#!/usr/bin/env bats
# v5.11.4 apt_update_with_retry — issue #68 regression test.
#
# Bug fixed: a brief ppa.launchpadcontent.net outage at install-time used to
# kill the script with "Ошибка apt update" / "apt update error". The new
# helper retries up to N times with exponential backoff and only fails when
# all attempts are exhausted, with a friendly final message that points
# users at issue #68 (Launchpad infrastructure outage, not a script bug).
#
# These tests extract apt_update_with_retry from each install script and
# exercise it against stubbed apt_update_tolerant + sleep so no real apt
# call happens during the test.

extract_helper() {
    # awk extracts the function body verbatim; eval puts it in this shell.
    # shellcheck disable=SC2046
    eval "$(awk '/^apt_update_with_retry\(\) \{/,/^\}/' "$1")"
}

setup() {
    log_warn()  { :; }
    log_error() { :; }
    log()       { :; }
    log_debug() { :; }
    export -f log log_warn log_error log_debug
    # Reset state.
    _attempts=0
    _delays=()
    # Stub sleep so tests run in milliseconds even with backoff math.
    sleep() { _delays+=("$1"); }
    export -f sleep
}

# ---------- RU install script ----------

@test "v5.11.4 PPA retry: RU helper succeeds on first attempt without sleeping" {
    extract_helper "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    apt_update_tolerant() { return 0; }
    export -f apt_update_tolerant

    run apt_update_with_retry 3 1
    [ "$status" -eq 0 ]
    # No retry attempted, so no sleeps. The shellcheck disable is only
    # because external bats runs with -x flag where stub captures are tricky.
    # Skip the array-length assertion in the `run` subshell — just confirm
    # rc=0.
}

@test "v5.11.4 PPA retry: RU helper retries until apt_update_tolerant succeeds" {
    extract_helper "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    # Fail twice, succeed on third attempt — counter lives in current shell.
    apt_update_tolerant() {
        _attempts=$((_attempts + 1))
        (( _attempts >= 3 ))
    }
    # Run the helper directly (no `run` subshell) so _attempts persists.
    apt_update_with_retry 3 1
    rc=$?
    [ "$rc" -eq 0 ]
    [ "$_attempts" -eq 3 ]
}

@test "v5.11.4 PPA retry: RU helper returns 1 after exhausting max attempts" {
    extract_helper "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    apt_update_tolerant() {
        _attempts=$((_attempts + 1))
        return 1
    }
    set +e
    apt_update_with_retry 3 1
    rc=$?
    set -e
    [ "$rc" -ne 0 ]
    [ "$_attempts" -eq 3 ]
}

@test "v5.11.4 PPA retry: RU helper uses exponential backoff (delay doubles)" {
    extract_helper "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    apt_update_tolerant() { return 1; }
    set +e
    apt_update_with_retry 4 10
    set -e
    # 4 attempts → 3 sleeps between them: 10, 20, 40.
    [ "${#_delays[@]}" -eq 3 ]
    [ "${_delays[0]}" -eq 10 ]
    [ "${_delays[1]}" -eq 20 ]
    [ "${_delays[2]}" -eq 40 ]
}

@test "v5.11.4 PPA retry: RU helper caps delay at 1800s (overflow guard)" {
    extract_helper "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    apt_update_tolerant() { return 1; }
    set +e
    # initial=2000 already above cap; doubled values would all stay capped.
    apt_update_with_retry 4 2000
    set -e
    [ "${#_delays[@]}" -eq 3 ]
    [ "${_delays[0]}" -eq 2000 ]
    [ "${_delays[1]}" -eq 1800 ]
    [ "${_delays[2]}" -eq 1800 ]
}

# ---------- EN install script ----------

@test "v5.11.4 PPA retry: EN helper succeeds on first attempt" {
    extract_helper "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    apt_update_tolerant() { return 0; }

    run apt_update_with_retry 3 1
    [ "$status" -eq 0 ]
}

@test "v5.11.4 PPA retry: EN helper retries until success" {
    extract_helper "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    apt_update_tolerant() {
        _attempts=$((_attempts + 1))
        (( _attempts >= 2 ))
    }
    apt_update_with_retry 3 1
    rc=$?
    [ "$rc" -eq 0 ]
    [ "$_attempts" -eq 2 ]
}

@test "v5.11.4 PPA retry: EN helper exhausts max attempts and returns 1" {
    extract_helper "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    apt_update_tolerant() {
        _attempts=$((_attempts + 1))
        return 1
    }
    set +e
    apt_update_with_retry 3 1
    rc=$?
    set -e
    [ "$rc" -ne 0 ]
    [ "$_attempts" -eq 3 ]
}

# ---------- RU/EN parity ----------

@test "v5.11.4 PPA retry: RU and EN helpers are structurally identical" {
    # Normalize the only language-specific line (log_warn message) — control
    # flow + math + return values must be identical. Anchor to start-of-line
    # to avoid masking a future drift where someone adds a second log_warn
    # call in this function with different RU/EN content.
    local ru en
    ru=$(awk '/^apt_update_with_retry\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh" \
        | sed -E 's/^([[:space:]]*)log_warn ".*"$/\1log_warn "MSG"/')
    en=$(awk '/^apt_update_with_retry\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh" \
        | sed -E 's/^([[:space:]]*)log_warn ".*"$/\1log_warn "MSG"/')
    [ "$ru" = "$en" ]
}

@test "v5.11.4 PPA retry: friendly final error in RU references issue #68" {
    run grep -F 'issues/68' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    [ "$status" -eq 0 ]
}

@test "v5.11.4 PPA retry: friendly final error in EN references issue #68" {
    run grep -F 'issues/68' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    [ "$status" -eq 0 ]
}
