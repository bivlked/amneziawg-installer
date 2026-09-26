#!/usr/bin/env bats
# initialize_setup(): a failed write of awgsetup_cfg.init must not replace the
# working file.
#
# The installer renders the init into a temp file next to it and publishes it
# with mv (atomic rename). If the heredoc write fails (ENOSPC, EFBIG), the temp
# file is empty or cut short; publishing it drops AWG_Jc/S1-S4/H1-H4, and the
# next run (after the step-1/step-2 reboot) regenerates the whole obfuscation
# set - every issued client stops connecting.
#
# The save block is cut out of the shipped script between its two log lines
# (no line numbers) and run in a child shell with a 1 KiB file-size limit and
# SIGXFSZ ignored, so the write gets EFBIG. Expected: non-zero exit, the old
# init byte-for-byte intact, no temp file left behind.

load test_helper

INSTALL_RU="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
INSTALL_EN="$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"

# Save block of initialize_setup() in $1: from the line containing $2 up to the
# line containing $3, exactly as the installer executes it.
save_block_from() {
    awk -v a="$2" -v b="$3" 'index($0, a) { f = 1 } f { print } f && index($0, b) { exit }' "$1"
}

# Run the save block of $1 (markers $2/$3) against $CONFIG_FILE in a child shell.
# $4 = "limit" applies the 1 KiB file-size limit, anything else runs unlimited.
run_save_block() {
    local block
    block=$(save_block_from "$1" "$2" "$3")
    [[ "$block" == *'cat > "$temp_conf" << EOF'* ]] || { echo "save block not found in $1"; return 1; }
    [[ "$block" == *'mv "$temp_conf" "$CONFIG_FILE"'* ]] || { echo "save block of $1 has no mv"; return 1; }
    # I1 of a realistic length; the control tests below assert that the rendered
    # init is above the 1 KiB limit, so the limited run really cuts the write.
    local i1
    i1="<b 0x$(printf '%0160d' 0)>"
    run bash -c '
        log() { :; }; log_warn() { :; }; log_error() { :; }
        die() { echo "DIE: $1"; exit 1; }
        _install_temp_files=()
        CONFIG_FILE="$2"
        PREV_AWG_PORT=""
        OS_ID=ubuntu OS_VERSION=24.04 OS_CODENAME=noble
        AWG_PORT=39743 AWG_TUNNEL_SUBNET=10.9.9.1/24 DISABLE_IPV6=1
        ALLOWED_IPS_MODE=1 ALLOWED_IPS=0.0.0.0/0 AWG_ENDPOINT=203.0.113.10
        AWG_Jc=6 AWG_Jmin=55 AWG_Jmax=380 AWG_S1=72 AWG_S2=56 AWG_S3=32 AWG_S4=16
        AWG_H1=100000-800000 AWG_H2=1000000-8000000
        AWG_H3=10000000-80000000 AWG_H4=100000000-800000000
        AWG_I1="$3" NO_TWEAKS=0 NO_CPS=0 IPV6_SUBNET="" AWG_PROTOCOL=2.0
        eval "save_block() {
$1
}"
        if [[ "$4" == limit ]]; then
            trap "" XFSZ
            ulimit -f 1
        fi
        save_block
    ' _ "$block" "$CONFIG_FILE" "$i1" "$4"
}

# Pre-existing working init with known content, and its reference copy outside
# the config directory.
make_working_init() {
    CONFIG_FILE="$TEST_DIR/cfg/awgsetup_cfg.init"
    mkdir -p "$TEST_DIR/cfg"
    printf "export AWG_PORT=51820\nexport AWG_Jc=4\nexport AWG_H1='1-2'\n" > "$CONFIG_FILE"
    cp "$CONFIG_FILE" "$TEST_DIR/reference.init"
}

assert_failed_write_keeps_init() {
    make_working_init
    run_save_block "$1" "$2" "$3" limit
    [ "$status" -ne 0 ] || {
        echo "save block returned 0 on a failed write ($1): $output"
        echo "working init now $(wc -c < "$CONFIG_FILE") bytes (was $(wc -c < "$TEST_DIR/reference.init")), last line: $(tail -n 1 "$CONFIG_FILE")"
        return 1
    }
    [[ "$output" == *"DIE: "* ]] || { echo "save block did not die ($1): $output"; return 1; }
    cmp "$TEST_DIR/reference.init" "$CONFIG_FILE" \
        || { echo "working init replaced ($1), now $(wc -c < "$CONFIG_FILE") bytes"; return 1; }
    local left
    left=$(ls -A "$TEST_DIR/cfg")
    [ "$left" = "awgsetup_cfg.init" ] || { echo "files left in the config dir ($1): $left"; return 1; }
}

assert_normal_write_publishes() {
    make_working_init
    run_save_block "$1" "$2" "$3" nolimit
    [ "$status" -eq 0 ] || { echo "save block failed without a limit ($1): $output"; return 1; }
    # The rendered init must exceed the 1 KiB limit, or the limited run proves nothing.
    [ "$(wc -c < "$CONFIG_FILE")" -gt 1024 ] || { echo "rendered init is not above 1 KiB ($1)"; return 1; }
    grep -qxF "export AWG_H4='100000000-800000000'" "$CONFIG_FILE" || { echo "H4 missing ($1)"; return 1; }
    grep -qxF "export AWG_PROTOCOL='2.0'" "$CONFIG_FILE" || { echo "marker missing ($1)"; return 1; }
    local left
    left=$(ls -A "$TEST_DIR/cfg")
    [ "$left" = "awgsetup_cfg.init" ] || { echo "files left in the config dir ($1): $left"; return 1; }
}

@test "init write failure (RU): EFBIG on the init heredoc dies and keeps the working awgsetup_cfg.init" {
    assert_failed_write_keeps_init "$INSTALL_RU" 'log "Сохранение настроек в $CONFIG_FILE..."' 'log "Настройки сохранены."'
}

@test "init write failure (EN): EFBIG on the init heredoc dies and keeps the working awgsetup_cfg.init" {
    assert_failed_write_keeps_init "$INSTALL_EN" 'log "Saving settings to $CONFIG_FILE..."' 'log "Settings saved."'
}

@test "init write (RU): without the limit the save block publishes a full init above 1 KiB" {
    assert_normal_write_publishes "$INSTALL_RU" 'log "Сохранение настроек в $CONFIG_FILE..."' 'log "Настройки сохранены."'
}

@test "init write (EN): without the limit the save block publishes a full init above 1 KiB" {
    assert_normal_write_publishes "$INSTALL_EN" 'log "Saving settings to $CONFIG_FILE..."' 'log "Settings saved."'
}
