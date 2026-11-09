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

# -------------------------------------------------------------------------
# Raspberry Pi OS trixie (13) gets its own targets; bookworm (12) keeps the
# old ones. Behaviour, not text: the function runs with a fake uname, dpkg
# and curl, and the asset name it asks for is checked whole.
# -------------------------------------------------------------------------

_asset_for() { # $1 installer, $2 uname -r, $3 dpkg arch, $4 OS_VERSION
    local script="$1"
    run bash -c '
        eval "$(awk '\''/^_try_install_prebuilt_arm\(\) \{$/,/^}$/'\'' "'"$script"'")"
        log() { :; }; log_warn() { :; }
        uname() { echo "'"$2"'"; }
        dpkg() { echo "'"$3"'"; }
        curl() {
            local a; for a in "$@"; do
                case "$a" in https://*) echo "URL $a" ;; esac
            done
            return 22
        }
        OS_ID=debian OS_VERSION="'"$4"'"
        _try_install_prebuilt_arm
        echo "rc=$?"
    '
}

_assert_asset() { # $1 expected asset file name
    [ "$status" -eq 0 ]
    [[ "$output" == *"URL https://github.com/bivlked/amneziawg-installer/releases/download/arm-packages/$1.sha256"* ]]
    [[ "$output" == *"rc=1"* ]]
}

@test "RU/EN: RPi OS trixie Pi 4 arm64 -> rpi-trixie-arm64" {
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        _asset_for "$s" "6.18.60+rpt-rpi-v8" arm64 13
        _assert_asset "amneziawg-kmod-rpi-trixie-arm64_6.18.60+rpt-rpi-v8_arm64.deb"
    done
}

@test "RU/EN: RPi OS trixie Pi 5 -> rpi5-trixie-arm64" {
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        _asset_for "$s" "6.18.60+rpt-rpi-2712" arm64 13
        _assert_asset "amneziawg-kmod-rpi5-trixie-arm64_6.18.60+rpt-rpi-2712_arm64.deb"
    done
}

@test "RU/EN: RPi OS trixie 32-bit -> rpi-trixie-armhf" {
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        _asset_for "$s" "6.18.60+rpt-rpi-v7" armhf 13
        _assert_asset "amneziawg-kmod-rpi-trixie-armhf_6.18.60+rpt-rpi-v7_armhf.deb"
    done
}

@test "RU/EN: RPi OS bookworm keeps the bookworm targets" {
    for s in "$INSTALL_RU" "$INSTALL_EN"; do
        _asset_for "$s" "6.12.115+rpt-rpi-v8" arm64 12
        _assert_asset "amneziawg-kmod-rpi-bookworm-arm64_6.12.115+rpt-rpi-v8_arm64.deb"
        _asset_for "$s" "6.12.115+rpt-rpi-2712" arm64 12
        _assert_asset "amneziawg-kmod-rpi5-bookworm-arm64_6.12.115+rpt-rpi-2712_arm64.deb"
        _asset_for "$s" "6.12.115+rpt-rpi-v7l" armhf 12
        _assert_asset "amneziawg-kmod-rpi-bookworm-armhf_6.12.115+rpt-rpi-v7l_armhf.deb"
    done
}

@test "arm-build.yml has the 3 Raspberry Pi trixie entries on debian:trixie with suite trixie" {
    local id
    for id in rpi-trixie-arm64 rpi5-trixie-arm64 rpi-trixie-armhf; do
        awk -v id="$id" '$0 ~ "- id: " id "$" {p=1; next} p && /- id:/ {exit} p' "$WF" > "$BATS_TEST_TMPDIR/entry"
        grep -qxF '            image: debian:trixie' "$BATS_TEST_TMPDIR/entry"
        grep -qxF '            rpi_suite: trixie' "$BATS_TEST_TMPDIR/entry"
    done
}