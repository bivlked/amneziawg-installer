#!/usr/bin/env bats
# Tests for load_awg_params_from_server_conf (#38 fix: regen reads live awg0.conf)
# shellcheck disable=SC2154  # Variables set by sourced scripts at runtime

load test_helper

@test "load_awg_params_from_server_conf: parses Interface section" {
    create_server_config
    run load_awg_params_from_server_conf "$SERVER_CONF_FILE"
    [ "$status" -eq 0 ]
}

@test "load_awg_params_from_server_conf: exports AWG_Jc/Jmin/Jmax" {
    create_server_config
    load_awg_params_from_server_conf "$SERVER_CONF_FILE"
    [ "$AWG_Jc" = "6" ]
    [ "$AWG_Jmin" = "55" ]
    [ "$AWG_Jmax" = "380" ]
}

@test "load_awg_params_from_server_conf: exports AWG_S1-S4" {
    create_server_config
    load_awg_params_from_server_conf "$SERVER_CONF_FILE"
    [ "$AWG_S1" = "72" ]
    [ "$AWG_S2" = "56" ]
    [ "$AWG_S3" = "32" ]
    [ "$AWG_S4" = "16" ]
}

@test "load_awg_params_from_server_conf: exports AWG_H1-H4" {
    create_server_config
    load_awg_params_from_server_conf "$SERVER_CONF_FILE"
    [ "$AWG_H1" = "100000-800000" ]
    [ "$AWG_H2" = "1000000-8000000" ]
    [ "$AWG_H3" = "10000000-80000000" ]
    [ "$AWG_H4" = "100000000-800000000" ]
}

@test "load_awg_params_from_server_conf: exports ListenPort as AWG_PORT" {
    create_server_config
    load_awg_params_from_server_conf "$SERVER_CONF_FILE"
    [ "$AWG_PORT" = "39743" ]
}

@test "load_awg_params_from_server_conf: missing file returns 1" {
    run load_awg_params_from_server_conf "/nonexistent/path/awg0.conf"
    [ "$status" -eq 1 ]
}

@test "load_awg_params_from_server_conf: ignores [Peer] section" {
    create_server_config
    add_test_peer "client1" "10.9.9.2"
    load_awg_params_from_server_conf "$SERVER_CONF_FILE"
    # AllowedIPs from [Peer] should NOT pollute AWG_* vars
    [ -z "${AllowedIPs:-}" ] || [ "$AllowedIPs" != "10.9.9.2/32" ]
    # AWG_Jc still correctly loaded from [Interface]
    [ "$AWG_Jc" = "6" ]
}

@test "load_awg_params_from_server_conf: parses I1 with angle brackets" {
    cat > "$SERVER_CONF_FILE" << 'CONF'
[Interface]
PrivateKey = TESTKEY
Address = 10.9.9.1/24
ListenPort = 39743
Jc = 7
Jmin = 50
Jmax = 350
S1 = 100
S2 = 80
S3 = 25
S4 = 15
H1 = 12345-67890
H2 = 1000000-2000000
H3 = 100000000-200000000
H4 = 3000000000-4000000000
I1 = <r 128>
CONF
    load_awg_params_from_server_conf "$SERVER_CONF_FILE"
    [ "$AWG_I1" = "<r 128>" ]
}

@test "load_awg_params: priority - server_conf overrides init file (#38 regression)" {
    # Init file has OLD values, server config has NEW values
    create_init_config
    cat > "$SERVER_CONF_FILE" << 'CONF'
[Interface]
PrivateKey = TESTKEY
Address = 10.9.9.1/24
ListenPort = 39743
Jc = 99
Jmin = 200
Jmax = 999
S1 = 1
S2 = 2
S3 = 3
S4 = 4
H1 = 500-1500
H2 = 2000-3000
H3 = 4000-5000
H4 = 6000-7000
CONF
    load_awg_params
    # Server config values should win (the regen-after-manual-edit scenario)
    [ "$AWG_Jc" = "99" ]
    [ "$AWG_Jmin" = "200" ]
    [ "$AWG_H1" = "500-1500" ]
    [ "$AWG_H4" = "6000-7000" ]
}

@test "load_awg_params: fallback to init file when server_conf missing" {
    create_init_config
    # No server config exists
    rm -f "$SERVER_CONF_FILE"
    load_awg_params
    # Init file values are used
    [ "$AWG_Jc" = "6" ]
    [ "$AWG_H1" = "100000-800000" ]
}

@test "load_awg_params: returns 0 when params loaded successfully" {
    create_server_config
    run load_awg_params
    [ "$status" -eq 0 ]
}

@test "load_awg_params: split-brain prevention - corrupt server_conf returns 1 even if init has values" {
    # The exact scenario from finding #1 of the code audit:
    # init file has GOOD (stale) values, server_conf exists but is missing
    # required H4. Old behavior would silently fall back to init and pretend
    # success - server runs new config, regen would emit clients old values.
    # New behavior: error, return 1, no split-brain possible.
    create_init_config
    cat > "$SERVER_CONF_FILE" << 'CONF'
[Interface]
PrivateKey = TESTKEY
Address = 10.9.9.1/24
ListenPort = 39743
Jc = 99
Jmin = 200
Jmax = 999
S1 = 1
S2 = 2
S3 = 3
S4 = 4
H1 = 500-1500
H2 = 2000-3000
H3 = 4000-5000
CONF
    # H4 deliberately missing
    run load_awg_params
    [ "$status" -eq 1 ]
}

@test "load_awg_params: split-brain prevention - server_conf missing falls back to init (bootstrap)" {
    # Counterpart to the previous test: when server_conf is missing entirely,
    # init fallback IS allowed - this is the bootstrap path of first install.
    create_init_config
    rm -f "$SERVER_CONF_FILE"
    run load_awg_params
    [ "$status" -eq 0 ]
}

@test "load_awg_params_from_server_conf: atomic - partial corrupt config does not pollute env" {
    # Init file has GOOD values
    create_init_config
    safe_load_config "$CONFIG_FILE"
    # Sanity: init values loaded
    [ "$AWG_Jc" = "6" ]
    [ "$AWG_H4" = "100000000-800000000" ]

    # Now write a CORRUPT server config - missing H2, H3, H4
    cat > "$SERVER_CONF_FILE" << 'CONF'
[Interface]
PrivateKey = TESTKEY
Address = 10.9.9.1/24
ListenPort = 39743
Jc = 99
Jmin = 200
Jmax = 999
S1 = 1
S2 = 2
S3 = 3
S4 = 4
H1 = 500-1500
CONF
    # Atomic: should return 1 because H2-H4 missing
    run load_awg_params_from_server_conf "$SERVER_CONF_FILE"
    [ "$status" -eq 1 ]

    # CRITICAL: env must NOT be partially polluted with new Jc/H1
    # The init values must remain intact
    [ "$AWG_Jc" = "6" ]
    [ "$AWG_H1" = "100000-800000" ]
    [ "$AWG_H4" = "100000000-800000000" ]
}
