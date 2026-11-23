#!/usr/bin/env bats
# v5.13.0 PPA noble fallback for Ubuntu non-LTS releases.
#
# Background: PPA Amnezia (ppa:amnezia/ppa on Launchpad) publishes packages
# only for known LTS Ubuntu codenames (noble/jammy/focal). Interim releases
# (questing/plucky/oracular/...) hit a 404 on dists/<codename>/Release.
# Upstream: amnezia-vpn/amneziawg-linux-kernel-module#118
#
# v5.13.0 fix: pre-check PPA availability. On 404, fall back to 'noble'
# (LTS): DKMS builds the module against the running kernel. Since v6.3.9 the
# check is _ppa_probe_suite, and only a 404 switches the suite: a 5xx or no
# answer is a Launchpad outage and keeps the release.
#
# Also handles re-run: a previous (≤ v5.12.1) install on questing wrote
# /etc/apt/sources.list.d/amnezia-ppa.sources with `Suites: questing`. On
# the next run, suite-mismatch detection rewrites it with the correct value.

# ---------- structural: RU script contains pre-check ----------

@test "v5.13.0: RU install whitelists LTS codenames (noble|jammy|focal)" {
    grep -q 'noble|jammy|focal)' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
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

# Since track K the fallback goes through the helper's --repair: it builds the
# running kernel (and the others); a failure on a stale kernel only (exit 1)
# still finishes the install; --finish configures dpkg - behaviour in
# test_kmod_installer.bats.
@test "v5.13.0: RU install_packages fallback repairs the module via the helper and finishes via --finish" {
    block=$(awk '/^install_packages\(\) \{/,/^\}/' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    [[ "$block" == *'_pkg_present amneziawg-dkms'* ]]
    [[ "$block" == *'"$AWG_ENSURE_HELPER" --repair'* ]]
    [[ "$block" == *'if [[ "$_hrc" -le 1 ]]'* ]]
    [[ "$block" == *'"$AWG_ENSURE_HELPER" --finish'* ]]
    [[ "$block" == *'_pkgs_installed_ok "${to_install[@]}"'* ]]
}

# Since track K the fallback goes through the helper's --repair: it builds the
# running kernel (and the others); a failure on a stale kernel only (exit 1)
# still finishes the install; --finish configures dpkg - behaviour in
# test_kmod_installer.bats.
@test "v5.13.0: EN install_packages fallback repairs the module via the helper and finishes via --finish" {
    block=$(awk '/^install_packages\(\) \{/,/^\}/' \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh")
    [[ "$block" == *'_pkg_present amneziawg-dkms'* ]]
    [[ "$block" == *'"$AWG_ENSURE_HELPER" --repair'* ]]
    [[ "$block" == *'if [[ "$_hrc" -le 1 ]]'* ]]
    [[ "$block" == *'"$AWG_ENSURE_HELPER" --finish'* ]]
    [[ "$block" == *'_pkgs_installed_ok "${to_install[@]}"'* ]]
}

@test "v5.13.0: RU install pre-installs gcc-13 when stale kernel headers detected" {
    grep -q 'устаревшие kernel headers' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -q 'apt-cache madison gcc-13' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -q 'apt -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y gcc-13' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
}

@test "v5.13.0: EN install pre-installs gcc-13 when stale kernel headers detected" {
    grep -q 'Stale kernel headers detected' \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    grep -q 'apt-cache madison gcc-13' \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    grep -q 'apt -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y gcc-13' \
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

@test "v5.13.0: EN install whitelists LTS codenames (noble|jammy|focal)" {
    grep -q 'noble|jammy|focal)' \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
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

# ---------- functional: _ppa_probe_suite from both installers ----------

# Loads the real _ppa_probe_suite from an installer. curl is a stub that
# prints STUB_HTTP as the status code (what `-w '%{http_code}'` prints) and
# exits with STUB_CURL_RC; CURL_LOG records the call.
_probe() {
    local installer="$1" codename="$2"
    log() { :; }
    log_warn() { printf '%s\n' "$*" >> "$WARN_LOG"; }
    curl() { printf '%s\n' "$*" >> "$CURL_LOG"; printf '%s' "${STUB_HTTP:-}"; return "${STUB_CURL_RC:-0}"; }
    eval "$(sed -n '/^_ppa_probe_suite()/,/^}/p' "$BATS_TEST_DIRNAME/../$installer")"
    _PPA_SUITE=""
    _ppa_probe_suite "$codename"
}

_probe_setup() {
    WARN_LOG="$BATS_TEST_TMPDIR/warn.log"; CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
    : > "$WARN_LOG"; : > "$CURL_LOG"
}

@test "PPA probe: 404 switches a non-LTS release to noble and says why, both twins" {
    local f
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        _probe_setup
        STUB_HTTP=404 STUB_CURL_RC=0 _probe "$f" plucky
        [ "$_PPA_SUITE" = "noble" ]
        grep -q 'HTTP 404' "$WARN_LOG"
        grep -q 'kernel-module/issues/118' "$WARN_LOG"
        grep -q 'dists/plucky/Release' "$CURL_LOG"
    done
}

@test "PPA probe: 200 keeps the release, no warning, both twins" {
    local f
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        _probe_setup
        STUB_HTTP=200 STUB_CURL_RC=0 _probe "$f" resolute
        [ "$_PPA_SUITE" = "resolute" ]
        run grep -c . "$WARN_LOG"
        [ "$output" = "0" ]
    done
}

# 23 Nov 2026 (I#68): Launchpad answered 503 for hours. A 5xx is an outage,
# not a release the PPA skips; switching to noble then would put a build for
# another Ubuntu release on the server.
@test "PPA probe: a 5xx keeps the release and names the outage, both twins" {
    local f code
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        for code in 503 502 500; do
            _probe_setup
            STUB_HTTP=$code STUB_CURL_RC=0 _probe "$f" resolute
            [ "$_PPA_SUITE" = "resolute" ] || { echo "$f $code -> '$_PPA_SUITE'"; return 1; }
            grep -q 'Launchpad' "$WARN_LOG"
            grep -q "$code" "$WARN_LOG"
            run grep -c "noble" "$WARN_LOG"
            [ "$output" = "0" ]
        done
    done
}

# No answer at all is not proof of an outage: apt may go through a proxy of
# its own that the probe does not use. On a release the PPA does not publish,
# keeping the suite would fail the install with "wait and retry", so no answer
# falls back to noble as before, and the warning says it was no answer.
@test "PPA probe: no answer falls back to noble and says it was no answer, both twins" {
    local f rc
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        for rc in 28 6 7; do
            _probe_setup
            STUB_HTTP=000 STUB_CURL_RC=$rc _probe "$f" plucky
            [ "$_PPA_SUITE" = "noble" ] || { echo "$f rc=$rc -> '$_PPA_SUITE'"; return 1; }
            grep -q '000' "$WARN_LOG"
            run grep -c 'HTTP 404' "$WARN_LOG"
            [ "$output" = "0" ]
        done
    done
}

@test "PPA probe: step 2 runs the probe only outside noble, jammy and focal, both twins" {
    local f block
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        block=$(awk '/case "\$ppa_codename" in/,/^            esac$/' "$BATS_TEST_DIRNAME/../$f")
        [[ "$block" == *'noble|jammy|focal)'* ]]
        [[ "$block" == *'_ppa_probe_suite "$ppa_codename"'* ]]
        [[ "$block" == *'ppa_codename="$_PPA_SUITE"'* ]]
    done
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
