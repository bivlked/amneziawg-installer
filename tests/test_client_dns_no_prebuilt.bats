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
        create_init_config
        echo "export CLIENT_DNS='10.9.9.1'" >> "$CONFIG_FILE"
        unset AWG_REGEN_RESET_ROUTES
        run regenerate_client "rita"
        [ "$status" -eq 0 ] || { echo "$lib: $output" >&2; return 1; }
        grep -qxF "DNS = 10.9.9.1" "$AWG_DIR/rita.conf" \
            || { echo "$lib:"; grep '^DNS' "$AWG_DIR/rita.conf"; return 1; } >&2
        unset CLIENT_DNS
        mv "$AWG_DIR/rita.conf" "$AWG_DIR/rita.conf.done-$lib"
    done
}

@test "client dns: an invalid CLIENT_DNS does not block regen of a client with a live config (both libraries)" {
    require_flock
    for lib in "${LIBS[@]}"; do
        _use_lib "$lib"
        _make_server_conf_with_peer "tom" "10.9.9.4"
        _setup_regen_stubs
        echo "TOM_PRIV" > "$KEYS_DIR/tom.private"
        printf '[Interface]\nPrivateKey = TOM_PRIV\nAddress = 10.9.9.4/32\nDNS = 9.9.9.9\nMTU = 1280\nPersistentKeepalive = 33\n[Peer]\nPublicKey = SERVER_PUB\nEndpoint = 203.0.113.1:39743\nAllowedIPs = 0.0.0.0/0\n' \
            > "$AWG_DIR/tom.conf"
        create_init_config
        echo "export CLIENT_DNS='10.9.9.1,'" >> "$CONFIG_FILE"
        unset AWG_REGEN_RESET_ROUTES
        run regenerate_client "tom"
        [ "$status" -eq 0 ] || { echo "$lib: regen blocked: $output" >&2; return 1; }
        grep -qxF "DNS = 9.9.9.9" "$AWG_DIR/tom.conf"
        unset CLIENT_DNS
    done
}

@test "client dns: the installer checks CLIENT_DNS in step 6 before creating clients (both languages)" {
    for f in "${INSTALLERS[@]}"; do
        body=$(sed -n '/^step6_generate_configs() {$/,/^}$/p' "$BATS_TEST_DIRNAME/../$f")
        # The check exists and comes before the first generate_client. Its
        # behaviour is covered by the _check_client_dns test below.
        local chk gen
        if echo "$body" | grep -qE '^[[:space:]]*awg_client_dns >/dev/null'; then
            echo "$f: step 6 calls awg_client_dns directly, bypassing _check_client_dns" >&2; return 1
        fi
        chk=$(echo "$body" | grep -nE '^[[:space:]]*_check_client_dns$' | head -1 | cut -d: -f1)
        gen=$(echo "$body" | grep -nE 'generate_client "\$client_name"' | head -1 | cut -d: -f1)
        [ -n "$chk" ] || { echo "$f: no CLIENT_DNS check in step 6" >&2; return 1; }
        [ -n "$gen" ] || { echo "$f: generate_client call not found in step 6" >&2; return 1; }
        [ "$chk" -lt "$gen" ] || { echo "$f: CLIENT_DNS check comes after generate_client" >&2; return 1; }
        # Before any state change of step 6, not merely before the clients.
        local sk
        sk=$(echo "$body" | grep -nE 'generate_server_keys' | head -1 | cut -d: -f1)
        [ -n "$sk" ] && [ "$chk" -lt "$sk" ] || { echo "$f: CLIENT_DNS check comes after the server keys" >&2; return 1; }
    done
}

@test "client dns: step 6 check survives a library that predates CLIENT_DNS (both languages)" {
    # Between releases the installer on main downloads the helpers of the
    # previous tag, where awg_client_dns does not exist. An empty CLIENT_DNS has
    # nothing to check; a set one would be ignored by that library, so it must
    # stop the install with the real reason, not with "CLIENT_DNS is invalid".
    local i f lib rc
    for i in 0 1; do
        f="${INSTALLERS[$i]}"; lib="${LIBS[$i]}"
        # Old library: awg_client_dns is not defined.
        rc=0
        ( die() { echo "DIE: $*" >&2; exit 1; }
          # shellcheck source=/dev/null
          source <(sed -n '/^_check_client_dns() {$/,/^}$/p' "$BATS_TEST_DIRNAME/../$f")
          declare -F _check_client_dns >/dev/null || exit 99
          unset -f awg_client_dns; ! declare -F awg_client_dns >/dev/null || exit 98
          CONFIG_FILE=/root/awg/awgsetup_cfg.init AWG_BRANCH=v5.36.2 CLIENT_DNS="" _check_client_dns ) || rc=$?
        [ "$rc" -eq 0 ] || { echo "$f: old library, empty CLIENT_DNS: rc=$rc" >&2; return 1; }
        rc=0
        ( die() { echo "DIE: $*" >&2; exit 1; }
          # shellcheck source=/dev/null
          source <(sed -n '/^_check_client_dns() {$/,/^}$/p' "$BATS_TEST_DIRNAME/../$f")
          declare -F _check_client_dns >/dev/null || exit 99
          unset -f awg_client_dns; ! declare -F awg_client_dns >/dev/null || exit 98
          CONFIG_FILE=/root/awg/awgsetup_cfg.init AWG_BRANCH=v5.36.2 CLIENT_DNS="9.9.9.9" _check_client_dns ) 2>"$TEST_DIR/err" || rc=$?
        [ "$rc" -eq 1 ] || { echo "$f: old library, CLIENT_DNS set: rc=$rc" >&2; return 1; }
        grep -q 'DIE: ' "$TEST_DIR/err" || { echo "$f: no die" >&2; return 1; }
        grep -q 'v5.36.2' "$TEST_DIR/err" || { echo "$f: message does not name the library branch" >&2; return 1; }
        if grep -qiE 'невалиден|is invalid' "$TEST_DIR/err"; then
            echo "$f: old library reported as an invalid value" >&2; return 1
        fi
        # Current library: the full check runs and fails loudly on a bad value.
        rc=0
        ( die() { echo "DIE: $*" >&2; exit 1; }
          _use_lib "$lib"
          # shellcheck source=/dev/null
          source <(sed -n '/^_check_client_dns() {$/,/^}$/p' "$BATS_TEST_DIRNAME/../$f")
          declare -F _check_client_dns >/dev/null || exit 99
          CONFIG_FILE=/root/awg/awgsetup_cfg.init CLIENT_DNS="10.9.9.1, 1.1.1.1" _check_client_dns ) || rc=$?
        [ "$rc" -eq 0 ] || { echo "$f: current library, valid CLIENT_DNS: rc=$rc" >&2; return 1; }
        rc=0
        ( die() { echo "DIE: $*" >&2; exit 1; }
          _use_lib "$lib"
          # shellcheck source=/dev/null
          source <(sed -n '/^_check_client_dns() {$/,/^}$/p' "$BATS_TEST_DIRNAME/../$f")
          declare -F _check_client_dns >/dev/null || exit 99
          CONFIG_FILE=/root/awg/awgsetup_cfg.init CLIENT_DNS="10.9.9.1," _check_client_dns ) 2>"$TEST_DIR/err" || rc=$?
        [ "$rc" -eq 1 ] || { echo "$f: current library, invalid CLIENT_DNS: rc=$rc" >&2; return 1; }
        grep -qiE 'невалиден|is invalid' "$TEST_DIR/err" || { echo "$f: invalid value not reported as invalid" >&2; return 1; }
    done
}

@test "client dns: step 0 shape check (both languages)" {
    for f in "${INSTALLERS[@]}"; do
        # shellcheck source=/dev/null
        source <(sed -n '/^_client_dns_shape_ok() {$/,/^}$/p' "$BATS_TEST_DIRNAME/../$f")
        declare -F _client_dns_shape_ok >/dev/null || { echo "$f: no _client_dns_shape_ok" >&2; return 1; }
        for ok in "10.9.9.1" "1.1.1.1, 1.0.0.1" "2606:4700:4700::1111" "10.9.9.1,fd00::1" "0.0.0.0"; do
            _client_dns_shape_ok "$ok" || { echo "$f rejected '$ok'" >&2; return 1; }
        done
        for bad in "" "10.9.9.1," ",10.9.9.1" "10.9.9.1,,1.1.1.1" "999.1.1.1" "1.1.1" "cafe" "1.1.1.1.1" "256.0.0.1"; do
            if _client_dns_shape_ok "$bad"; then echo "$f accepted '$bad'" >&2; return 1; fi
        done
        unset -f _client_dns_shape_ok
    done
}

@test "no-prebuilt: the saved value is checked before --no-prebuilt can overwrite it (both languages)" {
    for f in "${INSTALLERS[@]}"; do
        local v c
        v=$(grep -nE '^    case "\$\{NO_PREBUILT:-0\}" in$' "$BATS_TEST_DIRNAME/../$f" | head -1 | cut -d: -f1)
        c=$(grep -nE '^    if \[\[ "\$\{CLI_NO_PREBUILT:-0\}" -eq 1 \]\]; then$' "$BATS_TEST_DIRNAME/../$f" | head -1 | cut -d: -f1)
        [ -n "$v" ] && [ -n "$c" ] && [ "$v" -lt "$c" ] \
            || { echo "$f: validation ($v) is not before the CLI override ($c)" >&2; return 1; }
    done
}

@test "no-prebuilt: the installed-package filter catches half-installed packages, not removed ones (both languages)" {
    for f in "${INSTALLERS[@]}"; do
        line=$(grep -E '^[[:space:]]+_kmod=\$\(dpkg-query ' "$BATS_TEST_DIRNAME/../$f" | head -1)
        [ -n "$line" ] || { echo "$f: _kmod line not found" >&2; return 1; }
        out=$(bash -c '
            dpkg-query() { printf "%s\n" \
                "amneziawg-kmod-a install ok installed" \
                "amneziawg-kmod-b hold ok installed" \
                "amneziawg-kmod-c install ok half-configured" \
                "amneziawg-kmod-d install ok unpacked" \
                "amneziawg-kmod-e deinstall ok config-files" \
                "amneziawg-kmod-f unknown ok not-installed"; }
            eval "$1"; printf "%s" "$_kmod"' _ "$line")
        [ "$out" = "amneziawg-kmod-a amneziawg-kmod-b amneziawg-kmod-c amneziawg-kmod-d" ] \
            || { echo "$f: got '$out'" >&2; return 1; }
    done
}

@test "client dns: a kept DNS goes to render_client_config as an argument, not through the environment (both libraries)" {
    for lib in "${LIBS[@]}"; do
        _use_lib "$lib"
        create_server_config
        create_init_config
        echo "export CLIENT_DNS='bogus'" >> "$CONFIG_FILE"
        # With the 8th argument the invalid CLIENT_DNS does not matter.
        render_client_config "kept" "10.9.9.10" "FAKEPRIV" "FAKEPUB" "1.2.3.4" "39743" "" "9.9.9.9"
        grep -qxF "DNS = 9.9.9.9" "$AWG_DIR/kept.conf"
        # A variable in the environment is no substitute for the argument.
        mv "$AWG_DIR/kept.conf" "$AWG_DIR/kept.conf.$lib"
        export _AWG_KEEP_DNS="9.9.9.9" keep_dns="9.9.9.9"
        run render_client_config "envk" "10.9.9.11" "FAKEPRIV" "FAKEPUB" "1.2.3.4" "39743"
        unset _AWG_KEEP_DNS keep_dns
        [ "$status" -ne 0 ] || { echo "$lib: an environment variable bypassed CLIENT_DNS validation" >&2; return 1; }
    done
}

@test "client dns: the installer resets CLIENT_DNS from the environment before loading the config (both languages)" {
    for f in "${INSTALLERS[@]}"; do
        grep -qE '^[[:space:]]+CLIENT_DNS=""$' "$BATS_TEST_DIRNAME/../$f" \
            || { echo "$f: CLIENT_DNS is not reset before config load" >&2; return 1; }
    done
}

@test "no-prebuilt: stops when a prebuilt module package is already installed (both languages)" {
    for f in "${INSTALLERS[@]}"; do
        body=$(sed -n '/^step2_install_amnezia() {$/,/^}$/p' "$BATS_TEST_DIRNAME/../$f")
        echo "$body" | grep -qF "dpkg-query -W -f='\${Package} \${Status}\n' 'amneziawg-kmod-*'" \
            || { echo "$f: no check for an installed prebuilt package" >&2; return 1; }
        echo "$body" | grep -qE 'die .*apt-get purge -y \$_kmod' \
            || { echo "$f: no stop with the purge command" >&2; return 1; }
    done
}

@test "no-prebuilt: a NO_PREBUILT other than 0 or 1 stops the installer (both languages)" {
    for f in "${INSTALLERS[@]}"; do
        # Extract the validation block and run it with a few values.
        blk=$(sed -n '/^    case "\${NO_PREBUILT:-0}" in$/,/^    esac$/p' "$BATS_TEST_DIRNAME/../$f")
        [ -n "$blk" ] || { echo "$f: no NO_PREBUILT validation" >&2; return 1; }
        for v in 0 1; do
            NO_PREBUILT="$v" CONFIG_FILE=x bash -c 'die(){ echo DIE; exit 1; }; eval "$1"; echo OK' _ "$blk" | grep -qx OK \
                || { echo "$f: rejected valid NO_PREBUILT=$v" >&2; return 1; }
        done
        for v in yes true "1 # c" 2; do
            if NO_PREBUILT="$v" CONFIG_FILE=x bash -c 'die(){ echo DIE; exit 1; }; eval "$1"; echo OK' _ "$blk" | grep -qx OK; then
                echo "$f: accepted NO_PREBUILT='$v'" >&2
                return 1
            fi
        done
    done
}

@test "client dns: a CLIENT_DNS from the environment is dropped when the file has no such line (both libraries)" {
    for lib in "${LIBS[@]}"; do
        _use_lib "$lib"
        create_init_config
        export CLIENT_DNS="6.6.6.6"
        safe_load_config "$CONFIG_FILE"
        [ -z "${CLIENT_DNS:-}" ] || { echo "$lib kept env CLIENT_DNS='$CLIENT_DNS'" >&2; return 1; }
    done
}

@test "client dns: regen does not widen a deliberate CLIENT_DNS='1.1.1.1' into the pair (both libraries)" {
    require_flock
    for lib in "${LIBS[@]}"; do
        _use_lib "$lib"
        _make_server_conf_with_peer "una" "10.9.9.5"
        _setup_regen_stubs
        echo "UNA_PRIV" > "$KEYS_DIR/una.private"
        printf '[Interface]\nPrivateKey = UNA_PRIV\nAddress = 10.9.9.5/32\nDNS = 1.1.1.1\nMTU = 1280\nPersistentKeepalive = 33\n[Peer]\nPublicKey = SERVER_PUB\nEndpoint = 203.0.113.1:39743\nAllowedIPs = 0.0.0.0/0\n' \
            > "$AWG_DIR/una.conf"
        create_init_config
        echo "export CLIENT_DNS='1.1.1.1'" >> "$CONFIG_FILE"
        unset AWG_REGEN_RESET_ROUTES
        run regenerate_client "una"
        [ "$status" -eq 0 ] || { echo "$lib: $output" >&2; return 1; }
        grep -qxF "DNS = 1.1.1.1" "$AWG_DIR/una.conf" \
            || { echo "$lib:"; grep '^DNS' "$AWG_DIR/una.conf"; return 1; } >&2
        unset CLIENT_DNS
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
        create_init_config
        echo "export CLIENT_DNS='10.9.9.1'" >> "$CONFIG_FILE"
        unset AWG_REGEN_RESET_ROUTES
        run regenerate_client "sam"
        [ "$status" -eq 0 ] || { echo "$lib: $output" >&2; return 1; }
        grep -qxF "DNS = 8.8.8.8" "$AWG_DIR/sam.conf" \
            || { echo "$lib:"; grep '^DNS' "$AWG_DIR/sam.conf"; return 1; } >&2
        unset CLIENT_DNS
    done
}
