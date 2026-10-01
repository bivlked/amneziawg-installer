#!/usr/bin/env bats
# Lifecycle of both protocol generations (slice E of phase F4).
#
# The 3.1 header protection key belongs to the server identity: every client
# and every vpn:// link carries it, so a change anywhere cuts every client off.
# These cases run real manage operations on a full installation and compare
# the generation fingerprint (tests/gen_print.bash) before and after:
#   - regen, modify, add, remove keep the key and the parameters, and touch
#     only the client they name;
#   - backup + restore brings back exactly the archive, clients and links
#     included, within a generation and across generations;
#   - on 2.0 no header protection key appears anywhere.
# The fingerprint itself is checked first: it must reject or tell apart an
# installation that differs by one deleted link, one changed key or one changed
# parameter, or a green comparison would prove nothing.
#
# Harness: the real manage scripts end-to-end in a sandbox, as in
# test_awg31_backup_restore.bats, with a deterministic `awg pubkey` so that a
# re-rendered config is byte-comparable.

# shellcheck disable=SC2154  # $stderr is set by `run --separate-stderr`

bats_require_minimum_version 1.5.0

load gen_print

K1='BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA='
K2='CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCE='

_crond_state() {
    local f
    for f in /etc/cron.d/* /etc/cron.d/.[!.]*; do
        [[ -e "$f" ]] || continue
        printf '%s %s\n' "$f" "$(cksum < "$f")"
    done
}

setup_file() {
    _crond_state > "$BATS_FILE_TMPDIR/crond.before"
}

setup() {
    [[ -e /etc/cron.d/awg-expiry ]] && skip "host has /etc/cron.d/awg-expiry"
    command -v jq &>/dev/null || { [[ -z "${CI:-}" ]] || return 1; skip "jq not available"; }
    command -v python3 &>/dev/null || { [[ -z "${CI:-}" ]] || return 1; skip "python3 not available"; }
    TEST_DIR=$(mktemp -d)
    A="$TEST_DIR/awg"
    mkdir -p "$TEST_DIR/bin" "$A/keys" "$TEST_DIR/etc"

    # awg: random private keys, a public key derived from the private one, and
    # the third-line capability the environment check reads.
    cat > "$TEST_DIR/bin/awg" << STUB
#!/bin/bash
echo "awg \$*" >> "$TEST_DIR/awg.log"
case "\$1" in
    genkey|genpsk) head -c32 /dev/urandom | base64 ;;
    pubkey) k=\$(cat); printf '%s' "\$k" | sha256sum | head -c43; echo '=' ;;
    set)
        if [[ \$# -lt 3 ]]; then
            echo "Usage: awg set <interface> [listen-port <port>] [header-protection-key <file path>] [content-padding-addition <min-max>]"
            exit 1
        fi
        prev=""
        for a in "\$@"; do
            [[ "\$prev" == header-protection-key ]] && cat "\$a" > "$TEST_DIR/probe_hpk"
            prev="\$a"
        done
        exit 0 ;;
    showconf)
        echo "[Interface]"
        if [[ -s "$TEST_DIR/probe_hpk" ]]; then
            echo "HeaderProtectionKey = \$(cat "$TEST_DIR/probe_hpk")"
            echo "ContentPaddingAddition = 32-128"
        fi
        exit 0 ;;
    *) exit 0 ;;
esac
STUB
    local real_uname real_dpkg
    real_uname=$(PATH=/usr/bin:/bin command -v uname)
    real_dpkg=$(PATH=/usr/bin:/bin:/usr/sbin:/sbin command -v dpkg || echo false)
    cat > "$TEST_DIR/bin/uname" << STUB
#!/bin/bash
if [[ "\$1" == -r ]]; then echo 6.8.0-45-generic; exit 0; fi
exec "$real_uname" "\$@"
STUB
    cat > "$TEST_DIR/bin/dpkg" << STUB
#!/bin/bash
if [[ "\$1" == --print-architecture ]]; then echo amd64; exit 0; fi
exec "$real_dpkg" "\$@"
STUB
    printf '#!/bin/bash\necho "awg-quick $*" >> "%s/awg.log"\nexit 0\n' "$TEST_DIR" > "$TEST_DIR/bin/awg-quick"
    printf '#!/bin/bash\necho "systemctl $*" >> "%s/systemctl.log"\nexit 0\n' "$TEST_DIR" > "$TEST_DIR/bin/systemctl"
    cat > "$TEST_DIR/bin/ip" << STUB
#!/bin/bash
echo "ip \$*" >> "$TEST_DIR/ip.log"
if [[ "\$1 \$2" == "link add" ]]; then : > "$TEST_DIR/if_\$3"; exit 0; fi
if [[ "\$1 \$2" == "link del" ]]; then exec /bin/rm -f "$TEST_DIR/if_\$3"; fi
if [[ "\$1 \$2" == "link show" && "\$3" == awgp* ]]; then [[ -e "$TEST_DIR/if_\$3" ]]; exit; fi
if [[ "\$*" == *"link show"*"awg0"* ]]; then exit 1; fi
exit 0
STUB
    cat > "$TEST_DIR/bin/qrencode" << 'STUB'
#!/bin/bash
out=""
while [ $# -gt 0 ]; do
    if [ "$1" = "-o" ]; then out="$2"; shift; fi
    shift
done
cat >/dev/null
[ -n "$out" ] && printf 'PNG' > "$out"
exit 0
STUB
    for c in curl wget; do
        printf '#!/bin/bash\necho "%s $*" >> "%s/net.log"\nexit 1\n' "$c" "$TEST_DIR" > "$TEST_DIR/bin/$c"
    done
    chmod +x "$TEST_DIR/bin/"*
    export PATH="$TEST_DIR/bin:$PATH"

    cat > "$A/awgsetup_cfg.init" << 'CONF'
export AWG_PORT=39743
export AWG_TUNNEL_SUBNET='10.9.9.1/24'
export DISABLE_IPV6=1
export ALLOWED_IPS_MODE=1
export ALLOWED_IPS='0.0.0.0/0'
export AWG_Jc=6
export AWG_Jmin=55
export AWG_Jmax=380
export AWG_S1=72
export AWG_S2=56
export AWG_S3=32
export AWG_S4=16
export AWG_H1='100000-800000'
export AWG_H2='1000000-8000000'
export AWG_H3='10000000-80000000'
export AWG_H4='100000000-800000000'
export AWG_APPLY_MODE='syncconf'
export AWG_ENDPOINT='203.0.113.5'
CONF
    SC="$TEST_DIR/etc/awg0.conf"
    MOCK_ARGS=(--conf-dir="$A" --server-conf="$SC")
    export AWG_SKIP_APPLY=1
}

teardown() {
    unset AWG_SKIP_APPLY
    [[ -n "${TEST_DIR:-}" ]] && rm -rf "$TEST_DIR"
    _crond_state > "$BATS_TEST_TMPDIR/crond.after"
    cmp -s "$BATS_FILE_TMPDIR/crond.before" "$BATS_TEST_TMPDIR/crond.after" || {
        echo "host /etc/cron.d changed" >&2
        return 1
    }
}

_lib_for() {
    case "$1" in
        *_en.sh) cp "$BATS_TEST_DIRNAME/../awg_common_en.sh" "$A/awg_common.sh" ;;
        *)       cp "$BATS_TEST_DIRNAME/../awg_common.sh" "$A/awg_common.sh" ;;
    esac
}

_m() {
    local s="$1"; shift
    _lib_for "$s"
    run --separate-stderr timeout 60 bash "$s" "$@" --yes "${MOCK_ARGS[@]}"
}

_ok() {
    [ "$status" -eq 0 ] && return 0
    printf 'expected rc 0, got %s\n--- stdout\n%s\n--- stderr\n%s\n' "$status" "$output" "$stderr" >&2
    return 1
}

# _inst <script> <2.0|3.1> [key] : a full installation of that generation with
# the server keys and two clients made by the real `add`
_inst() {
    local s="$1" gen="$2" key="${3:-$K1}" priv
    sed -i '/AWG_PROTOCOL/d' "$A/awgsetup_cfg.init"
    printf "export AWG_PROTOCOL='%s'\n" "$gen" >> "$A/awgsetup_cfg.init"
    priv=$(head -c32 /dev/urandom | base64)
    ( umask 077
      printf '%s\n' "$priv" > "$A/server_private.key"
      printf '%s' "$priv" | awg pubkey > "$A/server_public.key" )
    {
        printf '[Interface]\nPrivateKey = %s\n' "$priv"
        [[ "$gen" == 3.1 ]] && printf 'HeaderProtectionKey = %s\nContentPaddingAddition = 32-128\n' "$key"
        printf 'Address = 10.9.9.1/24\nMTU = 1280\nListenPort = 39743\n'
        printf 'Jc = 6\nJmin = 55\nJmax = 380\nS1 = 72\nS2 = 56\nS3 = 32\nS4 = 16\n'
        printf 'H1 = 100000-800000\nH2 = 1000000-8000000\nH3 = 10000000-80000000\nH4 = 100000000-800000000\n'
    } > "$SC"
    chmod 600 "$SC"
    if [[ "$gen" == 3.1 ]]; then
        ( umask 077; printf '%s\n' "$key" > "$A/server_hpk.key" )
    else
        rm -f "$A/server_hpk.key"
    fi
    _m "$s" add alice; _ok
    _m "$s" add bob; _ok
}

# _print [file] : the fingerprint, saved when a file is given; fails loudly
_print() {
    local p
    p=$(_gen_print "$A" "$SC") || { echo "fingerprint refused the installation" >&2; return 1; }
    if [[ -n "${1:-}" ]]; then printf '%s\n' "$p" > "$1"; else printf '%s\n' "$p"; fi
}

# _same <before> : the fingerprint now equals the saved one
_same() {
    local now="$TEST_DIR/now.print"
    _print "$now" || return 1
    diff -u "$1" "$now" >&2 || { echo "fingerprint changed" >&2; return 1; }
}

# _diff_only <before> <regex> : every changed fact matches the regex, and
# something did change
_diff_only() {
    local now="$TEST_DIR/now.print" changed
    _print "$now" || return 1
    changed=$(diff "$1" "$now" | grep '^[<>]' || true)
    [[ -n "$changed" ]] || { echo "nothing changed" >&2; return 1; }
    if grep -vE "^[<>] ($2)" <<<"$changed" >&2; then
        echo "facts outside '$2' changed" >&2
        return 1
    fi
}

_hpk_count() { _print | grep -c "HeaderProtectionKey|$1\$\|^hpkfile|$1\$" || true; }

# 🔴 Case bodies run as plain commands, never under `||` or `if` (bash turns
# off set -e there); a fresh sandbox for the second twin.
_both() {
    local s
    for s in "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"; do
        echo "# twin: ${s##*/}" >&3
        "$1" "$s"
        teardown; setup
    done
}

# ---------- the fingerprint itself ----------

_fp_31_full() {
    _inst "$1" 3.1
    # the key in the file, the server config, two clients, and in each link both
    # the config text and the separate field of last_config
    [ "$(_hpk_count "$K1")" -eq 8 ]
}
@test "lifecycle: the fingerprint accepts a full 3.1 installation, key in all eight places" {
    _both _fp_31_full
}

_fp_20_full() {
    _inst "$1" 2.0
    _print > /dev/null
    [ "$(_print | grep -c HeaderProtectionKey || true)" -eq 0 ]
}
@test "lifecycle: the fingerprint accepts a full 2.0 installation without any key" {
    _both _fp_20_full
}

# _refused <command> : after the command the fingerprint must refuse
_refused() {
    eval "$1"
    if _gen_print "$A" "$SC" >/dev/null 2>"$TEST_DIR/fp.err"; then
        echo "fingerprint accepted: $1" >&2
        return 1
    fi
    grep -q '^gen_print: ' "$TEST_DIR/fp.err"
}

_fp_controls() {
    local s="$1" base="$TEST_DIR/base.print"
    _inst "$s" 3.1
    _print "$base"
    local snap="$TEST_DIR/snap"
    cp -a "$A" "$snap"; cp "$SC" "$TEST_DIR/sc.snap"
    _restore_snap() { rm -rf "$A"; cp -a "$snap" "$A"; cp "$TEST_DIR/sc.snap" "$SC"; }

    _refused 'rm "$A/alice.vpnuri"';                                    _restore_snap
    _refused 'sed -i "s|^HeaderProtectionKey = .*|HeaderProtectionKey = $K2|" "$A/bob.conf"'; _restore_snap
    _refused 'sed -i "/^HeaderProtectionKey/p" "$SC"';                   _restore_snap
    _refused 'sed -i "s|^S2 = .*|S2 = 57|" "$A/alice.conf"';            _restore_snap
    _refused 'printf "vpn://AAAA\n" > "$A/bob.vpnuri"';                 _restore_snap
    _refused 'printf "%s\n" "$K2" > "$A/server_hpk.key"';               _restore_snap
    _refused 'sed -i "/AWG_PROTOCOL/d" "$A/awgsetup_cfg.init"';         _restore_snap
    _refused 'rm "$A/keys/alice.private"';                              _restore_snap
    # accepted but different: a parameter that need not match the server
    sed -i 's|^ContentPaddingAddition = .*|ContentPaddingAddition = 40-128|' "$A/alice.conf"
    run _same "$base"
    [ "$status" -ne 0 ]
    _restore_snap
    _same "$base"
}
@test "lifecycle: the fingerprint refuses or tells apart a one-place corruption" {
    _both _fp_controls
}

# ---------- G2.5: manage operations keep the key ----------

_e1_regen_one() {
    local s="$1" base="$TEST_DIR/base.print"
    _inst "$s" 3.1
    _print "$base"
    _m "$s" regen alice; _ok
    _same "$base"
}
@test "lifecycle E1: regen of one client changes nothing in the fingerprint (3.1)" {
    _both _e1_regen_one
}

_e1_regen_all() {
    local s="$1" gen="$2" base="$TEST_DIR/base.print"
    _inst "$s" "$gen"
    _print "$base"
    _m "$s" regen; _ok
    _same "$base"
}
_e1_regen_all_31() { _e1_regen_all "$1" 3.1; }
_e1_regen_all_20() { _e1_regen_all "$1" 2.0; }
@test "lifecycle E1: regen of every client changes nothing (3.1)" {
    _both _e1_regen_all_31
}
@test "lifecycle E1: regen of every client changes nothing (2.0)" {
    _both _e1_regen_all_20
}

_e2_modify() {
    local s="$1" gen="$2" base="$TEST_DIR/base.print"
    _inst "$s" "$gen"
    _print "$base"
    _m "$s" modify alice DNS 9.9.9.9; _ok
    _diff_only "$base" '(client|uri):alice\|Interface\|DNS\||urimeta:alice\|[^|]*dns|urilast:alice\|'
}
_e2_modify_31() { _e2_modify "$1" 3.1; }
_e2_modify_20() { _e2_modify "$1" 2.0; }
@test "lifecycle E2: modify changes only that client's field, the key stays (3.1)" {
    _both _e2_modify_31
}
@test "lifecycle E2: modify changes only that client's field, no key appears (2.0)" {
    _both _e2_modify_20
}

_e_add_remove() {
    local s="$1" gen="$2" base="$TEST_DIR/base.print"
    _inst "$s" "$gen"
    _print "$base"
    _m "$s" add carol; _ok
    _diff_only "$base" '(client|uri|urilast|urimeta):carol\||srv\|peer:carol\||keys\|carol\.'
    _m "$s" remove carol; _ok
    _same "$base"
}
_e_add_remove_31() { _e_add_remove "$1" 3.1; }
_e_add_remove_20() { _e_add_remove "$1" 2.0; }
@test "lifecycle: add and remove touch only that client (3.1)" {
    _both _e_add_remove_31
}
@test "lifecycle: add and remove touch only that client (2.0)" {
    _both _e_add_remove_20
}

# ---------- G2.5 / G2.15f: backup and restore bring back the archive ----------

_backup() {
    local s="$1" out
    _lib_for "$s"
    out=$(timeout 60 bash "$s" backup --json "${MOCK_ARGS[@]}" 2>/dev/null) || return 1
    printf '%s' "$out" | jq -re '.path'
}

# _e3 <script> <archive gen> <archive key> <live gen> <live key>
_e3() {
    local s="$1" arch_print="$TEST_DIR/arch.print" path
    _inst "$s" "$2" "$3"
    _print "$arch_print"
    path=$(_backup "$s")
    [[ -f "$path" ]]
    # a different live installation: new server keys, other clients
    rm -f "$A"/*.conf "$A"/*.vpnuri "$A"/*.png "$A"/keys/*
    _inst "$s" "$4" "$5"
    _m "$s" add dave; _ok
    _m "$s" restore "$path"; _ok
    _same "$arch_print"
}
_e3_31_same_key()  { _e3 "$1" 3.1 "$K1" 3.1 "$K1"; }
_e3_31_other_key() { _e3 "$1" 3.1 "$K1" 3.1 "$K2"; }
_e4_31_onto_20()   { _e3 "$1" 3.1 "$K1" 2.0 ""; }
_e4_20_onto_31()   { _e3 "$1" 2.0 "" 3.1 "$K2"; }
@test "lifecycle E3: restore of a 3.1 archive brings back the archive exactly (same key)" {
    _both _e3_31_same_key
}
@test "lifecycle E3: restore of a 3.1 archive brings back the archive key, not the live one" {
    _both _e3_31_other_key
}
@test "lifecycle E4: restore of a 3.1 archive onto 2.0 brings back clients and links with the key" {
    _both _e4_31_onto_20
}
@test "lifecycle E4: restore of a 2.0 archive onto 3.1 leaves no key in any config or link" {
    _both _e4_20_onto_31
}
