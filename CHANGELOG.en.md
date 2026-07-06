<p align="center">
  <b>RU</b> <a href="CHANGELOG.md">Русский</a> | <b>EN</b> English
</p>

# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

---

## [5.18.4] - 2026-07-06

**v5.18.4** - cascade reliability and documentation. Cascade split-routing now survives ipdeny being unreachable: a snapshot of the Russian network list (`cascade/ru.zone`) is bundled in the repository, and the `awg-routing.sh` script uses it when `www.ipdeny.com` is blocked by the provider and no local copy exists yet - previously a fresh server in that situation would not bring the cascade up at all. The script also gained a workaround for the route error on VPSes whose default gateway sits outside the server subnet (Hetzner Cloud and similar with a `/32` interface). The installer itself is functionally unchanged, so existing installs do not need updating. Support matrix unchanged: Ubuntu 24.04 / 25.10 / 26.04, Debian 12 / 13, x86_64 + ARM.

### Documentation

- Cascade: bundled a snapshot of Russian networks `cascade/ru.zone` (ipdeny aggregated zone, snapshot 2026-07-06, 8626 networks) as a fallback source. The order in `awg-routing.sh` is now: ipdeny (the live list) -> the repo snapshot over `raw.githubusercontent.com` -> the previous local list; it aborts only if all three are unavailable. This brings the cascade up on a fresh server even when ipdeny is blocked (from Discussion #120)
- Cascade: `awg-routing.sh` retries adding the route to the exit server with the `onlink` flag when the default gateway sits outside the server subnet - otherwise on VPSes like Hetzner (real public IP on a `/32` interface, private gateway) the route failed with `Error: Nexthop has invalid gateway` (#158, Discussion #120)
- Added a `cascade/README.md` note for the snapshot (source, date, how to refresh) and an Ask DeepWiki badge in both READMEs for quick code navigation (#161)

### Infrastructure

- CI: bumped `docker/setup-qemu-action` from 4.1 to 4.2 in the ARM package build (#157)

---

## [5.18.3] - 2026-07-02

**v5.18.3** - convenience and documentation. Confirmation prompts (for example, when removing a client or enabling UFW) now accept not only `y` but also `yes` in any case and with stray surrounding whitespace. UFW is enabled more reliably via `ufw --force enable`, so on some systems the firewall is no longer left disabled. The docs gain the T-Mobile (Moscow) mobile carrier and a Keenetic Speedster router note. Existing installs are unaffected. Support matrix unchanged: Ubuntu 24.04 / 25.10 / 26.04, Debian 12 / 13, x86_64 + ARM.

### Fixed

- Confirmation prompts accept `yes`, not only `y`. Previously `confirm_action` (in `manage`) and five installer prompts (reboot, unsupported OS, low disk space, UFW enable, backup on removal) matched a bare `y` only, and answering `yes` read as "no". They now accept `y`/`Y`/`yes`/`YES` with any surrounding whitespace (issue #154)
- UFW is enabled via `ufw --force enable`. The old approach (feeding `y` into `ufw enable`) silently left the firewall off on some systems - only `--force` helped, and the installer now uses it directly (issue #154)

### Documentation

- Added **T-Mobile (Moscow)** to the mobile carrier table: a narrow app-style profile (Jc=6, Jmin=10, Jmax=50 + DNS-mimic I1 + full tunnel); the `diagnose --carrier=tmobile_us` profile checks Jc/Jmin/Jmax and that I1 is binary-shaped (Discussion #45)
- Added a **Keenetic Speedster** (firmware 5.0.6) router note: older firmware does not parse H1-H4 as ranges (`invalid H1`), needs concrete values and calmer junk, with a userspace AWG Manager workaround (Discussion #81)
- Added a diagnostics tip: the ByeByeVPN scanner helps tell whether a carrier blocks the server IP itself, separating an obfuscation issue from an AS/IP-level block

## [5.18.2] - 2026-07-01

**v5.18.2** - installation robustness. On fresh Ubuntu servers the built-in `unattended-upgrades` often holds the `dpkg` lock for several minutes on first boot, which made the installer fail at the system-update step with an `apt full-upgrade` error. The installer now waits for the lock to be released instead of failing immediately. Existing installations are unaffected. Support matrix unchanged: Ubuntu 24.04 / 25.10 / 26.04, Debian 12 / 13, x86_64 + ARM.

### Fixed

- A fresh-server install no longer aborts when the `dpkg` lock is busy. At the start of step 1 the installer sets `DPkg::Lock::Timeout` (via `/etc/apt/apt.conf.d`), so every `apt` call waits for the lock that `unattended-upgrades` / `apt-daily` hold on first boot. If `apt full-upgrade` still does not go through, the installer logs the process holding the lock, runs `dpkg --configure -a` and retries, and on a repeated failure exits with a clear message and recovery steps (issue #150)

## [5.18.1] - 2026-06-27

**v5.18.1** - bug-fix release. Fixes `--port` on reinstall: `install --force --port=N` now actually changes the server port (previously the new port was silently ignored). Full-tunnel clients now get `0.0.0.0/0, ::/0` so AmneziaVPN on iOS accepts the "all traffic" mode. The default DNS is now a resolver pair `1.1.1.1, 1.0.0.1`. `--port` now accepts any port 1-65535, including 443 (useful for mobile carriers that drop a non-standard high UDP port). Plus documentation fixes. Behaviour of existing installs and connected clients is unchanged; the improvements apply to new and re-issued (`manage regen`) configs. Support matrix unchanged: Ubuntu 24.04 / 25.10 / 26.04, Debian 12 / 13, x86_64 + ARM.

### Fixed

- `install --force --port=N` now changes the server port. Previously the new port was silently ignored: when rendering the server config, the port was re-read from the old `awg0.conf`, overwriting the value passed via `--port`. The port for the new config is now taken from the saved install parameters (the user's intent), which correctly survives the reboots during `--force`. Client `regen` is unaffected - it still reads the port from the live `awg0.conf`
- Full-tunnel clients (`AllowedIPs = 0.0.0.0/0`) now get `0.0.0.0/0, ::/0`. With a bare `0.0.0.0/0`, AmneziaVPN on iOS treated the config as incomplete split tunneling and refused to bring the tunnel up. `::/0` sends IPv6 into the tunnel (and drops it if the server has no native IPv6), so nothing leaks past the VPN. Split tunneling (a custom route list) is not affected

### Changed

- The default DNS in client configs is now a pair `1.1.1.1, 1.0.0.1` instead of a single resolver (a fallback DNS in case the first one is unreachable)
- `--port` now accepts ports 1-65535 (previously only 1024-65535). Low ports like 443/80/53 help with DPI evasion on mobile carriers: MTS, for example, drops a non-standard high UDP port but passes 443/udp. The VPN service runs as root, so privileged ports bind fine

### Documentation

- ADVANCED: fixed the `S3`/`S4` range in the minimal-config example (`S3`: 0-64, `S4`: 0-32 instead of the wrong 0-127); removed the stale link of the active-probing section to the already-closed issue #71; added notes on the mobile port and on direct IPv6 traffic bypassing the tunnel
- README: added Ubuntu 26.04 to the subtitle; clarified the `--force` gate in the re-run FAQ

### Tests

- Added `tests/test_v5181_bugfix.bats` - the port from the saved parameters wins over the old `awg0.conf` on render; a full-tunnel client gets `::/0`, a split one does not; the default DNS pair; RU/EN parity of all three fixes

---

## [5.18.0] - 2026-06-26

**v5.18.0** - the special-junk params `I2`-`I5` now reach clients. Previously only `I1` made it into the client config; `I2`-`I5` were hard-coded empty in the `vpn://` URI and never rendered into the `.conf`, so even if the admin set them in `awg0.conf` they could not reach the client. Now all five CPS params are carried into the client `.conf`, the QR code, and the `vpn://` link. Workflow: set `I2`-`I5` in the `[Interface]` of `awg0.conf`, restart the service, and distribute to clients with `manage regen`. No new install flags; when `I2`-`I5` are unset, behavior is identical to before. Support matrix unchanged: Ubuntu 24.04 / 25.10 / 26.04, Debian 12 / 13, x86_64 + ARM (issue #71).

### Added

- Pass-through of `I1`-`I5` (not just `I1`) from the server `awg0.conf` into client configs on generation and `regen`: the live-config parser reads `I2`-`I5`, the client `.conf` render appends the set values, and the previously hard-coded empty `I2`-`I5` in the `vpn://` URI are replaced with the real ones. Values are carried verbatim; the admin picks the tag format (`<r N>`, `<b 0xHEX>`, `<c>`, `<t>`) - see the VoidWaifu list. `I2`-`I5` are optional and independent: unset ones are simply not emitted
- The params inherit the same preservation semantics as the rest of the obfuscation: `--force` without `--preset/--jc/--jmin/--jmax` reads `I2`-`I5` from the live `awg0.conf` and keeps them; `--preset`/`--jc` regenerate the whole obfuscation set, which drops manually set `I2`-`I5` (same as `H1-H4/S1-S4/I1`)

### Tests

- Added `tests/test_v5180_i2i5_passthrough.bats` - parsing `I2`-`I5` from `awg0.conf`, anti-stale protection across calls, client `.conf` render (present when set, absent when empty), and a real `vpn://` decode (values present in both the structured fields and the embedded raw config), plus RU/EN parity of every touched site

---

## [5.17.0] - 2026-06-24

**v5.17.0** - the server firewall now clamps the TCP MSS to the tunnel MTU so large pages and downloads no longer hang on paths that filter ICMP (mobile carriers, double-NAT, two-server cascade). The install behavior is otherwise unchanged; update an existing server by re-running the installer. Support matrix unchanged: Ubuntu 24.04 / 25.10 / 26.04, Debian 12 / 13, x86_64 + ARM.

### Added

- MSS/PMTU clamp in the server config PostUp/PostDown: a `TCPMSS --set-mss` rule in the `mangle` table's `FORWARD` chain caps the advertised TCP MSS to a tunnel-safe value in both directions (`-o %i` and `-i %i`). This removes the PMTU blackhole - when ICMP "Fragmentation needed" is filtered along the path, oversized TCP segments with DF set are silently dropped at the 1280 tunnel and the page or download stalls. A common complaint on mobile carriers, behind double-NAT, and in cascade setups
- The MSS value is derived from `AWG_MTU` when the config is generated (IPv4: MTU-40 = 1240, IPv6: MTU-60 = 1220); a manual MTU change is picked up by re-running the installer with `--force`. IPv6 rules are only added when the IPv6 tunnel is enabled. It complements the existing conservative `MTU = 1280` rather than replacing it

### Tests

- Added `tests/test_v5170_mss_clamp.bats` - asserts the rules in both directions, the mirrored `-D` in PostDown, IPv6 gating, and MSS auto-derivation from `AWG_MTU`

---

## [5.16.1] - 2026-06-16

**v5.16.1** - hotfix: iOS tunnel drop on the default routing mode (Issue #42). The default install behavior is otherwise unchanged. Support matrix unchanged: Ubuntu 24.04 / 25.10 / 26.04, Debian 12 / 13, x86_64 + ARM.

### Fixed

- iOS: on the default routing mode (mode 2, "Amnezia List + DNS") the tunnel came up but traffic stopped after ~10 seconds (easy to mistake for DPI). The AllowedIPs list started with the `0.0.0.0/5` range, which covers the reserved `0.0.0.0/8`; the iOS kernel chokes on that block and never reaches the rest of the routes. The first range is split into `1.0.0.0/8, 2.0.0.0/7, 4.0.0.0/6` - the same coverage without the problematic zero block, and split-tunnel is preserved. Traced and fixed by @LiaNdrY (Issue #42)
- The `--expires` error message now lists `30d` among the valid formats (matching `--help`)

### Documentation

- README and ADVANCED (RU + EN): added an FAQ entry about the iOS drop with instructions for already-installed servers (before v5.16.1)
- Cascade (CASCADE.md / CASCADE.en.md): the client config example now uses this installer's default Endpoint port `39743` (was `51820` from upstream WireGuard); the troubleshooting section no longer references a nonexistent `after-awg1.conf` drop-in - the autostart check now points at the `awg-routing.service` unit; removed a duplicated paragraph in step 1
- Full documentation audit: fixed minor inaccuracies (a duplicated pointer line in ADVANCED.en.md, an install-link anchor mismatch between README RU and EN, the import-files wording in INSTALL_VPS.md)

### CI

- The ShellCheck workflow ("Lint and syntax check") is no longer path-filtered: the required status check now runs on docs-only PRs too, so it no longer blocks them (previously needed an admin override)

### Tests

- Added `tests/test_v5161_ios_allowedips.bats` - a structural guard against the mode-2 list reverting to `0.0.0.0/5`

---

## [5.16.0] - 2026-06-12

**v5.16.0** - security and reliability hardening from a full code audit. This release closes the findings of a full review of all six scripts of the AmneziaWG 2.0 VPN installer for Ubuntu and Debian: it eliminates the peer-loss window on `--force` reinstall, removes secrets from process argv, pins the PPA GPG key by full fingerprint, makes the AWG parameter validator check H1-H4 non-overlap, and stops expired orphan clients from looping the cron job forever. The default install behavior is unchanged. Support matrix unchanged: Ubuntu 24.04 / 25.10 / 26.04, Debian 12 / 13, x86_64 + ARM.

### Security

- The temp-file registry moved from world-writable `/tmp` into `$AWG_DIR` (0700): a predictable name in `/tmp` would let a local user plant a list of arbitrary paths that cleanup would then delete as root; registry reads are additionally guarded against symlink swaps
- Private keys (client and server) are now born with 0600 permissions via `umask 077` - the brief world-readable window between write and `chmod` is gone; the `keys/` directory is created with 0700
- The client private key and PSK are passed to the perl vpn:// URI generator via environment variables instead of argv (a process command line is visible to all users in `/proc/<pid>/cmdline`)
- The Amnezia PPA GPG key is requested by its full 40-character fingerprint instead of the short 32-bit ID (short IDs have known evil32 collisions) and is verified against the pin after download
- `uninstall` no longer purges the `fail2ban` package if it was installed before our installer (the `.fail2ban_installed_by_installer` marker, symmetric to the UFW marker); a user-owned fail2ban is restarted without our jail
- `uninstall` removes only the exact lines written by legacy versions of this installer from `/etc/sysctl.conf` instead of any line containing `disable_ipv6` (it could previously wipe user-added settings)
- Library functions `generate_client` / `add_peer_to_server` / `remove_peer_from_server` / `regenerate_client` now validate the client name themselves (defense-in-depth for cron and third-party scripts sourcing the library)

### Fixed

- Step 6: existing [Peer] blocks are now carried over inside a single atomic write of the server config (`render_server_config` appends peers before the `mv`). Previously a crash between render and the separate append left the config without peers, and a re-run of the step backed up the already peer-less file - all clients were lost on `--force` reinstall
- `remove_peer_from_server` checks the awk exit code and the presence of `[Interface]` in the result before replacing the server config - an awk failure on a full disk can no longer atomically replace a working config with a broken one
- An expired client whose peer was already removed from the config manually or by a restore (an orphan expiry label) is now cleaned up properly: previously cron retried the failing removal every 5 minutes forever and the client artifacts were never reclaimed
- `regen` recovers the PresharedKey from the server config when the client `.conf` is lost - previously the recreated config came out without a PSK while the server peer still had one, silently breaking the handshake
- The public IP detection cache actually works now (file-based, survives subshells): previously the assignment inside `$(...)` was lost, so `regen` over all clients performed a full curl round (up to 6 services, 5 s each) per client
- `validate_awg_config` checks pairwise non-overlap of the H1-H4 ranges (the key AWG 2.0 invariant) and parses parameters the same way the loader does: arbitrary whitespace around `=`, last-wins on duplicates - a hand-edited `Jc=4` no longer produces a false "parameter not found"
- H1-H4 generation guarantees a strict gap between ranges (boundary touching is excluded) and a lower bound >= 5 (values 1-4 are reserved by the WireGuard protocol)
- `--apply-mode` is validated at argument parse time: a typo like `--apply-mode=restrat` used to silently behave as `syncconf`
- `--diagnostic` checks for root before doing anything (previously it failed on every log write under a regular user and exited with a false success)
- Debian 12: the PPA suite-mismatch repair now also covers the traditional `.list` format (previously only DEB822 `.sources` was handled)
- Step 2: the early apt update is now tolerant to Amnezia PPA errors - a leftover PPA file with a broken suite (404 Release) no longer kills the install BEFORE the repair logic runs (live repro on Debian 12); base repository errors remain fatal
- `check`: when the port cannot be determined, the UFW rule check is skipped (previously it printed a meaningless warning about `0/udp`)
- `list`: a corrupted expiry file no longer causes a bash arithmetic error in the table
- `generate_vpn_uri` verifies the port is numeric before generating the URI (an empty port produced syntactically broken JSON that Amnezia Client silently refused to import)
- The public-IP detection error message in `manage add` no longer suggests the `--endpoint` flag that manage does not have

### Improved

- Installer steps 1-2 no longer re-run `apt-get update` without a sources change (saves 10-60 seconds per run on slow mirrors, up to two redundant runs per install)
- `backup` additionally takes the config lock: a parallel `add`/`remove` can no longer produce a desynchronized file set inside the backup
- Interactive port and subnet prompts during install re-ask on a typo instead of aborting the whole installation
- Reinstalling with `--preset`/`--jc`/`--jmin`/`--jmax` prints an explicit warning that the ENTIRE obfuscation parameter set is regenerated and existing client configs will need `regen` (the idempotency-guard message was clarified too)
- `setup_fail2ban` warns when UFW is inactive (bans with `banaction=ufw` are effectively inert in that case)
- The `apt-get update` error classification ignores known informational lines `W: Target ... is configured multiple times` and `W: ... legacy trusted.gpg` - they no longer turn a tolerable failure into a false fatal
- `diagnose` makes one `awg show` call instead of four; `stats` no longer spawns `date` per peer; `list --json` does not read expiry files (the field is not part of the JSON output)
- The expiry cron job runs the temp-file cleanup (fixes a registry-file leak on every firing)
- The random number generator fallback (when `/dev/urandom` is unavailable) covers the full 31-bit range instead of 30 bits
- `manage` help: `regen` documents accepting multiple names, `repair-module` lists its `repair` alias; the client-creation message mentions `.png` only when the QR was actually created
- Dead code removed: the unreachable `help)` dispatcher branch in manage, the unreachable `return` after `request_reboot` in the installer, two redundant `AWG_APPLY_MODE` re-exports, stale shellcheck directives
- CI/release scripts: `update-sha-pins.sh` preserves file permissions on rewrite; `build-arm-deb.sh` surfaces xz stderr on failure; `build-release-notes.sh` validates the version format before interpolating it into awk

---

## [5.15.6] - 2026-06-08

**v5.15.6** - input validation, atomicity and a JSON status field. This release continues the code-audit hardening cycle: it sharpens input validation in `manage`, makes client-artifact writes atomic, refines interrupt handling, and adds a stable machine-readable `status_code` to `list`/`stats --json`. The default install is unchanged. Support matrix unchanged: Ubuntu 24.04 / 25.10 / 26.04, Debian 12 / 13, x86_64 + ARM.

### Added

- `list --json` and `stats --json` now emit an extra `status_code` field with a stable, language-independent value (`active` | `recent` | `inactive` | `no_handshake` | `key_error` | `no_data`). The existing localized `status` field is kept - the change is additive and backward-compatible, and convenient for `jq` and automation (the contract is documented in `ADVANCED.en.md`)

### Improved

- `manage modify <client>` validates each DNS entry as a real IPv4/IPv6 address (via the shared `_valid_ipv4`/`_valid_ipv6` helpers) rather than a character set, so values like `abc` or `999.999.999.999` are no longer accepted. The same octet-range check (0-255) now applies to the auto-detected server public IP
- `--expires` duration is validated once before the client is created: an invalid value aborts the command up front without changing anything. A failure to write the expiry after creation is now reflected in a non-zero result and the log
- `--psk` is treated as an explicit request for a key: if the PSK cannot be generated, the command fails instead of silently degrading to a PSK-less client, and no artifacts are created
- `.vpnuri` and the temporary QR PNGs are written through the shared safe-temp mechanism with an atomic `mv`, so an interrupted write cannot leave an empty or truncated file over a working one. Client removal (manual and automatic on expiry) uses one shared helper that covers every client artifact
- The expired-client auto-removal cron is compared by content and refreshed when the working directory changes (for example after a restore), not only when the file is absent
- Restore checks for the server config before stopping the service (an interruption no longer touches a working system), and an empty clients directory is treated as a valid case
- Ctrl+C or a termination signal now aborts the script with the correct exit code (130/143) instead of continuing past the interrupted operation; an interrupted restore still rolls back

### Documentation

- Installer built-in help and the option tables in `ADVANCED.en.md`: `--endpoint` accepts an FQDN, IPv4 or `[IPv6]`; clarified that `--no-tweaks` still applies the minimal forwarding sysctl
- The command tables in `README.en.md` now include `diagnose` and `repair-module`
- ARM support for Ubuntu 26.04 (built via DKMS) is documented; the OS / architecture / prebuilt-package matrix is now checked automatically for consistency

### Tests

- Expanded automated coverage (bats): input validators, file-operation atomicity, signal handling, and the `status_code` contract

---

## [5.15.5] - 2026-06-07

**v5.15.5** - fail2ban bugfix on Ubuntu 24.04 (thanks @stereomonk).

### Fixed

- fail2ban failed to start on minimal Ubuntu 24.04 without rsyslog ("Have not found any log file for sshd jail"): the sshd jail now uses `backend = systemd` on Ubuntu as well, matching Debian since v5.7.12 (PR #106, thanks @stereomonk)
- fail2ban status after restart is now checked honestly: `systemctl restart` returns 0 even when the service dies right after start, so the installer used to report success on a crashed service. The state is now verified via `systemctl is-active` (PR #106)

---

## [5.15.4] - 2026-06-06

**v5.15.4** - a companion release: a new documentation section on a host being unreachable from Russia (autonomous-system blocking) and the I1/CPS workaround, plus housekeeping. The default install behavior and the support matrix are unchanged.

### Documentation

- **ADVANCED: a new section on host blocking by autonomous system (AS).** It covers the symptom (the handshake completes, then traffic stalls), the AS-level cut on the operator's network, and the workaround via I1/CPS QUIC mimicry with an allowlisted SNI. The section includes field observations across several operators and links to the relevant discussion (Issue #71).

### Internal

- **Two bats test names were converted to ASCII.** The full suite of 790 checks now also runs under bats on Windows (two tests with non-ASCII names were previously skipped there); the Linux CI always ran the full suite.

---

## [5.15.3] - 2026-06-04

**v5.15.3** - a hardening release following four rounds of external code and documentation audits. No new features: it tightens the installer's input validators, fixes a number of correctness issues in `manage`, and hardens file-operation atomicity and the release process. A default install is unchanged. Support matrix unchanged: Ubuntu 24.04 / 25.10 / 26.04, Debian 12 / 13, x86_64 + ARM.

### Fixed

- **Early installer validators now match the canonical ones.** The step-0 checks for port, subnet, endpoint and CIDR lists (before the shared library is downloaded) now reject ports with leading zeros (`0080` is no longer accepted via octal interpretation), numbers longer than 5 digits (64-bit overflow guard), non-canonical subnet octets, edge-case bracketed IPv6 endpoints (`[:::]`, double `::`), and newlines or empty items in route lists.
- **`--route-custom` is validated on the first run regardless of where the value came from:** an invalid route list stops the install before the configuration is written.
- **An unknown command-line argument exits the installer with code 1** (it used to print help and exit 0); an explicit `--help` still returns 0.
- **`manage restore` is robust against incomplete backups:** restoring from an empty key set or a truncated backup no longer removes live clients.
- **Re-running the installer keeps all existing peers** and the default clients when regenerating the server config.
- **`manage modify` validates IP and CIDR values by range**, not just by shape.
- **File-operation atomicity:** config temp files are created on the destination filesystem (so `mv` is actually atomic), the client QR PNG is written via temp + `mv`, and temp cleanup, comma validation in lists, and `vpn://` URI QR generation were tightened.

### Internal

- **Reproducible ARM builds:** the upstream module is pinned to an explicit ref, and a build manifest is published alongside the packages.
- **`release.yml` builds bilingual release notes** (RU + EN from both changelogs) and a descriptive release title automatically.
- **Preflight and CI hardened:** correct bats verdict, full OS/arch test matrix, the docs checker runs on path triggers, new guards against stale IPv6 wording and version placeholders.
- **The documentation consistency check is about 8x faster** (single-pass Unicode heading slugger) and now covers the ROADMAP.
- The test suite grew to 790 checks (new scenarios for the validators, restore, atomicity, the slugger and release notes).

### Documentation

- Corrected descriptions of IPv6 routing, native IPv6 detection, `--json` scope and the supported OS count; the CLI reference in ADVANCED is synced with the actual flags.
- README and INSTALL_VPS point at `--ssh-port` for changing the SSH port; mobile carrier advice and the script integrity note were refreshed; the ROADMAP was brought up to date.
- The release process is documented without contradictions (release-notes source, neutral review gate, checklist sync); Code of Conduct reports go to a private channel; blank issues are disabled - questions go to Discussions.

### Verification

- Live runs on clean VPSes: Ubuntu 24.04 (x86_64, full cycle: negative validator tests, install with 2 reboot-resumes, the whole `manage` CRUD), Ubuntu 26.04 (ARM64: PPA questing -> noble remap, DKMS module build), Debian 13 (custom routes via `--route-custom`, kernel headers fallback, DKMS against a kernel upgraded during the install). Real cross-continent AWG 2.0 handshakes and DNS through the tunnel confirmed.

---

## [5.15.2] - 2026-06-02

**v5.15.2** - a small maintenance release. It points the install and update commands in the documentation at the current tag. No installer or management code changed, behavior is unchanged. Support matrix is unchanged: Ubuntu 24.04 / 25.10 / 26.04, Debian 12 / 13, x86_64 + ARM.

### Fixed

- **Install and update commands in the documentation point at the current release.** The `wget` / `curl` examples in README, INSTALL_VPS and ADVANCED were pinned to the previous tag, so copying a command downloaded the previous version. They now point at this release, so following the instructions installs it.

### Internal

- The documentation consistency check now verifies that pinned `raw.githubusercontent.com` links match the current version, so install commands do not fall behind the release in the future.

---

## [5.15.1] - 2026-06-02

**v5.15.1** - a maintenance release after a round of external code and documentation audits. No new features: it hardens the v5.15.0 dual-stack IPv6 work, tightens several management commands, and fixes a number of correctness and robustness issues. A default install is unchanged. Support matrix unchanged: Ubuntu 24.04 / 25.10 / 26.04, Debian 12 / 13, x86_64 + ARM.

### Changed

- **Split tunnel + IPv6 now mirrors the IPv4 intent (behavior change).** When a client uses a custom `ALLOWED_IPS` (split tunnel), the dual-stack config keeps that IPv4 split list and adds only the tunnel ULA for IPv6 - it no longer forces a full `::/0` IPv6 route. A full tunnel (`ALLOWED_IPS=0.0.0.0/0`) still gets `::/0` with native IPv6, or the tunnel ULA without it. This affects only clients created with both a split tunnel and `--allow-ipv6-tunnel`. If you relied on the old behavior of IPv6 going full-tunnel while IPv4 stayed split, recreate the client to pick up the new routing.

### Fixed

- **`vpn://` URI now carries the server's real MTU, keepalive, and DNS** instead of fixed values, so a config imported from the URI matches the `.conf` even after the server settings or a `manage modify` changed them.
- **Stricter native-IPv6 detection.** The server is treated as natively IPv6-capable only when it has a global (non-ULA) IPv6 address and a default IPv6 route, so a client gets a full `::/0` route only when it will actually work.
- **The IPv6 host stack is re-enabled before detection** when the tunnel needs it, so a server that had IPv6 disabled via sysctl still gets a working dual-stack tunnel.
- **`install` fails fast if `apt update` errors out**, instead of continuing a multi-step install against a stale package cache.
- **`manage modify` validates the Endpoint and AllowedIPs** it is given (host:port, CIDR list) before writing them.
- **`manage add` is safe against name reuse:** it refuses a name that already exists and cleans up partial key or config artifacts if creation fails partway.
- **`manage restore` prunes stale clients and keys** that are absent from the backup, so a restore yields exactly the backed-up state.
- **`manage help` exits 0** for an explicit help request and 1 only for a real usage error.
- **`manage --json` keeps stdout pure JSON** by routing info and debug logging to stderr.
- **Log messages no longer double percent signs** ("95%" stays "95%").
- **`manage restore` recreates the expiry directory** before restoring expiry timestamps.

### Documentation

- `--subnet` help states the `/24`-only requirement; `install --help` lists Ubuntu 26.04.
- `manage --help` and the README document `list --json` (including the `client_ipv6` field).
- Restored the changelog compare-links for 5.11.0-5.15.0, fixed several broken in-page anchors, refreshed `SECURITY.md` and `CONTRIBUTING.md`, and added `docs/RELEASE_PROCESS.md`.

### Internal

- Tagging a release now runs a full preflight gate (syntax, shellcheck, tests, punctuation, version and SHA-pin consistency, documentation checks) before the GitHub Release is published, plus a lightweight documentation-consistency workflow. The signing design doc was aligned with the asset-upload draft.

---

## [5.15.0] - 2026-06-01

**v5.15.0** - optional dual-stack IPv6 inside the tunnel. Requested by users in [#24](https://github.com/bivlked/amneziawg-installer/issues/24): the new `--allow-ipv6-tunnel` flag hands clients an IPv6 address from the private ULA subnet `fddd:2c4:2c4:2c4::/64` alongside the usual IPv4. Off by default - without the flag the install is identical to v5.14.x. Support matrix unchanged: Ubuntu 24.04 / 25.10 / 26.04, Debian 12 / 13, x86_64 + ARM.

### Highlights

- 🆕 **`--allow-ipv6-tunnel` flag** in `install_amneziawg.sh` (opt-in, off by default). Enables dual-stack IPv6 inside the VPN tunnel: the server and clients get addresses from the ULA subnet `fddd:2c4:2c4:2c4::/64` next to IPv4. The subnet can be overridden via `IPV6_SUBNET=` in `awgsetup_cfg.init`. This is separate from the existing `--allow-ipv6` (host-level IPv6 via sysctl); the behavior of `--allow-ipv6` / `--disallow-ipv6` is unchanged.
- 🌐 **Dual-stack server and client configuration**. With the flag on, the server `awg0.conf` gets IPv6 in `Address` and `AllowedIPs`, an ip6tables MASQUERADE rule on the public NIC is set up, and the client `.conf` plus `vpn://` URI become dual-stack. The installer detects native IPv6 on the server (`ip -6 addr show scope global`): with native IPv6 the client gets a full `::/0` route, without native IPv6 only the tunnel subnet, so IPv6 traffic does not vanish into a black hole (a warning is logged in that case).
- 🔧 **`manage list` and `manage regen` are dual-stack aware**. The client list shows a mixed state (new dual-stack clients next to legacy IPv4-only ones), and config regeneration correctly preserves the IPv6 address.

### Migration

- **Existing clients are unaffected.** After upgrading and enabling IPv6, already-issued IPv4-only configs keep working as before - the server does nothing to them automatically.
- To add IPv6 to a client that already existed, after enabling `--allow-ipv6-tunnel` (re-run the installer with the flag or set `ALLOW_IPV6_TUNNEL=1` in `awgsetup_cfg.init`) recreate that client: `manage remove <name>`, then `manage add <name>`. Only recreation allocates an IPv6 for the client on the server and issues a dual-stack config. A plain `regen` keeps the client IPv4-only, because its `[Peer]` entry on the server has no IPv6 yet. The new `.conf` must be re-imported on the device.
- Details and troubleshooting are in [ADVANCED.en.md](ADVANCED.en.md#ipv6-tunnel-adv).

### Tests

- New file `tests/test_v515_sha_pins_lockstep.bats` (4 tests): checks the real `sha256sum` of the four helper scripts against the `COMMON_SCRIPT_SHA256` / `MANAGE_SCRIPT_SHA256` pins in both installers, so a partial bump cannot ship an installer with drifted pins.
- New helper `scripts/update-sha-pins.sh` (with a `--verify` flag) to recompute and verify the SHA pins, and `scripts/preflight-check.sh` for a single pre-tag check run (syntax, shellcheck, bats, punctuation, version consistency, SHA pins).

### Verification

- The automated test suite (bats) was extended with dual-stack coverage: server and client config rendering, IPv6 allocation, dual-stack `vpn://` URI, `manage list`/`regen`, and the no-native-IPv6 path. The no-flag regression is identical to v5.14.x.
- Verified on clean servers: the happy path on ARM64 / Ubuntu 26.04 with native IPv6 (the client gets a full `::/0` route, ip6tables MASQUERADE, IPv6 internet egress), and the warning path on x86_64 / Debian 13 without native IPv6 (the client gets the tunnel subnet only). A cross-host tunnel was confirmed live: both IPv4 and IPv6 pass through it (loss-free ping6 to the server's in-tunnel address).

---

## [5.14.5] - 2026-05-25

**v5.14.5** - the installer now detects the real SSH port and opens exactly that one in UFW. Previously, with SSH on a non-standard port, the firewall opened only port 22, and access to the server could be lost once it was enabled on the final step. No architectural changes, support matrix unchanged: Ubuntu 24.04 / 25.10 / 26.04, Debian 12 / 13, x86_64 + ARM.

### Highlights

- 🔧 **Automatic SSH port detection for the UFW rule** in `install_amneziawg.sh`. As observed by @userosos on Debian 13 ([#91](https://github.com/bivlked/amneziawg-installer/issues/91)): with SSH on a non-standard port, the installer opened only the default port 22 in UFW, and access was lost once the firewall was enabled (`ufw enable`). Added real-port detection: first the `--ssh-port` flag, then the effective `sshd -T` config (the `Port` directive and `ListenAddress host:port`, honouring drop-in files in `sshd_config.d`), then the real `sshd` listening sockets via `ss`, then `sshd_config` parsing, and port 22 as the default. UFW now opens every detected SSH port, the pre-enable warning names them explicitly, and the `--yes` mode also detects the port instead of assuming 22.
- 🆕 **`--ssh-port=PORT` flag** to set the SSH port manually (comma-separated list allowed) for non-standard setups where auto-detection is not desired.

### Tests

- New file `tests/test_ssh_port_detect.bats` (18 tests): port detection from `--ssh-port`, from `sshd -T` (the `Port` directive and `ListenAddress`, IPv4 and bracketed IPv6), union with `ss` sockets, port normalisation and deduplication, UFW rule application in both branches (fresh setup and update), and parity between the RU and EN branches.

### Verification

- Verified on clean servers with SSH on a non-standard port and a `--yes` install: Ubuntu 24.04 (x86_64) and Ubuntu 26.04 (ARM64). UFW opens the right port and server access is preserved.

---

## [5.14.4] - 2026-05-24

**v5.14.4** - small installer refinement: declining UFW activation during an interactive install (answering `N` to "Enable UFW?") now correctly continues the installation. A minor user-choice handling improvement, no architectural changes. Support matrix unchanged: Ubuntu 24.04 / 25.10 / 26.04, Debian 12 / 13, x86_64 + ARM.

### Highlights

- 🔧 **Declining UFW now continues the install correctly** in `install_amneziawg.sh`. As observed by @jay0x on Ubuntu 24.04 ([#89](https://github.com/bivlked/amneziawg-installer/issues/89)): answering `N` to the interactive "Enable UFW?" prompt stopped the installer instead of continuing. Adjusted the decline handling: the UFW rules stay configured (deny incoming, SSH rate limit, VPN port allow, routing) but the firewall is not activated, the install proceeds, and a hint is logged that the server is running without a firewall, along with the command to enable it later (`sudo ufw enable`). With the `--yes` flag the behaviour is unchanged - UFW is enabled automatically. Affects only the interactive path where the user declines the firewall themselves.

### Tests

- New file `tests/test_v5144_ufw_optional.bats` (6 tests): declining UFW continues the install and does not call `ufw enable`; accepting enables UFW; `--yes` mode enables automatically without reading input; structural parity between the RU and EN branches.

---

## [5.14.3] - 2026-05-21

**v5.14.3** - patch release with one fix: `cleanup_system()` no longer calls `apt-get autoremove` after purging `cloud-init`, which on clean Ubuntu 26.04 server in VirtualBox (subiquity, no cloud-init network management) could remove `netplan-generator` as a transitive dependency and leave the server unable to obtain an IP via DHCP after reboot. No architectural changes. Support matrix unchanged: Ubuntu 24.04 / 25.10 / 26.04, Debian 12 / 13, x86_64 + ARM.

### Highlights

- 🛡️ **Network stack protection in `cleanup_system`** in `install_amneziawg.sh`. Reported in [#84](https://github.com/bivlked/amneziawg-installer/issues/84) by @jay0x on a clean Ubuntu 26.04 server in VirtualBox: after the installer the server did not obtain an IP via DHCP. Root cause: an aggressive `apt-get autoremove` after `apt-get purge cloud-init` cascaded into removing `netplan-generator` as a transitive cloud-init dependency. Without `netplan-generator` the `/etc/netplan/00-installer-config.yaml` file (subiquity creates it on ISO installs) was no longer translated into `/run/systemd/network/*.network`, and `systemd-networkd` started with empty configuration. Changes in `cleanup_system()`: the `apt-get autoremove` call is dropped; before any `apt-get purge` an `apt-mark hold` is applied to critical network stack packages (`netplan.io`, `netplan-generator`, `systemd-resolved`, `netcfg`, `ifupdown`) - we first snapshot the user's existing holds via `apt-mark showhold` and only add our own hold on packages the user has not already locked (and on unhold we release strictly the ones we placed); a default-route snapshot is taken before and after cleanup - if the route is lost, the installer attempts recovery (`netplan.io` is reinstalled unconditionally, `netplan-generator` only when it is available in the archive via `apt-cache show`, so Debian 12 - which does not ship that package - does not abort the apt transaction), restart `systemd-networkd`, `netplan apply`, then a wait loop polling the route every 1-5 seconds for up to ~26 seconds; then on failure a last-ditch interface bring-up via `ip link set up`, first `networkctl renew` with a route re-check, then `dhclient -4` if needed, and only then the installer stops with a hint to restore the network from the console (`sudo dhclient -4 <iface>`) and retry the installer with `--no-tweaks`. Orphan packages now stay in the system after `purge` (~50-200 MB) - acceptable trade-off for stability; users can manually run `apt-get autoremove --no-install-recommends` after installation.
- 🪟 **Ubuntu 26.04 whitelisted in `check_os_version`**. Previously 26.04 fell into the warning branch with an interactive prompt (passed automatically with `--yes`). Now it is recognised as a supported OS alongside 24.04 / 25.10. The release is tested on 26.04 server in VirtualBox after the Issue #84 fix.

### Tests

**+14 new bats** (532 planned in `bats tests/`, up from 518 on v5.14.2):

- `test_v5143_cleanup_no_autoremove.bats` (+14) - functional checks via mocks of `dpkg-query`, `apt-get`, `apt-mark`, `apt-cache`, `ip`, `systemctl`, `netplan`, `networkctl`, `dhclient`, `sleep`: `apt-get autoremove` is never invoked; `apt-mark hold` fires for the netplan and systemd-resolved packages before any `purge` (without `systemd-networkd` - that is not a standalone package on Ubuntu 24+, the binary lives inside `systemd`); pre-existing user apt-mark holds are left alone (our hold/unhold cycle skips them); recovery path when default route is lost (install `netplan.io` unconditionally, `netplan-generator` only behind an `apt-cache show` gate, `netplan apply` + wait loop); last-ditch path after primary recovery fails (`ip link set up` + `networkctl renew` with a route re-check, then `dhclient -4` as fallback); `die` path on total failure with the `--no-tweaks` hint; existing cloud-init guard (three marker checks) preserved. Structural checks: RU/EN line parity of `cleanup_system`, presence of `apt-mark hold` / `unhold` / `die` in both files, absence of a real `apt-get autoremove` line (rationale comments are excluded).

### Compatibility

- **Backward compatible** with v5.14.x. Behaviour on cloud images that carry cloud-init markers (Hetzner, Oracle Cloud) is unchanged. ISO installs of Ubuntu 26.04 in VirtualBox now correctly handle the absence of cloud-init netplan markers.
- The **`--no-tweaks`** workaround still works but is no longer required for the @jay0x scenario.

### Upgrade

From v5.14.2 to v5.14.3:

```bash
wget https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.14.3/install_amneziawg_en.sh
sudo bash ./install_amneziawg_en.sh --force --yes
```

Step 5 of the installer pulls the latest `manage_amneziawg.sh` and `awg_common.sh` with SHA256 verification.

Thanks to @jay0x for the detailed repro with `dpkg`, `journalctl`, and `ls /etc/netplan/` output - the root cause would have taken longer to pin without it.

[Full list of changes since v5.14.2](https://github.com/bivlked/amneziawg-installer/compare/v5.14.2...v5.14.3)

---

## [5.14.2] - 2026-05-21

**v5.14.2** - patch release with two small fixes: the `.vpnuri.png` QR is now scannable with a phone camera from a computer screen (long URIs with PSK used to trigger error 900 in AmneziaVPN on iOS), and the ARM .deb build script no longer silently picks the "first" `/lib/modules/*/build` directory on hosts with multiple installed kernels. No architectural changes. Support matrix unchanged: Ubuntu 24.04 / 25.10 / 26.04, Debian 12 / 13, x86_64 + ARM.

### Highlights

- 📱 **`.vpnuri.png` QR is now scannable off a screen**. `awg_common.sh:generate_qr_vpnuri` now invokes `qrencode` with an explicit `-s 6` (the previous default was `3`). This is the real fix: at the default scale the PNG modules were too small for the iPhone camera to resolve when scanning off a computer screen, which produced error 900 ImportInvalidConfigError in AmneziaVPN on iOS for @haritos90 in issue [#72](https://github.com/bivlked/amneziawg-installer/issues/72) (Debian 12 + AmneziaVPN iOS 4.8.15.4). Increasing the module scale does not change QR data capacity - it makes each module physically larger so the camera can distinguish black/white blocks reliably. The current `qrencode` defaults are also pinned explicitly: `-l L` (lowest error-correction level) and `-m 4` (standard quiet zone) - so future default changes in `libqrencode` cannot regress this fix. Pasting the text of `.vpnuri` into the app already worked; the fix restores the primary camera-scan path.
- 🛠️ **`scripts/build-arm-deb.sh`: explicit `KERNEL_VERSION` + fail on ambiguity**. The ARM .deb builder used to pick the first matching `/lib/modules/*/build` directory through a simple loop; on developer hosts with several installed kernels this could build against an unintended target. An external code review on 8 May raised the risk. Version resolution has been extracted into a `_resolve_kernel_version` helper with three paths: when `KERNEL_VERSION` is set, the helper validates `/lib/modules/$KERNEL_VERSION/build` and uses it; otherwise it counts candidates - zero is an error (unchanged), exactly one is the unambiguous choice (unchanged), two or more produce an explicit failure that lists every found version and asks the caller to set `KERNEL_VERSION`. The AmneziaWG CI matrix is unaffected because each QEMU container installs exactly one headers package; the defensive behaviour is needed when the script runs on user hosts.

### Tests

**+18 new bats** (528 total, up from 510 on v5.14.1):

- `test_v5142_qr_high_density.bats` (+7) - asserts that `qrencode` receives `-l L`, `-s 6`, `-m 4`, that `-t png` is still passed, regression check that the PNG file is still produced from the `.vpnuri` payload, and byte-identical parity of the invocation line between RU and EN.
- `test_v5142_build_arm_deb.bats` (+11) - functional tests for `_resolve_kernel_version`: exactly one candidate, zero candidates, multiple candidates with an explicit list on stderr, directories without a `build/` subdir ignored; `KERNEL_VERSION` env path (valid, used to disambiguate, missing target dir, empty string falls back to auto-detect); structural checks that the function exists, the source-guard allows safe `source` from tests, and the old inline detection loop is gone from the main body.

### Compatibility

- **Backward compatible** with v5.14.x. Default behaviour is unchanged: `qrencode` still produces `.vpnuri.png`, and on CI hosts with exactly one installed kernel `_resolve_kernel_version` returns the same result as the previous loop.
- The **workaround** previously required for long QRs (manually copying `.vpnuri` contents into the app) is no longer needed.

### Upgrade

From v5.14.1 to v5.14.2:

```bash
wget https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.14.2/install_amneziawg_en.sh
sudo bash ./install_amneziawg_en.sh --force --yes
```

Step 5 of the installer pulls the latest `manage_amneziawg.sh` and `awg_common.sh` with SHA256 verification.

[Full list of changes since v5.14.1](https://github.com/bivlked/amneziawg-installer/compare/v5.14.1...v5.14.2)

---

## [5.14.1] - 2026-05-19

**v5.14.1** - patch release: `manage regen` now picks up the MTU from the server `awg0.conf` when regenerating client configs and no longer hardcodes `1280` in the client file. No architectural changes; default behaviour (`MTU = 1280` on the server) is unchanged. Support matrix unchanged: Ubuntu 24.04 / 25.10 / 26.04, Debian 12 / 13, x86_64 + ARM (Raspberry Pi, Oracle Ampere, Hetzner CAX).

### Highlights

- 📐 **MTU sync between server and client configs on `regen`**. Before v5.14.1 both `awg_common.sh:render_client_config` and `render_server_config` hardcoded `MTU = 1280`. If the user hand-edited MTU in `/etc/amnezia/amneziawg/awg0.conf`, `manage_amneziawg.sh regen` still wrote the stale `1280` into the new client `.conf`. MTU resolution is now ordered: value from the `[Interface]` section of server `awg0.conf` (the source of truth for a running server), then `AWG_MTU` from `awgsetup_cfg.init`, then `1280` as fallback. The live-config parser (`load_awg_params` for AWG parameters from awg0.conf) also reads the `MTU = ...` line now and exports `AWG_MTU`. Values outside the sane range `576..9100` at any stage fall back to `1280`. Reported in Discussion [#38](https://github.com/bivlked/amneziawg-installer/discussions/38) by @E-lmedano.
- 🔧 **Installer: `AWG_MTU` variable** in `awgsetup_cfg.init`. Fresh installs write `AWG_MTU=1280` into the config file; the user can override via environment before running the installer (`AWG_MTU=1380 sudo bash install_amneziawg.sh ...`) and the value is preserved. The variable is also added to the `safe_load_config` whitelist.

### Tests

**+18 new bats** (510 in the matrix, was 492 on v5.14.0):

- `test_v5141_mtu_resolution.bats` (+18) - functional tests for `_extract_mtu_from_server_conf` (valid MTU from `[Interface]`, whitespace around `=`, no MTU, ignored MTU in `[Peer]`, last-wins on duplicates, missing server file, non-numeric value); functional tests for `_validate_mtu` (accepts 1280, boundary 576 and 9100, rejects 0 / -1 / 9101 / 575 / `abc` / empty); structural checks on `render_client_config` (no `MTU = 1280` hardcode, uses `${mtu}` substitution), `render_server_config` (uses `${AWG_MTU:-1280}`); `safe_load_config` whitelist contains `AWG_MTU` in all 4 files; installer writes `AWG_MTU` to `awgsetup_cfg.init` (RU + EN); byte-identical `_extract_mtu_from_server_conf` between RU and EN.

### Compatibility

- **Backwards-compatible** with v5.13.x and v5.14.0. Default scenario behaviour is unchanged: with `MTU = 1280` on the server, `regen` still produces `1280` in the client config.
- **The previous workaround** (hand-editing `/root/awg/<name>.conf` after `regen`) is no longer needed - regen picks up whatever is in `awg0.conf`.

### Updating

From v5.13.x / v5.14.0 to v5.14.1:

```bash
wget https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.14.1/install_amneziawg_en.sh
sudo bash ./install_amneziawg_en.sh --force --yes
```

Step 5 of the installer pulls fresh `manage_amneziawg.sh` and `awg_common.sh` with SHA256 verification.

[Full diff against v5.14.0](https://github.com/bivlked/amneziawg-installer/compare/v5.14.0...v5.14.1)

---

## [5.14.0] - 2026-05-19

**v5.14.0** - small feature release: more reliable public IP detection (extra fallback services for AWS / NAT'd cloud) plus a new `manage diagnose` subcommand for one-line self-troubleshooting. Backwards-compatible with v5.13.x installs; no architectural changes. Support matrix unchanged: Ubuntu 24.04 / 25.10 / 26.04, Debian 12 / 13, x86_64 + ARM (Raspberry Pi, Oracle Ampere, Hetzner CAX).

### Highlights

- 🌐 **Extended public IP detection** in `awg_common.sh:get_server_public_ip`. The fallback cascade grew from 4 to 6 services - `api.ipify.org`, `checkip.amazonaws.com`, `icanhazip.com`, `ifconfig.io`, `ifconfig.me`, `ipinfo.io/ip` (alphabetical order, deterministic for diffs and tests). `checkip.amazonaws.com` is reachable from AWS / GCP / OCI private subnets behind a NAT Gateway where `ifconfig.me` can rate-limit; `ifconfig.io` is a backup for `ifconfig.me` downtime. First-wins behaviour preserved: when a service returns a valid IPv4, the rest are skipped. Successful detection is now traced into `/root/awg/install_amneziawg.log` (or the manage log file) - written directly to file, never to stdout, so the function's `$()` capture contract is preserved and the generated client `Endpoint =` line is not corrupted.
- 🩺 **`manage diagnose [--carrier=NAME]`** - new subcommand for one-line server self-troubleshooting. Without arguments it runs 6 health checks (kernel module loaded / service active / interface UP / sysctl ip_forward / BBR / UFW + AWG port + peer count). With `--carrier=NAME` it additionally compares the current AWG 2.0 obfuscation parameters (Jc / Jmin / Jmax / I1) against a known carrier profile and prints OK/WARN/FAIL per check with a Fix: hint. Seven confirmed carriers from `ADVANCED.en.md` operator matrix: `beeline_msk` (default preset); `yota_msk`, `tele2_msk`, `tattelecom` (mobile preset, random I1); `tele2_krasnoyarsk`, `megafon_regions` (mobile preset, I1 must be absent); `tmobile_us` (binary I1, from Discussion #45). Exit code 1 only on FAIL or unknown carrier; WARN does not change the rc. Bilingual RU + EN.
- 🔒 **Release signing design** ([docs/SIGNING_DESIGN.md](docs/SIGNING_DESIGN.md), planning only). Threat model, tool choice (minisign over cosign / GPG), signing flow with trusted-comment binding to tag + filename for rollback protection, and a draft `release-sign.yml` workflow that uploads pre-generated `.minisig` files. Activation is gated on the maintainer generating an offline keypair and committing `KEYS.txt` to the repository root; until then the section in `SECURITY.md` describes the planned path.

### Tests

**+37 new bats** (492 in the matrix, was 455 on v5.13.0):

- `test_v5140_public_ip_services.bats` (+11) - structural RU/EN parity on the 6 endpoints, byte-identical service list across RU and EN, alphabetical-order assertions (first = `api.ipify.org`, last = `ipinfo.io/ip`), functional fallthrough (first service success / first fails-second succeeds / all 6 fail / invalid IP format skip / last-in-list success / cache short-circuit).
- `test_v5140_diagnose.bats` (+16) - structural RU/EN parity on `diagnose_server` and the `_diagnose_carrier_known`, `_diagnose_carrier_list`, `_diag_line` helpers; CLI parser accepts `--carrier=NAME`; command dispatcher wires up `diagnose`; usage help mentions diagnose; functional checks on the carrier map (`beeline_msk` row matches default-preset shape, `tele2_krasnoyarsk` has `i1=absent`, `tmobile_us` has `i1=binary` + Jc=6; unknown carrier returns 1); carrier list has 7 distinct confirmed entries; previously-included unconfirmed `mts_msk` + `megafon_msk` are intentionally removed.

### Compatibility

- **OS**: Ubuntu 24.04 LTS, 25.10, 26.04 (with noble fallback). Debian 12 (bookworm), 13 (trixie).
- **Arch**: amd64, arm64 (Raspberry Pi 4/5, Oracle Cloud Ampere, Hetzner CAX, AWS Graviton, other ARM VPS).
- **Russian carriers** matrix in `ADVANCED.en.md`. The new `diagnose --carrier=NAME` recognises 7 confirmed rows; "🔄 testing" rows (Megafon Moscow, MTS Moscow) intentionally excluded until the operator range is confirmed and locked.

### Out of scope

- v5.14.1+: minor cleanups uncovered by post-release feedback.
- v5.15.x: minisign signature activation (after maintainer keypair generation), per-client CPS profiles (Issue #71), `--preset=mobile-awg1` for I1=none carriers.

[Full diff against v5.13.0](https://github.com/bivlked/amneziawg-installer/compare/v5.13.0...v5.14.0)

---

## [5.13.0] — 2026-05-12

**v5.13.0** — AmneziaWG 2.0 VPN installer release with Ubuntu 25.10 (questing) and 26.04 support, plus a `--force` safety guard against accidental re-install on a configured server. Ubuntu 24.04, Debian 12 / 13, x86_64 + ARM (Raspberry Pi, Oracle Ampere, Hetzner CAX) support — unchanged.

### Highlights

- 🛡️ **PPA noble fallback for Ubuntu 25.10 / 26.04** ([Issue #46](https://github.com/bivlked/amneziawg-installer/issues/46)). The Amnezia PPA does not yet publish packages for `questing` (25.10) or upcoming Ubuntu codenames. The installer now auto-detects the 404 on `dists/<codename>/Release`, remaps the suite to `noble` in `/etc/apt/sources.list.d/amnezia-ppa.sources` and re-runs `apt update`. If the server has leftover kernel headers from a previous 24.04 install (typical after `do-release-upgrade`), the installer also pulls in `gcc-13` from `questing/universe` so the DKMS autoinstall succeeds for every kernel. No manual `sources.list` edits, no DKMS surprises. The script also repairs a "sticky" `.sources` file from a previous (≤ v5.12.1) run that left `Suites: questing` behind after an apt failure.
- 🔒 **`--force` safety guard** ([Issue #78](https://github.com/bivlked/amneziawg-installer/issues/78)). Re-running the installer on a server with AmneziaWG already configured now requires an explicit `--force` (or `AWG_FORCE_REINSTALL=1`). Without it, the script early-exits with a clear "already installed and running" message. Server keys, peer configs, and obfuscation parameters survive a re-run, but Step 1 re-tunes sysctl/swap/BBR, `apt-get upgrade` may pull a new kernel (and require another reboot), and Step 7 restarts `awg-quick@awg0` — handshakes drop for a few seconds. The guard removes that foot-gun.
- 🧹 **`manage_amneziawg.sh` logging: WARN → stderr.** In v5.12.1 `manage_amneziawg.sh:log_msg` routed only ERROR to stderr and leaked WARN to stdout — broke CI/automation parsing (stdout = "data", stderr = "diagnostics"). WARN and ERROR now both go to stderr, symmetric with `install_amneziawg.sh:log_msg`.
- 💾 **Precise `/swapfile` check in `/etc/fstab`.** The old substring check `grep -q '/swapfile'` matched commented lines and partial-name hits (`/swapfile.bak`); on re-run the installer could mistakenly skip adding a valid entry — swap then failed to mount on reboot. Switched to an anchored field-aware awk check: `!/^[[:space:]]*#/ && $1 == "/swapfile" && $3 == "swap"`. Idempotent and comment-resistant.

### Installation

```bash
wget https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.13.0/install_amneziawg_en.sh
chmod +x install_amneziawg_en.sh
sudo bash ./install_amneziawg_en.sh
```

3 commands → ~20 minutes → a working VPN server with traffic obfuscation. Full guide — [README → Installation](README.en.md#installation).

### Upgrading an existing server

Run the latest `install_amneziawg.sh` with `--force` (if AmneziaWG is already running) — Step 5 fetches the fresh `manage_amneziawg.sh` and `awg_common.sh` with SHA256 verification. Full commands — [ADVANCED.en.md → Updating the scripts](ADVANCED.en.md#update-scripts-adv).

### Tests

**+68 new bats** (455 in the matrix, was 387 on v5.12.1):

- `test_v5130_ppa_noble_fallback.bats` (+33) — RU/EN structural greps on the pre-check block and suite-mismatch detection, parity counts, functional tests with mocked `curl` (404 → noble, timeout → noble, success → questing), LTS whitelist (noble/jammy/focal skip pre-check), suite mismatch deletes file on mismatch and preserves on match, corrupt `.sources` (missing `Suites:`) gets recreated, legacy `.sources` mismatch is removed, gcc-13 pre-install fires when stale headers are detected.
- `test_v5130_force_guard.bats` (+19) — RU/EN structural greps on the `--force|-f` CLI flag, the `AWG_FORCE_REINSTALL=1` env bridge, the idempotency guard `[[ -f $SERVER_CONF_FILE ]] && systemctl is-active --quiet awg-quick@awg0`, the help-section mention of `-f, --force`, RU/EN parity by `FORCE_REINSTALL` occurrence count; functional matrix of 6 cases (clean install / configured+active+no-force / configured+inactive+no-force → repair flow / configured+active+--force / env bridge / strict `=1` env vs `yes`).
- `test_v5130_bundled_fixes.bats` (+16) — rcgr: RU/EN log_msg routes WARN to stderr (structural + functional, INFO still on stdout); i31a: awk check on `/swapfile` correctly detects a valid entry, rejects commented lines, rejects partial-name matches (`/swapfile.bak`), handles indented lines and an empty fstab.

### Compatibility

- **OS**: Ubuntu 24.04 LTS, 25.10, 26.04 (with noble fallback). Debian 12 (bookworm), 13 (trixie).
- **Arch**: amd64, arm64 (Raspberry Pi 4/5, Oracle Cloud Ampere, Hetzner CAX, AWS Graviton, other ARM VPS)
- **Russian carriers**: `--preset=mobile` works on Yota, Beeline, MTS, Tattelecom, Tele2 (Moscow), Megafon (Moscow). See the operator matrix in README.

### Out of scope

- v5.13.1: external review fixes (kernel ambiguity in `build-arm-deb.sh`), backlog refinements.
- v5.14.0: `--preset=mobile-awg1` (I1=none fallback for Tele2 Krasnoyarsk / Megafon regions).

Full roadmap — [Issue #79](https://github.com/bivlked/amneziawg-installer/issues/79).

---

## [5.12.1] — 2026-05-08

**v5.12.1** — patch release of the AmneziaWG 2.0 VPN installer: three small fixes for issues found in the first 48 hours after v5.12.0. No new features, no architectural changes. Support matrix unchanged: Ubuntu 24.04 / 25.10, Debian 12 / 13, x86_64 + ARM (Raspberry Pi, Oracle Ampere, Hetzner CAX).

### Highlights

- 🔧 **`AWG_SKIP_APPLY=1` works again in `manage add` / `manage remove`.** v5.12.0 added an unconditional pre-call to `ensure_amneziawg_kernel_module` before both actions to make `awg syncconf` reliable. Side effect: it broke the offline edit-only flow on dev / CI machines without the kernel module loaded, where `AWG_SKIP_APPLY=1` accumulates changes for batch apply (see [`ADVANCED.en.md`](ADVANCED.en.md) — environment variables section). The pre-call is now wrapped in `if [[ "${AWG_SKIP_APPLY:-0}" != "1" ]]`. `manage restart` is intentionally NOT gated — it is an explicit apply, AWG_SKIP_APPLY has no meaningful semantics for it. Only the literal `1` is honoured; `yes`, `true`, any other string — same behaviour as unset (apply happens).
- ☁ **`linux-headers-cloud-${arch}` in the repair-module fallback on Debian.** `awg_common.sh:_install_kernel_headers` (used by `manage repair-module`) on Debian only tried `linux-headers-${kernel_ver}` and `linux-headers-${arch}`. On AWS / Azure / GCP / cloud-Hetzner (kernel name contains `-cloud-`) the exact-version package can disappear from the mirror after a kernel upgrade, while the cloud meta `linux-headers-cloud-${arch}` stays available. The installer's step 2 already knew about cloud-headers via smart detection; now `repair-module` knows too and tries the cloud meta before the generic one. Standard kernels (no `-cloud-` in the name) — behaviour unchanged.
- 📦 **ARM prebuilt packages now decompress correctly with the in-tree kernel decoder** ([Issue #76](https://github.com/bivlked/amneziawg-installer/issues/76)). `scripts/build-arm-deb.sh` used `xz -9` (CRC64 check, 64 MiB dictionary) — the userspace `xz -t` tool considered the stream valid, but the in-tree Linux decoder on Debian 13 trixie kernel `6.12.85+deb13-arm64` (build 2026-04-30) returned `decompression failed with status 6`. Switched to a kernel-compatible preset `xz --check=crc32 --lzma2=dict=1MiB` — matches mainline `scripts/Makefile.modinst`. Plus a build-time sanity gate: after compression, `xz -t` + `xz -d -c` round-trip; if anything fails — `exit 1`, no broken prebuilt ships to the `arm-packages` release. On the v5.12.1 tag push, CI workflow `arm-build.yml` re-publishes all 14 ARM prebuilt packages with the new xz flags.

### Install

```bash
wget https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.12.1/install_amneziawg_en.sh
chmod +x install_amneziawg_en.sh
sudo bash ./install_amneziawg_en.sh
```

3 commands → ~20 minutes → a ready-to-use VPN server with traffic obfuscation. Details — [README → Install](README.en.md#installation).

### Upgrading an existing server

Run a fresh `install_amneziawg_en.sh` — at step 5, `manage_amneziawg.sh` and `awg_common.sh` are updated automatically (with SHA256 verification). Full commands — [ADVANCED.en.md → How to update the scripts](ADVANCED.en.md#update-scripts-adv).

### Tests

**+30 new bats tests** (387 in the matrix, was 357 in v5.12.0):

- `test_v5121_skip_apply_regression.bats` (+14) — RU/EN structural greps on `add` / `remove` / `restart` blocks, plus runtime semantics of the gate for every documented value (unset / 0 / 1 / yes / true / YES); confirms `repair-module` keeps the `AWG_ALLOW_APT_IN_ENSURE=1 ensure_amneziawg_kernel_module full` invocation; bash -n syntax sanity.
- `test_v5121_cloud_headers.bats` (+9) — functional test of `_install_kernel_headers` via mocked `apt-get` and `dpkg`: cloud kernel gets the cloud meta in candidates before the generic one, standard kernel does not, Ubuntu codepath untouched; the EN mirror `awg_common_en.sh` is verified separately.
- `test_v5121_xz_kernel_compat.bats` (+7) — structural greps for the new xz flags in `build-arm-deb.sh`, fail-fast on sanity-stage failure, local round-trip with the same flags (toolchain smoke test; kernel-decompressor compatibility itself is best validated on a real kernel boot — VPS or QEMU with the target kernel).
- `test_v5115_regen_multiarg.bats` — version assertion bumped from 5.12.0 to 5.12.1.

### Compatibility and dependencies

- **Fully backwards-compatible.** All three fixes change behaviour only in narrow regression cases (offline edit / cloud-kernel repair / ARM prebuilt on Debian 13 trixie). The standard install + client flow is unchanged.
- **No new dependencies.**

[Full diff against v5.12.0](https://github.com/bivlked/amneziawg-installer/compare/v5.12.0...v5.12.1)

---

## [5.12.0] — 2026-05-06

**v5.12.0** — feature release of the AmneziaWG 2.0 VPN installer: one big feature — **automatic DKMS module recovery on kernel upgrade**. No architectural changes: compatible with all v5.11.x installs — the apt hook, systemd unit, and helper are deployed on the next run of `install_amneziawg_en.sh`. Support matrix unchanged: Ubuntu 24.04 / 25.10, Debian 12 / 13, x86_64 + ARM (Raspberry Pi, Oracle Ampere, Hetzner CAX).

### Highlights

- 🛡 **DKMS auto-repair on kernel upgrade — three layers of safety net.** Before v5.12.0, after `apt upgrade` of the kernel, DKMS did not always rebuild the `amneziawg` module by the next `reboot` — `awg-quick@awg0` failed with `modprobe: FATAL: Module amneziawg not found`, and the VPN was down until manual recovery. Now three safety nets work transparently:
  - **apt hook** (`/etc/apt/apt.conf.d/99-amneziawg-post-kernel`) — `DPkg::Post-Invoke` runs `/usr/local/sbin/amneziawg-ensure-module --hook`, which iterates `/lib/modules/*/build`, rebuilds DKMS for every target kernel with installed headers, then `depmod -a`. Log at `/var/log/amneziawg-ensure-module.log` (logrotate weekly, 4 copies). The stamp file `/var/lib/amneziawg/ensure-module.stamp` silences the hook on routine apt operations unrelated to the kernel.
  - **systemd unit** (`amneziawg-ensure-module.service`) — `Type=oneshot`, `Before=awg-quick@awg0.service`, `After=systemd-modules-load.service local-fs.target`. At boot, before `awg-quick`, it iterates kernels with already-installed headers (`/lib/modules/*/build`), rebuilds DKMS, runs `modprobe amneziawg`, and verifies via `lsmod`. If headers are missing, it logs a WARN and exits successfully — installing the headers themselves is the job of step 2 of the installer or of `manage repair-module`. Logs in journal (`journalctl -u amneziawg-ensure-module.service`). `ConditionPathExists=/usr/local/sbin/amneziawg-ensure-module` — the unit will not fail if the helper has been removed.
  - **manage repair-module** — explicit fallback for interactive recovery: `sudo bash /root/awg/manage_amneziawg.sh repair-module`. Sets `AWG_ALLOW_APT_IN_ENSURE=1` (apt-get install of kernel-headers is allowed only in this context — the apt hook and systemd unit do not use it to avoid blocking on dpkg-lock).
- 🧠 **Smart kernel-headers meta-package detection.** Step 2 of the installer now installs a meta-package matched to your kernel rather than pinning to `linux-headers-$(uname -r)`: on Ubuntu it extracts the flavor from `uname -r` (`aws`/`azure`/`gcp`/`oracle`/`kvm`/`lowlatency`/`raspi`) with a fallback to `linux-headers-generic`; on Debian — `linux-headers-cloud-${arch}` for cloud kernels, otherwise `linux-headers-${arch}`. This protects against the case where `apt-get upgrade` raised the kernel, but the new module fails to build without matching headers.

### Other

- 🛠 **`manage_amneziawg.sh` pre-calls `ensure_amneziawg_kernel_module` in `add` / `remove` / `restart`.** If the module is unloaded or doesn't match the current kernel, it tries to recover before the operation — this removes half of the "add a client doesn't work after `apt upgrade`" reports.
- 🧹 **`step_uninstall` cleans up the auto-repair components.** On `--uninstall` the systemd unit is disabled, and the apt hook, helper, logrotate config, stamp directory `/var/lib/amneziawg/`, and rotated logs `/var/log/amneziawg-ensure-module.log*` are removed. Idempotent — installs from before v5.12.0 are unaffected.

### Install

```bash
wget https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.12.0/install_amneziawg_en.sh
chmod +x install_amneziawg_en.sh
sudo bash ./install_amneziawg_en.sh
```

3 commands → ~20 minutes → a working VPN server with traffic obfuscation. Details — [README → Install](README.en.md#installation).

### Upgrading an existing server

Run the fresh `install_amneziawg_en.sh` — at step 5 `manage_amneziawg.sh` and `awg_common.sh` are refreshed automatically (with SHA256 verification), and at step 2 the apt hook, systemd unit, helper, and logrotate config are deployed. For an existing server this is a safe re-run. Full commands — [ADVANCED.en.md → Updating the scripts](ADVANCED.en.md#update-scripts-adv).

### Tests

**+32 new bats** (357 total, was 325 in v5.11.5):

- `test_v512_dkms_repair.bats` (+32) — structural coverage of the DKMS auto-repair deployment phases: 4 functions in `awg_common.sh`+`_en.sh`, ≥3 pre-calls in manage (`add`/`remove`/`restart`), the `manage repair-module|repair` command, the `AWG_ALLOW_APT_IN_ENSURE` gate; smart kernel-headers candidate-loop (Ubuntu flavor extraction, Debian cloud detection, RPi guard, fallback ordering: flavor BEFORE generic + cloud BEFORE arch); helper `--hook|--systemd` modes, stamp fast-path gated to `--hook`, modprobe+lsmod in `--systemd` plus 2 exit-1 paths, helper does not use apt-get; systemd unit 12 directives, atomic deploy, `daemon-reload`+`enable`; byte-identical RU/EN for helper, hook, logrotate, unit; atomic deploy cleanup-on-failure for all 4 staging vars; helper body parses with `bash -n`. Mock-based runtime tests (kernel upgrade simulation) are run on VPS Ubuntu 24.04 + Debian 13 as part of the release test.

### Compatibility and dependencies

- **Fully backwards-compatible.** v5.11.x installs continue to work as before; auto-repair components are deployed on the next run of `install_amneziawg_en.sh` — re-run is safe. Step 2 now installs a meta-package for headers, which protects against kernel-upgrade-without-headers; no extra packages need to be installed manually.
- **No new dependencies.** The helper uses `dkms`, `depmod`, `modprobe`, `systemctl` — all from the base install. The apt hook is a POSIX-sh inner command (not bash). The systemd unit is `Type=oneshot`, no timers needed.

---

## [5.11.5] — 2026-05-05

**v5.11.5** — bug-fix release of the AmneziaWG 2.0 VPN installer: two small fixes after v5.11.4, no architectural changes. Support matrix unchanged: Ubuntu 24.04 / 25.10, Debian 12 / 13, x86_64 + ARM (Raspberry Pi, Oracle Ampere, Hetzner CAX).

### Highlights

- 🔁 **`manage regen c1 c2 c3` now regenerates all three clients, not just the first.** Until v5.11.5 the `regen` case picked up only the first argument from the list — the rest were silently dropped. `add` and `remove` already had the loop over arguments, but `regen` was missing it. Behaviour is now consistent: each name is validated and processed individually, a missing client logs a warning and contributes `rc=1`, valid ones still get regenerated. A summary at the end prints `Processed: N of M`. The no-args path (`manage regen` regenerates all clients) is unchanged. ([#70](https://github.com/bivlked/amneziawg-installer/issues/70), @Barmem)
- 🛡 **Step 2: a hard apt-get update error is no longer masked.** In v5.11.4 I downgraded the `apt-get update` check at step 2 to a warning, so that a brief Launchpad PPA outage (issue #68) would not break the install. Side effect: real apt errors — DNS, GPG mismatch, dpkg lock contention on the base mirror — let the install continue on a stale `apt-cache` and fail later with a less actionable error. The logic now distinguishes the two scenarios: errors only on the Amnezia PPA (issue #68) — continue, `apt_wait_for_ppa_package` retries; any other non-source error — `die` with concrete pointers (DNS / `/etc/apt/keyrings` / dpkg lock). The OOM / silent-crash edge case is also covered — apt failures with no classifiable lines are no longer swallowed even if a PPA URL appears in the output. (post-merge review on [PR #69](https://github.com/bivlked/amneziawg-installer/pull/69))

### Other

- 📚 **Docs: AWG 2.0 vs AWG 1.0 (S3/S4).** Added a FAQ entry to `ADVANCED.en.md` noting that an AmneziaWG 2.0 server with `S3>0` or `S4>0` is not compatible with AWG 1.0 clients (see upstream issue [`amnezia-vpn/amneziawg-linux-kernel-module#168`](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/issues/168)). My installer always generates `S3=8..55` and `S4=4..27` — both `>0` — so in the typical scenario (Amnezia VPN client + clients generated by `manage`) this does not surface. Risk only when manually importing the server preset into a WireGuard/AWG 1.0 client.

### Install

```bash
wget https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.11.5/install_amneziawg_en.sh
chmod +x install_amneziawg_en.sh
sudo bash ./install_amneziawg_en.sh
```

3 commands → ~20 minutes → a working VPN server with traffic obfuscation. Details — [README → Install](README.en.md#installation).

### Upgrading an existing server

Run the fresh `install_amneziawg_en.sh` — at step 5 `manage_amneziawg.sh` and `awg_common.sh` are refreshed automatically (with SHA256 verification). Full commands — [ADVANCED.en.md → Updating the scripts](ADVANCED.en.md#update-scripts-adv).

### Tests

**+13 new bats** (325 total, was 312 in v5.11.4):

- `test_v5115_regen_multiarg.bats` (+13) — RU/EN regen case iterates `ARGS[@]` (the headline fix for #70); `_regen_count` counter and the summary line `Обработано: N из M` / `Processed: N of M`; no regression: single-arg `regen <name>` and no-args `regen` behave as before; missing/invalid names yield a warning + `rc=1` and the batch keeps going; RU/EN structural parity on the regen branch control-flow tokens; `apt_update_tolerant` accepts the `--ppa-amnezia-tolerant` flag with `local ppa_tolerant=0` declared in both installers; step 2 calls the helper with that flag and `die`s on a hard error; the OOM / silent-crash guard via `raw_had_non_src_errors` is present in both installers; `SCRIPT_VERSION="5.11.5"` is bumped in all six files.

### Compatibility and dependencies

- **Fully backwards-compatible.** Single-arg `manage regen <name>` and no-args `manage regen` are unchanged; only the multi-arg path is affected — names that used to be silently dropped are now processed. Step 2 behaviour during a normal install is unchanged too — strict mode only triggers on a real hard apt error that would have blocked the install anyway.
- **No new dependencies.**

---

## [5.11.4] — 2026-05-04

**v5.11.4** — bug-fix release of the AmneziaWG 2.0 VPN installer: two fixes for issues reported on top of v5.11.3, no architectural changes. Support matrix unchanged: Ubuntu 24.04 / 25.10, Debian 12 / 13, x86_64 + ARM (Raspberry Pi, Oracle Ampere, Hetzner CAX).

### Highlights

- 🔑 **`vpn://` import into the Amnezia VPN app now carries the PSK.** With `manage add --psk` the PresharedKey was correctly written to the server `[Peer]` and the client `.conf` since v5.11.1, but the `vpn://` URI was missing the `psk_key` field that the AmneziaVPN parser reads — clients silently came up without the preshared key, the server (which had it) rejected the handshake, and `awg show transfer` stayed at «never». Also tightened trailing CR / space stripping for `PresharedKey =` and `AllowedIPs =` so CRLF configs edited on Windows no longer leak `\r` into the JSON. ([#67](https://github.com/bivlked/amneziawg-installer/issues/67), @haritos90)
- 🔁 **Install survives a brief Launchpad PPA outage.** When `ppa.launchpadcontent.net` is briefly unreachable (as on May 3rd per [#68](https://github.com/bivlked/amneziawg-installer/issues/68)), the installer now waits for `amneziawg-dkms` to show up in `apt-cache` for up to 3 attempts with 30 s and 60 s backoff (and a fresh `apt-get update` between retries). Checking `apt-cache` matters: `apt-get update` itself is tolerant to an unreachable InRelease (returns 0 even when the PPA never downloaded), so a plain rc-based retry would not catch this case. After three failures a friendly message points the user at the issue and explains this is a Launchpad infrastructure outage, not a script bug. ([#68](https://github.com/bivlked/amneziawg-installer/issues/68), @saligin / @baikov)

### Install

```bash
wget https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.11.4/install_amneziawg_en.sh
chmod +x install_amneziawg_en.sh
sudo bash ./install_amneziawg_en.sh
```

3 commands → ~20 minutes → a working VPN server with traffic obfuscation. Details — [README → Install](README.en.md#installation).

### Upgrading an existing server

Run the fresh `install_amneziawg_en.sh` — at step 5 `manage_amneziawg.sh` and `awg_common.sh` are refreshed automatically (with SHA256 verification). Full commands — [ADVANCED.en.md → Updating the scripts](ADVANCED.en.md#update-scripts-adv).

### Tests

**+16 new bats** (312 total, was 296 in v5.11.3):

- `test_v5114_psk_uri.bats` (+5) — happy path with PSK; no PSK → no `psk_key` field; indented `PresharedKey`; CRLF-edited config does not leak `\r` into the JSON; empty `PresharedKey =` line does not turn into `psk_key:""` (which would mismatch a server with a real PSK anyway).
- `test_v5114_ppa_retry.bats` (+11) — success on first attempt; retry until success; exhausting max attempts; exponential backoff doubling; 1800 s cap against arithmetic overflow; RU/EN structural parity of the helper; issue #68 link present in both installers.

### Compatibility and dependencies

- **Fully backwards-compatible.** On a stable network the retry helper adds zero delay — the first attempt passes and the rest of the run is unchanged. `manage add --psk` without `vpn://` import behaves the same as before (the PSK has always been written to the `.conf` correctly).
- **No new dependencies.** Just bash arithmetic and `sleep` — both standard.

---

## [5.11.3] — 2026-04-28

**v5.11.3** is a UX release for the AmneziaWG 2.0 VPN installer: five improvements driven by recent issues and discussions, no architectural changes. Ubuntu 24.04 / 25.10, Debian 12 / 13, x86_64 + ARM (Raspberry Pi, Oracle Ampere, Hetzner CAX) — supported as before.

### Highlights

- 🍎 **Shadowrocket on iOS / macOS now connects out of the box.** The `--psk` flag for `manage add` shipped in v5.11.1 but was not visible in the README — it is now in the Quick Reference and has its own FAQ entry. ([#62](https://github.com/bivlked/amneziawg-installer/issues/62), @andreykorobko)
- 📡 **Ping inside the tunnel — server ↔ clients** — a step-by-step recipe for UFW + `/etc/ufw/before.rules` in the FAQ. Explicit warning: `ufw allow ... proto icmp` does **not** work (UFW only supports `tcp/udp/esp/ah/gre/ipv6` via the `proto` flag). ([#63](https://github.com/bivlked/amneziawg-installer/discussions/63), @PavelVVrn)
- 🌐 **Mobile carrier → I1 map extended.** Megafon (regions) and Tele2 (Krasnoyarsk) updated to `I1=absent` — the AWG 1.0 fallback for carriers where CPS packets themselves trigger DPI blocks. Exact commands below the table (`systemctl restart awg-quick@awg0` + `manage regen <name>`). ([#42](https://github.com/bivlked/amneziawg-installer/issues/42), @alkorrnd)
- 🤖 **Auto-scripts for cron / Ansible / Proxmox.** `manage --yes` (flag) or `AWG_YES=1` (env) skip the confirm prompt in `remove`, `restore`, `restart`. Default behavior is unchanged (opt-in).
- 🗂️ **Backups without collisions.** Millisecond suffix in filenames (`awg_backup_2026-04-28_15-53-50.123.tar.gz`) protects against overwrite when two backups land in the same second (e.g., `regen → backup → modify → backup`). Legacy filenames (no `.NNN`) keep working.

### Install

```bash
wget https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.11.3/install_amneziawg_en.sh
chmod +x install_amneziawg_en.sh
sudo bash ./install_amneziawg_en.sh
```

3 commands → ~20 minutes → a working VPN server with traffic obfuscation. More — [README.en.md → Installation](README.en.md#installation).

### Upgrading an existing server

Re-run the latest `install_amneziawg_en.sh` — step 5 refreshes `manage_amneziawg.sh` and `awg_common.sh` automatically (with SHA256 verification). Full commands — [ADVANCED.en.md → How to Update Scripts](ADVANCED.en.md#update-scripts-adv).

### Tests

**+34 new bats** (295 total, up from 261 on v5.11.2):

- `test_yes_flag.bats` (+11) — extract `confirm_action` via `awk` + `eval`. Verifies that non-`"1"` values of `AWG_YES` (`"yes"`, `"true"`, `"0"`) do **not** match the bypass branch under forced-interactive mode.
- `test_backup_collision.bats` (+8) — `date +%3N` produces distinct values under rapid fire; `find` pattern and `sort -r` correctly handle both legacy and ms-suffix names in the same directory.
- `test_v5113_docs.bats` (+15) — invariants for the ICMP FAQ, the carrier table, the `--psk` highlight; protection against RU/EN cross-link drift in README → ADVANCED.

### Compatibility and dependencies

- **Fully backwards-compatible.** `--yes` is opt-in, default behavior unchanged. Backup ms-suffix is designed to coexist with legacy filenames. Downgrading to v5.11.2 is safe.
- **No new dependencies.** `date +%3N` (milliseconds) is part of standard GNU coreutils, available out of the box on Ubuntu/Debian.

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

[Unreleased]: https://github.com/bivlked/amneziawg-installer/compare/v5.18.3...HEAD
[5.18.4]: https://github.com/bivlked/amneziawg-installer/compare/v5.18.3...v5.18.4
[5.18.3]: https://github.com/bivlked/amneziawg-installer/compare/v5.18.2...v5.18.3
[5.18.2]: https://github.com/bivlked/amneziawg-installer/compare/v5.18.1...v5.18.2
[5.18.1]: https://github.com/bivlked/amneziawg-installer/compare/v5.18.0...v5.18.1
[5.18.0]: https://github.com/bivlked/amneziawg-installer/compare/v5.17.0...v5.18.0
[5.17.0]: https://github.com/bivlked/amneziawg-installer/compare/v5.16.1...v5.17.0
[5.16.1]: https://github.com/bivlked/amneziawg-installer/compare/v5.16.0...v5.16.1
[5.16.0]: https://github.com/bivlked/amneziawg-installer/compare/v5.15.6...v5.16.0
[5.15.6]: https://github.com/bivlked/amneziawg-installer/compare/v5.15.5...v5.15.6
[5.15.5]: https://github.com/bivlked/amneziawg-installer/compare/v5.15.4...v5.15.5
[5.15.4]: https://github.com/bivlked/amneziawg-installer/compare/v5.15.3...v5.15.4
[5.15.3]: https://github.com/bivlked/amneziawg-installer/compare/v5.15.2...v5.15.3
[5.15.2]: https://github.com/bivlked/amneziawg-installer/compare/v5.15.1...v5.15.2
[5.15.1]: https://github.com/bivlked/amneziawg-installer/compare/v5.15.0...v5.15.1
[5.15.0]: https://github.com/bivlked/amneziawg-installer/compare/v5.14.5...v5.15.0
[5.14.5]: https://github.com/bivlked/amneziawg-installer/compare/v5.14.4...v5.14.5
[5.14.4]: https://github.com/bivlked/amneziawg-installer/compare/v5.14.3...v5.14.4
[5.14.3]: https://github.com/bivlked/amneziawg-installer/compare/v5.14.2...v5.14.3
[5.14.2]: https://github.com/bivlked/amneziawg-installer/compare/v5.14.1...v5.14.2
[5.14.1]: https://github.com/bivlked/amneziawg-installer/compare/v5.14.0...v5.14.1
[5.14.0]: https://github.com/bivlked/amneziawg-installer/compare/v5.13.0...v5.14.0
[5.13.0]: https://github.com/bivlked/amneziawg-installer/compare/v5.12.1...v5.13.0
[5.12.1]: https://github.com/bivlked/amneziawg-installer/compare/v5.12.0...v5.12.1
[5.12.0]: https://github.com/bivlked/amneziawg-installer/compare/v5.11.5...v5.12.0
[5.11.5]: https://github.com/bivlked/amneziawg-installer/compare/v5.11.4...v5.11.5
[5.11.4]: https://github.com/bivlked/amneziawg-installer/compare/v5.11.3...v5.11.4
[5.11.3]: https://github.com/bivlked/amneziawg-installer/compare/v5.11.2...v5.11.3
[5.11.2]: https://github.com/bivlked/amneziawg-installer/compare/v5.11.1...v5.11.2
[5.11.1]: https://github.com/bivlked/amneziawg-installer/compare/v5.11.0...v5.11.1
[5.11.0]: https://github.com/bivlked/amneziawg-installer/compare/v5.10.2...v5.11.0
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
