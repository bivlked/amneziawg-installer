#!/usr/bin/env bats
# Tests for v5.14.3 cleanup_system fix (Issue #84).
#
# Bug background: on clean Ubuntu 26.04 server installed via subiquity
# (VirtualBox VM, no cloud-init network management), cleanup_system used
# `apt-get autoremove` after `apt-get purge cloud-init`. Autoremove cascaded
# and removed netplan-generator as a transitive cloud-init dep; after reboot
# systemd-networkd started with empty config and DHCP failed - server lost IP.
#
# Fix (Option B from handoff):
#   1. apt-mark hold on critical network stack packages before any purge
#   2. apt-get autoremove call dropped from cleanup_system
#   3. Default route snapshot pre/post + recovery attempt + die on failure
#
# Reporter: @jay0x in issue #84 (21 may 2026).
#
# Do not run this file as root: the Issue #409 tests take cleanup_system up to
# its rm of /etc/cloud. A guard function catches that rm, but a guard can only
# catch the spellings it knows, and without root a miss cannot delete anything.

load test_helper

# Required for `run !` and `run -N` flags (negation/specific exit code).
bats_require_minimum_version 1.5.0

# Build a sandbox PATH with mocks for every external command cleanup_system
# touches: dpkg-query, apt-get, apt-mark, ip, systemctl, netplan, sleep.
# Each mock writes its argv line to a single trace file we then grep on.
setup() {
    TEST_DIR=$(mktemp -d)
    TRACE="$TEST_DIR/trace"
    : > "$TRACE"
    BIN="$TEST_DIR/bin"
    mkdir -p "$BIN"
    export TRACE BIN
    # Defaults that individual tests override before calling cleanup_system.
    export MOCK_PRE_ROUTE="default via 10.0.0.1 dev eth0"
    export MOCK_POST_ROUTE="default via 10.0.0.1 dev eth0"
    export MOCK_RECOVERY_ROUTE="default via 10.0.0.1 dev eth0"
    export MOCK_LASTDITCH_ROUTE=""
    export MOCK_LASTDITCH_ROUTE_AFTER_DHCLIENT=""
    export MOCK_CLOUD_INIT_INSTALLED=1
    export MOCK_NETPLAN_HAS_MARKERS=0
    export MOCK_PREEXISTING_HOLDS=""
    export MOCK_NETPLAN_GENERATOR_AVAILABLE=1

    # Per-command shims kept small and single-purpose; using `local` outside a
    # function (heredoc top-level) is a bash error, so each shim uses plain
    # variables only.

    # dpkg-query: pretend net stack pkgs and cloud-init are installed;
    # everything else (purge list, cleanup_list) is not - keeps tests focused.
    cat > "$BIN/dpkg-query" <<'SHIM'
#!/bin/bash
echo "dpkg-query $*" >> "$TRACE"
pkg="${@: -1}"
case "$pkg" in
    cloud-init)
        # after a purge that really removed it (see the apt-get shim below)
        [[ -e "$TRACE.ci_gone" ]] && { echo "unknown ok not-installed"; exit 0; }
        [[ "${MOCK_CLOUD_INIT_INSTALLED:-1}" -eq 1 ]] && { echo "install ok installed"; exit 0; }
        exit 1
        ;;
    netplan.io|netplan-generator|systemd-networkd|systemd-resolved)
        # MOCK_DPKG_HELD: packages whose dpkg selection is hold
        if [[ " ${MOCK_DPKG_HELD:-} " == *" $pkg "* ]]; then echo "hold ok installed"; else echo "install ok installed"; fi
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
SHIM
    chmod +x "$BIN/dpkg-query"

    # ip: counts route-show invocations.
    #   1   : pre-route snapshot (MOCK_PRE_ROUTE)
    #   2   : initial post-cleanup check (MOCK_POST_ROUTE)
    #   3-9 : route-wait loop iterations (MOCK_RECOVERY_ROUTE)
    #   10  : after networkctl renew (MOCK_LASTDITCH_ROUTE)
    #   11  : after dhclient (MOCK_LASTDITCH_ROUTE_AFTER_DHCLIENT)
    # Non-route invocations (like `ip link set ... up`) trace and exit 0.
    cat > "$BIN/ip" <<'SHIM'
#!/bin/bash
echo "ip $*" >> "$TRACE"
# Only route queries advance the counter.
if [[ "$*" =~ route\ show\ default ]]; then
    COUNT_FILE="$TRACE.ipcount"
    n=0
    [[ -f "$COUNT_FILE" ]] && n=$(cat "$COUNT_FILE")
    n=$((n + 1))
    echo "$n" > "$COUNT_FILE"
    case "$n" in
        1)     echo "$MOCK_PRE_ROUTE" ;;
        2)     echo "$MOCK_POST_ROUTE" ;;
        10)    echo "$MOCK_LASTDITCH_ROUTE" ;;
        11)    echo "$MOCK_LASTDITCH_ROUTE_AFTER_DHCLIENT" ;;
        *)     echo "$MOCK_RECOVERY_ROUTE" ;;
    esac
fi
exit 0
SHIM
    chmod +x "$BIN/ip"

    # apt-mark: traces all calls. `apt-mark showhold` returns user-held pkg list.
    cat > "$BIN/apt-mark" <<'SHIM'
#!/bin/bash
echo "apt-mark $*" >> "$TRACE"
case "$1" in
    showhold) printf '%s\n' "${MOCK_PREEXISTING_HOLDS:-}"; exit "${MOCK_SHOWHOLD_RC:-0}" ;;
esac
exit 0
SHIM
    chmod +x "$BIN/apt-mark"

    # apt-cache: only `show netplan-generator` is gated; everything else is OK.
    cat > "$BIN/apt-cache" <<'SHIM'
#!/bin/bash
echo "apt-cache $*" >> "$TRACE"
if [[ "$1 $2" == "show netplan-generator" ]]; then
    [[ "${MOCK_NETPLAN_GENERATOR_AVAILABLE:-1}" -eq 1 ]] && exit 0 || exit 100
fi
exit 0
SHIM
    chmod +x "$BIN/apt-cache"

    # networkctl + dhclient: trace-only, always succeed (the route mock
    # decides whether recovery actually worked).
    for cmd in networkctl dhclient; do
        cat > "$BIN/$cmd" <<SHIM
#!/bin/bash
echo "$cmd \$*" >> "\$TRACE"
exit 0
SHIM
        chmod +x "$BIN/$cmd"
    done

    # apt-get, systemctl, netplan, sleep: trace-only, always succeed.
    for cmd in apt-get systemctl netplan sleep; do
        cat > "$BIN/$cmd" <<SHIM
#!/bin/bash
echo "$cmd \$*" >> "\$TRACE"
exit 0
SHIM
        chmod +x "$BIN/$cmd"
    done

    # apt-get again, now with a purge of cloud-init for the Issue #409 order
    # below: MOCK_CLOUD_PURGE_RC is its exit code, and a successful purge
    # removes the package unless MOCK_CLOUD_PURGE_KEEPS=1 (apt says 0, dpkg
    # still has it, as with APT::Get::Simulate).
    cat > "$BIN/apt-get" <<'SHIM'
#!/bin/bash
echo "${DEBIAN_FRONTEND:-UNSET} apt-get $*" | sed 's/^noninteractive //' >> "$TRACE"
if [[ "$*" == *"purge -y cloud-init" ]]; then
    rc="${MOCK_CLOUD_PURGE_RC:-0}"
    [[ "$rc" -eq 0 && "${MOCK_CLOUD_PURGE_KEEPS:-0}" -ne 1 ]] && : > "$TRACE.ci_gone"
    [[ "$rc" -ne 0 ]] && echo "E: Sub-process /usr/bin/dpkg returned an error code (1)"
    exit "$rc"
fi
exit 0
SHIM
    chmod +x "$BIN/apt-get"

    # ls: used by cleanup_system inside cloud-init guard for /etc/netplan/*cloud-init*.
    # Forward everything else to the real ls.
    cat > "$BIN/ls" <<'SHIM'
#!/bin/bash
echo "ls $*" >> "$TRACE"
case "$*" in
    *cloud-init*)
        [[ "${MOCK_NETPLAN_HAS_MARKERS:-0}" -eq 1 ]] && exit 0 || exit 1
        ;;
esac
/usr/bin/ls "$@"
SHIM
    chmod +x "$BIN/ls"

    export PATH="$BIN:$PATH"

    # Extract cleanup_system from install_amneziawg.sh into a sourceable file.
    awk '/^cleanup_system\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh" \
        > "$TEST_DIR/cleanup_system.bash"
    # the hold helper cleanup_system asks about a user's own holds
    awk '/^_awg_pkg_held\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh" \
        >> "$TEST_DIR/cleanup_system.bash"
    # Stub the logger and die so the function does not need awg_common.sh.
    cat > "$TEST_DIR/loader.bash" <<'LOADER'
log()       { echo "LOG: $*" >> "$TRACE"; }
log_debug() { echo "DEBUG: $*" >> "$TRACE"; }
log_warn()  { echo "WARN: $*" >> "$TRACE"; }
log_error() { echo "ERROR: $*" >> "$TRACE"; }
die()       { echo "DIE: $*" >> "$TRACE"; exit 1; }
# Never let cleanup_system remove real system directories of the machine
# running the suite: system paths are traced and not removed, temp paths are
# passed on, anything else is refused loudly. A function, not a PATH shim, so
# it lives only inside call_cleanup.
rm() {
    local a
    for a in "$@"; do
        case "$a" in
            /etc/cloud*|/var/lib/cloud*|/snap*|/var/snap*|/var/lib/snapd*) echo "rm $*" >> "$TRACE"; return 0 ;;
        esac
    done
    for a in "$@"; do
        case "$a" in
            -*|/tmp/*|"${TRACE%/*}"/*) ;;
            *) echo "UNEXPECTED rm $*" >> "$TRACE"; return 1 ;;
        esac
    done
    command rm "$@"
}
OS_ID="ubuntu"
LOADER
}

teardown() {
    rm -rf "$TEST_DIR"
}

call_cleanup() {
    # shellcheck source=/dev/null
    bash -c "source '$TEST_DIR/loader.bash'; source '$TEST_DIR/cleanup_system.bash'; cleanup_system"
}

# --- Core regression tests ---

@test "v5.14.3: cleanup_system NEVER calls apt-get autoremove" {
    call_cleanup
    run ! grep -qE '^apt-get autoremove' "$TRACE"
}

@test "v5.14.3: apt-mark hold called for netplan.io BEFORE any purge" {
    call_cleanup
    # First apt-mark hold line for netplan.io must precede first apt-get purge.
    local hold_line purge_line
    hold_line=$(grep -nE '^apt-mark hold netplan\.io$' "$TRACE" | head -1 | cut -d: -f1)
    purge_line=$(grep -nE '^apt-get purge' "$TRACE" | head -1 | cut -d: -f1)
    [ -n "$hold_line" ]
    # Purge line may be absent if no packages matched - that is also OK.
    if [ -n "$purge_line" ]; then
        [ "$hold_line" -lt "$purge_line" ]
    fi
}

@test "v5.14.3: apt-mark hold covers netplan + resolved (NOT systemd-networkd, which is not a standalone pkg)" {
    call_cleanup
    grep -qE '^apt-mark hold netplan\.io$'         "$TRACE"
    grep -qE '^apt-mark hold netplan-generator$'   "$TRACE"
    grep -qE '^apt-mark hold systemd-resolved$'    "$TRACE"
    # systemd-networkd is part of the systemd package, NOT a standalone pkg.
    # External review v5.14.3 pass 1 flagged this - hold would be a no-op anyway,
    # and the recovery `apt install systemd-networkd` would fail. We keep it
    # out entirely.
    run ! grep -qE '^apt-mark hold systemd-networkd$' "$TRACE"
}

@test "v5.14.3: apt-mark unhold called after cleanup for each held package" {
    call_cleanup
    grep -qE '^apt-mark unhold netplan\.io$'       "$TRACE"
    grep -qE '^apt-mark unhold netplan-generator$' "$TRACE"
    grep -qE '^apt-mark unhold systemd-resolved$'  "$TRACE"
}

@test "v5.14.3: default route preserved ->no recovery, no DIE" {
    export MOCK_PRE_ROUTE="default via 10.0.0.1 dev eth0"
    export MOCK_POST_ROUTE="default via 10.0.0.1 dev eth0"
    call_cleanup
    run ! grep -qE '^DIE:'                                                  "$TRACE"
    run ! grep -qE 'Default route потерян|Default route lost'               "$TRACE"
    run ! grep -qE '^apt-get .*install .*--no-install-recommends netplan\.io' "$TRACE"
}

@test "v5.14.3: default route lost ->recovery attempt (apt install + netplan apply)" {
    export MOCK_PRE_ROUTE="default via 10.0.0.1 dev eth0"
    export MOCK_POST_ROUTE=""
    export MOCK_RECOVERY_ROUTE="default via 10.0.0.1 dev eth0"
    call_cleanup
    grep -qE 'Маршрут по умолчанию|Default route'                            "$TRACE"
    # Recovery installs netplan.io unconditionally, then gates netplan-generator
    # behind apt-cache show (so Debian 12 with no netplan-generator does not
    # abort the apt transaction).
    grep -qxF -- 'apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y --no-install-recommends netplan.io' "$TRACE"
    grep -qE '^apt-cache show netplan-generator'                            "$TRACE"
    grep -qxF -- 'apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y --no-install-recommends netplan-generator' "$TRACE"
    grep -qE '^systemctl restart systemd-networkd'                          "$TRACE"
    grep -qE '^netplan apply'                                               "$TRACE"
}

@test "v5.14.3: last-ditch attempts networkctl renew + ip link up when route still missing" {
    export MOCK_PRE_ROUTE="default via 10.0.0.1 dev enp0s3"
    export MOCK_POST_ROUTE=""
    export MOCK_RECOVERY_ROUTE=""
    export MOCK_LASTDITCH_ROUTE="default via 10.0.0.1 dev enp0s3"
    call_cleanup
    grep -qE '^ip link set enp0s3 up'   "$TRACE"
    grep -qE '^networkctl renew enp0s3' "$TRACE"
    # Successful last-ditch recovery should NOT call die.
    run ! grep -qE '^DIE:' "$TRACE"
}

@test "v5.14.3: last-ditch falls through to dhclient when networkctl did not restore route" {
    export MOCK_PRE_ROUTE="default via 10.0.0.1 dev eth0"
    export MOCK_POST_ROUTE=""
    export MOCK_RECOVERY_ROUTE=""
    # First last-ditch ip-route check (after networkctl) returns empty; second
    # check (after dhclient) returns a real route. The ip-mock counter handles this.
    export MOCK_LASTDITCH_ROUTE=""
    export MOCK_LASTDITCH_ROUTE_AFTER_DHCLIENT="default via 10.0.0.1 dev eth0"
    call_cleanup
    grep -qE '^networkctl renew eth0' "$TRACE"
    grep -qE '^dhclient -4 eth0'      "$TRACE"
}

@test "v5.14.3: pre-existing apt-mark hold preserved - we skip holding pkgs user already locked" {
    # Simulate user previously held netplan.io and systemd-resolved.
    export MOCK_PREEXISTING_HOLDS=$'netplan.io\nsystemd-resolved'
    call_cleanup
    # We must NOT add our own hold for these (the user owns the lock now).
    run ! grep -qE '^apt-mark hold netplan\.io$'      "$TRACE"
    run ! grep -qE '^apt-mark hold systemd-resolved$' "$TRACE"
    # We also must NOT release the user's hold at the end.
    run ! grep -qE '^apt-mark unhold netplan\.io$'      "$TRACE"
    run ! grep -qE '^apt-mark unhold systemd-resolved$' "$TRACE"
    # netplan-generator was NOT in user's holds - we still hold/unhold it.
    grep -qE '^apt-mark hold netplan-generator$'   "$TRACE"
    grep -qE '^apt-mark unhold netplan-generator$' "$TRACE"
}

@test "a user hold stays when showhold fails: dpkg selection is asked first" {
    # A failing showhold used to leave the snapshot of the user's holds empty,
    # so cleanup took the user's hold for its own and released it at the end.
    export MOCK_SHOWHOLD_RC=1
    export MOCK_DPKG_HELD="netplan.io"
    call_cleanup
    run ! grep -qE '^apt-mark hold netplan\.io$'   "$TRACE"
    run ! grep -qE '^apt-mark unhold netplan\.io$' "$TRACE"
    grep -qE '^apt-mark hold netplan-generator$'   "$TRACE"
    grep -qE '^apt-mark unhold netplan-generator$' "$TRACE"
}

@test "v5.14.3: recovery FAILS to restore route ->die() called with --no-tweaks advice" {
    export MOCK_PRE_ROUTE="default via 10.0.0.1 dev eth0"
    export MOCK_POST_ROUTE=""
    export MOCK_RECOVERY_ROUTE=""
    run call_cleanup
    [ "$status" -ne 0 ]
    grep -qE '^DIE:.*--no-tweaks' "$TRACE"
}

@test "v5.14.3: cloud-init absent ->no purge, no hold spam (existing guard preserved)" {
    export MOCK_CLOUD_INIT_INSTALLED=0
    call_cleanup
    # No cloud-init purge.
    run ! grep -qE '^apt-get .*purge -y cloud-init' "$TRACE"
    # apt-mark hold still runs (defensive on critical pkgs regardless of cloud-init state).
    grep -qE '^apt-mark hold netplan\.io$' "$TRACE"
}

# --- Structural / RU+EN parity ---

@test "structural: both cleanup_system twins ask _awg_pkg_held and keep no showhold snapshot" {
    local f body
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        body=$(awk '/^cleanup_system\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../$f")
        grep -qxF '            if _awg_pkg_held "$_hpkg"; then' <<< "$body" || { echo "$f: no _awg_pkg_held"; return 1; }
        run grep -c '_preexisting_holds' <<< "$body"
        [ "$output" = "0" ] || { echo "$f: snapshot still there"; return 1; }
    done
}

# The cloud-init branch needs its two helpers; the rest of the harness runs
# without them, so they are added only for the Issue #409 tests.
reach_cloud_init() {
    echo '_cloud_init_removable() { return 0; }; _cleanup_package_list() { :; }' >> "$TEST_DIR/loader.bash"
}

# After the cloud-init block the cleanup must go on: exit 0, no die, the
# default route checked again after the cleanup (second ip route query), and
# no rm outside the guard's known paths.
cleanup_went_on() {
    [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
    run grep -c '^DIE:' "$TRACE"
    [ "$output" = "0" ] || { echo "died: $(grep '^DIE:' "$TRACE")"; return 1; }
    [ "$(cat "$TRACE.ipcount" 2>/dev/null || echo 0)" -ge 2 ] || { echo "the cleanup stopped before the route check"; return 1; }
    run grep -c '^UNEXPECTED rm' "$TRACE"
    [ "$output" = "0" ] || { echo "$(grep '^UNEXPECTED rm' "$TRACE")"; return 1; }
}

@test "Issue #409: /etc/cloud and /var/lib/cloud go only after cloud-init is purged" {
    reach_cloud_init
    MOCK_CLOUD_PURGE_RC=0 run call_cleanup
    cleanup_went_on
    grep -qxF "apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold purge -y cloud-init" "$TRACE"
    grep -qx "rm -rf /etc/cloud /var/lib/cloud" "$TRACE"
}

@test "Issue #409: a failed cloud-init purge keeps /etc/cloud, says why, and the cleanup goes on" {
    reach_cloud_init
    MOCK_CLOUD_PURGE_RC=100 run call_cleanup
    cleanup_went_on
    grep -qxF "apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold purge -y cloud-init" "$TRACE"
    run grep -c "^rm .*/etc/cloud" "$TRACE"
    [ "$output" = "0" ]
    # the warning names the apt code and carries apt's own words
    grep -q "^WARN: .*100.*/etc/cloud.*returned an error code" "$TRACE"
}

@test "Issue #409: a purge that reports success while dpkg still has cloud-init keeps /etc/cloud" {
    reach_cloud_init
    MOCK_CLOUD_PURGE_RC=0 MOCK_CLOUD_PURGE_KEEPS=1 run call_cleanup
    cleanup_went_on
    grep -qxF "apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold purge -y cloud-init" "$TRACE"
    run grep -c "^rm .*/etc/cloud" "$TRACE"
    [ "$output" = "0" ]
    grep -q "^WARN: .*ok installed.*/etc/cloud" "$TRACE"
}

@test "Issue #409: the purge guard behaves the same in the EN installer" {
    reach_cloud_init
    awk '/^cleanup_system\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh" > "$TEST_DIR/cleanup_system.bash"
    awk '/^_awg_pkg_held\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh" >> "$TEST_DIR/cleanup_system.bash"
    MOCK_CLOUD_PURGE_RC=100 run call_cleanup
    cleanup_went_on
    run grep -c "^rm .*/etc/cloud" "$TRACE"
    [ "$output" = "0" ]
    grep -q "^WARN: .*100.*/etc/cloud.*returned an error code" "$TRACE"
    : > "$TRACE"; rm -f "$TRACE.ipcount" "$TRACE.ci_gone"
    MOCK_CLOUD_PURGE_RC=0 MOCK_CLOUD_PURGE_KEEPS=1 run call_cleanup
    cleanup_went_on
    run grep -c "^rm .*/etc/cloud" "$TRACE"
    [ "$output" = "0" ]
    : > "$TRACE"; rm -f "$TRACE.ipcount" "$TRACE.ci_gone"
    MOCK_CLOUD_PURGE_RC=0 run call_cleanup
    cleanup_went_on
    grep -qx "rm -rf /etc/cloud /var/lib/cloud" "$TRACE"
}

@test "structural: install_amneziawg.sh + _en.sh cleanup_system functions are line-equal" {
    local RU EN
    RU=$(awk '/^cleanup_system\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh" | wc -l)
    EN=$(awk '/^cleanup_system\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh" | wc -l)
    [ "$RU" = "$EN" ]
}

@test "structural: RU and EN cleanup_system both contain apt-mark hold + unhold + DIE" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        local block
        block=$(awk '/^cleanup_system\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../$f")
        grep -q 'apt-mark hold'   <<<"$block"
        grep -q 'apt-mark unhold' <<<"$block"
        grep -q 'die '            <<<"$block"
    done
}

@test "structural: apt-get autoremove is GONE from both install scripts" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        local block
        # Strip comment lines so a # `apt-get autoremove dropped...` rationale
        # comment does not register as a real invocation.
        block=$(awk '/^cleanup_system\(\) \{/,/^}$/' "$BATS_TEST_DIRNAME/../$f" \
            | grep -vE '^[[:space:]]*#')
        run ! grep -qE 'apt-get autoremove' <<<"$block"
    done
}
