#!/usr/bin/env bats
# v5.21.1: end-to-end contract of check --json with a broken AWG_PORT.
#
# The unit tests next door exercise _sanitize_port on its own. That is not
# enough: the port could be sanitized and the JSON still built from the raw
# variable, or the sanitized value could silently turn a corrupt config into
# a healthy-looking answer. This file runs the real check_server with the
# system commands stubbed out, then reads the actual envelope it printed.
#
# Scope note: config parsing stays out of it. safe_load_config is replaced by
# a stub that sets one variable, so the test controls exactly one input.
#
# What it pins:
#   - stdout parses as JSON whatever sits in AWG_PORT;
#   - port.number is always an integer;
#   - a config holding a non-port is reported as a failure (ok=false, rc 1),
#     not quietly waved through;
#   - a genuinely absent port stays a warning, as it always was.

require_jq() { command -v jq &>/dev/null || skip "jq not available"; }

# Stubs for everything check_server shells out to. Each one answers "healthy"
# so the only thing that can turn the result red is the port itself.
_make_stubs() {
    local bin="$1"
    mkdir -p "$bin"
    cat > "$bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    cat > "$bin/ip" <<'EOF'
#!/usr/bin/env bash
echo "5: awg0: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1420 qdisc noqueue state UNKNOWN"
echo "    inet 10.9.9.1/24 scope global awg0"
EOF
    # The listening socket matches the healthy port used below.
    cat > "$bin/ss" <<'EOF'
#!/usr/bin/env bash
echo "UNCONN 0 0 0.0.0.0:39743 0.0.0.0:*"
EOF
    cat > "$bin/sysctl" <<'EOF'
#!/usr/bin/env bash
echo 1
EOF
    cat > "$bin/lsmod" <<'EOF'
#!/usr/bin/env bash
echo "amneziawg 155648 0"
EOF
    cat > "$bin/ufw" <<'EOF'
#!/usr/bin/env bash
echo "Status: active"
echo "39743/udp                  ALLOW       Anywhere"
EOF
    cat > "$bin/awg" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$bin"/*
}

setup() {
    STUB_BIN="$BATS_TEST_TMPDIR/bin"
    _make_stubs "$STUB_BIN"
    AWG_DIR="$BATS_TEST_TMPDIR/awg"
    mkdir -p "$AWG_DIR"
    CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init"
    SERVER_CONF_FILE="$AWG_DIR/awg0.conf"
    printf '[Interface]\n[Peer]\n[Peer]\n' > "$SERVER_CONF_FILE"
    JSON_OUTPUT=1
    _JSON_EMITTED=0
    export AWG_DIR CONFIG_FILE SERVER_CONF_FILE JSON_OUTPUT
}

# Runs the real check_server in a subshell with the stubs in front of PATH.
# safe_load_config is replaced by a one-liner that exports the port under
# test, so the test controls exactly one input and nothing else.
_run_check() {
    local port_value="$1" src="${2:-$BATS_TEST_DIRNAME/../manage_amneziawg.sh}"
    # v5.21.2: _sanitize_port lives in awg_common*.sh now; check_server and the
    # JSON helpers still come from the manage script under test.
    local common_src="${src/manage_amneziawg/awg_common}"
    PATH="$STUB_BIN:$PATH" \
    AWG_DIR="$AWG_DIR" CONFIG_FILE="$CONFIG_FILE" SERVER_CONF_FILE="$SERVER_CONF_FILE" \
    _PORT_UNDER_TEST="$port_value" \
    bash -c '
        set -o pipefail
        log()       { :; }
        log_warn()  { :; }
        log_error() { :; }
        log_debug() { :; }
        safe_load_config() { [[ -n "${_PORT_UNDER_TEST+x}" ]] && AWG_PORT="$_PORT_UNDER_TEST"; return 0; }
        JSON_OUTPUT=1
        _JSON_EMITTED=0
        '"$(awk '/^_sanitize_port\(\) \{/,/^\}/' "$common_src")"'
        '"$(awk '/^_json_utf8_sanitize\(\) \{/,/^\}/' "$src")"'
        '"$(awk '/^json_escape\(\) \{/,/^\}/' "$src")"'
        '"$(awk '/^json_out\(\) \{/,/^\}/' "$src")"'
        '"$(awk '/^check_server\(\) \{/,/^\}/' "$src")"'
        check_server
    '
}

@test "check --json: healthy port gives ok=true and the real number" {
    require_jq
    run _run_check "39743"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.ok == true and .port.number == 39743' >/dev/null
}

@test "check --json: stdout parses for every broken port value" {
    require_jq
    # Marker lives in the per-test tmpdir: a shared /tmp path would race with
    # a parallel run and survive an interrupted one.
    local marker="$BATS_TEST_TMPDIR/executed"
    for p in "abc" "1 2" "70000" "65536" "99999999999999999999" '$(id)' "a[\$(touch $marker)]" "-5" "8.5"; do
        rm -f "$marker"
        run _run_check "$p"
        printf '%s' "$output" | jq -e . >/dev/null || { echo "[$p] produced unparseable output: $output"; return 1; }
        printf '%s' "$output" | jq -e '.port.number | type == "number"' >/dev/null \
            || { echo "[$p] port.number is not a number"; return 1; }
        [ ! -f "$marker" ] || { echo "[$p] executed a command"; return 1; }
    done
}

@test "check --json: a config holding a non-port is reported as a failure" {
    require_jq
    # Everything else is stubbed healthy, so ok=false can only come from the
    # port. Silently returning ok=true here would hide a broken config from
    # any monitoring that polls this command.
    for p in "abc" "70000" "0"; do
        run _run_check "$p"
        [ "$status" -eq 1 ] || { echo "[$p] exited $status, expected 1"; return 1; }
        printf '%s' "$output" | jq -e '.ok == false' >/dev/null \
            || { echo "[$p] reported ok=true for a corrupt port"; return 1; }
        printf '%s' "$output" | jq -e '.port.number == 0' >/dev/null \
            || { echo "[$p] port.number is not 0"; return 1; }
    done
}

@test "check --json: an absent port stays a warning, not a failure" {
    require_jq
    # Historical behaviour: a missing setting is not proof of a broken server.
    run _run_check ""
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.ok == true and .port.number == 0' >/dev/null
}

@test "check --json: a genuinely unset AWG_PORT behaves like an empty one" {
    require_jq
    # The case above passes an empty string; this one never sets the variable
    # at all, which is what a config without the key actually produces.
    run env PATH="$STUB_BIN:$PATH" AWG_DIR="$AWG_DIR" CONFIG_FILE="$CONFIG_FILE" \
        SERVER_CONF_FILE="$SERVER_CONF_FILE" bash -c '
            set -o pipefail
            log() { :; }; log_warn() { :; }; log_error() { :; }; log_debug() { :; }
            safe_load_config() { return 0; }
            JSON_OUTPUT=1
            _JSON_EMITTED=0
            '"$(awk '/^_sanitize_port\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../awg_common.sh")"'
            '"$(awk '/^_json_utf8_sanitize\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh")"'
            '"$(awk '/^json_escape\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh")"'
            '"$(awk '/^json_out\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh")"'
            '"$(awk '/^check_server\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh")"'
            check_server
        '
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.ok == true and .port.number == 0' >/dev/null
}

@test "check --json: exactly one JSON document on stdout" {
    require_jq
    run _run_check "abc"
    [ "$(printf '%s' "$output" | grep -c '^{')" -eq 1 ]
    printf '%s' "$output" | jq -e . >/dev/null
}

@test "EN check --json behaves identically" {
    require_jq
    local en="$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
    run _run_check "abc" "$en"
    [ "$status" -eq 1 ]
    printf '%s' "$output" | jq -e '.ok == false and .port.number == 0' >/dev/null
    run _run_check "39743" "$en"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.ok == true and .port.number == 39743' >/dev/null
}
