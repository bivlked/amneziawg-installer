#!/usr/bin/env bats
# v5.13.0 PPA noble fallback for Ubuntu non-LTS releases.
#
# Background: PPA Amnezia (ppa:amnezia/ppa on Launchpad) publishes packages
# only for known LTS Ubuntu codenames (noble/jammy/focal). Interim releases
# (questing/plucky/oracular/...) hit a 404 on dists/<codename>/Release.
# Upstream: amnezia-vpn/amneziawg-linux-kernel-module#118
#
# v5.13.0 fix: pre-check PPA availability with `curl -fsI`. On 404 or host
# unreachable, fall back to 'noble' (LTS) — DKMS builds the module against
# the running kernel.
#
# Also handles re-run: a previous (≤ v5.12.1) install on questing wrote
# /etc/apt/sources.list.d/amnezia-ppa.sources with `Suites: questing`. On
# the next run, suite-mismatch detection rewrites it with the correct value.

# ---------- structural: RU script contains pre-check ----------

@test "v5.13.0: RU install has PPA pre-check for Ubuntu non-LTS" {
    grep -q 'Проверка доступности PPA Amnezia для Ubuntu' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -q 'curl -fsI --max-time 15 --retry 2 --retry-delay 5' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -q 'dists/${ppa_codename}/Release' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
}

@test "v5.13.0: RU install whitelists LTS codenames (noble|jammy|focal)" {
    grep -q 'noble|jammy|focal)' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
}

@test "v5.13.0: RU install falls back ppa_codename to noble on failure" {
    block=$(awk '/Проверка доступности PPA Amnezia для Ubuntu/,/log "PPA Amnezia доступен/' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    [[ "$block" == *'ppa_codename="noble"'* ]]
    [[ "$block" == *'kernel-module/issues/118'* ]]
}

@test "v5.13.0: RU install has suite-mismatch detection" {
    grep -q "awk '/\^Suites:/{print \$2; exit}'" \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -q 'пересоздание' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
}

@test "v5.13.0: RU install handles corrupt .sources (no Suites line)" {
    grep -q 'строка Suites: не найдена' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
}

@test "v5.13.0: RU install also checks legacy .sources for suite mismatch" {
    grep -q 'legacy_suite' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -q 'Устаревший PPA-файл' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
}

@test "v5.13.0: RU install_packages falls back to dkms install for running kernel on amneziawg-dkms failure" {
    block=$(awk '/^install_packages\(\) \{/,/^\}/' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    [[ "$block" == *'amneziawg-dkms'* ]]
    [[ "$block" == *'dkms install -m amneziawg'* ]]
    [[ "$block" == *'-k "$(uname -r)" --force'* ]]
    [[ "$block" == *'dpkg --configure -a'* ]]
}

@test "v5.13.0: EN install_packages falls back to dkms install for running kernel on amneziawg-dkms failure" {
    block=$(awk '/^install_packages\(\) \{/,/^\}/' \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh")
    [[ "$block" == *'amneziawg-dkms'* ]]
    [[ "$block" == *'dkms install -m amneziawg'* ]]
    [[ "$block" == *'-k "$(uname -r)" --force'* ]]
    [[ "$block" == *'dpkg --configure -a'* ]]
}

@test "v5.13.0: RU install pre-installs gcc-13 when stale kernel headers detected" {
    grep -q 'устаревшие kernel headers' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -q 'apt-cache madison gcc-13' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -q 'apt install -y gcc-13' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
}

@test "v5.13.0: EN install pre-installs gcc-13 when stale kernel headers detected" {
    grep -q 'Stale kernel headers detected' \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    grep -q 'apt-cache madison gcc-13' \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    grep -q 'apt install -y gcc-13' \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
}

# ---- functional: stale-kernel-headers detection loop logic ----

@test "v5.13.0: stale detection - only running kernel => no stale" {
    tmpdir=$(mktemp -d)/lib/modules
    mkdir -p "$tmpdir/6.17.0-23-generic/build"
    running="6.17.0-23-generic"
    has_stale=0
    for hd in "$tmpdir"/*/build; do
        [[ -e "$hd" ]] || continue
        hd_kern="${hd#$tmpdir/}"
        hd_kern="${hd_kern%/build}"
        if [[ "$hd_kern" != "$running" ]]; then
            has_stale=1
            break
        fi
    done
    [ "$has_stale" -eq 0 ]
    rm -rf "$(dirname "$tmpdir")"
}

@test "v5.13.0: stale detection - running + 6.8 => stale=1" {
    tmpdir=$(mktemp -d)/lib/modules
    mkdir -p "$tmpdir/6.17.0-23-generic/build" "$tmpdir/6.8.0-111-generic/build"
    running="6.17.0-23-generic"
    has_stale=0
    for hd in "$tmpdir"/*/build; do
        [[ -e "$hd" ]] || continue
        hd_kern="${hd#$tmpdir/}"
        hd_kern="${hd_kern%/build}"
        if [[ "$hd_kern" != "$running" ]]; then
            has_stale=1
            break
        fi
    done
    [ "$has_stale" -eq 1 ]
    rm -rf "$(dirname "$tmpdir")"
}

# ---------- structural: EN script mirror ----------

@test "v5.13.0: EN install has PPA pre-check for Ubuntu non-LTS" {
    grep -q 'Checking Amnezia PPA availability for Ubuntu' \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    grep -q 'curl -fsI --max-time 15 --retry 2 --retry-delay 5' \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    grep -q 'dists/${ppa_codename}/Release' \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
}

@test "v5.13.0: EN install whitelists LTS codenames (noble|jammy|focal)" {
    grep -q 'noble|jammy|focal)' \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
}

@test "v5.13.0: EN install falls back ppa_codename to noble on failure" {
    block=$(awk '/Checking Amnezia PPA availability for Ubuntu/,/log "Amnezia PPA is available/' \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh")
    [[ "$block" == *'ppa_codename="noble"'* ]]
    [[ "$block" == *'kernel-module/issues/118'* ]]
}

@test "v5.13.0: EN install has suite-mismatch detection" {
    grep -q "awk '/\^Suites:/{print \$2; exit}'" \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    grep -q 'recreating' \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
}

@test "v5.13.0: EN install handles corrupt .sources (no Suites line)" {
    grep -q 'no Suites: line found' \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
}

@test "v5.13.0: EN install also checks legacy .sources for suite mismatch" {
    grep -q 'legacy_suite' \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    grep -q 'Legacy PPA' \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
}

# ---------- structural: parity counts ----------

@test "v5.13.0: RU/EN pre-check block parity (curl line count matches)" {
    ru=$(grep -c 'curl -fsI --max-time 15 --retry 2 --retry-delay 5' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    en=$(grep -c 'curl -fsI --max-time 15 --retry 2 --retry-delay 5' \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh")
    [ "$ru" -eq "$en" ]
    [ "$ru" -eq 1 ]
}

@test "v5.13.0: RU/EN noble fallback assignment count matches" {
    # Both scripts must assign ppa_codename="noble" inside the pre-check
    # exactly once. (Other "noble" mentions exist in Debian mapping above.)
    ru_pre=$(awk '/case "\$ppa_codename" in/,/^            esac$/' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh" \
        | grep -c 'ppa_codename="noble"')
    en_pre=$(awk '/case "\$ppa_codename" in/,/^            esac$/' \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh" \
        | grep -c 'ppa_codename="noble"')
    [ "$ru_pre" -eq "$en_pre" ]
    [ "$ru_pre" -ge 1 ]
}

# ---------- functional: ppa_codename resolution under mocked curl ----------

# Helper: extract a copy of the pre-check `case` and evaluate it with
# whatever curl behaviour the test set up. We replicate the block here
# instead of sourcing the installer (which would pull in side effects).
run_pre_check() {
    local ppa_codename="$1"
    case "$ppa_codename" in
        noble|jammy|focal) ;;
        *)
            if ! curl -fsI --max-time 15 --retry 2 --retry-delay 5 \
                "https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu/dists/${ppa_codename}/Release" \
                >/dev/null 2>&1; then
                ppa_codename="noble"
            fi
            ;;
    esac
    echo "$ppa_codename"
}

@test "v5.13.0: questing + curl 404 -> noble" {
    curl() { return 22; }   # curl's "HTTP error" exit code
    export -f curl
    result=$(run_pre_check questing)
    [ "$result" = "noble" ]
}

@test "v5.13.0: questing + curl timeout/network fail -> noble" {
    curl() { return 28; }   # curl's "operation timeout" exit code
    export -f curl
    result=$(run_pre_check questing)
    [ "$result" = "noble" ]
}

@test "v5.13.0: questing + curl success -> questing (no fallback)" {
    curl() { return 0; }
    export -f curl
    result=$(run_pre_check questing)
    [ "$result" = "questing" ]
}

@test "v5.13.0: noble skips pre-check entirely (curl never called)" {
    curl() { echo "CURL SHOULD NOT BE CALLED" >&2; return 1; }
    export -f curl
    result=$(run_pre_check noble)
    [ "$result" = "noble" ]
}

@test "v5.13.0: jammy skips pre-check entirely" {
    curl() { return 1; }
    export -f curl
    result=$(run_pre_check jammy)
    [ "$result" = "jammy" ]
}

@test "v5.13.0: focal skips pre-check entirely" {
    curl() { return 1; }
    export -f curl
    result=$(run_pre_check focal)
    [ "$result" = "focal" ]
}

@test "v5.13.0: plucky (future non-LTS) + curl 404 -> noble" {
    curl() { return 22; }
    export -f curl
    result=$(run_pre_check plucky)
    [ "$result" = "noble" ]
}

# ---------- functional: suite-mismatch detection ----------

@test "v5.13.0: existing Suites=questing + target=noble -> file gets deleted" {
    tmpdir=$(mktemp -d)
    ppa_sources="$tmpdir/amnezia-ppa.sources"
    ppa_list="$tmpdir/amnezia-ppa.list"
    cat > "$ppa_sources" <<EOF
Types: deb
URIs: https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu
Suites: questing
Components: main
Signed-By: /etc/apt/keyrings/amnezia-ppa.gpg
EOF
    ppa_codename="noble"

    # Inline the v5.13.0 logic
    existing_suite=""
    if [[ -f "$ppa_sources" ]]; then
        existing_suite=$(awk '/^Suites:/{print $2; exit}' "$ppa_sources" 2>/dev/null)
    fi
    [ "$existing_suite" = "questing" ]

    if [[ -n "$existing_suite" && "$existing_suite" != "$ppa_codename" ]]; then
        rm -f "$ppa_sources" "$ppa_list"
    fi
    [ ! -f "$ppa_sources" ]
    rm -rf "$tmpdir"
}

@test "v5.13.0: existing Suites=noble + target=noble -> file preserved" {
    tmpdir=$(mktemp -d)
    ppa_sources="$tmpdir/amnezia-ppa.sources"
    ppa_list="$tmpdir/amnezia-ppa.list"
    cat > "$ppa_sources" <<EOF
Types: deb
URIs: https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu
Suites: noble
Components: main
Signed-By: /etc/apt/keyrings/amnezia-ppa.gpg
EOF
    ppa_codename="noble"

    existing_suite=""
    if [[ -f "$ppa_sources" ]]; then
        existing_suite=$(awk '/^Suites:/{print $2; exit}' "$ppa_sources" 2>/dev/null)
    fi
    [ "$existing_suite" = "noble" ]

    if [[ -n "$existing_suite" && "$existing_suite" != "$ppa_codename" ]]; then
        rm -f "$ppa_sources" "$ppa_list"
    fi
    [ -f "$ppa_sources" ]
    rm -rf "$tmpdir"
}

@test "v5.13.0: missing .sources -> suite-mismatch logic is a no-op" {
    tmpdir=$(mktemp -d)
    ppa_sources="$tmpdir/does-not-exist.sources"
    ppa_codename="noble"

    existing_suite=""
    if [[ -f "$ppa_sources" ]]; then
        existing_suite=$(awk '/^Suites:/{print $2; exit}' "$ppa_sources" 2>/dev/null)
    fi
    [ -z "$existing_suite" ]

    # mismatch condition shouldn't trigger
    if [[ -f "$ppa_sources" && ( -z "$existing_suite" || "$existing_suite" != "$ppa_codename" ) ]]; then
        rm -f "$ppa_sources"
    fi
    [ ! -f "$ppa_sources" ]   # never existed
    rm -rf "$tmpdir"
}

# ---------- functional: corrupt .sources (no Suites: line) ----------

@test "v5.13.0: corrupt .sources (no Suites line) gets recreated" {
    tmpdir=$(mktemp -d)
    ppa_sources="$tmpdir/amnezia-ppa.sources"
    ppa_list="$tmpdir/amnezia-ppa.list"
    # Garbage file — exists but no Suites: line (manual edit gone wrong,
    # half-written by a crashed dpkg, etc.)
    cat > "$ppa_sources" <<EOF
Types: deb
URIs: https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu
# Suites: removed by hand
Components: main
Signed-By: /etc/apt/keyrings/amnezia-ppa.gpg
EOF
    ppa_codename="noble"

    existing_suite=""
    if [[ -f "$ppa_sources" ]]; then
        existing_suite=$(awk '/^Suites:/{print $2; exit}' "$ppa_sources" 2>/dev/null)
    fi
    [ -z "$existing_suite" ]

    # New logic: empty suite + file exists => rewrite
    if [[ -f "$ppa_sources" && ( -z "$existing_suite" || "$existing_suite" != "$ppa_codename" ) ]]; then
        rm -f "$ppa_sources" "$ppa_list"
    fi
    [ ! -f "$ppa_sources" ]
    rm -rf "$tmpdir"
}

# ---------- functional: legacy .sources mismatch ----------

@test "v5.13.0: legacy .sources with questing suite + target noble -> removed" {
    tmpdir=$(mktemp -d)
    legacy_sources="$tmpdir/amnezia-ubuntu-ppa-questing.sources"
    legacy_list="$tmpdir/amnezia-ubuntu-ppa-questing.list"
    cat > "$legacy_sources" <<EOF
Types: deb
URIs: https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu
Suites: questing
Components: main
Signed-By: /etc/apt/keyrings/amnezia-ppa.gpg
EOF
    ppa_codename="noble"

    legacy_suite=""
    if [[ -f "$legacy_sources" ]]; then
        legacy_suite=$(awk '/^Suites:/{print $2; exit}' "$legacy_sources" 2>/dev/null)
    fi
    [ "$legacy_suite" = "questing" ]

    if [[ -f "$legacy_sources" && ( -z "$legacy_suite" || "$legacy_suite" != "$ppa_codename" ) ]]; then
        rm -f "$legacy_sources" "$legacy_list"
    fi
    [ ! -f "$legacy_sources" ]
    rm -rf "$tmpdir"
}

@test "v5.13.0: legacy .sources with matching suite -> preserved" {
    tmpdir=$(mktemp -d)
    legacy_sources="$tmpdir/amnezia-ubuntu-ppa-noble.sources"
    legacy_list="$tmpdir/amnezia-ubuntu-ppa-noble.list"
    cat > "$legacy_sources" <<EOF
Types: deb
URIs: https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu
Suites: noble
Components: main
Signed-By: /etc/apt/keyrings/amnezia-ppa.gpg
EOF
    ppa_codename="noble"

    legacy_suite=""
    if [[ -f "$legacy_sources" ]]; then
        legacy_suite=$(awk '/^Suites:/{print $2; exit}' "$legacy_sources" 2>/dev/null)
    fi
    [ "$legacy_suite" = "noble" ]

    if [[ -f "$legacy_sources" && ( -z "$legacy_suite" || "$legacy_suite" != "$ppa_codename" ) ]]; then
        rm -f "$legacy_sources" "$legacy_list"
    fi
    [ -f "$legacy_sources" ]
    rm -rf "$tmpdir"
}
