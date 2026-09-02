#!/usr/bin/env bats
# issue #250 - expires_at and expires_at_error in every `list --json` record.
#
# Before this change the expiry marker was read for the table output only, so a
# machine consumer (GUI, bot, monitoring) could not tell a client with an expiry
# from a permanent one without reading /root/awg/expiry/ over SSH. The field
# mirrors the semantics `add` already uses: unix time as a number, or null.
#
# These tests drive the REAL get_client_expiry against REAL marker files. An
# earlier revision stubbed the helper, and that stub could not fail the way the
# code fails: it modelled the return value, while every interesting failure
# lives in the difference between "no file", "empty file", "directory in place
# of the file" and "file that cannot be read". Those four collapse to the same
# empty string, which is exactly why the emitter tests existence separately.
#
# shellcheck disable=SC2034  # VERBOSE_LIST/NO_COLOR are consumed by the eval'd list_clients

load test_helper

require_jq()      { command -v jq &>/dev/null || skip "jq not available"; }
require_python3() { command -v python3 &>/dev/null || skip "python3 not available"; }

_add_peer() {
    local name="$1" ipv4="$2"
    cat >> "$SERVER_CONF_FILE" << EOF

[Peer]
#_Name = ${name}
PublicKey = PK_${name}
AllowedIPs = ${ipv4}/32
EOF
}

_make_client_conf() {
    local name="$1" ipv4="$2"
    cat > "$AWG_DIR/${name}.conf" << EOF
[Interface]
PrivateKey = PRIV_${name}
Address = ${ipv4}/32
DNS = 1.1.1.1
MTU = 1280
[Peer]
PublicKey = SERVERPUB
AllowedIPs = 0.0.0.0/0
EOF
}

_set_marker() {
    mkdir -p "$EXPIRY_DIR"
    printf '%s' "$2" > "$EXPIRY_DIR/$1"
}

# Source-safe loader: pull list_clients out of the script with the stubs it
# needs. get_client_expiry is deliberately NOT stubbed - it is the code under
# test. format_remaining is, so the table assertions stay deterministic.
_load_list_clients() {
    local src="$1"
    JSON_OUTPUT="${JSON_OUTPUT:-1}"
    VERBOSE_LIST="${VERBOSE_LIST:-0}"
    NO_COLOR=1
    # json_escape lives in manage_amneziawg.sh, not in awg_common.sh, so the
    # loader has to provide it. Copied byte for byte from
    # tests/test_status_code_json.bats: an earlier hand-typed copy here lost one
    # backslash and silently stopped doubling them, which made the file certify
    # its own stub instead of the emitter.
    json_escape() { local s="$1"; s="${s//\/\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }
    json_out() { printf '%s\n' "$1"; }
    format_remaining() { echo "3d left"; }
    # Warnings must stay visible to assertions: test_helper silences log_warn,
    # and a silenced warning is indistinguishable from one never emitted.
    log_warn() { printf '%s\n' "$*" >> "$TEST_DIR/warns.txt"; }
    awg() { return 1; }
    eval "$(awk '/^list_clients\(\)/{p=1} p{print} p && /^\}$/{exit}' "$src")"
}

_one_client() {
    create_server_config
    _add_peer "alice" "10.9.9.2"
    _make_client_conf "alice" "10.9.9.2"
}

_two_clients() {
    _one_client
    _add_peer "bob" "10.9.9.3"
    _make_client_conf "bob" "10.9.9.3"
}

_RU="${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"
_EN="${BATS_TEST_DIRNAME}/../manage_amneziawg_en.sh"

@test "expires_at: a valid marker reports the timestamp as a number (RU)" {
    _one_client
    _set_marker alice 1750000000
    _load_list_clients "$_RU"

    run list_clients
    [ "$status" -eq 0 ]
    # Unquoted: a JSON number, not a string - the consumer compares it with time().
    echo "$output" | grep -q '"expires_at":1750000000' || { echo "no numeric expires_at in: $output"; false; }
    echo "$output" | grep -q '"expires_at_error":null' || { echo "error key missing or not null in: $output"; false; }
}

@test "expires_at: no marker at all means a permanent client, both keys null (RU)" {
    _one_client
    _load_list_clients "$_RU"

    run list_clients
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"expires_at":null' || { echo "no null expires_at in: $output"; false; }
    echo "$output" | grep -q '"expires_at_error":null' || { echo "error key missing or not null in: $output"; false; }
}

@test "expires_at: junk in the marker is unreadable, not permanent (RU)" {
    _one_client
    _set_marker alice "not-a-timestamp"
    _load_list_clients "$_RU"

    run list_clients
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"expires_at":null' || { echo "no null expires_at in: $output"; false; }
    echo "$output" | grep -q '"expires_at_error":"unreadable"' || { echo "no error marker in: $output"; false; }
}

@test "expires_at: an EMPTY marker file is unreadable, not permanent (RU)" {
    _one_client
    _set_marker alice ""
    _load_list_clients "$_RU"

    run list_clients
    [ "$status" -eq 0 ]
    # The reader returns "" for a missing file and for an empty one alike. The
    # expiry check treats an empty marker as corrupt and never removes the
    # client, so reporting "permanent" here would be a confident false claim.
    echo "$output" | grep -q '"expires_at_error":"unreadable"' || { echo "empty marker passed as permanent: $output"; false; }
}

@test "expires_at: a DIRECTORY in place of the marker is unreadable (RU)" {
    _one_client
    mkdir -p "$EXPIRY_DIR/alice"
    _load_list_clients "$_RU"

    run list_clients
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"expires_at_error":"unreadable"' || { echo "directory passed as permanent: $output"; false; }
}

@test "expires_at: an unreadable state is announced in the log, not only in JSON" {
    _one_client
    _set_marker alice "not-a-timestamp"
    _load_list_clients "$_RU"

    run list_clients
    [ "$status" -eq 0 ]
    # A machine field alone is not enough: the operator running the command has
    # to learn that a marker is broken.
    [ -f "$TEST_DIR/warns.txt" ] || { echo "no warning emitted at all"; false; }
    grep -q "alice" "$TEST_DIR/warns.txt" || { echo "warning does not name the client"; false; }
}

@test "expires_at: a marker with a leading zero is unreadable, not a number (RU)" {
    _one_client
    _set_marker alice 01750000000
    _load_list_clients "$_RU"

    run list_clients
    [ "$status" -eq 0 ]
    # JSON forbids leading zeros, so emitting this as a number breaks the whole
    # document for a strict parser. Bash reads it as octal too, which is why the
    # expiry check used to delete such a client on a bogus date.
    echo "$output" | grep -q '"expires_at":null' || { echo "not null in: $output"; false; }
    echo "$output" | grep -q '"expires_at_error":"unreadable"' || { echo "no error marker in: $output"; false; }
}

@test "expires_at: an over-long marker is unreadable, not a number (RU)" {
    _one_client
    _set_marker alice 99999999999999999999999999
    _load_list_clients "$_RU"

    run list_clients
    [ "$status" -eq 0 ]
    # Python and jq accept a bignum, Go int64 and .NET GetInt64 do not - and
    # those are the documented audience. The leading-zero argument, one step on.
    echo "$output" | grep -q '"expires_at_error":"unreadable"' || { echo "over-long value accepted: $output"; false; }
}

@test "expires_at: accepted and rejected value forms" {
    _one_client
    _load_list_clients "$_RU"

    local v
    for v in 0 1 1750000000 9999999999; do
        _set_marker alice "$v"
        run list_clients
        echo "$output" | grep -q "\"expires_at\":$v" || { echo "form '$v' should be accepted, got: $output"; false; }
    done
    for v in -1 +1 01 007 1e9 "17.0" 12345678901; do
        _set_marker alice "$v"
        run list_clients
        echo "$output" | grep -q '"expires_at":null' || { echo "form '$v' should be rejected, got: $output"; false; }
    done
}

@test "expires_at: a client name that fails validation is not turned into a path" {
    create_server_config
    _add_peer "../escape" "10.9.9.9"
    mkdir -p "$EXPIRY_DIR"
    printf '1750000000' > "$AWG_DIR/escape"
    _load_list_clients "$_RU"

    run list_clients
    [ "$status" -eq 0 ]
    # The name comes from the server config and used to be interpolated into
    # $EXPIRY_DIR/$name unchecked, so a traversing name published the contents
    # of a file outside the marker directory.
    echo "$output" | grep -q '"expires_at":1750000000' && { echo "read a file outside the marker directory: $output"; false; }
    echo "$output" | grep -q '"expires_at_error":"unreadable"' || { echo "no error marker for an invalid name: $output"; false; }
}

@test "expires_at: a valid marker reports the timestamp as a number (EN)" {
    _one_client
    _set_marker alice 1750000000
    _load_list_clients "$_EN"

    run list_clients
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"expires_at":1750000000' || { echo "no numeric expires_at in: $output"; false; }
    echo "$output" | grep -q '"expires_at_error":null' || { echo "error key missing or not null in: $output"; false; }
}

@test "expires_at: no marker means both keys null (EN)" {
    _one_client
    _load_list_clients "$_EN"

    run list_clients
    [ "$status" -eq 0 ]
    # Without this case the EN defaults are unpinned: flipping _jexp to "0" or
    # _jexp_err to "unreadable" in the EN script alone survived the suite, and
    # that is precisely the shape RU/EN drift takes.
    echo "$output" | grep -q '"expires_at":null' || { echo "no null expires_at in: $output"; false; }
    echo "$output" | grep -q '"expires_at_error":null' || { echo "error key missing or not null in: $output"; false; }
}

@test "expires_at: junk in the marker is unreadable (EN)" {
    _one_client
    _set_marker alice "not-a-timestamp"
    _load_list_clients "$_EN"

    run list_clients
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"expires_at_error":"unreadable"' || { echo "no error marker in: $output"; false; }
}

@test "expires_at: a broken marker on one client does not smear onto the next" {
    _two_clients
    _set_marker alice "not-a-timestamp"
    require_jq
    _load_list_clients "$_RU"

    run list_clients
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '
        (map(select(.name == "alice"))[0] | .expires_at == null and .expires_at_error == "unreadable")
        and (map(select(.name == "bob"))[0] | .expires_at == null and .expires_at_error == null)' >/dev/null
}

@test "expires_at: a valid marker does not leak onto a permanent client" {
    _two_clients
    _set_marker alice 1750000000
    require_jq
    _load_list_clients "$_RU"

    run list_clients
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '
        (map(select(.name == "alice"))[0].expires_at == 1750000000)
        and (map(select(.name == "bob"))[0].expires_at == null)' >/dev/null
}

@test "expires_at: the remaining-time string stays out of JSON (RU)" {
    _one_client
    _set_marker alice 1750000000
    _load_list_clients "$_RU"

    run list_clients
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '3d left' && { echo "human string leaked into JSON: $output"; false; }
    :
}

@test "expires_at: table output shows the remaining time (RU)" {
    _one_client
    _set_marker alice 1750000000
    export JSON_OUTPUT=0
    _load_list_clients "$_RU"

    run list_clients
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '\[3d left\]' || { echo "remaining time missing from table: $output"; false; }
    echo "$output" | grep -q 'expires_at' && { echo "JSON key leaked into the table: $output"; false; }
    :
}

@test "expires_at: verbose table shows the remaining time too (RU)" {
    _one_client
    _set_marker alice 1750000000
    export JSON_OUTPUT=0 VERBOSE_LIST=1
    _load_list_clients "$_RU"

    run list_clients
    [ "$status" -eq 0 ]
    # `list -v` is the documented way to check expiry, and it renders through a
    # different printf than the plain table.
    echo "$output" | grep -q '\[3d left\]' || { echo "remaining time missing from verbose table: $output"; false; }
}

@test "expires_at: table output marks a broken marker (RU)" {
    _one_client
    _set_marker alice "not-a-timestamp"
    export JSON_OUTPUT=0
    _load_list_clients "$_RU"

    run list_clients
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'expiry' || { echo "no broken-marker note in the table: $output"; false; }
}

@test "expires_at: table output marks a broken marker (EN)" {
    _one_client
    _set_marker alice "not-a-timestamp"
    export JSON_OUTPUT=0
    _load_list_clients "$_EN"

    run list_clients
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'expiry' || { echo "no broken-marker note in the table: $output"; false; }
}

@test "expires_at: every record carries both keys, not just the first" {
    _two_clients
    _set_marker alice 1750000000
    _load_list_clients "$_RU"

    run list_clients
    [ "$status" -eq 0 ]
    local n
    n=$(echo "$output" | grep -o '"expires_at":' | wc -l)
    [ "$n" -eq 2 ] || { echo "expected 2 expires_at keys, got $n in: $output"; false; }
    n=$(echo "$output" | grep -o '"expires_at_error":' | wc -l)
    [ "$n" -eq 2 ] || { echo "expected 2 expires_at_error keys, got $n in: $output"; false; }
}

@test "expires_at: the document survives a STRICT parser, not just jq" {
    _one_client
    _set_marker alice 1750000000
    require_python3
    _load_list_clients "$_RU"

    run list_clients
    [ "$status" -eq 0 ]
    # jq is a LENIENT reader: it accepts a number with a leading zero and
    # silently normalises it, so a jq-only assertion certifies less than it
    # looks. The consumers here are GUIs and bots on .NET, Go and Python.
    printf '%s' "$output" | python3 -c '
import json,sys
d = json.load(sys.stdin)
assert isinstance(d, list) and d, "not a non-empty array"
e = d[0]["expires_at"]
assert isinstance(e, int), "expires_at is %r, expected int" % (e,)
assert d[0]["expires_at_error"] is None, "expires_at_error should be null here"
'
}

@test "expires_at: a leading zero cannot reach a strict parser" {
    _one_client
    _set_marker alice 01750000000
    require_python3
    _load_list_clients "$_RU"

    run list_clients
    [ "$status" -eq 0 ]
    # This is the case the whole strictness argument exists for: with a lenient
    # regex the document below fails to parse at all.
    printf '%s' "$output" | python3 -c '
import json,sys
d = json.load(sys.stdin)
assert d[0]["expires_at"] is None, "expected null, got %r" % (d[0]["expires_at"],)
assert d[0]["expires_at_error"] == "unreadable"
'
}

@test "expires_at: a marker that exists but cannot be read is unreadable" {
    _one_client
    _set_marker alice 1750000000
    chmod 000 "$EXPIRY_DIR/alice" 2>/dev/null || true
    # Self-check: on filesystems where the mode does not actually deny reads
    # (Windows checkouts) this case cannot be exercised, and asserting anyway
    # would make the suite pass for the wrong reason on CI and fail here.
    if cat "$EXPIRY_DIR/alice" >/dev/null 2>&1; then
        chmod 644 "$EXPIRY_DIR/alice" 2>/dev/null || true
        skip "permissions are not enforced on this filesystem"
    fi
    _load_list_clients "$_RU"

    run list_clients
    local rc="$status"
    chmod 644 "$EXPIRY_DIR/alice" 2>/dev/null || true
    [ "$rc" -eq 0 ]
    # The read fails, the output is empty and indistinguishable from an absent
    # marker; only the exit status tells them apart. Reporting "permanent" here
    # would be the loudest failure turned quiet.
    echo "$output" | grep -q '"expires_at_error":"unreadable"' || { echo "unreadable file passed as permanent: $output"; false; }
}

# --- the other consumer of the same marker ----------------------------------
#
# check_expired_clients reads the same files and had no tests at all. Its
# validation used to be looser than the emitter's, so the two disagreed about
# what a valid marker is - and the looser side is the one that DELETES clients.

_load_expiry_check() {
    _removed=""
    remove_peer_from_server() { _removed="$_removed $1"; return 0; }
    _remove_client_files()    { :; }
    remove_client_expiry()    { rm -f "$EXPIRY_DIR/$1"; }
    log_warn() { printf '%s\n' "$*" >> "$TEST_DIR/warns.txt"; }
    log()      { :; }
}

@test "expiry check: a genuinely expired client IS removed (positive control)" {
    _one_client
    _set_marker alice 1000000000
    _load_expiry_check

    run check_expired_clients
    # Without this control the two cases below would pass even if the function
    # had stopped removing anything at all.
    [ -f "$EXPIRY_DIR/alice" ] && { echo "marker still present, nothing was removed"; false; }
    :
}

@test "expiry check: a leading-zero marker does NOT delete the client" {
    _one_client
    _set_marker alice 01750000000
    _load_expiry_check

    run check_expired_clients
    # Read as octal this is 262144000, i.e. 1978, so the loose form let the
    # comparison fire and the client was deleted on a bogus date.
    [ -f "$EXPIRY_DIR/alice" ] || { echo "client was deleted on an octal-misread marker"; false; }
}

@test "expiry check: junk in the marker does NOT delete the client" {
    _one_client
    _set_marker alice "not-a-timestamp"
    _load_expiry_check

    run check_expired_clients
    [ -f "$EXPIRY_DIR/alice" ] || { echo "client was deleted on an unparseable marker"; false; }
}

@test "expiry check: an over-long marker does NOT delete the client" {
    _one_client
    _set_marker alice 99999999999999999999999999
    _load_expiry_check

    run check_expired_clients
    [ -f "$EXPIRY_DIR/alice" ] || { echo "client was deleted on an over-long marker"; false; }
}
