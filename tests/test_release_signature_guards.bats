#!/usr/bin/env bats
# Guards in scripts/verify-signatures.sh against a check that verifies nothing.
#
# The script counts how many signatures it verified and refuses to report
# success if that number is wrong. The number it compares against used to come
# from the same list it was checking, and a list compared with itself cannot
# notice that it shrank: break the list and both counts fall to zero together,
# so the script printed PASS having opened no file at all. Downstream that meant
# release.yml attaching KEYS.txt alone and calling it a release.
#
# These tests break the list in the three ways that produced a silent pass and
# require a loud failure instead. The fourth test is the control: with the list
# intact the guards must stay quiet, otherwise they would be trading a silent
# pass for a permanent false alarm, which is not an improvement.
#
# Deliberately independent of minisign: these checks run before it is needed, so
# they are exercised on a CI runner that has no minisign installed. A test that
# silently skips is the very thing this file exists to prevent.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SANDBOX="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$SANDBOX/scripts" "$SANDBOX/signing"
    cp "$REPO_ROOT/scripts/verify-signatures.sh" "$SANDBOX/scripts/"
    cp "$REPO_ROOT/scripts/signed-file-list.sh" "$SANDBOX/scripts/"
    printf 'untrusted comment: test\nRWQtest\n' > "$SANDBOX/KEYS.txt"
    while read -r f; do
        [ -n "$f" ] || continue
        printf '#!/usr/bin/env bash\n' > "$SANDBOX/$f"
    done < <(bash "$REPO_ROOT/scripts/signed-file-list.sh")
}

_run_verify() {
    cd "$SANDBOX" || return 1
    bash scripts/verify-signatures.sh v9.9.9 2>&1
}

@test "signature-guards: a list command that fails is not a clean run" {
    printf '#!/usr/bin/env bash\nexit 127\n' > "$SANDBOX/scripts/signed-file-list.sh"
    run _run_verify
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot read scripts/signed-file-list.sh"* ]]
}

@test "signature-guards: an empty list is not zero files verified successfully" {
    printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/scripts/signed-file-list.sh"
    run _run_verify
    [ "$status" -ne 0 ]
    [[ "$output" == *"disagrees with the scripts at the repository root"* ]]
}

@test "signature-guards: a name dropped from the list fails instead of shipping unsigned" {
    # One name removed: the old guard saw checked == expected and passed, and the
    # release went out missing a script and its signature with everything green.
    bash "$BATS_TEST_DIRNAME/../scripts/signed-file-list.sh" | tail -n +2 > "$BATS_TEST_TMPDIR/short"
    {
        printf '#!/usr/bin/env bash\ncat <<EOF\n'
        cat "$BATS_TEST_TMPDIR/short"
        printf 'EOF\n'
    } > "$SANDBOX/scripts/signed-file-list.sh"
    run _run_verify
    [ "$status" -ne 0 ]
    [[ "$output" == *"disagrees with the scripts at the repository root"* ]]
}

@test "signature-guards: control - an intact list does not trip the guards" {
    # Must still fail, because the sandbox holds no signatures, but it has to
    # fail on the missing signature rather than on the list. A guard that fires
    # when nothing is wrong gets switched off, and then it guards nothing.
    run _run_verify
    [ "$status" -ne 0 ]
    [[ "$output" != *"disagrees with the scripts at the repository root"* ]]
    [[ "$output" != *"cannot read scripts/signed-file-list.sh"* ]]
}

@test "signature-guards: the real list matches the scripts at the repository root" {
    # The drift this catches in the actual tree: a new deliverable script added
    # to the root without being added to the list would ship unsigned.
    listed="$(bash "$BATS_TEST_DIRNAME/../scripts/signed-file-list.sh" | sort)"
    cd "$BATS_TEST_DIRNAME/.." || return 1
    at_root="$(printf '%s\n' ./*.sh | sed 's#^\./##' | sort)"
    [ "$listed" = "$at_root" ]
}
