#!/usr/bin/env bats
# The expiry stamp expiry/<name> must not outlive the client it belongs to and
# attach itself to a same-named permanent client:
#   (a) backup; add guest --expires=30d; restore <backup>; add guest
#       - the new permanent guest inherited the stamp (add JSON said
#         expires_at:null, list showed the deadline);
#   (b) add bob; backup; remove bob; add bob --expires=1h; restore <backup>
#       - bob, permanent in the backup, got the stamp of the current bob.
# In both cases cron (check_expired_clients) deleted the permanent client at
# the old deadline.
#
# Controls: a stamp that the archive carries survives restore with the
# archived value, and a stamp of a client absent from the restored config is
# left alone (restore deliberately does not prune those, comment C11 in
# restore_backup). A failed restore rolls the removed stamp back.
#
# Behavioral: runs the real manage scripts end-to-end in a sandbox (stubbed
# awg/systemctl/curl/wget, AWG_ENDPOINT set, AWG_SKIP_APPLY=1). backup reads
# and restore writes /etc/cron.d/awg-expiry by a literal path, so every
# archive is checked to carry no awg-expiry before restore, and each test
# verifies that the host /etc/cron.d is unchanged.

# shellcheck disable=SC2154  # $stderr is set by `run --separate-stderr`

bats_require_minimum_version 1.5.0

require_jq() { command -v jq &>/dev/null || skip "jq not available"; }

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
    # backup would pack the host file and restore would write it back.
    [[ -e /etc/cron.d/awg-expiry ]] && skip "host has /etc/cron.d/awg-expiry"
    TEST_DIR=$(mktemp -d)
    mkdir -p "$TEST_DIR/bin" "$TEST_DIR/awg/keys" "$TEST_DIR/cron"

    # Distinct random keys: several clients are added in one sandbox.
    cat > "$TEST_DIR/bin/awg" << 'STUB'
#!/bin/bash
case "$1" in
    genkey|genpsk) head -c32 /dev/urandom | base64 ;;
    pubkey) cat >/dev/null; head -c32 /dev/urandom | base64 ;;
    *) exit 0 ;;
esac
STUB
    # systemctl: "start" fails when $TEST_DIR/fail_start exists (rollback case).
    cat > "$TEST_DIR/bin/systemctl" << STUB
#!/bin/bash
echo "systemctl \$*" >> "$TEST_DIR/systemctl.log"
if [[ "\$1" == "start" && -e "$TEST_DIR/fail_start" ]]; then exit 1; fi
exit 0
STUB
    # No network: endpoint comes from AWG_ENDPOINT, any curl/wget call is logged.
    for c in curl wget; do
        printf '#!/bin/bash\necho "%s $*" >> "%s/net.log"\nexit 1\n' "$c" "$TEST_DIR" > "$TEST_DIR/bin/$c"
    done
    chmod +x "$TEST_DIR/bin/"*
    export PATH="$TEST_DIR/bin:$PATH"

    cp "$BATS_TEST_DIRNAME/../awg_common.sh" "$TEST_DIR/awg/awg_common.sh"
    cat > "$TEST_DIR/awg/awgsetup_cfg.init" << 'CONF'
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
    cat > "$TEST_DIR/awg/awg0.conf" << 'CONF'
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

    EXP="$TEST_DIR/awg/expiry"
    MOCK_ARGS=(--conf-dir="$TEST_DIR/awg" --server-conf="$TEST_DIR/awg/awg0.conf")
    export AWG_SKIP_APPLY=1
    export EXPIRY_CRON="$TEST_DIR/cron/awg-expiry"
}

teardown() {
    unset AWG_SKIP_APPLY EXPIRY_CRON
    rm -rf "$TEST_DIR"
    # The host cron directory must be untouched by backup/restore.
    # Per-test file: with bats --jobs the tests of this file run in parallel,
    # and one shared "after" file made teardowns overwrite each other.
    _crond_state > "$BATS_TEST_TMPDIR/crond.after"
    cmp -s "$BATS_FILE_TMPDIR/crond.before" "$BATS_TEST_TMPDIR/crond.after" || {
        echo "host /etc/cron.d changed" >&2
        diff "$BATS_FILE_TMPDIR/crond.before" "$BATS_TEST_TMPDIR/crond.after" >&2
        return 1
    }
}

# _lib_for <script>: put the library of the script's language where manage
# loads it from. On a server the EN installer saves awg_common_en.sh under the
# plain name, so the EN manage must run against the EN library here too.
_lib_for() {
    case "$1" in
        *_en.sh) cp "$BATS_TEST_DIRNAME/../awg_common_en.sh" "$TEST_DIR/awg/awg_common.sh" ;;
        *)       cp "$BATS_TEST_DIRNAME/../awg_common.sh" "$TEST_DIR/awg/awg_common.sh" ;;
    esac
}

# _m <script> <args...>: run manage in the sandbox.
_m() {
    local s="$1"; shift
    _lib_for "$s"
    run --separate-stderr bash "$s" "$@" --yes "${MOCK_ARGS[@]}"
}

# _backup <script>: make a backup, print its path; the archive must not carry
# awg-expiry, otherwise restore would write the host /etc/cron.d.
_backup() {
    local s="$1" out path listing
    _lib_for "$s"
    out=$(bash "$s" backup --json "${MOCK_ARGS[@]}" 2>/dev/null) || return 1
    path=$(printf '%s' "$out" | jq -re '.path') || return 1
    listing=$(tar -tzf "$path") || return 1
    if grep -qxE '(\./)?awg-expiry' <<< "$listing"; then
        echo "archive carries awg-expiry: $path" >&2
        return 1
    fi
    printf '%s\n' "$path"
}

# _list_exp <script> <name>: expires_at of <name> from list --json.
_list_exp() {
    local out
    _lib_for "$1"
    out=$(bash "$1" list --json "${MOCK_ARGS[@]}" 2>/dev/null) || return 1
    printf '%s' "$out" | jq -c --arg n "$2" \
        '[.. | objects | select(.name? == $n) | .expires_at] | if length == 1 then .[0] else error("no single record") end'
}

_scenario_a() {
    local s="$1" b1
    b1=$(_backup "$s")
    [ -n "$b1" ]
    _m "$s" add guest --expires=30d --json
    [ "$status" -eq 0 ]
    [ -f "$EXP/guest" ]
    _m "$s" restore "$b1" --json
    [ "$status" -eq 0 ]
    # guest is not in the restored config: its stamp is an orphan and restore
    # leaves it in place (C11), so it is add that has to drop it.
    [ -f "$EXP/guest" ]
    _m "$s" add guest --json
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.results[0].status == "created" and .results[0].expires_at == null' >/dev/null
    if [ -e "$EXP/guest" ]; then
        echo "stale stamp survived add: $EXP/guest = $(cat "$EXP/guest");" \
            "add JSON expires_at = $(printf '%s' "$output" | jq -c '.results[0].expires_at');" \
            "list expires_at = $(_list_exp "$s" guest)" >&2
        return 1
    fi
    run _list_exp "$s" guest
    [ "$status" -eq 0 ]
    [ "$output" = "null" ]
    [ ! -s "$TEST_DIR/net.log" ]
}

# _scenario_b <script> <archive_has_expiry>: with 1, carol --expires is added
# before the backup, so the archive carries expiry/ (with carol, without bob);
# with 0 the archive has no expiry/ at all.
_scenario_b() {
    local s="$1" with_exp="$2" b1 carol_archived=""
    if [ "$with_exp" = 1 ]; then
        _m "$s" add carol --expires=30d --json
        [ "$status" -eq 0 ]
        carol_archived=$(cat "$EXP/carol")
    fi
    _m "$s" add bob --json
    [ "$status" -eq 0 ]
    b1=$(_backup "$s")
    [ -n "$b1" ]
    local listing
    listing=$(tar -tzf "$b1")
    if [ "$with_exp" = 1 ]; then
        grep -qE '(^|/)expiry/carol$' <<< "$listing"
    else
        if grep -qE '(^|/)expiry/?$' <<< "$listing"; then
            echo "archive unexpectedly carries expiry/" >&2
            return 1
        fi
    fi
    _m "$s" remove bob --json
    [ "$status" -eq 0 ]
    _m "$s" add bob --expires=1h --json
    [ "$status" -eq 0 ]
    [ -f "$EXP/bob" ]
    _m "$s" restore "$b1" --json
    [ "$status" -eq 0 ]
    grep -qxF '#_Name = bob' "$TEST_DIR/awg/awg0.conf"
    if [ -e "$EXP/bob" ]; then
        echo "stale stamp survived restore: $EXP/bob = $(cat "$EXP/bob");" \
            "list expires_at = $(_list_exp "$s" bob)" >&2
        return 1
    fi
    run _list_exp "$s" bob
    [ "$status" -eq 0 ]
    [ "$output" = "null" ]
    if [ "$with_exp" = 1 ]; then
        [ "$(cat "$EXP/carol")" = "$carol_archived" ]
    fi
    [ ! -s "$TEST_DIR/net.log" ]
}

# Control (green before and after the fix): the archive carries carol's stamp,
# the current value differs - restore brings back the archived value; the
# orphan stamp of ghost (absent from the restored config) stays (C11).
_scenario_control() {
    local s="$1" b1 carol_archived
    _m "$s" add carol --expires=30d --json
    [ "$status" -eq 0 ]
    carol_archived=$(cat "$EXP/carol")
    b1=$(_backup "$s")
    [ -n "$b1" ]
    printf '%s\n' 1999999999 > "$EXP/carol"
    printf '%s\n' 1888888888 > "$EXP/ghost"
    _m "$s" restore "$b1" --json
    [ "$status" -eq 0 ]
    [ "$(cat "$EXP/carol")" = "$carol_archived" ]
    run _list_exp "$s" carol
    [ "$status" -eq 0 ]
    [ "$output" = "$carol_archived" ]
    [ -f "$EXP/ghost" ]
    [ "$(cat "$EXP/ghost")" = "1888888888" ]
    [ ! -s "$TEST_DIR/net.log" ]
}

# A failed restore rolls back to the pre-restore snapshot, stamp included.
_scenario_rollback() {
    local s="$1" b1 bob_now
    _m "$s" add bob --json
    [ "$status" -eq 0 ]
    b1=$(_backup "$s")
    [ -n "$b1" ]
    _m "$s" remove bob --json
    [ "$status" -eq 0 ]
    _m "$s" add bob --expires=1h --json
    [ "$status" -eq 0 ]
    bob_now=$(cat "$EXP/bob")
    : > "$TEST_DIR/fail_start"
    _m "$s" restore "$b1" --json
    [ "$status" -ne 0 ]
    printf '%s' "$output" | jq -e '.rolled_back == true' >/dev/null
    [ -f "$EXP/bob" ]
    [ "$(cat "$EXP/bob")" = "$bob_now" ]
    [ ! -s "$TEST_DIR/net.log" ]
}

# The mirror case: bob is timed in the archive and permanent now. restore
# copies the archived stamp in, then fails; the rollback must take that stamp
# away again, or cron deletes the permanent bob at the archived deadline while
# the JSON says rolled_back. Two variants: the pre-restore state has an empty
# expiry/ directory, or none at all.
_scenario_rollback_imported() {
    local s="$1" drop_dir="$2" b1
    _m "$s" add bob --expires=30d --json
    [ "$status" -eq 0 ]
    b1=$(_backup "$s")
    [ -n "$b1" ]
    tar -tzf "$b1" | grep -qE '(^|/)expiry/bob$'
    _m "$s" remove bob --json
    [ "$status" -eq 0 ]
    _m "$s" add bob --json
    [ "$status" -eq 0 ]
    [ ! -e "$EXP/bob" ]
    if [ "$drop_dir" = 1 ]; then rmdir "$EXP"; fi
    : > "$TEST_DIR/fail_start"
    _m "$s" restore "$b1" --json
    [ "$status" -ne 0 ]
    printf '%s' "$output" | jq -e '.rolled_back == true' >/dev/null
    if [ -e "$EXP/bob" ]; then
        echo "archived stamp survived the rollback: $EXP/bob = $(cat "$EXP/bob")" >&2
        return 1
    fi
    [ ! -s "$TEST_DIR/net.log" ]
}

@test "RU: failed restore takes back a stamp that came from the archive" {
    require_jq
    _scenario_rollback_imported "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" 0
    rm -rf "$TEST_DIR"; setup
    _scenario_rollback_imported "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" 1
}

@test "EN: failed restore takes back a stamp that came from the archive" {
    require_jq
    _scenario_rollback_imported "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh" 0
    rm -rf "$TEST_DIR"; setup
    _scenario_rollback_imported "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh" 1
}

@test "RU (a): add after restore does not inherit a stale expiry stamp" {
    require_jq
    _scenario_a "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
}

@test "EN (a): add after restore does not inherit a stale expiry stamp" {
    require_jq
    _scenario_a "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
}

@test "RU (b): restored permanent client drops the current same-named stamp (archive without expiry/)" {
    require_jq
    _scenario_b "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" 0
}

@test "EN (b): restored permanent client drops the current same-named stamp (archive without expiry/)" {
    require_jq
    _scenario_b "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh" 0
}

@test "RU (b): restored permanent client drops the current same-named stamp (archive with expiry/)" {
    require_jq
    _scenario_b "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" 1
}

@test "EN (b): restored permanent client drops the current same-named stamp (archive with expiry/)" {
    require_jq
    _scenario_b "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh" 1
}

@test "RU control: archived stamp restored, orphan stamp of absent client kept (C11)" {
    require_jq
    _scenario_control "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
}

@test "EN control: archived stamp restored, orphan stamp of absent client kept (C11)" {
    require_jq
    _scenario_control "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
}

@test "RU control: failed restore rolls the removed stamp back" {
    require_jq
    _scenario_rollback "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
}

@test "EN control: failed restore rolls the removed stamp back" {
    require_jq
    _scenario_rollback "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
}

# A stamp that cannot be removed must not turn into a false success. A
# non-empty directory in place of the stamp makes rm -f fail even as root.
# add: the client is refused (status error, nothing in awg0.conf), because it
# would otherwise be created with someone else's deadline.
_scenario_add_stamp_stuck() {
    local s="$1"
    mkdir -p "$EXP/guest/stuck"
    _m "$s" add guest --json
    [ "$status" -ne 0 ]
    printf '%s' "$output" | jq -e '.results[0].status == "error"' >/dev/null
    if grep -qxF '#_Name = guest' "$TEST_DIR/awg/awg0.conf"; then
        echo "guest created although its stale stamp could not be removed" >&2; return 1
    fi
    [ ! -e "$TEST_DIR/awg/guest.conf" ]
    [ ! -s "$TEST_DIR/net.log" ]
}

# restore: the stamp of a client permanent in the backup cannot be removed ->
# restore fails and rolls back instead of reporting success.
_scenario_restore_stamp_stuck() {
    local s="$1" b1
    _m "$s" add bob --json
    [ "$status" -eq 0 ]
    b1=$(_backup "$s")
    [ -n "$b1" ]
    _m "$s" remove bob --json
    [ "$status" -eq 0 ]
    rm -f "$EXP/bob"
    mkdir -p "$EXP/bob/stuck"
    _m "$s" restore "$b1" --json
    [ "$status" -ne 0 ]
    printf '%s' "$output" | jq -e '.ok == false and .rolled_back == true' >/dev/null
    # The refusal is about this stamp, not some other failure of restore.
    if ! LC_ALL=C.UTF-8 grep -qE '(Не удалось удалить метку срока|Could not remove the expiry stamp) .*/bob' <<< "$stderr"; then
        echo "restore failed for another reason: $stderr" >&2; return 1
    fi
    [ -d "$EXP/bob/stuck" ]
    [ ! -s "$TEST_DIR/net.log" ]
}

@test "RU: add refuses a client whose stale expiry stamp cannot be removed" {
    require_jq
    _scenario_add_stamp_stuck "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
}

@test "EN: add refuses a client whose stale expiry stamp cannot be removed" {
    require_jq
    _scenario_add_stamp_stuck "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
}

@test "RU: restore rolls back when a stale expiry stamp cannot be removed" {
    require_jq
    _scenario_restore_stamp_stuck "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
}

@test "EN: restore rolls back when a stale expiry stamp cannot be removed" {
    require_jq
    _scenario_restore_stamp_stuck "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
}
# Race: while this add waited for the config lock, a parallel add of the same
# name created the client with a deadline. The name is checked again under the
# lock, so the fresh stamp survives and this add reports "exists". The test
# holds the lock itself and waits until add blocks on it (a flock child).
_scenario_add_race() {
    local s="$1" fd pid blocked=0 rc=0
    _lib_for "$s"
    # The parallel client's QR and vpn:// are already on disk while its name is
    # not yet in awg0.conf: removing them before the locked re-check would erase
    # them.
    : > "$TEST_DIR/awg/guest.png"
    : > "$TEST_DIR/awg/guest.vpnuri"
    exec {fd}>"$TEST_DIR/awg/.awg_config.lock"
    flock -x "$fd"
    # {fd}>&-: the child must not inherit the held lock descriptor.
    bash "$s" add guest --json --yes "${MOCK_ARGS[@]}" > "$TEST_DIR/race.out" 2> "$TEST_DIR/race.err" {fd}>&- &
    pid=$!
    for _ in $(seq 1 100); do
        if pgrep -P "$pid" -x flock >/dev/null; then blocked=1; break; fi
        sleep 0.1
    done
    if [ "$blocked" != 1 ]; then
        flock -u "$fd"; exec {fd}>&-; wait "$pid"
        echo "add never blocked on the config lock" >&2; return 1
    fi
    printf '\n[Peer]\n#_Name = guest\nPublicKey = cmFjZS1wZWVyLWtleS1wbGFjZWhvbGRlci0wMDAwMDA=\nAllowedIPs = 10.9.9.200/32\n' >> "$TEST_DIR/awg/awg0.conf"
    mkdir -p "$EXP"
    printf '%s\n' 1999999999 > "$EXP/guest"
    flock -u "$fd"
    exec {fd}>&-
    wait "$pid" || rc=$?
    [ "$rc" -ne 0 ]
    jq -e '.results[0].status == "exists"' "$TEST_DIR/race.out" >/dev/null
    if [ "$(cat "$EXP/guest" 2>/dev/null)" != "1999999999" ]; then
        echo "the parallel client's fresh stamp was removed" >&2; return 1
    fi
    if [ ! -e "$TEST_DIR/awg/guest.png" ] || [ ! -e "$TEST_DIR/awg/guest.vpnuri" ]; then
        echo "the parallel client's QR or vpn:// file was removed" >&2; return 1
    fi
}

@test "RU: add re-checks the name under the config lock and keeps a parallel client's stamp" {
    require_jq
    command -v pgrep >/dev/null || skip "pgrep not available"
    _scenario_add_race "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
}

@test "EN: add re-checks the name under the config lock and keeps a parallel client's stamp" {
    require_jq
    command -v pgrep >/dev/null || skip "pgrep not available"
    _scenario_add_race "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
}
# restore: the archive carries carol's stamp, but it cannot be copied into
# place (a non-empty directory sits there). The copy is best-effort, so without
# a check carol would keep the current state's deadline. restore must fail and
# roll back.
_scenario_restore_archive_stamp_stuck() {
    local s="$1" b1
    _m "$s" add carol --expires=30d --json
    [ "$status" -eq 0 ]
    b1=$(_backup "$s")
    [ -n "$b1" ]
    grep -qE '(^|/)expiry/carol$' <<< "$(tar -tzf "$b1")"
    rm -f "$EXP/carol"
    mkdir -p "$EXP/carol/stuck"
    _m "$s" restore "$b1" --json
    [ "$status" -ne 0 ]
    printf '%s' "$output" | jq -e '.ok == false and .rolled_back == true' >/dev/null
    if ! LC_ALL=C.UTF-8 grep -qE "(Метка срока клиента 'carol' из архива не восстановлена|The expiry stamp of client 'carol' from the archive was not restored)" <<< "$stderr"; then
        echo "restore failed for another reason: $stderr" >&2; return 1
    fi
    [ ! -s "$TEST_DIR/net.log" ]
}

@test "RU: restore rolls back when an archived expiry stamp cannot be put in place" {
    require_jq
    _scenario_restore_archive_stamp_stuck "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
}

@test "EN: restore rolls back when an archived expiry stamp cannot be put in place" {
    require_jq
    _scenario_restore_archive_stamp_stuck "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
}
