#!/usr/bin/env bats
# mobile-flag / D#38 - the --mobile shorthand flag.
#
# --preset=mobile only tuned the obfuscation while the real mobile killer is
# the port (39743/udp dead on MTS, 443/udp works). --mobile = preset mobile +
# port 443 in one flag; an explicit --port wins; a contradicting --preset dies.

load test_helper

extract_resolve_mobile() {
    awk '/^resolve_mobile_flag\(\)/,/^}/' "$BATS_TEST_DIRNAME/../$1"
}

@test "mobile-flag: RU/EN installer parses --mobile into CLI_MOBILE" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run grep -F -- '--mobile)' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ]
        [[ "$output" == *'CLI_MOBILE=1'* ]]
    done
}

@test "mobile-flag: RU/EN help mentions --mobile" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run grep -c -- '--mobile' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ]
        [ "$output" -ge 2 ]   # parser + help
    done
}

@test "mobile-flag functional: --mobile sets preset mobile + port 443 when port not given" {
    fn=$(extract_resolve_mobile install_amneziawg.sh)
    [ -n "$fn" ]
    run bash -c '
        log() { :; }; die() { echo "DIE:$*"; exit 1; }
        '"$fn"'
        CLI_MOBILE=1 CLI_PRESET="" CLI_PORT=""
        resolve_mobile_flag
        echo "preset:$CLI_PRESET port:$CLI_PORT"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *'preset:mobile port:443'* ]]
}

@test "mobile-flag functional: explicit --port wins over the mobile default 443" {
    fn=$(extract_resolve_mobile install_amneziawg.sh)
    run bash -c '
        log() { :; }; die() { echo "DIE:$*"; exit 1; }
        '"$fn"'
        CLI_MOBILE=1 CLI_PRESET="" CLI_PORT=39743
        resolve_mobile_flag
        echo "preset:$CLI_PRESET port:$CLI_PORT"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *'preset:mobile port:39743'* ]]
}

@test "mobile-flag functional: --mobile dies on a contradicting --preset, tolerates --preset=mobile" {
    fn=$(extract_resolve_mobile install_amneziawg.sh)
    run bash -c '
        log() { :; }; die() { echo "DIE:$*"; exit 1; }
        '"$fn"'
        CLI_MOBILE=1 CLI_PRESET="mobile" CLI_PORT=""
        resolve_mobile_flag && echo "same-preset-ok:$CLI_PORT"
        CLI_MOBILE=1 CLI_PRESET="default" CLI_PORT=""
        resolve_mobile_flag
        echo "unreachable"
    '
    [[ "$output" == *'same-preset-ok:443'* ]]
    [[ "$output" == *'DIE:'* ]]
    [[ "$output" != *'unreachable'* ]]
}

@test "mobile-flag functional regression: bare --preset=mobile does NOT touch the port" {
    fn=$(extract_resolve_mobile install_amneziawg.sh)
    run bash -c '
        log() { :; }; die() { echo "DIE:$*"; exit 1; }
        '"$fn"'
        CLI_MOBILE=0 CLI_PRESET="mobile" CLI_PORT=""
        resolve_mobile_flag
        echo "preset:$CLI_PRESET port:[$CLI_PORT]"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *'preset:mobile port:[]'* ]]
}

@test "mobile-flag: RU/EN resolve_mobile_flag bodies are structurally identical (code lines)" {
    ru=$(awk '/^resolve_mobile_flag\(\)/,/^}/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh" | grep -vE '^\s*(#|log |die )')
    en=$(awk '/^resolve_mobile_flag\(\)/,/^}/' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh" | grep -vE '^\s*(#|log |die )')
    [ -n "$ru" ]
    [ "$ru" = "$en" ]
}

@test "mobile-flag: resolve_mobile_flag is called before the CLI port override (RU/EN)" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        # the call must appear before AWG_PORT=${CLI_PORT:-...} inside initialize_setup
        call_line=$(grep -n '^    resolve_mobile_flag$' "$BATS_TEST_DIRNAME/../$f" | head -1 | cut -d: -f1)
        port_line=$(grep -n 'AWG_PORT=${CLI_PORT:-\$AWG_PORT}' "$BATS_TEST_DIRNAME/../$f" | head -1 | cut -d: -f1)
        [ -n "$call_line" ] && [ -n "$port_line" ]
        [ "$call_line" -lt "$port_line" ]
    done
}
