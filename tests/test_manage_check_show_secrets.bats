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
        failempty)
            printf '#!/usr/bin/env bash\nexit 1\n' > "$bin/awg"
            ;;
        slow)
            # Writes after a pause and leaves a marker only if it survived the writes:
            # the show test needs awg show killed by SIGPIPE, and checks that it was.
            cat > "$bin/awg" <<EOF
#!/usr/bin/env bash
sleep 0.3
echo "interface: awg0"
echo "  header protection key: ${SECRET}"
echo "  jc: 6"
touch "${BATS_TEST_TMPDIR}/slow-finished" || exit 99
exit 0
EOF
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
        if [[ "${BROKEN_MASK:-0}" == 1 ]]; then _mask_report_secrets() { cat; return 1; }; fi
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
    # No leading capital: the phrase must match however the line starts.
    local noise="bfuscation parameters not detected"
    ru "$1" && noise="араметры обфускации не обнаружены"
    [[ "$output" != *"$noise"* ]] || { echo "a hidden output was judged as missing parameters ($1): $output"; return 1; }
}
@test "check: a failed secrets filter fails check and shows nothing unfiltered, both twins" {
    both c_filter_fails
}

c_filter_and_awg_fail() {
    local want="awg show awg0 failed (code 1)"
    ru "$1" && want="awg show awg0 завершился с ошибкой (код 1)"
    BROKEN_MASK=1 run _run_check "$1" fail
    [ "$status" -eq 1 ] || { echo "check passed with a failed filter and a failed awg show ($1): status $status"; return 1; }
    [[ "$output" == *"$want"* ]] || { echo "the awg show status is not named when its output is hidden ($1), expected '$want': $output"; return 1; }
    [[ "$output" != *"$SECRET"* ]] || { echo "the key leaked when both failed ($1): $output"; return 1; }
}
@test "check: with its output hidden a failed awg show is still reported by its code, both twins" {
    both c_filter_and_awg_fail
}

c_filter_and_timeout() {
    local want="The secrets filter failed" timed="did not answer within 10 seconds"
    ru "$1" && { want="Фильтр секретов не отработал"; timed="не ответил за 10 секунд"; }
    BROKEN_MASK=1 run _run_check "$1" timeout
    [ "$status" -eq 1 ] || { echo "check passed with a failed filter and a timeout ($1): status $status"; return 1; }
    [[ "$output" == *"$want"* ]] || { echo "filter failure not named ($1): $output"; return 1; }
    [[ "$output" == *"$timed"* ]] || { echo "a timeout next to a failed filter is not named as a timeout ($1): $output"; return 1; }
}
@test "check: a timeout is still named as a timeout when the secrets filter failed too, both twins" {
    both c_filter_and_timeout
}

c_fail_empty() {
    local want="awg show awg0 failed (code 1)"
    ru "$1" && want="awg show awg0 завершился с ошибкой (код 1)"
    run _run_check "$1" failempty
    [ "$status" -eq 1 ] || { echo "a silent failing awg show did not fail check ($1): status $status"; return 1; }
    [[ "$output" == *"$want"* ]] || { echo "a silent failure is not named by its code ($1), expected '$want': $output"; return 1; }
}
@test "check: an awg show that fails without output is named by its code, both twins" {
    both c_fail_empty
}

# _run_show <manage script> <awg mode> : show_awg_status lifted from the manage script,
# the library sourced for the masking filter, the same stubs as check.
# SIGPIPE is set back to its default: a parent that ignores it (the GitHub runner does)
# passes the ignore down, a shell cannot undo an ignore it inherited, and awg show
# would then outlive a dead filter instead of dying of SIGPIPE as it does when manage is
# run from an interactive shell. Under an inherited ignore (a systemd unit, whose
# IgnoreSIGPIPE= defaults to yes) awg show exits 0 instead: s_filter_fails_awg_ok.
_run_show() {
    local src="$1" mode="$2" common
    common="${src/manage_amneziawg/awg_common}"
    local bin="$BATS_TEST_TMPDIR/bin-show-$mode"
    _make_stubs "$bin" "$mode"
    PATH="$bin:$PATH" AWG_DIR="$BATS_TEST_TMPDIR/awg" \
    env --default-signal=PIPE timeout 60 bash -c '
        set -o pipefail
        log()       { echo "INFO: $*"; }
        log_warn()  { echo "WARN: $*"; }
        log_error() { echo "ERR: $*"; }
        log_debug() { :; }
        source "$1" >/dev/null 2>&1 || true
        if [[ "${BROKEN_MASK:-0}" == 1 ]]; then _mask_report_secrets() { exec 0<&-; return 3; }; fi
        if [[ "${BROKEN_MASK:-0}" == 2 ]]; then _mask_report_secrets() { cat >/dev/null; return 3; }; fi
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
    rm -f "$BATS_TEST_TMPDIR/slow-finished"
    BROKEN_MASK=1 run _run_show "$1" slow
    # Without SIGPIPE (ignored by a parent) awg show exits 0, and the 141 case this test
    # exists for would not be exercised: fail loudly instead of passing vacuously.
    [ ! -e "$BATS_TEST_TMPDIR/slow-finished" ] || { echo "precondition: awg show was not killed by SIGPIPE ($1)"; return 1; }
    [ "$status" -eq 1 ] || { echo "show passed with a failed secrets filter ($1): status $status $output"; return 1; }
    [[ "$output" == *"$want"* ]] || { echo "filter failure not named ($1), expected '$want': $output"; return 1; }
    [[ "$output" != *"$wrong"* ]] || { echo "a filter failure was reported as an awg show failure ($1): $output"; return 1; }
    # The broken filter here prints nothing, so this can only fail if that override or
    # show_awg_status itself starts printing the awg show output unfiltered.
    [[ "$output" != *"$SECRET"* ]] || { echo "the key leaked when the filter failed ($1): $output"; return 1; }
}
@test "show: a failed secrets filter is named as such, not as an awg show failure, both twins" {
    both s_filter_fails
}

s_filter_fails_awg_ok() {
    # The filter reads everything and then fails, so awg show exits 0: what a filter that
    # fails after reading its input produces, and what awg show returns under an inherited
    # SIGPIPE ignore. No signal is involved, so the test does not depend on the host.
    local want="The secrets filter failed" wrong="awg show failed"
    ru "$1" && { want="Фильтр секретов не отработал"; wrong="Ошибка awg show"; }
    BROKEN_MASK=2 run _run_show "$1" ok
    [ "$status" -eq 1 ] || { echo "show passed with a failed filter after a successful awg show ($1): status $status $output"; return 1; }
    [[ "$output" == *"$want"* ]] || { echo "filter failure not named ($1), expected '$want': $output"; return 1; }
    [[ "$output" != *"$wrong"* ]] || { echo "a successful awg show was reported as failed ($1): $output"; return 1; }
    [[ "$output" != *"$SECRET"* ]] || { echo "the key leaked when the filter failed ($1): $output"; return 1; }
}
@test "show: a failed secrets filter fails show even when awg show succeeded, both twins" {
    both s_filter_fails_awg_ok
}

s_filter_and_timeout() {
    local want="The secrets filter failed" timed="did not answer within 10 seconds"
    ru "$1" && { want="Фильтр секретов не отработал"; timed="не ответил за 10 секунд"; }
    BROKEN_MASK=1 run _run_show "$1" timeout
    [ "$status" -eq 1 ] || { echo "show passed with a failed filter and a timeout ($1): status $status"; return 1; }
    [[ "$output" == *"$want"* ]] || { echo "filter failure not named ($1): $output"; return 1; }
    [[ "$output" == *"$timed"* ]] || { echo "a timeout next to a failed filter is not named ($1): $output"; return 1; }
}
@test "show: a timeout is still named when the secrets filter failed too, both twins" {
    both s_filter_and_timeout
}

s_filter_and_awg_fail() {
    local want="The secrets filter failed" code="awg show failed (code 1)."
    ru "$1" && { want="Фильтр секретов не отработал"; code="Ошибка awg show (код 1)."; }
    BROKEN_MASK=1 run _run_show "$1" failempty
    [ "$status" -eq 1 ] || { echo "show passed with a failed filter and a failed awg show ($1): status $status"; return 1; }
    [[ "$output" == *"$want"* ]] || { echo "filter failure not named ($1): $output"; return 1; }
    [[ "$output" == *"$code"* ]] || { echo "a failed awg show next to a failed filter is not named by its code ($1): $output"; return 1; }
}
@test "show: a failed awg show is still named by its code when the secrets filter failed too, both twins" {
    both s_filter_and_awg_fail
}

s_fail_empty() {
    local want="awg show failed (code 1)."
    ru "$1" && want="Ошибка awg show (код 1)."
    run _run_show "$1" failempty
    [ "$status" -eq 1 ] || { echo "a silent failing awg show did not fail show ($1): status $status"; return 1; }
    [[ "$output" == *"$want"* ]] || { echo "show does not name the awg show status ($1), expected '$want': $output"; return 1; }
}
@test "show: a failed awg show is named by its code, like in check, both twins" {
    both s_fail_empty
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

# ---------------------------------------------------------------- colour mode

# awg show colours its labels when WG_COLOR_MODE=always, even into a pipe. The
# filter matches the plain label, so a coloured "header protection key" line went
# through with the key. The stub colours exactly like the tool: only when the
# variable says always.
_make_colour_awg() {
    local bin="$1"
    mkdir -p "$bin"
    cat > "$bin/awg" <<EOF
#!/usr/bin/env bash
b=""; r=""
if [[ "\${WG_COLOR_MODE:-}" == always ]]; then b=\$'\e[1m'; r=\$'\e[0m'; fi
printf '%sinterface%s: awg0\n' "\$b" "\$r"
printf '  %sheader protection key%s: %s\n' "\$b" "\$r" "${SECRET}"
printf '  %sjc%s: 6\n' "\$b" "\$r"
exit 0
EOF
    chmod +x "$bin/awg"
}

# _run_show_colour <manage script> <with the script's own colour setting 0|1>
_run_show_colour() {
    local src="$1" apply="$2" common bin dir
    common="${src/manage_amneziawg/awg_common}"
    bin="$BATS_TEST_TMPDIR/bin-colour"
    dir="$BATS_TEST_TMPDIR/awg-colour"
    _make_colour_awg "$bin"
    mkdir -p "$dir"
    PATH="$bin:$PATH" AWG_DIR="$dir" CONFIG_FILE="$dir/awgsetup_cfg.init" WG_COLOR_MODE=always _APPLY="$apply" \
    timeout 60 bash -c '
        set -o pipefail
        log()       { echo "INFO: $*"; }
        log_warn()  { echo "WARN: $*"; }
        log_error() { echo "ERR: $*"; }
        log_debug() { :; }
        source "$1" >/dev/null 2>&1 || true
        if [[ "$_APPLY" == 1 ]]; then
            eval "$(grep -m1 "^export WG_COLOR_MODE=" "$2")"
        fi
        eval "$(awk "/^show_awg_status\\(\\) \\{/,/^\\}/" "$2")"
        show_awg_status
    ' _ "$common" "$src"
}

c_colour() {
    # Control first: without the setting the stub really leaks, so the second
    # half cannot pass by accident.
    run _run_show_colour "$1" 0
    [[ "$output" == *"$SECRET"* ]] || { echo "the control did not leak, the stub is not colouring ($1): $output"; return 1; }
    run _run_show_colour "$1" 1
    [[ "$output" != *"$SECRET"* ]] || { echo "the key leaked through coloured output ($1): $output"; return 1; }
    [[ "$output" == *"jc: 6"* ]] || { echo "the dump is gone ($1): $output"; return 1; }
}
@test "show: WG_COLOR_MODE=always in the environment does not let the key through, both twins" {
    both c_colour
}

@test "colour mode: all four entry scripts switch tool colour off at top level" {
    local f n_set n_color
    for f in manage_amneziawg.sh manage_amneziawg_en.sh install_amneziawg.sh install_amneziawg_en.sh; do
        n_set=$(grep -n '^set -o pipefail$' "$BATS_TEST_DIRNAME/../$f" | head -1 | cut -d: -f1)
        n_color=$(grep -n '^export WG_COLOR_MODE=never$' "$BATS_TEST_DIRNAME/../$f" | head -1 | cut -d: -f1)
        [ -n "$n_color" ] || { echo "no top-level WG_COLOR_MODE=never in $f"; return 1; }
        [ "$n_color" -gt "$n_set" ] && [ "$((n_color - n_set))" -lt 10 ] || { echo "WG_COLOR_MODE=never is not at the top of $f"; return 1; }
    done
}
