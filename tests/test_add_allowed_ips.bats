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
    TEST_DIR=$(mktemp -d)
    mkdir -p "$TEST_DIR/bin" "$TEST_DIR/awg/keys"
    cat > "$TEST_DIR/bin/awg" << 'STUB'
#!/bin/bash
case "$1" in
    genkey|genpsk) echo "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ;;
    pubkey) cat >/dev/null; echo "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=" ;;
    *) exit 0 ;;
esac
STUB
    chmod +x "$TEST_DIR/bin/awg"
    export PATH="$TEST_DIR/bin:$PATH"
    cp "$BATS_TEST_DIRNAME/../awg_common.sh" "$TEST_DIR/awg/awg_common.sh"
    cat > "$TEST_DIR/awg/awgsetup_cfg.init" << 'CONF'
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
    cat > "$TEST_DIR/awg/awg0.conf" << 'CONF'
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
    rm -rf "$TEST_DIR"
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

@test "regen: a leaked CLIENT_ALLOWED_IPS never reaches the rendered conf" {
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
    local MANAGE_RU="${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"
    local MANAGE_EN="${BATS_TEST_DIRNAME}/../manage_amneziawg_en.sh"
    grep -q -- '--allowed-ips' "$MANAGE_RU"
    grep -q -- '--allowed-ips' "$MANAGE_EN"
}

@test "manage e2e: add --allowed-ips writes the list into the client conf" {
    require_flock
    setup_manage_env
    local SCRIPT="$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    run --separate-stderr bash "$SCRIPT" add alice \
        --allowed-ips="10.0.0.0/8,192.168.0.0/16" --json --yes \
        --conf-dir="$TEST_DIR/awg" --server-conf="$TEST_DIR/awg/awg0.conf"
    # Unnormalized input lands canonical ("a, b"), split list stays split
    [ "$status" -eq 0 ]
    [ "$(sed -n 's/^AllowedIPs = //p' "$TEST_DIR/awg/alice.conf")" = "10.0.0.0/8, 192.168.0.0/16" ]
    teardown_manage_env
}

@test "manage e2e: --allowed-ips applies to every name in the batch" {
    require_flock
    setup_manage_env
    local SCRIPT="$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    run --separate-stderr bash "$SCRIPT" add b1 b2 \
        --allowed-ips="10.50.0.0/16" --json --yes \
        --conf-dir="$TEST_DIR/awg" --server-conf="$TEST_DIR/awg/awg0.conf"
    [ "$status" -eq 0 ]
    [ "$(sed -n 's/^AllowedIPs = //p' "$TEST_DIR/awg/b1.conf")" = "10.50.0.0/16" ]
    [ "$(sed -n 's/^AllowedIPs = //p' "$TEST_DIR/awg/b2.conf")" = "10.50.0.0/16" ]
    teardown_manage_env
}

@test "manage e2e: invalid --allowed-ips dies before creating any client" {
    require_flock
    setup_manage_env
    local SCRIPT="$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    run --separate-stderr bash "$SCRIPT" add carol --allowed-ips="10.0.0.0/999" --json --yes \
        --conf-dir="$TEST_DIR/awg" --server-conf="$TEST_DIR/awg/awg0.conf"
    local rc=$status
    local err="$stderr"
    [ "$rc" -ne 0 ]
    [ ! -e "$TEST_DIR/awg/carol.conf" ]
    [[ "$err" == *'--allowed-ips'* ]]
    teardown_manage_env
}

@test "manage e2e: trailing comma in --allowed-ips is rejected" {
    require_flock
    setup_manage_env
    local SCRIPT="$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    run --separate-stderr bash "$SCRIPT" add dan --allowed-ips="10.0.0.0/8," --json --yes \
        --conf-dir="$TEST_DIR/awg" --server-conf="$TEST_DIR/awg/awg0.conf"
    [ "$status" -ne 0 ]
    [ ! -e "$TEST_DIR/awg/dan.conf" ]
    teardown_manage_env
}

@test "manage e2e: add without --allowed-ips still uses the global mode" {
    require_flock
    setup_manage_env
    local SCRIPT="$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    run --separate-stderr bash "$SCRIPT" add eve --json --yes \
        --conf-dir="$TEST_DIR/awg" --server-conf="$TEST_DIR/awg/awg0.conf"
    [ "$status" -eq 0 ]
    # The harness init config is full tunnel (mode 1) -> iOS ::/0 pair
    [ "$(sed -n 's/^AllowedIPs = //p' "$TEST_DIR/awg/eve.conf")" = "0.0.0.0/0, ::/0" ]
    teardown_manage_env
}

@test "manage e2e EN: add --allowed-ips works in the English script too" {
    require_flock
    setup_manage_env
    cp "$BATS_TEST_DIRNAME/../awg_common_en.sh" "$TEST_DIR/awg/awg_common.sh"
    local SCRIPT="$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
    run --separate-stderr bash "$SCRIPT" add fenrir --allowed-ips="10.50.0.0/16" --json --yes \
        --conf-dir="$TEST_DIR/awg" --server-conf="$TEST_DIR/awg/awg0.conf"
    [ "$status" -eq 0 ]
    [ "$(sed -n 's/^AllowedIPs = //p' "$TEST_DIR/awg/fenrir.conf")" = "10.50.0.0/16" ]
    teardown_manage_env
}

# ---------------------------------------------------------------------------
# Maintainer follow-up (Issue #253 comment):
#   (A) modify reuses the shared validator instead of an inline copy
#   (B) add --json reports the APPLIED AllowedIPs in results[]
# ---------------------------------------------------------------------------

@test "modify: RU/EN call the shared validator, no inline copy left" {
    local MANAGE_RU="${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"
    local MANAGE_EN="${BATS_TEST_DIRNAME}/../manage_amneziawg_en.sh"
    for f in "$MANAGE_RU" "$MANAGE_EN"; do
        local body
        body=$(awk '/^modify_client\(\)/,/^}/' "$f")
        [ -n "$body" ]
        # The AllowedIPs arm delegates to the library helper...
        printf '%s' "$body" | grep -q 'awg_validate_allowed_ips_list "\$value" || return 1'
        # ...and the inline per-token copy is gone (single source of truth)
        ! printf '%s' "$body" | grep -q '_valid_cidr'
    done
}

@test "modify e2e: invalid AllowedIPs value is rejected through the shared validator" {
    require_flock
    setup_manage_env
    local SCRIPT="$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    run --separate-stderr bash "$SCRIPT" add gina --json --yes \
        --conf-dir="$TEST_DIR/awg" --server-conf="$TEST_DIR/awg/awg0.conf"
    [ "$status" -eq 0 ]
    # Invalid list must die in validation, BEFORE any sed touches the conf
    # (validation precedes the lock and the backup), so this also works
    # where sed -i is unavailable.
    run --separate-stderr bash "$SCRIPT" modify gina AllowedIPs "10.0.0.0/999" --json --yes \
        --conf-dir="$TEST_DIR/awg" --server-conf="$TEST_DIR/awg/awg0.conf"
    [ "$status" -ne 0 ]
    # The untouched conf still carries the routes add wrote
    [ "$(sed -n 's/^AllowedIPs = //p' "$TEST_DIR/awg/gina.conf")" = "0.0.0.0/0, ::/0" ]
    teardown_manage_env
}

@test "add --json: results[] reports the applied AllowedIPs (override)" {
    require_flock
    command -v jq &>/dev/null || skip "jq not available"
    setup_manage_env
    local SCRIPT="$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    run --separate-stderr bash "$SCRIPT" add hilda --allowed-ips="10.0.0.0/8,192.168.0.0/16" --json --yes \
        --conf-dir="$TEST_DIR/awg" --server-conf="$TEST_DIR/awg/awg0.conf"
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
        --conf-dir="$TEST_DIR/awg" --server-conf="$TEST_DIR/awg/awg0.conf"
    [ "$status" -eq 0 ]
    # Applied value comes from the conf: full tunnel mirrors into ::/0 (iOS rule)
    [ "$(printf '%s' "$output" | jq -r '.results[0].allowed_ips')" = "0.0.0.0/0, ::/0" ]
    teardown_manage_env
}

@test "add --json EN: results[] carries the same allowed_ips field" {
    require_flock
    command -v jq &>/dev/null || skip "jq not available"
    setup_manage_env
    cp "$BATS_TEST_DIRNAME/../awg_common_en.sh" "$TEST_DIR/awg/awg_common.sh"
    local SCRIPT="$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
    run --separate-stderr bash "$SCRIPT" add jarl --allowed-ips="10.50.0.0/16" --json --yes \
        --conf-dir="$TEST_DIR/awg" --server-conf="$TEST_DIR/awg/awg0.conf"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.results[0].allowed_ips')" = "10.50.0.0/16" ]
    teardown_manage_env
}
