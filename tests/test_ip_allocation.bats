#!/usr/bin/env bats
# Tests for get_next_client_ip() in awg_common.sh

load test_helper

@test "get_next_client_ip: returns .2 for empty config" {
    require_grep_P
    export AWG_TUNNEL_SUBNET="10.9.9.1/24"
    create_server_config
    run get_next_client_ip
    [ "$status" -eq 0 ]
    [ "$output" = "10.9.9.2" ]
}

@test "get_next_client_ip: returns .3 when .2 taken" {
    require_grep_P
    export AWG_TUNNEL_SUBNET="10.9.9.1/24"
    create_server_config
    add_test_peer "client1" "10.9.9.2"
    run get_next_client_ip
    [ "$status" -eq 0 ]
    [ "$output" = "10.9.9.3" ]
}

@test "get_next_client_ip: skips .1 (server)" {
    export AWG_TUNNEL_SUBNET="10.9.9.1/24"
    create_server_config
    run get_next_client_ip
    [ "$status" -eq 0 ]
    [ "$output" != "10.9.9.1" ]
}

@test "get_next_client_ip: finds gap in sequence" {
    require_grep_P
    export AWG_TUNNEL_SUBNET="10.9.9.1/24"
    create_server_config
    add_test_peer "c1" "10.9.9.2"
    add_test_peer "c2" "10.9.9.3"
    # skip .4
    add_test_peer "c3" "10.9.9.5"
    run get_next_client_ip
    [ "$status" -eq 0 ]
    [ "$output" = "10.9.9.4" ]
}

@test "get_next_client_ip: custom subnet" {
    require_grep_P
    export AWG_TUNNEL_SUBNET="172.16.0.1/24"
    create_server_config
    run get_next_client_ip
    [ "$status" -eq 0 ]
    [ "$output" = "172.16.0.2" ]
}

@test "get_next_client_ip: works without config file" {
    export AWG_TUNNEL_SUBNET="10.9.9.1/24"
    rm -f "$SERVER_CONF_FILE"
    run get_next_client_ip
    [ "$status" -eq 0 ]
    [ "$output" = "10.9.9.2" ]
}

# --- Полноценный CIDR: маски шире и уже /24 (v5.19) ---

@test "get_next_client_ip: /16 returns .0.2 for empty config" {
    require_grep_P
    export AWG_TUNNEL_SUBNET="10.9.0.1/16"
    create_server_config
    run get_next_client_ip
    [ "$status" -eq 0 ]
    [ "$output" = "10.9.0.2" ]
}

@test "get_next_client_ip: /16 crosses octet boundary (.0.254 taken -> .0.255)" {
    require_grep_P
    export AWG_TUNNEL_SUBNET="10.9.0.1/16"
    create_server_config
    # Заполняем .0.2 .. .0.254
    local i
    for i in $(seq 2 254); do add_test_peer "c$i" "10.9.0.$i"; done
    run get_next_client_ip
    [ "$status" -eq 0 ]
    [ "$output" = "10.9.0.255" ]
}

@test "get_next_client_ip: /25 last usable is .126 (broadcast .127 excluded)" {
    require_grep_P
    export AWG_TUNNEL_SUBNET="10.9.9.1/25"
    create_server_config
    local i
    for i in $(seq 2 125); do add_test_peer "c$i" "10.9.9.$i"; done
    run get_next_client_ip
    [ "$status" -eq 0 ]
    [ "$output" = "10.9.9.126" ]
}

@test "get_next_client_ip: /25 full subnet -> error" {
    require_grep_P
    export AWG_TUNNEL_SUBNET="10.9.9.1/25"
    create_server_config
    local i
    for i in $(seq 2 126); do add_test_peer "c$i" "10.9.9.$i"; done
    run get_next_client_ip
    [ "$status" -ne 0 ]
}

@test "get_next_client_ip: /23 allocates .0.2 then spans into .1.x" {
    require_grep_P
    export AWG_TUNNEL_SUBNET="10.9.0.1/23"
    create_server_config
    run get_next_client_ip
    [ "$status" -eq 0 ]
    [ "$output" = "10.9.0.2" ]
}

@test "get_next_client_ip: server at network+1 is skipped (/24 default)" {
    export AWG_TUNNEL_SUBNET="10.9.9.1/24"
    create_server_config
    run get_next_client_ip
    [ "$status" -eq 0 ]
    [ "$output" != "10.9.9.1" ]
}
