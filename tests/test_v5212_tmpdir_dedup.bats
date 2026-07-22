#!/usr/bin/env bats
# v5.21.2:
#   - 5kag: manage_mktempdir_var registers the temp dir in the PARENT array, so
#     the INT/TERM/EXIT cleanup actually sees it. The old manage_mktempdir did
#     the append inside a command substitution ($()), i.e. a subshell, so the
#     parent array stayed empty and the dirs leaked on an interrupted
#     backup/rollback.
#   - dedup: _sanitize_port lives only in awg_common*.sh now (moved out of the
#     two manage scripts), which is why the guard can be shared by check/diagnose
#     and by generate/regenerate_client without a third copy drifting.

_extract() { awk '/^manage_mktempdir_var\(\) \{/,/^\}/' "$1"; }

# --- 5kag: registration survives in the parent shell ---

# Mirror real usage: the call sites live inside functions that declare their
# own `local td`. printf -v must write into that caller local (dynamic scope),
# and the append must land in the PARENT _manage_temp_dirs, not a subshell.
_assert_registers() {
    local script="$1"
    _manage_temp_dirs=()
    eval "$(_extract "$script")"
    _caller() {
        local td=""
        manage_mktempdir_var td || { echo "call failed"; return 1; }
        [ -n "$td" ] || { echo "caller local td not written"; return 1; }
        [ -d "$td" ] || { echo "dir not created: $td"; return 1; }
        [ "${#_manage_temp_dirs[@]}" -eq 1 ] || { echo "not registered in parent: ${#_manage_temp_dirs[@]}"; return 1; }
        [ "$td" = "${_manage_temp_dirs[0]}" ] || { echo "caller local != registered path"; return 1; }
        rmdir "$td"
    }
    _caller
}

@test "v5.21.2 (5kag): manage_mktempdir_var writes the caller local and registers in the parent (RU)" {
    run _assert_registers "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "v5.21.2 (5kag): manage_mktempdir_var writes the caller local and registers in the parent (EN)" {
    run _assert_registers "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# When mktemp fails, the helper must propagate the failure and register nothing,
# so the caller's `|| die`/`|| { ... }` fires instead of proceeding blind.
_assert_fails_clean() {
    local script="$1"
    _manage_temp_dirs=()
    eval "$(_extract "$script")"
    mktemp() { return 1; }   # simulate a failing mktemp
    local rc=0
    manage_mktempdir_var td || rc=$?
    [ "$rc" -ne 0 ] || { echo "did not propagate mktemp failure"; return 1; }
    [ "${#_manage_temp_dirs[@]}" -eq 0 ] || { echo "registered despite mktemp failure"; return 1; }
}

@test "v5.21.2 (5kag): manage_mktempdir_var fails cleanly when mktemp fails (RU)" {
    run _assert_fails_clean "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "v5.21.2 (5kag): manage_mktempdir_var fails cleanly when mktemp fails (EN)" {
    run _assert_fails_clean "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# End-to-end: the INT/TERM/EXIT handler (_manage_cleanup) actually removes a
# registered dir. This closes the loop on 5kag - the leak was that the handler
# never saw the dir, so registration alone is only half the proof.
_assert_cleanup_removes() {
    local script="$1"
    _manage_temp_dirs=()
    _manage_cleaned=0
    eval "$(_extract "$script")"
    eval "$(awk '/^_manage_cleanup\(\) \{/,/^\}/' "$script")"
    manage_mktempdir_var td
    [ -d "$td" ] || { echo "dir not created: $td"; return 1; }
    _manage_cleanup   # what the trap runs on INT/TERM/EXIT
    [ ! -d "$td" ] || { echo "cleanup left the registered dir: $td"; rmdir "$td" 2>/dev/null; return 1; }
}

@test "v5.21.2 (5kag): _manage_cleanup removes a registered temp dir (RU)" {
    run _assert_cleanup_removes "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "v5.21.2 (5kag): _manage_cleanup removes a registered temp dir (EN)" {
    run _assert_cleanup_removes "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "v5.21.2 (5kag): the old subshell-registering manage_mktempdir is gone (RU+EN)" {
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        run grep -nE '^manage_mktempdir\(\) \{' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -ne 0 ] || { echo "$f still defines the buggy manage_mktempdir"; return 1; }
        # A real call starts a code line (var=$(...)); the explanatory comment
        # begins with '#', so anchor to line start to skip it.
        run grep -nE '^[[:space:]]*[a-zA-Z_]+=\$\(manage_mktempdir\)' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -ne 0 ] || { echo "$f still calls manage_mktempdir via command substitution"; return 1; }
    done
}

# --- dedup: sanitizer lives only in the library ---

@test "v5.21.2 (dedup): _sanitize_port is defined only in awg_common*.sh" {
    for f in awg_common.sh awg_common_en.sh; do
        run grep -c '^_sanitize_port() {' "$BATS_TEST_DIRNAME/../$f"
        [ "$output" -eq 1 ] || { echo "$f: expected 1 definition, found $output"; return 1; }
    done
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        run grep -c '^_sanitize_port() {' "$BATS_TEST_DIRNAME/../$f"
        [ "$output" -eq 0 ] || { echo "$f still defines its own _sanitize_port ($output)"; return 1; }
    done
}
