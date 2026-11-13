#!/usr/bin/env bats
# check and diagnose take the server port from ListenPort of the live awg0.conf.
#
# They used to take AWG_PORT from awgsetup_cfg.init. After a port change made by
# editing awg0.conf, check then confirmed the UFW rule of the OLD port and never
# noticed that the port the server really listens on had no rule: the diagnosis
# said "all good" exactly when it was run to find the fault.
#
# Now ListenPort decides; the init port is used only when awg0.conf has no
# ListenPort line. A corrupt ListenPort is a failure, never a quiet fallback to
# the init. When both are valid and differ, check and diagnose say so and name
# the fix, `manage port <N>`, which with the current port now writes it into the
# init and touches nothing else.
#
# The real manage script runs end to end with the system commands stubbed on PATH.

# shellcheck disable=SC2154  # $stderr is set by bats `run --separate-stderr`
load test_helper

bats_require_minimum_version 1.5.0

# CI installs jq; a missing jq there is a broken runner, not a reason to skip.
require_jq() {
    command -v jq &>/dev/null && return 0
    [[ -z "${CI:-}" ]] || { echo "jq is missing in CI"; return 1; }
    skip "jq not available"
}

setup_env() {
    MGMT_DIR=$(mktemp -d)
    mkdir -p "$MGMT_DIR/bin" "$MGMT_DIR/awg/keys"
    export CALLS="$MGMT_DIR/calls"
    : > "$CALLS"
    cat > "$MGMT_DIR/bin/systemctl" << 'STUB'
#!/bin/bash
echo "systemctl $*" >> "$CALLS"
exit 0
STUB
    # ufw status lists STUB_UFW_HAS as ALLOW rules.
    cat > "$MGMT_DIR/bin/ufw" << 'STUB'
#!/bin/bash
if [[ "$1" == show ]]; then
    for r in ${STUB_UFW_HAS:-}; do printf 'ufw allow %s/udp comment AmneziaWG\n' "$r"; done
    exit 0
fi
if [[ "$1" == status ]]; then
    echo "Status: active"
    for r in ${STUB_UFW_HAS:-}; do printf '%s/udp                  ALLOW       Anywhere\n' "$r"; done
    exit 0
fi
echo "ufw $*" >> "$CALLS"
exit 0
STUB
    # The socket table lists STUB_LISTEN: the port the kernel really holds,
    # which after an edit of awg0.conf without a restart is not ListenPort.
    cat > "$MGMT_DIR/bin/ss" << 'STUB'
#!/bin/bash
for q in ${STUB_LISTEN:-}; do printf 'UNCONN 0 0 0.0.0.0:%s 0.0.0.0:*\n' "$q"; done
STUB
    cat > "$MGMT_DIR/bin/ip" << 'STUB'
#!/bin/bash
echo "5: awg0: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1280 qdisc noqueue state UNKNOWN"
echo "    inet 10.9.9.1/24 scope global awg0"
STUB
    printf '#!/bin/bash\necho 1\n' > "$MGMT_DIR/bin/sysctl"
    printf '#!/bin/bash\necho "amneziawg 155648 0"\n' > "$MGMT_DIR/bin/lsmod"
    cat > "$MGMT_DIR/bin/awg" << 'STUB'
#!/bin/bash
echo "interface: awg0"
echo "  listening port: ${STUB_LISTEN%% *}"
echo "  jc: 6"
echo "  jmin: 55"
echo "  jmax: 380"
echo "  s1: 72"
echo "  s2: 56"
echo "  h1: 100000-800000"
exit 0
STUB
    chmod +x "$MGMT_DIR/bin/"*
    export PATH="$MGMT_DIR/bin:$PATH"
    export AWG_USERNS_ROOT="$MGMT_DIR/no-userns-root"
    cat > "$MGMT_DIR/awg/awgsetup_cfg.init" << 'CONF'
export AWG_PORT=39743
export AWG_TUNNEL_SUBNET='10.9.9.1/24'
export DISABLE_IPV6=1
export ALLOWED_IPS_MODE=1
export ALLOWED_IPS='0.0.0.0/0'
export AWG_ENDPOINT='vpn.example.com'
export AWG_PROTOCOL='2.0'
CONF
    cat > "$MGMT_DIR/awg/awg0.conf" << 'CONF'
[Interface]
PrivateKey = TESTKEY
Address = 10.9.9.1/24
MTU = 1280
ListenPort = 39743
Jc = 6
Jmin = 55
Jmax = 380
S1 = 72
S2 = 56
S3 = 32
S4 = 16
H1 = 100000-800000
H2 = 1000000-8000000
H3 = 10000000-80000000
H4 = 100000000-800000000
CONF
    export AWG_SKIP_APPLY=1
}

teardown() {
    rm -rf "$TEST_DIR" "${MGMT_DIR:-}"
    unset AWG_SKIP_APPLY CALLS STUB_UFW_HAS STUB_LISTEN AWG_USERNS_ROOT
}

manage() {
    local script="$1"; shift
    local lib="awg_common.sh"
    [[ "$script" == *_en.sh ]] && lib="awg_common_en.sh"
    cp "$BATS_TEST_DIRNAME/../$lib" "$MGMT_DIR/awg/awg_common.sh"
    run --separate-stderr timeout 60 bash "$BATS_TEST_DIRNAME/../$script" "$@" --yes \
        --conf-dir="$MGMT_DIR/awg" --server-conf="$MGMT_DIR/awg/awg0.conf"
}

set_listen()    { sed -i "s/^ListenPort = .*/ListenPort = $1/" "$MGMT_DIR/awg/awg0.conf"; }
listen_port()   { sed -n 's/^ListenPort = //p' "$MGMT_DIR/awg/awg0.conf"; }
init_port()     { sed -n 's/^export AWG_PORT=//p' "$MGMT_DIR/awg/awgsetup_cfg.init"; }
calls()         { grep -vE '^(systemctl is-active|systemctl status|ufw status)' "$CALLS" | paste -sd'|' -; }
ru()            { [[ "$1" != *_en.sh ]]; }

# The drift line, in the language of the script: it names both ports.
drift_text() {
    if ru "$1"; then echo "не совпадает с ListenPort"; else echo "does not match ListenPort"; fi
}
noline_text() {
    if ru "$1"; then echo "нет строки ListenPort"; else echo "has no ListenPort line"; fi
}
noinit_text() {
    if ru "$1"; then echo "нет AWG_PORT"; else echo "has no AWG_PORT"; fi
}

# PATH without any ufw at all: the stub removed and every directory that holds a
# real ufw left out.
path_without_ufw() {
    rm -f "$MGMT_DIR/bin/ufw"
    local d out="" ds
    IFS=: read -ra ds <<< "$PATH"
    for d in "${ds[@]}"; do [[ -x "$d/ufw" ]] || out+="${out:+:}$d"; done
    printf '%s' "$out"
}

each_manage() {
    local seen=0 s
    for s in manage_amneziawg.sh manage_amneziawg_en.sh; do
        setup_env
        "$1" "$s" || return 1
        rm -rf "$MGMT_DIR"
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}

# ---------------------------------------------------------------- check

# The case from the bug: the port was moved to 51820 by editing awg0.conf and
# the server restarted, UFW still allows only the old 39743, the init still says
# 39743. Before the fix check reported port 39743, listening, allowed.
_check_sees_edited_port() {
    set_listen 51820
    export STUB_LISTEN=51820 STUB_UFW_HAS=39743
    manage "$1" check --json
    [ "$(printf '%s' "$output" | jq -r '.port.number')" = "51820" ] \
        || { echo "$1: port.number is not the live ListenPort: $output"; return 1; }
    printf '%s' "$output" | jq -e '.port.listening == true' >/dev/null \
        || { echo "$1: the live port is not seen as listening: $output"; return 1; }
    printf '%s' "$output" | jq -e '.firewall.port_allowed == false' >/dev/null \
        || { echo "$1: the rule of the old port was taken for the live one: $output"; return 1; }
    printf '%s' "$output" | jq -e '.port.source == "listen_port" and .port.init_mismatch == true' >/dev/null \
        || { echo "$1: JSON does not show the source and the mismatch: $output"; return 1; }
    [[ "$stderr" == *"ufw allow 51820/udp"* ]] \
        || { echo "$1: the missing rule has no fix command: $stderr"; return 1; }
    [[ "$stderr" == *"$(drift_text "$1")"* && "$stderr" == *39743* ]] \
        || { echo "$1: the init/ListenPort drift is not reported: $stderr"; return 1; }
    [[ "$stderr" == *"port 51820"* ]] \
        || { echo "$1: the drift has no fix command: $stderr"; return 1; }
}
@test "check: a port moved by editing awg0.conf is checked as the live ListenPort, the old rule does not count, both twins" {
    require_jq
    each_manage _check_sees_edited_port
}

_check_edited_and_opened() {
    set_listen 51820
    export STUB_LISTEN=51820 STUB_UFW_HAS=51820
    manage "$1" check --json
    [ "$status" -eq 0 ] || { echo "$1: check failed ($status): $stderr"; return 1; }
    printf '%s' "$output" | jq -e '.ok == true and .port.number == 51820 and .port.listening == true and .firewall.port_allowed == true' >/dev/null \
        || { echo "$1: a consistent live port is not green: $output"; return 1; }
}
@test "check: a moved port with its own UFW rule is green, both twins" {
    require_jq
    each_manage _check_edited_and_opened
}

# awg0.conf edited, the service not restarted: the kernel still holds 39743.
_check_edit_not_applied() {
    set_listen 51820
    export STUB_LISTEN=39743 STUB_UFW_HAS="39743 51820"
    manage "$1" check --json
    [ "$status" -eq 1 ] || { echo "$1: status $status, want 1"; return 1; }
    printf '%s' "$output" | jq -e '.ok == false and .port.number == 51820 and .port.listening == false' >/dev/null \
        || { echo "$1: an edit not yet applied looks applied: $output"; return 1; }
}
@test "check: ListenPort edited but not applied is reported as not listening, both twins" {
    require_jq
    each_manage _check_edit_not_applied
}

# A broken ListenPort is a broken authoritative source: no quiet fallback to the
# init, whose port would make everything look fine here.
_check_corrupt_listen() {
    local bad
    for bad in abc 70000 "" "51820=x"; do
        set_listen "$bad"
        export STUB_LISTEN=39743 STUB_UFW_HAS=39743
        manage "$1" check --json
        [ "$status" -eq 1 ] || { echo "$1 [$bad]: status $status, want 1"; return 1; }
        printf '%s' "$output" | jq -e '.ok == false and .port.number == 0' >/dev/null \
            || { echo "$1 [$bad]: a corrupt ListenPort fell back to the init: $output"; return 1; }
        [[ "$stderr" == *awg0.conf* ]] || { echo "$1 [$bad]: the failure does not name awg0.conf: $stderr"; return 1; }
    done
}
@test "check: a corrupt or empty ListenPort is a failure, not a fallback to the init, both twins" {
    require_jq
    each_manage _check_corrupt_listen
}

# awg-quick strips '#' comments, so this line is port 51820.
_check_listen_with_comment() {
    sed -i 's/^ListenPort = .*/ListenPort = 51820   # moved off 39743/' "$MGMT_DIR/awg/awg0.conf"
    sed -i 's/^export AWG_PORT=.*/export AWG_PORT=51820/' "$MGMT_DIR/awg/awgsetup_cfg.init"
    export STUB_LISTEN=51820 STUB_UFW_HAS=51820
    manage "$1" check --json
    [ "$status" -eq 0 ] || { echo "$1: check failed ($status): $stderr"; return 1; }
    printf '%s' "$output" | jq -e '.ok == true and .port.number == 51820' >/dev/null \
        || { echo "$1: a commented ListenPort is misread: $output"; return 1; }
}
@test "check: a comment after ListenPort is stripped the way awg-quick does, both twins" {
    require_jq
    each_manage _check_listen_with_comment
}

# No ListenPort line at all: the init port is used, as before, but not silently:
# such a server listens on a random port.
_check_no_listen_line() {
    sed -i '/^ListenPort/d' "$MGMT_DIR/awg/awg0.conf"
    export STUB_LISTEN=39743 STUB_UFW_HAS=39743
    manage "$1" check --json
    [ "$status" -eq 0 ] || { echo "$1: check failed ($status): $stderr"; return 1; }
    printf '%s' "$output" | jq -e '.ok == true and .port.number == 39743 and .firewall.port_allowed == true and .port.source == "init" and .port.init_mismatch == false' >/dev/null \
        || { echo "$1: without ListenPort the init port is not used: $output"; return 1; }
    [[ "$stderr" != *"$(drift_text "$1")"* ]] || { echo "$1: drift reported with no ListenPort: $stderr"; return 1; }
    [[ "$stderr" == *"$(noline_text "$1")"* ]] || { echo "$1: a missing ListenPort line is not named: $stderr"; return 1; }
}
@test "check: without a ListenPort line the init port is used, both twins" {
    require_jq
    each_manage _check_no_listen_line
}

_check_in_sync_no_drift() {
    export STUB_LISTEN=39743 STUB_UFW_HAS=39743
    manage "$1" check --json
    [ "$status" -eq 0 ] || { echo "$1: check failed ($status): $stderr"; return 1; }
    printf '%s' "$output" | jq -e '.ok == true and .port.number == 39743 and .port.source == "listen_port" and .port.init_mismatch == false' >/dev/null \
        || { echo "$1: a healthy server is not green: $output"; return 1; }
    [[ "$stderr" == *39743* ]] || { echo "$1: the port section is not in the log at all: $stderr"; return 1; }
    [[ "$stderr" != *"$(drift_text "$1")"* ]] || { echo "$1: drift reported when the ports agree: $stderr"; return 1; }
}
@test "check: no drift line when ListenPort and the init agree, both twins" {
    require_jq
    each_manage _check_in_sync_no_drift
}

# A broken init port next to a good ListenPort: check stays on ListenPort and
# names the broken init, because the installer reads it on a rerun.
_check_corrupt_init_good_listen() {
    sed -i 's/^export AWG_PORT=.*/export AWG_PORT=abc/' "$MGMT_DIR/awg/awgsetup_cfg.init"
    export STUB_LISTEN=39743 STUB_UFW_HAS=39743
    manage "$1" check --json
    [ "$status" -eq 0 ] || { echo "$1: a broken init port next to a good ListenPort failed check ($status): $stderr"; return 1; }
    printf '%s' "$output" | jq -e '.port.number == 39743 and .firewall.port_allowed == true and .port.init_mismatch == true' >/dev/null \
        || { echo "$1: a broken init port overrode a good ListenPort: $output"; return 1; }
    [[ "$stderr" == *"'abc'"* && "$stderr" == *"port 39743"* ]] \
        || { echo "$1: the broken init port is not named with its fix: $stderr"; return 1; }
}
@test "check: a broken init port next to a good ListenPort is named, the check runs on ListenPort, both twins" {
    require_jq
    each_manage _check_corrupt_init_good_listen
}

# ---------------------------------------------------------------- diagnose

_diag_sees_edited_port() {
    set_listen 51820
    export STUB_LISTEN=51820 STUB_UFW_HAS=39743
    manage "$1" diagnose
    local all="$output$stderr"
    [[ "$all" == *"51820/udp"* ]] || { echo "$1: diagnose does not check the live port: $all"; return 1; }
    [[ "$all" != *"39743/udp ALLOW"* ]] || { echo "$1: the rule of the old port was counted as OK: $all"; return 1; }
    [[ "$all" == *"ufw allow 51820/udp"* ]] || { echo "$1: no fix command for the missing rule: $all"; return 1; }
    [[ "$all" == *"$(drift_text "$1")"* && "$all" == *"port 51820"* ]] \
        || { echo "$1: diagnose does not report the drift with its fix: $all"; return 1; }
}
@test "diagnose: a port moved by editing awg0.conf is checked as the live ListenPort, both twins" {
    each_manage _diag_sees_edited_port
}

_diag_corrupt_listen() {
    set_listen abc
    export STUB_LISTEN=39743 STUB_UFW_HAS=39743
    manage "$1" diagnose
    local all="$output$stderr"
    [[ "$all" == *FAIL*awg0.conf*"'abc'"* ]] || { echo "$1: a corrupt ListenPort is not a FAIL naming awg0.conf: $all"; return 1; }
    [[ "$all" != *"39743/udp ALLOW"* ]] || { echo "$1: fell back to the init port: $all"; return 1; }
}
@test "diagnose: a corrupt ListenPort is a FAIL naming awg0.conf, both twins" {
    each_manage _diag_corrupt_listen
}

# ---------------------------------------------------------------- manage port <current>

# The fix named by the drift line: port with the port already in ListenPort
# writes it into the init and does nothing else - no restart, no UFW change, no
# regen (the clients may already carry it; regen stays the user's call).
_port_current_syncs_init() {
    set_listen 51820
    # A client in place: a regen would rewrite or refuse its config.
    printf '\n[Peer]\n#_Name = alice\nPublicKey = ALICEPUB\nAllowedIPs = 10.9.9.2/32\n' >> "$MGMT_DIR/awg/awg0.conf"
    printf '[Interface]\nPrivateKey = ALICEKEY\nAddress = 10.9.9.2/32\n[Peer]\nEndpoint = vpn.example.com:39743\n' > "$MGMT_DIR/awg/alice.conf"
    local conf_before alice_before; conf_before=$(cat "$MGMT_DIR/awg/awg0.conf"); alice_before=$(cat "$MGMT_DIR/awg/alice.conf")
    manage "$1" port 51820 --json
    [ "$status" -eq 0 ] || { echo "$1: port failed ($status): $stderr"; return 1; }
    [ "$(init_port)" = "51820" ] || { echo "$1: init AWG_PORT is '$(init_port)'"; return 1; }
    [ "$(cat "$MGMT_DIR/awg/awg0.conf")" = "$conf_before" ] || { echo "$1: awg0.conf changed"; return 1; }
    [ "$(cat "$MGMT_DIR/awg/alice.conf")" = "$alice_before" ] || { echo "$1: the client config was regenerated"; return 1; }
    [ -z "$(calls)" ] || { echo "$1: touched the system: $(calls)"; return 1; }
    printf '%s' "$output" | jq -e '.ok == true and .changed == false and .init_synced == true' >/dev/null \
        || { echo "$1: JSON does not say the init was synced: $output"; return 1; }
    local left; left=$(compgen -G "$MGMT_DIR/awg/*.bak.*" || true)
    [ -z "$left" ] || { echo "$1: copies left: $left"; return 1; }
}
@test "port <current port> writes it into an init that lags behind and touches nothing else, both twins" {
    require_flock
    require_jq
    each_manage _port_current_syncs_init
}

_port_current_in_sync_untouched() {
    local init_before; init_before=$(cat "$MGMT_DIR/awg/awgsetup_cfg.init")
    manage "$1" port 39743 --json
    [ "$status" -eq 0 ] || { echo "$1: port failed ($status): $stderr"; return 1; }
    [ "$(cat "$MGMT_DIR/awg/awgsetup_cfg.init")" = "$init_before" ] || { echo "$1: an init in sync was rewritten"; return 1; }
    printf '%s' "$output" | jq -e '.changed == false and (.init_synced // false) == false' >/dev/null \
        || { echo "$1: JSON claims a sync that did not happen: $output"; return 1; }
}
@test "port <current port> with the init in sync leaves the init as it is, both twins" {
    require_flock
    require_jq
    each_manage _port_current_in_sync_untouched
}

_port_current_init_without_key() {
    set_listen 51820
    sed -i '/^export AWG_PORT=/d' "$MGMT_DIR/awg/awgsetup_cfg.init"
    manage "$1" port 51820 --json
    [ "$status" -eq 0 ] || { echo "$1: port failed ($status): $stderr"; return 1; }
    [ "$(init_port)" = "51820" ] || { echo "$1: AWG_PORT not added: '$(init_port)'"; return 1; }
    [ -z "$(calls)" ] || { echo "$1: touched the system: $(calls)"; return 1; }
}
@test "port <current port> adds AWG_PORT to an init without it, both twins" {
    require_flock
    each_manage _port_current_init_without_key
}

# ---------------------------------------------------------------- reading ListenPort like awg

# awg applies the keys in order, so the last ListenPort wins, and it reads the
# key in any case.
_check_listen_last_and_case() {
    sed -i 's/^ListenPort = .*/ListenPort = 39743\nListenPort = 51820/' "$MGMT_DIR/awg/awg0.conf"
    export STUB_LISTEN=51820 STUB_UFW_HAS=51820
    manage "$1" check --json
    printf '%s' "$output" | jq -e '.port.number == 51820 and .port.listening == true' >/dev/null \
        || { echo "$1: two ListenPort lines, the first one was taken: $output"; return 1; }
    sed -i '/^ListenPort/d' "$MGMT_DIR/awg/awg0.conf"
    sed -i 's/^MTU = 1280$/MTU = 1280\nlistenport = 51820/' "$MGMT_DIR/awg/awg0.conf"
    manage "$1" check --json
    printf '%s' "$output" | jq -e '.port.number == 51820 and .port.source == "listen_port"' >/dev/null \
        || { echo "$1: a lowercase key fell back to the init: $output"; return 1; }
}
@test "check: the last ListenPort line counts and the key is read in any case, both twins" {
    require_jq
    each_manage _check_listen_last_and_case
}

_check_init_without_key() {
    set_listen 51820
    sed -i '/^export AWG_PORT=/d' "$MGMT_DIR/awg/awgsetup_cfg.init"
    export STUB_LISTEN=51820 STUB_UFW_HAS=51820
    manage "$1" check --json
    [ "$status" -eq 0 ] || { echo "$1: check failed ($status): $stderr"; return 1; }
    printf '%s' "$output" | jq -e '.port.number == 51820 and .port.init_mismatch == true' >/dev/null \
        || { echo "$1: an init without AWG_PORT is not a mismatch: $output"; return 1; }
    [[ "$stderr" == *"$(noinit_text "$1")"* && "$stderr" == *"port 51820"* ]] \
        || { echo "$1: an init without AWG_PORT is not named with its fix: $stderr"; return 1; }
}
@test "check: an init without AWG_PORT next to a good ListenPort is named with its fix, both twins" {
    require_jq
    each_manage _check_init_without_key
}

# AWG_PORT in root's environment is not the init: with the key missing from the
# file, an environment value equal to ListenPort must not hide the gap.
_check_init_port_not_from_env() {
    set_listen 51820
    sed -i '/^export AWG_PORT=/d' "$MGMT_DIR/awg/awgsetup_cfg.init"
    export STUB_LISTEN=51820 STUB_UFW_HAS=51820
    AWG_PORT=51820 manage "$1" check --json
    printf '%s' "$output" | jq -e '.port.init_mismatch == true' >/dev/null \
        || { echo "$1: the environment value passed for the init port: $output"; return 1; }
}
@test "check: AWG_PORT from the environment does not pass for the init port, both twins" {
    require_jq
    each_manage _check_init_port_not_from_env
}

# Control characters in the init value never reach the terminal raw.
_check_init_value_scrubbed() {
    printf 'export AWG_PORT=12\033[31mX\n' > "$MGMT_DIR/awg/init.new"
    grep -v '^export AWG_PORT=' "$MGMT_DIR/awg/awgsetup_cfg.init" >> "$MGMT_DIR/awg/init.new"
    mv "$MGMT_DIR/awg/init.new" "$MGMT_DIR/awg/awgsetup_cfg.init"
    export STUB_LISTEN=39743 STUB_UFW_HAS=39743
    manage "$1" check --json --no-color
    [[ "$stderr" == *"'12?[31mX'"* ]] || { echo "$1: the init value is not shown scrubbed: $stderr"; return 1; }
    [[ "$stderr" != *$'\033[31mX'* ]] || { echo "$1: a raw ESC from the init reached the output"; return 1; }
}
@test "check: an init port with control characters is shown scrubbed, both twins" {
    each_manage _check_init_value_scrubbed
}

_diag_corrupt_listen_no_ufw() {
    set_listen abc
    export STUB_LISTEN=39743
    PATH=$(path_without_ufw) manage "$1" diagnose
    local all="$output$stderr"
    [[ "$all" == *FAIL*awg0.conf*"'abc'"* ]] || { echo "$1: without ufw a corrupt ListenPort is not a FAIL: $all"; return 1; }
}
@test "diagnose: without ufw a corrupt ListenPort is still a FAIL, both twins" {
    each_manage _diag_corrupt_listen_no_ufw
}

# '08080' is port 8080: port with 8080 must not take it for a change.
_port_leading_zero() {
    sed -i 's/^ListenPort = .*/ListenPort = 08080/' "$MGMT_DIR/awg/awg0.conf"
    sed -i 's/^export AWG_PORT=.*/export AWG_PORT=8080/' "$MGMT_DIR/awg/awgsetup_cfg.init"
    export STUB_LISTEN=8080
    manage "$1" port 8080 --json
    [ "$status" -eq 0 ] || { echo "$1: a leading zero turned the current port into a change ($status): $stderr"; return 1; }
    printf '%s' "$output" | jq -e '.changed == false' >/dev/null || { echo "$1: $output"; return 1; }
    [ -z "$(calls)" ] || { echo "$1: touched the system: $(calls)"; return 1; }
}
@test "port with the current port written with a leading zero changes nothing, both twins" {
    require_flock
    require_jq
    each_manage _port_leading_zero
}

# The key in another case: port reads it and rewrites it.
_port_lowercase_key() {
    sed -i 's/^ListenPort = /listenport = /' "$MGMT_DIR/awg/awg0.conf"
    export STUB_LISTEN=39743
    manage "$1" port 23456
    [ "$status" -eq 0 ] || { echo "$1: port failed ($status): $stderr"; return 1; }
    grep -qx 'listenport = 23456' "$MGMT_DIR/awg/awg0.conf" || { echo "$1: the lowercase key was not rewritten: $(grep -i listenport "$MGMT_DIR/awg/awg0.conf")"; return 1; }
    [ "$(init_port)" = "23456" ] || { echo "$1: init AWG_PORT is '$(init_port)'"; return 1; }
}
@test "port rewrites a ListenPort key written in another case, both twins" {
    require_flock
    each_manage _port_lowercase_key
}
