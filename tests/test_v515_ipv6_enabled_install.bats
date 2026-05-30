#!/usr/bin/env bats
# Phase 3 (v5.15.0): render_server_config produces a dual-stack [Interface]
# Address and activates the ip6tables PostUp/PostDown rules when the IPv6
# tunnel is enabled (ALLOW_IPV6_TUNNEL=1).
# shellcheck disable=SC2154

load test_helper

# get_main_nic shells out to `ip route`; stub it to a deterministic value so
# the render path stays hermetic on any host.
stub_nic() {
    get_main_nic() { echo "eth0"; }
    export -f get_main_nic
}

setup_render_env() {
    stub_nic
    create_init_config
    echo "SERVER_PRIV" > "$AWG_DIR/server_private.key"
}

@test "render_server_config: dual-stack Address when ALLOW_IPV6_TUNNEL=1" {
    setup_render_env
    export ALLOW_IPV6_TUNNEL=1
    export IPV6_SUBNET='fddd:2c4:2c4:2c4::/64'
    export DISABLE_IPV6=0
    run render_server_config
    [ "$status" -eq 0 ]
    run grep -c '^Address = 10\.9\.9\.1/24, fddd:2c4:2c4:2c4::1/64$' "$SERVER_CONF_FILE"
    [ "$output" = "1" ]
}

@test "render_server_config: ip6tables PostUp activated when ALLOW_IPV6_TUNNEL=1" {
    setup_render_env
    export ALLOW_IPV6_TUNNEL=1
    export IPV6_SUBNET='fddd:2c4:2c4:2c4::/64'
    export DISABLE_IPV6=0
    run render_server_config
    [ "$status" -eq 0 ]
    run grep -c 'ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE' "$SERVER_CONF_FILE"
    [ "$output" = "1" ]
    run grep -c 'ip6tables -I FORWARD -i %i -j ACCEPT' "$SERVER_CONF_FILE"
    [ "$output" = "1" ]
}

@test "render_server_config: ip6tables PostDown activated when ALLOW_IPV6_TUNNEL=1" {
    setup_render_env
    export ALLOW_IPV6_TUNNEL=1
    export IPV6_SUBNET='fddd:2c4:2c4:2c4::/64'
    export DISABLE_IPV6=0
    run render_server_config
    [ "$status" -eq 0 ]
    run grep -c 'ip6tables -t nat -D POSTROUTING -o eth0 -j MASQUERADE' "$SERVER_CONF_FILE"
    [ "$output" = "1" ]
}

@test "render_server_config: ip6tables uses detected nic, not hardcoded ens3" {
    setup_render_env
    export ALLOW_IPV6_TUNNEL=1
    export IPV6_SUBNET='fddd:2c4:2c4:2c4::/64'
    export DISABLE_IPV6=0
    run render_server_config
    [ "$status" -eq 0 ]
    run grep -c 'ip6tables.*-o ens3' "$SERVER_CONF_FILE"
    [ "$output" = "0" ]
}

@test "render_server_config: IPv6 server addr derived from custom IPV6_SUBNET" {
    setup_render_env
    export ALLOW_IPV6_TUNNEL=1
    export IPV6_SUBNET='fd11:2222:3333:4444::/64'
    export DISABLE_IPV6=0
    run render_server_config
    [ "$status" -eq 0 ]
    run grep -c '^Address = 10\.9\.9\.1/24, fd11:2222:3333:4444::1/64$' "$SERVER_CONF_FILE"
    [ "$output" = "1" ]
}

@test "render_server_config: regression - IPv4-only Address when flag absent" {
    setup_render_env
    unset ALLOW_IPV6_TUNNEL
    unset IPV6_SUBNET
    export DISABLE_IPV6=1
    run render_server_config
    [ "$status" -eq 0 ]
    # Byte-for-byte v5.14.x: single IPv4 Address, no comma, no IPv6 literal.
    run grep -c '^Address = 10\.9\.9\.1/24$' "$SERVER_CONF_FILE"
    [ "$output" = "1" ]
    run grep -c 'ip6tables' "$SERVER_CONF_FILE"
    [ "$output" = "0" ]
    run grep -c 'fddd:' "$SERVER_CONF_FILE"
    [ "$output" = "0" ]
}

@test "render_server_config: regression - ALLOW_IPV6_TUNNEL=0 stays IPv4-only" {
    setup_render_env
    export ALLOW_IPV6_TUNNEL=0
    export IPV6_SUBNET='fddd:2c4:2c4:2c4::/64'
    export DISABLE_IPV6=1
    run render_server_config
    [ "$status" -eq 0 ]
    # Trap #1: "0" is non-empty, must NOT trigger dual-stack via :+ expansion.
    run grep -c '^Address = 10\.9\.9\.1/24$' "$SERVER_CONF_FILE"
    [ "$output" = "1" ]
    run grep -c 'ip6tables' "$SERVER_CONF_FILE"
    [ "$output" = "0" ]
}

@test "render_server_config: legacy --allow-ipv6 (DISABLE_IPV6=0, no tunnel) keeps ip6tables, IPv4-only Address" {
    setup_render_env
    # render_server_config reloads vars via load_awg_params, so set DISABLE_IPV6=0
    # in the init config itself (this is what an --allow-ipv6 install writes).
    sed -i 's/^export DISABLE_IPV6=1$/export DISABLE_IPV6=0/' "$CONFIG_FILE"
    export ALLOW_IPV6_TUNNEL=0
    export IPV6_SUBNET='fddd:2c4:2c4:2c4::/64'
    run render_server_config
    [ "$status" -eq 0 ]
    # v5.14.x parity: --allow-ipv6 (host IPv6 on) still gets ip6tables PostUp/PostDown.
    run grep -c 'ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE' "$SERVER_CONF_FILE"
    [ "$output" = "1" ]
    run grep -c 'ip6tables -t nat -D POSTROUTING -o eth0 -j MASQUERADE' "$SERVER_CONF_FILE"
    [ "$output" = "1" ]
    # But Address stays IPv4-only without the tunnel flag (no dual-stack literal).
    run grep -c '^Address = 10\.9\.9\.1/24$' "$SERVER_CONF_FILE"
    [ "$output" = "1" ]
    run grep -c 'fddd:' "$SERVER_CONF_FILE"
    [ "$output" = "0" ]
}

@test "_derive_ipv6_server_addr: ::/64 subnet maps to ::1/64" {
    run _derive_ipv6_server_addr 'fddd:2c4:2c4:2c4::/64'
    [ "$status" -eq 0 ]
    [ "$output" = "fddd:2c4:2c4:2c4::1/64" ]
}

@test "_derive_ipv6_server_addr: fallback returns input when no ::/ present" {
    run _derive_ipv6_server_addr 'fddd:2c4:2c4:2c4:1/64'
    [ "$status" -eq 0 ]
    [ "$output" = "fddd:2c4:2c4:2c4:1/64" ]
}

@test "render_server_config: RU/EN parity - dual-stack Address block identical" {
    local ru en
    ru=$(awk '/^render_server_config\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../awg_common.sh" | grep -E 'address_line|ALLOW_IPV6_TUNNEL|ip6tables')
    en=$(awk '/^render_server_config\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../awg_common_en.sh" | grep -E 'address_line|ALLOW_IPV6_TUNNEL|ip6tables')
    [ "$ru" = "$en" ]
}

@test "_derive_ipv6_server_addr: RU/EN parity - identical helper body" {
    local ru en
    ru=$(awk '/^_derive_ipv6_server_addr\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../awg_common.sh")
    en=$(awk '/^_derive_ipv6_server_addr\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../awg_common_en.sh")
    [ "$ru" = "$en" ]
}
