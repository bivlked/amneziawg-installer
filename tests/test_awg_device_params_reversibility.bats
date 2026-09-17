#!/usr/bin/env bats
# Tests for the three helpers added alongside the AWG 3.0 groundwork:
#
#   awg_module_version              - loaded module beats the file on disk
#   awg_session_via_tunnel          - "am I connected through this very VPN"
#   _awg_device_params_fingerprint  - which device parameters the config carries
#   _awg_tunnel_subnet              - the subnet comes from reality, never a default
#   apply_config                    - a REMOVED device parameter is REPORTED and
#                                     deliberately NOT restarted for you: syncconf
#                                     cannot clear those, and a false positive
#                                     would drop every client connection
#
# Own setup() (like test_apply_config.bats) because these need stub binaries in
# PATH and awg_common.sh sourced directly.

load test_helper

setup() {
    TEST_DIR=$(mktemp -d)
    export AWG_DIR="$TEST_DIR"
    export CONFIG_FILE="$TEST_DIR/awgsetup_cfg.init"
    export SERVER_CONF_FILE="$TEST_DIR/awg0.conf"
    export KEYS_DIR="$TEST_DIR/keys"
    mkdir -p "$KEYS_DIR"

    log()       { :; }
    log_warn()  { :; }
    log_error() { :; }
    log_debug() { :; }
    export -f log log_warn log_error log_debug

    MOCK_BIN="$TEST_DIR/mock_bin"
    mkdir -p "$MOCK_BIN"
    export PATH="$MOCK_BIN:$PATH"

    cat > "$MOCK_BIN/systemctl" << 'STUB'
#!/bin/bash
echo "systemctl $*" >> "${AWG_DIR}/.mock_calls"
exit 0
STUB
    cat > "$MOCK_BIN/awg-quick" << 'STUB'
#!/bin/bash
echo "awg-quick $*" >> "${AWG_DIR}/.mock_calls"
echo "[Interface]"
echo "PrivateKey = TEST"
exit 0
STUB
    cat > "$MOCK_BIN/awg" << 'STUB'
#!/bin/bash
echo "awg $*" >> "${AWG_DIR}/.mock_calls"
exit 0
STUB
    cat > "$MOCK_BIN/timeout" << 'STUB'
#!/bin/bash
shift
"$@"
STUB
    # modinfo stub: the "file on disk" answer, deliberately different from the
    # loaded-module answer so the priority between them is observable.
    cat > "$MOCK_BIN/modinfo" << 'STUB'
#!/bin/bash
echo "filename:       /lib/modules/test/updates/dkms/amneziawg.ko"
echo "version:        3.0.FROM-MODINFO"
exit 0
STUB
    # ip: by default awg0 does NOT exist. Without this the suite goes red on a
    # real AWG server - exactly where our runbook does final testing - because
    # _awg_tunnel_subnet asks the live interface FIRST and it beats an exported
    # AWG_TUNNEL_SUBNET. Tests that want a live interface stub it themselves.
    cat > "$MOCK_BIN/ip" << 'STUB'
#!/bin/bash
exit 1
STUB
    chmod +x "$MOCK_BIN"/*

    source "$BATS_TEST_DIRNAME/../awg_common.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

write_conf() {
    # $1 - extra [Interface] lines
    cat > "$SERVER_CONF_FILE" << EOF
[Interface]
PrivateKey = TESTKEY
Address = 10.9.9.1/24
ListenPort = 51820
$1

[Peer]
PublicKey = PEERKEY
AllowedIPs = 10.9.9.2/32
EOF
}

# ---------------------------------------------------------------- module version

@test "awg_module_version: loaded module wins over modinfo" {
    printf '2.0.FROM-SYSFS\n' > "$TEST_DIR/loaded_version"
    export AWG_MODULE_VERSION_PATH="$TEST_DIR/loaded_version"
    run awg_module_version
    [ "$status" -eq 0 ]
    [ "$output" = "2.0.FROM-SYSFS" ]
}

@test "awg_module_version: falls back to modinfo when the module is not loaded" {
    export AWG_MODULE_VERSION_PATH="$TEST_DIR/does_not_exist"
    run awg_module_version
    [ "$status" -eq 0 ]
    [ "$output" = "3.0.FROM-MODINFO" ]
}

@test "awg_module_version: a file without a trailing newline is still read" {
    # read returns 1 on such a file having already assigned the value; an
    # over-eager reset would wipe it and fall through to modinfo unnoticed.
    printf '2.0.NO-NEWLINE' > "$TEST_DIR/loaded_version"
    export AWG_MODULE_VERSION_PATH="$TEST_DIR/loaded_version"
    run awg_module_version
    [ "$status" -eq 0 ]
    [ "$output" = "2.0.NO-NEWLINE" ]
}

@test "awg_module_version: surrounding whitespace is trimmed" {
    printf '  3.0.PADDED \n' > "$TEST_DIR/loaded_version"
    export AWG_MODULE_VERSION_PATH="$TEST_DIR/loaded_version"
    run awg_module_version
    [ "$status" -eq 0 ]
    [ "$output" = "3.0.PADDED" ]
}

@test "awg_module_version: empty when neither source answers" {
    export AWG_MODULE_VERSION_PATH="$TEST_DIR/does_not_exist"
    cat > "$MOCK_BIN/modinfo" << 'STUB'
#!/bin/bash
exit 1
STUB
    chmod +x "$MOCK_BIN/modinfo"
    run awg_module_version
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ------------------------------------------------------------- session detection

# These three exercise the SSH_CONNECTION path. `who`/`ps` are silenced on
# purpose: utmp now takes priority, so without stubbing them the real utmp of
# whatever machine runs the suite could decide the outcome.
silence_utmp() {
    printf '#!/bin/bash\nexit 0\n' > "$MOCK_BIN/who"
    printf '#!/bin/bash\nexit 0\n' > "$MOCK_BIN/ps"
    chmod +x "$MOCK_BIN/who" "$MOCK_BIN/ps"
}

@test "awg_session_via_tunnel: address inside the tunnel subnet returns 0" {
    silence_utmp
    export AWG_TUNNEL_SUBNET="10.9.9.1/24"
    export SSH_CONNECTION="10.9.9.5 51000 10.9.9.1 22"
    run awg_session_via_tunnel
    [ "$status" -eq 0 ]
}

@test "awg_session_via_tunnel: address outside the subnet returns 1" {
    silence_utmp
    export AWG_TUNNEL_SUBNET="10.9.9.1/24"
    export SSH_CONNECTION="203.0.113.7 51000 198.51.100.4 22"
    run awg_session_via_tunnel
    [ "$status" -eq 1 ]
}

@test "awg_session_via_tunnel: hostname instead of an address returns 2 (unknown)" {
    silence_utmp
    export AWG_TUNNEL_SUBNET="10.9.9.1/24"
    export SSH_CONNECTION="client.example.org 51000 198.51.100.4 22"
    run awg_session_via_tunnel
    [ "$status" -eq 2 ]
}

@test "awg_session_via_tunnel: no session data at all returns 2 (unknown)" {
    export AWG_TUNNEL_SUBNET="10.9.9.1/24"
    unset SSH_CONNECTION
    # Silence both discovery paths so the result does not depend on the host.
    printf '#!/bin/bash\nexit 0\n' > "$MOCK_BIN/who"
    printf '#!/bin/bash\nexit 0\n' > "$MOCK_BIN/ps"
    chmod +x "$MOCK_BIN/who" "$MOCK_BIN/ps"
    run awg_session_via_tunnel
    [ "$status" -eq 2 ]
}

# The `who` path is what actually runs on a real server, because SSH_CONNECTION
# does not survive sudo. These cases pin that it either answers correctly or
# says "unknown" - never a confident wrong verdict.

stub_who() {
    printf '#!/bin/bash\nprintf "%%s\\n" %s\n' "$(printf '%q' "$1")" > "$MOCK_BIN/who"
    printf '#!/bin/bash\necho pts/0\n' > "$MOCK_BIN/ps"
    chmod +x "$MOCK_BIN/who" "$MOCK_BIN/ps"
    unset SSH_CONNECTION
    export AWG_TUNNEL_SUBNET="10.9.9.1/24"
}

@test "who path: tunnel address is recognised" {
    stub_who 'root pts/0 2026-08-08 01:00 (10.9.9.5)'
    run awg_session_via_tunnel
    [ "$status" -eq 0 ]
}

@test "who path: external address is recognised" {
    stub_who 'root pts/0 2026-08-08 01:00 (203.0.113.5)'
    run awg_session_via_tunnel
    [ "$status" -eq 1 ]
}

@test "who path: IPv6 source yields unknown, not a guess" {
    stub_who 'root pts/0 2026-08-08 01:00 (2001:db8::1)'
    run awg_session_via_tunnel
    [ "$status" -eq 2 ]
}

@test "who path: a session on another tty is not picked up" {
    stub_who 'root pts/1 2026-08-08 01:00 (10.9.9.7)'
    run awg_session_via_tunnel
    [ "$status" -eq 2 ]
}

@test "who path: parentheses inside the source do not produce a verdict" {
    stub_who 'root pts/0 2026-08-08 01:00 (host (weird))'
    run awg_session_via_tunnel
    [ "$status" -eq 2 ]
}

@test "who path: a local X session is not mistaken for SSH" {
    stub_who 'biv :0 2026-08-08 01:00 (:0)'
    run awg_session_via_tunnel
    [ "$status" -eq 2 ]
}

@test "who path: utmp wins over an inherited SSH_CONNECTION" {
    # A reattached tmux/screen session can carry SSH_CONNECTION from the
    # PREVIOUS connection. utmp keyed on our own tty describes the current one,
    # so it has to win - otherwise the verdict is confidently wrong.
    stub_who 'root pts/0 2026-08-08 01:00 (10.9.9.5)'
    export SSH_CONNECTION="203.0.113.9 51000 198.51.100.1 22"
    run awg_ssh_client_addr
    [ "$output" = "10.9.9.5" ]
    run awg_session_via_tunnel
    [ "$status" -eq 0 ]
}

@test "who path: SSH_CONNECTION is used when utmp gives a hostname" {
    # With UseDNS yes utmp holds a name, which cannot be matched against a
    # subnet. Falling back to the variable beats answering "unknown".
    stub_who 'root pts/0 2026-08-08 01:00 (client.example.org)'
    export SSH_CONNECTION="10.9.9.5 51000 10.9.9.1 22"
    run awg_session_via_tunnel
    [ "$status" -eq 0 ]
}

@test "awg_session_via_tunnel: a non-tunnel subnet does not produce a false positive" {
    silence_utmp
    export AWG_TUNNEL_SUBNET="10.9.9.1/24"
    export SSH_CONNECTION="10.9.10.5 51000 10.9.9.1 22"
    run awg_session_via_tunnel
    [ "$status" -eq 1 ]
}

# ------------------------------------------------------------------ fingerprint

@test "_awg_device_params_fingerprint: collects 2.0 and 3.0 names, sorted" {
    write_conf "Jc = 4
S1 = 100
H1 = 1234567
I1 = <b 0xdeadbeef>
HeaderProtectionKey = AAAA"
    run _awg_device_params_fingerprint
    [ "$status" -eq 0 ]
    [ "$output" = "H1 HeaderProtectionKey I1 Jc S1" ]
}

@test "_awg_device_params_fingerprint: ignores comments and the [Peer] section" {
    cat > "$SERVER_CONF_FILE" << 'EOF'
[Interface]
PrivateKey = TESTKEY
# Jc = 99
S1 = 100

[Peer]
PublicKey = PEERKEY
H1 = 777
EOF
    run _awg_device_params_fingerprint
    [ "$status" -eq 0 ]
    [ "$output" = "S1" ]
}

@test "_awg_device_params_fingerprint: tolerates missing spaces around =" {
    write_conf "Jc=4
S4=12"
    run _awg_device_params_fingerprint
    [ "$status" -eq 0 ]
    [ "$output" = "Jc S4" ]
}

@test "_awg_device_params_fingerprint: unreadable config returns 1" {
    rm -f "$SERVER_CONF_FILE"
    run _awg_device_params_fingerprint
    [ "$status" -eq 1 ]
}

# ----------------------------------------------- apply_config: removal detection

@test "apply_config: a removed device parameter is reported and does NOT trigger a restart" {
    require_flock
    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=syncconf

    # First apply records the set {Jc, S1}.
    write_conf "Jc = 4
S1 = 100"
    run apply_config
    [ "$status" -eq 0 ]
    grep -q "awg syncconf" "$AWG_DIR/.mock_calls"
    [ -f "$AWG_DIR/.awg_device_params" ]

    # S1 disappears from the config. syncconf will silently NOT clear it, so the
    # operator has to be told - but we must NOT restart on our own, because a
    # false positive would drop every client connection.
    rm -f "$AWG_DIR/.mock_calls"
    log_warn() { echo "$*" >> "$AWG_DIR/.warns"; }
    write_conf "Jc = 4"
    run apply_config
    [ "$status" -eq 0 ]
    grep -q "awg syncconf" "$AWG_DIR/.mock_calls"
    # NOT `! grep`: in Bats a leading ! does not fail the test (SC2314), so that
    # form silently asserts nothing. Count instead.
    run grep -c "systemctl restart" "$AWG_DIR/.mock_calls"
    [ "$output" = "0" ]
    grep -q "S1" "$AWG_DIR/.warns"
    grep -q "systemctl restart awg-quick@awg0" "$AWG_DIR/.warns"
}

@test "apply_config: the removal warning does not repeat on the next apply" {
    require_flock
    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=syncconf
    log_warn() { echo "$*" >> "$AWG_DIR/.warns"; }

    write_conf "Jc = 4
S1 = 100"
    run apply_config
    write_conf "Jc = 4"
    run apply_config
    local first
    first=$(grep -c "S1" "$AWG_DIR/.warns")
    [ "$first" -ge 1 ]

    # Nothing changed since; the snapshot was refreshed, so it must stay quiet.
    run apply_config
    [ "$status" -eq 0 ]
    [ "$(grep -c "S1" "$AWG_DIR/.warns")" -eq "$first" ]
}

@test "apply_config: an empty parameter set is not treated as a removal" {
    require_flock
    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=syncconf
    log_warn() { echo "$*" >> "$AWG_DIR/.warns"; }

    write_conf "Jc = 4
S1 = 100"
    run apply_config

    # A config being rewritten can momentarily hold no AWG parameters at all.
    # Reading that as "everything was removed" would be a false alarm, and our
    # generator always writes Jc/S/H, so emptiness means a partial read.
    write_conf ""
    run apply_config
    [ "$status" -eq 0 ]
    [ ! -f "$AWG_DIR/.warns" ]
}

@test "apply_config: an empty read does NOT overwrite the good snapshot" {
    require_flock
    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=syncconf

    write_conf "Jc = 4
S1 = 100"
    run apply_config
    [ "$(cat "$AWG_DIR/.awg_device_params")" = "Jc S1" ]

    # Storing an empty snapshot would disable detection FOREVER: there would be
    # nothing left to compare against. The previous good set has to survive.
    write_conf ""
    run apply_config
    [ "$status" -eq 0 ]
    [ "$(cat "$AWG_DIR/.awg_device_params")" = "Jc S1" ]

    # And once the file is whole again, a real removal is still caught.
    log_warn() { echo "$*" >> "$AWG_DIR/.warns"; }
    write_conf "Jc = 4"
    run apply_config
    [ "$status" -eq 0 ]
    grep -q "S1" "$AWG_DIR/.warns"
}

@test "apply_config: a failed apply keeps the warning alive for the next run" {
    require_flock
    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=syncconf
    log_warn() { echo "$*" >> "$AWG_DIR/.warns"; }

    write_conf "Jc = 4
S1 = 100"
    run apply_config

    # Everything the apply could use now fails, so nothing reaches the
    # interface. Refreshing the snapshot here would silence the warning forever
    # while the live interface still carries S1.
    printf '#!/bin/bash\nexit 1\n' > "$MOCK_BIN/awg-quick"
    printf '#!/bin/bash\nexit 1\n' > "$MOCK_BIN/awg"
    printf '#!/bin/bash\nexit 1\n' > "$MOCK_BIN/systemctl"
    chmod +x "$MOCK_BIN/awg-quick" "$MOCK_BIN/awg" "$MOCK_BIN/systemctl"
    write_conf "Jc = 4"
    run apply_config
    [ "$status" -ne 0 ]
    [ "$(cat "$AWG_DIR/.awg_device_params")" = "Jc S1" ]

    # Recovery: the tools work again, and the operator is told once more.
    rm -f "$AWG_DIR/.warns"
    printf '#!/bin/bash\necho "[Interface]"\nexit 0\n' > "$MOCK_BIN/awg-quick"
    printf '#!/bin/bash\nexit 0\n' > "$MOCK_BIN/awg"
    printf '#!/bin/bash\nexit 0\n' > "$MOCK_BIN/systemctl"
    chmod +x "$MOCK_BIN/awg-quick" "$MOCK_BIN/awg" "$MOCK_BIN/systemctl"
    run apply_config
    [ "$status" -eq 0 ]
    grep -q "S1" "$AWG_DIR/.warns"
}

@test "awg_record_device_params: recomputes from the file, refuses to store empty" {
    write_conf "Jc = 4
H1 = 7"
    awg_record_device_params
    [ "$(cat "$AWG_DIR/.awg_device_params")" = "H1 Jc" ]

    write_conf ""
    awg_record_device_params
    [ "$(cat "$AWG_DIR/.awg_device_params")" = "H1 Jc" ]

    rm -f "$SERVER_CONF_FILE"
    awg_record_device_params
    [ "$(cat "$AWG_DIR/.awg_device_params")" = "H1 Jc" ]
}

@test "awg_record_device_params: leaves no temp file behind" {
    write_conf "Jc = 4"
    awg_record_device_params
    run bash -c "ls \"$AWG_DIR\"/.awg_device_params.tmp 2>/dev/null | wc -l"
    [ "$output" = "0" ]
}

@test "parity: interface recreation refreshes the snapshot in both languages" {
    # manage restart, restore and the installer all recreate the interface. If
    # they do not refresh the snapshot, a parameter ADDED that way makes a later
    # removal invisible: apply_config would compare "absent against absent".
    for f in "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh" \
             "$BATS_TEST_DIRNAME/../install_amneziawg.sh" "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"; do
        run grep -c 'awg_record_device_params' "$f"
        [ "$output" -ge 1 ]
    done
    # Both manage scripts must do it on restart AND on restore, so two calls.
    for f in "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"; do
        run grep -c 'awg_record_device_params' "$f"
        [ "$output" -ge 2 ]
    done
}

@test "parity: awg_record_device_params identical in RU and EN" {
    local ru en
    ru=$(parity_body "$BATS_TEST_DIRNAME/../awg_common.sh" awg_record_device_params)
    en=$(parity_body "$BATS_TEST_DIRNAME/../awg_common_en.sh" awg_record_device_params)
    [ -n "$ru" ]
    [ "$ru" = "$en" ]
}

@test "parity: explicit apply-mode=restart warns about the disruption" {
    # Deleting the warning call from that branch must not go unnoticed.
    for f in "$BATS_TEST_DIRNAME/../awg_common.sh" "$BATS_TEST_DIRNAME/../awg_common_en.sh"; do
        local mode_line warn_line
        mode_line=$(grep -n 'AWG_APPLY_MODE:-syncconf' "$f" | head -1 | cut -d: -f1)
        warn_line=$(grep -n 'awg_warn_interface_disruption$' "$f" | awk -F: -v m="$mode_line" '$1 > m {print $1; exit}')
        [ -n "$mode_line" ]
        [ -n "$warn_line" ]
        [ "$((warn_line - mode_line))" -lt 6 ]
    done
}

@test "apply_config: an ADDED parameter still goes through syncconf" {
    require_flock
    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=syncconf

    write_conf "Jc = 4"
    run apply_config
    [ "$status" -eq 0 ]

    rm -f "$AWG_DIR/.mock_calls"
    write_conf "Jc = 4
S1 = 100"
    run apply_config
    [ "$status" -eq 0 ]
    grep -q "awg syncconf" "$AWG_DIR/.mock_calls"
    # NOT `! grep`: in Bats a leading ! does not fail the test (SC2314), so that
    # form silently asserts nothing. Count instead.
    run grep -c "systemctl restart" "$AWG_DIR/.mock_calls"
    [ "$output" = "0" ]
}

@test "apply_config: an unchanged parameter set goes through syncconf" {
    require_flock
    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=syncconf

    write_conf "Jc = 4
S1 = 100"
    run apply_config
    [ "$status" -eq 0 ]

    rm -f "$AWG_DIR/.mock_calls"
    write_conf "Jc = 8
S1 = 200"
    run apply_config
    [ "$status" -eq 0 ]
    grep -q "awg syncconf" "$AWG_DIR/.mock_calls"
    # NOT `! grep`: in Bats a leading ! does not fail the test (SC2314), so that
    # form silently asserts nothing. Count instead.
    run grep -c "systemctl restart" "$AWG_DIR/.mock_calls"
    [ "$output" = "0" ]
}

@test "apply_config: no state file means no spurious restart on the first run" {
    require_flock
    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=syncconf
    write_conf "Jc = 4
S1 = 100"
    rm -f "$AWG_DIR/.awg_device_params"
    run apply_config
    [ "$status" -eq 0 ]
    grep -q "awg syncconf" "$AWG_DIR/.mock_calls"
    # NOT `! grep`: in Bats a leading ! does not fail the test (SC2314), so that
    # form silently asserts nothing. Count instead.
    run grep -c "systemctl restart" "$AWG_DIR/.mock_calls"
    [ "$output" = "0" ]
}

@test "apply_config: state is recorded in apply-mode=restart as well" {
    require_flock
    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=restart
    write_conf "Jc = 4
S1 = 100"
    run apply_config
    [ "$status" -eq 0 ]
    run cat "$AWG_DIR/.awg_device_params"
    [ "$output" = "Jc S1" ]
}

# -------------------------------------------------------------- RU/EN parity
#
# Bodies must stay identical apart from comments and localized messages.
# Without this the two language versions drift silently: the RU one gets a fix
# and the EN one keeps the old behaviour, and nothing fails.

parity_body() {
    local file="$1" fn="$2"
    # Log lines are NORMALIZED, not deleted. Deleting them hid two classes of
    # divergence: the EN branch could lose EVERY message and still compare as
    # identical, and code appended to a log line (log_warn "..." ; return 0)
    # vanished from the comparison along with it. After normalization the count,
    # order and nesting of the calls are compared, and only the text differs.
    awk "/^${fn}\\(\\) \\{\$/,/^}\$/" "$file" \
        | grep -v '^[[:space:]]*#' \
        | sed -E 's/^([[:space:]]*log(_warn|_debug|_error)?)[[:space:]]+".*/\1 <MSG>/'
}

@test "parity: awg_module_version identical in RU and EN" {
    local ru en
    ru=$(parity_body "$BATS_TEST_DIRNAME/../awg_common.sh" awg_module_version)
    en=$(parity_body "$BATS_TEST_DIRNAME/../awg_common_en.sh" awg_module_version)
    [ -n "$ru" ]
    [ "$ru" = "$en" ]
}

@test "parity: awg_ssh_client_addr identical in RU and EN" {
    local ru en
    ru=$(parity_body "$BATS_TEST_DIRNAME/../awg_common.sh" awg_ssh_client_addr)
    en=$(parity_body "$BATS_TEST_DIRNAME/../awg_common_en.sh" awg_ssh_client_addr)
    [ -n "$ru" ]
    [ "$ru" = "$en" ]
}

@test "parity: awg_session_via_tunnel identical in RU and EN" {
    local ru en
    ru=$(parity_body "$BATS_TEST_DIRNAME/../awg_common.sh" awg_session_via_tunnel)
    en=$(parity_body "$BATS_TEST_DIRNAME/../awg_common_en.sh" awg_session_via_tunnel)
    [ -n "$ru" ]
    [ "$ru" = "$en" ]
}

@test "parity: _awg_device_param_names identical in RU and EN" {
    local ru en
    ru=$(parity_body "$BATS_TEST_DIRNAME/../awg_common.sh" _awg_device_param_names)
    en=$(parity_body "$BATS_TEST_DIRNAME/../awg_common_en.sh" _awg_device_param_names)
    [ -n "$ru" ]
    [ "$ru" = "$en" ]
}

@test "parity: _awg_device_params_fingerprint identical in RU and EN" {
    local ru en
    ru=$(parity_body "$BATS_TEST_DIRNAME/../awg_common.sh" _awg_device_params_fingerprint)
    en=$(parity_body "$BATS_TEST_DIRNAME/../awg_common_en.sh" _awg_device_params_fingerprint)
    [ -n "$ru" ]
    [ "$ru" = "$en" ]
}

@test "parity: awg_warn_interface_disruption structure identical in RU and EN" {
    local ru en
    ru=$(parity_body "$BATS_TEST_DIRNAME/../awg_common.sh" awg_warn_interface_disruption)
    en=$(parity_body "$BATS_TEST_DIRNAME/../awg_common_en.sh" awg_warn_interface_disruption)
    [ -n "$ru" ]
    [ "$ru" = "$en" ]
}

@test "parity: both manage scripts warn before confirming a restart" {
    for f in "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"; do
        # The warning must come BEFORE confirm_action, otherwise --yes runs
        # never see it - which is exactly the case that cuts people off.
        local warn_line confirm_line
        warn_line=$(grep -n 'awg_warn_interface_disruption' "$f" | head -1 | cut -d: -f1)
        confirm_line=$(grep -n 'confirm_action "' "$f" | awk -F: -v w="$warn_line" '$1 > w {print $1; exit}')
        [ -n "$warn_line" ]
        [ -n "$confirm_line" ]
        [ "$warn_line" -lt "$confirm_line" ]
    done
}

@test "parity: neither manage script still reads the module version from modinfo" {
    for f in "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"; do
        run grep -c 'modinfo amneziawg 2>/dev/null | awk' "$f"
        [ "$output" = "0" ]
    done
}

@test "parity: the ARM prebuilt path holds amneziawg-dkms in both installers" {
    for f in "$BATS_TEST_DIRNAME/../install_amneziawg.sh" "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"; do
        # The hold has to sit between the prebuilt success and the tools install,
        # otherwise apt pulls the DKMS 3.0 module next to the prebuilt 2.0 one.
        local prebuilt hold tools
        prebuilt=$(grep -n 'if _try_install_prebuilt_arm; then' "$f" | head -1 | cut -d: -f1)
        hold=$(grep -n 'apt-mark hold amneziawg-dkms' "$f" | awk -F: -v p="$prebuilt" '$1 > p {print $1; exit}')
        tools=$(grep -n 'install_packages "amneziawg-tools"' "$f" | awk -F: -v p="$prebuilt" '$1 > p {print $1; exit}')
        [ -n "$prebuilt" ]
        [ -n "$hold" ]
        [ -n "$tools" ]
        [ "$hold" -gt "$prebuilt" ]
        [ "$hold" -lt "$tools" ]
    done
}

@test "apply_config: state is NOT updated when the restart fails" {
    require_flock
    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=restart
    write_conf "Jc = 4
S1 = 100"
    run apply_config
    [ "$status" -eq 0 ]

    cat > "$MOCK_BIN/systemctl" << 'STUB'
#!/bin/bash
echo "systemctl $*" >> "${AWG_DIR}/.mock_calls"
exit 1
STUB
    chmod +x "$MOCK_BIN/systemctl"
    write_conf "Jc = 4"
    run apply_config
    [ "$status" -ne 0 ]
    # The old set survives, so the next successful run still knows S1 was dropped.
    run cat "$AWG_DIR/.awg_device_params"
    [ "$output" = "Jc S1" ]
}

# --------------------------------------------------- tunnel subnet (critical)
#
# The verdict is only as good as the subnet it is measured against. An earlier
# revision substituted a hardcoded 10.9.9.1/24, and since `manage restart` never
# loads awgsetup_cfg.init, anyone who installed with --subnet got a confident
# "you are NOT through the tunnel" while being exactly that.

@test "subnet: a custom subnet from the config is honoured, not a hardcoded default" {
    printf '#!/bin/bash\nexit 1\n' > "$MOCK_BIN/ip"
    chmod +x "$MOCK_BIN/ip"
    cat > "$SERVER_CONF_FILE" << 'CONF'
[Interface]
PrivateKey = TESTKEY
Address = 10.66.66.1/24
ListenPort = 51820
Jc = 4
CONF
    unset AWG_TUNNEL_SUBNET
    silence_utmp
    export SSH_CONNECTION="10.66.66.2 51000 10.66.66.1 22"
    run awg_session_via_tunnel
    [ "$status" -eq 0 ]
}

@test "subnet: the live interface wins over the config" {
    printf '#!/bin/bash\necho "5: awg0    inet 10.66.66.1/24 scope global awg0"\n' > "$MOCK_BIN/ip"
    chmod +x "$MOCK_BIN/ip"
    write_conf "Jc = 4"
    unset AWG_TUNNEL_SUBNET
    silence_utmp
    # write_conf puts Address = 10.9.9.1/24 in the file; the live interface says
    # otherwise, and the live interface is the authority.
    export SSH_CONNECTION="10.66.66.2 51000 10.66.66.1 22"
    run awg_session_via_tunnel
    [ "$status" -eq 0 ]
}

@test "subnet: unknown subnet yields unknown, never a guess" {
    printf '#!/bin/bash\nexit 1\n' > "$MOCK_BIN/ip"
    chmod +x "$MOCK_BIN/ip"
    rm -f "$SERVER_CONF_FILE"
    unset AWG_TUNNEL_SUBNET
    silence_utmp
    export SSH_CONNECTION="10.9.9.5 51000 10.9.9.1 22"
    run awg_session_via_tunnel
    [ "$status" -eq 2 ]
}

@test "subnet: an IPv6 Address line does not become the subnet" {
    printf '#!/bin/bash\nexit 1\n' > "$MOCK_BIN/ip"
    chmod +x "$MOCK_BIN/ip"
    cat > "$SERVER_CONF_FILE" << 'CONF'
[Interface]
Address = fddd:2c4:2c4:2c4::1/64, 10.66.66.1/24
Jc = 4
CONF
    unset AWG_TUNNEL_SUBNET
    run _awg_tunnel_subnet
    [ "$output" = "10.66.66.1/24" ]
}

@test "parity: _awg_tunnel_subnet identical in RU and EN" {
    local ru en
    ru=$(parity_body "$BATS_TEST_DIRNAME/../awg_common.sh" _awg_tunnel_subnet)
    en=$(parity_body "$BATS_TEST_DIRNAME/../awg_common_en.sh" _awg_tunnel_subnet)
    [ -n "$ru" ]
    [ "$ru" = "$en" ]
}

@test "module version: a readable but empty sysfs file does not fall back to modinfo" {
    # Falling back there would reintroduce the very defect this function exists
    # to remove: modinfo can name a version that is not running in the kernel.
    : > "$TEST_DIR/loaded_version"
    export AWG_MODULE_VERSION_PATH="$TEST_DIR/loaded_version"
    run awg_module_version
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "snapshot write failure is reported at warn level, not debug" {
    # log_debug prints only with --verbose and never reaches the log file, so a
    # lost snapshot used to look exactly like success.
    log_warn() { echo "$*" >> "$AWG_DIR/.warns"; }
    run _awg_save_device_params "$TEST_DIR/nonexistent-dir/state" "Jc S1"
    [ "$status" -eq 0 ]
    grep -q "снимок\|snapshot" "$AWG_DIR/.warns"
}

@test "parity: both fallback restarts inside apply_config warn first" {
    for f in "$BATS_TEST_DIRNAME/../awg_common.sh" "$BATS_TEST_DIRNAME/../awg_common_en.sh"; do
        # Two unplanned restarts (strip failure, syncconf failure) plus the
        # explicit restart mode = three warning calls inside apply_config.
        run grep -c 'awg_warn_interface_disruption' "$f"
        [ "$output" -ge 4 ]
    done
}

@test "parity: the ARM path checks the postcondition, not only the hold" {
    for f in "$BATS_TEST_DIRNAME/../install_amneziawg.sh" "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"; do
        # The hold is a precondition. Without checking the result, an install can
        # report success while two module trees sit on disk.
        local tools check
        tools=$(grep -n 'install_packages "amneziawg-tools"' "$f" | head -1 | cut -d: -f1)
        check=$(grep -n "dpkg-query -W -f='\${Status}' amneziawg-dkms" "$f" | awk -F: -v t="$tools" '$1 > t {print $1; exit}')
        [ -n "$tools" ]
        [ -n "$check" ]
        [ "$check" -gt "$tools" ]
    done
}

# ============================================================================
# Пробелы, найденные мутационным анализом. Каждый тест назван так, чтобы было
# видно, КАКУЮ подмену он убивает: без них набор оставался зелёным при инверсии
# смысла предупреждения и при переносе его ПОСЛЕ перезапуска.
# ============================================================================

capture_warn() {
    rm -f "$AWG_DIR/.warns" "$AWG_DIR/.debugs"
    log_warn()  { echo "$*" >> "$AWG_DIR/.warns"; }
    log_debug() { echo "$*" >> "$AWG_DIR/.debugs"; }
}

@test "warn: a session FROM the tunnel gets the loud warning and the console route" {
    stub_who 'root pts/0 2026-08-08 01:00 (10.9.9.5)'
    write_conf "Jc = 4"
    capture_warn
    awg_warn_interface_disruption
    grep -q "ЧЕРЕЗ этот же VPN" "$AWG_DIR/.warns"
    grep -q "10.9.9.5" "$AWG_DIR/.warns"
    grep -q "консоль или VNC" "$AWG_DIR/.warns"
    # The subnet in the text is the one the verdict was based on.
    grep -q "10.9.9.1/24" "$AWG_DIR/.warns"
}

@test "warn: a session OUTSIDE the tunnel gets no lost-access panic" {
    stub_who 'root pts/0 2026-08-08 01:00 (203.0.113.5)'
    write_conf "Jc = 4"
    capture_warn
    awg_warn_interface_disruption
    grep -q "прервутся" "$AWG_DIR/.warns"
    # Swapping the two verdict branches used to pass unnoticed.
    run grep -c "консоль или VNC" "$AWG_DIR/.warns"
    [ "$output" = "0" ]
    run grep -c "ЧЕРЕЗ этот же VPN" "$AWG_DIR/.warns"
    [ "$output" = "0" ]
}

@test "warn: an unknown source gets the generic warning, not a verdict" {
    silence_utmp
    unset SSH_CONNECTION
    write_conf "Jc = 4"
    capture_warn
    awg_warn_interface_disruption
    grep -q "прервутся" "$AWG_DIR/.warns"
    grep -q "Если вы подключены к серверу ЧЕРЕЗ этот VPN" "$AWG_DIR/.warns"
    run grep -c "Адрес вашей сессии" "$AWG_DIR/.warns"
    [ "$output" = "0" ]
}

@test "warn: the connections-will-drop line never disappears" {
    for src in '(10.9.9.5)' '(203.0.113.5)' '(2001:db8::1)'; do
        stub_who "root pts/0 2026-08-08 01:00 $src"
        write_conf "Jc = 4"
        capture_warn
        awg_warn_interface_disruption
        grep -q "Интерфейс awg0 будет перезапущен" "$AWG_DIR/.warns"
    done
}

# --- order: warn BEFORE the restart, otherwise nobody ever reads it ---

order_probe() {
    cat > "$MOCK_BIN/systemctl" << 'STUB'
#!/bin/bash
echo "RESTART-HAPPENED" >> "${AWG_DIR}/.warns"
echo "systemctl $*" >> "${AWG_DIR}/.mock_calls"
exit 0
STUB
    chmod +x "$MOCK_BIN/systemctl"
    rm -f "$AWG_DIR/.warns"
    log_warn()  { echo "$*" >> "$AWG_DIR/.warns"; }
    log_debug() { :; }
}

warn_precedes_restart() {
    local w r
    w=$(grep -n "прервутся" "$AWG_DIR/.warns" | head -1 | cut -d: -f1)
    r=$(grep -n "RESTART-HAPPENED" "$AWG_DIR/.warns" | head -1 | cut -d: -f1)
    [ -n "$w" ] && [ -n "$r" ] && [ "$w" -lt "$r" ]
}

@test "order: explicit apply-mode=restart warns BEFORE restarting" {
    require_flock
    write_conf "Jc = 4"
    stub_who 'root pts/0 2026-08-08 01:00 (10.9.9.5)'
    order_probe
    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=restart
    run apply_config
    [ "$status" -eq 0 ]
    warn_precedes_restart
}

@test "order: the strip-failure fallback warns BEFORE restarting" {
    require_flock
    write_conf "Jc = 4"
    stub_who 'root pts/0 2026-08-08 01:00 (10.9.9.5)'
    order_probe
    printf '#!/bin/bash\nexit 1\n' > "$MOCK_BIN/awg-quick"
    chmod +x "$MOCK_BIN/awg-quick"
    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=syncconf
    run apply_config
    warn_precedes_restart
}

@test "order: the syncconf-failure fallback warns BEFORE restarting" {
    require_flock
    write_conf "Jc = 4"
    stub_who 'root pts/0 2026-08-08 01:00 (10.9.9.5)'
    order_probe
    printf '#!/bin/bash\nexit 1\n' > "$MOCK_BIN/awg"
    chmod +x "$MOCK_BIN/awg"
    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=syncconf
    run apply_config
    warn_precedes_restart
}

@test "order: manage restart records the snapshot AFTER the restart, not before" {
    for f in "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"; do
        local restart record
        restart=$(grep -n 'if ! systemctl restart awg-quick@awg0; then' "$f" | head -1 | cut -d: -f1)
        record=$(grep -n 'awg_record_device_params' "$f" | awk -F: -v r="$restart" '$1 > r {print $1; exit}')
        [ -n "$restart" ]
        [ -n "$record" ]
        [ "$record" -gt "$restart" ]
    done
}

# --- the parameter-name list is tied to the generator, not kept by eye ---

@test "param list: every key the generator writes is present in it" {
    # A missing name means a removal is reflected by nothing at all - exactly the
    # failure this feature exists to prevent, and the risk grows with 3.0.
    local known generated missing k
    known=" $(_awg_device_param_names | tr '\n' ' ') "
    generated=$(grep -oE '^(Jc|Jmin|Jmax|S[1-4]|H[1-4]|I[1-5]|ContentPaddingAddition|HeaderProtectionKey|MaxHandshakeAttempts|KeepaliveTimeout|RejectAfterTime|RekeyAfterTime|RekeyTimeout) =' "$BATS_TEST_DIRNAME/../awg_common.sh" | sed 's/ =//' | sort -u)
    [ -n "$generated" ]
    missing=""
    for k in $generated; do
        [[ "$known" == *" $k "* ]] || missing="$missing$k "
    done
    [ -z "$missing" ]
}

@test "param list: all of its names survive a round trip through the fingerprint" {
    local names lines k expected
    names=$(_awg_device_param_names)
    lines=""
    for k in $names; do
        lines="$lines$k = 1
"
    done
    write_conf "$lines"
    run _awg_device_params_fingerprint "$SERVER_CONF_FILE"
    [ "$status" -eq 0 ]
    expected=$(printf '%s\n' $names | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    [ "$output" = "$expected" ]
}

@test "fingerprint: names are matched case-insensitively" {
    # awg-quick keys are case-insensitive, so a hand edit of jc = 4 after a
    # canonical Jc must not look like a removal.
    write_conf "jc = 4
s1 = 100
headerprotectionkey = AAAA"
    run _awg_device_params_fingerprint "$SERVER_CONF_FILE"
    [ "$output" = "HeaderProtectionKey Jc S1" ]
}

@test "fingerprint: a case-only change between applies is not a removal" {
    require_flock
    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=syncconf
    write_conf "Jc = 4
S1 = 100"
    run apply_config
    log_warn() { echo "$*" >> "$AWG_DIR/.warns"; }
    write_conf "jc = 4
s1 = 100"
    run apply_config
    [ "$status" -eq 0 ]
    [ ! -f "$AWG_DIR/.warns" ]
}

@test "fingerprint: a parameter mentioned only in a comment does not count" {
    write_conf "Jc = 4
# S1 = 100
#S4 = 12"
    run _awg_device_params_fingerprint "$SERVER_CONF_FILE"
    [ "$output" = "Jc" ]
}

@test "warning reports ALL removed names, not just the first" {
    require_flock
    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=syncconf
    write_conf "Jc = 4
S1 = 100
H1 = 7"
    run apply_config
    log_warn() { echo "$*" >> "$AWG_DIR/.warns"; }
    write_conf "Jc = 4"
    run apply_config
    [ "$status" -eq 0 ]
    grep -q "S1" "$AWG_DIR/.warns"
    grep -q "H1" "$AWG_DIR/.warns"
}

# --- snapshot: permissions, temp cleanup on failure, recomputation ---

@test "snapshot: the file is created with mode 600" {
    write_conf "Jc = 4"
    awg_record_device_params
    run stat -c '%a' "$AWG_DIR/.awg_device_params"
    [ "$output" = "600" ]
}

@test "snapshot: no temp file survives a failed mv" {
    write_conf "Jc = 4"
    mkdir -p "$TEST_DIR/ro"
    printf 'old\n' > "$TEST_DIR/ro/state"
    chmod 500 "$TEST_DIR/ro"
    log_warn() { echo "$*" >> "$AWG_DIR/.warns"; }
    run _awg_save_device_params "$TEST_DIR/ro/state" "Jc S1"
    chmod 700 "$TEST_DIR/ro"
    [ "$status" -eq 0 ]
    run bash -c "ls \"$TEST_DIR/ro\"/state.tmp 2>/dev/null | wc -l"
    [ "$output" = "0" ]
}

@test "snapshot: awg_record_device_params recomputes instead of reusing a caller value" {
    # Bash dynamic scoping would let the function pick up the caller's now_fp. If
    # it did, a set computed BEFORE the apply - possibly partially read - would
    # be frozen into the snapshot.
    write_conf "Jc = 4
H1 = 7"
    # shellcheck disable=SC2034  # НЕ используется намеренно: проверяем, что
    # функция НЕ подхватит эту переменную через динамическую область видимости.
    local now_fp="STALE-VALUE"
    awg_record_device_params
    run cat "$AWG_DIR/.awg_device_params"
    [ "$output" = "H1 Jc" ]
}

# --- parity for the functions it did not cover ---

@test "parity: apply_config identical in RU and EN" {
    local ru en
    ru=$(parity_body "$BATS_TEST_DIRNAME/../awg_common.sh" apply_config)
    en=$(parity_body "$BATS_TEST_DIRNAME/../awg_common_en.sh" apply_config)
    [ -n "$ru" ]
    [ "$ru" = "$en" ]
}

@test "parity: _awg_save_device_params identical in RU and EN" {
    local ru en
    ru=$(parity_body "$BATS_TEST_DIRNAME/../awg_common.sh" _awg_save_device_params)
    en=$(parity_body "$BATS_TEST_DIRNAME/../awg_common_en.sh" _awg_save_device_params)
    [ -n "$ru" ]
    [ "$ru" = "$en" ]
}

@test "parity: apply_config calls the warning EXACTLY three times" {
    # Not ">= 4" but exactly one per branch: explicit restart plus two fallbacks.
    # The loose count let a deleted call slip through.
    local f
    for f in "$BATS_TEST_DIRNAME/../awg_common.sh" "$BATS_TEST_DIRNAME/../awg_common_en.sh"; do
        awk '/^apply_config\(\) \{$/,/^}$/' "$f" | grep -v '^[[:space:]]*#' > "$TEST_DIR/body.txt"
        run grep -c 'awg_warn_interface_disruption' "$TEST_DIR/body.txt"
        [ "$output" = "3" ]
    done
}

@test "parity: manage has exactly one warning call" {
    local f
    for f in "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"; do
        run grep -c 'awg_warn_interface_disruption' "$f"
        [ "$output" = "1" ]
    done
}

# ------------------------------------------ third-line 3.1 names (F4 slice B)

@test "_awg_device_params_fingerprint: RandomTrailers and DisableCookies are device parameters" {
    # Both sit in [Interface] and syncconf cannot clear them either, so a removal
    # has to be seen. A value of "off" still counts: a present line is a present
    # parameter.
    write_conf "Jc = 4
RandomTrailers = off
DisableCookies = on"
    run _awg_device_params_fingerprint
    [ "$status" -eq 0 ]
    [ "$output" = "DisableCookies Jc RandomTrailers" ]
}

@test "apply_config: a removed RandomTrailers or DisableCookies is reported" {
    require_flock
    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=syncconf

    write_conf "Jc = 4
RandomTrailers = on
DisableCookies = on"
    run apply_config
    [ "$status" -eq 0 ]

    log_warn() { echo "$*" >> "$AWG_DIR/.warns"; }
    write_conf "Jc = 4"
    run apply_config
    [ "$status" -eq 0 ]
    grep -q "RandomTrailers" "$AWG_DIR/.warns"
    grep -q "DisableCookies" "$AWG_DIR/.warns"
}
