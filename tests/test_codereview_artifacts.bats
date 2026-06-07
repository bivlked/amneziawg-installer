#!/usr/bin/env bats
# Code-review findings A3 (.vpnuri atomic write), A4 (QR PNG via awg_mktemp),
# B2 (expiry cleanup must drop .vpnuri.png; shared client-artifact helper).

load test_helper

@test "B2 _remove_client_files: removes all six artifacts incl .vpnuri.png" {
    local n=alice
    : > "$AWG_DIR/$n.conf"
    : > "$AWG_DIR/$n.png"
    : > "$AWG_DIR/$n.vpnuri"
    : > "$AWG_DIR/$n.vpnuri.png"
    : > "$KEYS_DIR/$n.private"
    : > "$KEYS_DIR/$n.public"

    run _remove_client_files "$n"
    [ "$status" -eq 0 ]
    for ext in conf png vpnuri vpnuri.png; do
        [ ! -e "$AWG_DIR/$n.$ext" ] || { echo "left behind: $n.$ext"; false; }
    done
    [ ! -e "$KEYS_DIR/$n.private" ]
    [ ! -e "$KEYS_DIR/$n.public" ]
}

@test "B2 _remove_client_files: defined in both awg_common scripts" {
    for f in awg_common.sh awg_common_en.sh; do
        run grep -E '^_remove_client_files\(\) \{' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ] || { echo "$f missing _remove_client_files"; false; }
        run grep -E '\$\{name\}\.vpnuri\.png' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ] || { echo "$f helper omits .vpnuri.png"; false; }
    done
}

@test "B2 expiry cleanup and manage remove both call _remove_client_files" {
    for f in awg_common.sh awg_common_en.sh; do
        run grep -E '_remove_client_files "\$name"' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ] || { echo "$f expiry cleanup not using helper"; false; }
    done
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        run grep -E '_remove_client_files "\$_rname"' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ] || { echo "$f manage remove not using helper"; false; }
    done
}

@test "A3 source: generate_vpn_uri writes .vpnuri via awg_mktemp + atomic mv" {
    for f in awg_common.sh awg_common_en.sh; do
        # No direct redirect into the final .vpnuri file anymore.
        run grep -E '"\$vpn_uri" > "\$uri_file"' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -ne 0 ] || { echo "$f still writes .vpnuri non-atomically"; false; }
        run grep -E 'mv -f "\$_uri_tmp" "\$uri_file"' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ] || { echo "$f missing atomic mv for .vpnuri"; false; }
    done
}

@test "A4 source: QR PNGs use awg_mktemp (no manual .tmp.\$\$)" {
    for f in awg_common.sh awg_common_en.sh; do
        run grep -F '${png_file}.tmp.$$' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -ne 0 ] || { echo "$f still uses manual .tmp.\$\$ for QR"; false; }
        # Both QR functions must obtain tmp_png from awg_mktemp.
        run grep -cE 'tmp_png=\$\(awg_mktemp "\$AWG_DIR"\)' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ]
        [ "$output" -ge 2 ] || { echo "$f: expected 2 awg_mktemp QR sites, got $output"; false; }
    done
}
