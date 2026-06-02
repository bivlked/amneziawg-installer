#!/usr/bin/env bats
# Tests for C6 (v5.15.3): awg_mktemp target-directory support so config writes
# stay on the same filesystem as their destination (atomic mv rename instead of
# a cross-fs copy+unlink when /tmp is mounted as tmpfs).
#
# Atomicity of mv itself is a kernel property and cannot be unit-tested; instead
# we prove the temp file is created in the target directory (same fs as the
# final file) and that call-sites pass that directory rather than relying on
# /tmp/$TMPDIR.

load test_helper

# Minimal awg(1) shim: only `awg pubkey` is needed by _ensure_server_public_key.
# Reads the private key on stdin and emits a deterministic fake public key.
mock_awg() {
    local bin="$TEST_DIR/bin"
    mkdir -p "$bin"
    cat > "$bin/awg" <<'SHIM'
#!/bin/bash
case "$1" in
    pubkey) cat >/dev/null; echo "FAKEPUBKEY1234567890abcdefghijklmnopqrstuv=" ;;
    *)      exit 0 ;;
esac
SHIM
    chmod +x "$bin/awg"
    export PATH="$bin:$PATH"
}

@test "awg_mktemp: with target dir creates the temp file inside that dir" {
    local dir="$TEST_DIR/etc/amnezia"
    local f
    f=$(awg_mktemp "$dir")
    [ -f "$f" ]
    [ "$(dirname "$f")" = "$dir" ]
}

@test "awg_mktemp: target dir is created if missing (mkdir -p)" {
    local dir="$TEST_DIR/deep/nested/target"
    [ ! -d "$dir" ]
    local f
    f=$(awg_mktemp "$dir")
    [ -d "$dir" ]
    [ -f "$f" ]
}

@test "awg_mktemp: no argument keeps legacy behaviour (respects TMPDIR)" {
    local td="$TEST_DIR/legacy_tmp"
    mkdir -p "$td"
    TMPDIR="$td" run awg_mktemp
    [ "$status" -eq 0 ]
    [ -f "$output" ]
    [ "$(dirname "$output")" = "$td" ]
}

@test "awg_mktemp: registers the temp file in _AWG_TEMP_FILES for cleanup" {
    # Use a redirect (not command substitution) so the array mutation happens in
    # the current shell rather than a subshell where it would be lost.
    local before=${#_AWG_TEMP_FILES[@]}
    awg_mktemp "$TEST_DIR" > "$TEST_DIR/.mk_out"
    local after=${#_AWG_TEMP_FILES[@]}
    [ "$after" -eq $((before + 1)) ]
    local f
    f=$(cat "$TEST_DIR/.mk_out")
    [ "${_AWG_TEMP_FILES[$((after - 1))]}" = "$f" ]
}

@test "_ensure_server_public_key: temp lands in AWG_DIR, not in /tmp (call-site)" {
    mock_awg
    create_server_config   # provides PrivateKey = TESTKEY

    # Break the default temp location: a bare mktemp would fail here, so success
    # proves the call-site passed a real target dir ($AWG_DIR) to awg_mktemp.
    TMPDIR="$TEST_DIR/nonexistent_tmpdir" run _ensure_server_public_key
    [ "$status" -eq 0 ]
    [ -f "$AWG_DIR/server_public.key" ]
    [ -s "$AWG_DIR/server_public.key" ]
}

@test "awg_mktemp: a temp created via \$(...) is still cleaned up (file registry)" {
    # The array mutation is lost in a command-substitution subshell, so the
    # registry file is what lets _awg_cleanup reclaim a temp created the way the
    # real call-sites create theirs (tmp=\$(awg_mktemp ...)).
    [ -n "${_AWG_TEMP_REGISTRY:-}" ]
    local f
    f=$(awg_mktemp "$AWG_DIR")          # subshell - array update does not persist
    [ -f "$f" ]
    grep -qxF "$f" "$_AWG_TEMP_REGISTRY"

    _awg_cleanup
    [ ! -f "$f" ]                       # removed via the registry
    [ ! -f "$_AWG_TEMP_REGISTRY" ]      # registry itself cleaned
}
