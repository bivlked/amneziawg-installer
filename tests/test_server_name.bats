#!/usr/bin/env bats
# D#180 - configurable server name in the vpn:// URI.
#
# The outer JSON "description" field is what the Amnezia app shows as the
# server name after a vpn:// import. It used to be hardcoded to "AWG Server"
# and was lost on every config regeneration. Now it comes from
# AWG_SERVER_NAME (awgsetup_cfg.init, --server-name=, interactive question)
# with the old hardcode as the default.
#
# The behavioural tests below decode the generated vpn:// URI back
# (base64url -> zlib -> outer JSON) and assert on the actual description
# value - not on the shape of the code.

load test_helper

require_python3()    { command -v python3 &>/dev/null || skip "python3 not available"; }
require_perl_zlib()  { perl -MCompress::Zlib -MMIME::Base64 -e '1' 2>/dev/null || skip "perl Compress::Zlib/MIME::Base64 not available"; }

# Decode vpn:// URI and print the OUTER JSON "description" field.
decode_outer_description() {
    python3 - "$1" <<'PY'
import base64, zlib, json, struct, sys
uri = sys.argv[1].replace("vpn://", "")
pad = "=" * (-len(uri) % 4)
raw = base64.urlsafe_b64decode(uri + pad)
struct.unpack(">I", raw[:4])[0]
outer = json.loads(zlib.decompress(raw[4:]))
print(outer["description"])
PY
}

setup_vpn_uri_fixture() {
    create_init_config
    create_server_config
    echo "TESTSERVERPUBKEY_PLACEHOLDER" > "$AWG_DIR/server_public.key"
}

make_client_conf() {
    local name="$1"
    cat > "$AWG_DIR/${name}.conf" <<CONF
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

# ---------------------------------------------------------------------------
# Behavioural: the name actually lands in the decoded URI
# ---------------------------------------------------------------------------

@test "D#180 functional: custom AWG_SERVER_NAME lands in vpn:// description (cyrillic ok)" {
    require_python3
    require_perl_zlib
    setup_vpn_uri_fixture
    make_client_conf "named"
    export AWG_SERVER_NAME="Мой сервер"

    run generate_vpn_uri "named"
    [ "$status" -eq 0 ]

    local desc
    desc=$(decode_outer_description "$(cat "$AWG_DIR/named.vpnuri")")
    [ "$desc" = "Мой сервер" ]
}

@test "D#180 functional: unset AWG_SERVER_NAME falls back to 'AWG Server' (legacy behaviour)" {
    require_python3
    require_perl_zlib
    setup_vpn_uri_fixture
    make_client_conf "legacy"
    unset AWG_SERVER_NAME

    run generate_vpn_uri "legacy"
    [ "$status" -eq 0 ]

    local desc
    desc=$(decode_outer_description "$(cat "$AWG_DIR/legacy.vpnuri")")
    [ "$desc" = "AWG Server" ]
}

# ---------------------------------------------------------------------------
# validate_server_name (RU/EN identical bodies)
# ---------------------------------------------------------------------------

@test "D#180 functional: validate_server_name accepts sane names, rejects dangerous ones" {
    fn=$(awk '/^validate_server_name\(\)/,/^}/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    [ -n "$fn" ]
    run bash -c "$fn"'
        ok()  { validate_server_name "$1" && echo "ok:$2"; }
        bad() { validate_server_name "$1" || echo "bad:$2"; }
        ok  "AWG Server"        plain
        ok  "Мой сервер"        cyrillic
        ok  "domen.com"         domain
        ok  "vpn-01_home"       symbols
        # 64 cyrillic chars = 128 UTF-8 bytes: must fit regardless of locale
        ok  "$(python3 -c "print(chr(1103)*64)")" cyr64
        bad ""                  empty
        bad "$(printf "a%.0s" {1..129})" toolong
        bad "has'\''quote"          squote
        bad "has\"dquote"       dquote
        bad "has\\back"         backslash
        bad "$(printf "a\tb")"  tab
        bad "$(printf "a\nb")"  newline
        # ESC from arrow keys in interactive input would break the URI JSON
        bad "$(printf "a\033[Db")" esc
        bad " leading"          leadspace
        bad "trailing "         trailspace
    '
    [ "$status" -eq 0 ]
    for tag in ok:plain ok:cyrillic ok:domain ok:symbols ok:cyr64 \
               bad:empty bad:toolong bad:squote bad:dquote bad:backslash \
               bad:tab bad:newline bad:esc bad:leadspace bad:trailspace; do
        [[ "$output" == *"$tag"* ]]
    done
}

@test "D#180 functional: configure_server_name trims accidental surrounding whitespace" {
    fns=$(awk '/^validate_server_name\(\)/,/^}/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
          awk '/^_trim_ws\(\)/,/^}/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
          awk '/^configure_server_name\(\)/,/^}/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    [ -n "$fns" ]
    run bash -c '
        log() { :; }; log_warn() { :; }; die() { echo "DIE"; exit 1; }
        CONFIG_FILE=/dev/null
        '"$fns"'
        CLI_SERVER_NAME="  My VPN  " AWG_SERVER_NAME="" AUTO_YES=1 config_exists=0
        configure_server_name; echo "cli:[$AWG_SERVER_NAME]"
        # whitespace-only config value -> trimmed to empty -> invalid -> default
        CLI_SERVER_NAME="" AWG_SERVER_NAME="   " AUTO_YES=1 config_exists=1
        configure_server_name; echo "blank:[$AWG_SERVER_NAME]"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *'cli:[My VPN]'* ]]
    [[ "$output" == *'blank:[AWG Server]'* ]]
}

@test "D#180: RU/EN validate_server_name bodies are identical" {
    ru=$(awk '/^validate_server_name\(\)/,/^}/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    en=$(awk '/^validate_server_name\(\)/,/^}/' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh")
    [ -n "$ru" ]
    [ "$ru" = "$en" ]
}

# ---------------------------------------------------------------------------
# configure_server_name: source priority
# ---------------------------------------------------------------------------

@test "D#180 functional: configure_server_name priority CLI > config > default" {
    fns=$(awk '/^validate_server_name\(\)/,/^}/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
          awk '/^_trim_ws\(\)/,/^}/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
          awk '/^configure_server_name\(\)/,/^}/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    [ -n "$fns" ]
    run bash -c '
        log() { :; }; log_warn() { :; }; die() { echo "DIE"; exit 1; }
        CONFIG_FILE=/dev/null
        '"$fns"'
        CLI_SERVER_NAME="From CLI" AWG_SERVER_NAME="From Config" AUTO_YES=0 config_exists=1
        configure_server_name; echo "cli:$AWG_SERVER_NAME"
        CLI_SERVER_NAME="" AWG_SERVER_NAME="From Config"
        configure_server_name; echo "cfg:$AWG_SERVER_NAME"
        CLI_SERVER_NAME="" AWG_SERVER_NAME="" AUTO_YES=1 config_exists=0
        configure_server_name; echo "yes:$AWG_SERVER_NAME"
        CLI_SERVER_NAME="" AWG_SERVER_NAME="" AUTO_YES=0 config_exists=1
        configure_server_name; echo "legacy:$AWG_SERVER_NAME"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *'cli:From CLI'* ]]
    [[ "$output" == *'cfg:From Config'* ]]
    [[ "$output" == *'yes:AWG Server'* ]]
    [[ "$output" == *'legacy:AWG Server'* ]]
}

@test "D#180 functional: configure_server_name dies on invalid CLI, sanitizes invalid config value" {
    fns=$(awk '/^validate_server_name\(\)/,/^}/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
          awk '/^_trim_ws\(\)/,/^}/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
          awk '/^configure_server_name\(\)/,/^}/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    [ -n "$fns" ]
    run bash -c '
        log() { :; }; log_warn() { echo "WARN"; }; die() { echo "DIE:$*"; exit 1; }
        CONFIG_FILE=/dev/null
        '"$fns"'
        # invalid value loaded from a hand-edited config -> warn + default
        CLI_SERVER_NAME="" AWG_SERVER_NAME="bad\"name" AUTO_YES=1 config_exists=1
        configure_server_name; echo "cfgbad:$AWG_SERVER_NAME"
        # invalid CLI -> die
        CLI_SERVER_NAME="bad\"name" configure_server_name
        echo "unreachable"
    '
    [[ "$output" == *'WARN'* ]]
    [[ "$output" == *'cfgbad:AWG Server'* ]]
    [[ "$output" == *'DIE:'* ]]
    [[ "$output" != *'unreachable'* ]]
}

# ---------------------------------------------------------------------------
# Wiring: CLI parser, help, persistence, whitelist, change warning
# ---------------------------------------------------------------------------

@test "D#180: RU/EN installer parses --server-name= into CLI_SERVER_NAME" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run grep -F -- '--server-name=*)' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ]
        [[ "$output" == *'CLI_SERVER_NAME='* ]]
    done
}

@test "D#180: RU/EN help mentions --server-name" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run grep -c -- '--server-name=' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ]
        [ "$output" -ge 2 ]   # parser + help
    done
}

@test "D#180: RU/EN installer persists AWG_SERVER_NAME into awgsetup_cfg.init with default" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run grep -F "export AWG_SERVER_NAME='\${AWG_SERVER_NAME:-AWG Server}'" "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ]
    done
}

@test "D#180: AWG_SERVER_NAME whitelisted in safe_load_config (all four copies)" {
    for f in awg_common.sh awg_common_en.sh install_amneziawg.sh install_amneziawg_en.sh; do
        # The key may be the last in the whitelist or be followed by another one
        # (CLIENT_DNS joined after it in Sep 2026).
        run grep -cE '\|AWG_SERVER_NAME(\||\))' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ]
        [ "$output" -ge 1 ]
    done
}

@test "D#180: RU/EN installer resets AWG_SERVER_NAME before config load (no env inheritance)" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run grep -F 'AWG_SERVER_NAME=""' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ]
    done
}

@test "D#180: RU/EN installer warns about regen on server-name change" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run grep -c '_cfg_server_name' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ]
        [ "$output" -ge 2 ]   # capture + comparison
    done
    # Legacy config (no key) must be captured as the old hardcode, not empty.
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run grep -F '_cfg_server_name="${AWG_SERVER_NAME:-AWG Server}"' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ]
    done
}

@test "D#180: hardcoded description is gone from generate_vpn_uri (RU/EN)" {
    for f in awg_common.sh awg_common_en.sh; do
        run grep -F '"description":"AWG Server"' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -ne 0 ]
        # the field is fed through the je() JSON escaper instead
        block=$(awk '/^generate_vpn_uri\(\)/,/^}/' "$BATS_TEST_DIRNAME/../$f")
        [[ "$block" == *'je($srvname)'* ]]
        [[ "$block" == *'${AWG_SERVER_NAME:-AWG Server}'* ]]
    done
}
