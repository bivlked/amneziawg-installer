#!/usr/bin/env bats
# Tests for restore_backup rollback infrastructure (v5.11 Phase 2 / A5.1).
#
# Covers:
#   • _restore_do_rollback() helper exists in both RU and EN managers.
#   • restore_backup registers a trap RETURN for _restore_cleanup.
#   • restore_backup captures the pre-restore snapshot from LAST_BACKUP_PATH.
#   • restore_backup runs pre-flight validate_awg_config before service start.
#   • restore_backup sets _restore_ok=1 before final success return.
#   • _restore_do_rollback restores the 5 standard directories and keys.
#
# restore_backup() itself touches systemctl and systemd units that cannot
# be exercised in a container-less unit test — these tests are static
# invariant checks on the source. The structural integrity of the rollback
# path is what matters; the failure-mode verification lives on real VPS.

setup() {
    MANAGE_RU="${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"
    MANAGE_EN="${BATS_TEST_DIRNAME}/../manage_amneziawg_en.sh"
    [ -f "$MANAGE_RU" ] || { echo "manage_amneziawg.sh missing" >&2; return 1; }
    [ -f "$MANAGE_EN" ] || { echo "manage_amneziawg_en.sh missing" >&2; return 1; }
}

extract_func() {
    local file="$1" name="$2"
    sed -n "/^${name}() {\$/,/^}\$/p" "$file"
}

# -------------------------------------------------------------------------
# Structural checks — rollback helper
# -------------------------------------------------------------------------

@test "A5.1: RU _restore_do_rollback is defined" {
    run extract_func "$MANAGE_RU" "_restore_do_rollback"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [[ "$output" == *"_restore_do_rollback()"* ]]
}

@test "A5.1: EN _restore_do_rollback is defined" {
    run extract_func "$MANAGE_EN" "_restore_do_rollback"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [[ "$output" == *"_restore_do_rollback()"* ]]
}

@test "A5.1: RU rollback restores all 5 standard locations" {
    local body
    body=$(extract_func "$MANAGE_RU" "_restore_do_rollback")
    # server/, clients/, keys/, server_private.key, server_public.key
    grep -qE '\$_rtd/server' <<< "$body"
    grep -qE '\$_rtd/clients' <<< "$body"
    grep -qE '\$_rtd/keys' <<< "$body"
    grep -qE 'server_private\.key' <<< "$body"
    grep -qE 'server_public\.key' <<< "$body"
}

@test "A5.1: EN rollback restores all 5 standard locations" {
    local body
    body=$(extract_func "$MANAGE_EN" "_restore_do_rollback")
    grep -qE '\$_rtd/server' <<< "$body"
    grep -qE '\$_rtd/clients' <<< "$body"
    grep -qE '\$_rtd/keys' <<< "$body"
    grep -qE 'server_private\.key' <<< "$body"
    grep -qE 'server_public\.key' <<< "$body"
}

@test "A5.1: RU rollback attempts systemctl start after file restoration" {
    local body
    body=$(extract_func "$MANAGE_RU" "_restore_do_rollback")
    grep -qE 'systemctl start awg-quick@awg0' <<< "$body"
}

@test "A5.1: EN rollback attempts systemctl start after file restoration" {
    local body
    body=$(extract_func "$MANAGE_EN" "_restore_do_rollback")
    grep -qE 'systemctl start awg-quick@awg0' <<< "$body"
}

# -------------------------------------------------------------------------
# Structural checks — restore_backup integration with rollback
# -------------------------------------------------------------------------

@test "A5.1: RU restore_backup registers trap RETURN for _restore_cleanup" {
    local body
    body=$(extract_func "$MANAGE_RU" "restore_backup")
    grep -qE 'trap _restore_cleanup RETURN' <<< "$body"
}

@test "A5.1: EN restore_backup registers trap RETURN for _restore_cleanup" {
    local body
    body=$(extract_func "$MANAGE_EN" "restore_backup")
    grep -qE 'trap _restore_cleanup RETURN' <<< "$body"
}

@test "A5.1: RU restore_backup captures LAST_BACKUP_PATH after self-backup" {
    local body
    body=$(extract_func "$MANAGE_RU" "restore_backup")
    grep -qE '_rollback_snap="\$\{LAST_BACKUP_PATH:-\}"' <<< "$body"
}

@test "A5.1: EN restore_backup captures LAST_BACKUP_PATH after self-backup" {
    local body
    body=$(extract_func "$MANAGE_EN" "restore_backup")
    grep -qE '_rollback_snap="\$\{LAST_BACKUP_PATH:-\}"' <<< "$body"
}

@test "A5.1: RU restore_backup runs validate_awg_config before service start" {
    local body
    body=$(extract_func "$MANAGE_RU" "restore_backup")
    # validate_awg_config must appear BEFORE the final systemctl start line
    # so invalid restored configs trigger rollback rather than starting
    # a broken service.
    local vline sline
    vline=$(grep -n '! validate_awg_config' <<< "$body" | head -1 | cut -d: -f1)
    sline=$(grep -n 'systemctl start awg-quick@awg0' <<< "$body" | tail -1 | cut -d: -f1)
    [ -n "$vline" ]
    [ -n "$sline" ]
    [ "$vline" -lt "$sline" ]
}

@test "A5.1: EN restore_backup runs validate_awg_config before service start" {
    local body
    body=$(extract_func "$MANAGE_EN" "restore_backup")
    local vline sline
    vline=$(grep -n '! validate_awg_config' <<< "$body" | head -1 | cut -d: -f1)
    sline=$(grep -n 'systemctl start awg-quick@awg0' <<< "$body" | tail -1 | cut -d: -f1)
    [ -n "$vline" ]
    [ -n "$sline" ]
    [ "$vline" -lt "$sline" ]
}

@test "A5.1: RU restore_backup sets _restore_ok=1 before success return" {
    local body
    body=$(extract_func "$MANAGE_RU" "restore_backup")
    grep -qE '_restore_ok=1' <<< "$body"
}

@test "A5.1: EN restore_backup sets _restore_ok=1 before success return" {
    local body
    body=$(extract_func "$MANAGE_EN" "restore_backup")
    grep -qE '_restore_ok=1' <<< "$body"
}

@test "A5.1: RU _restore_cleanup invokes _restore_do_rollback only when not ok" {
    local body
    body=$(extract_func "$MANAGE_RU" "restore_backup")
    # The cleanup block must gate rollback on `_restore_ok -eq 0` AND
    # `_destructive_ops_started -eq 1` (review Q2 fix).
    grep -qE '_restore_ok -eq 0.*_destructive_ops_started -eq 1.*_rollback_snap' <<< "$body"
}

@test "A5.1: EN _restore_cleanup invokes _restore_do_rollback only when not ok" {
    local body
    body=$(extract_func "$MANAGE_EN" "restore_backup")
    grep -qE '_restore_ok -eq 0.*_destructive_ops_started -eq 1.*_rollback_snap' <<< "$body"
}

# -------------------------------------------------------------------------
# Post-audit fixes (review Q1/Q2/Q3)
# -------------------------------------------------------------------------

@test "Q1: RU _restore_cleanup clears RETURN trap to prevent global leak" {
    local body
    body=$(extract_func "$MANAGE_RU" "restore_backup")
    # trap - RETURN must be inside _restore_cleanup to clear the global
    # RETURN trap and prevent reentrancy / leak to callers.
    grep -qE 'trap - RETURN' <<< "$body"
}

@test "Q1: EN _restore_cleanup clears RETURN trap to prevent global leak" {
    local body
    body=$(extract_func "$MANAGE_EN" "restore_backup")
    grep -qE 'trap - RETURN' <<< "$body"
}

@test "Q2: RU restore_backup sets _destructive_ops_started after systemctl stop" {
    local body
    body=$(extract_func "$MANAGE_RU" "restore_backup")
    # The flag must transition from 0 to 1 exactly around systemctl stop
    # — rollback only meaningful once state is actually modified.
    # Use a pattern matching only code lines (not comments).
    local sline dline
    sline=$(grep -nE '^[[:space:]]+systemctl stop awg-quick@awg0' <<< "$body" | head -1 | cut -d: -f1)
    dline=$(grep -nE '^[[:space:]]+_destructive_ops_started=1$' <<< "$body" | head -1 | cut -d: -f1)
    [ -n "$sline" ]
    [ -n "$dline" ]
    [ "$dline" -gt "$sline" ]
}

@test "Q2: EN restore_backup sets _destructive_ops_started after systemctl stop" {
    local body
    body=$(extract_func "$MANAGE_EN" "restore_backup")
    local sline dline
    sline=$(grep -nE '^[[:space:]]+systemctl stop awg-quick@awg0' <<< "$body" | head -1 | cut -d: -f1)
    dline=$(grep -nE '^[[:space:]]+_destructive_ops_started=1$' <<< "$body" | head -1 | cut -d: -f1)
    [ -n "$sline" ]
    [ -n "$dline" ]
    [ "$dline" -gt "$sline" ]
}

@test "Q3: RU _backup_configs_nolock treats expiry/ as critical" {
    local body
    body=$(extract_func "$MANAGE_RU" "_backup_configs_nolock")
    # Must NOT have the old silent 2>/dev/null || true for expiry/
    run grep -qE 'cp -a "\$\{EXPIRY_DIR.*\|\| log_warn' <<< "$body"; [ "$status" -ne 0 ]
    # Must have if-block that returns 1 on failure for expiry/
    grep -qE 'if ! cp -a "\$\{EXPIRY_DIR' <<< "$body"
}

@test "Q3: EN _backup_configs_nolock treats expiry/ as critical" {
    local body
    body=$(extract_func "$MANAGE_EN" "_backup_configs_nolock")
    run grep -qE 'cp -a "\$\{EXPIRY_DIR.*\|\| log_warn' <<< "$body"; [ "$status" -ne 0 ]
    grep -qE 'if ! cp -a "\$\{EXPIRY_DIR' <<< "$body"
}

@test "Q3: RU _backup_configs_nolock treats awg-expiry cron as critical" {
    local body
    body=$(extract_func "$MANAGE_RU" "_backup_configs_nolock")
    run grep -qE 'cp -a /etc/cron\.d/awg-expiry.*\|\| log_warn' <<< "$body"; [ "$status" -ne 0 ]
    grep -qE 'if ! cp -a /etc/cron\.d/awg-expiry' <<< "$body"
}

@test "Q3: EN _backup_configs_nolock treats awg-expiry cron as critical" {
    local body
    body=$(extract_func "$MANAGE_EN" "_backup_configs_nolock")
    run grep -qE 'cp -a /etc/cron\.d/awg-expiry.*\|\| log_warn' <<< "$body"; [ "$status" -ne 0 ]
    grep -qE 'if ! cp -a /etc/cron\.d/awg-expiry' <<< "$body"
}

# -------------------------------------------------------------------------
# Dynamic test — rollback file restoration (mocked systemctl)
# -------------------------------------------------------------------------

prepare_rollback_sandbox() {
    BATS_TMP=$(mktemp -d)
    export AWG_DIR="$BATS_TMP/awg"
    export KEYS_DIR="$BATS_TMP/awg/keys"
    export CONFIG_FILE="$BATS_TMP/awg/awgsetup_cfg.init"
    export SERVER_CONF_FILE="$BATS_TMP/awg/awg0.conf"
    export EXPIRY_DIR="$BATS_TMP/awg/expiry"
    mkdir -p "$AWG_DIR" "$KEYS_DIR" "$EXPIRY_DIR"

    log()       { :; }
    log_warn()  { :; }
    log_error() { :; }
    log_debug() { :; }
    die()       { echo "die: $*" >&2; return 1; }
    # Stub systemctl — always succeeds, captures action
    systemctl() { echo "systemctl $*" >> "$BATS_TMP/systemctl.log"; return 0; }
    # v5.21.2: manage_mktempdir_var writes the path to a named var (no $() so
    # the parent's cleanup array registration survives).
    manage_mktempdir_var() { local d; d=$(mktemp -d "$BATS_TMP/mktd-XXXXXX") || return 1; printf -v "$1" '%s' "$d"; }
    export -f log log_warn log_error log_debug die systemctl manage_mktempdir_var
}

rollback_teardown() {
    rm -rf "$BATS_TMP"
}

@test "dyn A5.1: _restore_do_rollback aborts early on missing snapshot" {
    prepare_rollback_sandbox
    # shellcheck disable=SC1090
    source <(extract_func "$MANAGE_RU" "_restore_do_rollback")
    run _restore_do_rollback "/nonexistent/snap.tar.gz"
    [ "$status" -ne 0 ]
    rollback_teardown
}

@test "dyn A5.1: _restore_do_rollback extracts snapshot and calls systemctl start" {
    prepare_rollback_sandbox
    # Build a minimal valid snapshot
    local staging="$BATS_TMP/stage"
    mkdir -p "$staging/server" "$staging/clients" "$staging/keys"
    echo '[Interface]' > "$staging/server/awg0.conf"
    echo 'priv' > "$staging/server_private.key"
    echo 'pub'  > "$staging/server_public.key"
    echo 'metadata' > "$staging/clients/awgsetup_cfg.init"
    echo 'ck' > "$staging/keys/alice.private"
    local snap="$BATS_TMP/snap.tar.gz"
    tar -czf "$snap" -C "$staging" .

    # Wipe current state to confirm rollback actually re-creates files
    rm -f "$SERVER_CONF_FILE" "$AWG_DIR/server_private.key" "$AWG_DIR/server_public.key"
    rm -f "$CONFIG_FILE" "$KEYS_DIR/alice.private"

    # shellcheck disable=SC1090
    source <(extract_func "$MANAGE_RU" "_restore_do_rollback")
    run _restore_do_rollback "$snap"
    [ "$status" -eq 0 ]
    [ -f "$SERVER_CONF_FILE" ]
    [ -f "$AWG_DIR/server_private.key" ]
    [ -f "$AWG_DIR/server_public.key" ]
    [ -f "$KEYS_DIR/alice.private" ]
    grep -q "systemctl start awg-quick@awg0" "$BATS_TMP/systemctl.log"
    rollback_teardown
}

@test "dyn A5.1: _restore_do_rollback EN version also works identically" {
    prepare_rollback_sandbox
    local staging="$BATS_TMP/stage"
    mkdir -p "$staging/server"
    echo '[Interface]' > "$staging/server/awg0.conf"
    local snap="$BATS_TMP/snap.tar.gz"
    tar -czf "$snap" -C "$staging" .
    rm -f "$SERVER_CONF_FILE"

    # shellcheck disable=SC1090
    source <(extract_func "$MANAGE_EN" "_restore_do_rollback")
    run _restore_do_rollback "$snap"
    [ "$status" -eq 0 ]
    [ -f "$SERVER_CONF_FILE" ]
    rollback_teardown
}
