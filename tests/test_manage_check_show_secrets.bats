#!/usr/bin/env bats
# manage check must not print the header protection key, and must name a timeout.
#
# awg show prints the header protection key in clear text (amneziawg-tools show.c
# uses key() for it instead of masked_key()), and check_server copies every line of
# `awg show awg0` into its log, which goes to the terminal and to the log file. A
# server with HeaderProtectionKey therefore published its key through `manage check`.
#
# The same function captured the exit status of the failing `awg show` with
# `if ! out=$(...); then rc=$?`, and `$?` there is the status of the negation, always
# 0, so the timeout branch (rc 124, a looping interface dump) never fired.
#
# Harness: the whole awg_common.sh is sourced (the masking helper may live there, and
# the test must not care where), check_server is lifted out of the manage script, and
# every system command is a stub in front of PATH. Log functions print to stdout, so
# $output holds exactly what a person would see. Every case runs both twins and
# asserts the text in the language of the script under test.

SECRET="SECRETHPKVALUEAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

_make_stubs() {
    local bin="$1" awg_mode="$2"
    mkdir -p "$bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/systemctl"
    printf '#!/usr/bin/env bash\necho "5: awg0: <POINTOPOINT,UP> mtu 1280"\necho "    inet 10.9.9.1/24 scope global awg0"\n' > "$bin/ip"
    printf '#!/usr/bin/env bash\necho "UNCONN 0 0 0.0.0.0:39743 0.0.0.0:*"\n' > "$bin/ss"
    printf '#!/usr/bin/env bash\necho 1\n' > "$bin/sysctl"
    printf '#!/usr/bin/env bash\necho "amneziawg 155648 0"\n' > "$bin/lsmod"
    printf '#!/usr/bin/env bash\necho "Status: active"\necho "39743/udp ALLOW Anywhere"\n' > "$bin/ufw"
    case "$awg_mode" in
        ok)
            cat > "$bin/awg" <<EOF
#!/usr/bin/env bash
echo "interface: awg0"
echo "  public key: PUBLICKEYKEEPAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
echo "  private key: (hidden)"
echo "  header protection key: ${SECRET}"
echo "  jc: 6"
exit 0
EOF
            ;;
        fail)
            cat > "$bin/awg" <<EOF
#!/usr/bin/env bash
echo "  header protection key: ${SECRET}" >&2
echo "Unable to access interface: No such device" >&2
exit 1
EOF
            ;;
        timeout)
            printf '#!/usr/bin/env bash\nexit 124\n' > "$bin/awg"
            ;;
    esac
    chmod +x "$bin"/*
}

# _run_check <manage script> <awg mode>
_run_check() {
    local src="$1" mode="$2" common
    common="${src/manage_amneziawg/awg_common}"
    local bin="$BATS_TEST_TMPDIR/bin-$mode"
    _make_stubs "$bin" "$mode"
    local dir="$BATS_TEST_TMPDIR/awg"
    mkdir -p "$dir"
    printf '[Interface]\nListenPort = 39743\n' > "$dir/awg0.conf"
    PATH="$bin:$PATH" AWG_DIR="$dir" CONFIG_FILE="$dir/awgsetup_cfg.init" SERVER_CONF_FILE="$dir/awg0.conf" \
    timeout 60 bash -c '
        set -o pipefail
        log()       { echo "INFO: $*"; }
        log_warn()  { echo "WARN: $*"; }
        log_error() { echo "ERR: $*"; }
        log_debug() { :; }
        source "$1" >/dev/null 2>&1 || true
        if [[ "${BROKEN_MASK:-0}" == 1 ]]; then _mask_report_secrets() { cat >/dev/null; return 1; }; fi
        safe_load_config() { AWG_PORT=39743; return 0; }
        JSON_OUTPUT=0
        _JSON_EMITTED=0
        eval "$(awk "/^_json_utf8_sanitize\\(\\) \\{/,/^\\}/" "$2")"
        eval "$(awk "/^json_escape\\(\\) \\{/,/^\\}/" "$2")"
        eval "$(awk "/^json_out\\(\\) \\{/,/^\\}/" "$2")"
        eval "$(awk "/^check_server\\(\\) \\{/,/^\\}/" "$2")"
        check_server
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

ru() { [[ "$1" != *_en.sh ]]; }

c_ok_masked() {
    run _run_check "$1" ok
    [ "$status" -eq 0 ] || { echo "check failed on a healthy stub ($1): $output"; return 1; }
    [[ "$output" == *"jc: 6"* ]] || { echo "awg show output not shown at all ($1): $output"; return 1; }
    [[ "$output" == *"PUBLICKEYKEEP"* ]] || { echo "public key was masked too ($1): $output"; return 1; }
    [[ "$output" != *"$SECRET"* ]] || { echo "header protection key printed ($1): $output"; return 1; }
}
@test "check: the header protection key from awg show is masked, the rest is shown, both twins" {
    both c_ok_masked
}

c_fail_masked() {
    run _run_check "$1" fail
    [ "$status" -eq 1 ] || { echo "a failing awg show did not fail check ($1): status $status"; return 1; }
    [[ "$output" == *"Unable to access interface"* ]] || { echo "the error text is gone ($1): $output"; return 1; }
    [[ "$output" != *"$SECRET"* ]] || { echo "header protection key printed on the error path ($1): $output"; return 1; }
}
@test "check: the error path masks the key and keeps the failure, both twins" {
    both c_fail_masked
}

c_timeout_named() {
    local want="did not answer within 10 seconds"
    ru "$1" && want="не ответил за 10 секунд"
    run _run_check "$1" timeout
    [ "$status" -eq 1 ] || { echo "a timed out awg show did not fail check ($1): status $status"; return 1; }
    [[ "$output" == *"$want"* ]] || { echo "timeout not named ($1), expected '$want': $output"; return 1; }
}
@test "check: a timed out awg show is named as a timeout, both twins" {
    both c_timeout_named
}

c_filter_fails() {
    local want="The secrets filter failed"
    ru "$1" && want="Фильтр секретов не отработал"
    BROKEN_MASK=1 run _run_check "$1" ok
    [ "$status" -eq 1 ] || { echo "check passed with a failed secrets filter ($1): status $status $output"; return 1; }
    [[ "$output" == *"$want"* ]] || { echo "filter failure not named ($1), expected '$want': $output"; return 1; }
    [[ "$output" != *"$SECRET"* ]] || { echo "the key leaked when the filter failed ($1): $output"; return 1; }
}
@test "check: a failed secrets filter fails check and shows nothing unfiltered, both twins" {
    both c_filter_fails
}

# _run_show <manage script> <awg mode> : show_awg_status lifted from the manage script,
# the library sourced for the masking filter, the same stubs as check.
_run_show() {
    local src="$1" mode="$2" common
    common="${src/manage_amneziawg/awg_common}"
    local bin="$BATS_TEST_TMPDIR/bin-show-$mode"
    _make_stubs "$bin" "$mode"
    PATH="$bin:$PATH" AWG_DIR="$BATS_TEST_TMPDIR/awg" \
    timeout 60 bash -c '
        set -o pipefail
        log()       { echo "INFO: $*"; }
        log_warn()  { echo "WARN: $*"; }
        log_error() { echo "ERR: $*"; }
        log_debug() { :; }
        source "$1" >/dev/null 2>&1 || true
        if [[ "${BROKEN_MASK:-0}" == 1 ]]; then _mask_report_secrets() { exec 0<&-; return 3; }; fi
        eval "$(awk "/^show_awg_status\\(\\) \\{/,/^\\}/" "$2")"
        declare -F show_awg_status >/dev/null || { echo "NO_SHOW_FUNCTION"; exit 7; }
        show_awg_status
    ' _ "$common" "$src"
}

s_ok() {
    run _run_show "$1" ok
    [ "$status" -eq 0 ] || { echo "show failed on a healthy stub ($1): $output"; return 1; }
    [[ "$output" == *"jc: 6"* ]] || { echo "awg show output not shown ($1): $output"; return 1; }
    [[ "$output" == *"PUBLICKEYKEEP"* ]] || { echo "public key was masked too ($1): $output"; return 1; }
    [[ "$output" != *"$SECRET"* ]] || { echo "show printed the header protection key ($1): $output"; return 1; }
}
@test "show: the header protection key is masked, the rest of awg show is shown, both twins" {
    both s_ok
}

s_fail() {
    run _run_show "$1" fail
    [ "$status" -eq 1 ] || { echo "a failing awg show did not fail show ($1): status $status $output"; return 1; }
    [[ "$output" == *"Unable to access interface"* ]] || { echo "the error text is gone ($1): $output"; return 1; }
    [[ "$output" != *"$SECRET"* ]] || { echo "show printed the key on the error path ($1): $output"; return 1; }
}
@test "show: the error path keeps the failure and masks the key, both twins" {
    both s_fail
}

s_timeout() {
    local want="did not answer within 10 seconds"
    ru "$1" && want="не ответил за 10 секунд"
    run _run_show "$1" timeout
    [ "$status" -eq 1 ] || { echo "a timed out awg show did not fail show ($1): status $status"; return 1; }
    [[ "$output" == *"$want"* ]] || { echo "timeout not named ($1), expected '$want': $output"; return 1; }
}
@test "show: a timed out awg show is named as a timeout, both twins" {
    both s_timeout
}

s_filter_fails() {
    local want="The secrets filter failed" wrong="awg show failed"
    ru "$1" && { want="Фильтр секретов не отработал"; wrong="Ошибка awg show"; }
    BROKEN_MASK=1 run _run_show "$1" ok
    [ "$status" -eq 1 ] || { echo "show passed with a failed secrets filter ($1): status $status $output"; return 1; }
    [[ "$output" == *"$want"* ]] || { echo "filter failure not named ($1), expected '$want': $output"; return 1; }
    [[ "$output" != *"$wrong"* ]] || { echo "a filter failure was reported as an awg show failure ($1): $output"; return 1; }
    [[ "$output" != *"$SECRET"* ]] || { echo "the key leaked when the filter failed ($1): $output"; return 1; }
}
@test "show: a failed secrets filter is named as such, not as an awg show failure, both twins" {
    both s_filter_fails
}

@test "show: the show command goes through show_awg_status in both manage twins" {
    local seen=0 src
    for src in "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"; do
        awk '/^    show\)$/ { f = 1 } f && /;;/ { exit } f' "$src" | grep -q 'show_awg_status' \
            || { echo "the show) branch does not call show_awg_status ($src)"; return 1; }
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}

@test "diagnose: the first line of a failed awg show is filtered right before it is reported, both manage twins" {
    # Pinned inside the failure branch itself: between `_show2_rc=$?` and the WARN
    # line that reports the code, the text must be reassigned through the filter.
    # A file-wide grep would be satisfied by check_server and prove nothing.
    local seen=0 src region
    for src in "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"; do
        region=$(awk '/_show2_rc=\$\?/ { f = 1 } f { print } f && /_diag_line WARN/ && /_show2_rc/ { exit }' "$src")
        [ -n "$region" ] || { echo "the diagnose failure branch was not found ($src)"; return 1; }
        grep -Eq '^[[:space:]]*_awg_show=\$\(.*_mask_report_secrets' <<< "$region" \
            || { echo "the failure branch does not filter the line before reporting it ($src): $region"; return 1; }
        if grep '_diag_line WARN' <<< "$region" | grep -q '_awg_show%%'; then
            echo "the WARN line embeds the raw awg show text ($src)"; return 1
        fi
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}

@test "mask: _mask_report_secrets has one body in all four copies (installers and libraries)" {
    local ref="" body f seen=0
    for f in install_amneziawg.sh install_amneziawg_en.sh awg_common.sh awg_common_en.sh; do
        body=$(awk '/^_mask_report_secrets\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../$f")
        [ -n "$body" ] || { echo "no _mask_report_secrets in $f"; return 1; }
        if [ -z "$ref" ]; then
            ref="$body"
        elif [ "$body" != "$ref" ]; then
            echo "the body in $f differs from install_amneziawg.sh"; return 1
        fi
        seen=$((seen + 1))
    done
    [ "$seen" -eq 4 ]
}
