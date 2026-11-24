#!/usr/bin/env bats
# Step 3 of the installer loads the kernel module with modprobe. When Secure
# Boot rejects the module, modprobe says so in its own words, and step 3 used
# to stop with a bare "modprobe amneziawg error." (#403: Debian 12, "Key was
# rejected by service"). Now the reason is kept, and for the Secure Boot answers
# the stop names the way out.
#
# A kernel that enforces module signatures answers "Key was rejected by service"
# both for an unsigned module and for one signed with a key that is not enrolled,
# so the hint asks modinfo for sig_id instead of guessing from the words:
# no signature - enrolling a key cannot help; a signature - enroll the DKMS key.

load test_helper

INSTALL_RU="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
INSTALL_EN="$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"

func_from() { sed -n "/^$2()/,/^}/p" "$1"; }

# MODPROBE_OUT / MODPROBE_RC drive the modprobe stub, MODINFO_SIGID /
# MODINFO_RC the signature check, MODINFO_SIGNER the name in the text, SB_STATE / MOKUTIL_RC the mokutil stub; files
# under $TEST_DIR/root stand for the DKMS key locations.
run_step3_load() {
    local script="${1:-$INSTALL_RU}"
    {
        echo 'die() { echo "DIE: $*" >&2; exit 1; }'
        echo 'log() { echo "LOG: $*"; }'
        echo 'log_warn() { echo "WARN: $*"; }'
        echo 'update_state() { echo "$1" >> "$STATE_LOG"; }'
        echo 'lsmod() { echo "wireguard 100000 0"; }'
        echo 'modprobe() { echo "LC_ALL=${LC_ALL-}" > "$TEST_DIR/modprobe.env"; [ -n "${MODPROBE_OUT-}" ] && echo "$MODPROBE_OUT" >&2; return ${MODPROBE_RC:-1}; }'
        echo 'modinfo() { [ "$1" = -F ] && [ "$3" = amneziawg ] || return 9; case "$2" in sig_id) [ -n "${MODINFO_SIGID-}" ] && echo "$MODINFO_SIGID"; return ${MODINFO_RC:-0} ;; signer) [ -n "${MODINFO_SIGNER-}" ] && echo "$MODINFO_SIGNER"; return 0 ;; sig_key) [ -n "${MODINFO_SIGKEY-}" ] && echo "$MODINFO_SIGKEY"; return 0 ;; esac; return 9; }'
        # openssl: a key file holds lines "DER:<serial>" or "PEM:<serial>"; the
        # stub answers only for the matching -inform, like a real x509 parse.
        echo 'openssl() { local inform="" in="" s; while [ $# -gt 0 ]; do case "$1" in -inform) inform=$2; shift 2 ;; -in) in=$2; shift 2 ;; *) shift ;; esac; done; s=$(sed -n "s/^${inform}://p" "$in"); [ -n "$s" ] || return 1; echo "serial=$s"; }'
        echo 'mokutil() { [ -n "${SB_STATE-}" ] && echo "$SB_STATE"; return ${MOKUTIL_RC:-0}; }'
        echo 'mkdir() { :; }'
        echo 'grep() { if [ "$1" = "-qxF" ]; then return 0; fi; command grep "$@"; }'
        echo 'sleep() { :; }'
        # _awg_serial_norm is one line: the range runs on through _awg_cert_serial.
        func_from "$script" _awg_serial_norm
        func_from "$script" _awg_modprobe_hint
        # step 3 up to "module loaded": what follows (modinfo, vermagic, the 3.1
        # gate) is covered by test_awg31_protocol_flag.bats
        sed -n '/^step3_check_module()/,/log "\(Модуль загружен\|Module loaded\)\."/p' "$script"
        echo 'fi; }'
        echo 'step3_check_module'
    } > "$TEST_DIR/step3.sh"
    export STATE_LOG="$TEST_DIR/state.log"
    export AWG_SB_ROOT="$TEST_DIR/root"
    export TEST_DIR
    : > "$STATE_LOG"
    command mkdir -p "$AWG_SB_ROOT"
    run bash "$TEST_DIR/step3.sh"
}

dkms_key() { mkdir -p "$TEST_DIR/root/var/lib/dkms" && : > "$TEST_DIR/root/var/lib/dkms/mok.pub"; }
ubuntu_key() { mkdir -p "$TEST_DIR/root/var/lib/shim-signed/mok" && : > "$TEST_DIR/root/var/lib/shim-signed/mok/MOK.der"; }

REJECTED="modprobe: ERROR: could not insert 'amneziawg': Key was rejected by service"
NOKEY="modprobe: ERROR: could not insert 'amneziawg': Required key not available"
EPERM="modprobe: ERROR: could not insert 'amneziawg': Operation not permitted"
SIGNER="DKMS module signing key"

@test "a signed module with the Debian DKMS key on disk: Secure Boot, the signer and that key" {
    dkms_key
    MODPROBE_OUT="$REJECTED" MODINFO_SIGID=PKCS#7 MODINFO_SIGNER="$SIGNER" run_step3_load
    [ "$status" -eq 1 ]
    [[ "$output" == *"DIE: "* ]]
    [[ "$output" == *"Key was rejected by service"* ]]
    [[ "$output" == *"Secure Boot"* ]]
    [[ "$output" == *"mokutil --sb-state"* ]]
    [[ "$output" == *"«DKMS module signing key»"* ]]
    [[ "$output" == *"sudo mokutil --import /var/lib/dkms/mok.pub"* ]]
    [[ "$output" == *"MOK Manager"* ]]
    [[ "$output" == *"шага 3"* ]]
}

@test "a signed module with only the Ubuntu shim key names MOK.der" {
    ubuntu_key
    MODPROBE_OUT="$REJECTED" MODINFO_SIGID=PKCS#7 MODINFO_SIGNER="$SIGNER" run_step3_load
    [ "$status" -eq 1 ]
    [[ "$output" == *"sudo mokutil --import /var/lib/shim-signed/mok/MOK.der"* ]]
    [[ "$output" != *"/var/lib/dkms/mok.pub"* ]]
}

@test "the Debian DKMS key wins when both keys are on disk" {
    dkms_key
    ubuntu_key
    MODPROBE_OUT="$REJECTED" MODINFO_SIGID=PKCS#7 MODINFO_SIGNER="$SIGNER" run_step3_load
    [[ "$output" == *"sudo mokutil --import /var/lib/dkms/mok.pub"* ]]
}

@test "a signed module with no key file found: enroll advice without a made-up path" {
    MODPROBE_OUT="$REJECTED" MODINFO_SIGID=PKCS#7 MODINFO_SIGNER="$SIGNER" run_step3_load
    [ "$status" -eq 1 ]
    [[ "$output" == *"Secure Boot"* ]]
    [[ "$output" == *"(mokutil --import)"* ]]
    [[ "$output" != *"--import /"* ]]
}

@test "an unsigned module gets no enroll advice even with a key on disk" {
    dkms_key
    MODPROBE_OUT="$REJECTED" MODINFO_SIGNER="" run_step3_load
    [ "$status" -eq 1 ]
    [[ "$output" == *"Secure Boot"* ]]
    [[ "$output" == *"Модуль не подписан"* ]]
    [[ "$output" == *"Регистрация ключа тут не поможет"* ]]
    [[ "$output" != *"--import /"* ]]
}

@test "a failed signer check gives both ways out and claims nothing about the signature" {
    dkms_key
    MODPROBE_OUT="$REJECTED" MODINFO_RC=1 run_step3_load
    [ "$status" -eq 1 ]
    [[ "$output" == *"Secure Boot"* ]]
    [[ "$output" == *"modinfo -F signer amneziawg"* ]]
    [[ "$output" != *"Модуль не подписан"* ]]
    [[ "$output" != *"Модуль подписан"* ]]
}

@test "Required key not available is treated as Secure Boot too" {
    dkms_key
    MODPROBE_OUT="$NOKEY" MODINFO_SIGID=PKCS#7 MODINFO_SIGNER="$SIGNER" run_step3_load
    [ "$status" -eq 1 ]
    [[ "$output" == *"Required key not available"* ]]
    [[ "$output" == *"sudo mokutil --import /var/lib/dkms/mok.pub"* ]]
}

@test "Operation not permitted gets the hint when mokutil confirms Secure Boot" {
    MODPROBE_OUT="$EPERM" MODINFO_SIGNER="" SB_STATE="SecureBoot enabled" run_step3_load
    [ "$status" -eq 1 ]
    [[ "$output" == *"Operation not permitted"* ]]
    [[ "$output" == *"Модуль не подписан"* ]]
}

@test "Operation not permitted gets no hint when Secure Boot is off or unknown" {
    MODPROBE_OUT="$EPERM" SB_STATE="SecureBoot disabled" run_step3_load
    [ "$status" -eq 1 ]
    [[ "$output" == *"DIE: "*"Operation not permitted"* ]]
    [[ "$output" != *"Secure Boot"* ]]
    MODPROBE_OUT="$EPERM" SB_STATE="" MOKUTIL_RC=127 run_step3_load
    [ "$status" -eq 1 ]
    [[ "$output" != *"Secure Boot"* ]]
}

@test "any other modprobe failure keeps its own reason and does not blame Secure Boot" {
    dkms_key
    MODPROBE_OUT="modprobe: ERROR: could not insert 'amneziawg': Exec format error" MODINFO_SIGID=PKCS#7 MODINFO_SIGNER="$SIGNER" run_step3_load
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

@test "modprobe runs in the C locale, so its words can be matched" {
    MODPROBE_OUT="$REJECTED" MODINFO_SIGID=PKCS#7 MODINFO_SIGNER="$SIGNER" run_step3_load
    [ "$(cat "$TEST_DIR/modprobe.env")" = "LC_ALL=C" ]
}

@test "a stopped step 3 leaves the state at 3, so a rerun resumes there" {
    dkms_key
    MODPROBE_OUT="$REJECTED" MODINFO_SIGID=PKCS#7 MODINFO_SIGNER="$SIGNER" run_step3_load
    [ "$status" -eq 1 ]
    [ "$(cat "$STATE_LOG")" = "3" ]
    [[ "$output" != *"LOG: Модуль загружен."* ]]
}

@test "a multi-line modprobe answer is kept on the one stop line" {
    MODPROBE_OUT=$'modprobe: ERROR: could not insert \'amneziawg\': Key was rejected by service\nsecond line' MODINFO_SIGID=PKCS#7 MODINFO_SIGNER="$SIGNER" run_step3_load
    [ "$status" -eq 1 ]
    line=$(printf '%s\n' "$output" | grep '^DIE: ')
    [[ "$line" == *"Key was rejected by service second line"* ]]
    [[ "$line" == *"Secure Boot"* ]]
}

@test "a warning from a successful modprobe is shown, not swallowed" {
    MODPROBE_OUT="modprobe: WARNING: /etc/modprobe.d/x.conf line 3: ignoring bad line" MODPROBE_RC=0 run_step3_load
    [[ "$output" == *"WARN: modprobe: modprobe: WARNING: /etc/modprobe.d/x.conf line 3: ignoring bad line"* ]]
    [[ "$output" == *"LOG: Модуль загружен."* ]]
    [[ "$output" != *"DIE: "* ]]
}

@test "the English installer gives the same Secure Boot hint" {
    dkms_key
    MODPROBE_OUT="$REJECTED" MODINFO_SIGID=PKCS#7 MODINFO_SIGNER="$SIGNER" run_step3_load "$INSTALL_EN"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Key was rejected by service"* ]]
    [[ "$output" == *"\"DKMS module signing key\""* ]]
    [[ "$output" == *"sudo mokutil --import /var/lib/dkms/mok.pub"* ]]
    [[ "$output" == *"step 3"* ]]
}

@test "the English installer: unsigned, failed check, other errors and warnings" {
    dkms_key
    MODPROBE_OUT="$REJECTED" MODINFO_SIGNER="" run_step3_load "$INSTALL_EN"
    [[ "$output" == *"The module is not signed"* ]]
    [[ "$output" != *"--import /"* ]]
    MODPROBE_OUT="$REJECTED" MODINFO_RC=1 run_step3_load "$INSTALL_EN"
    [[ "$output" == *"modinfo -F signer amneziawg"* ]]
    [[ "$output" != *"The module is signed"* ]]
    MODPROBE_OUT="modprobe: FATAL: Module amneziawg not found" run_step3_load "$INSTALL_EN"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not found"* ]]
    [[ "$output" != *"Secure Boot"* ]]
    MODPROBE_OUT="modprobe: WARNING: x" MODPROBE_RC=0 run_step3_load "$INSTALL_EN"
    [[ "$output" == *"WARN: modprobe: modprobe: WARNING: x"* ]]
    [[ "$output" == *"LOG: Module loaded."* ]]
}

@test "a signature without a signer name (kmod without libcrypto) is still a signature" {
    dkms_key
    MODPROBE_OUT="$REJECTED" MODINFO_SIGID=PKCS#7 MODINFO_SIGNER="" run_step3_load
    [ "$status" -eq 1 ]
    [[ "$output" == *"Модуль подписан ключом, но"* ]]
    [[ "$output" == *"sudo mokutil --import /var/lib/dkms/mok.pub"* ]]
    [[ "$output" != *"Модуль не подписан"* ]]
}

# ---------- the key on disk is checked against the module signature ----------

# key_file <path under root> <content>
key_file() { mkdir -p "$TEST_DIR/root$(dirname "$1")" && printf '%s\n' "$2" > "$TEST_DIR/root$1"; }

# each_installer <function>: the case runs on both installers.
each_installer() {
    local s seen=0
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        rm -rf "$TEST_DIR/root"
        "$1" "$s" || return 1
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}

_key_matches() {
    key_file /var/lib/dkms/mok.pub "DER:0a1b2c3d"
    MODPROBE_OUT="$REJECTED" MODINFO_SIGID=PKCS#7 MODINFO_SIGNER="$SIGNER" MODINFO_SIGKEY="0A:1B:2C:3D" run_step3_load "$1"
    [ "$status" -eq 1 ] || return 1
    [[ "$output" == *"sudo mokutil --import /var/lib/dkms/mok.pub"* ]] || { echo "$1: $output"; return 1; }
    [[ "$output" != *"openssl x509"* ]] || { echo "$1: a caveat on a checked key"; return 1; }
}
@test "the DKMS key on disk matches the module signature: the exact command, no caveat" {
    each_installer _key_matches
}

_key_leading_zero() {
    key_file /var/lib/dkms/mok.pub "DER:A1B2"
    MODPROBE_OUT="$REJECTED" MODINFO_SIGID=PKCS#7 MODINFO_SIGKEY="00:a1:b2" run_step3_load "$1"
    [[ "$output" == *"sudo mokutil --import /var/lib/dkms/mok.pub"* ]] || { echo "$1: $output"; return 1; }
    [[ "$output" != *"openssl x509"* ]] || return 1
}
@test "the serial numbers are compared without colons, case and leading zeros" {
    each_installer _key_leading_zero
}

_key_differs() {
    key_file /var/lib/dkms/mok.pub "DER:DEAD"
    MODPROBE_OUT="$REJECTED" MODINFO_SIGID=PKCS#7 MODINFO_SIGNER="$SIGNER" MODINFO_SIGKEY="BE:EF" run_step3_load "$1"
    [ "$status" -eq 1 ] || return 1
    [[ "$output" != *"--import /"* ]] || { echo "$1: offered a key that does not match: $output"; return 1; }
    [[ "$output" == *"modinfo -F sig_key amneziawg"* ]] || { echo "$1: $output"; return 1; }
    [[ "$output" == *"Secure Boot"* ]] || return 1
}
@test "the DKMS key on disk is a different key: no command to enroll it, the general way out" {
    each_installer _key_differs
}

_second_key_matches() {
    key_file /var/lib/dkms/mok.pub "DER:DEAD"
    key_file /var/lib/shim-signed/mok/MOK.der "DER:BEEF"
    MODPROBE_OUT="$REJECTED" MODINFO_SIGID=PKCS#7 MODINFO_SIGKEY="BE:EF" run_step3_load "$1"
    [[ "$output" == *"sudo mokutil --import /var/lib/shim-signed/mok/MOK.der"* ]] || { echo "$1: $output"; return 1; }
    [[ "$output" != *"/var/lib/dkms/mok.pub"* ]] || return 1
}
@test "mok.pub differs and MOK.der matches: the command names MOK.der" {
    each_installer _second_key_matches
}

_pem_key() {
    key_file /var/lib/dkms/mok.pub "PEM:BEEF"
    MODPROBE_OUT="$REJECTED" MODINFO_SIGID=PKCS#7 MODINFO_SIGKEY="BE:EF" run_step3_load "$1"
    [[ "$output" == *"sudo mokutil --import /var/lib/dkms/mok.pub"* ]] || { echo "$1: $output"; return 1; }
    [[ "$output" != *"openssl x509"* ]] || return 1
}
@test "a key file in PEM is read too" {
    each_installer _pem_key
}

_no_sig_key() {
    key_file /var/lib/dkms/mok.pub "DER:BEEF"
    MODPROBE_OUT="$REJECTED" MODINFO_SIGID=PKCS#7 MODINFO_SIGKEY="" run_step3_load "$1"
    [[ "$output" == *"sudo mokutil --import /var/lib/dkms/mok.pub"* ]] || { echo "$1: $output"; return 1; }
    [[ "$output" == *"openssl x509 -inform DER -in /var/lib/dkms/mok.pub -noout -serial"* ]] || { echo "$1: no caveat"; return 1; }
}
@test "modinfo shows no sig_key: the command with a caveat on how to check it" {
    each_installer _no_sig_key
}

_unread_named() {
    key_file /var/lib/dkms/mok.pub "DER:DEAD"
    key_file /var/lib/shim-signed/mok/MOK.der "garbage"
    MODPROBE_OUT="$REJECTED" MODINFO_SIGID=PKCS#7 MODINFO_SIGKEY="BE:EF" run_step3_load "$1"
    [[ "$output" == *"sudo mokutil --import /var/lib/shim-signed/mok/MOK.der"* ]] || { echo "$1: $output"; return 1; }
    [[ "$output" != *"--import /var/lib/dkms/mok.pub"* ]] || { echo "$1: named the key that did not match"; return 1; }
    [[ "$output" == *"-in /var/lib/shim-signed/mok/MOK.der -noout -serial"* ]] || return 1
}
@test "one key differs and the other cannot be read: the caveat names the unread one" {
    each_installer _unread_named
}
