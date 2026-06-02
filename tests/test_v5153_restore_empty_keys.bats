#!/usr/bin/env bats
# Tests for C2 (v5.15.3): restore must survive a backup whose keys/ directory is
# empty (a server that had no client keys when it was backed up).
#
# The backup always creates $td/keys, but only populates it when keys exist
# (compgen guard on the backup side). On restore the keys block ran
# `cp -a "$td/keys/"*` with no nullglob, so an empty keys/ left the glob literal,
# cp failed, and - because this runs after destructive ops have begun - the
# whole restore rolled back. The fix guards the copy with compgen and treats an
# empty keys/ as a no-op.
#
# restore_backup() as a whole needs systemctl and root, so per the plan we test
# the guarded fragment in isolation and assert the guard exists in both scripts.

load test_helper

# Mirror of the C2-guarded keys-restore block from restore_backup().
restore_keys_fragment() {
    local td="$1"
    if [[ -d "$td/keys" ]]; then
        mkdir -p "$KEYS_DIR"
        rm -f "$KEYS_DIR"/* 2>/dev/null || true
        if ! compgen -G "$td/keys/*" > /dev/null; then
            return 0   # empty keys/ - skip, not an error
        elif ! cp -a "$td/keys/"* "$KEYS_DIR/"; then
            return 1
        else
            chmod 600 "$KEYS_DIR"/* 2>/dev/null
        fi
    fi
    return 0
}

@test "C2: empty keys/ in the archive does not fail (no rollback trigger)" {
    local td="$TEST_DIR/extract"
    mkdir -p "$td/keys"   # present but empty, as a no-client-keys backup yields
    run restore_keys_fragment "$td"
    [ "$status" -eq 0 ]
}

@test "C2: populated keys/ is still copied into KEYS_DIR" {
    local td="$TEST_DIR/extract"
    mkdir -p "$td/keys"
    echo "priv" > "$td/keys/alice.private"
    echo "pub"  > "$td/keys/alice.public"
    rm -rf "$KEYS_DIR"; mkdir -p "$KEYS_DIR"

    run restore_keys_fragment "$td"
    [ "$status" -eq 0 ]
    [ -f "$KEYS_DIR/alice.private" ]
    [ -f "$KEYS_DIR/alice.public" ]
}

@test "C2: missing keys/ directory is a no-op" {
    local td="$TEST_DIR/extract_nokeys"
    mkdir -p "$td"   # no keys subdir at all
    run restore_keys_fragment "$td"
    [ "$status" -eq 0 ]
}

@test "C2: source guards the keys copy with compgen (RU)" {
    run grep -E 'compgen -G "\$td/keys/\*"' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    [ "$status" -eq 0 ]
}

@test "C2: source guards the keys copy with compgen (EN)" {
    run grep -E 'compgen -G "\$td/keys/\*"' "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
    [ "$status" -eq 0 ]
}
