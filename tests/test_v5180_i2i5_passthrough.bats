#!/usr/bin/env bats
# v5.18.0 - issue #71: pass-through of special-junk params I2-I5 from awg0.conf
# into client configs (.conf + vpn:// URI).
#
# Before this release only I1 reached clients; I2-I5 were hard-coded empty in
# the vpn:// JSON and never rendered into the client .conf, so even if the admin
# set them in awg0.conf they were physically undeliverable. These tests cover:
#   - parser (load_awg_params_from_server_conf) picking up I2-I5
#   - anti-stale unset across load_awg_params calls
#   - client .conf render (render_client_config) emitting/omitting I2-I5
#   - vpn:// last_config carrying I2-I5 in BOTH the structured fields and the
#     embedded raw config (belt-and-suspenders delivery)
#   - RU/EN parity of every touched site
# shellcheck disable=SC2154  # Variables set by sourced scripts at runtime

load test_helper

require_python3()   { command -v python3 &>/dev/null || skip "python3 not available"; }
require_perl_zlib() { perl -MCompress::Zlib -MMIME::Base64 -e '1' 2>/dev/null || skip "perl Compress::Zlib/MIME::Base64 not available"; }

# Minimal complete server config with all four I2-I5 special-junk params set.
# Values exercise the real AWG 2.0 tag formats: byte-hex, counter, random,
# timestamp - including a space and a 0x hex literal inside the value.
create_server_config_with_i() {
    cat > "$SERVER_CONF_FILE" << 'CONF'
[Interface]
PrivateKey = TESTKEY
Address = 10.9.9.1/24
MTU = 1280
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
I1 = <r 100>
I2 = <b 0xf1>
I3 = <c>
I4 = <r 64>
I5 = <t>
CONF
}

# Decode vpn:// URI -> inner last_config JSON string (perl-compact format,
# preserved verbatim so compact substring assertions work). Mirrors the helper
# in test_v5114_psk_uri.bats.
decode_vpn_inner() {
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

# --- Parser ---

@test "v5.18 i2i5: load_awg_params_from_server_conf parses I2-I5" {
    create_server_config_with_i
    load_awg_params_from_server_conf "$SERVER_CONF_FILE"
    [ "$AWG_I1" = "<r 100>" ]
    [ "$AWG_I2" = "<b 0xf1>" ]
    [ "$AWG_I3" = "<c>" ]
    [ "$AWG_I4" = "<r 64>" ]
    [ "$AWG_I5" = "<t>" ]
}

@test "v5.18 i2i5: I2-I5 are optional (config without them still loads, vars empty)" {
    create_server_config
    run load_awg_params_from_server_conf "$SERVER_CONF_FILE"
    [ "$status" -eq 0 ]
    [ -z "${AWG_I2:-}" ]
    [ -z "${AWG_I3:-}" ]
    [ -z "${AWG_I4:-}" ]
    [ -z "${AWG_I5:-}" ]
}

@test "v5.18 i2i5: anti-stale - I2-I5 do not leak across load_awg_params calls" {
    create_server_config_with_i
    load_awg_params
    [ "$AWG_I2" = "<b 0xf1>" ]
    # Reload from a config that has no I-params: the optional vars must clear.
    create_server_config
    load_awg_params
    [ -z "${AWG_I2:-}" ]
    [ -z "${AWG_I5:-}" ]
    # Sanity: mandatory params still load fine.
    [ "$AWG_Jc" = "6" ]
}

# --- Client .conf render ---

@test "v5.18 i2i5: render_client_config writes I2-I5 into client .conf" {
    create_server_config_with_i
    render_client_config "c1" "10.9.9.2" "CLIENTPRIV" "SERVERPUB" "1.2.3.4" "39743"
    local conf="$AWG_DIR/c1.conf"
    [ -f "$conf" ]
    grep -qFx "I1 = <r 100>" "$conf"
    grep -qFx "I2 = <b 0xf1>" "$conf"
    grep -qFx "I3 = <c>" "$conf"
    grep -qFx "I4 = <r 64>" "$conf"
    grep -qFx "I5 = <t>" "$conf"
}

@test "v5.18 i2i5: render_client_config omits I2-I5 when server conf has none" {
    create_server_config
    render_client_config "c2" "10.9.9.3" "CLIENTPRIV" "SERVERPUB" "1.2.3.4" "39743"
    local conf="$AWG_DIR/c2.conf"
    [ -f "$conf" ]
    # None of I2-I5 should appear in the rendered client config.
    run grep -E '^I[2-5] = ' "$conf"
    [ "$status" -ne 0 ]
}

# --- vpn:// URI (structured fields + embedded raw config) ---

@test "v5.18 i2i5: vpn:// last_config carries I2-I5 (structured + raw config)" {
    require_python3
    require_perl_zlib
    create_server_config_with_i
    echo "TESTSERVERPUBKEY_PLACEHOLDER" > "$AWG_DIR/server_public.key"
    render_client_config "c3" "10.9.9.4" "TESTCLIENTPRIVKEY" "TESTSERVERPUBKEY_PLACEHOLDER" "1.2.3.4" "39743"

    run generate_vpn_uri "c3"
    [ "$status" -eq 0 ]
    [ -f "$AWG_DIR/c3.vpnuri" ]

    local inner
    inner=$(decode_vpn_inner "$(cat "$AWG_DIR/c3.vpnuri")")
    # Structured fields now hold real values (not the old hard-coded empties).
    [[ "$inner" == *'"I2":"<b 0xf1>"'* ]]
    [[ "$inner" == *'"I5":"<t>"'* ]]
    # The embedded raw config also carries them (the other delivery path).
    [[ "$inner" == *'I2 = <b 0xf1>'* ]]
    [[ "$inner" == *'I5 = <t>'* ]]
}

@test "v5.18 i2i5: vpn:// omits I2-I5 structured fields when none set" {
    require_python3
    require_perl_zlib
    create_server_config
    echo "TESTSERVERPUBKEY_PLACEHOLDER" > "$AWG_DIR/server_public.key"
    render_client_config "c4" "10.9.9.5" "TESTCLIENTPRIVKEY" "TESTSERVERPUBKEY_PLACEHOLDER" "1.2.3.4" "39743"

    run generate_vpn_uri "c4"
    [ "$status" -eq 0 ]

    local inner
    inner=$(decode_vpn_inner "$(cat "$AWG_DIR/c4.vpnuri")")
    # No I1 in this config either, so the whole I-block is absent.
    [[ "$inner" != *'"I2"'* ]]
    [[ "$inner" != *'"I5"'* ]]
}

# --- RU/EN parity ---

@test "v5.18 i2i5: RU+EN parser has I2-I5 case branches" {
    local p
    for p in awg_common.sh awg_common_en.sh; do
        grep -qE 'I2\)[[:space:]]+_I2=' "${BATS_TEST_DIRNAME}/../$p"
        grep -qE 'I5\)[[:space:]]+_I5=' "${BATS_TEST_DIRNAME}/../$p"
    done
}

@test "v5.18 i2i5: RU+EN vpn:// perl unpacks i2-i5 and caller passes AWG_I2-I5" {
    local p
    for p in awg_common.sh awg_common_en.sh; do
        grep -q '$i1,$i2,$i3,$i4,$i5' "${BATS_TEST_DIRNAME}/../$p"
        grep -q '"$AWG_I1" "${AWG_I2:-}" "${AWG_I3:-}" "${AWG_I4:-}" "${AWG_I5:-}"' "${BATS_TEST_DIRNAME}/../$p"
    done
}

@test "v5.18 i2i5: RU+EN client render emits I2-I5 echo lines" {
    local p
    for p in awg_common.sh awg_common_en.sh; do
        grep -qF 'echo "I2 = ${AWG_I2}"' "${BATS_TEST_DIRNAME}/../$p"
        grep -qF 'echo "I5 = ${AWG_I5}"' "${BATS_TEST_DIRNAME}/../$p"
    done
}

@test "v5.18 i2i5: RU+EN installers whitelist + persist AWG_I2-I5" {
    local p
    for p in install_amneziawg.sh install_amneziawg_en.sh; do
        grep -qF 'AWG_I2|AWG_I3|AWG_I4|AWG_I5' "${BATS_TEST_DIRNAME}/../$p"
        grep -qF "export AWG_I2='" "${BATS_TEST_DIRNAME}/../$p"
        grep -qF "export AWG_I5='" "${BATS_TEST_DIRNAME}/../$p"
    done
}
