#!/usr/bin/env bats
# --protocol: the flag, the generation it settles, and the two call sites of the
# environment gate.
#
# The gate itself is covered by test_awg31_environment_gate.bats. This file
# covers what turns that gate from a defined function into a defence: WHO calls
# it, WHEN, and what the person is told when it refuses.
#
# Four properties, each with a way to go wrong that has a name:
#
#   1. THE FLAG DOES NOT CHANGE AN EXISTING INSTALL. Changing a generation in
#      place means reissuing every client profile and handing them out again.
#      A flag that did it in passing would void other people's configs without
#      asking. The marker of "existing" is the config file, not a running
#      service, so --force lands here too.
#   2. THE GATE IS CALLED ONLY WHEN 3.1 IS ASKED FOR. Calling it on an ordinary
#      2.0 install would run an external probe and could refuse someone who
#      never wanted the third line.
#   3. EVERY REASON CODE HAS ITS OWN TEXT AND ITS OWN WAY OUT. One shared "3.1
#      is unavailable" would send a Debian 12 owner and an ARM owner into the
#      same dead end. The texts are asserted to be pairwise different, because
#      that is the property that decays quietly over a year of edits.
#   4. AN UNKNOWN CODE IS NOT PERMISSION. A reason code added later without a
#      text must not turn into an empty refusal with no explanation.
#
# 🔴 One test here is DESIGNED TO GO RED IN PHASE 5: the one pinning the
# new-install default at 2.0. Flipping the default is the moment someone must
# read what the marker means for installs that predate it, so the test is a
# checkpoint, not an obstacle.
#
# shellcheck disable=SC2154

load test_helper

INSTALL_RU="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
INSTALL_EN="$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"

# Function body of $2 from script $1, without running the script.
func_from() { sed -n "/^$2()/,/^}/p" "$1"; }

# The phase default as the installer actually declares it, not as this file
# remembers it.
declared_default() {
    sed -n 's/^PROTOCOL_DEFAULT="\(.*\)"$/\1/p' "${1:-$INSTALL_RU}"
}

# Build a sourceable file with the functions under test plus the seams a unit
# test needs: die that aborts, logs that are readable, and a gate stub that
# records the stage it was called with.
build_harness() {
    local script="${1:-$INSTALL_RU}"
    {
        echo 'die() { echo "DIE: $*" >&2; exit 1; }'
        echo 'log() { echo "LOG: $*"; }'
        echo 'log_warn() { echo "WARN: $*"; }'
        echo 'SCRIPT_VERSION="0.0.0-test"'
        echo 'CONFIG_FILE="/tmp/awgsetup_cfg.init"'
        echo "PROTOCOL_DEFAULT=\"$(declared_default "$script")\""
        func_from "$script" _awg31_host_arch
        func_from "$script" _awg31_blocker_message
        func_from "$script" _awg31_resolve_protocol
        # The gate is stubbed here on purpose: its own behaviour is covered in
        # the neighbouring file, and mixing the two would make a failure here
        # ambiguous between "wrong call site" and "wrong verdict".
        echo 'awg31_environment_blocker() { echo "$1" >> "$GATE_LOG"; printf "%s" "${BLOCKER_CODE-}"; return ${GATE_RC:-0}; }'
    } > "$TEST_DIR/harness.sh"
    export GATE_LOG="$TEST_DIR/gate.log"
    : > "$GATE_LOG"
    # The runner is written HERE, not inside run_resolve: a test that invokes it
    # directly would otherwise run a missing file, both variants would fail
    # identically, and a comparison between them would pass on two error
    # messages. That is exactly how this file first went green by accident.
    cat > "$TEST_DIR/run.sh" <<'RUNNER'
source "$HARNESS"
_awg31_resolve_protocol "$1"
echo "RESULT: $AWG_PROTOCOL"
RUNNER
}

# Run _awg31_resolve_protocol and print the generation it settled on.
# Arg $1: config_exists (0 or 1). Env: CLI_PROTOCOL, AWG_PROTOCOL, BLOCKER_CODE.
run_resolve() {
    HARNESS="$TEST_DIR/harness.sh" run bash "$TEST_DIR/run.sh" "$1"
}

# Parse a command line with the installer's own argument loop.
run_argparse() {
    local script="${1:-$INSTALL_RU}"; shift
    sed -n '/^while \[\[ \$# -gt 0 \]\]; do$/,/^done$/p' "$script" > "$TEST_DIR/args.sh"
    {
        echo 'CLI_PROTOCOL=""; CLI_PROTOCOL_SET=0; CLI_MOBILE=0; AUTO_YES=0; HELP=0; HELP_EXIT_RC=0'
        echo 'UNINSTALL=0; DIAGNOSTIC=0; VERBOSE=0; NO_COLOR=0; NO_TWEAKS=0; NO_CPS=0'
        echo 'KEEP_PACKAGES=""; FORCE_REINSTALL=0'
        cat "$TEST_DIR/args.sh"
        echo 'echo "PROTOCOL=[$CLI_PROTOCOL] SET=$CLI_PROTOCOL_SET YES=$AUTO_YES HELP=$HELP"'
    } > "$TEST_DIR/argrun.sh"
    run bash "$TEST_DIR/argrun.sh" "$@"
}

# ------------------------------------------------------- reason code messages

@test "every reason code produces a non-empty message" {
    build_harness
    local code
    for code in kernel arm arch_unsupported arch_unknown tools_old \
                not_implemented_yet internal_error; do
        run bash -c "source '$TEST_DIR/harness.sh'; _awg31_blocker_message '$code'"
        [ "$status" -eq 0 ]
        [ -n "$output" ]
    done
}

@test "the messages are pairwise different" {
    build_harness
    local code out
    : > "$TEST_DIR/msgs"
    for code in kernel arm arch_unsupported arch_unknown tools_old \
                not_implemented_yet internal_error; do
        out=$(bash -c "source '$TEST_DIR/harness.sh'; _awg31_blocker_message '$code'")
        echo "$out" >> "$TEST_DIR/msgs"
    done
    [ "$(sort -u "$TEST_DIR/msgs" | wc -l)" -eq 7 ]
}

@test "every message names the way out" {
    build_harness
    local code out
    for code in kernel arm arch_unsupported arch_unknown tools_old \
                not_implemented_yet internal_error nonsense_code; do
        out=$(bash -c "source '$TEST_DIR/harness.sh'; _awg31_blocker_message '$code'")
        [[ "$out" == *"--protocol=2.0"* ]] || {
            echo "code '$code' does not name --protocol=2.0: $out"; return 1; }
    done
}

@test "the kernel message names the threshold, not just the refusal" {
    build_harness
    run bash -c "source '$TEST_DIR/harness.sh'; _awg31_blocker_message kernel"
    [[ "$output" == *"6.7"* ]]
}

@test "tools_old is the only reason presented as fixable by an upgrade" {
    build_harness
    run bash -c "source '$TEST_DIR/harness.sh'; _awg31_blocker_message tools_old"
    [[ "$output" == *"amneziawg-tools"* ]]
    run bash -c "source '$TEST_DIR/harness.sh'; _awg31_blocker_message arm"
    [[ "$output" != *"amneziawg-tools"* ]]
}

@test "not_implemented_yet says the machine is not at fault" {
    build_harness
    run bash -c "source '$TEST_DIR/harness.sh'; _awg31_blocker_message not_implemented_yet"
    [[ "$output" == *"0.0.0-test"* ]]
}

@test "an unknown reason code refuses and repeats the code" {
    build_harness
    run bash -c "source '$TEST_DIR/harness.sh'; _awg31_blocker_message future_code"
    [ -n "$output" ]
    [[ "$output" == *"future_code"* ]]
}

# ---------------------------------------------------------- generation choice

@test "a new install without the flag takes the phase default" {
    build_harness
    # AWG_PROTOCOL starts at a value the default is NOT, so the assignment has
    # to happen for this to pass. With a 2.0 starting value the test was green
    # even with the assignment deleted - caught by external review 9 sep 2026.
    CLI_PROTOCOL="" CLI_PROTOCOL_SET=0 AWG_PROTOCOL="9.9" run_resolve 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"RESULT: $(declared_default)"* ]]
}

@test "the phase default is still 2.0 (goes red on purpose when phase 5 flips it)" {
    [ "$(declared_default "$INSTALL_RU")" = "2.0" ]
    [ "$(declared_default "$INSTALL_EN")" = "2.0" ]
}

@test "a new install with --protocol=2.0 does not call the gate" {
    build_harness
    CLI_PROTOCOL="2.0" CLI_PROTOCOL_SET=1 AWG_PROTOCOL="2.0" run_resolve 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"RESULT: 2.0"* ]]
    [ ! -s "$GATE_LOG" ]
}

@test "a new install with --protocol=3.1 calls the gate at stage pre" {
    build_harness
    CLI_PROTOCOL="3.1" CLI_PROTOCOL_SET=1 AWG_PROTOCOL="2.0" BLOCKER_CODE="" run_resolve 0
    [ "$status" -eq 0 ]
    [ "$(cat "$GATE_LOG")" = "pre" ]
}

@test "a blocked environment ends the install with that code's message" {
    build_harness
    CLI_PROTOCOL="3.1" CLI_PROTOCOL_SET=1 AWG_PROTOCOL="2.0" BLOCKER_CODE="kernel" run_resolve 0
    [ "$status" -eq 1 ]
    [[ "$output" == *"DIE:"* ]]
    [[ "$output" == *"6.7"* ]]
    [[ "$output" == *"--protocol=2.0"* ]]
}

@test "each blocking code produces its own refusal, not a shared one" {
    build_harness
    local code out kernel_out arm_out
    kernel_out=$(CLI_PROTOCOL="3.1" CLI_PROTOCOL_SET=1 AWG_PROTOCOL="2.0" BLOCKER_CODE="kernel" \
        HARNESS="$TEST_DIR/harness.sh" bash "$TEST_DIR/run.sh" 0 2>&1 || true)
    arm_out=$(CLI_PROTOCOL="3.1" CLI_PROTOCOL_SET=1 AWG_PROTOCOL="2.0" BLOCKER_CODE="arm" \
        HARNESS="$TEST_DIR/harness.sh" bash "$TEST_DIR/run.sh" 0 2>&1 || true)
    [[ "$kernel_out" == *"6.7"* ]]
    [[ "$arm_out" == *"ARM"* ]]
    [ "$kernel_out" != "$arm_out" ]
}

@test "on an existing install a different generation ends the install" {
    build_harness
    # Carrying on with the old generation would hand the operator something OTHER
    # than what they asked for, and the warning would drown in a long install log.
    # The refusal names both generations so the message is actionable on its own.
    CLI_PROTOCOL="3.1" CLI_PROTOCOL_SET=1 AWG_PROTOCOL="2.0" run_resolve 1
    [ "$status" -eq 1 ]
    [[ "$output" == *"DIE:"* ]]
    [[ "$output" == *"3.1"* ]]
    [[ "$output" == *"2.0"* ]]
}

@test "on an existing install the gate is not called at all" {
    build_harness
    CLI_PROTOCOL="3.1" CLI_PROTOCOL_SET=1 AWG_PROTOCOL="2.0" run_resolve 1
    [ ! -s "$GATE_LOG" ]
}

@test "the refusal on an existing install never rewrites the marker" {
    build_harness
    # The marker is what says which generation the running server actually is.
    # A refusal that changed it on the way out would be worse than no refusal.
    CLI_PROTOCOL="3.1" CLI_PROTOCOL_SET=1 AWG_PROTOCOL="2.0" run_resolve 1
    [[ "$output" != *"RESULT: 3.1"* ]]
}

@test "a flag matching the existing generation is accepted quietly" {
    build_harness
    CLI_PROTOCOL="2.0" CLI_PROTOCOL_SET=1 AWG_PROTOCOL="2.0" run_resolve 1
    [ "$status" -eq 0 ]
    [[ "$output" != *"WARN:"* ]]
    [[ "$output" == *"RESULT: 2.0"* ]]
}

@test "an invalid protocol value ends the install" {
    build_harness
    CLI_PROTOCOL="3" CLI_PROTOCOL_SET=1 AWG_PROTOCOL="2.0" run_resolve 0
    [ "$status" -eq 1 ]
    [[ "$output" == *"DIE:"* ]]
    [[ "$output" == *"2.0"* ]]
}

@test "a supplied but empty protocol value is refused, not ignored" {
    build_harness
    # --protocol= and a trailing --protocol both land here. Before the fix the
    # resolver only looked at whether the VALUE was non-empty, so this case fell
    # through to the default without a word.
    CLI_PROTOCOL="" CLI_PROTOCOL_SET=1 AWG_PROTOCOL="2.0" run_resolve 0
    [ "$status" -eq 1 ]
    [[ "$output" == *"DIE:"* ]]
}

@test "a whitespace protocol value is refused too" {
    build_harness
    CLI_PROTOCOL=" " CLI_PROTOCOL_SET=1 AWG_PROTOCOL="2.0" run_resolve 0
    [ "$status" -eq 1 ]
    [[ "$output" == *"DIE:"* ]]
}

@test "a gate that cannot answer stops the install instead of allowing it" {
    build_harness
    # Empty output means "3.1 is allowed". A call that failed prints nothing
    # either, so the exit status has to be read separately - otherwise a crashed
    # gate reads as a yes. External review 9 sep 2026.
    CLI_PROTOCOL="3.1" CLI_PROTOCOL_SET=1 AWG_PROTOCOL="2.0" BLOCKER_CODE="" GATE_RC=1 run_resolve 0
    [ "$status" -eq 1 ]
    [[ "$output" == *"DIE:"* ]]
    [[ "$output" == *"--protocol=2.0"* ]]
}

@test "a reason code this version does not know still stops the install" {
    build_harness
    CLI_PROTOCOL="3.1" CLI_PROTOCOL_SET=1 AWG_PROTOCOL="2.0" BLOCKER_CODE="future_code" run_resolve 0
    [ "$status" -eq 1 ]
    [[ "$output" == *"future_code"* ]]
}

@test "a malformed existing-install flag is an internal error, not permission" {
    build_harness
    CLI_PROTOCOL="3.1" CLI_PROTOCOL_SET=1 AWG_PROTOCOL="2.0" run_resolve ""
    [ "$status" -eq 1 ]
    [[ "$output" == *"DIE:"* ]]
    [ ! -s "$GATE_LOG" ]
}

# -------------------------------------------------------- argument parsing

@test "--protocol=VALUE is parsed" {
    build_harness
    run_argparse "$INSTALL_RU" --protocol=3.1
    [[ "$output" == *"PROTOCOL=[3.1]"* ]]
}

@test "--protocol VALUE with a space is parsed too" {
    build_harness
    run_argparse "$INSTALL_RU" --protocol 3.1
    [[ "$output" == *"PROTOCOL=[3.1]"* ]]
}

@test "the space form does not swallow the next flag" {
    build_harness
    run_argparse "$INSTALL_RU" --protocol 2.0 --yes
    [[ "$output" == *"PROTOCOL=[2.0]"* ]]
    [[ "$output" == *"YES=1"* ]]
}

@test "--protocol as the last argument is recorded as supplied but empty" {
    build_harness
    run_argparse "$INSTALL_RU" --protocol
    [[ "$output" == *"PROTOCOL=[] SET=1"* ]]
}

@test "--protocol= is recorded as supplied but empty, not as absent" {
    build_harness
    run_argparse "$INSTALL_RU" --protocol=
    [[ "$output" == *"PROTOCOL=[] SET=1"* ]]
}

@test "--protocol --yes does not eat the next flag" {
    build_harness
    run_argparse "$INSTALL_RU" --protocol --yes
    [[ "$output" == *"PROTOCOL=[] SET=1"* ]]
    [[ "$output" == *"YES=1"* ]]
}

@test "a repeated --protocol with no value discards the earlier one" {
    build_harness
    # Without clearing the value on entry the second, valueless flag would
    # silently keep the first one and the install would proceed on it.
    run_argparse "$INSTALL_RU" --protocol=2.0 --protocol --yes
    [[ "$output" == *"PROTOCOL=[] SET=1"* ]]
    [[ "$output" == *"YES=1"* ]]
}

@test "the English installer discards it the same way" {
    build_harness "$INSTALL_EN"
    run_argparse "$INSTALL_EN" --protocol=2.0 --protocol
    [[ "$output" == *"PROTOCOL=[] SET=1"* ]]
}

@test "no flag at all leaves the supplied marker clear" {
    build_harness
    run_argparse "$INSTALL_RU" --yes
    [[ "$output" == *"PROTOCOL=[] SET=0"* ]]
}

@test "the English installer parses the flag identically" {
    build_harness "$INSTALL_EN"
    run_argparse "$INSTALL_EN" --protocol 3.1
    [[ "$output" == *"PROTOCOL=[3.1]"* ]]
}

# ------------------------------------------------------- the step 3 call site

# 🔴 This is the branch that comes alive in phase 3. Today a 3.1 marker never
# reaches step 3, so nothing but this test proves the call site exists and is
# guarded by the marker. Deleting the call makes the first test red; removing
# the guard makes the second one red.
run_step3() {
    local script="${1:-$INSTALL_RU}"
    {
        echo 'die() { echo "DIE: $*" >&2; exit 1; }'
        echo 'log() { echo "LOG: $*"; }'
        echo 'log_warn() { echo "WARN: $*"; }'
        echo 'update_state() { echo "$1" >> "$STATE_LOG"; }'
        echo 'lsmod() { echo "amneziawg 100000 0"; }'
        echo 'modinfo() { echo "vermagic: $(uname -r)"; echo "version: test"; }'
        echo 'command() { if [ "$1" = "-v" ] && [ "$2" = "awg" ]; then return 0; fi; builtin command "$@"; }'
        echo 'awg() { echo "awg-tools v0"; }'
        echo 'sleep() { :; }'
        echo 'SCRIPT_VERSION="0.0.0-test"'
        echo 'CONFIG_FILE="/tmp/awgsetup_cfg.init"'
        func_from "$script" _awg31_host_arch
        func_from "$script" _awg31_blocker_message
        func_from "$script" step3_check_module
        echo 'awg31_environment_blocker() { echo "$1" >> "$GATE_LOG"; printf "%s" "${BLOCKER_CODE-}"; return ${GATE_RC:-0}; }'
        echo 'step3_check_module'
    } > "$TEST_DIR/step3.sh"
    export GATE_LOG="$TEST_DIR/gate.log"
    export STATE_LOG="$TEST_DIR/state.log"
    : > "$GATE_LOG"
    : > "$STATE_LOG"
    run bash "$TEST_DIR/step3.sh"
}

@test "step 3 runs the gate at stage post when the marker says 3.1" {
    AWG_PROTOCOL="3.1" BLOCKER_CODE="" run_step3
    [ "$(cat "$GATE_LOG")" = "post" ]
}

@test "step 3 does not touch the gate on a 2.0 install" {
    AWG_PROTOCOL="2.0" BLOCKER_CODE="tools_old" run_step3
    [ ! -s "$GATE_LOG" ]
}

@test "step 3 stops the install when the tools cannot parse the third line" {
    AWG_PROTOCOL="3.1" BLOCKER_CODE="tools_old" run_step3
    [ "$status" -eq 1 ]
    [[ "$output" == *"DIE:"* ]]
    [[ "$output" == *"amneziawg-tools"* ]]
}

@test "the English installer wires step 3 the same way" {
    AWG_PROTOCOL="3.1" BLOCKER_CODE="" run_step3 "$INSTALL_EN"
    [ "$(cat "$GATE_LOG")" = "post" ]
}

@test "step 3 stops when the gate cannot answer at all" {
    # Empty output means "3.1 is allowed", and a crashed call prints nothing
    # either. Deleting the status check at THIS call site left every other
    # step 3 test green, because they all supply a zero status - named by
    # external review of this pull request.
    AWG_PROTOCOL="3.1" BLOCKER_CODE="" GATE_RC=1 run_step3
    [ "$status" -eq 1 ]
    [[ "$output" == *"DIE:"* ]]
}

@test "a step 3 that stopped never advances the state machine" {
    # Printing a refusal is not the same as stopping: the proof is that the
    # step never hands the installer over to step 4.
    AWG_PROTOCOL="3.1" BLOCKER_CODE="" GATE_RC=1 run_step3
    grep -qx 4 "$STATE_LOG" && { echo "state advanced to 4 despite the refusal"; return 1; }
    return 0
}

@test "the English installer stops at step 3 on a gate that cannot answer" {
    AWG_PROTOCOL="3.1" BLOCKER_CODE="" GATE_RC=1 run_step3 "$INSTALL_EN"
    [ "$status" -eq 1 ]
    [[ "$output" == *"DIE:"* ]]
}

@test "a step 3 that passed does advance the state machine" {
    # The negative test above is worthless without this one: a state log that
    # is always empty would satisfy it.
    AWG_PROTOCOL="2.0" run_step3
    [ "$status" -eq 0 ]
    grep -qx 4 "$STATE_LOG"
}

# --------------------------------------------------------------- both locales

@test "step 0 actually calls the resolver" {
    # Every other test in this file extracts the resolver and calls it directly,
    # so deleting the call from initialize_setup left them all green. External
    # review 9 sep 2026 named this; the check is structural because
    # initialize_setup is four hundred lines and cannot be run in a unit test.
    local script
    for script in "$INSTALL_RU" "$INSTALL_EN"; do
        sed -n '/^initialize_setup() {/,/^}/p' "$script" \
            | grep -q '_awg31_resolve_protocol "\$config_exists"' \
            || { echo "no resolver call inside initialize_setup of $script"; return 1; }
    done
}

@test "both installers declare the same new functions" {
    local fn
    for fn in _awg31_resolve_protocol _awg31_blocker_message; do
        grep -q "^${fn}() {" "$INSTALL_RU" || { echo "RU lacks $fn"; return 1; }
        grep -q "^${fn}() {" "$INSTALL_EN" || { echo "EN lacks $fn"; return 1; }
    done
}

@test "both installers document the flag in their help" {
    grep -q -- "--protocol=2.0|3.1" "$INSTALL_RU"
    grep -q -- "--protocol=2.0|3.1" "$INSTALL_EN"
}
