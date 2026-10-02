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
        "$T/helper.raw" > "$T/helper"
    n=$(grep -c "^[A-Z_]*_DIR=$T/\|^SRC_PREFIX=$T/" "$T/helper")
    [ "$n" -eq 8 ] || { echo "path constants rewritten: $n of 8"; return 1; }
    chmod +x "$T/helper"
    H="$T/helper"
}

_stub() { printf '#!/bin/bash\n%s\n' "$2" > "$T/bin/$1"; chmod +x "$T/bin/$1"; }

# A server: one DKMS registration amneziawg/1.0.0 with the PPA source, and
# the given kernels, each with headers and an image in /boot.
_mk_server() {
    local k
    mkdir -p "$T/usr/src/amneziawg-1.0.0/compat" "$T/var/lib/dkms/amneziawg/1.0.0" \
             "$T/boot" "$T/proc/1/fd" "$T/var/lib/dpkg" "$T/run"
    cp "$(_fx compat.h.base)" "$T/usr/src/amneziawg-1.0.0/compat/compat.h"
    ln -s "$T/usr/src/amneziawg-1.0.0" "$T/var/lib/dkms/amneziawg/1.0.0/source"
    for k in "$@"; do _mk_kernel "$k"; done
}
_mk_kernel() {
    mkdir -p "$T/lib/modules/$1/hdr"
    ln -s hdr "$T/lib/modules/$1/build"
    : > "$T/lib/modules/$1/modules.order"
    : > "$T/boot/vmlinuz-$1"
}
_ko() { printf '%s' "$T/lib/modules/$1/updates/dkms/amneziawg.ko.zst"; }
_src() { printf '%s' "$T/usr/src/amneziawg-1.0.0/compat/compat.h"; }
_calls() { cat "$T/calls" 2>/dev/null || true; }
_stamp() { printf '%s' "$T/var/lib/amneziawg/ensure-module.stamp"; }

setup() {
    T=$(mktemp -d); export T FIXED_SHA
    # What every real system has: /boot, /run, a process table.
    mkdir -p "$T/bin" "$T/boot" "$T/run" "$T/proc/1/fd"
    command -v flock >/dev/null || skip "flock not available (not Linux)"
    command -v patch >/dev/null || skip "patch not installed"
    _stub id 'echo 0'
    _stub uname 'cat "$T/uname" 2>/dev/null || echo '"$OLD"
    _stub depmod 'echo "depmod $*" >> "$T/calls"; [[ ! -e "$T/depmod.fail" ]]'
    _stub lsmod '[[ -e "$T/loaded" ]] && echo "amneziawg 1 0"; exit 0'
    _stub modprobe 'echo "modprobe $*" >> "$T/calls"
k=$(uname -r)
[[ -e "$T/modprobe.fail" ]] && exit 1
[[ -n "$(find "$T/lib/modules/$k" -name "amneziawg.ko*" -type f 2>/dev/null)" ]] || exit 1
: > "$T/loaded"'
    _stub dpkg-query 'cat "$T/pkg" 2>/dev/null || echo "1.0.0-0~202609061402+4569c4c install ok installed"'
    _stub dpkg 'echo "dpkg $*" >> "$T/calls"
case "$1" in
  --audit) cat "$T/audit" 2>/dev/null; exit 0 ;;
  --configure) [[ -e "$T/configure.fail" ]] && exit 1; rm -f "$T/audit"; exit 0 ;;
esac'
    _stub dkms 'echo "dkms $*" >> "$T/calls"
[[ "$1" == install ]] || exit 0
shift; k=""; v=""
while [[ $# -gt 0 ]]; do case "$1" in -k) k="$2"; shift ;; -v) v="$2"; shift ;; esac; shift; done
[[ -e "$T/dkms.side" ]] && bash "$T/dkms.side"
d="$T/var/lib/dkms/amneziawg/$v/build"; mkdir -p "$d"
[[ -e "$T/dkms.quietfail" ]] && exit 10
if [[ "$k" == 7.0.0-38* && "$(sha256sum < "$T/usr/src/amneziawg-$v/compat/compat.h" | cut -d" " -f1)" != "$FIXED_SHA" ]]; then
  echo "compat/compat.h:1449:31: error: passing argument 2 of '"'"'setup_udp_tunnel_sock'"'"' from incompatible pointer type [-Werror=incompatible-pointer-types]" > "$d/make.log"
  exit 10
fi
if [[ -e "$T/dkms.fail.$k" ]]; then echo "error: something else" > "$d/make.log"; exit 10; fi
mkdir -p "$T/lib/modules/$k/updates/dkms"; echo ko > "$T/lib/modules/$k/updates/dkms/amneziawg.ko.zst"'
    export PATH="$T/bin:$PATH"
    _mk_helper install_amneziawg.sh
}

teardown() { rm -rf "$T"; }

# ---------- the embedded fix ----------

@test "helper: the embedded fix is byte-identical to the PR #218 fixture in both installers" {
    local s
    for s in install_amneziawg.sh install_amneziawg_en.sh; do
        _raw_helper "$s" | awk "/<<'AWG_KMOD_PR218_EOF'\$/{f=1; next} /^AWG_KMOD_PR218_EOF\$/{f=0} f" > "$T/emb.diff"
        cmp "$T/emb.diff" "$(_fx pr218.diff)" || { echo "embedded fix differs: $s"; return 1; }
    done
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

@test "helper: a damaged embedded fix is refused and the source stays as it was" {
    sed -i '/^AWG_KMOD_PR218_EOF$/i +/* tampered */' "$H"
    _mk_server "$OLD"
    run "$H" --prepare
    [ "$status" -eq 1 ]
    [[ "$output" == *"embedded source fix is damaged"* ]]
    [ "$(_sha "$(_src)")" = "$BASE_SHA" ]
}

# ---------- --repair ----------

@test "repair: base source is fixed, every kernel gets its module, the stamp is written" {
    _mk_server "$OLD" "$NEW"
    run "$H" --repair
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(_sha "$(_src)")" = "$FIXED_SHA" ]
    [ -s "$(_ko "$OLD")" ]; [ -s "$(_ko "$NEW")" ]
    [ -s "$(_stamp)" ]
    grep -q '^v2 src=1.0.0:' "$(_stamp)"
}

@test "repair: on both installers' helpers" {
    _mk_helper install_amneziawg_en.sh
    _mk_server "$OLD" "$NEW"
    run "$H" --repair
    [ "$status" -eq 0 ]; [ -s "$(_ko "$NEW")" ]
}

@test "repair: a foreign source is not touched; the 7.0 kernel fails with the known-issue line, the running one is fine" {
    _mk_server "$OLD" "$NEW"
    echo '/* local edit */' >> "$(_src)"
    local before; before=$(_sha "$(_src)")
    run "$H" --repair
    [ "$status" -eq 1 ]
    [ "$(_sha "$(_src)")" = "$before" ]
    [[ "$output" == *"kernel $NEW: NOT built [known-issue:kernel-70-udp-tunnel]"* ]]
    [ -s "$(_ko "$OLD")" ]; [ ! -e "$(_ko "$NEW")" ]
    [ ! -e "$(_stamp)" ]
}

@test "repair: the running kernel without a module is exit 2" {
    echo "$NEW" > "$T/uname"
    _mk_server "$NEW"
    echo '/* local edit */' >> "$(_src)"
    run "$H" --repair
    [ "$status" -eq 2 ]
    [[ "$output" == *"kernel $NEW (running): NO module on disk"* ]]
}

@test "repair: a running apt (dpkg lock held open) stops it before anything changes" {
    _mk_server "$OLD" "$NEW"
    ln -s "$T/var/lib/dpkg/lock-frontend" "$T/proc/1/fd/7"
    run "$H" --repair
    [ "$status" -eq 2 ]
    [[ "$output" == *"apt or dpkg is running"* ]]
    [ "$(_sha "$(_src)")" = "$BASE_SHA" ]
    [ -z "$(_calls)" ]
}

@test "repair: an unreadable process table counts as unknown, not as idle" {
    _mk_server "$OLD"
    rm -rf "$T/proc"; mkdir -p "$T/proc"
    run "$H" --repair
    [ "$status" -eq 2 ]
    [[ "$output" == *"cannot tell whether apt or dpkg is running"* ]]
    [ -z "$(_calls)" ]
}

@test "repair: two registered versions or a broken source link: nothing is touched and nothing is built" {
    _mk_server "$OLD" "$NEW"
    mkdir -p "$T/usr/src/amneziawg-1.0.1/compat" "$T/var/lib/dkms/amneziawg/1.0.1"
    cp "$(_fx compat.h.base)" "$T/usr/src/amneziawg-1.0.1/compat/compat.h"
    ln -s "$T/usr/src/amneziawg-1.0.1" "$T/var/lib/dkms/amneziawg/1.0.1/source"
    run "$H" --repair
    [ "$status" -eq 2 ]
    [ "$(_sha "$(_src)")" = "$BASE_SHA" ]
    [ -z "$(_calls)" ]
    rm -rf "$T/var/lib/dkms/amneziawg/1.0.1"
    rm "$T/var/lib/dkms/amneziawg/1.0.0/source"
    ln -s "$T/nowhere" "$T/var/lib/dkms/amneziawg/1.0.0/source"
    run "$H" --repair
    [ "$status" -eq 2 ]
    [[ "$output" == *"source $T/var/lib/dkms/amneziawg/1.0.0/source -> $T/nowhere is not $T/usr/src/amneziawg-1.0.0"* ]]
    [ -z "$(_calls)" ]
}

@test "repair: a package change during the build voids the result" {
    _mk_server "$OLD" "$NEW"
    echo 'echo "1.0.0-0~new install ok installed" > "$T/pkg"' > "$T/dkms.side"
    run "$H" --repair
    [ "$status" -eq 2 ]
    [[ "$output" == *"changed while the module was built"* ]]
    [ ! -e "$(_stamp)" ]
}

@test "repair: an old make.log is not reported as the reason of a new failure" {
    _mk_server "$OLD" "$NEW"
    echo '/* local edit */' >> "$(_src)"
    mkdir -p "$T/var/lib/dkms/amneziawg/1.0.0/build"
    echo "x: passing argument 2 of 'setup_udp_tunnel_sock' from incompatible pointer type" \
        > "$T/var/lib/dkms/amneziawg/1.0.0/build/make.log"
    : > "$T/dkms.quietfail"
    run "$H" --repair
    [[ "$output" == *"kernel $NEW: NOT built (dkms rc=10); no fresh make.log"* ]]
    [[ "$output" != *"known-issue"* ]]
}

@test "repair: a failed build of the running kernel is exit 2 and leaves no stamp" {
    _mk_server "$OLD"
    : > "$T/dkms.fail.$OLD"
    run "$H" --repair
    [ "$status" -eq 2 ]
    [[ "$output" == *"kernel $OLD: NOT built (dkms rc=10); log: "* ]]
    [ ! -e "$(_stamp)" ]
}

@test "repair: a broken headers link is reported and skipped, not built" {
    _mk_server "$OLD"
    mkdir -p "$T/lib/modules/$NEW"; ln -s "$T/gone" "$T/lib/modules/$NEW/build"
    run "$H" --repair
    [ "$status" -eq 0 ]
    [[ "$output" == *"kernel $NEW: headers link"*"is broken; kernel skipped"* ]]
    [[ "$(_calls)" != *"-k $NEW"* ]]
}

@test "repair: a failed depmod keeps the stamp away" {
    _mk_server "$OLD"
    : > "$T/depmod.fail"
    run "$H" --repair
    [ "$status" -eq 1 ]
    [ ! -e "$(_stamp)" ]
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
    mkdir -p "$(dirname "$(_ko "$OLD")")"; echo ko > "$(_ko "$OLD")"
    run "$H" --hook
    [ "$status" -eq 0 ]
    grep -q '^v2 ' "$(_stamp)"
}

@test "hook: when another job holds the lock it does nothing and leaves the stamp alone" {
    _mk_server "$OLD" "$NEW"
    mkdir -p "$T/var/lib/amneziawg"; echo keep > "$(_stamp)"
    mkdir -p "$T/run/amneziawg"
    exec {fd}>>"$T/run/amneziawg/kmod.lock"; flock -n "$fd"
    run "$H" --hook
    exec {fd}>&-
    [ "$status" -eq 0 ]
    [[ "$output" == *"another AmneziaWG module job is running; skipped"* ]]
    [ "$(cat "$(_stamp)")" = keep ]
    [ "$(_sha "$(_src)")" = "$BASE_SHA" ]
    [ -z "$(_calls)" ]
}

@test "hook: runs inside apt, so a held dpkg lock does not stop it" {
    _mk_server "$OLD" "$NEW"
    ln -s "$T/var/lib/dpkg/lock-frontend" "$T/proc/1/fd/7"
    run "$H" --hook
    [ "$status" -eq 0 ]
    [ -s "$(_ko "$NEW")" ]
}

@test "hook: no registered source is a quiet no-op" {
    mkdir -p "$T/proc/1/fd"; _mk_kernel "$OLD"
    run "$H" --hook
    [ "$status" -eq 0 ]; [ -z "$output" ]
    [ -z "$(_calls)" ]
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
    mkdir -p "$(dirname "$(_ko "$OLD")")"; echo ko > "$(_ko "$OLD")"
    run "$H" --systemd
    [ "$status" -eq 0 ]
    [[ "$(_calls)" != *"dkms install"* ]]
    [ ! -e "$(_stamp)" ]
    [ -e "$T/loaded" ]
}

@test "systemd: without a module it builds the running kernel only, then loads it" {
    echo "$NEW" > "$T/uname"
    _mk_server "$OLD" "$NEW"
    run "$H" --systemd
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -s "$(_ko "$NEW")" ]; [ ! -e "$(_ko "$OLD")" ]
    [ "$(_sha "$(_src)")" = "$FIXED_SHA" ]
    [ ! -e "$(_stamp)" ]
}

@test "systemd: lock held by another job: no build, exit 1 when nothing is loadable" {
    _mk_server "$OLD"
    mkdir -p "$T/run/amneziawg"
    exec {fd}>>"$T/run/amneziawg/kmod.lock"; flock -n "$fd"
    run timeout 60 "$H" --systemd
    exec {fd}>&-
    [ "$status" -eq 1 ]
    [[ "$(_calls)" != *"dkms install"* ]]
}

@test "systemd: a module on disk that does not load gets one forced rebuild" {
    _mk_server "$OLD"
    mkdir -p "$(dirname "$(_ko "$OLD")")"; echo ko > "$(_ko "$OLD")"
    : > "$T/modprobe.fail"
    run "$H" --systemd
    [ "$status" -eq 1 ]
    [[ "$(_calls)" == *"dkms install -m amneziawg -v 1.0.0 -k $OLD --force"* ]]
    [[ "$output" == *"Secure Boot"* ]]
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
    mkdir -p "$T/proc/1/fd"
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

@test "finish: every bootable kernel has the module: configure runs and the audit is re-checked" {
    _mk_server "$OLD" "$NEW"
    "$H" --repair >/dev/null 2>&1
    echo "linux-image-$NEW is not configured yet" > "$T/audit"
    run "$H" --finish
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$(_calls)" == *"dpkg --configure -a"* ]]
}

@test "finish: a bootable kernel without headers and without the module blocks configure, by name" {
    _mk_server "$OLD"
    "$H" --repair >/dev/null 2>&1
    : > "$T/boot/vmlinuz-$NEW"
    echo "unfinished" > "$T/audit"
    run "$H" --finish
    [ "$status" -eq 1 ]
    [[ "$output" == *"kernel(s) without the AmneziaWG module: $NEW"* ]]
    [[ "$(_calls)" != *"--configure"* ]]
}

@test "finish: no kernels at all is not a pass" {
    mkdir -p "$T/boot" "$T/proc/1/fd"
    echo "unfinished" > "$T/audit"
    run "$H" --finish
    [ "$status" -eq 1 ]
    [[ "$output" == *"no kernels found"* ]]
    [[ "$(_calls)" != *"--configure"* ]]
}

@test "finish: still unfinished after configure is a failure" {
    _mk_server "$OLD"
    "$H" --repair >/dev/null 2>&1
    echo "unfinished" > "$T/audit"
    _stub dpkg 'echo "dpkg $*" >> "$T/calls"; [[ "$1" == --audit ]] && echo still; exit 0'
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

# ---------- arguments ----------

@test "helper: --version identifies the new helper, an unknown mode is exit 2" {
    run "$H" --version
    [ "$status" -eq 0 ]; [ "$output" = "amneziawg-ensure-module 2" ]
    run "$H" --bogus
    [ "$status" -eq 2 ]
}
