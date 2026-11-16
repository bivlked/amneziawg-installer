#!/usr/bin/env bats
# check and diagnose warn when the amneziawg kernel module is on the system and
# unprivileged user namespaces are allowed without restriction.
#
# The module's generic netlink commands carry GENL_UNS_ADMIN_PERM and the family
# is netnsok, so CAP_NET_ADMIN inside a process's own user namespace is enough
# to create an amneziawg interface in its own netns and set I1-I5 on it. The
# module's I1-I5 parser takes the length in <r>/<rc>/<rd> as a signed int and
# never rejects a negative one (amneziawg-linux-kernel-module#233, src/junk.c;
# the same code in the pinned 2.0 source), which in some combinations writes
# past a kernel buffer. Our own commands refuse such values
# (awg_cps_check_safe); the warning is about everyone else on the host. The
# module declares MODULE_ALIAS_RTNL_LINK and MODULE_ALIAS_GENL_FAMILY, so an
# installed module that is not loaded may load by itself on the first request,
# unless module loading is disabled.
# Checked on an Ubuntu 24.04 stand on 12 oct 2026 without touching the bug:
# with kernel.apparmor_restrict_unprivileged_userns = 0 an ordinary user created
# the interface and set I1 = <r 8>; with 1 a plain unshare failed, but the
# stock restriction did not stop an ordinary user on the stand; with
# kernel.unprivileged_userns_clone = 0 unshare failed with EPERM.
#
# Quiet when the module is not on the system (not loaded and no non-empty
# module file for the running kernel, or module loading disabled), when a knob
# closes the path (unprivileged_userns_clone, max_user_namespaces or
# max_net_namespaces = 0), when max_user_namespaces or max_net_namespaces is
# missing, when the AppArmor restriction is in force (set, AppArmor not known to
# be off, not in complain mode), and when a value the verdict needs is not read:
# a guess here would teach people to ignore the warning. The AppArmor
# restriction does not close the path (it did not stop an ordinary user on the
# stand); staying quiet under it is the owner's decision of 12 oct 2026, and
# ADVANCED says so. For the same reason the advice never suggests turning that
# restriction on: unprivileged_userns_clone = 0, otherwise max_user_namespaces = 0.

# shellcheck disable=SC2016,SC2034  # bash -c bodies expand in the child
load test_helper

bats_require_minimum_version 1.5.0

COMMON="${BATS_TEST_DIRNAME}/../awg_common.sh"
COMMON_EN="${BATS_TEST_DIRNAME}/../awg_common_en.sh"

setup() {
    export AWG_USERNS_ROOT="$BATS_TEST_TMPDIR/root"
    mkdir -p "$AWG_USERNS_ROOT/proc/sys/kernel" "$AWG_USERNS_ROOT/proc/sys/user" \
        "$AWG_USERNS_ROOT/sys/module/apparmor/parameters"
}

# module : the amneziawg module is loaded.
module() { mkdir -p "$AWG_USERNS_ROOT/sys/module/amneziawg"; }

# installed : the module is installed for the running kernel but not loaded (a non-empty file).
installed() {
    local d
    d="$AWG_USERNS_ROOT/lib/modules/$(uname -r)/updates/dkms"
    mkdir -p "$d" && printf 'ELF' > "$d/amneziawg.ko.zst"
}

# knob <path under the root> <value> : write one knob.
knob() { printf '%s\n' "$2" > "$AWG_USERNS_ROOT/$1"; }

# debian / ubuntu : the knobs as the stock systems have them.
debian() {
    knob proc/sys/kernel/unprivileged_userns_clone 1
    knob proc/sys/user/max_user_namespaces 15329
    knob proc/sys/user/max_net_namespaces 15329
    knob proc/sys/kernel/modules_disabled 0
    rm -f "$AWG_USERNS_ROOT/proc/sys/kernel/apparmor_restrict_unprivileged_userns" \
        "$AWG_USERNS_ROOT/proc/sys/kernel/apparmor_restrict_unprivileged_userns_complain"
    knob sys/module/apparmor/parameters/enabled Y
}
ubuntu() {
    knob proc/sys/kernel/unprivileged_userns_clone 1
    knob proc/sys/user/max_user_namespaces 14934
    knob proc/sys/user/max_net_namespaces 14934
    knob proc/sys/kernel/modules_disabled 0
    knob proc/sys/kernel/apparmor_restrict_unprivileged_userns 1
    knob proc/sys/kernel/apparmor_restrict_unprivileged_userns_complain 0
    knob sys/module/apparmor/parameters/enabled Y
}

# lines <lib> : awg_userns_module_lines, its "message<TAB>fix" lines on stdout.
lines() {
    timeout 30 bash -c '
        log() { :; }; log_debug() { :; }; log_warn() { :; }; log_error() { echo "ERR: $*"; }
        source "$1" >/dev/null 2>&1 || true
        declare -F awg_userns_module_lines >/dev/null || { echo "NOFUNC"; exit 97; }
        awg_userns_module_lines
    ' _ "$1"
}

# warn <lib> : awg_userns_module_warn, warnings on stdout.
warn() {
    timeout 30 bash -c '
        log() { :; }; log_debug() { :; }; log_error() { echo "ERR: $*"; }
        log_warn() { echo "WARN: $*"; }
        source "$1" >/dev/null 2>&1 || true
        declare -F awg_userns_module_warn >/dev/null || { echo "NOFUNC"; exit 97; }
        awg_userns_module_warn
    ' _ "$1"
}

# doc <lib> : the ADVANCED file the advice of that twin must point to.
doc() { if [[ "$1" == *_en.sh ]]; then echo "ADVANCED.en.md#userns-module-adv"; else echo "ADVANCED.md#userns-module-adv"; fi; }

# quiet <case name> : both twins print nothing and return 0.
quiet() {
    local lib
    for lib in "$COMMON" "$COMMON_EN"; do
        run lines "$lib"
        [ "$status" -eq 0 ] || { echo "$1 $lib rc=$status: $output"; return 1; }
        [ -z "$output" ] || { echo "$1 $lib not quiet: $output"; return 1; }
    done
}

# warns <case name> <fix substring> [price substring] : both twins print one line
# naming #233 in their own language, with the fix (and its price), pointing to
# their own ADVANCED, never advising the AppArmor restriction.
warns() {
    local lib
    for lib in "$COMMON" "$COMMON_EN"; do
        run lines "$lib"
        [ "$status" -eq 0 ] || { echo "$1 $lib rc=$status: $output"; return 1; }
        [ "${#lines[@]}" -eq 1 ] || { echo "$1 $lib ${#lines[@]} lines: $output"; return 1; }
        [[ "$output" == *"#233"*$'\t'*"$2"* ]] || { echo "$1 $lib: $output"; return 1; }
        [[ -z "${3:-}" || "$output" == *$'\t'*"$3"* ]] || { echo "$1 $lib price: $output"; return 1; }
        [[ "$output" == *"$(doc "$lib")"* ]] || { echo "$1 $lib wrong pointer: $output"; return 1; }
        # the advice never names the AppArmor restriction in any form: after it check
        # would go quiet with the path still open
        [[ "$output" != *[Aa]pp[Aa]rmor* ]] || { echo "$1 $lib mentions AppArmor: $output"; return 1; }
        if [[ "$lib" == *_en.sh ]]; then
            [[ "$output" == "The amneziawg kernel module"* && "$output" == *"To close this path"* ]] || { echo "$1 $lib not English: $output"; return 1; }
        else
            [[ "$output" == "Модуль ядра amneziawg"* && "$output" == *"Закрыть этот путь"* ]] || { echo "$1 $lib not Russian: $output"; return 1; }
        fi
    done
}

@test "userns: stock Debian with the module loaded warns and names unprivileged_userns_clone, both twins" {
    module; debian
    warns debian "sysctl -w kernel.unprivileged_userns_clone=0" "Podman"
    local lib
    for lib in "$COMMON" "$COMMON_EN"; do
        run lines "$lib"
        [[ "$output" != *"PrivateUsers"* ]] || { echo "$lib clone advice carries the max_user_namespaces price: $output"; return 1; }
        [[ "$output" == *"не затрагивается"* || "$output" == *"not affected"* ]] || { echo "$lib clone price: $output"; return 1; }
    done
    warns debian-persist "echo 'kernel.unprivileged_userns_clone = 0' | sudo tee /etc/sysctl.d/99-userns.conf"
}

@test "userns: a module installed but not loaded counts, one for another kernel does not, both twins" {
    debian
    installed
    warns installed "kernel.unprivileged_userns_clone=0"
    # uncompressed (DKMS) and xz-compressed (Debian) module files count as well
    local ext d
    d="$AWG_USERNS_ROOT/lib/modules/$(uname -r)/updates/dkms"
    for ext in ko ko.xz; do
        rm -f "$d"/amneziawg.*
        printf 'ELF' > "$d/amneziawg.$ext"
        warns "installed .$ext" "kernel.unprivileged_userns_clone=0"
    done
    rm -rf "$AWG_USERNS_ROOT/lib/modules"
    mkdir -p "$AWG_USERNS_ROOT/lib/modules/0.0.0-other/updates/dkms" "$AWG_USERNS_ROOT/lib/modules/$(uname -r)/kernel"
    printf 'ELF' > "$AWG_USERNS_ROOT/lib/modules/0.0.0-other/updates/dkms/amneziawg.ko"
    quiet other-kernel
    # an empty module file (a broken DKMS build) cannot be loaded
    rm -rf "$AWG_USERNS_ROOT/lib/modules"
    mkdir -p "$AWG_USERNS_ROOT/lib/modules/$(uname -r)/updates/dkms"
    : > "$AWG_USERNS_ROOT/lib/modules/$(uname -r)/updates/dkms/amneziawg.ko"
    quiet empty-file
}

@test "userns: module loading disabled keeps a module that is not loaded quiet, not a loaded one, both twins" {
    debian; installed
    knob proc/sys/kernel/modules_disabled 1
    quiet not-loaded-disabled
    module
    warns loaded-disabled "kernel.unprivileged_userns_clone=0"
}

@test "userns: quiet when the module is not on the system, both twins" {
    debian
    quiet absent
}

@test "userns: stock Ubuntu (AppArmor restriction on and enabled) stays quiet by decision, both twins" {
    module; ubuntu
    quiet ubuntu
}

@test "userns: Ubuntu with the AppArmor restriction turned off warns and names unprivileged_userns_clone, both twins" {
    module; ubuntu
    knob proc/sys/kernel/apparmor_restrict_unprivileged_userns 0
    warns ubuntu-aa0 "kernel.unprivileged_userns_clone=0"
}

@test "userns: the AppArmor restriction in complain mode only logs, so it does not count, both twins" {
    module; ubuntu
    knob proc/sys/kernel/apparmor_restrict_unprivileged_userns_complain 1
    warns complain "kernel.unprivileged_userns_clone=0"
    # a kernel with the restriction but without the complain setting: the restriction counts
    rm -f "$AWG_USERNS_ROOT/proc/sys/kernel/apparmor_restrict_unprivileged_userns_complain"
    quiet no-complain-file
}

@test "userns: the AppArmor restriction counts unless AppArmor is known to be off, both twins" {
    module; ubuntu
    knob sys/module/apparmor/parameters/enabled N
    warns aa-off "kernel.unprivileged_userns_clone=0"
    local v
    for v in "" "?" missing; do
        if [[ "$v" == missing ]]; then
            rm -f "$AWG_USERNS_ROOT/sys/module/apparmor/parameters/enabled"
        else
            knob sys/module/apparmor/parameters/enabled "$v"
        fi
        quiet "aa-enabled='$v'"
    done
}

@test "userns: each closing knob keeps it quiet, leading zeros and spaces read as the number, both twins" {
    module; debian; knob proc/sys/kernel/unprivileged_userns_clone 0; quiet clone0
    debian; knob proc/sys/user/max_user_namespaces 0; quiet maxns0
    debian; knob proc/sys/user/max_net_namespaces 0; quiet netns0
    debian; knob proc/sys/kernel/unprivileged_userns_clone ' 00 '; quiet "clone=' 00 '"
    # a number longer than 10 digits is not read (it would overflow), so: do not know
    debian; knob proc/sys/user/max_user_namespaces 99999999999; quiet "maxns=11 digits"
    # while 10 digits, such as the int maximum some admins set, is read
    debian; knob proc/sys/user/max_user_namespaces 2147483647
    warns "maxns=10 digits" "kernel.unprivileged_userns_clone=0"
    # and an open host written with spaces still warns: spaces are not "do not know"
    debian; knob proc/sys/kernel/unprivileged_userns_clone ' 1 '; knob proc/sys/user/max_user_namespaces ' 015329 '
    warns spaced "kernel.unprivileged_userns_clone=0"
}

@test "userns: a setting that exists but holds no number means do not know, both twins" {
    local f
    for f in kernel/unprivileged_userns_clone user/max_user_namespaces user/max_net_namespaces \
             kernel/apparmor_restrict_unprivileged_userns kernel/apparmor_restrict_unprivileged_userns_complain; do
        module; debian
        knob "proc/sys/$f" abc
        quiet "$f=abc"
    done
    # modules_disabled matters only for a module that is not loaded
    rm -rf "$AWG_USERNS_ROOT/sys/module/amneziawg"
    debian; installed
    knob proc/sys/kernel/modules_disabled abc
    quiet "not loaded, modules_disabled=abc"
    module
    warns "loaded, modules_disabled=abc" "kernel.unprivileged_userns_clone=0"
}

@test "userns: quiet without max_user_namespaces or max_net_namespaces, both twins" {
    module; debian
    rm -f "$AWG_USERNS_ROOT/proc/sys/user/max_net_namespaces"
    quiet no-netns
    debian
    rm -f "$AWG_USERNS_ROOT/proc/sys/user/max_user_namespaces"
    quiet no-maxns
    # the case a reviewer raised: only the AppArmor knob readable, AppArmor off
    rm -f "$AWG_USERNS_ROOT/proc/sys/kernel/unprivileged_userns_clone"
    knob proc/sys/kernel/apparmor_restrict_unprivileged_userns 1
    knob sys/module/apparmor/parameters/enabled N
    quiet aa-only
}

@test "userns: without unprivileged_userns_clone the advice is max_user_namespaces, never the AppArmor restriction, both twins" {
    module; debian
    rm -f "$AWG_USERNS_ROOT/proc/sys/kernel/unprivileged_userns_clone"
    # AppArmor on, restriction off: turning it back on would silence check with the path open
    knob proc/sys/kernel/apparmor_restrict_unprivileged_userns 0
    warns aa0 "sysctl -w user.max_user_namespaces=0" "PrivateUsers"
    # writing down the previous value comes before the command, or people write down 0
    local lib fix
    for lib in "$COMMON" "$COMMON_EN"; do
        run lines "$lib"
        fix="${output#*$'\t'}"
        [[ "$fix" == "Сначала запишите"*"sysctl -w"* || "$fix" == "First write down"*"sysctl -w"* ]] || { echo "$lib write-down order: $fix"; return 1; }
    done
    # AppArmor state unknown, or off
    rm -f "$AWG_USERNS_ROOT/sys/module/apparmor/parameters/enabled"
    warns aa-unknown "user.max_user_namespaces=0"
    knob sys/module/apparmor/parameters/enabled N
    warns aa-off "user.max_user_namespaces=0"
    # a plain kernel with only the user namespace limits readable
    rm -f "$AWG_USERNS_ROOT/proc/sys/kernel/apparmor_restrict_unprivileged_userns"
    warns plain "user.max_user_namespaces=0" "PrivateUsers"
}

@test "userns: the check form prints the message and the fix as two warnings, both twins" {
    local lib
    module; debian
    for lib in "$COMMON" "$COMMON_EN"; do
        run warn "$lib"
        [ "$status" -eq 0 ]; [ "${#lines[@]}" -eq 2 ] || { echo "$lib: $output"; return 1; }
        [[ "${lines[0]}" == "WARN:  - "*"#233"* ]] || { echo "$lib first: ${lines[0]}"; return 1; }
        [[ "${lines[1]}" == "WARN:    "*"unprivileged_userns_clone=0"* ]] || { echo "$lib second: ${lines[1]}"; return 1; }
    done
    ubuntu
    for lib in "$COMMON" "$COMMON_EN"; do
        run warn "$lib"; [ "$status" -eq 0 ]; [ -z "$output" ] || { echo "$lib quiet: $output"; return 1; }
    done
}

@test "userns: the same under set -u, both twins" {
    local lib
    module; debian
    for lib in "$COMMON" "$COMMON_EN"; do
        run timeout 30 bash -c '
            set -u
            log() { :; }; log_debug() { :; }; log_warn() { :; }; log_error() { :; }
            source "$1" >/dev/null 2>&1 || true
            awg_userns_module_lines
        ' _ "$lib"
        [ "$status" -eq 0 ]; [ "${#lines[@]}" -eq 1 ] || { echo "$lib: $output"; return 1; }
    done
}

# Every case sets AWG_USERNS_ROOT, so the production default is pinned here: an
# edit that made the function read another place with the variable unset would
# switch the warning off on real servers and leave every other test green.
@test "userns: with AWG_USERNS_ROOT unset the function reads the real /sys, /proc and /lib/modules, both twins" {
    local lib body
    for lib in "$COMMON" "$COMMON_EN"; do
        body=$(sed -n '/^awg_userns_module_lines()/,/^}/p' "$lib")
        [[ "$body" == *'local root="${AWG_USERNS_ROOT:-}"'* ]] || { echo "$lib: default root changed"; return 1; }
        [[ "$body" == *'"$root/sys/module/amneziawg"'* ]] || { echo "$lib: module path"; return 1; }
        [[ "$body" == *'"$root/lib/modules/$kver"'* ]] || { echo "$lib: modules path"; return 1; }
        [[ "$body" == *'"$root/proc/sys/$f"'* && "$body" == *'"$root/proc/sys/user/max_user_namespaces"'* ]] || { echo "$lib: proc path"; return 1; }
        [[ "$body" == *'"$root/sys/module/apparmor/parameters/enabled"'* ]] || { echo "$lib: apparmor path"; return 1; }
    done
}

@test "userns: check and diagnose call the warning and say when the library lacks it, both manage twins" {
    local m
    for m in "${BATS_TEST_DIRNAME}/../manage_amneziawg.sh" "${BATS_TEST_DIRNAME}/../manage_amneziawg_en.sh"; do
        sed -n '/^check_server()/,/^}/p' "$m" | grep -q 'declare -F awg_userns_module_warn' || { echo "check guard: $m"; return 1; }
        sed -n '/^check_server()/,/^}/p' "$m" | grep -qE '^\s+awg_userns_module_warn$' || { echo "check call: $m"; return 1; }
        sed -n '/^diagnose_server()/,/^}/p' "$m" | grep -q 'declare -F awg_userns_module_lines' || { echo "diagnose guard: $m"; return 1; }
        sed -n '/^diagnose_server()/,/^}/p' "$m" | grep -q '"$(awg_userns_module_lines)"' || { echo "diagnose call: $m"; return 1; }
    done
}

# The vendor fixed #233 in module 3.1.20261113-02 (PRs #237 and #247, tag
# v3.1.20261113-02 = 63ed35d, PPA build of 13 Nov 2026). Tag v3.1.20261113
# (6879e27) predates the merges and already reports "3.1.20261113", so a bare
# 3.1.20261113 is NOT fixed. The module version tells the fix apart: a loaded
# module from /sys/module/amneziawg/version, one that is not loaded from modinfo
# of every module file (which one modprobe picks is up to its index). The 2.0
# line (1.0.x) has no fixed release; an unknown version keeps the warning as it
# was. The apt advice needs the amneziawg-dkms package to be installed.

# modver <version> : the loaded module reports this version.
modver() { module; printf '%s\n' "$1" > "$AWG_USERNS_ROOT/sys/module/amneziawg/version"; }

# dkms_pkg : the amneziawg-dkms package is installed (dpkg's file list exists).
dkms_pkg() { mkdir -p "$AWG_USERNS_ROOT/var/lib/dpkg/info" && : > "$AWG_USERNS_ROOT/var/lib/dpkg/info/amneziawg-dkms.list"; }

# stub_modinfo <version|fail> : modinfo on PATH for "-F version <file>": prints the
# content of <file>.ver when that exists (the word fail there means exit 1),
# otherwise the given default.
stub_modinfo() {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat > "$BATS_TEST_TMPDIR/bin/modinfo" <<EOF
#!/bin/sh
[ "\$1" = -F ] && [ "\$2" = version ] && [ -n "\$3" ] || exit 2
v="$1"
[ -f "\$3.ver" ] && v=\$(cat "\$3.ver")
[ "\$v" = fail ] && exit 1
printf '%s\n' "\$v"
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/modinfo"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "userns: a loaded module with the vendor fix (3.1.20261113-02 and newer) stays quiet, both twins" {
    debian
    local v
    for v in 3.1.20261113-02 3.1.20261113-10 3.1.20261114 3.1.20261201 4.0.20270101; do
        modver "$v"; quiet "fixed $v"
    done
}

@test "userns: versions right at the boundary without the fix keep the warning, both twins" {
    debian
    local v
    # 3.1.20261113 is the tag before the fix was merged; -01 and other suffixes are not -02
    for v in 3.1.20261112 3.1.20261113 3.1.20261113-01 3.1.20261113-00 3.1.20261113-rc1 3.1.20261113.1; do
        modver "$v"; warns "unfixed $v" "kernel.unprivileged_userns_clone=0"
    done
}

@test "userns: a loaded 3.1 module older than the fix warns, names its version and the PPA upgrade with a reboot, both twins" {
    debian; dkms_pkg; modver 3.1.20260812
    warns old31 "kernel.unprivileged_userns_clone=0"
    local lib
    for lib in "$COMMON" "$COMMON_EN"; do
        run lines "$lib"
        [[ "$output" == *"3.1.20260812"* ]] || { echo "$lib version: $output"; return 1; }
        [[ "$output" == *"3.1.20261113-02"* ]] || { echo "$lib fixed version: $output"; return 1; }
        [[ "$output" == *"sudo apt-get update && sudo apt-get install --only-upgrade amneziawg-dkms"* ]] || { echo "$lib upgrade: $output"; return 1; }
        [[ "$output" == *"перезагруз"* || "$output" == *"reboot"* ]] || { echo "$lib reboot: $output"; return 1; }
    done
}

@test "userns: without the amneziawg-dkms package an old 3.1 module gets the rebuild advice, not apt, both twins" {
    debian; modver 3.1.20260812
    warns nopkg "kernel.unprivileged_userns_clone=0"
    local lib
    for lib in "$COMMON" "$COMMON_EN"; do
        run lines "$lib"
        [[ "$output" != *"only-upgrade"* ]] || { echo "$lib apt without the package: $output"; return 1; }
        [[ "$output" == *"3.1.20260812"* && "$output" == *"3.1.20261113-02"* ]] || { echo "$lib versions: $output"; return 1; }
        [[ "$output" == *"пересобрать"* || "$output" == *"rebuild"* ]] || { echo "$lib rebuild: $output"; return 1; }
    done
}

@test "userns: a loaded 2.0 line module warns without the PPA upgrade, which has no 2.0 fix, both twins" {
    debian; dkms_pkg; modver 1.0.20260725
    warns twozero "kernel.unprivileged_userns_clone=0"
    local lib
    for lib in "$COMMON" "$COMMON_EN"; do
        run lines "$lib"
        [[ "$output" == *"1.0.20260725"* ]] || { echo "$lib version: $output"; return 1; }
        [[ "$output" != *"only-upgrade"* ]] || { echo "$lib advises the PPA for 2.0: $output"; return 1; }
        [[ "$output" == *"2.0"* ]] || { echo "$lib 2.0: $output"; return 1; }
    done
    # a later date does not make a 2.0 line module fixed: the fix is in 3.1 only
    modver 1.0.20261201
    warns twozero-late "kernel.unprivileged_userns_clone=0"
}

@test "userns: an unknown or odd module version keeps the warning without a version claim, both twins" {
    debian; dkms_pkg
    local v lib
    for v in "" "garbage" "3.1.2026111" "3.1.20261113-02\$(id)" missing; do
        if [[ "$v" == missing ]]; then
            module; rm -f "$AWG_USERNS_ROOT/sys/module/amneziawg/version"
        else
            modver "$v"
        fi
        warns "version='$v'" "kernel.unprivileged_userns_clone=0"
        for lib in "$COMMON" "$COMMON_EN"; do
            run lines "$lib"
            [[ "$output" != *"only-upgrade"* ]] || { echo "$lib version='$v' upgrade advice: $output"; return 1; }
            [[ "$output" != *'$(id)'* ]] || { echo "$lib echoes the raw version: $output"; return 1; }
        done
    done
}

@test "userns: a module that is not loaded is judged by modinfo of its file, both twins" {
    debian; dkms_pkg; installed
    stub_modinfo 3.1.20261113-02
    quiet file-fixed
    stub_modinfo 3.1.20260812
    warns file-old "kernel.unprivileged_userns_clone=0"
    local lib
    for lib in "$COMMON" "$COMMON_EN"; do
        run lines "$lib"
        [[ "$output" == *"3.1.20260812"* && "$output" == *"only-upgrade"* ]] || { echo "$lib file-old: $output"; return 1; }
    done
    stub_modinfo fail
    warns file-unknown "kernel.unprivileged_userns_clone=0"
}

@test "userns: with several module files every one must be fixed, an unknown one keeps the warning, both twins" {
    debian; dkms_pkg; installed
    local d k
    k="$AWG_USERNS_ROOT/lib/modules/$(uname -r)"
    d="$k/updates/dkms"
    mkdir -p "$k/extra" "$k/kernel/drivers/net"
    printf 'ELF' > "$k/extra/amneziawg.ko"
    stub_modinfo 3.1.20261113-02
    quiet both-fixed
    # whichever order find walks in, one unfixed file is enough to warn
    printf '%s\n' 3.1.20260812 > "$k/extra/amneziawg.ko.ver"
    warns extra-old "kernel.unprivileged_userns_clone=0"
    local lib
    for lib in "$COMMON" "$COMMON_EN"; do
        run lines "$lib"
        [[ "$output" == *"3.1.20260812"* ]] || { echo "$lib names the unfixed file: $output"; return 1; }
    done
    rm -f "$k/extra/amneziawg.ko.ver"
    printf '%s\n' 3.1.20260812 > "$d/amneziawg.ko.zst.ver"
    warns dkms-old "kernel.unprivileged_userns_clone=0"
    rm -f "$d/amneziawg.ko.zst.ver"
    printf 'ELF' > "$k/kernel/drivers/net/amneziawg.ko.xz"
    printf '%s\n' fail > "$k/kernel/drivers/net/amneziawg.ko.xz.ver"
    warns one-unknown "kernel.unprivileged_userns_clone=0"
    for lib in "$COMMON" "$COMMON_EN"; do
        run lines "$lib"
        [[ "$output" != *"only-upgrade"* ]] || { echo "$lib unknown file still gets a version claim: $output"; return 1; }
    done
}

@test "userns: the loaded module decides even when the file on disk is already fixed (before a reboot), both twins" {
    debian; installed; stub_modinfo 3.1.20261113-02
    modver 3.1.20260812
    warns pending-reboot "kernel.unprivileged_userns_clone=0"
    modver 3.1.20261113-02; stub_modinfo 3.1.20260812
    quiet loaded-fixed
    # a loaded module without a readable version is "do not know": the fixed file
    # on disk says nothing about what runs in the kernel
    rm -f "$AWG_USERNS_ROOT/sys/module/amneziawg/version"; stub_modinfo 3.1.20261113-02
    warns loaded-noversion "kernel.unprivileged_userns_clone=0"
}

@test "userns: the anchor the advice points to exists in both ADVANCED files" {
    grep -q '<a id="userns-module-adv"></a>' "${BATS_TEST_DIRNAME}/../ADVANCED.md"
    grep -q '<a id="userns-module-adv"></a>' "${BATS_TEST_DIRNAME}/../ADVANCED.en.md"
}
