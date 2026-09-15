#!/usr/bin/env bats
# Third-line profile, part two: the header protection key on the server.
#
# The key is a secret of the same class as the server PrivateKey: whoever holds it
# can tell our traffic from noise. It lives in $AWG_DIR/server_hpk.key, is written
# atomically with mode 600, never passes through argv, and never shows up in a
# `set -x` trace (the installer turns xtrace on for the whole run under --verbose).
#
# Harness: each case runs in a fresh bash that sources the library under test with
# `awg` as an EXECUTABLE stub in front of PATH, not a function: a function's own
# `echo <key>` would land in the xtrace output and fail the trace check for the
# stub's sake, while the real `awg genkey` is a separate process whose output is
# never traced. Every case runs both twins and counts that both ran.

KEY_OK="QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQA="

# lib_run <lib> <genkey mode> <snippet> : runs snippet with $AWG_DIR set up.
# genkey mode: ok (prints KEY_OK), fail (exit 1), bad (prints a malformed key).
lib_run() {
    local lib="$1" mode="$2" snippet="$3" bin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$bin"
    cat > "$bin/awg" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == genkey ]] || exit 99
case "$GENKEY_MODE" in
    ok)  echo "$KEY_OK" ;;
    bad) echo "not-a-key" ;;
    tail) printf '%s\ntail-without-newline' "$KEY_OK" ;;
    *)   exit 1 ;;
esac
STUB
    chmod +x "$bin/awg"
    PATH="$bin:$PATH" AWG_DIR="$BATS_TEST_TMPDIR/awg-$(basename "$lib" .sh)" KEY_OK="$KEY_OK" GENKEY_MODE="$mode" \
    timeout 60 bash -c '
        mkdir -p "$AWG_DIR"
        export CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init" SERVER_CONF_FILE="$AWG_DIR/awg0.conf"
        log() { echo "INFO: $*"; }; log_warn() { echo "WARN: $*"; }
        log_error() { echo "ERR: $*"; }; log_debug() { :; }
        source "$1" >/dev/null 2>&1 || true
        eval "$2"
    ' _ "$lib" "$snippet"
}

both() {
    local seen=0 lib
    for lib in "$BATS_TEST_DIRNAME/../awg_common.sh" "$BATS_TEST_DIRNAME/../awg_common_en.sh"; do
        rm -rf "$BATS_TEST_TMPDIR/awg-$(basename "$lib" .sh)"
        "$1" "$lib" || return 1
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}

dir_of() { echo "$BATS_TEST_TMPDIR/awg-$(basename "$1" .sh)"; }

# leftovers <dir> : files other than the key, ignoring the temp-file registry that
# awg_mktemp keeps next to its files (it holds paths only, and install/manage remove
# it on exit; a bare test shell has no such trap).
leftovers() { find "$1" -mindepth 1 ! -name server_hpk.key ! -name ".awg_temp_registry.*" | wc -l; }
ru() { [[ "$1" != *_en.sh ]]; }

# A refusal only counts if the function exists: "command not found" also exits
# non-zero and writes no file, and would pass every refusal case below.
defined() {
    run lib_run "$1" ok 'declare -F awg_generate_hpk >/dev/null && declare -F awg_hpk_path >/dev/null'
    [ "$status" -eq 0 ] || { echo "awg_generate_hpk or awg_hpk_path is not defined ($1)"; return 1; }
}

g_path() {
    run lib_run "$1" ok 'awg_hpk_path'
    [ "$status" -eq 0 ] || { echo "awg_hpk_path failed ($1): $output"; return 1; }
    [ "$output" = "$(dir_of "$1")/server_hpk.key" ] || { echo "wrong path ($1): $output"; return 1; }
}
@test "hpk: the key path is one place, under AWG_DIR, both twins" {
    both g_path
}

g_generate() {
    local d; d=$(dir_of "$1")
    run lib_run "$1" ok 'awg_generate_hpk'
    [ "$status" -eq 0 ] || { echo "generation failed ($1): $output"; return 1; }
    [ -f "$d/server_hpk.key" ] || { echo "no key file ($1)"; return 1; }
    [ "$(stat -c %a "$d/server_hpk.key")" = "600" ] || { echo "mode is not 600 ($1): $(stat -c %a "$d/server_hpk.key")"; return 1; }
    [ "$(head -n 1 "$d/server_hpk.key")" = "$KEY_OK" ] || { echo "key file content wrong ($1)"; return 1; }
    [ "$(leftovers "$d")" -eq 0 ] || { echo "leftovers next to the key ($1): $(ls -la "$d")"; return 1; }
    [[ "$output" != *"$KEY_OK"* ]] || { echo "key value printed ($1): $output"; return 1; }
}
@test "hpk: generation writes one mode 600 file with the key and nothing else, both twins" {
    both g_generate
}

g_idempotent() {
    local d; d=$(dir_of "$1")
    mkdir -p "$d"
    printf '%s\n' "RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRA=" > "$d/server_hpk.key"
    chmod 600 "$d/server_hpk.key"
    run lib_run "$1" ok 'awg_generate_hpk'
    [ "$status" -eq 0 ] || { echo "second call failed ($1): $output"; return 1; }
    [ "$(head -n 1 "$d/server_hpk.key")" = "RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRA=" ] || { echo "existing key was overwritten ($1)"; return 1; }
}
@test "hpk: an existing key is never overwritten, both twins" {
    both g_idempotent
}

g_genkey_fails() {
    local d want="could not generate the header protection key"; d=$(dir_of "$1")
    ru "$1" && want="не удалось сгенерировать ключ защиты заголовков"
    defined "$1" || return 1
    run lib_run "$1" fail 'awg_generate_hpk'
    [ "$status" -ne 0 ] || { echo "a failed genkey reported success ($1): $output"; return 1; }
    [[ "$output" == *"$want"* ]] || { echo "wrong reason ($1), expected '$want': $output"; return 1; }
    [ ! -e "$d/server_hpk.key" ] || { echo "a key file appeared after a failed genkey ($1)"; return 1; }
    [ "$(leftovers "$d")" -eq 0 ] || { echo "temporary leftovers ($1): $(ls -la "$d")"; return 1; }
}
@test "hpk: a failed genkey leaves no key file and no temporary file, both twins" {
    both g_genkey_fails
}

g_genkey_bad() {
    local d want="awg genkey returned a value that is not a key"; d=$(dir_of "$1")
    ru "$1" && want="awg genkey вернул значение не в форме ключа"
    defined "$1" || return 1
    run lib_run "$1" bad 'awg_generate_hpk'
    [ "$status" -ne 0 ] || { echo "a malformed key was accepted ($1): $output"; return 1; }
    [[ "$output" == *"$want"* ]] || { echo "wrong reason ($1), expected '$want': $output"; return 1; }
    [ ! -e "$d/server_hpk.key" ] || { echo "a malformed key was written ($1)"; return 1; }
    [ "$(leftovers "$d")" -eq 0 ] || { echo "temporary leftovers ($1): $(ls -la "$d")"; return 1; }
}
@test "hpk: a malformed genkey output is refused and not written, both twins" {
    both g_genkey_bad
}

g_genkey_tail() {
    local d want="awg genkey returned a value that is not a key"; d=$(dir_of "$1")
    ru "$1" && want="awg genkey вернул значение не в форме ключа"
    defined "$1" || return 1
    run lib_run "$1" tail 'awg_generate_hpk'
    [ "$status" -ne 0 ] || { echo "a key followed by an unterminated tail was accepted ($1): $output"; return 1; }
    [[ "$output" == *"$want"* ]] || { echo "wrong reason ($1), expected '$want': $output"; return 1; }
    [ ! -e "$d/server_hpk.key" ] || { echo "a key file with a tail was written ($1)"; return 1; }
}
@test "hpk: genkey output with an unterminated tail after the key is refused, both twins" {
    both g_genkey_tail
}

g_xtrace() {
    local d; d=$(dir_of "$1")
    run lib_run "$1" ok 'exec 2>&1; set -x; awg_generate_hpk; rc=$?; case $- in *x*) echo XTRACE_STILL_ON ;; esac; set +x; exit $rc'
    [ "$status" -eq 0 ] || { echo "generation under set -x failed ($1): $output"; return 1; }
    [[ "$output" == *XTRACE_STILL_ON* ]] || { echo "xtrace was not restored after the call ($1): $output"; return 1; }
    [ -f "$d/server_hpk.key" ] || { echo "no key file under set -x ($1)"; return 1; }
    [[ "$output" != *"$KEY_OK"* ]] || { echo "key value in the xtrace output ($1)"; return 1; }
}
# Measured with the xtrace guard disabled: this case fails, because the form check
# reads the first line of the generated file into a variable, and the trace of that
# comparison carries the key. (Before the check read the line, the value never sat
# in a variable here and the case could not catch a missing guard.)
@test "hpk: generation under set -x prints no key value and restores xtrace, both twins" {
    both g_xtrace
}

g_validate_xtrace() {
    local d; d=$(dir_of "$1")
    mkdir -p "$d"
    {
        printf '[Interface]\nPrivateKey = TESTKEY\nListenPort = 39743\nJc = 6\nJmin = 55\nJmax = 380\n'
        printf 'S1 = 72\nS2 = 56\nS3 = 32\nS4 = 16\nH1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\n'
        printf 'HeaderProtectionKey = %s\n' "$KEY_OK"
    } > "$d/awg0.conf"
    run lib_run "$1" ok 'exec 2>&1; set -x; validate_awg_config; rc=$?; case $- in *x*) echo XTRACE_STILL_ON ;; esac; set +x; exit $rc'
    [ "$status" -eq 0 ] || { echo "validation of a correct keyed config failed under set -x ($1): $output"; return 1; }
    [[ "$output" == *XTRACE_STILL_ON* ]] || { echo "xtrace was not restored after validation ($1)"; return 1; }
    [[ "$output" != *"$KEY_OK"* ]] || { echo "validate_awg_config printed the key into the trace ($1)"; return 1; }
}
@test "hpk: validate_awg_config under set -x keeps the key out of the trace, both twins" {
    both g_validate_xtrace
}

g_loader_xtrace() {
    local d; d=$(dir_of "$1")
    mkdir -p "$d"
    {
        printf '[Interface]\nPrivateKey = PRIVSECRETAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\nListenPort = 39743\nJc = 6\nJmin = 55\nJmax = 380\n'
        printf 'S1 = 72\nS2 = 56\nS3 = 32\nS4 = 16\nH1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\n'
        printf 'HeaderProtectionKey = %s\n' "$KEY_OK"
    } > "$d/awg0.conf"
    run lib_run "$1" ok 'exec 2>&1; set -x; load_awg_params_from_server_conf "$SERVER_CONF_FILE"; rc=$?; case $- in *x*) echo XTRACE_STILL_ON ;; esac; set +x; echo "JC=$AWG_Jc"; exit $rc'
    [ "$status" -eq 0 ] || { echo "the loader failed under set -x ($1): $output"; return 1; }
    [[ "$output" == *XTRACE_STILL_ON* ]] || { echo "xtrace was not restored after the loader ($1)"; return 1; }
    [[ "$output" == *"JC=6"* ]] || { echo "the loader no longer exports its values ($1): $output"; return 1; }
    [[ "$output" != *"$KEY_OK"* ]] || { echo "the loader printed the header protection key into the trace ($1)"; return 1; }
    [[ "$output" != *PRIVSECRET* ]] || { echo "the loader printed the private key into the trace ($1)"; return 1; }
}
@test "hpk: the live config loader under set -x keeps both keys out of the trace, both twins" {
    both g_loader_xtrace
}

g_dir_at_key_path() {
    local d want="is not a regular file"; d=$(dir_of "$1")
    ru "$1" && want="не обычный файл"
    defined "$1" || return 1
    mkdir -p "$d/server_hpk.key"
    run lib_run "$1" ok 'awg_generate_hpk'
    [ "$status" -eq 1 ] || { echo "generation reported success with a directory at the key path ($1): $output"; return 1; }
    [[ "$output" == *"$want"* ]] || { echo "wrong reason ($1), expected '$want': $output"; return 1; }
    [ "$(find "$d/server_hpk.key" -mindepth 1 | wc -l)" -eq 0 ] || { echo "a key was written inside the directory ($1)"; return 1; }
}
@test "hpk: a directory at the key path is refused, not reported as an existing key, both twins" {
    both g_dir_at_key_path
}
