#!/usr/bin/env bats
# v5.21.2: stats --json sanitizes rx/tx/last_handshake before arithmetic/JSON.
#
# These come from `awg show dump` (kernel utility output). stats fed them raw
# into total_rx=$((total_rx + rx)) - the same command-substitution vector that
# hit AWG_PORT - and into the JSON as "rx":$rx, unquoted, so a non-numeric or
# leading-zero field would produce "rx":abc / "rx":08 and break the document
# ("08" is invalid JSON and an octal error in arithmetic). The fix keeps only a
# canonical decimal integer and collapses everything else to 0.
#
# The dump carries two peers: one hostile (a command-substitution rx, a
# leading-zero tx, a junk handshake) and one clean, to prove both that garbage
# is zeroed with nothing executed and that a real counter passes through.

bats_require_minimum_version 1.5.0

require_jq() { command -v jq &>/dev/null || skip "jq not available"; }

setup() {
    TEST_DIR=$(mktemp -d)
    mkdir -p "$TEST_DIR/bin" "$TEST_DIR/awg/keys"
    MARKER="$TEST_DIR/EXECUTED"

    # foo: rx = a[$(touch MARKER)] (raw arithmetic would run it), tx = 08
    # (passes ^[0-9]+$ but is invalid JSON and octal), handshake = junk.
    # bar: a clean counter set that must survive untouched.
    local inj='a[$(touch '"$MARKER"')]'
    cat > "$TEST_DIR/bin/awg" << STUB
#!/bin/bash
if [[ "\$1" == "show" && "\$3" == "dump" ]]; then
    printf 'PRIVKEY\tPUBKEY\t39743\toff\n'
    printf 'PK_foo\t(none)\t203.0.113.5:51820\t10.9.9.2/32\tnot_a_time\t%s\t08\toff\n' '$inj'
    printf 'PK_bar\t(none)\t203.0.113.6:51820\t10.9.9.3/32\t1750000000\t123456\t654321\toff\n'
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

[Peer]
#_Name = bar
PublicKey = PK_bar
AllowedIPs = 10.9.9.3/32
CONF

    SCRIPT="$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    SCRIPT_EN="$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
    MOCK_ARGS=(--conf-dir="$TEST_DIR/awg" --server-conf="$TEST_DIR/awg/awg0.conf")
}

teardown() {
    rm -rf "$TEST_DIR"
}

_entry() { printf '%s' "$1" | jq -c ".[] | select(.name == \"$2\")"; }

_assert_sanitized() {
    local script="$1"
    run --separate-stderr bash "$script" stats --json "${MOCK_ARGS[@]}"
    [ "$status" -eq 0 ] || { echo "stats exited $status: $output"; return 1; }
    printf '%s' "$output" | jq -e 'type == "array"' >/dev/null \
        || { echo "output is not a JSON array: $output"; return 1; }

    # The full stats key set stays intact (freeze contract), on every entry.
    printf '%s' "$output" | jq -e '
        all(.[]; keys == ["ip","last_handshake","name","rx","status","status_code","tx"])' >/dev/null \
        || { echo "key set drifted: $output"; return 1; }

    # Hostile peer: every hostile counter is the number 0.
    local foo; foo=$(_entry "$output" foo)
    printf '%s' "$foo" | jq -e '
        (.rx == 0) and (.tx == 0) and (.last_handshake == 0)
        and (.rx|type=="number") and (.tx|type=="number") and (.last_handshake|type=="number")' >/dev/null \
        || { echo "hostile counters not zeroed: $foo"; return 1; }

    # Clean peer: real counters pass through unchanged.
    local bar; bar=$(_entry "$output" bar)
    printf '%s' "$bar" | jq -e '
        (.rx == 123456) and (.tx == 654321) and (.last_handshake == 1750000000)' >/dev/null \
        || { echo "clean counters altered: $bar"; return 1; }

    # The command substitution embedded in rx must never have run.
    [ ! -f "$MARKER" ] || { echo "arithmetic executed the embedded command"; return 1; }
}

@test "v5.21.2: stats --json sanitizes hostile counters, keeps clean ones, runs nothing (RU)" {
    require_jq
    _assert_sanitized "$SCRIPT"
}

@test "v5.21.2: stats --json sanitizes hostile counters, keeps clean ones, runs nothing (EN)" {
    require_jq
    _assert_sanitized "$SCRIPT_EN"
}
