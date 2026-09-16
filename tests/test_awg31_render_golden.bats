#!/usr/bin/env bats
# What a 2.0 render looks like, pinned BEFORE the third-line profile touches it.
#
# The third line adds two lines to both configs (HeaderProtectionKey and
# ContentPaddingAddition) and they must appear ONLY when the installation is
# marked 3.1. An install marked 2.0 has to keep rendering exactly what it
# renders today: the same keys, in the same order, and nothing else. A silent
# extra line there is not cosmetic - a client profile that carries a key the
# server does not use (or the other way round) does not connect, and the person
# finds out when the tunnel stays down, not when the file is written.
#
# The pin is on the KEY SEQUENCE, not on the whole file: PostUp/PostDown carry
# NIC names, MSS values and isolation rules that legitimately change, and a
# byte-for-byte golden file would fail on every unrelated routing edit while
# saying nothing about the profile. Of the profile values, I1 in the server
# config is compared as a value; Jc..H4 are pinned by the key sequence.
#
# Both library twins run for real in a separate shell: the renderers lean on a
# dozen neighbouring functions, so lifting one function out of the source would
# test a different thing than production runs.

# lib_run <lib> <snippet> : run snippet with a 2.0 install prepared in $AWG_DIR.
lib_run() {
    local lib="$1" snippet="$2" d
    d="$BATS_TEST_TMPDIR/g-$(basename "$lib" .sh)"
    rm -rf "$d"; mkdir -p "$d/keys"
    printf "export AWG_PORT=39743\nexport AWG_TUNNEL_SUBNET='10.9.9.1/24'\nexport DISABLE_IPV6=1\n" > "$d/awgsetup_cfg.init"
    printf "export ALLOWED_IPS_MODE=1\nexport AWG_PROTOCOL='2.0'\n" >> "$d/awgsetup_cfg.init"
    printf "export AWG_Jc=6\nexport AWG_Jmin=55\nexport AWG_Jmax=380\n" >> "$d/awgsetup_cfg.init"
    printf "export AWG_S1=72\nexport AWG_S2=56\nexport AWG_S3=32\nexport AWG_S4=16\n" >> "$d/awgsetup_cfg.init"
    printf "export AWG_H1='100000-800000'\nexport AWG_H2='1000000-8000000'\n" >> "$d/awgsetup_cfg.init"
    printf "export AWG_H3='10000000-80000000'\nexport AWG_H4='100000000-800000000'\n" >> "$d/awgsetup_cfg.init"
    printf "export AWG_I1='<r 128>'\nexport AWG_APPLY_MODE='syncconf'\n" >> "$d/awgsetup_cfg.init"
    printf 'SRVPRIVKEYPLACEHOLDER\n' > "$d/server_private.key"
    {
        printf '[Interface]\nPrivateKey = SRVPRIVKEYPLACEHOLDER\nAddress = 10.9.9.1/24\nMTU = 1280\n'
        printf 'ListenPort = 39743\nJc = 6\nJmin = 55\nJmax = 380\nS1 = 72\nS2 = 56\nS3 = 32\nS4 = 16\n'
        printf 'H1 = 100000-800000\nH2 = 1000000-8000000\nH3 = 10000000-80000000\nH4 = 100000000-800000000\n'
        printf 'I1 = <r 128>\n'
        printf '\n[Peer]\n#_Name = my_phone\nPublicKey = PEERPUB\nAllowedIPs = 10.9.9.2/32\n'
    } > "$d/awg0.conf"
    AWG_DIR="$d" timeout 60 bash -c '
        export CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init" SERVER_CONF_FILE="$AWG_DIR/awg0.conf"
        export KEYS_DIR="$AWG_DIR/keys" EXPIRY_DIR="$AWG_DIR/expiry"
        log() { :; }; log_warn() { :; }; log_error() { echo "ERR: $*"; }; log_debug() { :; }
        source "$1" >/dev/null 2>&1 || true
        get_main_nic() { echo eth0; }
        eval "$2"
    ' _ "$BATS_TEST_DIRNAME/../$(basename "$lib")" "$snippet"
}

# keys_of <file> : the key names of the file, in order, sections included.
keys_of() {
    sed -n 's/^\[\(.*\)\]$/[\1]/p; s/^\([A-Za-z_][A-Za-z0-9_]*\) = .*/\1/p' "$1"
}

both() {
    local seen=0 lib
    for lib in awg_common.sh awg_common_en.sh; do
        "$1" "$lib" || return 1
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}

g_server() {
    local lib="$1" d out
    d="$BATS_TEST_TMPDIR/g-$(basename "$lib" .sh)"
    out=$(lib_run "$lib" 'render_server_config "$SERVER_CONF_FILE"; echo "RC=$?"')
    [[ "$out" == *"RC=0"* ]] || { echo "render failed ($lib): $out"; return 1; }
    # Compared through command substitution on both sides: it strips trailing
    # newlines, and this file legitimately ends without one (the peer block is
    # carried over through a substitution, which eats the last newline). A plain
    # diff would report that as a difference and say nothing about the keys.
    local got want
    got=$(keys_of "$d/awg0.conf")
    want=$(printf '%s\n' '[Interface]' PrivateKey Address MTU ListenPort \
        PostUp PostDown Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4 I1 '[Peer]' PublicKey AllowedIPs)
    [ "$got" = "$want" ] || { echo "server keys differ ($lib):"; diff <(echo "$want") <(echo "$got"); return 1; }
    # The missing final newline is itself part of the 2.0 shape: anything the
    # third line appends AFTER the peers would change it.
    [ -n "$(tail -c 1 "$d/awg0.conf")" ] || { echo "server config now ends with a newline ($lib)"; return 1; }
    grep -q '^#_Name = my_phone$' "$d/awg0.conf" || { echo "carried peer lost ($lib)"; return 1; }
    grep -qx 'I1 = <r 128>' "$d/awg0.conf" || { echo "I1 value changed ($lib)"; return 1; }
}
@test "golden 2.0: the server config keeps its key sequence and carries the peers, both twins" {
    both g_server
}

g_client() {
    local lib="$1" d out
    d="$BATS_TEST_TMPDIR/g-$(basename "$lib" .sh)"
    out=$(lib_run "$lib" 'render_client_config c1 10.9.9.2 CLIENTPRIV SERVERPUB 203.0.113.10 39743; echo "RC=$?"')
    [[ "$out" == *"RC=0"* ]] || { echo "render failed ($lib): $out"; return 1; }
    diff <(keys_of "$d/c1.conf") <(printf '%s\n' '[Interface]' PrivateKey Address DNS MTU \
        Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4 I1 '[Peer]' PublicKey Endpoint AllowedIPs PersistentKeepalive) \
        || { echo "client keys differ ($lib)"; return 1; }
    grep -qx 'PersistentKeepalive = 33' "$d/c1.conf" || { echo "keepalive changed ($lib)"; return 1; }
}
@test "golden 2.0: the client config keeps its key sequence, both twins" {
    both g_client
}

g_no_third_line() {
    local lib="$1" d out
    d="$BATS_TEST_TMPDIR/g-$(basename "$lib" .sh)"
    out=$(lib_run "$lib" '
        render_server_config "$SERVER_CONF_FILE" || exit 1
        render_client_config c1 10.9.9.2 CLIENTPRIV SERVERPUB 203.0.113.10 39743 || exit 1
        echo "RC=0"')
    [[ "$out" == *"RC=0"* ]] || { echo "render failed ($lib): $out"; return 1; }
    local f n
    for f in "$d/awg0.conf" "$d/c1.conf"; do
        n=$(grep -ciE '^[[:space:]]*(HeaderProtectionKey|ContentPaddingAddition)[[:space:]]*=' "$f") || true
        [ "$n" -eq 0 ] || { echo "third-line key in $f ($lib): $n"; grep -niE 'HeaderProtection|ContentPadding' "$f"; return 1; }
    done
}
@test "golden 2.0: neither config gains a third-line key on an install marked 2.0, both twins" {
    both g_no_third_line
}

@test "golden 2.0: both twins render the same key sequence" {
    local ru en
    lib_run awg_common.sh 'render_server_config "$SERVER_CONF_FILE"' >/dev/null
    lib_run awg_common_en.sh 'render_server_config "$SERVER_CONF_FILE"' >/dev/null
    ru=$(keys_of "$BATS_TEST_TMPDIR/g-awg_common/awg0.conf")
    en=$(keys_of "$BATS_TEST_TMPDIR/g-awg_common_en/awg0.conf")
    [ -n "$ru" ] || { echo "RU render produced nothing"; false; }
    [ -n "$en" ] || { echo "EN render produced nothing"; false; }
    diff <(echo "$ru") <(echo "$en")
}
