#!/usr/bin/env bats
# Oracle Cloud Ubuntu images ship their own iptables rules
# (/etc/iptables/rules.v4, loaded at boot by netfilter-persistent) that end in
# `-j REJECT --reject-with icmp-host-prohibited` in INPUT and FORWARD.
# Installing ufw removes netfilter-persistent (the ufw package Breaks it), but
# the rules are already in the kernel and stay there until the next boot. UFW
# appends its jumps at the END of the chains, below that REJECT, so right after
# the install the VPN port and the replies to clients were rejected until one
# more reboot (checked on a stand with Oracle's rules reproduced, 9 nov 2026).
#
# remove_image_reject_above_ufw() deletes exactly that REJECT when it sits
# above the first UFW jump of the chain and leaves every other rule alone.
# The tests drive it against a fake iptables that keeps the rules in a file,
# and check the whole rule list afterwards, not a count. Both RU and EN.

bats_require_minimum_version 1.5.0

RU_SCRIPT="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
EN_SCRIPT="$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"

_load_fn() {
    eval "$(awk '/^remove_image_reject_above_ufw\(\) \{/,/^\}/' "$1")"
    declare -f remove_image_reject_above_ufw >/dev/null
}

setup() {
    LOG_FILE="$BATS_TEST_TMPDIR/log"
    : > "$LOG_FILE"
    log()       { echo "INFO: $*" >> "$LOG_FILE"; }
    log_warn()  { echo "WARN: $*" >> "$LOG_FILE"; }
    log_error() { echo "ERROR: $*" >> "$LOG_FILE"; }
    log_debug() { :; }

    # Fake iptables: rules live in $IPT_STATE as `-A CHAIN ...` lines.
    #   -S CHAIN         prints the policy line and the chain's rules in order
    #   -D CHAIN spec... deletes the FIRST rule equal to `-A CHAIN spec...`
    # -w and its optional seconds argument are skipped. $IPT_FAIL_DELETE=1
    # makes every -D fail without changing the state.
    IPT_STATE="$BATS_TEST_TMPDIR/rules"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat > "$BATS_TEST_TMPDIR/bin/iptables" <<'EOF'
#!/usr/bin/env bash
while [[ "${1:-}" == "-w" ]]; do
    shift
    [[ "${1:-}" =~ ^[0-9]+$ ]] && shift
done
op="$1"; chain="$2"; shift 2
case "$op" in
    -S)
        [[ "${IPT_FAIL_LIST:-0}" == "1" ]] && exit 4
        echo "-P $chain ACCEPT"
        grep -F -- "-A $chain " "$IPT_STATE" || true
        ;;
    -D)
        [[ "${IPT_FAIL_DELETE:-0}" == "1" ]] && exit 1
        # Claims success, deletes nothing: the loop must still end.
        [[ "${IPT_NOOP_DELETE:-0}" == "1" ]] && exit 0
        want="-A $chain $*"
        out="" found=0
        while IFS= read -r line; do
            if [[ "$found" -eq 0 && "$line" == "$want" ]]; then found=1; continue; fi
            out+="$line"$'\n'
        done < "$IPT_STATE"
        [[ "$found" -eq 1 ]] || exit 1
        printf '%s' "$out" > "$IPT_STATE"
        ;;
    *) exit 2 ;;
esac
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/iptables"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    export IPT_STATE PATH

    # The image's saved rules (what netfilter-persistent loaded at boot). The
    # function only removes a REJECT that is in this file; by default both
    # Oracle lines are there.
    IMAGE_RULES_V4="$BATS_TEST_TMPDIR/rules.v4"
    printf '%s\n' '*filter' ':INPUT ACCEPT [0:0]' \
        '-A INPUT -j REJECT --reject-with icmp-host-prohibited' \
        '-A FORWARD -j REJECT --reject-with icmp-host-prohibited' 'COMMIT' > "$IMAGE_RULES_V4"
}

# The rule layout seen on the stand after `ufw --force enable` on top of
# Oracle's loaded rules (abridged: the ACCEPT rules above REJECT are kept).
_oracle_layout() {
    cat > "$IPT_STATE" <<'EOF'
-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A INPUT -p icmp -j ACCEPT
-A INPUT -i lo -j ACCEPT
-A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT
-A INPUT -j REJECT --reject-with icmp-host-prohibited
-A INPUT -j ufw-before-logging-input
-A INPUT -j ufw-before-input
-A INPUT -j ufw-after-input
-A FORWARD -j REJECT --reject-with icmp-host-prohibited
-A FORWARD -j ufw-before-logging-forward
-A FORWARD -j ufw-before-forward
-A OUTPUT -j ufw-before-logging-output
EOF
}

_expected_after_oracle() {
    cat <<'EOF'
-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A INPUT -p icmp -j ACCEPT
-A INPUT -i lo -j ACCEPT
-A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT
-A INPUT -j ufw-before-logging-input
-A INPUT -j ufw-before-input
-A INPUT -j ufw-after-input
-A FORWARD -j ufw-before-logging-forward
-A FORWARD -j ufw-before-forward
-A OUTPUT -j ufw-before-logging-output
EOF
}


_t_oracle() {
    _load_fn "$1"
    _oracle_layout
    run remove_image_reject_above_ufw
    [ "$status" -eq 0 ]
    diff <(_expected_after_oracle) "$IPT_STATE"
    # Exactly one INFO line per removed rule, naming the chain, and no warning.
    run grep -c '^INFO: .*-A INPUT -j REJECT --reject-with icmp-host-prohibited' "$LOG_FILE"
    [ "$output" = "1" ]
    run grep -c '^INFO: .*-A FORWARD -j REJECT --reject-with icmp-host-prohibited' "$LOG_FILE"
    [ "$output" = "1" ]
    run grep -c '^WARN' "$LOG_FILE"
    [ "$output" = "0" ]
}

_t_below() {
    _load_fn "$1"
    cat > "$IPT_STATE" <<'EOF'
-A INPUT -j ufw-before-logging-input
-A INPUT -j ufw-before-input
-A INPUT -j REJECT --reject-with icmp-host-prohibited
-A FORWARD -j ufw-before-forward
-A FORWARD -j REJECT --reject-with icmp-host-prohibited
EOF
    cp "$IPT_STATE" "$BATS_TEST_TMPDIR/before"
    run remove_image_reject_above_ufw
    [ "$status" -eq 0 ]
    diff "$BATS_TEST_TMPDIR/before" "$IPT_STATE"
    run grep -c 'REJECT' "$LOG_FILE"
    [ "$output" = "0" ]
}

_t_no_ufw() {
    _load_fn "$1"
    cat > "$IPT_STATE" <<'EOF'
-A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT
-A INPUT -j REJECT --reject-with icmp-host-prohibited
-A FORWARD -j REJECT --reject-with icmp-host-prohibited
EOF
    cp "$IPT_STATE" "$BATS_TEST_TMPDIR/before"
    run remove_image_reject_above_ufw
    [ "$status" -eq 0 ]
    diff "$BATS_TEST_TMPDIR/before" "$IPT_STATE"
}

_t_other_form() {
    _load_fn "$1"
    cat > "$IPT_STATE" <<'EOF'
-A INPUT -j REJECT --reject-with icmp-port-unreachable
-A INPUT -s 203.0.113.0/24 -j REJECT --reject-with icmp-host-prohibited
-A INPUT -j ufw-before-input
-A FORWARD -j DROP
-A FORWARD -j ufw-before-forward
EOF
    cp "$IPT_STATE" "$BATS_TEST_TMPDIR/before"
    run remove_image_reject_above_ufw
    [ "$status" -eq 0 ]
    diff "$BATS_TEST_TMPDIR/before" "$IPT_STATE"
    # Not even attempted: no removal and no warning in the log.
    run grep -c 'REJECT' "$LOG_FILE"
    [ "$output" = "0" ]
}

_t_duplicate() {
    _load_fn "$1"
    cat > "$IPT_STATE" <<'EOF'
-A INPUT -j REJECT --reject-with icmp-host-prohibited
-A INPUT -i lo -j ACCEPT
-A INPUT -j REJECT --reject-with icmp-host-prohibited
-A INPUT -j ufw-before-input
EOF
    run remove_image_reject_above_ufw
    [ "$status" -eq 0 ]
    diff <(printf '%s\n' '-A INPUT -i lo -j ACCEPT' '-A INPUT -j ufw-before-input') "$IPT_STATE"
}

_t_delete_fails() {
    _load_fn "$1"
    _oracle_layout
    cp "$IPT_STATE" "$BATS_TEST_TMPDIR/before"
    IPT_FAIL_DELETE=1
    export IPT_FAIL_DELETE
    run remove_image_reject_above_ufw
    [ "$status" -eq 0 ]
    diff "$BATS_TEST_TMPDIR/before" "$IPT_STATE"
    grep -qF 'WARN: ' "$LOG_FILE"
    grep -qF 'iptables -D INPUT -j REJECT --reject-with icmp-host-prohibited' "$LOG_FILE"
    grep -qF 'iptables -D FORWARD -j REJECT --reject-with icmp-host-prohibited' "$LOG_FILE"
    # One warning per chain, not one per pass.
    run grep -c '^WARN' "$LOG_FILE"
    [ "$output" = "2" ]
}

_t_no_iptables() {
    _load_fn "$1"
    _oracle_layout
    cp "$IPT_STATE" "$BATS_TEST_TMPDIR/before"
    # `command -v iptables` finds nothing.
    command() { return 1; }
    run remove_image_reject_above_ufw
    unset -f command
    [ "$status" -eq 0 ]
    diff "$BATS_TEST_TMPDIR/before" "$IPT_STATE"
}

@test "RU: Oracle layout - both REJECT rules above UFW are removed, the rest is intact" {
    _t_oracle "$RU_SCRIPT"
}

@test "RU: REJECT below the UFW jumps is left alone" {
    _t_below "$RU_SCRIPT"
}

@test "RU: no UFW jumps (UFW off) - nothing is removed" {
    _t_no_ufw "$RU_SCRIPT"
}

@test "RU: a REJECT of another form above UFW is left alone" {
    _t_other_form "$RU_SCRIPT"
}

@test "RU: two identical REJECT rules above UFW are both removed" {
    _t_duplicate "$RU_SCRIPT"
}

@test "RU: failed delete warns with the manual command and does not fail the step" {
    _t_delete_fails "$RU_SCRIPT"
}

@test "RU: iptables missing - returns 0 and changes nothing" {
    _t_no_iptables "$RU_SCRIPT"
}

@test "EN: Oracle layout - both REJECT rules above UFW are removed, the rest is intact" {
    _t_oracle "$EN_SCRIPT"
}

@test "EN: REJECT below the UFW jumps is left alone" {
    _t_below "$EN_SCRIPT"
}

@test "EN: no UFW jumps (UFW off) - nothing is removed" {
    _t_no_ufw "$EN_SCRIPT"
}

@test "EN: a REJECT of another form above UFW is left alone" {
    _t_other_form "$EN_SCRIPT"
}

@test "EN: two identical REJECT rules above UFW are both removed" {
    _t_duplicate "$EN_SCRIPT"
}

@test "EN: failed delete warns with the manual command and does not fail the step" {
    _t_delete_fails "$EN_SCRIPT"
}

@test "EN: iptables missing - returns 0 and changes nothing" {
    _t_no_iptables "$EN_SCRIPT"
}

# setup_improved_firewall must call the cleanup on both paths: when it enables
# UFW itself and when UFW was already active (rules updated, ufw reload).
_t_integration() {
    local script="$1" ufw_state="$2"
    eval "$(awk '/^detect_ssh_ports\(\) \{/,/^\}/' "$script")"
    eval "$(awk '/^remove_image_reject_above_ufw\(\) \{/,/^\}/' "$script")"
    eval "$(awk '/^setup_improved_firewall\(\) \{/,/^\}/' "$script" | sed 's#< /dev/tty##')"
    UFW_STATE="$ufw_state"
    # Like the real ufw: its jumps land at the END of the chains when it is
    # enabled or reloaded. On a fresh Oracle image they are not there before.
    ufw() {
        case "$*" in
            status*) echo "Status: $UFW_STATE" ;;
            "--force enable"|reload) _ufw_add_jumps ;;
        esac
        return 0
    }
    ip() { echo "1.1.1.1 dev eth0 src 10.0.0.1 uid 0"; }
    install_packages() { return 0; }
    touch() { return 0; }
    die() { echo "DIE: $*"; return 1; }
    AWG_PORT=39743
    AWG_DIR="$BATS_TEST_TMPDIR"
    AUTO_YES=1
    CLI_SSH_PORT=22
    export AWG_PORT AWG_DIR AUTO_YES CLI_SSH_PORT
    if [[ "$ufw_state" == "inactive" ]]; then
        # Fresh Oracle image: only Oracle's rules, no UFW jumps yet.
        _oracle_layout
        grep -v -- '-j ufw-' "$IPT_STATE" > "$IPT_STATE.new" && mv "$IPT_STATE.new" "$IPT_STATE"
    else
        _oracle_layout
    fi
    run setup_improved_firewall < /dev/null
    [ "$status" -eq 0 ]
    diff <(_expected_after_oracle) <(_by_chain)
}

# Appends UFW's jumps at the end of each chain unless they are there already.
_ufw_add_jumps() {
    local r
    for r in '-A INPUT -j ufw-before-logging-input' '-A INPUT -j ufw-before-input' \
             '-A INPUT -j ufw-after-input' '-A FORWARD -j ufw-before-logging-forward' \
             '-A FORWARD -j ufw-before-forward' '-A OUTPUT -j ufw-before-logging-output'; do
        grep -qxF -- "$r" "$IPT_STATE" || printf '%s\n' "$r" >> "$IPT_STATE"
    done
}

# The rule file ordered INPUT, FORWARD, OUTPUT (order inside a chain kept).
_by_chain() {
    local c
    for c in INPUT FORWARD OUTPUT; do grep -F -- "-A $c " "$IPT_STATE" || true; done
}

@test "RU integration: UFW enabled by the installer - Oracle REJECT removed" {
    _t_integration "$RU_SCRIPT" inactive
}

@test "RU integration: UFW already active - Oracle REJECT removed" {
    _t_integration "$RU_SCRIPT" active
}

@test "EN integration: UFW enabled by the installer - Oracle REJECT removed" {
    _t_integration "$EN_SCRIPT" inactive
}

@test "EN integration: UFW already active - Oracle REJECT removed" {
    _t_integration "$EN_SCRIPT" active
}

_t_mixed() {
    _load_fn "$1"
    cat > "$IPT_STATE" <<'EOF'
-A INPUT -j REJECT --reject-with icmp-host-prohibited
-A INPUT -j ufw-before-input
-A INPUT -j REJECT --reject-with icmp-host-prohibited
EOF
    run remove_image_reject_above_ufw
    [ "$status" -eq 0 ]
    diff <(printf '%s\n' '-A INPUT -j ufw-before-input' '-A INPUT -j REJECT --reject-with icmp-host-prohibited') "$IPT_STATE"
}

_t_list_fails() {
    _load_fn "$1"
    _oracle_layout
    cp "$IPT_STATE" "$BATS_TEST_TMPDIR/before"
    IPT_FAIL_LIST=1
    export IPT_FAIL_LIST
    run remove_image_reject_above_ufw
    [ "$status" -eq 0 ]
    diff "$BATS_TEST_TMPDIR/before" "$IPT_STATE"
    # Not silent: one warning per chain, naming the chain and the check command.
    run grep -c '^WARN' "$LOG_FILE"
    [ "$output" = "2" ]
    grep -qF 'iptables -S INPUT' "$LOG_FILE"
    grep -qF 'iptables -S FORWARD' "$LOG_FILE"
    # The exit code of iptables itself (the fake one exits 4), in either language.
    [ "$(grep -cE '(code|код) 4\)' "$LOG_FILE")" -eq 2 ]
}

_t_noop_delete() {
    _load_fn "$1"
    _oracle_layout
    IPT_NOOP_DELETE=1
    export IPT_NOOP_DELETE
    local f
    f="$(declare -f remove_image_reject_above_ufw log log_warn)"
    run timeout 20 env LOG_FILE="$LOG_FILE" IMAGE_RULES_V4="$IMAGE_RULES_V4" bash -c "$f; remove_image_reject_above_ufw"
    [ "$status" -eq 0 ]
    # The bound: exactly 5 passes per chain (each "removal" claims success),
    # then it gives up; 2 chains, 10 INFO lines.
    run grep -c '^INFO' "$LOG_FILE"
    [ "$output" = "10" ]
}

@test "RU: REJECT above and below UFW - only the one above is removed" {
    _t_mixed "$RU_SCRIPT"
}

@test "EN: REJECT above and below UFW - only the one above is removed" {
    _t_mixed "$EN_SCRIPT"
}

@test "RU: iptables -S failing is reported, nothing changes" {
    _t_list_fails "$RU_SCRIPT"
}

@test "EN: iptables -S failing is reported, nothing changes" {
    _t_list_fails "$EN_SCRIPT"
}

@test "RU: a delete that reports success but removes nothing still ends" {
    _t_noop_delete "$RU_SCRIPT"
}

@test "EN: a delete that reports success but removes nothing still ends" {
    _t_noop_delete "$EN_SCRIPT"
}

# A REJECT above UFW that is NOT in the image's saved rules may be the
# administrator's own: it is left in place, with a warning that says why VPN
# traffic is blocked and how to remove it.
_t_not_from_image() {
    _load_fn "$1"
    _oracle_layout
    cp "$IPT_STATE" "$BATS_TEST_TMPDIR/before"
    rm -f "$IMAGE_RULES_V4"
    run remove_image_reject_above_ufw
    [ "$status" -eq 0 ]
    diff "$BATS_TEST_TMPDIR/before" "$IPT_STATE"
    run grep -c '^WARN' "$LOG_FILE"
    [ "$output" = "2" ]
    grep -qF 'iptables -D INPUT -j REJECT --reject-with icmp-host-prohibited' "$LOG_FILE"
    grep -qF 'iptables -D FORWARD -j REJECT --reject-with icmp-host-prohibited' "$LOG_FILE"
    run grep -c '^INFO' "$LOG_FILE"
    [ "$output" = "0" ]
}

# Only the INPUT line is saved: INPUT is cleaned, FORWARD gets the warning.
_t_partly_from_image() {
    _load_fn "$1"
    _oracle_layout
    printf '%s\n' '*filter' '-A INPUT -j REJECT --reject-with icmp-host-prohibited' 'COMMIT' > "$IMAGE_RULES_V4"
    run remove_image_reject_above_ufw
    [ "$status" -eq 0 ]
    run grep -c -- '-A INPUT -j REJECT' "$IPT_STATE"
    [ "$output" = "0" ]
    run grep -c -- '-A FORWARD -j REJECT' "$IPT_STATE"
    [ "$output" = "1" ]
    run grep -c '^WARN' "$LOG_FILE"
    [ "$output" = "1" ]
    grep -qF 'iptables -D FORWARD -j REJECT --reject-with icmp-host-prohibited' "$LOG_FILE"
}

@test "RU: a REJECT not in the image's saved rules is left alone, with a warning" {
    _t_not_from_image "$RU_SCRIPT"
}

@test "EN: a REJECT not in the image's saved rules is left alone, with a warning" {
    _t_not_from_image "$EN_SCRIPT"
}

@test "RU: only the chain whose REJECT is saved by the image is cleaned" {
    _t_partly_from_image "$RU_SCRIPT"
}

@test "EN: only the chain whose REJECT is saved by the image is cleaned" {
    _t_partly_from_image "$EN_SCRIPT"
}
