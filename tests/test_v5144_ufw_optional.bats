#!/usr/bin/env bats
# Issue #89 (jay0x): declining UFW activation must NOT abort the install.
#
# Before the fix, setup_improved_firewall returned 1 when the user answered
# anything but Y to "Enable UFW?", and the caller did
#   setup_improved_firewall || die "..."
# so a legitimate "no firewall" choice killed the whole installer.
#
# These tests extract setup_improved_firewall from the RU and EN installers,
# strip the `< /dev/tty` redirect so the prompt can be fed over a pipe, mock
# every external command (ufw/ip/command/log/...), and assert:
#   * answering N returns 0 and never calls `ufw enable`
#   * answering y returns 0 and DOES call `ufw --force enable`
#   * AUTO_YES=1 auto-enables without reading stdin
# Plus a RU/EN structural parity guard.

bats_require_minimum_version 1.5.0

RU_SCRIPT="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
EN_SCRIPT="$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"

# Load setup_improved_firewall from a given installer into the current shell,
# with the interactive `< /dev/tty` redirect removed so `read` uses stdin.
# Exported so a child `bash -c` (used to feed stdin over a pipe) inherits it.
_load_firewall_fn() {
    local script="$1"
    eval "$(awk '/^setup_improved_firewall\(\) \{/,/^\}/' "$script" | sed 's#< /dev/tty##')"
    export -f setup_improved_firewall
}

setup() {
    UFW_CALLS="$BATS_TEST_TMPDIR/ufw_calls"
    : > "$UFW_CALLS"

    # Mock ufw: record every invocation, report "inactive" for status so the
    # function takes the first-time-setup branch, succeed otherwise.
    ufw() {
        echo "$*" >> "$UFW_CALLS"
        case "$1" in
            status) echo "Status: inactive" ;;
            *)      return 0 ;;
        esac
    }

    # main_nic detection: `ip route get 1.1.1.1 | awk ... dev <nic>`
    ip() { echo "1.1.1.1 dev eth0 src 10.0.0.1 uid 0"; }

    command() { return 0; }          # `command -v ufw` -> found
    install_packages() { return 0; }
    touch() { return 0; }
    log()       { :; }
    log_warn()  { :; }
    log_error() { :; }
    die() { echo "DIE: $*"; return 1; }

    export -f ufw ip command install_packages touch log log_warn log_error die

    AWG_PORT=39743
    AWG_DIR="$BATS_TEST_TMPDIR"
    AUTO_YES=0
    # Exported so the child `bash -c` (pipe shell) sees them via the
    # environment rather than via string interpolation - paths with spaces
    # would otherwise break the injected command.
    export UFW_CALLS AWG_PORT AWG_DIR AUTO_YES
}

@test "RU: declining UFW (N) returns 0 and does not enable" {
    _load_firewall_fn "$RU_SCRIPT"
    run bash -c 'printf "N\n" | setup_improved_firewall'
    [ "$status" -eq 0 ]
    run ! grep -qx -- '--force enable' "$UFW_CALLS"
}

@test "RU: accepting UFW (y) returns 0 and calls enable" {
    _load_firewall_fn "$RU_SCRIPT"
    run bash -c 'printf "y\n" | setup_improved_firewall'
    [ "$status" -eq 0 ]
    grep -qx -- '--force enable' "$UFW_CALLS"
}

@test "RU: AUTO_YES=1 auto-enables without reading stdin" {
    _load_firewall_fn "$RU_SCRIPT"
    AUTO_YES=1
    run bash -c 'setup_improved_firewall < /dev/null'
    [ "$status" -eq 0 ]
    grep -qx -- '--force enable' "$UFW_CALLS"
}

@test "EN: declining UFW (N) returns 0 and does not enable" {
    _load_firewall_fn "$EN_SCRIPT"
    run bash -c 'printf "N\n" | setup_improved_firewall'
    [ "$status" -eq 0 ]
    run ! grep -qx -- '--force enable' "$UFW_CALLS"
}

@test "EN: accepting UFW (y) returns 0 and calls enable" {
    _load_firewall_fn "$EN_SCRIPT"
    run bash -c 'printf "y\n" | setup_improved_firewall'
    [ "$status" -eq 0 ]
    grep -qx -- '--force enable' "$UFW_CALLS"
}

@test "RU/EN parity: both return 0 (not 1) on declined UFW" {
    # The decline branch (from `confirm_ufw =~` test to its closing fi) must
    # end in `return 0`, not `return 1`.
    run bash -c "awk '/confirm_ufw.*=~/,/^        fi/' '$RU_SCRIPT' | grep -c 'return 0'"
    [ "$output" -ge 1 ]
    run bash -c "awk '/confirm_ufw.*=~/,/^        fi/' '$RU_SCRIPT' | grep -c 'return 1'"
    [ "$output" -eq 0 ]
    run bash -c "awk '/confirm_ufw.*=~/,/^        fi/' '$EN_SCRIPT' | grep -c 'return 0'"
    [ "$output" -ge 1 ]
    run bash -c "awk '/confirm_ufw.*=~/,/^        fi/' '$EN_SCRIPT' | grep -c 'return 1'"
    [ "$output" -eq 0 ]
}
