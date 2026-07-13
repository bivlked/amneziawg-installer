#!/usr/bin/env bats
# v5.19.1: coverage for the CIDR tunnel-subnet edges shipped in v5.19.0.
#   - /30 (smallest supported): server = network+1, exactly one client at
#     network+2, then the subnet is full.
#   - /25 (a non-/24 mask): the client IPv6 suffix is hex-encoded (decimal is a
#     /24-only legacy quirk), so the same host offset yields a different suffix
#     under /25 vs /24. This "seam" is safe: a prefix change with live peers is
#     blocked by guard_subnet_change_with_peers, so the two encodings never mix
#     inside one running subnet.

load test_helper

# --- /30: only one usable host ---

@test "v5.19.1 /30: the first client is network+2" {
    require_grep_P
    export AWG_TUNNEL_SUBNET="10.9.9.0/30"
    create_server_config
    run get_next_client_ip
    [ "$status" -eq 0 ]
    [ "$output" = "10.9.9.2" ]
}

@test "v5.19.1 /30: the subnet is full once the single client is taken" {
    require_grep_P
    export AWG_TUNNEL_SUBNET="10.9.9.0/30"
    create_server_config
    add_test_peer "c1" "10.9.9.2"
    run get_next_client_ip
    [ "$status" -ne 0 ]
}

# --- /25 IPv6 suffix (hex) and the /24 vs /25 seam ---

@test "v5.19.1 /25: server (network+1) maps to ::1" {
    export AWG_TUNNEL_SUBNET="10.9.9.0/25"
    run get_next_client_ipv6 "10.9.9.1"
    [ "$status" -eq 0 ]
    [ "$output" = "fddd:2c4:2c4:2c4::1" ]
}

@test "v5.19.1 /25: client offset is hex-encoded in the IPv6 suffix" {
    export AWG_TUNNEL_SUBNET="10.9.9.0/25"
    run get_next_client_ipv6 "10.9.9.17"   # offset 17 -> hex 11
    [ "$status" -eq 0 ]
    [ "$output" = "fddd:2c4:2c4:2c4::11" ]
}

@test "v5.19.1 /24-vs-/25 seam: same offset, decimal suffix on /24, hex on /25" {
    export AWG_TUNNEL_SUBNET="10.9.9.0/25"
    run get_next_client_ipv6 "10.9.9.16"   # offset 16 -> hex 10
    local v25="$output"
    export AWG_TUNNEL_SUBNET="10.9.9.0/24"
    run get_next_client_ipv6 "10.9.9.16"   # offset 16 -> decimal 16
    local v24="$output"
    [ "$v25" = "fddd:2c4:2c4:2c4::10" ]
    [ "$v24" = "fddd:2c4:2c4:2c4::16" ]
    [ "$v25" != "$v24" ]
}

@test "v5.19.1 /25: distinct offsets yield distinct hex IPv6 suffixes (incl. multi-digit)" {
    export AWG_TUNNEL_SUBNET="10.9.9.0/25"
    run get_next_client_ipv6 "10.9.9.10"; local a="$output"   # offset 10 -> hex a
    run get_next_client_ipv6 "10.9.9.26"; local b="$output"   # offset 26 -> hex 1a
    [ "$a" = "fddd:2c4:2c4:2c4::a" ]
    [ "$b" = "fddd:2c4:2c4:2c4::1a" ]
    [ "$a" != "$b" ]
}
