#!/usr/bin/env bats
# v5.13.0 bundled robustness fixes (rolled in alongside PPA noble fallback):
#
# 1. MyAI-rcgr — manage_amneziawg.sh log_msg now routes WARN to stderr
#    (matching install_amneziawg.sh:110+). Until v5.12.1, manage sent only
#    ERROR to stderr and dropped WARN into stdout, which broke CI/automation
#    that captured stdout for data only.
#
# 2. MyAI-i31a — install_amneziawg.sh optimize_swap now uses a field-aware
#    awk check on /etc/fstab instead of a substring grep. The old
#    `grep -q '/swapfile' /etc/fstab` matched commented lines and partial
#    names (e.g. `/swapfile.bak`), which on a re-run could skip adding a
#    valid entry — swap then wouldn't mount on reboot.

# ===========================================================================
# rcgr: manage log_msg routes WARN to stderr (RU + EN)
# ===========================================================================

@test "v5.13.0 rcgr: RU manage log_msg routes WARN to stderr" {
    block=$(awk '/^log_msg\(\) \{/,/^\}/' \
        "$BATS_TEST_DIRNAME/../manage_amneziawg.sh")
    [[ "$block" == *'"$type" == "ERROR" || "$type" == "WARN"'* ]]
    # The body that goes to stderr must be the same printf with >&2 redirect.
    [[ "$block" == *'>&2'* ]]
}

@test "v5.13.0 rcgr: EN manage log_msg routes WARN to stderr" {
    block=$(awk '/^log_msg\(\) \{/,/^\}/' \
        "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh")
    [[ "$block" == *'"$type" == "ERROR" || "$type" == "WARN"'* ]]
    [[ "$block" == *'>&2'* ]]
}

@test "v5.13.0 rcgr: RU and EN manage log_msg are in sync" {
    ru=$(awk '/^log_msg\(\) \{/,/^\}/' \
        "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" \
        | grep -c '"$type" == "ERROR" || "$type" == "WARN"')
    en=$(awk '/^log_msg\(\) \{/,/^\}/' \
        "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh" \
        | grep -c '"$type" == "ERROR" || "$type" == "WARN"')
    [ "$ru" -eq 1 ]
    [ "$en" -eq 1 ]
}

@test "v5.13.0 rcgr: manage log_msg now matches install log_msg behaviour" {
    # install_amneziawg.sh already routed WARN to stderr (line ~110).
    # manage must now do the same for consistency.
    install_block=$(awk '/^log_msg\(\) \{/,/^\}/' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    manage_block=$(awk '/^log_msg\(\) \{/,/^\}/' \
        "$BATS_TEST_DIRNAME/../manage_amneziawg.sh")
    [[ "$install_block" == *'WARN'*'>&2'* ]] || [[ "$install_block" == *'"$type" == "ERROR" || "$type" == "WARN"'* ]]
    [[ "$manage_block" == *'WARN'*'>&2'* ]] || [[ "$manage_block" == *'"$type" == "ERROR" || "$type" == "WARN"'* ]]
}

# ---- functional: simulate log_msg WARN goes to stderr ----

# Replicate the v5.13.0 manage log_msg branch (no $LOG_FILE side effect).
run_warn_routed() {
    local type="$1" msg="$2"
    local entry="[ts] $type: $msg"
    if [[ "$type" == "ERROR" || "$type" == "WARN" ]]; then
        printf '%s\n' "$entry" >&2
    else
        printf '%s\n' "$entry"
    fi
}

@test "v5.13.0 rcgr functional: WARN goes to stderr, not stdout" {
    out=$(run_warn_routed WARN "test warning" 2>/dev/null)
    err=$(run_warn_routed WARN "test warning" 2>&1 1>/dev/null)
    [ -z "$out" ]
    [[ "$err" == *"WARN: test warning"* ]]
}

@test "v5.13.0 rcgr functional: ERROR still goes to stderr" {
    out=$(run_warn_routed ERROR "test error" 2>/dev/null)
    err=$(run_warn_routed ERROR "test error" 2>&1 1>/dev/null)
    [ -z "$out" ]
    [[ "$err" == *"ERROR: test error"* ]]
}

@test "v5.13.0 rcgr functional: INFO still goes to stdout" {
    out=$(run_warn_routed INFO "test info" 2>/dev/null)
    err=$(run_warn_routed INFO "test info" 2>&1 1>/dev/null)
    [[ "$out" == *"INFO: test info"* ]]
    [ -z "$err" ]
}

# ===========================================================================
# i31a: install fstab swap check uses awk field-match (RU + EN)
# ===========================================================================

@test "v5.13.0 i31a: RU install uses awk field check for /swapfile in fstab" {
    grep -q "awk '!/\^\[\[:space:\]\]\*#/ && \\\$1 == \"/swapfile\" && \\\$3 == \"swap\"" \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    # Old substring grep must be gone.
    ! grep -q "grep -q '/swapfile' /etc/fstab" \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
}

@test "v5.13.0 i31a: EN install uses awk field check for /swapfile in fstab" {
    grep -q "awk '!/\^\[\[:space:\]\]\*#/ && \\\$1 == \"/swapfile\" && \\\$3 == \"swap\"" \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    ! grep -q "grep -q '/swapfile' /etc/fstab" \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
}

# ---- functional: simulate the awk check on various fstab contents ----

check_fstab_has_swap() {
    awk '!/^[[:space:]]*#/ && $1 == "/swapfile" && $3 == "swap" {found=1} END {exit !(found+0)}' "$1"
}

@test "v5.13.0 i31a: valid /swapfile entry detected (returns 0)" {
    tmp=$(mktemp)
    cat > "$tmp" <<EOF
UUID=abc-123 / ext4 defaults 0 1
/swapfile none swap sw 0 0
EOF
    check_fstab_has_swap "$tmp"
    rm -f "$tmp"
}

@test "v5.13.0 i31a: commented /swapfile NOT detected (returns 1)" {
    tmp=$(mktemp)
    cat > "$tmp" <<EOF
UUID=abc-123 / ext4 defaults 0 1
# Old entry: /swapfile none swap sw 0 0
EOF
    run check_fstab_has_swap "$tmp"
    [ "$status" -ne 0 ]
    rm -f "$tmp"
}

@test "v5.13.0 i31a: partial name /swapfile.bak NOT detected (returns 1)" {
    tmp=$(mktemp)
    cat > "$tmp" <<EOF
UUID=abc-123 / ext4 defaults 0 1
/swapfile.bak none swap sw 0 0
EOF
    run check_fstab_has_swap "$tmp"
    [ "$status" -ne 0 ]
    rm -f "$tmp"
}

@test "v5.13.0 i31a: indented /swapfile entry still detected" {
    tmp=$(mktemp)
    cat > "$tmp" <<EOF
UUID=abc-123 / ext4 defaults 0 1
   /swapfile none swap sw 0 0
EOF
    check_fstab_has_swap "$tmp"
    rm -f "$tmp"
}

@test "v5.13.0 i31a: indented comment NOT confusing the parser" {
    tmp=$(mktemp)
    cat > "$tmp" <<EOF
UUID=abc-123 / ext4 defaults 0 1
   # /swapfile none swap sw 0 0
EOF
    run check_fstab_has_swap "$tmp"
    [ "$status" -ne 0 ]
    rm -f "$tmp"
}

@test "v5.13.0 i31a: empty fstab returns 1 (no entry)" {
    tmp=$(mktemp)
    : > "$tmp"
    run check_fstab_has_swap "$tmp"
    [ "$status" -ne 0 ]
    rm -f "$tmp"
}

@test "v5.13.0 i31a: /swapfile with wrong type (not swap) NOT detected" {
    # Edge: someone has a file at /swapfile mounted as ext4 binding. Our
    # check requires $3 == "swap" so this should not match.
    tmp=$(mktemp)
    cat > "$tmp" <<EOF
/swapfile /mnt/foo ext4 defaults 0 0
EOF
    run check_fstab_has_swap "$tmp"
    [ "$status" -ne 0 ]
    rm -f "$tmp"
}
