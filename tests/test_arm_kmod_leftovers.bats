#!/usr/bin/env bats
# The ARM prebuilt module package (amneziawg-kmod-<target>) around the edges of an
# install: --uninstall must remove it (it carries the module file), and a stop in
# step 2 while it is installed must leave amneziawg-dkms held, as the prebuilt path
# does on success. Both found on the ARM stand on 6 oct 2026. "Could not ask dpkg"
# must never read as "no such package".

setup() {
    ROOT="${BATS_TEST_DIRNAME}/.."
}

_fn() { # installer function-name -> the function's source
    awk -v n="$2" '$0 == n "() {" {on=1} on {print} on && /^}$/ {exit}' "$1"
}

# dpkg-query stub: answers only the exact query the installer must make, from $PKGS
# ("name|status" per line). Empty $PKGS -> dpkg's own "no packages found" (rc 1);
# DPKG_FAIL=1 -> a real failure (rc 2).
STUB_DPKG_QUERY='
dpkg-query() {
    if [ "$#" -ne 3 ] || [ "$1" != -W ] || [ "$2" != '"'"'-f=${Package} ${Status}\n'"'"' ] || [ "$3" != "amneziawg-kmod-*" ]; then
        echo "dpkg-query: unexpected arguments: $*" >&2; return 2
    fi
    if [ "${DPKG_FAIL:-0}" = 1 ]; then echo "dpkg-query: error: parsing file /var/lib/dpkg/status" >&2; return 2; fi
    if [ -z "$PKGS" ]; then echo "dpkg-query: no packages found matching amneziawg-kmod-*" >&2; return 1; fi
    local n s
    while IFS="|" read -r n s; do [ -n "$n" ] && printf "%s %s\n" "$n" "$s"; done <<<"$PKGS"
}'

_run_kmod_list() { # installer
    local body
    body=$(_fn "$1" _awg_installed_kmod_pkgs)
    [ -n "$body" ] || return 99
    bash -c "$STUB_DPKG_QUERY"'
        eval "$1"
        out=$(_awg_installed_kmod_pkgs); rc=$?
        printf "rc=%s out=[%s]\n" "$rc" "$out"
    ' _ "$body"
}

@test "kmod list: every installed prebuilt package, whatever the kernel (RU + EN)" {
    local f
    export PKGS="amneziawg-kmod-ubuntu-2404-arm64|install ok installed
amneziawg-kmod-old|install ok half-configured
amneziawg-kmod-held|hold ok installed
amneziawg-kmod-gone|deinstall ok config-files
amneziawg-kmod-purged|unknown ok not-installed
amneziawg-kmod-debian-trixie-arm64|install ok unpacked"
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run _run_kmod_list "$ROOT/$f"
        [ "$output" = "rc=0 out=[amneziawg-kmod-ubuntu-2404-arm64 amneziawg-kmod-old amneziawg-kmod-held amneziawg-kmod-debian-trixie-arm64]" ] \
            || { echo "$f: got '$output'"; false; }
    done
}

@test "kmod list: nothing installed -> empty answer, rc 0 (RU + EN)" {
    local f
    export PKGS=""
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run _run_kmod_list "$ROOT/$f"
        [ "$output" = "rc=0 out=[]" ] || { echo "$f: got '$output'"; false; }
    done
}

@test "kmod list: dpkg could not be asked -> rc 2, not an empty answer (RU + EN)" {
    local f
    export PKGS="amneziawg-kmod-ubuntu-2404-arm64|install ok installed" DPKG_FAIL=1
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run _run_kmod_list "$ROOT/$f"
        [ "$output" = "rc=2 out=[]" ] || { echo "$f: got '$output'"; false; }
    done
}

@test "prebuilt for the running kernel: dpkg could not be asked -> rc 2 (RU + EN)" {
    local f a b
    export PKGS="amneziawg-kmod-ubuntu-2404-arm64|install ok installed" DPKG_FAIL=1
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        a=$(_fn "$ROOT/$f" _awg_installed_kmod_pkgs); b=$(_fn "$ROOT/$f" _awg_prebuilt_for_running_kernel)
        [ -n "$a" ] && [ -n "$b" ]
        run bash -c "$STUB_DPKG_QUERY"'
            uname() { echo 6.8.0-146-generic; }
            dpkg() { echo /lib/modules/6.8.0-146-generic/extra/amneziawg.ko.xz; }
            eval "$1"; eval "$2"
            out=$(_awg_prebuilt_for_running_kernel); rc=$?
            printf "rc=%s out=[%s]\n" "$rc" "$out"' _ "$a" "$b"
        [ "$output" = "rc=2 out=[]" ] || { echo "$f: got '$output'"; false; }
    done
}

# The package removal part of step_uninstall: from the unhold loop to the end of
# the separate prebuilt purge. Runs it with the real _awg_installed_kmod_pkgs and
# apt-get, apt-mark, dpkg stubbed; apt-get prints each argument in <>, so names
# glued into one argument or an empty argument are visible.
_run_uninstall_purge() { # installer no_tweaks
    local blk helper
    blk=$(_fn "$1" step_uninstall \
        | awk '/^    for _hp in amneziawg amneziawg-dkms; do$/{on=1} on{print} on && /_kmods_rc != 0/{seen=1} seen && /^    fi$/{exit}')
    helper=$(_fn "$1" _awg_installed_kmod_pkgs)
    [ -n "$blk" ] && [ -n "$helper" ] || return 99
    T=$(mktemp -d)
    # Events go to a file: the code captures apt-get's output and silences apt-mark.
    NT="$2" AWGD="$T" EV="$T/ev" bash -c "$STUB_DPKG_QUERY"'
        apt-get() {
            { printf "APT"; printf " <%s>" "$@"; echo; } >>"$EV"
            if [ "${APT_FAIL_KMOD:-0}" = 1 ] && [[ " $* " == *" amneziawg-kmod-"* ]]; then
                echo "E: sub-process returned an error code"; return 100
            fi
            return 0
        }
        apt-mark() { echo "MARK $*" >>"$EV"; }
        dpkg() { :; }
        log() { :; }; log_warn() { echo "WARN $*" >>"$EV"; }
        AWG_DIR=$AWGD saved_no_tweaks=$NT
        eval "$2"
        g() { eval "$1"; }; g "$1"; rc=$?
        cat "$EV" 2>/dev/null; exit $rc
    ' _ "$blk" "$helper"
    local rc=$?
    rm -rf "$T"
    return $rc
}

@test "uninstall: prebuilt packages are unheld and purged in a call of their own, each as its own argument (RU + EN)" {
    local f nt
    export PKGS="amneziawg-kmod-ubuntu-2404-arm64|install ok installed
amneziawg-kmod-old|hold ok installed"
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        for nt in 0 1; do
            run _run_uninstall_purge "$ROOT/$f" "$nt"
            [ "$status" -eq 0 ] || { echo "$f nt=$nt: rc=$status $output"; false; }
            grep -qxF 'APT <purge> <-y> <amneziawg-dkms> <amneziawg-tools> <qrencode>' <<<"$output" \
                || { echo "$f nt=$nt: usual purge changed: $output"; false; }
            grep -qxF 'APT <purge> <-y> <amneziawg-kmod-ubuntu-2404-arm64> <amneziawg-kmod-old>' <<<"$output" \
                || { echo "$f nt=$nt: prebuilt purge missing or malformed: $output"; false; }
            # each unheld, before its purge
            awk '/^MARK unhold amneziawg-kmod-ubuntu-2404-arm64$/{a=NR} /^MARK unhold amneziawg-kmod-old$/{b=NR}
                 /^APT <purge> <-y> <amneziawg-kmod-/{p=NR} END{exit !(a && b && p && a < p && b < p)}' <<<"$output" \
                || { echo "$f nt=$nt: unhold missing or after the purge: $output"; false; }
            [[ "$output" != *"<>"* && "$output" != *WARN* ]] || { echo "$f nt=$nt: $output"; false; }
        done
    done
}

@test "uninstall: no prebuilt package -> only the usual purge (RU + EN)" {
    local f nt
    export PKGS=""
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        for nt in 0 1; do
            run _run_uninstall_purge "$ROOT/$f" "$nt"
            [ "$status" -eq 0 ] && [ "$(grep -c '^APT ' <<<"$output")" -eq 1 ] \
                && [[ "$output" != *amneziawg-kmod* && "$output" != *"<>"* && "$output" != *WARN* ]] \
                || { echo "$f nt=$nt: $output"; false; }
        done
    done
}

@test "uninstall: dpkg could not be asked -> said out loud, the usual purge still runs (RU + EN)" {
    local f nt
    export PKGS="amneziawg-kmod-ubuntu-2404-arm64|install ok installed" DPKG_FAIL=1
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        for nt in 0 1; do
            run _run_uninstall_purge "$ROOT/$f" "$nt"
            [ "$(grep -c '^APT ' <<<"$output")" -eq 1 ] \
                && grep -q "^WARN .*dpkg -l 'amneziawg-kmod-\*'" <<<"$output" \
                || { echo "$f nt=$nt: $output"; false; }
        done
    done
}

@test "uninstall: a failed prebuilt purge names the packages, apt's answer and the command (RU + EN)" {
    local f nt
    export PKGS="amneziawg-kmod-ubuntu-2404-arm64|install ok installed" APT_FAIL_KMOD=1
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        for nt in 0 1; do
            run _run_uninstall_purge "$ROOT/$f" "$nt"
            grep -qxF 'APT <purge> <-y> <amneziawg-dkms> <amneziawg-tools> <qrencode>' <<<"$output" \
                && grep -q '^WARN .*sub-process returned an error code' <<<"$output" \
                && grep -q '^WARN .*sudo apt-get purge -y amneziawg-kmod-ubuntu-2404-arm64' <<<"$output" \
                || { echo "$f nt=$nt: $output"; false; }
        done
    done
}

# A stop block of the ARM branch in step2_install_amnezia with the real
# _awg_rehold_for_prebuilt; die, apt-mark and the package helpers stubbed. Events
# are recorded in a file: the real function captures apt-mark's output, so a stub
# printing to stdout would show nothing.
_run_arm_stop() { # installer start-line-regex
    local blk rehold
    blk=$(sed -n '/^step2_install_amnezia() {$/,/^}$/p' "$1" | sed -n "/$2/,/^            fi\$/p")
    [ -n "$blk" ] || return 99
    # absent -> nothing restores the hold, which is what the tests must catch
    rehold=$(_fn "$1" _awg_rehold_for_prebuilt)
    [ -n "$rehold" ] || rehold='_awg_rehold_for_prebuilt() { :; }'
    EV=$(mktemp)
    EV="$EV" bash -c '
        die() { echo "DIE: $*" >>"$EV"; cat "$EV"; exit 1; }
        log_warn() { echo "WARN: $*" >>"$EV"; }
        apt-mark() { echo "APT-MARK $*" >>"$EV"; echo "apt-mark said: lock busy"; }
        _awg_hold_refusal_log() { echo "REFUSAL: $1" >>"$EV"; }
        _awg_pkg_held() { [ "$1" = amneziawg-dkms ] && [ "${HELD:-1}" = 1 ]; }
        _awg_prebuilt_for_running_kernel() { printf "%s" "$LEFT"; return "${LRC:-0}"; }
        _awg_installed_kmod_pkgs() { printf "%s" "$LEFT"; return "${LRC:-0}"; }
        uname() { echo 6.8.0-146-generic; }
        eval "$2"
        g() { eval "$1"; echo CONTINUED >>"$EV"; cat "$EV"; }; g "$1"
    ' _ "$blk" "$rehold"
    local rc=$?
    rm -f "$EV"
    return $rc
}

STARTS=('^            local _kmod_here _kmod_rc=0$' '^            local _kmod _kmod_rc=0$')

@test "ARM stops in step 2 put the hold back before stopping (RU + EN)" {
    local f start
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        # the fallback stop (#343) and the --no-prebuilt refusal
        for start in "${STARTS[@]}"; do
            export LEFT=amneziawg-kmod-ubuntu-2404-arm64 LRC=0 HELD=1
            run _run_arm_stop "$ROOT/$f" "$start"
            [ "$status" -ne 0 ] && [[ "$output" == *"DIE:"*"apt-get purge -y amneziawg-kmod-ubuntu-2404-arm64"* ]] \
                && [[ "$output" != *CONTINUED* && "$output" != *WARN:* ]] \
                || { echo "$f [$start]: $output"; false; }
            awk '/^APT-MARK hold .*amneziawg-dkms/{h=NR} /^DIE:/{d=NR} END{exit !(h && d && h < d)}' <<<"$output" \
                || { echo "$f [$start]: hold not restored before the stop: $output"; false; }
        done
    done
}

@test "ARM stops in step 2: a hold that did not take is said out loud, with apt's answer and the command (RU + EN)" {
    local f start
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        for start in "${STARTS[@]}"; do
            export LEFT=amneziawg-kmod-ubuntu-2404-arm64 LRC=0 HELD=0
            run _run_arm_stop "$ROOT/$f" "$start"
            [[ "$output" == *"REFUSAL: apt-mark said: lock busy"* ]] \
                && [[ "$output" == *"WARN:"*"sudo apt-mark hold amneziawg-dkms amneziawg"* ]] \
                && [[ "$output" == *"DIE:"* ]] \
                || { echo "$f [$start]: $output"; false; }
        done
    done
}

@test "ARM stops in step 2: dpkg could not be asked -> hold back and stop, without the purge advice (RU + EN)" {
    local f start
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        for start in "${STARTS[@]}"; do
            export LEFT="" LRC=2 HELD=1
            run _run_arm_stop "$ROOT/$f" "$start"
            [ "$status" -ne 0 ] && [[ "$output" == *"DIE:"*"dpkg -l 'amneziawg-kmod-*'"* ]] \
                && [[ "$output" != *"apt-get purge"* && "$output" != *CONTINUED* ]] \
                || { echo "$f [$start]: $output"; false; }
            awk '/^APT-MARK hold .*amneziawg-dkms/{h=NR} /^DIE:/{d=NR} END{exit !(h && d && h < d)}' <<<"$output" \
                || { echo "$f [$start]: hold not restored before the stop: $output"; false; }
        done
    done
}

@test "ARM step 2: nothing installed -> no hold, no stop, the DKMS path goes on (RU + EN)" {
    local f start
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        for start in "${STARTS[@]}"; do
            export LEFT="" LRC=0 HELD=1
            run _run_arm_stop "$ROOT/$f" "$start"
            [ "$status" -eq 0 ] && [[ "$output" == *CONTINUED* ]] && [[ "$output" != *APT-MARK* ]] \
                || { echo "$f [$start]: $output"; false; }
        done
    done
}
