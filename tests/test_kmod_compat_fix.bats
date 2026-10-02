#!/usr/bin/env bats
# awg_kmod_compat_fix: kernel 7.0 udp_tunnel backport fix for the AmneziaWG
# module source (exact SHA-256 of compat/compat.h + upstream PR #218).
# Fixtures (tests/fixtures/kmod): the real BASE compat.h and the PR #218 diff.

load test_helper

BASE_SHA=b14346040ce0188c47e2db2baad1a4f21aa784510f6c95bbb4aa58d5bbe691c9
FIXED_SHA=8d47a358b4df0b2187788ce6f88ad63128218de1be22c78b263ef3e5d770c26b

_fx() { printf '%s' "$BATS_TEST_DIRNAME/fixtures/kmod/$1"; }
_sha() { sha256sum -- "$1" | cut -d' ' -f1; }
# One source tree in the DKMS layout (<dir>/compat/compat.h).
_mk_src() {
    SRC="$TEST_DIR/src"
    rm -rf "$SRC"; mkdir -p "$SRC/compat"
    cp "$(_fx compat.h.base)" "$SRC/compat/compat.h"
    chmod 0640 "$SRC/compat/compat.h"
}
# Stdout only: patch talks on stderr, the contract is one word on stdout.
kf() { awg_kmod_compat_fix "$@" 2>/dev/null; }
# Function body from a file: from its header line to the first unindented
# closing brace.
_body() { awk '/^awg_kmod_compat_fix\(\) \{$/{f=1} f{print} f&&/^\}$/{exit}' "$BATS_TEST_DIRNAME/../$1"; }
# Anything left next to compat.h besides compat.h and its backup.
_leftovers() { find "$SRC/compat" -mindepth 1 ! -name compat.h ! -name compat.h.awg-base -printf '%f\n'; }
# A directory of wrappers that shadows one tool; the wrapper body runs the
# real tool and then the given extra shell line.
_wrap() { # tool extra-line
    local real; real=$(command -v "$1")
    mkdir -p "$TEST_DIR/bin"
    printf '#!/bin/bash\n%s "$@"; rc=$?\n%s\nexit $rc\n' "$real" "$2" > "$TEST_DIR/bin/$1"
    chmod +x "$TEST_DIR/bin/$1"
}

setup() {
    TEST_DIR=$(mktemp -d)
    log() { :; }; log_warn() { :; }; log_error() { :; }; log_debug() { :; }
    source "$BATS_TEST_DIRNAME/../awg_common.sh"
    export AWG_KMOD_LOCK="$TEST_DIR/kmod.lock"
    unset AWG_KMOD_LOCK_WAIT AWG_KMOD_LOCK_HELD
    command -v patch >/dev/null || skip "patch not installed"
    command -v flock >/dev/null || skip "flock not available (not Linux)"
    _mk_src
}

teardown() { rm -rf "$TEST_DIR"; }

# ---------- one implementation in four places ----------

@test "kmod: the function body is byte-identical in both libraries and both helpers" {
    local ref f b
    ref=$(_body awg_common.sh)
    [ "$(wc -l <<<"$ref")" -gt 50 ]
    for f in awg_common_en.sh install_amneziawg.sh install_amneziawg_en.sh; do
        b=$(_body "$f")
        [ "$b" = "$ref" ] || { echo "differs: $f"; diff <(printf '%s\n' "$ref") <(printf '%s\n' "$b") | head -20; return 1; }
    done
}

@test "kmod: the helper copy sits inside the ensure-module heredoc" {
    local s
    for s in install_amneziawg.sh install_amneziawg_en.sh; do
        awk "/AWG_ENSURE_HELPER_EOF'/,/^AWG_ENSURE_HELPER_EOF\$/" "$BATS_TEST_DIRNAME/../$s" \
            | grep -q '^awg_kmod_compat_fix() {$' || { echo "not in helper: $s"; return 1; }
    done
}

@test "kmod: fixtures match the hashes pinned in the function" {
    local b
    b=$(_body awg_common.sh)
    [[ "$b" == *"base_sha=$BASE_SHA"* ]]
    [[ "$b" == *"fixed_sha=$FIXED_SHA"* ]]
    [ "$(_sha "$(_fx compat.h.base)")" = "$BASE_SHA" ]
    patch --batch --fuzz=0 -o "$TEST_DIR/out.h" "$(_fx compat.h.base)" < "$(_fx pr218.diff)" >/dev/null
    [ "$(_sha "$TEST_DIR/out.h")" = "$FIXED_SHA" ]
}

# ---------- classification and arguments ----------

@test "kmod: check classifies base, patched, foreign, absent" {
    run kf check "$SRC";                       [ "$status" -eq 0 ]; [ "$output" = base ]
    kf apply "$SRC" "$(_fx pr218.diff)" >/dev/null
    run kf check "$SRC";                       [ "$status" -eq 0 ]; [ "$output" = patched ]
    echo '/* local edit */' >> "$SRC/compat/compat.h"
    run kf check "$SRC";                       [ "$status" -eq 0 ]; [ "$output" = foreign ]
    rm "$SRC/compat/compat.h"
    run kf check "$SRC";                       [ "$status" -eq 0 ]; [ "$output" = absent ]
}

@test "kmod: a missing source dir or a compat that is not a dir is error:src" {
    run kf check "$TEST_DIR/nowhere";                  [ "$status" -eq 1 ]; [ "$output" = error:src ]
    run kf apply "$TEST_DIR/nowhere" "$(_fx pr218.diff)"; [ "$status" -eq 1 ]; [ "$output" = error:src ]
    [ ! -e "$TEST_DIR/nowhere" ]
    mkdir "$TEST_DIR/odd"; : > "$TEST_DIR/odd/compat"
    run kf apply "$TEST_DIR/odd" "$(_fx pr218.diff)"; [ "$status" -eq 1 ]; [ "$output" = error:src ]
}

@test "kmod: a symlinked compat.h is unsafe, exits 1 and its target is never written" {
    mv "$SRC/compat/compat.h" "$TEST_DIR/real.h"
    ln -s "$TEST_DIR/real.h" "$SRC/compat/compat.h"
    run kf check "$SRC";                         [ "$status" -eq 0 ]; [ "$output" = unsafe ]
    run kf apply "$SRC" "$(_fx pr218.diff)";     [ "$status" -eq 1 ]; [ "$output" = unsafe ]
    run kf revert "$SRC";                        [ "$status" -eq 1 ]; [ "$output" = unsafe ]
    [ "$(_sha "$TEST_DIR/real.h")" = "$BASE_SHA" ]
    [ -L "$SRC/compat/compat.h" ]
}

@test "kmod: a FIFO in place of compat.h is unsafe and nothing blocks on it" {
    rm "$SRC/compat/compat.h"; mkfifo "$SRC/compat/compat.h"
    run timeout 10 bash -c 'source "$1"; awg_kmod_compat_fix check "$2"' _ "$BATS_TEST_DIRNAME/../awg_common.sh" "$SRC"
    [ "$status" -eq 0 ]; [ "$output" = unsafe ]
}

@test "kmod: check does not take the lock" {
    exec {fd}>>"$AWG_KMOD_LOCK"; flock -n "$fd"
    run kf check "$SRC"
    exec {fd}>&-
    [ "$status" -eq 0 ]; [ "$output" = base ]
}

@test "kmod: an unknown mode or an empty source dir is a usage error" {
    run kf bogus "$SRC"
    [ "$status" -eq 1 ]; [ "$output" = error:usage ]
    run kf apply ""
    [ "$status" -eq 1 ]; [ "$output" = error:usage ]
}

# ---------- apply ----------

@test "kmod: apply turns base into patched, keeps mode and saves an exact backup" {
    run kf apply "$SRC" "$(_fx pr218.diff)"
    [ "$status" -eq 0 ]; [ "$output" = applied ]
    [ "$(_sha "$SRC/compat/compat.h")" = "$FIXED_SHA" ]
    [ "$(stat -c %a "$SRC/compat/compat.h")" = 640 ]
    [ "$(_sha "$SRC/compat/compat.h.awg-base")" = "$BASE_SHA" ]
    [ -z "$(_leftovers)" ]
}

@test "kmod: apply on patched is a no-op" {
    kf apply "$SRC" "$(_fx pr218.diff)" >/dev/null
    local before; before=$(stat -c %Y.%i "$SRC/compat/compat.h")
    run kf apply "$SRC" "$(_fx pr218.diff)"
    [ "$status" -eq 0 ]; [ "$output" = already ]
    [ "$(stat -c %Y.%i "$SRC/compat/compat.h")" = "$before" ]
}

@test "kmod: apply leaves a foreign source alone (local edit)" {
    echo '/* someone else */' >> "$SRC/compat/compat.h"
    local before; before=$(_sha "$SRC/compat/compat.h")
    run kf apply "$SRC" "$(_fx pr218.diff)"
    [ "$status" -eq 0 ]; [ "$output" = foreign ]
    [ "$(_sha "$SRC/compat/compat.h")" = "$before" ]
    [ ! -e "$SRC/compat/compat.h.awg-base" ]
}

@test "kmod: apply on a source dir without compat.h reports absent" {
    rm "$SRC/compat/compat.h"
    run kf apply "$SRC" "$(_fx pr218.diff)"
    [ "$status" -eq 0 ]; [ "$output" = absent ]
    [ -z "$(_leftovers)" ]
}

@test "kmod: apply without a readable diff fails and touches nothing" {
    run kf apply "$SRC"
    [ "$status" -eq 1 ]; [ "$output" = error:no-diff ]
    run kf apply "$SRC" "$TEST_DIR/missing.diff"
    [ "$status" -eq 1 ]; [ "$output" = error:no-diff ]
    [ "$(_sha "$SRC/compat/compat.h")" = "$BASE_SHA" ]
}

@test "kmod: a diff that does not apply fails, the original is intact, no temp files" {
    printf 'not a diff\n' > "$TEST_DIR/bad.diff"
    run kf apply "$SRC" "$TEST_DIR/bad.diff"
    [ "$status" -eq 1 ]; [ "$output" = error:patch ]
    [ "$(_sha "$SRC/compat/compat.h")" = "$BASE_SHA" ]
    [ -z "$(_leftovers)" ]
}

@test "kmod: a diff that applies but gives another result is rejected" {
    # Same hunk plus one extra added line: patch succeeds, the hash does not match.
    sed 's/^@@ -1444,11 +1444,36 @@.*$/@@ -1444,11 +1444,37 @@\n+\/* extra *\//' "$(_fx pr218.diff)" \
        > "$TEST_DIR/other.diff"
    grep -qx '+/\* extra \*/' "$TEST_DIR/other.diff"
    patch --batch --fuzz=0 -o "$TEST_DIR/probe.h" "$(_fx compat.h.base)" < "$TEST_DIR/other.diff" >/dev/null
    [ "$(_sha "$TEST_DIR/probe.h")" != "$FIXED_SHA" ]
    run kf apply "$SRC" "$TEST_DIR/other.diff"
    [ "$status" -eq 1 ]; [ "$output" = error:result ]
    [ "$(_sha "$SRC/compat/compat.h")" = "$BASE_SHA" ]
    [ -z "$(_leftovers)" ]
}

@test "kmod: without the patch tool apply fails and touches nothing" {
    local bin="$TEST_DIR/bin" t
    mkdir "$bin"
    for t in sha256sum mktemp cp mv rm chmod chown flock; do ln -s "$(command -v "$t")" "$bin/$t"; done
    PATH="$bin" run kf apply "$SRC" "$(_fx pr218.diff)"
    [ "$status" -eq 1 ]; [ "$output" = error:no-patch ]
    [ "$(_sha "$SRC/compat/compat.h")" = "$BASE_SHA" ]
}

@test "kmod: without flock apply fails instead of running unlocked" {
    local bin="$TEST_DIR/bin" t
    mkdir "$bin"
    for t in sha256sum mktemp cp mv rm chmod chown patch; do ln -s "$(command -v "$t")" "$bin/$t"; done
    PATH="$bin" run kf apply "$SRC" "$(_fx pr218.diff)"
    [ "$status" -eq 1 ]; [ "$output" = error:no-flock ]
    [ "$(_sha "$SRC/compat/compat.h")" = "$BASE_SHA" ]
}

@test "kmod: a source replaced before the snapshot is not patched" {
    # A package unpack rewrites compat.h right before it is copied into the
    # staging dir (dpkg does not take our lock): the snapshot must not match.
    mkdir -p "$TEST_DIR/bin"
    printf '#!/bin/bash\n[[ "$*" == *"/compat/compat.h "* ]] && echo "/* unpacked */" >> %q\nexec %q "$@"\n' \
        "$SRC/compat/compat.h" "$(command -v cp)" > "$TEST_DIR/bin/cp"
    chmod +x "$TEST_DIR/bin/cp"
    PATH="$TEST_DIR/bin:$PATH" run kf apply "$SRC" "$(_fx pr218.diff)"
    [ "$status" -eq 1 ]; [ "$output" = error:changed ]
    [ "$(tail -n1 "$SRC/compat/compat.h")" = '/* unpacked */' ]
    [ ! -e "$SRC/compat/compat.h.awg-base" ]
    [ -z "$(_leftovers)" ]
}

@test "kmod: a source replaced during the patch is not overwritten" {
    _wrap patch "echo '/* unpacked */' >> $(printf %q "$SRC/compat/compat.h")"
    PATH="$TEST_DIR/bin:$PATH" run kf apply "$SRC" "$(_fx pr218.diff)"
    [ "$status" -eq 1 ]; [ "$output" = error:changed ]
    [ "$(tail -n1 "$SRC/compat/compat.h")" = '/* unpacked */' ]
    [ -z "$(_leftovers)" ]
}

@test "kmod: the final re-check catches a replacement even with a valid backup" {
    cp -p "$(_fx compat.h.base)" "$SRC/compat/compat.h.awg-base"
    _wrap patch "echo '/* unpacked */' >> $(printf %q "$SRC/compat/compat.h")"
    PATH="$TEST_DIR/bin:$PATH" run kf apply "$SRC" "$(_fx pr218.diff)"
    [ "$status" -eq 1 ]; [ "$output" = error:changed ]
    [ "$(tail -n1 "$SRC/compat/compat.h")" = '/* unpacked */' ]
    [ -z "$(_leftovers)" ]
}

@test "kmod: a failed ownership copy is error:perm and touches nothing" {
    mkdir -p "$TEST_DIR/bin"
    printf '#!/bin/bash\nexit 1\n' > "$TEST_DIR/bin/chown"; chmod +x "$TEST_DIR/bin/chown"
    PATH="$TEST_DIR/bin:$PATH" run kf apply "$SRC" "$(_fx pr218.diff)"
    [ "$status" -eq 1 ]; [ "$output" = error:perm ]
    [ "$(_sha "$SRC/compat/compat.h")" = "$BASE_SHA" ]
    [ -z "$(_leftovers)" ]
}

@test "kmod: a stale backup is replaced with the exact base" {
    echo junk > "$SRC/compat/compat.h.awg-base"
    run kf apply "$SRC" "$(_fx pr218.diff)"
    [ "$status" -eq 0 ]; [ "$output" = applied ]
    [ "$(_sha "$SRC/compat/compat.h.awg-base")" = "$BASE_SHA" ]
}

@test "kmod: a backup path that is a symlink, a dir or a FIFO is refused" {
    ln -s "$TEST_DIR/elsewhere" "$SRC/compat/compat.h.awg-base"
    run kf apply "$SRC" "$(_fx pr218.diff)"
    [ "$status" -eq 1 ]; [ "$output" = error:backup ]
    [ ! -e "$TEST_DIR/elsewhere" ]
    rm "$SRC/compat/compat.h.awg-base"; mkdir "$SRC/compat/compat.h.awg-base"
    run kf apply "$SRC" "$(_fx pr218.diff)"
    [ "$status" -eq 1 ]; [ "$output" = error:backup ]
    [ -z "$(ls -A "$SRC/compat/compat.h.awg-base")" ]
    rmdir "$SRC/compat/compat.h.awg-base"; mkfifo "$SRC/compat/compat.h.awg-base"
    run timeout 10 bash -c 'source "$1"; awg_kmod_compat_fix apply "$2" "$3" 2>/dev/null' _ \
        "$BATS_TEST_DIRNAME/../awg_common.sh" "$SRC" "$(_fx pr218.diff)"
    [ "$status" -eq 1 ]; [ "$output" = error:backup ]
    [ "$(_sha "$SRC/compat/compat.h")" = "$BASE_SHA" ]
}

# ---------- lock ----------

@test "kmod: a held lock makes apply and revert fail fast, the source is untouched" {
    exec {fd}>>"$AWG_KMOD_LOCK"; flock -n "$fd"
    run kf apply "$SRC" "$(_fx pr218.diff)"
    local st=$status out=$output
    AWG_KMOD_LOCK_WAIT=1 run kf apply "$SRC" "$(_fx pr218.diff)"
    local st2=$status out2=$output
    run kf revert "$SRC"
    local st3=$status out3=$output
    exec {fd}>&-
    [ "$st" -eq 1 ]; [ "$out" = error:busy ]
    [ "$st2" -eq 1 ]; [ "$out2" = error:busy ]
    [ "$st3" -eq 1 ]; [ "$out3" = error:busy ]
    [ "$(_sha "$SRC/compat/compat.h")" = "$BASE_SHA" ]
    run kf apply "$SRC" "$(_fx pr218.diff)"
    [ "$output" = applied ]
}

@test "kmod: a caller that holds the lock passes AWG_KMOD_LOCK_HELD=1" {
    exec {fd}>>"$AWG_KMOD_LOCK"; flock -n "$fd"
    AWG_KMOD_LOCK_HELD=1 run kf apply "$SRC" "$(_fx pr218.diff)"
    exec {fd}>&-
    [ "$status" -eq 0 ]; [ "$output" = applied ]
}

@test "kmod: an unusable lock path fails instead of running unlocked" {
    AWG_KMOD_LOCK="$TEST_DIR/no/such/dir/lock" run kf apply "$SRC" "$(_fx pr218.diff)"
    [ "$status" -eq 1 ]; [ "$output" = error:lock ]
    [ "$(_sha "$SRC/compat/compat.h")" = "$BASE_SHA" ]
}

@test "kmod: repeated calls do not leak file descriptors" {
    local before after pid
    pid=$BASHPID
    before=$(ls "/proc/$pid/fd" | sort | tr '\n' ' ')
    for _ in 1 2 3; do
        awg_kmod_compat_fix apply "$SRC" "$(_fx pr218.diff)" >/dev/null 2>&1
        awg_kmod_compat_fix revert "$SRC" >/dev/null 2>&1
        awg_kmod_compat_fix apply "$SRC" /nonexistent >/dev/null 2>&1 || true
        AWG_KMOD_LOCK="$TEST_DIR/no/dir/l" awg_kmod_compat_fix apply "$SRC" x >/dev/null 2>&1 || true
    done
    after=$(ls "/proc/$pid/fd" | sort | tr '\n' ' ')
    [ "$before" = "$after" ] || { echo "before: $before"; echo "after:  $after"; return 1; }
}

# ---------- revert ----------

@test "kmod: revert restores base and keeps the current mode" {
    kf apply "$SRC" "$(_fx pr218.diff)" >/dev/null
    chmod 0600 "$SRC/compat/compat.h"
    run kf revert "$SRC"
    [ "$status" -eq 0 ]; [ "$output" = reverted ]
    [ "$(_sha "$SRC/compat/compat.h")" = "$BASE_SHA" ]
    [ "$(stat -c %a "$SRC/compat/compat.h")" = 600 ]
    [ -z "$(_leftovers)" ]
    run kf revert "$SRC"
    [ "$status" -eq 0 ]; [ "$output" = already ]
}

@test "kmod: revert refuses a wrong or missing backup and a foreign source" {
    kf apply "$SRC" "$(_fx pr218.diff)" >/dev/null
    echo junk > "$SRC/compat/compat.h.awg-base"
    run kf revert "$SRC"
    [ "$status" -eq 1 ]; [ "$output" = error:revert ]
    [ "$(_sha "$SRC/compat/compat.h")" = "$FIXED_SHA" ]
    rm "$SRC/compat/compat.h.awg-base"
    run kf revert "$SRC"
    [ "$status" -eq 1 ]; [ "$output" = error:revert ]
    _mk_src; echo '/* x */' >> "$SRC/compat/compat.h"
    run kf revert "$SRC"
    [ "$status" -eq 1 ]; [ "$output" = error:revert ]
}

@test "kmod: revert on a source dir without compat.h reports absent" {
    rm "$SRC/compat/compat.h"
    run kf revert "$SRC"
    [ "$status" -eq 0 ]; [ "$output" = absent ]
}

@test "kmod: revert does not overwrite a source replaced while it worked" {
    kf apply "$SRC" "$(_fx pr218.diff)" >/dev/null
    _wrap cp "echo '/* unpacked */' >> $(printf %q "$SRC/compat/compat.h")"
    PATH="$TEST_DIR/bin:$PATH" run kf revert "$SRC"
    [ "$status" -eq 1 ]; [ "$output" = error:changed ]
    [ "$(tail -n1 "$SRC/compat/compat.h")" = '/* unpacked */' ]
    [ -z "$(_leftovers)" ]
}

@test "kmod: revert checks the copy it is about to install" {
    kf apply "$SRC" "$(_fx pr218.diff)" >/dev/null
    _wrap cp 'echo "/* torn */" >> "${@: -1}"'
    PATH="$TEST_DIR/bin:$PATH" run kf revert "$SRC"
    [ "$status" -eq 1 ]; [ "$output" = error:copy ]
    [ "$(_sha "$SRC/compat/compat.h")" = "$FIXED_SHA" ]
    [ -z "$(_leftovers)" ]
}

# ---------- the helper copy under the helper's own flags ----------

_helper_fn() {
    awk "/AWG_ENSURE_HELPER_EOF'/,/^AWG_ENSURE_HELPER_EOF\$/" "$BATS_TEST_DIRNAME/../$1" \
        | awk '/^awg_kmod_compat_fix\(\) \{$/{f=1} f{print} f&&/^\}$/{exit}'
}

@test "kmod: each helper copy succeeds and fails cleanly under set -euo pipefail" {
    local s fn
    printf 'not a diff\n' > "$TEST_DIR/bad.diff"
    for s in install_amneziawg.sh install_amneziawg_en.sh; do
        fn=$(_helper_fn "$s"); [ -n "$fn" ]
        _mk_src
        # Failure path called directly, no || guard: the child must print the
        # token and then exit 1 through errexit, not die before printing.
        run /bin/bash -c 'set -euo pipefail; eval "$1"
            awg_kmod_compat_fix apply "$2" "$3" 2>/dev/null
            echo unreachable' _ "$fn" "$SRC" "$TEST_DIR/bad.diff"
        [ "$status" -eq 1 ] || { echo "$s: status $status"; return 1; }
        [ "$output" = error:patch ] || { echo "$s: $output"; return 1; }
        [ -z "$(_leftovers)" ]
        run /bin/bash -c 'set -euo pipefail; eval "$1"
            awg_kmod_compat_fix check "$2"
            awg_kmod_compat_fix apply "$2" "$3" 2>/dev/null
            awg_kmod_compat_fix apply "$2" "$3"
            awg_kmod_compat_fix revert "$2"
            echo end' _ "$fn" "$SRC" "$(_fx pr218.diff)"
        [ "$status" -eq 0 ] || { echo "$s: status $status: $output"; return 1; }
        [ "$output" = $'base\napplied\nalready\nreverted\nend' ] || { echo "$s: $output"; return 1; }
    done
}

@test "kmod: a failing cleanup does not abort a strict-mode caller" {
    local fn
    fn=$(_helper_fn install_amneziawg.sh)
    mkdir -p "$TEST_DIR/bin"
    printf '#!/bin/bash\nexit 1\n' > "$TEST_DIR/bin/rm"; chmod +x "$TEST_DIR/bin/rm"
    run env PATH="$TEST_DIR/bin:$PATH" /bin/bash -c 'set -euo pipefail; eval "$1"
        awg_kmod_compat_fix apply "$2" "$3" 2>/dev/null
        echo end' _ "$fn" "$SRC" "$(_fx pr218.diff)"
    [ "$status" -eq 0 ]; [ "$output" = $'applied\nend' ]
    [ "$(_sha "$SRC/compat/compat.h")" = "$FIXED_SHA" ]
}
