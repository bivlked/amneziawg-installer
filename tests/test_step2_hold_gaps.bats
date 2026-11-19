#!/usr/bin/env bats
# Step 2 holds amneziawg-dkms so that amneziawg-tools cannot pull the PPA
# module next to the one this path builds or unpacks. Gaps around that hold,
# found on review of the #285 fix and closed together:
#   1. a failed purge of an earlier amneziawg-dkms was only a warning, and the
#      hold then "protected" a package that was still installed;
#   2. APT::Ignore-Hold makes apt ignore every hold, so the protection is void
#      (and a setting that cannot be read must not pass as "off");
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

# stub_apt_config <exit code> <output> : answers only `shell v APT::Ignore-Hold/b`
stub_apt_config() {
    {
        echo '#!/usr/bin/env bash'
        echo '[ "$1 $2 $3" = "shell v APT::Ignore-Hold/b" ] || { echo "unexpected: $*" >&2; exit 99; }'
        printf 'printf "%%s" "%s"\n' "$2"
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
        stub_apt_config 0 "v='false'"; run honoured "$f"; [ "$status" -eq 0 ] || { echo "$f false: $status $output"; return 1; }
        stub_apt_config 0 "";          run honoured "$f"; [ "$status" -eq 0 ] || { echo "$f unset: $status $output"; return 1; }
    done
}

@test "Ignore-Hold: an enabled setting is a refusal with a reason, both installers" {
    stub_apt_config 0 "v='true'"
    local f
    for f in "${INSTALLERS[@]}"; do
        run honoured "$f"
        [ "$status" -eq 1 ] && [[ "$output" == ERR:*Ignore-Hold* ]] || { echo "$f: rc $status $output"; return 1; }
    done
}

@test "Ignore-Hold: an apt-config that fails or is missing is a refusal, not 'off'" {
    local f
    for f in "${INSTALLERS[@]}"; do
        stub_apt_config 1 "v='false'"; run honoured "$f"
        [ "$status" -eq 1 ] && [[ "$output" == ERR:*apt-config* ]] || { echo "$f failed: $status $output"; return 1; }
        rm -f "$BIN/apt-config"
        # no apt-config anywhere on PATH: only the stub directory and bash itself
        run env PATH="$BIN" "$BASH" -c "$(declare -f honoured); INSTALLERS=(); BATS_TEST_DIRNAME='$BATS_TEST_DIRNAME'; BIN='$BIN'; PATH='$BIN'; body=\$(/usr/bin/awk '/^_awg_apt_hold_honoured\\(\\) \\{/,/^\\}/' '$BATS_TEST_DIRNAME/../$f'); log_error() { echo \"ERR: \$*\"; }; eval \"\$body\"; _awg_apt_hold_honoured"
        [ "$status" -eq 1 ] && [[ "$output" == ERR:*apt-config* ]] || { echo "$f missing: $status $output"; return 1; }
    done
}

@test "Ignore-Hold: the helper body is the same in both installers apart from the messages" {
    local ru en
    ru=$(awk '/^_awg_apt_hold_honoured\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh" | grep -v 'log_error')
    en=$(awk '/^_awg_apt_hold_honoured\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh" | grep -v 'log_error')
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
            sed -n "$((g + 1))p" "$src" | grep -qE '^[[:space:]]*die ' || { echo "$f: guard at $g is not followed by die"; return 1; }
        done
    done
}

@test "purge: an amneziawg-dkms that survives the purge stops the pinned path" {
    local f src p c
    for f in "${INSTALLERS[@]}"; do
        src="$BATS_TEST_DIRNAME/../$f"
        p=$(grep -nE '\|\| dpkg --purge --force-all amneziawg-dkms amneziawg' "$src" | cut -d: -f1)
        [ "$(wc -l <<< "$p")" -eq 1 ] && [ -n "$p" ] || { echo "$f: purge chain: $p"; return 1; }
        c=$(awk -v s="$p" 'NR>s && NR<=s+12 && /^[[:space:]]*if _pkg_present amneziawg-dkms; then$/ {print NR; exit}' "$src")
        [ -n "$c" ] || { echo "$f: no presence check after the purge at $p"; return 1; }
        sed -n "$((c + 1))p" "$src" | grep -qE '^[[:space:]]*die ' || { echo "$f: the check at $c does not die"; return 1; }
        # the old soft path is gone
        run grep -cE 'log_warn .*(Не удалось полностью удалить|Could not fully remove)' "$src"
        [ "$output" = "0" ] || { echo "$f: the warn-only purge path is still there"; return 1; }
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
