#!/usr/bin/env bats
# Regression guard: safe_load_config whitelist accepts the three new IPv6-tunnel keys.
# shellcheck disable=SC2154

load test_helper

@test "safe_load_config: accepts ALLOW_IPV6_TUNNEL key" {
    echo "export ALLOW_IPV6_TUNNEL=1" > "$CONFIG_FILE"
    safe_load_config "$CONFIG_FILE"
    [ "$ALLOW_IPV6_TUNNEL" = "1" ]
}

@test "safe_load_config: accepts ALLOW_IPV6_TUNNEL=0" {
    echo "export ALLOW_IPV6_TUNNEL=0" > "$CONFIG_FILE"
    safe_load_config "$CONFIG_FILE"
    [ "$ALLOW_IPV6_TUNNEL" = "0" ]
}

@test "safe_load_config: accepts IPV6_SUBNET key" {
    echo "export IPV6_SUBNET='fddd:2c4:2c4:2c4::/64'" > "$CONFIG_FILE"
    safe_load_config "$CONFIG_FILE"
    [ "$IPV6_SUBNET" = "fddd:2c4:2c4:2c4::/64" ]
}

@test "safe_load_config: accepts SERVER_HAS_NATIVE_IPV6 key" {
    echo "export SERVER_HAS_NATIVE_IPV6=0" > "$CONFIG_FILE"
    safe_load_config "$CONFIG_FILE"
    [ "$SERVER_HAS_NATIVE_IPV6" = "0" ]
}

@test "safe_load_config: existing keys still accepted (regression)" {
    echo "export AWG_PORT=39743" > "$CONFIG_FILE"
    safe_load_config "$CONFIG_FILE"
    [ "$AWG_PORT" = "39743" ]
}

@test "safe_load_config: unknown keys still rejected (regression)" {
    echo "export EVIL_IPV6_KEY=hacked" > "$CONFIG_FILE"
    safe_load_config "$CONFIG_FILE"
    [ -z "${EVIL_IPV6_KEY:-}" ]
}

@test "safe_load_config: RU/EN parity - same whitelist in awg_common_en.sh" {
    local ru_block en_block
    ru_block=$(grep -m 1 -A4 'AWG_APPLY_MODE' "$BATS_TEST_DIRNAME/../awg_common.sh" | grep -E 'ALLOW_IPV6|IPV6_SUBNET|SERVER_HAS')
    en_block=$(grep -m 1 -A4 'AWG_APPLY_MODE' "$BATS_TEST_DIRNAME/../awg_common_en.sh" | grep -E 'ALLOW_IPV6|IPV6_SUBNET|SERVER_HAS')
    [ "$ru_block" = "$en_block" ]
}

@test "safe_load_config: install RU/EN parity - same whitelist in both installers" {
    local ru_block en_block
    ru_block=$(grep -m 1 -A4 'AWG_APPLY_MODE' "$BATS_TEST_DIRNAME/../install_amneziawg.sh" | grep -E 'ALLOW_IPV6|IPV6_SUBNET|SERVER_HAS')
    en_block=$(grep -m 1 -A4 'AWG_APPLY_MODE' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh" | grep -E 'ALLOW_IPV6|IPV6_SUBNET|SERVER_HAS')
    [ "$ru_block" = "$en_block" ]
}
