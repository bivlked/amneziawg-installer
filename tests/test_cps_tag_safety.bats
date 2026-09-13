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
# implementations shows to be dangerous is refused: a length that is not an
# unsigned decimal, and a total large enough to overflow. An unknown tag or
# plain junk is left to the implementations, which refuse those loudly on
# their own. Refusing them here could break a userspace server that works
# today, and a check that breaks working servers gets switched off.
#
# 🔴 Refusals are asserted by their REASON, not only by the exit status. A
# first version of these tests checked the status alone, and a mutant that let
# a negative length through still passed: `10#-1` broke the arithmetic, the
# function exited non-zero for the wrong reason, and the test read that as a
# refusal.

load test_helper

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

# The validator must see the value the loader sees. The loader reads [Interface]
# only and skips an empty value, so an I1 line in a peer section or a bare
# `I1=` after the real one must not hide the interface value from the check.
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
    [[ "$output" == *"not checked"* ]]
}

@test "validate: the EN library fails the same config" {
    create_server_config
    printf 'I1 = %s\n' "$REPRO" >> "$SERVER_CONF_FILE"
    run bash -c 'unset -f log log_warn log_error log_debug; source "$1" >/dev/null 2>&1 || true; validate_awg_config' _ "$COMMON_EN"
    [ "$status" -eq 1 ]
    [[ "$output" == *"I1"* && "$output" == *"<r -1>"* ]]
}

# ------------------------------------------------------------------ load_awg_params
# Every path that writes a client profile goes through load_awg_params, and
# every caller already fails loudly on its refusal. That is what stops the
# value from reaching clients.

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

# The deferral belongs to render_server_config alone. Nothing a caller sets in
# its environment may switch the check off.
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
