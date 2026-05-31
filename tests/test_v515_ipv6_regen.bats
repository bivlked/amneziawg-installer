#!/usr/bin/env bats
# Phase 5 - regenerate_client dual-stack support.
#
# Verifies that regenerate_client correctly reads client_ipv6 from
# existing dual-stack AllowedIPs in awg0.conf and passes it to
# render_client_config.
#
# Approach: stub render_client_config to capture arguments, then
# inspect what client_ipv6 value was passed as arg $7.

load test_helper

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Build a minimal dual-stack server config with one peer
_make_dualstack_server_conf() {
    local name="$1" ipv4="$2" ipv6="$3"
    cat > "$SERVER_CONF_FILE" << EOF
[Interface]
PrivateKey = SERVERKEY
Address = 10.9.9.1/24, fddd:2c4:2c4:2c4::1/64
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
PostUp = iptables -I FORWARD -i %i -j ACCEPT
PostDown = iptables -D FORWARD -i %i -j ACCEPT

[Peer]
#_Name = ${name}
PublicKey = TESTPUBKEY
AllowedIPs = ${ipv4}/32, ${ipv6}/128
EOF
}

# Build a minimal IPv4-only server config with one peer
_make_ipv4only_server_conf() {
    local name="$1" ipv4="$2"
    cat > "$SERVER_CONF_FILE" << EOF
[Interface]
PrivateKey = SERVERKEY
Address = 10.9.9.1/24
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
PostUp = iptables -I FORWARD -i %i -j ACCEPT
PostDown = iptables -D FORWARD -i %i -j ACCEPT

[Peer]
#_Name = ${name}
PublicKey = TESTPUBKEY
AllowedIPs = ${ipv4}/32
EOF
}

# ---------------------------------------------------------------------------
# Task A: dual-stack AllowedIPs -> client_ipv6 passed to render_client_config
# ---------------------------------------------------------------------------

@test "v5.15: regenerate_client passes client_ipv6 from dual-stack AllowedIPs when ALLOW_IPV6_TUNNEL=1" {
    require_flock
    _make_dualstack_server_conf "alice" "10.9.9.2" "fddd:2c4:2c4:2c4::2"

    # Store privkey
    mkdir -p "$KEYS_DIR"
    printf 'FAKEPRIVKEY' > "$KEYS_DIR/alice.private"
    echo "$AWG_DIR/server_public.key: FAKEPUBKEY" > /dev/null
    printf 'FAKESERVERPUB' > "$AWG_DIR/server_public.key"

    # Stub external dependencies
    get_server_public_ip() { echo "1.2.3.4"; }
    _ensure_server_public_key() { return 0; }
    generate_qr()          { return 0; }
    generate_vpn_uri()     { return 0; }
    generate_qr_vpnuri()   { return 0; }
    load_awg_params()      { export AWG_PORT=39743; return 0; }
    export -f get_server_public_ip _ensure_server_public_key generate_qr generate_vpn_uri generate_qr_vpnuri load_awg_params

    # Capture render_client_config args
    local captured_args_file="$TEST_DIR/rcc_args"
    render_client_config() {
        printf '%s\n' "$@" > "$captured_args_file"
        # Write minimal conf so sed restore steps pass
        printf '[Interface]\nPrivateKey = FAKEPRIVKEY\nAddress = %s/32\nDNS = 1.1.1.1\nMTU = 1280\nPersistentKeepalive = 33\n[Peer]\nPublicKey = FAKESERVERPUB\nAllowedIPs = 0.0.0.0/0\n' "$2" > "$AWG_DIR/${1}.conf"
        return 0
    }
    export -f render_client_config

    export ALLOW_IPV6_TUNNEL=1
    export IPV6_SUBNET="fddd:2c4:2c4:2c4::/64"

    run regenerate_client "alice"
    [ "$status" -eq 0 ]

    # arg $7 should be the IPv6 address (without prefix length)
    local arg7
    arg7=$(sed -n '7p' "$captured_args_file")
    [ "$arg7" = "fddd:2c4:2c4:2c4::2" ]
}

@test "v5.15: regenerate_client does NOT pass IPv6 when ALLOW_IPV6_TUNNEL=0 (backward compat)" {
    require_flock
    _make_dualstack_server_conf "bob" "10.9.9.3" "fddd:2c4:2c4:2c4::3"

    mkdir -p "$KEYS_DIR"
    printf 'FAKEPRIVKEY' > "$KEYS_DIR/bob.private"
    printf 'FAKESERVERPUB' > "$AWG_DIR/server_public.key"

    get_server_public_ip() { echo "1.2.3.4"; }
    _ensure_server_public_key() { return 0; }
    generate_qr()          { return 0; }
    generate_vpn_uri()     { return 0; }
    generate_qr_vpnuri()   { return 0; }
    load_awg_params()      { export AWG_PORT=39743; return 0; }
    export -f get_server_public_ip _ensure_server_public_key generate_qr generate_vpn_uri generate_qr_vpnuri load_awg_params

    local captured_args_file="$TEST_DIR/rcc_args_bob"
    render_client_config() {
        printf '%s\n' "$@" > "$captured_args_file"
        printf '[Interface]\nPrivateKey = FAKEPRIVKEY\nAddress = %s/32\nDNS = 1.1.1.1\nMTU = 1280\nPersistentKeepalive = 33\n[Peer]\nPublicKey = FAKESERVERPUB\nAllowedIPs = 0.0.0.0/0\n' "$2" > "$AWG_DIR/${1}.conf"
        return 0
    }
    export -f render_client_config

    export ALLOW_IPV6_TUNNEL=0
    export IPV6_SUBNET="fddd:2c4:2c4:2c4::/64"

    run regenerate_client "bob"
    [ "$status" -eq 0 ]

    # arg $7 should be empty or absent
    local arg7
    arg7=$(sed -n '7p' "$captured_args_file")
    [ -z "$arg7" ]
}

@test "v5.15: regenerate_client with IPv4-only AllowedIPs produces empty client_ipv6 even when ALLOW_IPV6_TUNNEL=1" {
    require_flock
    _make_ipv4only_server_conf "carol" "10.9.9.4"

    mkdir -p "$KEYS_DIR"
    printf 'FAKEPRIVKEY' > "$KEYS_DIR/carol.private"
    printf 'FAKESERVERPUB' > "$AWG_DIR/server_public.key"

    get_server_public_ip() { echo "1.2.3.4"; }
    _ensure_server_public_key() { return 0; }
    generate_qr()          { return 0; }
    generate_vpn_uri()     { return 0; }
    generate_qr_vpnuri()   { return 0; }
    load_awg_params()      { export AWG_PORT=39743; return 0; }
    export -f get_server_public_ip _ensure_server_public_key generate_qr generate_vpn_uri generate_qr_vpnuri load_awg_params

    local captured_args_file="$TEST_DIR/rcc_args_carol"
    render_client_config() {
        printf '%s\n' "$@" > "$captured_args_file"
        printf '[Interface]\nPrivateKey = FAKEPRIVKEY\nAddress = %s/32\nDNS = 1.1.1.1\nMTU = 1280\nPersistentKeepalive = 33\n[Peer]\nPublicKey = FAKESERVERPUB\nAllowedIPs = 0.0.0.0/0\n' "$2" > "$AWG_DIR/${1}.conf"
        return 0
    }
    export -f render_client_config

    export ALLOW_IPV6_TUNNEL=1
    export IPV6_SUBNET="fddd:2c4:2c4:2c4::/64"

    run regenerate_client "carol"
    [ "$status" -eq 0 ]

    # arg $7 should be empty (no IPv6 in AllowedIPs)
    local arg7
    arg7=$(sed -n '7p' "$captured_args_file")
    [ -z "$arg7" ]
}

# ---------------------------------------------------------------------------
# RU/EN parity: both files extract client_ipv6 from awg0.conf
# ---------------------------------------------------------------------------

@test "v5.15: RU awg_common.sh regenerate_client reads client_ipv6 from AllowedIPs" {
    grep -q 'client_ipv6' "${BATS_TEST_DIRNAME}/../awg_common.sh"
}

@test "v5.15: EN awg_common_en.sh regenerate_client reads client_ipv6 from AllowedIPs" {
    grep -q 'client_ipv6' "${BATS_TEST_DIRNAME}/../awg_common_en.sh"
}

@test "v5.15: RU regenerate_client passes client_ipv6 as 7th arg to render_client_config" {
    grep -q 'render_client_config.*client_ipv6' "${BATS_TEST_DIRNAME}/../awg_common.sh"
}

@test "v5.15: EN regenerate_client passes client_ipv6 as 7th arg to render_client_config" {
    grep -q 'render_client_config.*client_ipv6' "${BATS_TEST_DIRNAME}/../awg_common_en.sh"
}

@test "v5.15: RU and EN regenerate_client both have ALLOW_IPV6_TUNNEL guard clearing client_ipv6" {
    # Both files must contain the guard that clears client_ipv6 when tunnel is disabled
    grep -q 'ALLOW_IPV6_TUNNEL' "${BATS_TEST_DIRNAME}/../awg_common.sh"
    grep -q 'ALLOW_IPV6_TUNNEL' "${BATS_TEST_DIRNAME}/../awg_common_en.sh"
    # Both must reset client_ipv6 to empty when ALLOW_IPV6_TUNNEL != 1
    grep -q 'client_ipv6=""' "${BATS_TEST_DIRNAME}/../awg_common.sh"
    grep -q 'client_ipv6=""' "${BATS_TEST_DIRNAME}/../awg_common_en.sh"
}
