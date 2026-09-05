#!/usr/bin/env bats
# Issue #253 - per-client AllowedIPs at creation time (`manage add
# --allowed-ips=<CIDR list>`).
#
# Until now `add` only took --expires/--psk: a new client always received the
# server-wide routing mode, and custom routes could only be patched in
# afterwards with `modify <name> AllowedIPs <value>` (the two-step workaround
# the awgram Telegram bot has to run today). The systematic fix is an env
# contract mirroring CLIENT_PSK: the manage CLI flag exports
# CLIENT_ALLOWED_IPS, generate_client validates it (defense-in-depth),
# render_client_config uses it instead of the global ALLOWED_IPS with the same
# intent-mirroring rules (full tunnel -> ::/0 / tunnel-ULA, split -> list
# as-is + tunnel-ULA only, a value that already carries IPv6 tokens is
# written exactly as given), and regenerate_client must never see a leaked
# override (its contract is "global mode, then restore the client's own
# value").

load test_helper

bats_require_minimum_version 1.5.0

mock_awg() {
    # shellcheck disable=SC2317
    awg() {
        case "$1" in
            genkey)  echo "STUB_PRIVATE_KEY_32B_BASE64VAL==" ;;
            pubkey)  local _pk; _pk=$(cat); echo "pub_${_pk:0:20}" ;;
            genpsk)  echo "GENERATED_PSK_VALUE_32B==" ;;
            set)     return 0 ;;
            syncconf) return 0 ;;
            show)    return 0 ;;
            *)       command awg "$@" 2>/dev/null || return 0 ;;
        esac
    }
    export -f awg
}

setup_params() {
    mock_awg
    create_server_config
    create_init_config
    mkdir -p "$KEYS_DIR"
    echo "SERVER_PRIV" > "$AWG_DIR/server_private.key"
    echo "SERVER_PUB"  > "$AWG_DIR/server_public.key"
}

# Same harness style as test_v5210_json_commands.bats: the real manage script
# end-to-end in a mock environment (stubbed awg, AWG_SKIP_APPLY=1).
setup_manage_env() {
    MGMT_DIR=$(mktemp -d)
    mkdir -p "$MGMT_DIR/bin" "$MGMT_DIR/awg/keys"
    cat > "$MGMT_DIR/bin/awg" << 'STUB'
#!/bin/bash
case "$1" in
    genkey|genpsk) echo "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ;;
    pubkey) cat >/dev/null; echo "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=" ;;
    *) exit 0 ;;
esac
STUB
    chmod +x "$MGMT_DIR/bin/awg"
    export PATH="$MGMT_DIR/bin:$PATH"
    cp "$BATS_TEST_DIRNAME/../awg_common.sh" "$MGMT_DIR/awg/awg_common.sh"
    cat > "$MGMT_DIR/awg/awgsetup_cfg.init" << 'CONF'
export AWG_PORT=39743
export AWG_TUNNEL_SUBNET='10.9.9.1/24'
export DISABLE_IPV6=1
export ALLOWED_IPS_MODE=1
export ALLOWED_IPS='0.0.0.0/0'
export AWG_Jc=6
export AWG_Jmin=55
export AWG_Jmax=380
export AWG_S1=72
export AWG_S2=56
export AWG_S3=32
export AWG_S4=16
export AWG_H1='100000-800000'
export AWG_H2='1000000-8000000'
export AWG_H3='10000000-80000000'
export AWG_H4='100000000-800000000'
export AWG_APPLY_MODE='syncconf'
CONF
    cat > "$MGMT_DIR/awg/awg0.conf" << 'CONF'
[Interface]
PrivateKey = TESTKEY
Address = 10.9.9.1/24
MTU = 1280
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
CONF
    export AWG_SKIP_APPLY=1
}

teardown_manage_env() {
    unset AWG_SKIP_APPLY
    rm -rf "${MGMT_DIR:-}"
}

# Review follow-up: the helper's setup() creates its own $TEST_DIR; reusing
# that name in setup_manage_env leaked one temp dir per e2e test. The manage
# environment lives in MGMT_DIR, and cleanup runs from teardown() so it also
# fires when an assert above fails (an explicit call as the last body line
# did not).
teardown() {
    rm -rf "$TEST_DIR" "${MGMT_DIR:-}"
    unset AWG_SKIP_APPLY
}

_client_allowed_ips() {
    sed -n '/^\[Peer\]/,$ s/^AllowedIPs[ \t]*=[ \t]*//p' "$AWG_DIR/${1}.conf"
}

# ---------------------------------------------------------------------------
# The validator: awg_validate_allowed_ips_list <value>
# ---------------------------------------------------------------------------

@test "allowed-ips validator: accepts v4 CIDR, v6 CIDR and mixed lists" {
    setup_params
    awg_validate_allowed_ips_list "0.0.0.0/0"
    awg_validate_allowed_ips_list "10.0.0.0/8, 192.168.0.0/16"
    awg_validate_allowed_ips_list "0.0.0.0/0, ::/0"
    awg_validate_allowed_ips_list "fd00::/8"
    awg_validate_allowed_ips_list "10.0.0.0/8,fdab::/48"
    # A bare IP without a prefix is a valid single-host route (modify contract)
    awg_validate_allowed_ips_list "1.2.3.4"
}

@test "allowed-ips validator: rejects shell metacharacters and empty input" {
    setup_params
    [ "$(type -t awg_validate_allowed_ips_list)" = "function" ]
    run ! awg_validate_allowed_ips_list ""
    run ! awg_validate_allowed_ips_list "10.0.0.0/8; rm -rf /"
    run ! awg_validate_allowed_ips_list "10.0.0.0/8'"
    run ! awg_validate_allowed_ips_list '10.0.0.0/8"'
    run ! awg_validate_allowed_ips_list '10.0.0.0/8\'
    run ! awg_validate_allowed_ips_list "$(printf '10.0.0.0/8\n192.168.0.0/16')"
}

@test "allowed-ips validator: rejects broken comma structure" {
    setup_params
    [ "$(type -t awg_validate_allowed_ips_list)" = "function" ]
    run ! awg_validate_allowed_ips_list "10.0.0.0/8,"
    run ! awg_validate_allowed_ips_list ",10.0.0.0/8"
    run ! awg_validate_allowed_ips_list "10.0.0.0/8,,192.168.0.0/16"
    run ! awg_validate_allowed_ips_list "10.0.0.0/8, ,192.168.0.0/16"
}

@test "allowed-ips validator: rejects non-CIDR tokens" {
    setup_params
    [ "$(type -t awg_validate_allowed_ips_list)" = "function" ]
    run ! awg_validate_allowed_ips_list "999.999.0.0/16"
    run ! awg_validate_allowed_ips_list "notacidr"
    run ! awg_validate_allowed_ips_list "10.0.0.0/33"
    run ! awg_validate_allowed_ips_list "fd00::/129"
}

@test "allowed-ips validator: RU/EN bodies are structurally identical (code lines)" {
    local ru en
    ru=$(awk '/^awg_validate_allowed_ips_list\(\)/,/^}/' "$BATS_TEST_DIRNAME/../awg_common.sh" | grep -vE '^[[:space:]]*(#|log |log_error |log_warn |die )')
    en=$(awk '/^awg_validate_allowed_ips_list\(\)/,/^}/' "$BATS_TEST_DIRNAME/../awg_common_en.sh" | grep -vE '^[[:space:]]*(#|log |log_error |log_warn |die )')
    [ -n "$ru" ]
    [ "$ru" = "$en" ]
}

# ---------------------------------------------------------------------------
# render_client_config: the CLIENT_ALLOWED_IPS override
# ---------------------------------------------------------------------------

@test "render: without CLIENT_ALLOWED_IPS keeps the global routing mode" {
    setup_params
    unset CLIENT_ALLOWED_IPS
    run render_client_config "glob" "10.9.9.5" "CLIENT_PRIV" "SERVER_PUB" "1.2.3.4" "39743"
    [ "$status" -eq 0 ]
    # create_init_config ships the split list '0.0.0.0/5, 8.0.0.0/7' -> as-is
    [ "$(_client_allowed_ips glob)" = "0.0.0.0/5, 8.0.0.0/7" ]
}

@test "render: CLIENT_ALLOWED_IPS split list replaces the global mode verbatim" {
    setup_params
    export CLIENT_ALLOWED_IPS="10.50.0.0/16, 10.60.0.0/16"
    run render_client_config "split" "10.9.9.5" "CLIENT_PRIV" "SERVER_PUB" "1.2.3.4" "39743"
    [ "$status" -eq 0 ]
    [ "$(_client_allowed_ips split)" = "10.50.0.0/16, 10.60.0.0/16" ]
    unset CLIENT_ALLOWED_IPS
}

@test "render: full-tunnel v4 override gets ::/0 appended (iOS rule)" {
    setup_params
    export CLIENT_ALLOWED_IPS="0.0.0.0/0"
    run render_client_config "fullv4" "10.9.9.5" "CLIENT_PRIV" "SERVER_PUB" "1.2.3.4" "39743"
    [ "$status" -eq 0 ]
    [ "$(_client_allowed_ips fullv4)" = "0.0.0.0/0, ::/0" ]
    unset CLIENT_ALLOWED_IPS
}

@test "render: full-tunnel v4 override does not get ::/0 when IPv6 is disabled" {
    setup_params
    export DISABLE_IPV6=1
    export CLIENT_ALLOWED_IPS="0.0.0.0/0"
    run render_client_config "fullv4_no_v6" "10.9.9.5" "CLIENT_PRIV" "SERVER_PUB" "1.2.3.4" "39743"
    [ "$status" -eq 0 ]
    [ "$(_client_allowed_ips fullv4_no_v6)" = "0.0.0.0/0" ]
    unset CLIENT_ALLOWED_IPS DISABLE_IPV6
}

@test "render: override that already carries ::/0 is written as-is" {
    setup_params
    export CLIENT_ALLOWED_IPS="0.0.0.0/0, ::/0"
    run render_client_config "fullboth" "10.9.9.5" "CLIENT_PRIV" "SERVER_PUB" "1.2.3.4" "39743"
    [ "$status" -eq 0 ]
    [ "$(_client_allowed_ips fullboth)" = "0.0.0.0/0, ::/0" ]
    unset CLIENT_ALLOWED_IPS
}

@test "render: dual-stack split override gets only the tunnel ULA appended" {
    setup_params
    export ALLOW_IPV6_TUNNEL=1
    export IPV6_SUBNET='fddd:2c4:2c4:2c4::/64'
    export SERVER_HAS_NATIVE_IPV6=0
    export CLIENT_ALLOWED_IPS="10.50.0.0/16"
    run render_client_config "dsplit" "10.9.9.5" "CLIENT_PRIV" "SERVER_PUB" "1.2.3.4" "39743" "fddd:2c4:2c4:2c4::9"
    [ "$status" -eq 0 ]
    [ "$(_client_allowed_ips dsplit)" = "10.50.0.0/16, fddd:2c4:2c4:2c4::/64" ]
    unset CLIENT_ALLOWED_IPS ALLOW_IPV6_TUNNEL IPV6_SUBNET SERVER_HAS_NATIVE_IPV6
}

@test "render: dual-stack full override mirrors into ::/0 on a native-IPv6 server" {
    setup_params
    export ALLOW_IPV6_TUNNEL=1
    export IPV6_SUBNET='fddd:2c4:2c4:2c4::/64'
    export SERVER_HAS_NATIVE_IPV6=1
    export CLIENT_ALLOWED_IPS="0.0.0.0/0"
    run render_client_config "dnative" "10.9.9.5" "CLIENT_PRIV" "SERVER_PUB" "1.2.3.4" "39743" "fddd:2c4:2c4:2c4::9"
    [ "$status" -eq 0 ]
    [ "$(_client_allowed_ips dnative)" = "0.0.0.0/0, ::/0" ]
    unset CLIENT_ALLOWED_IPS ALLOW_IPV6_TUNNEL IPV6_SUBNET SERVER_HAS_NATIVE_IPV6
}

@test "render: dual-stack override with explicit v6 tokens is written as-is" {
    # A user-supplied list that already manages both families is not mirrored
    # on top of itself: same rule regen applies to lists carrying an IPv6 part.
    setup_params
    export ALLOW_IPV6_TUNNEL=1
    export IPV6_SUBNET='fddd:2c4:2c4:2c4::/64'
    export SERVER_HAS_NATIVE_IPV6=1
    export CLIENT_ALLOWED_IPS="10.50.0.0/16, fdab::/48"
    run render_client_config "dv6" "10.9.9.5" "CLIENT_PRIV" "SERVER_PUB" "1.2.3.4" "39743" "fddd:2c4:2c4:2c4::9"
    [ "$status" -eq 0 ]
    [ "$(_client_allowed_ips dv6)" = "10.50.0.0/16, fdab::/48" ]
    unset CLIENT_ALLOWED_IPS ALLOW_IPV6_TUNNEL IPV6_SUBNET SERVER_HAS_NATIVE_IPV6
}

@test "render: global list with an IPv6 token still mirrors (hand-edited init, main behavior)" {
    # Review follow-up: awgsetup_cfg.init is hand-editable, and the global
    # ALLOWED_IPS may carry IPv6 tokens. The as-is gate must key on the
    # OVERRIDE only - the global list follows the mirror rules as before,
    # otherwise a dual-stack client silently loses its route to the tunnel
    # subnet (rc=0).
    setup_params
    sed 's/^export ALLOWED_IPS=.*/export ALLOWED_IPS='"'"'10.0.0.0\/8, fd00:dead::\/32'"'"'/' "$CONFIG_FILE" > "$CONFIG_FILE.new" && mv "$CONFIG_FILE.new" "$CONFIG_FILE"
    export ALLOW_IPV6_TUNNEL=1
    export IPV6_SUBNET='fddd:2c4:2c4:2c4::/64'
    export SERVER_HAS_NATIVE_IPV6=0
    unset CLIENT_ALLOWED_IPS
    run render_client_config "gv6" "10.9.9.5" "CLIENT_PRIV" "SERVER_PUB" "1.2.3.4" "39743" "fddd:2c4:2c4:2c4::9"
    unset ALLOW_IPV6_TUNNEL IPV6_SUBNET SERVER_HAS_NATIVE_IPV6
    [ "$status" -eq 0 ]
    # The tunnel ULA is appended to the hand-edited global list, as on main
    [ "$(_client_allowed_ips gv6)" = "10.0.0.0/8, fd00:dead::/32, fddd:2c4:2c4:2c4::/64" ]
}

@test "render: full-tunnel override with a foreign v6 token warns like regen does" {
    # Review follow-up: regen warns when it PRESERVES a full-tunnel list with
    # explicit v6 tokens but no ::/0 on a native-IPv6 server; add, which
    # CREATES such a list, must not be quieter than regen.
    setup_params
    export ALLOW_IPV6_TUNNEL=1
    export IPV6_SUBNET='fddd:2c4:2c4:2c4::/64'
    export SERVER_HAS_NATIVE_IPV6=1
    export CLIENT_ALLOWED_IPS="0.0.0.0/0, fdab:1::/48"
    _warns="$TEST_DIR/warns.txt"; export _warns
    # shellcheck disable=SC2317
    log_warn() { printf '%s\n' "$*" >> "$_warns"; }
    export -f log_warn
    run render_client_config "warn1" "10.9.9.5" "CLIENT_PRIV" "SERVER_PUB" "1.2.3.4" "39743" "fddd:2c4:2c4:2c4::9"
    [ "$status" -eq 0 ]
    [ "$(_client_allowed_ips warn1)" = "0.0.0.0/0, fdab:1::/48" ]
    # Separate asserts: bats does not reliably fail a compound `a && b` list
    [ -s "$_warns" ]
    grep -q "warn1" "$_warns"
    grep -q "::/0" "$_warns"
    unset CLIENT_ALLOWED_IPS ALLOW_IPV6_TUNNEL IPV6_SUBNET SERVER_HAS_NATIVE_IPV6 _warns
}

@test "render: as-is list already carrying ::/0 stays silent" {
    setup_params
    export ALLOW_IPV6_TUNNEL=1
    export IPV6_SUBNET='fddd:2c4:2c4:2c4::/64'
    export SERVER_HAS_NATIVE_IPV6=1
    export CLIENT_ALLOWED_IPS="0.0.0.0/0, ::/0"
    _warns="$TEST_DIR/warns2.txt"; export _warns
    # shellcheck disable=SC2317
    log_warn() { printf '%s\n' "$*" >> "$_warns"; }
    export -f log_warn
    run render_client_config "warn2" "10.9.9.5" "CLIENT_PRIV" "SERVER_PUB" "1.2.3.4" "39743" "fddd:2c4:2c4:2c4::9"
    [ "$status" -eq 0 ]
    [ "$(_client_allowed_ips warn2)" = "0.0.0.0/0, ::/0" ]
    [ ! -s "$_warns" ]
    unset CLIENT_ALLOWED_IPS ALLOW_IPV6_TUNNEL IPV6_SUBNET SERVER_HAS_NATIVE_IPV6 _warns
}

@test "allowed-ips gap predicate: RU/EN bodies are structurally identical (code lines)" {
    local ru en
    ru=$(awk '/^_aip_full_tunnel_v6_gap\(\)/,/^}/' "$BATS_TEST_DIRNAME/../awg_common.sh" | grep -vE '^[[:space:]]*(#|log |log_error |log_warn |die )')
    en=$(awk '/^_aip_full_tunnel_v6_gap\(\)/,/^}/' "$BATS_TEST_DIRNAME/../awg_common_en.sh" | grep -vE '^[[:space:]]*(#|log |log_error |log_warn |die )')
    [ -n "$ru" ]
    [ "$ru" = "$en" ]
}

@test "validator: a glob token stays a literal and is rejected (no pathname expansion)" {
    # Review follow-up: `for x in $value` expands globs, so with a file named
    # 10.0.0.0 in the cwd the value `10.0.0.*` validated as a real address
    # while the raw star reached the conf. The quoted read -a form must keep
    # the token literal and reject it.
    setup_params
    _errs="$TEST_DIR/errs.txt"; export _errs
    # shellcheck disable=SC2317
    log_error() { printf '%s\n' "$*" >> "$_errs"; }
    export -f log_error
    mkdir -p "$TEST_DIR/globtrap" && touch "$TEST_DIR/globtrap/10.0.0.0"
    _cwd="$PWD"
    cd "$TEST_DIR/globtrap" || skip "cd failed"
    run awg_validate_allowed_ips_list "10.0.0.*"
    _rc=$status _out="$output"
    cd "$_cwd" || true
    [ "$_rc" -ne 0 ]
    # The rejection message names the RAW token - proof it never expanded
    grep -q "10.0.0.\\*" "$_errs"
    unset _errs
}

# ---------------------------------------------------------------------------
# generate_client: env contract + defense-in-depth
# ---------------------------------------------------------------------------

@test "generate_client: invalid CLIENT_ALLOWED_IPS fails before any artifact" {
    setup_params
    export CLIENT_ALLOWED_IPS="bogus; injection"
    # shellcheck disable=SC2317
    get_server_public_ip() { echo "203.0.113.1"; return 0; }
    export -f get_server_public_ip
    run generate_client "noart"
    [ "$status" -ne 0 ]
    # No keys, no conf: validation must precede every side effect
    [ ! -e "$KEYS_DIR/noart.private" ]
    [ ! -e "$KEYS_DIR/noart.public" ]
    [ ! -e "$AWG_DIR/noart.conf" ]
    unset CLIENT_ALLOWED_IPS
}

@test "generate_client: valid CLIENT_ALLOWED_IPS lands in the created conf" {
    require_flock
    setup_params
    export CLIENT_ALLOWED_IPS="10.60.0.0/16"
    # shellcheck disable=SC2317
    get_server_public_ip() { echo "203.0.113.1"; return 0; }
    export -f get_server_public_ip
    run generate_client "withaip"
    [ "$status" -eq 0 ]
    [ "$(_client_allowed_ips withaip)" = "10.60.0.0/16" ]
    unset CLIENT_ALLOWED_IPS
}

@test "generate_client: unnormalized env value is canonicalized (D#38)" {
    require_flock
    setup_params
    export CLIENT_ALLOWED_IPS="10.60.0.0/16,10.61.0.0/16"
    # shellcheck disable=SC2317
    get_server_public_ip() { echo "203.0.113.1"; return 0; }
    export -f get_server_public_ip
    run generate_client "canon"
    [ "$status" -eq 0 ]
    [ "$(_client_allowed_ips canon)" = "10.60.0.0/16, 10.61.0.0/16" ]
    unset CLIENT_ALLOWED_IPS
}

# ---------------------------------------------------------------------------
# regenerate_client: hygiene against a leaked override
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

[Peer]
#_Name = ${name}
PublicKey = TESTPUBKEY
AllowedIPs = ${ipv4}/32
EOF
}

_setup_regen_stubs() {
    mock_awg
    mkdir -p "$KEYS_DIR"
    echo "SERVER_PUB" > "$AWG_DIR/server_public.key"
    # shellcheck disable=SC2317
    get_server_public_ip() { echo "203.0.113.1"; return 0; }
    # shellcheck disable=SC2317
    _ensure_server_public_key() { return 0; }
    # shellcheck disable=SC2317
    generate_qr() { return 0; }
    # shellcheck disable=SC2317
    generate_vpn_uri() { return 0; }
    # shellcheck disable=SC2317
    generate_qr_vpnuri() { return 0; }
    export -f get_server_public_ip _ensure_server_public_key generate_qr \
        generate_vpn_uri generate_qr_vpnuri
}

@test "regen: the client's own list wins over a leaked CLIENT_ALLOWED_IPS (restore path)" {
    # Review follow-up: this exercises the .conf restore path - with the
    # hygiene unset REMOVED it still passes, because plain regen restores the
    # client's own list anyway. The unset itself is pinned by the
    # --reset-routes test below, where render's value survives.
    require_flock
    _make_server_conf_with_peer "alice" "10.9.9.2"
    _setup_regen_stubs
    echo "ALICE_PRIV" > "$KEYS_DIR/alice.private"
    printf '[Interface]\nPrivateKey = ALICE_PRIV\nAddress = 10.9.9.2/32\nDNS = 1.1.1.1, 1.0.0.1\nMTU = 1280\nPersistentKeepalive = 33\n[Peer]\nPublicKey = SERVER_PUB\nEndpoint = 203.0.113.1:39743\nAllowedIPs = 10.77.0.0/16\n' \
        > "$AWG_DIR/alice.conf"
    export ALLOWED_IPS="0.0.0.0/0"
    export CLIENT_ALLOWED_IPS="10.99.0.0/16"
    unset AWG_REGEN_RESET_ROUTES
    # No CONFIG_FILE in this fixture -> load_awg_params keeps the env ALLOWED_IPS
    run regenerate_client "alice"
    unset CLIENT_ALLOWED_IPS
    [ "$status" -eq 0 ]
    # The client's own list is restored; the leaked override never appears
    [ "$(_client_allowed_ips alice)" = "10.77.0.0/16" ]
}

@test "regen --reset-routes: leaked override loses to the global mode" {
    require_flock
    _make_server_conf_with_peer "bob" "10.9.9.3"
    _setup_regen_stubs
    echo "BOB_PRIV" > "$KEYS_DIR/bob.private"
    printf '[Interface]\nPrivateKey = BOB_PRIV\nAddress = 10.9.9.3/32\nDNS = 1.1.1.1, 1.0.0.1\nMTU = 1280\nPersistentKeepalive = 33\n[Peer]\nPublicKey = SERVER_PUB\nEndpoint = 203.0.113.1:39743\nAllowedIPs = 10.77.0.0/16\n' \
        > "$AWG_DIR/bob.conf"
    export ALLOWED_IPS="0.0.0.0/0"
    export CLIENT_ALLOWED_IPS="10.99.0.0/16"
    export AWG_REGEN_RESET_ROUTES=1
    run regenerate_client "bob"
    unset CLIENT_ALLOWED_IPS AWG_REGEN_RESET_ROUTES
    [ "$status" -eq 0 ]
    # --reset-routes keeps the freshly rendered global mode (full tunnel + ::/0)
    [ "$(_client_allowed_ips bob)" = "0.0.0.0/0, ::/0" ]
}

# ---------------------------------------------------------------------------
# manage CLI: --allowed-ips flag
# ---------------------------------------------------------------------------

@test "manage: RU/EN parse --allowed-ips into CLI_ADD_ALLOWED_IPS" {
    local MANAGE_RU="${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"
    local MANAGE_EN="${BATS_TEST_DIRNAME}/../manage_amneziawg_en.sh"
    for f in "$MANAGE_RU" "$MANAGE_EN"; do
        grep -qE -- '--allowed-ips=\*\)[[:space:]]+CLI_ADD_ALLOWED_IPS=' "$f"
        grep -qE 'export CLIENT_ALLOWED_IPS=' "$f"
        # Hygiene next to the CLIENT_PSK unset: the override must not leak
        grep -qE 'unset CLIENT_ALLOWED_IPS' "$f"
    done
}

@test "manage: help mentions --allowed-ips in RU and EN" {
    # Review follow-up: a whole-file grep was satisfied by the parser line
    # alone - assert the actual help output instead.
    local out
    out=$(bash "${BATS_TEST_DIRNAME}/../manage_amneziawg.sh" help)
    [[ "$out" == *"--allowed-ips"* ]]
    out=$(bash "${BATS_TEST_DIRNAME}/../manage_amneziawg_en.sh" help)
    [[ "$out" == *"--allowed-ips"* ]]
}

@test "manage e2e: add --allowed-ips writes the list into the client conf" {
    require_flock
    setup_manage_env
    local SCRIPT="$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    run --separate-stderr bash "$SCRIPT" add alice \
        --allowed-ips="10.0.0.0/8,192.168.0.0/16" --json --yes \
        --conf-dir="$MGMT_DIR/awg" --server-conf="$MGMT_DIR/awg/awg0.conf"
    # Unnormalized input lands canonical ("a, b"), split list stays split
    [ "$status" -eq 0 ]
    [ "$(sed -n 's/^AllowedIPs = //p' "$MGMT_DIR/awg/alice.conf")" = "10.0.0.0/8, 192.168.0.0/16" ]
    teardown_manage_env
}

@test "manage e2e: --allowed-ips applies to every name in the batch" {
    require_flock
    setup_manage_env
    local SCRIPT="$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    run --separate-stderr bash "$SCRIPT" add b1 b2 \
        --allowed-ips="10.50.0.0/16" --json --yes \
        --conf-dir="$MGMT_DIR/awg" --server-conf="$MGMT_DIR/awg/awg0.conf"
    [ "$status" -eq 0 ]
    [ "$(sed -n 's/^AllowedIPs = //p' "$MGMT_DIR/awg/b1.conf")" = "10.50.0.0/16" ]
    [ "$(sed -n 's/^AllowedIPs = //p' "$MGMT_DIR/awg/b2.conf")" = "10.50.0.0/16" ]
    teardown_manage_env
}

@test "manage e2e: invalid --allowed-ips dies before creating any client" {
    require_flock
    setup_manage_env
    local SCRIPT="$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    run --separate-stderr bash "$SCRIPT" add carol --allowed-ips="10.0.0.0/999" --json --yes \
        --conf-dir="$MGMT_DIR/awg" --server-conf="$MGMT_DIR/awg/awg0.conf"
    local rc=$status
    # shellcheck disable=SC2154  # $stderr is provided by bats `run --separate-stderr`
    local err="$stderr"
    [ "$rc" -ne 0 ]
    [ ! -e "$MGMT_DIR/awg/carol.conf" ]
    # Review follow-up: '*--allowed-ips*' also matched the SUCCESS info line
    # of a valid run; the early die has a message of its own - match it, so
    # the test tells the early validation apart from generate_client's
    # defense-in-depth fallback.
    [[ "$err" == *"Некорректный --allowed-ips="* ]]
    teardown_manage_env
}

@test "manage e2e: trailing comma in --allowed-ips is rejected" {
    require_flock
    setup_manage_env
    local SCRIPT="$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    run --separate-stderr bash "$SCRIPT" add dan --allowed-ips="10.0.0.0/8," --json --yes \
        --conf-dir="$MGMT_DIR/awg" --server-conf="$MGMT_DIR/awg/awg0.conf"
    [ "$status" -ne 0 ]
    [ ! -e "$MGMT_DIR/awg/dan.conf" ]
    teardown_manage_env
}

@test "manage e2e: empty --allowed-ips= refuses instead of widening routes" {
    # Review follow-up: an empty value must not silently fall back to the
    # server-wide mode - a bot with an empty variable would hand out WIDER
    # routes with ok:true. Fail closed, like any other invalid value.
    require_flock
    setup_manage_env
    local SCRIPT="$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    run --separate-stderr bash "$SCRIPT" add ghost --allowed-ips= --json --yes \
        --conf-dir="$MGMT_DIR/awg" --server-conf="$MGMT_DIR/awg/awg0.conf"
    [ "$status" -ne 0 ]
    [ ! -e "$MGMT_DIR/awg/ghost.conf" ]
    teardown_manage_env
}

@test "manage e2e: invalid --allowed-ips on a batch creates NO client at all" {
    # Review follow-up: the early die must fire before the FIRST client,
    # not at the first per-client failure - pin the "created nothing" half
    # of the promise, single-name tests cannot tell the two apart.
    require_flock
    setup_manage_env
    local SCRIPT="$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    run --separate-stderr bash "$SCRIPT" add m1 m2 --allowed-ips="not-a-cidr" --json --yes \
        --conf-dir="$MGMT_DIR/awg" --server-conf="$MGMT_DIR/awg/awg0.conf"
    [ "$status" -ne 0 ]
    [ ! -e "$MGMT_DIR/awg/m1.conf" ]
    [ ! -e "$MGMT_DIR/awg/m2.conf" ]
    teardown_manage_env
}

@test "manage e2e: add without --allowed-ips still uses the global mode" {
    require_flock
    setup_manage_env
    local SCRIPT="$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    run --separate-stderr bash "$SCRIPT" add eve --json --yes \
        --conf-dir="$MGMT_DIR/awg" --server-conf="$MGMT_DIR/awg/awg0.conf"
    [ "$status" -eq 0 ]
    # The harness init config is full tunnel (mode 1) -> iOS ::/0 pair
    [ "$(sed -n 's/^AllowedIPs = //p' "$MGMT_DIR/awg/eve.conf")" = "0.0.0.0/0, ::/0" ]
    teardown_manage_env
}

@test "manage e2e EN: add --allowed-ips works in the English script too" {
    require_flock
    setup_manage_env
    cp "$BATS_TEST_DIRNAME/../awg_common_en.sh" "$MGMT_DIR/awg/awg_common.sh"
    local SCRIPT="$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
    run --separate-stderr bash "$SCRIPT" add fenrir --allowed-ips="10.50.0.0/16" --json --yes \
        --conf-dir="$MGMT_DIR/awg" --server-conf="$MGMT_DIR/awg/awg0.conf"
    [ "$status" -eq 0 ]
    [ "$(sed -n 's/^AllowedIPs = //p' "$MGMT_DIR/awg/fenrir.conf")" = "10.50.0.0/16" ]
    teardown_manage_env
}

# ---------------------------------------------------------------------------
# Maintainer follow-up (Issue #253 comment):
#   (A) modify reuses the shared validator instead of an inline copy
#   (B) add --json reports the APPLIED AllowedIPs in results[]
# ---------------------------------------------------------------------------

@test "modify: RU/EN call the shared validator, no inline copy left" {
    # Review follow-up: `! cmd` inside a for-loop made the LAST iteration the
    # test status, so a copy returning to the Russian file passed unnoticed,
    # and grepping the raw body tripped on comments mentioning _valid_cidr.
    # Explicit if/fail per file (bats `run !` does not take pipelines),
    # code lines only.
    local MANAGE_RU="${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"
    local MANAGE_EN="${BATS_TEST_DIRNAME}/../manage_amneziawg_en.sh"
    local f body
    for f in "$MANAGE_RU" "$MANAGE_EN"; do
        body=$(awk '/^modify_client\(\)/,/^}/' "$f" | grep -vE '^[[:space:]]*#')
        [ -n "$body" ]
        printf '%s' "$body" | grep -q 'awg_validate_allowed_ips_list "\$value" || return 1' \
            || { echo "modify does not delegate to the shared validator: $f"; false; }
        if printf '%s' "$body" | grep -q '_valid_cidr'; then
            echo "inline _valid_cidr copy left in modify: $f"
            false
        fi
    done
}

@test "modify e2e: invalid AllowedIPs value is rejected through the shared validator" {
    require_flock
    setup_manage_env
    local SCRIPT="$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    run --separate-stderr bash "$SCRIPT" add gina --json --yes \
        --conf-dir="$MGMT_DIR/awg" --server-conf="$MGMT_DIR/awg/awg0.conf"
    [ "$status" -eq 0 ]
    # Invalid list must die in validation, BEFORE any sed touches the conf
    # (validation precedes the lock and the backup), so this also works
    # where sed -i is unavailable.
    run --separate-stderr bash "$SCRIPT" modify gina AllowedIPs "10.0.0.0/999" --json --yes \
        --conf-dir="$MGMT_DIR/awg" --server-conf="$MGMT_DIR/awg/awg0.conf"
    [ "$status" -ne 0 ]
    # The untouched conf still carries the routes add wrote
    [ "$(sed -n 's/^AllowedIPs = //p' "$MGMT_DIR/awg/gina.conf")" = "0.0.0.0/0, ::/0" ]
    teardown_manage_env
}

@test "add --json: results[] reports the applied AllowedIPs (override)" {
    require_flock
    command -v jq &>/dev/null || skip "jq not available"
    setup_manage_env
    local SCRIPT="$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    run --separate-stderr bash "$SCRIPT" add hilda --allowed-ips="10.0.0.0/8,192.168.0.0/16" --json --yes \
        --conf-dir="$MGMT_DIR/awg" --server-conf="$MGMT_DIR/awg/awg0.conf"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.results[0].allowed_ips')" = "10.0.0.0/8, 192.168.0.0/16" ]
    teardown_manage_env
}

@test "add --json: results[] reports the applied AllowedIPs (global mode, with ::/0)" {
    require_flock
    command -v jq &>/dev/null || skip "jq not available"
    setup_manage_env
    local SCRIPT="$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    run --separate-stderr bash "$SCRIPT" add ivar --json --yes \
        --conf-dir="$MGMT_DIR/awg" --server-conf="$MGMT_DIR/awg/awg0.conf"
    [ "$status" -eq 0 ]
    # Applied value comes from the conf: full tunnel mirrors into ::/0 (iOS rule)
    [ "$(printf '%s' "$output" | jq -r '.results[0].allowed_ips')" = "0.0.0.0/0, ::/0" ]
    teardown_manage_env
}

@test "add --json EN: results[] carries the same allowed_ips field" {
    require_flock
    command -v jq &>/dev/null || skip "jq not available"
    setup_manage_env
    cp "$BATS_TEST_DIRNAME/../awg_common_en.sh" "$MGMT_DIR/awg/awg_common.sh"
    local SCRIPT="$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
    run --separate-stderr bash "$SCRIPT" add jarl --allowed-ips="10.50.0.0/16" --json --yes \
        --conf-dir="$MGMT_DIR/awg" --server-conf="$MGMT_DIR/awg/awg0.conf"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.results[0].allowed_ips')" = "10.50.0.0/16" ]
    teardown_manage_env
}
