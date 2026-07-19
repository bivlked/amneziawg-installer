#!/usr/bin/env bats
# Machine-stable status_code enum in list --json and stats --json (finding 1bkk.6).
#
# The localized `status` field (Активен/Active, Недавно/Recent, ...) is kept for
# display, and a language-independent `status_code` enum is added alongside:
#   active | recent | inactive | no_handshake | key_error | no_data
# Behavioral tests run list_clients with JSON output; source-level tests cover
# both list and stats emitters in both language variants.
#
# shellcheck disable=SC2034  # VERBOSE_LIST/NO_COLOR are consumed by the eval'd list_clients

load test_helper

_add_peer() {
    local name="$1" ipv4="$2"
    cat >> "$SERVER_CONF_FILE" << EOF

[Peer]
#_Name = ${name}
PublicKey = PK_${name}
AllowedIPs = ${ipv4}/32
EOF
}

_make_client_conf() {
    local name="$1" ipv4="$2"
    cat > "$AWG_DIR/${name}.conf" << EOF
[Interface]
PrivateKey = PRIV_${name}
Address = ${ipv4}/32
DNS = 1.1.1.1
MTU = 1280
[Peer]
PublicKey = SERVERPUB
AllowedIPs = 0.0.0.0/0
EOF
}

# Source-safe loader: extract list_clients with the stubs it depends on.
_load_list_clients() {
    local src="$1"
    JSON_OUTPUT="${JSON_OUTPUT:-1}"
    VERBOSE_LIST=0
    NO_COLOR=1
    json_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }
    # v5.21.0: list_clients emits through json_out (single-emission point).
    json_out() { printf '%s\n' "$1"; }
    format_remaining() { echo "soon"; }
    get_client_expiry() { echo ""; }
    awg() { return 1; }
    eval "$(awk '/^list_clients\(\)/{p=1} p{print} p && /^\}$/{exit}' "$src")"
}

# Valid enum members - any emitted status_code must be one of these.
_VALID_CODES_RE='"status_code":"(active|recent|inactive|no_handshake|key_error|no_data)"'

@test "1bkk.6: list --json emits a valid status_code enum (RU)" {
    create_server_config
    _add_peer "alice" "10.9.9.2"
    _make_client_conf "alice" "10.9.9.2"

    export JSON_OUTPUT=1
    _load_list_clients "${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"

    run list_clients
    [ "$status" -eq 0 ]
    echo "$output" | grep -qE "$_VALID_CODES_RE" || { echo "no valid status_code in: $output"; false; }
}

@test "1bkk.6: list --json emits a valid status_code enum (EN)" {
    create_server_config
    _add_peer "bob" "10.9.9.2"
    _make_client_conf "bob" "10.9.9.2"

    export JSON_OUTPUT=1
    _load_list_clients "${BATS_TEST_DIRNAME}/../manage_amneziawg_en.sh"

    run list_clients
    [ "$status" -eq 0 ]
    echo "$output" | grep -qE "$_VALID_CODES_RE" || { echo "no valid status_code in: $output"; false; }
}

@test "1bkk.6: list --json keeps localized status alongside status_code (RU)" {
    create_server_config
    _add_peer "carol" "10.9.9.2"
    _make_client_conf "carol" "10.9.9.2"

    export JSON_OUTPUT=1
    _load_list_clients "${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"

    run list_clients
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"status":"'
    echo "$output" | grep -q '"status_code":"'
}

@test "1bkk.6 source: both list and stats JSON emitters include status_code (RU)" {
    local f="${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"
    local n
    n=$(grep -cE 'json_entries\+=.*status_code' "$f" || true)
    [ "$n" -ge 2 ] || { echo "expected >=2 json emitters with status_code, got $n"; false; }
}

@test "1bkk.6 source: both list and stats JSON emitters include status_code (EN)" {
    local f="${BATS_TEST_DIRNAME}/../manage_amneziawg_en.sh"
    local n
    n=$(grep -cE 'json_entries\+=.*status_code' "$f" || true)
    [ "$n" -ge 2 ] || { echo "expected >=2 json emitters with status_code, got $n"; false; }
}

@test "1bkk.6 source: status_code enum values present in both variants" {
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        local p="${BATS_TEST_DIRNAME}/../$f"
        for code in active recent inactive no_handshake key_error; do
            grep -q "status_code=\"${code}\"" "$p" || grep -q "st_code=\"${code}\"" "$p" \
                || { echo "$f missing status_code value: $code"; false; }
        done
    done
}
