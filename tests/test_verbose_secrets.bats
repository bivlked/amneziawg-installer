#!/usr/bin/env bats
# --verbose must not print key material.
#
# The installer runs with set -x under --verbose, and manage runs traced under
# `bash -x`. Tracing prints every assignment, command argument, env prefix and
# [[ ]] operand with values expanded, so a function that holds a private key, a
# preshared key or a vpn:// link in a variable printed it to the terminal. People
# paste that output into issues when they ask for help.
#
# Every case runs one library function in a fresh shell for both twins, first
# without tracing (the reference: status and files), then under `exec 2>&1; set -x`,
# and asserts: no secret value in the output, xtrace still on afterwards, the same
# status, and the same files written. Stub binaries return fixed secret-shaped
# values, so a leak is a plain substring match.

SRV_PRIV="SRVPRIVSECRETAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
CLI_PRIV="CLIPRIVSECRETAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
PSK_VAL="PSKSECRETVALUEAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
HPK_VAL="HPKSECRETVALUEAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

dir_of() { echo "$BATS_TEST_TMPDIR/vs-$(basename "$1" .sh)-$2"; }

_stubs() {
    local bin="$1"
    mkdir -p "$bin"
    cat > "$bin/awg" <<EOF
#!/usr/bin/env bash
echo "awg \$1" >> "\${AWG_DIR}/.calls"
case "\$1" in
    genkey) if [[ -f "\${AWG_DIR}/.next_genkey" ]]; then cat "\${AWG_DIR}/.next_genkey"; else echo "$CLI_PRIV"; fi ;;
    pubkey) read -r k; printf 'PUB%s\n' "\${#k}xPUBLICKEYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ;;
    genpsk) echo "$PSK_VAL" ;;
    syncconf) cat > /dev/null; exit 0 ;;
    *) exit 0 ;;
esac
EOF
    cat > "$bin/awg-quick" <<EOF
#!/usr/bin/env bash
echo "awg-quick \$1" >> "\${AWG_DIR}/.calls"
if [[ "\$1" == strip ]]; then
    printf '[Interface]\nPrivateKey = %s\nListenPort = 39743\nHeaderProtectionKey = %s\n\n[Peer]\nPublicKey = PEERPUB\nPresharedKey = %s\nAllowedIPs = 10.9.9.2/32\n' "$SRV_PRIV" "$HPK_VAL" "$PSK_VAL"
fi
exit 0
EOF
    printf '#!/usr/bin/env bash\ncase "$*" in *"link show dev eth0"*) exit 0 ;; esac\nexit 0\n' > "$bin/ip"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/systemctl"
    cat > "$bin/qrencode" <<'EOF'
#!/usr/bin/env bash
echo "qrencode" >> "${AWG_DIR}/.calls"
out=""
while (( $# > 0 )); do case "$1" in -o) out="$2"; shift 2 ;; -t) shift 2 ;; *) shift ;; esac; done
cat > "${out:-/dev/null}"
EOF
    chmod +x "$bin"/*
}

_init() {
    local d="$1"
    cat > "$d/awgsetup_cfg.init" <<'EOF'
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
export AWG_ENDPOINT='203.0.113.10'
export AWG_PROTOCOL='2.0'
EOF
}

_server_conf() {
    local d="$1"
    cat > "$d/awg0.conf" <<EOF
[Interface]
PrivateKey = ${SRV_PRIV}
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
EOF
}

# lib_run <lib> <workdir> <setup snippet> <call snippet> [traced 0|1]
lib_run() {
    local lib="$1" d="$2" setup="$3" call="$4" traced="${5:-0}"
    _stubs "$d/bin"
    PATH="$d/bin:$PATH" AWG_DIR="$d" AWG_TRACED="$traced" timeout 60 bash -c '
        export CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init" SERVER_CONF_FILE="$AWG_DIR/awg0.conf"
        export KEYS_DIR="$AWG_DIR/keys" EXPIRY_DIR="$AWG_DIR/expiry" AWG_MAIN_NIC=eth0
        mkdir -p "$KEYS_DIR" "$EXPIRY_DIR"
        log() { :; }; log_warn() { :; }; log_error() { echo "ERR: $*"; }; log_debug() { :; }
        source "$1" >/dev/null 2>&1 || true
        eval "$2"
        if [[ "$AWG_TRACED" == 1 ]]; then
            exec 2>&1
            set -x
            eval "$3"; rc=$?
            case $- in *x*) echo XTRACE_STILL_ON ;; esac
            set +x
        else
            eval "$3"; rc=$?
        fi
        echo "RC=$rc"
    ' _ "$lib" "$setup" "$call"
}

# listing <dir>: file names and sizes the call left behind (stubs and registries excluded).
listing() {
    (cd "$1" && find . -type f ! -path './bin/*' ! -name '.awg_temp_registry.*' ! -name '.awg_config.lock*' \
        -printf '%p %s\n' | LC_ALL=C sort)
}

# check_fn <lib> <label> <setup> <call> [extra secret...]
check_fn() {
    local lib="$1" label="$2" setup="$3" call="$4"; shift 4
    local ref="$(dir_of "$lib" "$label")-ref" tr="$(dir_of "$lib" "$label")-tr" ref_out tr_out ref_rc tr_rc s
    rm -rf "$ref" "$tr"; mkdir -p "$ref" "$tr"
    ref_out=$(lib_run "$lib" "$ref" "$setup" "$call" 0)
    tr_out=$(lib_run "$lib" "$tr" "$setup" "$call" 1)
    ref_rc=$(grep -o 'RC=[0-9]*' <<< "$ref_out" | tail -1)
    tr_rc=$(grep -o 'RC=[0-9]*' <<< "$tr_out" | tail -1)
    [ -n "$ref_rc" ] || { echo "$label ($lib): the reference run did not finish: $ref_out"; return 1; }
    [ "$ref_rc" = "$tr_rc" ] || { echo "$label ($lib): status differs under set -x: $ref_rc vs $tr_rc"; echo "$tr_out" | tail -20; return 1; }
    [[ "$tr_out" == *XTRACE_STILL_ON* ]] || { echo "$label ($lib): xtrace was not restored"; return 1; }
    # Only what tracing added counts: a line printed identically without tracing is the
    # function's own output, not the trace (unmasked systemctl status is tracked apart).
    local tr_only
    tr_only=$(grep -vxF -f <(printf '%s\n' "$ref_out") <<< "$tr_out" || true)
    for s in "$SRV_PRIV" "$CLI_PRIV" "$PSK_VAL" "$HPK_VAL" "$@"; do
        [ -n "$s" ] || continue
        if [[ "$tr_only" == *"$s"* ]]; then
            echo "$label ($lib): secret '${s:0:12}...' in the trace:"
            grep -n -F "${s:0:12}" <<< "$tr_only" | head -5
            return 1
        fi
    done
    [ "$(listing "$ref")" = "$(listing "$tr")" ] || { echo "$label ($lib): files differ under set -x"; diff <(listing "$ref") <(listing "$tr"); return 1; }
    [ "$(cat "$ref/.calls" 2>/dev/null)" = "$(cat "$tr/.calls" 2>/dev/null)" ] || { echo "$label ($lib): external calls differ under set -x (did the body run twice?)"; diff <(cat "$ref/.calls" 2>/dev/null) <(cat "$tr/.calls" 2>/dev/null); return 1; }
    CHECK_REF_OUT="$ref_out"
    CHECK_REF_DIR="$ref"
}

both() {
    local seen=0 lib
    for lib in "$BATS_TEST_DIRNAME/../awg_common.sh" "$BATS_TEST_DIRNAME/../awg_common_en.sh"; do
        "$1" "$lib" || return 1
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}

v_server_keys() {
    check_fn "$1" server_keys 'printf "%s\n" "'"$SRV_PRIV"'" > "$AWG_DIR/.next_genkey"' 'generate_server_keys' || return 1
    [[ "$CHECK_REF_OUT" == *"RC=0"* ]] || { echo "server keys were not generated without tracing ($1): $CHECK_REF_OUT"; return 1; }
}
@test "verbose: generate_server_keys keeps the server private key out of the trace, both twins" {
    both v_server_keys
}

v_keypair() {
    check_fn "$1" keypair ':' 'generate_keypair my_phone' || return 1
    [[ "$CHECK_REF_OUT" == *"RC=0"* ]] || { echo "the keypair was not generated without tracing ($1): $CHECK_REF_OUT"; return 1; }
}
@test "verbose: generate_keypair keeps the client private key out of the trace, both twins" {
    both v_keypair
}

v_pubkey_restore() {
    check_fn "$1" pubkey_restore "$(declare -f _server_conf); SRV_PRIV='$SRV_PRIV'; _server_conf \"\$AWG_DIR\"" '_ensure_server_public_key' || return 1
    [[ "$CHECK_REF_OUT" == *"RC=0"* ]] || { echo "server_public.key was not restored without tracing ($1): $CHECK_REF_OUT"; return 1; }
}
@test "verbose: restoring server_public.key keeps the server private key out of the trace, both twins" {
    both v_pubkey_restore
}

v_render_server() {
    local setup
    setup="$(declare -f _init _server_conf); SRV_PRIV='$SRV_PRIV'; PSK_VAL='$PSK_VAL'"'
        _init "$AWG_DIR"; _server_conf "$AWG_DIR"
        printf "%s\n" "$SRV_PRIV" > "$AWG_DIR/server_private.key"
        cp "$AWG_DIR/awg0.conf" "$AWG_DIR/backup.conf"
        printf "\n[Peer]\n#_Name = old_phone\nPublicKey = PEERPUB\nPresharedKey = %s\nAllowedIPs = 10.9.9.2/32\n" "$PSK_VAL" >> "$AWG_DIR/backup.conf"'
    check_fn "$1" render_server "$setup" 'render_server_config "$AWG_DIR/backup.conf"' || return 1
    [[ "$CHECK_REF_OUT" == *"RC=0"* ]] || { echo "the server config was not rendered without tracing ($1): $CHECK_REF_OUT"; return 1; }
    grep -qF "PresharedKey = $PSK_VAL" "$CHECK_REF_DIR/awg0.conf" || { echo "the reference render lost the carried peer ($1)"; return 1; }
}
@test "verbose: render_server_config keeps the server key and carried peer keys out of the trace, both twins" {
    both v_render_server
}

CLIENT_SETUP='_init "$AWG_DIR"; _server_conf "$AWG_DIR"; printf "%s\n" "$SRV_PRIV" > "$AWG_DIR/server_private.key"; printf "PUBSERVERAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n" > "$AWG_DIR/server_public.key"'

client_setup() { printf '%s; SRV_PRIV=%q; PSK_VAL=%q; %s' "$(declare -f _init _server_conf)" "$SRV_PRIV" "$PSK_VAL" "$CLIENT_SETUP"; }

v_generate_client() {
    check_fn "$1" generate_client "$(client_setup)" 'CLIENT_PSK=auto generate_client my_phone 203.0.113.10' || return 1
    [[ "$CHECK_REF_OUT" == *"RC=0"* ]] || { echo "the client was not generated without tracing ($1): $CHECK_REF_OUT"; return 1; }
    local uri; uri=$(cat "$CHECK_REF_DIR/my_phone.vpnuri" 2>/dev/null)
    [[ "$uri" == vpn://* ]] || { echo "the reference run wrote no vpn:// link ($1)"; return 1; }
    check_fn "$1" generate_client "$(client_setup)" 'CLIENT_PSK=auto generate_client my_phone 203.0.113.10' "${uri:6:40}"
}
@test "verbose: generate_client keeps the client key, the preshared key and the vpn:// link out of the trace, both twins" {
    both v_generate_client
}

v_vpn_uri() {
    local setup
    setup="$(client_setup); CLIENT_PSK=auto generate_client my_phone 203.0.113.10 >/dev/null 2>&1; rm -f \"\$AWG_DIR/my_phone.vpnuri\""
    check_fn "$1" vpn_uri "$setup" 'generate_vpn_uri my_phone' || return 1
    [[ "$CHECK_REF_OUT" == *"RC=0"* ]] || { echo "the vpn:// link was not built without tracing ($1): $CHECK_REF_OUT"; return 1; }
    local uri; uri=$(cat "$CHECK_REF_DIR/my_phone.vpnuri")
    check_fn "$1" vpn_uri "$setup" 'generate_vpn_uri my_phone' "${uri:6:40}"
}
@test "verbose: generate_vpn_uri keeps both keys and the link out of the trace, both twins" {
    both v_vpn_uri
}

v_regen() {
    local setup
    setup="$(client_setup); CLIENT_PSK=auto generate_client my_phone 203.0.113.10 >/dev/null 2>&1"
    check_fn "$1" regen "$setup" 'regenerate_client my_phone 203.0.113.10' || return 1
    [[ "$CHECK_REF_OUT" == *"RC=0"* ]] || { echo "the client was not regenerated without tracing ($1): $CHECK_REF_OUT"; return 1; }
}
@test "verbose: regenerate_client keeps the client key and the preshared key out of the trace, both twins" {
    both v_regen
}

v_regen_server_psk() {
    # The client .conf is gone (regen as recovery): the preshared key comes from the
    # server [Peer] block, the private key from keys/.
    local setup
    setup="$(client_setup); CLIENT_PSK=auto generate_client my_phone 203.0.113.10 >/dev/null 2>&1; rm -f \"\$AWG_DIR/my_phone.conf\""
    check_fn "$1" regen_server_psk "$setup" 'regenerate_client my_phone 203.0.113.10' || return 1
    [[ "$CHECK_REF_OUT" == *"RC=0"* ]] || { echo "the client was not regenerated without tracing ($1): $CHECK_REF_OUT"; return 1; }
    grep -qF "PresharedKey = $PSK_VAL" "$CHECK_REF_DIR/my_phone.conf" || { echo "the reference regen did not restore the key from the server config ($1)"; return 1; }
}
@test "verbose: regenerate_client keeps a preshared key read from the server config out of the trace, both twins" {
    both v_regen_server_psk
}

v_add_peer() {
    # The preshared key is exported in the untraced setup: set in the traced call line,
    # the test itself would print it.
    check_fn "$1" add_peer "$(client_setup); export CLIENT_PSK='$PSK_VAL'" 'add_peer_to_server my_phone PEERPUBKEY 10.9.9.2' || return 1
    [[ "$CHECK_REF_OUT" == *"RC=0"* ]] || { echo "the peer was not added without tracing ($1): $CHECK_REF_OUT"; return 1; }
}
@test "verbose: add_peer_to_server keeps the preshared key out of the trace, both twins" {
    both v_add_peer
}

v_apply() {
    check_fn "$1" apply "$(client_setup)" 'AWG_APPLY_MODE=syncconf apply_config' || return 1
    [[ "$CHECK_REF_OUT" == *"RC=0"* ]] || { echo "apply_config failed without tracing ($1): $CHECK_REF_OUT"; return 1; }
}
@test "verbose: apply_config keeps the stripped server config out of the trace, both twins" {
    both v_apply
}

# first_line <file> <function>: the line right after "<function>() {".
first_line() { awk -v h="$2() {" '$0 == h { getline; print; exit }' "$1"; }

@test "verbose: every library function that holds key material starts with the xtrace self-guard naming itself, both twins" {
    # A wrong name would run another function; a missing line puts the body back in the trace.
    local f fn line want seen=0
    for f in awg_common.sh awg_common_en.sh; do
        for fn in generate_server_keys generate_keypair _ensure_server_public_key render_server_config \
                  generate_client regenerate_client generate_vpn_uri add_peer_to_server apply_config; do
            want="    case \$- in *x*) _awg_xtrace_guard $fn \"\$@\"; return ;; esac"
            case "$fn" in
                generate_server_keys|_ensure_server_public_key|apply_config)
                    want="    case \$- in *x*) _awg_xtrace_guard $fn; return ;; esac" ;;
            esac
            line=$(first_line "$BATS_TEST_DIRNAME/../$f" "$fn")
            [ "$line" = "$want" ] || { echo "$f $fn: first line is '$line'"; return 1; }
            seen=$((seen + 1))
        done
        # Its positional argument is the client private key, so the guard line itself would print it.
        line=$(first_line "$BATS_TEST_DIRNAME/../$f" render_client_config)
        [[ "$line" != *_awg_xtrace_guard* ]] || { echo "$f: render_client_config must not guard itself: '$line'"; return 1; }
    done
    [ "$seen" -eq 18 ]
}

@test "verbose: render_client_config is called only from generate_client and regenerate_client in every script" {
    # render_client_config takes the client private key as an argument, so it cannot
    # guard itself (the guard line would print its arguments). Its callers must.
    local f callers seen=0
    for f in awg_common.sh awg_common_en.sh install_amneziawg.sh install_amneziawg_en.sh manage_amneziawg.sh manage_amneziawg_en.sh; do
        callers=$(awk '
            /^[A-Za-z_][A-Za-z0-9_]*\(\) \{/ { fn = $1 }
            /^\}/ { fn = "" }
            /^[[:space:]]*#/ { next }
            /render_client_config/ && !/^render_client_config\(\) \{/ { print (fn == "" ? "TOPLEVEL" : fn) }
        ' "$BATS_TEST_DIRNAME/../$f" | sort -u | tr '\n' ' ')
        case "$f" in
            awg_common*) [ "$callers" = "generate_client() regenerate_client() " ] || { echo "$f: render_client_config callers: '$callers'"; return 1; } ;;
            *) [ -z "$callers" ] || { echo "$f calls render_client_config from '$callers'"; return 1; } ;;
        esac
        seen=$((seen + 1))
    done
    [ "$seen" -eq 6 ]
}
