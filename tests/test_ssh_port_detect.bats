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

# An explicit --ssh-port without a single valid port is refused (status 1,
# empty output) instead of silently becoming 22: setup_improved_firewall would
# otherwise enable UFW with `limit 22/tcp` only and lock out SSH on the real
# custom port. Mixed lists still keep their valid ports (next test).
@test "RU detect: invalid-only --ssh-port is refused, not replaced by 22" {
    _load_detect_fn "$RU_SCRIPT"
    local v
    for v in 99999 222222 abc 2222/tcp '2222;2223' ','; do
        CLI_SSH_PORT="$v"
        run detect_ssh_ports
        if [ "$status" -eq 0 ]; then echo "'$v': status 0, output '$output'"; return 1; fi
        if [ -n "$output" ]; then echo "'$v': non-empty output '$output'"; return 1; fi
    done
}

@test "EN detect: invalid-only --ssh-port is refused, not replaced by 22" {
    _load_detect_fn "$EN_SCRIPT"
    local v
    for v in 99999 222222 abc 2222/tcp '2222;2223' ','; do
        CLI_SSH_PORT="$v"
        run detect_ssh_ports
        if [ "$status" -eq 0 ]; then echo "'$v': status 0, output '$output'"; return 1; fi
        if [ -n "$output" ]; then echo "'$v': non-empty output '$output'"; return 1; fi
    done
}

# A long string of digits must be refused before any arithmetic: $((10#...))
# wraps modulo 2^64, so 18446744073709551638 became 22 and 18446744073709551617
# became 1 - the silent 22 again, through overflow. Leading zeros still work.
@test "RU+EN detect: overflowing --ssh-port is refused, leading zeros still parse" {
    local script v
    for script in "$RU_SCRIPT" "$EN_SCRIPT"; do
        _load_detect_fn "$script"
        for v in 18446744073709551638 18446744073709551617 100022 0000000000000000000000; do
            CLI_SSH_PORT="$v"
            run detect_ssh_ports
            if [ "$status" -eq 0 ]; then echo "$script '$v': status 0, output '$output'"; return 1; fi
            if [ -n "$output" ]; then echo "$script '$v': non-empty output '$output'"; return 1; fi
        done
        CLI_SSH_PORT="2222,18446744073709551638"
        run detect_ssh_ports
        if [ "$status" -eq 0 ] || [ -n "$output" ]; then echo "$script mixed with overflow accepted: '$output'"; return 1; fi
        CLI_SSH_PORT="0000000000000000000022"
        run detect_ssh_ports
        if [ "$output" != "22" ]; then echo "$script leading zeros: '$output'"; return 1; fi
    done
}

# An explicit list is refused as a whole if any element is not a port: with
# --ssh-port=22,500022 (one digit too many for 50022) dropping the bad element
# would enable UFW with 22 only and cut off SSH on the real port. An empty
# --ssh-port= is refused too instead of falling back to detection, and a glob
# in the value is not expanded against the current directory.
@test "RU+EN detect: an explicit list with any bad element, an empty value or a glob is refused" {
    local script v
    for script in "$RU_SCRIPT" "$EN_SCRIPT"; do
        _load_detect_fn "$script"
        for v in "2222,abc" "22,500022" "2222,,x" ""; do
            CLI_SSH_PORT="$v"; CLI_SSH_PORT_SET=1
            run detect_ssh_ports
            if [ "$status" -eq 0 ] || [ -n "$output" ]; then echo "$script '$v': accepted as '$output'"; return 1; fi
        done
        mkdir -p "$BATS_TEST_TMPDIR/g" && : > "$BATS_TEST_TMPDIR/g/2222"
        CLI_SSH_PORT='*'; CLI_SSH_PORT_SET=1
        run bash -c "cd '$BATS_TEST_TMPDIR/g' && $(declare -f detect_ssh_ports log_error log_warn); CLI_SSH_PORT='*' CLI_SSH_PORT_SET=1 detect_ssh_ports"
        if [ "$status" -eq 0 ] || [ -n "$output" ]; then echo "$script glob expanded to '$output'"; return 1; fi
        # Repeated and valid lists still work under the flag.
        CLI_SSH_PORT="2222,22,2222"; CLI_SSH_PORT_SET=1
        run detect_ssh_ports
        [ "$status" -eq 0 ] && [ "$output" = "2222 22" ] || { echo "$script valid list: '$output'"; return 1; }
    done
    unset CLI_SSH_PORT_SET
}

@test "RU+EN parse: an empty --ssh-port= still counts as given, and step 0 checks it" {
    local script
    for script in "$RU_SCRIPT" "$EN_SCRIPT"; do
        grep -qF -- '--ssh-port=*)    CLI_SSH_PORT="${1#*=}"; CLI_SSH_PORT_SET=1 ;;' "$script" \
            || { echo "$script: parser does not record the flag"; return 1; }
        [ "$(grep -c 'CLI_SSH_PORT_SET:-0}" -eq 1' "$script")" -ge 2 ] \
            || { echo "$script: detect or step 0 ignores an empty --ssh-port="; return 1; }
    done
}

@test "RU detect: boundary 65535 valid, 65536 and 0 invalid" {
    _load_detect_fn "$RU_SCRIPT"
    CLI_SSH_PORT="65535"
    run detect_ssh_ports
    [ "$output" = "65535" ]
    CLI_SSH_PORT="65536"
    run detect_ssh_ports
    [ "$status" -ne 0 ]
    [ "$output" = "" ]
    CLI_SSH_PORT="0"
    run detect_ssh_ports
    [ "$status" -ne 0 ]
    [ "$output" = "" ]
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
    # the one that matters - missing it would lock the user out). Issue #91 / review HIGH.
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

# An --ssh-port value without a single valid port must stop the firewall setup
# before ANY ufw call. Before the fix it became 22 with a warning only, and
# with --yes on an inactive UFW the installer ran `default deny incoming`,
# `limit 22/tcp` and `--force enable` - SSH on 2222 was cut off. die is
# redefined to exit, as the real one does (the _fw_mocks stub only returns 1).
_assert_bad_ssh_port_stops_ufw() {
    _load_fw_fns "$1"
    _fw_mocks
    die() { echo "DIE: $*"; exit 1; }
    export -f die
    CLI_SSH_PORT='2222/tcp'
    PREV_AWG_PORT=40000
    CONFIG_FILE="$BATS_TEST_TMPDIR/awgsetup_cfg.init"
    : > "$CONFIG_FILE"
    export CLI_SSH_PORT PREV_AWG_PORT CONFIG_FILE
    run bash -c 'setup_improved_firewall < /dev/null'
    if grep -qx -- '--force enable' "$UFW_CALLS"; then
        echo "UFW enabled despite invalid --ssh-port; ufw calls:"; cat "$UFW_CALLS"; return 1
    fi
    if grep -q 'limit 22/tcp' "$UFW_CALLS"; then
        echo "limit 22/tcp applied for --ssh-port=2222/tcp; ufw calls:"; cat "$UFW_CALLS"; return 1
    fi
    if grep -qx 'default deny incoming' "$UFW_CALLS"; then
        echo "default deny incoming applied; ufw calls:"; cat "$UFW_CALLS"; return 1
    fi
    if [ -s "$UFW_CALLS" ]; then
        echo "ufw was called before the refusal:"; cat "$UFW_CALLS"; return 1
    fi
    [ "$status" -ne 0 ]
    [[ "$output" == *"DIE: "*"--ssh-port"* ]]
}

@test "RU integration: --ssh-port without a valid port stops before any ufw call" {
    _assert_bad_ssh_port_stops_ufw "$RU_SCRIPT"
}

@test "EN integration: --ssh-port without a valid port stops before any ufw call" {
    _assert_bad_ssh_port_stops_ufw "$EN_SCRIPT"
}

# Step 0 checks --ssh-port, so a broken value stops the run before package
# upgrades and reboots rather than at step 4. initialize_setup is too large to
# run in a unit test: check that its body holds the guard, then run that guard
# with the real detect_ssh_ports and an exiting die.
@test "initialize_setup RU/EN: step 0 refuses --ssh-port without a valid port" {
    local script body guard
    for script in "$RU_SCRIPT" "$EN_SCRIPT"; do
        body=$(sed -n '/^initialize_setup() {/,/^}/p' "$script")
        guard=$(awk '/^    if \[\[ -n "\$CLI_SSH_PORT" [|][|] "\$[{]CLI_SSH_PORT_SET:-0[}]" -eq 1 \]\]; then$/,/^    fi$/' <<< "$body")
        if [[ "$guard" != *'detect_ssh_ports >/dev/null'* || "$guard" != *'|| die '* ]]; then
            echo "no --ssh-port check via detect_ssh_ports inside initialize_setup of $script"; return 1
        fi
        # The point of the step 0 check is to stop BEFORE the init file is
        # written and the install moves on to upgrades and reboots.
        local gl wl
        gl=$(grep -n 'detect_ssh_ports >/dev/null' <<< "$body" | head -1 | cut -d: -f1)
        wl=$(grep -n 'cat > "\$temp_conf" << EOF' <<< "$body" | head -1 | cut -d: -f1)
        if [ -z "$gl" ] || [ -z "$wl" ] || [ "$gl" -ge "$wl" ]; then
            echo "$script: --ssh-port check (line ${gl:-?}) is not before the init write (line ${wl:-?})"; return 1
        fi
        _load_detect_fn "$script"
        die() { echo "DIE: $*"; exit 1; }
        export -f detect_ssh_ports die
        export GUARD="$guard"
        export CLI_SSH_PORT='2222/tcp'
        run bash -c 'eval "$GUARD"; echo passed'
        if [ "$status" -eq 0 ]; then echo "$script: step 0 guard let 2222/tcp through: $output"; return 1; fi
        export CLI_SSH_PORT='2222,abc'
        run bash -c 'eval "$GUARD"; echo passed'
        if [ "$status" -eq 0 ]; then echo "$script: step 0 guard let 2222,abc through: $output"; return 1; fi
        export CLI_SSH_PORT='2222,22'
        run bash -c 'eval "$GUARD"; echo passed'
        if [ "$status" -ne 0 ] || [ "$output" != "passed" ]; then echo "$script: step 0 guard refused 2222,22: $output"; return 1; fi
        # Flag absent: nothing to check. Flag given empty: refused.
        export CLI_SSH_PORT='' CLI_SSH_PORT_SET=0
        run bash -c 'eval "$GUARD"; echo passed'
        if [ "$status" -ne 0 ] || [ "$output" != "passed" ]; then echo "$script: step 0 guard fired without the flag: $output"; return 1; fi
        export CLI_SSH_PORT_SET=1
        run bash -c 'eval "$GUARD"; echo passed'
        if [ "$status" -eq 0 ]; then echo "$script: step 0 guard let an empty --ssh-port= through: $output"; return 1; fi
        unset CLI_SSH_PORT_SET
    done
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
