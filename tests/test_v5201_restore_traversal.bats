#!/usr/bin/env bats
# Path traversal check in restore_backup(): segment match, not substring.
#
# The old check rejected any tar entry containing the substring "..", which
# also killed legitimate filenames like "my..backup.conf". The new helper
# _path_has_parent_component() flags ".." only when it is a complete path
# component: exactly "..", a "../" prefix, a "/../" in the middle, or a
# trailing "/..". Everything else (dots inside a name) is legitimate.

load test_helper

# Extract _path_has_parent_component from a manage script (awk range: def .. closing brace).
extract_fn() {
    awk '/^_path_has_parent_component\(\)/,/^}/' "$BATS_TEST_DIRNAME/../$1"
}

# Run the extracted helper against one path. Prints TRAVERSAL / CLEAN.
check_path() {
    local script="$1" path="$2"
    local fn; fn=$(extract_fn "$script")
    [ -n "$fn" ] || { echo "extract failed"; return 99; }
    bash -c '
        '"$fn"'
        if _path_has_parent_component "$1"; then echo "TRAVERSAL"; else echo "CLEAN"; fi
    ' _ "$path"
}

# --- legitimate names with dots must pass (the original false positives) ---

@test "traversal: my..backup.conf is CLEAN (dots inside a name)" {
    result=$(check_path manage_amneziawg.sh "my..backup.conf")
    [ "$result" = "CLEAN" ]
}

@test "traversal: subdir/..foo.conf is CLEAN (leading dots in a name)" {
    result=$(check_path manage_amneziawg.sh "subdir/..foo.conf")
    [ "$result" = "CLEAN" ]
}

@test "traversal: v1..2.tar.gz is CLEAN (range-style name)" {
    result=$(check_path manage_amneziawg.sh "v1..2.tar.gz")
    [ "$result" = "CLEAN" ]
}

@test "traversal: clients/name../x is CLEAN (trailing dots in a component)" {
    result=$(check_path manage_amneziawg.sh "clients/name../x")
    [ "$result" = "CLEAN" ]
}

@test "traversal: ./server/awg0.conf is CLEAN (normal tar entry)" {
    result=$(check_path manage_amneziawg.sh "./server/awg0.conf")
    [ "$result" = "CLEAN" ]
}

# --- real parent-directory components must be rejected ---

@test "traversal: bare .. is TRAVERSAL" {
    result=$(check_path manage_amneziawg.sh "..")
    [ "$result" = "TRAVERSAL" ]
}

@test "traversal: ../escape.conf is TRAVERSAL (leading)" {
    result=$(check_path manage_amneziawg.sh "../escape.conf")
    [ "$result" = "TRAVERSAL" ]
}

@test "traversal: subdir/../escape.conf is TRAVERSAL (middle)" {
    result=$(check_path manage_amneziawg.sh "subdir/../escape.conf")
    [ "$result" = "TRAVERSAL" ]
}

@test "traversal: subdir/.. is TRAVERSAL (trailing)" {
    result=$(check_path manage_amneziawg.sh "subdir/..")
    [ "$result" = "TRAVERSAL" ]
}

@test "traversal: ./../escape.conf is TRAVERSAL (dot-slash prefix)" {
    result=$(check_path manage_amneziawg.sh "./../escape.conf")
    [ "$result" = "TRAVERSAL" ]
}

@test "traversal: ../../etc/evil.txt is TRAVERSAL (deep escape)" {
    result=$(check_path manage_amneziawg.sh "../../etc/evil.txt")
    [ "$result" = "TRAVERSAL" ]
}

# --- EN script parity ---

@test "traversal EN: my..backup.conf is CLEAN" {
    result=$(check_path manage_amneziawg_en.sh "my..backup.conf")
    [ "$result" = "CLEAN" ]
}

@test "traversal EN: subdir/../escape.conf is TRAVERSAL" {
    result=$(check_path manage_amneziawg_en.sh "subdir/../escape.conf")
    [ "$result" = "TRAVERSAL" ]
}

@test "traversal: helper bodies are identical in RU and EN scripts" {
    ru=$(extract_fn manage_amneziawg.sh)
    en=$(extract_fn manage_amneziawg_en.sh)
    [ -n "$ru" ]
    [ "$ru" = "$en" ]
}

# --- the restore loop actually calls the helper (no stale substring check) ---

@test "traversal: restore loop calls _path_has_parent_component (RU + EN)" {
    grep -q '_path_has_parent_component "\$_bad_entry"' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    grep -q '_path_has_parent_component "\$_bad_entry"' "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
    # the old substring predicate must be gone
    ! grep -q '"\$_bad_entry" == \*\.\.\*' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    ! grep -q '"\$_bad_entry" == \*\.\.\*' "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
}
