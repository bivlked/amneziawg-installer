#!/usr/bin/env bats
# Issue #409: DEBIAN_FRONTEND=noninteractive and -y do not answer dpkg's
# conffile prompt ("*** cloud.cfg (Y/I/N/O/D/Z) [default=N] ?"). With stdin
# open, step 1 waited on it forever; with stdin closed, dpkg failed on it and
# the `dpkg --configure -a` retry failed the same way. Every apt call in the
# six scripts that installs, upgrades or removes packages (a removal also makes
# apt configure pending packages) now passes --force-confdef --force-confold
# (take the default answer, otherwise keep the current file), and so does
# every `dpkg --configure -a`.
#
# The calls are found by their verb, not by their prefix, so a new call
# written without DEBIAN_FRONTEND or with the options in the wrong place is
# found and fails. Message text is cut out by its caller (log*, die, printf,
# echo at the start of a command, the fix=/note= hints), not by parsing
# quotes: a quote parser loses the pairing after "$(...)" and would hide the
# code that follows. Cutting to the end of the line still hides a call written
# after a message on the same line (`echo "x"; apt-get ...`), so a second,
# independent guard counts every mention of an apt or dpkg call in each
# script without cutting anything: any new mention, hidden or not, changes
# that count and has to be looked at.

bats_require_minimum_version 1.5.0

SCRIPTS=(install_amneziawg.sh install_amneziawg_en.sh awg_common.sh awg_common_en.sh manage_amneziawg.sh manage_amneziawg_en.sh)
APT_KEEP='-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold'
APT_RE='(DEBIAN_FRONTEND=noninteractive +)?\bapt(-get)?( +-o +[^ ]+| +-[a-zA-Z-]+)* +(install|upgrade|dist-upgrade|full-upgrade|reinstall|purge|remove|autoremove)( +-s( |$))?'
DPKG_RE='(DEBIAN_FRONTEND=noninteractive +)?\bdpkg( +-[^ ]+)* +--configure( +-[^ ;|)]+)*'

# code_of <script> : the script without comment lines and without message
# text: from a message call to the end of its line, and the fix=/note= hint
# strings.
code_of() {
    grep -vE '^[[:space:]]*#' "$BATS_TEST_DIRNAME/../$1" | strip_messages
}
strip_messages() {
    sed -E 's/(^[[:space:]]*|[;&|({)][[:space:]]*|[[:space:]](then|else|do)[[:space:]]+)(log|log_warn|log_error|log_debug|log_line|die|printf|echo)( .*|$)/\1/; s/(^|[[:space:];)])(local +)?(fix|note|_dfix)="[^"]*"/\1/g'
}

@test "conffile: every apt call that installs, upgrades or removes keeps current config files, all six scripts" {
    local f n call min
    for f in "${SCRIPTS[@]}"; do
        n=0
        while IFS= read -r call; do
            [ -n "$call" ] || continue
            # a dry run (-s) changes nothing and asks nothing
            [[ "$call" =~ \ -s\ ?$ ]] && continue
            n=$((n + 1))
            case "$call" in
                "DEBIAN_FRONTEND=noninteractive apt-get $APT_KEEP install"|\
                "DEBIAN_FRONTEND=noninteractive apt-get $APT_KEEP upgrade"|\
                "DEBIAN_FRONTEND=noninteractive apt-get $APT_KEEP purge"|\
                "DEBIAN_FRONTEND=noninteractive apt $APT_KEEP install"|\
                "DEBIAN_FRONTEND=noninteractive apt $APT_KEEP -o Apt::Cmd::Disable-Script-Warning=true install") ;;
                *) echo "$f: apt call not in the allowed form: [$call]"; return 1 ;;
            esac
        done < <(code_of "$f" | grep -oE "$APT_RE")
        # installers: 2 upgrades, install_packages, 2 restore passes, 2 netplan
        # restores, gcc-13, kernel meta package, 6 purges; awg_common: headers;
        # manage: ipset for block-ru, the install and its retry after apt-get update.
        # Exact: a new call means updating this number on purpose.
        case "$f" in
            install_*) min=15 ;;
            awg_common*) min=1 ;;
            *) min=2 ;;
        esac
        [ "$n" -eq "$min" ] || { echo "$f: $n apt calls found, expected $min"; return 1; }
    done
}

@test "conffile: every dpkg --configure keeps current config files, all six scripts" {
    local f n call min
    for f in "${SCRIPTS[@]}"; do
        n=0
        while IFS= read -r call; do
            [ -n "$call" ] || continue
            n=$((n + 1))
            [ "$call" = "DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confdef --force-confold" ] \
                || { echo "$f: dpkg call not in the allowed form: [$call]"; return 1; }
        done < <(code_of "$f" | grep -oE "$DPKG_RE")
        # step 1: the repair before the upgrade and the retry; helper --finish
        case "$f" in install_*) min=3 ;; *) min=0 ;; esac
        [ "$n" -eq "$min" ] || { echo "$f: $n dpkg calls found, expected $min"; return 1; }
    done
}

@test "conffile: every mention of an apt or dpkg call is counted, nothing cut, all six scripts" {
    # Calls plus the same words inside messages and hints. A change here means
    # a call or a message was added or removed: check it is not a call hidden
    # behind a message on the same line, then update the number.
    local f raw a d want
    for f in "${SCRIPTS[@]}"; do
        raw=$(grep -vE '^[[:space:]]*#' "$BATS_TEST_DIRNAME/../$f")
        a=$(grep -oE "$APT_RE" <<< "$raw" | wc -l)
        d=$(grep -oE "$DPKG_RE" <<< "$raw" | wc -l)
        case "$f" in
            install_amneziawg.sh) want="35 20" ;;
            install_amneziawg_en.sh) want="34 20" ;;
            awg_common.sh|awg_common_en.sh) want="6 0" ;;
            manage_amneziawg.sh|manage_amneziawg_en.sh) want="8 4" ;;
        esac
        [ "$a $d" = "$want" ] || { echo "$f: apt/dpkg mentions $a $d, expected $want"; return 1; }
    done
}

@test "conffile: the call finder sees the shapes it must judge" {
    # The two tests above are only as good as their finder: each of these must
    # be found (and would then fail the allowed-form check).
    local s
    for s in 'apt-get install -y x' \
             'DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y x' \
             'out=$(apt-get -o Dpkg::Options::=--force-confask install -y x)' \
             'apt-get dist-upgrade -y' 'apt full-upgrade -y' 'apt-get purge -y x' \
             'true || DEBIAN_FRONTEND=noninteractive apt install -y x' \
             'r="$(id -u)"; apt-get install -y x "$p"' 'x=""; apt-get purge -y foo "$p"' \
             'eval "apt-get install -y $p"' 'bash -c "apt-get install -y x"' \
             'restore_out="$(DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" 2>&1)"'; do
        [ -n "$(printf '%s\n' "$s" | strip_messages | grep -oE "$APT_RE")" ] || { echo "not found: $s"; return 1; }
    done
    for s in 'if dpkg --configure -a; then' 'out=$(dpkg --configure -a 2>&1)' \
             'timeout 600 dpkg --configure -a' 'x || dpkg --force-confold --configure -a'; do
        [ -n "$(printf '%s\n' "$s" | strip_messages | grep -oE "$DPKG_RE")" ] || { echo "not found: $s"; return 1; }
    done
    # message text is cut out, the call before a message on the same line stays
    for s in 'log_warn "run: apt-get install -y x"' 'die "do: sudo apt-get purge -y x"' \
             '        tools_old) fix="apt-get install --only-upgrade x" ;;' \
             'local _dfix="sudo apt install linux-headers-$rel"' \
             'printf '"'%s'"' "apt-get update && apt-get install x"'; do
        [ -z "$(printf '%s\n' "$s" | strip_messages | grep -oE "$APT_RE")" ] || { echo "message seen as a call: $s"; return 1; }
    done
    [ -n "$(printf '%s\n' 'apt-get purge -y x || log_warn "purge failed"' | strip_messages | grep -oE "$APT_RE")" ]
    # names that only end like a caller or a hint are code, not messages
    for s in 'mkdir -p /var/log && apt-get install -y x' 'prefix="$(apt-get install -y x)"' \
             '_die_upgrade_failed; apt-get install -y x'; do
        [ -n "$(printf '%s\n' "$s" | strip_messages | grep -oE "$APT_RE")" ] || { echo "code cut as a message: $s"; return 1; }
    done
    # the known boundary: a call after a message on the same line is cut here,
    # and only the uncut count above sees it
    [ -z "$(printf '%s\n' 'echo "x"; apt-get install -y y' | strip_messages | grep -oE "$APT_RE")" ]
    [ -n "$(printf '%s\n' 'echo "x"; apt-get install -y y' | grep -oE "$APT_RE")" ]
}

@test "conffile: install_packages runs apt noninteractive with the options, both installers" {
    local f body
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        body=$(awk '/^install_packages\(\) \{/,/^\}$/' "$BATS_TEST_DIRNAME/../$f")
        [ -n "$body" ]
        mkdir -p "$BATS_TEST_TMPDIR/bin"
        printf '#!/bin/bash\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/dpkg-query"
        printf '#!/bin/bash\necho "${DEBIAN_FRONTEND:-UNSET} $*" > "%s/apt-args"\nexit 0\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/apt"
        chmod +x "$BATS_TEST_TMPDIR/bin/dpkg-query" "$BATS_TEST_TMPDIR/bin/apt"
        rm -f "$BATS_TEST_TMPDIR/apt-args"
        run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" LOG_FILE=/dev/null timeout 30 bash -c \
            'log() { :; }; log_warn() { :; }; die() { echo "DIE $*"; exit 1; }; _APT_UPDATED=1; _install_temp_files=(); eval "$1"; install_packages curl' _ "$body"
        [ "$status" -eq 0 ] || { echo "$f: $status $output"; return 1; }
        [ "$(cat "$BATS_TEST_TMPDIR/apt-args")" = "noninteractive $APT_KEEP -o Apt::Cmd::Disable-Script-Warning=true install -y curl" ] \
            || { echo "$f: apt got: $(cat "$BATS_TEST_TMPDIR/apt-args")"; return 1; }
    done
}

@test "conffile: the kernel headers install in the library runs noninteractive with the options, both libraries" {
    local f body
    for f in awg_common.sh awg_common_en.sh; do
        body=$(awk '/^_install_kernel_headers\(\) \{/,/^\}$/' "$BATS_TEST_DIRNAME/../$f")
        [ -n "$body" ]
        mkdir -p "$BATS_TEST_TMPDIR/bin"
        printf '#!/bin/bash\necho "${DEBIAN_FRONTEND:-UNSET} $*" >> "%s/apt-get-args"\nexit 0\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/apt-get"
        chmod +x "$BATS_TEST_TMPDIR/bin/apt-get"
        rm -f "$BATS_TEST_TMPDIR/apt-get-args"
        run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" AWG_ALLOW_APT_IN_ENSURE=1 OS_ID=ubuntu timeout 30 bash -c \
            'log() { :; }; log_warn() { :; }; log_error() { echo "ERR $*"; }; eval "$1"; _install_kernel_headers 6.8.0-151-generic' _ "$body"
        [ "$status" -eq 0 ] || { echo "$f: $status $output"; return 1; }
        [ "$(head -1 "$BATS_TEST_TMPDIR/apt-get-args")" = "noninteractive $APT_KEEP install -y linux-headers-6.8.0-151-generic" ] \
            || { echo "$f: apt-get got: $(cat "$BATS_TEST_TMPDIR/apt-get-args")"; return 1; }
    done
}
