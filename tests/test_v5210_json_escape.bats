#!/usr/bin/env bats
# Phase 2 (v5.21.0, MyAI-n30w): hardened json_escape.
#
# New guarantees over the v5.20.x version:
#   - C0 controls (0x01-0x1F) escape as \u00XX (raw ESC/BEL used to break jq);
#   - invalid UTF-8 bytes become U+FFFD (replacement, not silent drop);
#   - valid input (ASCII and Cyrillic) passes through byte-identical to the
#     old behavior - list/stats output for real data must not change.
#
# Extracts json_escape + _json_utf8_sanitize from the manage scripts and
# validates every escaped result with jq.

require_jq() { command -v jq &>/dev/null || skip "jq not available"; }

_load_escape() {
    local src="$1"
    eval "$(awk '/^_json_utf8_sanitize\(\) \{/,/^\}/' "$src")"
    eval "$(awk '/^json_escape\(\) \{/,/^\}/' "$src")"
}

setup() {
    _load_escape "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
}

_jq_roundtrip() {
    # Wraps the escaped value into a JSON doc and asks jq for it back.
    printf '{"v":"%s"}' "$(json_escape "$1")" | jq -re '.v'
}

# --- valid input: byte-identical to the old escaper (freeze) ---

@test "plain name passes unchanged" {
    [ "$(json_escape 'phone-1_2')" = "phone-1_2" ]
}

@test "cyrillic status literal passes unchanged" {
    [ "$(json_escape 'Активен')" = "Активен" ]
}

@test "quotes and backslash escape as before" {
    [ "$(json_escape 'a"b\c')" = 'a\"b\\c' ]
}

@test "newline, CR, tab escape as before" {
    [ "$(json_escape $'a\nb\rc\td')" = 'a\nb\rc\td' ]
}

# --- C0 hardening ---

@test "ESC (0x1B) escapes to \\u001b and jq accepts the document" {
    require_jq
    local out
    out=$(json_escape $'red:\x1b[31m')
    [[ "$out" == *'\u001b'* ]]
    run _jq_roundtrip $'red:\x1b[31m'
    [ "$status" -eq 0 ]
}

@test "BEL (0x07) escapes to \\u0007 and jq accepts the document" {
    require_jq
    local out
    out=$(json_escape $'ding\x07')
    [ "$out" = 'ding\u0007' ]
    run _jq_roundtrip $'ding\x07'
    [ "$status" -eq 0 ]
}

@test "old escaper really did break jq on raw ESC (regression rationale)" {
    require_jq
    # The pre-v5.21.0 escaper passed ESC through raw; jq must reject that.
    old_escape() {
        local s="$1"
        s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
        s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
        printf '%s' "$s"
    }
    run bash -c "printf '{\"v\":\"%s\"}' \"\$1\" | jq -e ." _ "$(old_escape $'x\x1b')"
    [ "$status" -ne 0 ]
}

# --- invalid UTF-8 -> U+FFFD ---

@test "invalid byte becomes U+FFFD, valid part survives" {
    local out
    out=$(json_escape "$(printf 'ab\xffcd')")
    [ "$out" = "ab$(printf '\xEF\xBF\xBD')cd" ]
}

@test "invalid bytes around cyrillic: cyrillic survives intact" {
    require_jq
    local in out
    in=$(printf 'ok\xffсередина\xfeконец')
    out=$(json_escape "$in")
    [[ "$out" == *"середина"* && "$out" == *"конец"* ]]
    run _jq_roundtrip "$in"
    [ "$status" -eq 0 ]
}

@test "all-invalid input becomes all-U+FFFD, jq accepts" {
    require_jq
    local out ufffd
    ufffd=$(printf '\xEF\xBF\xBD')
    out=$(json_escape "$(printf '\xff\xfe\xfd')")
    [ "$out" = "${ufffd}${ufffd}${ufffd}" ]
}

@test "combined: invalid UTF-8 plus ESC plus quote in one string, jq accepts" {
    require_jq
    run _jq_roundtrip "$(printf 'p\xffq\x1br"s')"
    [ "$status" -eq 0 ]
}

# --- EN parity ---

@test "EN: escaper handles ESC and invalid UTF-8 identically" {
    require_jq
    local ru_out en_out in
    in=$(printf 'x\xffy\x1bz')
    ru_out=$(json_escape "$in")
    _load_escape "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
    en_out=$(json_escape "$in")
    [ "$ru_out" = "$en_out" ]
    run _jq_roundtrip "$in"
    [ "$status" -eq 0 ]
}
