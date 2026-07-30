#!/usr/bin/env bats
# Tests for warn_awg_init_drift (#196: editing awgsetup_cfg.init was ignored silently)
# shellcheck disable=SC2154  # Variables set by sourced scripts at runtime

load test_helper

# Capture warnings: the shared helper silences log_warn, these tests need it back.
capture_warnings() {
    log_warn() { echo "$1"; }
}

# init file newer than the live config (the "edited init, nothing happened" case)
make_init_newer() {
    touch -d '2 hours ago' "$SERVER_CONF_FILE"
    touch "$CONFIG_FILE"
}

# live config newer: the supported tuning path (edit awg0.conf, then regen)
make_live_newer() {
    touch -d '2 hours ago' "$CONFIG_FILE"
    touch "$SERVER_CONF_FILE"
}

@test "warn_awg_init_drift: warns when init is newer and params disagree" {
    create_server_config          # no I1
    create_init_config            # I1 = <r 128>
    make_init_newer
    capture_warnings
    run warn_awg_init_drift
    [ "$status" -eq 0 ]
    [[ "$output" == *"I1"* ]]
}

@test "warn_awg_init_drift: names every key that disagrees" {
    create_server_config
    create_init_config
    # diverge one more parameter on top of I1
    sed -i 's/^export AWG_Jc=6/export AWG_Jc=9/' "$CONFIG_FILE"
    make_init_newer
    capture_warnings
    run warn_awg_init_drift
    [[ "$output" == *"Jc"* ]]
    [[ "$output" == *"I1"* ]]
}

@test "warn_awg_init_drift: stays quiet when the live config is newer" {
    create_server_config
    create_init_config            # disagrees on I1, but awg0.conf was edited last
    make_live_newer
    capture_warnings
    run warn_awg_init_drift
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "warn_awg_init_drift: stays quiet when the parameters agree" {
    create_server_config
    create_init_config
    sed -i "/^export AWG_I1=/d" "$CONFIG_FILE"   # now both sides have no I1
    make_init_newer
    capture_warnings
    run warn_awg_init_drift
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "warn_awg_init_drift: stays quiet without a live config (bootstrap)" {
    create_init_config
    rm -f "$SERVER_CONF_FILE"
    capture_warnings
    run warn_awg_init_drift
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "warn_awg_init_drift: stays quiet without an init file" {
    create_server_config
    rm -f "$CONFIG_FILE"
    capture_warnings
    run warn_awg_init_drift
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "warn_awg_init_drift: leaves the caller's AWG_* untouched" {
    create_server_config
    create_init_config
    make_init_newer
    capture_warnings
    export AWG_I1='SENTINEL'
    export AWG_Jc='SENTINEL_JC'
    warn_awg_init_drift
    # Reading both sources must not leak their values into the caller.
    [ "$AWG_I1" = "SENTINEL" ]
    [ "$AWG_Jc" = "SENTINEL_JC" ]
}

@test "warn_awg_init_drift: stays quiet when the live config cannot be parsed" {
    create_server_config
    sed -i '/^H4 = /d' "$SERVER_CONF_FILE"   # a mandatory parameter is missing
    create_init_config
    make_init_newer
    capture_warnings
    run warn_awg_init_drift
    # The live parser exports nothing at all in this case. Comparing against a
    # set of empty values would name every key as differing, which is worse than
    # useless - load_awg_params reports the real cause a moment later.
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "warn_awg_init_drift: stays quiet when an AWG_* is readonly in the caller" {
    create_server_config
    create_init_config
    make_init_newer
    capture_warnings
    # A readonly variable cannot be unset, so the dump cannot clear inherited
    # values and the comparison would silently run on the wrong data.
    run bash -c "
        source '$BATS_TEST_DIRNAME/../awg_common.sh'
        CONFIG_FILE='$CONFIG_FILE' SERVER_CONF_FILE='$SERVER_CONF_FILE'
        log_warn() { echo \"\$1\"; }
        readonly AWG_I1=INHERITED
        warn_awg_init_drift
    "
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "RU/EN parity: both libraries define the drift check with the mtime gate" {
    for f in awg_common.sh awg_common_en.sh; do
        run grep -E '^warn_awg_init_drift\(\)' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ] || { echo "$f is missing warn_awg_init_drift"; false; }
        run grep -E '^_awg_drift_dump\(\)' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ] || { echo "$f is missing _awg_drift_dump"; false; }
        # The gate is what keeps the supported tuning path quiet.
        run grep -F '"$init" -nt "$live"' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ] || { echo "$f is missing the mtime gate"; false; }
        # Reading the sources must stay inside a subshell that clears inherited keys.
        run grep -F 'unset "${_AWG_DRIFT_KEYS[@]}" 2>/dev/null || exit 1' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ] || { echo "$f does not clear inherited AWG_* before dumping"; false; }
        # mapfile hides the producer's exit status, so the dump carries a marker.
        run grep -F "printf 'ok" "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ] || { echo "$f is missing the dump success marker"; false; }
    done
}

@test "RU/EN parity: both managers call the drift check on regen and check" {
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        [ "$(grep -c '^ *warn_awg_init_drift$' "$BATS_TEST_DIRNAME/../$f")" -eq 2 ] \
            || { echo "$f must call warn_awg_init_drift exactly twice (regen, check)"; false; }
    done
}

@test "installer does not call the drift check (init is legitimately newer mid-install)" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run grep -F 'warn_awg_init_drift' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -ne 0 ] || { echo "$f must not warn about drift during an install"; false; }
    done
}

@test "warn_awg_init_drift: an inherited AWG_* does not mask a real difference" {
    create_server_config
    create_init_config
    make_init_newer
    capture_warnings
    # The live config has no I1. Without clearing inherited values, the dump of
    # the live side would report this leftover and the difference would vanish.
    export AWG_I1='<r 128>'
    run warn_awg_init_drift
    [[ "$output" == *"I1"* ]]
}
