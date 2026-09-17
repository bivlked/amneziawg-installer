#!/usr/bin/env bats
# Issue #285: the check that amneziawg-dkms is on hold refused on Debian 12
# although the hold was in place.
#
# Step 2 holds amneziawg-dkms before amneziawg-tools is installed: tools
# recommends the dkms package, and without the hold apt would pull the PPA
# module next to the one this path builds or unpacks. The check after the hold
# used to read `apt-mark showhold | grep -qx amneziawg-dkms`. The reporter saw it
# refuse while dpkg said `hold ok not-installed` and a manual showhold listed the
# package. The cause on that host is not proven. One mechanism is real: apt-mark
# writes line by line, grep -q quits at the match, and if more held packages sort
# after it the next write gets SIGPIPE, so under pipefail the pipeline fails. It
# reproduces with the stub below every time and with the real apt-mark on a long
# list of holds; on a short list it does not.
#
# So the check now asks the source apt itself obeys, the selection dpkg keeps
# for the package, and reads the showhold list only as a fallback, from a
# variable rather than through a pipe. These tests pin that contract on the
# helper both installers define, and pin that both hold sites use it.

INSTALLERS=(install_amneziawg.sh install_amneziawg_en.sh)

setup() {
    BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$BIN"
}

# stub_dpkg_query <status line or empty for "unknown package">
# Answers only for the exact query the helper must make: -W, the Status format
# and the package name. Any other query is an unknown package, so a helper that
# asked about the wrong package or field loses the dpkg source and the tests
# that rely on it go red. Real dpkg-query prints the status without a newline.
stub_dpkg_query() {
    {
        echo '#!/usr/bin/env bash'
        # shellcheck disable=SC2016
        echo 'if [ "$1" = -W ] && [ "$2" = "-f=\${Status}" ] && [ "$3" = amneziawg-dkms ] && [ -n "$ST" ]; then'
        echo '    printf "%s" "$ST"; exit 0'
        echo 'fi'
        echo 'echo "dpkg-query: no packages found matching ${3:-}" >&2'
        echo 'exit 1'
    } > "$BIN/dpkg-query"
    chmod +x "$BIN/dpkg-query"
    export ST="$1"
}

# stub_apt_mark <exit code> <line>... : showhold prints each line as a separate
# write, with a pause that widens the race window, so the pipe form fails every
# time when the match is not the last line.
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
    # The producer writes line by line and keeps writing after the matching
    # line. Read through a pipe with grep -q under pipefail this form failed
    # every time; read from a variable it must pass. The match must NOT be the
    # last line: then nothing is written after grep quits and the old form
    # passes too, so the test would stop telling the two apart.
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
    # Only the first word of Status is the selection (want). Modern dpkg does
    # not print this status; it is a synthetic guard against matching a later
    # word.
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

@test "hold check: an empty or missing package name is a refusal" {
    # With no holds at all, the here-string still carries one empty line, and
    # an exact match of an empty name against it would pass.
    stub_dpkg_query ""
    stub_apt_mark 0
    local f body
    for f in "${INSTALLERS[@]}"; do
        body=$(awk '/^_awg_pkg_held\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../$f")
        run env PATH="$BIN:$PATH" timeout 30 bash -c 'set -o pipefail; eval "$1"; _awg_pkg_held ""' _ "$body"
        [ "$status" -eq 1 ] || { echo "$f: empty name gave rc $status"; return 1; }
        run env PATH="$BIN:$PATH" timeout 30 bash -c 'set -o pipefail; eval "$1"; _awg_pkg_held' _ "$body"
        [ "$status" -eq 1 ] || { echo "$f: missing name gave rc $status"; return 1; }
    done
}

@test "hold check: each site holds first, then checks, refuses with die, and only then installs tools" {
    # A check that moved below the tools install, lost its die, or lost the
    # hold in front of it would still count as "two guarded sites" above. Here
    # the order is pinned by line numbers: the apt-mark hold, then the check
    # within a few lines, the refusal log and die inside the check, and the
    # first install_packages after the hold only after the check.
    local f src holds h c i d
    for f in "${INSTALLERS[@]}"; do
        src="$BATS_TEST_DIRNAME/../$f"
        holds=$(grep -nE '^[[:space:]]*_hold_out=\$\(apt-mark hold amneziawg-dkms amneziawg 2>&1\) \|\| true$' "$src" | cut -d: -f1)
        [ "$(wc -l <<< "$holds")" -eq 2 ] || { echo "$f: expected 2 captured holds, got: $holds"; return 1; }
        for h in $holds; do
            c=$(awk -v s="$h" 'NR>s && /^[[:space:]]*if ! _awg_pkg_held amneziawg-dkms; then$/ {print NR; exit}' "$src")
            i=$(awk -v s="$h" 'NR>s && /^[[:space:]]*install_packages / {print NR; exit}' "$src")
            [ -n "$c" ] && [ -n "$i" ] || { echo "$f: hold at $h has no check ($c) or install ($i) after it"; return 1; }
            [ $((c - h)) -le 8 ] || { echo "$f: check at $c is too far from the hold at $h"; return 1; }
            [ "$c" -lt "$i" ] || { echo "$f: check at $c comes after install_packages at $i"; return 1; }
            sed -n "$((c + 1))p" "$src" | grep -qE '^[[:space:]]*_awg_hold_refusal_log "\$_hold_out"$' \
                || { echo "$f: no refusal log right after the check at $c"; return 1; }
            d=$(sed -n "$((c + 2))p" "$src")
            [[ "$d" =~ ^[[:space:]]*die\  ]] || { echo "$f: line after the refusal log at $c is not die: $d"; return 1; }
        done
    done
}

@test "hold check: a refusal prints what apt-mark and dpkg answered" {
    local f body
    stub_dpkg_query "install ok not-installed"
    for f in "${INSTALLERS[@]}"; do
        body=$(awk '/^_awg_hold_refusal_log\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../$f")
        [ -n "$body" ] || { echo "no _awg_hold_refusal_log in $f"; return 1; }
        run env PATH="$BIN:$PATH" timeout 30 bash -c 'log_error() { echo "ERR: $*"; }; eval "$1"; _awg_hold_refusal_log "E: Could not get lock /var/lib/dpkg/lock-frontend"' _ "$body"
        [ "$status" -eq 0 ]
        [[ "$output" == *"E: Could not get lock /var/lib/dpkg/lock-frontend"* ]] || { echo "$f lost the apt-mark answer: $output"; return 1; }
        [[ "$output" == *"install ok not-installed"* ]] || { echo "$f lost the dpkg status: $output"; return 1; }
    done
    # When dpkg itself fails, its own message is the reason and must be shown.
    stub_dpkg_query ""
    for f in "${INSTALLERS[@]}"; do
        body=$(awk '/^_awg_hold_refusal_log\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../$f")
        run env PATH="$BIN:$PATH" timeout 30 bash -c 'log_error() { echo "ERR: $*"; }; eval "$1"; _awg_hold_refusal_log ""' _ "$body"
        [ "$status" -eq 0 ]
        [[ "$output" == *"no packages found matching amneziawg-dkms"* ]] || { echo "$f hid the dpkg error: $output"; return 1; }
        # An empty apt-mark answer is named, not left as a blank.
        [[ "$output" == *"<пусто>"* || "$output" == *"<empty>"* ]] || { echo "$f left the empty answer blank: $output"; return 1; }
    done
}

@test "hold check: a multi-line answer stays on one log line and is cut to its end" {
    # log_msg stamps only the first line of a message, so a raw multi-line apt
    # answer would leave unstamped lines in the log. The reason apt gives is
    # usually at the end, so a long answer keeps its tail.
    local f body long
    stub_dpkg_query "install ok not-installed"
    long="$(printf 'W: noise %.0s\n' $(seq 60))E: Could not get lock /var/lib/dpkg/lock-frontend"
    for f in "${INSTALLERS[@]}"; do
        body=$(awk '/^_awg_hold_refusal_log\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../$f")
        run env PATH="$BIN:$PATH" timeout 30 bash -c 'log_error() { echo "ERR: $*"; }; eval "$1"; _awg_hold_refusal_log "$2"' _ "$body" "$long"
        [ "$status" -eq 0 ]
        [ "${#lines[@]}" -eq 2 ] || { echo "$f: expected 2 log lines, got ${#lines[@]}: $output"; return 1; }
        [[ "${lines[0]}" == *"E: Could not get lock /var/lib/dpkg/lock-frontend" ]] || { echo "$f lost the tail: ${lines[0]}"; return 1; }
        [ "${#lines[0]}" -lt 400 ] || { echo "$f did not cut a long answer: ${#lines[0]} chars"; return 1; }
    done
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
