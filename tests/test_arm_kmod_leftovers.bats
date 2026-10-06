#!/usr/bin/env bats
# The ARM prebuilt module package (amneziawg-kmod-<target>) around the edges of an
# install: --uninstall must remove it (it carries the module file), and a stop in
# step 2 while it is installed must leave amneziawg-dkms held, as the prebuilt path
# does on success. Both found on the ARM stand at gate G2.4 (6 oct 2026).

setup() {
    ROOT="${BATS_TEST_DIRNAME}/.."
}

# Run _awg_installed_kmod_pkgs from <installer> with dpkg-query answering from
# $PKGS ("name|status" per line).
_run_kmod_list() { # installer
    local body
    body=$(awk '/^_awg_installed_kmod_pkgs\(\) \{$/,/^}$/' "$1")
    [ -n "$body" ] || return 99
    bash -c '
        dpkg-query() { while IFS="|" read -r n s; do [ -n "$n" ] && printf "%s %s\n" "$n" "$s"; done <<<"$PKGS"; }
        eval "$1"
        _awg_installed_kmod_pkgs
    ' _ "$body"
}

@test "kmod list: every installed prebuilt package, whatever the kernel (RU + EN)" {
    local f
    export PKGS="amneziawg-kmod-ubuntu-2404-arm64|install ok installed
amneziawg-kmod-old|install ok half-configured
amneziawg-kmod-gone|deinstall ok config-files
amneziawg-kmod-purged|unknown ok not-installed
amneziawg-kmod-debian-trixie-arm64|install ok installed"
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run _run_kmod_list "$ROOT/$f"
        [ "$status" -eq 0 ] || { echo "$f: rc=$status $output"; false; }
        [ "$output" = "amneziawg-kmod-ubuntu-2404-arm64 amneziawg-kmod-old amneziawg-kmod-debian-trixie-arm64" ] \
            || { echo "$f: got '$output'"; false; }
    done
}

@test "kmod list: nothing installed -> empty (RU + EN)" {
    local f
    export PKGS=""
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run _run_kmod_list "$ROOT/$f"
        [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$f: got '$output'"; false; }
    done
}

# The package removal block of step_uninstall: from the unhold loop to the end of
# the purge branches. Runs it with apt-get, apt-mark, dpkg and the kmod list stubbed.
_run_uninstall_purge() { # installer no_tweaks
    local blk
    blk=$(awk '/^step_uninstall\(\) \{$/,/^}$/' "$1" \
        | awk '/^    for _hp in amneziawg amneziawg-dkms; do$/{on=1} on{print} on && /saved_no_tweaks" -eq 0/{seen=1} seen && /^    fi$/{exit}')
    [ -n "$blk" ] || return 99
    T=$(mktemp -d)
    NT="$2" AWGD="$T" bash -c '
        apt-get() { echo "APT $*"; }
        apt-mark() { :; }
        dpkg() { :; }
        log() { :; }; log_warn() { echo "WARN $*"; }
        _awg_installed_kmod_pkgs() { printf "%s" "$KMODS"; }
        AWG_DIR=$AWGD saved_no_tweaks=$NT
        g() { eval "$1"; }; g "$1"
    ' _ "$blk"
    local rc=$?
    rm -rf "$T"
    return $rc
}

@test "uninstall: the prebuilt module packages are purged with the rest, in both branches (RU + EN)" {
    local f nt
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        for nt in 0 1; do
            export KMODS="amneziawg-kmod-ubuntu-2404-arm64 amneziawg-kmod-old"
            run _run_uninstall_purge "$ROOT/$f" "$nt"
            [ "$status" -eq 0 ] || { echo "$f nt=$nt: rc=$status $output"; false; }
            [[ "$output" == *"APT purge -y amneziawg-dkms amneziawg-tools qrencode"* ]] \
                || { echo "$f nt=$nt: usual purge missing: $output"; false; }
            grep -E '^APT purge ' <<<"$output" | grep -qE '(^| )amneziawg-kmod-ubuntu-2404-arm64( |$)' \
                && grep -E '^APT purge ' <<<"$output" | grep -qE '(^| )amneziawg-kmod-old( |$)' \
                || { echo "$f nt=$nt: kmod packages not purged: $output"; false; }
        done
    done
}

@test "uninstall: no prebuilt package -> the purge is the usual one (RU + EN)" {
    local f nt
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        for nt in 0 1; do
            export KMODS=""
            run _run_uninstall_purge "$ROOT/$f" "$nt"
            [ "$status" -eq 0 ] || { echo "$f nt=$nt: rc=$status $output"; false; }
            [ "$(grep -c '^APT purge ' <<<"$output")" -eq 1 ] && [[ "$output" != *amneziawg-kmod* ]] \
                || { echo "$f nt=$nt: $output"; false; }
        done
    done
}

# A stop block of the ARM branch in step2_install_amnezia, run with die, apt-mark
# and the package helpers stubbed. apt-mark calls are printed, so the order of
# "hold" and the stop is visible.
_run_arm_stop() { # installer start-line-regex
    local blk rehold
    blk=$(sed -n '/^step2_install_amnezia() {$/,/^}$/p' "$1" | sed -n "/$2/,/^            fi\$/p")
    [ -n "$blk" ] || return 99
    # The real rehold function, when the installer has one; absent -> nothing
    # restores the hold, which is what the test must catch.
    rehold=$(awk '/^_awg_rehold_for_prebuilt\(\) \{$/,/^}$/' "$1")
    [ -n "$rehold" ] || rehold='_awg_rehold_for_prebuilt() { :; }'
    # Events go to a file: the real function silences apt-mark's output, so a
    # stub printing to stdout would show nothing.
    EV=$(mktemp)
    EV="$EV" bash -c '
        die() { echo "DIE: $*" >>"$EV"; cat "$EV"; exit 1; }
        log_warn() { echo "WARN: $*" >>"$EV"; }
        apt-mark() { echo "APT-MARK $*" >>"$EV"; }
        _awg_pkg_held() { [ "${HELD:-1}" = 1 ]; }
        _awg_prebuilt_for_running_kernel() { printf "%s" "$LEFT"; }
        _awg_installed_kmod_pkgs() { printf "%s" "$LEFT"; }
        eval "$2"
        g() { eval "$1"; echo CONTINUED >>"$EV"; cat "$EV"; }; g "$1"
    ' _ "$blk" "$rehold"
    local rc=$?
    rm -f "$EV"
    return $rc
}

@test "ARM stops in step 2 put the hold back before stopping (RU + EN)" {
    local f start
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        # the fallback stop (#343) and the --no-prebuilt refusal
        for start in '^            local _kmod_here$' '^            local _kmod$'; do
            export LEFT=amneziawg-kmod-ubuntu-2404-arm64 HELD=1
            run _run_arm_stop "$ROOT/$f" "$start"
            [ "$status" -ne 0 ] && [[ "$output" == *"DIE:"* ]] && [[ "$output" != *CONTINUED* ]] \
                || { echo "$f [$start]: no stop: $output"; false; }
            # hold of amneziawg-dkms, and before the stop
            awk '/^APT-MARK hold .*amneziawg-dkms/{h=NR} /^DIE:/{d=NR} END{exit !(h && d && h < d)}' <<<"$output" \
                || { echo "$f [$start]: hold not restored before the stop: $output"; false; }
        done
    done
}

@test "ARM stops in step 2: a hold that did not take is said out loud (RU + EN)" {
    local f start
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        for start in '^            local _kmod_here$' '^            local _kmod$'; do
            export LEFT=amneziawg-kmod-ubuntu-2404-arm64 HELD=0
            run _run_arm_stop "$ROOT/$f" "$start"
            [[ "$output" == *"WARN:"*amneziawg-dkms* ]] && [[ "$output" == *"DIE:"* ]] \
                || { echo "$f [$start]: $output"; false; }
        done
    done
}

@test "ARM step 2: nothing installed -> no hold, no stop, the DKMS path goes on (RU + EN)" {
    local f start
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        for start in '^            local _kmod_here$' '^            local _kmod$'; do
            export LEFT="" HELD=1
            run _run_arm_stop "$ROOT/$f" "$start"
            [ "$status" -eq 0 ] && [[ "$output" == *CONTINUED* ]] && [[ "$output" != *APT-MARK* ]] \
                || { echo "$f [$start]: $output"; false; }
        done
    done
}
