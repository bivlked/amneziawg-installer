#!/usr/bin/env bats
# The shell files tracked in the repository are exactly the ones we ship.
#
# A signal experiment named t.sh once reached the tree through a wildcard add
# and survived a green preflight: preflight lints the six named scripts, and the
# only glob-based check in check-docs-consistency.sh looks at control bytes. A
# scratch file at the root would have shipped in the release tag.
#
# The list below is the contract. Adding a script to the project means adding it
# here on purpose; that is the whole point.

setup() {
    cd "$BATS_TEST_DIRNAME/.." || return 1
}

@test "tree: the tracked shell files are exactly the expected set" {
    command -v git >/dev/null || skip "git not available"
    git rev-parse --git-dir >/dev/null 2>&1 || skip "not a git checkout"

    local expected actual
    expected=$(printf '%s\n' \
        awg_common.sh \
        awg_common_en.sh \
        install_amneziawg.sh \
        install_amneziawg_en.sh \
        manage_amneziawg.sh \
        manage_amneziawg_en.sh \
        scripts/build-arm-deb.sh \
        scripts/build-release-notes.sh \
        scripts/check-docs-consistency.sh \
        scripts/check-markers.sh \
        scripts/preflight-check.sh \
        scripts/sign-release.sh \
        scripts/signed-file-list.sh \
        scripts/update-facts-block.sh \
        scripts/update-sha-pins.sh \
        scripts/verify-signatures.sh \
        | sort)
    actual=$(git ls-files '*.sh' | sort)
    [ "$actual" = "$expected" ] || {
        echo "tracked shell files differ from the expected set"
        diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") || true
        false
    }
}

@test "tree: no tracked file lives at the root outside the known list" {
    command -v git >/dev/null || skip "git not available"
    git rev-parse --git-dir >/dev/null 2>&1 || skip "not a git checkout"

    local unexpected
    unexpected=$(git ls-files | grep -vE '/' | grep -vE '^(awg_common(_en)?\.sh|install_amneziawg(_en)?\.sh|manage_amneziawg(_en)?\.sh|[A-Z][A-Za-z0-9_.-]*\.md|LICENSE|\.editorconfig|\.gitattributes|\.gitignore|logo\.jpg|AmneziaWG20\.jpg|KEYS\.txt)$' || true)
    [ -z "$unexpected" ] || {
        echo "unexpected tracked files at the repository root:"
        printf '%s\n' "$unexpected"
        false
    }
}
