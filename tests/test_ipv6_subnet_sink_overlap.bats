#!/usr/bin/env bats
# IPV6_SUBNET must not overlap the IPv6 "sink" prefix fddd:2c4:2c4:ffff (routing
# mode 2, see AWG_V6_SINK_PREFIX in awg_common.sh). Sink addresses are told apart
# from a client's real IPv6 by that prefix, textually and case-insensitively. With
# IPV6_SUBNET inside it, every dual-stack client address looked like a sink:
# regen and modify could drop it, vpn:// and list hid it. IPV6_SUBNET is a
# documented override, so the installer refuses such a value at step 0 and the
# library refuses to hand out an address from it.
#
# shellcheck disable=SC2154  # Variables set by sourced scripts at runtime

load test_helper

LIBS=(awg_common.sh awg_common_en.sh)
INSTALLERS=(install_amneziawg.sh install_amneziawg_en.sh)

_use_lib() {
    # shellcheck source=/dev/null
    source "$BATS_TEST_DIRNAME/../$1"
}

@test "sink overlap: the predicate matches the sink prefix in any case and depth (both libraries)" {
    local lib v
    for lib in "${LIBS[@]}"; do
        _use_lib "$lib"
        declare -F _ipv6_subnet_hits_sink >/dev/null || { echo "$lib: no _ipv6_subnet_hits_sink" >&2; return 1; }
        for v in 'fddd:2c4:2c4:ffff::/64' 'FDDD:2C4:2C4:FFFF::/64' 'fddd:2c4:2c4:ffff:0::/80'; do
            if ! _ipv6_subnet_hits_sink "$v"; then echo "$lib: '$v' not recognised as the sink" >&2; return 1; fi
        done
        for v in 'fddd:2c4:2c4:2c4::/64' 'fddd:2c4:2c4::/48' 'fd00:1::/64' 'fddd:2c4:2c4:fffe::/64' 'fddd:2c4:2c4:ffff0::/64'; do
            if _ipv6_subnet_hits_sink "$v"; then echo "$lib: '$v' wrongly taken for the sink" >&2; return 1; fi
        done
    done
}

@test "sink overlap: get_next_client_ipv6 refuses an IPV6_SUBNET inside the sink (both libraries)" {
    local lib out rc
    for lib in "${LIBS[@]}"; do
        _use_lib "$lib"
        rc=0; out=$(IPV6_SUBNET='fddd:2c4:2c4:2c4::/64' get_next_client_ipv6 10.9.9.2) || rc=$?
        [ "$rc" -eq 0 ] && [ "$out" = "fddd:2c4:2c4:2c4::2" ] || { echo "$lib: default subnet: rc=$rc out='$out'" >&2; return 1; }
        rc=0; out=$(IPV6_SUBNET='FDDD:2C4:2C4:FFFF::/64' get_next_client_ipv6 10.9.9.2) || rc=$?
        [ "$rc" -ne 0 ] || { echo "$lib: sink subnet handed out '$out'" >&2; return 1; }
        [ -z "$out" ] || { echo "$lib: sink subnet printed '$out'" >&2; return 1; }
    done
}

# configure_ipv6_tunnel from the installer, with host changes stubbed out.
# _cfg <installer> <ALLOW_IPV6_TUNNEL> <IPV6_SUBNET> ; stderr to $TEST_DIR/err.
_cfg() {
    local f="$1" allow="$2" subnet="$3" rc=0
    ( die() { echo "DIE: $*" >&2; exit 1; }
      log_warn() { echo "WARN: $*" >&2; }
      sysctl() { :; }
      detect_native_ipv6() { echo 0; }
      # shellcheck source=/dev/null
      source <(sed -n '/^configure_ipv6_tunnel() {$/,/^}$/p' "$BATS_TEST_DIRNAME/../$f")
      declare -F configure_ipv6_tunnel >/dev/null || exit 99
      CONFIG_FILE="$TEST_DIR/awgsetup_cfg.init" SERVER_CONF_FILE="${SRV_CONF:-$TEST_DIR/none.conf}" \
          CLI_ALLOW_IPV6_TUNNEL=0 ALLOW_IPV6_TUNNEL="$allow" DISABLE_IPV6=0 IPV6_SUBNET="$subnet" configure_ipv6_tunnel
    ) 2>"$TEST_DIR/err" || rc=$?
    return "$rc"
}

@test "sink overlap: the installer stops at step 0 on an IPV6_SUBNET inside the sink (both languages)" {
    local f rc
    for f in "${INSTALLERS[@]}"; do
        rc=0; _cfg "$f" 1 'fddd:2c4:2c4:ffff::/64' || rc=$?
        [ "$rc" -eq 1 ] || { echo "$f: sink subnet with the IPv6 tunnel: rc=$rc" >&2; return 1; }
        grep -q 'DIE: .*IPV6_SUBNET' "$TEST_DIR/err" || { echo "$f: no refusal naming IPV6_SUBNET: $(cat "$TEST_DIR/err")" >&2; return 1; }
        rc=0; _cfg "$f" 1 'fddd:2c4:2c4:2c4::/64' || rc=$?
        [ "$rc" -eq 0 ] || { echo "$f: default subnet refused: rc=$rc $(cat "$TEST_DIR/err")" >&2; return 1; }
        # A server that already sits in the sink prefix and has clients is
        # warned, not stopped: the subnet cannot change under live peers, and a
        # rerun makes nothing worse there.
        printf '[Interface]\nAddress = 10.9.9.1/24, FDDD:2c4:2c4:ffff::1/64\n\n[Peer]\n#_Name = a\n' > "$TEST_DIR/srv.conf"
        rc=0; SRV_CONF="$TEST_DIR/srv.conf" _cfg "$f" 1 'fddd:2c4:2c4:ffff::/64' || rc=$?
        [ "$rc" -eq 0 ] || { echo "$f: server already in the sink stopped: rc=$rc $(cat "$TEST_DIR/err")" >&2; return 1; }
        grep -q 'WARN: .*IPV6_SUBNET.*--uninstall' "$TEST_DIR/err" || { echo "$f: no warning with the clean path: $(cat "$TEST_DIR/err")" >&2; return 1; }
        # A server with clients in another IPv6 subnet (or without IPv6) and a
        # sink value in the init file: that is a new subnet change under live
        # peers, so it stops as on a clean server.
        for addr in '10.9.9.1/24, fddd:2c4:2c4:2c4::1/64' '10.9.9.1/24'; do
            printf '[Interface]\nAddress = %s\n\n[Peer]\n#_Name = a\n' "$addr" > "$TEST_DIR/srv.conf"
            rc=0; SRV_CONF="$TEST_DIR/srv.conf" _cfg "$f" 1 'fddd:2c4:2c4:ffff::/64' || rc=$?
            [ "$rc" -eq 1 ] || { echo "$f: sink value on a server at '$addr' was not stopped: rc=$rc" >&2; return 1; }
            grep -q 'DIE: .*IPV6_SUBNET' "$TEST_DIR/err" || { echo "$f: no refusal for '$addr': $(cat "$TEST_DIR/err")" >&2; return 1; }
        done
        # Without the IPv6 tunnel IPV6_SUBNET is not used, nothing to stop.
        rc=0; _cfg "$f" 0 'fddd:2c4:2c4:ffff::/64' || rc=$?
        [ "$rc" -eq 0 ] || { echo "$f: sink subnet without the IPv6 tunnel refused: rc=$rc" >&2; return 1; }
    done
}

@test "sink overlap: the installer's copy of the sink prefix equals the library's (both languages)" {
    local i lib_prefix inst_prefix
    for i in 0 1; do
        lib_prefix=$(sed -n 's/^AWG_V6_SINK_PREFIX="\(.*\)"$/\1/p' "$BATS_TEST_DIRNAME/../${LIBS[$i]}")
        inst_prefix=$(sed -n 's/^[[:space:]]*local sink_prefix="\(.*\)"$/\1/p' "$BATS_TEST_DIRNAME/../${INSTALLERS[$i]}")
        [ -n "$lib_prefix" ] || { echo "${LIBS[$i]}: AWG_V6_SINK_PREFIX not found" >&2; return 1; }
        [ "$lib_prefix" = "$inst_prefix" ] || { echo "${INSTALLERS[$i]}: sink prefix '$inst_prefix' != library '$lib_prefix'" >&2; return 1; }
    done
}

# The invariant the predicate stands for: it holds exactly when a client
# address built from the subnet ("prefix::N", as get_next_client_ipv6 does) would
# be recognised as a sink. Pinned on a spread of spellings so the two functions
# cannot drift apart.
@test "sink overlap: the predicate agrees with _is_v6_sink_addr on client addresses (both libraries)" {
    local lib v p want got
    for lib in "${LIBS[@]}"; do
        _use_lib "$lib"
        for v in 'fddd:2c4:2c4:ffff::/64' 'FDDD:2C4:2C4:FFFF::/64' 'fddd:2c4:2c4:ffff:0::/80' \
                 'fddd:2c4:2c4:ffff:1:2::/96' 'fddd:2c4:2c4:2c4::/64' 'fddd:2c4:2c4::/48' \
                 'fddd:02c4:02c4:ffff::/64' 'fddd:2c4:2c4:fffe::/64' 'fddd:2c4:2c4:ffff0::/64' 'fd00::/64'; do
            p="${v%%::*}"
            want=no; _is_v6_sink_addr "${p}::2" && want=yes
            got=no; _ipv6_subnet_hits_sink "$v" && got=yes
            [ "$want" = "$got" ] || { echo "$lib: '$v': sink address check says $want, subnet check says $got" >&2; return 1; }
        done
    done
}
