#!/usr/bin/env bats
# v5.15.1 audit fixes - regression locks for:
#   C8 / weaq P1: detect_native_ipv6 must require a globally-routable (non-ULA)
#                 address AND a default IPv6 route (no false-positive -> no ::/0
#                 black-hole).
#   E / C13:      install --help OS line lists 26.04; --subnet help states /24.
#   C12:          log_msg must not double percent signs.
#   weaq P2:      log_msg must route INFO/DEBUG to stderr when JSON_OUTPUT=1.
#
# shellcheck disable=SC2034  # mock env vars (NO_COLOR/VERBOSE_LIST/LOG_FILE/JSON_OUTPUT) are consumed by the sourced functions
# shellcheck disable=SC2154  # $stderr is set by bats `run --separate-stderr`

bats_require_minimum_version 1.5.0

# ---------------------------------------------------------------------------
# detect_native_ipv6 (extracted from install_amneziawg.sh, `ip` mocked)
# ---------------------------------------------------------------------------

setup_detect() {
    local installer="${BATS_TEST_DIRNAME}/../install_amneziawg.sh"
    # shellcheck source=/dev/null
    source <(sed -n '/^detect_native_ipv6() {$/,/^}$/p' "$installer")
    ip() {
        case "$*" in
            *"addr show scope global"*) printf '%s\n' "${MOCK_IP6_ADDR:-}" ;;
            *"route show default"*)     printf '%s\n' "${MOCK_IP6_ROUTE:-}" ;;
            *) : ;;
        esac
    }
    export -f ip
}

@test "v5.15.1 C8: native = global non-ULA address + default route -> 1" {
    setup_detect
    MOCK_IP6_ADDR="    inet6 2a01:4f8:c17:abcd::1/64 scope global"
    MOCK_IP6_ROUTE="default via fe80::1 dev eth0 proto ra"
    run detect_native_ipv6
    [ "$output" = "1" ]
}

@test "v5.15.1 C8: ULA-only global address (fd..) + default route -> 0" {
    setup_detect
    MOCK_IP6_ADDR="    inet6 fddd:2c4:2c4:2c4::1/64 scope global"
    MOCK_IP6_ROUTE="default via fe80::1 dev eth0"
    run detect_native_ipv6
    [ "$output" = "0" ]
}

@test "v5.15.1 C8: global address but NO default route -> 0 (avoids black-hole)" {
    setup_detect
    MOCK_IP6_ADDR="    inet6 2a01:4f8:c17:abcd::1/64 scope global"
    MOCK_IP6_ROUTE=""
    run detect_native_ipv6
    [ "$output" = "0" ]
}

@test "v5.15.1 C8: no IPv6 at all -> 0" {
    setup_detect
    MOCK_IP6_ADDR=""
    MOCK_IP6_ROUTE=""
    run detect_native_ipv6
    [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# install --help text (E: 26.04, C13: /24) - source-level assertions
# ---------------------------------------------------------------------------

@test "v5.15.1 E: RU installer help OS line includes 26.04" {
    grep -q "Ubuntu (24.04 / 25.10 / 26.04)" "${BATS_TEST_DIRNAME}/../install_amneziawg.sh"
}

@test "v5.15.1 E: EN installer help OS line includes 26.04" {
    grep -q "Ubuntu (24.04 / 25.10 / 26.04)" "${BATS_TEST_DIRNAME}/../install_amneziawg_en.sh"
}

@test "v5.15.1 C13: RU installer --subnet help states /24 only" {
    grep -qP 'subnet.*/24' "${BATS_TEST_DIRNAME}/../install_amneziawg.sh"
}

# ---------------------------------------------------------------------------
# log_msg (extracted from manage_amneziawg.sh) - C12 + weaq P2
# ---------------------------------------------------------------------------

setup_logmsg() {
    NO_COLOR=1
    VERBOSE_LIST=0
    LOG_FILE="${BATS_TEST_TMPDIR:-/tmp}/awg_test_$$.log"
    JSON_OUTPUT=0
    local mgr="${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"
    # shellcheck source=/dev/null
    source <(sed -n '/^log_msg() {$/,/^}$/p' "$mgr")
}

@test "v5.15.1 C12: log_msg does not double percent signs" {
    setup_logmsg
    run log_msg INFO "disk is 95% full"
    [[ "$output" == *"95% full"* ]]
    [[ "$output" != *"95%%"* ]]
}

@test "v5.15.1 weaq P2: log_msg INFO goes to stderr (empty stdout) when JSON_OUTPUT=1" {
    setup_logmsg
    JSON_OUTPUT=1
    run --separate-stderr log_msg INFO "informational line"
    [ -z "$output" ]
    [[ "$stderr" == *"informational line"* ]]
}

@test "v5.15.1 weaq P2: log_msg INFO goes to stdout when JSON_OUTPUT=0" {
    setup_logmsg
    JSON_OUTPUT=0
    run log_msg INFO "informational line"
    [[ "$output" == *"informational line"* ]]
}
