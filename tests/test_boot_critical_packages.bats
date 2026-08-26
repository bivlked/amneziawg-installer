#!/usr/bin/env bats
# step 1 must not reboot into a system that lost the packages it needs to boot.
#
# Issue #223. cleanup_system purges its own list, and the ubuntu-server
# meta-package goes along as a reverse dependency of what is removed. On images
# where it was the only manual root, udev, initramfs-tools, netplan.io and
# everything else hanging under it become "no longer required". The
# `apt full-upgrade` that used to run shortly afterwards was then free to
# drop such a package while resolving the upgrade, and on a system with months
# of pending updates that is what happened: a batch of packages removed, udev
# among them. Since v5.28.1 step 1 upgrades with `apt-get upgrade --with-new-pkgs`,
# which has no right to remove an installed package at all, and the guards
# below are the second line of defence rather than the only one. Without
# udev there is no /dev/disk/by-label, systemd never sees the partitions fstab
# refers to by label, and the server drops into emergency mode on the reboot
# that step 1 itself triggers. The user is left with an unreachable server.
#
# Four guards answer this, and each is order-sensitive, which is why the tests
# below assert positions and not merely presence:
#   1. the snapshot is taken only after the dpkg repair and only when dpkg can
#      be trusted, because a broken dpkg reports everything as absent and would
#      switch both remaining guards off in silence;
#   2. `apt-mark manual` on that snapshot, BEFORE the upgrade;
#   3. `_verify_boot_critical` as the LAST action of the step, after everything
#      that could still remove a package and immediately before the reboot;
#   4. the same check before step 2's reboot, and a snapshot that persists in
#      /root/awg so a package lost in an aborted run is still remembered.
#      Without that, the installer's own "run it again" advice walks the user
#      straight past the guard.
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

# The package names the list helper actually ships, one per line.
package_names_of() {
    extract_func "$1" _boot_critical_package_list \
        | grep -oE '\b[a-z0-9][a-z0-9.+-]*\b' \
        | grep -vxE 'printf|s|local|list' | sort -u
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
                systemd-resolved ifupdown ubuntu-minimal ubuntu-standard; do
        echo "$ru" | grep -q -- "$want"
    done
    # cloud-init must NOT be here: cleanup_system deliberately purges it under a
    # guard, so protecting it would have the verification reinstall the package
    # the same run just removed, and report that as a repair.
    [ "$(echo "$ru" | grep -c 'cloud-init')" -eq 0 ]
}

@test "boot-critical: RU and EN ship the identical package list" {
    # Compares the package NAMES, not the last quoted string in the function.
    # Rewriting the helper as `local list="..."; printf '%s' "$list"` would make
    # both sides equal the literal "$list" and this assertion meaningless.
    local ru en
    ru=$(package_names_of "$(RU_INSTALL)")
    en=$(package_names_of "$(EN_INSTALL)")
    [ "$(echo "$ru" | grep -c .)" -ge 9 ]
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
        snap=$(echo "$body" | grep -n -m1 'critical_before="\$(_boot_critical_snapshot)"' | cut -d: -f1)
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
        snap=$(line_of "$f" 'critical_before="\$(_boot_critical_snapshot)"')
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
        snap=$(line_of "$f" 'critical_before="\$(_boot_critical_snapshot)"')
        mark=$(line_of "$f" 'apt-mark manual \$critical_before')
        [ -n "$snap" ] && [ -n "$mark" ]
        [ "$snap" -lt "$mark" ]
    done
}

@test "boot-critical: the marking happens before the upgrade" {
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        local mark upgrade
        mark=$(line_of "$f" 'apt-mark manual \$critical_before')
        upgrade=$(line_of "$f" 'apt-get upgrade -y --with-new-pkgs')
        [ -n "$mark" ] && [ -n "$upgrade" ]
        [ "$mark" -lt "$upgrade" ]
    done
}

@test "boot-critical: the marking is unconditional, --no-tweaks included" {
    # The marking repairs damage the image may have carried before we touched
    # anything, so no flag may switch it off. The code says so at the block
    # itself; without this test the statement would be documentation only.
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        local block
        block=$(sed -n '/^    local critical_before$/,/^    fi$/p' "$f")
        [ -n "$block" ]
        # Structural rather than a blocklist of flag names: exactly one branch,
        # and it tests the snapshot. Any added condition, whatever it is called,
        # fails this.
        [ "$(echo "$block" | grep -cE '^[[:space:]]*(el)?if ')" -eq 1 ]
        echo "$block" | grep -qE '^    if \[\[ -n "\$critical_before" \]\]; then'
    done
}

@test "boot-critical: an empty snapshot is reported, not passed over" {
    # Scoped to the else branch on purpose. Grepping the whole block also
    # matches the apt-mark failure fallback, so deleting the branch this test is
    # named after left it green.
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        local elsebranch
        elsebranch=$(sed -n '/^    local critical_before$/,/^    fi$/p' "$f" \
            | sed -n '/^    else$/,/^    fi$/p')
        [ -n "$elsebranch" ]
        echo "$elsebranch" | grep -q 'log_warn'
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

@test "boot-critical: the restore tries one transaction first, then per package" {
    # Both stages are load-bearing and the ORDER is the point.
    # One transaction first because it decides WHAT the resolver treats as a
    # goal: one at a time, the other lost names are not goals and apt may leave
    # them absent. That is how the restore failed in Issue #223 even though the
    # guard fired.
    # Per package after: a single name with no candidate aborts a whole
    # transaction and would restore nothing - the lesson cleanup_system already
    # paid for on netplan-generator.
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        local block bulk loop
        block=$(extract_func "$f" _verify_boot_critical)
        bulk=$(echo "$block" | grep -n -m1 'apt-get install -y --no-remove \$critical_lost' | cut -d: -f1)
        loop=$(echo "$block" | grep -n -m1 'for pkg in \$critical_lost' | cut -d: -f1)
        [ -n "$bulk" ] && [ -n "$loop" ]
        [ "$bulk" -lt "$loop" ]
        echo "$block" | grep -q 'apt-get install -y --no-remove "\$pkg"'
        # The per-package pass must skip what the bulk call already restored,
        # otherwise apt is invoked a second time for every name for nothing.
        echo "$block" | grep -q '_pkg_installed_ok "\$pkg" && continue'
    done
}

@test "boot-critical: step 1 upgrades only in the form that cannot remove" {
    # The regression guard for Issue #223. The first version of this test named
    # the FORBIDDEN command and a review defeated it in one line: dist-upgrade
    # is full-upgrade under another spelling and contains none of its letters.
    # A blocklist cannot win that race, so assert the ALLOWED shape instead -
    # every live apt upgrade invocation in this function must be the same safe
    # one, and anything else, however spelled, shows up as an extra entry.
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        local body live n line call
        body=$(extract_func "$f" step1_update_and_optimize)
        [ -n "$body" ]
        live=$(echo "$body" | grep -vE '^[[:space:]]*#')
        # Assert the WHOLE invocation, not just the verb. Two earlier versions
        # of this test were defeated: one named the forbidden command and lost
        # to `dist-upgrade`; the next matched only the verb and lost to `-f`
        # appended at the end, which restores the right to remove while the
        # verb stays `apt-get upgrade`. So every live upgrade call must be one
        # of exactly two allowed strings, flags included.
        n=0
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            n=$((n + 1))
            call=$(echo "$line" | grep -oE 'apt(-get)?( +-{1,2}[a-zA-Z-]+)* +[a-z-]*upgrade[a-z-]*( +-{1,2}[a-zA-Z-]+)*')
            case "$call" in
                "apt-get upgrade -y --with-new-pkgs") ;;
                "apt-get upgrade -s --with-new-pkgs") ;;
                *)
                    echo "unexpected upgrade invocation: [$call] in: $line" >&2
                    return 1
                    ;;
            esac
        done < <(echo "$live" | grep -E 'apt(-get)?( +-{1,2}[a-zA-Z-]+)* +[a-z-]*upgrade')
        [ "$n" -ge 2 ]
        # And nothing else in this function may remove packages. The regex
        # above only sees upgrade verbs, so a plain `apt-get autoremove` added
        # here would be invisible to it - and autoremove is exactly what made
        # udev disposable in Issue #223 in the first place.
        if echo "$live" | grep -qE 'apt(-get)? +(-[^ ]+ +)*(autoremove|remove|purge)'; then
            echo "a package-removing apt call appeared in step 1" >&2
            return 1
        fi
    done
}

@test "boot-critical: the upgrade-failure verdict lives in its own function" {
    # Structural, and it is the enabling condition for the seven behavioural
    # tests below (six on the RU installer plus the EN twin). While this reasoning was inline inside step 1, the suite
    # could only grep it, and a review demonstrated that deleting the second
    # lock measurement, inverting the condition, dropping -s or dropping the
    # timeout all survived 52/52 green.
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        local body
        body=$(extract_func "$f" step1_update_and_optimize)
        echo "$body" | grep -q '|| _die_upgrade_failed'
        [ -n "$(extract_func "$f" _die_upgrade_failed)" ]
    done
}

@test "boot-critical: a busy dpkg lock is named only when a holder is present" {
    load_upgrade_failure "$(RU_INSTALL)"
    setup_stubs
    fuser() { echo " 1234 5678"; return 0; }
    timeout() { echo "$*" > "$BATS_TEST_TMPDIR/dryrun-args"; return 0; }
    run _die_upgrade_failed
    [ "$status" -eq 42 ]
    echo "$output" | grep -q "1234"
    echo "$output" | grep -q "dpkg-lock"
    # The dry run must not even be reached: the cause is already known.
    # The stub above is what makes this assertion mean anything. Without it
    # nobody writes dryrun-args, so the file is absent whether the dry run ran
    # or not, and the check passes for the wrong reason - which is exactly how
    # it behaved before a review pointed it out.
    [ ! -f "$BATS_TEST_TMPDIR/dryrun-args" ]
}

@test "boot-critical: the lock is measured again, not reused from before" {
    # The value sampled before the retry is stale: dpkg --configure -a and a
    # whole second apt run happen in between. Deleting the second measurement
    # kept the old test green, so assert the function calls fuser itself.
    load_upgrade_failure "$(RU_INSTALL)"
    setup_stubs
    fuser() { echo "called" >> "$BATS_TEST_TMPDIR/fuser-calls"; return 1; }
    timeout() { return 0; }
    run _die_upgrade_failed
    [ "$status" -eq 42 ]
    [ "$(grep -c . "$BATS_TEST_TMPDIR/fuser-calls")" -ge 1 ]
}

@test "boot-critical: a successful dry run is not passed off as the cause" {
    load_upgrade_failure "$(RU_INSTALL)"
    setup_stubs
    fuser() { return 1; }
    # Succeeds and prints an ordinary happy plan.
    timeout() { echo "0 upgraded, 0 newly installed, 0 to remove"; return 0; }
    run _die_upgrade_failed
    [ "$status" -eq 42 ]
    # The happy output must NOT be quoted as the reason.
    [ "$(echo "$output" | grep -c "0 upgraded")" -eq 0 ]
    # And the lock must not be blamed either. Absence alone is escapable by
    # rewording, so pin the correct verdict positively as well.
    [ "$(echo "$output" | grep -ci "dpkg-lock\|dpkg lock")" -eq 0 ]
    echo "$output" | grep -q "сходятся"
}

@test "boot-critical: a failing dry run reaches the user with apt's own words" {
    load_upgrade_failure "$(RU_INSTALL)"
    setup_stubs
    fuser() { return 1; }
    timeout() { echo "netplan.io : Depends: udev but it is not going to be installed"; return 100; }
    run _die_upgrade_failed
    [ "$status" -eq 42 ]
    echo "$output" | grep -q "Depends: udev"
}

@test "boot-critical: a dry run that fails silently is reported as unknown" {
    # rc != 0 with no output means the check did not answer. Claiming
    # dependencies resolve here would be the very defect this file exists to
    # prevent, one level deeper.
    load_upgrade_failure "$(RU_INSTALL)"
    setup_stubs
    fuser() { return 1; }
    timeout() { return 124; }
    run _die_upgrade_failed
    [ "$status" -eq 42 ]
    echo "$output" | grep -q "124"
    # Must not assert that dependencies are fine.
    [ "$(echo "$output" | grep -ci "сходятся\|resolve")" -eq 0 ]
    # Positive pin: the verdict has to say the check itself gave no answer.
    echo "$output" | grep -q "не ответила"
}

@test "boot-critical: the diagnosis is a simulation under a timeout" {
    # -s keeps it from becoming a third real upgrade on the fatal path, and the
    # timeout keeps the installer from hanging when the user's only remaining
    # access is that SSH session. Both were droppable without any test noticing.
    load_upgrade_failure "$(RU_INSTALL)"
    setup_stubs
    fuser() { return 1; }
    timeout() { echo "$*" > "$BATS_TEST_TMPDIR/dryrun-args"; return 0; }
    run _die_upgrade_failed
    [ "$status" -eq 42 ]
    grep -q -- "-s" "$BATS_TEST_TMPDIR/dryrun-args"
    grep -qE "^12[0-9] " "$BATS_TEST_TMPDIR/dryrun-args"
}

@test "boot-critical (EN): the upgrade-failure verdict behaves the same" {
    load_upgrade_failure "$(EN_INSTALL)"
    setup_stubs
    fuser() { return 1; }
    timeout() { return 124; }
    run _die_upgrade_failed
    [ "$status" -eq 42 ]
    echo "$output" | grep -q "124"
    [ "$(echo "$output" | grep -ci "resolve")" -eq 0 ]
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

@test "boot-critical: the snapshot survives a restart and only grows" {
    # The installer asks the user to re-run it after a failure, and by then a
    # package may already be gone. A snapshot recomputed from scratch would not
    # contain it, and the pre-reboot check would compare the system against an
    # impoverished baseline.
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        [ -n "$(extract_func "$f" _boot_critical_snapshot)" ]
        grep -q 'critical_before="\$(_boot_critical_snapshot)"' "$f"
        grep -q 'BOOT_CRITICAL_SNAPSHOT_FILE="\$AWG_DIR/' "$f"
    done
}

@test "boot-critical: the verdict uses the strict predicate, the snapshot the lenient one" {
    # One predicate cannot answer both questions. "Unpacked" means present for
    # the snapshot and broken for the verdict: initramfs-tools in that state has
    # generated no initramfs for the new kernel.
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        local verifier lister
        verifier=$(extract_func "$f" _verify_boot_critical)
        lister=$(extract_func "$f" _installed_boot_critical)
        [ -n "$verifier" ] && [ -n "$lister" ]
        [ "$(echo "$verifier" | grep -c '_pkg_installed_ok')" -ge 2 ]
        [ "$(echo "$verifier" | grep -c '_pkg_present ')" -eq 0 ]
        echo "$lister" | grep -q '_pkg_present '
    done
}

@test "boot-critical: the predicate self-tests before the snapshot is trusted" {
    # _dpkg_usable answers for dpkg only, while the predicate also leans on awk.
    # A broken awk yields an empty status, i.e. "absent" for everything at once.
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        local body selftest snap
        body=$(extract_func "$f" step1_update_and_optimize)
        selftest=$(echo "$body" | grep -n -m1 '_pkg_present dpkg || die' | cut -d: -f1)
        snap=$(echo "$body" | grep -n -m1 'critical_before="\$(_boot_critical_snapshot)"' | cut -d: -f1)
        [ -n "$selftest" ] && [ -n "$snap" ]
        [ "$selftest" -lt "$snap" ]
    done
}

@test "boot-critical: a missing udev raises an alarm on its own" {
    # udev is present on virtually every target server, so its absence means the
    # machine may already be damaged rather than that there is nothing to guard.
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        local body
        body=$(extract_func "$f" step1_update_and_optimize)
        echo "$body" | grep -q '_pkg_installed_ok udev'
    done
}

@test "boot-critical: the restore keeps apt exit code and never logs a blank line" {
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        local block
        block=$(extract_func "$f" _verify_boot_critical)
        echo "$block" | grep -q 'restore_rc=\$?'
        # An empty apt answer gets its own branch instead of an empty warning.
        echo "$block" | grep -q 'elif \[\[ -n "\$restore_out" \]\]'
    done
}

@test "boot-critical: step 2 reboots are guarded as well" {
    # Step 2 installs packages and reboots too, so it needs the same line of
    # defence; the guard is only meaningful next to a reboot it precedes.
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        local body verify_count reboot_count
        body=$(extract_func "$f" step2_install_amnezia)
        [ -n "$body" ]
        verify_count=$(echo "$body" | grep -c '_boot_critical_guard')
        reboot_count=$(echo "$body" | grep -c 'request_reboot 3')
        [ "$reboot_count" -ge 1 ]
        [ "$verify_count" -eq "$reboot_count" ]
    done
}

@test "boot-critical: no package name is a dpkg glob pattern" {
    # dpkg-query -W treats *, ? and [ as patterns. A multi-match would produce a
    # multi-line status that falls through to "present", blinding the guard for
    # that name with no error at all.
    local names
    names=$(extract_func "$(RU_INSTALL)" _boot_critical_package_list | grep -o '"[^"]*"' | tail -1 | tr -d '"')
    [ -n "$names" ]
    [ "$(echo "$names" | grep -c '[][*?]')" -eq 0 ]
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
    # package that had configuration, which is literally the Issue #223 case.
    # It contains the substring "install ok", so any match loosened in that
    # direction would read a removed package as present. The real gain of
    # parsing the third field is the opposite case, covered by the test above:
    # half-configured and unpacked, which "ok installed" reads as absent.
    load_lister "$(RU_INSTALL)"
    dpkg-query() { echo "deinstall ok config-files"; }
    run _pkg_present udev
    [ "$status" -eq 1 ]
}

load_verifier() {
    eval "$(extract_func "$1" _pkg_installed_ok)"
    eval "$(extract_func "$1" _verify_boot_critical)"
}

load_upgrade_failure() {
    eval "$(extract_func "$1" _die_upgrade_failed)"
}

load_snapshot() {
    eval "$(extract_func "$1" _boot_critical_package_list)"
    eval "$(extract_func "$1" _pkg_present)"
    eval "$(extract_func "$1" _installed_boot_critical)"
    eval "$(extract_func "$1" _boot_critical_snapshot)"
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
    apt-get() { echo "${DEBIAN_FRONTEND:-UNSET} $*" >> "$BATS_TEST_TMPDIR/apt-args"; return 0; }
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

@test "boot-critical: the restore asks apt for the whole set, then per package" {
    load_verifier "$(RU_INSTALL)"
    setup_stubs
    dpkg-query() { return 1; }
    run _verify_boot_critical "udev initramfs-tools"
    [ "$status" -eq 42 ]
    # Three invocations: one naming both packages, then one per package because
    # the stubbed dpkg-query keeps reporting them missing.
    [ "$(grep -c . "$BATS_TEST_TMPDIR/apt-args")" -eq 3 ]
    # The bulk call comes FIRST. Order is the whole point of the two stages:
    # co-dependent packages only converge when every name is a resolver goal.
    head -1 "$BATS_TEST_TMPDIR/apt-args" | grep -qx "noninteractive install -y --no-remove udev initramfs-tools"
    # The environment prefix is recorded too: a conffile prompt in an unattended
    # run would block the installer at the worst possible moment.
    grep -qx "noninteractive install -y --no-remove udev" "$BATS_TEST_TMPDIR/apt-args"
    grep -qx "noninteractive install -y --no-remove initramfs-tools" "$BATS_TEST_TMPDIR/apt-args"
}

@test "boot-critical: the per-package pass skips what the bulk call restored" {
    load_verifier "$(RU_INSTALL)"
    setup_stubs
    # udev comes back after the bulk call, initramfs-tools does not. Without the
    # skip, udev would be reinstalled a second time for nothing.
    dpkg-query() {
        local want="${!#}"
        if [[ "$want" == "udev" && -f "$BATS_TEST_TMPDIR/bulk-done" ]]; then
            echo "install ok installed"
            return 0
        fi
        return 1
    }
    apt-get() {
        echo "${DEBIAN_FRONTEND:-UNSET} $*" >> "$BATS_TEST_TMPDIR/apt-args"
        touch "$BATS_TEST_TMPDIR/bulk-done"
        return 0
    }
    run _verify_boot_critical "udev initramfs-tools"
    [ "$status" -eq 42 ]
    # Bulk call plus one per-package call for initramfs-tools only.
    [ "$(grep -c . "$BATS_TEST_TMPDIR/apt-args")" -eq 2 ]
    [ "$(grep -c "no-remove udev$" "$BATS_TEST_TMPDIR/apt-args")" -eq 0 ]
    grep -qx "noninteractive install -y --no-remove initramfs-tools" "$BATS_TEST_TMPDIR/apt-args"
}

@test "boot-critical (EN): the restore asks apt for the whole set, then per package" {
    # The two behavioural tests above load the Russian installer. The English
    # one is a separate file, not a translation layer, so a repair that regressed
    # only there would stay green on every RU-only assertion.
    load_verifier "$(EN_INSTALL)"
    setup_stubs
    dpkg-query() { return 1; }
    run _verify_boot_critical "udev initramfs-tools"
    [ "$status" -eq 42 ]
    [ "$(grep -c . "$BATS_TEST_TMPDIR/apt-args")" -eq 3 ]
    head -1 "$BATS_TEST_TMPDIR/apt-args" | grep -qx "noninteractive install -y --no-remove udev initramfs-tools"
    # The environment prefix matters here as much as in the RU twin: without it
    # an unattended run stops at a conffile prompt. Losing it in the EN file
    # only used to go unnoticed, because this twin checked less than its
    # original.
    grep -qx "noninteractive install -y --no-remove udev" "$BATS_TEST_TMPDIR/apt-args"
    grep -qx "noninteractive install -y --no-remove initramfs-tools" "$BATS_TEST_TMPDIR/apt-args"
}

@test "boot-critical (EN): the per-package pass skips what the bulk call restored" {
    load_verifier "$(EN_INSTALL)"
    setup_stubs
    dpkg-query() {
        local want="${!#}"
        if [[ "$want" == "udev" && -f "$BATS_TEST_TMPDIR/bulk-done" ]]; then
            echo "install ok installed"
            return 0
        fi
        return 1
    }
    apt-get() {
        echo "${DEBIAN_FRONTEND:-UNSET} $*" >> "$BATS_TEST_TMPDIR/apt-args"
        touch "$BATS_TEST_TMPDIR/bulk-done"
        return 0
    }
    run _verify_boot_critical "udev initramfs-tools"
    [ "$status" -eq 42 ]
    [ "$(grep -c . "$BATS_TEST_TMPDIR/apt-args")" -eq 2 ]
    [ "$(grep -c "no-remove udev$" "$BATS_TEST_TMPDIR/apt-args")" -eq 0 ]
    grep -qx "noninteractive install -y --no-remove initramfs-tools" "$BATS_TEST_TMPDIR/apt-args"
}

@test "boot-critical: a failed bulk transaction is reported, then retried per package" {
    # The per-package branch on a failing apt was already covered elsewhere in
    # this file; the BULK stage was not. Its failure branch carries the same
    # truncation and single-line collapse the comments there call
    # format-critical, and until this test nothing exercised it.
    load_verifier "$(RU_INSTALL)"
    setup_stubs
    dpkg-query() { return 1; }
    apt-get() {
        echo "${DEBIAN_FRONTEND:-UNSET} $*" >> "$BATS_TEST_TMPDIR/apt-args"
        # Only the bulk call fails; the per-package calls succeed but change
        # nothing, which is the realistic shape of the Issue #223 failure.
        case "$*" in
            *"udev initramfs-tools"*) echo "E: Unable to correct problems"; return 100 ;;
        esac
        return 0
    }
    run _verify_boot_critical "udev initramfs-tools"
    [ "$status" -eq 42 ]
    # The failure is announced with apt's own words, and on ONE line: log_msg
    # timestamps only the first line, so a multi-line answer breaks the log
    # format exactly where it will later be parsed.
    echo "$output" | grep -q "Unable to correct problems"
    [ "$(echo "$output" | grep -c "Одной транзакцией не вышло")" -eq 1 ]
    # And the per-package pass still ran for both names.
    [ "$(grep -c . "$BATS_TEST_TMPDIR/apt-args")" -eq 3 ]
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

@test "boot-critical: a held package is not mistaken for a lost one" {
    # Status is "<want> <error> <status>". Anchoring the whole "install ok
    # installed" pins the want flag too, so apt-mark hold would turn a healthy
    # package into a permanent stop the user cannot escape: apt-get install
    # exits 0 on a held, already-newest package and changes nothing. This is
    # reachable, not theoretical: cleanup_system preserves operator holds.
    load_verifier "$(RU_INSTALL)"
    for good in "install ok installed" "hold ok installed" "install reinstreq installed"; do
        eval "dpkg-query() { echo '$good'; }"
        run _pkg_installed_ok udev
        [ "$status" -eq 0 ]
    done
    for bad in "install ok unpacked" "install ok half-configured" "deinstall ok config-files"; do
        eval "dpkg-query() { echo '$bad'; }"
        run _pkg_installed_ok udev
        [ "$status" -ne 0 ]
    done
}

@test "boot-critical: an empty snapshot is not silent success" {
    # Step 2 takes its snapshot fresh. With the file missing and dpkg broken the
    # union is empty, and the verification used to return 0 without printing
    # anything while the reboot went ahead.
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        load_verifier "$f"
        setup_stubs
        run _verify_boot_critical ""
        [ "$status" -eq 0 ]
        echo "$output" | grep -q "WARN"
    done
}

@test "boot-critical: the step 2 wrapper carries its own self-tests" {
    # die inside a command substitution ends only the subshell, so the checks
    # cannot live inside _boot_critical_snapshot. They belong in the wrapper,
    # before the assignment.
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        local body
        body=$(extract_func "$f" _boot_critical_guard)
        [ -n "$body" ]
        echo "$body" | grep -q '_dpkg_usable || die'
        echo "$body" | grep -q '_pkg_present dpkg || die'
        echo "$body" | grep -q 'snapshot="$(_boot_critical_snapshot)"'
    done
}

@test "boot-critical: a successful apt exit is not taken as proof" {
    # apt exits 0 whenever it decides there is nothing to do, which is exactly
    # the held-package and stale-name cases. Without the re-check the log
    # contradicts itself: "Restored X" three lines above "X is missing".
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        extract_func "$f" _verify_boot_critical | grep -q '&& _pkg_installed_ok "$pkg"; then'
    done
}

@test "boot-critical: the fatal message names the ways out" {
    # Without them the stop is inescapable: nothing else in the installer, the
    # log or the docs mentions apt-mark unhold or the snapshot file.
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        local body
        body=$(extract_func "$f" _verify_boot_critical)
        echo "$body" | grep -q 'apt-mark unhold'
        echo "$body" | grep -q 'BOOT_CRITICAL_SNAPSHOT_FILE'
    done
}

@test "boot-critical: an unreadable snapshot file is reported, not silently dropped" {
    # Otherwise it is indistinguishable from a missing file: the list shrinks
    # and the function immediately overwrites the history with it, while its
    # whole contract is that it can only grow.
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        extract_func "$f" _boot_critical_snapshot | grep -q '! -r "$BOOT_CRITICAL_SNAPSHOT_FILE"'
    done
}

@test "boot-critical: the snapshot file does not outlive the installation" {
    # A stale name (a package renamed by a release upgrade) would stop the next
    # installation for a reason the user cannot see.
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        local body
        body=$(extract_func "$f" step99_finish)
        [ -n "$body" ]
        echo "$body" | grep -q 'BOOT_CRITICAL_SNAPSHOT_FILE'
    done
}

@test "boot-critical: a half-configured dpkg is not trusted" {
    # _dpkg_usable is the single probe that can switch every guard off at once:
    # if it wrongly says "usable" while the database is mid-interruption, the
    # snapshot comes back empty, apt-mark marks nothing and the verification
    # iterates over nothing. Until this test existed the shipped body had zero
    # execution coverage - it was stubbed in every functional test and only
    # grepped for in the static ones.
    #
    # The tempting edit is routing it through _pkg_present, which this release
    # introduces and which is deliberately permissive. Opposite question, wrong
    # answer: presence is not trustworthiness.
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        eval "$(extract_func "$f" _pkg_present)"
        eval "$(extract_func "$f" _dpkg_usable)"
        dpkg-query() { echo "install ok installed"; }
        run _dpkg_usable
        [ "$status" -eq 0 ]
        for bad in "install ok half-configured" "install ok unpacked" \
                   "install ok half-installed" "deinstall ok config-files"; do
            eval "dpkg-query() { echo '$bad'; }"
            run _dpkg_usable
            [ "$status" -ne 0 ]
        done
    done
}

@test "boot-critical: apt's own words reach the user when a restore fails" {
    # The fatal message tells the user to install the packages by hand. If the
    # reason apt refused is discarded, they rediscover it themselves over a live
    # SSH session on a server that must not be rebooted.
    load_verifier "$(RU_INSTALL)"
    setup_stubs
    dpkg-query() { return 1; }
    apt-get() { echo "E: Package 'udev' has no installation candidate" >&2; return 100; }
    run _verify_boot_critical "udev"
    [ "$status" -eq 42 ]
    echo "$output" | grep -q "no installation candidate"
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

@test "boot-critical: strict predicate rejects an unpacked package" {
    load_verifier "$(RU_INSTALL)"
    dpkg-query() { echo "install ok unpacked"; }
    run _pkg_installed_ok initramfs-tools
    [ "$status" -eq 1 ]
}

@test "boot-critical: strict predicate accepts a fully configured package" {
    load_verifier "$(RU_INSTALL)"
    dpkg-query() { echo "install ok installed"; }
    run _pkg_installed_ok udev
    [ "$status" -eq 0 ]
}

@test "boot-critical: snapshot remembers a package lost between runs" {
    # The exact scenario the guard exists for: apt removes udev and then fails,
    # so the end-of-step check never runs; the user re-runs as instructed.
    load_snapshot "$(RU_INSTALL)"
    # shellcheck disable=SC2034  # consumed by the shipped function loaded via eval
    AWG_DIR="$BATS_TEST_TMPDIR"
    BOOT_CRITICAL_SNAPSHOT_FILE="$BATS_TEST_TMPDIR/boot-critical.pkgs"
    log_warn() { echo "WARN $*"; }

    dpkg-query() {
        case "$3" in udev|initramfs-tools) echo "install ok installed" ;; *) return 1 ;; esac
    }
    run _boot_critical_snapshot
    echo "$output" | grep -qx "udev"

    # udev is gone now, and left behind as config-files.
    dpkg-query() {
        case "$3" in
            initramfs-tools) echo "install ok installed" ;;
            udev) echo "deinstall ok config-files" ;;
            *) return 1 ;;
        esac
    }
    run _boot_critical_snapshot
    echo "$output" | grep -qx "udev"
    echo "$output" | grep -qx "initramfs-tools"
}

@test "boot-critical: snapshot ignores names it does not know" {
    # A corrupted or substituted file must not become a list of arbitrary
    # packages for the restore loop to install.
    #
    # Both installers on purpose: scoping this to one language left the other
    # untested, and a mutation that stripped the filter from the RU installer
    # alone kept this file green.
    # shellcheck disable=SC2034  # consumed by the shipped function loaded via eval
    AWG_DIR="$BATS_TEST_TMPDIR"
    BOOT_CRITICAL_SNAPSHOT_FILE="$BATS_TEST_TMPDIR/boot-critical.pkgs"
    log_warn() { echo "WARN $*"; }
    dpkg-query() { return 1; }
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        load_snapshot "$f"
        printf 'udev
evil-package
' > "$BOOT_CRITICAL_SNAPSHOT_FILE"
        run _boot_critical_snapshot
        echo "$output" | grep -qx "udev"
        [ "$(echo "$output" | grep -c 'evil-package')" -eq 0 ]
    done
}
