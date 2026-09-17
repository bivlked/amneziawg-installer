#!/usr/bin/env bats
# The third-line profile inside the vpn:// link.
#
# The link is what people actually import into the Amnezia client, so it has to
# carry the same profile as the .conf file: a link without HeaderProtectionKey
# produces a client that cannot connect to a 3.1 server, and the person has no
# way to see why - the link looks fine.
#
# Values come from the CLIENT config, the same file the link describes (the
# owner's decision, consistent with how the preshared key is taken). The key
# goes to perl through the environment, next to the other secrets: the command
# line of a process is readable by every user through /proc while perl runs.
#
# On an installation marked 2.0 the link keeps exactly the fields it has today.

KEY_OK="QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQA="
CPA_OK="32-128"

require_perl_zlib() { perl -MCompress::Zlib -MMIME::Base64 -e '1' 2>/dev/null || skip "perl Compress::Zlib/MIME::Base64 not available"; }
require_python3()   { command -v python3 &>/dev/null || skip "python3 not available"; }

# lib_run <lib> <generation> <snippet> : an install of that generation in $AWG_DIR.
lib_run() {
    local lib="$1" gen="$2" snippet="$3" d cpa=""
    d="$BATS_TEST_TMPDIR/u-$(basename "$lib" .sh)"
    [[ "$gen" == "3.1" ]] && cpa="$CPA_OK"
    rm -rf "$d"; mkdir -p "$d/keys"
    {
        printf "export AWG_PORT=39743\nexport AWG_TUNNEL_SUBNET='10.9.9.1/24'\nexport DISABLE_IPV6=1\n"
        printf "export ALLOWED_IPS_MODE=1\nexport AWG_PROTOCOL='%s'\nexport AWG_CPA='%s'\n" "$gen" "$cpa"
        printf "export AWG_Jc=6\nexport AWG_Jmin=55\nexport AWG_Jmax=380\n"
        printf "export AWG_S1=72\nexport AWG_S2=56\nexport AWG_S3=32\nexport AWG_S4=16\n"
        printf "export AWG_H1='1'\nexport AWG_H2='2'\nexport AWG_H3='3'\nexport AWG_H4='4'\n"
        printf "export AWG_I1='<r 128>'\nexport AWG_APPLY_MODE='syncconf'\n"
    } > "$d/awgsetup_cfg.init"
    printf 'SRVPRIVKEYPLACEHOLDER\n' > "$d/server_private.key"
    printf 'SRVPUBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n' > "$d/server_public.key"
    [[ "$gen" == "3.1" ]] && printf '%s\n' "$KEY_OK" > "$d/server_hpk.key"
    AWG_DIR="$d" timeout 60 bash -c '
        export CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init" SERVER_CONF_FILE="$AWG_DIR/awg0.conf"
        export KEYS_DIR="$AWG_DIR/keys" EXPIRY_DIR="$AWG_DIR/expiry"
        log() { :; }; log_warn() { echo "WARN: $*"; }; log_error() { echo "ERR: $*"; }; log_debug() { :; }
        source "$1" >/dev/null 2>&1 || true
        get_main_nic() { echo eth0; }
        render_server_config || { echo "RC=90"; exit 0; }
        render_client_config c1 10.9.9.2 CLIENTPRIVKEYPLACEHOLDER SRVPUBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= 203.0.113.10 39743 \
            || { echo "RC=91"; exit 0; }
        eval "$2"
    ' _ "$BATS_TEST_DIRNAME/../$lib" "$snippet"
}

dir_of() { echo "$BATS_TEST_TMPDIR/u-$(basename "$1" .sh)"; }

# inner_json <uri file> : the inner config JSON carried by the link.
inner_json() {
    python3 - "$1" <<'PY'
import base64, json, struct, sys, zlib
uri = open(sys.argv[1], encoding="utf-8").read().strip().replace("vpn://", "")
raw = base64.urlsafe_b64decode(uri + "=" * (-len(uri) % 4))
struct.unpack(">I", raw[:4])[0]
outer = json.loads(zlib.decompress(raw[4:]))
print(outer["containers"][0]["awg"]["last_config"])
PY
}

both() {
    local seen=0 lib
    for lib in awg_common.sh awg_common_en.sh; do
        "$1" "$lib" || return 1
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}

u_31_fields() {
    local lib="$1" d out inner
    d=$(dir_of "$lib")
    out=$(lib_run "$lib" 3.1 'generate_vpn_uri c1; echo "RC=$?"')
    [[ "$out" == *"RC=0"* ]] || { echo "uri not created ($lib): $out"; return 1; }
    inner=$(inner_json "$d/c1.vpnuri") || { echo "cannot decode the link ($lib)"; return 1; }
    [[ "$inner" == *"\"HeaderProtectionKey\":\"$KEY_OK\""* ]] || { echo "no key field ($lib): $inner"; return 1; }
    [[ "$inner" == *"\"ContentPaddingAddition\":\"$CPA_OK\""* ]] || { echo "no padding field ($lib): $inner"; return 1; }
}
@test "vpn uri 3.1: the link carries the key and the padding, both twins" {
    require_perl_zlib; require_python3
    both u_31_fields
}

u_20_unchanged() {
    local lib="$1" d out inner
    d=$(dir_of "$lib")
    out=$(lib_run "$lib" 2.0 'generate_vpn_uri c1; echo "RC=$?"')
    [[ "$out" == *"RC=0"* ]] || { echo "uri not created ($lib): $out"; return 1; }
    inner=$(inner_json "$d/c1.vpnuri") || { echo "cannot decode the link ($lib)"; return 1; }
    [[ "$inner" != *"HeaderProtectionKey"* ]] || { echo "key field on a 2.0 link ($lib)"; return 1; }
    [[ "$inner" != *"ContentPaddingAddition"* ]] || { echo "padding field on a 2.0 link ($lib)"; return 1; }
}
@test "vpn uri 2.0: the link keeps the fields it has today, both twins" {
    require_perl_zlib; require_python3
    both u_20_unchanged
}

u_31_missing_key_in_conf() {
    local lib="$1" d out
    d=$(dir_of "$lib")
    # A 3.1 client config with the key line removed by hand: the link would look
    # valid and would never connect, so it must not be written at all.
    out=$(lib_run "$lib" 3.1 '
        sed -i "/^HeaderProtectionKey = /d" "$AWG_DIR/c1.conf"
        generate_vpn_uri c1; echo "RC=$?"')
    [[ "$out" == *"RC=0"* ]] && { echo "a link was made from a 3.1 config without the key ($lib)"; return 1; }
    [ ! -f "$d/c1.vpnuri" ] || { echo "a link file was written anyway ($lib)"; return 1; }
    [[ "$out" == *"ERR:"* || "$out" == *"WARN:"* ]] || { echo "no reason printed ($lib): $out"; return 1; }
}
@test "vpn uri 3.1: a client config without the key produces no link, both twins" {
    require_perl_zlib; require_python3
    both u_31_missing_key_in_conf
}

u_key_not_in_argv() {
    local lib="$1" body
    body=$(sed -n '/^generate_vpn_uri() {/,/^}/p' "$BATS_TEST_DIRNAME/../$lib")
    # The key travels in the environment, like the other secrets: a positional
    # argument would be visible in /proc/<pid>/cmdline while perl runs.
    grep -q 'AWG_URI_HPK=' <<< "$body" || { echo "$lib: the key is not passed through the environment"; return 1; }
    # The argument list runs from the closing quote of the perl script to the
    # stderr redirect. Looking for the shell variable name, not the perl one:
    # inside perl the value is $hpk, in the shell it is $client_hpk, and a pin
    # written against the perl name would miss the mistake it is meant to catch.
    local args
    # The start anchor is the WHOLE line that closes the perl script, not a
    # substring: `' "$conf_file"` also occurs inside the grep that reads the
    # private key, and starting there would swallow the environment prefix and
    # report the key as an argument.
    args=$(awk '$0 == "    \x27 \"$conf_file\" \\" { f = 1 } f { print } index($0, "2>\"$perl_err\"") { exit }' <<< "$body")
    [ -n "$args" ] || { echo "$lib: could not find the perl argument list"; return 1; }
    grep -q 'client_hpk' <<< "$args" && { echo "$lib: the key is also passed as an argument"; return 1; }
    return 0
}
@test "vpn uri 3.1: the key reaches perl through the environment, not through argv, both twins" {
    both u_key_not_in_argv
}

u_no_trace() {
    local lib="$1" out trace
    trace="$BATS_TEST_TMPDIR/utrace-$(basename "$lib" .sh)"
    rm -f "$trace"
    out=$(lib_run "$lib" 3.1 '
        exec 7>"'"$trace"'"
        BASH_XTRACEFD=7
        set -x
        generate_vpn_uri c1
        rc=$?
        set +x
        echo "RC=$rc"')
    [[ "$out" == *"RC=0"* ]] || { echo "uri not created under tracing ($lib): $out"; return 1; }
    [ -s "$trace" ] || { echo "no trace was written ($lib)"; return 1; }
    grep -qF "$KEY_OK" "$trace" && { echo "the key is in the trace ($lib)"; return 1; }
    return 0
}
@test "vpn uri 3.1: the key does not reach the xtrace output, both twins" {
    require_perl_zlib; require_python3
    both u_no_trace
}

# inner_fields <uri file> : the top-level keys of the inner config JSON, parsed
# as JSON. A substring search would pass a link whose JSON is broken, which the
# client silently refuses to import.
inner_fields() {
    python3 - "$1" <<'PY'
import base64, json, struct, sys, zlib
uri = open(sys.argv[1], encoding="utf-8").read().strip().replace("vpn://", "")
raw = base64.urlsafe_b64decode(uri + "=" * (-len(uri) % 4))
outer = json.loads(zlib.decompress(raw[4:]))
inner = json.loads(outer["containers"][0]["awg"]["last_config"])
for k in sorted(inner):
    v = inner[k]
    print("%s=%s" % (k, v if isinstance(v, str) else json.dumps(v)))
PY
}

u_31_fields_parsed() {
    local lib="$1" d out fields
    d=$(dir_of "$lib")
    out=$(lib_run "$lib" 3.1 'generate_vpn_uri c1; echo "RC=$?"')
    [[ "$out" == *"RC=0"* ]] || { echo "uri not created ($lib): $out"; return 1; }
    fields=$(inner_fields "$d/c1.vpnuri") || { echo "the inner config is not valid JSON ($lib)"; return 1; }
    grep -qxF "HeaderProtectionKey=$KEY_OK" <<< "$fields" || { echo "key field wrong ($lib): $fields"; return 1; }
    grep -qxF "ContentPaddingAddition=$CPA_OK" <<< "$fields" || { echo "padding field wrong ($lib): $fields"; return 1; }
}
@test "vpn uri 3.1: the inner config parses as JSON and carries the exact values, both twins" {
    require_perl_zlib; require_python3
    both u_31_fields_parsed
}

u_20_hand_added_fields() {
    local lib="$1" d out fields
    d=$(dir_of "$lib")
    # A 2.0 client config with third-line lines added by hand. The renderers write
    # these lines only on 3.1, and the link follows the same rule: on 2.0 its
    # fields stay exactly as they were.
    out=$(lib_run "$lib" 2.0 '
        sed -i "0,/^\[Peer\]/s//HeaderProtectionKey = '"$KEY_OK"'\nContentPaddingAddition = 32-128\n\n[Peer]/" "$AWG_DIR/c1.conf"
        grep -q "^HeaderProtectionKey = " "$AWG_DIR/c1.conf" || { echo "SETUP_FAILED"; exit 0; }
        generate_vpn_uri c1; echo "RC=$?"')
    [[ "$out" != *SETUP_FAILED* ]] || { echo "could not prepare the config ($lib)"; return 1; }
    [[ "$out" == *"RC=0"* ]] || { echo "uri not created ($lib): $out"; return 1; }
    fields=$(inner_fields "$d/c1.vpnuri") || { echo "the inner config is not valid JSON ($lib)"; return 1; }
    grep -q '^HeaderProtectionKey=' <<< "$fields" && { echo "key field on a 2.0 link ($lib)"; return 1; }
    grep -q '^ContentPaddingAddition=' <<< "$fields" && { echo "padding field on a 2.0 link ($lib)"; return 1; }
    return 0
}
@test "vpn uri 2.0: third-line lines added by hand do not become link fields, both twins" {
    require_perl_zlib; require_python3
    both u_20_hand_added_fields
}

u_31_missing_cpa_in_conf() {
    local lib="$1" d out want
    d=$(dir_of "$lib")
    out=$(lib_run "$lib" 3.1 '
        sed -i "/^ContentPaddingAddition = /d" "$AWG_DIR/c1.conf"
        generate_vpn_uri c1; echo "RC=$?"')
    [[ "$out" == *"RC=0"* ]] && { echo "a link was made from a 3.1 config without the padding ($lib)"; return 1; }
    [ ! -f "$d/c1.vpnuri" ] || { echo "a link file was written anyway ($lib)"; return 1; }
    want="ContentPaddingAddition"
    [[ "$out" == *"$want"* ]] || { echo "the reason does not name the padding ($lib): $out"; return 1; }
}
@test "vpn uri 3.1: a client config without the padding produces no link, both twins" {
    require_perl_zlib; require_python3
    both u_31_missing_cpa_in_conf
}

u_broken_marker_link() {
    local lib="$1" d out fields
    d=$(dir_of "$lib")
    # An unreadable marker and no key file: add and regen go on over such an init,
    # so the link has to be made as on 2.0, not refused as a 3.1 profile without
    # a key. Third-line lines added to the client config by hand stay out of the
    # link fields here too.
    out=$(lib_run "$lib" yes '
        sed -i "0,/^\[Peer\]/s//HeaderProtectionKey = '"$KEY_OK"'\nContentPaddingAddition = 32-128\n\n[Peer]/" "$AWG_DIR/c1.conf"
        grep -q "^HeaderProtectionKey = " "$AWG_DIR/c1.conf" || { echo "SETUP_FAILED"; exit 0; }
        generate_vpn_uri c1; echo "RC=$?"')
    [[ "$out" != *SETUP_FAILED* && "$out" != *"RC=9"* ]] || { echo "could not prepare the install ($lib): $out"; return 1; }
    [[ "$out" == *"RC=0"* ]] || { echo "no link over an unreadable marker without a key ($lib): $out"; return 1; }
    fields=$(inner_fields "$d/c1.vpnuri") || { echo "the inner config is not valid JSON ($lib)"; return 1; }
    grep -q '^HeaderProtectionKey=' <<< "$fields" && { echo "key field on a link over an unreadable marker ($lib)"; return 1; }
    grep -q '^ContentPaddingAddition=' <<< "$fields" && { echo "padding field on a link over an unreadable marker ($lib)"; return 1; }
    return 0
}
@test "vpn uri: an unreadable marker without a key makes the link as on 2.0, both twins" {
    require_perl_zlib; require_python3
    both u_broken_marker_link
}

# ------------------------------------------------ the vpn:// budget on 3.1

# The link travels as one QR code in byte mode at level L, version 40: 2953
# bytes. A 3.1 client carries more than a 2.0 one (the header protection key and
# the padding range, each twice: as a field and inside the embedded config), so
# the worst case the generator can produce is measured here on the real
# generator, and the ceiling itself is pinned with the real qrencode.

u_31_worst_case() {
    local lib="$1" d out len aips i1
    d=$(dir_of "$lib")
    # Longest routes the installer writes itself: the mode-2 list.
    aips=$(grep -oP 'ALLOWED_IPS="\K1\.0\.0\.0/8[^"]*' "$BATS_TEST_DIRNAME/../install_amneziawg.sh" | head -1)
    [ -n "$aips" ] || { echo "mode-2 list not found in the installer"; return 1; }
    # Longest I1 the generator can emit: every random range at its top.
    i1=$(bash -c '
        eval "$(sed -n "/^generate_cps_i1()/,/^}/p" "$1")"
        rand_range() { echo "$2"; }
        generate_cps_i1
    ' _ "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    [ -n "$i1" ] || { echo "I1 generator produced nothing"; return 1; }
    # Values reach the snippet through the environment: they carry angle
    # brackets, spaces and commas, and nesting them into quoted code breaks.
    # They go into the init, because generate_vpn_uri reloads it.
    # Keys are random: placeholder keys compress well and understated the size
    # by about 250 bytes. The endpoint is a 253-character name, the DNS maximum,
    # and the server name takes the 128 bytes the installer allows.
    local k_srv k_cli k_hpk k_psk fqdn name
    k_srv=$(head -c 32 /dev/urandom | base64); k_cli=$(head -c 32 /dev/urandom | base64)
    k_hpk=$(head -c 32 /dev/urandom | base64); k_psk=$(head -c 32 /dev/urandom | base64)
    _rand_label() { head -c 400 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c "$1"; }
    fqdn="$(_rand_label 63).$(_rand_label 63).$(_rand_label 63).$(_rand_label 61)"
    name=$(head -c 400 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 128)
    [ "${#fqdn}" -eq 253 ] && [ "${#name}" -eq 128 ] || { echo "random inputs came out short"; return 1; }
    out=$(WC_AIPS="$aips" WC_I1="$i1" WC_SRV="$k_srv" WC_CLI="$k_cli" WC_HPK="$k_hpk" WC_PSK="$k_psk" \
          WC_FQDN="$fqdn" WC_NAME="$name" lib_run "$lib" 3.1 '
        sed -i "/^export AWG_I1=/d; /^export AWG_CPA=/d; /^export ALLOWED_IPS/d; /^export DISABLE_IPV6=/d; /^export AWG_J/d; /^export AWG_S[1-4]=/d" "$CONFIG_FILE"
        {
            printf "export ALLOWED_IPS_MODE=2\nexport ALLOWED_IPS=\"%s\"\n" "$WC_AIPS"
            printf "export DISABLE_IPV6=0\nexport ALLOW_IPV6_TUNNEL=1\nexport IPV6_SUBNET=fddd:2c4:2c4:2c4::/64\n"
            printf "export AWG_I1=\"%s\"\nexport AWG_CPA=10000-65535\n" "$WC_I1"
            printf "export AWG_Jc=128\nexport AWG_Jmin=1280\nexport AWG_Jmax=1280\n"
            printf "export AWG_S1=150\nexport AWG_S2=149\nexport AWG_S3=64\nexport AWG_S4=32\n"
            printf "export AWG_SERVER_NAME=\"%s\"\n" "$WC_NAME"
        } >> "$CONFIG_FILE"
        printf "%s\n" "$WC_SRV" > "$AWG_DIR/server_public.key"
        printf "%s\n" "$WC_HPK" > "$AWG_DIR/server_hpk.key"
        # The live server config is the source of the obfuscation values, so it
        # is rendered again from the rewritten init.
        rm -f "$SERVER_CONF_FILE"
        safe_load_config "$CONFIG_FILE" >/dev/null 2>&1 || { echo "RC=93"; exit 0; }
        render_server_config || { echo "RC=94"; exit 0; }
        export CLIENT_PSK="$WC_PSK"
        render_client_config c1 10.9.9.254 "$WC_CLI" "$WC_SRV" "$WC_FQDN" 65535 fddd:2c4:2c4:2c4::fffe \
            || { echo "RC=92"; exit 0; }
        generate_vpn_uri c1; echo "RC=$?"')
    [[ "$out" == *"RC=0"* ]] || { echo "worst-case uri not created ($lib): $out"; return 1; }
    grep -q 'HeaderProtectionKey' "$d/c1.conf" || { echo "the worst case is not a 3.1 config ($lib)"; return 1; }
    grep -q 'PresharedKey' "$d/c1.conf" || { echo "the worst case lost its PSK ($lib)"; return 1; }
    grep -q 'fddd:2c4:2c4:2c4::fffe' "$d/c1.conf" || { echo "the worst case lost its IPv6 address ($lib)"; return 1; }
    grep -qF "$i1" "$d/c1.conf" || { echo "the worst case lost its I1 ($lib)"; return 1; }
    grep -q '32.0.0.0/3' "$d/c1.conf" || { echo "the worst case lost the mode-2 routes ($lib)"; return 1; }
    grep -qF "$k_hpk" "$d/c1.conf" || { echo "the worst case lost its random key ($lib)"; return 1; }
    grep -qF "$fqdn" "$d/c1.conf" || { echo "the worst case lost its endpoint ($lib)"; return 1; }
    grep -q '^Jc = 128' "$d/c1.conf" || { echo "the worst case lost its junk sizes ($lib)"; return 1; }
    len=$(wc -c < "$d/c1.vpnuri")
    echo "worst-case 3.1 vpn:// is $len bytes, cap 2953, headroom $((2953 - len)) ($lib)"
    [ "$len" -le 2953 ] || { echo "worst-case 3.1 link exceeds one QR code ($lib): $len"; return 1; }
}
@test "vpn uri 3.1: the worst case the generator can produce fits one QR code, both twins" {
    require_perl_zlib
    both u_31_worst_case
}

@test "qrencode: the flags the installer uses take 2953 bytes and refuse 2954" {
    # Pins the ceiling the budget above is measured against. With other flags the
    # capacity is different, and the budget test would compare against a number
    # that is no longer true.
    local d="$BATS_TEST_TMPDIR/qr" lib
    # The libraries really use these flags; this part needs no qrencode.
    for lib in awg_common.sh awg_common_en.sh; do
        grep -qF 'qrencode -8 -t png -l L -s 6 -m 4 -o "$tmp_png" < "$uri_file"' "$BATS_TEST_DIRNAME/../$lib"
    done
    if ! command -v qrencode &>/dev/null; then
        # CI installs qrencode, so a missing binary there is a broken runner,
        # not a reason to pass without measuring.
        [[ -z "${CI:-}" ]] || { echo "qrencode is missing in CI"; return 1; }
        skip "qrencode not available"
    fi
    mkdir -p "$d"
    echo "# $(qrencode --version 2>&1 | head -1)" >&3
    head -c 2953 /dev/zero | tr '\0' 'A' > "$d/ok.txt"
    head -c 2954 /dev/zero | tr '\0' 'A' > "$d/over.txt"
    run qrencode -8 -t png -l L -s 6 -m 4 -o "$d/ok.png" < "$d/ok.txt"
    [ "$status" -eq 0 ]
    run qrencode -8 -t png -l L -s 6 -m 4 -o "$d/over.png" < "$d/over.txt"
    [ "$status" -ne 0 ]
}

u_qr_refusal_advice() {
    local lib="$1" d bin out
    d=$(dir_of "$lib")
    bin="$BATS_TEST_TMPDIR/qrfail"
    mkdir -p "$bin"
    printf '#!/usr/bin/env bash\necho "Failed to encode the input data: Input data too large" >&2\nexit 1\n' > "$bin/qrencode"
    chmod +x "$bin/qrencode"
    out=$(PATH="$bin:$PATH" lib_run "$lib" 3.1 'printf "vpn://x\n" > "$AWG_DIR/c1.vpnuri"; generate_qr_vpnuri c1; echo "RC=$?"')
    [[ "$out" == *"RC=1"* ]] || { echo "a refused QR did not fail ($lib): $out"; return 1; }
    [[ "$out" == *"c1.vpnuri"* ]] || { echo "no advice to import the .vpnuri file ($lib): $out"; return 1; }
    [ ! -e "$d/c1.vpnuri.png" ] || { echo "a partial PNG was left ($lib)"; return 1; }
}
@test "qr vpn uri: a refused QR fails and points at the .vpnuri file, both twins" {
    both u_qr_refusal_advice
}

u_render_no_trailers() {
    local lib="$1" d out
    d=$(dir_of "$lib")
    out=$(lib_run "$lib" 3.1 'echo "RC=0"')
    [[ "$out" == *"RC=0"* ]] || { echo "3.1 render failed ($lib): $out"; return 1; }
    grep -q 'HeaderProtectionKey' "$d/awg0.conf" && grep -q 'HeaderProtectionKey' "$d/c1.conf" \
        || { echo "not a 3.1 render, the check below would mean nothing ($lib)"; return 1; }
    if grep -nE '^[[:space:]]*(RandomTrailers|DisableCookies)[[:space:]]*=' "$d/awg0.conf" "$d/c1.conf"; then
        echo "a rendered 3.1 config carries RandomTrailers or DisableCookies ($lib)"
        return 1
    fi
}
@test "render 3.1: neither the server nor the client config carries RandomTrailers or DisableCookies, both twins" {
    # Either line, even with the value off, cuts off every 3.0 client.
    both u_render_no_trailers
}
