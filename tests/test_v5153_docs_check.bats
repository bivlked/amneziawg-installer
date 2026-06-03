#!/usr/bin/env bats
# Tests for T6 (v5.15.3): new checks in scripts/check-docs-consistency.sh.
#   #7 - stale IPv6 split-tunnel wording must not return to ADVANCED.
#   #8 - the issue-template version placeholder must stay neutral (no X.Y.Z).
#
# We assert the real script still passes on the repo (integration) and that the
# detection patterns catch the stale forms while not flagging the correct ones.

load test_helper

SCRIPT="$BATS_TEST_DIRNAME/../scripts/check-docs-consistency.sh"

# Patterns kept in sync with the script.
IPV6_STALE_RE='подразумевает full-tunnel|implies full-tunnel|пока не поддерживается|is not supported yet'
TMPL_STALE_RE='placeholder:[[:space:]]*"e\.g\.,[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+"'

@test "T6: check-docs-consistency passes on the current repo" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    # 9 checks since v5.15.3 round-2 added the full OS + arch matrix check (D4).
    [[ "$output" == *"9 passed, 0 failed"* ]]
}

@test "T6: script defines checks #7 and #8" {
    run grep -c 'IPv6 split-tunnel формулировк' "$SCRIPT"
    [ "$status" -eq 0 ]
    run grep -q 'placeholder версии нейтральный' "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "T6 #7: stale IPv6 phrases are detected" {
    for bad in \
        "В v5.15.0 dual-stack подразумевает full-tunnel" \
        "in v5.15.0 dual-stack implies full-tunnel" \
        "сочетание split-tunnel с IPv6 пока не поддерживается" \
        "combining split-tunnel with IPv6 is not supported yet"; do
        echo "$bad" | grep -qE "$IPV6_STALE_RE" || { echo "missed stale: $bad"; false; }
    done
}

@test "T6 #7: the corrected wording and past-tense note are NOT flagged" {
    for ok in \
        "в v5.15.0 dual-stack всегда подразумевал full-tunnel (split-tunnel вёл себя иначе)" \
        "in v5.15.0 dual-stack always implied a full tunnel (split-tunnel behaved differently)" \
        "split-tunnel сохраняет IPv4-список и добавляет только ULA"; do
        echo "$ok" | grep -qE "$IPV6_STALE_RE" && { echo "false positive: $ok"; false; }
    done
    return 0
}

@test "T6 #8: a concrete X.Y.Z placeholder is detected, neutral is not" {
    echo '      placeholder: "e.g., 5.15.0"' | grep -qE "$TMPL_STALE_RE"
    echo '      placeholder: "e.g., 5.x.y"'  | grep -qE "$TMPL_STALE_RE" && { echo "neutral flagged"; false; }
    # The kernel placeholder must not false-positive (version has a suffix).
    echo '      placeholder: "e.g., 6.8.0-51-generic"' | grep -qE "$TMPL_STALE_RE" && { echo "kernel flagged"; false; }
    return 0
}
