#!/usr/bin/env bats
# Step 2 failures must leave their cause in the log and on screen:
#   - a failed apt install copies the tail of apt's output into the install
#     log (I#368: the log held only "package installation error");
#   - before blaming a Launchpad outage, step 2 checks whether the server
#     resolves names at all (I#299: DNS was down for every source);
#   - cloning the pinned module source keeps git's own error text and never
#     waits for a login prompt (D#255).
# Every case runs on both installers.

load test_helper

INSTALLERS=(install_amneziawg.sh install_amneziawg_en.sh)

_fn() { sed -n "/^$2() {\$/,/^}\$/p" "$BATS_TEST_DIRNAME/../$1"; }
_stub() { printf '#!/bin/bash\n%s\n' "$2" > "$T/bin/$1"; chmod +x "$T/bin/$1"; }

setup() {
    T=$(mktemp -d); export T
    mkdir -p "$T/bin"
    # dpkg-query: nothing installed, so every requested package goes to apt.
    _stub dpkg-query 'echo "dpkg-query: no packages found matching ${*: -1}" >&2; exit 1'
    export PATH="$T/bin:$PATH"
}

teardown() { rm -rf "$T"; }

# ---------- apt install output in the log ----------

# A driver that runs install_packages from installer $1 outside the PPA/DKMS
# fallback (_AWG_KMOD_T1=0), so a failed apt goes straight to die.
_pkg_driver() {
    {
        echo 'log() { echo "LOG: $*"; }; log_warn() { echo "WARN: $*"; }; die() { echo "DIE: $*"; exit 1; }'
        echo 'apt_update_tolerant() { :; }; _install_temp_files=(); _APT_UPDATED=1'
        echo "_AWG_KMOD_T1=0; LOG_FILE=$T/log"
        _fn "$1" install_packages
        echo 'install_packages "$@"'
    } > "$T/drv.sh"
}

@test "apt install failure: the tail of apt output lands in the install log" {
    local f
    for f in "${INSTALLERS[@]}"; do
        rm -f "$T/log"
        _stub apt 'echo "Reading package lists..."; echo "E: Failed to fetch http://ppa.example/pool/x.deb  Connection timed out" >&2; exit 100'
        _pkg_driver "$f"
        run bash "$T/drv.sh" amneziawg-dkms qrencode
        [ "$status" -eq 1 ] || { echo "$f: $output"; return 1; }
        [[ "$output" == *DIE:* ]] || { echo "$f: $output"; return 1; }
        # Still on screen as before.
        [[ "$output" == *"E: Failed to fetch http://ppa.example/pool/x.deb  Connection timed out"* ]] || { echo "$f: not on screen: $output"; return 1; }
        # And now in the log, stdout and stderr both, under a header with the exit code.
        grep -qF 'E: Failed to fetch http://ppa.example/pool/x.deb  Connection timed out' "$T/log" || { echo "$f: apt error not in the log"; cat "$T/log"; return 1; }
        grep -qF 'Reading package lists...' "$T/log" || { echo "$f: apt stdout not in the log"; return 1; }
        grep -qE '^--- apt install \((код|exit) 100\)' "$T/log" || { echo "$f: no header with the exit code"; cat "$T/log"; return 1; }
    done
}

@test "apt install failure: only the last 40 lines go to the log" {
    local f
    for f in "${INSTALLERS[@]}"; do
        rm -f "$T/log"
        _stub apt 'for i in $(seq 1 100); do echo "apt line $i"; done; exit 100'
        _pkg_driver "$f"
        run bash "$T/drv.sh" qrencode
        [ "$status" -eq 1 ]
        grep -qx 'apt line 100' "$T/log" || { echo "$f: last line missing"; return 1; }
        grep -qx 'apt line 61' "$T/log" || { echo "$f: line 61 missing"; return 1; }
        ! grep -qx 'apt line 60' "$T/log" || { echo "$f: more than 40 lines"; return 1; }
    done
}

@test "apt install success: nothing from apt is copied to the log" {
    local f
    for f in "${INSTALLERS[@]}"; do
        rm -f "$T/log"
        _stub apt 'echo "Setting up qrencode ..."; exit 0'
        _pkg_driver "$f"
        run bash "$T/drv.sh" qrencode
        [ "$status" -eq 0 ] || { echo "$f: $output"; return 1; }
        [[ "$output" == *"Setting up qrencode ..."* ]]
        ! grep -q 'apt install' "$T/log" 2>/dev/null || { echo "$f: apt output copied on success"; return 1; }
    done
}

# ---------- DNS check before the Launchpad outage message ----------

# getent stub: a name listed in $T/resolves resolves, anything else fails.
_getent_stub() { _stub getent '[[ "$1" == hosts ]] || exit 2
grep -qx "$2" "$T/resolves" 2>/dev/null && { echo "192.0.2.1 $2"; exit 0; }
exit 2'; }

_verdict() {
    local f=$1 os=$2
    bash -c "OS_ID=$os; $(_fn "$f" _ppa_dns_verdict); _ppa_dns_verdict"
}

@test "_ppa_dns_verdict: names resolve -> nothing printed (outage remains the guess)" {
    local f
    _getent_stub
    printf '%s\n' ppa.launchpadcontent.net archive.ubuntu.com > "$T/resolves"
    for f in "${INSTALLERS[@]}"; do
        run _verdict "$f" ubuntu
        [ "$status" -eq 0 ]; [ -z "$output" ] || { echo "$f: '$output'"; return 1; }
    done
}

@test "_ppa_dns_verdict: nothing resolves -> dns-all with the distro mirror" {
    local f
    _getent_stub
    : > "$T/resolves"
    for f in "${INSTALLERS[@]}"; do
        run _verdict "$f" ubuntu
        [ "$output" = "dns-all archive.ubuntu.com" ] || { echo "$f: '$output'"; return 1; }
        run _verdict "$f" debian
        [ "$output" = "dns-all deb.debian.org" ] || { echo "$f: '$output'"; return 1; }
    done
}

@test "_ppa_dns_verdict: only the PPA name fails -> dns-ppa" {
    local f
    _getent_stub
    printf '%s\n' archive.ubuntu.com deb.debian.org > "$T/resolves"
    for f in "${INSTALLERS[@]}"; do
        run _verdict "$f" ubuntu
        [ "$output" = "dns-ppa archive.ubuntu.com" ] || { echo "$f: '$output'"; return 1; }
    done
}

@test "step 2: the DNS verdict is checked after the PPA wait and before the outage text, each branch dies" {
    local f s w v o
    for f in "${INSTALLERS[@]}"; do
        s=$(cat "$BATS_TEST_DIRNAME/../$f")
        w=$(grep -n -m1 -F 'if ! apt_wait_for_ppa_package amneziawg-dkms 3 30; then' <<<"$s" | cut -d: -f1)
        v=$(grep -n -m1 -F 'read -r _dns_v _dns_m <<<"$(_ppa_dns_verdict)"' <<<"$s" | cut -d: -f1)
        o=$(grep -n -m1 -E 'log_error "(Похоже, ppa\.launchpadcontent\.net|ppa\.launchpadcontent\.net appears)' <<<"$s" | cut -d: -f1)
        [ -n "$w" ] && [ -n "$v" ] && [ -n "$o" ] || { echo "$f: w=$w v=$v o=$o"; return 1; }
        [ "$w" -lt "$v" ] && [ "$v" -lt "$o" ] || { echo "$f: order w=$w v=$v o=$o"; return 1; }
        # Both verdict branches end in die before the outage text.
        [ "$(sed -n "${v},${o}p" <<<"$s" | grep -c '^ *die "')" -eq 2 ] || { echo "$f: expected two die between verdict and outage text"; return 1; }
    done
}

# ---------- git clone of the pinned module source ----------

_clone_driver() {
    {
        echo 'log() { echo "LOG: $*"; }; log_warn() { echo "WARN: $*"; }; log_error() { echo "ERR: $*"; }'
        echo 'AWG2_PIN_TAG=v1.0.test; AWG2_PIN_COMMIT=0000000000000000000000000000000000000000'
        _fn "$1" _install_pinned_awg2_module
        echo '_install_pinned_awg2_module'
    } > "$T/drv.sh"
}

@test "pinned module clone: git error text is shown and no login prompt is allowed" {
    local f
    _stub uname 'echo 6.1.0-test'
    _stub git 'echo "GIT_TERMINAL_PROMPT=${GIT_TERMINAL_PROMPT:-unset}" >> "$T/git.env"
if read -r -t 1 _x; then echo "stdin had data" >> "$T/git.env"; fi
echo "Cloning into ..." >&2
echo "fatal: unable to access '"'"'https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git/'"'"': Could not resolve host: github.com" >&2
exit 128'
    for f in "${INSTALLERS[@]}"; do
        rm -f "$T/git.env"
        _clone_driver "$f"
        run bash "$T/drv.sh" <<<"typed-password"
        [ "$status" -eq 1 ] || { echo "$f: $output"; return 1; }
        [[ "$output" == *"ERR:   git: fatal: unable to access"*"Could not resolve host: github.com"* ]] || { echo "$f: git error not shown: $output"; return 1; }
        [[ "$output" == *"ERR: "*"github.com"* ]]
        grep -qx 'GIT_TERMINAL_PROMPT=0' "$T/git.env" || { echo "$f: $(cat "$T/git.env")"; return 1; }
        ! grep -q 'stdin had data' "$T/git.env" || { echo "$f: git inherited stdin"; return 1; }
    done
}
