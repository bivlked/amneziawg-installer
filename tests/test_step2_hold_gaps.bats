#!/usr/bin/env bats
# Step 2 holds amneziawg-dkms so that amneziawg-tools cannot pull the PPA
# module next to the one this path builds or unpacks. Gaps around that hold,
# found on review of the #285 fix and closed together:
#   1. a failed purge of an earlier amneziawg-dkms was only a warning, and the
#      hold then "protected" a package that was still installed;
#   2. APT::Ignore-Hold makes apt ignore every hold, so the protection is void
#      (and a setting that cannot be read must not pass as "off"); the same
#      setting scoped to one binary (Binary::apt::APT::Ignore-Hold, and the
#      apt-get twin) does it only for that binary, and apt-config does not
#      apply such a scope to the plain key, so both are asked by name;
#   3. the ARM postcondition looked for "ok installed" and missed a package
#      left unpacked or half-configured.
# The step-2 body is one long function, so the order of the guards is pinned
# by source lines; the new helper is run for real.

bats_require_minimum_version 1.5.0

INSTALLERS=(install_amneziawg.sh install_amneziawg_en.sh)

setup() {
    BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$BIN"
}

# The one question the helper asks, all three keys in one call.
HOLD_ASK_KEYS="a APT::Ignore-Hold/b b Binary::apt::APT::Ignore-Hold/b c Binary::apt-get::APT::Ignore-Hold/b"
HOLD_ASK="shell $HOLD_ASK_KEYS"

# stub_apt_config <exit code> <output, \n for new lines> [stderr notice] :
# answers only $HOLD_ASK
stub_apt_config() {
    printf '%b' "$2" > "$BIN/apt-config.out"
    {
        echo '#!/usr/bin/env bash'
        printf '[ "$*" = "%s" ] || { echo "unexpected: $*" >&2; exit 99; }\n' "$HOLD_ASK"
        [ -n "${3:-}" ] && printf 'echo "%s" >&2\n' "$3"
        printf 'cat "%s"\n' "$BIN/apt-config.out"
        echo "exit $1"
    } > "$BIN/apt-config"
    chmod +x "$BIN/apt-config"
}

honoured() {
    local body
    body=$(awk '/^_awg_apt_hold_honoured\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../$1")
    [[ -n "$body" ]] || { echo "NO_HELPER in $1"; return 3; }
    PATH="$BIN:$PATH" timeout 30 bash -c 'set -o pipefail; log_error() { echo "ERR: $*"; }; eval "$1"; _awg_apt_hold_honoured' _ "$body"
}

@test "Ignore-Hold: holds count as honoured only when the setting is read and off, both installers" {
    local f
    for f in "${INSTALLERS[@]}"; do
        stub_apt_config 0 "a='false'"; run honoured "$f"; [ "$status" -eq 0 ] || { echo "$f false: $status $output"; return 1; }
        stub_apt_config 0 "";          run honoured "$f"; [ "$status" -eq 0 ] || { echo "$f unset: $status $output"; return 1; }
        stub_apt_config 0 "a='false'\nb='false'\nc='false'\n"; run honoured "$f"; [ "$status" -eq 0 ] || { echo "$f all false: $status $output"; return 1; }
    done
}

@test "Ignore-Hold: a notice on stderr does not spoil an answer that is off or unset, both installers" {
    local f n="N: Ignoring file '99custom.txt' in directory '/etc/apt/apt.conf.d/' as it has an invalid filename extension"
    for f in "${INSTALLERS[@]}"; do
        stub_apt_config 0 "a='false'" "$n"; run honoured "$f"; [ "$status" -eq 0 ] || { echo "$f false: $status $output"; return 1; }
        stub_apt_config 0 "" "$n";          run honoured "$f"; [ "$status" -eq 0 ] || { echo "$f unset: $status $output"; return 1; }
        stub_apt_config 0 "a='true'" "$n";  run honoured "$f"; [ "$status" -eq 1 ] || { echo "$f true: $status $output"; return 1; }
    done
}

@test "Ignore-Hold: an enabled setting is a refusal with a reason, both installers" {
    stub_apt_config 0 "a='true'"
    local f
    for f in "${INSTALLERS[@]}"; do
        run honoured "$f"
        [ "$status" -eq 1 ] && [[ "$output" == ERR:*Ignore-Hold* ]] || { echo "$f: rc $status $output"; return 1; }
    done
}

@test "Ignore-Hold: an answer that is neither empty nor true or false is a refusal, both installers" {
    stub_apt_config 0 "a='maybe'"
    local f
    for f in "${INSTALLERS[@]}"; do
        run honoured "$f"
        [ "$status" -eq 1 ] && [[ "$output" == ERR:*Ignore-Hold* ]] || { echo "$f: rc $status $output"; return 1; }
    done
}

@test "Ignore-Hold: an apt-config that fails or is missing is a refusal, not 'off'" {
    local f
    for f in "${INSTALLERS[@]}"; do
        stub_apt_config 1 "a='false'"; run honoured "$f"
        [ "$status" -eq 1 ] && [[ "$output" == ERR:*apt-config* ]] || { echo "$f failed: $status $output"; return 1; }
        rm -f "$BIN/apt-config"
        # no apt-config anywhere on PATH: only the stub directory and bash itself
        run env PATH="$BIN" "$BASH" -c "$(declare -f honoured); INSTALLERS=(); BATS_TEST_DIRNAME='$BATS_TEST_DIRNAME'; BIN='$BIN'; PATH='$BIN'; body=\$(/usr/bin/awk '/^_awg_apt_hold_honoured\\(\\) \\{/,/^\\}/' '$BATS_TEST_DIRNAME/../$f'); log_error() { echo \"ERR: \$*\"; }; eval \"\$body\"; _awg_apt_hold_honoured"
        [ "$status" -eq 1 ] && [[ "$output" == *ERR:*apt-config* ]] || { echo "$f missing: $status $output"; return 1; }
    done
}

@test "Ignore-Hold: the setting scoped to apt or apt-get is a refusal that names it, both installers" {
    local f
    for f in "${INSTALLERS[@]}"; do
        stub_apt_config 0 "b='true'\n"; run honoured "$f"
        [ "$status" -eq 1 ] && [[ "$output" == ERR:*Binary::apt::APT::Ignore-Hold* ]] || { echo "$f apt: $status $output"; return 1; }
        stub_apt_config 0 "c='true'\n"; run honoured "$f"
        [ "$status" -eq 1 ] && [[ "$output" == ERR:*Binary::apt-get::APT::Ignore-Hold* ]] || { echo "$f apt-get: $status $output"; return 1; }
        # off for everyone, on for apt only: still a refusal
        stub_apt_config 0 "a='false'\nb='true'\nc='false'\n"; run honoured "$f"
        [ "$status" -eq 1 ] && [[ "$output" == ERR:*Binary::apt::APT::Ignore-Hold* ]] || { echo "$f mixed: $status $output"; return 1; }
        # a strange line after good ones is not skipped
        stub_apt_config 0 "a='false'\nc='yes'\n"; run honoured "$f"
        [ "$status" -eq 1 ] && [[ "$output" == ERR:*Ignore-Hold* ]] || { echo "$f strange: $status $output"; return 1; }
    done
}

@test "Ignore-Hold: the real apt-config reports the apt-scoped setting to the helper, both installers" {
    command -v apt-config >/dev/null 2>&1 || skip "no apt-config on this machine"
    rm -f "$BIN/apt-config"
    local f conf="$BATS_TEST_TMPDIR/apt.conf"
    # The host's own apt.conf.d is still read; it must not enable the setting.
    if [[ "$(APT_CONFIG=/dev/null apt-config shell $HOLD_ASK_KEYS 2>/dev/null)" == *"'true'"* ]]; then
        skip "Ignore-Hold is enabled on this host"
    fi
    for f in "${INSTALLERS[@]}"; do
        printf '%s\n' 'Binary::apt::APT::Ignore-Hold "true";' > "$conf"
        APT_CONFIG="$conf" run honoured "$f"
        [ "$status" -eq 1 ] && [[ "$output" == ERR:*Binary::apt::APT::Ignore-Hold* ]] || { echo "$f apt: $status $output"; return 1; }
        printf '%s\n' 'Binary::apt-get::APT::Ignore-Hold "1";' > "$conf"
        APT_CONFIG="$conf" run honoured "$f"
        [ "$status" -eq 1 ] && [[ "$output" == ERR:*Binary::apt-get::APT::Ignore-Hold* ]] || { echo "$f apt-get: $status $output"; return 1; }
        printf '%s\n' 'Binary::apt::APT::Ignore-Hold "false";' > "$conf"
        APT_CONFIG="$conf" run honoured "$f"
        [ "$status" -eq 0 ] || { echo "$f off: $status $output"; return 1; }
    done
}

@test "Ignore-Hold: the helper body is the same in both installers apart from the messages" {
    local ru en
    ru=$(awk '/^_awg_apt_hold_honoured\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh" | grep -vE 'log_error|^[[:space:]]*#')
    en=$(awk '/^_awg_apt_hold_honoured\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh" | grep -vE 'log_error|^[[:space:]]*#')
    [ -n "$ru" ]
    [ "$ru" = "$en" ]
}

@test "Ignore-Hold: each amneziawg-dkms hold site refuses first when apt ignores holds" {
    local f src holds h g
    for f in "${INSTALLERS[@]}"; do
        src="$BATS_TEST_DIRNAME/../$f"
        holds=$(grep -nE '^[[:space:]]*_hold_out=\$\(apt-mark hold amneziawg-dkms amneziawg 2>&1\) \|\| true$' "$src" | cut -d: -f1)
        [ "$(wc -l <<< "$holds")" -eq 2 ] || { echo "$f: holds: $holds"; return 1; }
        for h in $holds; do
            g=$(awk -v s="$h" 'NR<s && NR>=s-6 && /^[[:space:]]*if ! _awg_apt_hold_honoured; then$/ {print NR}' "$src" | tail -n1)
            [ -n "$g" ] || { echo "$f: no Ignore-Hold guard before the hold at $h"; return 1; }
            sed -n "$((g + 1)),$((g + 2))p" "$src" | grep -qE '^[[:space:]]*die ' || { echo "$f: guard at $g is not followed by die"; return 1; }
        done
    done
}

# purge_block <installer> : the re-entry block of the pinned path, from the
# state query to the end of the cleanup, run for real with stubs. Its trace
# goes to $T: apt-get, dpkg, rm and dkms calls, log lines and DIE.
# STATE file: what dpkg-query reports; "FAIL" makes dpkg-query fail outright.
# APT_OK / DPKG_OK files: that tool purges (sets the state to not-installed).
purge_block() {
    local src="$BATS_TEST_DIRNAME/../$1" helper block
    helper=$(awk '/^_awg_pkg_state\(\) \{/,/^\}/' "$src")
    block=$(awk '/^[[:space:]]*local _dkms_st="" _purge_out=""$/ {on=1}
                 on {print}
                 on && /rm -rf \/var\/lib\/dkms\/amneziawg\* \/usr\/src\/amneziawg-\*/ {getline; print; exit}' "$src")
    [[ -n "$helper" && -n "$block" ]] || { echo "NO_BLOCK in $1"; return 3; }
    cat > "$BIN/dpkg-query" << 'STUB'
#!/usr/bin/env bash
st=$(cat "$STATE")
if [ "$st" = FAIL ]; then echo "dpkg-query: database is broken" >&2; exit 2; fi
if [ "$st" = not-installed ]; then echo "dpkg-query: no packages found matching amneziawg-dkms" >&2; exit 1; fi
printf '%s' "$st"
STUB
    cat > "$BIN/apt-get" << 'STUB'
#!/usr/bin/env bash
echo "apt-get $*" >> "$T"
[ -e "$APT_BREAKS_DPKG" ] && { echo FAIL > "$STATE"; exit 0; }
[ -e "$APT_OK" ] && { echo "unknown ok not-installed" > "$STATE"; exit 0; }
echo "E: Held packages were changed and -y was used without --allow-change-held-packages." >&2; exit 100
STUB
    cat > "$BIN/dpkg" << 'STUB'
#!/usr/bin/env bash
echo "dpkg $*" >> "$T"
[ -e "$DPKG_OK" ] && { echo "unknown ok not-installed" > "$STATE"; exit 0; }
echo "dpkg: error processing package amneziawg-dkms (--purge): locked" >&2; exit 1
STUB
    chmod +x "$BIN/dpkg-query" "$BIN/apt-get" "$BIN/dpkg"
    PATH="$BIN:$PATH" timeout 30 bash -c '
        set -euo pipefail
        log() { echo "LOG: $*" >> "$T"; }
        log_error() { echo "ERR: $*" >> "$T"; }
        die() { echo "DIE: $*" >> "$T"; exit 1; }
        rm() { echo "rm $*" >> "$T"; }
        dkms() { echo "dkms $*" >> "$T"; }
        f() { eval "$2"; }
        eval "$1"
        f _ "$3"
    ' _ "$helper" _ "$block"
}

purge_env() {
    export T="$BATS_TEST_TMPDIR/trace" STATE="$BATS_TEST_TMPDIR/state"
    export APT_OK="$BATS_TEST_TMPDIR/apt_ok" DPKG_OK="$BATS_TEST_TMPDIR/dpkg_ok" APT_BREAKS_DPKG="$BATS_TEST_TMPDIR/apt_breaks"
    : > "$T"; rm -f "$APT_OK" "$DPKG_OK" "$APT_BREAKS_DPKG"
    printf '%s' "$1" > "$STATE"
}

@test "purge: a held amneziawg-dkms is purged too (the hold selection does not hide it), both installers" {
    local f
    for f in "${INSTALLERS[@]}"; do
        purge_env "hold ok installed"; : > "$DPKG_OK"
        run purge_block "$f"
        [ "$status" -eq 0 ] || { echo "$f: rc $status"; cat "$T"; return 1; }
        grep -q '^dpkg --purge --force-all amneziawg-dkms amneziawg$' "$T" || { echo "$f: not purged"; cat "$T"; return 1; }
        grep -q '^rm -rf /var/lib/dkms/amneziawg' "$T" || { echo "$f: no cleanup"; cat "$T"; return 1; }
        run grep -c '^DIE:' "$T"; [ "$output" = "0" ] || { echo "$f: died"; cat "$T"; return 1; }
    done
}

@test "purge: an amneziawg-dkms that survives the purge stops the pinned path with what apt and dpkg said, both installers" {
    local f
    for f in "${INSTALLERS[@]}"; do
        purge_env "hold ok half-configured"
        run purge_block "$f"
        [ "$status" -ne 0 ] || { echo "$f: rc 0"; cat "$T"; return 1; }
        grep -q '^DIE: .*half-configured.*dpkg --purge --force-all amneziawg-dkms amneziawg' "$T" || { echo "$f: no die"; cat "$T"; return 1; }
        grep -q '^ERR: .*Held packages were changed.*locked' "$T" || { echo "$f: answers not shown"; cat "$T"; return 1; }
        run grep -c '^rm -rf' "$T"; [ "$output" = "0" ] || { echo "$f: cleaned up before dying"; return 1; }
    done
}

@test "purge: a package left with config files only does not stop the pinned path, both installers" {
    local f
    for f in "${INSTALLERS[@]}"; do
        purge_env "deinstall ok config-files"
        run purge_block "$f"
        [ "$status" -eq 0 ] || { echo "$f: rc $status"; cat "$T"; return 1; }
        grep -qxF -- 'apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold purge -y amneziawg-dkms amneziawg' "$T" || { echo "$f: config files not purged"; cat "$T"; return 1; }
    done
}

@test "purge: no amneziawg-dkms means no purge at all, both installers" {
    local f
    for f in "${INSTALLERS[@]}"; do
        purge_env "not-installed"
        run purge_block "$f"
        [ "$status" -eq 0 ] || { echo "$f: rc $status"; cat "$T"; return 1; }
        run grep -cE '^(apt-get|dpkg|DIE)' "$T"; [ "$output" = "0" ] || { echo "$f: acted"; cat "$T"; return 1; }
    done
}

@test "purge: a dpkg that cannot be asked stops the pinned path instead of reading as 'not installed', both installers" {
    local f
    for f in "${INSTALLERS[@]}"; do
        purge_env "FAIL"
        run purge_block "$f"
        [ "$status" -ne 0 ] || { echo "$f: rc 0"; cat "$T"; return 1; }
        grep -q '^DIE: .*dpkg -l amneziawg-dkms' "$T" || { echo "$f: no die"; cat "$T"; return 1; }
        run grep -cE '^(apt-get|dpkg) ' "$T"; [ "$output" = "0" ] || { echo "$f: purged blind"; return 1; }
    done
}

@test "purge: a dpkg that cannot be asked after the purge stops with that reason, both installers" {
    local f
    for f in "${INSTALLERS[@]}"; do
        purge_env "install ok installed"; : > "$APT_BREAKS_DPKG"
        run purge_block "$f"
        [ "$status" -ne 0 ] || { echo "$f: rc 0"; cat "$T"; return 1; }
        grep -qE '^DIE: .*(после удаления|after the removal)' "$T" || { echo "$f: wrong reason"; cat "$T"; return 1; }
        run grep -c '^rm -rf' "$T"; [ "$output" = "0" ] || { echo "$f: cleaned up"; return 1; }
    done
}

@test "purge: the old dpkg -l gate is gone, both installers" {
    local f
    for f in "${INSTALLERS[@]}"; do
        run grep -c "dpkg -l amneziawg-dkms 2>/dev/null | grep -qE" "$BATS_TEST_DIRNAME/../$f"
        [ "$output" = "0" ] || { echo "$f: old gate still there"; return 1; }
    done
}

@test "ARM: a refused Ignore-Hold check after the prebuilt install puts the hold back before dying, both installers" {
    local f src g
    for f in "${INSTALLERS[@]}"; do
        src="$BATS_TEST_DIRNAME/../$f"
        # the guard in the prebuilt branch: the only one indented by 12 spaces
        g=$(grep -nxF '            if ! _awg_apt_hold_honoured; then' "$src" | cut -d: -f1)
        [ "$(wc -l <<< "$g")" -eq 1 ] && [ -n "$g" ] || { echo "$f: guard lines: $g"; return 1; }
        sed -n "$((g + 1))p" "$src" | grep -qxF '                _awg_rehold_for_prebuilt' || { echo "$f: no rehold"; return 1; }
        sed -n "$((g + 2))p" "$src" | grep -qE '^[[:space:]]*die .*(уже установлен|already installed)' || { echo "$f: die does not name the installed package"; return 1; }
    done
}

@test "ARM postcondition: amneziawg-dkms in any present state is reported, not only 'ok installed'" {
    local f src w c
    for f in "${INSTALLERS[@]}"; do
        src="$BATS_TEST_DIRNAME/../$f"
        w=$(grep -nE 'log_warn "(ВНИМАНИЕ: рядом с предсобранным модулем|WARNING: the amneziawg-dkms package is installed next to the prebuilt module)' "$src" | cut -d: -f1)
        [ -n "$w" ] || { echo "$f: warning not found"; return 1; }
        c=$(sed -n "$((w - 1))p" "$src")
        [[ "$c" =~ ^[[:space:]]*if\ _pkg_present\ amneziawg-dkms\;\ then$ ]] || { echo "$f: line before the warning: $c"; return 1; }
    done
}
