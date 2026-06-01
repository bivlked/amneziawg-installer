#!/usr/bin/env bats
# Phase 4 (review finding 4.6) - render_client_config with native IPv6:
# SERVER_HAS_NATIVE_IPV6=1 must produce AllowedIPs = 0.0.0.0/0, ::/0
# and a dual-stack Address line.

load test_helper

setup_common() {
    create_server_config
    create_init_config
    # Append IPv6 keys to the init config. These are the "route all" (full
    # tunnel) tests, so force ALLOWED_IPS=0.0.0.0/0 (overrides the split default
    # from create_init_config; safe_load_config is last-wins). Under the
    # intent-mirroring rule a full IPv4 tunnel maps to ::/0 on native IPv6.
    cat >> "$CONFIG_FILE" << 'CONF'
export ALLOWED_IPS='0.0.0.0/0'
export ALLOW_IPV6_TUNNEL=1
export IPV6_SUBNET='fddd:2c4:2c4:2c4::/64'
export SERVER_HAS_NATIVE_IPV6=1
CONF
    safe_load_config "$CONFIG_FILE"
}

@test "v5.15: render_client_config with native IPv6 produces dual-stack Address" {
    setup_common
    render_client_config "testclient" "10.9.9.5" "FAKEPRIVKEY" "FAKEPUBKEY" "1.2.3.4" "39743" "fddd:2c4:2c4:2c4::5"
    local conf="$AWG_DIR/testclient.conf"
    grep -q "Address = 10.9.9.5/32, fddd:2c4:2c4:2c4::5/128" "$conf"
}

@test "v5.15: render_client_config with native IPv6 produces AllowedIPs with ::/0" {
    setup_common
    render_client_config "testclient" "10.9.9.5" "FAKEPRIVKEY" "FAKEPUBKEY" "1.2.3.4" "39743" "fddd:2c4:2c4:2c4::5"
    local conf="$AWG_DIR/testclient.conf"
    grep -q "AllowedIPs = 0.0.0.0/0, ::/0" "$conf"
}

@test "v5.15: render_client_config with native IPv6 Address contains /32 suffix" {
    setup_common
    render_client_config "testclient2" "10.9.9.6" "FAKEPRIVKEY" "FAKEPUBKEY" "1.2.3.4" "39743" "fddd:2c4:2c4:2c4::6"
    local conf="$AWG_DIR/testclient2.conf"
    grep -qP 'Address\s*=.*\/32' "$conf"
}

@test "v5.15: render_client_config with native IPv6 Address contains /128 suffix" {
    setup_common
    render_client_config "testclient3" "10.9.9.7" "FAKEPRIVKEY" "FAKEPUBKEY" "1.2.3.4" "39743" "fddd:2c4:2c4:2c4::7"
    local conf="$AWG_DIR/testclient3.conf"
    grep -qP 'Address\s*=.*/128' "$conf"
}

@test "v5.15: render_client_config native IPv6 - AllowedIPs does NOT contain only 0.0.0.0/0" {
    setup_common
    render_client_config "testclient4" "10.9.9.8" "FAKEPRIVKEY" "FAKEPUBKEY" "1.2.3.4" "39743" "fddd:2c4:2c4:2c4::8"
    local conf="$AWG_DIR/testclient4.conf"
    # Must contain ::/0, not just IPv4 default
    grep -q "::/0" "$conf"
}
