# Install AmneziaWG VPN server on Ubuntu / Debian VPS

A step-by-step guide for deploying an AmneziaWG 2.0 VPN server on a clean Ubuntu or Debian VPS over SSH. Single bash command, no Docker, no web panel. Aimed at headless setups where you want a working DPI-resistant VPN with the lowest possible footprint on a cheap VPS.

> The official [Amnezia VPN](https://amnezia.org/) app deploys the server side for you in Docker. This guide takes a different route on purpose: AmneziaWG as a kernel module, no Docker overhead, and the whole server tuned and hardened for a single-purpose VPN. See [how it differs](https://bivlked.github.io/amneziawg-installer/compare/).

## TL;DR

- One command, MIT-licensed, fully self-hosted, no third-party dependencies at runtime.
- Works on Ubuntu 24.04 LTS, Ubuntu 25.10/26.04, Debian 12 (bookworm), Debian 13 (trixie).
- Built for cheap VPS budgets: $3 to $5 a month, 1 vCPU, 512 MB RAM minimum (1 GB recommended), 2 GB disk minimum (3+ GB recommended).
- Both x86_64 (amd64) and ARM64 (aarch64), with prebuilt kernel modules covering Raspberry Pi 4/5, Ubuntu 24.04/25.10 ARM64, and Debian 12/13 ARM64 (Hetzner CAX, Oracle Ampere A1, AWS Graviton all run on these stock kernels). Ubuntu 26.04 ARM64 builds the module from source via DKMS.
- DPI bypass for Russia (ТСПУ), Iran, China, school and corporate firewalls.
- Survives kernel upgrades automatically via DKMS auto-repair (since v5.12.0).
- Ubuntu 25.10 and 26.04 PPA fallback to noble is automatic since v5.13.0.

## Choosing a VPS

A VPN server is mostly idle CPU and steady network. Three picks I keep coming back to:

- **Hetzner CAX11 / CAX21** (ARM Ampere, EU). About €4 / month for 2 vCPU and 4 GB RAM. Wide bandwidth, EU jurisdiction, prebuilt ARM kernel module is published for this exact platform. The catch: Hetzner subnets are widely blacklisted by Russian carriers (TSPU, Rostelecom, MTS), so do not use Hetzner if you are routing Russian mobile traffic into the tunnel. Pick a non-Russia-blacklisted host for that case.
- **Oracle Cloud Always Free (ARM Ampere A1)**. 4 vCPU and 24 GB RAM in the free tier, no expiry, multiple regions. Reliable but capacity-limited (Oracle releases A1 quotas in waves).
- **Generic budget VPS** (Vultr, RackNerd, your local provider). Pick anything with 1 GB RAM, root SSH access, and not on a known-bad subnet for your audience. ARM is fine where prebuilts apply, otherwise amd64 with DKMS-built kernel module works the same way.

Country matters mostly for latency and jurisdiction. ARM versus amd64 has no real performance difference for a personal-scale VPN.

## OS choice

- **Ubuntu 24.04 LTS** is the best-tested platform. Default pick if you have no other preference.
- **Ubuntu 25.10** (questing) and **Ubuntu 26.04** work since v5.13.0. The PPA codename remaps to `noble` automatically when the running codename PPA is unreachable (404 or network failure). Resilient against do-release-upgrade from 24.04.
- **Debian 12** (bookworm) and **Debian 13** (trixie) are fully supported with codename mapping (focal and noble respectively).
- Use a minimal install. The script assumes the box is single-purpose and will strip modemmanager, snapd, cloud-init leftovers and similar to free resources.
- Avoid custom kernels (XanMod, Liquorix, Zen) on first install. DKMS compiles against the running kernel headers, but custom kernels can shift internal structs and trip a runtime panic. If you must, file a repro upstream rather than guessing.

## One-command install

Connect as root (or as a sudo-capable user and prepend `sudo`). The installer usually detects the SSH port automatically and allows it in UFW. If SSH runs on a non-standard port or autodetection is unavailable, pass `--ssh-port=YOUR_PORT` to the installer (comma-separated for several ports). As an extra conservative safeguard you can allow the port in UFW **before** running the installer:

```bash
sudo ufw allow <your-ssh-port>/tcp
```

Then:

```bash
wget -O install_amneziawg_en.sh https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.18.1/install_amneziawg_en.sh
chmod +x install_amneziawg_en.sh
sudo bash ./install_amneziawg_en.sh
```

The script walks through OS detection, base packages, PPA setup, kernel module install (DKMS or ARM prebuilt), UFW firewall, sysctl hardening, Fail2Ban, AmneziaWG service start, and default client config generation. Expect two reboots and 15 to 25 minutes of wall-clock time, mostly bound by `apt` and the kernel module build.

The script is **idempotent and resume-safe**: after each reboot, run the same command again and it picks up from where it left off. State lives in `/root/awg/setup_state`.

For a non-interactive run pass `--yes` and the routing flag of your choice, e.g. `sudo bash ./install_amneziawg_en.sh --yes --route-amnezia`. Common flags: `--port=39743`, `--subnet=10.9.9.1/24`, `--disallow-ipv6`, `--allow-ipv6-tunnel` (dual-stack IPv6 inside the tunnel), `--preset=mobile`, `--endpoint=<public-IP>` (required when the server's public IP differs from its interface IP, typical on Oracle Cloud, GCP, or any NAT'd cloud setup). Full CLI: `--help` or [ADVANCED.en.md](ADVANCED.en.md#install-cli-adv).

## First-time client setup

The default install creates two clients (`my_phone`, `my_laptop`) so you can connect immediately. To add more:

```bash
sudo bash /root/awg/manage_amneziawg.sh add my_iphone
```

The client import files land in `/root/awg/`:

- `<name>.conf` for desktop AmneziaWG clients, Linux `wg-quick`, and routers.
- `<name>.png` QR code for the Amnezia VPN mobile app.
- `<name>.vpnuri` and `<name>.vpnuri.png` for one-tap import into the Amnezia VPN app via clipboard or scanned QR.

Pull files down with `scp`:

```bash
scp root@SERVER_IP:/root/awg/my_iphone.conf .
```

Verify the handshake from the server side with `sudo awg show awg0` after the client connects. The `latest handshake` line should refresh every minute. If you need PresharedKey for Shadowrocket on iOS or macOS, add the `--psk` flag during `manage add`.

## Update flow

Updating to a newer installer release on a server that already has a supported version running:

```bash
wget -O install_amneziawg_en.sh https://raw.githubusercontent.com/bivlked/amneziawg-installer/vX.Y.Z/install_amneziawg_en.sh
sudo bash ./install_amneziawg_en.sh --force
```

The `--force` flag (or `AWG_FORCE_REINSTALL=1`) is required when reinstalling over an already-running AmneziaWG service, so an accidental re-run on a healthy box does not destroy state. First-time installs do not need it. Server keys, peer list, and obfuscation parameters survive a reinstall.

A normal `apt-get upgrade` will pull a new kernel from time to time. For DKMS-based installs (typical for amd64 and most ARM64 deployments without a prebuilt for the new kernel), `amneziawg-ensure-module` rebuilds the module transparently at the next boot. Check its log with `journalctl -u amneziawg-ensure-module.service -b` or read the rolling apt-hook log at `/var/log/amneziawg-ensure-module.log`. Manual recovery if all three safety nets miss: `sudo bash /root/awg/manage_amneziawg.sh repair-module` reinstalls headers, rebuilds DKMS, and restarts the service. ARM users running an ARM prebuilt should rerun the installer after a kernel upgrade so it picks a fresh prebuilt or falls back to DKMS.

## Uninstall

```bash
sudo bash ./install_amneziawg_en.sh --uninstall
```

The uninstall path is symmetric: it removes the AmneziaWG service, the kernel module via DKMS, the PPA, the AmneziaWG-specific UFW rules (reverting to the pre-install UFW state via a marker file), Fail2Ban jails, and `/root/awg/`, `/etc/amnezia/`. Manage script and shared library go too. Re-installing later starts from a clean slate.

## Troubleshooting

- **PPA 404 on Ubuntu 25.10 or 26.04.** Automatic fallback to noble since v5.13.0. If you are still on v5.12.x, upgrade the installer.
- **DKMS build fails on stale kernel headers** (typical after `do-release-upgrade` 24.04 to 25.10). v5.13.0 detects stale headers (kernel version differs from the running kernel) and installs gcc-13 as a fallback compiler so DKMS autoinstall succeeds across the version mismatch. If DKMS still fails, `sudo bash /root/awg/manage_amneziawg.sh repair-module` forces a rebuild.
- **Mobile carrier unstable or only connects on the third attempt.** Reinstall with `--preset=mobile`. Tested carriers (Russia): Yota (Moscow), Tele2 (Moscow), Tattelecom / Letai (Tatarstan), Beeline (default preset). Tele2 (Krasnoyarsk) and Megafon (regional networks) need `--preset=mobile` plus the I1 parameter removed. Full per-carrier table and the underlying Jc / Jmin / Jmax mechanics are in [ADVANCED.en.md FAQ](ADVANCED.en.md#faq-advanced-adv).
- **Handshake completes but no packets flow.** Almost always the AllowedIPs gotcha on a custom split-tunnel config. Cover the server subnet too, not just the destinations you want. See [ADVANCED.en.md AllowedIPs](ADVANCED.en.md#allowedips-adv).
- **iPhone does not connect over cellular.** MTU issue. The installer sets `MTU = 1280` by default since v5.7.4; older configs need the line added manually. See [MTU and Mobile Clients](ADVANCED.en.md#mtu-mobile-adv).
- **ARM prebuilt unavailable for your kernel.** The installer falls back to DKMS automatically since v5.12.1. If both fail, file an issue with `sudo bash ./install_amneziawg_en.sh --diagnostic` output.

## Where to ask

- **Bug reports**: [GitHub Issues](https://github.com/bivlked/amneziawg-installer/issues).
- **Usage questions, deployment quirks**: [GitHub Discussions](https://github.com/bivlked/amneziawg-installer/discussions).
- **Feature requests**: vote on [Roadmap #79](https://github.com/bivlked/amneziawg-installer/issues/79) with a thumbs-up.

## Related reading

- [Hetzner Community: Making a website accessible from restricted regions](https://community.hetzner.com/tutorials/making-website-accessible-from-restricted-regions) - Hetzner tutorial that references this installer.
- [Pinggy: Top 5 Best Self-Hosted VPNs in 2026](https://pinggy.io/blog/top_5_best_self_hosted_vpns/) - third-party listing.
- [VPN Status (RU): AmneziaWG catalog](https://vpnstatus.site/protocols/amneziawg) - Russian-language directory of AmneziaWG server-side options.
- [LowEndTalk Tutorial #217191](https://lowendtalk.com/discussion/217191) - the short version of this guide, with reader Q&A.
- [README.en.md](README.en.md) - project overview, full feature list, FAQ, and the comparison with similar tools.
- [ADVANCED.en.md](ADVANCED.en.md) - full FAQ, mobile carrier presets, AWG 2.0 parameter reference, troubleshooting deep-dive.
