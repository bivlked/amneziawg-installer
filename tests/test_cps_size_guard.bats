#!/usr/bin/env bats
# awg_cps_decoded_size and the diagnose-time warning built on it.
#
# The defect being guarded against is upstream
# amneziawg-linux-kernel-module#228: once the I1-I5 attributes fill most of the
# netlink dump buffer, the first peer no longer fits, `wg_get_device_dump`
# neither advances nor fails, and the same message repeats forever. The reader
# spins; on a router that is enough to take the box down.
#
# 🔴 Two properties matter and are tested separately, because passing one while
# failing the other still leaves the user with a hung command:
#   1. the size is DECODED, not the length of the string - `<r 1000>` is nine
#      characters and a thousand bytes;
#   2. the warning is computed from the FILE and printed BEFORE any `awg show`,
#      since that call is the one that hangs.

setup() {
    COMMON="${BATS_TEST_DIRNAME}/../awg_common.sh"
    COMMON_EN="${BATS_TEST_DIRNAME}/../awg_common_en.sh"
    MANAGE="${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"
    MANAGE_EN="${BATS_TEST_DIRNAME}/../manage_amneziawg_en.sh"
}

size() {  # size <lib> <args...>
    local lib="$1"; shift
    bash -c 'source "$1" >/dev/null 2>&1 || true; shift; awg_cps_decoded_size "$@"' \
        _ "$lib" "$@"
}

# ---------------------------------------------------------------- decoded size

@test "cps size: a random tag counts its byte count, not its text length" {
    run size "$COMMON" '<r 1000>'
    [ "$status" -eq 0 ]
    [ "$output" = "1000" ]
}

@test "cps size: a literal tag counts two hex characters per byte" {
    run size "$COMMON" '<b 0xdeadbeef>'
    [ "$output" = "4" ]
}

@test "cps size: letters and digits count like random bytes" {
    run size "$COMMON" '<rc 10><rd 5>'
    [ "$output" = "15" ]
}

@test "cps size: timestamp and counter tags are four bytes each" {
    run size "$COMMON" '<t><c>'
    [ "$output" = "8" ]
}

@test "cps size: a tag without a space is accepted too" {
    run size "$COMMON" '<r64>'
    [ "$output" = "64" ]
}

@test "cps size: the documented DNS-shaped recipe stays small" {
    # The recipe published in ADVANCED. If a future edit inflates it, this
    # reddens rather than the users' routers.
    run size "$COMMON" '<r 2><b 0x858000010001000000000669636c6f756403636f6d0000010001c00c000100010000105a00044d583737>'
    [ "$status" -eq 0 ]
    [ "$output" -lt 128 ]
}

@test "cps size: I1 through I5 add up" {
    run size "$COMMON" '<r 100>' '<r 200>' '' '<b 0xaabb>' '<t>'
    [ "$output" = "306" ]
}

@test "cps size: empty input is zero, not an error" {
    run size "$COMMON" ''
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "cps size: an unknown tag is ignored rather than guessed at" {
    # Under-counting is safe here: the outcome is a warning, not a refusal.
    run size "$COMMON" '<nosuchtag 99>'
    [ "$output" = "0" ]
}

@test "cps size: the generator's own upper bound stays far below the threshold" {
    # generate_cps_i1 emits <r 32..256>. The guard warns above 1024.
    run size "$COMMON" '<r 256>'
    [ "$status" -eq 0 ]
    [ "$output" -lt 1024 ]
}

@test "cps size: a leading-zero count is decimal, not octal" {
    # 🔴 `<r 08>` is octal to bash. Before `10#` was added the arithmetic failed
    # outright, the function returned an EMPTY string, and every threshold
    # comparison built on it silently stopped firing - the guard was off and
    # said nothing. Tested ALONE on purpose: paired with a large tag the sum
    # survives on the neighbour's value and the test passes while broken, which
    # is exactly what an earlier version of this file did.
    run size "$COMMON" '<r 08>'
    [ "$status" -eq 0 ]
    [ "$output" = "8" ]
}

@test "cps size: a leading-zero count in the EN library too" {
    run size "$COMMON_EN" '<r 09>'
    [ "$status" -eq 0 ]
    [ "$output" = "9" ]
}

@test "cps size: the EN library computes the same number" {
    run size "$COMMON_EN" '<r 100>' '<b 0xaabb>'
    [ "$output" = "102" ]
}

# ------------------------------------------------------- ordering in diagnose

@test "cps guard: the check reads the config file, not awg show" {
    # If it ever reads the size out of `awg show`, it inherits the hang it is
    # meant to warn about.
    run grep -n 'awg_cps_decoded_size' "$MANAGE"
    [ "$status" -eq 0 ]
    grep -A2 '_cps_vals+=' "$MANAGE" | grep -q 'SERVER_CONF_FILE'
}

@test "cps guard: the guard runs before the first awg show in diagnose" {
    # The whole point of the ordering, measured by line numbers inside
    # diagnose_server: the guard must come first, or it never prints for the
    # user who needs it.
    #
    # Two kinds of line are skipped, and both were learned the hard way here:
    # comments, because the guard's own comment explains that it precedes
    # `awg show` and matching that sentence made the check fail on its own
    # documentation; and _diag_line calls, because the failure messages quote
    # the command name too. A guard that trips over its own explanation is a
    # pattern this repository has now paid for twice.
    for f in "$MANAGE" "$MANAGE_EN"; do
        start=$(grep -n '^diagnose_server() {' "$f" | cut -d: -f1)
        guard=$(awk -v s="$start" 'NR>s && /_diag_cps_guard/ && !/^[[:space:]]*#/ {print NR; exit}' "$f")
        show=$(awk -v s="$start" 'NR>s && /awg show/ && !/^[[:space:]]*#/ && !/_diag_line/ {print NR; exit}' "$f")
        [ -n "$guard" ]
        [ -n "$show" ]
        [ "$guard" -lt "$show" ]
    done
}

@test "cps guard: awg show inside diagnose is bounded by a timeout" {
    # A bounded call fails loudly; an unbounded one hangs silently, and a hung
    # diagnostic is the worst outcome here - the user cannot even report it.
    for f in "$MANAGE" "$MANAGE_EN"; do
        start=$(grep -n '^diagnose_server() {' "$f" | cut -d: -f1)
        end=$(awk -v s="$start" 'NR>s && /^}/ {print NR; exit}' "$f")
        bare=$(awk -v s="$start" -v e="$end" \
            'NR>s && NR<e && /awg show/ && !/timeout [0-9]+ awg show/ && !/^[[:space:]]*#/ && !/_diag_line/' "$f" | wc -l)
        [ "$bare" -eq 0 ]
    done
}

@test "cps guard: the threshold is stated once per language and matches" {
    ru=$(grep -c '_cps_total" -gt 1024' "$MANAGE")
    en=$(grep -c '_cps_total" -gt 1024' "$MANAGE_EN")
    [ "$ru" -eq 1 ]
    [ "$en" -eq 1 ]
}

# ------------------------------------------------------ behaviour, not grep
#
# The checks above read the source. These run it. The difference matters: a
# call that stays in place while its result stops mattering, a threshold line
# turned into dead code, or a `timeout` present in the text while its exit code
# is discarded - all of that passes a source scan and fails a user.
#
# The guard is extracted by awk range and eval'd, the way this suite already
# handles diagnose helpers. Sourcing the whole script is not an option: it runs
# main and prints the usage text.

# guard_out <manage script> <lib> <I1 value>
# Prints the guard's output, then a final line "unsafe=N" carrying the flag it
# sets in its caller.
guard_out() {
    local script="$1" lib="$2" i1="$3"
    local dir="$BATS_TEST_TMPDIR/g"
    rm -rf "$dir"; mkdir -p "$dir"
    printf '[Interface]\nPrivateKey = x\nI1 = %s\n' "$i1" > "$dir/awg0.conf"

    bash -c '
        SERVER_CONF_FILE="$1/awg0.conf"
        warn=0
        _cps_unsafe=0
        # Minimal stand-ins: the guard only needs a way to print a line.
        _diag_line() { echo "[$1] ${*:2}"; }
        eval "$(awk "/^awg_cps_decoded_size\\(\\) \\{/,/^}\$/" "$3")"
        eval "$(awk "/^_diag_cps_guard\\(\\) \\{/,/^}\$/" "$2")"
        _diag_cps_guard
        echo "unsafe=$_cps_unsafe"
    ' _ "$dir" "$script" "$lib"
}

@test "cps behaviour: an oversized I1 warns and names the size" {
    run guard_out "$MANAGE" "$COMMON" '<r 4096>'
    [ "$status" -eq 0 ]
    [[ "$output" == *"4096"* ]]
    [[ "$output" == *"unsafe=1"* ]]
}

# 🔴 The property the whole change exists for. Warning and then walking into
# the very call that loops would protect nobody: a timeout bounds time, not the
# memory a spinning reader consumes.
@test "cps behaviour: an oversized I1 marks the interface read unsafe" {
    run guard_out "$MANAGE" "$COMMON" '<r 4096>'
    [[ "$output" == *"unsafe=1"* ]]
}

@test "cps behaviour: a normal I1 leaves the interface read enabled" {
    # The mirror. Without it a guard that always skips would look perfect while
    # breaking diagnostics for everyone.
    run guard_out "$MANAGE" "$COMMON" '<r 64>'
    [[ "$output" == *"unsafe=0"* ]]
}

@test "cps behaviour: an unparsable tag is reported, not counted as small" {
    run guard_out "$MANAGE" "$COMMON" '<nosuchtag 9>'
    [[ "$output" == *"unsafe=1"* ]]
    [[ "$output" == *"WARN"* ]]
}

@test "cps behaviour: a leading-zero count does not silently disable the guard" {
    # `<r 08>` is octal to bash. Before the fix the arithmetic failed, the
    # function returned an empty string, and the threshold comparison never
    # fired - the guard was off and said nothing.
    run guard_out "$MANAGE" "$COMMON" '<r 08><r 4096>'
    [[ "$output" == *"unsafe=1"* ]]
}

@test "cps behaviour: an unreadable config is reported rather than passed over" {
    run bash -c '
        SERVER_CONF_FILE="/nonexistent/awg0.conf"
        warn=0
        _cps_unsafe=0
        _diag_line() { echo "[$1] ${*:2}"; }
        eval "$(awk "/^awg_cps_decoded_size\(\) \{/,/^}$/" "'"$COMMON"'")"
        eval "$(awk "/^_diag_cps_guard\(\) \{/,/^}$/" "'"$MANAGE"'")"
        _diag_cps_guard
        echo "unsafe=$_cps_unsafe"
    '
    [[ "$output" == *"unsafe=1"* ]]
    [[ "$output" == *"WARN"* ]]
}

@test "cps behaviour: the EN guard behaves the same" {
    run guard_out "$MANAGE_EN" "$COMMON_EN" '<r 4096>'
    [[ "$output" == *"4096"* ]]
    [[ "$output" == *"unsafe=1"* ]]
}
