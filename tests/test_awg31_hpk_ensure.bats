#!/usr/bin/env bats
# Third-line profile, part two: keeping the header protection key consistent.
#
# awg0.conf is the source of truth for the key on a live server; server_hpk.key is
# its backup copy. awg_hpk_ensure <install|manage> decides, before anything renders
# a profile, whether the pair is consistent, and says so loudly when it is not:
#   - a key in the config of an installation marked 2.0 is refused: rendering on
#     would issue profiles without the key, which silently do not connect;
#   - with the marker 3.1 a lost key file is restored from the config, never
#     replaced by a new key; a differing file is refused; a missing key is refused;
#   - a key is generated only in install mode, and only before the server config
#     exists (first install), never over an existing config.
# The marker is read from the init file afresh, not from a variable left in the
# environment by an earlier load.
#
# Every refusal is asserted by its reason in the language of the library under test,
# after checking that the function exists ("command not found" also exits non-zero).

KEY_A="QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQA="
KEY_B="RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRA="
KEY_GEN="SSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSA="

dir_of() { echo "$BATS_TEST_TMPDIR/awg-$(basename "$1" .sh)"; }
ru() { [[ "$1" != *_en.sh ]]; }

# lib_run <lib> <snippet> : fresh bash, library sourced, awg genkey prints KEY_GEN.
lib_run() {
    local lib="$1" snippet="$2" bin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$bin"
    printf '#!/usr/bin/env bash\n[[ "$1" == genkey ]] || exit 99\necho "%s"\n' "$KEY_GEN" > "$bin/awg"
    chmod +x "$bin/awg"
    PATH="$bin:$PATH" AWG_DIR="$(dir_of "$lib")" \
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
        rm -rf "$(dir_of "$lib")"
        mkdir -p "$(dir_of "$lib")"
        "$1" "$lib" || return 1
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}

defined() {
    run lib_run "$1" 'declare -F awg_hpk_ensure >/dev/null && declare -F awg_generate_hpk >/dev/null'
    [ "$status" -eq 0 ] || { echo "awg_hpk_ensure is not defined ($1)"; return 1; }
}

marker() { printf "export AWG_PORT=39743\nexport AWG_PROTOCOL='%s'\n" "$2" > "$(dir_of "$1")/awgsetup_cfg.init"; }

# conf <lib> [extra lines...] : a server config; extra lines go into [Interface].
conf() {
    local lib="$1"; shift
    {
        printf '[Interface]\nPrivateKey = TESTKEY\nListenPort = 39743\nJc = 6\nJmin = 55\nJmax = 380\n'
        printf 'S1 = 72\nS2 = 56\nS3 = 32\nS4 = 16\nH1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\n'
        local l
        for l in "$@"; do printf '%s\n' "$l"; done
        printf '\n[Peer]\n#_Name = my_phone\nPublicKey = PEERPUB\nAllowedIPs = 10.9.9.2/32\n'
    } > "$(dir_of "$lib")/awg0.conf"
}

keyfile() { printf '%s\n' "$2" > "$(dir_of "$1")/server_hpk.key"; chmod 600 "$(dir_of "$1")/server_hpk.key"; }

# expect <lib> <mode> <rc> <ru reason or ""> <en reason or "">
expect() {
    local lib="$1" mode="$2" rc="$3" want="$5"
    ru "$lib" && want="$4"
    run lib_run "$lib" "awg_hpk_ensure $mode"
    [ "$status" -eq "$rc" ] || { echo "status $status, expected $rc ($lib $mode): $output"; return 1; }
    if [[ -n "$want" ]]; then
        [[ "$output" == *"$want"* ]] || { echo "wrong reason ($lib), expected '$want': $output"; return 1; }
    fi
    local k
    for k in "$KEY_A" "$KEY_B" "$KEY_GEN"; do
        [[ "$output" != *"$k"* ]] || { echo "a key value was printed ($lib): $output"; return 1; }
    done
}

s_20_plain() {
    defined "$1" || return 1
    marker "$1" 2.0; conf "$1"
    expect "$1" manage 0 "" "" || return 1
    [ ! -e "$(dir_of "$1")/server_hpk.key" ] || { echo "a key file appeared on 2.0 ($1)"; return 1; }
    rm -f "$(dir_of "$1")/awgsetup_cfg.init"
    expect "$1" manage 0 "" ""
}
@test "ensure: a 2.0 installation without a key passes, with or without an init file, both twins" {
    both s_20_plain
}

s_20_with_key() {
    defined "$1" || return 1
    marker "$1" 2.0; conf "$1" "HeaderProtectionKey = $KEY_A"
    expect "$1" manage 1 "а установка помечена поколением 2.0" "but the installation is marked as generation 2.0" || return 1
    rm -f "$(dir_of "$1")/awgsetup_cfg.init"
    expect "$1" manage 1 "а установка помечена поколением 2.0" "but the installation is marked as generation 2.0" || return 1
    marker "$1" 2.0; conf "$1"; printf '\n[Peer]\nHeaderProtectionKey = %s\n' "$KEY_A" >> "$(dir_of "$1")/awg0.conf"
    expect "$1" manage 1 "а установка помечена поколением 2.0" "but the installation is marked as generation 2.0"
}
@test "ensure: a key in the config of a 2.0 installation is refused, in any section, both twins" {
    both s_20_with_key
}

s_stale_env_marker() {
    defined "$1" || return 1
    marker "$1" 2.0; conf "$1" "HeaderProtectionKey = $KEY_A"
    local want="but the installation is marked as generation 2.0"
    ru "$1" && want="а установка помечена поколением 2.0"
    run lib_run "$1" 'export AWG_PROTOCOL=3.1; awg_hpk_ensure manage'
    [ "$status" -eq 1 ] || { echo "stale AWG_PROTOCOL=3.1 in the environment won over the init file ($1): $output"; return 1; }
    [[ "$output" == *"$want"* ]] || { echo "wrong reason ($1): $output"; return 1; }
    # The case the reset exists for: an init without the marker (every install made
    # before it) loads nothing into AWG_PROTOCOL, so only the reset stops a stale 3.1
    # from surviving and turning "no marker = 2.0" into 3.1.
    printf "export AWG_PORT=39743\n" > "$(dir_of "$1")/awgsetup_cfg.init"
    run lib_run "$1" 'export AWG_PROTOCOL=3.1; awg_hpk_ensure manage'
    [ "$status" -eq 1 ] || { echo "stale AWG_PROTOCOL=3.1 won over an init without the marker ($1): $output"; return 1; }
    [[ "$output" == *"$want"* ]] || { echo "wrong reason for an init without the marker ($1): $output"; return 1; }
    [ ! -e "$(dir_of "$1")/server_hpk.key" ] || { echo "a key file was restored on an install without the marker ($1)"; return 1; }
}
@test "ensure: the marker comes from the init file, not from a stale environment variable, both twins" {
    both s_stale_env_marker
}

s_20_stale_file() {
    defined "$1" || return 1
    marker "$1" 2.0; conf "$1"; keyfile "$1" "$KEY_A"
    expect "$1" manage 0 "не используется" "is not used"
}
@test "ensure: a key file left on a 2.0 installation is reported and not used, both twins" {
    both s_20_stale_file
}

s_31_restore() {
    defined "$1" || return 1
    local d; d=$(dir_of "$1")
    marker "$1" 3.1; conf "$1" "HeaderProtectionKey = $KEY_A"
    expect "$1" manage 0 "восстановлен из" "restored from" || return 1
    [ -f "$d/server_hpk.key" ] || { echo "the key file was not restored ($1)"; return 1; }
    [ "$(stat -c %a "$d/server_hpk.key")" = "600" ] || { echo "restored file mode is not 600 ($1)"; return 1; }
    [ "$(cat "$d/server_hpk.key")" = "$KEY_A" ] || { echo "restored key differs from the config ($1)"; return 1; }
    expect "$1" manage 0 "" ""
}
@test "ensure: marker 3.1 with the key in the config and no file restores the file, never a new key, both twins" {
    both s_31_restore
}

s_31_restore_install() {
    defined "$1" || return 1
    local d; d=$(dir_of "$1")
    marker "$1" 3.1; conf "$1" "HeaderProtectionKey = $KEY_A"
    expect "$1" install 0 "восстановлен из" "restored from" || return 1
    [ "$(cat "$d/server_hpk.key")" = "$KEY_A" ] || { echo "install mode generated a new key instead of restoring ($1)"; return 1; }
}
@test "ensure: install mode over a config that holds a key restores it too, both twins" {
    both s_31_restore_install
}

s_31_mismatch() {
    defined "$1" || return 1
    marker "$1" 3.1; conf "$1" "HeaderProtectionKey = $KEY_A"; keyfile "$1" "$KEY_B"
    expect "$1" manage 1 "не совпадает с HeaderProtectionKey" "does not match HeaderProtectionKey" || return 1
    [ "$(cat "$(dir_of "$1")/server_hpk.key")" = "$KEY_B" ] || { echo "the differing file was overwritten ($1)"; return 1; }
}
@test "ensure: a key file that differs from the config is refused and left alone, both twins" {
    both s_31_mismatch
}

s_31_conf_key_bad() {
    defined "$1" || return 1
    local d; d=$(dir_of "$1")
    marker "$1" 3.1; conf "$1" "HeaderProtectionKey = ${KEY_A:0:43}"
    expect "$1" manage 1 "32 байта в base64" "32 bytes in base64" || return 1
    [ ! -e "$d/server_hpk.key" ] || { echo "a file was restored from a malformed key ($1)"; return 1; }
    conf "$1" "HeaderProtectionKey ="
    expect "$1" manage 1 "32 байта в base64" "32 bytes in base64" || return 1
    conf "$1" "HeaderProtectionKey = $KEY_A" "headerprotectionkey = $KEY_A"
    expect "$1" manage 1 "задан в [Interface] 2 раза" "is set 2 times in [Interface]" || return 1
    conf "$1"; printf '\n[Peer]\nHeaderProtectionKey = %s\n' "$KEY_A" >> "$d/awg0.conf"
    expect "$1" manage 1 "вне секции [Interface]" "outside the [Interface] section" || return 1
    [ ! -e "$d/server_hpk.key" ] || { echo "a file appeared from a broken config ($1)"; return 1; }
}
@test "ensure: a malformed, empty, repeated or misplaced key in the config is refused, both twins" {
    both s_31_conf_key_bad
}

s_31_no_key() {
    defined "$1" || return 1
    local d; d=$(dir_of "$1")
    marker "$1" 3.1; conf "$1"
    expect "$1" manage 1 "HeaderProtectionKey нет" "there is no HeaderProtectionKey" || return 1
    expect "$1" install 1 "HeaderProtectionKey нет" "there is no HeaderProtectionKey" || return 1
    [ ! -e "$d/server_hpk.key" ] || { echo "install mode generated a key over an existing config ($1)"; return 1; }
    keyfile "$1" "$KEY_A"
    expect "$1" manage 1 "убран из" "was removed from"
}
@test "ensure: marker 3.1 without a key in the config is refused, and no key is generated over it, both twins" {
    both s_31_no_key
}

s_31_bootstrap() {
    defined "$1" || return 1
    local d; d=$(dir_of "$1")
    marker "$1" 3.1
    expect "$1" install 0 "" "" || return 1
    [ "$(cat "$d/server_hpk.key")" = "$KEY_GEN" ] || { echo "first install did not generate a key ($1)"; return 1; }
    expect "$1" install 0 "" "" || return 1
    [ "$(cat "$d/server_hpk.key")" = "$KEY_GEN" ] || { echo "a second install call replaced the key ($1)"; return 1; }
    expect "$1" manage 1 "серверного конфига нет" "the server config does not exist"
}
@test "ensure: first install generates the key once; manage without a server config refuses, both twins" {
    both s_31_bootstrap
}

s_31_file_damaged() {
    defined "$1" || return 1
    local d; d=$(dir_of "$1")
    marker "$1" 3.1; conf "$1" "HeaderProtectionKey = $KEY_A"
    : > "$d/server_hpk.key"
    expect "$1" manage 1 "повреждён" "is damaged" || return 1
    printf '%s\r\n' "$KEY_A" > "$d/server_hpk.key"
    expect "$1" manage 1 "повреждён" "is damaged" || return 1
    printf '%s\n%s\n' "$KEY_A" "$KEY_A" > "$d/server_hpk.key"
    expect "$1" manage 1 "повреждён" "is damaged" || return 1
    printf '%s\ntail-without-newline' "$KEY_A" > "$d/server_hpk.key"
    expect "$1" manage 1 "повреждён" "is damaged" || return 1
    printf '%s' "$KEY_A" > "$d/server_hpk.key"
    expect "$1" manage 1 "повреждён" "is damaged" || return 1
    printf '\n%s' "$KEY_A" > "$d/server_hpk.key"
    expect "$1" manage 1 "повреждён" "is damaged" || return 1
    rm -f "$d/server_hpk.key"; printf '%s\n' "$KEY_A" > "$d/real.key"; ln -s "$d/real.key" "$d/server_hpk.key"
    expect "$1" manage 1 "не обычный файл" "is not a regular file" || return 1
    rm -f "$d/server_hpk.key" "$d/real.key"; mkdir "$d/server_hpk.key"
    expect "$1" manage 1 "не обычный файл" "is not a regular file" || return 1
    rmdir "$d/server_hpk.key"
}
@test "ensure: an empty, CRLF, two-line, tailed, symlinked or directory key file is refused by reason, both twins" {
    both s_31_file_damaged
}

s_31_file_unreadable() {
    defined "$1" || return 1
    local d; d=$(dir_of "$1")
    marker "$1" 3.1; conf "$1" "HeaderProtectionKey = $KEY_A"
    keyfile "$1" "$KEY_A"; chmod 000 "$d/server_hpk.key"
    expect "$1" manage 1 "не читается" "cannot be read" || { chmod 600 "$d/server_hpk.key"; return 1; }
    chmod 600 "$d/server_hpk.key"
}
@test "ensure: an unreadable key file is refused as unreadable, not as absent, both twins" {
    # root reads a mode 000 file, so the state is unreachable there; CI runs as a
    # regular user and exercises it.
    [[ "$(id -u)" -ne 0 ]] || skip "root can read a mode 000 file"
    both s_31_file_unreadable
}

s_20_fresh_install() {
    defined "$1" || return 1
    local d; d=$(dir_of "$1")
    marker "$1" 2.0
    expect "$1" install 0 "" "" || return 1
    [ ! -e "$d/server_hpk.key" ] || { echo "a fresh 2.0 install generated a key ($1)"; return 1; }
    rm -f "$d/awgsetup_cfg.init"
    expect "$1" install 0 "" "" || return 1
    [ ! -e "$d/server_hpk.key" ] || { echo "a fresh install without a marker generated a key ($1)"; return 1; }
}
@test "ensure: a fresh 2.0 install (no server config yet) passes in install mode and creates no key, both twins" {
    both s_20_fresh_install
}

s_empty_awg_dir() {
    defined "$1" || return 1
    local want="AWG_DIR is not set"
    ru "$1" && want="AWG_DIR не задан"
    run lib_run "$1" 'AWG_DIR=""; awg_hpk_ensure manage'
    [ "$status" -eq 1 ] || { echo "ensure with an empty AWG_DIR did not refuse ($1): $output"; return 1; }
    [[ "$output" == *"$want"* ]] || { echo "wrong reason ($1), expected '$want': $output"; return 1; }
    [ ! -e /server_hpk.key ] || { echo "a key path at the filesystem root exists"; return 1; }
    run lib_run "$1" 'AWG_DIR=""; awg_generate_hpk'
    [ "$status" -eq 1 ] || { echo "generation with an empty AWG_DIR did not refuse ($1): $output"; return 1; }
    [[ "$output" == *"$want"* ]] || { echo "wrong generation reason ($1), expected '$want': $output"; return 1; }
}
@test "ensure: an empty AWG_DIR is refused instead of pointing the key at the filesystem root, both twins" {
    both s_empty_awg_dir
}

s_marker_broken() {
    defined "$1" || return 1
    printf "export AWG_PROTOCOL='3.1'\nexport AWG_PROTOCOL='2.0'\n" > "$(dir_of "$1")/awgsetup_cfg.init"
    # No key anywhere: the server keeps working as 2.0 did before the marker existed,
    # and the broken marker is reported. A 2.0 user with a hand-mangled init must not
    # lose add and regen over it.
    conf "$1"
    expect "$1" manage 0 "Маркер поколения" "generation marker" || return 1
    # A key in the config makes the generation matter: refuse.
    conf "$1" "HeaderProtectionKey = $KEY_A"
    expect "$1" manage 1 "Маркер поколения" "generation marker" || return 1
    rm -f "$(dir_of "$1")/awg0.conf"
    conf "$1"; keyfile "$1" "$KEY_A"
    expect "$1" manage 1 "Маркер поколения" "generation marker"
}
@test "ensure: a broken generation marker warns without a key and refuses with one, both twins" {
    both s_marker_broken
}

s_generate_refuses_conf_key() {
    defined "$1" || return 1
    local d want="is already in"; d=$(dir_of "$1")
    ru "$1" && want="уже есть в"
    marker "$1" 3.1; conf "$1" "HeaderProtectionKey = $KEY_A"
    run lib_run "$1" 'awg_generate_hpk'
    [ "$status" -eq 1 ] || { echo "generation over a config that holds a key did not refuse ($1): $output"; return 1; }
    [[ "$output" == *"$want"* ]] || { echo "wrong reason ($1), expected '$want': $output"; return 1; }
    [ ! -e "$d/server_hpk.key" ] || { echo "a new key was written next to the config key ($1)"; return 1; }
}
@test "ensure: awg_generate_hpk itself refuses when the config already holds a key, both twins" {
    both s_generate_refuses_conf_key
}

s_generate_refuses_any_conf() {
    defined "$1" || return 1
    local d want="already exists without HeaderProtectionKey"; d=$(dir_of "$1")
    ru "$1" && want="уже существует без HeaderProtectionKey"
    marker "$1" 3.1; conf "$1"
    run lib_run "$1" 'awg_generate_hpk'
    [ "$status" -eq 1 ] || { echo "generation over an existing config without a key did not refuse ($1): $output"; return 1; }
    [[ "$output" == *"$want"* ]] || { echo "wrong reason ($1), expected '$want': $output"; return 1; }
    [ ! -e "$d/server_hpk.key" ] || { echo "a new key was written next to an existing config ($1)"; return 1; }
}
@test "ensure: awg_generate_hpk refuses any existing server config, both twins" {
    both s_generate_refuses_any_conf
}

s_xtrace() {
    defined "$1" || return 1
    marker "$1" 3.1; conf "$1" "HeaderProtectionKey = $KEY_A"
    run lib_run "$1" 'exec 2>&1; set -x; awg_hpk_ensure manage; rc=$?; case $- in *x*) echo XTRACE_STILL_ON ;; esac; set +x; exit $rc'
    [ "$status" -eq 0 ] || { echo "ensure under set -x failed ($1): $output"; return 1; }
    [[ "$output" == *XTRACE_STILL_ON* ]] || { echo "xtrace was not restored ($1)"; return 1; }
    [[ "$output" != *"$KEY_A"* ]] || { echo "key value in the xtrace output ($1)"; return 1; }
}
@test "ensure: restoring under set -x keeps the key out of the trace, both twins" {
    both s_xtrace
}
