#!/usr/bin/env bats
# .4 (v5.15.3 round-3): check-docs-consistency slug rewrite.
#
# The old _slug ran a 4-process pipeline (tr|sed|tr|sed) per heading, which was
# slow on hundreds of headings, and used LC_ALL=C so every Cyrillic heading
# slugged to the empty string (RU anchors were effectively unchecked). It is
# replaced by a single-pass, Unicode-aware perl stream filter, and docs/ROADMAP.md
# (which carries a `](#дорожная-карта)` link) is added to DOC_FILES.

SCRIPT="$BATS_TEST_DIRNAME/../scripts/check-docs-consistency.sh"

setup() {
    command -v perl >/dev/null || skip "perl not available"
    # Extract and load the real _slug_stream implementation from the script.
    eval "$(awk '/^_slug_stream\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$SCRIPT")"
}

@test ".4 _slug_stream: ASCII heading matches the GitHub slug" {
    out=$(printf '%s\n' 'Recently Shipped' | _slug_stream)
    [ "$out" = "recently-shipped" ]
}

@test ".4 _slug_stream: Cyrillic is preserved and lowercased" {
    out=$(printf '%s\n' 'Дорожная карта' | _slug_stream)
    [ "$out" = "дорожная-карта" ]
}

@test ".4 _slug_stream: emoji and punctuation stripped, Cyrillic kept" {
    out=$(printf '%s\n' '🗺️ Дорожная карта и публичный бэклог' | _slug_stream)
    [ "$out" = "дорожная-карта-и-публичный-бэклог" ]
}

@test ".4 _slug_stream: slugs several headings in a single pass" {
    out=$(printf '%s\n' 'Alpha' 'Бета' | _slug_stream | tr '\n' ',')
    [ "$out" = "alpha,бета," ]
}

@test ".4 docs/ROADMAP.md is covered by DOC_FILES" {
    run grep -E 'docs/ROADMAP\.md' "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test ".4 slugger no longer uses the per-heading LC_ALL=C pipeline" {
    run grep -F 'LC_ALL=C sed' "$SCRIPT"
    [ "$status" -ne 0 ]
}

@test ".4 slugger uses a single-pass perl stream filter" {
    run grep -E '^_slug_stream\(\)' "$SCRIPT"
    [ "$status" -eq 0 ]
    run grep -F 'perl -CSD' "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test ".4 integration: docs-check still passes 10/10 with ROADMAP included" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"10 passed, 0 failed"* ]]
}
