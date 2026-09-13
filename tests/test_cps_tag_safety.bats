#!/usr/bin/env bats
# awg_cps_check_safe and the places that refuse on it.
#
# Upstream amneziawg-linux-kernel-module#233: the kernel parses the length of
# <r>, <rc> and <rd> with kstrtoint and never looks at the value. A negative
# length next to a <b> tag keeps the summed size small and positive, so the
# buffer is small while the copy of the literal tag is not - a heap overflow.
# amneziawg-go reads the same length with strconv.Atoi, and a negative one
# panics on the slice when the packet is built. Both accept such a config
# without an error, and regen would hand it to every client.
#
# 🔴 The refusal is deliberately narrow. Only what the code of BOTH
# implementations shows to be dangerous is refused: a negative length, a
# length that is not a decimal or has more than nine significant digits, and a
# total too large for UDP. An unknown tag or plain junk is left to the
# implementations, which refuse those loudly on their own. Refusing them here could break a userspace server that works
# today, and a check that breaks working servers gets switched off.
#
# 🔴 Refusals are asserted by their REASON, not only by the exit status. A test
# that checks the status alone passes when the function merely crashes: `10#-1`
# breaks the arithmetic, the function exits non-zero for the wrong reason, and a
# mutant that lets a negative length through goes unnoticed.

# shellcheck disable=SC2154  # $stderr is set by bats `run --separate-stderr`
load test_helper

bats_require_minimum_version 1.5.0

REPRO='<b 0x0102><r -1>'
DNS_RECIPE='<r 2><b 0x858000010001000000000669636c6f756403636f6d0000010001c00c000100010000105a00044d583737>'

COMMON="${BATS_TEST_DIRNAME}/../awg_common.sh"
COMMON_EN="${BATS_TEST_DIRNAME}/../awg_common_en.sh"

check() {  # check <lib> <value> : bounded, so a hang shows up as status 124
    timeout 10 bash -c 'source "$1" >/dev/null 2>&1 || true; awg_cps_check_safe "$2"' \
        _ "$1" "$2"
}

# ------------------------------------------------------------------ the check

@test "cps safety: the upstream reproducer is refused and the tag is named" {
    run check "$COMMON" "$REPRO"
    [ "$status" -eq 1 ]
    [[ "$output" == *"<r -1>"* ]]
}

@test "cps safety: a negative length is refused for rc and rd as well" {
    run check "$COMMON" '<rc -5>'
    [ "$status" -eq 1 ]
    [[ "$output" == *"<rc -5>"* ]]
    run check "$COMMON" '<rd -5>'
    [ "$status" -eq 1 ]
    [[ "$output" == *"<rd -5>"* ]]
}

@test "cps safety: the documented DNS recipe is safe" {
    run check "$COMMON" "$DNS_RECIPE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "cps safety: a leading plus is accepted, both implementations parse it" {
    run check "$COMMON" '<r +5>'
    [ "$status" -eq 0 ]
}

@test "cps safety: leading zeros do not count against the digit limit" {
    run check "$COMMON" '<r 0000000001>'
    [ "$status" -eq 0 ]
}

# 🔴 The value is chosen so that ONLY the digit limit can refuse it. 1234567890
# is also caught by the sum check, so it proved nothing about the limit. 2^64+1
# wraps in bash arithmetic to 1: without the limit it would pass as one byte.
@test "cps safety: a length that wraps bash arithmetic is refused by the digit limit" {
    run check "$COMMON" '<r 18446744073709551617>'
    [ "$status" -eq 1 ]
    [[ "$output" == *"18446744073709551617"* ]]
    run check "$COMMON_EN" '<r 18446744073709551617>'
    [ "$status" -eq 1 ]
    [[ "$output" == *"18446744073709551617"* ]]
}

# Neither half exceeds the limit alone, so only a real sum refuses this.
@test "cps safety: two halves that together exceed 65535 are refused" {
    run check "$COMMON" '<r 32768><r 32768>'
    [ "$status" -eq 1 ]
    [[ "$output" == *"65536"* ]]
    run check "$COMMON" '<r +32768><r +32768>'
    [ "$status" -eq 1 ]
    [[ "$output" == *"65536"* ]]
    run check "$COMMON" '<r 32767><r 32768>'
    [ "$status" -eq 0 ]
}

@test "cps safety: a literal counts toward the total" {
    run check "$COMMON" '<r 65535>'
    [ "$status" -eq 0 ]
    run check "$COMMON" '<b 0xaa><r 65535>'
    [ "$status" -eq 1 ]
    [[ "$output" == *"65536"* ]]
}

@test "cps safety: timestamp and counter tags count toward the total" {
    run check "$COMMON" '<r 65532><t>'
    [ "$status" -eq 1 ]
    [[ "$output" == *"65536"* ]]
    run check "$COMMON" '<r 65531><c>'
    [ "$status" -eq 0 ]
}

# Zero is harmless in both implementations however it is spelled, and refusing
# a working config over it is exactly what the narrow refusal must not do. A
# bare sign is not a number at all.
@test "cps safety: zero in any spelling is safe, a bare sign is not" {
    local v
    for v in '<r 0>' '<r +0>' '<r 00>' '<r -0>' '<r -00>'; do
        run check "$COMMON" "$v"
        [ "$status" -eq 0 ] || { echo "refused: $v -> $output"; false; }
    done
    run check "$COMMON" '<r +>'
    [ "$status" -eq 1 ]
    run check "$COMMON" '<r ->'
    [ "$status" -eq 1 ]
}

# The negative-length message claims memory corruption. That claim belongs to a
# real negative number, not to a minus in front of junk.
@test "cps safety: a minus before junk is a syntax refusal, not a negative length" {
    run check "$COMMON" '<r -abc>'
    [ "$status" -eq 1 ]
    [[ "$output" == *"-abc"* ]]
    [[ "$output" != *"отрицательная"* ]]
}

# 🔴 A nested [[ =~ ]] clobbers BASH_REMATCH. If the loop advances by the
# clobbered match, a string it cannot consume never shrinks and the check spins
# forever - inside restore, after the files were already replaced.
@test "cps safety: a malformed literal does not hang the check" {
    run check "$COMMON" '<b 0xGG><r -1>'
    [ "$status" -ne 124 ]
    [ "$status" -eq 1 ]
    [[ "$output" == *"<r -1>"* ]]
}

@test "cps safety: whitespace inside a length does not hang the check" {
    run check "$COMMON" '<r 1 2>'
    [ "$status" -ne 124 ]
    [ "$status" -eq 0 ]
}

@test "cps safety: tags the check does not own are left to the implementations" {
    run check "$COMMON" '<d>'
    [ "$status" -eq 0 ]
    run check "$COMMON" '<t>'
    [ "$status" -eq 0 ]
    run check "$COMMON" 'garbagewithnotags'
    [ "$status" -eq 0 ]
}

@test "cps safety: an empty value is safe" {
    run check "$COMMON" ''
    [ "$status" -eq 0 ]
}

@test "cps safety: the EN library refuses the same inputs for the same reasons" {
    run check "$COMMON_EN" "$REPRO"
    [ "$status" -eq 1 ]
    [[ "$output" == *"<r -1>"* ]]
    run check "$COMMON_EN" '<r 32768><r 32768>'
    [ "$status" -eq 1 ]
    [[ "$output" == *"65536"* ]]
    run check "$COMMON_EN" '<b 0xGG><r -1>'
    [ "$status" -eq 1 ]
    [[ "$output" == *"<r -1>"* ]]
    run check "$COMMON_EN" "$DNS_RECIPE"
    [ "$status" -eq 0 ]
    run check "$COMMON_EN" '<r 0000000001>'
    [ "$status" -eq 0 ]
    run check "$COMMON_EN" '<rc -5>'
    [ "$status" -eq 1 ]
    [[ "$output" == *"<rc -5>"* ]]
    run check "$COMMON_EN" '<rd -5>'
    [ "$status" -eq 1 ]
    [[ "$output" == *"<rd -5>"* ]]
}

# ------------------------------------------------------------ validate_awg_config
# restore runs the validator before starting the service and rolls back on a
# refusal, so this is what keeps a dangerous backup off a live server.

@test "validate: a server config carrying the reproducer in I1 fails" {
    create_server_config
    printf 'I1 = %s\n' "$REPRO" >> "$SERVER_CONF_FILE"
    run validate_awg_config
    [ "$status" -eq 1 ]
}

@test "validate: the check covers I5, not only I1" {
    create_server_config
    printf 'I1 = %s\nI5 = %s\n' "$DNS_RECIPE" "$REPRO" >> "$SERVER_CONF_FILE"
    run validate_awg_config
    [ "$status" -eq 1 ]
}

@test "validate: a safe I1 still passes" {
    create_server_config
    printf 'I1 = %s\n' "$DNS_RECIPE" >> "$SERVER_CONF_FILE"
    run validate_awg_config
    [ "$status" -eq 0 ]
}

# The validator must see every value the tools will apply. amneziawg-tools match
# section headers and the I1-I5 keys without regard to case, so a peer-section
# line or an empty duplicate must not hide a dangerous interface value.
@test "validate: an I1 line in a peer section does not mask the interface value" {
    create_server_config
    printf 'I1 = %s\n\n[Peer]\nPublicKey = X\nI1 = <r 1>\n' "$REPRO" >> "$SERVER_CONF_FILE"
    run validate_awg_config
    [ "$status" -eq 1 ]
}

@test "validate: an empty duplicate does not mask the interface value" {
    create_server_config
    printf 'I1 = %s\nI1=\n' "$REPRO" >> "$SERVER_CONF_FILE"
    run validate_awg_config
    [ "$status" -eq 1 ]
}

# A config whose [Interface] the loader cannot parse must not pass as checked.
# The older sed-based checks read the whole file and can still find S4 in a peer
# section, so without this the I1 check would simply be skipped.
@test "validate: an interface the loader cannot parse is not waved through" {
    create_server_config
    sed -i '/^S4/d' "$SERVER_CONF_FILE"
    printf 'I1 = %s\n\n[Peer]\nPublicKey = X\nS4 = 16\n' "$REPRO" >> "$SERVER_CONF_FILE"
    run validate_awg_config
    [ "$status" -eq 1 ]
}

@test "validate: a readonly variable in the caller does not hide the file value" {
    create_server_config
    printf 'I1 = %s\n' "$REPRO" >> "$SERVER_CONF_FILE"
    readonly AWG_I1='<r 1>'
    run validate_awg_config
    [ "$status" -eq 1 ]
}

@test "validate: the EN library does not wave through an interface it cannot parse" {
    create_server_config
    sed -i '/^S4/d' "$SERVER_CONF_FILE"
    printf 'I1 = %s\n\n[Peer]\nPublicKey = X\nS4 = 16\n' "$REPRO" >> "$SERVER_CONF_FILE"
    run bash -c 'unset -f log log_warn log_error log_debug; source "$1" >/dev/null 2>&1 || true; validate_awg_config' _ "$COMMON_EN"
    [ "$status" -eq 1 ]
    [[ "$output" == *"I1"* && "$output" == *"<r -1>"* ]]
}

@test "validate: the EN library fails the same config" {
    create_server_config
    printf 'I1 = %s\n' "$REPRO" >> "$SERVER_CONF_FILE"
    run bash -c 'unset -f log log_warn log_error log_debug; source "$1" >/dev/null 2>&1 || true; validate_awg_config' _ "$COMMON_EN"
    [ "$status" -eq 1 ]
    [[ "$output" == *"I1"* && "$output" == *"<r -1>"* ]]
}

# ------------------------------------------------------------------ load_awg_params
# Every path that renders a client profile from the server parameters goes
# through load_awg_params and fails
# on its refusal; modify removes the vpn:// files it can no longer rebuild
# (tests/test_modify_stale_artifacts.bats). That is what stops the value from
# reaching clients.

@test "load_awg_params: a live config carrying the reproducer is refused" {
    create_server_config
    printf 'I1 = %s\n' "$REPRO" >> "$SERVER_CONF_FILE"
    run load_awg_params
    [ "$status" -eq 1 ]
}

@test "load_awg_params: a safe I1 loads exactly as before" {
    create_server_config
    printf 'I1 = %s\n' "$DNS_RECIPE" >> "$SERVER_CONF_FILE"
    load_awg_params
    [ "$AWG_I1" = "$DNS_RECIPE" ]
}

# The loader drops a trailing comment the way amneziawg-tools do. Without that a
# `# ...` tail would reach client profiles and vpn:// while the check, which
# strips the comment, never sees it.
@test "load_awg_params: a trailing comment is dropped from the values, as the tools read them" {
    create_server_config
    sed -i 's/^H1 = .*/& # note/' "$SERVER_CONF_FILE"
    printf 'I1 = %s # %s\n' "<b 0x0102><r 10>" "$REPRO" >> "$SERVER_CONF_FILE"
    load_awg_params
    [ "$AWG_I1" = "<b 0x0102><r 10>" ]
    [[ "$AWG_H1" != *"#"* ]]
    [ -n "$AWG_H1" ]
}

@test "load_awg_params: the EN library drops a trailing comment too" {
    create_server_config
    printf 'I1 = %s # %s\n' "<b 0x0102><r 10>" "$REPRO" >> "$SERVER_CONF_FILE"
    run bash -c 'unset -f log log_warn log_error log_debug; source "$1" >/dev/null 2>&1 || true; load_awg_params >/dev/null 2>&1 || exit 9; printf "%s" "$AWG_I1"' _ "$COMMON_EN"
    [ "$status" -eq 0 ]
    [ "$output" = "<b 0x0102><r 10>" ]
}

# The deferral belongs to render_server_config alone and is tied to the caller's
# name. An earlier draft of this change deferred through a variable with this
# name; the test keeps a variable-based deferral from coming back.
@test "load_awg_params: a variable named like the deferral does not switch the check off" {
    create_server_config
    printf 'I1 = %s\n' "$REPRO" >> "$SERVER_CONF_FILE"
    export _awg_cps_defer=1
    run load_awg_params
    [ "$status" -eq 1 ]
}

@test "load_awg_params: the EN library refuses the same config and says why" {
    create_server_config
    printf 'I1 = %s\n' "$REPRO" >> "$SERVER_CONF_FILE"
    run bash -c 'unset -f log log_warn log_error log_debug; source "$1" >/dev/null 2>&1 || true; load_awg_params' _ "$COMMON_EN"
    [ "$status" -eq 1 ]
    [[ "$output" == *"I1"* && "$output" == *"<r -1>"* ]]
}

# --no-cps is the documented way to get rid of I1 on a reinstall. It must still
# work when the I1 being removed is the dangerous one: render_server_config
# drops I1 after loading, so the check has to look at what is left.
@test "render_server_config: --no-cps removes a dangerous I1 instead of refusing" {
    create_server_config
    printf 'I1 = %s\n' "$REPRO" >> "$SERVER_CONF_FILE"
    create_init_config
    printf 'export NO_CPS=1\n' >> "$CONFIG_FILE"
    printf 'TESTPRIVKEY\n' > "$AWG_DIR/server_private.key"
    get_main_nic() { echo eth0; }
    run render_server_config
    [ "$status" -eq 0 ]
    ! grep -qE '^[[:space:]]*I1[[:space:]]*=' "$SERVER_CONF_FILE"
}

# Without --no-cps the deferred check must still run inside render_server_config,
# or deferring it would simply switch it off for the server config.
@test "render_server_config: without --no-cps a dangerous I1 is refused" {
    create_server_config
    printf 'I1 = %s\n' "$REPRO" >> "$SERVER_CONF_FILE"
    create_init_config
    printf 'TESTPRIVKEY\n' > "$AWG_DIR/server_private.key"
    get_main_nic() { echo eth0; }
    log_error() { printf '%s\n' "$*" >> "$AWG_DIR/.errors"; }
    run render_server_config
    [ "$status" -eq 1 ]
    grep -qF "$REPRO" "$SERVER_CONF_FILE"
    grep -qF '<r -1>' "$AWG_DIR/.errors"
}

# --no-cps clears I1 only. A dangerous I5 survives it and must still be refused.
@test "render_server_config: --no-cps does not wave through a dangerous I5" {
    create_server_config
    printf 'I1 = %s\nI5 = %s\n' "$DNS_RECIPE" "$REPRO" >> "$SERVER_CONF_FILE"
    create_init_config
    printf 'export NO_CPS=1\n' >> "$CONFIG_FILE"
    printf 'TESTPRIVKEY\n' > "$AWG_DIR/server_private.key"
    get_main_nic() { echo eth0; }
    log_error() { printf '%s\n' "$*" >> "$AWG_DIR/.errors"; }
    run render_server_config
    [ "$status" -eq 1 ]
    grep -qF 'I5' "$AWG_DIR/.errors"
}

# ...and the deferral must stay inside render_server_config. A client profile
# does not honour NO_CPS, so regen on the same server must still refuse.
@test "load_awg_params: NO_CPS does not let a dangerous I1 through to clients" {
    create_server_config
    printf 'I1 = %s\n' "$REPRO" >> "$SERVER_CONF_FILE"
    create_init_config
    printf 'export NO_CPS=1\n' >> "$CONFIG_FILE"
    run load_awg_params
    [ "$status" -eq 1 ]
}

# ------------------------------------------------------------ what must still pass
# The refusal is only worth having if everything the installer itself produces
# still passes it. A tightened check (for example the vendor's documented cap
# applied to <rc>) would otherwise leave every refusal test green while every
# fresh install dies in render_server_config.

gen_i1() {  # gen_i1 <installer> <count>
    bash -c '
        eval "$(sed -n "/^rand_range()/,/^}/p" "$1")"
        eval "$(sed -n "/^generate_cps_i1()/,/^}/p" "$1")"
        for _ in $(seq 1 "$2"); do generate_cps_i1; done
    ' _ "$1" "$2"
}

@test "cps safety: every I1 the RU and EN installers generate passes both libraries" {
    local inst v n=0
    for inst in install_amneziawg.sh install_amneziawg_en.sh; do
        while IFS= read -r v; do
            [ -n "$v" ] || continue
            n=$((n + 1))
            run check "$COMMON" "$v"
            [ "$status" -eq 0 ] || { echo "RU refused output of $inst: $v -> $output"; false; }
            run check "$COMMON_EN" "$v"
            [ "$status" -eq 0 ] || { echo "EN refused output of $inst: $v -> $output"; false; }
        done < <(gen_i1 "$BATS_TEST_DIRNAME/../$inst" 40)
    done
    # Guards against a vacuous pass: an extraction that yields nothing would
    # otherwise leave the loop above with nothing to refuse.
    [ "$n" -eq 80 ]
}

@test "cps safety: positive lengths of every tag the check owns are accepted" {
    local v
    for v in '<rc 62>' '<rd 10>' '<r 128>' '<rc 1>' '<rd 1000>'; do
        run check "$COMMON" "$v"
        [ "$status" -eq 0 ] || { echo "RU refused: $v -> $output"; false; }
        run check "$COMMON_EN" "$v"
        [ "$status" -eq 0 ] || { echo "EN refused: $v -> $output"; false; }
    done
}

# ------------------------------------------------------ render_server_config, EN
# The deferral by caller name and the check after --no-cps exist in both
# libraries. The RU pair is covered above; without these the EN pair could go
# missing with every test green.

render_en() {
    bash -c 'unset -f log log_warn log_error log_debug; source "$1" >/dev/null 2>&1 || true; get_main_nic() { echo eth0; }; render_server_config' _ "$COMMON_EN"
}

@test "render_server_config EN: without --no-cps a dangerous I1 is refused and named" {
    create_server_config
    printf 'I1 = %s\n' "$REPRO" >> "$SERVER_CONF_FILE"
    create_init_config
    printf 'TESTPRIVKEY\n' > "$AWG_DIR/server_private.key"
    run render_en
    [ "$status" -eq 1 ]
    [[ "$output" == *"<r -1>"* ]]
    grep -qF "$REPRO" "$SERVER_CONF_FILE"
}

@test "render_server_config EN: --no-cps removes a dangerous I1 instead of refusing" {
    create_server_config
    printf 'I1 = %s\n' "$REPRO" >> "$SERVER_CONF_FILE"
    create_init_config
    printf 'export NO_CPS=1\n' >> "$CONFIG_FILE"
    printf 'TESTPRIVKEY\n' > "$AWG_DIR/server_private.key"
    run render_en
    [ "$status" -eq 0 ]
    run grep -qE '^[[:space:]]*I1[[:space:]]*=' "$SERVER_CONF_FILE"
    [ "$status" -eq 1 ]
}

# ------------------------------------------------------- paths that must not block
# Client removal and the expiry cron must keep working on a server that already
# carries a dangerous value: blocking them would leave expired clients connected,
# and nobody reads the cron output. They do not call load_awg_params today; these
# tests are what keeps it that way.

@test "expiry: an expired client is still removed when the server carries a dangerous I2" {
    require_flock
    create_server_config
    # Into [Interface], right after H4: appended at the end it would land in a
    # peer section, where the loader never looks, and prove nothing.
    sed -i "/^H4 = /a I2 = $REPRO" "$SERVER_CONF_FILE"
    grep -qxF "I2 = $REPRO" "$SERVER_CONF_FILE"
    printf '\n[Peer]\n#_Name = bob\nPublicKey = BOBKEY\nAllowedIPs = 10.9.9.2/32\n' >> "$SERVER_CONF_FILE"
    mkdir -p "$EXPIRY_DIR"
    printf '1' > "$EXPIRY_DIR/bob"
    export AWG_SKIP_APPLY=1
    run check_expired_clients
    [ "$status" -eq 0 ]
    run grep -qxF '#_Name = bob' "$SERVER_CONF_FILE"
    [ "$status" -eq 1 ]
    [ ! -f "$EXPIRY_DIR/bob" ]
}

# --------------------------------------------------------------- manage end to end
# The real manage script in a mock environment (stubbed awg, AWG_SKIP_APPLY=1),
# in the style of test_add_allowed_ips.bats. The unit tests above prove that
# load_awg_params refuses; these prove that the refusal happens BEFORE anything is
# written, which no unit test can see.

MANAGE="${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"

setup_manage_env() {
    MGMT_DIR=$(mktemp -d)
    mkdir -p "$MGMT_DIR/bin" "$MGMT_DIR/awg/keys"
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
    cp "$BATS_TEST_DIRNAME/../awg_common.sh" "$MGMT_DIR/awg/awg_common.sh"
    cat > "$MGMT_DIR/awg/awgsetup_cfg.init" << 'CONF'
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
CONF
    cat > "$MGMT_DIR/awg/awg0.conf" << 'CONF'
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

# Overrides the helper's teardown so the manage environment is removed even when
# an assertion above fails.
teardown() {
    rm -rf "$TEST_DIR" "${MGMT_DIR:-}"
    unset AWG_SKIP_APPLY
}

mgmt() {  # mgmt <manage args...>
    bash "$MANAGE" "$@" --yes --conf-dir="$MGMT_DIR/awg" --server-conf="$MGMT_DIR/awg/awg0.conf"
}

poison_i3() {
    sed -i "/^H4 = /a I3 = $REPRO" "$MGMT_DIR/awg/awg0.conf"
    grep -qxF "I3 = $REPRO" "$MGMT_DIR/awg/awg0.conf"
}

@test "manage e2e: add issues nothing when the server carries a dangerous I3" {
    require_flock
    setup_manage_env
    poison_i3
    run --separate-stderr mgmt add bob --json
    [ "$status" -ne 0 ]
    [[ "$stderr$output" == *"I3"* ]]
    [ ! -f "$MGMT_DIR/awg/bob.conf" ]
    run grep -qxF '#_Name = bob' "$MGMT_DIR/awg/awg0.conf"
    [ "$status" -eq 1 ]
}

@test "manage e2e: regen leaves an existing profile untouched when the server carries a dangerous I3" {
    require_flock
    setup_manage_env
    run --separate-stderr mgmt add alice --json
    [ "$status" -eq 0 ]
    [ -f "$MGMT_DIR/awg/alice.conf" ]
    local before
    before=$(sha256sum "$MGMT_DIR/awg/alice.conf" | cut -d' ' -f1)
    poison_i3
    run --separate-stderr mgmt regen alice
    [ "$status" -ne 0 ]
    [[ "$stderr$output" == *"I3"* ]]
    [ "$(sha256sum "$MGMT_DIR/awg/alice.conf" | cut -d' ' -f1)" = "$before" ]
}

@test "manage e2e: remove still works when the server carries a dangerous I3" {
    require_flock
    setup_manage_env
    run --separate-stderr mgmt add carol --json
    [ "$status" -eq 0 ]
    poison_i3
    run --separate-stderr mgmt remove carol
    [ "$status" -eq 0 ]
    run grep -qxF '#_Name = carol' "$MGMT_DIR/awg/awg0.conf"
    [ "$status" -eq 1 ]
}

# ------------------------------------------------ as the implementations parse it
# The check has to read a value the way the code that applies it does. Every
# difference between the two is a way past it.

# The kernel splits tags with strsep, and strsep on a missing '>' returns the rest
# of the string: an unterminated LAST tag is parsed like a closed one.
@test "cps safety: an unterminated last tag is still checked, as the kernel parses it" {
    local lit
    lit=$(printf '41%.0s' $(seq 1 200))
    run check "$COMMON" "<b 0x${lit}><r -100"
    [ "$status" -eq 1 ]
    [[ "$output" == *"<r -100>"* ]]
    run check "$COMMON" '<b 0x41><r 999999'
    [ "$status" -eq 1 ]
    [[ "$output" == *"1000000"* ]]
    run check "$COMMON_EN" "<b 0x${lit}><r -100"
    [ "$status" -eq 1 ]
    [[ "$output" == *"<r -100>"* ]]
}

# Both implementations compare the tag name with its case (strcmp in the kernel,
# a map lookup in amneziawg-go): <R -1> is an unknown tag they reject
# themselves, and the negative-length message would be false for it.
@test "cps safety: a tag name in the wrong case is left to the implementations" {
    run check "$COMMON" '<R -1>'
    [ "$status" -eq 0 ]
    run check "$COMMON_EN" '<RC -5>'
    [ "$status" -eq 0 ]
}

# amneziawg-tools cut a line at '#'. A comment after a working value is not part
# of what gets applied, so it must neither refuse the value nor hide one.
@test "cps safety: a comment after the value is ignored the way the tools ignore it" {
    run check "$COMMON" '<r 10> # was <r -100>'
    [ "$status" -eq 0 ]
    run check "$COMMON" '<r -100> # keep'
    [ "$status" -eq 1 ]
    [[ "$output" == *"<r -100>"* ]]
    run check "$COMMON_EN" '<r 10> # was <r -100>'
    [ "$status" -eq 0 ]
}

# amneziawg-tools match the I1-I5 keys with strncasecmp: a lowercase key is
# applied like the uppercase one, while the loader does not even see it.
@test "validate: a lowercase i1 key is checked, the tools apply it" {
    create_server_config
    sed -i "/^H4 = /a i1 = $REPRO" "$SERVER_CONF_FILE"
    grep -qxF "i1 = $REPRO" "$SERVER_CONF_FILE"
    run validate_awg_config
    [ "$status" -eq 1 ]
}

@test "validate: a later lowercase key does not hide behind a safe uppercase one" {
    create_server_config
    sed -i "/^H4 = /a i1 = $REPRO" "$SERVER_CONF_FILE"
    sed -i "/^H4 = /a I1 = <r 10>" "$SERVER_CONF_FILE"
    grep -qxF "I1 = <r 10>" "$SERVER_CONF_FILE"
    run validate_awg_config
    [ "$status" -eq 1 ]
}

# Section headers are compared with strcasecmp after whitespace is stripped: a
# second [interface] after the peers switches the tools back to the device.
@test "validate: an I1 under a second, lowercase [interface] header is checked" {
    create_server_config
    printf '\n[Peer]\n#_Name = bob\nPublicKey = X\nAllowedIPs = 10.9.9.2/32\n\n[interface]\nI1 = %s\n' "$REPRO" >> "$SERVER_CONF_FILE"
    run validate_awg_config
    [ "$status" -eq 1 ]
}

@test "validate: the EN library checks a lowercase key and names it" {
    create_server_config
    sed -i "/^H4 = /a i1 = $REPRO" "$SERVER_CONF_FILE"
    run bash -c 'unset -f log log_warn log_error log_debug; source "$1" >/dev/null 2>&1 || true; validate_awg_config' _ "$COMMON_EN"
    [ "$status" -eq 1 ]
    [[ "$output" == *"i1"* && "$output" == *"<r -1>"* ]]
}

# On a first install there is no awg0.conf yet and the values come from the init
# file. Pointing the operator at a file that does not exist would send them to
# create one, and the loader would then take it as the source of truth.
@test "load_awg_params: on a first install the refusal names the init file" {
    create_init_config
    printf "export AWG_I2='%s'\n" "$REPRO" >> "$CONFIG_FILE"
    [ ! -f "$SERVER_CONF_FILE" ]
    log_error() { printf '%s\n' "$*" >> "$AWG_DIR/.errors"; }
    run load_awg_params
    [ "$status" -eq 1 ]
    grep -qF "I2" "$AWG_DIR/.errors"
    grep -qF "$CONFIG_FILE" "$AWG_DIR/.errors"
}
