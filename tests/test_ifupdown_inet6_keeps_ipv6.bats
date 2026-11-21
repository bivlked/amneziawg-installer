#!/usr/bin/env bats
# guard_ifupdown_ipv6: on Debian with ifupdown, IPv6 settings in
# /etc/network/interfaces, interfaces.d or files pulled in by source plus
# disable_ipv6=1 break the network at boot (measured on Debian 13:
# networking.service fails and stops dhcpcd, the server drops off the network
# when the DHCP lease runs out, or boots without SSH). The installer must keep
# host IPv6 on there, even when --disallow-ipv6 was given, remove a switch-off
# an earlier step 1 already wrote, and say why.
# shellcheck disable=SC2034,SC2154

load test_helper

INSTALLERS="install_amneziawg.sh install_amneziawg_en.sh"

setup() {
    TEST_DIR=$(mktemp -d)
    NETDIR="$TEST_DIR/network"
    SYSDIR="$TEST_DIR/sysctl.d"
    SYSCONF="$TEST_DIR/sysctl.conf"
    mkdir -p "$NETDIR/interfaces.d" "$SYSDIR"
    WARN_LOG="$TEST_DIR/warn.log"
    DIE_LOG="$TEST_DIR/die.log"
    : > "$WARN_LOG"
    log()       { :; }
    log_warn()  { printf '%s\n' "$*" >> "$WARN_LOG"; }
    log_error() { :; }
    log_debug() { :; }
    die()       { printf '%s\n' "$*" >> "$DIE_LOG"; exit 1; }
}

teardown() {
    chmod -R u+rwx "$TEST_DIR" 2>/dev/null || true
    rm -rf "$TEST_DIR"
    unset DISABLE_IPV6
}

_load_fn() {
    eval "$(sed -n '/^guard_ifupdown_ipv6()/,/^}/p' "$BATS_TEST_DIRNAME/../$1")"
}

_guard() {
    guard_ifupdown_ipv6 "$NETDIR" "$SYSDIR" "$SYSCONF"
}

# The three switch-off lines the installer's step 1 writes, plus lines that
# must survive the cleanup.
_sysctl_fixture() {
    printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\nnet.ipv6.conf.lo.disable_ipv6 = 1\nnet.ipv6.conf.all.accept_redirects = 0\nnet.ipv6.conf.eth0.disable_ipv6 = 0\nnet.core.default_qdisc = fq\n' > "$SYSDIR/99-amneziawg-security.conf"
    printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\nnet.ipv6.conf.lo.disable_ipv6 = 1\n' > "$SYSDIR/99-amneziawg-forwarding.conf"
    printf 'kernel.sysrq = 0\nnet.ipv6.conf.all.disable_ipv6 = 1\n' > "$SYSCONF"
    printf 'net.ipv6.conf.all.disable_ipv6 = 1\n' > "$SYSDIR/10-other.conf"
    cp "$SYSDIR/10-other.conf" "$TEST_DIR/other.before"
}

@test "ifupdown IPv6: inet6 stanza in interfaces.d keeps host IPv6 on and names the file (RU and EN)" {
    local f
    for f in $INSTALLERS; do
        _load_fn "$f"
        : > "$WARN_LOG"
        printf 'auto eth0\niface eth0 inet dhcp\n\niface eth0 inet6 static\n    address 2001:db8::2/64\n' > "$NETDIR/interfaces.d/50-cloud-init"
        DISABLE_IPV6=1
        _guard
        [ "$DISABLE_IPV6" = "0" ]
        run grep -c 'interfaces.d/50-cloud-init' "$WARN_LOG"
        [ "$output" = "1" ]
    done
}

@test "ifupdown IPv6: indented stanza with tabs in the main file counts" {
    _load_fn install_amneziawg.sh
    printf 'auto lo\niface lo inet loopback\n  iface\teth0   inet6 auto\n' > "$NETDIR/interfaces"
    DISABLE_IPV6=1
    _guard
    [ "$DISABLE_IPV6" = "0" ]
}

@test "ifupdown IPv6: IPv6 address, gateway or ip -6 hook without an inet6 stanza counts (RU and EN)" {
    local line f
    for f in $INSTALLERS; do
    _load_fn "$f"
    for line in '    address 2a01:4f8:1c18:d30c::1/64' '    gateway fe80::1' '    up ip -6 addr add 2a01::1/64 dev eth0' '    post-up /sbin/ip -6 route add default via fe80::1 dev eth0' '    post-up /sbin/ip -f inet6 route add default via fe80::1' '    up ip --family inet6 addr add 2a01::1/64 dev eth0' '    up ip -o -6 addr show' '    up sh -c "ip -6 route add default via fe80::1"' "    up sh -c 'ip -6 route add default via fe80::1'" '    up ip -n ns1 -6 addr add 2a01::1/64 dev eth0' '    up ip -fa inet6 route add default via fe80::1' '    up ip addr add 2001:db8::1/64 dev eth0' '    post-up ip addr add 2001:0db8:0000:0000:0000:0000:0000:0001/64 dev eth0'; do
        printf 'auto eth0\niface eth0 inet dhcp\n%s\n' "$line" > "$NETDIR/interfaces"
        DISABLE_IPV6=1
        _guard
        [ "$DISABLE_IPV6" = "0" ] || { echo "missed: $line ($f)"; false; }
    done
    done
}

@test "ifupdown IPv6: IPv4-only hooks are not mistaken for IPv6 (RU and EN)" {
    local line f
    for f in $INSTALLERS; do
    _load_fn "$f"
    for line in '    up ip -f inet addr add 1.2.3.4/32 dev eth0' '    up ip -o link' '    up ip link set dev eth0 address aa:bb:cc:dd:ee:ff' '    up ip -4 route add 10.0.0.0/8 via 10.0.0.1' '    up ping -c1 1.1.1.1' '    up ip6tables-restore < /etc/iptables/rules.v6'; do
        printf 'auto eth0\niface eth0 inet dhcp\n%s\n' "$line" > "$NETDIR/interfaces"
        DISABLE_IPV6=1
        _guard
        [ "$DISABLE_IPV6" = "1" ] || { echo "false hit: $line ($f)"; false; }
    done
    done
}

@test "ifupdown IPv6: source with several paths checks every path" {
    _load_fn install_amneziawg.sh
    mkdir -p "$TEST_DIR/c"
    printf 'iface eth0 inet dhcp\n' > "$TEST_DIR/c/ipv4"
    printf 'iface eth0 inet6 static\n' > "$TEST_DIR/c/ipv6"
    printf 'source %s/c/ipv4 %s/c/ipv6\n' "$TEST_DIR" "$TEST_DIR" > "$NETDIR/interfaces"
    DISABLE_IPV6=1
    _guard
    [ "$DISABLE_IPV6" = "0" ]
    run grep -c 'c/ipv6' "$WARN_LOG"
    [ "$output" = "1" ]
}

@test "ifupdown IPv6: IPv4-only config leaves DISABLE_IPV6=1, sysctl files untouched, no warning (RU and EN)" {
    local f
    for f in $INSTALLERS; do
        _load_fn "$f"
        _sysctl_fixture
        cp "$SYSDIR/99-amneziawg-security.conf" "$TEST_DIR/sec.before"
        printf 'auto lo\niface lo inet loopback\nauto eth0\niface eth0 inet static\n    address 10.0.0.2/24\n    gateway 10.0.0.1\n    hwaddress ether aa:bb:cc:dd:ee:ff\n    up ip route add 10.8.0.0/16 via 10.0.0.1\n    up ip -4 addr add 1.2.3.4/32 dev eth0\n' > "$NETDIR/interfaces"
        printf '# iface eth0 inet6 static\n#    address 2001:db8::2/64\n' > "$NETDIR/interfaces.d/eth1"
        DISABLE_IPV6=1
        _guard
        [ "$DISABLE_IPV6" = "1" ]
        [ ! -s "$WARN_LOG" ]
        cmp "$TEST_DIR/sec.before" "$SYSDIR/99-amneziawg-security.conf"
    done
}

@test "ifupdown IPv6: no ifupdown files at all leaves DISABLE_IPV6=1" {
    _load_fn install_amneziawg.sh
    rm -rf "$NETDIR"
    DISABLE_IPV6=1
    _guard
    [ "$DISABLE_IPV6" = "1" ]
    [ ! -s "$WARN_LOG" ]
}

@test "ifupdown IPv6: IPv6 already allowed - nothing changes, no warning" {
    _load_fn install_amneziawg.sh
    _sysctl_fixture
    cp "$SYSDIR/99-amneziawg-security.conf" "$TEST_DIR/sec.before"
    printf 'iface eth0 inet6 static\n' > "$NETDIR/interfaces"
    DISABLE_IPV6=0
    _guard
    [ "$DISABLE_IPV6" = "0" ]
    [ ! -s "$WARN_LOG" ]
    cmp "$TEST_DIR/sec.before" "$SYSDIR/99-amneziawg-security.conf"
}

@test "ifupdown IPv6: source with absolute and relative paths and source-directory are followed (RU and EN)" {
    local f
    for f in $INSTALLERS; do
        _load_fn "$f"
        rm -rf "$TEST_DIR/custom" "$NETDIR/extra.d" "$NETDIR/rel"
        mkdir -p "$TEST_DIR/custom" "$NETDIR/extra.d" "$NETDIR/rel"
        printf 'iface eth0 inet dhcp\n' > "$TEST_DIR/custom/eth0"

        : > "$WARN_LOG"
        printf 'source %s/custom/*\nsource-directory extra.d\n' "$TEST_DIR" > "$NETDIR/interfaces"
        printf 'iface eth0 inet6 static\n' > "$NETDIR/extra.d/v6"
        DISABLE_IPV6=1
        _guard
        [ "$DISABLE_IPV6" = "0" ]
        run grep -c 'extra.d/v6' "$WARN_LOG"
        [ "$output" = "1" ]

        : > "$WARN_LOG"
        rm -f "$NETDIR/extra.d/v6"
        printf 'source rel/*\n' > "$NETDIR/interfaces"
        printf 'iface ens3 inet6 auto\n' > "$NETDIR/rel/ens3"
        DISABLE_IPV6=1
        _guard
        [ "$DISABLE_IPV6" = "0" ]
        run grep -c 'rel/ens3' "$WARN_LOG"
        [ "$output" = "1" ]
    done
}

@test "ifupdown IPv6: relative source glob resolves under the network dir, not the current dir; names with spaces stay whole" {
    _load_fn install_amneziawg.sh
    mkdir -p "$TEST_DIR/cwd/rel" "$NETDIR/rel" "$TEST_DIR/sp"
    printf 'iface eth9 inet dhcp
' > "$TEST_DIR/cwd/rel/decoy"
    printf 'iface eth0 inet6 static
' > "$NETDIR/rel/real"
    printf 'source rel/*
' > "$NETDIR/interfaces"
    DISABLE_IPV6=1
    ( cd "$TEST_DIR/cwd" && _guard )
    run grep -c "$NETDIR/rel/real" "$WARN_LOG"
    [ "$output" = "1" ]

    : > "$WARN_LOG"
    rm -f "$NETDIR/rel/real"
    printf 'iface eth0 inet6 static
' > "$TEST_DIR/sp/my v6 file"
    printf 'source %s/sp/*
' "$TEST_DIR" > "$NETDIR/interfaces"
    DISABLE_IPV6=1
    _guard
    [ "$DISABLE_IPV6" = "0" ]
    run grep -c 'sp/my v6 file' "$WARN_LOG"
    [ "$output" = "1" ]
}

@test "ifupdown IPv6: nested source inside an included file is followed" {
    _load_fn install_amneziawg.sh
    mkdir -p "$TEST_DIR/deep"
    printf 'source %s/deep/*\n' "$TEST_DIR" > "$NETDIR/interfaces.d/10-more"
    printf 'iface eth0 inet6 static\n' > "$TEST_DIR/deep/v6"
    DISABLE_IPV6=1
    _guard
    [ "$DISABLE_IPV6" = "0" ]
    run grep -c 'deep/v6' "$WARN_LOG"
    [ "$output" = "1" ]
}

@test "ifupdown IPv6: a file that sources itself does not hang the walk" {
    _load_fn install_amneziawg.sh
    printf 'source %s/interfaces\niface eth0 inet dhcp\n' "$NETDIR" > "$NETDIR/interfaces"
    run timeout 10 bash -c "$(declare -f guard_ifupdown_ipv6 log_warn log_debug die); DISABLE_IPV6=1; guard_ifupdown_ipv6 '$NETDIR' '$SYSDIR' '$SYSCONF'; echo \"D=\$DISABLE_IPV6\""
    [ "$status" -eq 0 ]
    [ "$output" = "D=1" ]
}

@test "ifupdown IPv6: hitting the file cap counts as IPv6 configured, repeats do not count" {
    local k
    _load_fn install_amneziawg.sh
    for k in $(seq 1 300); do printf 'iface e%s inet dhcp
' "$k" > "$NETDIR/interfaces.d/f$k"; done
    DISABLE_IPV6=1
    _guard
    [ "$DISABLE_IPV6" = "0" ]
    run grep -c '256' "$WARN_LOG"
    [ "$output" = "1" ]

    rm -f "$NETDIR"/interfaces.d/f*
    : > "$WARN_LOG"
    printf 'iface eth0 inet dhcp
' > "$NETDIR/interfaces.d/only"
    : > "$NETDIR/interfaces"
    for k in $(seq 1 300); do printf 'source %s/interfaces.d/*
' "$NETDIR" >> "$NETDIR/interfaces"; done
    DISABLE_IPV6=1
    _guard
    [ "$DISABLE_IPV6" = "1" ]
    [ ! -s "$WARN_LOG" ]
}

@test "ifupdown IPv6: switch-off from an earlier step 1 is removed from the installer's files and sysctl.conf only (RU and EN)" {
    local f
    for f in $INSTALLERS; do
        _load_fn "$f"
        : > "$WARN_LOG"
        _sysctl_fixture
        printf 'iface eth0 inet6 static\n' > "$NETDIR/interfaces"
        DISABLE_IPV6=1
        _guard
        [ "$DISABLE_IPV6" = "0" ]
        [ "$(cat "$SYSDIR/99-amneziawg-security.conf")" = "net.ipv4.ip_forward = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.eth0.disable_ipv6 = 0
net.core.default_qdisc = fq" ]
        [ "$(cat "$SYSDIR/99-amneziawg-forwarding.conf")" = "net.ipv4.ip_forward = 1" ]
        [ "$(cat "$SYSCONF")" = "kernel.sysrq = 0" ]
        cmp "$TEST_DIR/other.before" "$SYSDIR/10-other.conf"
        run grep -c '99-amneziawg-security.conf, .*99-amneziawg-forwarding.conf, .*sysctl.conf' "$WARN_LOG"
        [ "$output" = "1" ]
    done
}

@test "ifupdown IPv6: symlinked sysctl.conf stays a symlink after the cleanup" {
    _load_fn install_amneziawg.sh
    _sysctl_fixture
    mv "$SYSCONF" "$SYSDIR/99-sysctl.conf"
    ln -s "$SYSDIR/99-sysctl.conf" "$SYSCONF"
    printf 'iface eth0 inet6 static\n' > "$NETDIR/interfaces"
    DISABLE_IPV6=1
    _guard
    [ -L "$SYSCONF" ]
    [ "$(cat "$SYSDIR/99-sysctl.conf")" = "kernel.sysrq = 0" ]
}

@test "ifupdown IPv6: a sysctl file that cannot be cleaned stops the install" {
    [ "$(id -u)" -ne 0 ] || skip "root ignores directory permissions"
    _load_fn install_amneziawg.sh
    _sysctl_fixture
    rm -f "$SYSDIR/99-amneziawg-forwarding.conf" "$SYSDIR/10-other.conf" "$SYSCONF"
    chmod 555 "$SYSDIR"
    printf 'iface eth0 inet6 static\n' > "$NETDIR/interfaces"
    DISABLE_IPV6=1
    run _guard
    [ "$status" -ne 0 ]
    run grep -c '99-amneziawg-security.conf' "$DIE_LOG"
    [ "$output" = "1" ]
}

@test "ifupdown IPv6: an unreadable network file is treated as IPv6 configured" {
    [ "$(id -u)" -ne 0 ] || skip "root reads any file"
    _load_fn install_amneziawg.sh
    printf 'iface eth0 inet dhcp\n' > "$NETDIR/interfaces.d/locked"
    chmod 000 "$NETDIR/interfaces.d/locked"
    DISABLE_IPV6=1
    _guard 2>/dev/null
    [ "$DISABLE_IPV6" = "0" ]
    run grep -c 'interfaces.d/locked' "$WARN_LOG"
    [ "$output" = "2" ]
}

@test "ifupdown IPv6: step 0 calls the guard after the IPv6 default, before the tunnel check (RU and EN)" {
    local f lines
    for f in $INSTALLERS; do
        lines=$(grep -n -e 'if \[\[ "\$DISABLE_IPV6" == "default" \]\]; then DISABLE_IPV6=1; fi' \
                       -e '^    guard_ifupdown_ipv6 /etc/network /etc/sysctl.d /etc/sysctl.conf$' \
                       -e '^    configure_ipv6_tunnel$' "$BATS_TEST_DIRNAME/../$f" | cut -d: -f2- | tr -s ' ')
        [ "$lines" = " if [[ \"\$DISABLE_IPV6\" == \"default\" ]]; then DISABLE_IPV6=1; fi
 guard_ifupdown_ipv6 /etc/network /etc/sysctl.d /etc/sysctl.conf
 configure_ipv6_tunnel" ]
    done
}
