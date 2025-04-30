#!/usr/bin/env bash
# Manage peers & workaround awgcfg bug – version‑5.1
set -Eeuo pipefail; set -o errtrace
trap 'echo "[FATAL] $LINENO $BASH_COMMAND" >&2' ERR
WG_CONF=/etc/wireguard/awg0.conf
CFG=/root/awg/awgsetup_cfg.init
FW_CMD=$(command -v ufw || true)

usage(){ cat <<EOF
Usage: $0 add <name> | del <name> | list | regen-fw
EOF
}
move(){ mv "$CFG" "$CFG.bak" 2>/dev/null || true; }
back(){ mv "$CFG.bak" "$CFG" 2>/dev/null || true; }

cmd=${1:-help}
case $cmd in
  add) name=$2; [[ -z $name ]] && { echo "Name missing"; exit 1; }; move; awgcfg.py -c -q "$name"; back; systemctl restart wg-quick@awg0; echo "Peer $name added." ;;
  del) move; awgcfg.py -d "$2"; back; systemctl restart wg-quick@awg0; echo "Peer $2 removed." ;;
  list) wg show awg0 peer brief ;;
  regen-fw)
    if [[ -z $FW_CMD ]]; then echo "UFW absent (fw=none); skip regen"; exit 0; fi
    $FW_CMD allow 22/tcp || true
    wg show awg0 | awk '/listening/{print $5}' | while read -r p; do $FW_CMD allow $p/udp || true; done
    $FW_CMD --force reload ;;
  *) usage; exit 1;;
esac