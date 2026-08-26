#!/usr/bin/env bats
# step 1 must not let `apt full-upgrade` strip the packages the server needs to
# boot.
#
# Issue #223. cleanup_system purges its own list, and apt takes the
# ubuntu-server meta-package along as a reverse dependency. On images where that
# was the only manual root, udev, initramfs-tools, netplan.io and everything
# else hanging under it become "no longer required". The `apt full-upgrade`
# that runs 60 seconds later is then free to drop such a package instead of
# upgrading it, and on a system with months of pending updates that is exactly
# what happened: 34 packages removed, udev among them. Without udev there is no
# /dev/disk/by-label, systemd never sees the partitions fstab refers to by
# label, and the server drops into emergency mode on the reboot that step 1
# itself triggers. The user is left with an unreachable server.
#
# Two guards answer this, and both are order-sensitive, which is why the tests
# below assert positions and not just presence:
#   1. `apt-mark manual` on the boot-critical set, BEFORE the upgrade;
#   2. a check that nothing from that set disappeared, AFTER the upgrade and
#      BEFORE request_reboot - while the server is still reachable.
#
# The functional tests lift the real blocks out of the shipped installer rather
# than reimplementing them. A copy of the logic inside the test would stay green
# after the guard was deleted from the installer, which is the exact regression
# this file exists to catch.

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

# Pull the post-upgrade loss gate out of step1.
extract_gate() {
    sed -n '/^    local critical_lost=""$/,/^    fi$/p' "$1"
}

# Line number of the first match inside the file, 0 when absent.
line_of() {
    grep -n -m1 -- "$2" "$1" | cut -d: -f1
}

# ===========================================================================
# static: the list exists, names the packages that actually brick a boot
# ===========================================================================

@test "boot-critical: RU installer defines the package list" {
    run extract_func "$(RU_INSTALL)" _boot_critical_package_list
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "boot-critical: EN installer defines the package list" {
    run extract_func "$(EN_INSTALL)" _boot_critical_package_list
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "boot-critical: the list names udev and initramfs-tools" {
    # udev is the package whose removal caused Issue #223; without
    # initramfs-tools a kernel upgrade produces no initramfs at all.
    local ru en
    ru=$(extract_func "$(RU_INSTALL)" _boot_critical_package_list)
    en=$(extract_func "$(EN_INSTALL)" _boot_critical_package_list)
    for want in udev initramfs-tools; do
        echo "$ru" | grep -q -- "$want"
        echo "$en" | grep -q -- "$want"
    done
}

@test "boot-critical: RU and EN ship the identical package list" {
    local ru en
    ru=$(extract_func "$(RU_INSTALL)" _boot_critical_package_list | grep -o '"[^"]*"' | tail -1)
    en=$(extract_func "$(EN_INSTALL)" _boot_critical_package_list | grep -o '"[^"]*"' | tail -1)
    [ -n "$ru" ]
    [ "$ru" = "$en" ]
}

# ===========================================================================
# static: ORDER. Presence alone would not have prevented Issue #223 - the
# existing apt-mark hold was present too, and was released before the upgrade.
# ===========================================================================

@test "boot-critical: RU marks manual BEFORE apt full-upgrade" {
    local mark upgrade
    mark=$(line_of "$(RU_INSTALL)" 'apt-mark manual \$critical_before')
    upgrade=$(line_of "$(RU_INSTALL)" 'apt full-upgrade -y')
    [ -n "$mark" ]
    [ -n "$upgrade" ]
    [ "$mark" -lt "$upgrade" ]
}

@test "boot-critical: EN marks manual BEFORE apt full-upgrade" {
    local mark upgrade
    mark=$(line_of "$(EN_INSTALL)" 'apt-mark manual \$critical_before')
    upgrade=$(line_of "$(EN_INSTALL)" 'apt full-upgrade -y')
    [ -n "$mark" ]
    [ -n "$upgrade" ]
    [ "$mark" -lt "$upgrade" ]
}

@test "boot-critical: RU gate sits AFTER the upgrade and BEFORE the reboot" {
    local upgrade gate reboot
    upgrade=$(grep -n -- 'apt full-upgrade -y' "$(RU_INSTALL)" | tail -1 | cut -d: -f1)
    gate=$(line_of "$(RU_INSTALL)" 'local critical_lost=""')
    reboot=$(line_of "$(RU_INSTALL)" 'request_reboot 2')
    [ -n "$upgrade" ] && [ -n "$gate" ] && [ -n "$reboot" ]
    [ "$gate" -gt "$upgrade" ]
    [ "$gate" -lt "$reboot" ]
}

@test "boot-critical: EN gate sits AFTER the upgrade and BEFORE the reboot" {
    local upgrade gate reboot
    upgrade=$(grep -n -- 'apt full-upgrade -y' "$(EN_INSTALL)" | tail -1 | cut -d: -f1)
    gate=$(line_of "$(EN_INSTALL)" 'local critical_lost=""')
    reboot=$(line_of "$(EN_INSTALL)" 'request_reboot 2')
    [ -n "$upgrade" ] && [ -n "$gate" ] && [ -n "$reboot" ]
    [ "$gate" -gt "$upgrade" ]
    [ "$gate" -lt "$reboot" ]
}

@test "boot-critical: the gate is fatal, not a warning" {
    # A log_warn here would leave the installer rebooting into an unbootable
    # system, which is the whole failure being prevented.
    local ru en
    ru=$(extract_gate "$(RU_INSTALL)")
    en=$(extract_gate "$(EN_INSTALL)")
    echo "$ru" | grep -q 'die '
    echo "$en" | grep -q 'die '
}

@test "boot-critical: hold list and boot-critical list stay separate" {
    # The pre-existing apt-mark hold guards the purge and is released inside
    # cleanup_system. Collapsing the two would re-open Issue #223.
    run grep -c 'apt-mark unhold' "$(RU_INSTALL)"
    [ "$output" -ge 1 ]
    run grep -c '_boot_critical_package_list' "$(RU_INSTALL)"
    [ "$output" -ge 2 ]
}

# ===========================================================================
# functional: the shipped functions, executed against stubbed dpkg
# ===========================================================================

# Load _installed_boot_critical (and its list helper) out of a script.
load_lister() {
    local script="$1"
    eval "$(extract_func "$script" _boot_critical_package_list)"
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

@test "boot-critical: lister stays silent when nothing is installed" {
    load_lister "$(EN_INSTALL)"
    dpkg-query() { return 1; }
    run _installed_boot_critical
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# Wrap the extracted gate in a function so its `local` declarations are legal.
load_gate() {
    local block
    block=$(extract_gate "$1")
    [ -n "$block" ] || return 1
    eval "_gate_under_test() {
$block
}"
}

setup_gate_stubs() {
    log() { echo "LOG $*"; }
    log_warn() { echo "WARN $*"; }
    log_error() { echo "ERROR $*"; }
    # The real die() terminates the process. A stub that merely returned would
    # let execution fall through to the "restored" log line and report success,
    # so the test would pass while the gate did nothing.
    die() { echo "DIE $*"; exit 42; }
    apt-get() { return 0; }
}

@test "boot-critical: gate stays quiet when every package survived" {
    load_gate "$(RU_INSTALL)"
    setup_gate_stubs
    dpkg-query() { echo "install ok installed"; }
    critical_before="udev initramfs-tools"
    run _gate_under_test
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "boot-critical: gate aborts when a package is gone and cannot be restored" {
    load_gate "$(RU_INSTALL)"
    setup_gate_stubs
    dpkg-query() { return 1; }   # nothing is installed, restore cannot help
    critical_before="udev"
    run _gate_under_test
    [ "$status" -eq 42 ]
    echo "$output" | grep -q "DIE"
    echo "$output" | grep -q "udev"
}

@test "boot-critical: gate accepts a successful restore without aborting" {
    load_gate "$(EN_INSTALL)"
    setup_gate_stubs
    # Absent on the first sweep, present once the restore has run. The marker
    # lives in a file on purpose: dpkg-query is called inside a pipeline, so a
    # shell counter would be incremented in a subshell and lost.
    dpkg-query() {
        [ -f "$BATS_TEST_TMPDIR/restored" ] || return 1
        echo "install ok installed"
    }
    apt-get() { touch "$BATS_TEST_TMPDIR/restored"; return 0; }
    critical_before="udev"
    run _gate_under_test
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | grep -c "DIE")" -eq 0 ]
    echo "$output" | grep -q "LOG"
}

@test "boot-critical: gate reports every lost package, not just the first" {
    load_gate "$(RU_INSTALL)"
    setup_gate_stubs
    dpkg-query() { return 1; }
    critical_before="udev initramfs-tools netplan.io"
    run _gate_under_test
    [ "$status" -eq 42 ]
    for pkg in udev initramfs-tools netplan.io; do
        echo "$output" | grep -q -- "$pkg"
    done
}
