#!/bin/bash
# build-arm-deb.sh — Build amneziawg kernel module and package as .deb
#
# Usage (environment variables):
#   KERNEL_ID       Target ID (e.g. rpi-bookworm-arm64). Used in .deb package name.
#   OUTPUT_DIR      Directory to write the .deb file. Default: /output
#   MODULE_VERSION  amneziawg module ref override (tag/branch). When empty, falls
#                   back to scripts/arm-module-version.txt, then default-branch
#                   HEAD. See _arm_module_ref for precedence.
#   INSTALLER_TAG   Optional installer release tag, recorded in the build manifest.
#
# The script:
#   1. Detects the installed kernel headers and resolves the exact kernel version
#   2. Clones amneziawg-linux-kernel-module (pinned ref if set) and builds amneziawg.ko,
#      recording the exact upstream commit for reproducibility/audit
#   3. Packages the .ko into a .deb with a postinst that runs depmod
#   4. Writes the .deb, its .sha256, and a .manifest.json to OUTPUT_DIR
#
# Output: amneziawg-kmod-${KERNEL_ID}_${KERNEL_VERSION}_${ARCH}.deb (+ .sha256, .manifest.json)
# e.g.    amneziawg-kmod-rpi-bookworm-arm64_6.12.75+rpt-rpi-v8_arm64.deb

# Resolve kernel version from /lib/modules/*/build (or alt root for tests).
# Honours KERNEL_VERSION env when set (must point at an existing build dir).
# Otherwise auto-detects: zero candidates → fail; exactly one → use it;
# multiple → fail explicitly and ask caller to set KERNEL_VERSION.
# External code review (8 may 2026): the previous loop silently
# picked the FIRST candidate, which on developer hosts with several installed
# kernels resulted in building against an unintended target. In our CI matrix
# each QEMU container installs exactly one headers package so the new
# fail-on-ambiguity path never triggers there.
# Arg $1: modules root directory (default /lib/modules), used by bats tests.
# Stdout: resolved kernel version on success.
# Return: 0 on success, 1 on error (message goes to stderr).
_resolve_kernel_version() {
    local modules_root="${1:-/lib/modules}"

    if [[ -n "${KERNEL_VERSION:-}" ]]; then
        if [[ ! -d "${modules_root}/${KERNEL_VERSION}/build" ]]; then
            echo "ERROR: KERNEL_VERSION='${KERNEL_VERSION}' is set but ${modules_root}/${KERNEL_VERSION}/build does not exist" >&2
            ls -la "$modules_root/" >&2 2>/dev/null || true
            return 1
        fi
        echo "$KERNEL_VERSION"
        return 0
    fi

    local _candidates=()
    local _d
    for _d in "$modules_root"/*/build; do
        if [[ -d "$_d" ]]; then
            _candidates+=("$(basename "$(dirname "$_d")")")
        fi
    done

    case "${#_candidates[@]}" in
        0)
            echo "ERROR: No kernel build directory found under $modules_root/" >&2
            ls -la "$modules_root/" >&2 2>/dev/null || true
            return 1
            ;;
        1)
            echo "${_candidates[0]}"
            return 0
            ;;
        *)
            echo "ERROR: Multiple kernel build directories found under $modules_root/:" >&2
            printf '  - %s\n' "${_candidates[@]}" >&2
            echo "Set KERNEL_VERSION env to disambiguate which one to build against." >&2
            return 1
            ;;
    esac
}

# Resolve which upstream amneziawg-linux-kernel-module ref to build, by precedence:
#   1. MODULE_VERSION env (workflow_dispatch input)  - explicit override
#   2. scripts/arm-module-version.txt pin            - per-release reproducibility
#   3. empty -> upstream default branch HEAD          - last resort (logged)
# The pin file holds a single tag or branch name; "HEAD" or empty means default
# branch. A commit SHA is not valid here (clone uses --depth=1 --branch), but the
# build manifest always records the exact commit that was actually built.
# Arg $1: pin-file path (default: alongside this script). Stdout: the ref or "".
# Optional arg is exercised by bats; the main body relies on the default path.
# shellcheck disable=SC2120
_arm_module_ref() {
    local pin_file="${1:-$(dirname "${BASH_SOURCE[0]}")/arm-module-version.txt}"
    if [[ -n "${MODULE_VERSION:-}" ]]; then
        printf '%s' "$MODULE_VERSION"
        return 0
    fi
    if [[ -f "$pin_file" ]]; then
        local ref
        ref="$(grep -vE '^[[:space:]]*(#|$)' "$pin_file" | head -n1 | tr -d '[:space:]')"
        if [[ -n "$ref" && "$ref" != "HEAD" ]]; then
            printf '%s' "$ref"
            return 0
        fi
    fi
    printf ''
}

# The module version as the vendor sets it in src/version.h. The upstream
# src/Makefile hardcodes WIREGUARD_VERSION = 1.0.0 and passes it to Kbuild, which
# overrides version.h, so a plain `make -C src` reported "1.0.0" for every line
# (DKMS from the PPA builds through Kbuild and reports the real version).
# check/diagnose judge the #233 fix by this version, hence it is read here and
# passed to make explicitly. Arg $1: the src/ directory. Stdout: the version.
_arm_module_version_h() {
    local f="${1:?src dir}/version.h" v
    [[ -f "$f" ]] || { echo "ERROR: $f not found" >&2; return 1; }
    v="$(sed -nE 's/^[[:space:]]*#[[:space:]]*define[[:space:]]+WIREGUARD_VERSION[[:space:]]+"([^"]+)".*/\1/p' "$f" | head -n1)"
    [[ -n "$v" ]] || { echo "ERROR: no WIREGUARD_VERSION define in $f" >&2; return 1; }
    printf '%s' "$v"
}

# 0 when the version carries the vendor fix for amneziawg-linux-kernel-module#233
# (3.1.20261113-02 and newer, on the 3.1 line or later). The same boundary as
# _awg_kmod_has_233_fix in awg_common.sh, kept in step by a test: a prebuilt
# that check/diagnose would still call unfixed must not be published.
_arm_version_has_233_fix() {
    [[ "${1:-}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]{8})(-([0-9]{1,4}))?([^0-9]|$) ]] || return 1
    local maj=$((10#${BASH_REMATCH[1]})) mnr=$((10#${BASH_REMATCH[2]})) day=$((10#${BASH_REMATCH[3]})) suf="${BASH_REMATCH[5]}"
    (( maj > 3 || (maj == 3 && mnr >= 1) )) || return 1
    (( day > 20261113 )) && return 0
    (( day == 20261113 )) && [[ -n "$suf" ]] && (( 10#$suf >= 2 ))
}

# Build the module from src/ with the version.h value. Args: src dir, kernel
# release, version.
_arm_build_module() {
    make -C "$1" \
        KERNELRELEASE="$2" \
        KERNELDIR="/lib/modules/$2/build" \
        WIREGUARD_VERSION="$3" \
        module
}

# The built module must report exactly the version.h value: anything else means
# the override above did not reach Kbuild. Args: expected version, modinfo output.
_arm_check_built_version() {
    local want="$1" got
    got="$(printf '%s\n' "$2" | awk '/^version:/{print $2; exit}')"
    if [[ "$got" != "$want" ]]; then
        echo "ERROR: the built module reports version '${got:-<none>}', expected '$want' from version.h" >&2
        return 1
    fi
}

# When sourced (e.g. by bats tests), expose helpers and skip the main body.
# When executed directly (./build-arm-deb.sh), continue with the build flow.
# `set -euo pipefail` is moved BELOW the source guard so it does not leak into
# the caller's shell options when the script is sourced from tests.
(return 0 2>/dev/null) && return 0

set -euo pipefail

KERNEL_ID="${KERNEL_ID:?KERNEL_ID must be set}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
MODULE_REPO="https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git"
MODULE_REF="$(_arm_module_ref)"

echo "=== amneziawg ARM .deb builder ==="
echo "KERNEL_ID: $KERNEL_ID"
echo "Running as: $(uname -a)"

KERNEL_VERSION="$(_resolve_kernel_version /lib/modules)"
echo "Kernel version: $KERNEL_VERSION"

ARCH="$(dpkg --print-architecture)"
echo "Architecture: $ARCH"

# Verify build tools are available
for cmd in make gcc git dpkg-deb depmod modinfo sha256sum awk xz; do
    command -v "$cmd" &>/dev/null || { echo "ERROR: $cmd not found" >&2; exit 1; }
done

# Clone module source
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "--- Cloning amneziawg-linux-kernel-module ---"
echo "Requested module ref: ${MODULE_REF:-<upstream default branch HEAD>}"
git clone --depth=1 ${MODULE_REF:+--branch "$MODULE_REF"} \
    "$MODULE_REPO" "$WORK_DIR/src"

# Record the exact commit actually built (reproducibility/audit even on HEAD).
MODULE_COMMIT="$(git -C "$WORK_DIR/src" rev-parse HEAD 2>/dev/null || echo unknown)"
echo "Upstream module commit: $MODULE_COMMIT"

# Verify kernel build directory exists
if [[ ! -d "/lib/modules/${KERNEL_VERSION}/build" ]]; then
    echo "ERROR: Kernel build directory /lib/modules/${KERNEL_VERSION}/build not found" >&2
    echo "Installed modules: $(ls /lib/modules/)" >&2
    exit 1
fi

# The version from version.h, and no publishing of a source without the #233
# fix: a manual module_version input wins over the pin, and the assets are
# shared by name, so an older ref would replace fixed packages for everyone.
WG_VERSION="$(_arm_module_version_h "$WORK_DIR/src/src")"
echo "Module version (version.h): $WG_VERSION"
if ! _arm_version_has_233_fix "$WG_VERSION"; then
    echo "ERROR: module $WG_VERSION has no fix for amneziawg-linux-kernel-module#233 (needs the 3.1 line or later, 3.1.20261113-02 or newer); refusing to build packages that would replace fixed ones" >&2
    exit 1
fi

# Build (upstream Makefile lives in src/ subdir of the cloned repo)
echo "--- Building kernel module ---"
_arm_build_module "$WORK_DIR/src/src" "$KERNEL_VERSION" "$WG_VERSION"

KO_PATH="$WORK_DIR/src/src/amneziawg.ko"
if [[ ! -f "$KO_PATH" ]]; then
    echo "ERROR: amneziawg.ko not found after build" >&2
    exit 1
fi

# Read module metadata once
MODINFO_OUT="$(modinfo "$KO_PATH")"
VERMAGIC="$(echo "$MODINFO_OUT" | awk '/^vermagic:/{print $2}')"
MODULE_VER="$(echo "$MODINFO_OUT" | awk '/^version:/{print $2}')"

echo "Module vermagic: $VERMAGIC"
if [[ "$VERMAGIC" != "$KERNEL_VERSION" ]]; then
    echo "ERROR: vermagic mismatch (got $VERMAGIC, expected $KERNEL_VERSION)" >&2
    exit 1
fi

if [[ -z "$MODULE_VER" ]]; then
    echo "ERROR: Could not determine module version from modinfo" >&2
    echo "$MODINFO_OUT" >&2
    exit 1
fi
_arm_check_built_version "$WG_VERSION" "$MODINFO_OUT"
echo "Module version: $MODULE_VER"

# Package as .deb
PKG_NAME="amneziawg-kmod-${KERNEL_ID}"
# Историческая замена '+' -> '~' в kernel-части ревизии сохранена ради
# непрерывности имён артефактов в релизе arm-packages (инсталлер матчит
# .deb по имени). Замечание: '+' валиден в Debian-версиях, а '~' сортируется
# РАНЬШЕ пустой строки - для версионного сравнения замена не нужна и даже
# инвертирует порядок, но пакеты ставятся из файла (dpkg -i), не из архива,
# так что на практике это только схема имён.
PKG_VERSION="${MODULE_VER}-${KERNEL_VERSION//+/\~}"
DEB_DIR="$WORK_DIR/deb"
MODULE_INSTALL_PATH="${DEB_DIR}/lib/modules/${KERNEL_VERSION}/extra"

mkdir -p "$MODULE_INSTALL_PATH" "${DEB_DIR}/DEBIAN"

cp "$KO_PATH" "$MODULE_INSTALL_PATH/amneziawg.ko"
# xz options chosen to match upstream kernel scripts/Makefile.modinst:
#   --check=crc32  : in-tree decompressor expects crc32, not the xz-default crc64.
#   --lzma2=dict=1MiB : 1 MiB dictionary fits in-tree decoder memory budget on
#                       all supported targets. xz -9 (default 64 MiB) decodes
#                       fine in userspace via `xz -d` but kernel decompressor
#                       on Debian 13 trixie 6.12.85-1 returns "decompression
#                       failed with status 6" (Issue #76). Reverting to the
#                       conservative preset is the documented fix.
KO_FILE="$MODULE_INSTALL_PATH/amneziawg.ko"
# stderr xz сохраняем: реальный сбой (диск/OOM под QEMU) не должен быть
# неотличим в логе сборки от намеренного пропуска компрессии.
XZ_ERR="$WORK_DIR/xz_err.txt"
if xz --check=crc32 --lzma2=dict=1MiB -f "$KO_FILE" 2>"$XZ_ERR"; then
    KO_XZ="${KO_FILE}.xz"
    # Sanity: kernel-compatible streams round-trip through `xz -d` and `xz -t`.
    # Catches preset/filter mismatches at build time instead of in users' dmesg.
    if xz -t "$KO_XZ" 2>/dev/null && xz -d -c "$KO_XZ" >/dev/null 2>&1; then
        echo "Module compressed with xz (crc32, 1 MiB dict, sanity OK)"
    else
        echo "ERROR: xz sanity check failed for $KO_XZ — refusing to ship a broken prebuilt." >&2
        exit 1
    fi
else
    echo "xz compression failed - packaging uncompressed .ko. xz stderr:"
    cat "$XZ_ERR" 2>/dev/null || true
fi
rm -f "$XZ_ERR" 2>/dev/null || true

cat > "${DEB_DIR}/DEBIAN/control" <<EOF
Package: ${PKG_NAME}
Version: ${PKG_VERSION}
Architecture: ${ARCH}
Maintainer: amneziawg-installer contributors
Description: AmneziaWG kernel module (prebuilt for ${KERNEL_ID})
 Precompiled amneziawg.ko for kernel ${KERNEL_VERSION}.
 Target: ${KERNEL_ID}
 Built from: amnezia-vpn/amneziawg-linux-kernel-module
EOF

cat > "${DEB_DIR}/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
depmod -a
exit 0
POSTINST
chmod 755 "${DEB_DIR}/DEBIAN/postinst"

mkdir -p "$OUTPUT_DIR"
DEB_FILE="${OUTPUT_DIR}/${PKG_NAME}_${KERNEL_VERSION}_${ARCH}.deb"

dpkg-deb --build "$DEB_DIR" "$DEB_FILE"
echo "--- Built: $DEB_FILE ---"
ls -lh "$DEB_FILE"

# Generate SHA256 checksum alongside the .deb
sha256sum "$DEB_FILE" | awk '{print $1}' > "${DEB_FILE}.sha256"
echo "SHA256: $(cat "${DEB_FILE}.sha256")"

# Build manifest alongside the .deb: makes a mutable arm-packages asset auditable
# (which installer tag, which upstream commit, which kernel) even though the
# asset filename is keyed on target/kernel/arch and re-uploaded with --clobber.
MANIFEST_FILE="${DEB_FILE}.manifest.json"
cat > "$MANIFEST_FILE" <<EOF
{
  "installer_tag": "${INSTALLER_TAG:-}",
  "kernel_id": "${KERNEL_ID}",
  "kernel_version": "${KERNEL_VERSION}",
  "arch": "${ARCH}",
  "module_version": "${MODULE_VER}",
  "module_ref_requested": "${MODULE_REF:-default-branch}",
  "module_commit": "${MODULE_COMMIT}",
  "deb_file": "$(basename "$DEB_FILE")",
  "deb_sha256": "$(cat "${DEB_FILE}.sha256")",
  "built_at_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
echo "--- Manifest: $MANIFEST_FILE ---"
cat "$MANIFEST_FILE"
