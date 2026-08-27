#!/usr/bin/env bats
# Tests for _resolve_kernel_version in scripts/build-arm-deb.sh (v5.14.2).
#
# Background: external code review on 8 may 2026 flagged that the original
# loop silently picked the FIRST /lib/modules/*/build candidate, which on
# developer hosts with multiple installed kernels resulted in building
# against an unintended target. In CI matrix this never triggers (one QEMU
# container = one headers package), but defensive behaviour is required.
#
# Fix: KERNEL_VERSION env honoured when set (must point at an existing build dir).
# Otherwise: 0 candidates → fail (unchanged); 1 candidate → use it (unchanged);
# 2+ candidates → fail with explicit list, ask caller to set KERNEL_VERSION.

# Required for `run !` flag (used in negation tests). Suppresses bats BW02 warning.
bats_require_minimum_version 1.5.0

setup() {
    TEST_DIR=$(mktemp -d)
    MODULES_ROOT="$TEST_DIR/lib/modules"
    mkdir -p "$MODULES_ROOT"
    # Sourcing the script must NOT execute its main body (we want the function).
    # Top of the script does `(return 0 2>/dev/null) && return 0` after defining
    # _resolve_kernel_version, so sourcing exits cleanly when invoked from bats.
    # We unset KERNEL_VERSION between tests because env leaks across them.
    unset KERNEL_VERSION
    source "$BATS_TEST_DIRNAME/../scripts/build-arm-deb.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
    unset KERNEL_VERSION
}

# --- Auto-detection paths ---

@test "_resolve_kernel_version: returns the single candidate when exactly one exists" {
    mkdir -p "$MODULES_ROOT/6.12.5-rpi/build"

    run _resolve_kernel_version "$MODULES_ROOT"
    [ "$status" -eq 0 ]
    [ "$output" = "6.12.5-rpi" ]
}

@test "_resolve_kernel_version: fails with code 1 when no candidates exist" {
    run _resolve_kernel_version "$MODULES_ROOT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"No kernel build directory found"* ]]
}

@test "_resolve_kernel_version: fails with code 1 on multiple candidates and lists them all" {
    mkdir -p "$MODULES_ROOT/6.1.0-rpi-v8/build"
    mkdir -p "$MODULES_ROOT/6.12.5-rpi-2712/build"
    mkdir -p "$MODULES_ROOT/6.14.0-azure/build"

    run _resolve_kernel_version "$MODULES_ROOT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Multiple kernel build directories"* ]]
    [[ "$output" == *"6.1.0-rpi-v8"* ]]
    [[ "$output" == *"6.12.5-rpi-2712"* ]]
    [[ "$output" == *"6.14.0-azure"* ]]
    [[ "$output" == *"Set KERNEL_VERSION env"* ]]
}

@test "_resolve_kernel_version: ignores subdirs without a build subdir (e.g. removed kernels)" {
    # Some /lib/modules/<ver>/ have no build symlink when headers were uninstalled.
    mkdir -p "$MODULES_ROOT/6.5.0-leftover"    # no build/
    mkdir -p "$MODULES_ROOT/6.12.5-active/build"

    run _resolve_kernel_version "$MODULES_ROOT"
    [ "$status" -eq 0 ]
    [ "$output" = "6.12.5-active" ]
}

# --- KERNEL_VERSION env path ---

@test "_resolve_kernel_version: honours KERNEL_VERSION env when set and dir exists" {
    mkdir -p "$MODULES_ROOT/6.1.0-rpi/build"
    mkdir -p "$MODULES_ROOT/6.12.5-rpi/build"
    KERNEL_VERSION="6.12.5-rpi"

    run _resolve_kernel_version "$MODULES_ROOT"
    [ "$status" -eq 0 ]
    [ "$output" = "6.12.5-rpi" ]
}

@test "_resolve_kernel_version: KERNEL_VERSION disambiguates when multiple candidates exist" {
    mkdir -p "$MODULES_ROOT/6.1.0-rpi-v8/build"
    mkdir -p "$MODULES_ROOT/6.12.5-rpi-2712/build"
    KERNEL_VERSION="6.12.5-rpi-2712"

    run _resolve_kernel_version "$MODULES_ROOT"
    [ "$status" -eq 0 ]
    [ "$output" = "6.12.5-rpi-2712" ]
}

@test "_resolve_kernel_version: fails when KERNEL_VERSION set but target dir missing" {
    mkdir -p "$MODULES_ROOT/6.12.5-rpi/build"
    KERNEL_VERSION="6.99.0-nonexistent"

    run _resolve_kernel_version "$MODULES_ROOT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"KERNEL_VERSION='6.99.0-nonexistent'"* ]]
    [[ "$output" == *"does not exist"* ]]
}

@test "_resolve_kernel_version: empty KERNEL_VERSION falls back to auto-detect" {
    mkdir -p "$MODULES_ROOT/6.12.5-rpi/build"
    # The helper reads KERNEL_VERSION via ${KERNEL_VERSION:-}, shellcheck cannot
    # see that cross-function flow and flags this as unused (SC2034).
    # shellcheck disable=SC2034
    KERNEL_VERSION=""

    run _resolve_kernel_version "$MODULES_ROOT"
    [ "$status" -eq 0 ]
    [ "$output" = "6.12.5-rpi" ]
}

# --- Structural / source guard ---

@test "structural: build-arm-deb.sh defines _resolve_kernel_version function" {
    local FILE="$BATS_TEST_DIRNAME/../scripts/build-arm-deb.sh"
    grep -qE '^_resolve_kernel_version\(\) \{' "$FILE"
}

@test "structural: build-arm-deb.sh has source-guard so sourcing skips main body" {
    local FILE="$BATS_TEST_DIRNAME/../scripts/build-arm-deb.sh"
    # The guard must use (return ... 2>/dev/null) - that builtin succeeds only
    # when the file is being sourced. If absent, sourcing would try to clone
    # the upstream kernel module repo, which is forbidden in unit tests.
    grep -qE '\(return 0 2>/dev/null\) && return 0' "$FILE"
}

@test "structural: main body uses _resolve_kernel_version (no inline detection loop)" {
    local FILE="$BATS_TEST_DIRNAME/../scripts/build-arm-deb.sh"
    # Inline pre-fix pattern: bare `for _d in /lib/modules/*/build; do`.
    # In Bats a bare `! grep` does NOT fail the test (SC2314); use `run !`
    # (bats >= 1.5.0) so the negated exit status actually fails the test.
    run ! grep -qE '^for _d in /lib/modules/\*/build' "$FILE"
    # New invocation: KERNEL_VERSION="$(_resolve_kernel_version /lib/modules)" somewhere.
    grep -qE 'KERNEL_VERSION="\$\(_resolve_kernel_version /lib/modules\)"' "$FILE"
}
