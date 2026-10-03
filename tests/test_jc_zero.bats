#!/usr/bin/env bats
# --jc=0: junk packets switched off.
#
# Both implementations accept Jc = 0 and then send no junk packets before the
# handshake: the kernel module guards the burst with `if (wg->jc && wg->jmax)`
# (src/send.c), amneziawg-go loops `for range device.junk.count.Load()`, the
# tools parse Jc as a plain uint16, and the vendor client passes the value on
# as a string. Some networks let only the first packet of an attempt through,
# and there a profile without junk packets is the one that connects (I#300).
# The installer used to refuse anything below 1, and validate_awg_config did
# the same (step 6 and restored backups).
#
# Jc = 0 changes nothing else: Jmin/Jmax keep their 0..1280 bounds and the
# Jmin <= Jmax rule, presets keep their values, and I1 is generated as usual.
#
# One trap comes with it: `awg show` prints the "jc:" line only when the value
# is non-zero (amneziawg-tools show.c), so every place that treated "jc:" as
# "the obfuscation parameters are on" would call a Jc = 0 server broken. Those
# places now read a missing jc line as Jc = 0 only when S or H lines prove the
# output is an AWG dump, and then check the zero against the Jc that was set:
# a zero nobody asked for is a warning, and output without S/H lines stays
# "unknown", never "zero".
#
# Every case runs both twins and counts that both really ran. Refusals that
# print a reason are asserted by it, not only by the exit status.

# shellcheck disable=SC2016,SC2034,SC2154  # bash -c bodies expand in the child; $output/$status come from bats
bats_require_minimum_version 1.5.0

INST="${BATS_TEST_DIRNAME}/../install_amneziawg.sh"
INST_EN="${BATS_TEST_DIRNAME}/../install_amneziawg_en.sh"
COMMON="${BATS_TEST_DIRNAME}/../awg_common.sh"
COMMON_EN="${BATS_TEST_DIRNAME}/../awg_common_en.sh"
MANAGE="${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"
MANAGE_EN="${BATS_TEST_DIRNAME}/../manage_amneziawg_en.sh"

# twins <function> <ru-file> <en-file> : run <function> on both files, check both ran.
twins() {
    local seen=0 f
    for f in "$2" "$3"; do
        "$1" "$f" || return 1
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}
en() { [[ "$1" == *_en.sh ]]; }

# ---------------------------------------------------------------- validator

# vjc <installer> <value> : validate_jc_value from the installer, prints rc=N.
vjc() {
    timeout 10 bash -c '
        eval "$(sed -n "/^validate_jc_value()/,/^}/p" "$1")"
        declare -F validate_jc_value >/dev/null || { echo NO_FUNCTION; exit 3; }
        validate_jc_value "$2"; echo "rc=$?"
    ' _ "$1" "$2" 2>&1
}

v_accepts() {
    local v
    for v in 0 1 3 128; do
        run vjc "$1" "$v"
        [[ "$output" == "rc=0" ]] || { echo "$1: --jc=$v refused: $output"; return 1; }
    done
}
@test "validator: 0, 1, 3 and 128 are accepted, both twins" {
    twins v_accepts "$INST" "$INST_EN"
}

v_refuses() {
    # 00 and 08: a leading zero either stores a non-canonical value or, in
    # arithmetic, is read as octal (08 is an error there).
    local v
    for v in 129 1000 -1 abc "" " 0" 00 08 010 1.5; do
        run vjc "$1" "$v"
        [[ "$output" == "rc=1" ]] || { echo "$1: --jc='$v' not refused cleanly: $output"; return 1; }
    done
}
@test "validator: 129, negative, empty, non-numeric and leading zeros are refused, both twins" {
    twins v_refuses "$INST" "$INST_EN"
}

# ---------------------------------------------------------------- generator

# gen <installer> <lib> <protocol> <preset|-> <jc> [jmin jmax] : generate_awg_params
# with CLI_JC, prints "Jc Jmin Jmax I1-set" or the DIE line, and the log.
gen() {
    timeout 120 bash -c '
        log() { echo "LOG: $*"; }; log_warn() { :; }; log_error() { :; }; log_debug() { :; }
        die() { echo "DIE: $*"; exit 1; }
        source "$2" >/dev/null 2>&1 || true
        for f in rand_range validate_jc_value validate_junk_size generate_awg_h_ranges generate_cps_i1 generate_awg_params; do
            eval "$(sed -n "/^${f}()/,/^}/p" "$1")"
        done
        unset CLI_PRESET CLI_JC CLI_JMIN CLI_JMAX
        export AWG_PROTOCOL="$3"
        [[ "$4" == "-" ]] || CLI_PRESET="$4"
        CLI_JC="$5"
        [[ -z "${6:-}" ]] || CLI_JMIN="$6"
        [[ -z "${7:-}" ]] || CLI_JMAX="$7"
        generate_awg_params
        echo "RESULT $AWG_Jc $AWG_Jmin $AWG_Jmax ${AWG_I1:+i1set}"
    ' _ "$1" "$2" "$3" "$4" "$5" "${6:-}" "${7:-}"
}

g_zero() {
    local inst="$1" lib="$COMMON" proto preset r
    en "$inst" && lib="$COMMON_EN"
    for proto in 2.0 3.1; do
        for preset in - default mobile; do
            run gen "$inst" "$lib" "$proto" "$preset" 0
            r=$(grep '^RESULT ' <<< "$output") || { echo "$inst $proto $preset: no result: $output"; return 1; }
            read -r _ jc jmin jmax i1 <<< "$r"
            [ "$jc" = 0 ] || { echo "$inst $proto $preset: Jc=$jc, not 0"; return 1; }
            # The size bounds stay in force with the junk switched off.
            (( jmin <= jmax && jmax <= 1280 )) || { echo "$inst $proto $preset: Jmin=$jmin Jmax=$jmax"; return 1; }
            # --jc=0 is not --no-cps: I1 is generated as usual.
            [ "$i1" = i1set ] || { echo "$inst $proto $preset: I1 lost with --jc=0"; return 1; }
            # The log says what the zero means, so nobody reads it as a bug.
            local want="junk-пакеты перед рукопожатием выключены"
            en "$inst" && want="junk packets before the handshake are off"
            [[ "$output" == *"$want"* ]] || { echo "$inst $proto $preset: zero not named in the log: $output"; return 1; }
        done
    done
}
@test "generator: --jc=0 gives Jc=0 on both generations and every preset, keeps Jmin<=Jmax and I1, both twins" {
    twins g_zero "$INST" "$INST_EN"
}

g_nonzero_silent() {
    # The mirror: a non-zero Jc must not claim the junk packets are off.
    local inst="$1" lib="$COMMON"
    en "$inst" && lib="$COMMON_EN"
    run gen "$inst" "$lib" 2.0 - 4
    [[ "$output" == *"RESULT 4 "* ]] || { echo "$inst: --jc=4 not applied: $output"; return 1; }
    [[ "$output" != *"выключены"* && "$output" != *"are off"* ]] || { echo "$inst: --jc=4 called off: $output"; return 1; }
}
@test "generator: a non-zero --jc is applied and not called off, both twins" {
    twins g_nonzero_silent "$INST" "$INST_EN"
}

g_bounds_kept() {
    local inst="$1" lib="$COMMON" want
    en "$inst" && lib="$COMMON_EN"
    run gen "$inst" "$lib" 2.0 - 0 300 200
    want="не может быть меньше"
    en "$inst" && want="cannot be less than"
    [[ "$output" == *"DIE: "*"$want"* ]] || { echo "$inst: Jmax<Jmin passed with --jc=0: $output"; return 1; }
    run gen "$inst" "$lib" 2.0 - 0 0 0
    [[ "$output" == *"RESULT 0 0 0 "* ]] || { echo "$inst: --jc=0 --jmin=0 --jmax=0 refused: $output"; return 1; }
}
@test "generator: Jmin<=Jmax is still enforced with --jc=0, and an all-zero junk set is allowed, both twins" {
    twins g_bounds_kept "$INST" "$INST_EN"
}

g_refusal_text() {
    local inst="$1" lib="$COMMON" want
    en "$inst" && lib="$COMMON_EN"
    run gen "$inst" "$lib" 2.0 - 129
    want="допустимо: 0-128"
    en "$inst" && want="allowed: 0-128"
    [[ "$output" == *"DIE: "*"--jc=129"*"$want"* ]] || { echo "$inst: refusal does not name 0-128: $output"; return 1; }
}
@test "generator: an out-of-range --jc is refused with the 0-128 range in the reason, both twins" {
    twins g_refusal_text "$INST" "$INST_EN"
}

h_help() {
    local want="--jc=N               Задать Jc вручную (0-128"
    en "$1" && want="--jc=N               Set Jc manually (0-128"
    grep -qF -- "$want" "$1" || { echo "$1: --help does not show 0-128"; return 1; }
    [ "$(grep -c -- '--jc=N.*1-128' "$1")" -eq 0 ] || { echo "$1: --help still says 1-128"; return 1; }
}
@test "help: --jc shows the 0-128 range, both twins" {
    twins h_help "$INST" "$INST_EN"
}

# ---------------------------------------------------------------- resume

r_resume() {
    # A re-run after a reboot loads the init. "0" must come back as the saved
    # value, not as "missing": initialize_setup regenerates the whole set when
    # AWG_Jc is empty, which on a live server would break every client.
    local inst="$1" out
    printf "export AWG_Jc=0\nexport AWG_Jmin=55\nexport AWG_Jmax=380\n" > "$BATS_TEST_TMPDIR/init"
    out=$(timeout 10 bash -c '
        log() { :; }; log_warn() { :; }; log_error() { :; }; log_debug() { :; }
        eval "$(sed -n "/^safe_load_config()/,/^}/p" "$1")"
        safe_load_config "$2" || { echo "LOAD_FAILED"; exit 1; }
        echo "Jc=[${AWG_Jc-unset}]"
    ' _ "$inst" "$BATS_TEST_TMPDIR/init")
    [ "$out" = "Jc=[0]" ] || { echo "$inst: saved Jc=0 came back as: $out"; return 1; }
    # The regeneration decision itself, lifted from initialize_setup and run
    # with a stub generator: a saved zero must keep the set.
    run decide "$inst" 0 ""
    [[ "$output" == *"DECIDED"* ]] || { echo "$inst: the decision block did not run: $output"; return 1; }
    # A truncated block still prints DECIDED after a syntax error.
    [[ "$output" != *"syntax error"* && "$output" != *"command not found"* ]] || { echo "$inst: the lifted block is broken: $output"; return 1; }
    [[ "$output" != *"GENERATED"* ]] || { echo "$inst: a saved Jc=0 regenerated the whole set: $output"; return 1; }
}
@test "resume: a saved Jc=0 is loaded as 0 and does not trigger regeneration, both twins" {
    twins r_resume "$INST" "$INST_EN"
}

# decide <installer> <saved AWG_Jc> <CLI_JC> : the "regenerate or keep" block of
# initialize_setup (from its `if [[ -z "${AWG_Jc:-}" ]]` to the closing `fi` at
# its own indent) with stubs; prints GENERATED when the generator was called.
decide() {
    timeout 10 bash -c '
        block=$(awk '\''/^    if \[\[ -z "\$\{AWG_Jc:-\}" \]\]/{on=1} on{print} on && /^    fi$/{exit}'\'' "$1")
        [[ -n "$block" ]] || { echo "NO_BLOCK"; exit 3; }
        log() { :; }; log_warn() { :; }
        generate_awg_params() { echo GENERATED; }
        _awg_switch_params() { echo GENERATED; }
        config_exists=1 MANAGE_SCRIPT_PATH=/x
        unset CLI_PRESET CLI_JMIN CLI_JMAX AWG_GEN_SWITCHED
        AWG_Jc="$2"
        if [[ -n "$3" ]]; then CLI_JC="$3"; else unset CLI_JC; fi
        f() { eval "$block"; }
        f
        echo DECIDED
    ' _ "$1" "$2" "$3" 2>&1
}

d_mirrors_regen() {
    # Mirrors: nothing saved regenerates, and an explicit --jc=0 on a re-run
    # regenerates too (CLI_JC="0" is a set flag, not an absent one).
    run decide "$1" "" ""
    [[ "$output" == *"GENERATED"*"DECIDED"* ]] || { echo "$1: an empty saved Jc did not regenerate: $output"; return 1; }
    run decide "$1" 5 0
    [[ "$output" == *"GENERATED"*"DECIDED"* ]] || { echo "$1: an explicit --jc=0 was ignored on a re-run: $output"; return 1; }
}
@test "resume: no saved Jc and an explicit --jc=0 both regenerate, both twins" {
    twins d_mirrors_regen "$INST" "$INST_EN"
}

# ---------------------------------------------------------------- render, regen, vpn://

# lib_run <lib> <generation> <snippet> : an install with Jc=0 in $AWG_DIR.
lib_run() {
    local lib="$1" gen="$2" snippet="$3" d
    d="$BATS_TEST_TMPDIR/r-$(basename "$lib" .sh)-$gen"
    rm -rf "$d"; mkdir -p "$d/keys"
    {
        printf "export AWG_PORT=39743\nexport AWG_TUNNEL_SUBNET='10.9.9.1/24'\nexport DISABLE_IPV6=1\n"
        printf "export ALLOWED_IPS_MODE=1\nexport AWG_PROTOCOL='%s'\n" "$gen"
        if [[ "$gen" == 3.1 ]]; then
            printf "export AWG_CPA='32-128'\nexport AWG_H1='1'\nexport AWG_H2='2'\nexport AWG_H3='3'\nexport AWG_H4='4'\n"
            printf "export AWG_S1=72\nexport AWG_S2=56\nexport AWG_S3=32\nexport AWG_S4=16\n"
        else
            printf "export AWG_H1='100000-800000'\nexport AWG_H2='1000000-8000000'\n"
            printf "export AWG_H3='10000000-80000000'\nexport AWG_H4='100000000-800000000'\n"
            printf "export AWG_S1=72\nexport AWG_S2=56\nexport AWG_S3=32\nexport AWG_S4=16\n"
        fi
        printf "export AWG_Jc=0\nexport AWG_Jmin=55\nexport AWG_Jmax=380\nexport AWG_I1='<r 64>'\n"
        printf "export AWG_APPLY_MODE='syncconf'\n"
    } > "$d/awgsetup_cfg.init"
    printf 'SRVPRIVKEYPLACEHOLDER\n' > "$d/server_private.key"
    [[ "$gen" == 3.1 ]] && printf '%s\n' "QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQA=" > "$d/server_hpk.key"
    AWG_DIR="$d" timeout 60 bash -c '
        export CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init" SERVER_CONF_FILE="$AWG_DIR/awg0.conf"
        export KEYS_DIR="$AWG_DIR/keys" EXPIRY_DIR="$AWG_DIR/expiry"
        log() { :; }; log_warn() { :; }; log_error() { echo "ERR: $*"; }; log_debug() { :; }
        source "$1" >/dev/null 2>&1 || true
        get_main_nic() { echo eth0; }
        host_lacks_ipv4_egress() { return 1; }
        eval "$2"
    ' _ "$lib" "$snippet"
}

rr_render() {
    local lib="$1" gen d out f
    for gen in 2.0 3.1; do
        d="$BATS_TEST_TMPDIR/r-$(basename "$lib" .sh)-$gen"
        # First render from the init, the client, then a second server render:
        # on a reinstall the parameters are re-read from the live awg0.conf,
        # which is the path regen takes too.
        out=$(lib_run "$lib" "$gen" '
            render_server_config || exit 1
            render_client_config c1 10.9.9.2 CLIENTPRIV SERVERPUB 203.0.113.10 39743 || exit 1
            unset AWG_Jc
            render_server_config || exit 1
            render_client_config c2 10.9.9.3 CLIENTPRIV SERVERPUB 203.0.113.10 39743 || exit 1
            validate_awg_config || exit 1
            echo "RC=0 JC=[$AWG_Jc]"')
        [[ "$out" == *"RC=0 JC=[0]"* ]] || { echo "$lib $gen: render/validate failed: $out"; return 1; }
        for f in "$d/awg0.conf" "$d/c1.conf" "$d/c2.conf"; do
            grep -qx 'Jc = 0' "$f" || { echo "$lib $gen: no 'Jc = 0' in $f: $(grep -i '^jc' "$f")"; return 1; }
            grep -qx 'Jmin = 55' "$f" || { echo "$lib $gen: Jmin lost in $f"; return 1; }
            grep -qx 'I1 = <r 64>' "$f" || { echo "$lib $gen: I1 lost in $f"; return 1; }
        done
    done
}
@test "render: Jc=0 reaches the server and client configs, survives the reload regen uses, and validates, both generations and twins" {
    twins rr_render "$COMMON" "$COMMON_EN"
}

rr_vpnuri() {
    command -v python3 >/dev/null || skip "python3 not available"
    perl -MCompress::Zlib -MMIME::Base64 -e 1 2>/dev/null || skip "perl Compress::Zlib not available"
    local lib="$1" d out inner
    d="$BATS_TEST_TMPDIR/r-$(basename "$lib" .sh)-2.0"
    out=$(lib_run "$lib" 2.0 '
        render_server_config || exit 1
        render_client_config c1 10.9.9.2 CLIENTPRIV SERVERPUB 203.0.113.10 39743 || exit 1
        echo SERVERPUB > "$AWG_DIR/server_public.key"
        generate_vpn_uri c1 || exit 1
        echo RC=0')
    [[ "$out" == *"RC=0"* ]] || { echo "$lib: vpn:// failed: $out"; return 1; }
    inner=$(python3 - "$(cat "$d/c1.vpnuri")" <<'PY'
import base64, zlib, json, sys
uri = sys.argv[1].replace("vpn://", "")
raw = base64.urlsafe_b64decode(uri + "=" * (-len(uri) % 4))
print(json.loads(zlib.decompress(raw[4:]))["containers"][0]["awg"]["last_config"])
PY
)
    [[ "$inner" == *'"Jc":"0"'* ]] || { echo "$lib: vpn:// has no Jc 0: $inner"; return 1; }
}
@test "vpn://: the import link carries Jc 0, both twins" {
    twins rr_vpnuri "$COMMON" "$COMMON_EN"
}

# ---------------------------------------------------------------- validate_awg_config

# vconf <lib> <Jc value> [hpk] : validate_awg_config on a config with that Jc.
vconf() {
    local lib="$1" jc="$2" hpk="${3:-}"
    {
        printf '[Interface]\nPrivateKey = TESTKEY\nAddress = 10.9.9.1/24\nListenPort = 39743\n'
        printf 'Jc = %s\nJmin = 55\nJmax = 380\nS1 = 72\nS2 = 56\nS3 = 32\nS4 = 16\n' "$jc"
        if [[ -n "$hpk" ]]; then
            printf 'H1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\nHeaderProtectionKey = QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQA=\n'
        else
            printf 'H1 = 100000-800000\nH2 = 1000000-8000000\nH3 = 10000000-80000000\nH4 = 100000000-800000000\n'
        fi
    } > "$BATS_TEST_TMPDIR/awg0.conf"
    AWG_DIR="$BATS_TEST_TMPDIR" SERVER_CONF_FILE="$BATS_TEST_TMPDIR/awg0.conf" timeout 30 bash -c '
        log() { :; }; log_warn() { :; }; log_debug() { :; }
        log_error() { echo "ERR: $*"; }
        source "$1" >/dev/null 2>&1 || true
        validate_awg_config; echo "rc=$?"
    ' _ "$lib"
}

vc_zero() {
    local hpk
    for hpk in "" hpk; do
        run vconf "$1" 0 "$hpk"
        [[ "$output" == *"rc=0"* ]] || { echo "$1 ${hpk:-plain}: Jc = 0 refused: $output"; return 1; }
    done
}
@test "validate_awg_config: Jc = 0 passes with and without the header protection key, both twins" {
    twins vc_zero "$COMMON" "$COMMON_EN"
}

vc_129() {
    local hpk want="вне допустимого диапазона (0-128)"
    en "$1" && want="is out of range (0-128)"
    for hpk in "" hpk; do
        run vconf "$1" 129 "$hpk"
        [[ "$output" == *"rc=1"* ]] || { echo "$1 ${hpk:-plain}: Jc = 129 passed: $output"; return 1; }
        [[ "$output" == *"Jc=129 $want"* ]] || { echo "$1 ${hpk:-plain}: reason does not name 0-128: $output"; return 1; }
    done
}
@test "validate_awg_config: Jc = 129 is still refused, by its reason, both twins" {
    twins vc_129 "$COMMON" "$COMMON_EN"
}

vc_bounds() {
    # The tools read Jc with strtoul base 10: 08 is 8, 0200 is 200, 00 is 0.
    # Bash arithmetic would read 0200 as octal 128 and wrap a 20-digit number,
    # so the check strips zeros and caps the length first.
    local hpk v
    for hpk in "" hpk; do
        for v in 128 00 08 0128; do
            run vconf "$1" "$v" "$hpk"
            [[ "$output" == *"rc=0"* && "$output" != *"ERR"* ]] || { echo "$1 ${hpk:-plain}: Jc = $v refused: $output"; return 1; }
        done
        for v in 0200 1000 9223372036854775808 18446744073709551615 18446744073709551621; do
            run vconf "$1" "$v" "$hpk"
            [[ "$output" == *"rc=1"* && "$output" == *"(0-128)"* ]] || { echo "$1 ${hpk:-plain}: Jc = $v not refused by range: $output"; return 1; }
        done
    done
}
@test "validate_awg_config: 128 and zero-padded small values pass, 0200 and oversized values are refused by range, both twins" {
    twins vc_bounds "$COMMON" "$COMMON_EN"
}

# ---------------------------------------------------------------- installer step 7

# awg_stub <dir> <mode> : awg show for an interface with Jc>0 (jc), Jc=0 (zero:
# no jc line, the rest present) or no AWG lines at all (bare).
awg_stub() {
    mkdir -p "$1"
    case "$2" in
        jc)   printf '#!/usr/bin/env bash\nprintf "interface: awg0\\n  listening port: 39743\\n  jc: 4\\n  jmin: 55\\n  jmax: 380\\n  s1: 72\\n"\n' > "$1/awg" ;;
        zero) printf '#!/usr/bin/env bash\nprintf "interface: awg0\\n  listening port: 39743\\n  jmin: 55\\n  jmax: 380\\n  s1: 72\\n  s2: 56\\n"\n' > "$1/awg" ;;
        bare) printf '#!/usr/bin/env bash\nprintf "interface: awg0\\n  listening port: 39743\\n"\n' > "$1/awg" ;;
        # Jc = Jmin = Jmax = 0: only the S lines are left to recognise the dump.
        sonly) printf '#!/usr/bin/env bash\nprintf "interface: awg0\\n  listening port: 39743\\n  s1: 72\\n"\n' > "$1/awg" ;;
        # Jmin/Jmax alone prove nothing: at Jc = 0 they have no effect.
        jonly) printf '#!/usr/bin/env bash\nprintf "interface: awg0\\n  listening port: 39743\\n  jmin: 55\\n  jmax: 380\\n"\n' > "$1/awg" ;;
    esac
    chmod +x "$1/awg"
}

# step7 <installer> <mode> [AWG_Jc] : check_service_status with stubs, log
# lines and rc. AWG_Jc is the value the installer set (default 0).
step7() {
    local bin="$BATS_TEST_TMPDIR/bin7-$2" body
    awg_stub "$bin" "$2"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$bin/systemctl"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/ip"
    printf '#!/usr/bin/env bash\nprintf "UNCONN 0 0 0.0.0.0:39743 0.0.0.0:*\\n"\n' > "$bin/ss"
    chmod +x "$bin"/*
    body=$(sed -n '/^check_service_status() {$/,/^}$/p' "$1")
    [[ -n "$body" ]] || { echo "NO_FUNCTION in $1"; return 3; }
    PATH="$bin:$PATH" AWG_PORT=39743 AWG_Jc="${3-0}" timeout 60 bash -c '
        set -o pipefail
        log()       { echo "INFO: $*"; }
        log_warn()  { echo "WARN: $*"; }
        log_error() { echo "ERR: $*"; }
        log_debug() { :; }
        eval "$1"
        check_service_status
        echo "rc=$?"
    ' _ "$body"
}

s7_zero() {
    local want="Jc = 0: junk-пакеты выключены" mode
    en "$1" && want="Jc = 0: junk packets off"
    for mode in zero sonly; do
        run step7 "$1" "$mode" 0
        [[ "$output" == *"rc=0"* ]] || { echo "$1 $mode: $output"; return 1; }
        [[ "$output" != *"WARN:"* ]] || { echo "$1 $mode: a Jc = 0 interface reported as a problem: $output"; return 1; }
        [[ "$output" == *"INFO: "*"$want"* ]] || { echo "$1 $mode: Jc = 0 not named: $output"; return 1; }
    done
}
@test "installer step 7: an interface with Jc = 0, set as 0, is reported active with junk off, both twins" {
    twins s7_zero "$INST" "$INST_EN"
}

s7_mismatch() {
    # The installer set Jc=4, the interface runs with 0: that is a warning,
    # not a green "junk packets off".
    local want="а задан Jc=4"
    en "$1" && want="but Jc=4 is set"
    run step7 "$1" zero 4
    [[ "$output" == *"WARN: "*"$want"* ]] || { echo "$1: a zero nobody set was not flagged: $output"; return 1; }
    [ "$(grep -c '^INFO: .*Jc = 0: junk' <<< "$output")" -eq 0 ] || { echo "$1: the unexpected zero was also called fine: $output"; return 1; }
}
@test "installer step 7: Jc = 0 on the interface while another Jc was set is a warning, both twins" {
    twins s7_mismatch "$INST" "$INST_EN"
}

s7_mirrors() {
    local active="AWG 2.0 параметры активны." missing="AWG 2.0 параметры не обнаружены" mode
    en "$1" && active="AWG 2.0 parameters active." && missing="AWG 2.0 parameters not detected"
    run step7 "$1" jc 4
    [[ "$output" == *"rc=0"* && "$output" != *"WARN:"* ]] || { echo "$1 jc: $output"; return 1; }
    [[ "$output" == *"INFO: $active"* && "$output" != *"Jc = 0"* ]] || { echo "$1: Jc = 4 not plain active: $output"; return 1; }
    # No S/H line: still the old warning, the check did not become blind.
    # Jmin/Jmax alone do not count.
    for mode in bare jonly; do
        run step7 "$1" "$mode" 0
        [[ "$output" == *"WARN: $missing"* ]] || { echo "$1 $mode: an interface without S/H lines passed: $output"; return 1; }
    done
}
@test "installer step 7: Jc > 0 stays plain, and output without S/H lines still warns, both twins" {
    twins s7_mirrors "$INST" "$INST_EN"
}

# ---------------------------------------------------------------- manage check

# mcheck <manage> <mode> [conf Jc|-] : check_server with stubs (harness of
# test_manage_check_show_secrets.bats); awg0.conf gets "Jc = <conf Jc>"
# (default 0, "-" for no Jc line).
mcheck() {
    local src="$1" mode="$2" cjc="${3-0}" common bin dir
    common="${src/manage_amneziawg/awg_common}"
    bin="$BATS_TEST_TMPDIR/binm-$mode"
    awg_stub "$bin" "$mode"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/systemctl"
    printf '#!/usr/bin/env bash\necho "5: awg0: <POINTOPOINT,UP> mtu 1280"\necho "    inet 10.9.9.1/24 scope global awg0"\n' > "$bin/ip"
    printf '#!/usr/bin/env bash\necho "UNCONN 0 0 0.0.0.0:39743 0.0.0.0:*"\n' > "$bin/ss"
    printf '#!/usr/bin/env bash\necho 1\n' > "$bin/sysctl"
    printf '#!/usr/bin/env bash\necho "amneziawg 155648 0"\n' > "$bin/lsmod"
    printf '#!/usr/bin/env bash\necho "Status: active"\necho "39743/udp ALLOW Anywhere"\n' > "$bin/ufw"
    chmod +x "$bin"/*
    dir="$BATS_TEST_TMPDIR/awgm"
    mkdir -p "$dir"
    printf '[Interface]\nListenPort = 39743\n' > "$dir/awg0.conf"
    [[ "$cjc" == "-" ]] || printf 'Jc = %s\n' "$cjc" >> "$dir/awg0.conf"
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

mc_zero() {
    local want="Jc = 0: junk-пакеты выключены" mode cjc
    en "$1" && want="Jc = 0: junk packets off"
    # A conf with Jc = 0, a zero-padded 00, or no Jc line at all (nothing to
    # contradict the interface) all agree with an interface at zero.
    for mode in zero sonly; do
        for cjc in 0 00 -; do
            run mcheck "$1" "$mode" "$cjc"
            [[ "$output" != *NO_FUNCTION* && "$output" == *"rc=0"* ]] || { echo "$1 $mode conf=$cjc: check failed: $output"; return 1; }
            [[ "$output" != *"WARN:"* ]] || { echo "$1 $mode conf=$cjc: Jc = 0 reported as a problem: $output"; return 1; }
            [[ "$output" == *"INFO: "*"$want"* ]] || { echo "$1 $mode conf=$cjc: Jc = 0 not named: $output"; return 1; }
        done
    done
}
@test "manage check: an interface with Jc = 0 that awg0.conf agrees with is reported active with junk off, both twins" {
    twins mc_zero "$MANAGE" "$MANAGE_EN"
}

mc_mismatch() {
    local want="а в awg0.conf Jc=4"
    en "$1" && want="but awg0.conf has Jc=4"
    run mcheck "$1" zero 4
    [[ "$output" == *"WARN: "*"$want"*"restart awg-quick@awg0"* ]] || { echo "$1: an unapplied Jc was not flagged: $output"; return 1; }
    [ "$(grep -c '^INFO: .*Jc = 0: junk' <<< "$output")" -eq 0 ] || { echo "$1: the unexpected zero was also called fine: $output"; return 1; }
}
@test "manage check: Jc = 0 on the interface while awg0.conf has another Jc is a warning with the fix, both twins" {
    twins mc_mismatch "$MANAGE" "$MANAGE_EN"
}

mc_mirrors() {
    local active=" - Параметры обфускации: активны" nowant="Параметры обфускации не обнаружены" mode
    en "$1" && active=" - Obfuscation parameters: active" && nowant="Obfuscation parameters not detected"
    run mcheck "$1" jc 4
    [[ "$output" == *"INFO: $active"* && "$output" != *"$nowant"* && "$output" != *"Jc = 0"* ]] || { echo "$1 jc: $output"; return 1; }
    for mode in bare jonly; do
        run mcheck "$1" "$mode" 0
        [[ "$output" == *"WARN: "*"$nowant"* ]] || { echo "$1 $mode: output without S/H lines passed: $output"; return 1; }
    done
}
@test "manage check: Jc > 0 stays plain, and output without S/H lines still warns, both twins" {
    twins mc_mirrors "$MANAGE" "$MANAGE_EN"
}

# ---------------------------------------------------------------- diagnose step 8

# step8 <manage> <mode> <cps_unsafe> : the step 8 block of diagnose, lifted by
# its comment borders (as in test_cps_size_guard.bats), with a stub awg.
# The block holds `local` declarations, so it runs inside a function, and any
# bash error from the harness itself fails the case (HARNESS_ERR).
# step8 <manage> <mode> <cps_unsafe> [conf Jc|-] : awg0.conf gets
# "Jc = <conf Jc>" (default 0, "-" for no line).
step8() {
    local cjc="${4-0}"
    printf '[Interface]\nListenPort = 39743\n' > "$BATS_TEST_TMPDIR/d8.conf"
    [[ "$cjc" == "-" ]] || printf 'Jc = %s\n' "$cjc" >> "$BATS_TEST_TMPDIR/d8.conf"
    SERVER_CONF_FILE="$BATS_TEST_TMPDIR/d8.conf" bash -c '
        MANAGE="$1"; MODE="$2"; _cps_unsafe="$3"
        warn=0; fail=0
        _diag_line() { echo "[$1] ${*:2}"; }
        _mask_report_secrets() { cat; }
        eval "$(awk "/^_awg_dec_strip\\(\\) \\{/,/^\\}/" "${MANAGE/manage_amneziawg/awg_common}")"
        eval "$(awk "/^_conf_jc\\(\\) \\{/,/^\\}/" "$MANAGE")"
        declare -F _awg_dec_strip _conf_jc >/dev/null || { echo "NO_FUNCTION"; exit 3; }
        case "$MODE" in
            zero)  awg() { printf "interface: awg0\n  jmin: 55\n  jmax: 380\n  s1: 72\n"; } ;;
            sonly) awg() { printf "interface: awg0\n  s1: 72\n"; } ;;
            jc)    awg() { printf "interface: awg0\n  jc: 4\n  jmin: 55\n  jmax: 380\n  s1: 72\n"; } ;;
            bare)  awg() { printf "interface: awg0\n  listening port: 39743\n"; } ;;
            fail)  awg() { echo "Unable to access interface: No such device" >&2; return 1; } ;;
            hang)  awg() { return 124; } ;;
        esac
        timeout() { shift; "$@"; }
        block=$(awk "/# 8\. AWG params snapshot/,/# 9\. Carrier comparison/" "$MANAGE" | sed "\$d")
        [[ -n "$block" ]] || { echo "NO_BLOCK"; exit 3; }
        step() { eval "$block"; echo "JC=[$jc] warn=$warn fail=$fail"; }
        step 2> >(sed "s/^/HARNESS_ERR: /")
        wait
    ' _ "$1" "$2" "$3"
}

# ok8 : the harness itself ran clean.
ok8() {
    [[ "$output" != *HARNESS_ERR* && "$output" != *NO_BLOCK* && "$output" != *NO_FUNCTION* && "$output" == *"JC=["* ]] \
        || { echo "harness broken ($1): $output"; return 1; }
}

d_zero() {
    local note="(junk-пакеты выключены)"
    en "$1" && note="(junk packets off)"
    run step8 "$1" zero 0 0
    ok8 "$1" || return 1
    [[ "$output" == *"[INFO] AWG params: Jc=0 $note Jmin=55 Jmax=380 "* ]] || { echo "$1: Jc = 0 not reported as off: $output"; return 1; }
    # The carrier comparison after step 8 reads $jc: it must get the number.
    [[ "$output" == *"JC=[0] warn=0 fail=0"* ]] || { echo "$1: jc not 0, or a warning on an agreed zero: $output"; return 1; }
    # All-zero junk set: missing jmin/jmax are zero too once the dump is proven.
    run step8 "$1" sonly 0 -
    ok8 "$1" || return 1
    [[ "$output" == *"AWG params: Jc=0 $note Jmin=0 Jmax=0 "* && "$output" == *"warn=0 fail=0"* ]] \
        || { echo "$1: the all-zero set is not read as zeros: $output"; return 1; }
}
@test "diagnose: a read AWG dump without a jc line is Jc=0, junk off, with zero Jmin/Jmax when absent, both twins" {
    twins d_zero "$MANAGE" "$MANAGE_EN"
}

d_mismatch() {
    local want="а в awg0.conf Jc=4"
    en "$1" && want="but awg0.conf has Jc=4"
    run step8 "$1" zero 0 4
    ok8 "$1" || return 1
    [[ "$output" == *"[WARN] "*"$want"* && "$output" == *"Fix: sudo systemctl restart awg-quick@awg0"* ]] \
        || { echo "$1: an unapplied Jc was not flagged: $output"; return 1; }
    [[ "$output" == *"JC=[0] warn=1 fail=0"* ]] || { echo "$1: the mismatch was not counted: $output"; return 1; }
}
@test "diagnose: Jc = 0 on the interface while awg0.conf has another Jc is a counted warning with the fix, both twins" {
    twins d_mismatch "$MANAGE" "$MANAGE_EN"
}

d_unknown() {
    # A dump without jc, S or H lines proves nothing: unknown, not zero.
    local want="нет параметров обфускации"
    en "$1" && want="prints no obfuscation parameters"
    run step8 "$1" bare 0 0
    ok8 "$1" || return 1
    [[ "$output" == *"AWG params: Jc=? Jmin=? Jmax=? "* && "$output" != *"Jc=0"* ]] || { echo "$1: an empty dump became numbers: $output"; return 1; }
    [[ "$output" == *"[WARN] "*"$want"* && "$output" == *"JC=[] warn=1"* ]] || { echo "$1: an empty dump was not flagged: $output"; return 1; }
}
@test "diagnose: a read dump without jc, S or H lines stays unknown and is flagged, both twins" {
    twins d_unknown "$MANAGE" "$MANAGE_EN"
}

d_mirrors() {
    local unread="не прочитан"
    en "$1" && unread="not read"
    run step8 "$1" jc 0 4
    ok8 "$1" || return 1
    [[ "$output" == *"AWG params: Jc=4 Jmin=55 Jmax=380 "* && "$output" != *"(junk"* && "$output" == *"warn=0 fail=0"* ]] || { echo "$1 jc: $output"; return 1; }
    # Not read is not zero, whichever way the read was lost.
    local mode
    for mode in skipped fail hang; do
        if [[ "$mode" == skipped ]]; then run step8 "$1" zero 1 0; else run step8 "$1" "$mode" 0 0; fi
        ok8 "$1" || return 1
        [[ "$output" != *"Jc=0"* && "$output" == *"JC=[]"* ]] || { echo "$1 $mode: an unread interface became Jc=0: $output"; return 1; }
        [[ "$output" == *"$unread"* ]] || { echo "$1 $mode: the unread interface was not named: $output"; return 1; }
    done
}
@test "diagnose: Jc > 0 is printed as is, and an interface not read (skipped, failed, timed out) is not turned into Jc=0, both twins" {
    twins d_mirrors "$MANAGE" "$MANAGE_EN"
}
