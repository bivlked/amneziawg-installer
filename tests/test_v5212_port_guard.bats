#!/usr/bin/env bats
# v5.21.2: generate_client and regenerate_client refuse a broken AWG_PORT.
#
# AWG_PORT comes from the hand-edited awgsetup_cfg.init and is rendered into
# the 'Endpoint = IP:PORT' line of the client .conf. Before this, add/regen
# passed it raw, so a corrupt config produced a silently broken profile that
# was carried onto a device and debugged blind - while generate_vpn_uri right
# next door already refused the vpn:// URI for the same input. Now both paths
# sanitize the port and refuse (non-zero, no render) when it collapses to 0.

load test_helper

# Stubs shared by both paths. load_awg_params supplies the port under test via
# _PORT_UT, so the test controls exactly the value the guard sees. A call to
# render drops a marker: the broken-port tests prove render was never reached.
_setup_stubs() {
    get_server_public_ip() { echo "1.2.3.4"; }
    _ensure_server_public_key() { return 0; }
    generate_qr()        { return 0; }
    generate_vpn_uri()   { return 0; }
    generate_qr_vpnuri() { return 0; }
    load_awg_params()    { export AWG_PORT="${_PORT_UT}"; return 0; }
    render_client_config() {
        : > "$AWG_DIR/RENDER_CALLED"
        printf '[Interface]\nAddress = %s/32\n[Peer]\nAllowedIPs = %s\n' \
            "$2" "${ALLOWED_IPS:-0.0.0.0/0}" > "$AWG_DIR/${1}.conf"
        return 0
    }
    export -f get_server_public_ip _ensure_server_public_key generate_qr \
        generate_vpn_uri generate_qr_vpnuri load_awg_params render_client_config
}

_server_conf_with_peer() {
    cat > "$SERVER_CONF_FILE" << 'EOF'
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
#_Name = alice
PublicKey = TESTPUBKEY
AllowedIPs = 10.9.9.2/32
EOF
}

# Everything a full regenerate_client run needs, so the valid-port case really
# reaches the end and returns 0. That is what makes the broken-port cases
# meaningful: they must fail at the port guard, not at some missing prerequisite.
_prepare_regen() {
    _server_conf_with_peer
    mkdir -p "$KEYS_DIR"
    printf 'FAKEPRIVKEY'   > "$KEYS_DIR/alice.private"
    printf 'FAKESERVERPUB' > "$AWG_DIR/server_public.key"
    printf '[Interface]\nPrivateKey = FAKEPRIVKEY\nAddress = 10.9.9.2/32\nDNS = 1.1.1.1, 1.0.0.1\nMTU = 1280\nPersistentKeepalive = 33\n[Peer]\nPublicKey = FAKESERVERPUB\nAllowedIPs = 0.0.0.0/0\n' \
        > "$AWG_DIR/alice.conf"
    _setup_stubs
    export ALLOWED_IPS="0.0.0.0/0"
    export AWG_ENDPOINT="1.2.3.4"
}

# --- regenerate_client: behaviour ---

@test "v5.21.2: regenerate_client refuses a non-numeric AWG_PORT (no render)" {
    require_flock
    _prepare_regen
    export _PORT_UT="abc"

    run regenerate_client "alice"
    [ "$status" -ne 0 ] || { echo "expected non-zero, got 0"; return 1; }
    [ ! -f "$AWG_DIR/RENDER_CALLED" ] || { echo "render was reached on a broken port"; return 1; }
}

@test "v5.21.2: regenerate_client refuses an empty AWG_PORT (no render)" {
    require_flock
    _prepare_regen
    export _PORT_UT=""

    run regenerate_client "alice"
    [ "$status" -ne 0 ]
    [ ! -f "$AWG_DIR/RENDER_CALLED" ]
}

@test "v5.21.2: regenerate_client refuses an out-of-range AWG_PORT (no render)" {
    require_flock
    _prepare_regen
    export _PORT_UT="70000"

    run regenerate_client "alice"
    [ "$status" -ne 0 ]
    [ ! -f "$AWG_DIR/RENDER_CALLED" ]
}

@test "v5.21.2: regenerate_client still works with a valid AWG_PORT" {
    require_flock
    _prepare_regen
    export _PORT_UT="39743"

    run regenerate_client "alice"
    [ "$status" -eq 0 ] || { echo "valid port failed: $output"; return 1; }
    [ -f "$AWG_DIR/RENDER_CALLED" ] || { echo "render was not reached for a valid port"; return 1; }
}

# --- generate_client: behaviour (full path, real render) ---

# Key/psk stubs so generate_client can mint a client without a kernel; real
# load_awg_params reads the (possibly broken) port straight from the config,
# which is exactly the z2i7 scenario.
_gen_stubs() {
    awg() {
        case "$1" in
            genkey)  echo "STUB_PRIVATE_KEY_32B_BASE64VAL==" ;;
            pubkey)  local _pk; _pk=$(cat); echo "pub_${_pk:0:20}" ;;
            genpsk)  echo "GENERATED_PSK_VALUE_32B==" ;;
            set|syncconf|show) return 0 ;;
            *) return 0 ;;
        esac
    }
    get_server_public_ip() { echo "203.0.113.1"; return 0; }
    export -f awg get_server_public_ip
}

_prepare_gen() {
    local port="$1"
    create_server_config
    create_init_config
    # For an existing server, load_awg_params takes AWG_PORT from the live
    # awg0.conf ListenPort (it overrides the init value); break both so the
    # port that actually reaches the guard is the value under test.
    sed -i "s/^ListenPort = .*/ListenPort = ${port}/" "$SERVER_CONF_FILE"
    sed -i "s/^export AWG_PORT=.*/export AWG_PORT=${port}/" "$CONFIG_FILE"
    mkdir -p "$KEYS_DIR"
    echo "SERVER_PRIV" > "$AWG_DIR/server_private.key"
    echo "SERVER_PUB"  > "$AWG_DIR/server_public.key"
    _gen_stubs
}

@test "v5.21.2: generate_client refuses a non-numeric AWG_PORT (no client .conf)" {
    require_flock
    _prepare_gen "abc"
    run generate_client "newcli"
    [ "$status" -ne 0 ] || { echo "expected non-zero, got 0"; return 1; }
    [ ! -f "$AWG_DIR/newcli.conf" ] || { echo "a broken-port client .conf was written"; return 1; }
}

@test "v5.21.2: generate_client still creates the client with a valid AWG_PORT" {
    require_flock
    _prepare_gen "39743"
    run generate_client "newcli"
    [ "$status" -eq 0 ] || { echo "valid port failed: $output"; return 1; }
    [ -f "$AWG_DIR/newcli.conf" ] || { echo "no client .conf on a valid port"; return 1; }
    # The rendered Endpoint carries the sanitized numeric port.
    grep -qE '^Endpoint = .*:39743$' "$AWG_DIR/newcli.conf" \
        || { echo "endpoint port wrong: $(grep Endpoint "$AWG_DIR/newcli.conf")"; return 1; }
}

# --- wiring invariant: the fix is present in both paths and both languages ---

@test "v5.21.2: generate/regenerate render the sanitized port, not raw AWG_PORT (RU+EN)" {
    for f in awg_common.sh awg_common_en.sh; do
        local src="$BATS_TEST_DIRNAME/../$f"
        # Both client renders must pass the sanitized "$_cport", never the raw
        # "${AWG_PORT}".
        run grep -cF 'render_client_config "$name" "$client_ip" "$client_privkey" "$server_pubkey" "$endpoint" "$_cport" "$client_ipv6"' "$src"
        [ "$output" -eq 2 ] || { echo "$f: expected 2 sanitized render calls, found $output"; return 1; }
        run grep -F 'render_client_config "$name" "$client_ip" "$client_privkey" "$server_pubkey" "$endpoint" "${AWG_PORT}" "$client_ipv6"' "$src"
        [ "$status" -ne 0 ] || { echo "$f still renders a raw AWG_PORT"; return 1; }
        # The guard itself must exist twice (generate_client + regenerate_client).
        run grep -cF '_cport=$(_sanitize_port "${AWG_PORT:-}")' "$src"
        [ "$output" -eq 2 ] || { echo "$f: expected 2 port guards, found $output"; return 1; }
    done
}
