#!/usr/bin/env bats
# The client set on a 3.1 installation is all or nothing (slice C2).
#
# A 3.1 client gets four files - the .conf, its QR, the vpn:// link and the
# link's QR - and a profile with a missing or foreign piece looks complete until
# the tunnel refuses to come up. So on 3.1:
#   - add and regen refuse BEFORE any change when qrencode or perl is missing;
#   - add whose set comes out incomplete removes the peer from awg0.conf and all
#     the client's files, and reports an error;
#   - regen whose set comes out incomplete puts the previous set back exactly
#     (a file that did not exist before is removed again).
# On 2.0 nothing changes: a missing QR stays a warning.
#
# Harness: the real manage scripts end-to-end in a sandbox, both twins, with
# stubbed awg, systemctl, ip, qrencode, curl and wget.

# shellcheck disable=SC2154  # $stderr is set by `run --separate-stderr`

bats_require_minimum_version 1.5.0

K1='BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA='
# PATH as bats started with it: every twin starts from here, whatever _hide did.
_ORIG_PATH="$PATH"

setup() {
    [[ -e /etc/cron.d/awg-expiry ]] && skip "host has /etc/cron.d/awg-expiry"
    TEST_DIR=$(mktemp -d)
    A="$TEST_DIR/awg"
    mkdir -p "$TEST_DIR/bin" "$A/keys"
    cat > "$TEST_DIR/bin/awg" << STUB
#!/bin/bash
echo "awg \$*" >> "$TEST_DIR/awg.log"
case "\$1" in
    genkey|genpsk) head -c32 /dev/urandom | base64 ;;
    pubkey) cat >/dev/null; head -c32 /dev/urandom | base64 ;;
    *) exit 0 ;;
esac
STUB
    # qrencode: writes a stand-in PNG; qr_fail_all breaks every call,
    # qr_fail_uri only the vpn:// QR (the only call with -l).
    cat > "$TEST_DIR/bin/qrencode" << STUB
#!/bin/bash
[[ -e "$TEST_DIR/qr_fail_all" ]] && exit 1
out=""; low=0
while [ \$# -gt 0 ]; do
    case "\$1" in -o) out="\$2"; shift ;; -l) low=1 ;; esac
    shift
done
cat >/dev/null
[[ \$low -eq 1 && -e "$TEST_DIR/qr_fail_uri" ]] && exit 1
[ -n "\$out" ] && printf 'PNG' > "\$out"
exit 0
STUB
    printf '#!/bin/bash\nexit 0\n' > "$TEST_DIR/bin/systemctl"
    printf '#!/bin/bash\nexit 1\n' > "$TEST_DIR/bin/ip"
    for c in curl wget; do printf '#!/bin/bash\nexit 1\n' > "$TEST_DIR/bin/$c"; done
    chmod +x "$TEST_DIR/bin/"*
    export PATH="$TEST_DIR/bin:$_ORIG_PATH"
    cat > "$A/awgsetup_cfg.init" << 'CONF'
export AWG_PORT=39743
export AWG_TUNNEL_SUBNET='10.9.9.1/24'
export DISABLE_IPV6=1
export ALLOWED_IPS_MODE=1
export ALLOWED_IPS='0.0.0.0/0'
export AWG_ENDPOINT='203.0.113.5'
CONF
    SC="$A/awg0.conf"
    MOCK_ARGS=(--conf-dir="$A" --server-conf="$SC")
    export AWG_SKIP_APPLY=1
}

teardown() {
    # first: _hide may have pointed PATH into the directory removed below
    export PATH="$_ORIG_PATH"
    unset AWG_SKIP_APPLY
    [[ -n "${TEST_DIR:-}" ]] && rm -rf "$TEST_DIR"
}

# _gen <2.0|3.1> : a consistent installation of that generation
_gen() {
    sed -i '/AWG_PROTOCOL/d' "$A/awgsetup_cfg.init"
    printf "export AWG_PROTOCOL='%s'\n" "$1" >> "$A/awgsetup_cfg.init"
    {
        printf '[Interface]\nPrivateKey = TESTKEY\n'
        [[ "$1" == 3.1 ]] && printf 'HeaderProtectionKey = %s\nContentPaddingAddition = 32-128\n' "$K1"
        printf 'Address = 10.9.9.1/24\nMTU = 1280\nListenPort = 39743\n'
        printf 'Jc = 6\nJmin = 55\nJmax = 380\nS1 = 72\nS2 = 56\nS3 = 32\nS4 = 16\n'
        printf 'H1 = 100000-800000\nH2 = 1000000-8000000\nH3 = 10000000-80000000\nH4 = 100000000-800000000\n'
    } > "$SC"
    chmod 600 "$SC"
    if [[ "$1" == 3.1 ]]; then
        ( umask 077; printf '%s\n' "$K1" > "$A/server_hpk.key" )
    else
        rm -f "$A/server_hpk.key"
    fi
}

# _hide <command> : the command is absent for manage even when the host has it
# (CI runners carry qrencode in /usr/bin, so deleting the stub alone hides
# nothing there and the case cannot fail). PATH becomes the stub directory plus
# a directory of links to every host command except that one.
_hide() {
    local name="$1" d f
    local -a dirs
    mkdir -p "$TEST_DIR/sysbin"
    IFS=: read -ra dirs <<< "$_ORIG_PATH"
    for d in "${dirs[@]}"; do
        # Windows directories a WSL PATH carries: thousands of files, none needed
        [[ -d "$d" && "$d" != /mnt/* ]] || continue
        for f in "$d"/*; do
            [[ -x "$f" && ! -e "$TEST_DIR/sysbin/${f##*/}" ]] || continue
            ln -s "$f" "$TEST_DIR/sysbin/${f##*/}"
        done
    done
    /bin/rm -f "$TEST_DIR/sysbin/$name" "$TEST_DIR/bin/$name"
    export PATH="$TEST_DIR/bin:$TEST_DIR/sysbin"
    if command -v "$name" >/dev/null 2>&1; then echo "_hide: $name still reachable" >&2; return 1; fi
    return 0
}

# The refusal itself, not the "qrencode not found" warning check_dependencies
# prints for any command once qrencode is hidden: that warning alone would let a
# failure for some other reason pass.
_refused_for_qrencode() {
    [[ "$output$stderr" == *"3.1 profile needs qrencode"* || "$output$stderr" == *"профиля 3.1 нужен qrencode"* ]]
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
_fail() {
    [ "$status" -ne 0 ] && return 0
    printf 'expected a failure, got rc 0\n--- stdout\n%s\n--- stderr\n%s\n' "$output" "$stderr" >&2
    return 1
}
_nope() {
    if eval "$1"; then echo "must not hold: $1" >&2; return 1; fi
    return 0
}

# _files <name> : fingerprint of every file of the client
_files() {
    local f
    for f in "$A/$1.conf" "$A/$1.png" "$A/$1.vpnuri" "$A/$1.vpnuri.png" "$A/keys/$1.private" "$A/keys/$1.public"; do
        if [[ -e "$f" ]]; then printf '%s %s\n' "${f##*/}" "$(cksum < "$f")"; else printf '%s absent\n' "${f##*/}"; fi
    done
}

# _no_trace <name> : nothing of the client is left anywhere
_no_trace() {
    # not through _nope: inside its eval "$1" would be _nope's own argument
    if grep -qxF "#_Name = $1" "$SC"; then echo "peer $1 left in $SC" >&2; return 1; fi
    [ "$(_files "$1" | grep -vc ' absent$')" -eq 0 ] || { _files "$1" >&2; return 1; }
}

# 🔴 The case function runs as a plain command, never under `||` or `if`: there
# set -e is off for the whole body and failed assertions inside are ignored.
_both() {
    local s
    for s in "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"; do
        echo "# twin: ${s##*/}" >&3
        "$1" "$s"
        teardown; setup
    done
}

# ------------------------------------------------------------------ add

_add_ok() {
    local s="$1"
    _gen 3.1
    _m "$s" add alice
    _ok
    grep -qxF "#_Name = alice" "$SC"
    [ "$(_files alice | grep -c ' absent$')" -eq 0 ]
}
@test "add on 3.1 with the tools in place gives the full set of four files" { _both _add_ok; }

_add_no_qrencode() {
    local s="$1"
    _gen 3.1
    _hide qrencode
    : > "$TEST_DIR/awg.log"
    _m "$s" add alice
    _fail
    _refused_for_qrencode
    _no_trace alice
    # refused BEFORE any change: no key was even generated (a create-then-undo
    # would leave no trace either, so this is what tells the two apart)
    _nope 'grep -q "^awg genkey" "$TEST_DIR/awg.log"'
}
@test "add on 3.1 without qrencode is refused before any change" { _both _add_no_qrencode; }

_add_incomplete_rolled_back() {
    local s="$1"
    _gen 3.1
    : > "$TEST_DIR/qr_fail_uri"
    _m "$s" add alice
    _fail
    _no_trace alice
}
@test "add on 3.1 with an incomplete set removes the peer and every file of the client" { _both _add_incomplete_rolled_back; }

_add_incomplete_others_kept() {
    local s="$1" before
    _gen 3.1
    _m "$s" add bob
    _ok
    before=$(_files bob; grep -c '^\[Peer\]' "$SC")
    : > "$TEST_DIR/qr_fail_uri"
    _m "$s" add alice
    _fail
    [ "$(_files bob; grep -c '^\[Peer\]' "$SC")" = "$before" ]
    grep -qxF "#_Name = bob" "$SC"
}
@test "the rollback of a failed add leaves the other clients untouched" { _both _add_incomplete_others_kept; }

_add_20_no_qrencode() {
    local s="$1"
    _gen 2.0
    _hide qrencode
    _m "$s" add alice
    _ok
    grep -qxF "#_Name = alice" "$SC"
    [ -f "$A/alice.conf" ]
    [ ! -e "$A/alice.png" ]
}
@test "add on 2.0 without qrencode still creates the client (unchanged)" { _both _add_20_no_qrencode; }

# ------------------------------------------------------------------ regen

_regen_restores() {
    local s="$1" before server
    _gen 3.1
    _m "$s" add alice
    _ok
    before=$(_files alice)
    server=$(cksum < "$SC")
    # a new endpoint makes the regenerated .conf differ from the old one, so a
    # set that is not put back is visible
    sed -i "s/^export AWG_ENDPOINT=.*/export AWG_ENDPOINT='203.0.113.9'/" "$A/awgsetup_cfg.init"
    : > "$TEST_DIR/qr_fail_all"
    _m "$s" regen alice
    _fail
    [ "$(_files alice)" = "$before" ] || { diff <(echo "$before") <(_files alice) >&2; return 1; }
    [ "$(cksum < "$SC")" = "$server" ]
}
@test "regen on 3.1 with an incomplete set puts the previous set back exactly" { _both _regen_restores; }

_regen_restores_absent() {
    local s="$1" before
    _gen 3.1
    _m "$s" add alice
    _ok
    # an older incomplete set: the config QR was never there. The regen creates
    # it and then fails on the link QR, so the new file must go again.
    /bin/rm -f "$A/alice.png"
    before=$(_files alice)
    : > "$TEST_DIR/qr_fail_uri"
    _m "$s" regen alice
    _fail
    [ "$(_files alice)" = "$before" ] || { diff <(echo "$before") <(_files alice) >&2; return 1; }
}
@test "regen on 3.1 that fails removes again a file that did not exist before" { _both _regen_restores_absent; }

_regen_no_qrencode() {
    local s="$1" before inode
    _gen 3.1
    _m "$s" add alice
    _ok
    before=$(_files alice)
    inode=$(stat -c %i "$A/alice.conf")
    _hide qrencode
    _m "$s" regen alice
    _fail
    _refused_for_qrencode
    [ "$(_files alice)" = "$before" ]
    # refused BEFORE any change: the .conf was never rewritten (a restore from
    # the copy would bring the same bytes back under a new inode)
    [ "$(stat -c %i "$A/alice.conf")" = "$inode" ]
}
@test "regen on 3.1 without qrencode is refused before any change" { _both _regen_no_qrencode; }

# The failure paths between the rewrite of the .conf and the end of the regen
# are hard to reach from outside (a failing sed, an unparseable route list), so
# the rule is pinned on the source: after the snapshot, every `return 1` puts the
# set back - eight failure paths with _awg31_set_restore_noted, plus the final
# check that restores with _awg31_set_restore itself.
@test "after the snapshot every failure return of regenerate_client puts the set back (source, both libraries)" {
    local lib body after n_ret n_rest n_final
    for lib in "$BATS_TEST_DIRNAME/../awg_common.sh" "$BATS_TEST_DIRNAME/../awg_common_en.sh"; do
        body=$(awk '/^regenerate_client\(\) \{$/,/^}$/' "$lib")
        after=$(awk 'f { print } /_awg31_set_snapshot "\$name"/ { f = 1 }' <<< "$body")
        [ -n "$after" ] || { echo "no snapshot in $lib"; return 1; }
        n_ret=$(grep -c 'return 1' <<< "$after")
        n_rest=$(grep -c '_awg31_set_restore_noted "\$name"' <<< "$after")
        n_final=$(grep -c 'if _awg31_set_restore; then' <<< "$after")
        [ "$n_final" -eq 1 ] || { echo "$lib: final restore $n_final"; return 1; }
        [ "$n_rest" -ge 8 ] || { echo "$lib: only $n_rest failure paths restore"; return 1; }
        [ "$n_ret" -eq $((n_rest + n_final)) ] \
            || { echo "$lib: $n_ret failure returns, $n_rest restoring + $n_final final"; return 1; }
    done
}

# A concurrent operation changes the client .conf in the window between the
# regen releasing the lock and its final check (the qrencode stub does it, then
# fails). The previous set must NOT come back over that change.
_regen_concurrent_change_kept() {
    local s="$1"
    _gen 3.1
    _m "$s" add alice
    _ok
    cat > "$TEST_DIR/bin/qrencode" << STUB
#!/bin/bash
cat >/dev/null
echo "# changed by another operation" >> "$A/alice.conf"
exit 1
STUB
    chmod +x "$TEST_DIR/bin/qrencode"
    sed -i "s/^export AWG_ENDPOINT=.*/export AWG_ENDPOINT='203.0.113.9'/" "$A/awgsetup_cfg.init"
    _m "$s" regen alice
    _fail
    grep -qxF "# changed by another operation" "$A/alice.conf"
    [[ "$output$stderr" == *"regen alice"* ]]
}
@test "regen does not put the previous set back over a concurrent change of the client config" { _both _regen_concurrent_change_kept; }

# The config lock cannot be taken again for the final put-back: nothing is
# restored without it (flock starts failing from the moment QR building begins).
_regen_no_lock_no_restore() {
    local s="$1" real_flock
    _gen 3.1
    _m "$s" add alice
    _ok
    real_flock=$(PATH=/usr/bin:/bin command -v flock)
    cat > "$TEST_DIR/bin/flock" << STUB
#!/bin/bash
[[ -e "$TEST_DIR/flock_fail" ]] && exit 1
exec "$real_flock" "\$@"
STUB
    cat > "$TEST_DIR/bin/qrencode" << STUB
#!/bin/bash
cat >/dev/null
: > "$TEST_DIR/flock_fail"
exit 1
STUB
    chmod +x "$TEST_DIR/bin/flock" "$TEST_DIR/bin/qrencode"
    sed -i "s/^export AWG_ENDPOINT=.*/export AWG_ENDPOINT='203.0.113.9'/" "$A/awgsetup_cfg.init"
    _m "$s" regen alice
    _fail
    # the regenerated .conf (new endpoint) stays: no put-back without the lock
    grep -q '203.0.113.9' "$A/alice.conf"
    [[ "$output$stderr" == *"regen alice"* ]]
}
@test "regen does not put the previous set back without the config lock" { _both _regen_no_lock_no_restore; }

# ------------------------------------------------------------------ only our own client is undone

# _lib <library> <code> : run code with the library sourced, in the sandbox
_lib() {
    AWG_DIR="$A" CONFIG_FILE="$A/awgsetup_cfg.init" SERVER_CONF_FILE="$SC" KEYS_DIR="$A/keys" \
        timeout 60 bash -c '
            log() { :; }; log_warn() { :; }; log_error() { echo "ERR: $*" >&2; }; log_debug() { :; }
            source "$1" >/dev/null 2>&1
            eval "$2"
        ' _ "$1" "$2"
}

_undo_foreign_left() {
    local s="$1" lib before server
    lib="${s/manage_amneziawg/awg_common}"
    _gen 3.1
    _m "$s" add alice
    _ok
    before=$(_files alice)
    server=$(cksum < "$SC")
    # another process recreated "alice": her key is not the one we created
    run _lib "$lib" '_awg31_undo_client alice NOTOURKEYNOTOURKEYNOTOURKEYNOTOURKEYNOTOUA='
    _fail
    [ "$(_files alice)" = "$before" ]
    [ "$(cksum < "$SC")" = "$server" ]
    run _lib "$lib" 'remove_peer_from_server alice NOTOURKEYNOTOURKEYNOTOURKEYNOTOURKEYNOTOUA='
    _fail
    [ "$(cksum < "$SC")" = "$server" ]
    # and with our own key it does take the client off (the check is not vacuous)
    run _lib "$lib" "_awg31_undo_client alice \"\$(cat '$A/keys/alice.public')\""
    _ok
    _no_trace alice
}
@test "the rollback of add takes off only its own client: a foreign key leaves files and peer alone" { _both _undo_foreign_left; }

_regen_ok() {
    local s="$1"
    _gen 3.1
    _m "$s" add alice
    _ok
    _m "$s" regen alice
    _ok
    [ "$(_files alice | grep -c ' absent$')" -eq 0 ]
}
@test "regen on 3.1 with the tools in place succeeds" { _both _regen_ok; }
