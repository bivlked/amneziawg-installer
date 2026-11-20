#!/usr/bin/env bats
# Issue #409: DEBIAN_FRONTEND=noninteractive and -y do not answer dpkg's
# conffile prompt ("*** cloud.cfg (Y/I/N/O/D/Z) [default=N] ?"). With stdin
# open, step 1 waited on it forever; with stdin closed, dpkg failed on it and
# the `dpkg --configure -a` retry failed the same way. Every apt call that can
# install or upgrade a package now passes --force-confdef --force-confold
# (take the default answer, otherwise keep the current file), and so does
# every `dpkg --configure -a`.

bats_require_minimum_version 1.5.0

INSTALLERS=(install_amneziawg.sh install_amneziawg_en.sh)
APT_KEEP='-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold'
DPKG_KEEP='--force-confdef --force-confold'

# Executed apt and apt-get calls that install or upgrade, comments excluded.
# Every such call in the installers runs with DEBIAN_FRONTEND=noninteractive,
# which is what tells it apart from the same words inside a message.
live_apt_calls() {
    grep -vE '^[[:space:]]*#' "$BATS_TEST_DIRNAME/../$1" \
        | grep -E 'DEBIAN_FRONTEND=noninteractive apt(-get)? ' \
        | grep -E ' (install|upgrade) ' \
        | grep -vE 'upgrade -s '
}

@test "conffile: every executed apt install or upgrade keeps current config files, both installers" {
    local f n line
    for f in "${INSTALLERS[@]}"; do
        n=0
        while IFS= read -r line; do
            n=$((n + 1))
            [[ "$line" =~ apt(-get)?\ $APT_KEEP(\ -o\ [^ ]+)*\ (install|upgrade)\  ]] \
                || { echo "$f: apt call without the conffile options: $line"; return 1; }
        done < <(live_apt_calls "$f")
        # step 1 (2 upgrades), install_packages, two restore passes, two
        # netplan restores, gcc-13, kernel meta package
        [ "$n" -ge 9 ] || { echo "$f: only $n apt calls found"; return 1; }
    done
}

@test "conffile: every dpkg --configure -a keeps current config files, both installers" {
    local f n line
    for f in "${INSTALLERS[@]}"; do
        n=0
        while IFS= read -r line; do
            n=$((n + 1))
            [[ "$line" == *"dpkg --configure -a $DPKG_KEEP"* ]] \
                || { echo "$f: dpkg --configure -a without the conffile options: $line"; return 1; }
        done < <(grep -vE '^[[:space:]]*#' "$BATS_TEST_DIRNAME/../$f" | grep -E 'noninteractive dpkg ')
        # step 1: the repair before the upgrade and the retry; helper --finish
        [ "$n" -ge 3 ] || { echo "$f: only $n dpkg calls found"; return 1; }
        # and no dpkg --configure runs without the noninteractive prefix
        run grep -cE '^[[:space:]]*(if ! )?dpkg [^"]*--configure' "$BATS_TEST_DIRNAME/../$f"
        [ "$output" = "0" ] || { echo "$f: a bare dpkg --configure call"; return 1; }
    done
}

@test "conffile: install_packages passes the options to apt, both installers" {
    local f body
    for f in "${INSTALLERS[@]}"; do
        body=$(awk '/^install_packages\(\) \{/,/^\}$/' "$BATS_TEST_DIRNAME/../$f")
        [ -n "$body" ]
        mkdir -p "$BATS_TEST_TMPDIR/bin"
        printf '#!/bin/bash\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/dpkg-query"
        printf '#!/bin/bash\necho "$*" > "%s/apt-args"\nexit 0\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/apt"
        chmod +x "$BATS_TEST_TMPDIR/bin/dpkg-query" "$BATS_TEST_TMPDIR/bin/apt"
        rm -f "$BATS_TEST_TMPDIR/apt-args"
        run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" LOG_FILE=/dev/null timeout 30 bash -c \
            'log() { :; }; log_warn() { :; }; die() { echo "DIE $*"; exit 1; }; _APT_UPDATED=1; _install_temp_files=(); eval "$1"; install_packages curl' _ "$body"
        [ "$status" -eq 0 ] || { echo "$f: $status $output"; return 1; }
        [[ "$(cat "$BATS_TEST_TMPDIR/apt-args")" == "$APT_KEEP "*"install -y curl" ]] \
            || { echo "$f: apt got: $(cat "$BATS_TEST_TMPDIR/apt-args")"; return 1; }
    done
}
