#!/usr/bin/env bats
# The "awg_common.sh is outdated" warning in manage names the ADVANCED section to
# update from. In the English script the section name used to sit in bare double
# quotes inside a double-quoted log_warn argument, so the shell split it into four
# words and log_msg (which takes only $1) printed the message cut off at
# "(section How". The line has no command substitutions, so evaluating it with a
# counting stub is safe and shows exactly what log_warn receives.

_eval_hint() {
    local script="$1" pattern="$2" line
    line=$(grep -m1 -F "$pattern" "$BATS_TEST_DIRNAME/../$script")
    [[ -n "$line" ]] || { echo "hint line not found in $script"; return 2; }
    [[ "$line" != *'$('* && "$line" != *'`'* ]] || { echo "line has a substitution, refusing to eval"; return 2; }
    log_warn() { printf 'argc=%s\n%s\n' "$#" "$1"; }
    eval "$line"
}

@test "manage EN: outdated-library hint reaches log_warn as one argument" {
    run _eval_hint manage_amneziawg_en.sh 'awg_restore_generation_notice is missing'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "argc=1" ]
    [[ "${lines[1]}" == *"How to Update Scripts"*"ADVANCED.en.md"* ]]
}

@test "manage RU: outdated-library hint reaches log_warn as one argument" {
    run _eval_hint manage_amneziawg.sh 'нет awg_restore_generation_notice'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "argc=1" ]
    [[ "${lines[1]}" == *"Как обновить скрипты"*"ADVANCED.md"* ]]
}
