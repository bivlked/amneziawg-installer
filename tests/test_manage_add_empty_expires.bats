#!/usr/bin/env bats
# `manage add <name> --expires=` with an EMPTY value (a bot passing an unset
# variable) used to create a PERMANENT client and report ok:true: the add gate
# only looked at a non-empty EXPIRES_DURATION, so the empty flag was dropped
# silently - the same "temporary became permanent" class as --expires=bad.
# Like --allowed-ips=, the flag is now tracked as "seen" and an empty value
# dies before the first client is created.
#
# Sandbox: the real manage scripts end-to-end (same harness style as
# test_v5210_json_commands.bats) with stubbed awg and curl, AWG_ENDPOINT set
# (no public IP lookup), AWG_SKIP_APPLY=1 and EXPIRY_CRON pointed into the
# temp dir - add with --expires installs a cron file.

bats_require_minimum_version 1.5.0

setup() {
    command -v flock &>/dev/null || skip "flock not available (not Linux)"
    TEST_DIR=$(mktemp -d)
    mkdir -p "$TEST_DIR/bin" "$TEST_DIR/awg/keys" "$TEST_DIR/cron.d"

    cat > "$TEST_DIR/bin/awg" << 'STUB'
#!/bin/bash
case "$1" in
    genkey|genpsk) echo "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ;;
    pubkey) cat >/dev/null; echo "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=" ;;
    *) exit 0 ;;
esac
STUB
    # No network: any curl call fails and is recorded.
    cat > "$TEST_DIR/bin/curl" << STUB
#!/bin/bash
echo "\$*" >> "$TEST_DIR/curl.calls"
exit 7
STUB
    chmod +x "$TEST_DIR/bin/awg" "$TEST_DIR/bin/curl"
    export PATH="$TEST_DIR/bin:$PATH"

    cat > "$TEST_DIR/awg/awgsetup_cfg.init" << 'CONF'
export AWG_PORT=39743
export AWG_TUNNEL_SUBNET='10.9.9.1/24'
export DISABLE_IPV6=1
export ALLOWED_IPS_MODE=1
export ALLOWED_IPS='0.0.0.0/0'
export AWG_ENDPOINT='203.0.113.1'
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
CONF

    MOCK_ARGS=(--conf-dir="$TEST_DIR/awg" --server-conf="$TEST_DIR/awg/awg0.conf")
    export AWG_SKIP_APPLY=1
    export EXPIRY_CRON="$TEST_DIR/cron.d/awg-expiry"
}

teardown() {
    unset AWG_SKIP_APPLY EXPIRY_CRON
    rm -rf "${TEST_DIR:-}"
}

# _use_lang ru|en - pick the script and the matching library copy.
_use_lang() {
    if [[ "$1" == "en" ]]; then
        SCRIPT="$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
        cp "$BATS_TEST_DIRNAME/../awg_common_en.sh" "$TEST_DIR/awg/awg_common.sh"
    else
        SCRIPT="$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
        cp "$BATS_TEST_DIRNAME/../awg_common.sh" "$TEST_DIR/awg/awg_common.sh"
    fi
}

_assert_empty_expires_refused() {
    command -v jq &>/dev/null || skip "jq not available"
    _use_lang "$1"
    run --separate-stderr bash "$SCRIPT" add tmp --expires= --json --yes "${MOCK_ARGS[@]}"
    if [ "$status" -ne 1 ]; then
        echo "expected rc=1, got $status; stdout: $output"
        false
    fi
    [ "$(printf '%s' "$output" | jq -r '.ok')" = "false" ]
    # The refusal names the empty flag itself, not some later failure
    [[ "$(printf '%s' "$output" | jq -r '.error')" == *"--expires="* ]]
    if grep -qxF "#_Name = tmp" "$TEST_DIR/awg/awg0.conf"; then
        echo "client 'tmp' was created despite the empty --expires="
        false
    fi
    [ ! -e "$TEST_DIR/awg/tmp.conf" ]
    [ ! -e "$TEST_DIR/awg/expiry" ]
    [ ! -e "$EXPIRY_CRON" ]
    [ ! -e "$TEST_DIR/curl.calls" ]
}

_assert_expires_1d_still_works() {
    command -v jq &>/dev/null || skip "jq not available"
    _use_lang "$1"
    run --separate-stderr bash "$SCRIPT" add tmp --expires=1d --json --yes "${MOCK_ARGS[@]}"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.ok')" = "true" ]
    grep -qxF "#_Name = tmp" "$TEST_DIR/awg/awg0.conf"
    [ -s "$TEST_DIR/awg/expiry/tmp" ]
    [ "$(printf '%s' "$output" | jq -r '.results[0].expires_at')" = "$(cat "$TEST_DIR/awg/expiry/tmp")" ]
    # The cron file went into the sandbox, not /etc/cron.d
    [ -s "$EXPIRY_CRON" ]
    [ ! -e "$TEST_DIR/curl.calls" ]
}

_assert_no_flag_is_permanent() {
    command -v jq &>/dev/null || skip "jq not available"
    _use_lang "$1"
    run --separate-stderr bash "$SCRIPT" add perm --json --yes "${MOCK_ARGS[@]}"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.ok')" = "true" ]
    grep -qxF "#_Name = perm" "$TEST_DIR/awg/awg0.conf"
    [ "$(printf '%s' "$output" | jq -r '.results[0].expires_at')" = "null" ]
    [ ! -e "$TEST_DIR/awg/expiry" ]
    [ ! -e "$EXPIRY_CRON" ]
}

@test "add --expires= (empty) RU: refused with ok:false before any client" {
    _assert_empty_expires_refused ru
}

@test "add --expires= (empty) EN: refused with ok:false before any client" {
    _assert_empty_expires_refused en
}

@test "add --expires=1d RU: still creates a client with an expiry mark" {
    _assert_expires_1d_still_works ru
}

@test "add --expires=1d EN: still creates a client with an expiry mark" {
    _assert_expires_1d_still_works en
}

@test "add without --expires RU: permanent client as before" {
    _assert_no_flag_is_permanent ru
}

@test "add without --expires EN: permanent client as before" {
    _assert_no_flag_is_permanent en
}

@test "add --expires=1d --expires= RU/EN: the last (empty) value wins and is refused" {
    command -v jq &>/dev/null || skip "jq not available"
    local lang
    for lang in ru en; do
        _use_lang "$lang"
        run --separate-stderr bash "$SCRIPT" add tmp2 --expires=1d --expires= --json --yes "${MOCK_ARGS[@]}"
        if [ "$status" -ne 1 ]; then
            echo "$lang: expected rc=1, got $status"
            false
        fi
        if grep -qxF "#_Name = tmp2" "$TEST_DIR/awg/awg0.conf"; then
            echo "$lang: client 'tmp2' was created"
            false
        fi
    done
}
