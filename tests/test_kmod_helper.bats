#!/usr/bin/env bats
# amneziawg-ensure-module (the helper written by both installers): the module
# source fix for kernel 7.0 (embedded upstream PR #218), the per-kernel
# build, the stamp cache and the repair modes. The helper is extracted from
# each installer and run whole under its own set -euo pipefail; its path
# constants are rewritten into a temporary tree, and dkms, modprobe, dpkg and
# friends are stubs. The dkms stub fails a 7.0.0-38 kernel the way the real
# build does (the stand's make.log line) unless compat.h is the fixed one.

load test_helper

BASE_SHA=b14346040ce0188c47e2db2baad1a4f21aa784510f6c95bbb4aa58d5bbe691c9
FIXED_SHA=8d47a358b4df0b2187788ce6f88ad63128218de1be22c78b263ef3e5d770c26b
OLD=6.8.0-100-generic
NEW=7.0.0-38-generic

_fx() { printf '%s' "$BATS_TEST_DIRNAME/fixtures/kmod/$1"; }
_sha() { sha256sum -- "$1" | cut -d' ' -f1; }
_raw_helper() { awk "/AWG_ENSURE_HELPER_EOF'/,/^AWG_ENSURE_HELPER_EOF\$/" "$BATS_TEST_DIRNAME/../$1" | sed '1d;$d'; }

# The helper from installer $1 with its path constants moved into $T.
_mk_helper() {
    local n
    _raw_helper "$1" > "$T/helper.raw"
    sed -e "s#^MODULES_DIR=/lib/modules\$#MODULES_DIR=$T/lib/modules#" \
        -e "s#^DKMS_DIR=/var/lib/dkms\$#DKMS_DIR=$T/var/lib/dkms#" \
        -e "s#^SRC_PREFIX=/usr/src\$#SRC_PREFIX=$T/usr/src#" \
        -e "s#^STAMP_DIR=/var/lib/amneziawg\$#STAMP_DIR=$T/var/lib/amneziawg#" \
        -e "s#^LOCK_DIR=/run/amneziawg\$#LOCK_DIR=$T/run/amneziawg#" \
        -e "s#^BOOT_DIR=/boot\$#BOOT_DIR=$T/boot#" \
        -e "s#^PROC_DIR=/proc\$#PROC_DIR=$T/proc#" \
        -e "s#^DPKG_DIR=/var/lib/dpkg\$#DPKG_DIR=$T/var/lib/dpkg#" \
        -e "s#^SYS_MODULE_DIR=/sys/module\$#SYS_MODULE_DIR=$T/sys/module#" \
        -e "s#^BOOT_BUDGET=280\$#BOOT_BUDGET=${BUDGET:-280}#" \
        "$T/helper.raw" > "$T/helper"
    n=$(grep -c "^[A-Z_]*_DIR=$T/\|^SRC_PREFIX=$T/" "$T/helper")
    [ "$n" -eq 9 ] || { echo "path constants rewritten: $n of 9"; return 1; }
    grep -qx "BOOT_BUDGET=${BUDGET:-280}" "$T/helper" || { echo "BOOT_BUDGET not rewritten"; return 1; }
    chmod +x "$T/helper"
    H="$T/helper"
}

_stub() { printf '#!/bin/bash\n%s\n' "$2" > "$T/bin/$1"; chmod +x "$T/bin/$1"; }

# A server: one DKMS registration amneziawg/1.0.0 with the PPA source, and
# the given kernels, each with headers and a configured image in /boot.
_mk_server() {
    local k
    mkdir -p "$T/usr/src/amneziawg-1.0.0/compat" "$T/var/lib/dkms/amneziawg/1.0.0" "$T/var/lib/dpkg"
    cp "$(_fx compat.h.base)" "$T/usr/src/amneziawg-1.0.0/compat/compat.h"
    ln -s "$T/usr/src/amneziawg-1.0.0" "$T/var/lib/dkms/amneziawg/1.0.0/source"
    mkdir -p "$T/own"; echo "amneziawg-dkms: $T/usr/src/amneziawg-1.0.0/dkms.conf" > "$T/own/dkms.conf"
    for k in "$@"; do _mk_kernel "$k"; done
}
_mk_kernel() { _mk_image "$1"; mkdir -p "$T/lib/modules/$1/hdr"; ln -s hdr "$T/lib/modules/$1/build"; }
# A kernel image in /boot owned by package linux-image-<rel> in state $2.
_mk_image() {
    mkdir -p "$T/lib/modules/$1" "$T/own" "$T/st"
    : > "$T/lib/modules/$1/modules.order"; : > "$T/boot/vmlinuz-$1"
    echo "linux-image-$1: $T/boot/vmlinuz-$1" > "$T/own/vmlinuz-$1"
    echo "${2:-install ok installed}" > "$T/st/linux-image-$1"
}
_ko() { printf '%s' "$T/lib/modules/$1/updates/dkms/amneziawg.ko.zst"; }
_put_ko() { mkdir -p "$(dirname "$(_ko "$1")")"; echo ko > "$(_ko "$1")"; }
_src() { printf '%s' "$T/usr/src/amneziawg-1.0.0/compat/compat.h"; }
_calls() { cat "$T/calls" 2>/dev/null || true; }
_stamp() { printf '%s' "$T/var/lib/amneziawg/ensure-module.stamp"; }
_hold_lock() { mkdir -p "$T/run/amneziawg"; exec {LFD}>>"$T/run/amneziawg/kmod.lock"; flock -n "$LFD"; }
# Deterministic lock races, no timing guesses: a flock wrapper marks the
# moment the helper starts WAITING (flock -w); the holder acts only after
# that mark ($1, then it releases). Every wait loop is bounded.
_signal_flock() { _stub flock "case \" \$* \" in *' -w '*) : > \"$T/flock.waiting\" ;; esac
exec \"$REAL_FLOCK\" \"\$@\""; }
_wait_file() { local i=0; while [ ! -e "$1" ] && [ "$i" -lt 400 ]; do sleep 0.05; i=$((i + 1)); done; }
_holder() {
    mkdir -p "$T/run/amneziawg"
    ( exec 9>>"$T/run/amneziawg/kmod.lock"; "$REAL_FLOCK" 9; : > "$T/held"
      _wait_file "$T/flock.waiting"; eval "${1:-:}"; sleep 0.3 ) 3>&- &
    _wait_file "$T/held"
}

setup() {
    T=$(mktemp -d); export T FIXED_SHA
    REAL_FLOCK=$(command -v flock || true)
    # What every real system has: /boot, /run, a process table.
    mkdir -p "$T/bin" "$T/boot" "$T/run" "$T/proc/1/fd" "$T/sys/module"
    command -v flock >/dev/null || { [[ -z "${CI:-}" ]] || return 1; skip "flock not available (not Linux)"; }
    command -v patch >/dev/null || { [[ -z "${CI:-}" ]] || return 1; skip "patch not installed"; }
    _stub id 'echo 0'
    _stub uname 'cat "$T/uname" 2>/dev/null || echo '"$OLD"
    _stub depmod 'echo "depmod $*" >> "$T/calls"; [[ ! -e "$T/depmod.fail" ]] || { echo "depmod: ERROR: could not open directory $T/lib/modules/$2" >&2; exit 1; }'
    _stub modprobe 'echo "modprobe $*" >> "$T/calls"
k=$(uname -r)
[[ -e "$T/modprobe.fail" ]] && exit 1
[[ -n "$(find "$T/lib/modules/$k" -name "amneziawg.ko*" -type f -size +0c 2>/dev/null)" ]] || exit 1
mkdir -p "$T/sys/module/amneziawg"'
    # Status per package from $T/st/<pkg>; amneziawg-dkms has a version too.
    # dq.listfail breaks only the pattern query (the kernel image list).
    _stub dpkg-query 'p="${*: -1}"
if [[ "$p" == *"*"* ]]; then
  [[ -e "$T/dq.listfail" ]] && { echo "dpkg-query: error: database locked" >&2; exit 2; }
  [[ -e "$T/dq.warn" ]] && echo "dpkg-query: warning: parsing file '"'"'/var/lib/dpkg/status'"'"' near line 5" >&2
  n=0; for f in "$T"/st/${p}; do [[ -f "$f" ]] || continue; echo "${f##*/} $(cat "$f")"; n=1; done
  [[ $n = 1 ]] || { echo "dpkg-query: no packages found matching $p" >&2; exit 1; }; exit 0
fi
[[ "$p" == amneziawg-dkms && -e "$T/dq.dkmsfail" ]] && { echo "dpkg-query: error: database locked" >&2; exit 2; }
[[ "$p" == linux-image-* && -e "$T/dq.imgfail" ]] && { echo "dpkg-query: error: database locked" >&2; exit 2; }
if [[ -f "$T/st/$p" ]]; then cat "$T/st/$p"
elif [[ "$p" == amneziawg-dkms ]]; then echo "1.0.0-0~202609061402+4569c4c install ok installed"
else echo "unknown ok not-installed"; fi'
    _stub dpkg 'case "$1" in
  -S) [[ -e "$T/S.fail" ]] && { echo "dpkg-query: error: cannot read the database" >&2; exit 2; }
      f="$T/own/${2##*/}"; [[ -f "$f" ]] && cat "$f" && exit 0; echo "dpkg-query: no path found matching pattern $2" >&2; exit 1 ;;
  -L) [[ -e "$T/L.fail" ]] && { echo "dpkg-query: error: cannot read the database" >&2; exit 2; }
      [[ -f "$T/st/$2" ]] || exit 1
      [[ -e "$T/meta.$2" ]] && { echo "/usr/share/doc/$2"; exit 0; }
      r="${2#linux-image-}"; r="${r%%:*}"; echo "/boot/vmlinuz-$r"; echo "/lib/modules/$r/modules.order"; exit 0 ;;
esac
echo "dpkg $*" >> "$T/calls"
case "$1" in
  --audit) [[ -e "$T/audit.fail" ]] && exit 2; cat "$T/audit" 2>/dev/null; exit 0 ;;
  --configure) [[ -e "$T/configure.fail" ]] && exit 1; if [[ -e "$T/configure.side" ]]; then bash "$T/configure.side" || { echo "configure.side failed" >&2; exit 97; }; fi; rm -f "$T/audit"; for f in "$T"/st/linux-image-*; do [[ -e "$f" ]] && echo "install ok installed" > "$f"; done; exit 0 ;;
esac'
    _stub dkms 'echo "dkms $*" >> "$T/calls"
[[ "$1" == install ]] || exit 0
shift; k=""; v=""
while [[ $# -gt 0 ]]; do case "$1" in -k) k="$2"; shift ;; -v) v="$2"; shift ;; esac; shift; done
date +%s > "$T/dkms.start"
[[ -e "$T/dkms.side" ]] && bash "$T/dkms.side"
d="$T/var/lib/dkms/amneziawg/$v/build"; mkdir -p "$d"
[[ -e "$T/dkms.quietfail" || -e "$T/dkms.quietfail.$k" ]] && exit 10
[[ -e "$T/dkms.rc124" ]] && exit 124
if [[ "$k" == 7.0.0-38* && "$(sha256sum < "$T/usr/src/amneziawg-$v/compat/compat.h" | cut -d" " -f1)" != "$FIXED_SHA" ]]; then
  echo "compat/compat.h:1449:31: error: passing argument 2 of '"'"'setup_udp_tunnel_sock'"'"' from incompatible pointer type [-Werror=incompatible-pointer-types]" > "$d/make.log"
  [[ -e "$T/dkms.after" ]] && bash "$T/dkms.after"
  exit 10
fi
if [[ -e "$T/dkms.fail.$k" ]]; then echo "error: something else" > "$d/make.log"; exit 10; fi
mkdir -p "$T/lib/modules/$k/updates/dkms"; echo ko > "$T/lib/modules/$k/updates/dkms/amneziawg.ko.zst"'
    # Holds as apt-mark lists them; am.fail breaks the query.
    _stub apt-mark '[[ "$1" == showhold ]] || exit 0
[[ -e "$T/am.fail" ]] && { echo "E: cannot read the selections" >&2; exit 100; }
cat "$T/holds" 2>/dev/null; exit 0'
    export PATH="$T/bin:$PATH"
    _mk_helper install_amneziawg.sh
}

teardown() { [[ -n "${LFD:-}" ]] && exec {LFD}>&- || :; rm -rf "$T"; }

# ---------- the embedded fix ----------

@test "helper: the embedded fix is byte-identical to the PR #218 fixture in both installers" {
    local s
    for s in install_amneziawg.sh install_amneziawg_en.sh; do
        _raw_helper "$s" | awk "/<<'AWG_KMOD_PR218_EOF'\$/{f=1; next} /^AWG_KMOD_PR218_EOF\$/{f=0} f" > "$T/emb.diff"
        cmp "$T/emb.diff" "$(_fx pr218.diff)" || { echo "embedded fix differs: $s"; return 1; }
    done
}

@test "helper: the helper is byte-identical in both installers (tests run on one rely on it)" {
    _raw_helper install_amneziawg.sh > "$T/h.ru"
    _raw_helper install_amneziawg_en.sh > "$T/h.en"
    [ -s "$T/h.ru" ] && [ "$(wc -l < "$T/h.ru")" -gt 1000 ]
    cmp "$T/h.ru" "$T/h.en"
}

@test "helper: the pinned hash of the fix matches the fixture, and the fix turns base into the fixed file" {
    grep -qx "PR218_SHA=$(_sha "$(_fx pr218.diff)")" "$H"
    bash -c 'eval "$(sed -n "/^_awg_kmod_pr218_diff() {\$/,/^}\$/p" "$1")"; _awg_kmod_pr218_diff' _ "$H" > "$T/out.diff"
    cmp "$T/out.diff" "$(_fx pr218.diff)"
    patch --batch --fuzz=0 -o "$T/out.h" "$(_fx compat.h.base)" < "$T/out.diff" >/dev/null
    [ "$(_sha "$T/out.h")" = "$FIXED_SHA" ]
}

@test "helper: attribution of the embedded fix names the project, PR, commit, author and license" {
    grep -q '^# Fix for the module source from amnezia-vpn/amneziawg-linux-kernel-module$' "$H"
    grep -q '^# PR #218 (commit 62189503fa51), author VaisVaisov, GPL-2.0; embedded$' "$H"
}

@test "helper: a damaged embedded fix is refused, the source stays, repair says so with exit 1" {
    sed -i '/^AWG_KMOD_PR218_EOF$/i +/* tampered */' "$H"
    _mk_server "$OLD"
    run "$H" --prepare
    [ "$status" -eq 1 ]
    [[ "$output" == *"embedded source fix is damaged"* ]]
    [ "$(_sha "$(_src)")" = "$BASE_SHA" ]
    run "$H" --repair
    [ "$status" -eq 1 ]
    [ -s "$(_ko "$OLD")" ]; [ ! -e "$(_stamp)" ]
}

# ---------- --repair ----------

@test "repair: base source is fixed, every kernel gets its module, depmod for each, the stamp is written" {
    _mk_server "$OLD" "$NEW"
    run "$H" --repair
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(_sha "$(_src)")" = "$FIXED_SHA" ]
    [ -s "$(_ko "$OLD")" ]; [ -s "$(_ko "$NEW")" ]
    [[ "$(_calls)" == *"depmod -a $OLD"* && "$(_calls)" == *"depmod -a $NEW"* ]]
    grep -q '^v2 src=1.0.0:' "$(_stamp)"
}

@test "repair: on both installers' helpers" {
    _mk_helper install_amneziawg_en.sh
    _mk_server "$OLD" "$NEW"
    run "$H" --repair
    [ "$status" -eq 0 ]; [ -s "$(_ko "$NEW")" ]
}

@test "repair: a foreign source is not touched, says so; the 7.0 kernel fails with the known-issue line" {
    _mk_server "$OLD" "$NEW"
    echo '/* local edit */' >> "$(_src)"
    local before; before=$(_sha "$(_src)")
    run "$H" --repair
    [ "$status" -eq 1 ]
    [ "$(_sha "$(_src)")" = "$before" ]
    [[ "$output" == *"differs from the known base; fix not applied"* ]]
    [[ "$output" == *"kernel $NEW: NOT built [known-issue:kernel-70-udp-tunnel]"* ]]
    [[ "$output" == *"kernel $NEW: NO module on disk"* ]]
    [ -s "$(_ko "$OLD")" ]; [ ! -e "$(_ko "$NEW")" ]
    [ ! -e "$(_stamp)" ]
}

@test "repair: a source without compat.h is a warning, not a silent pass" {
    _mk_server "$OLD"
    rm "$(_src)"
    run "$H" --repair
    [[ "$output" == *"compat.h not found; fix not applied"* ]]
}

@test "repair: the running kernel without a module is exit 2" {
    echo "$NEW" > "$T/uname"
    _mk_server "$NEW"
    echo '/* local edit */' >> "$(_src)"
    run "$H" --repair
    [ "$status" -eq 2 ]
    [[ "$output" == *"kernel $NEW (running): NO module on disk"* ]]
}

@test "repair: a running apt (either dpkg lock file held open) stops it before anything changes" {
    local l
    _mk_server "$OLD" "$NEW"
    for l in lock-frontend lock; do
        rm -rf "$T/proc"; mkdir -p "$T/proc/1/fd" "$T/proc/42/fd"; rm -f "$T/calls"
        ln -s "$T/var/lib/dpkg/$l" "$T/proc/42/fd/7"
        run "$H" --repair
        [ "$status" -eq 2 ] || { echo "$l: $status"; return 1; }
        [[ "$output" == *"apt or dpkg is running"* ]]
        [ "$(_sha "$(_src)")" = "$BASE_SHA" ]
        [ -z "$(_calls)" ]
    done
}

@test "repair: an empty process table or an unreadable fd list counts as unknown, not as idle" {
    [[ $EUID -ne 0 ]] || skip "root reads a mode-000 directory anyway"
    _mk_server "$OLD"
    rm -rf "$T/proc"; mkdir -p "$T/proc"
    run "$H" --repair
    [ "$status" -eq 2 ]
    [[ "$output" == *"cannot tell whether apt or dpkg is running"* ]]
    mkdir -p "$T/proc/1/fd" "$T/proc/9/fd"; chmod 000 "$T/proc/9/fd"
    run "$H" --repair
    chmod 700 "$T/proc/9/fd"
    [ "$status" -eq 2 ]
    [[ "$output" == *"cannot tell whether apt or dpkg is running"* ]]
    [ -z "$(_calls)" ]
}

@test "repair: two registered versions or a broken source link: nothing is touched, nothing is built, all are listed" {
    _mk_server "$OLD" "$NEW"
    mkdir -p "$T/usr/src/amneziawg-1.0.1/compat" "$T/var/lib/dkms/amneziawg/1.0.1"
    cp "$(_fx compat.h.base)" "$T/usr/src/amneziawg-1.0.1/compat/compat.h"
    ln -s "$T/usr/src/amneziawg-1.0.1" "$T/var/lib/dkms/amneziawg/1.0.1/source"
    run "$H" --repair
    [ "$status" -eq 2 ]
    [[ "$output" == *"source: amneziawg/1.0.0 ->"* && "$output" == *"source: amneziawg/1.0.1 ->"* ]]
    [[ "$output" == *"2 AmneziaWG DKMS registrations"* ]]
    [ "$(_sha "$(_src)")" = "$BASE_SHA" ]
    [ -z "$(_calls)" ]
    rm -rf "$T/var/lib/dkms/amneziawg/1.0.1"
    rm "$T/var/lib/dkms/amneziawg/1.0.0/source"
    ln -s "$T/nowhere" "$T/var/lib/dkms/amneziawg/1.0.0/source"
    run "$H" --repair
    [ "$status" -eq 2 ]
    [[ "$output" == *"source $T/var/lib/dkms/amneziawg/1.0.0/source -> $T/nowhere is not the directory $T/usr/src/amneziawg-1.0.0"* ]]
    [[ "$output" == *"registration is broken"* ]]
    [ -z "$(_calls)" ]
}

@test "repair: a package change or a source change during the build voids the result" {
    local side
    for side in 'echo "1.0.0-0~new install ok installed" > "$T/st/amneziawg-dkms"' \
                'echo "/* unpacked */" >> "$T/usr/src/amneziawg-1.0.0/compat/compat.h"'; do
        rm -rf "${T:?}/usr" "${T:?}/var" "${T:?}/lib" "${T:?}/st"; _mk_server "$OLD" "$NEW"
        echo "$side" > "$T/dkms.side"
        run "$H" --repair
        [ "$status" -eq 2 ] || { echo "[$side]: $status"; return 1; }
        [[ "$output" == *"changed while the module was built"* ]]
        [ ! -e "$(_stamp)" ]
    done
}

@test "repair: an old make.log is not reported as the reason of a new failure" {
    _mk_server "$OLD" "$NEW"
    echo '/* local edit */' >> "$(_src)"
    mkdir -p "$T/var/lib/dkms/amneziawg/1.0.0/build"
    echo "x: passing argument 2 of 'setup_udp_tunnel_sock' from incompatible pointer type" \
        > "$T/var/lib/dkms/amneziawg/1.0.0/build/make.log"
    touch -d '-1 hour' "$T/var/lib/dkms/amneziawg/1.0.0/build/make.log"
    : > "$T/dkms.quietfail"
    run "$H" --repair
    [[ "$output" == *"kernel $NEW: NOT built (dkms rc=10); no new or changed make.log found for this attempt"* ]]
    [[ "$output" != *"known-issue"* ]]
}

@test "repair: a make.log written in the same second the attempt started still counts" {
    _mk_server "$OLD" "$NEW"
    echo '/* local edit */' >> "$(_src)"
    # After the stub writes it, the log gets exactly the second the attempt
    # started, as coarse timestamps can give it.
    echo 'touch -d "@$(cat "$T/dkms.start")" "$T/var/lib/dkms/amneziawg/1.0.0/build/make.log"' > "$T/dkms.after"
    run "$H" --repair
    [[ "$output" == *"kernel $NEW: NOT built [known-issue:kernel-70-udp-tunnel]"* ]]
}

@test "repair: a make.log the new attempt rewrites in place still counts" {
    # DKMS keeps one build directory, so a failure after an earlier one
    # overwrites the same file: same path, new content.
    _mk_server "$OLD" "$NEW"
    echo '/* local edit */' >> "$(_src)"
    mkdir -p "$T/var/lib/dkms/amneziawg/1.0.0/build"
    echo "error: an earlier, unrelated failure" > "$T/var/lib/dkms/amneziawg/1.0.0/build/make.log"
    touch -d '-1 hour' "$T/var/lib/dkms/amneziawg/1.0.0/build/make.log"
    run "$H" --repair
    [[ "$output" == *"kernel $NEW: NOT built [known-issue:kernel-70-udp-tunnel]"* ]] || { echo "$output"; return 1; }
}

@test "repair: a failed build of the running kernel is exit 2 and leaves no stamp" {
    _mk_server "$OLD"
    : > "$T/dkms.fail.$OLD"
    run "$H" --repair
    [ "$status" -eq 2 ]
    [[ "$output" == *"kernel $OLD: NOT built (dkms rc=10); log: "* ]]
    [ ! -e "$(_stamp)" ]
}

@test "repair: an empty or dangling module file is not a module" {
    _mk_server "$OLD"
    mkdir -p "$(dirname "$(_ko "$OLD")")"; : > "$(_ko "$OLD")"
    : > "$T/dkms.fail.$OLD"
    run "$H" --repair
    [ "$status" -eq 2 ]
    rm "$(_ko "$OLD")"; ln -s "$T/gone.ko" "$(_ko "$OLD")"
    run "$H" --repair
    [ "$status" -eq 2 ]
}

@test "repair: a broken headers link is reported and skipped, not built" {
    _mk_server "$OLD"
    mkdir -p "$T/lib/modules/$NEW"; ln -s "$T/gone" "$T/lib/modules/$NEW/build"
    run "$H" --repair
    [ "$status" -eq 0 ]
    [[ "$output" == *"kernel $NEW: headers link"*"is broken; kernel skipped"* ]]
    [[ "$(_calls)" != *"-k $NEW"* ]]
}

@test "repair: no kernel with headers builds nothing and writes no stamp" {
    _mk_server; _put_ko "$OLD"
    run "$H" --repair
    [ "$status" -eq 0 ]
    [[ "$output" == *"no kernel has headers installed"* ]]
    [ ! -e "$(_stamp)" ]
}

@test "repair: a failed depmod keeps the stamp away, and the next run retries it instead of trusting the file" {
    _mk_server "$OLD"
    : > "$T/depmod.fail"
    run "$H" --repair
    [ "$status" -eq 1 ]
    [ ! -e "$(_stamp)" ]
    # depmod's own reason reaches the output, not just "depmod failed".
    [[ "$output" == *"depmod: ERROR: could not open directory"* ]] || { echo "$output"; return 1; }
    rm -f "$T/calls"
    run "$H" --repair
    [ "$status" -eq 1 ]
    [[ "$(_calls)" == *"depmod -a $OLD"* ]]
    [ ! -e "$(_stamp)" ]
    rm "$T/depmod.fail"
    run "$H" --repair
    [ "$status" -eq 0 ]; [ -s "$(_stamp)" ]
}

@test "repair: waits for a lock that another job releases" {
    _mk_server "$OLD"
    _signal_flock; _holder
    run timeout 60 "$H" --repair
    wait
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -e "$T/flock.waiting" ]
    [ -s "$(_ko "$OLD")" ]
}

@test "repair: apt that starts while it waits for the lock stops it before anything changes" {
    _mk_server "$OLD"
    # The holder "starts apt" (a dpkg lock file held open) only once the
    # helper is already waiting, i.e. after its first check, then releases.
    _signal_flock; _holder 'ln -s "$T/var/lib/dpkg/lock-frontend" "$T/proc/1/fd/7"'
    run timeout 60 "$H" --repair
    wait
    [ "$status" -eq 2 ] || { echo "$output"; return 1; }
    [[ "$output" == *"apt or dpkg is running"* ]]
    [ "$(_sha "$(_src)")" = "$BASE_SHA" ]
    [[ "$(_calls)" != *"dkms install"* ]]
}

@test "repair: a stamp that cannot be written is a warning, not an abort" {
    _mk_server "$OLD"
    mkdir -p "$T/var/lib"; : > "$T/var/lib/amneziawg"
    run "$H" --repair
    [ "$status" -eq 0 ]
    [[ "$output" == *"cannot write"* ]]
}

# ---------- --hook ----------

@test "hook: success writes the stamp, the next run takes the quiet fast path" {
    _mk_server "$OLD" "$NEW"
    run "$H" --hook
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -s "$(_stamp)" ]
    rm -f "$T/calls"
    run "$H" --hook
    [ "$status" -eq 0 ]; [ -z "$output" ]
    [[ "$(_calls)" != *"dkms install"* ]]
}

@test "hook: a matching stamp with a module missing on disk still builds" {
    _mk_server "$OLD" "$NEW"
    "$H" --hook >/dev/null 2>&1
    rm "$(_ko "$NEW")"; rm -f "$T/calls"
    run "$H" --hook
    [ "$status" -eq 0 ]
    [[ "$(_calls)" == *"dkms install -m amneziawg -v 1.0.0 -k $NEW"* ]]
    [ -s "$(_ko "$NEW")" ]
}

@test "hook: a failure removes the previous stamp" {
    _mk_server "$OLD"
    "$H" --hook >/dev/null 2>&1
    [ -s "$(_stamp)" ]
    _mk_kernel "$NEW"; : > "$T/dkms.fail.$NEW"
    run "$H" --hook
    [ "$status" -eq 1 ]
    [ ! -e "$(_stamp)" ]
}

@test "hook: a stamp of the old format does not match" {
    _mk_server "$OLD"
    mkdir -p "$T/var/lib/amneziawg"; printf '123 %s ' "$OLD" > "$(_stamp)"
    _put_ko "$OLD"
    run "$H" --hook
    [ "$status" -eq 0 ]
    grep -q '^v2 ' "$(_stamp)"
}

@test "hook: when another job holds the lock it does nothing and leaves the stamp alone" {
    _mk_server "$OLD" "$NEW"
    mkdir -p "$T/var/lib/amneziawg"; echo keep > "$(_stamp)"
    _hold_lock
    run "$H" --hook
    [ "$status" -eq 0 ]
    [[ "$output" == *"another AmneziaWG module job is running; skipped"* ]]
    [ "$(cat "$(_stamp)")" = keep ]
    [ "$(_sha "$(_src)")" = "$BASE_SHA" ]
    [ -z "$(_calls)" ]
}

@test "hook: an unusable lock is an error with exit 1, not a silent skip" {
    _mk_server "$OLD"
    mkdir -p "$T/var/lib/amneziawg"; echo stale > "$(_stamp)"
    : > "$T/run/amneziawg"
    run "$H" --hook
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot use $T/run/amneziawg/kmod.lock"* ]]
    [[ "$output" != *"another AmneziaWG module job"* ]]
    [ ! -e "$(_stamp)" ]
}

@test "hook: runs inside apt, so a held dpkg lock does not stop it; never modprobe or dpkg --configure" {
    _mk_server "$OLD" "$NEW"
    ln -s "$T/var/lib/dpkg/lock-frontend" "$T/proc/1/fd/7"
    run "$H" --hook
    [ "$status" -eq 0 ]
    [ -s "$(_ko "$NEW")" ]
    [[ "$(_calls)" != *modprobe* && "$(_calls)" != *"dpkg --configure"* ]]
}

@test "hook: no registered source is a quiet no-op; no dkms is a warning" {
    _mk_kernel "$OLD"
    run "$H" --hook
    [ "$status" -eq 0 ]; [ -z "$output" ]
    [ -z "$(_calls)" ]
    # The helper appends the sbin directories itself: a host dkms there would be found.
    local d
    for d in /usr/local/sbin /usr/sbin /sbin /usr/bin /bin; do [[ -x "$d/dkms" ]] && skip "the host has $d/dkms"; done
    rm "$T/bin/dkms"
    run env PATH="$T/bin:/usr/bin:/bin" "$H" --hook
    [ "$status" -eq 0 ]
    [[ "$output" == *"dkms is not installed"* ]]
}

@test "hook: two registrations are listed and nothing is built" {
    _mk_server "$OLD"
    mkdir -p "$T/usr/src/amneziawg-1.0.1" "$T/var/lib/dkms/amneziawg/1.0.1"
    ln -s "$T/usr/src/amneziawg-1.0.1" "$T/var/lib/dkms/amneziawg/1.0.1/source"
    run "$H" --hook
    [ "$status" -eq 1 ]
    [[ "$output" == *"source: amneziawg/1.0.1 ->"* ]]
    [[ "$(_calls)" != *"dkms install"* ]]
}

@test "hook: the lock directory is created 0700 and a symlinked one is refused" {
    _mk_server "$OLD"
    run "$H" --hook
    [ "$(stat -c %a "$T/run/amneziawg")" = 700 ]
    rm -rf "$T/run/amneziawg"; mkdir "$T/elsewhere"; ln -s "$T/elsewhere" "$T/run/amneziawg"
    run "$H" --repair
    [ "$status" -eq 2 ]
    [ ! -e "$T/elsewhere/kmod.lock" ]
}

# ---------- --systemd ----------

@test "systemd: a module on disk is only loaded: no build, no stamp" {
    _mk_server "$OLD" "$NEW"
    _put_ko "$OLD"
    run "$H" --systemd
    [ "$status" -eq 0 ]
    [[ "$(_calls)" != *"dkms install"* ]]
    [ ! -e "$(_stamp)" ]
    [ -d "$T/sys/module/amneziawg" ]
}

@test "systemd: without a module it builds the running kernel only, then loads it" {
    echo "$NEW" > "$T/uname"
    _mk_server "$OLD" "$NEW"
    run "$H" --systemd
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -s "$(_ko "$NEW")" ]; [ ! -e "$(_ko "$OLD")" ]
    [ "$(_sha "$(_src)")" = "$FIXED_SHA" ]
    [ ! -e "$(_stamp)" ]
    [ -d "$T/sys/module/amneziawg" ]
}

@test "systemd: lock held by another job: no build, exit 1, and it does not blame Secure Boot" {
    _mk_server "$OLD"
    _hold_lock
    run timeout 60 "$H" --systemd
    [ "$status" -eq 1 ]
    [[ "$(_calls)" != *"dkms install"* ]]
    [[ "$output" == *"held the lock"* ]]
    [[ "$output" != *"Secure Boot"* ]]
}

@test "systemd: waits for a lock that another job releases, then builds and loads" {
    echo "$NEW" > "$T/uname"
    _mk_server "$NEW"
    _signal_flock; _holder
    run timeout 60 "$H" --systemd
    wait
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -e "$T/flock.waiting" ]
    [ -s "$(_ko "$NEW")" ]
}

@test "systemd: an unusable lock: no build, says why, no wait" {
    _mk_server "$OLD"
    : > "$T/run/amneziawg"
    run timeout 60 "$H" --systemd
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot use"* ]]
    [[ "$(_calls)" != *"dkms install"* ]]
}

@test "systemd: a running apt stops the build" {
    _mk_server "$OLD"
    ln -s "$T/var/lib/dpkg/lock" "$T/proc/1/fd/7"
    run "$H" --systemd
    [ "$status" -eq 1 ]
    [[ "$(_calls)" != *"dkms install"* ]]
    [[ "$output" == *"apt or dpkg is running"* ]]
}

@test "systemd: no registered source: says so and exits 1" {
    _mk_kernel "$OLD"
    run "$H" --systemd
    [ "$status" -eq 1 ]
    [[ "$output" == *"no AmneziaWG DKMS source is registered"* ]]
}

@test "systemd: a module on disk that does not load gets one forced rebuild; still failing blames the load, not the build" {
    _mk_server "$OLD"
    _put_ko "$OLD"
    : > "$T/modprobe.fail"
    run "$H" --systemd
    [ "$status" -eq 1 ]
    [[ "$(_calls)" == *"dkms install -m amneziawg -v 1.0.0 -k $OLD --force"* ]]
    [[ "$output" == *"Secure Boot"* ]]
}

@test "systemd: a forced rebuild that fixes the load ends loaded" {
    _mk_server "$OLD"
    _put_ko "$OLD"
    # The first modprobe fails, the one after the rebuild works.
    : > "$T/modprobe.fail"; echo 'rm -f "$T/modprobe.fail"' > "$T/dkms.side"
    run "$H" --systemd
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -d "$T/sys/module/amneziawg" ]
}

# ---------- --prepare ----------

@test "prepare: fixes the source, builds nothing" {
    _mk_server "$OLD" "$NEW"
    run "$H" --prepare
    [ "$status" -eq 0 ]
    [ "$(_sha "$(_src)")" = "$FIXED_SHA" ]
    [[ "$(_calls)" != *"dkms install"* ]]
    run "$H" --prepare
    [ "$status" -eq 0 ]
}

@test "prepare: with no registered source there is nothing to do" {
    run "$H" --prepare
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to prepare"* ]]
}

# ---------- --finish ----------

@test "finish: nothing unfinished: dpkg --configure is not run" {
    _mk_server "$OLD"
    run "$H" --finish
    [ "$status" -eq 0 ]
    [[ "$(_calls)" != *"--configure"* ]]
}

@test "finish: an unfinished kernel with the module: configure runs, the audit is re-checked" {
    _mk_server "$OLD" "$NEW"
    "$H" --repair >/dev/null 2>&1
    echo "install ok unpacked" > "$T/st/linux-image-$NEW"
    echo "linux-image-$NEW is not configured yet" > "$T/audit"
    run "$H" --finish
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$(_calls)" == *"dpkg --configure -a"* ]]
    [[ "$output" == *"now in the boot loader"* ]]
}

# Configuring amneziawg-dkms itself runs its postinst, which deletes the
# module from the DKMS tree for every kernel and builds it back only for the
# running one (stand LA #2, 4 oct 2026). Our apt hook does not fire under a
# bare dpkg, so --finish has to build the other kernels again.
_configure_drops_others() {
    cat > "$T/configure.side" <<EOF
rm -f "$(_ko "$OLD")" "$(_ko "$NEW")"
mkdir -p "\$(dirname "$(_ko "$OLD")")"; echo ko > "$(_ko "$OLD")"
EOF
}

@test "finish: configure that drops the other kernels' module builds them again, on both helpers" {
    local s
    for s in install_amneziawg.sh install_amneziawg_en.sh; do
        rm -rf "${T:?}/usr" "${T:?}/var" "${T:?}/lib" "${T:?}/boot"/* "${T:?}/own" "${T:?}/st" "${T:?}/calls"; mkdir -p "$T/boot"
        _mk_helper "$s"
        _mk_server "$OLD" "$NEW"
        "$H" --repair >/dev/null 2>&1
        [ -s "$(_ko "$NEW")" ]
        echo "amneziawg-dkms is only half configured" > "$T/audit"
        _configure_drops_others
        run "$H" --finish
        [ "$status" -eq 0 ] || { echo "$s: $output"; return 1; }
        [ -s "$(_ko "$OLD")" ]; [ -s "$(_ko "$NEW")" ]
        # The rebuild of $NEW comes after the configure, not from the first --repair.
        sed -n '/^dpkg --configure -a$/,$p' "$T/calls" | grep -qx "dkms install -m amneziawg -v 1.0.0 -k $NEW" \
            || { echo "$s: no rebuild of $NEW after configure"; cat "$T/calls"; return 1; }
        [[ "$output" == *"building it again"* ]]
        [[ "$output" == *"packages: configured"* ]]
    done
}

@test "finish: a failed rebuild after configure is exit 1 and says so, on both helpers" {
    local s
    for s in install_amneziawg.sh install_amneziawg_en.sh; do
        rm -rf "${T:?}/usr" "${T:?}/var" "${T:?}/lib" "${T:?}/boot"/* "${T:?}/own" "${T:?}/st" "${T:?}/calls" "$T/dkms.fail.$NEW"; mkdir -p "$T/boot"
        _mk_helper "$s"
        _mk_server "$OLD" "$NEW"
        "$H" --repair >/dev/null 2>&1
        echo "amneziawg-dkms is only half configured" > "$T/audit"
        _configure_drops_others
        echo ": > \"$T/dkms.fail.$NEW\"" >> "$T/configure.side"
        run "$H" --finish
        [ "$status" -eq 1 ] || { echo "$s: $output"; return 1; }
        [[ "$output" == *"the module did not build again for: $NEW;"* ]] || { echo "$s: $output"; return 1; }
        [ ! -e "$(_ko "$NEW")" ]
    done
}

# The installer's fallback (T1) runs --finish after a --repair that exited 1:
# the running kernel has its module, another kernel never built (old headers
# after an in-place upgrade). That kernel is not --finish's business: only a
# module that configuring took away is built again.
@test "finish: a kernel that never built does not fail it; only modules lost to configure are rebuilt" {
    local k3=6.8.0-31-generic n
    _mk_server "$OLD" "$NEW" "$k3"
    : > "$T/dkms.fail.$k3"
    run "$H" --repair
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    [ ! -e "$(_ko "$k3")" ]; [ -s "$(_ko "$NEW")" ]
    echo "amneziawg-dkms is only half configured" > "$T/audit"
    _configure_drops_others
    n=$(grep -c "^dkms install -m amneziawg -v 1.0.0 -k $k3\$" "$T/calls")
    run "$H" --finish
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -s "$(_ko "$NEW")" ]; [ ! -e "$(_ko "$k3")" ]
    [[ "$output" == *"removed the module of: $NEW;"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"packages: configured"* ]]
    # The never-built kernel is tried again by the child pass (it builds every
    # kernel without a module), but its failure does not fail --finish.
    [ "$(grep -c "^dkms install -m amneziawg -v 1.0.0 -k $k3\$" "$T/calls")" -eq $((n + 1)) ]
    [[ "$output" == *"build pass after configuring exited with code 1 (still no module: $k3)"* ]] || { echo "$output"; return 1; }
}

# Exit 1 with every kernel built before configuring is a real failure of the
# pass after it (here depmod), not the T1 case: modules on disk are not enough.
# A kernel without a module before configuring that builds in the pass
# after it does not excuse that pass's exit 1 (here depmod).
@test "finish: a never-built kernel that builds after configuring does not excuse exit 1" {
    local k3=6.8.0-31-generic
    _mk_server "$OLD" "$NEW" "$k3"
    : > "$T/dkms.fail.$k3"
    "$H" --repair >/dev/null 2>&1 || true
    [ ! -e "$(_ko "$k3")" ]
    echo "amneziawg-dkms is only half configured" > "$T/audit"
    _configure_drops_others
    printf 'rm -f "%s"\n: > "%s"\n' "$T/dkms.fail.$k3" "$T/depmod.fail" >> "$T/configure.side"
    run "$H" --finish
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    [ -s "$(_ko "$k3")" ]
    [[ "$output" == *"build pass after them failed (exit 1)"* ]] || { echo "$output"; return 1; }
}

@test "finish: exit 1 of the pass after configuring with no never-built kernel fails it, on both helpers" {
    local s
    for s in install_amneziawg.sh install_amneziawg_en.sh; do
        rm -rf "${T:?}/usr" "${T:?}/var" "${T:?}/lib" "${T:?}/boot"/* "${T:?}/own" "${T:?}/st" "${T:?}/calls" "${T:?}/depmod.fail"; mkdir -p "$T/boot"
        _mk_helper "$s"
        _mk_server "$OLD" "$NEW"
        "$H" --repair >/dev/null 2>&1
        echo "amneziawg-dkms is only half configured" > "$T/audit"
        _configure_drops_others
        echo ": > \"$T/depmod.fail\"" >> "$T/configure.side"
        run "$H" --finish
        [ "$status" -eq 1 ] || { echo "$s: $output"; return 1; }
        [ -s "$(_ko "$NEW")" ]
        [[ "$output" == *"build pass after them failed (exit 1)"* ]] || { echo "$s: $output"; return 1; }
    done
}

# Exit 2 of the pass after configuring means it did not count its result:
# the module files on disk prove nothing then. Here the package changes
# under the build (the snapshot includes its dpkg status).
@test "finish: a build pass that did not count its result (exit 2) fails it even with the modules back, on both helpers" {
    local s
    for s in install_amneziawg.sh install_amneziawg_en.sh; do
        rm -rf "${T:?}/usr" "${T:?}/var" "${T:?}/lib" "${T:?}/boot"/* "${T:?}/own" "${T:?}/st" "${T:?}/calls" "${T:?}/dkms.side" "${T:?}/configure.side.dkms"; mkdir -p "$T/boot"
        _mk_helper "$s"
        _mk_server "$OLD" "$NEW"
        "$H" --repair >/dev/null 2>&1
        echo "amneziawg-dkms is only half configured" > "$T/audit"
        _configure_drops_others
        printf 'echo "1.0.0-0~new install ok half-configured" > "%s"\n' "$T/st/amneziawg-dkms" > "$T/configure.side.dkms"
        echo "cp \"$T/configure.side.dkms\" \"$T/dkms.side\"" >> "$T/configure.side"
        run "$H" --finish
        [ "$status" -eq 1 ] || { echo "$s: $output"; return 1; }
        [ -s "$(_ko "$NEW")" ]
        [[ "$output" == *"build pass after them failed (exit 2)"* ]] || { echo "$s: $output"; return 1; }
    done
}

@test "finish: the running kernel's module lost to configure and not rebuilt (child exit 2) fails it by name" {
    _mk_server "$OLD" "$NEW"
    "$H" --repair >/dev/null 2>&1
    echo "amneziawg-dkms is only half configured" > "$T/audit"
    printf 'rm -f "%s" "%s"\n: > "%s"\n' "$(_ko "$OLD")" "$(_ko "$NEW")" "$T/dkms.fail.$OLD" > "$T/configure.side"
    run "$H" --finish
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    [[ "$output" == *"the module did not build again for: $OLD;"* ]] || { echo "$output"; return 1; }
    [ -s "$(_ko "$NEW")" ]; [ ! -e "$(_ko "$OLD")" ]
}

@test "finish: configure that keeps every module builds nothing more" {
    _mk_server "$OLD" "$NEW"
    "$H" --repair >/dev/null 2>&1
    local n
    n=$(grep -c '^dkms install' "$T/calls")
    echo "amneziawg-tools is not configured" > "$T/audit"
    run "$H" --finish
    [ "$status" -eq 0 ]
    [[ "$output" == *"packages: configured"* ]]
    [[ "$(_calls)" == *"dpkg --configure -a"* ]]
    [ "$(grep -c '^dkms install' "$T/calls")" -eq "$n" ]
    [[ "$output" != *"building it again"* ]]
}

@test "finish: an unfinished kernel without headers and without the module blocks configure, by name" {
    _mk_server "$OLD"
    "$H" --repair >/dev/null 2>&1
    _mk_image "$NEW" "install ok unpacked"
    echo "unfinished" > "$T/audit"
    run "$H" --finish
    [ "$status" -eq 1 ]
    [[ "$output" == *"unfinished kernel(s) without the AmneziaWG module: $NEW"* ]]
    [[ "$(_calls)" != *"--configure"* ]]
}

@test "finish: an old configured kernel without a module only warns; the unfinished one with the module is configured" {
    local old2=6.8.0-31-generic
    _mk_server "$OLD" "$NEW"
    "$H" --repair >/dev/null 2>&1
    _mk_image "$old2"
    echo "install ok half-configured" > "$T/st/linux-image-$NEW"
    echo "unfinished" > "$T/audit"
    run "$H" --finish
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"already configured kernel(s) without the AmneziaWG module: $old2"* ]]
    [[ "$(_calls)" == *"dpkg --configure -a"* ]]
}

@test "finish: only non-kernel packages unfinished: configure runs, no boot loader claim" {
    _mk_server "$OLD"
    "$H" --repair >/dev/null 2>&1
    echo "amneziawg-tools is not configured" > "$T/audit"
    run "$H" --finish
    [ "$status" -eq 0 ]
    [[ "$(_calls)" == *"dpkg --configure -a"* ]]
    [[ "$output" != *"boot loader"* ]]
}

@test "finish: a module without headers is enough for an unfinished kernel" {
    _mk_server "$OLD"
    _mk_image "$NEW" "install ok unpacked"; _put_ko "$NEW"
    echo "unfinished" > "$T/audit"
    run "$H" --finish
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "finish: an image no package owns does not block" {
    _mk_server "$OLD"
    : > "$T/boot/vmlinuz-9.9.9-custom"
    echo "unfinished" > "$T/audit"
    run "$H" --finish
    [ "$status" -eq 0 ]
    [[ "$output" == *"9.9.9-custom: image not owned by a package"* ]]
}

@test "finish: a failed audit is not 'nothing to configure'" {
    _mk_server "$OLD"
    : > "$T/audit.fail"
    run "$H" --finish
    [ "$status" -eq 1 ]
    [[ "$output" == *"dpkg --audit failed"* ]]
    [[ "$(_calls)" != *"--configure"* ]]
}

@test "finish: an unreadable /boot is not an empty inventory" {
    _mk_server "$OLD"
    echo "unfinished" > "$T/audit"
    rm -rf "${T:?}/boot"
    run "$H" --finish
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot list kernels"* ]]
    [[ "$(_calls)" != *"--configure"* ]]
}

@test "finish: still unfinished after configure is a failure" {
    _mk_server "$OLD"
    "$H" --repair >/dev/null 2>&1
    echo "unfinished" > "$T/audit"
    _stub dpkg '[[ "$1" == -S ]] && { echo "dpkg-query: no path found matching pattern $2" >&2; exit 1; }; echo "dpkg $*" >> "$T/calls"; [[ "$1" == --audit ]] && echo still; exit 0'
    run "$H" --finish
    [ "$status" -eq 1 ]
    [[ "$output" == *"still unfinished"* ]]
}

@test "finish: a metapackage-like name in /boot is not a kernel; only real releases count" {
    _mk_server "$OLD"
    "$H" --repair >/dev/null 2>&1
    echo "unfinished" > "$T/audit"
    : > "$T/boot/vmlinuz"; : > "$T/boot/vmlinuz.old"; : > "$T/boot/config-$NEW"
    run "$H" --finish
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# ---------- --revert / --enable ----------

@test "revert: back to base, disabled until enable, later runs do not re-apply" {
    _mk_server "$OLD"
    "$H" --repair >/dev/null 2>&1
    [ "$(_sha "$(_src)")" = "$FIXED_SHA" ]
    run "$H" --revert
    [ "$status" -eq 0 ]
    [ "$(_sha "$(_src)")" = "$BASE_SHA" ]
    [ ! -e "$(_stamp)" ]
    run "$H" --hook
    [ "$(_sha "$(_src)")" = "$BASE_SHA" ]
    [[ "$output" == *"disabled by --revert"* ]]
    run "$H" --enable
    [ "$status" -eq 0 ]
    run "$H" --prepare
    [ "$(_sha "$(_src)")" = "$FIXED_SHA" ]
}

@test "revert: no registered source says so" {
    run "$H" --revert
    [ "$status" -eq 1 ]
    [[ "$output" == *"nothing to revert"* ]]
}

# ---------- review round 2: failures that must not pass as answers ----------

@test "lock: a flock failure other than a conflict is 'unusable', not 'another job'" {
    _mk_server "$OLD"
    _stub flock 'exit 65'
    run "$H" --hook
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot use"* ]]
    [[ "$output" != *"another AmneziaWG module job"* ]]
}

@test "dpkg check: a permission error on an fd link means 'cannot tell'" {
    _mk_server "$OLD"
    # find itself reports one fd it could not read, as it would in a
    # restricted container; everything else is the real find.
    local real; real=$(command -v find)
    _stub find "case \"\$*\" in *-lname*) \"$real\" \"\$@\"; echo \"find: '$T/proc/1/fd/9': Permission denied\" >&2; exit 1 ;; esac
exec \"$real\" \"\$@\""
    run "$H" --repair
    [ "$status" -eq 2 ]
    [[ "$output" == *"cannot tell whether apt or dpkg is running"* ]]
    [[ "$(_calls)" != *"dkms install"* ]]
}

@test "dpkg check: a process that exits during the scan does not make it 'cannot tell'" {
    _mk_server "$OLD"
    # On a live system find often meets an fd directory that is gone by then.
    local real; real=$(command -v find)
    _stub find "case \"\$*\" in *-lname*) \"$real\" \"\$@\"; echo \"find: '$T/proc/9/fd': No such file or directory\" >&2; exit 1 ;; esac
exec \"$real\" \"\$@\""
    run "$H" --repair
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$(_calls)" == *"dkms install"* ]]
}

@test "dpkg check: any other scan error means 'cannot tell', not 'idle'" {
    _mk_server "$OLD"
    # find never runs (a process table too big for one command line).
    _stub find "case \"\$*\" in *-lname*) echo \"bash: find: Argument list too long\" >&2; exit 126 ;; esac
exec \"$(command -v find)\" \"\$@\""
    run "$H" --repair
    [ "$status" -eq 2 ]
    [[ "$output" == *"cannot tell whether apt or dpkg is running"* ]] || { echo "$output"; return 1; }
    [[ "$(_calls)" != *"dkms install"* ]]
}

@test "build: a log another kernel wrote in this run is not blamed on the next one" {
    local third=7.1.0-5-generic
    _mk_server "$OLD" "$NEW" "$third"
    echo '/* local edit */' >> "$(_src)"
    : > "$T/dkms.quietfail.$third"
    run "$H" --repair
    [[ "$output" == *"kernel $NEW: NOT built [known-issue:kernel-70-udp-tunnel]"* ]]
    [[ "$output" == *"kernel $third: NOT built (dkms rc=10); no new or changed make.log found for this attempt"* ]] || { echo "$output"; return 1; }
}

@test "finish: a failed ownership lookup is a refusal, not an unpackaged image" {
    _mk_server "$OLD"
    _mk_image "$NEW" "install ok unpacked"
    echo "unfinished" > "$T/audit"; : > "$T/S.fail"
    run "$H" --finish
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot ask dpkg who owns"* ]]
    [[ "$(_calls)" != *"--configure"* ]]
}

@test "finish: diversion records and arch-qualified owners are read per line" {
    local old2=6.8.0-31-generic
    _mk_server "$OLD"
    "$H" --repair >/dev/null 2>&1
    # a configured kernel without the module, with diversion records around its owner
    _mk_image "$old2"
    printf '%s\n' "local diversion from: $T/boot/vmlinuz-$old2" \
        "diversion by foo to: $T/boot/vmlinuz-$old2.real" \
        "linux-image-$old2:amd64: $T/boot/vmlinuz-$old2" > "$T/own/vmlinuz-$old2"
    echo "install ok installed" > "$T/st/linux-image-$old2:amd64"
    echo "unfinished" > "$T/audit"
    run "$H" --finish
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"already configured kernel(s) without the AmneziaWG module: $old2"* ]]
    # the same owner unfinished blocks
    "$H" --repair >/dev/null 2>&1 || :
    echo "install ok unpacked" > "$T/st/linux-image-$old2:amd64"; echo "unfinished" > "$T/audit"
    run "$H" --finish
    [ "$status" -eq 1 ]
    [[ "$output" == *"unfinished kernel(s) without the AmneziaWG module: $old2"* ]]
}

@test "systemd: preparing the source runs in a child that does not take the held lock" {
    _mk_server "$OLD"
    _hold_lock
    # As --systemd does: the descriptor it holds the lock through is passed on.
    run env AWG_KMOD_LOCK_FD="$LFD" timeout 30 "$H" --prepare-locked
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(_sha "$(_src)")" = "$FIXED_SHA" ]
    # The child's exit leaves the lock with its holder.
    run bash -c 'exec 7>>"$1"; exec "$2" -n 7' _ "$T/run/amneziawg/kmod.lock" "$REAL_FLOCK"
    # flock -n on a held lock exits exactly 1; anything else is another failure.
    [ "$status" -eq 1 ]
}

@test "prepare-locked: run by hand it refuses, whether the lock is free or another job holds it" {
    _mk_server "$OLD"
    run timeout 30 "$H" --prepare-locked
    [ "$status" -eq 2 ]
    [[ "$output" == *"--prepare-locked is internal"* ]] || { echo "$output"; return 1; }
    # Another job (say, --repair) holds the lock; a manual call must not
    # take that for its parent's lock, not even with a descriptor of its own
    # on the same file.
    _hold_lock
    run timeout 30 "$H" --prepare-locked
    [ "$status" -eq 2 ]
    run bash -c 'exec 8>>"$1"; AWG_KMOD_LOCK_FD=8 exec timeout 30 "$2" --prepare-locked' _ "$T/run/amneziawg/kmod.lock" "$H"
    [ "$status" -eq 2 ] || { echo "$output"; return 1; }
    # A descriptor of some other file, lockable at once, is not the lock either.
    run bash -c 'exec 8>>"$1"; AWG_KMOD_LOCK_FD=8 exec timeout 30 "$2" --prepare-locked' _ "$T/other.lock" "$H"
    [ "$status" -eq 2 ] || { echo "$output"; return 1; }
    [ "$(_sha "$(_src)")" = "$BASE_SHA" ]
}

@test "systemd: apt that starts while the source is prepared stops the build" {
    echo "$NEW" > "$T/uname"
    _mk_server "$NEW"
    local real; real=$(command -v patch)
    _stub patch "ln -sfn \"$T/var/lib/dpkg/lock\" \"$T/proc/1/fd/8\"; exec \"$real\" \"\$@\""
    run "$H" --systemd
    [ "$status" -eq 1 ]
    [[ "$output" == *"apt or dpkg is running"* ]]
    [[ "$(_calls)" != *"dkms install"* ]]
}

@test "systemd: a stalled source fix is cut off and the boot goes on" {
    # patch hangs; the child that prepares the source is stopped by its own
    # timeout (shortened here from 20 s to 2 s), the build still runs.
    _mk_server "$OLD"
    local rt; rt=$(command -v timeout)
    _stub patch 'exec sleep 60'
    _stub timeout "case \" \$* \" in *' --prepare-locked '*) exec \"$rt\" -k 1 2 \"\${@:4}\" ;; esac
exec \"$rt\" \"\$@\""
    run timeout 30 "$H" --systemd
    [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
    [[ "$output" == *"preparing the source failed or did not finish"* ]]
    [[ "$(_calls)" == *"dkms install -m amneziawg -v 1.0.0 -k $OLD"* ]]
    [ "$(_sha "$(_src)")" = "$BASE_SHA" ]
}

# ---------- review round 2: branches that had no test ----------

@test "finish: a running apt stops it before the audit" {
    _mk_server "$OLD"
    echo "unfinished" > "$T/audit"
    ln -s "$T/var/lib/dpkg/lock" "$T/proc/1/fd/7"
    run "$H" --finish
    [ "$status" -eq 1 ]
    [[ "$(_calls)" != *"dpkg --audit"* && "$(_calls)" != *"--configure"* ]]
}

@test "finish: a kernel on hold that is configured counts as configured" {
    local old2=6.8.0-31-generic
    _mk_server "$OLD"
    "$H" --repair >/dev/null 2>&1
    _mk_image "$old2" "hold ok installed"
    echo "unfinished" > "$T/audit"
    run "$H" --finish
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"already configured kernel(s) without the AmneziaWG module: $old2"* ]]
}

@test "finish: every unfinished kernel without the module is named" {
    _mk_server "$OLD"
    "$H" --repair >/dev/null 2>&1
    _mk_image 7.0.0-38-generic "install ok unpacked"; _mk_image 7.0.0-39-generic "install ok half-configured"
    echo "unfinished" > "$T/audit"
    run "$H" --finish
    [ "$status" -eq 1 ]
    [[ "$output" == *"without the AmneziaWG module: "*7.0.0-38-generic*7.0.0-39-generic* || "$output" == *"without the AmneziaWG module: "*7.0.0-39-generic*7.0.0-38-generic* ]]
}

@test "finish: an unfinished image dpkg knows but /boot does not show still blocks" {
    _mk_server "$OLD"
    "$H" --repair >/dev/null 2>&1
    echo "install ok unpacked" > "$T/st/linux-image-$NEW"
    echo "unfinished" > "$T/audit"
    run "$H" --finish
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    [[ "$output" == *"unfinished kernel(s) without the AmneziaWG module: $NEW"* ]]
    [[ "$(_calls)" != *"--configure"* ]]
}

@test "finish: a failed package query is a refusal" {
    # Every kernel in /boot has its module, so only the failed list of
    # kernel image packages can stop it.
    _mk_server "$OLD"
    "$H" --repair >/dev/null 2>&1
    echo "unfinished" > "$T/audit"
    : > "$T/dq.listfail"
    run "$H" --finish
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    [[ "$output" == *"cannot list the kernel image packages"* ]]
    [[ "$(_calls)" != *"--configure"* ]]
}

@test "finish: an unfinished metapackage ships no kernel image and does not block" {
    # linux-image-generic stays unpacked after every interrupted kernel update.
    _mk_server "$OLD"
    "$H" --repair >/dev/null 2>&1
    echo "install ok unpacked" > "$T/st/linux-image-generic"; : > "$T/meta.linux-image-generic"
    echo "unfinished" > "$T/audit"
    run "$H" --finish
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$(_calls)" == *"dpkg --configure -a"* ]]
}

@test "finish: a warning from the package query is not read as a package" {
    _mk_server "$OLD"
    "$H" --repair >/dev/null 2>&1
    echo "unfinished" > "$T/audit"; : > "$T/dq.warn"
    run "$H" --finish
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$(_calls)" == *"dpkg --configure -a"* ]]
}

@test "finish: an ownership answer with no owner record is a refusal" {
    local k3=6.8.0-200-generic
    _mk_server "$OLD"
    "$H" --repair >/dev/null 2>&1
    _mk_image "$k3"
    # dpkg -S succeeds but names only a diversion of that path.
    echo "diversion by local-kernel from: $T/boot/vmlinuz-$k3" > "$T/own/vmlinuz-$k3"
    echo "unfinished" > "$T/audit"
    run "$H" --finish
    [ "$status" -eq 1 ]
    [[ "$output" == *"named no owning package"* ]] || { echo "$output"; return 1; }
    [[ "$(_calls)" != *"--configure"* ]]
}

@test "finish: a failed file list of an unfinished image package is a refusal" {
    _mk_server "$OLD"
    "$H" --repair >/dev/null 2>&1
    echo "install ok unpacked" > "$T/st/linux-image-$NEW"; : > "$T/L.fail"
    echo "unfinished" > "$T/audit"
    run "$H" --finish
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot list the files of linux-image-$NEW"* ]] || { echo "$output"; return 1; }
    [[ "$(_calls)" != *"--configure"* ]]
}

@test "finish: an unfinished image only dpkg shows, with its module on disk, is configured" {
    local k3=6.8.0-200-generic
    _mk_server "$OLD"
    # Headers but no image in /boot; the repair builds its module.
    mkdir -p "$T/lib/modules/$k3/hdr"; ln -s hdr "$T/lib/modules/$k3/build"
    "$H" --repair >/dev/null 2>&1
    [ -s "$(_ko "$k3")" ]
    echo "install ok unpacked" > "$T/st/linux-image-$k3"
    echo "unfinished" > "$T/audit"
    run "$H" --finish
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"kernel $k3 (to be configured, not seen in"* ]]
    [[ "$(_calls)" == *"dpkg --configure -a"* ]]
}

@test "finish: a failed configure says so" {
    _mk_server "$OLD"
    echo "amneziawg-tools unfinished" > "$T/audit"; : > "$T/configure.fail"
    run "$H" --finish
    [ "$status" -eq 1 ]
    [[ "$output" == *"dpkg --configure -a failed"* ]]
}

@test "systemd: a source change during its build is not trusted" {
    echo "$NEW" > "$T/uname"
    _mk_server "$NEW"
    echo 'echo "/* unpacked */" >> "$T/usr/src/amneziawg-1.0.0/compat/compat.h"' > "$T/dkms.side"
    run "$H" --systemd
    [ "$status" -eq 1 ]
    [[ "$output" == *"changed during the build"* ]]
}

@test "systemd: after a build it refreshes the module index of that kernel" {
    echo "$NEW" > "$T/uname"
    _mk_server "$NEW"
    run "$H" --systemd
    [ "$status" -eq 0 ]
    [[ "$(_calls)" == *"depmod -a $NEW"* ]]
}

@test "systemd: a budget that is used up skips modprobe and says so" {
    BUDGET=3 _mk_helper install_amneziawg.sh
    _mk_server "$OLD"; _put_ko "$OLD"
    sleep 1
    run "$H" --systemd
    [ "$status" -eq 1 ]
    [[ "$output" == *"budget is used up; modprobe not attempted"* ]] || { echo "$output"; return 1; }
    [[ "$(_calls)" != *modprobe* ]]
}

@test "systemd: too little budget left to build: no build, says so" {
    BUDGET=40 _mk_helper install_amneziawg.sh
    echo "$NEW" > "$T/uname"
    _mk_server "$NEW"
    run "$H" --systemd
    [ "$status" -eq 1 ]
    [[ "$output" == *"not enough of the boot time budget left to build"* ]] || { echo "$output"; return 1; }
    [[ "$(_calls)" != *"dkms install"* ]]
}

@test "systemd: a build that runs out of time is named as such, under a timeout" {
    echo "$NEW" > "$T/uname"
    _mk_server "$NEW"; : > "$T/dkms.rc124"
    _stub timeout 'echo "timeout $*" >> "$T/calls"; shift 3; exec "$@"'
    run "$H" --systemd
    [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
    [[ "$output" == *"kernel $NEW: NOT built: the build did not finish within"* ]] || { echo "$output"; return 1; }
    [[ "$(_calls)" == *"timeout -k 5 "*" dkms install"* ]]
}

@test "systemd: a modprobe that runs out of time does not blame Secure Boot" {
    _mk_server "$OLD"; _put_ko "$OLD"
    _stub modprobe 'echo "modprobe $*" >> "$T/calls"; exit 124'
    run "$H" --systemd
    [ "$status" -eq 1 ]
    [[ "$output" == *"modprobe did not finish within"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"Secure Boot"* ]]
}

@test "prepare and revert: a running apt stops them" {
    _mk_server "$OLD"
    ln -s "$T/var/lib/dpkg/lock" "$T/proc/1/fd/7"
    run "$H" --prepare
    [ "$status" -eq 1 ]; [ "$(_sha "$(_src)")" = "$BASE_SHA" ]
    run "$H" --revert
    [ "$status" -eq 1 ]
}

@test "prepare: apt that starts while it waits for the lock stops it before the source changes" {
    _mk_server "$OLD"
    _signal_flock; _holder 'ln -s "$T/var/lib/dpkg/lock-frontend" "$T/proc/1/fd/7"'
    run timeout 60 "$H" --prepare
    wait
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    [ -e "$T/flock.waiting" ]
    [[ "$output" == *"apt or dpkg is running"* ]]
    [ "$(_sha "$(_src)")" = "$BASE_SHA" ]
}

@test "hook: a failed source fix is exit 1 and leaves no stamp" {
    sed -i '/^AWG_KMOD_PR218_EOF$/i +/* tampered */' "$H"
    _mk_server "$OLD"
    run "$H" --hook
    [ "$status" -eq 1 ]
    [ ! -e "$(_stamp)" ]
}

@test "hook: two registrations remove an old stamp" {
    _mk_server "$OLD"
    "$H" --hook >/dev/null 2>&1; [ -s "$(_stamp)" ]
    mkdir -p "$T/usr/src/amneziawg-1.0.1" "$T/var/lib/dkms/amneziawg/1.0.1"
    ln -s "$T/usr/src/amneziawg-1.0.1" "$T/var/lib/dkms/amneziawg/1.0.1/source"
    run "$H" --hook
    [ "$status" -eq 1 ]
    [ ! -e "$(_stamp)" ]
}

@test "helper: not root is refused before anything" {
    _mk_server "$OLD"
    _stub id 'echo 1000'
    run "$H" --repair
    [ "$status" -eq 1 ]
    [[ "$output" == *"root privileges required"* ]]
    [ -z "$(_calls)" ]
}

@test "repair: no registered source is exit 2 (so --finish is never reached)" {
    run "$H" --repair
    [ "$status" -eq 2 ]
    [[ "$output" == *"no AmneziaWG DKMS source is registered"* ]]
}

# ---------- arguments ----------

@test "helper: --version identifies the new helper, an unknown mode is exit 2" {
    run "$H" --version
    [ "$status" -eq 0 ]; [ "$output" = "amneziawg-ensure-module 3" ]
    run "$H" --bogus
    [ "$status" -eq 2 ]
}

# ---------- --status (K2b): read-only facts ----------

# Runs --status with stdout only (stderr is chatter) into $T/st.out.
_status() { run bash -c '"$1" --status 2>/dev/null' _ "$H"; printf '%s\n' "$output" > "$T/st.out"; }
_rec() { grep -E "^$1( |\$)" "$T/st.out" || true; }

@test "status: a healthy server - every record, exactly one running kernel, complete, nothing changed" {
    _mk_server "$OLD" "$NEW"
    "$H" --repair >/dev/null 2>&1
    rm -f "$T/calls"
    local before; before=$(_sha "$(_src)")
    _status
    [ "$status" -eq 0 ] || { cat "$T/st.out"; return 1; }
    [ "$(_rec path)" = "path kind=ppa reason=-" ]
    [ "$(_rec source)" = "source state=patched version=1.0.0 fix=enabled" ]
    [ "$(_rec kernel | grep -c 'running=1')" -eq 1 ]
    [[ "$(_rec kernel)" == *"kernel release=$OLD running=1 image=1 module=1 headers=ok package=installed"* ]]
    [[ "$(_rec kernel)" == *"kernel release=$NEW running=0 image=1 module=1 headers=ok package=installed"* ]]
    [ "$(_rec module)" = "module loaded=0" ]
    [ "$(_rec packages)" = "packages audit=empty" ]
    [[ "$(tail -n 1 "$T/st.out")" =~ ^status\ complete=1\ time=[0-9]+$ ]]
    # Machine records only on stdout.
    [ -z "$(grep -vE '^(path|source|kernel|module|packages|status) ' "$T/st.out" || true)" ]
    # Read-only: no build, no configure, source as it was.
    [[ "$(_calls)" != *"dkms install"* && "$(_calls)" != *"--configure"* ]]
    [ "$(_sha "$(_src)")" = "$before" ]
}

@test "status: an already configured kernel without a module is reported even when nothing is unfinished" {
    local old2=6.8.0-31-generic
    _mk_server "$OLD"
    "$H" --repair >/dev/null 2>&1
    _mk_image "$old2"
    _status
    [ "$status" -eq 0 ]
    [[ "$(_rec kernel)" == *"kernel release=$old2 running=0 image=1 module=0 headers=missing package=installed"* ]] || { cat "$T/st.out"; return 1; }
    [ "$(_rec packages)" = "packages audit=empty" ]
}

@test "status: unfinished images, from /boot and from dpkg's side only" {
    _mk_server "$OLD"
    "$H" --repair >/dev/null 2>&1
    _mk_image 7.0.0-39-generic "install ok unpacked"
    echo "install ok half-configured" > "$T/st/linux-image-$NEW"
    echo "unfinished" > "$T/audit"
    _status
    [ "$status" -eq 0 ]
    [[ "$(_rec kernel)" == *"kernel release=7.0.0-39-generic running=0 image=1 module=0 headers=missing package=unfinished"* ]] || { cat "$T/st.out"; return 1; }
    [[ "$(_rec kernel)" == *"kernel release=$NEW running=0 image=0 module=0 headers=missing package=unfinished"* ]]
    [ "$(_rec packages)" = "packages audit=unfinished" ]
}

@test "status: the running kernel is always reported, image or not" {
    _mk_server
    mkdir -p "$T/lib/modules/$OLD"
    _status
    [ "$status" -eq 0 ] || { cat "$T/st.out"; return 1; }
    [ "$(_rec kernel)" = "kernel release=$OLD running=1 image=0 module=0 headers=missing package=none" ]
}

@test "status: a broken headers link is broken, a loaded module is loaded" {
    _mk_server "$OLD"
    "$H" --repair >/dev/null 2>&1
    rm "$T/lib/modules/$OLD/build"; ln -s "$T/nowhere" "$T/lib/modules/$OLD/build"
    mkdir -p "$T/sys/module/amneziawg"
    _status
    [[ "$(_rec kernel)" == *"release=$OLD running=1 image=1 module=1 headers=broken"* ]] || { cat "$T/st.out"; return 1; }
    [ "$(_rec module)" = "module loaded=1" ]
}

@test "status: what could not be looked at is unknown, never 'no' - and complete=0, exit 1, records kept" {
    [[ $EUID -ne 0 ]] || skip "root reads a mode-000 directory anyway"
    _mk_server "$OLD" "$NEW"
    "$H" --repair >/dev/null 2>&1
    chmod 000 "$T/lib/modules/$NEW/updates"
    _status
    chmod 755 "$T/lib/modules/$NEW/updates"
    [ "$status" -eq 1 ]
    [[ "$(_rec kernel)" == *"release=$NEW running=0 image=1 module=unknown"* ]] || { cat "$T/st.out"; return 1; }
    [[ "$(_rec kernel)" == *"release=$OLD running=1 image=1 module=1"* ]]
    [[ "$(tail -n 1 "$T/st.out")" == "status complete=0 "* ]]
}

@test "status: a failed listing of /boot or of the DKMS registrations is unknown, not 'no kernels' or 'not registered'" {
    # The listing itself fails (an I/O error or an LSM denial - root passes
    # permission tests, so this is injected): only the code of find tells.
    _mk_server "$OLD" "$NEW"
    "$H" --repair >/dev/null 2>&1
    local real; real=$(command -v find)
    _stub find "case \"\$*\" in *\"$T/boot\"*vmlinuz*) [[ -e \"$T/boot.fail\" ]] && { echo \"find: '$T/boot': Input/output error\" >&2; exit 1; } ;;
  *\"$T/var/lib/dkms/amneziawg\"*-maxdepth\ 2*) [[ -e \"$T/dkms.fail\" ]] && { echo \"find: '$T/var/lib/dkms/amneziawg/1.0.0': Input/output error\" >&2; exit 1; } ;; esac
exec \"$real\" \"\$@\""
    : > "$T/boot.fail"
    _status
    [ "$status" -eq 1 ]
    [[ "$(tail -n 1 "$T/st.out")" == "status complete=0 "* ]] || { cat "$T/st.out"; return 1; }
    [[ "$(_rec kernel)" != *"release=$NEW"* ]]
    rm "$T/boot.fail"; : > "$T/dkms.fail"
    _status
    [ "$status" -eq 1 ]
    [ "$(_rec path)" = "path kind=refused reason=query" ] || { cat "$T/st.out"; return 1; }
    [[ "$(_rec source)" == "source state=unknown "* ]]
}

@test "status: a /boot that is a symlink is walked, its kernels are reported" {
    _mk_server "$OLD" "$NEW"
    "$H" --repair >/dev/null 2>&1
    mv "$T/boot" "$T/boot.real"; ln -s "$T/boot.real" "$T/boot"
    # The owner records name the path as seen through the link.
    _status
    [ "$status" -eq 0 ] || { cat "$T/st.out"; return 1; }
    [[ "$(_rec kernel)" == *"release=$NEW running=0 image=1 module=1"* ]] || { cat "$T/st.out"; return 1; }
}

@test "status: a failed audit, ownership lookup or image list is complete=0" {
    _mk_server "$OLD"
    "$H" --repair >/dev/null 2>&1
    : > "$T/audit.fail"
    _status
    [ "$status" -eq 1 ]; [ "$(_rec packages)" = "packages audit=failed" ]
    rm "$T/audit.fail"; : > "$T/S.fail"
    _status
    [ "$status" -eq 1 ]
    [[ "$(_rec kernel)" == *"release=$OLD running=1 image=1 module=1 headers=ok package=unknown"* ]] || { cat "$T/st.out"; return 1; }
    # The owner is known, but its package status query fails: unknown too.
    rm "$T/S.fail"; : > "$T/dq.imgfail"
    _status
    [ "$status" -eq 1 ]
    [[ "$(_rec kernel)" == *"release=$OLD running=1 image=1 module=1 headers=ok package=unknown"* ]] || { cat "$T/st.out"; return 1; }
    rm "$T/dq.imgfail"
    : > "$T/dq.listfail"
    _status
    [ "$status" -eq 1 ]
}

@test "status: path kind repeats the installer's admission" {
    _mk_server "$OLD"
    _status; [ "$(_rec path)" = "path kind=ppa reason=-" ]
    echo "hold ok installed" > "$T/st/amneziawg-dkms"
    _status; [ "$(_rec path)" = "path kind=pinned reason=-" ]
    rm "$T/st/amneziawg-dkms"; echo amneziawg-dkms > "$T/holds"
    _status; [ "$(_rec path)" = "path kind=pinned reason=-" ]
    rm "$T/holds"; echo "unknown ok not-installed" > "$T/st/amneziawg-dkms"
    _status; [ "$(_rec path)" = "path kind=none reason=-" ]
    rm "$T/st/amneziawg-dkms"; echo "install ok installed" > "$T/st/amneziawg-kmod-6.8.0-100-generic"
    _status; [ "$(_rec path)" = "path kind=prebuilt reason=-" ]
    rm "$T/st/amneziawg-kmod-6.8.0-100-generic"
    echo "other-pkg: $T/usr/src/amneziawg-1.0.0/dkms.conf" > "$T/own/dkms.conf"
    _status; [ "$(_rec path)" = "path kind=refused reason=owner" ]
    echo "diversion by x from: $T/usr/src/amneziawg-1.0.0/dkms.conf" > "$T/own/dkms.conf"
    _status; [ "$(_rec path)" = "path kind=refused reason=owner" ]
    echo "amneziawg-dkms:amd64: $T/usr/src/amneziawg-1.0.0/dkms.conf" > "$T/own/dkms.conf"
    _status; [ "$(_rec path)" = "path kind=ppa reason=-" ]
    # A diversion record next to the real owner names no owner: still ppa.
    printf 'diversion by local from: %s\namneziawg-dkms: %s\n' "$T/usr/src/amneziawg-1.0.0/dkms.conf" "$T/usr/src/amneziawg-1.0.0/dkms.conf" > "$T/own/dkms.conf"
    _status; [ "$(_rec path)" = "path kind=ppa reason=-" ]
    mkdir -p "$T/usr/src/amneziawg-2.0.0" "$T/var/lib/dkms/amneziawg/2.0.0"
    ln -s "$T/usr/src/amneziawg-2.0.0" "$T/var/lib/dkms/amneziawg/2.0.0/source"
    _status; [ "$(_rec path)" = "path kind=refused reason=ambiguous" ]; [[ "$(_rec source)" == "source state=ambiguous "* ]]
    # Which source is meant is not known: incomplete, exit 1.
    [ "$status" -eq 1 ]; [[ "$(tail -n 1 "$T/st.out")" == "status complete=0 "* ]]
    rm -rf "${T:?}/var/lib/dkms/amneziawg"
    _status; [ "$(_rec path)" = "path kind=refused reason=noreg" ]; [[ "$(_rec source)" == "source state=none "* ]]
}

@test "status: any failed admission query is refused reason=query and complete=0, never ppa" {
    _mk_server "$OLD"
    : > "$T/dq.dkmsfail"
    _status; [ "$status" -eq 1 ]; [ "$(_rec path)" = "path kind=refused reason=query" ]
    rm "$T/dq.dkmsfail"; : > "$T/am.fail"
    _status; [ "$status" -eq 1 ]; [ "$(_rec path)" = "path kind=refused reason=query" ]
    rm "$T/am.fail"; : > "$T/dq.listfail"
    _status; [ "$status" -eq 1 ]; [ "$(_rec path)" = "path kind=refused reason=query" ]
    rm "$T/dq.listfail"; : > "$T/S.fail"
    _status; [ "$(_rec path)" = "path kind=refused reason=query" ]
}

@test "status: no dkms is refused, the revert marker shows as fix=disabled" {
    _mk_server "$OLD"
    rm "$T/bin/dkms"
    if command -v dkms >/dev/null; then skip "a real dkms is on this host"; fi
    _status
    [ "$(_rec path)" = "path kind=refused reason=nodkms" ]
    mkdir -p "$T/var/lib/amneziawg"; : > "$T/var/lib/amneziawg/kmod-fix.disabled"
    _status
    [[ "$(_rec source)" == *" fix=disabled" ]]
}

@test "status: works on both installers' helpers alike" {
    _mk_server "$OLD"
    _status; local ru; ru=$(grep -v '^status ' "$T/st.out")
    _mk_helper install_amneziawg_en.sh
    _status; [ "$(grep -v '^status ' "$T/st.out")" = "$ru" ]
}
