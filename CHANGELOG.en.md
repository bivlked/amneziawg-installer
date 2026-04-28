<p align="center">
  <b>RU</b> <a href="CHANGELOG.md">Русский</a> | <b>EN</b> English
</p>

# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

---

## [5.11.3] — 2026-04-28

UX patch on top of v5.11.2: cleanups for interactive commands so they behave well under scripts/cron, collision protection on rapid-fire backups, and FAQ extensions that answer recent questions from issues/discussions — no architectural changes.

### Added

- **CLI flag `--yes` for `manage_amneziawg.sh` (RU+EN)** and the equivalent `AWG_YES=1` environment variable skip every confirm prompt — in `remove`, `restore`, and `restart`. Useful for cron, Ansible, and one-off interactive calls that already pre-confirmed. Default behaviour is unchanged — without the flag and without the env var, confirm still works the same way.
- **Millisecond precision in backup filenames** — `awg_backup_2026-04-28_15-53-50.123.tar.gz` (`date +%F_%H-%M-%S.%3N` in `_backup_configs_nolock`). Resolves the collision in the "two backups within the same second" scenario (e.g. regen → backup → modify → backup) — previously the second tar overwrote the first. Backwards-compat: legacy backups without the `.NNN` suffix still match the `find` pattern and sort correctly.
- **FAQ: ICMP inside the tunnel (RU+EN, ADVANCED.md)** — why `ping` server↔clients does not flow after `default deny incoming`, how to open `awg0` in UFW, how to fix a user-edited `before.rules` via `-i <iface>`. Discussion [#63](https://github.com/bivlked/amneziawg-installer/discussions/63) (@PavelVVrn). Explicit warning: `ufw allow ... proto icmp` does not work (UFW does not support `icmp` via the `proto` flag).
- **Carrier → I1 map extended.** Tele2 (Krasnoyarsk) updated: in addition to `Jc=3` the `I1` line must be removed entirely (AWG 1.0 fallback, no CPS masking). New row Megafon (regions) — also `I1=absent`. Below the table — explainer with the exact commands: `systemctl restart awg-quick@awg0` on the server + `manage regen <name>` for every client. Issue [#42](https://github.com/bivlked/amneziawg-installer/issues/42) (@alkorrnd).
- **`--psk` highlight in README.md/.en.md** — example in the Quick Reference (`add my_iphone --psk`) + a new FAQ entry "Shadowrocket on iOS/macOS does not connect — needs PresharedKey" with step-by-step instructions for new and existing clients. Previously the feature was documented only in ADVANCED — Issue [#62](https://github.com/bivlked/amneziawg-installer/issues/62) (@andreykorobko) showed it was not discoverable.

### Tests

**+34 new bats** (295 total, up from 261 on v5.11.2):

- `test_yes_flag.bats` (+11) — extract `confirm_action` from manage scripts, exercise CLI_YES / AWG_YES branches in isolation; non-`"1"` values of AWG_YES (`"yes"`, `"true"`, `"0"`) are explicitly proven NOT to match the bypass branch under forced-interactive mode; CLI parser accepts `--yes`; usage help mentions `--yes` + `AWG_YES=1`; RU/EN structural parity.
- `test_backup_collision.bats` (+8) — `date +%3N` produces distinct values under rapid fire; `find` pattern matches both legacy and ms-suffix names; `sort -r` orders correctly in mixed-format directories; RU/EN parity.
- `test_v5113_docs.bats` (+15) — Phase 3+4+5 docs invariants: ICMP entry present in both languages, oper-table row count parity, README cheat sheet contains the `--psk` example, FAQ Shadowrocket entry present in both languages, RU README strictly links to `ADVANCED.md#manage-cli-adv`, EN README to `ADVANCED.en.md#manage-cli-adv` (cross-language link-drift guard), anchor `manage-cli-adv` resolvable.

### Compatibility

Fully backwards-compatible. `--yes` is opt-in, default behaviour unchanged. Backup ms-suffix is designed to coexist with legacy filenames. Downgrading to v5.11.2 is safe.

### Dependencies

No new ones. `date +%3N` (milliseconds) — standard GNU coreutils, available out of the box on Ubuntu/Debian.

---

## [5.11.2] — 2026-04-24

UX patch on top of v5.11.1. A second per-client QR code — rendered from the `vpn://` URI — for one-tap import into the flagship Amnezia VPN app (Android / iOS / Desktop). The existing `<name>.png` (scan of `.conf`) is unchanged and keeps working with WireGuard-compatible clients (AmneziaWG Windows, `wireguard-apple`, `wg-quick`).

### Added

- **New `generate_qr_vpnuri` helper** in `awg_common.sh` / `awg_common_en.sh`. It reads `/root/awg/<name>.vpnuri` (the URI that `generate_vpn_uri` has been producing for a while now — full Amnezia envelope: zlib-JSON with `containers/defaultContainer/hostName/dns/mtu/protocol_version=2` plus all AWG 2.0 params), pipes it into `qrencode -t png`, writes `/root/awg/<name>.vpnuri.png` with mode 600. Writes are atomic: first into `<name>.vpnuri.png.tmp.$$` in the same directory, `chmod 600`, then `mv -f` to the target path — if `qrencode` or `chmod` fails, the old file stays intact and the orphan `.tmp.*` is cleaned up.
- **Hooked into `generate_client` and `regenerate_client`.** After a successful `generate_vpn_uri`, `generate_qr_vpnuri` runs. If the URI itself cannot be built (missing perl modules, params not loaded), the vpn:// QR is silently skipped. The wg-quick QR and vpn:// QR are independent best-effort artifacts — a failure in one does not prevent the other.
- **Hooked into `manage regen` and `manage remove`.** `regen` now refreshes both QR codes (conf and vpn://) together. `remove` cleans up `<name>.vpnuri.png` alongside `<name>.conf` / `.png` / `.vpnuri` and keys.
- **Backup / restore picks up `.vpnuri.png` automatically** — no new code paths needed: the existing `*.png` glob in `_backup_configs_nolock` and `chmod 600 *.png` in `restore_backup` already cover the new artifact.

### Why

The flagship Amnezia VPN app (Android / iOS / Desktop) supports one-tap import by scanning a QR that encodes `vpn://{base64url(zlib(json))}`. I have been generating that URI for a while, but only as a plain text `.vpnuri` file that users had to copy over manually. Now you can point the phone camera at the second QR code instead of copying a file. The first QR (from `.conf`) remains the right one for classic WireGuard clients.

### Tests

- **+10 new bats** (261 total, up from 251 on v5.11.1):
  - `test_qr_vpnuri.bats` (+10) — happy path (stdin → PNG), missing `.vpnuri` → error, `qrencode` non-zero exit → error, **atomic write** (pre-existing `.vpnuri.png` is preserved on failure, no orphan `.tmp.*` left behind), `chmod 600` on Linux/Darwin, RU/EN structural parity of the helper (qrencode call + `.vpnuri.png` target + `command -v` guard), hooks in `generate_client` / `regenerate_client` / manage regen / cleanup in manage remove.

### Breaking changes

None. Existing client `.conf` / `.png` / `.vpnuri` files keep working. The new `.vpnuri.png` is only generated for clients created or regenerated on v5.11.2 — for older clients, a single `manage regen <name>` is enough. Downgrading to v5.11.1 is safe (stale `.vpnuri.png` files just sit in `/root/awg/` and are ignored).

### Dependencies

No new ones: `qrencode` was already in the installer step-2 required list (used by `generate_qr` for `.conf`), and `perl` + `Compress::Zlib` + `MIME::Base64` — already for `generate_vpn_uri`.

---

## [5.11.1] — 2026-04-23

UX patch. Three small improvements for `manage` on manual (non-installer) setups — e.g. `amneziawg-go` userspace in LXC. Credit to [@Akh-commits](https://github.com/Akh-commits) for the detailed live-test in [Issue #51](https://github.com/bivlked/amneziawg-installer/issues/51) on 2026-04-22, which is where all three fixes came from.

### Fixed / Added

- **`manage add` and `regen` now work without the `server_public.key` cache.** A new `_ensure_server_public_key` helper computes the server public key from the `[Interface]` `PrivateKey` in `awg0.conf` via `awg pubkey` if `/root/awg/server_public.key` is missing (typical for installs made outside my installer — that cache is only populated there). The result is written atomically (tmp + mv) with mode 600. The awk extractor tolerates leading whitespace before `PrivateKey = ` (hand-edited configs).
- **Endpoint fallback chain for egress-restricted setups.** Previously `manage add` inside LXC without access to external IP services died with "Failed to determine server public IP". Now, after `curl` to `ifconfig.me`/`ipify`/`icanhazip`/`ipinfo` fails, I try the first non-loopback IPv4 on a global-scope interface (`ip -4 -o addr show scope global`). The user gets a `log_warn` suggesting they hand-edit `Endpoint` in the client `.conf` if the server sits behind NAT.
- **New `manage add --psk` flag.** Optionally enables `PresharedKey` in the client `.conf` and in the server `[Peer]`. Generates a 32-byte key via `awg genpsk` for every client in batch mode (distinct PSK per client). Off by default — AWG 2.0 obfuscation is sufficient in most scenarios, and PSK is an extra layer for the paranoid or for compatibility with classic WireGuard deployments. Documented in `ADVANCED.md` / `ADVANCED.en.md` manage CLI section.

### Tests

- **+19 new bats** (249 total, up from 230 on v5.11.0):
  - `test_server_pubkey_autogen.bats` (+7) — no-op when cache exists, reconstruct from `awg0.conf`, edge cases (missing file, missing `PrivateKey`, ignore `PrivateKey` in `[Peer]` sections, indented `PrivateKey`, RU/EN parity).
  - `test_endpoint_fallback.bats` (+5) — returns IPv4 on a global-scope interface, empty output when no global scope, skips loopback, picks first of many interfaces, RU/EN parity.
  - `test_psk_flag.bats` (+7) — `PresharedKey` absent without flag, written when `CLIENT_PSK` is set, correct ordering inside `[Peer]` blocks, `CLIENT_PSK="auto"` resolution in `generate_client`, `--psk` parsing in RU+EN manage, help mention.

### Breaking changes

None. All three changes are additive — the existing install flow is unchanged, and without the `--psk` flag `manage add` behaves identically to v5.11.0.

---

## [5.11.0] — 2026-04-22

Robustness bundle — I closed a batch of scenarios where `install` or `manage` could leave the system in a half-configured state on failure: running `install` twice without reboot, a helpers download being interrupted, a kill during `restore`, a failed backup before a destructive `modify`, a race between concurrent `regen` calls. The CI ARM matrix now also ships prebuilt packages for Ubuntu 25.10 and Debian 13. Upgrading is recommended but not required — v5.10.2 remains working, no blocking bugs there.

### Fixed — `install_amneziawg.sh`

- **Running `install` twice without reboot no longer breaks DKMS.** `request_reboot` now saves `/proc/sys/kernel/random/boot_id` to `$AWG_DIR/.boot_id_before_step2` before the step 1→2 reboot. On entry to step 2 the installer compares the saved boot_id against the current one: if they match, the installer dies with "a reboot was expected before step 2". Previously re-running without the reboot attempted to build amneziawg-dkms against the wrong kernel and crashed on vermagic.
- **`setup_state` write is now atomic.** Uses `tmp + flock + mv -f` via a PID-specific tmp path (`${STATE_FILE}.tmp.$BASHPID`). Parallel-invocation scenarios can no longer read a half-written step number.
- **`awg_common.sh` and `manage_amneziawg.sh` download via mktemp + SHA256 + atomic mv.** New helper `_secure_download()`: curl writes to `mktemp`, SHA256 is verified, the verified file is `mv`'d to the target in one step. An interrupted connection no longer leaves a half-written helper in `/root/awg/`. Same pattern applied to the GPG keyring during PPA import.

### Fixed — `manage_amneziawg.sh` + `awg_common.sh`

- **`restore_backup` now rolls back on failure.** Before any destructive operation `restore` creates a pre-restore snapshot (this already existed as an undo aid). In v5.11.0 the snapshot is made known to the function (via `LAST_BACKUP_PATH`) and all error paths are wrapped in `trap _restore_cleanup RETURN`. If anything fails after `systemctl stop`, the cleanup unpacks the snapshot back into place and runs `systemctl start awg-quick@awg0`. A pre-flight `validate_awg_config` check is added before service start — if the restored config does not validate, the service is not started "broken"; rollback kicks in instead. The trap clears its own `RETURN` handler first (`trap - RETURN`) to avoid leaking into subsequent calls.
- **`_backup_configs_nolock` no longer hides cp failures on critical files.** The silent `|| true` is gone. A cp failure on critical artifacts (`awg0.conf`, `awgsetup_cfg.init`, `server_public.key`, `server_private.key`, client `*.conf`, `$KEYS_DIR/*`, `expiry/`, `/etc/cron.d/awg-expiry`) now returns 1 — a corrupted backup is more dangerous than a missing one. Optional artifacts (QR `*.png`, `*.vpnuri`) keep `log_warn` semantics. Empty globs are distinguished from cp failures via a `compgen -G` pre-check.
- **`modify_client` no longer runs a destructive `sed` after a failed backup.** Previously `cp "$cf" "$bak" || log_warn "..."` — a warning in the log, then `sed -i` would destroy the config with no way back. The backup is now a hard gate: `if ! cp ...; then log_error + release lock + return 1`.
- **`regenerate_client` is serialized under a lock and every `sed` is checked.** The function now wraps its body in `.awg_config.lock` (flock, 10 s timeout) — concurrent `regen` calls on the same client name can no longer corrupt the client config. The three `sed -i` statements that restore user settings (DNS, PersistentKeepalive, AllowedIPs) each use `if !` — on failure the function returns 1 and the lock is released. The lock is held only while `.conf` is being mutated; it is released before `generate_qr`/`generate_vpn_uri`, which remain best-effort derived artifacts.
- **`modify_client` flock-timeout no longer leaks the fd.** The "another operation holds the lock" branch now calls `exec {modify_lock_fd}>&-` before `return 1`. Previously the fd stayed open until shell exit.
- **`manage_amneziawg.sh` version is back in sync between RU and EN.** The drifted `5.10.0` / `5.10.1` values converge to `5.11.0`.

### CI / build

- **ARM matrix: Ubuntu 25.10 and Debian 13 added, Ubuntu 22.04 removed.** `.github/workflows/arm-build.yml` now builds the prebuilt `amneziawg.ko` for 7 targets: 3× Raspberry Pi + `ubuntu-2404-arm64` + `ubuntu-2510-arm64` + `debian-bookworm-arm64` + `debian-trixie-arm64`. The matrix matches the installer supported-OS list exactly. `_try_install_prebuilt_arm` in `install_amneziawg.sh` was updated in sync — new branches `*-generic* + 25.10 → ubuntu-2510-arm64` and `*-arm64* + debian + 13 → debian-trixie-arm64`; the dead 22.04 branch is gone.
- **Timeouts on every workflow job.** `shellcheck:10m`, `test:10m`, `release:15m`, `arm-build prepare:5m`, `build:60m`. A hung job no longer quietly burns CI minutes. (Already shipped in the polish PR #55 toward v5.10.2; listed here for completeness.)

### Docs

- **Minimum `awg0.conf` for AWG 2.0 in `ADVANCED.md` / `ADVANCED.en.md`.** A new collapsible section with a ready example for manual setups (`amneziawg-go` in LXC, etc.): all 11 obfuscation parameters (`Jc`/`Jmin`/`Jmax`/`S1`-`S4`/`H1`-`H4`), notes about S3/S4 (added to AWG 2.0 later than S1/S2 — configs carried over from AWG 1.x may not have them), `INT32_MAX` upper bound on H1-H4, `I1` being optional.
- **Explanation of the `#_Name = <name>` marker** inside the "Full List of Management Commands" section — previously implicit in examples only. It is now explicit: `list/remove/regen/modify` rely on this marker in each `[Peer]` block; if you migrate `awg0.conf` from an old server, add `#_Name` by hand.
- **"LXC / Docker via amneziawg-go (userspace)"** section in ADVANCED (source: [@Akh-commits](https://github.com/Akh-commits), [Issue #51](https://github.com/bivlked/amneziawg-installer/issues/51)). A working recipe for a privileged LXC on Proxmox 9 with a Debian 13 guest, security tradeoffs, prebuilt binary vs source build. Shipped to main before the v5.11.0 tag; listing it here for completeness.

### Tests

- **+84 new bats** (230 total, up from 146 on v5.10.2).
  - `test_state_machine.bats` (+18) — atomic `update_state`, `boot_id` guard, step 2 entry die, `request_reboot` capture.
  - `test_manage_robustness.bats` (+24) — `_backup_configs_nolock` contract (`LAST_BACKUP_PATH`, `compgen -G`, critical vs optional), `modify_client` backup gate, `regenerate_client` lock + sed checks, flock-timeout fd release.
  - `test_restore_rollback.bats` (+27) — `_restore_do_rollback` helper, `trap RETURN` + cleanup contract, `_destructive_ops_started` gate, pre-flight `validate_awg_config`, trap/rollback regression guards.
  - `test_arm_matrix.bats` (+15) — matrix-to-installer cross-reference, RU/EN mapping parity, absence of the dropped 22.04 branch.
- **Bonus**: 9 tests whose names contained Unicode em-dash/arrow characters (silently skipped by the bats parser) are now ASCII and actually execute.

### Breaking changes

- None. `restore_backup` externally behaves as before (success → service up; failure → previously partial state, now rollback); the `manage` CLI is unchanged; the `awgsetup_cfg.init` format stays compatible; SHA256 pins for helpers were updated — a downgrade from v5.11.0 back to v5.10.2 is possible by restoring the previous files.

---

## [5.10.2] — 2026-04-20

Urgent hotfix. In v5.10.1 every fresh AmneziaWG 2.0 install died at step 1 with `apt_update_tolerant: command not found` — on all mirrors, not only Hetzner. If you tried v5.10.1 on a new server, or you're about to deploy from scratch, move to v5.10.2. This release also closes an edge case where `apt_update_tolerant` could silently ignore a crash (SIGKILL, OOM).

### Fixed

- **Critical regression in v5.10.1: `apt_update_tolerant: command not found` broke installation.** The function was defined in `awg_common.sh`, but that file is only downloaded at step 5. The first `apt update` at step 1 (before the system upgrade) and the second at step 2 (after adding the PPA) received `command not found`, and installation aborted with `die "apt update error"`. In v5.10.2 the definition moved inline into `install_amneziawg.sh` — next to `log`/`die`, following the existing pattern used for `generate_awg_params`. It has been removed from `awg_common.sh`.
- **Edge case in `apt_update_tolerant`: silent crash / OOM / SIGKILL are no longer masked.** If `apt-get update` returned non-zero WITHOUT classifiable `E:`/`Err:`/`W:` lines in stderr (SIGKILL from OOM-killer, silent crash, unknown output format), the function erroneously returned 0 with a "source packages unavailable" message. Now, before falling back to that branch, the output is checked for explicit source-markers; if none are present, the error is propagated.
- **Regex future-proofing.** The pattern `Sources([[:space:]]|$)` is replaced with `Sources([^[:alpha:]]|$)` — catches future variants like `Sources.xz`, while preventing false-match on strings like `SourcesMirror`.
- **Synced header date in `install_amneziawg_en.sh`** (was `2026-04-16`, now `2026-04-20` to match the release).

### Tests

- **+9 new bats tests** (146 total, was 137).
  - `test_apt_tolerant.bats`: +3 tests — silent crash (rc!=0, empty stderr), DNS failure without `E:` prefix, regex does not match `SourcesMirror`. Function loading migrated from `source awg_common.sh` to `sed` range extraction from `install_amneziawg.sh`.
  - `test_install_defines_apt_tolerant.bats` (new, 6 tests) — regression guard: asserts the invariant "definition is inline in both install scripts, absent from awg_common" + all calls follow the definition line.

---

## [5.10.1] — 2026-04-19

Compatibility with mirrors that don't publish source packages (Hetzner, AWS, and others) — [Discussion #47](https://github.com/bivlked/amneziawg-installer/discussions/47).

### Fixed

- **`apt update` no longer dies on 404 for source packages.** Some mirrors (Hetzner Ubuntu, AWS Ubuntu) don't publish source packages, but the default `/etc/apt/sources.list.d/ubuntu.sources` contains `Types: deb deb-src`. The previous `apt update -y || die` failed in that case. The new `apt_update_tolerant` function (in `awg_common.sh`; moved inline into `install_amneziawg.sh` in v5.10.2) ignores 404s only on `source`/`Sources`/`deb-src`, but propagates every other error (GPG, network, unreachable PPA).
- **Removed modification of `/etc/apt/sources.list.d/ubuntu.sources`.** The installer no longer enables `deb-src` — we never used source packages (kernel module installs via DKMS + binary headers), so the modification was unnecessary and caused the issue.

### Tests

- **+6 new bats tests** (137 total, was 131). `test_apt_tolerant.bats`: clean update, source-only 404, deb-src 404, GPG error, binary 404, mixed errors.

---

## [5.10.0] — 2026-04-16

Mobile network optimization: `--preset=mobile` and `--jc`/`--jmin`/`--jmax` CLI flags, comprehensive security and reliability audit across the entire codebase ([Discussion #38](https://github.com/bivlked/amneziawg-installer/discussions/38), [Issue #42](https://github.com/bivlked/amneziawg-installer/issues/42)).

### Added

- **`--preset=mobile` CLI flag for mobile carriers.** Locks Jc=3 with narrow Jmax (Jmin+20..80) — confirmed working settings for Tele2, Yota, Megafon, Tattelecom and other carriers that block AWG connections with Jc>3 or Jmax>300. `--preset=default` is also available for explicit selection of the standard profile (Jc=3-6, Jmin=40-89, Jmax=Jmin+50..250).
- **`--jc=N`, `--jmin=N`, `--jmax=N` CLI flags.** Fine-grained override of obfuscation parameters on top of any preset. Jc: 1-128, Jmin/Jmax: 0-1280, Jmax must be ≥ Jmin. Example: `--preset=mobile --jc=4` uses the mobile profile but with Jc=4 instead of 3.
- **Protocol boundary validation in `validate_awg_config`.** Checks AWG parameter ranges after backup restore: Jc (1-128), Jmin/Jmax (0-1280, Jmax ≥ Jmin), S3 (0-64), S4 (0-32), H1-H4 range ordering (lower < upper).
- **`AWG_PRESET` saved to configuration.** The selected preset is recorded in `awgsetup_cfg.init` for diagnostics and reproducibility.

### Security

- **Config parser BOM and CRLF hardening.** `safe_load_config` and `safe_read_config_key` now strip BOM (UTF-8 `\xEF\xBB\xBF`) and CR (`\r`) before parsing. Prevents issues when configs are edited in Windows text editors.
- **Special character escaping in `regenerate_client`.** `sed` replacements properly escape `&`, `\`, `/` in values, preventing injection through client keys.
- **GitHub Actions pinned to SHA.** All 7 actions across 4 workflows are pinned to specific commit SHAs instead of mutable tags (supply chain protection).
- **Endpoint masking in diagnostic report.** `generate_diagnostic_report` replaces the server IP address with `***MASKED***` for safe sharing of diagnostic output.
- **File permissions for vpn:// URIs.** `secure_files` and `restore_backup` set `chmod 600` for `.vpnuri` and `.png` (QR code) files.
- **Client name validation in `set_client_expiry`.** Prevents path traversal through client names.
- **Quoted paths in cron file.** `install_expiry_cron` properly quotes paths with spaces.

### Reliability

- **TOCTOU fix in `modify_client`.** Parameter validation moved before lock acquisition, client state checks moved inside the lock. File descriptor is properly closed on all error paths.
- **Correct service restart.** Step 7 now detects an already-running service and uses `enable + restart` instead of a duplicate `awg-quick up`, preventing the "interface already exists" error.
- **I1 stale value fix.** `load_awg_params` clears `AWG_I1` before parsing the server config, preventing CPS parameter contamination from the initial configuration.
- **Forced regeneration with CLI flags.** Re-running with `--preset` or `--jc`/`--jmin`/`--jmax` forces AWG parameter regeneration even when the config already exists.
- **ARM prebuilt step completion.** The prebuilt `.deb` installation path now correctly updates state and requests a reboot, preventing an infinite step-2 loop.
- **Correct regex in `release.yml`.** Dots are now escaped in the version pattern (`5\.10\.0` instead of `5.10.0`).
- **Extended preflight in `build-arm-deb.sh`.** Added `modinfo`, `sha256sum`, `awk`, `xz` checks, kernel detection via `/lib/modules/*/build`, empty `MODULE_VER` guard.

### CI/CD

- **Expanded ShellCheck scope.** Workflow now lints `scripts/*.sh` and `tests/*.bash` in addition to root `.sh` files.
- **Test workflow hygiene.** Added `permissions: contents: read` and `concurrency` group to prevent parallel runs.

### Tests

- **+33 new bats tests** (131 total, up from 98). `test_preset.bats` (18): preset selection, CLI overrides, validation. `test_validate.bats` (+8): protocol boundary checks. `test_safe_load_config.bats` (+4): CRLF, BOM, BOM+CRLF, values with `=`. `test_validate_endpoint.bats` (+3): full IPv6, single-label hostname, empty brackets.

> 📣 **Main features of the 5.x branch** — see the [v5.8.0 release notes](https://github.com/bivlked/amneziawg-installer/releases/tag/v5.8.0). ARM support — see [v5.9.0](https://github.com/bivlked/amneziawg-installer/releases/tag/v5.9.0). v5.10.0 adds mobile network optimization and a comprehensive audit with no breaking changes.

---

## [5.9.0] — 2026-04-15

Raspberry Pi (arm64 and armhf) and ARM64 server support (AWS Graviton, Oracle Ampere, Hetzner arm64). Full implementation by [@pyr0ball](https://github.com/pyr0ball) ([PR #43](https://github.com/bivlked/amneziawg-installer/pull/43), [Issue #37](https://github.com/bivlked/amneziawg-installer/issues/37)).

### Added

- **Prebuilt kernel modules for ARM.** A new GitHub Actions workflow (`.github/workflows/arm-build.yml`) builds `amneziawg.ko` for 6 ARM targets via QEMU on every `v*` tag push. Targets: `rpi-bookworm-arm64` (Raspberry Pi 3/4), `rpi5-bookworm-arm64` (Pi 5 / Cortex-A76), `rpi-bookworm-armhf` (Pi 3/4 32-bit), `ubuntu-2404-arm64`, `ubuntu-2204-arm64`, `debian-bookworm-arm64`. Built `.deb` plus `.sha256` are published to a dedicated `arm-packages` release. Build script (`scripts/build-arm-deb.sh`) can also be run manually on ARM hardware outside CI.
- **Automatic install path selection on ARM.** On `aarch64`/`armv7l`, step 2 first tries the prebuilt `.deb` from the `arm-packages` release (kernel vermagic must match exactly) and falls back to DKMS silently if it does not. Curl uses `--max-time 60` to avoid hangs; SHA256 is verified before `dpkg -i`. Saves time and RAM on minimal systems without build tools.
- **Correct kernel headers detection for Raspberry Pi.** RPi Foundation kernels (`+rpt`/`-rpi` suffix) now pick `linux-headers-rpi-v8` or `linux-headers-rpi-2712` instead of the non-existent `linux-headers-arm64`. `amneziawg-tools` (userspace) on ARM is already shipped by the PPA for arm64/armhf — no separate build needed.
- **Bats tests for header selection.** `tests/test_rpi_headers.bats` — 6 cases: `+rpt-rpi-v8` → `rpi-v8`, `+rpt-rpi-2712` → `rpi-2712`, legacy `-rpi-v8`, mainline arm64 Debian, amd64, generic Ubuntu kernel.

### Tests

- **x86_64 regression** on a clean Ubuntu 24.04 LTS, kernel 6.8.0-110-generic: DKMS build, module load, `awg show`, `manage add/list/backup`, uninstall — all unchanged. The ARM path is skipped correctly on x86_64, `_try_install_prebuilt_arm` is not invoked.
- **ARM end-to-end** on a Raspberry Pi 4 / Debian 12 / kernel `6.12.75+rpt-rpi-v8` (DKMS path, prebuilts not published at PR time): full install lifecycle, `awg-quick@awg0` active, vermagic matches.

### Out of scope for this release

- OpenWrt — separate package ecosystem, needs the OpenWrt SDK
- Auto-tracking kernel updates / broken-package detection
- Armbian and other SBC vendor kernels (follow-up)

> 📣 **Main release notes for the 5.x branch** — see the [v5.8.0 release notes](https://github.com/bivlked/amneziawg-installer/releases/tag/v5.8.0). v5.9.0 is a minor bump adding ARM support with no breaking changes for existing x86_64 installs.

---

## [5.8.4] — 2026-04-13

Reliability and security hardening following a review of the installer and management script.

### Security

- **Extended file type check in `restore_backup`.** The verbose archive listing (`tar -tvzf`) now checks the type of each entry by its first character. Archives containing block devices (`b`), character devices (`c`), FIFOs (`p`), hardlinks (`h`), or symlinks (`l`) are rejected before extraction. The `--no-same-permissions` flag is also added to the extract step so file permissions are always derived from the process umask, never from archive metadata. Protects against crafted archives that bypassed the path checks introduced in v5.8.3.
- **IPv4 octet range validation in `validate_endpoint`.** Previously the regex accepted `999.0.0.1` as a "valid" IPv4 address because `[0-9]{1,3}` did not check the numeric value. A second pass via `BASH_REMATCH` now verifies each octet is in the 0-255 range. `validate_endpoint "256.0.0.1"` and `validate_endpoint "999.999.999.999"` now correctly return 1.
- **`restore_backup` — abort on first copy error.** All five critical `cp -a` operations (server/, clients/, keys/, server_private.key, server_public.key) are now explicitly checked. On failure both locks are released and the function returns 1 immediately with a message identifying which file failed. Prevents a half-restored configuration from being left in place.

### Reliability

- **File locks in `backup_configs` and `restore_backup`.** `backup_configs()` now acquires `.awg_backup.lock` (30 s timeout) before creating the archive. `restore_backup()` acquires `.awg_backup.lock` (outer) and `.awg_config.lock` (inner, 30 s) before extraction. Lock ordering is fixed (backup → config), deadlock is impossible. If `manage backup` and `manage restore` run concurrently the second process waits or exits with a clear diagnostic.
- **Self-deadlock prevention in `restore_backup`.** Before this fix `restore_backup()` called `backup_configs()` for its safety snapshot — both tried to acquire `.awg_backup.lock` → deadlock. An internal `_backup_configs_nolock()` helper was extracted; `restore_backup()` calls it inside its own locked scope. `backup_configs()` (the public entry point) keeps its own lock acquisition.
- **UFW exit code checks in `setup_improved_firewall`.** Every `ufw` command (default deny/allow, limit SSH, allow VPN port, route rule) on both branches (inactive and active) now checks the exit code. Accumulated errors cause `return 1`. Previously a single UFW rule failure did not abort firewall setup.
- **SHA256 bypass logged at WARN level.** When starting with a custom `AWG_BRANCH` (used during branch testing) the SHA256 check is skipped. This was previously logged at `log_debug`, invisible in normal output. Now it logs at `log_warn` so developers can see that integrity was not verified.

### Tests

- **+7 new bats tests.** `test_validate_endpoint.bats` +4: reject `999.999.999.999`, `256.1.1.1`; accept `255.255.255.255`, `0.0.0.0`. `test_restore_backup.bats` +1: real archive + mock tar injecting a block device entry → type-check rejects (proper negative test with real archive creation). `test_apply_config.bats` +2: flock timeout returns 1; systemctl restart failure returns non-zero. Total: **92 bats tests**, all PASS.

> 📣 **The main release notes bundle for the 5.8.x branch** lives in [v5.8.0 release notes](https://github.com/bivlked/amneziawg-installer/releases/tag/v5.8.0). v5.8.4 is a hardening patch on top of 5.8.3 with no breaking changes.

---

## [5.8.3] — 2026-04-11

A batch of hardening fixes and targeted improvements following [Issue #42](https://github.com/bivlked/amneziawg-installer/issues/42) and an internal audit.

### Security

- **Downloaded script integrity check (SHA256).** `install_amneziawg.sh` in step 5 now computes `sha256sum` for `awg_common.sh` and `manage_amneziawg.sh` right after `curl` and compares the result to hardcoded values updated at each release. On mismatch the installer aborts. Protects against tampering on an intermediate hop or a compromise of raw.githubusercontent.com. Verification is automatically skipped when `AWG_BRANCH` is overridden by the user for testing a custom branch.
- **Tar archive validation before extraction in `restore_backup`.** Before extraction the script reads the file list via `tar -tzf` and rejects the archive if it contains absolute paths (`/etc/...`) or path traversal (`..`). After extraction it scans the unpacked tree for symlinks and rejects the archive if any are found. Plus `tar -xzf --no-same-owner` to guarantee extracted files are owned by root rather than by metadata inside the archive. Protects against crafted or tampered backups.

### Fixed

- **Mobile internet — Yota/Tele2 blocked VPN ([Issue #42](https://github.com/bivlked/amneziawg-installer/issues/42)).** Reported by @markmokrenko: after a standard install the VPN fails to connect on Yota and Tele2, while Beeline works. Root cause: `Jmin`/`Jmax` values. This continues the Discussion #38 story — mobile carriers are sensitive to junk packet size. Lowered the `Jmax` offset from `Jmin+100..500` to `Jmin+50..250`, the maximum junk packet size drops from ~590 to ~340 bytes. Obfuscation strength is preserved, mobile compatibility improves.

### Tests

- **4 new bats tests** for `restore_backup` tar validation: happy path (good backup), absolute path rejection, path traversal rejection, server key `chmod 600`. Total: **85 bats tests**, all PASS.

### Live VPS tests

The release was validated on a clean Ubuntu 24.04 LTS: 13/13 checks passed. Tar validation was tested against three attack types — path traversal, absolute paths, symlinks. The SHA256 verify_sha256 function was tested with both correct and incorrect hash inputs. UFW routing cleanup during `--uninstall` was confirmed.

> 📣 **The main release notes bundle for the 5.8.x branch** lives in [v5.8.0 release notes](https://github.com/bivlked/amneziawg-installer/releases/tag/v5.8.0). v5.8.3 is a hotfix on top of 5.8.2 with security hardening and a narrower Jmax range for mobile networks.

---

## [5.8.2] — 2026-04-10

### Fixed

- **Hoster VNC console breaks, network drops on Hetzner (Discussion #41):** `rp_filter` lowered from `1` (strict) to `2` (loose). Strict mode broke routing on cloud hosters (Hetzner and similar) where the gateway is in a different subnet. Added `kernel.printk = 3 4 1 3` to suppress kernel warning messages in the VNC console. Thanks @z036.
- **`--uninstall` now correctly removes UFW routing rules:** added `out on <nic>` to the delete command — UFW requires an exact match with the rule that was created during install.
- **Default `Jc` lowered from 4-8 to 3-6 (Discussion #38):** mobile networks (LTE/5G) do not tolerate large amounts of junk packets well. @elvaleto confirmed that `Jc=3` works reliably on Tattelecom (Letai).

### Documentation

- **ADVANCED.md/en FAQ:** added 2 new entries — Jc/I1 recommendation for mobile networks and workaround for the VNC/Hetzner rp_filter issue. Parameter table updated: `Jc` range `4-8 → 3-6`.

---

## [5.8.1] — 2026-04-09

Targeted hotfix on top of v5.8.0 following [Discussion #40](https://github.com/bivlked/amneziawg-installer/discussions/40) from @z036: the randomized H1-H4 values from v5.8.0 could fall into the `[2^31, 2^32-1]` range, which the `amneziawg-windows-client` config editor underlines as invalid and refuses to save. The server (amneziawg-go) accepts the full `uint32`; the issue is purely in the client-side UI validator.

### Fixed

- **H1-H4 Windows client compatibility ([Discussion #40](https://github.com/bivlked/amneziawg-installer/discussions/40)):** `generate_awg_h_ranges` now caps the upper bound at `2^31-1 = 2147483647` instead of the full `uint32`. This matches `isValidHField()` in [amnezia-vpn/amneziawg-windows-client#85](https://github.com/amnezia-vpn/amneziawg-windows-client/issues/85) (upstream bug, open since February 2026, not yet fixed). Implementation: a `0x7FFFFFFF` bit mask is applied to the `od -N32 -tu4 /dev/urandom` output, and the fallback path now uses `rand_range 0 2147483647`. No bias is introduced — each lower bit stays independent. Obfuscation strength is not weakened: four non-overlapping pairs in `[0, 2^31)` with a minimum width of 1000 each still give an astronomically large key space, DPI cannot fingerprint by default values. Thanks @z036 for the precise screenshot with the underlined fields.

### Compatibility

- **Existing v5.8.0 installs continue to work on the server side.** `amneziawg-go` accepts the full `uint32`, handshake with clients is not affected. The only inconvenience is that `amneziawg-windows-client`'s config editor underlines H2-H4 in red if they happen to land in the upper half of the range (~99.6% of fresh v5.8.0 installs). The cross-platform `amnezia-client` (Qt, Android/iOS/Desktop) does not have this limit.
- **Upgrading from v5.8.0 is recommended** if you use `amneziawg-windows-client`: run `sudo bash /root/awg/install_amneziawg.sh --uninstall --yes`, then install v5.8.1 fresh. New H1-H4 values will land in the safe half of the range.
- **Algorithm and config format are unchanged**, only the generation space is narrower. No breaking changes for the server or existing client `.conf` files.

### Tests

- `tests/test_h_ranges.bats` updated: upper-bound check changed from `2^32-1` to `2^31-1`, plus a new regression test running the generator 20 times × 8 values (160 samples) and asserting every value is ≤ 2147483647. Total: **81 bats tests** (+1 from 5.8.0).

### Documentation

- **ADVANCED.md/en FAQ**: added an entry about the upstream `amneziawg-windows-client` bug with a root-cause explanation, links to upstream issue #85 and Discussion #40, and three workaround options for v5.8.0 users.

> 📣 **The main release notes bundle for the 5.8.x branch** lives in [v5.8.0 release notes](https://github.com/bivlked/amneziawg-installer/releases/tag/v5.8.0). That is where the full Discussion #38 (Russian DPI fingerprinting) context and the multi-round code-audit story lives. v5.8.1 is a hotfix on top of 5.8.0, recommended for everyone using the Windows client.

---

## [5.8.0] — 2026-04-07

Major security and reliability update after several consecutive code audits. The reason for a minor bump instead of a patch release is the significant volume of breaking-semantics changes in config handling, parameter source of truth, and error propagation.

### Security

- **Russian DPI fingerprinting via static H1-H4 (Discussion #38):** The H1-H4 ranges in `generate_awg_params` were hardcoded identically across all installs (`100000-800000`, `1000000-8000000`, ...). Russian DPI fingerprinted this static signature — installs stopped working over Russian mobile carriers. H1-H4 are now randomized per install: 8 random uint32 values are sorted and grouped into 4 non-overlapping pairs. Every install gets unique ranges with no static signature. Thanks @Klavishnik (report) and @elvaleto (diagnosis).

- **Split-brain prevention in `load_awg_params`:** When the live `awg0.conf` exists, it is now the SOLE source of truth for AWG protocol parameters. A partially corrupt live config (for example, a missing H4 field) produces an explicit error with return 1 instead of silently falling back to stale values from the init file. This closes a class of split-brain bugs where the server runs one config while `regen` would issue clients a different set of J*/S*/H*.

- **Atomic export in `load_awg_params_from_server_conf`:** The parser no longer exports `AWG_*` variables as it finds each field. It now either reads all 11 required fields successfully and exports them, or the environment is not modified at all. Protects against mixed state when `awg0.conf` is partially corrupt.

- **`restore_backup` forces `chmod 600` on restored server keys** instead of inheriting the mode from the archive via `cp -a`. Protects against restoring keys with broken permissions if the backup was created with a bad umask.

- **`--uninstall` no longer disables UFW globally** (HIGH severity, audit). Previously `ufw --force disable` wiped the entire firewall on a VPS where UFW was used for SSH/web hardening before our script was installed. The installer now writes a marker `.ufw_enabled_by_installer` only if UFW was inactive before installation, and uninstall disables UFW only when that marker is present. Backwards compat: older installs without the marker get safer-by-default — UFW stays active.

- **Process-wide install lock** (audit). Two concurrent `install_amneziawg.sh --yes` runs could read the same `setup_state`, race each other on `apt-get` and corrupt package state. `flock -n` on `$AWG_DIR/.install.lock` is now taken at the start of main() for the entire process lifetime — a second instance gets `die "Another installer is already running"`.

- **`--endpoint` validation** (audit). Previously the value was accepted verbatim and written to init and client.conf without any sanity check. Newlines or quotes in the endpoint could smuggle extra directives into configs. A new `validate_endpoint()` function rejects newlines, CR, quotes, backslashes, and requires FQDN / IPv4 / `[IPv6]` format.

### Fixed

- **`regen` did not update AWG parameters in client configs (#38):** `load_awg_params` only read AWG parameters from the cached `/root/awg/awgsetup_cfg.init`, not from the live `/etc/amnezia/amneziawg/awg0.conf`. If a user manually edited `awg0.conf` (for example, to change obfuscation parameters), `regen` produced client configs with stale values. `load_awg_params` now reads the live server config first, with the init file used only as a bootstrap fallback on first install. Added new function `load_awg_params_from_server_conf`.

- **`manage add/remove` ignored `apply_config` exit code** (audit). On apply_config failure the commands still logged "Configuration applied" and returned success — the user saw "OK" while the peer was applied only to the config file, not to the live interface. The caller now checks the return code, logs an actionable error pointing at `systemctl status`, and sets `_cmd_rc=1`.

- **`check_expired_clients` left peers on the live interface on apply failure** (audit). If apply_config failed after expired peers were removed from state files, the peer vanished from `expiry/` but remained active on the interface until a manual restart. Permanent stuck state. The function now checks the return code and returns 1 with an actionable message.

- **`--uninstall` removed `/etc/fail2ban/jail.local` by heuristic** (audit). Previously the entire file was deleted if it contained `banaction = ufw` — too broad a filter, could wipe an unrelated `jail.local` with custom jails. The removal block has been dropped entirely, leaving only `rm -f /etc/fail2ban/jail.d/amneziawg.conf` (our own artefact).

- **`check_server` did not check `awg show` exit code** (audit). Could report "State OK" even when `awg` itself crashed. The command is now captured and its exit code verified.

- **`backup_configs`/`restore_backup` leaked temp directories on SIGINT** (audit). `mktemp -d` was used directly, while the `_awg_cleanup` trap only removed files. A new `manage_mktempdir` helper registers the dir in an array and chains cleanup properly.

- **`add_peer_to_server` now takes an inner flock** to protect against direct calls outside `generate_client` (defense-in-depth, self-audit). The "caller must hold the lock" contract was fragile.

- **`check_expired_clients` validates the client name** before using it in paths (defense-in-depth, self-audit). Previously `name=$(basename "$efile")` was used without validation.

- **Backup file names no longer contain colons**: `%F_%T` → `%F_%H-%M-%S`. Colons are incompatible with FAT/NTFS when copying backups to another medium.

- **`apply_config` has an explicit `return 0` on the success path** — removes exit-code ambiguity from `exec {fd}>&-`.

### Optimizations

- **`generate_awg_h_ranges` does a single `/dev/urandom` read** instead of 8 `rand_range` subprocess calls. `od -An -N32 -tu4 /dev/urandom` reads 32 bytes = 8 uint32 values in one operation. Falls back to `rand_range` if `/dev/urandom` is unavailable.

### Tests

- **80 bats tests** (+34 from the 5.7.12 baseline of 46 tests):
  - `test_h_ranges.bats` — 9 H1-H4 generation checks
  - `test_load_awg_params.bats` — 14 awg0.conf parser, init-file priority, split-brain prevention, atomic export, bootstrap path checks
  - `test_validate_endpoint.bats` — 14 validate_endpoint checks (valid FQDN/IPv4/IPv6, reject newline/CR/quotes/space/backslash/empty)
- All 46 existing tests (apply_config, IP allocation, parse_duration, peer management, safe_load_config, validate) still pass without regressions.

### Documentation

- **ADVANCED.md/en FAQ**: added workflow "Rotating obfuscation parameters when DPI detects them" — how to edit `awg0.conf` + restart + regen, noting that as of 5.8.0 regen reads the live config.

---

## [5.7.12] — 2026-04-06

### Fixed

- **Fail2Ban on Debian (Discussion #39):** On Debian 12/13 rsyslog is not installed — fail2ban crashed without `/var/log/auth.log`. Added `backend = systemd` and `python3-systemd` package for Debian. Ubuntu continues using `backend = auto`.

---

## [5.7.11] — 2026-03-31

### Fixed

- **regen corrupts Address on Debian/mawk (#31):** `\s` in awk (PCRE extension) not supported by mawk. Replaced with `[ \t]`. Also replaced `grep -oP` with POSIX-compatible `sed` for private key extraction.
- **regen loses values after modify (#31):** User settings (DNS, PersistentKeepalive, AllowedIPs) changed via `modify` are now preserved during config regeneration.
- **modify leaves .bak files (#31):** Backup file is now deleted after successful parameter change.
- **check fails to detect port on Debian (#31):** `grep -qP` replaced with POSIX-compatible `grep` in all 6 port-checking locations.

---

## [5.7.10] — 2026-03-31

### Added

- **Batch remove clients (#30):** `manage remove client1 client2 client3` — remove multiple clients in one command with a single apply_config at the end.
- **AWG_SKIP_APPLY=1 (#30):** Environment variable to skip apply_config entirely. Allows accumulating changes and applying once — for automation and API integrations. Correct "Apply deferred" message instead of "Configuration applied".
- **flock in apply_config (#30):** Inter-process lock (`${AWG_DIR}/.awg_apply.lock`) prevents concurrent restart/syncconf calls.
- **Unit tests (bats-core):** 43 tests for awg_common.sh — parse_duration, safe_load_config, IP allocation, peer management, apply_config modes, validate. CI workflow `.github/workflows/test.yml`.

---

## [5.7.9] — 2026-03-25

### Added

- **Config apply mode (#30):** New `--apply-mode=restart` option for `manage_amneziawg.sh`. Switches to full service restart instead of `awg syncconf` — bypasses upstream deadlock in amneziawg kernel module ([amneziawg-linux-kernel-module#146](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/issues/146)). Persists via `AWG_APPLY_MODE=restart` in `awgsetup_cfg.init`.

---

## [5.7.8] — 2026-03-24

### Added

- **Batch add clients (#29):** `manage add client1 client2 client3 ...` — create multiple clients in one command. `awg syncconf` is called once at the end instead of N times. Prevents kernel panic during mass client creation (upstream bug [amneziawg-linux-kernel-module#146](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/issues/146)).

---

## [5.7.7] — 2026-03-24

### Fixed

- **Peer loss on reinstall:** `render_server_config` overwrote `awg0.conf` from scratch. Existing `[Peer]` blocks are now automatically restored from backup when step 6 re-runs.
- **Race condition when adding clients (TOCTOU):** `get_next_client_ip` and `add_peer_to_server` now execute in a single critical section (`flock` in `generate_client`). Two parallel `add` operations can no longer pick the same IP.
- **Silent restore success on failure:** `restore_backup` now returns non-zero exit code when file copy errors occur, instead of silently reporting success.
- **Config parser double quote support:** `safe_load_config` now correctly handles double-quoted values (`"value"`) in addition to single quotes.

---

## [5.7.6] — 2026-03-24

### Fixed

- **UFW blocks VPN traffic (Discussion #28):** Added `ufw route allow in on awg0 out on <nic>` rule during firewall setup. Previously, the default `deny (routed)` policy blocked forwarded packets from awg0 to the main interface, despite PostUp iptables rules. The rule is automatically removed on uninstall.
- **PostUp FORWARD ordering:** Changed `iptables -A FORWARD` to `iptables -I FORWARD` to insert the rule at the top of the chain. Ensures correct routing when UFW is absent (`--no-tweaks`).

---

## [5.7.5] — 2026-03-20

### Fixed

- **Trailing newlines in awg0.conf (#27):** Multiple blank lines accumulated in the server config after peer removals. Added normalization via `cat -s` on each remove.
- **Timeout for awg syncconf (#27):** `awg-quick strip` and `awg syncconf` are now called with `timeout 10`. On hang (upstream deadlock [amneziawg-linux-kernel-module#146](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/issues/146)), the script falls back to a full service restart instead of waiting indefinitely.

---

## [5.7.4] — 2026-03-20

### Fixed

- **MTU 1280 by default (Closes #26):** Server and client configs now include `MTU = 1280`. Fixes smartphone connectivity over cellular networks and on iPhone.
- **Jmax cap:** Maximum junk packet size capped at `Jmin+500` (was `Jmin+999`). Prevents fragmentation with MTU 1280.
- **validate_subnet:** Last subnet octet must be 1 (server address). Previously allowed arbitrary values, causing conflicts with `get_next_client_ip`.
- **awg show dump parsing:** Interface line skipped via `tail -n +2` instead of unreliable empty psk field check.
- **manage help without AWG:** `help` and empty command show usage before `check_dependencies`, allowing `--help` without AWG installed.
- **help text:** Installer help now lists all 4 supported OS (Ubuntu 24.04/25.10, Debian 12/13).
- **manage --expires help:** Added `4w` format to `--expires` help text (already supported by parser, but missing from help).

### Improved

- **IP caching:** `get_server_public_ip()` caches the result — repeated calls (add/regen) skip external service requests.
- **O(N) IP lookup:** `get_next_client_ip()` uses an associative array for free IP lookup instead of O(N²) nested loops.

### Documentation

- Fixed client compatibility table: `amneziawg-windows-client >= 2.0.0` supports AWG 2.0 (previously incorrectly listed as AWG 1.x only).
- Fixed APT format for Ubuntu 24.04: DEB822 `.sources` (was `.list`).
- Fixed `restore` example in migration FAQ: correct path `/root/awg/backups/`.
- Fixed uninstall reference in EN README FAQ: `install_amneziawg_en.sh`.
- Added Ubuntu 25.10 to the "Which hosting?" FAQ answer.
- Updated config examples: added `MTU = 1280`.
- Updated Jmax range in parameters table: `+500` instead of `+999`.
- Rewrote MTU section: automatic for v5.7.4+, manual workaround for older versions.
- Removed "MTU not set" from Known Limitations.
- Updated "How to change MTU?" FAQ for automatic MTU.

---

## [5.7.3] — 2026-03-18

### Fixed

- **Uninstall SSH lockout:** UFW is now disabled BEFORE fail2ban unban — prevents SSH lockout if the connection drops during uninstall.
- **CIDR validation (strict):** Invalid CIDR in `--route-custom` now calls `die()` in CLI mode. In interactive mode — retry prompt. Previously, installation continued with invalid AllowedIPs.
- **validate_subnet .0/.255:** Subnets with last octet 0 (network address) or 255 (broadcast) are now rejected.
- **ALLOWED_IPS resume:** Custom CIDR values (mode=3) are now validated when resuming installation from saved config.
- **modify sed mismatch:** Synchronized sed pattern with grep in `modify_client()` — handles .conf files with any whitespace formatting around `=`. Added post-replacement verification.
- **--no-color ANSI leak:** Fixed ESC code `\033[0m` leaking into `list --no-color` output.
- **Uninstall wildcard cleanup:** Removed meaningless wildcard patterns from uninstall — `*amneziawg*` files in `/etc/cron.d/` and `/usr/local/bin/` were never created.

### Documentation

- Added AmneziaWG for Windows 2.0.0 as a supported client.
- Removed misleading note about curl requirement on Debian.

---

## [5.7.2] — 2026-03-16

### Security

- **safe_load_config():** Replaced `source` with a whitelist config parser in `awg_common.sh` — only permitted keys (AWG_*, OS_*, DISABLE_IPV6, etc.) are loaded from the file. Eliminates potential code injection via `awgsetup_cfg.init`.
- **Supply chain pinning:** Script download URLs are pinned to the version tag (`AWG_BRANCH=v${SCRIPT_VERSION}`) instead of `main`. The `AWG_BRANCH` variable can be overridden for development.
- **HTTPS for IP detection:** `get_server_public_ip()` uses HTTPS instead of HTTP for external IP detection.

### Fixed

- **modify allowlist:** Removed Address and MTU from allowed `modify` parameters — these are managed by the installer and should not be changed manually.
- **flock for add/remove peer:** Peer addition and removal operations are protected with `flock -x` to prevent race conditions during parallel invocations.
- **cron expiry env:** Expiry cron job explicitly sets PATH and uses `--conf-dir` for correct operation in minimal cron environments.
- **log_warn for malformed expiry:** Malformed expiry files are handled via `log_warn` instead of being silently skipped.
- **Dead code:** Removed unused functions and variables from `awg_common.sh`.

### Changed

- **list_clients O(N):** Optimized `list_clients` — single-pass algorithm instead of O(N*M).
- **backup/restore:** Backups now include client expiry data (`expiry/`) and cron job.
- **Version:** 5.7.1 → 5.7.2 across all scripts.

---

## [5.7.1] — 2026-03-13

### Fixed

- **vpn:// URI AllowedIPs:** `generate_vpn_uri()` was hardcoding `0.0.0.0/0` instead of using actual AllowedIPs from client config — split-tunnel configurations are now correctly passed to the URI.
- **Fail2Ban jail.d:** Installation now writes to `/etc/fail2ban/jail.d/amneziawg.conf` instead of overwriting `jail.local` — user Fail2Ban customizations are preserved.
- **Fail2Ban uninstall:** Uninstall now removes only its own artifacts instead of `rm -rf /etc/fail2ban/`.
- **validate_client_name:** Client name validation added to `remove` and `modify` commands — previously only worked for `add` and `regen`.
- **exit code:** Management script now returns proper error codes instead of unconditional `exit 0`.
- **expiry cron path:** Expiry cron job uses `$AWG_DIR` instead of hardcoded `/root/awg/`.

### Removed

- **rand_range():** Removed unused function from `awg_common.sh` (installer defines its own copy).

---

## [5.7.0] — 2026-03-13

### Added

- **syncconf:** `add` and `remove` commands now auto-apply changes via `awg syncconf` — zero-downtime, no active connection drops (#19).
- **apply_config():** New function in `awg_common.sh` — applies config via `awg syncconf` with fallback to full restart.
- **--no-tweaks:** Installer flag — skips hardening (UFW, Fail2Ban, sysctl tweaks, cleanup) for advanced users with pre-configured servers (#21).
- **setup_minimal_sysctl():** Minimal sysctl configuration for `--no-tweaks` — only `ip_forward` and IPv6 settings.

### Fixed

- **trap conflict:** Fixed EXIT handler being overwritten when sourcing `awg_common.sh`. Each script now owns its trap and chains the library cleanup explicitly.

### Changed

- **Expiry cleanup:** Auto-removal of expired clients now uses `syncconf` instead of full restart.
- **Manage help:** Removed manual restart warning after `add`/`remove` (no longer required).
- **Version:** 5.6.0 → 5.7.0 across all scripts.

---

## [5.6.0] — 2026-03-13

### Added

- **stats:** `stats` command — per-client traffic statistics (format_bytes via awk).
- **stats --json:** Machine-readable JSON output for integration and monitoring.
- **--expires:** `--expires=DURATION` flag for `add` — time-limited clients (1h, 12h, 1d, 7d, 30d, 4w).
- **Expiry system:** Auto-removal of expired clients via cron (`/etc/cron.d/awg-expiry`, checks every 5 min).
- **vpn:// URI:** Generation of `.vpnuri` files for one-tap import into Amnezia Client (zlib compression via Perl).
- **Debian 12 (bookworm):** Full support — PPA via codename mapping to focal.
- **Debian 13 (trixie):** Full support — PPA via codename mapping to noble, DEB822 format.
- **linux-headers fallback:** Auto-fallback to `linux-headers-$(dpkg --print-architecture)` on Debian.

### Fixed

- **JSON sanitization:** Safe serialization in JSON output.
- **Numeric quoting:** AWG numeric parameters properly quoted.
- **O(n) stats:** Single-pass stats collection instead of multiple calls.
- **backup filename:** `%F_%T` → `%F_%H%M%S` (removed colons from filename).
- **cron auto-remove:** Cron cleanup when the last expiry client is removed.
- **backups perms:** `chmod 700` after `mkdir` for the backups directory.
- **apt sources location:** Apt sources backup moved to `$AWG_DIR` instead of `sources.list.d`.
- Multiple minor fixes from code review (19 fixes).

### Changed

- **Debian-aware installer:** OS_ID detection, adaptive behavior (cleanup, PPA, headers).
- **Version:** 5.5.1 → 5.6.0 across all scripts.

---

## [5.5.1] — 2026-03-05

### Fixed

- **read -r:** Added `-r` flag to all `read -p` calls (15 places) — prevents `\` from being interpreted as an escape character in user input.
- **curl timeout:** Added `--max-time 60 --retry 2` to script downloads during installation — prevents indefinite hanging on network issues.
- **subnet validation:** Subnet validation now checks each octet ≤ 255 — previously accepted addresses like `999.999.999.999/24`.
- **chmod checks:** Added error checking for `chmod 600` when setting permissions on key files.
- **pipe subshell:** Fixed variable loss in config regeneration loop due to pipe subshell — replaced with here-string.
- **port grep:** Improved port matching precision in `ss -lunp` — replaced `grep ":PORT "` with `grep -P ":PORT\s"` to avoid false matches.
- **sed → bash:** Replaced `sed 's/%/%%/g'` with `${msg//%/%%}` — removed 2 unnecessary subprocesses per log call.
- **cleanup trap:** Added `trap EXIT` for automatic cleanup of installer temp files.

---

## [5.5] — 2026-03-02

### Fixed

- **uninstall:** Uninstall proceeded without confirmation when `/dev/tty` was unavailable (pipe, cron, non-TTY SSH) due to default `confirm="yes"`.
- **uninstall:** Kernel module `amneziawg` remained loaded after uninstall — added `modprobe -r`.
- **uninstall:** Working directory `/root/awg/` was recreated by logging after deletion — moved cleanup to the end.
- **uninstall:** Empty `/etc/fail2ban/` and PPA backup `.bak-*` files remained after uninstall.
- **--no-color:** Reset escape code `\033[0m` was not suppressed with `--no-color` — fixed `color_end` initialization.
- **step99:** Duplicate "Cleaning apt…" message — removed extra `log` call before `cleanup_apt()`.
- **step99:** Lock file `setup_state.lock` was not removed after installation completed.
- **manage:** Inconsistent spelling "удален"/"удалён" — standardized (RU only).

---

## [5.4] — 2026-03-02

### Fixed

- **step5:** `manage_amneziawg.sh` download failure is now fatal (`die`), consistent with `awg_common.sh`.
- **update_state():** `die()` inside flock subshell did not terminate the main process — moved outside.
- **step6:** Server config backup now created *before* `render_server_config`, not after overwrite.
- **cloud-init:** Conservative detection — cloud-init markers checked first to avoid removing it on cloud hosts.
- **restore_backup():** Added non-interactive guard (explicit file path required in automation).
- **Subnet:** Validation now only allows `/24` mask (matches actual IP allocation logic).
- **Version:** Removed stale `v5.1` references in logs/diagnostics; introduced `SCRIPT_VERSION` constant.

---

## [5.3] — 2026-03-02

### Added

- **English scripts:** Full English versions of all three scripts (`install_amneziawg_en.sh`, `manage_amneziawg_en.sh`, `awg_common_en.sh`) with translated messages, help text, and comments.
- **CI:** ShellCheck and `bash -n` checks for English scripts.
- **PR template:** Checklist item for EN/RU version synchronization.
- **CONTRIBUTING.md:** Requirement to synchronize EN/RU when modifying scripts.

---

## [5.2] — 2026-03-02

### Fixed

- **check_server():** Fixed inverted exit code (return 1 on success → return 0).
- **Diagnostics restart/restore:** `systemctl status` output is now correctly captured in the log.
- **restore_backup():** Server config restoration path now uses `$SERVER_CONF_FILE`.

### Changed

- **awg_mktemp():** Activated automatic temp file cleanup via trap EXIT.
- **modify:** Added an allowlist of permitted parameters (DNS, Endpoint, AllowedIPs, Address, PersistentKeepalive, MTU). *(Address and MTU removed in v5.7.2)*
- **Documentation:** Removed incorrect mention of /16 subnet support.
- Removed dead trap code from install_amneziawg.sh.

---

## [5.1] — 2026-03-01

### Fixed

- **CRITICAL:** Command injection via special characters `#`, `&`, `/`, `\` in `modify_client()` — added `escape_sed()` function for escaping.
- **CRITICAL:** Race condition in `update_state()` — added locking via `flock -x`.
- **MEDIUM:** `curl` in `get_server_public_ip()` could receive HTML instead of IP — added `-f` flag (fail on error) and whitespace cleanup.
- **MEDIUM:** `$RANDOM` fallback in `rand_range()` gave max 32767 instead of uint32 — replaced with `(RANDOM<<15|RANDOM)` for 30-bit range.
- **MEDIUM:** Pipe subshell in `check_server()` — replaced with process substitution `< <(...)`.
- **MEDIUM:** Awk script in `remove_peer_from_server()` didn't handle non-standard sections — added handling for any `[...]` blocks.

### Added

- **CI:** GitHub Actions workflow — ShellCheck + `bash -n` on push/PR to main.
- **GitHub:** Issue templates (bug report, feature request) in YAML form format.
- **GitHub:** PR template with checklist (bash -n, shellcheck, VPS test, changelog).
- **SECURITY.md:** Security policy, responsible vulnerability disclosure.
- **CONTRIBUTING.md:** Contributor guide with code and testing requirements.
- **.editorconfig:** Unified formatting settings (UTF-8, LF, indentation).
- **Trap cleanup:** Automatic temp file cleanup via `trap EXIT` + `awg_mktemp()`.
- **Bash version check:** `Bash >= 4.0` check at the start of install and manage scripts.
- **Documentation:** Config examples, Mermaid architecture diagram, extended FAQ, troubleshooting.

### Changed

- **Version:** 5.0 → 5.1 across all scripts and documentation.
- **README.md:** Command table expanded to 10 (+ modify, backup, restore), FAQ expanded to 8 questions.
- **ADVANCED.md:** Added config examples, manage command examples, diagnostics description, update instructions.

---

## [5.0] — 2026-03-01

### ⚠️ Breaking Changes

- **AWG 2.0 protocol** is not compatible with AWG 1.x. All clients must update their configuration.
- Requires **Amnezia VPN >= 4.8.12.7** client with AWG 2.0 support.
- Previous version is available in the [`legacy/v4`](https://github.com/bivlked/amneziawg-installer/tree/legacy/v4) branch.

### Added

- **AWG 2.0:** Full protocol support — parameters H1-H4 (ranges), S1-S4, CPS (I1).
- **Native generation:** All keys and configs generated using Bash + `awg` with no external dependencies.
- **awg_common.sh:** Shared function library for install and manage scripts.
- **Server cleanup:** Automatic removal of unnecessary packages (snapd, modemmanager, networkd-dispatcher, unattended-upgrades, etc.).
- **Hardware-aware optimization:** Automatic swap, network buffer, and sysctl tuning based on server characteristics (RAM, CPU, NIC).
- **NIC optimization:** GRO/GSO/TSO offload disabling for stable VPN tunnel operation.
- **Extended sysctl hardening:** Adaptive network buffers, conntrack, additional protection.
- **Individual client regeneration:** `regen <name>` command for regenerating a single client's configs.
- **AWG 2.0 validation:** Verification of all protocol parameters in the server config.
- **AWG 2.0 diagnostics:** `check` command shows AWG 2.0 parameter status.

### Removed

- **Python/venv/awgcfg.py:** Python dependency and external config generator completely removed.
- **awgcfg.py bug workaround:** Moving `awgsetup_cfg.init` during generation is no longer necessary.
- **Parameters j1-j3, itime:** Legacy AWG 1.x parameters are no longer supported.

### Changed

- **Architecture:** 2 files → 3 files (install + manage + awg_common.sh).
- **Install step 1:** Added system cleanup and optimization.
- **Install step 2:** Installs `qrencode` instead of Python.
- **Install step 5:** Downloads `awg_common.sh` + `manage` (no Python/venv).
- **Install step 6:** Fully native config generation.
- **Key generation:** Native via `awg genkey` / `awg pubkey`.
- **QR codes:** Generated via `qrencode` directly (no Python).
- **Documentation:** README.md and ADVANCED.md updated for AWG 2.0.

---

## [4.0] — 2025-07-15

### Added

- AWG 1.x support (Jc, Jmin, Jmax, S1, S2, H1-H4 fixed values).
- DKMS installation.
- Config generation via Python + awgcfg.py.
- Client management: add, remove, list, regen, modify, backup, restore.
- UFW firewall, Fail2Ban, sysctl hardening.
- Resume-after-reboot support.
- Diagnostic report (`--diagnostic`).
- Full uninstall (`--uninstall`).

[Unreleased]: https://github.com/bivlked/amneziawg-installer/compare/v5.10.2...HEAD
[5.10.2]: https://github.com/bivlked/amneziawg-installer/compare/v5.10.1...v5.10.2
[5.10.1]: https://github.com/bivlked/amneziawg-installer/compare/v5.10.0...v5.10.1
[5.10.0]: https://github.com/bivlked/amneziawg-installer/compare/v5.9.0...v5.10.0
[5.9.0]: https://github.com/bivlked/amneziawg-installer/compare/v5.8.4...v5.9.0
[5.8.4]: https://github.com/bivlked/amneziawg-installer/compare/v5.8.3...v5.8.4
[5.8.3]: https://github.com/bivlked/amneziawg-installer/compare/v5.8.2...v5.8.3
[5.8.2]: https://github.com/bivlked/amneziawg-installer/compare/v5.8.1...v5.8.2
[5.8.1]: https://github.com/bivlked/amneziawg-installer/compare/v5.8.0...v5.8.1
[5.8.0]: https://github.com/bivlked/amneziawg-installer/compare/v5.7.12...v5.8.0
[5.7.12]: https://github.com/bivlked/amneziawg-installer/compare/v5.7.11...v5.7.12
[5.7.11]: https://github.com/bivlked/amneziawg-installer/compare/v5.7.10...v5.7.11
[5.7.10]: https://github.com/bivlked/amneziawg-installer/compare/v5.7.9...v5.7.10
[5.7.9]: https://github.com/bivlked/amneziawg-installer/compare/v5.7.8...v5.7.9
[5.7.8]: https://github.com/bivlked/amneziawg-installer/compare/v5.7.7...v5.7.8
[5.7.7]: https://github.com/bivlked/amneziawg-installer/compare/v5.7.6...v5.7.7
[5.7.6]: https://github.com/bivlked/amneziawg-installer/compare/v5.7.5...v5.7.6
[5.7.5]: https://github.com/bivlked/amneziawg-installer/compare/v5.7.4...v5.7.5
[5.7.4]: https://github.com/bivlked/amneziawg-installer/compare/v5.7.3...v5.7.4
[5.7.3]: https://github.com/bivlked/amneziawg-installer/compare/v5.7.2...v5.7.3
[5.7.2]: https://github.com/bivlked/amneziawg-installer/compare/v5.7.1...v5.7.2
[5.7.1]: https://github.com/bivlked/amneziawg-installer/compare/v5.7.0...v5.7.1
[5.7.0]: https://github.com/bivlked/amneziawg-installer/compare/v5.6.0...v5.7.0
[5.6.0]: https://github.com/bivlked/amneziawg-installer/compare/v5.5.1...v5.6.0
[5.5.1]: https://github.com/bivlked/amneziawg-installer/compare/v5.5...v5.5.1
[5.5]: https://github.com/bivlked/amneziawg-installer/compare/v5.4...v5.5
[5.4]: https://github.com/bivlked/amneziawg-installer/compare/v5.3...v5.4
[5.3]: https://github.com/bivlked/amneziawg-installer/compare/v5.2...v5.3
[5.2]: https://github.com/bivlked/amneziawg-installer/compare/v5.1...v5.2
[5.1]: https://github.com/bivlked/amneziawg-installer/compare/v5.0...v5.1
[5.0]: https://github.com/bivlked/amneziawg-installer/compare/v4.0...v5.0
[4.0]: https://github.com/bivlked/amneziawg-installer/releases/tag/v4.0
