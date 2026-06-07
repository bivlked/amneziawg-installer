#!/usr/bin/env bats
# Tests for generate_qr_vpnuri helper (v5.11.2).
#
# The helper renders <name>.vpnuri.png from <name>.vpnuri so that users can
# one-tap-import a client into the Amnezia VPN app (Android/iOS/Desktop),
# complementing the existing <name>.png which is scanned by classic
# WireGuard-compatible clients.

load test_helper

# Install a fake qrencode binary in an isolated PATH entry.
# The shim reads stdin (the vpn:// URI) and writes the content to the -o
# target so tests can assert the file was produced from stdin.
mock_qrencode() {
    local bin="$TEST_DIR/bin"
    mkdir -p "$bin"
    cat > "$bin/qrencode" <<'SHIM'
#!/bin/bash
out=""
while (( $# > 0 )); do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -t) shift 2 ;;
        *)  shift ;;
    esac
done
[[ -z "$out" ]] && { echo "qrencode shim: missing -o" >&2; exit 2; }
cat > "$out"
exit 0
SHIM
    chmod +x "$bin/qrencode"
    # Prepend so our shim wins over any system qrencode.
    export PATH="$bin:$PATH"
}

# Install a fake qrencode that always exits non-zero — to exercise the
# error branch of generate_qr_vpnuri.
mock_qrencode_failing() {
    local bin="$TEST_DIR/bin"
    mkdir -p "$bin"
    cat > "$bin/qrencode" <<'SHIM'
#!/bin/bash
echo "qrencode shim: simulated failure" >&2
exit 1
SHIM
    chmod +x "$bin/qrencode"
    export PATH="$bin:$PATH"
}

@test "generate_qr_vpnuri: happy path writes PNG from .vpnuri" {
    mock_qrencode
    echo "vpn://TEST_URI_PAYLOAD" > "$AWG_DIR/foo.vpnuri"

    run generate_qr_vpnuri "foo"
    [ "$status" -eq 0 ]
    [ -f "$AWG_DIR/foo.vpnuri.png" ]
    # Shim round-trips stdin to $out, so we can verify content provenance.
    [ "$(cat "$AWG_DIR/foo.vpnuri.png")" = "vpn://TEST_URI_PAYLOAD" ]
}

@test "generate_qr_vpnuri: fails when .vpnuri missing" {
    mock_qrencode
    rm -f "$AWG_DIR/missing.vpnuri"

    run generate_qr_vpnuri "missing"
    [ "$status" -ne 0 ]
    [ ! -f "$AWG_DIR/missing.vpnuri.png" ]
}

@test "generate_qr_vpnuri: fails when qrencode exits non-zero" {
    mock_qrencode_failing
    echo "vpn://ANY" > "$AWG_DIR/qfail.vpnuri"

    run generate_qr_vpnuri "qfail"
    [ "$status" -ne 0 ]
    [ ! -f "$AWG_DIR/qfail.vpnuri.png" ]
}

@test "generate_qr_vpnuri: atomic - pre-existing PNG preserved when qrencode fails" {
    # Pre-populate a stale .vpnuri.png; a failing qrencode run must leave
    # the old file intact (no half-written replacement, no orphan tmp).
    echo "OLD_PNG_CONTENT" > "$AWG_DIR/atom.vpnuri.png"
    echo "vpn://ANY" > "$AWG_DIR/atom.vpnuri"
    mock_qrencode_failing

    run generate_qr_vpnuri "atom"
    [ "$status" -ne 0 ]
    # Old file must still be there with untouched content.
    [ -f "$AWG_DIR/atom.vpnuri.png" ]
    [ "$(cat "$AWG_DIR/atom.vpnuri.png")" = "OLD_PNG_CONTENT" ]
    # No orphan <name>.vpnuri.png.tmp.* files.
    run compgen -G "$AWG_DIR/atom.vpnuri.png.tmp.*"
    [ "$status" -ne 0 ]
}

@test "generate_qr_vpnuri: chmod 600 on created PNG (Linux/Darwin)" {
    mock_qrencode
    echo "vpn://PERMTEST" > "$AWG_DIR/permtest.vpnuri"

    run generate_qr_vpnuri "permtest"
    [ "$status" -eq 0 ]
    [ -f "$AWG_DIR/permtest.vpnuri.png" ]
    # chmod is a no-op on NTFS via Git Bash / 9p WSL mount — skip there.
    if [[ "$(uname -s)" == "Linux" || "$(uname -s)" == "Darwin" ]]; then
        [ "$(stat -c '%a' "$AWG_DIR/permtest.vpnuri.png")" = "600" ]
    fi
}

@test "generate_qr_vpnuri: both RU and EN have the function with qrencode + .vpnuri.png + command-v guard" {
    local RU_FILE="${BATS_TEST_DIRNAME}/../awg_common.sh"
    local EN_FILE="${BATS_TEST_DIRNAME}/../awg_common_en.sh"
    grep -qE '^generate_qr_vpnuri\(\)' "$RU_FILE"
    grep -qE '^generate_qr_vpnuri\(\)' "$EN_FILE"
    # Body invariants: qrencode call, target .vpnuri.png, command -v guard.
    local ru_body en_body
    ru_body=$(awk '/^generate_qr_vpnuri\(\) \{$/,/^}$/' "$RU_FILE")
    en_body=$(awk '/^generate_qr_vpnuri\(\) \{$/,/^}$/' "$EN_FILE")
    grep -qE 'qrencode'              <<< "$ru_body"
    grep -qE 'qrencode'              <<< "$en_body"
    grep -qE '\.vpnuri\.png'         <<< "$ru_body"
    grep -qE '\.vpnuri\.png'         <<< "$en_body"
    grep -qE 'command -v qrencode'   <<< "$ru_body"
    grep -qE 'command -v qrencode'   <<< "$en_body"
}

@test "generate_client calls generate_qr_vpnuri after successful generate_vpn_uri (RU+EN)" {
    local RU_FILE="${BATS_TEST_DIRNAME}/../awg_common.sh"
    local EN_FILE="${BATS_TEST_DIRNAME}/../awg_common_en.sh"
    awk '/^generate_client\(\) \{$/,/^}$/' "$RU_FILE" | grep -qE 'generate_qr_vpnuri'
    awk '/^generate_client\(\) \{$/,/^}$/' "$EN_FILE" | grep -qE 'generate_qr_vpnuri'
}

@test "regenerate_client calls generate_qr_vpnuri after generate_vpn_uri (RU+EN)" {
    local RU_FILE="${BATS_TEST_DIRNAME}/../awg_common.sh"
    local EN_FILE="${BATS_TEST_DIRNAME}/../awg_common_en.sh"
    awk '/^regenerate_client\(\) \{$/,/^}$/' "$RU_FILE" | grep -qE 'generate_qr_vpnuri'
    awk '/^regenerate_client\(\) \{$/,/^}$/' "$EN_FILE" | grep -qE 'generate_qr_vpnuri'
}

@test "manage regen calls generate_qr_vpnuri (RU+EN scripts)" {
    local RU_MGMT="${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"
    local EN_MGMT="${BATS_TEST_DIRNAME}/../manage_amneziawg_en.sh"
    grep -qE 'generate_qr_vpnuri' "$RU_MGMT"
    grep -qE 'generate_qr_vpnuri' "$EN_MGMT"
}

@test "manage remove cleans up .vpnuri.png (RU+EN scripts)" {
    # Cleanup is now delegated to the shared _remove_client_files helper (which
    # includes .vpnuri.png - asserted in test_codereview_artifacts.bats), so
    # manage remove must call that helper rather than inline-rm the artifacts.
    local RU_MGMT="${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"
    local EN_MGMT="${BATS_TEST_DIRNAME}/../manage_amneziawg_en.sh"
    grep -qE '_remove_client_files "\$_rname"' "$RU_MGMT"
    grep -qE '_remove_client_files "\$_rname"' "$EN_MGMT"
}
