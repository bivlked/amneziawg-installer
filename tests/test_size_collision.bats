#!/usr/bin/env bats
# A data packet must not be taken for a handshake message.
#
# The receiver (kernel module src/receive.c awg_determine_type_and_padding,
# amneziawg-go device/receive.go DeterminePacketTypeAndPadding) tries init,
# response and cookie first, each by its EXACT length (padding + message size:
# 148 + S1, 92 + S2, 64 + S3) and by the 4 bytes at that padding offset falling
# into the message's H range, and only then transport. A data packet is
# 32 + P + S4 bytes long, P being its padded plaintext (a multiple of 16, at
# least 32 for any IP packet). When the lengths match, the check reads the data
# packet at offset o = S - S4 inside its transport message: the random S4
# padding (o < 0) or ciphertext (o >= 16) lands in H with a probability of
# H width / 2^32, the receiver index (o = 4, response with P = 64) does the same
# once per session, while the high half of the counter (o = 12, init with
# P = 128) is 0 and the packet's own type (o = 0, cookie with P = 32) comes from
# H4, so those two never match. A packet that matches goes to the handshake
# handler and is lost, on each receiving side. Measured on a 2.0 profile
# (S1-S4 = 94/62/21/26, response with o = 36, H2 = 8.6% of 2^32): pings of
# exactly that size lost about 20% round trip, every other size 0%; the same on
# an x86 module and with an amneziawg-go client. Our earlier guards
# (S1+56 != S2, S3 != S2+28) only kept handshake messages apart from each other.
#
# The model is the 2.0 transport. The 3.1 profile adds ContentPaddingAddition to
# the length and uses single H values, so there the single H, not the S4 choice,
# keeps the loss at about 2^-32.
#
# The generator picks S4 among the values without such a case; check and
# diagnose warn when an existing config has one and its H range is wide enough
# to matter.

# shellcheck disable=SC2016,SC2034,SC2154  # bash -c bodies expand in the child; $stderr is set by bats
load test_helper

bats_require_minimum_version 1.5.0

INST="${BATS_TEST_DIRNAME}/../install_amneziawg.sh"
INST_EN="${BATS_TEST_DIRNAME}/../install_amneziawg_en.sh"
COMMON="${BATS_TEST_DIRNAME}/../awg_common.sh"
COMMON_EN="${BATS_TEST_DIRNAME}/../awg_common_en.sh"

# coll <file> S1 S2 S3 S4 : _awg_size_collisions lifted from <file>.
coll() {
    timeout 30 bash -c '
        eval "$(sed -n "/^_awg_size_collisions()/,/^}/p" "$1")"
        declare -F _awg_size_collisions >/dev/null || { echo "NOFUNC"; exit 97; }
        shift
        _awg_size_collisions "$@"
    ' _ "$@"
}

# oracle S1 S2 S3 S4 : the same question answered from the data packet's layout
# (S4 padding, then type, receiver index, counter, ciphertext), independently of
# the code's formulas. Sets ORACLE_OUT ("class P" pairs in receiver order, space
# separated) instead of printing it, so a sweep calls it without a fork per case.
oracle() {
    local -a s=("$1" "$2" "$3") hdr=(148 92 64) cls=(init response cookie)
    local s4=$4 out="" i P o
    for i in 0 1 2; do
        P=$(( s[i] + hdr[i] - 32 - s4 ))
        (( P >= 32 && P % 16 == 0 )) || continue
        o=$(( s[i] - s4 ))
        # padding or ciphertext: random; receiver index and low counter: vary
        if (( o <= -4 || o >= 16 || o == 4 || o == 8 )); then out+="${cls[i]} $P "; fi
        # o = 0: the type, from H4, never in H1-H3; o = 12: high counter, 0
    done
    ORACLE_OUT="${out% }"
}

# gen <installer> <lib> <protocol> <runs> : one "S1 S2 S3 S4" line per run.
gen() {
    timeout 300 bash -c '
        log() { :; }; log_warn() { :; }; log_error() { :; }; log_debug() { :; }
        die() { echo "DIE: $*" >&2; exit 1; }
        source "$2" >/dev/null 2>&1 || true
        for f in rand_range validate_jc_value validate_junk_size generate_awg_h_ranges generate_cps_i1 _awg_size_collisions generate_awg_params; do
            eval "$(sed -n "/^${f}()/,/^}/p" "$1")"
        done
        unset CLI_PRESET CLI_JC CLI_JMIN CLI_JMAX
        export AWG_PROTOCOL="$3"
        for ((i = 0; i < $4; i++)); do
            generate_awg_params
            echo "$AWG_S1 $AWG_S2 $AWG_S3 $AWG_S4"
        done
    ' _ "$@"
}

# forced <installer> <lib> <protocol> <S1=S2> [nohelper] : every draw returns its
# lower bound, S1 and S2 return <S1=S2>, so S3 is the lower bound and the first
# S4 draw would be the lower bound too. Prints "S3 S4". "nohelper" leaves
# _awg_size_collisions out of the lifted functions.
forced() {
    timeout 60 bash -c '
        log() { :; }; log_warn() { :; }; log_error() { :; }; log_debug() { :; }
        die() { echo "DIE: $*"; exit 1; }
        source "$2" >/dev/null 2>&1 || true
        fs="validate_jc_value validate_junk_size generate_awg_params"
        [[ "${5:-}" == "nohelper" ]] || fs="_awg_size_collisions $fs"
        for f in $fs; do eval "$(sed -n "/^${f}()/,/^}/p" "$1")"; done
        [[ "${5:-}" == "nohelper" ]] && unset -f _awg_size_collisions
        S12="$4"
        rand_range() { case "$2" in 150) echo "$S12" ;; *) echo "$1" ;; esac; }
        generate_awg_h_ranges() { printf "%s\n" 100000-200000 300000-400000 500000-600000 700000-800000; }
        generate_cps_i1() { echo "<r 2>"; }
        unset CLI_PRESET CLI_JC CLI_JMIN CLI_JMAX
        export AWG_PROTOCOL="$3"
        generate_awg_params
        echo "$AWG_S3 $AWG_S4"
    ' _ "$@"
}

# warn <lib> : awg_size_collision_warn on $SERVER_CONF_FILE, warnings on stdout.
warn() {
    timeout 30 bash -c '
        log() { :; }; log_debug() { :; }; log_error() { echo "ERR: $*"; }
        log_warn() { echo "WARN: $*"; }
        source "$1" >/dev/null 2>&1 || true
        declare -F awg_size_collision_warn >/dev/null || { echo "NOFUNC"; exit 97; }
        awg_size_collision_warn
    ' _ "$1"
}

# server_conf S1 S2 S3 S4 H1 H2 H3 H4 : a minimal 2.0-shaped awg0.conf.
server_conf() {
    cat > "$SERVER_CONF_FILE" <<EOF
[Interface]
PrivateKey = TESTKEY
Address = 10.9.9.1/24
ListenPort = 39743
Jc = 3
Jmin = 78
Jmax = 256
S1 = $1
S2 = $2
S3 = $3
S4 = $4
H1 = $5
H2 = $6
H3 = $7
H4 = $8
EOF
}

# the measured set: response match, H2 = 351164001-721039105 (8.61%)
measured_conf() {
    server_conf 94 62 21 26 158796025-276895233 351164001-721039105 848364242-1111224741 1254688896-2141645164
}

setup() {
    export TEST_DIR="$BATS_TEST_TMPDIR"
    export SERVER_CONF_FILE="$TEST_DIR/awg0.conf"
    export CONFIG_FILE="$TEST_DIR/awgsetup_cfg.init"
    export AWG_DIR="$TEST_DIR"
    export MANAGE_SCRIPT_PATH=/opt/awgtest/manage_amneziawg.sh
    printf "export AWG_PRESET='mobile'\n" > "$CONFIG_FILE"
}

@test "collisions: the measured sets, the no-loss offsets and the S3 < S4 boundary, all four twins" {
    local f n=0
    for f in "$INST" "$INST_EN" "$COMMON" "$COMMON_EN"; do
        run coll "$f" 94 62 21 26;  [ "$status" -eq 0 ]; [ "$output" = "response 96" ] || { echo "$f: $output"; return 1; }
        run coll "$f" 124 119 37 16; [ "$status" -eq 0 ]; [ "$output" = "init 224" ] || { echo "$f: $output"; return 1; }
        run coll "$f" 124 119 37 14; [ "$status" -eq 0 ]; [ -z "$output" ] || { echo "$f: $output"; return 1; }
        # S3 = S4: the cookie check reads the data packet's own type (from H4)
        run coll "$f" 20 20 12 12;  [ "$status" -eq 0 ]; [ -z "$output" ] || { echo "$f: $output"; return 1; }
        # S3 - S4 + 32 = 16: only a data packet of at most 16 bytes could match
        run coll "$f" 21 20 8 24;   [ "$status" -eq 0 ]; [ -z "$output" ] || { echo "$f: $output"; return 1; }
        # S1 - S4 = 12 (init, P = 128) reads the high counter half, S3 = S4 the type:
        # only the response (receiver index, P = 64) is left
        run coll "$f" 28 20 16 16;  [ "$status" -eq 0 ]; [ "$output" = "response 64" ] || { echo "$f: $output"; return 1; }
        # all three at once are all named, in receiver order
        run coll "$f" 44 20 32 16;  [ "$status" -eq 0 ]; [ "$output" = "$(printf 'init 144\nresponse 64\ncookie 48')" ] || { echo "$f: $output"; return 1; }
        n=$((n + 1))
    done
    [ "$n" -eq 4 ]
}

@test "collisions: agrees with an independent oracle, class and P, over a sample of the generator's 2.0 range, installer RU" {
    # S4 runs through all of 4..27 (24 consecutive values), so S1 - S4, S2 - S4 and
    # S3 - S4 take every residue mod 16 for any S1, S2, S3; S3 8..55 also crosses
    # S4 both ways (the cookie floor and the type offset). One fork per case,
    # compared in the child: a sweep forking per comparison ran past its timeout
    # under parallel load.
    export -f oracle
    run timeout 120 bash -c '
        eval "$(sed -n "/^_awg_size_collisions()/,/^}/p" "$1")"
        declare -F _awg_size_collisions >/dev/null || { echo "NOFUNC"; exit 97; }
        n=0 bad=0
        for ((s1 = 15; s1 <= 150; s1 += 13)); do for ((s2 = 15; s2 <= 150; s2 += 17)); do
        for ((s3 = 8; s3 <= 55; s3 += 7)); do for ((s4 = 4; s4 <= 27; s4++)); do
            got=$(_awg_size_collisions $s1 $s2 $s3 $s4) g=""
            while read -r c pp; do [[ -n "$c" ]] && g+="$c $pp "; done <<< "$got"
            oracle $s1 $s2 $s3 $s4
            n=$((n + 1))
            if [[ "${g% }" != "$ORACLE_OUT" ]]; then
                echo "S=$s1/$s2/$s3/$s4: got [${g% }] want [$ORACLE_OUT]"; bad=$((bad + 1))
                (( bad < 5 )) || break 4
            fi
        done; done; done; done
        echo "cases $n bad $bad"
    ' _ "$INST"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "${lines[-1]}" =~ ^cases\ ([0-9]+)\ bad\ 0$ ]] || { echo "$output"; return 1; }
    (( BASH_REMATCH[1] > 14000 ))
}

@test "collisions: the helper body is identical in the installers and the libraries" {
    local ref
    ref=$(sed -n '/^_awg_size_collisions()/,/^}/p' "$INST")
    [ -n "$ref" ]
    [ "$(sed -n '/^_awg_size_collisions()/,/^}/p' "$INST_EN")" = "$ref" ]
    [ "$(sed -n '/^_awg_size_collisions()/,/^}/p' "$COMMON")" = "$ref" ]
    [ "$(sed -n '/^_awg_size_collisions()/,/^}/p' "$COMMON_EN")" = "$ref" ]
}

@test "gen: no generated parameter set has a lossy length match, both protocols, both twins" {
    local pair inst lib proto s1 s2 s3 s4 n=0
    local -A s4seen
    for pair in "$INST|$COMMON" "$INST_EN|$COMMON_EN"; do
        inst="${pair%%|*}"; lib="${pair##*|}"
        for proto in 2.0 3.1; do
            run --separate-stderr gen "$inst" "$lib" "$proto" 75
            [ "$status" -eq 0 ] || { echo "$inst $proto: $stderr"; return 1; }
            s4seen=()
            while read -r s1 s2 s3 s4; do
                n=$((n + 1))
                oracle "$s1" "$s2" "$s3" "$s4"
                [ -z "$ORACLE_OUT" ] || { echo "match: $s1/$s2/$s3/$s4 ($inst $proto)"; return 1; }
                # S4 is a number inside its range (4..27 for 2.0, 12..27 for 3.1)
                [[ "$s4" =~ ^[0-9]+$ ]] && (( s4 >= (${proto%.*} == 3 ? 12 : 4) && s4 <= 27 )) \
                    || { echo "S4 out of range: [$s4] ($inst $proto)"; return 1; }
                s4seen[$s4]=1
            done <<< "$output"
            # S4 stays random among the free values, not pinned to the first one
            (( ${#s4seen[@]} >= 5 )) || { echo "S4 barely varies ($inst $proto): ${!s4seen[*]}"; return 1; }
        done
    done
    [ "$n" -eq 300 ]
}

@test "gen: an S4 that would lose packets is skipped, a harmless one stays, both twins" {
    local inst lib
    for pair in "$INST|$COMMON" "$INST_EN|$COMMON_EN"; do
        inst="${pair%%|*}"; lib="${pair##*|}"
        # 2.0, S1 = S2 = 24, S3 = 8: S4 = 4 gives a response match (P = 80, ciphertext), 5 is free
        run forced "$inst" "$lib" 2.0 24
        [ "$status" -eq 0 ]; [ "$output" = "8 5" ] || { echo "$inst 2.0/24: $output"; return 1; }
        # 2.0, S1 = S2 = 20: S4 = 4 matches nothing, so the lower bound stays
        run forced "$inst" "$lib" 2.0 20
        [ "$status" -eq 0 ]; [ "$output" = "8 4" ] || { echo "$inst 2.0/20: $output"; return 1; }
        # 3.1, S1 = S2 = 32, S3 = 12: S4 = 12 gives a response match (P = 80), 13 is free
        run forced "$inst" "$lib" 3.1 32
        [ "$status" -eq 0 ]; [ "$output" = "12 13" ] || { echo "$inst 3.1/32: $output"; return 1; }
        # 3.1, S1 = S2 = 20: S3 = S4 = 12 is the cookie length at the type offset, harmless
        run forced "$inst" "$lib" 3.1 20
        [ "$status" -eq 0 ]; [ "$output" = "12 12" ] || { echo "$inst 3.1/20: $output"; return 1; }
    done
}

@test "gen: without the helper the generator stops loudly instead of skipping the check, both twins" {
    local inst lib
    for pair in "$INST|$COMMON" "$INST_EN|$COMMON_EN"; do
        inst="${pair%%|*}"; lib="${pair##*|}"
        run forced "$inst" "$lib" 2.0 20 nohelper
        [ "$status" -ne 0 ]
        [[ "$output" == DIE:* ]] || { echo "$inst: $output"; return 1; }
    done
}

@test "warn: a matching config with a wide H range is named with sizes, share and the way to fix it, RU" {
    measured_conf
    run warn "$COMMON"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^WARN: ' <<< "$output")" -eq 2 ]
    grep -q '81-96' <<< "$output"
    grep -q 'в среднем молча теряет около 8\.61%' <<< "$output"
    grep -q 'ответом рукопожатия' <<< "$output"
    grep -qF -- 'sudo bash install_amneziawg.sh --force --preset=mobile (' <<< "$output"
    grep -qF -- "sudo bash $MANAGE_SCRIPT_PATH regen" <<< "$output"
    if grep -qE -- '--no-cps|сессию' <<< "$output"; then echo "$output"; return 1; fi
}

@test "warn: the same in English" {
    measured_conf
    run warn "$COMMON_EN"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^WARN: ' <<< "$output")" -eq 2 ]
    grep -q 'inner size of 81-96' <<< "$output"
    grep -q 'on average about 8\.61%' <<< "$output"
    grep -q 'the handshake response' <<< "$output"
    grep -qF -- 'sudo bash install_amneziawg_en.sh --force --preset=mobile (' <<< "$output"
    grep -qF -- "sudo bash $MANAGE_SCRIPT_PATH regen" <<< "$output"
}

@test "warn: the 0.1% threshold, one step above and one below, both twins" {
    local lib
    for lib in "$COMMON" "$COMMON_EN"; do
        # H2 width 4294968 = 0.1000000xx%: named as 0.10%
        server_conf 94 62 21 26 158796025-276895233 351164001-355458968 848364242-1111224741 1254688896-2141645164
        run warn "$lib"; [ "$status" -eq 0 ]
        grep -q '0\.10%' <<< "$output" || { echo "$lib above: $output"; return 1; }
        # width 4294967 = 0.0999999xx%: quiet
        server_conf 94 62 21 26 158796025-276895233 351164001-355458967 848364242-1111224741 1254688896-2141645164
        run warn "$lib"; [ "$status" -eq 0 ]; [ -z "$output" ] || { echo "$lib below: $output"; return 1; }
    done
}

@test "warn: each class takes its own H range, both twins" {
    local lib
    for lib in "$COMMON" "$COMMON_EN"; do
        # init match (P = 224): H1 is 10.00%, H2 and H3 are tiny
        server_conf 124 119 37 16 100000000-529496729 600000000-600000100 700000000-700000100 800000000-900000000
        run warn "$lib"; [ "$status" -eq 0 ]
        grep -q '209-224' <<< "$output" && grep -q '10\.00%' <<< "$output" || { echo "$lib init: $output"; return 1; }
        grep -qE 'инициацией|initiation' <<< "$output" || { echo "$lib init name: $output"; return 1; }
        # cookie match (P = 48): H3 is 10.00%, H1 and H2 are tiny
        server_conf 125 21 32 16 100000000-100000100 200000000-200000100 300000000-729496729 800000000-900000000
        run warn "$lib"; [ "$status" -eq 0 ]
        grep -q '33-48' <<< "$output" && grep -q '10\.00%' <<< "$output" || { echo "$lib cookie: $output"; return 1; }
        grep -qE 'cookie-ответом|cookie reply' <<< "$output" || { echo "$lib cookie name: $output"; return 1; }
    done
}

@test "warn: a response match at the receiver index says the loss goes by session, both twins" {
    local lib
    for lib in "$COMMON" "$COMMON_EN"; do
        # S2 - S4 = 4: P = 64, the check reads the receiver index
        server_conf 20 20 8 16 100000000-100000100 200000000-629496729 700000000-700000100 800000000-900000000
        run warn "$lib"; [ "$status" -eq 0 ]
        grep -q '49-64' <<< "$output" || { echo "$lib: $output"; return 1; }
        grep -qE 'постоянен на сессию|fixed for a session' <<< "$output" || { echo "$lib: $output"; return 1; }
    done
}

@test "warn: leading zeros are read as decimal, both twins" {
    local lib
    for lib in "$COMMON" "$COMMON_EN"; do
        server_conf 094 062 021 026 158796025-276895233 0351164001-0721039105 848364242-1111224741 1254688896-2141645164
        run warn "$lib"; [ "$status" -eq 0 ]
        grep -q '81-96' <<< "$output" && grep -q '8\.61%' <<< "$output" || { echo "$lib: $output"; return 1; }
        grep -q '94/62/21/26' <<< "$output" || { echo "$lib: $output"; return 1; }
        if grep -qiE 'value too great|syntax error|ERR:' <<< "$output"; then echo "$lib: $output"; return 1; fi
        # more zeros than the digit limit allows: still the same numbers
        server_conf 000094 062 021 026 158796025-276895233 00351164001-00721039105 848364242-1111224741 1254688896-2141645164
        run warn "$lib"; [ "$status" -eq 0 ]
        grep -q '81-96' <<< "$output" && grep -q '8\.61%' <<< "$output" || { echo "$lib long zeros: $output"; return 1; }
    done
}

@test "warn: --no-cps in the init goes into the advice, an unknown preset becomes default, both twins" {
    local lib
    for lib in "$COMMON" "$COMMON_EN"; do
        measured_conf
        printf "export AWG_PRESET='mobile'\nexport NO_CPS=1\n" > "$CONFIG_FILE"
        run warn "$lib"; [ "$status" -eq 0 ]
        grep -qF -- '--force --preset=mobile --no-cps (' <<< "$output" || { echo "$lib nocps: $output"; return 1; }
        printf "export AWG_PRESET='weird'\n" > "$CONFIG_FILE"
        run warn "$lib"; [ "$status" -eq 0 ]
        grep -qF -- '--force --preset=default (' <<< "$output" || { echo "$lib preset: $output"; return 1; }
    done
}

@test "warn: every lossy class of one config is named, both twins" {
    local lib
    for lib in "$COMMON" "$COMMON_EN"; do
        # init 144, response 64, cookie 48, each H 10% wide
        server_conf 44 20 32 16 100000000-529496729 600000000-1029496729 1100000000-1529496729 1600000000-2000000000
        run warn "$lib"; [ "$status" -eq 0 ]
        [ "$(grep -c '^WARN:  *- ' <<< "$output")" -eq 3 ] || { echo "$lib: $output"; return 1; }
        grep -q '129-144' <<< "$output" && grep -q '49-64' <<< "$output" && grep -q '33-48' <<< "$output" \
            || { echo "$lib: $output"; return 1; }
    done
}

@test "warn: an init match at the counter's high half is named only when H1 starts at 0, both twins" {
    local lib
    for lib in "$COMMON" "$COMMON_EN"; do
        # S1 - S4 = 12: P = 128, the check reads the high half of the counter (0)
        server_conf 28 21 8 16 0-10000000 20000000-30000000 40000000-50000000 60000000-70000000
        run warn "$lib"; [ "$status" -eq 0 ]
        grep -q '113-128' <<< "$output" || { echo "$lib zero: $output"; return 1; }
        grep -qE 'теряет все такие пакеты|drops every one of them' <<< "$output" || { echo "$lib zero: $output"; return 1; }
        server_conf 28 21 8 16 5-10000000 20000000-30000000 40000000-50000000 60000000-70000000
        run warn "$lib"; [ "$status" -eq 0 ]; [ -z "$output" ] || { echo "$lib from 5: $output"; return 1; }
    done
}

@test "warn: quiet with ContentPaddingAddition, where the length model does not apply, both twins" {
    local lib
    for lib in "$COMMON" "$COMMON_EN"; do
        measured_conf
        echo 'ContentPaddingAddition = 32-128' >> "$SERVER_CONF_FILE"
        run warn "$lib"; [ "$status" -eq 0 ]; [ -z "$output" ] || { echo "$lib: $output"; return 1; }
        # AWG_CPA left in the environment by the init (check loads it first) does
        # not count: only the config's own line does
        measured_conf
        AWG_CPA='32-128' run warn "$lib"; [ "$status" -eq 0 ]
        grep -q '81-96' <<< "$output" || { echo "$lib inherited CPA: $output"; return 1; }
    done
}

@test "warn: the same warning under set -u, with no CPA anywhere, both twins" {
    local lib
    for lib in "$COMMON" "$COMMON_EN"; do
        measured_conf
        run timeout 30 bash -c '
            log() { :; }; log_debug() { :; }; log_error() { echo "ERR: $*"; }
            log_warn() { echo "WARN: $*"; }
            source "$1" >/dev/null 2>&1 || true
            unset AWG_CPA
            set -u
            awg_size_collision_warn
        ' _ "$lib"
        [ "$status" -eq 0 ]
        grep -q '81-96' <<< "$output" || { echo "$lib: $output"; return 1; }
    done
}

@test "warn: spaces inside an H value do not shift the fields, both twins" {
    local lib
    for lib in "$COMMON" "$COMMON_EN"; do
        server_conf 94 62 21 26 '158796025 - 276895233' '351164001 - 721039105' 848364242-1111224741 1254688896-2141645164
        run warn "$lib"; [ "$status" -eq 0 ]
        grep -q '81-96' <<< "$output" && grep -q '8\.61%' <<< "$output" || { echo "$lib: $output"; return 1; }
    done
}

@test "warn: quiet without a match, and quiet when the matching H is a single value, both twins" {
    local lib
    for lib in "$COMMON" "$COMMON_EN"; do
        server_conf 124 119 37 14 220537072-688521551 862105484-864855642 1387298644-1625888777 1645059238-2073493020
        run warn "$lib"; [ "$status" -eq 0 ]; [ -z "$output" ] || { echo "$lib no match: $output"; return 1; }
        # the 3.1 shape: a response match (S2 - S4 = 4) with H2 = 2
        server_conf 20 20 8 16 1 2 3 4
        run warn "$lib"; [ "$status" -eq 0 ]; [ -z "$output" ] || { echo "$lib single H: $output"; return 1; }
    done
}

@test "warn: a missing config or S that is not a number gives no warning and no error, both twins" {
    local lib
    for lib in "$COMMON" "$COMMON_EN"; do
        rm -f "$SERVER_CONF_FILE"
        run warn "$lib"; [ "$status" -eq 0 ]; [ -z "$output" ] || { echo "$lib missing: $output"; return 1; }
        server_conf abc 62 21 26 158796025-276895233 351164001-721039105 848364242-1111224741 1254688896-2141645164
        run warn "$lib"; [ "$status" -eq 0 ]; [ -z "$output" ] || { echo "$lib non-numeric: $output"; return 1; }
    done
}

@test "check and diagnose call the warning, both manage twins" {
    local m
    for m in "${BATS_TEST_DIRNAME}/../manage_amneziawg.sh" "${BATS_TEST_DIRNAME}/../manage_amneziawg_en.sh"; do
        sed -n '/^check_server()/,/^}/p' "$m" | grep -q 'awg_size_collision_warn' || { echo "check: $m"; return 1; }
        sed -n '/^diagnose_server()/,/^}/p' "$m" | grep -q 'awg_size_collision_lines' || { echo "diagnose: $m"; return 1; }
    done
}
