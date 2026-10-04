#!/usr/bin/env bats
# An install that has not reached step 6 may still change its generation.
#
# Once step 6 has run, client profiles exist and may already be in other
# people's hands, so the generation is locked: changing it means reissuing every
# profile. Before step 6 nothing has been handed out, and refusing a switch there
# would force a full uninstall over an install that never produced a profile.
#
# The line between the two is _awg_install_state. It prints
#   0 - a new install (no init file and no trace of an earlier one);
#   1 - an existing install: the generation is locked;
#   2 - an unfinished install: init present, setup_state 1..6, and no trace of
#       step 6 or of a live interface.
# 🔴 Every doubt resolves to 1. A trace that cannot be read, an `ip` that fails
# for a reason other than "no such device", a keys directory that is not a
# directory: each of them means "maybe profiles exist", and a switch there would
# void them. Files that steps 0-5 legitimately leave in the work directory must
# NOT count, or an unfinished install could never switch at all.
#
# shellcheck disable=SC2154

INSTALL_RU="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
INSTALL_EN="$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"

func_from() { sed -n "/^$2()/,/^}/p" "$1"; }

setup() {
    TEST_DIR=$(mktemp -d)
    export AWG_DIR="$TEST_DIR/root-awg"
    export KEYS_DIR="$AWG_DIR/keys"
    export STATE_FILE="$AWG_DIR/setup_state"
    export CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init"
    export SERVER_CONF_FILE="$TEST_DIR/etc/awg0.conf"
    export SYS_NET_DIR="$TEST_DIR/sys-class-net"
    mkdir -p "$AWG_DIR" "$TEST_DIR/etc" "$TEST_DIR/bin" "$SYS_NET_DIR"
    # ip is the fallback when the sysfs directory is missing; it answers with
    # its own exit code and error text, as iproute2 does.
    printf '#!/bin/bash\n[[ -n "${IP_ERR:-}" ]] && echo "$IP_ERR" >&2\nexit "${IP_RC:-1}"\n' > "$TEST_DIR/bin/ip"
    chmod +x "$TEST_DIR/bin/ip"
    export IP_RC=1 IP_ERR='Device "awg0" does not exist.'
}

teardown() {
    [[ -n "${TEST_DIR:-}" ]] && rm -rf "$TEST_DIR"
}

# _state <script> <config_exists> : run _awg_install_state from that installer.
_state() {
    func_from "$1" _awg_install_state > "$TEST_DIR/fn.sh"
    run env PATH="$TEST_DIR/bin:$PATH" bash -c "source '$TEST_DIR/fn.sh'; _awg_install_state '$2'"
}

# Empty work and config directories again (the loops reuse one test dir).
_fresh() {
    rm -rf "${AWG_DIR:?}" "${TEST_DIR:?}/etc" "${SYS_NET_DIR:?}"
    mkdir -p "$AWG_DIR" "$TEST_DIR/etc" "$SYS_NET_DIR"
    export IP_RC=1 IP_ERR='Device "awg0" does not exist.'
}

# A work directory as steps 0-5 of an unfinished install leave it.
_steps_0_to_5() {
    : > "$CONFIG_FILE"
    echo "${1:-4}" > "$STATE_FILE"
    : > "$STATE_FILE.lock"
    : > "$AWG_DIR/install_amneziawg.log"
    : > "$AWG_DIR/.install.lock"
    : > "$AWG_DIR/awg_common.sh"
    : > "$AWG_DIR/manage_amneziawg.sh"
    : > "$AWG_DIR/boot-critical.pkgs"
    : > "$AWG_DIR/.boot_id_before_step2"
    : > "$AWG_DIR/ubuntu.sources.bak-2026-09-27"
    : > "$AWG_DIR/.ufw_enabled_by_installer"
}

# Each trace of step 6 or of a live install, as a command that creates it.
_traces() {
    cat << 'T'
: > "$SERVER_CONF_FILE"
: > "$SERVER_CONF_FILE.bak-2026-09-27_101010"
ln -s "$TEST_DIR/nowhere" "$SERVER_CONF_FILE"
: > "$AWG_DIR/server_private.key"
: > "$AWG_DIR/server_public.key"
: > "$AWG_DIR/server_hpk.key"
: > "$AWG_DIR/my_phone.conf"
: > "$AWG_DIR/my_phone.png"
: > "$AWG_DIR/my_phone.vpnuri"
mkdir -p "$KEYS_DIR" && : > "$KEYS_DIR/my_phone.private"
mkdir -p "$KEYS_DIR" && : > "$KEYS_DIR/.half-written"
mkdir -p "$KEYS_DIR" && ln -s "$TEST_DIR/nowhere" "$KEYS_DIR/dangling"
: > "$KEYS_DIR"
mkdir -p "$TEST_DIR/empty-elsewhere" && ln -s "$TEST_DIR/empty-elsewhere" "$KEYS_DIR"
mkdir -p "$SYS_NET_DIR/awg0"
ln -s "$TEST_DIR/nowhere" "$SYS_NET_DIR/awg0"
export IP_RC=0 IP_ERR=
export IP_RC=1 IP_ERR="Cannot open netlink socket: Permission denied"
rm -rf "$SYS_NET_DIR"; export IP_RC=0 IP_ERR=
rm -rf "$SYS_NET_DIR"; export IP_RC=1 IP_ERR="Cannot open netlink socket: Permission denied"
rm -rf "$SYS_NET_DIR"; export IP_RC=127 IP_ERR="ip: command not found"
rm -rf "$SYS_NET_DIR"; export IP_RC=2 IP_ERR=
rm -rf "$SYS_NET_DIR"; export IP_RC=255 IP_ERR=
rm -rf "$SYS_NET_DIR"; export IP_RC=2 IP_ERR='Device "awg0" does not exist.'
T
}

@test "a clean new install is state 0" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        _state "$s" 0
        [ "$status" -eq 0 ]
        [ "$output" = "0" ] || { echo "$s: $output"; return 1; }
    done
}

@test "steps 0-5 alone make an unfinished install at every step from 1 to 6" {
    local s n
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        for n in 1 2 3 4 5 6; do
            _steps_0_to_5 "$n"
            _state "$s" 1
            [ "$status" -eq 0 ]
            [ "$output" = "2" ] || { echo "$s step $n: $output"; return 1; }
        done
    done
}

@test "an empty keys directory is not a trace (step 6 creates it before any key)" {
    _steps_0_to_5 4
    mkdir -p "$KEYS_DIR"
    _state "$INSTALL_RU" 1
    [ "$output" = "2" ]
    _state "$INSTALL_EN" 1
    [ "$output" = "2" ]
}

@test "sysfs without awg0 and ip's own no-such-device answer together rule awg0 out" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        _fresh
        _steps_0_to_5 4
        _state "$s" 1
        [ "$output" = "2" ] || { echo "$s: $output"; return 1; }
    done
}

@test "without the sysfs directory ip's own no-such-device answer is enough" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        _fresh
        _steps_0_to_5 4
        rm -rf "$SYS_NET_DIR"
        _state "$s" 1
        [ "$output" = "2" ] || { echo "$s: $output"; return 1; }
    done
}

@test "every trace of step 6 or a live interface makes an unfinished install existing" {
    local s t
    local n=0
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        while IFS= read -r t; do
            _fresh
            _steps_0_to_5 4
            eval "$t"
            _state "$s" 1
            [ "$status" -eq 0 ]
            [ "$output" = "1" ] || { echo "$s: trace [$t] gave $output"; return 1; }
            n=$((n + 1))
        done < <(_traces)
    done
    # an empty trace list would pass every loop above
    [ "$n" -eq $(( 2 * $(_traces | wc -l) )) ] && [ "$n" -ge 40 ] || { echo "ran $n trace cases"; return 1; }
}

@test "a trace without an init file is an existing install, not a new one" {
    # The init may be lost while awg0.conf, keys or profiles stay. Treating that
    # as new would let a flag rewrite the generation under handed-out profiles.
    local s t n=0
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        while IFS= read -r t; do
            _fresh
            eval "$t"
            _state "$s" 0
            [ "$output" = "1" ] || { echo "$s: trace [$t] without init gave $output"; return 1; }
            n=$((n + 1))
        done < <(_traces)
    done
    [ "$n" -ge 40 ] || { echo "ran $n trace cases"; return 1; }
}

@test "a state file without an init is an existing install, not a new one" {
    # An install whose init was lost at step 5 would otherwise go on as new:
    # a flag would set the generation, nothing would rewind, and the loop would
    # resume at step 5 past the step 3 gate.
    local s v
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        for v in 5 3 1 99 garbage ""; do
            _fresh
            printf '%s\n' "$v" > "$STATE_FILE"
            _state "$s" 0
            [ "$output" = "1" ] || { echo "$s: state [$v] without init gave $output"; return 1; }
        done
    done
}

@test "a keys directory that cannot be listed counts as a trace" {
    _steps_0_to_5 4
    mkdir -p "$KEYS_DIR"
    printf '#!/bin/bash\nexit 1\n' > "$TEST_DIR/bin/find"
    chmod +x "$TEST_DIR/bin/find"
    _state "$INSTALL_RU" 1
    [ "$output" = "1" ]
    _state "$INSTALL_EN" 1
    [ "$output" = "1" ]
}

@test "a finished or unknown step is an existing install" {
    local s v
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        for v in 7 99 0 12 3x " 4" ""; do
            _steps_0_to_5 4
            printf '%s\n' "$v" > "$STATE_FILE"
            _state "$s" 1
            [ "$output" = "1" ] || { echo "$s: state [$v] gave $output"; return 1; }
        done
        rm -f "$STATE_FILE"
        _state "$s" 1
        [ "$output" = "1" ] || { echo "$s: no state file gave $output"; return 1; }
    done
}

@test "a malformed argument is an error, not a state" {
    local s a
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        for a in "" 2 yes; do
            _state "$s" "$a"
            [ "$status" -ne 0 ]
            [ -z "$output" ]
        done
    done
}

# ------------------------------------------------------------ rewind to step 3

_rewind() {
    {
        echo 'log() { echo "LOG: $*"; }'
        echo 'log_warn() { echo "WARN: $*"; }'
        echo 'update_state() { echo "STATE $1"; echo "$1" > "$STATE_FILE"; }'
        func_from "$1" _awg_gen_switch_rewind
    } > "$TEST_DIR/fn.sh"
    run bash -c "source '$TEST_DIR/fn.sh'; _awg_gen_switch_rewind"
}

@test "a switch after step 3 rewinds to step 3" {
    local s n
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        for n in 4 5 6; do
            echo "$n" > "$STATE_FILE"
            AWG_GEN_SWITCHED=1 _rewind "$s"
            [ "$status" -eq 0 ]
            [[ "$output" == *"STATE 3"* ]] || { echo "$s from $n: $output"; return 1; }
            [ "$(cat "$STATE_FILE")" = "3" ]
        done
    done
}

@test "a switch at step 3 or earlier keeps the step (steps 1-2 must still run)" {
    local s n
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        for n in 1 2 3; do
            echo "$n" > "$STATE_FILE"
            AWG_GEN_SWITCHED=1 _rewind "$s"
            [ "$status" -eq 0 ]
            [[ "$output" != *"STATE"* ]] || { echo "$s at $n: $output"; return 1; }
            [ "$(cat "$STATE_FILE")" = "$n" ]
        done
    done
}

@test "without a switch nothing is rewound" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        echo 5 > "$STATE_FILE"
        AWG_GEN_SWITCHED=0 _rewind "$s"
        [ "$status" -eq 0 ]
        [[ "$output" != *"STATE"* ]]
        [ "$(cat "$STATE_FILE")" = "5" ]
    done
}

# ------------------------------------------------------------ preset on a switch

_switch_params() {
    {
        echo 'generate_awg_params() { echo "PRESET=${CLI_PRESET:-<unset>}"; }'
        func_from "$1" _awg_switch_params
    } > "$TEST_DIR/fn.sh"
    run bash -c "source '$TEST_DIR/fn.sh'; _awg_switch_params; echo \"AFTER=[\${CLI_PRESET:-}]\""
}

@test "a switch regenerates with the preset the install was made with" {
    # generate_awg_params reads only CLI_PRESET and falls back to default, so a
    # switch after --preset=mobile would silently land on default without this.
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        CLI_PRESET="" AWG_PRESET="mobile" _switch_params "$s"
        [[ "$output" == *"PRESET=mobile"* ]] || { echo "$s: $output"; return 1; }
        # the saved preset is lent to the call, not written into CLI_PRESET:
        # the --no-cps logic below reads CLI_PRESET as "the operator asked"
        [[ "$output" == *"AFTER=[]"* ]] || { echo "$s leaked CLI_PRESET: $output"; return 1; }
    done
}

@test "an explicit --preset wins over the saved one on a switch" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        CLI_PRESET="default" AWG_PRESET="mobile" _switch_params "$s"
        [[ "$output" == *"PRESET=default"* ]] || { echo "$s: $output"; return 1; }
        CLI_PRESET="mobile" AWG_PRESET="default" _switch_params "$s"
        [[ "$output" == *"PRESET=mobile"* ]] || { echo "$s: $output"; return 1; }
    done
}

@test "no saved preset falls back to default" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        CLI_PRESET="" AWG_PRESET="" _switch_params "$s"
        [[ "$output" == *"PRESET=default"* ]] || { echo "$s: $output"; return 1; }
    done
}

# ------------------------------------------------------------ wiring in step 0

_body() { sed -n '/^initialize_setup() {/,/^}/p' "$1"; }
_line() { grep -n -m1 -- "$2" <<< "$1" | cut -d: -f1; }

@test "step 0 classifies the install and hands the state to the resolver" {
    local s b
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        b=$(_body "$s")
        [ -n "$b" ] || { echo "$s: no initialize_setup"; return 1; }
        grep -q '^[[:space:]]*install_state=$(_awg_install_state "$config_exists")' <<< "$b" || { echo "$s: no classification"; return 1; }
        # a plain call, not inside $( ): the resolver's globals must survive
        grep -q '^[[:space:]]*_awg31_resolve_protocol "$install_state"$' <<< "$b" || { echo "$s: resolver not given the state"; return 1; }
    done
}

@test "step 0 rewinds BEFORE the init with the new marker is written and before the step is read" {
    # The other order would leave a window: a crash after the new marker is
    # saved and before the rewind resumes without the flag on the NEW
    # generation from the saved step (4-6), and a switch to 3.1 would skip the
    # step 3 post gate. The step the loop runs is read from the state file, so
    # the rewind must also come before that read, or this very run goes on
    # from the old step.
    local s b rew save cur
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        b=$(_body "$s")
        rew=$(_line "$b" '^[[:space:]]*_awg_gen_switch_rewind$')
        # the init is written by _awg_save_init, called from step 0; the
        # marker line lives in that writer, not in the body
        save=$(_line "$b" '^[[:space:]]*_awg_save_init$')
        sed -n '/^_awg_save_init() {/,/^}/p' "$s" | grep -q "^export AWG_PROTOCOL='" \
            || { echo "$s: the writer does not write the marker"; return 1; }
        cur=$(_line "$b" 'current_step=$(cat "$STATE_FILE")')
        [ -n "$rew" ] && [ -n "$save" ] && [ -n "$cur" ] || { echo "$s: rewind=$rew save=$save read=$cur"; return 1; }
        [ "$rew" -lt "$save" ] || { echo "$s: rewind after the init write"; return 1; }
        [ "$rew" -lt "$cur" ] || { echo "$s: rewind after the step is read"; return 1; }
    done
}

@test "a switch forces the full parameter set through the preset-keeping call" {
    local s b
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        b=$(_body "$s")
        grep -F '[[ -z "${AWG_Jc:-}" ]]' <<< "$b" | grep -qF '[[ "${AWG_GEN_SWITCHED:-0}" -eq 1 ]]' \
            || { echo "$s: the switch is not part of the regeneration condition"; return 1; }
        grep -q '^[[:space:]]*_awg_switch_params$' <<< "$b" || { echo "$s: switch does not use _awg_switch_params"; return 1; }
    done
}

@test "a switch does not tell anyone to reissue clients that do not exist" {
    # Both "reissue every client" warnings (a regenerated set, --no-cps) are
    # about handed-out profiles; a switch happens before step 6, so there are
    # none, and the switch has its own warning.
    local s b
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        b=$(_body "$s")
        grep -F 'if [[ "$config_exists" -eq 1 && -n "${AWG_Jc:-}"' <<< "$b" | grep -qF 'AWG_GEN_SWITCHED' \
            || { echo "$s: the regeneration warning fires on a switch"; return 1; }
        grep -F 'if [[ -n "${AWG_I1:-}" && "$config_exists" -eq 1' <<< "$b" | grep -qF 'AWG_GEN_SWITCHED' \
            || { echo "$s: the --no-cps warning fires on a switch"; return 1; }
    done
}

@test "the saved preset a switch uses comes from the init, not from the environment" {
    # AWG_PRESET=mobile in the environment would otherwise stand in for an init
    # that lacks the line, and the switch would regenerate on the wrong preset.
    local s b reset load
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        b=$(_body "$s")
        reset=$(_line "$b" '^[[:space:]]*AWG_PRESET=""$')
        load=$(_line "$b" 'safe_load_config "$CONFIG_FILE"')
        [ -n "$reset" ] && [ -n "$load" ] || { echo "$s: reset=$reset load=$load"; return 1; }
        [ "$reset" -lt "$load" ] || { echo "$s: the reset comes after the load"; return 1; }
    done
}

@test "a 3.1 marker is no longer refused by step 0 itself" {
    # The environment gate decides now (see the behavioural resume case below).
    local s b
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        b=$(_body "$s")
        [ -n "$b" ] || { echo "$s: no initialize_setup"; return 1; }
        if grep -q 'AWG_PROTOCOL" == "3.1"' <<< "$b"; then
            echo "$s: step 0 still tests the 3.1 marker itself"; return 1
        fi
    done
}

# ------------------------------------------------------------ step 0, end to end
# The real lines of initialize_setup from reading the marker to the rewind, run
# as they are: the classification feeds the resolver, the switch mark survives
# into the rewind, and the refusals leave the state file alone.

_step0() {
    local s="$1" fn
    {
        echo 'die() { echo "DIE: $*" >&2; exit 1; }'
        echo 'log() { echo "LOG: $*"; }'
        echo 'log_warn() { echo "WARN: $*"; }'
        echo 'update_state() { echo "$1" > "$STATE_FILE"; }'
        echo 'SCRIPT_VERSION="0.0.0-test"'
        echo 'PROTOCOL_DEFAULT="2.0"'
        echo 'awg31_environment_blocker() { echo "$1" >> "$GATE_LOG"; printf "%s" "${BLOCKER_CODE-}"; return ${GATE_RC:-0}; }'
        grep -E '^AWG31_FALLBACK_(PRE|POST)_CODES=' "$s"
        for fn in awg_installed_protocol _awg_install_state _awg31_host_arch _awg31_blocker_message _awg31_code_in _awg31_fallback_reason _awg31_announce_fallback _awg31_resolve_protocol _awg_gen_switch_rewind; do
            func_from "$s" "$fn"
        done
        echo 'step0_slice() {'
        echo '    local config_exists=0'
        echo '    AWG_PROTOCOL=""'
        echo '    if [[ -f "$CONFIG_FILE" ]]; then config_exists=1; source "$CONFIG_FILE"; fi'
        _body "$s" | sed -n '/^    local _proto_raw=/,/^    _awg_gen_switch_rewind$/p'
        echo '}'
        echo 'step0_slice'
        echo 'echo "PROTO=$AWG_PROTOCOL SW=$AWG_GEN_SWITCHED STATE=$(cat "$STATE_FILE")"'
    } > "$TEST_DIR/step0.sh"
    run env PATH="$TEST_DIR/bin:$PATH" bash "$TEST_DIR/step0.sh"
}

# _begun <generation> <step> : an install stopped before step 6.
_begun() {
    _fresh
    printf "export AWG_PROTOCOL='%s'\n" "$1" > "$CONFIG_FILE"
    echo "$2" > "$STATE_FILE"
    export GATE_LOG="$TEST_DIR/gate.log"
    : > "$GATE_LOG"
}

@test "end to end: 2.0 at step 5 switched to 3.1 rewinds to step 3 after the gate" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        _begun 2.0 5
        CLI_PROTOCOL=3.1 CLI_PROTOCOL_SET=1 BLOCKER_CODE="" _step0 "$s"
        [ "$status" -eq 0 ] || { echo "$s: $output"; return 1; }
        [[ "$output" == *"PROTO=3.1 SW=1 STATE=3"* ]] || { echo "$s: $output"; return 1; }
        [[ "$output" == *"WARN:"* ]]
        [ "$(cat "$GATE_LOG")" = "pre" ]
    done
}

@test "end to end: the resume of that install without the flag keeps 3.1 and meets the gate" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        _begun 3.1 3
        # the init carries no AWG_PROTOCOL_SOURCE: no fallback, the gate refuses
        CLI_PROTOCOL="" CLI_PROTOCOL_SET=0 BLOCKER_CODE="kernel" _step0 "$s"
        [ "$status" -eq 1 ]
        [[ "$output" == *"DIE:"*"--protocol=2.0"* ]] || { echo "$s: $output"; return 1; }
        [ "$(cat "$GATE_LOG")" = "pre" ]
        [ "$(cat "$STATE_FILE")" = "3" ]
    done
}

@test "end to end: 3.1 at step 5 switched to 2.0 rewinds without the gate" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        _begun 3.1 5
        CLI_PROTOCOL=2.0 CLI_PROTOCOL_SET=1 _step0 "$s"
        [ "$status" -eq 0 ] || { echo "$s: $output"; return 1; }
        [[ "$output" == *"PROTO=2.0 SW=1 STATE=3"* ]] || { echo "$s: $output"; return 1; }
        [ ! -s "$GATE_LOG" ]
    done
}

@test "end to end: a switch at step 2 keeps step 2" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        _begun 3.1 2
        CLI_PROTOCOL=2.0 CLI_PROTOCOL_SET=1 _step0 "$s"
        [ "$status" -eq 0 ]
        [[ "$output" == *"PROTO=2.0 SW=1 STATE=2"* ]] || { echo "$s: $output"; return 1; }
    done
}

@test "end to end: a refused switch leaves the step alone" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        _begun 2.0 5
        CLI_PROTOCOL=3.1 CLI_PROTOCOL_SET=1 BLOCKER_CODE="kernel" _step0 "$s"
        [ "$status" -eq 1 ]
        [ "$(cat "$STATE_FILE")" = "5" ] || { echo "$s: state moved on a refusal"; return 1; }
        [[ "$output" != *"WARN:"* ]]
    done
}

@test "end to end: a server config makes the same switch a refusal with the uninstall path" {
    local s
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        _begun 2.0 5
        : > "$SERVER_CONF_FILE"
        CLI_PROTOCOL=3.1 CLI_PROTOCOL_SET=1 BLOCKER_CODE="" _step0 "$s"
        [ "$status" -eq 1 ]
        [[ "$output" == *"--uninstall"* ]] || { echo "$s: $output"; return 1; }
        [ "$(cat "$STATE_FILE")" = "5" ]
    done
}
