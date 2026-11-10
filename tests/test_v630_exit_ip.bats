#!/usr/bin/env bats
# A separate exit address for client traffic (I#384).
#
# Clients connect to one address of the server (the entry, the Endpoint in their
# configs) and their traffic leaves to the internet from another address of the
# same server (the exit). --exit-ip=<IPv4> sets it at install time, manage
# exit-ip <IPv4|off> changes it on a running server without reissuing clients.
# The rule is a SNAT for the client subnet inserted above the installer's
# MASQUERADE; the server's own traffic is not touched. The address has to be on
# an interface of the server, and it cannot be combined with the IPv6 tunnel
# for clients: SNAT covers IPv4 only, and client IPv6 would leave from the
# entry side.
# shellcheck disable=SC2154  # $stderr is set by bats `run --separate-stderr`

load test_helper

bats_require_minimum_version 1.5.0

fn() { awk "/^$2\\(\\) \\{/,/^\\}/" "$BATS_TEST_DIRNAME/../$1"; }

SNAT_UP='iptables -t nat -I POSTROUTING -s 10.9.9.1/24 -o eth0 -j SNAT --to-source 203.0.113.7'
SNAT_DOWN='iptables -t nat -D POSTROUTING -s 10.9.9.1/24 -o eth0 -j SNAT --to-source 203.0.113.7'

setup_render_env() {
    get_main_nic() { echo "eth0"; }
    export -f get_main_nic
    create_init_config
    echo "SERVER_PRIV" > "$AWG_DIR/server_private.key"
    export AWG_TUNNEL_SUBNET="10.9.9.1/24"
    unset ALLOW_IPV6_TUNNEL
    export DISABLE_IPV6=1
}

# ---------- the server config ----------

@test "render: AWG_EXIT_IP adds the SNAT for the client subnet to PostUp and PostDown" {
    setup_render_env
    export AWG_EXIT_IP="203.0.113.7"
    run render_server_config
    [ "$status" -eq 0 ]
    grep -E '^PostUp = ' "$SERVER_CONF_FILE" | grep -qF "$SNAT_UP"
    grep -E '^PostDown = ' "$SERVER_CONF_FILE" | grep -qF "$SNAT_DOWN"
    # The MASQUERADE for the server's own traffic stays.
    grep -E '^PostUp = ' "$SERVER_CONF_FILE" | grep -qF 'iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE'
    unset AWG_EXIT_IP
}

@test "render: without AWG_EXIT_IP there is no SNAT" {
    setup_render_env
    unset AWG_EXIT_IP
    run render_server_config
    [ "$status" -eq 0 ]
    run grep -c 'SNAT' "$SERVER_CONF_FILE"
    [ "$output" = "0" ]
}

@test "render: an invalid AWG_EXIT_IP is refused, nothing is written" {
    setup_render_env
    local bad
    for bad in '203.0.113.7; reboot' '300.1.1.1' '203.0.113' 'example.com'; do
        rm -f "$SERVER_CONF_FILE"
        export AWG_EXIT_IP="$bad"
        run render_server_config
        [ "$status" -ne 0 ] || { echo "'$bad' was accepted"; return 1; }
        [ ! -e "$SERVER_CONF_FILE" ] || { echo "'$bad' left a config"; return 1; }
    done
    unset AWG_EXIT_IP
}

@test "render: the SNAT lines are the same in both libraries" {
    local a b
    a=$(fn awg_common.sh render_server_config | grep -F 'SNAT --to-source')
    b=$(fn awg_common_en.sh render_server_config | grep -F 'SNAT --to-source')
    [ -n "$a" ] && [ "$a" = "$b" ]
}

# ---------- the installer ----------

# xcheck <installer> <ip> <ipv6 tunnel> <addresses on interfaces>
xcheck() {
    run bash -c '
        log() { :; }
        '"$(fn "$1" _awg_exit_ip_check)"'
        ip() { local a; for a in $STUB_ADDRS; do printf "2: eth0    inet %s/24 brd x scope global eth0\n" "$a"; done; }
        ALLOW_IPV6_TUNNEL="$3"
        _awg_exit_ip_check "$2"
    ' _ "$1" "$2" "$3"
}

@test "installer: _awg_exit_ip_check accepts an address on an interface and refuses the rest, both twins" {
    local s
    for s in install_amneziawg.sh install_amneziawg_en.sh; do
        STUB_ADDRS="198.51.100.2 203.0.113.7" xcheck "$s" 203.0.113.7 0
        [ "$status" -eq 0 ] || { echo "$s: a present address was refused: $output"; return 1; }
        STUB_ADDRS="198.51.100.2" xcheck "$s" 203.0.113.7 0
        [ "$status" -ne 0 ] && [[ "$output" == *203.0.113.7* ]] || { echo "$s: a missing address passed: $output"; return 1; }
        STUB_ADDRS="203.0.113.7" xcheck "$s" 203.0.113.7 1
        [ "$status" -ne 0 ] && [[ "$output" == *IPv6* ]] || { echo "$s: the IPv6 tunnel combination passed: $output"; return 1; }
        STUB_ADDRS="203.0.113.7" xcheck "$s" '203.0.113.7;id' 0
        [ "$status" -ne 0 ] || { echo "$s: a malformed value passed"; return 1; }
    done
}

@test "installer: --exit-ip is parsed, saved into the init and whitelisted, both twins" {
    local s f
    for s in install_amneziawg.sh install_amneziawg_en.sh; do
        grep -qE '^\s+--exit-ip=\*\)\s+CLI_EXIT_IP="\$\{1#\*=\}"; CLI_EXIT_IP_SET=1 ;;' "$BATS_TEST_DIRNAME/../$s" \
            || { echo "$s: no --exit-ip case"; return 1; }
        fn "$s" _awg_save_init | grep -qF "export AWG_EXIT_IP='\${AWG_EXIT_IP:-}'" \
            || { echo "$s: _awg_save_init does not save AWG_EXIT_IP"; return 1; }
        fn "$s" initialize_setup | grep -qxE '\s+_awg_resolve_exit_ip' \
            || { echo "$s: initialize_setup does not resolve the exit address"; return 1; }
        fn "$s" step6_generate_configs | grep -qxE '\s+_awg_stop_if_exit_ip_changed' \
            || { echo "$s: step 6 does not stop the service on an exit address change"; return 1; }
    done
    for f in awg_common.sh awg_common_en.sh install_amneziawg.sh install_amneziawg_en.sh; do
        fn "$f" safe_load_config | grep -qE '\|AWG_EXIT_IP\|' || { echo "AWG_EXIT_IP missing from the whitelist in $f"; return 1; }
    done
}

# ---------- manage exit-ip ----------

setup_exit_env() {
    MGMT_DIR=$(mktemp -d)
    mkdir -p "$MGMT_DIR/bin" "$MGMT_DIR/awg/keys"
    export CALLS="$MGMT_DIR/calls"; : > "$CALLS"
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
[[ "$1" == stop && -n "${STUB_STOP_FAIL:-}" ]] && exit 1
# STUB_STOP_SIGNAL / STUB_START_SIGNAL: TERM to manage itself (the parent) while
# the service is down: right at the stop, or at the start on the new exit address.
[[ "$1" == stop && -n "${STUB_STOP_SIGNAL:-}" ]] && { kill -TERM "$PPID"; exit 0; }
if [[ "$1" == start && -n "${STUB_START_SIGNAL:-}" ]] && grep -qF -- "--to-source ${STUB_START_SIGNAL}" "$STUB_SERVER_CONF"; then
    kill -TERM "$PPID"; exit 0
fi
if [[ "$1" == start && -n "${STUB_START_FAIL:-}" ]]; then
    grep -qF -- "--to-source ${STUB_START_FAIL}" "$STUB_SERVER_CONF" && exit 1
fi
exit 0
STUB
    cat > "$MGMT_DIR/bin/ip" << 'STUB'
#!/bin/bash
for a in ${STUB_ADDRS:-}; do printf '2: eth0    inet %s/24 brd x scope global eth0\n' "$a"; done
printf '3: awg0    inet 10.9.9.1/24 scope global awg0\n'
printf '1: lo    inet 127.0.0.1/8 scope host lo\n'
STUB
    # iptables: -C answers "the rule is there" only for STUB_IPT_LEFT; every
    # -D is written to a log of its own. STUB_IPT_STUCK: a rule that -C always
    # finds and -D never removes (more copies than any bounded loop takes).
    cat > "$MGMT_DIR/bin/iptables" << 'STUB'
#!/bin/bash
case " $* " in
    *" -C "*) [[ -n "${STUB_IPT_STUCK:-}" && " $* " == *"--to-source ${STUB_IPT_STUCK} "* ]] && exit 0
              [[ -n "${STUB_IPT_LEFT:-}" && " $* " == *"--to-source ${STUB_IPT_LEFT} "* && ! -e "$CALLS.gone" ]] && exit 0; exit 1 ;;
    *" -D "*) echo "iptables $*" >> "$CALLS.ipt"; [[ -n "${STUB_IPT_LEFT:-}" && " $* " == *"--to-source ${STUB_IPT_LEFT} "* ]] && : > "$CALLS.gone"; exit 0 ;;
esac
exit 0
STUB
    chmod +x "$MGMT_DIR/bin/"*
    export PATH="$MGMT_DIR/bin:$PATH"
    export STUB_SERVER_CONF="$MGMT_DIR/awg/awg0.conf"
    export STUB_ADDRS="198.51.100.2 203.0.113.7 203.0.113.8"
    cat > "$MGMT_DIR/awg/awgsetup_cfg.init" << 'CONF'
export AWG_PORT=39743
export AWG_TUNNEL_SUBNET='10.9.9.1/24'
export DISABLE_IPV6=1
export ALLOW_IPV6_TUNNEL=0
export ALLOWED_IPS_MODE=1
export ALLOWED_IPS='0.0.0.0/0'
export AWG_ENDPOINT='198.51.100.2'
CONF
    cat > "$MGMT_DIR/awg/awg0.conf" << 'CONF'
[Interface]
PrivateKey = TESTKEY
Address = 10.9.9.1/24
MTU = 1280
ListenPort = 39743
PostUp = iptables -I FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE; iptables -t mangle -A FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE; iptables -t mangle -D FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240

[Peer]
#_Name = alice
PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
AllowedIPs = 10.9.9.2/32
CONF
    printf '[Interface]\nPrivateKey = X\n\n[Peer]\nEndpoint = 198.51.100.2:39743\n' > "$MGMT_DIR/awg/alice.conf"
    export AWG_SKIP_APPLY=1
}

teardown() {
    rm -rf "$TEST_DIR" "${MGMT_DIR:-}"
    unset AWG_SKIP_APPLY CALLS STUB_SERVER_CONF STUB_ADDRS STUB_START_FAIL STUB_STOP_FAIL STUB_IPT_LEFT STUB_IPT_STUCK STUB_STOP_SIGNAL STUB_START_SIGNAL
}

manage() {
    local script="$1"; shift
    local lib="awg_common.sh"
    [[ "$script" == *_en.sh ]] && lib="awg_common_en.sh"
    cp "$BATS_TEST_DIRNAME/../$lib" "$MGMT_DIR/awg/awg_common.sh"
    run --separate-stderr bash "$BATS_TEST_DIRNAME/../$script" "$@" --yes \
        --conf-dir="$MGMT_DIR/awg" --server-conf="$MGMT_DIR/awg/awg0.conf"
}

snat_up() { grep -E '^PostUp = ' "$MGMT_DIR/awg/awg0.conf" | grep -oE 'iptables -t nat -I POSTROUTING -s [^ ]+ -o [^ ]+ -j SNAT --to-source [0-9.]+'; }
snat_down() { grep -E '^PostDown = ' "$MGMT_DIR/awg/awg0.conf" | grep -oE 'iptables -t nat -D POSTROUTING -s [^ ]+ -o [^ ]+ -j SNAT --to-source [0-9.]+'; }
init_exit() { sed -n "s/^export AWG_EXIT_IP=//p" "$MGMT_DIR/awg/awgsetup_cfg.init"; }
calls() { grep -vE '^systemctl is-active' "$CALLS" | paste -sd'|' -; }

each_manage() {
    local seen=0 s
    for s in manage_amneziawg.sh manage_amneziawg_en.sh; do
        setup_exit_env
        "$1" "$s" || return 1
        rm -rf "$MGMT_DIR"
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}

_exit_set_change_off() {
    local client_before; client_before=$(cat "$MGMT_DIR/awg/alice.conf")
    manage "$1" exit-ip 203.0.113.7
    [ "$status" -eq 0 ] || { echo "$1: set failed: $stderr"; return 1; }
    [ "$(snat_up)" = "$SNAT_UP" ] || { echo "$1: PostUp SNAT '$(snat_up)'"; return 1; }
    [ "$(snat_down)" = "$SNAT_DOWN" ] || { echo "$1: PostDown SNAT '$(snat_down)'"; return 1; }
    [ "$(init_exit)" = "'203.0.113.7'" ] || { echo "$1: init '$(init_exit)'"; return 1; }
    [ "$(calls)" = "systemctl stop awg-quick@awg0|systemctl start awg-quick@awg0" ] || { echo "$1: calls '$(calls)'"; return 1; }
    [ "$(cat "$MGMT_DIR/awg/alice.conf")" = "$client_before" ] || { echo "$1: the client config changed"; return 1; }
    : > "$CALLS"
    manage "$1" exit-ip 203.0.113.8
    [ "$status" -eq 0 ] || { echo "$1: change failed: $stderr"; return 1; }
    [ "$(snat_up | wc -l)" = "1" ] && [[ "$(snat_up)" == *"--to-source 203.0.113.8" ]] || { echo "$1: after a change: '$(snat_up)'"; return 1; }
    [ "$(snat_down | wc -l)" = "1" ] || { echo "$1: PostDown after a change: '$(snat_down)'"; return 1; }
    manage "$1" exit-ip off
    [ "$status" -eq 0 ] || { echo "$1: off failed: $stderr"; return 1; }
    run grep -c SNAT "$MGMT_DIR/awg/awg0.conf"
    [ "$output" = "0" ] || { echo "$1: SNAT left after off"; return 1; }
    [ "$(init_exit)" = "''" ] || { echo "$1: init after off '$(init_exit)'"; return 1; }
    grep -qF 'iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE' "$MGMT_DIR/awg/awg0.conf" || { echo "$1: MASQUERADE lost"; return 1; }
}
@test "exit-ip sets, changes and removes the exit address without touching the clients" {
    require_flock
    each_manage _exit_set_change_off
}

_exit_refusals() {
    local conf_before; conf_before=$(cat "$MGMT_DIR/awg/awg0.conf")
    manage "$1" exit-ip 192.0.2.99
    [ "$status" -ne 0 ] && [[ "$stderr" == *192.0.2.99* ]] || { echo "$1: an address not on the server passed: $stderr"; return 1; }
    manage "$1" exit-ip 'x.y'
    [ "$status" -ne 0 ] || { echo "$1: a malformed address passed"; return 1; }
    sed -i 's/^export ALLOW_IPV6_TUNNEL=0/export ALLOW_IPV6_TUNNEL=1/' "$MGMT_DIR/awg/awgsetup_cfg.init"
    manage "$1" exit-ip 203.0.113.7
    [ "$status" -ne 0 ] && [[ "$stderr" == *IPv6* ]] || { echo "$1: the IPv6 tunnel combination passed: $stderr"; return 1; }
    [ "$(cat "$MGMT_DIR/awg/awg0.conf")" = "$conf_before" ] || { echo "$1: a refusal changed awg0.conf"; return 1; }
    [ -z "$(calls)" ] || { echo "$1: a refusal touched the service: $(calls)"; return 1; }
}
@test "exit-ip refuses an address that is not on the server, a malformed one, and the IPv6 tunnel combination" {
    each_manage _exit_refusals
}

_exit_rollback() {
    local conf_before init_before
    conf_before=$(cat "$MGMT_DIR/awg/awg0.conf"); init_before=$(cat "$MGMT_DIR/awg/awgsetup_cfg.init")
    export STUB_START_FAIL=203.0.113.7
    manage "$1" exit-ip 203.0.113.7
    unset STUB_START_FAIL
    [ "$status" -ne 0 ] || { echo "$1: a failed start reported success"; return 1; }
    [ "$(cat "$MGMT_DIR/awg/awg0.conf")" = "$conf_before" ] || { echo "$1: awg0.conf not restored"; return 1; }
    [ "$(cat "$MGMT_DIR/awg/awgsetup_cfg.init")" = "$init_before" ] || { echo "$1: init not restored"; return 1; }
    [ "$(calls)" = "systemctl stop awg-quick@awg0|systemctl start awg-quick@awg0|systemctl start awg-quick@awg0" ] || { echo "$1: calls '$(calls)'"; return 1; }
}
@test "a failed start on the new exit address puts the old config back and starts it" {
    require_flock
    each_manage _exit_rollback
}

@test "help lists the exit-ip command, both twins" {
    local s
    for s in manage_amneziawg.sh manage_amneziawg_en.sh; do
        run bash "$BATS_TEST_DIRNAME/../$s" help
        [[ "$output" == *"exit-ip <"* ]] || { echo "$s: help has no exit-ip command"; return 1; }
    done
}

_exit_more_refusals() {
    manage "$1" exit-ip 10.9.9.1
    [ "$status" -ne 0 ] || { echo "$1: the tunnel address was accepted as an exit"; return 1; }
    manage "$1" exit-ip 127.0.0.1
    [ "$status" -ne 0 ] || { echo "$1: loopback was accepted as an exit"; return 1; }
    manage "$1" exit-ip 198.51.100.2
    [ "$status" -ne 0 ] && [[ "$stderr" == *AWG_ENDPOINT* ]] || { echo "$1: the entry address was accepted as an exit: $stderr"; return 1; }
    sed -i 's|^Address = 10.9.9.1/24$|Address = 10.9.9.1/24, fddd:2c4:2c4:2c4::1/64|' "$MGMT_DIR/awg/awg0.conf"
    manage "$1" exit-ip 203.0.113.7
    [ "$status" -ne 0 ] && [[ "$stderr" == *IPv6* ]] || { echo "$1: an IPv6 Address in awg0.conf did not stop it: $stderr"; return 1; }
    [ -z "$(calls)" ] || { echo "$1: a refusal touched the service: $(calls)"; return 1; }
}
@test "exit-ip refuses the tunnel address, loopback, the entry address, and an IPv6 Address in awg0.conf" {
    each_manage _exit_more_refusals
}

_exit_stop_fails() {
    local conf_before; conf_before=$(cat "$MGMT_DIR/awg/awg0.conf")
    export STUB_STOP_FAIL=1
    manage "$1" exit-ip 203.0.113.7
    unset STUB_STOP_FAIL
    [ "$status" -ne 0 ] || { echo "$1: a failed stop reported success"; return 1; }
    [ "$(cat "$MGMT_DIR/awg/awg0.conf")" = "$conf_before" ] || { echo "$1: awg0.conf changed after a failed stop"; return 1; }
    [ "$(calls)" = "systemctl stop awg-quick@awg0" ] || { echo "$1: calls '$(calls)'"; return 1; }
}
@test "exit-ip changes nothing when the service does not stop" {
    require_flock
    each_manage _exit_stop_fails
}

_exit_old_rule_left() {
    manage "$1" exit-ip 203.0.113.7
    [ "$status" -eq 0 ] || { echo "$1: set failed: $stderr"; return 1; }
    : > "$CALLS.ipt"
    export STUB_IPT_LEFT=203.0.113.7
    manage "$1" exit-ip off
    unset STUB_IPT_LEFT
    [ "$status" -eq 0 ] || { echo "$1: off failed: $stderr"; return 1; }
    grep -qxF "iptables -t nat -D POSTROUTING -s 10.9.9.1/24 -o eth0 -j SNAT --to-source 203.0.113.7" "$CALLS.ipt" \
        || { echo "$1: the rule left after stop was not removed: $(cat "$CALLS.ipt")"; return 1; }
}
@test "exit-ip removes an old SNAT rule that PostDown left in place" {
    require_flock
    each_manage _exit_old_rule_left
}

_exit_crlf() {
    sed -i 's/$/\r/' "$MGMT_DIR/awg/awg0.conf"
    manage "$1" exit-ip 203.0.113.7
    [ "$status" -eq 0 ] || { echo "$1: set on a CRLF config failed: $stderr"; return 1; }
    run grep -c $'\r' "$MGMT_DIR/awg/awg0.conf"
    [ "$output" = "0" ] || { echo "$1: a carriage return is left in awg0.conf"; return 1; }
    grep -E '^PostUp = ' "$MGMT_DIR/awg/awg0.conf" | grep -qF -- "--set-mss 1240; $SNAT_UP" \
        || { echo "$1: the last PostUp command is broken: $(grep '^PostUp' "$MGMT_DIR/awg/awg0.conf")"; return 1; }
}
@test "exit-ip on a CRLF awg0.conf keeps the last PostUp command intact" {
    require_flock
    each_manage _exit_crlf
}

_exit_foreign_snat() {
    local foreign_up='iptables -t nat -I POSTROUTING -s 10.8.0.0/24 -o eth0 -j SNAT --to-source 203.0.113.8'
    local foreign_down='iptables -t nat -D POSTROUTING -s 10.8.0.0/24 -o eth0 -j SNAT --to-source 203.0.113.8'
    sed -i "s|^PostUp = .*|&; $foreign_up|; s|^PostDown = .*|&; $foreign_down|" "$MGMT_DIR/awg/awg0.conf"
    manage "$1" exit-ip 203.0.113.8
    [ "$status" -eq 0 ] || { echo "$1: set failed: $stderr"; return 1; }
    [[ "$output$stderr" != *"менять нечего"* && "$output$stderr" != *"nothing to change"* ]] || { echo "$1: a foreign SNAT was taken for ours"; return 1; }
    [[ "$(snat_up)" == *"-s 10.9.9.1/24 -o eth0 -j SNAT --to-source 203.0.113.8"* ]] || { echo "$1: the command's rule is missing: $(snat_up)"; return 1; }
    manage "$1" exit-ip off
    [ "$status" -eq 0 ] || { echo "$1: off failed: $stderr"; return 1; }
    grep -E '^PostUp = ' "$MGMT_DIR/awg/awg0.conf" | grep -qF "$foreign_up" || { echo "$1: the foreign PostUp rule was removed"; return 1; }
    grep -E '^PostDown = ' "$MGMT_DIR/awg/awg0.conf" | grep -qF "$foreign_down" || { echo "$1: the foreign PostDown rule was removed"; return 1; }
    run grep -c -- '-s 10.9.9.1/24 -o eth0 -j SNAT' "$MGMT_DIR/awg/awg0.conf"
    [ "$output" = "0" ] || { echo "$1: the command's rule is left after off"; return 1; }
}
@test "exit-ip leaves a SNAT rule for another subnet alone" {
    require_flock
    each_manage _exit_foreign_snat
}

# The rule render_server_config writes is the one manage exit-ip finds and removes.
_exit_render_then_off() {
    local up down
    up=$(grep '^PostUp = ' "$RENDERED"); down=$(grep '^PostDown = ' "$RENDERED")
    awk -v u="$up" -v d="$down" '/^PostUp = /{print u; next} /^PostDown = /{print d; next} {print}' \
        "$MGMT_DIR/awg/awg0.conf" > "$MGMT_DIR/awg/awg0.conf.new" && mv "$MGMT_DIR/awg/awg0.conf.new" "$MGMT_DIR/awg/awg0.conf"
    sed -i "s/^export AWG_TUNNEL_SUBNET=.*/export AWG_TUNNEL_SUBNET='10.9.9.1\/24'/" "$MGMT_DIR/awg/awgsetup_cfg.init"
    manage "$1" exit-ip off
    [ "$status" -eq 0 ] || { echo "$1: off failed: $stderr"; return 1; }
    run grep -c 'SNAT' "$MGMT_DIR/awg/awg0.conf"
    [ "$output" = "0" ] || { echo "$1: the rendered SNAT was not removed: $(grep '^Post' "$MGMT_DIR/awg/awg0.conf")"; return 1; }
}
@test "exit-ip off removes the SNAT that render_server_config wrote" {
    require_flock
    setup_render_env
    export AWG_EXIT_IP="203.0.113.7"
    run render_server_config
    [ "$status" -eq 0 ]
    unset AWG_EXIT_IP
    export RENDERED="$BATS_TEST_TMPDIR/rendered.conf"
    cp "$SERVER_CONF_FILE" "$RENDERED"
    each_manage _exit_render_then_off
}
# xresolve <installer> <snippet>: _awg_resolve_exit_ip with die/log stubbed;
# the snippet sets CLI_* and AWG_EXIT_IP, the output ends with AWG_EXIT_IP=<value>.
xresolve() {
    run bash -c '
        log() { :; }; die() { echo "DIE: $*"; exit 1; }
        '"$(fn "$1" _awg_exit_ip_check)"'
        '"$(fn "$1" _awg_resolve_exit_ip)"'
        ip() { local a; for a in $STUB_ADDRS; do printf "2: eth0    inet %s/24 brd x scope global eth0\n" "$a"; done; }
        ALLOW_IPV6_TUNNEL=0 AWG_ENDPOINT=198.51.100.2
        '"$2"'
        _awg_resolve_exit_ip
        echo "AWG_EXIT_IP=${AWG_EXIT_IP}"
    '
}

@test "installer: --exit-ip sets, off clears, a saved value is checked again, an empty flag is refused, both twins" {
    local s
    export STUB_ADDRS="198.51.100.2 203.0.113.7"
    for s in install_amneziawg.sh install_amneziawg_en.sh; do
        xresolve "$s" 'CLI_EXIT_IP_SET=1 CLI_EXIT_IP=203.0.113.7 AWG_EXIT_IP=""'
        [ "$status" -eq 0 ] && [[ "$output" == *"AWG_EXIT_IP=203.0.113.7" ]] || { echo "$s: set: $output"; return 1; }
        xresolve "$s" 'CLI_EXIT_IP_SET=1 CLI_EXIT_IP=off AWG_EXIT_IP=203.0.113.7'
        [ "$status" -eq 0 ] && [[ "$output" == *"AWG_EXIT_IP=" ]] || { echo "$s: off: $output"; return 1; }
        xresolve "$s" 'CLI_EXIT_IP_SET=1 CLI_EXIT_IP="" AWG_EXIT_IP=""'
        [ "$status" -ne 0 ] && [[ "$output" == *"DIE:"*"--exit-ip"* ]] || { echo "$s: an empty --exit-ip= passed: $output"; return 1; }
        xresolve "$s" 'CLI_EXIT_IP_SET=0 AWG_EXIT_IP=192.0.2.50'
        [ "$status" -ne 0 ] && [[ "$output" == *192.0.2.50* ]] || { echo "$s: a saved address that is gone passed: $output"; return 1; }
        xresolve "$s" 'CLI_EXIT_IP_SET=1 CLI_EXIT_IP=198.51.100.2 AWG_EXIT_IP=""'
        [ "$status" -ne 0 ] && [[ "$output" == *"--endpoint"* ]] || { echo "$s: the entry address passed as exit: $output"; return 1; }
    done
}

# The service stops before the render only when the exit address really changes.
@test "installer: a reinstall that changes the exit address stops the service before the render, both twins" {
    local s d="$BATS_TEST_TMPDIR/stopx"
    for s in install_amneziawg.sh install_amneziawg_en.sh; do
        rm -rf "$d"; mkdir -p "$d"
        printf 'PostUp = a; iptables -t nat -I POSTROUTING -s 10.9.9.1/24 -o eth0 -j SNAT --to-source 203.0.113.7\n' > "$d/awg0.conf"
        local want new
        for pair in "203.0.113.8:stop flag=1" ":stop flag=1" "203.0.113.7:flag=0"; do
            new="${pair%%:*}"; want="${pair#*:}"
            run bash -c '
                log() { :; }; log_warn() { :; }
                '"$(fn "$s" _awg_stop_if_exit_ip_changed)"'
                systemctl() { [[ "$1" == is-active ]] && return 0; echo "$1"; }
                SERVER_CONF_FILE="$1" AWG_EXIT_IP="$2"
                _awg_stop_if_exit_ip_changed
                echo "flag=${_AWG_STOPPED_FOR_EXIT:-0}"
            ' _ "$d/awg0.conf" "$new"
            [ "$(paste -sd' ' <<< "$output")" = "$want" ] || { echo "$s: exit '$new': got '$output', want '$want'"; return 1; }
        done
    done
}
_exit_check_reports_missing() {
    manage "$1" exit-ip 203.0.113.7
    [ "$status" -eq 0 ] || { echo "$1: set failed: $stderr"; return 1; }
    manage "$1" check
    [[ "$output$stderr" == *203.0.113.7* ]] || { echo "$1: check does not mention the exit address"; return 1; }
    [[ "$output$stderr" != *"203.0.113.7 нет"* && "$output$stderr" != *"203.0.113.7 is not on"* ]] || { echo "$1: check calls a present address missing"; return 1; }
    export STUB_ADDRS="198.51.100.2"
    manage "$1" check
    [ "$status" -ne 0 ] || { echo "$1: check passed with the exit address gone"; return 1; }
    [[ "$stderr" == *"203.0.113.7 нет"* || "$stderr" == *"203.0.113.7 is not on"* ]] || { echo "$1: check does not say the address is gone: $stderr"; return 1; }
}
@test "check reports an exit address that is no longer on the server" {
    require_flock
    each_manage _exit_check_reports_missing
}
_exit_rollback_removes_new_rule() {
    : > "$CALLS.ipt"
    export STUB_START_FAIL=203.0.113.7 STUB_IPT_LEFT=203.0.113.7
    manage "$1" exit-ip 203.0.113.7
    unset STUB_START_FAIL STUB_IPT_LEFT
    [ "$status" -ne 0 ] || { echo "$1: a failed start reported success"; return 1; }
    grep -qxF "iptables -t nat -D POSTROUTING -s 10.9.9.1/24 -o eth0 -j SNAT --to-source 203.0.113.7" "$CALLS.ipt" \
        || { echo "$1: the new rule a failed start left behind was not removed: $(cat "$CALLS.ipt")"; return 1; }
}
@test "a failed start removes the new SNAT rule before the rollback" {
    require_flock
    each_manage _exit_rollback_removes_new_rule
}

@test "installer: a step 6 failure after the stop for an exit change starts the service again, both twins" {
    local s
    for s in install_amneziawg.sh install_amneziawg_en.sh; do
        run bash -c '
            log() { :; }; log_error() { echo "ERR $*"; }
            '"$(fn "$s" _awg_start_if_stopped_for_exit)"'
            systemctl() { echo "systemctl $*"; }
            _awg_start_if_stopped_for_exit; echo "-"
            _AWG_STOPPED_FOR_EXIT=1; _awg_start_if_stopped_for_exit; _awg_start_if_stopped_for_exit'
        [ "$output" = $'-\nsystemctl start awg-quick@awg0' ] || { echo "$s: got '$output'"; return 1; }
        fn "$s" _step6_undo_31 | grep -qxE '\s+_awg_start_if_stopped_for_exit' || { echo "$s: the 3.1 undo does not start the service again"; return 1; }
        fn "$s" step6_generate_configs | grep -qF '|| { _awg_start_if_stopped_for_exit; die' || { echo "$s: a render failure does not start the service again"; return 1; }
    done
}
_exit_old_rule_stuck() {
    local conf_before
    manage "$1" exit-ip 203.0.113.7
    [ "$status" -eq 0 ] || { echo "$1: set failed: $stderr"; return 1; }
    conf_before=$(cat "$MGMT_DIR/awg/awg0.conf"); : > "$CALLS"
    export STUB_IPT_STUCK=203.0.113.7
    manage "$1" exit-ip off
    unset STUB_IPT_STUCK
    [ "$status" -ne 0 ] || { echo "$1: off reported success while the old SNAT rule is still in place"; return 1; }
    [ "$(cat "$MGMT_DIR/awg/awg0.conf")" = "$conf_before" ] || { echo "$1: awg0.conf changed"; return 1; }
    [[ "$stderr" == *203.0.113.7* ]] || { echo "$1: the error does not name the rule: $stderr"; return 1; }
    [ "$(calls)" = "systemctl stop awg-quick@awg0|systemctl start awg-quick@awg0" ] || { echo "$1: calls '$(calls)'"; return 1; }
}
@test "exit-ip fails and starts the service again when the old SNAT rule does not go away, both twins" {
    require_flock
    each_manage _exit_old_rule_stuck
}

_exit_rollback_rule_stuck() {
    export STUB_START_FAIL=203.0.113.7 STUB_IPT_STUCK=203.0.113.7
    manage "$1" exit-ip 203.0.113.7 --json
    unset STUB_START_FAIL STUB_IPT_STUCK
    [ "$status" -ne 0 ] || { echo "$1: a failed start reported success"; return 1; }
    [[ "$output" == *"rollback incomplete"* ]] || { echo "$1: rollback reported complete with the new rule left: $output"; return 1; }
    [[ "$stderr" == *SNAT*203.0.113.7* ]] || { echo "$1: no log line names the SNAT rule left behind: $stderr"; return 1; }
}
@test "a rollback that cannot remove the new SNAT rule says so and names it, both twins" {
    require_flock
    each_manage _exit_rollback_rule_stuck
}
# ---------- an interruption while the service is down ----------

_exit_signal_at_stop() {
    local conf_before init_before
    conf_before=$(cat "$MGMT_DIR/awg/awg0.conf"); init_before=$(cat "$MGMT_DIR/awg/awgsetup_cfg.init")
    export STUB_STOP_SIGNAL=1
    manage "$1" exit-ip 203.0.113.7
    unset STUB_STOP_SIGNAL
    [ "$status" -eq 143 ] || { echo "$1: status $status, want 143"; return 1; }
    [ "$(cat "$MGMT_DIR/awg/awg0.conf")" = "$conf_before" ] || { echo "$1: awg0.conf changed"; return 1; }
    [ "$(cat "$MGMT_DIR/awg/awgsetup_cfg.init")" = "$init_before" ] || { echo "$1: init changed"; return 1; }
    [ "$(calls)" = "systemctl stop awg-quick@awg0|systemctl start awg-quick@awg0" ] || { echo "$1: the service was not started again: '$(calls)'"; return 1; }
    local left; left=$(compgen -G "$MGMT_DIR/awg/*.bak.*"; compgen -G "$MGMT_DIR/awg/*.new.*")
    [ -z "$left" ] || { echo "$1: copies left: $left"; return 1; }
}
@test "exit-ip interrupted right at the stop starts the service again on the unchanged config, both twins" {
    require_flock
    each_manage _exit_signal_at_stop
}

_exit_signal_at_new_start() {
    local conf_before init_before
    conf_before=$(cat "$MGMT_DIR/awg/awg0.conf"); init_before=$(cat "$MGMT_DIR/awg/awgsetup_cfg.init")
    export STUB_START_SIGNAL=203.0.113.7
    manage "$1" exit-ip 203.0.113.7
    unset STUB_START_SIGNAL
    [ "$status" -eq 143 ] || { echo "$1: status $status, want 143"; return 1; }
    [ "$(cat "$MGMT_DIR/awg/awg0.conf")" = "$conf_before" ] || { echo "$1: awg0.conf not put back"; return 1; }
    [ "$(cat "$MGMT_DIR/awg/awgsetup_cfg.init")" = "$init_before" ] || { echo "$1: init not put back"; return 1; }
    [ "$(calls)" = "systemctl stop awg-quick@awg0|systemctl start awg-quick@awg0|systemctl start awg-quick@awg0" ] || { echo "$1: calls '$(calls)'"; return 1; }
}
@test "exit-ip interrupted after the files are written puts them back and starts the old config, both twins" {
    require_flock
    each_manage _exit_signal_at_new_start
}

@test "installer: a failed stop for an exit change aborts before the config is written and marks the service for a restart, both twins" {
    local s d="$BATS_TEST_TMPDIR/stopfail"
    for s in install_amneziawg.sh install_amneziawg_en.sh; do
        rm -rf "$d"; mkdir -p "$d"
        printf 'PostUp = a; iptables -t nat -I POSTROUTING -s 10.9.9.1/24 -o eth0 -j SNAT --to-source 203.0.113.7\n' > "$d/awg0.conf"
        run bash -c '
            log() { :; }; log_warn() { :; }
            die() { echo "DIE flag=${_AWG_STOPPED_FOR_EXIT:-0}"; exit 1; }
            '"$(fn "$s" _awg_stop_if_exit_ip_changed)"'
            systemctl() { [[ "$1" == is-active ]] && return 0; [[ "$1" == stop ]] && return 1; return 0; }
            SERVER_CONF_FILE="$1" AWG_EXIT_IP=203.0.113.8
            _awg_stop_if_exit_ip_changed
            echo "went on"
        ' _ "$d/awg0.conf"
        [ "$status" -eq 1 ] && [ "$output" = "DIE flag=1" ] || { echo "$s: status $status, output '$output'"; return 1; }
    done
}

@test "installer: the exit cleanup starts a service stopped for an exit change, and step 7 clears the mark, both twins" {
    local s
    for s in install_amneziawg.sh install_amneziawg_en.sh; do
        run bash -c '
            log() { :; }; log_warn() { :; }; log_error() { :; }; log_debug() { :; }
            _apt_noretry_set=0; _install_cleaned=0; _install_temp_files=()
            '"$(fn "$s" _awg_start_if_stopped_for_exit)"'
            '"$(fn "$s" _install_cleanup)"'
            systemctl() { echo "systemctl $*"; }
            _AWG_STOPPED_FOR_EXIT=1; _install_cleanup; echo "-"
            _install_cleanup'
        [ "$output" = $'systemctl start awg-quick@awg0\n-' ] || { echo "$s: cleanup gave '$output'"; return 1; }
        run bash -c '
            log() { :; }; log_warn() { :; }; log_debug() { :; }; die() { echo "DIE $*"; exit 1; }
            update_state() { :; }; awg_record_device_params() { :; }; check_service_status() { return 0; }
            setup_fail2ban() { :; }; sleep() { :; }
            systemctl() { [[ "$1" == is-active ]] && return 1; return 0; }
            '"$(fn "$s" step7_start_service)"'
            NO_TWEAKS=1 CLIENT_ISOLATION=1 _AWG_STOPPED_FOR_EXIT=1
            step7_start_service
            echo "flag=$_AWG_STOPPED_FOR_EXIT"'
        [ "$output" = "flag=0" ] || { echo "$s: after step 7: '$output'"; return 1; }
    done
}