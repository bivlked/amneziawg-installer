#!/usr/bin/env bats
# manage check must see a listening port however long the ss output is.
#
# check_server used `if ! ss -lunp | grep -q ":${port} "` under the global
# `set -o pipefail`. grep -q exits on the first match; ss, still writing the other
# sockets, dies of SIGPIPE, and pipefail turns the port that was found into "NOT
# listening": ok=0, rc 1 and `"listening":false` in --json. A server with many UDP
# listeners (containers, DNS, TURN) got a false alarm from its own monitoring.
#
# Harness: the real check_server lifted out of the manage script with the helpers it
# calls, every system command a stub in front of PATH. The ss stub prints our socket
# first and then 5000 other sockets, one write per line, well past a pipe buffer, so
# the reader that stops early kills it every time. SIGPIPE is set back to its default:
# a parent that ignores it (the GitHub runner does) passes the ignore down and would
# hide the defect. Log lines go to stderr, the JSON envelope to stdout.

PORT=39743

setup() {
    AWG_DIR="$BATS_TEST_TMPDIR/awg"
    mkdir -p "$AWG_DIR"
    CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init"
    SERVER_CONF_FILE="$AWG_DIR/awg0.conf"
    printf '[Interface]\nListenPort = %s\n[Peer]\n' "$PORT" > "$SERVER_CONF_FILE"
    # Nothing here writes a cron file; the path is pointed away from /etc anyway.
    EXPIRY_CRON="$BATS_TEST_TMPDIR/cron.d/awg-expiry"
    AWG_MODULE_VERSION_PATH="$BATS_TEST_TMPDIR/module-version"
    printf '1.0.0\n' > "$AWG_MODULE_VERSION_PATH"
    export AWG_DIR CONFIG_FILE SERVER_CONF_FILE EXPIRY_CRON AWG_MODULE_VERSION_PATH
}

# _make_stubs <bin> <ss mode>
#   big    - our socket first, then 5000 other sockets, one printf per line;
#   absent - the same 5000 sockets without ours;
#   fail   - our socket, then exit 1 (ss itself failed).
_make_stubs() {
    local bin="$1" mode="$2"
    mkdir -p "$bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/systemctl"
    printf '#!/usr/bin/env bash\necho "5: awg0: <POINTOPOINT,UP> mtu 1280"\necho "    inet 10.9.9.1/24 scope global awg0"\n' > "$bin/ip"
    printf '#!/usr/bin/env bash\necho 1\n' > "$bin/sysctl"
    printf '#!/usr/bin/env bash\necho "amneziawg 155648 0"\n' > "$bin/lsmod"
    printf '#!/usr/bin/env bash\necho "Status: active"\necho "%s/udp ALLOW Anywhere"\n' "$PORT" > "$bin/ufw"
    printf '#!/usr/bin/env bash\necho "interface: awg0"\necho "  jc: 6"\nexit 0\n' > "$bin/awg"
    case "$mode" in
        big|absent)
            cat > "$bin/ss" <<EOF
#!/usr/bin/env bash
printf 'State Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n'
if [[ "$mode" == big ]]; then
    printf 'UNCONN 0 0 0.0.0.0:${PORT} 0.0.0.0:*\n'
fi
for ((i = 0; i < 5000; i++)); do
    printf 'UNCONN 0 0 127.0.0.1:%d 0.0.0.0:* users:(("svc",pid=%d,fd=5))\n' \$((20000 + i)) \$((1000 + i))
done
EOF
            ;;
        fail)
            printf '#!/usr/bin/env bash\necho "UNCONN 0 0 0.0.0.0:%s 0.0.0.0:*"\nexit 1\n' "$PORT" > "$bin/ss"
            ;;
    esac
    chmod +x "$bin"/*
}

# _run_check <manage script> <ss mode> : stdout is the JSON envelope, the log lines
# land in $BATS_TEST_TMPDIR/log-<mode>.
_run_check() {
    local src="$1" mode="$2" common bin
    common="${src/manage_amneziawg/awg_common}"
    bin="$BATS_TEST_TMPDIR/bin-$mode"
    _make_stubs "$bin" "$mode"
    PATH="$bin:$PATH" \
    env --default-signal=PIPE timeout 60 bash -c '
        set -o pipefail
        log()       { echo "INFO: $*" >&2; }
        log_warn()  { echo "WARN: $*" >&2; }
        log_error() { echo "ERR: $*" >&2; }
        log_debug() { :; }
        safe_load_config() { AWG_PORT='"$PORT"'; return 0; }
        JSON_OUTPUT=1
        _JSON_EMITTED=0
        eval "$(awk "/^_sanitize_port\\(\\) \\{/,/^\\}/" "$1")"
        eval "$(awk "/^awg_module_version\\(\\) \\{/,/^\\}/" "$1")"
        eval "$(awk "/^awg_installed_protocol\\(\\) \\{/,/^\\}/" "$1")"
        eval "$(awk "/^_awg_generation_from_init\\(\\) \\{/,/^\\}/" "$1")"
        eval "$(awk "/^_mask_report_secrets\\(\\) \\{/,/^\\}/" "$1")"
        eval "$(awk "/^_json_utf8_sanitize\\(\\) \\{/,/^\\}/" "$2")"
        eval "$(awk "/^json_escape\\(\\) \\{/,/^\\}/" "$2")"
        eval "$(awk "/^json_out\\(\\) \\{/,/^\\}/" "$2")"
        eval "$(awk "/^check_server\\(\\) \\{/,/^\\}/" "$2")"
        declare -F check_server >/dev/null || { echo "NO_CHECK_FUNCTION"; exit 7; }
        check_server
    ' _ "$common" "$src" 2>"$BATS_TEST_TMPDIR/log-$mode"
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

require_jq() { command -v jq &>/dev/null || skip "jq not available"; }

c_big_found() {
    local bad="Port ${PORT}/udp is NOT listening" good="Port ${PORT}/udp is listening." log
    ru "$1" && { bad="Порт ${PORT}/udp НЕ прослушивается"; good="Порт ${PORT}/udp прослушивается."; }
    run _run_check "$1" big
    log=$(cat "$BATS_TEST_TMPDIR/log-big")
    [[ "$log" != *"$bad"* ]] || { echo "a listening port was reported as NOT listening ($1): $log"; return 1; }
    [[ "$log" == *"$good"* ]] || { echo "the port was not reported as listening ($1): $log"; return 1; }
    printf '%s' "$output" | jq -e '.port.listening == true' >/dev/null \
        || { echo "--json says the port is not listening ($1): $output"; return 1; }
    [ "$status" -eq 0 ] || { echo "check failed with every stub healthy ($1): status $status $output $log"; return 1; }
    printf '%s' "$output" | jq -e '.ok == true' >/dev/null || { echo "ok is not true ($1): $output"; return 1; }
}
@test "check: a listening port is found in a long ss output under pipefail, both twins" {
    require_jq
    both c_big_found
}

c_absent_not_listening() {
    local bad="Port ${PORT}/udp is NOT listening" log
    ru "$1" && bad="Порт ${PORT}/udp НЕ прослушивается"
    run _run_check "$1" absent
    log=$(cat "$BATS_TEST_TMPDIR/log-absent")
    [ "$status" -eq 1 ] || { echo "check passed without our socket in ss ($1): status $status $output"; return 1; }
    [[ "$log" == *"$bad"* ]] || { echo "a missing port was not reported as NOT listening ($1): $log"; return 1; }
    printf '%s' "$output" | jq -e '.ok == false and .port.listening == false' >/dev/null \
        || { echo "--json does not report the missing port ($1): $output"; return 1; }
}
@test "check: a port absent from a long ss output is still NOT listening, both twins" {
    require_jq
    both c_absent_not_listening
}

c_ss_fails() {
    local bad="Port ${PORT}/udp is NOT listening" log
    ru "$1" && bad="Порт ${PORT}/udp НЕ прослушивается"
    run _run_check "$1" fail
    log=$(cat "$BATS_TEST_TMPDIR/log-fail")
    [ "$status" -eq 1 ] || { echo "check passed although ss failed ($1): status $status $output"; return 1; }
    [[ "$log" == *"$bad"* ]] || { echo "a failed ss was not reported as NOT listening ($1): $log"; return 1; }
    printf '%s' "$output" | jq -e '.ok == false and .port.listening == false' >/dev/null \
        || { echo "--json trusts the output of a failed ss ($1): $output"; return 1; }
}
@test "check: a failed ss still means NOT listening, even if its output names the port, both twins" {
    require_jq
    both c_ss_fails
}
