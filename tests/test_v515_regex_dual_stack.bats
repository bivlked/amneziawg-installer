#!/usr/bin/env bats
# Regression tests for the generate_vpn_uri() client_ip regex fix.
#
# Phase 1 hardening: replaced the ambiguous [0-9./]+ pattern with an explicit
# IPv4 dotted-decimal regex so that the intent is clear and the extraction is
# stable when a dual-stack "Address = 10.x.x.x/32, fddd::.../128" line is
# present in a client .conf file.
#
# For Phase 1 scope the function still extracts only the IPv4 address (with
# optional CIDR suffix) - the IPv6 part of the URI is a Phase 4 deliverable.

load test_helper

# Apply the exact extraction regex from generate_vpn_uri against a fixture.
# Usage: extract_client_ip <conf_file>
extract_client_ip() {
    grep -oP 'Address\s*=\s*\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(?:/[0-9]+)?' "$1"
}

# Build a minimal client conf with IPv4-only Address.
make_client_ipv4_conf() {
    local f="$1"
    cat > "$f" << 'CONF'
[Interface]
PrivateKey = CLIENTPRIVKEY
Address = 10.9.9.2/32
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = SERVERPUBKEY
AllowedIPs = 0.0.0.0/0
Endpoint = 1.2.3.4:39743
PersistentKeepalive = 33
CONF
}

# Build a minimal client conf with dual-stack Address.
make_client_dual_stack_conf() {
    local f="$1"
    cat > "$f" << 'CONF'
[Interface]
PrivateKey = CLIENTPRIVKEY
Address = 10.9.9.2/32, fddd:2c4:2c4:2c4::2/128
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = SERVERPUBKEY
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 1.2.3.4:39743
PersistentKeepalive = 33
CONF
}

# --- IPv4-only: baseline regression ---

@test "v5.15: regex extracts IPv4 with CIDR from IPv4-only Address line" {
    require_grep_P
    local conf="$TEST_DIR/client_ipv4.conf"
    make_client_ipv4_conf "$conf"

    result=$(extract_client_ip "$conf")
    [ "$result" = "10.9.9.2/32" ]
}

@test "v5.15: regex returns non-empty for IPv4-only Address" {
    require_grep_P
    local conf="$TEST_DIR/client_ipv4.conf"
    make_client_ipv4_conf "$conf"

    result=$(extract_client_ip "$conf")
    [ -n "$result" ]
}

# --- Dual-stack: forward-looking coverage ---

@test "v5.15: regex extracts IPv4 part only from dual-stack Address line" {
    require_grep_P
    local conf="$TEST_DIR/client_dual.conf"
    make_client_dual_stack_conf "$conf"

    result=$(extract_client_ip "$conf")
    [ "$result" = "10.9.9.2/32" ]
}

@test "v5.15: regex result does not contain IPv6 on dual-stack Address" {
    require_grep_P
    local conf="$TEST_DIR/client_dual.conf"
    make_client_dual_stack_conf "$conf"

    result=$(extract_client_ip "$conf")
    [[ "$result" != *"fddd"* ]]
    [[ "$result" != *":"* ]]
}

@test "v5.15: regex result does not contain comma on dual-stack Address" {
    require_grep_P
    local conf="$TEST_DIR/client_dual.conf"
    make_client_dual_stack_conf "$conf"

    result=$(extract_client_ip "$conf")
    [[ "$result" != *","* ]]
}

# --- RU/EN parity: both files use the explicit IPv4 regex ---

@test "v5.15: RU awg_common.sh generate_vpn_uri uses explicit IPv4 dotted-decimal regex" {
    require_grep_P
    grep -qP 'Address\\s\*=\\s\*\\K\[0-9\]\+\\.\[0-9\]\+\\.\[0-9\]\+\\.\[0-9\]\+' \
        "${BATS_TEST_DIRNAME}/../awg_common.sh"
}

@test "v5.15: EN awg_common_en.sh generate_vpn_uri uses explicit IPv4 dotted-decimal regex" {
    require_grep_P
    grep -qP 'Address\\s\*=\\s\*\\K\[0-9\]\+\\.\[0-9\]\+\\.\[0-9\]\+\\.\[0-9\]\+' \
        "${BATS_TEST_DIRNAME}/../awg_common_en.sh"
}

@test "v5.15: RU and EN generate_vpn_uri client_ip extraction lines are identical" {
    local RU_FILE="${BATS_TEST_DIRNAME}/../awg_common.sh"
    local EN_FILE="${BATS_TEST_DIRNAME}/../awg_common_en.sh"

    # Extract the client_ip= assignment line that greps for Address in generate_vpn_uri
    ru_line=$(grep 'client_ip=.*grep.*Address' "$RU_FILE" | grep -v '^\s*#')
    en_line=$(grep 'client_ip=.*grep.*Address' "$EN_FILE" | grep -v '^\s*#')

    # Both lines must contain the explicit dotted-decimal IPv4 pattern
    [[ "$ru_line" == *'[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'* ]]
    [[ "$en_line" == *'[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'* ]]
    # Both lines must be identical (RU/EN parity)
    [ "$ru_line" = "$en_line" ]
}
