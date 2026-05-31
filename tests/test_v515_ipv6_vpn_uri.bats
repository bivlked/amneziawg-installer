#!/usr/bin/env bats
# Phase 4 - generate_vpn_uri: dual-stack .conf produces client_ipv6 field
# in the vpn:// URI JSON, and IPv4-only .conf produces empty client_ipv6.
#
# Tests verify the bash-level extraction of client_ip (IPv4) and client_ipv6
# from a dual-stack Address line, since the Perl vpn:// URI requires perl
# + Compress::Zlib which is not guaranteed in the test environment.
# The extraction logic is tested as standalone awk programs.

load test_helper

# Helper: create dual-stack client .conf
make_dual_stack_client_conf() {
    local f="$1"
    cat > "$f" << 'CONF'
[Interface]
PrivateKey = TESTPRIVKEY
Address = 10.9.9.5/32, fddd:2c4:2c4:2c4::5/128
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = TESTPUBKEY
Endpoint = 1.2.3.4:39743
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 33
CONF
}

# Helper: create IPv4-only client .conf
make_ipv4_only_client_conf() {
    local f="$1"
    cat > "$f" << 'CONF'
[Interface]
PrivateKey = TESTPRIVKEY
Address = 10.9.9.3/32
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = TESTPUBKEY
Endpoint = 1.2.3.4:39743
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 33
CONF
}

# Awk extraction matching what generate_vpn_uri does for client_ip
extract_client_ip_awk() {
    local conf="$1"
    awk '/^Address[[:space:]]*=/{
        sub(/^Address[[:space:]]*=[[:space:]]*/, "")
        n = split($0, parts, /[[:space:]]*,[[:space:]]*/)
        sub(/\/[0-9]+$/, "", parts[1])
        print parts[1]; exit
    }' "$conf"
}

# Awk extraction matching what generate_vpn_uri does for client_ipv6
extract_client_ipv6_awk() {
    local conf="$1"
    awk '/^Address[[:space:]]*=/{
        sub(/^Address[[:space:]]*=[[:space:]]*/, "")
        n = split($0, parts, /[[:space:]]*,[[:space:]]*/)
        if (n >= 2) {
            sub(/\/[0-9]+$/, "", parts[2])
            gsub(/[[:space:]]/, "", parts[2])
            print parts[2]
        }
        exit
    }' "$conf"
}

# --- Dual-stack extraction ---

@test "v5.15: vpn_uri IPv4 extraction from dual-stack Address returns correct IPv4" {
    local conf="$TEST_DIR/dual.conf"
    make_dual_stack_client_conf "$conf"
    result=$(extract_client_ip_awk "$conf")
    [ "$result" = "10.9.9.5" ]
}

@test "v5.15: vpn_uri IPv6 extraction from dual-stack Address returns correct IPv6" {
    local conf="$TEST_DIR/dual.conf"
    make_dual_stack_client_conf "$conf"
    result=$(extract_client_ipv6_awk "$conf")
    [ "$result" = "fddd:2c4:2c4:2c4::5" ]
}

@test "v5.15: vpn_uri IPv4 extraction from dual-stack has no CIDR suffix" {
    local conf="$TEST_DIR/dual.conf"
    make_dual_stack_client_conf "$conf"
    result=$(extract_client_ip_awk "$conf")
    [[ "$result" != *"/"* ]]
}

@test "v5.15: vpn_uri IPv6 extraction from dual-stack has no CIDR suffix" {
    local conf="$TEST_DIR/dual.conf"
    make_dual_stack_client_conf "$conf"
    result=$(extract_client_ipv6_awk "$conf")
    [[ "$result" != *"/"* ]]
}

@test "v5.15: vpn_uri IPv4 extraction from dual-stack has no comma" {
    local conf="$TEST_DIR/dual.conf"
    make_dual_stack_client_conf "$conf"
    result=$(extract_client_ip_awk "$conf")
    [[ "$result" != *","* ]]
}

# --- IPv4-only extraction ---

@test "v5.15: vpn_uri IPv4 extraction from IPv4-only Address returns correct IPv4" {
    local conf="$TEST_DIR/ipv4.conf"
    make_ipv4_only_client_conf "$conf"
    result=$(extract_client_ip_awk "$conf")
    [ "$result" = "10.9.9.3" ]
}

@test "v5.15: vpn_uri IPv6 extraction from IPv4-only Address returns empty string" {
    local conf="$TEST_DIR/ipv4.conf"
    make_ipv4_only_client_conf "$conf"
    result=$(extract_client_ipv6_awk "$conf")
    [ -z "$result" ]
}

# --- RU/EN parity: awk extraction pattern exists in both files ---

@test "v5.15: RU generate_vpn_uri uses awk-based IPv4 extraction" {
    grep -q "awk '/\^Address\[" "${BATS_TEST_DIRNAME}/../awg_common.sh"
}

@test "v5.15: EN generate_vpn_uri uses awk-based IPv4 extraction" {
    grep -q "awk '/\^Address\[" "${BATS_TEST_DIRNAME}/../awg_common_en.sh"
}

@test "v5.15: RU generate_vpn_uri has client_ipv6 in Perl argv" {
    grep -q 'client_ipv6' "${BATS_TEST_DIRNAME}/../awg_common.sh"
}

@test "v5.15: EN generate_vpn_uri has client_ipv6 in Perl argv" {
    grep -q 'client_ipv6' "${BATS_TEST_DIRNAME}/../awg_common_en.sh"
}
