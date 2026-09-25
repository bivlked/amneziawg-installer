#!/usr/bin/env bats
# Tests for Raspberry Pi kernel header detection in install_amneziawg.sh
# Validates that the correct linux-headers-rpi-* meta-package is selected
# when the exact linux-headers-$(uname -r) package is unavailable.

load test_helper

# The Raspberry Pi choice comes from the installer's own _rpi_headers_pkg
# (sourced below, so this file tests the shipped code, not a copy of it). The
# non-RPi arch fallback is still restated here with an injectable dpkg stub.

# shellcheck source=/dev/null
source <(sed -n '/^_rpi_headers_pkg() {$/,/^}$/p' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")

select_rpi_headers() {
    # Args: $1 = simulated kernel string (e.g. "6.12.75+rpt-rpi-v8")
    local kernel_release="$1"
    if [[ "$kernel_release" == *+rpt* || "$kernel_release" == *-rpi* ]]; then
        _rpi_headers_pkg "$kernel_release"
    else
        echo "linux-headers-$(dpkg --print-architecture 2>/dev/null || echo "amd64")"
    fi
}

@test "rpi headers: Pi 3/4 arm64 rpt kernel selects rpi-v8" {
    result=$(select_rpi_headers "6.12.75+rpt-rpi-v8")
    [ "$result" = "linux-headers-rpi-v8" ]
}

@test "rpi headers: Pi 5 rpt-rpi-2712 kernel selects rpi-2712" {
    result=$(select_rpi_headers "6.12.75+rpt-rpi-2712")
    [ "$result" = "linux-headers-rpi-2712" ]
}

@test "rpi headers: older rpi- suffix kernel selects rpi-v8" {
    result=$(select_rpi_headers "6.6.31-rpi-v8")
    [ "$result" = "linux-headers-rpi-v8" ]
}

@test "rpi headers: non-RPi arm64 debian kernel selects arch package" {
    # Mock dpkg to return arm64 (test may run on x86_64 CI runner)
    dpkg() { echo "arm64"; }
    export -f dpkg
    result=$(select_rpi_headers "6.1.0-28-arm64")
    [ "$result" = "linux-headers-arm64" ]
}

@test "rpi headers: amd64 x86 kernel selects amd64 package" {
    dpkg() { echo "amd64"; }
    export -f dpkg
    result=$(select_rpi_headers "6.1.0-28-amd64")
    [ "$result" = "linux-headers-amd64" ]
}

@test "rpi headers: generic Ubuntu kernel selects arch package" {
    dpkg() { echo "amd64"; }
    export -f dpkg
    result=$(select_rpi_headers "6.8.0-57-generic")
    # Should not match RPi pattern
    [[ "$result" != *rpi* ]]
}
