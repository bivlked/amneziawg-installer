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

# --- phase 4-5: singles + check ---

_make_client_conf() {
    cat > "$TEST_DIR/awg/foo.conf" << 'CONF'
[Interface]
PrivateKey = PRIV_foo
Address = 10.9.9.2/32
DNS = 1.1.1.1
MTU = 1280
[Peer]
PublicKey = SERVERPUB
AllowedIPs = 0.0.0.0/0
CONF
}

_stub_systemctl() {
    printf '#!/bin/bash\nexit 0\n' > "$TEST_DIR/bin/systemctl"
    chmod +x "$TEST_DIR/bin/systemctl"
}

_stub_lsmod() {
    printf '#!/bin/bash\necho "amneziawg 40960 0"\n' > "$TEST_DIR/bin/lsmod"
    chmod +x "$TEST_DIR/bin/lsmod"
}

@test "modify: success envelope with name/param/value, no applied field" {
    require_jq
    _make_client_conf
    run --separate-stderr bash "$SCRIPT" modify foo DNS 8.8.8.8 --json "${MOCK_ARGS[@]}"
    [ "$status" -eq 0 ]
    _one_json_line
    printf '%s' "$output" | jq -e '
        .command == "modify" and .ok == true and .name == "foo"
        and .param == "DNS" and .value == "8.8.8.8"
        and (has("applied") | not)' >/dev/null
}

@test "modify: failure gives the emergency error object" {
    require_jq
    run --separate-stderr bash "$SCRIPT" modify ghost DNS 8.8.8.8 --json "${MOCK_ARGS[@]}"
    [ "$status" -eq 1 ]
    printf '%s' "$output" | jq -e '.ok == false and .rc == 1' >/dev/null
}

@test "backup: success envelope with existing path and numeric size" {
    require_jq
    run --separate-stderr bash "$SCRIPT" backup --json "${MOCK_ARGS[@]}"
    [ "$status" -eq 0 ]
    _one_json_line
    printf '%s' "$output" | jq -e '
        .command == "backup" and .ok == true
        and (.size_bytes | type == "number") and .size_bytes > 0' >/dev/null
    bpath=$(printf '%s' "$output" | jq -re '.path')
    [ -f "$bpath" ]
}

@test "restore: success envelope with source, restored counters" {
    require_jq
    _stub_systemctl
    run --separate-stderr bash "$SCRIPT" backup --json "${MOCK_ARGS[@]}"
    bpath=$(printf '%s' "$output" | jq -re '.path')
    run --separate-stderr bash "$SCRIPT" restore "$bpath" --json --yes "${MOCK_ARGS[@]}"
    [ "$status" -eq 0 ]
    _one_json_line
    printf '%s' "$output" | jq -e --arg src "$bpath" '
        .command == "restore" and .ok == true and .source == $src
        and .applied == true and .rolled_back == false
        and .restored.server_conf == true
        and (.restored.clients | type == "number")
        and (.restored.keys | type == "boolean")' >/dev/null
}

@test "restore: missing file gives error object via guard (die path)" {
    require_jq
    run --separate-stderr bash "$SCRIPT" restore /nonexistent.tar.gz --json --yes "${MOCK_ARGS[@]}"
    [ "$status" -eq 1 ]
    printf '%s' "$output" | jq -e '.command == "restore" and .ok == false' >/dev/null
}

@test "restart: success envelope with unit and active" {
    require_jq
    _stub_systemctl
    _stub_lsmod
    run --separate-stderr bash "$SCRIPT" restart --json --yes "${MOCK_ARGS[@]}"
    [ "$status" -eq 0 ]
    _one_json_line
    printf '%s' "$output" | jq -e '
        .command == "restart" and .ok == true
        and .unit == "awg-quick@awg0" and .active == true' >/dev/null
}

@test "repair-module: envelope with module_loaded/service_active/rc" {
    require_jq
    _stub_systemctl
    _stub_lsmod
    run --separate-stderr bash "$SCRIPT" repair-module --json "${MOCK_ARGS[@]}"
    [ "$status" -eq 0 ]
    _one_json_line
    printf '%s' "$output" | jq -e '
        .command == "repair-module" and .ok == true
        and .module_loaded == true and .service_active == true and .rc == 0' >/dev/null
}

@test "alias repair canonicalizes to repair-module in the envelope" {
    require_jq
    _stub_systemctl
    _stub_lsmod
    run --separate-stderr bash "$SCRIPT" repair --json "${MOCK_ARGS[@]}"
    printf '%s' "$output" | jq -e '.command == "repair-module"' >/dev/null
}

@test "check: full section structure, alias status canonicalizes to check" {
    require_jq
    _stub_systemctl
    _stub_lsmod
    # Interface awg0 does not exist in the mock -> ok=false, rc 1, but the
    # envelope must still carry every section with honest values.
    run --separate-stderr bash "$SCRIPT" check --json "${MOCK_ARGS[@]}"
    [ "$status" -eq 1 ]
    _one_json_line
    printf '%s' "$output" | jq -e '
        .command == "check" and .ok == false
        and .service.unit == "awg-quick@awg0" and .service.active == true
        and .interface.present == false
        and .port.proto == "udp"
        and .module.loaded == true
        and (.clients.total | type == "number") and .clients.total == 1
        and (.firewall | has("ufw_active") and has("port_allowed"))' >/dev/null
    run --separate-stderr bash "$SCRIPT" status --json "${MOCK_ARGS[@]}"
    printf '%s' "$output" | jq -e '.command == "check"' >/dev/null
}

@test "check: human output (no --json) still prints the sections to stdout" {
    _stub_systemctl
    _stub_lsmod
    run --separate-stderr bash "$SCRIPT" check "${MOCK_ARGS[@]}"
    [[ "$output" == *"awg0"* ]]
}

# --- EN parity for phase 4-5 envelopes ---

@test "EN: check/status envelope keys match RU" {
    require_jq
    _stub_systemctl
    _stub_lsmod
    run --separate-stderr bash "$SCRIPT" check --json "${MOCK_ARGS[@]}"
    ru=$(printf '%s' "$output" | jq -cS '[paths | map(tostring)] | sort')
    run --separate-stderr bash "$SCRIPT_EN" check --json "${MOCK_ARGS[@]}"
    en=$(printf '%s' "$output" | jq -cS '[paths | map(tostring)] | sort')
    [ "$ru" = "$en" ]
}

@test "EN: repair-module and restart envelopes match RU keys" {
    require_jq
    _stub_systemctl
    _stub_lsmod
    run --separate-stderr bash "$SCRIPT" repair --json "${MOCK_ARGS[@]}"
    ru=$(printf '%s' "$output" | jq -cS 'keys')
    run --separate-stderr bash "$SCRIPT_EN" repair --json "${MOCK_ARGS[@]}"
    en=$(printf '%s' "$output" | jq -cS 'keys')
    [ "$ru" = "$en" ]
    run --separate-stderr bash "$SCRIPT" restart --json --yes "${MOCK_ARGS[@]}"
    ru=$(printf '%s' "$output" | jq -cS 'keys')
    run --separate-stderr bash "$SCRIPT_EN" restart --json --yes "${MOCK_ARGS[@]}"
    en=$(printf '%s' "$output" | jq -cS 'keys')
    [ "$ru" = "$en" ]
}
