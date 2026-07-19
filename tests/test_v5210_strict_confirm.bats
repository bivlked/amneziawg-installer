#!/usr/bin/env bats
# Phase 1 (v5.21.0, MyAI-2s58): AWG_STRICT_CONFIRM opt-in for confirm_action.
#
# Matrix 2x2x2 (strict x TTY x yes). Extracts confirm_action + is_interactive
# from the manage scripts (same awk pattern as test_yes_flag.bats) so the
# logic runs without a live server or a real TTY. bats itself is non-TTY,
# so the "interactive" axis is simulated by stubbing is_interactive.
#
# shellcheck disable=SC2034  # CLI_YES/AWG_YES/AWG_STRICT_CONFIRM are read
#                            # inside the eval-extracted confirm_action.

_load_confirm() {
    local src="$1"
    eval "$(awk '/^confirm_action\(\) \{/,/^\}/' "$src")"
    eval "$(awk '/^is_interactive\(\) \{/,/^\}/' "$src")"
    # Log stubs that echo so `run` can assert on the message text.
    log()       { echo "LOG: $1"; }
    log_warn()  { echo "WARN: $1" >&2; }
    log_error() { echo "ERROR: $1" >&2; }
    log_debug() { :; }
}

setup() {
    _load_confirm "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    unset CLI_YES AWG_YES AWG_STRICT_CONFIRM _JSON_ERR
}

# --- strict=1, non-TTY ---

@test "strict=1 non-TTY without yes: refused with rc 1 and STRICT message" {
    AWG_STRICT_CONFIRM=1
    run confirm_action "удалить" "клиента 'foo'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"AWG_STRICT_CONFIRM=1"* ]]
    [[ "$output" == *"--yes"* ]]
}

@test "strict=1 non-TTY with CLI_YES=1: allowed (yes beats strict)" {
    AWG_STRICT_CONFIRM=1
    CLI_YES=1
    run confirm_action "удалить" "клиента 'foo'"
    [ "$status" -eq 0 ]
}

@test "strict=1 non-TTY with AWG_YES=1: allowed (env yes beats strict)" {
    AWG_STRICT_CONFIRM=1
    AWG_YES=1
    run confirm_action "удалить" "клиента 'foo'"
    [ "$status" -eq 0 ]
}

@test "strict=1 refusal sets _JSON_ERR for the JSON exit guard" {
    AWG_STRICT_CONFIRM=1
    # No `run` here: run executes in a subshell and variable changes vanish.
    confirm_action "удалить" "клиента 'foo'" 2>/dev/null || true
    [ "${_JSON_ERR:-}" = "AWG_STRICT_CONFIRM=1: non-interactive run requires --yes" ]
}

# --- strict=0 / unset, non-TTY: prior behavior preserved ---

@test "strict unset non-TTY without yes: allowed (prior behavior, the default)" {
    run confirm_action "удалить" "клиента 'foo'"
    [ "$status" -eq 0 ]
}

@test "strict=0 non-TTY without yes: allowed" {
    AWG_STRICT_CONFIRM=0
    run confirm_action "удалить" "клиента 'foo'"
    [ "$status" -eq 0 ]
}

@test "strict=true (not '1') non-TTY: treated as off, allowed" {
    AWG_STRICT_CONFIRM=true
    run confirm_action "удалить" "клиента 'foo'"
    [ "$status" -eq 0 ]
}

# --- strict=1, TTY (simulated): prompt path, strict must NOT trigger ---

@test "strict=1 interactive: goes to prompt, not the STRICT refusal" {
    AWG_STRICT_CONFIRM=1
    is_interactive() { return 0; }
    # Shadow the read builtin: on a real TTY (local WSL runs) the prompt's
    # `read < /dev/tty` would block forever waiting for input; in CI /dev/tty
    # fails to open. Either way the prompt path must end in "cancelled" -
    # the point is the message is NOT the strict one.
    read() { return 1; }
    run confirm_action "удалить" "клиента 'foo'"
    [[ "$output" != *"AWG_STRICT_CONFIRM"* ]]
}

@test "strict=1 interactive with CLI_YES=1: allowed without prompt" {
    AWG_STRICT_CONFIRM=1
    CLI_YES=1
    is_interactive() { return 0; }
    run confirm_action "удалить" "клиента 'foo'"
    [ "$status" -eq 0 ]
}

# --- EN parity ---

@test "EN: strict=1 non-TTY without yes refused with rc 1" {
    _load_confirm "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
    AWG_STRICT_CONFIRM=1
    run confirm_action "remove" "client 'foo'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"AWG_STRICT_CONFIRM=1"* ]]
}

@test "EN: strict unset non-TTY without yes allowed" {
    _load_confirm "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
    run confirm_action "remove" "client 'foo'"
    [ "$status" -eq 0 ]
}

@test "EN: _JSON_ERR text is byte-identical to RU (same machine contract)" {
    _load_confirm "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
    AWG_STRICT_CONFIRM=1
    confirm_action "remove" "client 'foo'" 2>/dev/null || true
    [ "${_JSON_ERR:-}" = "AWG_STRICT_CONFIRM=1: non-interactive run requires --yes" ]
}
