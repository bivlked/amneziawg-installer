#!/usr/bin/env bats
# SHA256 pin lockstep test.
#
# The installers download the helper scripts over the network and verify them
# against hardcoded pins (COMMON_SCRIPT_SHA256 / MANAGE_SCRIPT_SHA256). By
# default the URL they download from is
#
#     https://raw.githubusercontent.com/<repo>/${AWG_BRANCH}/<helper>
#     AWG_BRANCH="${AWG_BRANCH:-v${SCRIPT_VERSION}}"
#
# so with AWG_BRANCH unset the bytes an end user receives are the bytes of the
# helper AT THE TAG v$SCRIPT_VERSION, not the bytes in the working tree. With
# AWG_BRANCH overridden the installer does not merely fetch from somewhere
# else: verify_sha256() skips the pin check altogether and only warns. The pin
# therefore governs the default path, which is the one users take.
#
# Comparing a pin against the neighbouring file is only a proxy for that
# contract, and the proxy holds only while the tree happens to equal the tag.
# It was wrong in both directions:
#   - it went red on main after a cosmetic commit that touched a helper without
#     a version bump, even though every published installer was still correct;
#   - it stayed green when the pins were recomputed from the tree while the tag
#     already existed. An installer shipped with such pins would refuse the
#     download it is supposed to accept.
#
# So: if the tag for this installer's SCRIPT_VERSION exists, compare the pin
# with the helper's bytes at that tag. If it does not exist, compare with the
# working tree and say so out loud.
#
# KNOWN LIMIT, stated because a silent one would be worse: the local tag set is
# taken as the truth. A checkout that has simply not fetched v$SCRIPT_VERSION
# (shallow, --no-tags, a fork made before the tag), or whose tag moved under
# "git tag -f", is indistinguishable here from an honest release in
# preparation, and falls back to the tree comparison. Only a checkout with NO
# tags at all is rejected outright. That fallback announces itself on TAP
# output, so a run that checked the weaker thing can be told apart from a run
# that checked the contract.

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

# Expected sha for a helper, resolved against whatever the installer will
# really download. Prints the sha; on any inability to decide, prints nothing
# and returns non-zero, because "could not check" must never read as "passed".
_expected_sha() {
    local installer="$1" helper="$2" ver tag
    ver=$(grep -oP 'SCRIPT_VERSION="\K[0-9.]+' "$ROOT/$installer" | head -1)
    if [ -z "$ver" ]; then
        echo "cannot read SCRIPT_VERSION from $installer" >&2
        return 1
    fi
    tag="v$ver"

    if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        echo "not a git checkout: cannot resolve $tag, refusing to guess" >&2
        return 1
    fi

    # A checkout with no tags at all is an environment fault, not the
    # "tag not pushed yet" state. Without this the test would quietly
    # degrade to the old tree comparison in CI (actions/checkout fetches
    # no tags by default) and its result would mean nothing.
    if [ -z "$(git -C "$ROOT" tag --list | head -1)" ]; then
        echo "this checkout has no tags at all - fetch them (fetch-depth: 0 or fetch-tags: true)" >&2
        return 1
    fi

    if git -C "$ROOT" rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1; then
        local tmp sha
        tmp="$(mktemp)" || return 1
        # Not "git show | sha256sum": on empty output that pipeline cheerfully
        # hashes the empty input into 64 valid hex characters, which would sail
        # through every length check and look like a real expected value. And
        # not "$(git show)" either: command substitution strips trailing
        # newlines and would change the hash.
        if ! git -C "$ROOT" show "refs/tags/$tag:$helper" > "$tmp" 2>/dev/null; then
            rm -f "$tmp"
            # The cause is deliberately not named: a missing file at the tag, a
            # corrupt object and an unfetched shallow checkout all land here.
            echo "cannot read $tag:$helper" >&2
            return 1
        fi
        sha="$(sha256sum "$tmp" | cut -d' ' -f1)"
        rm -f "$tmp"
        if [[ ! "$sha" =~ ^[0-9a-f]{64}$ ]]; then
            echo "unusable sha for $tag:$helper" >&2
            return 1
        fi
        printf '%s tag %s' "$sha" "$tag"
        return 0
    fi

    # Release in preparation, or a checkout that never fetched the tag - see
    # KNOWN LIMIT above. Announced, not assumed silently.
    printf '%s worktree' "$(sha256sum "$ROOT/$helper" | cut -d' ' -f1)"
}

# A pin must occur exactly once. Two occurrences are an ambiguity, not a
# detail: bash applies the LAST assignment when it sources the installer,
# while grep piped into head would report the first.
_pinned_sha() {
    local hits
    hits=$(grep -cP '^'"$2"'_SCRIPT_SHA256="[0-9a-f]{64}"' "$ROOT/$1")
    if [ "$hits" != "1" ]; then
        echo "$2 pin occurs $hits times in $1 - bash would apply the last" >&2
        return 1
    fi
    grep -oP '^'"$2"'_SCRIPT_SHA256="\K[0-9a-f]{64}' "$ROOT/$1"
}

_check_pin() {
    local installer="$1" kind="$2" helper="$3" line expected src pinned
    line=$(_expected_sha "$installer" "$helper") || {
        echo "$kind pin for $helper NOT CHECKED (see reason above)" >&2
        false
        return
    }
    read -r expected src <<< "$line"
    # Say which of the two comparisons actually ran. A green run that silently
    # used the weaker one is precisely what this file exists to prevent.
    echo "# $installer $kind: checked against $src" >&3
    pinned=$(_pinned_sha "$installer" "$kind") || {
        echo "$kind pin for $helper NOT CHECKED (see reason above)" >&2
        false
        return
    }
    [ -n "$expected" ] && [ -n "$pinned" ] || {
        echo "$kind pin for $helper NOT CHECKED: empty value (expected='$expected' pinned='$pinned')" >&2
        false
        return
    }
    [ "$expected" = "$pinned" ] || {
        echo "$installer $kind pin mismatch for $helper: pinned=$pinned expected=$expected" >&2
        echo "  run scripts/update-sha-pins.sh after the version headers are final" >&2
        false
    }
}

# ---------- RU installer pins ----------

@test "RU installer COMMON pin matches awg_common.sh as published" {
    _check_pin install_amneziawg.sh COMMON awg_common.sh
}

@test "RU installer MANAGE pin matches manage_amneziawg.sh as published" {
    _check_pin install_amneziawg.sh MANAGE manage_amneziawg.sh
}

# ---------- EN installer pins ----------

@test "EN installer COMMON pin matches awg_common_en.sh as published" {
    _check_pin install_amneziawg_en.sh COMMON awg_common_en.sh
}

@test "EN installer MANAGE pin matches manage_amneziawg_en.sh as published" {
    _check_pin install_amneziawg_en.sh MANAGE manage_amneziawg_en.sh
}
