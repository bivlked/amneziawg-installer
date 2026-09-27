#!/usr/bin/env bats
# The third-line environment check restore runs (decision Р6) is a COPY of the
# installer's, because the installer needs it at step 3 and the library only
# arrives at step 5. These cases pin the copies to the installer in SOURCE, per
# language (the RU and EN twins differ in their messages, so each library is
# compared with the installer of its own language), and check the restore
# blocker's own order and codes. The end-to-end restore cases live in
# test_awg31_backup_restore.bats.

bats_require_minimum_version 1.5.0

R="${BATS_TEST_DIRNAME}/.."

# _src <file> <function> : the function's source from its header line to the
# closing brace or parenthesis at column 0, CR stripped (Windows checkouts).
_src() {
    awk -v n="$2" '
        !on && ($0 == n "() {" || $0 == n "() (") { on = 1; close_ = ($0 ~ /\{$/) ? "}" : ")" }
        on { print }
        on && $0 == close_ { exit }
    ' "$1" | tr -d '\r'
}

@test "the copied environment functions match the installer in source, both languages" {
    local f pair inst lib a b
    for pair in "install_amneziawg.sh awg_common.sh" "install_amneziawg_en.sh awg_common_en.sh"; do
        read -r inst lib <<< "$pair"
        for f in _kernel_supports_awg3 _awg31_host_arch awg31_tools_support awg31_module_support _awg31_module_probe; do
            a=$(_src "$R/$inst" "$f")
            b=$(_src "$R/$lib" "$f")
            [ -n "$a" ] || { echo "missing in $inst: $f"; return 1; }
            [ -n "$b" ] || { echo "missing in $lib: $f"; return 1; }
            [ "$a" = "$b" ] || { echo "$f: $lib diverges from $inst"; diff <(echo "$a") <(echo "$b") | head -20; return 1; }
        done
    done
}

@test "the restore blocker is the same logic in both languages" {
    local a b
    a=$(_src "$R/awg_common.sh" awg31_restore_blocker)
    b=$(_src "$R/awg_common_en.sh" awg31_restore_blocker)
    [ -n "$a" ]
    [ "$a" = "$b" ]
}

# _blocker <arch> <kernel> [tools_ok 0|1] [module rc] : run the real blocker
# from the library with the host facts and the two capabilities stubbed.
_blocker() {
    local lib="$1" arch="$2" kver="$3" tools="${4:-0}" mod="${5:-0}"
    ARCH="$arch" KVER="$kver" TOOLS="$tools" MOD="$mod" timeout 30 bash -c '
        log() { :; }; log_warn() { :; }; log_error() { :; }; log_debug() { :; }
        source "$1" >/dev/null 2>&1 || true
        _awg31_host_arch() { printf "%s" "$ARCH"; }
        uname() { [[ "$1" == -r ]] && { echo "$KVER"; return 0; }; command uname "$@"; }
        awg31_tools_support() { return "$TOOLS"; }
        awg31_module_support() { return "$MOD"; }
        awg31_restore_blocker
    ' _ "$lib"
}

@test "restore blocker: codes and their order, both languages" {
    local lib
    for lib in "$R/awg_common.sh" "$R/awg_common_en.sh"; do
        [ "$(_blocker "$lib" amd64 6.8.0)" = pass ]
        [ "$(_blocker "$lib" x86_64 6.8.0)" = pass ]
        [ "$(_blocker "$lib" "" 6.8.0)" = arch_unknown ]
        [ "$(_blocker "$lib" arm64 6.8.0)" = arm ]
        [ "$(_blocker "$lib" aarch64 6.8.0)" = arm ]
        [ "$(_blocker "$lib" riscv64 6.8.0)" = arch_unsupported ]
        [ "$(_blocker "$lib" amd64 6.1.0-25-amd64)" = kernel ]
        # architecture and kernel come BEFORE the tools: ARM with old tools is arm
        [ "$(_blocker "$lib" arm64 6.8.0 1)" = arm ]
        [ "$(_blocker "$lib" amd64 6.1.0 1)" = kernel ]
        [ "$(_blocker "$lib" amd64 6.8.0 1)" = tools_old ]
        # tools BEFORE the module: the probe runs with those tools
        [ "$(_blocker "$lib" amd64 6.8.0 1 1)" = tools_old ]
        [ "$(_blocker "$lib" amd64 6.8.0 0 1)" = module_line2 ]
        [ "$(_blocker "$lib" amd64 6.8.0 0 2)" = module_probe_failed ]
    done
}

@test "restore blocker: every code has its own reason text, both languages" {
    local lib code txt seen
    for lib in "$R/awg_common.sh" "$R/awg_common_en.sh"; do
        seen=""
        for code in arch_unknown arm arch_unsupported kernel tools_old module_line2 module_probe_failed ""; do
            txt=$(timeout 30 bash -c 'log(){ :; }; log_warn(){ :; }; log_error(){ :; }; log_debug(){ :; }; source "$1" >/dev/null 2>&1; _awg31_restore_blocker_reason "$2"' _ "$lib" "$code")
            [ -n "$txt" ] || { echo "$lib: no text for $code"; return 1; }
            [[ "$txt" != *"'$code'"* ]] || { echo "$lib: $code falls to the unknown branch"; return 1; }
            [[ "$seen" != *"|$txt|"* ]] || { echo "$lib: $code repeats another text"; return 1; }
            seen+="|$txt|"
        done
    done
}
