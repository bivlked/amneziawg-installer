#!/usr/bin/env bats
# Phase 4 - get_next_client_ipv6: deterministic IPv6 from IPv4 last-octet.
#
# Verifies that get_next_client_ipv6 returns the expected ULA address for
# a given IPv4 address, and that RU/EN parity holds.

load test_helper

# --- Basic allocation ---

@test "v5.15: get_next_client_ipv6 returns ::3 for 10.9.9.3" {
    export IPV6_SUBNET="fddd:2c4:2c4:2c4::/64"
    result=$(get_next_client_ipv6 "10.9.9.3")
    [ "$result" = "fddd:2c4:2c4:2c4::3" ]
}

@test "v5.15: get_next_client_ipv6 returns ::100 for 10.9.9.100" {
    export IPV6_SUBNET="fddd:2c4:2c4:2c4::/64"
    result=$(get_next_client_ipv6 "10.9.9.100")
    [ "$result" = "fddd:2c4:2c4:2c4::100" ]
}

@test "v5.15: get_next_client_ipv6 returns ::2 for 10.9.9.2" {
    export IPV6_SUBNET="fddd:2c4:2c4:2c4::/64"
    result=$(get_next_client_ipv6 "10.9.9.2")
    [ "$result" = "fddd:2c4:2c4:2c4::2" ]
}

@test "v5.15: get_next_client_ipv6 returns ::254 for 10.9.9.254" {
    export IPV6_SUBNET="fddd:2c4:2c4:2c4::/64"
    result=$(get_next_client_ipv6 "10.9.9.254")
    [ "$result" = "fddd:2c4:2c4:2c4::254" ]
}

# --- Subnet default fallback ---

@test "v5.15: get_next_client_ipv6 uses default subnet when IPV6_SUBNET unset" {
    unset IPV6_SUBNET
    result=$(get_next_client_ipv6 "10.9.9.5")
    [ "$result" = "fddd:2c4:2c4:2c4::5" ]
}

# --- Error handling ---

@test "v5.15: get_next_client_ipv6 returns non-zero for empty argument" {
    run get_next_client_ipv6 ""
    [ "$status" -ne 0 ]
}

# --- RU/EN parity ---

@test "v5.15: RU awg_common.sh defines get_next_client_ipv6" {
    grep -q '^get_next_client_ipv6()' "${BATS_TEST_DIRNAME}/../awg_common.sh"
}

@test "v5.15: EN awg_common_en.sh defines get_next_client_ipv6" {
    grep -q '^get_next_client_ipv6()' "${BATS_TEST_DIRNAME}/../awg_common_en.sh"
}

@test "v5.15: RU and EN get_next_client_ipv6 use same prefix extraction pattern" {
    local ru_body en_body
    # Extract structural lines only; skip log_error lines (differ by design: bilingual RU/EN messages)
    ru_body=$(awk '/^get_next_client_ipv6\(\)/,/^\}$/' "${BATS_TEST_DIRNAME}/../awg_common.sh" | grep 'prefix\|echo' | grep -v 'log_error')
    en_body=$(awk '/^get_next_client_ipv6\(\)/,/^\}$/' "${BATS_TEST_DIRNAME}/../awg_common_en.sh" | grep 'prefix\|echo' | grep -v 'log_error')
    [ "$ru_body" = "$en_body" ]
}
