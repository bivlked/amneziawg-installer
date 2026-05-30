#!/usr/bin/env bats
# Regression guard: --allow-ipv6-tunnel flag is parsed in both installers.
# Tests configure_ipv6_tunnel() function behavior via extracted function.
# shellcheck disable=SC2034,SC2154

load test_helper

setup() {
    TEST_DIR=$(mktemp -d)
    export AWG_DIR="$TEST_DIR"
    export CONFIG_FILE="$TEST_DIR/awgsetup_cfg.init"
    mkdir -p "$TEST_DIR"

    log()       { :; }
    log_warn()  { :; }
    log_error() { :; }
    log_debug() { :; }
    export -f log log_warn log_error log_debug

    source "$BATS_TEST_DIRNAME/../awg_common.sh"
    eval "$(sed -n '/^detect_native_ipv6()/,/^}/p' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")"
    eval "$(sed -n '/^configure_ipv6_tunnel()/,/^}/p' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")"
}

teardown() {
    rm -rf "$TEST_DIR"
    unset CLI_ALLOW_IPV6_TUNNEL ALLOW_IPV6_TUNNEL IPV6_SUBNET SERVER_HAS_NATIVE_IPV6 DISABLE_IPV6
}

@test "--allow-ipv6-tunnel flag exists in install_amneziawg.sh" {
    run grep -c '\-\-allow-ipv6-tunnel' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "--allow-ipv6-tunnel flag exists in install_amneziawg_en.sh" {
    run grep -c '\-\-allow-ipv6-tunnel' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "--allow-ipv6 flag unchanged (regression baseline)" {
    run grep -c '\-\-allow-ipv6)' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "configure_ipv6_tunnel: no flag sets ALLOW_IPV6_TUNNEL=0" {
    CLI_ALLOW_IPV6_TUNNEL=0
    DISABLE_IPV6=1
    unset ALLOW_IPV6_TUNNEL
    configure_ipv6_tunnel
    [ "$ALLOW_IPV6_TUNNEL" = "0" ]
}

@test "configure_ipv6_tunnel: CLI flag sets ALLOW_IPV6_TUNNEL=1" {
    CLI_ALLOW_IPV6_TUNNEL=1
    DISABLE_IPV6=0
    configure_ipv6_tunnel
    [ "$ALLOW_IPV6_TUNNEL" = "1" ]
}

@test "configure_ipv6_tunnel: sets IPV6_SUBNET default" {
    CLI_ALLOW_IPV6_TUNNEL=0
    DISABLE_IPV6=1
    unset IPV6_SUBNET
    configure_ipv6_tunnel
    [ "$IPV6_SUBNET" = "fddd:2c4:2c4:2c4::/64" ]
}

@test "configure_ipv6_tunnel: preserves existing IPV6_SUBNET (config override)" {
    CLI_ALLOW_IPV6_TUNNEL=0
    DISABLE_IPV6=1
    IPV6_SUBNET="fddd:1234:5678:9abc::/64"
    configure_ipv6_tunnel
    [ "$IPV6_SUBNET" = "fddd:1234:5678:9abc::/64" ]
}

@test "configure_ipv6_tunnel: sets SERVER_HAS_NATIVE_IPV6=0 when no native IPv6" {
    # Phase 3: value is now detected (not statically defaulted). Stub detection
    # to the no-native result so the assertion is host-independent.
    detect_native_ipv6() { echo 0; }
    export -f detect_native_ipv6
    CLI_ALLOW_IPV6_TUNNEL=0
    DISABLE_IPV6=1
    unset SERVER_HAS_NATIVE_IPV6
    configure_ipv6_tunnel
    [ "$SERVER_HAS_NATIVE_IPV6" = "0" ]
}

@test "configure_ipv6_tunnel: RU/EN parity - both scripts define the function" {
    run grep -c '^configure_ipv6_tunnel()' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    [ "$output" -eq 1 ]
    run grep -c '^configure_ipv6_tunnel()' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    [ "$output" -eq 1 ]
}

@test "backward compat: v5.14.x init without IPv6 keys sets safe defaults" {
    detect_native_ipv6() { echo 0; }
    export -f detect_native_ipv6
    CLI_ALLOW_IPV6_TUNNEL=0
    DISABLE_IPV6=1
    unset ALLOW_IPV6_TUNNEL IPV6_SUBNET SERVER_HAS_NATIVE_IPV6
    configure_ipv6_tunnel
    [ "$ALLOW_IPV6_TUNNEL" = "0" ]
    [ "$IPV6_SUBNET" = "fddd:2c4:2c4:2c4::/64" ]
    [ "$SERVER_HAS_NATIVE_IPV6" = "0" ]
}

@test "configure_ipv6_tunnel: resume preserves ALLOW_IPV6_TUNNEL from config (no CLI flag)" {
    CLI_ALLOW_IPV6_TUNNEL=0
    ALLOW_IPV6_TUNNEL=1
    DISABLE_IPV6=0
    configure_ipv6_tunnel
    [ "$ALLOW_IPV6_TUNNEL" = "1" ]
}
