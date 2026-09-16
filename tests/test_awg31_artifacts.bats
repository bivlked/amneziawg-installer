#!/usr/bin/env bats
# The client's set of files, checked as a set.
#
# A client is handed four files: the .conf, its QR code, the vpn:// link and the
# link's QR code. They are produced by different steps, and a failure in one of
# them used to be a warning: the person then gets a folder that looks complete
# and a client that does not work, and nobody can tell which file is the bad one.
#
# On a 3.1 installation the set is also checked for the profile itself: the
# config has to carry exactly one HeaderProtectionKey in [Interface], equal to
# the key file, and the installation's padding (AWG_CPA). A profile with the wrong key is
# indistinguishable from a working one until the tunnel refuses to come up.

KEY_OK="QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQA="
KEY_OTHER="WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWA="
CPA_OK="32-128"

# lib_run <lib> <generation> <snippet> : a client set prepared in $AWG_DIR.
lib_run() {
    local lib="$1" gen="$2" snippet="$3" d cpa=""
    d="$BATS_TEST_TMPDIR/a-$(basename "$lib" .sh)"
    [[ "$gen" == "3.1" ]] && cpa="$CPA_OK"
    rm -rf "$d"; mkdir -p "$d/keys"
    {
        printf "export AWG_PORT=39743\nexport AWG_TUNNEL_SUBNET='10.9.9.1/24'\nexport DISABLE_IPV6=1\n"
        printf "export ALLOWED_IPS_MODE=1\nexport AWG_PROTOCOL='%s'\nexport AWG_CPA='%s'\n" "$gen" "$cpa"
        printf "export AWG_Jc=6\nexport AWG_Jmin=55\nexport AWG_Jmax=380\n"
        printf "export AWG_S1=72\nexport AWG_S2=56\nexport AWG_S3=32\nexport AWG_S4=16\n"
        printf "export AWG_H1='1'\nexport AWG_H2='2'\nexport AWG_H3='3'\nexport AWG_H4='4'\n"
        printf "export AWG_APPLY_MODE='syncconf'\n"
    } > "$d/awgsetup_cfg.init"
    [[ "$gen" == "3.1" ]] && printf '%s\n' "$KEY_OK" > "$d/server_hpk.key"
    # A complete, plausible set. The renderers are not used here: this file is
    # about the check, and building the set by hand lets every case break one
    # thing at a time.
    {
        printf '[Interface]\nPrivateKey = CLIENTPRIV\nAddress = 10.9.9.2/32\nDNS = 1.1.1.1\nMTU = 1280\n'
        printf 'Jc = 6\nJmin = 55\nJmax = 380\nS1 = 72\nS2 = 56\nS3 = 32\nS4 = 16\n'
        printf 'H1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\n'
        [[ "$gen" == "3.1" ]] && printf 'HeaderProtectionKey = %s\nContentPaddingAddition = %s\n' "$KEY_OK" "$CPA_OK"
        printf '\n[Peer]\nPublicKey = SRVPUB\nEndpoint = 203.0.113.10:39743\nAllowedIPs = 0.0.0.0/0\nPersistentKeepalive = 33\n'
    } > "$d/c1.conf"
    printf 'PNG\n' > "$d/c1.png"
    printf 'vpn://AAAA\n' > "$d/c1.vpnuri"
    printf 'PNG\n' > "$d/c1.vpnuri.png"
    AWG_DIR="$d" timeout 60 bash -c '
        export CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init" SERVER_CONF_FILE="$AWG_DIR/awg0.conf"
        export KEYS_DIR="$AWG_DIR/keys" EXPIRY_DIR="$AWG_DIR/expiry"
        log() { :; }; log_warn() { echo "WARN: $*"; }; log_error() { echo "ERR: $*"; }; log_debug() { :; }
        source "$1" >/dev/null 2>&1 || true
        # The installer has loaded the parameters by the time it checks a set,
        # and the check compares the padding against them rather than reading
        # the init a second time.
        safe_load_config "$CONFIG_FILE" >/dev/null 2>&1 || true
        eval "$2"
    ' _ "$BATS_TEST_DIRNAME/../$lib" "$snippet"
}

dir_of() { echo "$BATS_TEST_TMPDIR/a-$(basename "$1" .sh)"; }

both() {
    local seen=0 lib
    for lib in awg_common.sh awg_common_en.sh; do
        "$1" "$lib" || return 1
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}

# expect_fail <lib> <generation> <break snippet> <what> [<ru phrase> <en phrase>]
# The optional phrases pin the REASON, not only the refusal. Without them a case
# passes for the wrong reason: a missing file also fails the "not empty" check,
# so dropping the existence check would still refuse it - while telling the
# person to look for an empty file instead of a missing one.
expect_fail() {
    local lib="$1" gen="$2" brk="$3" what="$4" ru="${5:-}" en="${6:-}" out want
    out=$(lib_run "$lib" "$gen" "$brk
        awg_client_artifacts_check c1; echo \"RC=\$?\"")
    [[ "$out" == *"RC=0"* ]] && { echo "$what accepted ($lib): $out"; return 1; }
    [[ "$out" == *"ERR:"* ]] || { echo "$what refused without a reason ($lib): $out"; return 1; }
    if [ -n "$ru" ]; then
        want="$ru"
        [[ "$lib" == *_en.sh ]] && want="$en"
        [[ "$out" == *"$want"* ]] || { echo "$what refused with the wrong reason ($lib): $out"; return 1; }
    fi
    return 0
}

a_complete() {
    local lib="$1" out
    out=$(lib_run "$lib" 3.1 'awg_client_artifacts_check c1; echo "RC=$?"')
    [[ "$out" == *"RC=0"* ]] || { echo "a complete 3.1 set was refused ($lib): $out"; return 1; }
}
@test "artifacts 3.1: a complete set passes, both twins" {
    both a_complete
}

a_complete_20() {
    local lib="$1" out
    out=$(lib_run "$lib" 2.0 'awg_client_artifacts_check c1; echo "RC=$?"')
    [[ "$out" == *"RC=0"* ]] || { echo "a complete 2.0 set was refused ($lib): $out"; return 1; }
}
@test "artifacts 2.0: a complete set passes without any third-line line, both twins" {
    both a_complete_20
}

a_missing() {
    local lib="$1" f
    for f in c1.conf c1.png c1.vpnuri c1.vpnuri.png; do
        expect_fail "$lib" 3.1 "rm -f \"\$AWG_DIR/$f\"" "a set without $f" "нет файла" "is missing" || return 1
    done
}
@test "artifacts: a missing file of the set is refused, whichever one it is, both twins" {
    both a_missing
}

a_empty() {
    local lib="$1" f
    for f in c1.conf c1.png c1.vpnuri c1.vpnuri.png; do
        expect_fail "$lib" 3.1 ": > \"\$AWG_DIR/$f\"" "an empty $f" "пуст" "is empty" || return 1
    done
}
@test "artifacts: an empty file of the set is refused, whichever one it is, both twins" {
    both a_empty
}

a_symlink() {
    # The link points at a real, non-empty file inside the folder: a dangling
    # link would also fail the existence check and pass for the wrong reason.
    expect_fail "$1" 3.1 'mv "$AWG_DIR/c1.png" "$AWG_DIR/real.png"; ln -s "$AWG_DIR/real.png" "$AWG_DIR/c1.png"' "a symlink in place of a file" "символьная ссылка" "is a symlink"
}
@test "artifacts: a symlink in place of a file is refused, both twins" {
    both a_symlink
}

a_uri_shape() {
    expect_fail "$1" 3.1 'printf "not-a-link\n" > "$AWG_DIR/c1.vpnuri"' "a .vpnuri that is not a link"
}
@test "artifacts: a .vpnuri that does not start with vpn:// is refused, both twins" {
    both a_uri_shape
}

a_key_missing() {
    expect_fail "$1" 3.1 'sed -i "/^HeaderProtectionKey = /d" "$AWG_DIR/c1.conf"' "a 3.1 profile without the key"
}
@test "artifacts 3.1: a client config without the key is refused, both twins" {
    both a_key_missing
}

a_key_wrong() {
    expect_fail "$1" 3.1 "sed -i \"s|^HeaderProtectionKey = .*|HeaderProtectionKey = $KEY_OTHER|\" \"\$AWG_DIR/c1.conf\"" \
        "a 3.1 profile whose key differs from the key file"
}
@test "artifacts 3.1: a key that differs from the key file is refused, both twins" {
    both a_key_wrong
}

a_key_twice() {
    expect_fail "$1" 3.1 "sed -i \"0,/^HeaderProtectionKey = /s||HeaderProtectionKey = $KEY_OK\\nHeaderProtectionKey = |\" \"\$AWG_DIR/c1.conf\"" \
        "a 3.1 profile with two key lines"
}
@test "artifacts 3.1: two key lines in one config are refused, both twins" {
    both a_key_twice
}

a_cpa_wrong() {
    expect_fail "$1" 3.1 'sed -i "s|^ContentPaddingAddition = .*|ContentPaddingAddition = 16-32|" "$AWG_DIR/c1.conf"' \
        "a 3.1 profile whose padding differs from the installation"
}
@test "artifacts 3.1: a padding that differs from the installation is refused, both twins" {
    both a_cpa_wrong
}

a_no_trace() {
    local lib="$1" out trace
    trace="$BATS_TEST_TMPDIR/atrace-$(basename "$lib" .sh)"
    rm -f "$trace"
    out=$(lib_run "$lib" 3.1 '
        exec 7>"'"$trace"'"
        BASH_XTRACEFD=7
        set -x
        awg_client_artifacts_check c1
        rc=$?
        set +x
        echo "RC=$rc"')
    [[ "$out" == *"RC=0"* ]] || { echo "the check failed under tracing ($lib): $out"; return 1; }
    [ -s "$trace" ] || { echo "no trace was written ($lib)"; return 1; }
    grep -qF "$KEY_OK" "$trace" && { echo "the key is in the trace ($lib)"; return 1; }
    return 0
}
@test "artifacts 3.1: the key does not reach the xtrace output, both twins" {
    both a_no_trace
}

a_scan_vars_local() {
    local lib="$1" out
    # The check compares the key value through _awg_hpk_conf_scan, whose results
    # belong to the caller's locals. Declared anywhere else, the key would stay
    # in a global of the installer shell for the rest of the run.
    out=$(lib_run "$lib" 3.1 'awg_client_artifacts_check c1; echo "RC=$?"; declare -p _hs_val _hs_if _hs_any _hs_out 2>/dev/null | wc -l')
    [[ "$out" == *"RC=0"* ]] || { echo "a complete 3.1 set was refused ($lib): $out"; return 1; }
    [ "$(tail -1 <<< "$out")" -eq 0 ] || { echo "scan variables left in the caller shell ($lib): $out"; return 1; }
}
@test "artifacts 3.1: the key value does not stay in a global of the calling shell, both twins" {
    both a_scan_vars_local
}

a_cpa_with_comment() {
    local lib="$1" out
    # The renderers write the padding in the checked form; the installation value
    # may carry a comment or spaces. The set check compares the same checked form.
    out=$(lib_run "$lib" 3.1 'AWG_CPA="32 - 128 # set by hand"; awg_client_artifacts_check c1; echo "RC=$?"')
    [[ "$out" == *"RC=0"* ]] || { echo "a set written in the checked form was refused ($lib): $out"; return 1; }
}
@test "artifacts 3.1: the padding is compared in its checked form, both twins" {
    both a_cpa_with_comment
}
