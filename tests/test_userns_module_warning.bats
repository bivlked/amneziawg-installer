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

@test "userns: the anchor the advice points to exists in both ADVANCED files" {
    grep -q '<a id="userns-module-adv"></a>' "${BATS_TEST_DIRNAME}/../ADVANCED.md"
    grep -q '<a id="userns-module-adv"></a>' "${BATS_TEST_DIRNAME}/../ADVANCED.en.md"
}
