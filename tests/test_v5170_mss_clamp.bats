#!/usr/bin/env bats
# v5.17.0 (MyAI-sonp): render_server_config emits a TCP MSS clamp in the firewall
# PostUp/PostDown so oversized segments do not blackhole against the 1280 tunnel
# when ICMP "frag needed" is filtered (mobile / double-NAT / cascade paths).
# The MSS is fixed and derived from AWG_MTU (IPv4: MTU-40, IPv6: MTU-60), applied
# bidirectionally (-o %i and -i %i) in the mangle table, SYN only. IPv6 rules are
# gated behind the same condition as the existing ip6tables FORWARD/MASQUERADE.
# shellcheck disable=SC2154

load test_helper

# get_main_nic shells out to `ip route`; stub it so the render path stays hermetic.
stub_nic() {
    get_main_nic() { echo "eth0"; }
    export -f get_main_nic
}

setup_render_env() {
    stub_nic
    create_init_config
    echo "SERVER_PRIV" > "$AWG_DIR/server_private.key"
}

# --- IPv4 clamp (always present, default IPv4-only mode) ---

@test "v5.17: IPv4 MSS clamp in PostUp, egress direction (-o %i), default MTU -> 1240" {
    setup_render_env
    unset ALLOW_IPV6_TUNNEL
    export DISABLE_IPV6=1
    run render_server_config
    [ "$status" -eq 0 ]
    run grep -c 'iptables -t mangle -A FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240' "$SERVER_CONF_FILE"
    [ "$output" = "1" ]
}

@test "v5.17: IPv4 MSS clamp in PostUp, ingress direction (-i %i), default MTU -> 1240" {
    setup_render_env
    unset ALLOW_IPV6_TUNNEL
    export DISABLE_IPV6=1
    run render_server_config
    [ "$status" -eq 0 ]
    run grep -c 'iptables -t mangle -A FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240' "$SERVER_CONF_FILE"
    [ "$output" = "1" ]
}

@test "v5.17: IPv4 MSS clamp mirrored with -D in PostDown (both directions)" {
    setup_render_env
    unset ALLOW_IPV6_TUNNEL
    export DISABLE_IPV6=1
    run render_server_config
    [ "$status" -eq 0 ]
    run grep -c 'iptables -t mangle -D FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240' "$SERVER_CONF_FILE"
    [ "$output" = "1" ]
    run grep -c 'iptables -t mangle -D FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240' "$SERVER_CONF_FILE"
    [ "$output" = "1" ]
}

# --- IPv6 clamp (gated behind the IPv6 tunnel) ---

@test "v5.17: IPv6 MSS clamp present when ALLOW_IPV6_TUNNEL=1, default MTU -> 1220" {
    setup_render_env
    export ALLOW_IPV6_TUNNEL=1
    export IPV6_SUBNET='fddd:2c4:2c4:2c4::/64'
    export DISABLE_IPV6=0
    run render_server_config
    [ "$status" -eq 0 ]
    run grep -c 'ip6tables -t mangle -A FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1220' "$SERVER_CONF_FILE"
    [ "$output" = "1" ]
    run grep -c 'ip6tables -t mangle -A FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1220' "$SERVER_CONF_FILE"
    [ "$output" = "1" ]
    run grep -c 'ip6tables -t mangle -D FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1220' "$SERVER_CONF_FILE"
    [ "$output" = "1" ]
}

@test "v5.17: IPv6 MSS clamp ABSENT in default IPv4-only mode" {
    setup_render_env
    unset ALLOW_IPV6_TUNNEL
    export DISABLE_IPV6=1
    run render_server_config
    [ "$status" -eq 0 ]
    run grep -c 'ip6tables -t mangle' "$SERVER_CONF_FILE"
    [ "$output" = "0" ]
}

# --- MSS auto-derives from AWG_MTU (deterministic, syncs with operator override) ---

@test "v5.17: MSS auto-derives from AWG_MTU override (1420 -> 1380 v4)" {
    setup_render_env
    # AWG_MTU is in the safe_load_config whitelist; render reloads it from the
    # init config, so set it there (not just in the shell env).
    echo "export AWG_MTU=1420" >> "$CONFIG_FILE"
    unset ALLOW_IPV6_TUNNEL
    export DISABLE_IPV6=1
    run render_server_config
    [ "$status" -eq 0 ]
    run grep -c 'TCPMSS --set-mss 1380' "$SERVER_CONF_FILE"
    [ "$output" = "2" ]
    # The default 1240 must NOT appear once a custom MTU is set.
    run grep -c 'TCPMSS --set-mss 1240' "$SERVER_CONF_FILE"
    [ "$output" = "0" ]
}

# --- RU/EN parity of the MSS rule lines ---

@test "v5.17: render_server_config MSS clamp - RU/EN rule lines identical" {
    local ru en
    ru=$(awk '/^render_server_config\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../awg_common.sh" | grep -E 'TCPMSS|mss4=|mss6=|awg_mtu=' | grep -v '^[[:space:]]*#')
    en=$(awk '/^render_server_config\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../awg_common_en.sh" | grep -E 'TCPMSS|mss4=|mss6=|awg_mtu=' | grep -v '^[[:space:]]*#')
    [ -n "$ru" ]
    [ "$ru" = "$en" ]
}
