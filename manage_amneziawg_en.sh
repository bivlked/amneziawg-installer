#!/bin/bash

# Minimum Bash version check
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "ERROR: Bash >= 4.0 required (current: ${BASH_VERSION})" >&2; exit 1
fi

# ==============================================================================
# AmneziaWG 2.0 peer management script
# Author: @bivlked
# Version: 5.10.1
# Date: 2026-04-16
# Repository: https://github.com/bivlked/amneziawg-installer
# ==============================================================================

# --- Safe mode and Constants ---
# shellcheck disable=SC2034
SCRIPT_VERSION="5.10.1"
set -o pipefail
AWG_DIR="/root/awg"
SERVER_CONF_FILE="/etc/amnezia/amneziawg/awg0.conf"
CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init"
KEYS_DIR="$AWG_DIR/keys"
COMMON_SCRIPT_PATH="$AWG_DIR/awg_common.sh"
LOG_FILE="$AWG_DIR/manage_amneziawg.log"
NO_COLOR=0
VERBOSE_LIST=0
JSON_OUTPUT=0
EXPIRES_DURATION=""

# --- Auto-cleanup of temporary files and directories ---
# _manage_temp_dirs holds mktemp -d paths for backup/restore.
# _awg_cleanup from awg_common.sh removes files (awg_mktemp), but not
# directories — so this is chained cleanup: first our directories, then
# the library one. Ensures that SIGINT during backup_configs/restore_backup
# does not leave orphan /tmp/tmp.XXXX (audit).
_manage_temp_dirs=()

manage_mktempdir() {
    local d
    d=$(mktemp -d) || return 1
    _manage_temp_dirs+=("$d")
    echo "$d"
}

_manage_cleanup() {
    local d
    for d in "${_manage_temp_dirs[@]}"; do
        [[ -d "$d" ]] && rm -rf "$d"
    done
    type _awg_cleanup &>/dev/null && _awg_cleanup
}
trap _manage_cleanup EXIT INT TERM

# --- Argument handling ---
COMMAND=""
ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)         COMMAND="help"; break ;;
        -v|--verbose)      VERBOSE_LIST=1; shift ;;
        --no-color)        NO_COLOR=1; shift ;;
        --json)            JSON_OUTPUT=1; shift ;;
        --expires=*)       EXPIRES_DURATION="${1#*=}"; shift ;;
        --conf-dir=*)      AWG_DIR="${1#*=}"; shift ;;
        --server-conf=*)   SERVER_CONF_FILE="${1#*=}"; shift ;;
        --apply-mode=*)    _CLI_APPLY_MODE="${1#*=}"; export AWG_APPLY_MODE="$_CLI_APPLY_MODE"; shift ;;
        --*)               echo "Unknown option: $1" >&2; COMMAND="help"; break ;;
        *)
            if [[ -z "$COMMAND" ]]; then
                COMMAND=$1
            else
                ARGS+=("$1")
            fi
            shift ;;
    esac
done
CLIENT_NAME="${ARGS[0]}"
PARAM="${ARGS[1]}"
VALUE="${ARGS[2]}"

# Update paths after possible --conf-dir override
CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init"
KEYS_DIR="$AWG_DIR/keys"
COMMON_SCRIPT_PATH="$AWG_DIR/awg_common.sh"
LOG_FILE="$AWG_DIR/manage_amneziawg.log"

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

    if [[ "$type" == "ERROR" ]]; then
        printf "${color_start}%s${color_end}\n" "$entry" >&2
    else
        printf "${color_start}%s${color_end}\n" "$entry"
    fi
}

log()       { log_msg "INFO" "$1"; }
log_warn()  { log_msg "WARN" "$1"; }
log_error() { log_msg "ERROR" "$1"; }
log_debug() { if [[ "$VERBOSE_LIST" -eq 1 ]]; then log_msg "DEBUG" "$1"; fi; }
die()       { log_error "$1"; exit 1; }

# ==============================================================================
# Utilities
# ==============================================================================

is_interactive() { [[ -t 0 && -t 1 ]]; }

# Escape special characters for sed (prevents command injection)
escape_sed() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//&/\\&}"
    s="${s//#/\\#}"
    s="${s////\\/}"
    printf '%s' "$s"
}

confirm_action() {
    if ! is_interactive; then return 0; fi
    local action="$1" subject="$2"
    read -rp "Are you sure you want to $action $subject? [y/N]: " confirm < /dev/tty
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        return 0
    else
        log "Action cancelled."
        return 1
    fi
}

validate_client_name() {
    local name="$1"
    if [[ -z "$name" ]]; then log_error "Name is empty."; return 1; fi
    if [[ ${#name} -gt 63 ]]; then log_error "Name exceeds 63 chars."; return 1; fi
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then log_error "Name contains invalid characters."; return 1; fi
    return 0
}

# ==============================================================================
# Dependency check
# ==============================================================================

check_dependencies() {
    log "Checking dependencies..."
    local ok=1

    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Not found: $CONFIG_FILE"
        ok=0
    fi
    if [[ ! -f "$COMMON_SCRIPT_PATH" ]]; then
        log_error "Not found: $COMMON_SCRIPT_PATH"
        ok=0
    fi
    if [[ ! -f "$SERVER_CONF_FILE" ]]; then
        log_error "Not found: $SERVER_CONF_FILE"
        ok=0
    fi
    if [[ "$ok" -eq 0 ]]; then
        die "Installation files not found. Run install_amneziawg_en.sh."
    fi

    if ! command -v awg &>/dev/null; then die "'awg' not found."; fi
    if ! command -v qrencode &>/dev/null; then log_warn "qrencode not found (QR codes will not be created)."; fi

    # Load common library
    # shellcheck source=/dev/null
    source "$COMMON_SCRIPT_PATH" || die "Failed to load $COMMON_SCRIPT_PATH"

    log "Dependencies OK."
}

# ==============================================================================
# Backup
# ==============================================================================

# Internal function: performs backup without acquiring a lock.
# Called only from a context where .awg_backup.lock is already held.
_backup_configs_nolock() {
    log "Creating backup..."
    local bd="$AWG_DIR/backups"
    mkdir -p "$bd" || die "mkdir error $bd"
    chmod 700 "$bd" 2>/dev/null
    local ts bf td
    ts=$(date +%F_%H-%M-%S)
    bf="$bd/awg_backup_${ts}.tar.gz"
    td=$(manage_mktempdir) || die "Failed to create temp directory"

    mkdir -p "$td/server" "$td/clients" "$td/keys"
    cp -a "$SERVER_CONF_FILE"* "$td/server/" 2>/dev/null
    cp -a "$AWG_DIR"/*.conf "$AWG_DIR"/*.png "$AWG_DIR"/*.vpnuri "$CONFIG_FILE" "$td/clients/" 2>/dev/null || true
    cp -a "$KEYS_DIR"/* "$td/keys/" 2>/dev/null || true
    cp -a "$AWG_DIR/server_private.key" "$AWG_DIR/server_public.key" "$td/" 2>/dev/null || true
    if [[ -d "${EXPIRY_DIR:-$AWG_DIR/expiry}" ]]; then
        cp -a "${EXPIRY_DIR:-$AWG_DIR/expiry}" "$td/expiry" 2>/dev/null || true
    fi
    [[ -f /etc/cron.d/awg-expiry ]] && cp -a /etc/cron.d/awg-expiry "$td/" 2>/dev/null || true

    tar -czf "$bf" -C "$td" . || { rm -rf "$td"; die "tar error $bf"; }
    log_debug "tar: archive created $bf"
    rm -rf "$td"
    chmod 600 "$bf" || log_warn "chmod error on backup"

    # Keep maximum 10 backups
    find "$bd" -maxdepth 1 -name "awg_backup_*.tar.gz" -printf '%T@ %p\n' | \
        sort -nr | tail -n +11 | cut -d' ' -f2- | xargs -r rm -f || \
        log_warn "Error deleting old backups"

    log "Backup created: $bf"
}

backup_configs() {
    local backup_lockfile="${AWG_DIR}/.awg_backup.lock"
    local backup_lock_fd
    exec {backup_lock_fd}>"$backup_lockfile"
    if ! flock -x -w 30 "$backup_lock_fd"; then
        log_error "Backup lock timeout (30 sec). Another backup/restore operation is already running."
        exec {backup_lock_fd}>&-
        return 1
    fi
    _backup_configs_nolock
    local _rc=$?
    exec {backup_lock_fd}>&-
    return "$_rc"
}

restore_backup() {
    local bf="$1"
    local bd="$AWG_DIR/backups"

    if [[ -z "$bf" ]]; then
        if ! is_interactive; then
            die "Backup file path is required in non-interactive mode: restore <file>"
        fi
        if [[ ! -d "$bd" ]] || [[ -z "$(ls -A "$bd" 2>/dev/null)" ]]; then
            die "No backups found in $bd."
        fi
        local backups
        backups=$(find "$bd" -maxdepth 1 -name "awg_backup_*.tar.gz" | sort -r)
        if [[ -z "$backups" ]]; then die "No backups found."; fi

        echo "Available backups:"
        local i=1
        local bl=()
        while IFS= read -r f; do
            echo "  $i) $(basename "$f")"
            bl[$i]="$f"
            ((i++))
        done <<< "$backups"

        read -rp "Number to restore (0-cancel): " choice < /dev/tty
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -eq 0 ]] || [[ "$choice" -ge "$i" ]]; then
            log "Cancelled."
            return 1
        fi
        bf="${bl[$choice]}"
    fi

    if [[ ! -f "$bf" ]]; then die "Backup file '$bf' not found."; fi
    log "Restoring from $bf"
    if ! confirm_action "restore" "configuration from '$bf'"; then return 1; fi

    # Acquire backup lock (outer) — prevents concurrent backup/restore operations
    local backup_lockfile="${AWG_DIR}/.awg_backup.lock"
    local backup_lock_fd
    exec {backup_lock_fd}>"$backup_lockfile"
    if ! flock -x -w 30 "$backup_lock_fd"; then
        log_error "Backup lock timeout (30 sec). Another backup/restore operation is already running."
        exec {backup_lock_fd}>&-
        return 1
    fi

    # Acquire config lock (inner) — prevents config changes during restore
    local config_lockfile="${AWG_DIR}/.awg_config.lock"
    local config_lock_fd
    exec {config_lock_fd}>"$config_lockfile"
    if ! flock -x -w 30 "$config_lock_fd"; then
        log_error "Config lock timeout (30 sec)."
        exec {config_lock_fd}>&-
        exec {backup_lock_fd}>&-
        return 1
    fi

    log "Backing up current config..."
    if ! _backup_configs_nolock; then
        log_error "Failed to create backup of current configuration."
        exec {config_lock_fd}>&-
        exec {backup_lock_fd}>&-
        return 1
    fi

    local td
    td=$(manage_mktempdir) || {
        log_error "Failed to create temp directory"
        exec {config_lock_fd}>&-
        exec {backup_lock_fd}>&-
        return 1
    }

    # Pre-extraction validation: inspect tar contents before unpacking.
    # Defense-in-depth: our threat model (root-only local backups) makes
    # exploitation unlikely, but a crafted or substituted archive could use
    # path traversal (../), absolute paths, symlinks or device files to
    # overwrite arbitrary system files when extracted as root.

    # Type check via verbose listing: reject block/char/FIFO/hardlink entries
    local _tar_verbose _vline _tc
    _tar_verbose=$(tar -tvzf "$bf" 2>/dev/null) || {
        log_error "Cannot read archive contents: $bf"
        rm -rf "$td"
        exec {config_lock_fd}>&-
        exec {backup_lock_fd}>&-
        return 1
    }
    while IFS= read -r _vline; do
        [[ -z "$_vline" ]] && continue
        _tc="${_vline:0:1}"
        case "$_tc" in
            b|c|p|h|l)
                log_error "Archive contains dangerous entry type ('${_tc}'): '${_vline}' — restore aborted."
                rm -rf "$td"
                exec {config_lock_fd}>&-
                exec {backup_lock_fd}>&-
                return 1
                ;;
        esac
    done <<< "$_tar_verbose"

    # Path check: absolute paths and path traversal
    local _tar_list _bad_entry
    _tar_list=$(tar -tzf "$bf" 2>/dev/null) || {
        log_error "Cannot read archive contents: $bf"
        rm -rf "$td"
        exec {config_lock_fd}>&-
        exec {backup_lock_fd}>&-
        return 1
    }
    while IFS= read -r _bad_entry; do
        [[ -z "$_bad_entry" ]] && continue
        # Absolute paths
        if [[ "$_bad_entry" == /* ]]; then
            log_error "Archive contains absolute path: '$_bad_entry' — restore aborted."
            rm -rf "$td"
            exec {config_lock_fd}>&-
            exec {backup_lock_fd}>&-
            return 1
        fi
        # Parent directory traversal
        if [[ "$_bad_entry" == *..* ]]; then
            log_error "Archive contains path traversal (..): '$_bad_entry' — restore aborted."
            rm -rf "$td"
            exec {config_lock_fd}>&-
            exec {backup_lock_fd}>&-
            return 1
        fi
    done <<< "$_tar_list"
    log_debug "Pre-extraction check passed: $(echo "$_tar_list" | wc -l) files in archive."

    if ! tar -xzf "$bf" --no-same-owner --no-same-permissions -C "$td"; then
        log_error "tar error $bf"
        rm -rf "$td"
        exec {config_lock_fd}>&-
        exec {backup_lock_fd}>&-
        return 1
    fi

    # Post-extraction check: no symlinks in the unpacked tree
    local _symlinks
    _symlinks=$(find "$td" -type l 2>/dev/null)
    if [[ -n "$_symlinks" ]]; then
        log_error "Archive contains symlinks (possible symlink attack):"
        while IFS= read -r _sl; do log_error "  $_sl -> $(readlink "$_sl")"; done <<< "$_symlinks"
        rm -rf "$td"
        exec {config_lock_fd}>&-
        exec {backup_lock_fd}>&-
        return 1
    fi

    log "Stopping service..."
    systemctl stop awg-quick@awg0 || log_warn "Service not stopped."

    if [[ -d "$td/server" ]]; then
        log "Restoring server config..."
        local server_conf_dir
        server_conf_dir=$(dirname "$SERVER_CONF_FILE")
        mkdir -p "$server_conf_dir"
        cp -a "$td/server/"* "$server_conf_dir/" || {
            log_error "Error copying server — restore aborted."
            rm -rf "$td"
            exec {config_lock_fd}>&-
            exec {backup_lock_fd}>&-
            return 1
        }
        chmod 600 "$server_conf_dir"/*.conf 2>/dev/null
        chmod 700 "$server_conf_dir"
        log_debug "Server config restored to $server_conf_dir"
    fi

    if [[ -d "$td/clients" ]]; then
        log "Restoring client files..."
        cp -a "$td/clients/"* "$AWG_DIR/" || {
            log_error "Error copying clients — restore aborted."
            rm -rf "$td"
            exec {config_lock_fd}>&-
            exec {backup_lock_fd}>&-
            return 1
        }
        chmod 600 "$AWG_DIR"/*.conf 2>/dev/null
        chmod 600 "$AWG_DIR"/*.png 2>/dev/null
        chmod 600 "$AWG_DIR"/*.vpnuri 2>/dev/null
        chmod 600 "$CONFIG_FILE" 2>/dev/null
        log_debug "Client files restored to $AWG_DIR"
    fi

    if [[ -d "$td/keys" ]]; then
        log "Restoring keys..."
        mkdir -p "$KEYS_DIR"
        cp -a "$td/keys/"* "$KEYS_DIR/" || {
            log_error "Error copying keys — restore aborted."
            rm -rf "$td"
            exec {config_lock_fd}>&-
            exec {backup_lock_fd}>&-
            return 1
        }
        chmod 600 "$KEYS_DIR"/* 2>/dev/null
        log_debug "Keys restored to $KEYS_DIR"
    fi

    # Server keys: cp -a preserves the mode from the archive, so we force 600
    # regardless of the mode they had inside the backup (audit fix).
    if [[ -f "$td/server_private.key" ]]; then
        cp -a "$td/server_private.key" "$AWG_DIR/" || {
            log_error "Error copying server_private.key — restore aborted."
            rm -rf "$td"
            exec {config_lock_fd}>&-
            exec {backup_lock_fd}>&-
            return 1
        }
        chmod 600 "$AWG_DIR/server_private.key" 2>/dev/null || true
    fi
    if [[ -f "$td/server_public.key" ]]; then
        cp -a "$td/server_public.key" "$AWG_DIR/" || {
            log_error "Error copying server_public.key — restore aborted."
            rm -rf "$td"
            exec {config_lock_fd}>&-
            exec {backup_lock_fd}>&-
            return 1
        }
        chmod 600 "$AWG_DIR/server_public.key" 2>/dev/null || true
    fi

    if [[ -d "$td/expiry" ]]; then
        log "Restoring expiry data..."
        mkdir -p "${EXPIRY_DIR:-$AWG_DIR/expiry}"
        cp -a "$td/expiry/"* "${EXPIRY_DIR:-$AWG_DIR/expiry}/" 2>/dev/null || true
        chmod 600 "${EXPIRY_DIR:-$AWG_DIR/expiry}"/* 2>/dev/null
    fi
    if [[ -f "$td/awg-expiry" ]]; then
        cp -a "$td/awg-expiry" /etc/cron.d/awg-expiry
        chmod 644 /etc/cron.d/awg-expiry
    fi

    rm -rf "$td"

    # Release locks before starting service — file operations complete
    exec {config_lock_fd}>&-
    exec {backup_lock_fd}>&-

    log "Starting service..."
    if ! systemctl start awg-quick@awg0; then
        log_error "Service start error!"
        local status_out
        status_out=$(systemctl status awg-quick@awg0 --no-pager 2>&1) || true
        while IFS= read -r line; do log_error "  $line"; done <<< "$status_out"
        return 1
    fi
    log "Restore completed."
}

# ==============================================================================
# Modify client parameter
# ==============================================================================

modify_client() {
    local name="$1" param="$2" value="$3"

    if [[ -z "$name" || -z "$param" || -z "$value" ]]; then
        log_error "Usage: modify <name> <param> <value>"
        return 1
    fi

    # Validation BEFORE taking the lock (early returns need no fd cleanup)
    local allowed_params="DNS|Endpoint|AllowedIPs|PersistentKeepalive"
    if ! [[ "$param" =~ ^($allowed_params)$ ]]; then
        log_error "Parameter '$param' cannot be changed via modify."
        log_error "Allowed parameters: ${allowed_params//|/, }"
        return 1
    fi

    case "$param" in
        DNS)
            if ! [[ "$value" =~ ^[0-9a-fA-F.:,\ ]+$ ]]; then
                log_error "Invalid DNS: '$value' (expected comma-separated IPs)"
                return 1
            fi ;;
        PersistentKeepalive)
            if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -gt 65535 ]]; then
                log_error "Invalid PersistentKeepalive: '$value' (expected: 0-65535)"
                return 1
            fi ;;
        Endpoint)
            case "$value" in
                *$'\n'*|*$'\r'*|*\\*|*\"*|*\'*|"")
                    log_error "Invalid Endpoint: '$value'"
                    return 1 ;;
            esac ;;
        AllowedIPs)
            case "$value" in
                *$'\n'*|*$'\r'*|*\\*|*\"*|*\'*|"")
                    log_error "Invalid AllowedIPs: '$value'"
                    return 1 ;;
            esac ;;
    esac

    # Lock before state checks (TOCTOU protection against concurrent remove)
    local modify_lockfile="${AWG_DIR}/.awg_config.lock"
    local modify_lock_fd
    exec {modify_lock_fd}>"$modify_lockfile"
    if ! flock -x -w 10 "$modify_lock_fd"; then
        log_error "Could not acquire config lock (another operation in progress)"
        return 1
    fi

    if ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE"; then
        exec {modify_lock_fd}>&-
        die "Client '$name' not found."
    fi

    local cf="$AWG_DIR/$name.conf"
    if [[ ! -f "$cf" ]]; then exec {modify_lock_fd}>&-; die "File $cf not found."; fi

    if ! grep -q -E "^${param}[[:space:]]*=" "$cf"; then
        log_error "Parameter '$param' not found in $cf."
        exec {modify_lock_fd}>&-
        return 1
    fi

    log "Changing '$param' to '$value' for '$name'..."
    local bak
    bak="${cf}.bak-$(date +%F_%H-%M-%S)"
    cp "$cf" "$bak" || log_warn "Backup error $bak"
    log "Backup: $bak"

    local escaped_value
    escaped_value=$(escape_sed "$value")
    if ! sed -i "s#^${param}[[:space:]]*=[[:space:]]*.*#${param} = ${escaped_value}#" "$cf"; then
        log_error "sed error. Restoring..."
        cp "$bak" "$cf" || log_warn "Restore error."
        exec {modify_lock_fd}>&-
        return 1
    fi
    if ! grep -q -E "^${param} = " "$cf"; then
        log_error "Replacement failed for '$param'. Restoring..."
        cp "$bak" "$cf" || log_warn "Restore error."
        exec {modify_lock_fd}>&-
        return 1
    fi
    log_debug "sed: ${param} = ${value} in $cf"

    log "Parameter '$param' changed."
    rm -f "$bak"

    log "Regenerating QR code and vpn:// URI..."
    generate_qr "$name" || log_warn "Failed to update QR code."
    generate_vpn_uri "$name" || log_warn "Failed to update vpn:// URI."

    exec {modify_lock_fd}>&-
    return 0
}

# ==============================================================================
# Server status check
# ==============================================================================

check_server() {
    log "Checking AmneziaWG 2.0 server status..."
    local ok=1

    log "Service status:"
    if ! systemctl status awg-quick@awg0 --no-pager; then ok=0; fi

    log "Interface awg0:"
    if ! ip addr show awg0 &>/dev/null; then
        log_error " - Interface not found!"
        ok=0
    else
        while IFS= read -r line; do log "  $line"; done < <(ip addr show awg0)
    fi

    log "Port listening:"
    # shellcheck source=/dev/null
    safe_load_config "$CONFIG_FILE" 2>/dev/null
    local port=${AWG_PORT:-0}
    if [[ "$port" -eq 0 ]]; then
        log_warn " - Failed to determine port."
    else
        if ! ss -lunp | grep -q ":${port} "; then
            log_error " - Port ${port}/udp is NOT listening!"
            ok=0
        else
            log " - Port ${port}/udp is listening."
        fi
    fi

    log "Kernel settings:"
    local fwd
    fwd=$(sysctl -n net.ipv4.ip_forward)
    if [[ "$fwd" != "1" ]]; then
        log_error " - IP Forwarding is disabled ($fwd)!"
        ok=0
    else
        log " - IP Forwarding is enabled."
    fi

    log "UFW rules:"
    if command -v ufw &>/dev/null; then
        if ! ufw status | grep -qw "${port}/udp"; then
            log_warn " - UFW rule for ${port}/udp not found!"
        else
            log " - UFW rule for ${port}/udp is present."
        fi
    else
        log_warn " - UFW is not installed."
    fi

    log "AmneziaWG 2.0 status:"
    # Previously awg show was called via process substitution without an exit
    # code check, so check could report "Status OK" even when awg crashed.
    # Now we capture the output and check the exit code (audit).
    local _awg_out
    if ! _awg_out=$(awg show awg0 2>&1); then
        log_error " - awg show awg0 failed:"
        while IFS= read -r _l; do log_error "  $_l"; done <<< "$_awg_out"
        ok=0
    else
        while IFS= read -r _l; do log "  $_l"; done <<< "$_awg_out"
        if grep -q "jc:" <<< "$_awg_out"; then
            log " - AWG 2.0 obfuscation parameters: active"
        else
            log_warn " - AWG 2.0 obfuscation parameters not detected"
        fi
    fi

    if [[ "$ok" -eq 1 ]]; then
        log "Check completed: Status OK."
        return 0
    else
        log_error "Check completed: ISSUES FOUND!"
        return 1
    fi
}

# ==============================================================================
# Client list
# ==============================================================================

list_clients() {
    log "Getting client list..."
    local clients
    clients=$(grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //' | sort) || clients=""
    if [[ -z "$clients" ]]; then
        log "No clients found."
        return 0
    fi

    local verbose=$VERBOSE_LIST
    local act=0 tot=0

    # Single-pass server config parsing: name → pubkey
    local -A _name_to_pk
    local _cn=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "#_Name = "* ]]; then
            _cn="${line#\#_Name = }"
            _cn="${_cn## }"; _cn="${_cn%% }"
        elif [[ -n "$_cn" && "$line" == "PublicKey = "* ]]; then
            local _pk="${line#PublicKey = }"
            _pk="${_pk## }"; _pk="${_pk%% }"
            [[ -n "$_pk" ]] && _name_to_pk["$_cn"]="$_pk"
            _cn=""
        fi
    done < "$SERVER_CONF_FILE"

    # Single-pass awg show dump parsing: pubkey → handshake timestamp
    local -A _pk_to_hs
    local awg_dump
    awg_dump=$(awg show awg0 dump 2>/dev/null) || awg_dump=""
    if [[ -n "$awg_dump" ]]; then
        # shellcheck disable=SC2034
        while IFS=$'\t' read -r _dpk _dpsk _dep _daips _dhs _drx _dtx _dka; do
            _pk_to_hs["$_dpk"]="$_dhs"
        done < <(echo "$awg_dump" | tail -n +2)
    fi

    if [[ $verbose -eq 1 ]]; then
        printf "%-20s | %-7s | %-7s | %-15s | %-15s | %s\n" "Client name" "Conf" "QR" "IP address" "Key (start)" "Status"
        printf -- "-%.0s" {1..95}
        echo
    else
        printf "%-20s | %-7s | %-7s | %s\n" "Client name" "Conf" "QR" "Status"
        printf -- "-%.0s" {1..50}
        echo
    fi

    local now
    now=$(date +%s)

    while IFS= read -r name; do
        name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"
        if [[ -z "$name" ]]; then continue; fi
        ((tot++))

        local cf="?" png="?" pk="-" ip="-" st="No data"
        local color_start="" color_end=""
        if [[ "$NO_COLOR" -eq 0 ]]; then
            color_end="\033[0m"
            color_start="\033[0;37m"
        fi

        [[ -f "$AWG_DIR/${name}.conf" ]] && cf="+"
        [[ -f "$AWG_DIR/${name}.png" ]] && png="+"

        if [[ "$cf" == "+" ]]; then
            ip=$(grep -oP 'Address = \K[0-9.]+' "$AWG_DIR/${name}.conf" 2>/dev/null) || ip="?"

            local current_pk="${_name_to_pk[$name]:-}"

            if [[ -n "$current_pk" ]]; then
                pk="${current_pk:0:10}..."
                local handshake="${_pk_to_hs[$current_pk]:-0}"
                if [[ "$handshake" =~ ^[0-9]+$ && "$handshake" -gt 0 ]]; then
                    local diff=$((now - handshake))
                    if [[ $diff -lt 180 ]]; then
                        st="Active"
                        [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;32m"
                        ((act++))
                    elif [[ $diff -lt 86400 ]]; then
                        st="Recent"
                        [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;33m"
                        ((act++))
                    else
                        st="No handshake"
                        [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;37m"
                    fi
                else
                    st="No handshake"
                    [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;37m"
                fi
            else
                pk="?"
                st="Key error"
                [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;31m"
            fi
        fi

        # Expiry info
        local exp_str=""
        local exp_ts
        exp_ts=$(get_client_expiry "$name" 2>/dev/null)
        if [[ -n "$exp_ts" ]]; then
            exp_str=" [$(format_remaining "$exp_ts")]"
        fi

        if [[ $verbose -eq 1 ]]; then
            printf "%-20s | %-7s | %-7s | %-15s | %-15s | ${color_start}%s${color_end}%s\n" "$name" "$cf" "$png" "$ip" "$pk" "$st" "$exp_str"
        else
            printf "%-20s | %-7s | %-7s | ${color_start}%s${color_end}%s\n" "$name" "$cf" "$png" "$st" "$exp_str"
        fi
    done <<< "$clients"
    echo ""
    log "Total clients: $tot, Active/Recent: $act"
}

# ==============================================================================
# Traffic statistics
# ==============================================================================

# Escape string for safe JSON inclusion
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# Format bytes to human-readable
format_bytes() {
    local bytes="${1:-0}"
    if [[ ! "$bytes" =~ ^[0-9]+$ ]]; then printf "0 B"; return; fi
    if [[ "$bytes" -ge 1073741824 ]]; then
        awk "BEGIN{printf \"%.2f GiB\", $bytes/1073741824}"
    elif [[ "$bytes" -ge 1048576 ]]; then
        awk "BEGIN{printf \"%.2f MiB\", $bytes/1048576}"
    elif [[ "$bytes" -ge 1024 ]]; then
        awk "BEGIN{printf \"%.1f KiB\", $bytes/1024}"
    else
        printf "%d B" "$bytes"
    fi
}

stats_clients() {
    local clients
    clients=$(grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //' | sort) || clients=""
    if [[ -z "$clients" ]]; then
        if [[ "$JSON_OUTPUT" -eq 1 ]]; then
            echo "[]"
        else
            log "No clients found."
        fi
        return 0
    fi

    # Get awg show data
    local awg_dump
    awg_dump=$(awg show awg0 dump 2>/dev/null) || {
        log_error "Failed to get awg show data."
        return 1
    }

    # Map: public key -> client name (single-pass)
    local -A pk_to_name
    local _current_name=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "#_Name = "* ]]; then
            _current_name="${line#\#_Name = }"
            _current_name="${_current_name## }"; _current_name="${_current_name%% }"
        elif [[ -n "$_current_name" && "$line" == "PublicKey = "* ]]; then
            local _pk="${line#PublicKey = }"
            _pk="${_pk## }"; _pk="${_pk%% }"
            [[ -n "$_pk" ]] && pk_to_name["$_pk"]="$_current_name"
            _current_name=""
        fi
    done < "$SERVER_CONF_FILE"

    local json_entries=()
    local table_rows=()
    local total_rx=0 total_tx=0

    # awg show dump: each peer line = pubkey psk endpoint allowed-ips latest-handshake rx tx keepalive
    # shellcheck disable=SC2034
    while IFS=$'\t' read -r pk psk ep aips handshake rx tx keepalive; do
        local cname="${pk_to_name[$pk]:-unknown}"
        if [[ "$cname" == "unknown" ]]; then continue; fi

        local ip="-"
        if [[ -f "$AWG_DIR/${cname}.conf" ]]; then
            ip=$(grep -oP 'Address = \K[0-9.]+' "$AWG_DIR/${cname}.conf" 2>/dev/null) || ip="?"
        fi

        local hs_str="never"
        local status="Inactive"
        if [[ "$handshake" =~ ^[0-9]+$ && "$handshake" -gt 0 ]]; then
            local now
            now=$(date +%s)
            local diff=$((now - handshake))
            if [[ $diff -lt 180 ]]; then
                status="Active"
            elif [[ $diff -lt 86400 ]]; then
                status="Recent"
            fi
            hs_str=$(date -d "@$handshake" '+%F %T' 2>/dev/null || echo "$handshake")
        fi

        total_rx=$((total_rx + rx))
        total_tx=$((total_tx + tx))

        if [[ "$JSON_OUTPUT" -eq 1 ]]; then
            json_entries+=("{\"name\":\"$(json_escape "$cname")\",\"ip\":\"$(json_escape "$ip")\",\"rx\":$rx,\"tx\":$tx,\"last_handshake\":$handshake,\"status\":\"$(json_escape "$status")\"}")
        else
            local rx_h tx_h
            rx_h=$(format_bytes "$rx")
            tx_h=$(format_bytes "$tx")
            table_rows+=("$(printf "%-15s | %-15s | %-12s | %-12s | %-19s | %s" "$cname" "$ip" "$rx_h" "$tx_h" "$hs_str" "$status")")
        fi
    done < <(echo "$awg_dump" | tail -n +2)

    if [[ "$JSON_OUTPUT" -eq 1 ]]; then
        ( IFS=","; echo "[${json_entries[*]}]" )
    else
        log "Client traffic statistics:"
        echo ""
        printf "%-15s | %-15s | %-12s | %-12s | %-19s | %s\n" "Name" "IP" "Received" "Sent" "Last handshake" "Status"
        printf -- "-%.0s" {1..95}
        echo
        for row in "${table_rows[@]}"; do
            echo "$row"
        done
        echo ""
        log "Total: Received $(format_bytes "$total_rx"), Sent $(format_bytes "$total_tx")"
    fi
}

# ==============================================================================
# Help
# ==============================================================================

usage() {
    exec >&2
    echo ""
    echo "AmneziaWG 2.0 management script (v${SCRIPT_VERSION})"
    echo "=============================================="
    echo "Usage: $0 [OPTIONS] <COMMAND> [ARGUMENTS]"
    echo ""
    echo "Options:"
    echo "  -h, --help            Show this help"
    echo "  -v, --verbose         Verbose output (for list command)"
    echo "  --no-color            Disable colored output"
    echo "  --json                JSON output (for stats command)"
    echo "  --expires=DURATION    Expiry time for add (1h, 12h, 1d, 7d, 30d, 4w)"
    echo "  --conf-dir=PATH       Specify AWG directory (default: $AWG_DIR)"
    echo "  --server-conf=PATH    Specify server config file"
    echo "  --apply-mode=MODE     syncconf (default) or restart (bypass kernel panic)"
    echo ""
    echo "Commands:"
    echo "  add <name> [name2 ...]       Add client(s). --expires applies to all"
    echo "  remove <name> [name2 ...]    Remove client(s)"
    echo "  list [-v]             List clients"
    echo "  stats [--json]        Client traffic statistics"
    echo "  regen [name]          Regenerate client file(s)"
    echo "  modify <name> <p> <v> Modify a client parameter"
    echo "  backup                Create a backup"
    echo "  restore [file]        Restore from backup"
    echo "  check | status        Check server status"
    echo "  show                  Show \`awg show\` status"
    echo "  restart               Restart AmneziaWG service"
    echo "  help                  Show this help"
    echo ""
    exit 1
}

# ==============================================================================
# Main logic
# ==============================================================================

if [[ "$COMMAND" == "help" || -z "$COMMAND" ]]; then
    usage
fi

check_dependencies || exit 1
cd "$AWG_DIR" || die "Failed to change to $AWG_DIR"

log "Running command '$COMMAND'..."
_cmd_rc=0

case $COMMAND in
    add)
        [[ ${#ARGS[@]} -eq 0 ]] && die "Client name not specified."

        _added=0
        for _cname in "${ARGS[@]}"; do
            validate_client_name "$_cname" || { _cmd_rc=1; continue; }

            if grep -qxF "#_Name = ${_cname}" "$SERVER_CONF_FILE"; then
                log_warn "Client '$_cname' already exists, skipping."
                continue
            fi

            log "Adding '$_cname'..."
            if generate_client "$_cname"; then
                log "Client '$_cname' added."
                log "Files: $AWG_DIR/${_cname}.conf, $AWG_DIR/${_cname}.png"
                if [[ -f "$AWG_DIR/${_cname}.vpnuri" ]]; then
                    log "vpn:// URI: $AWG_DIR/${_cname}.vpnuri"
                fi
                if [[ -n "$EXPIRES_DURATION" ]]; then
                    if set_client_expiry "$_cname" "$EXPIRES_DURATION"; then
                        install_expiry_cron
                    fi
                fi
                ((_added++))
            else
                log_error "Error adding client '$_cname'."
                _cmd_rc=1
            fi
        done

        if [[ $_added -gt 0 ]]; then
            [[ -n "${_CLI_APPLY_MODE:-}" ]] && export AWG_APPLY_MODE="$_CLI_APPLY_MODE"
            if [[ "${AWG_SKIP_APPLY:-0}" == "1" ]]; then
                apply_config
                log "Clients added: $_added. Apply deferred (AWG_SKIP_APPLY=1)."
            elif apply_config; then
                log "Clients added: $_added. Configuration applied."
            else
                log_error "Clients added: $_added, but apply_config failed. Config written but NOT applied to live interface. Check: systemctl status awg-quick@awg0"
                _cmd_rc=1
            fi
        fi
        ;;

    remove)
        [[ ${#ARGS[@]} -eq 0 ]] && die "Client name not specified."

        # Validate all names before removing
        _valid_names=()
        for _rname in "${ARGS[@]}"; do
            validate_client_name "$_rname" || { _cmd_rc=1; continue; }
            if ! grep -qxF "#_Name = ${_rname}" "$SERVER_CONF_FILE"; then
                log_warn "Client '$_rname' not found, skipping."
                continue
            fi
            _valid_names+=("$_rname")
        done

        if [[ ${#_valid_names[@]} -eq 0 ]]; then
            log_error "No clients to remove."
            _cmd_rc=1
        else
            # Confirmation
            if [[ ${#_valid_names[@]} -eq 1 ]]; then
                if ! confirm_action "remove" "client '${_valid_names[0]}'"; then exit 1; fi
            else
                if ! confirm_action "remove" "${#_valid_names[@]} clients"; then exit 1; fi
            fi

            _removed=0
            for _rname in "${_valid_names[@]}"; do
                log "Removing '$_rname'..."
                if remove_peer_from_server "$_rname"; then
                    rm -f "$AWG_DIR/$_rname.conf" "$AWG_DIR/$_rname.png" "$AWG_DIR/$_rname.vpnuri"
                    rm -f "$KEYS_DIR/${_rname}.private" "$KEYS_DIR/${_rname}.public"
                    remove_client_expiry "$_rname"
                    log "Client '$_rname' removed."
                    ((_removed++))
                else
                    log_error "Error removing '$_rname'."
                    _cmd_rc=1
                fi
            done

            if [[ $_removed -gt 0 ]]; then
                [[ -n "${_CLI_APPLY_MODE:-}" ]] && export AWG_APPLY_MODE="$_CLI_APPLY_MODE"
                if [[ "${AWG_SKIP_APPLY:-0}" == "1" ]]; then
                    apply_config
                    log "Clients removed: $_removed. Apply deferred (AWG_SKIP_APPLY=1)."
                elif apply_config; then
                    log "Clients removed: $_removed. Configuration applied."
                else
                    log_error "Clients removed: $_removed, but apply_config failed. Peers removed from config but may still be present on live interface. Check: systemctl status awg-quick@awg0"
                    _cmd_rc=1
                fi
            fi
        fi
        ;;

    list)
        list_clients || _cmd_rc=1
        ;;

    stats)
        stats_clients || _cmd_rc=1
        ;;

    regen)
        log "Regenerating config and QR files..."
        if [[ -n "$CLIENT_NAME" ]]; then
            # Regenerate single client
            validate_client_name "$CLIENT_NAME" || exit 1
            if ! grep -qxF "#_Name = ${CLIENT_NAME}" "$SERVER_CONF_FILE"; then
                die "Client '$CLIENT_NAME' not found."
            fi
            regenerate_client "$CLIENT_NAME" || { log_error "Regeneration error '$CLIENT_NAME'."; _cmd_rc=1; }
        else
            # Regenerate all clients
            all_clients=$(grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //')
            if [[ -z "$all_clients" ]]; then
                log "No clients found."
            else
                while IFS= read -r cname; do
                    cname="${cname## }"; cname="${cname%% }"
                    [[ -z "$cname" ]] && continue
                    log "Regenerating '$cname'..."
                    regenerate_client "$cname" || { log_warn "Regeneration error '$cname'"; _cmd_rc=1; }
                done <<< "$all_clients"
                log "Regeneration completed."
            fi
        fi
        ;;

    modify)
        [[ -z "$CLIENT_NAME" ]] && die "Client name not specified."
        validate_client_name "$CLIENT_NAME" || exit 1
        modify_client "$CLIENT_NAME" "$PARAM" "$VALUE" || _cmd_rc=1
        ;;

    backup)
        backup_configs || _cmd_rc=1
        ;;

    restore)
        restore_backup "$CLIENT_NAME" || _cmd_rc=1 # CLIENT_NAME is used as [file]
        ;;

    check|status)
        check_server || _cmd_rc=1
        ;;

    show)
        log "AmneziaWG 2.0 status..."
        if ! awg show; then log_error "awg show error."; _cmd_rc=1; fi
        ;;

    restart)
        log "Restarting service..."
        if ! confirm_action "restart" "service"; then exit 1; fi
        if ! systemctl restart awg-quick@awg0; then
            log_error "Restart error."
            status_out=$(systemctl status awg-quick@awg0 --no-pager 2>&1) || true
            while IFS= read -r line; do log_error "  $line"; done <<< "$status_out"
            exit 1
        else
            log "Service restarted."
        fi
        ;;

    help)
        usage
        ;;

    *)
        log_error "Unknown command: '$COMMAND'"
        _cmd_rc=1
        usage
        ;;
esac

log "Management script finished."
exit $_cmd_rc
