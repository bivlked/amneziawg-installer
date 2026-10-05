#!/usr/bin/env bats
# v6.0.0: a new install defaults to 3.1, and an UNCHOSEN default gives way to
# 2.0 on a machine where 3.1 cannot run (owner decision 27 sep 2026).
#
# The rules pinned here, each with the reason it exists:
#  - the fallback happens only when 3.1 was not chosen (AWG_PROTOCOL_SOURCE =
#    default), only for a new or unfinished install (no step 6 trace: no
#    profile can be voided), and only on a known reason code with the gate
#    answering normally. An explicit --protocol=3.1, an existing install, an
#    unknown source, internal_error or a gate that failed are refusals;
#  - at step 0 the parameters are generated after the decision (new install)
#    or regenerated from the SAVED J values and preset (unfinished install);
#  - at step 3 one candidate is generated, probed on a temporary interface and
#    only then written; a failed probe leaves the disk alone;
#  - the veto AWG_INSTALL_STATE_AT_START is taken at step 0 of the same
#    process, because step 0 and step 3 rewrite setup_state;
#  - step 6 never downgrades and hands out 3.1 profiles only after the post
#    gate passed in the same process;
#  - the final report names the generation and, after a fallback, the reason.
#
# 🔴 Refusals are asserted by what happened (DIE, no write, state untouched),
# not by the exit status alone. Both twins run every case.

bats_require_minimum_version 1.5.0

INSTALL_RU="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
INSTALL_EN="$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
COMMON_RU="$BATS_TEST_DIRNAME/../awg_common.sh"
COMMON_EN="$BATS_TEST_DIRNAME/../awg_common_en.sh"

func_from() { sed -n "/^$2()/,/^}/p" "$1"; }
# _src <file> <function> : a function from its header to the closing brace or
# parenthesis at column 0 (the probe is a ( ) subshell function).
_src() {
    awk -v n="$2" '
        !on && ($0 == n "() {" || $0 == n "() (") { on = 1; close_ = ($0 ~ /\{$/) ? "}" : ")" }
        on { print }
        on && $0 == close_ { exit }
    ' "$1"
}
_body() { sed -n '/^initialize_setup() {/,/^}/p' "$1"; }

setup() {
    TEST_DIR=$(mktemp -d)
    export TEST_DIR
    export AWG_DIR="$TEST_DIR/root-awg"
    export KEYS_DIR="$AWG_DIR/keys"
    export STATE_FILE="$AWG_DIR/setup_state"
    export CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init"
    export SERVER_CONF_FILE="$TEST_DIR/etc/awg0.conf"
    export SYS_NET_DIR="$TEST_DIR/sys-class-net"
    mkdir -p "$AWG_DIR" "$TEST_DIR/etc" "$TEST_DIR/bin" "$SYS_NET_DIR"
    printf '#!/bin/bash\n[[ -n "${IP_ERR:-}" ]] && echo "$IP_ERR" >&2\nexit "${IP_RC:-1}"\n' > "$TEST_DIR/bin/ip"
    chmod +x "$TEST_DIR/bin/ip"
    export IP_RC=1 IP_ERR='Device "awg0" does not exist.'
    export GATE_LOG="$TEST_DIR/gate.log" STATE_LOG="$TEST_DIR/state.log" EVLOG="$TEST_DIR/ev.log"
    : > "$GATE_LOG"; : > "$STATE_LOG"; : > "$EVLOG"
}

teardown() {
    [[ -n "${TEST_DIR:-}" ]] && rm -rf "$TEST_DIR"
}

_fresh() {
    rm -rf "${AWG_DIR:?}" "${TEST_DIR:?}/etc" "${SYS_NET_DIR:?}"
    mkdir -p "$AWG_DIR" "$TEST_DIR/etc" "$SYS_NET_DIR"
    : > "$GATE_LOG"; : > "$STATE_LOG"; : > "$EVLOG"
}

# ============================================================ fallback params

_gen() {
    local s="$1" lib="$2" f
    {
        echo "source '$lib' >/dev/null 2>&1 || true"
        echo 'log() { :; }; log_warn() { :; }; log_error() { :; }; log_debug() { :; }'
        echo 'die() { echo "DIE: $*" >&2; exit 1; }'
        for f in rand_range validate_jc_value validate_junk_size generate_awg_h_ranges generate_cps_i1 generate_awg_params _awg_fallback_params; do
            func_from "$s" "$f"
        done
    } > "$TEST_DIR/gen.sh"
}

@test "fallback params: saved J and preset carry over, the set is 2.0, CLI_* are restored, both twins" {
    local pair s lib n=0
    for pair in "$INSTALL_RU $COMMON_RU" "$INSTALL_EN $COMMON_EN"; do
        read -r s lib <<< "$pair"
        _gen "$s" "$lib"
        run bash -c "source '$TEST_DIR/gen.sh'
            export AWG_CPA=32-128
            AWG_PROTOCOL=2.0 AWG_Jc=0 AWG_Jmin=10 AWG_Jmax=20 AWG_PRESET=mobile
            CLI_JC='' CLI_JMIN='' CLI_JMAX='' CLI_PRESET=''
            _awg_fallback_params
            echo \"J=\$AWG_Jc/\$AWG_Jmin/\$AWG_Jmax P=\$AWG_PRESET H1=\$AWG_H1 S3=\$AWG_S3 CPA=\$(printenv AWG_CPA || echo unset) CLI=[\$CLI_JC][\$CLI_JMIN][\$CLI_JMAX][\$CLI_PRESET]\""
        [ "$status" -eq 0 ] || { echo "$s: $output"; return 1; }
        [[ "$output" == *"J=0/10/20 P=mobile"* ]] || { echo "$s: J or preset lost: $output"; return 1; }
        [[ "$output" == *"H1="*-* ]] || { echo "$s: H1 is not a 2.0 range: $output"; return 1; }
        [[ "$output" == *"CPA=unset"* ]] || { echo "$s: CPA survived the 2.0 set: $output"; return 1; }
        [[ "$output" == *"CLI=[][][][]"* ]] || { echo "$s: CLI_* leaked out of the call: $output"; return 1; }
        n=$((n + 1))
    done
    [ "$n" -eq 2 ]
}

@test "fallback params: an explicit preset of the current run sets J anew instead of the saved values, both twins" {
    local pair s lib n=0
    for pair in "$INSTALL_RU $COMMON_RU" "$INSTALL_EN $COMMON_EN"; do
        read -r s lib <<< "$pair"
        _gen "$s" "$lib"
        run bash -c "source '$TEST_DIR/gen.sh'
            AWG_PROTOCOL=2.0 AWG_Jc=6 AWG_Jmin=89 AWG_Jmax=339 AWG_PRESET=default
            CLI_JC='' CLI_JMIN='' CLI_JMAX='' CLI_PRESET=mobile
            _awg_fallback_params
            echo \"J=\$AWG_Jc/\$AWG_Jmin/\$AWG_Jmax P=\$AWG_PRESET\""
        [ "$status" -eq 0 ] || { echo "$s: $output"; return 1; }
        # mobile fixes Jc=3 and Jmin 30..50: the saved 6/89 must not survive
        [[ "$output" == *"J=3/"* && "$output" == *"P=mobile"* ]] || { echo "$s: saved J overrode the new preset: $output"; return 1; }
        [[ "$output" != *"/89/"* ]] || { echo "$s: saved Jmin kept: $output"; return 1; }
        n=$((n + 1))
    done
    [ "$n" -eq 2 ]
}

@test "fallback params: an explicit flag of the current run wins over the saved value, both twins" {
    local pair s lib
    for pair in "$INSTALL_RU $COMMON_RU" "$INSTALL_EN $COMMON_EN"; do
        read -r s lib <<< "$pair"
        _gen "$s" "$lib"
        run bash -c "source '$TEST_DIR/gen.sh'
            AWG_PROTOCOL=2.0 AWG_Jc=4 AWG_Jmin=10 AWG_Jmax=20 AWG_PRESET=default
            CLI_JC=7 CLI_JMIN='' CLI_JMAX='' CLI_PRESET=''
            _awg_fallback_params
            echo \"J=\$AWG_Jc/\$AWG_Jmin/\$AWG_Jmax CLI=[\$CLI_JC]\""
        [[ "$output" == *"J=7/10/20 CLI=[7]"* ]] || { echo "$s: $output"; return 1; }
    done
}

# ============================================================ step 0 decisions

_s0() {
    local s="$1" fn
    {
        echo 'die() { echo "DIE: $*" >&2; exit 1; }'
        echo 'log() { echo "LOG: $*"; }'
        echo 'log_warn() { echo "WARN: $*"; }'
        echo 'update_state() { echo "$1" > "$STATE_FILE"; }'
        echo 'SCRIPT_VERSION="0.0.0-test"'
        grep -E '^PROTOCOL_DEFAULT=' "$s"
        grep -E '^AWG31_FALLBACK_(PRE|POST)_CODES=' "$s"
        echo 'awg31_environment_blocker() { echo "$1" >> "$GATE_LOG"; printf "%s" "${BLOCKER_CODE-}"; return ${GATE_RC:-0}; }'
        for fn in awg_installed_protocol _awg_install_state _awg31_host_arch _awg31_blocker_message _awg31_code_in _awg31_fallback_reason _awg31_announce_fallback _awg31_existing_refusal _awg31_resolve_protocol _awg_gen_switch_rewind; do
            func_from "$s" "$fn"
        done
        echo 'step0_slice() {'
        echo '    local config_exists=0'
        echo '    AWG_PROTOCOL=""; AWG_PROTOCOL_SOURCE=""; AWG_PROTOCOL_FALLBACK=""; AWG_AUTO_FALLBACK=0; AWG_INSTALL_STATE_AT_START=""'
        echo '    if [[ -f "$CONFIG_FILE" ]]; then config_exists=1; source "$CONFIG_FILE"; fi'
        _body "$s" | sed -n '/^    local _proto_raw=/,/^    _awg_gen_switch_rewind$/p'
        echo '}'
        echo 'step0_slice'
        echo 'echo "PROTO=$AWG_PROTOCOL SRC=$AWG_PROTOCOL_SOURCE FB=$AWG_PROTOCOL_FALLBACK AUTO=$AWG_AUTO_FALLBACK AT=$AWG_INSTALL_STATE_AT_START STATE=$(cat "$STATE_FILE" 2>/dev/null)"'
    } > "$TEST_DIR/s0.sh"
    run env PATH="$TEST_DIR/bin:$PATH" bash "$TEST_DIR/s0.sh"
}

# _begun <marker> <step> [source] [fallback] : an install stopped before step 6.
_begun() {
    _fresh
    {
        printf "export AWG_PROTOCOL='%s'\n" "$1"
        [[ -n "${3:-}" ]] && printf "export AWG_PROTOCOL_SOURCE='%s'\n" "$3"
        [[ -n "${4:-}" ]] && printf "export AWG_PROTOCOL_FALLBACK='%s'\n" "$4"
    } > "$CONFIG_FILE"
    echo "$2" > "$STATE_FILE"
}

@test "step 0: a new install without the flag on a suitable machine gets 3.1 by default and the notice" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        _fresh
        CLI_PROTOCOL="" CLI_PROTOCOL_SET=0 BLOCKER_CODE="" _s0 "$s"
        [ "$status" -eq 0 ] || { echo "$s: $output"; return 1; }
        [[ "$output" == *"PROTO=3.1 SRC=default FB= AUTO=0 AT=0"* ]] || { echo "$s: $output"; return 1; }
        [ "$(cat "$GATE_LOG")" = "pre" ]
        [[ "$output" == *"WARN:"*"--protocol=2.0"* ]] || { echo "$s: no default notice: $output"; return 1; }
    done
}

@test "step 0: every pre reason code makes an unchosen default fall back to 2.0, loudly, both twins" {
    local s code
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        for code in arm kernel arch_unsupported arch_unknown; do
            _fresh
            CLI_PROTOCOL="" CLI_PROTOCOL_SET=0 BLOCKER_CODE="$code" _s0 "$s"
            [ "$status" -eq 0 ] || { echo "$s/$code: $output"; return 1; }
            [[ "$output" == *"PROTO=2.0 SRC=default FB=$code AUTO=0 AT=0"* ]] || { echo "$s/$code: $output"; return 1; }
            [[ "$output" == *"WARN:"*"$code"* ]] || { echo "$s/$code: no loud block: $output"; return 1; }
            [[ "$output" != *"DIE:"* ]]
        done
    done
}

@test "step 0: an explicit --protocol=3.1 on an unsuitable machine is refused, not downgraded" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        _fresh
        CLI_PROTOCOL=3.1 CLI_PROTOCOL_SET=1 BLOCKER_CODE="kernel" _s0 "$s"
        [ "$status" -eq 1 ]
        [[ "$output" == *"DIE:"*"6.7"* ]] || { echo "$s: $output"; return 1; }
        [[ "$output" != *"PROTO="* ]]
    done
}

@test "step 0: internal_error, an unknown code, a failed gate and a known code with a bad status are refusals" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        _fresh; CLI_PROTOCOL="" CLI_PROTOCOL_SET=0 BLOCKER_CODE="internal_error" GATE_RC=0 _s0 "$s"
        [ "$status" -eq 1 ] && [[ "$output" == *"DIE:"* ]] || { echo "$s internal_error: $output"; return 1; }
        _fresh; CLI_PROTOCOL="" CLI_PROTOCOL_SET=0 BLOCKER_CODE="brand_new_code" GATE_RC=0 _s0 "$s"
        [ "$status" -eq 1 ] && [[ "$output" == *"DIE:"* ]] || { echo "$s unknown: $output"; return 1; }
        _fresh; CLI_PROTOCOL="" CLI_PROTOCOL_SET=0 BLOCKER_CODE="" GATE_RC=2 _s0 "$s"
        [ "$status" -eq 1 ] && [[ "$output" == *"DIE:"* ]] || { echo "$s rc=2: $output"; return 1; }
        _fresh; CLI_PROTOCOL="" CLI_PROTOCOL_SET=0 BLOCKER_CODE="kernel" GATE_RC=2 _s0 "$s"
        [ "$status" -eq 1 ] && [[ "$output" == *"DIE:"* ]] || { echo "$s kernel rc=2: $output"; return 1; }
    done
}

@test "step 0: an existing 3.1 install with a default source is never downgraded" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        _begun 3.1 7 default
        : > "$SERVER_CONF_FILE"
        CLI_PROTOCOL="" CLI_PROTOCOL_SET=0 BLOCKER_CODE="kernel" _s0 "$s"
        [ "$status" -eq 1 ] || { echo "$s: $output"; return 1; }
        # the way out names the removal: --protocol=2.0 alone would be refused
        # for an existing install by the resolver itself
        [[ "$output" == *"DIE:"*"--uninstall"* ]] || { echo "$s: no removal path: $output"; return 1; }
        [[ "$output" != *"Выход: поставьте с --protocol=2.0"* && "$output" != *"Way out: install with --protocol=2.0"* ]] || { echo "$s: contradictory advice: $output"; return 1; }
        [[ "$output" == *"uname -r"* ]] || { echo "$s: no kernel repair hint: $output"; return 1; }
        [ "$(cat "$STATE_FILE")" = 7 ]
    done
}

@test "step 0: an unfinished default 3.1 install falls back with the saved-J path and rewinds to step 3" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        _begun 3.1 5 default
        CLI_PROTOCOL="" CLI_PROTOCOL_SET=0 BLOCKER_CODE="kernel" _s0 "$s"
        [ "$status" -eq 0 ] || { echo "$s: $output"; return 1; }
        [[ "$output" == *"PROTO=2.0 SRC=default FB=kernel AUTO=1 AT=2 STATE=3"* ]] || { echo "$s: $output"; return 1; }
    done
}

@test "step 0: an unfinished 3.1 install with no recorded source is refused, not downgraded" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        _begun 3.1 5
        CLI_PROTOCOL="" CLI_PROTOCOL_SET=0 BLOCKER_CODE="kernel" _s0 "$s"
        [ "$status" -eq 1 ] && [[ "$output" == *"DIE:"* ]] || { echo "$s: $output"; return 1; }
        [ "$(cat "$STATE_FILE")" = 5 ]
    done
}

@test "step 0: a garbage source in the init counts as unknown and forbids the fallback" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        _begun 3.1 5 yes
        CLI_PROTOCOL="" CLI_PROTOCOL_SET=0 BLOCKER_CODE="kernel" _s0 "$s"
        [ "$status" -eq 1 ] || { echo "$s: $output"; return 1; }
        [[ "$output" == *"WARN:"*"AWG_PROTOCOL_SOURCE"* ]] || { echo "$s: no warning: $output"; return 1; }
        [[ "$output" == *"DIE:"* ]]
    done
}

@test "step 0: a garbage fallback reason in the init is dropped" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        _begun 2.0 4 default weird_reason
        CLI_PROTOCOL="" CLI_PROTOCOL_SET=0 BLOCKER_CODE="" _s0 "$s"
        [ "$status" -eq 0 ] || { echo "$s: $output"; return 1; }
        [[ "$output" == *"PROTO=2.0 SRC=default FB= "* ]] || { echo "$s: $output"; return 1; }
        [[ "$output" == *"WARN:"*"AWG_PROTOCOL_FALLBACK"* ]]
    done
}

@test "step 0: a fallback reason next to a 3.1 marker is dropped" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        _begun 3.1 4 default kernel
        CLI_PROTOCOL="" CLI_PROTOCOL_SET=0 BLOCKER_CODE="" _s0 "$s"
        [ "$status" -eq 0 ] || { echo "$s: $output"; return 1; }
        [[ "$output" == *"PROTO=3.1 SRC=default FB= "* ]] || { echo "$s: $output"; return 1; }
        [[ "$output" == *"WARN:"*"AWG_PROTOCOL_FALLBACK"* ]]
    done
}

@test "step 0: an explicit choice after a fallback clears the reason and records the flag" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        _begun 2.0 4 default kernel
        CLI_PROTOCOL=2.0 CLI_PROTOCOL_SET=1 BLOCKER_CODE="" _s0 "$s"
        [ "$status" -eq 0 ] || { echo "$s: $output"; return 1; }
        [[ "$output" == *"PROTO=2.0 SRC=explicit FB= "* ]] || { echo "$s: $output"; return 1; }
    done
}

@test "step 0: an internal code or a failed gate on an existing 3.1 install is not a reason to remove it" {
    local s c
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        for c in "internal_error:0" "brand_new_code:0" ":2" "kernel:2"; do
            _begun 3.1 7 default
            : > "$SERVER_CONF_FILE"
            CLI_PROTOCOL="" CLI_PROTOCOL_SET=0 BLOCKER_CODE="${c%%:*}" GATE_RC="${c##*:}" _s0 "$s"
            [ "$status" -eq 1 ] || { echo "$s/$c: $output"; return 1; }
            [[ "$output" == *"DIE:"*"--verbose"* && "$output" != *"--uninstall"* ]] || { echo "$s/$c: $output"; return 1; }
            [ "$(cat "$STATE_FILE")" = 7 ]
        done
    done
}

@test "step 0: a matching explicit flag on an existing install records the choice and clears the reason" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        _begun 2.0 7 default kernel
        : > "$SERVER_CONF_FILE"
        CLI_PROTOCOL=2.0 CLI_PROTOCOL_SET=1 BLOCKER_CODE="" _s0 "$s"
        [ "$status" -eq 0 ] || { echo "$s: $output"; return 1; }
        [[ "$output" == *"PROTO=2.0 SRC=explicit FB= AUTO=0 AT=1"* ]] || { echo "$s: $output"; return 1; }
    done
}

@test "step 0: the process bookkeeping inherited from the environment is reset" {
    # AWG31_POST_OK=1 from outside would let step 6 hand out 3.1 profiles with
    # no post gate in this run. The reset block of initialize_setup is run as it
    # is, with the poisoned values exported.
    local s blk
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        blk=$(_body "$s" | sed -n '/^    AWG_PROTOCOL=""$/,/^    AWG_INSTALL_STATE_AT_START=""$/p')
        [[ "$blk" == *AWG31_POST_OK=0* ]] || { echo "$s: reset block not found"; return 1; }
        run env AWG31_POST_OK=1 AWG_AUTO_FALLBACK=1 AWG_INSTALL_STATE_AT_START=0 \
            AWG_PROTOCOL_SOURCE=default AWG_PROTOCOL_FALLBACK=kernel bash -c "$blk
echo \"POST=\$AWG31_POST_OK AUTO=\$AWG_AUTO_FALLBACK AT=[\$AWG_INSTALL_STATE_AT_START] SRC=[\$AWG_PROTOCOL_SOURCE] FB=[\$AWG_PROTOCOL_FALLBACK]\""
        [ "$status" -eq 0 ] || { echo "$s: $output"; return 1; }
        [ "$output" = "POST=0 AUTO=0 AT=[] SRC=[] FB=[]" ] || { echo "$s: $output"; return 1; }
    done
}

@test "step 0: a resume without the flag keeps the source and the reason from the init" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        _begun 2.0 4 default module_line2
        CLI_PROTOCOL="" CLI_PROTOCOL_SET=0 BLOCKER_CODE="" _s0 "$s"
        [ "$status" -eq 0 ] || { echo "$s: $output"; return 1; }
        # resumed after step 3: back to step 3, where the saved 2.0 set is probed
        [[ "$output" == *"PROTO=2.0 SRC=default FB=module_line2 AUTO=0 AT=2 STATE=3"* ]] || { echo "$s: $output"; return 1; }
    done
}

@test "step 0: an unfinished 3.1 install resumed after step 3 goes back to step 3 for the post gate" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        _begun 3.1 5 default
        CLI_PROTOCOL="" CLI_PROTOCOL_SET=0 BLOCKER_CODE="" _s0 "$s"
        [ "$status" -eq 0 ] || { echo "$s: $output"; return 1; }
        [[ "$output" == *"PROTO=3.1 SRC=default FB= AUTO=0 AT=2 STATE=3"* ]] || { echo "$s: $output"; return 1; }
    done
}

@test "step 0: the start state is taken before the resolver and the process bookkeeping is reset" {
    local s b reset at res
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        b=$(_body "$s")
        reset=$(grep -n '^[[:space:]]*AWG31_POST_OK=0$' <<< "$b" | head -1 | cut -d: -f1)
        at=$(grep -n '^[[:space:]]*AWG_INSTALL_STATE_AT_START="\$install_state"$' <<< "$b" | head -1 | cut -d: -f1)
        res=$(grep -n '^[[:space:]]*_awg31_resolve_protocol "\$install_state"$' <<< "$b" | head -1 | cut -d: -f1)
        [ -n "$reset" ] && [ -n "$at" ] && [ -n "$res" ] || { echo "$s: anchors $reset/$at/$res"; return 1; }
        [ "$reset" -lt "$res" ] && [ "$at" -lt "$res" ] || { echo "$s: order $reset/$at/$res"; return 1; }
    done
}

# ============================================================ step 3

_s3() {
    local s="$1" fn
    {
        echo 'die() { echo "DIE: $*" >&2; exit 1; }'
        echo 'log() { echo "LOG: $*"; }'
        echo 'log_warn() { echo "WARN: $*"; }'
        echo 'update_state() { echo "$1" >> "$STATE_LOG"; }'
        echo 'lsmod() { echo "amneziawg 100000 0"; }'
        echo 'modinfo() { echo "vermagic: $(uname -r)"; echo "version: test"; }'
        echo 'command() { if [ "$1" = "-v" ] && [ "$2" = "awg" ]; then [ "${AWG_PRESENT:-1}" = 1 ]; return; fi; builtin command "$@"; }'
        echo 'awg() { echo "awg-tools v0"; }'
        echo 'sleep() { :; }'
        echo 'SCRIPT_VERSION="0.0.0-test"'
        echo 'AWG31_POST_OK=0'
        grep -E '^AWG31_FALLBACK_(PRE|POST)_CODES=' "$s"
        for fn in _awg31_host_arch _awg31_blocker_message _awg31_code_in _awg31_fallback_reason _awg31_announce_fallback _awg31_post_fallback_allowed _awg31_post_fallback _awg31_existing_refusal _awg20_candidate_stale_die _awg31_step3_gate step3_check_module; do
            func_from "$s" "$fn"
        done
        echo 'awg31_environment_blocker() { echo "$1" >> "$GATE_LOG"; printf "%s" "${BLOCKER_CODE-}"; return ${GATE_RC:-0}; }'
        echo '_awg_install_state() { echo "STATECHK $1" >> "$EVLOG"; echo "${NOW_STATE:-2}"; }'
        echo '_awg_fallback_params() { echo "GEN proto=$AWG_PROTOCOL" >> "$EVLOG"; AWG_I1="<b 0x01>"; }'
        echo 'awg20_candidate_support() { echo "PROBE proto=$AWG_PROTOCOL i1=[$AWG_I1]" >> "$EVLOG"; return ${PROBE_RC:-0}; }'
        echo '_awg_save_init() { echo "SAVE proto=$AWG_PROTOCOL fb=$AWG_PROTOCOL_FALLBACK src=$AWG_PROTOCOL_SOURCE" >> "$EVLOG"; }'
        # REC_CONTENT: a record of an earlier probe of this process, as the probe
        # (or someone planting it in /tmp) would leave it; @PID becomes $$
        echo '[[ -n "${REC_CONTENT-}" ]] && printf "%b" "${REC_CONTENT//@PID/$$}" > "${TMPDIR:-/tmp}/awg31probe.$$.iface"'
        # REC_FIFO=1: a FIFO planted in place of the record (nobody ever writes it)
        echo '[[ "${REC_FIFO:-0}" == 1 ]] && mkfifo "${TMPDIR:-/tmp}/awg31probe.$$.iface"'
        echo '${S3_CALL:-step3_check_module}'
        echo 'echo "POST_OK=$AWG31_POST_OK PROTO=$AWG_PROTOCOL FB=${AWG_PROTOCOL_FALLBACK-}"'
    } > "$TEST_DIR/s3.sh"
    : > "$GATE_LOG"; : > "$STATE_LOG"; : > "$EVLOG"
    run timeout 60 bash "$TEST_DIR/s3.sh"
}

@test "step 3: a suitable machine passes post and sets the in-process flag" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        AWG_PROTOCOL=3.1 AWG_PROTOCOL_SOURCE=default AWG_INSTALL_STATE_AT_START=0 BLOCKER_CODE="" _s3 "$s"
        [ "$status" -eq 0 ] || { echo "$s: $output"; return 1; }
        [[ "$output" == *"POST_OK=1 PROTO=3.1"* ]] || { echo "$s: $output"; return 1; }
        grep -qx 4 "$STATE_LOG"
        [ ! -s "$EVLOG" ]
    done
}

@test "step 3: every known code falls back for an unchosen default: candidate, probe, then save, in that order" {
    local s code
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        for code in tools_old module_line2 module_probe_failed kernel arm arch_unsupported arch_unknown; do
            AWG_PROTOCOL=3.1 AWG_PROTOCOL_SOURCE=default AWG_INSTALL_STATE_AT_START=0 BLOCKER_CODE="$code" _s3 "$s"
            [ "$status" -eq 0 ] || { echo "$s/$code: $output"; return 1; }
            [[ "$output" == *"POST_OK=0 PROTO=2.0 FB=$code"* ]] || { echo "$s/$code: $output"; return 1; }
            [ "$(grep -v '^STATECHK' "$EVLOG" | cut -d' ' -f1 | tr '\n' ' ')" = "GEN PROBE SAVE " ] || { echo "$s/$code: order $(cat "$EVLOG")"; return 1; }
            grep -qx "SAVE proto=2.0 fb=$code src=default" "$EVLOG" || { echo "$s/$code: $(cat "$EVLOG")"; return 1; }
            grep -qx 'GEN proto=2.0' "$EVLOG" || { echo "$s/$code: generated on another generation: $(cat "$EVLOG")"; return 1; }
            grep -qx 'PROBE proto=2.0 i1=\[<b 0x01>\]' "$EVLOG" || { echo "$s/$code: probed something else: $(cat "$EVLOG")"; return 1; }
            grep -qx 4 "$STATE_LOG"
            [[ "$output" == *"WARN:"*"$code"* ]]
        done
    done
}

@test "step 3: --no-cps survives the fallback: the probed candidate carries no I1" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        AWG_PROTOCOL=3.1 AWG_PROTOCOL_SOURCE=default AWG_INSTALL_STATE_AT_START=0 BLOCKER_CODE="module_line2" NO_CPS=1 _s3 "$s"
        [ "$status" -eq 0 ] || { echo "$s: $output"; return 1; }
        grep -qx 'PROBE proto=2.0 i1=\[\]' "$EVLOG" || { echo "$s: $(cat "$EVLOG")"; return 1; }
    done
}

@test "step 3: a failed candidate probe dies before anything is written" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        AWG_PROTOCOL=3.1 AWG_PROTOCOL_SOURCE=default AWG_INSTALL_STATE_AT_START=0 BLOCKER_CODE="module_probe_failed" PROBE_RC=1 _s3 "$s"
        [ "$status" -eq 1 ] && [[ "$output" == *"DIE:"* ]] || { echo "$s: $output"; return 1; }
        grep -q '^PROBE' "$EVLOG" || { echo "$s: died before the probe"; return 1; }
        ! grep -q '^SAVE' "$EVLOG" || { echo "$s: written despite the failed probe"; return 1; }
        ! grep -qx 4 "$STATE_LOG" || { echo "$s: state advanced"; return 1; }
    done
}

@test "step 3: tools_old whose 2.0 set also fails points at the tools, not at the module" {
    # Stand, 5 oct 2026: second-line tools with a third-line module cannot set the
    # H1-H4 ranges, so the 2.0 candidate fails too; the cure is newer tools.
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        AWG_PROTOCOL=3.1 AWG_PROTOCOL_SOURCE=default AWG_INSTALL_STATE_AT_START=0 BLOCKER_CODE="tools_old" PROBE_RC=1 _s3 "$s"
        [ "$status" -eq 1 ] && [[ "$output" == *"DIE:"* ]] || { echo "$s: $output"; return 1; }
        [[ "$output" == *"--only-upgrade amneziawg-tools"* ]] || { echo "$s: no tools advice: $output"; return 1; }
        [[ "$output" != *"dkms status"* ]] || { echo "$s: still sent to the module: $output"; return 1; }
        ! grep -q '^SAVE' "$EVLOG" || { echo "$s: written despite the failed probe"; return 1; }
    done
    # Any other code keeps the module advice.
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        AWG_PROTOCOL=3.1 AWG_PROTOCOL_SOURCE=default AWG_INSTALL_STATE_AT_START=0 BLOCKER_CODE="module_probe_failed" PROBE_RC=1 _s3 "$s"
        [[ "$output" == *"dkms status"* ]] || { echo "$s: module advice lost: $output"; return 1; }
    done
}

@test "step 3: tools_old with no awg at all dies before a candidate is even generated" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        AWG_PROTOCOL=3.1 AWG_PROTOCOL_SOURCE=default AWG_INSTALL_STATE_AT_START=0 BLOCKER_CODE="tools_old" AWG_PRESENT=0 _s3 "$s"
        [ "$status" -eq 1 ] && [[ "$output" == *"DIE:"*"amneziawg-tools"* ]] || { echo "$s: $output"; return 1; }
        ! grep -q '^GEN' "$EVLOG" || { echo "$s: negative check failed: grep -q '^GEN' '$EVLOG'"; return 1; }
    done
}

@test "step 3: an explicit 3.1 is refused with the way to 2.0 that needs no removal" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        AWG_PROTOCOL=3.1 AWG_PROTOCOL_SOURCE=explicit AWG_INSTALL_STATE_AT_START=0 BLOCKER_CODE="module_line2" _s3 "$s"
        [ "$status" -eq 1 ] || { echo "$s: $output"; return 1; }
        [[ "$output" == *"DIE:"*"--protocol=2.0"* && "$output" != *"--uninstall"* ]] || { echo "$s: $output"; return 1; }
        ! grep -qv '^STATECHK' "$EVLOG" || { echo "$s: $(cat "$EVLOG")"; return 1; }
    done
}

@test "step 3: an install that was existing at step 0 is refused even if no trace is seen now" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        AWG_PROTOCOL=3.1 AWG_PROTOCOL_SOURCE=default AWG_INSTALL_STATE_AT_START=1 NOW_STATE=2 BLOCKER_CODE="module_line2" _s3 "$s"
        [ "$status" -eq 1 ] || { echo "$s: $output"; return 1; }
        [[ "$output" == *"DIE:"*"--uninstall"* ]] || { echo "$s: $output"; return 1; }
        [[ "$output" != *"Либо поставьте"* && "$output" != *"Or install with"* ]] || { echo "$s: contradictory advice: $output"; return 1; }
        # the repair that leaves the install alone comes first
        [[ "$output" == *"amneziawg-dkms"* ]] || { echo "$s: no repair hint: $output"; return 1; }
        ! grep -q '^SAVE' "$EVLOG" || { echo "$s: negative check failed: grep -q '^SAVE' '$EVLOG'"; return 1; }
    done
}

@test "step 3: the trace recheck passes whether the init exists (1 with it, 0 without)" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        : > "$CONFIG_FILE"
        # explicit 3.1: the fallback check returns before its own recheck, so
        # the line logged is the recheck of the gate's refusal path
        AWG_PROTOCOL=3.1 AWG_PROTOCOL_SOURCE=explicit AWG_INSTALL_STATE_AT_START=0 NOW_STATE=2 BLOCKER_CODE="module_line2" _s3 "$s"
        grep -qx 'STATECHK 1' "$EVLOG" || { echo "$s with init: $(cat "$EVLOG")"; return 1; }
        rm -f "$CONFIG_FILE"
        AWG_PROTOCOL=3.1 AWG_PROTOCOL_SOURCE=explicit AWG_INSTALL_STATE_AT_START=0 NOW_STATE=2 BLOCKER_CODE="module_line2" _s3 "$s"
        grep -qx 'STATECHK 0' "$EVLOG" || { echo "$s without init: $(cat "$EVLOG")"; return 1; }
    done
}

@test "step 3: a gate that failed on an existing install, with or without a code, is not a reason to remove it" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        AWG_PROTOCOL=3.1 AWG_PROTOCOL_SOURCE=default AWG_INSTALL_STATE_AT_START=1 BLOCKER_CODE="" GATE_RC=1 _s3 "$s"
        [ "$status" -eq 1 ] && [[ "$output" == *"DIE:"*"--verbose"* && "$output" != *"--uninstall"* ]] || { echo "$s no code: $output"; return 1; }
        AWG_PROTOCOL=3.1 AWG_PROTOCOL_SOURCE=default AWG_INSTALL_STATE_AT_START=1 BLOCKER_CODE="module_line2" GATE_RC=2 _s3 "$s"
        [ "$status" -eq 1 ] && [[ "$output" == *"DIE:"*"--verbose"* && "$output" != *"--uninstall"* ]] || { echo "$s known code, bad status: $output"; return 1; }
    done
}

@test "step 3: an internal gate error on an existing install is not a reason to remove it" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        AWG_PROTOCOL=3.1 AWG_PROTOCOL_SOURCE=default AWG_INSTALL_STATE_AT_START=1 BLOCKER_CODE="internal_error" _s3 "$s"
        [ "$status" -eq 1 ] || { echo "$s: $output"; return 1; }
        [[ "$output" == *"DIE:"* && "$output" != *"--uninstall"* ]] || { echo "$s: advises a removal for our own defect: $output"; return 1; }
        [[ "$output" == *"--verbose"* ]] || { echo "$s: $output"; return 1; }
    done
}

@test "step 3: a candidate that was not checked because of a left probe interface is not blamed on the module" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        AWG_PROTOCOL=3.1 AWG_PROTOCOL_SOURCE=default AWG_INSTALL_STATE_AT_START=0 BLOCKER_CODE="module_line2" PROBE_RC=2 _s3 "$s"
        [ "$status" -eq 1 ] || { echo "$s: $output"; return 1; }
        [[ "$output" == *"DIE:"*"awgp"* ]] || { echo "$s: $output"; return 1; }
        [[ "$output" != *"не принял"* && "$output" != *"refused the 2.0"* ]] || { echo "$s: blamed on the module: $output"; return 1; }
        ! grep -q '^SAVE' "$EVLOG" || { echo "$s: negative check failed: grep -q '^SAVE' '$EVLOG'"; return 1; }
        AWG_PROTOCOL=2.0 AWG_PROTOCOL_FALLBACK=kernel AWG_INSTALL_STATE_AT_START=0 PROBE_RC=2 _s3 "$s"
        [ "$status" -eq 1 ] && [[ "$output" == *"DIE:"*"awgp"* ]] || { echo "$s saved set: $output"; return 1; }
    done
}

@test "step 3: the left-interface refusal names only a name of our probe, never a planted one" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        TMPDIR="$TEST_DIR" REC_CONTENT='eth0' AWG_PROTOCOL=3.1 AWG_PROTOCOL_SOURCE=default AWG_INSTALL_STATE_AT_START=0 BLOCKER_CODE="module_line2" PROBE_RC=2 _s3 "$s"
        [ "$status" -eq 1 ] || { echo "$s: $output"; return 1; }
        [[ "$output" != *eth0* && "$output" == *"awgp"* ]] || { echo "$s: a planted name reached the advice: $output"; return 1; }
        TMPDIR="$TEST_DIR" REC_CONTENT='awgp@PIDx1\033[2Jtrail' AWG_PROTOCOL=3.1 AWG_PROTOCOL_SOURCE=default AWG_INSTALL_STATE_AT_START=0 BLOCKER_CODE="module_line2" PROBE_RC=2 _s3 "$s"
        [ "$status" -eq 1 ] && [[ "$output" == *"DIE:"*"awgp"* ]] || { echo "$s: did not reach the refusal: $output"; return 1; }
        [[ "$output" != *$'\033'* ]] || { echo "$s: a control sequence reached the console"; return 1; }
        # only the first line counts: a real name followed by a planted second line
        TMPDIR="$TEST_DIR" REC_CONTENT='awgp@PIDx3\neth0' AWG_PROTOCOL=3.1 AWG_PROTOCOL_SOURCE=default AWG_INSTALL_STATE_AT_START=0 BLOCKER_CODE="module_line2" PROBE_RC=2 _s3 "$s"
        [[ "$output" =~ awgp[0-9]+x3 && "$output" != *eth0* ]] || { echo "$s: first line: $output"; return 1; }
        TMPDIR="$TEST_DIR" REC_CONTENT='awgp@PIDx2' AWG_PROTOCOL=3.1 AWG_PROTOCOL_SOURCE=default AWG_INSTALL_STATE_AT_START=0 BLOCKER_CODE="module_line2" PROBE_RC=2 _s3 "$s"
        [[ "$output" =~ awgp[0-9]+x2 ]] || { echo "$s: the real probe name is not named: $output"; return 1; }
        # a probe name of another process, and a number outside 1..5, are not ours
        TMPDIR="$TEST_DIR" REC_CONTENT='awgp1x1' AWG_PROTOCOL=3.1 AWG_PROTOCOL_SOURCE=default AWG_INSTALL_STATE_AT_START=0 BLOCKER_CODE="module_line2" PROBE_RC=2 _s3 "$s"
        [ "$status" -eq 1 ] && [[ "$output" != *"awgp1x1"* ]] || { echo "$s: another process's name was named: $output"; return 1; }
        TMPDIR="$TEST_DIR" REC_CONTENT='awgp@PIDx9' AWG_PROTOCOL=3.1 AWG_PROTOCOL_SOURCE=default AWG_INSTALL_STATE_AT_START=0 BLOCKER_CODE="module_line2" PROBE_RC=2 _s3 "$s"
        [ "$status" -eq 1 ] && ! [[ "$output" =~ awgp[0-9]+x9 ]] || { echo "$s: an out-of-mask number was named: $output"; return 1; }
    done
}

@test "step 3: a FIFO planted as the probe record does not hang the left-interface refusal" {
    local s t0
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        t0=$SECONDS
        TMPDIR="$TEST_DIR" REC_FIFO=1 AWG_PROTOCOL=3.1 AWG_PROTOCOL_SOURCE=default AWG_INSTALL_STATE_AT_START=0 BLOCKER_CODE="module_line2" PROBE_RC=2 _s3 "$s"
        [ "$status" -eq 1 ] && [[ "$output" == *"DIE:"*"awgp"* ]] || { echo "$s: $output"; return 1; }
        (( SECONDS - t0 < 20 )) || { echo "$s: took $((SECONDS - t0)) s"; return 1; }
        # the FIFO really was there: without it the fallback text passes this case too
        [ -n "$(find "$TEST_DIR" -maxdepth 1 -type p -name 'awg31probe.*.iface')" ] || { echo "$s: no FIFO was planted"; return 1; }
        find "$TEST_DIR" -maxdepth 1 -type p -name 'awg31probe.*.iface' -delete
    done
}

@test "step 3: a trace found now makes the advice lead to removal even if step 0 saw a new install" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        AWG_PROTOCOL=3.1 AWG_PROTOCOL_SOURCE=explicit AWG_INSTALL_STATE_AT_START=0 NOW_STATE=1 BLOCKER_CODE="module_line2" _s3 "$s"
        [ "$status" -eq 1 ] || { echo "$s: $output"; return 1; }
        [[ "$output" == *"DIE:"*"--uninstall"* ]] || { echo "$s: $output"; return 1; }
        [[ "$output" != *"без удаления"* && "$output" != *"without removing"* ]] || { echo "$s: $output"; return 1; }
    done
}

@test "step 3: a step 6 trace found right before the fallback is a refusal" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        AWG_PROTOCOL=3.1 AWG_PROTOCOL_SOURCE=default AWG_INSTALL_STATE_AT_START=0 NOW_STATE=1 BLOCKER_CODE="module_line2" _s3 "$s"
        [ "$status" -eq 1 ] && [[ "$output" == *"DIE:"* ]] || { echo "$s: $output"; return 1; }
        grep -q '^STATECHK' "$EVLOG" || { echo "$s: the trace was not rechecked: $(cat "$EVLOG")"; return 1; }
        ! grep -q '^GEN' "$EVLOG" || { echo "$s: negative check failed: grep -q '^GEN' '$EVLOG'"; return 1; }
    done
}

@test "step 3: internal_error, an unknown code and a known code with a bad status are refusals" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        AWG_PROTOCOL=3.1 AWG_PROTOCOL_SOURCE=default AWG_INSTALL_STATE_AT_START=0 BLOCKER_CODE="internal_error" _s3 "$s"
        [ "$status" -eq 1 ] && [[ "$output" == *"DIE:"* ]] || { echo "$s internal_error: $output"; return 1; }
        AWG_PROTOCOL=3.1 AWG_PROTOCOL_SOURCE=default AWG_INSTALL_STATE_AT_START=0 BLOCKER_CODE="new_code" _s3 "$s"
        [ "$status" -eq 1 ] && [[ "$output" == *"DIE:"* ]] || { echo "$s unknown: $output"; return 1; }
        AWG_PROTOCOL=3.1 AWG_PROTOCOL_SOURCE=default AWG_INSTALL_STATE_AT_START=0 BLOCKER_CODE="tools_old" GATE_RC=2 _s3 "$s"
        [ "$status" -eq 1 ] && [[ "$output" == *"DIE:"* ]] || { echo "$s rc: $output"; return 1; }
        ! grep -q '^SAVE' "$EVLOG" || { echo "$s: negative check failed: grep -q '^SAVE' '$EVLOG'"; return 1; }
    done
}

@test "step 3: a 2.0 set saved by the step 0 fallback is probed before step 4, and a failure stops there" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        AWG_PROTOCOL=2.0 AWG_PROTOCOL_FALLBACK=kernel AWG_INSTALL_STATE_AT_START=2 _s3 "$s"
        [ "$status" -eq 0 ] || { echo "$s: $output"; return 1; }
        grep -q '^PROBE proto=2.0' "$EVLOG" || { echo "$s: not probed"; return 1; }
        ! grep -q '^GEN' "$EVLOG" || { echo "$s: regenerated instead of probing the saved set"; return 1; }
        [ ! -s "$GATE_LOG" ]
        AWG_PROTOCOL=2.0 AWG_PROTOCOL_FALLBACK=kernel AWG_INSTALL_STATE_AT_START=0 PROBE_RC=1 _s3 "$s"
        [ "$status" -eq 1 ] && [[ "$output" == *"DIE:"* ]] || { echo "$s: $output"; return 1; }
        ! grep -qx 4 "$STATE_LOG" || { echo "$s: negative check failed: grep -qx 4 '$STATE_LOG'"; return 1; }
    done
}

@test "step 3: the saved fallback set is probed whatever the start state, a plain 2.0 install is not" {
    # The state veto forbids a downgrade, not a check: an unfinished fallback
    # install that step 0 took for an existing one (an ip failure gives 1)
    # must not reach step 6 unprobed. Found by the code review of round 1.
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        AWG_PROTOCOL=2.0 AWG_PROTOCOL_FALLBACK=kernel AWG_INSTALL_STATE_AT_START=1 _s3 "$s"
        [ "$status" -eq 0 ] || { echo "$s existing: $output"; return 1; }
        grep -q '^PROBE proto=2.0' "$EVLOG" || { echo "$s existing: not probed"; return 1; }
        AWG_PROTOCOL=2.0 AWG_PROTOCOL_FALLBACK="" AWG_INSTALL_STATE_AT_START=0 _s3 "$s"
        [ "$status" -eq 0 ] && [ ! -s "$EVLOG" ] || { echo "$s plain: $output"; return 1; }
    done
}

# ============================================================ step 6

@test "step 6: the post gate never downgrades, even where step 3 would have" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        S3_CALL="_awg31_step3_gate step6" AWG_PROTOCOL=3.1 AWG_PROTOCOL_SOURCE=default AWG_INSTALL_STATE_AT_START=0 BLOCKER_CODE="module_line2" _s3 "$s"
        [ "$status" -eq 1 ] && [[ "$output" == *"DIE:"* ]] || { echo "$s: $output"; return 1; }
        ! grep -qv '^STATECHK' "$EVLOG" || { echo "$s: $(cat "$EVLOG")"; return 1; }
        S3_CALL="_awg31_step3_gate step6" AWG_PROTOCOL=3.1 AWG_PROTOCOL_SOURCE=default AWG_INSTALL_STATE_AT_START=0 BLOCKER_CODE="" _s3 "$s"
        [ "$status" -eq 0 ] && [[ "$output" == *"POST_OK=1"* ]] || { echo "$s pass: $output"; return 1; }
    done
}

@test "step 6: a 3.1 run without the in-process post pass runs the gate before any key is made" {
    local s b gate gen keys
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        b=$(func_from "$s" step6_generate_configs)
        gate=$(grep -n '^[[:space:]]*_awg31_step3_gate step6$' <<< "$b" | head -1 | cut -d: -f1)
        gen=$(grep -n 'if \[\[ "\${AWG31_POST_OK:-0}" -ne 1 \]\]; then' <<< "$b" | head -1 | cut -d: -f1)
        keys=$(grep -n 'mkdir -p "\$KEYS_DIR"' <<< "$b" | head -1 | cut -d: -f1)
        [ -n "$gate" ] && [ -n "$gen" ] && [ -n "$keys" ] || { echo "$s: anchors $gate/$gen/$keys"; return 1; }
        [ "$gen" -lt "$gate" ] && [ "$gate" -lt "$keys" ] || { echo "$s: order $gen/$gate/$keys"; return 1; }
    done
}

# ============================================================ final report

@test "report: the generation line covers all four cases, both twins" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        { func_from "$s" _awg31_host_arch; func_from "$s" _awg31_fallback_reason; func_from "$s" _awg_generation_summary; } > "$TEST_DIR/sum.sh"
        run bash -c "source '$TEST_DIR/sum.sh'
            AWG_PROTOCOL=3.1 AWG_PROTOCOL_SOURCE=default AWG_PROTOCOL_FALLBACK=''; echo \"A[\$(_awg_generation_summary)]\"
            AWG_PROTOCOL=2.0 AWG_PROTOCOL_SOURCE=explicit; echo \"B[\$(_awg_generation_summary)]\"
            AWG_PROTOCOL=2.0 AWG_PROTOCOL_SOURCE=default AWG_PROTOCOL_FALLBACK=kernel; echo \"C[\$(_awg_generation_summary)]\"
            AWG_PROTOCOL=2.0 AWG_PROTOCOL_SOURCE='' AWG_PROTOCOL_FALLBACK=''; echo \"D[\$(_awg_generation_summary)]\"
            AWG_PROTOCOL=3.1 AWG_PROTOCOL_SOURCE='' AWG_PROTOCOL_FALLBACK=''; echo \"E[\$(_awg_generation_summary)]\"
            AWG_PROTOCOL=3.1 AWG_PROTOCOL_SOURCE=explicit AWG_PROTOCOL_FALLBACK=''; echo \"F[\$(_awg_generation_summary)]\""
        [ "$status" -eq 0 ]
        [[ "$output" == *"A[3.1"* ]] || { echo "$s: $output"; return 1; }
        [[ "$output" == *"B[2.0 ("* ]] || { echo "$s: $output"; return 1; }
        [[ "$output" == *"C[2.0 - "*"6.7]"* ]] || { echo "$s: $output"; return 1; }
        [[ "$output" == *"D[2.0 ("* ]] || { echo "$s: $output"; return 1; }
        # an unknown source on 3.1 claims neither "default" nor "by flag"
        [[ "$output" == *"E[3.1]"* ]] || { echo "$s: $output"; return 1; }
        [[ "$output" == *"F[3.1 ("* ]] || { echo "$s: $output"; return 1; }
        [ "$(grep '^F\[' <<< "$output" | cut -c2-)" != "$(grep '^A\[' <<< "$output" | cut -c2-)" ] || { echo "$s: 3.1 by flag and by default read the same"; return 1; }
        # four different texts
        [ "$(grep -o '^[A-D]\[.*\]$' <<< "$output" | cut -c3- | sort -u | wc -l)" -eq 4 ] || { echo "$s: $output"; return 1; }
    done
}

# ============================================================ candidate probe

# make_cand_awg : awg set records the pairs it got, showconf prints them back
# as amneziawg-tools do ("Jc = 3"). SHOW_MODE: ok | dropi1 | alterh1 | fail.
make_cand_awg() {
    cat > "$TEST_DIR/bin/awg" << 'STUB'
#!/usr/bin/env bash
case "$1" in
    genkey) echo "PROBE+KEY/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ;;
    set) shift 2; printf '%s\n' "$@" > "$TEST_DIR/set.args"; exit "${SET_RC:-0}" ;;
    showconf)
        [ "${SHOW_MODE:-ok}" = fail ] && exit 1
        echo "[Interface]"
        mapfile -t a < "$TEST_DIR/set.args"
        for ((i = 0; i + 1 < ${#a[@]}; i += 2)); do
            k="${a[i]}" v="${a[i+1]}"
            case "$k" in jc) k=Jc ;; jmin) k=Jmin ;; jmax) k=Jmax ;; *) k="${k^^}" ;; esac
            [ "${SHOW_MODE:-ok}" = dropi1 ] && [ "$k" = I1 ] && continue
            [ "${SHOW_MODE:-ok}" = alterh1 ] && [ "$k" = H1 ] && v="1-2"
            [ "${SHOW_MODE:-ok}" = "alter:$k" ] && v="${v}9"
            echo "$k = $v"
        done
        ;;
esac
exit 0
STUB
    chmod +x "$TEST_DIR/bin/awg"
    cat > "$TEST_DIR/bin/ip" << 'STUB'
#!/usr/bin/env bash
D="$TEST_DIR/ifaces"
case "$2" in
    show) [ -e "$D/$3" ] && exit 0 || exit 1 ;;
    add) mkdir -p "$D"; : > "$D/$3"; exit 0 ;;
    del) rm -f "$D/$3"; exit 0 ;;
esac
exit 0
STUB
    chmod +x "$TEST_DIR/bin/ip"
}

_cand() {
    local s="$1"
    { _src "$s" _awg31_module_probe; func_from "$s" awg20_candidate_support; } > "$TEST_DIR/cand.sh"
    rm -rf "$TEST_DIR/ifaces" "$TEST_DIR/set.args"
    run env PATH="$TEST_DIR/bin:$PATH" TMPDIR="$TEST_DIR" bash -c "source '$TEST_DIR/cand.sh'
        AWG_Jc=3 AWG_Jmin=57 AWG_Jmax=128 AWG_S1=47 AWG_S2=57 AWG_S3=22 AWG_S4=20
        AWG_H1=106708213-181093823 AWG_H2=382267692-422170153 AWG_H3=635761689-774441487 AWG_H4=1511098413-2076194992
        AWG_I1=\"\${CAND_I1-<r 2><b 0x8580><rc 30>}\"
        if awg20_candidate_support; then echo VERDICT=ok; else echo VERDICT=failed; fi"
}

@test "candidate probe: the whole 2.0 set is applied and read back verbatim, both twins" {
    local s
    make_cand_awg
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        SHOW_MODE=ok _cand "$s"
        [[ "$output" == *"VERDICT=ok"* ]] || { echo "$s: $output"; return 1; }
        grep -qx 'h1' "$TEST_DIR/set.args" || { echo "$s: check failed: grep -qx 'h1' '$TEST_DIR/set.args'"; return 1; }
        grep -qx '106708213-181093823' "$TEST_DIR/set.args" || { echo "$s: check failed: grep -qx '106708213-181093823' '$TEST_DIR/set.args'"; return 1; }
        grep -qx 'i1' "$TEST_DIR/set.args" || { echo "$s: I1 not sent"; return 1; }
        ! grep -q 'header-protection-key' "$TEST_DIR/set.args" || { echo "$s: negative check failed: grep -q 'header-protection-key' '$TEST_DIR/set.args'"; return 1; }
        [ -z "$(ls -A "$TEST_DIR/ifaces" 2>/dev/null)" ] || { echo "$s: the temporary interface was left behind"; return 1; }
    done
}

@test "candidate probe: an empty I1 (--no-cps) is not sent and not required back" {
    local s
    make_cand_awg
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        CAND_I1="" SHOW_MODE=ok _cand "$s"
        [[ "$output" == *"VERDICT=ok"* ]] || { echo "$s: $output"; return 1; }
        ! grep -qx 'i1' "$TEST_DIR/set.args" || { echo "$s: negative check failed: grep -qx 'i1' '$TEST_DIR/set.args'"; return 1; }
    done
}

@test "candidate probe: a value that comes back different, a lost I1, a refused set or a failed read is 'failed'" {
    local s mode
    make_cand_awg
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        for mode in dropi1 alterh1 fail; do
            SHOW_MODE="$mode" _cand "$s"
            [[ "$output" == *"VERDICT=failed"* ]] || { echo "$s/$mode: $output"; return 1; }
        done
        SET_RC=1 SHOW_MODE=ok _cand "$s"
        [[ "$output" == *"VERDICT=failed"* ]] || { echo "$s/setrc: $output"; return 1; }
        [ -z "$(ls -A "$TEST_DIR/ifaces" 2>/dev/null)" ] || { echo "$s: interface left after a refusal"; return 1; }
    done
}

@test "candidate probe: all twelve parameters and I1 are sent, and a change of ANY one of them is caught" {
    local s key
    make_cand_awg
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        SHOW_MODE=ok _cand "$s"
        [[ "$output" == *"VERDICT=ok"* ]] || { echo "$s: $output"; return 1; }
        for key in jc jmin jmax s1 s2 s3 s4 h1 h2 h3 h4 i1; do
            grep -qx "$key" "$TEST_DIR/set.args" || { echo "$s: $key not sent"; return 1; }
        done
        for key in Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4 I1; do
            SHOW_MODE="alter:$key" _cand "$s"
            [[ "$output" == *"VERDICT=failed"* ]] || { echo "$s: a changed $key passed: $output"; return 1; }
        done
    done
}

@test "candidate probe: a record left by an earlier probe of this run stops a new one and stays for the cleanup" {
    local s
    make_cand_awg
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        { _src "$s" _awg31_module_probe; func_from "$s" awg20_candidate_support; } > "$TEST_DIR/cand.sh"
        rm -rf "$TEST_DIR/ifaces" "$TEST_DIR/set.args" "$TEST_DIR"/awg31probe.*
        run env PATH="$TEST_DIR/bin:$PATH" TMPDIR="$TEST_DIR" bash -c "source '$TEST_DIR/cand.sh'
            echo awgp\$\$x1 > \"$TEST_DIR/awg31probe.\$\$.iface\"
            AWG_Jc=3 AWG_Jmin=57 AWG_Jmax=128 AWG_S1=47 AWG_S2=57 AWG_S3=22 AWG_S4=20
            AWG_H1=1-2 AWG_H2=3-4 AWG_H3=5-6 AWG_H4=7-8 AWG_I1=''
            awg20_candidate_support; echo \"VERDICT=failed RC=\$?\"
            [ -e \"$TEST_DIR/awg31probe.\$\$.iface\" ] && echo RECORD_KEPT"
        [[ "$output" == *"VERDICT=failed RC=2"* && "$output" == *RECORD_KEPT* ]] || { echo "$s: $output"; return 1; }
        [ ! -e "$TEST_DIR/set.args" ] || { echo "$s: a set was sent despite the left record"; return 1; }
    done
}

# ============================================================ init writer, for real

_wr() {
    {
        echo 'log() { :; }; log_warn() { echo "WARN: $*"; }; log_error() { :; }; log_debug() { :; }'
        echo 'die() { echo "DIE: $*"; exit 1; }'
        echo '_install_temp_files=()'
        func_from "$1" _awg_save_init
        func_from "$1" safe_load_config
    } > "$TEST_DIR/wr.sh"
}

@test "init: the real writer persists the source and the reason, and the real loader reads them back" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        _wr "$s"
        rm -rf "$TEST_DIR/cfg"; mkdir -p "$TEST_DIR/cfg"
        run bash -c "source '$TEST_DIR/wr.sh'
            CONFIG_FILE='$TEST_DIR/cfg/awgsetup_cfg.init' PREV_AWG_PORT=''
            AWG_PROTOCOL=2.0 AWG_PROTOCOL_SOURCE=default AWG_PROTOCOL_FALLBACK=module_line2 AWG_Jc=3
            _awg_save_init
            unset AWG_PROTOCOL AWG_PROTOCOL_SOURCE AWG_PROTOCOL_FALLBACK
            safe_load_config \"\$CONFIG_FILE\"
            echo \"R=\$AWG_PROTOCOL/\$AWG_PROTOCOL_SOURCE/\$AWG_PROTOCOL_FALLBACK\""
        [ "$status" -eq 0 ] || { echo "$s: $output"; return 1; }
        [[ "$output" == *"R=2.0/default/module_line2"* ]] || { echo "$s: $output"; return 1; }
        [ "$(tail -n 1 "$TEST_DIR/cfg/awgsetup_cfg.init")" = "export AWG_PROTOCOL='2.0'" ] || { echo "$s: the marker is not the last line"; return 1; }
    done
}

@test "init: a failed rename dies, keeps the working init byte for byte and leaves no temp file" {
    local s
    printf '#!/bin/bash\nexit 1\n' > "$TEST_DIR/bin/mv"; chmod +x "$TEST_DIR/bin/mv"
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        _wr "$s"
        rm -rf "$TEST_DIR/cfg"; mkdir -p "$TEST_DIR/cfg"
        printf "export AWG_PROTOCOL='3.1'\nexport AWG_Jc=4\n" > "$TEST_DIR/cfg/awgsetup_cfg.init"
        cp "$TEST_DIR/cfg/awgsetup_cfg.init" "$TEST_DIR/ref.init"
        run env PATH="$TEST_DIR/bin:$PATH" bash -c "source '$TEST_DIR/wr.sh'
            CONFIG_FILE='$TEST_DIR/cfg/awgsetup_cfg.init' PREV_AWG_PORT=''
            AWG_PROTOCOL=2.0 AWG_PROTOCOL_SOURCE=default AWG_PROTOCOL_FALLBACK=kernel AWG_Jc=3
            _awg_save_init; echo SAVED"
        [[ "$output" == *"DIE:"* && "$output" != *SAVED* ]] || { echo "$s: $output"; return 1; }
        cmp "$TEST_DIR/ref.init" "$TEST_DIR/cfg/awgsetup_cfg.init" || { echo "$s: the working init changed"; return 1; }
        [ "$(ls -A "$TEST_DIR/cfg")" = "awgsetup_cfg.init" ] || { echo "$s: left: $(ls -A "$TEST_DIR/cfg")"; return 1; }
    done
}

# ============================================================ step 0 parameter block

_s0gen() {
    local s="$1" lib="$2" f
    {
        echo "source '$lib' >/dev/null 2>&1 || true"
        echo 'log() { :; }; log_warn() { echo "WARN: $*"; }; log_error() { :; }; log_debug() { :; }'
        echo 'die() { echo "DIE: $*" >&2; exit 1; }'
        for f in rand_range validate_jc_value validate_junk_size generate_awg_h_ranges generate_cps_i1 generate_awg_params _awg_fallback_params _awg_switch_params; do
            func_from "$s" "$f"
        done
        echo 'gen_slice() {'
        _body "$s" | sed -n '/^    if \[\[ -z "\${AWG_Jc:-}" \]\] || \[\[ "\${AWG_GEN_SWITCHED/,/^    case "\${NO_PREBUILT:-0}" in$/p' | sed '$d'
        echo '}'
    } > "$TEST_DIR/s0gen.sh"
    grep -q '_awg_fallback_params$' "$TEST_DIR/s0gen.sh" || { echo "slice not found in $s"; return 1; }
}

@test "step 0: the fallback of an unfinished install regenerates 2.0 with the saved J, preset and --no-cps, and tells nobody to regen" {
    local pair s lib
    for pair in "$INSTALL_RU $COMMON_RU" "$INSTALL_EN $COMMON_EN"; do
        read -r s lib <<< "$pair"
        _s0gen "$s" "$lib"
        run bash -c "source '$TEST_DIR/s0gen.sh'
            config_exists=1 AWG_PROTOCOL=2.0 AWG_AUTO_FALLBACK=1 AWG_GEN_SWITCHED=0 MANAGE_SCRIPT_PATH=/x
            AWG_Jc=0 AWG_Jmin=10 AWG_Jmax=20 AWG_PRESET=mobile NO_CPS=1 AWG_I1='<r 2>'
            AWG_H1=1 AWG_H2=2 AWG_H3=3 AWG_H4=4 AWG_S3=12 AWG_S4=12
            export AWG_CPA=32-128
            CLI_PRESET='' CLI_JC='' CLI_JMIN='' CLI_JMAX='' CLI_NO_CPS=0
            gen_slice
            echo \"J=\$AWG_Jc/\$AWG_Jmin/\$AWG_Jmax P=\$AWG_PRESET H1=\$AWG_H1 I1=[\$AWG_I1] CPA=\$(printenv AWG_CPA || echo unset) NOCPS=\$NO_CPS\""
        [ "$status" -eq 0 ] || { echo "$s: $output"; return 1; }
        [[ "$output" == *"J=0/10/20 P=mobile"* ]] || { echo "$s: J or preset lost: $output"; return 1; }
        [[ "$output" != *"H1=1 "* ]] || { echo "$s: the saved 3.1 set was kept: $output"; return 1; }
        [[ "$output" == *"I1=[] CPA=unset NOCPS=1"* ]] || { echo "$s: $output"; return 1; }
        [[ "$output" != *regen* ]] || { echo "$s: told someone to regen: $output"; return 1; }
    done
}
