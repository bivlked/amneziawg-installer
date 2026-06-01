#!/usr/bin/env bats
# Phase 4 (review finding 4.6) - render_client_config without native IPv6:
# SERVER_HAS_NATIVE_IPV6=0 must produce AllowedIPs = 0.0.0.0/0, <IPV6_SUBNET>
# (tunnel-subnet only, NOT ::/0, to avoid IPv6 blackhole on the internet).

load test_helper

setup_no_native() {
    create_server_config
    create_init_config
    # "route all" (full tunnel) tests: force ALLOWED_IPS=0.0.0.0/0 (overrides the
    # split default from create_init_config; safe_load_config is last-wins). With
    # no native IPv6 a full tunnel maps to the tunnel ULA, never ::/0.
    cat >> "$CONFIG_FILE" << 'CONF'
export ALLOWED_IPS='0.0.0.0/0'
export ALLOW_IPV6_TUNNEL=1
export IPV6_SUBNET='fddd:2c4:2c4:2c4::/64'
export SERVER_HAS_NATIVE_IPV6=0
CONF
    safe_load_config "$CONFIG_FILE"
}

@test "v5.15: render_client_config no-native IPv6 produces dual-stack Address" {
    setup_no_native
    render_client_config "testclient" "10.9.9.5" "FAKEPRIVKEY" "FAKEPUBKEY" "1.2.3.4" "39743" "fddd:2c4:2c4:2c4::5"
    local conf="$AWG_DIR/testclient.conf"
    grep -q "Address = 10.9.9.5/32, fddd:2c4:2c4:2c4::5/128" "$conf"
}

@test "v5.15: render_client_config no-native IPv6 AllowedIPs contains IPv6 tunnel subnet" {
    setup_no_native
    render_client_config "testclient" "10.9.9.5" "FAKEPRIVKEY" "FAKEPUBKEY" "1.2.3.4" "39743" "fddd:2c4:2c4:2c4::5"
    local conf="$AWG_DIR/testclient.conf"
    grep -q "fddd:2c4:2c4:2c4::/64" "$conf"
}

@test "v5.15: render_client_config no-native IPv6 AllowedIPs does NOT contain ::/0" {
    setup_no_native
    render_client_config "testclient" "10.9.9.5" "FAKEPRIVKEY" "FAKEPUBKEY" "1.2.3.4" "39743" "fddd:2c4:2c4:2c4::5"
    local conf="$AWG_DIR/testclient.conf"
    # Must NOT have full IPv6 default route - would be a blackhole
    run grep -q "::/0" "$conf"
    [ "$status" -ne 0 ]
}

@test "v5.15: render_client_config no-native IPv6 AllowedIPs has exact expected value" {
    setup_no_native
    render_client_config "testclient2" "10.9.9.6" "FAKEPRIVKEY" "FAKEPUBKEY" "1.2.3.4" "39743" "fddd:2c4:2c4:2c4::6"
    local conf="$AWG_DIR/testclient2.conf"
    grep -q "AllowedIPs = 0.0.0.0/0, fddd:2c4:2c4:2c4::/64" "$conf"
}

# --- Legacy client (no IPv6 arg) is unchanged ---

@test "v5.15: render_client_config legacy client (no ipv6 arg) Address is IPv4-only" {
    setup_no_native
    render_client_config "legacyclient" "10.9.9.10" "FAKEPRIVKEY" "FAKEPUBKEY" "1.2.3.4" "39743"
    local conf="$AWG_DIR/legacyclient.conf"
    grep -q "^Address = 10.9.9.10/32$" "$conf"
}

@test "v5.15: render_client_config legacy client AllowedIPs does not contain IPv6" {
    setup_no_native
    render_client_config "legacyclient" "10.9.9.10" "FAKEPRIVKEY" "FAKEPUBKEY" "1.2.3.4" "39743"
    local conf="$AWG_DIR/legacyclient.conf"
    run grep -q "fddd:" "$conf"
    [ "$status" -ne 0 ]
}
