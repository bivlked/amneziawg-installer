#!/bin/bash

# ==============================================================================
# Shared function library for AmneziaWG 2.0
# Author: @bivlked
# Version: 5.36.2
# Date: 2026-09-24
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

# Library version. The manage script compares it against its own by MAJOR.MINOR
# after sourcing and dies with a clear message if awg_common.sh and manage have
# drifted apart (one file updated, the other not) - otherwise the mismatch shows
# up as a "command not found" somewhere random. Bumped with the other versions.
# shellcheck disable=SC2034  # used by the manage script after sourcing
AWG_COMMON_VERSION="5.36.2"

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

# The port from the config cannot be trusted before it is checked: both
# awgsetup_cfg.init and the ListenPort in the live awg0.conf are hand-edited and
# end up holding anything. The value goes into the 'Endpoint = IP:PORT' line of
# the client .conf (add/regen), into JSON unquoted ("number":abc does not parse)
# and into arithmetic comparisons (where bash runs command substitution from a
# value like a[$(...)]) in check, and into the UFW rule regex in diagnose. A
# function, not two lines in place: this way the test runs the real code.
_sanitize_port() {
    local p="${1:-}"
    # Surrounding whitespace is trimmed: 'AWG_PORT=39743 ' is an ordinary
    # leftover of a hand edit and means the same port. Such a config used to
    # fail the check for nothing.
    p="${p#"${p%%[![:space:]]*}"}"
    p="${p%"${p##*[![:space:]]}"}"
    # {1,5} rules out 64-bit arithmetic overflow: a long digit string would
    # quietly land inside the valid range. 10# rules out octal reading of
    # values with a leading zero (0070 would otherwise be 56).
    if [[ "$p" =~ ^[0-9]{1,5}$ ]] && (( 10#$p >= 1 && 10#$p <= 65535 )); then
        printf '%s' "$((10#$p))"
    else
        printf '0'
    fi
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

# --- Full tunnel: decided by the PROPERTY of the route set, not by a string ---

# IPv4 ranges whose absence from AllowedIPs does NOT make a tunnel split.
# This is a TOLERANCE list, NOT a description of what any mode excludes: our
# default list leaves out only 0/8, 10/8, 172.16/12, 192.168/16 and 224/3, and
# routes the rest of this table into the tunnel. Confusing the two is dangerous:
# read as "the modes leave these outside the tunnel", it invites someone to
# align the list generator with this table and silently change what the default
# tunnels. The contents are POLICY rather than mechanics, so the grounds are
# named: private networks (10/8, 172.16/12, 192.168/16) and CGNAT (100.64/10)
# live at the ISP and on the home network; 0/8, 127/8 and 169.254/16 are not
# routed; 192.0.0/24 is IETF protocol assignments, 192.0.2/24, 198.51.100/24 and
# 203.0.113/24 are documentation examples, 198.18/15 is benchmarking; 224/3 is
# multicast, reserved space and the broadcast address. None of these is a place
# a user reaches through the VPN, so their absence does not make the tunnel any
# less full.
# Ascending and non-overlapping - the sweep in _awg_ipv4_range_is_non_public
# relies on that.
_AWG_NON_PUBLIC_IPV4=(
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
    172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16
    198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/3
)

# _awg_ipv4_range_is_non_public <lo> <hi> : does [lo, hi] lie entirely inside
# the non-public ranges? Sweep with a cursor: every range is either already
# behind the cursor or must start no later than it, otherwise a public address
# sits in between and the answer is no.
_awg_ipv4_range_is_non_public() {
    local hi="$2" cidr b slo shi cur="$1"
    for cidr in "${_AWG_NON_PUBLIC_IPV4[@]}"; do
        b=$(_cidr_bounds "$cidr") || {
            # The table is a constant, so a failure here means broken code, not
            # user input. A silent "split" would look like an honest answer.
            log_error "The internal table of non-public ranges is corrupt: '$cidr'."
            return 1
        }
        slo="${b%% *}"; shi="${b##* }"
        (( shi < cur )) && continue
        (( slo > cur )) && return 1
        (( shi + 1 > cur )) && cur=$(( shi + 1 ))
        (( cur > hi )) && return 0
    done
    (( cur > hi ))
}

# _is_full_tunnel <allowed_ips> : does the list cover ALL public IPv4?
#
# Mode 1 spells a full tunnel as 0.0.0.0/0; mode 2 (the install default until
# v5.34.0) spells it as a 34-entry list: all public IPv4 minus the private ranges. It is written
# as a list only to dodge the iOS bug on 0.0.0.0/5 (issue #42), so by meaning it
# is a full tunnel too. Comparing the string with a literal answered these two
# cases differently, and the install default lost its ::/0 back then - the device's IPv6
# went out with its real address.
#
# Real split routing (mode 3) does not cover the public space and still gets a
# negative answer.
#
# Returns: 0 - full tunnel, 1 - not. An unparseable route also returns 1, but
# LOUDLY: a silent "assuming split" is indistinguishable from an honest answer.
_is_full_tunnel() {
    local list="$1" tok b lo hi pairs="" cur=0
    local -a toks=()
    # read takes ONLY THE FIRST LINE even with newline in IFS, so newlines and
    # carriage returns are turned into spaces up front. AllowedIPs can be
    # multi-line (wg allows the key to repeat, D#38), and a config edited on
    # Windows arrives with a \r glued to the last token.
    list="${list//$'\r'/}"
    list="${list//$'\n'/, }"
    local IFS=$', \t'
    read -ra toks <<< "$list"
    IFS=$' \t\n'
    # Upper bound on the list size. Every token costs one command substitution,
    # that is one process: our own lists are under 40 entries, but a user list
    # of tens of thousands of networks (inverting country ranges is a popular
    # trick in forum threads) would turn every add and regen into minutes. The
    # refusal is LOUD and carries the number: the behaviour stays what it was
    # (no ::/0 appended), but the reason is visible instead of looking checked.
    if (( ${#toks[@]} > 512 )); then
        log_warn "AllowedIPs: ${#toks[@]} routes, above the check limit (512) - treating the list as split, not appending ::/0."
        return 1
    fi
    for tok in "${toks[@]}"; do
        [[ -z "$tok" ]] && continue
        # An IPv6 token does not change IPv4 coverage: a dual-stack list already
        # carries its IPv6 part and must not disturb the answer about IPv4.
        [[ "$tok" == *:* ]] && continue
        [[ "$tok" == */* ]] || tok="${tok}/32"
        if ! b=$(_cidr_bounds "$tok"); then
            log_warn "AllowedIPs: route '$tok' could not be parsed - treating the list as split, not appending ::/0."
            return 1
        fi
        pairs+="${b}"$'\n'
    done
    # An empty list (or an IPv6-only one) is not a full tunnel.
    [[ -n "$pairs" ]] || return 1
    # Sweep the union of the intervals: whatever stays uncovered must lie
    # entirely inside the non-public ranges. sort -n gives ascending order;
    # overlaps and duplicates collapse into the cursor.
    # Sort into a variable, NOT through process substitution: a failure of sort
    # inside <(...) is invisible to the parent shell, so the predicate would
    # silently answer "split" for a sound list - on a broken host the behaviour
    # from before this change would quietly return, mode 1 included, which never
    # depended on sort at all.
    local sorted
    sorted=$(printf '%s' "$pairs" | LC_ALL=C sort -n -k1,1 -k2,2) || {
        log_warn "AllowedIPs: could not order the routes - not checking whether the tunnel is full, not appending ::/0."
        return 1
    }
    while read -r lo hi; do
        if (( lo > cur )); then
            _awg_ipv4_range_is_non_public "$cur" $(( lo - 1 )) || return 1
        fi
        if (( hi + 1 > cur )); then cur=$(( hi + 1 )); fi
    done <<< "$sorted"
    if (( cur <= 4294967295 )); then
        _awg_ipv4_range_is_non_public "$cur" 4294967295 || return 1
    fi
    return 0
}

# The IPv6 "sink" prefix for the list-based full tunnel (routing mode 2).
#
# Why. The AmneziaWG Windows client (a wireguard-windows fork) turns on its kill
# switch when a single peer carries 0.0.0.0/0 OR ::/0, and that kill switch cuts
# off the LAN - the very thing mode 2 exists for (measured on a stand: gateway,
# LAN hosts and SSH unreachable). Without an IPv6 address on the interface,
# Windows installs no IPv6 route at all (amneziawg-windows-client #112), so
# 2000::/3 alone instead of ::/0 would bring the LAN back and let IPv6 leak
# around the tunnel. Hence the list gets 2000::/3 (all global IPv6) plus an
# address from this prefix: the route is installed, IPv6 enters the tunnel and
# dies there (a server without the IPv6 tunnel drops that source), and the LAN
# stays outside. Measured on Windows, Linux awg-quick and Android with real IPv6.
# The prefix is separate from the dual-stack tunnel subnet
# (fddd:2c4:2c4:2c4::/64): vpn:// and regen tell the sink from a real client
# IPv6 address by the prefix.
AWG_V6_SINK_PREFIX="fddd:2c4:2c4:ffff"

# _awg_v6_sink_addr <ipv4> : the client's sink address - the prefix plus its
# IPv4 in the low 32 bits (10.9.9.5 -> fddd:2c4:2c4:ffff::a09:905). Unique per
# client, stable across regen, computed without stored state.
_awg_v6_sink_addr() {
    local ip="${1:-}" o1 o2 o3 o4
    _valid_ipv4 "$ip" || return 1
    IFS=. read -r o1 o2 o3 o4 <<< "$ip"
    printf '%s::%x:%x' "$AWG_V6_SINK_PREFIX" \
        $(( (10#$o1 << 8) | 10#$o2 )) $(( (10#$o3 << 8) | 10#$o4 ))
}

# _is_v6_sink_addr <address[/len]> : an address from the sink prefix.
_is_v6_sink_addr() {
    local a="${1%%/*}"
    a="${a,,}"
    [[ -n "$a" && "$a" == "${AWG_V6_SINK_PREFIX}:"* ]]
}

# _aip_tokens <list> : the AllowedIPs elements one per line, without spaces.
# Newline and comma separate elements, a carriage return is not meaningful.
_aip_tokens() {
    local list="$1" tok
    local -a toks=()
    list="${list//$'\r'/}"
    list="${list//$'\n'/,}"
    IFS=',' read -ra toks <<< "$list"
    for tok in "${toks[@]}"; do
        tok="${tok//[[:space:]]/}"
        [[ -n "$tok" ]] && printf '%s\n' "$tok"
    done
    return 0
}

# _aip_has_token <list> <element> : whether the list has exactly that element.
# No pipeline: grep -q exits on the first match, the writer gets SIGPIPE, and
# under pipefail the pipeline answers "no" for an element that is there (on a
# 400-route list - almost always).
_aip_has_token() {
    local toks
    toks=$(_aip_tokens "$1") || return 1
    grep -qxF -- "$2" <<< "$toks"
}

# _aip_wants_v6_sink <list> : whether the client needs the sink address - the
# list has 2000::/3 and no ::/0 (with ::/0 the Windows kill switch is on anyway).
_aip_wants_v6_sink() {
    _aip_has_token "$1" "2000::/3" && ! _aip_has_token "$1" "::/0"
}

# _append_ipv6_full_tunnel_route <allowed_ips> : prints the list with the IPv6
# part of a full tunnel when it is a full tunnel without IPv6; otherwise prints
# the list unchanged.
#
# Why: IPv6 does not travel through an IPv4 tunnel, so without an IPv6 route it
# goes around the VPN with its real address - a blocked site with an AAAA record
# stays blocked, and it looks like "the VPN does not work on mobile". The route
# pulls IPv6 into the tunnel where it is dropped, and the client falls back to
# IPv4 (Happy Eyeballs). iOS AmneziaVPN requires the same for its "all traffic"
# mode. Which route:
#   - the list has 0.0.0.0/0 (mode 1) -> ::/0, as before: the Windows kill
#     switch is turned on by 0.0.0.0/0 itself there;
#   - a full tunnel written as a list (mode 2) -> 2000::/3, and
#     render_client_config adds the sink address (see AWG_V6_SINK_PREFIX).
# A list that already has an IPv6 part is untouched: an explicit ::/0 from
# --allowed-ips is the user's choice. Our own earlier ::/0 on a mode-2 list
# (v5.31.0-v5.36.x) is replaced by regen via _aip_migrate_legacy_v6: only regen
# knows where the list came from.
#
# Idempotence is mandatory: regen runs repeatedly, including over a dual-stack
# client whose IPv6 part has already been built.
_append_ipv6_full_tunnel_route() {
    local list="$1"
    # The decision is taken on a normalised copy, so the normalised copy is what
    # gets printed. Otherwise a carriage return from the middle of the line would
    # travel into the client config together with the appended route, and
    # clients reject such a token.
    # A carriage return is NEVER meaningful and is simply dropped; a newline is
    # an element separator, so it becomes a comma rather than a space - a space
    # would glue two routes into one unreadable token.
    list="${list//$'\r'/}"
    list="${list//$'\n'/, }"
    if [[ "$list" != *:* ]]; then
        if _is_full_tunnel "$list"; then
            if _aip_has_token "$list" "0.0.0.0/0"; then
                printf '%s, ::/0' "$list"
            else
                printf '%s, 2000::/3' "$list"
            fi
        else
            printf '%s' "$list"
        fi
        return 0
    fi
    printf '%s' "$list"
}

# _aip_migrate_legacy_v6 <client list> <server list> : prints the list with our
# earlier ::/0 replaced by 2000::/3, otherwise the list unchanged.
# v5.31.0-v5.36.x appended a bare ::/0 to the mode-2 list, and on Windows it
# cuts off the local network. ONLY what we wrote is replaced: the IPv4 part
# matches the server's global list (as a set of routes), the IPv6 part is
# exactly ::/0, and that list is a full tunnel without 0.0.0.0/0. A full tunnel
# a person wrote out themselves (--allowed-ips, modify) stays their choice.
# Regen never passes a client with a real IPv6 address (dual-stack) here.
_aip_migrate_legacy_v6() {
    local list="$1" base="$2" toks v6 mine srv tok out="" rc
    toks=$(_aip_tokens "$list") || return 1
    # grep exit code 1 means "no lines", which is an answer; 2 and above is a
    # failure and must not pass for an answer: the migration would silently skip.
    v6=$(grep -F ':' <<< "$toks"); rc=$?
    (( rc > 1 )) && return 1
    if [[ "$v6" != "::/0" || -z "$base" || "$base" == *:* ]] \
       || _aip_has_token "$base" "0.0.0.0/0" || ! _is_full_tunnel "$base"; then
        printf '%s' "$list"
        return 0
    fi
    # Without an IPv4 part (modify accepts a bare ::/0 too) this is not our list.
    # Not in a pipeline: under pipefail "no lines" would fail regen on a valid list.
    mine=$(grep -vF ':' <<< "$toks"); rc=$?
    (( rc > 1 )) && return 1
    [[ -n "$mine" ]] || { printf '%s' "$list"; return 0; }
    mine=$(LC_ALL=C sort -u <<< "$mine") || return 1
    srv=$(_aip_tokens "$base" | LC_ALL=C sort -u) || return 1
    if [[ "$mine" == "$srv" ]]; then
        while IFS= read -r tok; do
            [[ "$tok" == "::/0" ]] && tok="2000::/3"
            out+="${out:+, }${tok}"
        done <<< "$toks"
        printf '%s' "$out"
        return 0
    fi
    printf '%s' "$list"
}

# _sync_v6_sink_address <client config> : bring Address in line with the
# AllowedIPs of the same file - the sink address is there exactly when the list
# needs it. Used where the list changes after rendering: regen restoring a
# custom list, and modify AllowedIPs. A dual-stack client (second address not
# from the sink) is left alone.
# A layout we never write (Address over several lines, three addresses) is left
# alone too, but said out loud: a sink kept silently would drift from the
# routes. Every failure is named; the caller adds what was rolled back.
_sync_v6_sink_address() {
    local conf="$1" addr aips v4 second new sink n_addr
    local -a parts=()
    # A missing file reaches awk below and is named there.
    n_addr=$(grep -c '^[[:space:]]*Address[[:space:]]*=' "$conf" 2>/dev/null) || n_addr=0
    if (( n_addr > 1 )); then
        log_warn "Address in $conf spans several lines - not aligning the IPv6 sink address, check it by hand."
        return 0
    fi
    addr=$(awk '/^[[:space:]]*Address[[:space:]]*=/{sub(/^[[:space:]]*Address[[:space:]]*=[[:space:]]*/, ""); sub(/\r$/, ""); print; exit}' "$conf") || {
        log_error "Address: could not read $conf."
        return 1
    }
    # Every AllowedIPs line: wg adds them up, and 2000::/3 on the second line is
    # as much a route as on the first.
    aips=$(awk '/^[[:space:]]*AllowedIPs[[:space:]]*=/{sub(/^[[:space:]]*AllowedIPs[[:space:]]*=[[:space:]]*/, ""); sub(/\r$/, ""); printf "%s%s", sep, $0; sep=", "}' "$conf") || {
        log_error "AllowedIPs: could not read $conf."
        return 1
    }
    IFS=',' read -ra parts <<< "$addr"
    v4="${parts[0]//[[:space:]]/}"
    second="${parts[1]:-}"
    second="${second//[[:space:]]/}"
    if (( ${#parts[@]} > 2 )); then
        log_warn "Address in $conf carries more than two addresses - not aligning the IPv6 sink address, check it by hand."
        return 0
    fi
    [[ -n "$second" ]] && ! _is_v6_sink_addr "$second" && return 0
    # The IPv4 is checked whole: the value goes into a sed replacement, and an
    # '&' in it would duplicate the line with exit code 0. An empty Address is
    # refused here too.
    if [[ ! "$v4" =~ ^[0-9.]+(/([0-9]|[12][0-9]|3[0-2]))?$ ]] || ! _valid_ipv4 "${v4%%/*}"; then
        log_error "Address in $conf not parsed ('$v4')."
        return 1
    fi
    new="$v4"
    if _aip_wants_v6_sink "$aips"; then
        sink=$(_awg_v6_sink_addr "${v4%%/*}") || {
            log_error "Address: could not compute the sink address for '$v4'."
            return 1
        }
        new="${v4}, ${sink}/128"
    fi
    [[ "$new" == "$addr" ]] && return 0
    sed -i "s|^[[:space:]]*Address[[:space:]]*=.*|Address = ${new}|" "$conf" || {
        log_error "Address: could not write $conf."
        return 1
    }
}

# A full tunnel whose AllowedIPs carry an explicit IPv6 part but no ::/0,
# on a server with native IPv6 (Issue #253): exactly the state regen warns
# about when it preserves a custom list. One predicate for regen and render -
# two copies of the condition would drift silently. The native-IPv6 clause is
# mandatory: without it the client is due the tunnel ULA instead of ::/0,
# which is the documented rule, not a leak, and the warning would invite
# fixing what is not broken.
_aip_full_tunnel_v6_gap() {
    local list="$1"
    [[ "${SERVER_HAS_NATIVE_IPV6:-0}" == "1" && "$list" == *:* ]] \
        && ! _aip_has_token "$list" "::/0" && ! _aip_has_token "$list" "2000::/3" \
        && _is_full_tunnel "$list"
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

# awg_module_version : version of the amneziawg module (empty string if it
# cannot be determined). Asks the LOADED module first, the file second.
#
# ⚠️ Why not just modinfo: modinfo reads the metadata of the .ko that was
# SELECTED on disk via modules.dep, not of the object running in the kernel.
# Normally these are the same, which is why the divergence never surfaced. But
# if a host ends up with TWO trees carrying a module of the same name - the
# pinned 2.0 in extra/ and DKMS 3.0 in updates/dkms/ - modinfo reports whichever
# won the search order, while a different one may be loaded (for instance the
# previous one, before a reboot). Our own diagnostics would then name a version
# that is not in the kernel.
# /sys/module/amneziawg/version reflects exactly what is loaded, and it exists
# in BOTH lines: MODULE_VERSION(WIREGUARD_VERSION) is declared in src/main.c in
# the pinned 2.0 tag as well as in 3.0.
# modinfo stays as the second path - it works when the module is not loaded.
#
# AWG_MODULE_VERSION_PATH is overridden by tests (bats) only: /sys cannot be
# faked otherwise, and the priority "loaded beats file" is exactly what needs
# verifying.
awg_module_version() {
    local ver="" sysfile="${AWG_MODULE_VERSION_PATH:-/sys/module/amneziawg/version}"
    if [[ -r "$sysfile" ]]; then
        # ⚠️ `|| true`, NOT `|| ver=""`: on a file without a trailing newline
        # read returns 1 having ALREADY assigned what it read. Resetting to an
        # empty string would wipe a correct value and silently fall to modinfo.
        # ⚠️ And `2>/dev/null` comes BEFORE `<`, not after: redirections are
        # applied left to right, so with the opposite order a file-open error
        # still reaches the original stderr - verified, a raw `bash: ...` line
        # appeared in the middle of `manage check` output.
        IFS= read -r ver 2>/dev/null < "$sysfile" || true
        ver="${ver//[[:space:]]/}"
        # 🔴 The file was readable, so answer with what it gave, even if that
        # is empty, and do NOT fall through to modinfo. Substituting the on-disk
        # answer is exactly what this function exists to avoid: with two trees
        # modinfo names a version that is not in the kernel, and diagnose would
        # then declare a protocol line from it. An empty version is more honest
        # than a wrong one - consumers print the line without a version.
        printf '%s' "$ver"
        return 0
    fi
    ver=$(modinfo amneziawg 2>/dev/null | awk '/^version:/{print $2; exit}')
    printf '%s' "$ver"
}

# awg_module_build_id : build identity of the loaded module, on one line.
# Empty string when nothing could be identified.
#
# 🔴 Why this is separate from awg_module_version. The module version string
# does NOT identify the build: a bench measurement on 30 aug 2026 read
# `3.1.20260812` BOTH from the PPA build of 14 aug (`4680320`) AND from the one
# of 28 aug (`3c38e16`) - MODULE_VERSION is a static define and changes far less
# often than the code. Only srcversion (the source hash the module build
# computes) and the package version tell the builds apart.
# Without it the diagnostic report cannot answer "which build do you have",
# which is exactly the question when a kernel module and a userspace client
# disagree.
#
# AWG_MODULE_SRCVERSION_PATH is overridden by tests only: /sys cannot be
# replaced otherwise, and what has to be verified is the read of the loaded
# module.
awg_module_build_id() {
    local src="" pkg="" out=""
    local sysfile="${AWG_MODULE_SRCVERSION_PATH:-/sys/module/amneziawg/srcversion}"
    if [[ -r "$sysfile" ]]; then
        # `|| true` for the same reason as in awg_module_version: on a file with
        # no trailing newline read returns 1 having ALREADY assigned the value.
        IFS= read -r src 2>/dev/null < "$sysfile" || true
        src="${src//[[:space:]]/}"
    fi
    # FIRST line only: on several matches concatenation would produce a
    # plausible but non-existent version, and that is worse than no answer.
    pkg=$(dpkg-query -W -f='${Version}\n' amneziawg-dkms 2>/dev/null | head -n 1 || true)
    pkg="${pkg//[[:space:]]/}"
    # 🔴 The two parts are LABELLED DIFFERENTLY on purpose: they are different
    # things and they diverge routinely. The package can be upgraded while the
    # module in memory stays the old one until a reboot or modprobe - exactly
    # what was observed on the bench on 30 aug 2026. Merging them into one
    # "build id" would pass the package version off as the loaded code.
    [[ -n "$src" ]] && out="loaded srcversion $src"
    if [[ -n "$pkg" ]]; then
        [[ -n "$out" ]] && out="$out; "
        out="${out}installed package $pkg"
    fi
    printf '%s' "$out"
}

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
        depmod -a "$kernel_ver" >/dev/null 2>&1 || \
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
    # CLIENT_DNS lives only in the file: without this reset a variable from root's
    # environment (CLIENT_DNS=... manage add) would silently reach new clients on
    # installs whose file has no such line yet.
    unset CLIENT_DNS

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
                AWG_H1|AWG_H2|AWG_H3|AWG_H4|AWG_I1|AWG_I2|AWG_I3|AWG_I4|AWG_I5|AWG_PRESET|NO_TWEAKS|NO_CPS|KEEP_PACKAGES|\
                AWG_APPLY_MODE|ALLOW_IPV6_TUNNEL|IPV6_SUBNET|SERVER_HAS_NATIVE_IPV6|PREV_AWG_PORT|CLIENT_ISOLATION|CLIENT_ISOLATION_NET|AWG_PROTOCOL|AWG_CPA|AWG_SERVER_NAME|CLIENT_DNS)
                    export "$key=$value"
                    ;;
            esac
        fi
    done < "$config_file"
}

# awg_installed_protocol : the INSTALLATION's generation, from the AWG_PROTOCOL
# marker in awgsetup_cfg.init (already loaded by safe_load_config). Prints '2.0'
# or '3.1'.
# 🔴 A missing field IS 2.0, not "unknown": that is what every install made
# before the marker existed looks like, and any other answer could silently
# change its generation. Any other value is a failure (code 1) with NO output
# and no quiet default: a corrupt marker on a third-line server would otherwise
# (once regen consults the marker) make regen hand out second-line profiles that
# silently fail to connect. The
# caller prints the error text: the function body is identical in all four
# copies (RU/EN, shared library/installer), and the parity test checks that.
# Optional argument: path to the init file. With it the file is checked
# fail-closed by one anchored grep without a pipeline (a pipeline under pipefail
# took SIGPIPE on a large file and switched the guard off): a line of the form
# "AWG_PROTOCOL =" in any case with an empty value (the field did not parse:
# indentation, spaces around '=', broken quotes; or it was written empty) is a
# corrupt marker, not a missing one; two or more such lines are corrupt too
# (which one is true cannot be guessed). Both fail, or a corrupt marker would
# quietly read as 2.0.
# 🔴 The pattern allows a leading BOM ON PURPOSE: safe_load_config parses such a
# line, so the guard has to see it too. Without that, a corrupt marker behind a
# BOM (a file that went through a Windows editor) did not match the pattern, the
# guard read the marker as absent and answered 2.0 - exactly the silent
# substitution it is written against. For the same reason a second marker line
# did not match when the first carried a BOM, so a duplicate passed as a single
# marker.
# 🔴 grep's exit codes are not interchangeable: 1 means no match (normal), 2 and
# above mean grep itself failed (a regular file that cannot be read). The
# former '|| n=0' form equated them and turned a failure into "no
# marker", that is, into a confident 2.0. A read error now refuses as well.
# 🔴 grep only ever gets a regular file (-f): on a FIFO it would wait for a
# writer forever, on /dev/zero it would read without end. A missing path and a
# non-regular file in place of the init never reach grep and read as "no
# marker", so the -f check must stay. In manage the live init of that kind never reaches
# the function: check_dependencies refuses it earlier. The installer treats it as
# absent at step 0 and calls the function with the same path; the -f check is
# what gives it 2.0 instead of a hang.
awg_installed_protocol() {
    local cfg="${1:-}" n=0 _rc=0 _bom=$'\xef\xbb\xbf'
    if [[ -n "$cfg" && -f "$cfg" ]]; then
        n=$(grep -ciE "^(${_bom})?[[:space:]]*(export[[:space:]]+)?AWG_PROTOCOL[[:space:]]*=" "$cfg")
        _rc=$?
        if [[ "$_rc" -ge 2 ]]; then
            return 1
        fi
        [[ "$_rc" -eq 0 ]] || n=0
        if [[ "$n" -gt 1 ]]; then
            return 1
        fi
    fi
    case "${AWG_PROTOCOL:-}" in
        "")
            if [[ "$n" -ge 1 ]]; then
                return 1
            fi
            echo "2.0" ;;
        2.0) echo "2.0" ;;
        3.1) echo "3.1" ;;
        *)   return 1 ;;
    esac
}

# _awg_generation_from_init <init> : the installation generation from
# the init file. Prints 2.0 or 3.1; a corrupt marker fails (status 1)
# with no output. The rules live in awg_installed_protocol, this only
# reads the file.
# 🔴 The subshell is required, and not only because of AWG_PROTOCOL:
# safe_load_config EXPORTS everything it parses, so a caller that
# merely asked for the generation would silently receive the port and
# the subnet FROM THE FILE too.
# The value to use when the marker is unreadable belongs to the
# caller: restore prints "?" and warns, the key check uses broken and
# fails only where a key exists.
_awg_generation_from_init() {
    local init="${1:-}"
    (
        AWG_PROTOCOL=""
        if [[ -f "$init" ]]; then
            safe_load_config "$init" >/dev/null 2>&1
        fi
        awg_installed_protocol "$init"
    )
}

# awg_restore_generation_notice <init from the backup> <live init>
# restore is an explicit action and brings back a consistent set (config + init
# + keys), so it does not forbid a generation change, but the change must not
# be silent either: when the generation in the backup differs from the current
# one, a warning is printed BEFORE the service is stopped, right after the
# backup completeness check, when the archive is already unpacked and the
# human can still abort the restore. A missing field reads as 2.0 (the
# awg_installed_protocol rule); a backup without the init itself gets its own
# warning (the marker then stays as it is, restore does not touch the file);
# an unreadable marker prints as "?" and always warns, even when the other
# side is unreadable too. Always returns 0: the restore is not interrupted,
# the warning stays in the log.
awg_restore_generation_notice() {
    local backup_init="$1" live_init="$2" backup_gen live_gen
    live_gen=$(_awg_generation_from_init "$live_init") || live_gen="?"
    if [[ ! -f "$backup_init" ]]; then
        log_warn "The backup has no awgsetup_cfg.init: the generation marker stays as it is (${live_gen}). After the restore compare it with the restored server config."
        return 0
    fi
    backup_gen=$(_awg_generation_from_init "$backup_init") || backup_gen="?"
    if [[ "$backup_gen" == "?" || "$live_gen" == "?" ]]; then
        log_warn "The generation marker AWG_PROTOCOL cannot be read (backup: ${backup_gen}, current installation: ${live_gen}; 2.0 and 3.1 are allowed). Check ${live_init} by hand after the restore."
    elif [[ "$backup_gen" != "$live_gen" ]]; then
        log_warn "Protocol generation in the backup: ${backup_gen}, in the current installation: ${live_gen}. After the restore the server will be generation ${backup_gen}; client profiles of the other generation will not connect to it."
    fi
    return 0
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
# load_awg_params_from_server_conf [config] : obfuscation parameters from the live config.
# The parse loop holds every [Interface] line in variables, PrivateKey and
# HeaderProtectionKey included, so the body runs with tracing off.
load_awg_params_from_server_conf() {
    _awg_xtrace_guard _load_awg_params_from_server_conf_body "$@"
}

_load_awg_params_from_server_conf_body() {
    local conf="${1:-$SERVER_CONF_FILE}"
    [[ -f "$conf" ]] || return 1

    # Local accumulation — all-or-nothing export at the end
    local _Jc="" _Jmin="" _Jmax=""
    local _S1="" _S2="" _S3="" _S4=""
    local _H1="" _H2="" _H3="" _H4=""
    local _I1="" _I2="" _I3="" _I4="" _I5="" _Port="" _MTU="" _CPA=""

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
            # Drop a trailing comment the way amneziawg-tools do (config_read_line
            # cuts the line at #). Otherwise a `# ...` tail would reach the client
            # config and vpn://, and the I1-I5 check never sees it.
            value="${value%%#*}"
            value="${value%"${value##*[![:space:]]}"}"
            # ContentPaddingAddition is optional and read case-insensitively, the way
            # amneziawg-tools read it: otherwise a lowercase entry would apply on the
            # server and never reach the client profiles.
            [[ "${key,,}" == contentpaddingaddition ]] && _CPA="$value"
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
    [[ -n "$_CPA"  ]] && export AWG_CPA="$_CPA"
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

    # Where the AWG parameters come from: the I1-I5 refusal names this file as
    # the place to fix. The init file by default; the live-config branch below
    # overrides it.
    _AWG_PARAMS_SOURCE="$CONFIG_FILE"

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
        unset AWG_I1 AWG_I2 AWG_I3 AWG_I4 AWG_I5 AWG_CPA
        if ! load_awg_params_from_server_conf; then
            log_error "$SERVER_CONF_FILE is missing required AWG parameters"
            log_error "(Jc/Jmin/Jmax/S1-S4/H1-H4). Refusing to use stale values from"
            log_error "$CONFIG_FILE, that would create a split-brain between server"
            log_error "and client configs. Restore the [Interface] section in"
            log_error "$SERVER_CONF_FILE or restore awg0.conf from a backup."
            return 1
        fi
        log_debug "AWG parameters loaded from $SERVER_CONF_FILE (live config)"
        _AWG_PARAMS_SOURCE="$SERVER_CONF_FILE"
    else
        # Bootstrap: server config does not exist yet (first install).
        # AWG_* must be in env via safe_load_config above.
        log_debug "$SERVER_CONF_FILE missing — using AWG params from $CONFIG_FILE (bootstrap)"
    fi

    # 2a. Header protection key - before any rendering. The check also runs on the
    # CLI override branch, which does not read parameters from the live config: the
    # key in it does not go away because of that. While there is no config yet (first
    # install), step 6 of the installer checks in install mode, the only one allowed
    # to create a key.
    if [[ -f "$SERVER_CONF_FILE" ]]; then
        awg_hpk_ensure manage || return 1
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
    # 4. Safety of I1-I5, whatever the source. From here the parameters go into
    # the server config and the client profiles: generate_client,
    # regenerate_client and render_server_config fail on a refusal, while modify
    # builds no vpn:// and has already removed the previous file before the edit.
    # A dangerous value typed into awg0.conf by hand or carried in with
    # someone else's config stops here instead of being handed to clients.
    # ⚠️ The boundary: paths that apply the awg0.conf already in place do not
    # call this function and do not check I1-I5: the apply after remove and the
    # expiry cron, manage restart, repair-module, the restore rollback, systemctl
    # restart and the start at boot. The refusal does not block them, and it
    # does not protect them either.
    # ⚠️ One exception: when render_server_config calls us, it runs the check
    # itself, AFTER --no-cps clears I1. Otherwise a reinstall with --no-cps -
    # the documented way to remove I1 - would be refused because of the very I1
    # it removes. The deferral is tied to the NAME of the direct caller, not to
    # a variable: a variable can be inherited from the environment and silently
    # switch the check off. Client paths do not honour NO_CPS, so they get no
    # deferral.
    if [[ "${FUNCNAME[1]:-}" != "render_server_config" ]]; then
        awg_cps_refuse_unsafe || return 1
    fi
    return 0
}

# Warn when awgsetup_cfg.init disagrees with the live awg0.conf (issue #196).
#
# After the install, awg0.conf is the only source of the obfuscation parameters,
# and the init file is read for them only during the bootstrap of a first
# install (see load_awg_params above). Editing AWG_* in the init file afterwards
# has no effect on clients, and until this check it was ignored SILENTLY: the
# file is named like the installation config, so someone edits it and gets no
# hint that the answer lives elsewhere.
#
# The modification-time gate removes false positives on the supported path.
# The recommended way to tune (edit [Interface] in awg0.conf, then regen) also
# makes the two files disagree, but nothing rewrites the init file after the
# install, so there it stays OLDER than the live config. We warn only when the
# init file was touched LATER than awg0.conf, which is the "edited init, nothing
# happened" case.
#
# Deliberately not hooked into load_awg_params: the installer calls that on
# step 6, where the init file is necessarily newer than an awg0.conf that has
# not been rewritten yet, and the warning would surface mid-install.
_AWG_DRIFT_KEYS=(AWG_Jc AWG_Jmin AWG_Jmax AWG_S1 AWG_S2 AWG_S3 AWG_S4 \
                 AWG_H1 AWG_H2 AWG_H3 AWG_H4 AWG_I1 AWG_I2 AWG_I3 AWG_I4 AWG_I5 AWG_CPA)

# _awg_drift_dump <init|live> <file>: one line per key in the order of the array
# above, so the dumps of the two sources compare line by line. Read in a subshell
# to leave the caller's environment alone - the function can be called at any
# point without the risk of clobbering already loaded parameters.
_awg_drift_dump() {
    local mode="$1" src="$2"
    (
        # Clear inherited values: otherwise a key missing from the source would
        # look equal to whatever is already in the environment. If clearing
        # fails (the variable is readonly in the calling environment) there is
        # nothing to compare, so leave without the marker.
        unset "${_AWG_DRIFT_KEYS[@]}" 2>/dev/null || exit 1
        if [[ "$mode" == "init" ]]; then
            safe_load_config "$src" >/dev/null 2>&1 || exit 1
        else
            load_awg_params_from_server_conf "$src" >/dev/null 2>&1 || exit 1
        fi
        # Success marker on the first line: mapfile does not expose the exit
        # status of the producing process, so without it a parser failure is
        # indistinguishable from a set of empty values.
        printf 'ok\n'
        local k
        for k in "${_AWG_DRIFT_KEYS[@]}"; do
            printf '%s\n' "${!k:-}"
        done
    )
}

warn_awg_init_drift() {
    local init="${CONFIG_FILE:-}" live="${SERVER_CONF_FILE:-}"
    [[ -n "$init" && -n "$live" ]] || return 0
    [[ -f "$init" && -f "$live" ]] || return 0
    # The init file is not newer than the live one, so any disagreement was
    # created by editing awg0.conf itself, which is the supported path. Stay quiet.
    [[ "$init" -nt "$live" ]] || return 0

    local -a ivals lvals
    mapfile -t ivals < <(_awg_drift_dump init "$init")
    mapfile -t lvals < <(_awg_drift_dump live "$live")
    # Without the marker the comparison is not trustworthy: one of the sources
    # failed to parse. Stay quiet instead of declaring every key as differing -
    # load_awg_params will name the real cause (an incomplete [Interface], say).
    [[ "${ivals[0]:-}" == "ok" && "${lvals[0]:-}" == "ok" ]] || return 0

    local drift="" i
    for i in "${!_AWG_DRIFT_KEYS[@]}"; do
        [[ "${ivals[i+1]:-}" == "${lvals[i+1]:-}" ]] || drift+="${_AWG_DRIFT_KEYS[i]#AWG_} "
    done
    [[ -n "$drift" ]] || return 0

    log_warn "$init was modified later than $live, and their obfuscation parameters disagree: ${drift% }"
    log_warn "The values from $live are the ones in effect - after the install it is the only source of these parameters. If you edited them in $init, the edit will not reach clients: change the [Interface] section in $live instead, then restart awg-quick@awg0 and regen the clients you need."
    return 0
}

# ==============================================================================
# Key generation
# ==============================================================================

# Generate keypair (private + public)
# generate_keypair <name>
# Result: keys/<name>.private, keys/<name>.public
generate_keypair() {
    case $- in *x*) _awg_xtrace_guard generate_keypair "$@"; return ;; esac
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
    case $- in *x*) _awg_xtrace_guard generate_server_keys; return ;; esac
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
    case $- in *x*) _awg_xtrace_guard _ensure_server_public_key; return ;; esac
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

# _mask_report_secrets : the secrets filter for everything that goes to the screen
# or the log from awg show and configs. A copy of the installer's filter: there it
# has to work without the downloaded library (--diagnostic), here it serves manage
# check, show, diagnose and the service status text in check and on a failed restore or restart. The body is the same in all four copies, and a parity
# test checks that; the rules and the five upstream string literals are explained
# in the installer's comment.
_mask_report_secrets() {
    sed -E \
        -e 's/^([[:space:]]*#?[[:space:]]*(PrivateKey|PresharedKey|HeaderProtectionKey)[[:space:]]*=[[:space:]]*).*/\1[HIDDEN]/I' \
        -e 's/^([[:space:]]*(private key|preshared key|header protection key)[[:space:]]*:[[:space:]]*).*/\1(hidden)/I' \
        -e 's/(Line unrecognized:[[:space:]]*.?(PrivateKey|PresharedKey|HeaderProtectionKey|PublicKey|ListenPort|FwMark|Jc|Jmin|Jmax|S[1-4]|H[1-4]|I[1-5]|ContentPaddingAddition|RekeyAfterTime|RekeyTimeout|RejectAfterTime|KeepaliveTimeout|MaxHandshakeAttempts|RandomTrailers|DisableCookies|Endpoint|AllowedIPs|PersistentKeepalive|AdvancedSecurity)[[:space:]]*=[[:space:]]*).*/\1[HIDDEN]/I' \
        -e '/\[HIDDEN\]/!s/(Line unrecognized:[[:space:]]*).*/\1[HIDDEN]/I' \
        -e 's/(Key is not the correct length or format:[[:space:]]*).*/\1[HIDDEN]/I' \
        -e "s|(Unable to parse IP address:[[:space:]]*\`)[^.:']*'|\1[HIDDEN]'|I" \
        -e "s|\`[A-Za-z0-9+/]{20,}={0,2}'|\`[HIDDEN]'|g"
}

# awg_hpk_path : path to the header protection key (HeaderProtectionKey) file.
# One place, and only from the current AWG_DIR: the path is not stored in init,
# or a second source of the path would have to be reconciled with this one every
# time a backup moves.
awg_hpk_path() {
    [[ -n "${AWG_DIR:-}" ]] || return 1
    printf '%s\n' "$AWG_DIR/server_hpk.key"
}

# _awg_xtrace_guard <function> [args] : call a function that holds a secret with
# tracing off, then restore the previous state and return the function's status.
# The installer turns set -x on for the whole run under --verbose, and any
# assignment of the key value would land in stderr. Contract limits: the
# arguments are traced BEFORE tracing goes off, so pass only non-secret ones; the
# body does not exit or die, only return, or tracing stays off; the body does not
# print the secret to stdout for a caller's $( ).
# Functions that hold keys themselves (key generation, server config rendering,
# client creation and regeneration, add_peer_to_server, vpn://, apply_config
# and the manage functions that read keys or the service status) start with a
# self-guard line:
#     case $- in *x*) _awg_xtrace_guard <own name> "$@"; return ;; esac
# (without "$@" in a function that takes no arguments).
# Under tracing the function calls itself once more with tracing off, so the
# body runs once; the function name and FUNCNAME[1] of nested calls are kept.
# A function with a secret argument cannot do this: the self-guard line prints
# its arguments. Exception to the no-die rule: modify_client ends the process
# through die on some refusals; tracing is not restored there, but the process
# exits anyway.
# The body runs under `||` (under tracing for functions with the self-guard
# line, always for wrappers of the form `_awg_xtrace_guard _..._body`), so
# set -e and an ERR trap do not apply inside it. The entry points that load
# this library turn neither on, and the installer calls these functions under
# `||`; if set -e is ever added, revisit this.
_awg_xtrace_guard() {
    local _xt=0 _rc=0
    case $- in *x*) _xt=1; set +x ;; esac
    "$@" || _rc=$?
    if (( _xt )); then set -x; fi
    return "$_rc"
}

# _awg_hpk_file_valid <file> : the key file is exactly one LF-terminated line, and
# that line is a key in amneziawg-tools key_from_base64 form (44 characters, '=' at
# the end, the last significant character carries zero low bits). CRLF, an empty
# file, a second line, a directory or a symlink are not a key. The first line is
# read into an internal variable (only bodies under _awg_xtrace_guard call this):
# read fails without a terminating LF, and a size of exactly 45 bytes rules out a
# tail or a second line after the key. The line never reaches argv.
_awg_hpk_file_valid() {
    local f="$1" n _hv_line
    [[ -f "$f" && ! -L "$f" && -r "$f" ]] || return 1
    IFS= read -r _hv_line < "$f" || return 1
    [[ "$_hv_line" =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]] || return 1
    n=$(wc -c < "$f") || return 1
    [[ "$n" -eq 45 ]]
}

# awg_generate_hpk : create the key file if it does not exist. The key is the output
# of `awg genkey` (the Amnezia app generates this key the same way as a WireGuard
# private key), written STRAIGHT into a temporary file: the value never passes
# through variables or argv. An existing file is left alone. The final name appears
# through ln, which refuses when the file already exists: no window in which
# someone else's key could be overwritten.
# When no key file exists but a server config does, refuses: a new key appears only
# on a first install, before the config is written. Production code does not call
# this wrapper: awg_hpk_ensure calls _awg_generate_hpk_body inside its trace guard.
awg_generate_hpk() {
    _awg_xtrace_guard _awg_generate_hpk_body
}

_awg_generate_hpk_body() {
    local key tmp state
    key=$(awg_hpk_path) || { log_error "Error: AWG_DIR is not set, not creating the header protection key"; return 1; }
    state=$(_awg_hpk_file_state "$key")
    case "$state" in
        ok)     return 0 ;;
        absent) ;;
        *)      _awg_hpk_file_refuse "$key" "$state"; return 1 ;;
    esac
    if [[ -f "$SERVER_CONF_FILE" ]]; then
        local _hs_any=0 _hs_if=0 _hs_out=0 _hs_val=""
        _awg_hpk_conf_scan "$SERVER_CONF_FILE" || { log_error "Error: could not parse $SERVER_CONF_FILE, not creating a new header protection key"; return 1; }
        if (( _hs_any > 0 )); then
            log_error "Error: HeaderProtectionKey is already in $SERVER_CONF_FILE, not creating a new key"
            return 1
        fi
        log_error "Error: $SERVER_CONF_FILE already exists without HeaderProtectionKey, not creating a new key over an existing config"
        return 1
    fi
    mkdir -p "$AWG_DIR" || return 1
    tmp=$(awg_mktemp "$AWG_DIR") || {
        log_error "Error: could not generate the header protection key: no temporary file in $AWG_DIR"
        return 1
    }
    if ! ( umask 077; awg genkey > "$tmp" ); then
        rm -f "$tmp"
        log_error "Error: could not generate the header protection key (awg genkey)"
        return 1
    fi
    if ! _awg_hpk_file_valid "$tmp"; then
        rm -f "$tmp"
        log_error "Error: awg genkey returned a value that is not a key, the key file was not written"
        return 1
    fi
    if ! chmod 600 "$tmp" || ! ln -T "$tmp" "$key" 2>/dev/null; then
        rm -f "$tmp"
        log_error "Error: could not save the header protection key to $key"
        return 1
    fi
    rm -f "$tmp"
    log "Header protection key created: $key"
    return 0
}

# _awg_hpk_conf_scan <config> : the HeaderProtectionKey lines of a config, parsed the
# same way the validator parses them (key and section case-insensitive, comment and
# whitespace dropped). Prints no value: it sets variables declared local in the
# caller - _hs_any (lines in any section), _hs_if (in [Interface]), _hs_out (outside
# it, including lines before the first header), _hs_val (value of the last line in
# [Interface]). A parse failure returns 1.
_awg_hpk_conf_scan() {
    local _pairs _sec _k _v
    _hs_any=0; _hs_if=0; _hs_out=0; _hs_val=""
    _pairs=$(_awg_conf_pairs "$1") || return 1
    while IFS=$'\t' read -r _sec _k _v; do
        [[ "$_k" == headerprotectionkey ]] || continue
        _hs_any=$((_hs_any + 1))
        if [[ "$_sec" == interface ]]; then
            _hs_if=$((_hs_if + 1))
            _hs_val="$_v"
        else
            _hs_out=$((_hs_out + 1))
        fi
    done <<< "$_pairs"
    return 0
}

# _awg_hpk_file_state <file> : absent, notregular (a directory or a symlink),
# unreadable, damaged or ok. "Cannot be read" and "absent" stay apart: a read error
# must not turn into a quiet absence after which the file would be overwritten.
_awg_hpk_file_state() {
    local f="$1"
    if [[ -L "$f" ]]; then echo notregular; return 0; fi
    if [[ ! -e "$f" ]]; then echo absent; return 0; fi
    if [[ ! -f "$f" ]]; then echo notregular; return 0; fi
    if [[ ! -r "$f" ]]; then echo unreadable; return 0; fi
    if _awg_hpk_file_valid "$f"; then echo ok; else echo damaged; fi
    return 0
}

# _awg_hpk_write_value <file> : write the caller's _hs_val through a temporary file:
# builtin printf (the value stays out of argv), form check, mode 600, ln onto the
# final name without overwriting an existing one.
_awg_hpk_write_value() {
    local key="$1" tmp
    tmp=$(awg_mktemp "$AWG_DIR") || return 1
    if ! printf '%s\n' "$_hs_val" > "$tmp" || ! _awg_hpk_file_valid "$tmp" \
        || ! chmod 600 "$tmp" || ! ln -T "$tmp" "$key" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
    return 0
}

_awg_hpk_file_refuse() {
    case "$2" in
        notregular) log_error "The key file $1 is not a regular file (a directory or a symlink): the header protection key cannot be checked" ;;
        unreadable) log_error "The key file $1 cannot be read" ;;
        *)          log_error "The key file $1 is damaged: one line with the key is expected" ;;
    esac
}

# awg_hpk_ensure <install|manage> : header protection key consistency before any
# profile is rendered. awg0.conf is the source of truth, server_hpk.key its copy.
#   - the marker is read from init afresh in a subshell: an AWG_PROTOCOL variable
#     left in the environment by an earlier load must not decide;
#   - a 2.0 installation with a key in the config (in any section) is refused:
#     rendering would issue profiles without the key, which silently do not connect;
#     a leftover key file is a warning;
#   - 3.1: the config key is checked the validator's way (one line in [Interface],
#     key form); a lost file is restored from the config and NEVER replaced by a new
#     key; a differing file is refused and left alone;
#   - a new key is created only in install mode and only while the server config does
#     not exist yet (first install); never over an existing config.
# Limits: the live interface is not checked (the key sticks to it), and manage
# restore is not protected by this check.
awg_hpk_ensure() {
    _awg_xtrace_guard _awg_hpk_ensure_body "$@"
}

_awg_hpk_ensure_body() {
    local mode="${1:-}" key gen state _line
    local _hs_any=0 _hs_if=0 _hs_out=0 _hs_val=""
    case "$mode" in
        install|manage) ;;
        *) log_error "awg_hpk_ensure: mode install or manage is required"; return 1 ;;
    esac
    key=$(awg_hpk_path) || { log_error "AWG_DIR is not set: the header protection key is not checked"; return 1; }
    gen=$(_awg_generation_from_init "$CONFIG_FILE") || gen=broken
    if [[ -f "$SERVER_CONF_FILE" ]]; then
        _awg_hpk_conf_scan "$SERVER_CONF_FILE" || { log_error "Could not parse $SERVER_CONF_FILE: the header protection key is not checked"; return 1; }
    fi

    # A broken marker matters only where a key exists. Without a key the installation
    # behaves as 2.0 did before the marker existed, and add or regen must not fail over an init edit.
    if [[ "$gen" == broken ]]; then
        if (( _hs_any > 0 )) || [[ -e "$key" || -L "$key" ]]; then
            log_error "The generation marker AWG_PROTOCOL in $CONFIG_FILE cannot be read (allowed values are 2.0 and 3.1): the header protection key is not checked"
            return 1
        fi
        log_warn "The generation marker AWG_PROTOCOL in $CONFIG_FILE cannot be read (allowed values are 2.0 and 3.1): the header protection key is not checked"
        return 0
    fi

    if [[ "$gen" != "3.1" ]]; then
        if (( _hs_any > 0 )); then
            log_error "HeaderProtectionKey (third line) is set in $SERVER_CONF_FILE, but the installation is marked as generation 2.0: profiles without the key will not connect. Check the AWG_PROTOCOL marker in $CONFIG_FILE or remove the key from the config"
            return 1
        fi
        if [[ -e "$key" || -L "$key" ]]; then
            log_warn "$key is not used: the installation is marked as generation 2.0"
        fi
        return 0
    fi

    if [[ ! -f "$SERVER_CONF_FILE" ]]; then
        if [[ "$mode" != install ]]; then
            log_error "The installation is marked as generation 3.1, but the server config does not exist ($SERVER_CONF_FILE): the header protection key cannot be checked"
            return 1
        fi
        state=$(_awg_hpk_file_state "$key")
        case "$state" in
            absent) _awg_generate_hpk_body; return ;;
            ok)     return 0 ;;
            *)      _awg_hpk_file_refuse "$key" "$state"; return 1 ;;
        esac
    fi

    if (( _hs_out > 0 )); then
        log_error "HeaderProtectionKey is set outside the [Interface] section in $SERVER_CONF_FILE"
        return 1
    fi
    if (( _hs_if > 1 )); then
        log_error "HeaderProtectionKey is set ${_hs_if} times in [Interface] in $SERVER_CONF_FILE: keep a single key"
        return 1
    fi
    state=$(_awg_hpk_file_state "$key")
    if (( _hs_if == 0 )); then
        if [[ "$state" == absent ]]; then
            log_error "The installation is marked as generation 3.1, but there is no HeaderProtectionKey in $SERVER_CONF_FILE or in $key: profiles cannot be issued"
        else
            log_error "HeaderProtectionKey was removed from $SERVER_CONF_FILE, but the key file $key exists: put the key back into the config or restore the config from a backup"
        fi
        return 1
    fi
    if ! [[ "$_hs_val" =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]]; then
        log_error "HeaderProtectionKey in $SERVER_CONF_FILE does not look like a key: it must be 32 bytes in base64, 44 characters"
        return 1
    fi
    case "$state" in
        absent)
            if ! _awg_hpk_write_value "$key"; then
                log_error "Error: could not restore the header protection key file $key"
                return 1
            fi
            log "Header protection key file restored from $SERVER_CONF_FILE: $key"
            return 0
            ;;
        ok)
            if ! IFS= read -r _line < "$key"; then
                log_error "The key file $key cannot be read"
                return 1
            fi
            [[ "$_line" == "$_hs_val" ]] && return 0
            log_error "The key in $key does not match HeaderProtectionKey in $SERVER_CONF_FILE: a manual edit or a failed restore. Decide by hand which one is right"
            return 1
            ;;
        *)
            _awg_hpk_file_refuse "$key" "$state"
            return 1
            ;;
    esac
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

# _awg31_append_profile_lines <file> : append the third-line profile lines -
# HeaderProtectionKey and ContentPaddingAddition - to [Interface].
# On a 2.0 installation it does nothing and returns 0: the 2.0 path is unchanged.
# With an unreadable marker and no key file it writes nothing either (the rule
# of awg_hpk_ensure).
# 🔴 The key value never passes through argv and never reaches the trace: this
# function is guarded, and the file is read through a redirect. The client
# renderer itself is unguarded (the client key arrives as an argument; its
# callers generate_client and regenerate_client are guarded), so reading the key
# there would leak it under --verbose.
# The value comes from the key file. It is NOT compared with the server config
# here: with an existing awg0.conf both renderers go through load_awg_params,
# which calls awg_hpk_ensure, and that already catches a file/config
# disagreement and names it. On a first install there is no config yet, and
# awg_hpk_ensure install in step 6 keeps them consistent. A second check of the
# same thing would be dead code pretending to be a second guard.
_awg31_append_profile_lines() {
    _awg_xtrace_guard _awg31_append_profile_lines_body "$@"
}

_awg31_append_profile_lines_body() {
    local target="$1" gen keyfile key why cpa
    # An unreadable marker follows the rule of awg_hpk_ensure: without a key it is
    # no reason to take add and regen away over an edit of the init, the third-line
    # lines are simply not written; with a key file the generation cannot be
    # guessed, and that is a refusal.
    if ! gen=$(_awg_generation_from_init "$CONFIG_FILE"); then
        keyfile=$(awg_hpk_path) || { log_error "AWG_DIR is not set: the header protection key was not checked"; return 1; }
        if [[ -e "$keyfile" || -L "$keyfile" ]]; then
            log_error "The generation marker AWG_PROTOCOL in $CONFIG_FILE cannot be read (2.0 and 3.1 are allowed) while the key file $keyfile exists: the config was not written"
            return 1
        fi
        return 0
    fi
    [[ "$gen" == "3.1" ]] || return 0
    keyfile=$(awg_hpk_path) || { log_error "AWG_DIR is not set: the header protection key cannot be read"; return 1; }
    if [[ ! -f "$keyfile" ]]; then
        log_error "The installation is marked generation 3.1 but the key file $keyfile is missing: a profile without the key would not connect, the config was not written"
        return 1
    fi
    IFS= read -r key < "$keyfile" || { log_error "The key file $keyfile cannot be read: the config was not written"; return 1; }
    if ! [[ "$key" =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]]; then
        log_error "The key file $keyfile does not look like a key: 32 bytes in base64, 44 characters are required"
        return 1
    fi
    # Write exactly the value that was checked: awg_cpa_check_safe drops a comment
    # and spaces the way the tools do, while in the config, and further in the
    # vpn:// link, they would become part of the value.
    cpa="${AWG_CPA:-}"
    cpa="${cpa%%#*}"
    cpa="${cpa//[[:space:]]/}"
    why=$(awg_cpa_check_safe "$cpa") || {
        log_error "ContentPaddingAddition: ${why}. The config was not written"
        return 1
    }
    printf 'HeaderProtectionKey = %s\n' "$key" >> "$target" || {
        log_error "Failed to write the header protection key into the config"
        return 1
    }
    printf 'ContentPaddingAddition = %s\n' "$cpa" >> "$target" || {
        log_error "Failed to write ContentPaddingAddition into the config"
        return 1
    }
    return 0
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
    case $- in *x*) _awg_xtrace_guard render_server_config "$@"; return ;; esac
    local peers_source="${1:-}"
    load_awg_params || return 1

    # --no-cps (issue #159): load_awg_params re-reads I1 from the live awg0.conf
    # on a reinstall. When NO_CPS=1 clear I1 intentionally, otherwise the server
    # config would silently restore CPS against the flag.
    if grep -qE '^[[:space:]]*(export[[:space:]]+)?NO_CPS=1' "$CONFIG_FILE" 2>/dev/null; then
        AWG_I1=''
    fi
    # I1-I5 are checked here, AFTER --no-cps: load_awg_params deferred the check
    # for us (see step 4 there), otherwise a reinstall with --no-cps would be
    # refused because of the very I1 it removes.
    awg_cps_refuse_unsafe || return 1

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

    # Client isolation (issue #178): DROP awg0->awg0 before the general ACCEPT.
    # PostUp runs left to right, -I inserts at the head of the chain - so a
    # rule added ON A LATER LINE ends up HIGHER IN THE CHAIN, which is why the
    # DROP is appended at the end of postup. Before -I we drain stale copies
    # with a -D loop: after a failed PostDown a DROP copy would otherwise pile
    # up on every up (PR #179 review). A drain, deliberately not -C: by this
    # point the stale copy sits BELOW the freshly inserted ACCEPT, -C would
    # find it, skip the insert - and awg0->awg0 traffic would hit ACCEPT
    # (isolation silently broken). PostDown uses '2>/dev/null || true':
    # after an on->off reinstall the rule is not in the running set, and a
    # failing -D must not fail awg-quick down (the down phase of restart already
    # runs against the new config). Unset CLIENT_ISOLATION = 1: configs from
    # before v5.20 are isolated.
    if [[ "${CLIENT_ISOLATION:-1}" -eq 1 ]]; then
        postup="${postup}; while iptables -D FORWARD -i %i -o %i -j DROP 2>/dev/null; do :; done; iptables -I FORWARD -i %i -o %i -j DROP"
        postdown="${postdown}; iptables -D FORWARD -i %i -o %i -j DROP 2>/dev/null || true"
    fi

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
        # Isolation for the IPv6 tunnel too: without the DROP, dual-stack
        # clients in split modes can reach each other over fddd::/64
        # (IPV6_SUBNET is already in their AllowedIPs via render_client_config)
        # - issue #178.
        if [[ "${ALLOW_IPV6_TUNNEL:-0}" -eq 1 && "${CLIENT_ISOLATION:-1}" -eq 1 ]]; then
            postup="${postup}; while ip6tables -D FORWARD -i %i -o %i -j DROP 2>/dev/null; do :; done; ip6tables -I FORWARD -i %i -o %i -j DROP"
            postdown="${postdown}; ip6tables -D FORWARD -i %i -o %i -j DROP 2>/dev/null || true"
        fi
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
    _awg31_append_profile_lines "$tmpfile" || { rm -f "$tmpfile"; return 1; }

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

# Warn that a list value was given on several lines and they were joined.
# Staying silent here is not an option: joining changes what the user typed by
# hand, and if they made a mistake they should hear it from us, not from the
# client.
_awg_warn_multiline() {
    local raw="$1" key="$2" name="$3" n
    n=$(printf '%s\n' "$raw" | grep -c '[^[:space:]]') || n=0
    (( n > 1 )) && log_warn "'${key}' of client '${name}' is given on ${n} lines - the values were joined into one."
    return 0
}

# Normalise a comma-separated list to the canonical "a, b, c" form.
#
# Why: the installer writes AllowedIPs and DNS with a space after each comma,
# while regenerate_client read those values through `tr -d '[:space:]'` and
# wrote what it had read straight back, so the very first regen left a
# collapsed list in .conf (D#38 @humowns). Here the list is split per element
# and the separator is rebuilt canonically, so a repeated regen REPAIRS configs
# that were already damaged.
#
# 🔴 Do NOT apply this to the value that feeds the allowed_ips JSON array in the
# vpn:// builder (see the comment at generate_vpn_uri): that one needs the
# COMPACT form. One revision of this very fix did normalise it there, and on a
# test server that put a leading space inside 33 of the 34 array elements.
#
# Whitespace is stripped INSIDE each element, not only at its edges: elements of
# these two lists (CIDRs and resolver addresses) never contain spaces, and the
# `manage modify` validator cleans them the same way, via `${tok//[[:space:]]/}`.
# That also repairs values like "1.1.1. 1", which the old `tr` cleaned by luck.
#
# Split via `read -a` rather than `for x in $raw` so the value is not subject to
# glob expansion. The trim is inline rather than a function call: a substitution
# per element forks a subshell, and on a 2000-entry list that is 18 seconds
# against 0.1 - while regen without a name walks every client at once.
#
# ⚠️ Contract: the input is SINGLE-LINE. `read` without `-d` would take only the
# first line, so a multi-line value must be joined by the caller (`paste -sd, -`).
awg_normalize_csv() {
    local out="" item
    local -a parts
    IFS=',' read -r -a parts <<< "$1"
    for item in "${parts[@]}"; do
        item="${item//[[:space:]]/}"
        [[ -z "$item" ]] && continue
        out+="${out:+, }$item"
    done
    printf '%s' "$out"
}

# Validation of an AllowedIPs list as a client-config value (Issue #253).
# Dangerous characters cut off + a positive per-token CIDR check (IPv4/IPv6
# with an optional /n prefix) + no empty items (leading/trailing/double
# comma). The original caller is modify (the validation historically lived
# inline in its dispatcher, C5); since Issue #253 the helper is the single
# point for the early validation of `manage add --allowed-ips` (before the
# first client is created) and for the defense-in-depth check in
# generate_client (the CLIENT_ALLOWED_IPS env contract).
# Parsing uses read -a with a quoted walk, not `for x in $value`: an
# unquoted loop expands pathnames (a file named "10.0.0.0" in the current
# directory let the value "10.0.0.*" through) - the same reason
# awg_normalize_csv parses into an array.
awg_validate_allowed_ips_list() {
    local value="$1"
    case "$value" in
        *$'\n'*|*$'\r'*|*\\*|*\"*|*\'*|"")
            log_error "Invalid AllowedIPs: '$value'"
            return 1 ;;
    esac
    case "$value" in
        ,*|*,|*,,*)
            log_error "Invalid AllowedIPs '$value': empty list item (extra comma)"
            return 1 ;;
    esac
    local -a _aip_parts
    local _aip_tok
    IFS=',' read -r -a _aip_parts <<< "$value"
    for _aip_tok in "${_aip_parts[@]}"; do
        _aip_tok="${_aip_tok//[[:space:]]/}"
        if [[ -z "$_aip_tok" ]]; then
            log_error "Invalid AllowedIPs '$value': empty list item (extra comma)"
            return 1
        fi
        if ! _valid_cidr "$_aip_tok"; then
            log_error "Invalid AllowedIPs '$value': '$_aip_tok' does not look like a CIDR (IPv4/IPv6 with an optional /n prefix)"
            return 1
        fi
    done
    return 0
}

# Validate a DNS list for a client config: IPv4/IPv6 only, comma-separated, no
# host names, no empty items. One place for `manage modify DNS` and for CLIENT_DNS
# from awgsetup_cfg.init (two inline copies drift, see the AllowedIPs note above).
# Parsed with read -a, not `for x in $value`: the old loop in modify expanded globs,
# so "1.1.1.*" passed whenever a file named 1.1.1.1 sat in the current directory.
awg_validate_dns_list() {
    local value="$1" tok
    local -a parts
    case "$value" in
        *$'\n'*|*$'\r'*|*\\*|*\"*|*\'*|"")
            log_error "Invalid DNS: '$value'"
            return 1 ;;
    esac
    case "$value" in
        ,*|*,|*,,*)
            log_error "Invalid DNS '$value': empty list element (stray comma)"
            return 1 ;;
    esac
    IFS=',' read -r -a parts <<< "$value"
    for tok in "${parts[@]}"; do
        tok="${tok//[[:space:]]/}"
        if [[ -z "$tok" ]]; then
            log_error "Invalid DNS '$value': empty list element (stray comma)"
            return 1
        fi
        if ! _valid_ipv4 "$tok" && ! _valid_ipv6 "$tok"; then
            log_error "Invalid DNS '$value': '$tok' is not a valid IPv4/IPv6 address"
            return 1
        fi
    done
    return 0
}

# DNS for a NEW client config: CLIENT_DNS from awgsetup_cfg.init, otherwise the
# old "1.1.1.1, 1.0.0.1". An invalid value fails loudly instead of silently falling
# back: someone who wrote in their own resolver would otherwise get clients on
# Cloudflare and never know. Existing clients are not affected: regen keeps their
# DNS from the current .conf.
awg_client_dns() {
    if [[ -z "${CLIENT_DNS:-}" ]]; then
        printf '%s' "1.1.1.1, 1.0.0.1"
        return 0
    fi
    if ! awg_validate_dns_list "$CLIENT_DNS"; then
        log_error "CLIENT_DNS in $CONFIG_FILE is invalid ('$CLIENT_DNS'). Fix the value (IPs separated by commas) or remove the line to get 1.1.1.1, 1.0.0.1."
        return 1
    fi
    awg_normalize_csv "$CLIENT_DNS"
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
#       full tunnel (_is_full_tunnel, modes 1 and 2): + ::/0 (native) or + <IPV6_SUBNET> (no-native)
#       split tunnel (mode 3):               IPv4 list UNCHANGED + ONLY <IPV6_SUBNET>,
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

    # DNS of the new client: CLIENT_DNS or the default. Computed BEFORE the tmpfile,
    # so an invalid CLIENT_DNS never leaves a half-written config behind.
    # regenerate_client with a live .conf passes the client's DNS in _AWG_KEEP_DNS:
    # CLIENT_DNS is then not needed and not checked, so a typo in it cannot block
    # regen of clients it does not concern.
    local client_dns
    if [[ -n "${_AWG_KEEP_DNS:-}" ]]; then
        client_dns="$_AWG_KEEP_DNS"
    else
        client_dns=$(awg_client_dns) || return 1
    fi

    local conf_file="$AWG_DIR/${name}.conf"
    # Route base: the client's own override (CLIENT_ALLOWED_IPS, Issue #253)
    # or the server-wide mode (ALLOWED_IPS from awgsetup_cfg.init).
    local _aip_base="${CLIENT_ALLOWED_IPS:-${ALLOWED_IPS:-0.0.0.0/0}}"
    local allowed_ips
    if [[ -n "$client_ipv6" ]]; then
        # Dual-stack: mirror the IPv4 routing intent into IPv6.
        # full tunnel (IPv4=0.0.0.0/0) -> ::/0 (native) or tunnel ULA (no-native).
        # split tunnel -> IPv4 split AS-IS + ONLY tunnel ULA, never ::/0 (no
        # IPv6 split-list, must not hijack all IPv6).
        # An override carrying explicit IPv6 tokens is not mirrored on top of
        # itself: the user has spelled out both families - the same rule by
        # which regen leaves the IPv6 part of custom lists untouched. The gate
        # keys on the OVERRIDE itself, not on the merged base: awgsetup_cfg.init
        # is hand-editable and the global list may carry IPv6 tokens - such a
        # list goes through mirroring as always (the dedup below stays live for
        # it), otherwise a dual-stack client silently loses its route to the
        # tunnel subnet.
        if [[ -n "${CLIENT_ALLOWED_IPS:-}" && "$CLIENT_ALLOWED_IPS" == *:* ]]; then
            allowed_ips="$_aip_base"
        else
            local ipv4_part ipv6_part
            ipv4_part="$_aip_base"
            if _is_full_tunnel "$ipv4_part" && [[ "${SERVER_HAS_NATIVE_IPV6:-0}" == "1" ]]; then
                ipv6_part="::/0"
            else
                ipv6_part="${IPV6_SUBNET:-fddd:2c4:2c4:2c4::/64}"
            fi
            # Defensive de-dup: do not duplicate ipv6_part if it is already
            # present as a token in the list (reachable for a global list with
            # IPv6 tokens from a hand-edited awgsetup_cfg.init).
            case ",${ipv4_part// /}," in
                *",${ipv6_part},"*) allowed_ips="$ipv4_part" ;;
                *)                  allowed_ips="${ipv4_part}, ${ipv6_part}" ;;
            esac
        fi
    else
        allowed_ips="$_aip_base"
        # iOS AmneziaVPN in "all traffic" mode requires both address families:
        # with a bare 0.0.0.0/0 it treats the config as incomplete split routing
        # and refuses to bring the tunnel up. For a full tunnel we add an IPv6
        # route: ::/0 with 0.0.0.0/0 (mode 1), 2000::/3 with the sink address
        # for the mode-2 list (see _append_ipv6_full_tunnel_route). IPv6 goes
        # into the tunnel (and is dropped if the server has no native IPv6), so
        # it never leaks past the VPN. A full tunnel is decided by route
        # coverage, so both mode 1 and mode 2 land here; split routing does not.
        # Checking the substitution result is mandatory: the old code was a pure
        # string comparison and could not fail, while a command substitution
        # returns an empty string when fork/exec fails. Without the check the
        # config would get 'AllowedIPs = ' with exit code 0 - a loud failure
        # turned into the quiet delivery of a broken profile.
        local _aip_new
        _aip_new=$(_append_ipv6_full_tunnel_route "$allowed_ips") && [[ -n "$_aip_new" ]] || {
            log_error "Could not compute AllowedIPs - the client config was not created."
            return 1
        }
        allowed_ips="$_aip_new"
    fi

    # A per-client list with explicit IPv6 but no ::/0 over a full tunnel:
    # regen warns about this state (its custom-list preservation rule), and
    # the creator of the config must not be quieter than regen - otherwise
    # the person learns about their routes a month later from another
    # command. The global mode is not warned about: the installer never
    # writes such lists, and a hand-edited one passed silently before too.
    if [[ -n "${CLIENT_ALLOWED_IPS:-}" ]] && _aip_full_tunnel_v6_gap "$allowed_ips"; then
        log_warn "Client '$name': the per-client AllowedIPs spells out IPv6 without ::/0 - over a full tunnel the device's IPv6 goes outside the tunnel. Need ::/0 - add it to --allowed-ips or run regen --reset-routes '$name'."
    fi

    # MTU resolution order: server awg0.conf > AWG_MTU from awgsetup_cfg.init >
    # 1280 fallback. Server config is the source of truth for a running server -
    # the user could have hand-edited MTU in /etc/amnezia/amneziawg/awg0.conf
    # and regen has to pick that up (Discussion #38). Out-of-range
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
        # The sink address for 2000::/3 (see AWG_V6_SINK_PREFIX): without it
        # Windows does not install the route and IPv6 goes around the tunnel.
        if _aip_wants_v6_sink "$allowed_ips"; then
            local _sink
            _sink=$(_awg_v6_sink_addr "$client_ip") || {
                rm -f "$tmpfile"
                log_error "Could not compute the IPv6 sink address for '$name' ($client_ip) - client config not created."
                return 1
            }
            address_line+=", ${_sink}/128"
        fi
    fi

    cat > "$tmpfile" << EOF
[Interface]
PrivateKey = ${client_privkey}
Address = ${address_line}
DNS = ${client_dns}
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
    # They do not have to match the server side - the receiver never validates
    # them; regen simply distributes whatever the server has.
    [[ -n "${AWG_I1:-}" ]] && echo "I1 = ${AWG_I1}" >> "$tmpfile"
    [[ -n "${AWG_I2:-}" ]] && echo "I2 = ${AWG_I2}" >> "$tmpfile"
    [[ -n "${AWG_I3:-}" ]] && echo "I3 = ${AWG_I3}" >> "$tmpfile"
    [[ -n "${AWG_I4:-}" ]] && echo "I4 = ${AWG_I4}" >> "$tmpfile"
    [[ -n "${AWG_I5:-}" ]] && echo "I5 = ${AWG_I5}" >> "$tmpfile"
    _awg31_append_profile_lines "$tmpfile" || { rm -f "$tmpfile"; return 1; }

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
# Operations that restart the interface: warning and reversibility
# ==============================================================================

# awg_ssh_client_addr : source address of the current SSH session (empty if this
# is not SSH or it cannot be determined).
#
# ⚠️ $SSH_CONNECTION alone is NOT ENOUGH: the script is run through sudo, sudo
# does env_reset by default, and SSH_CONNECTION is not in the Debian/Ubuntu
# env_keep list. Hence the second path - who, matched against our own tty.
# who may report a hostname instead of an address (with UseDNS yes); the subnet
# comparison then cannot be made, and the caller gets "could not determine",
# which is more honest than guessing.
awg_ssh_client_addr() {
    local from_tty="" from_env="" mytty
    mytty=$(ps -o tty= -p $$ 2>/dev/null | tr -d '[:space:]')
    if [[ -n "$mytty" && "$mytty" != "?" ]]; then
        from_tty=$(who 2>/dev/null | awk -v t="$mytty" '
            $2 == t && match($0, /\(([^)]+)\)/) {
                print substr($0, RSTART + 1, RLENGTH - 2); exit
            }')
    fi
    [[ -n "${SSH_CONNECTION:-}" ]] && from_env="${SSH_CONNECTION%% *}"
    # ⚠️ Data keyed on OUR tty wins over the inherited variable.
    # SSH_CONNECTION comes from the environment, and in a reattached tmux/screen
    # session it can point at the PREVIOUS connection - we would then produce a
    # confidently wrong verdict. utmp keyed on our own tty describes the current
    # one. But if the tty path yielded something that is not an address (with
    # UseDNS yes it will be a hostname), take the variable: a usable address
    # beats an honest "unknown".
    if _valid_ipv4 "$from_tty" 2>/dev/null; then
        printf '%s' "$from_tty"
    elif _valid_ipv4 "$from_env" 2>/dev/null; then
        printf '%s' "$from_env"
    elif [[ -n "$from_tty" ]]; then
        printf '%s' "$from_tty"
    else
        printf '%s' "$from_env"
    fi
}

# awg_session_via_tunnel : is the current session going THROUGH the VPN tunnel.
#   0 - yes, the source address is inside the tunnel subnet (a restart will cut
#       off access);
#   1 - no, the address is outside the subnet;
#   2 - could not determine (not SSH, address not IPv4, subnet not parsed).
# Three states rather than two, deliberately: "unknown" and "not through the
# tunnel" need DIFFERENT wording, and collapsing them into 1 would present a
# guess as a fact.
# _awg_tunnel_subnet : the tunnel subnet as addr/prefix, or an empty string.
#
# 🔴 THERE IS DELIBERATELY NO DEFAULT HERE, and that fixes a critical defect.
# An earlier revision substituted the literal 10.9.9.1/24, while manage does NOT
# load awgsetup_cfg.init on the restart path - so AWG_TUNNEL_SUBNET is empty
# there. For anyone who installed with --subnet, a session from their own subnet
# (say 10.66.66.2) was compared against a foreign 10.9.9.0/24 and declared "not
# through the tunnel": the script confidently asserted THE OPPOSITE OF THE TRUTH
# in exactly the scenario the check was written for, and showed neither the
# warning nor the hint about the provider console. A substituted literal turns
# "there is no data" into "there is data, and it says this".
#
# Sources by descending trustworthiness: the live interface, the server config,
# the variable (which load_awg_params sets on other paths). Nothing found means
# empty, and the caller must say "unknown" rather than guess.
_awg_tunnel_subnet() {
    local out=""
    out=$(ip -4 -o addr show awg0 2>/dev/null \
        | awk '{ for (i = 1; i <= NF; i++) if ($i == "inet") { print $(i + 1); exit } }')
    if [[ -z "$out" && -r "$SERVER_CONF_FILE" ]]; then
        out=$(awk '
            /^[[:space:]]*#/ { next }
            /^[[:space:]]*\[/ { inif = (tolower($0) ~ /^[[:space:]]*\[interface\]/) ? 1 : 0; next }
            inif && tolower($0) ~ /^[[:space:]]*address[[:space:]]*=/ {
                sub(/^[^=]*=[[:space:]]*/, "")
                n = split($0, parts, ",")
                for (i = 1; i <= n; i++) {
                    gsub(/[[:space:]]/, "", parts[i])
                    if (parts[i] ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/) { print parts[i]; exit }
                }
            }' "$SERVER_CONF_FILE")
    fi
    [[ -z "$out" && -n "${AWG_TUNNEL_SUBNET:-}" ]] && out="$AWG_TUNNEL_SUBNET"
    printf '%s' "$out"
}

awg_session_via_tunnel() {
    local addr="${1:-}" subnet net_int bcast_int addr_int
    [[ -n "$addr" ]] || addr="$(awg_ssh_client_addr)"
    [[ -n "$addr" ]] || return 2
    [[ "$addr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 2
    subnet="$(_awg_tunnel_subnet)"
    [[ -n "$subnet" ]] || return 2
    # 🔴 A /31 or /32 prefix carries no host range, so it cannot answer our
    # question: any address other than the server one lands "outside the
    # subnet", and we would confidently tell someone sitting in the tunnel
    # that access is unaffected. Our generator writes /16../30, but the live
    # interface path inherits WHATEVER prefix is there, and /32 in
    # [Interface] is common WireGuard practice. Answer "unknown" (verified).
    [[ "${subnet##*/}" =~ ^[0-9]+$ ]] || return 2
    (( 10#${subnet##*/} <= 30 )) || return 2
    read -r net_int bcast_int < <(_cidr_bounds "$subnet" 2>/dev/null) || return 2
    [[ -n "$net_int" && -n "$bcast_int" ]] || return 2
    addr_int="$(_ipv4_to_int "$addr" 2>/dev/null)" || return 2
    [[ -n "$addr_int" ]] || return 2
    (( addr_int >= net_int && addr_int <= bcast_int )) && return 0
    return 1
}

# awg_warn_interface_disruption : warn BEFORE an operation that restarts the
# interface. Call it before confirm_action so the warning is visible with --yes
# as well (a non-interactive run can cut people off from the server too).
awg_warn_interface_disruption() {
    local rc addr subnet
    log_warn "The awg0 interface will be restarted - every client connection drops for a few seconds."
    # Ask for the address ONCE and pass it into the check: two independent
    # calls could give a verdict about one address and text about another.
    addr="$(awg_ssh_client_addr)"
    # The subnet is resolved ONCE and BEFORE the verdict as well: an earlier
    # revision asked for it a second time afterwards, so the printed subnet
    # could differ from the one the verdict was based on.
    subnet="$(_awg_tunnel_subnet)"
    # rc is taken with `|| rc=$?` rather than `cmd; rc=$?`: under set -e the
    # latter aborts the function on a non-zero status, cutting the warning off
    # halfway. The repository does contain an embedded script with set -euo
    # pipefail, so this is not hypothetical.
    rc=0
    awg_session_via_tunnel "$addr" || rc=$?
    case "$rc" in
        0)
            log_warn "WARNING: it looks like you are connected to this server THROUGH this very VPN."
            log_warn "  Your session address $addr belongs to the tunnel subnet ${subnet},"
            log_warn "  so the current connection will drop after the restart."
            log_warn "  If access does not come back on its own, use the console or VNC in your"
            log_warn "  provider's panel: it works independently of the VPN."
            ;;
        1)
            log_debug "Session is not going through the tunnel (address $addr) - server access is unaffected."
            ;;
        *)
            log_warn "  If you are connected to this server THROUGH this VPN, you will lose access."
            log_warn "  The fallback for that case is the console or VNC in your provider's panel."
            ;;
    esac
}

# awg_cps_decoded_size <I string> [...] : total DECODED size in bytes.
#
# Why. The I1-I5 parameters land in the device attributes that the kernel emits
# as a single netlink dump message. Once the device attributes fill most of the
# buffer, the first peer no longer fits, and `wg_get_device_dump` neither
# advances nor fails: it returns a non-zero length, netlink asks again, and the
# same message is produced forever. The reader spins and grows; on a router that
# is enough to take the box down. Written up with the code path in
# amneziawg-linux-kernel-module#228 (31 aug 2026); the user-visible symptom is
# #148. The band just above the looping one answers `Unable to access interface:
# Message too long`, which is BETTER: an error at least stops. Those are the
# exact words: errno EMSGSIZE, which glibc renders as "too long", so that is
# what to grep a log for.
#
# 🔴 The DECODED size is counted, not the string length. `<r 1000>` is eight
# characters and a thousand bytes on the wire; comparing string lengths would
# miss exactly the case this check exists for.
#
# The tag set is the intersection of both implementations, which is also the set
# the vendor documents: `<b 0xHEX>` literal bytes, `<r N>` random bytes,
# `<rc N>` random letters, `<rd N>` random digits, `<t>` a timestamp (4 bytes).
# `<c>` counts as the same 4 bytes: it exists in the kernel module and not in
# amneziawg-go, so it affects portability rather than size.
# Nothing unknown is guessed at: an invented number is worse than an honest
# refusal. But it must not pass in silence either, so anything left unparsed -
# an unknown tag, an unterminated bracket, junk between tags, an implausibly
# large count - marks the result with exit code 2, "the sum is an under-count".
# A zero with code 0 must mean "parsed everything, there is no size", otherwise
# the caller reads junk as emptiness.
awg_cps_decoded_size() {
    local total=0 s tag n hex mat pre unknown=0
    for s in "$@"; do
        [[ -n "$s" ]] || continue
        # The space-less form is accepted DELIBERATELY, even though both
        # implementations reject it: the kernel splits a tag on the space
        # (`strsep`) and amneziawg-go uses `strings.Fields`, so `<r64>` is an
        # unknown key to them and the interface will not come up. Counting it
        # is still right: this estimates a size, and an over-estimate leads to
        # a warning while a miss leads to a hang. ⚠️ Do not write this form
        # into a config.
        while [[ "$s" =~ \<[[:space:]]*([a-zA-Z]+)[[:space:]]*([^\>]*)\> ]]; do
            # 🔴 Save the match BEFORE the case: the `b` branch runs its own
            # `[[ =~ ]]`, which overwrites BASH_REMATCH. That was harmless
            # while the string advanced to the first `>`; now that it advances
            # by the match, a value read after the case would be the hex.
            mat="${BASH_REMATCH[0]}"
            tag="${BASH_REMATCH[1]}"
            n="${BASH_REMATCH[2]}"
            n="${n//[[:space:]]/}"
            # Whatever sits BEFORE the tag is not a tag. Without this line
            # `<><r 5>` passed as an honest five bytes.
            pre="${s%%"$mat"*}"
            [[ -z "${pre//[[:space:]]/}" ]] || unknown=1
            case "${tag,,}" in
                b)
                    hex="${n#0x}"; hex="${hex#0X}"
                    # Two hex characters make a byte. An odd tail is not
                    # counted: implementations reject such a tag anyway.
                    if [[ "$hex" =~ ^[0-9a-fA-F]+$ && $(( ${#hex} % 2 )) -eq 0 ]]; then
                        total=$(( total + ${#hex} / 2 ))
                    else
                        unknown=1
                    fi
                    ;;
                r|rc|rd)
                    # 🔴 `10#` is mandatory. Without it bash reads a
                    # leading-zero number as octal, `<r 08>` breaks the
                    # arithmetic, the whole function returns EMPTY, and the
                    # threshold check silently never fires - a silent failure
                    # exactly where it hurts most. Measured 31 aug 2026.
                    # The nine-digit limit is not a matter of taste:
                    # `<r 18446744073709551617>` overflows 64-bit bash
                    # arithmetic and sums to ONE, so a plainly dangerous value
                    # slips under the threshold. Measured 1 sep 2026. The
                    # vendor caps r/rc/rd at a thousand, so nine digits is
                    # headroom rather than a constraint.
                    if [[ "$n" =~ ^[0-9]{1,9}$ ]]; then
                        total=$(( total + 10#$n ))
                    else
                        unknown=1
                    fi
                    ;;
                t|c)
                    # 🔴 `<t>` and `<c>` carry no payload, so non-empty content
                    # means we parsed the WRONG thing. `<t <r 4096>` matches
                    # this regex as a single tag whose value is `<r 4096`, and
                    # without the check it counted four bytes and returned
                    # success: four thousand bytes became four, and diagnostics
                    # walked into the dangerous call with a clear conscience.
                    if [[ -z "$n" ]]; then
                        total=$(( total + 4 ))
                    else
                        unknown=1
                    fi
                    ;;
                *)
                    unknown=1
                    ;;
            esac
            # 🔴 Advance past the END OF THE MATCH. The `${s#*>}` form cut
            # to the first `>` in the string, which could sit BEFORE the
            # match - and then the same tag was counted twice.
            s="${s#*"$mat"}"
        done
        # A non-empty remainder is not a tag. Without this, `garbage` and an
        # unterminated `<r 5` returned zero with code 0, that is "parsed, no
        # size".
        [[ -z "${s//[[:space:]]/}" ]] || unknown=1
    done
    printf '%s' "$total"
    # A code of 2 means "the sum is an under-count, something was not parsed".
    # The caller must say so out loud: an under-count is indistinguishable from
    # a genuinely small size, and that is precisely a false "checked, fine".
    [[ "$unknown" -eq 0 ]] || return 2
    return 0
}

# Does a CPS string have STRUCTURE rather than just random bytes.
#
# 🔴 This answers the diagnostic's question "should this value be scolded", and
# the boundary matters more than convenience. Measured 10 sep 2026 on a live
# Russian carrier: a packet of random bytes never completes the handshake, a
# DNS-reply-shaped packet of the same size does. So "structured" has to mean
# structure, not the presence of one literal tag somewhere in the string:
# `<r 200><b 0xaa>` is two hundred bytes of randomness with a one-byte tail, and
# the first version of this check blessed it. Three conditions, each its own:
#   1. the string parses through our counter in full (truncation and odd hex out);
#   2. tags only from the intersection of the implementations - `<c>` and `<d>`
#      break portability;
#   3. no random run is longer than a DNS label (63 bytes), and there are at
#      least thirty literal bytes. Our generator gives a label up to 62 and from
#      48 literal bytes; the documented QUIC recipes are nearly all literal.
#
# Returns 0 when the structure is there.
awg_cps_is_shaped() {
    local s="${1:-}" rest tag n lit=0 rnd_max=0
    [[ -n "$s" ]] || return 1
    # Разбирается целиком: код 2 означает «встретилось неразобранное», и такой
    # тег обе реализации отвергнут - интерфейс не поднимется.
    awg_cps_decoded_size "$s" >/dev/null 2>&1 || return 1
    rest="$s"
    while [[ "$rest" =~ \<[[:space:]]*([a-zA-Z]+)[[:space:]]*([^\>]*)\> ]]; do
        tag="${BASH_REMATCH[1],,}"
        n="${BASH_REMATCH[2]//[[:space:]]/}"
        case "$tag" in
            b)
                n="${n#0x}"; n="${n#0X}"
                lit=$(( lit + ${#n} / 2 ))
                ;;
            r|rc|rd)
                [[ "$n" =~ ^[0-9]{1,9}$ ]] || return 1
                [[ $(( 10#$n )) -gt "$rnd_max" ]] && rnd_max=$(( 10#$n ))
                ;;
            t) : ;;
            *) return 1 ;;
        esac
        rest="${rest#*"${BASH_REMATCH[0]}"}"
    done
    # Ни одного случайного куска длиннее метки DNS и не меньше тридцати
    # литеральных байт структуры.
    [[ "$rnd_max" -le 63 && "$lit" -ge 30 ]]
}

# awg_cps_check_safe <I string> : is a CPS string safe for BOTH implementations.
# 0 - safe; 1 - not, and the reason goes to stdout.
#
# Why. The kernel module parses the length of `<r>`/`<rc>`/`<rd>` with
# kstrtoint and never looks at the value: tag sizes are summed into an int that
# sizes an allocation, while each tag's own length drives a copy. A negative
# length next to `<b>` keeps the sum small and positive, so the buffer is small
# and the literal copy is not (upstream amneziawg-linux-kernel-module#233 and
# #187); a lone negative length makes the sum negative, and then the kernel
# refuses by itself. amneziawg-go reads the same length with strconv.Atoi and
# crashes on a slice when it builds the packet. Such a config is accepted
# without an error, and regen would hand it to every client.
#
# 🔴 The refusal is narrow ON PURPOSE: only what the code of both
# implementations shows to be dangerous. A length must be a non-negative
# decimal of at most nine significant digits (both accept a sign, leading zeros
# and `-0`, and a working config with them must not break); the total must not
# exceed 65535, more certainly does not fit in UDP. Nine digits is the limit of
# OUR arithmetic, not a property of the implementations: bash silently wraps
# 2^64+1 into 1. An unknown tag and junk are NOT touched: the implementations
# reject those loudly on their own, and refusing them here could break a
# userspace server that works today.
#
# 🔴 The value is read THE WAY IT IS APPLIED, or any difference is a way past:
#   - amneziawg-tools cut a line at `#`, so the comment is dropped;
#   - the kernel splits tags with strsep, and strsep without `>` returns the
#     rest of the string, so an unterminated LAST tag is parsed like a closed one;
#   - both implementations compare the tag name with its case (strcmp and a map),
#     so `<R -1>` is an unknown tag for them, and it is left alone.
# The form without a space (`<r-1>`) is parsed as in awg_cps_decoded_size;
# refusing it is harmless, both implementations reject that form themselves.
# The total is counted here rather than by awg_cps_decoded_size: that one does
# not accept a leading plus, and `<r +999999999>` three times would slip past
# the overflow check.
awg_cps_check_safe() {
    local s="${1:-}" rest mat tag n digits hex total=0
    s="${s%%#*}"
    [[ -n "${s//[[:space:]]/}" ]] || return 0
    rest="$s"
    while [[ "$rest" =~ \<[[:space:]]*([a-zA-Z]+)[[:space:]]*([^\>]*)(\>|$) ]]; do
        # 🔴 Save the match and advance BEFORE any other [[ =~ ]]: those clobber
        # BASH_REMATCH, and advancing by a clobbered match would not shorten the
        # string. On `<b 0xGG>` or `<r 1 2>` the loop would then never end, and in
        # restore that would happen after the files were replaced and before the
        # rollback.
        mat="${BASH_REMATCH[0]}"
        tag="${BASH_REMATCH[1]}"
        n="${BASH_REMATCH[2]//[[:space:]]/}"
        rest="${rest#*"$mat"}"
        case "$tag" in
            r|rc|rd)
                # The sign is stripped once, leading zeros before the digit
                # limit: both implementations read `-0`, `+0` and `0000000001`
                # as plain numbers, and refusing them would break a working
                # config.
                digits="${n#[-+]}"
                if ! [[ "$digits" =~ ^[0-9]+$ ]]; then
                    printf 'the length in tag <%s %s> is not a decimal' "$tag" "$n"
                    return 1
                fi
                while [[ "$digits" == 0?* ]]; do digits="${digits#0}"; done
                # The memory corruption text is for a real negative number only,
                # not for a minus in front of zero or junk.
                if [[ "$n" == -* && "$digits" != "0" ]]; then
                    printf 'negative length in tag <%s %s>: amneziawg-go crashes on it when building the packet, and the kernel module writes past the buffer when a <b> stands next to it' "$tag" "$n"
                    return 1
                fi
                if ! [[ "$digits" =~ ^[0-9]{1,9}$ ]]; then
                    printf 'the length in tag <%s %s> has more than nine significant digits: certainly above 65535 bytes, and such a number would overflow the arithmetic of this check' "$tag" "$n"
                    return 1
                fi
                total=$(( total + 10#$digits ))
                ;;
            b)
                hex="${n#0x}"; hex="${hex#0X}"
                [[ "$hex" =~ ^[0-9a-fA-F]+$ ]] && total=$(( total + ${#hex} / 2 ))
                ;;
            t|c)
                total=$(( total + 4 ))
                ;;
        esac
    done
    if [[ "$total" -gt 65535 ]]; then
        printf 'the total size of %s bytes exceeds 65535: such a packet certainly does not fit in UDP, and huge lengths overflow the summed size in the kernel module' "$total"
        return 1
    fi
    return 0
}

# awg_cpa_check_safe <value> : ContentPaddingAddition in a form amneziawg-tools
# parse without silently distorting it.
# The tools read the value with u16_range_from_string and wrap the number modulo
# 65536: 65536 becomes 0, that is a profile with no added padding on a fully
# green install (measured 10 sep 2026). So the 65535 cap is checked here, before
# the tool. A number longer than 10 significant digits is refused BEFORE shell
# arithmetic (leading zeros do not count, _awg_dec_strip): otherwise a huge
# value wraps past 2^63 and the comparison lies. The
# tools refuse a reversed range loudly on their own; here it is refused earlier,
# before the service starts.
# Returns: 0 - safe; 1 - not, the reason on stdout.
awg_cpa_check_safe() {
    local v="${1:-}" lo hi
    v="${v%%#*}"
    v="${v//[[:space:]]/}"
    if [[ "$v" =~ ^([0-9]+)$ ]]; then
        lo="${BASH_REMATCH[1]}"
        hi="$lo"
    elif [[ "$v" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        lo="${BASH_REMATCH[1]}"
        hi="${BASH_REMATCH[2]}"
    else
        printf 'value "%s" is neither a number nor a MIN-MAX range' "$v"
        return 1
    fi
    lo=$(_awg_dec_strip "$lo")
    hi=$(_awg_dec_strip "$hi")
    if (( ${#lo} > 10 || ${#hi} > 10 )) || (( lo > 4294967295 || hi > 4294967295 )); then
        printf 'value "%s" exceeds 4294967295: amneziawg-tools will not accept it' "$v"
        return 1
    fi
    if (( lo > 65535 || hi > 65535 )); then
        printf 'value "%s" exceeds 65535: amneziawg-tools silently wrap it modulo 65536' "$v"
        return 1
    fi
    if (( lo > hi )); then
        printf 'in the range "%s" the lower bound is greater than the upper one' "$v"
        return 1
    fi
    return 0
}

# _awg_dec_strip <digits> : the same number without leading zeros ("0" if only
# zeros). The overflow length is counted in significant digits: the tools read
# 00000000001 as 1, and refusing it by its written length would be false. A result
# without leading zeros is also safe for shell arithmetic, which would otherwise
# read 010 as 8.
_awg_dec_strip() {
    local d="${1#"${1%%[!0]*}"}"
    printf '%s' "${d:-0}"
}

# _awg_conf_pairs <file> : "section<TAB>key<TAB>value" lines of a config, the way
# amneziawg-tools read them: section header and key case-insensitive (the key is
# printed lowercase), the comment after # and all whitespace dropped, CR removed.
# The section is interface, other or none (a line before the first header; the
# tools refuse it, and we must not skip it silently). Matches the tools for
# single-token keys; spaces inside I1-I5 are not kept, so this function is not
# for I1-I5. Order is kept, duplicates are NOT collapsed.
_awg_conf_pairs() {
    awk '
        BEGIN { sec = "none" }
        { gsub(/\r/, ""); sub(/#.*/, "") }
        /^[[:space:]]*\[/ {
            h = tolower($0); gsub(/[[:space:]]/, "", h)
            sec = (h == "[interface]") ? "interface" : "other"
            next
        }
        /=/ {
            k = $0; sub(/=.*/, "", k); gsub(/[[:space:]]/, "", k)
            v = $0; sub(/^[^=]*=/, "", v); gsub(/[[:space:]]/, "", v)
            if (k != "") print sec "\t" tolower(k) "\t" v
        }
    ' "$1"
}

# awg_cps_refuse_unsafe : check AWG_I1..AWG_I5 of the current environment.
# 0 - all safe; 1 - not, the reasons are already logged.
# One refusal text for load_awg_params and render_server_config; the validator
# checks the lines of the file itself and writes its own. The file to fix is
# named by the actual source load_awg_params records: on a first install there
# is no awg0.conf yet and the values come from the init file.
awg_cps_refuse_unsafe() {
    local v why bad=0
    for v in AWG_I1 AWG_I2 AWG_I3 AWG_I4 AWG_I5; do
        [[ -n "${!v:-}" ]] || continue
        if ! why=$(awg_cps_check_safe "${!v}"); then
            log_error "Parameter ${v#AWG_} is unsafe: ${why}."
            bad=1
        fi
    done
    if [[ $bad -eq 1 ]]; then
        log_error "Not issuing profiles or a server config with such a value (upstream amneziawg-linux-kernel-module#233). Fix I1-I5 in ${_AWG_PARAMS_SOURCE:-$SERVER_CONF_FILE}."
        return 1
    fi
    return 0
}


# _awg_device_param_names : names of the AWG device parameters (2.0, 3.0 and 3.1)
# that live in the [Interface] section and that syncconf does NOT clear.
_awg_device_param_names() {
    printf '%s\n' Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4 I1 I2 I3 I4 I5 \
        ContentPaddingAddition HeaderProtectionKey MaxHandshakeAttempts \
        KeepaliveTimeout RejectAfterTime RekeyAfterTime RekeyTimeout \
        RandomTrailers DisableCookies
}

# _awg_device_params_fingerprint [config] : sorted list of device parameter
# NAMES present in the [Interface] section, on a single line.
# Names only: syncconf applies values correctly, the problem is exactly removal.
_awg_device_params_fingerprint() {
    local conf="${1:-$SERVER_CONF_FILE}" known
    [[ -r "$conf" ]] || return 1
    known="$(_awg_device_param_names | tr '\n' '|')"
    known="${known%|}"
    awk -v known="$known" '
        BEGIN { n = split(known, k, "|"); for (i = 1; i <= n; i++) low[tolower(k[i])] = k[i] }
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*\[/ { inif = (tolower($0) ~ /^[[:space:]]*\[interface\]/) ? 1 : 0; next }
        inif && /=/ {
            name = $1
            sub(/[[:space:]]*=.*$/, "", name)
            gsub(/[[:space:]]/, "", name)
            if (tolower(name) in low) print low[tolower(name)]
        }
    ' "$conf" | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

# _awg_save_device_params <state file> <fingerprint> : remember the applied set.
# The file lives in AWG_DIR (root-only); losing it degrades gracefully - the
# next check simply does not fire, and no spurious restart happens.
# The write is ATOMIC (temp + mv): a truncated write would leave a half-empty
# snapshot, which reads as "the parameters were removed" and produces a false
# warning. A failure is not swallowed entirely - it goes to debug, otherwise a
# silent loss of state would look like success.
_awg_save_device_params() {
    local state="$1" fp="$2" tmp="${1}.tmp"
    if ! printf '%s\n' "$fp" > "$tmp" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        log_warn "Failed to write the interface parameter snapshot ($state) - check free space and permissions."
        return 0
    fi
    chmod 600 "$tmp" 2>/dev/null || true
    if ! mv -f "$tmp" "$state" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        log_warn "Failed to replace the interface parameter snapshot ($state) - check free space and permissions."
    fi
    return 0
}

# awg_record_device_params : remember which set of device parameters the config
# holds RIGHT NOW. Call it AFTER a successful apply or interface recreation - the
# snapshot has to mean "what is actually on the live interface", otherwise
# removal detection starts lying in both directions.
#
# 🔴 Two rules, each closing a defect found in review:
# 1. The fingerprint is recomputed rather than reusing the one taken before the
#    apply: if the file was being rewritten at that moment, what was computed was
#    incomplete, and saving it would have frozen a wrong set.
# 2. An EMPTY set is NEVER written. An empty snapshot disables the check forever
#    (nothing to compare against), and emptiness almost always means a partially
#    read file: our generator always writes Jc/S/H. Keeping the previous good
#    snapshot is better.
awg_record_device_params() {
    local state="${AWG_DIR}/.awg_device_params" fp
    [[ -r "$SERVER_CONF_FILE" ]] || return 0
    fp="$(_awg_device_params_fingerprint "$SERVER_CONF_FILE" 2>/dev/null)" || return 0
    [[ -n "$fp" ]] || return 0
    _awg_save_device_params "$state" "$fp"
}

# ==============================================================================
# Config application (syncconf)
# ==============================================================================

# Apply configuration changes
# AWG_SKIP_APPLY=1: skip apply (for batch automation)
# AWG_APPLY_MODE=syncconf|restart: apply method (config or --apply-mode CLI)
# flock on .awg_apply.lock: prevents concurrent apply calls
apply_config() {
    case $- in *x*) _awg_xtrace_guard apply_config; return ;; esac
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

    # 🔴 syncconf DOES NOT CLEAR AWG device parameters. Verified on module
    # 3.0.20260731-04: Jc/S4/H1/I1/ContentPaddingAddition/RekeyAfterTime that had
    # been set stayed on the live interface after applying a config without them.
    # The WireGuard semantics ("setconf = the complete picture") does not hold for
    # AWG parameters, it is additive. So the operation "remove a parameter from
    # awg0.conf and apply" would silently not work: the file changes, the
    # interface does not, and nothing catches that divergence. A parameter can
    # only be cleared by recreating the interface, i.e. by restarting the service.
    #
    # We compare the SET OF NAMES against what was applied last time, not against
    # the live interface: `awg showconf` prints neutral values too (S4 = 0,
    # H1 = 1), so comparing with it would produce false positives on every apply.
    # Values are not compared at all - syncconf applies those correctly, the
    # problem is exactly removal.
    # No state (first install, lost file) - stay quiet: there is nothing to
    # compare against, and guessing at a warning is worse than not warning.
    local params_state="${AWG_DIR}/.awg_device_params"
    local now_fp="" prev_fp="" removed=""
    if [[ -r "$SERVER_CONF_FILE" ]]; then
        # The path is passed explicitly even though it is also the default:
        # otherwise shellcheck 0.9 (the version CI installs) rightly raises
        # SC2120 about a parameter nobody ever passes.
        now_fp="$(_awg_device_params_fingerprint "$SERVER_CONF_FILE" 2>/dev/null)" || now_fp=""
        [[ -r "$params_state" ]] && IFS= read -r prev_fp 2>/dev/null < "$params_state"
        # ⚠️ An empty set against a non-empty previous one is NOT treated as
        # "everything was removed". Our generator always writes Jc/S/H, so
        # emptiness means a partially read or currently rewritten file rather
        # than a real cleanup. Stay quiet: a false alarm costs more here than a
        # missed one.
        if [[ -n "$prev_fp" && -n "$now_fp" ]]; then
            local _p
            for _p in $prev_fp; do
                [[ " $now_fp " == *" $_p "* ]] || removed+="${removed:+, }$_p"
            done
        fi
    fi

    if [[ "${AWG_APPLY_MODE:-syncconf}" == "restart" ]]; then
        # An explicit restart mode drops client connections, SSH through the
        # tunnel included, so warn exactly as manage restart does.
        awg_warn_interface_disruption
        log "Restarting service (apply-mode=restart)..."
        systemctl restart awg-quick@awg0 2>/dev/null; rc=$?
        if [[ $rc -ne 0 ]]; then
            log_warn "Service restart error."
        else
            awg_record_device_params
        fi
        exec {apply_fd}>&-
        return $rc
    fi

    # 🔴 A detected removal is NOT restarted for you - it is reported.
    # The first revision of this change restarted the service automatically, and
    # that was WORSE than the trap it closed: a restart drops EVERY client
    # connection, and the state can fall behind through no fault of the user.
    # Example: someone drops the line and applies it with `manage restart` - the
    # interface is already recreated and the parameter already cleared, but the
    # snapshot still holds the old set, so the next ordinary `add` would see the
    # "removal" a second time and cut everyone off again. A false warning costs
    # a log line; a false restart costs everyone's connection. So we speak, and
    # the human decides.
    # ⚠️ The snapshot is NOT updated here. It is updated only AFTER a successful
    # apply, below. An earlier revision updated it right away, and that silenced
    # the warning forever whenever the apply then failed: the state had already
    # "caught up" with the file while nothing had changed on the live interface.
    if [[ -n "$removed" ]]; then
        log_warn "Removed from the [Interface] section: ${removed}."
        log_warn "  syncconf does NOT clear such parameters - they stay on the live interface."
        log_warn "  To make the removal take effect the interface has to be recreated:"
        log_warn "    systemctl restart awg-quick@awg0"
        log_warn "  That drops every client connection for a few seconds, which is why we do"
        log_warn "  not do it for you. If you have already restarted the service by hand, this"
        log_warn "  warning can be ignored: after a successful apply the snapshot is"
        log_warn "  refreshed and this line will not appear on later runs."
    fi

    local strip_out
    strip_out=$(timeout 10 awg-quick strip awg0 2>/dev/null) || {
        log_warn "awg-quick strip failed or timed out, falling back to full restart."
        # This restart is NOT expected: the person ran a routine add/remove.
        # It drops every client, so warn here too, not only in explicit mode.
        awg_warn_interface_disruption
        systemctl restart awg-quick@awg0 2>/dev/null; rc=$?
        if [[ $rc -ne 0 ]]; then
            log_warn "Service restart error."
        else
            awg_record_device_params
        fi
        exec {apply_fd}>&-
        return $rc
    }
    echo "$strip_out" | timeout 10 awg syncconf awg0 /dev/stdin 2>/dev/null || {
        log_warn "awg syncconf failed or timed out, falling back to full restart."
        # As above: an unplanned restart cuts off everyone, including an SSH
        # session through the tunnel - that has to be said before, not after.
        awg_warn_interface_disruption
        systemctl restart awg-quick@awg0 2>/dev/null; rc=$?
        if [[ $rc -ne 0 ]]; then
            log_warn "Service restart error."
        else
            awg_record_device_params
        fi
        exec {apply_fd}>&-
        return $rc
    }
    log_debug "Config applied (syncconf)."
    awg_record_device_params
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
    case $- in *x*) _awg_xtrace_guard add_peer_to_server "$@"; return ;; esac
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
    case $- in *x*) _awg_xtrace_guard generate_vpn_uri "$@"; return ;; esac
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
    client_privkey=$(grep -oP 'PrivateKey\s*=\s*\K\S+' "$conf_file") || { log_warn "PrivateKey could not be read from '$conf_file' - vpn:// URI not created for '$name'."; return 1; }
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
    # The sink address is not the client's IPv6: it does not go into client_ipv6.
    if _is_v6_sink_addr "$client_ipv6"; then
        client_ipv6=""
    fi
    _ensure_server_public_key || return 1
    server_pubkey=$(cat "$AWG_DIR/server_public.key" 2>/dev/null) || { log_warn "Could not read $AWG_DIR/server_public.key - vpn:// URI not created for '$name'."; return 1; }
    # PresharedKey is optional. awk instead of grep so an empty result is not
    # treated as failure (grep -P without a match → rc=1, not what we want here).
    # Also strip a trailing CR (CRLF from Windows editors) and trailing spaces
    # — leaking them into the JSON psk_key would break the handshake just as
    # cleanly as the missing field. Without psk_key in inner JSON AmneziaVPN
    # import via vpn:// loses the PSK and the handshake fails (issue #67,
    # fix v5.11.4).
    client_psk=$(awk '/^[[:space:]]*PresharedKey[[:space:]]*=/{sub(/^[[:space:]]*PresharedKey[[:space:]]*=[[:space:]]*/, ""); sub(/\r$/, ""); sub(/[ \t]+$/, ""); print; exit}' "$conf_file" 2>/dev/null)
    # Third line: the key and the padding come from the CLIENT .conf - the link
    # describes that file, and the preshared key is taken the same way. The fields
    # are written only on a 3.1 installation, like the lines in the renderers: on
    # 2.0 and with an unreadable marker the link stays what it was. On 3.1 a
    # profile without the key or the padding is a refusal: such a link looks valid
    # and silently fails to connect, leaving the person with "it does not work".
    local client_hpk client_cpa uri_gen
    client_hpk=$(awk '/^[[:space:]]*HeaderProtectionKey[[:space:]]*=/{sub(/^[[:space:]]*HeaderProtectionKey[[:space:]]*=[[:space:]]*/, ""); sub(/\r$/, ""); sub(/[ \t]+$/, ""); print; exit}' "$conf_file" 2>/dev/null)
    client_cpa=$(awk '/^[[:space:]]*ContentPaddingAddition[[:space:]]*=/{sub(/^[[:space:]]*ContentPaddingAddition[[:space:]]*=[[:space:]]*/, ""); sub(/\r$/, ""); sub(/[ \t]+$/, ""); print; exit}' "$conf_file" 2>/dev/null)
    uri_gen=$(_awg_generation_from_init "$CONFIG_FILE") || uri_gen=broken
    if [[ "$uri_gen" == "3.1" ]]; then
        if [[ -z "$client_hpk" ]]; then
            log_error "The client config '$name' has no HeaderProtectionKey while the installation is marked generation 3.1: the vpn:// link was not created, it would look valid and would not connect"
            return 1
        fi
        if [[ -z "$client_cpa" ]]; then
            log_error "The client config '$name' has no ContentPaddingAddition while the installation is marked generation 3.1: the vpn:// link was not created"
            return 1
        fi
    else
        client_hpk=""
        client_cpa=""
    fi
    local raw_endpoint
    raw_endpoint=$(grep -oP 'Endpoint\s*=\s*\K\S+' "$conf_file") || { log_warn "Endpoint could not be read from '$conf_file' - vpn:// URI not created for '$name'."; return 1; }
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
    #
    # v5.27.1: do NOT touch. The value goes into the allowed_ips JSON array via
    # split(/,/), so spaces here are harmful - they would end up inside the
    # array elements. This path does not damage the spaces in the client
    # .conf: the embedded config is inlined from the file as it is.
    allowed_ips=$(grep -oP 'AllowedIPs\s*=\s*\K.+' "$conf_file" | paste -sd, - | tr -d ' \r')
    # Test for EMPTINESS, not for the exit status: the `||` did not fire even
    # on a valueless "AllowedIPs = " line, because grep matched the space and
    # exited zero, and a pipeline with paste makes the status useless anyway.
    [[ -n "$allowed_ips" ]] || { log_warn "AllowedIPs could not be read from '$conf_file' - the link will carry a full tunnel."; allowed_ips="0.0.0.0/0"; }

    # MTU/PersistentKeepalive/DNS from .conf - these can be changed via manage modify.
    # On vpn:// import the Amnezia client uses the structured inner-JSON fields
    # (awgConfigurator takes mtu from the structured field, not the embedded config),
    # so hardcoding them would desync from .conf - same class as issue #67 (the
    # structured psk_key field was authoritative).
    local mtu keepalive dns_line dns1 dns2
    mtu=$(grep -oP '^MTU\s*=\s*\K[0-9]+' "$conf_file" | head -n1); mtu="${mtu:-1280}"
    keepalive=$(grep -oP '^PersistentKeepalive\s*=\s*\K[0-9]+' "$conf_file" | head -n1); keepalive="${keepalive:-33}"
    dns_line=$(grep -oP '^DNS\s*=\s*\K.+' "$conf_file" | paste -sd, - | tr -d ' \r')
    dns1="${dns_line%%,*}"; dns1="${dns1:-1.1.1.1}"
    if [[ "$dns_line" == *,* ]]; then dns2="${dns_line#*,}"; dns2="${dns2%%,*}"; else dns2="$dns1"; fi

    local vpn_uri perl_err
    perl_err=$(awg_mktemp "$AWG_DIR") || { log_warn "mktemp failed - vpn:// URI not created for '$name'."; return 1; }
    # Secrets (client privkey, PSK) are passed to perl via env, NOT via argv:
    # the process command line is visible to all users in /proc/<pid>/cmdline
    # while perl runs. server_pubkey is not a secret but travels with the group.
    # shellcheck disable=SC2016
    vpn_uri=$(AWG_URI_CPK="$client_privkey" AWG_URI_PSK="$client_psk" AWG_URI_SPK="$server_pubkey" \
      AWG_URI_HPK="$client_hpk" AWG_URI_CPA="$client_cpa" \
      perl -MCompress::Zlib -MMIME::Base64 -e '
        my ($conf_path, $h1,$h2,$h3,$h4, $jc,$jmin,$jmax,
            $s1,$s2,$s3,$s4, $i1,$i2,$i3,$i4,$i5, $port, $ep, $cip, $cipv6, $aips,
            $mtu, $keepalive, $dns1, $dns2, $srvname) = @ARGV;
        my $cpk = $ENV{AWG_URI_CPK} // "";
        my $psk = $ENV{AWG_URI_PSK} // "";
        my $spk = $ENV{AWG_URI_SPK} // "";
        my $hpk = $ENV{AWG_URI_HPK} // "";
        my $cpa = $ENV{AWG_URI_CPA} // "";

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
        if ($hpk ne "") {
            my $ehpk = je($hpk);
            $inner .= qq("HeaderProtectionKey":"$ehpk",);
        }
        if ($cpa ne "") {
            my $ecpa = je($cpa);
            $inner .= qq("ContentPaddingAddition":"$ecpa",);
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
        my $esrv = je($srvname);
        $outer .= qq("description":"$esrv",);
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
        "$mtu" "$keepalive" "$dns1" "$dns2" "${AWG_SERVER_NAME:-AWG Server}" 2>"$perl_err"
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

# _awg31_require_client_tools : the tools a 3.1 profile is incomplete without.
# On 3.1 a client is handed a set of four files, and the vpn:// link is not a
# convenience but the one simple way to get the profile into the application.
# The link is built by perl with Compress::Zlib and MIME::Base64, both QR codes
# by qrencode. So on 3.1 a missing tool is a refusal BEFORE anything changes,
# naming what is missing, rather than a failure halfway through the install.
# On 2.0 the function does nothing.
_awg31_require_client_tools() {
    local gen
    gen=$(_awg_generation_from_init "$CONFIG_FILE") || {
        log_error "The generation marker AWG_PROTOCOL in $CONFIG_FILE cannot be read: the toolset was not checked"
        return 1
    }
    [[ "$gen" == "3.1" ]] || return 0
    if ! command -v qrencode >/dev/null 2>&1; then
        log_error "A 3.1 profile needs qrencode: without it there is neither the config QR nor the link QR. Install qrencode and run again"
        return 1
    fi
    if ! command -v perl >/dev/null 2>&1; then
        log_error "A 3.1 profile needs perl: without it the vpn:// link cannot be built. Install perl and run again"
        return 1
    fi
    if ! perl -MCompress::Zlib -MMIME::Base64 -e '1' 2>/dev/null; then
        log_error "A 3.1 profile needs the perl modules Compress::Zlib and MIME::Base64: without them the vpn:// link cannot be built. Install them and run again"
        return 1
    fi
    return 0
}

# _awg31_refuse_client_leftovers <name> [<name>...] : leftover client files.
# generate_client refuses a client whose keys or .conf already exist. On 2.0
# step 6 logs a warning about it and goes on; on 3.1 that refusal would come
# AFTER the server config was rewritten and would mean an undo, so the leftovers
# are checked before the first change and the file is named. .png, .vpnuri and
# .vpnuri.png count as leftovers too, although generate_client overwrites them:
# if the new link failed, the old file would pass the set check as the real one.
# On 2.0 the function does nothing; with an unreadable marker it refuses.
_awg31_refuse_client_leftovers() {
    local gen name f
    gen=$(_awg_generation_from_init "$CONFIG_FILE") || {
        log_error "The generation marker AWG_PROTOCOL in $CONFIG_FILE cannot be read: leftover client files were not checked"
        return 1
    }
    [[ "$gen" == "3.1" ]] || return 0
    for name in "$@"; do
        for f in "$AWG_DIR/${name}.conf" "$AWG_DIR/${name}.png" "$AWG_DIR/${name}.vpnuri" \
                 "$AWG_DIR/${name}.vpnuri.png" "$KEYS_DIR/${name}.private" "$KEYS_DIR/${name}.public"; do
            if [[ -e "$f" || -L "$f" ]]; then
                log_error "A leftover file of client '$name': $f. The 3.1 install stopped before its first change: remove the leftovers of the previous client and run again"
                return 1
            fi
        done
    done
    return 0
}

# awg_client_artifacts_check <name> : the client's set of files, as a set.
# A client is handed four files - the .conf, its QR code, the vpn:// link and
# the link's QR code. Different steps produce them, and a failure in one used to
# be a warning: the person then gets a folder that looks complete and a client
# that does not work. Each file is checked for existence, for being a regular
# file (not a symlink) and for not being empty, and the .vpnuri is checked to
# actually start with vpn://.
# On a 3.1 installation the profile itself is checked too: exactly one
# HeaderProtectionKey in [Interface], equal to the key file, and a
# ContentPaddingAddition equal to the installation's padding. A profile with the
# wrong key looks exactly like a working one until the tunnel refuses to start.
# 🔴 The function is guarded: it compares the key value.
# The expected padding comes from the ALREADY LOADED parameters ($AWG_CPA), in
# the same normalized form the renderers write: the caller must have loaded the
# parameters (load_awg_params), otherwise the comparison uses whatever is in the
# environment, empty or stale. The padding is read from the first
# ContentPaddingAddition line in the file; unlike the key, its section and
# uniqueness are not checked.
awg_client_artifacts_check() {
    _awg_xtrace_guard _awg_client_artifacts_check_body "$@"
}

_awg_client_artifacts_check_body() {
    local name="${1:-}" f gen keyfile key conf uri_first conf_cpa want_cpa
    local _hs_any=0 _hs_if=0 _hs_out=0 _hs_val=""
    if [[ -z "$name" ]]; then
        log_error "awg_client_artifacts_check: the client name is required"
        return 1
    fi
    conf="$AWG_DIR/${name}.conf"
    for f in "$conf" "$AWG_DIR/${name}.png" "$AWG_DIR/${name}.vpnuri" "$AWG_DIR/${name}.vpnuri.png"; do
        if [[ -L "$f" ]]; then
            log_error "The set of client '$name' is incomplete: $f is a symlink where a regular file is required"
            return 1
        fi
        if [[ ! -f "$f" ]]; then
            log_error "The set of client '$name' is incomplete: $f is missing"
            return 1
        fi
        if [[ ! -s "$f" ]]; then
            log_error "The set of client '$name' is incomplete: $f is empty"
            return 1
        fi
    done
    if ! IFS= read -r uri_first < "$AWG_DIR/${name}.vpnuri"; then
        log_error "The set of client '$name': the link file $AWG_DIR/${name}.vpnuri cannot be read"
        return 1
    fi
    if [[ "$uri_first" != vpn://* ]]; then
        log_error "The set of client '$name': $AWG_DIR/${name}.vpnuri does not start with vpn:// - the client cannot import such a link"
        return 1
    fi
    gen=$(_awg_generation_from_init "$CONFIG_FILE") || {
        log_error "The generation marker AWG_PROTOCOL in $CONFIG_FILE cannot be read: the set of client '$name' was not checked"
        return 1
    }
    [[ "$gen" == "3.1" ]] || return 0
    keyfile=$(awg_hpk_path) || { log_error "AWG_DIR is not set: the set of client '$name' was not checked"; return 1; }
    if [[ ! -f "$keyfile" ]]; then
        log_error "The set of client '$name': the installation is marked generation 3.1 but the key file $keyfile is missing"
        return 1
    fi
    if ! IFS= read -r key < "$keyfile"; then
        log_error "The set of client '$name': the key file $keyfile cannot be read"
        return 1
    fi
    _awg_hpk_conf_scan "$conf" || {
        log_error "The set of client '$name': could not parse $conf"
        return 1
    }
    if (( _hs_out > 0 )); then
        log_error "The set of client '$name': HeaderProtectionKey sits outside [Interface] in $conf"
        return 1
    fi
    if (( _hs_if != 1 )); then
        log_error "The set of client '$name': [Interface] in $conf must carry exactly one HeaderProtectionKey, found ${_hs_if}"
        return 1
    fi
    if [[ "$_hs_val" != "$key" ]]; then
        log_error "The set of client '$name': HeaderProtectionKey in $conf does not match the key file $keyfile - such a profile will not connect"
        return 1
    fi
    conf_cpa=$(awk '/^[[:space:]]*ContentPaddingAddition[[:space:]]*=/{sub(/^[[:space:]]*ContentPaddingAddition[[:space:]]*=[[:space:]]*/, ""); sub(/\r$/, ""); sub(/[ \t]+$/, ""); print; exit}' "$conf" 2>/dev/null)
    if [[ -z "$conf_cpa" ]]; then
        log_error "The set of client '$name': $conf has no ContentPaddingAddition while the installation is marked generation 3.1"
        return 1
    fi
    want_cpa="${AWG_CPA:-}"
    want_cpa="${want_cpa%%#*}"
    want_cpa="${want_cpa//[[:space:]]/}"
    if [[ "$conf_cpa" != "$want_cpa" ]]; then
        log_error "The set of client '$name': ContentPaddingAddition in $conf ('$conf_cpa') differs from the installation parameter ('$want_cpa')"
        return 1
    fi
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
#   CLIENT_ALLOWED_IPS - optional (Issue #253). The client's own routes
#     instead of the server-wide mode (ALLOWED_IPS): a comma-separated
#     list of IPv4/IPv6 CIDRs. The value is validated and normalized
#     right here; empty/unset - the global mode as before. Exported by
#     `manage add --allowed-ips=...`; calling directly with the env is
#     equally valid (a library contract, not just a CLI one).
generate_client() {
    case $- in *x*) _awg_xtrace_guard generate_client "$@"; return ;; esac
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

    # CLIENT_ALLOWED_IPS (Issue #253): validated BEFORE key generation and
    # the lock - an invalid value must leave no artifacts and must not hold
    # the lock. This check duplicates the early validation in manage add:
    # the env contract is available directly too, without the CLI.
    if [[ -n "${CLIENT_ALLOWED_IPS:-}" ]]; then
        if ! awg_validate_allowed_ips_list "$CLIENT_ALLOWED_IPS"; then
            log_error "generate_client: invalid CLIENT_ALLOWED_IPS - client '$name' NOT created."
            return 1
        fi
        CLIENT_ALLOWED_IPS=$(awg_normalize_csv "$CLIENT_ALLOWED_IPS")
        [[ -n "$CLIENT_ALLOWED_IPS" ]] || {
            log_error "generate_client: normalizing CLIENT_ALLOWED_IPS produced an empty value - client '$name' NOT created."
            return 1
        }
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

    # The server port comes from the live awg0.conf (ListenPort), else from
    # awgsetup_cfg.init - both are hand-edited. render puts it into the
    # 'Endpoint = IP:PORT' line of the client .conf: a broken port is carried
    # onto the device and debugged blind. We refuse explicitly, just as
    # generate_vpn_uri does for the vpn:// URI. _rollback below removes the
    # artifacts.
    local _cport
    _cport=$(_sanitize_port "${AWG_PORT:-}")
    if [[ "$_cport" == "0" ]]; then
        log_error "AWG_PORT is invalid ('${AWG_PORT:-}') - client config for '$name' was not created. Check ListenPort in $SERVER_CONF_FILE (or AWG_PORT in $CONFIG_FILE)."
        _rollback_client_artifacts "$name"
        exec {lock_fd}>&-
        return 1
    fi

    # Client config
    render_client_config "$name" "$client_ip" "$client_privkey" "$server_pubkey" "$endpoint" "$_cport" "$client_ipv6" || {
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
    case $- in *x*) _awg_xtrace_guard regenerate_client "$@"; return ;; esac
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

    # Hygiene (Issue #253): CLIENT_ALLOWED_IPS is a contract for generating a
    # NEW client (manage add --allowed-ips); regen must never see it. Without
    # this cleanup a leaked env override would reach render_client_config,
    # and with --reset-routes it would even survive in the config, defeating
    # the very point of resetting routes to the global mode. Regen always
    # renders with the global mode; the client's own value is restored from
    # the existing .conf below.
    unset CLIENT_ALLOWED_IPS

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
    # current_dns stays empty without an old .conf: the DNS in the config is then the
    # one render_client_config wrote (CLIENT_DNS or the default), and overwriting it
    # with a hardcoded constant is wrong - that is how CLIENT_DNS got lost on restore.
    local current_dns="" current_keepalive="33" current_allowed_ips="${ALLOWED_IPS:-0.0.0.0/0}"
    local _had_conf=0
    if [[ -f "$AWG_DIR/${name}.conf" ]]; then
        _had_conf=1
        local _v _raw
        # tr -d '[:space:]' stripped the spaces after commas here, so regen
        # wrote the collapsed list into .conf (D#38). Normalise, do not strip.
        #
        # The lines are JOINED rather than taking the first one: wg allows DNS
        # and AllowedIPs to repeat, and the values add up. The old `tr` glued
        # them into a plainly invalid CIDR and awg-quick refused to bring the
        # interface up LOUDLY; taking the first line would instead hand the user
        # a valid config with part of the networks silently gone.
        _raw=$(sed -n 's/^DNS[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf")
        _awg_warn_multiline "$_raw" "DNS" "$name"
        _v=$(awg_normalize_csv "$(printf '%s' "$_raw" | paste -sd, -)")
        [[ -n "$_v" ]] && current_dns="$_v"
        _v=$(sed -n 's/^PersistentKeepalive[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf" | tr -d '[:space:]')
        [[ -n "$_v" ]] && current_keepalive="$_v"
        _raw=$(sed -n '/^\[Peer\]/,$ s/^AllowedIPs[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf")
        _awg_warn_multiline "$_raw" "AllowedIPs" "$name"
        _v=$(awg_normalize_csv "$(printf '%s' "$_raw" | paste -sd, -)")
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

    # Same port guard as generate_client: a broken AWG_PORT must not reach the
    # Endpoint of the regenerated .conf.
    local _cport
    _cport=$(_sanitize_port "${AWG_PORT:-}")
    if [[ "$_cport" == "0" ]]; then
        log_error "AWG_PORT is invalid ('${AWG_PORT:-}') - config for '$name' was not regenerated. Check ListenPort in $SERVER_CONF_FILE (or AWG_PORT in $CONFIG_FILE)."
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    fi

    # Config regeneration (pass client_ipv6 if dual-stack). A live client's DNS goes
    # to render directly (see _AWG_KEEP_DNS there): it is restored below anyway.
    local _AWG_KEEP_DNS=""
    [[ "$_had_conf" -eq 1 && -n "$current_dns" ]] && _AWG_KEEP_DNS="$current_dns"
    render_client_config "$name" "$client_ip" "$client_privkey" "$server_pubkey" "$endpoint" "$_cport" "$client_ipv6" || {
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    }

    # On regen, pull in the new defaults for non-customized clients: a full
    # tunnel gets an IPv6 route (::/0 with 0.0.0.0/0, 2000::/3 for the mode-2
    # list; needed by iOS AmneziaVPN, and it closes the IPv6 leak), a single
    # DNS 1.1.1.1 becomes a pair with a fallback. Split routing set by
    # the user via modify is not a full tunnel and is kept as-is.
    # This fork lives here on purpose: without it, re-issuing a profile would
    # not deliver the fix to already issued clients, and "update your profile"
    # would not cure the leak.
    # All of this only matters when the saved settings are going to be restored.
    # Under --reset-routes, and on the recovery path where there was no config,
    # the value below is not used at all, and a refusal over it would fail a
    # re-issue that had already succeeded.
    if [[ "${AWG_REGEN_RESET_ROUTES:-0}" != "1" && "$_had_conf" -eq 1 ]]; then
        local _aip_new
        # Our earlier ::/0 on a mode-2 list (v5.31.0-v5.36.x) cuts off the local
        # network on Windows; a plain regen has to deliver the replacement. For a
        # dual-stack client ::/0 is its own scheme and stays.
        if [[ -z "$client_ipv6" ]]; then
            _aip_new=$(_aip_migrate_legacy_v6 "$current_allowed_ips" "${ALLOWED_IPS:-}") && [[ -n "$_aip_new" ]] || {
                log_error "Could not compute AllowedIPs for client '$name'. The config has already been regenerated from the current routing mode, but individual settings were NOT restored - check $AWG_DIR/${name}.conf."
                exec {lock_fd}>&-
                unset CLIENT_PSK
                return 1
            }
            if [[ "$_aip_new" != "$current_allowed_ips" ]]; then
                log "Client '$name': IPv6 route ::/0 replaced with 2000::/3 (with ::/0 the Windows client cuts off the local network)."
                current_allowed_ips="$_aip_new"
            elif _aip_has_token "$current_allowed_ips" "::/0" \
                 && ! _aip_has_token "$current_allowed_ips" "0.0.0.0/0" \
                 && _is_full_tunnel "$current_allowed_ips"; then
                # Whether this ::/0 is ours cannot be proven: the server list may
                # have changed since (isolation, subnet), or it was set by hand.
                # Kept, but not silently - this is the cut-off LAN.
                # The hint follows the server's mode: --reset-routes hands out the
                # SERVER list and helps only when that list is mode 2 itself; on
                # mode 1 or 3 it would give 0.0.0.0/0 or a partial list and erase
                # the client's own; with ::/0 in the server list itself it would
                # hand that ::/0 back.
                if [[ "${ALLOWED_IPS:-}" != *:* ]] && ! _aip_has_token "${ALLOWED_IPS:-}" "0.0.0.0/0" \
                   && _is_full_tunnel "${ALLOWED_IPS:-}"; then
                    log_warn "Client '$name': full tunnel with ::/0 kept as is - with ::/0 the AmneziaWG Windows client cuts off the local network. If the route was issued by an earlier installer version, run regen --reset-routes '$name'."
                else
                    log_warn "Client '$name': full tunnel with ::/0 kept as is - with ::/0 the AmneziaWG Windows client cuts off the local network. To keep the network reachable, replace ::/0 with 2000::/3 in its AllowedIPs with modify '$name' AllowedIPs."
                fi
            fi
        fi
        _aip_new=$(_append_ipv6_full_tunnel_route "$current_allowed_ips") && [[ -n "$_aip_new" ]] || {
            # The file has ALREADY been rewritten by render_client_config, so
            # "left unchanged" would be a false statement about state, and that
            # is worse than the failure it replaced: the operator would have no
            # reason to look at the file.
            log_error "Could not compute AllowedIPs for client '$name'. The config has already been regenerated from the current routing mode, but individual settings were NOT restored - check $AWG_DIR/${name}.conf."
            exec {lock_fd}>&-
            unset CLIENT_PSK
            return 1
        }
        # A client issued with --allow-ipv6-tunnel carries its own IPv6 part in
        # the list, and the appender leaves it alone - otherwise a re-issue would
        # break an individual setting. Consequence: such a client does NOT get
        # ::/0 from a plain regen, and the cure is regen --reset-routes.
        # 🔴 The native-IPv6 condition is mandatory: WITHOUT native IPv6 the
        # client is supposed to get the tunnel ULA instead of ::/0 - documented
        # behaviour, not a leak. Without this check the warning would fire always
        # and prescribe a command that changes nothing, sending the operator to
        # fix something that is not broken. Since Issue #253 the condition
        # lives in the _aip_full_tunnel_v6_gap predicate, shared with
        # render_client_config (which creates lists of the same shape).
        if _aip_full_tunnel_v6_gap "$current_allowed_ips"; then
            log_warn "Client '$name': the IPv6 part of AllowedIPs was kept as-is, ::/0 not appended. Run regen --reset-routes to roll out the current routing mode."
        fi
        current_allowed_ips="$_aip_new"
    fi
    # A lone 1.1.1.1 from older versions becomes the pair, but not when it is a
    # deliberate choice through CLIENT_DNS='1.1.1.1'.
    [[ "$current_dns" == "1.1.1.1" && "$(awg_normalize_csv "${CLIENT_DNS:-}")" != "1.1.1.1" ]] && current_dns="1.1.1.1, 1.0.0.1"

    # Restore user settings (escape & and \ for sed replacement)
    local _dns _ka _aip
    _dns=$(printf '%s' "$current_dns" | sed 's/[&\\/]/\\&/g')
    _ka=$(printf '%s' "$current_keepalive" | sed 's/[&\\/]/\\&/g')
    _aip=$(printf '%s' "$current_allowed_ips" | sed 's/[&\\/]/\\&/g')
    local _client_conf="$AWG_DIR/${name}.conf"
    if [[ -n "$current_dns" ]]; then
        if ! sed -i "s/^DNS = .*/DNS = ${_dns}/" "$_client_conf"; then
            log_error "sed error writing DNS to $_client_conf"
            exec {lock_fd}>&-
            unset CLIENT_PSK
            return 1
        fi
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
    elif [[ "$_had_conf" -eq 0 ]]; then
        # There was no config (regen used as recovery), so there is nothing to
        # preserve and the value from render_client_config stands. Previously the
        # global list was substituted here, which handed ::/0 to a dual-stack
        # client on a server without native IPv6, against that client's own rule.
        log "Client '$name' had no config - AllowedIPs taken from the current routing mode."
    elif ! sed -i "s/^AllowedIPs = .*/AllowedIPs = ${_aip}/" "$_client_conf"; then
        log_error "sed error writing AllowedIPs to $_client_conf"
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    fi
    # The restored list may differ from the one render wrote Address for (a
    # custom partial list on a server in mode 2).
    if ! _sync_v6_sink_address "$_client_conf"; then
        log_error "Could not bring the Address of client '$name' in line with its AllowedIPs: the routes in $_client_conf are already written, and the IPv6 sink address may not match them; QR and vpn:// were not rebuilt. Fix the cause and run regen '$name' again."
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

# validate_awg_config : server config check. The parse holds the header protection
# key value in variables, so the body runs with tracing off: under the installer's
# --verbose the key would otherwise land in stderr.
validate_awg_config() {
    _awg_xtrace_guard _validate_awg_config_body "$@"
}

_validate_awg_config_body() {
    if [[ ! -f "$SERVER_CONF_FILE" ]]; then
        log_error "Server config not found: $SERVER_CONF_FILE"
        return 1
    fi

    local ok=1
    local param val
    local int_params=("Jc" "Jmin" "Jmax" "S1" "S2" "S3" "S4")
    local range_params=("H1" "H2" "H3" "H4")

    # The header protection key and content padding are parsed FIRST: the key
    # decides where the other numbers come from. The key rules are switched on by
    # ITS PRESENCE in the file, not by the generation marker: restore checks the
    # restored files, the kernel module and amneziawg-go turn header protection on
    # when a key is present, and the vendor client tells the generation from the
    # presence of such keys in the config. The parse mirrors amneziawg-tools (section and key
    # case-insensitive, last value). Boundary: the check reads the file only and
    # does not see a key left in a live interface.
    local _pairs _sec _k _v _cpa_why _hpk=0 _hpk_count=0 _hpk_val=""
    local -A _if_last=()
    if ! _pairs=$(_awg_conf_pairs "$SERVER_CONF_FILE"); then
        # Without the parse every key rule would silently switch off, including the
        # ContentPaddingAddition cap, which the kernel module does not catch.
        log_error "Could not parse $SERVER_CONF_FILE: the header protection key and ContentPaddingAddition were not checked"
        ok=0
    fi
    while IFS=$'\t' read -r _sec _k _v; do
        [[ -n "$_k" ]] || continue
        case "$_k" in
            headerprotectionkey)
                if [[ "$_sec" != "interface" ]]; then
                    log_error "HeaderProtectionKey is set outside the [Interface] section"
                    ok=0
                    continue
                fi
                _hpk_count=$((_hpk_count + 1))
                _hpk_val="$_v"
                ;;
            contentpaddingaddition)
                # Every line, not the last one. The tools apply the last one, but an
                # out-of-range line is a sign of a manual edit, and refusing is safer
                # than relying on line order.
                if ! _cpa_why=$(awg_cpa_check_safe "$_v"); then
                    log_error "Parameter 'ContentPaddingAddition' is unsafe: ${_cpa_why}"
                    ok=0
                fi
                ;;
        esac
        [[ "$_sec" == "interface" ]] && _if_last[$_k]="$_v"
    done <<< "$_pairs"

    if [[ "$_hpk_count" -ge 1 ]]; then
        _hpk=1
        if [[ "$_hpk_count" -gt 1 ]]; then
            log_error "HeaderProtectionKey is set ${_hpk_count} times in [Interface]: only the last one takes effect, keep a single key"
            ok=0
        # As key_from_base64 in the tools: 44 characters, '=' at the end, the last
        # significant character carries zero low bits. The value is not printed.
        elif ! [[ "$_hpk_val" =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]]; then
            log_error "HeaderProtectionKey does not look like a key: 32 bytes in base64, 44 characters, are expected"
            ok=0
        fi
    fi

    # Without the key, parsing is aligned with load_awg_params_from_server_conf:
    # arbitrary spaces around '=', last-wins for duplicate lines (validate the value that will
    # actually load), trim spaces/CR. Previously the validator required exactly
    # one space and took first-wins - a hand-edited 'Jc=4' loaded fine but
    # failed validation with a bogus "parameter not found".
    # With the key the numbers come from the parse above, as the tools apply them:
    # otherwise a lowercase `s4 = 12` would give a false "not found", and a later
    # `s4 = 33` would slip past the upper bound. Without the key the path is unchanged.
    for param in "${int_params[@]}"; do
        if [[ "$_hpk" -eq 1 ]]; then
            val="${_if_last[${param,,}]:-}"
        else
            val=$(sed -n "s/^[[:space:]]*${param}[[:space:]]*=[[:space:]]*//p" "$SERVER_CONF_FILE" | tail -1 | sed 's/#.*//' | tr -d '[:space:]')
        fi
        if [[ -z "$val" ]]; then
            log_error "Parameter '$param' not found in server config"
            ok=0
        elif ! [[ "$val" =~ ^[0-9]+$ ]]; then
            log_error "Parameter '$param' has invalid value: '$val' (expected integer)"
            ok=0
        elif [[ "$_hpk" -eq 1 ]]; then
            # bash silently wraps a number longer than int64, so 20 digits would pass
            # the comparisons below as a small value. Cut it off before any arithmetic.
            val=$(_awg_dec_strip "$val")
            if (( ${#val} > 10 )) || (( val > 4294967295 )); then
                log_error "Parameter '$param': value exceeds 4294967295"
                ok=0
            fi
        fi
    done

    # Protocol boundary checks (defense-in-depth for restored backups)
    local jc jmin jmax s3 s4
    if [[ "$_hpk" -eq 1 ]]; then
        jc="${_if_last[jc]:-}"
        [[ "$jc" =~ ^[0-9]+$ ]] && jc=$(_awg_dec_strip "$jc")
        jmin="${_if_last[jmin]:-}"
        [[ "$jmin" =~ ^[0-9]+$ ]] && jmin=$(_awg_dec_strip "$jmin")
        jmax="${_if_last[jmax]:-}"
        [[ "$jmax" =~ ^[0-9]+$ ]] && jmax=$(_awg_dec_strip "$jmax")
        s3="${_if_last[s3]:-}"
        [[ "$s3" =~ ^[0-9]+$ ]] && s3=$(_awg_dec_strip "$s3")
        s4="${_if_last[s4]:-}"
        [[ "$s4" =~ ^[0-9]+$ ]] && s4=$(_awg_dec_strip "$s4")
    else
        jc=$(sed -n 's/^[[:space:]]*Jc[[:space:]]*=[[:space:]]*//p' "$SERVER_CONF_FILE" | tail -1 | sed 's/#.*//' | tr -d '[:space:]')
        jmin=$(sed -n 's/^[[:space:]]*Jmin[[:space:]]*=[[:space:]]*//p' "$SERVER_CONF_FILE" | tail -1 | sed 's/#.*//' | tr -d '[:space:]')
        jmax=$(sed -n 's/^[[:space:]]*Jmax[[:space:]]*=[[:space:]]*//p' "$SERVER_CONF_FILE" | tail -1 | sed 's/#.*//' | tr -d '[:space:]')
        s3=$(sed -n 's/^[[:space:]]*S3[[:space:]]*=[[:space:]]*//p' "$SERVER_CONF_FILE" | tail -1 | sed 's/#.*//' | tr -d '[:space:]')
        s4=$(sed -n 's/^[[:space:]]*S4[[:space:]]*=[[:space:]]*//p' "$SERVER_CONF_FILE" | tail -1 | sed 's/#.*//' | tr -d '[:space:]')
    fi
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

    if [[ "$_hpk" -eq 1 ]]; then
    # With the key the first 12 bytes of the S padding serve as the nonce, and both
    # the kernel module (netlink.c) and amneziawg-go (uapi.go) reject S below 12.
    # Presence and form were checked by the loop above on the same parse, and it
    # already refused numbers past uint32; leading zeros do not hide a small number.
        local _sn _sv
        for _sn in s1 s2 s3 s4; do
            _sv="${_if_last[$_sn]:-}"
            [[ "$_sv" =~ ^[0-9]+$ ]] || continue
            _sv=$(_awg_dec_strip "$_sv")
            if (( ${#_sv} <= 10 )) && (( _sv < 12 )); then
                log_error "${_sn^^}=${_if_last[$_sn]} is below 12: with HeaderProtectionKey the first 12 bytes of the S padding serve as the nonce, and both the kernel module and amneziawg-go reject such a config"
                ok=0
            fi
        done
    fi

    local _h_ranges=()
    for param in "${range_params[@]}"; do
        # With the key H comes from the same parse. Without the key our profile
        # requires ranges (protection against a fingerprint by H); with the key the
        # header is closed and a single number reveals nothing, so it is allowed.
        # The protocol accepts a single number either way. Without the key the path
        # is unchanged.
        if [[ "$_hpk" -eq 1 ]]; then
            val="${_if_last[${param,,}]:-}"
        else
            val=$(sed -n "s/^[[:space:]]*${param}[[:space:]]*=[[:space:]]*//p" "$SERVER_CONF_FILE" | tail -1 | sed 's/#.*//' | tr -d '[:space:]')
        fi
        if [[ -z "$val" ]]; then
            log_error "Parameter '$param' not found in server config"
            ok=0
        elif [[ "$_hpk" -eq 1 && "$val" =~ ^[0-9]+$ ]]; then
            # H numbers are read in base 10, as the tools do (strtoul, base 10):
            # without stripping zeros 010 would be octal 8, and 08 an error after
            # which the pair is silently not compared. The significant length is
            # checked BEFORE arithmetic.
            val=$(_awg_dec_strip "$val")
            if (( ${#val} > 10 )) || (( val > 4294967295 )); then
                log_error "Parameter '$param': value exceeds 4294967295"
                ok=0
            else
                _h_ranges+=("$val $val $param")
            fi
        elif ! [[ "$val" =~ ^[0-9]+-[0-9]+$ ]]; then
            log_error "Parameter '$param' has invalid value: '$val' (expected MIN-MAX format)"
            ok=0
        else
            local range_lo range_hi
            range_lo=$(_awg_dec_strip "${val%-*}")
            range_hi=$(_awg_dec_strip "${val#*-}")
            # Bounds without leading zeros too, with the length checked before
            # arithmetic. Without the key the range is strictly increasing, as before;
            # with the key N-N is also fine, it is the same scalar.
            if (( ${#range_lo} > 10 || ${#range_hi} > 10 )) || (( range_lo > 4294967295 || range_hi > 4294967295 )); then
                log_error "Parameter '$param': a range bound exceeds 4294967295"
                ok=0
            elif (( range_lo > range_hi )) || [[ "$_hpk" -ne 1 && "$range_lo" -eq "$range_hi" ]]; then
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

    # I1-I5: the same dangerous lengths load_awg_params refuses. restore runs the
    # validator BEFORE starting the service and rolls back on a refusal, so this
    # is where a dangerous backup is kept off the live interface.
    # 🔴 EVERY I1-I5 line of the file is checked, in any case and any section,
    # not the loader's values. The config is applied not by the loader but by
    # amneziawg-tools, which match the key and the section header regardless of
    # case, so `i1 = ` and an `I1` under a second `[interface]` header reach the
    # device while the loader never sees them. A superset cannot hide the real
    # value; an extra refusal can only fall on a [Peer] line, which the tools
    # reject by themselves.
    local _cps_line _cps_key _cps_why
    while IFS= read -r _cps_line || [[ -n "$_cps_line" ]]; do
        [[ "$_cps_line" =~ ^[[:space:]]*([Ii][1-5])[[:space:]]*=(.*)$ ]] || continue
        _cps_key="${BASH_REMATCH[1]}"
        if ! _cps_why=$(awg_cps_check_safe "${BASH_REMATCH[2]}"); then
            log_error "Parameter '$_cps_key' is unsafe: ${_cps_why} (upstream amneziawg-linux-kernel-module#233)"
            ok=0
        fi
    done < "$SERVER_CONF_FILE"

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
        # The exit status is captured the same way list_clients does it: cat
        # can emit parseable bytes and still fail (an I/O error, a truncated
        # read). Without the check THIS reader - the only one of the three that
        # deletes - would act on data from a failed read.
        local _exp_rc=0
        expires_at=$(cat "$efile" 2>/dev/null) || _exp_rc=$?
        if [[ "$_exp_rc" -ne 0 ]]; then
            log_warn "Expiry marker for '$name' was not read (status $_exp_rc) - leaving the client alone."
            continue
        fi
        # A canonical decimal of at most 15 digits - the same form list_clients
        # uses, and the two must not diverge. The previous ^[0-9]+$ accepted a
        # leading zero, and the comparison below reads such a value as OCTAL:
        # the marker 01750000000 became 262144000, that is 1978, the condition
        # fired and the client was removed silently on a bogus date. With a
        # value containing 8 or 9 the comparison instead failed with 'value too
        # great for base', evaluated false and the client stayed - one and the
        # same corruption behaving in two different ways. The length bound
        # closes the third path: a value beyond bash integer range wraps
        # silently in arithmetic.
        if [[ -z "$expires_at" || ! "$expires_at" =~ ^(0|[1-9][0-9]*)$ || "${#expires_at}" -gt 15 ]]; then
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
