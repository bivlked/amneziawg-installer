#!/usr/bin/env bats
# The finish block of a 3.1 install says how to get back to 2.0.
#
# Gate G2.14 (headless install) found that a 3.1 install names its clients and says
# that routers without 3.1 firmware and Hiddify need a 2.0 server, but nowhere says
# how to get one. The only hint was the step-0 notice "stop now (Ctrl+C) and run with
# --protocol=2.0" (install_amneziawg_en.sh), printed without a pause, so on an unattended
# install nobody reads it in time, and wrong once the install is done: on an installed
# server --protocol=2.0 is refused, and the way is --uninstall (the profiles go with it,
# a backup copy is kept by default) followed by a new install with --protocol=2.0. The finish block
# is the last thing printed and the part of the log a person reads afterwards.
#
# The real step99_finish is lifted out of both installers and run with stubs, so the
# test fails if the lines are removed from the shipped function.

# shellcheck disable=SC2034  # the variables set in finish_output are read by the lifted step99_finish, which shellcheck does not see

RU_INSTALL() { echo "$BATS_TEST_DIRNAME/../install_amneziawg.sh"; }
EN_INSTALL() { echo "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"; }

extract_func() {
    awk -v f="$2" '
        $0 ~ "^" f "\\(\\) \\{" { p = 1 }
        p { print }
        p && /^\}$/ { exit }
    ' "$1"
}

# Run the shipped step99_finish of <installer> for <generation> [fallback code].
finish_output() {
    local f="$1" gen="$2" fb="${3:-}" d
    d=$(mktemp -d)
    (
        eval "$(extract_func "$f" _awg31_fallback_reason)"
        eval "$(extract_func "$f" _awg_generation_summary)"
        eval "$(extract_func "$f" step99_finish)"
        log() { echo "$*"; }
        log_warn() { echo "WARN: $*"; }
        log_error() { echo "ERROR: $*"; }
        cleanup_apt() { :; }
        _awg31_host_arch() { echo aarch64; }
        AWG_PROTOCOL="$gen"
        AWG_PROTOCOL_SOURCE=default
        AWG_PROTOCOL_FALLBACK="$fb"
        AWG_DIR="$d" CONFIG_FILE="$d/init" STATE_FILE="$d/state" LOG_FILE="$d/log"
        BOOT_CRITICAL_SNAPSHOT_FILE="$d/snap" MANAGE_SCRIPT_PATH="$d/manage.sh"
        : > "$CONFIG_FILE"
        # A failed extraction must be loud: otherwise the "no --uninstall" checks
        # below would pass on output that is only "command not found".
        declare -F step99_finish _awg_generation_summary _awg31_fallback_reason >/dev/null \
            || { echo "EXTRACT FAILED"; exit 97; }
        step99_finish
    ) 2>&1
    local rc=$?
    rm -rf "$d"
    return "$rc"
}

# The two steps of the way back: --uninstall with the warning about the
# profiles, and on the same or the next line the new install with
# --protocol=2.0 and new profiles for the clients.
assert_way_back() {
    local profiles_word="$1" new_profiles="$2" backup_word="$3"
    # a runnable command, not just a flag name
    grep -F -- '--uninstall' <<<"$output" | grep -qE -- 'sudo bash [^ ]+ --uninstall'
    grep -F -- '--uninstall' <<<"$output" | grep -q "$profiles_word"
    grep -F -- '--uninstall' <<<"$output" | grep -q "$backup_word"
    grep -A1 -F -- '--uninstall' <<<"$output" | grep -qF -- '--protocol=2.0'
    grep -A1 -F -- '--uninstall' <<<"$output" | grep -qF -- "$new_profiles"
}

@test "finish of a 3.1 install names the way back to 2.0 (RU)" {
    run finish_output "$(RU_INSTALL)" 3.1
    [ "$status" -eq 0 ]
    assert_way_back 'профил' 'новые профили' 'бэкап'
}

@test "finish of a 3.1 install names the way back to 2.0 (EN)" {
    run finish_output "$(EN_INSTALL)" 3.1
    [ "$status" -eq 0 ]
    assert_way_back 'profiles' 'new profiles' 'backup'
}

@test "the way back sits in the 3.1 client block, after the clients that need 2.0" {
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        run finish_output "$f" 3.1
        [ "$status" -eq 0 ]
        local hint way
        hint=$(grep -nE 'Hiddify' <<<"$output" | head -1 | cut -d: -f1)
        way=$(grep -nF -- '--uninstall' <<<"$output" | head -1 | cut -d: -f1)
        [ -n "$hint" ]
        [ -n "$way" ]
        [ "$way" -gt "$hint" ]
    done
}

@test "finish of a 2.0 install does not talk about leaving 3.1" {
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        run finish_output "$f" 2.0
        [ "$status" -eq 0 ]
        # the 2.0 client branch really ran (the same line in both languages)
        [[ "$output" == *"4.8.12.7"* ]]
        [[ "$output" != *--uninstall* ]]
        run finish_output "$f" 2.0 arm
        [ "$status" -eq 0 ]
        # and the fallback branch this run exists for
        [[ "$output" == *"WARN: "* ]]
        [[ "$output" != *--uninstall* ]]
    done
}
