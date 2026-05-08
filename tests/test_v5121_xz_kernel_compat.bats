#!/usr/bin/env bats
# v5.12.1 Issue #76 — kernel-compatible xz preset for ARM prebuilts.
#
# Background: until v5.12.0 build-arm-deb.sh used `xz -9` which produced
# valid xz streams (round-trips through `xz -t` and `xz -d`) but the in-tree
# kernel decompressor on Debian 13 trixie 6.12.85+deb13-arm64 returned
# `decompression failed with status 6`. Manual decompression + `insmod`
# worked, ruling out a content bug.
#
# Fix: switch to the kernel's own modinst preset:
#   xz --check=crc32 --lzma2=dict=1MiB
# matches scripts/Makefile.modinst defaults — crc32 (kernel decompressor
# does not consume xz-default crc64 streams) and 1 MiB dictionary (in-tree
# decoder memory budget).
#
# Plus a build-time sanity gate: refuse to ship a .ko.xz that does not
# round-trip via `xz -t` and `xz -d -c` after compression.

setup() {
    BUILD="${BATS_TEST_DIRNAME}/../scripts/build-arm-deb.sh"
    [ -f "$BUILD" ] || { echo "build-arm-deb.sh missing" >&2; return 1; }
}

@test "v5.12.1: build script no longer uses bare 'xz -9' on the kernel module" {
    # The v5.12.0 invocation `xz -9 "$MODULE_INSTALL_PATH/amneziawg.ko"` is the
    # exact line Issue #76 traced to. Make sure it is gone.
    ! grep -qE 'xz -9 "\$MODULE_INSTALL_PATH/amneziawg\.ko"' "$BUILD"
}

@test "v5.12.1: build script uses --check=crc32 (kernel-compatible)" {
    grep -qE 'xz .*--check=crc32' "$BUILD"
}

@test "v5.12.1: build script uses --lzma2=dict=1MiB (in-tree decoder budget)" {
    grep -qE 'xz .*--lzma2=dict=1MiB' "$BUILD"
}

@test "v5.12.1: build script runs xz -t round-trip sanity on the produced .ko.xz" {
    grep -qE 'xz -t "\$KO_XZ"' "$BUILD"
}

@test "v5.12.1: build script runs xz -d round-trip sanity on the produced .ko.xz" {
    grep -qE 'xz -d -c "\$KO_XZ"' "$BUILD"
}

@test "v5.12.1: build script aborts on sanity failure (no broken prebuilt published)" {
    # "exit 1" must appear inside the sanity branch so a corrupt compress
    # stream cannot be packaged into the .deb.
    block=$(awk '/KO_FILE=/,/^fi$/' "$BUILD")
    [[ "$block" == *'sanity check failed'* ]]
    [[ "$block" == *'exit 1'* ]]
}

@test "v5.12.1: xz with chosen flags round-trips locally (sanity on the tooling)" {
    # Toolchain smoke test, NOT a kernel-decompressor compatibility proof.
    # The actual incompatibility on Issue #76 is between userspace xz
    # output and the in-tree decoder — only a real ARM kernel can prove
    # round-trip there. This test confirms the build host's xz binary
    # accepts our flags and produces a stream userspace can decode.
    skip_if_no_xz() {
        command -v xz >/dev/null 2>&1 || skip "xz not installed"
    }
    skip_if_no_xz

    tmp=$(mktemp -d)
    # 256 KiB of zero bytes — small, deterministic, fits in any dict size.
    head -c 262144 /dev/zero > "$tmp/sample"
    xz --check=crc32 --lzma2=dict=1MiB -f "$tmp/sample"
    [ -f "$tmp/sample.xz" ]
    xz -t "$tmp/sample.xz"
    out=$(xz -d -c "$tmp/sample.xz" | wc -c)
    [ "$out" -eq 262144 ]
    rm -rf "$tmp"
}
