#!/usr/bin/env bats
# ARM prebuilts move from the pinned 2.0 tag to the 3.1 line with the vendor fix
# for amneziawg-linux-kernel-module#233 (tag v3.1.20261113-02).
#
# Two things the build has to get right:
# 1. The version. The upstream src/Makefile sets WIREGUARD_VERSION = 1.0.0 and
#    hands it to Kbuild, which overrides src/version.h, so a `make -C src` build
#    reported "1.0.0" for both lines (DKMS from the PPA builds through Kbuild and
#    reports the real one). check/diagnose decide whether the #233 fix is present
#    by that version, so the build passes the version.h value explicitly and
#    refuses a module that reports anything else.
# 2. No step back. A manual workflow_dispatch ref wins over the pin and the
#    workflow overwrites the shared assets, so the build refuses a source without
#    the fix instead of publishing it under the same names.

bats_require_minimum_version 1.5.0

setup() {
    TEST_DIR=$(mktemp -d)
    unset MODULE_VERSION
    # shellcheck source=../scripts/build-arm-deb.sh
    source "$BATS_TEST_DIRNAME/../scripts/build-arm-deb.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

version_h() {
    mkdir -p "$TEST_DIR/src"
    printf '%s\n' '#ifndef WIREGUARD_VERSION' "#define WIREGUARD_VERSION \"$1\"" '#endif' > "$TEST_DIR/src/version.h"
}

@test "the version comes from src/version.h" {
    version_h "3.1.20261113-02"
    run _arm_module_version_h "$TEST_DIR/src"
    [ "$status" -eq 0 ]
    [ "$output" = "3.1.20261113-02" ]
}

@test "a source without version.h is a build error, not an empty version" {
    mkdir -p "$TEST_DIR/src"
    run --separate-stderr _arm_module_version_h "$TEST_DIR/src"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"version.h not found"* ]]
}

@test "a version.h without the define is a build error" {
    mkdir -p "$TEST_DIR/src"
    printf '%s\n' '/* nothing here */' > "$TEST_DIR/src/version.h"
    run _arm_module_version_h "$TEST_DIR/src"
    [ "$status" -ne 0 ]
}

@test "the build passes the version.h value to make" {
    make() { printf '%s\n' "$@" > "$TEST_DIR/make.args"; }
    _arm_build_module "$TEST_DIR/src" "6.8.0-149-generic" "3.1.20261113-02"
    grep -qxF -- '-C' "$TEST_DIR/make.args"
    grep -qxF -- "$TEST_DIR/src" "$TEST_DIR/make.args"
    grep -qxF -- 'KERNELRELEASE=6.8.0-149-generic' "$TEST_DIR/make.args"
    grep -qxF -- 'KERNELDIR=/lib/modules/6.8.0-149-generic/build' "$TEST_DIR/make.args"
    grep -qxF -- 'WIREGUARD_VERSION=3.1.20261113-02' "$TEST_DIR/make.args"
    grep -qxF -- 'module' "$TEST_DIR/make.args"
}

@test "a failed make fails the build step" {
    make() { return 2; }
    run _arm_build_module "$TEST_DIR/src" "6.8.0-149-generic" "3.1.20261113-02"
    [ "$status" -ne 0 ]
}

@test "the built module must report exactly the version.h value" {
    run _arm_check_built_version "3.1.20261113-02" $'filename: x\nversion:        3.1.20261113-02\nvermagic: y'
    [ "$status" -eq 0 ]
    run _arm_check_built_version "3.1.20261113-02" $'filename: x\nversion:        1.0.0\nvermagic: y'
    [ "$status" -ne 0 ]
    [[ "$output" == *"1.0.0"* ]]
    [[ "$output" == *"3.1.20261113-02"* ]]
    run _arm_check_built_version "3.1.20261113-02" $'filename: x\nvermagic: y'
    [ "$status" -ne 0 ]
}

@test "only a source with the #233 fix may be published" {
    for v in 3.1.20261113-02 3.1.20261113-10 3.1.20261201 3.2.20270101 4.0.20270301; do
        run _arm_version_has_233_fix "$v"
        [ "$status" -eq 0 ] || { echo "refused fixed $v"; false; }
    done
    for v in 3.1.20261113 3.1.20261113-01 3.1.20260906 3.0.20260731-04 1.0.20260725 1.0.0 "" garbage; do
        run _arm_version_has_233_fix "$v"
        [ "$status" -ne 0 ] || { echo "accepted unfixed $v"; false; }
    done
}

@test "the build boundary agrees with the one check and diagnose use" {
    # check/diagnose (awg_common.sh) and the ARM build must call the same
    # versions fixed, or a published prebuilt would still get the warning.
    # shellcheck source=../awg_common.sh
    eval "$(sed -n '/^_awg_kmod_has_233_fix()/,/^}/p' "$BATS_TEST_DIRNAME/../awg_common.sh")"
    declare -F _awg_kmod_has_233_fix >/dev/null
    for v in 3.1.20261113-02 3.1.20261113-01 3.1.20261113 3.1.20261114 3.0.20261201 2.9.20270101 4.0.20261113-03 1.0.0; do
        a=0; b=0
        _arm_version_has_233_fix "$v" || a=1
        _awg_kmod_has_233_fix "$v" || b=1
        [ "$a" = "$b" ] || { echo "disagree on $v: build=$a check=$b"; false; }
    done
}

@test "the shipped pin is a fixed 3.1 tag" {
    run grep -vE '^[[:space:]]*(#|$)' "$BATS_TEST_DIRNAME/../scripts/arm-module-version.txt"
    [ "$status" -eq 0 ]
    pin=$(printf '%s\n' "$output" | head -n1 | tr -d '[:space:]')
    [ "$pin" = "v3.1.20261113-02" ]
    run _arm_version_has_233_fix "${pin#v}"
    [ "$status" -eq 0 ]
}
