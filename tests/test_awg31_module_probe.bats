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
#          an interface that went away in mid probe looks like;
# addhang - creates the device and THEN hangs, which is what a delayed netlink
#          acknowledgement looks like: timeout kills the command after the
#          kernel has already made the interface;
# addmade - creates the device and then exits 2, which is the same situation
#          arriving through an exit code that is NOT one of the timeout ones:
#          a signal from outside, a failure reported after the fact.
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
            addhang) echo 'D="'"$TEST_DIR"'/ifaces"; case "$2" in show) [ -e "$D/$3" ] && exit 0 || exit 1 ;; add) mkdir -p "$D"; : > "$D/$3"; sleep 30 ;; del) rm -f "$D/$3"; exit 0 ;; esac; exit 0' ;;
            addmade) echo 'D="'"$TEST_DIR"'/ifaces"; case "$2" in show) [ -e "$D/$3" ] && exit 0 || exit 1 ;; add) mkdir -p "$D"; : > "$D/$3"; exit 2 ;; del) rm -f "$D/$3"; exit 0 ;; esac; exit 0' ;;
            fail) echo 'case "$2" in show) exit 1 ;; add) exit 2 ;; del) exit 0 ;; esac; exit 0' ;;
            busy) echo 'case "$2" in show) exit 0 ;; add) exit 2 ;; del) exit 0 ;; esac; exit 0' ;;
            hang) echo 'case "$2" in show) exit 1 ;; add) sleep 30 ;; del) exit 0 ;; esac; exit 0' ;;
            hangshow) echo 'case "$2" in show) sleep 30 ;; add) exit 0 ;; del) exit 0 ;; esac; exit 0' ;;
            delhang) echo 'D="'"$TEST_DIR"'/ifaces"; case "$2" in show) [ -e "$D/$3" ] && exit 0 || exit 1 ;; add) mkdir -p "$D"; : > "$D/$3"; exit 0 ;; del) sleep 30 ;; esac; exit 0' ;;
            addunknown) echo 'D="'"$TEST_DIR"'/ifaces"; M="'"$TEST_DIR"'/addtried"; case "$2" in show) [ -e "$M" ] && sleep 30; exit 1 ;; add) : > "$M"; exit 2 ;; del) exit 0 ;; esac; exit 0' ;;
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
# twoline - awg genkey prints a valid key and then a second line;
# crlfkey - awg genkey writes a valid key ending in CRLF: the variable can be
#          cleaned of the carriage return, the FILE handed to the module cannot;
# nonlkey - awg genkey writes a valid key with no trailing newline at all;
# blankline - awg genkey prints a valid key, a BLANK line, and then junk: the
#          shape that slipped past a guard which only looked at lines one and
#          two and called the file one line long when the second was empty;
# cpawrong - the key comes back verbatim, the padding range comes back changed;
# indented - both values come back correct but with leading whitespace;
# spaced - both parameters come back, correct, with an extra space after the
#          equals sign: the module understood everything, the parser does not
#          recognise the shape;
# bothwrong - both parameter NAMES come back carrying values that are not ours;
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
            twoline) echo '  genkey) echo "PROBE+KEY/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; echo "trailing junk" ;;' ;;
            blankline) echo '  genkey) echo "PROBE+KEY/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; echo ""; echo "trailing junk" ;;' ;;
            crlfkey)   echo '  genkey) printf "%s\r\n" "PROBE+KEY/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ;;' ;;
            nonlkey)   echo '  genkey) printf "%s" "PROBE+KEY/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ;;' ;;
            nulkey)    echo '  genkey) printf "%s\\0\\n" "PROBE+KEY/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ;;' ;;
            *)       echo '  genkey) echo "PROBE+KEY/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ;;' ;;
        esac
        echo '  set)'
        case "$mode" in
            ok|silent|empty|hpkshow|cpashow|wrongkey|keyhang|spaced|bothwrong|twoline|blankline|cpawrong|indented|crlfkey|nonlkey|nulkey)
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
            keygrow)
                # Refuses anything carrying the key AND makes the file one byte
                # longer each time, which models a key file replaced between the
                # validation and control step 2.
                echo '    if [[ "$*" == *header-protection-key* ]]; then'
                echo '      for a in "$@"; do [[ -f "$a" && "$a" == *awg31probe* ]] && printf "X" >> "$a"; done'
                echo '      exit 1'
                echo '    fi'
                echo '    exit 0 ;;' ;;
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
            ok|twoline|blankline|crlfkey|nonlkey|nulkey|keygrow)
                echo '    echo "[Interface]"; echo "ListenPort = 51820"'
                echo '    echo "HeaderProtectionKey = PROBE+KEY/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="'
                echo '    echo "ContentPaddingAddition = 32-128"; exit 0 ;;' ;;
            silent)
                echo '    echo "[Interface]"; echo "ListenPort = 51820"; exit 0 ;;' ;;
            hpkshow)
                echo '    echo "[Interface]"; echo "HeaderProtectionKey = PROBE+KEY/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; exit 0 ;;' ;;
            cpashow)
                echo '    echo "[Interface]"; echo "ContentPaddingAddition = 32-128"; exit 0 ;;' ;;
            spaced)
                echo '    echo "[Interface]"; echo "HeaderProtectionKey =  PROBE+KEY/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="'
                echo '    echo "ContentPaddingAddition =  32-128"; exit 0 ;;' ;;
            bothwrong)
                echo '    echo "[Interface]"; echo "HeaderProtectionKey = OTHER+KEY/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA="'
                echo '    echo "ContentPaddingAddition = 64-256"; exit 0 ;;' ;;
            cpawrong)
                echo '    echo "[Interface]"; echo "HeaderProtectionKey = PROBE+KEY/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="'
                echo '    echo "ContentPaddingAddition = 32-127"; exit 0 ;;' ;;
            indented)
                echo '    echo "[Interface]"; printf "\t%s\n" "HeaderProtectionKey = PROBE+KEY/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="'
                echo '    printf "  %s  \n" "ContentPaddingAddition = 32-128"; exit 0 ;;' ;;
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
# 🔴 The module took everything and gave everything back, only in a shape the
# parser does not match. Reading a second line out of that would tell its owner
# to rebuild a healthy kernel module and reboot. The output shape rests on a
# single bench measurement, so a drift in it has to end as "could not check".
p_spaced_back() {
    make_ip add; make_awg spaced
    local out; out=$(probe "$1")
    [ "$out" = "failed" ] || { echo "an answer in an unrecognised shape was judged ($1): $out"; return 1; }
}
@test "probe: both values back in a shape we do not recognise names no generation, both twins" {
    both p_spaced_back
}

# Both names present, neither value ours. Not silence, and not a generation we
# can name either.
p_both_wrong_back() {
    make_ip add; make_awg bothwrong
    local out; out=$(probe "$1")
    [ "$out" = "failed" ] || { echo "two values that are not ours were judged ($1): $out"; return 1; }
}
@test "probe: both names back with values that are not ours names no generation, both twins" {
    both p_both_wrong_back
}

# 🔴 The mirror of p_wrong_key_back, and the one that matters more. A mutant
# matching ContentPaddingAddition by NAME alone survived the whole suite: with
# the key echoed verbatim and the range changed, the verdict became `ok` and the
# installer would write a 3.1 profile against a module whose padding behaviour
# was never confirmed. That is the one direction where a wrong verdict is not
# "rebuild for nothing" but "the profile builds and the tunnel never comes up".
p_cpa_wrong_back() {
    make_ip add; make_awg cpawrong
    local out; out=$(probe "$1")
    [ "$out" = "failed" ] || { echo "a padding range we never asked for was accepted as ours ($1): $out"; return 1; }
}
@test "probe: a padding range that is not the one we set is not a third-line verdict, both twins" {
    both p_cpa_wrong_back
}

# The trimming in the parser had no case at all: every stub emitted flush-left
# lines, so it could be deleted with the suite green.
p_indented_back() {
    make_ip add; make_awg indented
    local out; out=$(probe "$1")
    [ "$out" = "ok" ] || { echo "an indented but correct answer was not recognised ($1): $out"; return 1; }
}
@test "probe: leading and trailing whitespace in the answer does not hide it, both twins" {
    both p_indented_back
}

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
    # 🔴 The pattern must be a substring of the key the stub actually prints.
    # It used to read PROBEKEYAAAA while the stub printed PROBE+KEY/AAAA, so it
    # matched nothing this suite can produce and the assertion could never fail:
    # a mutant that passed the key inline in argv kept the whole file green.
    # The promise it guards is published in both changelogs.
    grep -qF 'PROBE+KEY/' "$TEST_DIR/awg.argv" && { echo "the key went into argv ($1)"; return 1; }
    grep -q "header-protection-key" "$TEST_DIR/awg.argv" || { echo "the key was never set ($1)"; return 1; }
    return 0
}
@test "probe: the key reaches the module as a file, never in argv, both twins" {
    both p_key_not_in_argv
}

p_key_not_in_xtrace() {
    # 🔴 This is not hygiene for its own sake. `--verbose` turns xtrace on for
    # the whole installer (`if [[ "$VERBOSE" -eq 1 ]]; then set -x; fi`), and
    # the text printed when the probe fails TELLS the user to re-run with
    # `--verbose` and bring the log. That is the exact path along which a log
    # carrying the key reaches a public issue. The probe suppresses the trace
    # for its own body; nothing held that in place until this case.
    # Measured with the suppression replaced by a no-op: the key appears in the
    # trace seven times, and the whole suite stays green.
    local src="$1" out trace="$TEST_DIR/xtrace.log"
    make_ip add; make_awg ok
    out=$(PATH="$BIN:$PATH" TMPDIR="$TEST_DIR" timeout 60 bash -c '
        eval "$(sed -n "/^_awg31_module_probe() (/,/^)$/p" "$1")"
        set -x
        _awg31_module_probe
    ' _ "$src" 2>"$trace")
    [ "$out" = "ok" ] || { echo "the probe under set -x did not reach its verdict ($src): $out"; return 1; }
    # Without this the case would pass on an empty file, which is how a test
    # that greps for an absence quietly stops testing anything.
    [ -s "$trace" ] || { echo "set -x produced no trace at all, so this case proves nothing ($src)"; return 1; }
    grep -qF 'PROBE+KEY/' "$trace" && { echo "the probe key is in the xtrace output ($src)"; return 1; }
    return 0
}
# Nothing is asserted here about xtrace being restored afterwards: the probe
# body is a subshell, so its `set +x` cannot escape it in the first place. An
# assertion about that would hold with the guard and without it.
@test "probe: the key stays out of the trace under set -x, both twins" {
    both p_key_not_in_xtrace
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

# Comments are stripped, and so is the TEXT of the diagnostic messages, because
# those are translated on purpose. Everything else stays byte for byte: the
# normalisation touches only the quoted argument of _probe_say, _probe_warn and
# log_debug, and
# a single-quoted literal on a line that also redirects to stderr. The verdict
# lines (printf 'failed', printf 'line2') carry no such marker and are compared
# as they are, which is the point - they are behaviour, not wording.
strip_twin() {
    sed -n "/^$2/,/^$3/p" "$1" \
        | grep -vE '^\s*#' \
        | sed -E 's/_probe_say "[^"]*"/_probe_say "<msg>"/g; s/_probe_warn "[^"]*"/_probe_warn "<msg>"/g; s/log_debug "[^"]*"/log_debug "<msg>"/g' \
        | sed -E '/>&2/ s/'"'"'[^'"'"']*'"'"'/<msg>/g' \
        | tr -d '\r'
}

@test "probe: the body is identical in RU and EN except the comments and the translations" {
    local ru en
    ru=$(strip_twin "$INSTALL_RU" '_awg31_module_probe() (' ')$')
    en=$(strip_twin "$INSTALL_EN" '_awg31_module_probe() (' ')$')
    [ -n "$ru" ] || { echo "no probe body found"; return 1; }
    [ "$ru" = "$en" ] || { echo "the probe bodies differ:"; diff <(printf '%s\n' "$ru") <(printf '%s\n' "$en") || true; return 1; }
    # 🔴 The normalisation collapses any single-quoted literal on a line that
    # also redirects to stderr. Today that is one diagnostic line and no verdict
    # line, but a future `printf 'failed'` sharing a line with >&2 would be
    # collapsed too, and this comparison would quietly stop seeing verdicts.
    local nru nen
    nru=$(grep -cE "printf '(failed|line2|ok)'" <<< "$ru")
    nen=$(grep -cE "printf '(failed|line2|ok)'" <<< "$en")
    [ "$nru" -gt 0 ] || { echo "the normalisation swallowed the verdicts"; return 1; }
    [ "$nru" = "$nen" ] || { echo "the twins carry a different number of verdicts: $nru vs $nen"; return 1; }
}

@test "cleanup: the installer cleanup is identical in RU and EN except the comments and the translations" {
    # The probe had this guard from the start; the cleanup did not, and the
    # cleanup is where the two twins drifted in practice.
    local ru en
    ru=$(strip_twin "$INSTALL_RU" '_install_cleanup() {' '}$')
    en=$(strip_twin "$INSTALL_EN" '_install_cleanup() {' '}$')
    [ -n "$ru" ] || { echo "no cleanup body found"; return 1; }
    [ "$ru" = "$en" ] || { echo "the cleanup bodies differ:"; diff <(printf '%s\n' "$ru") <(printf '%s\n' "$en") || true; return 1; }
}

@test "the English installer carries no Russian comment" {
    # 🔴 An untranslated Russian comment block did reach the English twin once,
    # carried there by a helper that applied one text to both files. The body
    # comparison above cannot see it, because it strips comments before
    # comparing - which is exactly the blind spot this test fills.
    # 🔴 LC_ALL=C.UTF-8 is not decoration. LC_ALL and LANG are empty in Git Bash,
    # so `grep -P` runs in the C locale, where the codepoint syntax \x{...} does
    # not work at all: the command finds nothing and the check passes on any
    # input. Measured: without the locale this very test stayed green against a
    # planted Russian comment. The project has this recorded and I walked into
    # it anyway, which is why the locale is spelled out here rather than assumed.
    local bad
    bad=$(grep -nE '^[[:space:]]*#' "$INSTALL_EN" | LC_ALL=C.UTF-8 grep -P '[\x{0400}-\x{04FF}]' || true)
    [ -z "$bad" ] || { echo "Russian comments in the English installer:"; printf '%s\n' "$bad"; return 1; }
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
    # End to end, in ONE shell, through the shape the installer really uses: the
    # probe runs inside $( ), and the cleanup afterwards has to find what it left
    # and actually delete it.
    # 🔴 Counting "a file matching awg31probe.*.iface exists" is not enough, and
    # that is measured, not supposed: a mutant naming the record by $BASHPID
    # instead of $$, and a mutant writing the record EMPTY, both kept every test
    # green. The pid in the name and the name inside the file are exactly what
    # makes the sweep able to act, so both are asserted here by running the
    # consumer rather than by looking at the directory.
    local src="$1" out added after
    make_ip delfail; make_awg ok
    out=$(PATH="$BIN:$PATH" TMPDIR="$TEST_DIR" timeout 90 bash -c '
        eval "$(sed -n "/^_probe_warn() {/,/^}/p" "$1")"
        eval "$(sed -n "/^_awg31_module_probe() (/,/^)$/p" "$1")"
        eval "$(sed -n "/^_install_cleanup() {/,/^}/p" "$1")"
        log_warn() { echo "WARNED $*"; }
        _install_temp_files=()
        _install_cleaned=0
        _verdict=$(_awg31_module_probe)
        echo "MARKER" >> "$2/ip.argv"
        _install_cleanup
    ' _ "$src" "$TEST_DIR")
    added=$(grep -m1 "^link add " "$TEST_DIR/ip.argv" | awk "{print \$3}")
    [ -n "$added" ] || { echo "the probe created no interface ($src)"; return 1; }
    after=$(sed -n "/^MARKER$/,\$p" "$TEST_DIR/ip.argv")
    [[ "$after" == *"link del $added"* ]] || { echo "the cleanup did not delete what the probe created ($src): [$after]"; return 1; }
    [[ "$out" == *WARNED* ]] || { echo "a leftover that could not be removed was not named ($src): [$out]"; return 1; }

    # And on the ordinary path, where the probe removes its own interface, the
    # cleanup must find no record and touch nothing.
    rm -f "$TEST_DIR"/awg31probe.*
    make_ip add; make_awg ok
    out=$(PATH="$BIN:$PATH" TMPDIR="$TEST_DIR" timeout 90 bash -c '
        eval "$(sed -n "/^_probe_warn() {/,/^}/p" "$1")"
        eval "$(sed -n "/^_awg31_module_probe() (/,/^)$/p" "$1")"
        eval "$(sed -n "/^_install_cleanup() {/,/^}/p" "$1")"
        log_warn() { echo "WARNED $*"; }
        _install_temp_files=()
        _install_cleaned=0
        _verdict=$(_awg31_module_probe)
        echo "MARKER" >> "$2/ip.argv"
        _install_cleanup
    ' _ "$src" "$TEST_DIR")
    after=$(sed -n "/^MARKER$/,\$p" "$TEST_DIR/ip.argv")
    [[ "$after" != *"link del"* ]] || { echo "the cleanup chased an interface the probe had already removed ($src): [$after]"; return 1; }
    [[ "$out" != *WARNED* ]] || { echo "the cleanup warned with nothing to warn about ($src): [$out]"; return 1; }
}
c_cleanup_foreign_name() {
    # 🔴 This block runs as root on EVERY exit of the installer, and the record
    # path is predictable in a world-writable directory. A planted name like
    # eth0 must not reach `ip link del`, and the refusal must be audible: "there
    # is a record I did not understand" is not the same as "there was no probe".
    local src="$1" out
    out=$(timeout 60 bash -c '
        mkdir -p "$2/bin" "$2/tmp"
        printf "#!/usr/bin/env bash\necho \"\$*\" >> \"$2/called\"\nexit 0\n" > "$2/bin/ip"
        chmod +x "$2/bin/ip"
        export PATH="$2/bin:$PATH"
        export TMPDIR="$2/tmp"
        rm -f "$2/called" "$TMPDIR"/awg31probe.*
        printf "%s\n" "eth0" > "$TMPDIR/awg31probe.$$.iface"
        log_warn() { echo "WARNED $*"; }
        _install_temp_files=()
        _install_cleaned=0
        eval "$(sed -n "/^_probe_warn() {/,/^}/p" "$1")"
        eval "$(sed -n "/^_install_cleanup() {/,/^}/p" "$1")"
        _install_cleanup
        cat "$2/called" 2>/dev/null
    ' _ "$src" "$TEST_DIR")
    [[ "$out" != *"link del eth0"* ]] || { echo "a planted name reached ip link del ($src): [$out]"; return 1; }
    [[ "$out" == *WARNED* ]] || { echo "a record that made no sense was passed over in silence ($src): [$out]"; return 1; }

    # 🔴 And the half that actually carries the weight: a name of exactly the
    # right SHAPE but from another pid. `eth0` is refused by any shape check, so
    # it never tested the pid binding - a mutant dropping `$$` from the pattern
    # survived the whole suite. This is what makes a planted record harmless.
    out=$(timeout 60 bash -c '
        mkdir -p "$2/bin" "$2/tmp"
        printf "#!/usr/bin/env bash\necho \"\$*\" >> \"$2/called\"\nexit 0\n" > "$2/bin/ip"
        chmod +x "$2/bin/ip"
        export PATH="$2/bin:$PATH"
        export TMPDIR="$2/tmp"
        rm -f "$2/called"; rm -f "$TMPDIR"/awg31probe.*
        printf "%s\n" "awgp999999x1" > "$TMPDIR/awg31probe.$$.iface"
        log_warn() { echo "WARNED $*"; }
        _install_temp_files=()
        _install_cleaned=0
        eval "$(sed -n "/^_probe_warn() {/,/^}/p" "$1")"
        eval "$(sed -n "/^_install_cleanup() {/,/^}/p" "$1")"
        _install_cleanup
        cat "$2/called" 2>/dev/null
    ' _ "$src" "$TEST_DIR")
    [[ "$out" != *"link del"* ]] || { echo "a well shaped name from another run reached ip link del ($src): [$out]"; return 1; }
    [[ "$out" == *WARNED* ]] || { echo "a record from another run was passed over in silence ($src): [$out]"; return 1; }
}
@test "cleanup: a record naming something the probe could not have made is refused out loud, both twins" {
    both c_cleanup_foreign_name
}

c_cleanup_not_a_file() {
    # 🔴 A FIFO, not a directory. The first version of this test used a
    # directory, and a mutant that dropped the guard entirely SURVIVED it: a
    # directory yields an empty read either way, so the test could not tell the
    # guarded code from the unguarded one.
    #
    # ⚠️ Be honest about what is measured NOW: since the read was put under
    # `timeout -k 1 5 head`, this case no longer separates the guard from its
    # absence either. Without the guard the read no longer hangs, it stalls for
    # five seconds and comes back empty, the cleanup takes the "empty or
    # unreadable" branch, and all three assertions below still hold. Measured:
    # replacing `-f && ! -L` with `-e` keeps the whole suite green. What this
    # case still holds down is the OUTCOME - the cleanup finishes, deletes
    # nothing and does not keep quiet - and the two guards together, since
    # removing both does hang. Telling them apart needs a writer feeding the
    # FIFO a well formed name and an assertion that nothing was deleted.
    command -v mkfifo >/dev/null 2>&1 || skip "mkfifo not available"
    local src="$1" out
    out=$(timeout 60 bash -c '
        mkdir -p "$2/bin" "$2/tmp"
        printf "#!/usr/bin/env bash\necho \"\$*\" >> \"$2/called\"\nexit 0\n" > "$2/bin/ip"
        chmod +x "$2/bin/ip"
        export PATH="$2/bin:$PATH"
        export TMPDIR="$2/tmp"
        rm -f "$2/called"; rm -rf "$TMPDIR"/awg31probe.*
        mkfifo "$TMPDIR/awg31probe.$$.iface"
        log_warn() { echo "WARNED $*"; }
        _install_temp_files=()
        _install_cleaned=0
        eval "$(sed -n "/^_probe_warn() {/,/^}/p" "$1")"
        eval "$(sed -n "/^_install_cleanup() {/,/^}/p" "$1")"
        _install_cleanup
        echo "finished"
        cat "$2/called" 2>/dev/null
    ' _ "$src" "$TEST_DIR")
    [[ "$out" == *finished* ]] || { echo "the cleanup hung or died on a record that is not a regular file ($src): [$out]"; return 1; }
    [[ "$out" != *"link del"* ]] || { echo "something was deleted from a record that is not a regular file ($src): [$out]"; return 1; }
    [[ "$out" == *WARNED* ]] || { echo "a record that could not be read was passed over in silence ($src): [$out]"; return 1; }
}
@test "cleanup: a record that is not a regular file is ignored, both twins" {
    both c_cleanup_not_a_file
}

c_cleanup_dangling_symlink() {
    # 🔴 A dangling symlink fails BOTH the regular-file test and the existence
    # test, so the branch that reports an unusable record used to stay quiet and
    # the sweep removed it without a word. That gap was opened by the previous
    # round's own fix, which narrowed an unconditional else into `elif -e`.
    # Skipped where the shell cannot make one: Git Bash refuses `ln -s` to a
    # missing target, and pretending otherwise would be a test that measures
    # nothing. It runs on Linux, which is where the installer runs.
    local src="$1" out
    ( cd "$TEST_DIR" && ln -s /nonexistent/target .lntest ) 2>/dev/null \
        || skip "this shell cannot create a symlink to a missing target"
    rm -f "$TEST_DIR/.lntest"
    out=$(timeout 60 bash -c '
        mkdir -p "$2/bin" "$2/tmp"
        printf "#!/usr/bin/env bash\nexit 0\n" > "$2/bin/ip"
        chmod +x "$2/bin/ip"
        export PATH="$2/bin:$PATH"
        export TMPDIR="$2/tmp"
        rm -f "$TMPDIR"/awg31probe.*
        ln -s /nonexistent/target "$TMPDIR/awg31probe.$$.iface"
        log_warn() { echo "WARNED $*"; }
        _install_temp_files=()
        _install_cleaned=0
        eval "$(sed -n "/^_probe_warn() {/,/^}/p" "$1")"
        eval "$(sed -n "/^_install_cleanup() {/,/^}/p" "$1")"
        _install_cleanup
        echo finished
    ' _ "$src" "$TEST_DIR")
    [[ "$out" == *finished* ]] || { echo "the cleanup did not finish on a dangling symlink ($src): [$out]"; return 1; }
    [[ "$out" == *WARNED* ]] || { echo "a dangling symlink record was passed over in silence ($src): [$out]"; return 1; }
}
@test "cleanup: a dangling symlink in place of the record is said out loud, both twins" {
    both c_cleanup_dangling_symlink
}

c_cleanup_show_unknown() {
    # 🔴 `del` failed and `show` could not answer. Only exit code 1 means "no
    # such device"; a timeout is "do not know", and the interface may well still
    # be there. Measured before the fix: total silence, and the record erased.
    local src="$1" out
    out=$(timeout 90 bash -c '
        mkdir -p "$2/bin" "$2/tmp"
        printf "#!/usr/bin/env bash\ncase \"\$2\" in show) sleep 30 ;; *) exit 1 ;; esac\n" > "$2/bin/ip"
        chmod +x "$2/bin/ip"
        export PATH="$2/bin:$PATH"
        export TMPDIR="$2/tmp"
        rm -f "$TMPDIR"/awg31probe.*
        printf "%s\n" "awgp${$}x1" > "$TMPDIR/awg31probe.$$.iface"
        log_warn() { echo "WARNED $*"; }
        _install_temp_files=()
        _install_cleaned=0
        eval "$(sed -n "/^_probe_warn() {/,/^}/p" "$1")"
        eval "$(sed -n "/^_install_cleanup() {/,/^}/p" "$1")"
        _install_cleanup
        echo finished
    ' _ "$src" "$TEST_DIR")
    [[ "$out" == *finished* ]] || { echo "the cleanup did not finish ($src): [$out]"; return 1; }
    [[ "$out" == *WARNED* ]] || { echo "a device check that could not answer was taken for gone ($src): [$out]"; return 1; }
}
@test "cleanup: a device check that cannot answer is not taken for gone, both twins" {
    both c_cleanup_show_unknown
}

c_cleanup_keeps_evidence() {
    # 🔴 The message tells the operator to go and look at the record. Deleting
    # it two lines later made that advice impossible to follow, which is what
    # the sweep used to do.
    local src="$1" out
    out=$(timeout 60 bash -c '
        mkdir -p "$2/bin" "$2/tmp"
        printf "#!/usr/bin/env bash\nexit 0\n" > "$2/bin/ip"
        chmod +x "$2/bin/ip"
        export PATH="$2/bin:$PATH"
        export TMPDIR="$2/tmp"
        rm -f "$TMPDIR"/awg31probe.*
        printf "%s\n" "eth0" > "$TMPDIR/awg31probe.$$.iface"
        : > "$TMPDIR/awg31probe.$$.keyfile"
        log_warn() { echo "WARNED $*"; }
        _install_temp_files=()
        _install_cleaned=0
        eval "$(sed -n "/^_probe_warn() {/,/^}/p" "$1")"
        eval "$(sed -n "/^_install_cleanup() {/,/^}/p" "$1")"
        _install_cleanup
        ls "$TMPDIR"
    ' _ "$src" "$TEST_DIR")
    [[ "$out" == *WARNED* ]] || { echo "an unusable record was passed over in silence ($src): [$out]"; return 1; }
    [[ "$out" == *".iface"* ]] || { echo "the record the message points at was destroyed ($src): [$out]"; return 1; }
    [[ "$out" != *".keyfile"* ]] || { echo "the other probe files were not swept ($src): [$out]"; return 1; }
}
@test "cleanup: a record it could not understand is kept for the operator, both twins" {
    both c_cleanup_keeps_evidence
}

c_cleanup_empty_record() {
    # An empty record is a state nobody can act on, and it used to pass in
    # total silence.
    local src="$1" out
    out=$(timeout 60 bash -c '
        mkdir -p "$2/bin" "$2/tmp"
        printf "#!/usr/bin/env bash\nexit 0\n" > "$2/bin/ip"
        chmod +x "$2/bin/ip"
        export PATH="$2/bin:$PATH"
        export TMPDIR="$2/tmp"
        rm -f "$TMPDIR"/awg31probe.*
        : > "$TMPDIR/awg31probe.$$.iface"
        log_warn() { echo "WARNED $*"; }
        _install_temp_files=()
        _install_cleaned=0
        eval "$(sed -n "/^_probe_warn() {/,/^}/p" "$1")"
        eval "$(sed -n "/^_install_cleanup() {/,/^}/p" "$1")"
        _install_cleanup
    ' _ "$src" "$TEST_DIR")
    [[ "$out" == *WARNED* ]] || { echo "an empty record was passed over in silence ($src): [$out]"; return 1; }
}
@test "cleanup: an empty record is said out loud, both twins" {
    both c_cleanup_empty_record
}

c_cleanup_sanitises() {
    # The record comes from a world writable directory, so its contents must not
    # be able to drive a root terminal.
    local src="$1" out
    out=$(timeout 60 bash -c '
        mkdir -p "$2/bin" "$2/tmp"
        printf "#!/usr/bin/env bash\nexit 0\n" > "$2/bin/ip"
        chmod +x "$2/bin/ip"
        export PATH="$2/bin:$PATH"
        export TMPDIR="$2/tmp"
        rm -f "$TMPDIR"/awg31probe.*
        printf "eth0\033[31mRED\n" > "$TMPDIR/awg31probe.$$.iface"
        log_warn() { echo "WARNED $*"; }
        _install_temp_files=()
        _install_cleaned=0
        eval "$(sed -n "/^_probe_warn() {/,/^}/p" "$1")"
        eval "$(sed -n "/^_install_cleanup() {/,/^}/p" "$1")"
        _install_cleanup
    ' _ "$src" "$TEST_DIR" | cat -v)
    [[ "$out" == *WARNED* ]] || { echo "a planted record was passed over in silence ($src): [$out]"; return 1; }
    [[ "$out" != *"^["* ]] || { echo "an escape sequence from the record reached the output ($src): [$out]"; return 1; }
}
@test "cleanup: control bytes in a record never reach the output, both twins" {
    both c_cleanup_sanitises
}

p_add_bounded_out_keeps_the_record() {
    # 🔴 timeout can kill `ip link add` AFTER the kernel has created the device.
    # Measured on a stub before the fix: the probe erased the record, walked to
    # the next name, and left FIVE root-created interfaces on the machine with
    # nothing naming any of them and not a word printed. The record has to stay
    # and the walk has to stop.
    local src="$1" out adds
    make_ip addhang; make_awg ok
    rm -f "$TEST_DIR"/awg31probe.*
    out=$(probe "$src")
    [ "$out" = "failed" ] || { echo "a bounded-out creation was judged ($src): $out"; return 1; }
    adds=$(grep -c "^link add " "$TEST_DIR/ip.argv" 2>/dev/null || echo 0)
    [ "$adds" -eq 1 ] || { echo "the probe kept creating interfaces after a bounded-out add ($src): $adds"; return 1; }
    ls "$TEST_DIR"/awg31probe.*.iface >/dev/null 2>&1 || { echo "the record was erased after a bounded-out add ($src)"; return 1; }
}
@test "probe: a bounded-out creation keeps its record and stops, both twins" {
    both p_add_bounded_out_keeps_the_record
}

p_add_made_but_failed_keeps_the_record() {
    # 🔴 The same situation arriving through an exit code that is not a timeout
    # one. The first fix here special-cased 124/125/137 and let every other
    # abnormal exit erase the record and walk to the next name - and then the
    # `ip link show` that followed found OUR OWN device and read it as "the name
    # is taken by someone else". Measured before the fix: five interfaces on the
    # machine, no record naming any of them, not a word. What decides now is
    # whether the device is there, which does not depend on how the command
    # ended.
    local src="$1" out adds
    make_ip addmade; make_awg ok
    rm -f "$TEST_DIR"/awg31probe.*
    out=$(probe "$src")
    [ "$out" = "failed" ] || { echo "a creation that failed after making the device was judged ($src): $out"; return 1; }
    adds=$(grep -c "^link add " "$TEST_DIR/ip.argv" 2>/dev/null || echo 0)
    [ "$adds" -eq 1 ] || { echo "the probe walked on to another name after making a device ($src): $adds"; return 1; }
    ls "$TEST_DIR"/awg31probe.*.iface >/dev/null 2>&1 || { echo "the record was erased although the device exists ($src)"; return 1; }
}
p_add_device_check_cannot_answer() {
    # 🔴 The THIRD arm of the device check, and it arrived without a case of its
    # own: the fix that made the DEVICE decide instead of the exit code says, in
    # its own message, "the device is there OR could not be checked". The first
    # half had two cases, the second had none, and a mutant narrowing
    # `(( arc != 1 ))` to `(( arc == 0 ))` survived the whole suite. Under that
    # mutant a device check that cannot answer erases the record and refuses -
    # the exact silent loss the record file exists to prevent.
    #
    # The stub answers the availability check normally, then stops answering
    # once a creation has been attempted: that is what a netlink socket which
    # stops responding looks like from here.
    local src="$1" out adds started elapsed
    make_ip addunknown; make_awg ok
    rm -f "$TEST_DIR"/awg31probe.* "$TEST_DIR/addtried"
    started=$SECONDS
    out=$(probe "$src")
    elapsed=$((SECONDS - started))
    [ "$out" = "failed" ] || { echo "a device check that cannot answer was judged ($src): $out"; return 1; }
    [ "$elapsed" -lt 25 ] || { echo "the device check after a failed creation is not bounded ($src): ${elapsed}s"; return 1; }
    adds=$(grep -c "^link add " "$TEST_DIR/ip.argv" 2>/dev/null || echo 0)
    [ "$adds" -eq 1 ] || { echo "the probe walked on to another name while the device was unknown ($src): $adds"; return 1; }
    ls "$TEST_DIR"/awg31probe.*.iface >/dev/null 2>&1 || { echo "the record was erased although the device could not be checked ($src)"; return 1; }
}
@test "probe: a device check that cannot answer keeps the record, both twins" {
    both p_add_device_check_cannot_answer
}

@test "probe: a creation that failed after making the device keeps its record, both twins" {
    both p_add_made_but_failed_keeps_the_record
}

p_says_why() {
    # The probe can refuse for a good many reasons and used to name none of
    # them. No number here on purpose: three copies of that count have already
    # gone stale in this branch alone.
    # stdout carries the verdict, so the explanation goes to stderr.
    # 🔴 BOTH branches of the helper are exercised. With no logger it falls back
    # to stderr; with one it must go through it, and that branch had no coverage
    # at all - a mutant gutting it survived every test.
    local src="$1" err viaLog
    make_ip fail; make_awg ok
    err=$(PATH="$BIN:$PATH" TMPDIR="$TEST_DIR" timeout 60 bash -c '
        eval "$(sed -n "/^_awg31_module_probe() (/,/^)$/p" "$1")"
        _awg31_module_probe >/dev/null
    ' _ "$src" 2>&1)
    [ -n "$err" ] || { echo "the probe refused without saying why ($src)"; return 1; }

    viaLog=$(PATH="$BIN:$PATH" TMPDIR="$TEST_DIR" timeout 60 bash -c '
        # To stderr, like the real log_debug: the probe stdout is the verdict
        # and is redirected away, so a stub echoing to stdout would measure
        # nothing at all.
        log_debug() { echo "LOGGED $*" >&2; }
        eval "$(sed -n "/^_awg31_module_probe() (/,/^)$/p" "$1")"
        _awg31_module_probe >/dev/null
    ' _ "$src" 2>&1)
    [[ "$viaLog" == *LOGGED* ]] || { echo "the explanation did not go through the logger when there was one ($src): [$viaLog]"; return 1; }
}
@test "probe: a refusal says on stderr what stopped it, both twins" {
    both p_says_why
}

p_key_two_lines() {
    # `read` takes only the first line while the module is handed the whole
    # file, so a valid first line with junk behind it used to pass the shape
    # check and the refusal that followed was read as a second-line module.
    # 🔴 The stub answers showconf the way the `ok` stub does, ON PURPOSE.
    # Without that it refused the read back, the verdict was `failed` whether the
    # guard was there or not, and this test passed while measuring nothing -
    # caught by the mutation run, not by reading it.
    local src="$1" out
    make_ip add; make_awg twoline
    out=$(probe "$src")
    [ "$out" = "failed" ] || { echo "a key file of two lines was accepted ($src): $out"; return 1; }
}
@test "probe: a key file longer than one line stops the probe, both twins" {
    both p_key_two_lines
}

p_key_blank_second_line() {
    # 🔴 The guard used to read lines one and two and call the file one line
    # long when the second was empty. Measured on the real function: a key, a
    # blank line and junk passed, the module was handed the whole file, the tool
    # refused it, and control step 2 turned that into `line2` - a healthy
    # third-line module told to rebuild and reboot, which is the single thing
    # this slice exists to prevent.
    make_ip add; make_awg blankline
    local out; out=$(probe "$1")
    [ "$out" = "failed" ] || { echo "a key file with a blank second line was accepted ($1): $out"; return 1; }
}
@test "probe: a key file with a blank line and junk stops the probe, both twins" {
    both p_key_blank_second_line
}

p_key_crlf() {
    # 🔴 The third visit to this one place, and the root was the same each time:
    # the check looked at what had been READ AND TIDIED while the module is
    # handed the file AS IT IS. Stripping the carriage return from the variable
    # let a CRLF file through, the tool refused it, and control step 2 turned
    # that into a second-line verdict for a healthy module.
    make_ip add; make_awg crlfkey
    local out; out=$(probe "$1")
    [ "$out" = "failed" ] || { echo "a key file with CRLF was accepted ($1): $out"; return 1; }
}
@test "probe: a key file ending in CRLF stops the probe, both twins" {
    both p_key_crlf
}

p_key_no_newline() {
    # The library demands exactly 45 bytes, that is the key and one newline. A
    # file one byte short is not what it validates, so it is not what we accept.
    make_ip add; make_awg nonlkey
    local out; out=$(probe "$1")
    [ "$out" = "failed" ] || { echo "a key file with no trailing newline was accepted ($1): $out"; return 1; }
}
p_key_nul_byte() {
    # 🔴 The fourth visit to this one place, and the one that showed the other
    # three were reaching for the wrong dimension. The three guards here cited
    # the library's rule - exactly 45 bytes - and never counted a byte: they
    # rebuilt the expected string out of data bash had already normalised and
    # compared it with itself. `mapfile` and `read -N` both DROP a NUL, so a
    # 46-byte file shaped `<44 base64><NUL><LF>` satisfied all three: one line,
    # the file equal to that line plus a newline, the right shape.
    #
    # The cost is the expensive verdict, not a safe refusal. The tool is handed
    # the file AS IT IS, refuses it over its size, control step 1 carries no key
    # and passes, and the refusal at control step 2 reads as "the module does
    # not understand the key" - a healthy third-line module told to rebuild
    # itself and reboot. Measured before the fix: both twins answered `line2`
    # against stubs modelling a healthy module.
    local src="$1" out
    make_ip add; make_awg nulkey
    out=$(probe "$src")
    [ "$out" = "failed" ] || { echo "a key file padded with a NUL was judged ($src): $out"; return 1; }
}
@test "probe: a key file padded with a NUL byte stops the probe, both twins" {
    both p_key_nul_byte
}

@test "probe: a key file with no trailing newline stops the probe, both twins" {
    both p_key_no_newline
}

c_probe_explains_every_bail() {
    # 🔴 The refusal text tells the operator to re-run with --verbose and says
    # the probe will name what stopped it. That promise was made while only four
    # of the bail points said anything at all: a person would have followed
    # the advice, seen nothing, and concluded the option was broken. Structural
    # on purpose - driving every one of them from a test is not within reach,
    # and the invariant is what matters: no silent exit ON ANY PATH THE PROBE
    # CHOOSES ITSELF.
    # ⚠️ Said exactly, because the scan cannot see further than that: it matches
    # `printf 'failed'` in SINGLE quotes, and the signal trap bails with
    # `printf "failed"` in double quotes and says nothing. That silence is
    # deliberate - a handler that runs on a signal should not try to reach a
    # logger - but it is outside what this case measures, and the invariant has
    # to be stated with that boundary rather than as a blanket claim.
    local f body line prev bad
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        body=$(sed -n '/^_awg31_module_probe() (/,/^)$/p' "$BATS_TEST_DIRNAME/../$f")
        [ -n "$body" ] || { echo "no probe body in $f"; return 1; }
        prev=""
        bad=0
        while IFS= read -r line; do
            case "$line" in
                *"printf 'failed'"*)
                    case "$line$prev" in
                        *_probe_say*) : ;;
                        *) echo "a silent refusal in $f: $line"; bad=1 ;;
                    esac
                    ;;
            esac
            prev="$line"
        done <<< "$body"
        [ "$bad" -eq 0 ] || return 1
    done
    return 0
}
@test "probe: every refusal says what stopped it, both twins" {
    c_probe_explains_every_bail
}

c_cleanup_key_file_without_record() {
    # 🔴 A key file with no record at all is not "a record that cannot be read".
    # The branch written to report an unreadable record fired on a MISSING one
    # too: the operator was told to inspect a record that does not exist, and
    # the sweep removed the one file that did. Nothing to keep, nothing to say.
    local src="$1" out
    out=$(timeout 60 bash -c '
        mkdir -p "$2/bin" "$2/tmp"
        printf "#!/usr/bin/env bash\necho \"\$*\" >> \"$2/called\"\nexit 0\n" > "$2/bin/ip"
        chmod +x "$2/bin/ip"
        export PATH="$2/bin:$PATH"
        export TMPDIR="$2/tmp"
        rm -f "$2/called"; rm -f "$TMPDIR"/awg31probe.*
        : > "$TMPDIR/awg31probe.$$.keyonly"
        log_warn() { echo "WARNED $*"; }
        _install_temp_files=()
        _install_cleaned=0
        eval "$(sed -n "/^_probe_warn() {/,/^}/p" "$1")"
        eval "$(sed -n "/^_install_cleanup() {/,/^}/p" "$1")"
        _install_cleanup
        echo "left: $(ls "$TMPDIR" 2>/dev/null | tr "\n" " ")"
    ' _ "$src" "$TEST_DIR")
    [[ "$out" != *WARNED* ]] || { echo "a missing record was reported as unreadable ($src): [$out]"; return 1; }
    [[ "$out" == *"left: "* ]] || { echo "the cleanup did not finish ($src): [$out]"; return 1; }
    [[ "$out" != *keyonly* ]] || { echo "the leftover key file was not swept ($src): [$out]"; return 1; }
}
@test "cleanup: a key file with no record is swept without a word, both twins" {
    both c_cleanup_key_file_without_record
}

p_record_unwritable() {
    # If the record cannot be written, NOTHING may be created: an interface with
    # no record is a leak nobody would ever hear about. A directory in the record
    # path makes the write fail without touching anything else.
    local src="$1" out
    out=$(PATH="$BIN:$PATH" TMPDIR="$TEST_DIR" timeout 60 bash -c '
        rm -rf "$TMPDIR"/awg31probe.*
        mkdir -p "$TMPDIR/awg31probe.$$.iface"
        eval "$(sed -n "/^_awg31_module_probe() (/,/^)$/p" "$1")"
        _awg31_module_probe
    ' _ "$src")
    [ "$out" = "failed" ] || { echo "a record that could not be written was not a refusal ($src): $out"; return 1; }
    grep -q "^link add " "$TEST_DIR/ip.argv" && { echo "an interface was created with no record ($src)"; return 1; }
    return 0
}
@test "probe: nothing is created when the record cannot be written, both twins" {
    make_ip add; make_awg ok
    both p_record_unwritable
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
        # The delete fails and the interface is STILL THERE: that is the one
        # state worth a warning. A delete that failed because the device is
        # already gone is not, and the code now tells the two apart.
        printf "#!/usr/bin/env bash\ncase \"\$2\" in show) exit 0 ;; *) exit 1 ;; esac\n" > "$2/bin/ip"
        chmod +x "$2/bin/ip"
        export PATH="$2/bin:$PATH"
        export TMPDIR="$2/tmp"
        rm -f "$TMPDIR"/awg31probe.*
        printf "%s\n" "awgp${$}x1" > "$TMPDIR/awg31probe.$$.iface"
        log_warn() { echo "WARNED $*"; }
        _install_temp_files=()
        _install_cleaned=0
        eval "$(sed -n "/^_probe_warn() {/,/^}/p" "$1")"
        eval "$(sed -n "/^_install_cleanup() {/,/^}/p" "$1")"
        _install_cleanup
    ' _ "$src" "$TEST_DIR")
    [[ "$out" == *WARNED* ]] || { echo "a leftover that could not be removed was passed over in silence ($src): [$out]"; return 1; }
    [[ "$out" == *awgp* ]] || { echo "the warning does not name the leftover ($src): [$out]"; return 1; }
    # 🔴 Assert the BRANCH, not just that something was said. Measured: with the
    # cleanup regex broken in one twin, four tests went red and this one stayed
    # green, because "warned" and "names awgp" are equally true of the
    # foreign-name branch next door. A delete has to have been attempted.
    [[ "$out" == *"ip link del"* ]] || { echo "the warning did not come from the delete branch ($src): [$out]"; return 1; }
}
@test "cleanup: a leftover that cannot be removed is named, both twins" {
    both c_cleanup_speaks
}

c_cleanup_quiet_when_gone() {
    # On Ctrl-C the whole process group is signalled and the probe subshell can
    # remove the interface first, so the parent's delete fails against a device
    # that is already gone. Warning then points the reader at a non-problem.
    local src="$1" out
    out=$(timeout 60 bash -c '
        mkdir -p "$2/bin" "$2/tmp"
        printf "#!/usr/bin/env bash\nexit 1\n" > "$2/bin/ip"
        chmod +x "$2/bin/ip"
        export PATH="$2/bin:$PATH"
        export TMPDIR="$2/tmp"
        rm -f "$TMPDIR"/awg31probe.*
        printf "%s\n" "awgp${$}x1" > "$TMPDIR/awg31probe.$$.iface"
        log_warn() { echo "WARNED $*"; }
        _install_temp_files=()
        _install_cleaned=0
        eval "$(sed -n "/^_probe_warn() {/,/^}/p" "$1")"
        eval "$(sed -n "/^_install_cleanup() {/,/^}/p" "$1")"
        _install_cleanup
        echo finished
    ' _ "$src" "$TEST_DIR")
    [[ "$out" == *finished* ]] || { echo "the cleanup did not finish ($src): [$out]"; return 1; }
    [[ "$out" != *WARNED* ]] || { echo "warned about an interface that was already gone ($src): [$out]"; return 1; }
}
@test "cleanup: nothing is said when the interface is already gone, both twins" {
    both c_cleanup_quiet_when_gone
}

c_cleanup_short_record() {
    # 🔴 `read` returns 1 on a file with no trailing newline HAVING ALREADY
    # assigned the value. Throwing that value away, as `|| _probe_if=""` did,
    # means a record truncated by a full disk silently loses the interface it
    # names. Measured here rather than argued: the record is written without a
    # newline and the interface still has to be removed.
    local src="$1" out
    out=$(timeout 60 bash -c '
        mkdir -p "$2/bin" "$2/tmp"
        printf "#!/usr/bin/env bash\necho \"\$*\" >> \"$2/called\"\nexit 0\n" > "$2/bin/ip"
        chmod +x "$2/bin/ip"
        export PATH="$2/bin:$PATH"
        export TMPDIR="$2/tmp"
        rm -f "$2/called"; rm -f "$TMPDIR"/awg31probe.*
        printf "%s" "awgp${$}x1" > "$TMPDIR/awg31probe.$$.iface"
        log_warn() { echo "WARNED $*"; }
        _install_temp_files=()
        _install_cleaned=0
        eval "$(sed -n "/^_probe_warn() {/,/^}/p" "$1")"
        eval "$(sed -n "/^_install_cleanup() {/,/^}/p" "$1")"
        _install_cleanup
        cat "$2/called" 2>/dev/null
    ' _ "$src" "$TEST_DIR")
    [[ "$out" == *"link del awgp"* ]] || { echo "a record without a trailing newline lost the interface ($src): [$out]"; return 1; }
}
@test "cleanup: a record without a trailing newline still names its interface, both twins" {
    both c_cleanup_short_record
}

c_record_write_is_guarded() {
    # Structural, and said so plainly: a symlink planted at the record path is
    # already defeated by the `rm -f` in front of the write, and `set -C`
    # (O_EXCL) closes the race where something re-plants it in between. Neither
    # can be driven portably from a test on this host, so what is pinned here is
    # that both are present and in that order.
    #
    # 🔴 The order half has to be checked as ADJACENCY, not as two independent
    # greps: `rm -f "$rec"` occurs three times in the probe body (inside
    # `_probe_cleanup`, in front of the write, and after a failed creation), so
    # a plain grep for it was satisfied by lines that have nothing to do with
    # the write. Measured: removing exactly the `rm -f` that guards the write
    # left this case green.
    local f body
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        body=$(sed -n '/^_awg31_module_probe() (/,/^)$/p' "$BATS_TEST_DIRNAME/../$f")
        [ -n "$body" ] || { echo "no probe body in $f"; return 1; }
        grep -A1 'rm -f "$rec" 2>/dev/null' <<< "$body" | grep -q 'set -C; printf' \
            || { echo "the record write is not a cleared path followed by an O_EXCL write in $f"; return 1; }
        grep -q 'set -C; printf' <<< "$body" || { echo "the record write does not use set -C in $f"; return 1; }
    done
    return 0
}
@test "probe: the record is written with O_EXCL over a cleared path, both twins" {
    c_record_write_is_guarded
}

c_record_read_is_bounded() {
    # 🔴 TWO bounds, and they are not the same bound. The time bound keeps the
    # exit trap from hanging for good on a planted FIFO. The SIZE bound keeps a
    # planted file from being read whole: `head -n 1` on a file with no newline
    # in it streams all of it, and the result is handed to a warning that writes
    # to the log under /root and to the console. Measured: 20 MB came back well
    # inside the five second bound, so the clock does not stand in for the size.
    # The path is predictable (a world writable directory plus a pid from
    # /proc), and this trap fires on EVERY exit of the installer, `--help`
    # included, where the probe never ran at all.
    #
    # Structural, and honest about why: the regular-file test rejects a FIFO
    # before the read, so an unbounded read never hangs in any case a test can
    # set up - what the time bound protects is the RACE, a swap between the test
    # and the open, which cannot be driven from a test without injecting one.
    # The size half IS driven behaviourally, by the case below this one.
    local f body
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        body=$(sed -n '/^_install_cleanup() {/,/^}/p' "$BATS_TEST_DIRNAME/../$f")
        [ -n "$body" ] || { echo "no cleanup body in $f"; return 1; }
        grep -q 'timeout -k 1 5 head -c 64 "$_probe_rec"' <<< "$body" \
            || { echo "the record read is not bounded in both time and size in $f"; return 1; }
    done
    return 0
}

c_record_read_is_bounded_in_size() {
    # The behavioural half: a record whose first line is long must not put that
    # line into the warning. A megabyte here stands in for the 20 MB measured by
    # hand; what is asserted is that the output stays small, not a byte count.
    local src="$1" out len
    out=$(timeout 60 bash -c '
        mkdir -p "$2/bin" "$2/tmp"
        printf "#!/usr/bin/env bash\nexit 0\n" > "$2/bin/ip"
        chmod +x "$2/bin/ip"
        export PATH="$2/bin:$PATH"
        export TMPDIR="$2/tmp"
        rm -rf "$TMPDIR"/awg31probe.*
        # one line, no newline anywhere in it
        head -c 1048576 /dev/zero | tr "\0" "A" > "$TMPDIR/awg31probe.$$.iface"
        # 🔴 The message itself, not its length. The first version of this
        # case printed ${#1} and was therefore vacuous: the output stayed small
        # whether the read was bounded or not, and the mutant survived.
        log_warn() { echo "WARNED $*"; }
        _install_temp_files=()
        _install_cleaned=0
        eval "$(sed -n "/^_probe_warn() {/,/^}/p" "$1")"
        eval "$(sed -n "/^_install_cleanup() {/,/^}/p" "$1")"
        _install_cleanup
        echo finished
    ' _ "$src" "$TEST_DIR" 2>&1)
    [[ "$out" == *finished* ]] || { echo "the cleanup did not finish on a long record ($src): ${out:0:200}"; return 1; }
    len=${#out}
    [ "$len" -lt 4096 ] || { echo "a long record reached the output ($src): $len characters"; return 1; }
}
@test "cleanup: a record with a very long line does not reach the log, both twins" {
    both c_record_read_is_bounded_in_size
}
@test "cleanup: the record is read under a bound, both twins" {
    c_record_read_is_bounded
}

c_probe_cleanup_idempotent() {
    # 🔴 Behavioural, not a grep over the source. On a signal the cleanup runs
    # from the handler and again on EXIT; without the guard the second run
    # spends another bounded `ip link del` on an interface that is already gone,
    # which is up to five more seconds of silence in exactly the wedged netlink
    # state the probe exists to refuse over. The previous version pinned the
    # SHAPE of the flag, so it would have passed a rewrite that sets the flag and
    # still spends the delete - and it broke on a harmless reformat.
    local src="$1" out
    out=$(timeout 60 bash -c '
        mkdir -p "$2/bin" "$2/tmp"
        printf "#!/usr/bin/env bash\necho \"\$*\" >> \"$2/dels\"\nexit 0\n" > "$2/bin/ip"
        chmod +x "$2/bin/ip"
        export PATH="$2/bin:$PATH"
        rm -f "$2/dels"
        # The nested function is lifted the same way everything else here is.
        eval "$(sed -n "/^    _probe_cleanup() {/,/^    }/p" "$1")"
        cleaned=0
        made=1
        ifn="awgpXx1"
        kf="$2/tmp/keyfile"; : > "$kf"
        rec="$2/tmp/record";  : > "$rec"
        _probe_cleanup
        _probe_cleanup
        grep -c "^link del " "$2/dels" 2>/dev/null || echo 0
    ' _ "$src" "$TEST_DIR")
    [ "$out" = "1" ] || { echo "the probe cleanup spent $out deletes over two runs, expected 1 ($src)"; return 1; }
}
@test "cleanup: the probe cleanup does nothing on a second run, both twins" {
    both c_probe_cleanup_idempotent
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
p_key_replaced_before_control() {
    # 🔴 The key file is still THERE at control step 2, and still non-empty -
    # it is simply no longer the file that was validated. The old guard asked
    # `-s` alone, which is true for exactly the file that does the damage: the
    # tool refuses over the FILE, and the refusal at step 2 reads as "the module
    # refused the key", so a healthy third-line module is told to rebuild itself
    # and reboot. The guard now asks the same question the validation asked.
    local src="$1" out
    make_ip add; make_awg keygrow
    out=$(probe "$src")
    [ "$out" = "failed" ] || { echo "a key file replaced before control step 2 produced a verdict ($src): $out"; return 1; }
}
@test "probe: a key file replaced before control step 2 is not a second-line verdict, both twins" {
    both p_key_replaced_before_control
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
