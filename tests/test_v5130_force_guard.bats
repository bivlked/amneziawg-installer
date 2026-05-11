#!/usr/bin/env bats
# v5.13.0 idempotency / --force safety guard (MyAI-cq9g, Issue #78).
#
# Background: re-running the installer on a configured server silently
# repeats Step 1 (sysctl/swap/BBR, possible kernel upgrade + reboot loop)
# and Step 7 (service restart, drops live handshakes). Server keys,
# peers, and obfuscation parameters survive a re-run, but the user
# expects an upfront "already installed" message.
#
# v5.13.0 fix: idempotency guard at the start of the main loop —
# checks $SERVER_CONF_FILE existence + awg-quick@awg0 active, and aborts
# unless --force / AWG_FORCE_REINSTALL=1 is set.

# ---------- structural: RU script ----------

@test "v5.13.0: RU install has --force flag in CLI parser" {
    grep -qE '\-\-force\|-f\).*FORCE_REINSTALL=1' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
}

@test "v5.13.0: RU install initializes FORCE_REINSTALL=0" {
    grep -qE '^FORCE_REINSTALL=0\b' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
}

@test "v5.13.0: RU install reads AWG_FORCE_REINSTALL from env" {
    grep -q 'AWG_FORCE_REINSTALL:-0' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
}

@test "v5.13.0: RU install guard checks SERVER_CONF_FILE + service active" {
    grep -q '\-f "\$SERVER_CONF_FILE"' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -q 'systemctl is-active --quiet awg-quick@awg0' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
}

@test "v5.13.0: RU install guard message mentions --force flag and ENV" {
    grep -q 'AmneziaWG уже установлен и запущен' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -q 'AWG_FORCE_REINSTALL=1' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
}

@test "v5.13.0: RU install help mentions --force" {
    grep -q -- '-f, --force' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
}

# ---------- structural: EN script ----------

@test "v5.13.0: EN install has --force flag in CLI parser" {
    grep -qE '\-\-force\|-f\).*FORCE_REINSTALL=1' \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
}

@test "v5.13.0: EN install initializes FORCE_REINSTALL=0" {
    grep -qE '^FORCE_REINSTALL=0\b' \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
}

@test "v5.13.0: EN install reads AWG_FORCE_REINSTALL from env" {
    grep -q 'AWG_FORCE_REINSTALL:-0' \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
}

@test "v5.13.0: EN install guard checks SERVER_CONF_FILE + service active" {
    grep -q '\-f "\$SERVER_CONF_FILE"' \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    grep -q 'systemctl is-active --quiet awg-quick@awg0' \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
}

@test "v5.13.0: EN install guard message is in English and mentions --force" {
    grep -q 'AmneziaWG is already installed and running' \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    grep -q 'AWG_FORCE_REINSTALL=1' \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
}

@test "v5.13.0: EN install help mentions --force" {
    grep -q -- '-f, --force' \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
}

# ---------- functional: guard decision matrix ----------

# Helper: replicate the v5.13.0 guard. Returns 0 if installer should
# proceed (and lets the caller run install), or echoes "skip" and
# returns 1 if the guard would abort.
run_guard() {
    local SERVER_CONF_FILE="$1"
    local SERVICE_ACTIVE="$2"   # 0/1
    local FORCE_REINSTALL="$3"  # 0/1
    local AWG_FORCE_REINSTALL="${4:-0}"

    # Emulate the env-var → flag bridge
    if [[ "$AWG_FORCE_REINSTALL" == "1" ]]; then
        FORCE_REINSTALL=1
    fi

    if [[ "$FORCE_REINSTALL" -ne 1 ]] && [[ -f "$SERVER_CONF_FILE" ]] \
       && [[ "$SERVICE_ACTIVE" == "1" ]]; then
        echo "skip"
        return 1
    fi
    echo "proceed"
    return 0
}

@test "v5.13.0 cq9g: clean install (no conf, no service) => proceed" {
    result=$(run_guard "/tmp/does-not-exist" 0 0 0)
    [ "$result" = "proceed" ]
}

@test "v5.13.0 cq9g: configured + active + no force => skip" {
    tmp=$(mktemp)
    result=$(run_guard "$tmp" 1 0 0) || true
    [ "$result" = "skip" ]
    rm -f "$tmp"
}

@test "v5.13.0 cq9g: configured + inactive (broken) + no force => proceed (repair flow)" {
    tmp=$(mktemp)
    result=$(run_guard "$tmp" 0 0 0)
    [ "$result" = "proceed" ]
    rm -f "$tmp"
}

@test "v5.13.0 cq9g: configured + active + --force => proceed" {
    tmp=$(mktemp)
    result=$(run_guard "$tmp" 1 1 0)
    [ "$result" = "proceed" ]
    rm -f "$tmp"
}

@test "v5.13.0 cq9g: configured + active + AWG_FORCE_REINSTALL=1 env => proceed" {
    tmp=$(mktemp)
    result=$(run_guard "$tmp" 1 0 1)
    [ "$result" = "proceed" ]
    rm -f "$tmp"
}

@test "v5.13.0 cq9g: AWG_FORCE_REINSTALL=yes (non-1) is NOT honoured (only =1)" {
    tmp=$(mktemp)
    result=$(run_guard "$tmp" 1 0 yes) || true
    # Strict =1 check — "yes" should not bypass
    [ "$result" = "skip" ]
    rm -f "$tmp"
}

# ---------- structural parity ----------

@test "v5.13.0: RU/EN install guard structure has parity" {
    ru_count=$(grep -c 'FORCE_REINSTALL' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    en_count=$(grep -c 'FORCE_REINSTALL' \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh")
    [ "$ru_count" -eq "$en_count" ]
    [ "$ru_count" -ge 4 ]   # init + CLI flag + env bridge + guard
}
