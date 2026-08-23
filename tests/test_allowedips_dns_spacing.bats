#!/usr/bin/env bats
# D#38 (@humowns) - `regenerate_client` silently collapsed the comma-space
# separator in AllowedIPs and DNS.
#
# The installer writes those lists as "a, b, c". regen read them back through
# `tr -d '[:space:]'`, which stripped the spaces together with CR, and wrote
# what it had read straight into .conf. The damage is invisible to the eye and
# survived every later regen. `manage modify` wrote its value verbatim and could
# put a collapsed list there from the other side.
#
# The fix normalises instead of stripping, so a repeated regen also REPAIRS
# configs that were already collapsed.
#
# The `tr -d ' \r'` inside the vpn:// builder looks like the same bug and is
# NOT: that path never writes to .conf, and its value feeds a JSON array where
# the compact form is required. See the guard test at the bottom of this file.

load test_helper

# ---------------------------------------------------------------------------
# awg_normalize_csv - the helper both paths now share
# ---------------------------------------------------------------------------

@test "D#38: normalize keeps the canonical comma-space separator" {
    [ "$(awg_normalize_csv '1.0.0.0/8, 2.0.0.0/7, 4.0.0.0/6')" = '1.0.0.0/8, 2.0.0.0/7, 4.0.0.0/6' ]
}

@test "D#38: normalize repairs an already collapsed list" {
    [ "$(awg_normalize_csv '1.0.0.0/8,2.0.0.0/7,4.0.0.0/6')" = '1.0.0.0/8, 2.0.0.0/7, 4.0.0.0/6' ]
}

@test "D#38: normalize trims ragged spacing around elements" {
    [ "$(awg_normalize_csv '  1.0.0.0/8 ,2.0.0.0/7  ')" = '1.0.0.0/8, 2.0.0.0/7' ]
}

@test "D#38: normalize drops empty elements" {
    [ "$(awg_normalize_csv '1.0.0.0/8,,2.0.0.0/7')" = '1.0.0.0/8, 2.0.0.0/7' ]
}

@test "D#38: normalize still removes CR (CRLF configs broke the URI JSON)" {
    run awg_normalize_csv "$(printf '1.2.3.4/32, 5.6.7.8/32\r')"
    [ "$output" = '1.2.3.4/32, 5.6.7.8/32' ]
}

@test "D#38: normalize does not glob-expand the value" {
    [ "$(awg_normalize_csv '*, 1.2.3.4/32')" = '*, 1.2.3.4/32' ]
}

@test "D#38: normalize strips whitespace INSIDE an element, not only at its edges" {
    # The old tr -d '[:space:]' cleaned "1.1.1. 1" by luck. Trimming edges only
    # would have preserved the typo forever, and the `manage modify` validator
    # strips inner whitespace too, so the two must agree.
    [ "$(awg_normalize_csv '1.1.1. 1, 8.8.8.8')" = '1.1.1.1, 8.8.8.8' ]
    [ "$(awg_normalize_csv '10.0.0.0 /8')" = '10.0.0.0/8' ]
}

@test "D#38: normalize is idempotent" {
    local once twice
    once=$(awg_normalize_csv '1.0.0.0/8,2.0.0.0/7')
    twice=$(awg_normalize_csv "$once")
    [ "$once" = "$twice" ]
}

@test "D#38: normalize returns empty for blank input" {
    [ -z "$(awg_normalize_csv '')" ]
    [ -z "$(awg_normalize_csv '   ')" ]
}

@test "D#38: single-value lists are untouched (default-upgrade comparisons rely on it)" {
    [ "$(awg_normalize_csv '0.0.0.0/0')" = '0.0.0.0/0' ]
    [ "$(awg_normalize_csv '1.1.1.1')" = '1.1.1.1' ]
    [ "$(awg_normalize_csv '0.0.0.0/0, ::/0')" = '0.0.0.0/0, ::/0' ]
}

# ---------------------------------------------------------------------------
# Functional: regen must not collapse the client's lists
# ---------------------------------------------------------------------------

_spacing_regen_stubs() {
    get_server_public_ip()  { echo "203.0.113.10"; }
    _ensure_server_public_key() { return 0; }
    generate_qr()          { return 0; }
    generate_vpn_uri()     { return 0; }
    generate_qr_vpnuri()   { return 0; }
    load_awg_params()      { export AWG_PORT=39743; return 0; }
    render_client_config() {
        printf '[Interface]\nPrivateKey = FAKEPRIVKEY\nAddress = %s/32\nDNS = 1.1.1.1, 1.0.0.1\nMTU = 1280\nPersistentKeepalive = 33\n[Peer]\nPublicKey = FAKESERVERPUB\nAllowedIPs = %s\n' \
            "$2" "${ALLOWED_IPS:-0.0.0.0/0}" > "$AWG_DIR/${1}.conf"
        return 0
    }
    export -f get_server_public_ip _ensure_server_public_key generate_qr \
        generate_vpn_uri generate_qr_vpnuri load_awg_params render_client_config
}

_write_client() {
    printf '[Interface]\nPrivateKey = FAKEPRIVKEY\nAddress = 10.9.9.2/32\nDNS = %s\nMTU = 1280\nPersistentKeepalive = 33\n[Peer]\nPublicKey = FAKESERVERPUB\nAllowedIPs = %s\n' \
        "$2" "$3" > "$AWG_DIR/${1}.conf"
}

_prepare() {
    local name="$1"
    mkdir -p "$KEYS_DIR"
    printf 'FAKEPRIVKEY' > "$KEYS_DIR/${name}.private"
    printf 'FAKESERVERPUB' > "$AWG_DIR/server_public.key"
    cat > "$SERVER_CONF_FILE" << EOF
[Interface]
PrivateKey = SERVERKEY
Address = 10.9.9.1/24
ListenPort = 39743
Jc = 6
Jmin = 55
Jmax = 380
S1 = 72
S2 = 56
S3 = 32
S4 = 16
H1 = 100000-800000
H2 = 1000000-8000000
H3 = 10000000-80000000
H4 = 100000000-800000000
PostUp = iptables -I FORWARD -i %i -j ACCEPT
PostDown = iptables -D FORWARD -i %i -j ACCEPT

[Peer]
#_Name = ${name}
PublicKey = TESTPUBKEY
AllowedIPs = 10.9.9.2/32
EOF
    _spacing_regen_stubs
}

@test "D#38: regen preserves the spacing of a customized AllowedIPs list" {
    require_flock
    _prepare "dave"
    _write_client "dave" "1.1.1.1, 1.0.0.1" "10.11.0.0/16, 192.168.100.0/24"
    export ALLOWED_IPS="0.0.0.0/0"
    unset AWG_REGEN_RESET_ROUTES

    run regenerate_client "dave"
    [ "$status" -eq 0 ]
    grep -q '^AllowedIPs = 10\.11\.0\.0/16, 192\.168\.100\.0/24$' "$AWG_DIR/dave.conf"
}

@test "D#38: regen preserves the spacing of a two-entry DNS line" {
    require_flock
    _prepare "erin"
    _write_client "erin" "1.1.1.1, 1.0.0.1" "10.11.0.0/16, 192.168.100.0/24"
    export ALLOWED_IPS="0.0.0.0/0"
    unset AWG_REGEN_RESET_ROUTES

    run regenerate_client "erin"
    [ "$status" -eq 0 ]
    grep -q '^DNS = 1\.1\.1\.1, 1\.0\.0\.1$' "$AWG_DIR/erin.conf"
}

@test "D#38: regen repairs a config that was already collapsed" {
    require_flock
    _prepare "frank"
    _write_client "frank" "1.1.1.1,1.0.0.1" "10.11.0.0/16,192.168.100.0/24"
    export ALLOWED_IPS="0.0.0.0/0"
    unset AWG_REGEN_RESET_ROUTES

    run regenerate_client "frank"
    [ "$status" -eq 0 ]
    grep -q '^AllowedIPs = 10\.11\.0\.0/16, 192\.168\.100\.0/24$' "$AWG_DIR/frank.conf"
    grep -q '^DNS = 1\.1\.1\.1, 1\.0\.0\.1$' "$AWG_DIR/frank.conf"
}

# ---------------------------------------------------------------------------
# Structural: RU and EN must stay in step
# ---------------------------------------------------------------------------

@test "D#38: both awg_common variants define the normalizer" {
    for f in awg_common.sh awg_common_en.sh; do
        run grep -c '^awg_normalize_csv() {' "$BATS_TEST_DIRNAME/../$f"
        [ "$output" = "1" ]
    done
}

@test "D#38: regen no longer strips whitespace out of the two list values" {
    for f in awg_common.sh awg_common_en.sh; do
        run grep -c "sed -n .s/\^DNS.*tr -d" "$BATS_TEST_DIRNAME/../$f"
        [ "$output" = "0" ]
        run grep -c "AllowedIPs\[ ..t\]\*=.*tr -d" "$BATS_TEST_DIRNAME/../$f"
        [ "$output" = "0" ]
    done
}

# The vpn:// builder DELIBERATELY keeps stripping spaces. Its value feeds the
# structured allowed_ips JSON array through split(/,/), and the client builds
# its routes from that array, so a space would land inside the elements.
# Measured on a test server: normalising here put a leading space into 33 of
# the 34 array entries. The spacing of the client .conf is not affected by
# this path, the embedded config is inlined from the file as it is.
#
# This is checked by DECODING the produced link, not by grepping the source.
# The earlier grep-based guard passed even when the space-stripping was removed,
# which is exactly the regression it was supposed to catch.
require_python3()   { command -v python3 &>/dev/null || skip "python3 not available"; }
require_perl_zlib() { perl -MCompress::Zlib -MMIME::Base64 -e '1' 2>/dev/null || skip "perl Compress::Zlib not available"; }

_decode_inner() {
    python3 - "$1" <<'PY'
import base64, zlib, json, sys
uri = sys.argv[1].replace("vpn://", "")
raw = base64.urlsafe_b64decode(uri + "=" * (-len(uri) % 4))
outer = json.loads(zlib.decompress(raw[4:]))
print(outer["containers"][0]["awg"]["last_config"])
PY
}

_decode_outer() {
    python3 - "$1" <<'PYOUT'
import base64, zlib, json, sys
uri = sys.argv[1].replace("vpn://", "")
raw = base64.urlsafe_b64decode(uri + "=" * (-len(uri) % 4))
o = json.loads(zlib.decompress(raw[4:]))
print("dns1=[%s] dns2=[%s]" % (o.get("dns1"), o.get("dns2")))
PYOUT
}

_uri_fixture() {
    create_init_config
    create_server_config
    echo "TESTSERVERPUBKEY_PLACEHOLDER" > "$AWG_DIR/server_public.key"
    cat > "$AWG_DIR/${1}.conf" <<CONF
[Interface]
PrivateKey = TESTCLIENTPRIVKEY
Address = 10.9.9.2/32
DNS = 1.1.1.1, 1.0.0.1

[Peer]
PublicKey = TESTSERVERPUBKEY_PLACEHOLDER
Endpoint = 1.2.3.4:39743
AllowedIPs = ${2}
PersistentKeepalive = 33
CONF
}

@test "D#38: vpn:// allowed_ips array carries no element with a stray space" {
    require_python3
    require_perl_zlib
    _uri_fixture "urispace" "1.0.0.0/8, 2.0.0.0/7, 4.0.0.0/6"

    run generate_vpn_uri "urispace"
    [ "$status" -eq 0 ]

    local inner
    inner=$(_decode_inner "$(cat "$AWG_DIR/urispace.vpnuri")")
    # Every element must be quoted with no leading blank: "1.0.0.0/8", not " 2.0.0.0/7".
    [[ "$inner" != *'" '* ]]
    [[ "$inner" == *'"allowed_ips":["1.0.0.0/8","2.0.0.0/7","4.0.0.0/6"]'* ]]
}

@test "D#38: vpn:// dns2 is a bare address, not one with a leading space" {
    require_python3
    require_perl_zlib
    _uri_fixture "uridns" "0.0.0.0/0"

    run generate_vpn_uri "uridns"
    [ "$status" -eq 0 ]

    # dns1/dns2 are structured fields of the OUTER json, not of last_config.
    local outer
    outer=$(_decode_outer "$(cat "$AWG_DIR/uridns.vpnuri")")
    [ "$outer" = "dns1=[1.1.1.1] dns2=[1.0.0.1]" ]
}

# `manage modify` is exercised for real, not grepped. The two structural greps
# that stood here before proved only that a line of source exists: one of them
# stayed green when the defect was reintroduced with different syntax.
_modify_fixture() {
    create_init_config
    create_server_config
    printf '#_Name = %s\n' "$1" >> "$SERVER_CONF_FILE"
    cat > "$AWG_DIR/${1}.conf" <<CONF
[Interface]
PrivateKey = TESTCLIENTPRIVKEY
Address = 10.9.9.2/32
DNS = 1.1.1.1, 1.0.0.1
MTU = 1280

[Peer]
PublicKey = TESTSERVERPUBKEY_PLACEHOLDER
Endpoint = 1.2.3.4:39743
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 33
CONF
}

_load_modify() {
    # Тело modify_client берём из RU-скрипта, вместе с его зависимостями.
    local body
    body=$(awk '/^modify_client\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh")
    eval "$body"
}

@test "D#38: modify writes the canonical separator even when typed without spaces" {
    require_flock
    _modify_fixture "mod1"
    _load_modify
    escape_sed() { printf '%s' "$1" | sed 's/[&\\/]/\\&/g'; }
    apply_config() { return 0; }

    run modify_client "mod1" "AllowedIPs" "10.0.0.0/8,192.168.0.0/16"
    [ "$status" -eq 0 ]
    grep -q '^AllowedIPs = 10\.0\.0\.0/8, 192\.168\.0\.0/16$' "$AWG_DIR/mod1.conf"
}

@test "D#38: modify refuses and keeps the backup when the normalizer is missing" {
    require_flock
    _modify_fixture "mod2"
    _load_modify
    escape_sed() { printf '%s' "$1" | sed 's/[&\\/]/\\&/g'; }
    apply_config() { return 0; }
    # Version skew: fresh manage next to an old awg_common.sh without the helper.
    unset -f awg_normalize_csv

    run modify_client "mod2" "AllowedIPs" "10.0.0.0/8,192.168.0.0/16"
    [ "$status" -ne 0 ]
    # The old value must survive untouched, and nothing may be blanked out.
    grep -q '^AllowedIPs = 0\.0\.0\.0/0$' "$AWG_DIR/mod2.conf"
    ! grep -qE '^AllowedIPs = *$' "$AWG_DIR/mod2.conf"
}

