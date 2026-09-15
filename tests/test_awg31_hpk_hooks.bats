#!/usr/bin/env bats
# Third-line profile, part two: where the header protection key check runs.
#
# awg_hpk_ensure has to run before anything writes or renders a profile:
#   - load_awg_params is the common entry of render_server_config,
#     render_client_config, generate_vpn_uri, generate_client and regenerate_client,
#     so it checks the key whenever a live server config exists, and also on the
#     CLI override branch that skips reading parameters from that config;
#   - modify_client rewrites the client .conf and deletes its QR and vpn:// before it
#     ever reaches load_awg_params, so it checks right after taking its lock;
#   - step 6 of the installer checks in install mode (the only mode allowed to
#     generate a key) before render_server_config, and dies on a refusal.
# Behaviour is exercised for load_awg_params; the two call sites that need a whole
# manage or installer run are pinned by position in the source of both twins, and
# the mutation run checks that the pins bite.

KEY_A="QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQA="

dir_of() { echo "$BATS_TEST_TMPDIR/awg-$(basename "$1" .sh)"; }
ru() { [[ "$1" != *_en.sh ]]; }

lib_run() {
    local lib="$1" snippet="$2"
    AWG_DIR="$(dir_of "$lib")" timeout 60 bash -c '
        mkdir -p "$AWG_DIR"
        export CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init" SERVER_CONF_FILE="$AWG_DIR/awg0.conf"
        log() { echo "INFO: $*"; }; log_warn() { echo "WARN: $*"; }
        log_error() { echo "ERR: $*"; }; log_debug() { :; }
        source "$1" >/dev/null 2>&1 || true
        eval "$2"
    ' _ "$lib" "$snippet"
}

both_libs() {
    local seen=0 lib
    for lib in "$BATS_TEST_DIRNAME/../awg_common.sh" "$BATS_TEST_DIRNAME/../awg_common_en.sh"; do
        rm -rf "$(dir_of "$lib")"; mkdir -p "$(dir_of "$lib")"
        "$1" "$lib" || return 1
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}

setup_pair() {
    local d; d=$(dir_of "$1")
    printf "export AWG_PORT=39743\nexport AWG_PROTOCOL='%s'\n" "$2" > "$d/awgsetup_cfg.init"
    {
        printf '[Interface]\nPrivateKey = TESTKEY\nListenPort = 39743\nJc = 6\nJmin = 55\nJmax = 380\n'
        printf 'S1 = 72\nS2 = 56\nS3 = 32\nS4 = 16\n'
        printf 'H1 = 100000-800000\nH2 = 1000000-8000000\nH3 = 10000000-80000000\nH4 = 100000000-800000000\n'
        [[ -n "${3:-}" ]] && printf 'HeaderProtectionKey = %s\n' "$3"
        printf '\n[Peer]\n#_Name = my_phone\nPublicKey = PEERPUB\nAllowedIPs = 10.9.9.2/32\n'
    } > "$d/awg0.conf"
}

h_load_20_plain() {
    setup_pair "$1" 2.0
    run lib_run "$1" 'load_awg_params'
    [ "$status" -eq 0 ] || { echo "a plain 2.0 install no longer loads ($1): $output"; return 1; }
}
@test "hooks: load_awg_params on a plain 2.0 install is unchanged, both twins" {
    both_libs h_load_20_plain
}

h_load_20_key() {
    local want="but the installation is marked as generation 2.0"
    ru "$1" && want="а установка помечена поколением 2.0"
    run lib_run "$1" 'declare -F awg_hpk_ensure >/dev/null || { echo NO_ENSURE; exit 7; }'
    [ "$status" -eq 0 ] || { echo "awg_hpk_ensure is not defined ($1)"; return 1; }
    setup_pair "$1" 2.0 "$KEY_A"
    run lib_run "$1" 'load_awg_params'
    [ "$status" -eq 1 ] || { echo "load_awg_params let a 2.0 install with a key through ($1): $output"; return 1; }
    [[ "$output" == *"$want"* ]] || { echo "wrong reason ($1), expected '$want': $output"; return 1; }
    [[ "$output" != *"$KEY_A"* ]] || { echo "key value printed ($1)"; return 1; }
}
@test "hooks: load_awg_params refuses a 2.0 install whose live config holds a key, both twins" {
    both_libs h_load_20_key
}

h_load_cli_override() {
    local want="but the installation is marked as generation 2.0"
    ru "$1" && want="а установка помечена поколением 2.0"
    setup_pair "$1" 2.0 "$KEY_A"
    run lib_run "$1" 'export CLI_PRESET=default AWG_Jc=6 AWG_Jmin=55 AWG_Jmax=380 AWG_S1=72 AWG_S2=56 AWG_S3=32 AWG_S4=16 AWG_H1=100000-800000 AWG_H2=1000000-8000000 AWG_H3=10000000-80000000 AWG_H4=100000000-800000000; load_awg_params'
    [ "$status" -eq 1 ] || { echo "the CLI override branch skipped the key check ($1): $output"; return 1; }
    [[ "$output" == *"$want"* ]] || { echo "wrong reason ($1), expected '$want': $output"; return 1; }
}
@test "hooks: the CLI override branch of load_awg_params still checks the key, both twins" {
    both_libs h_load_cli_override
}

# first_line <file> <fixed string> [after line] : number of the first line at or after
# the given line that contains the string, or 0.
first_line() {
    awk -v s="$2" -v from="${3:-1}" 'NR >= from && index($0, s) { print NR; found = 1; exit } END { if (!found) print 0 }' "$1"
}

h_modify_order() {
    local src="$1" start lock ensure write
    start=$(first_line "$src" "modify_client() {")
    lock=$(first_line "$src" 'flock -x -w 10 "$modify_lock_fd"' "$start")
    ensure=$(first_line "$src" "awg_hpk_ensure manage" "$start")
    write=$(first_line "$src" 'sed -i "s#^${param}' "$start")
    [ "$start" -gt 0 ] && [ "$lock" -gt 0 ] && [ "$write" -gt 0 ] || { echo "anchors not found in $src: start=$start lock=$lock write=$write"; return 1; }
    [ "$ensure" -gt "$lock" ] || { echo "modify checks the key before taking its lock or not at all ($src): lock=$lock ensure=$ensure"; return 1; }
    [ "$ensure" -lt "$write" ] || { echo "modify checks the key after its first write ($src): ensure=$ensure write=$write"; return 1; }
    local del; del=$(first_line "$src" 'rm -f "$_df"' "$start")
    [ "$del" -eq 0 ] || [ "$ensure" -lt "$del" ] || { echo "modify checks the key after deleting derived files ($src)"; return 1; }
}
@test "hooks: modify checks the key after its lock and before any write, both manage twins" {
    local seen=0 src
    for src in "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"; do
        h_modify_order "$src" || return 1
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}

h_step6_order() {
    local src="$1" start ensure render
    start=$(first_line "$src" "step6_generate_configs() {")
    ensure=$(first_line "$src" "awg_hpk_ensure install" "$start")
    render=$(first_line "$src" 'render_server_config "${s_bak:-}"' "$start")
    [ "$start" -gt 0 ] && [ "$render" -gt 0 ] || { echo "anchors not found in $src"; return 1; }
    [ "$ensure" -gt "$start" ] && [ "$ensure" -lt "$render" ] || { echo "step 6 does not check the key before rendering ($src): ensure=$ensure render=$render"; return 1; }
    sed -n "${ensure}p" "$src" | grep -q '|| die' || { echo "a refused key check does not stop step 6 ($src): $(sed -n "${ensure}p" "$src")"; return 1; }
}
@test "hooks: step 6 checks the key in install mode before rendering and dies on refusal, both installers" {
    local seen=0 src
    for src in "$BATS_TEST_DIRNAME/../install_amneziawg.sh" "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"; do
        h_step6_order "$src" || return 1
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}
