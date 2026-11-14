#!/usr/bin/env bats
# A random UDP port for a new install (ntc t/22685 #35).
#
# Every install used to listen on 39743/udp unless told otherwise, which made
# that port a shared trait of all of them. A first install now picks a random
# free port in 10000-59999, skipping 51820 and 51821 (the WireGuard defaults).
# A reinstall keeps the port from the init file as before, --port and --mobile
# (443) still win, and the final report prints the port.

load test_helper

# fn <installer> <name>: the body of one function from an installer.
fn() { awk "/^$2\\(\\) \\{/,/^\\}/" "$BATS_TEST_DIRNAME/../$1"; }

# pick <installer> <rand sequence>: run _awg_default_port with rand_range
# answering the given numbers in turn and ss listing the ports in $BUSY.
pick() {
    local src="$1" seq="$2"
    run bash -c '
        log() { :; }; log_warn() { echo "WARN: $*" >&2; }
        '"$(fn "$src" _awg_pick_random_port)"'
        '"$(fn "$src" _awg_default_port)"'
        i=0; read -ra SEQ <<< "$1"
        rand_range() { [[ "$1" == 10000 && "$2" == 59999 ]] || { echo "bad range $1 $2" >&2; exit 9; }
                       local f="$BATS_TMP/rand_i"; local k; k=$(cat "$f" 2>/dev/null || echo 0)
                       echo $((k + 1)) > "$f"; echo "${SEQ[$k]:-12345}"; }
        ss() { local p; for p in $BUSY; do printf "UNCONN 0 0 0.0.0.0:%s 0.0.0.0:*\n" "$p"; done; }
        CONFIG_FILE="$BATS_TMP/none.init"
        _awg_default_port
    ' _ "$seq"
}

setup() {
    export BATS_TMP="$BATS_TEST_TMPDIR"
    rm -f "$BATS_TMP/rand_i"
}

both() {
    local seen=0 s
    for s in install_amneziawg.sh install_amneziawg_en.sh; do
        rm -f "$BATS_TMP/rand_i"
        "$1" "$s" || return 1
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}

_first_install_random() {
    pick "$1" "23456"
    [ "$status" -eq 0 ] || { echo "$1: status $status: $output"; return 1; }
    [ "$output" = "23456" ] || { echo "$1: picked '$output', want 23456"; return 1; }
}
@test "a first install takes the random port, both twins" {
    export BUSY=""
    both _first_install_random
}

_skips_wireguard_and_busy() {
    pick "$1" "51820 51821 34567 45678"
    [ "$status" -eq 0 ] || { echo "$1: status $status: $output"; return 1; }
    [ "$output" = "45678" ] || { echo "$1: picked '$output', want 45678 after 51820, 51821 and busy 34567"; return 1; }
}
@test "the random port skips 51820, 51821 and a busy port, both twins" {
    export BUSY="34567"
    both _skips_wireguard_and_busy
}

_reinstall_keeps_old_default() {
    run bash -c '
        log() { :; }; log_warn() { :; }
        '"$(fn "$1" _awg_pick_random_port)"'
        '"$(fn "$1" _awg_default_port)"'
        rand_range() { echo 23456; }
        ss() { :; }
        CONFIG_FILE="$BATS_TMP/exists.init"; : > "$CONFIG_FILE"
        _awg_default_port
    '
    [ "$status" -eq 0 ] || { echo "$1: status $status"; return 1; }
    [ "$output" = "39743" ] || { echo "$1: with an init file the fallback is '$output', want 39743"; return 1; }
}
@test "with an init file the fallback stays 39743 (the init port wins anyway), both twins" {
    both _reinstall_keeps_old_default
}

_no_free_port_falls_back() {
    run bash -c '
        log() { :; }; log_warn() { echo "WARN: $*" >&2; }
        '"$(fn "$1" _awg_pick_random_port)"'
        '"$(fn "$1" _awg_default_port)"'
        rand_range() { echo 51820; }
        ss() { :; }
        CONFIG_FILE="$BATS_TMP/none.init"
        _awg_default_port 2>&1
    '
    [ "$status" -eq 0 ] || { echo "$1: status $status"; return 1; }
    [[ "$output" == *"WARN:"* ]] || { echo "$1: no warning when no random port was found: $output"; return 1; }
    [ "$(tail -n1 <<< "$output")" = "39743" ] || { echo "$1: fallback '$output'"; return 1; }
}
@test "when no random port is found, the fallback is 39743 with a warning, both twins" {
    both _no_free_port_falls_back
}

@test "the real picker stays inside 10000-59999 and never returns 51820 or 51821" {
    local s p
    for s in install_amneziawg.sh install_amneziawg_en.sh; do
        for _ in $(seq 1 200); do
            p=$(bash -c "$(fn "$s" rand_range)"$'\n'"ss() { :; }"$'\n'"$(fn "$s" _awg_pick_random_port)"$'\n''_awg_pick_random_port')
            [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 10000 && p <= 59999 && p != 51820 && p != 51821 )) \
                || { echo "$s: bad port '$p'"; return 1; }
        done
    done
}

@test "initialize_setup takes its default port from _awg_default_port, both twins" {
    local s
    for s in install_amneziawg.sh install_amneziawg_en.sh; do
        fn "$s" initialize_setup | grep -qE '^\s+default_port=\$\(_awg_default_port\)$' \
            || { echo "$s: initialize_setup does not use _awg_default_port"; return 1; }
        fn "$s" initialize_setup | grep -qE 'local default_port=39743' \
            && { echo "$s: the fixed default is still there"; return 1; }
        true
    done
}

@test "the final report prints the VPN port, both twins" {
    local s
    for s in install_amneziawg.sh install_amneziawg_en.sh; do
        run bash -c '
            log() { echo "$*"; }; log_warn() { echo "$*"; }; log_error() { echo "$*"; }
            _awg_generation_summary() { echo 3.1; }; cleanup_apt() { :; }
            '"$(fn "$s" step99_finish)"'
            CONFIG_FILE=/nonexistent STATE_FILE="$BATS_TMP/st" LOG_FILE=/dev/null AWG_DIR=/root/awg
            AWG_PROTOCOL=3.1 AWG_PORT=23456 MANAGE_SCRIPT_PATH=/root/awg/manage_amneziawg.sh
            step99_finish
        '
        [[ "$output" == *"23456/udp"* ]] || { echo "$s: the report does not name the port: $output"; return 1; }
    done
}

# ---------- --uninstall: which UFW port rules it removes ----------

# uports <installer> <init lines> <awg0.conf lines>: ports _awg_uninstall_ports
# names; "-" for an init or a server config that does not exist.
uports() {
    local src="$1" init="$2" conf="$3" d="$BATS_TMP/up"
    rm -rf "$d"; mkdir -p "$d"
    [[ "$init" == "-" ]] || printf '%s\n' "$init" > "$d/awgsetup_cfg.init"
    [[ "$conf" == "-" ]] || printf '%s\n' "$conf" > "$d/awg0.conf"
    run bash -c '
        '"$(fn "$src" safe_read_config_key)"'
        '"$(fn "$src" _awg_uninstall_ports)"'
        CONFIG_FILE="$1/awgsetup_cfg.init"; SERVER_CONF_FILE="$1/awg0.conf"
        _awg_uninstall_ports
    ' _ "$d"
}

_uninstall_ports_cases() {
    uports "$1" $'export AWG_PORT=23456' $'[Interface]\nListenPort = 23456'
    [ "$output" = "23456" ] || { echo "$1: same port twice gave '$output'"; return 1; }
    uports "$1" $'export AWG_PORT=23456\nexport PREV_AWG_PORT=34567' $'[Interface]\nListenPort = 45678'
    [ "$output" = "23456 34567 45678" ] || { echo "$1: init, deferred and live port gave '$output'"; return 1; }
    uports "$1" - $'[Interface]\nListenPort = 45678\r'
    [ "$output" = "45678" ] || { echo "$1: no init, CRLF conf gave '$output'"; return 1; }
    uports "$1" - -
    [ "$output" = "" ] || { echo "$1: nothing to read gave '$output' (the old code fell back to 39743)"; return 1; }
    uports "$1" $'export AWG_PORT=99999' $'[Interface]\nListenPort = abc'
    [ "$output" = "" ] || { echo "$1: invalid values gave '$output'"; return 1; }
    # The live port is read the way awg applies it: a comment after '#' dropped,
    # the last of several lines, the key in any case.
    uports "$1" - $'[Interface]\nListenPort = 45678   # moved'
    [ "$output" = "45678" ] || { echo "$1: a commented ListenPort gave '$output'"; return 1; }
    uports "$1" - $'[Interface]\nListenPort = 45678\nListenPort = 45679'
    [ "$output" = "45679" ] || { echo "$1: two ListenPort lines gave '$output', want the last"; return 1; }
    uports "$1" - $'[Interface]\nlistenport = 45678'
    [ "$output" = "45678" ] || { echo "$1: a lowercase key gave '$output'"; return 1; }
}
@test "--uninstall removes the init port, a deferred old port and the live ListenPort, never a guessed 39743, both twins" {
    both _uninstall_ports_cases
}

@test "step_uninstall deletes the UFW rule of every port from _awg_uninstall_ports, both twins" {
    local s
    for s in install_amneziawg.sh install_amneziawg_en.sh; do
        fn "$s" step_uninstall | grep -qE '_uports=\$\(_awg_uninstall_ports\)' \
            && fn "$s" step_uninstall | grep -qE 'for _uport in \$_uports; do' \
            || { echo "$s: step_uninstall does not loop over _awg_uninstall_ports"; return 1; }
        fn "$s" step_uninstall | grep -qF 'port_to_del:-39743' \
            && { echo "$s: the guessed 39743 is still there"; return 1; }
        true
    done
}