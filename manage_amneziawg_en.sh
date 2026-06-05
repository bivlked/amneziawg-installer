#!/bin/bash

# Minimum Bash version check
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "ERROR: Bash >= 4.0 required (current: ${BASH_VERSION})" >&2; exit 1
fi

# ==============================================================================
# AmneziaWG 2.0 peer management script
# Author: @bivlked
# Version: 5.15.4
# Date: 2026-06-06
# Repository: https://github.com/bivlked/amneziawg-installer
# ==============================================================================

# --- Safe mode and Constants ---
# shellcheck disable=SC2034
SCRIPT_VERSION="5.15.4"
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
CLI_CARRIER=""
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
HELP_EXIT_RC=0   # C1: 0 = explicit help (exit 0); set to 1 for usage errors
ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)         COMMAND="help"; HELP_EXIT_RC=0; break ;;
        -v|--verbose)      VERBOSE_LIST=1; shift ;;
        --no-color)        NO_COLOR=1; shift ;;
        --json)            JSON_OUTPUT=1; shift ;;
        --expires=*)       EXPIRES_DURATION="${1#*=}"; shift ;;
        --conf-dir=*)      AWG_DIR="${1#*=}"; shift ;;
        --server-conf=*)   SERVER_CONF_FILE="${1#*=}"; shift ;;
        --apply-mode=*)    _CLI_APPLY_MODE="${1#*=}"; export AWG_APPLY_MODE="$_CLI_APPLY_MODE"; shift ;;
        --psk)             CLI_ADD_PSK=1; shift ;;
        --yes)             CLI_YES=1; shift ;;
        --carrier=*)       CLI_CARRIER="${1#*=}"; shift ;;
        --*)               echo "Unknown option: $1" >&2; COMMAND="help"; HELP_EXIT_RC=1; break ;;
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

    # WARN and ERROR go to stderr (symmetry with install_amneziawg.sh:110+,
    # important for CI/automation parsing: stdout = "data", stderr = "diagnostics").
    if [[ "$type" == "ERROR" || "$type" == "WARN" ]]; then
        printf "${color_start}%s${color_end}\n" "$entry" >&2
    elif [[ "${JSON_OUTPUT:-0}" -eq 1 ]]; then
        # weaq P2: in --json mode stdout must contain ONLY JSON (jq/automation).
        # Route INFO/DEBUG to stderr, otherwise list/show/stats --json print INFO
        # lines before the JSON and break parsing (confirmed on biHetzner).
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
    # CLI flag --yes or ENV AWG_YES=1 skip the confirm prompt — useful for
    # scripts, cron, Ansible and interactive calls that pre-confirmed.
    if [[ "${CLI_YES:-0}" == "1" || "${AWG_YES:-0}" == "1" ]]; then
        return 0
    fi
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
#
# Error handling contract (v5.11.0 A1.1):
#   - Critical artifacts (awg0.conf, CONFIG_FILE, server_*.key, client
#     *.conf, $KEYS_DIR/*) — on cp failure, return 1 (no silent skip).
#     A corrupted backup is more dangerous than a missing one.
#   - Optional (QR *.png, *.vpnuri, expiry/, cron) — cp failure → log_warn,
#     continue. They can be regenerated from config.
#   - Missing globs (no clients yet) is distinguished from cp-failure via
#     compgen -G pre-check.
# On success, sets LAST_BACKUP_PATH (used by restore_backup for rollback
# snapshot).
_backup_configs_nolock() {
    # --no-prune: do not delete old backups after creating one. Used by the
    # pre-restore snapshot: otherwise, with 10 backups already present, prune
    # would drop the oldest one, which may be exactly the backup selected for
    # restore (it lives in the same $AWG_DIR/backups directory).
    local no_prune=0
    if [[ "${1:-}" == "--no-prune" ]]; then
        no_prune=1
        shift
    fi
    log "Creating backup..."
    local bd="$AWG_DIR/backups"
    mkdir -p "$bd" || die "mkdir error $bd"
    chmod 700 "$bd" 2>/dev/null
    local ts bf td
    # Millisecond precision in the timestamp prevents collisions on rapid-fire
    # backups (e.g. regen → backup → modify → backup within the same second).
    ts=$(date +%F_%H-%M-%S.%3N)
    bf="$bd/awg_backup_${ts}.tar.gz"
    td=$(manage_mktempdir) || die "Failed to create temp directory"

    mkdir -p "$td/server" "$td/clients" "$td/keys"

    # Server config (mandatory)
    if [[ -f "$SERVER_CONF_FILE" ]]; then
        if ! cp -a "$SERVER_CONF_FILE" "$td/server/"; then
            log_error "Failed to save $SERVER_CONF_FILE to backup."
            rm -rf "$td"
            return 1
        fi
    else
        log_warn "Server config missing ($SERVER_CONF_FILE) — will not be in backup."
    fi
    # Optional sidecar files next to awg0.conf (modify backups, etc.)
    if compgen -G "${SERVER_CONF_FILE}.*" > /dev/null; then
        cp -a "${SERVER_CONF_FILE}".* "$td/server/" 2>/dev/null || \
            log_warn "Failed to save ${SERVER_CONF_FILE}.* (non-critical)."
    fi

    # Client metadata (mandatory)
    if [[ -f "$CONFIG_FILE" ]]; then
        if ! cp -a "$CONFIG_FILE" "$td/clients/"; then
            log_error "Failed to save $CONFIG_FILE to backup."
            rm -rf "$td"
            return 1
        fi
    fi
    # Client *.conf (critical when present)
    if compgen -G "$AWG_DIR/*.conf" > /dev/null; then
        if ! cp -a "$AWG_DIR"/*.conf "$td/clients/"; then
            log_error "Failed to save client *.conf files to backup."
            rm -rf "$td"
            return 1
        fi
    fi
    # QR codes *.png (optional — regenerated from conf)
    if compgen -G "$AWG_DIR/*.png" > /dev/null; then
        cp -a "$AWG_DIR"/*.png "$td/clients/" 2>/dev/null || \
            log_warn "Failed to save client *.png (non-critical)."
    fi
    # vpn:// URIs (optional — regenerated)
    if compgen -G "$AWG_DIR/*.vpnuri" > /dev/null; then
        cp -a "$AWG_DIR"/*.vpnuri "$td/clients/" 2>/dev/null || \
            log_warn "Failed to save client *.vpnuri (non-critical)."
    fi

    # Client keys (critical when present)
    if compgen -G "$KEYS_DIR/*" > /dev/null; then
        if ! cp -a "$KEYS_DIR"/* "$td/keys/"; then
            log_error "Failed to save client keys ($KEYS_DIR) to backup."
            rm -rf "$td"
            return 1
        fi
    fi

    # Server keys (mandatory when present)
    if [[ -f "$AWG_DIR/server_private.key" ]]; then
        if ! cp -a "$AWG_DIR/server_private.key" "$td/"; then
            log_error "Failed to save server_private.key to backup."
            rm -rf "$td"
            return 1
        fi
    fi
    if [[ -f "$AWG_DIR/server_public.key" ]]; then
        if ! cp -a "$AWG_DIR/server_public.key" "$td/"; then
            log_error "Failed to save server_public.key to backup."
            rm -rf "$td"
            return 1
        fi
    fi

    # Expiry (critical — Unix epoch timestamps cannot be recovered from
    # other configs). Losing this data changes expiry-enforcement behavior
    # after restore.
    if [[ -d "${EXPIRY_DIR:-$AWG_DIR/expiry}" ]]; then
        if ! cp -a "${EXPIRY_DIR:-$AWG_DIR/expiry}" "$td/expiry"; then
            log_error "Failed to save expiry/ to backup."
            rm -rf "$td"
            return 1
        fi
    fi
    # Cron awg-expiry (critical — without it expiry-enforcement stops working).
    if [[ -f /etc/cron.d/awg-expiry ]]; then
        if ! cp -a /etc/cron.d/awg-expiry "$td/"; then
            log_error "Failed to save /etc/cron.d/awg-expiry to backup."
            rm -rf "$td"
            return 1
        fi
    fi

    tar -czf "$bf" -C "$td" . || { rm -rf "$td"; die "tar error $bf"; }
    log_debug "tar: archive created $bf"
    rm -rf "$td"
    chmod 600 "$bf" || log_warn "chmod error on backup"

    # Keep maximum 10 backups (unless --no-prune)
    if [[ "$no_prune" -eq 0 ]]; then
        find "$bd" -maxdepth 1 -name "awg_backup_*.tar.gz" -printf '%T@ %p\n' | \
            sort -nr | tail -n +11 | cut -d' ' -f2- | xargs -r rm -f || \
            log_warn "Error deleting old backups"
    fi

    LAST_BACKUP_PATH="$bf"
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

# Roll back to pre-restore snapshot (v5.11.0 A5.1).
# Called from restore_backup on any error after destructive ops start.
# Extracts the snapshot from $1 and copies files back to their original
# locations, then tries to start the service. Non-fatal if a particular
# cp fails: the goal is best-effort return to a working state so the
# user is not left without a VPN.
_restore_do_rollback() {
    local _snap="$1"
    if [[ -z "$_snap" || ! -f "$_snap" ]]; then
        log_error "Rollback snapshot unavailable ($_snap) — manual recovery required."
        return 1
    fi
    log_warn "Rolling back to pre-restore state ($(basename "$_snap"))..."
    local _rtd
    _rtd=$(manage_mktempdir) || {
        log_error "Failed to create rollback tmpdir. Manual: tar -xzf $_snap -C /"
        return 1
    }
    if ! tar -xzf "$_snap" --no-same-owner --no-same-permissions -C "$_rtd" 2>/dev/null; then
        rm -rf "$_rtd"
        log_error "Failed to unpack rollback snapshot ($_snap). Manual recovery: tar -xzf $_snap -C <target dir>"
        return 1
    fi
    local _scdir
    _scdir=$(dirname "$SERVER_CONF_FILE")
    [[ -d "$_rtd/server" ]] && cp -a "$_rtd/server/"* "$_scdir/" 2>/dev/null
    [[ -d "$_rtd/clients" ]] && cp -a "$_rtd/clients/"* "$AWG_DIR/" 2>/dev/null
    [[ -d "$_rtd/keys" ]] && cp -a "$_rtd/keys/"* "$KEYS_DIR/" 2>/dev/null
    [[ -f "$_rtd/server_private.key" ]] && cp -a "$_rtd/server_private.key" "$AWG_DIR/" 2>/dev/null
    [[ -f "$_rtd/server_public.key" ]] && cp -a "$_rtd/server_public.key" "$AWG_DIR/" 2>/dev/null
    [[ -d "$_rtd/expiry" ]] && { mkdir -p "${EXPIRY_DIR:-$AWG_DIR/expiry}"; cp -a "$_rtd/expiry"/* "${EXPIRY_DIR:-$AWG_DIR/expiry}/" 2>/dev/null; }
    [[ -f "$_rtd/awg-expiry" ]] && cp -a "$_rtd/awg-expiry" /etc/cron.d/awg-expiry 2>/dev/null
    rm -rf "$_rtd"

    log "Rollback done — attempting to start service..."
    if systemctl start awg-quick@awg0; then
        log "Service started after rollback."
        return 0
    else
        log_error "Service did not start after rollback — check: systemctl status awg-quick@awg0"
        return 1
    fi
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

    # v5.11.0 A5.1: rollback infrastructure.
    # _rollback_snap is populated after _backup_configs_nolock — until that
    # point no destructive ops run, so no rollback is needed.
    # _destructive_ops_started=1 is set before the first destructive op
    # (after systemctl stop). We roll back only when the system has
    # actually been modified — otherwise copying the same bytes back is
    # needless overhead.
    # _restore_ok=1 is set only on final success.
    local _rollback_snap=""
    local _restore_ok=0
    local _destructive_ops_started=0
    local td=""

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

    # Cleanup hook: fires on every return (via trap RETURN).
    # Rollback only when _restore_ok=0 AND _destructive_ops_started=1
    # AND _rollback_snap is captured. Always → remove temp dir and
    # release locks. First we clear the RETURN trap — bash's `trap ...
    # RETURN` has global lifetime, without this it would fire on any
    # subsequent return in this shell.
    _restore_cleanup() {
        # Order matters: capture $? (return code from restore_backup)
        # FIRST, then clear the RETURN trap. Swapping would break $?
        # capture because `trap - RETURN` is a builtin that clobbers
        # $? to 0. Reentrancy is impossible: `local` and `trap -` do
        # not invoke functions, and once `trap - RETURN` runs, our
        # trap is off.
        local _rc=$?
        trap - RETURN
        if [[ $_restore_ok -eq 0 && $_destructive_ops_started -eq 1 && -n "$_rollback_snap" ]]; then
            _restore_do_rollback "$_rollback_snap" || true
        fi
        [[ -n "$td" && -d "$td" ]] && rm -rf "$td"
        [[ -n "${config_lock_fd:-}" ]] && exec {config_lock_fd}>&- 2>/dev/null
        [[ -n "${backup_lock_fd:-}" ]] && exec {backup_lock_fd}>&- 2>/dev/null
        return $_rc
    }
    trap _restore_cleanup RETURN

    log "Backing up current config..."
    # --no-prune: the backup selected for restore ($bf) lives in the same
    # backups dir; pruning after the pre-restore snapshot could delete it.
    if ! _backup_configs_nolock --no-prune; then
        log_error "Failed to create backup of current configuration."
        return 1
    fi
    # Capture rollback snapshot (set by _backup_configs_nolock)
    _rollback_snap="${LAST_BACKUP_PATH:-}"

    td=$(manage_mktempdir) || {
        log_error "Failed to create temp directory"
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
        return 1
    }
    while IFS= read -r _vline; do
        [[ -z "$_vline" ]] && continue
        _tc="${_vline:0:1}"
        case "$_tc" in
            b|c|p|h|l)
                log_error "Archive contains dangerous entry type ('${_tc}'): '${_vline}' — restore aborted."
                return 1
                ;;
        esac
    done <<< "$_tar_verbose"

    # Path check: absolute paths and path traversal
    local _tar_list _bad_entry
    _tar_list=$(tar -tzf "$bf" 2>/dev/null) || {
        log_error "Cannot read archive contents: $bf"
        return 1
    }
    while IFS= read -r _bad_entry; do
        [[ -z "$_bad_entry" ]] && continue
        # Absolute paths
        if [[ "$_bad_entry" == /* ]]; then
            log_error "Archive contains absolute path: '$_bad_entry' — restore aborted."
            return 1
        fi
        # Parent directory traversal
        if [[ "$_bad_entry" == *..* ]]; then
            log_error "Archive contains path traversal (..): '$_bad_entry' — restore aborted."
            return 1
        fi
    done <<< "$_tar_list"
    log_debug "Pre-extraction check passed: $(echo "$_tar_list" | wc -l) files in archive."

    if ! tar -xzf "$bf" --no-same-owner --no-same-permissions -C "$td"; then
        log_error "tar error $bf"
        return 1
    fi

    # Post-extraction check: no symlinks in the unpacked tree
    local _symlinks
    _symlinks=$(find "$td" -type l 2>/dev/null)
    if [[ -n "$_symlinks" ]]; then
        log_error "Archive contains symlinks (possible symlink attack):"
        while IFS= read -r _sl; do log_error "  $_sl -> $(readlink "$_sl")"; done <<< "$_symlinks"
        return 1
    fi

    log "Stopping service..."
    systemctl stop awg-quick@awg0 || log_warn "Service not stopped."

    # From here on destructive ops. All error paths → trap _restore_cleanup → rollback.
    _destructive_ops_started=1
    if [[ -d "$td/server" ]]; then
        log "Restoring server config..."
        local server_conf_dir
        server_conf_dir=$(dirname "$SERVER_CONF_FILE")
        mkdir -p "$server_conf_dir"
        if ! cp -a "$td/server/"* "$server_conf_dir/"; then
            log_error "Error copying server — restore aborted (triggering rollback)."
            return 1
        fi
        chmod 600 "$server_conf_dir"/*.conf 2>/dev/null
        chmod 700 "$server_conf_dir"
        log_debug "Server config restored to $server_conf_dir"
    fi

    if [[ -d "$td/clients" ]]; then
        log "Restoring client files..."
        # C11: clean replacement, not a merge. Remove stale client artifacts that
        # are absent from the backup (otherwise a client deleted since the backup
        # lingers as orphan .conf/.png/.vpnuri). Scope strictly to managed client
        # globs - never touch scripts, server keys, backups/, logs, .lock,
        # awgsetup_cfg.init.
        rm -f "$AWG_DIR"/*.conf "$AWG_DIR"/*.png "$AWG_DIR"/*.vpnuri 2>/dev/null || true
        if ! cp -a "$td/clients/"* "$AWG_DIR/"; then
            log_error "Error copying clients — restore aborted (triggering rollback)."
            return 1
        fi
        chmod 600 "$AWG_DIR"/*.conf 2>/dev/null
        chmod 600 "$AWG_DIR"/*.png 2>/dev/null
        chmod 600 "$AWG_DIR"/*.vpnuri 2>/dev/null
        chmod 600 "$CONFIG_FILE" 2>/dev/null
        log_debug "Client files restored to $AWG_DIR"
    fi

    if [[ -d "$td/keys" ]]; then
        log "Restoring keys..."
        mkdir -p "$KEYS_DIR"
        # C11: remove stale client keys absent from the backup (server keys live
        # in AWG_DIR, not KEYS_DIR, so they are not affected).
        rm -f "$KEYS_DIR"/* 2>/dev/null || true
        # C2: the backup's keys/ may be empty (server with no client keys).
        # Without a compgen guard the bare glob "$td/keys/*" would stay literal,
        # cp would fail and the whole restore would roll back. Empty keys/ is OK.
        if ! compgen -G "$td/keys/*" > /dev/null; then
            log_debug "Backup has no client keys (keys/ empty) - skipping, not an error."
        elif ! cp -a "$td/keys/"* "$KEYS_DIR/"; then
            log_error "Error copying keys — restore aborted (triggering rollback)."
            return 1
        else
            chmod 600 "$KEYS_DIR"/* 2>/dev/null
            log_debug "Keys restored to $KEYS_DIR"
        fi
    fi

    # Server keys: cp -a preserves the mode from the archive, so we force 600
    # regardless of the mode they had inside the backup (audit fix).
    if [[ -f "$td/server_private.key" ]]; then
        if ! cp -a "$td/server_private.key" "$AWG_DIR/"; then
            log_error "Error copying server_private.key — restore aborted (triggering rollback)."
            return 1
        fi
        chmod 600 "$AWG_DIR/server_private.key" 2>/dev/null || true
    fi
    if [[ -f "$td/server_public.key" ]]; then
        if ! cp -a "$td/server_public.key" "$AWG_DIR/"; then
            log_error "Error copying server_public.key — restore aborted (triggering rollback)."
            return 1
        fi
        chmod 600 "$AWG_DIR/server_public.key" 2>/dev/null || true
    fi

    if [[ -d "$td/expiry" ]]; then
        log "Restoring expiry data..."
        mkdir -p "${EXPIRY_DIR:-$AWG_DIR/expiry}"
        # C11: expiry is intentionally NOT pruned. Orphan stamps for nonexistent
        # clients are harmless (cron cleanup ignores them), and a prune here would
        # be unsafe: both the rm and the following cp are best-effort (|| true), so
        # a copy failure after the prune would silently leave expiry empty. The
        # client artifacts themselves are pruned above.
        cp -a "$td/expiry/"* "${EXPIRY_DIR:-$AWG_DIR/expiry}/" 2>/dev/null || true
        chmod 600 "${EXPIRY_DIR:-$AWG_DIR/expiry}"/* 2>/dev/null
    fi
    if [[ -f "$td/awg-expiry" ]]; then
        cp -a "$td/awg-expiry" /etc/cron.d/awg-expiry
        chmod 644 /etc/cron.d/awg-expiry
    fi

    # Pre-flight: validate restored config BEFORE starting the service.
    # If the config is invalid awg-quick@awg0 will definitely fail — better
    # to roll back now and explain why than to start a broken service.
    if ! validate_awg_config >/dev/null 2>&1; then
        log_error "Restored server config failed validation — triggering rollback."
        return 1
    fi

    log "Starting service..."
    if ! systemctl start awg-quick@awg0; then
        log_error "Service start error — triggering rollback."
        local status_out
        status_out=$(systemctl status awg-quick@awg0 --no-pager 2>&1) || true
        while IFS= read -r line; do log_error "  $line"; done <<< "$status_out"
        return 1
    fi

    # Success — rollback not needed, trap only performs cleanup
    _restore_ok=1
    log "Restore completed."
    return 0
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
            # C5: beyond rejecting dangerous chars - positive host:port check.
            case "$value" in
                *$'\n'*|*$'\r'*|*\\*|*\"*|*\'*|*' '*|*$'\t'*|"")
                    log_error "Invalid Endpoint: '$value'"
                    return 1 ;;
            esac
            local _eh _ept
            if [[ "$value" == \[*\]:* ]]; then
                _eh="${value%]:*}"; _eh="${_eh#\[}"   # IPv6 without brackets
                _ept="${value##*]:}"
                _valid_ipv6 "$_eh" || { log_error "Invalid Endpoint '$value': malformed IPv6 host"; return 1; }
            else
                _eh="${value%:*}"; _ept="${value##*:}"
                _valid_host_or_ipv4 "$_eh" || { log_error "Invalid Endpoint '$value': expected host:port (FQDN / IPv4 / [IPv6])"; return 1; }
            fi
            { [[ "$_ept" =~ ^[0-9]+$ ]] && [[ "$_ept" -ge 1 && "$_ept" -le 65535 ]]; } || { log_error "Invalid Endpoint '$value': port must be 1-65535"; return 1; }
            ;;
        AllowedIPs)
            # C5: beyond rejecting dangerous chars - positive CIDR-list check.
            case "$value" in
                *$'\n'*|*$'\r'*|*\\*|*\"*|*\'*|"")
                    log_error "Invalid AllowedIPs: '$value'"
                    return 1 ;;
            esac
            # Stray commas: word-splitting on IFS=',' silently drops a TRAILING
            # empty element (e.g. "10.0.0.0/24,"), so check list structure
            # separately: leading/trailing/doubled comma.
            case "$value" in
                ,*|*,|*,,*)
                    log_error "Invalid AllowedIPs '$value': empty list element (stray comma)"
                    return 1 ;;
            esac
            local _aip_tok _aip_ifs="$IFS"
            IFS=','
            for _aip_tok in $value; do
                _aip_tok="${_aip_tok//[[:space:]]/}"
                if [[ -z "$_aip_tok" ]]; then
                    IFS="$_aip_ifs"
                    log_error "Invalid AllowedIPs '$value': empty list element (stray comma)"
                    return 1
                fi
                if ! _valid_cidr "$_aip_tok"; then
                    IFS="$_aip_ifs"
                    log_error "Invalid AllowedIPs '$value': '$_aip_tok' is not a CIDR (IPv4/IPv6 with optional /n prefix)"
                    return 1
                fi
            done
            IFS="$_aip_ifs"
            ;;
    esac

    # Lock before state checks (TOCTOU protection against concurrent remove)
    local modify_lockfile="${AWG_DIR}/.awg_config.lock"
    local modify_lock_fd
    exec {modify_lock_fd}>"$modify_lockfile"
    if ! flock -x -w 10 "$modify_lock_fd"; then
        log_error "Could not acquire config lock (another operation in progress)"
        exec {modify_lock_fd}>&-
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
    # v5.11.0 A5.2: backup is critical — without it a destructive sed can
    # corrupt the config with no way back. Abort if the backup cp fails.
    if ! cp "$cf" "$bak"; then
        log_error "Failed to create backup '$bak' — destructive sed aborted."
        exec {modify_lock_fd}>&-
        return 1
    fi
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
    if generate_vpn_uri "$name"; then
        generate_qr_vpnuri "$name" || log_warn "Failed to update vpn:// QR."
    else
        log_warn "Failed to update vpn:// URI."
    fi

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
# Diagnose: self-troubleshooting with optional carrier comparison
# ==============================================================================

# Known carriers and recommended AWG params.
# Format: jc_min jc_max jmin_lo jmin_hi jmax_offset_lo jmax_offset_hi i1_mode
#   i1_mode: random ("<r N>" form), absent (no I1), binary ("<r N><b 0xHEX>" form)
# Source: ADVANCED.en.md operator matrix (only confirmed ✅ rows).
# Megafon Moscow in the table is still 🔄 testing (Jc=3, Jmin=80, Jmax=268) -
# the range is wider than mobile preset; will add once the operator is
# confirmed and the range is fixed. T-Mobile MO US - Discussion #45 (o2me).
_diagnose_carrier_known() {
    case "$1" in
        beeline_msk)            echo "3 6 40 89 50 250 random" ;;
        yota_msk|tele2_msk|tattelecom) echo "3 3 30 50 20 80 random" ;;
        tele2_krasnoyarsk|megafon_regions) echo "3 3 30 50 20 80 absent" ;;
        tmobile_us)             echo "6 6 10 10 40 40 binary" ;;
        *)                       return 1 ;;
    esac
}

_diagnose_carrier_list() {
    echo "beeline_msk yota_msk tele2_msk tele2_krasnoyarsk tattelecom megafon_regions tmobile_us"
}

# Print one result line with color
_diag_line() {
    local status="$1" msg="$2"
    local color_start="" color_end=""
    if [[ "$NO_COLOR" -eq 0 ]]; then
        color_end="\033[0m"
        case "$status" in
            OK)   color_start="\033[0;32m" ;;
            WARN) color_start="\033[0;33m" ;;
            FAIL) color_start="\033[0;31m" ;;
            INFO) color_start="\033[0;36m" ;;
        esac
    fi
    printf "%b[%-4s]%b %s\n" "$color_start" "$status" "$color_end" "$msg"
}

# Main: runs health-checks + optional carrier comparison
diagnose_server() {
    local carrier="${CLI_CARRIER}"
    local ok=0 warn=0 fail=0

    log "AmneziaWG 2.0 server diagnostics..."
    if [[ -n "$carrier" ]] && ! _diagnose_carrier_known "$carrier" >/dev/null; then
        log_error "Unknown carrier: '$carrier'"
        log_error "Supported: $(_diagnose_carrier_list)"
        return 1
    fi

    # 1. Kernel module
    if lsmod 2>/dev/null | awk '$1 == "amneziawg" {f=1} END {exit !f}'; then
        _diag_line OK "Kernel module amneziawg loaded"; ok=$((ok+1))
    else
        _diag_line FAIL "Kernel module amneziawg NOT loaded"
        echo "        Fix: sudo bash $0 repair-module"
        fail=$((fail+1))
    fi

    # 2. Service active
    if systemctl is-active --quiet awg-quick@awg0 2>/dev/null; then
        _diag_line OK "Service awg-quick@awg0 is active"; ok=$((ok+1))
    else
        _diag_line FAIL "Service awg-quick@awg0 is INACTIVE"
        echo "        Fix: sudo systemctl start awg-quick@awg0"
        fail=$((fail+1))
    fi

    # 3. Interface awg0 UP
    if ip link show awg0 2>/dev/null | grep -qE "state (UP|UNKNOWN)"; then
        local awg_ip
        awg_ip=$(ip -4 -o addr show awg0 2>/dev/null | awk '{print $4; exit}')
        _diag_line OK "Interface awg0 UP (${awg_ip:-?})"; ok=$((ok+1))
    else
        _diag_line FAIL "Interface awg0 not UP (or missing)"
        fail=$((fail+1))
    fi

    # 4. sysctl ip_forward
    local fwd
    fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "?")
    if [[ "$fwd" == "1" ]]; then
        _diag_line OK "sysctl net.ipv4.ip_forward=1"; ok=$((ok+1))
    else
        _diag_line FAIL "sysctl net.ipv4.ip_forward=$fwd (1 required)"
        echo "        Fix: echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.d/99-awg.conf && sudo sysctl --system"
        fail=$((fail+1))
    fi

    # 5. BBR congestion control (recommended, not required)
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
    if [[ "$cc" == "bbr" ]]; then
        _diag_line OK "sysctl tcp_congestion_control=bbr"; ok=$((ok+1))
    else
        _diag_line WARN "sysctl tcp_congestion_control=$cc (bbr recommended)"
        warn=$((warn+1))
    fi

    # 6. UFW state + AWG port
    # shellcheck source=/dev/null
    safe_load_config "$CONFIG_FILE" 2>/dev/null
    local awg_port="${AWG_PORT:-39743}"
    if command -v ufw &>/dev/null; then
        local ufw_st
        ufw_st=$(ufw status 2>/dev/null | head -1)
        if [[ "$ufw_st" == "Status: active" ]]; then
            if ufw status 2>/dev/null | grep -qE "^${awg_port}/udp[[:space:]]+ALLOW"; then
                _diag_line OK "UFW active, ${awg_port}/udp ALLOW"; ok=$((ok+1))
            else
                _diag_line WARN "UFW active, but ${awg_port}/udp not explicitly ALLOW (traffic may not arrive)"
                warn=$((warn+1))
            fi
        else
            _diag_line WARN "UFW not active ($ufw_st)"; warn=$((warn+1))
        fi
    else
        _diag_line WARN "ufw is not installed"; warn=$((warn+1))
    fi

    # 7. Peer count
    local peer_count
    peer_count=$(awg show awg0 peers 2>/dev/null | wc -l)
    _diag_line INFO "Peers configured: $peer_count"

    # 8. AWG params snapshot
    local jc jmin jmax i1
    jc=$(awg show awg0 2>/dev/null   | awk '/^[[:space:]]*jc:/   {print $2; exit}')
    jmin=$(awg show awg0 2>/dev/null | awk '/^[[:space:]]*jmin:/ {print $2; exit}')
    jmax=$(awg show awg0 2>/dev/null | awk '/^[[:space:]]*jmax:/ {print $2; exit}')
    i1=$(awg show awg0 2>/dev/null   | awk -F': ' '/^[[:space:]]*i1:/ {print $2; exit}')
    _diag_line INFO "AWG params: Jc=${jc:-?} Jmin=${jmin:-?} Jmax=${jmax:-?} I1=${i1:-absent}"

    # 9. Carrier comparison
    if [[ -n "$carrier" ]]; then
        echo ""
        log "Comparing against carrier profile '$carrier'..."
        local row
        row=$(_diagnose_carrier_known "$carrier")
        local rc_jc_min rc_jc_max rc_jmin_lo rc_jmin_hi rc_jmax_off_lo rc_jmax_off_hi rc_i1
        read -r rc_jc_min rc_jc_max rc_jmin_lo rc_jmin_hi rc_jmax_off_lo rc_jmax_off_hi rc_i1 <<<"$row"

        # Jc range check
        if [[ -n "$jc" && "$jc" =~ ^[0-9]+$ && "$jc" -ge "$rc_jc_min" && "$jc" -le "$rc_jc_max" ]]; then
            _diag_line OK "Jc=$jc within [$rc_jc_min..$rc_jc_max] for $carrier"; ok=$((ok+1))
        else
            _diag_line WARN "Jc=${jc:-?} outside recommended [$rc_jc_min..$rc_jc_max] for $carrier"
            warn=$((warn+1))
        fi

        # Jmin range check
        if [[ -n "$jmin" && "$jmin" =~ ^[0-9]+$ && "$jmin" -ge "$rc_jmin_lo" && "$jmin" -le "$rc_jmin_hi" ]]; then
            _diag_line OK "Jmin=$jmin within [$rc_jmin_lo..$rc_jmin_hi] for $carrier"; ok=$((ok+1))
        else
            _diag_line WARN "Jmin=${jmin:-?} outside recommended [$rc_jmin_lo..$rc_jmin_hi] for $carrier"
            warn=$((warn+1))
        fi

        # Jmax offset check
        if [[ -n "$jmax" && -n "$jmin" && "$jmax" =~ ^[0-9]+$ && "$jmin" =~ ^[0-9]+$ ]]; then
            local jmax_off=$((jmax - jmin))
            if [[ "$jmax_off" -ge "$rc_jmax_off_lo" && "$jmax_off" -le "$rc_jmax_off_hi" ]]; then
                _diag_line OK "Jmax-Jmin=$jmax_off within [$rc_jmax_off_lo..$rc_jmax_off_hi]"; ok=$((ok+1))
            else
                _diag_line WARN "Jmax-Jmin=$jmax_off outside [$rc_jmax_off_lo..$rc_jmax_off_hi] (lower Jmax often more stable for $carrier)"
                warn=$((warn+1))
            fi
        else
            _diag_line WARN "Jmax-Jmin could not be computed (Jmax=${jmax:-?}, Jmin=${jmin:-?})"
            warn=$((warn+1))
        fi

        # I1 mode check
        case "$rc_i1" in
            absent)
                if [[ -z "$i1" || "$i1" == "absent" ]]; then
                    _diag_line OK "I1 absent (required for $carrier)"; ok=$((ok+1))
                else
                    _diag_line WARN "I1=$i1 but $carrier requires I1=absent"
                    echo "        Fix: edit /etc/amnezia/amneziawg/awg0.conf, remove 'I1 = ...' line, sudo systemctl restart awg-quick@awg0"
                    warn=$((warn+1))
                fi
                ;;
            random)
                if [[ -n "$i1" && "$i1" =~ ^\<r\ [0-9]+\>$ ]]; then
                    _diag_line OK "I1 random ($i1) - suitable for $carrier"; ok=$((ok+1))
                elif [[ -z "$i1" ]]; then
                    _diag_line WARN "I1 missing, $carrier usually works with random I1 (<r N>)"
                    warn=$((warn+1))
                else
                    _diag_line WARN "I1=$i1 unusual format (for $carrier <r N> is typical)"
                    warn=$((warn+1))
                fi
                ;;
            binary)
                if [[ -n "$i1" && "$i1" =~ ^\<r\ [0-9]+\>\<b\ 0x[0-9A-Fa-f]+\> ]]; then
                    _diag_line OK "I1 binary ($i1) - suitable for $carrier"; ok=$((ok+1))
                else
                    _diag_line WARN "I1=${i1:-absent}, $carrier (T-Mobile MO) requires binary I1 (<r N><b 0xHEX>)"
                    warn=$((warn+1))
                fi
                ;;
        esac
    fi

    # Summary
    echo ""
    log "Summary: OK=$ok WARN=$warn FAIL=$fail"
    if [[ "$fail" -gt 0 ]]; then
        return 1
    fi
    return 0
}

# ==============================================================================
# Client list
# ==============================================================================

list_clients() {
    log "Getting client list..."
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

    if [[ "$JSON_OUTPUT" -ne 1 ]]; then
        if [[ $verbose -eq 1 ]]; then
            printf "%-20s | %-7s | %-7s | %-36s | %-15s | %s\n" "Client name" "Conf" "QR" "IP address" "Key (start)" "Status"
            printf -- "-%.0s" {1..114}
            echo
        else
            printf "%-20s | %-7s | %-7s | %s\n" "Client name" "Conf" "QR" "Status"
            printf -- "-%.0s" {1..50}
            echo
        fi
    fi

    local now
    now=$(date +%s)

    local json_entries=()

    while IFS= read -r name; do
        name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"
        if [[ -z "$name" ]]; then continue; fi
        ((tot++))

        local cf="?" png="?" pk="-" ip="-" ip6="-" st="No data"
        local color_start="" color_end=""
        if [[ "$NO_COLOR" -eq 0 ]]; then
            color_end="\033[0m"
            color_start="\033[0;37m"
        fi

        [[ -f "$AWG_DIR/${name}.conf" ]] && cf="+"
        [[ -f "$AWG_DIR/${name}.png" ]] && png="+"

        if [[ "$cf" == "+" ]]; then
            # Extract IPv4 and optional IPv6 from Address line (dual-stack aware)
            local _addr_line
            _addr_line=$(awk '/^Address[ \t]*=/ { sub(/^Address[ \t]*=[ \t]*/, ""); print; exit }' "$AWG_DIR/${name}.conf" 2>/dev/null)
            if [[ -n "$_addr_line" ]]; then
                local _a1 _a2
                _a1="${_addr_line%%,*}"
                _a1="${_a1// /}"
                _a1="${_a1%%/*}"
                ip="${_a1:-?}"
                if [[ "$_addr_line" == *,* ]]; then
                    _a2="${_addr_line#*,}"
                    _a2="${_a2// /}"
                    _a2="${_a2%%/*}"
                    ip6="${_a2:-?}"
                else
                    ip6="-"
                fi
            else
                ip="?"
                ip6="-"
            fi

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

        if [[ "$JSON_OUTPUT" -eq 1 ]]; then
            local _ip6_val="${ip6}"
            [[ "$_ip6_val" == "-" ]] && _ip6_val=""
            json_entries+=("{\"name\":\"$(json_escape "$name")\",\"ip\":\"$(json_escape "$ip")\",\"client_ipv6\":\"$(json_escape "$_ip6_val")\",\"status\":\"$(json_escape "$st")\"}")
        elif [[ $verbose -eq 1 ]]; then
            local ip_display
            if [[ "$ip6" != "-" ]]; then
                ip_display="${ip} / ${ip6}"
            else
                ip_display="${ip} / -"
            fi
            printf "%-20s | %-7s | %-7s | %-36s | %-15s | ${color_start}%s${color_end}%s\n" "$name" "$cf" "$png" "$ip_display" "$pk" "$st" "$exp_str"
        else
            printf "%-20s | %-7s | %-7s | ${color_start}%s${color_end}%s\n" "$name" "$cf" "$png" "$st" "$exp_str"
        fi
    done <<< "$clients"

    if [[ "$JSON_OUTPUT" -eq 1 ]]; then
        ( IFS=","; echo "[${json_entries[*]}]" )
    else
        echo ""
        log "Total clients: $tot, Active/Recent: $act"
    fi
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
    # C1: explicit help (rc=0) -> stdout + exit 0; usage error (rc!=0, default)
    # -> stderr + exit 1. Explicit-help callers pass 0, error callers omit the
    # argument (get 1).
    local _rc="${1:-1}"
    [[ "$_rc" -ne 0 ]] && exec >&2
    echo ""
    echo "AmneziaWG 2.0 management script (v${SCRIPT_VERSION})"
    echo "=============================================="
    echo "Usage: $0 [OPTIONS] <COMMAND> [ARGUMENTS]"
    echo ""
    echo "Options:"
    echo "  -h, --help            Show this help"
    echo "  -v, --verbose         Verbose output (for list command)"
    echo "  --no-color            Disable colored output"
    echo "  --json                Machine-readable JSON output (for list / stats)"
    echo "  --expires=DURATION    Expiry time for add (1h, 12h, 1d, 7d, 30d, 4w)"
    echo "  --conf-dir=PATH       Specify AWG directory (default: $AWG_DIR)"
    echo "  --server-conf=PATH    Specify server config file"
    echo "  --apply-mode=MODE     syncconf (default) or restart (bypass kernel panic)"
    echo "  --psk                 (add only) generate a PresharedKey for the new client"
    echo "  --yes                 Skip confirm prompts (equivalent to ENV AWG_YES=1)"
    echo "  --carrier=NAME        (diagnose only) compare AWG params against carrier profile"
    echo "                        Available: beeline_msk yota_msk tele2_msk tele2_krasnoyarsk"
    echo "                                   tattelecom megafon_regions tmobile_us"
    echo "                        Exit code: 1 only on FAIL or unknown carrier (WARN -> 0)"
    echo ""
    echo "Commands:"
    echo "  add <name> [name2 ...]       Add client(s). --expires applies to all"
    echo "  remove <name> [name2 ...]    Remove client(s)"
    echo "  list [-v] [--json]    List clients (--json: machine-readable, includes client_ipv6)"
    echo "  stats [--json]        Client traffic statistics"
    echo "  regen [name]          Regenerate client file(s)"
    echo "  modify <name> <p> <v> Modify a client parameter"
    echo "  backup                Create a backup"
    echo "  restore [file]        Restore from backup"
    echo "  check | status        Check server status"
    echo "  diagnose [--carrier=N] Self-troubleshooting: kernel/sysctl/UFW + carrier comparison"
    echo "  show                  Show \`awg show\` status"
    echo "  restart               Restart AmneziaWG service"
    echo "  repair-module         Repair the kernel module after a kernel upgrade"
    echo "                        (dkms autoinstall + modprobe + start awg-quick)"
    echo "  help                  Show this help"
    echo ""
    exit "$_rc"
}

# ==============================================================================
# Main logic
# ==============================================================================

if [[ -z "$COMMAND" ]]; then
    usage 1
fi
if [[ "$COMMAND" == "help" ]]; then
    usage "$HELP_EXIT_RC"
fi

check_dependencies || exit 1
cd "$AWG_DIR" || die "Failed to change to $AWG_DIR"

log "Running command '$COMMAND'..."
_cmd_rc=0

case $COMMAND in
    add)
        [[ ${#ARGS[@]} -eq 0 ]] && die "Client name not specified."

        # Make sure the amneziawg kernel module is loaded and awg-quick@awg0 is up.
        # Without it apply_config (awg syncconf) fails. See also 'manage repair-module'.
        # AWG_SKIP_APPLY=1 (offline/batch edit without apply): skip the module check —
        # apply_config will no-op anyway, and the command must work on a dev machine.
        if [[ "${AWG_SKIP_APPLY:-0}" != "1" ]]; then
            ensure_amneziawg_kernel_module \
                || die "amneziawg kernel module unavailable. Run 'manage repair-module' and try again."
        fi

        # --psk: enable optional PresharedKey for every new client.
        # Export CLIENT_PSK="auto" -> generate_client produces a fresh
        # 32-byte PSK via `awg genpsk` for each client in the batch
        # (distinct PSK per client).
        if [[ "${CLI_ADD_PSK:-0}" == "1" ]]; then
            export CLIENT_PSK="auto"
            log "PresharedKey will be generated for each new client (--psk)."
        fi

        _added=0
        for _cname in "${ARGS[@]}"; do
            validate_client_name "$_cname" || { _cmd_rc=1; continue; }

            if grep -qxF "#_Name = ${_cname}" "$SERVER_CONF_FILE"; then
                log_warn "Client '$_cname' already exists, skipping."
                continue
            fi

            # In batch mode each client gets its own PSK: reset to "auto"
            # so generate_client generates a new one every iteration.
            if [[ "${CLI_ADD_PSK:-0}" == "1" ]]; then
                export CLIENT_PSK="auto"
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
        # Hygiene: do not let CLIENT_PSK leak into later operations
        unset CLIENT_PSK
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

            # Ensure module is loaded before any mutations (apply_config / awg syncconf).
            # AWG_SKIP_APPLY=1 (offline/batch edit without apply): skip the module check —
            # apply_config will no-op anyway, and the command must work on a dev machine.
            if [[ "${AWG_SKIP_APPLY:-0}" != "1" ]]; then
                ensure_amneziawg_kernel_module \
                    || die "amneziawg kernel module unavailable. Run 'manage repair-module' and try again."
            fi

            _removed=0
            for _rname in "${_valid_names[@]}"; do
                log "Removing '$_rname'..."
                if remove_peer_from_server "$_rname"; then
                    rm -f "$AWG_DIR/$_rname.conf" "$AWG_DIR/$_rname.png" \
                        "$AWG_DIR/$_rname.vpnuri" "$AWG_DIR/$_rname.vpnuri.png"
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
        if [[ ${#ARGS[@]} -eq 0 ]]; then
            # No arguments — regenerate all clients (preserves prior behaviour).
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
        else
            # With arguments — process each name individually (parity with add/remove).
            # Until v5.11.5 only $CLIENT_NAME (=ARGS[0]) was read here, the rest were
            # silently dropped (Issue #70).
            _regen_count=0
            for _cname in "${ARGS[@]}"; do
                validate_client_name "$_cname" || { _cmd_rc=1; continue; }
                if ! grep -qxF "#_Name = ${_cname}" "$SERVER_CONF_FILE"; then
                    log_warn "Client '$_cname' not found, skipping."
                    _cmd_rc=1
                    continue
                fi
                log "Regenerating '$_cname'..."
                if regenerate_client "$_cname"; then
                    _regen_count=$((_regen_count + 1))
                else
                    log_error "Regeneration error '$_cname'."
                    _cmd_rc=1
                fi
            done
            if [[ $_regen_count -gt 0 ]]; then
                log "Regeneration completed. Processed: $_regen_count of ${#ARGS[@]}."
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
        # Verify kernel module is loaded before systemctl restart (mode=module-only —
        # the restart below starts the unit explicitly, so an extra start from ensure
        # would be redundant).
        ensure_amneziawg_kernel_module module-only \
            || die "amneziawg kernel module unavailable. Run 'manage repair-module' and try again."
        if ! systemctl restart awg-quick@awg0; then
            log_error "Restart error."
            status_out=$(systemctl status awg-quick@awg0 --no-pager 2>&1) || true
            while IFS= read -r line; do log_error "  $line"; done <<< "$status_out"
            exit 1
        else
            log "Service restarted."
        fi
        ;;

    repair-module|repair)
        # Explicit user-facing command: after a kernel upgrade the module may
        # need a DKMS rebuild. Allow apt-installing kernel headers here
        # (AWG_ALLOW_APT_IN_ENSURE=1) — the user explicitly requested repair.
        log "Repairing amneziawg kernel module (may take up to 5 minutes — DKMS rebuild)..."
        if AWG_ALLOW_APT_IN_ENSURE=1 ensure_amneziawg_kernel_module full; then
            log "amneziawg kernel module repaired, awg-quick@awg0 service is active."
        else
            log_error "Could not repair the kernel module. See log above; manual recovery may be required."
            _cmd_rc=1
        fi
        ;;

    diagnose)
        diagnose_server || _cmd_rc=1
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
