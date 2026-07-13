#!/usr/bin/env bats
# Issue #170 - changing the routing mode after install had no effect.
#
# Two bundled fixes:
#   1. install: --route-all/--route-amnezia on reinstall changed only
#      ALLOWED_IPS_MODE while ALLOWED_IPS kept the old list loaded from
#      awgsetup_cfg.init (configure_routing_mode ran only on empty list).
#      The CLI override block now clears ALLOWED_IPS so the list is
#      recomputed for the new mode.
#   2. manage regen --reset-routes: a regular regen deliberately preserves
#      per-client AllowedIPs (modify customizations), so a changed global
#      routing mode never reached existing clients. The new flag keeps the
#      freshly rendered AllowedIPs (global mode) instead of restoring the
#      client's old value.

load test_helper

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_make_server_conf_with_peer() {
    local name="$1" ipv4="$2"
    cat > "$SERVER_CONF_FILE" << EOF
[Interface]
PrivateKey = SERVERKEY
Address = 10.9.9.1/24
ListenPort = 39743
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
PostUp = iptables -I FORWARD -i %i -j ACCEPT
PostDown = iptables -D FORWARD -i %i -j ACCEPT

[Peer]
#_Name = ${name}
PublicKey = TESTPUBKEY
AllowedIPs = ${ipv4}/32
EOF
}

# Common stubs for regenerate_client; render_client_config mirrors the real
# renderer for the aspect under test: AllowedIPs comes from the global
# ALLOWED_IPS (awgsetup_cfg.init).
_setup_regen_stubs() {
    get_server_public_ip() { echo "1.2.3.4"; }
    _ensure_server_public_key() { return 0; }
    generate_qr()          { return 0; }
    generate_vpn_uri()     { return 0; }
    generate_qr_vpnuri()   { return 0; }
    load_awg_params()      { export AWG_PORT=39743; return 0; }
    render_client_config() {
        printf '[Interface]\nPrivateKey = FAKEPRIVKEY\nAddress = %s/32\nDNS = 1.1.1.1, 1.0.0.1\nMTU = 1280\nPersistentKeepalive = 33\n[Peer]\nPublicKey = FAKESERVERPUB\nAllowedIPs = %s\n' \
            "$2" "${ALLOWED_IPS:-0.0.0.0/0}" > "$AWG_DIR/${1}.conf"
        return 0
    }
    export -f get_server_public_ip _ensure_server_public_key generate_qr \
        generate_vpn_uri generate_qr_vpnuri load_awg_params render_client_config
}

_client_allowed_ips() {
    sed -n '/^\[Peer\]/,$ s/^AllowedIPs[ \t]*=[ \t]*//p' "$AWG_DIR/${1}.conf"
}

# ---------------------------------------------------------------------------
# Fix 2 (functional): regen with/without AWG_REGEN_RESET_ROUTES
# ---------------------------------------------------------------------------

@test "issue #170: plain regen still preserves per-client AllowedIPs (modify contract)" {
    require_flock
    _make_server_conf_with_peer "alice" "10.9.9.2"
    mkdir -p "$KEYS_DIR"
    printf 'FAKEPRIVKEY' > "$KEYS_DIR/alice.private"
    printf 'FAKESERVERPUB' > "$AWG_DIR/server_public.key"
    _setup_regen_stubs

    # Customized client (as if via `manage modify`), global mode = full tunnel
    printf '[Interface]\nPrivateKey = FAKEPRIVKEY\nAddress = 10.9.9.2/32\nDNS = 1.1.1.1, 1.0.0.1\nMTU = 1280\nPersistentKeepalive = 33\n[Peer]\nPublicKey = FAKESERVERPUB\nAllowedIPs = 10.11.0.0/16, 192.168.100.0/24\n' \
        > "$AWG_DIR/alice.conf"
    export ALLOWED_IPS="0.0.0.0/0"
    unset AWG_REGEN_RESET_ROUTES

    run regenerate_client "alice"
    [ "$status" -eq 0 ]
    # regenerate_client strips whitespace when preserving the old value
    # (tr -d '[:space:]'), hence no space after the comma.
    [ "$(_client_allowed_ips alice)" = "10.11.0.0/16,192.168.100.0/24" ]
}

@test "issue #170: regen with AWG_REGEN_RESET_ROUTES=1 applies the global routing mode" {
    require_flock
    _make_server_conf_with_peer "bob" "10.9.9.3"
    mkdir -p "$KEYS_DIR"
    printf 'FAKEPRIVKEY' > "$KEYS_DIR/bob.private"
    printf 'FAKESERVERPUB' > "$AWG_DIR/server_public.key"
    _setup_regen_stubs

    # Old client with the Amnezia list, global mode switched to full tunnel
    printf '[Interface]\nPrivateKey = FAKEPRIVKEY\nAddress = 10.9.9.3/32\nDNS = 1.1.1.1, 1.0.0.1\nMTU = 1280\nPersistentKeepalive = 33\n[Peer]\nPublicKey = FAKESERVERPUB\nAllowedIPs = 1.0.0.0/8, 2.0.0.0/7\n' \
        > "$AWG_DIR/bob.conf"
    export ALLOWED_IPS="0.0.0.0/0"
    export AWG_REGEN_RESET_ROUTES=1

    run regenerate_client "bob"
    unset AWG_REGEN_RESET_ROUTES
    [ "$status" -eq 0 ]
    [ "$(_client_allowed_ips bob)" = "0.0.0.0/0" ]
}

@test "issue #170: reset-routes regen still preserves per-client DNS and keepalive" {
    require_flock
    _make_server_conf_with_peer "carol" "10.9.9.4"
    mkdir -p "$KEYS_DIR"
    printf 'FAKEPRIVKEY' > "$KEYS_DIR/carol.private"
    printf 'FAKESERVERPUB' > "$AWG_DIR/server_public.key"
    _setup_regen_stubs

    printf '[Interface]\nPrivateKey = FAKEPRIVKEY\nAddress = 10.9.9.4/32\nDNS = 9.9.9.9\nMTU = 1280\nPersistentKeepalive = 21\n[Peer]\nPublicKey = FAKESERVERPUB\nAllowedIPs = 1.0.0.0/8\n' \
        > "$AWG_DIR/carol.conf"
    export ALLOWED_IPS="0.0.0.0/0"
    export AWG_REGEN_RESET_ROUTES=1

    run regenerate_client "carol"
    unset AWG_REGEN_RESET_ROUTES
    [ "$status" -eq 0 ]
    [ "$(_client_allowed_ips carol)" = "0.0.0.0/0" ]
    grep -q '^DNS = 9.9.9.9$' "$AWG_DIR/carol.conf"
    grep -q '^PersistentKeepalive = 21$' "$AWG_DIR/carol.conf"
}

# ---------------------------------------------------------------------------
# Fix 2 (structural): manage RU/EN wire --reset-routes to the ENV flag
# ---------------------------------------------------------------------------

@test "issue #170: RU/EN manage parse --reset-routes into CLI_RESET_ROUTES" {
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        run grep -F -- '--reset-routes)' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ]
        [[ "$output" == *'CLI_RESET_ROUTES=1'* ]]
    done
}

@test "issue #170: RU/EN manage regen case exports AWG_REGEN_RESET_ROUTES" {
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        block=$(awk '/^    regen\)/,/^[[:space:]]+;;[[:space:]]*$/' "$BATS_TEST_DIRNAME/../$f")
        [[ "$block" == *'export AWG_REGEN_RESET_ROUTES=1'* ]]
    done
}

@test "issue #170: RU/EN manage help mentions --reset-routes" {
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        run grep -F -- '--reset-routes ' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ]
    done
}

@test "issue #170: RU/EN awg_common guard AllowedIPs restore behind AWG_REGEN_RESET_ROUTES" {
    for f in awg_common.sh awg_common_en.sh; do
        run grep -F 'AWG_REGEN_RESET_ROUTES' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ]
    done
}

# ---------------------------------------------------------------------------
# Fix 1 (structural): installer CLI override clears the stale list
# ---------------------------------------------------------------------------

@test "issue #170: RU/EN install CLI override resets ALLOWED_IPS before mode-3 assignment" {
    # The override block (step 0, after the config load) must clear
    # ALLOWED_IPS so configure_routing_mode recomputes it for the new mode;
    # previously the stale list from awgsetup_cfg.init survived the override.
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run grep -A8 'ALLOWED_IPS_MODE=$CLI_ROUTING_MODE' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ]
        [[ "$output" == *'ALLOWED_IPS=""'* ]]
    done
}

@test "issue #170: RU/EN install hint suggests regen --reset-routes after a mode change" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run grep -F 'regen --reset-routes' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ]
    done
}
