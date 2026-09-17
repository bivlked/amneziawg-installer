#!/usr/bin/env bats
# Issue #285: the check that amneziawg-dkms is on hold refused on Debian 12
# although the hold was in place.
#
# Step 2 holds amneziawg-dkms before amneziawg-tools is installed: tools
# recommends the dkms package, and without the hold apt would pull the PPA
# module next to the one this path builds or unpacks. The check after the hold
# used to read `apt-mark showhold | grep -qx amneziawg-dkms`. The reporter saw it
# refuse while dpkg said `hold ok not-installed` and a manual showhold listed the
# package. The root cause is not proven: a producer that writes line by line
# gets SIGPIPE under pipefail once grep has matched and quit, which reproduces
# with a stub every time and with the real apt-mark on a small list not at all.
#
# So the check now asks the source apt itself obeys, the selection dpkg keeps
# for the package, and reads the showhold list only as a second source, from a
# variable rather than through a pipe. These tests pin that contract on the
# helper both installers define, and pin that both hold sites use it.

INSTALLERS=(install_amneziawg.sh install_amneziawg_en.sh)

setup() {
    BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$BIN"
}

# stub_dpkg_query <status line or empty for "unknown package">
stub_dpkg_query() {
    if [[ -n "$1" ]]; then
        printf '#!/usr/bin/env bash\nprintf "%%s" "%s"\n' "$1" > "$BIN/dpkg-query"
    else
        printf '#!/usr/bin/env bash\necho "dpkg-query: no packages found matching $3" >&2\nexit 1\n' > "$BIN/dpkg-query"
    fi
    chmod +x "$BIN/dpkg-query"
}

# stub_apt_mark <exit code> <line>... : showhold prints each line, flushing and
# pausing between lines the way a line-buffered producer does.
stub_apt_mark() {
    local rc="$1"; shift
    {
        echo '#!/usr/bin/env bash'
        echo '[ "$1" = showhold ] || exit 0'
        local l
        for l in "$@"; do
            printf 'printf "%%s\\n" "%s"; sleep 0.05\n' "$l"
        done
        echo "exit $rc"
    } > "$BIN/apt-mark"
    chmod +x "$BIN/apt-mark"
}

# held <installer> : runs the installer's _awg_pkg_held amneziawg-dkms under
# pipefail, the way the installer runs, with the stubs first on PATH.
held() {
    local src="$BATS_TEST_DIRNAME/../$1" body
    body=$(awk '/^_awg_pkg_held\(\) \{/,/^\}/' "$src")
    [[ -n "$body" ]] || { echo "NO_HELPER in $1"; return 3; }
    PATH="$BIN:$PATH" timeout 30 bash -c '
        set -o pipefail
        eval "$1"
        _awg_pkg_held amneziawg-dkms
    ' _ "$body"
}

both_rc() {
    local want="$1" f
    for f in "${INSTALLERS[@]}"; do
        run held "$f"
        [ "$status" -eq "$want" ] || { echo "$f: expected rc $want, got $status: $output"; return 1; }
    done
}

@test "hold check: dpkg selection 'hold ok not-installed' counts as held (the #285 state)" {
    stub_dpkg_query "hold ok not-installed"
    stub_apt_mark 0
    both_rc 0
}

@test "hold check: a hold on an installed package counts as held" {
    stub_dpkg_query "hold ok installed"
    stub_apt_mark 0
    both_rc 0
}

@test "hold check: the showhold list still counts when dpkg does not report the hold" {
    stub_dpkg_query "install ok not-installed"
    stub_apt_mark 0 amneziawg amneziawg-dkms
    both_rc 0
}

@test "hold check: more held packages after the match do not turn a hold into a refusal" {
    # The producer flushes line by line and keeps writing after the matching
    # line. Read through a pipe with grep -q under pipefail this form failed
    # every time; read from a variable it must pass.
    stub_dpkg_query ""
    stub_apt_mark 0 amneziawg amneziawg-dkms ifupdown linux-image-amd64 netcfg
    both_rc 0
}

@test "hold check: no hold in either source is a refusal" {
    stub_dpkg_query "install ok not-installed"
    stub_apt_mark 0 ifupdown netcfg
    both_rc 1
}

@test "hold check: an unknown package with an empty showhold is a refusal" {
    stub_dpkg_query ""
    stub_apt_mark 0
    both_rc 1
}

@test "hold check: the package name must match the whole line" {
    stub_dpkg_query ""
    stub_apt_mark 0 amneziawg-dkms-extra xamneziawg-dkms
    both_rc 1
}

@test "hold check: 'hold' elsewhere in the status is not the selection" {
    # Only the first word of Status is the selection (want). A word further on
    # must not pass for it.
    stub_dpkg_query "install hold installed"
    stub_apt_mark 0
    both_rc 1
}

@test "hold check: a failing showhold is not read as a list" {
    # A non-zero exit means the list cannot be trusted, even if it printed the
    # name before failing: without the dpkg selection this stays a refusal.
    stub_dpkg_query ""
    stub_apt_mark 100 amneziawg-dkms
    both_rc 1
}

@test "hold check: both hold sites in both installers use the helper, no pipe into grep" {
    local f n
    for f in "${INSTALLERS[@]}"; do
        ! grep -nE 'apt-mark showhold[^|]*\|[[:space:]]*grep' "$BATS_TEST_DIRNAME/../$f" \
            | grep -v '^[0-9]*:[[:space:]]*#' || { echo "$f still pipes showhold into grep"; return 1; }
        n=$(grep -cE '^[[:space:]]*if ! _awg_pkg_held amneziawg-dkms; then' "$BATS_TEST_DIRNAME/../$f")
        [ "$n" -eq 2 ] || { echo "$f: expected 2 guarded hold sites, found $n"; return 1; }
    done
}

@test "hold check: the helper body is the same in both installers" {
    local ru en
    ru=$(awk '/^_awg_pkg_held\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh" | grep -v '^[[:space:]]*#')
    en=$(awk '/^_awg_pkg_held\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh" | grep -v '^[[:space:]]*#')
    [ -n "$ru" ]
    [ "$ru" = "$en" ]
}
