#!/usr/bin/env bats
# scripts/update-sha-pins.sh - the pin's source of truth.
#
# The script decides what a pin OUGHT to be, and until now nothing tested it.
# It has to agree with tests/test_v515_sha_pins_lockstep.bats, because
# scripts/preflight-check.sh runs both: the bats suite as step 3 and
# "update-sha-pins.sh --verify" as step 8. Two different answers about one
# state would make preflight simultaneously green and red.
#
# Every case here runs against a throwaway fixture repository built in
# BATS_TEST_TMPDIR, never against the real checkout.
#
# Test titles are ASCII on purpose: bats on Git Bash cannot execute a test
# whose title contains Cyrillic - it prints "unknown test name" and the case
# silently does not run, with no "not ok" line anywhere (see MyAI-ln09).

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    FIX="$BATS_TEST_TMPDIR/fixture"
    mkdir -p "$FIX/scripts"
    cp "$ROOT/scripts/update-sha-pins.sh" "$FIX/scripts/"

    _helper awg_common.sh
    _helper manage_amneziawg.sh
    _helper awg_common_en.sh
    _helper manage_amneziawg_en.sh
    _installer install_amneziawg.sh awg_common.sh manage_amneziawg.sh
    _installer install_amneziawg_en.sh awg_common_en.sh manage_amneziawg_en.sh

    _git init -q
    _git add -A
    _git commit -qm initial
}

_helper() {
    printf '#!/usr/bin/env bash\n# %s at the tag\n' "$1" > "$FIX/$1"
}

_installer() {
    {
        printf '#!/usr/bin/env bash\n'
        printf 'SCRIPT_VERSION="1.0.0"\n'
        printf 'COMMON_SCRIPT_SHA256="%s"\n' "$(_sha "$2")"
        printf 'MANAGE_SCRIPT_SHA256="%s"\n' "$(_sha "$3")"
    } > "$FIX/$1"
}

_sha() { sha256sum "$FIX/$1" | cut -d' ' -f1; }

_git() { git -C "$FIX" -c user.name=t -c user.email=t@t "$@"; }

_pin() { grep -oP '^'"$2"'_SCRIPT_SHA256="\K[0-9a-f]{64}' "$FIX/$1"; }

_run_pins() { ( cd "$FIX" && bash scripts/update-sha-pins.sh "$@" 2>&1 ); }

# Edit a helper AFTER the tag, so tree bytes and tag bytes differ.
_edit_helper_after_tag() { printf '# edited on main\n' >> "$FIX/awg_common.sh"; }

@test "pins: tag exists and pins match it - green, and says the tag was used" {
    _git tag v1.0.0
    _edit_helper_after_tag
    run _run_pins --verify
    [ "$status" -eq 0 ]
    [[ "$output" == *"tag v1.0.0"* ]]
    [[ "$output" != *"worktree"* ]]
}

@test "pins: recomputed from the tree while the tag exists - red" {
    _git tag v1.0.0
    _edit_helper_after_tag
    # The dangerous state: an installer shipped like this would refuse the
    # download it is supposed to accept.
    sed -i "s|^COMMON_SCRIPT_SHA256=.*|COMMON_SCRIPT_SHA256=\"$(_sha awg_common.sh)\"|" \
        "$FIX/install_amneziawg.sh"
    run _run_pins --verify
    [ "$status" -eq 1 ]
    [[ "$output" == *"MISMATCH"* ]]
}

@test "pins: no tag for this version - writes from the tree, then is idempotent" {
    _git tag v0.9.0
    _edit_helper_after_tag
    run _run_pins
    [ "$status" -eq 0 ]
    [[ "$output" == *"UPDATE"* ]]
    [ "$(_pin install_amneziawg.sh COMMON)" = "$(_sha awg_common.sh)" ]

    run _run_pins
    [ "$status" -eq 0 ]
    [[ "$output" != *"UPDATE"* ]]
}

@test "pins: a corrupted pin is repaired with the TAG bytes, not the tree bytes" {
    _git tag v1.0.0
    tagged=$(_sha awg_common.sh)
    _edit_helper_after_tag
    sed -i 's|^COMMON_SCRIPT_SHA256=.*|COMMON_SCRIPT_SHA256="'"$(printf '0%.0s' {1..64})"'"|' \
        "$FIX/install_amneziawg.sh"
    run _run_pins
    [ "$status" -eq 0 ]
    [ "$(_pin install_amneziawg.sh COMMON)" = "$tagged" ]
    [ "$(_pin install_amneziawg.sh COMMON)" != "$(_sha awg_common.sh)" ]
}

@test "pins: a checkout with no tags fails, and names the tags as the reason" {
    run _run_pins --verify
    [ "$status" -eq 1 ]
    [[ "$output" == *"нет ни одного тега"* ]]
    # The reason must not be shadowed by a second, invented one: sha256 was
    # never computed here, so claiming it could not be computed sends the
    # reader after the wrong thing.
    [[ "$output" != *"не удалось вычислить sha256"* ]]
}

@test "pins: tags exist but not this version's - falls back to the tree OUT LOUD" {
    _git tag v0.9.0
    run _run_pins --verify
    [ "$status" -eq 0 ]
    # Silence here would be the whole defect: the weaker comparison must be
    # distinguishable from the contract one.
    [[ "$output" == *"worktree"* ]]
    [[ "$output" == *"git fetch --tags --force"* ]]
}

@test "pins: helper missing at the tag - fails and leaves the pins alone" {
    _git rm -q awg_common.sh
    _git commit -qm "drop helper"
    _git tag v1.0.0
    _git checkout -q HEAD~1 -- awg_common.sh
    before=$(_pin install_amneziawg.sh COMMON)
    run _run_pins
    [ "$status" -eq 1 ]
    [[ "$output" == *"не удалось прочитать v1.0.0:awg_common.sh"* ]]
    [ "$(_pin install_amneziawg.sh COMMON)" = "$before" ]
}
