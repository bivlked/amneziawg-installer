#!/usr/bin/env bats
# Tests for C5 (v5.15.3): a --force reinstall must not lose peer blocks.
#
# Two problems in the old peer-restore awk inside install_amneziawg.sh:
#   1. Default clients my_phone/my_laptop were deliberately excluded from the
#      restore. The default-generation loop then tried to recreate them, but the
#      generate_client guard (v5.15.1) refuses to recreate a client whose files
#      already exist -> the client became an orphan: files present, no [Peer]
#      block, silent connectivity loss.
#   2. The awk overwrote its buffer on every new [Peer] without flushing the
#      previous one, so only the LAST peer block survived a reinstall.
#
# The fix flushes the buffer on each [Peer] and restores every block. The
# default-generation loop is idempotent (skips peers already present), so
# defaults keep their original keys instead of being regenerated.
#
# Per the repo convention (see test_v515_awk_split_dual_stack.bats) we run a
# faithful copy of the inline awk and also assert the source no longer carries
# the old exclusion, plus RU/EN program parity.

load test_helper

# Faithful copy of the corrected inline peer-restore awk.
run_peer_restore() {
    awk '
        /^\[Peer\]/ { if (in_peer) printf "%s", buf; buf=$0"\n"; in_peer=1; next }
        in_peer && /^\[/ { printf "%s", buf; buf=""; in_peer=0; next }
        in_peer { buf=buf $0"\n"; next }
        END { if (in_peer) printf "%s", buf }
    ' "$1"
}

make_sbak() {
    cat > "$1" << 'CONF'
[Interface]
PrivateKey = SRVPRIV
ListenPort = 39743
PostUp = iptables -I FORWARD -i %i -j ACCEPT

[Peer]
#_Name = my_phone
PublicKey = AAA
AllowedIPs = 10.9.9.2/32

[Peer]
#_Name = alice
PublicKey = BBB
AllowedIPs = 10.9.9.5/32

[Peer]
#_Name = my_laptop
PublicKey = CCC
AllowedIPs = 10.9.9.3/32

[Peer]
#_Name = bob
PublicKey = DDD
AllowedIPs = 10.9.9.6/32
CONF
}

@test "C5: every peer block is restored, including the defaults" {
    local sbak="$TEST_DIR/awg0.bak"
    make_sbak "$sbak"
    run run_peer_restore "$sbak"
    [ "$status" -eq 0 ]
    for name in my_phone alice my_laptop bob; do
        echo "$output" | grep -qxF "#_Name = ${name}" || { echo "missing peer: $name"; false; }
    done
    # And their public keys travel with them (not just the name line).
    echo "$output" | grep -qxF "PublicKey = AAA"
    echo "$output" | grep -qxF "PublicKey = CCC"
}

@test "C5: the LAST peer is not the only survivor (multi-peer flush)" {
    local sbak="$TEST_DIR/awg0.bak"
    make_sbak "$sbak"
    local n
    n=$(run_peer_restore "$sbak" | grep -c '^#_Name = ')
    [ "$n" -eq 4 ]
}

@test "C5: a defaults-only backup restores both defaults" {
    local sbak="$TEST_DIR/awg0.bak"
    cat > "$sbak" << 'CONF'
[Interface]
PrivateKey = SRVPRIV
ListenPort = 39743

[Peer]
#_Name = my_phone
PublicKey = AAA
AllowedIPs = 10.9.9.2/32

[Peer]
#_Name = my_laptop
PublicKey = CCC
AllowedIPs = 10.9.9.3/32
CONF
    local n
    n=$(run_peer_restore "$sbak" | grep -c '^#_Name = ')
    [ "$n" -eq 2 ]
}

@test "C5: source no longer excludes my_phone/my_laptop from restore (RU)" {
    run grep -E 'my_phone\|my_laptop\)\$/\) skip=1' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    [ "$status" -ne 0 ]
}

@test "C5: source no longer excludes my_phone/my_laptop from restore (EN)" {
    run grep -E 'my_phone\|my_laptop\)\$/\) skip=1' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    [ "$status" -ne 0 ]
}

@test "C5: RU and EN peer-restore awk programs are identical" {
    ru=$(awk '/restored_peers=\$\(awk/,/\x27 "\$s_bak"\)/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh" | tr -d ' \t')
    en=$(awk '/restored_peers=\$\(awk/,/\x27 "\$s_bak"\)/' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh" | tr -d ' \t')
    [ -n "$ru" ]
    [ "$ru" = "$en" ]
}
