#!/usr/bin/env bats
# v5.11.5 hotfix regression tests.
#
# Two bundled fixes:
#   1. manage regen multi-arg (Issue #70 from @Barmem) — `manage regen c1 c2 c3`
#      used to process only c1; the rest were silently dropped. Now matches
#      add/remove pattern (loop over ARGS[@]).
#   2. apt strict mode on rc!=0 in step 2 (PR #69 review finding) —
#      apt_update_tolerant gained --ppa-amnezia-tolerant flag so step 2 dies
#      on base-mirror / GPG / dpkg-lock errors but still defers to
#      apt_wait_for_ppa_package retry on PPA Amnezia outage (issue #68).

# ---------- Fix 1: regen multi-arg ----------

@test "v5.11.5: RU regen case iterates ARGS[@]" {
    # Extract the regen case body and confirm the for-loop is there.
    block=$(awk '/^    regen\)/,/^[[:space:]]+;;[[:space:]]*$/' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh")
    [[ "$block" == *'for _cname in "${ARGS[@]}"'* ]]
}

@test "v5.11.5: EN regen case iterates ARGS[@]" {
    block=$(awk '/^    regen\)/,/^[[:space:]]+;;[[:space:]]*$/' "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh")
    [[ "$block" == *'for _cname in "${ARGS[@]}"'* ]]
}

@test "v5.11.5: RU regen has counter and 'Обработано N из M' summary" {
    block=$(awk '/^    regen\)/,/^[[:space:]]+;;[[:space:]]*$/' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh")
    [[ "$block" == *'_regen_count'* ]]
    [[ "$block" == *'Обработано'* ]]
}

@test "v5.11.5: EN regen has counter and 'Processed N of M' summary" {
    block=$(awk '/^    regen\)/,/^[[:space:]]+;;[[:space:]]*$/' "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh")
    [[ "$block" == *'_regen_count'* ]]
    [[ "$block" == *'Processed'* ]]
}

@test "v5.11.5: regen no longer hard-dies on missing single client (regression guard)" {
    # Pre-fix the single-client branch had `die "Клиент не найден."` — fail-fast
    # on a typo. The new loop logs warn + sets _cmd_rc=1 and continues, so a
    # batch with one missing name still processes valid ones.
    block=$(awk '/^    regen\)/,/^[[:space:]]+;;[[:space:]]*$/' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh")
    [[ "$block" == *'не найден, пропуск'* ]]
    [[ "$block" != *'die "Клиент'* ]]

    block_en=$(awk '/^    regen\)/,/^[[:space:]]+;;[[:space:]]*$/' "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh")
    [[ "$block_en" == *'not found, skipping'* ]]
    [[ "$block_en" != *'die "Client'* ]]
}

@test "v5.11.5: regen no-args path preserved (fallback to all clients)" {
    # The `${#ARGS[@]} -eq 0` branch must still grep ^#_Name = and loop —
    # backwards-compatibility for `manage regen` invocations without arguments.
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        block=$(awk '/^    regen\)/,/^[[:space:]]+;;[[:space:]]*$/' "$BATS_TEST_DIRNAME/../$f")
        [[ "$block" == *'${#ARGS[@]} -eq 0'* ]]
        [[ "$block" == *'^#_Name = '* ]]
    done
}

@test "v5.11.5: RU/EN regen case parity (identical control-flow tokens)" {
    ru=$(awk '/^    regen\)/,/^[[:space:]]+;;[[:space:]]*$/' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" \
        | grep -oE '(if |for |while |elif |else|fi|done|\${#ARGS\[@\]}|_regen_count|ARGS\[@\])' \
        | sort -u)
    en=$(awk '/^    regen\)/,/^[[:space:]]+;;[[:space:]]*$/' "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh" \
        | grep -oE '(if |for |while |elif |else|fi|done|\${#ARGS\[@\]}|_regen_count|ARGS\[@\])' \
        | sort -u)
    [ "$ru" = "$en" ]
}

# ---------- Fix 2: apt strict mode + --ppa-amnezia-tolerant ----------

@test "v5.11.5: RU apt_update_tolerant accepts --ppa-amnezia-tolerant flag" {
    # The flag string and the local var both must be present.
    run grep -F -- '--ppa-amnezia-tolerant' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    [ "$status" -eq 0 ]
    run grep -E '^\s*local ppa_tolerant=0' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    [ "$status" -eq 0 ]
}

@test "v5.11.5: EN apt_update_tolerant accepts --ppa-amnezia-tolerant flag" {
    run grep -F -- '--ppa-amnezia-tolerant' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    [ "$status" -eq 0 ]
    run grep -E '^\s*local ppa_tolerant=0' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    [ "$status" -eq 0 ]
}

@test "v5.11.5: step 2 uses --ppa-amnezia-tolerant and dies on hard error (RU)" {
    # The step 2 callsite must invoke the flag AND die() on rc!=0; without die
    # the install would proceed on a stale apt-cache (PR #69 review finding).
    run grep -B0 -A6 'apt_update_tolerant --ppa-amnezia-tolerant' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *'die'* ]]
}

@test "v5.11.5: step 2 uses --ppa-amnezia-tolerant and dies on hard error (EN)" {
    run grep -B0 -A6 'apt_update_tolerant --ppa-amnezia-tolerant' \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *'die'* ]]
}

@test "v5.11.5: ppa-tolerant guard requires raw_had_non_src_errors (OOM/silent crash safety)" {
    # Codex round-2 MEDIUM: don't tolerate when output mentions PPA Amnezia
    # but no E:/Err:/W: lines were classified — that's an OOM/silent crash
    # path that must surface, not be swallowed.
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run grep -F 'raw_had_non_src_errors' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ]
    done
}

# ---------- Version markers ----------

@test "v5.11.5: SCRIPT_VERSION bumped in all six files" {
    for f in install_amneziawg.sh install_amneziawg_en.sh manage_amneziawg.sh manage_amneziawg_en.sh; do
        run grep -E 'SCRIPT_VERSION="5\.11\.5"' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ]
    done
    run grep -E '# Версия: 5\.11\.5' "$BATS_TEST_DIRNAME/../awg_common.sh"
    [ "$status" -eq 0 ]
    run grep -E '# Version: 5\.11\.5' "$BATS_TEST_DIRNAME/../awg_common_en.sh"
    [ "$status" -eq 0 ]
}
