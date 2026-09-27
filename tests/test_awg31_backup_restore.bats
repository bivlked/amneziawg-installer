#!/usr/bin/env bats
# backup and restore across protocol generations (slice C1 of phase F4).
#
# A 3.1 installation has a third file that belongs to the server identity: the
# header protection key, server_hpk.key, a copy of HeaderProtectionKey from
# awg0.conf. Without it a 3.1 backup cannot be restored into a working server.
#
# Contract pinned here:
#   - backup on 3.1 carries server_hpk.key (mode 600, same bytes) and refuses,
#     with a named reason, when the key file and awg0.conf disagree; a key file
#     lost next to a key in awg0.conf is restored from the config first;
#   - restore checks the CANDIDATE (marker from the archive init, key in the
#     archive awg0.conf, archive key file) and validates the candidate config
#     BEFORE the service is stopped; any refusal leaves the service running and
#     every live file untouched;
#   - an archive without an init keeps the live marker (old backups);
#   - a failed stop, or awg0 still present after stop, is fatal before any
#     file is replaced;
#   - restore of 2.0 over 3.1 moves the live key into archive/<date>-3.1/;
#   - the pre-restore snapshot takes the live key file as it is (a damaged key
#     must not block restore as a repair), and rollback returns the key file,
#     the marker and the client files to exactly the pre-restore set;
#   - neither restore nor rollback calls syncconf: a generation change needs
#     the interface recreated.
#
# Harness: the real manage scripts end-to-end in a sandbox, stubbed awg,
# systemctl, ip, curl and wget. backup reads and restore writes
# /etc/cron.d/awg-expiry by a literal path, so the file skips when the host has
# one, and teardown checks the host /etc/cron.d is unchanged.

# shellcheck disable=SC2154  # $stderr is set by `run --separate-stderr`

bats_require_minimum_version 1.5.0

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
    cat > "$TEST_DIR/bin/awg-quick" << STUB
#!/bin/bash
echo "awg-quick \$*" >> "$TEST_DIR/awg.log"
exit 0
STUB
    # systemctl: a flag file makes one action fail.
    cat > "$TEST_DIR/bin/systemctl" << STUB
#!/bin/bash
echo "systemctl \$*" >> "$TEST_DIR/systemctl.log"
[[ "\$1" == "start" && -e "$TEST_DIR/fail_start" ]] && exit 1
[[ "\$1" == "stop" && -e "$TEST_DIR/fail_stop" ]] && exit 1
exit 0
STUB
    # ip: awg0 exists only while the flag file is there.
    cat > "$TEST_DIR/bin/ip" << STUB
#!/bin/bash
echo "ip \$*" >> "$TEST_DIR/ip.log"
if [[ "\$*" == *"link show"*"awg0"* ]]; then
    [[ -e "$TEST_DIR/awg0_left" ]] && { echo "5: awg0: <POINTOPOINT,UP> mtu 1280"; exit 0; }
    exit 1
fi
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
    _write_conf ""
    MOCK_ARGS=(--conf-dir="$A" --server-conf="$A/awg0.conf")
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

# _write_conf <key or empty> [S1] : server config, with HeaderProtectionKey when a key is given
_write_conf() {
    local key="$1" s1="${2:-72}"
    {
        printf '[Interface]\nPrivateKey = TESTKEY\n'
        [[ -n "$key" ]] && printf 'HeaderProtectionKey = %s\nContentPaddingAddition = 32-128\n' "$key"
        printf 'Address = 10.9.9.1/24\nMTU = 1280\nListenPort = 39743\n'
        printf 'Jc = 6\nJmin = 55\nJmax = 380\nS1 = %s\nS2 = 56\nS3 = 32\nS4 = 16\n' "$s1"
        printf 'H1 = 100000-800000\nH2 = 1000000-8000000\nH3 = 10000000-80000000\nH4 = 100000000-800000000\n'
    } > "$A/awg0.conf"
    chmod 600 "$A/awg0.conf"
}

# _make_31 <key> : turn the sandbox into a consistent 3.1 installation
_make_31() {
    sed -i '/AWG_PROTOCOL/d' "$A/awgsetup_cfg.init"
    printf "export AWG_PROTOCOL='3.1'\n" >> "$A/awgsetup_cfg.init"
    _write_conf "$1"
    ( umask 077; printf '%s\n' "$1" > "$A/server_hpk.key" )
}

_make_20() {
    sed -i '/AWG_PROTOCOL/d' "$A/awgsetup_cfg.init"
    printf "export AWG_PROTOCOL='2.0'\n" >> "$A/awgsetup_cfg.init"
    _write_conf ""
    rm -f "$A/server_hpk.key"
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

# _backup <script> : make a backup, print its path
_backup() {
    local s="$1" out path
    _lib_for "$s"
    out=$(timeout 60 bash "$s" backup --json "${MOCK_ARGS[@]}" 2>/dev/null) || return 1
    path=$(printf '%s' "$out" | jq -re '.path') || return 1
    if tar -tzf "$path" | grep -qxE '(\./)?awg-expiry'; then
        echo "archive carries awg-expiry: $path" >&2
        return 1
    fi
    printf '%s\n' "$path"
}

# _retar <archive> <out> <command> : unpack, run a command in the tree, pack again
_retar() {
    local src="$1" out="$2" cmd="$3" d
    d=$(mktemp -d "$TEST_DIR/retar-XXXXXX")
    tar -xzf "$src" -C "$d"
    ( cd "$d" && eval "$cmd" )
    tar -czf "$out" -C "$d" .
    rm -rf "$d"
}

# _state : fingerprint of every live file restore may touch
_state() {
    ( cd "$A" && find . -path ./backups -prune -o -path ./archive -prune -o -type f ! -name '*.log' -print \
        | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done )
}

_mode() { stat -c %a "$1"; }

# 🔴 The case function is called as a plain command, never under `||` or `if`:
# there bash turns off set -e for the whole body, every failed assertion inside
# is ignored and only the last command decides. For the same reason a negated
# check is written with _nope, not `! cmd` (set -e ignores `!`).
_both() {
    local s
    for s in "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"; do
        echo "# twin: ${s##*/}" >&3
        "$1" "$s"
        # fresh sandbox for the twin
        teardown; setup
    done
}

# _ok / _fail : status of the last `run`, with its output shown on a surprise
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

# _nope <command string> : fail when the command succeeds
_nope() {
    if eval "$1"; then echo "must not hold: $1" >&2; return 1; fi
    return 0
}

_ru() { [[ "$1" != *_en.sh ]]; }

# ------------------------------------------------------------------ backup

_b_31_carries_key() {
    local s="$1" b
    _make_31 "$K1"
    b=$(_backup "$s")
    [ -n "$b" ]
    local d; d=$(mktemp -d "$TEST_DIR/x-XXXXXX")
    tar -xzf "$b" -C "$d"
    [ -f "$d/server_hpk.key" ]
    [ "$(cat "$d/server_hpk.key")" = "$K1" ]
    [ "$(_mode "$d/server_hpk.key")" = 600 ]
}
@test "backup on 3.1 carries server_hpk.key, mode 600, same bytes" { _both _b_31_carries_key; }

_b_31_mismatch_refused() {
    local s="$1" before
    _make_31 "$K1"
    printf '%s\n' "$K2" > "$A/server_hpk.key"
    before=$(find "$A/backups" -name 'awg_backup_*' 2>/dev/null | wc -l)
    _m "$s" backup
    _fail
    [[ "$output$stderr" == *"server_hpk.key"* ]]
    [ "$(find "$A/backups" -name 'awg_backup_*' 2>/dev/null | wc -l)" -eq "$before" ]
}
@test "backup on 3.1 refuses when the key file and awg0.conf disagree" { _both _b_31_mismatch_refused; }

_b_31_lost_file_restored() {
    local s="$1" b d
    _make_31 "$K1"
    rm -f "$A/server_hpk.key"
    b=$(_backup "$s")
    [ -n "$b" ]
    d=$(mktemp -d "$TEST_DIR/x-XXXXXX")
    tar -xzf "$b" -C "$d"
    [ "$(cat "$d/server_hpk.key")" = "$K1" ]
    [ "$(cat "$A/server_hpk.key")" = "$K1" ]
}
@test "backup on 3.1 with a lost key file restores it from awg0.conf and carries it" { _both _b_31_lost_file_restored; }

_b_20_no_key() {
    local s="$1" b
    _make_20
    b=$(_backup "$s")
    [ -n "$b" ]
    _nope 'tar -tzf "$b" | grep -qE "(^|/)server_hpk\.key$"'
}
@test "backup on 2.0 carries no server_hpk.key" { _both _b_20_no_key; }

# ------------------------------------------------------------------ restore

_r_31_roundtrip() {
    local s="$1" b
    _make_31 "$K1"
    b=$(_backup "$s")
    _make_31 "$K2"
    _m "$s" restore "$b"
    _ok
    grep -qxF "HeaderProtectionKey = $K1" "$A/awg0.conf"
    [ "$(cat "$A/server_hpk.key")" = "$K1" ]
    [ "$(_mode "$A/server_hpk.key")" = 600 ]
    [ ! -L "$A/server_hpk.key" ]
}
@test "restore 3.1 over 3.1 brings back the archived key in the config and the file" { _both _r_31_roundtrip; }

_r_31_over_20() {
    local s="$1" b
    _make_31 "$K1"
    b=$(_backup "$s")
    _make_20
    _m "$s" restore "$b"
    _ok
    grep -q "AWG_PROTOCOL='3.1'" "$A/awgsetup_cfg.init"
    [ "$(cat "$A/server_hpk.key")" = "$K1" ]
    [ "$(_mode "$A/server_hpk.key")" = 600 ]
}
@test "restore 3.1 over 2.0 places the key file with mode 600" { _both _r_31_over_20; }

_r_20_over_31_archives_key() {
    local s="$1" b arch
    _make_20
    b=$(_backup "$s")
    _make_31 "$K1"
    _m "$s" restore "$b"
    _ok
    grep -q "AWG_PROTOCOL='2.0'" "$A/awgsetup_cfg.init"
    [ ! -e "$A/server_hpk.key" ]
    arch=$(find "$A/archive" -path '*-3.1/server_hpk.key' 2>/dev/null)
    [ "$(printf '%s\n' "$arch" | grep -c .)" -eq 1 ]
    [ "$(cat "$arch")" = "$K1" ]
    [ "$(_mode "$arch")" = 600 ]
}
@test "restore 2.0 over 3.1 moves the live key into archive/<date>-3.1/" { _both _r_20_over_31_archives_key; }

_r_candidate_mismatch() {
    local s="$1" b bad before
    _make_31 "$K1"
    b=$(_backup "$s")
    bad="$TEST_DIR/bad.tar.gz"
    _retar "$b" "$bad" "printf '%s\n' '$K2' > server_hpk.key"
    before=$(_state)
    : > "$TEST_DIR/systemctl.log"
    _m "$s" restore "$bad"
    _fail
    [[ "$output$stderr" == *"server_hpk.key"* ]]
    _nope 'grep -q "^systemctl stop" "$TEST_DIR/systemctl.log"'
    [ "$(_state)" = "$before" ]
}
@test "restore refuses a candidate whose key file disagrees with its config, before stop" { _both _r_candidate_mismatch; }

_r_candidate_invalid_visible() {
    local s="$1" b bad before
    _make_31 "$K1"
    b=$(_backup "$s")
    bad="$TEST_DIR/bad.tar.gz"
    _retar "$b" "$bad" "sed -i 's/^S1 = .*/S1 = 5/' server/awg0.conf"
    before=$(_state)
    : > "$TEST_DIR/systemctl.log"
    _m "$s" restore "$bad"
    _fail
    # the reason is shown, not swallowed
    [[ "$output$stderr" == *"S1=5"* ]]
    _nope 'grep -q "^systemctl stop" "$TEST_DIR/systemctl.log"'
    [ "$(_state)" = "$before" ]
}
@test "restore validates the candidate config before stop and shows the reason" { _both _r_candidate_invalid_visible; }

_r_no_init_keeps_live_marker_31() {
    local s="$1" b bad before
    _make_20
    b=$(_backup "$s")
    bad="$TEST_DIR/noinit.tar.gz"
    _retar "$b" "$bad" "rm -f clients/awgsetup_cfg.init"
    _make_31 "$K1"
    before=$(_state)
    : > "$TEST_DIR/systemctl.log"
    _m "$s" restore "$bad"
    # live marker stays 3.1, the archived config has no key: refused before stop
    _fail
    _nope 'grep -q "^systemctl stop" "$TEST_DIR/systemctl.log"'
    [ "$(_state)" = "$before" ]
}
@test "archive without init keeps the live 3.1 marker and a keyless config is refused" { _both _r_no_init_keeps_live_marker_31; }

_r_no_init_keeps_live_marker_20() {
    local s="$1" b bad
    _make_20
    b=$(_backup "$s")
    bad="$TEST_DIR/noinit.tar.gz"
    _retar "$b" "$bad" "rm -f clients/awgsetup_cfg.init"
    sed -i 's/^export AWG_Jc=6/export AWG_Jc=7/' "$A/awgsetup_cfg.init"
    _m "$s" restore "$bad"
    _ok
    grep -q '^export AWG_Jc=7' "$A/awgsetup_cfg.init"
    grep -q "AWG_PROTOCOL='2.0'" "$A/awgsetup_cfg.init"
}
@test "archive without init restores on 2.0 and leaves the live init in place" { _both _r_no_init_keeps_live_marker_20; }

_r_stop_fails() {
    local s="$1" b before
    _make_31 "$K1"
    b=$(_backup "$s")
    _make_31 "$K2"
    before=$(_state)
    touch "$TEST_DIR/fail_stop"
    _m "$s" restore "$b"
    _fail
    [ "$(_state)" = "$before" ]
    _nope 'grep -q "^systemctl start" "$TEST_DIR/systemctl.log"'
}
@test "a failed stop is fatal before any file is replaced" { _both _r_stop_fails; }

_r_awg0_left() {
    local s="$1" b before
    _make_31 "$K1"
    b=$(_backup "$s")
    _make_31 "$K2"
    before=$(_state)
    touch "$TEST_DIR/awg0_left"
    _m "$s" restore "$b"
    _fail
    [[ "$output$stderr" == *awg0* ]]
    [ "$(_state)" = "$before" ]
}
@test "awg0 still present after stop is fatal before any file is replaced" { _both _r_awg0_left; }

_r_damaged_live_key_repairable() {
    local s="$1" b
    _make_31 "$K1"
    b=$(_backup "$s")
    printf 'garbage\n' > "$A/server_hpk.key"
    _m "$s" restore "$b"
    _ok
    [ "$(cat "$A/server_hpk.key")" = "$K1" ]
}
@test "restore repairs a damaged live key file: the snapshot does not refuse" { _both _r_damaged_live_key_repairable; }

# ------------------------------------------------------------------ rollback

_rb_31_over_20() {
    local s="$1" b before
    _make_31 "$K1"
    _m "$s" add alice
    _ok
    b=$(_backup "$s")
    _make_20
    rm -f "$A"/alice.* "$A/keys"/alice*
    before=$(_state)
    touch "$TEST_DIR/fail_start"
    _m "$s" restore "$b"
    _fail
    [ ! -e "$A/server_hpk.key" ]
    [ ! -e "$A/alice.conf" ]
    [ "$(_state)" = "$before" ]
}
@test "rollback of 3.1 over 2.0 removes the key file and the archived clients: exact pre-restore set" { _both _rb_31_over_20; }

_rb_20_over_31() {
    local s="$1" b before
    _make_20
    b=$(_backup "$s")
    _make_31 "$K1"
    before=$(_state)
    touch "$TEST_DIR/fail_start"
    _m "$s" restore "$b"
    _fail
    [ "$(cat "$A/server_hpk.key")" = "$K1" ]
    [ "$(_mode "$A/server_hpk.key")" = 600 ]
    [ "$(_state)" = "$before" ]
    [ -z "$(find "$A/archive" -type f 2>/dev/null)" ]
}
@test "rollback of 2.0 over 3.1 returns the key file, the marker and the config" { _both _rb_20_over_31; }

_rb_31_over_31() {
    local s="$1" b before
    _make_31 "$K1"
    b=$(_backup "$s")
    _make_31 "$K2"
    before=$(_state)
    touch "$TEST_DIR/fail_start"
    _m "$s" restore "$b"
    _fail
    [ "$(cat "$A/server_hpk.key")" = "$K2" ]
    [ "$(_state)" = "$before" ]
}
@test "rollback of 3.1 over 3.1 returns the previous key" { _both _rb_31_over_31; }

# ------------------------------------------------------------------ no syncconf

_no_syncconf_dyn() {
    local s="$1" b
    _make_20
    b=$(_backup "$s")
    _make_31 "$K1"
    _m "$s" restore "$b"
    _ok
    touch "$TEST_DIR/fail_start"
    _m "$s" restore "$b"
    _fail
    _nope 'grep -q syncconf "$TEST_DIR/awg.log" 2>/dev/null'
}
@test "neither restore nor its rollback calls syncconf (dynamic)" { _both _no_syncconf_dyn; }

@test "neither restore nor its rollback calls syncconf (source, both twins)" {
    local s f body
    for s in "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"; do
        for f in restore_backup _restore_do_rollback; do
            body=$(sed -n "/^${f}() {\$/,/^}\$/p" "$s")
            [ -n "$body" ]
            if grep -vE '^[[:space:]]*#' <<< "$body" | grep -qE 'syncconf|apply_config'; then echo "$f in $s calls syncconf/apply_config" >&2; return 1; fi
        done
    done
}
