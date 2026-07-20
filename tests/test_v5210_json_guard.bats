#!/usr/bin/env bats
# Phase 2 (v5.21.0): universal JSON contract on FAILURE paths (plan 10.1).
#
# Runs the real manage script end-to-end in a mock environment and asserts
# the core contract rule: with --json, stdout carries EXACTLY ONE valid JSON
# document on every exit path - including the paths that used to leave stdout
# empty (bare exit 1 after a confirm refusal, early option errors).
#
# Executing tests, not grep-the-source (v5.19.2 lesson).

bats_require_minimum_version 1.5.0

require_jq() { command -v jq &>/dev/null || skip "jq not available"; }

setup() {
    TEST_DIR=$(mktemp -d)
    mkdir -p "$TEST_DIR/bin" "$TEST_DIR/awg/keys"

    # awg stub so check_dependencies passes without a real kernel stack.
    printf '#!/bin/bash\nexit 0\n' > "$TEST_DIR/bin/awg"
    chmod +x "$TEST_DIR/bin/awg"
    export PATH="$TEST_DIR/bin:$PATH"

    # Mock conf-dir: library, init config, server config with one peer.
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

# stdout must be exactly one line of valid JSON with ok=false and the rc field.
_assert_error_json() {
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
    printf '%s' "$output" | jq -e '(.ok == false) and (.rc != null) and (.command != null)' >/dev/null
}

# --- early option errors (before any command runs) ---

@test "unknown option with --json: single JSON error doc on stdout" {
    require_jq
    run --separate-stderr bash "$SCRIPT" --json --frobnicate
    [ "$status" -eq 1 ]
    _assert_error_json
}

@test "apply-mode typo with --json AFTER it: guard still speaks (rev.2 hole)" {
    require_jq
    run --separate-stderr bash "$SCRIPT" add foo --apply-mode=restrat --json
    [ "$status" -eq 1 ]
    _assert_error_json
    printf '%s' "$output" | jq -re '.error' | grep -q 'apply-mode'
}

@test "apply-mode typo without --json: stdout stays empty (no JSON leak)" {
    run --separate-stderr bash "$SCRIPT" add foo --apply-mode=restrat
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "valid apply-mode still accepted after the validation move" {
    require_jq
    # Invalid client name: fails AFTER option parsing, so a parse-level
    # regression in --apply-mode would surface as an apply-mode error instead.
    run --separate-stderr bash "$SCRIPT" add 'bad name!' --apply-mode=restart --json "${MOCK_ARGS[@]}"
    [ "$status" -eq 1 ]
    _assert_error_json
    local err_text
    err_text=$(printf '%s' "$output" | jq -re '.error')
    [[ "$err_text" != *apply-mode* ]]
}

# --- strict-confirm refusal: the exact scenario the feature exists for ---

@test "strict-confirm remove refusal: JSON error doc, not empty stdout" {
    require_jq
    AWG_STRICT_CONFIRM=1 run --separate-stderr bash "$SCRIPT" remove foo --json "${MOCK_ARGS[@]}"
    [ "$status" -eq 1 ]
    _assert_error_json
    printf '%s' "$output" | jq -re '.error' | grep -q 'AWG_STRICT_CONFIRM'
}

@test "strict-confirm restart refusal: JSON error doc" {
    require_jq
    AWG_STRICT_CONFIRM=1 run --separate-stderr bash "$SCRIPT" restart --json "${MOCK_ARGS[@]}"
    [ "$status" -eq 1 ]
    _assert_error_json
    printf '%s' "$output" | jq -re '.command' | grep -qx 'restart'
}

@test "strict-confirm remove with --yes proceeds past confirm (no strict error)" {
    require_jq
    # Passes confirm, then fails later in the mock env (no real interface) -
    # the point: no STRICT refusal, and stdout is still clean JSON or empty.
    AWG_STRICT_CONFIRM=1 run --separate-stderr bash "$SCRIPT" remove foo --json --yes "${MOCK_ARGS[@]}"
    if [ -n "$output" ]; then
        printf '%s' "$output" | jq -e . >/dev/null
        [[ "$output" != *AWG_STRICT_CONFIRM* ]]
    fi
}

# --- die paths carry meaningful error text ---

@test "remove nonexistent client --json: envelope with not_found entry, rc 1" {
    require_jq
    # Phase 3 upgraded this path from the emergency object to a full envelope:
    # partial/total not-found is rc 1 (spec 3.4, symmetry with add/regen).
    run --separate-stderr bash "$SCRIPT" remove ghost --json --yes "${MOCK_ARGS[@]}"
    [ "$status" -eq 1 ]
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
    printf '%s' "$output" | jq -e '.command == "remove" and .ok == false and .removed == 0 and .failed == 1 and .results[0].status == "not_found"' >/dev/null
}

@test "missing conf-dir --json: die in check_dependencies produces JSON" {
    require_jq
    run --separate-stderr bash "$SCRIPT" list --json --conf-dir="$TEST_DIR/nonexistent"
    [ "$status" -eq 1 ]
    _assert_error_json
}

# --- frozen list path still works through the moved json_escape ---

@test "list --json still emits a valid JSON array (freeze regression)" {
    require_jq
    run --separate-stderr bash "$SCRIPT" list --json "${MOCK_ARGS[@]}"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e 'type == "array" and length == 1 and .[0].name == "foo"' >/dev/null
}

# --- EN parity on the same paths ---

@test "EN: strict-confirm remove refusal produces JSON error doc" {
    require_jq
    AWG_STRICT_CONFIRM=1 run --separate-stderr bash "$SCRIPT_EN" remove foo --json "${MOCK_ARGS[@]}"
    [ "$status" -eq 1 ]
    _assert_error_json
    printf '%s' "$output" | jq -re '.error' | grep -q 'AWG_STRICT_CONFIRM'
}

@test "EN: unknown option with --json produces JSON error doc" {
    require_jq
    run --separate-stderr bash "$SCRIPT_EN" --json --frobnicate
    [ "$status" -eq 1 ]
    _assert_error_json
}

# --- post-review fixes ---

@test "unknown option BEFORE --json: guard still speaks (argv tail scan)" {
    require_jq
    run --separate-stderr bash "$SCRIPT" --frobnicate --json
    [ "$status" -eq 1 ]
    _assert_error_json
}

@test "show --json failure: no JSON pollution on the human stream" {
    # show is documented as JSON-unsupported; on failure the guard must stay
    # silent instead of appending an error object after human output.
    printf '#!/bin/bash
exit 1
' > "$TEST_DIR/bin/awg"
    chmod +x "$TEST_DIR/bin/awg"
    run --separate-stderr bash "$SCRIPT" show --json "${MOCK_ARGS[@]}"
    [ "$status" -eq 1 ]
    [[ "$output" != *'"ok"'* ]]
}

@test "diagnose --json failure: no trailing JSON error object" {
    run --separate-stderr bash "$SCRIPT" diagnose --json "${MOCK_ARGS[@]}"
    [[ "$output" != *'"ok":false'* ]]
}

@test "list --json emission goes through json_out (SIGINT race closed)" {
    # Structural check backing the freeze tests: the frozen array must be
    # printed by json_out (sets _JSON_EMITTED) and not by a bare echo.
    run ! grep -E '\( IFS=","; echo' "$SCRIPT"
    grep -q 'json_out "\$_jarr"' "$SCRIPT"
    grep -q 'json_out "\$_jarr"' "$SCRIPT_EN"
}
