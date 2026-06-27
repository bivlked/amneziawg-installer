#!/usr/bin/env bats
# v5.18.1 bug-fix release. Three independent fixes:
#
#   jue6 - install --force --port=N was silently ignored: render_server_config
#          calls load_awg_params, which re-reads ListenPort from the live
#          awg0.conf and overwrote the CLI/init port. The new server config now
#          takes the port from the init file (the user's intent, survives the
#          reboot-resume of --force). render_server_config is install-only, so
#          client regen (regenerate_client) is unaffected.
#   rl9c - client DNS default is now a Cloudflare pair "1.1.1.1, 1.0.0.1"
#          instead of a single resolver.
#   r11y - full-tunnel clients (AllowedIPs = 0.0.0.0/0) now get "0.0.0.0/0, ::/0"
#          so iOS AmneziaVPN accepts the "all traffic" mode. Split-tunnel
#          (custom list != 0.0.0.0/0) is untouched.
# shellcheck disable=SC2154  # Variables set by sourced scripts at runtime

load test_helper

stub_nic() {
    get_main_nic() { echo "eth0"; }
    export -f get_main_nic
}

# --- jue6: port from init wins over live awg0.conf in server render ---

@test "v5.18.1 jue6: render_server_config takes ListenPort from init, not old awg0.conf" {
    stub_nic
    create_init_config
    # Simulate --force --port=443: Step 0 saved the new port into init, while the
    # live awg0.conf still carries the old 39743.
    sed -i 's/^export AWG_PORT=.*/export AWG_PORT=443/' "$CONFIG_FILE"
    create_server_config
    echo "SERVER_PRIV" > "$AWG_DIR/server_private.key"

    run render_server_config
    [ "$status" -eq 0 ]
    grep -qxF "ListenPort = 443" "$SERVER_CONF_FILE"
    # The stale 39743 from the old awg0.conf must not survive.
    run grep -qxF "ListenPort = 39743" "$SERVER_CONF_FILE"
    [ "$status" -ne 0 ]
}

@test "v5.18.1 jue6: port unchanged when init matches old config (no --port)" {
    stub_nic
    create_init_config
    create_server_config
    echo "SERVER_PRIV" > "$AWG_DIR/server_private.key"

    run render_server_config
    [ "$status" -eq 0 ]
    grep -qxF "ListenPort = 39743" "$SERVER_CONF_FILE"
}

# --- rl9c: dual DNS default ---

@test "v5.18.1 rl9c: client config DNS defaults to 1.1.1.1, 1.0.0.1" {
    create_init_config
    render_client_config "c1" "10.9.9.2" "CLIENTPRIV" "SERVERPUB" "1.2.3.4" "443"
    grep -qxF "DNS = 1.1.1.1, 1.0.0.1" "$AWG_DIR/c1.conf"
}

# --- r11y: full-tunnel ::/0 for iOS; split-tunnel untouched ---

@test "v5.18.1 r11y: full-tunnel client gets 0.0.0.0/0, ::/0" {
    create_init_config
    sed -i "s|^export ALLOWED_IPS=.*|export ALLOWED_IPS='0.0.0.0/0'|" "$CONFIG_FILE"
    render_client_config "c2" "10.9.9.3" "CLIENTPRIV" "SERVERPUB" "1.2.3.4" "443"
    grep -qxF "AllowedIPs = 0.0.0.0/0, ::/0" "$AWG_DIR/c2.conf"
}

@test "v5.18.1 r11y: split-tunnel (custom list) does NOT get ::/0" {
    create_init_config
    sed -i "s|^export ALLOWED_IPS=.*|export ALLOWED_IPS='1.0.0.0/8, 2.0.0.0/7'|" "$CONFIG_FILE"
    render_client_config "c3" "10.9.9.4" "CLIENTPRIV" "SERVERPUB" "1.2.3.4" "443"
    grep -qxF "AllowedIPs = 1.0.0.0/8, 2.0.0.0/7" "$AWG_DIR/c3.conf"
    run grep -qF "::/0" "$AWG_DIR/c3.conf"
    [ "$status" -ne 0 ]
}

# --- r11y/rl9c via regen: upgrade non-customized clients, preserve custom ones ---

# Build a full regen scenario: server peer block, an existing client .conf with
# the OLD AllowedIPs/DNS, keys, and stubbed externals. regenerate_client runs the
# real render + the restore-with-upgrade path under test.
setup_regen_scenario() {
    # $1 name, $2 client_ip, $3 old_allowedips, $4 old_dns
    create_server_config
    create_init_config
    add_test_peer "$1" "$2"
    mkdir -p "$KEYS_DIR"
    printf 'FAKEPRIV' > "$KEYS_DIR/$1.private"
    printf 'FAKESERVERPUB' > "$AWG_DIR/server_public.key"
    cat > "$AWG_DIR/$1.conf" << EOF
[Interface]
PrivateKey = FAKEPRIV
Address = $2/32
DNS = $4
MTU = 1280

[Peer]
PublicKey = FAKESERVERPUB
Endpoint = 1.2.3.4:39743
AllowedIPs = $3
PersistentKeepalive = 33
EOF
    get_server_public_ip() { echo "1.2.3.4"; }
    _ensure_server_public_key() { return 0; }
    generate_qr()        { return 0; }
    generate_vpn_uri()   { return 0; }
    generate_qr_vpnuri() { return 0; }
    export -f get_server_public_ip _ensure_server_public_key generate_qr generate_vpn_uri generate_qr_vpnuri
}

@test "v5.18.1 regen: full-tunnel client upgraded to ::/0 and DNS pair" {
    require_flock
    setup_regen_scenario "alice" "10.9.9.2" "0.0.0.0/0" "1.1.1.1"
    run regenerate_client "alice"
    [ "$status" -eq 0 ]
    grep -qxF "AllowedIPs = 0.0.0.0/0, ::/0" "$AWG_DIR/alice.conf"
    grep -qxF "DNS = 1.1.1.1, 1.0.0.1" "$AWG_DIR/alice.conf"
}

@test "v5.18.1 regen: customized client (modify) preserved, no upgrade" {
    require_flock
    setup_regen_scenario "bob" "10.9.9.3" "10.0.0.0/8" "8.8.8.8"
    run regenerate_client "bob"
    [ "$status" -eq 0 ]
    grep -qxF "AllowedIPs = 10.0.0.0/8" "$AWG_DIR/bob.conf"
    grep -qxF "DNS = 8.8.8.8" "$AWG_DIR/bob.conf"
    run grep -qF "::/0" "$AWG_DIR/bob.conf"
    [ "$status" -ne 0 ]
}

# --- RU/EN parity of the three fixes ---

@test "v5.18.1 parity: jue6 init-port override present in RU+EN" {
    local p
    for p in awg_common.sh awg_common_en.sh; do
        grep -qF '_init_port=$(grep -oP' "${BATS_TEST_DIRNAME}/../$p"
    done
}

@test "v5.18.1 parity: rl9c dual DNS + r11y ::/0 present in RU+EN" {
    local p
    for p in awg_common.sh awg_common_en.sh; do
        grep -qF 'DNS = 1.1.1.1, 1.0.0.1' "${BATS_TEST_DIRNAME}/../$p"
        grep -qF 'allowed_ips="0.0.0.0/0, ::/0"' "${BATS_TEST_DIRNAME}/../$p"
    done
}
