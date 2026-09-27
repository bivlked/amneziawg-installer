#!/usr/bin/env bats
# apply_config and the header protection key on the LIVE interface (slice C2).
#
# syncconf does not take device parameters off a live interface, and a key that
# is in awg0.conf but not on awg0 (or the other way round, or a different value)
# means the running interface does not match the file every profile is built
# from. apply_config therefore compares the key in the file with the key on the
# device before syncconf, and when they disagree - or the device cannot be read
# at all - it recreates the interface with a restart instead of a syncconf.
# The key value is compared, never printed: the comparison runs with tracing off.
#
# Harness: the real awg_common.sh (and awg_common_en.sh: every case runs on both
# libraries) sourced in a subshell, stubbed awg (showconf answers from a file),
# awg-quick, systemctl and timeout.

load test_helper

K1='BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA='
K2='CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCE='
SRV='SRVPRIVATEKEYSRVPRIVATEKEYSRVPRIVATEKEYSRA='

setup() {
    TEST_DIR=$(mktemp -d)
    export AWG_DIR="$TEST_DIR"
    export CONFIG_FILE="$TEST_DIR/awgsetup_cfg.init"
    export SERVER_CONF_FILE="$TEST_DIR/awg0.conf"
    export KEYS_DIR="$TEST_DIR/keys"
    mkdir -p "$KEYS_DIR"
    MOCK_BIN="$TEST_DIR/mock_bin"
    mkdir -p "$MOCK_BIN"
    export PATH="$MOCK_BIN:$PATH"
    cat > "$MOCK_BIN/systemctl" << 'STUB'
#!/bin/bash
echo "systemctl $*" >> "${AWG_DIR}/.mock_calls"
exit 0
STUB
    cat > "$MOCK_BIN/awg-quick" << 'STUB'
#!/bin/bash
echo "awg-quick $*" >> "${AWG_DIR}/.mock_calls"
echo "[Interface]"
exit 0
STUB
    # showconf answers from .dev_key (the key on the live device), fails on
    # .showconf_fail; the server private key is in the answer, as in reality.
    cat > "$MOCK_BIN/awg" << STUB
#!/bin/bash
echo "awg \$*" >> "\${AWG_DIR}/.mock_calls"
if [[ "\$1" == showconf ]]; then
    [[ -e "\${AWG_DIR}/.showconf_fail" ]] && exit 1
    echo "[Interface]"
    echo "PrivateKey = $SRV"
    [[ -s "\${AWG_DIR}/.dev_key" ]] && echo "HeaderProtectionKey = \$(cat "\${AWG_DIR}/.dev_key")"
    echo "Jc = 6"
fi
exit 0
STUB
    cat > "$MOCK_BIN/timeout" << 'STUB'
#!/bin/bash
shift
"$@"
STUB
    chmod +x "$MOCK_BIN"/*
    export AWG_SKIP_APPLY=0 AWG_APPLY_MODE=syncconf
}

teardown() {
    rm -rf "$TEST_DIR"
}

# _state <file key or empty> <device key or empty>
_state() {
    rm -f "$AWG_DIR/.mock_calls" "$AWG_DIR/.showconf_fail" "$TEST_DIR/log"
    {
        printf '[Interface]\nPrivateKey = %s\n' "$SRV"
        [[ -n "$1" ]] && printf 'HeaderProtectionKey = %s\nContentPaddingAddition = 32-128\n' "$1"
        printf 'ListenPort = 39743\nJc = 6\n'
    } > "$SERVER_CONF_FILE"
    if [[ -n "$2" ]]; then printf '%s\n' "$2" > "$AWG_DIR/.dev_key"; else rm -f "$AWG_DIR/.dev_key"; fi
}

_restarted()  { grep -q 'systemctl restart awg-quick@awg0' "$AWG_DIR/.mock_calls"; }
_synced()     { grep -q 'awg syncconf' "$AWG_DIR/.mock_calls"; }
# _nope <function> : fail when it holds. A bare `! cmd` would never fail a bats
# test: set -e ignores a negated command.
_nope() { if "$@"; then echo "must not hold: $*" >&2; return 1; fi; return 0; }

# _apply <library> : apply_config of that library, logs to $TEST_DIR/log
_apply() {
    (
        log()       { echo "INFO: $*" >> "$TEST_DIR/log"; }
        log_warn()  { echo "WARN: $*" >> "$TEST_DIR/log"; }
        log_error() { echo "ERR: $*" >> "$TEST_DIR/log"; }
        log_debug() { :; }
        # shellcheck disable=SC1090
        source "$1"
        apply_config
    )
}

# _libs <case function> : run the case on the RU and on the EN library. The case
# runs as a plain command in a subshell: a failed assertion exits it non-zero.
_libs() {
    local lib
    for lib in "$BATS_TEST_DIRNAME/../awg_common.sh" "$BATS_TEST_DIRNAME/../awg_common_en.sh"; do
        echo "# library: ${lib##*/}" >&3
        ( "$1" "$lib" )
    done
}

c_same() {
    _state "$K1" "$K1"
    _apply "$1"
    _synced
    _nope _restarted
}
@test "same key in the file and on the device: syncconf, no restart" { require_flock; _libs c_same; }

c_none() {
    _state "" ""
    _apply "$1"
    _synced
    _nope _restarted
}
@test "no key anywhere (2.0): syncconf, no restart" { require_flock; _libs c_none; }

c_file_only() {
    _state "$K1" ""
    _apply "$1"
    _restarted
    _nope _synced
    grep -q 'HeaderProtectionKey' "$TEST_DIR/log"
}
@test "key in the file, none on the device: restart, not syncconf" { require_flock; _libs c_file_only; }

c_dev_only() {
    _state "" "$K1"
    _apply "$1"
    _restarted
    _nope _synced
}
@test "key on the device, none in the file: restart, not syncconf" { require_flock; _libs c_dev_only; }

c_values_differ() {
    _state "$K2" "$K1"
    _apply "$1"
    _restarted
    _nope _synced
}
@test "different key values: restart, not syncconf" { require_flock; _libs c_values_differ; }

c_unreadable() {
    _state "$K1" "$K1"
    : > "$AWG_DIR/.showconf_fail"
    _apply "$1"
    _restarted
    _nope _synced
}
@test "the device cannot be read: restart, not syncconf" { require_flock; _libs c_unreadable; }

c_no_leak() {
    _state "$K2" "$K1"
    ( set -x; _apply "$1" ) 2> "$TEST_DIR/trace" || true
    # the case is not vacuous: the trace did record apply_config running
    grep -q 'apply_config' "$TEST_DIR/trace"
    _restarted
    local s
    for s in "$K1" "$K2" "$SRV"; do
        if grep -qF "$s" "$TEST_DIR/trace" "$TEST_DIR/log"; then
            echo "secret ${s:0:8}... leaked"; return 1
        fi
    done
}
@test "neither key value nor the server key reaches the trace or the log" { require_flock; _libs c_no_leak; }
