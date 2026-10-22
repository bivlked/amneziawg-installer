#!/usr/bin/env bats
# Step 2 failures must leave their cause in the log and on screen:
#   - a failed apt install copies the tail of apt's output into the install
#     log (I#368: the log held only "package installation error");
#   - before blaming a Launchpad outage, step 2 checks whether the server
#     resolves names at all (I#299: DNS was down for every source);
#   - cloning the pinned module source keeps git's own error text and never
#     waits for a login prompt (D#255).
# Every case runs on both installers.

load test_helper

INSTALLERS=(install_amneziawg.sh install_amneziawg_en.sh)

_fn() { sed -n "/^$2() {\$/,/^}\$/p" "$BATS_TEST_DIRNAME/../$1"; }
_stub() { printf '#!/bin/bash\n%s\n' "$2" > "$T/bin/$1"; chmod +x "$T/bin/$1"; }
_ru() { [[ "$1" == install_amneziawg.sh ]]; }

setup() {
    T=$(mktemp -d); export T
    mkdir -p "$T/bin"
    # Temp files made by the code under test land here and go with teardown.
    export TMPDIR="$T"
    # dpkg-query: nothing installed, so every requested package goes to apt.
    _stub dpkg-query 'echo "dpkg-query: no packages found matching ${*: -1}" >&2; exit 1'
    export PATH="$T/bin:$PATH"
}

teardown() { rm -rf "$T"; }

# ---------- apt install output in the log ----------

# apt stub: without the script-warning option it complains the way apt does
# when its output is not a terminal; then it prints $T/apt.out and exits
# with $T/apt.rc.
_apt_stub() { _stub apt 'case " $* " in *" Apt::Cmd::Disable-Script-Warning=true "*) ;; *) echo "WARNING: apt does not have a stable CLI interface. Use with caution in scripts." >&2 ;; esac
cat "$T/apt.out" 2>/dev/null
[[ -f "$T/apt.err" ]] && cat "$T/apt.err" >&2
exit "$(cat "$T/apt.rc" 2>/dev/null || echo 0)"'; }

# A driver that runs install_packages from installer $1 with the T1 flag $2
# (default 0: a failed apt goes straight to die).
_pkg_driver() {
    {
        echo 'log() { echo "LOG: $*"; }; log_warn() { echo "WARN: $*"; }; die() { echo "DIE: $*"; exit 1; }'
        echo 'apt_update_tolerant() { :; }; _install_temp_files=(); _APT_UPDATED=1'
        echo "_AWG_KMOD_T1=${2:-0}; LOG_FILE=$T/log; AWG_ENSURE_HELPER=$T/bin/helper"
        echo '_pkg_present() { return 0; }; _pkgs_installed_ok() { return 0; }'
        _fn "$1" install_packages
        echo 'install_packages "$@"'
    } > "$T/drv.sh"
}

_apt_header() { if _ru "$1"; then echo "--- apt install (код $2), последние 40 строк вывода ---"; else echo "--- apt install (exit $2), last 40 lines of output ---"; fi; }

@test "apt install failure: the tail of apt output lands in the install log" {
    local f
    _apt_stub
    echo "Reading package lists..." > "$T/apt.out"
    echo "E: Failed to fetch http://ppa.example/pool/x.deb  Connection timed out" > "$T/apt.err"
    echo 100 > "$T/apt.rc"
    for f in "${INSTALLERS[@]}"; do
        rm -f "$T/log"
        _pkg_driver "$f"
        run bash "$T/drv.sh" amneziawg-dkms qrencode
        [ "$status" -eq 1 ] || { echo "$f: $output"; return 1; }
        [[ "$output" == *DIE:* ]] || { echo "$f: $output"; return 1; }
        # Still on screen as before.
        grep -qxF 'E: Failed to fetch http://ppa.example/pool/x.deb  Connection timed out' <<<"$output" || { echo "$f: not on screen: $output"; return 1; }
        # And now in the log, stdout and stderr both, under a header with the exit code.
        grep -qxF -- "$(_apt_header "$f" 100)" "$T/log" || { echo "$f: no header"; cat "$T/log"; return 1; }
        grep -qxF 'E: Failed to fetch http://ppa.example/pool/x.deb  Connection timed out' "$T/log" || { echo "$f: apt stderr not in the log"; cat "$T/log"; return 1; }
        grep -qxF 'Reading package lists...' "$T/log" || { echo "$f: apt stdout not in the log"; return 1; }
    done
}

@test "apt install failure: only the last 40 lines go to the log" {
    local f
    _apt_stub
    seq -f 'apt line %g' 1 100 > "$T/apt.out"
    echo 100 > "$T/apt.rc"
    for f in "${INSTALLERS[@]}"; do
        rm -f "$T/log"
        _pkg_driver "$f"
        run bash "$T/drv.sh" qrencode
        [ "$status" -eq 1 ]
        grep -qx 'apt line 100' "$T/log" || { echo "$f: last line missing"; return 1; }
        grep -qx 'apt line 61' "$T/log" || { echo "$f: line 61 missing"; return 1; }
        ! grep -qx 'apt line 60' "$T/log" || { echo "$f: more than 40 lines"; return 1; }
    done
}

@test "apt install: no script WARNING from apt, and nothing copied to the log on success" {
    local f
    _apt_stub
    echo "Setting up qrencode ..." > "$T/apt.out"
    echo 0 > "$T/apt.rc"
    for f in "${INSTALLERS[@]}"; do
        rm -f "$T/log"; : > "$T/log"
        _pkg_driver "$f"
        run bash "$T/drv.sh" qrencode
        [ "$status" -eq 0 ] || { echo "$f: $output"; return 1; }
        grep -qxF 'Setting up qrencode ...' <<<"$output" || { echo "$f: $output"; return 1; }
        [[ "$output" != *"does not have a stable CLI interface"* ]] || { echo "$f: apt script warning shown"; return 1; }
        ! grep -qF 'Setting up qrencode ...' "$T/log" || { echo "$f: apt output copied on success"; return 1; }
    done
}

@test "apt install failure on the module fallback path: apt tail is logged before the helper output" {
    local f a h
    _apt_stub
    echo "E: Sub-process /usr/bin/dpkg returned an error code (1)" > "$T/apt.err"
    echo 100 > "$T/apt.rc"
    _stub helper 'echo "helper $1 ok"; exit 0'
    for f in "${INSTALLERS[@]}"; do
        rm -f "$T/log"
        _pkg_driver "$f" 1
        run bash "$T/drv.sh" amneziawg-dkms
        [ "$status" -eq 0 ] || { echo "$f: $output"; return 1; }
        a=$(grep -nxF -- "$(_apt_header "$f" 100)" "$T/log" | cut -d: -f1)
        h=$(grep -nxF -- '--- amneziawg-ensure-module ---' "$T/log" | cut -d: -f1)
        [ -n "$a" ] && [ -n "$h" ] && [ "$a" -lt "$h" ] || { echo "$f: a=$a h=$h"; cat "$T/log"; return 1; }
        grep -qxF 'E: Sub-process /usr/bin/dpkg returned an error code (1)' "$T/log"
    done
}

@test "apt install failure without a temp file: a warning, apt output still on screen, then die" {
    local f w
    _apt_stub
    echo "E: Unable to locate package qrencode" > "$T/apt.err"
    echo 100 > "$T/apt.rc"
    _stub mktemp 'exit 1'
    for f in "${INSTALLERS[@]}"; do
        rm -f "$T/log"
        _pkg_driver "$f"
        run bash "$T/drv.sh" qrencode
        [ "$status" -eq 1 ]; [[ "$output" == *DIE:* ]]
        grep -qxF 'E: Unable to locate package qrencode' <<<"$output" || { echo "$f: $output"; return 1; }
        if _ru "$f"; then w='WARN: Не удалось создать временный файл: вывод apt в журнал не попал, он только на экране выше.'
        else w='WARN: Could not create a temp file: the apt output did not reach the log, it is only on screen above.'; fi
        grep -qxF "$w" <<<"$output" || { echo "$f: $output"; return 1; }
        ! grep -q -- '--- apt install' "$T/log" 2>/dev/null
    done
}

# ---------- DNS check before the Launchpad outage message ----------

# getent stub: $T/rc.<name> forces an exit code (124 = timed out, 1 = tool
# trouble); otherwise a name listed in $T/resolves resolves and anything else
# is "not found" (exit 2). apt-config stub prints $T/aptconf (no proxy by default).
_getent_stub() {
    _stub getent '[[ "$1" == ahosts ]] || exit 1
[[ -f "$T/rc.$2" ]] && exit "$(cat "$T/rc.$2")"
grep -qx "$2" "$T/resolves" 2>/dev/null && { echo "192.0.2.1 $2"; exit 0; }
exit 2'
    _stub apt-config 'cat "$T/aptconf" 2>/dev/null; exit 0'
}

# The verdict function of installer $1 on OS $2, with no proxy in the
# environment unless the test sets one through $3 ("name=value").
_verdict() {
    local f=$1 os=$2
    env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY ${3:+"$3"} \
        bash -c "OS_ID=$os; $(_fn "$f" _ppa_dns_verdict); _ppa_dns_verdict"
}

@test "_ppa_dns_verdict: the PPA name resolves -> nothing printed (outage remains the guess)" {
    local f
    _getent_stub
    for f in "${INSTALLERS[@]}"; do
        printf '%s\n' ppa.launchpadcontent.net archive.ubuntu.com > "$T/resolves"
        run _verdict "$f" ubuntu
        [ "$status" -eq 0 ]; [ -z "$output" ] || { echo "$f: '$output'"; return 1; }
        # Only the PPA name is asked when it resolves.
        echo ppa.launchpadcontent.net > "$T/resolves"
        run _verdict "$f" ubuntu
        [ "$status" -eq 0 ]; [ -z "$output" ] || { echo "$f: '$output'"; return 1; }
    done
}

@test "_ppa_dns_verdict: nothing resolves -> dns-all with the distro mirror" {
    local f
    _getent_stub
    : > "$T/resolves"
    for f in "${INSTALLERS[@]}"; do
        run _verdict "$f" ubuntu
        [ "$output" = "dns-all archive.ubuntu.com" ] || { echo "$f: '$output'"; return 1; }
        run _verdict "$f" debian
        [ "$output" = "dns-all deb.debian.org" ] || { echo "$f: '$output'"; return 1; }
    done
}

@test "_ppa_dns_verdict: only the PPA name fails -> dns-ppa with the distro mirror" {
    local f
    _getent_stub
    printf '%s\n' archive.ubuntu.com deb.debian.org > "$T/resolves"
    for f in "${INSTALLERS[@]}"; do
        run _verdict "$f" ubuntu
        [ "$output" = "dns-ppa archive.ubuntu.com" ] || { echo "$f: '$output'"; return 1; }
        run _verdict "$f" debian
        [ "$output" = "dns-ppa deb.debian.org" ] || { echo "$f: '$output'"; return 1; }
    done
}

@test "_ppa_dns_verdict: an apt proxy (environment or apt config) gives no verdict" {
    local f
    _getent_stub
    : > "$T/resolves"
    for f in "${INSTALLERS[@]}"; do
        run _verdict "$f" ubuntu "https_proxy=http://10.0.0.1:3128"
        [ "$status" -eq 0 ]; [ -z "$output" ] || { echo "$f env: '$output'"; return 1; }
        echo 'Acquire::http::Proxy "http://10.0.0.1:3128";' > "$T/aptconf"
        run _verdict "$f" ubuntu
        [ -z "$output" ] || { echo "$f apt-config: '$output'"; return 1; }
        echo 'Acquire::https::Proxy::ppa.launchpadcontent.net "http://10.0.0.1:3128";' > "$T/aptconf"
        run _verdict "$f" ubuntu
        [ -z "$output" ] || { echo "$f per-host: '$output'"; return 1; }
        echo 'Acquire::http::Proxy-Auto-Detect "/usr/local/bin/find-proxy";' > "$T/aptconf"
        run _verdict "$f" ubuntu
        [ -z "$output" ] || { echo "$f auto-detect: '$output'"; return 1; }
        echo 'Acquire::http::ProxyAutoDetect "/usr/local/bin/find-proxy";' > "$T/aptconf"
        run _verdict "$f" ubuntu
        [ -z "$output" ] || { echo "$f legacy auto-detect: '$output'"; return 1; }
        rm -f "$T/aptconf"
    done
}

@test "_ppa_dns_verdict: DIRECT, false or an empty proxy value still gives a verdict" {
    local f
    _getent_stub
    : > "$T/resolves"
    printf '%s\n' 'Acquire::http::Proxy::archive.ubuntu.com "DIRECT";' 'Acquire::https::Proxy "false";' 'Acquire::http::Proxy "";' 'APT::Architecture "amd64";' > "$T/aptconf"
    for f in "${INSTALLERS[@]}"; do
        run _verdict "$f" ubuntu
        [ "$output" = "dns-all archive.ubuntu.com" ] || { echo "$f: '$output'"; return 1; }
    done
}

@test "_ppa_dns_verdict: a timed-out or failed lookup gives no verdict" {
    local f
    _getent_stub
    : > "$T/resolves"
    for f in "${INSTALLERS[@]}"; do
        echo 124 > "$T/rc.ppa.launchpadcontent.net"
        run _verdict "$f" ubuntu
        [ -z "$output" ] || { echo "$f ppa 124: '$output'"; return 1; }
        echo 1 > "$T/rc.ppa.launchpadcontent.net"
        run _verdict "$f" ubuntu
        [ -z "$output" ] || { echo "$f ppa 1: '$output'"; return 1; }
        rm -f "$T/rc.ppa.launchpadcontent.net"
        echo 124 > "$T/rc.archive.ubuntu.com"
        run _verdict "$f" ubuntu
        [ -z "$output" ] || { echo "$f mirror 124: '$output'"; return 1; }
        rm -f "$T/rc.archive.ubuntu.com"
    done
}

@test "_ppa_dns_verdict: lookups wait long enough for a silent DNS (ahosts, at least 57 s, no trailing dot)" {
    # Measured on Ubuntu 24.04: three silent servers plus a search line make
    # ahosts fail after 56 s; a shorter timeout turns that into "no verdict".
    # A trailing dot would skip /etc/hosts, which apt itself reads.
    local f body t n
    for f in "${INSTALLERS[@]}"; do
        body=$(_fn "$f" _ppa_dns_verdict)
        [ "$(grep -c 'getent ahosts' <<<"$body")" -eq 2 ] || { echo "$f: expected two getent ahosts"; return 1; }
        ! grep -q 'getent hosts' <<<"$body" || { echo "$f: getent hosts is back"; return 1; }
        ! grep -q 'getent ahosts [^ ]*\. ' <<<"$body" || { echo "$f: trailing dot on a name"; return 1; }
        n=0
        while read -r t; do
            n=$((n + 1))
            [ "$t" -ge 57 ] || { echo "$f: timeout $t s is too short"; return 1; }
        done < <(sed -n 's/.*timeout \([0-9]*\) getent ahosts.*/\1/p' <<<"$body")
        [ "$n" -eq 2 ] || { echo "$f: expected two plain-second timeouts, got $n"; return 1; }
    done
}

@test "_ppa_dns_verdict: both names are asked at once, not one after the other" {
    local f s e
    _getent_stub
    # Each lookup takes 2 s and fails; in turn that would be 4 s.
    _stub getent '[[ "$1" == ahosts ]] || exit 1; sleep 2; exit 2'
    for f in "${INSTALLERS[@]}"; do
        s=$(date +%s%N)
        run _verdict "$f" ubuntu
        e=$(date +%s%N)
        [ "$output" = "dns-all archive.ubuntu.com" ] || { echo "$f: '$output'"; return 1; }
        [ $(( (e - s) / 1000000 )) -lt 3500 ] || { echo "$f: took $(( (e - s) / 1000000 )) ms"; return 1; }
    done
}

# Runs the step 2 block that reads the verdict, with a stubbed verdict $2.
_dns_block() {
    local f=$1 v=$2
    {
        echo 'log() { :; }; log_error() { echo "ERR: $*"; }; die() { echo "DIE: $*"; exit 1; }'
        echo "_ppa_dns_verdict() { echo '$v'; }"
        echo 'blk() {'
        awk '/^        local _dns_v _dns_m$/{on=1} on{print} on && /^        esac$/{exit}' "$BATS_TEST_DIRNAME/../$f"
        echo 'echo AFTER; }; blk'
    } > "$T/blk.sh"
    bash "$T/blk.sh"
}

@test "step 2 DNS verdict: dns-all names the server DNS and the mirror from the verdict, then dies" {
    local f
    for f in "${INSTALLERS[@]}"; do
        run _dns_block "$f" "dns-all deb.debian.org"
        [ "$status" -eq 1 ] || { echo "$f: $output"; return 1; }
        if _ru "$f"; then
            grep -qxF 'ERR: Сервер не может разрешить ни ppa.launchpadcontent.net, ни deb.debian.org: не работает DNS на самом сервере, Launchpad тут ни при чём.' <<<"$output"
            grep -qxF 'ERR: Проверьте: cat /etc/resolv.conf и getent hosts deb.debian.org. Когда имена начнут разрешаться, запустите скрипт снова той же командой.' <<<"$output"
            grep -qxF 'DIE: DNS на сервере не работает.' <<<"$output"
        else
            grep -qxF 'ERR: The server cannot resolve either ppa.launchpadcontent.net or deb.debian.org: DNS on the server itself is broken, Launchpad is not the cause.' <<<"$output"
            grep -qxF 'ERR: Check: cat /etc/resolv.conf and getent hosts deb.debian.org. Once names resolve, re-run the script with the same command.' <<<"$output"
            grep -qxF 'DIE: DNS on the server does not work.' <<<"$output"
        fi
        [[ "$output" != *AFTER* ]]
    done
}

@test "step 2 DNS verdict: dns-ppa names the PPA and the mirror from the verdict, then dies" {
    local f
    for f in "${INSTALLERS[@]}"; do
        run _dns_block "$f" "dns-ppa archive.ubuntu.com"
        [ "$status" -eq 1 ] || { echo "$f: $output"; return 1; }
        if _ru "$f"; then
            grep -qxF 'ERR: Имя ppa.launchpadcontent.net не разрешается, хотя archive.ubuntu.com разрешается: DNS-сервер, который указан у сервера, не отдаёт адрес PPA.' <<<"$output"
            grep -qxF 'DIE: Имя PPA Amnezia не разрешается.' <<<"$output"
        else
            grep -qxF 'ERR: ppa.launchpadcontent.net does not resolve although archive.ubuntu.com does: the DNS server configured on this server does not return the PPA address.' <<<"$output"
            grep -qxF 'DIE: The Amnezia PPA name does not resolve.' <<<"$output"
        fi
        [[ "$output" != *AFTER* ]]
    done
}

@test "step 2 DNS verdict: an empty verdict falls through to the outage text" {
    local f
    for f in "${INSTALLERS[@]}"; do
        run _dns_block "$f" ""
        [ "$status" -eq 0 ] || { echo "$f: $output"; return 1; }
        [ "$output" = "AFTER" ] || { echo "$f: '$output'"; return 1; }
    done
}

@test "step 2: the DNS verdict is read after the PPA wait and before the outage text" {
    local f s w v o
    for f in "${INSTALLERS[@]}"; do
        s=$(cat "$BATS_TEST_DIRNAME/../$f")
        w=$(grep -n -m1 -F 'if ! apt_wait_for_ppa_package amneziawg-dkms 3 30; then' <<<"$s" | cut -d: -f1)
        v=$(grep -n -m1 -F 'read -r _dns_v _dns_m <<<"$(_ppa_dns_verdict)"' <<<"$s" | cut -d: -f1)
        o=$(grep -n -m1 -E 'log_error "(Похоже, ppa\.launchpadcontent\.net|ppa\.launchpadcontent\.net appears)' <<<"$s" | cut -d: -f1)
        [ -n "$w" ] && [ -n "$v" ] && [ -n "$o" ] || { echo "$f: w=$w v=$v o=$o"; return 1; }
        [ "$w" -lt "$v" ] && [ "$v" -lt "$o" ] || { echo "$f: order w=$w v=$v o=$o"; return 1; }
    done
}

# ---------- git clone of the pinned module source ----------

_clone_driver() {
    {
        echo 'log() { echo "LOG: $*"; }; log_warn() { echo "WARN: $*"; }; log_error() { echo "ERR: $*"; }'
        echo 'AWG2_PIN_TAG=v1.0.test; AWG2_PIN_COMMIT=0000000000000000000000000000000000000000'
        _fn "$1" _install_pinned_awg2_module
        echo '_install_pinned_awg2_module'
    } > "$T/drv.sh"
}

@test "pinned module clone: git error text is shown and no login prompt is allowed" {
    local f last
    _stub uname 'echo 6.1.0-test'
    _stub git 'echo "GIT_TERMINAL_PROMPT=${GIT_TERMINAL_PROMPT:-unset}" >> "$T/git.env"
echo "GIT_ASKPASS=${GIT_ASKPASS:-unset}" >> "$T/git.env"
if read -r -t 1 _x; then echo "stdin had data" >> "$T/git.env"; fi
echo "Cloning into ..." >&2
echo "fatal: unable to access '"'"'https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git/'"'"': Could not resolve host: github.com" >&2
exit 128'
    # A caller environment that allows prompts must not leak into the clone.
    export GIT_TERMINAL_PROMPT=1 GIT_ASKPASS=/usr/bin/ssh-askpass
    for f in "${INSTALLERS[@]}"; do
        rm -f "$T/git.env"
        _clone_driver "$f"
        run bash "$T/drv.sh" <<<"typed-password"
        [ "$status" -eq 1 ] || { echo "$f: $output"; return 1; }
        grep -qxF "ERR:   git: fatal: unable to access 'https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git/': Could not resolve host: github.com" <<<"$output" || { echo "$f: git error not shown: $output"; return 1; }
        if _ru "$f"; then last='ERR: Проверьте доступ к github.com.'; else last='ERR: Check access to github.com.'; fi
        [ "$(tail -n 1 <<<"$output")" = "$last" ] || { echo "$f: last line: $(tail -n 1 <<<"$output")"; return 1; }
        grep -qx 'GIT_TERMINAL_PROMPT=0' "$T/git.env" || { echo "$f: $(cat "$T/git.env")"; return 1; }
        grep -qx 'GIT_ASKPASS=/bin/true' "$T/git.env" || { echo "$f: $(cat "$T/git.env")"; return 1; }
        ! grep -q 'stdin had data' "$T/git.env" || { echo "$f: git inherited stdin"; return 1; }
        if _ru "$f"; then
            grep -qxF "ERR: Не удалось клонировать https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git (тег v1.0.test), git вернул код 128. Ответ git:" <<<"$output"
        else
            grep -qxF "ERR: Failed to clone https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git (tag v1.0.test), git exited with 128. git said:" <<<"$output"
        fi
    done
}

@test "pinned module clone: git killed without output still says so, with its exit code" {
    local f
    _stub uname 'echo 6.1.0-test'
    _stub git 'exit 137'
    for f in "${INSTALLERS[@]}"; do
        _clone_driver "$f"
        run bash "$T/drv.sh"
        [ "$status" -eq 1 ] || { echo "$f: $output"; return 1; }
        if _ru "$f"; then
            grep -qF 'git вернул код 137' <<<"$output" || { echo "$f: $output"; return 1; }
            grep -qxF 'ERR:   git: вывода нет' <<<"$output" || { echo "$f: $output"; return 1; }
        else
            grep -qF 'git exited with 137' <<<"$output" || { echo "$f: $output"; return 1; }
            grep -qxF 'ERR:   git: no output' <<<"$output" || { echo "$f: $output"; return 1; }
        fi
    done
}
