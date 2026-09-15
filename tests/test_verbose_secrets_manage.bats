#!/usr/bin/env bats
# `bash -x manage_amneziawg.sh ...` must not print key material either.
#
# manage has no --verbose tracing of its own, but people run it under `bash -x`
# when they debug, and paste the output. list and stats walked awg0.conf line by
# line through [[ ]] tests and kept `awg show awg0 dump` in a variable; check kept
# the raw `awg show` output (with the header protection key) in a variable before
# masking it; modify walked the client .conf line by line. Each of those printed
# private keys, preshared keys or the header protection key into the trace.
#
# Same contract as tests/test_verbose_secrets.bats: a reference run without
# tracing, a run under `exec 2>&1; set -x`, then no secret in the traced output,
# xtrace restored, the same status. Both manage twins.

SRV_PRIV="SRVPRIVSECRETAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
CLI_PRIV="CLIPRIVSECRETAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
PSK_VAL="PSKSECRETVALUEAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
HPK_VAL="HPKSECRETVALUEAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

_stubs() {
    local bin="$1"
    mkdir -p "$bin"
    cat > "$bin/awg" <<EOF
#!/usr/bin/env bash
case "\$*" in
    "show awg0 dump")
        printf '%s\t%s\t39743\toff\n' "$SRV_PRIV" "SRVPUBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        printf '%s\t%s\t1.2.3.4:5555\t10.9.9.2/32\t1750000000\t1000\t2000\toff\n' "PEERPUB" "$PSK_VAL"
        ;;
    "show awg0")
        echo "interface: awg0"
        echo "  public key: SRVPUBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        echo "  private key: (hidden)"
        echo "  header protection key: $HPK_VAL"
        echo "  jc: 6"
        ;;
    genpsk) echo "$PSK_VAL" ;;
    pubkey) read -r _; echo "PUBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ;;
esac
exit 0
EOF
    printf '#!/usr/bin/env bash\n[[ "$1" == status ]] && echo "awg-quick[1]: Line unrecognized: PrivateKey=%s"\nexit 0\n' "$SRV_PRIV" > "$bin/systemctl"
    printf '#!/usr/bin/env bash\necho "5: awg0: <POINTOPOINT,UP> mtu 1280"\necho "    inet 10.9.9.1/24 scope global awg0"\n' > "$bin/ip"
    printf '#!/usr/bin/env bash\necho "UNCONN 0 0 0.0.0.0:39743 0.0.0.0:*"\n' > "$bin/ss"
    printf '#!/usr/bin/env bash\necho 1\n' > "$bin/sysctl"
    printf '#!/usr/bin/env bash\necho "amneziawg 155648 0"\n' > "$bin/lsmod"
    printf '#!/usr/bin/env bash\necho "Status: active"\necho "39743/udp ALLOW Anywhere"\n' > "$bin/ufw"
    cat > "$bin/qrencode" <<'EOF'
#!/usr/bin/env bash
out=""
while (( $# > 0 )); do case "$1" in -o) out="$2"; shift 2 ;; -t) shift 2 ;; *) shift ;; esac; done
cat > "${out:-/dev/null}"
EOF
    chmod +x "$bin"/*
}

_files() {
    local d="$1"
    mkdir -p "$d/keys" "$d/expiry"
    printf "export AWG_PORT=39743\nexport AWG_TUNNEL_SUBNET='10.9.9.1/24'\nexport AWG_ENDPOINT='203.0.113.10'\nexport AWG_PROTOCOL='2.0'\n" > "$d/awgsetup_cfg.init"
    {
        printf '[Interface]\nPrivateKey = %s\nAddress = 10.9.9.1/24\nMTU = 1280\nListenPort = 39743\n' "$SRV_PRIV"
        printf 'Jc = 6\nJmin = 55\nJmax = 380\nS1 = 72\nS2 = 56\nS3 = 32\nS4 = 16\n'
        printf 'H1 = 100000-800000\nH2 = 1000000-8000000\nH3 = 10000000-80000000\nH4 = 100000000-800000000\n'
        printf '\n[Peer]\n#_Name = my_phone\nPublicKey = PEERPUB\nPresharedKey = %s\nAllowedIPs = 10.9.9.2/32\n' "$PSK_VAL"
    } > "$d/awg0.conf"
    printf '[Interface]\nPrivateKey = %s\nAddress = 10.9.9.2/32\nDNS = 1.1.1.1\nMTU = 1280\n\n[Peer]\nPublicKey = SRVPUBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\nPresharedKey = %s\nEndpoint = 203.0.113.10:39743\nAllowedIPs = 0.0.0.0/0\n' "$CLI_PRIV" "$PSK_VAL" > "$d/my_phone.conf"
    printf '%s\n' "$CLI_PRIV" > "$d/keys/my_phone.private"
    printf 'PEERPUB\n' > "$d/keys/my_phone.public"
    printf 'SRVPUBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n' > "$d/server_public.key"
    chmod 600 "$d/awg0.conf" "$d/my_phone.conf" "$d/keys/my_phone.private"
}

# mrun <manage script> <dir> <call> <traced 0|1>
mrun() {
    local src="$1" d="$2" call="$3" traced="$4" common
    common="${src/manage_amneziawg/awg_common}"
    _stubs "$d/bin"
    PATH="$d/bin:$PATH" AWG_DIR="$d" AWG_TRACED="$traced" timeout 60 bash -c '
        export CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init" SERVER_CONF_FILE="$AWG_DIR/awg0.conf"
        export KEYS_DIR="$AWG_DIR/keys" EXPIRY_DIR="$AWG_DIR/expiry"
        log() { :; }; log_warn() { :; }; log_error() { :; }; log_debug() { :; }
        die() { echo "DIE: $*"; exit 1; }
        source "$1" >/dev/null 2>&1 || true
        JSON_OUTPUT=0; _JSON_EMITTED=0; _JSON_ERR=""; VERBOSE_LIST=0; NO_COLOR=1
        for fn in _json_utf8_sanitize json_escape json_out format_bytes format_remaining escape_sed _log_service_status check_server list_clients stats_clients modify_client; do
            eval "$(awk "/^${fn}\\(\\) \\{/,/^\\}/" "$2")"
        done
        _check_common_compat() { return 0; }
        check_dependencies() { return 0; }
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
    ' _ "$common" "$src" "$call"
}

# check_manage <manage script> <label> <call>
check_manage() {
    local src="$1" label="$2" call="$3" ref tr ref_out tr_out ref_rc tr_rc s
    ref="$BATS_TEST_TMPDIR/vm-$(basename "$src" .sh)-$label-ref"
    tr="$BATS_TEST_TMPDIR/vm-$(basename "$src" .sh)-$label-tr"
    rm -rf "$ref" "$tr"; _files "$ref"; _files "$tr"
    ref_out=$(mrun "$src" "$ref" "$call" 0)
    tr_out=$(mrun "$src" "$tr" "$call" 1)
    ref_rc=$(grep -o 'RC=[0-9]*' <<< "$ref_out" | tail -1)
    tr_rc=$(grep -o 'RC=[0-9]*' <<< "$tr_out" | tail -1)
    [ -n "$ref_rc" ] || { echo "$label ($src): the reference run did not finish: $ref_out"; return 1; }
    [ "$ref_rc" = "$tr_rc" ] || { echo "$label ($src): status differs under set -x: $ref_rc vs $tr_rc"; echo "$tr_out" | tail -20; return 1; }
    [[ "$tr_out" == *XTRACE_STILL_ON* ]] || { echo "$label ($src): xtrace was not restored"; return 1; }
    # Only what tracing added counts: a line printed identically without tracing is the
    # function's own output, not the trace (unmasked systemctl status is tracked apart).
    local tr_only
    tr_only=$(grep -vxF -f <(printf '%s\n' "$ref_out") <<< "$tr_out" || true)
    for s in "$SRV_PRIV" "$CLI_PRIV" "$PSK_VAL" "$HPK_VAL"; do
        if [[ "$tr_only" == *"$s"* ]]; then
            echo "$label ($src): secret '${s:0:12}...' in the trace:"
            grep -n -F "${s:0:12}" <<< "$tr_only" | head -5
            return 1
        fi
    done
    CHECK_REF_OUT="$ref_out"
}

both() {
    local seen=0 src
    for src in "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"; do
        "$1" "$src" || return 1
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}

m_list() { check_manage "$1" list 'list_clients'; }
@test "verbose manage: list keeps the server key and preshared keys out of the trace, both twins" {
    both m_list
}

m_stats() { check_manage "$1" stats 'stats_clients'; }
@test "verbose manage: stats keeps the dump keys out of the trace, both twins" {
    both m_stats
}

m_check() { check_manage "$1" check 'check_server'; }
@test "verbose manage: check keeps the header protection key out of the trace, both twins" {
    both m_check
}

m_modify() {
    check_manage "$1" modify 'modify_client my_phone DNS 8.8.8.8' || return 1
    [[ "$CHECK_REF_OUT" == *"RC=0"* ]] || { echo "modify failed without tracing ($1): $CHECK_REF_OUT"; return 1; }
}
@test "verbose manage: modify keeps the client key and preshared key out of the trace, both twins" {
    both m_modify
}

m_service_status() {
    check_manage "$1" service_status 'declare -F _log_service_status >/dev/null || exit 9; _log_service_status' || return 1
    [[ "$CHECK_REF_OUT" == *"RC=0"* ]] || { echo "_log_service_status is missing or failed ($1): $CHECK_REF_OUT"; return 1; }
}
@test "verbose manage: the service status printed on a failed restore or restart stays out of the trace, both twins" {
    both m_service_status
}

@test "verbose manage: restore and restart print the service status through the guarded helper, both twins" {
    local f seen=0 body
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        [ "$(grep -c 'status_out=$(systemctl status' "$BATS_TEST_DIRNAME/../$f")" -eq 1 ] \
            || { echo "$f captures systemctl status into a variable outside the helper"; return 1; }
        awk '/^_log_service_status\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../$f" | grep -q 'status_out=$(systemctl status' \
            || { echo "$f: the only capture is not inside _log_service_status"; return 1; }
        body=$(awk '/^restore_backup\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../$f")
        grep -q '_log_service_status' <<< "$body" || { echo "$f: restore_backup does not use _log_service_status"; return 1; }
        awk '/^    restart\)$/ { p = 1 } p && /;;/ { exit } p' "$BATS_TEST_DIRNAME/../$f" | grep -q '_log_service_status' \
            || { echo "$f: the restart branch does not use _log_service_status"; return 1; }
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}

@test "verbose manage: every manage function that holds key material starts with the xtrace self-guard naming itself, both twins" {
    local f fn line want seen=0
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        for fn in list_clients stats_clients check_server diagnose_server modify_client _log_service_status; do
            want="    case \$- in *x*) _awg_xtrace_guard $fn; return ;; esac"
            [ "$fn" = modify_client ] && want="    case \$- in *x*) _awg_xtrace_guard $fn \"\$@\"; return ;; esac"
            line=$(awk -v h="$fn() {" '$0 == h { getline; print; exit }' "$BATS_TEST_DIRNAME/../$f")
            [ "$line" = "$want" ] || { echo "$f $fn: first line is '$line'"; return 1; }
            seen=$((seen + 1))
        done
    done
    [ "$seen" -eq 12 ]
}
