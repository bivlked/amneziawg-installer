#!/usr/bin/env bats
# manage shows the protocol generation of the installation, read from the marker.
#
# The generation comes from AWG_PROTOCOL in awgsetup_cfg.init and never from the
# module version: a third-line module happily runs a second-line configuration,
# and a header saying "AmneziaWG 2.0" next to a module version 3.1 already
# confused people. So check, show and diagnose print the generation on a line of
# its own, the command headers stop naming a generation, and check --json carries
# it in the "protocol" field.
#
# An unreadable marker is an error, never a quiet "2.0": check turns ok=false with
# rc 1 (owner decision 17 sep 2026), show and diagnose say the marker is unreadable.
#
# Harness: the whole awg_common.sh is sourced (the real safe_load_config and the
# real marker reader, so the init file is what decides), the manage functions are
# lifted out of the script, and every system command is a stub in front of PATH.
# Each case runs both twins.

bats_require_minimum_version 1.5.0

_make_stubs() {
    local bin="$1" jmin="${2:-40}" jmax="${3:-70}"
    mkdir -p "$bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/systemctl"
    printf '#!/usr/bin/env bash\necho "5: awg0: <POINTOPOINT,UP> mtu 1280 state UNKNOWN"\necho "    inet 10.9.9.1/24 scope global awg0"\n' > "$bin/ip"
    printf '#!/usr/bin/env bash\necho "UNCONN 0 0 0.0.0.0:39743 0.0.0.0:*"\n' > "$bin/ss"
    printf '#!/usr/bin/env bash\necho 1\n' > "$bin/sysctl"
    printf '#!/usr/bin/env bash\necho "amneziawg 155648 0"\n' > "$bin/lsmod"
    printf '#!/usr/bin/env bash\necho "Status: active"\necho "39743/udp ALLOW Anywhere"\n' > "$bin/ufw"
    cat > "$bin/awg" <<EOF
#!/usr/bin/env bash
echo "interface: awg0"
echo "  public key: PUBLICKEYKEEPAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
echo "  jc: 4"
echo "  jmin: ${jmin}"
echo "  jmax: ${jmax}"
exit 0
EOF
    chmod +x "$bin"/*
}

# _write_init <marker line or empty>
_write_init() {
    local dir="$BATS_TEST_TMPDIR/awg"
    mkdir -p "$dir"
    printf 'export AWG_PORT=39743\n' > "$dir/awgsetup_cfg.init"
    [[ -n "$1" ]] && printf '%s\n' "$1" >> "$dir/awgsetup_cfg.init"
    printf '[Interface]\nListenPort = 39743\n' > "$dir/awg0.conf"
}

# _run <manage script> <function> <json 0|1> [jmin jmax]
# Logs go to stdout for human runs and to stderr for --json runs, the way the
# script routes them, so $output is exactly the JSON document there.
_run() {
    local src="$1" fn="$2" json="$3" common bin dir
    common="${src/manage_amneziawg/awg_common}"
    bin="$BATS_TEST_TMPDIR/bin"
    dir="$BATS_TEST_TMPDIR/awg"
    _make_stubs "$bin" "${4:-40}" "${5:-70}"
    PATH="$bin:$PATH" AWG_DIR="$dir" CONFIG_FILE="$dir/awgsetup_cfg.init" SERVER_CONF_FILE="$dir/awg0.conf" \
    _JSON="$json" timeout 60 bash -c '
        set -o pipefail
        if [[ "$_JSON" == 1 ]]; then
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
        JSON_OUTPUT="$_JSON"
        _JSON_EMITTED=0
        NO_COLOR=1
        CLI_CARRIER=""
        for f in _json_utf8_sanitize json_escape json_out check_server show_awg_status \
                 _diagnose_carrier_known _diagnose_carrier_list _diag_line _diag_cps_guard diagnose_server; do
            eval "$(awk "/^${f}\\(\\) \\{/,/^\\}/" "$2")"
        done
        "$3"
    ' _ "$common" "$src" "$fn"
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

# gen_line <src> : the text of the generation line, in the language of the script
gen_line() {
    if ru "$1"; then echo "Поколение протокола установки"; else echo "Installation protocol generation"; fi
}
unreadable_text() {
    if ru "$1"; then echo "не читается"; else echo "cannot be read"; fi
}

# ------------------------------------------------------------------ check

c_text_31() {
    _write_init "export AWG_PROTOCOL='3.1'"
    run _run "$1" check_server 0
    [ "$status" -eq 0 ] || { echo "check failed on a healthy 3.1 stub ($1): $output"; return 1; }
    [[ "$output" == *"$(gen_line "$1"): 3.1"* ]] || { echo "no 3.1 generation line ($1): $output"; return 1; }
}
@test "check: prints the generation from the marker (3.1), both twins" {
    both c_text_31
}

c_text_absent() {
    _write_init ""
    run _run "$1" check_server 0
    [ "$status" -eq 0 ] || { echo "check failed on a healthy stub ($1): $output"; return 1; }
    [[ "$output" == *"$(gen_line "$1"): 2.0"* ]] || { echo "absent marker is not 2.0 ($1): $output"; return 1; }
}
@test "check: an installation without the marker is 2.0, both twins" {
    both c_text_absent
}

c_text_broken() {
    _write_init "export AWG_PROTOCOL='9.9'"
    run _run "$1" check_server 0
    [ "$status" -eq 1 ] || { echo "an unreadable marker did not fail check ($1): status $status"; return 1; }
    [[ "$output" == *"ERR: "*"AWG_PROTOCOL"*"$(unreadable_text "$1")"* ]] || { echo "no unreadable-marker error ($1): $output"; return 1; }
    [[ "$output" != *"$(gen_line "$1"): 2.0"* ]] || { echo "a broken marker was shown as 2.0 ($1): $output"; return 1; }
}
@test "check: an unreadable marker fails check and is never shown as 2.0, both twins" {
    both c_text_broken
}

# shellcheck disable=SC2154  # $stderr is provided by bats `run --separate-stderr`
c_json_31() {
    _write_init "export AWG_PROTOCOL='3.1'"
    run --separate-stderr _run "$1" check_server 1
    [ "$status" -eq 0 ] || { echo "rc $status ($1): $output / $stderr"; return 1; }
    printf '%s' "$output" | jq -e '.ok == true and .protocol == "3.1" and .protocol_error == null' >/dev/null \
        || { echo "bad envelope ($1): $output"; return 1; }
}
@test "check --json: protocol is the marker value and protocol_error is null, both twins" {
    command -v jq &>/dev/null || skip "jq not available"
    both c_json_31
}

# shellcheck disable=SC2154  # $stderr is provided by bats `run --separate-stderr`
c_json_broken() {
    _write_init "export AWG_PROTOCOL='9.9'"
    run --separate-stderr _run "$1" check_server 1
    [ "$status" -eq 1 ] || { echo "rc $status ($1): $output"; return 1; }
    printf '%s' "$output" | jq -e '.ok == false and .protocol == null and .protocol_error == "unreadable"' >/dev/null \
        || { echo "bad envelope ($1): $output"; return 1; }
    [[ "$stderr" == *"AWG_PROTOCOL"* ]] || { echo "the reason did not reach stderr ($1): $stderr"; return 1; }
}
@test "check --json: an unreadable marker gives protocol null, protocol_error unreadable, ok false, both twins" {
    command -v jq &>/dev/null || skip "jq not available"
    both c_json_broken
}

# ------------------------------------------------------------------ show

s_31() {
    _write_init "export AWG_PROTOCOL='3.1'"
    run _run "$1" show_awg_status 0
    [ "$status" -eq 0 ] || { echo "show failed ($1): $output"; return 1; }
    [[ "$output" == *"$(gen_line "$1"): 3.1"* ]] || { echo "no generation line in show ($1): $output"; return 1; }
    [[ "$output" == *"jc: 4"* ]] || { echo "awg show output missing ($1): $output"; return 1; }
}
@test "show: prints the generation before the interface dump, both twins" {
    both s_31
}

s_broken() {
    _write_init "export AWG_PROTOCOL='9.9'"
    run _run "$1" show_awg_status 0
    [[ "$output" == *"ERR: "*"AWG_PROTOCOL"*"$(unreadable_text "$1")"* ]] || { echo "no unreadable-marker error in show ($1): $output"; return 1; }
    [[ "$output" != *"$(gen_line "$1"): 2.0"* ]] || { echo "a broken marker was shown as 2.0 ($1): $output"; return 1; }
}
@test "show: an unreadable marker is reported, never shown as 2.0, both twins" {
    both s_broken
}

# ------------------------------------------------------------------ diagnose

d_31() {
    _write_init "export AWG_PROTOCOL='3.1'"
    run _run "$1" diagnose_server 0
    local want
    if ru "$1"; then want="Поколение конфигурации: 3.1"; else want="Configuration generation: 3.1"; fi
    [[ "$output" == *"[INFO] $want"* ]] || { echo "no generation line in diagnose ($1): $output"; return 1; }
}
@test "diagnose: prints the configuration generation as INFO, both twins" {
    both d_31
}

d_broken() {
    _write_init "export AWG_PROTOCOL='9.9'"
    run _run "$1" diagnose_server 0
    [[ "$output" == *"[FAIL] "*"AWG_PROTOCOL"*"$(unreadable_text "$1")"* ]] || { echo "no FAIL for the unreadable marker ($1): $output"; return 1; }
}
@test "diagnose: an unreadable marker is a FAIL line, both twins" {
    both d_broken
}

d_jmin_gt_jmax() {
    _write_init ""
    run _run "$1" diagnose_server 0 90 50
    [[ "$output" == *"[FAIL] "*"Jmin"*"90"*"Jmax"*"50"* ]] || { echo "Jmin > Jmax not reported ($1): $output"; return 1; }
    [[ "$output" == *"#225"* ]] || { echo "the upstream reference is missing ($1): $output"; return 1; }
}
@test "diagnose: live Jmin greater than Jmax is a FAIL line, both twins" {
    both d_jmin_gt_jmax
}

d_jmin_le_jmax() {
    _write_init ""
    run _run "$1" diagnose_server 0 50 50
    [[ "$output" != *"#225"* ]] || { echo "equal Jmin and Jmax reported as a defect ($1): $output"; return 1; }
    [[ "$output" == *"Jmin=50 Jmax=50"* ]] || { echo "interface was not read ($1): $output"; return 1; }
}
@test "diagnose: Jmin equal to Jmax is not reported, both twins" {
    both d_jmin_le_jmax
}

# ------------------------------------------------------------------ headers

@test "headers: check, show, diagnose and help no longer name a generation" {
    local f fn body
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        for fn in check_server show_awg_status diagnose_server usage; do
            body=$(awk "/^${fn}\\(\\) \\{/,/^\\}/" "$BATS_TEST_DIRNAME/../$f")
            [ -n "$body" ] || { echo "$fn not found in $f"; return 1; }
            if grep -nE '(log|log_warn|echo)[^#]*(AmneziaWG|AWG) 2\.0' <<< "$body"; then
                echo "generation literal left in $fn ($f)"
                return 1
            fi
        done
    done
}

@test "render: no generated config writes RandomTrailers" {
    # RandomTrailers cuts off 3.0 clients; it must never appear by default.
    local f
    for f in awg_common.sh awg_common_en.sh install_amneziawg.sh install_amneziawg_en.sh; do
        run grep -nE '^[[:space:]]*(echo[[:space:]]+"|printf[^"]*")?RandomTrailers[[:space:]]*=' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 1 ] || { echo "RandomTrailers written by $f: $output"; return 1; }
    done
}
