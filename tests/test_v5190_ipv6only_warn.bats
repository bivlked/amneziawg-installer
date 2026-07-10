#!/usr/bin/env bats
# v5.19.0 - host_lacks_ipv4_egress() IPv6-only egress detection (issue #166).
#
# On an IPv6-only VPS (Timeweb / Ubuntu 26.04) get_main_nic now succeeds via the
# IPv6 fallback, so the install finishes - but the IPv4 tunnel (10.x) is NATed
# via MASQUERADE and cannot leave a host without IPv4 egress. render_server_config
# warns in that case. This helper isolates the "no IPv4 egress" test: it returns
# 0 only when there is no default IPv4 route AND the nic has no global IPv4 addr,
# so dual-stack / IPv4-only hosts never trigger the warning.
#
# `ip` is mocked so the two probes are exercised deterministically.
# shellcheck disable=SC2154

load test_helper

mock_ip() {
    ip() {
        case "$*" in
            "-4 route show default")                    printf '%s' "${MOCK_DEF4:-}" ;;
            "-o -4 addr show dev "*" up scope global")  printf '%s' "${MOCK_ADDR:-}" ;;
            *) return 1 ;;
        esac
    }
    export -f ip
}

@test "v5.19.0 ipv6-only: warns when no IPv4 default route and no IPv4 on nic" {
    mock_ip
    export MOCK_DEF4=""
    export MOCK_ADDR=""
    run host_lacks_ipv4_egress eth0
    [ "$status" -eq 0 ]
}

@test "v5.19.0 ipv6-only: silent on dual-stack (default IPv4 route present)" {
    mock_ip
    export MOCK_DEF4="default via 192.168.1.1 dev eth0 proto dhcp"
    export MOCK_ADDR="2: eth0    inet 192.168.1.5/24 scope global eth0"
    run host_lacks_ipv4_egress eth0
    [ "$status" -eq 1 ]
}

@test "v5.19.0 ipv6-only: silent when nic has global IPv4 but no default route" {
    mock_ip
    export MOCK_DEF4=""
    export MOCK_ADDR="2: eth0    inet 203.0.113.7/24 scope global eth0"
    run host_lacks_ipv4_egress eth0
    [ "$status" -eq 1 ]
}

@test "v5.19.0 ipv6-only: silent when default IPv4 route present but nic addr empty" {
    mock_ip
    export MOCK_DEF4="default via 10.0.0.1 dev eth1"
    export MOCK_ADDR=""
    run host_lacks_ipv4_egress eth0
    [ "$status" -eq 1 ]
}
