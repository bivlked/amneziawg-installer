#!/usr/bin/env bats
# The module version string does not identify the build, and diagnose must not
# pretend otherwise.
#
# Background. `/sys/module/amneziawg/version` is a static MODULE_VERSION define.
# A bench measurement on 30 aug 2026 read `3.1.20260812` from BOTH the PPA build
# of 14 aug and the one of 28 aug. diagnose used to turn that string into the
# literal "AmneziaWG 3.0" via `[[ $ver == 3.* ]]`, so every user on the third
# line saw a 3.1 module announced as 3.0, and no build could be told apart at
# all. check, 130 lines above in the same file, already carried the opposite
# rule in a comment.
#
# What this pins:
#   - awg_module_build_id reports srcversion and the package version;
#   - it survives a srcversion file with no trailing newline;
#   - it returns an empty string rather than junk when nothing is available;
#   - 🔴 the diagnose kernel-module block contains no hardcoded generation
#     literal and does call the build-id helper. This is the test that goes red
#     if the guess comes back.

RU_COMMON="${BATS_TEST_DIRNAME}/../awg_common.sh"
EN_COMMON="${BATS_TEST_DIRNAME}/../awg_common_en.sh"
RU_MANAGE="${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"
EN_MANAGE="${BATS_TEST_DIRNAME}/../manage_amneziawg_en.sh"

# The kernel-module stanza of diagnose_server, both languages.
_diag_module_block() {
    awk '/# 1\. Kernel module/,/# 2\. Service active/' "$1"
}

# Run awg_module_build_id extracted from a library, with /sys and dpkg-query
# both under the test's control.
_run_build_id() {
    local src="$1" stub_pkg="$2" lib="$3"
    local bin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$bin"
    if [ -n "$stub_pkg" ]; then
        printf '#!/usr/bin/env bash\nprintf %%s %s\n' "$stub_pkg" > "$bin/dpkg-query"
    else
        printf '#!/usr/bin/env bash\nexit 1\n' > "$bin/dpkg-query"
    fi
    chmod +x "$bin/dpkg-query"
    PATH="$bin:$PATH" AWG_MODULE_SRCVERSION_PATH="$src" bash -c '
        '"$(awk '/^awg_module_build_id\(\) \{/,/^\}/' "$lib")"'
        awg_module_build_id
    '
}

@test "build id: RU library defines awg_module_build_id" {
    grep -qE '^awg_module_build_id\(\) \{' "$RU_COMMON"
}

@test "build id: EN library defines awg_module_build_id" {
    grep -qE '^awg_module_build_id\(\) \{' "$EN_COMMON"
}

@test "build id: srcversion is reported" {
    local f="$BATS_TEST_TMPDIR/srcversion"
    printf '5F142DE112E19E1AD2E6344\n' > "$f"
    run _run_build_id "$f" "" "$RU_COMMON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"5F142DE112E19E1AD2E6344"* ]]
}

@test "build id: package version is reported alongside srcversion" {
    local f="$BATS_TEST_TMPDIR/srcversion"
    printf 'B55FF16F2E5FAADE434191F\n' > "$f"
    run _run_build_id "$f" "1.0.0-0~202608140352+4680320~ubuntu24.04.1" "$RU_COMMON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"B55FF16F2E5FAADE434191F"* ]]
    [[ "$output" == *"4680320"* ]]
}

@test "build id: a srcversion file without a trailing newline is still read" {
    local f="$BATS_TEST_TMPDIR/srcversion_nonl"
    printf 'ABCDEF0123456789' > "$f"
    run _run_build_id "$f" "" "$RU_COMMON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ABCDEF0123456789"* ]]
}

@test "build id: nothing available yields an empty string, not junk" {
    run _run_build_id "$BATS_TEST_TMPDIR/does-not-exist" "" "$RU_COMMON"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "build id: EN library behaves the same on srcversion" {
    local f="$BATS_TEST_TMPDIR/srcversion_en"
    printf 'DEADBEEFCAFE\n' > "$f"
    run _run_build_id "$f" "" "$EN_COMMON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DEADBEEFCAFE"* ]]
}

# 🔴 The guard. If someone reintroduces "print the generation from the version
# string", these two go red.
@test "diagnose RU: kernel-module block hardcodes no protocol generation" {
    local block
    block="$(_diag_module_block "$RU_MANAGE")"
    [ -n "$block" ]
    ! grep -qE 'AmneziaWG 3\.[0-9]' <<< "$block"
    ! grep -qE '_d_mod_ver" == 3\.' <<< "$block"
}

@test "diagnose EN: kernel-module block hardcodes no protocol generation" {
    local block
    block="$(_diag_module_block "$EN_MANAGE")"
    [ -n "$block" ]
    ! grep -qE 'AmneziaWG 3\.[0-9]' <<< "$block"
    ! grep -qE '_d_mod_ver" == 3\.' <<< "$block"
}

@test "diagnose RU: kernel-module block asks for the build id" {
    _diag_module_block "$RU_MANAGE" | grep -q 'awg_module_build_id'
}

@test "diagnose EN: kernel-module block asks for the build id" {
    _diag_module_block "$EN_MANAGE" | grep -q 'awg_module_build_id'
}
