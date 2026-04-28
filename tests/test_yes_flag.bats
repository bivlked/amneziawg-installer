#!/usr/bin/env bats
# Phase 1 (v5.11.3): --yes flag and AWG_YES env for confirm_action.
#
# Extracts confirm_action and is_interactive from manage_amneziawg.sh into
# the test shell so the logic can be exercised without a live awg0.conf or
# a real interactive TTY. Both RU and EN scripts must share the same
# CLI_YES / AWG_YES check structure.

setup() {
    # Pull confirm_action + is_interactive out of the RU manage script.
    # awk extracts each function body verbatim; eval puts them in this shell.
    eval "$(awk '/^confirm_action\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh")"
    eval "$(awk '/^is_interactive\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh")"

    # Silent log stubs so confirm_action's "Действие отменено." log_msg() does
    # not fail when the function is sourced in isolation.
    log()       { :; }
    log_warn()  { :; }
    log_error() { :; }
    log_debug() { :; }
    export -f log log_warn log_error log_debug

    # Default: clear flags so each test starts from a known state.
    unset CLI_YES AWG_YES
}

@test "confirm_action: CLI_YES=1 skips prompt and returns 0" {
    CLI_YES=1
    run confirm_action "удалить" "клиента 'foo'"
    [ "$status" -eq 0 ]
}

@test "confirm_action: AWG_YES=1 (env) skips prompt and returns 0" {
    AWG_YES=1
    run confirm_action "удалить" "клиента 'foo'"
    [ "$status" -eq 0 ]
}

@test "confirm_action: CLI_YES wins even when AWG_YES=0" {
    CLI_YES=1
    AWG_YES=0
    run confirm_action "удалить" "клиента 'foo'"
    [ "$status" -eq 0 ]
}

@test "confirm_action: AWG_YES wins even when CLI_YES=0" {
    CLI_YES=0
    AWG_YES=1
    run confirm_action "удалить" "клиента 'foo'"
    [ "$status" -eq 0 ]
}

@test "confirm_action: non-interactive without flags returns 0 (preserves prior behaviour)" {
    # bats runs in a non-TTY context — is_interactive() returns false, so
    # confirm_action falls through to its existing non-interactive path.
    # CLI_YES/AWG_YES are read inside the eval-extracted confirm_action,
    # which shellcheck cannot see; suppress the false-positive SC2034.
    # shellcheck disable=SC2034
    CLI_YES=0
    # shellcheck disable=SC2034
    AWG_YES=0
    run confirm_action "удалить" "клиента 'foo'"
    [ "$status" -eq 0 ]
}

@test "confirm_action: non-'1' AWG_YES values do NOT match the bypass branch" {
    # Defensive: env vars come from external callers. Only literal "1"
    # should match the AWG_YES bypass. To prove this, force is_interactive
    # to TRUE so the non-TTY fallback cannot mask a loosened check —
    # then non-"1" values must NOT short-circuit; instead they fall
    # through to the read-from-/dev/tty path, which here is replaced
    # with a stub that returns the captured prompt input "n" (cancel).
    is_interactive() { return 0; }
    export -f is_interactive
    # shellcheck disable=SC2317
    read() {
        # Mimic user typing "n" then Enter.
        case "${!#}" in *) eval "$(printf '%s=%q' "${!#}" "n")" ;; esac
    }
    export -f read

    AWG_YES="yes"
    run confirm_action "удалить" "клиента 'foo'"
    [ "$status" -ne 0 ]   # not bypassed — fell through and was cancelled

    AWG_YES="true"
    run confirm_action "удалить" "клиента 'foo'"
    [ "$status" -ne 0 ]

    AWG_YES="0"
    run confirm_action "удалить" "клиента 'foo'"
    [ "$status" -ne 0 ]

    # Sanity: literal "1" still bypasses under same forced-interactive mode.
    # shellcheck disable=SC2034
    AWG_YES="1"
    run confirm_action "удалить" "клиента 'foo'"
    [ "$status" -eq 0 ]

    unset -f is_interactive read
}

@test "RU manage: CLI parser accepts --yes" {
    run grep -E '^\s+--yes\)\s+CLI_YES=1' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    [ "$status" -eq 0 ]
}

@test "EN manage: CLI parser accepts --yes" {
    run grep -E '^\s+--yes\)\s+CLI_YES=1' "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
    [ "$status" -eq 0 ]
}

@test "RU manage: usage help mentions --yes and AWG_YES" {
    run grep -F -- '--yes' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    [[ "$output" == *"AWG_YES=1"* ]]
}

@test "EN manage: usage help mentions --yes and AWG_YES" {
    run grep -F -- '--yes' "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
    [[ "$output" == *"AWG_YES=1"* ]]
}

@test "RU/EN parity: CLI_YES/AWG_YES check has identical structure" {
    # Strip comment lines (start with #) — only compare code identity.
    ru_block=$(awk '/^confirm_action\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" \
        | grep -E 'CLI_YES|AWG_YES' | grep -vE '^\s*#')
    en_block=$(awk '/^confirm_action\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh" \
        | grep -E 'CLI_YES|AWG_YES' | grep -vE '^\s*#')
    [ "$ru_block" = "$en_block" ]
}
