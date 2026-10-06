#!/usr/bin/env bats
# docs/support-matrix.json is the single source of truth for the supported OS set.
# These tests tie the installer and the ARM build to it, in both directions, and
# check what check_os_version actually does on a release outside the set (Ubuntu
# 25.10 since v6.0.0: out of vendor support, warned about, not refused).

setup() {
    ROOT="${BATS_TEST_DIRNAME}/.."
    MATRIX="$ROOT/docs/support-matrix.json"
    WF="$ROOT/.github/workflows/arm-build.yml"
    [ -f "$MATRIX" ] && [ -f "$WF" ]
}

# Matrix platforms as "os:version" lines, sorted.
_matrix_set() {
    python3 -c "
import io, json, sys
d = json.load(io.open(sys.argv[1], encoding='utf-8'))
print('\n'.join(sorted('%s:%s' % (p['os'], p['version']) for p in d['platforms'])))
" "$MATRIX"
}

# The literals check_os_version accepts, as "os:version" lines, sorted.
_installer_set() { # file
    awk '/^check_os_version\(\) \{$/,/^}$/' "$1" | awk '
        /^[[:space:]]*ubuntu\)/ { fam = "ubuntu" }
        /^[[:space:]]*debian\)/ { fam = "debian" }
        /;;/ { fam = "" }
        fam != "" {
            line = $0
            while (match(line, /"\$OS_VERSION" == "[^"]+"/)) {
                v = substr(line, RSTART, RLENGTH); sub(/.*== "/, "", v); sub(/"$/, "", v)
                print fam ":" v
                line = substr(line, RSTART + RLENGTH)
            }
        }' | sort
}

# Run check_os_version from <installer> against a fake os-release.
# $1 installer, $2 ID, $3 VERSION_ID, $4 codename, $5 AUTO_YES
_run_os_check() {
    local inst="$1" rel
    rel="$BATS_TEST_TMPDIR/os-release"
    printf 'ID=%s\nVERSION_ID="%s"\nVERSION_CODENAME=%s\n' "$2" "$3" "$4" > "$rel"
    local body
    body=$(awk '/^check_os_version\(\) \{$/,/^}$/' "$inst" \
        | sed -e "s|/etc/os-release|$rel|g" -e 's|< /dev/tty|< /dev/null|g')
    [ -n "$body" ] || return 99
    AUTO_YES="$5" bash -c '
        log() { echo "LOG: $*"; }
        log_warn() { echo "WARN: $*"; }
        die() { echo "DIE: $*"; exit 1; }
        eval "$1"
        check_os_version
        echo "RETURNED OS=$OS_ID $OS_VERSION"
    ' _ "$body"
}

@test "matrix: every version comparison in check_os_version is one the parser reads (RU + EN)" {
    # The set below only sees "$OS_VERSION" == "X"; a version added in another
    # form ("${OS_VERSION}", a single =, =~, a nested case) would slip past the
    # "code wider than the matrix" direction. So every mention of OS_VERSION
    # inside the outer `case "$OS_ID" in ... esac` block must be one the parser
    # read, and `supported=1` may only be set inside that block.
    local f fn blk n_eq n_read
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        fn=$(awk '/^check_os_version\(\) \{$/,/^}$/' "$ROOT/$f")
        blk=$(sed -n '/^    case "\$OS_ID" in$/,/^    esac$/p' <<<"$fn")
        [ -n "$blk" ] || { echo "$f: outer case block not found"; false; }
        n_eq=$(grep -o 'OS_VERSION' <<<"$blk" | wc -l)
        n_read=$(_installer_set "$ROOT/$f" | wc -l)
        [ "$n_eq" -gt 0 ] && [ "$n_eq" -eq "$n_read" ] || { echo "$f: mentions $n_eq, parsed $n_read"; false; }
        [ "$(grep -c 'supported=1' <<<"$fn")" -eq "$(grep -c 'supported=1' <<<"$blk")" ] \
            || { echo "$f: supported=1 set outside the case block"; false; }
    done
}

@test "matrix: check_os_version literals equal the matrix platforms, both ways (RU)" {
    run diff <(_matrix_set) <(_installer_set "$ROOT/install_amneziawg.sh")
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ -n "$(_installer_set "$ROOT/install_amneziawg.sh")" ]
}

@test "matrix: check_os_version literals equal the matrix platforms, both ways (EN)" {
    run diff <(_matrix_set) <(_installer_set "$ROOT/install_amneziawg_en.sh")
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ -n "$(_installer_set "$ROOT/install_amneziawg_en.sh")" ]
}

@test "matrix: arm_prebuilt_targets equal the arm-build.yml job ids, both ways" {
    local m w
    m=$(python3 -c "
import io, json, sys
d = json.load(io.open(sys.argv[1], encoding='utf-8'))
print('\n'.join(sorted({t for p in d['platforms'] for t in p['arm_prebuilt_targets']})))
" "$MATRIX")
    w=$(grep -oE '^[[:space:]]*- id: [a-z0-9-]+' "$WF" | sed 's/.*id: //' | sort -u)
    [ -n "$m" ] && [ -n "$w" ]
    [ "$m" = "$w" ] || { echo "matrix: $m"; echo "workflow: $w"; false; }
}

@test "check_os_version: Ubuntu 25.10 is warned about, and --yes carries on (RU + EN)" {
    local f
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run _run_os_check "$ROOT/$f" ubuntu 25.10 questing 1
        [ "$status" -eq 0 ] || { echo "$f: $output"; false; }
        [[ "$output" == *"WARN:"*"25.10"* ]] || { echo "$f: no warning: $output"; false; }
        [[ "$output" == *"RETURNED OS=ubuntu 25.10"* ]]
        [[ "$output" != *"DIE:"* ]]
    done
}

@test "check_os_version: Ubuntu 25.10 without --yes asks and stops on no answer (RU + EN)" {
    local f
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run _run_os_check "$ROOT/$f" ubuntu 25.10 questing 0
        [ "$status" -ne 0 ]
        [[ "$output" == *"WARN:"*"25.10"* ]]
        [[ "$output" == *"DIE:"* ]] || { echo "$f: $output"; false; }
    done
}

# --- A prebuilt module package left for the running kernel (e.g. on 25.10, whose
# --- packages are no longer built) must stop the DKMS fallback: two module trees.

# Run _awg_prebuilt_for_running_kernel from <installer> with stubbed dpkg tools.
# Fake packages: name|status|files ("FAIL" = dpkg -L fails), one per line in $PKGS.
_run_prebuilt_probe() { # installer kernel
    local body
    body=$(awk '/^_awg_prebuilt_for_running_kernel\(\) \{$/,/^}$/' "$1")
    [ -n "$body" ] || return 99
    KREL="$2" bash -c '
        uname() { printf "%s\n" "$KREL"; }
        dpkg-query() { while IFS="|" read -r n s _; do [ -n "$n" ] && printf "%s %s\n" "$n" "$s"; done <<<"$PKGS"; }
        dpkg() {
            [ "$1" = "-L" ] || return 2
            local n s f
            while IFS="|" read -r n s f; do
                if [ "$n" = "$2" ]; then
                    [ "$f" = FAIL ] && return 1
                    tr "," "\n" <<<"$f"; return 0
                fi
            done <<<"$PKGS"
            return 1
        }
        eval "$1"
        _awg_prebuilt_for_running_kernel
    ' _ "$body"
}

@test "prebuilt leftover: only packages carrying a module for the running kernel are named (RU + EN)" {
    local f
    export PKGS="amneziawg-kmod-ubuntu-2510-arm64|install ok installed|/lib/modules/6.17.0-5-generic/extra/amneziawg.ko
amneziawg-kmod-usr|install ok installed|/usr/lib/modules/6.17.0-5-generic/updates/amneziawg.ko
amneziawg-kmod-old|install ok installed|/lib/modules/6.17.0-4-generic/extra/amneziawg.ko
amneziawg-kmod-unreadable|install ok half-configured|FAIL
amneziawg-kmod-gone|deinstall ok config-files|/lib/modules/6.17.0-5-generic/extra/amneziawg.ko
amneziawg-kmod-purged|unknown ok not-installed|FAIL
amneziawg-kmod-64k|install ok installed|/lib/modules/6.17.0-5-generic-64k/extra/amneziawg.ko"
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run _run_prebuilt_probe "$ROOT/$f" 6.17.0-5-generic
        [ "$status" -eq 0 ] || { echo "$f: rc=$status $output"; false; }
        [ "$output" = "amneziawg-kmod-ubuntu-2510-arm64 amneziawg-kmod-usr amneziawg-kmod-unreadable" ] \
            || { echo "$f: got '$output'"; false; }
    done
}

@test "prebuilt leftover: kernel names are matched literally, not as a pattern (RU + EN)" {
    local f
    # '+' and '.' in a Raspberry Pi kernel name must not act as regex operators.
    export PKGS="amneziawg-kmod-rpi|install ok installed|/lib/modules/6.6.31+rpt-rpi-v8/extra/amneziawg.ko
amneziawg-kmod-near|install ok installed|/lib/modules/6.6.31rpt-rpi-v8/extra/amneziawg.ko"
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run _run_prebuilt_probe "$ROOT/$f" 6.6.31+rpt-rpi-v8
        [ "$output" = "amneziawg-kmod-rpi" ] || { echo "$f: got '$output'"; false; }
    done
}

@test "prebuilt leftover: nothing installed -> nothing named (RU + EN)" {
    local f
    export PKGS=""
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run _run_prebuilt_probe "$ROOT/$f" 6.17.0-5-generic
        [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$f: got '$output'"; false; }
    done
}

@test "prebuilt leftover: the DKMS fallback in step 2 stops on it with the purge command (RU + EN)" {
    local f body tail
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        body=$(sed -n '/^step2_install_amnezia() {$/,/^}$/p' "$ROOT/$f")
        [ -n "$body" ]
        # The check sits in the else branch of the prebuilt attempt, before the
        # DKMS path starts installing packages.
        tail=$(awk '/^[[:space:]]+elif _try_install_prebuilt_arm; then/{on=1} on' <<<"$body" \
            | awk '/^        else$/{on=1} on' | sed '/^    fi$/q')
        grep -qF '_kmod_here=$(_awg_prebuilt_for_running_kernel)' <<<"$tail" \
            || { echo "$f: no leftover check in the fallback branch"; false; }
        grep -qE 'die .*apt-get purge -y \$_kmod_here' <<<"$tail" \
            || { echo "$f: no stop with the purge command"; false; }
    done
}

@test "prebuilt leftover: the fallback stops only when the helper names a package (RU + EN, behaviour)" {
    # Runs the guard block itself, so an inverted condition is caught, not only
    # the presence of the text.
    local f blk
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        blk=$(sed -n '/^step2_install_amnezia() {$/,/^}$/p' "$ROOT/$f" \
            | sed -n '/^            local _kmod_here$/,/^            fi$/p')
        [ -n "$blk" ] || { echo "$f: guard block not found"; false; }
        unset LEFT
        run bash -c 'die() { echo "DIE: $*"; exit 1; }
            _awg_prebuilt_for_running_kernel() { printf "%s" "$LEFT"; }
            g() { eval "$1"; echo CONTINUED; }; g "$1"' _ "$blk"
        # LEFT unset -> nothing in the way -> the DKMS path goes on
        [ "$status" -eq 0 ] && [[ "$output" == *CONTINUED* ]] || { echo "$f none: $output"; false; }
        export LEFT=amneziawg-kmod-ubuntu-2510-arm64
        run bash -c 'die() { echo "DIE: $*"; exit 1; }
            _awg_prebuilt_for_running_kernel() { printf "%s" "$LEFT"; }
            g() { eval "$1"; echo CONTINUED; }; g "$1"' _ "$blk"
        [ "$status" -ne 0 ] && [[ "$output" == *"DIE:"*"apt-get purge -y amneziawg-kmod-ubuntu-2510-arm64"* ]] \
            && [[ "$output" != *CONTINUED* ]] || { echo "$f leftover: $output"; false; }
    done
}

@test "check_os_version: behaviour follows the matrix, whatever the syntax (RU + EN)" {
    # Every matrix platform passes silently; neighbours outside it are warned
    # about. Catches a version added under another variable (VERSION_ID,
    # OS_CODENAME), outside the case block or as a new family branch, which no
    # text check of the function sees.
    local f line os ver
    local -a outside=("ubuntu 25.10 questing" "ubuntu 24.10 oracular" "ubuntu 22.04 jammy"
                      "debian 11 bullseye" "debian 14 forky" "raspbian 12 bookworm")
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        while IFS=: read -r os ver; do
            [ -n "$os" ] || continue
            run _run_os_check "$ROOT/$f" "$os" "$ver" x 0
            [ "$status" -eq 0 ] && [[ "$output" != *"WARN:"* ]] || { echo "$f $os $ver (matrix): $output"; false; }
        done < <(_matrix_set)
        for line in "${outside[@]}"; do
            read -r os ver _ <<<"$line"
            run _run_os_check "$ROOT/$f" $line 1
            [ "$status" -eq 0 ] && [[ "$output" == *"WARN:"* ]] || { echo "$f $os $ver (outside): $output"; false; }
        done
    done
}

@test "check_os_version: supported releases pass without a warning (RU + EN, positive control)" {
    local f
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run _run_os_check "$ROOT/$f" ubuntu 24.04 noble 0
        [ "$status" -eq 0 ] && [[ "$output" != *"WARN:"* ]] || { echo "$f 24.04: $output"; false; }
        run _run_os_check "$ROOT/$f" ubuntu 26.04 resolute 0
        [ "$status" -eq 0 ] && [[ "$output" != *"WARN:"* ]] || { echo "$f 26.04: $output"; false; }
        run _run_os_check "$ROOT/$f" debian 13 trixie 0
        [ "$status" -eq 0 ] && [[ "$output" != *"WARN:"* ]] || { echo "$f 13: $output"; false; }
    done
}
