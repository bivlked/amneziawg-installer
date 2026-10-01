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
        # module_line2: a second-line module ignores the key (the step 3 post check fails)
        if [[ ! -e "$TEST_DIR/module_line2" && -s "$TEST_DIR/probe_hpk" ]]; then
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
if [[ "\$*" == *"link show"*"awg0"* ]]; then echo 'Device "awg0" does not exist.' >&2; exit 1; fi
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
    # a real install keeps the init private
    chmod 600 "$A/awgsetup_cfg.init"
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

# _kept <before> : every fact of the saved fingerprint is still there unchanged;
# only new init keys may have appeared
_kept() {
    local now="$TEST_DIR/now.print" added d rc=0
    _print "$now" || return 1
    d=$(diff "$1" "$now") || rc=$?
    (( rc <= 1 )) || { echo "diff failed ($rc)" >&2; return 1; }
    if grep '^<' <<<"$d" >&2; then echo "facts changed or gone" >&2; return 1; fi
    added=$(grep '^>' <<<"$d" || true)
    if grep -v '^> init|' <<<"$added" | grep . >&2; then echo "facts outside the init appeared" >&2; return 1; fi
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

# _refused <command> <reason> : after the command the fingerprint must refuse,
# for that reason (a refusal for another reason would hide a dead check)
_refused() {
    eval "$1"
    if _gen_print "$A" "$SC" >/dev/null 2>"$TEST_DIR/fp.err"; then
        echo "fingerprint accepted: $1" >&2
        return 1
    fi
    grep -qF -- "$2" "$TEST_DIR/fp.err" || { echo "refused, but not for '$2':" >&2; cat "$TEST_DIR/fp.err" >&2; return 1; }
}

_fp_controls() {
    local s="$1" base="$TEST_DIR/base.print"
    _inst "$s" 3.1
    _print "$base"
    local snap="$TEST_DIR/snap"
    cp -a "$A" "$snap"; cp "$SC" "$TEST_DIR/sc.snap"
    _restore_snap() { rm -rf "$A"; cp -a "$snap" "$A"; cp "$TEST_DIR/sc.snap" "$SC"; }

    _refused 'rm "$A/alice.vpnuri"' 'no .vpnuri';                        _restore_snap
    _refused 'sed -i "s|^HeaderProtectionKey = .*|HeaderProtectionKey = $K2|" "$A/bob.conf"' 'header protection key differs'; _restore_snap
    _refused 'sed -i "/^HeaderProtectionKey/p" "$SC"' 'duplicate HeaderProtectionKey'; _restore_snap
    _refused 'sed -i "/^HeaderProtectionKey/d" "$SC"' '3.1 server config without HeaderProtectionKey'; _restore_snap
    _refused 'sed -i "s|^S2 = .*|S2 = 57|" "$A/alice.conf"' "S2 '57' vs server"; _restore_snap
    _refused 'printf "vpn://AAAA\n" > "$A/bob.vpnuri"' 'link does not decode'; _restore_snap
    _refused 'printf "%s\n" "$K2" > "$A/server_hpk.key"' 'header protection key differs'; _restore_snap
    _refused 'sed -i "/AWG_PROTOCOL/d" "$A/awgsetup_cfg.init"' 'marker AWG_PROTOCOL'; _restore_snap
    _refused 'rm "$A/keys/alice.private"' 'PrivateKey differs from keys/alice.private'; _restore_snap
    _refused 'cp "$A/alice.vpnuri" "$A/ghost.vpnuri"' 'ghost.vpnuri without ghost.conf'; _restore_snap
    _refused 'chmod 644 "$A/server_hpk.key"' 'a secret must be 600';   _restore_snap
    _refused 'rm "$A/server_public.key"' 'no server_public.key';         _restore_snap
    # accepted but different: a fact no check ties to another one
    sed -i "s|^export AWG_ENDPOINT=.*|export AWG_ENDPOINT='203.0.113.9'|" "$A/awgsetup_cfg.init"
    run _same "$base"
    [ "$status" -ne 0 ]
    [[ "$output$stderr" == *"fingerprint changed"* && "$output$stderr" != *"refused"* ]]
    _restore_snap
    _same "$base"
}
@test "lifecycle: the fingerprint refuses or tells apart a one-place corruption" {
    _both _fp_controls
}

# ---------- G2.5: manage operations keep the key ----------

_e1_regen_one() {
    local s="$1" gen="$2" base="$TEST_DIR/base.print"
    _inst "$s" "$gen"
    _print "$base"
    _m "$s" regen alice; _ok
    _same "$base"
}
_e1_regen_one_31() { _e1_regen_one "$1" 3.1; }
_e1_regen_one_20() { _e1_regen_one "$1" 2.0; }
@test "lifecycle E1: regen of one client changes nothing in the fingerprint (3.1)" {
    _both _e1_regen_one_31
}
@test "lifecycle E1: regen of one client changes nothing in the fingerprint (2.0)" {
    _both _e1_regen_one_20
}

# restart goes through apply_config for real here (AWG_SKIP_APPLY off): the
# configs on disk stay as they were
_e_restart() {
    local s="$1" gen="$2" base="$TEST_DIR/base.print"
    _inst "$s" "$gen"
    _print "$base"
    # the module counts as loaded, or restart would start its repair path
    printf '#!/bin/bash\necho "amneziawg 123456 0"\n' > "$TEST_DIR/bin/lsmod"
    chmod +x "$TEST_DIR/bin/lsmod"
    unset AWG_SKIP_APPLY
    _m "$s" restart; _ok
    export AWG_SKIP_APPLY=1
    _same "$base"
}
_e_restart_31() { _e_restart "$1" 3.1; }
_e_restart_20() { _e_restart "$1" 2.0; }
@test "lifecycle: restart leaves the installation as it was (3.1)" {
    _both _e_restart_31
}
@test "lifecycle: restart leaves the installation as it was (2.0)" {
    _both _e_restart_20
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
    _diff_only "$base" '(client|uri):alice\|Interface\|DNS\||urimeta:alice\|\.dns[12]\|'
    _print | grep -qx 'client:alice|Interface|DNS|9.9.9.9'
    _print | grep -qx 'uri:alice|Interface|DNS|9.9.9.9'
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
    _diff_only "$base" '(client|uri|urilast|urimeta):carol\||srv\|peer:carol\||keys\|carol\.|mode\|(keys/)?carol\.'
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

_e_expiry() {
    local s="$1" gen="$2" base="$TEST_DIR/base.print"
    _inst "$s" "$gen"
    _print "$base"
    _m "$s" add carol; _ok
    # an expiry mark long past; the check runs as the cron line runs it, with the
    # cron file pointed away from the host
    mkdir -p "$A/expiry"
    printf '1\n' > "$A/expiry/carol"
    run --separate-stderr env AWG_DIR="$A" CONFIG_FILE="$A/awgsetup_cfg.init" \
        SERVER_CONF_FILE="$SC" EXPIRY_CRON="$TEST_DIR/awg-expiry" \
        timeout 60 /bin/bash -c 'source "$AWG_DIR/awg_common.sh" || exit 1; trap _awg_cleanup EXIT; check_expired_clients'
    _ok
    [[ ! -e "$A/carol.conf" && ! -e "$A/keys/carol.private" ]]
    _same "$base"
}
_e_expiry_31() { _e_expiry "$1" 3.1; }
_e_expiry_20() { _e_expiry "$1" 2.0; }
@test "lifecycle: an expired client goes, the rest of the installation stays (3.1)" {
    _both _e_expiry_31
}
@test "lifecycle: an expired client goes, the rest of the installation stays (2.0)" {
    _both _e_expiry_20
}

_e_manual_params() {
    local s="$1" gen="$2" base="$TEST_DIR/base.print"
    _inst "$s" "$gen"
    _print "$base"
    # a hand edit of the live server config, then regen of every client: on a
    # live install awg0.conf is the source of the parameters, the key stays
    sed -i 's|^S1 = .*|S1 = 80|; s|^Jc = .*|Jc = 4|' "$SC"
    _m "$s" regen; _ok
    _diff_only "$base" '(srv|client:[a-z]+|uri:[a-z]+)\|Interface\|(S1|Jc)\||urilast:[a-z]+\|(S1|Jc)\|'
    _print | grep -qx 'client:alice|Interface|S1|80'
    _print | grep -qx 'client:bob|Interface|Jc|4'
}
_e_manual_params_31() { _e_manual_params "$1" 3.1; }
_e_manual_params_20() { _e_manual_params "$1" 2.0; }
@test "lifecycle: a hand-edited server parameter reaches the clients by regen, the key stays (3.1)" {
    _both _e_manual_params_31
}
@test "lifecycle: a hand-edited server parameter reaches the clients by regen (2.0)" {
    _both _e_manual_params_20
}

# ---------- G2.5: step 6 of the installer, real step and real library ----------
#
# _s6 <installer> : run the installer's step6_generate_configs with the real
# library of the same language. Stubbed: the system commands (PATH stubs from
# setup), the log, update_state, die and secure_files (absolute /etc paths).
_s6() {
    local inst="$1" lib=awg_common.sh
    [[ "$inst" == *_en.sh ]] && lib=awg_common_en.sh
    cp "$BATS_TEST_DIRNAME/../$lib" "$A/awg_common.sh"
    local ver
    ver=$(sed -n 's/^SCRIPT_VERSION="\(.*\)"$/\1/p' "$BATS_TEST_DIRNAME/../$inst")
    run --separate-stderr env AWG_DIR="$A" KEYS_DIR="$A/keys" SERVER_CONF_FILE="$SC" \
        SCRIPT_VERSION="$ver" AWG_MAIN_NIC=eth0 \
        CONFIG_FILE="$A/awgsetup_cfg.init" COMMON_SCRIPT_PATH="$A/awg_common.sh" \
        MANAGE_SCRIPT_PATH="$A/manage_amneziawg.sh" LOG_FILE="$TEST_DIR/s6.log" \
        timeout 120 bash -c '
        log() { :; }; log_warn() { echo "WARN: $*"; }; log_error() { echo "ERR: $*"; }; log_debug() { :; }
        die() { echo "DIE: $*"; exit 1; }
        update_state() { :; }
        secure_files() { :; }
        eval "$(awk "/^_check_loaded_library\\(\\) \\{/,/^\\}/" "$1")"
        eval "$(awk "/^_step6_undo_31\\(\\) \\{/,/^\\}/" "$1")"
        eval "$(awk "/^step6_generate_configs\\(\\) \\{/,/^\\}/" "$1")"
        declare -F step6_generate_configs _check_loaded_library _step6_undo_31 >/dev/null || { echo NO_STEP6; exit 7; }
        step6_generate_configs
        echo "RC=$?"
    ' _ "$BATS_TEST_DIRNAME/../$inst"
}

_s6_ok() {
    # an error that step 6 only logs (a 2.0 client that failed) is a failure too
    [[ "$status" -eq 0 && "$output" == *"RC=0"* && "$output" != *"DIE:"* && "$output" != *"ERR:"* ]] && return 0
    printf 'step 6 failed, rc %s\n--- stdout\n%s\n--- stderr\n%s\n' "$status" "$output" "$stderr" >&2
    return 1
}

# _fresh <2.0|3.1> : the state step 6 meets on a first install
_fresh() {
    sed -i '/AWG_PROTOCOL/d; /AWG_CPA/d' "$A/awgsetup_cfg.init"
    printf "export AWG_PROTOCOL='%s'\n" "$1" >> "$A/awgsetup_cfg.init"
    # step 0 writes the padding range into the init on 3.1 (generate_awg_params)
    [[ "$1" == 3.1 ]] && printf "export AWG_CPA='32-128'\n" >> "$A/awgsetup_cfg.init"
    # a CPS packet, as step 0 makes by default
    sed -i '/AWG_I1=/d' "$A/awgsetup_cfg.init"
    printf "export AWG_I1='<r 32>'\n" >> "$A/awgsetup_cfg.init"
    rm -f "$SC"
}

_bothi() {
    local s
    for s in install_amneziawg.sh install_amneziawg_en.sh; do
        echo "# twin: $s" >&3
        "$1" "$s"
        teardown; setup
    done
}

_e5a() {
    local inst="$1" gen="$2" base="$TEST_DIR/base.print" man=manage_amneziawg.sh
    [[ "$inst" == *_en.sh ]] && man=manage_amneziawg_en.sh
    _fresh "$gen"
    _s6 "$inst"; _s6_ok
    # a client added after the install must survive the repeat as well
    _m "$BATS_TEST_DIRNAME/../$man" add alice; _ok
    _print "$base"
    _s6 "$inst"; _s6_ok
    _same "$base"
}
_e5a_31() { _e5a "$1" 3.1; }
_e5a_20() { _e5a "$1" 2.0; }
@test "lifecycle E5a: step 6 again on a finished install (the --force path) changes nothing (3.1)" {
    _bothi _e5a_31
}
@test "lifecycle E5a: step 6 again on a finished install changes nothing (2.0)" {
    _bothi _e5a_20
}

_e5b() {
    local inst="$1" priv
    _fresh 3.1
    # step 6 broke off right after the key: server keys and server_hpk.key only
    priv=$(head -c32 /dev/urandom | base64)
    ( umask 077
      printf '%s\n' "$priv" > "$A/server_private.key"
      printf '%s' "$priv" | awg pubkey > "$A/server_public.key"
      printf '%s\n' "$K2" > "$A/server_hpk.key" )
    _s6 "$inst"; _s6_ok
    # the key that was there is the key everywhere: file, config, both default
    # clients, both links twice
    [ "$(_hpk_count "$K2")" -eq 8 ]
    # and the server keys made before the break are the ones in use
    [ "$(cat "$A/server_private.key")" = "$priv" ]
    _print | grep -qxF "srv|Interface|PrivateKey|$priv"
}
@test "lifecycle E5b: step 6 after a break right after the key keeps that key" {
    _bothi _e5b
}

_e5c() {
    local inst="$1" base="$TEST_DIR/base.print" man=manage_amneziawg.sh
    [[ "$inst" == *_en.sh ]] && man=manage_amneziawg_en.sh
    _fresh 3.1
    _s6 "$inst"; _s6_ok
    _print "$base"
    rm "$A/server_hpk.key"
    _s6 "$inst"; _s6_ok
    _same "$base"
    # the manage side restores a lost key file the same way
    rm "$A/server_hpk.key"
    _m "$BATS_TEST_DIRNAME/../$man" regen my_phone; _ok
    _same "$base"
}
@test "lifecycle E5c: a lost key file comes back from the config, in step 6 and in manage" {
    _bothi _e5c
}

# ---------- G2.15: the whole installer, step 0 and step 6 ----------
#
# _inst_run <installer> <args...> : the real installer from a copy where only
# the paths point into the sandbox and the main loop is cut after step 0
# (AWG_TEST_STEP3=1 runs step 3 after it, AWG_TEST_STEP6=1 step 6). Everything else is the real script:
# argument parsing, the --force guard, initialize_setup with the real init
# heredoc and state file. `id -u` answers 0; systemctl answers is-active with
# success unless $TEST_DIR/inactive exists (a resume after reboot).
_inst_run() {
    local inst="$BATS_TEST_DIRNAME/../$1" copy="$TEST_DIR/inst.sh" lib=awg_common.sh n
    shift
    [[ "$inst" == *_en.sh ]] && lib=awg_common_en.sh
    cp "$BATS_TEST_DIRNAME/../$lib" "$A/awg_common.sh"
    mkdir -p "$TEST_DIR/sysnet"
    sed -e "s|^AWG_DIR=\"/root/awg\"\$|AWG_DIR=\"$A\"|" \
        -e "s|^SERVER_CONF_FILE=\"/etc/amnezia/amneziawg/awg0.conf\"\$|SERVER_CONF_FILE=\"$SC\"|" \
        -e "s|^SYS_NET_DIR=\"/sys/class/net\"\$|SYS_NET_DIR=\"$TEST_DIR/sysnet\"|" \
        -e "s|/etc/amnezia|$TEST_DIR/etc-amnezia|g" \
        -e '/^while (( current_step < 99 )); do$/,$d' "$inst" > "$copy"
    # every substitution must have happened, or the run would touch the host
    # (secure_files in step 6 chmods /etc/amnezia by literal path)
    n=$(grep -cxF -e "AWG_DIR=\"$A\"" -e "SERVER_CONF_FILE=\"$SC\"" -e "SYS_NET_DIR=\"$TEST_DIR/sysnet\"" "$copy")
    [ "$n" -eq 3 ] || { echo "path substitution failed ($n of 3)" >&2; return 1; }
    if grep -q '/etc/amnezia' "$copy"; then echo "/etc/amnezia left in the copy" >&2; return 1; fi
    if grep -q '^while (( current_step < 99 ))' "$copy"; then echo "main loop not cut" >&2; return 1; fi
    # UNLOCK31=1: the locally unblocked copy the plan prescribes until phase F5,
    # made by removing exactly the two lines F5 removes from the gate
    if [[ "${UNLOCK31:-0}" == 1 ]]; then
        sed -i "/^    printf 'not_implemented_yet'\$/{N;/\n    return 0\$/d}" "$copy"
        ! grep -q "^    printf 'not_implemented_yet'\$" "$copy" || { echo "unlock failed" >&2; return 1; }
    fi
    cat >> "$copy" << 'TAIL'
echo "STEP0_DONE step=$current_step"
if [[ -n "${AWG_TEST_STEP3:-}" ]]; then step3_check_module || { echo "STEP3_RC=$?"; exit 1; }; echo "STEP3_DONE"; fi
if [[ -n "${AWG_TEST_STEP6:-}" ]]; then step6_generate_configs || { echo "STEP6_RC=$?"; exit 1; }; echo "STEP6_DONE"; fi
exit 0
TAIL
    run --separate-stderr env AWG_MAIN_NIC=eth0 timeout 120 bash "$copy" "$@"
}

_inst_stubs() {
    printf '#!/bin/bash\nif [[ "$1" == -u ]]; then echo 0; exit 0; fi\nexec /usr/bin/id "$@"\n' > "$TEST_DIR/bin/id"
    cat > "$TEST_DIR/bin/systemctl" << STUB
#!/bin/bash
echo "systemctl \$*" >> "$TEST_DIR/systemctl.log"
if [[ "\$1" == is-active ]]; then [[ ! -e "$TEST_DIR/inactive" ]]; exit; fi
exit 0
STUB
    printf '#!/bin/bash\nexit 0\n' > "$TEST_DIR/bin/ss"
    # step 3: the module counts as loaded (so nothing goes to /etc/modules-load.d)
    printf '#!/bin/bash\necho "amneziawg 123456 0"\n' > "$TEST_DIR/bin/lsmod"
    printf '#!/bin/bash\necho "vermagic:       6.8.0-45-generic SMP preempt mod_unload"\n' > "$TEST_DIR/bin/modinfo"
    printf '#!/bin/bash\necho "modprobe $*" >> "%s/awg.log"\nexit 1\n' "$TEST_DIR" > "$TEST_DIR/bin/modprobe"
    # the test host may be a container (WSL, a CI runner); the install target is not
    printf '#!/bin/bash\necho none\n' > "$TEST_DIR/bin/systemd-detect-virt"
    printf '#!/bin/bash\nexit 0\n' > "$TEST_DIR/bin/chown"
    chmod +x "$TEST_DIR/bin/id" "$TEST_DIR/bin/systemctl" "$TEST_DIR/bin/ss" "$TEST_DIR/bin/chown" "$TEST_DIR/bin/systemd-detect-virt" "$TEST_DIR/bin/lsmod" "$TEST_DIR/bin/modinfo" "$TEST_DIR/bin/modprobe"
}

_run_ok() {
    [[ "$status" -eq 0 && "$output" == *"STEP0_DONE"* ]] && return 0
    printf 'installer run failed, rc %s\n--- stdout\n%s\n--- stderr\n%s\n' "$status" "$output" "$stderr" >&2
    return 1
}

# a finished install of that generation, made by the real step 6
_finished() {
    local inst="$1" gen="$2"
    _fresh "$gen"
    _s6 "$inst"; _s6_ok
    # on 2.0 a failed default client is only a warning: make sure both exist
    [[ -f "$A/my_phone.conf" && -f "$A/my_laptop.conf" ]]
}

_e6_force() {
    local inst="$1" gen="$2" base="$TEST_DIR/base.print"
    _inst_stubs
    _finished "$inst" "$gen"
    _print "$base"
    # without --force the live install is left alone: the guard exits 0 and
    # names --force
    _inst_run "$inst" --yes --ssh-port=22
    [ "$status" -eq 0 ]
    [[ "$output" != *STEP0_DONE* && "$output$stderr" == *--force* ]]
    _same "$base"
    AWG_TEST_STEP6=1 _inst_run "$inst" --force --yes --ssh-port=22
    _run_ok
    [[ "$output" == *STEP6_DONE* ]]
    # the first real run writes the full init: keys may be added, none of the
    # facts before may change or go
    _kept "$base"
    # from then on a repeat changes nothing at all
    _print "$base"
    AWG_TEST_STEP6=1 _inst_run "$inst" --force --yes --ssh-port=22
    _run_ok
    _same "$base"
}
_e6_force_31() { UNLOCK31=1 _e6_force "$1" 3.1; }
_e6_force_20() { _e6_force "$1" 2.0; }
@test "lifecycle E6: the real installer with --force keeps the generation, init and key (3.1)" {
    _bothi _e6_force_31
}
@test "lifecycle E6: the real installer with --force keeps the generation and init (2.0)" {
    _bothi _e6_force_20
}

_e7_refuse_down() {
    local inst="$1" base="$TEST_DIR/base.print" sums="$TEST_DIR/sums"
    _inst_stubs
    _finished "$inst" 3.1
    AWG_TEST_STEP6=1 _inst_run "$inst" --force --yes --ssh-port=22; _run_ok
    _print "$base"
    ( cd "$A" && find . -type f ! -name '*.log' -print0 | LC_ALL=C sort -z | xargs -0 sha256sum ) > "$sums"
    sha256sum "$SC" >> "$sums"
    AWG_TEST_STEP6=1 _inst_run "$inst" --force --protocol=2.0 --yes --ssh-port=22
    [ "$status" -ne 0 ]
    [[ "$output$stderr" == *--uninstall* && "$output$stderr" == *--protocol=2.0* ]]
    _same "$base"
    # byte for byte, not only the fingerprint
    ( cd "$A" && find . -type f ! -name '*.log' -print0 | LC_ALL=C sort -z | xargs -0 sha256sum ) > "$sums.after"
    sha256sum "$SC" >> "$sums.after"
    diff "$sums" "$sums.after"
}
@test "lifecycle E7: --force --protocol=2.0 on a 3.1 install refuses and changes no byte" {
    UNLOCK31=1 _bothi _e7_refuse_down
}

_e9_two_resumes() {
    local inst="$1" gen="$2" init_before
    _inst_stubs
    : > "$TEST_DIR/inactive"
    _fresh "$gen"
    init_before=$(cat "$A/awgsetup_cfg.init")
    # first run: an install with a 3.1 or 2.0 init, up to the end of step 0
    _inst_run "$inst" --yes --ssh-port=22 --protocol="$gen"
    if [[ "$gen" == 3.1 && "${UNLOCK31:-0}" != 1 ]]; then
        # the 3.1 path is closed until F5: the pre gate refuses, by its reason
        # code, before step 0 writes anything
        [ "$status" -ne 0 ]
        [[ "$output" != *STEP0_DONE* && "$output$stderr" == *not_implemented_yet* ]]
        [[ "$(cat "$A/awgsetup_cfg.init")" == "$init_before" ]]
        return 0
    fi
    _run_ok
    printf '3\n' > "$A/setup_state"
    init_before=$(grep -v '^#' "$A/awgsetup_cfg.init")
    # two resumes after reboot, no flags: the init is read back and written again
    _inst_run "$inst" --yes --ssh-port=22; _run_ok
    [[ "$output" == *"STEP0_DONE step=3"* ]]
    _inst_run "$inst" --yes --ssh-port=22; _run_ok
    [[ "$output" == *"STEP0_DONE step=3"* ]]
    diff <(printf '%s\n' "$init_before") <(grep -v '^#' "$A/awgsetup_cfg.init")
}
_e9_20() { _e9_two_resumes "$1" 2.0; }
_e9_31_locked() { _e9_two_resumes "$1" 3.1; }
_e9_31() { UNLOCK31=1 _e9_two_resumes "$1" 3.1; }
@test "lifecycle E9: an install with a 3.1 init is refused while the path is closed" {
    _bothi _e9_31_locked
}
@test "lifecycle E9: two resumes without flags keep the init as written (3.1, unblocked copy)" {
    _bothi _e9_31
}
@test "lifecycle E9: two resumes without flags keep the init as written (2.0)" {
    _bothi _e9_20
}

# _hpk_of : the key of the current installation, from its fingerprint
_hpk_of() { _print | sed -n 's/^hpkfile|//p'; }

# _e_force_preset <installer> <flags...> : --force with flags that regenerate
# the parameter set
_e_force_preset() {
    local inst="$1" man=manage_amneziawg.sh base="$TEST_DIR/base.print" key
    shift
    [[ "$inst" == *_en.sh ]] && man=manage_amneziawg_en.sh
    _inst_stubs
    _finished "$inst" 3.1
    AWG_TEST_STEP6=1 _inst_run "$inst" --force --yes --ssh-port=22; _run_ok
    _print "$base"
    key=$(_hpk_of)
    [[ -n "$key" ]]
    # --preset regenerates the whole parameter set: the server moves at once,
    # the clients follow by regen, as the installer says; the key never moves
    AWG_TEST_STEP6=1 _inst_run "$inst" --force "$@" --yes --ssh-port=22; _run_ok
    _m "$BATS_TEST_DIRNAME/../$man" regen; _ok
    local params='(Jc|Jmin|Jmax|S[1-4]|H[1-4]|I[1-5])'
    _diff_only "$base" "init\\|AWG_(Jc|Jmin|Jmax|S[1-4]|H[1-4]|I[1-5]|PRESET)\\||(srv|client:[a-z_]+|uri:[a-z_]+)\\|Interface\\|$params\\||urilast:[a-z_]+\\|$params\\|"
    # the new set did reach the server (fresh H ranges), and the clients follow
    # it (gen_print refuses any S/H mismatch between a client and the server)
    [[ "$(grep '^srv|Interface|H1|' "$base")" != "$(_print | grep '^srv|Interface|H1|')" ]]
    [ "$(_hpk_count "$key")" -eq 8 ]
}
_e_force_preset_mobile() { _e_force_preset "$1" --preset=mobile; }
_e_force_preset_jc() { _e_force_preset "$1" --jc=5; _print | grep -qx 'srv|Interface|Jc|5'; }
@test "lifecycle: --force --preset regenerates the parameters but never the key (3.1, unblocked copy)" {
    UNLOCK31=1 _bothi _e_force_preset_mobile
}
@test "lifecycle: --force --jc regenerates the parameters but never the key (3.1, unblocked copy)" {
    UNLOCK31=1 _bothi _e_force_preset_jc
}

_e_force_no_cps() {
    local inst="$1" gen="$2" base="$TEST_DIR/base.print"
    _inst_stubs
    _finished "$inst" "$gen"
    AWG_TEST_STEP6=1 _inst_run "$inst" --force --yes --ssh-port=22; _run_ok
    _print "$base"
    grep -q '^srv|Interface|I1|' "$base"
    AWG_TEST_STEP6=1 _inst_run "$inst" --force --no-cps --yes --ssh-port=22; _run_ok
    # I1 leaves the server and the init; nothing else moves, the key included
    _diff_only "$base" 'init\|(AWG_I1|NO_CPS)\||srv\|Interface\|I1\|'
    _print > "$TEST_DIR/after.print"
    if grep -q '^srv|Interface|I1|' "$TEST_DIR/after.print"; then echo "I1 still on the server" >&2; return 1; fi
    grep -qx 'init|NO_CPS|1' "$TEST_DIR/after.print"
    if grep -q '^init|AWG_I1|.' "$TEST_DIR/after.print"; then echo "AWG_I1 still in the init" >&2; return 1; fi
}
_e_force_no_cps_31() { UNLOCK31=1 _e_force_no_cps "$1" 3.1; }
_e_force_no_cps_20() { _e_force_no_cps "$1" 2.0; }
@test "lifecycle: --force --no-cps drops I1 and nothing else (3.1, unblocked copy)" {
    _bothi _e_force_no_cps_31
}
@test "lifecycle: --force --no-cps drops I1 and nothing else (2.0)" {
    _bothi _e_force_no_cps_20
}

_e8_post_refused() {
    local inst="$1" sums="$TEST_DIR/sums"
    _inst_stubs
    : > "$TEST_DIR/inactive"
    # the pre gate passes (unblocked copy), the module turns out second line
    : > "$TEST_DIR/module_line2"
    _fresh 3.1
    # an unfinished 3.1 install resumed at step 3: init and state, nothing else
    printf '3\n' > "$A/setup_state"
    # one step-0-only resume first: it writes the full init the real run keeps
    _inst_run "$inst" --yes --ssh-port=22; _run_ok
    ( cd "$A" && find . -type f ! -name '*.log' ! -name '*.lock' ! -name awg_common.sh -print0 | LC_ALL=C sort -z | xargs -0 sha256sum ) > "$sums"
    AWG_TEST_STEP3=1 _inst_run "$inst" --yes --ssh-port=22
    [ "$status" -ne 0 ]
    # step 0 passed: the refusal is the post check of step 3, not the pre gate
    [[ "$output" == *STEP0_DONE* && "$output" != *STEP3_DONE* ]]
    [[ "$output$stderr" == *module_line2* ]]
    [ "$(cat "$A/setup_state")" = 3 ]
    [[ ! -e "$SC" && ! -e "$A/server_hpk.key" && ! -e "$A/server_private.key" ]]
    # the run itself writes nothing but its log and lock files
    ( cd "$A" && find . -type f ! -name '*.log' ! -name '*.lock' ! -name awg_common.sh -print0 | LC_ALL=C sort -z | xargs -0 sha256sum ) > "$sums.after"
    diff "$sums" "$sums.after"
}
@test "lifecycle E8: a refused post check at step 3 leaves the install as it was" {
    UNLOCK31=1 _bothi _e8_post_refused
}

# Found on the stand 1 oct 2026: --force runs step 1, which reboots; after the
# reboot the service is up again, and a resume run without --force met the
# "already installed, add --force" guard, exited 0 and left setup_state=2, so
# steps 2-7 never ran. A state file means an install is under way: the resume
# must carry on, and without a state file the guard still protects.
_e11_resume_force() {
    local inst="$1" st
    _inst_stubs
    _finished "$inst" 2.0
    # the two states a reboot asked for by the installer leaves: the resume
    # carries on without the flag
    for st in 2 3; do
        printf '%s\n' "$st" > "$A/setup_state"
        _inst_run "$inst" --yes --ssh-port=22
        _run_ok
        [[ "$output" == *"STEP0_DONE step=$st"* ]]
    done
    # anything else on a live server is not a resume: the guard stands, exits 0
    # and names --force (a stuck 7 or 99, garbage, an empty file, no file)
    for st in 7 99 junk empty none; do
        case "$st" in
            empty) : > "$A/setup_state" ;;
            none)  rm -f "$A/setup_state" ;;
            *)     printf '%s\n' "$st" > "$A/setup_state" ;;
        esac
        _inst_run "$inst" --yes --ssh-port=22
        [ "$status" -eq 0 ] || { echo "state $st: rc $status" >&2; return 1; }
        [[ "$output" != *STEP0_DONE* ]] || { echo "state $st: the install ran" >&2; return 1; }
        [[ "$output$stderr" == *--force* ]] || { echo "state $st: no guard text" >&2; return 1; }
    done
}
@test "lifecycle E11: a resume after the reboot of a --force run carries on without the flag" {
    _bothi _e11_resume_force
}

_e10_legacy_init() {
    local inst="$1" base="$TEST_DIR/base.print"
    _inst_stubs
    _finished "$inst" 2.0
    AWG_TEST_STEP6=1 _inst_run "$inst" --force --yes --ssh-port=22; _run_ok
    _print "$base"
    # scripts updated on a server whose init predates the marker
    sed -i '/AWG_PROTOCOL/d' "$A/awgsetup_cfg.init"
    AWG_TEST_STEP6=1 _inst_run "$inst" --force --yes --ssh-port=22; _run_ok
    grep -qx "export AWG_PROTOCOL='2.0'" "$A/awgsetup_cfg.init"
    _same "$base"
}
@test "lifecycle E10: an init without the marker stays 2.0 through --force and step 6" {
    _bothi _e10_legacy_init
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
_e3_20_onto_20() { _e3 "$1" 2.0 "" 2.0 ""; }
@test "lifecycle E3: restore of a 2.0 archive onto 2.0 brings back the archive exactly" {
    _both _e3_20_onto_20
}

# An archive without clients/ at all (made by hand or by an old version):
# restore has nothing to put back for the clients, and the live client files
# stay. (An EMPTY clients/ is a different, documented case: a server without
# client files, and restore clears them.)
_e3_no_clients() {
    local s="$1" base="$TEST_DIR/base.print" path d
    _inst "$s" 3.1
    _print "$base"
    path=$(_backup "$s")
    [[ -f "$path" ]]
    d=$(mktemp -d "$TEST_DIR/retar-XXXXXX")
    tar -xzf "$path" -C "$d"
    [[ -d "$d/clients" ]]
    find "$d/clients" -delete
    tar -czf "$TEST_DIR/noclients.tar.gz" -C "$d" .
    _m "$s" restore "$TEST_DIR/noclients.tar.gz"; _ok
    _same "$base"
}
@test "lifecycle E3: restore of an archive without client files keeps the live clients" {
    _both _e3_no_clients
}
