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
