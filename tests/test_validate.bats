#!/usr/bin/env bats
# Tests for validate_awg_config() in awg_common.sh

load test_helper

@test "validate: complete config passes" {
    create_server_config
    run validate_awg_config
    [ "$status" -eq 0 ]
}

@test "validate: missing Jc fails" {
    create_server_config
    sed -i '/^Jc/d' "$SERVER_CONF_FILE"
    run validate_awg_config
    [ "$status" -eq 1 ]
}

@test "validate: missing S3 fails" {
    create_server_config
    sed -i '/^S3/d' "$SERVER_CONF_FILE"
    run validate_awg_config
    [ "$status" -eq 1 ]
}

@test "validate: missing H4 fails" {
    create_server_config
    sed -i '/^H4/d' "$SERVER_CONF_FILE"
    run validate_awg_config
    [ "$status" -eq 1 ]
}

@test "validate: I1 optional (warn only, still passes)" {
    create_server_config
    # I1 is not in our minimal config — should still pass
    run validate_awg_config
    [ "$status" -eq 0 ]
}

@test "validate: missing file fails" {
    rm -f "$SERVER_CONF_FILE"
    run validate_awg_config
    [ "$status" -eq 1 ]
}

@test "validate: Jc=0 (junk packets off) passes" {
    create_server_config
    sed -i 's/^Jc = .*/Jc = 0/' "$SERVER_CONF_FILE"
    run validate_awg_config
    [ "$status" -eq 0 ]
}

@test "validate: Jc=129 out of range fails" {
    create_server_config
    sed -i 's/^Jc = .*/Jc = 129/' "$SERVER_CONF_FILE"
    run validate_awg_config
    [ "$status" -eq 1 ]
}

@test "validate: Jmin=1500 exceeds 1280 fails" {
    create_server_config
    sed -i 's/^Jmin = .*/Jmin = 1500/' "$SERVER_CONF_FILE"
    run validate_awg_config
    [ "$status" -eq 1 ]
}

@test "validate: Jmax < Jmin fails" {
    create_server_config
    sed -i 's/^Jmin = .*/Jmin = 200/' "$SERVER_CONF_FILE"
    sed -i 's/^Jmax = .*/Jmax = 100/' "$SERVER_CONF_FILE"
    run validate_awg_config
    [ "$status" -eq 1 ]
}

@test "validate: S3=65 exceeds max fails" {
    create_server_config
    sed -i 's/^S3 = .*/S3 = 65/' "$SERVER_CONF_FILE"
    run validate_awg_config
    [ "$status" -eq 1 ]
}

@test "validate: S4=33 exceeds max fails" {
    create_server_config
    sed -i 's/^S4 = .*/S4 = 33/' "$SERVER_CONF_FILE"
    run validate_awg_config
    [ "$status" -eq 1 ]
}

@test "validate: H range with low >= high fails" {
    create_server_config
    sed -i 's/^H1 = .*/H1 = 500-500/' "$SERVER_CONF_FILE"
    run validate_awg_config
    [ "$status" -eq 1 ]
}

@test "validate: valid boundary values pass" {
    create_server_config
    sed -i 's/^Jc = .*/Jc = 128/' "$SERVER_CONF_FILE"
    sed -i 's/^Jmin = .*/Jmin = 0/' "$SERVER_CONF_FILE"
    sed -i 's/^Jmax = .*/Jmax = 1280/' "$SERVER_CONF_FILE"
    sed -i 's/^S3 = .*/S3 = 64/' "$SERVER_CONF_FILE"
    sed -i 's/^S4 = .*/S4 = 32/' "$SERVER_CONF_FILE"
    run validate_awg_config
    [ "$status" -eq 0 ]
}
