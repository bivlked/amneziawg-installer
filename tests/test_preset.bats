#!/usr/bin/env bats
# Tests for --preset and --jc/--jmin/--jmax CLI overrides
# Tests generate_awg_params() preset logic extracted from install_amneziawg.sh
# shellcheck disable=SC2034,SC2154  # CLI_* vars consumed by sourced functions; AWG_* set at runtime

load test_helper

# Source rand_range and generate_awg_h_ranges from installer
# (these are defined before generate_awg_params in install_amneziawg.sh)
setup() {
    TEST_DIR=$(mktemp -d)
    export AWG_DIR="$TEST_DIR"
    export CONFIG_FILE="$TEST_DIR/awgsetup_cfg.init"
    export SERVER_CONF_FILE="$TEST_DIR/awg0.conf"
    export KEYS_DIR="$TEST_DIR/keys"
    export EXPIRY_DIR="$TEST_DIR/expiry"
    mkdir -p "$KEYS_DIR" "$EXPIRY_DIR"

    log()       { :; }
    log_warn()  { :; }
    log_error() { :; }
    log_debug() { :; }
    die() { echo "DIE: $*" >&2; exit 1; }
    export -f log log_warn log_error log_debug die

    source "$BATS_TEST_DIRNAME/../awg_common.sh"

    # Source only the functions we need from installer (validators + rand_range + generate)
    # Extract them via eval to avoid running the installer's main flow
    eval "$(sed -n '/^rand_range()/,/^}/p' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")"
    eval "$(sed -n '/^validate_jc_value()/,/^}/p' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")"
    eval "$(sed -n '/^validate_junk_size()/,/^}/p' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")"
    eval "$(sed -n '/^generate_awg_h_ranges()/,/^}/p' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")"
    eval "$(sed -n '/^generate_cps_i1()/,/^}/p' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")"
    eval "$(sed -n '/^generate_awg_params()/,/^}/p' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")"
}

teardown() {
    rm -rf "$TEST_DIR"
    unset CLI_PRESET CLI_JC CLI_JMIN CLI_JMAX
}

# --- Default preset ---

@test "preset default: Jc in range 3-6" {
    unset CLI_PRESET CLI_JC CLI_JMIN CLI_JMAX
    generate_awg_params
    [[ "$AWG_Jc" -ge 3 ]] && [[ "$AWG_Jc" -le 6 ]]
}

@test "preset default: Jmin in range 40-89" {
    unset CLI_PRESET CLI_JC CLI_JMIN CLI_JMAX
    generate_awg_params
    [[ "$AWG_Jmin" -ge 40 ]] && [[ "$AWG_Jmin" -le 89 ]]
}

@test "preset default: Jmax >= Jmin" {
    unset CLI_PRESET CLI_JC CLI_JMIN CLI_JMAX
    generate_awg_params
    [[ "$AWG_Jmax" -ge "$AWG_Jmin" ]]
}

@test "preset default: AWG_PRESET set to 'default'" {
    unset CLI_PRESET CLI_JC CLI_JMIN CLI_JMAX
    generate_awg_params
    [ "$AWG_PRESET" = "default" ]
}

# --- Mobile preset ---

@test "preset mobile: Jc fixed at 3" {
    CLI_PRESET=mobile
    unset CLI_JC CLI_JMIN CLI_JMAX
    generate_awg_params
    [ "$AWG_Jc" -eq 3 ]
}

@test "preset mobile: Jmin in range 30-50" {
    CLI_PRESET=mobile
    unset CLI_JC CLI_JMIN CLI_JMAX
    generate_awg_params
    [[ "$AWG_Jmin" -ge 30 ]] && [[ "$AWG_Jmin" -le 50 ]]
}

@test "preset mobile: Jmax <= Jmin + 80" {
    CLI_PRESET=mobile
    unset CLI_JC CLI_JMIN CLI_JMAX
    generate_awg_params
    [[ "$AWG_Jmax" -le $((AWG_Jmin + 80)) ]]
}

@test "preset mobile: AWG_PRESET set to 'mobile'" {
    CLI_PRESET=mobile
    unset CLI_JC CLI_JMIN CLI_JMAX
    generate_awg_params
    [ "$AWG_PRESET" = "mobile" ]
}

# --- CLI overrides ---

@test "override: --jc=5 overrides preset default" {
    unset CLI_PRESET CLI_JMIN CLI_JMAX
    CLI_JC=5
    generate_awg_params
    [ "$AWG_Jc" -eq 5 ]
}

@test "override: --jc=5 overrides preset mobile" {
    CLI_PRESET=mobile
    CLI_JC=5
    unset CLI_JMIN CLI_JMAX
    generate_awg_params
    [ "$AWG_Jc" -eq 5 ]
}

@test "override: --jmin=100 --jmax=200" {
    unset CLI_PRESET CLI_JC
    CLI_JMIN=100
    CLI_JMAX=200
    generate_awg_params
    [ "$AWG_Jmin" -eq 100 ]
    [ "$AWG_Jmax" -eq 200 ]
}

# --- Validation ---

@test "validate: --jc=0 rejected" {
    run validate_jc_value "0"
    [ "$status" -ne 0 ]
}

@test "validate: --jc=abc rejected" {
    run validate_jc_value "abc"
    [ "$status" -ne 0 ]
}

@test "validate: --jc=128 accepted" {
    run validate_jc_value "128"
    [ "$status" -eq 0 ]
}

@test "validate: --jmin=1281 rejected" {
    run validate_junk_size "1281"
    [ "$status" -ne 0 ]
}

@test "validate: --jmin=0 accepted" {
    run validate_junk_size "0"
    [ "$status" -eq 0 ]
}

@test "validate: unknown preset rejected" {
    CLI_PRESET=stealth
    unset CLI_JC CLI_JMIN CLI_JMAX
    run generate_awg_params
    [ "$status" -ne 0 ]
}

@test "validate: Jmax < Jmin rejected" {
    unset CLI_PRESET CLI_JC
    CLI_JMIN=200
    CLI_JMAX=100
    run generate_awg_params
    [ "$status" -ne 0 ]
}

# --- S-padding size collisions (v5.24.0) ---
#
# Итоговый размер пакета = размер сообщения + свой S-паддинг. Совпадение
# размеров у двух типов сообщений даёт DPI стабильный признак, ради устранения
# которого паддинги и нужны. Размеры: init 148, response 92, cookie reply 64.

@test "S-collisions: S2 != S1 + 56 (init vs response), 200 прогонов" {
    unset CLI_PRESET CLI_JC CLI_JMIN CLI_JMAX
    local i
    for ((i = 0; i < 200; i++)); do
        generate_awg_params
        if [[ $((AWG_S1 + 56)) -eq "$AWG_S2" ]]; then
            echo "коллизия init/response на прогоне $i: S1=$AWG_S1 S2=$AWG_S2"
            return 1
        fi
    done
}

@test "S-collisions: S3 != S2 + 28 (response vs cookie), 200 прогонов" {
    unset CLI_PRESET CLI_JC CLI_JMIN CLI_JMAX
    local i
    for ((i = 0; i < 200; i++)); do
        generate_awg_params
        if [[ $((AWG_S2 + 28)) -eq "$AWG_S3" ]]; then
            echo "коллизия response/cookie на прогоне $i: S2=$AWG_S2 S3=$AWG_S3"
            return 1
        fi
    done
}

@test "S-collisions: S3 != S1 + 84 (init vs cookie) недостижима по диапазонам" {
    unset CLI_PRESET CLI_JC CLI_JMIN CLI_JMAX
    generate_awg_params
    # S1 минимум 15 -> S1+84 минимум 99; S3 максимум 55. Цикл не нужен, но
    # если кто-то расширит диапазоны, этот тест первым покажет, что нужен.
    [[ $((AWG_S1 + 84)) -gt 55 ]]
}

@test "S-collisions: диапазоны S1-S4 не съехали" {
    unset CLI_PRESET CLI_JC CLI_JMIN CLI_JMAX
    generate_awg_params
    [[ "$AWG_S1" -ge 15 ]] && [[ "$AWG_S1" -le 150 ]]
    [[ "$AWG_S2" -ge 15 ]] && [[ "$AWG_S2" -le 150 ]]
    [[ "$AWG_S3" -ge 8 ]]  && [[ "$AWG_S3" -le 55 ]]
    [[ "$AWG_S4" -ge 4 ]]  && [[ "$AWG_S4" -le 27 ]]
}
