#!/usr/bin/env bats
# Issue #91 (userosos): SSH lockout when SSH runs on a non-standard port.
#
# Before the fix, setup_improved_firewall hardcoded `ufw limit 22/tcp` while
# `ufw default deny incoming` was active, so a server with SSH on a custom port
# lost all access right after `ufw enable`.
#
# The fix adds detect_ssh_ports(): it resolves the real SSH port(s) from
# --ssh-port, then `sshd -T`, then `ss`, then sshd_config files, then 22, and
# setup_improved_firewall opens each detected port with `ufw limit <port>/tcp`.
#
# These tests cover detect_ssh_ports() in isolation (the deterministic
# CLI-override and sshd paths) and the integration with setup_improved_firewall
# (the right ufw limit rule is applied). Both RU and EN scripts must match.

bats_require_minimum_version 1.5.0

RU_SCRIPT="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
EN_SCRIPT="$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"

# Pull detect_ssh_ports out of a given installer into the current shell.
_load_detect_fn() {
    eval "$(awk '/^detect_ssh_ports\(\) \{/,/^\}/' "$1")"
}

# Pull both detect_ssh_ports and setup_improved_firewall, strip the
# `< /dev/tty` redirect so `read` uses stdin, and export for a child bash -c.
_load_fw_fns() {
    local script="$1"
    eval "$(awk '/^detect_ssh_ports\(\) \{/,/^\}/' "$script")"
    eval "$(awk '/^setup_improved_firewall\(\) \{/,/^\}/' "$script" | sed 's#< /dev/tty##')"
    export -f detect_ssh_ports setup_improved_firewall
}

setup() {
    # Silent log stubs (detect_ssh_ports uses log_warn on invalid --ssh-port).
    log()       { :; }
    log_warn()  { :; }
    log_error() { :; }
    log_debug() { :; }
    export -f log log_warn log_error log_debug
    unset CLI_SSH_PORT
}

# ---------------------------------------------------------------------------
# detect_ssh_ports() - CLI override path (deterministic, no external deps)
# ---------------------------------------------------------------------------

@test "RU detect: single custom port via --ssh-port" {
    _load_detect_fn "$RU_SCRIPT"
    CLI_SSH_PORT=2222
    run detect_ssh_ports
    [ "$output" = "2222" ]
}

@test "RU detect: comma-separated list preserves order" {
    _load_detect_fn "$RU_SCRIPT"
    CLI_SSH_PORT="2222,22"
    run detect_ssh_ports
    [ "$output" = "2222 22" ]
}

@test "RU detect: duplicates collapsed" {
    _load_detect_fn "$RU_SCRIPT"
    CLI_SSH_PORT="22,22,2222"
    run detect_ssh_ports
    [ "$output" = "22 2222" ]
}

@test "RU detect: invalid-only input falls back to 22" {
    _load_detect_fn "$RU_SCRIPT"
    CLI_SSH_PORT="99999"
    run detect_ssh_ports
    [ "$output" = "22" ]
}

@test "RU detect: mixed valid+invalid keeps only valid" {
    _load_detect_fn "$RU_SCRIPT"
    CLI_SSH_PORT="2222,abc"
    run detect_ssh_ports
    [ "$output" = "2222" ]
}

@test "RU detect: boundary 65535 valid, 65536 and 0 invalid" {
    _load_detect_fn "$RU_SCRIPT"
    CLI_SSH_PORT="65535"
    run detect_ssh_ports
    [ "$output" = "65535" ]
    CLI_SSH_PORT="65536"
    run detect_ssh_ports
    [ "$output" = "22" ]
    CLI_SSH_PORT="0"
    run detect_ssh_ports
    [ "$output" = "22" ]
}

# ---------------------------------------------------------------------------
# detect_ssh_ports() - sshd -T / ss / listenaddress paths (mocked, CLI unset)
# ss is mocked silent in every case below so a real host sshd on the CI runner
# cannot leak its port into the union and make these tests flaky.
# ---------------------------------------------------------------------------

@test "RU detect: reads multiple ports from sshd -T" {
    _load_detect_fn "$RU_SCRIPT"
    command() { return 0; }            # `command -v sshd`/`ss` -> found
    sshd() { printf 'port 2022\nport 2200\n'; }
    ss() { :; }                        # silent: no real sockets
    export -f command sshd ss
    run detect_ssh_ports
    [ "$output" = "2022 2200" ]
}

@test "RU detect: extracts port from sshd -T listenaddress (IPv4 + bracketed IPv6)" {
    _load_detect_fn "$RU_SCRIPT"
    command() { return 0; }
    # `port 22` is the default sshd -T always prints; the real listener is on
    # the ListenAddress port. The union must keep BOTH (22 is harmless, 2222 is
    # the one that matters - missing it would lock the user out). Issue #91 / Codex HIGH.
    sshd() { printf 'port 22\nlistenaddress 0.0.0.0:2222\nlistenaddress [::]:2200\nlistenaddress 2001:db8::1\n'; }
    ss() { :; }
    export -f command sshd ss
    run detect_ssh_ports
    # 22 (port), 2222 (ipv4:port), 2200 (bracketed ipv6:port); bare IPv6 yields nothing
    [ "$output" = "22 2222 2200" ]
}

@test "RU detect: merges ss socket port with sshd -T (union, not fallback)" {
    _load_detect_fn "$RU_SCRIPT"
    command() { return 0; }
    sshd() { printf 'port 22\n'; }     # config default only
    ss() { printf 'LISTEN 0 128 0.0.0.0:2222 0.0.0.0:* users:(("sshd",pid=1,fd=3))\n'; }
    export -f command sshd ss
    run detect_ssh_ports
    [ "$output" = "22 2222" ]
}

@test "RU detect: leading-zero port normalised to decimal (no octal)" {
    _load_detect_fn "$RU_SCRIPT"
    CLI_SSH_PORT="022"
    run detect_ssh_ports
    [ "$output" = "22" ]
}

@test "EN detect: CLI override parity with RU" {
    _load_detect_fn "$EN_SCRIPT"
    CLI_SSH_PORT="2222,22"
    run detect_ssh_ports
    [ "$output" = "2222 22" ]
}

@test "EN detect: listenaddress + ss union parity with RU" {
    _load_detect_fn "$EN_SCRIPT"
    command() { return 0; }
    sshd() { printf 'port 22\nlistenaddress 0.0.0.0:2222\n'; }
    ss() { :; }
    export -f command sshd ss
    run detect_ssh_ports
    [ "$output" = "22 2222" ]
}

# ---------------------------------------------------------------------------
# Integration: setup_improved_firewall applies the detected port
# ---------------------------------------------------------------------------

_fw_mocks() {
    UFW_CALLS="$BATS_TEST_TMPDIR/ufw_calls"
    : > "$UFW_CALLS"
    ufw() {
        echo "$*" >> "$UFW_CALLS"
        case "$1" in
            status) echo "Status: inactive" ;;
            *)      return 0 ;;
        esac
    }
    ip() { echo "1.1.1.1 dev eth0 src 10.0.0.1 uid 0"; }
    command() { return 0; }
    install_packages() { return 0; }
    touch() { return 0; }
    die() { echo "DIE: $*"; return 1; }
    export -f ufw ip command install_packages touch die
    AWG_PORT=39743
    AWG_DIR="$BATS_TEST_TMPDIR"
    AUTO_YES=1
    export UFW_CALLS AWG_PORT AWG_DIR AUTO_YES
}

@test "RU integration: custom --ssh-port opens that port, not 22" {
    _load_fw_fns "$RU_SCRIPT"
    _fw_mocks
    CLI_SSH_PORT=2222
    export CLI_SSH_PORT
    run bash -c 'setup_improved_firewall < /dev/null'
    [ "$status" -eq 0 ]
    grep -q 'limit 2222/tcp' "$UFW_CALLS"
    run ! grep -q 'limit 22/tcp' "$UFW_CALLS"
}

@test "RU integration: comma list opens every port" {
    _load_fw_fns "$RU_SCRIPT"
    _fw_mocks
    CLI_SSH_PORT="2222,22"
    export CLI_SSH_PORT
    run bash -c 'setup_improved_firewall < /dev/null'
    [ "$status" -eq 0 ]
    grep -q 'limit 2222/tcp' "$UFW_CALLS"
    grep -q 'limit 22/tcp' "$UFW_CALLS"
}

@test "EN integration: custom --ssh-port opens that port, not 22" {
    _load_fw_fns "$EN_SCRIPT"
    _fw_mocks
    CLI_SSH_PORT=2222
    export CLI_SSH_PORT
    run bash -c 'setup_improved_firewall < /dev/null'
    [ "$status" -eq 0 ]
    grep -q 'limit 2222/tcp' "$UFW_CALLS"
    run ! grep -q 'limit 22/tcp' "$UFW_CALLS"
}

# ---------------------------------------------------------------------------
# RU/EN structural parity guards
# ---------------------------------------------------------------------------

@test "parity: both installers define detect_ssh_ports" {
    grep -qE '^detect_ssh_ports\(\) \{' "$RU_SCRIPT"
    grep -qE '^detect_ssh_ports\(\) \{' "$EN_SCRIPT"
}

@test "parity: no hardcoded 'ufw limit 22/tcp' command remains" {
    # Match the actual command line (optional indent, then `ufw`), not the
    # explanatory comment that mentions the old rule.
    run grep -cE '^[[:space:]]*ufw limit 22/tcp' "$RU_SCRIPT"
    [ "$output" -eq 0 ]
    run grep -cE '^[[:space:]]*ufw limit 22/tcp' "$EN_SCRIPT"
    [ "$output" -eq 0 ]
}

@test "parity: both loop ufw limit over detected ports" {
    grep -q 'ufw limit "${_sp}/tcp"' "$RU_SCRIPT"
    grep -q 'ufw limit "${_sp}/tcp"' "$EN_SCRIPT"
}
