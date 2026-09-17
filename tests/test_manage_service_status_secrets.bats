#!/usr/bin/env bats
# manage must not print keys from the service status text.
#
# `systemctl status awg-quick@awg0` ends with the last journal lines of the unit,
# and those carry the stderr of `awg setconf`. When awg0.conf holds a malformed key
# (a hand edit that cut a character, PrivateKey moved into [Peer]), the tools answer
# with `Line unrecognized: `PrivateKey=<value>'` or `Key is not the correct length
# or format: `<value>'`, and the value is the server private key or a preshared key
# with one character off. check printed this status as is, and a failed restore or
# restart copied it into the log through _log_service_status, so the key went to the
# screen, to the manage log and into reports people paste into issues.
#
# The installer's --diagnostic already runs the same text through
# _mask_report_secrets; its two unanchored rules exist exactly for this prefixed
# journal form. Harness: the whole awg_common.sh is sourced, the manage function is
# lifted out by awk, every system command is a stub in front of PATH. Both twins.

PRIV="SECRETPRIVKEYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
BAD="SECRETBADLENGTHKEYBBBBBBBBBBBBBBBBBBBBBBBBB"

# _make_stubs <dir> <systemctl exit code>
_make_stubs() {
    local bin="$1" rc="$2"
    mkdir -p "$bin"
    cat > "$bin/systemctl" <<EOF
#!/usr/bin/env bash
if [ "\$1" = status ]; then
    echo "x awg-quick@awg0.service - WireGuard via wg-quick(8) for awg0"
    echo "     Active: failed (Result: exit-code) since Wed 2026-09-17 12:00:00 UTC; 5s ago"
    echo "Sep 17 12:00:00 host awg-quick[1234]: [#] awg setconf awg0 /dev/fd/63"
    echo "Sep 17 12:00:00 host awg-quick[1234]: Line unrecognized: \\\`PrivateKey=${PRIV}'"
    echo "Sep 17 12:00:00 host awg-quick[1234]: Key is not the correct length or format: \\\`${BAD}'"
    echo "Sep 17 12:00:00 host awg-quick[1234]: Configuration parsing error"
    exit ${rc}
fi
exit 0
EOF
    printf '#!/usr/bin/env bash\necho "5: awg0: <POINTOPOINT,UP> mtu 1280"\necho "    inet 10.9.9.1/24 scope global awg0"\n' > "$bin/ip"
    printf '#!/usr/bin/env bash\necho "UNCONN 0 0 0.0.0.0:39743 0.0.0.0:*"\n' > "$bin/ss"
    printf '#!/usr/bin/env bash\necho 1\n' > "$bin/sysctl"
    printf '#!/usr/bin/env bash\necho "amneziawg 155648 0"\n' > "$bin/lsmod"
    printf '#!/usr/bin/env bash\necho "Status: active"\necho "39743/udp ALLOW Anywhere"\n' > "$bin/ufw"
    printf '#!/usr/bin/env bash\necho "interface: awg0"\necho "  jc: 6"\nexit 0\n' > "$bin/awg"
    chmod +x "$bin"/*
}

# _run_check <manage script> <systemctl rc> <json 0|1>
# Prints stdout and stderr separately: "OUT:" lines, then "ERR-STREAM:" lines.
_run_check() {
    local src="$1" rc="$2" json="$3" common bin dir
    common="${src/manage_amneziawg/awg_common}"
    bin="$BATS_TEST_TMPDIR/bin-$rc"
    _make_stubs "$bin" "$rc"
    dir="$BATS_TEST_TMPDIR/awg"
    mkdir -p "$dir"
    printf '[Interface]\nListenPort = 39743\n[Peer]\n' > "$dir/awg0.conf"
    PATH="$bin:$PATH" AWG_DIR="$dir" CONFIG_FILE="$dir/awgsetup_cfg.init" SERVER_CONF_FILE="$dir/awg0.conf" \
    JSON_MODE="$json" timeout 60 bash -c '
        set -o pipefail
        # In --json the real logger writes to stderr and stdout carries only the
        # envelope, so the stand-ins do the same there.
        if [[ "$JSON_MODE" == 1 ]]; then
            log()       { echo "INFO: $*" >&2; }
            log_warn()  { echo "WARN: $*" >&2; }
            log_error() { echo "ERR: $*" >&2; }
        else
            log()       { echo "INFO: $*"; }
            log_warn()  { echo "WARN: $*"; }
            log_error() { echo "ERR: $*"; }
        fi
        log_debug() { :; }
        source "$1" >/dev/null 2>&1 || true
        if [[ "${BROKEN_MASK:-0}" == 1 ]]; then _mask_report_secrets() { cat; return 1; }; fi
        # 2: the filter fails only on the service status text and still works for awg
        # show, so a check failure can come from nothing but the status branch.
        if [[ "${BROKEN_MASK:-0}" == 2 ]]; then
            eval "_real_mask() $(declare -f _mask_report_secrets | tail -n +2)"
            _mask_report_secrets() {
                local _in
                _in=$(cat)
                if [[ "$_in" == *"Active:"* ]]; then printf "%s\n" "$_in"; return 1; fi
                printf "%s\n" "$_in" | _real_mask
            }
        fi
        safe_load_config() { AWG_PORT=39743; return 0; }
        JSON_OUTPUT="$JSON_MODE"
        _JSON_EMITTED=0
        eval "$(awk "/^_json_utf8_sanitize\\(\\) \\{/,/^\\}/" "$2")"
        eval "$(awk "/^json_escape\\(\\) \\{/,/^\\}/" "$2")"
        eval "$(awk "/^json_out\\(\\) \\{/,/^\\}/" "$2")"
        eval "$(awk "/^check_server\\(\\) \\{/,/^\\}/" "$2")"
        check_server 2>"$3"
    ' _ "$common" "$src" "$BATS_TEST_TMPDIR/stderr-$rc-$json"
}

# _run_log_status <manage script>
_run_log_status() {
    local src="$1" common bin
    common="${src/manage_amneziawg/awg_common}"
    bin="$BATS_TEST_TMPDIR/bin-log"
    _make_stubs "$bin" 3
    PATH="$bin:$PATH" AWG_DIR="$BATS_TEST_TMPDIR/awg" timeout 60 bash -c '
        set -o pipefail
        log()       { echo "INFO: $*"; }
        log_warn()  { echo "WARN: $*"; }
        log_error() { echo "ERR: $*"; }
        log_debug() { :; }
        source "$1" >/dev/null 2>&1 || true
        if [[ "${BROKEN_MASK:-0}" == 1 ]]; then _mask_report_secrets() { cat; return 1; }; fi
        eval "$(awk "/^_log_service_status\\(\\) \\{/,/^\\}/" "$2")"
        declare -F _log_service_status >/dev/null || { echo "NO_FUNCTION"; exit 7; }
        _log_service_status
    ' _ "$common" "$src"
}

both() {
    local seen=0 src
    for src in "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"; do
        "$1" "$src" || return 1
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}

no_secret() {
    [[ "$1" != *"$PRIV"* && "$1" != *"$BAD"* ]]
}

c_text() {
    run _run_check "$1" 3 0
    local err
    err=$(cat "$BATS_TEST_TMPDIR/stderr-3-0")
    [ "$status" -eq 1 ] || { echo "a failed service did not fail check ($1): status $status"; return 1; }
    [[ "$output" == *"Active: failed"* ]] || { echo "the service status is not shown at all ($1): $output"; return 1; }
    [[ "$output" == *"Configuration parsing error"* ]] || { echo "the journal lines are gone ($1): $output"; return 1; }
    [[ "$output" == *"[HIDDEN]"* ]] || { echo "nothing was masked ($1): $output"; return 1; }
    no_secret "$output$err" || { echo "check printed a key from the service status ($1): $output $err"; return 1; }
}
@test "check: keys in the service status journal lines are masked, the rest is shown, both twins" {
    both c_text
}

c_json() {
    command -v jq >/dev/null || skip "jq not available"
    run _run_check "$1" 3 1
    local err
    err=$(cat "$BATS_TEST_TMPDIR/stderr-3-1")
    printf '%s' "$output" | jq -e '.command == "check" and .ok == false' >/dev/null \
        || { echo "stdout is not the check JSON ($1): $output"; return 1; }
    [[ "$err" == *"Active: failed"* ]] || { echo "the service status did not go to stderr in --json ($1): $err"; return 1; }
    no_secret "$output$err" || { echo "check --json printed a key ($1): $err"; return 1; }
}
@test "check --json: the masked service status goes to stderr, stdout stays JSON, both twins" {
    both c_json
}

c_active_ok() {
    run _run_check "$1" 0 0
    [ "$status" -eq 0 ] || { echo "an active service failed check ($1): $output"; return 1; }
    no_secret "$output" || { echo "check printed a key from an active service status ($1)"; return 1; }
}
@test "check: an active service still passes and its status text is masked too, both twins" {
    both c_active_ok
}

c_broken_filter() {
    BROKEN_MASK=2 run _run_check "$1" 0 0
    [ "$status" -eq 1 ] || { echo "a failed secrets filter did not fail check ($1): status $status"; return 1; }
    no_secret "$output" || { echo "a failed filter let the raw status through ($1): $output"; return 1; }
    if [[ "$1" != *_en.sh ]]; then
        [[ "$output" == *"Фильтр секретов не отработал"* ]] || { echo "the filter failure is not named ($1): $output"; return 1; }
    else
        [[ "$output" == *"secrets filter failed"* ]] || { echo "the filter failure is not named ($1): $output"; return 1; }
    fi
}
@test "check: a failed secrets filter hides the service status and fails check, both twins" {
    both c_broken_filter
}

l_masked() {
    run _run_log_status "$1"
    [ "$status" -eq 0 ] || { echo "_log_service_status failed ($1): $output"; return 1; }
    [[ "$output" == *"ERR:   "*"Active: failed"* ]] || { echo "the status is not logged ($1): $output"; return 1; }
    [[ "$output" == *"[HIDDEN]"* ]] || { echo "nothing was masked in the log ($1): $output"; return 1; }
    no_secret "$output" || { echo "the log got a key from the service status ($1): $output"; return 1; }
}
@test "restore and restart: the service status copied into the log is masked, both twins" {
    both l_masked
}

l_broken_filter() {
    BROKEN_MASK=1 run _run_log_status "$1"
    no_secret "$output" || { echo "a failed filter let the raw status into the log ($1): $output"; return 1; }
    if [[ "$1" != *_en.sh ]]; then
        [[ "$output" == *"Фильтр секретов не отработал"* ]] || { echo "the filter failure is not named ($1): $output"; return 1; }
    else
        [[ "$output" == *"secrets filter failed"* ]] || { echo "the filter failure is not named ($1): $output"; return 1; }
    fi
}
@test "restore and restart: a failed secrets filter logs no raw status, both twins" {
    both l_broken_filter
}

@test "manage: every systemctl status call is captured, none prints straight to the terminal" {
    # A later edit that prints the status directly again would bypass the filter
    # silently; the behaviour tests above would not see a new call site.
    local f n bad
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        bad=$(grep -nE 'systemctl status awg-quick@awg0 --no-pager' "$BATS_TEST_DIRNAME/../$f" \
            | grep -vE '^[0-9]+:[[:space:]]*#' | grep -vE '=\$\(systemctl status awg-quick@awg0 --no-pager 2>&1\)' || true)
        [ -z "$bad" ] || { echo "$f prints systemctl status without capture: $bad"; return 1; }
        n=$(grep -cE '=\$\(systemctl status awg-quick@awg0 --no-pager 2>&1\)' "$BATS_TEST_DIRNAME/../$f")
        [ "$n" -eq 2 ] || { echo "$f: expected 2 captured calls (check, _log_service_status), found $n"; return 1; }
    done
}
