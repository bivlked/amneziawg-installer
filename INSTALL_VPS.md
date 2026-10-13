# Install AmneziaWG VPN server on Ubuntu / Debian VPS

A step-by-step guide for deploying an AmneziaWG VPN server (3.1 by default, 2.0 for older clients) on a clean Ubuntu or Debian VPS over SSH. Single bash command, no Docker, no web panel. Aimed at headless setups where you want a working DPI-resistant VPN with the lowest possible footprint on a cheap VPS.

> The official [Amnezia VPN](https://amnezia.org/) app deploys the server side for you in Docker. This guide takes a different route on purpose: AmneziaWG as a kernel module, no Docker overhead, and the whole server tuned and hardened for a single-purpose VPN. See [how it differs](https://bivlked.github.io/amneziawg-installer/compare/).

## TL;DR

- A fresh install gets **AmneziaWG 3.1**: header encryption and extra padding on top of the usual obfuscation. Routers on stock firmware, Hiddify and apps that have not been updated need `--protocol=2.0`.
- One command, MIT-licensed, fully self-hosted: no third-party service carries your traffic or holds your keys. During install and updates the server downloads packages (your distribution's mirrors, the Amnezia PPA on Launchpad) and the installer's own scripts from GitHub, plus ARM prebuilt modules or the pinned 2.0 module source where they are needed. When a client config is made without `--endpoint`, it asks a public-IP lookup service (api.ipify.org and fallbacks) for its address.
- 3.1 out of the box on x86_64 with Ubuntu 24.04 LTS, Ubuntu 26.04 LTS or Debian 13 (trixie). A stock Debian 12 (bookworm, kernel 6.1) works too, on 2.0, but it is past regular support; Ubuntu 25.10 is not supported since v6.0.0. Details below.
- Built for cheap VPS budgets: $3 to $5 a month, 1 vCPU, 512 MB RAM minimum (1 GB recommended), 2 GB disk minimum (3+ GB recommended). It needs a full virtual machine (KVM or similar) or bare metal: in a container (OpenVZ, LXC, Docker) the installer stops.
- ARM64 (aarch64) works too, on AmneziaWG 2.0, with prebuilt kernel modules for Raspberry Pi 4/5, Ubuntu 24.04 ARM64 and Debian 12/13 ARM64 (Hetzner CAX, Oracle Ampere A1 and AWS Graviton run these stock kernels). Ubuntu 26.04 ARM64 builds the module from source via DKMS.
- DPI bypass for Russia (ТСПУ), Iran, China, school and corporate firewalls. No guarantees: the result depends on the network and the parameters.
- Survives kernel upgrades: with DKMS the module is rebuilt at the next boot. On ARM with a prebuilt module there is no DKMS: after a kernel change, run the installer again ([details](#update-flow)).

## Choosing a VPS

A VPN server is mostly idle CPU and steady network. What to look for:

- **A full virtual machine (KVM or similar) on x86_64 (amd64)** with 1 GB RAM and root SSH access: this is what gets AmneziaWG 3.1. Any budget provider will do (Vultr, RackNerd, your local host), as long as its addresses are not on a known-bad subnet for your audience. Containers (OpenVZ, LXC, Docker) cannot load a kernel module, and the installer stops in them; for a container there is the userspace route in [ADVANCED](ADVANCED.en.md#lxc-userspace-adv).
- **ARM hosts** work fine, but the installer sets up AmneziaWG 2.0 there. Two common ones: Hetzner CAX11 / CAX21 (about €4 a month for 2 vCPU and 4 GB RAM, EU) and Oracle Cloud Always Free (Ampere A1, 4 vCPU and 24 GB RAM, capacity released in waves). A prebuilt ARM kernel module is published for both.
- **Hetzner and Russian carriers.** Hetzner subnets are widely blacklisted by Russian carriers (TSPU, Rostelecom, MTS), so do not use Hetzner if you are routing Russian mobile traffic into the tunnel. Pick a host that is not blacklisted for that case.

Country matters mostly for latency and jurisdiction. For a personal VPN, ARM versus amd64 makes no real speed difference; it decides the protocol generation, as above.

**Check that your host gives you an emergency console, and that it works.** It is the simplest way back in if SSH stops answering after a reboot or because of a firewall rule. Without one, recovery means provider support, a snapshot rollback or a reinstall.

## OS choice

**Which systems get 3.1:** Ubuntu 24.04, Ubuntu 26.04 and Debian 13 on x86_64. On a stock Debian 12 (kernel 6.1) and on ARM the installer sets up 2.0 by itself: it issues the 3.1 profile only on x86_64 with kernel 6.7 or newer, a deliberately cautious choice for platforms that have not been measured yet ([where 2.0 is installed instead](ADVANCED.en.md#awg3-fallback-adv)).

- **Ubuntu 24.04 LTS** is the best-tested platform. Default pick if you have no other preference. The HWE kernel 7.0.0-38 is supported: the installer fixes the PPA module source itself ([details](ADVANCED.en.md#kernel-70-backport-adv)).
- **Ubuntu 26.04 LTS** is supported. The PPA publishes packages for it (`resolute`); if the PPA does not answer for a release, the installer falls back to `noble` by itself. The PPA module does not build for the 26.04 kernel 7.0.0-38 on its own; the installer fixes its source itself ([details](ADVANCED.en.md#kernel-70-backport-adv)). An upgrade from 24.04 with `do-release-upgrade` works too.
- ❌ **Ubuntu 25.10** (questing) is not supported since v6.0.0. Ubuntu itself stopped supporting it on 2026-07-01, and being an interim release it gets no extended support either: no security updates of any kind are published for it. The installer treats it as an untested release: it warns and asks for confirmation (`--yes` carries on without asking). Move the box to 26.04 LTS with `do-release-upgrade` and run the latest installer again, or reinstall on 24.04 LTS or Debian 13.
- **Debian 13** (trixie) is fully supported, with the codename mapped to `noble`.
- ⚠️ **Debian 12** (bookworm) is just as fully supported by the installer, with the codename mapped to `focal`. Debian itself ended regular support on 2026-07-11; security updates continue through Debian LTS until 2028-06-30, so the system is still patched, though no longer by the main team. Prefer Debian 13 for a new server. On a stock Debian 12 (kernel 6.1) the installer sets up AmneziaWG 2.0: it issues 3.1 only on kernel 6.7 or newer, so here it builds a pinned 2.0 module from source ([details](ADVANCED.en.md#debian-support-adv)).
- Use a minimal install. The script assumes the box is single-purpose and will strip modemmanager, snapd, cloud-init leftovers and similar to free resources.
- Avoid custom kernels (XanMod, Liquorix, Zen) on first install. DKMS compiles against the running kernel headers, but custom kernels can shift internal structs and end in a kernel panic. If you must, file a repro upstream rather than guessing.

## One-command install

Connect as root (or as a sudo-capable user and prepend `sudo`). The installer usually detects the SSH port automatically and allows it in UFW. If SSH runs on a non-standard port or autodetection is unavailable, pass `--ssh-port=YOUR_PORT` to the installer (comma-separated for several ports). As an extra conservative safeguard you can allow the port in UFW **before** running the installer:

```bash
sudo ufw allow <your-ssh-port>/tcp
```

Then run the installer. It sets up AmneziaWG 3.1; if one of your devices is a router on stock firmware or uses Hiddify, read **Protocol generation** below first, because changing the generation later means a reinstall and new profiles for every client.

```bash
wget -O install_amneziawg_en.sh https://github.com/bivlked/amneziawg-installer/releases/latest/download/install_amneziawg_en.sh
chmod +x install_amneziawg_en.sh
sudo bash ./install_amneziawg_en.sh
```

**Protocol generation.** A new install gets AmneziaWG 3.1 by default: header encryption (`HeaderProtectionKey`) and extra padding (`ContentPaddingAddition`) on top of the usual obfuscation. A client without 3.1 support will not connect to such a server, so if you have one - a router on stock firmware (stable KeeneticOS, OpenWrt with an old amneziawg package), Hiddify, an app that has not been updated for a long time - install on 2.0 from the start:

```bash
sudo bash ./install_amneziawg_en.sh --protocol=2.0
```

On kernels older than 6.7 (a stock Debian 12) and on ARM, the installer installs 2.0 by itself and says why. Where the installed awg tools or the kernel module do not understand 3.1 parameters, it switches to 2.0 if the module accepts the 2.0 set, and otherwise stops and says what to fix (for old tools, the package to upgrade). The final report names the generation on the "Protocol generation" line. Which clients understand 3.1: [client table](ADVANCED.en.md#client-gen-adv); the details of both profiles: [ADVANCED.en.md](ADVANCED.en.md#awg3-fallback-adv).

The script walks through OS detection, base packages, PPA setup, kernel module install (DKMS or ARM prebuilt), UFW firewall, sysctl hardening, Fail2Ban, AmneziaWG service start, and default client config generation. Expect two reboots and 15 to 25 minutes of wall-clock time, mostly bound by `apt` and the kernel module build.

The script is **idempotent and resume-safe**. When it asks "Reboot now? [y/N]", answer `y` (Enter means no, and you reboot by hand). The SSH session drops; wait a minute or two, log in again and run the same command with the same flags: it picks up from where it left off. State lives in `/root/awg/setup_state`. Two reboots are part of the normal flow:

```mermaid
flowchart LR
    A["Steps 0-1<br/>params, system prep"] --> R1(("reboot"))
    R1 --> B["Step 2<br/>kernel module"]
    B --> R2(("reboot"))
    R2 --> C["Steps 3-7<br/>firewall, configs, service"]
    C --> D["VPN ready"]
```

The first run asks for the port, the tunnel subnet, IPv6, the routing mode, client isolation and the server name shown in the Amnezia app; Enter takes the value shown in brackets. Two questions are easy to miss. Along the way the script lists the packages it would remove (snapd, unattended-upgrades and others) and asks first; answer `n` or pass `--keep-packages` to keep them. If UFW is not on yet, the third run asks "Enable UFW? [y/N]": answer `y`, because pressing Enter leaves the server without a firewall.

For a non-interactive run pass `--yes`: `sudo bash ./install_amneziawg_en.sh --yes`. The routing mode then falls back to the default, the packages are removed and UFW is enabled without asking.

**Routing modes** (what goes into the tunnel):

| Flag | Mode | When to pick it |
|---|---|---|
| `--route-all` | "All traffic" (`0.0.0.0/0`) | the default, the full-tunnel form clients expect |
| `--route-amnezia` | "Amnezia", a subnet list | when the private networks must stay out of the tunnel |
| `--route-custom=NETS` | "Custom" | when the subnet list is your own |

⚠️ The "Amnezia" mode sends the same public IPv4 into the tunnel as the full tunnel does: the only difference is the private networks, which stay outside. But the Amnezia app reads such a list as split routing already configured on the server and disables its own split-tunneling page, and a Linux client can loop its routes on it. That is why `--route-all` is the default. The details: [ADVANCED, AllowedIPs](ADVANCED.en.md#allowedips-adv).

Common flags:

- `--port=39743` - any port 1-65535;
- `--subnet=10.9.9.1/24`;
- `--disallow-ipv6`;
- `--allow-ipv6-tunnel` - dual-stack IPv6 inside the tunnel;
- `--mobile` - the mobile obfuscation preset plus port 443/udp in one flag; an explicit `--port` wins;
- `--isolation=on|off` - client-to-client isolation, on by default;
- `--endpoint=<public-IP>` - required when the server's public IP differs from its interface IP, typical on Oracle Cloud, GCP, or any NAT'd cloud setup.

Full CLI: `--help` or [ADVANCED.en.md](ADVANCED.en.md#install-cli-adv).

## First-time client setup

The default install creates two clients (`my_phone`, `my_laptop`) so you can connect immediately. To add more:

```bash
sudo bash /root/awg/manage_amneziawg.sh add my_iphone
```

All client files land in `/root/awg/`. There are four of them, and they are not interchangeable:

| File | What it is for |
|---|---|
| `<name>.conf` | text config: AmneziaWG desktop clients, Linux `awg-quick`, routers |
| `<name>.png` | QR code of that same `.conf`, for AmneziaWG clients with QR import (a plain WireGuard client cannot import it) |
| `<name>.vpnuri` | the `vpn://` link for the Amnezia VPN app |
| `<name>.vpnuri.png` | QR code of the `vpn://` link, for the Amnezia VPN app |

**The two QR codes are easy to mix up.** `<name>.png` holds the config text, `<name>.vpnuri.png` holds the `vpn://` link. The Amnezia VPN app expects `<name>.vpnuri.png`; do not scan `<name>.png` in it. More: [ADVANCED, import via vpn://](ADVANCED.en.md#vpnuri-adv).

The installer does not print a QR code in the terminal; it saves the files. Copy them to your computer by running `scp` **on your own computer, not in the SSH session on the server** (PowerShell works on Windows):

```bash
scp root@SERVER_IP:/root/awg/my_iphone.conf .
scp root@SERVER_IP:/root/awg/my_iphone.png .
scp root@SERVER_IP:/root/awg/my_iphone.vpnuri.png .
```

With a non-standard SSH port, `scp` takes it as `-P` (capital P):

```bash
scp -P YOUR_SSH_PORT root@SERVER_IP:/root/awg/my_iphone.conf .
```

Which app to put on which device (for a 3.1 server each of them needs a version with 3.1 support, see the [client table](ADVANCED.en.md#client-gen-adv)):

| Device | App | What to import |
|---|---|---|
| Android | WG Tunnel or AmneziaWG | open `<name>.png` on your computer screen; in the app tap "+", then scan the QR code |
| iPhone, iPad | AmneziaWG | `<name>.png` (QR code) or `<name>.conf` |
| Mac | AmneziaWG | `<name>.conf` |
| Windows | AmneziaWG | `<name>.conf` |
| any platform, Linux included | Amnezia VPN (not in the Russian App Store) | `<name>.vpnuri.png`: "Add VPN", then "Scan QR code"; or the `vpn://` text from `sudo cat /root/awg/<name>.vpnuri` via "Paste from clipboard" |
| Linux | `awg-quick`; the AmneziaWG module (or amneziawg-go) and tools on the client must support 3.1 | `<name>.conf`, brought up with `awg-quick up` ([Linux client](ADVANCED.en.md#linux-client-adv)) |

On Android, WG Tunnel and AmneziaWG are what we recommend: in our check on 13 October 2026 they reconnected in under a second and kept the tunnel across a Wi-Fi to mobile data switch (iPhone was not part of that check). If the Amnezia VPN scanner does not recognize the code (it did not on Android with 5.0.3), read the code with the phone's regular camera and paste the copied `vpn://` text. If you need PresharedKey for Shadowrocket on iOS or macOS, add the `--psk` flag during `manage add`.

**Check that it works.** After the client connects, `sudo awg show awg0` on the server should show a `latest handshake` within the last two or three minutes, and a "what is my IP" page on the client should show the server's address (in the custom routing mode, only if that site is in your list of networks). `sudo bash /root/awg/manage_amneziawg.sh check` reports the server's health and its protocol generation ("Installation protocol generation").

## What next

- Add or remove people: `add <name>`, `remove <name>`, `list`, `stats`.
- Time-limited access: `add guest --expires=7d`.
- Reissue a lost config: `regen <name>` (the keys stay the same). If a config leaked, revoke it instead: `remove <name>`, then `add <name>` and hand out the new file.
- Back up before experiments: `backup`, and `restore` to go back.
- Check server health: `check`.
- Drive the server from scripts: the management commands take `--json` and reply with a single JSON object even when they fail; add `--yes` for unattended runs ([JSON interface](ADVANCED.en.md#json-api-adv)).

All of them run as `sudo bash /root/awg/manage_amneziawg.sh <command>`. Common next steps: [two-server cascade](CASCADE.en.md), [Russian sites through WARP](WARP-RU.en.md).

## Update flow

Updating to a newer installer release on a server that already has a supported version running:

```bash
wget -O install_amneziawg_en.sh https://github.com/bivlked/amneziawg-installer/releases/latest/download/install_amneziawg_en.sh
sudo bash ./install_amneziawg_en.sh --force
```

Set aside a few minutes for this. A reinstall walks the state machine from the top, so the box reboots twice, once after the system-update step and once after the kernel-module step, and you run the same command again after each reboot. Step 1 is replayed in full along the way: package cleanup, sysctl tuning, swap and BBR. The tunnel is down across those reboots, but nothing that clients hold is touched.

The `--force` flag (or `AWG_FORCE_REINSTALL=1`) is required when reinstalling over an already-running AmneziaWG service, so an accidental re-run on a healthy box does not destroy state. First-time installs do not need it. Server keys, peer list, and obfuscation parameters survive a reinstall, and so does the protocol generation. Since v5.21.0 the script pair is protected against drift: update one half and forget the other, and the scripts stop with the exact commands to fetch the missing piece, instead of throwing strange errors halfway through.

That is what keeps an update invisible to your users: config files and QR codes handed out earlier stay valid, and existing clients are preserved rather than recreated, the default `my_phone` and `my_laptop` included. One exception is worth remembering. Passing `--mobile`, `--preset`, `--jc`, `--jmin` or `--jmax` regenerates the whole `Jc`/`S`/`H`/`I1` set, while `--port` (as well as `--mobile`, which sets 443) changes the port. Either way every config issued before that stops connecting until you re-issue it with `sudo bash /root/awg/manage_amneziawg.sh regen` and hand it out again. `--endpoint` changes the address only in configs issued afterwards: the old ones keep the previous address and work as long as it still reaches the server, and they get the new one after `regen`. Leave those flags off when you are only updating. And if all you want is the newer management commands, `--force` is not needed at all: replacing the two scripts on the server is enough, and the installer only has to be re-run when the installer itself changed.

**Moving an existing server to 3.1.** An update keeps the generation: a server installed before version 6.0.0 stays on AmneziaWG 2.0. To move it to 3.1, make a backup with `manage_amneziawg.sh backup` and copy it to your own computer (`--uninstall` deletes `/root/awg/backups/`, see [Uninstall](#uninstall)), run `--uninstall`, install again with the latest installer and hand out new profiles to every client: profiles of the old generation do not connect to the new server. That backup is only for going back to 2.0: restoring it returns the server to 2.0 (`restore` warns about this before it stops the service, but does not stop you). The way back, from 3.1 to 2.0, is the same with `--protocol=2.0`.

A normal `apt-get upgrade` will pull a new kernel from time to time. For DKMS-based installs (typical for amd64 and for ARM64 without a prebuilt for the new kernel), `amneziawg-ensure-module` rebuilds the module transparently at the next boot. Check its log with `journalctl -u amneziawg-ensure-module.service -b` or read the rolling apt-hook log at `/var/log/amneziawg-ensure-module.log`. If the automatic rebuild did not help, `sudo bash /root/awg/manage_amneziawg.sh repair-module` reinstalls headers, rebuilds DKMS, and restarts the service.

**ARM with a prebuilt module works differently, and it is worth knowing in advance.** On that path neither DKMS nor kernel headers are installed, and the `amneziawg-ensure-module` service is not created, so there is no rebuild at boot and no log to read. A prebuilt module is built for one kernel version: after a kernel change the tunnel does not come up (`awg-quick@awg0` goes to `failed`, there is no `awg0` interface) and does not recover by itself. `repair-module` cannot replace a missing prebuilt module either. Run the installer again: it picks a package for the new kernel or falls back to DKMS.

## Uninstall

🔴 **The irreversible part first.** Uninstalling wipes `/root/awg/` entirely, and with it the server keys and every client config. Clients you handed files to stop connecting. If you may need the server later, make a copy **before** uninstalling and take it off the machine: run `sudo bash /root/awg/manage_amneziawg.sh backup` on the server, then `scp root@SERVER_ADDRESS:/root/awg/backups/*.tar.gz .` on your own computer. The uninstaller also offers a backup and makes one by default, but it can be declined or fail (the uninstall then continues), and it stays on the same server.

If the server runs the cascade or WARP, remove them first, following their own guides: [cascade](CASCADE.en.md#uninstall), [WARP](WARP-RU.en.md#uninstall).

Then uninstall:

```bash
sudo bash ./install_amneziawg_en.sh --uninstall
```

What `--uninstall` does:
- stops and disables `awg-quick@awg0`, unloads the module, and removes the `amneziawg-ensure-module` unit, hook and log;
- purges `amneziawg-dkms`, `amneziawg-tools` and `qrencode`, plus `fail2ban` only if the installer added it;
- on ARM, purges the prebuilt module package `amneziawg-kmod-*` (if that fails, it prints the command to remove it by hand);
- removes the PPA and its key, `/etc/apt/apt.conf.d/99-amneziawg-lock-timeout`, `/etc/amnezia/`, `/etc/modules-load.d/amneziawg.conf`, its sysctl files, `/etc/cron.d/awg-expiry`, its Fail2Ban jail, the DKMS registration and `/root/awg/`, including the backups in `/root/awg/backups/`;
- in UFW removes the VPN port rule and the `awg0` forwarding rule; it turns UFW off only if the installer turned it on.

What stays:
- the uninstaller's archive `/root/awg_uninstall_backup_<date>.tar.gz` with every server and client key, and the log `/root/awg_uninstall.log`: archives accumulate, one per uninstall, so if you no longer need the server, copy the archive to your own machine and delete it from the server;
- the dependencies: `dkms`, `build-essential`, `dpkg-dev`, kernel headers, `wireguard-tools`, `ufw`, plus `git`, `gcc-13` and `python3-systemd` if they were installed;
- `/swapfile` and its line in `/etc/fstab`;
- packages removed during the install, which you have to reinstall by hand (`sudo apt install unattended-upgrades` and so on);
- the SSH rule in UFW if UFW was active before the install, and rules you added yourself;
- the sysctl values, until the next reboot.

Re-installing later starts from a clean slate. Already uninstalled and need it back? Look for the uninstaller's archive: `ls -la /root/awg_uninstall_backup_*.tar.gz`. It holds the server keys, the keys and configs of every client and the server config.

## Troubleshooting

- **A client does not connect to a new server, and shows no error.** Most often the client does not support AmneziaWG 3.1: check the app version against the [client table](ADVANCED.en.md#client-gen-adv), and `manage_amneziawg.sh check` for the server's generation. For a router or Hiddify that cannot be updated, the server has to be reinstalled with `--protocol=2.0`.
- **PPA 404 on an Ubuntu release the PPA publishes nothing for.** The installer checks whether the PPA answers for the codename and switches to `noble` itself when it does not.
- **DKMS build fails on stale kernel headers** (typical after a `do-release-upgrade`, for example 24.04 to 26.04). The installer detects stale headers (kernel version differs from the running kernel) and installs gcc-13 as a fallback compiler so DKMS autoinstall succeeds across the version mismatch. If DKMS still fails, `sudo bash /root/awg/manage_amneziawg.sh repair-module` forces a rebuild.
- **Mobile carrier unstable or only connects on the third attempt.** On a new server, install with `--mobile` - it enables the mobile obfuscation preset and moves the port to 443/udp in one flag (carriers often drop unfamiliar UDP ports; an explicit `--port` wins if you pass both). On a running server that is a `--force --mobile` reinstall, after which every client config has to be reissued with `regen`; if the handshake never completes at all, read [the walkthrough](ADVANCED.en.md#no-hs-mobile-adv) first. Tested carriers (Russia): Yota (Moscow), Tele2 (Moscow), Tattelecom / Letai (Tatarstan), Beeline (default preset). Tele2 (Krasnoyarsk) needed `I1 = <r 48>` in May 2026, and Megafon (regional networks) needed I1 removed. Full per-carrier table and the underlying Jc / Jmin / Jmax mechanics are in [ADVANCED.en.md FAQ](ADVANCED.en.md#faq-mobile-unstable-adv).
- **Handshake completes but no packets flow.** Almost always the AllowedIPs gotcha on a custom split-tunnel config. Cover the server subnet too, not just the destinations you want. See [ADVANCED.en.md AllowedIPs](ADVANCED.en.md#allowedips-adv).
- **iPhone does not connect over cellular.** MTU issue. The installer sets `MTU = 1280` by default; configs issued before v5.7.4 need the line added manually. See [MTU and Mobile Clients](ADVANCED.en.md#mtu-mobile-adv).
- **ARM prebuilt unavailable for your kernel.** The installer falls back to DKMS automatically. If both fail, file an issue with `sudo bash ./install_amneziawg_en.sh --diagnostic` output.
- **Nothing answers at all, not even SSH or ping.** That is not the VPN. Check the address itself, ideally from another network: if the whole address is unreachable, no obfuscation setting will help.

## Where to ask

- **Bug reports**: [GitHub Issues](https://github.com/bivlked/amneziawg-installer/issues).
- **Usage questions, deployment quirks**: [GitHub Discussions](https://github.com/bivlked/amneziawg-installer/discussions).
- **Feature requests**: vote on [Roadmap #79](https://github.com/bivlked/amneziawg-installer/issues/79) with a thumbs-up.

## Related reading

- [INSTALL_VPS.ru.md](INSTALL_VPS.ru.md) - the same guide in Russian.
- [CASCADE.en.md](CASCADE.en.md) - two-server cascade: Russian traffic direct, the rest abroad.
- [WARP-RU.en.md](WARP-RU.en.md) - Russian sites through Cloudflare WARP on the same server.
- [Hetzner Community: Making a website accessible from restricted regions](https://community.hetzner.com/tutorials/making-website-accessible-from-restricted-regions) - Hetzner tutorial that references this installer.
- [Pinggy: Top 5 Best Self-Hosted VPNs in 2026](https://pinggy.io/blog/top_5_best_self_hosted_vpns/) - third-party listing.
- [VPN Status (RU): AmneziaWG catalog](https://vpnstatus.site/protocols/amneziawg) - Russian-language directory of AmneziaWG server-side options.
- [LowEndTalk Tutorial #217191](https://lowendtalk.com/discussion/217191) - the short version of this guide, with reader Q&A.
- [README.en.md](README.en.md) - project overview, full feature list, FAQ, and the comparison with similar tools.
- [ADVANCED.en.md](ADVANCED.en.md) - full FAQ, mobile carrier presets, AmneziaWG 2.0 and 3.1 parameter reference, troubleshooting deep-dive.
