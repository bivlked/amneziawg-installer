#!/usr/bin/env bats
# Phase 2 (v5.11.3): backup filename millisecond suffix.
#
# Without millisecond precision, two rapid-fire backups within the same
# second collide (second one overwrites the first via tar). The fix adds
# .%3N to the timestamp format. These tests verify both manage scripts
# carry the new format and that the find/restore pattern still matches
# both old (legacy) and new (ms-suffixed) filenames.

@test "RU manage: backup timestamp uses millisecond precision (.%3N)" {
    run grep -E 'date \+%F_%H-%M-%S\.%3N' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    [ "$status" -eq 0 ]
}

@test "EN manage: backup timestamp uses millisecond precision (.%3N)" {
    run grep -E 'date \+%F_%H-%M-%S\.%3N' "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
    [ "$status" -eq 0 ]
}

@test "date +%3N produces millisecond-distinct values under rapid fire" {
    # Sample 10 calls in a tight loop and require at least 2 distinct values.
    # GNU coreutils on Linux/Git Bash supports %3N. BSD date does not, but
    # the project targets Ubuntu/Debian only.
    local seen=()
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        seen+=("$(date +%3N)")
    done
    local uniq_count
    uniq_count=$(printf '%s\n' "${seen[@]}" | sort -u | wc -l)
    [ "$uniq_count" -ge 2 ]
}

@test "Restore find pattern matches legacy (no ms) backup filenames" {
    local bd
    bd=$(mktemp -d)
    touch "$bd/awg_backup_2026-04-28_15-53-50.tar.gz"
    local matches
    matches=$(find "$bd" -maxdepth 1 -name "awg_backup_*.tar.gz" | wc -l)
    [ "$matches" -eq 1 ]
    rm -rf "$bd"
}

@test "Restore find pattern matches new ms-suffix backup filenames" {
    local bd
    bd=$(mktemp -d)
    touch "$bd/awg_backup_2026-04-28_15-53-50.123.tar.gz"
    touch "$bd/awg_backup_2026-04-28_15-53-50.456.tar.gz"
    local matches
    matches=$(find "$bd" -maxdepth 1 -name "awg_backup_*.tar.gz" | wc -l)
    [ "$matches" -eq 2 ]
    rm -rf "$bd"
}

@test "Mixed legacy + ms-suffix files coexist in find output" {
    local bd
    bd=$(mktemp -d)
    touch "$bd/awg_backup_2026-04-25_10-00-00.tar.gz"          # legacy
    touch "$bd/awg_backup_2026-04-28_15-53-50.123.tar.gz"      # new
    touch "$bd/awg_backup_2026-04-28_15-53-50.456.tar.gz"      # new
    local matches
    matches=$(find "$bd" -maxdepth 1 -name "awg_backup_*.tar.gz" | wc -l)
    [ "$matches" -eq 3 ]
    rm -rf "$bd"
}

@test "Sort -r orders newer (later date) backups first regardless of ms-suffix" {
    local bd
    bd=$(mktemp -d)
    touch "$bd/awg_backup_2026-04-25_10-00-00.tar.gz"
    touch "$bd/awg_backup_2026-04-28_15-53-50.123.tar.gz"
    touch "$bd/awg_backup_2026-04-28_15-53-51.000.tar.gz"
    local first
    first=$(find "$bd" -maxdepth 1 -name "awg_backup_*.tar.gz" | sort -r | head -1)
    [[ "$first" == *"2026-04-28_15-53-51.000.tar.gz" ]]
    rm -rf "$bd"
}

@test "RU/EN parity: backup timestamp line identical" {
    ru=$(grep -E 'ts=\$\(date \+%F_%H-%M-%S' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" | head -1 | tr -d ' \t')
    en=$(grep -E 'ts=\$\(date \+%F_%H-%M-%S' "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh" | head -1 | tr -d ' \t')
    [ "$ru" = "$en" ]
}
