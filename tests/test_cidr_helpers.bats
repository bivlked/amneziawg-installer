#!/usr/bin/env bats
# Unit tests for CIDR arithmetic helpers in awg_common.sh:
# _ipv4_to_int / _int_to_ipv4 / _cidr_bounds. RU/EN parity checked at end.

load test_helper

# --- _ipv4_to_int ---

@test "_ipv4_to_int: 0.0.0.0 -> 0" {
    run _ipv4_to_int "0.0.0.0"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "_ipv4_to_int: 255.255.255.255 -> 4294967295" {
    run _ipv4_to_int "255.255.255.255"
    [ "$status" -eq 0 ]
    [ "$output" = "4294967295" ]
}

@test "_ipv4_to_int: 10.9.9.1 -> 168364289" {
    run _ipv4_to_int "10.9.9.1"
    [ "$status" -eq 0 ]
    [ "$output" = "168364289" ]
}

@test "_ipv4_to_int: leading-zero octet handled as decimal (10.9.9.010 -> .10)" {
    run _ipv4_to_int "10.9.9.010"
    [ "$status" -eq 0 ]
    [ "$output" = "168364298" ]
}

@test "_ipv4_to_int: rejects invalid IPv4" {
    run _ipv4_to_int "10.9.9.256"
    [ "$status" -ne 0 ]
}

# --- _int_to_ipv4 (round-trip) ---

@test "_int_to_ipv4: 0 -> 0.0.0.0" {
    run _int_to_ipv4 0
    [ "$output" = "0.0.0.0" ]
}

@test "_int_to_ipv4: 4294967295 -> 255.255.255.255" {
    run _int_to_ipv4 4294967295
    [ "$output" = "255.255.255.255" ]
}

@test "_int_to_ipv4: round-trips 172.16.5.9" {
    local n
    n=$(_ipv4_to_int "172.16.5.9")
    run _int_to_ipv4 "$n"
    [ "$output" = "172.16.5.9" ]
}

# --- _cidr_bounds ---

@test "_cidr_bounds: 10.9.9.1/24 -> network 10.9.9.0, broadcast 10.9.9.255" {
    run _cidr_bounds "10.9.9.1/24"
    [ "$status" -eq 0 ]
    local net bcast
    read -r net bcast <<< "$output"
    [ "$(_int_to_ipv4 "$net")" = "10.9.9.0" ]
    [ "$(_int_to_ipv4 "$bcast")" = "10.9.9.255" ]
}

@test "_cidr_bounds: 10.9.0.1/16 -> network 10.9.0.0, broadcast 10.9.255.255" {
    run _cidr_bounds "10.9.0.1/16"
    [ "$status" -eq 0 ]
    local net bcast
    read -r net bcast <<< "$output"
    [ "$(_int_to_ipv4 "$net")" = "10.9.0.0" ]
    [ "$(_int_to_ipv4 "$bcast")" = "10.9.255.255" ]
}

@test "_cidr_bounds: 192.168.1.5/30 -> network .4, broadcast .7" {
    run _cidr_bounds "192.168.1.5/30"
    [ "$status" -eq 0 ]
    local net bcast
    read -r net bcast <<< "$output"
    [ "$(_int_to_ipv4 "$net")" = "192.168.1.4" ]
    [ "$(_int_to_ipv4 "$bcast")" = "192.168.1.7" ]
}

@test "_cidr_bounds: rejects missing/invalid prefix" {
    run _cidr_bounds "10.9.9.1/abc"
    [ "$status" -ne 0 ]
    run _cidr_bounds "10.9.9.1/33"
    [ "$status" -ne 0 ]
}

@test "_cidr_bounds: leading-zero prefix parsed as decimal (/016 == /16)" {
    run _cidr_bounds "10.9.0.1/016"
    [ "$status" -eq 0 ]
    local net bcast
    read -r net bcast <<< "$output"
    [ "$(_int_to_ipv4 "$net")" = "10.9.0.0" ]
    [ "$(_int_to_ipv4 "$bcast")" = "10.9.255.255" ]
}

# --- RU/EN parity (definitions present, bodies identical modulo comments) ---

@test "RU awg_common.sh defines all three helpers" {
    for fn in _ipv4_to_int _int_to_ipv4 _cidr_bounds; do
        grep -q "^${fn}()" "${BATS_TEST_DIRNAME}/../awg_common.sh" || { echo "missing $fn"; false; }
    done
}

@test "EN awg_common_en.sh defines all three helpers" {
    for fn in _ipv4_to_int _int_to_ipv4 _cidr_bounds; do
        grep -q "^${fn}()" "${BATS_TEST_DIRNAME}/../awg_common_en.sh" || { echo "missing $fn"; false; }
    done
}
