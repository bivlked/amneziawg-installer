#!/usr/bin/env bats
# step 1 must not reboot into a system that lost the packages it needs to boot.
#
# Issue #223. cleanup_system purges its own list, and the ubuntu-server
# meta-package goes along as a reverse dependency of what is removed. On images
# where it was the only manual root, udev, initramfs-tools, netplan.io and
# everything else hanging under it become "no longer required". The
# `apt full-upgrade` that runs shortly afterwards is then free to drop such a
# package while resolving the upgrade, and on a system with months of pending
# updates that is what happened: 34 packages removed, udev among them. Without
# udev there is no /dev/disk/by-label, systemd never sees the partitions fstab
# refers to by label, and the server drops into emergency mode on the reboot
# that step 1 itself triggers. The user is left with an unreachable server.
#
# Three guards answer this, and all three are order-sensitive, which is why the
# tests below assert positions and not merely presence:
#   1. the snapshot is taken only after the dpkg repair and only when dpkg can
#      be trusted, because a broken dpkg reports everything as absent and would
#      switch both remaining guards off in silence;
#   2. `apt-mark manual` on that snapshot, BEFORE the upgrade;
#   3. `_verify_boot_critical` as the LAST action of the step, after everything
#      that could still remove a package and immediately before the reboot.
#
# The functional tests lift the real functions out of the shipped installer
# rather than reimplementing them. A copy of the logic inside the test would
# stay green after the guard was deleted from the installer, which is the exact
# regression this file exists to catch.

RU_INSTALL() { echo "$BATS_TEST_DIRNAME/../install_amneziawg.sh"; }
EN_INSTALL() { echo "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"; }

# Pull a whole function definition out of a script.
extract_func() {
    awk -v f="$2" '
        $0 ~ "^" f "\\(\\) \\{" { p = 1 }
        p { print }
        p && /^\}$/ { exit }
    ' "$1"
}

# Line number of the first match, empty when absent.
line_of() {
    grep -n -m1 -- "$2" "$1" | cut -d: -f1
}

# ===========================================================================
# static: the list
# ===========================================================================

@test "boot-critical: both installers define the package list" {
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        [ -n "$(extract_func "$f" _boot_critical_package_list)" ]
    done
}

@test "boot-critical: the list keeps every package it shipped with" {
    # Checking only udev would let a synchronised removal of any other member
    # pass, since the RU/EN parity test below compares the two lists against
    # each other rather than against a known set.
    local ru
    ru=$(extract_func "$(RU_INSTALL)" _boot_critical_package_list)
    for want in udev initramfs-tools openssh-server netplan.io netplan-generator \
                systemd-resolved ifupdown cloud-init ubuntu-minimal ubuntu-standard; do
        echo "$ru" | grep -q -- "$want"
    done
}

@test "boot-critical: RU and EN ship the identical package list" {
    local ru en
    ru=$(extract_func "$(RU_INSTALL)" _boot_critical_package_list | grep -o '"[^"]*"' | tail -1)
    en=$(extract_func "$(EN_INSTALL)" _boot_critical_package_list | grep -o '"[^"]*"' | tail -1)
    [ -n "$ru" ]
    [ "$ru" = "$en" ]
}

@test "boot-critical: the hold list and this list stay separate" {
    # The pre-existing apt-mark hold guards the purge and is released inside
    # cleanup_system. Collapsing the two would re-open Issue #223.
    local hold_list crit_list
    hold_list=$(grep -m1 '_hold_pkgs="' "$(RU_INSTALL)" | grep -o '"[^"]*"')
    crit_list=$(extract_func "$(RU_INSTALL)" _boot_critical_package_list \
        | grep -o '"[^"]*"' | tail -1)
    [ -n "$hold_list" ] && [ -n "$crit_list" ]
    [ "$hold_list" != "$crit_list" ]
    run grep -c 'apt-mark unhold' "$(RU_INSTALL)"
    [ "$output" -ge 1 ]
}

# ===========================================================================
# static: ORDER. Presence alone would not have prevented Issue #223 - the
# existing apt-mark hold was present too, and released before the upgrade.
# ===========================================================================

@test "boot-critical: the snapshot is taken only when dpkg can be trusted" {
    # A broken dpkg answers "not installed" for every probe. Without this guard
    # the snapshot would come back empty, apt-mark would be skipped and the
    # verification would iterate over nothing: the protection would switch
    # itself off on exactly the machines where the defect bites.
    # Scoped to the step 1 body on purpose: _dpkg_usable is also called inside
    # _verify_boot_critical, which is defined earlier in the file. A file-wide
    # search finds that one and passes even when the step 1 guard is deleted.
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        local body guard snap
        body=$(extract_func "$f" step1_update_and_optimize)
        [ -n "$body" ]
        guard=$(echo "$body" | grep -n -m1 '_dpkg_usable || die' | cut -d: -f1)
        snap=$(echo "$body" | grep -n -m1 'critical_before="\$(_installed_boot_critical)"' | cut -d: -f1)
        [ -n "$guard" ] && [ -n "$snap" ]
        [ "$guard" -lt "$snap" ]
    done
}

@test "boot-critical: the snapshot is taken after the dpkg repair, not before" {
    # The repair block exists because apt-get check is expected to fail here on
    # first boot. Sampling dpkg before it would sample a dpkg known to be broken.
    # Anchored on the repair statement itself: the bare words "apt-get check"
    # also appear inside an error message, and matching those made this
    # assertion pass no matter where the snapshot sat.
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        local repair snap
        repair=$(line_of "$f" 'if ! apt-get check')
        snap=$(line_of "$f" 'critical_before="\$(_installed_boot_critical)"')
        [ -n "$repair" ] && [ -n "$snap" ]
        [ "$snap" -gt "$repair" ]
    done
}

@test "boot-critical: the snapshot precedes the manual marking" {
    # Moving the snapshot below its consumer would leave apt-mark an empty list
    # and the verification a self-comparison, with every other assertion here
    # still green.
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        local snap mark
        snap=$(line_of "$f" 'critical_before="\$(_installed_boot_critical)"')
        mark=$(line_of "$f" 'apt-mark manual \$critical_before')
        [ -n "$snap" ] && [ -n "$mark" ]
        [ "$snap" -lt "$mark" ]
    done
}

@test "boot-critical: the marking happens before the upgrade" {
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        local mark upgrade
        mark=$(line_of "$f" 'apt-mark manual \$critical_before')
        upgrade=$(line_of "$f" 'apt full-upgrade -y')
        [ -n "$mark" ] && [ -n "$upgrade" ]
        [ "$mark" -lt "$upgrade" ]
    done
}

@test "boot-critical: the marking is unconditional, --no-tweaks included" {
    # The marking repairs damage the image may have carried before we touched
    # anything, so no flag may switch it off. This invariant is documented in
    # the code and would otherwise have no test at all.
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        local block
        block=$(sed -n '/^    local critical_before$/,/^    fi$/p' "$f")
        [ -n "$block" ]
        [ "$(echo "$block" | grep -c 'NO_TWEAKS')" -eq 0 ]
    done
}

@test "boot-critical: an empty snapshot is reported, not passed over" {
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        local block
        block=$(sed -n '/^    local critical_before$/,/^    fi$/p' "$f")
        [ -n "$block" ]
        echo "$block" | grep -q 'log_warn'
    done
}

@test "boot-critical: verification is the last action before the reboot" {
    # This is the assertion that keeps the guard meaningful. install_packages
    # still runs after the upgrade and calls apt install without --no-remove, so
    # a check placed any earlier leaves a window of the same class it closes.
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        local body verify reboot between
        body=$(extract_func "$f" step1_update_and_optimize)
        [ -n "$body" ]
        verify=$(echo "$body" | grep -n -m1 '_verify_boot_critical "\$critical_before"' | cut -d: -f1)
        reboot=$(echo "$body" | grep -n -m1 'request_reboot 2' | cut -d: -f1)
        [ -n "$verify" ] && [ -n "$reboot" ]
        [ "$verify" -lt "$reboot" ]
        # Only blank lines, comments and plain log calls may separate the two.
        # Listing forbidden commands instead would miss a wrapper: install_packages
        # is a function, so a grep for "apt install" walks straight past it.
        between=$(echo "$body" | sed -n "$((verify + 1)),$((reboot - 1))p"             | grep -vE '^[[:space:]]*(#|$)' | grep -vE '^[[:space:]]*log "' || true)
        [ -z "$between" ]
    done
}

# ===========================================================================
# static: the verification function itself
# ===========================================================================

@test "boot-critical: the verification function is extractable from both" {
    # A single named test for this, so that a broken extractor produces one
    # clear diagnosis instead of a spray of unrelated failures below.
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        [ -n "$(extract_func "$f" _verify_boot_critical)" ]
    done
}

@test "boot-critical: verification is fatal, not a warning" {
    # A log_warn here would leave the installer rebooting into an unbootable
    # system, which is the whole failure being prevented.
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        extract_func "$f" _verify_boot_critical | grep -q '^    die \|^        die '
    done
}

@test "boot-critical: the fatal path tells the user not to reboot" {
    # At that moment only the running kernel keeps the session alive. "The
    # install failed, let me reboot and start clean" is the natural next move,
    # and it is the one that loses the server. Counted rather than merely found:
    # the warning appears both in the broken-dpkg exit and on the fatal path,
    # so a bare grep would survive deleting either one.
    local ru en
    ru=$(extract_func "$(RU_INSTALL)" _verify_boot_critical)
    en=$(extract_func "$(EN_INSTALL)" _verify_boot_critical)
    [ "$(echo "$ru" | grep -c 'НЕ ПЕРЕЗАГРУЖАЙТЕ')" -eq 2 ]
    [ "$(echo "$en" | grep -ci 'not reboot')" -eq 2 ]
    echo "$ru" | grep -q 'log_error "НЕ ПЕРЕЗАГРУЖАЙТЕ'
    echo "$en" | grep -q 'log_error "Do NOT reboot'
}

@test "boot-critical: a broken dpkg is not reported as a removal" {
    # Both conditions look identical from outside; blaming the upgrade would
    # send the user chasing packages that were never removed.
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        extract_func "$f" _verify_boot_critical | grep -q '_dpkg_usable || die'
    done
}

@test "boot-critical: the restore runs per package, not as one transaction" {
    # apt aborts the whole transaction when a single name has no candidate, so a
    # one-shot install would restore nothing at all - the lesson cleanup_system
    # already paid for on netplan-generator.
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        local block
        block=$(extract_func "$f" _verify_boot_critical)
        echo "$block" | grep -q 'for pkg in \$critical_lost'
        echo "$block" | grep -q 'apt-get install -y --no-remove "\$pkg"'
    done
}

@test "boot-critical: the final check covers the whole set" {
    # Re-checking only what the upgrade dropped would miss a package removed by
    # the restore itself. The last loop in the function must span the snapshot.
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        local last_loop
        last_loop=$(extract_func "$f" _verify_boot_critical | grep -E '^    for pkg in ' | tail -1)
        [ "$last_loop" = '    for pkg in $critical_before; do' ]
    done
}

# ===========================================================================
# functional: the shipped functions, executed against stubbed dpkg
# ===========================================================================

load_lister() {
    local script="$1"
    eval "$(extract_func "$script" _boot_critical_package_list)"
    eval "$(extract_func "$script" _pkg_present)"
    eval "$(extract_func "$script" _installed_boot_critical)"
}

@test "boot-critical: lister returns only the installed packages" {
    load_lister "$(RU_INSTALL)"
    dpkg-query() {
        case "$3" in
            udev|netplan.io) echo "install ok installed" ;;
            *) return 1 ;;
        esac
    }
    run _installed_boot_critical
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | grep -c .)" -eq 2 ]
    echo "$output" | grep -qx "udev"
    echo "$output" | grep -qx "netplan.io"
}

@test "boot-critical: lister is silent when nothing is installed, yet not inert" {
    # The silence has to be shown to be a decision. A lister whose package list
    # came back empty would also print nothing, so the same load is exercised
    # twice: once with dpkg denying everything, once with a single hit.
    load_lister "$(EN_INSTALL)"
    dpkg-query() { return 1; }
    run _installed_boot_critical
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    dpkg-query() { [ "$3" = "udev" ] && echo "install ok installed"; }
    run _installed_boot_critical
    [ "$output" = "udev" ]
}

@test "boot-critical: half-configured counts as present" {
    # grep "ok installed" would miss it, leaving the package unprotected right
    # after the purge storm that makes that state likely.
    load_lister "$(RU_INSTALL)"
    dpkg-query() { echo "install ok half-configured"; }
    run _pkg_present udev
    [ "$status" -eq 0 ]
}

@test "boot-critical: a removed-but-configured package counts as absent" {
    # "deinstall ok config-files" is what apt leaves behind after removing a
    # package that had configuration, which is literally the Issue #223 case. It
    # also contains the substring "install ok", so a looser match would read a
    # removed package as present.
    load_lister "$(RU_INSTALL)"
    dpkg-query() { echo "deinstall ok config-files"; }
    run _pkg_present udev
    [ "$status" -eq 1 ]
}

load_verifier() {
    eval "$(extract_func "$1" _pkg_present)"
    eval "$(extract_func "$1" _verify_boot_critical)"
}

setup_stubs() {
    log() { echo "LOG $*"; }
    log_debug() { :; }
    log_warn() { echo "WARN $*"; }
    log_error() { echo "ERROR $*"; }
    # The real die() terminates the process. A stub that merely returned would
    # let execution fall through to the "restored" log line and report success,
    # so the test would pass while the guard did nothing.
    die() { echo "DIE $*"; exit 42; }
    # Records its arguments so a test can prove what was actually asked for.
    apt-get() { echo "$*" >> "$BATS_TEST_TMPDIR/apt-args"; return 0; }
    _dpkg_usable() { return 0; }
}

@test "boot-critical: verification stays quiet when every package survived" {
    load_verifier "$(RU_INSTALL)"
    setup_stubs
    dpkg-query() { echo "install ok installed"; }
    run _verify_boot_critical "udev initramfs-tools"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "boot-critical: verification aborts when a package cannot be restored" {
    load_verifier "$(RU_INSTALL)"
    setup_stubs
    dpkg-query() { return 1; }
    run _verify_boot_critical "udev"
    [ "$status" -eq 42 ]
    echo "$output" | grep -q "DIE"
    echo "$output" | grep -q "udev"
}

@test "boot-critical: verification accepts a successful restore" {
    load_verifier "$(EN_INSTALL)"
    setup_stubs
    # Absent on the first sweep, present once the restore has run. The marker
    # lives in a file on purpose: dpkg-query is called inside a pipeline, so a
    # shell counter would be incremented in a subshell and lost.
    dpkg-query() {
        [ -f "$BATS_TEST_TMPDIR/restored" ] || return 1
        echo "install ok installed"
    }
    apt-get() { touch "$BATS_TEST_TMPDIR/restored"; return 0; }
    run _verify_boot_critical "udev"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | grep -c "DIE")" -eq 0 ]
}

@test "boot-critical: the restore asks apt for one package with --no-remove" {
    load_verifier "$(RU_INSTALL)"
    setup_stubs
    dpkg-query() { return 1; }
    run _verify_boot_critical "udev initramfs-tools"
    [ "$status" -eq 42 ]
    # Two separate invocations, each naming exactly one package.
    [ "$(grep -c . "$BATS_TEST_TMPDIR/apt-args")" -eq 2 ]
    grep -qx "install -y --no-remove udev" "$BATS_TEST_TMPDIR/apt-args"
    grep -qx "install -y --no-remove initramfs-tools" "$BATS_TEST_TMPDIR/apt-args"
}

@test "boot-critical: verification reports every lost package, not just the first" {
    load_verifier "$(RU_INSTALL)"
    setup_stubs
    dpkg-query() { return 1; }
    run _verify_boot_critical "udev initramfs-tools netplan.io"
    [ "$status" -eq 42 ]
    for pkg in udev initramfs-tools netplan.io; do
        echo "$output" | grep -q -- "$pkg"
    done
}

@test "boot-critical: verification blames dpkg, not the upgrade, when dpkg is broken" {
    load_verifier "$(RU_INSTALL)"
    setup_stubs
    dpkg-query() { return 1; }
    _dpkg_usable() { return 1; }
    run _verify_boot_critical "udev"
    [ "$status" -eq 42 ]
    echo "$output" | grep -q "dpkg"
    [ "$(echo "$output" | grep -c "Исчезли пакеты")" -eq 0 ]
}
