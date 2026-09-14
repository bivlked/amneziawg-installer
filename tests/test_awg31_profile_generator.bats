#!/usr/bin/env bats
# Third-line profile, part one: the generator branch and the config check.
#
# The 3.1 branch of generate_awg_params raises the S3/S4 lower bounds to 12
# (with a header protection key the first 12 bytes of the S padding are the
# nonce, and both implementations reject less), writes H1..H4 = 1/2/3/4 and a
# ContentPaddingAddition of 32-128. The 2.0 branch keeps its old ranges: S3
# 8..55, S4 4..27, random H ranges, no ContentPaddingAddition. An unset or empty
# AWG_PROTOCOL means 2.0.
#
# validate_awg_config switches the key rules on by the PRESENCE of
# HeaderProtectionKey in [Interface], parsed the way amneziawg-tools parse it
# (section and key case-insensitive). ContentPaddingAddition is checked in any
# config, because the tools wrap an overflowing value modulo 65536 silently. H
# numbers are read in base 10 and capped at uint32, as the tools read them.
# Configs without the key and ContentPaddingAddition keep their old results:
# the regression cases below were taken by running the validator from main.
#
# 🔴 Refusals are asserted by their REASON, not only by the exit status: a check
# that merely crashes also exits non-zero, and a mutant that lets a bad value
# through would pass a status-only test.
#
# Both twins run every case, and every loop counts that both really ran: RU and
# EN keep separate copies of the code.

# shellcheck disable=SC2016,SC2034,SC2154  # bash -c bodies expand in the child; read fields kept for clarity; $stderr is set by bats
load test_helper

bats_require_minimum_version 1.5.0

INST="${BATS_TEST_DIRNAME}/../install_amneziawg.sh"
INST_EN="${BATS_TEST_DIRNAME}/../install_amneziawg_en.sh"
COMMON="${BATS_TEST_DIRNAME}/../awg_common.sh"
COMMON_EN="${BATS_TEST_DIRNAME}/../awg_common_en.sh"

# gen <installer> <lib> <protocol|UNSET|EMPTY> <runs> [leftover] : one line per
# run, "S1 S2 S3 S4 H1 H2 H3 H4 CPA". CPA is read with printenv, so only an
# EXPORTED value counts, and is "unset" when absent. "leftover" exports a stale
# AWG_CPA before the first run.
gen() {
    timeout 300 bash -c '
        log() { :; }; log_warn() { :; }; log_error() { :; }; log_debug() { :; }
        die() { echo "DIE: $*" >&2; exit 1; }
        source "$2" >/dev/null 2>&1 || true
        for f in rand_range validate_jc_value validate_junk_size generate_awg_h_ranges generate_cps_i1 generate_awg_params; do
            eval "$(sed -n "/^${f}()/,/^}/p" "$1")"
        done
        unset CLI_PRESET CLI_JC CLI_JMIN CLI_JMAX
        case "$3" in
            UNSET) unset AWG_PROTOCOL ;;
            EMPTY) export AWG_PROTOCOL= ;;
            *) export AWG_PROTOCOL="$3" ;;
        esac
        if [[ "${5:-}" == "leftover" ]]; then export AWG_CPA=32-128; fi
        for ((i = 0; i < $4; i++)); do
            generate_awg_params
            echo "$AWG_S1 $AWG_S2 $AWG_S3 $AWG_S4 $AWG_H1 $AWG_H2 $AWG_H3 $AWG_H4 $(printenv AWG_CPA || echo unset)"
        done
    ' _ "$1" "$2" "$3" "$4" "${5:-}"
}

# forced_retry <installer> <lib> <protocol|UNSET|EMPTY> : S3's first draw is
# forced onto the S2+28 collision, so the retry path decides S3; every other draw
# returns its lower bound. rand_range lives in $( ), so its state goes through a
# file. Prints "S3 S4".
forced_retry() {
    rm -f "$BATS_TEST_TMPDIR/s3hit"
    timeout 60 bash -c '
        log() { :; }; log_warn() { :; }; log_error() { :; }; log_debug() { :; }
        die() { echo "DIE: $*" >&2; exit 1; }
        source "$2" >/dev/null 2>&1 || true
        for f in validate_jc_value validate_junk_size generate_awg_params; do
            eval "$(sed -n "/^${f}()/,/^}/p" "$1")"
        done
        mark="$4/s3hit"
        rand_range() {
            case "$2" in
                150) echo 20 ;;
                55) if [[ ! -e "$mark" ]]; then : > "$mark"; echo 48; else echo "$1"; fi ;;
                *) echo "$1" ;;
            esac
        }
        generate_awg_h_ranges() { printf "%s\n" 100000-200000 300000-400000 500000-600000 700000-800000; }
        generate_cps_i1() { echo "<r 2>"; }
        unset CLI_PRESET CLI_JC CLI_JMIN CLI_JMAX
        case "$3" in
            UNSET) unset AWG_PROTOCOL ;;
            EMPTY) export AWG_PROTOCOL= ;;
            *) export AWG_PROTOCOL="$3" ;;
        esac
        generate_awg_params
        [[ -e "$mark" ]] || { echo "NO RETRY"; exit 1; }
        echo "$AWG_S3 $AWG_S4"
    ' _ "$1" "$2" "$3" "$BATS_TEST_TMPDIR"
}

# validate <lib> [brokenparse] : validate_awg_config on $SERVER_CONF_FILE, errors
# on stdout. "brokenparse" replaces the config parser with a failing one.
validate() {
    timeout 30 bash -c '
        log() { :; }; log_warn() { :; }; log_debug() { :; }
        log_error() { echo "ERR: $*"; }
        source "$1" >/dev/null 2>&1 || true
        if [[ "${2:-}" == "brokenparse" ]]; then _awg_conf_pairs() { return 1; }; fi
        validate_awg_config
    ' _ "$1" "${2:-}"
}

# cpa <lib> <value> : awg_cpa_check_safe, reason on stdout.
cpa() {
    timeout 10 bash -c 'source "$1" >/dev/null 2>&1 || true; awg_cpa_check_safe "$2"' _ "$1" "$2"
}

HPK=$(printf 'test-only-header-protection-key!' | base64)

# A server config in the shape the 3.1 generator produces, with test key values.
write_31_conf() {
    cat > "$SERVER_CONF_FILE" << CONF
[Interface]
PrivateKey = TESTKEY
Address = 10.9.9.1/24
MTU = 1280
ListenPort = 39743
Jc = 6
Jmin = 89
Jmax = 339
S1 = 150
S2 = 150
S3 = 12
S4 = 12
H1 = 1
H2 = 2
H3 = 3
H4 = 4
I1 = <r 256>
HeaderProtectionKey = ${HPK}
ContentPaddingAddition = 32-128
CONF
}

# both <function> : run <function> <lib> for both twins and check both ran.
both() {
    local lib seen=0
    for lib in "$COMMON" "$COMMON_EN"; do
        "$1" "$lib" || return 1
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}

# expect_refused <lib> <ru-reason> <en-reason> [brokenparse]
expect_refused() {
    run --separate-stderr validate "$1" "${4:-}"
    [ "$status" -eq 1 ] || { echo "accepted, expected refusal ($1): $output"; return 1; }
    [[ "$output" == *"$2"* || "$output" == *"$3"* ]] || { echo "wrong reason ($1): $output"; return 1; }
}

# expect_accepted <lib>
expect_accepted() {
    run --separate-stderr validate "$1"
    [ "$status" -eq 0 ] || { echo "refused, expected acceptance ($1): $output"; return 1; }
}

# ---------------------------------------------------------------- generator

@test "gen 3.1: S3 and S4 start at 12, H is 1/2/3/4, CPA 32-128 is exported, both twins" {
    local pair inst lib n=0
    for pair in "$INST|$COMMON" "$INST_EN|$COMMON_EN"; do
        inst="${pair%%|*}"; lib="${pair##*|}"
        run --separate-stderr gen "$inst" "$lib" 3.1 100
        [ "$status" -eq 0 ]
        while read -r s1 s2 s3 s4 h1 h2 h3 h4 c; do
            n=$((n + 1))
            (( s1 >= 15 && s1 <= 150 && s2 >= 15 && s2 <= 150 )) || { echo "S1/S2 out: $s1 $s2 ($inst)"; return 1; }
            (( s3 >= 12 && s3 <= 55 )) || { echo "S3=$s3 out of 12..55 ($inst)"; return 1; }
            (( s4 >= 12 && s4 <= 27 )) || { echo "S4=$s4 out of 12..27 ($inst)"; return 1; }
            [[ "$h1 $h2 $h3 $h4" == "1 2 3 4" ]] || { echo "H=$h1 $h2 $h3 $h4 ($inst)"; return 1; }
            [[ "$c" == "32-128" ]] || { echo "CPA=$c ($inst)"; return 1; }
            (( s2 != s1 + 56 )) || { echo "init/response collision ($inst)"; return 1; }
            (( s3 != s2 + 28 )) || { echo "response/cookie collision ($inst)"; return 1; }
        done <<< "$output"
    done
    [ "$n" -eq 200 ]
}

@test "gen 2.0, unset and empty protocol: old ranges, random H ranges, no CPA, both twins" {
    local pair inst lib proto n=0
    for pair in "$INST|$COMMON" "$INST_EN|$COMMON_EN"; do
        inst="${pair%%|*}"; lib="${pair##*|}"
        for proto in 2.0 UNSET EMPTY; do
            run --separate-stderr gen "$inst" "$lib" "$proto" 40
            [ "$status" -eq 0 ]
            while read -r s1 s2 s3 s4 h1 h2 h3 h4 c; do
                n=$((n + 1))
                (( s3 >= 8 && s3 <= 55 && s4 >= 4 && s4 <= 27 )) || { echo "S3/S4 out: $s3 $s4 ($inst $proto)"; return 1; }
                local hv lo hi los=() his=() i j
                for hv in "$h1" "$h2" "$h3" "$h4"; do
                    [[ "$hv" =~ ^([0-9]+)-([0-9]+)$ ]] || { echo "H not a range: $hv ($inst $proto)"; return 1; }
                    lo="${BASH_REMATCH[1]}"; hi="${BASH_REMATCH[2]}"
                    (( lo < hi )) || { echo "H not ordered: $hv ($inst $proto)"; return 1; }
                    los+=("$lo"); his+=("$hi")
                done
                for ((i = 0; i < 4; i++)); do
                    for ((j = i + 1; j < 4; j++)); do
                        (( los[i] > his[j] || los[j] > his[i] )) || { echo "H ranges overlap: $h1 $h2 $h3 $h4 ($inst $proto)"; return 1; }
                    done
                done
                [[ "$c" == "unset" ]] || { echo "CPA=$c ($inst $proto)"; return 1; }
                (( s3 != s2 + 28 && s2 != s1 + 56 )) || { echo "collision ($inst $proto)"; return 1; }
            done <<< "$output"
        done
    done
    [ "$n" -eq 240 ]
}

@test "gen 2.0: a stale exported AWG_CPA does not survive, both twins" {
    local pair inst lib
    for pair in "$INST|$COMMON" "$INST_EN|$COMMON_EN"; do
        inst="${pair%%|*}"; lib="${pair##*|}"
        run --separate-stderr gen "$inst" "$lib" 2.0 1 leftover
        [ "$status" -eq 0 ]
        [[ "${output##* }" == "unset" ]] || { echo "stale CPA survived ($inst): $output"; return 1; }
    done
}

@test "gen 3.1: the S3 collision retry keeps the raised bound, both twins" {
    run --separate-stderr forced_retry "$INST" "$COMMON" 3.1
    [ "$status" -eq 0 ]
    [ "$output" = "12 12" ]
    run --separate-stderr forced_retry "$INST_EN" "$COMMON_EN" 3.1
    [ "$status" -eq 0 ]
    [ "$output" = "12 12" ]
}

@test "gen 2.0, unset and empty protocol: the S3 collision retry keeps the old bound, both twins" {
    local proto
    for proto in 2.0 UNSET EMPTY; do
        run --separate-stderr forced_retry "$INST" "$COMMON" "$proto"
        [ "$status" -eq 0 ]
        [ "$output" = "8 4" ] || { echo "RU $proto: $output"; return 1; }
        run --separate-stderr forced_retry "$INST_EN" "$COMMON_EN" "$proto"
        [ "$status" -eq 0 ]
        [ "$output" = "8 4" ] || { echo "EN $proto: $output"; return 1; }
    done
}

@test "gen 3.1: the generated CPA passes awg_cpa_check_safe, both twins" {
    local pair inst lib c n=0
    for pair in "$INST|$COMMON" "$INST_EN|$COMMON_EN"; do
        inst="${pair%%|*}"; lib="${pair##*|}"
        run --separate-stderr gen "$inst" "$lib" 3.1 1
        [ "$status" -eq 0 ]
        c="${output##* }"
        run --separate-stderr cpa "$lib" "$c"
        [ "$status" -eq 0 ]
        n=$((n + 1))
    done
    [ "$n" -eq 2 ]
}

# ---------------------------------------------------------------- CPA predicate

cpa_accepts() {
    local v
    for v in 0 16 65535 32-128 0-65535 128-128 "32 - 128" "32-128 # comment" 00032-00128 00000065535; do
        run --separate-stderr cpa "$1" "$v"
        [ "$status" -eq 0 ] || { echo "rejected '$v' ($1): $output"; return 1; }
    done
}
@test "cpa: accepted forms, both twins" {
    both cpa_accepts
}

cpa_wrap() {
    local v
    for v in 65536 70000-70016 0-65536 99999 100000 4294967295; do
        run --separate-stderr cpa "$1" "$v"
        [ "$status" -eq 1 ] || { echo "accepted '$v' ($1)"; return 1; }
        [[ "$output" == *"65536"* ]] || { echo "no wrap reason for '$v' ($1): $output"; return 1; }
    done
}
@test "cpa: an overflow the tools would wrap is refused with the wrap named, both twins" {
    both cpa_wrap
}

cpa_uint32() {
    local v
    for v in 4294967296 9999999999 1-4294967296 99999999999 18446744073709551616; do
        run --separate-stderr cpa "$1" "$v"
        [ "$status" -eq 1 ] || { echo "accepted '$v' ($1)"; return 1; }
        [[ "$output" == *"4294967295"* ]] || { echo "no uint32 reason for '$v' ($1): $output"; return 1; }
    done
}
@test "cpa: a value the tools would not accept at all, however long, is refused with that reason, both twins" {
    both cpa_uint32
}

cpa_form() {
    local v
    for v in abc "" -5 1-2-3 "0x10"; do
        run --separate-stderr cpa "$1" "$v"
        [ "$status" -eq 1 ] || { echo "accepted '$v' ($1)"; return 1; }
        [[ "$output" == *"MIN-MAX"* ]] || { echo "wrong reason for '$v' ($1): $output"; return 1; }
    done
}
@test "cpa: junk is refused by form, both twins" {
    both cpa_form
}

cpa_order() {
    local v
    for v in 16-1 09-08; do
        run --separate-stderr cpa "$1" "$v"
        [ "$status" -eq 1 ] || { echo "accepted '$v' ($1)"; return 1; }
        [[ "$output" == *"нижняя граница больше"* || "$output" == *"lower bound is greater"* ]] || { echo "wrong reason for '$v' ($1): $output"; return 1; }
    done
}
@test "cpa: a reversed range is refused, leading zeros read in base 10, both twins" {
    both cpa_order
}

# ---------------------------------------------------------------- validator: 2.0 regression

v_2_0_basics() {
    create_server_config
    expect_accepted "$1" || return 1
    sed -i 's/^S3 = .*/S3 = 8/; s/^S4 = .*/S4 = 4/' "$SERVER_CONF_FILE"
    expect_accepted "$1" || return 1
    create_server_config
    sed -i 's/^H1 = .*/H1 = 1/' "$SERVER_CONF_FILE"
    expect_refused "$1" "ожидается формат MIN-MAX" "expected MIN-MAX format"
}
@test "validate 2.0: plain config accepted, S below 12 accepted, scalar H refused, both twins" {
    both v_2_0_basics
}

v_2_0_ranges() {
    create_server_config
    sed -i 's/^H1 = .*/H1 = 500-500/' "$SERVER_CONF_FILE"
    expect_refused "$1" "нижняя граница (500) >= верхней (500)" "lower bound (500) >= upper bound (500)" || return 1
    create_server_config
    sed -i 's/^H1 = .*/H1 = 800000-100000/' "$SERVER_CONF_FILE"
    expect_refused "$1" "нижняя граница (800000) >= верхней (100000)" "lower bound (800000) >= upper bound (100000)"
}
@test "validate 2.0: equal and reversed H ranges refused as before, both twins" {
    both v_2_0_ranges
}

v_2_0_same_as_main() {
    # Each case was run through the validator from main: status 0 there.
    create_server_config
    printf 'h1 = 5-6\n' >> "$SERVER_CONF_FILE"
    expect_accepted "$1" || return 1
    create_server_config
    printf '\n[Peer]\nPublicKey = X\nH2 = 5-6\n' >> "$SERVER_CONF_FILE"
    expect_accepted "$1" || return 1
    create_server_config
    sed -i 's/^S4 = 16$/S4 = 16 # pad/; s/^H1 = 100000-800000$/H1 = 100000-800000 # h/' "$SERVER_CONF_FILE"
    expect_accepted "$1" || return 1
    create_server_config
    sed -i 's/$/\r/' "$SERVER_CONF_FILE"
    expect_accepted "$1" || return 1
    # Refused in main with exactly this reason.
    create_server_config
    printf '\n[Peer]\nPublicKey = X\n\n[interface]\nS4 = 20\nH2 = 1000000-1000000\n' >> "$SERVER_CONF_FILE"
    expect_refused "$1" "нижняя граница (1000000) >= верхней (1000000)" "lower bound (1000000) >= upper bound (1000000)"
}
@test "validate 2.0: lowercase keys, H in [Peer], comments, CRLF and a second [interface] behave as in main, both twins" {
    both v_2_0_same_as_main
}

v_h_decimal() {
    create_server_config
    sed -i 's/^H1 = .*/H1 = 0100000-0800000/' "$SERVER_CONF_FILE"
    expect_accepted "$1" || return 1
    create_server_config
    sed -i 's/^H1 = .*/H1 = 00000000001-00000000002/' "$SERVER_CONF_FILE"
    expect_accepted "$1" || return 1
    create_server_config
    sed -i 's/^H4 = .*/H4 = 100000000-4294967296/' "$SERVER_CONF_FILE"
    expect_refused "$1" "больше 4294967295" "exceeds 4294967295" || return 1
    create_server_config
    sed -i 's/^H1 = .*/H1 = 100000-99999999999999999999/' "$SERVER_CONF_FILE"
    expect_refused "$1" "больше 4294967295" "exceeds 4294967295"
}
@test "validate: H ranges read in base 10 and capped at uint32 without the key, both twins" {
    both v_h_decimal
}

v_cpa_any_config() {
    create_server_config
    printf 'ContentPaddingAddition = 70000-70016\n' >> "$SERVER_CONF_FILE"
    expect_refused "$1" "ContentPaddingAddition" "ContentPaddingAddition" || return 1
    create_server_config
    printf 'ContentPaddingAddition = 32-128\n' >> "$SERVER_CONF_FILE"
    expect_accepted "$1"
}
@test "validate: CPA is checked without the key too, both twins" {
    both v_cpa_any_config
}

# ---------------------------------------------------------------- validator: key rules

v_31_accepted() {
    write_31_conf
    expect_accepted "$1" || return 1
    write_31_conf
    sed -i 's/$/\r/' "$SERVER_CONF_FILE"
    expect_accepted "$1" || return 1
    write_31_conf
    sed -i 's/^\[Interface\]$/[Interface] # main/; s/^S4 = 12$/S4 = 12 # nonce/' "$SERVER_CONF_FILE"
    expect_accepted "$1" || return 1
    write_31_conf
    sed -i 's/^H1 = .*/h1 = 1/; s/^H2 = .*/h2 = 2/; s/^H3 = .*/h3 = 3/; s/^H4 = .*/h4 = 4/' "$SERVER_CONF_FILE"
    expect_accepted "$1" || return 1
    write_31_conf
    printf '\n[Peer]\nPublicKey = X\nS1 = 11\n' >> "$SERVER_CONF_FILE"
    expect_accepted "$1"
}
@test "validate 3.1: the generator-shaped config, CRLF, comments, lowercase h and S in [Peer] are accepted, both twins" {
    both v_31_accepted
}

v_31_s_bound() {
    local s
    for s in S1 S2 S3 S4; do
        write_31_conf
        sed -i "s/^${s} = .*/${s} = 11/" "$SERVER_CONF_FILE"
        expect_refused "$1" "${s}=11 меньше 12" "${s}=11 is below 12" || return 1
    done
    write_31_conf
    sed -i 's/^S4 = .*/S4 = 09/' "$SERVER_CONF_FILE"
    expect_refused "$1" "S4=09 меньше 12" "S4=09 is below 12" || return 1
    write_31_conf
    sed -i 's/^S4 = .*/S4 = 012/' "$SERVER_CONF_FILE"
    expect_accepted "$1" || return 1
    write_31_conf
    printf '[interface]\ns4 = 11\n' >> "$SERVER_CONF_FILE"
    expect_refused "$1" "S4=11 меньше 12" "S4=11 is below 12" || return 1
    write_31_conf
    sed -i '/^S2 = /d' "$SERVER_CONF_FILE"
    expect_refused "$1" "Параметр 'S2' не найден" "Parameter 'S2' not found" || return 1
    write_31_conf
    sed -i 's/^S4 = .*/S4 = 0000011/' "$SERVER_CONF_FILE"
    expect_refused "$1" "S4=0000011 меньше 12" "S4=0000011 is below 12" || return 1
    write_31_conf
    sed -i 's/^S4 = .*/s4 = 12/' "$SERVER_CONF_FILE"
    expect_accepted "$1" || return 1
    write_31_conf
    printf 's4 = 33\n' >> "$SERVER_CONF_FILE"
    expect_refused "$1" "S4=33 превышает максимум (32)" "S4=33 exceeds maximum (32)" || return 1
    write_31_conf
    printf 'jc = 500\n' >> "$SERVER_CONF_FILE"
    expect_refused "$1" "Jc=500 вне допустимого диапазона" "Jc=500 is out of range" || return 1
    write_31_conf
    sed -i 's/^S1 = .*/S1 = 18446744073709551616/' "$SERVER_CONF_FILE"
    expect_refused "$1" "Параметр 'S1': значение больше 4294967295" "Parameter 'S1': value exceeds 4294967295" || return 1
    write_31_conf
    sed -i 's/^S3 = .*/S3 = 18446744073709551628/' "$SERVER_CONF_FILE"
    expect_refused "$1" "Параметр 'S3': значение больше 4294967295" "Parameter 'S3': value exceeds 4294967295" || return 1
    write_31_conf
    printf 'jmax = 18446744073709551955\n' >> "$SERVER_CONF_FILE"
    expect_refused "$1" "Параметр 'Jmax': значение больше 4294967295" "Parameter 'Jmax': value exceeds 4294967295" || return 1
    write_31_conf
    sed -i 's/^S1 = .*/S1 = 4294967296/' "$SERVER_CONF_FILE"
    expect_refused "$1" "Параметр 'S1': значение больше 4294967295" "Parameter 'S1': value exceeds 4294967295" || return 1
    write_31_conf
    sed -i 's/^S1 = .*/S1 = 0000000000000000000150/' "$SERVER_CONF_FILE"
    expect_accepted "$1"
}
@test "validate 3.1: S below 12 (with zeros, lowercase, later), missing S, upper bounds from the same parse, numbers past uint32, both twins" {
    both v_31_s_bound
}

v_31_h_rules() {
    write_31_conf
    sed -i 's/^H1 = .*/H1 = 1-1/; s/^H2 = .*/H2 = 2-2/' "$SERVER_CONF_FILE"
    expect_accepted "$1" || return 1
    write_31_conf
    sed -i 's/^H2 = .*/H2 = 1/' "$SERVER_CONF_FILE"
    expect_refused "$1" "пересекаются" "overlap" || return 1
    write_31_conf
    printf '[interface]\nh2 = 1\n' >> "$SERVER_CONF_FILE"
    expect_refused "$1" "пересекаются" "overlap" || return 1
    write_31_conf
    sed -i 's/^H1 = .*/H1 = 010/; s/^H2 = .*/H2 = 8/' "$SERVER_CONF_FILE"
    expect_accepted "$1" || return 1
    write_31_conf
    sed -i 's/^H1 = .*/H1 = 08/; s/^H2 = .*/H2 = 8/' "$SERVER_CONF_FILE"
    expect_refused "$1" "пересекаются" "overlap" || return 1
    write_31_conf
    sed -i 's/^H4 = .*/H4 = 4294967295/' "$SERVER_CONF_FILE"
    expect_accepted "$1" || return 1
    write_31_conf
    sed -i 's/^H4 = .*/H4 = 00000000004294967295/' "$SERVER_CONF_FILE"
    expect_accepted "$1" || return 1
    write_31_conf
    sed -i 's/^H4 = .*/H4 = 4294967296/' "$SERVER_CONF_FILE"
    expect_refused "$1" "больше 4294967295" "exceeds 4294967295" || return 1
    write_31_conf
    sed -i 's/^H1 = .*/H1 = 9-5/' "$SERVER_CONF_FILE"
    expect_refused "$1" "нижняя граница (9) >= верхней (5)" "lower bound (9) >= upper bound (5)"
}
@test "validate 3.1: scalar and N-N H, overlaps, lowercase later h, base 10, uint32 cap, reversed range, both twins" {
    both v_31_h_rules
}

v_31_key_rules() {
    local bad43 badbits
    bad43="${HPK:0:43}"
    badbits="${HPK:0:42}B="
    write_31_conf
    printf 'headerprotectionkey = %s\n' "$HPK" >> "$SERVER_CONF_FILE"
    expect_refused "$1" "2 раза: применится только последний" "2 times in [Interface]: only the last one" || return 1
    write_31_conf
    sed -i "s|^HeaderProtectionKey = .*|HeaderProtectionKey = ${bad43}|" "$SERVER_CONF_FILE"
    expect_refused "$1" "32 байта в base64" "32 bytes in base64" || return 1
    [[ "$output" != *"$bad43"* ]] || { echo "key value printed ($1)"; return 1; }
    write_31_conf
    sed -i "s|^HeaderProtectionKey = .*|HeaderProtectionKey = ${badbits}|" "$SERVER_CONF_FILE"
    expect_refused "$1" "32 байта в base64" "32 bytes in base64" || return 1
    create_server_config
    printf '\n[Peer]\nPublicKey = X\nHeaderProtectionKey = %s\n' "$HPK" >> "$SERVER_CONF_FILE"
    expect_refused "$1" "вне секции [Interface]" "outside the [Interface] section" || return 1
    create_server_config
    { printf 'HeaderProtectionKey = %s\n' "$HPK"; cat "$SERVER_CONF_FILE"; } > "$SERVER_CONF_FILE.new"
    mv "$SERVER_CONF_FILE.new" "$SERVER_CONF_FILE"
    expect_refused "$1" "вне секции [Interface]" "outside the [Interface] section" || return 1
    write_31_conf
    { printf '\xef\xbb\xbf'; cat "$SERVER_CONF_FILE"; } > "$SERVER_CONF_FILE.new"
    mv "$SERVER_CONF_FILE.new" "$SERVER_CONF_FILE"
    expect_refused "$1" "вне секции [Interface]" "outside the [Interface] section"
}
@test "validate 3.1: repeated, malformed, wrong trailing bits, in [Peer], before the header, after a BOM, both twins" {
    both v_31_key_rules
}

v_cpa_hidden_and_placed() {
    write_31_conf
    sed -i 's/^ContentPaddingAddition = .*/ContentPaddingAddition = 65536/' "$SERVER_CONF_FILE"
    printf 'ContentPaddingAddition = 32\n' >> "$SERVER_CONF_FILE"
    expect_refused "$1" "65536" "65536" || return 1
    create_server_config
    { printf 'ContentPaddingAddition = 65536\n'; cat "$SERVER_CONF_FILE"; } > "$SERVER_CONF_FILE.new"
    mv "$SERVER_CONF_FILE.new" "$SERVER_CONF_FILE"
    expect_refused "$1" "65536" "65536"
}
@test "validate: a later good CPA line does not hide an overflow, CPA before the header is checked, both twins" {
    both v_cpa_hidden_and_placed
}

v_parse_failure() {
    write_31_conf
    expect_refused "$1" "Не удалось разобрать" "Could not parse" brokenparse
}
@test "validate: a failed config parse refuses instead of switching the key rules off, both twins" {
    both v_parse_failure
}
