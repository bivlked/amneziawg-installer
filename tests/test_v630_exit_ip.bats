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
        fn "$s" initialize_setup | grep -qF '_awg_exit_ip_check "$AWG_EXIT_IP"' \
            || { echo "$s: initialize_setup does not check the exit address"; return 1; }
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
if [[ "$1" == start && -n "${STUB_START_FAIL:-}" ]]; then
    grep -qF -- "--to-source ${STUB_START_FAIL}" "$STUB_SERVER_CONF" && exit 1
fi
exit 0
STUB
    cat > "$MGMT_DIR/bin/ip" << 'STUB'
#!/bin/bash
for a in ${STUB_ADDRS:-}; do printf '2: eth0    inet %s/24 brd x scope global eth0\n' "$a"; done
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
    unset AWG_SKIP_APPLY CALLS STUB_SERVER_CONF STUB_ADDRS STUB_START_FAIL
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
