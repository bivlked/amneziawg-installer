#!/usr/bin/env bats
# Tests for ARM prebuilt CI matrix + installer target_id mappings (v5.11 Phase 5 / A7.2).
#
# Invariants:
#   • arm-build.yml matrix contains entries for every OS listed in install
#     supported-OS check.
#   • install_amneziawg.sh _try_install_prebuilt_arm target_id strings match
#     the matrix `id:` fields (otherwise installer downloads 404 assets).
#   • Dropped OS (22.04; 25.10 since v6.0.0, past vendor support) is absent
#     from both workflow and installer mapping.

setup() {
    WF="${BATS_TEST_DIRNAME}/../.github/workflows/arm-build.yml"
    INSTALL_RU="${BATS_TEST_DIRNAME}/../install_amneziawg.sh"
    INSTALL_EN="${BATS_TEST_DIRNAME}/../install_amneziawg_en.sh"
    [ -f "$WF" ]         || { echo "arm-build.yml missing" >&2; return 1; }
    [ -f "$INSTALL_RU" ] || { echo "install_amneziawg.sh missing" >&2; return 1; }
    [ -f "$INSTALL_EN" ] || { echo "install_amneziawg_en.sh missing" >&2; return 1; }
}

# -------------------------------------------------------------------------
# arm-build.yml matrix coverage (A7.2)
# -------------------------------------------------------------------------

@test "arm-build.yml dropped Ubuntu 25.10 entry (past vendor support since 2026-07-01)" {
    run grep -qE 'ubuntu-2510-arm64' "$WF"; [ "$status" -ne 0 ]
    run grep -qE 'image: ubuntu:25\.10' "$WF"; [ "$status" -ne 0 ]
}

@test "arm-build.yml has debian-trixie-arm64 matrix entry (Debian 13)" {
    grep -qE 'id: debian-trixie-arm64' "$WF"
    grep -qE 'image: debian:trixie' "$WF"
}

@test "arm-build.yml keeps ubuntu-2404-arm64 (LTS, still supported)" {
    grep -qE 'id: ubuntu-2404-arm64' "$WF"
    grep -qE 'image: ubuntu:24\.04' "$WF"
}

@test "arm-build.yml keeps debian-bookworm-arm64 (Debian 12, still supported)" {
    grep -qE 'id: debian-bookworm-arm64' "$WF"
    grep -qE 'image: debian:bookworm' "$WF"
}

@test "arm-build.yml keeps the 3 Raspberry Pi entries" {
    grep -qE 'id: rpi-bookworm-arm64' "$WF"
    grep -qE 'id: rpi5-bookworm-arm64' "$WF"
    grep -qE 'id: rpi-bookworm-armhf' "$WF"
}

@test "arm-build.yml dropped Ubuntu 22.04 entry (no longer in supported list)" {
    run grep -qE 'ubuntu-2204-arm64' "$WF"; [ "$status" -ne 0 ]
    run grep -qE 'image: ubuntu:22\.04' "$WF"; [ "$status" -ne 0 ]
}

# -------------------------------------------------------------------------
# install_amneziawg.sh target_id mapping (A7.2)
# -------------------------------------------------------------------------

@test "install_amneziawg.sh no longer maps 25.10 -> ubuntu-2510" {
    local body
    body=$(awk '/^_try_install_prebuilt_arm\(\) \{$/,/^}$/' "$INSTALL_RU")
    [ -n "$body" ]
    run grep -qE 'ubuntu-2510-arm64' <<< "$body"; [ "$status" -ne 0 ]
    run grep -qE 'OS_VERSION.*"25\.10"' <<< "$body"; [ "$status" -ne 0 ]
}

@test "install_amneziawg_en.sh no longer maps 25.10 -> ubuntu-2510" {
    local body
    body=$(awk '/^_try_install_prebuilt_arm\(\) \{$/,/^}$/' "$INSTALL_EN")
    [ -n "$body" ]
    run grep -qE 'ubuntu-2510-arm64' <<< "$body"; [ "$status" -ne 0 ]
    run grep -qE 'OS_VERSION.*"25\.10"' <<< "$body"; [ "$status" -ne 0 ]
}

@test "install_amneziawg.sh maps Debian 13 -> debian-trixie-arm64" {
    awk '/^_try_install_prebuilt_arm\(\) \{$/,/^}$/' "$INSTALL_RU" | \
        grep -A1 'OS_VERSION.*"13"' | grep -qE 'target_id="debian-trixie-arm64"'
}

@test "install_amneziawg_en.sh maps Debian 13 -> debian-trixie-arm64" {
    awk '/^_try_install_prebuilt_arm\(\) \{$/,/^}$/' "$INSTALL_EN" | \
        grep -A1 'OS_VERSION.*"13"' | grep -qE 'target_id="debian-trixie-arm64"'
}

@test "install_amneziawg.sh no longer maps 22.04 -> ubuntu-2204" {
    local body
    body=$(awk '/^_try_install_prebuilt_arm\(\) \{$/,/^}$/' "$INSTALL_RU")
    run grep -qE 'target_id="ubuntu-2204-arm64"' <<< "$body"; [ "$status" -ne 0 ]
    run grep -qE 'OS_VERSION.*"22\.04"' <<< "$body"; [ "$status" -ne 0 ]
}

@test "install_amneziawg_en.sh no longer maps 22.04 -> ubuntu-2204" {
    local body
    body=$(awk '/^_try_install_prebuilt_arm\(\) \{$/,/^}$/' "$INSTALL_EN")
    run grep -qE 'target_id="ubuntu-2204-arm64"' <<< "$body"; [ "$status" -ne 0 ]
    run grep -qE 'OS_VERSION.*"22\.04"' <<< "$body"; [ "$status" -ne 0 ]
}

# -------------------------------------------------------------------------
# Cross-file consistency — every target_id in installer has a matrix entry
# -------------------------------------------------------------------------

@test "every target_id in install_amneziawg.sh appears in arm-build.yml matrix" {
    local targets t
    # Extract all target_id="..." values from the function body
    targets=$(awk '/^_try_install_prebuilt_arm\(\) \{$/,/^}$/' "$INSTALL_RU" | \
              grep -oE 'target_id="[^"]+"' | sed 's/target_id="\([^"]*\)"/\1/' | sort -u)
    [ -n "$targets" ]
    while IFS= read -r t; do
        [ -z "$t" ] && continue
        grep -qE "id: ${t}\b" "$WF" || {
            echo "Missing matrix entry for target_id=$t" >&2
            return 1
        }
    done <<< "$targets"
}

@test "every matrix id in arm-build.yml is handled by installer target_id mapping" {
    local ids i
    ids=$(grep -oE '^\s*- id: [a-z0-9-]+' "$WF" | sed 's/.*id: //' | sort -u)
    [ -n "$ids" ]
    while IFS= read -r i; do
        [ -z "$i" ] && continue
        awk '/^_try_install_prebuilt_arm\(\) \{$/,/^}$/' "$INSTALL_RU" | \
            grep -qE "target_id=\"${i}\"" || {
            echo "Matrix id $i not referenced in install_amneziawg.sh" >&2
            return 1
        }
    done <<< "$ids"
}

@test "RU and EN installer have identical target_id mappings" {
    local ru en
    ru=$(awk '/^_try_install_prebuilt_arm\(\) \{$/,/^}$/' "$INSTALL_RU" | \
         grep -oE 'target_id="[^"]+"' | sort -u)
    en=$(awk '/^_try_install_prebuilt_arm\(\) \{$/,/^}$/' "$INSTALL_EN" | \
         grep -oE 'target_id="[^"]+"' | sort -u)
    [ "$ru" = "$en" ]
}
