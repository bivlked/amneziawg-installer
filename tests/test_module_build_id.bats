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
# 🔴 Why every assertion below is either plain or final. In bash, `set -e` is
# ignored when a return value is inverted with `!`, so a bare `! grep ...` that
# is not the last command of a bats body is INERT: it reads like a check and
# checks nothing. The first version of this file had exactly that, and its
# mutation run passed only because of a different assertion further down.
# Verified on this machine: a failing `! true` in the middle of a body leaves
# the test green, while a plain `[ 1 -eq 2 ]` in the same place fails it.
#
# The guards also read the EXECUTABLE lines only. The comment that explains the
# removal names the old literal, and a whole-block grep would trip over the
# explanation instead of the code.

RU_COMMON="${BATS_TEST_DIRNAME}/../awg_common.sh"
EN_COMMON="${BATS_TEST_DIRNAME}/../awg_common_en.sh"
RU_MANAGE="${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"
EN_MANAGE="${BATS_TEST_DIRNAME}/../manage_amneziawg_en.sh"

# Executable lines of the kernel-module stanza of diagnose_server.
_diag_module_code() {
    awk '/# 1\. Kernel module/,/# 2\. Service active/' "$1" | grep -vE '^[[:space:]]*#'
}

# awg_module_build_id from a given library, with /sys and dpkg-query both under
# the test's control.
_run_build_id() {
    local src="$1" stub_pkg="$2" lib="$3"
    local bin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$bin"
    if [ -n "$stub_pkg" ]; then
        printf '#!/usr/bin/env bash\nprintf "%%s\\n" %s\n' "$stub_pkg" > "$bin/dpkg-query"
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

@test "build id RU: srcversion alone" {
    printf '5F142DE112E19E1AD2E6344\n' > "$BATS_TEST_TMPDIR/s"
    run _run_build_id "$BATS_TEST_TMPDIR/s" "" "$RU_COMMON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"5F142DE112E19E1AD2E6344"* ]]
    [ "$(grep -c ';' <<< "$output")" -eq 0 ]
}

@test "build id EN: srcversion alone" {
    printf '5F142DE112E19E1AD2E6344\n' > "$BATS_TEST_TMPDIR/s"
    run _run_build_id "$BATS_TEST_TMPDIR/s" "" "$EN_COMMON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"5F142DE112E19E1AD2E6344"* ]]
    [ "$(grep -c ';' <<< "$output")" -eq 0 ]
}

@test "build id RU: package alone, no srcversion available" {
    run _run_build_id "$BATS_TEST_TMPDIR/absent" "1.0.0-0~pkg+abc~ubuntu24.04.1" "$RU_COMMON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"1.0.0-0~pkg+abc~ubuntu24.04.1"* ]]
    [ "$(grep -c ';' <<< "$output")" -eq 0 ]
}

@test "build id EN: package alone, no srcversion available" {
    run _run_build_id "$BATS_TEST_TMPDIR/absent" "1.0.0-0~pkg+abc~ubuntu24.04.1" "$EN_COMMON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"1.0.0-0~pkg+abc~ubuntu24.04.1"* ]]
    [ "$(grep -c ';' <<< "$output")" -eq 0 ]
}

# 🔴 The loaded module and the installed package diverge routinely: upgrading
# the package leaves the old module in memory until modprobe. They must be
# reported as two labelled things, not merged into one identity.
@test "build id RU: both parts are separated and the loaded one comes first" {
    printf 'B55FF16F2E5FAADE434191F\n' > "$BATS_TEST_TMPDIR/s"
    run _run_build_id "$BATS_TEST_TMPDIR/s" "1.0.0-0~202608140352+4680320~ubuntu24.04.1" "$RU_COMMON"
    [ "$status" -eq 0 ]
    [ "$(grep -c ';' <<< "$output")" -eq 1 ]
    local head_part="${output%%;*}" tail_part="${output#*;}"
    [[ "$head_part" == *"B55FF16F2E5FAADE434191F"* ]]
    [[ "$tail_part" == *"4680320"* ]]
}

@test "build id EN: both parts are separated and the loaded one comes first" {
    printf 'B55FF16F2E5FAADE434191F\n' > "$BATS_TEST_TMPDIR/s"
    run _run_build_id "$BATS_TEST_TMPDIR/s" "1.0.0-0~202608140352+4680320~ubuntu24.04.1" "$EN_COMMON"
    [ "$status" -eq 0 ]
    [ "$(grep -c ';' <<< "$output")" -eq 1 ]
    local head_part="${output%%;*}" tail_part="${output#*;}"
    [[ "$head_part" == *"B55FF16F2E5FAADE434191F"* ]]
    [[ "$tail_part" == *"4680320"* ]]
}

@test "build id RU: a srcversion file without a trailing newline is still read" {
    printf 'ABCDEF0123456789' > "$BATS_TEST_TMPDIR/s"
    run _run_build_id "$BATS_TEST_TMPDIR/s" "" "$RU_COMMON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ABCDEF0123456789"* ]]
}

@test "build id EN: a srcversion file without a trailing newline is still read" {
    printf 'ABCDEF0123456789' > "$BATS_TEST_TMPDIR/s"
    run _run_build_id "$BATS_TEST_TMPDIR/s" "" "$EN_COMMON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ABCDEF0123456789"* ]]
}

# 🔴 Several matching lines must not be glued into one plausible but
# non-existent version. Only the first is taken.
_run_build_id_multiline() {
    local lib="$1"
    local bin="$BATS_TEST_TMPDIR/bin_multi"
    mkdir -p "$bin"
    cat > "$bin/dpkg-query" <<'STUB'
#!/usr/bin/env bash
printf '1.0.0-first\n2.0.0-second\n'
STUB
    chmod +x "$bin/dpkg-query"
    PATH="$bin:$PATH" AWG_MODULE_SRCVERSION_PATH="$BATS_TEST_TMPDIR/absent" bash -c '
        '"$(awk '/^awg_module_build_id\(\) \{/,/^\}/' "$lib")"'
        awg_module_build_id
    '
}

@test "build id RU: several package lines do not get glued together" {
    run _run_build_id_multiline "$RU_COMMON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"1.0.0-first"* ]]
    run bash -c 'grep -c "2.0.0-second" <<< "$1"' _ "$output"
    [ "$output" = "0" ]
}

@test "build id EN: several package lines do not get glued together" {
    run _run_build_id_multiline "$EN_COMMON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"1.0.0-first"* ]]
    run bash -c 'grep -c "2.0.0-second" <<< "$1"' _ "$output"
    [ "$output" = "0" ]
}

@test "build id RU: nothing available yields an empty string, not junk" {
    run _run_build_id "$BATS_TEST_TMPDIR/absent" "" "$RU_COMMON"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "build id EN: nothing available yields an empty string, not junk" {
    run _run_build_id "$BATS_TEST_TMPDIR/absent" "" "$EN_COMMON"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# 🔴 The guards. If the generation guess comes back, these go red.
@test "diagnose RU: executable lines carry no hardcoded generation literal" {
    _diag_module_code "$RU_MANAGE" > "$BATS_TEST_TMPDIR/code"
    [ -s "$BATS_TEST_TMPDIR/code" ]
    run grep -cE 'AmneziaWG [0-9]+\.[0-9]' "$BATS_TEST_TMPDIR/code"
    [ "$output" = "0" ]
}

@test "diagnose EN: executable lines carry no hardcoded generation literal" {
    _diag_module_code "$EN_MANAGE" > "$BATS_TEST_TMPDIR/code"
    [ -s "$BATS_TEST_TMPDIR/code" ]
    run grep -cE 'AmneziaWG [0-9]+\.[0-9]' "$BATS_TEST_TMPDIR/code"
    [ "$output" = "0" ]
}

@test "diagnose RU: executable lines do not branch on the version prefix" {
    _diag_module_code "$RU_MANAGE" > "$BATS_TEST_TMPDIR/code"
    [ -s "$BATS_TEST_TMPDIR/code" ]
    run grep -cE '_d_mod_ver"[[:space:]]*==[[:space:]]*3\.' "$BATS_TEST_TMPDIR/code"
    [ "$output" = "0" ]
}

@test "diagnose EN: executable lines do not branch on the version prefix" {
    _diag_module_code "$EN_MANAGE" > "$BATS_TEST_TMPDIR/code"
    [ -s "$BATS_TEST_TMPDIR/code" ]
    run grep -cE '_d_mod_ver"[[:space:]]*==[[:space:]]*3\.' "$BATS_TEST_TMPDIR/code"
    [ "$output" = "0" ]
}

@test "diagnose RU: the stanza asks for the build id" {
    _diag_module_code "$RU_MANAGE" | grep -q 'awg_module_build_id'
}

@test "diagnose EN: the stanza asks for the build id" {
    _diag_module_code "$EN_MANAGE" | grep -q 'awg_module_build_id'
}
