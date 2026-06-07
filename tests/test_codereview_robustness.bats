#!/usr/bin/env bats
# Code-review findings A6 (install_expiry_cron idempotent by content) and
# A7 (restore: server-completeness check before the service stop; empty
# clients/ is a valid no-op instead of a cp crash + rollback).

load test_helper

# --- A6: install_expiry_cron is content-aware -------------------------------

@test "A6 install_expiry_cron: writes a cron pointing at the current AWG_DIR" {
    install_expiry_cron
    [ -f "$EXPIRY_CRON" ]
    grep -q "AWG_DIR=\"$AWG_DIR\"" "$EXPIRY_CRON"
}

@test "A6 install_expiry_cron: identical content is left untouched (idempotent)" {
    install_expiry_cron
    local before; before=$(cat "$EXPIRY_CRON")
    run install_expiry_cron
    [ "$status" -eq 0 ]
    [ "$(cat "$EXPIRY_CRON")" = "$before" ]
}

@test "A6 install_expiry_cron: refreshes stale paths after AWG_DIR changes" {
    install_expiry_cron
    grep -q "AWG_DIR=\"$AWG_DIR\"" "$EXPIRY_CRON"
    # Simulate a restore/migration to a new directory; the cron path is fixed but
    # its embedded AWG_DIR must be rewritten (the old early-out left it stale).
    local newdir="$TEST_DIR/moved"; mkdir -p "$newdir"
    export AWG_DIR="$newdir"
    run install_expiry_cron
    [ "$status" -eq 0 ]
    grep -q "AWG_DIR=\"$newdir\"" "$EXPIRY_CRON"
    ! grep -q "AWG_DIR=\"$TEST_DIR\"" "$EXPIRY_CRON"
}

@test "A6 source: install_expiry_cron compares content (no bare file-exists early-out)" {
    for f in awg_common.sh awg_common_en.sh; do
        run grep -E 'cmp -s "\$_cron_tmp" "\$EXPIRY_CRON"' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ] || { echo "$f: install_expiry_cron not content-aware"; false; }
    done
}

# --- A7: restore completeness + empty-clients no-op ------------------------

# Mirror of the A7 pre-stop server-completeness check (looks for the actual
# server config by basename, not just any file in server/).
server_complete_ok() {
    local td="$1"
    [[ -f "$td/server/$(basename "$SERVER_CONF_FILE")" ]]
}

# Mirror of the A7-guarded clients-restore fragment.
restore_clients_fragment() {
    local td="$1"
    if [[ -d "$td/clients" ]]; then
        rm -f "$AWG_DIR"/*.conf "$AWG_DIR"/*.png "$AWG_DIR"/*.vpnuri 2>/dev/null || true
        if compgen -G "$td/clients/*" > /dev/null; then
            cp -a "$td/clients/"* "$AWG_DIR/" || return 1
        fi
    fi
    return 0
}

@test "A7 server completeness: empty, missing, or non-config server/ is rejected" {
    local td="$TEST_DIR/x"
    mkdir -p "$td/server"            # present but empty
    run server_complete_ok "$td"
    [ "$status" -ne 0 ]
    echo readme > "$td/server/README"   # a file, but not the server config
    run server_complete_ok "$td"
    [ "$status" -ne 0 ]
    rm -rf "$td/server"             # missing entirely
    run server_complete_ok "$td"
    [ "$status" -ne 0 ]
}

@test "A7 server completeness: a server/ holding the actual config passes" {
    local td="$TEST_DIR/x"
    mkdir -p "$td/server"
    echo "[Interface]" > "$td/server/$(basename "$SERVER_CONF_FILE")"
    run server_complete_ok "$td"
    [ "$status" -eq 0 ]
}

@test "A7 clients: empty clients/ is a no-op (no crash, no leftover)" {
    local td="$TEST_DIR/x"
    mkdir -p "$td/clients"
    echo stale > "$AWG_DIR/old.conf"
    run restore_clients_fragment "$td"
    [ "$status" -eq 0 ]
    [ ! -e "$AWG_DIR/old.conf" ]     # prune still happened (clean replace)
}

@test "A7 clients: populated clients/ is copied" {
    local td="$TEST_DIR/x"
    mkdir -p "$td/clients"
    echo "cfg" > "$td/clients/bob.conf"
    run restore_clients_fragment "$td"
    [ "$status" -eq 0 ]
    [ -f "$AWG_DIR/bob.conf" ]
}

@test "A7 source: server completeness is checked BEFORE the service stop" {
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        local check_line stop_line
        check_line=$(grep -n '! -f "\$td/server/\$_srv_base"' "$BATS_TEST_DIRNAME/../$f" | head -1 | cut -d: -f1)
        stop_line=$(grep -n 'systemctl stop awg-quick@awg0' "$BATS_TEST_DIRNAME/../$f" | head -1 | cut -d: -f1)
        [ -n "$check_line" ] || { echo "$f: no server config completeness check"; false; }
        [ "$check_line" -lt "$stop_line" ] || { echo "$f: completeness check not before stop"; false; }
    done
}

@test "A7 source: clients copy is guarded by compgen in both scripts" {
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        run grep -E 'compgen -G "\$td/clients/\*"' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ] || { echo "$f: clients copy not compgen-guarded"; false; }
    done
}
