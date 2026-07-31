#!/usr/bin/env bats
# v5.23.0 (H0, AmneziaWG 3.0): predicate _kernel_supports_awg3.
#
# Upstream merged AmneziaWG 3.0; the 3.0 module needs kernel >= 6.7 (nla_put_uint).
# On older kernels the installer must route to the pinned 2.0 path. This test pins
# the 6.7 boundary and the parsing of real uname -r strings from our support matrix,
# so moving the threshold is a deliberate edit that updates this test, not a silent
# one.
#
# The function is pure and self-contained - extracted via sed-range and sourced
# (same pattern as apt_update_tolerant in test_apt_tolerant.bats). Descriptions are
# ASCII-only: Cyrillic in bats test names mangles the generated function names.

setup() {
    local installer="${BATS_TEST_DIRNAME}/../install_amneziawg.sh"
    # shellcheck source=/dev/null
    source <(sed -n '/^_kernel_supports_awg3() {$/,/^}$/p' "$installer")
}

# --- supports 3.0 (kernel >= 6.7) ---

@test "6.7.0 supported (exact boundary)" {
    _kernel_supports_awg3 "6.7.0"
}

@test "6.8.0-136-generic supported (Ubuntu 24.04)" {
    _kernel_supports_awg3 "6.8.0-136-generic"
}

@test "6.12.85+deb13-amd64 supported (Debian 13 trixie)" {
    _kernel_supports_awg3 "6.12.85+deb13-amd64"
}

@test "6.17.0-5-generic supported (Ubuntu 25.10)" {
    _kernel_supports_awg3 "6.17.0-5-generic"
}

@test "7.0.0-generic supported (biHetzner or newer)" {
    _kernel_supports_awg3 "7.0.0-generic"
}

@test "10.2.0 supported (major greater than 6)" {
    _kernel_supports_awg3 "10.2.0"
}

@test "6.7 supported (no patch part)" {
    _kernel_supports_awg3 "6.7"
}

# --- NOT supported (kernel < 6.7) -> pinned 2.0 ---

@test "6.1.0-51-amd64 not supported (Debian 12 bookworm)" {
    run _kernel_supports_awg3 "6.1.0-51-amd64"
    [ "$status" -eq 1 ]
}

@test "6.6.99 not supported (lower boundary 6.6.x)" {
    run _kernel_supports_awg3 "6.6.99"
    [ "$status" -eq 1 ]
}

@test "6.6.0 not supported (Raspberry Pi OS bookworm 6.6)" {
    run _kernel_supports_awg3 "6.6.0"
    [ "$status" -eq 1 ]
}

@test "5.15.0-generic not supported (Ubuntu 22.04)" {
    run _kernel_supports_awg3 "5.15.0-generic"
    [ "$status" -eq 1 ]
}

@test "5.4.0 not supported (Ubuntu 20.04)" {
    run _kernel_supports_awg3 "5.4.0"
    [ "$status" -eq 1 ]
}

# --- conservative fallback: unparseable version treated as NOT supported ---

@test "garbage version not supported (safe pinned 2.0)" {
    run _kernel_supports_awg3 "not-a-version"
    [ "$status" -eq 1 ]
}

@test "empty arg parses running uname (does not crash)" {
    run _kernel_supports_awg3
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}
