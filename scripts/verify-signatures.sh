#!/usr/bin/env bash
# Verify the offline minisign signatures for a tag.
#
#   bash scripts/verify-signatures.sh v5.29.0
#
# Checks, for each signed file:
#   1. signing/<file>.minisig exists;
#   2. it verifies against KEYS.txt for the file as it stands in the working
#      tree;
#   3. its trusted comment names this exact tag and this exact file.
#
# Point 3 is not decoration. A signature verifies a byte sequence, not an
# intention: an old, perfectly valid signature paired with its old, perfectly
# valid file passes point 2 for any tag. Binding the comment to tag+filename is
# what turns "these bytes were signed once" into "these bytes were signed as
# part of THIS release", and it is the rollback protection the design promises.
#
# Signing itself never happens here or in CI. The private key lives on the
# maintainer's machine and is used by hand:
#
#   TAG=v5.29.0
#   KEY=~/.minisign/amneziawg-installer.key
#   mkdir -p signing
#   for f in $(bash scripts/signed-file-list.sh); do
#     minisign -Sm "$f" -s "$KEY" -x "signing/$f.minisig" \
#              -t "amneziawg-installer $TAG $f"
#   done
set -euo pipefail

TAG="${1:-}"
if [[ -z "$TAG" ]]; then
    echo "usage: $0 <tag>" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v minisign >/dev/null 2>&1; then
    echo "ERROR: minisign is not installed" >&2
    echo "       Ubuntu/Debian: sudo apt-get install -y minisign" >&2
    exit 3
fi

if [[ ! -f KEYS.txt ]]; then
    echo "ERROR: KEYS.txt is missing from the repository root" >&2
    exit 3
fi

fail=0
checked=0

while read -r file; do
    [[ -n "$file" ]] || continue
    sig="signing/${file}.minisig"

    if [[ ! -f "$file" ]]; then
        echo "ERROR: $file is listed as signed but does not exist" >&2
        fail=1
        continue
    fi
    if [[ ! -f "$sig" ]]; then
        echo "ERROR: missing signature $sig" >&2
        echo "       sign it locally, see the header of this script" >&2
        fail=1
        continue
    fi

    out=""
    rc=0
    out="$(minisign -V -p KEYS.txt -m "$file" -x "$sig" 2>&1)" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        echo "ERROR: $file does not match $sig" >&2
        printf '%s\n' "$out" >&2
        fail=1
        continue
    fi

    want="amneziawg-installer ${TAG} ${file}"
    got="$(printf '%s\n' "$out" | sed -n 's/^Trusted comment: //p' | head -1)"
    if [[ "$got" != "$want" ]]; then
        echo "ERROR: $sig carries the wrong trusted comment" >&2
        echo "       expected: $want" >&2
        echo "       found:    ${got:-<none>}" >&2
        fail=1
        continue
    fi

    echo "ok  $file"
    checked=$((checked + 1))
done < <(bash "$SCRIPT_DIR/signed-file-list.sh")

# A run that verified nothing must not report success. Without this the script
# would pass on an empty list, which is the one outcome indistinguishable from
# a broken check.
expected="$(bash "$SCRIPT_DIR/signed-file-list.sh" | grep -c . || true)"
if [[ "$checked" -ne "$expected" ]]; then
    echo "ERROR: verified $checked of $expected files" >&2
    fail=1
fi

if [[ "$fail" -ne 0 ]]; then
    echo "FAIL: signatures for $TAG are not in order" >&2
    exit 1
fi
echo "PASS: $checked signatures verified for $TAG"
