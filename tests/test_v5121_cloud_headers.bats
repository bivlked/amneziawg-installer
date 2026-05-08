#!/usr/bin/env bats
# v5.12.1 cloud-headers fallback in awg_common._install_kernel_headers().
#
# Background: installer's step 2 has smart kernel-headers detection that
# already picks linux-headers-cloud-${arch} on Debian cloud kernels. The
# repair-module path uses the shared awg_common.sh helper, which previously
# only tried linux-headers-${kernel_ver} and linux-headers-${arch}.
# When the exact-version package vanishes from the mirror after a kernel
# upgrade — common on AWS/Azure/GCP/cloud-Hetzner — repair-module fell
# through, even though linux-headers-cloud-${arch} was available.
#
# Fix: when the running kernel is a Debian cloud build (`*-cloud-*`),
# add linux-headers-cloud-${arch} into the candidate list before the
# generic linux-headers-${arch}.

load test_helper

setup() {
    TEST_DIR=$(mktemp -d)
    export AWG_DIR="$TEST_DIR"
    export MOCK_BIN="$TEST_DIR/mock_bin"
    mkdir -p "$MOCK_BIN"
    export PATH="$MOCK_BIN:$PATH"

    # Silent log stubs for clean test output.
    log()       { :; }
    log_warn()  { :; }
    log_error() { :; }
    log_debug() { :; }
    export -f log log_warn log_error log_debug

    # Mock apt-get: always fail to install, but record each requested pkg
    # in CALLS_LOG. This lets us assert the candidate order without needing
    # any real apt repository.
    cat > "$MOCK_BIN/apt-get" << 'STUB'
#!/bin/bash
# Args: install -y <pkg>  → log pkg, exit 1 (simulate "not found")
if [[ "$1" == "install" ]]; then
    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|-q|--no-install-recommends) shift ;;
            *) echo "$1" >> "${AWG_DIR}/.apt_calls"; shift ;;
        esac
    done
fi
exit 1
STUB
    chmod +x "$MOCK_BIN/apt-get"

    # Mock dpkg --print-architecture to return our chosen arch.
    cat > "$MOCK_BIN/dpkg" << 'STUB'
#!/bin/bash
if [[ "$1" == "--print-architecture" ]]; then
    echo "${MOCK_ARCH:-amd64}"
fi
exit 0
STUB
    chmod +x "$MOCK_BIN/dpkg"

    # Required gate: this function refuses to call apt without it.
    export AWG_ALLOW_APT_IN_ENSURE=1

    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../awg_common.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

# ---------- standard (non-cloud) kernel: cloud meta NOT in candidates ----------

@test "v5.12.1: Debian arm64 standard kernel does not request linux-headers-cloud-arm64" {
    export OS_ID=debian
    export MOCK_ARCH=arm64
    run _install_kernel_headers "6.12.85+deb13-arm64"
    [ "$status" -eq 1 ]
    [ -f "$AWG_DIR/.apt_calls" ]
    grep -q "linux-headers-6.12.85+deb13-arm64" "$AWG_DIR/.apt_calls"
    grep -q "linux-headers-arm64" "$AWG_DIR/.apt_calls"
    ! grep -q "linux-headers-cloud-arm64" "$AWG_DIR/.apt_calls"
}

@test "v5.12.1: Debian amd64 standard kernel does not request linux-headers-cloud-amd64" {
    export OS_ID=debian
    export MOCK_ARCH=amd64
    run _install_kernel_headers "6.1.0-28-amd64"
    [ "$status" -eq 1 ]
    grep -q "linux-headers-amd64" "$AWG_DIR/.apt_calls"
    ! grep -q "linux-headers-cloud-amd64" "$AWG_DIR/.apt_calls"
}

# ---------- cloud kernel: cloud meta in candidates, BEFORE generic ----------

@test "v5.12.1: Debian amd64 cloud kernel adds linux-headers-cloud-amd64 fallback" {
    export OS_ID=debian
    export MOCK_ARCH=amd64
    run _install_kernel_headers "6.1.0-22-cloud-amd64"
    [ "$status" -eq 1 ]
    grep -q "linux-headers-cloud-amd64" "$AWG_DIR/.apt_calls"
}

@test "v5.12.1: Debian arm64 cloud kernel adds linux-headers-cloud-arm64 fallback" {
    export OS_ID=debian
    export MOCK_ARCH=arm64
    run _install_kernel_headers "6.5.0-15-cloud-arm64"
    [ "$status" -eq 1 ]
    grep -q "linux-headers-cloud-arm64" "$AWG_DIR/.apt_calls"
}

@test "v5.12.1: Debian cloud kernel: cloud meta tried before generic arch meta" {
    export OS_ID=debian
    export MOCK_ARCH=amd64
    run _install_kernel_headers "6.1.0-22-cloud-amd64"
    [ "$status" -eq 1 ]
    # Order check: cloud line precedes the generic one.
    cloud_line=$(grep -n "^linux-headers-cloud-amd64$" "$AWG_DIR/.apt_calls" | head -1 | cut -d: -f1)
    generic_line=$(grep -n "^linux-headers-amd64$" "$AWG_DIR/.apt_calls" | head -1 | cut -d: -f1)
    [ -n "$cloud_line" ]
    [ -n "$generic_line" ]
    [ "$cloud_line" -lt "$generic_line" ]
}

# ---------- candidate set sanity (non-regression for existing behaviour) ----------

@test "v5.12.1: Debian still tries exact kernel_ver first" {
    export OS_ID=debian
    export MOCK_ARCH=amd64
    run _install_kernel_headers "6.1.0-22-cloud-amd64"
    first=$(head -1 "$AWG_DIR/.apt_calls")
    [ "$first" = "linux-headers-6.1.0-22-cloud-amd64" ]
}

@test "v5.12.1: Ubuntu codepath unaffected by Debian cloud branch" {
    export OS_ID=ubuntu
    export MOCK_ARCH=amd64
    run _install_kernel_headers "6.8.0-57-generic"
    [ "$status" -eq 1 ]
    grep -q "linux-headers-6.8.0-57-generic" "$AWG_DIR/.apt_calls"
    grep -q "linux-headers-generic" "$AWG_DIR/.apt_calls"
    ! grep -q "linux-headers-cloud-" "$AWG_DIR/.apt_calls"
}

# ---------- EN mirror: same behaviour from awg_common_en.sh ----------
#
# The shared helper exists in both awg_common.sh (RU log strings) and
# awg_common_en.sh (EN log strings). The kernel-headers logic is identical
# byte-for-byte; this guard catches the case where someone updates only one.

@test "v5.12.1: EN mirror Debian cloud kernel adds linux-headers-cloud-amd64" {
    # Re-source the EN helper into a fresh subshell so we don't pollute the
    # already-loaded RU functions in this test file.
    rm -f "$AWG_DIR/.apt_calls"
    (
        export AWG_ALLOW_APT_IN_ENSURE=1 OS_ID=debian MOCK_ARCH=amd64
        # shellcheck disable=SC1091
        source "$BATS_TEST_DIRNAME/../awg_common_en.sh"
        _install_kernel_headers "6.1.0-22-cloud-amd64" || true
    )
    [ -f "$AWG_DIR/.apt_calls" ]
    grep -q "linux-headers-cloud-amd64" "$AWG_DIR/.apt_calls"
}

@test "v5.12.1: EN mirror Debian standard kernel does NOT add cloud meta" {
    rm -f "$AWG_DIR/.apt_calls"
    (
        export AWG_ALLOW_APT_IN_ENSURE=1 OS_ID=debian MOCK_ARCH=arm64
        # shellcheck disable=SC1091
        source "$BATS_TEST_DIRNAME/../awg_common_en.sh"
        _install_kernel_headers "6.12.85+deb13-arm64" || true
    )
    [ -f "$AWG_DIR/.apt_calls" ]
    ! grep -q "linux-headers-cloud-arm64" "$AWG_DIR/.apt_calls"
}
