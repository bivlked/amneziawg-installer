#!/usr/bin/env bats
# v5.19.1 (#163): explicit early guard for a too-old kernel.
#
# The AmneziaWG 2.0 DKMS module does not build on kernels older than 5.15 (e.g.
# 5.4 on Ubuntu 20.04). The installer used to proceed and die at step 2 with an
# opaque "package install failed". check_kernel_version now warns clearly and
# early, before the system update and reboots. Non-fatal: with --yes it
# continues; interactively a "no" aborts.
# shellcheck disable=SC2317,SC2329,SC2034  # bodies invoked via eval; uname/read/AUTO_YES/confirm are stubs

ROOT="$BATS_TEST_DIRNAME/.."

setup() {
    LAST_WARN=""
    log()       { :; }
    log_warn()  { LAST_WARN="$LAST_WARN $*"; }
    log_error() { :; }
    die()       { echo "DIE: $*"; exit 1; }
    eval "$(awk '/^check_kernel_version\(\) \{/{f=1} f{print} f&&/^}$/{exit}' \
        "$ROOT/install_amneziawg.sh")"
}

_set_uname() { eval "uname() { echo '$1'; }"; }

@test "v5.19.1 #163: kernel 5.4 (Ubuntu 20.04) warns as too old, continues with --yes" {
    _set_uname "5.4.0-216-generic"; AUTO_YES=1
    check_kernel_version
    [[ "$LAST_WARN" == *"5.15"* ]]
}

@test "v5.19.1 #163: kernel 6.8 (Ubuntu 24.04) passes without a warning" {
    _set_uname "6.8.0-31-generic"; AUTO_YES=1
    check_kernel_version
    [ -z "${LAST_WARN// /}" ]
}

@test "v5.19.1 #163: kernel 5.15 is the accepted boundary (no warning)" {
    _set_uname "5.15.0-100-generic"; AUTO_YES=1
    check_kernel_version
    [ -z "${LAST_WARN// /}" ]
}

@test "v5.19.1 #163: too-old kernel with an interactive 'no' aborts" {
    _set_uname "5.4.0-216-generic"; AUTO_YES=0
    read() { confirm="n"; }
    run check_kernel_version
    [ "$status" -ne 0 ]
    [[ "$output" == *"DIE:"* ]]
}

# The interactive "yes continues" path reads from /dev/tty, which is not
# available under bats; instead guard the confirmation regex directly (extracted
# from the real code) so a regression cannot start rejecting a valid "y"/"yes"
# and falsely abort an operator who opted in on an old-but-workable (HWE) kernel.
@test "v5.19.1 #163: confirm regex accepts y/yes, rejects n and empty (HWE opt-in)" {
    local line re
    line=$(awk '/^check_kernel_version\(\) \{/{f=1} f&&/confirm" =~/{print; exit}' "$ROOT/install_amneziawg.sh")
    re="${line#*=~ }"; re="${re%% ]]; then*}"
    [ -n "$re" ]
    [[ "y"   =~ $re ]]
    [[ "yes" =~ $re ]]
    [[ " Y " =~ $re ]]
    [[ ! "n" =~ $re ]]
    [[ ! ""  =~ $re ]]
}

@test "v5.19.1 #163: kernel 5.14 (just below the boundary) warns" {
    _set_uname "5.14.21-generic"; AUTO_YES=1
    check_kernel_version
    [[ "$LAST_WARN" == *"5.15"* ]]
}

@test "v5.19.1 #163: unparseable kernel is skipped WITH a warning (no false abort)" {
    _set_uname "weirdkernel"; AUTO_YES=1
    check_kernel_version
    [[ "$LAST_WARN" == *"weirdkernel"* ]]
}

@test "v5.19.1 #163: dotless numeric kernel ('5'/'6') is unparseable, not read as major.minor" {
    # Regression: a bare '5' would parse kmin='5' and fall into the too-old
    # branch, so an interactive 'no' aborts a host whose kernel is merely
    # unknown, not old; a bare '6' would pass silently. Require major.minor:
    # anything without a dot is unparseable -> warn + continue, never die.
    read() { confirm="n"; }
    _set_uname "5"; AUTO_YES=0; LAST_WARN=""
    check_kernel_version
    [[ "$LAST_WARN" == *"'5'"* ]]
    _set_uname "6"; AUTO_YES=1; LAST_WARN=""
    check_kernel_version
    [[ "$LAST_WARN" == *"'6'"* ]]
}

@test "v5.19.1 #163: check_kernel_version runs early - before check_free_space (RU + EN)" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        grep -q '^check_kernel_version() {' "$ROOT/$f" || { echo "no function in $f"; false; }
        local body kline fline
        body=$(awk '/^initialize_setup\(\) \{/{f=1} f{print} f&&/^}$/{exit}' "$ROOT/$f")
        kline=$(echo "$body" | grep -n '^[[:space:]]*check_kernel_version[[:space:]]*$' | head -1 | cut -d: -f1)
        fline=$(echo "$body" | grep -n '^[[:space:]]*check_free_space[[:space:]]*$' | head -1 | cut -d: -f1)
        [ -n "$kline" ] && [ -n "$fline" ] && [ "$kline" -lt "$fline" ] || { echo "kernel check not before check_free_space in $f"; false; }
    done
}
