#!/usr/bin/env bats
# CLIENT_IPV6_DIRECT=1 (installer flag --client-ipv6-direct): IPv4 through the
# tunnel, the device's IPv6 directly, the LAN reachable - routing mode 2 without
# the IPv6 route it gets since v5.31.0 (2000::/3 plus the sink address since
# v5.36.2). Asked for in PR #260.
#
# Owner decisions: the key is for mode 2 only. Mode 1 keeps ::/0, because iOS
# AmneziaVPN does not bring up a bare 0.0.0.0/0 (the v5.18.1 fix), and the
# installer refuses the combination; in mode 3 there is no IPv6 route anyway.
# A plain regen takes OUR route away from clients already issued (2000::/3, or
# the older ::/0, next to the server's own list) and leaves hand-made routes
# alone, the same way it swapped ::/0 for 2000::/3 in v5.36.2.
#
# The library scenarios run the REAL library in a fresh bash, once per twin.
#
# shellcheck disable=SC2154

SINK_PREFIX="fddd:2c4:2c4:ffff"

require_flock() { command -v flock &>/dev/null || skip "flock not available"; }

mode2_list() {
    sed -n 's/^[[:space:]]*ALLOWED_IPS="\(1\.0\.0\.0\/8,.*\)"$/\1/p' \
        "${BATS_TEST_DIRNAME}/../install_amneziawg.sh" | head -1
}

dir_of() { echo "$BATS_TEST_TMPDIR/s-$(basename "$1" .sh)"; }

# lr <lib> <server ALLOWED_IPS> <extra init lines> <snippet>
lr() {
    local lib="$1" aips="$2" initx="$3" snippet="$4" d
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
        [[ -n "$initx" ]] && printf '%s\n' "$initx"
    } > "$d/awgsetup_cfg.init"
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

ON="export CLIENT_IPV6_DIRECT=1"

# --- render ---

render_direct() {
    local lib="$1" list out
    list=$(mode2_list)
    out=$(lr "$lib" "$list" "$ON" 'render_client_config c1 10.9.9.2 FAKEPRIV FAKEPUB 203.0.113.10 39743; echo "RC=$?"')
    [[ "$out" == *"RC=0"* ]] || { echo "render failed ($lib): $out"; return 1; }
    [ "$(conf_line "$lib" AllowedIPs c1)" = "AllowedIPs = $list" ] || { echo "routes ($lib): $(conf_line "$lib" AllowedIPs c1)"; return 1; }
    [ "$(conf_line "$lib" Address c1)" = "Address = 10.9.9.2/32" ] || { echo "address ($lib): $(conf_line "$lib" Address c1)"; return 1; }
}
@test "render: with the key, mode 2 gets no IPv6 route and no sink address, both twins" {
    both render_direct
}

render_mode1_kept() {
    local lib="$1" out
    out=$(lr "$lib" "0.0.0.0/0" "$ON" 'render_client_config c1 10.9.9.4 FAKEPRIV FAKEPUB 203.0.113.10 39743; echo "RC=$?"')
    [[ "$out" == *"RC=0"* ]] || { echo "render failed ($lib): $out"; return 1; }
    [ "$(conf_line "$lib" AllowedIPs c1)" = "AllowedIPs = 0.0.0.0/0, ::/0" ] || { echo "mode 1 lost ::/0 ($lib): $(conf_line "$lib" AllowedIPs c1)"; return 1; }
}
@test "render: mode 1 keeps ::/0 even with the key (iOS AmneziaVPN needs it), both twins" {
    both render_mode1_kept
}

render_only_server_list() {
    local lib="$1" out
    # mode 3 with a list that happens to be a full tunnel: the key is for mode 2 only
    out=$(lr "$lib" "0.0.0.0/1, 128.0.0.0/1" "$ON
export ALLOWED_IPS_MODE=3" 'render_client_config c1 10.9.9.2 FAKEPRIV FAKEPUB 203.0.113.10 39743; echo "RC=$?"')
    [[ "$out" == *"RC=0"* ]] || { echo "render failed ($lib): $out"; return 1; }
    [ "$(conf_line "$lib" AllowedIPs c1)" = "AllowedIPs = 0.0.0.0/1, 128.0.0.0/1, 2000::/3" ] || { echo "mode 3 lost the route ($lib): $(conf_line "$lib" AllowedIPs c1)"; return 1; }
    # a hand-made full tunnel through --allowed-ips on a mode 2 server keeps the route
    out=$(lr "$lib" "$(mode2_list)" "$ON" '
        export CLIENT_ALLOWED_IPS="0.0.0.0/1, 128.0.0.0/1"
        render_client_config c1 10.9.9.3 FAKEPRIV FAKEPUB 203.0.113.10 39743; echo "RC=$?"')
    [[ "$out" == *"RC=0"* ]] || { echo "render failed ($lib): $out"; return 1; }
    [ "$(conf_line "$lib" AllowedIPs c1)" = "AllowedIPs = 0.0.0.0/1, 128.0.0.0/1, 2000::/3" ] || { echo "hand-made list lost the route ($lib): $(conf_line "$lib" AllowedIPs c1)"; return 1; }
}
@test "render: the key touches only the server's mode 2 list, not mode 3 or a hand-made full tunnel, both twins" {
    both render_only_server_list
}

render_env_ignored() {
    local lib="$1" list out
    list=$(mode2_list)
    out=$(CLIENT_IPV6_DIRECT=1 lr "$lib" "$list" "" 'render_client_config c1 10.9.9.2 FAKEPRIV FAKEPUB 203.0.113.10 39743; echo "RC=$?"')
    [[ "$out" == *"RC=0"* ]] || { echo "render failed ($lib): $out"; return 1; }
    [ "$(conf_line "$lib" AllowedIPs c1)" = "AllowedIPs = $list, 2000::/3" ] || { echo "environment changed the routes ($lib): $(conf_line "$lib" AllowedIPs c1)"; return 1; }
}
@test "render: the key lives in the init file only, the environment does not switch it on, both twins" {
    both render_env_ignored
}

render_bad_value() {
    local lib="$1" list out
    list=$(mode2_list)
    out=$(lr "$lib" "$list" "export CLIENT_IPV6_DIRECT=yes" 'render_client_config c1 10.9.9.2 FAKEPRIV FAKEPUB 203.0.113.10 39743; echo "RC=$?"')
    [[ "$out" == *"RC=0"* ]] || { echo "render failed ($lib): $out"; return 1; }
    [ "$(conf_line "$lib" AllowedIPs c1)" = "AllowedIPs = $list, 2000::/3" ] || { echo "routes ($lib): $(conf_line "$lib" AllowedIPs c1)"; return 1; }
    [[ "$out" == *"WARN:"*"CLIENT_IPV6_DIRECT"* ]] || { echo "bad value not named ($lib): $out"; return 1; }
}
@test "render: a value other than 0 or 1 is named and the route stays, both twins" {
    both render_bad_value
}

# --- regen ---

# regen_run <lib> <init extra> <client AllowedIPs> <client Address> [extra snippet]
regen_run() {
    local lib="$1" initx="$2" caips="$3" caddr="$4" extra="${5:-}"
    lr "$lib" "$(mode2_list)" "$initx" '
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

regen_strips_ours() {
    local lib="$1" list out v6
    list=$(mode2_list)
    for v6 in "2000::/3" "::/0"; do
        # as in production: regen gets the key from the init file itself (load_awg_params), not from the caller
        out=$(regen_run "$lib" "$ON" "$list, $v6" "10.9.9.20/32, ${SINK_PREFIX}::a09:914/128" 'unset CLIENT_IPV6_DIRECT ALLOWED_IPS_MODE ALLOWED_IPS')
        [[ "$out" == *"RC=0"* && "$out" == *"RC2=0"* ]] || { echo "regen failed ($lib, $v6): $out"; return 1; }
        [ "$(conf_line "$lib" AllowedIPs r1)" = "AllowedIPs = $list" ] || { echo "route kept ($lib, $v6): $(conf_line "$lib" AllowedIPs r1)"; return 1; }
        [ "$(conf_line "$lib" Address r1)" = "Address = 10.9.9.20/32" ] || { echo "sink kept ($lib, $v6): $(conf_line "$lib" Address r1)"; return 1; }
        [[ "$out" == *"LOG:"*"CLIENT_IPV6_DIRECT"* ]] || { echo "not reported ($lib, $v6): $out"; return 1; }
    done
}
@test "regen: with the key, our 2000::/3 or old ::/0 next to the server list is taken away with the sink, both twins" {
    require_flock
    both regen_strips_ours
}

regen_keeps_hand_made() {
    local lib="$1" list out
    list=$(mode2_list)
    # an extra IPv6 network of the user's own
    out=$(regen_run "$lib" "$ON" "$list, 2001:db8::/32" "10.9.9.20/32")
    [[ "$out" == *"RC=0"* ]] || { echo "regen failed ($lib): $out"; return 1; }
    [ "$(conf_line "$lib" AllowedIPs r1)" = "AllowedIPs = $list, 2001:db8::/32" ] || { echo "own IPv6 route touched ($lib): $(conf_line "$lib" AllowedIPs r1)"; return 1; }
    # an IPv4 part that is not the server list: not ours
    out=$(regen_run "$lib" "$ON" "0.0.0.0/1, 128.0.0.0/1, ::/0" "10.9.9.20/32")
    [[ "$out" == *"RC=0"* ]] || { echo "regen failed ($lib): $out"; return 1; }
    [ "$(conf_line "$lib" AllowedIPs r1)" = "AllowedIPs = 0.0.0.0/1, 128.0.0.0/1, ::/0" ] || { echo "hand-made full tunnel touched ($lib): $(conf_line "$lib" AllowedIPs r1)"; return 1; }
    # kept, but a route of our shape next to a list that is not the server one is named
    [[ "$out" == *"WARN:"*"reset-routes"* ]] || { echo "kept silently ($lib): $out"; return 1; }
    # the server list plus a tunnel subnet (isolation changed later) and 2000::/3: kept and named
    out=$(regen_run "$lib" "$ON" "$list, 10.9.9.0/24, 2000::/3" "10.9.9.20/32")
    [ "$(conf_line "$lib" AllowedIPs r1)" = "AllowedIPs = $list, 10.9.9.0/24, 2000::/3" ] || { echo "not-ours stripped ($lib)"; return 1; }
    [[ "$out" == *"WARN:"*"reset-routes"* ]] || { echo "kept silently ($lib): $out"; return 1; }
    # a real split
    out=$(regen_run "$lib" "$ON" "10.0.0.0/8" "10.9.9.20/32")
    [ "$(conf_line "$lib" AllowedIPs r1)" = "AllowedIPs = 10.0.0.0/8" ] || { echo "split touched ($lib)"; return 1; }
    [[ "$out" != *"reset-routes"* ]] || { echo "split warned about ($lib): $out"; return 1; }
}
@test "regen: with the key, hand-made routes stay as they are, both twins" {
    require_flock
    both regen_keeps_hand_made
}

regen_without_key() {
    local lib="$1" list out
    list=$(mode2_list)
    out=$(regen_run "$lib" "" "$list, 2000::/3" "10.9.9.20/32, ${SINK_PREFIX}::a09:914/128")
    [[ "$out" == *"RC=0"* ]] || { echo "regen failed ($lib): $out"; return 1; }
    [ "$(conf_line "$lib" AllowedIPs r1)" = "AllowedIPs = $list, 2000::/3" ] || { echo "route lost without the key ($lib)"; return 1; }
    out=$(regen_run "$lib" "export CLIENT_IPV6_DIRECT=0" "$list, 2000::/3" "10.9.9.20/32, ${SINK_PREFIX}::a09:914/128")
    [ "$(conf_line "$lib" AllowedIPs r1)" = "AllowedIPs = $list, 2000::/3" ] || { echo "route lost with the key at 0 ($lib)"; return 1; }
}
@test "regen: without the key or with 0 nothing changes, both twins" {
    require_flock
    both regen_without_key
}

regen_turned_off() {
    local lib="$1" list out
    list=$(mode2_list)
    # the key back at 0: a plain regen gives the route and the sink back
    out=$(regen_run "$lib" "export CLIENT_IPV6_DIRECT=0" "$list" "10.9.9.20/32")
    [[ "$out" == *"RC=0"* && "$out" == *"RC2=0"* ]] || { echo "regen failed ($lib): $out"; return 1; }
    [ "$(conf_line "$lib" AllowedIPs r1)" = "AllowedIPs = $list, 2000::/3" ] || { echo "route not back ($lib): $(conf_line "$lib" AllowedIPs r1)"; return 1; }
    [ "$(conf_line "$lib" Address r1)" = "Address = 10.9.9.20/32, ${SINK_PREFIX}::a09:914/128" ] || { echo "sink not back ($lib): $(conf_line "$lib" Address r1)"; return 1; }
}
@test "regen: switching the key back to 0 gives the route and the sink back with a plain regen, both twins" {
    require_flock
    both regen_turned_off
}

regen_reset_routes() {
    local lib="$1" list out
    list=$(mode2_list)
    out=$(regen_run "$lib" "$ON" "10.0.0.0/8" "10.9.9.20/32" 'export AWG_REGEN_RESET_ROUTES=1')
    [[ "$out" == *"RC=0"* ]] || { echo "regen failed ($lib): $out"; return 1; }
    [ "$(conf_line "$lib" AllowedIPs r1)" = "AllowedIPs = $list" ] || { echo "routes ($lib): $(conf_line "$lib" AllowedIPs r1)"; return 1; }
    [ "$(conf_line "$lib" Address r1)" = "Address = 10.9.9.20/32" ] || { echo "address ($lib)"; return 1; }
}
@test "regen --reset-routes: with the key, back to the server list without IPv6, both twins" {
    require_flock
    both regen_reset_routes
}

# --- modify ---

mod_quiet() {
    local lib="$1" manage list out
    manage="${lib/awg_common/manage_amneziawg}"
    list=$(mode2_list)
    out=$(lr "$lib" "$list" "$ON" '
        cat > "$AWG_DIR/m1.conf" << EOF
[Interface]
PrivateKey = FAKEPRIV
Address = 10.9.9.40/32
DNS = 1.1.1.1, 1.0.0.1
MTU = 1280

[Peer]
PublicKey = SRVPUB
Endpoint = 203.0.113.10:39743
AllowedIPs = 10.0.0.0/8
PersistentKeepalive = 33
EOF
        eval "$(awk "/^modify_client\\(\\) \\{/,/^\\}/" "'"$BATS_TEST_DIRNAME/../$manage"'")"
        escape_sed() { printf "%s" "$1" | sed "s/[&\\\\/]/\\\\&/g"; }
        apply_config() { return 0; }; generate_qr() { return 0; }; generate_vpn_uri() { return 0; }; generate_qr_vpnuri() { return 0; }
        # manage does not load the init file before modify: the key must be read there
        unset CLIENT_IPV6_DIRECT
        modify_client m1 AllowedIPs "'"$list"'"; echo "RC=$?"
        modify_client m1 AllowedIPs "0.0.0.0/0"; echo "RC1=$?"
        modify_client m1 AllowedIPs "0.0.0.0/1, 128.0.0.0/1"; echo "RC2=$?"')
    [[ "$out" == *"RC=0"* ]] || { echo "modify failed ($lib): $out"; return 1; }
    [[ "$out" == *"RC1=0"* ]] || { echo "modify to 0.0.0.0/0 failed ($lib): $out"; return 1; }
    [[ "$out" == *"RC2=0"* ]] || { echo "modify to a hand-made list failed ($lib): $out"; return 1; }
    # the mode-2 list: the chosen setup, no warning; 0.0.0.0/0 still warns (iOS),
    # and so does a hand-made full tunnel, which the key does not cover
    [ "$(grep -c "WARN:.*regen" <<< "$out")" -eq 2 ] || { echo "warnings ($lib): $out"; return 1; }
    [[ "${out%%RC=*}" != *"WARN:"*"regen"* ]] || { echo "warns about the chosen setup ($lib): $out"; return 1; }
}
@test "modify: with the key, the server list without IPv6 is the chosen setup, no warning, both twins" {
    require_flock
    both mod_quiet
}

# --- installer ---

INSTALLERS=(install_amneziawg.sh install_amneziawg_en.sh)

# inst <installer> <snippet>: configure_client_ipv6_direct from the installer
# with an exiting die and loud logs.
inst() {
    local f="$BATS_TEST_DIRNAME/../$1"
    timeout 30 bash -c '
        die() { echo "DIE: $*"; exit 1; }
        log() { echo "LOG: $*"; }; log_warn() { echo "WARN: $*"; }; log_error() { echo "ERR: $*"; }
        eval "$(awk "/^configure_client_ipv6_direct\\(\\) \\{/,/^\\}/" "$1")"
        declare -F configure_client_ipv6_direct >/dev/null || { echo "NOFUNC"; exit 3; }
        CONFIG_FILE=/root/awg/awgsetup_cfg.init; MANAGE_SCRIPT_PATH=/root/awg/manage_amneziawg.sh
        eval "$2"
        configure_client_ipv6_direct; echo "RC=$? V=${CLIENT_IPV6_DIRECT:-unset}"
    ' _ "$f" "$2" 2>&1 || true
}

@test "installer: the step 0 check allows mode 2, refuses mode 1 and a dual-stack tunnel, both twins" {
    local s out
    for s in "${INSTALLERS[@]}"; do
        out=$(inst "$s" 'ALLOWED_IPS_MODE=2; ALLOW_IPV6_TUNNEL=0; CLI_CLIENT_IPV6_DIRECT=1; config_exists=0')
        [[ "$out" == *"RC=0 V=1"* && "$out" == *"WARN:"* ]] || { echo "$s mode 2: $out"; return 1; }
        out=$(inst "$s" 'ALLOWED_IPS_MODE=1; ALLOW_IPV6_TUNNEL=0; CLI_CLIENT_IPV6_DIRECT=1; config_exists=0')
        [[ "$out" == *"DIE:"*"--route-amnezia"* && "$out" != *"RC=0"* ]] || { echo "$s mode 1 accepted: $out"; return 1; }
        out=$(inst "$s" 'ALLOWED_IPS_MODE=2; ALLOW_IPV6_TUNNEL=1; CLI_CLIENT_IPV6_DIRECT=1; config_exists=0')
        [[ "$out" == *"DIE:"*"--allow-ipv6-tunnel"* ]] || { echo "$s dual-stack accepted: $out"; return 1; }
        out=$(inst "$s" 'ALLOWED_IPS_MODE=3; ALLOW_IPV6_TUNNEL=0; CLI_CLIENT_IPV6_DIRECT=1; config_exists=0')
        [[ "$out" == *"RC=0 V=1"* && "$out" == *"WARN:"* ]] || { echo "$s mode 3: $out"; return 1; }
    done
}

@test "installer: a saved key is kept, a bad saved value stops, existing clients get the regen hint, both twins" {
    local s out
    for s in "${INSTALLERS[@]}"; do
        out=$(inst "$s" 'ALLOWED_IPS_MODE=2; ALLOW_IPV6_TUNNEL=0; CLIENT_IPV6_DIRECT=1; config_exists=1')
        [[ "$out" == *"RC=0 V=1"* && "$out" == *"regen"* ]] || { echo "$s saved key: $out"; return 1; }
        out=$(inst "$s" 'ALLOWED_IPS_MODE=2; ALLOW_IPV6_TUNNEL=0; CLIENT_IPV6_DIRECT=yes; CLI_CLIENT_IPV6_DIRECT=1')
        [[ "$out" == *"DIE:"*"CLIENT_IPV6_DIRECT"* ]] || { echo "$s bad value hidden by the flag: $out"; return 1; }
        out=$(inst "$s" 'ALLOWED_IPS_MODE=1; ALLOW_IPV6_TUNNEL=0; CLIENT_IPV6_DIRECT=0')
        [[ "$out" == *"RC=0 V=0"* && "$out" != *"WARN:"* ]] || { echo "$s key off: $out"; return 1; }
    done
}

@test "installer: flag parsed, listed in help, key read and written to the init file, check called at step 0, both twins" {
    local s f body
    for s in "${INSTALLERS[@]}"; do
        f="$BATS_TEST_DIRNAME/../$s"
        grep -qF -- '--client-ipv6-direct) CLI_CLIENT_IPV6_DIRECT=1 ;;' "$f" || { echo "$s: flag not parsed"; return 1; }
        sed -n '/^show_help() {/,/^}/p' "$f" | grep -qF -- '--client-ipv6-direct' || { echo "$s: not in help"; return 1; }
        sed -n '/^safe_load_config() {$/,/^}$/p' "$f" | grep -q 'CLIENT_IPV6_DIRECT' || { echo "$s: not read from init"; return 1; }
        grep -qF 'export CLIENT_IPV6_DIRECT=${CLIENT_IPV6_DIRECT:-0}' "$f" || { echo "$s: not written to init"; return 1; }
        body=$(sed -n '/^initialize_setup() {/,/^}/p' "$f")
        grep -q '^[[:space:]]*configure_client_ipv6_direct$' <<< "$body" || { echo "$s: not called in initialize_setup"; return 1; }
    done
    for s in awg_common.sh awg_common_en.sh; do
        sed -n '/^safe_load_config() {$/,/^}$/p' "$BATS_TEST_DIRNAME/../$s" | grep -q 'CLIENT_IPV6_DIRECT' || { echo "$s: not read from init"; return 1; }
    done
}

@test "parsers: an unrecognised CLIENT_IPV6_DIRECT line is named, not skipped (libraries and installers)" {
    local src form err
    for src in awg_common.sh awg_common_en.sh install_amneziawg.sh install_amneziawg_en.sh; do
        eval "$(sed -n '/^safe_load_config() {$/,/^}$/p' "$BATS_TEST_DIRNAME/../$src")"
        log_warn() { printf 'WARN:%s\n' "$1" >&2; }
        for form in 'CLIENT_IPV6_DIRECT = 0' '  export CLIENT_IPV6_DIRECT=0' 'client_ipv6_direct=0'; do
            printf 'export AWG_PORT=39743\n%s\n' "$form" > "$BATS_TEST_TMPDIR/init"
            safe_load_config "$BATS_TEST_TMPDIR/init" 2>"$BATS_TEST_TMPDIR/err"
            err=$(cat "$BATS_TEST_TMPDIR/err")
            [[ "$err" == *WARN:*CLIENT_IPV6_DIRECT* ]] || { echo "$src: no warning for '$form'"; return 1; }
        done
        printf 'export AWG_PORT=39743\nexport CLIENT_IPV6_DIRECT=1\n' > "$BATS_TEST_TMPDIR/init"
        safe_load_config "$BATS_TEST_TMPDIR/init" 2>"$BATS_TEST_TMPDIR/err"
        [ ! -s "$BATS_TEST_TMPDIR/err" ] || { echo "$src: warning on the canonical line: $(cat "$BATS_TEST_TMPDIR/err")"; return 1; }
        [ "${CLIENT_IPV6_DIRECT:-}" = "1" ] || { echo "$src: canonical line not read"; return 1; }
    done
}

@test "installer: the step 0 check runs after the routing mode and the IPv6 tunnel are final, and the flag returns an unfinished install to step 4, both twins" {
    local s f body call tun mode
    for s in "${INSTALLERS[@]}"; do
        f="$BATS_TEST_DIRNAME/../$s"
        body=$(sed -n '/^initialize_setup() {/,/^}/p' "$f")
        call=$(grep -n '^[[:space:]]*configure_client_ipv6_direct$' <<< "$body" | head -1 | cut -d: -f1)
        tun=$(grep -n '^[[:space:]]*configure_ipv6_tunnel$' <<< "$body" | head -1 | cut -d: -f1)
        mode=$(grep -n 'if \[\[ -z "\$ALLOWED_IPS" \]\]; then configure_routing_mode; fi' <<< "$body" | tail -1 | cut -d: -f1)
        [ -n "$call" ] && [ -n "$tun" ] && [ -n "$mode" ] || { echo "$s: anchors not found ($call/$tun/$mode)"; return 1; }
        [ "$call" -gt "$tun" ] && [ "$call" -gt "$mode" ] || { echo "$s: check at $call runs before the tunnel ($tun) or mode ($mode) is final"; return 1; }
        grep -qF '|| [[ "${CLI_CLIENT_IPV6_DIRECT:-0}" -eq 1 ]]; }; then' "$f" || { echo "$s: flag does not return an unfinished install to step 4"; return 1; }
    done
}