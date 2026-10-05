#!/usr/bin/env bats
# Client profiles must import into the strict vendor clients.
#
# AmneziaWG for Android (tunnel/.../config/Interface.java), iOS and macOS
# (TunnelConfiguration+WgQuickConfig.swift) and Windows (conf/parser.go) reject
# the WHOLE profile when [Interface] carries a key they do not know, and reject
# a malformed HeaderProtectionKey on its own. The flagship AmneziaVPN ignores
# unknown keys, so a profile that imports there proves nothing about these
# three. Every content line of a rendered client profile is therefore checked
# against the key list those parsers accept, for both generations and the
# render variants an install can produce (no CPS, I2-I5, IPv6, own DNS and
# MTU). The 3.1 client key sequence is pinned as well, next to the 2.0 one in
# test_awg31_render_golden.bats.
#
# Both library twins run for real in a separate shell.
#
# What this does NOT pin: that we write exactly our own key set. The parsers also
# accept keys we never render (RandomTrailers, timers, ...); a client profile
# that starts carrying one passes here and is caught by the golden key sequences
# (2.0 in test_awg31_render_golden.bats, 3.1 below).

# The [Interface] keys the strict vendor parsers accept (Android Interface.java,
# the same set in the iOS and Windows parsers), lower case.
IFACE_KEYS=" address dns excludedapplications includedapplications listenport mtu privatekey
 jc jmin jmax s1 s2 s3 s4 h1 h2 h3 h4 i1 i2 i3 i4 i5 headerprotectionkey contentpaddingaddition
 rekeyaftertime rekeytimeout rejectaftertime keepalivetimeout maxhandshakeattempts randomtrailers
 disablecookies "
# One line with a space on both sides of every key, for the lookup below.
IFACE_KEYS=" $(echo $IFACE_KEYS) "
# The [Peer] keys of the same parsers.
PEER_KEYS=" publickey presharedkey allowedips endpoint persistentkeepalive "

KEY_OK="QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQA="
# Keys of the right form (32 bytes of base64): the strict clients check that too.
KEY_PRIV="cccccccccccccccccccccccccccccccccccccccccc4="
KEY_PUB="ssssssssssssssssssssssssssssssssssssssssssk="
KEY_PSK="pppppppppppppppppppppppppppppppppppppppppp8="

# lib_run <lib> <generation> <extra init lines> <client IPv6 or empty> [preshared key]
# renders the server and client c1 of that install; prints RC= and the client path
lib_run() {
    local lib="$1" gen="$2" extra="$3" c6="${4:-}" psk="${5:-}" d cpa=""
    d="$BATS_TEST_TMPDIR/k-$(basename "$lib" .sh)"
    [[ "$gen" == "3.1" ]] && cpa="32-128"
    rm -rf "$d"; mkdir -p "$d/keys"
    {
        printf "export AWG_PORT=39743\nexport AWG_TUNNEL_SUBNET='10.9.9.1/24'\nexport DISABLE_IPV6=1\n"
        printf "export ALLOWED_IPS_MODE=1\nexport ALLOWED_IPS='0.0.0.0/0'\n"
        printf "export AWG_PROTOCOL='%s'\nexport AWG_CPA='%s'\n" "$gen" "$cpa"
        printf "export AWG_Jc=6\nexport AWG_Jmin=55\nexport AWG_Jmax=380\n"
        printf "export AWG_S1=72\nexport AWG_S2=56\nexport AWG_S3=32\nexport AWG_S4=16\n"
        if [[ "$gen" == "3.1" ]]; then
            printf "export AWG_H1='1'\nexport AWG_H2='2'\nexport AWG_H3='3'\nexport AWG_H4='4'\n"
        else
            printf "export AWG_H1='100000-800000'\nexport AWG_H2='1000000-8000000'\n"
            printf "export AWG_H3='10000000-80000000'\nexport AWG_H4='100000000-800000000'\n"
        fi
        printf "export AWG_I1='<r 128>'\nexport AWG_APPLY_MODE='syncconf'\n"
        [[ -n "$extra" ]] && printf '%s\n' "$extra"
    } > "$d/awgsetup_cfg.init"
    printf 'SRVPRIVKEYPLACEHOLDER\n' > "$d/server_private.key"
    printf '%s\n' "$KEY_PUB" > "$d/server_public.key"
    [[ "$gen" == "3.1" ]] && printf '%s\n' "$KEY_OK" > "$d/server_hpk.key"
    AWG_DIR="$d" timeout 60 bash -c '
        export CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init" SERVER_CONF_FILE="$AWG_DIR/awg0.conf"
        export KEYS_DIR="$AWG_DIR/keys" EXPIRY_DIR="$AWG_DIR/expiry"
        log() { :; }; log_warn() { :; }; log_error() { echo "ERR: $*"; }; log_debug() { :; }
        source "$1" >/dev/null 2>&1 || true
        safe_load_config "$CONFIG_FILE" >/dev/null 2>&1
        get_main_nic() { echo eth0; }
        render_server_config || { echo "RC=90"; exit 0; }
        if [[ -n "$5" ]]; then export CLIENT_PSK="$5"; else unset CLIENT_PSK; fi
        render_client_config c1 10.9.9.2 "$3" "$4" "$6" 39743 "$2" || { echo "RC=91"; exit 0; }
        echo "RC=0"
    ' _ "$BATS_TEST_DIRNAME/../$lib" "$c6" "$KEY_PRIV" "$KEY_PUB" "$psk" "${EP:-203.0.113.10}"
}

conf_of() { echo "$BATS_TEST_TMPDIR/k-$(basename "$1" .sh)/c1.conf"; }

# strict_ok <client conf> : every content line is `Key = value` with a value,
# in a known section, with a key the strict parsers accept and a value of the
# form they accept (keys: 32 bytes of base64; MTU, Jc..S4: a number; H1-H4: a
# number or a range, ContentPaddingAddition too; Address and AllowedIPs a list
# of CIDRs; Endpoint host:port with an IPv6 host in brackets); one [Interface],
# at least one [Peer], no key twice in a section except Address, AllowedIPs and
# DNS (the iOS parser refuses any other repeat). Prints the first
# offending line and fails otherwise. Values are checked for FORM only: what the
# parsers do with a well-formed but wrong value is the device gate's business.
strict_ok() {
    local f="$1" line sec="" key low val tok seen_i=0 seen_p=0
    local -A seen=()
    [ -s "$f" ] || { echo "no client config: $f"; return 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "$line" ]] && continue
        case "$line" in
            '[Interface]') (( seen_i == 0 )) || { echo "a second [Interface]"; return 1; }
                           sec=i; seen_i=1; seen=(); continue ;;
            '[Peer]')      sec=p; seen_p=1; seen=(); continue ;;
        esac
        [[ "$line" =~ ^([A-Za-z0-9]+)\ =\ (.*[^[:space:]].*)$ ]] || { echo "not a key line: '$line'"; return 1; }
        key="${BASH_REMATCH[1]}"; low="${key,,}"; val="${BASH_REMATCH[2]}"
        case "$low" in
            address|allowedips|dns) : ;;
            *) [[ -z "${seen[$low]:-}" ]] || { echo "a key repeated in its section: '$line'"; return 1; }
               seen[$low]=1 ;;
        esac
        case "$low" in
            privatekey|publickey|presharedkey|headerprotectionkey)
                [[ "$val" =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]] || { echo "not a key value: '$line'"; return 1; } ;;
            mtu|jc|jmin|jmax|s1|s2|s3|s4|persistentkeepalive)
                [[ "$val" =~ ^[0-9]+$ ]] || { echo "not a number: '$line'"; return 1; } ;;
            h1|h2|h3|h4|contentpaddingaddition)
                [[ "$val" =~ ^[0-9]+(-[0-9]+)?$ ]] || { echo "not a number or range: '$line'"; return 1; } ;;
            address|allowedips)
                for tok in ${val//,/ }; do
                    [[ "$tok" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ || "$tok" =~ ^[0-9A-Fa-f:]*:[0-9A-Fa-f:]*/[0-9]{1,3}$ ]] \
                        || { echo "not a CIDR list: '$line'"; return 1; }
                done ;;
            endpoint)
                [[ "$val" =~ ^(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9.-]+):[0-9]{1,5}$ ]] || { echo "not host:port: '$line'"; return 1; } ;;
        esac
        case "$sec" in
            i) [[ "$IFACE_KEYS" == *" $low "* ]] || { echo "[Interface] key the strict clients reject: '$line'"; return 1; } ;;
            p) [[ "$PEER_KEYS" == *" $low "* ]] || { echo "[Peer] key the strict clients reject: '$line'"; return 1; } ;;
            *) echo "line outside a section: '$line'"; return 1 ;;
        esac
    done < "$f"
    [ "$seen_i" -eq 1 ] && [ "$seen_p" -eq 1 ] || { echo "a section is missing in $f"; return 1; }
}

both() {
    local seen=0 lib
    for lib in awg_common.sh awg_common_en.sh; do
        "$1" "$lib" || return 1
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}

# check <lib> <generation> <extra init> <client IPv6 or empty> <musts> [<must not>] [<psk>]
# render, prove the variant took effect (a line for every pattern in <musts>,
# separated by ';;', and none matching <must not>), then strict_ok
check() {
    local out f m
    local -a musts
    out=$(lib_run "$1" "$2" "$3" "$4" "${7:-}")
    [[ "$out" == *"RC=0"* ]] || { echo "render failed ($1, $2, $3): $out"; return 1; }
    f=$(conf_of "$1")
    IFS=$'\n' read -r -d '' -a musts < <(printf '%s' "${5//;;/$'\n'}"; printf '\0') || true
    [ "${#musts[@]}" -gt 0 ] || { echo "no must pattern given"; return 1; }
    for m in "${musts[@]}"; do
        grep -qE "$m" "$f" || { echo "variant did not take effect, no /$m/ ($1, $2, $3)"; cat "$f"; return 1; }
    done
    if [[ -n "${6:-}" ]]; then
        ! grep -qE "$6" "$f" || { echo "variant did not take effect, /$6/ still there ($1, $2, $3)"; cat "$f"; return 1; }
    fi
    strict_ok "$f" || { echo "($1, $2, $3)"; cat "$f"; return 1; }
}

@test "strict keys: the checker itself rejects an unknown key, a comment, an empty value, a bad form" {
    local f="$BATS_TEST_TMPDIR/bad.conf" good
    good="[Interface]"$'\n'"PrivateKey = $KEY_PRIV"$'\nAddress = 10.9.9.2/32\nMTU = 1280\n\n[Peer]\n'"PublicKey = $KEY_PUB"$'\nAllowedIPs = 0.0.0.0/0\n'
    printf '%s' "$good" > "$f"
    strict_ok "$f" || { echo "a valid profile was rejected"; return 1; }
    printf '%s' "${good/Address/Table = off$'\n'Address}" > "$f"
    ! strict_ok "$f" >/dev/null || { echo "Table accepted"; return 1; }
    printf '%s' "${good/Address/# note$'\n'Address}" > "$f"
    ! strict_ok "$f" >/dev/null || { echo "comment accepted"; return 1; }
    printf '%s' "${good/Address = 10.9.9.2\/32/Address = }" > "$f"
    ! strict_ok "$f" >/dev/null || { echo "empty value accepted"; return 1; }
    printf '%s' "${good/AllowedIPs/Jc = 4$'\n'AllowedIPs}" > "$f"
    ! strict_ok "$f" >/dev/null || { echo "Interface key under [Peer] accepted"; return 1; }
    printf '%s' "${good/\[Peer\]/[Interface]$'\n'DNS = 9.9.9.9$'\n\n'[Peer]}" > "$f"
    ! strict_ok "$f" >/dev/null || { echo "a second [Interface] accepted"; return 1; }
    printf '%s' "${good/$KEY_PRIV/CLIENTPRIVKEYPLACEHOLDER}" > "$f"
    ! strict_ok "$f" >/dev/null || { echo "a malformed key accepted"; return 1; }
    printf '%s' "${good/MTU = 1280/MTU = 1280x}" > "$f"
    ! strict_ok "$f" >/dev/null || { echo "a malformed MTU accepted"; return 1; }
    printf '%s' "${good/MTU = 1280/MTU = 1280$'\n'MTU = 1380}" > "$f"
    ! strict_ok "$f" >/dev/null || { echo "a repeated MTU accepted"; return 1; }
    printf '%s' "${good/AllowedIPs = 0.0.0.0\/0/AllowedIPs = 0.0.0.0\/0$'\n'Endpoint = 2001:db8::1:39743}" > "$f"
    ! strict_ok "$f" >/dev/null || { echo "an unbracketed IPv6 endpoint accepted"; return 1; }
    printf '%s' "${good/Address = 10.9.9.2\/32/Address = 10.9.9.2}" > "$f"
    ! strict_ok "$f" >/dev/null || { echo "an Address without a prefix accepted"; return 1; }
    printf '%s' "${good/MTU = 1280/MTU = 1280$'\n'DNS = 1.1.1.1$'\n'DNS = 1.0.0.1}" > "$f"
    strict_ok "$f" || { echo "a repeated DNS rejected"; return 1; }
}

k_variants() {
    local lib="$1" gen
    for gen in 2.0 3.1; do
        check "$lib" "$gen" "" "" '^I1 = <r 128>$' || return 1
        check "$lib" "$gen" "export AWG_I1=''" "" '^Jc = 6$' '^I1 ' || return 1
        check "$lib" "$gen" $'export AWG_I2=\'<r 10>\'\nexport AWG_I3=\'<rc 8>\'\nexport AWG_I4=\'<rd 6>\'\nexport AWG_I5=\'<t>\'' "" \
            '^I2 = <r 10>$;;^I3 = <rc 8>$;;^I4 = <rd 6>$;;^I5 = <t>$' || return 1
        check "$lib" "$gen" $'export CLIENT_DNS=\'9.9.9.9\'\nexport AWG_MTU=1380' "" '^DNS = 9\.9\.9\.9$;;^MTU = 1380$' || return 1
        check "$lib" "$gen" $'export AWG_MTU=1380' "" '^MTU = 1380$' || return 1
        check "$lib" "$gen" $'export DISABLE_IPV6=0\nexport ALLOW_IPV6_TUNNEL=1\nexport IPV6_SUBNET=\'fddd:2c4:2c4:2c4::/64\'' \
            "fddd:2c4:2c4:2c4::2" '^Address = 10\.9\.9\.2/32, fddd:2c4:2c4:2c4::2' || return 1
        check "$lib" "$gen" "" "" "^PresharedKey = $KEY_PSK\$" "" "$KEY_PSK" || return 1
        EP='[2001:db8::1]' check "$lib" "$gen" "" "" '^Endpoint = \[2001:db8::1\]:39743$' || return 1
    done
}
@test "strict keys: every render variant of both generations imports into the strict clients, both twins" {
    both k_variants
}

# keys_of <file> : the key names of the file, in order, sections included.
keys_of() {
    sed -n 's/^\[\(.*\)\]$/[\1]/p; s/^\([A-Za-z_][A-Za-z0-9_]*\) = .*/\1/p' "$1"
}

k_golden31() {
    local lib="$1" out f
    out=$(lib_run "$lib" 3.1 "")
    [[ "$out" == *"RC=0"* ]] || { echo "render failed ($lib): $out"; return 1; }
    f=$(conf_of "$lib")
    diff <(keys_of "$f") <(printf '%s\n' '[Interface]' PrivateKey Address DNS MTU \
        Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4 I1 HeaderProtectionKey ContentPaddingAddition \
        '[Peer]' PublicKey Endpoint AllowedIPs PersistentKeepalive) || { echo "client 3.1 keys differ ($lib)"; return 1; }
    grep -qx "HeaderProtectionKey = $KEY_OK" "$f" || { echo "key value ($lib)"; return 1; }
    grep -qx 'ContentPaddingAddition = 32-128' "$f" || { echo "padding value ($lib)"; return 1; }
    grep -qx 'H1 = 1' "$f" && grep -qx 'H4 = 4' "$f" || { echo "H values ($lib)"; return 1; }
}
@test "golden 3.1: the client config keeps its key sequence and values, both twins" {
    both k_golden31
}
