#!/usr/bin/env bats
# Tests for C1 (v5.15.3): the pre-restore snapshot must not prune away the
# backup the user selected for restore.
#
# restore_backup() takes a snapshot of the current state via
# _backup_configs_nolock before overwriting anything. That helper used to prune
# the backups directory to the 10 newest files. The file selected for restore
# lives in that same directory, so when ~10 backups already existed the snapshot
# pushed the count over the limit and the prune could delete the oldest one -
# which might be exactly the file being restored - making the later
# `tar -tvzf "$bf"` fail. The fix adds a --no-prune mode used by restore.
#
# We exercise the REAL _backup_configs_nolock by extracting its definition from
# the script (its closing brace is the only one in column 0) and sourcing it in
# isolation with light stubs, then assert the call-site via grep.

load test_helper

# Pull just the _backup_configs_nolock function out of the manage script.
source_backup_fn() {
    local script="$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    eval "$(sed -n '/^_backup_configs_nolock() {/,/^}/p' "$script")"
}

setup_backup_env() {
    # Minimal collaborators the function expects.
    log()       { :; }
    log_warn()  { :; }
    log_debug() { :; }
    die()       { echo "die: $*" >&2; return 1; }
    manage_mktempdir_var() { local d; d=$(mktemp -d) || return 1; printf -v "$1" '%s' "$d"; }
    create_server_config   # gives the backup some real content
    create_init_config
    source_backup_fn
}

# Create N pre-existing backups with distinct, strictly increasing old mtimes.
seed_old_backups() {
    local n="$1" bd="$AWG_DIR/backups" i
    mkdir -p "$bd"
    for (( i = 1; i <= n; i++ )); do
        : > "$bd/awg_backup_seed_$(printf '%02d' "$i").tar.gz"
        touch -d "@$((1600000000 + i))" "$bd/awg_backup_seed_$(printf '%02d' "$i").tar.gz"
    done
}

count_backups() {
    find "$AWG_DIR/backups" -maxdepth 1 -name 'awg_backup_*.tar.gz' | wc -l
}

@test "C1: --no-prune keeps all existing backups and the selected (oldest) one" {
    setup_backup_env
    seed_old_backups 11
    # The oldest seed is the one a restore might target; it must survive.
    local oldest="$AWG_DIR/backups/awg_backup_seed_01.tar.gz"
    [ -f "$oldest" ]

    run _backup_configs_nolock --no-prune
    [ "$status" -eq 0 ]

    # 11 seeds + 1 fresh snapshot, nothing pruned.
    [ "$(count_backups)" -eq 12 ]
    [ -f "$oldest" ]
}

@test "C1: default mode still prunes the backups directory to 10" {
    setup_backup_env
    seed_old_backups 11

    run _backup_configs_nolock
    [ "$status" -eq 0 ]

    [ "$(count_backups)" -eq 10 ]
}

@test "C1: restore_backup calls _backup_configs_nolock with --no-prune (RU)" {
    run grep -E '_backup_configs_nolock --no-prune' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    [ "$status" -eq 0 ]
}

@test "C1: restore_backup calls _backup_configs_nolock with --no-prune (EN)" {
    run grep -E '_backup_configs_nolock --no-prune' "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
    [ "$status" -eq 0 ]
}

@test "C1: RU/EN parity for the --no-prune guard structure" {
    ru=$(grep -c 'no_prune' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh")
    en=$(grep -c 'no_prune' "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh")
    [ "$ru" -eq "$en" ]
    [ "$ru" -ge 3 ]
}
