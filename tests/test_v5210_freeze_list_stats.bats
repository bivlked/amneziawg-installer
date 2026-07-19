#!/usr/bin/env bats
# Phase 6 (v5.21.0): freeze the public list/stats --json shape.
#
# These two outputs are the oldest part of the JSON contract (bare arrays,
# consumed by awgram and other bots since D#130) and are promised to stay
# byte-compatible: same key set, same types, no envelope. Until now nothing
# guarded that promise - a refactor could silently rename a key. These tests
# pin the exact key sets and value types in both language variants.

bats_require_minimum_version 1.5.0

require_jq() { command -v jq &>/dev/null || skip "jq not available"; }

setup() {
    TEST_DIR=$(mktemp -d)
    mkdir -p "$TEST_DIR/bin" "$TEST_DIR/awg/keys"
    # awg stub: `show awg0 dump` returns one interface line + one peer line
    # for PK_foo (tab-separated: pubkey psk endpoint allowed-ips handshake
    # rx tx keepalive) so stats has real material to build an entry from.
    cat > "$TEST_DIR/bin/awg" << 'STUB'
#!/bin/bash
if [[ "$1" == "show" && "$3" == "dump" ]]; then
    printf 'PRIVKEY\tPUBKEY\t39743\toff\n'
    printf 'PK_foo\t(none)\t203.0.113.5:51820\t10.9.9.2/32\t1750000000\t123456\t654321\toff\n'
fi
exit 0
STUB
    chmod +x "$TEST_DIR/bin/awg"
    export PATH="$TEST_DIR/bin:$PATH"

    cp "$BATS_TEST_DIRNAME/../awg_common.sh" "$TEST_DIR/awg/awg_common.sh"
    cat > "$TEST_DIR/awg/awgsetup_cfg.init" << 'CONF'
export AWG_PORT=39743
export AWG_TUNNEL_SUBNET='10.9.9.1/24'
export DISABLE_IPV6=1
export ALLOWED_IPS_MODE=1
export ALLOWED_IPS='0.0.0.0/0'
export AWG_APPLY_MODE='syncconf'
CONF
    cat > "$TEST_DIR/awg/awg0.conf" << 'CONF'
[Interface]
PrivateKey = TESTKEY
Address = 10.9.9.1/24
ListenPort = 39743

[Peer]
#_Name = foo
PublicKey = PK_foo
AllowedIPs = 10.9.9.2/32
CONF

    SCRIPT="$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    SCRIPT_EN="$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
    MOCK_ARGS=(--conf-dir="$TEST_DIR/awg" --server-conf="$TEST_DIR/awg/awg0.conf")
}

teardown() {
    rm -rf "$TEST_DIR"
}

# --- list ---

@test "freeze: list --json is a bare array, exact key set, string values" {
    require_jq
    run --separate-stderr bash "$SCRIPT" list --json "${MOCK_ARGS[@]}"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e 'type == "array"' >/dev/null
    keys=$(printf '%s' "$output" | jq -cS '.[0] | keys')
    [ "$keys" = '["client_ipv6","ip","name","status","status_code"]' ]
    printf '%s' "$output" | jq -e '
        .[0] | (.name | type == "string") and (.ip | type == "string")
        and (.client_ipv6 | type == "string")
        and (.status | type == "string") and (.status_code | type == "string")' >/dev/null
}

@test "freeze: list --json on empty server is a bare empty array" {
    require_jq
    cat > "$TEST_DIR/awg/awg0.conf" << 'CONF'
[Interface]
PrivateKey = TESTKEY
Address = 10.9.9.1/24
ListenPort = 39743
CONF
    run --separate-stderr bash "$SCRIPT" list --json "${MOCK_ARGS[@]}"
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}

@test "freeze: status_code enum values stay within the documented set" {
    require_jq
    run --separate-stderr bash "$SCRIPT" list --json "${MOCK_ARGS[@]}"
    printf '%s' "$output" | jq -e '
        [.[].status_code] | all(. as $c |
            ["active","recent","inactive","no_handshake","key_error","no_data"]
            | index($c) != null)' >/dev/null
}

# --- stats ---

@test "freeze: stats --json is a bare array, exact key set, numeric counters" {
    require_jq
    run --separate-stderr bash "$SCRIPT" stats --json "${MOCK_ARGS[@]}"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e 'type == "array"' >/dev/null
    keys=$(printf '%s' "$output" | jq -cS '.[0] | keys')
    [ "$keys" = '["ip","last_handshake","name","rx","status","status_code","tx"]' ]
    printf '%s' "$output" | jq -e '
        .[0] | (.rx | type == "number") and (.tx | type == "number")
        and (.last_handshake | type == "number")' >/dev/null
}

# --- EN parity ---

@test "freeze: EN list and stats key sets match RU exactly" {
    require_jq
    run --separate-stderr bash "$SCRIPT" list --json "${MOCK_ARGS[@]}"
    ru_l=$(printf '%s' "$output" | jq -cS '.[0] | keys')
    run --separate-stderr bash "$SCRIPT_EN" list --json "${MOCK_ARGS[@]}"
    en_l=$(printf '%s' "$output" | jq -cS '.[0] | keys')
    [ "$ru_l" = "$en_l" ]
    run --separate-stderr bash "$SCRIPT" stats --json "${MOCK_ARGS[@]}"
    ru_s=$(printf '%s' "$output" | jq -cS '.[0] | keys')
    run --separate-stderr bash "$SCRIPT_EN" stats --json "${MOCK_ARGS[@]}"
    en_s=$(printf '%s' "$output" | jq -cS '.[0] | keys')
    [ "$ru_s" = "$en_s" ]
}
