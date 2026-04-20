#!/bin/bash

# Minimum Bash version check
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "ERROR: Bash >= 4.0 required (current: ${BASH_VERSION})" >&2; exit 1
fi

# ==============================================================================
# AmneziaWG 2.0 installation and configuration script for Ubuntu/Debian servers
# Author: @bivlked
# Version: 5.10.2
# Date: 2026-04-20
# Repository: https://github.com/bivlked/amneziawg-installer
# ==============================================================================

# --- Safe mode and Constants ---
set -o pipefail
SCRIPT_VERSION="5.10.2"

AWG_DIR="/root/awg"
CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init"
STATE_FILE="$AWG_DIR/setup_state"
LOG_FILE="$AWG_DIR/install_amneziawg.log"
KEYS_DIR="$AWG_DIR/keys"
SERVER_CONF_FILE="/etc/amnezia/amneziawg/awg0.conf"
AWG_BRANCH="${AWG_BRANCH:-v${SCRIPT_VERSION}}"
COMMON_SCRIPT_URL="https://raw.githubusercontent.com/bivlked/amneziawg-installer/${AWG_BRANCH}/awg_common_en.sh"
COMMON_SCRIPT_PATH="$AWG_DIR/awg_common.sh"
MANAGE_SCRIPT_URL="https://raw.githubusercontent.com/bivlked/amneziawg-installer/${AWG_BRANCH}/manage_amneziawg_en.sh"
MANAGE_SCRIPT_PATH="$AWG_DIR/manage_amneziawg.sh"

# SHA256 checksums of downloaded scripts. Updated at each release.
# Verified in step5_download_scripts() after curl.
# Verification is skipped when AWG_BRANCH is overridden (test branch).
# Format: sha256sum output (hex, 64 chars).
COMMON_SCRIPT_SHA256="5a31301232e51ec040088ddb3bdd9f10261373918f45c46140c4987dc81a3a55"
MANAGE_SCRIPT_SHA256="f5cc1eb920898cba8e40979b15a13549f5c518cd67e7cd13d96fecc99aaac934"

# CLI flags
UNINSTALL=0; HELP=0; DIAGNOSTIC=0; VERBOSE=0; NO_COLOR=0; AUTO_YES=0; NO_TWEAKS=0
_APT_UPDATED=0
CLI_PORT=""; CLI_SUBNET=""; CLI_DISABLE_IPV6="default"
CLI_ROUTING_MODE="default"; CLI_CUSTOM_ROUTES=""; CLI_ENDPOINT=""; CLI_NO_TWEAKS=0

# --- Auto-cleanup of temporary files ---
_install_temp_files=()
_install_cleanup() {
    local f
    for f in "${_install_temp_files[@]}"; do [[ -f "$f" ]] && rm -f "$f"; done
    # Clean up temporary files from awg_common.sh (if already sourced)
    type _awg_cleanup &>/dev/null && _awg_cleanup
}
trap _install_cleanup EXIT INT TERM

# --- Argument processing ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --uninstall)     UNINSTALL=1 ;;
        --help|-h)       HELP=1 ;;
        --diagnostic)    DIAGNOSTIC=1 ;;
        --verbose|-v)    VERBOSE=1 ;;
        --no-color)      NO_COLOR=1 ;;
        --port=*)        CLI_PORT="${1#*=}" ;;
        --subnet=*)      CLI_SUBNET="${1#*=}" ;;
        --allow-ipv6)    CLI_DISABLE_IPV6=0 ;;
        --disallow-ipv6) CLI_DISABLE_IPV6=1 ;;
        --route-all)     CLI_ROUTING_MODE=1 ;;
        --route-amnezia) CLI_ROUTING_MODE=2 ;;
        --route-custom=*) CLI_ROUTING_MODE=3; CLI_CUSTOM_ROUTES="${1#*=}" ;;
        --endpoint=*)    CLI_ENDPOINT="${1#*=}" ;;
        --yes|-y)        AUTO_YES=1 ;;
        --no-tweaks)     NO_TWEAKS=1; CLI_NO_TWEAKS=1 ;;
        --preset=*)      CLI_PRESET="${1#*=}" ;;
        --jc=*)          CLI_JC="${1#*=}" ;;
        --jmin=*)        CLI_JMIN="${1#*=}" ;;
        --jmax=*)        CLI_JMAX="${1#*=}" ;;
        *) echo "Unknown argument: $1"; HELP=1 ;;
    esac
    shift
done

# ==============================================================================
# Logging functions
# ==============================================================================

log_msg() {
    local type="$1" msg="$2"
    local ts
    ts=$(date +'%F %T')
    local safe_msg
    safe_msg="${msg//%/%%}"
    local entry="[$ts] $type: $safe_msg"
    local color_start="" color_end=""

    if [[ "$NO_COLOR" -eq 0 ]]; then
        color_end="\033[0m"
        case "$type" in
            INFO)  color_start="\033[0;32m" ;;
            WARN)  color_start="\033[0;33m" ;;
            ERROR) color_start="\033[1;31m" ;;
            DEBUG) color_start="\033[0;36m" ;;
            *)     color_start=""; color_end="" ;;
        esac
    fi

    if ! mkdir -p "$(dirname "$LOG_FILE")" || ! echo "$entry" >> "$LOG_FILE"; then
        echo "[$ts] ERROR: Log write error $LOG_FILE" >&2
    fi

    if [[ "$type" == "ERROR" || "$type" == "WARN" ]]; then
        printf "${color_start}%s${color_end}\n" "$entry" >&2
    elif [[ "$type" == "DEBUG" && "$VERBOSE" -eq 1 ]]; then
        printf "${color_start}%s${color_end}\n" "$entry" >&2
    elif [[ "$type" == "INFO" ]]; then
        printf "${color_start}%s${color_end}\n" "$entry"
    elif [[ "$type" != "DEBUG" ]]; then
        printf "${color_start}%s${color_end}\n" "$entry"
    fi
}

log()       { log_msg "INFO" "$1"; }
log_warn()  { log_msg "WARN" "$1"; }
log_error() { log_msg "ERROR" "$1"; }
log_debug() { if [[ "$VERBOSE" -eq 1 ]]; then log_msg "DEBUG" "$1"; fi; }
die()       { log_error "CRITICAL ERROR: $1"; log_error "Installation aborted. Log: $LOG_FILE"; exit 1; }

# ==============================================================================
# apt-get update wrapper that tolerates 404s only for source packages (deb-src).
# INLINE: needed in steps 1-2 before awg_common.sh is downloaded (Step 5).
# Some mirrors (Hetzner, AWS) do not serve source packages, but the default
# ubuntu.sources contains 'Types: deb deb-src'. We do not need source packages
# (kernel module is built via DKMS using binary headers), so such 404s are safe
# to ignore. Returns 0 if update succeeded OR if all errors are on source markers.
# Any other error (GPG, binary-package network, silent crash / OOM / SIGKILL) → non-zero.
# ==============================================================================
apt_update_tolerant() {
    local err_output rc non_src_errors
    err_output=$(LANG=C LC_ALL=C apt-get update -y 2>&1)
    rc=$?
    echo "$err_output"

    if [[ $rc -eq 0 ]]; then
        return 0
    fi

    # Filter error lines. Ignore:
    #   1. Lines about source packages (deb-src / /source/ / Sources)
    #   2. Generic 'Some index files failed to download' — symptom, not cause
    non_src_errors=$(printf '%s\n' "$err_output" \
        | grep -E '^(E:|Err:|W:)' \
        | grep -vE '(deb-src|/source/|Sources([^[:alpha:]]|$))' \
        | grep -vE 'Some index files failed to download' || true)

    if [[ -z "$non_src_errors" ]]; then
        # Edge case: rc != 0 but no classifiable E:/Err:/W: lines found
        # (OOM-killer SIGKILL, silent crash, unknown apt output format).
        # Ignore ONLY if the output actually contains source-markers.
        if printf '%s\n' "$err_output" | grep -qE '(deb-src|/source/|Sources([^[:alpha:]]|$))'; then
            log_warn "apt update: source packages unavailable in mirror (expected, ignored)"
            return 0
        fi
        log_error "apt update exited with rc=$rc without any classifiable APT lines — possible silent crash / OOM / SIGKILL"
        return "$rc"
    fi

    log_error "apt update failed with non-source errors:"
    printf '%s\n' "$non_src_errors" | while IFS= read -r line; do
        log_error "  $line"
    done
    return "$rc"
}

# ==============================================================================
# Help
# ==============================================================================

show_help() {
    cat << 'EOF'
Usage: sudo bash install_amneziawg_en.sh [OPTIONS]
Script for installation and configuration of AmneziaWG 2.0 on Ubuntu (24.04 / 25.10) and Debian (12 / 13).

Options:
  -h, --help            Show this help and exit
  --uninstall           Uninstall AmneziaWG and all its configurations
  --diagnostic          Generate diagnostic report and exit
  -v, --verbose         Verbose output for debugging (including DEBUG)
  --no-color            Disable colored terminal output
  --port=NUMBER         Set UDP port (1024-65535) non-interactively
  --subnet=SUBNET       Set tunnel subnet (x.x.x.x/yy) non-interactively
  --allow-ipv6          Keep IPv6 enabled non-interactively
  --disallow-ipv6       Force-disable IPv6 non-interactively
  --route-all           Use 'All traffic' mode non-interactively
  --route-amnezia       Use 'Amnezia' mode non-interactively
  --route-custom=NETS   Use 'Custom' mode non-interactively
  --endpoint=IP         Specify external server IP (for servers behind NAT)
  -y, --yes             Auto-confirm (reboots, UFW, etc.)
  --no-tweaks           Skip hardening/optimization (no UFW, Fail2Ban, sysctl tweaks)
  --preset=TYPE         Obfuscation parameter preset: default, mobile
                        mobile: Jc=3, narrow Jmax — for mobile carriers (Tele2, Yota, Megafon)
  --jc=N               Set Jc manually (1-128, overrides preset)
  --jmin=N             Set Jmin manually (0-1280, overrides preset)
  --jmax=N             Set Jmax manually (0-1280, overrides preset, must be >= Jmin)

Examples:
  sudo bash install_amneziawg_en.sh                             # Interactive installation
  sudo bash install_amneziawg_en.sh --port=51820 --route-all    # Non-interactive
  sudo bash install_amneziawg_en.sh --route-amnezia --yes       # Fully automated
  sudo bash install_amneziawg_en.sh --preset=mobile --yes       # Optimized for mobile networks
  sudo bash install_amneziawg_en.sh --uninstall                 # Uninstall
  sudo bash install_amneziawg_en.sh --diagnostic                # Diagnostics

Repository: https://github.com/bivlked/amneziawg-installer
EOF
    exit 0
}

# ==============================================================================
# Utilities and validation
# ==============================================================================

update_state() {
    local next_step=$1
    mkdir -p "$(dirname "$STATE_FILE")"
    # Atomic write with flock to prevent race condition
    (
        flock -x 200
        echo "$next_step" > "$STATE_FILE"
    ) 200>"${STATE_FILE}.lock" || die "Failed to write state"
    log "State: next step - $next_step"
}

request_reboot() {
    local next_step=$1
    update_state "$next_step"
    echo "" >> "$LOG_FILE"
    log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    log_warn "!!! SYSTEM REBOOT REQUIRED                                !!!"
    log_warn "!!! After reboot, run the script again:                   !!!"
    log_warn "!!! sudo bash $0 [with the same parameters, if any]      !!!"
    log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "" >> "$LOG_FILE"
    local confirm="y"
    if [[ "$AUTO_YES" -eq 0 ]]; then
        read -rp "Reboot now? [y/N]: " confirm < /dev/tty
    else
        log "Auto-confirming reboot (--yes)."
    fi
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log "Reboot initiated..."
        sleep 5
        if ! reboot; then die "Reboot command failed."; fi
        exit 1
    else
        log "Reboot cancelled. Reboot manually and run the script again."
        exit 1
    fi
}

check_os_version() {
    log "Checking OS..."

    # Detection via /etc/os-release (universal for Ubuntu and Debian)
    OS_ID=""
    OS_VERSION=""
    OS_CODENAME=""
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        OS_ID="$ID"
        OS_VERSION="$VERSION_ID"
        OS_CODENAME="$VERSION_CODENAME"
    elif command -v lsb_release &>/dev/null; then
        OS_ID=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
        OS_VERSION=$(lsb_release -sr)
        OS_CODENAME=$(lsb_release -sc)
    else
        log_warn "Cannot detect OS (/etc/os-release and lsb_release not found)."
        return 0
    fi
    export OS_ID OS_VERSION OS_CODENAME

    # Supported OS
    local supported=0
    case "$OS_ID" in
        ubuntu)
            if [[ "$OS_VERSION" == "24.04" || "$OS_VERSION" == "25.10" ]]; then
                supported=1
            fi
            ;;
        debian)
            if [[ "$OS_VERSION" == "12" || "$OS_VERSION" == "13" ]]; then
                supported=1
            fi
            ;;
    esac

    if [[ "$supported" -eq 1 ]]; then
        log "OS: ${OS_ID^} $OS_VERSION ($OS_CODENAME) — supported"
    else
        log_warn "Detected $OS_ID $OS_VERSION ($OS_CODENAME). Script tested on Ubuntu 24.04/25.10 and Debian 12/13."
        if [[ "$AUTO_YES" -eq 0 ]]; then
            read -rp "Continue? [y/N]: " confirm < /dev/tty
            if ! [[ "$confirm" =~ ^[Yy]$ ]]; then die "Cancelled."; fi
        else
            log "Continuing on $OS_ID $OS_VERSION (--yes)."
        fi
    fi
}

check_free_space() {
    log "Checking disk space..."
    local req=2048
    local avail
    avail=$(df -m / | awk 'NR==2 {print $4}')
    if [[ -z "$avail" ]]; then
        log_warn "Failed to determine free space."
        return 0
    fi
    if [ "$avail" -lt "$req" ]; then
        log_warn "Available $avail MB. Recommended >= $req MB."
        if [[ "$AUTO_YES" -eq 0 ]]; then
            read -rp "Continue? [y/N]: " confirm < /dev/tty
            if ! [[ "$confirm" =~ ^[Yy]$ ]]; then die "Cancelled."; fi
        else
            log "Continuing with $avail MB (--yes)."
        fi
    else
        log "Free: $avail MB (OK)"
    fi
}

check_port_availability() {
    local port=$1
    log "Checking port $port..."
    local proc
    proc=$(ss -lunp | grep ":${port} ")
    if [[ -n "$proc" ]]; then
        log_error "Port ${port}/udp already in use! Process: $proc"
        return 1
    else
        log "Port $port/udp is free."
        return 0
    fi
}

install_packages() {
    local packages=("$@")
    local to_install=()
    local pkg
    log "Checking packages: ${packages[*]}..."
    for pkg in "${packages[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
            to_install+=("$pkg")
        fi
    done
    if [ ${#to_install[@]} -eq 0 ]; then
        log "All packages already installed."
        return 0
    fi
    log "Installing: ${to_install[*]}..."
    if [[ "${_APT_UPDATED:-0}" -eq 0 ]]; then
        apt_update_tolerant || log_warn "Failed to update apt."
        _APT_UPDATED=1
    fi
    DEBIAN_FRONTEND=noninteractive apt install -y "${to_install[@]}" || die "Package installation error."
    log "Packages installed."
}

cleanup_apt() {
    log "Cleaning apt..."
    apt-get clean || log_warn "apt-get clean error"
    rm -rf /var/lib/apt/lists/* || log_warn "rm /var/lib/apt/lists/* error"
    log "apt cache cleared."
}

configure_ipv6() {
    if [[ "$CLI_DISABLE_IPV6" != "default" ]]; then
        DISABLE_IPV6=$CLI_DISABLE_IPV6
        log "IPv6 from CLI: $DISABLE_IPV6"
    elif [[ "$AUTO_YES" -eq 1 ]]; then
        DISABLE_IPV6=1
        log "IPv6 disabled (--yes, default)."
    else
        read -rp "Disable IPv6 (recommended)? [Y/n]: " dis_ipv6 < /dev/tty
        if [[ "$dis_ipv6" =~ ^[Nn]$ ]]; then
            DISABLE_IPV6=0
        else
            DISABLE_IPV6=1
        fi
    fi
    export DISABLE_IPV6
    log "IPv6 disable: $(if [ "$DISABLE_IPV6" -eq 1 ]; then echo 'Yes'; else echo 'No'; fi)"
}

# Safe configuration loader (whitelist parser, no source/eval)
safe_load_config() {
    local config_file="${1:-$CONFIG_FILE}"
    if [[ ! -f "$config_file" ]]; then return 1; fi

    local line key value first_line=1
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$first_line" -eq 1 ]]; then
            line="${line#$'\xEF\xBB\xBF'}"
            first_line=0
        fi
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue
        line="${line#export }"
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            if [[ "$value" == \'*\' ]]; then
                value="${value#\'}"
                value="${value%\'}"
            elif [[ "$value" == \"*\" ]]; then
                value="${value#\"}"
                value="${value%\"}"
            fi
            case "$key" in
                OS_ID|OS_VERSION|OS_CODENAME|AWG_PORT|AWG_TUNNEL_SUBNET|\
                DISABLE_IPV6|ALLOWED_IPS_MODE|ALLOWED_IPS|AWG_ENDPOINT|\
                AWG_Jc|AWG_Jmin|AWG_Jmax|AWG_S1|AWG_S2|AWG_S3|AWG_S4|\
                AWG_H1|AWG_H2|AWG_H3|AWG_H4|AWG_I1|AWG_PRESET|NO_TWEAKS|AWG_APPLY_MODE)
                    export "$key=$value"
                    ;;
            esac
        fi
    done < "$config_file"
}

# Read a single key from config (for point queries)
safe_read_config_key() {
    local key="$1" config_file="${2:-$CONFIG_FILE}"
    local line first_line=1
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$first_line" -eq 1 ]]; then
            line="${line#$'\xEF\xBB\xBF'}"
            first_line=0
        fi
        line="${line%$'\r'}"
        line="${line#export }"
        if [[ "$line" =~ ^${key}=(.*)$ ]]; then
            local value="${BASH_REMATCH[1]}"
            if [[ "$value" == \'*\' ]]; then
                value="${value#\'}"
                value="${value%\'}"
            elif [[ "$value" == \"*\" ]]; then
                value="${value#\"}"
                value="${value%\"}"
            fi
            echo "$value"
            return 0
        fi
    done < "$config_file"
    return 1
}

validate_jc_value() {
    local v="$1"
    [[ "$v" =~ ^[0-9]+$ ]] && [[ "$v" -ge 1 ]] && [[ "$v" -le 128 ]]
}

validate_junk_size() {
    local v="$1"
    [[ "$v" =~ ^[0-9]+$ ]] && [[ "$v" -ge 0 ]] && [[ "$v" -le 1280 ]]
}

validate_port() {
    local port="$1"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1024 ]] || [[ "$port" -gt 65535 ]]; then
        die "Invalid port: '$port'. Allowed range: 1024-65535."
    fi
}

validate_subnet() {
    local subnet="$1"
    if ! [[ "$subnet" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/24$ ]] \
       || [[ "${BASH_REMATCH[1]}" -gt 255 ]] || [[ "${BASH_REMATCH[2]}" -gt 255 ]] \
       || [[ "${BASH_REMATCH[3]}" -gt 255 ]] || [[ "${BASH_REMATCH[4]}" -gt 255 ]]; then
        die "Invalid subnet: '$subnet'. Only /24 is supported."
    fi
    if [[ "${BASH_REMATCH[4]}" -eq 0 ]] || [[ "${BASH_REMATCH[4]}" -eq 255 ]]; then
        die "Invalid subnet: '$subnet'. Last octet cannot be 0 (network address) or 255 (broadcast)."
    fi
    if [[ "${BASH_REMATCH[4]}" -ne 1 ]]; then
        die "Invalid subnet: '$subnet'. Last octet must be 1 (server address in subnet)."
    fi
}

# Endpoint validation (FQDN / IPv4 / [IPv6]).
# Returns 0 if the endpoint is safe and matches one of the formats,
# otherwise 1 (the caller decides between die or log_warn + unset).
# Forbids newline/CR/quotes/backslash to prevent injection into
# awgsetup_cfg.init and client.conf via the --endpoint flag (audit).
validate_endpoint() {
    local ep="$1"
    [[ -n "$ep" ]] || return 1
    # Forbid characters that could break the config or inject content
    [[ "$ep" != *$'\n'* && "$ep" != *$'\r'* && \
       "$ep" != *"'"* && "$ep" != *'"'* && "$ep" != *'\\'* && \
       "$ep" != *' '* && "$ep" != *$'\t'* ]] || return 1
    # One of three formats: FQDN, IPv4, [IPv6]
    [[ "$ep" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*|[0-9]{1,3}(\.[0-9]{1,3}){3}|\[[0-9A-Fa-f:]+\])$ ]] || return 1
    # If IPv4 format — additionally validate octet range 0-255
    if [[ "$ep" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        [[ "${BASH_REMATCH[1]}" -le 255 && "${BASH_REMATCH[2]}" -le 255 && \
           "${BASH_REMATCH[3]}" -le 255 && "${BASH_REMATCH[4]}" -le 255 ]] || return 1
    fi
    return 0
}

validate_cidr_list() {
    local input="$1" cidr
    input="${input//$'\r'/}"
    input="${input//$'\t'/ }"
    IFS=',' read -ra cidrs <<< "$input"
    for cidr in "${cidrs[@]}"; do
        cidr=$(echo "$cidr" | tr -d ' ')
        if ! [[ "$cidr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]] \
           || [[ "${BASH_REMATCH[1]}" -gt 255 ]] || [[ "${BASH_REMATCH[2]}" -gt 255 ]] \
           || [[ "${BASH_REMATCH[3]}" -gt 255 ]] || [[ "${BASH_REMATCH[4]}" -gt 255 ]] \
           || [[ "${BASH_REMATCH[5]}" -gt 32 ]]; then
            return 1
        fi
    done
}

configure_routing_mode() {
    if [[ "$CLI_ROUTING_MODE" != "default" ]]; then
        ALLOWED_IPS_MODE=$CLI_ROUTING_MODE
        if [[ "$CLI_ROUTING_MODE" -eq 3 ]]; then
            ALLOWED_IPS=$CLI_CUSTOM_ROUTES
            if [ -z "$ALLOWED_IPS" ]; then die "No networks specified for --route-custom."; fi
        fi
        log "Routing mode from CLI: $ALLOWED_IPS_MODE"
    elif [[ "$AUTO_YES" -eq 1 ]]; then
        ALLOWED_IPS_MODE=2
        log "Routing mode: Amnezia+DNS (--yes, default)."
    else
        echo ""
        log "Select routing mode (client AllowedIPs):"
        echo "  1) All traffic (0.0.0.0/0) - Max privacy, may block LAN"
        echo "  2) Amnezia List+DNS (default) - Recommended for bypassing restrictions"
        echo "  3) Only specified networks (Split Tunneling)"
        read -rp "Your choice [2]: " r_mode < /dev/tty
        ALLOWED_IPS_MODE=${r_mode:-2}
    fi
    case "$ALLOWED_IPS_MODE" in
        1) ALLOWED_IPS="0.0.0.0/0"
           log "Selected mode: All traffic." ;;
        3) if [[ -z "$CLI_CUSTOM_ROUTES" ]]; then
               read -rp "Enter networks (a.b.c.d/xx,...): " ALLOWED_IPS < /dev/tty
               while ! validate_cidr_list "$ALLOWED_IPS"; do
                   log_warn "Invalid CIDR format: '$ALLOWED_IPS'. Expected: x.x.x.x/y[,x.x.x.x/y]"
                   read -rp "Try again: " ALLOWED_IPS < /dev/tty
               done
           else
               ALLOWED_IPS=$CLI_CUSTOM_ROUTES
               if ! validate_cidr_list "$ALLOWED_IPS"; then
                   die "Invalid CIDR format: '$ALLOWED_IPS'. Expected: x.x.x.x/y[,x.x.x.x/y]"
               fi
           fi
           log "Selected mode: Custom ($ALLOWED_IPS)" ;;
        *) ALLOWED_IPS_MODE=2
           ALLOWED_IPS="0.0.0.0/5, 8.0.0.0/7, 11.0.0.0/8, 12.0.0.0/6, 16.0.0.0/4, 32.0.0.0/3, 64.0.0.0/2, 128.0.0.0/3, 160.0.0.0/5, 168.0.0.0/6, 172.0.0.0/12, 172.32.0.0/11, 172.64.0.0/10, 172.128.0.0/9, 173.0.0.0/8, 174.0.0.0/7, 176.0.0.0/4, 192.0.0.0/9, 192.128.0.0/11, 192.160.0.0/13, 192.169.0.0/16, 192.170.0.0/15, 192.172.0.0/14, 192.176.0.0/12, 192.192.0.0/10, 193.0.0.0/8, 194.0.0.0/7, 196.0.0.0/6, 200.0.0.0/5, 208.0.0.0/4, 8.8.8.8/32, 1.1.1.1/32"
           log "Selected mode: Amnezia List+DNS." ;;
    esac
    if [ -z "$ALLOWED_IPS" ]; then die "Failed to determine AllowedIPs."; fi
    export ALLOWED_IPS_MODE ALLOWED_IPS
}

# ==============================================================================
# AWG 2.0 parameter generation (inline — needed in step 0, before downloading awg_common.sh)
# ==============================================================================

# Random number [min, max] via /dev/urandom (uint32 support)
rand_range() {
    local min=$1 max=$2
    local range=$((max - min + 1))
    local random_val
    random_val=$(od -An -tu4 -N4 /dev/urandom | tr -d ' ')
    if [[ -z "$random_val" || ! "$random_val" =~ ^[0-9]+$ ]]; then
        # Fallback: combining two $RANDOM for 30-bit range
        random_val=$(( (RANDOM << 15) | RANDOM ))
    fi
    echo $(( (random_val % range) + min ))
}

# Generate 4 non-overlapping ranges for AWG H1-H4.
# Algorithm: 8 random values → sort → 4 (low, high) pairs.
# Sorting guarantees low ≤ high and non-overlap between pairs.
# Minimum width per range = 1000 (for proper obfuscation).
# Prints 4 "low-high" lines to stdout. Returns 1 on failure.
# Mitigates Russian DPI fingerprinting of static H values (#38).
#
# Range: [0, 2^31-1] = [0, 2147483647]. The AmneziaWG spec allows the
# full uint32 (0-4294967295), but the standalone Windows client
# `amneziawg-windows-client` has a UI validator capped at 2^31-1 in
# `ui/syntax/highlighter.go:isValidHField()` (upstream bug
# amnezia-vpn/amneziawg-windows-client#85, not yet fixed). Values above
# 2^31-1 work on the server, but the client's config editor underlines
# them as invalid and blocks saving. For compatibility we generate in
# the safe half of the range (#40).
#
# Optimization: a single `od -N32 -tu4` call reads 32 bytes = 8 uint32
# values in one operation, instead of 8 separate subprocess calls via
# rand_range. Falls back to rand_range if /dev/urandom is unavailable.
generate_awg_h_ranges() {
    local attempt=0 max_attempts=20
    while (( attempt < max_attempts )); do
        local raw arr=() _v
        raw=$(od -An -N32 -tu4 /dev/urandom 2>/dev/null | tr -s ' \n' '\n' | sed '/^$/d')
        if [[ -n "$raw" ]]; then
            local count=0
            while IFS= read -r _v; do
                [[ "$_v" =~ ^[0-9]+$ ]] || continue
                # Mask 0x7FFFFFFF: clears the top bit, value in [0, 2^31-1]
                # with no bias (each lower bit stays independent).
                arr+=("$(( _v & 2147483647 ))")
                count=$((count + 1))
                (( count == 8 )) && break
            done <<< "$raw"
        fi
        if (( ${#arr[@]} != 8 )); then
            arr=()
            local _i
            for _i in 1 2 3 4 5 6 7 8; do
                arr+=("$(rand_range 0 2147483647)")
            done
        fi
        local sorted
        sorted=$(printf '%s\n' "${arr[@]}" | sort -n)
        arr=()
        while IFS= read -r _v; do arr+=("$_v"); done <<< "$sorted"
        if (( ${arr[1]} - ${arr[0]} >= 1000 )) && \
           (( ${arr[3]} - ${arr[2]} >= 1000 )) && \
           (( ${arr[5]} - ${arr[4]} >= 1000 )) && \
           (( ${arr[7]} - ${arr[6]} >= 1000 )); then
            printf '%s-%s\n' "${arr[0]}" "${arr[1]}"
            printf '%s-%s\n' "${arr[2]}" "${arr[3]}"
            printf '%s-%s\n' "${arr[4]}" "${arr[5]}"
            printf '%s-%s\n' "${arr[6]}" "${arr[7]}"
            return 0
        fi
        attempt=$((attempt + 1))
    done
    return 1
}

# Generate CPS string for I1
# Format: "<r N>" where N is the number of random bytes (32-256)
generate_cps_i1() {
    local n
    n=$(rand_range 32 256)
    echo "<r ${n}>"
}

# Generate all AWG 2.0 parameters
generate_awg_params() {
    local preset="${CLI_PRESET:-default}"
    log "Generating AWG 2.0 parameters (preset: $preset)..."

    case "$preset" in
        default)
            # Jc 3-6: balance between obfuscation and mobile compatibility (Discussion #38)
            AWG_Jc=$(rand_range 3 6)
            AWG_Jmin=$(rand_range 40 89)
            # Jmax = Jmin + 50..250 (~90-339 bytes, Issue #42)
            AWG_Jmax=$(( AWG_Jmin + $(rand_range 50 250) ))
            ;;
        mobile)
            # Jc=3 fixed: alkorrnd (Tele2) — Jc=3 >95%, Jc=4 ~30%, Jc=5 <5%
            # Narrow Jmax: markmokrenko (Yota) — Jmax=70 works, Jmax>300 blocked
            AWG_Jc=3
            AWG_Jmin=$(rand_range 30 50)
            AWG_Jmax=$(( AWG_Jmin + $(rand_range 20 80) ))
            log "  Preset 'mobile': Jc=3, narrow Jmax for mobile networks"
            ;;
        *)
            die "Unknown preset: '$preset'. Allowed: default, mobile"
            ;;
    esac

    # Individual CLI overrides (on top of preset)
    if [[ -n "${CLI_JC:-}" ]]; then
        validate_jc_value "$CLI_JC" || die "Invalid --jc=$CLI_JC (allowed: 1-128)"
        AWG_Jc="$CLI_JC"
    fi
    if [[ -n "${CLI_JMIN:-}" ]]; then
        validate_junk_size "$CLI_JMIN" || die "Invalid --jmin=$CLI_JMIN (allowed: 0-1280)"
        AWG_Jmin="$CLI_JMIN"
    fi
    if [[ -n "${CLI_JMAX:-}" ]]; then
        validate_junk_size "$CLI_JMAX" || die "Invalid --jmax=$CLI_JMAX (allowed: 0-1280)"
        AWG_Jmax="$CLI_JMAX"
    fi

    # Sanity: Jmax >= Jmin
    if [[ "$AWG_Jmax" -lt "$AWG_Jmin" ]]; then
        die "Jmax ($AWG_Jmax) cannot be less than Jmin ($AWG_Jmin)"
    fi

    AWG_PRESET="$preset"
    AWG_S1=$(rand_range 15 150)
    AWG_S2=$(rand_range 15 150)

    # Critical kernel constraint: S1+56 != S2
    # Prevents init and response messages from having the same size
    while [[ $((AWG_S1 + 56)) -eq $AWG_S2 ]]; do
        AWG_S2=$(rand_range 15 150)
    done

    AWG_S3=$(rand_range 8 55)
    AWG_S4=$(rand_range 4 27)

    # H1-H4: 4 random non-overlapping uint32 ranges.
    # Per-install randomization protects against Russian DPI fingerprinting
    # of static H values (Discussion #38, elvaleto/Klavishnik).
    # Algorithm: 8 random uint32 → sort → 4 non-overlapping pairs.
    local _h_lines
    mapfile -t _h_lines < <(generate_awg_h_ranges) || true
    if [[ ${#_h_lines[@]} -ne 4 ]]; then
        die "Failed to generate H1-H4 ranges."
    fi
    AWG_H1="${_h_lines[0]}"
    AWG_H2="${_h_lines[1]}"
    AWG_H3="${_h_lines[2]}"
    AWG_H4="${_h_lines[3]}"

    # I1: CPS concealment
    AWG_I1=$(generate_cps_i1)

    export AWG_Jc AWG_Jmin AWG_Jmax AWG_S1 AWG_S2 AWG_S3 AWG_S4 AWG_PRESET
    export AWG_H1 AWG_H2 AWG_H3 AWG_H4 AWG_I1

    log "  Jc=$AWG_Jc, Jmin=$AWG_Jmin, Jmax=$AWG_Jmax"
    log "  S1=$AWG_S1, S2=$AWG_S2, S3=$AWG_S3, S4=$AWG_S4"
    log "  H1=$AWG_H1"
    log "  H2=$AWG_H2"
    log "  H3=$AWG_H3"
    log "  H4=$AWG_H4"
    log "  I1=$AWG_I1"
    log "AWG 2.0 parameters generated."
}

# ==============================================================================
# System optimization (new in v5.0)
# ==============================================================================

# Detect hardware characteristics
detect_hardware() {
    TOTAL_RAM_MB=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
    CPU_CORES=$(nproc)
    MAIN_NIC=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    log "Hardware: RAM=${TOTAL_RAM_MB}MB, CPU=${CPU_CORES} cores, NIC=${MAIN_NIC}"
}

# Remove unnecessary packages and services
cleanup_system() {
    log "Cleaning system of unnecessary components..."

    # Packages to remove (safe for VPS)
    # snapd and lxd-agent-loader — Ubuntu only, not present on Debian
    local packages_to_remove=()
    local pkg
    local cleanup_list="modemmanager networkd-dispatcher unattended-upgrades packagekit udisks2"
    if [[ "${OS_ID:-ubuntu}" == "ubuntu" ]]; then
        cleanup_list="snapd $cleanup_list lxd-agent-loader"
    fi
    for pkg in $cleanup_list; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
            packages_to_remove+=("$pkg")
        fi
    done

    if [ ${#packages_to_remove[@]} -gt 0 ]; then
        log "Removing: ${packages_to_remove[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get purge -y "${packages_to_remove[@]}" || log_warn "Error removing some packages"
    fi

    # Cleaning snap artifacts (Ubuntu only)
    if [[ "${OS_ID:-ubuntu}" == "ubuntu" && -d /snap ]]; then
        log "Cleaning snap artifacts..."
        rm -rf /snap /var/snap /var/lib/snapd 2>/dev/null || log_warn "snap cleanup error"
    fi

    # cloud-init: remove only if NOT managing network
    # Conservative approach: check cloud-init markers first, then renderer
    if dpkg-query -W -f='${Status}' cloud-init 2>/dev/null | grep -q "ok installed"; then
        local cloud_manages_network=0
        # Check cloud-init markers (priority — safety)
        if ls /etc/netplan/*cloud-init* &>/dev/null 2>&1; then
            cloud_manages_network=1
        elif grep -rq "cloud-init" /etc/netplan/ 2>/dev/null; then
            cloud_manages_network=1
        elif [[ -f /etc/network/interfaces ]] && grep -q "cloud-init" /etc/network/interfaces 2>/dev/null; then
            cloud_manages_network=1
        fi
        if [[ $cloud_manages_network -eq 0 ]]; then
            log "Removing cloud-init (network doesn't depend on it)..."
            DEBIAN_FRONTEND=noninteractive apt-get purge -y cloud-init 2>/dev/null || log_warn "cloud-init removal error"
            rm -rf /etc/cloud /var/lib/cloud 2>/dev/null
        else
            log_warn "cloud-init manages network — skipping removal."
        fi
    fi

    apt-get autoremove -y 2>/dev/null || log_warn "autoremove error"
    log "System cleanup completed."
}

# Swap configuration
optimize_swap() {
    log "Optimizing swap..."
    local target_swap_mb

    if [[ $TOTAL_RAM_MB -le 2048 ]]; then
        target_swap_mb=1024
    else
        target_swap_mb=512
    fi

    # Check current swap
    local current_swap_mb
    current_swap_mb=$(free -m | awk '/Swap:/ {print $2}')

    if [[ $current_swap_mb -ge $target_swap_mb ]]; then
        log "Swap is already sufficient: ${current_swap_mb}MB (target: ${target_swap_mb}MB)"
    else
        log "Creating swap file: ${target_swap_mb}MB"
        # Disable existing swap file if present
        if [[ -f /swapfile ]]; then
            swapoff /swapfile 2>/dev/null
            rm -f /swapfile
        fi
        dd if=/dev/zero of=/swapfile bs=1M count="$target_swap_mb" status=none 2>/dev/null || {
            log_warn "Error creating swap file"
            return 1
        }
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1 || { log_warn "mkswap error"; return 1; }
        swapon /swapfile || { log_warn "swapon error"; return 1; }
        # Add to fstab if missing
        if ! grep -q '/swapfile' /etc/fstab; then
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
        log "Swap file created: ${target_swap_mb}MB"
    fi

    # Setting swappiness
    sysctl -w vm.swappiness=10 >/dev/null 2>&1
}

# Network interface optimization
optimize_nic() {
    if [[ -z "$MAIN_NIC" ]]; then
        log_warn "Main NIC not detected, skipping optimization."
        return 1
    fi

    if ! command -v ethtool &>/dev/null; then
        log_debug "ethtool not found, skipping NIC optimization."
        return 0
    fi

    log "NIC optimization: $MAIN_NIC"
    # Disable GRO/GSO/TSO — may interfere with VPN traffic
    ethtool -K "$MAIN_NIC" gro off 2>/dev/null || log_debug "GRO: not supported/already off."
    ethtool -K "$MAIN_NIC" gso off 2>/dev/null || log_debug "GSO: not supported/already off."
    ethtool -K "$MAIN_NIC" tso off 2>/dev/null || log_debug "TSO: not supported/already off."
    log "NIC optimization completed."
}

# Full system optimization
optimize_system() {
    log "Optimizing system for VPN server..."
    detect_hardware
    optimize_swap
    optimize_nic
    log "System optimization completed."
}

# ==============================================================================
# Sysctl configuration (minimal, for --no-tweaks)
# ==============================================================================

setup_minimal_sysctl() {
    log "Configuring minimal sysctl (--no-tweaks)..."
    local f="/etc/sysctl.d/99-amneziawg-forwarding.conf"
    cat > "$f" << SYSEOF
# AmneziaWG — minimal settings (--no-tweaks)
net.ipv4.ip_forward = 1
SYSEOF
    if [[ "${DISABLE_IPV6:-1}" -eq 1 ]]; then
        cat >> "$f" << SYSEOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
SYSEOF
    else
        cat >> "$f" << SYSEOF
net.ipv6.conf.all.forwarding = 1
SYSEOF
    fi
    sysctl -p "$f" >/dev/null 2>&1 || log_warn "sysctl -p error"
    log "Minimal sysctl configured."
}

# ==============================================================================
# Sysctl configuration (extended)
# ==============================================================================

setup_advanced_sysctl() {
    log "Configuring sysctl..."
    local f="/etc/sysctl.d/99-amneziawg-security.conf"

    # Adaptive buffers based on RAM
    local rmem_max wmem_max netdev_backlog
    if [[ ${TOTAL_RAM_MB:-1024} -ge 2048 ]]; then
        rmem_max=16777216    # 16MB
        wmem_max=16777216
        netdev_backlog=5000
    else
        rmem_max=4194304     # 4MB
        wmem_max=4194304
        netdev_backlog=2500
    fi

    cat > "$f" << EOF
# AmneziaWG 2.0 Security/Performance Settings - $(date)
# Auto-generated by install_amneziawg_en.sh v${SCRIPT_VERSION}

# --- IP Forwarding ---
net.ipv4.ip_forward = 1
$(if [[ "${DISABLE_IPV6:-1}" -eq 1 ]]; then
    echo "net.ipv6.conf.all.disable_ipv6 = 1"
    echo "net.ipv6.conf.default.disable_ipv6 = 1"
    echo "net.ipv6.conf.lo.disable_ipv6 = 1"
else
    echo "# IPv6 not disabled"
    echo "net.ipv6.conf.all.forwarding = 1"
fi)

# --- TCP/IP Hardening ---
# rp_filter = 2 (loose mode): validates source IP against ANY route in the
# table, not against the reverse path through the same interface. Strict mode
# (=1) breaks routing on cloud hosters (Hetzner and similar) where the gateway
# is in a different subnet than the VPS IP — reply packets fail the strict
# reverse path check. Loose mode is safe: spoofed source IPs are still dropped
# if no route exists for them at all. Discussion #41 (z036).
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5
net.ipv4.tcp_rfc1337 = 1

# --- Redirects ---
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
$(if [[ "${DISABLE_IPV6:-1}" -ne 1 ]]; then
    echo "net.ipv6.conf.all.accept_redirects = 0"
    echo "net.ipv6.conf.default.accept_redirects = 0"
fi)

# --- BBR Congestion Control ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- Network Buffers (adaptive) ---
net.core.rmem_max = ${rmem_max}
net.core.wmem_max = ${wmem_max}
net.core.netdev_max_backlog = ${netdev_backlog}

# --- Conntrack ---
net.netfilter.nf_conntrack_max = 65536

# --- Security ---
vm.swappiness = 10
kernel.sysrq = 0

# Suppress kernel warning/notice messages in the hoster VNC console.
# Without this, fail2ban UFW blocks spam the VNC window with "[UFW BLOCK]"
# lines and make the console unusable.
# Format: console_loglevel default_msg_loglevel min_console_loglevel default_console_loglevel
# Value 3 = KERN_ERR — only errors and above reach the console.
# Discussion #41 (z036).
kernel.printk = 3 4 1 3
EOF

    log "Applying sysctl..."
    if ! sysctl -p "$f" >/dev/null 2>&1; then
        # nf_conntrack may be unavailable before module is loaded
        log_warn "Some sysctl parameters did not apply (nf_conntrack will be available later)."
        sysctl -p "$f" 2>/dev/null || true
    fi
}

# ==============================================================================
# Firewall and security
# ==============================================================================

setup_improved_firewall() {
    log "Configuring UFW..."
    if ! command -v ufw &>/dev/null; then install_packages ufw; fi

    # Detect main network interface for route rule
    local main_nic
    main_nic=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    if [[ -z "$main_nic" ]]; then
        log_warn "Could not detect network interface for UFW route."
    fi

    local ufw_errors=0
    if ufw status 2>/dev/null | grep -q inactive; then
        log "UFW is inactive. Configuring..."
        ufw default deny incoming  || { log_warn "UFW: failed to set default deny incoming"; ufw_errors=1; }
        ufw default allow outgoing || { log_warn "UFW: failed to set default allow outgoing"; ufw_errors=1; }
        ufw limit 22/tcp comment "SSH Rate Limit" || { log_warn "UFW: failed to limit SSH"; ufw_errors=1; }
        ufw allow "${AWG_PORT}/udp" comment "AmneziaWG VPN" || { log_warn "UFW: failed to allow VPN port"; ufw_errors=1; }
        if [[ -n "$main_nic" ]]; then
            ufw route allow in on awg0 out on "$main_nic" comment "AmneziaWG Routing" \
                || { log_warn "UFW: failed to add route rule"; ufw_errors=1; }
            log "VPN routing rule added (awg0 → ${main_nic})."
        fi
        if [[ "$ufw_errors" -ne 0 ]]; then
            log_error "One or more UFW rules failed to apply. Check settings manually."
            return 1
        fi
        log "UFW rules added."
        log_warn "--- ENABLING UFW ---"
        log_warn "Verify SSH access!"
        local confirm_ufw="y"
        if [[ "$AUTO_YES" -eq 0 ]]; then
            sleep 5
            read -rp "Enable UFW? [y/N]: " confirm_ufw < /dev/tty
        else
            log "Auto-enabling UFW (--yes)."
        fi
        if ! [[ "$confirm_ufw" =~ ^[Yy]$ ]]; then
            log_warn "UFW not enabled."
            return 1
        fi
        if ! ufw enable <<< "y"; then die "UFW enable error."; fi
        log "UFW enabled."
        # Marker: UFW was enabled by our installer (not by the user beforehand).
        # Used in step_uninstall to decide whether disabling UFW is safe.
        # Protects against destructive uninstall on a VPS where UFW was used
        # for SSH/web hardening BEFORE our script was installed (audit).
        touch "$AWG_DIR/.ufw_enabled_by_installer" 2>/dev/null || \
            log_warn "Failed to create UFW marker — uninstall will not disable UFW automatically."
    else
        log "UFW is active. Updating rules..."
        ufw limit 22/tcp comment "SSH Rate Limit" || { log_warn "UFW: failed to limit SSH"; ufw_errors=1; }
        ufw allow "${AWG_PORT}/udp" comment "AmneziaWG VPN" || { log_warn "UFW: failed to allow VPN port"; ufw_errors=1; }
        if [[ -n "$main_nic" ]]; then
            ufw route allow in on awg0 out on "$main_nic" comment "AmneziaWG Routing" \
                || { log_warn "UFW: failed to add route rule"; ufw_errors=1; }
        fi
        if [[ "$ufw_errors" -ne 0 ]]; then
            log_error "One or more UFW rules failed to apply. Check settings manually."
            return 1
        fi
        ufw reload || log_warn "UFW reload error."
        log "Rules updated."
    fi
    log "UFW configured."
    log "$(ufw status verbose 2>&1)"
    return 0
}

secure_files() {
    log "Setting secure file permissions..."
    chmod 700 "$AWG_DIR" 2>/dev/null
    chmod 700 /etc/amnezia 2>/dev/null
    chmod 700 /etc/amnezia/amneziawg 2>/dev/null
    chmod 600 /etc/amnezia/amneziawg/*.conf 2>/dev/null
    find "$AWG_DIR" -name "*.conf" -type f -exec chmod 600 {} \; 2>/dev/null
    find "$AWG_DIR" -name "*.key" -type f -exec chmod 600 {} \; 2>/dev/null
    find "$AWG_DIR" -name "*.png" -type f -exec chmod 600 {} \; 2>/dev/null
    find "$AWG_DIR" -name "*.vpnuri" -type f -exec chmod 600 {} \; 2>/dev/null
    if [[ -d "$KEYS_DIR" ]]; then
        chmod 700 "$KEYS_DIR" 2>/dev/null
        chmod 600 "$KEYS_DIR"/* 2>/dev/null
    fi
    [[ -f "$CONFIG_FILE" ]] && chmod 600 "$CONFIG_FILE"
    [[ -f "$LOG_FILE" ]] && chmod 640 "$LOG_FILE"
    [[ -f "$MANAGE_SCRIPT_PATH" ]] && chmod 700 "$MANAGE_SCRIPT_PATH"
    [[ -f "$COMMON_SCRIPT_PATH" ]] && chmod 700 "$COMMON_SCRIPT_PATH"
    log "File permissions set."
}

setup_fail2ban() {
    log "Configuring Fail2Ban..."
    if ! command -v fail2ban-client &>/dev/null; then install_packages fail2ban; fi
    if ! command -v fail2ban-client &>/dev/null; then
        log_warn "Fail2Ban not installed, skipping."
        return 1
    fi

    # Debian: journald instead of rsyslog, needs python3-systemd
    if [[ "${OS_ID:-}" == "debian" ]]; then
        install_packages python3-systemd
    fi

    mkdir -p /etc/fail2ban/jail.d 2>/dev/null

    # Backend: systemd for Debian (no rsyslog), auto for Ubuntu
    local f2b_backend="auto"
    if [[ "${OS_ID:-}" == "debian" ]]; then
        f2b_backend="systemd"
    fi

    cat > /etc/fail2ban/jail.d/amneziawg.conf << JAILEOF || { log_warn "jail.d/amneziawg.conf write error"; return 1; }
# AmneziaWG — SSH protection (managed by amneziawg-installer)
[sshd]
enabled = true
backend = ${f2b_backend}
maxretry = 5
findtime = 10m
bantime  = 1h
banaction = ufw
JAILEOF

    if systemctl restart fail2ban; then
        log "Fail2Ban configured and restarted."
    else
        log_warn "fail2ban restart error"
    fi
    return 0
}

# ==============================================================================
# Service status check
# ==============================================================================

check_service_status() {
    log "Checking service status..."
    local ok=1

    if systemctl is-failed --quiet awg-quick@awg0; then
        log_error "Service FAILED!"
        ok=0
    fi

    if ! ip addr show awg0 &>/dev/null; then
        log_error "Interface awg0 not found!"
        ok=0
    fi

    if ! awg show 2>/dev/null | grep -q "interface: awg0"; then
        log_error "awg show cannot see interface!"
        ok=0
    fi

    # Port check
    local port_check=${AWG_PORT:-0}
    if [[ "$port_check" -eq 0 ]] && [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        port_check=$(safe_read_config_key "AWG_PORT" "$CONFIG_FILE")
        port_check=${port_check:-0}
    fi
    if [[ "$port_check" -ne 0 ]]; then
        if ! ss -lunp | grep -q ":${port_check} "; then
            log_error "Port $port_check/udp is not listening!"
            ok=0
        fi
    fi

    # AWG 2.0 parameter check
    if awg show awg0 2>/dev/null | grep -q "jc:"; then
        log "AWG 2.0 parameters active."
    else
        log_warn "AWG 2.0 parameters not detected in awg show."
    fi

    if [[ "$ok" -eq 1 ]]; then
        log "Service and interface status OK."
        return 0
    else
        return 1
    fi
}

# ==============================================================================
# Diagnostics
# ==============================================================================

create_diagnostic_report() {
    log "Creating diagnostics..."
    local rf
    rf="$AWG_DIR/diag_$(date +%F_%T).txt"
    {
        echo "=== AMNEZIAWG 2.0 DIAGNOSTIC REPORT ==="
        echo ""
        echo "!!! WARNING: This report contains IP addresses, ports and routes."
        echo "!!! Review and redact private data before posting to public issues."
        echo ""
        echo "Generated: $(date)"
        echo "Hostname: $(hostname)"
        echo "Installer: v${SCRIPT_VERSION}"
        echo ""
        echo "--- OS ---"
        lsb_release -ds 2>/dev/null || cat /etc/os-release
        uname -a
        echo ""
        echo "--- Hardware ---"
        echo "RAM: $(awk '/MemTotal/ {printf "%.0f MB", $2/1024}' /proc/meminfo)"
        echo "CPU: $(nproc) cores"
        echo "Swap: $(free -m | awk '/Swap:/ {print $2}') MB"
        echo ""
        echo "--- Configuration ($CONFIG_FILE) ---"
        if [[ -f "$CONFIG_FILE" ]]; then
            sed 's/AWG_ENDPOINT=.*/AWG_ENDPOINT=[HIDDEN]/' "$CONFIG_FILE"
        else
            echo "File not found"
        fi
        echo ""
        echo "--- Server Config ($SERVER_CONF_FILE) ---"
        # Mask private key
        if [[ -f "$SERVER_CONF_FILE" ]]; then
            sed 's/PrivateKey = .*/PrivateKey = [HIDDEN]/' "$SERVER_CONF_FILE"
        else
            echo "File not found"
        fi
        echo ""
        echo "--- Service Status ---"
        systemctl status awg-quick@awg0 --no-pager -l 2>/dev/null || echo "Service not found"
        echo ""
        echo "--- AWG Status ---"
        awg show 2>/dev/null || echo "awg show failed"
        echo ""
        echo "--- AWG Version ---"
        awg --version 2>/dev/null || echo "awg --version failed"
        echo ""
        echo "--- Network Interfaces ---"
        ip a 2>/dev/null
        echo ""
        echo "--- Listening Ports ---"
        ss -lunp 2>/dev/null
        echo ""
        echo "--- Firewall Status ---"
        if command -v ufw &>/dev/null; then ufw status verbose; else echo "UFW N/A"; fi
        echo ""
        echo "--- Routing Table ---"
        ip route 2>/dev/null
        echo ""
        echo "--- Kernel Params ---"
        sysctl net.ipv4.ip_forward net.ipv6.conf.all.disable_ipv6 2>/dev/null
        echo ""
        echo "--- AWG Journal (last 50) ---"
        journalctl -u awg-quick@awg0 -n 50 --no-pager --output=cat 2>/dev/null || echo "N/A"
        echo ""
        echo "--- Client List ---"
        grep "^#_Name = " "$SERVER_CONF_FILE" 2>/dev/null | sed 's/^#_Name = //' || echo "N/A"
        echo ""
        echo "--- DKMS Status ---"
        dkms status 2>/dev/null || echo "N/A"
        echo ""
        echo "--- Module Info ---"
        modinfo amneziawg 2>/dev/null || echo "N/A"
        echo ""
        echo "=== END ==="
    } > "$rf" || log_error "Report write error."
    chmod 600 "$rf" || log_warn "Report chmod error."
    log "Report: $rf"
}

# ==============================================================================
# Uninstall
# ==============================================================================

step_uninstall() {
    log "### AMNEZIAWG UNINSTALL ###"
    echo ""
    echo "WARNING! Complete removal of AmneziaWG and configurations."
    echo "This process is irreversible!"
    echo ""
    local confirm="" backup="Y"
    if [[ "$AUTO_YES" -eq 0 ]]; then
        read -rp "Are you sure? (type 'yes'): " confirm < /dev/tty
        if [[ "$confirm" != "yes" ]]; then log "Uninstall cancelled."; exit 1; fi
        read -rp "Create backup before removal? [Y/n]: " backup < /dev/tty
    else
        log "Auto-confirming uninstall (--yes)."
    fi
    if [[ -z "$backup" || "$backup" =~ ^[Yy]$ ]]; then
        local bf
        bf="$HOME/awg_uninstall_backup_$(date +%F_%H-%M-%S).tar.gz"
        log "Creating backup: $bf"
        if tar -czf "$bf" -C / etc/amnezia "$AWG_DIR" --ignore-failed-read 2>/dev/null \
            && chmod 600 "$bf"; then
            log "Backup created: $bf"
        else
            log_warn "Backup failed — check $bf manually before continuing"
        fi
    fi
    # Load --no-tweaks flag from saved configuration
    local saved_no_tweaks=0
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        saved_no_tweaks=$(safe_read_config_key "NO_TWEAKS" "$CONFIG_FILE" 2>/dev/null) || saved_no_tweaks=0
        saved_no_tweaks=${saved_no_tweaks:-0}
    fi
    log "Stopping service..."
    systemctl stop awg-quick@awg0 2>/dev/null
    systemctl disable awg-quick@awg0 2>/dev/null
    modprobe -r amneziawg 2>/dev/null || true
    if [[ "$saved_no_tweaks" -eq 0 ]]; then
        log "Cleaning up AmneziaWG UFW rules..."
        if command -v ufw &>/dev/null; then
            local port_to_del
            if [[ -f "$CONFIG_FILE" ]]; then
                # shellcheck source=/dev/null
                port_to_del=$(safe_read_config_key "AWG_PORT" "$CONFIG_FILE")
            fi
            port_to_del=${port_to_del:-39743}
            # Removing our rules is ALWAYS performed (idempotent)
            ufw delete allow "${port_to_del}/udp" 2>/dev/null
            # To delete a route rule we need an exact match with how it was created:
            # "ufw route allow in on awg0 out on <nic>". Without "out on", UFW will
            # not find the rule and it stays in ufw status. Discussion #41.
            local _nic
            _nic=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
            if [[ -n "$_nic" ]]; then
                ufw route delete allow in on awg0 out on "$_nic" 2>/dev/null
            fi
            # Fallback: try deleting without out on (for compatibility with older rules)
            ufw route delete allow in on awg0 2>/dev/null

            # ufw disable runs ONLY if UFW was enabled by our installer.
            # Protects against destructive uninstall on a VPS where UFW was used
            # for SSH/web hardening BEFORE our script was installed (audit).
            # Backwards compat: older installs without the marker keep UFW active.
            if [[ -f "$AWG_DIR/.ufw_enabled_by_installer" ]]; then
                log "Disabling UFW (was enabled by our installer)..."
                ufw --force disable 2>/dev/null
                rm -f "$AWG_DIR/.ufw_enabled_by_installer"
            else
                log "Leaving UFW active (was active before installation, or older installer version)."
            fi
        fi
        log "Removing Fail2Ban bans..."
        if command -v fail2ban-client &>/dev/null; then
            fail2ban-client unban --all 2>/dev/null || true
            systemctl stop fail2ban 2>/dev/null
        fi
    else
        log "Skipping UFW/Fail2Ban (installed with --no-tweaks)."
    fi
    log "Removing packages..."
    if [[ "$saved_no_tweaks" -eq 0 ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y amneziawg-dkms amneziawg-tools fail2ban qrencode 2>/dev/null || log_warn "Purge error."
    else
        DEBIAN_FRONTEND=noninteractive apt-get purge -y amneziawg-dkms amneziawg-tools qrencode 2>/dev/null || log_warn "Purge error."
    fi
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>/dev/null || log_warn "Autoremove error."
    log "Removing PPA and files..."
    rm -f /etc/apt/sources.list.d/amnezia-ppa.sources \
        /etc/apt/sources.list.d/amnezia-ppa.list \
        /etc/apt/sources.list.d/amnezia-ubuntu-ppa-*.list \
        /etc/apt/sources.list.d/amnezia-ubuntu-ppa-*.sources \
        /etc/apt/keyrings/amnezia-ppa.gpg 2>/dev/null
    rm -rf /etc/amnezia \
        /etc/modules-load.d/amneziawg.conf \
        /etc/sysctl.d/99-amneziawg-security.conf \
        /etc/sysctl.d/99-amneziawg-forwarding.conf \
        /etc/logrotate.d/amneziawg* || log_warn "File removal error."
    if [[ "$saved_no_tweaks" -eq 0 ]]; then
        # Remove only our own jail file.
        # Previously there was a heuristic "if jail.local contains banaction = ufw,
        # remove the whole file" — too broad a filter, could wipe an unrelated
        # jail.local with custom jails. Heuristic removed (audit).
        # If a user still has a jail.local from very old installer versions,
        # leave it for them to deal with.
        rm -f /etc/fail2ban/jail.d/amneziawg.conf 2>/dev/null
    fi
    log "Removing DKMS..."
    rm -rf /var/lib/dkms/amneziawg* || log_warn "DKMS removal error."
    log "Restoring sysctl..."
    if grep -q "disable_ipv6" /etc/sysctl.conf 2>/dev/null; then
        sed -i '/disable_ipv6/d' /etc/sysctl.conf || log_warn "sed sysctl.conf error"
    fi
    sysctl -p --system 2>/dev/null
    rm -f /etc/apt/sources.list.d/*.bak-* "$AWG_DIR"/ubuntu.sources.bak-* 2>/dev/null || true
    log "Removing cron and scripts..."
    rm -f /etc/cron.d/awg-expiry 2>/dev/null
    log "=== UNINSTALL COMPLETED ==="
    # Copy log and remove working directory
    cp "$LOG_FILE" "$HOME/awg_uninstall.log" 2>/dev/null || true
    rm -rf "$AWG_DIR" 2>/dev/null || true
    exit 0
}

# ==============================================================================
# STEP 0: Initialization
# ==============================================================================

initialize_setup() {
    if [ "$(id -u)" -ne 0 ]; then die "Run the script as root (sudo bash $0)."; fi

    mkdir -p "$AWG_DIR" || die "Error creating $AWG_DIR"
    chown root:root "$AWG_DIR"

    # Process-wide lock: prevents two install_amneziawg.sh instances from
    # running concurrently. Without it two parallel runs could read the
    # same setup_state, race each other on apt-get/dkms/ufw and corrupt
    # package state (audit).
    # FD 9 is fixed and does not conflict with update_state (uses 200).
    # The lock is held open for the whole process lifetime — released
    # automatically on exit.
    INSTALL_LOCK_FILE="$AWG_DIR/.install.lock"
    exec 9>"$INSTALL_LOCK_FILE" || die "Cannot open $INSTALL_LOCK_FILE"
    if ! flock -n 9; then
        die "Another install_amneziawg_en.sh instance is already running. Wait for it to finish, or if the process is hung, remove $INSTALL_LOCK_FILE and try again."
    fi

    touch "$LOG_FILE" || die "Failed to create log file $LOG_FILE"
    chmod 640 "$LOG_FILE"
    log "--- STARTING AmneziaWG 2.0 INSTALLATION (v${SCRIPT_VERSION}) ---"
    log "### STEP 0: Initialization and parameter check ###"
    cd "$AWG_DIR" || die "Error changing to $AWG_DIR"
    log "Working directory: $AWG_DIR"
    log "Log file: $LOG_FILE"

    check_os_version
    check_free_space

    local default_port=39743
    local default_subnet="10.9.9.1/24"
    local config_exists=0

    # Variable initialization
    AWG_PORT=$default_port
    AWG_TUNNEL_SUBNET=$default_subnet
    DISABLE_IPV6="default"
    ALLOWED_IPS_MODE="default"
    ALLOWED_IPS=""
    AWG_ENDPOINT=""

    # Load config
    if [[ -f "$CONFIG_FILE" ]]; then
        log "Configuration file found $CONFIG_FILE. Loading settings..."
        config_exists=1
        # shellcheck source=/dev/null
        safe_load_config "$CONFIG_FILE" || log_warn "Failed to fully load settings from $CONFIG_FILE."
        AWG_PORT=${AWG_PORT:-$default_port}
        AWG_TUNNEL_SUBNET=${AWG_TUNNEL_SUBNET:-$default_subnet}
        DISABLE_IPV6=${DISABLE_IPV6:-"default"}
        ALLOWED_IPS_MODE=${ALLOWED_IPS_MODE:-"default"}
        ALLOWED_IPS=${ALLOWED_IPS:-""}
        AWG_ENDPOINT=${AWG_ENDPOINT:-""}
        log "Settings loaded from file."
    else
        log "Configuration file $CONFIG_FILE not found."
    fi

    # CLI override
    AWG_PORT=${CLI_PORT:-$AWG_PORT}
    AWG_TUNNEL_SUBNET=${CLI_SUBNET:-$AWG_TUNNEL_SUBNET}
    if [[ "$CLI_DISABLE_IPV6" != "default" ]]; then DISABLE_IPV6=$CLI_DISABLE_IPV6; fi
    if [[ "$CLI_ROUTING_MODE" != "default" ]]; then
        ALLOWED_IPS_MODE=$CLI_ROUTING_MODE
        if [[ "$CLI_ROUTING_MODE" -eq 3 ]]; then ALLOWED_IPS=$CLI_CUSTOM_ROUTES; fi
    fi
    if [[ -n "$CLI_ENDPOINT" ]]; then
        if ! validate_endpoint "$CLI_ENDPOINT"; then
            die "Invalid --endpoint: '$CLI_ENDPOINT'. Allowed formats: FQDN (vpn.example.com), IPv4 (1.2.3.4), [IPv6] ([2001:db8::1]). Spaces, tabs, quotes, backslashes and newlines are forbidden."
        fi
        AWG_ENDPOINT=$CLI_ENDPOINT
    fi
    if [[ "$CLI_NO_TWEAKS" -eq 1 ]]; then NO_TWEAKS=1; fi

    # Validate after CLI override
    validate_port "$AWG_PORT"
    validate_subnet "$AWG_TUNNEL_SUBNET"
    # AWG_ENDPOINT may have come from CONFIG_FILE via safe_load_config (no CLI override).
    # If the value is present and invalid — log_warn + reset to "" so the installer
    # falls back to auto-detect via get_server_public_ip (audit).
    if [[ -n "$AWG_ENDPOINT" ]] && ! validate_endpoint "$AWG_ENDPOINT"; then
        log_warn "AWG_ENDPOINT='$AWG_ENDPOINT' from $CONFIG_FILE is invalid, falling back to auto-detect."
        AWG_ENDPOINT=""
    fi

    # Request settings from user only on first run
    if [[ "$config_exists" -eq 0 ]]; then
        log "Requesting settings from user (first run)."
        if [[ "$AUTO_YES" -eq 0 ]]; then
            read -rp "Enter AmneziaWG UDP port (1024-65535) [${AWG_PORT}]: " input_port < /dev/tty
            if [[ -n "$input_port" ]]; then AWG_PORT=$input_port; fi
        fi
        validate_port "$AWG_PORT"
        if [[ "$AUTO_YES" -eq 0 ]]; then
            read -rp "Enter tunnel subnet [${AWG_TUNNEL_SUBNET}]: " input_subnet < /dev/tty
            if [[ -n "$input_subnet" ]]; then AWG_TUNNEL_SUBNET=$input_subnet; fi
        fi
        validate_subnet "$AWG_TUNNEL_SUBNET"
        if [[ "$DISABLE_IPV6" == "default" ]]; then configure_ipv6; fi
        if [[ "$ALLOWED_IPS_MODE" == "default" ]]; then configure_routing_mode; fi
    else
        log "Using settings from $CONFIG_FILE."
        if [[ "$ALLOWED_IPS_MODE" == "3" ]] && [[ -n "$ALLOWED_IPS" ]]; then
            if ! validate_cidr_list "$ALLOWED_IPS"; then
                die "Invalid ALLOWED_IPS in config: '$ALLOWED_IPS'. Delete $CONFIG_FILE and re-run the installer."
            fi
        fi
    fi

    # Default values
    if [[ "$DISABLE_IPV6" == "default" ]]; then DISABLE_IPV6=1; fi
    if [[ "$ALLOWED_IPS_MODE" == "default" ]]; then ALLOWED_IPS_MODE=2; fi
    if [[ -z "$ALLOWED_IPS" ]]; then configure_routing_mode; fi

    # Port check (skip if AWG service is already listening on this port)
    if ! systemctl is-active --quiet awg-quick@awg0 2>/dev/null; then
        check_port_availability "$AWG_PORT" || die "Port $AWG_PORT/udp is occupied."
    else
        log "AWG service is active — skipping port check."
    fi

    # AWG 2.0 parameter generation
    # Regenerate if: first run OR explicit CLI override (--preset/--jc/--jmin/--jmax)
    if [[ -z "${AWG_Jc:-}" ]] || [[ -n "${CLI_PRESET:-}" ]] || [[ -n "${CLI_JC:-}" ]] \
        || [[ -n "${CLI_JMIN:-}" ]] || [[ -n "${CLI_JMAX:-}" ]]; then
        generate_awg_params
    else
        log "AWG 2.0 parameters already set from config."
    fi

    # Save configuration
    log "Saving settings to $CONFIG_FILE..."
    local temp_conf
    temp_conf=$(mktemp) || die "mktemp error."
    _install_temp_files+=("$temp_conf")
    cat > "$temp_conf" << EOF
# AmneziaWG 2.0 installation configuration (Auto-generated)
# Used by installation and management scripts
export OS_ID='${OS_ID:-ubuntu}'
export OS_VERSION='${OS_VERSION:-}'
export OS_CODENAME='${OS_CODENAME:-}'
export AWG_PORT=${AWG_PORT}
export AWG_TUNNEL_SUBNET='${AWG_TUNNEL_SUBNET}'
export DISABLE_IPV6=${DISABLE_IPV6}
export ALLOWED_IPS_MODE=${ALLOWED_IPS_MODE}
export ALLOWED_IPS='${ALLOWED_IPS}'
export AWG_ENDPOINT='${AWG_ENDPOINT}'
# AWG 2.0 Parameters
export AWG_Jc=${AWG_Jc}
export AWG_Jmin=${AWG_Jmin}
export AWG_Jmax=${AWG_Jmax}
export AWG_S1=${AWG_S1}
export AWG_S2=${AWG_S2}
export AWG_S3=${AWG_S3}
export AWG_S4=${AWG_S4}
export AWG_H1='${AWG_H1}'
export AWG_H2='${AWG_H2}'
export AWG_H3='${AWG_H3}'
export AWG_H4='${AWG_H4}'
export AWG_I1='${AWG_I1}'
export AWG_PRESET='${AWG_PRESET:-default}'
export NO_TWEAKS=${NO_TWEAKS}
export AWG_APPLY_MODE='${AWG_APPLY_MODE:-syncconf}'
EOF
    if ! mv "$temp_conf" "$CONFIG_FILE"; then
        rm -f "$temp_conf"
        die "Error saving $CONFIG_FILE"
    fi
    chmod 600 "$CONFIG_FILE" || log_warn "chmod $CONFIG_FILE error"
    log "Settings saved."
    export AWG_PORT AWG_TUNNEL_SUBNET DISABLE_IPV6 ALLOWED_IPS_MODE ALLOWED_IPS AWG_ENDPOINT
    log "Port: ${AWG_PORT}/udp"
    log "Subnet: ${AWG_TUNNEL_SUBNET}"
    log "IPv6 disable: $DISABLE_IPV6"
    log "AllowedIPs mode: $ALLOWED_IPS_MODE"

    # Loading state
    if [[ -f "$STATE_FILE" ]]; then
        current_step=$(cat "$STATE_FILE")
        if ! [[ "$current_step" =~ ^[0-9]+$ ]]; then
            log_warn "$STATE_FILE corrupted."
            current_step=1
            update_state 1
        else
            log "Resuming from step $current_step."
        fi
    else
        current_step=1
        log "Starting from step 1."
        update_state 1
    fi
    log "Step 0 completed."
}

# ==============================================================================
# STEP 1: System update, cleanup, and optimization
# ==============================================================================

step1_update_and_optimize() {
    update_state 1
    log "### STEP 1: System update, cleanup, and optimization ###"

    # Clean unnecessary components (BEFORE update to save bandwidth/time)
    if [[ "$NO_TWEAKS" -eq 0 ]]; then
        cleanup_system
    else
        log "Skipping system cleanup (--no-tweaks)."
    fi

    log "Updating package lists..."
    apt_update_tolerant || die "apt update error."

    log "Unlocking dpkg..."
    if ! apt-get check &>/dev/null; then
        log_warn "dpkg locked or corrupted, fixing..."
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a || log_warn "dpkg --configure -a."
    fi

    log "Updating system..."
    DEBIAN_FRONTEND=noninteractive apt full-upgrade -y || die "apt full-upgrade error."
    log "System updated."

    install_packages curl wget gpg sudo ethtool

    if [[ "$NO_TWEAKS" -eq 0 ]]; then
        # System optimization
        optimize_system
        # Sysctl configuration
        setup_advanced_sysctl
    else
        log "Skipping optimization and hardening (--no-tweaks)."
        setup_minimal_sysctl
    fi

    log "Step 1 completed successfully."
    request_reboot 2
}

# ==============================================================================
# ARM prebuilt support
# ==============================================================================

# _try_install_prebuilt_arm — download and install a prebuilt amneziawg .deb
# for the current ARM kernel from the arm-packages GitHub release.
#
# Returns 0 if a matching prebuilt was installed successfully.
# Returns 1 if no match was found or installation failed (caller falls back to DKMS).
#
# Prebuilt packages are built by .github/workflows/arm-build.yml and published
# to the arm-packages release tag. The filename encodes both the target ID and
# the exact kernel version: amneziawg-kmod-<target-id>_<kernel-version>_<arch>.deb
#
# Kernel version matching is exact — the module vermagic must match uname -r.
# DKMS is the preferred path for kernels that haven't been pre-built yet.
_try_install_prebuilt_arm() {
    local kernel arch target_id asset_name asset_url tmpfile tmpsha expected_sha actual_sha
    kernel="$(uname -r)"
    arch="$(dpkg --print-architecture)"

    # Map kernel string to a build target ID
    if [[ "$kernel" == *+rpt-rpi-2712* ]]; then
        target_id="rpi5-bookworm-arm64"
    elif [[ "$kernel" == *+rpt* && "$arch" == "arm64" ]]; then
        target_id="rpi-bookworm-arm64"
    elif [[ "$kernel" == *+rpt* && "$arch" == "armhf" ]]; then
        target_id="rpi-bookworm-armhf"
    elif [[ "$kernel" == *-generic* && "${OS_VERSION:-}" == "24.04" ]]; then
        target_id="ubuntu-2404-arm64"
    elif [[ "$kernel" == *-generic* && "${OS_VERSION:-}" == "22.04" ]]; then
        target_id="ubuntu-2204-arm64"
    elif [[ "$kernel" == *-arm64* && "${OS_ID:-}" == "debian" ]]; then
        target_id="debian-bookworm-arm64"
    else
        log "No prebuilt target for kernel $kernel ($arch)"
        return 1
    fi

    # Asset filename encodes the exact kernel version
    asset_name="amneziawg-kmod-${target_id}_${kernel}_${arch}.deb"
    asset_url="https://github.com/bivlked/amneziawg-installer/releases/download/arm-packages/${asset_name}"

    log "Trying prebuilt: $asset_name"
    tmpfile="$(mktemp /tmp/amneziawg-prebuilt-XXXXXX.deb)"
    tmpsha="$(mktemp /tmp/amneziawg-prebuilt-XXXXXX.deb.sha256)"

    # Download SHA256 checksum first
    if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 \
            -o "$tmpsha" "${asset_url}.sha256" 2>/dev/null; then
        log "Prebuilt not available for $kernel — using DKMS"
        rm -f "$tmpfile" "$tmpsha"
        return 1
    fi

    if curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 \
            -o "$tmpfile" "$asset_url" 2>/dev/null; then
        # Verify integrity before installing a kernel module
        expected_sha="$(cat "$tmpsha")"
        actual_sha="$(sha256sum "$tmpfile" | awk '{print $1}')"
        rm -f "$tmpsha"
        if [[ "$expected_sha" != "$actual_sha" ]]; then
            log_warn "Prebuilt SHA256 mismatch — discarding download"
            rm -f "$tmpfile"
            return 1
        fi

        log "Downloaded prebuilt (SHA256 OK), installing..."
        if dpkg -i "$tmpfile" 2>/dev/null; then
            rm -f "$tmpfile"
            log "Prebuilt installed: $asset_name"
            return 0
        else
            log_warn "Prebuilt install failed (vermagic mismatch or corrupt package)"
            rm -f "$tmpfile"
            return 1
        fi
    else
        log "Prebuilt not available for $kernel — using DKMS"
        rm -f "$tmpfile" "$tmpsha"
        return 1
    fi
}

# ==============================================================================
# STEP 2: Installing AmneziaWG and dependencies
# ==============================================================================

step2_install_amnezia() {
    update_state 2
    log "### STEP 2: Installing AmneziaWG and dependencies ###"
    _APT_UPDATED=0  # Reset: new sources will be added in this step

    apt_update_tolerant || die "apt update error."

    # PPA Amnezia (without software-properties-common)
    log "Adding Amnezia PPA..."

    # Determine codename for PPA
    # On Debian, map to nearest Ubuntu codename since PPA is Launchpad (Ubuntu)
    # Debian 12 (bookworm) → focal, Debian 13 (trixie) → noble
    local codename ppa_codename
    codename="${OS_CODENAME:-$(lsb_release -sc 2>/dev/null || echo "noble")}"
    case "${OS_ID:-ubuntu}" in
        debian)
            case "$codename" in
                bookworm) ppa_codename="focal" ;;
                trixie)   ppa_codename="noble" ;;
                *)        ppa_codename="noble" ;;
            esac
            log "Debian ($codename) → PPA codename: $ppa_codename"
            ;;
        *)
            ppa_codename="$codename"
            ;;
    esac

    local keyring_dir="/etc/apt/keyrings"
    local keyring_file="${keyring_dir}/amnezia-ppa.gpg"
    local ppa_sources="/etc/apt/sources.list.d/amnezia-ppa.sources"
    local ppa_list="/etc/apt/sources.list.d/amnezia-ppa.list"
    # Check for legacy files (from add-apt-repository of previous versions)
    local legacy_list="/etc/apt/sources.list.d/amnezia-ubuntu-ppa-${codename}.list"
    local legacy_sources="/etc/apt/sources.list.d/amnezia-ubuntu-ppa-${codename}.sources"
    if [[ -f "$legacy_list" ]] || [[ -f "$legacy_sources" ]]; then
        log "PPA already added (legacy format)."
    elif [[ -f "$ppa_sources" ]] || [[ -f "$ppa_list" ]]; then
        log "PPA already added."
    else
        mkdir -p "$keyring_dir"
        log "Importing Amnezia PPA GPG key..."
        curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x57290828" \
            | gpg --dearmor -o "$keyring_file" \
            || die "Amnezia PPA GPG key import error."
        chmod 644 "$keyring_file"

        # Debian 12 uses traditional .list format, Debian 13+ and Ubuntu 24.04+ use DEB822 .sources
        if [[ "${OS_ID:-ubuntu}" == "debian" && "${OS_VERSION}" == "12" ]]; then
            log "Debian 12: using traditional .list format"
            echo "deb [signed-by=${keyring_file}] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu ${ppa_codename} main" \
                > "$ppa_list" || die "Failed to create $ppa_list"
            chmod 644 "$ppa_list"
        else
            cat > "$ppa_sources" <<PPASRC || die "PPA sources creation error."
Types: deb
URIs: https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu
Suites: ${ppa_codename}
Components: main
Signed-By: ${keyring_file}
PPASRC
            chmod 644 "$ppa_sources"
        fi
        log "PPA added."
    fi
    apt_update_tolerant || die "apt update error."

    # AmneziaWG + qrencode packages (NO Python!)
    log "Installing AmneziaWG packages..."

    # On ARM: try prebuilt .deb first (no build tools or headers required).
    # Falls back to DKMS if no matching prebuilt is available or download fails.
    local arch
    arch="$(uname -m)"
    if [[ "$arch" == "aarch64" || "$arch" == "armv7l" ]]; then
        if _try_install_prebuilt_arm; then
            log "Prebuilt kernel module installed. Installing userspace tools from PPA..."
            install_packages "amneziawg-tools" "wireguard-tools" "qrencode"
            log "Step 2 completed (prebuilt ARM)."
            request_reboot 3
            return
        fi
        log "No matching prebuilt — falling back to DKMS build."
    fi

    local packages=("amneziawg-dkms" "amneziawg-tools" "wireguard-tools" "dkms"
                    "build-essential" "dpkg-dev" "qrencode")

    # Linux headers: on Debian, exact linux-headers-$(uname -r) may not be available
    local current_headers
    current_headers="linux-headers-$(uname -r)"
    if dpkg -s "$current_headers" &>/dev/null || apt-cache show "$current_headers" &>/dev/null 2>&1; then
        packages+=("$current_headers")
    else
        log_warn "No headers for $(uname -r), installing generic package..."
        local kernel_release
        kernel_release="$(uname -r)"
        if [[ "$kernel_release" == *+rpt* || "$kernel_release" == *-rpi* ]]; then
            # Raspberry Pi Foundation kernel (+rpt suffix) — use RPi meta-package
            # linux-headers-rpi-2712: Pi 5 / Cortex-A76; linux-headers-rpi-v8: Pi 3/4 arm64
            local rpi_headers
            if [[ "$kernel_release" == *2712* ]]; then
                rpi_headers="linux-headers-rpi-2712"
            else
                rpi_headers="linux-headers-rpi-v8"
            fi
            log "Raspberry Pi kernel detected, using $rpi_headers"
            packages+=("$rpi_headers")
        elif [[ "${OS_ID:-ubuntu}" == "debian" ]]; then
            # On Debian: linux-headers-$(dpkg --print-architecture)
            local arch_pkg
            arch_pkg="linux-headers-$(dpkg --print-architecture 2>/dev/null || echo "amd64")"
            packages+=("$arch_pkg")
        else
            packages+=("linux-headers-generic")
        fi
    fi
    install_packages "${packages[@]}"

    # DKMS status
    log "Checking DKMS status..."
    local dkms_stat
    dkms_stat=$(dkms status 2>&1)
    if ! echo "$dkms_stat" | grep -q 'amneziawg.*installed'; then
        log_warn "DKMS status not OK."
        log_msg "WARN" "$dkms_stat"
    else
        log "DKMS status OK."
    fi

    log "Step 2 completed."
    request_reboot 3
}

# ==============================================================================
# STEP 3: Kernel module check
# ==============================================================================

step3_check_module() {
    update_state 3
    log "### STEP 3: Kernel module check ###"
    sleep 2

    if ! lsmod | grep -q -w amneziawg; then
        log "Module not loaded. Loading..."
        modprobe amneziawg || die "modprobe amneziawg error."
        log "Module loaded."
        local mf="/etc/modules-load.d/amneziawg.conf"
        mkdir -p "$(dirname "$mf")"
        if ! grep -qxF 'amneziawg' "$mf" 2>/dev/null; then
            echo "amneziawg" > "$mf" || log_warn "Write error $mf"
            log "Added to $mf."
        fi
    else
        log "amneziawg module loaded."
    fi

    log "Module information:"
    modinfo amneziawg | grep -E "filename|version|vermagic|srcversion" | while IFS= read -r line; do
        log "  $line"
    done

    local cv kr
    cv=$(modinfo amneziawg 2>/dev/null | awk '/^vermagic:/{print $2}')
    if [[ -z "$cv" ]]; then
        die "Failed to read amneziawg vermagic. Check: modprobe amneziawg && modinfo amneziawg"
    fi
    kr=$(uname -r)
    if [[ "$cv" != "$kr" ]]; then
        log_warn "VerMagic MISMATCH: Module($cv) != Kernel($kr)!"
    else
        log "VerMagic matches."
    fi

    # Check awg version
    if command -v awg &>/dev/null; then
        local awg_ver
        awg_ver=$(awg --version 2>/dev/null || echo "unknown")
        log "awg version: $awg_ver"
    else
        log_warn "awg command not found!"
    fi

    log "Step 3 completed."
    update_state 4
}

# ==============================================================================
# STEP 4: Firewall configuration
# ==============================================================================

step4_setup_firewall() {
    update_state 4
    if [[ "$NO_TWEAKS" -eq 0 ]]; then
        log "### STEP 4: UFW firewall configuration ###"
        install_packages ufw
        setup_improved_firewall || die "UFW configuration error."
        log "Step 4 completed."
    else
        log "### STEP 4: Skipping UFW configuration (--no-tweaks) ###"
    fi
    update_state 5
}

# ==============================================================================
# STEP 5: Downloading scripts (NO Python!)
# ==============================================================================

verify_sha256() {
    local file="$1" expected="$2" label="$3"
    # Skip verification when:
    # - SHA is not set (RELEASE_PLACEHOLDER — release not yet published)
    # - AWG_BRANCH is overridden (test branch)
    if [[ "$expected" == "RELEASE_PLACEHOLDER" ]]; then
        log_debug "SHA256 for $label: skipped (placeholder, pre-release)."
        return 0
    fi
    if [[ "${AWG_BRANCH}" != "v${SCRIPT_VERSION}" ]]; then
        log_warn "SHA256 for $label: verification skipped (AWG_BRANCH=${AWG_BRANCH} != v${SCRIPT_VERSION}). File not verified."
        return 0
    fi
    local actual
    actual=$(sha256sum "$file" 2>/dev/null | awk '{print $1}')
    if [[ "$actual" != "$expected" ]]; then
        log_error "SHA256 mismatch for $label!"
        log_error "  Expected: $expected"
        log_error "  Got:      $actual"
        log_error "  File may have been tampered with. Re-download the installer from GitHub."
        return 1
    fi
    log_debug "SHA256 $label: OK ($actual)"
    return 0
}

step5_download_scripts() {
    update_state 5
    log "### STEP 5: Downloading management scripts ###"
    cd "$AWG_DIR" || die "Error changing to $AWG_DIR"

    # Downloading awg_common.sh
    log "Downloading $COMMON_SCRIPT_PATH..."
    if curl -fLso "$COMMON_SCRIPT_PATH" --max-time 60 --retry 2 "$COMMON_SCRIPT_URL"; then
        chmod 700 "$COMMON_SCRIPT_PATH" || die "chmod awg_common.sh error"
        verify_sha256 "$COMMON_SCRIPT_PATH" "$COMMON_SCRIPT_SHA256" "awg_common.sh" || \
            die "awg_common.sh integrity check failed (SHA256 mismatch). Installation aborted."
        log "awg_common.sh downloaded and verified."
    else
        die "awg_common.sh download error"
    fi

    # Downloading manage_amneziawg.sh
    log "Downloading $MANAGE_SCRIPT_PATH..."
    if curl -fLso "$MANAGE_SCRIPT_PATH" --max-time 60 --retry 2 "$MANAGE_SCRIPT_URL"; then
        chmod 700 "$MANAGE_SCRIPT_PATH" || die "chmod manage_amneziawg.sh error"
        verify_sha256 "$MANAGE_SCRIPT_PATH" "$MANAGE_SCRIPT_SHA256" "manage_amneziawg.sh" || \
            die "manage_amneziawg.sh integrity check failed (SHA256 mismatch). Installation aborted."
        log "manage_amneziawg.sh downloaded and verified."
    else
        die "manage_amneziawg.sh download error"
    fi

    log "Step 5 completed."
    update_state 6
}

# ==============================================================================
# STEP 6: Config generation (native, without awgcfg.py)
# ==============================================================================

step6_generate_configs() {
    update_state 6
    log "### STEP 6: AWG 2.0 config generation ###"
    cd "$AWG_DIR" || die "cd $AWG_DIR error"

    # Load shared library
    if [[ ! -f "$COMMON_SCRIPT_PATH" ]]; then
        die "awg_common.sh not found. Step 5 not completed?"
    fi
    # shellcheck source=/dev/null
    source "$COMMON_SCRIPT_PATH"

    # Create key directory
    mkdir -p "$KEYS_DIR" || die "Error creating $KEYS_DIR"

    # Generate server keys (if not yet present)
    if [[ ! -f "$AWG_DIR/server_private.key" ]]; then
        log "Generating server keys..."
        generate_server_keys || die "Server key generation error."
    else
        log "Server keys already exist."
    fi

    # Backup existing server config BEFORE overwriting
    if [[ -f "$SERVER_CONF_FILE" ]]; then
        local s_bak
        s_bak="${SERVER_CONF_FILE}.bak-$(date +%F_%H%M%S)"
        cp "$SERVER_CONF_FILE" "$s_bak" || log_warn "Backup error $s_bak"
        log "Server config backup: $s_bak"
    fi

    # Create AWG 2.0 server config
    log "Creating server config..."
    render_server_config || die "Server config creation error."

    # Restore existing [Peer] blocks from backup (excluding defaults)
    if [[ -n "${s_bak:-}" && -f "$s_bak" ]]; then
        local restored_peers
        restored_peers=$(awk '
            /^\[Peer\]/ { buf=$0"\n"; in_peer=1; skip=0; next }
            in_peer && /^\[/ { if (!skip) printf "%s\n", buf; buf=""; in_peer=0; next }
            in_peer { buf=buf $0"\n"; if ($0 ~ /^#_Name = (my_phone|my_laptop)$/) skip=1; next }
            END { if (in_peer && !skip) printf "%s", buf }
        ' "$s_bak")
        if [[ -n "$restored_peers" ]]; then
            printf '\n%s' "$restored_peers" >> "$SERVER_CONF_FILE"
            log "Existing peers restored from backup."
        fi
    fi

    # Generate default clients
    log "Creating default clients..."
    local client_name
    for client_name in my_phone my_laptop; do
        if grep -qxF "#_Name = ${client_name}" "$SERVER_CONF_FILE" 2>/dev/null; then
            log "Client '$client_name' already exists."
        else
            log "Creating client '$client_name'..."
            generate_client "$client_name" || log_warn "Client creation error '$client_name'"
        fi
    done

    # Config validation
    validate_awg_config || log_warn "Config validation found issues."

    # Set file permissions
    secure_files

    log "Configuration files in $AWG_DIR:"
    ls -la "$AWG_DIR"/*.conf "$AWG_DIR"/*.png 2>/dev/null | while IFS= read -r line; do
        log "  $line"
    done

    log "Step 6 completed."
    update_state 7
}

# ==============================================================================
# STEP 7: Service startup
# ==============================================================================

step7_start_service() {
    update_state 7
    log "### STEP 7: Service startup and security configuration ###"

    log "Enabling and starting awg-quick@awg0..."
    if systemctl is-active --quiet awg-quick@awg0; then
        log "Service already active — restarting to apply configuration..."
        systemctl enable awg-quick@awg0 || log_warn "Failed to enable awg-quick@awg0 — check autostart manually"
        systemctl restart awg-quick@awg0 || die "restart awg-quick@awg0 error."
    else
        systemctl enable --now awg-quick@awg0 || die "enable --now error."
    fi
    log "Service enabled and started."

    log "Checking service status..."
    local _attempt
    for _attempt in 1 2 3 4 5; do
        sleep 1
        check_service_status 2>/dev/null && break
        [[ $_attempt -lt 5 ]] && log_debug "Waiting for service startup... (attempt $_attempt/5)"
    done
    check_service_status || die "Service status check failed."

    # Fail2Ban
    if [[ "$NO_TWEAKS" -eq 0 ]]; then
        setup_fail2ban
    else
        log "Skipping Fail2Ban (--no-tweaks)."
    fi

    log "Step 7 completed successfully."
    update_state 99
}

# ==============================================================================
# STEP 99: Completion
# ==============================================================================

step99_finish() {
    log "### INSTALLATION COMPLETE ###"
    log "=============================================================================="
    log "AmneziaWG 2.0 installation and configuration COMPLETED SUCCESSFULLY!"
    log " "
    log "CLIENT FILES:"
    log "  Configs (.conf) and QR codes (.png) in: $AWG_DIR"
    log "  Copy them securely."
    log "  Example (on your PC):"
    log "    scp root@<SERVER_IP>:$AWG_DIR/*.conf ./"
    log " "
    log "USEFUL COMMANDS:"
    log "  sudo bash $MANAGE_SCRIPT_PATH help   # Client management"
    log "  systemctl status awg-quick@awg0      # VPN status"
    log "  awg show                              # AmneziaWG status"
    log "  ufw status verbose                    # Firewall status"
    log " "
    log "IMPORTANT: Use Amnezia VPN client >= 4.8.12.7 to connect"
    log "           with AWG 2.0 protocol support"
    log " "
    cleanup_apt
    log " "

    # Final checks
    if [[ -f "$CONFIG_FILE" ]]; then
        log "Settings file $CONFIG_FILE: OK"
    else
        log_error "Settings file $CONFIG_FILE MISSING!"
    fi

    # Remove state file
    log "Removing installation state file..."
    rm -f "$STATE_FILE" "${STATE_FILE}.lock" || log_warn "Failed to remove $STATE_FILE"
    log "Installation fully completed. Log: $LOG_FILE"
    log "=============================================================================="
}

# ==============================================================================
# Main execution loop
# ==============================================================================

if [[ "$HELP" -eq 1 ]]; then show_help; fi
if [[ "$UNINSTALL" -eq 1 ]]; then step_uninstall; fi
if [[ "$DIAGNOSTIC" -eq 1 ]]; then create_diagnostic_report; exit 0; fi
if [[ "$VERBOSE" -eq 1 ]]; then set -x; fi

initialize_setup

while (( current_step < 99 )); do
    log "Executing step $current_step..."
    case $current_step in
        1) step1_update_and_optimize ;;
        2) step2_install_amnezia ;;
        3) step3_check_module; current_step=4 ;;
        4) step4_setup_firewall; current_step=5 ;;
        5) step5_download_scripts; current_step=6 ;;
        6) step6_generate_configs; current_step=7 ;;
        7) step7_start_service; current_step=99 ;;
        *) die "Error: Unknown step $current_step." ;;
    esac
done

if (( current_step == 99 )); then step99_finish; fi
exit 0
