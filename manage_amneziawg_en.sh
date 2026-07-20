#!/bin/bash

# Minimum Bash version check
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "ERROR: Bash >= 4.0 required (current: ${BASH_VERSION})" >&2; exit 1
fi

# ==============================================================================
# AmneziaWG 2.0 peer management script
# Author: @bivlked
# Version: 5.21.0
# Date: 2026-07-20
# Repository: https://github.com/bivlked/amneziawg-installer
# ==============================================================================

# --- Safe mode and Constants ---
# shellcheck disable=SC2034
SCRIPT_VERSION="5.21.0"
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

_manage_cleaned=0
_manage_cleanup() {
    # Idempotent: on INT/TERM it is called from the signal handler, then again on
    # EXIT - the repeat must be a no-op.
    [[ "$_manage_cleaned" -eq 1 ]] && return 0
    _manage_cleaned=1
    local d
    for d in "${_manage_temp_dirs[@]}"; do
        [[ -d "$d" ]] && rm -rf "$d"
    done
    type _awg_cleanup &>/dev/null && _awg_cleanup
}
# On INT/TERM the cleanup used to run but the script did NOT exit - execution
# continued past the interrupted command and cleanup ran again on EXIT. A signal
# now means cleanup + explicit 130/143. restore_backup installs its OWN INT/TERM
# handler (with rollback) for its destructive phase and clears it in _restore_cleanup.
_manage_on_signal() {
    _manage_cleanup
    exit "$1"
}

# ==============================================================================
# JSON helpers (v5.21.0)
# ==============================================================================
# Defined BEFORE the EXIT trap is installed: _manage_on_exit calls
# _json_exit_guard, which calls json_escape. An early exit (option error)
# without these definitions would print "command not found" instead of the
# emergency JSON.

# Byte-wise replacement of invalid UTF-8 with U+FFFD. A replacement, not
# iconv -c: silently dropping bytes makes an error text meaningless exactly
# when it matters most. iconv prints the valid prefix up to the first bad
# byte: take the prefix, replace the byte, re-run the tail.
# Called only after validation already failed - zero cost on valid input.
_json_utf8_sanitize() {
    local s="$1" out="" prefix
    local LC_ALL=C   # ${#} and ${:offset} must count BYTES, not characters
    while [[ -n "$s" ]]; do
        if printf '%s' "$s" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
            out+="$s"
            break
        fi
        # Sentinel X preserves the prefix's trailing newlines ($() strips them).
        prefix=$(printf '%s' "$s" | iconv -f UTF-8 -t UTF-8 2>/dev/null; printf X)
        prefix="${prefix%X}"
        out+="${prefix}"$'\xEF\xBF\xBD'
        s="${s:$(( ${#prefix} + 1 ))}"
    done
    printf '%s' "$out"
}

# Escape a string for safe JSON inclusion. Beyond the basic \ " \n \r \t
# this escapes ALL C0 controls (0x01-0x1F) as \u00XX - jq rejects raw ESC/BEL
# (same class as the ESC-in-vpn:// bug in v5.20.0), and the emergency path
# feeds arbitrary error text and --conf-dir paths in here. Invalid UTF-8 ->
# U+FFFD. NUL is not handled: a bash variable cannot carry it.
json_escape() {
    local s="$1"
    # Fork-free fast-path via printf %q: clean strings (names, IPs, our
    # status literals) come back from %q unchanged - no iconv spawn needed
    # (matters for list/stats: hundreds of calls per run). Broken bytes and
    # C0 are ALWAYS quoted by %q ($'...') -> they take the iconv path.
    # A false positive (spaces/parens) costs one cheap validation.
    # NOT usable as a detector on its own: comparing char length == byte
    # length misses broken UTF-8 (each bad byte counts as a "character").
    local _q
    printf -v _q '%q' "$s"
    if [[ "$_q" != "$s" ]] && command -v iconv >/dev/null 2>&1; then
        if ! printf '%s' "$s" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
            s=$(_json_utf8_sanitize "$s"; printf X)
            s="${s%X}"
        fi
    fi
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    # Rare path: remaining C0 (after the replacements above, \n\r\t are gone).
    if [[ "$s" =~ [[:cntrl:]] ]]; then
        local _i _ch _u
        for _i in 1 2 3 4 5 6 7 8 11 12 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31; do
            printf -v _ch "\\$(printf '%03o' "$_i")"
            [[ "$s" == *"$_ch"* ]] || continue
            printf -v _u '\\u%04x' "$_i"
            s="${s//$_ch/$_u}"
        done
    fi
    printf '%s' "$s"
}

# The single point that prints JSON to stdout. Contract rule: with --json,
# stdout carries EXACTLY ONE JSON document, including any failure.
_JSON_EMITTED=0
_JSON_ERR=""
json_out() {
    [[ "${JSON_OUTPUT:-0}" -eq 1 ]] || return 0
    [[ "$_JSON_EMITTED" -eq 1 ]] && return 0    # double-emission protection
    _JSON_EMITTED=1
    printf '%s\n' "$1"
}

# Emergency emission on EXIT: any exit path with rc!=0 that has not printed
# its envelope (die, bare exit, strict-confirm refusal, signal, usage error)
# leaves the bot {"command","ok":false,"error","rc"} instead of empty stdout.
# rc arrives as an ARGUMENT: the guard is called from _manage_on_exit, and
# reading $? here would be too late. The error field is human-readable text
# (may be localized); bots must decide by ok/rc/status.
_json_exit_guard() {
    local rc="$1"
    [[ "${JSON_OUTPUT:-0}" -eq 1 && "$_JSON_EMITTED" -eq 0 && "$rc" -ne 0 ]] || return 0
    # show/diagnose are outside the JSON contract (--json documented as
    # unsupported): their human output already went to stdout, an emergency
    # object on top would produce a mixed stream instead of "exactly one".
    case "${COMMAND:-}" in show|diagnose) return 0 ;; esac
    json_out "{\"command\":\"$(json_escape "${COMMAND:-}")\",\"ok\":false,\"error\":\"$(json_escape "${_JSON_ERR:-command failed}")\",\"rc\":$rc}"
}

# The ONLY EXIT handler. The guard lives here, NOT inside the idempotent
# _manage_cleanup: the signal path calls cleanup directly (at that moment $?
# is not yet 130/143 - the guard would report a wrong rc), and the repeated
# cleanup call on EXIT hits _manage_cleaned=1 (a guard placed after that
# check would never run). Here rc is honest on all paths, including the
# exit 130/143 from the signal hooks.
_manage_on_exit() {
    local rc=$?
    _json_exit_guard "$rc"
    _manage_cleanup
}
trap _manage_on_exit EXIT
trap '_manage_on_signal 130' INT
trap '_manage_on_signal 143' TERM

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
        --apply-mode=*)
            # Stash only; validation happens AFTER the loop (see below):
            # inside the loop --json may not be parsed yet ('add x
            # --apply-mode=bad --json') and the emergency JSON guard
            # would stay silent on an error here.
            _CLI_APPLY_MODE="${1#*=}"
            shift ;;
        --psk)             CLI_ADD_PSK=1; shift ;;
        --reset-routes)    CLI_RESET_ROUTES=1; shift ;;
        --yes)             CLI_YES=1; shift ;;
        --carrier=*)       CLI_CARRIER="${1#*=}"; shift ;;
        --*)               echo "Unknown option: $1" >&2; for _rest in "$@"; do [[ "$_rest" == "--json" ]] && JSON_OUTPUT=1; done; COMMAND="help"; HELP_EXIT_RC=1; break ;;
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

# Alias canonicalization (contract 3.2): a bot must not have to parse how the
# command was typed. The dispatcher below matches both spellings, so this is
# safe for the human path too.
case "$COMMAND" in
    status) COMMAND="check" ;;
    repair) COMMAND="repair-module" ;;
esac

# Validate --apply-mode after ALL options are parsed (--json is known now).
# A typo (--apply-mode=restrat) would silently act as syncconf - a user
# working around an issue with restart mode would never learn the mode
# did not apply.
if [[ -n "${_CLI_APPLY_MODE:-}" ]]; then
    case "$_CLI_APPLY_MODE" in
        syncconf|restart) export AWG_APPLY_MODE="$_CLI_APPLY_MODE" ;;
        *)
            _JSON_ERR="Invalid --apply-mode value: '$_CLI_APPLY_MODE' (expected: syncconf or restart)"
            echo "$_JSON_ERR" >&2
            exit 1 ;;
    esac
fi

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
# die mirrors the message into _JSON_ERR so the guard's emergency JSON
# carries meaningful text instead of the default "command failed".
die()       { _JSON_ERR="$1"; log_error "$1"; exit 1; }

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
    if ! is_interactive; then
        # AWG_STRICT_CONFIRM=1 (opt-in, v5.21.0): a non-interactive run without
        # an explicit --yes/AWG_YES=1 is refused instead of silently approved -
        # protects destructive commands in pipelines where nobody watches the
        # screen. Default 0 keeps prior behavior; strictly the string "1".
        # The ENV applies per run and is NOT persisted to awgsetup_cfg.init.
        if [[ "${AWG_STRICT_CONFIRM:-0}" == "1" ]]; then
            _JSON_ERR="AWG_STRICT_CONFIRM=1: non-interactive run requires --yes"
            log_error "AWG_STRICT_CONFIRM=1: non-interactive run requires --yes (or AWG_YES=1). Action cancelled."
            return 1
        fi
        return 0
    fi
    local action="$1" subject="$2"
    read -rp "Are you sure you want to $action $subject? [y/N]: " confirm < /dev/tty
    # Accept y/yes (case-insensitive) plus stray whitespace/CR around it.
    if [[ "$confirm" =~ ^[[:space:]]*[Yy]([Ee][Ss])?[[:space:]]*$ ]]; then
        return 0
    else
        _JSON_ERR="confirmation denied"
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

# JSON entry for a successful regen (v5.21.0). qr/vpnuri are paths if the
# file exists at response time (regenerate_client refreshes them best-effort;
# the contract makes no freshness promise - see the races note in the docs).
_regen_json_entry() {
    local name="$1" _jqr="null" _juri="null"
    [[ -f "$AWG_DIR/${name}.png" ]] && _jqr="\"$(json_escape "$AWG_DIR/${name}.png")\""
    [[ -f "$AWG_DIR/${name}.vpnuri" ]] && _juri="\"$(json_escape "$AWG_DIR/${name}.vpnuri")\""
    printf '%s' "{\"name\":\"$(json_escape "$name")\",\"status\":\"regenerated\",\"conf\":\"$(json_escape "$AWG_DIR/${name}.conf")\",\"qr\":$_jqr,\"vpnuri\":$_juri}"
}

# ==============================================================================
# Dependency check
# ==============================================================================

# Compatibility check between awg_common.sh and this script. The files are
# updated as a pair; if only one is refreshed, the mismatch otherwise surfaces
# as a "command not found" somewhere random (issue #183). We compare MAJOR.MINOR:
# a patch difference is fine (no breaking library changes within a minor), but a
# different minor or a library with no version (older than this check) = stop.
_check_common_compat() {
    local have="${AWG_COMMON_VERSION:-}"
    local want="$SCRIPT_VERSION"
    # Compare MAJOR and MINOR separately as NUMBERS, not via ${v%.*} (which would
    # collapse "5.20" and "5.9" into "5"). An X.Y.* shape with numeric X.Y is
    # required: an empty/two-component/non-numeric library version fails the
    # match and leads to die. Anything after MINOR (patch, -rc1) is ignored.
    local re='^([0-9]+)\.([0-9]+)\.'
    if [[ "$have" =~ $re ]]; then
        local have_mj="${BASH_REMATCH[1]}" have_mn="${BASH_REMATCH[2]}"
        if [[ "$want" =~ $re ]]; then
            [[ "$have_mj" == "${BASH_REMATCH[1]}" && "$have_mn" == "${BASH_REMATCH[2]}" ]] && return 0
        fi
    fi
    die "awg_common.sh (${have:-no version}) is incompatible with manage_amneziawg.sh ($want). Update both halves to the same version:
  wget -O $AWG_DIR/manage_amneziawg.sh https://raw.githubusercontent.com/bivlked/amneziawg-installer/v$want/manage_amneziawg_en.sh
  wget -O $COMMON_SCRIPT_PATH https://raw.githubusercontent.com/bivlked/amneziawg-installer/v$want/awg_common_en.sh
  chmod 700 $AWG_DIR/manage_amneziawg.sh $COMMON_SCRIPT_PATH"
}

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

    # Load common library.
    # Reset before sourcing so the version comes ONLY from the library, not from
    # an inherited environment (otherwise an old library with no variable could
    # falsely pass the compatibility check).
    unset AWG_COMMON_VERSION
    # shellcheck source=/dev/null
    source "$COMMON_SCRIPT_PATH" || die "Failed to load $COMMON_SCRIPT_PATH"
    _check_common_compat

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
    # Additionally take the config lock: a concurrent `manage add/remove`
    # could modify awg0.conf/keys BETWEEN copying server/ and clients/ into
    # tmpdir - each file in the backup is intact (atomic mv) but the set is
    # desynchronized (peer mismatch on restore). restore_backup holds both
    # locks - backup must do the same. IMPORTANT: in restore
    # _backup_configs_nolock is called under an already-held config lock -
    # here the lock is taken only for the direct backup command (flock is
    # non-reentrant, see the contract in awg_common.sh).
    local config_lockfile="${AWG_DIR}/.awg_config.lock"
    local config_lock_fd
    exec {config_lock_fd}>"$config_lockfile"
    if ! flock -x -w 30 "$config_lock_fd"; then
        log_error "Config lock timeout (30 sec)."
        exec {config_lock_fd}>&-
        exec {backup_lock_fd}>&-
        return 1
    fi
    _backup_configs_nolock
    local _rc=$?
    exec {config_lock_fd}>&-
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
    # Rollback files are in place - the JSON envelope reports rolled_back=true
    # even if the service below fails to start (FS state is already pre-restore).
    _RESTORE_ROLLED_BACK=1

    log "Rollback done — attempting to start service..."
    if systemctl start awg-quick@awg0; then
        log "Service started after rollback."
        return 0
    else
        log_error "Service did not start after rollback — check: systemctl status awg-quick@awg0"
        return 1
    fi
}

# Returns 0 when the path contains '..' as a COMPLETE component (parent
# traversal): exactly "..", a "../" prefix, "/../" in the middle or a trailing
# "/..". A ".." substring inside a name (my..backup.conf, v1..2) is legitimate -
# the old substring check falsely rejected such files when restoring
# foreign/modified archives.
_path_has_parent_component() {
    local p="$1"
    [[ "$p" == ".." || "$p" == "../"* || "$p" == *"/../"* || "$p" == *"/.." ]]
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
    _RESTORE_SOURCE="$bf"   # for the restore JSON envelope (v5.21.0)
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
        # Clear RETURN and RESTORE the global INT/TERM (restore's local hooks are
        # set below). A plain `trap -` would reset them to default and the manager
        # would lose its B1 signal -> cleanup+exit behavior after a restore.
        trap - RETURN
        trap '_manage_on_signal 130' INT
        trap '_manage_on_signal 143' TERM
        if [[ $_restore_ok -eq 0 && $_destructive_ops_started -eq 1 && -n "$_rollback_snap" ]]; then
            _restore_do_rollback "$_rollback_snap" || true
        fi
        [[ -n "$td" && -d "$td" ]] && rm -rf "$td"
        [[ -n "${config_lock_fd:-}" ]] && exec {config_lock_fd}>&- 2>/dev/null
        [[ -n "${backup_lock_fd:-}" ]] && exec {backup_lock_fd}>&- 2>/dev/null
        return $_rc
    }
    trap _restore_cleanup RETURN
    # INT/TERM during restore: same rollback+cleanup as a normal return
    # (_restore_cleanup sees the local _restore_ok/_rollback_snap/td), then exit
    # with the signal code. Overrides the global _manage_on_signal so interrupting
    # the destructive phase does not leave the system without a rollback.
    # _restore_cleanup clears these hooks itself (trap - INT TERM above).
    trap '_restore_cleanup; exit 130' INT
    trap '_restore_cleanup; exit 143' TERM

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

    # Type check via verbose listing: reject block/char/FIFO/symlink ('l')
    # and hardlink ('h') entries - both link classes are unsafe to extract.
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
        # Parent directory traversal ('..' as a complete path component only)
        if _path_has_parent_component "$_bad_entry"; then
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

    # Check backup completeness BEFORE stopping the service. A backup without a
    # server config is useless (a VPN cannot come up without it), and an empty
    # server/ used to crash `cp "$td/server/"*` AFTER the stop, forcing a rollback
    # of a working system. Checking before the destructive phase leaves the
    # service untouched and needs no rollback.
    local _srv_base
    _srv_base=$(basename "$SERVER_CONF_FILE")
    if [[ ! -f "$td/server/$_srv_base" ]]; then
        log_error "Incomplete backup: missing server config ($_srv_base) - restore aborted."
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
        # An empty clients/ is a valid case (a server with no client configs):
        # the prune above already gives a clean replacement, so we just skip the
        # copy (without compgen the bare glob "$td/clients/"* would stay literal
        # and crash cp -> rollback).
        if compgen -G "$td/clients/*" > /dev/null; then
            if ! cp -a "$td/clients/"* "$AWG_DIR/"; then
                log_error "Error copying clients — restore aborted (triggering rollback)."
                return 1
            fi
            chmod 600 "$AWG_DIR"/*.conf 2>/dev/null
            chmod 600 "$AWG_DIR"/*.png 2>/dev/null
            chmod 600 "$AWG_DIR"/*.vpnuri 2>/dev/null
            chmod 600 "$CONFIG_FILE" 2>/dev/null
            log_debug "Client files restored to $AWG_DIR"
        else
            log_debug "Backup has no client files (clients/ empty) - skipping copy."
        fi
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
        # clients are harmless: check_expired_clients detects on expiry that the
        # peer is absent from the config and cleans the stamp with the artifacts
        # itself. A prune here would be unsafe: both the rm and the following cp
        # are best-effort (|| true), so a copy failure after the prune would
        # silently leave expiry empty. The client artifacts themselves are
        # pruned above.
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
            # Structural validation of the DNS list. The old charset-only regex
            # ^[0-9a-fA-F.:,\ ]+$ let garbage through ('abc' - a-f letters;
            # '999.999.999.999' - out of range). DNS is IP-only by contract (no
            # FQDN), so each element must be a bare IPv4 or IPv6, like Endpoint/AllowedIPs.
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
            local _dns_tok _dns_ifs="$IFS"
            IFS=','
            for _dns_tok in $value; do
                _dns_tok="${_dns_tok//[[:space:]]/}"
                if [[ -z "$_dns_tok" ]]; then
                    IFS="$_dns_ifs"
                    log_error "Invalid DNS '$value': empty list element (stray comma)"
                    return 1
                fi
                if ! _valid_ipv4 "$_dns_tok" && ! _valid_ipv6 "$_dns_tok"; then
                    IFS="$_dns_ifs"
                    log_error "Invalid DNS '$value': '$_dns_tok' is not a valid IPv4/IPv6 address"
                    return 1
                fi
            done
            IFS="$_dns_ifs"
            ;;
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
        # After a successful rollback the .bak is identical to the config -
        # remove it so repeated failed modifies do not pile .bak files in $AWG_DIR.
        if cp "$bak" "$cf"; then rm -f "$bak"; else log_warn "Restore error."; fi
        exec {modify_lock_fd}>&-
        return 1
    fi
    if ! grep -q -E "^${param} = " "$cf"; then
        log_error "Replacement failed for '$param'. Restoring..."
        if cp "$bak" "$cf"; then rm -f "$bak"; else log_warn "Restore error."; fi
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
    # Snapshot for the JSON envelope (v5.21.0): collected along the human
    # checks so the data and the verdict come from the same pass.
    local _c_svc_active=false _c_present=false _c_mtu=null _c_addrs=""
    local _c_listen=false _c_mod=false _c_ufw_active=false _c_allowed=false

    log "Service status:"
    # With --json the raw systemctl output goes to stderr: stdout is contract-only.
    if [[ "${JSON_OUTPUT:-0}" -eq 1 ]]; then
        if ! systemctl status awg-quick@awg0 --no-pager >&2; then ok=0; fi
    else
        if ! systemctl status awg-quick@awg0 --no-pager; then ok=0; fi
    fi
    systemctl is-active --quiet awg-quick@awg0 2>/dev/null && _c_svc_active=true

    log "Interface awg0:"
    local _ip_out
    if ! _ip_out=$(ip addr show awg0 2>/dev/null); then
        log_error " - Interface not found!"
        ok=0
    else
        _c_present=true
        while IFS= read -r line; do log "  $line"; done <<< "$_ip_out"
        _c_mtu=$(sed -n 's/.*mtu \([0-9][0-9]*\).*/\1/p' <<< "$_ip_out" | head -n1)
        [[ "$_c_mtu" =~ ^[0-9]+$ ]] || _c_mtu=null
        local _a
        while IFS= read -r _a; do
            [[ -z "$_a" ]] && continue
            _c_addrs+="${_c_addrs:+,}\"$(json_escape "$_a")\""
        done < <(awk '/^[[:space:]]*inet6? /{print $2}' <<< "$_ip_out")
    fi

    log "Port listening:"
    safe_load_config "$CONFIG_FILE" 2>/dev/null
    local port=${AWG_PORT:-0}
    if [[ "$port" -eq 0 ]]; then
        log_warn " - Failed to determine port."
    else
        if ! ss -lunp | grep -q ":${port} "; then
            log_error " - Port ${port}/udp is NOT listening!"
            ok=0
        else
            _c_listen=true
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

    log "Kernel module:"
    # Pattern from diagnose: exact module name in the first lsmod column.
    if lsmod 2>/dev/null | awk '$1 == "amneziawg" {f=1} END {exit !f}'; then
        _c_mod=true
        log " - amneziawg module is loaded."
    else
        # WARN, not ok=0: userspace installs (amneziawg-go, LXC) never have
        # the module, and a broken kernel path already fails service/interface.
        log_warn " - amneziawg module is not loaded (normal for userspace mode)."
    fi

    log "UFW rules:"
    if command -v ufw &>/dev/null; then
        local _ufw_st
        _ufw_st=$(ufw status 2>/dev/null | head -1)
        [[ "$_ufw_st" == "Status: active" ]] && _c_ufw_active=true
        if [[ "$port" -eq 0 ]]; then
            # The port could not be determined above - grepping for "0/udp" would give a false warning.
            log_warn " - Port not determined, UFW rule check skipped."
        elif [[ "$_c_ufw_active" != true ]]; then
            # Inactive UFW used to masquerade as "rule not found": grepping the
            # inactive status output missed the port and blamed the wrong thing.
            log_warn " - UFW is not active (${_ufw_st:-no status})."
        elif ufw status 2>/dev/null | grep -qE "^${port}/udp[[:space:]]+ALLOW"; then
            # Strict pattern from diagnose: specifically ALLOW, not any mention
            # of the port (the old grep -qw did not tell ALLOW from DENY).
            _c_allowed=true
            log " - UFW rule for ${port}/udp is present."
        else
            log_warn " - UFW rule for ${port}/udp not found!"
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

    if [[ "${JSON_OUTPUT:-0}" -eq 1 ]]; then
        local _c_clients _jok=false
        _c_clients=$(grep -c '^\[Peer\]' "$SERVER_CONF_FILE" 2>/dev/null) || _c_clients=0
        [[ "$ok" -eq 1 ]] && _jok=true
        json_out "{\"command\":\"check\",\"ok\":$_jok,\"service\":{\"unit\":\"awg-quick@awg0\",\"active\":$_c_svc_active},\"interface\":{\"name\":\"awg0\",\"present\":$_c_present,\"mtu\":$_c_mtu,\"addresses\":[$_c_addrs]},\"port\":{\"number\":$port,\"proto\":\"udp\",\"listening\":$_c_listen},\"module\":{\"loaded\":$_c_mod},\"clients\":{\"total\":$_c_clients},\"firewall\":{\"ufw_active\":$_c_ufw_active,\"port_allowed\":$_c_allowed}}"
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

    # 8. AWG params snapshot (one awg show call instead of four)
    local _awg_show jc jmin jmax i1
    _awg_show=$(awg show awg0 2>/dev/null)
    jc=$(awk '/^[[:space:]]*jc:/   {print $2; exit}' <<< "$_awg_show")
    jmin=$(awk '/^[[:space:]]*jmin:/ {print $2; exit}' <<< "$_awg_show")
    jmax=$(awk '/^[[:space:]]*jmax:/ {print $2; exit}' <<< "$_awg_show")
    i1=$(awk -F': ' '/^[[:space:]]*i1:/ {print $2; exit}' <<< "$_awg_show")
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
            json_out "[]"
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

        local cf="?" png="?" pk="-" ip="-" ip6="-" st="No data" st_code="no_data"
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
                        st="Active"; st_code="active"
                        [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;32m"
                        ((act++))
                    elif [[ $diff -lt 86400 ]]; then
                        st="Recent"; st_code="recent"
                        [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;33m"
                        ((act++))
                    else
                        st="No handshake"; st_code="no_handshake"
                        [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;37m"
                    fi
                else
                    st="No handshake"; st_code="no_handshake"
                    [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;37m"
                fi
            else
                pk="?"
                st="Key error"; st_code="key_error"
                [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;31m"
            fi
        fi

        # Expiry info: table output only (JSON does not print it - a wasted
        # file read per client). Accept only a numeric timestamp: a corrupted
        # expiry file would throw a bash arithmetic error from
        # format_remaining straight into the table.
        local exp_str=""
        if [[ "$JSON_OUTPUT" -ne 1 ]]; then
            local exp_ts
            exp_ts=$(get_client_expiry "$name" 2>/dev/null)
            if [[ "$exp_ts" =~ ^[0-9]+$ ]]; then
                exp_str=" [$(format_remaining "$exp_ts")]"
            elif [[ -n "$exp_ts" ]]; then
                exp_str=" [expiry corrupted]"
            fi
        fi

        if [[ "$JSON_OUTPUT" -eq 1 ]]; then
            local _ip6_val="${ip6}"
            [[ "$_ip6_val" == "-" ]] && _ip6_val=""
            json_entries+=("{\"name\":\"$(json_escape "$name")\",\"ip\":\"$(json_escape "$ip")\",\"client_ipv6\":\"$(json_escape "$_ip6_val")\",\"status\":\"$(json_escape "$st")\",\"status_code\":\"${st_code}\"}")
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
        _jarr=$(IFS=","; echo "[${json_entries[*]}]")
        json_out "$_jarr"
    else
        echo ""
        log "Total clients: $tot, Active/Recent: $act"
    fi
}

# ==============================================================================
# Traffic statistics
# ==============================================================================

# json_escape is defined in the JSON helpers block at the top of the file
# (moved in v5.21.0: the EXIT guard calls it on any early exit, so the
# definition must precede the trap installation).

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
            json_out "[]"
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
    # date +%s once before the loop (instead of a subprocess per peer);
    # one-second snapshot precision is enough for active/recent statuses.
    local _stats_now
    _stats_now=$(date +%s)

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
        local status="Inactive" status_code="inactive"
        if [[ "$handshake" =~ ^[0-9]+$ && "$handshake" -gt 0 ]]; then
            local diff=$((_stats_now - handshake))
            if [[ $diff -lt 180 ]]; then
                status="Active"; status_code="active"
            elif [[ $diff -lt 86400 ]]; then
                status="Recent"; status_code="recent"
            fi
            hs_str=$(date -d "@$handshake" '+%F %T' 2>/dev/null || echo "$handshake")
        fi

        total_rx=$((total_rx + rx))
        total_tx=$((total_tx + tx))

        if [[ "$JSON_OUTPUT" -eq 1 ]]; then
            json_entries+=("{\"name\":\"$(json_escape "$cname")\",\"ip\":\"$(json_escape "$ip")\",\"rx\":$rx,\"tx\":$tx,\"last_handshake\":$handshake,\"status\":\"$(json_escape "$status")\",\"status_code\":\"${status_code}\"}")
        else
            local rx_h tx_h
            rx_h=$(format_bytes "$rx")
            tx_h=$(format_bytes "$tx")
            table_rows+=("$(printf "%-15s | %-15s | %-12s | %-12s | %-19s | %s" "$cname" "$ip" "$rx_h" "$tx_h" "$hs_str" "$status")")
        fi
    done < <(echo "$awg_dump" | tail -n +2)

    if [[ "$JSON_OUTPUT" -eq 1 ]]; then
        _jarr=$(IFS=","; echo "[${json_entries[*]}]")
        json_out "$_jarr"
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
    if [[ "$_rc" -ne 0 && "${JSON_OUTPUT:-0}" -eq 1 ]]; then
        # --json + usage error: the bot has no use for help text, and the
        # exec >&2 below would hijack stdout away from the emergency JSON
        # guard (exec moves the fd for the whole process, and the guard
        # fires LATER, on EXIT). The cause is already on stderr.
        _JSON_ERR="${_JSON_ERR:-invalid usage (unknown option or command)}"
        exit "$_rc"
    fi
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
    echo "  --json                Machine-readable JSON output (most commands; details in ADVANCED.en.md)"
    echo "                        ENV AWG_STRICT_CONFIRM=1: non-TTY run without --yes is refused (rc 1)"
    echo "  --expires=DURATION    Expiry time for add (1h, 12h, 1d, 7d, 30d, 4w)"
    echo "  --conf-dir=PATH       Specify AWG directory (default: $AWG_DIR)"
    echo "  --server-conf=PATH    Specify server config file"
    echo "  --apply-mode=MODE     syncconf (default) or restart (bypass kernel panic)"
    echo "  --psk                 (add only) generate a PresharedKey for the new client"
    echo "  --reset-routes        (regen only) reset client AllowedIPs to the current"
    echo "                        global routing mode (Issue #170)"
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
    echo "  regen [name ...] [--reset-routes]  Regenerate client file(s), multiple names allowed"
    echo "  modify <name> <p> <v> Modify a client parameter"
    echo "  backup                Create a backup"
    echo "  restore [file]        Restore from backup"
    echo "  check | status        Check server status"
    echo "  diagnose [--carrier=N] Self-troubleshooting: kernel/sysctl/UFW + carrier comparison"
    echo "  show                  Show \`awg show\` status"
    echo "  restart               Restart AmneziaWG service"
    echo "  repair-module         Repair the kernel module after a kernel upgrade (alias: repair)"
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

check_dependencies || { _JSON_ERR="missing dependencies (diagnostics in stderr)"; exit 1; }
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
            # rc=2 (module OK, service did not start) does not block add: the
            # config gets written and apply_config reports the failure itself.
            ensure_amneziawg_kernel_module; _mod_rc=$?
            if [[ "$_mod_rc" -eq 1 ]]; then
                die "amneziawg kernel module unavailable. Run 'manage repair-module' and try again."
            elif [[ "$_mod_rc" -eq 2 ]]; then
                log_warn "awg-quick@awg0 service is not active - the config will be written but may not be applied."
            fi
        fi

        # --psk: enable optional PresharedKey for every new client.
        # Export CLIENT_PSK="auto" -> generate_client produces a fresh
        # 32-byte PSK via `awg genpsk` for each client in the batch
        # (distinct PSK per client).
        if [[ "${CLI_ADD_PSK:-0}" == "1" ]]; then
            export CLIENT_PSK="auto"
            log "PresharedKey will be generated for each new client (--psk)."
        fi

        # Validate --expires ONCE before creating the first client. Otherwise a
        # bad format (--expires=bad) created permanent clients while
        # set_client_expiry failed silently per-client - a temporary client
        # quietly became permanent. A bad format now aborts before any change.
        if [[ -n "$EXPIRES_DURATION" ]]; then
            parse_duration "$EXPIRES_DURATION" >/dev/null \
                || die "Invalid --expires='$EXPIRES_DURATION'. Use: 1h, 12h, 1d, 7d, 30d, 4w."
        fi

        _added=0
        _jr=()
        for _cname in "${ARGS[@]}"; do
            validate_client_name "$_cname" || { _cmd_rc=1; _jr+=("{\"name\":\"$(json_escape "$_cname")\",\"status\":\"invalid_name\"}"); continue; }

            if grep -qxF "#_Name = ${_cname}" "$SERVER_CONF_FILE"; then
                # _cmd_rc=1 - parity with remove ("No clients to remove") and
                # regen ("not found, skipping"): a no-op for this name must be
                # distinguishable via the exit code for automation (Issue #175).
                log_warn "Client '$_cname' already exists, skipping."
                _cmd_rc=1
                _jr+=("{\"name\":\"$(json_escape "$_cname")\",\"status\":\"exists\"}")
                continue
            fi

            # In batch mode each client gets its own PSK: reset to "auto"
            # so generate_client generates a new one every iteration.
            if [[ "${CLI_ADD_PSK:-0}" == "1" ]]; then
                export CLIENT_PSK="auto"
            fi

            # Stale artifacts of a same-named client from the past (the QR
            # may not regenerate if qrencode disappeared): without cleanup the
            # [[ -f ]] checks below would report someone else's old file as
            # fresh - both in the log and in JSON.
            rm -f "$AWG_DIR/${_cname}.png" "$AWG_DIR/${_cname}.vpnuri" "$AWG_DIR/${_cname}.vpnuri.png"

            log "Adding '$_cname'..."
            if generate_client "$_cname"; then
                log "Client '$_cname' added."
                # Mention .png only if the QR was actually created (qrencode
                # may be absent) - symmetric to the .vpnuri check below.
                if [[ -f "$AWG_DIR/${_cname}.png" ]]; then
                    log "Files: $AWG_DIR/${_cname}.conf, $AWG_DIR/${_cname}.png"
                else
                    log "Files: $AWG_DIR/${_cname}.conf"
                fi
                if [[ -f "$AWG_DIR/${_cname}.vpnuri" ]]; then
                    log "vpn:// URI: $AWG_DIR/${_cname}.vpnuri"
                fi
                if [[ -n "$EXPIRES_DURATION" ]]; then
                    if set_client_expiry "$_cname" "$EXPIRES_DURATION"; then
                        install_expiry_cron || { log_error "Client '$_cname' created with an expiry, but the auto-removal cron was NOT installed - the expired client will not be removed automatically."; _cmd_rc=1; }
                    else
                        # Format is validated above, so this is a write failure
                        # (FS/permissions). The client exists and works but has NO
                        # auto-expiry - signal it so a temporary client does not
                        # silently stay permanent.
                        log_error "Client '$_cname' created, but expiry was NOT set (expiry write error). The client is permanent - set the expiry again or remove it."
                        _cmd_rc=1
                    fi
                fi
                ((_added++))
                # JSON success entry: qr/vpnuri are paths if the file really
                # exists at response time (generate_client reports success
                # even when QR/URI failed); expires_at is epoch or null.
                _jqr="null"; _juri="null"; _jexp="null"
                [[ -f "$AWG_DIR/${_cname}.png" ]] && _jqr="\"$(json_escape "$AWG_DIR/${_cname}.png")\""
                [[ -f "$AWG_DIR/${_cname}.vpnuri" ]] && _juri="\"$(json_escape "$AWG_DIR/${_cname}.vpnuri")\""
                if [[ -n "$EXPIRES_DURATION" ]]; then
                    _jexp_val=$(get_client_expiry "$_cname" 2>/dev/null) || _jexp_val=""
                    [[ "$_jexp_val" =~ ^[0-9]+$ ]] && _jexp="$_jexp_val"
                fi
                _jr+=("{\"name\":\"$(json_escape "$_cname")\",\"status\":\"created\",\"conf\":\"$(json_escape "$AWG_DIR/${_cname}.conf")\",\"qr\":$_jqr,\"vpnuri\":$_juri,\"expires_at\":$_jexp}")
            else
                log_error "Error adding client '$_cname'."
                _cmd_rc=1
                _jr+=("{\"name\":\"$(json_escape "$_cname")\",\"status\":\"error\"}")
            fi
        done

        _japplied=false
        if [[ $_added -gt 0 ]]; then
            if [[ "${AWG_SKIP_APPLY:-0}" == "1" ]]; then
                apply_config
                log "Clients added: $_added. Apply deferred (AWG_SKIP_APPLY=1)."
            elif apply_config; then
                _japplied=true
                log "Clients added: $_added. Configuration applied."
            else
                log_error "Clients added: $_added, but apply_config failed. Config written but NOT applied to live interface. Check: systemctl status awg-quick@awg0"
                _cmd_rc=1
            fi
        fi
        if [[ "$JSON_OUTPUT" -eq 1 ]]; then
            _jrj=""
            [[ ${#_jr[@]} -gt 0 ]] && _jrj=$(IFS=,; printf '%s' "${_jr[*]}")
            _jok=false; [[ "$_cmd_rc" -eq 0 ]] && _jok=true
            json_out "{\"command\":\"add\",\"ok\":$_jok,\"added\":$_added,\"failed\":$(( ${#ARGS[@]} - _added )),\"applied\":$_japplied,\"results\":[$_jrj]}"
        fi
        # Hygiene: do not let CLIENT_PSK leak into later operations
        unset CLIENT_PSK
        ;;

    remove)
        [[ ${#ARGS[@]} -eq 0 ]] && die "Client name not specified."

        # Validate all names before removing
        _valid_names=()
        _jr=()
        for _rname in "${ARGS[@]}"; do
            validate_client_name "$_rname" || { _cmd_rc=1; _jr+=("{\"name\":\"$(json_escape "$_rname")\",\"status\":\"invalid_name\"}"); continue; }
            if ! grep -qxF "#_Name = ${_rname}" "$SERVER_CONF_FILE"; then
                # _cmd_rc=1 (v5.21.0): a partial not-found used to give rc 0 -
                # asymmetric with add (exists -> rc 1) and regen (not-found ->
                # rc 1). Spec 3.4: 'remove a ghost' = partial success = rc 1.
                log_warn "Client '$_rname' not found, skipping."
                _cmd_rc=1
                _jr+=("{\"name\":\"$(json_escape "$_rname")\",\"status\":\"not_found\"}")
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
                # rc=2 (module OK, service did not start) does not block remove -
                # symmetric with add: apply_config reports the failure itself.
                ensure_amneziawg_kernel_module; _mod_rc=$?
                if [[ "$_mod_rc" -eq 1 ]]; then
                    die "amneziawg kernel module unavailable. Run 'manage repair-module' and try again."
                elif [[ "$_mod_rc" -eq 2 ]]; then
                    log_warn "awg-quick@awg0 service is not active - the config will be written but may not be applied."
                fi
            fi

            _removed=0
            for _rname in "${_valid_names[@]}"; do
                log "Removing '$_rname'..."
                if remove_peer_from_server "$_rname"; then
                    _remove_client_files "$_rname"
                    remove_client_expiry "$_rname"
                    log "Client '$_rname' removed."
                    ((_removed++))
                    _jr+=("{\"name\":\"$(json_escape "$_rname")\",\"status\":\"removed\"}")
                else
                    log_error "Error removing '$_rname'."
                    _cmd_rc=1
                    _jr+=("{\"name\":\"$(json_escape "$_rname")\",\"status\":\"error\"}")
                fi
            done

            _japplied=false
            if [[ $_removed -gt 0 ]]; then
                if [[ "${AWG_SKIP_APPLY:-0}" == "1" ]]; then
                    apply_config
                    log "Clients removed: $_removed. Apply deferred (AWG_SKIP_APPLY=1)."
                elif apply_config; then
                    _japplied=true
                    log "Clients removed: $_removed. Configuration applied."
                else
                    log_error "Clients removed: $_removed, but apply_config failed. Peers removed from config but may still be present on live interface. Check: systemctl status awg-quick@awg0"
                    _cmd_rc=1
                fi
            fi
        fi
        if [[ "$JSON_OUTPUT" -eq 1 ]]; then
            _jrj=""
            [[ ${#_jr[@]} -gt 0 ]] && _jrj=$(IFS=,; printf '%s' "${_jr[*]}")
            _jok=false; [[ "$_cmd_rc" -eq 0 ]] && _jok=true
            json_out "{\"command\":\"remove\",\"ok\":$_jok,\"removed\":${_removed:-0},\"failed\":$(( ${#ARGS[@]} - ${_removed:-0} )),\"applied\":${_japplied:-false},\"results\":[$_jrj]}"
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
        # --reset-routes (Issue #170): pass the flag to regenerate_client via
        # ENV - a regular regen preserves per-client AllowedIPs, with the flag
        # every client gets the global routing mode from awgsetup_cfg.init.
        if [[ "${CLI_RESET_ROUTES:-0}" == "1" ]]; then
            export AWG_REGEN_RESET_ROUTES=1
            log "AllowedIPs of all regenerated clients will be reset to the global routing mode (--reset-routes)."
        fi
        _jr=()
        _regen_count=0
        _regen_total=0
        if [[ ${#ARGS[@]} -eq 0 ]]; then
            # No arguments — regenerate all clients (preserves prior behaviour).
            all_clients=$(grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //')
            if [[ -z "$all_clients" ]]; then
                # Empty list is a regular no-op: rc 0, regenerated=0 in JSON.
                log "No clients found."
            else
                while IFS= read -r cname; do
                    cname="${cname## }"; cname="${cname%% }"
                    [[ -z "$cname" ]] && continue
                    _regen_total=$((_regen_total + 1))
                    log "Regenerating '$cname'..."
                    if regenerate_client "$cname"; then
                        _regen_count=$((_regen_count + 1))
                        _jr+=("$(_regen_json_entry "$cname")")
                    else
                        log_warn "Regeneration error '$cname'"
                        _cmd_rc=1
                        _jr+=("{\"name\":\"$(json_escape "$cname")\",\"status\":\"error\"}")
                    fi
                done <<< "$all_clients"
                log "Regeneration completed."
            fi
        else
            # With arguments — process each name individually (parity with add/remove).
            # Until v5.11.5 only $CLIENT_NAME (=ARGS[0]) was read here, the rest were
            # silently dropped (Issue #70).
            _regen_total=${#ARGS[@]}
            for _cname in "${ARGS[@]}"; do
                validate_client_name "$_cname" || { _cmd_rc=1; _jr+=("{\"name\":\"$(json_escape "$_cname")\",\"status\":\"invalid_name\"}"); continue; }
                if ! grep -qxF "#_Name = ${_cname}" "$SERVER_CONF_FILE"; then
                    log_warn "Client '$_cname' not found, skipping."
                    _cmd_rc=1
                    _jr+=("{\"name\":\"$(json_escape "$_cname")\",\"status\":\"not_found\"}")
                    continue
                fi
                log "Regenerating '$_cname'..."
                if regenerate_client "$_cname"; then
                    _regen_count=$((_regen_count + 1))
                    _jr+=("$(_regen_json_entry "$_cname")")
                else
                    log_error "Regeneration error '$_cname'."
                    _cmd_rc=1
                    _jr+=("{\"name\":\"$(json_escape "$_cname")\",\"status\":\"error\"}")
                fi
            done
            if [[ $_regen_count -gt 0 ]]; then
                log "Regeneration completed. Processed: $_regen_count of ${#ARGS[@]}."
            fi
        fi
        if [[ "$JSON_OUTPUT" -eq 1 ]]; then
            _jrj=""
            [[ ${#_jr[@]} -gt 0 ]] && _jrj=$(IFS=,; printf '%s' "${_jr[*]}")
            _jok=false; [[ "$_cmd_rc" -eq 0 ]] && _jok=true
            _jreset=false; [[ "${CLI_RESET_ROUTES:-0}" == "1" ]] && _jreset=true
            # regen does not change server state (keys and IPs are reused,
            # no apply needed) - the envelope has no applied field on purpose.
            json_out "{\"command\":\"regen\",\"ok\":$_jok,\"regenerated\":$_regen_count,\"failed\":$(( _regen_total - _regen_count )),\"reset_routes\":$_jreset,\"results\":[$_jrj]}"
        fi
        ;;

    modify)
        [[ -z "$CLIENT_NAME" ]] && die "Client name not specified."
        validate_client_name "$CLIENT_NAME" || { _JSON_ERR="invalid client name"; exit 1; }
        if modify_client "$CLIENT_NAME" "$PARAM" "$VALUE"; then
            # modify edits ONLY the client config (DNS/MTU/AllowedIPs/...):
            # server state does not change, no apply needed - the envelope has
            # no applied field on purpose (symmetry with regen).
            json_out "{\"command\":\"modify\",\"ok\":true,\"name\":\"$(json_escape "$CLIENT_NAME")\",\"param\":\"$(json_escape "$PARAM")\",\"value\":\"$(json_escape "$VALUE")\"}"
        else
            _cmd_rc=1
        fi
        ;;

    backup)
        if backup_configs; then
            _jsize=null
            if [[ -n "${LAST_BACKUP_PATH:-}" && -f "$LAST_BACKUP_PATH" ]]; then
                _jsize=$(stat -c%s "$LAST_BACKUP_PATH" 2>/dev/null) || _jsize=null
            fi
            json_out "{\"command\":\"backup\",\"ok\":true,\"path\":\"$(json_escape "${LAST_BACKUP_PATH:-}")\",\"size_bytes\":$_jsize}"
        else
            _cmd_rc=1
        fi
        ;;

    restore)
        if restore_backup "$CLIENT_NAME"; then # CLIENT_NAME is used as [file]
            _jclients=$(grep -c '^\[Peer\]' "$SERVER_CONF_FILE" 2>/dev/null) || _jclients=0
            _jkeys=false
            [[ -n "$(find "$KEYS_DIR" -maxdepth 1 -name '*.private' -print -quit 2>/dev/null)" ]] && _jkeys=true
            # clients = number of [Peer] blocks in the RESTORED server config
            # (spec 3.3: not files in clients/ - those can diverge).
            json_out "{\"command\":\"restore\",\"ok\":true,\"source\":\"$(json_escape "${_RESTORE_SOURCE:-}")\",\"applied\":true,\"rolled_back\":false,\"restored\":{\"server_conf\":true,\"clients\":$_jclients,\"keys\":$_jkeys}}"
        else
            _cmd_rc=1
            # Envelope on failure too: the bot needs to know whether a rollback
            # happened. error is human-readable text; decide by ok/rc.
            if [[ "$JSON_OUTPUT" -eq 1 ]]; then
                _jrb=false; [[ "${_RESTORE_ROLLED_BACK:-0}" == "1" ]] && _jrb=true
                json_out "{\"command\":\"restore\",\"ok\":false,\"error\":\"$(json_escape "${_JSON_ERR:-restore failed (see stderr)}")\",\"source\":\"$(json_escape "${_RESTORE_SOURCE:-}")\",\"applied\":false,\"rolled_back\":$_jrb,\"rc\":1}"
            fi
        fi
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
            _JSON_ERR="service restart failed"
            log_error "Restart error."
            status_out=$(systemctl status awg-quick@awg0 --no-pager 2>&1) || true
            while IFS= read -r line; do log_error "  $line"; done <<< "$status_out"
            exit 1
        else
            log "Service restarted."
            _jactive=false
            systemctl is-active --quiet awg-quick@awg0 2>/dev/null && _jactive=true
            json_out "{\"command\":\"restart\",\"ok\":true,\"unit\":\"awg-quick@awg0\",\"active\":$_jactive}"
        fi
        ;;

    repair-module|repair)
        # Explicit user-facing command: after a kernel upgrade the module may
        # need a DKMS rebuild. Allow apt-installing kernel headers here
        # (AWG_ALLOW_APT_IN_ENSURE=1) — the user explicitly requested repair.
        log "Repairing amneziawg kernel module (may take up to 5 minutes — DKMS rebuild)..."
        AWG_ALLOW_APT_IN_ENSURE=1 ensure_amneziawg_kernel_module full; _mod_rc=$?
        _jmod=true; _jsvc=false
        case "$_mod_rc" in
            0)
                _jsvc=true
                log "amneziawg kernel module repaired, awg-quick@awg0 service is active."
                ;;
            2)
                # Previously this case masqueraded as success: "service is
                # active" + exit 0 while the service was down (Issue #175).
                log_error "The kernel module is fine, but the awg-quick@awg0 service did NOT start."
                log_error "Diagnostics: systemctl status awg-quick@awg0; journalctl -u awg-quick@awg0 -n 50"
                _cmd_rc=1
                ;;
            *)
                _jmod=false
                log_error "Could not repair the kernel module. See log above; manual recovery may be required."
                _cmd_rc=1
                ;;
        esac
        if [[ "$JSON_OUTPUT" -eq 1 ]]; then
            _jok=false; [[ "$_cmd_rc" -eq 0 ]] && _jok=true
            # rc here = ensure_amneziawg_kernel_module code (0/1/2), not the exit code.
            json_out "{\"command\":\"repair-module\",\"ok\":$_jok,\"module_loaded\":$_jmod,\"service_active\":$_jsvc,\"rc\":$_mod_rc}"
        fi
        ;;

    diagnose)
        diagnose_server || _cmd_rc=1
        ;;

    # No help) branch here on purpose: every path that sets COMMAND="help"
    # (-h/--help, unknown option, positional help) is intercepted BEFORE the
    # dispatcher by the early `usage` (which terminates the process via exit).

    *)
        log_error "Unknown command: '$COMMAND'"
        _cmd_rc=1
        usage
        ;;
esac

log "Management script finished."
exit $_cmd_rc
