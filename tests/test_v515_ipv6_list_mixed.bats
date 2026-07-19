#!/usr/bin/env bats
# Phase 5 - manage list dual-stack display.
#
# Verifies that list_clients correctly shows:
#   - dual-stack clients: "10.9.9.2 / fddd:2c4:2c4:2c4::2"
#   - IPv4-only clients:  "10.9.9.2 / -"
# and that --json output includes client_ipv6 field for both cases.
#
# Since manage_amneziawg.sh has a runnable main block (not source-safe),
# integration tests use a source-safe loader that extracts only the
# functions defined after the argument-parsing preamble.
# Structural/grep tests verify the source directly.

load test_helper

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_add_dualstack_peer() {
    local name="$1" ipv4="$2" ipv6="$3"
    cat >> "$SERVER_CONF_FILE" << EOF

[Peer]
#_Name = ${name}
PublicKey = PK_${name}
AllowedIPs = ${ipv4}/32, ${ipv6}/128
EOF
}

_add_ipv4only_peer() {
    local name="$1" ipv4="$2"
    cat >> "$SERVER_CONF_FILE" << EOF

[Peer]
#_Name = ${name}
PublicKey = PK_${name}
AllowedIPs = ${ipv4}/32
EOF
}

_make_client_conf_dualstack() {
    local name="$1" ipv4="$2" ipv6="$3"
    cat > "$AWG_DIR/${name}.conf" << EOF
[Interface]
PrivateKey = PRIV_${name}
Address = ${ipv4}/32, ${ipv6}/128
DNS = 1.1.1.1
MTU = 1280
PersistentKeepalive = 33
[Peer]
PublicKey = SERVERPUB
AllowedIPs = 0.0.0.0/0, ::/0
EOF
}

_make_client_conf_ipv4only() {
    local name="$1" ipv4="$2"
    cat > "$AWG_DIR/${name}.conf" << EOF
[Interface]
PrivateKey = PRIV_${name}
Address = ${ipv4}/32
DNS = 1.1.1.1
MTU = 1280
PersistentKeepalive = 33
[Peer]
PublicKey = SERVERPUB
AllowedIPs = 0.0.0.0/0
EOF
}

# Extract just the list_clients + json_escape + format_remaining functions from
# manage_amneziawg.sh into a small source-safe subshell context.
# Writes extracted functions to a temp file, then sources it.
_load_list_clients_ru() {
    local src="${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"
    # Stub everything list_clients depends on that we don't need
    JSON_OUTPUT="${JSON_OUTPUT:-0}"
    VERBOSE_LIST="${VERBOSE_LIST:-0}"
    NO_COLOR="${NO_COLOR:-1}"

    json_escape() {
        local s="$1"
        s="${s//\\/\\\\}"
        s="${s//\"/\\\"}"
        printf '%s' "$s"
    }
    format_remaining() { echo "soon"; }
    get_client_expiry() { echo ""; }
    awg() { return 1; }
    # v5.21.0: list_clients emits through json_out (single-emission point).
    json_out() { printf '%s
' "$1"; }

    # Source only the list_clients function body by eval-ing it
    eval "$(awk '/^list_clients\(\)/{p=1} p{print} p && /^\}$/{exit}' "$src")"
}

_load_list_clients_en() {
    local src="${BATS_TEST_DIRNAME}/../manage_amneziawg_en.sh"
    JSON_OUTPUT="${JSON_OUTPUT:-0}"
    VERBOSE_LIST="${VERBOSE_LIST:-0}"
    NO_COLOR="${NO_COLOR:-1}"

    json_escape() {
        local s="$1"
        s="${s//\\/\\\\}"
        s="${s//\"/\\\"}"
        printf '%s' "$s"
    }
    format_remaining() { echo "soon"; }
    get_client_expiry() { echo ""; }
    awg() { return 1; }
    # v5.21.0: list_clients emits through json_out (single-emission point).
    json_out() { printf '%s
' "$1"; }

    eval "$(awk '/^list_clients\(\)/{p=1} p{print} p && /^\}$/{exit}' "$src")"
}

# ---------------------------------------------------------------------------
# Display tests - verbose mode (VERBOSE_LIST=1)
# ---------------------------------------------------------------------------

@test "v5.15: list verbose shows 'ip / ipv6' for dual-stack client (RU)" {
    create_server_config
    _add_dualstack_peer "alice" "10.9.9.2" "fddd:2c4:2c4:2c4::2"
    _make_client_conf_dualstack "alice" "10.9.9.2" "fddd:2c4:2c4:2c4::2"

    export VERBOSE_LIST=1
    export JSON_OUTPUT=0
    export NO_COLOR=1
    _load_list_clients_ru

    run list_clients
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "10.9.9.2 / fddd:2c4:2c4:2c4::2"
}

@test "v5.15: list verbose shows 'ip / -' for IPv4-only client (RU)" {
    create_server_config
    _add_ipv4only_peer "legacy" "10.9.9.3"
    _make_client_conf_ipv4only "legacy" "10.9.9.3"

    export VERBOSE_LIST=1
    export JSON_OUTPUT=0
    export NO_COLOR=1
    _load_list_clients_ru

    run list_clients
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "10.9.9.3 / -"
}

@test "v5.15: list verbose mixed state shows both formats (RU)" {
    create_server_config
    _add_dualstack_peer "ds_client" "10.9.9.2" "fddd:2c4:2c4:2c4::2"
    _add_ipv4only_peer  "v4_client" "10.9.9.3"
    _make_client_conf_dualstack "ds_client" "10.9.9.2" "fddd:2c4:2c4:2c4::2"
    _make_client_conf_ipv4only  "v4_client" "10.9.9.3"

    export VERBOSE_LIST=1
    export JSON_OUTPUT=0
    export NO_COLOR=1
    _load_list_clients_ru

    run list_clients
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "10.9.9.2 / fddd:2c4:2c4:2c4::2"
    echo "$output" | grep -q "10.9.9.3 / -"
}

@test "v5.15: list verbose shows dual-stack format (EN)" {
    create_server_config
    _add_dualstack_peer "bob" "10.9.9.2" "fddd:2c4:2c4:2c4::2"
    _make_client_conf_dualstack "bob" "10.9.9.2" "fddd:2c4:2c4:2c4::2"

    export VERBOSE_LIST=1
    export JSON_OUTPUT=0
    export NO_COLOR=1
    _load_list_clients_en

    run list_clients
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "10.9.9.2 / fddd:2c4:2c4:2c4::2"
}

# ---------------------------------------------------------------------------
# JSON output tests
# ---------------------------------------------------------------------------

@test "v5.15: list --json includes client_ipv6 for dual-stack client (RU)" {
    create_server_config
    _add_dualstack_peer "ds_json" "10.9.9.2" "fddd:2c4:2c4:2c4::2"
    _make_client_conf_dualstack "ds_json" "10.9.9.2" "fddd:2c4:2c4:2c4::2"

    export VERBOSE_LIST=0
    export JSON_OUTPUT=1
    export NO_COLOR=1
    _load_list_clients_ru

    run list_clients
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"client_ipv6":"fddd:2c4:2c4:2c4::2"'
}

@test "v5.15: list --json includes empty client_ipv6 for IPv4-only client (RU)" {
    create_server_config
    _add_ipv4only_peer "v4_json" "10.9.9.3"
    _make_client_conf_ipv4only "v4_json" "10.9.9.3"

    export VERBOSE_LIST=0
    export JSON_OUTPUT=1
    export NO_COLOR=1
    _load_list_clients_ru

    run list_clients
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"client_ipv6":""'
}

@test "v5.15: list --json is a valid array with both entries" {
    create_server_config
    _add_dualstack_peer "a" "10.9.9.2" "fddd:2c4:2c4:2c4::2"
    _add_ipv4only_peer  "b" "10.9.9.3"
    _make_client_conf_dualstack "a" "10.9.9.2" "fddd:2c4:2c4:2c4::2"
    _make_client_conf_ipv4only  "b" "10.9.9.3"

    export VERBOSE_LIST=0
    export JSON_OUTPUT=1
    export NO_COLOR=1
    _load_list_clients_ru

    run list_clients
    [ "$status" -eq 0 ]
    [[ "$output" == "["* ]]
    [[ "$output" == *"]" ]]
    echo "$output" | grep -q '"name":"a"'
    echo "$output" | grep -q '"name":"b"'
}

@test "v5.15: list --json empty list returns empty array" {
    create_server_config  # no peers

    export VERBOSE_LIST=0
    export JSON_OUTPUT=1
    export NO_COLOR=1
    _load_list_clients_ru

    run list_clients
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}

@test "v5.15: list --json includes client_ipv6 for dual-stack (EN)" {
    create_server_config
    _add_dualstack_peer "ds_en" "10.9.9.2" "fddd:2c4:2c4:2c4::2"
    _make_client_conf_dualstack "ds_en" "10.9.9.2" "fddd:2c4:2c4:2c4::2"

    export VERBOSE_LIST=0
    export JSON_OUTPUT=1
    export NO_COLOR=1
    _load_list_clients_en

    run list_clients
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"client_ipv6":"fddd:2c4:2c4:2c4::2"'
}

# ---------------------------------------------------------------------------
# Structural/grep tests (no execution needed)
# ---------------------------------------------------------------------------

@test "v5.15: RU manage_amneziawg.sh list_clients uses awk for Address extraction" {
    grep -q "awk.*Address" "${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"
}

@test "v5.15: EN manage_amneziawg_en.sh list_clients uses awk for Address extraction" {
    grep -q "awk.*Address" "${BATS_TEST_DIRNAME}/../manage_amneziawg_en.sh"
}

@test "v5.15: RU manage_amneziawg.sh list_clients includes client_ipv6 in JSON" {
    grep -q 'client_ipv6' "${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"
}

@test "v5.15: EN manage_amneziawg_en.sh list_clients includes client_ipv6 in JSON" {
    grep -q 'client_ipv6' "${BATS_TEST_DIRNAME}/../manage_amneziawg_en.sh"
}
