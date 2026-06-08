#!/usr/bin/env bats
# Code-review findings A1 (--expires atomicity) and A2 (--psk fail-closed).
#
# A1: `manage add --expires=...` incremented the added-client counter regardless
#   of set_client_expiry's result and never validated the duration up front, so
#   `--expires=bad` created PERMANENT clients while expiry silently failed. The
#   fix validates the format once before the loop (aborts before any change) and
#   flags a non-zero return if the post-create expiry write fails.
# A2: `generate_client` with CLIENT_PSK=auto (set only by --psk) degraded to a
#   PSK-less client on `awg genpsk` failure. It now fails closed (return 1).

load test_helper

@test "A1 parse_duration: rejects bad formats, accepts valid units" {
    for bad in bad 1 1x 12 h "" "-1h" "1 h" "1.5h"; do
        run parse_duration "$bad"
        [ "$status" -ne 0 ] || { echo "accepted invalid duration: $bad"; false; }
    done
    for ok in 1h 12h 1d 7d 4w; do
        run parse_duration "$ok"
        [ "$status" -eq 0 ] || { echo "rejected valid duration: $ok"; false; }
    done
}

@test "A1 source: add validates --expires before the client loop (die on bad format)" {
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        # The upfront guard must call parse_duration and die before the loop.
        run grep -E 'parse_duration "\$EXPIRES_DURATION" >/dev/null' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ] || { echo "$f missing upfront --expires validation"; false; }
        # That guard must sit before the add loop, not inside it.
        local guard_line loop_line
        guard_line=$(grep -n 'parse_duration "\$EXPIRES_DURATION" >/dev/null' "$BATS_TEST_DIRNAME/../$f" | head -1 | cut -d: -f1)
        loop_line=$(grep -n '_added=0' "$BATS_TEST_DIRNAME/../$f" | head -1 | cut -d: -f1)
        [ "$guard_line" -lt "$loop_line" ] || { echo "$f: --expires guard not before add loop"; false; }
    done
}

@test "A1 source: post-create expiry failure sets a non-zero command result" {
    # The set_client_expiry if/else block must flag _cmd_rc=1 on failure, and the
    # cron-install rc inside the then-branch must also be checked (review finding #3).
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        local block
        block=$(grep -A10 'if set_client_expiry "\$_cname" "\$EXPIRES_DURATION"; then' "$BATS_TEST_DIRNAME/../$f")
        echo "$block" | grep -q 'else' || { echo "$f: no else on set_client_expiry"; false; }
        echo "$block" | grep -q '_cmd_rc=1' || { echo "$f: expiry failure does not set _cmd_rc=1"; false; }
        echo "$block" | grep -qE 'install_expiry_cron \|\|' || { echo "$f: cron-install rc not checked"; false; }
    done
}

@test "A2 source: generate_client fails closed on awg genpsk failure (no silent PSK-less client)" {
    for f in awg_common.sh awg_common_en.sh; do
        # The old silent-degradation warning must be gone.
        run grep -E 'будет создан без PresharedKey|will be created without PresharedKey' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -ne 0 ] || { echo "$f still degrades to PSK-less client"; false; }
        # The auto branch must no longer reset CLIENT_PSK to empty on failure.
        run grep -E 'awg genpsk\) \|\| \{' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ]
        # And it must carry a fail-closed return inside generate_client.
        run grep -E 'NOT created|НЕ создан' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ] || { echo "$f missing fail-closed PSK error"; false; }
    done
}

@test "A2 source: auto-PSK failure path returns 1 (not CLIENT_PSK=\"\")" {
    for f in awg_common.sh awg_common_en.sh; do
        run grep -Pzo 'awg genpsk\) \|\| \{[^}]*return 1' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ] || { echo "$f auto-PSK failure does not return 1"; false; }
    done
}
