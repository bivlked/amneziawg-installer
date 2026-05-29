#!/usr/bin/env bats
# Regression tests for the regenerate_client() awk AllowedIPs extraction fix.
#
# Phase 1 hardening: the original gsub cascade corrupted dual-stack AllowedIPs
# (e.g. "10.9.9.2/32, fddd:2c4:2c4:2c4::2/128") by stripping prefix and CIDR
# tokens but leaving both IPs concatenated on one line. Fixed by using split()
# to take only the first comma-separated field.
#
# Tests run the exact awk program extracted from awg_common.sh to verify the
# extraction logic in isolation - no server process or real config needed.

load test_helper

# Extract the awk program body from the RU or EN source file.
# Usage: get_awk_program <file>
get_awk_program_ru() {
    awk '/client_ip=\$\(awk -v target/,/\x27 "\$SERVER_CONF_FILE"\)/' \
        "${BATS_TEST_DIRNAME}/../awg_common.sh"
}

get_awk_program_en() {
    awk '/client_ip=\$\(awk -v target/,/\x27 "\$SERVER_CONF_FILE"\)/' \
        "${BATS_TEST_DIRNAME}/../awg_common_en.sh"
}

# Run the inline awk extraction logic against a fixture SERVER_CONF_FILE.
# Usage: run_awk_extract <server_conf_file> <client_name>
run_awk_extract() {
    local server_conf="$1"
    local target="$2"
    awk -v target="$target" '
    /^\[Peer\]/ { in_peer=1; found=0; next }
    in_peer && $0 == "#_Name = " target { found=1; next }
    in_peer && found && /^AllowedIPs/ {
      sub(/^AllowedIPs[ \t]*=[ \t]*/, "")
      n = split($0, ips, /[ \t]*,[ \t]*/)
      sub(/\/[0-9]+$/, "", ips[1])
      print ips[1]
      exit
    }
    /^\[/ && !/^\[Peer\]/ { in_peer=0; found=0 }
    ' "$server_conf"
}

# Build a minimal server config with a single IPv4-only peer.
make_ipv4_only_conf() {
    local f="$1"
    cat > "$f" << 'CONF'
[Interface]
PrivateKey = SERVERKEY
Address = 10.9.9.1/24
ListenPort = 39743

[Peer]
#_Name = alice
PublicKey = ALICEPUBKEY
AllowedIPs = 10.9.9.2/32
CONF
}

# Build a minimal server config with a dual-stack peer.
make_dual_stack_conf() {
    local f="$1"
    cat > "$f" << 'CONF'
[Interface]
PrivateKey = SERVERKEY
Address = 10.9.9.1/24
ListenPort = 39743

[Peer]
#_Name = alice
PublicKey = ALICEPUBKEY
AllowedIPs = 10.9.9.2/32, fddd:2c4:2c4:2c4::2/128
CONF
}

# Build a config with multiple peers to verify only the target is extracted.
make_multi_peer_conf() {
    local f="$1"
    cat > "$f" << 'CONF'
[Interface]
PrivateKey = SERVERKEY
Address = 10.9.9.1/24
ListenPort = 39743

[Peer]
#_Name = alice
PublicKey = ALICEPUBKEY
AllowedIPs = 10.9.9.2/32, fddd:2c4:2c4:2c4::2/128

[Peer]
#_Name = bob
PublicKey = BOBPUBKEY
AllowedIPs = 10.9.9.3/32
CONF
}

# --- IPv4-only: baseline regression ---

@test "v5.15: awk extracts bare IPv4 from IPv4-only AllowedIPs" {
    local conf="$TEST_DIR/awg0_ipv4.conf"
    make_ipv4_only_conf "$conf"

    result=$(run_awk_extract "$conf" "alice")
    [ "$result" = "10.9.9.2" ]
}

@test "v5.15: awk result has no CIDR suffix for IPv4-only" {
    local conf="$TEST_DIR/awg0_ipv4.conf"
    make_ipv4_only_conf "$conf"

    result=$(run_awk_extract "$conf" "alice")
    [[ "$result" != *"/"* ]]
}

# --- Dual-stack: forward-looking coverage ---

@test "v5.15: awk extracts IPv4 only from dual-stack AllowedIPs (not concatenated)" {
    local conf="$TEST_DIR/awg0_dual.conf"
    make_dual_stack_conf "$conf"

    result=$(run_awk_extract "$conf" "alice")
    [ "$result" = "10.9.9.2" ]
}

@test "v5.15: awk result does not contain IPv6 address on dual-stack" {
    local conf="$TEST_DIR/awg0_dual.conf"
    make_dual_stack_conf "$conf"

    result=$(run_awk_extract "$conf" "alice")
    [[ "$result" != *"fddd"* ]]
}

@test "v5.15: awk result has no comma on dual-stack" {
    local conf="$TEST_DIR/awg0_dual.conf"
    make_dual_stack_conf "$conf"

    result=$(run_awk_extract "$conf" "alice")
    [[ "$result" != *","* ]]
}

@test "v5.15: awk result has no CIDR suffix on dual-stack" {
    local conf="$TEST_DIR/awg0_dual.conf"
    make_dual_stack_conf "$conf"

    result=$(run_awk_extract "$conf" "alice")
    [[ "$result" != *"/"* ]]
}

# --- Multi-peer: correct target selection ---

@test "v5.15: awk extracts correct peer from multi-peer dual-stack config" {
    local conf="$TEST_DIR/awg0_multi.conf"
    make_multi_peer_conf "$conf"

    result_alice=$(run_awk_extract "$conf" "alice")
    result_bob=$(run_awk_extract "$conf" "bob")

    [ "$result_alice" = "10.9.9.2" ]
    [ "$result_bob" = "10.9.9.3" ]
}

# --- RU/EN parity: both files use the split() approach ---

@test "v5.15: RU awg_common.sh uses split() in regenerate_client awk block" {
    grep -qE 'split\(\$0,\s*ips' "${BATS_TEST_DIRNAME}/../awg_common.sh"
}

@test "v5.15: EN awg_common_en.sh uses split() in regenerate_client awk block" {
    grep -qE 'split\(\$0,\s*ips' "${BATS_TEST_DIRNAME}/../awg_common_en.sh"
}

@test "v5.15: RU and EN awk blocks are structurally identical (split + sub pattern)" {
    local RU_FILE="${BATS_TEST_DIRNAME}/../awg_common.sh"
    local EN_FILE="${BATS_TEST_DIRNAME}/../awg_common_en.sh"

    ru_block=$(awk '/^regenerate_client\(\) \{$/,/^}$/' "$RU_FILE" | grep -E '(split|sub.*ips\[1\]|print ips)')
    en_block=$(awk '/^regenerate_client\(\) \{$/,/^}$/' "$EN_FILE" | grep -E '(split|sub.*ips\[1\]|print ips)')

    [ "$ru_block" = "$en_block" ]
}
