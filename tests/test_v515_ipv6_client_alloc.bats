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

# --- v5.19: полноценный CIDR, IPv6-маппинг по смещению хоста ---

@test "v5.19: /24 regression - offset==last octet, ::100 for 10.9.9.100" {
    export IPV6_SUBNET="fddd:2c4:2c4:2c4::/64"
    export AWG_TUNNEL_SUBNET="10.9.9.1/24"
    result=$(get_next_client_ipv6 "10.9.9.100")
    [ "$result" = "fddd:2c4:2c4:2c4::100" ]
}

@test "v5.19: /24 regression - ::254 for 10.9.9.254" {
    export IPV6_SUBNET="fddd:2c4:2c4:2c4::/64"
    export AWG_TUNNEL_SUBNET="10.9.9.1/24"
    result=$(get_next_client_ipv6 "10.9.9.254")
    [ "$result" = "fddd:2c4:2c4:2c4::254" ]
}

@test "v5.19: /16 no collision - 10.9.0.5 and 10.9.1.5 differ" {
    export IPV6_SUBNET="fddd:2c4:2c4:2c4::/64"
    export AWG_TUNNEL_SUBNET="10.9.0.1/16"
    local a b
    a=$(get_next_client_ipv6 "10.9.0.5")
    b=$(get_next_client_ipv6 "10.9.1.5")
    [ "$a" != "$b" ]
    # offset(10.9.0.5)=5 -> ::5 ; offset(10.9.1.5)=261=0x105 -> ::105
    [ "$a" = "fddd:2c4:2c4:2c4::5" ]
    [ "$b" = "fddd:2c4:2c4:2c4::105" ]
}

@test "v5.19: /16 offset hex-encoded - 10.9.0.16 -> ::10" {
    export IPV6_SUBNET="fddd:2c4:2c4:2c4::/64"
    export AWG_TUNNEL_SUBNET="10.9.0.1/16"
    result=$(get_next_client_ipv6 "10.9.0.16")
    [ "$result" = "fddd:2c4:2c4:2c4::10" ]
}

@test "v5.19: get_next_client_ipv6 rejects IPv4 outside the tunnel subnet" {
    export IPV6_SUBNET="fddd:2c4:2c4:2c4::/64"
    export AWG_TUNNEL_SUBNET="10.9.0.1/16"
    run get_next_client_ipv6 "10.10.0.5"
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
