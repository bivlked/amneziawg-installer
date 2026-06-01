#!/usr/bin/env bats
# Phase 4 (review finding 4.7) - upgrade / force-rerun scenario.
#
# Verifies that an existing IPv4-only peer in awg0.conf is NOT automatically
# upgraded when a NEW dual-stack client is added with ALLOW_IPV6_TUNNEL=1.
# The existing peer must retain its original AllowedIPs (IPv4-only).
#
# Two-step test:
#   1. Simulate "old install": server config has an IPv4-only peer (alice).
#   2. add_peer_to_server is called for a new dual-stack client (bob).
#   3. Assert: alice's AllowedIPs is still 10.9.9.2/32 (unchanged).
#   4. Assert: bob's AllowedIPs contains both /32 and /128.

load test_helper

# Build server config with one IPv4-only peer (simulates pre-5.15 install)
make_ipv4_install_conf() {
    cat > "$SERVER_CONF_FILE" << 'CONF'
[Interface]
PrivateKey = SERVERKEY
Address = 10.9.9.1/24
ListenPort = 39743
PostUp = iptables -I FORWARD -i %i -j ACCEPT
PostDown = iptables -D FORWARD -i %i -j ACCEPT
Jc = 6
Jmin = 55
Jmax = 380
S1 = 72
S2 = 56
S3 = 32
S4 = 16
H1 = 100000-800000
H2 = 1000000-8000000
H3 = 10000000-80000000
H4 = 100000000-800000000

[Peer]
#_Name = alice
PublicKey = ALICEPUBKEY
AllowedIPs = 10.9.9.2/32
CONF
}

# --- Existing client is NOT touched ---

@test "v5.15: upgrade - existing IPv4-only peer AllowedIPs unchanged after new dual-stack add" {
    make_ipv4_install_conf
    # Add a new dual-stack peer (bob) without touching alice
    add_peer_to_server "bob" "BOBPUBKEY" "10.9.9.3" "fddd:2c4:2c4:2c4::3"

    # Alice's AllowedIPs must still be IPv4-only
    alice_allowed=$(awk '
        /^\[Peer\]/ { in_peer=1; found=0; next }
        in_peer && $0 == "#_Name = alice" { found=1; next }
        in_peer && found && /^AllowedIPs/ { print; exit }
        /^\[/ && !/^\[Peer\]/ { in_peer=0; found=0 }
    ' "$SERVER_CONF_FILE")
    [ "$alice_allowed" = "AllowedIPs = 10.9.9.2/32" ]
}

@test "v5.15: upgrade - new dual-stack peer has dual-stack AllowedIPs" {
    make_ipv4_install_conf
    add_peer_to_server "bob" "BOBPUBKEY" "10.9.9.3" "fddd:2c4:2c4:2c4::3"

    bob_allowed=$(awk '
        /^\[Peer\]/ { in_peer=1; found=0; next }
        in_peer && $0 == "#_Name = bob" { found=1; next }
        in_peer && found && /^AllowedIPs/ { print; exit }
        /^\[/ && !/^\[Peer\]/ { in_peer=0; found=0 }
    ' "$SERVER_CONF_FILE")
    [ "$bob_allowed" = "AllowedIPs = 10.9.9.3/32, fddd:2c4:2c4:2c4::3/128" ]
}

@test "v5.15: upgrade - add_peer_to_server IPv4-only (no ipv6 arg) does not modify existing peers" {
    make_ipv4_install_conf
    # Add another IPv4-only peer (charlie)
    add_peer_to_server "charlie" "CHARLIEPUBKEY" "10.9.9.4"

    alice_allowed=$(awk '
        /^\[Peer\]/ { in_peer=1; found=0; next }
        in_peer && $0 == "#_Name = alice" { found=1; next }
        in_peer && found && /^AllowedIPs/ { print; exit }
        /^\[/ && !/^\[Peer\]/ { in_peer=0; found=0 }
    ' "$SERVER_CONF_FILE")
    [ "$alice_allowed" = "AllowedIPs = 10.9.9.2/32" ]
}

@test "v5.15: upgrade - add_peer_to_server with empty ipv6 writes IPv4-only AllowedIPs" {
    make_ipv4_install_conf
    add_peer_to_server "charlie" "CHARLIEPUBKEY" "10.9.9.4" ""

    charlie_allowed=$(awk '
        /^\[Peer\]/ { in_peer=1; found=0; next }
        in_peer && $0 == "#_Name = charlie" { found=1; next }
        in_peer && found && /^AllowedIPs/ { print; exit }
        /^\[/ && !/^\[Peer\]/ { in_peer=0; found=0 }
    ' "$SERVER_CONF_FILE")
    [ "$charlie_allowed" = "AllowedIPs = 10.9.9.4/32" ]
}

@test "v5.15: upgrade - server config retains all original peer count after dual-stack add" {
    make_ipv4_install_conf
    add_peer_to_server "bob" "BOBPUBKEY" "10.9.9.3" "fddd:2c4:2c4:2c4::3"

    peer_count=$(grep -c '^\[Peer\]' "$SERVER_CONF_FILE")
    [ "$peer_count" -eq 2 ]
}
