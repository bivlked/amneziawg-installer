#!/usr/bin/env bats
# Issue #175 - command-surface audit fixes.
#
# 1. Stale setup_state=7/99 + config-affecting CLI flags: initialize_setup
#    must roll back to step 4 so firewall + configs are regenerated;
#    previously the loop jumped straight to step 7 and the new values lived
#    only in awgsetup_cfg.init while awg0.conf kept the old ones.

# ---------------------------------------------------------------------------
# Fix 1: resume rollback guard
# ---------------------------------------------------------------------------

@test "issue #175/1: RU/EN installer rolls back stale state>4 to step 4 on config CLI flags" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        # The guard must exist between state load and end of initialize_setup:
        # a current_step>4 check that considers CLI overrides and resets to 4.
        run grep -A20 'current_step > 4' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ]
        [[ "$output" == *'current_step=4'* ]]
        [[ "$output" == *'update_state 4'* ]]
    done
}

@test "issue #175/1: rollback guard covers every config-affecting CLI override" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        block=$(awk '/current_step > 4/,/update_state 4/' "$BATS_TEST_DIRNAME/../$f")
        for var in CLI_PORT CLI_SUBNET CLI_SSH_PORT CLI_ROUTING_MODE CLI_ENDPOINT \
                   CLI_DISABLE_IPV6 CLI_ALLOW_IPV6_TUNNEL CLI_PRESET CLI_JC CLI_JMIN \
                   CLI_JMAX CLI_NO_CPS; do
            [[ "$block" == *"$var"* ]] || {
                echo "missing $var in $f rollback guard" >&2
                return 1
            }
        done
    done
}

@test "issue #175/1: guard sits inside initialize_setup after the state load" {
    # The reset must happen after STATE_FILE is read (otherwise current_step
    # is not yet known) and before the main step loop consumes it.
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        state_line=$(grep -n 'current_step=$(cat "$STATE_FILE")' "$BATS_TEST_DIRNAME/../$f" | head -1 | cut -d: -f1)
        guard_line=$(grep -n 'current_step > 4' "$BATS_TEST_DIRNAME/../$f" | head -1 | cut -d: -f1)
        [ -n "$state_line" ] && [ -n "$guard_line" ]
        [ "$guard_line" -gt "$state_line" ]
    done
}

# ---------------------------------------------------------------------------
# Fix 2: stale UFW rule cleanup on port change
# ---------------------------------------------------------------------------

@test "issue #175/2: RU/EN installer captures the config port before the CLI override" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        prev_line=$(grep -n '_cfg_awg_port="$AWG_PORT"' "$BATS_TEST_DIRNAME/../$f" | head -1 | cut -d: -f1)
        # Anchor on the override assignment (skip the parser's --port= line).
        override_line=$(grep -n 'AWG_PORT=${CLI_PORT:-$AWG_PORT}' "$BATS_TEST_DIRNAME/../$f" | head -1 | cut -d: -f1)
        [ -n "$prev_line" ] && [ -n "$override_line" ]
        [ "$prev_line" -lt "$override_line" ]
    done
}

@test "issue #175/2: RU/EN setup_improved_firewall deletes the old port rule on change" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        block=$(awk '/^setup_improved_firewall\(\)/,/^}/' "$BATS_TEST_DIRNAME/../$f")
        [[ "$block" == *'ufw delete allow "${PREV_AWG_PORT}/udp"'* ]]
        # Guarded: numeric check + only when the port actually changed.
        [[ "$block" == *'"$PREV_AWG_PORT" != "$AWG_PORT"'* ]]
        [[ "$block" == *'^[0-9]+$'* ]]
    done
}

@test "issue #175/2 functional: firewall block deletes old rule only when port changed" {
    # Extract the deletion guard and run it with a stubbed ufw to verify both
    # directions: changed port -> delete called; same port -> no delete.
    local guard
    guard=$(awk '/Смена порта при переустановке/,/^    fi$/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh" | grep -v '^    #')
    [ -n "$guard" ]

    run bash -c '
        calls_file=$(mktemp)
        ufw() { echo "$*" >> "$calls_file"; return 0; }
        log() { :; }; log_warn() { :; }
        PREV_AWG_PORT=51820; AWG_PORT=443
        '"$guard"'
        PREV_AWG_PORT=443; AWG_PORT=443
        '"$guard"'
        PREV_AWG_PORT=""; AWG_PORT=443
        '"$guard"'
        cat "$calls_file"; rm -f "$calls_file"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *'delete allow 51820/udp'* ]]
    # Exactly one delete call: same-port and empty-prev runs must not delete.
    [ "$(grep -c 'delete allow' <<< "$output")" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Fix 2 (PR #176 review): PREV_AWG_PORT must survive the step-1/step-2 reboots.
# A plain shell variable dies at request_reboot, so the pending delete is
# persisted in awgsetup_cfg.init and removed only after a successful
# ufw delete.
# ---------------------------------------------------------------------------

@test "issue #175/2 reboot: RU/EN installer persists PREV_AWG_PORT into the saved config" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        # The save block must append the key to the temp config before mv,
        # guarded by a numeric check.
        block=$(grep -B1 -A1 'echo "export PREV_AWG_PORT=' "$BATS_TEST_DIRNAME/../$f")
        [[ "$block" == *'"$PREV_AWG_PORT" =~ ^[0-9]+$'* ]]
        [[ "$block" == *'>> "$temp_conf"'* ]]
    done
}

@test "issue #175/2 reboot: RU/EN safe_load_config whitelists PREV_AWG_PORT in all four copies" {
    for f in awg_common.sh awg_common_en.sh install_amneziawg.sh install_amneziawg_en.sh; do
        run grep -c '|PREV_AWG_PORT' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ]
        [ "$output" -ge 1 ]
    done
}

@test "issue #175/2 reboot functional: RU/EN awg_common safe_load_config exports PREV_AWG_PORT" {
    for f in awg_common.sh awg_common_en.sh; do
        run bash -c '
            log() { :; }; log_warn() { :; }; log_error() { :; }; log_debug() { :; }
            AWG_DIR=$(mktemp -d); export AWG_DIR
            source "'"$BATS_TEST_DIRNAME"'/../'"$f"'"
            cfg=$(mktemp)
            printf "export AWG_PORT=443\nexport PREV_AWG_PORT=51820\n" > "$cfg"
            unset PREV_AWG_PORT
            safe_load_config "$cfg"
            rc_val="${PREV_AWG_PORT:-UNSET}"
            rm -rf "$cfg" "$AWG_DIR"
            echo "PREV_AWG_PORT=$rc_val"
        '
        [ "$status" -eq 0 ]
        [[ "$output" == *'PREV_AWG_PORT=51820'* ]]
    done
}

@test "issue #175/2 reboot functional: capture logic keeps a pending delete across resumed runs" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        snippet=$(awk '/PREV_AWG_PORT="\$\{PREV_AWG_PORT:-\}"/,/"\$PREV_AWG_PORT" == "\$AWG_PORT" \]\]; then PREV_AWG_PORT=""; fi/' \
            "$BATS_TEST_DIRNAME/../$f" | grep -v '^[[:space:]]*#')
        [ -n "$snippet" ]
        run bash -c '
            # Run 1: a finished install (config port 51820), --port=443.
            PREV_AWG_PORT=""; config_exists=1; AWG_PORT=51820; CLI_PORT=443
            '"$snippet"'
            echo "run1=$PREV_AWG_PORT"
            # Run 2 (after reboot): the config already holds 443, the pending
            # value 51820 arrives via safe_load_config and must survive.
            PREV_AWG_PORT=51820; config_exists=1; AWG_PORT=443; CLI_PORT=""
            '"$snippet"'
            echo "run2=$PREV_AWG_PORT"
            # Port changed back before the delete happened: the stale pending
            # value must not linger once it equals the active port.
            PREV_AWG_PORT=443; config_exists=1; AWG_PORT=443; CLI_PORT=""
            '"$snippet"'
            echo "run3=${PREV_AWG_PORT:-EMPTY}"
        '
        [ "$status" -eq 0 ]
        [[ "$output" == *'run1=51820'* ]]
        [[ "$output" == *'run2=51820'* ]]
        [[ "$output" == *'run3=EMPTY'* ]]
    done
}

@test "issue #175/2 reboot: RU/EN firewall clears the persisted key only on successful delete" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        block=$(awk '/^setup_improved_firewall\(\)/,/^}/' "$BATS_TEST_DIRNAME/../$f")
        # The sed cleanup must live inside the success branch of ufw delete.
        [[ "$block" == *"sed -i '/^export PREV_AWG_PORT=/d'"* ]]
        success_branch=$(printf '%s\n' "$block" \
            | awk '/if ufw delete allow "\$\{PREV_AWG_PORT\}\/udp"/,/else/')
        [[ "$success_branch" == *'sed -i'* ]]
    done
}

@test "issue #175/2 reboot functional: failed ufw delete keeps the persisted key for a retry" {
    # Extract the deletion guard and run it against a real config file with a
    # stubbed ufw: success removes the key, failure leaves it in place.
    local guard
    guard=$(awk '/Смена порта при переустановке/,/^    fi$/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh" | grep -v '^    #')
    [ -n "$guard" ]

    # The cleanup uses GNU sed -i syntax (the scripts target Linux servers).
    sed --version >/dev/null 2>&1 || skip "GNU sed required"

    run bash -c '
        log() { :; }; log_warn() { :; }
        CONFIG_FILE=$(mktemp)
        echo "export PREV_AWG_PORT=51820" > "$CONFIG_FILE"
        # Failure: the key must survive for the next run.
        ufw() { return 1; }
        PREV_AWG_PORT=51820; AWG_PORT=443
        '"$guard"'
        if grep -q "^export PREV_AWG_PORT=" "$CONFIG_FILE"; then
            echo "fail-branch=kept"
        else
            echo "fail-branch=gone"
        fi
        # Success: the key must be removed.
        ufw() { return 0; }
        PREV_AWG_PORT=51820; AWG_PORT=443
        '"$guard"'
        if grep -q "^export PREV_AWG_PORT=" "$CONFIG_FILE"; then
            echo "success-branch=kept"
        else
            echo "success-branch=gone"
        fi
        rm -f "$CONFIG_FILE"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *'fail-branch=kept'* ]]
    [[ "$output" == *'success-branch=gone'* ]]
}

# ---------------------------------------------------------------------------
# Fix 3: honest repair-module (rc=2 = module OK, service down)
# ---------------------------------------------------------------------------

# Run ensure_amneziawg_kernel_module in an isolated bash with stubbed
# environment: module "loaded" (lsmod fast-path), service start outcome
# controlled by the _ensure_awg_quick_running stub.
_run_ensure_module() {
    local svc_ok="$1" lang_file="$2"
    bash -c '
        log() { :; }; log_warn() { :; }; log_error() { :; }; log_debug() { :; }
        AWG_DIR=$(mktemp -d); export AWG_DIR
        source "'"$BATS_TEST_DIRNAME"'/../'"$lang_file"'"
        lsmod() { echo "amneziawg 16384 0"; }
        _ensure_awg_quick_running() { return '"$svc_ok"'; }
        ensure_amneziawg_kernel_module full
        rc=$?
        rm -rf "$AWG_DIR"
        exit $rc
    '
}

@test "issue #175/3 functional: RU/EN ensure_amneziawg_kernel_module full returns 2 when service fails" {
    for f in awg_common.sh awg_common_en.sh; do
        run _run_ensure_module 1 "$f"
        [ "$status" -eq 2 ]
    done
}

@test "issue #175/3 functional: RU/EN ensure_amneziawg_kernel_module full returns 0 when service runs" {
    for f in awg_common.sh awg_common_en.sh; do
        run _run_ensure_module 0 "$f"
        [ "$status" -eq 0 ]
    done
}

@test "issue #175/3 functional: module-only mode ignores the service entirely" {
    for f in awg_common.sh awg_common_en.sh; do
        run bash -c '
            log() { :; }; log_warn() { :; }; log_error() { :; }; log_debug() { :; }
            AWG_DIR=$(mktemp -d); export AWG_DIR
            source "'"$BATS_TEST_DIRNAME"'/../'"$f"'"
            lsmod() { echo "amneziawg 16384 0"; }
            _ensure_awg_quick_running() { return 1; }
            ensure_amneziawg_kernel_module module-only
            rc=$?
            rm -rf "$AWG_DIR"
            exit $rc
        '
        [ "$status" -eq 0 ]
    done
}

@test "issue #175/3: RU/EN repair-module distinguishes service failure (rc=2) from module failure" {
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        # The branch now contains a nested case (its own ;;), so bound the
        # block by the next dispatcher command instead of the first ';;'.
        block=$(awk '/repair-module\|repair\)/,/^    diagnose\)/' "$BATS_TEST_DIRNAME/../$f")
        [[ "$block" == *'_mod_rc=$?'* ]]
        [[ "$block" == *'2)'* ]]
        [[ "$block" == *'_cmd_rc=1'* ]]
    done
}

@test "issue #175/3: RU/EN add/remove tolerate rc=2 (module OK, service down) with a warning" {
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        # Both callsites must die only on rc=1 and warn on rc=2.
        [ "$(grep -c '"$_mod_rc" -eq 1' "$BATS_TEST_DIRNAME/../$f")" -eq 2 ]
        [ "$(grep -c '"$_mod_rc" -eq 2' "$BATS_TEST_DIRNAME/../$f")" -eq 2 ]
    done
}

# ---------------------------------------------------------------------------
# Fix 4: add sets _cmd_rc=1 when a requested client already exists
# ---------------------------------------------------------------------------

@test "issue #175/4: RU/EN add duplicate-skip branch flags failure via _cmd_rc" {
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        # The 'already exists' skip must set _cmd_rc=1 before continue,
        # matching remove/regen exit-code semantics for no-op names.
        # Window widened v5.21.0: the JSON results line sits between
        # _cmd_rc=1 and continue, pushing continue past the old -A6.
        block=$(grep -A8 'grep -qxF "#_Name = ${_cname}" "$SERVER_CONF_FILE"; then' "$BATS_TEST_DIRNAME/../$f" | head -10)
        [[ "$block" == *'_cmd_rc=1'* ]]
        [[ "$block" == *'continue'* ]]
    done
}

# ---------------------------------------------------------------------------
# Fix 5: NO_CPS in the awg_common safe_load_config whitelist
# ---------------------------------------------------------------------------

@test "issue #175/5 functional: RU/EN awg_common safe_load_config exports NO_CPS" {
    for f in awg_common.sh awg_common_en.sh; do
        run bash -c '
            log() { :; }; log_warn() { :; }; log_error() { :; }; log_debug() { :; }
            AWG_DIR=$(mktemp -d); export AWG_DIR
            source "'"$BATS_TEST_DIRNAME"'/../'"$f"'"
            cfg=$(mktemp)
            printf "export NO_CPS=1\nexport NO_TWEAKS=0\n" > "$cfg"
            unset NO_CPS
            safe_load_config "$cfg"
            rc_val="${NO_CPS:-UNSET}"
            rm -rf "$cfg" "$AWG_DIR"
            echo "NO_CPS=$rc_val"
        '
        [ "$status" -eq 0 ]
        [[ "$output" == *'NO_CPS=1'* ]]
    done
}

@test "issue #175/5: whitelists in installer and awg_common agree on NO_CPS" {
    for f in awg_common.sh awg_common_en.sh install_amneziawg.sh install_amneziawg_en.sh; do
        run grep -c 'NO_TWEAKS|NO_CPS|' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ]
        [ "$output" -ge 1 ]
    done
}
