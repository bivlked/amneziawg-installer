#!/usr/bin/env bats
# manage block-ru: VPN clients cannot reach Russian IPv4 addresses (D#418).
#
# manage writes a small helper (awg-block-ru.sh) and a systemd unit tied to
# awg-quick@awg0. The helper loads a list of Russian networks into the ipset
# awg_block_ru and puts one REJECT rule at the top of FORWARD for traffic that
# comes in from awg0. The unit never calls manage: exit-ip and port hold the
# config lock while they start awg-quick, and a start of awg-quick pulls this
# unit in. Starting the unit uses the cached list and goes to the network only
# when there is none; a reload (weekly cron, manage block-ru update) downloads.
#
# The stubs keep state in files, so the unit lines manage writes are executed:
# systemctl start/restart runs ExecStart of the written unit, stop runs
# ExecStop, reload runs ExecReload.
# shellcheck disable=SC2154  # $stderr is set by bats `run --separate-stderr`

load test_helper

bats_require_minimum_version 1.5.0

SET=awg_block_ru
RULE='FORWARD -i awg0 -m set --match-set awg_block_ru dst -j REJECT --reject-with icmp-admin-prohibited'

# make_list <file> <count>: <count> distinct IPv4 networks, one per line.
make_list() {
    local i
    for (( i = 0; i < $2; i++ )); do printf '10.%d.%d.0/24\n' $(( i / 256 )) $(( i % 256 )); done > "$1"
}

setup_block_env() {
    # each_manage runs both scripts in one test: no stub switch carries over.
    unset STUB_START_FAIL STUB_IPT_I_FAIL STUB_IPSET_RESTORE_FAIL STUB_IPSET_HAS STUB_APT_FAIL STUB_IPSET_REAL STUB_AWG_DOWN STUB_FLOCK_FAIL STUB_APT_NEEDS_UPDATE STUB_CURL_SNAP
    MGMT_DIR=$(mktemp -d)
    mkdir -p "$MGMT_DIR/bin" "$MGMT_DIR/awg/keys" "$MGMT_DIR/systemd" "$MGMT_DIR/cron" "$MGMT_DIR/web"
    export CALLS="$MGMT_DIR/calls"; : > "$CALLS"
    export AWG_SYSTEMD_DIR="$MGMT_DIR/systemd" AWG_CRON_DIR="$MGMT_DIR/cron"
    export STUB_WEB="$MGMT_DIR/web"
    cat > "$MGMT_DIR/bin/awg" << 'STUB'
#!/bin/bash
exit 0
STUB
    # systemctl: the state of awg-block-ru lives in files; start/restart/stop/reload
    # run the matching Exec line of the unit manage wrote.
    cat > "$MGMT_DIR/bin/systemctl" << 'STUB'
#!/bin/bash
echo "systemctl $*" >> "$CALLS"
unit="$AWG_SYSTEMD_DIR/awg-block-ru.service"
run_exec() {
    local line
    line=$(sed -n "s/^$1=//p" "$unit" | head -1)
    [[ -n "$line" ]] || return 1
    timeout 10 bash -c "$line"
}
case "$1" in
    is-enabled) [[ -e "$CALLS.enabled" ]] && { echo enabled; exit 0; }; echo disabled; exit 1 ;;
    is-active)  if [[ "$*" == *awg-quick* ]]; then [[ -z "${STUB_AWG_DOWN:-}" ]]; exit; fi
                [[ "$*" == *awg-block-ru* ]] || exit 0
                q=0; [[ " $* " == *" --quiet "* ]] && q=1
                if [[ -e "$CALLS.active" ]]; then (( q )) || echo active; exit 0; fi
                (( q )) || echo inactive; exit 3 ;;
    daemon-reload) exit 0 ;;
    enable)  [[ -e "$unit" ]] || exit 1; : > "$CALLS.enabled" ;;
    disable) rm -f "$CALLS.enabled"
             if [[ " $* " == *" --now "* && -e "$CALLS.active" ]]; then
                 rm -f "$CALLS.active"
                 run_exec ExecStop || exit 1
             fi ;;
    start|restart)
        [[ "$*" == *awg-block-ru* ]] || exit 0
        [[ -n "${STUB_START_FAIL:-}" ]] && exit 1
        if [[ "$1" == restart && -e "$CALLS.active" ]]; then run_exec ExecStop; fi
        run_exec ExecStart || { rm -f "$CALLS.active"; exit 1; }
        : > "$CALLS.active" ;;
    stop)   [[ -e "$CALLS.active" ]] && run_exec ExecStop; rm -f "$CALLS.active" ;;
    reload) [[ -e "$CALLS.active" ]] || exit 1; run_exec ExecReload ;;
esac
exit 0
STUB
    # iptables: rules of FORWARD in a file, newest -I on top.
    cat > "$MGMT_DIR/bin/iptables" << 'STUB'
#!/bin/bash
echo "iptables $*" >> "$CALLS.ipt"
F="$CALLS.fw"; touch "$F"
[[ "$1" == -w ]] && shift
[[ "$1" =~ ^[0-9]+$ ]] && shift
op="$1"; shift
case "$op" in
    -C) grep -qxF -- "$*" "$F" ;;
    -I) [[ -n "${STUB_IPT_I_FAIL:-}" ]] && exit 1
        { echo "$*"; cat "$F"; } > "$F.n"; mv "$F.n" "$F" ;;
    -A) echo "$*" >> "$F" ;;
    -D) if [[ $# -eq 2 && "$2" =~ ^[0-9]+$ ]]; then sed -i "${2}d" "$F"; exit; fi
        n=$(grep -nxF -- "$*" "$F" | head -1 | cut -d: -f1)
        [[ -n "$n" ]] || exit 1
        sed -i "${n}d" "$F" ;;
    -S) echo "-P FORWARD DROP"; sed 's/^/-A /' "$F" ;;
esac
STUB
    # ipset: every set is a file of entries.
    cat > "$MGMT_DIR/bin/ipset" << 'STUB'
#!/bin/bash
echo "ipset $*" >> "$CALLS.ipset"
S="$CALLS.sets"; mkdir -p "$S"
case "$1" in
    create)  if [[ -e "$S/$2" ]]; then [[ " $* " == *" -exist "* ]] && exit 0; echo "set $2 exists" >&2; exit 1; fi
             : > "$S/$2" ;;
    destroy) [[ -e "$S/$2" ]] || { echo "no set $2" >&2; exit 1; }; rm -f "$S/$2" ;;
    swap)    [[ -e "$S/$2" && -e "$S/$3" ]] || exit 1
             mv "$S/$2" "$S/.t"; mv "$S/$3" "$S/$2"; mv "$S/.t" "$S/$3" ;;
    restore) if [[ -n "${STUB_IPSET_RESTORE_FAIL:-}" ]]; then cat > /dev/null; exit 1; fi
             if [[ -e "$CALLS.restore_fail_once" ]]; then rm -f "$CALLS.restore_fail_once"; cat > /dev/null; exit 1; fi
             while read -r a n v; do
                 [[ "$a" == add && -e "$S/$n" ]] || { echo "restore: bad line '$a $n $v'" >&2; exit 1; }
                 echo "$v" >> "$S/$n"
             done ;;
    add)     [[ -e "$S/$2" ]] || exit 1
             # a prefix over 32 is refused, as ipset itself does
             [[ "$3" == */* && "${3##*/}" -gt 32 ]] && { echo "ipset v7: Syntax error: '$3' is out of range" >&2; exit 1; }
             echo "$3" >> "$S/$2" ;;
    list)    if [[ "$2" == -n ]]; then ls "$S"; exit 0; fi
             [[ -e "$S/$2" ]] || { echo "The set with the given name does not exist" >&2; exit 1; }
             echo "Name: $2"; echo "Number of entries: $(grep -c . "$S/$2")" ;;
    test)    [[ -e "$S/$2" ]] || exit 1
             [[ " ${STUB_IPSET_HAS:-} " == *" $3 "* ]] ;;
esac
STUB
    # curl: the file for a URL is $STUB_WEB/<last path element>; no file = failure.
    cat > "$MGMT_DIR/bin/curl" << 'STUB'
#!/bin/bash
echo "curl $*" >> "$CALLS.curl"
# the FORWARD rules as they stand at the moment of the download
[[ -n "${STUB_CURL_SNAP:-}" ]] && cat "$CALLS.fw" > "$CALLS.fw_at_curl" 2>/dev/null
out="" url=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        --max-time) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
src="$STUB_WEB/${url##*/}"
[[ -f "$src" ]] || exit 22
cp "$src" "$out"
STUB
    cat > "$MGMT_DIR/bin/apt-get" << 'STUB'
#!/bin/bash
echo "apt-get $*" >> "$CALLS.apt"
[[ -n "${STUB_APT_FAIL:-}" ]] && exit 100
[[ "$1" == update ]] && : > "$CALLS.apt_updated"
[[ -n "${STUB_APT_NEEDS_UPDATE:-}" && " $* " == *" install "* && ! -e "$CALLS.apt_updated" ]] && exit 100
[[ " $* " == *" install "* ]] && cp "$STUB_IPSET_REAL" "$(dirname "$0")/ipset"
exit 0
STUB
    # flock: the real one, or a timeout when STUB_FLOCK_FAIL is set
    printf '#!/bin/bash\n[[ -n "${STUB_FLOCK_FAIL:-}" ]] && exit 1\nexec %s "$@"\n' "$(command -v flock)" > "$MGMT_DIR/bin/flock"
    chmod +x "$MGMT_DIR/bin/"*
    export PATH="$MGMT_DIR/bin:$PATH"
    cat > "$MGMT_DIR/awg/awgsetup_cfg.init" << 'CONF'
export AWG_PORT=39743
export AWG_TUNNEL_SUBNET='10.9.9.1/24'
export DISABLE_IPV6=1
export ALLOW_IPV6_TUNNEL=0
export ALLOWED_IPS_MODE=1
export ALLOWED_IPS='0.0.0.0/0'
CONF
    cat > "$MGMT_DIR/awg/awg0.conf" << 'CONF'
[Interface]
PrivateKey = TESTKEY
Address = 10.9.9.1/24
ListenPort = 39743
PostUp = iptables -I FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
CONF
    make_list "$STUB_WEB/ru-aggregated.zone" 1200
    export AWG_SKIP_APPLY=1
}

teardown() {
    rm -rf "$TEST_DIR" "${MGMT_DIR:-}"
    unset AWG_SKIP_APPLY CALLS STUB_WEB AWG_SYSTEMD_DIR AWG_CRON_DIR STUB_START_FAIL STUB_IPT_I_FAIL \
        STUB_IPSET_RESTORE_FAIL STUB_IPSET_HAS STUB_APT_FAIL STUB_IPSET_REAL STUB_AWG_DOWN STUB_FLOCK_FAIL STUB_APT_NEEDS_UPDATE
}

manage() {
    local script="$1"; shift
    local lib="awg_common.sh"
    [[ "$script" == *_en.sh ]] && lib="awg_common_en.sh"
    cp "$BATS_TEST_DIRNAME/../$lib" "$MGMT_DIR/awg/awg_common.sh"
    run --separate-stderr bash "$BATS_TEST_DIRNAME/../$script" "$@" --yes \
        --conf-dir="$MGMT_DIR/awg" --server-conf="$MGMT_DIR/awg/awg0.conf"
}

helper() { run --separate-stderr "$MGMT_DIR/awg/awg-block-ru.sh" "$@"; }
fw() { cat "$CALLS.fw" 2>/dev/null; }
set_size() { grep -c . "$CALLS.sets/$1" 2>/dev/null || echo none; }
unit() { cat "$AWG_SYSTEMD_DIR/awg-block-ru.service"; }

each_manage() {
    local seen=0 s
    for s in manage_amneziawg.sh manage_amneziawg_en.sh; do
        setup_block_env
        "$1" "$s" || return 1
        rm -rf "$MGMT_DIR"
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}

# ---------- on ----------

_on_writes_and_applies() {
    manage "$1" block-ru on
    [ "$status" -eq 0 ] || { echo "$1: on failed: $stderr"; return 1; }
    [ -x "$MGMT_DIR/awg/awg-block-ru.sh" ] || { echo "$1: no executable helper"; return 1; }
    unit | grep -qxF "ExecStart=$MGMT_DIR/awg/awg-block-ru.sh apply" || { echo "$1: ExecStart: $(unit)"; return 1; }
    unit | grep -qxF "ExecReload=$MGMT_DIR/awg/awg-block-ru.sh update" || { echo "$1: ExecReload"; return 1; }
    unit | grep -qxF "ExecStop=$MGMT_DIR/awg/awg-block-ru.sh stop" || { echo "$1: ExecStop"; return 1; }
    unit | grep -qxF "PartOf=awg-quick@awg0.service" || { echo "$1: PartOf"; return 1; }
    unit | grep -qxF "Requisite=awg-quick@awg0.service" || { echo "$1: Requisite"; return 1; }
    unit | grep -qxF "WantedBy=awg-quick@awg0.service" || { echo "$1: WantedBy"; return 1; }
    unit | grep -qxF "After=awg-quick@awg0.service network-online.target" || { echo "$1: After"; return 1; }
    grep -qE '^[0-9]{1,2} 4 \* \* 1 root systemctl is-active --quiet awg-quick@awg0 && systemctl reload-or-restart awg-block-ru\.service$' "$AWG_CRON_DIR/awg-block-ru" \
        || { echo "$1: cron: $(cat "$AWG_CRON_DIR/awg-block-ru" 2>&1)"; return 1; }
    grep -qxF "systemctl enable awg-block-ru.service" "$CALLS" || { echo "$1: not enabled: $(cat "$CALLS")"; return 1; }
    # The rule is on top of FORWARD, once, and the set holds the whole list.
    [ "$(fw | head -1)" = "$RULE" ] || { echo "$1: top rule '$(fw | head -1)'"; return 1; }
    [ "$(fw | grep -cxF "$RULE")" = "1" ] || { echo "$1: rule count"; return 1; }
    [ "$(set_size $SET)" = "1200" ] || { echo "$1: set size $(set_size $SET)"; return 1; }
    [ ! -e "$CALLS.sets/${SET}_new" ] || { echo "$1: temporary set left"; return 1; }
    [ "$(grep -c . "$MGMT_DIR/awg/block-ru.zone")" = "1200" ] || { echo "$1: no cached list"; return 1; }
}
@test "block-ru on: helper, unit and cron are written, the rule is on top, the set is full" {
    each_manage _on_writes_and_applies
}

_on_json() {
    manage "$1" block-ru on --json
    [ "$status" -eq 0 ] || { echo "$1: $stderr"; return 1; }
    [ "$(jq -r '.command' <<< "$output")" = "block-ru" ] || { echo "$1: json '$output'"; return 1; }
    [ "$(jq -r '.ok' <<< "$output")" = "true" ] || return 1
    [ "$(jq -r '.enabled' <<< "$output")" = "true" ] || return 1
    [ "$(jq -r '.rule' <<< "$output")" = "true" ] || return 1
    [ "$(jq -r '.networks' <<< "$output")" = "1200" ] || { echo "$1: networks '$output'"; return 1; }
}
@test "block-ru on --json: one document with enabled, rule and networks" {
    command -v jq >/dev/null || skip "jq not available"
    each_manage _on_json
}

_on_twice() {
    manage "$1" block-ru on
    [ "$status" -eq 0 ] || return 1
    manage "$1" block-ru on
    [ "$status" -eq 0 ] || { echo "$1: second on failed: $stderr"; return 1; }
    [ "$(fw | grep -cxF "$RULE")" = "1" ] || { echo "$1: rule doubled: $(fw)"; return 1; }
    [ "$(fw | head -1)" = "$RULE" ] || return 1
}
@test "block-ru on twice: still one rule on top" {
    each_manage _on_twice
}

_on_no_list() {
    rm -f "$STUB_WEB"/*
    manage "$1" block-ru on
    [ "$status" -ne 0 ] || { echo "$1: on without any list succeeded"; return 1; }
    [ ! -e "$AWG_SYSTEMD_DIR/awg-block-ru.service" ] || { echo "$1: unit left after a failed first on"; return 1; }
    [ ! -e "$AWG_CRON_DIR/awg-block-ru" ] || { echo "$1: cron left"; return 1; }
    [ ! -e "$CALLS.enabled" ] || { echo "$1: left enabled"; return 1; }
    [ "$(fw | grep -cF awg_block_ru)" = "0" ] || { echo "$1: rule present without a list"; return 1; }
}
@test "block-ru on: no list anywhere - fails loudly, nothing stays behind" {
    each_manage _on_no_list
}

_on_installs_ipset() {
    mv "$MGMT_DIR/bin/ipset" "$MGMT_DIR/ipset.real"
    export STUB_IPSET_REAL="$MGMT_DIR/ipset.real"
    manage "$1" block-ru on
    [ "$status" -eq 0 ] || { echo "$1: $stderr"; return 1; }
    grep -qE '^apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y ipset$' "$CALLS.apt" || { echo "$1: no apt-get install: $(cat "$CALLS.apt" 2>&1)"; return 1; }
    [ "$(fw | head -1)" = "$RULE" ] || return 1
}
@test "block-ru on: ipset is missing - it is installed with apt-get" {
    each_manage _on_installs_ipset
}

_on_ipset_install_fails() {
    mv "$MGMT_DIR/bin/ipset" "$MGMT_DIR/ipset.real"
    export STUB_IPSET_REAL="$MGMT_DIR/ipset.real" STUB_APT_FAIL=1
    manage "$1" block-ru on
    [ "$status" -ne 0 ] || { echo "$1: succeeded without ipset"; return 1; }
    [[ "$stderr" == *"apt update && apt install -y ipset"* ]] || { echo "$1: no manual command: $stderr"; return 1; }
    [ ! -e "$AWG_SYSTEMD_DIR/awg-block-ru.service" ] || return 1
    [ ! -e "$MGMT_DIR/awg/awg-block-ru.sh" ] || return 1
}
@test "block-ru on: ipset cannot be installed - refused with the manual command, nothing written" {
    each_manage _on_ipset_install_fails
}

_on_start_fails_was_off() {
    export STUB_START_FAIL=1
    manage "$1" block-ru on
    [ "$status" -ne 0 ] || return 1
    [ ! -e "$AWG_SYSTEMD_DIR/awg-block-ru.service" ] || { echo "$1: unit left"; return 1; }
    [ ! -e "$CALLS.enabled" ] || { echo "$1: left enabled"; return 1; }
    [[ "$stderr" == *"journalctl -u awg-block-ru"* ]] || { echo "$1: no hint: $stderr"; return 1; }
}
@test "block-ru on: the unit does not start on a server where it was off - rolled back" {
    each_manage _on_start_fails_was_off
}

_on_warns_ipv6() {
    sed -i 's/^export ALLOW_IPV6_TUNNEL=0/export ALLOW_IPV6_TUNNEL=1/' "$MGMT_DIR/awg/awgsetup_cfg.init"
    manage "$1" block-ru on
    [ "$status" -eq 0 ] || return 1
    [[ "$stderr$output" == *"IPv6"* ]] || { echo "$1: no IPv6 warning"; return 1; }
}
@test "block-ru on: with the IPv6 tunnel for clients it warns that IPv6 stays open" {
    each_manage _on_warns_ipv6
}

_on_warns_dns() {
    echo "export CLIENT_DNS='77.88.8.8, 1.1.1.1'" >> "$MGMT_DIR/awg/awgsetup_cfg.init"
    export STUB_IPSET_HAS="77.88.8.8"
    manage "$1" block-ru on
    [ "$status" -eq 0 ] || return 1
    [[ "$stderr$output" == *"77.88.8.8"* ]] || { echo "$1: no DNS warning: $stderr"; return 1; }
    [[ "$stderr$output" != *"1.1.1.1 "* ]] || { echo "$1: warned about a foreign DNS too"; return 1; }
}
@test "block-ru on: a client DNS server inside the list is named in a warning" {
    each_manage _on_warns_dns
}

_on_warns_cascade() {
    mkdir -p "$CALLS.sets"; : > "$CALLS.sets/ru"
    manage "$1" block-ru on
    [ "$status" -eq 0 ] || return 1
    [[ "$stderr$output" == *"CASCADE"* ]] || { echo "$1: no cascade warning: $stderr"; return 1; }
}
@test "block-ru on: the cascade set 'ru' exists - warns about the conflict" {
    each_manage _on_warns_cascade
}

# ---------- off, status, update ----------

_off_removes() {
    manage "$1" block-ru on
    [ "$status" -eq 0 ] || return 1
    echo "203.0.113.0/24" > "$MGMT_DIR/awg/block-ru.extra"
    manage "$1" block-ru off
    [ "$status" -eq 0 ] || { echo "$1: off failed: $stderr"; return 1; }
    grep -qF "systemctl disable --now awg-block-ru.service" "$CALLS" || { echo "$1: no disable --now"; return 1; }
    # ExecStop ran and succeeded: manage took the helper lock only after it.
    [[ "$stderr" != *"disable --now awg-block-ru.service"* ]] || { echo "$1: ExecStop failed: $stderr"; return 1; }
    [ "$(fw | grep -cF awg_block_ru)" = "0" ] || { echo "$1: rule left: $(fw)"; return 1; }
    [ ! -e "$CALLS.sets/$SET" ] || { echo "$1: set left"; return 1; }
    local f
    for f in "$AWG_SYSTEMD_DIR/awg-block-ru.service" "$AWG_CRON_DIR/awg-block-ru" \
             "$MGMT_DIR/awg/awg-block-ru.sh" "$MGMT_DIR/awg/block-ru.zone"; do
        [ ! -e "$f" ] || { echo "$1: $f left"; return 1; }
    done
    # The list of the owner's own networks stays: it is the user's data.
    [ -s "$MGMT_DIR/awg/block-ru.extra" ] || { echo "$1: extra removed"; return 1; }
}
@test "block-ru off: unit, cron, helper, list, rule and set are removed; the own list stays" {
    each_manage _off_removes
}

_off_when_off() {
    manage "$1" block-ru off
    [ "$status" -eq 0 ] || { echo "$1: $stderr"; return 1; }
    run grep -c "disable" "$CALLS"
    [ "$output" = "0" ] || { echo "$1: disable called on an off server"; return 1; }
}
@test "block-ru off on a server where it is off: success, nothing to do" {
    each_manage _off_when_off
}

_status() {
    manage "$1" block-ru --json
    [ "$status" -eq 0 ] || { echo "$1: $stderr"; return 1; }
    [ "$(jq -r '.enabled' <<< "$output")" = "false" ] || { echo "$1: '$output'"; return 1; }
    manage "$1" block-ru on
    manage "$1" block-ru status --json
    [ "$status" -eq 0 ] || return 1
    [ "$(jq -r '.enabled' <<< "$output")" = "true" ] || { echo "$1: '$output'"; return 1; }
    [ "$(jq -r '.active' <<< "$output")" = "true" ] || return 1
    [ "$(jq -r '.rule' <<< "$output")" = "true" ] || return 1
    [ "$(jq -r '.networks' <<< "$output")" = "1200" ] || return 1
    [ "$(jq -r '.in_force' <<< "$output")" = "true" ] || { echo "$1: '$output'"; return 1; }
}
@test "block-ru status: off and then on, as JSON" {
    command -v jq >/dev/null || skip "jq not available"
    each_manage _status
}

_update_off() {
    manage "$1" block-ru update
    [ "$status" -ne 0 ] || { echo "$1: update on an off server succeeded"; return 1; }
}
@test "block-ru update on a server where it is off: refused" {
    each_manage _update_off
}

_update_downloads() {
    manage "$1" block-ru on
    [ "$status" -eq 0 ] || return 1
    make_list "$STUB_WEB/ru-aggregated.zone" 1300
    manage "$1" block-ru update
    [ "$status" -eq 0 ] || { echo "$1: update failed: $stderr"; return 1; }
    [ "$(set_size $SET)" = "1300" ] || { echo "$1: set size $(set_size $SET)"; return 1; }
    [ "$(fw | grep -cxF "$RULE")" = "1" ] || return 1
}
@test "block-ru update: a fresh list replaces the set" {
    each_manage _update_downloads
}

_bad_sub() {
    manage "$1" block-ru maybe
    [ "$status" -ne 0 ] || return 1
}
@test "block-ru with an unknown argument: refused" {
    each_manage _bad_sub
}

_usage_lists() {
    run bash "$BATS_TEST_DIRNAME/../$1" help
    [[ "$output" == *"block-ru"* ]] || { echo "$1: help has no block-ru"; return 1; }
}
@test "help lists block-ru in both scripts" {
    _usage_lists manage_amneziawg.sh && _usage_lists manage_amneziawg_en.sh
}

# ---------- the helper on its own ----------

# on_then <script>: turn on, then clear the stub state so a test starts from a
# written helper and an empty firewall.
on_then() {
    manage "$1" block-ru on
    [ "$status" -eq 0 ] || { echo "$1: on failed: $stderr"; return 1; }
    rm -rf "$CALLS.sets" "$CALLS.fw" "$CALLS.ipset" "$CALLS.curl" "$MGMT_DIR/awg/block-ru.zone"
}

_helper_fallback_url() {
    on_then "$1" || return 1
    printf '<html>not a list</html>\n' > "$STUB_WEB/ru-aggregated.zone"
    make_list "$STUB_WEB/ru.zone" 1100
    helper apply
    [ "$status" -eq 0 ] || { echo "$1: $stderr"; return 1; }
    [ "$(set_size $SET)" = "1100" ] || { echo "$1: set $(set_size $SET)"; return 1; }
    grep -qE "raw\.githubusercontent\.com/bivlked/amneziawg-installer/v[0-9]+\.[0-9]+\.[0-9]+/cascade/ru\.zone" "$CALLS.curl" \
        || { echo "$1: fallback url: $(cat "$CALLS.curl")"; return 1; }
}
@test "helper: the first source gives HTML - the snapshot from the release tag is used" {
    each_manage _helper_fallback_url
}

_helper_rejects_mixed() {
    on_then "$1" || return 1
    make_list "$STUB_WEB/ru-aggregated.zone" 1200
    echo "<b>oops</b>" >> "$STUB_WEB/ru-aggregated.zone"
    rm -f "$STUB_WEB/ru.zone"
    helper apply
    [ "$status" -ne 0 ] || { echo "$1: a list with a foreign line was accepted"; return 1; }
    [ "$(fw | grep -cF awg_block_ru)" = "0" ] || return 1
}
@test "helper: a list with a single non-network line is refused" {
    each_manage _helper_rejects_mixed
}

_helper_short_list() {
    on_then "$1" || return 1
    make_list "$STUB_WEB/ru-aggregated.zone" 999
    rm -f "$STUB_WEB/ru.zone"
    helper apply
    [ "$status" -ne 0 ] || { echo "$1: 999 networks accepted"; return 1; }
}
@test "helper: fewer than 1000 networks is refused" {
    each_manage _helper_short_list
}

_helper_crlf() {
    on_then "$1" || return 1
    sed -i 's/$/\r/' "$STUB_WEB/ru-aggregated.zone"
    helper apply
    [ "$status" -eq 0 ] || { echo "$1: CRLF list refused: $stderr"; return 1; }
    [ "$(set_size $SET)" = "1200" ] || return 1
    run grep -c $'\r' "$CALLS.sets/$SET"
    [ "$output" = "0" ] || { echo "$1: CR went into the set"; return 1; }
}
@test "helper: a list with CRLF line ends is accepted without the CR" {
    each_manage _helper_crlf
}

_helper_apply_uses_cache() {
    on_then "$1" || return 1
    make_list "$MGMT_DIR/awg/block-ru.zone" 1050
    : > "$CALLS.curl"
    helper apply
    [ "$status" -eq 0 ] || return 1
    [ ! -s "$CALLS.curl" ] || { echo "$1: apply went to the network with a cached list"; return 1; }
    [ "$(set_size $SET)" = "1050" ] || return 1
}
@test "helper apply: a cached list is used without the network" {
    each_manage _helper_apply_uses_cache
}

_helper_update_keeps_old() {
    on_then "$1" || return 1
    make_list "$MGMT_DIR/awg/block-ru.zone" 1050
    rm -f "$STUB_WEB"/*
    helper update
    [ "$status" -eq 3 ] || { echo "$1: rc $status, want 3"; return 1; }
    [ "$(set_size $SET)" = "1050" ] || return 1
    [ "$(fw | head -1)" = "$RULE" ] || return 1
}
@test "helper update: download fails - the cached list stays in force, rc 3" {
    each_manage _helper_update_keeps_old
}

_helper_extra() {
    on_then "$1" || return 1
    printf '203.0.113.0/24\n# comment\n\n198.51.100.7\nnot-a-net\n' > "$MGMT_DIR/awg/block-ru.extra"
    helper apply
    [ "$status" -eq 0 ] || return 1
    grep -qxF "203.0.113.0/24" "$CALLS.sets/$SET" || return 1
    grep -qxF "198.51.100.7" "$CALLS.sets/$SET" || return 1
    [ "$(set_size $SET)" = "1202" ] || { echo "$1: set $(set_size $SET)"; return 1; }
    [[ "$stderr" == *"not-a-net"* ]] || { echo "$1: the bad line is not named"; return 1; }
}
@test "helper: block-ru.extra adds own networks, skips and names a bad line" {
    each_manage _helper_extra
}

_helper_restore_fails() {
    on_then "$1" || return 1
    mkdir -p "$CALLS.sets"; echo "192.0.2.0/24" > "$CALLS.sets/$SET"
    export STUB_IPSET_RESTORE_FAIL=1
    helper apply
    [ "$status" -ne 0 ] || return 1
    [ "$(cat "$CALLS.sets/$SET")" = "192.0.2.0/24" ] || { echo "$1: the old set was replaced"; return 1; }
    [ ! -e "$CALLS.sets/${SET}_new" ] || { echo "$1: temporary set left"; return 1; }
    run grep -c "ipset swap" "$CALLS.ipset"
    [ "$output" = "0" ] || return 1
}
@test "helper: ipset restore fails - no swap, the old set stays, the temporary one is gone" {
    each_manage _helper_restore_fails
}

_helper_stop() {
    on_then "$1" || return 1
    printf '%s\n%s\nFORWARD -i awg0 -j ACCEPT\n' "$RULE" "$RULE" > "$CALLS.fw"
    helper stop
    [ "$status" -eq 0 ] || return 1
    [ "$(fw)" = "FORWARD -i awg0 -j ACCEPT" ] || { echo "$1: left '$(fw)'"; return 1; }
}
@test "helper stop: every copy of the rule is removed, other rules stay" {
    each_manage _helper_stop
}

_helper_reorders() {
    on_then "$1" || return 1
    # awg-quick restarted under the unit: its ACCEPT is now above our rule.
    printf 'FORWARD -i awg0 -j ACCEPT\n%s\n' "$RULE" > "$CALLS.fw"
    helper apply
    [ "$status" -eq 0 ] || return 1
    [ "$(fw | head -1)" = "$RULE" ] || { echo "$1: not on top: $(fw)"; return 1; }
    [ "$(fw | grep -cxF "$RULE")" = "1" ] || return 1
}
@test "helper apply: a rule pushed down by another rule is moved back to the top" {
    each_manage _helper_reorders
}

_helpers_same_code() {
    local a b
    setup_block_env; manage manage_amneziawg.sh block-ru on
    a=$(grep -vE '^[[:space:]]*#|echo|printf|^DIR=' "$MGMT_DIR/awg/awg-block-ru.sh" | sed -E 's/fail "[^"]*"/fail MSG/')
    rm -rf "$MGMT_DIR"
    setup_block_env; manage manage_amneziawg_en.sh block-ru on
    b=$(grep -vE '^[[:space:]]*#|echo|printf|^DIR=' "$MGMT_DIR/awg/awg-block-ru.sh" | sed -E 's/fail "[^"]*"/fail MSG/')
    [ -n "$a" ] && [ "$a" = "$b" ] || { diff <(echo "$a") <(echo "$b"); return 1; }
}
@test "the RU and EN helpers differ only in messages" {
    _helpers_same_code
}

# ---------- the installer: uninstall ----------

_uninstall_block_ru() {
    local inst="$1" d
    d=$(mktemp -d)
    mkdir -p "$d/systemd" "$d/cron" "$d/bin"
    : > "$d/systemd/awg-block-ru.service"; : > "$d/cron/awg-block-ru"
    printf '#!/bin/bash\necho "$(basename "$0") $*" >> "%s/calls"\n' "$d" > "$d/bin/systemctl"
    cp "$d/bin/systemctl" "$d/bin/ipset"
    # No rule is left in FORWARD: -C answers "absent".
    printf '#!/bin/bash\necho "iptables $*" >> "%s/calls"\nexit 1\n' "$d" > "$d/bin/iptables"
    chmod +x "$d/bin/"*
    run env PATH="$d/bin:$PATH" AWG_SYSTEMD_DIR="$d/systemd" AWG_CRON_DIR="$d/cron" bash -c '
        log() { :; }; log_warn() { :; }
        eval "$(awk "/^_uninstall_block_ru\\(\\) \\{/,/^\\}/" "$1")"
        _uninstall_block_ru' _ "$BATS_TEST_DIRNAME/../$inst"
    [ "$status" -eq 0 ] || { echo "$inst: $output"; rm -rf "$d"; return 1; }
    [ ! -e "$d/systemd/awg-block-ru.service" ] && [ ! -e "$d/cron/awg-block-ru" ] || { echo "$inst: files left"; rm -rf "$d"; return 1; }
    grep -qxF "systemctl disable --now awg-block-ru.service" "$d/calls" || { echo "$inst: $(cat "$d/calls")"; rm -rf "$d"; return 1; }
    grep -qxF "ipset destroy awg_block_ru" "$d/calls" || { echo "$inst: set not destroyed"; rm -rf "$d"; return 1; }
    rm -rf "$d"
}
@test "uninstall removes the block-ru unit, cron and set in both installers" {
    _uninstall_block_ru install_amneziawg.sh && _uninstall_block_ru install_amneziawg_en.sh
}

# ---------- review round: start order, failed reload, off against update ----------

_on_awg_down() {
    local json
    export STUB_AWG_DOWN=1
    manage "$1" block-ru on --json
    [ "$status" -eq 0 ] || { echo "$1: $stderr"; return 1; }
    json=$output
    [ -e "$CALLS.enabled" ] || { echo "$1: not enabled"; return 1; }
    run grep -c "systemctl restart awg-block-ru" "$CALLS"
    [ "$output" = "0" ] || { echo "$1: started while awg0 is down"; return 1; }
    [ "$(fw | grep -cF awg_block_ru)" = "0" ] || return 1
    [[ "$stderr" == *"awg0"* ]] || { echo "$1: no word on awg0: $stderr"; return 1; }
    [ "$(grep -c . "$MGMT_DIR/awg/block-ru.zone")" = "1200" ] || { echo "$1: the list was not downloaded now"; return 1; }
    [ "$(jq -r '.in_force' <<< "$json")" = "false" ] || { echo "$1: in force with awg0 down: $json"; return 1; }
    manage "$1" block-ru --json
    [ "$(jq -r '.in_force' <<< "$output")" = "false" ] || return 1
    [[ "$stderr" == *"awg-quick@awg0"* ]] || { echo "$1: status names no reason: $stderr"; return 1; }
}
@test "block-ru on while awg0 is stopped: enabled, not started, the block comes with awg0" {
    command -v jq >/dev/null || skip "jq not available"
    each_manage _on_awg_down
}

_status_not_first() {
    manage "$1" block-ru on
    [ "$status" -eq 0 ] || return 1
    printf 'FORWARD -i awg0 -j ACCEPT\n%s\n' "$RULE" > "$CALLS.fw"
    manage "$1" block-ru --json
    [ "$status" -eq 0 ] || return 1
    [ "$(jq -r '.rule' <<< "$output")" = "true" ] || return 1
    [ "$(jq -r '.rule_first' <<< "$output")" = "false" ] || { echo "$1: '$output'"; return 1; }
    [[ "$stderr" == *"systemctl restart awg-block-ru"* ]] || { echo "$1: no warning: $stderr"; return 1; }
}
@test "block-ru status: a rule pushed down is reported, the block does not look fine" {
    command -v jq >/dev/null || skip "jq not available"
    each_manage _status_not_first
}

_extra_out_of_range() {
    on_then "$1" || return 1
    printf '203.0.113.0/24\n203.0.113.7/99\n' > "$MGMT_DIR/awg/block-ru.extra"
    helper apply
    [ "$status" -eq 0 ] || { echo "$1: one bad extra line broke the load: $stderr"; return 1; }
    [ "$(set_size $SET)" = "1201" ] || { echo "$1: set $(set_size $SET)"; return 1; }
    [[ "$stderr" == *"203.0.113.7/99"* ]] || return 1
    [ "$(fw | head -1)" = "$RULE" ] || return 1
}
@test "helper: an extra line ipset refuses is skipped, the rest loads" {
    each_manage _extra_out_of_range
}

_failed_load_keeps_block() {
    on_then "$1" || return 1
    mkdir -p "$CALLS.sets"; echo "192.0.2.0/24" > "$CALLS.sets/$SET"
    printf 'FORWARD -i awg0 -j ACCEPT\n' > "$CALLS.fw"
    export STUB_IPSET_RESTORE_FAIL=1
    helper apply
    [ "$status" -ne 0 ] || return 1
    [ "$(fw | head -1)" = "$RULE" ] || { echo "$1: the old set is not enforced: $(fw)"; return 1; }
}
@test "helper: the load fails - the rule goes back on the previous set and the run still fails" {
    each_manage _failed_load_keeps_block
}

_helper_after_off() {
    on_then "$1" || return 1
    cp "$MGMT_DIR/awg/awg-block-ru.sh" "$MGMT_DIR/copy.sh"
    rm -f "$MGMT_DIR/awg/awg-block-ru.sh"
    run --separate-stderr "$MGMT_DIR/copy.sh" update
    [ "$status" -eq 4 ] || { echo "$1: rc $status, want 4"; return 1; }
    [ "$(fw | grep -cF awg_block_ru)" = "0" ] || { echo "$1: a run after off put the rule back"; return 1; }
    [ ! -e "$CALLS.sets/$SET" ] || { echo "$1: a run after off created the set"; return 1; }
}
@test "helper: a run that gets the lock after off (helper removed) changes nothing" {
    each_manage _helper_after_off
}

# ---------- review round 2: early exits keep the block, off without the lock ----------

_no_list_keeps_block() {
    on_then "$1" || return 1
    mkdir -p "$CALLS.sets"; make_list "$CALLS.sets/$SET" 1100
    printf 'FORWARD -i awg0 -j ACCEPT\n' > "$CALLS.fw"
    rm -f "$STUB_WEB"/*
    helper apply
    [ "$status" -ne 0 ] || return 1
    [ "$(fw | head -1)" = "$RULE" ] || { echo "$1: the set in memory is not enforced: $(fw)"; return 1; }
    rm -f "$CALLS.fw"; printf 'FORWARD -i awg0 -j ACCEPT\n' > "$CALLS.fw"
    helper update
    [ "$status" -ne 0 ] || return 1
    [ "$(fw | head -1)" = "$RULE" ] || { echo "$1: update: not enforced: $(fw)"; return 1; }
}
@test "helper: no list on disk and none downloaded - the set in memory keeps the block, the run fails" {
    each_manage _no_list_keeps_block
}

_off_without_lock() {
    manage "$1" block-ru on
    [ "$status" -eq 0 ] || return 1
    export STUB_FLOCK_FAIL=1
    manage "$1" block-ru off
    [ "$status" -ne 0 ] || { echo "$1: off succeeded without the lock"; return 1; }
    [ -e "$MGMT_DIR/awg/awg-block-ru.sh" ] || { echo "$1: files removed without the lock"; return 1; }
    [ -e "$AWG_SYSTEMD_DIR/awg-block-ru.service" ] || { echo "$1: unit removed without the lock"; return 1; }
    # the weekly cron job would restart the disabled unit and bring the block back
    [ ! -e "$AWG_CRON_DIR/awg-block-ru" ] || { echo "$1: cron job left after a failed off"; return 1; }
    [[ "$stderr" == *"block-ru off"* ]] || { echo "$1: no hint to repeat: $stderr"; return 1; }
}
@test "block-ru off cannot take the helper lock: only the cron job goes, the rest stays and it says to repeat" {
    each_manage _off_without_lock
}

# ---------- review round 3 ----------

# A list that passes the shape check but has a network ipset refuses would go
# to the cache and never load after a reboot: it is refused at download.
_strict_list() {
    local bad
    for bad in '300.1.2.0/24' '10.0.0.0/0' '10.0.0.0/33' '1.2.3.256/24'; do
        make_list "$STUB_WEB/ru-aggregated.zone" 1200
        on_then "$1" || return 1
        make_list "$STUB_WEB/ru-aggregated.zone" 1200
        echo "$bad" >> "$STUB_WEB/ru-aggregated.zone"
        rm -f "$STUB_WEB/ru.zone"
        helper apply
        [ "$status" -ne 0 ] || { echo "$1: '$bad' accepted"; return 1; }
        [ ! -e "$MGMT_DIR/awg/block-ru.zone" ] || { echo "$1: '$bad' went to the cache"; return 1; }
    done
}
@test "helper: a list with an octet over 255 or a prefix of 0 or over 32 is refused and not cached" {
    each_manage _strict_list
}

_strict_extra() {
    on_then "$1" || return 1
    printf '203.0.113.0/24\n300.1.1.1\n10.0.0.0/0\n10.1.0.0/33\n' > "$MGMT_DIR/awg/block-ru.extra"
    helper apply
    [ "$status" -eq 0 ] || return 1
    [ "$(set_size $SET)" = "1201" ] || { echo "$1: set $(set_size $SET)"; return 1; }
    local l
    for l in 300.1.1.1 10.0.0.0/0 10.1.0.0/33; do
        [[ "$stderr" == *"$l"* ]] || { echo "$1: '$l' not named"; return 1; }
    done
}
@test "helper: own networks with a bad octet or prefix are skipped and named" {
    each_manage _strict_extra
}

_refetch_after_failed_load() {
    on_then "$1" || return 1
    make_list "$MGMT_DIR/awg/block-ru.zone" 1050
    : > "$CALLS.restore_fail_once"
    : > "$CALLS.curl"
    helper apply
    [ "$status" -eq 0 ] || { echo "$1: $stderr"; return 1; }
    [ -s "$CALLS.curl" ] || { echo "$1: no fresh download after a failed load"; return 1; }
    [ "$(set_size $SET)" = "1200" ] || return 1
    [ "$(fw | head -1)" = "$RULE" ] || return 1
    # the list that loaded replaces the cache ipset refused
    cmp -s "$MGMT_DIR/awg/block-ru.zone" "$STUB_WEB/ru-aggregated.zone" || { echo "$1: the refused cache was kept"; return 1; }
    run bash -c "ls -A '$MGMT_DIR/awg' | grep -E '^\.block-ru\.[A-Za-z0-9]{6}$'"
    [ -z "$output" ] || { echo "$1: temporary file left: $output"; return 1; }
}
@test "helper apply: the cached list does not load - a fresh one is downloaded once and loaded" {
    each_manage _refetch_after_failed_load
}

_on_awg_down_no_list() {
    export STUB_AWG_DOWN=1
    rm -f "$STUB_WEB"/*
    manage "$1" block-ru on
    [ "$status" -ne 0 ] || { echo "$1: on succeeded with no list"; return 1; }
    [ ! -e "$AWG_SYSTEMD_DIR/awg-block-ru.service" ] || { echo "$1: unit left"; return 1; }
    [ ! -e "$CALLS.enabled" ] || return 1
}
@test "block-ru on while awg0 is stopped and no list can be downloaded: refused, nothing left" {
    each_manage _on_awg_down_no_list
}

_update_inactive() {
    manage "$1" block-ru on
    [ "$status" -eq 0 ] || return 1
    rm -f "$CALLS.active"
    : > "$CALLS.curl"
    manage "$1" block-ru update
    [ "$status" -ne 0 ] || return 1
    [ ! -s "$CALLS.curl" ] || { echo "$1: downloaded with the unit inactive"; return 1; }
    [[ "$stderr" == *"systemctl restart awg-block-ru"* ]] || { echo "$1: no way out: $stderr"; return 1; }
}
@test "block-ru update with the unit not running: refused with the way to bring it up" {
    each_manage _update_inactive
}

_update_kept_old() {
    manage "$1" block-ru on
    [ "$status" -eq 0 ] || return 1
    rm -f "$STUB_WEB"/*
    manage "$1" block-ru update --json
    [ "$status" -eq 0 ] || { echo "$1: $stderr"; return 1; }
    [ "$(jq -r '.changed' <<< "$output")" = "false" ] || { echo "$1: '$output'"; return 1; }
    [ "$(jq -r '.in_force' <<< "$output")" = "true" ] || return 1
    [ "$(set_size $SET)" = "1200" ] || return 1
}
@test "block-ru update: nothing downloaded - success with changed false, the previous list in force" {
    command -v jq >/dev/null || skip "jq not available"
    each_manage _update_kept_old
}

_reon_fails_keeps_block() {
    manage "$1" block-ru on
    [ "$status" -eq 0 ] || return 1
    rm -f "$STUB_WEB"/* "$MGMT_DIR/awg/block-ru.zone"
    manage "$1" block-ru on
    [ "$status" -ne 0 ] || { echo "$1: second on succeeded with no list"; return 1; }
    local f
    for f in "$AWG_SYSTEMD_DIR/awg-block-ru.service" "$AWG_CRON_DIR/awg-block-ru" "$MGMT_DIR/awg/awg-block-ru.sh"; do
        [ -e "$f" ] || { echo "$1: $f removed by a failed second on"; return 1; }
    done
    [ -e "$CALLS.enabled" ] || return 1
    [ "$(fw | head -1)" = "$RULE" ] || { echo "$1: the block was lifted: $(fw)"; return 1; }
    [ "$(set_size $SET)" = "1200" ] || return 1
}
@test "block-ru on again on a server where it is on: a failed start keeps the block and the files" {
    each_manage _reon_fails_keeps_block
}

_off_drains_leftover() {
    printf '%s\n%s\n' "$RULE" "$RULE" > "$CALLS.fw"
    mkdir -p "$CALLS.sets"; echo "192.0.2.0/24" > "$CALLS.sets/$SET"
    manage "$1" block-ru off --json
    [ "$status" -eq 0 ] || { echo "$1: $stderr"; return 1; }
    [ "$(fw | grep -cF awg_block_ru)" = "0" ] || { echo "$1: rule left: $(fw)"; return 1; }
    [ ! -e "$CALLS.sets/$SET" ] || return 1
    [ "$(jq -r '.changed' <<< "$output")" = "true" ] || return 1
}
@test "block-ru off with no files but a leftover rule and set: both are removed" {
    command -v jq >/dev/null || skip "jq not available"
    each_manage _off_drains_leftover
}

_apt_retry() {
    mv "$MGMT_DIR/bin/ipset" "$MGMT_DIR/ipset.real"
    export STUB_IPSET_REAL="$MGMT_DIR/ipset.real" STUB_APT_NEEDS_UPDATE=1
    manage "$1" block-ru on
    [ "$status" -eq 0 ] || { echo "$1: $stderr"; return 1; }
    [ "$(awk '{print ($2 == "update") ? "update" : "install"}' "$CALLS.apt" | paste -sd' ' -)" = "install update install" ] \
        || { echo "$1: apt calls: $(cat "$CALLS.apt")"; return 1; }
    [ "$(fw | head -1)" = "$RULE" ] || return 1
}
@test "block-ru on: ipset install fails on stale lists - apt-get update, then the install goes through" {
    each_manage _apt_retry
}

_extra_args() {
    manage "$1" block-ru on off
    [ "$status" -ne 0 ] || return 1
    [ ! -e "$CALLS.enabled" ] || { echo "$1: 'on off' turned it on"; return 1; }
}
@test "block-ru with two arguments: refused, nothing done" {
    each_manage _extra_args
}

@test "the uninstall rule in both installers is the rule manage puts in" {
    local f r
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        r=$(sed -n 's/^    local rule="\(.*\)"$/\1/p' "$BATS_TEST_DIRNAME/../$f")
        [ "$r" = "$RULE" ] || { echo "$f: '$r'"; return 1; }
    done
}

# ---------- review round 5 ----------

# A fresh list that ipset refuses must not overwrite the usable cache: otherwise
# after a reboot the block would not come up and the good list would be lost.
_update_bad_keeps_cache() {
    on_then "$1" || return 1
    make_list "$MGMT_DIR/awg/block-ru.zone" 1100
    helper apply
    [ "$status" -eq 0 ] || { echo "$1: apply: $stderr"; return 1; }
    cp "$MGMT_DIR/awg/block-ru.zone" "$MGMT_DIR/good.zone"
    make_list "$STUB_WEB/ru-aggregated.zone" 1300
    export STUB_IPSET_RESTORE_FAIL=1
    helper update
    [ "$status" -ne 0 ] || { echo "$1: update succeeded with a set that did not load"; return 1; }
    cmp -s "$MGMT_DIR/awg/block-ru.zone" "$MGMT_DIR/good.zone" || { echo "$1: the cache was overwritten by a list ipset refused"; return 1; }
    [ "$(set_size $SET)" = "1100" ] || { echo "$1: set $(set_size $SET)"; return 1; }
    [ "$(fw | head -1)" = "$RULE" ] || { echo "$1: rule: $(fw)"; return 1; }
    run bash -c "ls -A '$MGMT_DIR/awg' | grep -E '^\.block-ru\.[A-Za-z0-9]{6}$'"
    [ -z "$output" ] || { echo "$1: temporary file left: $output"; return 1; }
}
@test "helper update: a fresh list ipset refuses leaves the cache, the set and the rule as they were" {
    each_manage _update_bad_keeps_cache
}

# The list that loaded becomes the cache.
_update_good_saves() {
    on_then "$1" || return 1
    make_list "$MGMT_DIR/awg/block-ru.zone" 1100
    make_list "$STUB_WEB/ru-aggregated.zone" 1300
    helper update
    [ "$status" -eq 0 ] || { echo "$1: $stderr"; return 1; }
    cmp -s "$MGMT_DIR/awg/block-ru.zone" "$STUB_WEB/ru-aggregated.zone" || { echo "$1: the loaded list is not the cache"; return 1; }
    [ "$(set_size $SET)" = "1300" ] || return 1
}
@test "helper update: the fresh list that loaded becomes the cache" {
    each_manage _update_good_saves
}

# With the set still in memory (an awg0 restart) the rule goes up before the
# helper goes to the network.
_apply_rule_before_fetch() {
    on_then "$1" || return 1
    mkdir -p "$CALLS.sets"
    make_list "$CALLS.sets/$SET" 1200
    : > "$CALLS.fw"
    make_list "$STUB_WEB/ru-aggregated.zone" 1250
    export STUB_CURL_SNAP=1
    helper apply
    [ "$status" -eq 0 ] || { echo "$1: $stderr"; return 1; }
    [ -e "$CALLS.fw_at_curl" ] || { echo "$1: no download"; return 1; }
    [ "$(head -1 "$CALLS.fw_at_curl")" = "$RULE" ] || { echo "$1: no rule while downloading: $(cat "$CALLS.fw_at_curl")"; return 1; }
    [ "$(set_size $SET)" = "1250" ] || return 1
}
@test "helper apply: the set is in memory - the rule is up before the download" {
    each_manage _apply_rule_before_fetch
}

# An empty set in memory gets no rule before the list loads.
_apply_empty_no_early_rule() {
    on_then "$1" || return 1
    : > "$CALLS.fw"
    make_list "$STUB_WEB/ru-aggregated.zone" 1250
    export STUB_CURL_SNAP=1
    helper apply
    [ "$status" -eq 0 ] || { echo "$1: $stderr"; return 1; }
    [ -e "$CALLS.fw_at_curl" ] || { echo "$1: no download"; return 1; }
    [ ! -s "$CALLS.fw_at_curl" ] || { echo "$1: rule before the set loaded: $(cat "$CALLS.fw_at_curl")"; return 1; }
    [ "$(fw | head -1)" = "$RULE" ] || return 1
}
@test "helper apply: no set in memory - no rule until the list loads" {
    each_manage _apply_empty_no_early_rule
}
