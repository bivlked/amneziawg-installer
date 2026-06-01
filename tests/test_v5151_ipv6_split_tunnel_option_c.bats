#!/usr/bin/env bats
# v5.15.1 (audit C7) - intent-mirroring of the IPv4 routing mode into IPv6.
#
# When the client uses a SPLIT tunnel (custom ALLOWED_IPS, not 0.0.0.0/0),
# render_client_config must keep the IPv4 split list AS-IS and append ONLY the
# tunnel ULA - never ::/0. There is no IPv6 split-list, so routing all IPv6 into
# the tunnel would silently break the user's split-tunnel intent.
#
# create_init_config seeds a split ALLOWED_IPS ('0.0.0.0/5, 8.0.0.0/7'), so these
# tests exercise the split path directly without overriding it.

load test_helper

setup_split_native() {
    create_server_config
    create_init_config   # ALLOWED_IPS='0.0.0.0/5, 8.0.0.0/7' (split)
    cat >> "$CONFIG_FILE" << 'CONF'
export ALLOW_IPV6_TUNNEL=1
export IPV6_SUBNET='fddd:2c4:2c4:2c4::/64'
export SERVER_HAS_NATIVE_IPV6=1
CONF
    safe_load_config "$CONFIG_FILE"
}

setup_split_no_native() {
    create_server_config
    create_init_config
    cat >> "$CONFIG_FILE" << 'CONF'
export ALLOW_IPV6_TUNNEL=1
export IPV6_SUBNET='fddd:2c4:2c4:2c4::/64'
export SERVER_HAS_NATIVE_IPV6=0
CONF
    safe_load_config "$CONFIG_FILE"
}

@test "v5.15.1 C7: split tunnel + native IPv6 keeps IPv4 split and appends only the ULA" {
    setup_split_native
    render_client_config "splitnat" "10.9.9.20" "FAKEPRIVKEY" "FAKEPUBKEY" "1.2.3.4" "39743" "fddd:2c4:2c4:2c4::20"
    local conf="$AWG_DIR/splitnat.conf"
    grep -q "AllowedIPs = 0.0.0.0/5, 8.0.0.0/7, fddd:2c4:2c4:2c4::/64" "$conf"
}

@test "v5.15.1 C7: split tunnel + native IPv6 does NOT add ::/0" {
    setup_split_native
    render_client_config "splitnat2" "10.9.9.21" "FAKEPRIVKEY" "FAKEPUBKEY" "1.2.3.4" "39743" "fddd:2c4:2c4:2c4::21"
    local conf="$AWG_DIR/splitnat2.conf"
    ! grep -q "::/0" "$conf"
}

@test "v5.15.1 C7: split tunnel + no native IPv6 keeps IPv4 split and appends only the ULA" {
    setup_split_no_native
    render_client_config "splitno" "10.9.9.22" "FAKEPRIVKEY" "FAKEPUBKEY" "1.2.3.4" "39743" "fddd:2c4:2c4:2c4::22"
    local conf="$AWG_DIR/splitno.conf"
    grep -q "AllowedIPs = 0.0.0.0/5, 8.0.0.0/7, fddd:2c4:2c4:2c4::/64" "$conf"
}

@test "v5.15.1 C7: split tunnel preserves the IPv4 split (not collapsed to 0.0.0.0/0)" {
    setup_split_native
    render_client_config "splitnat3" "10.9.9.23" "FAKEPRIVKEY" "FAKEPUBKEY" "1.2.3.4" "39743" "fddd:2c4:2c4:2c4::23"
    local conf="$AWG_DIR/splitnat3.conf"
    grep -qP '^AllowedIPs = 0\.0\.0\.0/5, 8\.0\.0\.0/7,' "$conf"
    ! grep -qP '^AllowedIPs = 0\.0\.0\.0/0' "$conf"
}
