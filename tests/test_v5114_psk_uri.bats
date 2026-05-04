#!/usr/bin/env bats
# v5.11.4 vpn:// URI psk_key field — issue #67 regression test.
#
# Bug fixed: generate_vpn_uri did not include the psk_key field in the
# inner JSON awg block. AmneziaVPN imports vpn:// via that inner JSON,
# and without psk_key it silently brings the connection up without the
# preshared key — server (which has the PSK) then rejects the handshake.
#
# These tests decode the resulting vpn:// URI, parse the outer + inner
# JSON, and assert psk_key presence/absence matches the source .conf.

load test_helper

require_python3()    { command -v python3 &>/dev/null || skip "python3 not available"; }
require_perl_zlib()  { perl -MCompress::Zlib -MMIME::Base64 -e '1' 2>/dev/null || skip "perl Compress::Zlib/MIME::Base64 not available"; }

# Decode vpn:// URI -> outer JSON -> inner JSON STRING (as produced by perl).
# Prints the raw inner JSON string on stdout, preserving perl's compact format
# so substring assertions like *"key":"value"* work without spurious spaces.
# Format: vpn://<base64url(uint32_BE(uncompressed_len) + zlib(outer_json))>
decode_vpn_uri() {
    python3 - "$1" <<'PY'
import base64, zlib, json, struct, sys
uri = sys.argv[1].replace("vpn://", "")
pad = "=" * (-len(uri) % 4)
raw = base64.urlsafe_b64decode(uri + pad)
# Skip 4-byte BE length prefix, decompress remainder.
struct.unpack(">I", raw[:4])[0]
outer = json.loads(zlib.decompress(raw[4:]))
# Print the raw inner JSON string verbatim — do NOT re-serialize, json.dumps
# would normalize spacing and break compact substring assertions.
print(outer["containers"][0]["awg"]["last_config"])
PY
}

setup_vpn_uri_fixture() {
    create_init_config
    create_server_config
    # _ensure_server_public_key returns 0 immediately if file already exists,
    # so the awg pubkey roundtrip is skipped on Windows/CI without awg binary.
    echo "TESTSERVERPUBKEY_PLACEHOLDER" > "$AWG_DIR/server_public.key"
}

# Render a minimal client .conf in $AWG_DIR/<name>.conf.
make_client_conf() {
    local name="$1" psk="${2:-}"
    local conf="$AWG_DIR/${name}.conf"
    cat > "$conf" <<CONF
[Interface]
PrivateKey = TESTCLIENTPRIVKEY
Address = 10.9.9.2/32
DNS = 1.1.1.1, 1.0.0.1

[Peer]
PublicKey = TESTSERVERPUBKEY_PLACEHOLDER
CONF
    if [[ -n "$psk" ]]; then
        echo "PresharedKey = $psk" >> "$conf"
    fi
    cat >> "$conf" <<CONF
Endpoint = 1.2.3.4:39743
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 33
CONF
}

@test "v5.11.4 psk_key: vpn:// URI inner JSON contains psk_key when PresharedKey present in .conf" {
    require_python3
    require_perl_zlib
    setup_vpn_uri_fixture
    local psk="FAKEPSKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    make_client_conf "withpsk" "$psk"

    run generate_vpn_uri "withpsk"
    [ "$status" -eq 0 ]
    [ -f "$AWG_DIR/withpsk.vpnuri" ]

    local uri inner
    uri=$(cat "$AWG_DIR/withpsk.vpnuri")
    inner=$(decode_vpn_uri "$uri")
    # psk_key field must be present and equal to the .conf PSK.
    [[ "$inner" == *"\"psk_key\":\"${psk}\""* ]]
}

@test "v5.11.4 psk_key: vpn:// URI inner JSON omits psk_key when no PresharedKey in .conf" {
    require_python3
    require_perl_zlib
    setup_vpn_uri_fixture
    make_client_conf "nopsk"

    run generate_vpn_uri "nopsk"
    [ "$status" -eq 0 ]
    [ -f "$AWG_DIR/nopsk.vpnuri" ]

    local uri inner
    uri=$(cat "$AWG_DIR/nopsk.vpnuri")
    inner=$(decode_vpn_uri "$uri")
    # psk_key field must NOT appear in inner JSON for non-PSK clients.
    [[ "$inner" != *"psk_key"* ]]
}

@test "v5.11.4 psk_key: indented PresharedKey is still extracted (defensive)" {
    require_python3
    require_perl_zlib
    setup_vpn_uri_fixture
    local psk="INDENTPSKBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="
    local conf="$AWG_DIR/indent.conf"
    cat > "$conf" <<CONF
[Interface]
PrivateKey = TESTCLIENTPRIVKEY
Address = 10.9.9.2/32

[Peer]
PublicKey = TESTSERVERPUBKEY_PLACEHOLDER
    PresharedKey = ${psk}
Endpoint = 1.2.3.4:39743
AllowedIPs = 0.0.0.0/0
CONF

    run generate_vpn_uri "indent"
    [ "$status" -eq 0 ]

    local inner
    inner=$(decode_vpn_uri "$(cat "$AWG_DIR/indent.vpnuri")")
    [[ "$inner" == *"\"psk_key\":\"${psk}\""* ]]
}

@test "v5.11.4 psk_key: CRLF line endings do not leak \\r into psk_key value" {
    # Windows-edited client conf often arrives with CRLF. Without explicit
    # CR strip, the trailing \r ends up inside psk_key, AmneziaVPN treats
    # the value as a different key, and the handshake silently fails the
    # same way as the original missing-field bug.
    require_python3
    require_perl_zlib
    setup_vpn_uri_fixture
    local psk="CRLFPSKCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC="
    local conf="$AWG_DIR/crlf.conf"
    # Build a CRLF-terminated config explicitly.
    {
        printf '[Interface]\r\n'
        printf 'PrivateKey = TESTCLIENTPRIVKEY\r\n'
        printf 'Address = 10.9.9.2/32\r\n'
        printf '\r\n'
        printf '[Peer]\r\n'
        printf 'PublicKey = TESTSERVERPUBKEY_PLACEHOLDER\r\n'
        printf 'PresharedKey = %s\r\n' "$psk"
        printf 'Endpoint = 1.2.3.4:39743\r\n'
        printf 'AllowedIPs = 0.0.0.0/0\r\n'
    } > "$conf"

    run generate_vpn_uri "crlf"
    [ "$status" -eq 0 ]

    # Use Python to parse strictly: psk_key value must equal $psk exactly,
    # without any trailing \r or whitespace.
    local got
    got=$(python3 - "$AWG_DIR/crlf.vpnuri" <<'PY'
import base64, json, struct, sys, zlib
uri = open(sys.argv[1]).read().strip().replace("vpn://", "")
pad = "=" * (-len(uri) % 4)
raw = base64.urlsafe_b64decode(uri + pad)
struct.unpack(">I", raw[:4])[0]
outer = json.loads(zlib.decompress(raw[4:]))
inner = json.loads(outer["containers"][0]["awg"]["last_config"])
print(repr(inner.get("psk_key", "")))
PY
)
    [ "$got" = "'${psk}'" ]
}

@test "v5.11.4 psk_key: empty 'PresharedKey =' value is not emitted as psk_key" {
    # Defensive: a stray line "PresharedKey =" with no value must not
    # produce psk_key:"" in the inner JSON — that would still mismatch
    # a server that has a real PSK and is not what the user intended.
    require_python3
    require_perl_zlib
    setup_vpn_uri_fixture
    local conf="$AWG_DIR/emptypsk.conf"
    cat > "$conf" <<'CONF'
[Interface]
PrivateKey = TESTCLIENTPRIVKEY
Address = 10.9.9.2/32

[Peer]
PublicKey = TESTSERVERPUBKEY_PLACEHOLDER
PresharedKey =
Endpoint = 1.2.3.4:39743
AllowedIPs = 0.0.0.0/0
CONF

    run generate_vpn_uri "emptypsk"
    [ "$status" -eq 0 ]

    local inner
    inner=$(decode_vpn_uri "$(cat "$AWG_DIR/emptypsk.vpnuri")")
    [[ "$inner" != *"psk_key"* ]]
}
