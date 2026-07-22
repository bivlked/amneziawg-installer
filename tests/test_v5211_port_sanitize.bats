#!/usr/bin/env bats
# v5.21.1: AWG_PORT from awgsetup_cfg.init is normalized before use.
#
# The config file is hand-edited, so a bad edit can leave any string in
# AWG_PORT. That value reached several places unchecked:
#   - the check --json envelope, interpolated without quotes, so a non-numeric
#     value produced "number":abc - not parseable, which breaks the v5.21.0
#     promise of exactly one valid JSON document;
#   - [[ "$port" -eq 0 ]], an arithmetic context where bash performs command
#     substitution, so a value like a[$(cmd)] executed cmd;
#   - the UFW rule regex, where a value like '.*' matched any rule.
#
# These tests run the real _sanitize_port pulled out of the scripts, not a
# local copy of the logic - a grep-for-the-regex test would pass even if the
# function were never called.

require_jq() { command -v jq &>/dev/null || skip "jq not available"; }

_load_sanitizer() {
    eval "$(awk '/^_sanitize_port\(\) \{/,/^\}/' "$1")"
}

setup() {
    # v5.21.2: _sanitize_port moved to awg_common.sh (shared by check/diagnose
    # in manage and by generate/regenerate_client in the library).
    _load_sanitizer "$BATS_TEST_DIRNAME/../awg_common.sh"
}

# --- valid ports pass through unchanged ---

@test "port sanitize: real ports survive" {
    for p in 1 443 39743 51820 65535; do
        run _sanitize_port "$p"
        [ "$output" = "$p" ] || { echo "port $p became $output"; return 1; }
    done
}

@test "port sanitize: leading zeros are not read as octal" {
    # Without 10# a padded value is read as octal: 0070 would become 56.
    # 0080 is not even valid octal and would abort the arithmetic outright.
    run _sanitize_port "0080"
    [ "$output" = "80" ]
    run _sanitize_port "00001"
    [ "$output" = "1" ]
    # All-zero padding is still zero, so it lands in the "unknown" bucket.
    run _sanitize_port "00000"
    [ "$output" = "0" ]
}

@test "port sanitize: whitespace around the value is trimmed" {
    # 'AWG_PORT=39743 ' is an ordinary leftover of a hand edit and names the
    # same port. Rejecting it would paint a healthy server red.
    for p in "39743 " " 39743" "  39743  " "$(printf '39743\t')"; do
        run _sanitize_port "$p"
        [ "$output" = "39743" ] || { echo "[$p] became [$output], expected 39743"; return 1; }
    done
}

@test "port sanitize: trimming does not rescue genuinely broken values" {
    # Whitespace inside the value is still junk, not a port.
    for p in "39743 x" "1 2" "39743 # comment" " abc "; do
        run _sanitize_port "$p"
        [ "$output" = "0" ] || { echo "[$p] became [$output], expected 0"; return 1; }
    done
}

@test "diagnose reads the port without substituting a default first" {
    # Sanitizing "${AWG_PORT:-39743}" would report on a port the config does
    # not hold: the default slips past the validator and looks like a finding.
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        run grep -F '_sanitize_port "${AWG_PORT:-39743}"' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -ne 0 ] || { echo "$f still sanitizes the default port"; return 1; }
        run grep -cF '_sanitize_port "${AWG_PORT:-}"' "$BATS_TEST_DIRNAME/../$f"
        [ "$output" -eq 2 ] || { echo "$f: expected 2 sanitizer calls, found $output"; return 1; }
    done
}

@test "port sanitize: no argument at all is safe under set -u" {
    run bash -c "set -u; $(declare -f _sanitize_port); _sanitize_port"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

# --- everything else collapses to 0, the value check already treats as
#     "port unknown" ---

@test "port sanitize: junk collapses to 0" {
    for p in "abc" "1 2" "" "8.5" "-5" "80;rm -rf /" '$(id)' "0" "port"; do
        run _sanitize_port "$p"
        [ "$output" = "0" ] || { echo "[$p] became [$output], expected 0"; return 1; }
    done
}

@test "port sanitize: out-of-range and overflow collapse to 0" {
    # 65536 is one past the maximum; the long one would overflow 64-bit
    # arithmetic and yield a meaningless number.
    for p in 65536 70000 99999999999999999999; do
        run _sanitize_port "$p"
        [ "$output" = "0" ] || { echo "$p became $output"; return 1; }
    done
}

# --- the two defects, tested through behaviour ---

@test "check JSON stays parseable for any AWG_PORT" {
    require_jq
    for p in "abc" "1 2" "" "39743" "0080" "99999999999999999999"; do
        local n
        n=$(_sanitize_port "$p")
        # Same shape as the check envelope: the value is interpolated bare.
        run bash -c "printf '{\"port\":{\"number\":%s}}' '$n' | jq -re '.port.number'"
        [ "$status" -eq 0 ] || { echo "[$p] produced unparseable JSON"; return 1; }
        [[ "$output" =~ ^[0-9]+$ ]] || { echo "[$p] gave non-numeric $output"; return 1; }
    done
}

@test "arithmetic test on the port does not execute commands" {
    marker="$BATS_TEST_TMPDIR/executed"
    rm -f "$marker"
    # Raw value would run touch inside [[ -eq ]]; the sanitized one must not.
    port=$(_sanitize_port "a[\$(touch $marker)]")
    if [[ "$port" -eq 0 ]]; then :; fi
    [ ! -f "$marker" ] || { echo "command substitution executed via arithmetic"; return 1; }
    [ "$port" = "0" ]
}

# --- the fix must be wired in, not just present ---

@test "check_server calls the sanitizer instead of reading AWG_PORT raw" {
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        run grep -E 'port=\$\(_sanitize_port "\$\{AWG_PORT:-\}"\)' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ] || { echo "$f does not call _sanitize_port"; return 1; }
        run grep -F 'local port=${AWG_PORT:-0}' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -ne 0 ] || { echo "$f still reads AWG_PORT raw"; return 1; }
    done
}

@test "RU/EN parity: the empty-vs-junk branches stay identical" {
    # The function collapses both cases to 0; the callers tell them apart with
    # [[ -n "${AWG_PORT:-}" ]], and that decision lives in four places
    # (check_server and diagnose_server, times two languages). Pinning the
    # sanitizer body alone would let the branches drift apart unnoticed.
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        run grep -c 'if \[\[ -n "${AWG_PORT:-}" \]\]; then' "$BATS_TEST_DIRNAME/../$f"
        [ "$output" -eq 2 ] || { echo "$f: expected 2 empty-vs-junk branches, found $output"; return 1; }
        # Both branches must scrub the value before printing it.
        run grep -c '_bad_port="${_bad_port//\[^\[:print:\]\]/?}"' "$BATS_TEST_DIRNAME/../$f"
        [ "$output" -eq 2 ] || { echo "$f: value not scrubbed in both branches ($output)"; return 1; }
    done
}

@test "RU/EN parity: identical sanitizer body" {
    ru=$(awk '/^_sanitize_port\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../awg_common.sh" | grep -vE '^\s*#')
    en=$(awk '/^_sanitize_port\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../awg_common_en.sh" | grep -vE '^\s*#')
    [ -n "$ru" ] && [ "$ru" = "$en" ]
}

@test "EN sanitizer behaves the same as RU" {
    _load_sanitizer "$BATS_TEST_DIRNAME/../awg_common_en.sh"
    run _sanitize_port "abc"; [ "$output" = "0" ]
    run _sanitize_port "443"; [ "$output" = "443" ]
    run _sanitize_port "65536"; [ "$output" = "0" ]
}
