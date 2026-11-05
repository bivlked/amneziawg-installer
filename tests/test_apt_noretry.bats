#!/usr/bin/env bats
# CVE-2026-109518 (apt, 4 nov 2026): an on-path attacker between apt and the
# mirror can get an unverified package installed as root, but only when apt
# retries a package download (Acquire::Retries > 0; the default is 3 since
# Debian 12 and Ubuntu 22.04). Fixed apt exists, yet provider images keep the
# vulnerable one for weeks, and the installer downloads packages with exactly
# that apt: cleanup_system, the step 1 upgrade and, on a resumed run, steps 2-4.
#
# The installer therefore drops a temporary apt.conf.d file with
# Acquire::Retries "0" before the step loop of EVERY run (resume included) and
# removes it on exit. --uninstall removes a copy left by a killed run.
#
# The functional tests lift the real functions out of the shipped installers,
# so deleting the guard from an installer turns them red.

RU_INSTALL() { echo "$BATS_TEST_DIRNAME/../install_amneziawg.sh"; }
EN_INSTALL() { echo "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"; }

extract_func() {
    awk -v f="$2" '
        $0 ~ "^" f "\\(\\) \\{" { p = 1 }
        p { print }
        p && /^\}$/ { exit }
    ' "$1"
}

setup() {
    TMPD="$(mktemp -d)"
    STUBS="$TMPD/bin"
    mkdir -p "$STUBS" "$TMPD/apt.conf.d"
    WARNED="$TMPD/warned"
    DIED="$TMPD/died"
}

teardown() {
    chmod -R u+w "$TMPD" 2>/dev/null || true
    rm -rf "$TMPD"
}

# apt-config stub: answers `apt-config shell R Acquire::Retries` with $1.
stub_apt_config() {
    cat > "$STUBS/apt-config" <<EOF
#!/bin/bash
[ "\$1" = shell ] && [ "\$2" = R ] && [ "\$3" = Acquire::Retries ] || exit 2
printf '%s\n' "$1"
EOF
    chmod +x "$STUBS/apt-config"
}

# Runs enable (and optionally disable) from installer $1 in a subshell.
run_guard() {
    local inst="$1" action="$2"
    run bash -c '
        set -o pipefail
        PATH="'"$STUBS"':$PATH"
        log() { :; }
        log_warn() { printf "%s\n" "$*" >> "'"$WARNED"'"; }
        die() { printf "%s\n" "$*" >> "'"$DIED"'"; exit 1; }
        APT_NORETRY_CONF="'"$TMPD"'/apt.conf.d/99zz-amneziawg-installer-noretries"
        _apt_noretry_set=0
        eval "$(awk -v f=_apt_noretry_enable '\''$0 ~ "^" f "\\(\\) \\{" {p=1} p {print} p && /^\}$/ {exit}'\'' "'"$inst"'")"
        eval "$(awk -v f=_apt_noretry_disable '\''$0 ~ "^" f "\\(\\) \\{" {p=1} p {print} p && /^\}$/ {exit}'\'' "'"$inst"'")"
        '"$action"'
    '
}

CONF() { echo "$TMPD/apt.conf.d/99zz-amneziawg-installer-noretries"; }

@test "apt-noretry: both installers define enable and disable" {
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        [ -n "$(extract_func "$f" _apt_noretry_enable)" ]
        [ -n "$(extract_func "$f" _apt_noretry_disable)" ]
    done
}

@test "apt-noretry: enable writes Acquire::Retries 0 and stays quiet when apt agrees" {
    stub_apt_config "R='0'"
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        rm -f "$(CONF)" "$WARNED" "$DIED"
        run_guard "$f" '_apt_noretry_enable; echo "set=$_apt_noretry_set"'
        [ "$status" -eq 0 ]
        [ "$output" = "set=1" ]
        [ -f "$(CONF)" ]
        # The one setting line, exactly; comments may surround it.
        [ "$(grep -v '^//' "$(CONF)" | grep -c .)" = "1" ]
        grep -qx 'Acquire::Retries "0";' "$(CONF)"
        [ ! -e "$WARNED" ]
        [ ! -e "$DIED" ]
        # No temporary sibling is left behind.
        [ "$(ls "$TMPD/apt.conf.d" | wc -l)" = "1" ]
    done
}

@test "apt-noretry: enable warns when the effective value is not 0" {
    stub_apt_config "R='3'"
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        rm -f "$(CONF)" "$WARNED" "$DIED"
        run_guard "$f" '_apt_noretry_enable'
        [ "$status" -eq 0 ]
        [ -f "$(CONF)" ]
        [ -s "$WARNED" ]
        grep -q 'CVE-2026-109518' "$WARNED"
    done
}

@test "apt-noretry: enable dies when the file cannot be written" {
    [ "$(id -u)" -ne 0 ] || skip "root ignores directory permissions"
    stub_apt_config "R='0'"
    chmod a-w "$TMPD/apt.conf.d"
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        rm -f "$DIED"
        run_guard "$f" '_apt_noretry_enable; echo reached'
        [ "$status" -eq 1 ]
        [[ "$output" != *reached* ]]
        [ -s "$DIED" ]
        [ "$(ls -A "$TMPD/apt.conf.d" | wc -l)" = "0" ]
    done
}

@test "apt-noretry: disable removes the file this run created" {
    stub_apt_config "R='0'"
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        rm -f "$(CONF)"
        run_guard "$f" '_apt_noretry_enable; [ -f "$APT_NORETRY_CONF" ] && echo created; _apt_noretry_disable; echo "set=$_apt_noretry_set"'
        [ "$status" -eq 0 ]
        [ "$output" = "$(printf 'created\nset=0')" ]
        [ ! -e "$(CONF)" ]
    done
}

@test "apt-noretry: enable sweeps a temporary file left by a killed run" {
    stub_apt_config "R='0'"
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        rm -f "$TMPD/apt.conf.d/"*
        printf 'x\n' > "$(CONF).tmp.99999"
        run_guard "$f" '_apt_noretry_enable'
        [ "$status" -eq 0 ]
        [ -f "$(CONF)" ]
        [ ! -e "$(CONF).tmp.99999" ]
    done
}

@test "apt-noretry: enable warns when apt-config is missing" {
    # PATH without apt-config: only the stub dir and the bare tools bash needs.
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        rm -f "$(CONF)" "$WARNED"
        mkdir -p "$TMPD/nobin"
        for t in rm mv printf awk; do
            p=$(command -v "$t") && [ -x "$p" ] && ln -sf "$p" "$TMPD/nobin/$t"
        done
        run bash -c '
            PATH="'"$TMPD"'/nobin"
            log_warn() { printf "%s\n" "$*" >> "'"$WARNED"'"; }
            die() { echo died; exit 1; }
            APT_NORETRY_CONF="'"$TMPD"'/apt.conf.d/99zz-amneziawg-installer-noretries"
            _apt_noretry_set=0
            eval "$(awk -v f=_apt_noretry_enable '\''$0 ~ "^" f "\\(\\) \\{" {p=1} p {print} p && /^\}$/ {exit}'\'' "'"$f"'")"
            _apt_noretry_enable
        '
        [ "$status" -eq 0 ]
        [ -f "$(CONF)" ]
        grep -q 'apt-config' "$WARNED"
    done
}

@test "apt-noretry: the warning advice itself downloads without retries" {
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        extract_func "$f" _apt_noretry_enable \
            | grep -qF 'apt-get -o Acquire::Retries=0 update && apt-get -o Acquire::Retries=0 install --only-upgrade apt'
    done
}

@test "apt-noretry: disable without enable leaves the path alone" {
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        printf 'Acquire::Retries "0";\n' > "$(CONF)"
        run_guard "$f" '_apt_noretry_disable'
        [ "$status" -eq 0 ]
        [ -f "$(CONF)" ]
    done
}

@test "apt-noretry: the path is the fixed 99zz name, read after the others" {
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        grep -qx 'APT_NORETRY_CONF="/etc/apt/apt.conf.d/99zz-amneziawg-installer-noretries"' "$f"
    done
}

@test "apt-noretry: enabled after initialize_setup, before the step loop" {
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        init=$(grep -n -m1 '^initialize_setup$' "$f" | cut -d: -f1)
        en=$(grep -n -m1 '^_apt_noretry_enable$' "$f" | cut -d: -f1)
        loop=$(grep -n -m1 '^while (( current_step < 99 )); do$' "$f" | cut -d: -f1)
        [ -n "$init" ] && [ -n "$en" ] && [ -n "$loop" ]
        [ "$init" -lt "$en" ]
        [ "$en" -lt "$loop" ]
    done
}

@test "apt-noretry: the real exit cleanup removes the file" {
    stub_apt_config "R='0'"
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        rm -f "$(CONF)"
        run bash -c '
            PATH="'"$STUBS"':$PATH"
            TMPDIR="'"$TMPD"'"
            log() { :; }; log_warn() { :; }; die() { echo died; exit 1; }
            APT_NORETRY_CONF="'"$TMPD"'/apt.conf.d/99zz-amneziawg-installer-noretries"
            _apt_noretry_set=0; _install_cleaned=0; _install_temp_files=()
            for fn in _apt_noretry_enable _apt_noretry_disable _install_cleanup; do
                eval "$(awk -v f="$fn" '\''$0 ~ "^" f "\\(\\) \\{" {p=1} p {print} p && /^\}$/ {exit}'\'' "'"$f"'")"
            done
            _apt_noretry_enable
            [ -f "$APT_NORETRY_CONF" ] && echo created
            _install_cleanup
        '
        [ "$status" -eq 0 ]
        [ "$output" = "created" ]
        [ ! -e "$(CONF)" ]
    done
}

@test "apt-noretry: uninstall removes a copy left by a killed run" {
    for f in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        extract_func "$f" step_uninstall \
            | grep -qxF '    rm -f "$APT_NORETRY_CONF" "$APT_NORETRY_CONF".tmp.* 2>/dev/null || true'
    done
}
