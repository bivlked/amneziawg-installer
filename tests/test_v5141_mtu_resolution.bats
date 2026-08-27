#!/usr/bin/env bats
# Tests for MTU resolution priority in render_client_config (v5.14.1).
#
# Bug background: v5.14.0 and earlier hardcoded MTU = 1280 in render_server_config
# and render_client_config. Manual edits to MTU in server awg0.conf were lost
# on `manage regen`. Reported in Discussion #38 by @E-lmedano.
#
# Fix: resolution order
#   1) MTU = N from [Interface] section of server awg0.conf (if present)
#   2) AWG_MTU env / awgsetup_cfg.init (if set)
#   3) 1280 fallback

load test_helper

# Required for `run !` flag (used in negation tests). Suppresses bats BW02 warning.
bats_require_minimum_version 1.5.0

setup() {
    TEST_DIR=$(mktemp -d)
    export AWG_DIR="$TEST_DIR"
    export SERVER_CONF_FILE="$TEST_DIR/awg0.conf"
    log()       { :; }
    log_warn()  { :; }
    log_error() { :; }
    log_debug() { :; }
    export -f log log_warn log_error log_debug
    source "$BATS_TEST_DIRNAME/../awg_common.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "_extract_mtu_from_server_conf: returns MTU from [Interface] section" {
    cat > "$SERVER_CONF_FILE" <<'CONF'
[Interface]
PrivateKey = TESTKEY
Address = 10.9.9.1/24
MTU = 1200
ListenPort = 39743
Jc = 5

[Peer]
PublicKey = PEERKEY
AllowedIPs = 10.9.9.2/32
CONF
    run _extract_mtu_from_server_conf
    [ "$status" -eq 0 ]
    [ "$output" = "1200" ]
}

@test "_extract_mtu_from_server_conf: tolerates whitespace around =" {
    cat > "$SERVER_CONF_FILE" <<'CONF'
[Interface]
PrivateKey = K
Address = 10.0.0.1/24
MTU    =   1380
ListenPort = 51820
CONF
    run _extract_mtu_from_server_conf
    [ "$status" -eq 0 ]
    [ "$output" = "1380" ]
}

@test "_extract_mtu_from_server_conf: returns nothing when MTU absent" {
    cat > "$SERVER_CONF_FILE" <<'CONF'
[Interface]
PrivateKey = K
Address = 10.0.0.1/24
ListenPort = 51820

[Peer]
PublicKey = PK
AllowedIPs = 10.0.0.2/32
CONF
    run _extract_mtu_from_server_conf
    [ -z "$output" ]
}

@test "_extract_mtu_from_server_conf: ignores MTU in [Peer] section" {
    cat > "$SERVER_CONF_FILE" <<'CONF'
[Interface]
PrivateKey = K
Address = 10.0.0.1/24
ListenPort = 51820

[Peer]
PublicKey = PK
MTU = 9999
AllowedIPs = 10.0.0.2/32
CONF
    run _extract_mtu_from_server_conf
    [ -z "$output" ]
}

@test "_extract_mtu_from_server_conf: last-wins on duplicates (matches awg-quick)" {
    cat > "$SERVER_CONF_FILE" <<'CONF'
[Interface]
PrivateKey = K
MTU = 1280
Address = 10.0.0.1/24
MTU = 1500
ListenPort = 51820
CONF
    run _extract_mtu_from_server_conf
    [ "$status" -eq 0 ]
    [ "$output" = "1500" ]
}

@test "_validate_mtu: accepts 1280" {
    run _validate_mtu 1280
    [ "$status" -eq 0 ]
}

@test "_validate_mtu: accepts boundary 576 and 9100" {
    run _validate_mtu 576; [ "$status" -eq 0 ]
    run _validate_mtu 9100; [ "$status" -eq 0 ]
}

@test "_validate_mtu: rejects 0 / negative-as-string / 9101 / non-numeric / empty" {
    run _validate_mtu 0;        [ "$status" -ne 0 ]
    run _validate_mtu "-1";     [ "$status" -ne 0 ]
    run _validate_mtu 9101;     [ "$status" -ne 0 ]
    run _validate_mtu 575;      [ "$status" -ne 0 ]
    run _validate_mtu abc;      [ "$status" -ne 0 ]
    run _validate_mtu "";       [ "$status" -ne 0 ]
}

@test "_extract_mtu_from_server_conf: out-of-range MTU returns 1 (fallback path)" {
    cat > "$SERVER_CONF_FILE" <<'CONF'
[Interface]
PrivateKey = K
MTU = 0
Address = 10.0.0.1/24
ListenPort = 51820
CONF
    run _extract_mtu_from_server_conf
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "_extract_mtu_from_server_conf: returns 1 when server conf missing" {
    rm -f "$SERVER_CONF_FILE"
    run _extract_mtu_from_server_conf
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "_extract_mtu_from_server_conf: skips non-numeric MTU value" {
    cat > "$SERVER_CONF_FILE" <<'CONF'
[Interface]
PrivateKey = K
MTU = abc
Address = 10.0.0.1/24
ListenPort = 51820
CONF
    run _extract_mtu_from_server_conf
    [ -z "$output" ]
}

@test "structural RU: render_client_config uses dynamic MTU (no hardcoded 1280)" {
    local FILE="${BATS_TEST_DIRNAME}/../awg_common.sh"
    local block
    block=$(awk '/^render_client_config\(\) \{/,/^}$/' "$FILE")
    # Must NOT contain literal "MTU = 1280" hardcode.
    # In Bats a bare `! grep` does NOT fail the test (SC2314); use `run !`
    # (bats >= 1.5.0) so the negated exit status actually fails the test.
    run ! grep -qE '^MTU = 1280$' <<<"$block"
    # Must contain template substitution for MTU
    grep -qE 'MTU = \$\{mtu\}' <<<"$block"
}

@test "structural EN: render_client_config uses dynamic MTU" {
    local FILE="${BATS_TEST_DIRNAME}/../awg_common_en.sh"
    local block
    block=$(awk '/^render_client_config\(\) \{/,/^}$/' "$FILE")
    run ! grep -qE '^MTU = 1280$' <<<"$block"
    grep -qE 'MTU = \$\{mtu\}' <<<"$block"
}

@test "structural RU: render_server_config uses AWG_MTU with fallback" {
    local FILE="${BATS_TEST_DIRNAME}/../awg_common.sh"
    local block
    block=$(awk '/^render_server_config\(\) \{/,/^}$/' "$FILE")
    grep -qE 'MTU = \$\{AWG_MTU:-1280\}' <<<"$block"
}

@test "structural EN: render_server_config uses AWG_MTU with fallback" {
    local FILE="${BATS_TEST_DIRNAME}/../awg_common_en.sh"
    local block
    block=$(awk '/^render_server_config\(\) \{/,/^}$/' "$FILE")
    grep -qE 'MTU = \$\{AWG_MTU:-1280\}' <<<"$block"
}

@test "structural: AWG_MTU is in safe_load_config whitelist (all 4 files)" {
    for f in install_amneziawg.sh install_amneziawg_en.sh awg_common.sh awg_common_en.sh; do
        grep -qE 'AWG_ENDPOINT\|AWG_MTU' "${BATS_TEST_DIRNAME}/../$f"
    done
}

@test "structural: installer writes AWG_MTU to awgsetup_cfg.init (RU + EN)" {
    grep -qE 'export AWG_MTU=' "${BATS_TEST_DIRNAME}/../install_amneziawg.sh"
    grep -qE 'export AWG_MTU=' "${BATS_TEST_DIRNAME}/../install_amneziawg_en.sh"
}

@test "_extract_mtu RU and EN are byte-identical (parity)" {
    local RU_FILE="${BATS_TEST_DIRNAME}/../awg_common.sh"
    local EN_FILE="${BATS_TEST_DIRNAME}/../awg_common_en.sh"
    local ru_block en_block
    ru_block=$(awk '/^_extract_mtu_from_server_conf\(\) \{/,/^}$/' "$RU_FILE" | grep -v "^#")
    en_block=$(awk '/^_extract_mtu_from_server_conf\(\) \{/,/^}$/' "$EN_FILE" | grep -v "^#")
    [ -n "$ru_block" ]
    [ "$ru_block" = "$en_block" ]
}
