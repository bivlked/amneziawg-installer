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

_fn() { sed -n "/^$2() {\$/,/^}\$/p" "$BATS_TEST_DIRNAME/../$1"; }
_stub() { printf '#!/bin/bash\n%s\n' "$2" > "$T/bin/$1"; chmod +x "$T/bin/$1"; }
_calls() { cat "$T/calls" 2>/dev/null || true; }

setup() {
    T=$(mktemp -d); export T
    mkdir -p "$T/bin"
    # iptables stub: the rule count lives in $T/rules; ipt.fail makes every
    # call an error (exit 2, as with a missing match extension).
    _stub iptables 'echo "iptables $*" >> "$T/calls"
[[ -e "$T/ipt.fail" ]] && { echo "iptables: Couldn'"'"'t load match u32" >&2; exit 2; }
n=$(cat "$T/rules" 2>/dev/null || echo 0)
case "$4" in
  -C) [[ "$n" -gt 0 ]] ;;
  -I) echo $((n + 1)) > "$T/rules" ;;
  -D) [[ "$n" -gt 0 ]] || { echo "iptables: Bad rule" >&2; exit 1; }; echo $((n - 1)) > "$T/rules" ;;
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
        grep -qxF "iptables -w -t raw -I $RULE" "$T/calls" || { echo "$f: $(_calls)"; return 1; }
        # A second start finds it and adds nothing.
        run sh "$T/guard" start
        [ "$status" -eq 0 ]
        [ "$(cat "$T/rules")" = 1 ] || { echo "$f: duplicated"; return 1; }
    done
}

@test "helper: stop removes every copy and succeeds when there is none" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _helper "$f"; echo 3 > "$T/rules"
        run sh "$T/guard" stop
        [ "$status" -eq 0 ] || { echo "$f: $output"; return 1; }
        [ "$(cat "$T/rules")" = 0 ]
        run sh "$T/guard" stop
        [ "$status" -eq 0 ]
    done
}

@test "helper: status is 0 with the rule, 1 without it, and the iptables code on an error" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _helper "$f"
        echo 1 > "$T/rules"; run sh "$T/guard" status; [ "$status" -eq 0 ] || { echo "$f present: $status"; return 1; }
        echo 0 > "$T/rules"; run sh "$T/guard" status; [ "$status" -eq 1 ] || { echo "$f absent: $status"; return 1; }
        touch "$T/ipt.fail";  run sh "$T/guard" status; [ "$status" -eq 2 ] || { echo "$f error: $status"; return 1; }
        rm -f "$T/ipt.fail"
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
# systemctl stub: records the call; start/restart runs the unit's ExecStart
# (the helper, from $T/sbin), as systemd would.
_systemctl_stub() {
    _stub systemctl 'echo "systemctl $*" >> "$T/calls"
[[ -e "$T/sc.fail.$1" ]] && exit 1
case "$1" in restart|start) sh "$T/sbin/amneziawg-ipopts-guard" start ;; esac'
}

@test "deploy: writes an executable helper and the unit, enables and restarts it, rule in place: 0" {
    local f
    for f in "${INSTALLERS[@]}"; do
        rm -rf "${T:?}/sbin" "$T/units" "$T/calls" "$T/rules"
        _deploy_driver "$f"; _systemctl_stub
        run bash "$T/deploy.sh"
        [[ "$output" == *"RC=0"* ]] || { echo "$f: $output"; return 1; }
        [ -x "$T/sbin/amneziawg-ipopts-guard" ]
        [ -f "$T/units/amneziawg-ipopts-guard.service" ]
        [ "$(cat "$T/rules")" = 1 ]
        grep -qx 'systemctl daemon-reload' "$T/calls"
        grep -qx 'systemctl enable amneziawg-ipopts-guard.service' "$T/calls"
        grep -qx 'systemctl restart amneziawg-ipopts-guard.service' "$T/calls" || { echo "$f: $(_calls)"; return 1; }
        ls -A "$T/sbin" "$T/units" | grep -q '\.new$' && { echo "$f: stage left"; return 1; }
        # The refresh on a second run keeps exactly one rule.
        run bash "$T/deploy.sh"
        [[ "$output" == *"RC=0"* ]] && [ "$(cat "$T/rules")" = 1 ] || { echo "$f second: $output rules=$(cat "$T/rules")"; return 1; }
    done
}

@test "deploy: a rule that is not in place after the start is a failure, not a success" {
    local f
    for f in "${INSTALLERS[@]}"; do
        rm -rf "${T:?}/sbin" "$T/units" "$T/calls" "$T/rules"
        _deploy_driver "$f"; _systemctl_stub; touch "$T/ipt.fail"
        run bash "$T/deploy.sh"
        [[ "$output" == *"RC=1"* ]] || { echo "$f: $output"; return 1; }
        [[ "$output" == *"WARN: "*"amneziawg-ipopts-guard"* ]] || { echo "$f: $output"; return 1; }
        rm -f "$T/ipt.fail"
    done
}

@test "deploy: a failed enable or daemon-reload is a failure" {
    local f s
    for f in "${INSTALLERS[@]}"; do
        for s in enable daemon-reload; do
            rm -rf "${T:?}/sbin" "$T/units" "$T/calls" "$T/rules" "$T"/sc.fail.*
            _deploy_driver "$f"; _systemctl_stub; touch "$T/sc.fail.$s"
            run bash "$T/deploy.sh"
            [[ "$output" == *"RC=1"* ]] || { echo "$f $s: $output"; return 1; }
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
        echo 'update_state() { :; }; install_packages() { :; }'
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
        [[ "$output" == *"RC=0"* ]] && [ "$(_calls | tr '\n' ' ')" = "ufw guard " ] || { echo "$f: $output | $(_calls)"; return 1; }
        rm -f "$T/calls"; touch "$T/deploy.fail"
        run bash "$T/s4.sh"
        [[ "$output" == *"RC=0"* ]] || { echo "$f fail: $output"; return 1; }
        [[ "$output" == *"WARN: "*"--ipopts-guard"* ]] || { echo "$f fail: $output"; return 1; }
    done
}

@test "step 4 with --no-tweaks: no guard, a warning that names --ipopts-guard" {
    local f
    for f in "${INSTALLERS[@]}"; do
        rm -f "$T/calls"; _step4_driver "$f"
        NT=1 run bash "$T/s4.sh"
        [[ "$output" == *"RC=0"* ]] || { echo "$f: $output"; return 1; }
        [ -z "$(_calls)" ] || { echo "$f: $(_calls)"; return 1; }
        [[ "$output" == *"WARN: "*"--ipopts-guard"* ]] || { echo "$f: $output"; return 1; }
    done
}

@test "uninstall stops the guard and removes its unit and helper" {
    local f body
    for f in "${INSTALLERS[@]}"; do
        body=$(_fn "$f" step_uninstall)
        grep -qF 'systemctl disable --now amneziawg-ipopts-guard.service' <<<"$body" || { echo "$f: no disable"; return 1; }
        grep -qF '/usr/local/sbin/amneziawg-ipopts-guard stop' <<<"$body" || { echo "$f: no stop"; return 1; }
        grep -qF '/etc/systemd/system/amneziawg-ipopts-guard.service' <<<"$body" || { echo "$f: unit not removed"; return 1; }
        grep -qE '^[[:space:]]+/usr/local/sbin/amneziawg-ipopts-guard \\$' <<<"$body" || { echo "$f: helper not removed"; return 1; }
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

@test "check: check_server calls the report" {
    local m
    for m in "${MANAGERS[@]}"; do
        _fn "$m" check_server | grep -qx '    _ipopts_guard_report' || { echo "$m"; return 1; }
    done
}
