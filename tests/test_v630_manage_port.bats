#!/usr/bin/env bats
# `manage port <N>`: change the server's UDP port on a running server.
#
# One command does what had to be done by hand: the new port goes into
# ListenPort of awg0.conf and AWG_PORT of the init file, UFW opens the new port
# before the restart and closes the old one after it, and every client is
# regenerated, because the port is part of the Endpoint in each client config.
# A failed restart puts both files back, restarts on the old port and closes
# the new port again. A bad, busy or unchanged port changes nothing.
#
# The real manage script runs end to end with systemctl, ufw and ss stubbed on
# PATH; every call is written to a log so the order can be checked.

# shellcheck disable=SC2154  # $stderr is set by bats `run --separate-stderr`
load test_helper

bats_require_minimum_version 1.5.0

setup_port_env() {
    MGMT_DIR=$(mktemp -d)
    mkdir -p "$MGMT_DIR/bin" "$MGMT_DIR/awg/keys"
    export CALLS="$MGMT_DIR/calls"
    : > "$CALLS"
    cat > "$MGMT_DIR/bin/awg" << 'STUB'
#!/bin/bash
case "$1" in
    genkey|genpsk) echo "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ;;
    pubkey) cat >/dev/null; echo "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=" ;;
    *) exit 0 ;;
esac
STUB
    cat > "$MGMT_DIR/bin/systemctl" << 'STUB'
#!/bin/bash
echo "systemctl $*" >> "$CALLS"
if [[ "$1" == restart && -n "${STUB_RESTART_FAIL:-}" ]]; then
    # Fails only while the config names the new port: the restart that puts
    # the old port back has to succeed.
    grep -qE "^ListenPort = ${STUB_RESTART_FAIL}\$" "$STUB_SERVER_CONF" && exit 1
fi
# STUB_RESTART_SIGNAL: one TERM to manage itself (the parent) during the restart on the new port.
if [[ "$1" == restart && -n "${STUB_RESTART_SIGNAL:-}" && ! -e "$CALLS.signaled" ]] \
    && grep -qE "^ListenPort = ${STUB_RESTART_SIGNAL}\$" "$STUB_SERVER_CONF"; then
    : > "$CALLS.signaled"; kill -TERM "$PPID"
fi
exit 0
STUB
    cat > "$MGMT_DIR/bin/ufw" << 'STUB'
#!/bin/bash
if [[ "$1" == show ]]; then
    for r in ${STUB_UFW_HAS:-}; do printf 'ufw allow %s/udp comment AmneziaWG\n' "$r"; done
    exit 0
fi
if [[ "$1" == status ]]; then
    [[ -n "${STUB_UFW_OFF:-}" ]] && { echo "Status: inactive"; exit 0; }
    echo "Status: active"
    for r in ${STUB_UFW_HAS:-}; do printf '%s/udp                  ALLOW       Anywhere\n' "$r"; done
    exit 0
fi
echo "ufw $*" >> "$CALLS"
[[ "$1" == allow && -n "${STUB_UFW_ALLOW_FAIL:-}" ]] && exit 1
exit 0
STUB
    cat > "$MGMT_DIR/bin/ss" << 'STUB'
#!/bin/bash
# The server listens on whatever ListenPort says, plus the ports in STUB_BUSY.
p=$(sed -n 's/^ListenPort = //p' "$STUB_SERVER_CONF")
for q in $p ${STUB_BUSY:-}; do printf 'UNCONN 0 0 0.0.0.0:%s 0.0.0.0:*\n' "$q"; done
STUB
    chmod +x "$MGMT_DIR/bin/"*
    export PATH="$MGMT_DIR/bin:$PATH"
    export STUB_SERVER_CONF="$MGMT_DIR/awg/awg0.conf"
    cat > "$MGMT_DIR/awg/awgsetup_cfg.init" << 'CONF'
export AWG_PORT=39743
export AWG_TUNNEL_SUBNET='10.9.9.1/24'
export DISABLE_IPV6=1
export ALLOWED_IPS_MODE=1
export ALLOWED_IPS='0.0.0.0/0'
export AWG_APPLY_MODE='syncconf'
export AWG_ENDPOINT='vpn.example.com'
CONF
    cat > "$MGMT_DIR/awg/awg0.conf" << 'CONF'
[Interface]
PrivateKey = TESTKEY
Address = 10.9.9.1/24
MTU = 1280
ListenPort = 39743
Jc = 6
Jmin = 55
Jmax = 380
S1 = 72
S2 = 56
S3 = 32
S4 = 16
H1 = 100000-800000
H2 = 1000000-8000000
H3 = 10000000-80000000
H4 = 100000000-800000000
CONF
    export AWG_SKIP_APPLY=1
}

teardown() {
    rm -rf "$TEST_DIR" "${MGMT_DIR:-}"
    unset AWG_SKIP_APPLY CALLS STUB_SERVER_CONF STUB_RESTART_FAIL STUB_UFW_OFF STUB_BUSY STUB_UFW_HAS STUB_UFW_ALLOW_FAIL STUB_RESTART_SIGNAL
}

manage() {
    local script="$1"; shift
    local lib="awg_common.sh"
    [[ "$script" == *_en.sh ]] && lib="awg_common_en.sh"
    cp "$BATS_TEST_DIRNAME/../$lib" "$MGMT_DIR/awg/awg_common.sh"
    run --separate-stderr bash "$BATS_TEST_DIRNAME/../$script" "$@" --yes \
        --conf-dir="$MGMT_DIR/awg" --server-conf="$MGMT_DIR/awg/awg0.conf"
}

listen_port() { sed -n 's/^ListenPort = //p' "$MGMT_DIR/awg/awg0.conf"; }
init_port() { sed -n 's/^export AWG_PORT=//p' "$MGMT_DIR/awg/awgsetup_cfg.init"; }
endpoint() { sed -n 's/^Endpoint = //p' "$MGMT_DIR/awg/$1.conf"; }
calls() { grep -vE '^(systemctl is-active|ufw status)' "$CALLS" | paste -sd'|' -; }

each_manage() {
    local seen=0 s
    for s in manage_amneziawg.sh manage_amneziawg_en.sh; do
        setup_port_env
        "$1" "$s" || return 1
        rm -rf "$MGMT_DIR"
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}

_port_changes_everything() {
    manage "$1" add alice bob
    [ "$status" -eq 0 ] || { echo "$1: add failed: $stderr"; return 1; }
    [ "$(endpoint alice)" = "vpn.example.com:39743" ] || { echo "$1: unexpected start endpoint $(endpoint alice)"; return 1; }
    : > "$CALLS"
    manage "$1" port 23456
    [ "$status" -eq 0 ] || { echo "$1: port failed ($status): $stderr"; return 1; }
    [ "$(listen_port)" = "23456" ] || { echo "$1: ListenPort is '$(listen_port)'"; return 1; }
    [ "$(init_port)" = "23456" ] || { echo "$1: init AWG_PORT is '$(init_port)'"; return 1; }
    [ "$(endpoint alice)" = "vpn.example.com:23456" ] || { echo "$1: alice endpoint '$(endpoint alice)'"; return 1; }
    [ "$(endpoint bob)" = "vpn.example.com:23456" ] || { echo "$1: bob endpoint '$(endpoint bob)'"; return 1; }
    local want="ufw allow 23456/udp comment AmneziaWG VPN|systemctl restart awg-quick@awg0|ufw delete allow 39743/udp"
    [ "$(calls)" = "$want" ] || { echo "$1: calls"; echo " got  $(calls)"; echo " want $want"; return 1; }
    [[ "$output$stderr" == *23456* ]] || { echo "$1: the result does not name the new port"; return 1; }
}
@test "port <N> changes ListenPort and the init, opens the new port before the restart, closes the old one, regenerates the clients" {
    require_flock
    each_manage _port_changes_everything
}

_port_refuses() {
    local bad
    for bad in 0 65536 abc 08080 ""; do
        : > "$CALLS"
        manage "$1" port $bad
        [ "$status" -ne 0 ] || { echo "$1: port '$bad' was accepted"; return 1; }
        [ "$(listen_port)" = "39743" ] && [ "$(init_port)" = "39743" ] || { echo "$1: '$bad' changed the files"; return 1; }
        [ -z "$(calls)" ] || { echo "$1: '$bad' touched the system: $(calls)"; return 1; }
    done
    export STUB_BUSY=34567
    manage "$1" port 34567
    unset STUB_BUSY
    [ "$status" -ne 0 ] || { echo "$1: a busy port was accepted"; return 1; }
    [[ "$stderr" == *34567* ]] || { echo "$1: the refusal does not name the busy port: $stderr"; return 1; }
    [ "$(listen_port)" = "39743" ] && [ -z "$(calls)" ] || { echo "$1: a busy port changed something: $(calls)"; return 1; }
}
@test "port refuses a bad or busy port and changes nothing" {
    each_manage _port_refuses
}

_port_same_is_noop() {
    manage "$1" port 39743
    [ "$status" -eq 0 ] || { echo "$1: the same port failed: $stderr"; return 1; }
    [ -z "$(calls)" ] || { echo "$1: the same port touched the system: $(calls)"; return 1; }
}
@test "port with the current port is a no-op" {
    each_manage _port_same_is_noop
}

_port_restart_failure_rolls_back() {
    manage "$1" add alice
    [ "$status" -eq 0 ] || { echo "$1: add failed: $stderr"; return 1; }
    local conf_before init_before client_before
    conf_before=$(cat "$MGMT_DIR/awg/awg0.conf"); init_before=$(cat "$MGMT_DIR/awg/awgsetup_cfg.init")
    client_before=$(cat "$MGMT_DIR/awg/alice.conf")
    : > "$CALLS"
    export STUB_RESTART_FAIL=23456
    manage "$1" port 23456
    unset STUB_RESTART_FAIL
    [ "$status" -ne 0 ] || { echo "$1: a failed restart reported success"; return 1; }
    [ "$(cat "$MGMT_DIR/awg/awg0.conf")" = "$conf_before" ] || { echo "$1: awg0.conf not restored"; return 1; }
    [ "$(cat "$MGMT_DIR/awg/awgsetup_cfg.init")" = "$init_before" ] || { echo "$1: init not restored"; return 1; }
    [ "$(cat "$MGMT_DIR/awg/alice.conf")" = "$client_before" ] || { echo "$1: the client was regenerated after a failed restart"; return 1; }
    local want="ufw allow 23456/udp comment AmneziaWG VPN|systemctl restart awg-quick@awg0|systemctl restart awg-quick@awg0|ufw delete allow 23456/udp"
    [ "$(calls)" = "$want" ] || { echo "$1: calls"; echo " got  $(calls)"; echo " want $want"; return 1; }
    run bash -c "ls '$MGMT_DIR/awg' | grep -c '\.bak\.'"
    [ "$output" = "0" ] || { echo "$1: backup files left behind"; return 1; }
}
@test "a failed restart puts the old port back everywhere and closes the new port" {
    require_flock
    each_manage _port_restart_failure_rolls_back
}

_port_without_ufw() {
    export STUB_UFW_OFF=1
    manage "$1" port 23456
    unset STUB_UFW_OFF
    [ "$status" -eq 0 ] || { echo "$1: port failed with UFW off: $stderr"; return 1; }
    local want="ufw allow 23456/udp comment AmneziaWG VPN|systemctl restart awg-quick@awg0|ufw delete allow 39743/udp"
    [ "$(calls)" = "$want" ] || { echo "$1: calls with UFW off: $(calls)"; return 1; }
    [ "$(listen_port)" = "23456" ] || { echo "$1: ListenPort '$(listen_port)'"; return 1; }
}
# UFW switched off now still gets the rules: turning it on later must not
# close the VPN port.
@test "port with UFW inactive still opens the new port and closes the old one" {
    require_flock
    each_manage _port_without_ufw
}

@test "help lists the port command, both twins" {
    local s
    for s in manage_amneziawg.sh manage_amneziawg_en.sh; do
        run bash "$BATS_TEST_DIRNAME/../$s" help
        [[ "$output" == *"port <"* ]] || { echo "$s: help has no port command"; return 1; }
    done
}

_port_ufw_allow_fails() {
    export STUB_UFW_ALLOW_FAIL=1
    manage "$1" port 23456
    unset STUB_UFW_ALLOW_FAIL
    [ "$status" -ne 0 ] || { echo "$1: a failed ufw allow reported success"; return 1; }
    [ "$(listen_port)" = "39743" ] && [ "$(init_port)" = "39743" ] || { echo "$1: the files changed after a failed ufw allow"; return 1; }
    [[ "$(calls)" != *"systemctl restart"* ]] || { echo "$1: the server restarted onto a port UFW did not open: $(calls)"; return 1; }
    run bash -c "ls '$MGMT_DIR/awg' | grep -c '\.bak\.'"
    [ "$output" = "0" ] || { echo "$1: backup files left behind"; return 1; }
}
@test "port stops before any change when UFW does not open the new port" {
    require_flock
    each_manage _port_ufw_allow_fails
}

_port_rollback_keeps_existing_rule() {
    export STUB_UFW_HAS=23456 STUB_RESTART_FAIL=23456
    manage "$1" port 23456
    unset STUB_UFW_HAS STUB_RESTART_FAIL
    [ "$status" -ne 0 ] || { echo "$1: a failed restart reported success"; return 1; }
    [[ "$(calls)" != *"ufw delete allow 23456/udp"* ]] || { echo "$1: the rollback removed a rule that existed before: $(calls)"; return 1; }
    [ "$(listen_port)" = "39743" ] || { echo "$1: not rolled back"; return 1; }
}
@test "a rollback keeps a UFW rule for the new port that existed before the command" {
    require_flock
    each_manage _port_rollback_keeps_existing_rule
}

_port_partial_regen() {
    manage "$1" add alice bob
    [ "$status" -eq 0 ] || { echo "$1: add failed: $stderr"; return 1; }
    # regen takes the key from keys/ or from the client .conf: with neither it fails.
    rm -f "$MGMT_DIR/awg/keys/alice.private" "$MGMT_DIR/awg/keys/alice.public" "$MGMT_DIR/awg/alice.conf"
    manage "$1" port 23456
    [ "$status" -ne 0 ] || { echo "$1: a failed regen of one client reported success"; return 1; }
    [[ "$stderr" == *alice* ]] || { echo "$1: the failed client is not named: $stderr"; return 1; }
    [ "$(listen_port)" = "23456" ] || { echo "$1: the port was rolled back over a client failure"; return 1; }
    [ "$(endpoint bob)" = "vpn.example.com:23456" ] || { echo "$1: bob not regenerated: $(endpoint bob)"; return 1; }
}
@test "port reports a client that could not be regenerated and keeps the new port" {
    require_flock
    each_manage _port_partial_regen
}

_port_init_without_key() {
    sed -i '/^export AWG_PORT=/d' "$MGMT_DIR/awg/awgsetup_cfg.init"
    manage "$1" port 23456
    [ "$status" -eq 0 ] || { echo "$1: port failed: $stderr"; return 1; }
    [ "$(init_port)" = "23456" ] || { echo "$1: AWG_PORT not added to the init: '$(init_port)'"; return 1; }
}
@test "port adds AWG_PORT to an init file that does not have it" {
    require_flock
    each_manage _port_init_without_key
}
_port_rollback_keeps_rule_ufw_off() {
    export STUB_UFW_OFF=1 STUB_UFW_HAS=23456 STUB_RESTART_FAIL=23456
    manage "$1" port 23456
    unset STUB_UFW_OFF STUB_UFW_HAS STUB_RESTART_FAIL
    [ "$status" -ne 0 ] || { echo "$1: a failed restart reported success"; return 1; }
    [[ "$(calls)" != *"ufw delete allow 23456/udp"* ]] || { echo "$1: with UFW off the rollback removed a rule that existed before: $(calls)"; return 1; }
}
@test "with UFW off a rollback still keeps a rule for the new port that existed before" {
    require_flock
    each_manage _port_rollback_keeps_rule_ufw_off
}
# A match at the top of a long output must count under pipefail: grep -q quits
# early, the writer gets SIGPIPE, and pipefail would turn the pipeline false.
@test "_port_ufw_has and _port_listening see a match at the top of a long output under pipefail, both twins" {
    local s
    for s in manage_amneziawg.sh manage_amneziawg_en.sh; do
        run bash -c '
            set -o pipefail
            '"$(awk '/^_port_listening\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../$s")"'
            '"$(awk '/^_port_ufw_has\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../$s")"'
            ufw() { [[ "$1" == show ]] || return 0; echo "ufw allow 23456/udp comment AmneziaWG"; seq 1 200000 | sed "s/^/ufw allow 1\/tcp # /"; }
            ss() { echo "UNCONN 0 0 0.0.0.0:23456 0.0.0.0:*"; seq 1 200000 | sed "s/^/UNCONN 0 0 0.0.0.0:1 # /"; }
            _port_ufw_has 23456 && echo ufw-yes
            _port_listening 23456 && echo ss-yes
            :
        '
        [[ "$output" == *ufw-yes* ]] || { echo "$s: _port_ufw_has missed the rule: $output"; return 1; }
        [[ "$output" == *ss-yes* ]] || { echo "$s: _port_listening missed the port: $output"; return 1; }
    done
}
# ---------- an interruption in the middle of the port change ----------

_port_signal_at_restart() {
    export STUB_RESTART_SIGNAL=23456
    manage "$1" port 23456
    unset STUB_RESTART_SIGNAL
    [ "$status" -eq 143 ] || { echo "$1: status $status, want 143"; return 1; }
    [ "$(listen_port)" = "39743" ] || { echo "$1: ListenPort left at $(listen_port)"; return 1; }
    [ "$(init_port)" = "39743" ] || { echo "$1: AWG_PORT left at $(init_port)"; return 1; }
    [[ "$(calls)" == *"systemctl restart awg-quick@awg0|systemctl restart awg-quick@awg0"* ]] || { echo "$1: the old port was not restarted: '$(calls)'"; return 1; }
    [[ "$(calls)" == *"ufw delete allow 23456/udp"* ]] || { echo "$1: the new port's rule was left: '$(calls)'"; return 1; }
    local left; left=$(compgen -G "$MGMT_DIR/awg/*.bak.*")
    [ -z "$left" ] || { echo "$1: copies left: $left"; return 1; }
}
@test "port interrupted during the restart puts the old port back and removes the rule it added, both twins" {
    require_flock
    each_manage _port_signal_at_restart
}

_port_signal_keeps_existing_rule() {
    export STUB_RESTART_SIGNAL=23456 STUB_UFW_HAS=23456
    manage "$1" port 23456
    unset STUB_RESTART_SIGNAL STUB_UFW_HAS
    [ "$status" -eq 143 ] || { echo "$1: status $status, want 143"; return 1; }
    [[ "$(calls)" != *"ufw delete allow 23456/udp"* ]] || { echo "$1: a rule that was there before was deleted: '$(calls)'"; return 1; }
}
@test "port interrupted keeps a rule for the new port that existed before, both twins" {
    require_flock
    each_manage _port_signal_keeps_existing_rule
}
# Another manage port committed between this command's first read and its lock.
_port_old_reread_under_lock() {
    cat > "$MGMT_DIR/bin/flock" << 'STUB'
#!/bin/bash
if [[ -n "${STUB_FLOCK_SET_PORT:-}" && ! -e "$CALLS.flocked" ]]; then
    : > "$CALLS.flocked"
    sed -i "s/^ListenPort = .*/ListenPort = ${STUB_FLOCK_SET_PORT}/" "$STUB_SERVER_CONF"
fi
exec /usr/bin/flock "$@"
STUB
    chmod +x "$MGMT_DIR/bin/flock"
    export STUB_FLOCK_SET_PORT=34567
    manage "$1" port 23456
    unset STUB_FLOCK_SET_PORT
    /bin/rm -f "$MGMT_DIR/bin/flock"; hash -r
    [ "$status" -eq 0 ] || { echo "$1: status $status: $stderr"; return 1; }
    [ "$(listen_port)" = "23456" ] || { echo "$1: ListenPort $(listen_port)"; return 1; }
    [[ "$(calls)" == *"ufw delete allow 34567/udp"* ]] || { echo "$1: the port in place at the lock was not closed: '$(calls)'"; return 1; }
    [[ "$(calls)" != *"ufw delete allow 39743/udp"* ]] || { echo "$1: the stale first read was used: '$(calls)'"; return 1; }
}
@test "port reads the old port again under the lock, both twins" {
    require_flock
    [ -x /usr/bin/flock ] || skip "no /usr/bin/flock"
    each_manage _port_old_reread_under_lock
}