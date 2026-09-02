#!/usr/bin/env bats
# issue #250 - expires_at in every `list --json` record.
#
# Before this change the expiry marker was read for the table output only, so a
# machine consumer (GUI, bot, monitoring) could not tell a client with an expiry
# from a permanent one without reading /root/awg/expiry/ over SSH. The field
# mirrors the semantics already used by `add`: unix time as a number, or null.
#
# The corrupted-marker case is covered on purpose: a bare null there would claim
# "permanent" about a client that DOES have an expiry cron may apply, so the
# emitter must keep the unknown visible via expires_at_error.
#
# shellcheck disable=SC2034  # VERBOSE_LIST/NO_COLOR are consumed by the eval'd list_clients

load test_helper

require_jq() { command -v jq &>/dev/null || skip "jq not available"; }

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

# Source-safe loader, same shape as test_status_code_json.bats: pull list_clients
# out of the script together with the stubs it depends on.
#
# The expiry stub is NAME-AWARE on purpose. A stub that ignores its argument and
# returns one global value cannot fail when the emitter mixes clients up: every
# record would look right because every record is meant to be identical. Here a
# client reads its own marker from _EXP_<name>, and an unset variable means "no
# marker file", so one run can hold a valid, a missing and a broken marker at once.
_load_list_clients() {
    local src="$1"
    JSON_OUTPUT="${JSON_OUTPUT:-1}"
    VERBOSE_LIST=0
    NO_COLOR=1
    json_escape() { local s="$1"; s="${s//\/\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }
    json_out() { printf '%s\n' "$1"; }
    format_remaining() { echo "3d left"; }
    get_client_expiry() { local _v="_EXP_$1"; printf '%s' "${!_v-}"; }
    awg() { return 1; }
    eval "$(awk '/^list_clients\(\)/{p=1} p{print} p && /^\}$/{exit}' "$src")"
}

_setup_one_client() {
    create_server_config
    _add_peer "alice" "10.9.9.2"
    _make_client_conf "alice" "10.9.9.2"
}

@test "expires_at: timed client reports the timestamp as a number (RU)" {
    _setup_one_client
    export JSON_OUTPUT=1 _EXP_alice=1750000000
    _load_list_clients "${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"

    run list_clients
    [ "$status" -eq 0 ]
    # Unquoted: a JSON number, not a string - the consumer compares it with time().
    echo "$output" | grep -q '"expires_at":1750000000' || { echo "no numeric expires_at in: $output"; false; }
    echo "$output" | grep -q '"expires_at_error":null' || { echo "error key missing or not null in: $output"; false; }
}

@test "expires_at: permanent client reports null (RU)" {
    _setup_one_client
    export JSON_OUTPUT=1; unset _EXP_alice
    _load_list_clients "${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"

    run list_clients
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"expires_at":null' || { echo "no null expires_at in: $output"; false; }
    # The key is always present; a permanent client differs from a broken one by
    # the VALUE, not by the key showing up. An absent key would make the record
    # shape depend on the data.
    echo "$output" | grep -q '"expires_at_error":null' || { echo "error key missing or not null in: $output"; false; }
}

@test "expires_at: unreadable marker keeps the unknown visible, not a bare null (RU)" {
    _setup_one_client
    export JSON_OUTPUT=1 _EXP_alice="not-a-timestamp"
    _load_list_clients "${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"

    run list_clients
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"expires_at":null' || { echo "no null expires_at in: $output"; false; }
    echo "$output" | grep -q '"expires_at_error":"unreadable"' || { echo "no error marker in: $output"; false; }
}

@test "expires_at: timed client reports the timestamp as a number (EN)" {
    _setup_one_client
    export JSON_OUTPUT=1 _EXP_alice=1750000000
    _load_list_clients "${BATS_TEST_DIRNAME}/../manage_amneziawg_en.sh"

    run list_clients
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"expires_at":1750000000' || { echo "no numeric expires_at in: $output"; false; }
}

@test "expires_at: unreadable marker keeps the unknown visible (EN)" {
    _setup_one_client
    export JSON_OUTPUT=1 _EXP_alice="not-a-timestamp"
    _load_list_clients "${BATS_TEST_DIRNAME}/../manage_amneziawg_en.sh"

    run list_clients
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"expires_at_error":"unreadable"' || { echo "no error marker in: $output"; false; }
}

@test "expires_at: the remaining-time string stays out of JSON (RU)" {
    _setup_one_client
    export JSON_OUTPUT=1 _EXP_alice=1750000000
    _load_list_clients "${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"

    run list_clients
    [ "$status" -eq 0 ]
    # format_remaining is for humans; leaking it into the machine output would
    # give the consumer a localized string it cannot parse.
    echo "$output" | grep -q '3d left' && { echo "human string leaked into JSON: $output"; false; }
    :
}

@test "expires_at: table output still shows the remaining time (RU)" {
    _setup_one_client
    export JSON_OUTPUT=0 _EXP_alice=1750000000
    _load_list_clients "${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"

    run list_clients
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '\[3d left\]' || { echo "remaining time missing from table: $output"; false; }
    echo "$output" | grep -q 'expires_at' && { echo "JSON key leaked into the table: $output"; false; }
    :
}

@test "expires_at: every record carries the field, not just the first (RU)" {
    create_server_config
    _add_peer "alice" "10.9.9.2"
    _make_client_conf "alice" "10.9.9.2"
    _add_peer "bob" "10.9.9.3"
    _make_client_conf "bob" "10.9.9.3"
    export JSON_OUTPUT=1 _EXP_alice=1750000000
    _load_list_clients "${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"

    run list_clients
    [ "$status" -eq 0 ]
    local n
    n=$(echo "$output" | grep -o '"expires_at":' | wc -l)
    [ "$n" -eq 2 ] || { echo "expected 2 expires_at keys, got $n in: $output"; false; }
}

@test "expires_at: the emitted document is valid JSON, not just matching text" {
    _setup_one_client
    export JSON_OUTPUT=1 _EXP_alice=1750000000
    require_jq
    _load_list_clients "${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"

    run list_clients
    [ "$status" -eq 0 ]
    # Substring assertions cannot see a broken document: they pass on trailing
    # garbage and on numbers JSON does not allow. Parse it instead.
    printf '%s' "$output" | jq -e 'type == "array"' >/dev/null
    printf '%s' "$output" | jq -e '.[0].expires_at | type == "number"' >/dev/null
}

@test "expires_at: a marker with a leading zero is unreadable, not a number" {
    _setup_one_client
    export JSON_OUTPUT=1 _EXP_alice=01750000000
    require_jq
    _load_list_clients "${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"

    run list_clients
    [ "$status" -eq 0 ]
    # JSON forbids leading zeros, so emitting this as a number breaks the whole
    # document for a strict parser. Bash reads it as octal too, so cron never
    # applies such a marker - "unreadable" is the honest answer, not a number.
    echo "$output" | grep -q '"expires_at":null' || { echo "not null in: $output"; false; }
    echo "$output" | grep -q '"expires_at_error":"unreadable"' || { echo "no error marker in: $output"; false; }
    # Validate with a STRICT parser, not with jq: jq accepts a leading zero and
    # normalises it silently, so a jq assertion here would stay green in exactly
    # the case this test exists for. Python rejects the whole document, which is
    # what the consumer would do.
    if command -v python3 &>/dev/null; then
        printf '%s' "$output" | python3 -c '
import json,sys
d = json.load(sys.stdin)
assert d[0]["expires_at"] is None, "expected null, got %r" % (d[0]["expires_at"],)
'
    fi
}

@test "expires_at: a broken marker on one client does not smear onto the next" {
    create_server_config
    _add_peer "alice" "10.9.9.2"
    _make_client_conf "alice" "10.9.9.2"
    _add_peer "bob" "10.9.9.3"
    _make_client_conf "bob" "10.9.9.3"
    # alice has a broken marker, bob has none at all. If the emitter carried
    # state between iterations, bob would inherit alice's error flag.
    export JSON_OUTPUT=1 _EXP_alice="not-a-timestamp"
    unset _EXP_bob
    require_jq
    _load_list_clients "${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"

    run list_clients
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '
        (map(select(.name == "alice"))[0] | .expires_at == null and .expires_at_error == "unreadable")
        and (map(select(.name == "bob"))[0] | .expires_at == null and .expires_at_error == null and has("expires_at_error"))' >/dev/null
}

@test "expires_at: a valid marker does not leak onto a permanent client" {
    create_server_config
    _add_peer "alice" "10.9.9.2"
    _make_client_conf "alice" "10.9.9.2"
    _add_peer "bob" "10.9.9.3"
    _make_client_conf "bob" "10.9.9.3"
    export JSON_OUTPUT=1 _EXP_alice=1750000000
    unset _EXP_bob
    require_jq
    _load_list_clients "${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"

    run list_clients
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '
        (map(select(.name == "alice"))[0].expires_at == 1750000000)
        and (map(select(.name == "bob"))[0].expires_at == null)' >/dev/null
}

require_python3() { command -v python3 &>/dev/null || skip "python3 not available"; }

@test "expires_at: the document survives a STRICT parser, not just jq" {
    _setup_one_client
    export JSON_OUTPUT=1 _EXP_alice=1750000000
    require_python3
    _load_list_clients "${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"

    run list_clients
    [ "$status" -eq 0 ]
    # jq is a LENIENT reader: it accepts a number with a leading zero and
    # silently normalises it, so a jq-only assertion certifies less than it
    # looks. The consumers of this output are GUIs and bots on .NET, Go and
    # Python, and those reject such a document whole. Validate with a strict
    # parser so the guarantee matches the audience.
    printf '%s' "$output" | python3 -c '
import json,sys
d = json.load(sys.stdin)
assert isinstance(d, list) and d, "not a non-empty array"
e = d[0]["expires_at"]
assert isinstance(e, int), "expires_at is %r, expected int" % (e,)
'
}
