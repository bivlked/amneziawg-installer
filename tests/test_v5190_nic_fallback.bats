#!/usr/bin/env bats
# v5.19.0 hy3g - get_main_nic() interface-detection fallback chain (issue #166).
#
# On Ubuntu 26.04 / Timeweb the single `ip route get 1.1.1.1` probe returned no
# interface (probe address null-routed/blocked, policy-routing or IPv6-only
# egress), so render_server_config aborted the install. get_main_nic now falls
# back: probe -> default IPv4 route -> first global-IPv4 UP iface -> default
# IPv6 route, plus a validated AWG_MAIN_NIC override.
#
# The tests mock `ip` so the chain is exercised deterministically without any
# real networking.
# shellcheck disable=SC2154

load test_helper

# Deterministic `ip` mock driven by MOCK_* env vars (one per fallback stage).
mock_ip() {
    ip() {
        case "$*" in
            "route get 1.1.1.1")               printf '%s' "${MOCK_PROBE:-}" ;;
            "-4 route show default")           printf '%s' "${MOCK_DEF4:-}" ;;
            "-o -4 addr show up scope global") printf '%s' "${MOCK_ADDR:-}" ;;
            "-6 route show default")           printf '%s' "${MOCK_DEF6:-}" ;;
            "link show dev "*)
                local all="$*" d
                d="${all#link show dev }"
                case " ${MOCK_LINKS:-} " in *" $d "*) return 0 ;; *) return 1 ;; esac ;;
            *) return 1 ;;
        esac
    }
    export -f ip
}

@test "v5.19.0 hy3g: probe path wins when ip route get returns a dev" {
    mock_ip
    export MOCK_PROBE="1.1.1.1 via 10.0.0.1 dev eth0 src 10.0.0.5 uid 0"
    export MOCK_DEF4="default via 10.0.0.1 dev eth9"
    run get_main_nic
    [ "$status" -eq 0 ]
    [ "$output" = "eth0" ]
}

@test "v5.19.0 hy3g: falls back to default IPv4 route when probe is empty" {
    mock_ip
    export MOCK_PROBE=""
    export MOCK_DEF4="default via 192.168.1.1 dev ens3 proto dhcp"
    run get_main_nic
    [ "$status" -eq 0 ]
    [ "$output" = "ens3" ]
}

@test "v5.19.0 hy3g: falls back to first global-IPv4 UP interface when no default route" {
    mock_ip
    export MOCK_PROBE=""
    export MOCK_DEF4=""
    export MOCK_ADDR="2: enp1s0    inet 203.0.113.7/24 scope global enp1s0"
    run get_main_nic
    [ "$status" -eq 0 ]
    [ "$output" = "enp1s0" ]
}

@test "v5.19.0 hy3g: strips @peer suffix from addr fallback ifname" {
    mock_ip
    export MOCK_PROBE=""
    export MOCK_DEF4=""
    export MOCK_ADDR="5: wg-site@if3    inet 100.64.0.2/32 scope global wg-site"
    run get_main_nic
    [ "$status" -eq 0 ]
    [ "$output" = "wg-site" ]
}

@test "v5.19.0 hy3g: falls back to default IPv6 route on IPv6-only egress" {
    mock_ip
    export MOCK_PROBE=""
    export MOCK_DEF4=""
    export MOCK_ADDR=""
    export MOCK_DEF6="default via fe80::1 dev eth0 proto ra metric 100"
    run get_main_nic
    [ "$status" -eq 0 ]
    [ "$output" = "eth0" ]
}

@test "v5.19.0 hy3g: valid AWG_MAIN_NIC override wins over auto-detection" {
    mock_ip
    export MOCK_PROBE="1.1.1.1 dev eth0"
    export MOCK_LINKS="eth0 eth1"
    export AWG_MAIN_NIC="eth1"
    run get_main_nic
    [ "$status" -eq 0 ]
    [ "$output" = "eth1" ]
}

@test "v5.19.0 hy3g: override with shell metacharacters is rejected (falls through)" {
    mock_ip
    export MOCK_PROBE="1.1.1.1 dev eth0"
    export MOCK_LINKS="eth0"
    export AWG_MAIN_NIC="eth0; rm -rf /"
    run get_main_nic
    [ "$status" -eq 0 ]
    [ "$output" = "eth0" ]
}

@test "v5.19.0 hy3g: non-existent override is rejected (falls through)" {
    mock_ip
    export MOCK_PROBE=""
    export MOCK_DEF4="default via 10.0.0.1 dev eth0"
    export MOCK_LINKS="eth0"
    export AWG_MAIN_NIC="doesnotexist0"
    run get_main_nic
    [ "$status" -eq 0 ]
    [ "$output" = "eth0" ]
}

@test "v5.19.0 hy3g: returns non-zero and empty when nothing detectable" {
    mock_ip
    export MOCK_PROBE=""
    export MOCK_DEF4=""
    export MOCK_ADDR=""
    export MOCK_DEF6=""
    run get_main_nic
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}
