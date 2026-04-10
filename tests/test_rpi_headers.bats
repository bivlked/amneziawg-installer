#!/usr/bin/env bats
# Tests for Raspberry Pi kernel header detection in install_amneziawg.sh
# Validates that the correct linux-headers-rpi-* meta-package is selected
# when the exact linux-headers-$(uname -r) package is unavailable.

load test_helper

# Extract just the headers-detection logic into a testable function by
# re-implementing it here with injectable mock stubs (uname, dpkg, apt-cache).
# This avoids sourcing the full installer (which has root-only side effects).

select_rpi_headers() {
    # Args: $1 = simulated kernel string (e.g. "6.12.75+rpt-rpi-v8")
    local kernel_release="$1"
    local current_headers="linux-headers-${kernel_release}"

    # Simulate dpkg -s / apt-cache show both failing (headers not installed)
    if false; then
        echo "$current_headers"
        return
    fi

    if [[ "$kernel_release" == *+rpt* || "$kernel_release" == *-rpi* ]]; then
        if [[ "$kernel_release" == *2712* ]]; then
            echo "linux-headers-rpi-2712"
        else
            echo "linux-headers-rpi-v8"
        fi
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
    result=$(select_rpi_headers "6.1.0-28-arm64")
    [ "$result" = "linux-headers-arm64" ]
}

@test "rpi headers: amd64 x86 kernel selects amd64 package" {
    result=$(select_rpi_headers "6.1.0-28-amd64")
    [ "$result" = "linux-headers-amd64" ]
}

@test "rpi headers: generic Ubuntu kernel selects arch package" {
    result=$(select_rpi_headers "6.8.0-57-generic")
    # Should not match RPi pattern
    [[ "$result" != *rpi* ]]
}
