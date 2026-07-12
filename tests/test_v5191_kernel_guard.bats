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

@test "v5.19.1 #163: unparseable kernel is skipped (no false abort)" {
    _set_uname "weirdkernel"; AUTO_YES=1
    run check_kernel_version
    [ "$status" -eq 0 ]
}

@test "v5.19.1 #163: check_kernel_version defined and wired into step 0 (RU + EN)" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        grep -q '^check_kernel_version() {' "$ROOT/$f" || { echo "no function in $f"; false; }
        grep -qE '^[[:space:]]*check_kernel_version[[:space:]]*$' "$ROOT/$f" || { echo "not called in $f"; false; }
    done
}
