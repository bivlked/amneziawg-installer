#!/usr/bin/env bats
# v5.19: validate_subnet supports full CIDR /16-/30 and normalizes server to
# network+1. install_amneziawg.sh is not sourceable; extract the contiguous
# validators block and eval with die/log stubs (mirror of test_v5153).

ROOT="$BATS_TEST_DIRNAME/.."

setup() {
    die()       { echo "DIE: $*"; exit 1; }
    log()       { :; }
    log_warn()  { :; }
    log_error() { :; }
    eval "$(awk '/^validate_port\(\) \{/{f=1} f{print} /^configure_routing_mode\(\) \{/{exit}' \
        "$ROOT/install_amneziawg.sh" | sed '/^configure_routing_mode/d')"
}

# --- Accepts /16-/30 (network or network+1 form) ---

@test "validate_subnet: accepts /24 default (network+1)" {
    run validate_subnet "10.9.9.1/24"
    [ "$status" -eq 0 ]
}

@test "validate_subnet: accepts /16 network form" {
    run validate_subnet "10.9.0.0/16"
    [ "$status" -eq 0 ]
}

@test "validate_subnet: accepts /16 network+1 form" {
    run validate_subnet "10.9.0.1/16"
    [ "$status" -eq 0 ]
}

@test "validate_subnet: accepts /30 network+1" {
    run validate_subnet "192.168.1.1/30"
    [ "$status" -eq 0 ]
}

# --- Rejects out-of-range masks ---

@test "validate_subnet: rejects /15 (too wide)" {
    run validate_subnet "10.0.0.0/15"
    [ "$status" -ne 0 ]
}

@test "validate_subnet: rejects /31 and /32 (no host room)" {
    run validate_subnet "10.9.9.0/31"
    [ "$status" -ne 0 ]
    run validate_subnet "10.9.9.1/32"
    [ "$status" -ne 0 ]
}

@test "validate_subnet: rejects missing prefix" {
    run validate_subnet "10.9.9.1"
    [ "$status" -ne 0 ]
}

# --- Rejects address that is neither network nor network+1 ---

@test "validate_subnet: rejects arbitrary host .2 in /24" {
    run validate_subnet "10.9.9.2/24"
    [ "$status" -ne 0 ]
}

@test "validate_subnet: rejects broadcast in /24" {
    run validate_subnet "10.9.9.255/24"
    [ "$status" -ne 0 ]
}

@test "validate_subnet: rejects mid-subnet host in /16" {
    run validate_subnet "10.9.5.7/16"
    [ "$status" -ne 0 ]
}

# --- Rejects octal/leading-zero and out-of-range octets ---

@test "validate_subnet: rejects leading-zero octets" {
    run validate_subnet "010.008.009.001/24"
    [ "$status" -ne 0 ]
}

@test "validate_subnet: rejects octet > 255" {
    run validate_subnet "256.0.0.1/24"
    [ "$status" -ne 0 ]
}

# --- Normalization: server becomes network+1 (direct call, not `run`) ---

@test "validate_subnet: normalizes /16 network form to network+1" {
    AWG_TUNNEL_SUBNET="10.9.0.0/16"
    validate_subnet "$AWG_TUNNEL_SUBNET"
    [ "$AWG_TUNNEL_SUBNET" = "10.9.0.1/16" ]
}

@test "validate_subnet: normalization is idempotent for network+1 input" {
    AWG_TUNNEL_SUBNET="10.9.9.1/24"
    validate_subnet "$AWG_TUNNEL_SUBNET"
    [ "$AWG_TUNNEL_SUBNET" = "10.9.9.1/24" ]
}
