#!/usr/bin/env bats
# The probe of the LOADED kernel module: does it understand the third-line
# parameters.
#
# The line cannot be read off the module version string (the same 3.1.20260812
# string was seen on two different builds), so the capability is probed: a
# header protection key and a padding range are set on a temporary interface and
# read back. Unknown netlink attributes are passed over silently by an older
# module, so a silent acceptance without a read back is a second-line module,
# not a success.
#
# A refusal from `awg set` is deliberately NOT a verdict on its own: it looks the
# same for a second-line module and for an environment problem. The probe then
# runs a control command without the third-line parameters and decides by that.
#
# Harness: `ip` and `awg` are stubs in front of PATH, the two functions are
# lifted out of the installer, and both twins run every case.

bats_require_minimum_version 1.5.0

INSTALL_RU="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
INSTALL_EN="$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"

func_from() { sed -n "/^$2()/,/^)$/p; /^$2() {/,/^}/p" "$1"; }

setup() {
    TEST_DIR=$(mktemp -d)
    BIN="$TEST_DIR/bin"
    mkdir -p "$BIN"
    export TEST_DIR BIN
}

teardown() {
    [ -n "${TEST_DIR:-}" ] && rm -rf "$TEST_DIR"
}

# make_ip <mode> : add - creates; fail - refuses to create; busy - every name
# already exists; hang - never answers.
make_ip() {
    local mode="$1"
    {
        echo '#!/usr/bin/env bash'
        echo "echo \"\$*\" >> \"$TEST_DIR/ip.argv\""
        # The verb is the SECOND word: the calls are `ip link show|add|del`.
        case "$mode" in
            add)  echo 'case "$2" in show) exit 1 ;; add) exit 0 ;; del) exit 0 ;; esac; exit 0' ;;
            fail) echo 'case "$2" in show) exit 1 ;; add) exit 2 ;; del) exit 0 ;; esac; exit 0' ;;
            busy) echo 'case "$2" in show) exit 0 ;; add) exit 2 ;; del) exit 0 ;; esac; exit 0' ;;
            hang) echo 'case "$2" in show) exit 1 ;; add) sleep 30 ;; del) exit 0 ;; esac; exit 0' ;;
        esac
    } > "$BIN/ip"
    chmod +x "$BIN/ip"
}

# make_awg <mode> : ok - accepts and reads back; silent - accepts and reads back
# nothing of the sort; refuse - refuses the third-line set, control passes;
# dead - refuses everything; empty - showconf prints nothing; hang - set hangs.
make_awg() {
    local mode="$1"
    {
        echo '#!/usr/bin/env bash'
        echo "echo \"\$*\" >> \"$TEST_DIR/awg.argv\""
        echo 'case "$1" in'
        echo '  genkey) echo "PROBEKEYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ;;'
        echo '  set)'
        case "$mode" in
            ok|silent|empty)
                echo '    shift 2; printf "%s\n" "$*" > "'"$TEST_DIR"'/set.args"; exit 0 ;;' ;;
            refuse)
                echo '    if [[ "$*" == *header-protection-key* ]]; then exit 1; fi; exit 0 ;;' ;;
            dead)
                echo '    exit 1 ;;' ;;
            hang)
                echo '    if [[ "$*" == *header-protection-key* ]]; then sleep 30; fi; exit 0 ;;' ;;
        esac
        echo '  showconf)'
        case "$mode" in
            ok)
                echo '    echo "[Interface]"; echo "ListenPort = 51820"'
                echo '    echo "HeaderProtectionKey = PROBEKEYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="'
                echo '    echo "ContentPaddingAddition = 32-128"; exit 0 ;;' ;;
            silent)
                echo '    echo "[Interface]"; echo "ListenPort = 51820"; exit 0 ;;' ;;
            empty)
                echo '    exit 0 ;;' ;;
            *)
                echo '    exit 1 ;;' ;;
        esac
        echo 'esac'
        echo 'exit 0'
    } > "$BIN/awg"
    chmod +x "$BIN/awg"
}

# probe <installer> : the verdict the probe prints
probe() {
    local src="$1"
    PATH="$BIN:$PATH" TMPDIR="$TEST_DIR" timeout 60 bash -c '
        eval "$(sed -n "/^_awg31_module_probe() (/,/^)$/p" "$1")"
        _awg31_module_probe
    ' _ "$src"
}

# support_rc <installer> : the exit code of awg31_module_support
support_rc() {
    local src="$1"
    PATH="$BIN:$PATH" TMPDIR="$TEST_DIR" timeout 60 bash -c '
        eval "$(sed -n "/^_awg31_module_probe() (/,/^)$/p" "$1")"
        eval "$(sed -n "/^awg31_module_support() {/,/^}/p" "$1")"
        awg31_module_support
        echo "RC=$?"
    ' _ "$src"
}

both() {
    local seen=0 src
    for src in "$INSTALL_RU" "$INSTALL_EN"; do
        "$1" "$src" || return 1
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}

# ----------------------------------------------------------------- verdicts

p_ok() {
    make_ip add; make_awg ok
    local out; out=$(probe "$1")
    [ "$out" = "ok" ] || { echo "a third-line module was not recognised ($1): $out"; return 1; }
}
@test "probe: a module that reads the key and the padding back is third line, both twins" {
    both p_ok
}

p_silent() {
    make_ip add; make_awg silent
    local out; out=$(probe "$1")
    [ "$out" = "line2" ] || { echo "a silent acceptance was not caught ($1): $out"; return 1; }
}
@test "probe: accepting the parameters and reading nothing back is second line, both twins" {
    both p_silent
}

p_empty() {
    make_ip add; make_awg empty
    local out; out=$(probe "$1")
    [ "$out" = "line2" ] || { echo "an empty showconf was not caught ($1): $out"; return 1; }
}
@test "probe: an empty showconf is second line, both twins" {
    both p_empty
}

p_refuse() {
    make_ip add; make_awg refuse
    local out; out=$(probe "$1")
    [ "$out" = "line2" ] || { echo "a refusal with a working control was not second line ($1): $out"; return 1; }
}
@test "probe: a refused set with a passing control is second line, both twins" {
    both p_refuse
}

p_dead() {
    make_ip add; make_awg dead
    local out; out=$(probe "$1")
    [ "$out" = "failed" ] || { echo "a device that refuses everything was judged ($1): $out"; return 1; }
}
@test "probe: a device that refuses the control too is not judged, both twins" {
    both p_dead
}

p_no_iface() {
    make_ip fail; make_awg ok
    local out; out=$(probe "$1")
    [ "$out" = "failed" ] || { echo "a failed interface creation was judged ($1): $out"; return 1; }
}
@test "probe: an interface that cannot be created is not judged, both twins" {
    both p_no_iface
}

p_hang_set() {
    make_ip add; make_awg hang
    local out start end
    start=$(date +%s)
    out=$(probe "$1")
    end=$(date +%s)
    [ "$out" = "failed" ] || { echo "a hanging set was judged ($1): $out"; return 1; }
    [ "$((end - start))" -lt 25 ] || { echo "the probe waited for a hanging set ($1)"; return 1; }
}
@test "probe: a hanging set is bounded and not judged, both twins" {
    both p_hang_set
}

p_hang_add() {
    make_ip hang; make_awg ok
    local out start end
    start=$(date +%s)
    out=$(probe "$1")
    end=$(date +%s)
    [ "$out" = "failed" ] || { echo "a hanging ip link add was judged ($1): $out"; return 1; }
    [ "$((end - start))" -lt 25 ] || { echo "the probe waited for a hanging ip ($1)"; return 1; }
}
@test "probe: a hanging interface creation is bounded, both twins" {
    both p_hang_add
}

# -------------------------------------------------------------- housekeeping

p_cleanup() {
    make_ip add; make_awg ok
    probe "$1" >/dev/null
    grep -q "^link del " "$TEST_DIR/ip.argv" || { echo "the interface was not removed ($1): $(cat "$TEST_DIR/ip.argv")"; return 1; }
    local left
    left=$(find "$TEST_DIR" -maxdepth 1 -name 'awg31probe.*' | wc -l)
    [ "$left" -eq 0 ] || { echo "the key file was left behind ($1)"; return 1; }
}
@test "probe: the interface and the key file are removed on the happy path, both twins" {
    both p_cleanup
}

p_cleanup_failure() {
    make_ip add; make_awg dead
    probe "$1" >/dev/null
    grep -q "^link del " "$TEST_DIR/ip.argv" || { echo "the interface survived a failed probe ($1)"; return 1; }
    local left
    left=$(find "$TEST_DIR" -maxdepth 1 -name 'awg31probe.*' | wc -l)
    [ "$left" -eq 0 ] || { echo "the key file survived a failed probe ($1)"; return 1; }
}
@test "probe: the interface and the key file are removed after a failure too, both twins" {
    both p_cleanup_failure
}

p_name() {
    make_ip add; make_awg ok
    probe "$1" >/dev/null
    local name
    name=$(grep -m1 '^link add ' "$TEST_DIR/ip.argv" | awk '{print $3}')
    [ -n "$name" ] || { echo "no interface was created ($1)"; return 1; }
    [ "$name" != "awg0" ] || { echo "the probe touched awg0 ($1)"; return 1; }
    [ "${#name}" -le 15 ] || { echo "the interface name is longer than 15 characters ($1): $name"; return 1; }
}
@test "probe: the temporary interface is never awg0 and fits the name limit, both twins" {
    both p_name
}

p_key_not_in_argv() {
    make_ip add; make_awg ok
    probe "$1" >/dev/null
    grep -q "PROBEKEYAAAA" "$TEST_DIR/awg.argv" && { echo "the key went into argv ($1)"; return 1; }
    grep -q "header-protection-key" "$TEST_DIR/awg.argv" || { echo "the key was never set ($1)"; return 1; }
    return 0
}
@test "probe: the key reaches the module as a file, never in argv, both twins" {
    both p_key_not_in_argv
}

p_one_command() {
    make_ip add; make_awg ok
    probe "$1" >/dev/null
    local args
    args=$(cat "$TEST_DIR/set.args")
    for token in s1 s2 s3 s4 header-protection-key content-padding-addition; do
        [[ "$args" == *"$token"* ]] || { echo "$token is missing from the single set command ($1): $args"; return 1; }
    done
}
@test "probe: the padding sizes and the key go in one command, both twins" {
    both p_one_command
}

# ------------------------------------------------------------- return codes

s_codes() {
    local src="$1" out
    make_ip add; make_awg ok
    out=$(support_rc "$src"); [[ "$out" == *"RC=0"* ]] || { echo "a third-line module did not give 0 ($src): $out"; return 1; }
    make_ip add; make_awg silent
    out=$(support_rc "$src"); [[ "$out" == *"RC=1"* ]] || { echo "a second-line module did not give 1 ($src): $out"; return 1; }
    make_ip add; make_awg dead
    out=$(support_rc "$src"); [[ "$out" == *"RC=2"* ]] || { echo "an unusable probe did not give 2 ($src): $out"; return 1; }
}
@test "support: 0 for the third line, 1 for the second, 2 for could not check, both twins" {
    both s_codes
}

# ------------------------------------------------------------ the gate wiring

@test "gate: the module probe runs after the tools check and before not_implemented_yet" {
    local f body tools mod nimpl
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        body=$(sed -n '/^awg31_environment_blocker() {/,/^}/p' "$BATS_TEST_DIRNAME/../$f")
        tools=$(grep -n 'awg31_tools_support' <<< "$body" | head -1 | cut -d: -f1)
        mod=$(grep -n 'awg31_module_support' <<< "$body" | head -1 | cut -d: -f1)
        nimpl=$(grep -n "printf 'not_implemented_yet'" <<< "$body" | head -1 | cut -d: -f1)
        [ -n "$tools" ] && [ -n "$mod" ] && [ -n "$nimpl" ] || { echo "a check is missing in $f"; return 1; }
        [ "$mod" -gt "$tools" ] || { echo "the module probe runs before the tools check in $f"; return 1; }
        [ "$nimpl" -gt "$mod" ] || { echo "not_implemented_yet comes before the module probe in $f"; return 1; }
    done
}

@test "gate: both module codes have their own refusal text, and the texts differ" {
    local f body l2 pf
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        body=$(sed -n '/^_awg31_blocker_message() {/,/^}/p' "$BATS_TEST_DIRNAME/../$f")
        l2=$(awk '/module_line2\)/{f=1;next} f&&/;;/{exit} f' <<< "$body")
        pf=$(awk '/module_probe_failed\)/{f=1;next} f&&/;;/{exit} f' <<< "$body")
        [ -n "$l2" ] && [ -n "$pf" ] || { echo "a message is missing in $f"; return 1; }
        [ "$l2" != "$pf" ] || { echo "the two module messages are the same in $f"; return 1; }
        [[ "$l2" == *"amneziawg-dkms"* ]] || { echo "the second-line text does not name the way out in $f"; return 1; }
        [[ "$pf" == *"--protocol=2.0"* ]] || { echo "the probe-failed text does not name the way out in $f"; return 1; }
    done
}

@test "probe: the body is identical in RU and EN except the comments" {
    local ru en
    ru=$(sed -n '/^_awg31_module_probe() (/,/^)$/p' "$INSTALL_RU" | grep -vE '^\s*#' | tr -d '\r')
    en=$(sed -n '/^_awg31_module_probe() (/,/^)$/p' "$INSTALL_EN" | grep -vE '^\s*#' | tr -d '\r')
    [ -n "$ru" ]
    [ "$ru" = "$en" ]
}
