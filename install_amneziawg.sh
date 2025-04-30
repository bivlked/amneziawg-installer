#!/usr/bin/env bash
# AmneziaWG Installer – version-5.1.1 (2025-04-30)
# https://github.com/bivlked/amneziawg-installer • MIT

set -Eeuo pipefail
set -o errtrace
trap 'echo "[FATAL] line $LINENO – $BASH_COMMAND" >&2' ERR
shopt -s inherit_errexit nullglob

readonly STATE_FILE="/root/.amwg-installer/state"
readonly WORK_DIR="/root/awg"
mkdir -p "$(dirname "$STATE_FILE")"
readonly SCRIPT_URL="https://raw.githubusercontent.com/bivlked/amneziawg-installer/version-5/install_amneziawg.sh"
readonly SCRIPT_SHA256="REPLACE_ME_ON_RELEASE"

# ----------------------- CLI‑параметры ----------------------
AWG_PORT=${AWG_PORT:-39743}  # AmneziaWG port
FW="ufw"                   # ufw|iptables|firewalld|none
ALLOWED_PRESET="default"   # default|split
NON_INTERACTIVE=false
SELF_UPDATE=false
DISABLE_IPV6=false
WITH_NET2BAN=false
PROFILE=""

usage(){ cat <<EOF
AmneziaWG installer
Options:
  --fw=<backend>               ufw|firewalld|iptables|none (default ufw)
  --allowed-ips=<preset>       default|split (default default)
  --disable-ipv6               Turn off IPv6 via sysctl
  --with-net2ban               Install net2ban service
  --hardening                  Shortcut for --disable-ipv6 --with-net2ban
  --profile=azure              Preset (fw=none, hardening, non-interactive, cleanup)
  --non-interactive            Suppress prompts (CI)
  --self-update                Replace installer and exit
  -h|--help                    Show help
EOF
}

for arg in "$@"; do case $arg in
  --fw=*)            FW="${arg#*=}";;
  --allowed-ips=*)   ALLOWED_PRESET="${arg#*=}";;
  --disable-ipv6)    DISABLE_IPV6=true;;
  --with-net2ban)    WITH_NET2BAN=true;;
  --hardening)       DISABLE_IPV6=true; WITH_NET2BAN=true;;
  --profile=azure)   PROFILE=azure;;
  --non-interactive) NON_INTERACTIVE=true;;
  --self-update)     SELF_UPDATE=true;;
  -h|--help)         usage; exit 0;;
  *) echo "Неизвестный параметр $arg"; usage; exit 1;;
  esac; done

# --------------- Профиль Azure (легковесный) ---------------
if [[ $PROFILE == azure ]]; then
  FW="none"; DISABLE_IPV6=true; WITH_NET2BAN=false; NON_INTERACTIVE=true
fi

# ------------------------ Self‑update -----------------------
if $SELF_UPDATE; then
  tmp=$(mktemp); curl -fsSL "$SCRIPT_URL" -o "$tmp"
  echo "$SCRIPT_SHA256  $tmp" | sha256sum -c - || { echo "Checksum mismatch"; exit 1; }
  install -m 0755 "$tmp" "$0"; echo "Installer updated."; exit 0
fi

# ------------------ Интерактивные вопросы ------------------
if [[ -t 0 && $NON_INTERACTIVE == false ]]; then
  [[ $DISABLE_IPV6 == false ]] && read -rp "Выключить IPv6? (Y/n) " a && [[ ${a,,} =~ ^y|^$ ]] && DISABLE_IPV6=true
  [[ $WITH_NET2BAN == false ]] && read -rp "Установить net2ban? (Y/n) " b && [[ ${b,,} =~ ^y|^$ ]] && WITH_NET2BAN=true
  read -rp "AllowedIPs preset (default/split) [default]: " c && [[ -n $c ]] && ALLOWED_PRESET=$c
fi

# ------------------------- Проверки -------------------------
source /etc/os-release
[[ $ID == ubuntu && ${VERSION_ID%%.*} -ge 24 ]] || { echo "Требуется Ubuntu ≥24.04"; exit 1; }

step(){ echo "$1" > "$STATE_FILE"; }
cur=$(cat "$STATE_FILE" 2>/dev/null || echo 0)

# ------------------------- Функции --------------------------
install_packages(){
  apt-get update -y
  pkgs=(jq curl lsb-release wireguard wireguard-tools)
  case $FW in ufw) pkgs+=(ufw);; firewalld) pkgs+=(firewalld);; iptables) pkgs+=(iptables iptables-persistent);; esac
  $WITH_NET2BAN && pkgs+=(net2ban)
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
}

disable_ipv6(){ cat >/etc/sysctl.d/99-amwg-disable-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
  sysctl -q -p /etc/sysctl.d/99-amwg-disable-ipv6.conf
}

cleanup_azure(){ apt-get purge -y man-db snapd >/dev/null 2>&1 || true; apt-get autoremove -y; apt-get clean; }

configure_fw(){
  case $FW in
    ufw) ufw allow 22/tcp; ufw allow "$AWG_PORT"/udp; ufw --force enable ;;
    firewalld) systemctl enable --now firewalld; firewall-cmd --permanent --add-port=${AWG_PORT}/udp; firewall-cmd --reload ;;
    iptables) iptables -w 5 -A INPUT -p udp --dport "$AWG_PORT" -j ACCEPT; iptables-save >/etc/iptables/rules.v4 ;;
    none) echo "FW disabled" ;;
  esac
}

create_keys(){ mkdir -p "$WORK_DIR" && chmod 700 "$WORK_DIR"; wg genkey | tee "$WORK_DIR/server.key" | wg pubkey > "$WORK_DIR/server.pub"; }

create_conf(){
  AWG_PORT=51820
  [[ $ALLOWED_PRESET == split ]] && ALLOWED_IPS="0.0.0.0/1,128.0.0.0/1" || ALLOWED_IPS="0.0.0.0/0,::/0"
  cat >/etc/wireguard/awg0.conf <<CONF
[Interface]
Address = 10.60.0.1/24
ListenPort = $AWG_PORT
PrivateKey = $(cat "$WORK_DIR/server.key")
PostUp   = iptables -w 5 -t nat -A POSTROUTING -o awg0 -j MASQUERADE
PostDown = iptables -w 5 -t nat -D POSTROUTING -o awg0 -j MASQUERADE
CONF
}

enable_service(){ systemctl enable --now wg-quick@awg0.service; }
install_manager(){ curl -fsSL "https://raw.githubusercontent.com/bivlked/amneziawg-installer/version-5/manage_amneziawg.sh" -o /usr/local/bin/manage_amneziawg.sh; chmod 755 /usr/local/bin/manage_amneziawg.sh; }

# ----------------------- Пайплайн ---------------------------
[[ $cur -lt 1 ]] && echo "[1] packages" && install_packages && step 1
[[ $cur -lt 2 && $DISABLE_IPV6 == true ]] && echo "[2] disable IPv6" && disable_ipv6 && step 2 || { [[ $cur -lt 2 ]] && step 2; }
[[ $cur -lt 3 ]] && echo "[3] firewall" && configure_fw && step 3
[[ $cur -lt 4 ]] && echo "[4] keys" && create_keys && step 4
[[ $cur -lt 5 ]] && echo "[5] config" && create_conf && step 5
[[ $cur -lt 6 ]] && echo "[6] service" && enable_service && install_manager && step 6
[[ $PROFILE == azure ]] && cleanup_azure

echo "AmneziaWG installed successfully!"
```bash
#!/usr/bin/env bash
# AmneziaWG Installer – version-5.1.1 (2025-04-30)
# https://github.com/bivlked/amneziawg-installer • MIT

set -Eeuo pipefail; set -o errtrace
trap 'echo "[FATAL] line $LINENO – $BASH_COMMAND" >&2' ERR
shopt -s inherit_errexit nullglob

readonly STATE_FILE="/root/.amwg-installer/state"
readonly WORK_DIR="/root/awg"
mkdir -p "$(dirname "$STATE_FILE")"   # <— фикс: гарантируем каталог
readonly SCRIPT_URL="https://raw.githubusercontent.com/bivlked/amneziawg-installer/version-5/install_amneziawg.sh"
readonly SCRIPT_SHA256="REPLACE_ME_ON_RELEASE"

# остальной код без изменений...
```bash
#!/usr/bin/env bash
# AmneziaWG Installer – version‑5.1 (2025‑04‑30)
# https://github.com/bivlked/amneziawg-installer • MIT

set -Eeuo pipefail
set -o errtrace
trap 'echo "[FATAL] line $LINENO – $BASH_COMMAND" >&2' ERR
shopt -s inherit_errexit nullglob

readonly STATE_FILE="/root/.amwg-installer/state"
readonly WORK_DIR="/root/awg"
readonly SCRIPT_URL="https://raw.githubusercontent.com/bivlked/amneziawg-installer/version-5/install_amneziawg.sh"
readonly SCRIPT_SHA256="REPLACE_ME_ON_RELEASE"  # ставится CI

# ----------------------- CLI‑параметры ----------------------
FW="ufw"                   # ufw|iptables|firewalld|none
ALLOWED_PRESET="default"   # default|split
NON_INTERACTIVE=false
SELF_UPDATE=false
DISABLE_IPV6=false
WITH_NET2BAN=false
PROFILE=""

usage(){ cat <<EOF
AmneziaWG installer
Options:
  --fw=<backend>               ufw|firewalld|iptables|none (default ufw)
  --allowed-ips=<preset>       default|split (default default)
  --disable-ipv6               Turn off IPv6 via sysctl
  --with-net2ban               Install net2ban service
  --hardening                  Shortcut for --disable-ipv6 --with-net2ban
  --profile=azure              Preset (fw=none, hardening, non-interactive, cleanup)
  --non-interactive            Suppress prompts (CI)
  --self-update                Replace installer and exit
  -h|--help                    Show help
EOF
}

for arg in "$@"; do case $arg in
  --fw=*)            FW="${arg#*=}";;
  --allowed-ips=*)   ALLOWED_PRESET="${arg#*=}";;
  --disable-ipv6)    DISABLE_IPV6=true;;
  --with-net2ban)    WITH_NET2BAN=true;;
  --hardening)       DISABLE_IPV6=true; WITH_NET2BAN=true;;
  --profile=azure)   PROFILE=azure;;
  --non-interactive) NON_INTERACTIVE=true;;
  --self-update)     SELF_UPDATE=true;;
  -h|--help)         usage; exit 0;;
  *) echo "Неизвестный параметр $arg"; usage; exit 1;;
  esac; done

# --------------- Профиль Azure (легковесный) ---------------
if [[ $PROFILE == azure ]]; then
  FW="none"; DISABLE_IPV6=true; WITH_NET2BAN=false; NON_INTERACTIVE=true
fi

# ------------------------ Self‑update -----------------------
if $SELF_UPDATE; then
  tmp=$(mktemp); curl -fsSL "$SCRIPT_URL" -o "$tmp"
  echo "$SCRIPT_SHA256  $tmp" | sha256sum -c - || { echo "Checksum mismatch"; exit 1; }
  install -m 0755 "$tmp" "$0"; echo "Installer updated."; exit 0
fi

# ------------------ Интерактивные вопросы ------------------
if [[ -t 0 && $NON_INTERACTIVE == false ]]; then
  [[ $DISABLE_IPV6 == false ]] && read -rp "Выключить IPv6? (Y/n) " a && [[ ${a,,} =~ ^y|^$ ]] && DISABLE_IPV6=true
  [[ $WITH_NET2BAN == false ]] && read -rp "Установить net2ban? (Y/n) " b && [[ ${b,,} =~ ^y|^$ ]] && WITH_NET2BAN=true
  read -rp "AllowedIPs preset (default/split) [default]: " c && [[ -n $c ]] && ALLOWED_PRESET=$c
fi

# ------------------------- Проверки -------------------------
source /etc/os-release
[[ $ID == ubuntu && ${VERSION_ID%%.*} -ge 24 ]] || { echo "Требуется Ubuntu ≥24.04"; exit 1; }

step(){ echo "$1" > "$STATE_FILE"; }
cur=$(cat "$STATE_FILE" 2>/dev/null || echo 0)

# ------------------------- Функции --------------------------
install_packages(){
  apt-get update -y
  pkgs=(jq curl lsb-release wireguard wireguard-tools)
  case $FW in ufw) pkgs+=(ufw);; firewalld) pkgs+=(firewalld);; iptables) pkgs+=(iptables iptables-persistent);; esac
  $WITH_NET2BAN && pkgs+=(net2ban)
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
}

disable_ipv6(){ cat >/etc/sysctl.d/99-amwg-disable-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
  sysctl -q -p /etc/sysctl.d/99-amwg-disable-ipv6.conf
}

cleanup_azure(){ apt-get purge -y man-db snapd >/dev/null 2>&1 || true; apt-get autoremove -y; apt-get clean; }

configure_fw(){
  case $FW in
    ufw) ufw allow 22/tcp; ufw allow "$AWG_PORT"/udp; ufw --force enable ;;
    firewalld) systemctl enable --now firewalld; firewall-cmd --permanent --add-port=${AWG_PORT}/udp; firewall-cmd --reload ;;
    iptables) iptables -w 5 -A INPUT -p udp --dport "$AWG_PORT" -j ACCEPT; iptables-save >/etc/iptables/rules.v4 ;;
    none) echo "FW disabled" ;;
  esac
}

create_keys(){ mkdir -p "$WORK_DIR" && chmod 700 "$WORK_DIR"; wg genkey | tee "$WORK_DIR/server.key" | wg pubkey > "$WORK_DIR/server.pub"; }

create_conf(){
  AWG_PORT=51820
  [[ $ALLOWED_PRESET == split ]] && ALLOWED_IPS="0.0.0.0/1,128.0.0.0/1" || ALLOWED_IPS="0.0.0.0/0,::/0"
  cat >/etc/wireguard/awg0.conf <<CONF
[Interface]
Address = 10.60.0.1/24
ListenPort = $AWG_PORT
PrivateKey = $(cat "$WORK_DIR/server.key")
PostUp   = iptables -w 5 -t nat -A POSTROUTING -o awg0 -j MASQUERADE
PostDown = iptables -w 5 -t nat -D POSTROUTING -o awg0 -j MASQUERADE
CONF
}

enable_service(){ systemctl enable --now wg-quick@awg0.service; }
install_manager(){ curl -fsSL "https://raw.githubusercontent.com/bivlked/amneziawg-installer/version-5/manage_amneziawg.sh" -o /usr/local/bin/manage_amneziawg.sh; chmod 755 /usr/local/bin/manage_amneziawg.sh; }

# ----------------------- Пайплайн ---------------------------
[[ $cur -lt 1 ]] && echo "[1] packages" && install_packages && step 1
[[ $cur -lt 2 && $DISABLE_IPV6 == true ]] && echo "[2] disable IPv6" && disable_ipv6 && step 2 || { [[ $cur -lt 2 ]] && step 2; }
[[ $cur -lt 3 ]] && echo "[3] firewall" && configure_fw && step 3
[[ $cur -lt 4 ]] && echo "[4] keys" && create_keys && step 4
[[ $cur -lt 5 ]] && echo "[5] config" && create_conf && step 5
[[ $cur -lt 6 ]] && echo "[6] service" && enable_service && install_manager && step 6
[[ $PROFILE == azure ]] && cleanup_azure

echo "AmneziaWG installed successfully!"