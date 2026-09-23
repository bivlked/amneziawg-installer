#!/usr/bin/env bats
# Routing mode 2 on Windows: LAN stays reachable, IPv6 still does not leak.
#
# Since v5.31.0 the list-based mode 2 got a bare ::/0 appended. The AmneziaWG
# Windows client (a wireguard-windows fork) turns on its kill switch when a
# single peer carries 0.0.0.0/0 OR ::/0, and that kill switch blocks the LAN -
# the very thing mode 2 exists for. Measured on a stand: gateway, LAN hosts and
# SSH unreachable. Without an IPv6 address on the interface Windows also refuses
# to install ANY IPv6 route (amneziawg-windows-client #112), so replacing ::/0
# with 2000::/3 alone would bring the LAN back and let IPv6 leak.
#
# The fix: the list-based full tunnel gets 2000::/3 (all global unicast IPv6)
# instead of ::/0, plus a ULA address from a dedicated sink prefix, so the route
# is installed and IPv6 dies in the tunnel. Measured: Windows (LAN back, no
# leak), Linux awg-quick (no regression), Android on a carrier with real IPv6
# (no leak). Mode 1 (0.0.0.0/0) keeps ::/0: its kill switch comes from the IPv4
# default route anyway. Dual-stack clients keep their own scheme.
#
# The scenarios run the REAL library in a fresh bash, once per language twin.
#
# shellcheck disable=SC2154

SINK_PREFIX="fddd:2c4:2c4:ffff"

require_flock()     { command -v flock &>/dev/null || skip "flock not available"; }
require_perl_zlib() { perl -MCompress::Zlib -MMIME::Base64 -e '1' 2>/dev/null || skip "perl Compress::Zlib/MIME::Base64 not available"; }
require_python3()   { command -v python3 &>/dev/null || skip "python3 not available"; }

# The real mode-2 list, read out of the installer (a copy would keep passing
# after someone edits the installer).
mode2_list() {
    sed -n 's/^[[:space:]]*ALLOWED_IPS="\(1\.0\.0\.0\/8,.*\)"$/\1/p' \
        "${BATS_TEST_DIRNAME}/../install_amneziawg.sh" | head -1
}

dir_of() { echo "$BATS_TEST_TMPDIR/s-$(basename "$1" .sh)"; }

# lr <lib> <server ALLOWED_IPS> <snippet> : a fresh install dir, the real library
# (and, for modify, the real manage twin), one bash per call. stdout+stderr back.
lr() {
    local lib="$1" aips="$2" snippet="$3" d
    d=$(dir_of "$lib")
    rm -rf "$d"; mkdir -p "$d/keys" "$d/expiry"
    {
        printf "export AWG_PORT=39743\nexport AWG_TUNNEL_SUBNET='10.9.9.1/24'\nexport DISABLE_IPV6=1\n"
        printf "export ALLOWED_IPS_MODE=2\nexport ALLOWED_IPS='%s'\n" "$aips"
        printf "export AWG_Jc=6\nexport AWG_Jmin=55\nexport AWG_Jmax=380\n"
        printf "export AWG_S1=72\nexport AWG_S2=56\nexport AWG_S3=32\nexport AWG_S4=16\n"
        printf "export AWG_H1='100000-800000'\nexport AWG_H2='1000000-8000000'\n"
        printf "export AWG_H3='10000000-80000000'\nexport AWG_H4='100000000-800000000'\n"
        printf "export AWG_I1='<r 128>'\nexport AWG_APPLY_MODE='syncconf'\n"
    } > "$d/awgsetup_cfg.init"
    # The same server config test_helper uses: render refuses one without the
    # obfuscation parameters (no split brain between server and clients).
    cat > "$d/awg0.conf" << 'CONF'
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
    printf 'SRVPRIVKEYPLACEHOLDER\n' > "$d/server_private.key"
    printf 'SRVPUBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n' > "$d/server_public.key"
    # pipefail as in manage_amneziawg.sh: without it a grep that finds nothing
    # inside a pipeline passes here and fails in production.
    AWG_DIR="$d" timeout 60 bash -c '
        set -o pipefail
        export CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init" SERVER_CONF_FILE="$AWG_DIR/awg0.conf"
        export KEYS_DIR="$AWG_DIR/keys" EXPIRY_DIR="$AWG_DIR/expiry"
        log() { echo "LOG: $*" >&2; }; log_warn() { echo "WARN: $*" >&2; }; log_error() { echo "ERR: $*" >&2; }; log_debug() { :; }
        source "$1" >/dev/null 2>&1 || true
        safe_load_config "$CONFIG_FILE" >/dev/null 2>&1
        get_main_nic() { echo eth0; }
        get_server_public_ip() { echo 203.0.113.10; }
        _ensure_server_public_key() { return 0; }
        eval "$2"
    ' _ "$BATS_TEST_DIRNAME/../$lib" "$snippet" 2>&1
}

both() {
    local seen=0 lib
    for lib in awg_common.sh awg_common_en.sh; do
        "$1" "$lib" || return 1
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}

conf_line() { grep -E "^$2 = " "$(dir_of "$1")/$3.conf" | head -1; }

# --- the sink address ---

sink_addr_form() {
    local lib="$1" out
    out=$(lr "$lib" "0.0.0.0/0" '
        echo "A=$(_awg_v6_sink_addr 10.9.9.5)"
        echo "B=$(_awg_v6_sink_addr 10.9.9.1)"
        echo "C=$(_awg_v6_sink_addr 10.255.0.10)"
        _awg_v6_sink_addr 10.9.9.300 >/dev/null 2>&1; echo "BAD=$?"
        _awg_v6_sink_addr "" >/dev/null 2>&1; echo "EMPTY=$?"')
    [[ "$out" == *"A=${SINK_PREFIX}::a09:905"* ]] || { echo "10.9.9.5 ($lib): $out"; return 1; }
    [[ "$out" == *"B=${SINK_PREFIX}::a09:901"* ]] || { echo "10.9.9.1 ($lib): $out"; return 1; }
    [[ "$out" == *"C=${SINK_PREFIX}::aff:a"* ]] || { echo "10.255.0.10 ($lib): $out"; return 1; }
    [[ "$out" == *"BAD=1"* && "$out" == *"EMPTY=1"* ]] || { echo "invalid input accepted ($lib): $out"; return 1; }
}
@test "sink: the address embeds the client IPv4 in a dedicated ULA prefix, both twins" {
    both sink_addr_form
}

sink_recognised() {
    local lib="$1" out
    out=$(lr "$lib" "0.0.0.0/0" '
        for a in "'"$SINK_PREFIX"'::a09:905" "'"$SINK_PREFIX"'::a09:905/128" "FDDD:2C4:2C4:FFFF::A09:905" \
                 "fddd:2c4:2c4:2c4::5" "2a00:1fa0::1" "10.9.9.5" ""; do
            if _is_v6_sink_addr "$a"; then echo "Y[$a]"; else echo "N[$a]"; fi
        done')
    [[ "$out" == *"Y[${SINK_PREFIX}::a09:905]"* && "$out" == *"Y[${SINK_PREFIX}::a09:905/128]"* ]] || { echo "sink not recognised ($lib): $out"; return 1; }
    [[ "$out" == *"Y[FDDD:2C4:2C4:FFFF::A09:905]"* ]] || { echo "case matters ($lib): $out"; return 1; }
    # The dual-stack tunnel subnet is NOT the sink: regen and vpn:// tell them apart.
    [[ "$out" == *"N[fddd:2c4:2c4:2c4::5]"* && "$out" == *"N[2a00:1fa0::1]"* ]] || { echo "false positive ($lib): $out"; return 1; }
    [[ "$out" == *"N[10.9.9.5]"* && "$out" == *"N[]"* ]] || { echo "false positive on IPv4/empty ($lib): $out"; return 1; }
}
@test "sink: recognised by prefix, never confused with the dual-stack subnet, both twins" {
    both sink_recognised
}

# --- the route appender ---

append_cases() {
    local lib="$1" list out
    list=$(mode2_list)
    [ -n "$list" ] || { echo "empty mode-2 fixture"; return 1; }
    out=$(lr "$lib" "0.0.0.0/0" '
        L="'"$list"'"
        echo "M2=$(_append_ipv6_full_tunnel_route "$L")"
        echo "M1=$(_append_ipv6_full_tunnel_route "0.0.0.0/0")"
        echo "EXPL=$(_append_ipv6_full_tunnel_route "$L, ::/0")"
        echo "IDEM=$(_append_ipv6_full_tunnel_route "$L, 2000::/3")"
        echo "P32=$(_append_ipv6_full_tunnel_route "$L, 2000::/32")"
        echo "M1V6=$(_append_ipv6_full_tunnel_route "0.0.0.0/0, ::/0")"
        echo "SPLIT=$(_append_ipv6_full_tunnel_route "10.0.0.0/8, 192.168.0.0/16")"
        echo "SPLITV6=$(_append_ipv6_full_tunnel_route "10.0.0.0/8, ::/0")"
        echo "DUAL=$(_append_ipv6_full_tunnel_route "$L, fddd:2c4:2c4:2c4::/64")"
        echo "MIXED=$(_append_ipv6_full_tunnel_route "$L, ::/0, fddd:2c4:2c4:2c4::/64")"')
    [[ "$out" == *"M2=$list, 2000::/3"$'\n'* ]] || { echo "mode 2 ($lib): $out"; return 1; }
    [[ "$out" == *"M1=0.0.0.0/0, ::/0"$'\n'* ]] || { echo "mode 1 ($lib): $out"; return 1; }
    # A list that already has an IPv6 part is never rewritten here: an explicit
    # ::/0 is the user's choice (add --allowed-ips), and the migration of our own
    # old ::/0 lives in regen, which knows where the list came from.
    [[ "$out" == *"EXPL=$list, ::/0"$'\n'* ]] || { echo "explicit ::/0 rewritten ($lib): $out"; return 1; }
    [[ "$out" == *"IDEM=$list, 2000::/3"$'\n'* ]] || { echo "not idempotent ($lib): $out"; return 1; }
    [[ "$out" == *"P32=$list, 2000::/32"$'\n'* ]] || { echo "2000::/32 touched ($lib): $out"; return 1; }
    [[ "$out" == *"M1V6=0.0.0.0/0, ::/0"$'\n'* ]] || { echo "mode 1 with ::/0 changed ($lib): $out"; return 1; }
    [[ "$out" == *"SPLIT=10.0.0.0/8, 192.168.0.0/16"$'\n'* ]] || { echo "split changed ($lib): $out"; return 1; }
    # A split list someone gave ::/0 by hand is theirs: not a full tunnel, not touched.
    [[ "$out" == *"SPLITV6=10.0.0.0/8, ::/0"$'\n'* ]] || { echo "hand-made split touched ($lib): $out"; return 1; }
    [[ "$out" == *"DUAL=$list, fddd:2c4:2c4:2c4::/64"$'\n'* ]] || { echo "dual-stack touched ($lib): $out"; return 1; }
    [[ "$out" == *"MIXED=$list, ::/0, fddd:2c4:2c4:2c4::/64"* ]] || { echo "mixed IPv6 part touched ($lib): $out"; return 1; }
}
@test "append: list gets 2000::/3, mode 1 keeps ::/0, an explicit IPv6 part is kept, both twins" {
    both append_cases
}

# --- the migration of our own old ::/0 ---

migrate_cases() {
    local lib="$1" list out
    list=$(mode2_list)
    [ -n "$list" ] || { echo "empty mode-2 fixture"; return 1; }
    out=$(lr "$lib" "$list" '
        L="'"$list"'"
        echo "OURS=$(_aip_migrate_legacy_v6 "$L, ::/0" "$L")"
        echo "CR=$(_aip_migrate_legacy_v6 "$L, ::/0"$'"'"'\r'"'"' "$L")"
        echo "EXPL=$(_aip_migrate_legacy_v6 "0.0.0.0/1, 128.0.0.0/1, ::/0" "$L")"
        echo "M1=$(_aip_migrate_legacy_v6 "0.0.0.0/0, ::/0" "0.0.0.0/0")"
        echo "OTHERBASE=$(_aip_migrate_legacy_v6 "$L, ::/0" "0.0.0.0/0")"
        echo "MIXED=$(_aip_migrate_legacy_v6 "$L, ::/0, fddd:2c4:2c4:2c4::/64" "$L")"
        echo "NOV6=$(_aip_migrate_legacy_v6 "$L" "$L")"
        echo "DONE=$(_aip_migrate_legacy_v6 "$L, 2000::/3" "$L")"
        R=$(printf "%s\n" "$L" | tr "," "\n" | tac | paste -sd, -)
        echo "REORD=$(_aip_migrate_legacy_v6 "$R, ::/0, 1.0.0.0/8" "$L")"
        V=$(_aip_migrate_legacy_v6 "::/0" "$L"); echo "V6ONLY=$V rc=$?"
        echo "SPLITBASE=$(_aip_migrate_legacy_v6 "10.0.0.0/8, ::/0" "10.0.0.0/8")"
        # grep failing for real (exit 2) is a failure, not "no lines"
        V=$(grep() { [[ "$1" == "-vF" ]] && return 2; command grep "$@"; }; _aip_migrate_legacy_v6 "$L, ::/0" "$L"); echo "GREPV rc=$?"
        V=$(grep() { [[ "$1" == "-F" ]] && return 2; command grep "$@"; }; _aip_migrate_legacy_v6 "$L, ::/0" "$L"); echo "GREPF rc=$?"')
    # Only the exact shape v5.31-v5.36 wrote: the server list plus our ::/0.
    [[ "$out" == *"OURS=$list, 2000::/3"$'\n'* ]] || { echo "our ::/0 not migrated ($lib): $out"; return 1; }
    [[ "$out" == *"CR=$list, 2000::/3"$'\n'* ]] || { echo "CR broke the migration ($lib): $out"; return 1; }
    # A full tunnel the user wrote by hand is theirs, even with ::/0.
    [[ "$out" == *"EXPL=0.0.0.0/1, 128.0.0.0/1, ::/0"$'\n'* ]] || { echo "explicit list migrated ($lib): $out"; return 1; }
    [[ "$out" == *"M1=0.0.0.0/0, ::/0"$'\n'* ]] || { echo "mode 1 migrated ($lib): $out"; return 1; }
    [[ "$out" == *"OTHERBASE=$list, ::/0"$'\n'* ]] || { echo "migrated against a mode-1 server ($lib): $out"; return 1; }
    [[ "$out" == *"MIXED=$list, ::/0, fddd:2c4:2c4:2c4::/64"$'\n'* ]] || { echo "mixed IPv6 part migrated ($lib): $out"; return 1; }
    [[ "$out" == *"NOV6=$list"$'\n'* ]] || { echo "list without IPv6 changed ($lib): $out"; return 1; }
    [[ "$out" == *"DONE=$list, 2000::/3"$'\n'* ]] || { echo "not idempotent ($lib): $out"; return 1; }
    # the same routes in another order, one repeated: still ours
    [[ "$out" == *"REORD="*", 2000::/3, 1.0.0.0/8"$'\n'* ]] || { echo "reordered list not migrated ($lib): $out"; return 1; }
    # no IPv4 part at all (modify accepts it): kept, and no failure under pipefail
    [[ "$out" == *"V6ONLY=::/0 rc=0"* ]] || { echo "IPv6-only list ($lib): $out"; return 1; }
    # a split server list (mode 3) is never a mode-2 origin
    [[ "$out" == *"SPLITBASE=10.0.0.0/8, ::/0"$'\n'* ]] || { echo "migrated against a split server ($lib): $out"; return 1; }
    [[ "$out" == *"GREPV rc=1"* && "$out" == *"GREPF rc=1"* ]] || { echo "grep failure taken for no lines ($lib): $out"; return 1; }
}
@test "migrate: only the server list plus our old ::/0 becomes 2000::/3, both twins" {
    both migrate_cases
}

# grep -q quits on the first match; under pipefail the writer then dies of
# SIGPIPE and the pipeline reports "not found". Long lists make it near certain.
has_token_pipefail() {
    local lib="$1" out
    out=$(lr "$lib" "0.0.0.0/0" '
        set -o pipefail
        L="0.0.0.0/0"; for i in $(seq 1 400); do L+=", 10.$((i / 250)).$((i % 250)).1/32"; done
        miss=0
        for i in $(seq 1 30); do _aip_has_token "$L" "0.0.0.0/0" || miss=$((miss + 1)); done
        echo "MISS=$miss"
        echo "ROUTE=$(_append_ipv6_full_tunnel_route "$L" | grep -o "::/0\|2000::/3")"')
    [[ "$out" == *"MISS=0"* ]] || { echo "false negatives ($lib): $out"; return 1; }
    [[ "$out" == *"ROUTE=::/0"* ]] || { echo "mode 1 list got the wrong route ($lib): $out"; return 1; }
}
@test "tokens: a long list under pipefail never reports a present token as missing, both twins" {
    both has_token_pipefail
}

# --- render_client_config ---

render_mode2() {
    local lib="$1" out
    out=$(lr "$lib" "$(mode2_list)" 'render_client_config c1 10.9.9.2 FAKEPRIV FAKEPUB 203.0.113.10 39743; echo "RC=$?"')
    [[ "$out" == *"RC=0"* ]] || { echo "render failed ($lib): $out"; return 1; }
    [ "$(conf_line "$lib" Address c1)" = "Address = 10.9.9.2/32, ${SINK_PREFIX}::a09:902/128" ] || { echo "address ($lib): $(conf_line "$lib" Address c1)"; return 1; }
    [[ "$(conf_line "$lib" AllowedIPs c1)" == "AllowedIPs = 1.0.0.0/8, "*"208.0.0.0/4, 8.8.8.8/32, 1.1.1.1/32, 2000::/3" ]] || { echo "routes ($lib): $(conf_line "$lib" AllowedIPs c1)"; return 1; }
    ! grep -qF '::/0' "$(dir_of "$lib")/c1.conf" || { echo "::/0 left ($lib)"; return 1; }
}
@test "render: mode 2 writes 2000::/3 and the sink address, no ::/0, both twins" {
    both render_mode2
}

render_mode1() {
    local lib="$1" out
    out=$(lr "$lib" "0.0.0.0/0" 'render_client_config c1 10.9.9.4 FAKEPRIV FAKEPUB 203.0.113.10 39743; echo "RC=$?"')
    [[ "$out" == *"RC=0"* ]] || { echo "render failed ($lib): $out"; return 1; }
    [ "$(conf_line "$lib" Address c1)" = "Address = 10.9.9.4/32" ] || { echo "address ($lib): $(conf_line "$lib" Address c1)"; return 1; }
    [ "$(conf_line "$lib" AllowedIPs c1)" = "AllowedIPs = 0.0.0.0/0, ::/0" ] || { echo "routes ($lib)"; return 1; }
}
@test "render: mode 1 is unchanged - 0.0.0.0/0, ::/0 and an IPv4-only address, both twins" {
    both render_mode1
}

render_split() {
    local lib="$1" out
    out=$(lr "$lib" "10.0.0.0/8, 192.168.0.0/16" 'render_client_config c1 10.9.9.5 FAKEPRIV FAKEPUB 203.0.113.10 39743; echo "RC=$?"')
    [[ "$out" == *"RC=0"* ]] || { echo "render failed ($lib): $out"; return 1; }
    [ "$(conf_line "$lib" Address c1)" = "Address = 10.9.9.5/32" ] || { echo "address ($lib)"; return 1; }
    [ "$(conf_line "$lib" AllowedIPs c1)" = "AllowedIPs = 10.0.0.0/8, 192.168.0.0/16" ] || { echo "routes ($lib)"; return 1; }
}
@test "render: a real split gets neither an IPv6 route nor the sink address, both twins" {
    both render_split
}

render_dual() {
    local lib="$1" out
    out=$(lr "$lib" "$(mode2_list)" '
        export ALLOW_IPV6_TUNNEL=1 IPV6_SUBNET="fddd:2c4:2c4:2c4::/64" SERVER_HAS_NATIVE_IPV6=0
        render_client_config c1 10.9.9.6 FAKEPRIV FAKEPUB 203.0.113.10 39743 fddd:2c4:2c4:2c4::6; echo "RC=$?"')
    [[ "$out" == *"RC=0"* ]] || { echo "render failed ($lib): $out"; return 1; }
    [ "$(conf_line "$lib" Address c1)" = "Address = 10.9.9.6/32, fddd:2c4:2c4:2c4::6/128" ] || { echo "address ($lib): $(conf_line "$lib" Address c1)"; return 1; }
    ! grep -qF "$SINK_PREFIX" "$(dir_of "$lib")/c1.conf" || { echo "sink on a dual-stack client ($lib)"; return 1; }
}
@test "render: a dual-stack client keeps its own address and scheme, no sink, both twins" {
    both render_dual
}

render_explicit_v6() {
    local lib="$1" out
    out=$(lr "$lib" "$(mode2_list)" '
        export CLIENT_ALLOWED_IPS="0.0.0.0/1, 128.0.0.0/1, ::/0"
        render_client_config c1 10.9.9.7 FAKEPRIV FAKEPUB 203.0.113.10 39743; echo "RC=$?"')
    [[ "$out" == *"RC=0"* ]] || { echo "render failed ($lib): $out"; return 1; }
    [ "$(conf_line "$lib" AllowedIPs c1)" = "AllowedIPs = 0.0.0.0/1, 128.0.0.0/1, ::/0" ] || { echo "explicit list rewritten ($lib): $(conf_line "$lib" AllowedIPs c1)"; return 1; }
    [ "$(conf_line "$lib" Address c1)" = "Address = 10.9.9.7/32" ] || { echo "sink on an explicit ::/0 ($lib): $(conf_line "$lib" Address c1)"; return 1; }
}
@test "render: add --allowed-ips with an explicit ::/0 is written as is, no sink, both twins" {
    both render_explicit_v6
}

# --- regen ---

# regen_run <lib> <server list> <client AllowedIPs> <client Address> <extra snippet>
regen_run() {
    local lib="$1" slist="$2" caips="$3" caddr="$4" extra="${5:-}"
    lr "$lib" "$slist" '
        printf "\n[Peer]\n#_Name = r1\nPublicKey = PUBr1\nAllowedIPs = 10.9.9.20/32\n" >> "$SERVER_CONF_FILE"
        printf "FAKEPRIV" > "$KEYS_DIR/r1.private"
        cat > "$AWG_DIR/r1.conf" << EOF
[Interface]
PrivateKey = FAKEPRIV
Address = '"$caddr"'
DNS = 1.1.1.1, 1.0.0.1
MTU = 1280

[Peer]
PublicKey = SRVPUB
Endpoint = 203.0.113.10:39743
AllowedIPs = '"$caips"'
PersistentKeepalive = 33
EOF
        generate_qr() { return 0; }; generate_vpn_uri() { return 0; }; generate_qr_vpnuri() { return 0; }
        '"$extra"'
        regenerate_client r1; echo "RC=$?"
        regenerate_client r1; echo "RC2=$?"'
}

regen_migrates() {
    local lib="$1" list out
    list=$(mode2_list)
    out=$(regen_run "$lib" "$list" "$list, ::/0" "10.9.9.20/32")
    [[ "$out" == *"RC=0"* && "$out" == *"RC2=0"* ]] || { echo "regen failed ($lib): $out"; return 1; }
    [ "$(conf_line "$lib" AllowedIPs r1)" = "AllowedIPs = $list, 2000::/3" ] || { echo "routes ($lib): $(conf_line "$lib" AllowedIPs r1)"; return 1; }
    [ "$(conf_line "$lib" Address r1)" = "Address = 10.9.9.20/32, ${SINK_PREFIX}::a09:914/128" ] || { echo "address ($lib): $(conf_line "$lib" Address r1)"; return 1; }
    [ "$(grep -o "$SINK_PREFIX" "$(dir_of "$lib")/r1.conf" | wc -l)" -eq 1 ] || { echo "sink doubled ($lib)"; return 1; }
    # the only message the operator gets about the change
    [[ "$out" == *"LOG:"*"2000::/3"* ]] || { echo "migration not reported ($lib): $out"; return 1; }
}
@test "regen: a mode-2 client issued with ::/0 gets 2000::/3 and the sink, twice is idempotent, both twins" {
    require_flock
    both regen_migrates
}

regen_split_kept() {
    local lib="$1" out
    out=$(regen_run "$lib" "$(mode2_list)" "10.0.0.0/8" "10.9.9.20/32")
    [[ "$out" == *"RC=0"* ]] || { echo "regen failed ($lib): $out"; return 1; }
    [ "$(conf_line "$lib" AllowedIPs r1)" = "AllowedIPs = 10.0.0.0/8" ] || { echo "routes ($lib)"; return 1; }
    # The renderer draws mode 2 first; the restored split list must take the sink away again.
    [ "$(conf_line "$lib" Address r1)" = "Address = 10.9.9.20/32" ] || { echo "sink left on a split client ($lib): $(conf_line "$lib" Address r1)"; return 1; }
}
@test "regen: a customized split client keeps its list and gets no sink address, both twins" {
    require_flock
    both regen_split_kept
}

regen_mode1_kept() {
    local lib="$1" out
    out=$(regen_run "$lib" "$(mode2_list)" "0.0.0.0/0, ::/0" "10.9.9.20/32")
    [[ "$out" == *"RC=0"* ]] || { echo "regen failed ($lib): $out"; return 1; }
    [ "$(conf_line "$lib" AllowedIPs r1)" = "AllowedIPs = 0.0.0.0/0, ::/0" ] || { echo "routes ($lib)"; return 1; }
    [ "$(conf_line "$lib" Address r1)" = "Address = 10.9.9.20/32" ] || { echo "address ($lib)"; return 1; }
    [[ "$out" != *"WARN:"* ]] || { echo "warning on mode 1 ($lib): $out"; return 1; }
}
@test "regen: a client customized to 0.0.0.0/0 keeps ::/0 and no sink, both twins" {
    require_flock
    both regen_mode1_kept
}

regen_reset() {
    local lib="$1" list out
    list=$(mode2_list)
    out=$(regen_run "$lib" "$list" "10.0.0.0/8" "10.9.9.20/32" 'export AWG_REGEN_RESET_ROUTES=1')
    [[ "$out" == *"RC=0"* ]] || { echo "regen failed ($lib): $out"; return 1; }
    [ "$(conf_line "$lib" AllowedIPs r1)" = "AllowedIPs = $list, 2000::/3" ] || { echo "routes ($lib)"; return 1; }
    [ "$(conf_line "$lib" Address r1)" = "Address = 10.9.9.20/32, ${SINK_PREFIX}::a09:914/128" ] || { echo "address ($lib)"; return 1; }
}
@test "regen --reset-routes: back to the mode-2 list with 2000::/3 and the sink, both twins" {
    require_flock
    both regen_reset
}

regen_explicit_kept() {
    local lib="$1" out
    out=$(regen_run "$lib" "$(mode2_list)" "0.0.0.0/1, 128.0.0.0/1, ::/0" "10.9.9.20/32")
    [[ "$out" == *"RC=0"* && "$out" == *"RC2=0"* ]] || { echo "regen failed ($lib): $out"; return 1; }
    [ "$(conf_line "$lib" AllowedIPs r1)" = "AllowedIPs = 0.0.0.0/1, 128.0.0.0/1, ::/0" ] || { echo "explicit list migrated ($lib): $(conf_line "$lib" AllowedIPs r1)"; return 1; }
    [ "$(conf_line "$lib" Address r1)" = "Address = 10.9.9.20/32" ] || { echo "sink on an explicit ::/0 ($lib)"; return 1; }
    # kept, but not silently: with ::/0 the Windows client loses the LAN
    [[ "$out" == *"WARN:"*"reset-routes"* ]] || { echo "kept silently ($lib): $out"; return 1; }
}
@test "regen: a hand-written full tunnel with ::/0 keeps ::/0, no sink, with a warning, both twins" {
    require_flock
    both regen_explicit_kept
}

# A v5.31-v5.36 profile after the server list changed (isolation toggled, the
# tunnel subnet moved): no longer provably ours, so it is kept - and said so.
regen_legacy_base_changed() {
    local lib="$1" list out
    list=$(mode2_list)
    out=$(regen_run "$lib" "$list" "$list, 10.9.9.0/24, ::/0" "10.9.9.20/32")
    [[ "$out" == *"RC=0"* ]] || { echo "regen failed ($lib): $out"; return 1; }
    [ "$(conf_line "$lib" AllowedIPs r1)" = "AllowedIPs = $list, 10.9.9.0/24, ::/0" ] || { echo "routes ($lib): $(conf_line "$lib" AllowedIPs r1)"; return 1; }
    [[ "$out" == *"WARN:"*"reset-routes"* ]] || { echo "legacy ::/0 kept silently ($lib): $out"; return 1; }
}
@test "regen: an old ::/0 on a list that no longer matches the server is kept with a warning, both twins" {
    require_flock
    both regen_legacy_base_changed
}

# The hint must fit the server: --reset-routes only helps where the server list
# is itself mode 2; on a mode-1 or mode-3 server it would hand out 0.0.0.0/0 or a
# split list and lose the client's own routes.
regen_keep_advice() {
    local lib="$1" list out
    list=$(mode2_list)
    out=$(regen_run "$lib" "0.0.0.0/0" "0.0.0.0/1, 128.0.0.0/1, ::/0" "10.9.9.20/32")
    [[ "$out" == *"RC=0"* && "$out" == *"WARN:"*"2000::/3"* ]] || { echo "mode-1 server: no usable hint ($lib): $out"; return 1; }
    [[ "$out" != *"reset-routes"* ]] || { echo "mode-1 server: harmful reset hint ($lib): $out"; return 1; }
    out=$(regen_run "$lib" "10.0.0.0/8" "$list, ::/0" "10.9.9.20/32")
    [[ "$out" == *"RC=0"* && "$out" == *"WARN:"*"2000::/3"* ]] || { echo "mode-3 server: no usable hint ($lib): $out"; return 1; }
    [[ "$out" != *"reset-routes"* ]] || { echo "mode-3 server: harmful reset hint ($lib): $out"; return 1; }
    # a split list with ::/0 is not a full tunnel: nothing to warn about
    out=$(regen_run "$lib" "$list" "10.0.0.0/8, ::/0" "10.9.9.20/32")
    [[ "$out" == *"RC=0"* && "$out" != *"WARN:"* ]] || { echo "false warning on a split list ($lib): $out"; return 1; }
}
@test "regen: the hint for a kept ::/0 fits the server's routing mode, both twins" {
    require_flock
    both regen_keep_advice
}

regen_ipv6_only() {
    local lib="$1" out
    out=$(regen_run "$lib" "$(mode2_list)" "::/0" "10.9.9.20/32")
    [[ "$out" == *"RC=0"* && "$out" == *"RC2=0"* ]] || { echo "regen failed ($lib): $out"; return 1; }
    [ "$(conf_line "$lib" AllowedIPs r1)" = "AllowedIPs = ::/0" ] || { echo "IPv6-only list lost ($lib): $(conf_line "$lib" AllowedIPs r1)"; return 1; }
}
@test "regen: an IPv6-only AllowedIPs survives regen under pipefail, both twins" {
    require_flock
    both regen_ipv6_only
}

# A dual-stack client on a server with native IPv6: add writes the list plus ::/0
# for it, and a plain regen must not flip that to 2000::/3 (the tunnel ULA would
# go with it).
regen_dual_native() {
    local lib="$1" list out
    list=$(mode2_list)
    out=$(regen_run "$lib" "$list" "$list, ::/0" "10.9.9.20/32, fddd:2c4:2c4:2c4::20/128" '
        sed -i "s|^AllowedIPs = 10.9.9.20/32\$|AllowedIPs = 10.9.9.20/32, fddd:2c4:2c4:2c4::20/128|" "$SERVER_CONF_FILE"
        export ALLOW_IPV6_TUNNEL=1 IPV6_SUBNET="fddd:2c4:2c4:2c4::/64" SERVER_HAS_NATIVE_IPV6=1')
    [[ "$out" == *"RC=0"* && "$out" == *"RC2=0"* ]] || { echo "regen failed ($lib): $out"; return 1; }
    [ "$(conf_line "$lib" AllowedIPs r1)" = "AllowedIPs = $list, ::/0" ] || { echo "dual-stack route flipped ($lib): $(conf_line "$lib" AllowedIPs r1)"; return 1; }
    [ "$(conf_line "$lib" Address r1)" = "Address = 10.9.9.20/32, fddd:2c4:2c4:2c4::20/128" ] || { echo "dual-stack address ($lib): $(conf_line "$lib" Address r1)"; return 1; }
    # ::/0 is present, nothing to warn about
    [[ "$out" != *"WARN:"* ]] || { echo "false warning ($lib): $out"; return 1; }
}
@test "regen: a dual-stack client on a native-IPv6 server keeps ::/0, both twins" {
    require_flock
    both regen_dual_native
}

regen_sync_fails() {
    local lib="$1" out
    out=$(regen_run "$lib" "$(mode2_list)" "10.0.0.0/8" "10.9.9.20/32" '_sync_v6_sink_address() { return 1; }')
    [[ "$out" == *"RC=1"* && "$out" == *"ERR:"*"Address"* ]] || { echo "sync failure swallowed ($lib): $out"; return 1; }
    # the state left behind is named: the routes are written, QR and vpn:// are not rebuilt
    [[ "$out" == *"ERR:"*"Address"*"QR"* ]] || { echo "stale QR not mentioned ($lib): $out"; return 1; }
}
regen_migrate_fails() {
    local lib="$1" out list
    list=$(mode2_list)
    out=$(regen_run "$lib" "$list" "$list, ::/0" "10.9.9.20/32" '_aip_migrate_legacy_v6() { return 1; }')
    [[ "$out" == *"RC=1"* && "$out" == *"ERR:"*"AllowedIPs"* ]] || { echo "migration failure swallowed ($lib): $out"; return 1; }
}
@test "regen: a failure to compute the migrated routes is reported, not swallowed, both twins" {
    require_flock
    both regen_migrate_fails
}

@test "regen: a failure to align Address is reported, not swallowed, both twins" {
    require_flock
    both regen_sync_fails
}

# --- modify ---

# mod_run <lib> <client AllowedIPs> <client Address> <new AllowedIPs> [extra snippet]
mod_run() {
    local lib="$1" caips="$2" caddr="$3" newv="$4" extra="${5:-}" manage
    manage="${lib/awg_common/manage_amneziawg}"
    lr "$lib" "$(mode2_list)" '
        cat > "$AWG_DIR/m1.conf" << EOF
[Interface]
PrivateKey = FAKEPRIV
Address = '"$caddr"'
DNS = 1.1.1.1, 1.0.0.1
MTU = 1280

[Peer]
PublicKey = SRVPUB
Endpoint = 203.0.113.10:39743
AllowedIPs = '"$caips"'
PersistentKeepalive = 33
EOF
        eval "$(awk "/^modify_client\\(\\) \\{/,/^\\}/" "'"$BATS_TEST_DIRNAME/../$manage"'")"
        escape_sed() { printf "%s" "$1" | sed "s/[&\\\\/]/\\\\&/g"; }
        apply_config() { return 0; }; generate_qr() { return 0; }; generate_vpn_uri() { return 0; }; generate_qr_vpnuri() { return 0; }
        '"$extra"'
        modify_client m1 AllowedIPs "'"$newv"'"; echo "RC=$?"'
}

modify_follows() {
    local lib="$1" list sinkaddr out
    list=$(mode2_list)
    sinkaddr="10.9.9.40/32, ${SINK_PREFIX}::a09:928/128"
    # sink client -> split: the sink goes away
    out=$(mod_run "$lib" "$list, 2000::/3" "$sinkaddr" "10.0.0.0/8")
    [[ "$out" == *"RC=0"* ]] || { echo "modify failed ($lib): $out"; return 1; }
    [ "$(conf_line "$lib" Address m1)" = "Address = 10.9.9.40/32" ] || { echo "sink kept on split ($lib): $(conf_line "$lib" Address m1)"; return 1; }
    # plain IPv4 client -> list with 2000::/3: the sink appears
    out=$(mod_run "$lib" "10.0.0.0/8" "10.9.9.40/32" "$list, 2000::/3")
    [[ "$out" == *"RC=0"* ]] || { echo "modify failed ($lib): $out"; return 1; }
    [ "$(conf_line "$lib" Address m1)" = "Address = $sinkaddr" ] || { echo "no sink ($lib): $(conf_line "$lib" Address m1)"; return 1; }
    # the full list without any IPv6 route: written as asked, sink removed, and a warning
    out=$(mod_run "$lib" "$list, 2000::/3" "$sinkaddr" "$list")
    [[ "$out" == *"RC=0"* && "$out" == *"WARN:"*"regen"* ]] || { echo "no warning ($lib): $out"; return 1; }
    [ "$(conf_line "$lib" Address m1)" = "Address = 10.9.9.40/32" ] || { echo "sink kept without route ($lib)"; return 1; }
    # a dual-stack client: its real IPv6 address is never touched, and the edit
    # itself goes through (a rollback would leave the old Address too)
    out=$(mod_run "$lib" "$list, fddd:2c4:2c4:2c4::/64" "10.9.9.40/32, fddd:2c4:2c4:2c4::40/128" "$list, 2000::/3")
    [[ "$out" == *"RC=0"* ]] || { echo "modify failed ($lib): $out"; return 1; }
    [ "$(conf_line "$lib" AllowedIPs m1)" = "AllowedIPs = $list, 2000::/3" ] || { echo "edit not applied ($lib)"; return 1; }
    [ "$(conf_line "$lib" Address m1)" = "Address = 10.9.9.40/32, fddd:2c4:2c4:2c4::40/128" ] || { echo "dual-stack address touched ($lib): $(conf_line "$lib" Address m1)"; return 1; }
    # 2000::/3 next to ::/0: ::/0 brings the Windows kill switch anyway, no sink
    out=$(mod_run "$lib" "10.0.0.0/8" "10.9.9.40/32" "$list, 2000::/3, ::/0")
    [[ "$out" == *"RC=0"* ]] || { echo "modify failed ($lib): $out"; return 1; }
    [ "$(conf_line "$lib" Address m1)" = "Address = 10.9.9.40/32" ] || { echo "sink next to ::/0 ($lib): $(conf_line "$lib" Address m1)"; return 1; }
}
@test "modify AllowedIPs: the sink address follows the routes, dual-stack untouched, both twins" {
    require_flock
    both modify_follows
}

modify_rolls_back() {
    local lib="$1" out d
    d=$(dir_of "$lib")
    # An empty Address cannot be aligned: the edit must be undone, loudly.
    out=$(mod_run "$lib" "10.0.0.0/8" "" "$(mode2_list), 2000::/3")
    [[ "$out" == *"RC=1"* && "$out" == *"ERR:"* ]] || { echo "no failure ($lib): $out"; return 1; }
    [ "$(conf_line "$lib" AllowedIPs m1)" = "AllowedIPs = 10.0.0.0/8" ] || { echo "not restored ($lib): $(conf_line "$lib" AllowedIPs m1)"; return 1; }
    [ -z "$(find "$d" -maxdepth 1 -name 'm1.conf.bak-*')" ] || { echo "backup left ($lib): $(ls "$d")"; return 1; }
}
@test "modify AllowedIPs: when Address cannot follow, the edit is rolled back, both twins" {
    require_flock
    both modify_rolls_back
}

# manage one patch newer than the library: the edit goes through, with a warning.
modify_old_library() {
    local lib="$1" out list
    list=$(mode2_list)
    out=$(mod_run "$lib" "10.0.0.0/8" "10.9.9.40/32" "$list, 2000::/3" 'unset -f _sync_v6_sink_address')
    [[ "$out" == *"RC=0"* && "$out" == *"WARN:"*"awg_common.sh"* ]] || { echo "old library ($lib): $out"; return 1; }
    [ "$(conf_line "$lib" AllowedIPs m1)" = "AllowedIPs = $list, 2000::/3" ] || { echo "edit rolled back ($lib)"; return 1; }
}
@test "modify AllowedIPs: next to an older library the edit is kept and the gap is named, both twins" {
    require_flock
    both modify_old_library
}

# --- _sync_v6_sink_address on hand-edited files ---

# sync_on <lib> <file content (printf format)> : runs the sync, prints RC and the file.
sync_on() {
    local lib="$1" content="$2"
    lr "$lib" "0.0.0.0/0" '
        printf "'"$content"'" > "$AWG_DIR/h.conf"
        _sync_v6_sink_address "$AWG_DIR/h.conf"; echo "RC=$?"
        cat "$AWG_DIR/h.conf"'
}

sync_hand_edited() {
    local lib="$1" out
    # CRLF from a Windows editor: the sink is added, no stray CR in the value
    out=$(sync_on "$lib" '[Interface]\r\nAddress = 10.9.9.5/32\r\n[Peer]\r\nAllowedIPs = 1.0.0.0/8, 2000::/3\r\n')
    [[ "$out" == *"RC=0"* && "$out" == *"Address = 10.9.9.5/32, ${SINK_PREFIX}::a09:905/128"* ]] || { echo "CRLF ($lib): $out"; return 1; }
    # a non-/24 tunnel subnet: the sink is derived from the client address alone
    out=$(sync_on "$lib" '[Interface]\nAddress = 172.16.200.9/32\n[Peer]\nAllowedIPs = 1.0.0.0/8, 2000::/3\n')
    [[ "$out" == *"RC=0"* && "$out" == *"Address = 172.16.200.9/32, ${SINK_PREFIX}::ac10:c809/128"* ]] || { echo "non-/24 ($lib): $out"; return 1; }
    # AllowedIPs split over two lines (wg sums them): 2000::/3 on the second one counts
    out=$(sync_on "$lib" '[Interface]\nAddress = 10.9.9.5/32\n[Peer]\nAllowedIPs = 1.0.0.0/8\nAllowedIPs = 2000::/3\n')
    [[ "$out" == *"RC=0"* && "$out" == *"${SINK_PREFIX}::a09:905/128"* ]] || { echo "multi-line AllowedIPs ($lib): $out"; return 1; }
    # 2000::/32 is not 2000::/3
    out=$(sync_on "$lib" '[Interface]\nAddress = 10.9.9.5/32\n[Peer]\nAllowedIPs = 1.0.0.0/8, 2000::/32\n')
    [[ "$out" == *"RC=0"* && "$out" != *"$SINK_PREFIX"* ]] || { echo "2000::/32 took a sink ($lib): $out"; return 1; }
    # a value sed would mangle is refused, the file stays as it was
    out=$(sync_on "$lib" '[Interface]\nAddress = 10.9.9.5/32&\n[Peer]\nAllowedIPs = 1.0.0.0/8, 2000::/3\n')
    [[ "$out" == *"RC=1"* && "$out" == *"Address = 10.9.9.5/32&"$'\n'* ]] || { echo "bad Address written ($lib): $out"; return 1; }
    # a short IPv4 or an impossible prefix is refused even when no sink is due
    out=$(sync_on "$lib" '[Interface]\nAddress = 10.9.9/32\n[Peer]\nAllowedIPs = 10.0.0.0/8\n')
    [[ "$out" == *"RC=1"* && "$out" == *"ERR:"* ]] || { echo "short IPv4 accepted ($lib): $out"; return 1; }
    out=$(sync_on "$lib" '[Interface]\nAddress = 10.9.9.5/99\n[Peer]\nAllowedIPs = 1.0.0.0/8, 2000::/3\n')
    [[ "$out" == *"RC=1"* && "$out" != *"$SINK_PREFIX"* ]] || { echo "/99 accepted ($lib): $out"; return 1; }
    out=$(sync_on "$lib" '[Interface]\nAddress = 10.9.9.5/33\n[Peer]\nAllowedIPs = 1.0.0.0/8, 2000::/3\n')
    [[ "$out" == *"RC=1"* ]] || { echo "/33 accepted ($lib): $out"; return 1; }
    # a failed write is a failure
    out=$(lr "$lib" "0.0.0.0/0" '
        printf "[Interface]\nAddress = 10.9.9.5/32\n[Peer]\nAllowedIPs = 1.0.0.0/8, 2000::/3\n" > "$AWG_DIR/h.conf"
        sed() { return 1; }
        _sync_v6_sink_address "$AWG_DIR/h.conf"; echo "RC=$?"')
    [[ "$out" == *"RC=1"* && "$out" == *"ERR:"* ]] || { echo "failed write reported as success ($lib): $out"; return 1; }
    # Address over two lines, the second a real IPv6: a hand-made layout, left alone with a warning
    out=$(sync_on "$lib" '[Interface]\nAddress = 10.9.9.5/32\nAddress = fd00::5/128\n[Peer]\nAllowedIPs = 1.0.0.0/8, 2000::/3\n')
    [[ "$out" == *"RC=0"* && "$out" != *"$SINK_PREFIX"* && "$out" == *"WARN:"* ]] || { echo "two Address lines ($lib): $out"; return 1; }
    # three addresses: not our layout, left alone with a warning
    out=$(sync_on "$lib" "[Interface]\nAddress = 10.9.9.5/32, ${SINK_PREFIX}::a09:905/128, fd00::1/128\n[Peer]\nAllowedIPs = 10.0.0.0/8\n")
    [[ "$out" == *"RC=0"* && "$out" == *"WARN:"* ]] || { echo "three addresses silently kept ($lib): $out"; return 1; }
    # no Address, no file: failures, each named
    out=$(sync_on "$lib" '[Interface]\n[Peer]\nAllowedIPs = 10.0.0.0/8\n')
    [[ "$out" == *"RC=1"* && "$out" == *"ERR:"* ]] || { echo "missing Address ($lib): $out"; return 1; }
    out=$(lr "$lib" "0.0.0.0/0" '_sync_v6_sink_address "$AWG_DIR/nope.conf"; echo "RC=$?"')
    [[ "$out" == *"RC=1"* && "$out" == *"ERR:"* ]] || { echo "missing file ($lib): $out"; return 1; }
}
@test "sync: hand-edited client files - CRLF, other subnets, split lines, bad values, both twins" {
    both sync_hand_edited
}

# --- the gap warning predicate ---

gap_cases() {
    local lib="$1" list out
    list=$(mode2_list)
    out=$(lr "$lib" "0.0.0.0/0" '
        export SERVER_HAS_NATIVE_IPV6=1
        _aip_full_tunnel_v6_gap "'"$list"', 2000::/3" && echo "G1=gap" || echo "G1=ok"
        _aip_full_tunnel_v6_gap "'"$list"', fddd:2c4:2c4:2c4::/64" && echo "G2=gap" || echo "G2=ok"
        _aip_full_tunnel_v6_gap "0.0.0.0/0, 2000::/32" && echo "G3=gap" || echo "G3=ok"
        _aip_full_tunnel_v6_gap "'"$list"', ::/0" && echo "G4=gap" || echo "G4=ok"
        _aip_full_tunnel_v6_gap "'"$list"'" && echo "G5=gap" || echo "G5=ok"')
    [[ "$out" == *"G1=ok"* ]] || { echo "2000::/3 treated as a gap ($lib): $out"; return 1; }
    [[ "$out" == *"G2=gap"* ]] || { echo "real gap not reported ($lib): $out"; return 1; }
    # 2000::/32 is one /32, not the global unicast space
    [[ "$out" == *"G3=gap"* ]] || { echo "2000::/32 taken for 2000::/3 ($lib): $out"; return 1; }
    # no false alarms: ::/0 covers IPv6, and an IPv4-only list is not this state
    [[ "$out" == *"G4=ok"* && "$out" == *"G5=ok"* ]] || { echo "false gap ($lib): $out"; return 1; }
}
@test "gap predicate: 2000::/3 counts as covering IPv6, a ULA-only part still does not, both twins" {
    both gap_cases
}

# --- vpn:// ---

inner_json() {
    python3 - "$1" <<'PY'
import base64, json, struct, sys, zlib
uri = open(sys.argv[1], encoding="utf-8").read().strip().replace("vpn://", "")
raw = base64.urlsafe_b64decode(uri + "=" * (-len(uri) % 4))
outer = json.loads(zlib.decompress(raw[4:]))
print(outer["containers"][0]["awg"]["last_config"])
PY
}

vpnuri_no_sink() {
    local lib="$1" out inner
    out=$(lr "$lib" "$(mode2_list)" '
        render_server_config >/dev/null 2>&1
        render_client_config c1 10.9.9.2 CLIENTPRIVKEYPLACEHOLDER SRVPUBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= 203.0.113.10 39743 || echo RC=91
        generate_vpn_uri c1; echo "RC=$?"')
    [[ "$out" == *"RC=0"* ]] || { echo "uri not created ($lib): $out"; return 1; }
    inner=$(inner_json "$(dir_of "$lib")/c1.vpnuri") || { echo "cannot decode ($lib)"; return 1; }
    [[ "$inner" == *'"client_ipv6":""'* ]] || { echo "sink leaked into client_ipv6 ($lib): $inner"; return 1; }
    [[ "$inner" == *'"client_ip":"10.9.9.2"'* ]] || { echo "client_ip ($lib)"; return 1; }
    [[ "$inner" == *'"2000::/3"'* ]] || { echo "route missing from allowed_ips ($lib)"; return 1; }
}
@test "vpn://: the sink is not passed as client_ipv6, the route is, both twins" {
    require_perl_zlib; require_python3
    both vpnuri_no_sink
}

# --- manage list ---

# list_run <lib> <JSON_OUTPUT> <VERBOSE_LIST> : three clients - a sink one, the
# same with CRLF line endings, a dual-stack one - through the real list_clients.
list_run() {
    local lib="$1" manage
    manage="${BATS_TEST_DIRNAME}/../${lib/awg_common/manage_amneziawg}"
    lr "$lib" "$(mode2_list)" '
        for n in s1:10.9.9.2 c1:10.9.9.3 d1:10.9.9.4; do
            printf "\n[Peer]\n#_Name = %s\nPublicKey = PK_%s\nAllowedIPs = %s/32\n" "${n%%:*}" "${n%%:*}" "${n#*:}" >> "$SERVER_CONF_FILE"
        done
        printf "[Interface]\nAddress = 10.9.9.2/32, '"$SINK_PREFIX"'::a09:902/128\n" > "$AWG_DIR/s1.conf"
        printf "[Interface]\r\nAddress = 10.9.9.3/32, '"$SINK_PREFIX"'::a09:903/128\r\n" > "$AWG_DIR/c1.conf"
        printf "[Interface]\nAddress = 10.9.9.4/32, fddd:2c4:2c4:2c4::4/128\n" > "$AWG_DIR/d1.conf"
        for f in json_escape json_out list_clients; do
            eval "$(awk -v f="$f" "\$0 ~ \"^\" f \"\\\\(\\\\)\" {p=1} p {print} p && /^\\}\$/ {exit}" "'"$manage"'")"
        done
        JSON_OUTPUT='"$2"' VERBOSE_LIST='"$3"' NO_COLOR=1
        awg() { return 1; }; format_remaining() { echo "-"; }
        list_clients; echo "RC=$?"'
}

list_hides_sink() {
    local lib="$1" out
    out=$(list_run "$lib" 1 0)
    [[ "$out" == *"RC=0"* ]] || { echo "list failed ($lib): $out"; return 1; }
    [[ "$out" == *'"name":"s1","ip":"10.9.9.2","client_ipv6":""'* ]] || { echo "sink in client_ipv6 ($lib): $out"; return 1; }
    [[ "$out" == *'"name":"c1","ip":"10.9.9.3","client_ipv6":""'* ]] || { echo "CRLF sink in client_ipv6 ($lib): $out"; return 1; }
    [[ "$out" == *'"name":"d1","ip":"10.9.9.4","client_ipv6":"fddd:2c4:2c4:2c4::4"'* ]] || { echo "dual-stack lost ($lib): $out"; return 1; }
    out=$(list_run "$lib" 0 1)
    [[ "$out" == *"RC=0"* ]] || { echo "list -v failed ($lib): $out"; return 1; }
    [[ "$out" != *"$SINK_PREFIX"* ]] || { echo "sink shown in the table ($lib): $out"; return 1; }
    [[ "$out" == *"10.9.9.4 / fddd:2c4:2c4:2c4::4"* ]] || { echo "dual-stack not shown ($lib): $out"; return 1; }
}
@test "list: the sink is not a client IPv6 address, in the table or in --json, both twins" {
    both list_hides_sink
}
