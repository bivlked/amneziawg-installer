#!/usr/bin/env bats
# Code-review finding B1: INT/TERM traps must terminate the script.
#
# Both installers and managers used `trap _cleanup EXIT INT TERM`. On INT/TERM
# bash ran the cleanup but did NOT exit, so execution continued past the
# interrupted command (dangerous mid apt/dpkg/config edits) and cleanup ran a
# second time on EXIT. The fix splits the handlers: EXIT does cleanup only;
# INT/TERM do an idempotent cleanup and exit 130/143.

load test_helper

@test "B1 signal pattern: SIGTERM exits 143, cleans up once, does not continue" {
    local out="$TEST_DIR/sig.out"
    : > "$out"
    cat > "$TEST_DIR/sig.sh" <<EOF
#!/bin/bash
cleaned=0
_cleanup() { [[ "\$cleaned" -eq 1 ]] && return 0; cleaned=1; echo CLEANUP >> "$out"; }
_on_signal() { _cleanup; exit "\$1"; }
trap _cleanup EXIT
trap '_on_signal 130' INT
trap '_on_signal 143' TERM
echo START >> "$out"
sleep 10
echo AFTER >> "$out"
EOF
    bash "$TEST_DIR/sig.sh" &
    local pid=$! i=0
    while [[ ! -s "$out" ]] && (( i++ < 50 )); do sleep 0.1; done
    kill -TERM "$pid"
    local rc=0
    wait "$pid" || rc=$?

    [ "$rc" -eq 143 ] || { echo "exit code was $rc, expected 143"; false; }
    grep -q START "$out"
    grep -q CLEANUP "$out"
    ! grep -q AFTER "$out" || { echo "script continued past the signal"; false; }
    [ "$(grep -c CLEANUP "$out")" -eq 1 ] || { echo "cleanup ran more than once"; false; }
}

@test "B1 source: installers split EXIT from INT/TERM and exit on signal" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        # The combined trap must be gone.
        run grep -E 'trap _install_cleanup EXIT INT TERM' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -ne 0 ] || { echo "$f still has combined EXIT INT TERM trap"; false; }
        run grep -E 'trap _install_cleanup EXIT$' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ] || { echo "$f missing EXIT-only cleanup trap"; false; }
        run grep -E "_install_on_signal 130' INT" "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ] || { echo "$f missing INT signal handler"; false; }
        run grep -E "_install_on_signal 143' TERM" "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ] || { echo "$f missing TERM signal handler"; false; }
    done
}

@test "B1 source: managers split EXIT from INT/TERM and exit on signal" {
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        run grep -E 'trap _manage_cleanup EXIT INT TERM' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -ne 0 ] || { echo "$f still has combined EXIT INT TERM trap"; false; }
        run grep -E "_manage_on_signal 130' INT" "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ] || { echo "$f missing INT signal handler"; false; }
        run grep -E "_manage_on_signal 143' TERM" "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ] || { echo "$f missing TERM signal handler"; false; }
    done
}

@test "B1 source: cleanup is idempotent (guard flag) in all four scripts" {
    grep -qE '_install_cleaned' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qE '_install_cleaned' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    grep -qE '_manage_cleaned' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    grep -qE '_manage_cleaned' "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
}

@test "B1 source: restore installs its own INT/TERM rollback hook and clears it" {
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        run grep -E "_restore_cleanup; exit 130' INT" "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ] || { echo "$f restore missing INT rollback hook"; false; }
        run grep -E "_restore_cleanup; exit 143' TERM" "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ] || { echo "$f restore missing TERM rollback hook"; false; }
        # _restore_cleanup must clear RETURN and RESTORE the global INT/TERM
        # handlers (not reset them to default), so B1 survives a restore.
        run grep -E 'trap - RETURN$' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ] || { echo "$f restore does not clear RETURN"; false; }
        run grep -cE "_manage_on_signal 1(30|43)'" "$BATS_TEST_DIRNAME/../$f"
        # 2 global installs + 2 re-arms inside _restore_cleanup = 4 occurrences.
        [ "$output" -ge 4 ] || { echo "$f does not re-arm global signal handlers after restore"; false; }
    done
}
