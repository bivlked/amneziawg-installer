#!/usr/bin/env bats
# The pinned module path (a kernel older than 6.7 with no prebuilt, for example
# Debian 12 on its stock 6.1) builds the module from the 3.1 tag that carries the
# fix for amneziawg-linux-kernel-module#233, while the profile stays 2.0. It used
# to build the 2.0 tag v1.0.20260725, which has no fix.
#
# Both trees land in /usr/src/amneziawg-1.0.0 (the vendor Makefile names the DKMS
# version 1.0.0 on every line), so a server that already has the 2.0 build would
# keep it on a rerun: DKMS sees "already built for this kernel" and installs the
# old module again. The installer therefore drops a source of another version
# before laying out the new one, and after the build checks the version the
# module reports.
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
# stubs, the function and the helpers it calls, and calls the function with the
# script's arguments.
_drv() {
    local f="$1" fn="$2" h; shift 2
    {
        echo 'log() { echo "LOG: $*"; }; log_warn() { echo "WARN: $*"; }; log_error() { echo "ERR: $*"; }'
        for h in "$@"; do _fn "$f" "$h"; done
        _fn "$f" "$fn"
        echo "$fn"' "$@"'
    } > "$T/drv.sh"
}

_vh() { printf '#ifndef WIREGUARD_VERSION\n#define WIREGUARD_VERSION "%s"\n#endif\n' "$2" > "$1"; }

@test "pin: both installers point at the 3.1 tag with the #233 fix and its commit" {
    local f
    for f in "${INSTALLERS[@]}"; do
        grep -qxF 'AWG2_PIN_TAG="v3.1.20261113-02"' "$BATS_TEST_DIRNAME/../$f" || { echo "$f: tag"; return 1; }
        grep -qxF 'AWG2_PIN_COMMIT="63ed35de3d3f135b17e8eae0b84949e7700303be"' "$BATS_TEST_DIRNAME/../$f" || { echo "$f: commit"; return 1; }
    done
}

@test "pin: the shipped tag is one the #233 boundary in check counts as fixed" {
    # The same boundary check uses (awg_common): a pin outside it would put back a
    # module that check keeps warning about.
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
    done
}

@test "src version: no file or no define is a failure with empty output, both installers" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _drv "$f" _awg_module_src_version
        run bash "$T/drv.sh" "$T/missing.h"
        [ "$status" -eq 1 ] && [ -z "$output" ] || { echo "$f missing: rc=$status '$output'"; return 1; }
        printf '#define OTHER "1"\n' > "$T/v.h"
        run bash "$T/drv.sh" "$T/v.h"
        [ "$status" -eq 1 ] && [ -z "$output" ] || { echo "$f no define: rc=$status '$output'"; return 1; }
        printf '#define WIREGUARD_VERSION "1.0$(id)"\n' > "$T/v.h"
        run bash "$T/drv.sh" "$T/v.h"
        [ "$status" -eq 1 ] && [ -z "$output" ] || { echo "$f odd value: rc=$status '$output'"; return 1; }
    done
}

# dkms stub: "status" prints $T/dkms.status (empty when there is none); any
# other command is recorded in $T/dkms.calls and exits with $T/dkms.rc.
_dkms_stub() { _stub dkms 'if [ "$1" = status ]; then cat "$T/dkms.status" 2>/dev/null; exit 0; fi
echo "$*" >> "$T/dkms.calls"; exit "$(cat "$T/dkms.rc" 2>/dev/null || echo 0)"'; }

@test "stale source: a source of another version is unregistered and removed, both installers" {
    local f
    _dkms_stub
    for f in "${INSTALLERS[@]}"; do
        rm -f "$T/dkms.calls"; mkdir -p "$T/src/amneziawg-1.0.0"; _vh "$T/src/amneziawg-1.0.0/version.h" 1.0.20260725
        : > "$T/src/amneziawg-1.0.0/old.c"
        _drv "$f" _awg_pin_drop_stale _awg_module_src_version
        run bash "$T/drv.sh" "$T/src/amneziawg-1.0.0" 3.1.20261113-02 1.0.0
        [ "$status" -eq 0 ] || { echo "$f: rc=$status $output"; return 1; }
        [ ! -e "$T/src/amneziawg-1.0.0" ] || { echo "$f: the old source stayed"; return 1; }
        grep -qxF 'remove -m amneziawg -v 1.0.0 --all' "$T/dkms.calls" || { echo "$f: dkms: $(cat "$T/dkms.calls" 2>/dev/null)"; return 1; }
        [[ "$output" == *"1.0.20260725"* && "$output" == *"3.1.20261113-02"* ]] || { echo "$f: versions not named: $output"; return 1; }
    done
}

@test "stale source: the same version is left alone, both installers" {
    local f
    _dkms_stub
    for f in "${INSTALLERS[@]}"; do
        rm -f "$T/dkms.calls"; mkdir -p "$T/src/amneziawg-1.0.0"; _vh "$T/src/amneziawg-1.0.0/version.h" 3.1.20261113-02
        _drv "$f" _awg_pin_drop_stale _awg_module_src_version
        run bash "$T/drv.sh" "$T/src/amneziawg-1.0.0" 3.1.20261113-02 1.0.0
        [ "$status" -eq 0 ] || { echo "$f: rc=$status $output"; return 1; }
        [ -f "$T/src/amneziawg-1.0.0/version.h" ] || { echo "$f: the source was removed"; return 1; }
        [ ! -e "$T/dkms.calls" ] || { echo "$f: dkms called: $(cat "$T/dkms.calls")"; return 1; }
        [ -z "$output" ] || { echo "$f: said something: $output"; return 1; }
    done
}

@test "stale source: no source at all is not an error and calls nothing, both installers" {
    local f
    _dkms_stub
    for f in "${INSTALLERS[@]}"; do
        rm -f "$T/dkms.calls"; rm -rf "$T/src"
        _drv "$f" _awg_pin_drop_stale _awg_module_src_version
        run bash "$T/drv.sh" "$T/src/amneziawg-1.0.0" 3.1.20261113-02 1.0.0
        [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$f: rc=$status $output"; return 1; }
        [ ! -e "$T/dkms.calls" ] || { echo "$f: dkms called"; return 1; }
    done
}

@test "stale source: a source without a readable version counts as another version, both installers" {
    local f
    _dkms_stub
    for f in "${INSTALLERS[@]}"; do
        rm -f "$T/dkms.calls"; mkdir -p "$T/src/amneziawg-1.0.0"; : > "$T/src/amneziawg-1.0.0/dkms.conf"
        _drv "$f" _awg_pin_drop_stale _awg_module_src_version
        run bash "$T/drv.sh" "$T/src/amneziawg-1.0.0" 3.1.20261113-02 1.0.0
        [ "$status" -eq 0 ] || { echo "$f: rc=$status $output"; return 1; }
        [ ! -e "$T/src/amneziawg-1.0.0" ] || { echo "$f: stayed"; return 1; }
        grep -qxF 'remove -m amneziawg -v 1.0.0 --all' "$T/dkms.calls" || { echo "$f: no dkms remove"; return 1; }
    done
}

@test "stale source: a failed dkms remove with nothing left registered still goes on, both installers" {
    # dkms remove also fails when the module was never registered; what matters
    # is whether a build is still registered afterwards.
    local f
    _dkms_stub; echo 3 > "$T/dkms.rc"
    for f in "${INSTALLERS[@]}"; do
        mkdir -p "$T/src/amneziawg-1.0.0"; _vh "$T/src/amneziawg-1.0.0/version.h" 1.0.20260725
        _drv "$f" _awg_pin_drop_stale _awg_module_src_version
        run bash "$T/drv.sh" "$T/src/amneziawg-1.0.0" 3.1.20261113-02 1.0.0
        [ "$status" -eq 0 ] || { echo "$f: rc=$status $output"; return 1; }
        [ ! -e "$T/src/amneziawg-1.0.0" ] || { echo "$f: stayed"; return 1; }
        [[ "$output" != *ERR:* ]] || { echo "$f: $output"; return 1; }
    done
}

@test "stale source: an old build still registered after dkms remove stops before the source is touched, both installers" {
    # Otherwise the new version.h would hide the old build from the next run:
    # the cleanup would be skipped, DKMS would report the old build as built,
    # and the old module would be installed again.
    local f
    _dkms_stub; echo 3 > "$T/dkms.rc"
    echo 'amneziawg/1.0.0, 6.1.0-56-amd64, x86_64: installed' > "$T/dkms.status"
    for f in "${INSTALLERS[@]}"; do
        mkdir -p "$T/src/amneziawg-1.0.0"; _vh "$T/src/amneziawg-1.0.0/version.h" 1.0.20260725
        _drv "$f" _awg_pin_drop_stale _awg_module_src_version
        run bash "$T/drv.sh" "$T/src/amneziawg-1.0.0" 3.1.20261113-02 1.0.0
        [ "$status" -eq 1 ] || { echo "$f: rc=$status $output"; return 1; }
        grep -qF '1.0.20260725' "$T/src/amneziawg-1.0.0/version.h" || { echo "$f: the old source was touched"; return 1; }
        [[ "$output" == *ERR:*"dkms"* ]] || { echo "$f: not loud: $output"; return 1; }
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

# modinfo stub: "-k <kver> -F version amneziawg" prints $T/modver; anything else fails.
_modinfo_stub() { _stub modinfo '[ "$1" = -k ] && [ "$3" = -F ] && [ "$4" = version ] && [ "$5" = amneziawg ] || exit 2
echo "$2" > "$T/modinfo.k"
[ -f "$T/modver" ] || exit 1
cat "$T/modver"'; }

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

@test "pinned build: the new steps run in order inside _install_pinned_awg2_module, both installers" {
    local f body a b c d
    for f in "${INSTALLERS[@]}"; do
        body=$(_fn "$f" _install_pinned_awg2_module)
        a=$(grep -n -m1 'want_ver=$(_awg_module_src_version "$work/src/src/version.h")' <<<"$body" | cut -d: -f1)
        b=$(grep -n -m1 '_awg_pin_drop_stale "/usr/src/amneziawg-${dkms_ver}" "$want_ver" "$dkms_ver"' <<<"$body" | cut -d: -f1)
        c=$(grep -n -m1 'make -C "$work/src/src" dkms-install' <<<"$body" | cut -d: -f1)
        d=$(grep -n -m1 '_awg_pin_check_built "$kver" "$want_ver"' <<<"$body" | cut -d: -f1)
        [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ -n "$d" ] || { echo "$f: a=$a b=$b c=$c d=$d"; return 1; }
        [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && [ "$c" -lt "$d" ] || { echo "$f: order a=$a b=$b c=$c d=$d"; return 1; }
    done
}

@test "RU and EN helpers have the same code" {
    local fn ru en
    for fn in _awg_module_src_version _awg_pin_drop_stale _awg_pin_check_built; do
        ru=$(_fn install_amneziawg.sh "$fn" | grep -vE '^[[:space:]]*(#|$)' | grep -vE 'log(_warn|_error)? ')
        en=$(_fn install_amneziawg_en.sh "$fn" | grep -vE '^[[:space:]]*(#|$)' | grep -vE 'log(_warn|_error)? ')
        [ -n "$ru" ] && [ "$ru" = "$en" ] || { echo "$fn differs"; diff <(echo "$ru") <(echo "$en"); return 1; }
    done
}
