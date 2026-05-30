#!/usr/bin/env bats
# Phase 3 (v5.15.0): when --allow-ipv6-tunnel is requested on a VPS without
# native IPv6, configure_ipv6_tunnel() must log a warning and continue (not die),
# and SERVER_HAS_NATIVE_IPV6=0 must be recorded.
# shellcheck disable=SC2034,SC2154

load test_helper

setup() {
    TEST_DIR=$(mktemp -d)
    export AWG_DIR="$TEST_DIR"
    export CONFIG_FILE="$TEST_DIR/awgsetup_cfg.init"
    mkdir -p "$TEST_DIR"
    export WARN_LOG="$TEST_DIR/warn.log"
    : > "$WARN_LOG"

    log()       { :; }
    # Capture warnings so we can assert the no-native-IPv6 path emits one.
    log_warn()  { echo "$*" >> "$WARN_LOG"; }
    log_error() { :; }
    log_debug() { :; }
    export WARN_LOG
    export -f log log_warn log_error log_debug

    source "$BATS_TEST_DIRNAME/../awg_common.sh"
    eval "$(sed -n '/^detect_native_ipv6()/,/^}/p' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")"
    eval "$(sed -n '/^configure_ipv6_tunnel()/,/^}/p' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")"
}

teardown() {
    rm -rf "$TEST_DIR"
    unset CLI_ALLOW_IPV6_TUNNEL ALLOW_IPV6_TUNNEL DISABLE_IPV6 IPV6_SUBNET SERVER_HAS_NATIVE_IPV6 WARN_LOG
}

# Force native-IPv6 detection result deterministically (real impl shells to `ip -6`).
stub_native() {
    local result="$1"
    eval "detect_native_ipv6() { echo $result; }"
    export -f detect_native_ipv6
}

@test "no native IPv6 + tunnel=1: warning emitted, no die, SERVER_HAS_NATIVE_IPV6=0" {
    stub_native 0
    CLI_ALLOW_IPV6_TUNNEL=1
    DISABLE_IPV6=0
    run configure_ipv6_tunnel
    [ "$status" -eq 0 ]
    configure_ipv6_tunnel
    [ "$SERVER_HAS_NATIVE_IPV6" = "0" ]
    [ "$ALLOW_IPV6_TUNNEL" = "1" ]
    run grep -ci 'native ipv6' "$WARN_LOG"
    [ "$output" -ge 1 ]
}

@test "native IPv6 present + tunnel=1: no no-native warning, SERVER_HAS_NATIVE_IPV6=1" {
    stub_native 1
    CLI_ALLOW_IPV6_TUNNEL=1
    DISABLE_IPV6=0
    configure_ipv6_tunnel
    [ "$SERVER_HAS_NATIVE_IPV6" = "1" ]
    [ "$ALLOW_IPV6_TUNNEL" = "1" ]
    run grep -ci 'native ipv6' "$WARN_LOG"
    [ "$output" = "0" ]
}

@test "no native IPv6 + tunnel=0: no warning (warning is tunnel-gated)" {
    stub_native 0
    CLI_ALLOW_IPV6_TUNNEL=0
    DISABLE_IPV6=1
    unset ALLOW_IPV6_TUNNEL
    configure_ipv6_tunnel
    [ "$SERVER_HAS_NATIVE_IPV6" = "0" ]
    [ "$ALLOW_IPV6_TUNNEL" = "0" ]
    run grep -ci 'native ipv6' "$WARN_LOG"
    [ "$output" = "0" ]
}

@test "detect_native_ipv6: returns 1 when global inet6 line present" {
    # Stub the `ip` command to emit a global-scope IPv6 line.
    ip() { echo "    inet6 2a01:4f8::1/64 scope global"; }
    export -f ip
    run detect_native_ipv6
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
    unset -f ip
}

@test "detect_native_ipv6: returns 0 when no global inet6 (link-local only)" {
    ip() { echo ""; }
    export -f ip
    run detect_native_ipv6
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
    unset -f ip
}

@test "RU/EN parity: detect_native_ipv6 body identical in both installers" {
    local ru en
    ru=$(sed -n '/^detect_native_ipv6()/,/^}/p' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    en=$(sed -n '/^detect_native_ipv6()/,/^}/p' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh")
    [ "$ru" = "$en" ]
}

@test "RU/EN parity: both installers warn on no-native + tunnel" {
    local ru en
    ru=$(grep -c 'SERVER_HAS_NATIVE_IPV6" -eq 0' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    en=$(grep -c 'SERVER_HAS_NATIVE_IPV6" -eq 0' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh")
    [ "$ru" -ge 1 ]
    [ "$en" -ge 1 ]
}
