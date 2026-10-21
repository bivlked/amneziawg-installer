#!/usr/bin/env bats
# --i1: pin the I1 concealment packet to a value of your own (issue #196).
#
# What is guarded here:
#   1. the value check at the command line: only the tags BOTH implementations
#      parse, so a phone client never gets a profile it cannot load (`<c>` is
#      kernel only, amneziawg-go fails on it with "failed to parse I1");
#   2. the pin lives in the init file as AWG_I1_PIN and wins over the generator,
#      so it survives a reboot and the step 3 fallback, which regenerates the
#      whole set in another process;
#   3. on a reinstall the server config takes the pin over the live I1, and
#      says so when the live value was different;
#   4. --no-cps, or an explicit --preset/--jc/--jmin/--jmax without --i1, drops
#      the pin, the same way they already treat NO_CPS.
# shellcheck disable=SC2154

load test_helper

INSTALLERS=(install_amneziawg.sh install_amneziawg_en.sh)
DNS_I1='<r 2><b 0x858000010001000000001f><rc 31><b 0x0463646e730669636c6f756403636f6d0000010001c00c000100010000012c0004c0a80101>'

# lift <installer> <functions...> : define installer functions in a subshell
# script prefix; the caller appends what to run.
lift() {
    local f="$1"; shift
    local out=""
    for fn in "$@"; do
        out+="$(sed -n "/^${fn}()/,/^}/p" "$BATS_TEST_DIRNAME/../$f")"$'\n'
    done
    printf '%s' "$out"
}

check() {  # check <installer> <value> : runs _awg_i1_cli_check, prints reason
    bash -c "$(lift "$1" _awg_i1_cli_check)"$'\n''_awg_i1_cli_check "$1"' _ "$2"
}

# ------------------------------------------------------------- value check

@test "i1 flag: accepts portable values, including the generator's own (RU + EN)" {
    local f v
    for f in "${INSTALLERS[@]}"; do
        for v in "$DNS_I1" '<b 0xc0ffee><r 16>' '<t><rd 4><rc 1000>' '<b 0xAbCd>' '<r 1>'; do
            run check "$f" "$v"
            [ "$status" -eq 0 ] || { echo "$f rejected: $v -> $output"; false; }
        done
        # The value the generator emits today must pass the check it is compared to.
        local gen
        gen=$(bash -c "$(lift "$f" rand_range generate_cps_i1)"$'\n''generate_cps_i1')
        [[ "$gen" == '<r 2><b 0x'* ]]
        run check "$f" "$gen"
        [ "$status" -eq 0 ] || { echo "$f rejected its own generator: $gen"; false; }
    done
}

@test "i1 flag: the decoded size is capped at 1024 bytes, like the diagnose warning (RU + EN)" {
    local f
    for f in "${INSTALLERS[@]}"; do
        # 1000 + 20 + 4 = 1024: exactly at the cap passes.
        run check "$f" '<r 1000><rc 20><t>'
        [ "$status" -eq 0 ] || { echo "$f rejected 1024 bytes: $output"; false; }
        # 1000 + 24 + 1 (one <b> byte) = 1025: one over fails and says the size.
        run check "$f" '<r 1000><rd 24><b 0x01>'
        [ "$status" -eq 1 ]
        [[ "$output" == *1025* ]] || { echo "$f: no size in reason: $output"; false; }
        # Many small tags add up too: each tag is fine alone.
        run check "$f" '<r 1000><r 1000><r 1000><r 1000>'
        [ "$status" -eq 1 ]
        # <t> counts as 4 bytes: 1000 + 21 + 4 = 1025.
        run check "$f" '<r 1000><rc 21><t>'
        [ "$status" -eq 1 ]
    done
}

@test "i1 flag: dropping a saved pin is said out loud, keeping or setting it is quiet (RU + EN)" {
    local f
    for f in "${INSTALLERS[@]}"; do
        run env -i PATH="$PATH" CLI_JC=4 'AWG_I1_PIN=<t>' bash -c 'log_warn() { echo "WARN: $*"; }'$'\n'"$(lift "$f" _awg_resolve_i1_pin)"$'\n''_awg_resolve_i1_pin'
        [[ "$output" == WARN:*'<t>'* ]] || { echo "$f: no warning on drop: $output"; false; }
        run env -i PATH="$PATH" CLI_JC=4 bash -c 'log_warn() { echo "WARN: $*"; }'$'\n'"$(lift "$f" _awg_resolve_i1_pin)"$'\n''_awg_resolve_i1_pin'
        [ -z "$output" ] || { echo "$f: warned with no pin to drop: $output"; false; }
        run env -i PATH="$PATH" CLI_I1_SET=1 'CLI_I1=<t>' 'AWG_I1_PIN=<b 0x01>' bash -c 'log_warn() { echo "WARN: $*"; }'$'\n'"$(lift "$f" _awg_resolve_i1_pin)"$'\n''_awg_resolve_i1_pin'
        [ -z "$output" ] || { echo "$f: warned on a new --i1: $output"; false; }
    done
}

@test "i1 flag: rejects the kernel-only counter tag and names the phone failure (RU + EN)" {
    local f
    for f in "${INSTALLERS[@]}"; do
        run check "$f" '<b 0x01><c>'
        [ "$status" -eq 1 ]
        [[ "$output" == *'<c>'* ]]
        [[ "$output" == *amneziawg-go* ]]
    done
}

@test "i1 flag: rejects malformed and non-portable values (RU + EN)" {
    local f v
    for f in "${INSTALLERS[@]}"; do
        for v in '' '<d>' '<ds>' '<dz 4>' '<r 0>' '<r 1001>' '<r 01>' '<r -1>' \
                 '<b 0x123>' '<b 0x>' '<b 0xGG>' '<b 12>' '<r 2> <t>' '<R 2>' \
                 '<r 2>x' '<r 2' "<b 0x12>'" 'r 2' '<t 4>' '<rc>'; do
            run check "$f" "$v"
            [ "$status" -eq 1 ] || { echo "$f accepted: [$v]"; false; }
            [ -n "$output" ] || { echo "$f gave no reason for: [$v]"; false; }
        done
    done
}

@test "i1 flag: the installer refuses a bad --i1 before doing anything, exit 2 (RU + EN)" {
    local f
    for f in "${INSTALLERS[@]}"; do
        run bash "$BATS_TEST_DIRNAME/../$f" '--i1=<c>'
        [ "$status" -eq 2 ]
        [[ "$output" == *'--i1'* ]]
        [[ "$output" == *'<c>'* ]]
    done
}

@test "i1 flag: --i1 together with --no-cps is refused, exit 2 (RU + EN)" {
    local f
    for f in "${INSTALLERS[@]}"; do
        run bash "$BATS_TEST_DIRNAME/../$f" '--i1=<b 0x0102><r 8>' --no-cps
        [ "$status" -eq 2 ]
        [[ "$output" == *'--no-cps'* ]]
    done
}

@test "i1 flag: a valid --i1 passes the check and reaches help, exit 0 (RU + EN)" {
    local f
    for f in "${INSTALLERS[@]}"; do
        run bash "$BATS_TEST_DIRNAME/../$f" '--i1=<b 0x0102><r 8>' --help
        [ "$status" -eq 0 ]
        [[ "$output" == *'--i1='* ]]
    done
}

# ------------------------------------------------------------- pin resolution

resolve() {  # resolve <installer> <env assignments...> : prints the pin
    local f="$1"; shift
    env -i PATH="$PATH" "$@" bash -c "log_warn() { :; }"$'\n'"$(lift "$f" _awg_resolve_i1_pin)"$'\n''_awg_resolve_i1_pin; printf "[%s]" "${AWG_I1_PIN-}"'
}

@test "i1 flag: --i1 sets the pin, even with an explicit preset (RU + EN)" {
    local f
    for f in "${INSTALLERS[@]}"; do
        run resolve "$f" CLI_I1_SET=1 'CLI_I1=<b 0x0a>' CLI_PRESET=mobile 'AWG_I1_PIN=<t>'
        [ "$output" = '[<b 0x0a>]' ]
    done
}

@test "i1 flag: --no-cps and explicit regeneration flags drop the pin (RU + EN)" {
    local f a
    for f in "${INSTALLERS[@]}"; do
        for a in CLI_NO_CPS=1 CLI_PRESET=default CLI_JC=4 CLI_JMIN=40 CLI_JMAX=90; do
            run resolve "$f" "$a" 'AWG_I1_PIN=<t>'
            [ "$output" = '[]' ] || { echo "$f $a kept the pin: $output"; false; }
        done
    done
}

@test "i1 flag: with no relevant flag the saved pin is kept (RU + EN)" {
    local f
    for f in "${INSTALLERS[@]}"; do
        run resolve "$f" 'AWG_I1_PIN=<t>'
        [ "$output" = '[<t>]' ]
        run resolve "$f"
        [ "$output" = '[]' ]
    done
}

# ------------------------------------------------------------- generator

genparams() {  # genparams <installer> <lib> <protocol> <pin> : prints AWG_I1
    timeout 120 bash -c '
        log() { :; }; log_warn() { :; }; log_error() { :; }; log_debug() { :; }
        die() { echo "DIE: $*" >&2; exit 1; }
        source "$2" >/dev/null 2>&1 || true
        for f in rand_range validate_jc_value validate_junk_size generate_awg_h_ranges generate_cps_i1 _awg_size_collisions generate_awg_params; do
            eval "$(sed -n "/^${f}()/,/^}/p" "$1")"
        done
        unset CLI_PRESET CLI_JC CLI_JMIN CLI_JMAX
        export AWG_PROTOCOL="$3" AWG_I1_PIN="$4"
        generate_awg_params
        printf "%s" "$AWG_I1"
    ' _ "$@"
}

@test "i1 flag: the generator uses the pin instead of a fresh I1, both generations (RU + EN)" {
    local pair f lib p
    for pair in "install_amneziawg.sh awg_common.sh" "install_amneziawg_en.sh awg_common_en.sh"; do
        read -r f lib <<< "$pair"
        for p in 2.0 3.1; do
            run genparams "$BATS_TEST_DIRNAME/../$f" "$BATS_TEST_DIRNAME/../$lib" "$p" '<b 0x0102><rc 8>'
            [ "$status" -eq 0 ]
            [ "$output" = '<b 0x0102><rc 8>' ] || { echo "$f $p: $output"; false; }
            # Without a pin the generator still emits its own DNS-shaped value.
            run genparams "$BATS_TEST_DIRNAME/../$f" "$BATS_TEST_DIRNAME/../$lib" "$p" ''
            [ "$status" -eq 0 ]
            [[ "$output" == '<r 2><b 0x'* ]] || { echo "$f $p unpinned: $output"; false; }
        done
    done
}

# ------------------------------------------------------------- init file

@test "i1 flag: AWG_I1_PIN is written to the init file and read back by both loaders (RU + EN)" {
    local f
    for f in "${INSTALLERS[@]}"; do
        grep -qF "export AWG_I1_PIN='\${AWG_I1_PIN:-}'" "$BATS_TEST_DIRNAME/../$f" \
            || { echo "no AWG_I1_PIN line in _awg_save_init of $f"; false; }
    done
    printf "export AWG_I1_PIN='<b 0x0102><r 8>'\n" > "$CONFIG_FILE"
    local lib
    for lib in awg_common.sh awg_common_en.sh; do
        run bash -c 'log_warn() { :; }; log() { :; }; source "$1" >/dev/null 2>&1; unset AWG_I1_PIN; safe_load_config "$2"; printf "[%s]" "${AWG_I1_PIN-}"' _ "$BATS_TEST_DIRNAME/../$lib" "$CONFIG_FILE"
        [ "$output" = '[<b 0x0102><r 8>]' ] || { echo "$lib: $output"; false; }
    done
    for f in "${INSTALLERS[@]}"; do
        run bash -c "log_warn() { :; }; $(lift "$f" safe_load_config)"$'\n''unset AWG_I1_PIN; safe_load_config "$1"; printf "[%s]" "${AWG_I1_PIN-}"' _ "$CONFIG_FILE"
        [ "$output" = '[<b 0x0102><r 8>]' ] || { echo "$f: $output"; false; }
    done
}

# ------------------------------------------------------------- reinstall render

render_fixture() {
    create_init_config
    create_server_config
    echo "I1 = <r 155>" >> "$SERVER_CONF_FILE"
    echo "I2 = <t>" >> "$SERVER_CONF_FILE"
    echo "PRIVKEYPLACEHOLDER" > "$AWG_DIR/server_private.key"
    get_main_nic() { echo eth0; }
    host_lacks_ipv4_egress() { return 1; }
    log_warn() { echo "WARN: $*"; }
}

@test "i1 flag: reinstall render takes the pin over the live I1 and says so (keeps I2)" {
    render_fixture
    echo "export AWG_I1_PIN='<b 0x0102><r 8>'" >> "$CONFIG_FILE"
    run render_server_config
    [ "$status" -eq 0 ]
    grep -qxF 'I1 = <b 0x0102><r 8>' "$SERVER_CONF_FILE"
    [ "$(grep -cE '^I1 = ' "$SERVER_CONF_FILE")" -eq 1 ]
    grep -qxF 'I2 = <t>' "$SERVER_CONF_FILE"
    [[ "$output" == *'<r 155>'* ]]
}

@test "i1 flag: reinstall render keeps the live I1 when there is no pin" {
    render_fixture
    echo "export AWG_I1_PIN=''" >> "$CONFIG_FILE"
    run render_server_config
    [ "$status" -eq 0 ]
    grep -qxF 'I1 = <r 155>' "$SERVER_CONF_FILE"
}

@test "i1 flag: reinstall render is quiet when the live I1 already equals the pin" {
    render_fixture
    sed -i 's/^I1 = .*/I1 = <b 0x0102><r 8>/' "$SERVER_CONF_FILE"
    echo "export AWG_I1_PIN='<b 0x0102><r 8>'" >> "$CONFIG_FILE"
    run render_server_config
    [ "$status" -eq 0 ]
    grep -qxF 'I1 = <b 0x0102><r 8>' "$SERVER_CONF_FILE"
    [ "$(printf '%s\n' "$output" | grep -c 'I1')" -eq 0 ]
}

@test "i1 flag: the EN library takes the pin over the live I1 too" {
    render_fixture
    echo "export AWG_I1_PIN='<b 0x0102><r 8>'" >> "$CONFIG_FILE"
    run bash -c '
        log() { :; }; log_error() { echo "ERR: $*"; }; log_debug() { :; }; log_warn() { echo "WARN: $*"; }
        source "$1" >/dev/null 2>&1
        get_main_nic() { echo eth0; }
        host_lacks_ipv4_egress() { return 1; }
        render_server_config
    ' _ "$BATS_TEST_DIRNAME/../awg_common_en.sh"
    [ "$status" -eq 0 ]
    grep -qxF 'I1 = <b 0x0102><r 8>' "$SERVER_CONF_FILE"
}

# ------------------------------------------------------------- wiring

@test "i1 flag: initialize_setup resolves the pin before generating and applies it after, both twins" {
    local s body res gen app nocps
    for s in "${INSTALLERS[@]}"; do
        body=$(sed -n '/^initialize_setup() {/,/^}/p' "$BATS_TEST_DIRNAME/../$s")
        res=$(grep -n '^[[:space:]]*_awg_resolve_i1_pin$' <<< "$body" | head -1 | cut -d: -f1)
        gen=$(grep -n '^[[:space:]]*generate_awg_params$' <<< "$body" | head -1 | cut -d: -f1)
        app=$(grep -n '^[[:space:]]*AWG_I1="\$AWG_I1_PIN"$' <<< "$body" | head -1 | cut -d: -f1)
        nocps=$(grep -n '^[[:space:]]*if \[\[ "\${NO_CPS:-0}" -eq 1 \]\]; then$' <<< "$body" | head -1 | cut -d: -f1)
        [ -n "$res" ] && [ -n "$gen" ] && [ -n "$app" ] && [ -n "$nocps" ] || { echo "$s: anchors not found ($res/$gen/$app/$nocps)"; return 1; }
        [ "$res" -lt "$gen" ] || { echo "$s: pin resolved at $res, after generation at $gen"; return 1; }
        [ "$gen" -lt "$app" ] && [ "$app" -lt "$nocps" ] || { echo "$s: pin applied at $app, not between generation $gen and --no-cps $nocps"; return 1; }
        # --i1 turns CPS back on and sends an unfinished install back to step 4.
        grep -qF 'elif [[ "${CLI_I1_SET:-0}" -eq 1 || -n "${CLI_PRESET:-}"' <<< "$body" || { echo "$s: --i1 does not reset NO_CPS"; return 1; }
        grep -qF '|| [[ "${CLI_I1_SET:-0}" -eq 1 ]] \' <<< "$body" || { echo "$s: --i1 does not return an unfinished install to step 4"; return 1; }
    done
}

@test "i1 flag: --help wins over a bad --i1, exit 0 (RU + EN)" {
    local f
    for f in "${INSTALLERS[@]}"; do
        run bash "$BATS_TEST_DIRNAME/../$f" --help '--i1=<c>'
        [ "$status" -eq 0 ] || { echo "$f: rc=$status"; false; }
        [[ "$output" == *'--i1='* ]]
    done
}

@test "i1 flag: render stays quiet about the swap when this run passed --i1 (it already warned)" {
    render_fixture
    echo "export AWG_I1_PIN='<b 0x0102><r 8>'" >> "$CONFIG_FILE"
    export CLI_I1_SET=1   # read by render_server_config
    run render_server_config
    [ "$status" -eq 0 ]
    grep -qxF 'I1 = <b 0x0102><r 8>' "$SERVER_CONF_FILE"
    [ "$(printf '%s\n' "$output" | grep -c '<r 155>')" -eq 0 ]
}

@test "i1 flag: every list of pin-dropping flags names --mobile (help, ADVANCED, render hint)" {
    local f
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        sed -n '/^  --i1=/,/^  --no-prebuilt/p' "$BATS_TEST_DIRNAME/../$f" | grep -q -- '--mobile' || { echo "$f help"; false; }
    done
    for f in ADVANCED.md ADVANCED.en.md; do
        grep -E "^  --i1='" "$BATS_TEST_DIRNAME/../$f" | grep -q -- '--mobile' || { echo "$f flag list"; false; }
    done
    for f in awg_common.sh awg_common_en.sh; do
        sed -n '/^render_server_config() {/,/^}$/p' "$BATS_TEST_DIRNAME/../$f" | grep 'AWG_I1_PIN' | grep -q -- '--mobile' || { echo "$f render hint"; false; }
    done
}
