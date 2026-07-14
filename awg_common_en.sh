#!/bin/bash

# ==============================================================================
# Shared function library for AmneziaWG 2.0
# Author: @bivlked
# Version: 5.19.2
# Date: 2026-07-15
# Repository: https://github.com/bivlked/amneziawg-installer
# ==============================================================================
#
# This file contains shared functions for key generation, config rendering,
# peer management, and working with AWG 2.0 parameters.
# Intended to be included via source from the install and manage scripts.
# ==============================================================================

# --- Constants (can be overridden before source) ---
AWG_DIR="${AWG_DIR:-/root/awg}"
CONFIG_FILE="${CONFIG_FILE:-$AWG_DIR/awgsetup_cfg.init}"
SERVER_CONF_FILE="${SERVER_CONF_FILE:-/etc/amnezia/amneziawg/awg0.conf}"
KEYS_DIR="${KEYS_DIR:-$AWG_DIR/keys}"

# --- Auto-cleanup of temporary files ---
# NOTE: trap is NOT set here to avoid overwriting the caller's trap handler.
# The calling script must invoke _awg_cleanup() in its own EXIT handler.
_AWG_TEMP_FILES=()
# File-backed temp registry: awg_mktemp is usually called via $(...) (a
# subshell), where the _AWG_TEMP_FILES array mutation is lost in the parent. A
# file survives the subshell, so _awg_cleanup can reliably remove even a temp
# created inside command substitution (e.g. an interrupted config write between
# mktemp and mv). $$ is the calling script's PID, stable across its subshells.
# The registry lives in $AWG_DIR (root-only 0700), NOT in world-writable /tmp:
# a predictable name in /tmp would let a local user pre-plant a file listing
# arbitrary paths, which _awg_cleanup would then delete as root.
_AWG_TEMP_REGISTRY="${AWG_DIR}/.awg_temp_registry.$$"

_awg_cleanup() {
    local f
    for f in "${_AWG_TEMP_FILES[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
    # File-backed public IP cache (see get_server_public_ip) - per-PID, clean it up.
    rm -f "${AWG_DIR}/.public_ip.cache.$$" 2>/dev/null
    # Guard against symlink substitution of the registry: read regular files only.
    if [[ -n "${_AWG_TEMP_REGISTRY:-}" && -f "$_AWG_TEMP_REGISTRY" && ! -L "$_AWG_TEMP_REGISTRY" ]]; then
        while IFS= read -r f; do
            [[ -n "$f" && -f "$f" ]] && rm -f "$f"
        done < "$_AWG_TEMP_REGISTRY"
        rm -f "$_AWG_TEMP_REGISTRY"
    fi
}

# mktemp wrapper with auto-cleanup.
# Optional 1st argument - target directory: the temp file is created in the same
# directory where the final file will live, so the subsequent mv is an atomic
# rename within one filesystem rather than a cross-fs copy+unlink (matters when
# /tmp is mounted as tmpfs). With no argument the behaviour is unchanged (/tmp
# or $TMPDIR) - backward compatible.
awg_mktemp() {
    local dir="${1:-}" f
    if [[ -n "$dir" ]]; then
        mkdir -p "$dir" 2>/dev/null
        f=$(mktemp -p "$dir") || return 1
    else
        f=$(mktemp) || return 1
    fi
    _AWG_TEMP_FILES+=("$f")
    # Mirror the path into the file registry - it survives a subshell
    # ($(awg_mktemp ...)), unlike the array above.
    [[ -n "${_AWG_TEMP_REGISTRY:-}" ]] && printf '%s\n' "$f" >> "$_AWG_TEMP_REGISTRY" 2>/dev/null
    echo "$f"
}

# --- Logging stubs (overridden by the calling script) ---
if ! declare -f log >/dev/null 2>&1; then
    log()       { echo "[INFO] $1"; }
    log_warn()  { echo "[WARN] $1" >&2; }
    log_error() { echo "[ERROR] $1" >&2; }
    log_debug() { echo "[DEBUG] $1"; }
fi

# ==============================================================================
# Utilities
# ==============================================================================

# --- IP / CIDR validators (shared by install and manage) ---
# These check numeric ranges, not just shape: IPv4 octets 0-255, IPv4 prefix
# 0-32, IPv6 0-128. A bare address (no prefix) is valid (wireguard-tools treats
# a bare IPv4 as /32 and a bare IPv6 as /128 - a host route).

# _valid_ipv4 <addr> : exactly 4 octets, each 0-255 (10# avoids a leading-zero
# octet being read as octal inside (( )) ).
_valid_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local o
    for o in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
        (( 10#$o <= 255 )) || return 1
    done
    return 0
}

# _valid_ipv6 <addr> : structural check (not just charset). Allows one "::"
# compression; without it requires exactly 8 groups of 1-4 hex digits, with it
# at most 7. Embedded IPv4 (::ffff:1.2.3.4) is intentionally unsupported - it
# does not occur in tunnel AllowedIPs and the dots are rejected by the charset.
_valid_ipv6() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    case "$ip" in
        *:::*)   return 1 ;;                     # three or more ":" in a row
        *::*::*) return 1 ;;                     # more than one "::"
    esac
    [[ "$ip" == :* && "$ip" != ::* ]] && return 1   # lone leading ":"
    [[ "$ip" == *: && "$ip" != *:: ]] && return 1   # lone trailing ":"
    local has_dcolon=0
    [[ "$ip" == *::* ]] && has_dcolon=1
    local IFS=':' parts=() p ngroups=0
    read -ra parts <<< "$ip"
    for p in "${parts[@]}"; do
        [[ -z "$p" ]] && continue                 # empty fields from "::"
        [[ "$p" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        (( ngroups++ ))
    done
    if [[ $has_dcolon -eq 1 ]]; then
        (( ngroups <= 7 )) || return 1            # "::" stands for >=1 group
    else
        (( ngroups == 8 )) || return 1
    fi
    return 0
}

# _valid_cidr <token> : IPv4/IPv6 address with an optional prefix. If present,
# the prefix must be a number in range (IPv4 0-32, IPv6 0-128). An empty prefix
# after "/" (e.g. "1.2.3.4/") is rejected.
_valid_cidr() {
    local tok="$1" addr prefix
    if [[ "$tok" == */* ]]; then
        addr="${tok%/*}"; prefix="${tok##*/}"
        [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
    else
        addr="$tok"; prefix=""
    fi
    if _valid_ipv4 "$addr"; then
        [[ -z "$prefix" ]] && return 0
        (( 10#$prefix <= 32 )) || return 1
        return 0
    elif _valid_ipv6 "$addr"; then
        [[ -z "$prefix" ]] && return 0
        (( 10#$prefix <= 128 )) || return 1
        return 0
    fi
    return 1
}

# _valid_host_or_ipv4 <host> : for Endpoint - a valid IPv4 OR an FQDN.
_valid_host_or_ipv4() {
    local host="$1"
    _valid_ipv4 "$host" && return 0
    [[ "$host" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$ ]] || return 1
    # An all-numeric last label is not a real TLD (RFC 3696) but more likely a
    # malformed IPv4 (e.g. "999.1.1.1"); reject it so a typo'd IP is not accepted.
    local last="${host##*.}"
    [[ "$last" =~ ^[0-9]+$ ]] && return 1
    return 0
}

# --- CIDR arithmetic (shared by the IPv4/IPv6 allocator) ---
# Pure functions, bash arithmetic only ($(( ))), no external dependencies.
# set-e-safe: read values via $(( ))/local, guard with "|| return".

# _ipv4_to_int <a.b.c.d> : 32-bit integer from IPv4. Input guard is _valid_ipv4
# (do not reinvent octet checks). 10# guards against a leading-zero octet being
# parsed as octal.
_ipv4_to_int() {
    _valid_ipv4 "$1" || return 1
    local IFS=. o
    read -ra o <<< "$1"
    echo $(( (10#${o[0]} << 24) | (10#${o[1]} << 16) | (10#${o[2]} << 8) | 10#${o[3]} ))
}

# _int_to_ipv4 <int> : IPv4 from a 32-bit integer.
_int_to_ipv4() {
    local n="$1"
    echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
}

# _cidr_bounds <addr/prefix> : prints "network_int broadcast_int".
# The single source of the network/broadcast formula in awg_common.
_cidr_bounds() {
    local cidr="$1" addr prefix ip mask net bcast
    addr="${cidr%/*}"; prefix="${cidr##*/}"
    [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
    (( 10#$prefix >= 0 && 10#$prefix <= 32 )) || return 1
    ip=$(_ipv4_to_int "$addr") || return 1
    if (( 10#$prefix == 0 )); then mask=0; else mask=$(( (0xFFFFFFFF << (32 - 10#$prefix)) & 0xFFFFFFFF )); fi
    net=$(( ip & mask ))
    bcast=$(( net | (0xFFFFFFFF ^ mask) ))
    echo "$net $bcast"
}

# Detect primary (egress) network interface.
# Fallback chain so we don't abort on hosts where the 1.1.1.1 probe returns no
# interface: the provider null-routes/blocks the address, policy-routing, or
# IPv6-only egress (seen on Ubuntu 26.04 / Timeweb, issue #166).
# Manual override: export AWG_MAIN_NIC=<iface> before running.
get_main_nic() {
    # Accept a manual override only if it is an existing, safe ifname: the value
    # ends up in PostUp/PostDown (iptables -o ...), so reject names with shell
    # metacharacters and non-existent interfaces (fall through to auto-detect).
    if [[ -n "${AWG_MAIN_NIC:-}" ]]; then
        if [[ "$AWG_MAIN_NIC" =~ ^[A-Za-z0-9._-]+$ ]] \
            && ip link show dev "$AWG_MAIN_NIC" &>/dev/null; then
            printf '%s\n' "$AWG_MAIN_NIC"
            return 0
        fi
        # Reject an invalid override LOUDLY (log_warn goes to stderr, so the $()
        # output stays clean): a silent fall-through would confuse a user who
        # already followed the export AWG_MAIN_NIC=... hint with a typo.
        log_warn "AWG_MAIN_NIC='${AWG_MAIN_NIC}' ignored: interface not found or the name is invalid - continuing with auto-detection."
    fi
    local nic
    # 1) Real egress to a public address (FIB lookup, fast path for most hosts).
    nic=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    # 2) Default IPv4 route (when the probe is unreachable/blocked).
    [[ -z "$nic" ]] && nic=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    # 3) First UP interface with a global IPv4 (no default route). Exclude
    #    tunnel/virtual interfaces (awg0 itself is UP with a 10.x scope-global
    #    address on a --force reinstall, docker0/br-*/veth* on container hosts):
    #    otherwise the NAT would hairpin through the tunnel itself, and the
    #    IPv6-only warning would be silently suppressed (awg0 has a global IPv4).
    [[ -z "$nic" ]] && nic=$(ip -o -4 addr show up scope global 2>/dev/null \
        | awk '{sub(/@.*/,"",$2); if ($2!="lo" && $2 !~ /^(awg|wg|docker|br-|virbr|veth|lxc|tun|tap)/) { print $2; exit }}')
    # 4) Default IPv6 route (IPv6-only egress).
    [[ -z "$nic" ]] && nic=$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [[ -n "$nic" ]] || return 1
    printf '%s\n' "$nic"
}

# Returns 0 if the host has no IPv4 egress: no default IPv4 route AND interface
# $1 has no global IPv4 address. Such a host is IPv6-only (issue #166: Timeweb
# Ubuntu 26.04) - the IPv4 tunnel (10.x) cannot be NATed out. Both conditions
# must hold: on dual-stack/IPv4 hosts the function returns 1.
host_lacks_ipv4_egress() {
    local nic="$1"
    # [[ -z $(...) ]] instead of "| grep -q .": grep -q exits on the first line,
    # and under pipefail a multi-line ip output (several default routes) could
    # yield SIGPIPE=141 -> a spurious "no route" on a healthy dual-stack host.
    [[ -z "$(ip -4 route show default 2>/dev/null)" ]] \
        && [[ -z "$(ip -o -4 addr show dev "$nic" up scope global 2>/dev/null)" ]]
}

# Detect server public IP (with caching).
#
# The 6-service list covers common NAT and cloud scenarios without
# hard ranking by uptime: ifconfig.me has been historically stable on
# regular VPS (Hetzner, Vultr, OVH), checkip.amazonaws.com remains
# reachable from AWS / GCP / OCI private subnets behind a NAT Gateway,
# ipinfo.io / icanhazip / ifconfig.io are extra fallbacks against
# rate-limit on any single endpoint. Order is alphabetical (deterministic
# for tests and diffs). First-wins: when one service returns a valid IP,
# the rest are skipped.
_CACHED_PUBLIC_IP=""
# File-backed twin of the cache: get_server_public_ip is almost always called
# as $(...) (a subshell), where the _CACHED_PUBLIC_IP assignment is lost in the
# parent and the cache variable never kicks in. A PID-suffixed file survives
# the subshell (same trick as _AWG_TEMP_REGISTRY) and is removed in
# _awg_cleanup. Without it `manage regen` over N clients would do N curl
# rounds (up to 6 services at 5 sec each) when AWG_ENDPOINT is empty.
_PUBLIC_IP_CACHE="${AWG_DIR}/.public_ip.cache.$$"
get_server_public_ip() {
    if [[ -n "$_CACHED_PUBLIC_IP" ]]; then
        echo "$_CACHED_PUBLIC_IP"
        return 0
    fi
    if [[ -f "$_PUBLIC_IP_CACHE" && ! -L "$_PUBLIC_IP_CACHE" ]]; then
        local cached
        cached=$(<"$_PUBLIC_IP_CACHE")
        if [[ -n "$cached" ]] && _valid_ipv4 "$cached"; then
            _CACHED_PUBLIC_IP="$cached"
            echo "$cached"
            return 0
        fi
    fi
    local ip="" svc
    for svc in \
        https://api.ipify.org \
        https://checkip.amazonaws.com \
        https://icanhazip.com \
        https://ifconfig.io \
        https://ifconfig.me \
        https://ipinfo.io/ip
    do
        ip=$(curl -4 -sf --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$ip" ]] && _valid_ipv4 "$ip"; then
            _CACHED_PUBLIC_IP="$ip"
            printf '%s\n' "$ip" > "$_PUBLIC_IP_CACHE" 2>/dev/null || true
            # Observability: write trace to LOG_FILE directly. Never to stdout
            # (the function's stdout IS the IP; any extra bytes corrupt the
            # caller's $(get_server_public_ip) capture and the generated
            # client Endpoint line).
            if [[ -n "${LOG_FILE:-}" && -w "$(dirname "${LOG_FILE}")" ]]; then
                printf '[%s] DEBUG: public IP detected: %s (via %s)\n' \
                    "$(date +'%F %T')" "$ip" "$svc" >>"$LOG_FILE" 2>/dev/null || true
            fi
            echo "$ip"
            return 0
        fi
    done
    if [[ -n "${LOG_FILE:-}" && -w "$(dirname "${LOG_FILE}")" ]]; then
        printf '[%s] DEBUG: public IP detection failed (all 6 services unreachable or invalid)\n' \
            "$(date +'%F %T')" >>"$LOG_FILE" 2>/dev/null || true
    fi
    echo ""
    return 1
}

# Fallback: first non-loopback IPv4 on a network interface.
# Used when curl to ifconfig.me / ipify / ... does not go through
# (LXC without egress, outbound firewall, etc.). On bare metal / regular
# VPS this usually matches the public IP; on a NAT'd host it returns a
# private address — in that case the caller must emit log_warn so the
# user can hand-edit the Endpoint in the client .conf files.
_try_local_ip() {
    local ip
    ip=$(ip -4 -o addr show scope global 2>/dev/null \
        | awk '{print $4}' \
        | cut -d/ -f1 \
        | grep -v '^127\.' \
        | head -1)
    { [[ -n "$ip" ]] && _valid_ipv4 "$ip"; } || return 1
    echo "$ip"
    return 0
}

# Note: apt_update_tolerant() is defined inline in install_amneziawg_en.sh
# (needed in steps 1-2 before this file is downloaded). Not duplicated here.

# ==============================================================================
# AWG 2.0 parameter generation (used in tests + manage)
# ==============================================================================

# Random number [min, max] via /dev/urandom (uint32 support).
# Mirrors install_amneziawg_en.sh:rand_range — needed here for tests and regen.
rand_range() {
    local min=$1 max=$2
    local range=$((max - min + 1))
    local random_val
    random_val=$(od -An -tu4 -N4 /dev/urandom 2>/dev/null | tr -d ' ')
    if [[ -z "$random_val" || ! "$random_val" =~ ^[0-9]+$ ]]; then
        # Fallback: three $RANDOM (15 bits) with XOR overlap = full 31 bits.
        random_val=$(( (RANDOM << 16) ^ (RANDOM << 8) ^ RANDOM ))
    fi
    echo $(( (random_val % range) + min ))
}

# Generate 4 non-overlapping ranges for AWG H1-H4.
# Algorithm: 8 random values → sort → 4 (low, high) pairs.
# Sorting gives low <= high; the strict checks below guarantee a gap between
# pairs (touching bounds = overlap at a single point) and a lower bound >= 5
# (values 1-4 are reserved for vanilla WireGuard message types).
# Minimum width per range = 1000.
# Prints 4 "low-high" lines to stdout. Returns 1 on failure.
# Mitigates Russian DPI fingerprinting of static H values (#38).
#
# Range: [0, 2^31-1] = [0, 2147483647]. The AmneziaWG spec allows the
# full uint32 (0-4294967295), but the standalone Windows client
# `amneziawg-windows-client` has a UI validator capped at 2^31-1 in
# `ui/syntax/highlighter.go:isValidHField()` (upstream bug
# amnezia-vpn/amneziawg-windows-client#85, not yet fixed). Values
# above 2^31-1 work on the server, but the client's config editor
# underlines them as invalid and blocks saving. For compatibility we
# generate in the safe half of the range (#40).
#
# Optimization: a single `od -N32 -tu4` call reads 32 bytes = 8 uint32
# values in one operation, instead of 8 separate subprocess calls via
# rand_range. Falls back to rand_range if /dev/urandom is unavailable.
generate_awg_h_ranges() {
    local attempt=0 max_attempts=20
    while (( attempt < max_attempts )); do
        local raw arr=() _v
        # One 32-byte read from /dev/urandom = 8 uint32 values
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
        # Fallback: 8 separate rand_range calls (if urandom unavailable)
        if (( ${#arr[@]} != 8 )); then
            arr=()
            local _i
            for _i in 1 2 3 4 5 6 7 8; do
                arr+=("$(rand_range 0 2147483647)")
            done
        fi
        # Sort
        local sorted
        sorted=$(printf '%s\n' "${arr[@]}" | sort -n)
        arr=()
        while IFS= read -r _v; do arr+=("$_v"); done <<< "$sorted"
        # Check: minimum width per pair, strict gap between pairs (no
        # touching bounds) and lower bound outside the reserved values 1-4
        # (vanilla WireGuard message types).
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

# ==============================================================================
# DKMS / amneziawg kernel module auto-recovery
# ==============================================================================
#
# After an apt kernel upgrade the DKMS module must be rebuilt for the new
# kernel. If that did not happen automatically (or the module was unbound),
# the 4 functions below perform an idempotent recovery:
#
#   _sanitize_awg_dkms_conf       — strip the deprecated REMAKE_INITRD= directive
#   _install_kernel_headers       — distro-aware fallback chain (Ubuntu/Debian)
#   _ensure_awg_quick_running     — start awg-quick@awg0 if inactive
#   ensure_amneziawg_kernel_module — master, public entry point
#
# === Use context and safety contract ===
#
# Master ensure_amneziawg_kernel_module() assumes that the running kernel
# (uname -r) is the target kernel — i.e. it is suited for post-reboot
# contexts only: manage repair-module, manage add/remove (after the user
# rebooted), the systemd unit (which fires at boot when the new kernel is
# already running). From a DPkg::Post-Invoke hook uname -r still returns the
# OLD kernel — for that case the Phase 3 apt-hook helper will use a separate
# wrapper that iterates target kernels via /lib/modules/*/build.
#
# Master does NOT call apt-get install by default (deadlock in any context
# where a parent process holds /var/lib/dpkg/lock-frontend). The apt step is
# gated by the AWG_ALLOW_APT_IN_ENSURE=1 environment variable, which is set
# only by install_amneziawg step 2 / manage repair-module. The apt hook
# helper and the systemd unit do NOT set it; master skips the headers step.
#
# Headers must be set up separately at install time via a meta-package
# (linux-headers-$(arch) on Debian, linux-headers-generic on Ubuntu) — apt
# then pulls matching headers automatically on apt kernel upgrade.

# Strip the deprecated REMAKE_INITRD= directive from the amneziawg dkms.conf.
# Modern DKMS versions consider it deprecated and print noisy warnings.
_sanitize_awg_dkms_conf() {
    local conf
    for conf in /var/lib/dkms/amneziawg/*/source/dkms.conf; do
        [[ -f "$conf" ]] && sed -i '/^REMAKE_INITRD=/d' "$conf"
    done
}

# Install a kernel headers package via a distro-aware fallback chain.
# Argument: kernel version (defaults to $(uname -r)).
# Returns: 0 if at least one candidate installed successfully, 1 if all failed.
#
# IMPORTANT: only call from contexts where the apt lock is available
# (install_amneziawg step 2 or manage repair-module). MUST NOT be called from
# the DPkg::Post-Invoke hook.
#
# Recognises Raspberry Pi Foundation kernels (+rpt/-rpi suffix):
# linux-headers-rpi-2712 (Pi 5 / Cortex-A76) or linux-headers-rpi-v8 (Pi 3/4 arm64).
_install_kernel_headers() {
    # Defense-in-depth: this function calls apt-get install and must never
    # run from a hook context (deadlock on dpkg lock). Master already gates
    # it via AWG_ALLOW_APT_IN_ENSURE, but the _ prefix is not enforced — the
    # same gate is added here so an accidental direct call from a third-party
    # script still cannot bypass the protection.
    if [[ "${AWG_ALLOW_APT_IN_ENSURE:-0}" != "1" ]]; then
        log_error "_install_kernel_headers: AWG_ALLOW_APT_IN_ENSURE is not set — apt invocation forbidden in this context."
        return 1
    fi

    local kernel_ver="${1:-$(uname -r)}"
    local candidates=()

    # RPi Foundation kernel (suffix +rpt or -rpi) — separate meta-package
    # regardless of distro. Pattern check order: 2712 → v7l → v7 → v8 (default).
    if [[ "$kernel_ver" == *+rpt* || "$kernel_ver" == *-rpi* ]]; then
        if [[ "$kernel_ver" == *2712* ]]; then
            candidates+=("linux-headers-rpi-2712")  # Pi 5 / Cortex-A76
        elif [[ "$kernel_ver" == *-rpi-v7l* ]]; then
            candidates+=("linux-headers-rpi-v7l")   # armhf 32-bit (LPAE)
        elif [[ "$kernel_ver" == *-rpi-v7* ]]; then
            candidates+=("linux-headers-rpi-v7")    # armhf 32-bit older
        else
            candidates+=("linux-headers-rpi-v8")    # Pi 3/4 arm64 default
        fi
    fi

    case "${OS_ID:-}" in
        ubuntu)
            candidates+=(
                "linux-headers-${kernel_ver}"
                "linux-headers-generic"
                "raspberrypi-kernel-headers"
            )
            ;;
        debian)
            local arch
            arch=$(dpkg --print-architecture 2>/dev/null)
            candidates+=("linux-headers-${kernel_ver}")
            if [[ -n "$arch" ]]; then
                # Debian cloud images use a dedicated meta-package
                # linux-headers-cloud-${arch} instead of the generic
                # linux-headers-${arch} (different kernel ABI — sched/IRQ
                # timers trimmed for VMs). Prefer cloud-meta when the
                # running kernel is explicitly a cloud build — otherwise
                # repair-module fails on AWS/Azure/GCP/cloud-Hetzner after
                # a kernel upgrade, even though headers are available via
                # the cloud meta-package.
                if [[ "$kernel_ver" == *-cloud-* ]]; then
                    candidates+=("linux-headers-cloud-${arch}")
                fi
                candidates+=("linux-headers-${arch}")
            fi
            ;;
        *)
            log_error "Installing kernel headers: unknown OS_ID='${OS_ID:-}' (only ubuntu/debian are supported)."
            return 1
            ;;
    esac

    local pkg
    for pkg in "${candidates[@]}"; do
        if apt-get install -y "$pkg" >/dev/null 2>&1; then
            log "Installed kernel headers: $pkg"
            return 0
        fi
        log_warn "Failed to install $pkg, trying next candidate..."
    done
    log_error "Failed to install any kernel headers package (${candidates[*]})."
    return 1
}

# Start awg-quick@<iface> if the service is inactive.
# Argument: interface name (defaults to awg0).
# Returns: 0 on successful start or if already active, 1 on failure.
_ensure_awg_quick_running() {
    local iface="${1:-awg0}"
    local svc="awg-quick@${iface}.service"

    if systemctl is-active --quiet "$svc"; then
        return 0
    fi

    log "Starting $svc (was inactive)..."
    if systemctl start "$svc"; then
        log "$svc started."
        return 0
    fi
    log_error "Failed to start $svc. Details: systemctl status $svc"
    return 1
}

# Master: ensure that the amneziawg kernel module is built and loaded for the running kernel.
# Idempotent: fast-path returns 0 if the module is already loaded.
#
# Argument: mode — "full" (default: module + start awg-quick) or
#                  "module-only" (module only, no service start).
#
# IMPORTANT: master is intended for post-reboot contexts (manage repair-module,
# manage add/remove after a reboot, the systemd unit at boot). Apt/dpkg hook
# code MUST NOT call master — uname -r inside Post-Invoke still returns the
# OLD kernel, so the hook must use a separate wrapper that iterates target
# kernels via /lib/modules/*/build (Phase 3 helper).
#
# Environment: AWG_ALLOW_APT_IN_ENSURE=1 enables the kernel-headers install step
# via apt-get install (dangerous in hook context — deadlock on dpkg lock).
# When unset → headers step is skipped with a warning (assumes headers are
# already on disk via the linux-headers-$(arch) meta-package).
#
# When needed, runs a 5-step recovery:
#   headers → sanitize → dkms autoinstall → depmod → modprobe.
#
# Returns:
#   0 — module loaded successfully (and in "full" mode awg-quick is active).
#   1 — final modprobe failed, or invalid mode argument
#       (with a 4-step manual recovery printed to the log).
#   2 - "full" mode only: the module is fine but awg-quick@awg0 did not
#       start (a service problem: broken config, busy port, etc.).
#       Previously this was swallowed into log_warn + return 0 and
#       repair-module claimed "service is active" while it was down
#       (Issue #175).
ensure_amneziawg_kernel_module() {
    local mode="${1:-full}"
    case "$mode" in
        full|module-only) ;;
        *)
            log_error "ensure_amneziawg_kernel_module: invalid mode '$mode' (expected 'full' or 'module-only')."
            return 1
            ;;
    esac
    local kernel_ver
    kernel_ver="$(uname -r)"

    # Fast-path: module already loaded.
    if lsmod 2>/dev/null | awk '{print $1}' | grep -qx 'amneziawg'; then
        if [[ "$mode" == "full" ]]; then
            _ensure_awg_quick_running awg0 || {
                log_warn "Module is active but awg-quick@awg0 did not start (module OK, this is a service issue)."
                return 2
            }
        fi
        return 0
    fi

    # Module on disk for the running kernel — try modprobe before full repair.
    if find "/lib/modules/${kernel_ver}" -name 'amneziawg.ko*' -print -quit 2>/dev/null | grep -q .; then
        if modprobe amneziawg 2>/dev/null && \
           lsmod 2>/dev/null | awk '{print $1}' | grep -qx 'amneziawg'; then
            log "amneziawg module found on disk and loaded successfully."
            if [[ "$mode" == "full" ]]; then
                _ensure_awg_quick_running awg0 || {
                    log_warn "Module loaded but awg-quick@awg0 did not start (module OK, this is a service issue)."
                    return 2
                }
            fi
            return 0
        fi
    fi

    log_warn "amneziawg module is not loaded and not built for kernel ${kernel_ver}."
    log_warn "Starting automatic recovery..."

    # Step 1: kernel headers — only when apt is allowed by the calling context.
    if [[ "${AWG_ALLOW_APT_IN_ENSURE:-0}" == "1" ]]; then
        case "${OS_ID:-}" in
            ubuntu|debian)
                local headers_pkg="linux-headers-${kernel_ver}"
                if ! dpkg-query -W -f='${Status}' "$headers_pkg" 2>/dev/null | grep -q 'install ok installed'; then
                    log "Kernel headers ($headers_pkg) are not installed. Installing..."
                    _install_kernel_headers "$kernel_ver" || \
                        log_warn "Failed to install kernel headers. The DKMS module build may fail."
                fi
                ;;
        esac
    elif [[ ! -d "/lib/modules/${kernel_ver}/build" ]]; then
        log_warn "/lib/modules/${kernel_ver}/build is missing, headers are not installed."
        log_warn "Apt install skipped (context does not allow apt). The DKMS build will most likely fail."
    fi

    # Step 2: strip the deprecated REMAKE_INITRD from dkms.conf
    _sanitize_awg_dkms_conf

    # Step 3: dkms autoinstall for the running kernel.
    # If this step reports an error, still try modprobe below — that's the definitive check.
    if command -v dkms >/dev/null 2>&1; then
        log "Running: dkms autoinstall -k ${kernel_ver}"
        if ! dkms autoinstall -k "${kernel_ver}" >/dev/null 2>&1; then
            log_warn "dkms autoinstall reported an error for kernel ${kernel_ver}."
            local dkms_log
            dkms_log=$(find /var/lib/dkms/amneziawg -name 'make.log' -path "*${kernel_ver}*" 2>/dev/null | head -n 1)
            if [[ -n "$dkms_log" ]]; then
                log_warn "Last 20 lines of the DKMS build log (${dkms_log}):"
                tail -20 "$dkms_log" | while IFS= read -r line; do log_warn "  $line"; done
            else
                log_warn "Build log not found. Details under /var/lib/dkms/amneziawg/."
            fi
        fi
    else
        log_warn "The dkms package is not installed. Cannot rebuild the kernel module."
    fi

    # Step 4: rebuild module dependency cache for the specific kernel.
    if command -v depmod >/dev/null 2>&1; then
        depmod -a "$kernel_ver" 2>/dev/null || \
            log_warn "depmod -a $kernel_ver reported an error; modprobe below will give the final diagnosis."
    fi

    # Step 5: final modprobe attempt.
    if ! modprobe amneziawg 2>/dev/null; then
        log_error "amneziawg kernel module could not be loaded for kernel ${kernel_ver}."
        log_error "The module is not present in /lib/modules/${kernel_ver}/."
        log_error "Manual recovery:"
        log_error "  1. apt install -y \"linux-headers-${kernel_ver}\""
        log_error "  2. dkms autoinstall -k \"${kernel_ver}\" && depmod -a"
        log_error "  3. modprobe amneziawg"
        log_error "  4. systemctl start \"awg-quick@awg0\""
        return 1
    fi

    log "amneziawg module loaded successfully for kernel ${kernel_ver}."
    if [[ "$mode" == "full" ]]; then
        _ensure_awg_quick_running awg0 || {
            log_warn "Module loaded but awg-quick@awg0 did not start (module OK, this is a service issue)."
            return 2
        }
    fi
    return 0
}

# ==============================================================================
# Loading / saving parameters
# ==============================================================================

# Safe configuration loader (whitelist parser, no source/eval)
# Parses only allowed keys in KEY=VALUE or export KEY=VALUE format
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
                AWG_APPLY_MODE|ALLOW_IPV6_TUNNEL|IPV6_SUBNET|SERVER_HAS_NATIVE_IPV6|PREV_AWG_PORT)
                    export "$key=$value"
                    ;;
            esac
        fi
    done < "$config_file"
}

# Parser for the live AmneziaWG server config (source of truth for AWG_*).
# Reads the [Interface] section of awg0.conf and exports AWG_* variables
# ATOMICALLY: either all 11 required parameters (Jc/Jmin/Jmax/S1-S4/H1-H4)
# are found and exported, or nothing changes in the environment and 1
# is returned. Protects against mixed state when awg0.conf is partially
# corrupt. I1-I5, ListenPort are optional - exported only if found.
# Fixes #38: regen used stale values from the init file instead of the
# actual awg0.conf after manual edits.
# shellcheck disable=SC2120  # Optional argument is only used in tests
load_awg_params_from_server_conf() {
    local conf="${1:-$SERVER_CONF_FILE}"
    [[ -f "$conf" ]] || return 1

    # Local accumulation — all-or-nothing export at the end
    local _Jc="" _Jmin="" _Jmax=""
    local _S1="" _S2="" _S3="" _S4=""
    local _H1="" _H2="" _H3="" _H4=""
    local _I1="" _I2="" _I3="" _I4="" _I5="" _Port="" _MTU=""

    local in_iface=0 line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^\[Interface\] ]]; then in_iface=1; continue; fi
        if [[ "$line" =~ ^\[ ]]; then in_iface=0; continue; fi
        (( in_iface )) || continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        if [[ "$line" =~ ^[[:space:]]*([A-Za-z0-9]+)[[:space:]]*=[[:space:]]*(.+)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            value="${value%"${value##*[![:space:]]}"}"
            case "$key" in
                Jc)         _Jc="$value" ;;
                Jmin)       _Jmin="$value" ;;
                Jmax)       _Jmax="$value" ;;
                S1)         _S1="$value" ;;
                S2)         _S2="$value" ;;
                S3)         _S3="$value" ;;
                S4)         _S4="$value" ;;
                H1)         _H1="$value" ;;
                H2)         _H2="$value" ;;
                H3)         _H3="$value" ;;
                H4)         _H4="$value" ;;
                I1)         _I1="$value" ;;
                I2)         _I2="$value" ;;
                I3)         _I3="$value" ;;
                I4)         _I4="$value" ;;
                I5)         _I5="$value" ;;
                ListenPort) _Port="$value" ;;
                MTU)        _MTU="$value" ;;
            esac
        fi
    done < "$conf"

    # Atomic check: are all 11 required fields present?
    [[ -n "$_Jc" && -n "$_Jmin" && -n "$_Jmax" && \
       -n "$_S1" && -n "$_S2" && -n "$_S3" && -n "$_S4" && \
       -n "$_H1" && -n "$_H2" && -n "$_H3" && -n "$_H4" ]] || return 1

    # Atomic export — environment is modified only on full success
    export AWG_Jc="$_Jc" AWG_Jmin="$_Jmin" AWG_Jmax="$_Jmax"
    export AWG_S1="$_S1" AWG_S2="$_S2" AWG_S3="$_S3" AWG_S4="$_S4"
    export AWG_H1="$_H1" AWG_H2="$_H2" AWG_H3="$_H3" AWG_H4="$_H4"
    [[ -n "$_I1"   ]] && export AWG_I1="$_I1"
    [[ -n "$_I2"   ]] && export AWG_I2="$_I2"
    [[ -n "$_I3"   ]] && export AWG_I3="$_I3"
    [[ -n "$_I4"   ]] && export AWG_I4="$_I4"
    [[ -n "$_I5"   ]] && export AWG_I5="$_I5"
    [[ -n "$_Port" ]] && export AWG_PORT="$_Port"
    if _validate_mtu "${_MTU:-}"; then
        export AWG_MTU="$_MTU"
    fi
    return 0
}

# Load AWG parameters.
#
# Source semantics (important for preventing split-brain between server
# and client configs, see #38):
#
#   * init file ($CONFIG_FILE = awgsetup_cfg.init) — for NON-AWG settings
#     (OS_ID, ALLOWED_IPS, AWG_PORT, AWG_ENDPOINT etc.). Always loaded
#     when present.
#   * Live server config ($SERVER_CONF_FILE = /etc/amnezia/amneziawg/awg0.conf)
#     — the SOLE source of truth for AWG protocol parameters
#     (Jc/Jmin/Jmax/S1-S4/H1-H4/I1-I5) when the file exists.
#
# If the live server config exists but does NOT contain a complete set of
# AWG parameters (corruption / incomplete manual edit) — the function
# returns 1 with an explicit error. Silently falling back to stale values
# from the init file would create split-brain: the server runs the new
# awg0.conf while regen would issue clients old J*/S*/H*. This is exactly
# the class of issue reported by elvaleto and Klavishnik in Discussion #38.
#
# The init file is used for AWG parameters ONLY when the live server
# config is missing entirely — that is the bootstrap path of the first
# install when awg0.conf has not been written yet but generate_awg_params
# has already stored values in the init file.
load_awg_params() {
    # 1. Base settings from init (always, for non-AWG keys)
    if [[ -f "$CONFIG_FILE" ]]; then
        safe_load_config "$CONFIG_FILE" || log_warn "Failed to load $CONFIG_FILE"
    fi

    # 2. AWG protocol parameters
    # If CLI specified --preset/--jc/--jmin/--jmax, params are already set via generate_awg_params.
    # Skip reload from awg0.conf to preserve the fresh values.
    if [[ -n "${CLI_PRESET:-}" || -n "${CLI_JC:-}" || -n "${CLI_JMIN:-}" || -n "${CLI_JMAX:-}" ]]; then
        log_debug "CLI overrides set — AWG params from generate_awg_params, not from $SERVER_CONF_FILE"
    elif [[ -f "$SERVER_CONF_FILE" ]]; then
        # Live config exists — it is the sole source of truth.
        # No fallback to init: that would create split-brain.
        # Unset I1-I5 before parsing: they are optional, if absent from live conf
        # they must not leak stale values from init file.
        unset AWG_I1 AWG_I2 AWG_I3 AWG_I4 AWG_I5
        if ! load_awg_params_from_server_conf; then
            log_error "$SERVER_CONF_FILE is missing required AWG parameters"
            log_error "(Jc/Jmin/Jmax/S1-S4/H1-H4). Refusing to use stale values from"
            log_error "$CONFIG_FILE, that would create a split-brain between server"
            log_error "and client configs. Restore the [Interface] section in"
            log_error "$SERVER_CONF_FILE or restore awg0.conf from a backup."
            return 1
        fi
        log_debug "AWG parameters loaded from $SERVER_CONF_FILE (live config)"
    else
        # Bootstrap: server config does not exist yet (first install).
        # AWG_* must be in env via safe_load_config above.
        log_debug "$SERVER_CONF_FILE missing — using AWG params from $CONFIG_FILE (bootstrap)"
    fi

    # 3. Check required AWG 2.0 parameters
    local missing=0
    local param
    for param in AWG_Jc AWG_Jmin AWG_Jmax AWG_S1 AWG_S2 AWG_S3 AWG_S4 AWG_H1 AWG_H2 AWG_H3 AWG_H4; do
        if [[ -z "${!param:-}" ]]; then
            log_error "Parameter $param not found"
            missing=1
        fi
    done
    if [[ $missing -eq 1 ]]; then
        return 1
    fi
    return 0
}

# ==============================================================================
# Key generation
# ==============================================================================

# Generate keypair (private + public)
# generate_keypair <name>
# Result: keys/<name>.private, keys/<name>.public
generate_keypair() {
    local name="$1"
    if [[ -z "$name" ]]; then
        log_error "generate_keypair: name not specified"
        return 1
    fi
    mkdir -p "$KEYS_DIR" || {
        log_error "Failed to create $KEYS_DIR"
        return 1
    }
    # 700 right at creation: mkdir -p with the default umask would give 755,
    # and until the installer's secure_files the keys directory would be
    # world-readable.
    chmod 700 "$KEYS_DIR"

    local privkey pubkey
    privkey=$(awg genkey) || {
        log_error "Failed to generate private key for '$name'"
        return 1
    }
    pubkey=$(echo "$privkey" | awg pubkey) || {
        log_error "Failed to generate public key for '$name'"
        return 1
    }

    # umask 077 in a subshell: the file is born 600 right away, no
    # world-readable window between write and chmod (with the default umask
    # 022 the key would briefly be 644).
    ( umask 077; echo "$privkey" > "$KEYS_DIR/${name}.private" ) || {
        log_error "Failed to write private key for '$name'"
        return 1
    }
    ( umask 077; echo "$pubkey" > "$KEYS_DIR/${name}.public" ) || {
        log_error "Failed to write public key for '$name'"
        return 1
    }
    chmod 600 "$KEYS_DIR/${name}.private" "$KEYS_DIR/${name}.public" || {
        log_error "Failed to set permissions on keys for '$name'"
        return 1
    }
    log_debug "Keys for '$name' generated."
    return 0
}

# Generate server keys
# Result: server_private.key, server_public.key in AWG_DIR
generate_server_keys() {
    local privkey pubkey
    privkey=$(awg genkey) || {
        log_error "Failed to generate server private key"
        return 1
    }
    pubkey=$(echo "$privkey" | awg pubkey) || {
        log_error "Failed to generate server public key"
        return 1
    }

    # umask 077: no world-readable window between write and chmod (see generate_keypair).
    ( umask 077; echo "$privkey" > "$AWG_DIR/server_private.key" ) || return 1
    ( umask 077; echo "$pubkey" > "$AWG_DIR/server_public.key" ) || return 1
    chmod 600 "$AWG_DIR/server_private.key" "$AWG_DIR/server_public.key" || {
        log_error "Failed to set permissions on server keys"
        return 1
    }
    log "Server keys generated."
    return 0
}

# Ensure $AWG_DIR/server_public.key is present.
# If missing — tries to reconstruct it from the PrivateKey in awg0.conf
# (useful for manual setups outside my installer, where the cached
# server pubkey from install step 6 does not exist). Returns 0 if the
# key is already there or has been reconstructed, 1 otherwise.
_ensure_server_public_key() {
    [[ -f "$AWG_DIR/server_public.key" ]] && return 0

    [[ -f "$SERVER_CONF_FILE" ]] || {
        log_error "Cannot reconstruct server_public.key — $SERVER_CONF_FILE is missing"
        return 1
    }
    local _srv_priv
    _srv_priv=$(awk '
        /^\[Interface\]/ {in_iface=1; next}
        in_iface && /^[ \t]*PrivateKey[ \t]*=/ {
            sub(/^[ \t]*PrivateKey[ \t]*=[ \t]*/, "")
            gsub(/[[:space:]]/, "")
            print
            exit
        }
        /^\[/ && !/^\[Interface\]/ {in_iface=0}
    ' "$SERVER_CONF_FILE")
    if [[ -z "$_srv_priv" ]]; then
        log_error "PrivateKey not found in $SERVER_CONF_FILE — cannot reconstruct server_public.key"
        return 1
    fi
    mkdir -p "$AWG_DIR"
    local _tmp
    _tmp=$(awg_mktemp "$AWG_DIR") || return 1
    if ! echo "$_srv_priv" | awg pubkey > "$_tmp"; then
        rm -f "$_tmp"
        log_error "awg pubkey failed to compute the public key"
        return 1
    fi
    if ! mv -f "$_tmp" "$AWG_DIR/server_public.key"; then
        rm -f "$_tmp"
        log_error "Failed to move to $AWG_DIR/server_public.key"
        return 1
    fi
    chmod 600 "$AWG_DIR/server_public.key" 2>/dev/null || true
    log "server_public.key reconstructed from awg0.conf PrivateKey."
    return 0
}

# ==============================================================================
# Config rendering
# ==============================================================================

# Derive the server IPv6 address (host ::1) from the tunnel subnet.
# Input: PREFIX::/MASK (e.g. fddd:2c4:2c4:2c4::/64).
# Output: PREFIX::1/MASK (e.g. fddd:2c4:2c4:2c4::1/64).
# Assumption: subnet always ends with ::/MASK (that is how the installer writes it).
# If no trailing ::/ is present I return the input unchanged (defensive fallback).
_derive_ipv6_server_addr() {
    local subnet="$1"
    if [[ "$subnet" == *"::/"* ]]; then
        echo "${subnet/::\//::1\/}"
    else
        echo "$subnet"
    fi
}

# Render server config for AWG 2.0
# render_server_config [peers_source_file]
# Uses global variables from load_awg_params()
# peers_source_file (optional): a file whose [Peer] blocks are carried over
# into the new config BEFORE the atomic mv (usually a backup of the live
# awg0.conf). Thanks to this the live config is never left peer-less even for
# an instant - a failure between render and a separate append would leave a
# peer-less file, and the next run of step 6 would back up that already
# peer-less file (losing all peers on --force reinstall).
# shellcheck disable=SC2154  # AWG_* vars loaded via load_awg_params -> source
render_server_config() {
    local peers_source="${1:-}"
    load_awg_params || return 1

    # --no-cps (issue #159): load_awg_params re-reads I1 from the live awg0.conf
    # on a reinstall. When NO_CPS=1 clear I1 intentionally, otherwise the server
    # config would silently restore CPS against the flag.
    if grep -qE '^[[:space:]]*(export[[:space:]]+)?NO_CPS=1' "$CONFIG_FILE" 2>/dev/null; then
        AWG_I1=''
    fi

    # Port for the NEW awg0.conf comes from the init file (the user's intent:
    # the --port flag or the previously saved port), NOT from the old awg0.conf
    # being overwritten. load_awg_params re-reads ListenPort from the live
    # config, so without this --port on --force would be silently ignored.
    # render_server_config is only called from install; client regen
    # (regenerate_client) takes its own path and is unaffected.
    local _init_port
    _init_port=$(grep -oP '^\s*export AWG_PORT=\K[0-9]+' "$CONFIG_FILE" 2>/dev/null | head -n1)
    [[ -n "$_init_port" ]] && AWG_PORT="$_init_port"

    local server_privkey
    if [[ -f "$AWG_DIR/server_private.key" ]]; then
        server_privkey=$(cat "$AWG_DIR/server_private.key")
    else
        log_error "Server private key not found: $AWG_DIR/server_private.key"
        return 1
    fi

    local nic
    nic=$(get_main_nic)
    if [[ -z "$nic" ]]; then
        log_error "Failed to detect network interface."
        log_error "Set it manually and re-run step 6: export AWG_MAIN_NIC=<iface>"
        log_error "Available interfaces: $(ip -br link 2>/dev/null | awk '$1!="lo"{printf "%s ", $1}')"
        return 1
    fi

    # IPv6-only egress: interface exists, but there is no IPv4 egress. The IPv4
    # tunnel (10.x) is NATed via MASQUERADE - on such a host IPv4 client traffic
    # will not leave (issue #166). Warn, do not block: peer-to-peer inside the
    # tunnel and the IPv6 tunnel (--allow-ipv6-tunnel) still work.
    if host_lacks_ipv4_egress "$nic"; then
        log_warn "Host appears to be IPv6-only: $nic has no IPv4 egress."
        log_warn "The VPN tunnels IPv4, so IPv4 client traffic will not leave the host."
        log_warn "A host with an IPv4 address (dual-stack) or NAT64 is required."
    fi

    local server_ip subnet_mask
    server_ip=$(echo "$AWG_TUNNEL_SUBNET" | cut -d'/' -f1)
    subnet_mask=$(echo "$AWG_TUNNEL_SUBNET" | cut -d'/' -f2)

    # [Interface] Address: IPv4 always, IPv6 only when the tunnel is enabled.
    # The server takes host ::1 in the tunnel IPv6 subnet.
    # IPV6_SUBNET has the form PREFIX::/MASK (default fddd:2c4:2c4:2c4::/64),
    # so I derive the server address by replacing trailing ::/MASK with ::1/MASK.
    local address_line="${server_ip}/${subnet_mask}"
    if [[ "${ALLOW_IPV6_TUNNEL:-0}" -eq 1 ]]; then
        local ipv6_subnet="${IPV6_SUBNET:-fddd:2c4:2c4:2c4::/64}"
        local ipv6_server_addr
        ipv6_server_addr=$(_derive_ipv6_server_addr "$ipv6_subnet")
        address_line="${address_line}, ${ipv6_server_addr}"
    fi

    local conf_dir
    conf_dir=$(dirname "$SERVER_CONF_FILE")
    mkdir -p "$conf_dir" || {
        log_error "Failed to create $conf_dir"
        return 1
    }

    # PostUp/PostDown rules for routing
    local postup="iptables -I FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${nic} -j MASQUERADE"
    local postdown="iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${nic} -j MASQUERADE"

    # MSS/PMTU clamp: pin the TCP MSS to the tunnel MTU so large segments do not
    # stall against the 1280 tunnel when ICMP "frag needed" is filtered (PMTU
    # blackhole: VPN connects but large pages/downloads hang on mobile/double-NAT/
    # cascade paths). A fixed MSS derived from AWG_MTU is deterministic with the
    # hard-set MTU and auto-syncs with it; clamp-to-pmtu would depend on the egress
    # route. Bidirectional (-o %i and -i %i) caps the MSS both ways. IPv4: MTU-40,
    # IPv6: MTU-60. SYN only, mangle table (separate from UFW/filter). The -A/-D
    # style mirrors the MASQUERADE rules above.
    local awg_mtu="${AWG_MTU:-1280}"
    local mss4=$(( awg_mtu - 40 ))
    local mss6=$(( awg_mtu - 60 ))
    postup="${postup}; iptables -t mangle -A FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss4}; iptables -t mangle -A FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss4}"
    postdown="${postdown}; iptables -t mangle -D FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss4}; iptables -t mangle -D FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss4}"

    # IPv6 rules: enabled when the IPv6 tunnel is on (FORWARD inside the tunnel +
    # MASQUERADE to the public interface). MASQUERADE is harmless without native
    # IPv6 on the VPS - it is a no-op while there is no IPv6 default route, while
    # peer-to-peer traffic inside the tunnel still works. I reuse the same nic as
    # the IPv4 MASQUERADE (no hardcoded interface).
    # The DISABLE_IPV6=0 condition is kept for byte-identical compatibility with v5.14.x:
    # an install with --allow-ipv6 (no tunnel) gets the same IPv6 filter rules as before.
    if [[ "${ALLOW_IPV6_TUNNEL:-0}" -eq 1 || "${DISABLE_IPV6:-1}" -eq 0 ]]; then
        postup="${postup}; ip6tables -I FORWARD -i %i -j ACCEPT; ip6tables -t nat -A POSTROUTING -o ${nic} -j MASQUERADE; ip6tables -t mangle -A FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss6}; ip6tables -t mangle -A FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss6}"
        postdown="${postdown}; ip6tables -D FORWARD -i %i -j ACCEPT; ip6tables -t nat -D POSTROUTING -o ${nic} -j MASQUERADE; ip6tables -t mangle -D FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss6}; ip6tables -t mangle -D FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss6}"
    fi

    # Build config via temp file (atomic write).
    # Create temp in the target config's directory so mv is an atomic rename on
    # the same filesystem (not a cross-fs copy+unlink when /tmp is tmpfs).
    local tmpfile
    tmpfile=$(awg_mktemp "$(dirname "$SERVER_CONF_FILE")") || { log_error "mktemp failed"; return 1; }

    cat > "$tmpfile" << EOF
[Interface]
PrivateKey = ${server_privkey}
Address = ${address_line}
MTU = ${AWG_MTU:-1280}
ListenPort = ${AWG_PORT}
PostUp = ${postup}
PostDown = ${postdown}
Jc = ${AWG_Jc}
Jmin = ${AWG_Jmin}
Jmax = ${AWG_Jmax}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
S3 = ${AWG_S3}
S4 = ${AWG_S4}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}
EOF

    # Add I1-I5 only if set (CPS params are optional).
    # I2-I5 are set by the admin manually in awg0.conf (issue #71), copied as-is.
    [[ -n "${AWG_I1:-}" ]] && echo "I1 = ${AWG_I1}" >> "$tmpfile"
    [[ -n "${AWG_I2:-}" ]] && echo "I2 = ${AWG_I2}" >> "$tmpfile"
    [[ -n "${AWG_I3:-}" ]] && echo "I3 = ${AWG_I3}" >> "$tmpfile"
    [[ -n "${AWG_I4:-}" ]] && echo "I4 = ${AWG_I4}" >> "$tmpfile"
    [[ -n "${AWG_I5:-}" ]] && echo "I5 = ${AWG_I5}" >> "$tmpfile"

    # Carry [Peer] blocks from peers_source into the temp BEFORE mv (see doc comment).
    # The buffer is flushed on every new [Peer]: ALL blocks are carried over.
    if [[ -n "$peers_source" && -f "$peers_source" ]]; then
        local _peers
        _peers=$(awk '
            /^\[Peer\]/ { if (in_peer) printf "%s", buf; buf=$0"\n"; in_peer=1; next }
            in_peer && /^\[/ { printf "%s", buf; buf=""; in_peer=0; next }
            in_peer { buf=buf $0"\n"; next }
            END { if (in_peer) printf "%s", buf }
        ' "$peers_source")
        if [[ -n "$_peers" ]]; then
            printf '\n%s' "$_peers" >> "$tmpfile" || {
                rm -f "$tmpfile"
                log_error "Failed to carry [Peer] blocks into the new config"
                return 1
            }
        fi
    fi

    if ! mv "$tmpfile" "$SERVER_CONF_FILE"; then
        rm -f "$tmpfile"
        log_error "Failed to write server config"
        return 1
    fi
    chmod 600 "$SERVER_CONF_FILE"
    log "Server config created: $SERVER_CONF_FILE"
    return 0
}

# Acceptable MTU range for AWG / WireGuard.
# Lower bound 576 (classic IPv4 minimum), upper bound 9100 (just under jumbo).
# Values outside the range are treated as invalid and dropped (fallback to 1280).
_validate_mtu() {
    local v="$1"
    [[ "$v" =~ ^[0-9]+$ ]] || return 1
    (( v >= 576 && v <= 9100 )) || return 1
    return 0
}

# Extract MTU from the [Interface] section of server awg0.conf (if the file
# exists). Prints the integer on stdout, or nothing if MTU is missing or the
# file is unreadable. Last-wins: if [Interface] holds several MTU = ... lines,
# the last one is returned (matching the way awg-quick applies the final
# assignment). Used by render_client_config to sync the client MTU with the
# server (v5.14.0 bug: manual MTU edit in awg0.conf was not picked up by regen).
_extract_mtu_from_server_conf() {
    local conf="${SERVER_CONF_FILE:-/etc/amnezia/amneziawg/awg0.conf}"
    [[ -r "$conf" ]] || return 1
    local val
    val=$(awk '
        /^\[Interface\]/ {in_iface=1; next}
        /^\[/ {in_iface=0}
        in_iface && /^[[:space:]]*MTU[[:space:]]*=/ {
            gsub(/^[[:space:]]*MTU[[:space:]]*=[[:space:]]*/, "")
            gsub(/[[:space:]].*$/, "")
            if ($0 ~ /^[0-9]+$/) { mtu=$0 }
        }
        END { if (mtu != "") print mtu }
    ' "$conf")
    _validate_mtu "$val" || return 1
    echo "$val"
}

# Render client config for AWG 2.0
# render_client_config <name> <client_ip> <client_privkey> <server_pubkey> <endpoint> <port> [client_ipv6]
#
# client_ipv6 (optional 7th argument): client IPv6 address without prefix
# length (e.g. fddd:2c4:2c4:2c4::5). If non-empty and ALLOW_IPV6_TUNNEL=1:
#   - Address = <ipv4>/32, <ipv6>/128
#   - AllowedIPs (mirror the IPv4 routing mode into IPv6, intent-mirroring):
#       full tunnel (ALLOWED_IPS=0.0.0.0/0): + ::/0 (native) or + <IPV6_SUBNET> (no-native)
#       split tunnel (custom ALLOWED_IPS):   IPv4 list UNCHANGED + ONLY <IPV6_SUBNET>,
#         NEVER ::/0 - there is no IPv6 split-list, hijacking all IPv6 breaks split-tunnel.
# If empty (legacy client): Address = <ipv4>/32, AllowedIPs unchanged.
render_client_config() {
    local name="$1"
    local client_ip="$2"
    local client_privkey="$3"
    local server_pubkey="$4"
    local endpoint="$5"
    local port="$6"
    local client_ipv6="${7:-}"

    load_awg_params || return 1

    local conf_file="$AWG_DIR/${name}.conf"
    local allowed_ips
    if [[ -n "$client_ipv6" ]]; then
        # Dual-stack: mirror the IPv4 routing intent into IPv6.
        # full tunnel (IPv4=0.0.0.0/0) -> ::/0 (native) or tunnel ULA (no-native).
        # split tunnel (custom ALLOWED_IPS) -> IPv4 split AS-IS + ONLY tunnel ULA,
        # never ::/0 (no IPv6 split-list, must not hijack all IPv6).
        local ipv4_part ipv6_part
        ipv4_part="${ALLOWED_IPS:-0.0.0.0/0}"
        if [[ "$ipv4_part" == "0.0.0.0/0" && "${SERVER_HAS_NATIVE_IPV6:-0}" == "1" ]]; then
            ipv6_part="::/0"
        else
            ipv6_part="${IPV6_SUBNET:-fddd:2c4:2c4:2c4::/64}"
        fi
        # Defensive de-dup: ALLOWED_IPS is IPv4-only by construction, but do not
        # duplicate ipv6_part if it is already present as a token in the list.
        case ",${ipv4_part// /}," in
            *",${ipv6_part},"*) allowed_ips="$ipv4_part" ;;
            *)                  allowed_ips="${ipv4_part}, ${ipv6_part}" ;;
        esac
    else
        allowed_ips="${ALLOWED_IPS:-0.0.0.0/0}"
        # iOS AmneziaVPN in "all traffic" mode requires both address families:
        # with a bare 0.0.0.0/0 it treats the config as incomplete split routing
        # and refuses to bring the tunnel up. For full tunnel we add ::/0 - IPv6
        # goes into the tunnel (and is dropped if the server has no native IPv6),
        # so it never leaks past the VPN. Affects mode-1 only: split mode uses a
        # custom list that is not equal to 0.0.0.0/0 and skips this branch.
        if [[ "$allowed_ips" == "0.0.0.0/0" ]]; then
            allowed_ips="0.0.0.0/0, ::/0"
        fi
    fi

    # MTU resolution order: server awg0.conf > AWG_MTU from awgsetup_cfg.init >
    # 1280 fallback. Server config is the source of truth for a running server -
    # the user could have hand-edited MTU in /etc/amnezia/amneziawg/awg0.conf
    # and regen has to pick that up (MyAI-sdge, Discussion #38). Out-of-range
    # values (outside 576..9100) at any stage roll back to 1280.
    local mtu
    mtu=$(_extract_mtu_from_server_conf) || mtu=""
    if [[ -z "$mtu" ]]; then
        if _validate_mtu "${AWG_MTU:-}"; then
            mtu="$AWG_MTU"
        else
            mtu=1280
        fi
    fi

    # temp in the client config dir ($AWG_DIR) -> mv = atomic rename.
    local tmpfile
    tmpfile=$(awg_mktemp "$AWG_DIR") || { log_error "mktemp failed"; return 1; }

    local address_line
    if [[ -n "$client_ipv6" ]]; then
        address_line="${client_ip}/32, ${client_ipv6}/128"
    else
        address_line="${client_ip}/32"
    fi

    cat > "$tmpfile" << EOF
[Interface]
PrivateKey = ${client_privkey}
Address = ${address_line}
DNS = 1.1.1.1, 1.0.0.1
MTU = ${mtu}
Jc = ${AWG_Jc}
Jmin = ${AWG_Jmin}
Jmax = ${AWG_Jmax}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
S3 = ${AWG_S3}
S4 = ${AWG_S4}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}
EOF

    # I1-I5: copy the set CPS params into the client config (issue #71).
    # Values must match the server side - regen distributes them to clients.
    [[ -n "${AWG_I1:-}" ]] && echo "I1 = ${AWG_I1}" >> "$tmpfile"
    [[ -n "${AWG_I2:-}" ]] && echo "I2 = ${AWG_I2}" >> "$tmpfile"
    [[ -n "${AWG_I3:-}" ]] && echo "I3 = ${AWG_I3}" >> "$tmpfile"
    [[ -n "${AWG_I4:-}" ]] && echo "I4 = ${AWG_I4}" >> "$tmpfile"
    [[ -n "${AWG_I5:-}" ]] && echo "I5 = ${AWG_I5}" >> "$tmpfile"

    cat >> "$tmpfile" << EOF

[Peer]
PublicKey = ${server_pubkey}
EOF
    # Optional PresharedKey — extra layer on top of AWG 2.0 obfuscation
    # (enabled via `manage add --psk`). Must match on server peer and
    # client [Peer].
    if [[ -n "${CLIENT_PSK:-}" ]]; then
        echo "PresharedKey = ${CLIENT_PSK}" >> "$tmpfile"
    fi
    cat >> "$tmpfile" << EOF
Endpoint = ${endpoint}:${port}
AllowedIPs = ${allowed_ips}
PersistentKeepalive = 33
EOF

    if ! mv "$tmpfile" "$conf_file"; then
        rm -f "$tmpfile"
        log_error "Failed to write config for client '$name'"
        return 1
    fi
    chmod 600 "$conf_file"
    log_debug "Config for '$name' created: $conf_file"
    return 0
}

# ==============================================================================
# Config application (syncconf)
# ==============================================================================

# Apply configuration changes
# AWG_SKIP_APPLY=1: skip apply (for batch automation)
# AWG_APPLY_MODE=syncconf|restart: apply method (config or --apply-mode CLI)
# flock on .awg_apply.lock: prevents concurrent apply calls
apply_config() {
    # Skip apply (AWG_SKIP_APPLY=1 manage add/remove ...)
    if [[ "${AWG_SKIP_APPLY:-0}" == "1" ]]; then
        log_debug "apply_config skipped (AWG_SKIP_APPLY=1)."
        return 0
    fi

    # Inter-process lock for apply_config
    local apply_lockfile="${AWG_DIR}/.awg_apply.lock"
    local apply_fd
    exec {apply_fd}>"$apply_lockfile"
    if ! flock -x -w 120 "$apply_fd"; then
        log_warn "Failed to acquire apply_config lock."
        exec {apply_fd}>&-
        return 1
    fi

    local rc=0

    if [[ "${AWG_APPLY_MODE:-syncconf}" == "restart" ]]; then
        log "Restarting service (apply-mode=restart)..."
        systemctl restart awg-quick@awg0 2>/dev/null; rc=$?
        [[ $rc -ne 0 ]] && log_warn "Service restart error."
        exec {apply_fd}>&-
        return $rc
    fi

    local strip_out
    strip_out=$(timeout 10 awg-quick strip awg0 2>/dev/null) || {
        log_warn "awg-quick strip failed or timed out, falling back to full restart."
        systemctl restart awg-quick@awg0 2>/dev/null; rc=$?
        [[ $rc -ne 0 ]] && log_warn "Service restart error."
        exec {apply_fd}>&-
        return $rc
    }
    echo "$strip_out" | timeout 10 awg syncconf awg0 /dev/stdin 2>/dev/null || {
        log_warn "awg syncconf failed or timed out, falling back to full restart."
        systemctl restart awg-quick@awg0 2>/dev/null; rc=$?
        [[ $rc -ne 0 ]] && log_warn "Service restart error."
        exec {apply_fd}>&-
        return $rc
    }
    log_debug "Config applied (syncconf)."
    exec {apply_fd}>&-
    return 0
}

# ==============================================================================
# Peer management
# ==============================================================================

# Get the next free IP in the subnet (arbitrary /16-/30 mask). Server = network+1;
# host range is [network+1 .. broadcast-1]. Returns the lowest free address
# (early exit) - up to 65534 slots for /16, but no full scan in the common case.
get_next_client_ip() {
    local subnet="${AWG_TUNNEL_SUBNET:-10.9.9.1/24}"
    local net_int bcast_int
    read -r net_int bcast_int < <(_cidr_bounds "$subnet") || {
        log_error "get_next_client_ip: could not parse subnet '$subnet'"
        return 1
    }
    local server_int=$(( net_int + 1 ))

    # Associative array for O(1) lookup. Server (network+1) is taken.
    declare -A used_set
    used_set["$(_int_to_ipv4 "$server_int")"]=1
    if [[ -f "$SERVER_CONF_FILE" ]]; then
        while IFS= read -r ip; do
            used_set["$ip"]=1
        done < <(grep -oP 'AllowedIPs\s*=\s*\K[0-9.]+' "$SERVER_CONF_FILE")
    fi

    local i candidate
    for (( i = net_int + 1; i <= bcast_int - 1; i++ )); do
        candidate=$(_int_to_ipv4 "$i")
        if [[ -z "${used_set[$candidate]+x}" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    log_error "No free IPs in subnet ${subnet}"
    return 1
}

# Derive the client IPv6 from its IPv4. Used only when ALLOW_IPV6_TUNNEL=1.
# Index = host offset in the subnet (offset = ipv4 - network), which is unique
# for any mask. Suffix encoding depends on the mask:
#   prefix == 24 -> decimal offset (== last octet; byte-identical to before),
#   otherwise    -> proper hex (printf '%x').
# The server (network+1, offset 1) yields "1" in both modes -> ::1 (see
# _derive_ipv6_server_addr, unchanged). Clients have offset >= 2.
# Returns the address string without a prefix length.
#
# get_next_client_ipv6 <ipv4_addr>
get_next_client_ipv6() {
    local ipv4="$1"
    if [[ -z "$ipv4" ]]; then
        log_error "get_next_client_ipv6: no IPv4 address supplied"
        return 1
    fi
    local tunnel="${AWG_TUNNEL_SUBNET:-10.9.9.1/24}"
    local tprefix="${tunnel##*/}"
    local net_int bcast_int ip_int offset suffix
    read -r net_int bcast_int < <(_cidr_bounds "$tunnel") || {
        log_error "get_next_client_ipv6: could not parse subnet '$tunnel'"
        return 1
    }
    ip_int=$(_ipv4_to_int "$ipv4") || {
        log_error "get_next_client_ipv6: invalid IPv4 '$ipv4'"
        return 1
    }
    offset=$(( ip_int - net_int ))
    (( offset >= 1 && offset < bcast_int - net_int )) || { log_error "get_next_client_ipv6: IPv4 '$ipv4' outside subnet '$tunnel'"; return 1; }
    if [[ "$tprefix" == "24" ]]; then
        suffix="$offset"
    else
        suffix=$(printf '%x' "$offset")
    fi
    local subnet="${IPV6_SUBNET:-fddd:2c4:2c4:2c4::/64}"
    local prefix="${subnet%%::*}"
    [[ "$prefix" == *:* ]] || { log_error "get_next_client_ipv6: IPV6_SUBNET does not contain :: (value: $subnet)"; return 1; }
    echo "${prefix}::${suffix}"
    return 0
}

# [Peer] addition to server config (atomic via tmpfile + mv).
#
# LOCKING CONTRACT: the caller MUST hold an exclusive flock on
# ${AWG_DIR}/.awg_config.lock when invoking this function. The lock is
# acquired by generate_client() — the only current caller. Do not call
# add_peer_to_server directly without holding the lock.
#
# Why an inner flock is not possible here: bash flock is not re-entrant
# across different file descriptors on the same file. generate_client()
# opens .awg_config.lock on its own fd and holds an exclusive lock; an
# attempt to open the same file on a new fd inside add_peer_to_server
# and take an exclusive lock there would self-deadlock (the parent lock
# is seen as foreign). Contract-based locking is the only reliable
# option in this situation. Re-entrant behaviour is possible only if
# the sub-function uses the SAME fd as the parent (via inheritance),
# which would require passing the fd as an argument.
#
# add_peer_to_server <name> <pubkey> <client_ip> [client_ipv6]
#
# client_ipv6 (optional 4th argument): IPv6 address without prefix length.
# If non-empty: AllowedIPs = <ipv4>/32, <ipv6>/128
# If empty (legacy): AllowedIPs = <ipv4>/32
add_peer_to_server() {
    local name="$1"
    local pubkey="$2"
    local client_ip="$3"
    local client_ipv6="${4:-}"

    if [[ -z "$name" || -z "$pubkey" || -z "$client_ip" ]]; then
        log_error "add_peer_to_server: insufficient arguments"
        return 1
    fi
    # The name goes into the config heredoc (#_Name = ...): a newline in the
    # name would inject a [Peer] section. Defense-in-depth, see generate_client.
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "add_peer_to_server: invalid client name '$name'"
        return 1
    fi

    if grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE" 2>/dev/null; then
        log_error "Peer '$name' already exists in config"
        return 1
    fi

    # Add peer via temp file (atomic).
    # temp in the server config dir -> mv = atomic rename on the same filesystem.
    local tmpfile
    tmpfile=$(awg_mktemp "$(dirname "$SERVER_CONF_FILE")") || { log_error "mktemp failed"; return 1; }

    cp "$SERVER_CONF_FILE" "$tmpfile" || {
        rm -f "$tmpfile"
        log_error "Failed to copy server config"
        return 1
    }

    cat >> "$tmpfile" << EOF

[Peer]
#_Name = ${name}
PublicKey = ${pubkey}
EOF
    # PresharedKey — optional, written if passed via CLIENT_PSK env.
    # Must match the server peer and client [Peer].
    if [[ -n "${CLIENT_PSK:-}" ]]; then
        echo "PresharedKey = ${CLIENT_PSK}" >> "$tmpfile"
    fi
    if [[ -n "$client_ipv6" ]]; then
        echo "AllowedIPs = ${client_ip}/32, ${client_ipv6}/128" >> "$tmpfile"
    else
        echo "AllowedIPs = ${client_ip}/32" >> "$tmpfile"
    fi

    if ! mv "$tmpfile" "$SERVER_CONF_FILE"; then
        rm -f "$tmpfile"
        log_error "Failed to update server config"
        return 1
    fi
    chmod 600 "$SERVER_CONF_FILE"
    log "Peer '$name' added to server config."
    return 0
}

# Remove [Peer] from server config by name (with locking)
# remove_peer_from_server <name>
remove_peer_from_server() {
    local name="$1"

    if [[ -z "$name" ]]; then
        log_error "remove_peer_from_server: name not specified"
        return 1
    fi
    # Defense-in-depth: same contract as in add_peer_to_server.
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "remove_peer_from_server: invalid client name '$name'"
        return 1
    fi

    # Inter-process lock
    local lockfile="${AWG_DIR}/.awg_config.lock"
    local lock_fd
    exec {lock_fd}>"$lockfile"
    if ! flock -x -w 10 "$lock_fd"; then
        log_error "Failed to acquire config lock"
        exec {lock_fd}>&-
        return 1
    fi

    if ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE" 2>/dev/null; then
        log_error "Peer '$name' not found in config"
        exec {lock_fd}>&-
        return 1
    fi

    # temp in the server config dir -> the final mv is an atomic rename.
    local tmpfile
    tmpfile=$(awg_mktemp "$(dirname "$SERVER_CONF_FILE")") || { log_error "mktemp failed"; exec {lock_fd}>&-; return 1; }

    # Remove [Peer] block containing #_Name = name
    # Logic: buffer each [Peer] block, check name, print only if not matching
    awk -v target="$name" '
    BEGIN { buf=""; is_target=0 }
    /^\[Peer\]/ {
        # Print previous buffer if not target
        if (buf != "" && !is_target) printf "%s", buf
        buf = $0 "\n"
        is_target = 0
        next
    }
    /^\[/ && !/^\[Peer\]/ {
        # Any other section — flush buffer
        if (buf != "" && !is_target) printf "%s", buf
        buf = ""
        is_target = 0
        print
        next
    }
    {
        if (buf != "") {
            buf = buf $0 "\n"
            if ($0 == "#_Name = " target) is_target = 1
        } else {
            print
        }
    }
    END {
        if (buf != "" && !is_target) printf "%s", buf
    }
    ' "$SERVER_CONF_FILE" > "$tmpfile" || {
        log_error "Failed to filter the server config (awk)"
        rm -f "$tmpfile"
        exec {lock_fd}>&-
        return 1
    }

    # Sanity-check BEFORE mv: on ENOSPC/I/O failure awk would leave an
    # empty/truncated tmpfile, and the atomic mv would replace a working
    # config with a broken one (losing the server PrivateKey and all peers).
    # [Interface] must survive.
    if ! grep -q '^\[Interface\]' "$tmpfile"; then
        log_error "Peer removal result looks corrupt ([Interface] is missing) - config left unchanged"
        rm -f "$tmpfile"
        exec {lock_fd}>&-
        return 1
    fi

    # Normalize: squeeze multiple blank lines into one.
    # tmpclean lives on the same filesystem as tmpfile (mv tmpclean->tmpfile atomic).
    local tmpclean
    tmpclean=$(awg_mktemp "$(dirname "$SERVER_CONF_FILE")") || { log_error "mktemp failed"; exec {lock_fd}>&-; return 1; }
    if cat -s "$tmpfile" > "$tmpclean" 2>/dev/null; then
        mv "$tmpclean" "$tmpfile"
    else
        rm -f "$tmpclean"
    fi

    if ! mv "$tmpfile" "$SERVER_CONF_FILE"; then
        rm -f "$tmpfile"
        log_error "Failed to update server config"
        exec {lock_fd}>&-
        return 1
    fi
    chmod 600 "$SERVER_CONF_FILE"
    exec {lock_fd}>&-
    log "Peer '$name' removed from server config."
    return 0
}

# ==============================================================================
# Full client lifecycle
# ==============================================================================

# Generate QR code for client
# generate_qr <name>
generate_qr() {
    local name="$1"
    local conf_file="$AWG_DIR/${name}.conf"
    local png_file="$AWG_DIR/${name}.png"

    if [[ ! -f "$conf_file" ]]; then
        log_error "Client config '$name' not found: $conf_file"
        return 1
    fi

    if ! command -v qrencode &>/dev/null; then
        log_warn "qrencode is not installed, QR code not created for '$name'."
        return 1
    fi

    # C4: generate into a temp file and move it into place atomically, so an
    # interrupted qrencode cannot leave a partial/corrupt PNG over the working one.
    # awg_mktemp "$AWG_DIR" puts the tmp in the same directory (mv = atomic rename
    # on one filesystem) AND registers it in the shared cleanup registry, so a
    # SIGKILL between qrencode and mv leaves no orphan tmp.
    local tmp_png
    tmp_png=$(awg_mktemp "$AWG_DIR") || { log_error "mktemp error for QR '$name'"; return 1; }
    if ! qrencode -t png -o "$tmp_png" < "$conf_file"; then
        log_error "Failed to generate QR code for '$name'"
        rm -f "$tmp_png"
        return 1
    fi
    chmod 600 "$tmp_png" 2>/dev/null
    if ! mv -f "$tmp_png" "$png_file"; then
        log_error "Failed to save QR code for '$name'"
        rm -f "$tmp_png"
        return 1
    fi
    log_debug "QR code for '$name' created: $png_file"
    return 0
}

# Generate vpn:// URI for import into Amnezia Client
# generate_vpn_uri <name>
generate_vpn_uri() {
    local name="$1"
    local conf_file="$AWG_DIR/${name}.conf"
    local uri_file="$AWG_DIR/${name}.vpnuri"

    if [[ ! -f "$conf_file" ]]; then
        log_error "Client config '$name' not found: $conf_file"
        return 1
    fi

    if ! command -v perl &>/dev/null; then
        log_warn "perl not found, vpn:// URI not created for '$name'."
        return 1
    fi

    if ! perl -MCompress::Zlib -MMIME::Base64 -e '1' 2>/dev/null; then
        log_warn "Perl modules Compress::Zlib/MIME::Base64 not found, vpn:// URI not created."
        return 1
    fi

    load_awg_params || return 1

    # AWG_PORT is the only UNquoted numeric field of the inner JSON ("port":N).
    # An empty/non-numeric value would produce "port":, - syntactically broken
    # JSON, which Amnezia Client silently fails to import.
    if ! [[ "${AWG_PORT:-}" =~ ^[0-9]+$ ]]; then
        log_warn "AWG_PORT is unset or not a number ('${AWG_PORT:-}') - vpn:// URI not created for '$name'."
        return 1
    fi

    local client_privkey client_ip client_ipv6 server_pubkey endpoint allowed_ips client_psk
    client_privkey=$(grep -oP 'PrivateKey\s*=\s*\K\S+' "$conf_file") || return 1
    # Extract IPv4 from Address (first field before comma, without /prefix).
    # Regex stops at digits and dots - does not capture IPv6 in dual-stack configs.
    client_ip=$(awk '/^Address[[:space:]]*=/{
        sub(/^Address[[:space:]]*=[[:space:]]*/, "")
        sub(/\r$/, "")
        n = split($0, parts, /[[:space:]]*,[[:space:]]*/)
        sub(/\/[0-9]+$/, "", parts[1])
        print parts[1]; exit
    }' "$conf_file") || return 1
    # Extract IPv6 from Address (second field, if present), without /prefix.
    client_ipv6=$(awk '/^Address[[:space:]]*=/{
        sub(/^Address[[:space:]]*=[[:space:]]*/, "")
        sub(/\r$/, "")
        n = split($0, parts, /[[:space:]]*,[[:space:]]*/)
        if (n >= 2) {
            sub(/\/[0-9]+$/, "", parts[2])
            gsub(/[[:space:]]/, "", parts[2])
            print parts[2]
        }
        exit
    }' "$conf_file" 2>/dev/null)
    client_ipv6="${client_ipv6:-}"
    _ensure_server_public_key || return 1
    server_pubkey=$(cat "$AWG_DIR/server_public.key" 2>/dev/null) || return 1
    # PresharedKey is optional. awk instead of grep so an empty result is not
    # treated as failure (grep -P without a match → rc=1, not what we want here).
    # Also strip a trailing CR (CRLF from Windows editors) and trailing spaces
    # — leaking them into the JSON psk_key would break the handshake just as
    # cleanly as the missing field. Without psk_key in inner JSON AmneziaVPN
    # import via vpn:// loses the PSK and the handshake fails (issue #67,
    # fix v5.11.4).
    client_psk=$(awk '/^[[:space:]]*PresharedKey[[:space:]]*=/{sub(/^[[:space:]]*PresharedKey[[:space:]]*=[[:space:]]*/, ""); sub(/\r$/, ""); sub(/[ \t]+$/, ""); print; exit}' "$conf_file" 2>/dev/null)
    local raw_endpoint
    raw_endpoint=$(grep -oP 'Endpoint\s*=\s*\K\S+' "$conf_file") || return 1
    if [[ "$raw_endpoint" == \[* ]]; then
        # IPv6: [addr]:port
        endpoint="${raw_endpoint%%]:*}"
        endpoint="${endpoint#\[}"
    else
        # IPv4/hostname: addr:port
        endpoint="${raw_endpoint%:*}"
    fi
    # tr -d ' \r' - strips spaces AND CR (on CRLF configs '.+' greedily
    # captures \r into the value, which breaks JSON.allowed_ips).
    allowed_ips=$(grep -oP 'AllowedIPs\s*=\s*\K.+' "$conf_file" | tr -d ' \r') || allowed_ips="0.0.0.0/0"

    # MTU/PersistentKeepalive/DNS from .conf - these can be changed via manage modify.
    # On vpn:// import the Amnezia client uses the structured inner-JSON fields
    # (awgConfigurator takes mtu from the structured field, not the embedded config),
    # so hardcoding them would desync from .conf - same class as issue #67 (the
    # structured psk_key field was authoritative).
    local mtu keepalive dns_line dns1 dns2
    mtu=$(grep -oP '^MTU\s*=\s*\K[0-9]+' "$conf_file" | head -n1); mtu="${mtu:-1280}"
    keepalive=$(grep -oP '^PersistentKeepalive\s*=\s*\K[0-9]+' "$conf_file" | head -n1); keepalive="${keepalive:-33}"
    dns_line=$(grep -oP '^DNS\s*=\s*\K.+' "$conf_file" | head -n1 | tr -d ' \r')
    dns1="${dns_line%%,*}"; dns1="${dns1:-1.1.1.1}"
    if [[ "$dns_line" == *,* ]]; then dns2="${dns_line#*,}"; dns2="${dns2%%,*}"; else dns2="$dns1"; fi

    local vpn_uri perl_err
    perl_err=$(awg_mktemp "$AWG_DIR") || { log_warn "mktemp failed - vpn:// URI not created for '$name'."; return 1; }
    # Secrets (client privkey, PSK) are passed to perl via env, NOT via argv:
    # the process command line is visible to all users in /proc/<pid>/cmdline
    # while perl runs. server_pubkey is not a secret but travels with the group.
    # shellcheck disable=SC2016
    vpn_uri=$(AWG_URI_CPK="$client_privkey" AWG_URI_PSK="$client_psk" AWG_URI_SPK="$server_pubkey" \
      perl -MCompress::Zlib -MMIME::Base64 -e '
        my ($conf_path, $h1,$h2,$h3,$h4, $jc,$jmin,$jmax,
            $s1,$s2,$s3,$s4, $i1,$i2,$i3,$i4,$i5, $port, $ep, $cip, $cipv6, $aips,
            $mtu, $keepalive, $dns1, $dns2) = @ARGV;
        my $cpk = $ENV{AWG_URI_CPK} // "";
        my $psk = $ENV{AWG_URI_PSK} // "";
        my $spk = $ENV{AWG_URI_SPK} // "";

        open my $fh, "<", $conf_path or die;
        local $/; my $raw = <$fh>; close $fh;
        chomp $raw;

        sub je {
            my $s = shift;
            $s =~ s/\\/\\\\/g; $s =~ s/"/\\"/g;
            $s =~ s/\n/\\n/g;  $s =~ s/\r/\\r/g;
            $s =~ s/\t/\\t/g;  return $s;
        }

        my $inner = "{";
        $inner .= qq("H1":"$h1","H2":"$h2","H3":"$h3","H4":"$h4",);
        $inner .= qq("Jc":"$jc","Jmin":"$jmin","Jmax":"$jmax",);
        $inner .= qq("S1":"$s1","S2":"$s2","S3":"$s3","S4":"$s4",);
        if ($i1 ne "" || $i2 ne "" || $i3 ne "" || $i4 ne "" || $i5 ne "") {
            my $ei1 = je($i1); my $ei2 = je($i2); my $ei3 = je($i3);
            my $ei4 = je($i4); my $ei5 = je($i5);
            $inner .= qq("I1":"$ei1","I2":"$ei2","I3":"$ei3","I4":"$ei4","I5":"$ei5",);
        }
        my $eraw = je($raw);
        my @ips = split(/,/, $aips);
        my $ips_json = join(",", map { qq("$_") } @ips);
        $inner .= qq("allowed_ips":[$ips_json],);
        $inner .= qq("client_ip":"$cip",);
        $cipv6 //= "";
        $inner .= qq("client_ipv6":"$cipv6",);
        $inner .= qq("client_priv_key":"$cpk",);
        if (defined $psk && $psk ne "") {
            my $epsk = je($psk);
            $inner .= qq("psk_key":"$epsk",);
        }
        $inner .= qq("config":"$eraw",);
        $inner .= qq("hostName":"$ep","mtu":"$mtu",);
        $inner .= qq("persistent_keep_alive":"$keepalive","port":$port,);
        $inner .= qq("server_pub_key":"$spk"});

        my $einner = je($inner);
        my $outer = "{";
        $outer .= qq("containers":[{"awg":{"isThirdPartyConfig":true,);
        $outer .= qq("last_config":"$einner",);
        $outer .= qq("port":"$port","protocol_version":"2",);
        $outer .= qq("transport_proto":"udp"\},"container":"amnezia-awg"\}],);
        $outer .= qq("defaultContainer":"amnezia-awg",);
        $outer .= qq("description":"AWG Server",);
        my $ed1 = je($dns1); my $ed2 = je($dns2);
        $outer .= qq("dns1":"$ed1","dns2":"$ed2",);
        $outer .= qq("hostName":"$ep"});

        my $compressed = compress($outer);
        my $payload = pack("N", length($outer)) . $compressed;
        my $b64 = encode_base64($payload, "");
        $b64 =~ tr|+/|-_|;
        $b64 =~ s/=+$//;
        print "vpn://" . $b64;
    ' "$conf_file" \
        "$AWG_H1" "$AWG_H2" "$AWG_H3" "$AWG_H4" \
        "$AWG_Jc" "$AWG_Jmin" "$AWG_Jmax" \
        "$AWG_S1" "$AWG_S2" "$AWG_S3" "$AWG_S4" \
        "$AWG_I1" "${AWG_I2:-}" "${AWG_I3:-}" "${AWG_I4:-}" "${AWG_I5:-}" "$AWG_PORT" "$endpoint" \
        "$client_ip" "$client_ipv6" "$allowed_ips" \
        "$mtu" "$keepalive" "$dns1" "$dns2" 2>"$perl_err"
    )

    if [[ -z "$vpn_uri" ]]; then
        log_warn "Failed to generate vpn:// URI for '$name'."
        [[ -s "$perl_err" ]] && log_warn "Perl: $(cat "$perl_err")"
        rm -f "$perl_err"
        return 1
    fi
    rm -f "$perl_err"

    # Write via tmp + atomic mv (like .conf/.png) so an interrupted write never
    # leaves an empty/truncated .vpnuri on top of a working one.
    local _uri_tmp
    _uri_tmp=$(awg_mktemp "$AWG_DIR") || { log_error "mktemp error for vpn:// URI '$name'"; return 1; }
    printf '%s\n' "$vpn_uri" > "$_uri_tmp" || { rm -f "$_uri_tmp"; log_error "Error writing vpn:// URI for '$name'"; return 1; }
    chmod 600 "$_uri_tmp"
    if ! mv -f "$_uri_tmp" "$uri_file"; then
        rm -f "$_uri_tmp"
        log_error "Error saving vpn:// URI for '$name'"
        return 1
    fi
    log_debug "vpn:// URI for '$name' created: $uri_file"
    return 0
}

# Generate QR code from vpn:// URI (for one-tap import into Amnezia VPN app Android/iOS/Desktop)
# generate_qr_vpnuri <name>
#
# Writes via a temp file in the same directory + atomic mv so that on
# qrencode or chmod failure the user never sees a truncated `.vpnuri.png`:
# the previous version stays intact and the new one only appears whole.
generate_qr_vpnuri() {
    local name="$1"
    local uri_file="$AWG_DIR/${name}.vpnuri"
    local png_file="$AWG_DIR/${name}.vpnuri.png"
    local tmp_png

    if [[ ! -f "$uri_file" ]]; then
        log_error "vpn:// URI for '$name' not found: $uri_file"
        return 1
    fi

    if ! command -v qrencode &>/dev/null; then
        log_warn "qrencode is not installed, vpn:// QR not created for '$name'."
        return 1
    fi

    # tmp via awg_mktemp (shared cleanup registry + atomic mv on the same FS).
    tmp_png=$(awg_mktemp "$AWG_DIR") || { log_error "mktemp error for vpn:// QR '$name'"; return 1; }

    # qrencode flags for long vpn:// URIs with PSK (issue #72):
    #   -8    single 8-bit byte mode. Without it qrencode's optimizer splits the
    #         base64 URI into alternating alnum/byte segments, and the mode-switch
    #         overhead inflates the stream past the v40-L capacity (2953 bytes).
    #         Large I1-I5/CPS configs failed with "Input data too large" even
    #         though the data itself is under the limit (URI ~2929 bytes < 2953)
    #         and fits in a single byte segment. Reporter: pqqsnupl (ntc.party).
    #   -s 6  module size of 6 pixels instead of the default 3 - this is the real fix.
    #         At the default scale modules were too small for the iPhone camera to
    #         distinguish when scanning the PNG off a computer screen, producing
    #         error 900 ImportInvalidConfigError in AmneziaVPN iOS for @haritos90
    #         in issue #72.
    #   -l L  lowest error correction level - this is already the qrencode default,
    #         pinned explicitly to guard against future default changes in libqrencode.
    #   -m 4  standard quiet zone of 4 modules - also the default, pinned explicitly.
    if ! qrencode -8 -t png -l L -s 6 -m 4 -o "$tmp_png" < "$uri_file"; then
        log_error "Failed to generate vpn:// QR for '$name' (config may be too large for a single QR - import the vpn:// from ${name}.vpnuri manually)."
        rm -f "$tmp_png"
        return 1
    fi

    if ! chmod 600 "$tmp_png"; then
        log_error "Failed to chmod 600 $tmp_png"
        rm -f "$tmp_png"
        return 1
    fi

    if ! mv -f "$tmp_png" "$png_file"; then
        log_error "Failed to save vpn:// QR for '$name'"
        rm -f "$tmp_png"
        return 1
    fi
    log_debug "vpn:// QR for '$name' created: $png_file"
    return 0
}

# Removes partially created client artifacts (keys + .conf). Used by the
# early-error paths of generate_client - C10: do not leave orphan keys when a
# step fails before the peer is committed to the server config.
_rollback_client_artifacts() {
    rm -f "$KEYS_DIR/$1.private" "$KEYS_DIR/$1.public" "$AWG_DIR/$1.conf"
}

# Full set of client artifacts (conf/png/vpnuri/vpnuri.png + keys). A single
# list for `manage remove` and expired-client auto-removal so the paths do not
# diverge (expiry-cleanup used to forget .vpnuri.png). Does NOT touch the expiry
# marker or cron - the caller does that (remove_client_expiry / rm "$efile").
_remove_client_files() {
    local name="$1"
    rm -f "$AWG_DIR/${name}.conf" "$AWG_DIR/${name}.png" \
        "$AWG_DIR/${name}.vpnuri" "$AWG_DIR/${name}.vpnuri.png" \
        "$KEYS_DIR/${name}.private" "$KEYS_DIR/${name}.public"
}

# Full client creation cycle:
# keypair -> next IP -> client config -> add peer -> QR
# generate_client <name> [endpoint]
#
# Env var contract:
#   CLIENT_PSK — optional. If set to "auto", a fresh PSK is generated via
#     `awg genpsk` and written to both the server [Peer] and the client
#     [Peer]. If set to a concrete value (32-byte base64), it is used as
#     is without regenerating. Empty/unset — no PSK is added (default).
generate_client() {
    local name="$1"
    local endpoint="${2:-}"

    if [[ -z "$name" ]]; then
        log_error "generate_client: name not specified"
        return 1
    fi
    # Library contract (defense-in-depth): a name with metacharacters/newlines
    # would inject into paths and the server config heredoc. Same regex as
    # validate_client_name in manage and set_client_expiry here.
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "generate_client: invalid client name '$name'"
        return 1
    fi

    # Load parameters
    load_awg_params || return 1

    # Optional PresharedKey: "auto" -> `awg genpsk`, otherwise use the
    # given value as-is. Empty/unset -> no PSK.
    if [[ "${CLIENT_PSK:-}" == "auto" ]]; then
        # --psk was requested explicitly: on awg genpsk failure do NOT silently
        # degrade to a PSK-less client (that would weaken the requested security).
        # Fail-closed; no artifacts exist yet (keys/config are created below), so
        # no rollback is needed.
        CLIENT_PSK=$(awg genpsk) || {
            log_error "awg genpsk failed - client with PresharedKey (--psk) NOT created. Please retry."
            return 1
        }
    fi

    # Inter-process lock: atomicity of IP allocation + peer addition
    local lockfile="${AWG_DIR}/.awg_config.lock"
    local lock_fd
    exec {lock_fd}>"$lockfile"
    if ! flock -x -w 30 "$lock_fd"; then
        log_error "Failed to acquire config lock"
        exec {lock_fd}>&-
        return 1
    fi

    # C6: the client must not already exist. Check UNDER the lock, BEFORE
    # generating keys - otherwise `add <existing_name>` would silently overwrite
    # a live client's keys (generate_keypair overwrites unconditionally), and a
    # concurrent same-name add would race to overwrite.
    if [[ -e "$KEYS_DIR/${name}.private" || -e "$KEYS_DIR/${name}.public" || -e "$AWG_DIR/${name}.conf" ]]; then
        log_error "Client '$name' already exists. Use 'remove' or a different name."
        exec {lock_fd}>&-
        return 1
    fi

    # Generate keys. From here on, any early failure must remove the freshly
    # created keys/conf (C10) via _rollback_client_artifacts.
    generate_keypair "$name" || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }

    # Next free IP
    local client_ip
    client_ip=$(get_next_client_ip) || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }

    # IPv6 address for client (when ALLOW_IPV6_TUNNEL=1)
    local client_ipv6=""
    if [[ "${ALLOW_IPV6_TUNNEL:-0}" == "1" ]]; then
        client_ipv6=$(get_next_client_ipv6 "$client_ip") || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }
        log_debug "Allocated IPv6 address ${client_ipv6} for client ${name}"
    fi

    # Read keys
    local client_privkey client_pubkey server_pubkey
    client_privkey=$(cat "$KEYS_DIR/${name}.private") || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }
    client_pubkey=$(cat "$KEYS_DIR/${name}.public") || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }

    # Try to reconstruct server_public.key from awg0.conf when the cache
    # is missing (supports manual setups without the installer step 6).
    _ensure_server_public_key || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }
    server_pubkey=$(cat "$AWG_DIR/server_public.key") || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }

    # Endpoint: argument → AWG_ENDPOINT (awgsetup_cfg.init) → curl to
    # external services → local IP on a network interface.
    # The last fallback targets LXC / egress-restricted setups: it may be a
    # NAT address, so we warn the user via the log.
    if [[ -z "$endpoint" ]]; then
        endpoint="${AWG_ENDPOINT:-}"
    fi
    if [[ -z "$endpoint" ]]; then
        endpoint=$(get_server_public_ip)
    fi
    if [[ -z "$endpoint" ]]; then
        endpoint=$(_try_local_ip) && log_warn "Using local server IP as Endpoint ('$endpoint') — curl to external services did not go through. If the server is behind NAT, hand-edit the Endpoint in the client .conf files."
    fi
    if [[ -z "$endpoint" ]]; then
        log_error "Failed to detect the server public IP. Set AWG_ENDPOINT in awgsetup_cfg.init (or reinstall with --endpoint=IP)."
        _rollback_client_artifacts "$name"
        exec {lock_fd}>&-
        return 1
    fi

    # Client config
    render_client_config "$name" "$client_ip" "$client_privkey" "$server_pubkey" "$endpoint" "${AWG_PORT}" "$client_ipv6" || {
        log_error "Rollback: removing artifacts for '$name'"
        _rollback_client_artifacts "$name"
        exec {lock_fd}>&-
        return 1
    }

    # Add peer to server config
    if ! add_peer_to_server "$name" "$client_pubkey" "$client_ip" "$client_ipv6"; then
        log_error "Rollback: removing artifacts for '$name'"
        _rollback_client_artifacts "$name"
        exec {lock_fd}>&-
        return 1
    fi

    # Release lock — peer written, remaining operations are non-critical
    exec {lock_fd}>&-

    # QR code (optional, failure is non-fatal)
    if ! generate_qr "$name"; then
        log_warn "QR code not created. Config: $AWG_DIR/${name}.conf"
    fi

    # vpn:// URI and QR for Amnezia VPN app (optional).
    # QR vpn:// is attempted only if URI was generated successfully — no source otherwise.
    if ! generate_vpn_uri "$name"; then
        log_warn "vpn:// URI not created for '$name'."
    elif ! generate_qr_vpnuri "$name"; then
        log_warn "vpn:// QR not created for '$name'."
    fi

    log "Client '$name' created (IP: $client_ip)."
    return 0
}

# Regenerate config and QR for existing client
# regenerate_client <name> [endpoint]
#
# v5.11.0 A5.3: protected by .awg_config.lock (serializes with
# modify_client / remove and concurrent regens on the same client) and
# checks the return code of each sed -i that restores user settings —
# previously sed failures were silently ignored.
#
# Lock scope: held only while mutating $AWG_DIR/${name}.conf.
# generate_qr / generate_vpn_uri / generate_qr_vpnuri are called OUTSIDE
# the lock as best-effort derived artifacts — if a concurrent modify
# changes the conf between our sed and QR generation, the QR may be
# stale by one tick. A concurrent `manage remove <name>` may also delete
# the client after we release the lock, and regen will "resurrect"
# `.conf` / `.png` / `.vpnuri` / `.vpnuri.png` for an already-removed
# peer (stale artefacts in $AWG_DIR). Acceptable: the user gets correct
# state on the next operation (repeat `remove` or `regen`), and the
# peer is already out of the server config — no traffic flows through
# it. Including QR/URI in the lock is more expensive (holding the lock
# for several seconds) with no server-state integrity gain.
regenerate_client() {
    local name="$1"
    local endpoint="${2:-}"

    if [[ -z "$name" ]]; then
        log_error "regenerate_client: name not specified"
        return 1
    fi
    # Library contract (defense-in-depth): the name is interpolated into paths
    # and the config, so validate it right here instead of relying on the
    # caller (manage does its own validate_client_name, but cron / third-party
    # scripts do not).
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "regenerate_client: invalid client name '$name'"
        return 1
    fi

    # Cross-process lock: guards against races with modify_client/remove
    # and concurrent regens on the same client name.
    local lockfile="${AWG_DIR}/.awg_config.lock"
    local lock_fd
    exec {lock_fd}>"$lockfile"
    if ! flock -x -w 10 "$lock_fd"; then
        log_error "Failed to acquire config lock (another operation is running)"
        exec {lock_fd}>&-
        return 1
    fi

    load_awg_params || { exec {lock_fd}>&-; return 1; }

    # Check that client exists in server config
    if ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE" 2>/dev/null; then
        log_error "Client '$name' not found in server config"
        exec {lock_fd}>&-
        return 1
    fi

    # Read client private key
    local client_privkey client_ip server_pubkey
    if [[ -f "$KEYS_DIR/${name}.private" ]]; then
        client_privkey=$(cat "$KEYS_DIR/${name}.private")
    elif [[ -f "$AWG_DIR/${name}.conf" ]]; then
        # Try to extract from existing config
        client_privkey=$(sed -n 's/^PrivateKey[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf" | tr -d '[:space:]')
    fi

    if [[ -z "$client_privkey" ]]; then
        log_error "Private key for client '$name' not found"
        exec {lock_fd}>&-
        return 1
    fi

    # Client IP from server config
    # Find [Peer] block with #_Name = name, then AllowedIPs
    # For dual-stack: ips[1] = IPv4/32, ips[2] = IPv6/128 (if present)
    local _regen_awk_out
    _regen_awk_out=$(awk -v target="$name" '
    /^\[Peer\]/ { in_peer=1; found=0; next }
    in_peer && $0 == "#_Name = " target { found=1; next }
    in_peer && found && /^AllowedIPs/ {
      sub(/^AllowedIPs[ \t]*=[ \t]*/, "")
      n = split($0, ips, /[ \t]*,[ \t]*/)
      sub(/\/[0-9]+$/, "", ips[1])
      gsub(/^[ \t]+|[ \t]+$/, "", ips[1])
      ipv4 = ips[1]
      ipv6 = ""
      if (n >= 2) {
        sub(/\/[0-9]+$/, "", ips[2])
        gsub(/^[ \t]+|[ \t]+$/, "", ips[2])
        ipv6 = ips[2]
      }
      print ipv4 " " ipv6
      exit
    }
    /^\[/ && !/^\[Peer\]/ { in_peer=0; found=0 }
    ' "$SERVER_CONF_FILE")

    client_ip="${_regen_awk_out%% *}"
    local client_ipv6="${_regen_awk_out#* }"
    # Defensive guard: awk always prints trailing space, so client_ipv6 is "" for IPv4-only.
    # This guard fires only if awk produces no trailing space (not expected in practice).
    if [[ "$client_ipv6" == "$client_ip" ]]; then
        client_ipv6=""
    fi

    # Only carry IPv6 forward if ALLOW_IPV6_TUNNEL is enabled
    if [[ "${ALLOW_IPV6_TUNNEL:-0}" != "1" ]]; then
        client_ipv6=""
    fi

    if [[ -z "$client_ip" ]]; then
        log_error "Client IP for '$name' not found in server config"
        exec {lock_fd}>&-
        return 1
    fi

    # Auto-gen from awg0.conf if the cache is missing (manual setup)
    _ensure_server_public_key || { exec {lock_fd}>&-; return 1; }
    server_pubkey=$(cat "$AWG_DIR/server_public.key" 2>/dev/null) || {
        log_error "Server public key not found"
        exec {lock_fd}>&-
        return 1
    }

    # Endpoint chain: arg → AWG_ENDPOINT → curl → local IP (best-effort).
    if [[ -z "$endpoint" ]]; then
        endpoint="${AWG_ENDPOINT:-}"
    fi
    if [[ -z "$endpoint" ]]; then
        endpoint=$(get_server_public_ip)
    fi
    if [[ -z "$endpoint" ]]; then
        endpoint=$(_try_local_ip) && log_warn "Using local server IP as Endpoint ('$endpoint') — curl to external services did not go through."
    fi
    if [[ -z "$endpoint" ]]; then
        log_error "Failed to determine server public IP."
        exec {lock_fd}>&-
        return 1
    fi

    # Preserve user settings from current .conf (modified via modify command)
    local current_dns="1.1.1.1, 1.0.0.1" current_keepalive="33" current_allowed_ips="${ALLOWED_IPS:-0.0.0.0/0}"
    if [[ -f "$AWG_DIR/${name}.conf" ]]; then
        local _v
        _v=$(sed -n 's/^DNS[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf" | tr -d '[:space:]')
        [[ -n "$_v" ]] && current_dns="$_v"
        _v=$(sed -n 's/^PersistentKeepalive[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf" | tr -d '[:space:]')
        [[ -n "$_v" ]] && current_keepalive="$_v"
        _v=$(sed -n '/^\[Peer\]/,$ s/^AllowedIPs[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf" | tr -d '[:space:]')
        [[ -n "$_v" ]] && current_allowed_ips="$_v"
        # v5.11.1: preserve PresharedKey through regen. Without this,
        # clients added with `manage add --psk` would lose their PSK on
        # regen — the server peer still holds the PSK but the client
        # conf would drop it, breaking the handshake. CLIENT_PSK is
        # passed through to render_client_config.
        local _psk
        _psk=$(sed -n '/^\[Peer\]/,$ s/^PresharedKey[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf" | tr -d '[:space:]')
        if [[ -n "$_psk" ]]; then
            export CLIENT_PSK="$_psk"
        else
            unset CLIENT_PSK
        fi
    else
        # The client .conf is lost (regen as recovery): restore the
        # PresharedKey from the server [Peer] block, otherwise the recreated
        # config would come out without a PSK while the server still has one -
        # the handshake silently breaks. We control the field order in the
        # block (add_peer_to_server writes #_Name first), so found-then-PSK
        # is sufficient.
        local _psk
        _psk=$(awk -v target="$name" '
            /^\[Peer\]/ { in_peer=1; found=0; next }
            in_peer && $0 == "#_Name = " target { found=1; next }
            in_peer && found && /^PresharedKey[ \t]*=/ {
                sub(/^PresharedKey[ \t]*=[ \t]*/, ""); sub(/\r$/, ""); print; exit
            }
            /^\[/ && !/^\[Peer\]/ { in_peer=0; found=0 }
        ' "$SERVER_CONF_FILE" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$_psk" ]]; then
            export CLIENT_PSK="$_psk"
        else
            unset CLIENT_PSK
        fi
    fi

    # Config regeneration (pass client_ipv6 if dual-stack)
    render_client_config "$name" "$client_ip" "$client_privkey" "$server_pubkey" "$endpoint" "${AWG_PORT}" "$client_ipv6" || {
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    }

    # On regen, pull in the new defaults for non-customized clients: a
    # full-tunnel 0.0.0.0/0 gets ::/0 (needed by iOS AmneziaVPN), a single DNS
    # 1.1.1.1 becomes a pair with a fallback. Values set by the user via modify
    # differ from the old defaults and are therefore kept as-is.
    [[ "$current_allowed_ips" == "0.0.0.0/0" ]] && current_allowed_ips="0.0.0.0/0, ::/0"
    [[ "$current_dns" == "1.1.1.1" ]] && current_dns="1.1.1.1, 1.0.0.1"

    # Restore user settings (escape & and \ for sed replacement)
    local _dns _ka _aip
    _dns=$(printf '%s' "$current_dns" | sed 's/[&\\/]/\\&/g')
    _ka=$(printf '%s' "$current_keepalive" | sed 's/[&\\/]/\\&/g')
    _aip=$(printf '%s' "$current_allowed_ips" | sed 's/[&\\/]/\\&/g')
    local _client_conf="$AWG_DIR/${name}.conf"
    if ! sed -i "s/^DNS = .*/DNS = ${_dns}/" "$_client_conf"; then
        log_error "sed error writing DNS to $_client_conf"
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    fi
    if ! sed -i "s/^PersistentKeepalive = .*/PersistentKeepalive = ${_ka}/" "$_client_conf"; then
        log_error "sed error writing PersistentKeepalive to $_client_conf"
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    fi
    # Delimiter '/' (not '|'): the escaping class above covers & \ / - a '|'
    # character in the value would break a sed expression using the '|' delimiter.
    # regen --reset-routes (Issue #170): do NOT restore the client's old
    # AllowedIPs - keep the value from render_client_config, computed from the
    # global routing mode (awgsetup_cfg.init) with correct IPv6 mirroring.
    # A regular regen still preserves per-client customizations.
    if [[ "${AWG_REGEN_RESET_ROUTES:-0}" == "1" ]]; then
        log "AllowedIPs of client '$name' reset to the global routing mode (--reset-routes)."
    elif ! sed -i "s/^AllowedIPs = .*/AllowedIPs = ${_aip}/" "$_client_conf"; then
        log_error "sed error writing AllowedIPs to $_client_conf"
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    fi

    # Release lock — config written, remaining ops are non-critical
    exec {lock_fd}>&-

    # QR code
    generate_qr "$name"

    # vpn:// URI and QR for Amnezia VPN app (best-effort).
    # QR vpn:// is attempted only if URI was regenerated successfully.
    if generate_vpn_uri "$name"; then
        generate_qr_vpnuri "$name" || log_warn "vpn:// QR not updated for '$name'."
    else
        log_warn "vpn:// URI not updated for '$name'."
    fi

    # Hygiene: do not let PSK leak into later operations in the same shell
    unset CLIENT_PSK

    log "Client config for '$name' regenerated."
    return 0
}

# ==============================================================================
# Validation
# ==============================================================================

# Validate AWG 2.0 server config
validate_awg_config() {
    if [[ ! -f "$SERVER_CONF_FILE" ]]; then
        log_error "Server config not found: $SERVER_CONF_FILE"
        return 1
    fi

    local ok=1
    local param val
    local int_params=("Jc" "Jmin" "Jmax" "S1" "S2" "S3" "S4")
    local range_params=("H1" "H2" "H3" "H4")

    # Parsing aligned with load_awg_params_from_server_conf: arbitrary spaces
    # around '=', last-wins for duplicate lines (validate the value that will
    # actually load), trim spaces/CR. Previously the validator required exactly
    # one space and took first-wins - a hand-edited 'Jc=4' loaded fine but
    # failed validation with a bogus "parameter not found".
    for param in "${int_params[@]}"; do
        val=$(sed -n "s/^[[:space:]]*${param}[[:space:]]*=[[:space:]]*//p" "$SERVER_CONF_FILE" | tail -1 | tr -d '[:space:]')
        if [[ -z "$val" ]]; then
            log_error "Parameter '$param' not found in server config"
            ok=0
        elif ! [[ "$val" =~ ^[0-9]+$ ]]; then
            log_error "Parameter '$param' has invalid value: '$val' (expected integer)"
            ok=0
        fi
    done

    # Protocol boundary checks (defense-in-depth for restored backups)
    local jc jmin jmax s3 s4
    jc=$(sed -n 's/^[[:space:]]*Jc[[:space:]]*=[[:space:]]*//p' "$SERVER_CONF_FILE" | tail -1 | tr -d '[:space:]')
    jmin=$(sed -n 's/^[[:space:]]*Jmin[[:space:]]*=[[:space:]]*//p' "$SERVER_CONF_FILE" | tail -1 | tr -d '[:space:]')
    jmax=$(sed -n 's/^[[:space:]]*Jmax[[:space:]]*=[[:space:]]*//p' "$SERVER_CONF_FILE" | tail -1 | tr -d '[:space:]')
    s3=$(sed -n 's/^[[:space:]]*S3[[:space:]]*=[[:space:]]*//p' "$SERVER_CONF_FILE" | tail -1 | tr -d '[:space:]')
    s4=$(sed -n 's/^[[:space:]]*S4[[:space:]]*=[[:space:]]*//p' "$SERVER_CONF_FILE" | tail -1 | tr -d '[:space:]')
    if [[ "$jc" =~ ^[0-9]+$ ]]; then
        if [[ "$jc" -lt 1 || "$jc" -gt 128 ]]; then
            log_error "Jc=$jc is out of range (1-128)"
            ok=0
        fi
    fi
    if [[ "$jmin" =~ ^[0-9]+$ && "$jmax" =~ ^[0-9]+$ ]]; then
        if [[ "$jmin" -gt 1280 ]]; then
            log_error "Jmin=$jmin exceeds 1280"
            ok=0
        fi
        if [[ "$jmax" -gt 1280 ]]; then
            log_error "Jmax=$jmax exceeds 1280"
            ok=0
        fi
        if [[ "$jmax" -lt "$jmin" ]]; then
            log_error "Jmax ($jmax) is less than Jmin ($jmin)"
            ok=0
        fi
    fi
    if [[ "$s3" =~ ^[0-9]+$ && "$s3" -gt 64 ]]; then
        log_error "S3=$s3 exceeds maximum (64)"
        ok=0
    fi
    if [[ "$s4" =~ ^[0-9]+$ && "$s4" -gt 32 ]]; then
        log_error "S4=$s4 exceeds maximum (32)"
        ok=0
    fi

    local _h_ranges=()
    for param in "${range_params[@]}"; do
        val=$(sed -n "s/^[[:space:]]*${param}[[:space:]]*=[[:space:]]*//p" "$SERVER_CONF_FILE" | tail -1 | tr -d '[:space:]')
        if [[ -z "$val" ]]; then
            log_error "Parameter '$param' not found in server config"
            ok=0
        elif ! [[ "$val" =~ ^[0-9]+-[0-9]+$ ]]; then
            log_error "Parameter '$param' has invalid value: '$val' (expected MIN-MAX format)"
            ok=0
        else
            local range_lo="${val%-*}" range_hi="${val#*-}"
            if [[ "$range_lo" -ge "$range_hi" ]]; then
                log_error "Parameter '$param': lower bound ($range_lo) >= upper bound ($range_hi)"
                ok=0
            else
                _h_ranges+=("$range_lo $range_hi $param")
            fi
        fi
    done

    # Pairwise non-overlap of H1-H4 is a key AWG 2.0 invariant. Without this
    # check a config from a foreign backup with overlapping ranges passed
    # validation even though the protocol does not allow it.
    if [[ ${#_h_ranges[@]} -eq 4 ]]; then
        local _i _j _lo1 _hi1 _n1 _lo2 _hi2 _n2
        for ((_i = 0; _i < 4; _i++)); do
            for ((_j = _i + 1; _j < 4; _j++)); do
                read -r _lo1 _hi1 _n1 <<< "${_h_ranges[$_i]}"
                read -r _lo2 _hi2 _n2 <<< "${_h_ranges[$_j]}"
                if (( _lo1 <= _hi2 && _lo2 <= _hi1 )); then
                    log_error "Ranges ${_n1} (${_lo1}-${_hi1}) and ${_n2} (${_lo2}-${_hi2}) overlap"
                    ok=0
                fi
            done
        done
    fi

    # I1 is optional. Absent = either not set, or intentionally disabled via
    # --no-cps (issue #159): the desktop AmneziaVPN on macOS does not support CPS.
    if ! grep -qE '^[[:space:]]*I1[[:space:]]*=' "$SERVER_CONF_FILE"; then
        if grep -qE '^[[:space:]]*(export[[:space:]]+)?NO_CPS=1' "$CONFIG_FILE" 2>/dev/null; then
            log "I1 (CPS) intentionally disabled (--no-cps) - expected for the desktop AmneziaVPN on macOS"
        else
            log_warn "Parameter I1 (CPS) not found - CPS concealment is not active"
        fi
    fi

    if [[ $ok -eq 1 ]]; then
        log "AWG 2.0 config validation: OK"
        return 0
    else
        return 1
    fi
}

# ==============================================================================
# Client expiry
# ==============================================================================

EXPIRY_DIR="${AWG_DIR}/expiry"
EXPIRY_CRON="${EXPIRY_CRON:-/etc/cron.d/awg-expiry}"

# Parse duration string to seconds: 1h, 12h, 1d, 7d, 30d
# parse_duration <duration_string>
parse_duration() {
    local input="$1"
    local num unit
    if [[ "$input" =~ ^([0-9]+)([hdw])$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"
    else
        log_error "Invalid duration format: '$input'. Use: 1h, 12h, 1d, 7d, 4w"
        return 1
    fi
    case "$unit" in
        h) echo $((num * 3600)) ;;
        d) echo $((num * 86400)) ;;
        w) echo $((num * 604800)) ;; # 7 days
        *) return 1 ;;
    esac
}

# Set client expiry
# set_client_expiry <name> <duration>
set_client_expiry() {
    local name="$1"
    local duration="$2"
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "Invalid client name: '$name'"
        return 1
    fi
    if ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE" 2>/dev/null; then
        log_error "Client '$name' not found."
        return 1
    fi
    local seconds
    seconds=$(parse_duration "$duration") || return 1
    local now
    now=$(date +%s)
    local expires_at=$((now + seconds))

    mkdir -p "$EXPIRY_DIR" || {
        log_error "Failed to create $EXPIRY_DIR"
        return 1
    }
    echo "$expires_at" > "$EXPIRY_DIR/$name" || {
        log_error "Failed to write expiry for '$name'"
        return 1
    }
    chmod 600 "$EXPIRY_DIR/$name"
    local expires_date
    expires_date=$(date -d "@$expires_at" '+%F %T' 2>/dev/null || echo "$expires_at")
    log "Expiry for '$name': $expires_date ($duration)"
    return 0
}

# Get client expiry (unix timestamp or empty)
# get_client_expiry <name>
get_client_expiry() {
    local name="$1"
    local efile="$EXPIRY_DIR/$name"
    if [[ -f "$efile" ]]; then
        cat "$efile"
    fi
}

# Format remaining time
# format_remaining <expires_at_timestamp>
format_remaining() {
    local expires_at="$1"
    local now
    now=$(date +%s)
    local diff=$((expires_at - now))
    if [[ $diff -le 0 ]]; then
        local ago=$(( (-diff) / 3600 ))
        if [[ $ago -ge 24 ]]; then
            echo "expired $(( ago / 24 ))d ago"
        elif [[ $ago -ge 1 ]]; then
            echo "expired ${ago}h ago"
        else
            local ago_mins=$(( (-diff) / 60 ))
            if [[ $ago_mins -ge 1 ]]; then
                echo "expired ${ago_mins}m ago"
            else
                echo "just expired"
            fi
        fi
        return 0
    fi
    local days=$((diff / 86400))
    local hours=$(( (diff % 86400) / 3600 ))
    if [[ $days -gt 0 ]]; then
        echo "${days}d ${hours}h"
    else
        local mins=$(( (diff % 3600) / 60 ))
        echo "${hours}h ${mins}m"
    fi
}

# Check and remove expired clients
check_expired_clients() {
    if [[ ! -d "$EXPIRY_DIR" ]]; then return 0; fi

    local removed=0
    local efile
    for efile in "$EXPIRY_DIR"/*; do
        [[ -f "$efile" ]] || continue
        local name
        name=$(basename "$efile")
        # Name validation: same regex as validate_client_name in manage_amneziawg.sh.
        # Defense-in-depth — EXPIRY_DIR is root-only, but protection against an
        # accidentally placed invalid file (or symlink attack if expiry_dir
        # ever becomes shared) is needed before using $name in paths and
        # passing it to remove_peer_from_server (self-audit).
        if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            log_warn "Skipping invalid expiry file: '$name'"
            continue
        fi
        local expires_at
        expires_at=$(cat "$efile" 2>/dev/null)
        if [[ -z "$expires_at" || ! "$expires_at" =~ ^[0-9]+$ ]]; then
            log_warn "Malformed expiry data for '$name': '$(head -c 50 "$efile" 2>/dev/null)'"
            continue
        fi

        local now
        now=$(date +%s)
        if [[ $now -ge $expires_at ]]; then
            log "Client '$name' expired. Removing..."
            if [[ -r "$SERVER_CONF_FILE" ]] && ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE"; then
                # Orphan marker: the peer is already gone from the config
                # (removed manually, via awg, or by restoring an old backup).
                # Without this branch cron would forever retry
                # remove_peer_from_server every 5 minutes, piling warns into
                # expiry.log, and the client artifacts would never be cleaned.
                # The [[ -r ]] guard: a temporarily missing/unreadable config
                # (mid-restore, fs failure) is NOT a reason to wipe client
                # artifacts - that case falls through to the warn branch and
                # is retried later.
                _remove_client_files "$name"
                remove_client_expiry "$name"
                log "Client '$name': peer is absent from the config - cleaned up orphaned artifacts and the expiry marker."
            elif remove_peer_from_server "$name" 2>/dev/null; then
                _remove_client_files "$name"
                remove_client_expiry "$name"
                log "Client '$name' removed (expired)."
                ((removed++))
            else
                log_warn "Failed to remove expired client '$name'."
            fi
        fi
    done

    if [[ $removed -gt 0 ]]; then
        log "Expired clients removed: $removed. Applying config..."
        if ! apply_config; then
            log_error "apply_config failed after removing expired clients. Peers removed from config and expiry/, but may still be present on live interface. Manual restart required: systemctl restart awg-quick@awg0"
            return 1
        fi
    fi
    return 0
}

# Install cron job for auto-removal
install_expiry_cron() {
    # Idempotent by CONTENT, not by file existence. The old early-out on "file
    # exists" left stale paths after restore/migration/--conf-dir: the cron kept
    # pointing at the old AWG_DIR. Generate the expected text and replace the file
    # only when it differs.
    local _cron_tmp
    _cron_tmp=$(awg_mktemp "$(dirname "$EXPIRY_CRON")") || { log_error "mktemp error for expiry cron"; return 1; }
    # Check the write succeeded BEFORE cmp/mv: otherwise a failure (disk/perms)
    # could atomically replace a working cron with an empty/partial tmp.
    if ! cat > "$_cron_tmp" << CRONEOF
# AmneziaWG client expiry check - every 5 minutes
AWG_DIR="${AWG_DIR}"
CONFIG_FILE="${CONFIG_FILE}"
SERVER_CONF_FILE="${SERVER_CONF_FILE}"
*/5 * * * * root /bin/bash -c 'source "${AWG_DIR}/awg_common.sh" || exit 1; trap _awg_cleanup EXIT; check_expired_clients' >> "${AWG_DIR}/expiry.log" 2>&1
CRONEOF
    then
        rm -f "$_cron_tmp"
        log_error "Error writing expiry cron job"
        return 1
    fi
    if [[ -f "$EXPIRY_CRON" ]] && cmp -s "$_cron_tmp" "$EXPIRY_CRON"; then
        rm -f "$_cron_tmp"
        log_debug "Expiry cron job already current."
        return 0
    fi
    chmod 644 "$_cron_tmp"
    if ! mv -f "$_cron_tmp" "$EXPIRY_CRON"; then
        rm -f "$_cron_tmp"
        log_error "Error installing expiry cron job: $EXPIRY_CRON"
        return 1
    fi
    log "Expiry cron job installed/updated: $EXPIRY_CRON"
}

# Remove client expiry data
remove_client_expiry() {
    local name="$1"
    rm -f "$EXPIRY_DIR/$name" 2>/dev/null
    # Remove cron if no more clients with expiry
    if [[ -d "$EXPIRY_DIR" ]] && [[ -z "$(ls -A "$EXPIRY_DIR" 2>/dev/null)" ]]; then
        rm -f "$EXPIRY_CRON" 2>/dev/null
        log_debug "Expiry cron job removed (no clients with expiry)."
    fi
}
