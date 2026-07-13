#!/bin/bash

# Minimum Bash version check
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "ERROR: Bash >= 4.0 required (current: ${BASH_VERSION})" >&2; exit 1
fi

# ==============================================================================
# AmneziaWG 2.0 installation and configuration script for Ubuntu/Debian servers
# Author: @bivlked
# Version: 5.19.1
# Date: 2026-07-13
# Repository: https://github.com/bivlked/amneziawg-installer
# ==============================================================================

# --- Safe mode and Constants ---
set -o pipefail
SCRIPT_VERSION="5.19.1"

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
COMMON_SCRIPT_SHA256="b7cfe982573a811a30581c51223227b772d46c2bf79d6affcfb51db6fc612e76"
MANAGE_SCRIPT_SHA256="6f0d76b072c7fde07907769b338e8852d047d0416649dbd34c4244c0770646e2"

# CLI flags
UNINSTALL=0; HELP=0; HELP_EXIT_RC=0; DIAGNOSTIC=0; VERBOSE=0; NO_COLOR=0; AUTO_YES=0; NO_TWEAKS=0; NO_CPS=0
FORCE_REINSTALL=0
_APT_UPDATED=0
CLI_PORT=""; CLI_SUBNET=""; CLI_DISABLE_IPV6="default"; CLI_SSH_PORT=""
CLI_ROUTING_MODE="default"; CLI_CUSTOM_ROUTES=""; CLI_ENDPOINT=""; CLI_NO_TWEAKS=0; CLI_NO_CPS=0
CLI_ALLOW_IPV6_TUNNEL=0

# --- Auto-cleanup of temporary files ---
_install_temp_files=()
_install_cleaned=0
_install_cleanup() {
    # Idempotent: on INT/TERM it is called from the signal handler, then again on
    # EXIT - the second call must be a no-op.
    [[ "$_install_cleaned" -eq 1 ]] && return 0
    _install_cleaned=1
    local f
    for f in "${_install_temp_files[@]}"; do [[ -f "$f" ]] && rm -f "$f"; done
    # Clean up temporary files from awg_common.sh (if already sourced)
    type _awg_cleanup &>/dev/null && _awg_cleanup
}
# On INT/TERM the cleanup used to run but the script did NOT exit - execution
# continued past the interrupted command (dangerous mid apt/dpkg/config edits)
# and cleanup ran again on EXIT. A signal now means cleanup + explicit 130/143.
_install_on_signal() {
    _install_cleanup
    exit "$1"
}
trap _install_cleanup EXIT
trap '_install_on_signal 130' INT
trap '_install_on_signal 143' TERM

# --- Argument processing ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --uninstall)     UNINSTALL=1 ;;
        --help|-h)       HELP=1 ;;
        --diagnostic)    DIAGNOSTIC=1 ;;
        --verbose|-v)    VERBOSE=1 ;;
        --no-color)      NO_COLOR=1 ;;
        --port=*)        CLI_PORT="${1#*=}" ;;
        --ssh-port=*)    CLI_SSH_PORT="${1#*=}" ;;
        --subnet=*)      CLI_SUBNET="${1#*=}" ;;
        --allow-ipv6)        CLI_DISABLE_IPV6=0 ;;
        --disallow-ipv6)     CLI_DISABLE_IPV6=1 ;;
        --allow-ipv6-tunnel) CLI_ALLOW_IPV6_TUNNEL=1 ;;
        --route-all)     CLI_ROUTING_MODE=1 ;;
        --route-amnezia) CLI_ROUTING_MODE=2 ;;
        --route-custom=*) CLI_ROUTING_MODE=3; CLI_CUSTOM_ROUTES="${1#*=}" ;;
        --endpoint=*)    CLI_ENDPOINT="${1#*=}" ;;
        --yes|-y)        AUTO_YES=1 ;;
        --no-tweaks)     NO_TWEAKS=1; CLI_NO_TWEAKS=1 ;;
        --no-cps)        NO_CPS=1; CLI_NO_CPS=1 ;;
        --force|-f)      FORCE_REINSTALL=1 ;;
        --preset=*)      CLI_PRESET="${1#*=}" ;;
        --jc=*)          CLI_JC="${1#*=}" ;;
        --jmin=*)        CLI_JMIN="${1#*=}" ;;
        --jmax=*)        CLI_JMAX="${1#*=}" ;;
        *) echo "Unknown argument: $1" >&2; HELP=1; HELP_EXIT_RC=1 ;;
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
    local entry="[$ts] $type: $msg"
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
    # --ppa-amnezia-tolerant: also ignore errors from the Amnezia PPA. Used
    # in step 2 — apt_wait_for_ppa_package below already retries for the
    # ppa.launchpadcontent.net outage scenario (issue #68). Without this
    # flag we must fail fast on any non-source error, otherwise the script
    # would continue installing on a stale apt-cache (PR #69 review finding).
    local ppa_tolerant=0
    if [[ "${1:-}" == "--ppa-amnezia-tolerant" ]]; then
        ppa_tolerant=1
        shift
    fi

    local err_output rc non_src_errors raw_had_non_src_errors=0
    err_output=$(LANG=C LC_ALL=C apt-get update -y 2>&1)
    rc=$?
    echo "$err_output"

    if [[ $rc -eq 0 ]]; then
        return 0
    fi

    # Filter error lines. Ignore:
    #   1. Lines about source packages (deb-src / /source/ / Sources)
    #   2. Generic 'Some index files failed to download' — symptom, not cause
    # Additionally exclude known informational W: lines that are never the
    # CAUSE of rc!=0 but used to survive the filters and turn a tolerable
    # failure (e.g. deb-src 404 with duplicated sources) into a false fatal:
    #   - "Target ... is configured multiple times" (duplicate sources entries)
    #   - "... stored in legacy trusted.gpg keyring" (old key format)
    non_src_errors=$(printf '%s\n' "$err_output" \
        | grep -E '^(E:|Err:|W:)' \
        | grep -vE '(deb-src|/source/|Sources([^[:alpha:]]|$))' \
        | grep -vE 'Some index files failed to download' \
        | grep -vE '^W: (Target .* is configured multiple times|.* stored in legacy trusted\.gpg)' || true)

    # Remember pre-PPA-filter state — we need to distinguish "real APT errors,
    # but all on Amnezia PPA" (tolerant OK) from "no classifiable errors at all"
    # (OOM / silent crash — NOT tolerant even if the output happens to mention
    # a PPA URL elsewhere).
    [[ -n "$non_src_errors" ]] && raw_had_non_src_errors=1

    # Optional (step 2): drop errors that are only on the Amnezia PPA — they
    # will be re-checked via apt_wait_for_ppa_package against apt-cache (issue #68).
    if [[ $ppa_tolerant -eq 1 && -n "$non_src_errors" ]]; then
        non_src_errors=$(printf '%s\n' "$non_src_errors" \
            | grep -vE 'ppa\.launchpadcontent\.net.*amnezia' || true)
    fi

    if [[ -z "$non_src_errors" ]]; then
        # Edge case: rc != 0 but no classifiable E:/Err:/W: lines found
        # (OOM-killer SIGKILL, silent crash, unknown apt output format).
        # Ignore ONLY if the output actually contains source-markers, or if
        # ppa-tolerant + there were real APT lines and all of them were on the
        # Amnezia PPA.
        if printf '%s\n' "$err_output" | grep -qE '(deb-src|/source/|Sources([^[:alpha:]]|$))'; then
            log_warn "apt update: source packages unavailable in mirror (expected, ignored)"
            return 0
        fi
        if [[ $ppa_tolerant -eq 1 && $raw_had_non_src_errors -eq 1 ]] \
            && printf '%s\n' "$err_output" | grep -qE 'ppa\.launchpadcontent\.net.*amnezia'; then
            log_warn "apt update: errors only on Amnezia PPA (issue #68), continuing with retry."
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
# apt_wait_for_ppa_package <package> [max_attempts] [initial_delay_seconds]
#   Waits until the given package becomes visible in apt-cache, with
#   exponential backoff between attempts. Needed in step 2 after the
#   Amnezia PPA is added: ppa.launchpadcontent.net sometimes briefly
#   goes down (issue #68), and without retries the first cold install
#   fails even though the PPA is back a minute later.
#
#   IMPORTANT: this checks apt-cache show, not the rc of apt-get update.
#   apt-get update returns 0 tolerantly even when an InRelease file did
#   not download — so a plain rc-based retry does not catch a PPA outage.
#   Package visibility in apt-cache is the only reliable signal that
#   the PPA actually got indexed.
#
#   With the defaults (3 attempts × initial=30s) the timeline is:
#   attempt 1 → sleep 30s → apt update + attempt 2 → sleep 60s →
#   apt update + attempt 3 (last). After the third fail we return 1.
#   Total wait between attempts is about 1.5 minutes.
#
#   The 1800s delay cap guards against arithmetic overflow if the helper
#   is ever called with a very large max.
# ==============================================================================
apt_wait_for_ppa_package() {
    local pkg="$1" max="${2:-3}" delay="${3:-30}" attempt
    for ((attempt = 1; attempt <= max; attempt++)); do
        if apt-cache show "$pkg" >/dev/null 2>&1; then
            return 0
        fi
        if (( attempt == max )); then
            return 1
        fi
        log_warn "Package '${pkg}' did not appear in apt-cache (attempt ${attempt}/${max}, PPA still unavailable), retrying in ${delay}s..."
        sleep "$delay"
        apt_update_tolerant >/dev/null 2>&1 || true
        delay=$(( delay * 2 > 1800 ? 1800 : delay * 2 ))
    done
    return 1
}

# ==============================================================================
# Help
# ==============================================================================

show_help() {
    cat << 'EOF'
Usage: sudo bash install_amneziawg_en.sh [OPTIONS]
Script for installation and configuration of AmneziaWG 2.0 on Ubuntu (24.04 / 25.10 / 26.04) and Debian (12 / 13).

Options:
  -h, --help            Show this help and exit
  --uninstall           Uninstall AmneziaWG and all its configurations
  --diagnostic          Generate diagnostic report and exit
  -v, --verbose         Verbose output for debugging (including DEBUG)
  --no-color            Disable colored terminal output
  --port=NUMBER         Set UDP port (1-65535) non-interactively
  --ssh-port=PORT       SSH port for the UFW rule (auto-detected by default;
                        comma-separated list). Use if SSH runs on a non-standard
                        port and auto-detection is unavailable
  --subnet=SUBNET       Tunnel subnet, CIDR /16-/30 (e.g. 10.9.0.0/16) non-interactively
  --allow-ipv6          Keep IPv6 enabled non-interactively
  --disallow-ipv6       Force-disable IPv6 non-interactively
  --allow-ipv6-tunnel   Enable dual-stack IPv6 inside the tunnel (ULA, opt-in)
  --route-all           Use 'All traffic' mode non-interactively
  --route-amnezia       Use 'Amnezia' mode non-interactively
  --route-custom=NETS   Use 'Custom' mode non-interactively
  --endpoint=ADDR       External server endpoint: FQDN, IPv4 or [IPv6] (NAT)
  -y, --yes             Auto-confirm (reboots, UFW, etc.)
  -f, --force           Force reinstall on top of an already-running AmneziaWG
                        (by default a run on a configured server aborts;
                        ENV: AWG_FORCE_REINSTALL=1 is equivalent to the flag)
  --no-tweaks           Skip optional hardening/optimization (UFW, Fail2Ban);
                        the minimal forwarding sysctl is always applied
  --preset=TYPE         Obfuscation parameter preset: default, mobile
                        mobile: Jc=3, narrow Jmax — for mobile carriers (Tele2, Yota, Megafon)
  --jc=N               Set Jc manually (1-128, overrides preset)
  --jmin=N             Set Jmin manually (0-1280, overrides preset)
  --jmax=N             Set Jmax manually (0-1280, overrides preset, must be >= Jmin)
  --no-cps              Disable CPS (the I1 parameter) - needed if the desktop
                        AmneziaVPN on macOS hangs on connect (issue #159)

Examples:
  sudo bash install_amneziawg_en.sh                             # Interactive installation
  sudo bash install_amneziawg_en.sh --port=51820 --route-all    # Non-interactive
  sudo bash install_amneziawg_en.sh --route-amnezia --yes       # Fully automated
  sudo bash install_amneziawg_en.sh --preset=mobile --yes       # Optimized for mobile networks
  sudo bash install_amneziawg_en.sh --uninstall                 # Uninstall
  sudo bash install_amneziawg_en.sh --diagnostic                # Diagnostics

Repository: https://github.com/bivlked/amneziawg-installer
EOF
    # Explicit --help exits 0; an unknown argument exits 1 (false success in CI).
    exit "${HELP_EXIT_RC:-0}"
}

# ==============================================================================
# Utilities and validation
# ==============================================================================

update_state() {
    local next_step=$1
    mkdir -p "$(dirname "$STATE_FILE")"
    # Atomic write: tmp-file + flock + mv. Protects against a truncated
    # state file if the process is killed / power-lost between write and close.
    (
        flock -x 200
        local tmp="${STATE_FILE}.tmp.$BASHPID"
        if printf '%s\n' "$next_step" > "$tmp" && mv -f "$tmp" "$STATE_FILE"; then
            exit 0
        fi
        rm -f "$tmp" 2>/dev/null
        exit 1
    ) 200>"${STATE_FILE}.lock" || die "Failed to write state"
    log "State: next step - $next_step"
}

request_reboot() {
    local next_step=$1
    update_state "$next_step"

    # Capture boot_id before the 1→2 reboot gate. On step 2 entry we
    # compare it with the current boot_id — if they match, the user did
    # not reboot, which means apt full-upgrade staged a new kernel on
    # disk but the running kernel is still the old one. DKMS would build
    # the module against the old kernel and modprobe would fail after
    # the next reboot. Fail fast instead.
    if [[ "$next_step" == "2" ]] && [[ -r /proc/sys/kernel/random/boot_id ]]; then
        if cat /proc/sys/kernel/random/boot_id > "$AWG_DIR/.boot_id_before_step2" 2>/dev/null; then
            log_debug "boot_id captured before reboot"
        fi
    fi

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
    if [[ "$confirm" =~ ^[[:space:]]*[Yy]([Ee][Ss])?[[:space:]]*$ ]]; then
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
            if [[ "$OS_VERSION" == "24.04" || "$OS_VERSION" == "25.10" || "$OS_VERSION" == "26.04" ]]; then
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
        log_warn "Detected $OS_ID $OS_VERSION ($OS_CODENAME). Script tested on Ubuntu 24.04/25.10/26.04 and Debian 12/13."
        if [[ "$AUTO_YES" -eq 0 ]]; then
            read -rp "Continue? [y/N]: " confirm < /dev/tty
            if ! [[ "$confirm" =~ ^[[:space:]]*[Yy]([Ee][Ss])?[[:space:]]*$ ]]; then die "Cancelled."; fi
        else
            log "Continuing on $OS_ID $OS_VERSION (--yes)."
        fi
    fi
}

check_kernel_version() {
    # The AmneziaWG 2.0 module is built via DKMS against the host kernel. On
    # kernels older than 5.15 (Ubuntu < 22.04, e.g. 5.4 on 20.04) the build
    # usually fails at step 2 with an opaque package-failure. Warn EXPLICITLY and
    # early, before updates and reboots (issue #163). Not a die: on some older
    # kernels the module still builds (HWE and such), so WARN + confirm.
    local kver kmaj kmin
    kver=$(uname -r)
    if [[ "$kver" =~ ^([0-9]+)\.([0-9]+) ]]; then
        kmaj=${BASH_REMATCH[1]}; kmin=${BASH_REMATCH[2]}
    else
        log_warn "Could not parse the kernel version ('$kver') - skipping the minimum-version check."
        return 0
    fi
    if (( kmaj < 5 || (kmaj == 5 && kmin < 15) )); then
        log_warn "Kernel $kver is older than 5.15 - usually too old for the AmneziaWG 2.0 module."
        log_warn "The DKMS module build on such a kernel most often fails. Reinstall the VPS on Ubuntu 24.04 LTS or Debian 12 (or newer). Matrix: Ubuntu 24.04/25.10/26.04, Debian 12/13."
        if [[ "$AUTO_YES" -eq 0 ]]; then
            read -rp "Continue anyway? [y/N]: " confirm < /dev/tty
            if ! [[ "$confirm" =~ ^[[:space:]]*[Yy]([Ee][Ss])?[[:space:]]*$ ]]; then die "Cancelled: kernel $kver is too old for the AmneziaWG 2.0 module."; fi
        else
            log "Continuing on kernel $kver (--yes)."
        fi
    else
        log "Kernel $kver (OK for the AmneziaWG 2.0 module)."
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
            if ! [[ "$confirm" =~ ^[[:space:]]*[Yy]([Ee][Ss])?[[:space:]]*$ ]]; then die "Cancelled."; fi
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
        # C4: a hard apt_update_tolerant failure (GPG / binary-repo network / OOM)
        # is NOT source noise but a real error; continuing on a stale cache is not
        # safe (contract line ~138, same as callers 1975/2108). die aborts the
        # install, so _APT_UPDATED=1 is set only on success - otherwise a later
        # install_packages call in this session would silently skip the update.
        apt_update_tolerant || die "apt update error."
        _APT_UPDATED=1
    fi
    if ! DEBIAN_FRONTEND=noninteractive apt install -y "${to_install[@]}"; then
        # v5.13.0: typical failure on 25.10/26.04 after an in-place upgrade
        # from 24.04 — the amneziawg-dkms postinst runs `dkms autoinstall`
        # which iterates over ALL kernels in /lib/modules/. The leftover
        # 6.8.x headers were compiled with gcc-13, but 25.10 ships only
        # gcc-15 by default → autoinstall fails, dpkg leaves the dependent
        # amneziawg-tools / amneziawg unconfigured. Force-build the module
        # for the running kernel only and finish with dpkg --configure -a.
        if printf '%s\n' "${to_install[@]}" | grep -qx "amneziawg-dkms"; then
            log_warn "apt install did not complete — trying a DKMS build for the running kernel $(uname -r) only..."
            local _mver
            _mver="$(ls /var/lib/dkms/amneziawg/ 2>/dev/null | head -n1)"
            if [[ -n "$_mver" ]] \
               && dkms install -m amneziawg -v "$_mver" -k "$(uname -r)" --force \
               && DEBIAN_FRONTEND=noninteractive dpkg --configure -a; then
                log "DKMS module built for $(uname -r), dpkg configured."
                log "Packages installed."
                return 0
            fi
        fi
        die "Package installation error."
    fi
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

# Detect whether the VPS has native IPv6.
# Native IPv6 = a globally routable address (NOT ULA fc00::/7, NOT link-local
# fe80::) AND a default IPv6 route. Either condition alone is insufficient:
#   - a global address without a default route -> no IPv6 internet egress (a client
#     with ::/0 would black-hole);
#   - a ULA (fddd::/...) has global scope to `ip` but is not internet-routable.
# Echo 1 only when both conditions hold, otherwise 0.
detect_native_ipv6() {
    local have_addr=0 have_route=0
    if ip -6 addr show scope global 2>/dev/null \
        | grep -oP 'inet6\s+\K[0-9a-fA-F:]+' \
        | grep -qviE '^(fc|fd)'; then
        have_addr=1
    fi
    if ip -6 route show default 2>/dev/null | grep -q .; then
        have_route=1
    fi
    if [[ "$have_addr" -eq 1 && "$have_route" -eq 1 ]]; then
        echo 1
    else
        echo 0
    fi
}

configure_ipv6_tunnel() {
    if [[ "$CLI_ALLOW_IPV6_TUNNEL" -eq 1 ]]; then
        ALLOW_IPV6_TUNNEL=1
    elif [[ -z "${ALLOW_IPV6_TUNNEL:-}" ]]; then
        ALLOW_IPV6_TUNNEL=0
    fi
    : "${IPV6_SUBNET:=fddd:2c4:2c4:2c4::/64}"
    # The IPv6 tunnel requires host IPv6 enabled. Override --disallow-ipv6 AND
    # actively re-enable IPv6 at runtime BEFORE detection/render: on an upgrade
    # from a default past install (IPv6 was runtime-disabled), the kernel hides
    # all IPv6 addresses, so detect_native_ipv6 would false-negative and a client
    # would be rendered with an IPv6 Address while the kernel has IPv6 off
    # (awg-quick restart can fail). weaq P1.
    if [[ "$ALLOW_IPV6_TUNNEL" -eq 1 ]]; then
        if [[ "$DISABLE_IPV6" -eq 1 ]]; then
            log_warn "--allow-ipv6-tunnel requires host IPv6 forwarding; overriding --disallow-ipv6 (DISABLE_IPV6=0)"
            DISABLE_IPV6=0
        fi
        sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || true
    fi
    # Detect native IPv6 AFTER the runtime re-enable (cached in init for client render in Phase 4).
    SERVER_HAS_NATIVE_IPV6=$(detect_native_ipv6)
    if [[ "$ALLOW_IPV6_TUNNEL" -eq 1 && "$SERVER_HAS_NATIVE_IPV6" -eq 0 ]]; then
        log_warn "Native IPv6 not detected on VPS - the IPv6 tunnel will work peer-to-peer only, without IPv6 internet egress."
    fi
    export ALLOW_IPV6_TUNNEL IPV6_SUBNET SERVER_HAS_NATIVE_IPV6 DISABLE_IPV6
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
                DISABLE_IPV6|ALLOWED_IPS_MODE|ALLOWED_IPS|AWG_ENDPOINT|AWG_MTU|\
                AWG_Jc|AWG_Jmin|AWG_Jmax|AWG_S1|AWG_S2|AWG_S3|AWG_S4|\
                AWG_H1|AWG_H2|AWG_H3|AWG_H4|AWG_I1|AWG_I2|AWG_I3|AWG_I4|AWG_I5|AWG_PRESET|NO_TWEAKS|NO_CPS|\
                AWG_APPLY_MODE|ALLOW_IPV6_TUNNEL|IPV6_SUBNET|SERVER_HAS_NATIVE_IPV6)
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
    # ^[1-9][0-9]{0,4}$ forbids leading zeros ('0080' would otherwise be parsed as
    # octal in arithmetic and slip past the range check) and bounds the length:
    # without a limit 64-bit (( )) arithmetic wraps, so 2^64+51820 would pass the
    # range check. Comparison uses plain decimal.
    if ! [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] || (( port > 65535 )); then
        die "Invalid port: '$port'. Allowed range: 1-65535."
    fi
}

validate_subnet() {
    local subnet="$1" o
    # Self-contained (step 0, BEFORE awg_common.sh is downloaded): does not use
    # _valid_ipv4/_cidr_bounds. Octets without leading zeros ('010...' would
    # otherwise be parsed as octal).
    if ! [[ "$subnet" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})/([0-9]{1,2})$ ]]; then
        die "Invalid subnet: '$subnet'. Expected CIDR /16-/30, e.g. 10.9.0.0/16."
    fi
    local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}" c="${BASH_REMATCH[3]}" d="${BASH_REMATCH[4]}" prefix="${BASH_REMATCH[5]}"
    for o in "$a" "$b" "$c" "$d"; do
        (( 10#$o <= 255 )) || die "Invalid subnet: '$subnet'. Octet out of range 0-255."
    done
    (( 10#$prefix >= 16 && 10#$prefix <= 30 )) || die "Invalid subnet: '$subnet'. Only /16-/30 masks are supported."
    # Inline arithmetic: the address must be network or network+1.
    local ip=$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
    local mask=$(( (0xFFFFFFFF << (32 - 10#$prefix)) & 0xFFFFFFFF ))
    local network=$(( ip & mask ))
    local n1=$(( network + 1 ))
    local srv="$(( (n1 >> 24) & 255 )).$(( (n1 >> 16) & 255 )).$(( (n1 >> 8) & 255 )).$(( n1 & 255 ))"
    if (( ip != network && ip != n1 )); then
        die "Invalid subnet: '$subnet'. Server address must be ${srv} (network+1), or specify the network."
    fi
    # Normalize the global to <network+1>/<prefix> (server = network+1).
    AWG_TUNNEL_SUBNET="${srv}/${prefix}"
}

# Subnet-change guard: [Peer] blocks are carried over verbatim on reinstall
# (render_server_config), and their addresses were issued in the OLD subnet.
# Changing the subnet under live clients breaks them: old IPv4s can fall
# outside the new range, and IPv6 suffixes can collide (the decimal /24
# encoding vs hex for non-/24 masks yields two peers with the same ::x). So the
# install aborts when peers exist and the subnet differs (PR #167 review).
# Self-contained (step 0, BEFORE awg_common.sh is downloaded). The old
# subnet is the first Address value in the awg0.conf [Interface]: it is the
# normalized <network+1>/<prefix>, and the new AWG_TUNNEL_SUBNET has been
# normalized by validate_subnet by the time of the call - a plain string
# comparison is enough.
guard_subnet_change_with_peers() {
    [[ -f "$SERVER_CONF_FILE" ]] || return 0
    grep -q '^\[Peer\]' "$SERVER_CONF_FILE" 2>/dev/null || return 0
    local old_subnet
    # Address may be dual-stack ("IPv4/n, IPv6/n") in any order - pick the IPv4
    # element, not just the first comma field (an IPv6-first Address would
    # otherwise look like a subnet change). No IPv4 -> empty -> fail closed below.
    old_subnet=$(sed -n 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*//p' "$SERVER_CONF_FILE" 2>/dev/null \
        | tr ',' '\n' | sed 's/[[:space:]]//g' \
        | grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$')
    if [[ -z "$old_subnet" ]]; then
        # Peers exist but the old subnet cannot be determined - fail closed: a
        # silent continue would re-render the config in the new subnet and break
        # the clients.
        die "${SERVER_CONF_FILE} already contains peers, but the Address line in [Interface] is unreadable - the subnet-change check is impossible. Restore the Address line, or remove the clients (sudo bash $MANAGE_SCRIPT_PATH remove <name>), or run --uninstall and reinstall from scratch."
    fi
    if [[ "$old_subnet" != "$AWG_TUNNEL_SUBNET" ]]; then
        die "The tunnel subnet changed (${old_subnet} -> ${AWG_TUNNEL_SUBNET}), but ${SERVER_CONF_FILE} already contains peers: their addresses were issued in the old subnet, and changing it breaks the clients. Options: keep the previous subnet; remove all clients (sudo bash $MANAGE_SCRIPT_PATH remove <name>); or run --uninstall and reinstall from scratch."
    fi
    return 0
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
    # Bracketed [IPv6] form: structural check of the bracket contents. The previous
    # charset-only test let junk like [:::] / [1:2:3] through. Mirrors _valid_ipv6.
    if [[ "$ep" == \[*\] ]]; then
        local inner="${ep#\[}"; inner="${inner%\]}"
        [[ "$inner" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
        case "$inner" in
            *:::*|*::*::*) return 1 ;;
        esac
        [[ "$inner" == :* && "$inner" != ::* ]] && return 1
        [[ "$inner" == *: && "$inner" != *:: ]] && return 1
        local has_dcolon=0; [[ "$inner" == *::* ]] && has_dcolon=1
        local IFS=':' parts=() p ngroups=0
        read -ra parts <<< "$inner"
        for p in "${parts[@]}"; do
            [[ -z "$p" ]] && continue
            [[ "$p" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
            ngroups=$((ngroups + 1))
        done
        if [[ $has_dcolon -eq 1 ]]; then
            (( ngroups <= 7 )) || return 1
        else
            (( ngroups == 8 )) || return 1
        fi
        return 0
    fi
    # Otherwise FQDN or IPv4
    [[ "$ep" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*|[0-9]{1,3}(\.[0-9]{1,3}){3})$ ]] || return 1
    # If IPv4 format - additionally validate octet range 0-255
    if [[ "$ep" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        [[ "${BASH_REMATCH[1]}" -le 255 && "${BASH_REMATCH[2]}" -le 255 && \
           "${BASH_REMATCH[3]}" -le 255 && "${BASH_REMATCH[4]}" -le 255 ]] || return 1
    fi
    return 0
}

validate_cidr_list() {
    local input="$1" cidr o nospace
    input="${input//$'\r'/}"
    input="${input//$'\t'/ }"
    # A newline means injection into awgsetup_cfg.init (read <<< only sees the
    # first line, the rest would pass unchecked). Same policy as validate_endpoint.
    [[ "$input" != *$'\n'* ]] || return 1
    # Structural comma check before split: bash IFS drops a trailing empty element,
    # so '10.0.0.0/24,' used to pass. Reject leading/trailing/double comma and empty
    # input (spaces are ignored for this check).
    nospace="${input// /}"
    case "$nospace" in
        ""|,*|*,|*,,*) return 1 ;;
    esac
    IFS=',' read -ra cidrs <<< "$input"
    for cidr in "${cidrs[@]}"; do
        cidr="${cidr// /}"
        # Octets without leading zeros; prefix 0-32 enforced in the regex (no octal).
        if ! [[ "$cidr" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})/([0-9]|[12][0-9]|3[0-2])$ ]]; then
            return 1
        fi
        for o in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
            (( o <= 255 )) || return 1
        done
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
           # iOS breaks the tunnel if the list starts with 0.0.0.0/5: that block covers
           # the reserved 0.0.0.0/8 which the iOS kernel chokes on, so it never reaches the
           # rest of the routes. 1.0.0.0/8 + 2.0.0.0/7 + 4.0.0.0/6 is the same range minus the
           # zero block (0.0.0.0/8 is non-routable anyway). Do not revert to 0.0.0.0/5 (Issue #42).
           ALLOWED_IPS="1.0.0.0/8, 2.0.0.0/7, 4.0.0.0/6, 8.0.0.0/7, 11.0.0.0/8, 12.0.0.0/6, 16.0.0.0/4, 32.0.0.0/3, 64.0.0.0/2, 128.0.0.0/3, 160.0.0.0/5, 168.0.0.0/6, 172.0.0.0/12, 172.32.0.0/11, 172.64.0.0/10, 172.128.0.0/9, 173.0.0.0/8, 174.0.0.0/7, 176.0.0.0/4, 192.0.0.0/9, 192.128.0.0/11, 192.160.0.0/13, 192.169.0.0/16, 192.170.0.0/15, 192.172.0.0/14, 192.176.0.0/12, 192.192.0.0/10, 193.0.0.0/8, 194.0.0.0/7, 196.0.0.0/6, 200.0.0.0/5, 208.0.0.0/4, 8.8.8.8/32, 1.1.1.1/32"
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
        # Fallback: three $RANDOM (15 bits each) with XOR overlap cover bits
        # 0-30, i.e. the full [0, 2^31-1]. The previous variant
        # (RANDOM<<15|RANDOM) gave only 30 bits - the upper half of the H
        # range could never come up.
        random_val=$(( (RANDOM << 16) ^ (RANDOM << 8) ^ RANDOM ))
    fi
    echo $(( (random_val % range) + min ))
}

# Generate 4 non-overlapping ranges for AWG H1-H4.
# Algorithm: 8 random values → sort → 4 (low, high) pairs.
# Sorting gives low <= high; the strict checks below guarantee a gap between
# pairs (touching bounds = overlap at a single point) and a lower bound >= 5
# (values 1-4 are reserved for vanilla WireGuard message types).
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
        if (( ${arr[0]} >= 5 )) && \
           (( ${arr[1]} - ${arr[0]} >= 1000 )) && \
           (( ${arr[3]} - ${arr[2]} >= 1000 )) && \
           (( ${arr[5]} - ${arr[4]} >= 1000 )) && \
           (( ${arr[7]} - ${arr[6]} >= 1000 )) && \
           (( ${arr[2]} > ${arr[1]} )) && \
           (( ${arr[4]} > ${arr[3]} )) && \
           (( ${arr[6]} > ${arr[5]} )); then
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

    # I2-I5 are NOT generated here (the admin sets them manually in awg0.conf, issue #71).
    # A fresh param set (first install or --preset/--jc/--jmin/--jmax) clears any stale
    # I2-I5 loaded from awgsetup_cfg.init so the new obfuscation set does not carry old
    # values (--preset regenerates the whole set).
    unset AWG_I2 AWG_I3 AWG_I4 AWG_I5

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

    # Snapshot default route BEFORE cleanup - detects when we break the network.
    # Issue #84: on clean Ubuntu 26.04 server (subiquity, no cloud-init netplan
    # markers) apt-get autoremove after purging cloud-init removed
    # netplan-generator as a transitive dep, and the server lost its IP on reboot.
    local pre_default_route
    pre_default_route="$(ip -4 route show default 2>/dev/null | head -1 || true)"
    log_debug "Pre-cleanup default route: ${pre_default_route:-<none>}"

    # apt-mark hold for critical network stack packages: defence against
    # accidental removal via transitive deps. Covers both netplan naming
    # variants (netplan.io on 24.04, netplan-generator on 25.10/26.04) plus
    # systemd-resolved and netcfg/ifupdown legacy. There is no standalone
    # systemd-networkd package - the binary lives inside systemd, nothing to hold.
    # Before holding we snapshot the user's existing holds so we never strip
    # holds we did not place (e.g. on linux-image-* held by the user).
    local _hold_pkgs="netplan.io netplan-generator systemd-resolved netcfg ifupdown"
    local _preexisting_holds=""
    _preexisting_holds="$(apt-mark showhold 2>/dev/null || true)"
    local _held_actual=()
    local _hpkg
    for _hpkg in $_hold_pkgs; do
        if dpkg-query -W -f='${Status}' "$_hpkg" 2>/dev/null | grep -q "ok installed"; then
            # Skip if user already held - that hold is not ours to release.
            if grep -qxF "$_hpkg" <<<"$_preexisting_holds"; then
                continue
            fi
            apt-mark hold "$_hpkg" >/dev/null 2>&1 && _held_actual+=("$_hpkg")
        fi
    done
    [ ${#_held_actual[@]} -gt 0 ] && log_debug "Apt-mark hold: ${_held_actual[*]}"

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

    # apt-get autoremove dropped (was the source of Issue #84 on Ubuntu 26.04
    # ISO): autoremove zapped netplan-generator as a transitive dep of
    # cloud-init. Orphans left after purge take ~50-200 MB - acceptable trade
    # for stability. User can manually run apt-get autoremove --no-install-recommends.

    # Release apt-mark holds so packages do not stay frozen for the user.
    local _upkg
    for _upkg in "${_held_actual[@]}"; do
        apt-mark unhold "$_upkg" >/dev/null 2>&1 || true
    done

    # Verify default route is still present. If lost, attempt recovery.
    # We reinstall netplan.io unconditionally (present on every supported
    # distro). netplan-generator only ships from Ubuntu 25.10+ / Debian 13+ -
    # gate the install behind apt-cache show so Debian 12 does not abort the
    # transaction trying to fetch a non-existent package.
    local post_default_route
    post_default_route="$(ip -4 route show default 2>/dev/null | head -1 || true)"
    if [[ -n "$pre_default_route" && -z "$post_default_route" ]]; then
        log_error "Default route lost after cleanup. Attempting recovery..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            netplan.io 2>/dev/null || true
        if apt-cache show netplan-generator &>/dev/null; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
                netplan-generator 2>/dev/null || true
        fi
        systemctl restart systemd-networkd 2>/dev/null || true
        netplan apply 2>/dev/null || true
        # Route-wait loop: up to ~26 seconds, polling every 1-5 seconds.
        # Fixed sleeps are unreliable - DHCP route appearance on slow VMs is
        # unpredictable.
        local _wait
        for _wait in 1 2 3 5 5 5 5; do
            post_default_route="$(ip -4 route show default 2>/dev/null | head -1 || true)"
            [[ -n "$post_default_route" ]] && break
            sleep "$_wait"
        done
        # Last-ditch: bring up the interface from pre_default_route. Try
        # networkctl renew first (for systemd-networkd-managed link); if the
        # route still does not come back, fall through to dhclient (ifupdown).
        if [[ -z "$post_default_route" ]]; then
            local _iface
            _iface="$(awk '{for (i=1; i<=NF; i++) if ($i == "dev") { print $(i+1); exit } }' <<<"$pre_default_route")"
            if [[ -n "$_iface" ]]; then
                log_warn "Last-ditch attempt to bring $_iface up..."
                ip link set "$_iface" up 2>/dev/null || true
                if command -v networkctl &>/dev/null; then
                    networkctl renew "$_iface" 2>/dev/null || true
                    sleep 3
                    post_default_route="$(ip -4 route show default 2>/dev/null | head -1 || true)"
                fi
                # If networkctl did not bring the route back (or is absent) - dhclient.
                if [[ -z "$post_default_route" ]] && command -v dhclient &>/dev/null; then
                    dhclient -4 "$_iface" 2>/dev/null || true
                    sleep 3
                    post_default_route="$(ip -4 route show default 2>/dev/null | head -1 || true)"
                fi
            fi
        fi
        if [[ -z "$post_default_route" ]]; then
            die "Network did not recover after cleanup_system. Restore it from the console (e.g. sudo dhclient -4 <iface>) and retry the installer with --no-tweaks flag."
        fi
        log_warn "Network recovered: $post_default_route"
    fi

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
        # Add to fstab if missing. Precise field match: ignore commented
        # lines and partial matches (e.g. `/swapfile.bak` or an old entry
        # left in a comment).
        if ! awk '!/^[[:space:]]*#/ && $1 == "/swapfile" && $3 == "swap" {found=1} END {exit !(found+0)}' \
             /etc/fstab; then
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

# Detect the real SSH port(s) so the UFW rule does not lock you out.
# Without this, ufw limit 22/tcp + default deny incoming cuts server access
# after ufw enable when SSH runs on a non-standard port (Issue #91).
# Self-contained: called at step 4, BEFORE awg_common.sh is sourced.
# Sources:
#   1. CLI_SSH_PORT (--ssh-port=, manual override, comma-separated list) - authoritative
#   otherwise UNION (not fallback - so we never miss the real port):
#   2. sshd -T   (effective config: `Port` AND `ListenAddress host:port`, honours drop-ins)
#   3. ss -tlnp  (real sshd listening sockets: ground truth for ListenAddress)
#   4. /etc/ssh/sshd_config + sshd_config.d/*.conf (parsing, only if 2-3 are empty)
#   5. 22 (default, if nothing is found)
# Prints unique valid ports (1-65535) space-separated to stdout.
# IMPORTANT: only log_warn/log_error (stderr) inside; log() writes to stdout
# and would corrupt the $(detect_ssh_ports) capture.
detect_ssh_ports() {
    local ports="" p pp valid=""
    # awk: pulls the port from `port N` and `listenaddress host:port` lines
    # (IPv4 and [IPv6]); a bare address without a port is skipped.
    local awk_ports='tolower($1)=="port"&&$2~/^[0-9]+$/{print $2} tolower($1)=="listenaddress"{v=$2; if(v~/\]:[0-9]+$/){sub(/.*\]:/,"",v); print v} else if(v~/^[0-9.]+:[0-9]+$/){sub(/.*:/,"",v); print v}}'

    if [[ -n "$CLI_SSH_PORT" ]]; then
        # 1. Manual override - authoritative source
        ports="${CLI_SSH_PORT//,/ }"
    else
        # 2. sshd -T: effective configuration (Port + ListenAddress, drop-ins)
        if command -v sshd &>/dev/null; then
            ports+=" $(sshd -T 2>/dev/null | awk "$awk_ports" | tr '\n' ' ')"
        fi
        # 3. ss: real sshd listening sockets. Merged, not fallback - catches the
        #    ListenAddress port even when sshd -T prints the default port 22.
        if command -v ss &>/dev/null; then
            ports+=" $(ss -H -tlnp 2>/dev/null | awk '/"sshd"/{n=split($4,a,":"); print a[n]}' | tr '\n' ' ')"
        fi
        # 4. Parse config files - only if sshd -T and ss yielded nothing
        if [[ -z "${ports// }" ]]; then
            local cfgs=() d
            [[ -f /etc/ssh/sshd_config ]] && cfgs+=(/etc/ssh/sshd_config)
            for d in /etc/ssh/sshd_config.d/*.conf; do
                [[ -f "$d" ]] && cfgs+=("$d")
            done
            if [[ "${#cfgs[@]}" -gt 0 ]]; then
                ports+=" $(awk "$awk_ports" "${cfgs[@]}" 2>/dev/null | tr '\n' ' ')"
            fi
        fi
    fi

    # Validate (decimal 1-65535, 10# guards against octal) + dedup preserving order
    for p in $ports; do
        if [[ "$p" =~ ^[0-9]+$ ]]; then
            pp=$((10#$p))
            if (( pp >= 1 && pp <= 65535 )); then
                case " $valid " in
                    *" $pp "*) ;;
                    *) valid+="${valid:+ }$pp" ;;
                esac
            fi
        fi
    done

    # 5. Default if detection produced nothing valid
    if [[ -z "$valid" ]]; then
        [[ -n "$CLI_SSH_PORT" ]] && log_warn "--ssh-port has no valid ports, falling back to 22."
        valid="22"
    fi
    printf '%s' "$valid"
}

setup_improved_firewall() {
    log "Configuring UFW..."
    if ! command -v ufw &>/dev/null; then install_packages ufw; fi

    # Detect main network interface for route rule
    local main_nic
    main_nic=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    if [[ -z "$main_nic" ]]; then
        log_warn "Could not detect network interface for UFW route."
    fi

    # Detect the real SSH port(s) so we do not lock out access on a non-standard port (Issue #91)
    local ssh_ports _sp
    ssh_ports=$(detect_ssh_ports)
    log "SSH port(s) for the UFW rule: ${ssh_ports}"

    local ufw_errors=0
    if ufw status 2>/dev/null | grep -q inactive; then
        log "UFW is inactive. Configuring..."
        ufw default deny incoming  || { log_warn "UFW: failed to set default deny incoming"; ufw_errors=1; }
        ufw default allow outgoing || { log_warn "UFW: failed to set default allow outgoing"; ufw_errors=1; }
        for _sp in $ssh_ports; do
            ufw limit "${_sp}/tcp" comment "SSH Rate Limit" || { log_warn "UFW: failed to limit SSH (port ${_sp})"; ufw_errors=1; }
        done
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
        log_warn "UFW will allow SSH ONLY on port(s): ${ssh_ports}. Make sure you connect over it."
        if [[ "$ssh_ports" != "22" ]]; then
            log_warn "NOTE: SSH on a non-standard port. If the port is detected wrong, you will lose server access."
            log_warn "Override if needed: --ssh-port=PORT"
        fi
        local confirm_ufw="y"
        if [[ "$AUTO_YES" -eq 0 ]]; then
            sleep 5
            read -rp "Enable UFW? [y/N]: " confirm_ufw < /dev/tty
        else
            log "Auto-enabling UFW (--yes)."
        fi
        if ! [[ "$confirm_ufw" =~ ^[[:space:]]*[Yy]([Ee][Ss])?[[:space:]]*$ ]]; then
            log_warn "UFW configured but not activated by your choice."
            log_warn "The server is running WITHOUT a firewall. Enable later: sudo ufw enable"
            return 0
        fi
        if ! ufw --force enable; then die "UFW enable error."; fi
        log "UFW enabled."
        # Marker: UFW was enabled by our installer (not by the user beforehand).
        # Used in step_uninstall to decide whether disabling UFW is safe.
        # Protects against destructive uninstall on a VPS where UFW was used
        # for SSH/web hardening BEFORE our script was installed (audit).
        touch "$AWG_DIR/.ufw_enabled_by_installer" 2>/dev/null || \
            log_warn "Failed to create UFW marker — uninstall will not disable UFW automatically."
    else
        log "UFW is active. Updating rules..."
        for _sp in $ssh_ports; do
            ufw limit "${_sp}/tcp" comment "SSH Rate Limit" || { log_warn "UFW: failed to limit SSH (port ${_sp})"; ufw_errors=1; }
        done
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
    if ! command -v fail2ban-client &>/dev/null; then
        install_packages fail2ban
        # Marker: the fail2ban package was installed by our installer (rather
        # than being present before it). step_uninstall purges fail2ban only
        # when the marker exists, so it never wipes SSH protection the user
        # had set up beforehand (symmetric to .ufw_enabled_by_installer).
        if command -v fail2ban-client &>/dev/null; then
            touch "$AWG_DIR/.fail2ban_installed_by_installer" 2>/dev/null || \
                log_warn "Failed to create the fail2ban marker - uninstall will not remove the fail2ban package."
        fi
    fi
    if ! command -v fail2ban-client &>/dev/null; then
        log_warn "Fail2Ban not installed, skipping."
        return 1
    fi

    # banaction=ufw only takes effect with UFW active: if the user declined to
    # enable UFW at step 4, bans land in an inactive ruleset and effectively
    # do nothing (while fail2ban itself looks "green").
    if ufw status 2>/dev/null | grep -q inactive; then
        log_warn "UFW is not active: fail2ban bans (banaction=ufw) have no effect while UFW is off. Enable with: sudo ufw enable"
    fi

    # Debian: journald instead of rsyslog, needs python3-systemd
    if [[ "${OS_ID:-}" == "debian" ]]; then
        install_packages python3-systemd
    fi

    mkdir -p /etc/fail2ban/jail.d 2>/dev/null

    # Backend: systemd for Debian and Ubuntu (no rsyslog)
    local f2b_backend="systemd"

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

    systemctl restart fail2ban
    # Wait a second, service is restarting...
    sleep 1

    if systemctl is-active --quiet fail2ban; then
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
    # --diagnostic runs BEFORE initialize_setup (home of the main root check):
    # as a regular user every log_msg write into /root/awg fails, the report
    # is not created, and exit 0 would look like a false success.
    if [ "$(id -u)" -ne 0 ]; then die "Run the script as root (sudo bash $0 --diagnostic)."; fi
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
    if [[ -z "$backup" || "$backup" =~ ^[[:space:]]*[Yy]([Ee][Ss])?[[:space:]]*$ ]]; then
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
    # v5.12.0+: kernel module auto-repair on kernel upgrade.
    # Remove apt hook and systemd unit BEFORE apt purge so the hook does not
    # fire during amneziawg-dkms purge (the helper would try to rebuild DKMS,
    # but the package is already gone). Files may be absent on installs from
    # before v5.12.0 — all operations are idempotent.
    log "Removing kernel module auto-repair components (v5.12.0+)..."
    if systemctl is-enabled amneziawg-ensure-module.service &>/dev/null; then
        systemctl disable amneziawg-ensure-module.service 2>/dev/null || true
    fi
    rm -f /etc/systemd/system/amneziawg-ensure-module.service \
        /etc/apt/apt.conf.d/99-amneziawg-post-kernel \
        /etc/logrotate.d/amneziawg-ensure-module \
        /usr/local/sbin/amneziawg-ensure-module \
        2>/dev/null
    # Also clean up staging dotfiles that may be left over from an interrupted install (atomic deploy).
    rm -f /etc/systemd/system/.amneziawg-ensure-module.service.new \
        /etc/apt/apt.conf.d/.99-amneziawg-post-kernel.new \
        /etc/logrotate.d/.amneziawg-ensure-module.new \
        /usr/local/sbin/.amneziawg-ensure-module.new \
        2>/dev/null || true
    rm -f /var/log/amneziawg-ensure-module.log* 2>/dev/null || true
    rm -rf /var/lib/amneziawg 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
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
        local _purge_pkgs=(amneziawg-dkms amneziawg-tools qrencode)
        # Purge fail2ban only if we installed it ourselves (marker from
        # setup_fail2ban) - otherwise SSH protection the user had before the
        # installer must not disappear together with the VPN. Our jail file
        # is removed below in any case. Backwards compat: old installs
        # without the marker keep fail2ban installed.
        if [[ -f "$AWG_DIR/.fail2ban_installed_by_installer" ]]; then
            _purge_pkgs+=(fail2ban)
        else
            log "fail2ban left installed (was present before the installer or an older installer version)."
        fi
        DEBIAN_FRONTEND=noninteractive apt-get purge -y "${_purge_pkgs[@]}" 2>/dev/null || log_warn "Purge error."
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
        # If fail2ban was not purged (it predates us) - restart it without our
        # jail: it was stopped above (systemctl stop fail2ban).
        if command -v fail2ban-client &>/dev/null && [[ ! -f "$AWG_DIR/.fail2ban_installed_by_installer" ]]; then
            systemctl restart fail2ban 2>/dev/null || log_warn "Failed to restart fail2ban after removing our jail."
        fi
    fi
    log "Removing DKMS..."
    rm -rf /var/lib/dkms/amneziawg* || log_warn "DKMS removal error."
    log "Restoring sysctl..."
    # Only the exact lines legacy versions of our installer wrote (=1 for
    # all/default/lo). Previously ANY line containing disable_ipv6 was removed -
    # including lines added by the user themselves (e.g. an =0 override).
    if grep -qE '^net\.ipv6\.conf\.(all|default|lo)\.disable_ipv6[[:space:]]*=[[:space:]]*1[[:space:]]*$' /etc/sysctl.conf 2>/dev/null; then
        sed -i -E '/^net\.ipv6\.conf\.(all|default|lo)\.disable_ipv6[[:space:]]*=[[:space:]]*1[[:space:]]*$/d' /etc/sysctl.conf || log_warn "sed sysctl.conf error"
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
    check_kernel_version
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
        # An explicit CLI mode overrides the list too: previously --route-all/
        # --route-amnezia on reinstall changed only the mode while ALLOWED_IPS
        # kept the old value from awgsetup_cfg.init - the flag silently had no
        # effect (Issue #170). An empty list forces configure_routing_mode to
        # recompute it for the new mode.
        ALLOWED_IPS=""
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
        # Interactive input: a typo does not kill the install (the validator
        # runs in a subshell -> die prints the error but only terminates the
        # subshell, and the prompt repeats). The final validate_* calls
        # outside the loop stay authoritative for CLI/config values (die is
        # appropriate there).
        if [[ "$AUTO_YES" -eq 0 ]]; then
            while true; do
                read -rp "Enter AmneziaWG UDP port (1-65535) [${AWG_PORT}]: " input_port < /dev/tty
                [[ -z "$input_port" ]] && break
                if ( validate_port "$input_port" ); then AWG_PORT=$input_port; break; fi
                log_warn "Please re-enter the port."
            done
        fi
        validate_port "$AWG_PORT"
        if [[ "$AUTO_YES" -eq 0 ]]; then
            while true; do
                read -rp "Enter tunnel subnet [${AWG_TUNNEL_SUBNET}]: " input_subnet < /dev/tty
                [[ -z "$input_subnet" ]] && break
                if ( validate_subnet "$input_subnet" ); then AWG_TUNNEL_SUBNET=$input_subnet; break; fi
                log_warn "Please re-enter the subnet."
            done
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

    # Changing the subnet with live peers is forbidden - check before the
    # init file is saved and before any on-disk changes (AWG_TUNNEL_SUBNET
    # is final here).
    guard_subnet_change_with_peers

    # Default values
    if [[ "$DISABLE_IPV6" == "default" ]]; then DISABLE_IPV6=1; fi
    configure_ipv6_tunnel
    if [[ "$ALLOWED_IPS_MODE" == "default" ]]; then ALLOWED_IPS_MODE=2; fi
    if [[ -z "$ALLOWED_IPS" ]]; then configure_routing_mode; fi

    # Single mandatory AllowedIPs validation before saving the config: CLI
    # --route-custom on a first run assigned ALLOWED_IPS without checking it
    # (configure_routing_mode was skipped because the mode was already 3).
    # Validate any non-empty list regardless of its source (CLI / config / mode).
    if [[ -n "$ALLOWED_IPS" ]] && ! validate_cidr_list "$ALLOWED_IPS"; then
        die "Invalid ALLOWED_IPS: '$ALLOWED_IPS'. Expected a list x.x.x.x/y[,x.x.x.x/y]."
    fi

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
        # generate_awg_params regenerates the WHOLE set (S1-S4, H1-H4, I1),
        # not just the requested parameter: on a reinstall over a live server
        # every issued client config still holds the old H1-H4 and will stop
        # connecting. Warn loudly.
        if [[ "$config_exists" -eq 1 && -n "${AWG_Jc:-}" ]]; then
            log_warn "WARNING: --preset/--jc/--jmin/--jmax on a reinstall regenerate ALL obfuscation parameters (including H1-H4/S1-S4/I1)."
            log_warn "All existing client configs will stop connecting - reissue them after the install: sudo bash $MANAGE_SCRIPT_PATH regen"
        fi
        generate_awg_params
    else
        log "AWG 2.0 parameters already set from config."
    fi

    # CPS (I1) toggle (issue #159): --no-cps drops the I1 parameter that makes the
    # desktop AmneziaVPN on macOS hang on connect (mobile and CLI clients handle
    # CPS fine). Only I1 is cleared, the rest of the obfuscation set (Jc/S1-S4/
    # H1-H4) is left intact. Explicit --preset/--jc/--jmin/--jmax without --no-cps
    # re-enable CPS (a fresh set includes I1). Otherwise keep the state from init.
    if [[ "${CLI_NO_CPS:-0}" -eq 1 ]]; then
        NO_CPS=1
    elif [[ -n "${CLI_PRESET:-}" || -n "${CLI_JC:-}" || -n "${CLI_JMIN:-}" || -n "${CLI_JMAX:-}" ]]; then
        NO_CPS=0
    fi
    if [[ "${NO_CPS:-0}" -eq 1 ]]; then
        if [[ -n "${AWG_I1:-}" && "$config_exists" -eq 1 ]]; then
            log_warn "WARNING: --no-cps drops the I1 (CPS) parameter. Existing client configs that still carry I1 will stop connecting - reissue them: sudo bash $MANAGE_SCRIPT_PATH regen"
        fi
        AWG_I1=''
        log "CPS (I1) disabled (--no-cps / persisted NO_CPS=1): the desktop AmneziaVPN on macOS does not support CPS."
    fi

    # Save configuration
    log "Saving settings to $CONFIG_FILE..."
    # temp in the target config's directory -> mv = atomic rename on the same
    # filesystem (not a cross-fs copy+unlink when /tmp is mounted as tmpfs).
    local temp_conf cfg_dir
    cfg_dir="$(dirname "$CONFIG_FILE")"
    mkdir -p "$cfg_dir" 2>/dev/null
    temp_conf=$(mktemp -p "$cfg_dir") || die "mktemp error."
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
export AWG_MTU=${AWG_MTU:-1280}
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
export AWG_I2='${AWG_I2:-}'
export AWG_I3='${AWG_I3:-}'
export AWG_I4='${AWG_I4:-}'
export AWG_I5='${AWG_I5:-}'
export AWG_PRESET='${AWG_PRESET:-default}'
export NO_TWEAKS=${NO_TWEAKS}
export NO_CPS=${NO_CPS}
export AWG_APPLY_MODE='${AWG_APPLY_MODE:-syncconf}'
export ALLOW_IPV6_TUNNEL=${ALLOW_IPV6_TUNNEL:-0}
export IPV6_SUBNET='${IPV6_SUBNET}'
export SERVER_HAS_NATIVE_IPV6=${SERVER_HAS_NATIVE_IPV6:-0}
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
    # Changing the routing mode is a client-config operation: new clients get
    # the new list, but for existing ones regen deliberately preserves
    # AllowedIPs (per-client modify customizations). Hint the explicit way to
    # apply the new mode to everyone (Issue #170).
    if [[ "$config_exists" -eq 1 && "$CLI_ROUTING_MODE" != "default" ]]; then
        log_warn "Routing mode changed. Existing client configs keep their old AllowedIPs."
        log_warn "Apply the new mode to all clients: sudo bash $MANAGE_SCRIPT_PATH regen --reset-routes"
    fi

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

    # First-boot dpkg-lock resilience: unattended-upgrades and apt-daily often
    # hold the lock for several minutes (issue #150 - apt full-upgrade used to
    # fail immediately). DPkg::Lock::Timeout makes apt wait for the lock to be
    # released instead of erroring out.
    mkdir -p /etc/apt/apt.conf.d
    printf 'DPkg::Lock::Timeout "300";\n' > /etc/apt/apt.conf.d/99-amneziawg-lock-timeout \
        || log_warn "Failed to write apt lock-timeout (issue #150 mitigation)."

    # Clean unnecessary components (BEFORE update to save bandwidth/time)
    if [[ "$NO_TWEAKS" -eq 0 ]]; then
        cleanup_system
    else
        log "Skipping system cleanup (--no-tweaks)."
    fi

    log "Updating package lists..."
    apt_update_tolerant || die "apt update error."
    # Cache is fresh: install_packages below must not rerun apt update
    # (sources do not change in step 1).
    _APT_UPDATED=1

    log "Unlocking dpkg..."
    if ! apt-get check &>/dev/null; then
        log_warn "dpkg locked or corrupted, fixing..."
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a || log_warn "dpkg --configure -a."
    fi

    log "Updating system..."
    if ! DEBIAN_FRONTEND=noninteractive apt full-upgrade -y; then
        _lock_holder="$(fuser /var/lib/dpkg/lock-frontend 2>/dev/null | tr -s ' ' || true)"
        if [[ -n "$_lock_holder" ]]; then
            log_warn "dpkg-lock is held by:${_lock_holder} (usually first-boot unattended-upgrades)."
        fi
        log_warn "apt full-upgrade failed, fixing dpkg and retrying..."
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a || true
        DEBIAN_FRONTEND=noninteractive apt full-upgrade -y \
            || die "apt full-upgrade error. Another apt/unattended-upgrades process is likely holding the dpkg lock. Wait for it to finish (check: fuser /var/lib/dpkg/lock-frontend) or run: systemctl stop unattended-upgrades; dpkg --configure -a - then run the script again."
    fi
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
    elif [[ "$kernel" == *-generic* && "${OS_VERSION:-}" == "25.10" ]]; then
        target_id="ubuntu-2510-arm64"
    elif [[ "$kernel" == *-arm64* && "${OS_ID:-}" == "debian" && "${OS_VERSION:-}" == "13" ]]; then
        target_id="debian-trixie-arm64"
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

    # Guard: make sure the user actually rebooted before step 2.
    # If boot_id matches the one saved in request_reboot 2 — the reboot
    # did not happen (e.g. user re-ran the script by mistake). Step 1's
    # apt full-upgrade staged a new kernel on disk, but the running
    # kernel is still the old one → DKMS would build the module against
    # the old kernel and modprobe would fail after the next reboot.
    local boot_id_file="$AWG_DIR/.boot_id_before_step2"
    if [[ -f "$boot_id_file" ]] && [[ -r /proc/sys/kernel/random/boot_id ]]; then
        local saved_boot_id current_boot_id
        saved_boot_id=$(< "$boot_id_file")
        current_boot_id=$(< /proc/sys/kernel/random/boot_id)
        if [[ -n "$saved_boot_id" ]] && [[ "$saved_boot_id" == "$current_boot_id" ]]; then
            die "Reboot expected before step 2 (kernel upgrade is only activated after reboot). Run: sudo reboot — then re-run the script."
        fi
        log "Reboot confirmed (boot_id changed) — continuing with step 2"
        rm -f "$boot_id_file" 2>/dev/null || true
    fi

    log "### STEP 2: Installing AmneziaWG and dependencies ###"
    _APT_UPDATED=0  # Reset: new sources will be added in this step

    # --ppa-amnezia-tolerant is REQUIRED already here: if a PPA file with a
    # broken suite is left on disk (404 Release; e.g. questing from an older
    # version or after an in-place upgrade), a strict update died BEFORE the
    # repair blocks below ever ran, so the repair never fired (live repro on
    # Debian 12, v5.16.0 cycle). Base repository errors remain fail-closed;
    # PPA errors are handled by the repair + post-PPA update +
    # apt_wait_for_ppa_package below.
    apt_update_tolerant --ppa-amnezia-tolerant || die "apt update error."

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
            # For Ubuntu non-LTS (questing/plucky/oracular/...) Amnezia PPA does
            # not publish packages — dists/<codename>/Release returns 404.
            # Pre-check via HEAD and fall back to noble (LTS): the noble build
            # gets DKMS-compiled against the running kernel.
            # Upstream: amnezia-vpn/amneziawg-linux-kernel-module#118
            case "$ppa_codename" in
                noble|jammy|focal)
                    # Known LTS — skip pre-check (PPA is reliably published)
                    ;;
                *)
                    log "Checking Amnezia PPA availability for Ubuntu '${ppa_codename}'..."
                    if ! curl -fsI --max-time 15 --retry 2 --retry-delay 5 \
                        "https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu/dists/${ppa_codename}/Release" \
                        >/dev/null 2>&1; then
                        log_warn "Amnezia PPA does not publish packages for Ubuntu '${ppa_codename}' (HTTP 404 or host unreachable)."
                        log_warn "Falling back to 'noble' — DKMS will build the module against the running kernel."
                        log_warn "Context: https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/issues/118"
                        ppa_codename="noble"
                    else
                        log "Amnezia PPA is available for '${ppa_codename}'."
                    fi
                    ;;
            esac
            ;;
    esac

    local keyring_dir="/etc/apt/keyrings"
    local keyring_file="${keyring_dir}/amnezia-ppa.gpg"
    local ppa_sources="/etc/apt/sources.list.d/amnezia-ppa.sources"
    local ppa_list="/etc/apt/sources.list.d/amnezia-ppa.list"
    # Check for legacy files (from add-apt-repository of previous versions)
    local legacy_list="/etc/apt/sources.list.d/amnezia-ubuntu-ppa-${codename}.list"
    local legacy_sources="/etc/apt/sources.list.d/amnezia-ubuntu-ppa-${codename}.sources"
    # Re-run on a server where a previous run (≤ v5.12.1) wrote a broken
    # .sources file with Suites=questing/plucky/etc.: if the existing suite
    # doesn't match the target ppa_codename, remove the file so it gets
    # recreated below with the correct suite. Same check for legacy
    # .sources (add-apt-repository format).
    # If the file exists but `Suites:` can't be parsed — treat as corrupt
    # and recreate, otherwise the broken file would slip through as
    # "PPA already added".
    local existing_suite=""
    if [[ -f "$ppa_sources" ]]; then
        existing_suite=$(awk '/^Suites:/{print $2; exit}' "$ppa_sources" 2>/dev/null)
    fi
    if [[ -f "$ppa_sources" && ( -z "$existing_suite" || "$existing_suite" != "$ppa_codename" ) ]]; then
        if [[ -z "$existing_suite" ]]; then
            log_warn "$ppa_sources exists but no Suites: line found — recreating."
        else
            log_warn "Existing PPA suite='${existing_suite}', target='${ppa_codename}' — recreating $ppa_sources."
        fi
        rm -f "$ppa_sources" "$ppa_list"
    fi
    local legacy_suite=""
    if [[ -f "$legacy_sources" ]]; then
        legacy_suite=$(awk '/^Suites:/{print $2; exit}' "$legacy_sources" 2>/dev/null)
    fi
    if [[ -f "$legacy_sources" && ( -z "$legacy_suite" || "$legacy_suite" != "$ppa_codename" ) ]]; then
        log_warn "Legacy PPA $legacy_sources (suite='${legacy_suite:-<empty>}') does not match target '${ppa_codename}' — removing."
        rm -f "$legacy_sources" "$legacy_list"
    fi
    # Same repair for the traditional .list (Debian 12): the suite is the token
    # after the URL in a 'deb [opts] URL <suite> main' line. Without this check
    # a file with an old/foreign suite (e.g. after an in-place upgrade
    # bookworm->trixie) would slip through below as "PPA already added" and apt
    # would keep pulling the wrong suite.
    local list_suite=""
    if [[ -f "$ppa_list" ]]; then
        list_suite=$(awk '/^deb([[:space:]]|$)/ {
            for (i = 2; i <= NF; i++) {
                if ($i ~ /^https?:/) { print $(i+1); exit }
            }
        }' "$ppa_list" 2>/dev/null)
        if [[ -z "$list_suite" || "$list_suite" != "$ppa_codename" ]]; then
            log_warn "Existing $ppa_list (suite='${list_suite:-<empty>}') does not match target '${ppa_codename}' - recreating."
            rm -f "$ppa_list"
        fi
    fi
    if [[ -f "$legacy_list" ]] || [[ -f "$legacy_sources" ]]; then
        log "PPA already added (legacy format)."
    elif [[ -f "$ppa_sources" ]] || [[ -f "$ppa_list" ]]; then
        log "PPA already added."
    else
        mkdir -p "$keyring_dir"
        log "Importing Amnezia PPA GPG key..."
        # Atomic: pipe into temp, then mv — a half-written keyring never
        # lives on the target path, even if curl/gpg die mid-way.
        local _kf_tmp
        _kf_tmp=$(mktemp -p "$keyring_dir" ".amnezia-ppa.gpg.tmp.XXXXXX") \
            || die "Failed to create temp file for GPG key."
        # --batch --no-tty --yes: gpg must not open /dev/tty (non-interactive
        # SSH, cloud-init, Ansible, etc.) and must not abort with "File exists"
        # when overwriting the mktemp-created tmp file. Without --yes gpg in
        # batch mode refuses to write into the pre-existing empty tmp file.
        # Request by the FULL 40-character fingerprint, not the short ID:
        # short 32-bit IDs have preimage collisions (evil32), and
        # keyserver.ubuntu.com accepts uploads of arbitrary keys. A swapped
        # key would not give RCE (package signatures would not match), but it
        # would break the install with a cryptic apt error.
        local _ppa_key_fpr="75C9DD72C799870E310542E24166F2C257290828"
        if ! curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${_ppa_key_fpr}" \
             | gpg --batch --no-tty --yes --dearmor -o "$_kf_tmp"; then
            rm -f "$_kf_tmp" 2>/dev/null
            die "Amnezia PPA GPG key import error."
        fi
        # Verify the downloaded key fingerprint against the expected one (pin).
        local _got_fpr
        _got_fpr=$(gpg --batch --no-tty --show-keys --with-colons "$_kf_tmp" 2>/dev/null \
            | awk -F: '/^fpr:/{print $10; exit}')
        if [[ "$_got_fpr" != "$_ppa_key_fpr" ]]; then
            rm -f "$_kf_tmp" 2>/dev/null
            die "Amnezia PPA GPG key failed the fingerprint check (got: '${_got_fpr:-<empty>}')."
        fi
        chmod 644 "$_kf_tmp" || { rm -f "$_kf_tmp" 2>/dev/null; die "chmod GPG key error."; }
        mv -f "$_kf_tmp" "$keyring_file" \
            || { rm -f "$_kf_tmp" 2>/dev/null; die "Failed to move GPG key to target path."; }

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
    # apt-get update + error classification:
    #   - Errors only on the Amnezia PPA → continue, apt_wait_for_ppa_package
    #     below will retry (issue #68: ppa.launchpadcontent.net briefly down).
    #   - Any other non-source error (DNS / GPG mismatch / dpkg lock on the
    #     base mirror) → fail fast. Continuing on a stale apt-cache is unsafe —
    #     the next apt-get install would fail with a less actionable error
    #     (PR #69 review finding).
    if ! apt_update_tolerant --ppa-amnezia-tolerant; then
        log_error "apt-get update failed with a hard error — not a PPA outage (issue #68)."
        log_error "Check: DNS, access to archive.ubuntu.com / deb.debian.org,"
        log_error "integrity of keys in /etc/apt/keyrings, dpkg lock contention."
        die "apt update returned an error (rc!=0, not the Amnezia PPA)."
    fi
    # PPA added, cache refreshed: sources do not change further in step 2, so
    # install_packages must not repeat apt update (on slow mirrors every run
    # is 10-60 seconds).
    _APT_UPDATED=1
    # apt-get update is tolerant to an unreachable InRelease (rc=0 even when
    # the PPA is down). So we check that amneziawg-dkms actually appears in
    # apt-cache, with three attempts and 30s/60s backoff (~1.5 min total).
    # A brief ppa.launchpadcontent.net outage (issue #68) must not break
    # the install.
    if ! apt_wait_for_ppa_package amneziawg-dkms 3 30; then
        log_error "Package amneziawg-dkms did not appear in apt-cache after 3 attempts."
        log_error "ppa.launchpadcontent.net appears to be down — this is a"
        log_error "Launchpad infrastructure outage, not a script bug."
        log_error "Wait 10–15 minutes and re-run the script with the same args."
        log_error "Details: https://github.com/bivlked/amneziawg-installer/issues/68"
        die "Amnezia PPA is temporarily unavailable."
    fi

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
            # request_reboot always terminates the process (exit), we never return here.
            request_reboot 3
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
    # v5.13.0: on 25.10/26.04 after an in-place upgrade from 24.04, the
    # system may still carry kernel headers from 24.04 (6.8.x) compiled with
    # gcc-13. 25.10 ships gcc-15 by default → dkms autoinstall in the
    # amneziawg-dkms postinst fails when building against stale kernels, and
    # dpkg leaves amneziawg* unconfigured. If we detect kernel headers other
    # than the running one, install gcc-13 ahead of time (available in
    # questing/universe and 26.04 archive) so autoinstall succeeds for every
    # kernel.
    local _running_kernel _has_stale=0 _hd _hd_kern
    _running_kernel="$(uname -r)"
    for _hd in /lib/modules/*/build; do
        [[ -e "$_hd" ]] || continue
        _hd_kern="${_hd#/lib/modules/}"
        _hd_kern="${_hd_kern%/build}"
        if [[ "$_hd_kern" != "$_running_kernel" ]]; then
            _has_stale=1
            break
        fi
    done
    if [[ "$_has_stale" -eq 1 ]] && ! command -v gcc-13 >/dev/null 2>&1; then
        if apt-cache madison gcc-13 2>/dev/null | grep -q .; then
            log "Stale kernel headers detected (other than $_running_kernel) — installing gcc-13 for DKMS autoinstall compatibility."
            DEBIAN_FRONTEND=noninteractive apt install -y gcc-13 \
                || log_warn "gcc-13 install failed — DKMS autoinstall may fail on stale kernels."
        else
            log_warn "Stale kernel headers detected, but gcc-13 is not in the repo — DKMS autoinstall may fail."
        fi
    fi
    install_packages "${packages[@]}"

    # v5.12.0: install a kernel-headers meta-package so apt automatically
    # pulls matching headers on every kernel upgrade. Without the meta only
    # linux-headers-$(uname -r) is installed, which does not track new
    # kernels and the DKMS module fails to rebuild on the next apt upgrade.
    #
    # Detect kernel flavor (Ubuntu cloud images: aws/azure/gcp/oracle/kvm/
    # lowlatency/raspi; Debian cloud-amd64) — a plain linux-headers-generic
    # on an Azure VM does not track the right kernel pipeline. Take the
    # uname -r suffix, try the flavor-specific meta first, fall back to
    # generic / arch.
    local arch_meta kernel_rel
    arch_meta="$(dpkg --print-architecture 2>/dev/null || echo '')"
    kernel_rel="$(uname -r)"
    local -a meta_candidates=()
    if [[ "$kernel_rel" == *+rpt* || "$kernel_rel" == *-rpi* ]]; then
        : # RPi: linux-headers-rpi-{2712,v8} meta is already in packages above.
    elif [[ "${OS_ID:-ubuntu}" == "ubuntu" ]]; then
        # Ubuntu uname -r format: 6.8.0-49-generic / 6.8.0-1009-aws / ...
        local flavor="${kernel_rel##*-}"
        if [[ -n "$flavor" && "$flavor" != "$kernel_rel" ]]; then
            meta_candidates+=("linux-headers-${flavor}")
        fi
        meta_candidates+=("linux-headers-generic")
    elif [[ "${OS_ID:-}" == "debian" && -n "$arch_meta" ]]; then
        # Debian: stock kernel 6.12.85+deb13-amd64, cloud — 6.12.85+deb13-cloud-amd64.
        [[ "$kernel_rel" == *-cloud-* ]] \
            && meta_candidates+=("linux-headers-cloud-${arch_meta}")
        meta_candidates+=("linux-headers-${arch_meta}")
    fi
    local meta meta_installed=0
    for meta in "${meta_candidates[@]}"; do
        if dpkg-query -W -f='${Status}' "$meta" 2>/dev/null \
                | grep -q 'install ok installed'; then
            log "$meta is already installed (auto-tracking kernel upgrades)."
            meta_installed=1
            break
        fi
        log "Installing meta-package $meta..."
        if DEBIAN_FRONTEND=noninteractive apt install -y "$meta" 2>/dev/null; then
            log "$meta installed."
            meta_installed=1
            break
        fi
        log_warn "Failed to install $meta — trying next candidate."
    done
    if [[ ${#meta_candidates[@]} -gt 0 && $meta_installed -eq 0 ]]; then
        log_warn "No kernel-headers meta-package installed — auto-rebuild on kernel upgrade may not work."
    fi

    # v5.12.0: deploy the standalone helper /usr/local/sbin/amneziawg-ensure-module.
    # It is invoked from the apt hook (DPkg::Post-Invoke) and from the Phase 4
    # systemd unit. The helper is self-contained — it does NOT source
    # awg_common.sh — so it keeps working even if /root/awg/ is moved.
    #
    # Deploy uses a staging file in the SAME filesystem as the destination
    # plus a final `mv -f` — guaranteeing atomic replacement (a cross-FS
    # rename is copy+remove, NOT atomic). The staging file starts with a
    # dot so apt and logrotate skip dotfiles when scanning the directory.
    log "Deploying DKMS auto-repair helper..."
    mkdir -p /usr/local/sbin
    local _stage_helper=/usr/local/sbin/.amneziawg-ensure-module.new
    cat > "$_stage_helper" <<'AWG_ENSURE_HELPER_EOF'
#!/bin/bash
# amneziawg-ensure-module — rebuilds the AmneziaWG DKMS module after a
# kernel upgrade.
#
# Generated by install_amneziawg.sh (v5.12.0+). Do not edit; re-run the
# installer to refresh.
#
# Modes:
#   --hook     — invoked from /etc/apt/apt.conf.d/99-amneziawg-post-kernel
#                (DPkg::Post-Invoke). Constraints:
#                  - MUST NOT call apt-get install: the parent apt still
#                    holds /var/lib/dpkg/lock-frontend, a nested install
#                    would deadlock.
#                  - Skips modprobe and systemctl: the running kernel may
#                    still be the old one. The newly-built module is
#                    loaded after reboot via the systemd unit, or via
#                    `manage repair-module`.
#                Stamp-file fast-path keeps routine apt ops noise-free.
#
#   --systemd  — invoked from amneziawg-ensure-module.service at boot,
#                ordered Before=awg-quick@awg0.service. Builds for every
#                target kernel (same as --hook), then loads the module
#                via modprobe so awg-quick can start. No stamp fast-path
#                — boot must always verify load state, even if /lib/modules
#                hasn't changed since the last build (module not loaded
#                across reboots). Exit 1 if modprobe fails so systemd
#                marks the unit as failed (visible via systemctl status).
#
# Iteration target: every kernel that exposes /lib/modules/<ver>/build
# (= a directory with installed headers). uname -r alone is insufficient
# in apt-hook context because it returns the OLD running kernel while
# the new kernel's headers are already on disk.
#
# Output: stdout / stderr; --hook appends to
# /var/log/amneziawg-ensure-module.log (rotated weekly via
# /etc/logrotate.d/amneziawg-ensure-module). --systemd writes to journal
# (StandardOutput=journal, StandardError=journal in the unit file).

set -euo pipefail

MODE="${1:-}"
case "$MODE" in
    --hook|--systemd) ;;
    --help|-h) echo "Usage: $0 --hook | --systemd"; exit 0 ;;
    *) echo "amneziawg-ensure-module: missing or unknown mode (use --hook or --systemd)" >&2; exit 2 ;;
esac

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log_line() { printf '[%s] [%s] %s\n' "$(ts)" "$MODE" "$*"; }

if [[ $(id -u) -ne 0 ]]; then
    log_line "ERROR: root privileges required" >&2
    exit 1
fi

if ! command -v dkms >/dev/null 2>&1; then
    log_line "WARN: dkms is not installed — nothing to do"
    exit 0
fi

declare -a target_kernels=()
shopt -s nullglob
for build_dir in /lib/modules/*/build; do
    [[ -d "$build_dir" || -L "$build_dir" ]] || continue
    target_kernels+=("$(basename "$(dirname "$build_dir")")")
done
shopt -u nullglob

if [[ ${#target_kernels[@]} -eq 0 ]]; then
    log_line "WARN: no /lib/modules/*/build directories — kernel headers missing"
    exit 0
fi

# Build per-run state signature (mtime + kver) used by both modes:
#   --hook     — for stamp-file fast-path comparison (silent exit if equal)
#   --systemd  — recorded after success so subsequent --hook calls can skip
STAMP_DIR=/var/lib/amneziawg
STAMP_FILE="${STAMP_DIR}/ensure-module.stamp"
current_state=""
for kver in "${target_kernels[@]}"; do
    # stat may fail (build dir removed in flight) — guard against set -e abort.
    # Empty mtime → comparison differs → we re-run dkms autoinstall (acceptable).
    mtime="$(stat -c '%Y' "/lib/modules/${kver}/build" 2>/dev/null || true)"
    current_state+="${mtime} ${kver} "
done

# Fast-path applies ONLY to --hook. Boot (--systemd) must always run the
# full path — module is not loaded across reboots even when /lib/modules
# state is unchanged.
if [[ "$MODE" == "--hook" ]] \
        && [[ -f "$STAMP_FILE" && "$(cat "$STAMP_FILE" 2>/dev/null)" == "$current_state" ]]; then
    # Silent exit — routine apt ops don't add log noise.
    exit 0
fi

# Strip the deprecated REMAKE_INITRD directive (triggers noisy warnings
# on modern DKMS releases).
for cfg in /var/lib/dkms/amneziawg/*/source/dkms.conf; do
    [[ -f "$cfg" ]] && sed -i '/^REMAKE_INITRD=/d' "$cfg" 2>/dev/null || true
done

build_rc=0
for kver in "${target_kernels[@]}"; do
    log_line "dkms autoinstall -k $kver"
    if ! dkms autoinstall -k "$kver"; then
        log_line "WARN: dkms autoinstall failed for kernel $kver" >&2
        build_rc=1
    fi
done

depmod -a 2>/dev/null || true

# --systemd: load the module so awg-quick can start. Exit 1 on modprobe
# failure — systemd marks the unit failed; visible via `systemctl status
# amneziawg-ensure-module.service`. awg-quick still starts (Before= is
# ordering only, not a dependency) and surfaces its own error if the
# module is unavailable.
if [[ "$MODE" == "--systemd" ]]; then
    log_line "modprobe amneziawg"
    if ! modprobe amneziawg 2>&1; then
        log_line "ERROR: modprobe amneziawg failed for running kernel $(uname -r)" >&2
        log_line "  Check: /var/lib/dkms/amneziawg/<ver>/<kernel>/log/make.log" >&2
        exit 1
    fi
    if ! lsmod 2>/dev/null | grep -q '^amneziawg '; then
        log_line "ERROR: amneziawg module not present in lsmod after modprobe" >&2
        exit 1
    fi
    log_line "amneziawg module loaded for $(uname -r)"
    # Update stamp on --systemd success (current kernel is usable, what matters
    # for boot) even if some other kernel's build failed (build_rc=1).
    mkdir -p "$STAMP_DIR" 2>/dev/null || true
    printf '%s' "$current_state" > "$STAMP_FILE" 2>/dev/null || true
    log_line "done"
    exit 0
fi

# --hook: update stamp only on full success — partial failures retry next run.
if [[ $build_rc -eq 0 ]]; then
    mkdir -p "$STAMP_DIR" 2>/dev/null || true
    printf '%s' "$current_state" > "$STAMP_FILE" 2>/dev/null || true
fi

log_line "done (rc=$build_rc)"
exit "$build_rc"
AWG_ENSURE_HELPER_EOF
    chown root:root "$_stage_helper" 2>/dev/null || true
    chmod 0755 "$_stage_helper" \
        || { rm -f "$_stage_helper"; die "Failed to chmod helper."; }
    mv -f "$_stage_helper" /usr/local/sbin/amneziawg-ensure-module \
        || { rm -f "$_stage_helper"; die "Failed to deploy amneziawg-ensure-module helper."; }
    log "Helper /usr/local/sbin/amneziawg-ensure-module deployed."

    # v5.12.0: apt hook DPkg::Post-Invoke calls the helper after a kernel upgrade.
    mkdir -p /etc/apt/apt.conf.d
    local _stage_hook=/etc/apt/apt.conf.d/.99-amneziawg-post-kernel.new
    cat > "$_stage_hook" <<'AWG_APT_HOOK_EOF'
// amneziawg-installer (v5.12.0+): rebuild DKMS module after kernel upgrades.
// Generated by install_amneziawg.sh — do not edit; re-run the installer to refresh.
DPkg::Post-Invoke {"if [ -x /usr/local/sbin/amneziawg-ensure-module ]; then /usr/local/sbin/amneziawg-ensure-module --hook >>/var/log/amneziawg-ensure-module.log 2>&1 || true; fi";};
AWG_APT_HOOK_EOF
    chown root:root "$_stage_hook" 2>/dev/null || true
    chmod 0644 "$_stage_hook" \
        || { rm -f "$_stage_hook"; die "Failed to chmod apt hook."; }
    mv -f "$_stage_hook" /etc/apt/apt.conf.d/99-amneziawg-post-kernel \
        || { rm -f "$_stage_hook"; die "Failed to deploy apt hook."; }
    log "Apt hook 99-amneziawg-post-kernel installed (auto-rebuild on apt kernel upgrade)."

    # v5.12.0: logrotate config for /var/log/amneziawg-ensure-module.log
    mkdir -p /etc/logrotate.d
    local _stage_logrotate=/etc/logrotate.d/.amneziawg-ensure-module.new
    cat > "$_stage_logrotate" <<'AWG_LOGROTATE_EOF'
/var/log/amneziawg-ensure-module.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
AWG_LOGROTATE_EOF
    chown root:root "$_stage_logrotate" 2>/dev/null || true
    chmod 0644 "$_stage_logrotate" \
        || { rm -f "$_stage_logrotate"; die "Failed to chmod logrotate config."; }
    mv -f "$_stage_logrotate" /etc/logrotate.d/amneziawg-ensure-module \
        || { rm -f "$_stage_logrotate"; die "Failed to deploy logrotate config."; }
    log "Logrotate config /etc/logrotate.d/amneziawg-ensure-module installed (weekly, rotate 4)."

    # v5.12.0 Phase 4: systemd unit guarantees the kernel module is built
    # and loaded BEFORE awg-quick@awg0 starts on every boot. Type=oneshot +
    # RemainAfterExit=yes + Before=awg-quick@awg0.service — the standard
    # pre-load pattern (after a kernel upgrade DKMS may need to rebuild on
    # the very first boot of the new kernel).
    log "Deploying systemd unit amneziawg-ensure-module.service..."
    mkdir -p /etc/systemd/system
    local _stage_unit=/etc/systemd/system/.amneziawg-ensure-module.service.new
    cat > "$_stage_unit" <<'AWG_SYSTEMD_UNIT_EOF'
[Unit]
Description=Ensure amneziawg kernel module is built and loaded
Documentation=https://github.com/bivlked/amneziawg-installer
Before=awg-quick@awg0.service
After=systemd-modules-load.service local-fs.target
ConditionPathExists=/usr/local/sbin/amneziawg-ensure-module

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/amneziawg-ensure-module --systemd
TimeoutStartSec=300
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
AWG_SYSTEMD_UNIT_EOF
    chown root:root "$_stage_unit" 2>/dev/null || true
    chmod 0644 "$_stage_unit" \
        || { rm -f "$_stage_unit"; die "Failed to chmod systemd unit."; }
    mv -f "$_stage_unit" /etc/systemd/system/amneziawg-ensure-module.service \
        || { rm -f "$_stage_unit"; die "Failed to deploy systemd unit."; }
    if ! systemctl daemon-reload; then
        log_warn "systemctl daemon-reload failed — the unit may not activate until reboot."
    fi
    if ! systemctl enable amneziawg-ensure-module.service; then
        log_warn "Failed to enable amneziawg-ensure-module.service — boot-time auto-rebuild will not run."
    fi
    log "Systemd unit amneziawg-ensure-module.service installed and enabled (Before=awg-quick@awg0)."

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

# _secure_download <url> <target> <expected_sha256> <label>
# Atomic download:
#   1. curl → mktemp on the same FS as target;
#   2. verify_sha256 on the temp file (not on target, so a corrupt file
#      never lives on the target path even for a fraction of a second);
#   3. chmod 700 on temp;
#   4. mv -f temp → target (atomic rename).
# If any step fails, temp is removed and target is untouched.
_secure_download() {
    local url="$1" target="$2" expected_sha256="$3" label="$4"
    local tmp target_dir
    target_dir=$(dirname "$target")
    tmp=$(mktemp -p "$target_dir" ".${label//\//_}.tmp.XXXXXX") \
        || die "Failed to create temp file for $label"
    if ! curl -fLso "$tmp" --max-time 60 --retry 2 "$url"; then
        rm -f "$tmp" 2>/dev/null
        die "$label download error"
    fi
    if ! verify_sha256 "$tmp" "$expected_sha256" "$label"; then
        rm -f "$tmp" 2>/dev/null
        die "$label integrity check failed (SHA256 mismatch). Installation aborted."
    fi
    if ! chmod 700 "$tmp"; then
        rm -f "$tmp" 2>/dev/null
        die "chmod $label error"
    fi
    if ! mv -f "$tmp" "$target"; then
        rm -f "$tmp" 2>/dev/null
        die "Failed to move $label to target path"
    fi
    log "$label downloaded and verified."
}

step5_download_scripts() {
    update_state 5
    log "### STEP 5: Downloading management scripts ###"
    cd "$AWG_DIR" || die "Error changing to $AWG_DIR"

    log "Downloading $COMMON_SCRIPT_PATH..."
    _secure_download "$COMMON_SCRIPT_URL" "$COMMON_SCRIPT_PATH" \
        "$COMMON_SCRIPT_SHA256" "awg_common.sh"

    log "Downloading $MANAGE_SCRIPT_PATH..."
    _secure_download "$MANAGE_SCRIPT_URL" "$MANAGE_SCRIPT_PATH" \
        "$MANAGE_SCRIPT_SHA256" "manage_amneziawg.sh"

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

    # Create the AWG 2.0 server config, carrying ALL existing [Peer] blocks
    # over from the backup in ONE atomic write (render_server_config appends
    # the peers into the temp BEFORE mv). Previously the append ran AFTER
    # render as a separate operation: a failure in the window between them
    # left the live config peer-less, and the next run of step 6 backed up
    # the already peer-less file - all clients were lost on --force reinstall
    # (recovery only by hand from a timestamped .bak).
    # C5 history (semantics worth keeping): ALL blocks are restored, including
    # the defaults my_phone/my_laptop - the idempotent loop below skips peers
    # that already exist, and the guard in generate_client refuses to recreate
    # one whose artifacts exist.
    log "Creating server config..."
    render_server_config "${s_bak:-}" || die "Server config creation error."
    if [[ -n "${s_bak:-}" && -f "$s_bak" ]] && grep -q '^\[Peer\]' "$s_bak" 2>/dev/null; then
        log "Existing peers restored from backup."
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
    rm -f "$STATE_FILE" "${STATE_FILE}.lock" "$AWG_DIR/.boot_id_before_step2" || log_warn "Failed to remove $STATE_FILE"
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

# v5.13.0: idempotency guard — if AmneziaWG is already installed and
# running, a re-run wastes ~20 minutes (Step 1 re-tunes sysctl/swap/BBR,
# `apt-get upgrade` can pull a new kernel and force another reboot, Step 7
# restarts awg-quick@awg0 — handshakes drop for a few seconds). Server
# keys, peers and obfuscation parameters survive a re-run, but without
# explicit opt-in this behaviour looks like a silent reinstall. Guarded by
# an explicit flag.
# AWG_FORCE_REINSTALL=1 in the environment is equivalent to --force.
if [[ "${AWG_FORCE_REINSTALL:-0}" == "1" ]]; then
    FORCE_REINSTALL=1
fi
if [[ "$FORCE_REINSTALL" -ne 1 ]] && [[ -f "$SERVER_CONF_FILE" ]] \
   && systemctl is-active --quiet awg-quick@awg0 2>/dev/null; then
    log_error "AmneziaWG is already installed and running."
    log_error "To reinstall — pass --force (or AWG_FORCE_REINSTALL=1)."
    log_error "WARNING: a reinstall will rerun Step 1 (sysctl/swap/BBR) and Step 7 (service restart)."
    log_error "         Obfuscation parameters (Jc/Jmin/Jmax/H1-H4/I1) survive UNLESS you pass"
    log_error "         --preset/--jc/--jmin/--jmax (those flags regenerate the whole set - every"
    log_error "         issued client config would have to be reissued via regen)."
    log_error "To manage clients:  sudo bash $MANAGE_SCRIPT_PATH help"
    log_error "To fully uninstall: sudo bash $0 --uninstall"
    exit 0
fi

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
