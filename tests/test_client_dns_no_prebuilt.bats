#!/usr/bin/env bats
# CLIENT_DNS in awgsetup_cfg.init sets the DNS of NEW client configs, and
# --no-prebuilt makes the ARM path build the module with DKMS instead of
# installing the prebuilt .deb (September 2026 audit, K-01 and T-07).
#
# shellcheck disable=SC2154  # Variables set by sourced scripts at runtime

load test_helper

LIBS=(awg_common.sh awg_common_en.sh)
INSTALLERS=(install_amneziawg.sh install_amneziawg_en.sh)
MANAGERS=(manage_amneziawg.sh manage_amneziawg_en.sh)

_use_lib() {
    # shellcheck source=/dev/null
    source "$BATS_TEST_DIRNAME/../$1"
}

# ---------------------------------------------------------------- DNS list validator

@test "dns list: valid lists pass (both libraries)" {
    for lib in "${LIBS[@]}"; do
        _use_lib "$lib"
        awg_validate_dns_list "1.1.1.1"
        awg_validate_dns_list "1.1.1.1, 1.0.0.1"
        awg_validate_dns_list "10.9.9.1"
        awg_validate_dns_list "2606:4700:4700::1111"
        awg_validate_dns_list "10.9.9.1,2606:4700:4700::1111"
    done
}

@test "dns list: malformed lists are refused (both libraries)" {
    for lib in "${LIBS[@]}"; do
        _use_lib "$lib"
        declare -F awg_validate_dns_list >/dev/null || { echo "$lib: no awg_validate_dns_list" >&2; return 1; }
        for bad in "" "abc" "999.1.1.1" "1.1.1.1," ",1.1.1.1" "1.1.1.1,,8.8.8.8" \
                   "1.1.1.1'" '1.1.1.1"' "dns.google" "1.1.1.1 8.8.8.8"; do
            if awg_validate_dns_list "$bad"; then
                echo "$lib accepted '$bad'" >&2
                return 1
            fi
        done
        if awg_validate_dns_list $'1.1.1.1\n8.8.8.8'; then
            echo "$lib accepted a newline" >&2
            return 1
        fi
    done
}

@test "dns list: a glob is not expanded against files in the current directory (both libraries)" {
    cd "$TEST_DIR"
    touch 1.1.1.1
    for lib in "${LIBS[@]}"; do
        _use_lib "$lib"
        declare -F awg_validate_dns_list >/dev/null || { echo "$lib: no awg_validate_dns_list" >&2; return 1; }
        if awg_validate_dns_list "1.1.1.*"; then
            echo "$lib: '1.1.1.*' matched the file 1.1.1.1 and passed" >&2
            return 1
        fi
    done
}

# ---------------------------------------------------------------- default DNS for new clients

@test "client dns: default without CLIENT_DNS, configured value with it, spacing normalised (both libraries)" {
    for lib in "${LIBS[@]}"; do
        _use_lib "$lib"
        unset CLIENT_DNS
        [ "$(awg_client_dns)" = "1.1.1.1, 1.0.0.1" ]
        CLIENT_DNS="10.9.9.1"
        [ "$(awg_client_dns)" = "10.9.9.1" ]
        CLIENT_DNS=" 10.9.9.1 ,1.1.1.1"
        [ "$(awg_client_dns)" = "10.9.9.1, 1.1.1.1" ]
        unset CLIENT_DNS
    done
}

@test "client dns: an invalid CLIENT_DNS fails loudly instead of falling back (both libraries)" {
    for lib in "${LIBS[@]}"; do
        _use_lib "$lib"
        log_error() { printf 'ERR:%s\n' "$1" >&2; }
        CLIENT_DNS="not-an-ip"
        local out err rc=0
        out=$(awg_client_dns 2>"$TEST_DIR/err") || rc=$?
        err=$(cat "$TEST_DIR/err")
        [ "$rc" -ne 0 ]
        # Nothing on stdout: that is what would land in the config's DNS line.
        [ -z "$out" ] || { echo "$lib: stdout was '$out'" >&2; return 1; }
        # The error names the key, so the user knows what to fix.
        [[ "$err" == *CLIENT_DNS* ]]
        unset CLIENT_DNS
        log_error() { :; }
    done
}

@test "client dns: safe_load_config reads CLIENT_DNS from awgsetup_cfg.init (both libraries)" {
    for lib in "${LIBS[@]}"; do
        _use_lib "$lib"
        unset CLIENT_DNS
        create_init_config
        echo "export CLIENT_DNS='10.9.9.1'" >> "$CONFIG_FILE"
        safe_load_config "$CONFIG_FILE"
        [ "${CLIENT_DNS:-}" = "10.9.9.1" ]
        unset CLIENT_DNS
    done
}

@test "client dns: render_client_config writes CLIENT_DNS into a new client (both libraries)" {
    for lib in "${LIBS[@]}"; do
        _use_lib "$lib"
        create_server_config
        create_init_config
        echo "export CLIENT_DNS='10.9.9.1, 1.1.1.1'" >> "$CONFIG_FILE"
        safe_load_config "$CONFIG_FILE"
        rm -f "$AWG_DIR/dnsc.conf"
        render_client_config "dnsc" "10.9.9.7" "FAKEPRIV" "FAKEPUB" "1.2.3.4" "39743"
        grep -qxF "DNS = 10.9.9.1, 1.1.1.1" "$AWG_DIR/dnsc.conf" \
            || { echo "$lib:"; cat "$AWG_DIR/dnsc.conf"; return 1; } >&2
        unset CLIENT_DNS
    done
}

@test "client dns: without CLIENT_DNS a new client keeps 1.1.1.1, 1.0.0.1 (both libraries)" {
    for lib in "${LIBS[@]}"; do
        _use_lib "$lib"
        unset CLIENT_DNS
        create_server_config
        create_init_config
        safe_load_config "$CONFIG_FILE"
        rm -f "$AWG_DIR/dnsd.conf"
        render_client_config "dnsd" "10.9.9.8" "FAKEPRIV" "FAKEPUB" "1.2.3.4" "39743"
        grep -qxF "DNS = 1.1.1.1, 1.0.0.1" "$AWG_DIR/dnsd.conf"
    done
}

@test "client dns: an invalid CLIENT_DNS stops render_client_config, no config is written (both libraries)" {
    for lib in "${LIBS[@]}"; do
        _use_lib "$lib"
        create_server_config
        create_init_config
        echo "export CLIENT_DNS='bogus'" >> "$CONFIG_FILE"
        safe_load_config "$CONFIG_FILE"
        rm -f "$AWG_DIR/dnsx.conf"
        run render_client_config "dnsx" "10.9.9.9" "FAKEPRIV" "FAKEPUB" "1.2.3.4" "39743"
        [ "$status" -ne 0 ]
        [ ! -e "$AWG_DIR/dnsx.conf" ]
        unset CLIENT_DNS
    done
}

@test "client dns: manage modify DNS uses the shared validator, the inline glob-prone loop is gone (both languages)" {
    for m in "${MANAGERS[@]}"; do
        grep -q 'awg_validate_dns_list "\$value"' "$BATS_TEST_DIRNAME/../$m" \
            || { echo "$m: modify DNS does not call awg_validate_dns_list" >&2; return 1; }
        if grep -qE 'for _dns_tok in \$value' "$BATS_TEST_DIRNAME/../$m"; then
            echo "$m: inline DNS loop still there" >&2
            return 1
        fi
    done
}

@test "client dns: the installer keeps CLIENT_DNS across a rewrite of awgsetup_cfg.init (both languages)" {
    for f in "${INSTALLERS[@]}"; do
        # Read back by the installer's own loader ...
        sed -n '/^safe_load_config() {$/,/^}$/p' "$BATS_TEST_DIRNAME/../$f" | grep -q 'CLIENT_DNS' \
            || { echo "$f: CLIENT_DNS not in the loader whitelist" >&2; return 1; }
        # ... and written back when the file is regenerated.
        grep -qF "export CLIENT_DNS='\${CLIENT_DNS:-}'" "$BATS_TEST_DIRNAME/../$f" \
            || { echo "$f: CLIENT_DNS not written to awgsetup_cfg.init" >&2; return 1; }
    done
}

# ---------------------------------------------------------------- --no-prebuilt

@test "no-prebuilt: flag parsed, shown in help, persisted and read back (both languages)" {
    for f in "${INSTALLERS[@]}"; do
        local p="$BATS_TEST_DIRNAME/../$f"
        grep -qE '^[[:space:]]+--no-prebuilt\)[[:space:]]+NO_PREBUILT=1; CLI_NO_PREBUILT=1 ;;' "$p" \
            || { echo "$f: --no-prebuilt not parsed" >&2; return 1; }
        grep -qE '^[[:space:]]+--no-prebuilt[[:space:]]' "$p" \
            || { echo "$f: --no-prebuilt missing from help" >&2; return 1; }
        sed -n '/^safe_load_config() {$/,/^}$/p' "$p" | grep -q 'NO_PREBUILT' \
            || { echo "$f: NO_PREBUILT not in the loader whitelist" >&2; return 1; }
        grep -qF 'export NO_PREBUILT=${NO_PREBUILT:-0}' "$p" \
            || { echo "$f: NO_PREBUILT not written to awgsetup_cfg.init" >&2; return 1; }
    done
}

@test "no-prebuilt: help exits 0 and lists the flag (both languages)" {
    for f in "${INSTALLERS[@]}"; do
        run bash "$BATS_TEST_DIRNAME/../$f" --help
        [ "$status" -eq 0 ]
        [[ "$output" == *"--no-prebuilt"* ]] || { echo "$f: help output lacks --no-prebuilt" >&2; return 1; }
    done
}

@test "no-prebuilt: step 2 skips the prebuilt package when NO_PREBUILT=1 (both languages)" {
    for f in "${INSTALLERS[@]}"; do
        # The gate must sit right in front of the prebuilt attempt, in the same
        # if-chain, so a set flag can never reach _try_install_prebuilt_arm.
        body=$(sed -n '/^step2_install_amnezia() {$/,/^}$/p' "$BATS_TEST_DIRNAME/../$f")
        echo "$body" | grep -qE 'if \[\[ "\$\{NO_PREBUILT:-0\}" -eq 1 \]\]; then' \
            || { echo "$f: no NO_PREBUILT gate in step2" >&2; return 1; }
        echo "$body" | grep -qE '^[[:space:]]+elif _try_install_prebuilt_arm; then' \
            || { echo "$f: prebuilt attempt is not the elif of the gate" >&2; return 1; }
    done
}

# ---------------------------------------------------------------- regen and CLIENT_DNS

_make_server_conf_with_peer() {
    local name="$1" ipv4="$2"
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

[Peer]
#_Name = ${name}
PublicKey = TESTPUBKEY
AllowedIPs = ${ipv4}/32
EOF
}

mock_awg() {
    # shellcheck disable=SC2317
    awg() {
        case "$1" in
            genkey)  echo "STUB_PRIVATE_KEY_32B_BASE64VAL==" ;;
            pubkey)  local _pk; _pk=$(cat); echo "pub_${_pk:0:20}" ;;
            genpsk)  echo "GENERATED_PSK_VALUE_32B==" ;;
            set|syncconf|show) return 0 ;;
            *)       command awg "$@" 2>/dev/null || return 0 ;;
        esac
    }
    export -f awg
}

_setup_regen_stubs() {
    mock_awg
    mkdir -p "$KEYS_DIR"
    echo "SERVER_PUB" > "$AWG_DIR/server_public.key"
    # shellcheck disable=SC2317
    get_server_public_ip() { echo "203.0.113.1"; return 0; }
    # shellcheck disable=SC2317
    _ensure_server_public_key() { return 0; }
    # shellcheck disable=SC2317
    generate_qr() { return 0; }
    # shellcheck disable=SC2317
    generate_vpn_uri() { return 0; }
    # shellcheck disable=SC2317
    generate_qr_vpnuri() { return 0; }
    export -f get_server_public_ip _ensure_server_public_key generate_qr \
        generate_vpn_uri generate_qr_vpnuri
}

@test "client dns: regen restoring a lost client config keeps CLIENT_DNS (both libraries)" {
    require_flock
    for lib in "${LIBS[@]}"; do
        _use_lib "$lib"
        _make_server_conf_with_peer "rita" "10.9.9.2"
        _setup_regen_stubs
        echo "RITA_PRIV" > "$KEYS_DIR/rita.private"
        # No rita.conf: the restore path (the previous iteration moved its file away).
        [ ! -e "$AWG_DIR/rita.conf" ]
        export CLIENT_DNS="10.9.9.1"
        unset AWG_REGEN_RESET_ROUTES
        run regenerate_client "rita"
        [ "$status" -eq 0 ] || { echo "$lib: $output" >&2; return 1; }
        grep -qxF "DNS = 10.9.9.1" "$AWG_DIR/rita.conf" \
            || { echo "$lib:"; grep '^DNS' "$AWG_DIR/rita.conf"; return 1; } >&2
        unset CLIENT_DNS
        mv "$AWG_DIR/rita.conf" "$AWG_DIR/rita.conf.done-$lib"
    done
}

@test "client dns: regen keeps an existing client's own DNS even with CLIENT_DNS set (both libraries)" {
    require_flock
    for lib in "${LIBS[@]}"; do
        _use_lib "$lib"
        _make_server_conf_with_peer "sam" "10.9.9.3"
        _setup_regen_stubs
        echo "SAM_PRIV" > "$KEYS_DIR/sam.private"
        printf '[Interface]\nPrivateKey = SAM_PRIV\nAddress = 10.9.9.3/32\nDNS = 8.8.8.8\nMTU = 1280\nPersistentKeepalive = 33\n[Peer]\nPublicKey = SERVER_PUB\nEndpoint = 203.0.113.1:39743\nAllowedIPs = 0.0.0.0/0\n' \
            > "$AWG_DIR/sam.conf"
        export CLIENT_DNS="10.9.9.1"
        unset AWG_REGEN_RESET_ROUTES
        run regenerate_client "sam"
        [ "$status" -eq 0 ] || { echo "$lib: $output" >&2; return 1; }
        grep -qxF "DNS = 8.8.8.8" "$AWG_DIR/sam.conf" \
            || { echo "$lib:"; grep '^DNS' "$AWG_DIR/sam.conf"; return 1; } >&2
        unset CLIENT_DNS
    done
}
