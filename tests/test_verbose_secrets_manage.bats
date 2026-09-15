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
# tracing, a run under `exec 2>&1; set -x`, then no secret in what tracing added,
# xtrace restored, the same status. Both manage twins. A failed restore and a
# failed restart run the whole script under `bash -x` instead, with the trace
# in its own file.

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
    cat > "$bin/systemctl" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == status ]]; then
    echo "awg-quick@awg0.service - AmneziaWG via awg-quick(8) for awg0"
    echo "  awg-quick[1]: Line unrecognized: PrivateKey=$SRV_PRIV"
    echo "  Active: failed (Result: exit-code)"
fi
exit 0
EOF
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
        for fn in _json_utf8_sanitize json_escape json_out format_bytes format_remaining escape_sed _log_service_status check_server list_clients stats_clients modify_client _diagnose_carrier_known _diagnose_carrier_list _diag_line _diag_cps_guard diagnose_server; do
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
    # function's own output, not the trace. Lines are subtracted as a multiset, so a
    # continuation line of a traced multi-line value still counts even when the
    # function also prints the same line.
    local tr_only
    tr_only=$(LC_ALL=C comm -13 <(printf '%s\n' "$ref_out" | LC_ALL=C sort) <(printf '%s\n' "$tr_out" | LC_ALL=C sort))
    for s in "$SRV_PRIV" "$CLI_PRIV" "$PSK_VAL" "$HPK_VAL"; do
        if [[ "$tr_only" == *"$s"* ]]; then
            echo "$label ($src): secret '${s:0:12}...' in the trace:"
            grep -n -F "${s:0:12}" <<< "$tr_only" | head -5
            return 1
        fi
    done
    CHECK_REF_OUT="$ref_out"
    CHECK_REF_DIR="$ref"
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

m_diag() { check_manage "$1" diag 'diagnose_server'; }
@test "verbose manage: diagnose keeps the header protection key out of the trace, both twins" {
    both m_diag
}
@test "verbose manage: check keeps the header protection key out of the trace, both twins" {
    both m_check
}

m_modify() {
    check_manage "$1" modify 'modify_client my_phone DNS 8.8.8.8' || return 1
    [[ "$CHECK_REF_OUT" == *"RC=0"* ]] || { echo "modify failed in the untraced run ($1): $CHECK_REF_OUT"; return 1; }
    grep -q '^DNS = 8.8.8.8' "$CHECK_REF_DIR/my_phone.conf" || { echo "the untraced modify did not write the new DNS ($1)"; return 1; }
}
@test "verbose manage: modify keeps the client key and preshared key out of the trace, both twins" {
    both m_modify
}

m_service_status() {
    check_manage "$1" service_status 'declare -F _log_service_status >/dev/null || exit 9; _log_service_status' || return 1
    [[ "$CHECK_REF_OUT" == *"RC=0"* ]] || { echo "_log_service_status is missing or failed ($1): $CHECK_REF_OUT"; return 1; }
}
@test "verbose manage: _log_service_status keeps the service status out of the trace, both twins" {
    both m_service_status
}

STATUS_SECRET="SVCSTATUSSECRETAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

# m_svc_fail <manage script> <restore|restart>
# The whole manage script under `bash -x`: systemctl start and restart fail,
# and systemctl status and journalctl print a secret-shaped line.
# BASH_XTRACEFD sends the trace to its own file, so no reference run is
# needed. No matter how the systemctl status and journalctl output is read (a
# substitution, a pipe, a temp file, a wrapper), its text must reach the output
# and must not reach the trace file, and the trace must reach the failing start
# or restart, so an empty trace does not pass. The keys in the test config must
# not reach the trace file either.
m_svc_fail() {
    local src="$1" cmd="$2" common d b rc s
    local -a args
    common="${src/manage_amneziawg/awg_common}"
    d="$BATS_TEST_TMPDIR/vm-svc-$(basename "$src" .sh)-$cmd"
    rm -rf "$d"; _files "$d"; _stubs "$d/bin"
    cp "$common" "$d/awg_common.sh"
    cat > "$d/bin/systemctl" <<EOF
#!/usr/bin/env bash
# Any argument counts: systemctl --no-pager status, systemctl -n 50 status.
for a in "\$@"; do
    case "\$a" in
        status)
            echo "awg-quick@awg0.service - AmneziaWG via awg-quick(8) for awg0"
            echo "  awg-quick[1]: Line unrecognized: PrivateKey=$STATUS_SECRET"
            echo "  Active: failed (Result: exit-code)"
            exit 0
            ;;
        start|restart) exit 1 ;;
    esac
done
exit 0
EOF
    printf '#!/usr/bin/env bash\necho "awg-quick[1]: Line unrecognized: PrivateKey=%s"\n' "$STATUS_SECRET" > "$d/bin/journalctl"
    chmod +x "$d/bin/systemctl" "$d/bin/journalctl"
    args=(--conf-dir="$d" --server-conf="$d/awg0.conf")
    if [ "$cmd" = restore ]; then
        PATH="$d/bin:$PATH" timeout 60 bash "$src" backup "${args[@]}" > "$d/backup.out" 2>&1 \
            || { echo "backup failed ($src): $(tail -5 "$d/backup.out")"; return 1; }
        b=$(find "$d/backups" -maxdepth 1 -name 'awg_backup_*.tar.gz' | head -1)
        [ -n "$b" ] || { echo "no backup was written ($src)"; return 1; }
        args=("$b" "${args[@]}")
    fi
    rc=0
    PATH="$d/bin:$PATH" BASH_XTRACEFD=7 timeout 120 bash -x "$src" "$cmd" "${args[@]}" --yes \
        7> "$d/trace" > "$d/out" 2>&1 || rc=$?
    [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] || { echo "$cmd ($src): expected a failure, got rc=$rc: $(tail -5 "$d/out")"; return 1; }
    grep -qF "PrivateKey=$STATUS_SECRET" "$d/out" \
        || { echo "$cmd ($src): the service status did not reach the output: $(tail -5 "$d/out")"; return 1; }
    grep -qE "systemctl (start|restart) awg-quick@awg0\$" "$d/trace" \
        || { echo "$cmd ($src): the trace does not reach the failing systemctl start or restart"; return 1; }
    for s in "$STATUS_SECRET" "$SRV_PRIV" "$CLI_PRIV" "$PSK_VAL" "$HPK_VAL"; do
        if grep -qF "$s" "$d/trace"; then
            echo "$cmd ($src): secret '${s:0:12}...' is in the trace:"
            grep -n -F "${s:0:12}" "$d/trace" | head -5
            return 1
        fi
    done
}
m_svc_restore() { m_svc_fail "$1" restore; }
m_svc_restart() { m_svc_fail "$1" restart; }
@test "verbose manage: a failed restore prints the service status but keeps it out of the trace, both twins" {
    both m_svc_restore
}
@test "verbose manage: a failed restart prints the service status but keeps it out of the trace, both twins" {
    both m_svc_restart
}

m_old_library() {
    # manage next to a library of the same minor that has no _awg_xtrace_guard yet:
    # the fallback from check_dependencies keeps list working under bash -x.
    local src="$1" common old d out
    common="${src/manage_amneziawg/awg_common}"
    d="$BATS_TEST_TMPDIR/vm-old-$(basename "$src" .sh)"
    rm -rf "$d"; _files "$d"; _stubs "$d/bin"
    old="$d/old_common.sh"
    awk '/^_awg_xtrace_guard\(\) \{/ { skip = 1 } !skip { print } skip && /^\}/ { skip = 0 }' "$common" > "$old"
    ! grep -q '^_awg_xtrace_guard() {' "$old" || { echo "the old library copy still defines the guard"; return 1; }
    out=$(PATH="$d/bin:$PATH" AWG_DIR="$d" timeout 60 bash -c '
        export CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init" SERVER_CONF_FILE="$AWG_DIR/awg0.conf"
        export KEYS_DIR="$AWG_DIR/keys" EXPIRY_DIR="$AWG_DIR/expiry"
        log() { :; }; log_warn() { :; }; log_error() { :; }; log_debug() { :; }
        source "$1" >/dev/null 2>&1 || true
        JSON_OUTPUT=0; _JSON_EMITTED=0; VERBOSE_LIST=0; NO_COLOR=1
        for fn in _json_utf8_sanitize json_escape json_out format_remaining list_clients; do
            eval "$(awk "/^${fn}\\(\\) \\{/,/^\\}/" "$2")"
        done
        eval "$(grep -m1 "declare -F _awg_xtrace_guard" "$2")"
        exec 2>&1
        set -x
        list_clients; rc=$?
        set +x
        echo "RC=$rc"
    ' _ "$old" "$src")
    [[ "$out" != *"command not found"* ]] || { echo "manage under bash -x broke next to an old library ($src): $(grep 'command not found' <<< "$out" | head -3)"; return 1; }
    [[ "$out" == *"RC=0"* ]] || { echo "list failed under bash -x next to an old library ($src): $(tail -5 <<< "$out")"; return 1; }
}
@test "verbose manage: next to a same-minor library without the guard, list still works under bash -x, both twins" {
    both m_old_library
}

@test "verbose manage: check_dependencies defines the guard fallback right after the compatibility check, both twins" {
    local f body seen=0
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        body=$(awk '/^check_dependencies\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../$f")
        grep -A6 '^    _check_common_compat$' <<< "$body" | grep -qxF '    declare -F _awg_xtrace_guard >/dev/null || _awg_xtrace_guard() { local _xt=0 _rc=0; case $- in *x*) _xt=1; set +x ;; esac; "$@" || _rc=$?; if (( _xt )); then set -x; fi; return "$_rc"; }' \
            || { echo "$f: no guard fallback after _check_common_compat"; return 1; }
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
