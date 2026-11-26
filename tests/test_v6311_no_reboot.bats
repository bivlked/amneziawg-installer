#!/usr/bin/env bats
# --no-reboot (#427): the installer does not reboot by itself. It saves the next
# step, says a reboot is needed and exits with 75 (EX_TEMPFAIL), so Ansible or
# Puppet can tell "reboot and run me again" from the end of the install (0) and
# from a failure (any other code: 1, or 2 for bad parameters), reboot the server
# themselves and run the same command again.

load test_helper

bats_require_minimum_version 1.5.0

setup() {
    T=$(mktemp -d)
}

teardown() {
    rm -rf "$T"
}

# run_reboot_gate <installer> <AUTO_YES> <NO_REBOOT> <step>: runs request_reboot of
# that installer in a clean shell with stubbed state, logging and reboot.
run_reboot_gate() {
    local f="$BATS_TEST_DIRNAME/../$1"
    sed -n '/^request_reboot() {/,/^}/p' "$f" > "$T/fn.sh"
    [ -s "$T/fn.sh" ] || { echo "request_reboot not found in $1"; return 1; }
    cat > "$T/run.sh" << EOF
AWG_DIR="$T"; LOG_FILE="$T/log"; AUTO_YES=$2; NO_REBOOT=$3
update_state() { echo "\$1" > "$T/state"; }
log() { echo "INFO: \$*"; }
log_warn() { echo "WARN: \$*"; }
log_debug() { :; }
die() { echo "die: \$*"; exit 1; }
sleep() { :; }
reboot() { : > "$T/rebooted"; }
source "$T/fn.sh"
request_reboot $4
echo "returned"
EOF
    # no controlling terminal and a time limit: a question on /dev/tty must fail
    # the test, not hang it
    run timeout 20 setsid -w bash "$T/run.sh"
}

_no_reboot_exits_75() {
    run_reboot_gate "$1" 1 1 2 || return 1
    [ "$status" -eq 75 ] || { echo "$1: rc $status: $output"; return 1; }
    [ ! -e "$T/rebooted" ] || { echo "$1: rebooted with --no-reboot"; return 1; }
    [ "$(cat "$T/state")" = "2" ] || { echo "$1: state '$(cat "$T/state" 2>&1)'"; return 1; }
    [[ "$output" == *"--no-reboot"* ]] || { echo "$1: the flag is not named: $output"; return 1; }
    [[ "$output" != *returned* ]] || { echo "$1: request_reboot returned"; return 1; }
    # The boot_id is saved before the exit: step 2 refuses a rerun without a reboot.
    [ "$(cat "$T/.boot_id_before_step2" 2>&1)" = "$(cat /proc/sys/kernel/random/boot_id)" ] \
        || { echo "$1: no boot_id saved before exit 75"; return 1; }
    rm -f "$T/state" "$T/.boot_id_before_step2"
}
@test "--no-reboot: the next step is saved, no reboot, exit 75 in both installers" {
    _no_reboot_exits_75 install_amneziawg.sh
    _no_reboot_exits_75 install_amneziawg_en.sh
}

_no_reboot_without_yes() {
    # No question either: the run is unattended, there is nobody to answer.
    run_reboot_gate "$1" 0 1 3 < /dev/null || return 1
    [ "$status" -eq 75 ] || { echo "$1: rc $status: $output"; return 1; }
    [ ! -e "$T/rebooted" ] || return 1
    [ "$(cat "$T/state")" = "3" ] || return 1
    rm -f "$T/state"
}
@test "--no-reboot without --yes: no question, exit 75" {
    _no_reboot_without_yes install_amneziawg.sh
    _no_reboot_without_yes install_amneziawg_en.sh
}

_yes_still_reboots() {
    run_reboot_gate "$1" 1 0 2 || return 1
    [ -e "$T/rebooted" ] || { echo "$1: --yes no longer reboots: $output"; return 1; }
    [ "$status" -eq 1 ] || { echo "$1: rc $status"; return 1; }
    rm -f "$T/rebooted" "$T/state"
}
@test "--yes without --no-reboot still reboots by itself" {
    _yes_still_reboots install_amneziawg.sh
    _yes_still_reboots install_amneziawg_en.sh
}

_flag_parsed() {
    run bash "$BATS_TEST_DIRNAME/../$1" --no-reboot --help
    [ "$status" -eq 0 ] || { echo "$1: --no-reboot is not accepted (rc $status): ${output:0:300}"; return 1; }
    grep -qE '^  --no-reboot ' <<< "$output" || { echo "$1: --no-reboot not in help"; return 1; }
    grep -qxF '        --no-reboot)     NO_REBOOT=1 ;;' <(sed -n '/^while \[\[ \$# -gt 0 \]\]/,/^done/p' "$BATS_TEST_DIRNAME/../$1") \
        || { echo "$1: the parser does not set NO_REBOOT=1"; return 1; }
    # Only the default and the parser assign it: a later reset (from a saved config,
    # say) would make the flag silently do nothing.
    [ "$(grep -cE '(^|[^A-Z_])NO_REBOOT=' "$BATS_TEST_DIRNAME/../$1")" = "2" ] \
        || { echo "$1: NO_REBOOT assigned elsewhere: $(grep -nE '(^|[^A-Z_])NO_REBOOT=' "$BATS_TEST_DIRNAME/../$1")"; return 1; }
}
@test "--no-reboot is parsed and listed in help of both installers" {
    _flag_parsed install_amneziawg.sh
    _flag_parsed install_amneziawg_en.sh
}
