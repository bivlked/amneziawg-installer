#!/usr/bin/env bats
# Third-line profile in the rendered configs: HeaderProtectionKey and
# ContentPaddingAddition.
#
# Both lines are written only when the installation is marked 3.1, and they are
# written to BOTH sides: the key is a two-way parameter, a client profile without
# it does not connect to a server that has it. The key value comes from the key
# file (read through a redirect, never through argv), the padding from AWG_CPA,
# which generate_awg_params puts into the init on 3.1 and leaves empty on 2.0.
#
# A 3.1 install whose key file is missing must FAIL the render rather than write
# a config without the key: that config would look like a valid 3.1 profile and
# would silently refuse every client. The same for a padding value the tools
# would not accept.
#
# The 2.0 shape is pinned separately in tests/test_awg31_render_golden.bats.

KEY_OK="QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQA="
KEY_OK2="WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWA="

# lib_run <lib> <generation> <cpa> <key|-> <snippet>
# Prepares an install of the given generation in $AWG_DIR and runs the snippet.
lib_run() {
    local lib="$1" gen="$2" cpa="$3" key="$4" snippet="$5" d
    d="$BATS_TEST_TMPDIR/r-$(basename "$lib" .sh)"
    rm -rf "$d"; mkdir -p "$d/keys"
    {
        printf "export AWG_PORT=39743\nexport AWG_TUNNEL_SUBNET='10.9.9.1/24'\nexport DISABLE_IPV6=1\n"
        printf "export ALLOWED_IPS_MODE=1\nexport AWG_PROTOCOL='%s'\nexport AWG_CPA='%s'\n" "$gen" "$cpa"
        printf "export AWG_Jc=6\nexport AWG_Jmin=55\nexport AWG_Jmax=380\n"
        printf "export AWG_S1=72\nexport AWG_S2=56\nexport AWG_S3=32\nexport AWG_S4=16\n"
        printf "export AWG_H1='1'\nexport AWG_H2='2'\nexport AWG_H3='3'\nexport AWG_H4='4'\n"
        printf "export AWG_APPLY_MODE='syncconf'\n"
    } > "$d/awgsetup_cfg.init"
    printf 'SRVPRIVKEYPLACEHOLDER\n' > "$d/server_private.key"
    [[ "$key" == "-" ]] || printf '%s\n' "$key" > "$d/server_hpk.key"
    AWG_DIR="$d" timeout 60 bash -c '
        export CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init" SERVER_CONF_FILE="$AWG_DIR/awg0.conf"
        export KEYS_DIR="$AWG_DIR/keys" EXPIRY_DIR="$AWG_DIR/expiry"
        log() { :; }; log_warn() { :; }; log_error() { echo "ERR: $*"; }; log_debug() { :; }
        source "$1" >/dev/null 2>&1 || true
        get_main_nic() { echo eth0; }
        eval "$2"
    ' _ "$BATS_TEST_DIRNAME/../$lib" "$snippet"
}

dir_of() { echo "$BATS_TEST_TMPDIR/r-$(basename "$1" .sh)"; }

# leftovers_none <dir> <lib> : a refused render leaves no half-written config
# behind. awg_mktemp builds its files with `mktemp -p`, so they are tmp.* next
# to the config; the registry file (.awg_temp_registry.*) is not one of them.
leftovers_none() {
    local d="$1" lib="$2" n
    n=$(find "$d" -maxdepth 1 -name 'tmp.*' | wc -l)
    [ "$n" -eq 0 ] || { echo "$n temp file(s) left after a refused render ($lib)"; find "$d" -maxdepth 1 -name 'tmp.*'; return 1; }
}

both() {
    local seen=0 lib
    for lib in awg_common.sh awg_common_en.sh; do
        "$1" "$lib" || return 1
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}

# ---------- server ----------

r_server_31() {
    local lib="$1" d out
    d=$(dir_of "$lib")
    out=$(lib_run "$lib" 3.1 32-128 "$KEY_OK" 'render_server_config; echo "RC=$?"')
    [[ "$out" == *"RC=0"* ]] || { echo "render failed ($lib): $out"; return 1; }
    grep -qxF "HeaderProtectionKey = $KEY_OK" "$d/awg0.conf" || { echo "no key line ($lib)"; return 1; }
    grep -qxF "ContentPaddingAddition = 32-128" "$d/awg0.conf" || { echo "no padding line ($lib)"; return 1; }
    # Both belong to [Interface]: after the last profile line, before any peer.
    local keys
    keys=$(sed -n 's/^\[\(.*\)\]$/[\1]/p; s/^\([A-Za-z_][A-Za-z0-9_]*\) = .*/\1/p' "$d/awg0.conf")
    [ "$(printf '%s\n' "$keys" | tail -2 | head -1)" = "HeaderProtectionKey" ] \
        || { echo "key line out of place ($lib): $keys"; return 1; }
    [ "$(printf '%s\n' "$keys" | tail -1)" = "ContentPaddingAddition" ] \
        || { echo "padding line out of place ($lib): $keys"; return 1; }
}
@test "render 3.1: the server config carries the key and the padding, both twins" {
    both r_server_31
}

r_server_no_key() {
    local lib="$1" d out
    d=$(dir_of "$lib")
    out=$(lib_run "$lib" 3.1 32-128 - 'render_server_config; echo "RC=$?"')
    [[ "$out" == *"RC=0"* ]] && { echo "render succeeded without the key file ($lib)"; return 1; }
    # The reason has to say the file is MISSING. Reading a file that is not there
    # fails on its own, so without this the case would also pass for a library
    # that dropped the check and only reported "cannot be read" - true, but it
    # sends the person looking for a permission problem instead of a missing key.
    local want="а файла ключа"
    [[ "$lib" == *_en.sh ]] && want="is missing"
    [[ "$out" == *"$want"* ]] || { echo "reason does not name the missing key file ($lib): $out"; return 1; }
    [ ! -f "$d/awg0.conf" ] || { echo "a config was written anyway ($lib)"; return 1; }
    leftovers_none "$d" "$lib" || return 1
}
@test "render 3.1: a missing key file fails the server render instead of writing a keyless 3.1 config, both twins" {
    both r_server_no_key
}

r_server_bad_cpa() {
    local lib="$1" d out
    d=$(dir_of "$lib")
    out=$(lib_run "$lib" 3.1 70000 "$KEY_OK" 'render_server_config; echo "RC=$?"')
    [[ "$out" == *"RC=0"* ]] && { echo "render accepted an out-of-range padding ($lib)"; return 1; }
    [[ "$out" == *"ERR:"* ]] || { echo "no reason printed ($lib): $out"; return 1; }
    [ ! -f "$d/awg0.conf" ] || { echo "a config was written anyway ($lib)"; return 1; }
    leftovers_none "$d" "$lib" || return 1
}
@test "render 3.1: a padding the tools would not accept fails the render, both twins" {
    both r_server_bad_cpa
}

# ---------- client ----------

r_client_31() {
    local lib="$1" d out
    d=$(dir_of "$lib")
    out=$(lib_run "$lib" 3.1 32-128 "$KEY_OK" '
        render_server_config || exit 1
        render_client_config c1 10.9.9.2 CLIENTPRIV SERVERPUB 203.0.113.10 39743 || exit 1
        echo "RC=0"')
    [[ "$out" == *"RC=0"* ]] || { echo "render failed ($lib): $out"; return 1; }
    grep -qxF "HeaderProtectionKey = $KEY_OK" "$d/c1.conf" || { echo "client has no key line ($lib)"; return 1; }
    grep -qxF "ContentPaddingAddition = 32-128" "$d/c1.conf" || { echo "client has no padding line ($lib)"; return 1; }
    # In [Interface], not in [Peer]: everything before the [Peer] header.
    local before
    before=$(sed -n '1,/^\[Peer\]$/p' "$d/c1.conf")
    grep -qxF "HeaderProtectionKey = $KEY_OK" <<< "$before" || { echo "key line after [Peer] ($lib)"; return 1; }
    grep -qxF "ContentPaddingAddition = 32-128" <<< "$before" || { echo "padding line after [Peer] ($lib)"; return 1; }
}
@test "render 3.1: the client config carries the same key and padding, both twins" {
    both r_client_31
}

r_client_key_matches_server() {
    local lib="$1" d out
    d=$(dir_of "$lib")
    # A file that disagrees with the running server config must stop the render
    # rather than hand out a profile that cannot connect. The guard itself lives
    # in awg_hpk_ensure, which load_awg_params calls before either renderer; this
    # case pins that the renderer really is behind it.
    out=$(lib_run "$lib" 3.1 32-128 "$KEY_OK" '
        render_server_config || exit 1
        printf "%s\n" "'"$KEY_OK2"'" > "$AWG_DIR/server_hpk.key"
        render_client_config c1 10.9.9.2 CLIENTPRIV SERVERPUB 203.0.113.10 39743; echo "RC=$?"')
    [[ "$out" == *"RC=0"* ]] && { echo "client rendered with a key that differs from the server config ($lib)"; return 1; }
    # The reason has to name the disagreement. Without this the case passes for
    # the wrong reason on a library that does not write the key at all: the
    # render then fails because the config has no key, which is a different bug.
    local want="не совпадает"
    [[ "$lib" == *_en.sh ]] && want="does not match"
    [[ "$out" == *"$want"* ]] || { echo "reason does not name the disagreement ($lib): $out"; return 1; }
}
@test "render 3.1: a key file that disagrees with the server config fails the client render, both twins" {
    both r_client_key_matches_server
}

# ---------- 2.0 stays as it is ----------

r_20_untouched() {
    local lib="$1" d out
    d=$(dir_of "$lib")
    out=$(lib_run "$lib" 2.0 "" "$KEY_OK" '
        render_server_config || exit 1
        render_client_config c1 10.9.9.2 CLIENTPRIV SERVERPUB 203.0.113.10 39743 || exit 1
        echo "RC=0"')
    [[ "$out" == *"RC=0"* ]] || { echo "render failed ($lib): $out"; return 1; }
    local f n
    for f in "$d/awg0.conf" "$d/c1.conf"; do
        n=$(grep -ciE '^(HeaderProtectionKey|ContentPaddingAddition) = ' "$f") || true
        [ "$n" -eq 0 ] || { echo "third-line key on a 2.0 install in $f ($lib)"; return 1; }
    done
}
@test "render 2.0: a key file lying around does not put third-line keys into the configs, both twins" {
    both r_20_untouched
}

# ---------- the key stays out of the trace ----------

r_no_trace() {
    local lib="$1" d out trace
    d=$(dir_of "$lib")
    trace="$BATS_TEST_TMPDIR/trace-$(basename "$lib" .sh)"
    rm -f "$trace"
    out=$(lib_run "$lib" 3.1 32-128 "$KEY_OK" '
        exec 7>"'"$trace"'"
        BASH_XTRACEFD=7
        set -x
        render_server_config
        rc=$?
        render_client_config c1 10.9.9.2 CLIENTPRIV SERVERPUB 203.0.113.10 39743 || rc=1
        set +x
        echo "RC=$rc"')
    [[ "$out" == *"RC=0"* ]] || { echo "render failed under tracing ($lib): $out"; return 1; }
    [ -s "$trace" ] || { echo "no trace was written ($lib)"; return 1; }
    grep -qF "$KEY_OK" "$trace" && { echo "the key is in the trace ($lib)"; grep -nF "$KEY_OK" "$trace" | head -3; return 1; }
    return 0
}
@test "render 3.1: the key does not reach the xtrace output, both twins" {
    both r_no_trace
}

# ---------- an unreadable generation marker ----------
#
# awg_hpk_ensure lets add and regen go on over a hand-mangled init as long as no
# key exists anywhere: the person must not lose client management over a typo.
# The renderers have to follow the same rule, or that promise is broken one call
# later. With a key file present the generation cannot be guessed safely, so the
# render refuses and names the marker.

r_broken_marker_no_key() {
    local lib="$1" d out f n
    d=$(dir_of "$lib")
    out=$(lib_run "$lib" yes "" - '
        render_server_config || exit 1
        render_client_config c1 10.9.9.2 CLIENTPRIV SERVERPUB 203.0.113.10 39743 || exit 1
        echo "RC=0"')
    [[ "$out" == *"RC=0"* ]] || { echo "an unreadable marker without a key stopped the render ($lib): $out"; return 1; }
    for f in "$d/awg0.conf" "$d/c1.conf"; do
        n=$(grep -ciE '^(HeaderProtectionKey|ContentPaddingAddition) = ' "$f") || true
        [ "$n" -eq 0 ] || { echo "third-line key written with an unreadable marker in $f ($lib)"; return 1; }
    done
}
@test "render: an unreadable marker without a key renders as before, both twins" {
    both r_broken_marker_no_key
}

r_broken_marker_with_key() {
    local lib="$1" d out want
    d=$(dir_of "$lib")
    out=$(lib_run "$lib" yes 32-128 "$KEY_OK" 'render_server_config; echo "RC=$?"')
    [[ "$out" == *"RC=0"* ]] && { echo "rendered over an unreadable marker with a key file present ($lib)"; return 1; }
    want="AWG_PROTOCOL"
    [[ "$out" == *"$want"* ]] || { echo "the reason does not name the marker ($lib): $out"; return 1; }
    [ ! -f "$d/awg0.conf" ] || { echo "a config was written anyway ($lib)"; return 1; }
    leftovers_none "$d" "$lib" || return 1
    # A dangling link in place of the key file counts as a key being there.
    out=$(lib_run "$lib" yes 32-128 - '
        ln -s "$AWG_DIR/nowhere" "$AWG_DIR/server_hpk.key"
        [ -L "$AWG_DIR/server_hpk.key" ] || { echo "NO_LINK"; exit 0; }
        render_server_config; echo "RC=$?"')
    [[ "$out" != *NO_LINK* ]] || { echo "could not create the dangling link on this system ($lib)"; return 1; }
    [[ "$out" == *"RC=0"* ]] && { echo "rendered over an unreadable marker with a dangling key link ($lib)"; return 1; }
    [[ "$out" == *"$want"* ]] || { echo "the dangling link case refused for another reason ($lib): $out"; return 1; }
    [ ! -f "$d/awg0.conf" ] || { echo "a config was written anyway with a dangling key link ($lib)"; return 1; }
    leftovers_none "$d" "$lib" || return 1
}
@test "render: an unreadable marker with a key file present refuses the render, both twins" {
    both r_broken_marker_with_key
}

# ---------- a rerun over live peers ----------

r_server_31_with_peers() {
    local lib="$1" d out first_peer hpk_line cpa_line
    d=$(dir_of "$lib")
    out=$(lib_run "$lib" 3.1 32-128 "$KEY_OK" '
        render_server_config || exit 1
        printf "\n[Peer]\n#_Name = a\nPublicKey = PA\nAllowedIPs = 10.9.9.2/32\n" >> "$SERVER_CONF_FILE"
        printf "\n[Peer]\n#_Name = b\nPublicKey = PB\nAllowedIPs = 10.9.9.3/32\n" >> "$SERVER_CONF_FILE"
        cp "$SERVER_CONF_FILE" "$AWG_DIR/bak"
        render_server_config "$AWG_DIR/bak" || exit 1
        echo "RC=0"')
    [[ "$out" == *"RC=0"* ]] || { echo "a rerun over live peers failed ($lib): $out"; return 1; }
    [ "$(grep -c '^HeaderProtectionKey = ' "$d/awg0.conf")" -eq 1 ] || { echo "the key line is not there exactly once ($lib)"; cat "$d/awg0.conf"; return 1; }
    [ "$(grep -c '^ContentPaddingAddition = ' "$d/awg0.conf")" -eq 1 ] || { echo "the padding line is not there exactly once ($lib)"; return 1; }
    [ "$(grep -c '^\[Peer\]$' "$d/awg0.conf")" -eq 2 ] || { echo "the peers were not carried over ($lib)"; return 1; }
    first_peer=$(grep -n '^\[Peer\]$' "$d/awg0.conf" | head -1 | cut -d: -f1)
    hpk_line=$(grep -n '^HeaderProtectionKey = ' "$d/awg0.conf" | cut -d: -f1)
    cpa_line=$(grep -n '^ContentPaddingAddition = ' "$d/awg0.conf" | cut -d: -f1)
    [ "$hpk_line" -lt "$first_peer" ] && [ "$cpa_line" -lt "$first_peer" ] \
        || { echo "third-line lines landed in a peer block ($lib): key=$hpk_line padding=$cpa_line peer=$first_peer"; return 1; }
}
@test "render 3.1: a rerun over live peers keeps the key and padding in [Interface], once, both twins" {
    both r_server_31_with_peers
}

# ---------- the padding is written as checked ----------

r_cpa_normalized() {
    local lib="$1" d out f
    d=$(dir_of "$lib")
    # A comment or spaces in or around the value pass the check, which reads the value
    # the way the tools do. What reaches the configs has to be that same value:
    # the comment would otherwise travel into the vpn:// link as part of it.
    out=$(lib_run "$lib" 3.1 "32 - 128 # set by hand" "$KEY_OK" '
        render_server_config || exit 1
        render_client_config c1 10.9.9.2 CLIENTPRIV SERVERPUB 203.0.113.10 39743 || exit 1
        echo "RC=0"')
    [[ "$out" == *"RC=0"* ]] || { echo "render failed ($lib): $out"; return 1; }
    for f in "$d/awg0.conf" "$d/c1.conf"; do
        grep -qxF "ContentPaddingAddition = 32-128" "$f" || { echo "the padding was not written as checked in $f ($lib): $(grep ContentPadding "$f")"; return 1; }
    done
}
@test "render 3.1: the padding is written in the form that was checked, both twins" {
    both r_cpa_normalized
}
