#!/usr/bin/env bats
# Which apply mode (syncconf or restart) a manage command actually uses.
#
# restart is the workaround for the kernel module deadlock on fast add/remove
# (amneziawg-linux-kernel-module#146), so choosing it must take effect on every
# path that applies the config. Two gaps made it a no-op:
#   * add: generate_client -> load_awg_params -> safe_load_config exported
#     AWG_APPLY_MODE from awgsetup_cfg.init (the installer writes
#     ${AWG_APPLY_MODE:-syncconf} there, so 'syncconf' on a default install),
#     overriding --apply-mode=restart and the environment;
#   * remove and the expiry cron job never load init, and apply_config read only
#     the environment, so a 'restart' saved in init was ignored.
# Now a mode set before the call wins over init, and apply_config falls back to
# the value saved in init when nothing else set it.
#
# Every case runs the real manage script (or the cron command line) with all
# host commands stubbed and logged; nothing touches the system, the network or
# /etc/cron.d (EXPIRY_CRON points into the test directory). Each case runs for
# both twins: the RU and EN scripts each carry their own copies.

bats_require_minimum_version 1.5.0

MANAGE_RU="${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"
MANAGE_EN="${BATS_TEST_DIRNAME}/../manage_amneziawg_en.sh"

setup() {
    command -v flock &>/dev/null || skip "flock not available (not Linux)"
    ORIG_PATH="$PATH"
    SB="$BATS_TEST_TMPDIR/sb"
    A="$SB/awg"
    CALLS="$SB/calls.log"
    mkdir -p "$SB/bin" "$A/keys"
    : > "$CALLS"
    export EXPIRY_CRON="$BATS_TEST_TMPDIR/cron.d/awg-expiry"
    mkdir -p "$(dirname "$EXPIRY_CRON")"
    unset AWG_APPLY_MODE AWG_SKIP_APPLY

    cat > "$SB/bin/awg" << STUB
#!/bin/bash
case "\$1" in
    genkey|genpsk) echo "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ;;
    pubkey) cat >/dev/null; echo "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=" ;;
    syncconf) echo "awg \$*" >> "$CALLS"; cat >/dev/null ;;
    *) exit 0 ;;
esac
STUB
    cat > "$SB/bin/awg-quick" << STUB
#!/bin/bash
echo "awg-quick \$*" >> "$CALLS"
echo "[Interface]"
STUB
    cat > "$SB/bin/systemctl" << STUB
#!/bin/bash
echo "systemctl \$*" >> "$CALLS"
exit 0
STUB
    cat > "$SB/bin/lsmod" << 'STUB'
#!/bin/bash
echo "Module                  Size  Used by"
echo "amneziawg             1      0"
STUB
    cat > "$SB/bin/qrencode" << 'STUB'
#!/bin/bash
out=""
while [ $# -gt 0 ]; do
    if [ "$1" = "-o" ]; then shift; out="$1"; fi
    shift
done
[ -n "$out" ] || exit 1
cat > "$out"
STUB
    local t
    for t in curl wget ip modprobe; do
        printf '#!/bin/bash\necho "%s $*" >> "%s"\nexit 1\n' "$t" "$CALLS" > "$SB/bin/$t"
    done
    chmod +x "$SB/bin/"*
    export PATH="$SB/bin:$PATH"

    cat > "$A/awgsetup_cfg.init" << 'CONF'
export AWG_PORT=39743
export AWG_TUNNEL_SUBNET='10.9.9.1/24'
export DISABLE_IPV6=1
export ALLOWED_IPS_MODE=1
export ALLOWED_IPS='0.0.0.0/0'
export AWG_ENDPOINT='203.0.113.10'
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
CONF
    cat > "$A/awg0.conf" << 'CONF'
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
CONF
}

teardown() {
    export PATH="$ORIG_PATH"
    hash -r
}

use_lang() {  # use_lang ru|en
    if [[ "$1" == "en" ]]; then
        MANAGE="$MANAGE_EN"
        cp "$BATS_TEST_DIRNAME/../awg_common_en.sh" "$A/awg_common.sh"
    else
        MANAGE="$MANAGE_RU"
        cp "$BATS_TEST_DIRNAME/../awg_common.sh" "$A/awg_common.sh"
    fi
}

set_init_mode() {  # set_init_mode syncconf|restart
    sed -i "s/^export AWG_APPLY_MODE=.*/export AWG_APPLY_MODE='$1'/" "$A/awgsetup_cfg.init"
    grep -qxF "export AWG_APPLY_MODE='$1'" "$A/awgsetup_cfg.init"
}

mgmt() {  # mgmt <manage args...>
    bash "$MANAGE" "$@" --yes --conf-dir="$A" --server-conf="$A/awg0.conf"
}

# A client created offline, then the call log cleared.
precreate_client() {
    AWG_SKIP_APPLY=1 mgmt add "$1" >/dev/null 2>&1
    grep -qxF "#_Name = $1" "$A/awg0.conf"
    : > "$CALLS"
}

assert_restart_used() {
    if ! grep -qxF "systemctl restart awg-quick@awg0" "$CALLS"; then
        echo "expected 'systemctl restart awg-quick@awg0', calls were:" >&2
        cat "$CALLS" >&2
        return 1
    fi
    if grep -q "syncconf" "$CALLS"; then
        echo "syncconf used although the apply mode is restart, calls were:" >&2
        cat "$CALLS" >&2
        return 1
    fi
    no_network
}

assert_syncconf_used() {
    if ! grep -qxF "awg syncconf awg0 /dev/stdin" "$CALLS"; then
        echo "expected 'awg syncconf awg0 /dev/stdin', calls were:" >&2
        cat "$CALLS" >&2
        return 1
    fi
    if grep -qxF "systemctl restart awg-quick@awg0" "$CALLS"; then
        echo "restart used although the apply mode is syncconf, calls were:" >&2
        cat "$CALLS" >&2
        return 1
    fi
    no_network
}

no_network() {
    if grep -qE '^(curl|wget) ' "$CALLS"; then
        echo "a network tool was called:" >&2
        cat "$CALLS" >&2
        return 1
    fi
}

# --------------------------------------------------------------------- add

check_add_cli_restart() {
    use_lang "$1"
    set_init_mode syncconf
    run mgmt add alice --apply-mode=restart
    [ "$status" -eq 0 ]
    grep -qxF "#_Name = alice" "$A/awg0.conf"
    assert_restart_used
}

@test "add --apply-mode=restart wins over init 'syncconf' (RU)" { check_add_cli_restart ru; }
@test "add --apply-mode=restart wins over init 'syncconf' (EN)" { check_add_cli_restart en; }

check_add_env_restart() {
    use_lang "$1"
    set_init_mode syncconf
    AWG_APPLY_MODE=restart run mgmt add alice
    [ "$status" -eq 0 ]
    grep -qxF "#_Name = alice" "$A/awg0.conf"
    assert_restart_used
}

@test "add with AWG_APPLY_MODE=restart in the environment wins over init (RU)" { check_add_env_restart ru; }
@test "add with AWG_APPLY_MODE=restart in the environment wins over init (EN)" { check_add_env_restart en; }

check_add_cli_syncconf() {
    use_lang "$1"
    set_init_mode restart
    run mgmt add alice --apply-mode=syncconf
    [ "$status" -eq 0 ]
    grep -qxF "#_Name = alice" "$A/awg0.conf"
    assert_syncconf_used
}

@test "add --apply-mode=syncconf wins over init 'restart' (RU)" { check_add_cli_syncconf ru; }
@test "add --apply-mode=syncconf wins over init 'restart' (EN)" { check_add_cli_syncconf en; }

# ------------------------------------------------------------------ remove

check_remove_init_restart() {
    use_lang "$1"
    set_init_mode restart
    precreate_client pre
    run mgmt remove pre
    [ "$status" -eq 0 ]
    if grep -qxF "#_Name = pre" "$A/awg0.conf"; then
        echo "client 'pre' is still in awg0.conf" >&2
        return 1
    fi
    assert_restart_used
}

@test "remove applies with the 'restart' saved in init (RU)" { check_remove_init_restart ru; }
@test "remove applies with the 'restart' saved in init (EN)" { check_remove_init_restart en; }

# -------------------------------------------------------------------- cron

# The same command line install_expiry_cron writes to /etc/cron.d/awg-expiry,
# with the environment the cron file sets and no AWG_APPLY_MODE.
check_cron_init_restart() {
    use_lang "$1"
    set_init_mode restart
    precreate_client old
    mkdir -p "$A/expiry"
    echo 1 > "$A/expiry/old"
    run env -u AWG_APPLY_MODE AWG_DIR="$A" CONFIG_FILE="$A/awgsetup_cfg.init" \
        SERVER_CONF_FILE="$A/awg0.conf" EXPIRY_CRON="$EXPIRY_CRON" \
        /bin/bash -c 'source "${AWG_DIR}/awg_common.sh" || exit 1; trap _awg_cleanup EXIT; check_expired_clients'
    [ "$status" -eq 0 ]
    if grep -qxF "#_Name = old" "$A/awg0.conf"; then
        echo "expired client 'old' is still in awg0.conf" >&2
        return 1
    fi
    [ ! -e "$A/expiry/old" ]
    assert_restart_used
}

@test "cron check_expired_clients applies with the 'restart' saved in init (RU)" { check_cron_init_restart ru; }
@test "cron check_expired_clients applies with the 'restart' saved in init (EN)" { check_cron_init_restart en; }

# ------------------------------------------------------------- init parsing

# apply_config reads init with the same parser as load_awg_params, so a file
# saved with a BOM and CRLF line ends still yields 'restart' on the remove path.
check_remove_init_restart_crlf() {
    use_lang "$1"
    set_init_mode restart
    precreate_client pre
    { printf '\xef\xbb\xbf'; sed 's/$/\r/' "$A/awgsetup_cfg.init"; } > "$A/init.tmp"
    mv "$A/init.tmp" "$A/awgsetup_cfg.init"
    run mgmt remove pre
    [ "$status" -eq 0 ]
    assert_restart_used
}

@test "remove: init with BOM and CRLF still gives 'restart' (RU)" { check_remove_init_restart_crlf ru; }
@test "remove: init with BOM and CRLF still gives 'restart' (EN)" { check_remove_init_restart_crlf en; }

# An unknown mode in init or the environment used to fall to syncconf without a
# word, so a typo like 'Restart' silently lost the workaround it was set for.
# The fallback stays syncconf, but it is now named.
check_unknown_mode_named() {
    use_lang "$1"
    set_init_mode Restart
    precreate_client pre
    run --separate-stderr mgmt remove pre
    [ "$status" -eq 0 ]
    # shellcheck disable=SC2154  # $stderr is set by `run --separate-stderr`
    [[ "$stderr" == *"AWG_APPLY_MODE"*"Restart"* ]] || { echo "no warning, stderr: $stderr" >&2; return 1; }
    assert_syncconf_used
}

@test "remove: an unknown apply mode is named and falls back to syncconf (RU)" { check_unknown_mode_named ru; }
@test "remove: an unknown apply mode is named and falls back to syncconf (EN)" { check_unknown_mode_named en; }