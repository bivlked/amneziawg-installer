#!/usr/bin/env bats
# Version guard (issue #183): manage checks awg_common.sh compatibility.
#
# A server can end up with manage_amneziawg.sh from one version and
# awg_common.sh from another (the user updated only one file). Before this
# guard the mismatch surfaced as "_valid_cidr: command not found" or a similar
# random error deep inside a command. Now manage compares AWG_COMMON_VERSION
# (declared in the library) against its own SCRIPT_VERSION by MAJOR.MINOR and
# dies early with a clear "update both halves" message. A patch-level drift is
# tolerated; a different minor or a library with no version = stop.

load test_helper

# Extract _check_common_compat from a manage script (awk range: def .. closing brace).
extract_compat() {
    awk '/^_check_common_compat\(\)/,/^}/' "$BATS_TEST_DIRNAME/../$1"
}

# Run the extracted function with mocked die/SCRIPT_VERSION and a given
# AWG_COMMON_VERSION. Prints "OK" on return 0, "DIE:<msg>" on die.
run_compat() {
    local script="$1" common_ver="$2" script_ver="$3"
    local fn; fn=$(extract_compat "$script")
    [ -n "$fn" ] || { echo "extract failed"; return 99; }
    bash -c '
        die() { echo "DIE:$*"; exit 1; }
        AWG_DIR="/root/awg"; COMMON_SCRIPT_PATH="/root/awg/awg_common.sh"
        SCRIPT_VERSION="'"$script_ver"'"
        '"$fn"'
        if [ -n "'"$common_ver"'" ]; then AWG_COMMON_VERSION="'"$common_ver"'"; fi
        _check_common_compat && echo "OK"
    '
}

@test "guard: both libraries declare AWG_COMMON_VERSION" {
    for f in awg_common.sh awg_common_en.sh; do
        run grep -Ec '^AWG_COMMON_VERSION="[0-9]+\.[0-9]+\.[0-9]+"' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ]
        [ "$output" -eq 1 ]
    done
}

@test "guard: both manage scripts define and call _check_common_compat" {
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        run grep -Ec '^_check_common_compat\(\)' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ]; [ "$output" -eq 1 ]
        run grep -Ec '^[[:space:]]+_check_common_compat$' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ]; [ "$output" -ge 1 ]
    done
}

@test "guard: exact match passes (RU + EN)" {
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        run run_compat "$f" "5.20.0" "5.20.0"
        [ "$status" -eq 0 ]
        [[ "$output" == *OK* ]]
    done
}

@test "guard: patch drift is tolerated (5.20.0 lib vs 5.20.7 manage)" {
    run run_compat "manage_amneziawg.sh" "5.20.0" "5.20.7"
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "guard: minor mismatch dies (5.19.2 lib vs 5.20.0 manage)" {
    run run_compat "manage_amneziawg.sh" "5.19.2" "5.20.0"
    [ "$status" -ne 0 ]
    [[ "$output" == *DIE:* ]]
}

@test "guard: major mismatch dies (4.9.9 lib vs 5.20.0 manage)" {
    run run_compat "manage_amneziawg.sh" "4.9.9" "5.20.0"
    [ "$status" -ne 0 ]
    [[ "$output" == *DIE:* ]]
}

@test "guard: missing library version dies (old common, no variable)" {
    run run_compat "manage_amneziawg.sh" "" "5.20.0"
    [ "$status" -ne 0 ]
    [[ "$output" == *DIE:* ]]
}

@test "guard: two-component version dies (5.20 lib is not X.Y.Z)" {
    run run_compat "manage_amneziawg.sh" "5.20" "5.20.0"
    [ "$status" -ne 0 ]
    [[ "$output" == *DIE:* ]]
}

@test "guard: non-numeric version dies" {
    run run_compat "manage_amneziawg.sh" "abc" "5.20.0"
    [ "$status" -ne 0 ]
    [[ "$output" == *DIE:* ]]
}

@test "guard: rc/patch suffix on matching minor passes (5.20.0-rc1 vs 5.20.3)" {
    run run_compat "manage_amneziawg.sh" "5.20.0-rc1" "5.20.3"
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "guard: manage unsets AWG_COMMON_VERSION before sourcing (no env leak)" {
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        run grep -Ec '^[[:space:]]*unset AWG_COMMON_VERSION$' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ]; [ "$output" -ge 1 ]
    done
}

@test "guard: die message carries the update commands (both files, correct version)" {
    run run_compat "manage_amneziawg.sh" "5.19.2" "5.20.0"
    [[ "$output" == *"wget -O /root/awg/manage_amneziawg.sh"* ]]
    [[ "$output" == *"wget -O /root/awg/awg_common.sh"* ]]
    [[ "$output" == *"/v5.20.0/"* ]]
}

@test "guard: EN die message points at _en.sh URLs" {
    run run_compat "manage_amneziawg_en.sh" "5.19.2" "5.20.0"
    [ "$status" -ne 0 ]
    [[ "$output" == *"manage_amneziawg_en.sh"* ]]
    [[ "$output" == *"awg_common_en.sh"* ]]
}
