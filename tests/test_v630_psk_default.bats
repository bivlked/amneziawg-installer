#!/usr/bin/env bats
# PresharedKey by default for new clients (D#371).
#
# `manage add` gives every new client its own PresharedKey unless --no-psk is
# given, or the server was installed with --no-psk (NO_PSK=1 in the init file);
# --psk then still turns it on for that call. --psk and --no-psk together, or
# either of them with a command other than add, is an error instead of being
# silently ignored. Existing clients are not touched (regen keeps what a client
# has, see test_psk_flag.bats).
#
# The real manage script runs end to end in a mock environment (stubbed awg,
# AWG_SKIP_APPLY=1), the same harness as test_add_allowed_ips.bats.

# shellcheck disable=SC2154  # $stderr is set by bats `run --separate-stderr`
load test_helper

bats_require_minimum_version 1.5.0

setup_manage_env() {
    MGMT_DIR=$(mktemp -d)
    mkdir -p "$MGMT_DIR/bin" "$MGMT_DIR/awg/keys"
    # genpsk returns a different value on every call, so a batch can show
    # that each client got its own key.
    cat > "$MGMT_DIR/bin/awg" << 'STUB'
#!/bin/bash
case "$1" in
    genkey) echo "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ;;
    genpsk)
        n=$(( $(cat "$AWG_STUB_PSK_COUNTER" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$AWG_STUB_PSK_COUNTER"
        printf 'PSK%040d=\n' "$n" ;;
    pubkey) cat >/dev/null; echo "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=" ;;
    *) exit 0 ;;
esac
STUB
    chmod +x "$MGMT_DIR/bin/awg"
    export AWG_STUB_PSK_COUNTER="$MGMT_DIR/psk_counter"
    export PATH="$MGMT_DIR/bin:$PATH"
    cat > "$MGMT_DIR/awg/awgsetup_cfg.init" << 'CONF'
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
export AWG_ENDPOINT='vpn.example.com'
CONF
    cat > "$MGMT_DIR/awg/awg0.conf" << 'CONF'
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
    export AWG_SKIP_APPLY=1
}

teardown() {
    rm -rf "$TEST_DIR" "${MGMT_DIR:-}"
    unset AWG_SKIP_APPLY AWG_STUB_PSK_COUNTER
}

# manage <script> <args...>: the real manage script against MGMT_DIR, with the
# library that belongs to it (RU with RU, EN with EN).
manage() {
    local script="$1"; shift
    local lib="awg_common.sh"
    [[ "$script" == *_en.sh ]] && lib="awg_common_en.sh"
    cp "$BATS_TEST_DIRNAME/../$lib" "$MGMT_DIR/awg/awg_common.sh"
    run --separate-stderr bash "$BATS_TEST_DIRNAME/../$script" "$@" --yes \
        --conf-dir="$MGMT_DIR/awg" --server-conf="$MGMT_DIR/awg/awg0.conf"
}

client_psk() { sed -n '/^\[Peer\]/,$ s/^PresharedKey = //p' "$MGMT_DIR/awg/$1.conf"; }
server_psk() {
    awk -v n="#_Name = $1" '$0==n{p=1; next} /^\[Peer\]/{p=0} p && /^PresharedKey = /{sub(/^PresharedKey = /,""); print}' \
        "$MGMT_DIR/awg/awg0.conf"
}

each_manage() {
    local seen=0 s
    for s in manage_amneziawg.sh manage_amneziawg_en.sh; do
        setup_manage_env
        "$1" "$s" || return 1
        rm -rf "$MGMT_DIR"
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}

_add_default_has_psk() {
    manage "$1" add alice
    [ "$status" -eq 0 ] || { echo "$1: add failed: $stderr"; return 1; }
    local c s
    c=$(client_psk alice); s=$(server_psk alice)
    [[ "$c" == PSK*= ]] || { echo "$1: client has no PresharedKey: '$c'"; return 1; }
    [ "$c" = "$s" ] || { echo "$1: client '$c' != server '$s'"; return 1; }
}
@test "add without flags gives the client a PresharedKey on both sides" {
    require_flock
    each_manage _add_default_has_psk
}

_add_batch_own_psk() {
    manage "$1" add alice bob
    [ "$status" -eq 0 ] || { echo "$1: add failed: $stderr"; return 1; }
    local a b
    a=$(client_psk alice); b=$(client_psk bob)
    [[ "$a" == PSK*= && "$b" == PSK*= ]] || { echo "$1: missing PSK a='$a' b='$b'"; return 1; }
    [ "$a" != "$b" ] || { echo "$1: both clients got the same PSK"; return 1; }
    [ "$(server_psk bob)" = "$b" ] || { echo "$1: server PSK of bob differs"; return 1; }
}
@test "a batch add gives every client its own PresharedKey" {
    require_flock
    each_manage _add_batch_own_psk
}

_add_no_psk() {
    manage "$1" add alice --no-psk
    [ "$status" -eq 0 ] || { echo "$1: add --no-psk failed: $stderr"; return 1; }
    run grep -c '^PresharedKey' "$MGMT_DIR/awg/alice.conf"
    [ "$output" = "0" ] || { echo "$1: client got a PSK with --no-psk"; return 1; }
    run grep -c '^PresharedKey' "$MGMT_DIR/awg/awg0.conf"
    [ "$output" = "0" ] || { echo "$1: server peer got a PSK with --no-psk"; return 1; }
    [ ! -s "$AWG_STUB_PSK_COUNTER" ] || { echo "$1: awg genpsk was called with --no-psk"; return 1; }
}
@test "add --no-psk creates the client without a PresharedKey" {
    require_flock
    each_manage _add_no_psk
}

_add_psk_still_works() {
    manage "$1" add alice --psk
    [ "$status" -eq 0 ] || { echo "$1: add --psk failed: $stderr"; return 1; }
    [[ "$(client_psk alice)" == PSK*= ]] || { echo "$1: --psk gave no PSK"; return 1; }
}
@test "add --psk still works and gives a PresharedKey" {
    require_flock
    each_manage _add_psk_still_works
}

_both_flags_refused() {
    manage "$1" add alice --psk --no-psk
    [ "$status" -ne 0 ] || { echo "$1: --psk with --no-psk was accepted"; return 1; }
    [[ "$stderr" == *"--psk"*"--no-psk"* ]] || { echo "$1: the refusal does not name both flags: $stderr"; return 1; }
    [ ! -e "$MGMT_DIR/awg/alice.conf" ] || { echo "$1: a client was created anyway"; return 1; }
}
@test "add with both --psk and --no-psk is refused before any change" {
    require_flock
    each_manage _both_flags_refused
}

_flags_outside_add_refused() {
    local f
    for f in --psk --no-psk; do
        manage "$1" list "$f"
        [ "$status" -eq 1 ] || { echo "$1: list $f was accepted (status $status)"; return 1; }
        [[ "$stderr" == *"$f"*add* ]] || { echo "$1: list $f: the refusal does not say it is for add: $stderr"; return 1; }
    done
}
@test "--psk and --no-psk with a command other than add are refused" {
    each_manage _flags_outside_add_refused
}

_init_no_psk_default() {
    echo "export NO_PSK=1" >> "$MGMT_DIR/awg/awgsetup_cfg.init"
    manage "$1" add alice
    [ "$status" -eq 0 ] || { echo "$1: add failed: $stderr"; return 1; }
    run grep -c '^PresharedKey' "$MGMT_DIR/awg/alice.conf"
    [ "$output" = "0" ] || { echo "$1: NO_PSK=1 in init, but the client got a PSK"; return 1; }
    manage "$1" add bob --psk
    [ "$status" -eq 0 ] || { echo "$1: add --psk failed: $stderr"; return 1; }
    [[ "$(client_psk bob)" == PSK*= ]] || { echo "$1: --psk did not override NO_PSK=1"; return 1; }
}
@test "NO_PSK=1 in the init file makes add create clients without PSK, --psk overrides it" {
    require_flock
    each_manage _init_no_psk_default
}

@test "NO_PSK is in all four safe_load_config whitelists" {
    local f
    for f in awg_common.sh awg_common_en.sh install_amneziawg.sh install_amneziawg_en.sh; do
        awk '/^safe_load_config\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../$f" | grep -qE '\|NO_PSK\|' \
            || { echo "NO_PSK missing from the whitelist in $f"; return 1; }
    done
}

# The installer: --no-psk is parsed and saved, so it survives the reboots.
_installer_saves_no_psk() {
    local src="$BATS_TEST_DIRNAME/../$1" d="$BATS_TEST_TMPDIR/init-$1"
    mkdir -p "$d"
    run bash -c '
        eval "$(awk "/^_awg_save_init\\(\\) \\{/,/^\\}/" "$1")"
        log() { :; }; log_warn() { :; }; log_error() { echo "ERR: $*" >&2; }; die() { echo "DIE: $*" >&2; exit 1; }
        CONFIG_FILE="$2/awgsetup_cfg.init"; AWG_DIR="$2"
        NO_PSK="$3"
        _awg_save_init || exit 9
        grep "^export NO_PSK=" "$CONFIG_FILE"
    ' _ "$src" "$d" "$2"
    [ "$status" -eq 0 ] || { echo "$1: _awg_save_init failed: $output"; return 1; }
    [ "$output" = "export NO_PSK=$2" ] || { echo "$1: saved '$output' for NO_PSK=$2"; return 1; }
}
@test "the installer saves NO_PSK into the init file" {
    local s
    for s in install_amneziawg.sh install_amneziawg_en.sh; do
        _installer_saves_no_psk "$s" 1 || return 1
        _installer_saves_no_psk "$s" 0 || return 1
    done
}

@test "the installer parses --no-psk into NO_PSK=1" {
    local s
    for s in install_amneziawg.sh install_amneziawg_en.sh; do
        grep -qE '^\s+--no-psk\)\s+NO_PSK=1; CLI_NO_PSK=1 ;;' "$BATS_TEST_DIRNAME/../$s" \
            || { echo "no --no-psk case in $s"; return 1; }
    done
}
