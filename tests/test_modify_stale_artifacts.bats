#!/usr/bin/env bats
# manage modify and the files derived from a client config (QR, vpn://).
#
# modify edits NAME.conf and then rebuilds NAME.png, NAME.vpnuri and
# NAME.vpnuri.png. A rebuild that failed used to leave the previous files in
# place: they still carried the old values while the command reported success,
# so anything that hands those files out could serve them as current. That
# happened without qrencode or the perl modules, and with the I1-I5 check a
# server with a refused value became one more way: generate_vpn_uri stops on
# load_awg_params while the .conf edit goes through.
#
# modify now removes the derived files BEFORE the .conf edit and rebuilds them
# after it. A failed or interrupted rebuild leaves a missing file, never a stale
# copy; a removal that fails returns an error with the .conf untouched; a value
# refused by modify's own check, or a refusal after the lock, keeps the files;
# a client config that already carries an unsafe I1-I5 is not reissued. The JSON
# envelope reports qr and vpnuri the way add does: a path when the file exists,
# null when it does not. The rebuilt files are checked for CONTENT, not only for
# presence, so a rebuild moved before the edit cannot pass.
#
# Every scenario runs against both manage twins: the RU and EN scripts each
# carry their own copy of modify_client and of the dispatcher.

# shellcheck disable=SC2154  # $stderr is set by bats `run --separate-stderr`

bats_require_minimum_version 1.5.0

require_flock() { command -v flock &>/dev/null || skip "flock not available (not Linux)"; }
require_jq() { command -v jq &>/dev/null || skip "jq not available"; }
require_uri_perl() {
    perl -MCompress::Zlib -MMIME::Base64 -e 1 2>/dev/null || skip "perl with Compress::Zlib not available"
}

REPRO='<b 0x0102><r -1>'
MANAGE="${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"
MANAGE_EN="${BATS_TEST_DIRNAME}/../manage_amneziawg_en.sh"

setup() {
    ORIG_PATH="$PATH"
    REAL_RM=$(command -v rm)
    REAL_SED=$(command -v sed)
    MGMT_DIR=$(mktemp -d)
    A="$MGMT_DIR/awg"
    mkdir -p "$MGMT_DIR/bin" "$A/keys"
    cat > "$MGMT_DIR/bin/awg" << 'STUB'
#!/bin/bash
case "$1" in
    genkey|genpsk) echo "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ;;
    pubkey) cat >/dev/null; echo "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=" ;;
    *) exit 0 ;;
esac
STUB
    chmod +x "$MGMT_DIR/bin/awg"
    export PATH="$MGMT_DIR/bin:$PATH"
    cp "$BATS_TEST_DIRNAME/../awg_common.sh" "$A/awg_common.sh"
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
    export AWG_SKIP_APPLY=1
}

teardown() {
    # Stubs (rm, sed, qrencode) live in $MGMT_DIR/bin: drop them from PATH
    # before the directory goes, or bats itself calls a removed tool afterwards.
    export PATH="$ORIG_PATH"
    hash -r
    command rm -rf "${MGMT_DIR:-}"
    unset AWG_SKIP_APPLY PROBE_TARGET PROBE_OUT
}

use_en() {
    cp "$BATS_TEST_DIRNAME/../awg_common_en.sh" "$A/awg_common.sh"
    MANAGE="$MANAGE_EN"
}

mgmt() {  # mgmt <manage args...>
    bash "$MANAGE" "$@" --yes --conf-dir="$A" --server-conf="$A/awg0.conf"
}

poison_i3() {
    sed -i "/^H4 = /a I3 = $REPRO" "$A/awg0.conf"
    grep -qxF "I3 = $REPRO" "$A/awg0.conf"
}

# qrencode stubs: one that always fails, one that copies its input to the -o
# target (so the QR file carries the content it was built from), and a probe
# that records whether PROBE_TARGET exists when it runs.
stub_qrencode_fail() {
    printf '#!/bin/bash\nexit 1\n' > "$MGMT_DIR/bin/qrencode"
    chmod +x "$MGMT_DIR/bin/qrencode"
}
stub_qrencode_ok() {
    cat > "$MGMT_DIR/bin/qrencode" << 'STUB'
#!/bin/bash
out=""
while [ $# -gt 0 ]; do
    if [ "$1" = "-o" ]; then shift; out="$1"; fi
    shift
done
[ -n "$out" ] || exit 1
cat > "$out"
STUB
    chmod +x "$MGMT_DIR/bin/qrencode"
}
stub_qrencode_probe() {
    cat > "$MGMT_DIR/bin/qrencode" << 'STUB'
#!/bin/bash
if [ -e "$PROBE_TARGET" ]; then echo present >> "$PROBE_OUT"; else echo absent >> "$PROBE_OUT"; fi
exit 1
STUB
    chmod +x "$MGMT_DIR/bin/qrencode"
}

# The file a failed rebuild would leave behind, with content no generator produces.
plant() { printf 'OLD\n' > "$A/$1"; }

add_alice() {
    run --separate-stderr mgmt add alice --json
    [ "$status" -eq 0 ]
    [ -f "$A/alice.conf" ]
}

one_json_line() {
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
    printf '%s' "$output" | jq -e . >/dev/null
}

# Outer JSON of a vpn:// link: base64url of a 4-byte length plus zlib data.
decode_vpnuri() {
    perl -MCompress::Zlib -MMIME::Base64 -e '
        my $s = <STDIN>; chomp $s; $s =~ s{^vpn://}{}; $s =~ tr{-_}{+/};
        $s .= "=" x ((4 - length($s) % 4) % 4);
        my $d = decode_base64($s); print uncompress(substr($d, 4));' < "$1"
}

# ------------------------------------------------------------------ scenarios

refused_vpnuri_leaves_no_vpnuri() {
    require_flock
    require_jq
    require_uri_perl
    stub_qrencode_fail
    add_alice
    plant alice.vpnuri
    plant alice.vpnuri.png
    poison_i3
    run --separate-stderr mgmt modify alice DNS 8.8.4.4 --json
    [ "$status" -eq 0 ]
    grep -qxF 'DNS = 8.8.4.4' "$A/alice.conf"
    [ ! -e "$A/alice.vpnuri" ]
    [ ! -e "$A/alice.vpnuri.png" ]
    one_json_line
    printf '%s' "$output" | jq -e 'has("qr") and has("vpnuri") and .ok == true and .vpnuri == null' >/dev/null
    # The refusal names its reason, and the log names the file that is missing.
    [[ "$stderr" == *"I3"* ]]
    [[ "$stderr" == *"alice.vpnuri"* ]]
}

refused_vpnuri_keeps_fresh_qr() {
    require_flock
    require_jq
    require_uri_perl
    stub_qrencode_ok
    add_alice
    plant alice.png
    plant alice.vpnuri
    poison_i3
    run --separate-stderr mgmt modify alice DNS 8.8.4.4 --json
    [ "$status" -eq 0 ]
    grep -qxF 'DNS = 8.8.4.4' "$A/alice.png"
    [ ! -e "$A/alice.vpnuri" ]
    printf '%s' "$output" | jq -e --arg q "$A/alice.png" '.qr == $q and has("vpnuri") and .vpnuri == null' >/dev/null
}

failed_qr_leaves_no_png() {
    require_flock
    require_jq
    stub_qrencode_fail
    add_alice
    plant alice.png
    run --separate-stderr mgmt modify alice DNS 8.8.4.4 --json
    [ "$status" -eq 0 ]
    [ ! -e "$A/alice.png" ]
    printf '%s' "$output" | jq -e 'has("qr") and has("vpnuri") and .ok == true and .qr == null' >/dev/null
}

failed_vpnuri_qr_leaves_fresh_uri() {
    require_flock
    require_jq
    require_uri_perl
    stub_qrencode_fail
    add_alice
    plant alice.vpnuri
    plant alice.vpnuri.png
    run --separate-stderr mgmt modify alice DNS 8.8.4.4 --json
    [ "$status" -eq 0 ]
    [ ! -e "$A/alice.vpnuri.png" ]
    decode_vpnuri "$A/alice.vpnuri" | grep -qF '"dns1":"8.8.4.4"'
    printf '%s' "$output" | jq -e --arg p "$A/alice.vpnuri" '.ok == true and .vpnuri == $p' >/dev/null
}

successful_rebuild_carries_the_new_value() {
    require_flock
    require_jq
    require_uri_perl
    stub_qrencode_ok
    add_alice
    plant alice.png
    plant alice.vpnuri
    plant alice.vpnuri.png
    run --separate-stderr mgmt modify alice DNS 8.8.4.4 --json
    [ "$status" -eq 0 ]
    # Content, not presence: built from the edited .conf, not from the old one.
    grep -qxF 'DNS = 8.8.4.4' "$A/alice.png"
    decode_vpnuri "$A/alice.vpnuri" | grep -qF '"dns1":"8.8.4.4"'
    cmp -s "$A/alice.vpnuri" "$A/alice.vpnuri.png"
    one_json_line
    printf '%s' "$output" | jq -e --arg q "$A/alice.png" --arg u "$A/alice.vpnuri" \
        '.ok == true and .qr == $q and .vpnuri == $u' >/dev/null
}

old_files_are_gone_before_the_rebuild() {
    require_flock
    stub_qrencode_fail
    add_alice
    stub_qrencode_probe
    plant alice.vpnuri
    export PROBE_TARGET="$A/alice.vpnuri" PROBE_OUT="$MGMT_DIR/probe"
    run --separate-stderr mgmt modify alice DNS 8.8.4.4
    [ "$status" -eq 0 ]
    # The first rebuild step (the QR of the .conf) already sees no old vpn:// file:
    # an interruption from here on leaves a missing file, not a stale one.
    [ "$(head -n1 "$PROBE_OUT")" = "absent" ]
}

refused_value_keeps_the_files() {
    require_flock
    stub_qrencode_fail
    add_alice
    plant alice.png
    plant alice.vpnuri
    run --separate-stderr mgmt modify alice DNS not-an-address
    [ "$status" -ne 0 ]
    # The refusal is the value check itself, not some earlier failure.
    [[ "$stderr" == *"not-an-address"* ]]
    grep -qxF 'OLD' "$A/alice.png"
    grep -qxF 'OLD' "$A/alice.vpnuri"
}

refusal_after_the_lock_keeps_the_files() {
    require_flock
    stub_qrencode_fail
    add_alice
    sed -i '/^DNS[[:space:]]*=/d' "$A/alice.conf"
    plant alice.png
    plant alice.vpnuri
    run --separate-stderr mgmt modify alice DNS 8.8.4.4
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"DNS"* ]]
    grep -qxF 'OLD' "$A/alice.png"
    grep -qxF 'OLD' "$A/alice.vpnuri"
}

unsafe_client_config_is_not_reissued() {
    require_flock
    require_jq
    stub_qrencode_fail
    add_alice
    sed -i "/^\[Interface\]/a I3 = $REPRO" "$A/alice.conf"
    plant alice.png
    local before
    before=$(sha256sum "$A/alice.conf" | cut -d' ' -f1)
    run --separate-stderr mgmt modify alice DNS 8.8.4.4 --json
    [ "$status" -eq 1 ]
    [ "$(sha256sum "$A/alice.conf" | cut -d' ' -f1)" = "$before" ]
    grep -qxF 'OLD' "$A/alice.png"
    [[ "$stderr" == *"I3"* ]]
    one_json_line
    printf '%s' "$output" | jq -e '.ok == false and .rc == 1 and (.error | contains("I1-I5"))' >/dev/null
}

unremovable_file_refuses_before_the_edit() {
    require_flock
    require_jq
    stub_qrencode_fail
    add_alice
    plant alice.png
    local dns_before
    dns_before=$(grep '^DNS' "$A/alice.conf")
    # rm refuses only the PNG; every other removal modify makes goes through.
    printf '#!/bin/bash\nfor a in "$@"; do case "$a" in *alice.png) exit 1 ;; esac; done\nexec %q "$@"\n' \
        "$REAL_RM" > "$MGMT_DIR/bin/rm"
    chmod +x "$MGMT_DIR/bin/rm"
    run --separate-stderr mgmt modify alice DNS 8.8.4.4 --json
    [ "$status" -eq 1 ]
    [ "$(grep '^DNS' "$A/alice.conf")" = "$dns_before" ]
    grep -qxF 'OLD' "$A/alice.png"
    [ -z "$(find "$A" -maxdepth 1 -name 'alice.conf.bak-*')" ]
    one_json_line
    printf '%s' "$output" | jq -e '.command == "modify" and .ok == false and .rc == 1 and (.error | contains("alice.png"))' >/dev/null
    [[ "$stderr" == *"alice.png"* ]]
}

rm_that_lies_is_caught() {
    require_flock
    stub_qrencode_fail
    add_alice
    plant alice.png
    local dns_before
    dns_before=$(grep '^DNS' "$A/alice.conf")
    # rm reports success for the PNG but leaves it in place.
    printf '#!/bin/bash\nfor a in "$@"; do case "$a" in *alice.png) exit 0 ;; esac; done\nexec %q "$@"\n' \
        "$REAL_RM" > "$MGMT_DIR/bin/rm"
    chmod +x "$MGMT_DIR/bin/rm"
    run --separate-stderr mgmt modify alice DNS 8.8.4.4
    [ "$status" -eq 1 ]
    [ "$(grep '^DNS' "$A/alice.conf")" = "$dns_before" ]
    grep -qxF 'OLD' "$A/alice.png"
}

partial_removal_points_to_regen() {
    require_flock
    require_jq
    stub_qrencode_fail
    add_alice
    plant alice.png
    # add may already have built a real alice.vpnuri; a directory takes its place.
    command rm -f "$A/alice.vpnuri"
    mkdir "$A/alice.vpnuri"
    local dns_before
    dns_before=$(grep '^DNS' "$A/alice.conf")
    run --separate-stderr mgmt modify alice DNS 8.8.4.4 --json
    [ "$status" -eq 1 ]
    [ "$(grep '^DNS' "$A/alice.conf")" = "$dns_before" ]
    # The PNG before it is already gone, and the operator is told how to get it back.
    [ ! -e "$A/alice.png" ]
    [ -d "$A/alice.vpnuri" ]
    [[ "$stderr" == *"regen"* ]]
    printf '%s' "$output" | jq -e '.ok == false and (.error | contains("alice.vpnuri"))' >/dev/null
}

rollback_after_a_failed_edit_points_to_regen() {
    require_flock
    require_jq
    stub_qrencode_fail
    add_alice
    plant alice.png
    plant alice.vpnuri
    command cp "$A/alice.conf" "$MGMT_DIR/alice.conf.before"
    # sed fails only for the in-place edit of alice.conf.
    printf '#!/bin/bash\ni=0; c=0\nfor a in "$@"; do case "$a" in -i) i=1 ;; *alice.conf) c=1 ;; esac; done\n[ "$i$c" = 11 ] && exit 1\nexec %q "$@"\n' \
        "$REAL_SED" > "$MGMT_DIR/bin/sed"
    chmod +x "$MGMT_DIR/bin/sed"
    run --separate-stderr mgmt modify alice DNS 8.8.4.4 --json
    [ "$status" -eq 1 ]
    cmp -s "$A/alice.conf" "$MGMT_DIR/alice.conf.before"
    [ -z "$(find "$A" -maxdepth 1 -name 'alice.conf.bak-*')" ]
    [ ! -e "$A/alice.png" ]
    [ ! -e "$A/alice.vpnuri" ]
    [[ "$stderr" == *"regen"* ]]
    printf '%s' "$output" | jq -e '.ok == false and (.error | contains("regen"))' >/dev/null
}

# ------------------------------------------------------------------ RU

@test "modify RU: a refused vpn:// rebuild leaves no vpn:// files and reports vpnuri null" {
    refused_vpnuri_leaves_no_vpnuri
}

@test "modify RU: a refused vpn:// rebuild keeps the freshly built QR" {
    refused_vpnuri_keeps_fresh_qr
}

@test "modify RU: a failed QR rebuild leaves no PNG and reports qr null" {
    failed_qr_leaves_no_png
}

@test "modify RU: a failed vpn:// QR leaves the fresh URI and reports it" {
    failed_vpnuri_qr_leaves_fresh_uri
}

@test "modify RU: a successful rebuild carries the new value in every file" {
    successful_rebuild_carries_the_new_value
}

@test "modify RU: the old files are gone before the rebuild starts" {
    old_files_are_gone_before_the_rebuild
}

@test "modify RU: a value refused by its own check keeps the files" {
    refused_value_keeps_the_files
}

@test "modify RU: a refusal after the lock keeps the files" {
    refusal_after_the_lock_keeps_the_files
}

@test "modify RU: a client config with an unsafe I1-I5 is not reissued" {
    unsafe_client_config_is_not_reissued
}

@test "modify RU: a file that cannot be removed refuses with the .conf untouched" {
    unremovable_file_refuses_before_the_edit
}

@test "modify RU: an rm that reports success but keeps the file is caught" {
    rm_that_lies_is_caught
}

@test "modify RU: a partial removal points the operator to regen" {
    partial_removal_points_to_regen
}

@test "modify RU: a failed edit rolls back and points to regen" {
    rollback_after_a_failed_edit_points_to_regen
}

# ------------------------------------------------------------------ EN

@test "modify EN: a refused vpn:// rebuild leaves no vpn:// files and reports vpnuri null" {
    use_en
    refused_vpnuri_leaves_no_vpnuri
}

@test "modify EN: a refused vpn:// rebuild keeps the freshly built QR" {
    use_en
    refused_vpnuri_keeps_fresh_qr
}

@test "modify EN: a failed QR rebuild leaves no PNG and reports qr null" {
    use_en
    failed_qr_leaves_no_png
}

@test "modify EN: a failed vpn:// QR leaves the fresh URI and reports it" {
    use_en
    failed_vpnuri_qr_leaves_fresh_uri
}

@test "modify EN: a successful rebuild carries the new value in every file" {
    use_en
    successful_rebuild_carries_the_new_value
}

@test "modify EN: the old files are gone before the rebuild starts" {
    use_en
    old_files_are_gone_before_the_rebuild
}

@test "modify EN: a value refused by its own check keeps the files" {
    use_en
    refused_value_keeps_the_files
}

@test "modify EN: a refusal after the lock keeps the files" {
    use_en
    refusal_after_the_lock_keeps_the_files
}

@test "modify EN: a client config with an unsafe I1-I5 is not reissued" {
    use_en
    unsafe_client_config_is_not_reissued
}

@test "modify EN: a file that cannot be removed refuses with the .conf untouched" {
    use_en
    unremovable_file_refuses_before_the_edit
}

@test "modify EN: an rm that reports success but keeps the file is caught" {
    use_en
    rm_that_lies_is_caught
}

@test "modify EN: a partial removal points the operator to regen" {
    use_en
    partial_removal_points_to_regen
}

@test "modify EN: a failed edit rolls back and points to regen" {
    use_en
    rollback_after_a_failed_edit_points_to_regen
}
