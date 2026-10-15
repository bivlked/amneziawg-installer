#!/usr/bin/env bats
# Jc ceiling for clients on amneziawg-go.
#
# amneziawg-go sends the Jc junk packets, the non-empty I1-I5 and the handshake
# initiation in one SendBuffers call, and the batch holds 128 packets
# (conn/conn.go IdealBatchSize). Jc + non-empty I + 1 > 128 panics with "index
# out of range [128]" on the first handshake (amneziawg-go#111). The kernel
# module sends packet by packet and is not affected, so the server keeps
# working while the clients crash.
#
# New values are capped at 122, which leaves room for all five I. A config
# already over the line is warned about, never refused: step 6 of the installer,
# restore, check and diagnose keep their verdicts, and add/regen still issue the
# profile. An unfinished first install that carries a saved Jc over 122 has no
# profiles yet, so it stops and names the fix instead of shipping the set.
#
# Every case runs both twins and counts that both really ran.

# shellcheck disable=SC2016,SC2034,SC2154  # bash -c bodies expand in the child; $output/$status come from bats
export AWG_USERNS_ROOT=/nonexistent-awg-userns-root

bats_require_minimum_version 1.5.0

INST="${BATS_TEST_DIRNAME}/../install_amneziawg.sh"
INST_EN="${BATS_TEST_DIRNAME}/../install_amneziawg_en.sh"
COMMON="${BATS_TEST_DIRNAME}/../awg_common.sh"
COMMON_EN="${BATS_TEST_DIRNAME}/../awg_common_en.sh"
MANAGE="${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"
MANAGE_EN="${BATS_TEST_DIRNAME}/../manage_amneziawg_en.sh"

twins() {
    local seen=0 f
    for f in "$2" "$3"; do
        "$1" "$f" || return 1
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}
en() { [[ "$1" == *_en.sh ]]; }

# The warning names the upstream issue; counting it counts warnings.
MARK='amneziawg-go#111'

# ---------------------------------------------------------------- the rule

# ov <lib> <Jc> <number of I> : awg_jc_go_overflow, prints rc=N.
ov() {
    timeout 10 bash -c '
        log() { :; }; log_warn() { :; }; log_error() { :; }; log_debug() { :; }
        source "$1" >/dev/null 2>&1 || true
        declare -F awg_jc_go_overflow >/dev/null || { echo NO_FUNCTION; exit 3; }
        awg_jc_go_overflow "$2" "$3"; echo "rc=$?"
    ' _ "$1" "$2" "$3" 2>&1
}

o_table() {
    # "Jc I rc": rc 0 = the batch overflows.
    local spec jc ni want
    for spec in "122 5 1" "123 5 0" "126 1 1" "127 1 0" "127 0 1" "128 0 0" \
                "0 5 1" "4 1 1" "0127 1 0" "0126 1 1" "1000 0 0" "99999999999999999999 0 0" \
                "18446744073709551617 0 0" "" "abc 1 1" "127 6 1" "127 x 1"; do
        [[ -n "$spec" ]] || continue
        read -r jc ni want <<< "$spec"
        run ov "$1" "$jc" "$ni"
        [[ "$output" == "rc=$want" ]] || { echo "$1: Jc=$jc I=$ni gave '$output', want rc=$want"; return 1; }
    done
}
@test "rule: Jc + non-empty I + 1 > 128 overflows, leading zeros and long numbers are read as the tools read them, junk input is not an overflow, both twins" {
    twins o_table "$COMMON" "$COMMON_EN"
}

# ---------------------------------------------------------------- installer input

vjc() {
    timeout 10 bash -c '
        eval "$(sed -n "/^validate_jc_value()/,/^}/p" "$1")"
        declare -F validate_jc_value >/dev/null || { echo NO_FUNCTION; exit 3; }
        validate_jc_value "$2"; echo "rc=$?"
    ' _ "$1" "$2" 2>&1
}

i_cap() {
    local v
    for v in 0 6 122; do
        run vjc "$1" "$v"
        [[ "$output" == "rc=0" ]] || { echo "$1: --jc=$v refused: $output"; return 1; }
    done
    for v in 123 127 128; do
        run vjc "$1" "$v"
        [[ "$output" == "rc=1" ]] || { echo "$1: --jc=$v accepted: $output"; return 1; }
    done
}
@test "installer: --jc takes 0-122 and refuses 123-128, both twins" {
    twins i_cap "$INST" "$INST_EN"
}

# guard <installer> <state at start> <saved Jc> [CLI_JC] [CLI_PRESET] [switched]
# [CLI_JMIN] [auto fallback] : _awg_saved_jc_guard with a stub die, prints PASS
# or the DIE line.
guard() {
    timeout 10 bash -c '
        eval "$(sed -n "/^validate_jc_value()/,/^}/p" "$1")"
        eval "$(sed -n "/^_awg_saved_jc_guard()/,/^}/p" "$1")"
        declare -F _awg_saved_jc_guard >/dev/null || { echo NO_FUNCTION; exit 3; }
        die() { echo "DIE: $*"; exit 1; }
        CONFIG_FILE=/root/awg/awgsetup_cfg.init
        AWG_INSTALL_STATE_AT_START="$2" AWG_Jc="$3" CLI_JC="$4" CLI_PRESET="$5" AWG_GEN_SWITCHED="${6:-0}"
        CLI_JMIN="${7:-}" AWG_AUTO_FALLBACK="${8:-0}"
        _awg_saved_jc_guard
        echo PASS
    ' _ "$@" 2>&1
}

g_stops() {
    local want="--jc=" v
    # "125 " - a trailing space in the init line; the value reaches the config
    # with it and the validator trims it, so the guard must not call it a non-number.
    for v in 123 127 128 0127 "125 "; do
        run guard "$1" 2 "$v"
        [[ "$output" == "DIE: "*"Jc=$v"*"122"*"$want"* ]] || { echo "$1: unfinished install with saved Jc='$v' not stopped with the fix: $output"; return 1; }
    done
    # --jmin on an automatic fallback: _awg_fallback_params would carry the
    # saved Jc through CLI_JC, so the run is not exempt.
    run guard "$1" 2 127 '' '' 0 50 1
    [[ "$output" == "DIE: "*"Jc=127"* ]] || { echo "$1: --jmin on a fallback let the saved Jc through: $output"; return 1; }
}
@test "installer: an unfinished first install with a saved Jc over 122 stops and names the fix, both twins" {
    twins g_stops "$INST" "$INST_EN"
}

g_passes() {
    # Mirrors: a safe saved value; a finished install (its live awg0.conf wins
    # and step 6 warns); a new install (nothing saved); an explicit --jc or
    # --preset of this run (the generator takes over and validates); a
    # generation switch (J are generated anew); a value that is not a number;
    # --jmin without a fallback (the set is generated from the preset).
    local args
    for args in "2 122" "2 0" "2 00" "1 127" "0 ''" "2 127 6" "2 127 '' mobile" "2 127 '' '' 1" "2 abc" "2 127 '' '' 0 50 0"; do
        eval "run guard \"\$1\" $args"
        [[ "$output" == "PASS" ]] || { echo "$1 [$args]: stopped: $output"; return 1; }
    done
}
@test "installer: the guard lets through safe values, finished installs, explicit --jc/--preset, a generation switch and non-numbers, both twins" {
    twins g_passes "$INST" "$INST_EN"
}

g_wired() {
    # The guard runs in initialize_setup after its inputs are known (the state
    # at start, then the resolver that sets the generation switch and the
    # automatic fallback) and before the regenerate-or-keep decision. Called
    # earlier it would see empty inputs and pass everything.
    local body
    body=$(sed -n '/^initialize_setup() {$/,/^}$/p' "$1")
    [[ -n "$body" ]] || { echo "$1: initialize_setup not found"; return 1; }
    awk '/^    AWG_INSTALL_STATE_AT_START="\$install_state"$/{s=NR}
         /^    _awg31_resolve_protocol "\$install_state"$/{r=NR}
         /^    _awg_saved_jc_guard$/{g=NR}
         /^    if \[\[ -z "\$\{AWG_Jc:-\}" \]\]/{d=NR}
         END{exit !(s && r && g && d && s < r && r < g && g < d)}' <<< "$body" \
        || { echo "$1: guard not called between its inputs and the decision"; return 1; }
}
@test "installer: the guard is called before parameters are kept or regenerated, both twins" {
    twins g_wired "$INST" "$INST_EN"
}

# ---------------------------------------------------------------- validate_awg_config

# vconf <lib> <Jc> <extra lines, printf %b> [hpk] : validate_awg_config with
# warnings visible.
vconf() {
    local lib="$1" jc="$2" extra="$3" hpk="${4:-}"
    {
        printf '[Interface]\nPrivateKey = TESTKEY\nAddress = 10.9.9.1/24\nListenPort = 39743\n'
        printf 'Jc = %s\nJmin = 55\nJmax = 380\nS1 = 72\nS2 = 56\nS3 = 32\nS4 = 16\n' "$jc"
        if [[ -n "$hpk" ]]; then
            printf 'H1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\nHeaderProtectionKey = QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQA=\n'
        else
            printf 'H1 = 100000-800000\nH2 = 1000000-8000000\nH3 = 10000000-80000000\nH4 = 100000000-800000000\n'
        fi
        [[ -z "$extra" ]] || printf '%b\n' "$extra"
    } > "$BATS_TEST_TMPDIR/awg0.conf"
    AWG_DIR="$BATS_TEST_TMPDIR" SERVER_CONF_FILE="$BATS_TEST_TMPDIR/awg0.conf" CONFIG_FILE="$BATS_TEST_TMPDIR/none.init" timeout 30 bash -c '
        log() { echo "INFO: $*"; }; log_warn() { echo "WARN: $*"; }; log_debug() { :; }
        log_error() { echo "ERR: $*"; }
        source "$1" >/dev/null 2>&1 || true
        validate_awg_config; echo "rc=$?"
    ' _ "$lib"
}

vc_warns() {
    local hpk spec jc extra
    for hpk in "" hpk; do
        for spec in "127|I1 = <r 8>" "128|" "123|I1 = <r 8>\nI2 = <r 8>\nI3 = <r 8>\nI4 = <r 8>\nI5 = <r 8>" "127|i1 = <r 8>"; do
            jc="${spec%%|*}"; extra="${spec#*|}"
            run vconf "$1" "$jc" "$extra" "$hpk"
            [[ "$output" == *"rc=0"* && "$output" != *"ERR:"* ]] || { echo "$1 ${hpk:-plain} Jc=$jc: refused instead of warned: $output"; return 1; }
            [ "$(grep -c "^WARN: .*$MARK" <<< "$output")" -eq 1 ] || { echo "$1 ${hpk:-plain} Jc=$jc: no single warning: $output"; return 1; }
            [[ "$output" == *"WARN: "*"122"*"regen"* ]] || { echo "$1 ${hpk:-plain} Jc=$jc: the fix is not named: $output"; return 1; }
            # restore validates an unpacked copy with AWG_DIR pointing at it: the
            # command must name the installed manager, not the temporary directory.
            [[ "$output" == *"sudo bash /root/awg/manage_amneziawg.sh regen"* && "$output" != *"$BATS_TEST_TMPDIR/manage"* ]] || { echo "$1 ${hpk:-plain} Jc=$jc: the fix names a wrong path: $output"; return 1; }
        done
    done
}
@test "validate_awg_config: a config over the line passes with one warning and the fix, both key variants, both twins" {
    twins vc_warns "$COMMON" "$COMMON_EN"
}

vc_quiet() {
    # Mirrors: on the line or below, an empty I value, a repeated key (the
    # tools keep the last value, it is one I), and the last value empty.
    local hpk spec jc extra
    for hpk in "" hpk; do
        for spec in "126|I1 = <r 8>" "127|" "122|I1 = <r 8>\nI2 = <r 8>\nI3 = <r 8>\nI4 = <r 8>\nI5 = <r 8>" "127|I1 =" "4|I1 = <r 8>" \
                    "126|I1 = <r 8>\nI1 = <r 8>" "127|I1 = <r 8>\nI1 ="; do
            jc="${spec%%|*}"; extra="${spec#*|}"
            run vconf "$1" "$jc" "$extra" "$hpk"
            [[ "$output" == *"rc=0"* ]] || { echo "$1 ${hpk:-plain} Jc=$jc: refused: $output"; return 1; }
            [[ "$output" != *"$MARK"* ]] || { echo "$1 ${hpk:-plain} Jc=$jc [$extra]: warned: $output"; return 1; }
        done
        # An I under [Peer] is not the interface's: 126 + 1 + 1 stays on the
        # line. Only the warning is judged here, the verdict on a [Peer] I1-I5
        # belongs to other checks.
        run vconf "$1" 126 "I1 = <r 8>\n[Peer]\nPublicKey = QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQA=\nI2 = <r 8>" "$hpk"
        [[ "$output" == *"rc="* && "$output" != *"$MARK"* ]] || { echo "$1 ${hpk:-plain}: an I under [Peer] was counted: $output"; return 1; }
    done
}
@test "validate_awg_config: Jc on the line or below, and an empty I, give no warning, both key variants, both twins" {
    twins vc_quiet "$COMMON" "$COMMON_EN"
}

vc_still_refuses() {
    run vconf "$1" 129 "I1 = <r 8>"
    [[ "$output" == *"rc=1"* && "$output" == *"ERR: Jc=129"* ]] || { echo "$1: Jc = 129 not refused: $output"; return 1; }
}
vc_tools_view() {
    # The tools apply the last Jc, key case-insensitive. Without the header
    # protection key the range check reads "Jc" case-sensitively, so the
    # warning must not rely on it.
    local hpk
    for hpk in "" hpk; do
        run vconf "$1" 4 "jc = 127\nI1 = <r 8>" "$hpk"
        [[ "$output" == *"rc=0"* ]] || { echo "$1 ${hpk:-plain}: refused: $output"; return 1; }
        [ "$(grep -c "^WARN: Jc=127 .*$MARK" <<< "$output")" -eq 1 ] || { echo "$1 ${hpk:-plain}: a lower-case jc = 127 after Jc = 4 not warned: $output"; return 1; }
        run vconf "$1" 127 "jc = 4\nI1 = <r 8>" "$hpk"
        [[ "$output" == *"rc=0"* && "$output" != *"$MARK"* ]] || { echo "$1 ${hpk:-plain}: an overridden Jc = 127 warned: $output"; return 1; }
    done
}
@test "validate_awg_config: the warning follows the Jc the tools apply (last value, any case), both key variants, both twins" {
    twins vc_tools_view "$COMMON" "$COMMON_EN"
}

@test "validate_awg_config: Jc = 129 is still a refusal, not a warning, both twins" {
    twins vc_still_refuses "$COMMON" "$COMMON_EN"
}

vc_names_generation() {
    local ok2="Валидация конфига AmneziaWG 2.0: OK" ok3="Валидация конфига AmneziaWG 3.1: OK"
    en "$1" && ok2="AmneziaWG 2.0 config validation: OK" && ok3="AmneziaWG 3.1 config validation: OK"
    run vconf "$1" 4 "I1 = <r 8>" hpk
    [[ "$output" == *"INFO: $ok3"* && "$output" != *"2.0"* ]] || { echo "$1: a config with the key is not called 3.1: $output"; return 1; }
    run vconf "$1" 4 "I1 = <r 8>"
    [[ "$output" == *"INFO: $ok2"* ]] || { echo "$1: a config without the key is not called 2.0: $output"; return 1; }
}
@test "validate_awg_config: the OK line names 3.1 for a config with the header protection key and 2.0 without, both twins" {
    twins vc_names_generation "$COMMON" "$COMMON_EN"
}

# ---------------------------------------------------------------- add / regen

# crender <lib> <generation> <Jc> : two client renders in one process from an
# init with I1 set, warnings visible.
crender() {
    local lib="$1" gen="$2" jc="$3" d
    d="$BATS_TEST_TMPDIR/c-$(basename "$lib" .sh)-$gen-$jc"
    rm -rf "$d"; mkdir -p "$d/keys"
    {
        printf "export AWG_PORT=39743\nexport AWG_TUNNEL_SUBNET='10.9.9.1/24'\nexport DISABLE_IPV6=1\n"
        printf "export ALLOWED_IPS_MODE=1\nexport AWG_PROTOCOL='%s'\n" "$gen"
        if [[ "$gen" == 3.1 ]]; then
            printf "export AWG_CPA='32-128'\nexport AWG_H1='1'\nexport AWG_H2='2'\nexport AWG_H3='3'\nexport AWG_H4='4'\n"
        else
            printf "export AWG_H1='100000-800000'\nexport AWG_H2='1000000-8000000'\n"
            printf "export AWG_H3='10000000-80000000'\nexport AWG_H4='100000000-800000000'\n"
        fi
        printf "export AWG_S1=72\nexport AWG_S2=56\nexport AWG_S3=32\nexport AWG_S4=16\n"
        printf "export AWG_Jc=%s\nexport AWG_Jmin=55\nexport AWG_Jmax=380\nexport AWG_I1='<r 64>'\n" "$jc"
        # CR_FIVE_I=1: all five I set.
        [[ -z "${CR_FIVE_I:-}" ]] || printf "export AWG_I2='<r 8>'\nexport AWG_I3='<r 8>'\nexport AWG_I4='<r 8>'\nexport AWG_I5='<r 8>'\n"
        printf "export AWG_APPLY_MODE='syncconf'\n"
    } > "$d/awgsetup_cfg.init"
    printf 'SRVPRIVKEYPLACEHOLDER\n' > "$d/server_private.key"
    [[ "$gen" == 3.1 ]] && printf '%s\n' "QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQA=" > "$d/server_hpk.key"
    AWG_DIR="$d" timeout 60 bash -c '
        export CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init" SERVER_CONF_FILE="$AWG_DIR/awg0.conf"
        export KEYS_DIR="$AWG_DIR/keys" EXPIRY_DIR="$AWG_DIR/expiry"
        log() { :; }; log_warn() { echo "WARN: $*"; }; log_error() { echo "ERR: $*"; }; log_debug() { :; }
        # CR_INHERIT=1: a set flag in the environment must not mute the warning.
        [[ -z "${CR_INHERIT:-}" ]] || export _AWG_JC_GO_WARNED=1
        source "$1" >/dev/null 2>&1 || true
        get_main_nic() { echo eth0; }
        host_lacks_ipv4_egress() { return 1; }
        echo SERVERPUB > "$AWG_DIR/server_public.key"
        case "$2" in
            two) render_client_config c1 10.9.9.2 CLIENTPRIV SERVERPUB 203.0.113.10 39743 || exit 1
                 render_client_config c2 10.9.9.3 CLIENTPRIV SERVERPUB 203.0.113.10 39743 || exit 1 ;;
            # add: render, then the vpn:// export, in one run.
            addexport) render_client_config c1 10.9.9.2 CLIENTPRIV SERVERPUB 203.0.113.10 39743 || exit 1
                 generate_vpn_uri c1 || exit 1 ;;
            # modify: a later run that rebuilds only the export of an existing profile.
            export) render_client_config c1 10.9.9.2 CLIENTPRIV SERVERPUB 203.0.113.10 39743 >/dev/null 2>&1 || exit 1
                 _AWG_JC_GO_WARNED=""
                 echo "--- export run"
                 generate_vpn_uri c1 || exit 1 ;;
            # modify after the server was lowered without regen: the profile
            # still carries its own Jc, the server params are safe.
            diverge) render_client_config c1 10.9.9.2 CLIENTPRIV SERVERPUB 203.0.113.10 39743 >/dev/null 2>&1 || exit 1
                 _AWG_JC_GO_WARNED=""
                 sed -i "s/^export AWG_Jc=.*/export AWG_Jc=4/" "$CONFIG_FILE"
                 unset AWG_Jc
                 echo "--- export run"
                 generate_vpn_uri c1 || exit 1 ;;
            # the profile carries five I, the server one: the profile is
            # counted by its own I, not by those of the server.
            fivei) render_client_config c1 10.9.9.2 CLIENTPRIV SERVERPUB 203.0.113.10 39743 >/dev/null 2>&1 || exit 1
                 _AWG_JC_GO_WARNED=""
                 printf "I2 = <r 8>\nI3 = <r 8>\nI4 = <r 8>\nI5 = <r 8>\n" > "$AWG_DIR/i.tmp"
                 sed -i "/^I1 = /r $AWG_DIR/i.tmp" "$AWG_DIR/c1.conf"
                 echo "--- export run"
                 generate_vpn_uri c1 || true ;;
            # the same, on a machine without perl: generate_vpn_uri gives up on
            # the dependency, the QR modify rebuilt is still the dangerous one.
            noperl) render_client_config c1 10.9.9.2 CLIENTPRIV SERVERPUB 203.0.113.10 39743 >/dev/null 2>&1 || exit 1
                 _AWG_JC_GO_WARNED=""
                 sed -i "s/^export AWG_Jc=.*/export AWG_Jc=4/" "$CONFIG_FILE"
                 unset AWG_Jc
                 command() { [[ "$1 $2" == "-v perl" ]] && return 1; builtin command "$@"; }
                 echo "--- export run"
                 generate_vpn_uri c1
                 echo "URI_RC=$?" ;;
        esac
        echo RC=0
    ' _ "$lib" "${4:-two}"
}

# exported <output> : the part of the output after the "--- export run" mark.
exported() { sed -n '/^--- export run/,$p' <<< "$1"; }

cr_noperl() {
    # Runs without perl or python: the point is the machine that lacks them.
    local gen out
    for gen in 2.0 3.1; do
        run crender "$1" "$gen" 127 noperl
        [[ "$output" == *"URI_RC=1"* ]] || { echo "$1 $gen: the stub did not hide perl: $output"; return 1; }
        out=$(exported "$output")
        [ "$(grep -c "^WARN: Jc=127 .*$MARK" <<< "$out")" -eq 1 ] || { echo "$1 $gen: no warning when vpn:// gives up on perl: $out"; return 1; }
    done
}
cr_fivei() {
    local gen out
    for gen in 2.0 3.1; do
        run crender "$1" "$gen" 123 fivei
        out=$(exported "$output")
        [ "$(grep -c "^WARN: Jc=123 .*$MARK" <<< "$out")" -eq 1 ] || { echo "$1 $gen: a profile with five I and Jc=123 under a server with one I not warned: $output"; return 1; }
    done
}
@test "modify/export: the profile is counted by its own I1-I5, both generations, both twins" {
    twins cr_fivei "$COMMON" "$COMMON_EN"
}

@test "modify/export: the profile is checked even when vpn:// gives up for lack of perl, both generations, both twins" {
    twins cr_noperl "$COMMON" "$COMMON_EN"
}

cr_export() {
    command -v python3 >/dev/null || skip "python3 not available"
    perl -MCompress::Zlib -MMIME::Base64 -e 1 2>/dev/null || skip "perl Compress::Zlib not available"
    local gen out
    for gen in 2.0 3.1; do
        run crender "$1" "$gen" 127 addexport
        [[ "$output" == *"RC=0"* ]] || { echo "$1 $gen: add with export failed: $output"; return 1; }
        [ "$(grep -c "^WARN: .*$MARK" <<< "$output")" -eq 1 ] || { echo "$1 $gen: render plus export did not give exactly one warning: $output"; return 1; }
        run crender "$1" "$gen" 127 export
        [[ "$output" == *"RC=0"* ]] || { echo "$1 $gen: export failed: $output"; return 1; }
        out=$(exported "$output")
        [ "$(grep -c "^WARN: .*$MARK" <<< "$out")" -eq 1 ] || { echo "$1 $gen: an export on its own (modify) did not warn: $out"; return 1; }
        run crender "$1" "$gen" 126 export
        [[ "$output" == *"RC=0"* && "$output" != *"$MARK"* ]] || { echo "$1 $gen: Jc=126 export warned: $output"; return 1; }
        # The profile's own Jc counts even when the server's is already safe.
        run crender "$1" "$gen" 127 diverge
        [[ "$output" == *"RC=0"* ]] || { echo "$1 $gen: export after lowering failed: $output"; return 1; }
        out=$(exported "$output")
        [ "$(grep -c "^WARN: Jc=127 .*$MARK" <<< "$out")" -eq 1 ] || { echo "$1 $gen: a profile with Jc=127 exported silently under a safe server: $out"; return 1; }
    done
}
@test "modify/export: the vpn:// export warns on its own and once together with the render, both generations, both twins" {
    twins cr_export "$COMMON" "$COMMON_EN"
}

cr_warns_once() {
    local gen
    for gen in 2.0 3.1; do
        run crender "$1" "$gen" 127
        [[ "$output" == *"RC=0"* ]] || { echo "$1 $gen: profile not issued: $output"; return 1; }
        [ "$(grep -c "^WARN: .*$MARK" <<< "$output")" -eq 1 ] || { echo "$1 $gen: not exactly one warning for two profiles: $output"; return 1; }
        run crender "$1" "$gen" 126
        [[ "$output" == *"RC=0"* && "$output" != *"$MARK"* ]] || { echo "$1 $gen: Jc=126 with one I warned: $output"; return 1; }
        # All five I are counted, not only I1.
        CR_FIVE_I=1 run crender "$1" "$gen" 123
        [ "$(grep -c "^WARN: .*$MARK" <<< "$output")" -eq 1 ] || { echo "$1 $gen: Jc=123 with five I not warned: $output"; return 1; }
        CR_FIVE_I=1 run crender "$1" "$gen" 122
        [[ "$output" == *"RC=0"* && "$output" != *"$MARK"* ]] || { echo "$1 $gen: Jc=122 with five I warned: $output"; return 1; }
        # The flag cannot be inherited from the environment.
        CR_INHERIT=1 run crender "$1" "$gen" 127
        [ "$(grep -c "^WARN: .*$MARK" <<< "$output")" -eq 1 ] || { echo "$1 $gen: an inherited flag muted the warning: $output"; return 1; }
    done
}
@test "add/regen: a profile over the line is still issued, with one warning per run, and Jc on the line is quiet, both generations, both twins" {
    twins cr_warns_once "$COMMON" "$COMMON_EN"
}

# ---------------------------------------------------------------- manage check

# mcheck <manage> <Jc> <I lines in the dump> : check_server on an interface dump.
mcheck() {
    local src="$1" jc="$2" ilines="$3" common bin dir
    common="${src/manage_amneziawg/awg_common}"
    bin="$BATS_TEST_TMPDIR/binm-$jc-${#ilines}"
    mkdir -p "$bin"
    printf '#!/usr/bin/env bash\nprintf "interface: awg0\\n  listening port: 39743\\n  jc: %s\\n  jmin: 55\\n  jmax: 380\\n  s1: 72\\n%b"\n' "$jc" "$ilines" > "$bin/awg"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/systemctl"
    printf '#!/usr/bin/env bash\necho "5: awg0: <POINTOPOINT,UP> mtu 1280"\necho "    inet 10.9.9.1/24 scope global awg0"\n' > "$bin/ip"
    printf '#!/usr/bin/env bash\necho "UNCONN 0 0 0.0.0.0:39743 0.0.0.0:*"\n' > "$bin/ss"
    printf '#!/usr/bin/env bash\necho 1\n' > "$bin/sysctl"
    printf '#!/usr/bin/env bash\necho "amneziawg 155648 0"\n' > "$bin/lsmod"
    printf '#!/usr/bin/env bash\necho "Status: active"\necho "39743/udp ALLOW Anywhere"\n' > "$bin/ufw"
    chmod +x "$bin"/*
    dir="$BATS_TEST_TMPDIR/awgm-$jc-${#ilines}"
    mkdir -p "$dir"
    printf '[Interface]\nListenPort = 39743\nJc = %s\n' "$jc" > "$dir/awg0.conf"
    PATH="$bin:$PATH" AWG_DIR="$dir" CONFIG_FILE="$dir/awgsetup_cfg.init" SERVER_CONF_FILE="$dir/awg0.conf" \
    timeout 60 bash -c '
        set -o pipefail
        log()       { echo "INFO: $*"; }
        log_warn()  { echo "WARN: $*"; }
        log_error() { echo "ERR: $*"; }
        log_debug() { :; }
        source "$1" >/dev/null 2>&1 || true
        safe_load_config() { AWG_PORT=39743; return 0; }
        JSON_OUTPUT=0
        _JSON_EMITTED=0
        eval "$(awk "/^_json_utf8_sanitize\\(\\) \\{/,/^\\}/" "$2")"
        eval "$(awk "/^json_escape\\(\\) \\{/,/^\\}/" "$2")"
        eval "$(awk "/^json_out\\(\\) \\{/,/^\\}/" "$2")"
        eval "$(awk "/^_conf_jc\\(\\) \\{/,/^\\}/" "$2")"
        eval "$(awk "/^check_server\\(\\) \\{/,/^\\}/" "$2")"
        declare -F _conf_jc check_server >/dev/null || { echo "NO_FUNCTION"; exit 3; }
        check_server
        echo "rc=$?"
    ' _ "$common" "$src"
}

mc_warns() {
    local base over
    run mcheck "$1" 4 '  i1: <r 8>\n'
    base="$output"
    [[ "$base" != *NO_FUNCTION* && "$base" != *"$MARK"* ]] || { echo "$1: baseline broken or warned: $base"; return 1; }
    run mcheck "$1" 127 '  i1: <r 8>\n'
    over="$output"
    [ "$(grep -c "^WARN: .*$MARK" <<< "$over")" -eq 1 ] || { echo "$1: Jc=127 with I1 on the interface not warned once: $over"; return 1; }
    # A warning, not a failed check: the verdict is the baseline's.
    [ "$(grep '^rc=' <<< "$over")" = "$(grep '^rc=' <<< "$base")" ] || { echo "$1: the warning changed the verdict: $(grep '^rc=' <<< "$base") -> $(grep '^rc=' <<< "$over")"; return 1; }
    run mcheck "$1" 127 ''
    [[ "$output" != *"$MARK"* ]] || { echo "$1: Jc=127 without I warned: $output"; return 1; }
    # All five i lines are counted, and a number too long for bash arithmetic is
    # still over the line.
    local five='  i1: <r 8>\n  i2: <r 8>\n  i3: <r 8>\n  i4: <r 8>\n  i5: <r 8>\n'
    run mcheck "$1" 123 "$five"
    [ "$(grep -c "^WARN: .*$MARK" <<< "$output")" -eq 1 ] || { echo "$1: Jc=123 with five I not warned: $output"; return 1; }
    run mcheck "$1" 122 "$five"
    [[ "$output" != *NO_FUNCTION* && "$output" != *"$MARK"* ]] || { echo "$1: Jc=122 with five I warned: $output"; return 1; }
    run mcheck "$1" 18446744073709551617 ''
    [ "$(grep -c "^WARN: .*$MARK" <<< "$output")" -eq 1 ] || { echo "$1: a huge Jc wrapped under the line: $output"; return 1; }
}
@test "manage check: an interface over the line is one warning and keeps the verdict, both twins" {
    twins mc_warns "$MANAGE" "$MANAGE_EN"
}

# ---------------------------------------------------------------- diagnose step 8

# step8 <manage> <Jc> <I lines in the dump> : the step 8 block of diagnose,
# lifted by its comment borders as in test_jc_zero.bats.
step8() {
    printf '[Interface]\nListenPort = 39743\nJc = %s\n' "$2" > "$BATS_TEST_TMPDIR/d8.conf"
    SERVER_CONF_FILE="$BATS_TEST_TMPDIR/d8.conf" timeout 60 bash -c '
        MANAGE="$1"; JC="$2"; IL="$3"; _cps_unsafe=0
        warn=0; fail=0
        _diag_line() { echo "[$1] ${*:2}"; }
        _mask_report_secrets() { cat; }
        eval "$(awk "/^_awg_dec_strip\\(\\) \\{/,/^\\}/" "${MANAGE/manage_amneziawg/awg_common}")"
        eval "$(awk "/^_awg_conf_pairs\\(\\) \\{/,/^\\}/" "${MANAGE/manage_amneziawg/awg_common}")"
        eval "$(awk "/^_conf_jc\\(\\) \\{/,/^\\}/" "$MANAGE")"
        awg() { printf "interface: awg0\n  jc: %s\n  jmin: 55\n  jmax: 380\n  s1: 72\n%b" "$JC" "$IL"; }
        timeout() { shift; "$@"; }
        block=$(awk "/# 8\. AWG params snapshot/,/# 9\. Carrier comparison/" "$MANAGE" | sed "\$d")
        [[ -n "$block" ]] || { echo "NO_BLOCK"; exit 3; }
        step() { eval "$block"; echo "warn=$warn fail=$fail"; }
        step 2> >(sed "s/^/HARNESS_ERR: /")
        wait
    ' _ "$1" "$2" "$3"
}

d_warns() {
    run step8 "$1" 127 '  i1: <r 8>\n'
    [[ "$output" != *HARNESS_ERR* && "$output" != *NO_BLOCK* ]] || { echo "$1: harness broken: $output"; return 1; }
    [[ "$output" == *"[WARN] "*"$MARK"* && "$output" == *"warn=1 fail=0"* ]] || { echo "$1: Jc=127 with I1 not a counted warning: $output"; return 1; }
    [[ "$output" == *"122"* ]] || { echo "$1: the fix is not named: $output"; return 1; }
    run step8 "$1" 126 '  i1: <r 8>\n'
    [[ "$output" != *HARNESS_ERR* && "$output" != *"$MARK"* && "$output" == *"warn=0 fail=0"* ]] || { echo "$1: Jc=126 with I1 warned: $output"; return 1; }
    run step8 "$1" 123 '  i1: <r 8>\n  i2: <r 8>\n  i3: <r 8>\n  i4: <r 8>\n  i5: <r 8>\n'
    [[ "$output" == *"[WARN] "*"$MARK"* && "$output" == *"fail=0"* ]] || { echo "$1: Jc=123 with five I not warned: $output"; return 1; }
    run step8 "$1" 122 '  i1: <r 8>\n  i2: <r 8>\n  i3: <r 8>\n  i4: <r 8>\n  i5: <r 8>\n'
    [[ "$output" != *HARNESS_ERR* && "$output" != *"$MARK"* ]] || { echo "$1: Jc=122 with five I warned: $output"; return 1; }
    run step8 "$1" 18446744073709551617 ''
    [[ "$output" != *HARNESS_ERR* && "$output" == *"[WARN] "*"$MARK"* ]] || { echo "$1: a huge Jc wrapped under the line: $output"; return 1; }
}
@test "diagnose: an interface over the line is a counted warning with the fix, not a failure, both twins" {
    twins d_warns "$MANAGE" "$MANAGE_EN"
}

# ---------------------------------------------------------------- help and docs

h_help() {
    local want="--jc=N               Задать Jc вручную (0-122" doc="$BATS_TEST_DIRNAME/../ADVANCED.md"
    en "$1" && want="--jc=N               Set Jc manually (0-122" && doc="$BATS_TEST_DIRNAME/../ADVANCED.en.md"
    grep -qF -- "$want" "$1" || { echo "$1: --help does not show 0-122"; return 1; }
    [ "$(grep -cE -- '--jc=N.*0-128' "$1" "$doc" | awk -F: '{s+=$NF} END{print s}')" -eq 0 ] || { echo "$1: 0-128 left in --help or ADVANCED"; return 1; }
    grep -qE -- '^\| `--jc=N` \| 0-122 \|' "$doc" || { echo "$doc: the flag table does not show 0-122"; return 1; }
}
@test "help and ADVANCED: --jc shows 0-122, both twins" {
    twins h_help "$INST" "$INST_EN"
}
