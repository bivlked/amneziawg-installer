# Kernel module fixtures (tests only)

Used by `tests/test_kmod_compat_fix.bats`. Not shipped by the installer.

| File | Origin | License |
|---|---|---|
| `compat.h.base` | `src/compat/compat.h` of [amnezia-vpn/amneziawg-linux-kernel-module](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module) at tag `v3.1.20260906` (commit `4569c4c`), byte-identical to the `amneziawg-dkms` source in the PPA | GPL-2.0 (see the SPDX header in the file) |
| `pr218.diff` | diff of commit `62189503fa51` from upstream [PR #218](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/pull/218) | GPL-2.0, as part of that project |

SHA-256:

- `compat.h.base` - `b14346040ce0188c47e2db2baad1a4f21aa784510f6c95bbb4aa58d5bbe691c9`
- `compat.h.base` with `pr218.diff` applied - `8d47a358b4df0b2187788ce6f88ad63128218de1be22c78b263ef3e5d770c26b`

Both files are hash-pinned: do not reformat them (`.gitattributes` marks both `-text`, `.editorconfig` leaves their whitespace and final newline alone).
