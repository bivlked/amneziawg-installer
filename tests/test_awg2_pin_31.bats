#!/usr/bin/env bats
# The pinned module path (a kernel older than 6.7 with no prebuilt, for example
# Debian 12 on its stock 6.1) builds the module from the 3.1 tag that carries the
# fix for amneziawg-linux-kernel-module#233, while the profile stays 2.0. It used
# to build the 2.0 tag v1.0.20260725, which has no fix.
#
# Both trees land in /usr/src/amneziawg-1.0.0 (the vendor Makefile names the DKMS
# version 1.0.0 on every line), so a server that already has the 2.0 build would
# keep it on a rerun: DKMS sees "already built for this kernel" and installs the
# old module again. The installer therefore test-builds the new source first,
# then drops a source of another version, and after the build checks the version
# the module reports.
# Every case runs on both installers.

load test_helper

INSTALLERS=(install_amneziawg.sh install_amneziawg_en.sh)

_fn() { sed -n "/^$2() {\$/,/^}\$/p" "$BATS_TEST_DIRNAME/../$1"; }
_stub() { printf '#!/bin/bash\n%s\n' "$2" > "$T/bin/$1"; chmod +x "$T/bin/$1"; }
_ru() { [[ "$1" == install_amneziawg.sh ]]; }

setup() {
    T=$(mktemp -d); export T
    mkdir -p "$T/bin"
    export PATH="$T/bin:$PATH"
}

teardown() { /bin/rm -rf "$T"; }

# _drv <installer> <function> [helpers...] : a script that defines the logging
# stubs, the function and the helpers it calls, calls the function with the
# script's arguments and prints the dropped version kept by _awg_pin_drop_stale.
_drv() {
    local f="$1" fn="$2" h; shift 2
    {
        echo 'log() { echo "LOG: $*"; }; log_warn() { echo "WARN: $*"; }; log_error() { echo "ERR: $*"; }'
        { for h in "$@"; do _fn "$f" "$h"; done; _fn "$f" "$fn"; } | sed -e "s#/var/lib/dkms/#$T/var-dkms/#g"
        echo "$fn"' "$@"; rc=$?; [ -n "${_AWG_PIN_DROPPED:-}" ] && echo "DROPPED=$_AWG_PIN_DROPPED"; exit $rc'
    } > "$T/drv.sh"
}

_vh() { printf '#ifndef WIREGUARD_VERSION\n#define WIREGUARD_VERSION "%s"\n#endif\n' "$2" > "$1"; }

# dkms stub. "status" answers only to "-m amneziawg -v 1.0.0" (with or without
# -k <kernel>) and prints the registration kept in $T/dkms.reg; "remove" clears
# it and the DKMS tree $T/var-dkms/amneziawg unless $T/dkms.stuck exists (then it
# fails and the build stays) or $T/dkms.nosrc exists (then, like dkms without the
# source's dkms.conf, it complains and leaves the tree); "add"
# registers the source unless $T/dkms.noadd exists; "build" and "install" mark it
# installed. Every command except status is recorded in $T/dkms.calls.
_dkms_stub() { _stub dkms 'if [ "$1" = status ]; then
    [ "$2 $3 $4 $5" = "-m amneziawg -v 1.0.0" ] || exit 0
    cat "$T/dkms.reg" 2>/dev/null; exit 0
fi
echo "$*" >> "$T/dkms.calls"
case "$1" in
remove) [ -f "$T/dkms.stuck" ] && exit 3
    if [ -f "$T/dkms.nosrc" ]; then echo "Error! Could not locate dkms.conf file."; exit 0; fi
    : > "$T/dkms.reg"; rm -rf "$T/var-dkms/amneziawg"; exit 0 ;;
add) if [ -f "$T/dkms.noadd" ]; then echo "Error! Bad conf file."; exit 4; fi
     [ -s "$T/dkms.reg" ] || echo "amneziawg/1.0.0: added" > "$T/dkms.reg"; exit 0 ;;
build|install) echo "amneziawg/1.0.0, 6.1.0-test, x86_64: installed" > "$T/dkms.reg"; exit 0 ;;
esac
exit 0'; }

# modinfo stub: "-k <kver> -F version amneziawg" prints $T/modver; anything else fails.
_modinfo_stub() { _stub modinfo '[ "$1" = -k ] && [ "$3" = -F ] && [ "$4" = version ] && [ "$5" = amneziawg ] || exit 2
echo "$2" > "$T/modinfo.k"
[ -f "$T/modver" ] || exit 1
cat "$T/modver"'; }

@test "pin: both installers point at the 3.1 tag with the #233 fix and its commit" {
    local f
    for f in "${INSTALLERS[@]}"; do
        grep -qxF 'AWG2_PIN_TAG="v3.1.20261113-02"' "$BATS_TEST_DIRNAME/../$f" || { echo "$f: tag"; return 1; }
        grep -qxF 'AWG2_PIN_COMMIT="63ed35de3d3f135b17e8eae0b84949e7700303be"' "$BATS_TEST_DIRNAME/../$f" || { echo "$f: commit"; return 1; }
    done
}

@test "pin: the shipped tag is one the #233 boundary in check counts as fixed" {
    # The same boundary check uses (awg_common). The tag name stands in for the
    # version in its version.h; the stand build of this tag reported the same.
    local f tag
    for f in "${INSTALLERS[@]}"; do
        tag=$(sed -n 's/^AWG2_PIN_TAG="v\(.*\)"$/\1/p' "$BATS_TEST_DIRNAME/../$f")
        [ -n "$tag" ] || { echo "$f: no tag"; return 1; }
        run bash -c "$(sed -n '/^_awg_kmod_has_233_fix() {$/,/^}$/p' "$BATS_TEST_DIRNAME/../awg_common_en.sh"); _awg_kmod_has_233_fix '$tag'"
        [ "$status" -eq 0 ] || { echo "$f: $tag is not past the boundary"; return 1; }
    done
}

@test "src version: reads WIREGUARD_VERSION from version.h, both installers" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _drv "$f" _awg_module_src_version
        _vh "$T/v.h" 3.1.20261113-02
        run bash "$T/drv.sh" "$T/v.h"
        [ "$status" -eq 0 ] && [ "$output" = "3.1.20261113-02" ] || { echo "$f: rc=$status '$output'"; return 1; }
        _vh "$T/v.h" 1.0.20260725
        run bash "$T/drv.sh" "$T/v.h"
        [ "$status" -eq 0 ] && [ "$output" = "1.0.20260725" ] || { echo "$f: rc=$status '$output'"; return 1; }
        # tabs and extra spaces
        printf '#ifndef WIREGUARD_VERSION\n#\tdefine   WIREGUARD_VERSION\t"3.1.20261201"\n#endif\n' > "$T/v.h"
        run bash "$T/drv.sh" "$T/v.h"
        [ "$status" -eq 0 ] && [ "$output" = "3.1.20261201" ] || { echo "$f: spaces rc=$status '$output'"; return 1; }
        # the first define wins
        printf '#define WIREGUARD_VERSION "3.1.20261113-02"\n#define WIREGUARD_VERSION "9.9.9"\n' > "$T/v.h"
        run bash "$T/drv.sh" "$T/v.h"
        [ "$status" -eq 0 ] && [ "$output" = "3.1.20261113-02" ] || { echo "$f: first rc=$status '$output'"; return 1; }
        # a file without a final newline is read
        printf '#define WIREGUARD_VERSION "3.1.20261201"' > "$T/v.h"
        run bash "$T/drv.sh" "$T/v.h"
        [ "$status" -eq 0 ] && [ "$output" = "3.1.20261201" ] || { echo "$f: no newline rc=$status '$output'"; return 1; }
    done
}

@test "src version: no file, no define, a commented define or an odd value is a failure with empty output, both installers" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _drv "$f" _awg_module_src_version
        run bash "$T/drv.sh" "$T/missing.h"
        [ "$status" -eq 1 ] && [ -z "$output" ] || { echo "$f missing: rc=$status '$output'"; return 1; }
        printf '#define OTHER "1"\n' > "$T/v.h"
        run bash "$T/drv.sh" "$T/v.h"
        [ "$status" -eq 1 ] && [ -z "$output" ] || { echo "$f no define: rc=$status '$output'"; return 1; }
        printf '// #define WIREGUARD_VERSION "3.1.20261113-02"\n' > "$T/v.h"
        run bash "$T/drv.sh" "$T/v.h"
        [ "$status" -eq 1 ] && [ -z "$output" ] || { echo "$f commented: rc=$status '$output'"; return 1; }
        printf '#define WIREGUARD_VERSION "1.0$(id)"\n' > "$T/v.h"
        run bash "$T/drv.sh" "$T/v.h"
        [ "$status" -eq 1 ] && [ -z "$output" ] || { echo "$f odd value: rc=$status '$output'"; return 1; }
    done
}

@test "stale source: a source of another version is unregistered and removed, return 2, both installers" {
    local f
    _dkms_stub
    for f in "${INSTALLERS[@]}"; do
        rm -f "$T/dkms.calls"; mkdir -p "$T/src/amneziawg-1.0.0"; _vh "$T/src/amneziawg-1.0.0/version.h" 1.0.20260725
        echo "amneziawg/1.0.0, 6.1.0-test, x86_64: installed" > "$T/dkms.reg"
        _drv "$f" _awg_pin_drop_stale _awg_module_src_version
        run bash "$T/drv.sh" "$T/src/amneziawg-1.0.0" 3.1.20261113-02 1.0.0
        [ "$status" -eq 2 ] || { echo "$f: rc=$status $output"; return 1; }
        [ ! -e "$T/src/amneziawg-1.0.0" ] || { echo "$f: the old source stayed"; return 1; }
        grep -qxF 'remove -m amneziawg -v 1.0.0 --all' "$T/dkms.calls" || { echo "$f: dkms: $(cat "$T/dkms.calls" 2>/dev/null)"; return 1; }
        [[ "$output" == *"1.0.20260725"*"3.1.20261113-02"* ]] || { echo "$f: versions not named: $output"; return 1; }
        grep -qxF 'DROPPED=1.0.20260725' <<<"$output" || { echo "$f: dropped version not kept: $output"; return 1; }
    done
}

@test "stale source: the same version is left alone, both installers" {
    local f
    _dkms_stub
    for f in "${INSTALLERS[@]}"; do
        rm -f "$T/dkms.calls"; mkdir -p "$T/src/amneziawg-1.0.0"; _vh "$T/src/amneziawg-1.0.0/version.h" 3.1.20261113-02
        echo "amneziawg/1.0.0, 6.1.0-test, x86_64: installed" > "$T/dkms.reg"
        _drv "$f" _awg_pin_drop_stale _awg_module_src_version
        run bash "$T/drv.sh" "$T/src/amneziawg-1.0.0" 3.1.20261113-02 1.0.0
        [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$f: rc=$status $output"; return 1; }
        [ -f "$T/src/amneziawg-1.0.0/version.h" ] || { echo "$f: the source was removed"; return 1; }
        [ ! -e "$T/dkms.calls" ] || { echo "$f: dkms called: $(cat "$T/dkms.calls")"; return 1; }
    done
}

@test "stale source: no source and nothing registered is not an error and calls nothing, both installers" {
    local f
    _dkms_stub
    for f in "${INSTALLERS[@]}"; do
        rm -f "$T/dkms.calls" "$T/dkms.reg"; rm -rf "$T/src"
        _drv "$f" _awg_pin_drop_stale _awg_module_src_version
        run bash "$T/drv.sh" "$T/src/amneziawg-1.0.0" 3.1.20261113-02 1.0.0
        [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$f: rc=$status $output"; return 1; }
        [ ! -e "$T/dkms.calls" ] || { echo "$f: dkms called"; return 1; }
    done
}

@test "stale source: a build registered without its source is removed too, both installers" {
    # Otherwise dkms add of the new source fails as already added, DKMS reports
    # the old build as installed, and the old module goes back in.
    local f
    _dkms_stub
    for f in "${INSTALLERS[@]}"; do
        rm -f "$T/dkms.calls"; rm -rf "$T/src"
        echo "amneziawg/1.0.0, 6.1.0-test, x86_64: installed" > "$T/dkms.reg"
        _drv "$f" _awg_pin_drop_stale _awg_module_src_version
        run bash "$T/drv.sh" "$T/src/amneziawg-1.0.0" 3.1.20261113-02 1.0.0
        [ "$status" -eq 2 ] || { echo "$f: rc=$status $output"; return 1; }
        grep -qxF 'remove -m amneziawg -v 1.0.0 --all' "$T/dkms.calls" || { echo "$f: no dkms remove"; return 1; }
        grep -qxF 'DROPPED=unknown' <<<"$output" || { echo "$f: $output"; return 1; }
    done
}

@test "stale source: a DKMS tree left without its source is removed directly, both installers" {
    # dkms 3.0.10 without the source's dkms.conf lists nothing and its remove
    # fails while the tree stays (checked on a Debian 12 stand); the next dkms add
    # and build would then put the old module back.
    local f
    _dkms_stub; : > "$T/dkms.nosrc"
    for f in "${INSTALLERS[@]}"; do
        rm -f "$T/dkms.calls" "$T/dkms.reg"; rm -rf "$T/src"
        mkdir -p "$T/var-dkms/amneziawg/1.0.0/6.1.0-test"
        ln -sfn 1.0.0/6.1.0-test/x86_64 "$T/var-dkms/amneziawg/kernel-6.1.0-test-x86_64"
        _drv "$f" _awg_pin_drop_stale _awg_module_src_version
        run bash "$T/drv.sh" "$T/src/amneziawg-1.0.0" 3.1.20261113-02 1.0.0
        [ "$status" -eq 2 ] || { echo "$f: rc=$status $output"; return 1; }
        [ ! -e "$T/var-dkms/amneziawg/1.0.0" ] || { echo "$f: the tree stayed"; return 1; }
        [ ! -L "$T/var-dkms/amneziawg/kernel-6.1.0-test-x86_64" ] || { echo "$f: the link stayed"; return 1; }
        grep -qxF 'DROPPED=unknown' <<<"$output" || { echo "$f: $output"; return 1; }
    done
    rm -f "$T/dkms.nosrc"
}

@test "stale source: a source without a readable version counts as another version, both installers" {
    local f
    _dkms_stub
    for f in "${INSTALLERS[@]}"; do
        rm -f "$T/dkms.calls"; mkdir -p "$T/src/amneziawg-1.0.0"; : > "$T/src/amneziawg-1.0.0/dkms.conf"
        _drv "$f" _awg_pin_drop_stale _awg_module_src_version
        run bash "$T/drv.sh" "$T/src/amneziawg-1.0.0" 3.1.20261113-02 1.0.0
        [ "$status" -eq 2 ] || { echo "$f: rc=$status $output"; return 1; }
        [ ! -e "$T/src/amneziawg-1.0.0" ] || { echo "$f: stayed"; return 1; }
        grep -qxF 'remove -m amneziawg -v 1.0.0 --all' "$T/dkms.calls" || { echo "$f: no dkms remove"; return 1; }
    done
}

@test "stale source: a failed dkms remove with nothing left registered still goes on, both installers" {
    # dkms remove also fails when the module was never registered; what matters
    # is whether a build is still registered afterwards.
    local f
    _stub dkms 'if [ "$1" = status ]; then exit 0; fi; exit 3'
    for f in "${INSTALLERS[@]}"; do
        mkdir -p "$T/src/amneziawg-1.0.0"; _vh "$T/src/amneziawg-1.0.0/version.h" 1.0.20260725
        _drv "$f" _awg_pin_drop_stale _awg_module_src_version
        run bash "$T/drv.sh" "$T/src/amneziawg-1.0.0" 3.1.20261113-02 1.0.0
        [ "$status" -eq 2 ] || { echo "$f: rc=$status $output"; return 1; }
        [ ! -e "$T/src/amneziawg-1.0.0" ] || { echo "$f: stayed"; return 1; }
        [[ "$output" != *ERR:* ]] || { echo "$f: $output"; return 1; }
    done
}

@test "stale source: an old build still registered after dkms remove stops before the source is touched, both installers" {
    # Otherwise the new version.h would hide the old build from the next run:
    # the cleanup would be skipped, DKMS would report the old build as built,
    # and the old module would be installed again.
    local f
    _dkms_stub; _modinfo_stub; : > "$T/dkms.stuck"
    for f in "${INSTALLERS[@]}"; do
        echo 'amneziawg/1.0.0, 6.1.0-56-amd64, x86_64: installed' > "$T/dkms.reg"
        mkdir -p "$T/src/amneziawg-1.0.0"; _vh "$T/src/amneziawg-1.0.0/version.h" 1.0.20260725
        _drv "$f" _awg_pin_drop_stale _awg_module_src_version
        # the module of the running kernel is still on disk: no claim of a drop
        echo 1.0.20260725 > "$T/modver"
        run bash "$T/drv.sh" "$T/src/amneziawg-1.0.0" 3.1.20261113-02 1.0.0
        [ "$status" -eq 1 ] || { echo "$f: rc=$status $output"; return 1; }
        grep -qF '1.0.20260725' "$T/src/amneziawg-1.0.0/version.h" || { echo "$f: the old source was touched"; return 1; }
        [[ "$output" == *ERR:*"dkms"* ]] || { echo "$f: not loud: $output"; return 1; }
        [[ "$output" != *DROPPED=* ]] || { echo "$f: claims a drop: $output"; return 1; }
        # a partial remove took the module of the running kernel: the drop is reported
        rm -f "$T/modver"
        run bash "$T/drv.sh" "$T/src/amneziawg-1.0.0" 3.1.20261113-02 1.0.0
        [ "$status" -eq 1 ] || { echo "$f partial: rc=$status $output"; return 1; }
        grep -qxF 'DROPPED=1.0.20260725' <<<"$output" || { echo "$f partial: $output"; return 1; }
    done
}

@test "stale source: a source that cannot be removed fails loudly, both installers" {
    local f
    _dkms_stub
    _stub rm 'exit 1'
    for f in "${INSTALLERS[@]}"; do
        mkdir -p "$T/src/amneziawg-1.0.0"; _vh "$T/src/amneziawg-1.0.0/version.h" 1.0.20260725
        _drv "$f" _awg_pin_drop_stale _awg_module_src_version
        run bash "$T/drv.sh" "$T/src/amneziawg-1.0.0" 3.1.20261113-02 1.0.0
        [ "$status" -eq 1 ] || { echo "$f: rc=$status $output"; return 1; }
        [[ "$output" == *ERR:* && "$output" == *"$T/src/amneziawg-1.0.0"* ]] || { echo "$f: $output"; return 1; }
    done
}

@test "built check: the module for the kernel reports the expected version, both installers" {
    local f
    _modinfo_stub
    echo 3.1.20261113-02 > "$T/modver"
    for f in "${INSTALLERS[@]}"; do
        _drv "$f" _awg_pin_check_built
        run bash "$T/drv.sh" 6.1.0-41-amd64 3.1.20261113-02
        [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$f: rc=$status $output"; return 1; }
        [ "$(cat "$T/modinfo.k")" = 6.1.0-41-amd64 ] || { echo "$f: asked about the wrong kernel"; return 1; }
    done
}

@test "built check: an old module or no answer is a loud failure naming both versions, both installers" {
    local f v
    _modinfo_stub
    for f in "${INSTALLERS[@]}"; do
        _drv "$f" _awg_pin_check_built
        for v in 1.0.20260725 1.0.0 3.1.20261113 none; do
            if [[ "$v" == none ]]; then rm -f "$T/modver"; else echo "$v" > "$T/modver"; fi
            run bash "$T/drv.sh" 6.1.0-41-amd64 3.1.20261113-02
            [ "$status" -eq 1 ] || { echo "$f $v: rc=$status $output"; return 1; }
            [[ "$output" == ERR:* && "$output" == *"3.1.20261113-02"* ]] || { echo "$f $v: $output"; return 1; }
            [[ "$v" == none || "$output" == *"$v"* ]] || { echo "$f $v: the found version is not named: $output"; return 1; }
        done
    done
}

# ---------- the whole pinned build, run on stubs ----------

# _pin_drv <installer> : runs _install_pinned_awg2_module with its helpers, the
# system paths moved under $T. Prints RC and the dropped version at the end.
_pin_drv() {
    local fn
    mkdir -p "$T/tmp" "$T/log" "$T/usr/src" "$T/sys/module"
    {
        echo 'log() { echo "LOG: $*"; }; log_warn() { echo "WARN: $*"; }; log_error() { echo "ERR: $*"; }'
        echo 'AWG2_PIN_TAG=v3.1.test; AWG2_PIN_COMMIT=c0ffee'
        for fn in _awg_module_src_version _awg_pin_drop_stale _awg_pin_trial_build _awg_pin_check_built _install_pinned_awg2_module; do
            _fn "$1" "$fn"
        done | sed -e "s#/usr/src/#$T/usr/src/#g" -e "s#/var/log/#$T/log/#g" -e "s#/var/lib/dkms/#$T/var-dkms/#g" \
                   -e "s#/sys/module/#$T/sys/module/#g" -e "s#mktemp -d /tmp/#mktemp -d $T/tmp/#g"
        echo '_install_pinned_awg2_module; rc=$?; echo "RC=$rc DROPPED=${_AWG_PIN_DROPPED:-}"; exit $rc'
    } > "$T/drv.sh"
}

# _pin_stubs : git (clone lays out a source of version $T/src.ver), make
# (dkms-install copies it under $T/usr/src, a module build exits $T/make.rc),
# dkms (_dkms_stub), modinfo ($T/modver), modprobe and uname. make and modprobe
# are recorded in $T/dkms.calls too, so the order of all steps is in one file.
_pin_stubs() {
    _dkms_stub; _modinfo_stub
    _stub uname 'echo 6.1.0-test'
    _stub git 'case "$1" in
clone) d="${*: -1}"; mkdir -p "$d/src"; printf "#define WIREGUARD_VERSION \"%s\"\n" "$(cat "$T/src.ver")" > "$d/src/version.h"; : > "$d/src/dkms.conf" ;;
-C) echo c0ffee ;;
esac'
    _stub make 'echo "make $3" >> "$T/dkms.calls"
case "$3" in
dkms-install) mkdir -p "$T/usr/src/amneziawg-1.0.0"; cp "$2/version.h" "$2/dkms.conf" "$T/usr/src/amneziawg-1.0.0/" ;;
KERNELDIR=*) exit "$(cat "$T/make.rc" 2>/dev/null || echo 0)" ;;
esac'
    _stub modprobe 'echo modprobe >> "$T/dkms.calls"'
    echo 3.1.20261113-02 > "$T/src.ver"
}

_old_server() {
    mkdir -p "$T/usr/src/amneziawg-1.0.0"; _vh "$T/usr/src/amneziawg-1.0.0/version.h" 1.0.20260611
    echo "amneziawg/1.0.0, 6.1.0-test, x86_64: installed" > "$T/dkms.reg"
    mkdir -p "$T/var-dkms/amneziawg/1.0.0/6.1.0-test"
}

_reset() { /bin/rm -rf "${T:?}/usr" "${T:?}/sys" "${T:?}/tmp" "${T:?}/log" "$T/dkms.calls" "$T/dkms.reg" "$T/dkms.noadd" "$T/dkms.stuck" "$T/dkms.nosrc" "$T/make.rc" "$T/modver" "${T:?}/var-dkms"; }

_line() { grep -n -m1 -xF "$1" "$T/dkms.calls" | cut -d: -f1; }

@test "pinned build: a fresh install test-builds, lays out, builds, checks the version and loads, both installers" {
    local f a b c d e
    _pin_stubs
    for f in "${INSTALLERS[@]}"; do
        _reset; echo 3.1.20261113-02 > "$T/modver"
        _pin_drv "$f"
        run bash "$T/drv.sh"
        [ "$status" -eq 0 ] || { echo "$f: rc=$status $output"; return 1; }
        grep -qxF 'RC=0 DROPPED=' <<<"$output" || { echo "$f: $output"; return 1; }
        a=$(_line 'make KERNELDIR=/lib/modules/6.1.0-test/build'); b=$(_line 'make dkms-install')
        c=$(_line 'build -m amneziawg -v 1.0.0 -k 6.1.0-test'); d=$(_line 'install -m amneziawg -v 1.0.0 -k 6.1.0-test --force'); e=$(_line modprobe)
        [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ -n "$d" ] && [ -n "$e" ] || { echo "$f: a=$a b=$b c=$c d=$d e=$e: $(cat "$T/dkms.calls")"; return 1; }
        [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && [ "$c" -lt "$d" ] && [ "$d" -lt "$e" ] || { echo "$f: order: $(cat "$T/dkms.calls")"; return 1; }
        [ -z "$(ls -A "$T/tmp")" ] || { echo "$f: the work dir stayed: $(ls -R "$T/tmp")"; return 1; }
    done
}

@test "pinned build: on a server with the old build, the old one is dropped after the test build, both installers" {
    local f a r b
    _pin_stubs
    for f in "${INSTALLERS[@]}"; do
        _reset; _old_server; echo 3.1.20261113-02 > "$T/modver"
        _pin_drv "$f"
        run bash "$T/drv.sh"
        [ "$status" -eq 0 ] || { echo "$f: rc=$status $output"; return 1; }
        grep -qxF 'RC=0 DROPPED=1.0.20260611' <<<"$output" || { echo "$f: $output"; return 1; }
        a=$(_line 'make KERNELDIR=/lib/modules/6.1.0-test/build'); r=$(_line 'remove -m amneziawg -v 1.0.0 --all'); b=$(_line 'make dkms-install')
        [ -n "$a" ] && [ -n "$r" ] && [ -n "$b" ] && [ "$a" -lt "$r" ] && [ "$r" -lt "$b" ] || { echo "$f: order: $(cat "$T/dkms.calls")"; return 1; }
        grep -qF '3.1.20261113-02' "$T/usr/src/amneziawg-1.0.0/version.h" || { echo "$f: the new source is not in place"; return 1; }
    done
}

@test "pinned build: a source that does not build leaves the installed module untouched, both installers" {
    local f
    _pin_stubs
    for f in "${INSTALLERS[@]}"; do
        _reset; _old_server; echo 2 > "$T/make.rc"
        _pin_drv "$f"
        run bash "$T/drv.sh"
        [ "$status" -eq 1 ] || { echo "$f: rc=$status $output"; return 1; }
        grep -qxF 'RC=1 DROPPED=' <<<"$output" || { echo "$f: $output"; return 1; }
        grep -qF '1.0.20260611' "$T/usr/src/amneziawg-1.0.0/version.h" || { echo "$f: the old source was touched"; return 1; }
        ! grep -qE '^(remove|add|build|install|make dkms-install)' "$T/dkms.calls" || { echo "$f: touched: $(cat "$T/dkms.calls")"; return 1; }
        [[ "$output" == *ERR:*"6.1.0-test"* ]] || { echo "$f: not loud: $output"; return 1; }
    done
}

@test "pinned build: an old build that will not unregister stops the build before the new source is laid out, both installers" {
    local f
    _pin_stubs
    for f in "${INSTALLERS[@]}"; do
        _reset; _old_server; : > "$T/dkms.stuck"; echo 3.1.20261113-02 > "$T/modver"
        _pin_drv "$f"
        run bash "$T/drv.sh"
        rm -f "$T/dkms.stuck"
        [ "$status" -eq 1 ] || { echo "$f: rc=$status $output"; return 1; }
        ! grep -qxF 'make dkms-install' "$T/dkms.calls" || { echo "$f: laid out anyway: $(cat "$T/dkms.calls")"; return 1; }
        grep -qF '1.0.20260611' "$T/usr/src/amneziawg-1.0.0/version.h" || { echo "$f: the old source was touched"; return 1; }
    done
}

@test "pinned build: a module that reports another version stops before modprobe, both installers" {
    local f
    _pin_stubs
    for f in "${INSTALLERS[@]}"; do
        _reset; _old_server; echo 1.0.20260611 > "$T/modver"
        _pin_drv "$f"
        run bash "$T/drv.sh"
        [ "$status" -eq 1 ] || { echo "$f: rc=$status $output"; return 1; }
        grep -qxF 'RC=1 DROPPED=1.0.20260611' <<<"$output" || { echo "$f: $output"; return 1; }
        ! grep -qx modprobe "$T/dkms.calls" || { echo "$f: modprobe ran"; return 1; }
        [[ "$output" == *ERR:*"1.0.20260611"*"3.1.20261113-02"* ]] || { echo "$f: $output"; return 1; }
    done
}

@test "pinned build: with the old module still loaded the new one is not claimed as loaded, both installers" {
    local f
    _pin_stubs
    for f in "${INSTALLERS[@]}"; do
        _reset; _old_server; echo 3.1.20261113-02 > "$T/modver"
        mkdir -p "$T/sys/module/amneziawg"; echo 1.0.20260611 > "$T/sys/module/amneziawg/version"
        _pin_drv "$f"
        run bash "$T/drv.sh"
        [ "$status" -eq 0 ] || { echo "$f: rc=$status $output"; return 1; }
        ! grep -qx modprobe "$T/dkms.calls" || { echo "$f: modprobe ran"; return 1; }
        grep -qE '^LOG: .*3\.1\.20261113-02.*1\.0\.20260611' <<<"$output" || { echo "$f: $output"; return 1; }
    done
}

@test "pinned build: a source dkms add does not register is a loud failure with dkms's words, both installers" {
    local f
    _pin_stubs
    for f in "${INSTALLERS[@]}"; do
        _reset; : > "$T/dkms.noadd"; echo 3.1.20261113-02 > "$T/modver"
        _pin_drv "$f"
        run bash "$T/drv.sh"
        [ "$status" -eq 1 ] || { echo "$f: rc=$status $output"; return 1; }
        grep -qxF 'ERR:   dkms: Error! Bad conf file.' <<<"$output" || { echo "$f: $output"; return 1; }
        ! grep -qE '^build ' "$T/dkms.calls" || { echo "$f: built anyway"; return 1; }
    done
}

@test "step 2: when the old module is already gone, the failure says so, both installers" {
    local f body
    for f in "${INSTALLERS[@]}"; do
        body=$(sed -n '/if ! _install_pinned_awg2_module; then/,/^        fi$/p' "$BATS_TEST_DIRNAME/../$f")
        # shellcheck disable=SC2016  # the literal text of the installer is matched
        grep -qF 'if [[ -n "${_AWG_PIN_DROPPED:-}" ]]; then' <<<"$body" || { echo "$f: no check"; return 1; }
        if _ru "$f"; then
            # shellcheck disable=SC2016
            grep -qF 'Прежний модуль (версия ${_AWG_PIN_DROPPED/#unknown/неизвестна}) уже снят' <<<"$body" || { echo "$f: text"; return 1; }
        else
            # shellcheck disable=SC2016
            grep -qF 'The previous module (version ${_AWG_PIN_DROPPED}) was already removed' <<<"$body" || { echo "$f: text"; return 1; }
        fi
    done
}

@test "RU and EN helpers have the same code" {
    local fn ru en
    for fn in _awg_module_src_version _awg_pin_drop_stale _awg_pin_trial_build _awg_pin_check_built _install_pinned_awg2_module; do
        ru=$(_fn install_amneziawg.sh "$fn" | grep -vE '^[[:space:]]*(#|$)' | grep -vE 'log(_warn|_error)? ')
        en=$(_fn install_amneziawg_en.sh "$fn" | grep -vE '^[[:space:]]*(#|$)' | grep -vE 'log(_warn|_error)? ')
        [ -n "$ru" ] && [ "$ru" = "$en" ] || { echo "$fn differs"; diff <(echo "$ru") <(echo "$en"); return 1; }
    done
}
