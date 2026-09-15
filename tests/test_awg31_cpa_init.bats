#!/usr/bin/env bats
# Third-line profile, part two: ContentPaddingAddition travels like the other
# obfuscation parameters.
#
# The 3.1 generator exports AWG_CPA, and step 6 renders from what init and the live
# config provide, so the value has to survive both paths:
#   - init: the heredoc writes AWG_CPA, and every safe_load_config copy (library and
#     installer, both languages) accepts the key, or it would be written and never read;
#   - live config: load_awg_params_from_server_conf reads ContentPaddingAddition
#     (case-insensitive, as the tools read it), and load_awg_params drops a stale
#     AWG_CPA before parsing a live config that has none, like it does for I1-I5;
#   - drift: AWG_CPA edited in init after install is reported like the others.

dir_of() { echo "$BATS_TEST_TMPDIR/cpa-$(basename "$1" .sh)"; }

lib_run() {
    local lib="$1" snippet="$2"
    AWG_DIR="$(dir_of "$lib")" timeout 60 bash -c '
        mkdir -p "$AWG_DIR"
        export CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init" SERVER_CONF_FILE="$AWG_DIR/awg0.conf"
        log() { :; }; log_warn() { :; }; log_error() { echo "ERR: $*"; }; log_debug() { :; }
        source "$1" >/dev/null 2>&1 || true
        eval "$2"
    ' _ "$lib" "$snippet"
}

each_lib() {
    local seen=0 lib
    for lib in "$BATS_TEST_DIRNAME/../awg_common.sh" "$BATS_TEST_DIRNAME/../awg_common_en.sh"; do
        rm -rf "$(dir_of "$lib")"; mkdir -p "$(dir_of "$lib")"
        "$1" "$lib" || return 1
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}

live_conf() {
    {
        printf '[Interface]\nPrivateKey = TESTKEY\nListenPort = 39743\nJc = 6\nJmin = 55\nJmax = 380\n'
        printf 'S1 = 72\nS2 = 56\nS3 = 32\nS4 = 16\n'
        printf 'H1 = 100000-800000\nH2 = 1000000-8000000\nH3 = 10000000-80000000\nH4 = 100000000-800000000\n'
        [[ -n "${2:-}" ]] && printf '%s\n' "$2"
    } > "$(dir_of "$1")/awg0.conf"
}

@test "cpa: both installers write AWG_CPA into init right before the generation marker block" {
    # The marker stays the last line of the heredoc (test_protocol_marker.bats), so
    # AWG_CPA goes just above its comment block.
    local seen=0 src line
    for src in "$BATS_TEST_DIRNAME/../install_amneziawg.sh" "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"; do
        line=$(awk 'index($0, "export AWG_PROTOCOL=") == 1 { print prev; exit } !/^[[:space:]]*#/ { prev = $0 }' "$src")
        [ "$line" = "export AWG_CPA='\${AWG_CPA:-}'" ] || { echo "line before the marker block in $src: '$line'"; return 1; }
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}

c_safe_load_lib() {
    printf "export AWG_PORT=39743\nexport AWG_CPA='32-128'\n" > "$(dir_of "$1")/awgsetup_cfg.init"
    run lib_run "$1" 'safe_load_config "$CONFIG_FILE"; printf "CPA=%s\n" "${AWG_CPA:-}"'
    [[ "$output" == *"CPA=32-128"* ]] || { echo "safe_load_config dropped AWG_CPA ($1): $output"; return 1; }
}
@test "cpa: safe_load_config in both libraries accepts AWG_CPA" {
    each_lib c_safe_load_lib
}

@test "cpa: safe_load_config in both installers accepts AWG_CPA" {
    local seen=0 src d="$BATS_TEST_TMPDIR/inst"
    mkdir -p "$d"
    printf "export AWG_PORT=39743\nexport AWG_CPA='32-128'\n" > "$d/awgsetup_cfg.init"
    for src in "$BATS_TEST_DIRNAME/../install_amneziawg.sh" "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"; do
        run timeout 30 bash -c '
            eval "$(awk "/^safe_load_config\\(\\) \\{/,/^\\}/" "$1")"
            safe_load_config "$2"; printf "CPA=%s\n" "${AWG_CPA:-}"
        ' _ "$src" "$d/awgsetup_cfg.init"
        [[ "$output" == *"CPA=32-128"* ]] || { echo "installer safe_load_config dropped AWG_CPA ($src): $output"; return 1; }
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}

c_loader_reads() {
    live_conf "$1" "contentpaddingaddition = 32-128"
    run lib_run "$1" 'load_awg_params_from_server_conf "$SERVER_CONF_FILE"; printf "CPA=%s\n" "${AWG_CPA:-}"'
    [[ "$output" == *"CPA=32-128"* ]] || { echo "the loader did not read ContentPaddingAddition ($1): $output"; return 1; }
    live_conf "$1" "ContentPaddingAddition = 48 # comment"
    run lib_run "$1" 'load_awg_params_from_server_conf "$SERVER_CONF_FILE"; printf "CPA=%s|\n" "${AWG_CPA:-}"'
    [[ "$output" == *"CPA=48|"* ]] || { echo "the loader kept a comment or spaces in ContentPaddingAddition ($1): $output"; return 1; }
}
@test "cpa: the live config loader reads ContentPaddingAddition in any case, without a trailing comment, both twins" {
    each_lib c_loader_reads
}

c_stale_dropped() {
    live_conf "$1"
    run lib_run "$1" 'export AWG_CPA=999; load_awg_params; printf "rc=%s CPA=%s|\n" "$?" "${AWG_CPA:-}"'
    [[ "$output" == *"rc=0 CPA=|"* ]] || { echo "a stale AWG_CPA survived a live config without it ($1): $output"; return 1; }
}
@test "cpa: load_awg_params drops a stale AWG_CPA when the live config has none, both twins" {
    each_lib c_stale_dropped
}

@test "cpa: AWG_CPA is on the init drift list of both libraries" {
    local seen=0 src
    for src in "$BATS_TEST_DIRNAME/../awg_common.sh" "$BATS_TEST_DIRNAME/../awg_common_en.sh"; do
        run timeout 30 bash -c 'source "$1" >/dev/null 2>&1; printf "%s\n" "${_AWG_DRIFT_KEYS[@]}"' _ "$src"
        grep -qx AWG_CPA <<< "$output" || { echo "AWG_CPA is not on the drift list ($src): $output"; return 1; }
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}
