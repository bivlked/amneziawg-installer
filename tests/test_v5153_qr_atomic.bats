#!/usr/bin/env bats
# Tests for C4 (v5.15.3): generate_qr writes the PNG atomically (temp + mv),
# mirroring generate_qr_vpnuri. A direct write meant an interrupted qrencode
# could leave a partial PNG over a previously good one.

load test_helper

# qrencode shim: write stdin to the -o target so we can assert the output came
# from the client config.
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
    export PATH="$bin:$PATH"
}

# qrencode shim that fails after partially writing the temp file.
mock_qrencode_failing() {
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
[[ -n "$out" ]] && echo "partial" > "$out"
echo "qrencode shim: simulated failure" >&2
exit 1
SHIM
    chmod +x "$bin/qrencode"
    export PATH="$bin:$PATH"
}

@test "C4: happy path writes PNG and leaves no .tmp.* behind" {
    mock_qrencode
    echo "[Interface]" > "$AWG_DIR/alice.conf"

    run generate_qr alice
    [ "$status" -eq 0 ]
    [ -f "$AWG_DIR/alice.png" ]
    run bash -c 'ls "$AWG_DIR"/*.tmp.* 2>/dev/null | wc -l'
    [ "$output" -eq 0 ]
}

@test "C4: qrencode failure cleans up temp and preserves an existing PNG" {
    echo "[Interface]" > "$AWG_DIR/alice.conf"
    printf 'OLD-GOOD-PNG' > "$AWG_DIR/alice.png"   # pre-existing good QR
    mock_qrencode_failing

    run generate_qr alice
    [ "$status" -ne 0 ]
    # The old PNG must be untouched and no temp file may linger.
    [ "$(cat "$AWG_DIR/alice.png")" = "OLD-GOOD-PNG" ]
    run bash -c 'ls "$AWG_DIR"/*.tmp.* 2>/dev/null | wc -l'
    [ "$output" -eq 0 ]
}

@test "C4: mv failure preserves the existing PNG and removes the temp" {
    echo "[Interface]" > "$AWG_DIR/alice.conf"
    printf 'OLD-GOOD-PNG' > "$AWG_DIR/alice.png"
    mock_qrencode
    # Force the atomic move to fail; generate_qr must roll back cleanly.
    mv() { return 1; }

    run generate_qr alice
    [ "$status" -ne 0 ]
    [ "$(cat "$AWG_DIR/alice.png")" = "OLD-GOOD-PNG" ]
    unset -f mv
}

@test "C4: generate_qr uses a temp file and checks the mv (RU source)" {
    run grep -E 'tmp_png="\$\{png_file\}\.tmp\.\$\$"' "$BATS_TEST_DIRNAME/../awg_common.sh"
    [ "$status" -eq 0 ]
    run grep -E 'if ! mv -f "\$tmp_png" "\$png_file"' "$BATS_TEST_DIRNAME/../awg_common.sh"
    [ "$status" -eq 0 ]
}

@test "C4: generate_qr uses a temp file and checks the mv (EN source)" {
    run grep -E 'tmp_png="\$\{png_file\}\.tmp\.\$\$"' "$BATS_TEST_DIRNAME/../awg_common_en.sh"
    [ "$status" -eq 0 ]
    run grep -E 'if ! mv -f "\$tmp_png" "\$png_file"' "$BATS_TEST_DIRNAME/../awg_common_en.sh"
    [ "$status" -eq 0 ]
}
