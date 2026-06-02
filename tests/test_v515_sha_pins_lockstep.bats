#!/usr/bin/env bats
# SHA256 pin lockstep test (5.15.x line).
#
# The installers (install_amneziawg.sh / install_amneziawg_en.sh) download the
# helper scripts over the network and verify them against hardcoded pins
# (COMMON_SCRIPT_SHA256 / MANAGE_SCRIPT_SHA256). If any pin drifts from the
# actual file hash, secure-download refuses the install. The existing
# "SCRIPT_VERSION is consistent" test only compares version strings, not the
# pins, so a partial sequential bump could ship a broken installer.
#
# This test computes the real sha256 of all four helper scripts and asserts
# each of the four pinned values matches. Keep it green before any tag push;
# scripts/update-sha-pins.sh --verify provides the same gate for CI.

# ---------- RU installer pins ----------

@test "RU installer COMMON pin matches awg_common.sh" {
    actual=$(sha256sum "$BATS_TEST_DIRNAME/../awg_common.sh" | cut -d' ' -f1)
    pinned=$(grep -oP 'COMMON_SCRIPT_SHA256="\K[0-9a-f]{64}' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    [ "$actual" = "$pinned" ] || {
        echo "RU COMMON pin mismatch: pinned=$pinned actual=$actual (awg_common.sh)" >&2
        false
    }
}

@test "RU installer MANAGE pin matches manage_amneziawg.sh" {
    actual=$(sha256sum "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" | cut -d' ' -f1)
    pinned=$(grep -oP 'MANAGE_SCRIPT_SHA256="\K[0-9a-f]{64}' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    [ "$actual" = "$pinned" ] || {
        echo "RU MANAGE pin mismatch: pinned=$pinned actual=$actual (manage_amneziawg.sh)" >&2
        false
    }
}

# ---------- EN installer pins ----------

@test "EN installer COMMON pin matches awg_common_en.sh" {
    actual=$(sha256sum "$BATS_TEST_DIRNAME/../awg_common_en.sh" | cut -d' ' -f1)
    pinned=$(grep -oP 'COMMON_SCRIPT_SHA256="\K[0-9a-f]{64}' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh")
    [ "$actual" = "$pinned" ] || {
        echo "EN COMMON pin mismatch: pinned=$pinned actual=$actual (awg_common_en.sh)" >&2
        false
    }
}

@test "EN installer MANAGE pin matches manage_amneziawg_en.sh" {
    actual=$(sha256sum "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh" | cut -d' ' -f1)
    pinned=$(grep -oP 'MANAGE_SCRIPT_SHA256="\K[0-9a-f]{64}' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh")
    [ "$actual" = "$pinned" ] || {
        echo "EN MANAGE pin mismatch: pinned=$pinned actual=$actual (manage_amneziawg_en.sh)" >&2
        false
    }
}
