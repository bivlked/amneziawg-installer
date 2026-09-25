#!/usr/bin/env bats
# Fixes from the September 2026 documentation audit, checked in both installers:
# - --uninstall must not run apt-get autoremove (same netplan-generator risk as
#   Issue #84) and must remove its own apt lock-timeout drop-in;
# - Raspberry Pi header meta-package follows the kernel flavour from uname -r;
# - --diagnostic reports the LOADED module next to the module file on disk;
# - the NIC offload step is gone (it never survived the reboot after step 1).

load test_helper

INSTALLERS=(install_amneziawg.sh install_amneziawg_en.sh)

_body() {
    # _body <file> <function>: the function definition, from its line to the closing brace.
    sed -n "/^$2() {\$/,/^}\$/p" "$BATS_TEST_DIRNAME/../$1"
}

@test "uninstall: no apt autoremove in step_uninstall (both languages)" {
    for f in "${INSTALLERS[@]}"; do
        body=$(_body "$f" step_uninstall)
        [ -n "$body" ] || { echo "$f: step_uninstall not found" >&2; return 1; }
        if echo "$body" | grep -vE '^[[:space:]]*#' | grep -qE 'apt(-get)?( +-[^ ]+)* +autoremove'; then
            echo "$f: step_uninstall still calls autoremove" >&2
            return 1
        fi
    done
}

@test "uninstall: removes the apt lock-timeout drop-in the installer creates (both languages)" {
    for f in "${INSTALLERS[@]}"; do
        # The installer creates it ...
        grep -q "> /etc/apt/apt.conf.d/99-amneziawg-lock-timeout" "$BATS_TEST_DIRNAME/../$f"
        # ... and step_uninstall must remove it.
        body=$(_body "$f" step_uninstall)
        echo "$body" | grep -vE '^[[:space:]]*#' | grep -q '/etc/apt/apt.conf.d/99-amneziawg-lock-timeout' \
            || { echo "$f: step_uninstall does not remove 99-amneziawg-lock-timeout" >&2; return 1; }
    done
}

@test "rpi headers: package follows the kernel flavour (both languages)" {
    for f in "${INSTALLERS[@]}"; do
        # shellcheck source=/dev/null
        source <(_body "$f" _rpi_headers_pkg)
        declare -F _rpi_headers_pkg >/dev/null || { echo "$f: no _rpi_headers_pkg" >&2; return 1; }
        [ "$(_rpi_headers_pkg 6.6.51+rpt-rpi-v6)" = linux-headers-rpi-v6 ]
        [ "$(_rpi_headers_pkg 6.6.51+rpt-rpi-v7)" = linux-headers-rpi-v7 ]
        [ "$(_rpi_headers_pkg 6.6.51+rpt-rpi-v7l)" = linux-headers-rpi-v7l ]
        [ "$(_rpi_headers_pkg 6.12.75+rpt-rpi-v8)" = linux-headers-rpi-v8 ]
        [ "$(_rpi_headers_pkg 6.12.75+rpt-rpi-2712)" = linux-headers-rpi-2712 ]
        [ "$(_rpi_headers_pkg 6.6.31-rpi-v8)" = linux-headers-rpi-v8 ]
        [ "$(_rpi_headers_pkg 6.6.31-rpi-v7l)" = linux-headers-rpi-v7l ]
        unset -f _rpi_headers_pkg
    done
}

@test "rpi headers: unknown flavour keeps the previous choice, non-RPi kernel gives nothing (both languages)" {
    for f in "${INSTALLERS[@]}"; do
        # shellcheck source=/dev/null
        source <(_body "$f" _rpi_headers_pkg)
        # Unknown flavour: the pre-audit behaviour (2712 by substring, otherwise v8).
        [ "$(_rpi_headers_pkg 6.18.1+rpt-rpi-2712k)" = linux-headers-rpi-2712 ]
        [ "$(_rpi_headers_pkg 6.18.1+rpt-rpi-v9)" = linux-headers-rpi-v8 ]
        # Not a Raspberry Pi Foundation kernel: empty, the caller takes its own path.
        [ -z "$(_rpi_headers_pkg 6.8.0-57-generic)" ]
        [ -z "$(_rpi_headers_pkg 6.1.0-28-arm64)" ]
        unset -f _rpi_headers_pkg
    done
}

@test "rpi headers: the headers block uses _rpi_headers_pkg, no hardcoded v8 choice left (both languages)" {
    for f in "${INSTALLERS[@]}"; do
        grep -qE 'rpi_headers="\$\(_rpi_headers_pkg ' "$BATS_TEST_DIRNAME/../$f" \
            || { echo "$f: headers block does not call _rpi_headers_pkg" >&2; return 1; }
        # Explicit if, not `! grep`: a negated command does not trip errexit, so
        # inside the loop only the last file would count.
        if grep -qE '^[[:space:]]+rpi_headers="linux-headers-rpi-v8"' "$BATS_TEST_DIRNAME/../$f"; then
            echo "$f: hardcoded rpi-v8 choice is back" >&2
            return 1
        fi
    done
}

@test "diagnostic: module info shows the loaded module and the file on disk (both languages)" {
    for f in "${INSTALLERS[@]}"; do
        # shellcheck source=/dev/null
        source <(_body "$f" _diag_sysattr)
        # shellcheck source=/dev/null
        source <(_body "$f" _diag_module_info)
        declare -F _diag_module_info >/dev/null || { echo "$f: no _diag_module_info" >&2; return 1; }
        local sysd="$BATS_TEST_TMPDIR/sys-$f"
        mkdir -p "$sysd"
        printf '3.1.20260812\n' > "$sysd/version"
        printf 'ABCDEF0123456789ABCDEF0\n' > "$sysd/srcversion"
        modinfo() { printf 'filename:       /lib/modules/x/updates/dkms/amneziawg.ko.zst\nsrcversion:     FFFFFFFFFFFFFFFFFFFFFFF\n'; }
        out=$(_diag_module_info "$sysd")
        echo "$out" | grep -q '3.1.20260812'
        echo "$out" | grep -q 'ABCDEF0123456789ABCDEF0'
        echo "$out" | grep -q 'FFFFFFFFFFFFFFFFFFFFFFF'
        echo "$out" | grep -q 'amneziawg.ko.zst'
        unset -f modinfo _diag_module_info _diag_sysattr
    done
}

@test "diagnostic: module not loaded and no module file are both reported, not silent (both languages)" {
    for f in "${INSTALLERS[@]}"; do
        # shellcheck source=/dev/null
        source <(_body "$f" _diag_sysattr)
        # shellcheck source=/dev/null
        source <(_body "$f" _diag_module_info)
        modinfo() { return 1; }
        out=$(_diag_module_info "$BATS_TEST_TMPDIR/no-such-dir-$f")
        [ -n "$out" ]
        # Two separate N/A lines: loaded and on disk.
        [ "$(echo "$out" | grep -c 'N/A')" -ge 2 ]
        unset -f modinfo _diag_module_info _diag_sysattr
    done
}

@test "diagnostic: create_diagnostic_report calls _diag_module_info (both languages)" {
    for f in "${INSTALLERS[@]}"; do
        _body "$f" create_diagnostic_report | grep -q '_diag_module_info'
    done
}

@test "nic offloads: optimize_nic and ethtool are gone (both languages)" {
    for f in "${INSTALLERS[@]}"; do
        # Code lines only: the comment that explains the removal names ethtool.
        # Explicit if, not `! grep` (see the rpi headers test above).
        if grep -vE '^[[:space:]]*#' "$BATS_TEST_DIRNAME/../$f" | grep -qE 'optimize_nic|ethtool'; then
            echo "$f: optimize_nic or ethtool is back" >&2
            return 1
        fi
    done
}

@test "diagnostic: srcversion match and mismatch are stated explicitly (both languages)" {
    for f in "${INSTALLERS[@]}"; do
        # shellcheck source=/dev/null
        source <(_body "$f" _diag_sysattr)
        # shellcheck source=/dev/null
        source <(_body "$f" _diag_module_info)
        local sysd="$BATS_TEST_TMPDIR/cmp-$f"
        mkdir -p "$sysd"
        printf 'SAMESRC0000000000000000\n' > "$sysd/srcversion"
        modinfo() { printf 'filename: /x/amneziawg.ko\nsrcversion:     SAMESRC0000000000000000\n'; }
        out=$(_diag_module_info "$sysd")
        echo "$out" | grep -qiE 'совпадает|matches' || { echo "$f: no match line" >&2; return 1; }
        modinfo() { printf 'filename: /x/amneziawg.ko\nsrcversion:     OTHERSRC000000000000000\n'; }
        out=$(_diag_module_info "$sysd")
        echo "$out" | grep -qE 'РАЗЛИЧАЕТСЯ|DIFFERENT' || { echo "$f: no mismatch line" >&2; return 1; }
        unset -f modinfo _diag_module_info _diag_sysattr
    done
}

@test "diagnostic: module directory without attribute files says so, not a bare N/A (both languages)" {
    for f in "${INSTALLERS[@]}"; do
        # shellcheck source=/dev/null
        source <(_body "$f" _diag_sysattr)
        # shellcheck source=/dev/null
        source <(_body "$f" _diag_module_info)
        local sysd="$BATS_TEST_TMPDIR/empty-$f"
        mkdir -p "$sysd"
        : > "$sysd/srcversion"
        modinfo() { return 1; }
        out=$(_diag_module_info "$sysd")
        # version file is absent, srcversion file is empty: two different words.
        echo "$out" | grep -E 'version:' | grep -qiE 'нет файла|no file' || { echo "$f: missing file not named" >&2; echo "$out" >&2; return 1; }
        echo "$out" | grep -E 'srcversion:' | grep -qiE 'пусто|empty' || { echo "$f: empty file not named" >&2; echo "$out" >&2; return 1; }
        # No comparison line when one side is unknown.
        if echo "$out" | grep -qE 'совпадает|matches|РАЗЛИЧАЕТСЯ|DIFFERENT'; then
            echo "$f: compared with an unknown side" >&2; return 1
        fi
        unset -f modinfo _diag_module_info _diag_sysattr
    done
}