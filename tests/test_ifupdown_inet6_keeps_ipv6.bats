#!/usr/bin/env bats
# guard_ifupdown_ipv6: on Debian with ifupdown, an `iface ... inet6` stanza in
# /etc/network/interfaces or interfaces.d plus disable_ipv6=1 breaks the
# network at boot (measured on Debian 13: networking.service fails, or the
# server boots without SSH). The installer must keep host IPv6 on there,
# even when --disallow-ipv6 was given, and say why.
# shellcheck disable=SC2034,SC2154

load test_helper

setup() {
    TEST_DIR=$(mktemp -d)
    NETDIR="$TEST_DIR/network"
    mkdir -p "$NETDIR/interfaces.d"
    WARN_LOG="$TEST_DIR/warn.log"
    : > "$WARN_LOG"
    log()       { :; }
    log_warn()  { printf '%s\n' "$*" >> "$WARN_LOG"; }
    log_error() { :; }
    log_debug() { :; }
}

teardown() {
    rm -rf "$TEST_DIR"
    unset DISABLE_IPV6
}

_load_fn() {
    eval "$(sed -n '/^guard_ifupdown_ipv6()/,/^}/p' "$BATS_TEST_DIRNAME/../$1")"
}

@test "ifupdown inet6: stanza in interfaces.d keeps host IPv6 on and warns" {
    _load_fn install_amneziawg.sh
    printf 'auto eth0\niface eth0 inet dhcp\n\niface eth0 inet6 static\n    address 2001:db8::2/64\n' > "$NETDIR/interfaces.d/50-cloud-init"
    DISABLE_IPV6=1
    guard_ifupdown_ipv6 "$NETDIR"
    [ "$DISABLE_IPV6" = "0" ]
    run grep -c 'interfaces.d/50-cloud-init' "$WARN_LOG"
    [ "$output" = "1" ]
}

@test "ifupdown inet6: stanza in the main interfaces file counts too" {
    _load_fn install_amneziawg.sh
    printf 'auto lo\niface lo inet loopback\n  iface\teth0   inet6 auto\n' > "$NETDIR/interfaces"
    DISABLE_IPV6=1
    guard_ifupdown_ipv6 "$NETDIR"
    [ "$DISABLE_IPV6" = "0" ]
}

@test "ifupdown inet6: IPv4-only config leaves DISABLE_IPV6=1 and stays quiet" {
    _load_fn install_amneziawg.sh
    printf 'auto lo\niface lo inet loopback\nauto eth0\niface eth0 inet dhcp\n' > "$NETDIR/interfaces"
    printf '# iface eth0 inet6 static\niface eth1 inet static\n    address 10.0.0.2/24\n' > "$NETDIR/interfaces.d/eth1"
    DISABLE_IPV6=1
    guard_ifupdown_ipv6 "$NETDIR"
    [ "$DISABLE_IPV6" = "1" ]
    [ ! -s "$WARN_LOG" ]
}

@test "ifupdown inet6: no ifupdown files at all leaves DISABLE_IPV6=1" {
    _load_fn install_amneziawg.sh
    rm -rf "$NETDIR"
    DISABLE_IPV6=1
    guard_ifupdown_ipv6 "$NETDIR"
    [ "$DISABLE_IPV6" = "1" ]
    [ ! -s "$WARN_LOG" ]
}

@test "ifupdown inet6: IPv6 already allowed - nothing changes, no warning" {
    _load_fn install_amneziawg.sh
    printf 'iface eth0 inet6 static\n' > "$NETDIR/interfaces"
    DISABLE_IPV6=0
    guard_ifupdown_ipv6 "$NETDIR"
    [ "$DISABLE_IPV6" = "0" ]
    [ ! -s "$WARN_LOG" ]
}

@test "ifupdown inet6: EN installer behaves the same" {
    _load_fn install_amneziawg_en.sh
    printf 'iface eth0 inet6 static\n' > "$NETDIR/interfaces.d/60-v6"
    DISABLE_IPV6=1
    guard_ifupdown_ipv6 "$NETDIR"
    [ "$DISABLE_IPV6" = "0" ]
    run grep -c 'interfaces.d/60-v6' "$WARN_LOG"
    [ "$output" = "1" ]
}

@test "ifupdown inet6: step 0 calls the guard after the IPv6 default, before the tunnel check (RU and EN)" {
    local f lines
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        lines=$(grep -n -e 'if \[\[ "\$DISABLE_IPV6" == "default" \]\]; then DISABLE_IPV6=1; fi' \
                       -e '^    guard_ifupdown_ipv6 /etc/network$' \
                       -e '^    configure_ipv6_tunnel$' "$BATS_TEST_DIRNAME/../$f" | cut -d: -f2- | tr -s ' ')
        [ "$lines" = " if [[ \"\$DISABLE_IPV6\" == \"default\" ]]; then DISABLE_IPV6=1; fi
 guard_ifupdown_ipv6 /etc/network
 configure_ipv6_tunnel" ]
    done
}
