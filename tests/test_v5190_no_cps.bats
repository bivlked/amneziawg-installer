#!/usr/bin/env bats
# v5.19.0 - --no-cps drops the I1/CPS parameter (issue #159).
#
# The desktop AmneziaVPN on macOS does not support the I1 CPS layer and hangs on
# connect; mobile and CLI clients handle it. --no-cps clears AWG_I1 so the server
# config omits the `I1 = ` line, and everything derived from it follows. These
# tests assert the vpn:// URI (the path AmneziaVPN imports) mirrors the server
# config: an `I1 = ` line surfaces as "I1" in the inner JSON, its absence (the
# --no-cps result) is omitted. generate_vpn_uri reads params from the live server
# config, so the server config is the source of truth here.
# shellcheck disable=SC2154

load test_helper

require_python3()   { command -v python3 &>/dev/null || skip "python3 not available"; }
require_perl_zlib() { perl -MCompress::Zlib -MMIME::Base64 -e '1' 2>/dev/null || skip "perl Compress::Zlib/MIME::Base64 not available"; }

# Decode vpn://<base64url(uint32_BE(len) + zlib(outer_json))> -> inner JSON string.
decode_vpn_uri() {
    python3 - "$1" <<'PY'
import base64, zlib, json, struct, sys
uri = sys.argv[1].replace("vpn://", "")
pad = "=" * (-len(uri) % 4)
raw = base64.urlsafe_b64decode(uri + pad)
struct.unpack(">I", raw[:4])[0]
outer = json.loads(zlib.decompress(raw[4:]))
print(outer["containers"][0]["awg"]["last_config"])
PY
}

make_client_conf() {
    cat > "$AWG_DIR/${1}.conf" <<CONF
[Interface]
PrivateKey = TESTCLIENTPRIVKEY
Address = 10.9.9.2/32
DNS = 1.1.1.1, 1.0.0.1

[Peer]
PublicKey = TESTSERVERPUBKEY_PLACEHOLDER
Endpoint = 1.2.3.4:39743
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 33
CONF
}

@test "v5.19.0 no-cps: vpn:// URI includes I1 when the server config has an I1 line (CPS on)" {
    require_python3
    require_perl_zlib
    create_init_config
    create_server_config
    echo "I1 = <r 155>" >> "$SERVER_CONF_FILE"
    echo "TESTSERVERPUBKEY_PLACEHOLDER" > "$AWG_DIR/server_public.key"
    make_client_conf "cpson"

    run generate_vpn_uri "cpson"
    [ "$status" -eq 0 ]
    local inner
    inner=$(decode_vpn_uri "$(cat "$AWG_DIR/cpson.vpnuri")")
    [[ "$inner" == *'"I1":"<r 155>"'* ]]
}

@test "v5.19.0 no-cps: vpn:// URI omits I1 when the server config has no I1 line (--no-cps result)" {
    require_python3
    require_perl_zlib
    create_init_config
    create_server_config
    echo "TESTSERVERPUBKEY_PLACEHOLDER" > "$AWG_DIR/server_public.key"
    make_client_conf "cpsoff"

    run generate_vpn_uri "cpsoff"
    [ "$status" -eq 0 ]
    local inner
    inner=$(decode_vpn_uri "$(cat "$AWG_DIR/cpsoff.vpnuri")")
    [[ "$inner" != *'"I1"'* ]]
    # Positive anchor: a degenerate empty inner config must not satisfy the test.
    [[ "$inner" == *'"Jc"'* ]]
}

# Behavioral reinstall pin: the whole point of the render-side re-clear is
# ORDERING - load_awg_params re-reads I1 from the live awg0.conf, and only
# after that the NO_CPS=1 init state clears it. These tests run the real
# render_server_config over a live CPS conf, so moving the clear before
# load_awg_params (silently restoring I1 on reinstall) fails the first test.
render_reinstall_fixture() {
    create_init_config
    create_server_config
    echo "I1 = <r 155>" >> "$SERVER_CONF_FILE"   # old install's CPS
    echo "I2 = <t>" >> "$SERVER_CONF_FILE"       # admin-set I2 must survive
    echo "PRIVKEYPLACEHOLDER" > "$AWG_DIR/server_private.key"
    get_main_nic() { echo eth0; }
    host_lacks_ipv4_egress() { return 1; }
}

@test "v5.19.0 no-cps: reinstall render drops live I1 when init has NO_CPS=1 (keeps Jc, I2)" {
    render_reinstall_fixture
    echo "export NO_CPS=1" >> "$CONFIG_FILE"
    run render_server_config
    [ "$status" -eq 0 ]
    # Счётная форма вместо "! grep": в Bats голый ! не валит тест (SC2314).
    [ "$(grep -cE '^[[:space:]]*I1[[:space:]]*=' "$SERVER_CONF_FILE")" -eq 0 ]
    grep -q '^Jc = ' "$SERVER_CONF_FILE"
    grep -q '^I2 = <t>' "$SERVER_CONF_FILE"
}

@test "v5.19.0 no-cps: reinstall render keeps live I1 when NO_CPS is not set" {
    render_reinstall_fixture
    run render_server_config
    [ "$status" -eq 0 ]
    grep -q '^I1 = <r 155>' "$SERVER_CONF_FILE"
}

@test "v5.19.0 no-cps: render_server_config honors NO_CPS (clears I1) in RU and EN" {
    for f in awg_common.sh awg_common_en.sh; do
        local block
        block=$(awk '/^render_server_config\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../$f")
        echo "$block" | grep -q 'NO_CPS=1' || { echo "no NO_CPS check in $f"; false; }
        echo "$block" | grep -q "AWG_I1=''" || { echo "no I1 clear in $f"; false; }
    done
}

@test "v5.19.0 no-cps: installer parses --no-cps and persists NO_CPS (RU + EN)" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        grep -qE '\-\-no-cps\).*NO_CPS=1; CLI_NO_CPS=1' "$BATS_TEST_DIRNAME/../$f" || { echo "no --no-cps parse in $f"; false; }
        grep -qE 'export NO_CPS=\$\{NO_CPS\}' "$BATS_TEST_DIRNAME/../$f" || { echo "no NO_CPS persist in $f"; false; }
    done
}

@test "v5.19.0 no-cps: NO_CPS is in the safe_load_config whitelist (RU + EN)" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        grep -q 'NO_TWEAKS|NO_CPS' "$BATS_TEST_DIRNAME/../$f" || { echo "NO_CPS not whitelisted in $f"; false; }
    done
}
