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
    mkdir -p "$AWG_DIR" "$TEST_DIR/etc" "$TEST_DIR/bin"
    printf '#!/bin/bash\nexit "${IP_RC:-1}"\n' > "$TEST_DIR/bin/ip"
    chmod +x "$TEST_DIR/bin/ip"
    export IP_RC=1
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
    rm -rf "${AWG_DIR:?}" "${TEST_DIR:?}/etc"
    mkdir -p "$AWG_DIR" "$TEST_DIR/etc"
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
export IP_RC=0
export IP_RC=2
export IP_RC=255
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

@test "no ip command at all is not a live interface" {
    # awg-quick cannot bring awg0 up without ip either.
    _steps_0_to_5 4
    export IP_RC=127
    _state "$INSTALL_RU" 1
    [ "$output" = "2" ]
    _state "$INSTALL_EN" 1
    [ "$output" = "2" ]
}

@test "every trace of step 6 or a live interface makes an unfinished install existing" {
    local s t
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        while IFS= read -r t; do
            _fresh
            export IP_RC=1
            _steps_0_to_5 4
            eval "$t"
            _state "$s" 1
            [ "$status" -eq 0 ]
            [ "$output" = "1" ] || { echo "$s: trace [$t] gave $output"; return 1; }
        done < <(_traces)
    done
}

@test "a trace without an init file is an existing install, not a new one" {
    # The init may be lost while awg0.conf, keys or profiles stay. Treating that
    # as new would let a flag rewrite the generation under handed-out profiles.
    local s t
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        while IFS= read -r t; do
            _fresh
            export IP_RC=1
            eval "$t"
            _state "$s" 0
            [ "$output" = "1" ] || { echo "$s: trace [$t] without init gave $output"; return 1; }
        done < <(_traces)
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
        grep -q 'install_state=$(_awg_install_state "$config_exists")' <<< "$b" || { echo "$s: no classification"; return 1; }
        grep -q '_awg31_resolve_protocol "$install_state"' <<< "$b" || { echo "$s: resolver not given the state"; return 1; }
    done
}

@test "step 0 rewinds BEFORE the init with the new marker is written" {
    # The other order leaves a window: a crash after the new marker is saved
    # and before the rewind resumes without the flag on the NEW generation from
    # step 5, and a switch to 3.1 would skip the step 3 post gate.
    local s b rew save
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        b=$(_body "$s")
        rew=$(_line "$b" '^[[:space:]]*_awg_gen_switch_rewind$')
        # the heredoc line at column 0, not the sample inside an error text
        save=$(_line "$b" "^export AWG_PROTOCOL='")
        [ -n "$rew" ] && [ -n "$save" ] || { echo "$s: rewind=$rew save=$save"; return 1; }
        [ "$rew" -lt "$save" ] || { echo "$s: rewind after the init write"; return 1; }
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

@test "a 3.1 marker is no longer refused by step 0 itself" {
    # The environment gate decides now: until the path opens it answers
    # not_implemented_yet, and a step 0 die in front of it would also block the
    # resume of an unfinished 3.1 install.
    local s b
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        b=$(_body "$s")
        if grep -q '^[[:space:]]*if \[\[ "\$AWG_PROTOCOL" == "3.1" \]\]; then$' <<< "$b"; then
            echo "$s: step 0 still refuses a 3.1 marker"; return 1
        fi
    done
}
