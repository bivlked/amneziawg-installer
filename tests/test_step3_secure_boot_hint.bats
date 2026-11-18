#!/usr/bin/env bats
# Step 3 of the installer loads the kernel module with modprobe. When Secure
# Boot rejects the module, modprobe says why in its own words, and step 3 used
# to stop with a bare "modprobe amneziawg error." (#403: Debian 12, a DKMS
# module signed by a key that was never enrolled). Now the reason is kept and,
# for the two Secure Boot answers, the stop names the way out.
#
# "Key was rejected by service" = signed, but the key is not trusted (EKEYREJECTED).
# "Required key not available"  = not signed at all (ENOKEY).

load test_helper

INSTALL_RU="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
INSTALL_EN="$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"

func_from() { sed -n "/^$2()/,/^}/p" "$1"; }

# MODPROBE_OUT / MODPROBE_RC drive the modprobe stub; files under
# $TEST_DIR/root stand for the DKMS key locations.
run_step3_load() {
    local script="${1:-$INSTALL_RU}"
    {
        echo 'die() { echo "DIE: $*" >&2; exit 1; }'
        echo 'log() { echo "LOG: $*"; }'
        echo 'log_warn() { echo "WARN: $*"; }'
        echo 'update_state() { echo "$1" >> "$STATE_LOG"; }'
        echo 'lsmod() { echo "wireguard 100000 0"; }'
        echo 'modprobe() { [ -n "${MODPROBE_OUT-}" ] && echo "$MODPROBE_OUT" >&2; return ${MODPROBE_RC:-1}; }'
        echo 'sleep() { :; }'
        func_from "$script" _awg_modprobe_hint
        func_from "$script" step3_check_module
        echo 'step3_check_module'
    } > "$TEST_DIR/step3.sh"
    export STATE_LOG="$TEST_DIR/state.log"
    export AWG_SB_ROOT="$TEST_DIR/root"
    : > "$STATE_LOG"
    mkdir -p "$AWG_SB_ROOT"
    run bash "$TEST_DIR/step3.sh"
}

dkms_key() { mkdir -p "$TEST_DIR/root/var/lib/dkms" && : > "$TEST_DIR/root/var/lib/dkms/mok.pub"; }
ubuntu_key() { mkdir -p "$TEST_DIR/root/var/lib/shim-signed/mok" && : > "$TEST_DIR/root/var/lib/shim-signed/mok/MOK.der"; }

REJECTED="modprobe: ERROR: could not insert 'amneziawg': Key was rejected by service"
UNSIGNED="modprobe: ERROR: could not insert 'amneziawg': Required key not available"

@test "a rejected key with the Debian DKMS key on disk names Secure Boot and that key" {
    dkms_key
    MODPROBE_OUT="$REJECTED" run_step3_load
    [ "$status" -eq 1 ]
    [[ "$output" == *"DIE: "* ]]
    [[ "$output" == *"Key was rejected by service"* ]]
    [[ "$output" == *"Secure Boot"* ]]
    [[ "$output" == *"mokutil --sb-state"* ]]
    [[ "$output" == *"sudo mokutil --import /var/lib/dkms/mok.pub"* ]]
    [[ "$output" == *"MOK Manager"* ]]
    [[ "$output" == *"шага 3"* ]]
}

@test "a rejected key with only the Ubuntu shim key names MOK.der" {
    ubuntu_key
    MODPROBE_OUT="$REJECTED" run_step3_load
    [ "$status" -eq 1 ]
    [[ "$output" == *"sudo mokutil --import /var/lib/shim-signed/mok/MOK.der"* ]]
    [[ "$output" != *"/var/lib/dkms/mok.pub"* ]]
}

@test "the Debian DKMS key wins when both keys are on disk" {
    dkms_key
    ubuntu_key
    MODPROBE_OUT="$REJECTED" run_step3_load
    [[ "$output" == *"sudo mokutil --import /var/lib/dkms/mok.pub"* ]]
}

@test "a rejected key with no key file found still names Secure Boot, without a made-up path" {
    MODPROBE_OUT="$REJECTED" run_step3_load
    [ "$status" -eq 1 ]
    [[ "$output" == *"Secure Boot"* ]]
    [[ "$output" == *"mokutil --sb-state"* ]]
    [[ "$output" != *"--import /"* ]]
}

@test "an unsigned module under Secure Boot names Secure Boot" {
    dkms_key
    MODPROBE_OUT="$UNSIGNED" run_step3_load
    [ "$status" -eq 1 ]
    [[ "$output" == *"Required key not available"* ]]
    [[ "$output" == *"Secure Boot"* ]]
    [[ "$output" == *"mokutil --sb-state"* ]]
}

@test "any other modprobe failure keeps its own reason and does not blame Secure Boot" {
    dkms_key
    MODPROBE_OUT="modprobe: ERROR: could not insert 'amneziawg': Exec format error" run_step3_load
    [ "$status" -eq 1 ]
    [[ "$output" == *"DIE: "*"Exec format error"* ]]
    [[ "$output" != *"Secure Boot"* ]]
}

@test "a failure with no words from modprobe still stops the install" {
    MODPROBE_OUT="" run_step3_load
    [ "$status" -eq 1 ]
    [[ "$output" == *"DIE: "*"modprobe amneziawg"* ]]
    [[ "$output" != *"Secure Boot"* ]]
}

@test "a stopped step 3 leaves the state at 3, so a rerun resumes there" {
    dkms_key
    MODPROBE_OUT="$REJECTED" run_step3_load
    [ "$status" -eq 1 ]
    [ "$(cat "$STATE_LOG")" = "3" ]
    [[ "$output" != *"LOG: Модуль загружен."* ]]
}

@test "the English installer gives the same Secure Boot hint" {
    dkms_key
    MODPROBE_OUT="$REJECTED" run_step3_load "$INSTALL_EN"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Key was rejected by service"* ]]
    [[ "$output" == *"Secure Boot"* ]]
    [[ "$output" == *"sudo mokutil --import /var/lib/dkms/mok.pub"* ]]
    [[ "$output" == *"step 3"* ]]
}

@test "the English installer names Secure Boot for an unsigned module and not for other errors" {
    MODPROBE_OUT="$UNSIGNED" run_step3_load "$INSTALL_EN"
    [[ "$output" == *"Secure Boot"* ]]
    MODPROBE_OUT="modprobe: FATAL: Module amneziawg not found" run_step3_load "$INSTALL_EN"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not found"* ]]
    [[ "$output" != *"Secure Boot"* ]]
}

@test "a multi-line modprobe answer is kept on the one stop line" {
    MODPROBE_OUT=$'modprobe: ERROR: could not insert \'amneziawg\': Key was rejected by service\nsecond line' run_step3_load
    [ "$status" -eq 1 ]
    line=$(printf '%s\n' "$output" | grep '^DIE: ')
    [[ "$line" == *"Key was rejected by service second line"* ]]
    [[ "$line" == *"Secure Boot"* ]]
}
