#!/usr/bin/env bats
# Guard against CVE-2026-98432 (kernel use-after-free on an IPv4 TCP SYN that
# carries IP options): a raw-table rule that drops TCP packets with IP options,
# kept by the helper amneziawg-ipopts-guard and the unit
# amneziawg-ipopts-guard.service. The installer deploys it on step 4 and on
# its own with --ipopts-guard (installed servers); manage check reports it;
# --uninstall removes it. Every case runs on both languages: their functions
# differ in messages, so one cannot stand in for the other.

load test_helper

INSTALLERS=(install_amneziawg.sh install_amneziawg_en.sh)
MANAGERS=(manage_amneziawg.sh manage_amneziawg_en.sh)
RULE='PREROUTING -p tcp -m u32 --u32 0>>24&0xF=6:15 -m comment --comment amneziawg-ipopts-guard -j DROP'
IPT='iptables -w 10 -t raw'

_fn() { sed -n "/^$2() {\$/,/^}\$/p" "$BATS_TEST_DIRNAME/../$1"; }
_stub() { printf '#!/bin/bash\n%s\n' "$2" > "$T/bin/$1"; chmod +x "$T/bin/$1"; }
_calls() { cat "$T/calls" 2>/dev/null || true; }

setup() {
    T=$(mktemp -d); export T
    mkdir -p "$T/bin"
    # iptables stub: the rule count lives in $T/rules. ipt.fail makes every
    # call an error (exit 2, as with a missing match extension); ipt.other
    # exits 1 with a message that is not "no such rule" (iptables uses 1 for
    # other problems too); ipt.stuck makes -D succeed without removing;
    # ipt.nodel makes -D fail as "no such rule" while the rule stays.
    _stub iptables 'echo "iptables $*" >> "$T/calls"
[[ -e "$T/ipt.fail" ]] && { echo "iptables: Couldn'"'"'t load match u32" >&2; exit 2; }
[[ -e "$T/ipt.other" ]] && { echo "iptables: table raw is incompatible, use nft tool" >&2; exit 1; }
nomatch() { echo "iptables: Bad rule (does a matching rule exist in that chain?)." >&2; exit 1; }
n=$(cat "$T/rules" 2>/dev/null || echo 0)
case "$5" in
  -C) [[ "$n" -gt 0 ]] || nomatch ;;
  -I) [[ -e "$T/ipt.noinsert" ]] && { echo "iptables: No chain/target/match by that name." >&2; exit 1; }
      echo $((n + 1)) > "$T/rules" ;;
  -D) [[ -e "$T/ipt.stuck" ]] && exit 0
      [[ -e "$T/ipt.nodel" ]] && nomatch
      [[ "$n" -gt 0 ]] || nomatch; echo $((n - 1)) > "$T/rules" ;;
  *) exit 3 ;;
esac'
    export PATH="$T/bin:$PATH"
}

teardown() { rm -rf "$T"; }

# The helper as written by installer $1 -> $T/guard.
_helper() {
    sed -n "/<<'AWG_IPOPTS_HELPER_EOF'/,/^AWG_IPOPTS_HELPER_EOF\$/p" "$BATS_TEST_DIRNAME/../$1" | sed '1d;$d' > "$T/guard"
    [ -s "$T/guard" ] || { echo "$1: helper heredoc not found"; return 1; }
    chmod +x "$T/guard"
}

# ---------- the helper ----------

@test "helper: start inserts the rule once, with the exact match, into raw PREROUTING" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _helper "$f"; rm -f "$T/rules" "$T/calls"
        run sh "$T/guard" start
        [ "$status" -eq 0 ] || { echo "$f: $output"; return 1; }
        [ "$(cat "$T/rules")" = 1 ]
        grep -qxF "$IPT -C $RULE" "$T/calls" || { echo "$f: $(_calls)"; return 1; }
        grep -qxF "$IPT -I $RULE" "$T/calls" || { echo "$f: $(_calls)"; return 1; }
        # A second start finds it and adds nothing.
        run sh "$T/guard" start
        [ "$status" -eq 0 ]
        [ "$(cat "$T/rules")" = 1 ] || { echo "$f: duplicated"; return 1; }
    done
}

@test "helper: stop removes every copy and succeeds when there is none" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _helper "$f"; echo 3 > "$T/rules"; rm -f "$T/calls"
        run sh "$T/guard" stop
        [ "$status" -eq 0 ] || { echo "$f: $output"; return 1; }
        [ "$(cat "$T/rules")" = 0 ]
        grep -qxF "$IPT -D $RULE" "$T/calls" || { echo "$f: $(_calls)"; return 1; }
        run sh "$T/guard" stop
        [ "$status" -eq 0 ]
    done
}

@test "helper: stop that leaves the rule in place fails and says so" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _helper "$f"; echo 1 > "$T/rules"; touch "$T/ipt.nodel"
        run sh "$T/guard" stop
        [ "$status" -eq 1 ] || { echo "$f: $status $output"; return 1; }
        [[ "$output" == *"still in place"* ]] || { echo "$f: $output"; return 1; }
        rm -f "$T/ipt.nodel"
    done
}

@test "helper: stop gives up after 100 removals that remove nothing, it does not spin" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _helper "$f"; echo 1 > "$T/rules"; touch "$T/ipt.stuck"; rm -f "$T/calls"
        run timeout 20 sh "$T/guard" stop
        [ "$status" -eq 1 ] || { echo "$f: $status"; return 1; }
        [ "$(grep -c -- ' -D ' "$T/calls")" -eq 100 ] || { echo "$f: $(grep -c -- ' -D ' "$T/calls") removals"; return 1; }
        rm -f "$T/ipt.stuck"
    done
}

@test "helper: stop with exactly 100 copies removes them all and succeeds" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _helper "$f"; echo 100 > "$T/rules"
        run sh "$T/guard" stop
        [ "$status" -eq 0 ] && [ "$(cat "$T/rules")" = 0 ] || { echo "$f: $status rules=$(cat "$T/rules") $output"; return 1; }
    done
}

@test "helper: status is 0 with the rule, 1 without it, 3 when iptables cannot tell" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _helper "$f"
        echo 1 > "$T/rules"; run sh "$T/guard" status; [ "$status" -eq 0 ] || { echo "$f present: $status"; return 1; }
        echo 0 > "$T/rules"; run sh "$T/guard" status; [ "$status" -eq 1 ] || { echo "$f absent: $status"; return 1; }
        [ -z "$output" ] || { echo "$f absent printed: $output"; return 1; }
        touch "$T/ipt.fail"; run sh "$T/guard" status
        [ "$status" -eq 3 ] && [[ "$output" == *"load match u32"* ]] || { echo "$f error: $status $output"; return 1; }
        rm -f "$T/ipt.fail"
        # iptables exits 1 for other problems too: that is not "no rule"
        touch "$T/ipt.other"; run sh "$T/guard" status
        [ "$status" -eq 3 ] && [[ "$output" == *"incompatible"* ]] || { echo "$f other: $status $output"; return 1; }
        run sh "$T/guard" start
        [ "$status" -eq 3 ] || { echo "$f other start: $status"; return 1; }
        rm -f "$T/ipt.other"
    done
}

@test "helper: a failing iptables makes start fail loudly" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _helper "$f"; touch "$T/ipt.fail"
        run sh "$T/guard" start
        [ "$status" -ne 0 ] || { echo "$f: start succeeded"; return 1; }
        [[ "$output" == *"load match u32"* ]] || { echo "$f: $output"; return 1; }
    done
}

@test "helper: an unknown or missing mode is exit 2; --version answers" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _helper "$f"
        run sh "$T/guard" bogus; [ "$status" -eq 2 ]
        run sh "$T/guard";       [ "$status" -eq 2 ]
        run sh "$T/guard" --version
        [ "$status" -eq 0 ] && [[ "$output" == "amneziawg-ipopts-guard "[0-9]* ]] || { echo "$f: $output"; return 1; }
        [ ! -e "$T/calls" ] || { echo "$f: iptables called: $(_calls)"; return 1; }
    done
}

@test "helper and unit are the same text in both installers" {
    local a b
    a=$(sed -n "/<<'AWG_IPOPTS_HELPER_EOF'/,/^AWG_IPOPTS_HELPER_EOF\$/p;/<<'AWG_IPOPTS_UNIT_EOF'/,/^AWG_IPOPTS_UNIT_EOF\$/p" "$BATS_TEST_DIRNAME/../install_amneziawg.sh" | grep -v "<<'AWG_IPOPTS_")
    b=$(sed -n "/<<'AWG_IPOPTS_HELPER_EOF'/,/^AWG_IPOPTS_HELPER_EOF\$/p;/<<'AWG_IPOPTS_UNIT_EOF'/,/^AWG_IPOPTS_UNIT_EOF\$/p" "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh" | grep -v "<<'AWG_IPOPTS_")
    [ -n "$a" ]
    [ "$a" = "$b" ]
    grep -qx 'ExecStart=/usr/local/sbin/amneziawg-ipopts-guard start' <<<"$a"
    grep -qx 'ExecStop=/usr/local/sbin/amneziawg-ipopts-guard stop' <<<"$a"
    grep -qx 'RemainAfterExit=yes' <<<"$a"
    grep -qx 'WantedBy=multi-user.target' <<<"$a"
}

# ---------- deployment ----------

# _awg_deploy_ipopts_guard of installer $1 with its target directories moved
# into $T. The helper heredoc may hold "}" in column 0, so the function is cut
# up to the "}" that follows the unit's end marker.
_deploy_driver() {
    {
        echo 'log() { echo "LOG: $*"; }; log_warn() { echo "WARN: $*"; }; log_error() { echo "ERR: $*"; }'
        awk '/^_awg_deploy_ipopts_guard\(\) \{$/{f=1} f{print} f&&/^AWG_IPOPTS_UNIT_EOF$/{e=1} f&&e&&/^}$/{exit}' \
            "$BATS_TEST_DIRNAME/../$1" | sed "s#/usr/local/sbin#$T/sbin#g; s#/etc/systemd/system#$T/units#g"
        echo '_awg_deploy_ipopts_guard; echo "RC=$?"'
    } > "$T/deploy.sh"
    grep -q '^AWG_IPOPTS_UNIT_EOF$' "$T/deploy.sh" || { echo "$1: function not cut"; return 1; }
}
# systemctl stub: records the call; start runs the unit's ExecStart (the
# helper, from $T/sbin) and marks the unit active, stop runs ExecStop, as
# systemd would; is-active answers by that mark.
_systemctl_stub() {
    _stub systemctl 'echo "systemctl $*" >> "$T/calls"
[[ -e "$T/sc.fail.$1" ]] && exit 1
case "$1" in
  start) sh "$T/sbin/amneziawg-ipopts-guard" start && touch "$T/active" ;;
  restart) sh "$T/sbin/amneziawg-ipopts-guard" stop; sh "$T/sbin/amneziawg-ipopts-guard" start ;;
  is-active) [[ -e "$T/active" ]] ;;
esac'
}

@test "deploy: writes an executable helper and the unit, enables and starts it, rule in place: 0" {
    local f
    for f in "${INSTALLERS[@]}"; do
        rm -rf "${T:?}/sbin" "$T/units" "$T/calls" "$T/rules" "$T/active"
        _deploy_driver "$f"; _systemctl_stub
        run bash "$T/deploy.sh"
        [[ "$output" == *"RC=0"* ]] || { echo "$f: $output"; return 1; }
        [ -x "$T/sbin/amneziawg-ipopts-guard" ]
        [ -f "$T/units/amneziawg-ipopts-guard.service" ]
        [ "$(cat "$T/rules")" = 1 ]
        grep -qx 'systemctl daemon-reload' "$T/calls"
        grep -qx 'systemctl enable amneziawg-ipopts-guard.service' "$T/calls"
        grep -qx 'systemctl start amneziawg-ipopts-guard.service' "$T/calls" || { echo "$f: $(_calls)"; return 1; }
        [ ! -e "$T/sbin/.amneziawg-ipopts-guard.new" ] && [ ! -e "$T/units/.amneziawg-ipopts-guard.service.new" ] \
            || { echo "$f: stage left"; return 1; }
    done
}

@test "deploy: a repeated run on an active unit never removes the rule, and keeps exactly one" {
    local f
    for f in "${INSTALLERS[@]}"; do
        rm -rf "${T:?}/sbin" "$T/units" "$T/calls" "$T/rules" "$T/active"
        _deploy_driver "$f"; _systemctl_stub
        run bash "$T/deploy.sh"
        [[ "$output" == *"RC=0"* ]] || { echo "$f first: $output"; return 1; }
        rm -f "$T/calls"
        run bash "$T/deploy.sh"
        [[ "$output" == *"RC=0"* ]] && [ "$(cat "$T/rules")" = 1 ] || { echo "$f second: $output rules=$(cat "$T/rules")"; return 1; }
        # no stop and no restart: there is no window without the rule
        ! grep -q -- ' -D ' "$T/calls" || { echo "$f: the rule was removed: $(_calls)"; return 1; }
        ! grep -qE 'systemctl (restart|stop|start) ' "$T/calls" || { echo "$f: $(_calls)"; return 1; }
    done
}

@test "deploy: a rule that is not in place after the start is a failure, not a success" {
    local f
    for f in "${INSTALLERS[@]}"; do
        rm -rf "${T:?}/sbin" "$T/units" "$T/calls" "$T/rules" "$T/active"
        # the check answers "no rule", but the insert fails
        _deploy_driver "$f"; _systemctl_stub; touch "$T/ipt.noinsert"
        run bash "$T/deploy.sh"
        [[ "$output" == *"RC=1"* ]] || { echo "$f: $output"; return 1; }
        # the refusal comes from the final status check, after enable and start
        [[ "$output" == *"WARN: "*"amneziawg-ipopts-guard status"* ]] || { echo "$f: $output"; return 1; }
        grep -qx 'systemctl enable amneziawg-ipopts-guard.service' "$T/calls"
        grep -qx 'systemctl start amneziawg-ipopts-guard.service' "$T/calls"
        # and the unit that cannot set the rule is not left enabled for every boot
        grep -qx 'systemctl disable amneziawg-ipopts-guard.service' "$T/calls" || { echo "$f: $(_calls)"; return 1; }
        grep -qx 'systemctl reset-failed amneziawg-ipopts-guard.service' "$T/calls" || { echo "$f: $(_calls)"; return 1; }
        rm -f "$T/ipt.noinsert"
    done
}

@test "deploy: a check that cannot tell (code 3) is a failure that leaves the unit enabled" {
    local f
    for f in "${INSTALLERS[@]}"; do
        rm -rf "${T:?}/sbin" "$T/units" "$T/calls" "$T/rules" "$T/active"
        _deploy_driver "$f"; _systemctl_stub; touch "$T/ipt.fail"
        run bash "$T/deploy.sh"
        [[ "$output" == *"RC=1"* ]] || { echo "$f: $output"; return 1; }
        [[ "$output" == *"WARN: "*"код 3,"* || "$output" == *"WARN: "*"code 3,"* ]] || { echo "$f: $output"; return 1; }
        ! grep -q 'systemctl disable' "$T/calls" || { echo "$f: disabled on an unknown answer: $(_calls)"; return 1; }
        rm -f "$T/ipt.fail"
    done
}

@test "deploy: an active unit whose rule was lost gets it back without a restart" {
    local f
    for f in "${INSTALLERS[@]}"; do
        rm -rf "${T:?}/sbin" "$T/units" "$T/calls" "$T/rules" "$T/active"
        _deploy_driver "$f"; _systemctl_stub
        run bash "$T/deploy.sh"
        [[ "$output" == *"RC=0"* ]] || { echo "$f first: $output"; return 1; }
        echo 0 > "$T/rules"; rm -f "$T/calls"   # the unit stays active, the rule is gone
        run bash "$T/deploy.sh"
        [[ "$output" == *"RC=0"* ]] && [ "$(cat "$T/rules")" = 1 ] || { echo "$f: $output rules=$(cat "$T/rules")"; return 1; }
        ! grep -qE 'systemctl (restart|stop|start|disable) ' "$T/calls" || { echo "$f: $(_calls)"; return 1; }
    done
}

@test "deploy: a failed enable or daemon-reload is a failure" {
    local f s
    for f in "${INSTALLERS[@]}"; do
        for s in enable daemon-reload; do
            rm -rf "${T:?}/sbin" "$T/units" "$T/calls" "$T/rules" "$T"/sc.fail.* "$T/active"
            _deploy_driver "$f"; _systemctl_stub; touch "$T/sc.fail.$s"
            run bash "$T/deploy.sh"
            [[ "$output" == *"RC=1"* ]] || { echo "$f $s: $output"; return 1; }
            ! grep -qE 'systemctl (re)?start' "$T/calls" || { echo "$f $s: started anyway"; return 1; }
            [[ "$s" != daemon-reload ]] || ! grep -q 'systemctl enable' "$T/calls" || { echo "$f: enable after a failed reload"; return 1; }
        done
    done
}

@test "deploy: without iptables nothing is written and it fails" {
    local f
    for f in "${INSTALLERS[@]}"; do
        rm -rf "${T:?}/sbin" "$T/units" "$T/calls"
        _deploy_driver "$f"; _systemctl_stub
        # A PATH with no iptables at all.
        mkdir -p "$T/nobin"; ln -sf "$T/bin/systemctl" "$T/nobin/systemctl"
        for c in bash sh cat chmod chown mv rm mkdir mktemp sed awk grep ls; do
            ln -sf "$(command -v "$c")" "$T/nobin/$c"
        done
        PATH="$T/nobin" run "$T/nobin/bash" "$T/deploy.sh"
        [[ "$output" == *"RC=1"* ]] || { echo "$f: $output"; return 1; }
        [ ! -e "$T/sbin/amneziawg-ipopts-guard" ] || { echo "$f: helper written"; return 1; }
        [ ! -e "$T/calls" ] || ! grep -q systemctl "$T/calls" || { echo "$f: $(_calls)"; return 1; }
    done
}

# ---------- --ipopts-guard: arguments and dispatch ----------

# Only the head of the installer runs: first line through the end of the
# --ipopts-guard argument check, then a marker. A whole run would go on to
# whatever the other flag asks for.
_head_through_check() {
    awk '{print} /^if \[\[ "\$IPOPTS_GUARD" -eq 1 \]\]; then$/ {c=1} c && /^fi$/ {exit}' \
        "$BATS_TEST_DIRNAME/../$1" > "$T/head.sh"
    grep -q '^if \[\[ "\$IPOPTS_GUARD" -eq 1 \]\]; then$' "$T/head.sh" || { echo "$1: the check block was not found"; return 1; }
    ! grep -q '^repair_module_cmd() {$\|^step_uninstall() {$\|^initialize_setup() {$' "$T/head.sh" \
        || { echo "$1: the head copy reaches into the installer body"; return 1; }
    printf '%s\n' 'echo "PASSED-CHECK guard=$IPOPTS_GUARD verbose=$VERBOSE"; trap - EXIT; exit 0' >> "$T/head.sh"
}

@test "--ipopts-guard refuses any other argument before doing anything" {
    local f a
    for f in "${INSTALLERS[@]}"; do
        _head_through_check "$f"
        for a in --uninstall --force --yes --diagnostic --repair-module --port=51820 --bogus; do
            run timeout 20 bash "$T/head.sh" --ipopts-guard "$a" </dev/null
            [ "$status" -eq 2 ] || { echo "$f $a: status $status: $output"; return 1; }
            [[ "$output" == *"--ipopts-guard"*"$a"* || "$output" == *"--repair-module"*"--ipopts-guard"* ]] || { echo "$f $a: $output"; return 1; }
            [[ "$output" != *PASSED-CHECK* ]]
            run timeout 20 bash "$T/head.sh" "$a" --ipopts-guard </dev/null
            [ "$status" -eq 2 ] || { echo "$f $a (before): status $status"; return 1; }
        done
    done
}

@test "--ipopts-guard accepts --verbose, -v and --no-color" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _head_through_check "$f"
        run timeout 20 bash "$T/head.sh" --ipopts-guard --verbose --no-color </dev/null
        [ "$status" -eq 0 ] || { echo "$f: status $status: $output"; return 1; }
        [[ "$output" == *"PASSED-CHECK guard=1 verbose=1"* ]] || { echo "$f: $output"; return 1; }
        run timeout 20 bash "$T/head.sh" -v --ipopts-guard </dev/null
        [ "$status" -eq 0 ] || { echo "$f -v: $output"; return 1; }
    done
}

@test "--ipopts-guard is dispatched after set -x and before the guard and the state machine" {
    local f g sx guard
    for f in "${INSTALLERS[@]}"; do
        g=$(grep -n -m1 '^if \[\[ "\$IPOPTS_GUARD" -eq 1 \]\]; then ipopts_guard_cmd; fi$' "$BATS_TEST_DIRNAME/../$f" | cut -d: -f1)
        sx=$(grep -n -m1 '^if \[\[ "\$VERBOSE" -eq 1 \]\]; then set -x; fi$' "$BATS_TEST_DIRNAME/../$f" | cut -d: -f1)
        guard=$(grep -n -m1 '^_resume_state=""$' "$BATS_TEST_DIRNAME/../$f" | cut -d: -f1)
        [ -n "$g" ] && [ -n "$sx" ] && [ -n "$guard" ]
        [ "$sx" -lt "$g" ] && [ "$g" -lt "$guard" ] || { echo "$f: sx=$sx g=$g guard=$guard"; return 1; }
    done
}

# ipopts_guard_cmd of installer $1, with id and the deploy stubbed.
_cmd_driver() {
    {
        echo 'log() { echo "LOG: $*"; }; log_warn() { echo "WARN: $*"; }; log_error() { echo "ERR: $*"; }'
        echo "id() { [[ \"\$1\" == -u ]] && echo \"\${FAKE_UID:-0}\"; }"
        echo '_awg_deploy_ipopts_guard() { echo deploy >> "$T/calls"; [[ ! -e "$T/deploy.fail" ]]; }'
        _fn "$1" ipopts_guard_cmd
        echo 'ipopts_guard_cmd'
    } > "$T/cmd.sh"
}

@test "ipopts_guard_cmd: deploys and exits 0, a failed deploy exits 1, not root is refused untouched" {
    local f
    for f in "${INSTALLERS[@]}"; do
        rm -f "$T/calls" "$T/deploy.fail"; _cmd_driver "$f"
        run bash "$T/cmd.sh"
        [ "$status" -eq 0 ] && [ "$(_calls)" = deploy ] || { echo "$f ok: $status $output"; return 1; }
        rm -f "$T/calls"; touch "$T/deploy.fail"
        run bash "$T/cmd.sh"
        [ "$status" -eq 1 ] || { echo "$f fail: $status $output"; return 1; }
        [[ "$output" == *"ERR: "* ]]
        rm -f "$T/calls"
        FAKE_UID=1000 run bash "$T/cmd.sh"
        [ "$status" -eq 1 ] && [ -z "$(_calls)" ] || { echo "$f uid: $status $(_calls)"; return 1; }
    done
}

# ---------- step 4 and uninstall ----------

# step4_setup_firewall of installer $1 with everything around it stubbed.
_step4_driver() {
    {
        echo 'log() { echo "LOG: $*"; }; log_warn() { echo "WARN: $*"; }; die() { echo "DIE: $*"; exit 1; }'
        echo 'update_state() { echo "state $1" >> "$T/calls"; }; install_packages() { :; }'
        echo 'setup_improved_firewall() { echo ufw >> "$T/calls"; }'
        echo '_awg_deploy_ipopts_guard() { echo guard >> "$T/calls"; [[ ! -e "$T/deploy.fail" ]]; }'
        echo "NO_TWEAKS=\${NT:-0}"
        _fn "$1" step4_setup_firewall
        echo 'step4_setup_firewall; echo "RC=$?"'
    } > "$T/s4.sh"
}

@test "step 4: the guard is deployed after UFW; its failure warns and does not stop the install" {
    local f
    for f in "${INSTALLERS[@]}"; do
        rm -f "$T/calls" "$T/deploy.fail"; _step4_driver "$f"
        run bash "$T/s4.sh"
        [[ "$output" == *"RC=0"* ]] && [ "$(_calls | tr '\n' ' ')" = "state 4 ufw guard state 5 " ] || { echo "$f: $output | $(_calls)"; return 1; }
        rm -f "$T/calls"; touch "$T/deploy.fail"
        run bash "$T/s4.sh"
        [[ "$output" == *"RC=0"* ]] || { echo "$f fail: $output"; return 1; }
        [[ "$output" == *"WARN: "*"--ipopts-guard"* ]] || { echo "$f fail: $output"; return 1; }
        # the step still moves on
        [ "$(_calls | tr '\n' ' ')" = "state 4 ufw guard state 5 " ] || { echo "$f fail: $(_calls)"; return 1; }
    done
}

@test "step 4 with --no-tweaks: no guard, a warning that names --ipopts-guard" {
    local f
    for f in "${INSTALLERS[@]}"; do
        rm -f "$T/calls"; _step4_driver "$f"
        NT=1 run bash "$T/s4.sh"
        [[ "$output" == *"RC=0"* ]] || { echo "$f: $output"; return 1; }
        [ "$(_calls | tr '\n' ' ')" = "state 4 state 5 " ] || { echo "$f: $(_calls)"; return 1; }
        [[ "$output" == *"WARN: "*"--ipopts-guard"* ]] || { echo "$f: $output"; return 1; }
    done
}

# The guard block of step_uninstall of installer $1, run on its own with the
# paths moved into $T: from its log line through the removal of the stage files.
_uninstall_driver() {
    {
        echo 'log() { echo "LOG: $*"; }; log_warn() { echo "WARN: $*"; }'
        # inside a function, as in step_uninstall (the block uses local)
        echo '_ub() {'
        _fn "$1" step_uninstall \
            | awk '/^    log "(Удаление защиты от|Removing the) CVE-2026-98432/{f=1} f{print} f&&/amneziawg-ipopts-guard\.new 2>\/dev\/null \|\| true$/{exit}' \
            | sed "s#/usr/local/sbin#$T/sbin#g; s#/etc/systemd/system#$T/units#g"
        echo '}'
        echo '_ub; echo "RC=$?"'
    } > "$T/un.sh"
    grep -q 'ipopts-guard.new 2>/dev/null || true' "$T/un.sh" || { echo "$1: uninstall block not cut"; return 1; }
}
_installed() { # helper and unit in $T, as a deploy leaves them, rule count $1
    mkdir -p "$T/sbin" "$T/units"
    _helper "$2"; cp "$T/guard" "$T/sbin/amneziawg-ipopts-guard"
    : > "$T/units/amneziawg-ipopts-guard.service"
    : > "$T/units/.amneziawg-ipopts-guard.service.new"; : > "$T/sbin/.amneziawg-ipopts-guard.new"
    echo "$1" > "$T/rules"
}

@test "uninstall: disables the unit, removes the rule, the helper, the unit and the stage files" {
    local f
    for f in "${INSTALLERS[@]}"; do
        rm -rf "${T:?}/sbin" "$T/units" "$T/calls"; _installed 1 "$f"; _systemctl_stub; _uninstall_driver "$f"
        run bash "$T/un.sh"
        [[ "$output" == *"RC=0"* ]] || { echo "$f: $output"; return 1; }
        grep -qx 'systemctl disable --now amneziawg-ipopts-guard.service' "$T/calls" || { echo "$f: $(_calls)"; return 1; }
        [ "$(cat "$T/rules")" = 0 ] || { echo "$f: rule left"; return 1; }
        [[ "$output" != *"WARN: "* ]] || { echo "$f: $output"; return 1; }
        [ -z "$(find "$T/sbin" "$T/units" -mindepth 1)" ] || { echo "$f: left $(find "$T/sbin" "$T/units" -mindepth 1)"; return 1; }
    done
}

@test "uninstall: a rule that would not go is said with the command to remove it" {
    local f
    for f in "${INSTALLERS[@]}"; do
        rm -rf "${T:?}/sbin" "$T/units" "$T/calls"; _installed 1 "$f"; _systemctl_stub; touch "$T/ipt.nodel"
        _uninstall_driver "$f"
        run bash "$T/un.sh"
        [[ "$output" == *"WARN: "*"iptables -t raw -D PREROUTING"* ]] || { echo "$f: $output"; return 1; }
        # said as a rule that stayed, not as an unknown outcome
        [[ "$output" == *"уйдёт после перезагрузки"* || "$output" == *"goes away at the next reboot"* ]] || { echo "$f: $output"; return 1; }
        [ ! -e "$T/sbin/amneziawg-ipopts-guard" ]
        rm -f "$T/ipt.nodel"
    done
}

@test "uninstall: when iptables cannot tell whether the rule went, that is said too" {
    local f
    for f in "${INSTALLERS[@]}"; do
        rm -rf "${T:?}/sbin" "$T/units" "$T/calls"; _installed 1 "$f"; _systemctl_stub; touch "$T/ipt.fail"
        _uninstall_driver "$f"
        run bash "$T/un.sh"
        [[ "$output" == *"WARN: "*"код 3)"*"iptables -t raw -S PREROUTING"* || "$output" == *"WARN: "*"code 3)"*"iptables -t raw -S PREROUTING"* ]] \
            || { echo "$f: $output"; return 1; }
        # the reason from iptables is shown, not swallowed
        [[ "$output" == *"load match u32"* ]] || { echo "$f: no reason: $output"; return 1; }
        rm -f "$T/ipt.fail"
    done
}

@test "uninstall: without the guard installed it passes quietly" {
    local f
    for f in "${INSTALLERS[@]}"; do
        rm -rf "${T:?}/sbin" "$T/units" "$T/calls"; mkdir -p "$T/sbin" "$T/units"; _systemctl_stub; _uninstall_driver "$f"
        run bash "$T/un.sh"
        [[ "$output" == *"RC=0"* && "$output" != *"WARN: "* ]] || { echo "$f: $output"; return 1; }
    done
}

@test "--ipopts-guard is in the help of both installers" {
    grep -q -- '--ipopts-guard        Защита от CVE-2026-98432' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -q -- '--ipopts-guard        Protection against CVE-2026-98432' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
}

# ---------- manage check ----------

# _ipopts_guard_report of manage $1, with the helper path moved into $T.
_report_driver() {
    {
        echo 'log() { echo "LOG: $*"; }; log_warn() { echo "WARN: $*"; }; log_error() { echo "ERR: $*"; }'
        echo "AWG_IPOPTS_HELPER=$T/sbin/amneziawg-ipopts-guard"
        _fn "$1" _ipopts_guard_report
        echo '_ipopts_guard_report; echo "RC=$?"'
    } > "$T/rep.sh"
    grep -q '^_ipopts_guard_report() {$' "$T/rep.sh" || { echo "$1: function not found"; return 1; }
}
# helper stub answering status with $T/st.rc; systemctl is-enabled by $T/en.
_report_env() {
    mkdir -p "$T/sbin"
    printf '#!/bin/sh\n[ "$1" = status ] || exit 9\nexit $(cat "%s/st.rc")\n' "$T" > "$T/sbin/amneziawg-ipopts-guard"
    chmod +x "$T/sbin/amneziawg-ipopts-guard"
    _stub systemctl '[[ "$1" == is-enabled ]] && [[ -e "$T/en" ]]'
}

@test "check: rule in place and unit enabled is an info line; the function never fails check" {
    local m
    for m in "${MANAGERS[@]}"; do
        _report_env; echo 0 > "$T/st.rc"; touch "$T/en"; _report_driver "$m"
        run bash "$T/rep.sh"
        [[ "$output" == *"LOG: "*"CVE-2026-98432"* ]] || { echo "$m: $output"; return 1; }
        grep -qxF -e 'LOG:  - Стоит: TCP-пакеты с IP-опциями отбрасываются (amneziawg-ipopts-guard.service).' \
            -e 'LOG:  - Set: TCP packets with IP options are dropped (amneziawg-ipopts-guard.service).' <<<"$output" \
            || { echo "$m: $output"; return 1; }
        [[ "$output" != *"WARN: "* ]] || { echo "$m: $output"; return 1; }
        [[ "$output" == *"RC=0"* ]]
    done
}

@test "check: no helper, no rule, a rule that will not survive a reboot, or a failed query each warn" {
    local m
    for m in "${MANAGERS[@]}"; do
        # no helper at all: the way in is --ipopts-guard
        rm -rf "${T:?}/sbin" "$T/en"; _stub systemctl 'exit 1'; _report_driver "$m"
        run bash "$T/rep.sh"
        [[ "$output" == *"LOG: "*"CVE-2026-98432"*"WARN: "*"--ipopts-guard"* ]] || { echo "$m none: $output"; return 1; }
        [[ "$output" == *"RC=0"* ]]
        # helper, rule missing
        _report_env; echo 1 > "$T/st.rc"; touch "$T/en"; _report_driver "$m"
        run bash "$T/rep.sh"
        [[ "$output" == *"WARN: "*"--ipopts-guard"* ]] || { echo "$m absent: $output"; return 1; }
        # rule in place, unit not enabled
        echo 0 > "$T/st.rc"; rm -f "$T/en"
        run bash "$T/rep.sh"
        [[ "$output" == *"WARN: "*"amneziawg-ipopts-guard.service"* ]] || { echo "$m not enabled: $output"; return 1; }
        # the query itself failed: said as such, not as "no rule"
        echo 2 > "$T/st.rc"; touch "$T/en"
        run bash "$T/rep.sh"
        [[ "$output" == *"WARN: "* ]] && [[ "$output" == *"RC=0"* ]] || { echo "$m error: $output"; return 1; }
        local q; q=$(bash "$T/rep.sh" 2>&1); echo 1 > "$T/st.rc"
        [ "$q" != "$(bash "$T/rep.sh" 2>&1)" ] || { echo "$m: a failed query reads like a missing rule"; return 1; }
    done
}

@test "check: the status query is bounded by timeout 10, and a timeout is said as a failed query" {
    local m
    for m in "${MANAGERS[@]}"; do
        _report_env; echo 0 > "$T/st.rc"; touch "$T/en"; rm -f "$T/calls"
        _stub timeout 'echo "timeout $*" >> "$T/calls"; exit 124'
        _report_driver "$m"
        run bash "$T/rep.sh"
        grep -qxF "timeout 10 $T/sbin/amneziawg-ipopts-guard status" "$T/calls" || { echo "$m: $(cat "$T/calls" 2>/dev/null)"; return 1; }
        [[ "$output" == *"WARN: "*"124"* && "$output" == *"RC=0"* ]] || { echo "$m: $output"; return 1; }
        [[ "$output" != *"amneziawg-ipopts-guard.service"*"restart"* ]] || { echo "$m: said as a missing rule"; return 1; }
        rm -f "$T/bin/timeout"
    done
}

@test "check: check_server calls the report" {
    local m
    for m in "${MANAGERS[@]}"; do
        _fn "$m" check_server | grep -qx '    _ipopts_guard_report' || { echo "$m"; return 1; }
    done
}
