#!/usr/bin/env bats
# Invariant guard: --allow-ipv6-tunnel forces host IPv6 forwarding on.
# When ALLOW_IPV6_TUNNEL=1 and DISABLE_IPV6=1, configure_ipv6_tunnel()
# must override DISABLE_IPV6 to 0.
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
    unset CLI_ALLOW_IPV6_TUNNEL ALLOW_IPV6_TUNNEL DISABLE_IPV6 IPV6_SUBNET SERVER_HAS_NATIVE_IPV6
}

@test "invariant: tunnel=1 + host-disabled=1 forces DISABLE_IPV6=0" {
    CLI_ALLOW_IPV6_TUNNEL=1
    DISABLE_IPV6=1
    configure_ipv6_tunnel
    [ "$ALLOW_IPV6_TUNNEL" = "1" ]
    [ "$DISABLE_IPV6" = "0" ]
}

@test "invariant: tunnel=0 + host-disabled=1 leaves DISABLE_IPV6=1 (no override)" {
    CLI_ALLOW_IPV6_TUNNEL=0
    DISABLE_IPV6=1
    unset ALLOW_IPV6_TUNNEL
    configure_ipv6_tunnel
    [ "$ALLOW_IPV6_TUNNEL" = "0" ]
    [ "$DISABLE_IPV6" = "1" ]
}

@test "invariant: tunnel=1 + host-enabled=0 leaves DISABLE_IPV6=0 (no change needed)" {
    CLI_ALLOW_IPV6_TUNNEL=1
    DISABLE_IPV6=0
    configure_ipv6_tunnel
    [ "$ALLOW_IPV6_TUNNEL" = "1" ]
    [ "$DISABLE_IPV6" = "0" ]
}

@test "invariant: RU/EN parity - invariant exists in both installer scripts" {
    local ru_check en_check
    ru_check=$(grep -c 'DISABLE_IPV6=0' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    en_check=$(grep -c 'DISABLE_IPV6=0' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh")
    [ "$ru_check" -ge 1 ]
    [ "$en_check" -ge 1 ]
}
