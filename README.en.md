<a id="top"></a>
<p align="center">
  <b>RU</b> <a href="README.md">Русский</a> | <b>EN</b> English
</p>

<p align="center"><em>One-command VPN that works where WireGuard gets blocked — self-hosted on any $3 VPS</em></p>

<p align="center">
  <img src="logo.jpg" alt="AmneziaWG 2.0 VPN Installer — Ubuntu, Debian, Raspberry Pi, ARM64, mobile carrier optimization" width="600">
</p>

<p align="center">
  <strong>A set of Bash scripts for one-command installation, secure hardening,<br>
  and easy management of an AmneziaWG 2.0 VPN server on Ubuntu (24.04 LTS / 25.10) and Debian (12 / 13)</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Ubuntu-24.04_|_25.10-orange" alt="Ubuntu 24.04 | 25.10">
  <img src="https://img.shields.io/badge/Debian-12_|_13-A81D33" alt="Debian 12 | 13">
  <img src="https://img.shields.io/badge/Architecture-x86__64_|_ARM64_|_ARMv7-green" alt="x86_64 | ARM64 | ARMv7">
  <a href="https://github.com/bivlked/amneziawg-installer/blob/main/LICENSE"><img src="https://img.shields.io/github/license/bivlked/amneziawg-installer" alt="License"></a>
  <img src="https://img.shields.io/badge/Status-Stable-success" alt="Status">
  <a href="https://github.com/bivlked/amneziawg-installer/releases"><img src="https://img.shields.io/badge/Installer_Version-5.11.3-blue" alt="Version"></a>
  <img src="https://img.shields.io/badge/AmneziaWG-2.0-blueviolet" alt="AWG 2.0">
  <a href="https://github.com/bivlked/amneziawg-installer/actions/workflows/shellcheck.yml"><img src="https://github.com/bivlked/amneziawg-installer/actions/workflows/shellcheck.yml/badge.svg" alt="ShellCheck"></a>
  <a href="https://github.com/bivlked/amneziawg-installer/actions/workflows/test.yml"><img src="https://github.com/bivlked/amneziawg-installer/actions/workflows/test.yml/badge.svg" alt="Tests"></a>
  <a href="https://github.com/bivlked/amneziawg-installer/stargazers"><img src="https://img.shields.io/github/stars/bivlked/amneziawg-installer?style=flat" alt="Stars"></a>
  <a href="https://github.com/bivlked/amneziawg-installer/network/members"><img src="https://img.shields.io/github/forks/bivlked/amneziawg-installer?style=flat" alt="Forks"></a>
  <img src="https://img.shields.io/github/last-commit/bivlked/amneziawg-installer" alt="Last commit">
</p>

<p align="center">
  <a href="#why">Why this project</a> •
  <a href="#comparison">AWG vs WG</a> •
  <a href="#cli-vs-panel">CLI vs panels</a> •
  <a href="#quickstart">Quick Start</a> •
  <a href="#features">Features</a> •
  <a href="#requirements">Requirements</a> •
  <a href="#hosting-recommendation">Hosting</a> •
  <a href="#installation">Installation</a> •
  <a href="#after-installation">After installation</a> •
  <a href="#client-management">Management</a> •
  <a href="#additional-information">More</a> •
  <a href="#faq">FAQ</a> •
  <a href="#troubleshooting">Troubleshooting</a> •
  <a href="#ecosystem">Ecosystem</a> •
  <a href="#license">License</a>
</p>

<a id="why"></a>
## 💡 Why this project

[AmneziaWG](https://github.com/amnezia-vpn) is a fork of WireGuard with traffic obfuscation. DPI systems cannot distinguish it from random noise, so the connection is not blocked.

This set of scripts turns a clean VPS into a ready-to-use VPN server. No Linux knowledge required — the script configures the firewall, optimizes the system, and generates client configs and QR codes automatically.

Works on Ubuntu 24.04/25.10 and Debian 12/13. Any cheap VPS with 1 GB RAM is enough.

---

<a id="comparison"></a>
## ⚖️ AmneziaWG vs WireGuard

| | WireGuard | AmneziaWG 2.0 |
|---|---|---|
| **DPI detection** | Fingerprinted by fixed packet sizes and magic bytes | Undetectable — randomized headers, padding, protocol mimicry |
| **Blocked in** | China, Russia, Iran, UAE, Turkmenistan | No known blocks (as of April 2026) |
| **Server setup** | Manual: keys, iptables, sysctl, systemd | One command, 20 min, fully automatic |
| **Hardening** | DIY: UFW, Fail2Ban, sysctl | Automatic: firewall + brute-force protection + kernel tuning |
| **Client management** | Edit configs by hand, restart | `add`/`remove`/`list`/`stats` with hot-reload |
| **Temporary access** | Not built-in | `--expires=7d` with auto-cleanup |
| **Server requirements** | — | Same — any $3-5/mo VPS, 1 GB RAM |
| **Speed overhead** | Baseline | Negligible (<2%) |

> If WireGuard works for you and isn't blocked — keep using it. If it's blocked or throttled — AmneziaWG 2.0 is the drop-in replacement.

---

<a id="cli-vs-panel"></a>
## ⚙️ CLI Installer vs Web Panels

> **The goal: set up a VPN on a cheap VPS in 20 minutes.** The script doesn't pull in Docker, a web server, or a database. After installation only AWG and the firewall are running — minimal footprint, maximum resources for VPN.

| | This project (CLI) | Docker-based web panels |
|---|---|---|
| **AWG module** | Kernel module — runs at kernel level | Userspace inside a container |
| **Server requirements** | Any VPS with 512 MB RAM | Needs PHP/Python, database, web server, Docker |
| **Attack surface** | SSH + UDP VPN port | + HTTP panel, database, Docker |
| **Installation** | Single command on the server, 20 minutes | docker-compose + giving SSH access to the panel |
| **After reboot** | Resumes installation from the same step | Depends on container and database state |
| **Web interface** | ❌ None — SSH only | ✅ GUI, browser-based management |
| **Multiple protocols** | AmneziaWG only | WireGuard, OpenVPN, VLESS and others |

> Need a VPN without GUI on a dedicated server — this project. Need a web panel with multiple protocols — look for Docker-based solutions.

---

<a id="quickstart"></a>
## 🚀 Quick Start

```bash
wget https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.11.3/install_amneziawg_en.sh
chmod +x install_amneziawg_en.sh
sudo bash ./install_amneziawg_en.sh
```

> 3 commands to start. 2 reboots along the way. About 20 minutes to a working VPN. [Learn more →](#installation)

<details>
<summary><strong>Non-interactive installation (for automation)</strong></summary>

```bash
sudo bash ./install_amneziawg_en.sh --yes --route-all
```

All parameters are accepted automatically. Details: [ADVANCED.en.md#cli-params-adv](ADVANCED.en.md#cli-params-adv)
</details>

---

<a id="features"></a>
## ✨ Features

* **DPI bypass** — AmneziaWG 2.0 with traffic obfuscation. DPI cannot detect the connection
* **One command — working VPN** — from a clean VPS to a running server with client configs and QR codes
* **Secure by default** — UFW, Fail2Ban, sysctl hardening, strict file permissions (600/700)
* **Easy management** — add/remove clients, temporary clients with auto-removal, traffic stats, backups
* **4 operating systems** — Ubuntu 24.04, Ubuntu 25.10, Debian 12, Debian 13
* **x86_64 and ARM** — cloud VPS, Raspberry Pi 3/4/5, ARM64 servers (AWS Graviton, Oracle Ampere, Hetzner)
* **Mobile network optimization** — `--preset=mobile` for Tele2, Yota, Megafon and other carriers with DPI blocking. Fine-tune with `--jc`, `--jmin`, `--jmax` ([details](ADVANCED.en.md#presets-adv))

<details>
<summary><strong>All features</strong></summary>

* Native key and config generation via `awg` — no Python or external dependencies
* Hardware-aware optimization: swap, NIC offloads, network buffers tuned to server specs
* DKMS — automatic kernel module rebuild on updates
* `vpn://` URI for one-tap import into Amnezia Client (`.vpnuri` files)
* Per-client traffic statistics (`stats`, `stats --json`)
* Temporary clients with auto-removal (`--expires=1h`, `7d`, `4w`, etc.)
* Diagnostic report (`--diagnostic`) and full uninstall (`--uninstall`)
* All actions logged to `/root/awg/`
* Resume after reboot — the script picks up from where it left off
* Choice of port, subnet, IPv6 mode, and routing mode. `--endpoint` flag for servers behind NAT
</details>

---

<a id="requirements"></a>
## 🖥️ Requirements

* **OS:** A **clean** installation of **Ubuntu Server 24.04 LTS** / **Ubuntu 25.10** (⚠️) / **Debian 12** / **Debian 13** Minimal
* **Access:** `root` privileges (via `sudo`)
* **Internet:** Stable connection
* **Resources:** ~1 GB RAM (2+ GB recommended), minimum ~2 GB disk (3+ GB recommended)
* **SSH:** SSH access to the server

**OS Compatibility:**

| OS | Status | Notes |
|----|--------|-------|
| Ubuntu 24.04 LTS | ✅ Fully supported | Recommended |
| Ubuntu 25.10 | ⚠️ Experimental | May require building the kernel module from source |
| Debian 12 (bookworm) | ✅ Supported | Tested. PPA via codename mapping to focal |
| Debian 13 (trixie) | ✅ Supported | Tested. PPA via codename mapping to noble, DEB822 |

**Architecture support (v5.10.0+):**

| Architecture | Status | Platforms |
|---|---|---|
| x86_64 (amd64) | ✅ Fully supported | All cloud VPS |
| ARM64 (aarch64) | ✅ Supported | Raspberry Pi 3/4/5, AWS Graviton, Oracle Ampere, Hetzner |
| ARMv7 (armhf) | ✅ Supported | Raspberry Pi 3/4 (32-bit) |

> On ARM, the installer downloads prebuilt kernel modules when available and falls back to DKMS compilation automatically.

> ⚠️ **Non-standard SSH port:** If SSH is not on port 22, run `sudo ufw allow YOUR_PORT/tcp` **before** starting the installer, otherwise you will lose access to the server.

**Clients:**
* **All platforms:** [Amnezia VPN](https://github.com/amnezia-vpn/amnezia-client/releases) **>= 4.8.12.7** — full-featured VPN client with AWG 2.0. Import via `vpn://` URI
* **Windows:** [AmneziaWG](https://github.com/amnezia-vpn/amneziawg-windows-client/releases) **>= 2.0.0** — lightweight tunnel manager with AWG 2.0. Import via `.conf` files

> [Full client compatibility table →](ADVANCED.en.md#client-compat-adv)

---

<a id="hosting-recommendation"></a>
## 🚀 Hosting Recommendation

For a stable, high-throughput VPN server, you need reliable hosting with a good network.

We've tested and recommend [**FreakHosting**](https://freakhosting.com/clientarea/aff.php?aff=392). Their **BUDGET VPS** lineup offers excellent value for money.

Their IPs are not flagged as datacenter — they are not blocked by services that restrict hosting/datacenter IP ranges (unlike Azure and some major clouds).

* **Recommended plan:** **BVPS-2**
* **Specs:** 2 vCPU, 2 GB RAM, 40 GB NVMe SSD.
* **Key advantage:** **10 Gbps** port with **unlimited traffic**. Perfect for VPN!
* **Price:** Just **€25 per year**.

This configuration is more than enough for comfortable AmneziaWG operation with many connections and heavy traffic.

---

<a id="installation"></a>
## 🔧 Installation (Recommended Method)

This installation method ensures correct handling of interactive prompts and colored output in your terminal.

1.  **Connect** to a **clean** server (Ubuntu 24.04 / Ubuntu 25.10 / Debian 12 / Debian 13) via SSH.
    > **Tip:** After creating the server, wait 5-10 minutes for all background initialization processes to complete before starting the installation.

2.  **Download the script:**
    ```bash
    wget https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.11.3/install_amneziawg_en.sh
    # or: curl -fLo install_amneziawg_en.sh https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.11.3/install_amneziawg_en.sh
    ```
3.  **Make it executable:**
    ```bash
    chmod +x install_amneziawg_en.sh
    ```
4.  **Run with `sudo`:**
    ```bash
    sudo bash ./install_amneziawg_en.sh
    ```
    *(You can also pass command-line parameters, see `sudo bash ./install_amneziawg_en.sh --help` or [ADVANCED.en.md#install-cli-adv](ADVANCED.en.md#install-cli-adv))*

    > **Russian version:** For Russian output, use `install_amneziawg.sh`:
    > ```bash
    > wget https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.11.3/install_amneziawg.sh
    > sudo bash ./install_amneziawg.sh
    > ```
    > The Russian version is functionally identical; only user-facing messages and logs are in Russian.
    > After reboots, resume with the same file: `sudo bash ./install_amneziawg.sh`

5.  **Initial setup:** The script will interactively ask for:
    * **UDP port:** Port for client connections (1024-65535). Default: `39743`.
    * **Tunnel subnet:** Internal VPN network. Default: `10.9.9.1/24`.
    * **Disable IPv6:** Recommended (`Y`) to prevent traffic leaks.
    * **Routing mode:** Determines which traffic goes through the VPN. Default `2` (Amnezia List + DNS) — recommended for best compatibility and bypassing restrictions.

    AWG 2.0 parameters (Jc, S1-S4, H1-H4, I1) are generated **automatically** — no action required.

6.  **Reboots:** **TWO** reboots are required. The script will ask for confirmation `[y/N]`. Type `y` and press Enter.

7.  **Resume:** After each reboot, **run the script again** with the same command:
    ```bash
    sudo bash ./install_amneziawg_en.sh
    ```
    The script will automatically resume from where it left off **without repeating any prompts**.

8.  **Completion:** After the second reboot and the third script run, you will see the message:
    `AmneziaWG 2.0 installation and configuration completed SUCCESSFULLY!`

---

<a id="after-installation"></a>
## 📦 After installation

**Where to find client files:**

| File | Path | Purpose |
|------|------|---------|
| `.conf` | `/root/awg/name.conf` | Configuration for client import |
| `.png` | `/root/awg/name.png` | QR code for mobile devices |
| `.vpnuri` | `/root/awg/name.vpnuri` | `vpn://` URI for Amnezia Client |

**Download config to your computer:**

```bash
scp root@SERVER_IP:/root/awg/my_phone.conf .
```

<details>
<summary><strong>Import into Amnezia VPN (phone) via vpn:// URI</strong></summary>

1. On the server, run: `cat /root/awg/my_phone.vpnuri`
2. Copy the text and send it to yourself (Telegram, email, etc.)
3. On your phone: Amnezia VPN → "Add VPN" → "Paste from clipboard"
</details>

<details>
<summary><strong>Import via QR code</strong></summary>

1. Download the QR code: `scp root@SERVER_IP:/root/awg/my_phone.png .`
2. Open the file on your computer screen
3. On your phone: Amnezia VPN → "Add VPN" → "Scan QR code"
</details>

<details>
<summary><strong>Import into AmneziaWG for Windows</strong></summary>

1. Download the `.conf` file to your computer via `scp` or `sftp`
2. AmneziaWG → Import tunnel(s) from file → select the `.conf` file
</details>

**Other files on the server:**

* Server configuration: `/etc/amnezia/amneziawg/awg0.conf`
* Script settings: `/root/awg/awgsetup_cfg.init`
* Management script: `/root/awg/manage_amneziawg.sh`
* Shared functions: `/root/awg/awg_common.sh`
* Client expiry data: `/root/awg/expiry/`
* Logs: `/root/awg/*.log`

---

<a id="client-management"></a>
## 👥 Client Management (`manage_amneziawg.sh`)

The `manage_amneziawg.sh` script is downloaded automatically during installation.

**Usage:**

```bash
sudo bash /root/awg/manage_amneziawg.sh <command> [arguments]
```

**Main commands:** (Full list: `... help` or [ADVANCED.en.md#manage-commands-adv](ADVANCED.en.md#manage-commands-adv))

| Command   | Arguments              | Description                    | Restart? |
| :-------- | :--------------------- | :----------------------------- | :------: |
| `add`     | `<name> [name2 ...] [--expires=DUR]`  | Add client(s) (opt. with expiry) | No (auto) |
| `remove`  | `<name> [name2 ...]`   | Remove client(s)               | No (auto) |
| `list`    | `[-v]`                 | List clients (`-v` for details)|    No     |
| `regen`   | `[client_name]`        | Regenerate files (all/one)     |    No     |
| `modify`  | `<name> <param> <val>` | Modify a client parameter      |    No     |
| `backup`  |                        | Create a backup                |    No     |
| `restore` | `[file]`               | Restore from backup            |    No     |
| `stats`   | `[--json]`                | Per-client traffic statistics    |    No     |
| `show`    |                        | Run `awg show`                 |    No     |
| `check`   |                        | Check server status            |    No     |
| `restart` |                        | Restart AmneziaWG service      |    -      |

> **💡 Note:** `add` and `remove` commands auto-apply changes via `awg syncconf` — no service restart needed.

### 📌 Quick Reference

```bash
# Installation (English)
wget https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.11.3/install_amneziawg_en.sh
sudo bash ./install_amneziawg_en.sh       # Run (+ 2 reboots)

# Installation (Russian)
wget https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.11.3/install_amneziawg.sh
sudo bash ./install_amneziawg.sh          # Run (+ 2 reboots)

# Client management
sudo bash /root/awg/manage_amneziawg.sh add my_phone       # Add
sudo bash /root/awg/manage_amneziawg.sh add my_iphone --psk  # +PresharedKey (Shadowrocket iOS/macOS)
sudo bash /root/awg/manage_amneziawg.sh remove my_phone    # Remove
sudo bash /root/awg/manage_amneziawg.sh list                # List
sudo bash /root/awg/manage_amneziawg.sh regen               # Regenerate

# Temporary client (7 days)
sudo bash /root/awg/manage_amneziawg.sh add guest --expires=7d

# Traffic statistics
sudo bash /root/awg/manage_amneziawg.sh stats
sudo bash /root/awg/manage_amneziawg.sh stats --json

# Maintenance
sudo bash /root/awg/manage_amneziawg.sh check               # Diagnostics
sudo bash /root/awg/manage_amneziawg.sh backup               # Backup
sudo bash /root/awg/manage_amneziawg.sh restart              # Restart
```

---

<a id="additional-information"></a>
## ℹ️ Additional Information

For detailed information on configuration, security settings, AWG 2.0 parameters, management commands, technical details, and more, see **[ADVANCED.en.md](ADVANCED.en.md)**.

For the changelog, see **[CHANGELOG.en.md](CHANGELOG.en.md)**.

---

<a id="faq"></a>
## ❓ FAQ

<details>
  <summary><strong>Q: Will it survive a kernel update?</strong></summary>
  <b>A:</b> Yes, DKMS should automatically rebuild the module. Verify with <code>dkms status</code>.
</details>

<details>
  <summary><strong>Q: How do I completely uninstall AmneziaWG?</strong></summary>
  <b>A:</b> Download the installer script (if you don't have it) and run: <code>sudo bash ./install_amneziawg_en.sh --uninstall</code>.
</details>

<details>
  <summary><strong>Q: Clients can't connect — what should I do?</strong></summary>
  <b>A:</b> 1. Check status: <code>sudo bash /root/awg/manage_amneziawg.sh check</code>. 2. Check firewall: <code>sudo ufw status verbose</code>. 3. Verify client config. 4. Check logs: <code>sudo journalctl -u awg-quick@awg0 -n 50</code>. 5. Make sure the client supports AWG 2.0: Amnezia VPN <b>>= 4.8.12.7</b> or AmneziaWG <b>>= 2.0.0</b>.
</details>

<details>
  <summary><strong>Q: Can I use this with AWG 1.x clients?</strong></summary>
  <b>A:</b> No. AWG 2.0 is not compatible with AWG 1.x. All clients must support the 2.0 protocol. For AWG 1.x, use the <a href="https://github.com/bivlked/amneziawg-installer/tree/legacy/v4">legacy/v4</a> branch.
</details>

<details>
  <summary><strong>Q: Config import error "Invalid key: s3" — what's wrong?</strong></summary>
  <b>A:</b> You're using an outdated version of <code>amneziawg-windows-client</code> (< 2.0.0). Update to <a href="https://github.com/amnezia-vpn/amneziawg-windows-client/releases"><b>version 2.0.0+</b></a> which supports AWG 2.0. Alternatively, use <a href="https://github.com/amnezia-vpn/amnezia-client/releases"><b>Amnezia VPN</b></a> >= 4.8.12.7.
</details>

<details>
  <summary><strong>Q: How do I update the scripts to a newer version?</strong></summary>
  <b>A:</b> Download the updated scripts and replace them on the server:
  <pre>
  # English version:
  wget -O /root/awg/manage_amneziawg.sh https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.11.3/manage_amneziawg_en.sh
  wget -O /root/awg/awg_common.sh https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.11.3/awg_common_en.sh
  chmod 700 /root/awg/manage_amneziawg.sh /root/awg/awg_common.sh

  # Russian version:
  wget -O /root/awg/manage_amneziawg.sh https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.11.3/manage_amneziawg.sh
  wget -O /root/awg/awg_common.sh https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.11.3/awg_common.sh
  chmod 700 /root/awg/manage_amneziawg.sh /root/awg/awg_common.sh
  </pre>
  Server reinstallation is not required.
</details>

<details>
  <summary><strong>Q: What is the maximum number of clients?</strong></summary>
  <b>A:</b> A <code>/24</code> subnet supports up to 253 clients (.2 — .254), which is sufficient for most use cases.
</details>

<details>
  <summary><strong>Q: Which hosting providers work well?</strong></summary>
  <b>A:</b> Any VPS with Ubuntu 24.04 / Ubuntu 25.10 (⚠️) / Debian 12 / Debian 13, root access, and at least 1 GB RAM. We recommend providers with clean (non-blacklisted) IPs and unlimited traffic. See our <a href="#hosting-recommendation">recommendation</a>.
</details>

<details>
  <summary><strong>Q: How do I migrate the VPN to another server?</strong></summary>
  <b>A:</b> 1. Create a backup: <code>sudo bash /root/awg/manage_amneziawg.sh backup</code>. 2. Copy the archive from <code>/root/awg/backups/</code> to the new server. 3. Install AmneziaWG on the new server. 4. Restore: <code>sudo bash /root/awg/manage_amneziawg.sh restore</code> (interactive selection, or specify the full archive path). 5. Regenerate configs with new IP: <code>sudo bash /root/awg/manage_amneziawg.sh regen</code>.
</details>

<details>
  <summary><strong>Q: How do I create a temporary client?</strong></summary>
  <b>A:</b> <code>sudo bash /root/awg/manage_amneziawg.sh add guest --expires=7d</code>. Formats: <code>1h</code>, <code>12h</code>, <code>1d</code>, <code>7d</code>, <code>30d</code>, <code>4w</code>. A cron job checks every 5 minutes and automatically removes expired clients.
</details>

<details>
  <summary><strong>Q: What are .vpnuri files?</strong></summary>
  <b>A:</b> <code>.vpnuri</code> files contain <code>vpn://</code> URIs for one-tap config import into Amnezia Client. Copy the file contents → open Amnezia Client → "Add VPN" → "Paste from clipboard".
</details>

<details>
  <summary><strong>Q: Shadowrocket on iOS/macOS does not connect — needs PresharedKey</strong></summary>
  <b>A:</b> Since v5.11.1 the <code>add</code> command supports a <code>--psk</code> flag: <code>sudo bash /root/awg/manage_amneziawg.sh add my_iphone --psk</code>. The client config will include a <code>PresharedKey = ...</code> line matching the server <code>[Peer]</code>. For existing clients: recreate with the flag (<code>remove</code> + <code>add --psk</code>) or manually — generate the key <em>once</em> (<code>PSK=$(awg genpsk)</code>) and paste the <em>same value</em> into both sides (the server <code>[Peer]</code> for that client and the client's <code>[Peer]</code> for the server); the handshake fails if the values differ. <code>regen</code> preserves an existing PSK across rotation. Details — in <a href="ADVANCED.en.md#manage-cli-adv">ADVANCED.en.md</a>.
</details>

<details>
  <summary><strong>Q: Why port 39743?</strong></summary>
  <b>A:</b> It's a random port from the upper range, chosen as the default. You can change it during installation: <code>--port=XXXXX</code> (any port 1024-65535).
</details>

<details>
  <summary><strong>Q: Is Perl required on the server?</strong></summary>
  <b>A:</b> Perl is used optionally for generating <code>vpn://</code> URIs (<code>.vpnuri</code> files). If Perl is absent, <code>.conf</code> files are still created normally — you can use them via file import or QR code. Perl is installed by default on Ubuntu and Debian.
</details>

<details>
  <summary><strong>Q: Is it safe to re-run the installer?</strong></summary>
  <b>A:</b> Yes. On re-run, the server config is recreated, but existing clients are automatically restored from backup. Default clients (<code>my_phone</code>, <code>my_laptop</code>) are recreated; all others are preserved.
</details>

> More answers and solutions in **[ADVANCED.en.md](ADVANCED.en.md)**.

---

<a id="troubleshooting"></a>
## 🛠️ Troubleshooting

1.  **Logs:** `/root/awg/install_amneziawg.log`, `/root/awg/manage_amneziawg.log`
2.  **Service status:** `sudo systemctl status awg-quick@awg0`
3.  **AmneziaWG status:** `sudo awg show`
4.  **UFW status:** `sudo ufw status verbose`
5.  **Diagnostic report:** `sudo bash ./install_amneziawg_en.sh --diagnostic`
    For a detailed breakdown of the report, see [ADVANCED.en.md](ADVANCED.en.md#diagnostic-report-adv).

---

<a id="ecosystem"></a>
## 🌐 Ecosystem

### Clients

> **Which client should I use?** Install [**Amnezia VPN**](https://github.com/amnezia-vpn/amnezia-client/releases) (>= 4.8.12.7) — works on all platforms, supports `vpn://` URI import.
> For a lightweight connection (`.conf` import only), use **AmneziaWG** for your platform.

| Client | Platform | AWG 2.0 | Type | Notes |
|--------|----------|:-------:|------|-------|
| **[Amnezia VPN](https://github.com/amnezia-vpn/amnezia-client/releases)** | Windows, macOS, Linux, Android, iOS | ✅ >= 4.8.12.7 | Official | **Recommended.** Full-featured, `vpn://` URI |
| [AmneziaWG](https://github.com/amnezia-vpn/amneziawg-windows-client/releases) | Windows | ✅ >= 2.0.0 | Official | Lightweight tunnel manager, `.conf` import |
| [AmneziaWG](https://github.com/amnezia-vpn/amneziawg-android) | Android | ✅ >= 2.0.0 | Official | Lightweight tunnel manager, `.conf` import |
| [AmneziaWG](https://apps.apple.com/app/amneziawg/id6478942365) | iOS | ✅ | Official | Lightweight tunnel manager, `.conf` import |
| [WG Tunnel](https://github.com/wgtunnel/android) | Android | ⚠️ partial | Third-party, FOSS | Auto-tunneling, split tunnel, F-Droid |
| [VeilBox](https://github.com/artem4150/VeilBox) | Windows, macOS | ✅ | Third-party, FOSS | Also supports VLESS |

> [Full compatibility table with AWG 1.x details →](ADVANCED.en.md#client-compat-adv)

### Configuration Tools

| Project | Description |
|---------|-------------|
| [Junker](https://spatiumstas.github.io/junker/) | AmneziaWG signature generator by @spatiumstas — for manual setup without an installer |
| [AmneziaWG-Architect](https://vadim-khristenko.github.io/AmneziaWG-Architect/) | CPS/mimicry generator UI for AWG 2.0 by @Vadim-Khristenko ([GitHub](https://github.com/Vadim-Khristenko/AmneziaWG-Architect)) |

### Router Firmware

| Project | Platform | Description |
|---------|----------|-------------|
| [AWG Manager](https://github.com/hoaxisr/awg-manager) | Keenetic (Entware) | Web UI for managing AWG tunnels on Keenetic routers |
| [AmneziaWG for Merlin](https://github.com/r0otx/asuswrt-merlin-amneziawg) | ASUS (Asuswrt-Merlin) | AWG 2.0 addon with web UI, GeoIP/GeoSite routing |

<a id="featured-in"></a>
<details>
<summary><strong>📰 Featured in</strong></summary>

- [XDA Developers — «I found a self-hosted VPN that works where WireGuard gets blocked»](https://www.xda-developers.com/self-hosted-vpn-works-where-wireguard-gets-blocked/)
- [Pinggy — Top 5 Best Self-Hosted VPNs in 2026](https://pinggy.io/blog/top_5_best_self_hosted_vpns/)
- [gHacks Tech News — AmneziaWG 2.0](https://www.ghacks.net/2026/03/25/amnezia-releases-amneziawg-2-0-to-bypass-advanced-internet-censorship-systems/)
- [Debian Forums — HowTo: Install AmneziaWG 2.0 on Debian 12/13](https://forums.debian.net/viewtopic.php?t=166105)
- [Qubes OS Forum — AmneziaWG for censored regions](https://forum.qubes-os.org/t/installation-of-amnezia-vpn-and-amnezia-wg-effective-tools-against-internet-blocks-via-dpi-for-china-russia-belarus-turkmenistan-iran-vpn-with-vless-xray-reality-best-obfuscation-for-wireguard-easy-self-hosted-vpn-bypass/39005)

</details>

---

<a id="license"></a>
## 📝 License & Author

* **Author:** @bivlked - [GitHub](https://github.com/bivlked)
* **License:** MIT — free and open-source (see `LICENSE`)

---

<p align="center">
  <a href="#top">↑ Back to top</a>
</p>
