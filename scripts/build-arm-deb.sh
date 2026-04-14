#!/bin/bash
# build-arm-deb.sh — Build amneziawg kernel module and package as .deb
#
# Usage (environment variables):
#   KERNEL_ID       Target ID (e.g. rpi-bookworm-arm64). Used in .deb package name.
#   OUTPUT_DIR      Directory to write the .deb file. Default: /output
#   MODULE_VERSION  amneziawg module version tag. Default: latest tag from upstream.
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

# Resolve exact kernel version from installed headers
KERNEL_VERSION="$(ls /lib/modules/ | head -1)"
if [[ -z "$KERNEL_VERSION" ]]; then
    echo "ERROR: No kernel headers found under /lib/modules/" >&2
    exit 1
fi
echo "Kernel version: $KERNEL_VERSION"

ARCH="$(dpkg --print-architecture)"
echo "Architecture: $ARCH"

# Verify build tools are available
for cmd in make gcc git dpkg-deb depmod; do
    command -v "$cmd" &>/dev/null || { echo "ERROR: $cmd not found" >&2; exit 1; }
done

# Clone module source
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "--- Cloning amneziawg-linux-kernel-module ---"
git clone --depth=1 ${MODULE_VERSION:+--branch "$MODULE_VERSION"} \
    "$MODULE_REPO" "$WORK_DIR/src"

# Build
echo "--- Building kernel module ---"
make -C "/lib/modules/${KERNEL_VERSION}/build" \
    M="$WORK_DIR/src" \
    modules

KO_PATH="$WORK_DIR/src/amneziawg.ko"
if [[ ! -f "$KO_PATH" ]]; then
    echo "ERROR: amneziawg.ko not found after build" >&2
    exit 1
fi

# Verify vermagic matches the target kernel
VERMAGIC="$(modinfo "$KO_PATH" | awk '/^vermagic:/{print $2}')"
echo "Module vermagic: $VERMAGIC"
if [[ "$VERMAGIC" != "$KERNEL_VERSION" ]]; then
    echo "ERROR: vermagic mismatch (got $VERMAGIC, expected $KERNEL_VERSION)" >&2
    exit 1
fi

MODULE_VER="$(modinfo "$KO_PATH" | awk '/^version:/{print $2}')"
echo "Module version: $MODULE_VER"

# Package as .deb
PKG_NAME="amneziawg-kmod-${KERNEL_ID}"
PKG_VERSION="${MODULE_VER}-${KERNEL_VERSION//+/\~}"   # dpkg-safe: + → ~
DEB_DIR="$WORK_DIR/deb"
MODULE_INSTALL_PATH="${DEB_DIR}/lib/modules/${KERNEL_VERSION}/extra"

mkdir -p "$MODULE_INSTALL_PATH" "${DEB_DIR}/DEBIAN"

cp "$KO_PATH" "$MODULE_INSTALL_PATH/amneziawg.ko"
xz -9 "$MODULE_INSTALL_PATH/amneziawg.ko" 2>/dev/null || true  # compress if xz available

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
