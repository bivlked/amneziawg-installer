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
#     archive awg0.conf, archive key file; a 3.1 archive without the key file
#     gets it from its own config) and validates the candidate config BEFORE the
#     snapshot and the stop; such a refusal leaves the service running, every
#     live file untouched and no snapshot behind; so does a live key path that
#     is a link or a directory;
#   - an archive without an init keeps the live marker (old backups);
#   - a failed stop, or awg0 still present after stop, is fatal before any
#     file is replaced; with awg0 left the service is started again;
#   - restore of 2.0 over 3.1 moves the live key into archive/<time>-3.1/
#     (directories 700);
#   - the pre-restore snapshot takes the live key file as it is (a damaged key
#     must not block restore as a repair), and rollback returns the key file,
#     the marker and the client files to exactly the pre-restore set;
#   - both layouts: awg0.conf inside the working directory (the sandbox
#     default) and outside it, as on a real server (/etc/amnezia/amneziawg);
#   - a refused restore answers --json with ok=false and rolled_back=false;
#   - neither restore nor rollback calls syncconf: a generation change needs
#     the interface recreated (pinned on the source; restore has no apply step).
#
# Harness: the real manage scripts end-to-end in a sandbox, stubbed awg,
# awg-quick, systemctl, ip, curl and wget. backup reads and restore writes
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
    SC="$A/awg0.conf"
    _write_conf ""
    MOCK_ARGS=(--conf-dir="$A" --server-conf="$SC")
    export AWG_SKIP_APPLY=1
}

# _etc_layout : move the server config out of the working directory, as on a
# real server. In the default layout awg0.conf also matches $AWG_DIR/*.conf and
# rides in clients/ of every archive, which would mask the server/ copy.
_etc_layout() {
    mkdir -p "$TEST_DIR/etc"
    mv "$SC" "$TEST_DIR/etc/awg0.conf"
    SC="$TEST_DIR/etc/awg0.conf"
    MOCK_ARGS=(--conf-dir="$A" --server-conf="$SC")
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
    } > "$SC"
    chmod 600 "$SC"
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
    # the server config in either layout
    printf 'SC %s\n' "$(cksum < "$SC")"
}

_nbackups() { find "$A/backups" -name 'awg_backup_*' 2>/dev/null | wc -l; }

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
    # a hand chmod on the live key must not widen the copy in the archive
    chmod 644 "$A/server_hpk.key"
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
    grep -qxF "HeaderProtectionKey = $K1" "$SC"
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
    [ "$(_mode "$A/archive")" = 700 ]
    [ "$(_mode "${arch%/*}")" = 700 ]
}
@test "restore 2.0 over 3.1 moves the live key into archive/<time>-3.1/, directories 700" { _both _r_20_over_31_archives_key; }

_r_candidate_mismatch() {
    local s="$1" b bad before nb
    _make_31 "$K1"
    b=$(_backup "$s")
    bad="$TEST_DIR/bad.tar.gz"
    _retar "$b" "$bad" "printf '%s\n' '$K2' > server_hpk.key"
    before=$(_state)
    nb=$(_nbackups)
    : > "$TEST_DIR/systemctl.log"
    _m "$s" restore "$bad"
    _fail
    [[ "$output$stderr" == *"server_hpk.key"* ]]
    _nope 'grep -q "^systemctl stop" "$TEST_DIR/systemctl.log"'
    [ "$(_state)" = "$before" ]
    # the check runs before the snapshot: a refused restore leaves no archive behind
    [ "$(_nbackups)" -eq "$nb" ]
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
    [[ "$output$stderr" == *HeaderProtectionKey* ]]
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
    # the service was stopped, so it is started again on the previous files
    grep -q '^systemctl stop' "$TEST_DIR/systemctl.log"
    grep -q '^systemctl start' "$TEST_DIR/systemctl.log"
}
@test "awg0 still present after stop is fatal before any file is replaced, the service is started again" { _both _r_awg0_left; }

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

# ------------------------------------------------------------------ more restore cases

_r_31_archive_without_keyfile() {
    local s="$1" b bad
    _make_31 "$K1"
    b=$(_backup "$s")
    bad="$TEST_DIR/nokey.tar.gz"
    _retar "$b" "$bad" "rm -f server_hpk.key"
    _make_31 "$K2"
    _m "$s" restore "$bad"
    _ok
    [ "$(cat "$A/server_hpk.key")" = "$K1" ]
    [ "$(_mode "$A/server_hpk.key")" = 600 ]
}
@test "a 3.1 archive without the key file gets it from its own config" { _both _r_31_archive_without_keyfile; }

_r_json_refusal() {
    local s="$1" b bad
    _make_31 "$K1"
    b=$(_backup "$s")
    bad="$TEST_DIR/bad.tar.gz"
    _retar "$b" "$bad" "printf '%s\n' '$K2' > server_hpk.key"
    _m "$s" restore "$bad" --json
    _fail
    printf '%s' "$output" | jq -e '.command == "restore" and .ok == false and .applied == false and .rolled_back == false' >/dev/null
}
@test "a refused restore answers --json with ok=false, applied=false, rolled_back=false" { _both _r_json_refusal; }

_r_live_key_link_refused() {
    local s="$1" b nb
    _make_31 "$K1"
    b=$(_backup "$s")
    printf 'bait\n' > "$TEST_DIR/bait"
    rm -f "$A/server_hpk.key"
    ln -s "$TEST_DIR/bait" "$A/server_hpk.key"
    nb=$(_nbackups)
    : > "$TEST_DIR/systemctl.log"
    _m "$s" restore "$b"
    _fail
    [[ "$output$stderr" == *server_hpk.key* ]]
    # nothing written through the link, the link itself kept, nothing stopped
    [ "$(cat "$TEST_DIR/bait")" = bait ]
    [ -L "$A/server_hpk.key" ]
    _nope 'grep -q "^systemctl stop" "$TEST_DIR/systemctl.log"'
    [ "$(_nbackups)" -eq "$nb" ]
}
@test "a live key path that is a link is refused before the snapshot and the stop" { _both _r_live_key_link_refused; }

_r_live_key_dir_refused() {
    local s="$1" b
    _make_31 "$K1"
    b=$(_backup "$s")
    rm -f "$A/server_hpk.key"
    mkdir "$A/server_hpk.key"
    : > "$TEST_DIR/systemctl.log"
    _m "$s" restore "$b"
    _fail
    [ -d "$A/server_hpk.key" ]
    [ -z "$(ls -A "$A/server_hpk.key")" ]
    _nope 'grep -q "^systemctl stop" "$TEST_DIR/systemctl.log"'
}
@test "a live key path that is a directory is refused before the stop" { _both _r_live_key_dir_refused; }

# ------------------------------------------------------------------ config outside AWG_DIR

_etc_roundtrip() {
    local s="$1" b
    _etc_layout
    _make_31 "$K1"
    b=$(_backup "$s")
    # the server config rides only in server/, nothing masks that copy
    _nope 'tar -tzf "$b" | grep -qE "(^|/)clients/awg0\.conf$"'
    _make_31 "$K2"
    _m "$s" restore "$b"
    _ok
    grep -qxF "HeaderProtectionKey = $K1" "$SC"
    [ "$(cat "$A/server_hpk.key")" = "$K1" ]
    [ ! -e "$A/awg0.conf" ]
}
@test "config outside the working directory: 3.1 roundtrip restores the server config from server/" { _both _etc_roundtrip; }

_etc_rollback() {
    local s="$1" b before
    _etc_layout
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
    [ ! -e "$A/awg0.conf" ]
    [ "$(_state)" = "$before" ]
}
@test "config outside the working directory: rollback of 3.1 over 2.0 is exact" { _both _etc_rollback; }

# ------------------------------------------------------------------ loud where it used to be quiet

_b_refused_key_without_31() {
    local s="$1" marker="$2" nb
    _make_31 "$K1"
    sed -i '/AWG_PROTOCOL/d' "$A/awgsetup_cfg.init"
    printf "export AWG_PROTOCOL='%s'\n" "$marker" >> "$A/awgsetup_cfg.init"
    nb=$(_nbackups)
    _m "$s" backup
    _fail
    [[ "$output$stderr" == *HeaderProtectionKey* || "$output$stderr" == *AWG_PROTOCOL* ]]
    [ "$(_nbackups)" -eq "$nb" ]
}
_b_refused_broken_marker() { _b_refused_key_without_31 "$1" 9.9; }
_b_refused_marker_20() { _b_refused_key_without_31 "$1" 2.0; }
@test "backup refuses a key in awg0.conf under a broken marker: the archive would not restore" { _both _b_refused_broken_marker; }
@test "backup refuses a key in awg0.conf under marker 2.0: the archive would not restore" { _both _b_refused_marker_20; }

_rb_json_complete() {
    local s="$1" b
    _make_20
    b=$(_backup "$s")
    _make_31 "$K1"
    touch "$TEST_DIR/fail_start"
    _m "$s" restore "$b" --json
    _fail
    printf '%s' "$output" | jq -e '.rolled_back == true and .rollback_complete == true' >/dev/null
}
@test "a full rollback answers --json with rolled_back=true and rollback_complete=true" { _both _rb_json_complete; }

# cp into the client key directory fails: restore goes to rollback, and the
# rollback cannot put the client keys back either.
_rb_json_partial() {
    local s="$1" target="${2:-$A/keys/}" src="${3:-}" b real_cp
    _make_31 "$K1"
    _m "$s" add alice
    _ok
    b=$(_backup "$s")
    real_cp=$(PATH=/usr/bin:/bin command -v cp)
    cat > "$TEST_DIR/bin/cp" << STUB
#!/bin/bash
if [[ -e "$TEST_DIR/fail_cp_keys" ]]; then
    # fails only the copy into the target, and with a source filter only when a source matches it
    hit=0; tgt=0
    for a in "\$@"; do
        [[ "\$a" == "$target" ]] && tgt=1
        [[ -z "$src" || "\$a" == *"$src"* ]] && hit=1
    done
    (( tgt && hit )) && exit 1
fi
exec "$real_cp" "\$@"
STUB
    chmod +x "$TEST_DIR/bin/cp"
    touch "$TEST_DIR/fail_cp_keys"
    _m "$s" restore "$b" --json
    _fail
    printf '%s' "$output" | jq -e '.rolled_back == true and .rollback_complete == false' >/dev/null \
        || { printf 'envelope: %s\nstderr: %s\n' "$output" "$stderr" >&2; return 1; }
    [[ "$stderr" == *"${target%/}"* ]]
}
@test "a partial rollback answers --json with rollback_complete=false and names the snapshot" { _both _rb_json_partial; }
_rb_json_partial_clients() { _rb_json_partial "$1" "$A/" /clients/; }
@test "a partial rollback of the client files answers --json with rollback_complete=false" { _both _rb_json_partial_clients; }

# rm of the client files fails during rollback: the archived client stays, so
# the rollback is not complete. (The cron file copy is counted the same way; it
# is not exercised here because the sandbox never touches the host /etc/cron.d.)
_rb_json_partial_prune() {
    local s="$1" b real_rm
    _make_31 "$K1"
    _m "$s" add alice
    _ok
    b=$(_backup "$s")
    _make_20
    rm -f "$A"/alice.* "$A/keys"/alice*
    real_rm=$(PATH=/usr/bin:/bin command -v rm)
    cat > "$TEST_DIR/bin/rm" << STUB
#!/bin/bash
if [[ -e "$TEST_DIR/fail_rm_clients" ]]; then
    for a in "\$@"; do [[ "\$a" == "$A/alice.conf" ]] && exit 1; done
fi
exec "$real_rm" "\$@"
STUB
    chmod +x "$TEST_DIR/bin/rm"
    # arm the failing rm only once restore is past its own prune: the start fails,
    # rollback runs its prune with the flag set
    cat > "$TEST_DIR/bin/systemctl" << STUB
#!/bin/bash
echo "systemctl \$*" >> "$TEST_DIR/systemctl.log"
if [[ "\$1" == "start" ]]; then touch "$TEST_DIR/fail_rm_clients"; exit 1; fi
exit 0
STUB
    chmod +x "$TEST_DIR/bin/systemctl"
    _m "$s" restore "$b" --json
    _fail
    printf '%s' "$output" | jq -e '.rolled_back == true and .rollback_complete == false' >/dev/null \
        || { printf 'envelope: %s\nstderr: %s\n' "$output" "$stderr" >&2; return 1; }
}
@test "a rollback that cannot remove an archived client answers --json with rollback_complete=false" { _both _rb_json_partial_prune; }

# A dynamic "no syncconf" case cannot fail here: restore has no apply step at
# all and the sandbox sets AWG_SKIP_APPLY, so the source check below is the pin.

# ------------------------------------------------------------------ no syncconf

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
