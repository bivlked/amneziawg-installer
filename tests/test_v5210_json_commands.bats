#!/usr/bin/env bats
# Phase 3 (v5.21.0, MyAI-n30w): --json envelopes for add/remove/regen.
#
# Behavioral: runs the real manage scripts end-to-end in a mock environment
# (stubbed awg, AWG_SKIP_APPLY=1 to keep module/apply out of the way) and
# validates the approved envelope schemas with jq. Spec: plan section 3.3.

bats_require_minimum_version 1.5.0

require_jq() { command -v jq &>/dev/null || skip "jq not available"; }

setup() {
    TEST_DIR=$(mktemp -d)
    mkdir -p "$TEST_DIR/bin" "$TEST_DIR/awg/keys"

    # awg stub: genkey/genpsk/pubkey return dummy keys, everything else no-ops.
    cat > "$TEST_DIR/bin/awg" << 'STUB'
#!/bin/bash
case "$1" in
    genkey|genpsk) echo "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ;;
    pubkey) cat >/dev/null; echo "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=" ;;
    *) exit 0 ;;
esac
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
export AWG_Jc=6
export AWG_Jmin=55
export AWG_Jmax=380
export AWG_S1=72
export AWG_S2=56
export AWG_S3=32
export AWG_S4=16
export AWG_H1='100000-800000'
export AWG_H2='1000000-8000000'
export AWG_H3='10000000-80000000'
export AWG_H4='100000000-800000000'
export AWG_APPLY_MODE='syncconf'
CONF
    cat > "$TEST_DIR/awg/awg0.conf" << 'CONF'
[Interface]
PrivateKey = TESTKEY
Address = 10.9.9.1/24
MTU = 1280
ListenPort = 39743
Jc = 6
Jmin = 55
Jmax = 380
S1 = 72
S2 = 56
S3 = 32
S4 = 16
H1 = 100000-800000
H2 = 1000000-8000000
H3 = 10000000-80000000
H4 = 100000000-800000000

[Peer]
#_Name = foo
PublicKey = PK_foo
AllowedIPs = 10.9.9.2/32
CONF

    SCRIPT="$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    SCRIPT_EN="$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
    MOCK_ARGS=(--conf-dir="$TEST_DIR/awg" --server-conf="$TEST_DIR/awg/awg0.conf")
    export AWG_SKIP_APPLY=1
}

teardown() {
    unset AWG_SKIP_APPLY
    rm -rf "$TEST_DIR"
}

_one_json_line() {
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
    printf '%s' "$output" | jq -e . >/dev/null
}

# --- add ---

@test "add: created entry with conf path, envelope counters, single JSON doc" {
    require_jq
    run --separate-stderr bash "$SCRIPT" add newguy --json --yes "${MOCK_ARGS[@]}"
    [ "$status" -eq 0 ]
    _one_json_line
    printf '%s' "$output" | jq -e '
        .command == "add" and .ok == true and .added == 1 and .failed == 0
        and (.results | length == 1)
        and .results[0].status == "created"
        and (.results[0].conf | endswith("newguy.conf"))
        and (.results[0] | has("qr") and has("vpnuri") and has("expires_at"))' >/dev/null
    # The conf file really exists (the path is not a promise but a fact).
    conf_path=$(printf '%s' "$output" | jq -re '.results[0].conf')
    [ -f "$conf_path" ]
}

@test "add: mixed batch (invalid + ok) gives ok=false, per-entry statuses, rc 1" {
    require_jq
    run --separate-stderr bash "$SCRIPT" add 'bad name!' newguy --json --yes "${MOCK_ARGS[@]}"
    [ "$status" -eq 1 ]
    _one_json_line
    printf '%s' "$output" | jq -e '
        .command == "add" and .ok == false and .added == 1 and .failed == 1
        and .results[0].status == "invalid_name"
        and .results[1].status == "created"' >/dev/null
}

@test "add: existing name gives exists status and rc 1" {
    require_jq
    run --separate-stderr bash "$SCRIPT" add foo --json --yes "${MOCK_ARGS[@]}"
    [ "$status" -eq 1 ]
    _one_json_line
    printf '%s' "$output" | jq -e '
        .ok == false and .added == 0 and .failed == 1
        and .results[0].status == "exists"' >/dev/null
}

@test "add: applied=false under AWG_SKIP_APPLY (deferred apply is not applied)" {
    require_jq
    run --separate-stderr bash "$SCRIPT" add newguy --json --yes "${MOCK_ARGS[@]}"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.applied == false' >/dev/null
}

# --- remove ---

@test "remove: removed entry, counters, applied field present" {
    require_jq
    run --separate-stderr bash "$SCRIPT" remove foo --json --yes "${MOCK_ARGS[@]}"
    [ "$status" -eq 0 ]
    _one_json_line
    printf '%s' "$output" | jq -e '
        .command == "remove" and .ok == true and .removed == 1 and .failed == 0
        and (.results | length == 1)
        and .results[0].status == "removed"
        and has("applied")' >/dev/null
    # The peer is really gone from the server config.
    ! grep -q '#_Name = foo' "$TEST_DIR/awg/awg0.conf"
}

@test "remove: partial (one ok, one ghost) gives ok=false, rc 1, both entries" {
    require_jq
    run --separate-stderr bash "$SCRIPT" remove foo ghost --json --yes "${MOCK_ARGS[@]}"
    [ "$status" -eq 1 ]
    _one_json_line
    printf '%s' "$output" | jq -e '
        .ok == false and .removed == 1 and .failed == 1
        and ([.results[].status] | sort == ["not_found", "removed"])' >/dev/null
}

@test "remove: partial not-found now exits 1 also without --json (spec 3.4)" {
    run --separate-stderr bash "$SCRIPT" remove foo ghost --yes "${MOCK_ARGS[@]}"
    [ "$status" -eq 1 ]
}

# --- regen ---

@test "regen: missing client key gives error entry, ok=false" {
    require_jq
    # Mock foo has no private key anywhere - regenerate_client must fail.
    run --separate-stderr bash "$SCRIPT" regen foo --json "${MOCK_ARGS[@]}"
    [ "$status" -eq 1 ]
    _one_json_line
    printf '%s' "$output" | jq -e '
        .command == "regen" and .ok == false
        and .regenerated == 0 and .failed == 1
        and .results[0].status == "error"
        and has("reset_routes")' >/dev/null
}

@test "regen: ghost client gives not_found entry" {
    require_jq
    run --separate-stderr bash "$SCRIPT" regen ghost --json "${MOCK_ARGS[@]}"
    [ "$status" -eq 1 ]
    printf '%s' "$output" | jq -e '.results[0].status == "not_found"' >/dev/null
}

@test "regen: no clients at all is a clean no-op (rc 0, regenerated 0, empty results)" {
    require_jq
    # Server config without peers (spec 3.4: empty set is ok:true).
    cat > "$TEST_DIR/awg/awg0.conf" << 'CONF'
[Interface]
PrivateKey = TESTKEY
Address = 10.9.9.1/24
ListenPort = 39743
CONF
    run --separate-stderr bash "$SCRIPT" regen --json "${MOCK_ARGS[@]}"
    [ "$status" -eq 0 ]
    _one_json_line
    printf '%s' "$output" | jq -e '
        .ok == true and .regenerated == 0 and .failed == 0
        and .results == []' >/dev/null
}

@test "regen: reset_routes flag is reflected in the envelope" {
    require_jq
    run --separate-stderr bash "$SCRIPT" regen ghost --json --reset-routes "${MOCK_ARGS[@]}"
    printf '%s' "$output" | jq -e '.reset_routes == true' >/dev/null
}

@test "regen: envelope has no applied field (regen does not touch server state)" {
    require_jq
    run --separate-stderr bash "$SCRIPT" regen ghost --json "${MOCK_ARGS[@]}"
    printf '%s' "$output" | jq -e 'has("applied") | not' >/dev/null
}

# --- RU/EN schema parity (keys and enums, not text) ---

@test "EN: add created entry has identical key set to RU" {
    require_jq
    run --separate-stderr bash "$SCRIPT" add p1 --json --yes "${MOCK_ARGS[@]}"
    ru_keys=$(printf '%s' "$output" | jq -cS '[paths | map(tostring)] | sort')
    run --separate-stderr bash "$SCRIPT_EN" add p2 --json --yes "${MOCK_ARGS[@]}"
    en_keys=$(printf '%s' "$output" | jq -cS '[paths | map(tostring)] | sort')
    # Same tree shape: replace the differing leaf indices (names/paths differ,
    # structure must not).
    [ "$ru_keys" = "$en_keys" ]
}

@test "EN: remove and regen envelopes carry the same keys as RU" {
    require_jq
    run --separate-stderr bash "$SCRIPT" remove ghost --json --yes "${MOCK_ARGS[@]}"
    ru_rm=$(printf '%s' "$output" | jq -cS 'keys')
    run --separate-stderr bash "$SCRIPT_EN" remove ghost --json --yes "${MOCK_ARGS[@]}"
    en_rm=$(printf '%s' "$output" | jq -cS 'keys')
    [ "$ru_rm" = "$en_rm" ]
    run --separate-stderr bash "$SCRIPT" regen ghost --json "${MOCK_ARGS[@]}"
    ru_rg=$(printf '%s' "$output" | jq -cS 'keys')
    run --separate-stderr bash "$SCRIPT_EN" regen ghost --json "${MOCK_ARGS[@]}"
    en_rg=$(printf '%s' "$output" | jq -cS 'keys')
    [ "$ru_rg" = "$en_rg" ]
}
