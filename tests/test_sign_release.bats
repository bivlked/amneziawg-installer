#!/usr/bin/env bats
# scripts/sign-release.sh - the refusal paths.
#
# The happy path cannot be tested here: it needs the private key and its
# password. What can and must be tested is that every way of NOT signing is
# loud, because the failure this script was written after was silent. A manual
# signing loop was run where stdin was not a terminal; `read -rsp` failed
# immediately, the "&&" chain skipped the signing, nothing was written, no
# error appeared, and the next command in the line ran as if all was well.
#
# Test titles are ASCII on purpose: bats on Git Bash silently refuses to
# execute a test whose title contains Cyrillic: it prints "unknown test
# name" and the case does not run, with no "not ok" line to notice.

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT="$ROOT/scripts/sign-release.sh"
    FAKE_KEY="$BATS_TEST_TMPDIR/key"
    printf 'untrusted comment: fake\n' > "$FAKE_KEY"

    # The script checks that minisign exists before it checks anything else,
    # and CI installs only bats. Without a stub these tests would report on the
    # runner's package list rather than on the script: they passed locally,
    # where minisign is installed, and failed in CI for a reason that has
    # nothing to do with the code under test.
    #
    # The stub exits non-zero on purpose. No case here should reach the signing
    # loop, and if one ever does, a stub that succeeded would let it claim six
    # signatures without producing a single file.
    STUB_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUB_BIN"
    printf '#!/bin/sh\necho "stub minisign must not be called" >&2\nexit 1\n' \
        > "$STUB_BIN/minisign"
    chmod +x "$STUB_BIN/minisign"
    PATH="$STUB_BIN:$PATH"
    export PATH
}

@test "sign-release: no tag at all is a usage error" {
    run bash "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage:"* ]]
}

@test "sign-release: a tag without the leading v is rejected before the password" {
    MINISIGN_KEY="$FAKE_KEY" run bash "$SCRIPT" 5.29.0
    [ "$status" -eq 2 ]
    [[ "$output" == *"не похож"* ]]
    # Nothing about a password: the format is checked first, so a mistyped tag
    # costs one line rather than six signatures and a failed verification.
    [[ "$output" != *"Пароль"* ]]
}

@test "sign-release: a pre-release tag is accepted by the format check" {
    # It must get past the format gate and stop at the terminal check instead.
    MINISIGN_KEY="$FAKE_KEY" run bash "$SCRIPT" v5.29.0-rc1 < /dev/null
    [ "$status" -eq 2 ]
    [[ "$output" != *"не похож"* ]]
    [[ "$output" == *"нет терминала"* ]]
}

@test "sign-release: a missing key is named, not discovered later" {
    MINISIGN_KEY="$BATS_TEST_TMPDIR/nope" run bash "$SCRIPT" v5.29.0
    [ "$status" -eq 2 ]
    [[ "$output" == *"приватный ключ не найден"* ]]
}

@test "sign-release: no terminal for the password is a loud refusal" {
    # The regression this file exists for. Without a terminal the script must
    # refuse and say why; it must never proceed quietly having signed nothing.
    MINISIGN_KEY="$FAKE_KEY" run bash "$SCRIPT" v5.29.0 < /dev/null
    [ "$status" -eq 2 ]
    [[ "$output" == *"нет терминала"* ]]
    [[ "$output" != *"подписано"* ]]
}

@test "sign-release: an empty file list stops the run instead of reporting success" {
    tmp="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$tmp/scripts"
    cp "$SCRIPT" "$tmp/scripts/"
    printf '#!/usr/bin/env bash\n' > "$tmp/scripts/signed-file-list.sh"
    MINISIGN_KEY="$FAKE_KEY" run bash "$tmp/scripts/sign-release.sh" v5.29.0
    [ "$status" -eq 1 ]
    [[ "$output" == *"список подписываемых файлов пуст"* ]]
}

@test "sign-release: the missing key message names the override variable" {
    MINISIGN_KEY="$BATS_TEST_TMPDIR/nope" run bash "$SCRIPT" v5.29.0
    [ "$status" -eq 2 ]
    [[ "$output" == *"MINISIGN_KEY"* ]]
}

@test "sign-release: no WSL hint outside WSL" {
    # The hint is for the case where `bash` in PowerShell turns out to be the
    # WSL launcher, which inherits none of the Windows environment - not even
    # MINISIGN_KEY set on the same command line. Verified against a real WSL
    # run; here we guard the other side, that a normal shell is not told it is
    # something it is not.
    if [[ -r /proc/version ]] && grep -qiE 'microsoft|wsl' /proc/version; then
        skip "running under WSL, the negative case cannot be observed here"
    fi
    MINISIGN_KEY="$BATS_TEST_TMPDIR/nope" run bash "$SCRIPT" v5.29.0
    [ "$status" -eq 2 ]
    [[ "$output" != *"WSL"* ]]
}
