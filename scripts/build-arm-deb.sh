#!/bin/bash
# build-arm-deb.sh — Build amneziawg kernel module and package as .deb
#
# Usage (environment variables):
#   KERNEL_ID       Target ID (e.g. rpi-bookworm-arm64). Used in .deb package name.
#   OUTPUT_DIR      Directory to write the .deb file. Default: /output
#   MODULE_VERSION  amneziawg module version tag. Default: upstream default branch HEAD.
#
# The script:
#   1. Detects the installed kernel headers and resolves the exact kernel version
#   2. Clones amneziawg-linux-kernel-module and builds amneziawg.ko
#   3. Packages the .ko into a .deb with a postinst that runs depmod
#   4. Writes the .deb to OUTPUT_DIR
#
# Output filename: amneziawg-kmod-${KERNEL_ID}_${KERNEL_VERSION}_${ARCH}.deb
# e.g.            amneziawg-kmod-rpi-bookworm-arm64_6.12.75+rpt-rpi-v8_arm64.deb

set -euo pipefail

KERNEL_ID="${KERNEL_ID:?KERNEL_ID must be set}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
MODULE_REPO="https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git"
MODULE_VERSION="${MODULE_VERSION:-}"

echo "=== amneziawg ARM .deb builder ==="
echo "KERNEL_ID: $KERNEL_ID"
echo "Running as: $(uname -a)"

# Resolve kernel version from installed headers (pick first with a build dir)
KERNEL_VERSION=""
for _d in /lib/modules/*/build; do
    if [[ -d "$_d" ]]; then
        KERNEL_VERSION="$(basename "$(dirname "$_d")")"
        break
    fi
done
if [[ -z "$KERNEL_VERSION" ]]; then
    echo "ERROR: No kernel build directory found under /lib/modules/" >&2
    ls -la /lib/modules/ >&2 2>/dev/null || true
    exit 1
fi
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
git clone --depth=1 ${MODULE_VERSION:+--branch "$MODULE_VERSION"} \
    "$MODULE_REPO" "$WORK_DIR/src"

# Verify kernel build directory exists
if [[ ! -d "/lib/modules/${KERNEL_VERSION}/build" ]]; then
    echo "ERROR: Kernel build directory /lib/modules/${KERNEL_VERSION}/build not found" >&2
    echo "Installed modules: $(ls /lib/modules/)" >&2
    exit 1
fi

# Build (upstream Makefile lives in src/ subdir of the cloned repo)
echo "--- Building kernel module ---"
make -C "$WORK_DIR/src/src" \
    KERNELRELEASE="$KERNEL_VERSION" \
    KERNELDIR="/lib/modules/${KERNEL_VERSION}/build" \
    module

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
echo "Module version: $MODULE_VER"

# Package as .deb
PKG_NAME="amneziawg-kmod-${KERNEL_ID}"
PKG_VERSION="${MODULE_VER}-${KERNEL_VERSION//+/\~}"   # dpkg-safe: + → ~
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
if xz --check=crc32 --lzma2=dict=1MiB -f "$KO_FILE" 2>/dev/null; then
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
    echo "xz compression skipped — packaging uncompressed .ko"
fi

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
