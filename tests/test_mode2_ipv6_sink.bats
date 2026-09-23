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
    AWG_DIR="$d" timeout 60 bash -c '
        export CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init" SERVER_CONF_FILE="$AWG_DIR/awg0.conf"
        export KEYS_DIR="$AWG_DIR/keys" EXPIRY_DIR="$AWG_DIR/expiry"
        log() { :; }; log_warn() { echo "WARN: $*" >&2; }; log_error() { echo "ERR: $*" >&2; }; log_debug() { :; }
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
        echo "MIG=$(_append_ipv6_full_tunnel_route "$L, ::/0")"
        echo "IDEM=$(_append_ipv6_full_tunnel_route "$L, 2000::/3")"
        echo "M1V6=$(_append_ipv6_full_tunnel_route "0.0.0.0/0, ::/0")"
        echo "SPLIT=$(_append_ipv6_full_tunnel_route "10.0.0.0/8, 192.168.0.0/16")"
        echo "SPLITV6=$(_append_ipv6_full_tunnel_route "10.0.0.0/8, ::/0")"
        echo "DUAL=$(_append_ipv6_full_tunnel_route "$L, fddd:2c4:2c4:2c4::/64")"
        echo "MIXED=$(_append_ipv6_full_tunnel_route "$L, ::/0, fddd:2c4:2c4:2c4::/64")"')
    [[ "$out" == *"M2=$list, 2000::/3"$'\n'* ]] || { echo "mode 2 ($lib): $out"; return 1; }
    [[ "$out" == *"M1=0.0.0.0/0, ::/0"$'\n'* ]] || { echo "mode 1 ($lib): $out"; return 1; }
    # A client issued by v5.31-v5.36 carries our own ::/0 - a plain regen must deliver the fix.
    [[ "$out" == *"MIG=$list, 2000::/3"$'\n'* ]] || { echo "migration ($lib): $out"; return 1; }
    [[ "$out" == *"IDEM=$list, 2000::/3"$'\n'* ]] || { echo "not idempotent ($lib): $out"; return 1; }
    [[ "$out" == *"M1V6=0.0.0.0/0, ::/0"$'\n'* ]] || { echo "mode 1 with ::/0 changed ($lib): $out"; return 1; }
    [[ "$out" == *"SPLIT=10.0.0.0/8, 192.168.0.0/16"$'\n'* ]] || { echo "split changed ($lib): $out"; return 1; }
    # A split list someone gave ::/0 by hand is theirs: not a full tunnel, not touched.
    [[ "$out" == *"SPLITV6=10.0.0.0/8, ::/0"$'\n'* ]] || { echo "hand-made split touched ($lib): $out"; return 1; }
    [[ "$out" == *"DUAL=$list, fddd:2c4:2c4:2c4::/64"$'\n'* ]] || { echo "dual-stack touched ($lib): $out"; return 1; }
    [[ "$out" == *"MIXED=$list, ::/0, fddd:2c4:2c4:2c4::/64"* ]] || { echo "mixed IPv6 part touched ($lib): $out"; return 1; }
}
@test "append: list gets 2000::/3, mode 1 keeps ::/0, an old ::/0 on the list is migrated, both twins" {
    both append_cases
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

# --- modify ---

# mod_run <lib> <client AllowedIPs> <client Address> <new AllowedIPs>
mod_run() {
    local lib="$1" caips="$2" caddr="$3" newv="$4" manage
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
    # a dual-stack client: its real IPv6 address is never touched
    out=$(mod_run "$lib" "$list, fddd:2c4:2c4:2c4::/64" "10.9.9.40/32, fddd:2c4:2c4:2c4::40/128" "$list, 2000::/3")
    [ "$(conf_line "$lib" Address m1)" = "Address = 10.9.9.40/32, fddd:2c4:2c4:2c4::40/128" ] || { echo "dual-stack address touched ($lib): $(conf_line "$lib" Address m1)"; return 1; }
}
@test "modify AllowedIPs: the sink address follows the routes, dual-stack untouched, both twins" {
    require_flock
    both modify_follows
}

# --- the gap warning predicate ---

gap_cases() {
    local lib="$1" list out
    list=$(mode2_list)
    out=$(lr "$lib" "0.0.0.0/0" '
        export SERVER_HAS_NATIVE_IPV6=1
        _aip_full_tunnel_v6_gap "'"$list"', 2000::/3" && echo "G1=gap" || echo "G1=ok"
        _aip_full_tunnel_v6_gap "'"$list"', fddd:2c4:2c4:2c4::/64" && echo "G2=gap" || echo "G2=ok"')
    [[ "$out" == *"G1=ok"* ]] || { echo "2000::/3 treated as a gap ($lib): $out"; return 1; }
    [[ "$out" == *"G2=gap"* ]] || { echo "real gap not reported ($lib): $out"; return 1; }
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
