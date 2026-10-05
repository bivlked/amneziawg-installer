#!/usr/bin/env bats
# The server address out of client AllowedIPs (routing modes 2 and 3).
#
# Linux awg-quick sets up fwmark policy routing only for 0.0.0.0/0. With a list
# that covers the server's own public address, encrypted packets to the
# endpoint are routed into the tunnel itself: the handshake goes through (the
# first packet leaves before the routes), then rx freezes and tx explodes
# (ENOBUFS). App clients add a host route themselves, Linux does not. The
# generated list therefore carries a hole for the endpoint: every route that
# covers it is replaced by its complement around that one address.
#
# shellcheck disable=SC2154  # Variables set by sourced scripts at runtime

load test_helper

# A bare `! cmd` does not fail a bats test (errexit ignores it): every negation
# below carries `|| return 1`.

mode2_list() {
    sed -n 's/^[[:space:]]*ALLOWED_IPS="\(1\.0\.0\.0\/8,.*\)"$/\1/p' \
        "${BATS_TEST_DIRNAME}/../install_amneziawg.sh" | head -1
}

# covers <list> <ipv4> : 0 if some IPv4 route of the list contains the address
covers() {
    local tok b e lo hi
    e=$(_ipv4_to_int "$2")
    while IFS= read -r tok; do
        [[ "$tok" == *:* ]] && continue
        [[ "$tok" == */* ]] || tok="$tok/32"
        b=$(_cidr_bounds "$tok") || return 2
        lo=${b% *}; hi=${b#* }
        (( e >= lo && e <= hi )) && return 0
    done < <(_aip_tokens "$1")
    return 1
}

# size <list> : number of IPv4 addresses the routes cover (routes do not overlap here)
size() {
    local tok b n=0
    while IFS= read -r tok; do
        [[ "$tok" == *:* ]] && continue
        b=$(_cidr_bounds "$tok")
        n=$(( n + ${b#* } - ${b% *} + 1 ))
    done < <(_aip_tokens "$1")
    echo "$n"
}

EP=150.241.230.21

# --- the carve itself ---

@test "carve: the route holding the endpoint becomes its complement, one address smaller" {
    out=$(_aip_carve_endpoints "128.0.0.0/3" "$EP")
    [ "$(_aip_tokens "$out" | wc -l)" -eq 29 ]
    ! covers "$out" "$EP" || return 1
    [ "$(size "$out")" -eq $(( (1 << 29) - 1 )) ]
    covers "$out" 150.241.230.20
    covers "$out" 150.241.230.22
    covers "$out" 128.0.0.0
    covers "$out" 159.255.255.255
}

@test "carve: routes that do not hold the endpoint keep their place and spelling" {
    out=$(_aip_carve_endpoints "1.0.0.0/8, 128.0.0.0/3, 8.8.8.8/32" "$EP")
    [[ "$out" == "1.0.0.0/8, "* ]]
    [[ "$out" == *", 8.8.8.8/32" ]]
    ! covers "$out" "$EP" || return 1
}

@test "carve: every route holding the endpoint is cut, a duplicate /32 included" {
    out=$(_aip_carve_endpoints "128.0.0.0/3, 150.241.230.0/24, $EP/32, $EP" "$EP")
    ! covers "$out" "$EP" || return 1
    ! _aip_has_token "$out" "$EP/32" || return 1
    ! _aip_has_token "$out" "$EP" || return 1
}

@test "carve: 0.0.0.0/0 is left alone, a narrower route next to it is still cut" {
    out=$(_aip_carve_endpoints "0.0.0.0/0, 150.241.0.0/16, ::/0" "$EP")
    _aip_has_token "$out" "0.0.0.0/0"
    _aip_has_token "$out" "::/0"
    ! _aip_has_token "$out" "150.241.0.0/16" || return 1
    run _aip_carve_endpoints "0.0.0.0/0, ::/0" "$EP"
    [ "$output" = "0.0.0.0/0, ::/0" ]
}

@test "carve: a name or an IPv6 endpoint cuts nothing" {
    for ep in vpn.example.com "[2001:db8::1]" "2001:db8::1" ""; do
        run _aip_carve_endpoints "128.0.0.0/3, 2000::/3" "$ep"
        [ "$output" = "128.0.0.0/3, 2000::/3" ] || { echo "ep=$ep: $output"; return 1; }
    done
}

@test "carve: IPv6 routes stay where they were" {
    out=$(_aip_carve_endpoints "fddd:2c4:2c4:2c4::/64, 128.0.0.0/3, 2000::/3" "$EP")
    [[ "$out" == "fddd:2c4:2c4:2c4::/64, "* ]]
    [[ "$out" == *", 2000::/3" ]]
}

@test "carve: idempotent, and the result does not depend on the order of two endpoints" {
    once=$(_aip_carve_endpoints "$(mode2_list)" "$EP")
    twice=$(_aip_carve_endpoints "$once" "$EP")
    [ "$once" = "$twice" ]
    ab=$(_aip_carve_endpoints "$(mode2_list)" "$EP" 150.241.230.99 | tr -d ' ' | tr ',' '\n' | sort)
    ba=$(_aip_carve_endpoints "$(mode2_list)" 150.241.230.99 "$EP" | tr -d ' ' | tr ',' '\n' | sort)
    [ -n "$ab" ] && [ "$ab" = "$ba" ]
}

@test "carve: a non-canonical route is cut by its real bounds" {
    out=$(_aip_carve_endpoints "150.241.230.77/24" "$EP")
    ! covers "$out" "$EP" || return 1
    [ "$(size "$out")" -eq 255 ]
}

@test "carve: a list made of the endpoint alone comes out empty" {
    run _aip_carve_endpoints "$EP/32" "$EP"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "endpoint: only an IPv4 literal is returned, with or without a port" {
    [ "$(_aip_endpoint_v4 "$EP")" = "$EP" ]
    [ "$(_aip_endpoint_v4 "$EP:39743")" = "$EP" ]
    [ -z "$(_aip_endpoint_v4 "vpn.example.com:39743")" ]
    [ -z "$(_aip_endpoint_v4 "[2001:db8::1]:39743")" ]
    [ -z "$(_aip_endpoint_v4 "300.1.1.1")" ]
    [ -z "$(_aip_endpoint_v4 "")" ]
}

# --- the full-tunnel predicate with a known endpoint ---

@test "full tunnel: the mode-2 list with the endpoint cut is full only when the endpoint is named" {
    cut=$(_aip_carve_endpoints "$(mode2_list)" "$EP")
    ! _is_full_tunnel "$cut" || return 1
    _AWG_CARVE_EPS="$EP" _is_full_tunnel "$cut"
}

@test "full tunnel: naming the endpoint does not excuse any other hole" {
    cut=$(_aip_carve_endpoints "$(mode2_list)" "$EP" 150.241.230.99)
    ! _AWG_CARVE_EPS="$EP" _is_full_tunnel "$cut" || return 1
    _AWG_CARVE_EPS="$EP 150.241.230.99" _is_full_tunnel "$cut"
}

@test "same set: a cut client list equals the server list once both are cut by the same endpoint" {
    cut=$(_aip_carve_endpoints "$(mode2_list)" "$EP")
    ! _aip_same_set "$cut" "$(mode2_list)" || return 1
    _AWG_CARVE_EPS="$EP" _aip_same_set "$cut" "$(mode2_list)"
}

# --- render: the generated config ---

setup_list() {   # setup_list <ALLOWED_IPS> <mode>
    create_server_config
    create_init_config
    sed -i "s|^export ALLOWED_IPS=.*|export ALLOWED_IPS='$1'|" "$CONFIG_FILE"
    sed -i "/^export ALLOWED_IPS_MODE=/d" "$CONFIG_FILE"
    echo "export ALLOWED_IPS_MODE=$2" >> "$CONFIG_FILE"
    safe_load_config "$CONFIG_FILE"
}

aips_of() { sed -n 's/^AllowedIPs = //p' "$AWG_DIR/$1.conf"; }

@test "render: mode 2 with an IPv4 endpoint keeps the endpoint out and keeps 2000::/3" {
    setup_list "$(mode2_list)" 2
    render_client_config c2 10.9.9.2 FAKEPRIV FAKEPUB "$EP" 39743
    a=$(aips_of c2)
    ! covers "$a" "$EP" || return 1
    [[ "$a" == *", 2000::/3" ]]
    grep -q "^Endpoint = $EP:39743$" "$AWG_DIR/c2.conf"
}

@test "render: a mode-3 list that covers the endpoint loses only that address" {
    setup_list "150.241.0.0/16, 10.0.0.0/8" 3
    render_client_config c3 10.9.9.3 FAKEPRIV FAKEPUB "$EP" 39743
    a=$(aips_of c3)
    ! covers "$a" "$EP" || return 1
    covers "$a" 150.241.0.1
    _aip_has_token "$a" "10.0.0.0/8"
}

@test "render: mode 1 output is unchanged" {
    setup_list "0.0.0.0/0" 1
    render_client_config c1 10.9.9.4 FAKEPRIV FAKEPUB "$EP" 39743
    [ "$(aips_of c1)" = "0.0.0.0/0, ::/0" ]
}

@test "render: a name as the endpoint leaves the list as it was" {
    setup_list "$(mode2_list)" 2
    render_client_config cn 10.9.9.5 FAKEPRIV FAKEPUB vpn.example.com 39743
    [[ "$(aips_of cn)" == "$(mode2_list), 2000::/3" ]]
}

@test "render: a list of the server address alone is refused before any config is written" {
    setup_list "$EP/32" 3
    run render_client_config ce 10.9.9.6 FAKEPRIV FAKEPUB "$EP" 39743
    [ "$status" -ne 0 ]
    [ ! -e "$AWG_DIR/ce.conf" ]
}

@test "render: mode 2 with a cut endpoint keeps the IPv6 sink address next to 2000::/3" {
    setup_list "$(mode2_list)" 2
    render_client_config cs 10.9.9.7 FAKEPRIV FAKEPUB "$EP" 39743
    grep -q "^Address = 10.9.9.7/32, fddd:2c4:2c4:ffff::" "$AWG_DIR/cs.conf" || { cat "$AWG_DIR/cs.conf"; return 1; }
}

@test "render: a dual-stack list of the server address alone is refused, not written IPv6-only" {
    setup_list "$EP/32" 3
    cat >> "$CONFIG_FILE" << 'CONF'
export ALLOW_IPV6_TUNNEL=1
export IPV6_SUBNET='fddd:2c4:2c4:2c4::/64'
CONF
    safe_load_config "$CONFIG_FILE"
    run render_client_config cd 10.9.9.8 FAKEPRIV FAKEPUB "$EP" 39743 fddd:2c4:2c4:2c4::8
    [ "$status" -ne 0 ]
    [ ! -e "$AWG_DIR/cd.conf" ]
}

@test "render: a name as the endpoint with a route list warns once that Linux needs a manual route" {
    setup_list "$(mode2_list)" 2
    WL="$TEST_DIR/w.log"; : > "$WL"
    log_warn() { echo "WARN: $*" >> "$WL"; }
    render_client_config cw 10.9.9.9 FAKEPRIV FAKEPUB vpn.example.com 39743
    [ "$(grep -c 'WARN:.*Endpoint' "$WL")" -eq 1 ] || { cat "$WL"; return 1; }
    : > "$WL"
    setup_list "0.0.0.0/0" 1
    log_warn() { echo "WARN: $*" >> "$WL"; }
    render_client_config cw1 10.9.9.10 FAKEPRIV FAKEPUB vpn.example.com 39743
    ! grep -q 'WARN:.*Endpoint' "$WL" || { echo "mode 1 warned"; cat "$WL"; return 1; }
}

# --- regen: clients issued before the fix are cured, the server-list rules keep working ---

# setup_regen_ep <name> <ip> <client AllowedIPs> <Endpoint in the client conf> <server endpoint now> [init extra]
setup_regen_ep() {
    create_server_config
    create_init_config
    sed -i "s|^export ALLOWED_IPS=.*|export ALLOWED_IPS='$(mode2_list)'|" "$CONFIG_FILE"
    [ -n "${6:-}" ] && printf '%s\n' "$6" >> "$CONFIG_FILE"
    add_test_peer "$1" "$2"
    printf 'FAKEPRIV' > "$KEYS_DIR/$1.private"
    printf 'FAKESERVERPUB' > "$AWG_DIR/server_public.key"
    cat > "$AWG_DIR/$1.conf" << EOF
[Interface]
PrivateKey = FAKEPRIV
Address = $2/32
DNS = 1.1.1.1, 1.0.0.1
MTU = 1280

[Peer]
PublicKey = FAKESERVERPUB
Endpoint = $4:39743
AllowedIPs = $3
PersistentKeepalive = 33
EOF
    SRV_EP_NOW="$5"
    get_server_public_ip() { echo "$SRV_EP_NOW"; }
    _ensure_server_public_key() { return 0; }
    generate_qr()        { return 0; }
    generate_vpn_uri()   { return 0; }
    generate_qr_vpnuri() { return 0; }
    WARN_LOG="$TEST_DIR/warn.log"; : > "$WARN_LOG"
    log_warn()  { echo "WARN: $*" >> "$WARN_LOG"; }
    log_error() { echo "ERR: $*" >> "$WARN_LOG"; }
    export -f get_server_public_ip _ensure_server_public_key generate_qr generate_vpn_uri generate_qr_vpnuri log_warn log_error
    export SRV_EP_NOW WARN_LOG
}

@test "regen: a mode-2 client issued before the fix gets the hole and 2000::/3, without a warning" {
    require_flock
    setup_regen_ep old 10.9.9.10 "$(mode2_list)" "$EP" "$EP"
    run regenerate_client old
    [ "$status" -eq 0 ] || { echo "$output"; cat "$WARN_LOG"; return 1; }
    a=$(aips_of old)
    ! covers "$a" "$EP" || return 1
    [[ "$a" == *", 2000::/3" ]]
    ! grep -q 'WARN' "$WARN_LOG" || { cat "$WARN_LOG"; return 1; }
    # twice is idempotent
    run regenerate_client old
    [ "$status" -eq 0 ]
    [ "$(aips_of old)" = "$a" ]
}

@test "regen: an old ::/0 next to the server list is still migrated to 2000::/3, with the hole" {
    require_flock
    setup_regen_ep leg 10.9.9.11 "$(mode2_list), ::/0" "$EP" "$EP"
    run regenerate_client leg
    [ "$status" -eq 0 ] || { echo "$output"; cat "$WARN_LOG"; return 1; }
    a=$(aips_of leg)
    ! _aip_has_token "$a" "::/0" || return 1
    _aip_has_token "$a" "2000::/3"
    ! covers "$a" "$EP" || return 1
    ! grep -q 'WARN' "$WARN_LOG" || { cat "$WARN_LOG"; return 1; }
}

@test "regen: with CLIENT_IPV6_DIRECT our 2000::/3 next to a cut server list is dropped, no warning" {
    require_flock
    cut=$(_aip_carve_endpoints "$(mode2_list)" "$EP")
    setup_regen_ep dir 10.9.9.12 "$cut, 2000::/3" "$EP" "$EP" "export CLIENT_IPV6_DIRECT=1"
    run regenerate_client dir
    [ "$status" -eq 0 ] || { echo "$output"; cat "$WARN_LOG"; return 1; }
    a=$(aips_of dir)
    ! _aip_has_token "$a" "2000::/3" || return 1
    ! covers "$a" "$EP" || return 1
    ! grep -q 'WARN' "$WARN_LOG" || { cat "$WARN_LOG"; return 1; }
}

@test "regen: a changed server address keeps the old hole, cuts the new one, the server-list rules still apply" {
    require_flock
    cut_a=$(_aip_carve_endpoints "$(mode2_list)" "$EP")
    setup_regen_ep mv 10.9.9.13 "$cut_a, ::/0" "$EP" 64.1.2.3
    run regenerate_client mv
    [ "$status" -eq 0 ] || { echo "$output"; cat "$WARN_LOG"; return 1; }
    a=$(aips_of mv)
    ! covers "$a" "$EP" || return 1
    ! covers "$a" 64.1.2.3 || return 1
    _aip_has_token "$a" "2000::/3"
    ! _aip_has_token "$a" "::/0" || return 1
    covers "$a" 64.1.2.2 && covers "$a" 64.1.2.4 || { echo "the new hole is wider than one address: $a"; return 1; }
    grep -q '^Endpoint = 64.1.2.3:39743$' "$AWG_DIR/mv.conf"
    ! grep -q 'WARN' "$WARN_LOG" || { cat "$WARN_LOG"; return 1; }
}

@test "regen: a hand-made list of the server address alone is refused, with a way out" {
    require_flock
    setup_regen_ep only 10.9.9.14 "$EP/32" "$EP" "$EP"
    before=$(cksum < "$AWG_DIR/only.conf")
    run regenerate_client only
    [ "$status" -ne 0 ]
    grep -q "ERR: .*$EP" "$WARN_LOG" || { cat "$WARN_LOG"; return 1; }
    # refused BEFORE the rewrite: the client config is exactly as it was
    [ "$(cksum < "$AWG_DIR/only.conf")" = "$before" ] || { echo "config changed by a refused regen"; cat "$AWG_DIR/only.conf"; return 1; }
}

@test "regen: the server address alone next to an IPv6 route is refused too, config untouched" {
    require_flock
    setup_regen_ep only6 10.9.9.16 "$EP/32, 2000::/3" "$EP" "$EP"
    before=$(cksum < "$AWG_DIR/only6.conf")
    run regenerate_client only6
    [ "$status" -ne 0 ]
    [ "$(cksum < "$AWG_DIR/only6.conf")" = "$before" ] || { echo "config changed by a refused regen"; return 1; }
}

@test "regen --reset-routes: a list of the server address alone is replaced by the server list, not refused" {
    require_flock
    setup_regen_ep rst 10.9.9.17 "$EP/32" "$EP" "$EP"
    AWG_REGEN_RESET_ROUTES=1 run regenerate_client rst
    [ "$status" -eq 0 ] || { echo "$output"; cat "$WARN_LOG"; return 1; }
    a=$(aips_of rst)
    ! covers "$a" "$EP" || return 1
    _aip_has_token "$a" "2000::/3"
}

@test "regen: a split client whose routes do not hold the server address keeps its list" {
    require_flock
    setup_regen_ep spl 10.9.9.15 "10.0.0.0/8" "$EP" "$EP"
    run regenerate_client spl
    [ "$status" -eq 0 ]
    [ "$(aips_of spl)" = "10.0.0.0/8" ]
}

# --- both language twins carry the same code ---

@test "twins: the carve helpers are identical in code in both libraries" {
    local f ru en
    for f in _aip_endpoint_v4 _aip_carve_endpoints _aip_v4_norm _aip_same_set; do
        ru=$(sed -n "/^${f}() {/,/^}/p" "$BATS_TEST_DIRNAME/../awg_common.sh" | grep -v '^[[:space:]]*#')
        en=$(sed -n "/^${f}() {/,/^}/p" "$BATS_TEST_DIRNAME/../awg_common_en.sh" | grep -v '^[[:space:]]*#')
        [ -n "$ru" ] || { echo "$f missing"; return 1; }
        # The log_warn message is the only line allowed to differ (language).
        [ "$(grep -v log_warn <<< "$ru")" = "$(grep -v log_warn <<< "$en")" ] || { echo "$f differs"; diff <(echo "$ru") <(echo "$en"); return 1; }
    done
}

# --- modify: the contract stays (writes what was asked), the loop is named ---

# mrun <lib> <extra init> <AllowedIPs in m1.conf> <Endpoint in m1.conf> <modify args...>
mrun() {
    local lib="$1" initx="$2" aips="$3" ep="$4"; shift 4
    local manage="${lib/awg_common/manage_amneziawg}" d="$BATS_TEST_TMPDIR/m-$(basename "$lib" .sh)"
    rm -rf "$d"; mkdir -p "$d/keys" "$d/expiry"
    {
        printf "export AWG_PORT=39743\nexport AWG_TUNNEL_SUBNET='10.9.9.1/24'\nexport DISABLE_IPV6=1\n"
        printf "export ALLOWED_IPS_MODE=2\nexport ALLOWED_IPS='%s'\n" "$(mode2_list)"
        [[ -n "$initx" ]] && printf '%s\n' "$initx"
    } > "$d/awgsetup_cfg.init"
    printf '[Interface]\nPrivateKey = TESTKEY\nAddress = 10.9.9.1/24\nListenPort = 39743\n' > "$d/awg0.conf"
    printf '[Interface]\nPrivateKey = FAKEPRIV\nAddress = 10.9.9.40/32\nDNS = 1.1.1.1, 1.0.0.1\nMTU = 1280\n\n[Peer]\nPublicKey = SRVPUB\nEndpoint = %s\nAllowedIPs = %s\nPersistentKeepalive = 33\n' "$ep" "$aips" > "$d/m1.conf"
    AWG_DIR="$d" timeout 60 bash -c '
        export CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init" SERVER_CONF_FILE="$AWG_DIR/awg0.conf"
        export KEYS_DIR="$AWG_DIR/keys" EXPIRY_DIR="$AWG_DIR/expiry"
        log() { :; }; log_warn() { echo "WARN: $*"; }; log_error() { echo "ERR: $*"; }; log_debug() { :; }
        source "$1" >/dev/null 2>&1 || true
        eval "$(awk "/^modify_client\\(\\) \\{/,/^\\}/" "$2")"
        escape_sed() { printf "%s" "$1" | sed "s/[&\\\\/]/\\\\&/g"; }
        apply_config() { return 0; }; generate_qr() { return 0; }; generate_vpn_uri() { return 0; }; generate_qr_vpnuri() { return 0; }
        unset CLIENT_IPV6_DIRECT
        shift 2
        modify_client m1 "$@"; echo "RC=$?"
        sed -n "s/^AllowedIPs = //p; s/^Endpoint = /EP=/p" "$AWG_DIR/m1.conf"
    ' _ "$BATS_TEST_DIRNAME/../$lib" "$BATS_TEST_DIRNAME/../$manage" "$@" 2>&1
}

both() {
    local seen=0 lib
    for lib in awg_common.sh awg_common_en.sh; do
        "$1" "$lib" || return 1
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}

m_allowedips() {
    local lib="$1" out
    out=$(mrun "$lib" "" "10.0.0.0/8" "$EP:39743" AllowedIPs "128.0.0.0/3")
    [[ "$out" == *"RC=0"* ]] || { echo "modify failed ($lib): $out"; return 1; }
    [[ "$out" == *"WARN:"*"$EP"*"regen"* ]] || { echo "no loop warning ($lib): $out"; return 1; }
    grep -qx "128.0.0.0/3" <<< "$out" || { echo "the asked value was not written as is ($lib): $out"; return 1; }
    out=$(mrun "$lib" "" "128.0.0.0/3" "$EP:39743" AllowedIPs "10.0.0.0/8")
    [[ "$out" != *"WARN:"*"$EP"* ]] || { echo "warns about a list that does not hold the server ($lib): $out"; return 1; }
    out=$(mrun "$lib" "" "128.0.0.0/3" "vpn.example.com:39743" AllowedIPs "128.0.0.0/3")
    [[ "$out" != *"WARN:"* ]] || { echo "warns with a name as the endpoint ($lib): $out"; return 1; }
}
@test "modify AllowedIPs: writes the value as asked and names the loop when it holds the server address, both twins" {
    require_flock
    both m_allowedips
}

m_cut_server_list() {
    local lib="$1" out cut
    cut=$(_aip_carve_endpoints "$(mode2_list)" "$EP")
    out=$(mrun "$lib" "export CLIENT_IPV6_DIRECT=1" "10.0.0.0/8" "$EP:39743" AllowedIPs "$cut")
    [[ "$out" == *"RC=0"* ]] || { echo "modify failed ($lib): $out"; return 1; }
    [[ "$out" != *"WARN:"* ]] || { echo "a cut server list with the key is not recognised ($lib): $out"; return 1; }
    # Without the key the same list is a full tunnel without an IPv6 route and
    # must be named: this is what proves the hole was taken into account above
    # (a list not seen as a full tunnel gives no warning either way).
    out=$(mrun "$lib" "" "10.0.0.0/8" "$EP:39743" AllowedIPs "$cut")
    [[ "$out" == *"WARN:"*"IPv6"* ]] || { echo "the cut list is not seen as a full tunnel ($lib): $out"; return 1; }
}
@test "modify AllowedIPs: the server list with the hole is still the server list for the IPv6 key, both twins" {
    require_flock
    both m_cut_server_list
}

m_endpoint() {
    local lib="$1" out
    out=$(mrun "$lib" "" "128.0.0.0/3" "vpn.example.com:39743" Endpoint "$EP:39743")
    [[ "$out" == *"RC=0"* ]] || { echo "modify failed ($lib): $out"; return 1; }
    [[ "$out" == *"WARN:"*"$EP"* ]] || { echo "no warning for an endpoint under the routes ($lib): $out"; return 1; }
    grep -qx "EP=$EP:39743" <<< "$out" || { echo "endpoint not written ($lib): $out"; return 1; }
    out=$(mrun "$lib" "" "10.0.0.0/8" "vpn.example.com:39743" Endpoint "$EP:39743")
    [[ "$out" != *"WARN:"*"$EP"* ]] || { echo "warns though the routes do not hold the endpoint ($lib): $out"; return 1; }
}
@test "modify Endpoint: an address under the client routes is named, both twins" {
    require_flock
    both m_endpoint
}
