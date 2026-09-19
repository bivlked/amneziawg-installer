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
# runs two control steps, each taking one thing away, and only a real refusal of
# the key itself is a second-line verdict.
#
# Harness: `ip` and `awg` are stubs in front of PATH, the two functions are
# lifted out of the installer, and both twins run every case.

bats_require_minimum_version 1.5.0

INSTALL_RU="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
INSTALL_EN="$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"

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
# already exists; hang - never answers to add; hangshow - never answers to show;
# delfail - creates, but refuses to delete;
# vanish - creates, but never admits the device exists afterwards, which is what
#          an interface that went away in mid probe looks like.
#
# 🔴 The creating modes keep a directory of the names they made, so that `show`
# answers about a device that exists. A stub that says "no such interface" right
# after creating it is not a model of ip: the probe asks again after a refusal,
# to tell "the module said no" from "the device went away", and against the old
# stub that question always answered "gone".
make_ip() {
    local mode="$1"
    # The argv logs are truncated here: both twins run inside one @test, and a
    # cumulative file lets the first twin satisfy an assertion about the second.
    rm -f "$TEST_DIR/ip.argv" "$TEST_DIR/awg.argv" "$TEST_DIR/set.args"
    rm -rf "$TEST_DIR/ifaces"
    {
        echo '#!/usr/bin/env bash'
        echo "echo \"\$*\" >> \"$TEST_DIR/ip.argv\""
        # The verb is the SECOND word: the calls are `ip link show|add|del`.
        case "$mode" in
            add)  echo 'D="'"$TEST_DIR"'/ifaces"; case "$2" in show) [ -e "$D/$3" ] && exit 0 || exit 1 ;; add) mkdir -p "$D"; : > "$D/$3"; exit 0 ;; del) rm -f "$D/$3"; exit 0 ;; esac; exit 0' ;;
            delfail) echo 'D="'"$TEST_DIR"'/ifaces"; case "$2" in show) [ -e "$D/$3" ] && exit 0 || exit 1 ;; add) mkdir -p "$D"; : > "$D/$3"; exit 0 ;; del) exit 1 ;; esac; exit 0' ;;
            vanish) echo 'case "$2" in show) exit 1 ;; add) exit 0 ;; del) exit 0 ;; esac; exit 0' ;;
            fail) echo 'case "$2" in show) exit 1 ;; add) exit 2 ;; del) exit 0 ;; esac; exit 0' ;;
            busy) echo 'case "$2" in show) exit 0 ;; add) exit 2 ;; del) exit 0 ;; esac; exit 0' ;;
            hang) echo 'case "$2" in show) exit 1 ;; add) sleep 30 ;; del) exit 0 ;; esac; exit 0' ;;
            hangshow) echo 'case "$2" in show) sleep 30 ;; add) exit 0 ;; del) exit 0 ;; esac; exit 0' ;;
            delhang) echo 'D="'"$TEST_DIR"'/ifaces"; case "$2" in show) [ -e "$D/$3" ] && exit 0 || exit 1 ;; add) mkdir -p "$D"; : > "$D/$3"; exit 0 ;; del) sleep 30 ;; esac; exit 0' ;;
        esac
    } > "$BIN/ip"
    chmod +x "$BIN/ip"
}

# make_awg <mode> : ok - accepts and reads back; silent - accepts and reads back
# nothing of the sort; refuse - refuses any set carrying the key, so control
#          step 1 passes and step 2 refuses, which is what produces the verdict;
# dead - refuses every set, control step 1 included; empty - showconf prints
#        nothing; hang - set hangs;
# cpaonly - takes the key but refuses the padding range;
# ctlhang - refuses the full set, passes control step 1 and hangs on step 2;
# showfail - takes the set and then refuses showconf;
# showhang - takes the set and never answers showconf;
# nokey - genkey prints nothing;
# badkey - genkey exits zero but prints a key of the wrong shape;
# keygone - the main set refuses AND takes the key file away, so control step 2
#           would refuse over the file rather than over the module;
# hpkshow - the key comes back but the padding range does not;
# cpashow - the padding range comes back but the key does not;
# wrongkey - a well formed but DIFFERENT key comes back, which is what a module
#           that masks the value would look like;
# keyhang - awg genkey never answers;
# notconf - the set is taken, but showconf answers with something that is not a
#           config at all;
# hangrefuse - the full set hangs, and a later set carrying the key refuses.
make_awg() {
    local mode="$1"
    {
        echo '#!/usr/bin/env bash'
        echo "echo \"\$*\" >> \"$TEST_DIR/awg.argv\""
        echo 'case "$1" in'
        case "$mode" in
            nokey)  echo '  genkey) exit 0 ;;' ;;
            badkey)  echo '  genkey) echo "SHORTKEY=" ;;' ;;
            keyhang) echo '  genkey) sleep 30 ;;' ;;
            *)       echo '  genkey) echo "PROBE+KEY/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ;;' ;;
        esac
        echo '  set)'
        case "$mode" in
            ok|silent|empty|hpkshow|cpashow|wrongkey|keyhang)
                echo '    shift 2; printf "%s\n" "$*" > "'"$TEST_DIR"'/set.args"; exit 0 ;;' ;;
            refuse)
                # The wording is the one a module built from tag v1.0.20260725
                # printed on the stand, so the stub refuses the way the real one
                # does: on stderr, with exit code 1.
                echo '    if [[ "$*" == *header-protection-key* ]]; then echo "Unable to modify interface: Invalid argument" >&2; exit 1; fi; exit 0 ;;' ;;
            cpaonly)
                echo '    if [[ "$*" == *content-padding-addition* ]]; then exit 1; fi; exit 0 ;;' ;;
            ctlhang)
                echo '    if [[ "$*" == *content-padding-addition* ]]; then exit 1; fi'
                echo '    if [[ "$*" == *header-protection-key* ]]; then sleep 30; fi'
                echo '    exit 0 ;;' ;;
            dead)
                echo '    exit 1 ;;' ;;
            hang)
                echo '    if [[ "$*" == *header-protection-key* ]]; then sleep 30; fi; exit 0 ;;' ;;
            hangrefuse)
                echo '    if [[ "$*" == *content-padding-addition* ]]; then sleep 30; fi'
                echo '    if [[ "$*" == *header-protection-key* ]]; then echo "Unable to modify interface: Invalid argument" >&2; exit 1; fi'
                echo '    exit 0 ;;' ;;
            keygone)
                # The path travels in argv right after header-protection-key.
                # It is picked out by walking the arguments: ${*#pattern} would
                # strip the prefix from EACH argument separately rather than
                # from the joined string, which silently yields the wrong path.
                echo '    p=""; prev=""; for a in "$@"; do [ "$prev" = "header-protection-key" ] && p="$a"; prev="$a"; done'
                echo '    if [[ "$*" == *content-padding-addition* ]]; then rm -f "$p"; exit 1; fi'
                echo '    if [[ "$*" == *header-protection-key* ]]; then [ -s "$p" ] || exit 1; exit 0; fi'
                echo '    exit 0 ;;' ;;
            showfail|showhang|nokey|badkey|notconf)
                echo '    shift 2; printf "%s\n" "$*" > "'"$TEST_DIR"'/set.args"; exit 0 ;;' ;;
        esac
        echo '  showconf)'
        case "$mode" in
            ok)
                echo '    echo "[Interface]"; echo "ListenPort = 51820"'
                echo '    echo "HeaderProtectionKey = PROBE+KEY/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="'
                echo '    echo "ContentPaddingAddition = 32-128"; exit 0 ;;' ;;
            silent)
                echo '    echo "[Interface]"; echo "ListenPort = 51820"; exit 0 ;;' ;;
            hpkshow)
                echo '    echo "[Interface]"; echo "HeaderProtectionKey = PROBE+KEY/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; exit 0 ;;' ;;
            cpashow)
                echo '    echo "[Interface]"; echo "ContentPaddingAddition = 32-128"; exit 0 ;;' ;;
            wrongkey)
                echo '    echo "[Interface]"; echo "HeaderProtectionKey = OTHER+KEY/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA="'
                echo '    echo "ContentPaddingAddition = 32-128"; exit 0 ;;' ;;
            empty)
                echo '    exit 0 ;;' ;;
            notconf)
                echo '    echo "awg: command not found"; exit 0 ;;' ;;
            showfail)
                echo '    exit 1 ;;' ;;
            showhang)
                echo '    sleep 30 ;;' ;;
            nokey)
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

# An interface that exists always makes `awg showconf` print at least the
# [Interface] line (measured on a stand, 19 sep 2026). So a zero exit with no
# output at all is the environment talking, not the module: a substituted
# binary, a truncated pipe, a device that went away. Calling that second line
# would tell someone to rebuild a module nothing is known about.
p_empty() {
    make_ip add; make_awg empty
    local out; out=$(probe "$1")
    [ "$out" = "failed" ] || { echo "an empty showconf was judged instead of refused ($1): $out"; return 1; }
}
@test "probe: an empty showconf names no generation, both twins" {
    both p_empty
}

# Same rule one step further out: output that is not a config at all.
p_notconf() {
    make_ip add; make_awg notconf
    local out; out=$(probe "$1")
    [ "$out" = "failed" ] || { echo "an answer that is not a config was judged ($1): $out"; return 1; }
}
@test "probe: an answer that is not a config names no generation, both twins" {
    both p_notconf
}

# A genkey that exits zero and prints rubbish must not reach the module. If it
# did, control step 2 would refuse over the KEY FILE and we would call a healthy
# module second line, sending its owner to rebuild it for nothing.
p_badkey() {
    make_ip add; make_awg badkey
    local out; out=$(probe "$1")
    [ "$out" = "failed" ] || { echo "a malformed key was used as if it were one ($1): $out"; return 1; }
    grep -q 'set ' "$TEST_DIR/awg.argv" && { echo "the probe sent a set with a malformed key ($1)"; return 1; }
    return 0
}
@test "probe: a key of the wrong shape stops the probe, both twins" {
    both p_badkey
}

# 🔴 Half an answer is not a verdict. Upstream shipped the third-line
# parameters at different times, so a build that knows the key and not the
# padding exists. Calling it second line would be false in both clauses of that
# message, and its advice to rebuild the module would be a guess.
p_hpk_only_back() {
    make_ip add; make_awg hpkshow
    local out; out=$(probe "$1")
    [ "$out" = "failed" ] || { echo "a key back without the padding was judged ($1): $out"; return 1; }
}
@test "probe: the key back without the padding names no generation, both twins" {
    both p_hpk_only_back
}

p_cpa_only_back() {
    make_ip add; make_awg cpashow
    local out; out=$(probe "$1")
    [ "$out" = "failed" ] || { echo "the padding back without the key was judged ($1): $out"; return 1; }
}
@test "probe: the padding back without the key names no generation, both twins" {
    both p_cpa_only_back
}

# A module or tool that masks the value would echo a well formed key that is not
# ours. Matching the field name alone would read that as a third-line module;
# this installer masks header protection keys elsewhere for exactly that reason.
p_wrong_key_back() {
    make_ip add; make_awg wrongkey
    local out; out=$(probe "$1")
    [ "$out" = "failed" ] || { echo "a key we never set was accepted as ours ($1): $out"; return 1; }
}
@test "probe: a key that is not the one we set is not a third-line verdict, both twins" {
    both p_wrong_key_back
}

# Every other external call of the probe has a hang case. This one is the first
# thing it runs, so without a bound the whole install step stops with no message.
p_genkey_hangs() {
    make_ip add; make_awg keyhang
    local start end out
    start=$(date +%s)
    out=$(probe "$1")
    end=$(date +%s)
    [ "$out" = "failed" ] || { echo "a hanging genkey was judged ($1): $out"; return 1; }
    [ $((end - start)) -lt 20 ] || { echo "the probe waited for a hanging genkey ($1): $((end - start))s"; return 1; }
}
@test "probe: a hanging key generation is bounded and not judged, both twins" {
    both p_genkey_hangs
}

p_refuse() {
    make_ip add; make_awg refuse
    local out; out=$(probe "$1")
    [ "$out" = "line2" ] || { echo "a refused key on control step 2 was not second line ($1): $out"; return 1; }
}
@test "probe: a key refused on control step 2 is second line, both twins" {
    both p_refuse
}

# 🔴 A one from `awg set` means "any error", not "the module said no". An
# interface that went away in mid probe returns the same one, and reading a
# second line out of that would send its owner to rebuild a healthy module. The
# device is checked, not the wording of the error: tool messages change between
# versions, the presence of a device does not.
p_refuse_but_gone() {
    make_ip vanish; make_awg refuse
    local out; out=$(probe "$1")
    [ "$out" = "failed" ] || { echo "a refusal with the device gone was read as a verdict ($1): $out"; return 1; }
}
@test "probe: a refusal with the interface gone names no generation, both twins" {
    both p_refuse_but_gone
}

p_dead() {
    make_ip add; make_awg dead
    local out; out=$(probe "$1")
    [ "$out" = "failed" ] || { echo "a device that refuses control step 1 as well was judged ($1): $out"; return 1; }
}
@test "probe: a device that refuses control step 1 as well is not judged, both twins" {
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
    local args token
    args=$(cat "$TEST_DIR/set.args")
    # Values, not just names: with the key set the module demands S1..S4 of at
    # least 12, so a padding size that silently changed would make the probe
    # refuse on a healthy module.
    for token in "s1 15" "s2 15" "s3 12" "s4 12" "content-padding-addition 32-128" "header-protection-key"; do
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

p_busy() {
    # Every candidate name is taken: the probe must give up rather than write
    # into a device that belongs to someone else.
    make_ip busy; make_awg ok
    local out; out=$(probe "$1")
    [ "$out" = "failed" ] || { echo "a taken name did not stop the probe ($1): $out"; return 1; }
    grep -q "^link add " "$TEST_DIR/ip.argv" && { echo "the probe wrote into an existing interface ($1)"; return 1; }
    return 0
}
@test "probe: when every candidate name is taken nothing is created, both twins" {
    both p_busy
}

p_hang_show() {
    # The name check is an external call like any other: on a stuck netlink it
    # would hang the install step with no message at all.
    make_ip hangshow; make_awg ok
    local out start end
    start=$(date +%s)
    out=$(probe "$1")
    end=$(date +%s)
    [ "$out" = "failed" ] || { echo "a hanging name check was judged ($1): $out"; return 1; }
    [ "$((end - start))" -lt 25 ] || { echo "the probe waited for a hanging ip link show ($1)"; return 1; }
}
@test "probe: a hanging name check is bounded too, both twins" {
    both p_hang_show
}

@test "cleanup: the installer removes a probe interface left by a signal, both twins" {
    # The trap inside the probe covers an ordinary exit. A signal can cut the
    # subshell before it runs, and that is measurable: bash does not always give
    # the subshell its turn. So the installer cleanup, which is guaranteed to
    # run, removes anything the probe may have left. The pattern carries the
    # installer pid, so it can only match interfaces of this very run.
    # 🔴 The marker is a FILE, not a variable. The probe is called through
    # $( ), so anything it assigns dies with the subshell; a flag in a variable
    # turned this whole block into dead code once already, and the tests did not
    # see it because they set the flag by hand.
    local f body
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        body=$(sed -n '/^_install_cleanup() {/,/^}/p' "$BATS_TEST_DIRNAME/../$f")
        [ -n "$body" ] || { echo "no _install_cleanup in $f"; return 1; }
        grep -q 'awg31probe' <<< "$body" || { echo "the cleanup does not look for the probe record in $f"; return 1; }
        grep -q 'ip link del' <<< "$body" || { echo "the cleanup does not delete anything in $f"; return 1; }
        if grep -q '_awg31_probe_ran' <<< "$body"; then
            echo "the cleanup keys off a variable a subshell cannot set in $f"
            return 1
        fi
    done
    return 0
}

c_cleanup_runs() {
    # The same cleanup, executed. The probe records the name it created; the
    # cleanup removes exactly that one. A name the probe stepped over, because
    # it was already taken, must survive: the probe refuses to write into a
    # device it did not create, and the cleanup has to be no less careful.
    local src="$1" out
    out=$(timeout 60 bash -c '
        mkdir -p "$2/bin" "$2/tmp"
        cat > "$2/bin/ip" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$2/deleted"
exit 0
STUB
        chmod +x "$2/bin/ip"
        export PATH="$2/bin:$PATH"
        export TMPDIR="$2/tmp"
        rm -f "$2/deleted"
        printf "%s\n" "awgp${$}x2" > "$TMPDIR/awg31probe.$$.iface"
        _install_temp_files=()
        _install_cleaned=0
        eval "$(sed -n "/^_install_cleanup() {/,/^}/p" "$1")"
        _install_cleanup
        cat "$2/deleted" 2>/dev/null
    ' _ "$src" "$TEST_DIR")
    [[ "$out" == *"link del awgp"*"x2"* ]] || { echo "the recorded interface was not deleted ($src): [$out]"; return 1; }
    [[ "$out" != *"x1"* ]] || { echo "an interface the probe stepped over was deleted ($src): $out"; return 1; }
    [[ "$out" != *"awg0"* ]] || { echo "the working interface was deleted ($src): $out"; return 1; }
}
@test "cleanup: exactly the recorded interface is removed, both twins" {
    both c_cleanup_runs
}

c_cleanup_skipped() {
    # No probe in this run means no record, and then not one external command
    # may run: the EXIT trap fires on every exit of the installer, --help
    # included.
    local src="$1" out
    out=$(timeout 60 bash -c '
        mkdir -p "$2/bin" "$2/tmp"
        cat > "$2/bin/ip" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$2/called"
exit 0
STUB
        chmod +x "$2/bin/ip"
        export PATH="$2/bin:$PATH"
        export TMPDIR="$2/tmp"
        rm -f "$2/called"
        _install_temp_files=()
        _install_cleaned=0
        eval "$(sed -n "/^_install_cleanup() {/,/^}/p" "$1")"
        _install_cleanup
        cat "$2/called" 2>/dev/null
    ' _ "$src" "$TEST_DIR")
    [ -z "$out" ] || { echo "the cleanup called ip although no probe ran ($src): [$out]"; return 1; }
}
@test "cleanup: nothing is swept when the probe left no record, both twins" {
    both c_cleanup_skipped
}

c_cleanup_wiring() {
    # End to end, through the shape the installer really uses: the probe runs in
    # a subshell, and what it leaves behind has to reach the cleanup.
    # 🔴 This is the test that would have caught a marker kept in a VARIABLE.
    # Every other cleanup test lays the marker down by hand, so all of them
    # stayed green while the sweep was dead code on every real run.
    local src="$1" left
    # The probe cannot remove its own interface here, so it must keep the record
    # for the installer cleanup rather than dropping it.
    make_ip delfail; make_awg ok
    probe "$src" >/dev/null
    left=$(ls "$TEST_DIR"/awg31probe.*.iface 2>/dev/null | wc -l)
    [ "$left" -eq 1 ] || { echo "a delete that failed left no record for the cleanup ($src): $left"; return 1; }

    # And on the ordinary path, where the probe does remove its interface, the
    # record has to be gone: otherwise the cleanup would chase a device that is
    # no longer there and warn about it. The record of the run above is taken
    # away first, or this half would count that one and pass on it.
    rm -f "$TEST_DIR"/awg31probe.*
    make_ip add; make_awg ok
    probe "$src" >/dev/null
    left=$(ls "$TEST_DIR"/awg31probe.*.iface 2>/dev/null | wc -l)
    [ "$left" -eq 0 ] || { echo "the record outlived a successful delete ($src): $left"; return 1; }
}
@test "cleanup: the probe leaves a record the cleanup can act on, both twins" {
    both c_cleanup_wiring
}

c_cleanup_speaks() {
    # This sweep is the last line of defence after a SIGKILL, so its silence
    # would be the last signal going quiet: a leftover that cannot be removed
    # has to be named.
    local src="$1" out
    out=$(timeout 60 bash -c '
        mkdir -p "$2/bin" "$2/tmp"
        printf "#!/usr/bin/env bash\nexit 1\n" > "$2/bin/ip"
        chmod +x "$2/bin/ip"
        export PATH="$2/bin:$PATH"
        export TMPDIR="$2/tmp"
        printf "%s\n" "awgp${$}x1" > "$TMPDIR/awg31probe.$$.iface"
        log_warn() { echo "WARNED $*"; }
        _install_temp_files=()
        _install_cleaned=0
        eval "$(sed -n "/^_install_cleanup() {/,/^}/p" "$1")"
        _install_cleanup
    ' _ "$src" "$TEST_DIR")
    [[ "$out" == *WARNED* ]] || { echo "a leftover that could not be removed was passed over in silence ($src): [$out]"; return 1; }
    [[ "$out" == *awgp* ]] || { echo "the warning does not name the leftover ($src): [$out]"; return 1; }
}
@test "cleanup: a leftover that cannot be removed is named, both twins" {
    both c_cleanup_speaks
}

c_probe_cleanup_idempotent() {
    # On a signal the probe cleanup runs from the handler and then again on
    # EXIT. Without a guard the second run spends another bounded delete on an
    # interface that is already gone: up to five more seconds of silence on
    # Ctrl-C, in exactly the wedged netlink state the probe exists to refuse
    # over. The installer cleanup has carried this guard for a long time; the
    # probe one was written without it.
    local f body
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        body=$(sed -n '/^_awg31_module_probe() (/,/^)$/p' "$BATS_TEST_DIRNAME/../$f")
        [ -n "$body" ] || { echo "no probe body in $f"; return 1; }
        grep -q 'cleaned=1' <<< "$body" || { echo "the probe cleanup does not mark itself done in $f"; return 1; }
        # Matched loosely on purpose: the point is that the flag guards an early
        # return, not the exact shape of the condition.
        grep -qE 'cleaned"? -eq 1 \]\].*return 0' <<< "$body" || { echo "the probe cleanup does not return early on a second run in $f"; return 1; }
    done
}
@test "cleanup: the probe cleanup does nothing on a second run, both twins" {
    c_probe_cleanup_idempotent
}

p_key_gone_before_control() {
    # Control step 2 judges by exit code 1, and awg set returns one on any
    # error, a key file it cannot read included. If the file goes away between
    # the shape check and that step, the refusal is about the FILE, and reading
    # a second-line module out of it would send its owner to rebuild a healthy
    # one.
    make_ip add; make_awg keygone
    local out; out=$(probe "$1")
    [ "$out" = "failed" ] || { echo "a refusal over the key file was read as a verdict ($1): $out"; return 1; }
}
@test "probe: a key file that goes missing is not a second-line verdict, both twins" {
    both p_key_gone_before_control
}

c_cleanup_temp_files() {
    # The key file outlives a SIGKILL, because the subshell trap never runs.
    # Its name carries our pid, which is what lets the sweep find it without
    # touching anyone else's.
    local src="$1" out
    out=$(timeout 60 bash -c '
        mkdir -p "$2/bin" "$2/tmp"
        printf "#!/usr/bin/env bash\nexit 0\n" > "$2/bin/ip"
        chmod +x "$2/bin/ip"
        export PATH="$2/bin:$PATH"
        export TMPDIR="$2/tmp"
        rm -f "$TMPDIR"/awg31probe.*
        : > "$TMPDIR/awg31probe.$$.left"
        : > "$TMPDIR/awg31probe.999999.other"
        _install_temp_files=()
        _install_cleaned=0
        eval "$(sed -n "/^_install_cleanup() {/,/^}/p" "$1")"
        _install_cleanup
        ls "$TMPDIR" 2>/dev/null
    ' _ "$src" "$TEST_DIR")
    [[ "$out" != *".left"* ]] || { echo "the probe key file survived the cleanup ($src): [$out]"; return 1; }
    [[ "$out" == *".other"* ]] || { echo "the cleanup removed a file of another run ($src): [$out]"; return 1; }
}
@test "cleanup: the probe temp files of this run are removed and others are not, both twins" {
    both c_cleanup_temp_files
}

p_control_shape() {
    # Two control steps, each dropping one thing at a time: first the padding
    # sizes alone, then the sizes plus the key. Dropping both third-line
    # parameters in one step cannot tell "the module does not know the key" from
    # "the module does not like this padding range".
    make_ip add; make_awg refuse
    probe "$1" >/dev/null
    local step1 step2
    step1=$(grep "^set " "$TEST_DIR/awg.argv" | sed -n 2p)
    step2=$(grep "^set " "$TEST_DIR/awg.argv" | sed -n 3p)
    [ -n "$step1" ] && [ -n "$step2" ] || { echo "the two control steps did not run ($1): $(cat "$TEST_DIR/awg.argv")"; return 1; }
    local token
    for token in "s1 15" "s2 15" "s3 12" "s4 12"; do
        [[ "$step1" == *"$token"* ]] || { echo "control step 1 lost $token ($1): $step1"; return 1; }
        [[ "$step2" == *"$token"* ]] || { echo "control step 2 lost $token ($1): $step2"; return 1; }
    done
    [[ "$step1" != *header-protection-key* ]] || { echo "control step 1 still carries the key ($1): $step1"; return 1; }
    [[ "$step1" != *content-padding-addition* ]] || { echo "control step 1 still carries the padding ($1): $step1"; return 1; }
    [[ "$step2" == *header-protection-key* ]] || { echo "control step 2 lost the key ($1): $step2"; return 1; }
    [[ "$step2" != *content-padding-addition* ]] || { echo "control step 2 still carries the padding ($1): $step2"; return 1; }
}
@test "probe: the two control steps drop one thing at a time, both twins" {
    both p_control_shape
}

p_key_ok_padding_not() {
    # A module that takes the key and refuses the padding range is not a
    # second-line module, and telling its owner to rebuild the module would be
    # wrong. The honest answer is that the check could not be made.
    make_ip add; make_awg cpaonly
    local out; out=$(probe "$1")
    [ "$out" = "failed" ] || { echo "a module that took the key was judged ($1): $out"; return 1; }
}
@test "probe: the key taken and the padding refused is not a second-line verdict, both twins" {
    both p_key_ok_padding_not
}

@test "probe: the refusal text reproduces the probe and cleans up after itself" {
    local f body
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        body=$(sed -n '/^_awg31_blocker_message() {/,/^}/p' "$BATS_TEST_DIRNAME/../$f")
        body=$(awk '/module_probe_failed\)/{f=1;next} f&&/;;/{exit} f' <<< "$body")
        [[ "$body" == *"ip link add awgprobe"* ]] || { echo "no reproduction command in $f"; return 1; }
        [[ "$body" == *"ip link del awgprobe"* ]] || { echo "the text leaves the interface behind in $f"; return 1; }
        # The recipe has to reproduce the main command of the probe and the read
        # back, not only the controls, and the count word has to match the list.
        [[ "$body" == *"content-padding-addition 32-128"* ]] || { echo "the recipe cannot reproduce the main command in $f"; return 1; }
        local listed keys
        listed=$(grep -o "awg set awgprobe\|awg showconf awgprobe\|ip link add awgprobe\|ip link del awgprobe" <<< "$body" | wc -l)
        if [[ "$f" == *_en.sh ]]; then
            [[ "$body" == *"six commands"* ]] || { echo "the count word does not say six in $f"; return 1; }
        else
            [[ "$body" == *"шести команд"* ]] || { echo "the count word does not say six in $f"; return 1; }
        fi
        [ "$listed" -eq 6 ] || { echo "the recipe lists $listed commands, not six, in $f"; return 1; }
        [[ "$body" == *"awg showconf awgprobe"* ]] || { echo "the recipe cannot reproduce the read back in $f"; return 1; }
        # The opening clause has to admit the path where everything answered and
        # the answer still does not name the generation: the key taken, the
        # padding range refused. Without this the old, untrue wording could come
        # back and no test would notice.
        if [[ "$f" == *_en.sh ]]; then
            [[ "$body" == *"does not name the generation"* ]] || { echo "the text does not admit the answered-but-unnameable path in $f"; return 1; }
        else
            [[ "$body" == *"по которому поколение назвать нельзя"* ]] || { echo "the text does not admit the answered-but-unnameable path in $f"; return 1; }
        fi
        # Control step 2 is pinned by COUNTING the key, not by a substring: the
        # main command carries the same words, so a substring check was satisfied
        # by it alone and step 2 was pinned by nothing.
        keys=$(grep -o "header-protection-key" <<< "$body" | wc -l)
        [ "$keys" -eq 2 ] || { echo "the recipe carries the key $keys times, not twice, in $f"; return 1; }
    done
}

c_cleanup_bounded() {
    # The EXIT trap runs on every exit of every run, --help included. A wedged
    # netlink is exactly the state the probe refuses over, so an unbounded ip
    # here would turn that refusal into a silent hang of the installer.
    # 🔴 The record has to be laid down, or the block under test is skipped and
    # this measures nothing. That is not hypothetical: a guard added for speed
    # made these two tests vacuous once, and they stayed green while the bound
    # they exist for was gone.
    local src="$1" start end out
    start=$(date +%s)
    out=$(timeout 60 bash -c '
        mkdir -p "$2/slowbin" "$2/tmp"
        printf "#!/usr/bin/env bash\nsleep 30\n" > "$2/slowbin/ip"
        chmod +x "$2/slowbin/ip"
        export PATH="$2/slowbin:$PATH"
        export TMPDIR="$2/tmp"
        printf "%s\n" "awgp${$}x1" > "$TMPDIR/awg31probe.$$.iface"
        log_warn() { :; }
        _install_temp_files=()
        _install_cleaned=0
        eval "$(sed -n "/^_install_cleanup() {/,/^}/p" "$1")"
        _install_cleanup
        echo done
    ' _ "$src" "$TEST_DIR")
    end=$(date +%s)
    [ "$out" = "done" ] || { echo "the cleanup did not finish ($src): $out"; return 1; }
    [ "$((end - start))" -lt 20 ] || { echo "the cleanup waited for a hanging ip ($src): $((end - start))s"; return 1; }
}
@test "cleanup: a hanging ip does not block the exit trap, both twins" {
    both c_cleanup_bounded
}

p_control_timeout() {
    # The main set refuses, control step 1 passes, control step 2 never answers.
    # A hung command is not evidence about the module: judging it "second line"
    # would send the owner of a healthy module to rebuild it, which is the very
    # advice the two-step control exists to avoid.
    make_ip add; make_awg ctlhang
    local out start end
    start=$(date +%s)
    out=$(probe "$1")
    end=$(date +%s)
    [ "$out" = "failed" ] || { echo "a hanging control step was judged ($1): $out"; return 1; }
    [ "$((end - start))" -lt 25 ] || { echo "the probe waited for a hanging control ($1)"; return 1; }
}
@test "probe: a hanging second control step is not a second-line verdict, both twins" {
    both p_control_timeout
}

p_showconf_fails() {
    # The set was taken, the read back never happened. That is not evidence
    # about the module: judging it second line would tell the owner of a healthy
    # module to rebuild it. The neighbouring case, an empty showconf with a zero
    # code, IS a verdict, and these two live one line apart in the code.
    make_ip add; make_awg showfail
    local out; out=$(probe "$1")
    [ "$out" = "failed" ] || { echo "a refused showconf was judged ($1): $out"; return 1; }
}
@test "probe: a refused read back is not a second-line verdict, both twins" {
    both p_showconf_fails
}

p_showconf_hangs() {
    make_ip add; make_awg showhang
    local out start end
    start=$(date +%s)
    out=$(probe "$1")
    end=$(date +%s)
    [ "$out" = "failed" ] || { echo "a hanging showconf was judged ($1): $out"; return 1; }
    [ "$((end - start))" -lt 25 ] || { echo "the probe waited for a hanging showconf ($1)"; return 1; }
}
@test "probe: a hanging read back is bounded and not judged, both twins" {
    both p_showconf_hangs
}

p_no_key() {
    # No key, no probe: running the set without one would test nothing and the
    # read back would compare against an empty string.
    make_ip add; make_awg nokey
    local out; out=$(probe "$1")
    [ "$out" = "failed" ] || { echo "an empty key did not stop the probe ($1): $out"; return 1; }
}
@test "probe: an empty key stops the probe instead of judging, both twins" {
    both p_no_key
}

p_main_hang_then_refuse() {
    # The main set never answers, and the control steps would then describe a
    # different command: step 1 passes, step 2 refuses, and without the timeout
    # bail that pair reads as a second-line verdict. A hang is not evidence, so
    # the answer has to stay "could not check". Without this case the bail could
    # be deleted and every test would still pass.
    make_ip add; make_awg hangrefuse
    local out start end
    start=$(date +%s)
    out=$(probe "$1")
    end=$(date +%s)
    [ "$out" = "failed" ] || { echo "a hang followed by a refusal was judged ($1): $out"; return 1; }
    [ "$((end - start))" -lt 25 ] || { echo "the probe waited for the hanging set ($1)"; return 1; }
}
@test "probe: a hanging set is not rescued into a verdict by the control steps, both twins" {
    both p_main_hang_then_refuse
}
