#!/bin/bash

# Проверка минимальной версии Bash
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "ОШИБКА: Требуется Bash >= 4.0 (текущая: ${BASH_VERSION})" >&2; exit 1
fi

# ==============================================================================
# Скрипт для управления пользователями (пирами) AmneziaWG 2.0
# Автор: @bivlked
# Версия: 5.19.0
# Дата: 2026-07-11
# Репозиторий: https://github.com/bivlked/amneziawg-installer
# ==============================================================================

# --- Безопасный режим и Константы ---
# shellcheck disable=SC2034
SCRIPT_VERSION="5.19.0"
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
CLI_CARRIER=""

# --- Автоочистка временных файлов и директорий ---
# _manage_temp_dirs хранит mktemp -d пути для backup/restore.
# _awg_cleanup из awg_common.sh удаляет файлы (awg_mktemp), но не директории —
# поэтому здесь chained cleanup: сначала наши директории, потом библиотечный.
# Гарантирует что SIGINT во время backup_configs/restore_backup не оставит
# orphan /tmp/tmp.XXXX (audit).
_manage_temp_dirs=()

manage_mktempdir() {
    local d
    d=$(mktemp -d) || return 1
    _manage_temp_dirs+=("$d")
    echo "$d"
}

_manage_cleaned=0
_manage_cleanup() {
    # Идемпотентно: на INT/TERM зовётся из сигнального обработчика, затем ещё раз
    # на EXIT - повтор должен быть no-op.
    [[ "$_manage_cleaned" -eq 1 ]] && return 0
    _manage_cleaned=1
    local d
    for d in "${_manage_temp_dirs[@]}"; do
        [[ -d "$d" ]] && rm -rf "$d"
    done
    type _awg_cleanup &>/dev/null && _awg_cleanup
}
# На INT/TERM раньше cleanup срабатывал, но скрипт НЕ завершался - выполнение шло
# дальше после прерванной команды, и cleanup повторялся на EXIT. Теперь сигнал =
# cleanup + явный выход 130/143. restore_backup на время destructive-фазы ставит
# СВОЙ INT/TERM-обработчик (с откатом), затем снимает его в _restore_cleanup.
_manage_on_signal() {
    _manage_cleanup
    exit "$1"
}
trap _manage_cleanup EXIT
trap '_manage_on_signal 130' INT
trap '_manage_on_signal 143' TERM

# --- Обработка аргументов ---
COMMAND=""
HELP_EXIT_RC=0   # C1: 0 = явный help (exit 0); ставится в 1 для ошибок использования
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
            _CLI_APPLY_MODE="${1#*=}"
            # Валидация сразу при парсинге: опечатка (--apply-mode=restrat)
            # молча работала бы как syncconf - пользователь, обходящий проблему
            # режимом restart, не узнал бы, что режим не применился.
            case "$_CLI_APPLY_MODE" in
                syncconf|restart) ;;
                *) echo "Недопустимое значение --apply-mode: '$_CLI_APPLY_MODE' (ожидается: syncconf или restart)" >&2; exit 1 ;;
            esac
            export AWG_APPLY_MODE="$_CLI_APPLY_MODE"
            shift ;;
        --psk)             CLI_ADD_PSK=1; shift ;;
        --reset-routes)    CLI_RESET_ROUTES=1; shift ;;
        --yes)             CLI_YES=1; shift ;;
        --carrier=*)       CLI_CARRIER="${1#*=}"; shift ;;
        --*)               echo "Неизвестная опция: $1" >&2; COMMAND="help"; HELP_EXIT_RC=1; break ;;
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

# Обновляем пути после возможного переопределения --conf-dir
CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init"
KEYS_DIR="$AWG_DIR/keys"
COMMON_SCRIPT_PATH="$AWG_DIR/awg_common.sh"
LOG_FILE="$AWG_DIR/manage_amneziawg.log"

# ==============================================================================
# Функции логирования
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
        echo "[$ts] ERROR: Ошибка записи лога $LOG_FILE" >&2
    fi

    # WARN и ERROR в stderr (симметрия с install_amneziawg.sh:110+, важно
    # для CI/automation парсинга: stdout = «данные», stderr = «диагностика»).
    if [[ "$type" == "ERROR" || "$type" == "WARN" ]]; then
        printf "${color_start}%s${color_end}\n" "$entry" >&2
    elif [[ "${JSON_OUTPUT:-0}" -eq 1 ]]; then
        # weaq P2: в режиме --json stdout обязан содержать ТОЛЬКО JSON (jq/automation).
        # INFO/DEBUG уводим в stderr, иначе list/show/stats --json печатают INFO-строки
        # перед JSON и ломают парсинг (подтверждено на biHetzner).
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
# Утилиты
# ==============================================================================

is_interactive() { [[ -t 0 && -t 1 ]]; }

# Экранирование спецсимволов для sed (предотвращает command injection)
escape_sed() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//&/\\&}"
    s="${s//#/\\#}"
    s="${s////\\/}"
    printf '%s' "$s"
}

confirm_action() {
    # CLI флаг --yes или ENV AWG_YES=1 пропускают confirm-prompt — для скриптов,
    # cron, Ansible и интерактивных вызовов где явно подтвердили заранее.
    if [[ "${CLI_YES:-0}" == "1" || "${AWG_YES:-0}" == "1" ]]; then
        return 0
    fi
    if ! is_interactive; then return 0; fi
    local action="$1" subject="$2"
    read -rp "Вы действительно хотите $action $subject? [y/N]: " confirm < /dev/tty
    # Принимаем y/yes (регистронезависимо) + случайные пробелы/CR по краям.
    if [[ "$confirm" =~ ^[[:space:]]*[Yy]([Ee][Ss])?[[:space:]]*$ ]]; then
        return 0
    else
        log "Действие отменено."
        return 1
    fi
}

validate_client_name() {
    local name="$1"
    if [[ -z "$name" ]]; then log_error "Имя пустое."; return 1; fi
    if [[ ${#name} -gt 63 ]]; then log_error "Имя > 63 симв."; return 1; fi
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then log_error "Имя содержит недоп. символы."; return 1; fi
    return 0
}

# ==============================================================================
# Проверка зависимостей
# ==============================================================================

check_dependencies() {
    log "Проверка зависимостей..."
    local ok=1

    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Не найден: $CONFIG_FILE"
        ok=0
    fi
    if [[ ! -f "$COMMON_SCRIPT_PATH" ]]; then
        log_error "Не найден: $COMMON_SCRIPT_PATH"
        ok=0
    fi
    if [[ ! -f "$SERVER_CONF_FILE" ]]; then
        log_error "Не найден: $SERVER_CONF_FILE"
        ok=0
    fi
    if [[ "$ok" -eq 0 ]]; then
        die "Не найдены файлы установки. Запустите install_amneziawg.sh."
    fi

    if ! command -v awg &>/dev/null; then die "'awg' не найден."; fi
    if ! command -v qrencode &>/dev/null; then log_warn "qrencode не найден (QR-коды не будут созданы)."; fi

    # Подключаем общую библиотеку
    # shellcheck source=/dev/null
    source "$COMMON_SCRIPT_PATH" || die "Ошибка загрузки $COMMON_SCRIPT_PATH"

    log "Зависимости OK."
}

# ==============================================================================
# Резервное копирование
# ==============================================================================

# Внутренняя функция: выполняет бэкап без захвата блокировки.
# Вызывается только из контекста, где .awg_backup.lock уже удерживается.
#
# Контракт обработки ошибок (v5.11.0 A1.1):
#   - Критичные артефакты (awg0.conf, CONFIG_FILE, server_*.key, клиентские
#     *.conf, $KEYS_DIR/*) — при ошибке cp возвращает 1 (не продолжает
#     молча). Повреждённый backup опаснее отсутствующего.
#   - Опциональные (QR *.png, *.vpnuri, expiry/, cron) — ошибка cp → log_warn,
#     продолжаем. Они восстанавливаются из конфига.
#   - Отсутствие глобов (клиентов нет) отличается от cp-failure через
#     compgen -G pre-check.
# По успеху устанавливает LAST_BACKUP_PATH (используется restore_backup
# для rollback snapshot).
_backup_configs_nolock() {
    # --no-prune: не удалять старые бэкапы после создания. Используется
    # pre-restore snapshot'ом: иначе при уже накопленных 10 бэкапах prune
    # обрезал бы самый старый, которым может оказаться именно выбранный для
    # восстановления файл (он лежит в той же папке $AWG_DIR/backups).
    local no_prune=0
    if [[ "${1:-}" == "--no-prune" ]]; then
        no_prune=1
        shift
    fi
    log "Создание бэкапа..."
    local bd="$AWG_DIR/backups"
    mkdir -p "$bd" || die "Ошибка mkdir $bd"
    chmod 700 "$bd" 2>/dev/null
    local ts bf td
    # Миллисекундная точность в timestamp защищает от collision при rapid-fire
    # backup'ах (например, regen → backup → modify → backup в одной секунде).
    ts=$(date +%F_%H-%M-%S.%3N)
    bf="$bd/awg_backup_${ts}.tar.gz"
    td=$(manage_mktempdir) || die "Ошибка создания временной директории"

    mkdir -p "$td/server" "$td/clients" "$td/keys"

    # Серверный конфиг (mandatory)
    if [[ -f "$SERVER_CONF_FILE" ]]; then
        if ! cp -a "$SERVER_CONF_FILE" "$td/server/"; then
            log_error "Не удалось сохранить $SERVER_CONF_FILE в бэкап."
            rm -rf "$td"
            return 1
        fi
    else
        log_warn "Серверный конфиг отсутствует ($SERVER_CONF_FILE) — в бэкап не попадёт."
    fi
    # Опциональные файлы рядом с awg0.conf (backup'ы от modify, и т.п.)
    if compgen -G "${SERVER_CONF_FILE}.*" > /dev/null; then
        cp -a "${SERVER_CONF_FILE}".* "$td/server/" 2>/dev/null || \
            log_warn "Не удалось сохранить ${SERVER_CONF_FILE}.* (некритично)."
    fi

    # Метаданные клиентов (mandatory)
    if [[ -f "$CONFIG_FILE" ]]; then
        if ! cp -a "$CONFIG_FILE" "$td/clients/"; then
            log_error "Не удалось сохранить $CONFIG_FILE в бэкап."
            rm -rf "$td"
            return 1
        fi
    fi
    # Клиентские *.conf (critical если существуют)
    if compgen -G "$AWG_DIR/*.conf" > /dev/null; then
        if ! cp -a "$AWG_DIR"/*.conf "$td/clients/"; then
            log_error "Не удалось сохранить клиентские *.conf в бэкап."
            rm -rf "$td"
            return 1
        fi
    fi
    # QR-коды *.png (optional — перегенерируются из conf)
    if compgen -G "$AWG_DIR/*.png" > /dev/null; then
        cp -a "$AWG_DIR"/*.png "$td/clients/" 2>/dev/null || \
            log_warn "Не удалось сохранить клиентские *.png (некритично)."
    fi
    # vpn:// URI (optional — перегенерируются)
    if compgen -G "$AWG_DIR/*.vpnuri" > /dev/null; then
        cp -a "$AWG_DIR"/*.vpnuri "$td/clients/" 2>/dev/null || \
            log_warn "Не удалось сохранить клиентские *.vpnuri (некритично)."
    fi

    # Ключи клиентов (critical если существуют)
    if compgen -G "$KEYS_DIR/*" > /dev/null; then
        if ! cp -a "$KEYS_DIR"/* "$td/keys/"; then
            log_error "Не удалось сохранить ключи клиентов ($KEYS_DIR) в бэкап."
            rm -rf "$td"
            return 1
        fi
    fi

    # Ключи сервера (mandatory если существуют)
    if [[ -f "$AWG_DIR/server_private.key" ]]; then
        if ! cp -a "$AWG_DIR/server_private.key" "$td/"; then
            log_error "Не удалось сохранить server_private.key в бэкап."
            rm -rf "$td"
            return 1
        fi
    fi
    if [[ -f "$AWG_DIR/server_public.key" ]]; then
        if ! cp -a "$AWG_DIR/server_public.key" "$td/"; then
            log_error "Не удалось сохранить server_public.key в бэкап."
            rm -rf "$td"
            return 1
        fi
    fi

    # Expiry (critical — Unix epoch метки не восстановимы из других конфигов).
    # Потеря этих данных меняет поведение expiry-enforcement после restore.
    if [[ -d "${EXPIRY_DIR:-$AWG_DIR/expiry}" ]]; then
        if ! cp -a "${EXPIRY_DIR:-$AWG_DIR/expiry}" "$td/expiry"; then
            log_error "Не удалось сохранить expiry/ в бэкап."
            rm -rf "$td"
            return 1
        fi
    fi
    # Cron awg-expiry (critical — без него expiry-enforcement перестаёт работать).
    if [[ -f /etc/cron.d/awg-expiry ]]; then
        if ! cp -a /etc/cron.d/awg-expiry "$td/"; then
            log_error "Не удалось сохранить /etc/cron.d/awg-expiry в бэкап."
            rm -rf "$td"
            return 1
        fi
    fi

    tar -czf "$bf" -C "$td" . || { rm -rf "$td"; die "Ошибка tar $bf"; }
    log_debug "tar: архив создан $bf"
    rm -rf "$td"
    chmod 600 "$bf" || log_warn "Ошибка chmod бэкапа"

    # Оставляем максимум 10 бэкапов (кроме режима --no-prune)
    if [[ "$no_prune" -eq 0 ]]; then
        find "$bd" -maxdepth 1 -name "awg_backup_*.tar.gz" -printf '%T@ %p\n' | \
            sort -nr | tail -n +11 | cut -d' ' -f2- | xargs -r rm -f || \
            log_warn "Ошибка удаления старых бэкапов"
    fi

    LAST_BACKUP_PATH="$bf"
    log "Бэкап создан: $bf"
}

backup_configs() {
    local backup_lockfile="${AWG_DIR}/.awg_backup.lock"
    local backup_lock_fd
    exec {backup_lock_fd}>"$backup_lockfile"
    if ! flock -x -w 30 "$backup_lock_fd"; then
        log_error "Таймаут ожидания блокировки backup (30 сек). Другая операция backup/restore уже запущена."
        exec {backup_lock_fd}>&-
        return 1
    fi
    # Дополнительно берём конфиг-лок: параллельный `manage add/remove` мог
    # изменить awg0.conf/keys МЕЖДУ копированием server/ и clients/ в tmpdir -
    # каждый файл в бэкапе цел (atomic mv), но набор рассинхронизирован
    # (peer-mismatch при restore). restore_backup держит оба лока - бэкап
    # должен делать так же. ВАЖНО: в restore _backup_configs_nolock вызывается
    # под уже взятым конфиг-локом - здесь лок берётся только для прямой
    # команды backup (flock non-reentrant, см. контракт в awg_common.sh).
    local config_lockfile="${AWG_DIR}/.awg_config.lock"
    local config_lock_fd
    exec {config_lock_fd}>"$config_lockfile"
    if ! flock -x -w 30 "$config_lock_fd"; then
        log_error "Таймаут ожидания блокировки конфига (30 сек)."
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

# Откат к pre-restore snapshot (v5.11.0 A5.1).
# Вызывается из restore_backup при любой ошибке после начала destructive ops.
# Извлекает snapshot из $1 и копирует файлы обратно в исходные пути, затем
# пытается запустить сервис. Не критично, если cp какого-то файла провалится:
# цель — вернуть систему в рабочее состояние best-effort, чтобы пользователь
# не остался без VPN.
_restore_do_rollback() {
    local _snap="$1"
    if [[ -z "$_snap" || ! -f "$_snap" ]]; then
        log_error "Rollback snapshot недоступен ($_snap) — требуется ручное восстановление."
        return 1
    fi
    log_warn "Откат к состоянию до restore ($(basename "$_snap"))..."
    local _rtd
    _rtd=$(manage_mktempdir) || {
        log_error "Не удалось создать tmpdir для отката. Ручное: tar -xzf $_snap -C /"
        return 1
    }
    if ! tar -xzf "$_snap" --no-same-owner --no-same-permissions -C "$_rtd" 2>/dev/null; then
        rm -rf "$_rtd"
        log_error "Не удалось распаковать rollback snapshot ($_snap). Ручное восстановление: tar -xzf $_snap -C <нужная папка>"
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

    log "Откат завершён — пытаюсь запустить сервис..."
    if systemctl start awg-quick@awg0; then
        log "Сервис запущен после отката."
        return 0
    else
        log_error "Сервис не стартовал после отката — проверьте: systemctl status awg-quick@awg0"
        return 1
    fi
}

restore_backup() {
    local bf="$1"
    local bd="$AWG_DIR/backups"

    if [[ -z "$bf" ]]; then
        if ! is_interactive; then
            die "Путь к бэкапу обязателен в неинтерактивном режиме: restore <файл>"
        fi
        if [[ ! -d "$bd" ]] || [[ -z "$(ls -A "$bd" 2>/dev/null)" ]]; then
            die "Бэкапы не найдены в $bd."
        fi
        local backups
        backups=$(find "$bd" -maxdepth 1 -name "awg_backup_*.tar.gz" | sort -r)
        if [[ -z "$backups" ]]; then die "Бэкапы не найдены."; fi

        echo "Доступные бэкапы:"
        local i=1
        local bl=()
        while IFS= read -r f; do
            echo "  $i) $(basename "$f")"
            bl[$i]="$f"
            ((i++))
        done <<< "$backups"

        read -rp "Номер для восстановления (0-отмена): " choice < /dev/tty
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -eq 0 ]] || [[ "$choice" -ge "$i" ]]; then
            log "Отмена."
            return 1
        fi
        bf="${bl[$choice]}"
    fi

    if [[ ! -f "$bf" ]]; then die "Файл бэкапа '$bf' не найден."; fi
    log "Восстановление из $bf"
    if ! confirm_action "восстановить" "конфигурацию из '$bf'"; then return 1; fi

    # v5.11.0 A5.1: rollback infrastructure.
    # _rollback_snap заполнится после _backup_configs_nolock — до этого
    # момента destructive ops не выполняются, откат не нужен.
    # _destructive_ops_started=1 ставится перед первой деструктивной
    # операцией (после systemctl stop) — rollback делаем только когда
    # система реально изменена, иначе cp тех же байт это no-op overhead.
    # _restore_ok=1 выставляется только на финальном успехе.
    local _rollback_snap=""
    local _restore_ok=0
    local _destructive_ops_started=0
    local td=""

    # Захват блокировки backup (внешняя) — предотвращает параллельные backup/restore
    local backup_lockfile="${AWG_DIR}/.awg_backup.lock"
    local backup_lock_fd
    exec {backup_lock_fd}>"$backup_lockfile"
    if ! flock -x -w 30 "$backup_lock_fd"; then
        log_error "Таймаут ожидания блокировки backup (30 сек). Другая операция backup/restore уже запущена."
        exec {backup_lock_fd}>&-
        return 1
    fi

    # Захват блокировки конфига (внутренняя) — предотвращает изменение конфига во время restore
    local config_lockfile="${AWG_DIR}/.awg_config.lock"
    local config_lock_fd
    exec {config_lock_fd}>"$config_lockfile"
    if ! flock -x -w 30 "$config_lock_fd"; then
        log_error "Таймаут ожидания блокировки конфига (30 сек)."
        exec {config_lock_fd}>&-
        exec {backup_lock_fd}>&-
        return 1
    fi

    # Cleanup-хук: вызывается на любом return (через trap RETURN).
    # При _restore_ok=0 И _destructive_ops_started=1 → rollback к
    # _rollback_snap. Всегда → удаление временной директории и снятие
    # блокировок. Первым делом сбрасываем RETURN trap — bash `trap ...
    # RETURN` имеет global lifetime и без очистки срабатывал бы на
    # любом последующем return в этом shell.
    _restore_cleanup() {
        # Порядок важен: сначала захватываем $? (return-code функции
        # restore_backup), потом снимаем RETURN trap. Swap сломал бы
        # захват, т.к. `trap - RETURN` — builtin, затирает $? в 0.
        # Реентранс невозможен: `local` и `trap -` не вызывают функций,
        # а после `trap - RETURN` наш trap уже снят.
        local _rc=$?
        # Снимаем RETURN и ВОССТАНАВЛИВАЕМ глобальные INT/TERM (локальные хуки
        # restore выставлены ниже). Просто `trap -` сбросил бы их в default и
        # менеджер после restore потерял бы B1-поведение signal -> cleanup+exit.
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
    # INT/TERM в ходе restore: тот же rollback+cleanup, что и на обычном return
    # (_restore_cleanup видит локальные _restore_ok/_rollback_snap/td), затем выход
    # с сигнальным кодом. Перекрывает глобальный _manage_on_signal, чтобы прерывание
    # destructive-фазы не оставило систему без отката. _restore_cleanup сам снимет
    # эти хуки (trap - INT TERM выше).
    trap '_restore_cleanup; exit 130' INT
    trap '_restore_cleanup; exit 143' TERM

    log "Создание бэкапа текущей..."
    # --no-prune: выбранный для восстановления $bf лежит в той же папке бэкапов;
    # prune после создания pre-restore снапшота мог бы удалить именно его.
    if ! _backup_configs_nolock --no-prune; then
        log_error "Не удалось создать бэкап текущей конфигурации."
        return 1
    fi
    # Фиксируем rollback snapshot (устанавливается _backup_configs_nolock)
    _rollback_snap="${LAST_BACKUP_PATH:-}"

    td=$(manage_mktempdir) || {
        log_error "Ошибка создания временной директории"
        return 1
    }

    # Pre-extraction валидация: проверяем содержимое tar до распаковки.
    # Defense-in-depth: наш threat model (root-only локальные бэкапы) делает
    # эксплуатацию маловероятной, но crafted или подменённый архив мог бы
    # использовать path traversal (../), абсолютные пути, symlinks или device
    # файлы для перезаписи произвольных системных файлов при распаковке от root.

    # Проверка типов через verbose listing: отклоняем block/char/FIFO/symlink ('l')
    # и hardlink ('h') - оба класса ссылок небезопасны при распаковке.
    local _tar_verbose _vline _tc
    _tar_verbose=$(tar -tvzf "$bf" 2>/dev/null) || {
        log_error "Не удалось прочитать содержимое архива $bf"
        return 1
    }
    while IFS= read -r _vline; do
        [[ -z "$_vline" ]] && continue
        _tc="${_vline:0:1}"
        case "$_tc" in
            b|c|p|h|l)
                log_error "Архив содержит опасный тип файла ('${_tc}'): '${_vline}' — восстановление отменено."
                return 1
                ;;
        esac
    done <<< "$_tar_verbose"

    # Проверка путей: абсолютные пути и path traversal
    local _tar_list _bad_entry
    _tar_list=$(tar -tzf "$bf" 2>/dev/null) || {
        log_error "Не удалось прочитать содержимое архива $bf"
        return 1
    }
    while IFS= read -r _bad_entry; do
        [[ -z "$_bad_entry" ]] && continue
        # Абсолютные пути
        if [[ "$_bad_entry" == /* ]]; then
            log_error "Архив содержит абсолютный путь: '$_bad_entry' — восстановление отменено."
            return 1
        fi
        # Parent directory traversal
        if [[ "$_bad_entry" == *..* ]]; then
            log_error "Архив содержит path traversal (..): '$_bad_entry' — восстановление отменено."
            return 1
        fi
    done <<< "$_tar_list"
    log_debug "Pre-extraction проверка пройдена: $(echo "$_tar_list" | wc -l) файлов в архиве."

    if ! tar -xzf "$bf" --no-same-owner --no-same-permissions -C "$td"; then
        log_error "Ошибка tar $bf"
        return 1
    fi

    # Post-extraction проверка: нет symlinks в распакованном дереве
    local _symlinks
    _symlinks=$(find "$td" -type l 2>/dev/null)
    if [[ -n "$_symlinks" ]]; then
        log_error "Архив содержит symlinks (возможная symlink attack):"
        while IFS= read -r _sl; do log_error "  $_sl → $(readlink "$_sl")"; done <<< "$_symlinks"
        return 1
    fi

    # Проверка полноты бэкапа ДО остановки сервиса. Бэкап без серверного конфига
    # бесполезен (VPN без него не поднять), а пустой server/ ронял `cp "$td/server/"*`
    # уже ПОСЛЕ stop и форсил откат рабочей системы. Проверяем до destructive-фазы:
    # сервис не трогаем, откат не нужен.
    local _srv_base
    _srv_base=$(basename "$SERVER_CONF_FILE")
    if [[ ! -f "$td/server/$_srv_base" ]]; then
        log_error "Бэкап неполный: отсутствует серверный конфиг ($_srv_base) - восстановление отменено."
        return 1
    fi

    log "Остановка сервиса..."
    systemctl stop awg-quick@awg0 || log_warn "Сервис не остановлен."

    # С этого момента destructive ops. Все error paths → trap _restore_cleanup → rollback.
    _destructive_ops_started=1
    if [[ -d "$td/server" ]]; then
        log "Восстановление конфига сервера..."
        local server_conf_dir
        server_conf_dir=$(dirname "$SERVER_CONF_FILE")
        mkdir -p "$server_conf_dir"
        if ! cp -a "$td/server/"* "$server_conf_dir/"; then
            log_error "Ошибка копирования server — восстановление прервано (запуск отката)."
            return 1
        fi
        chmod 600 "$server_conf_dir"/*.conf 2>/dev/null
        chmod 700 "$server_conf_dir"
        log_debug "Конфиг сервера восстановлен в $server_conf_dir"
    fi

    if [[ -d "$td/clients" ]]; then
        log "Восстановление файлов клиентов..."
        # C11: чистая замена, не merge. Удаляю stale client-артефакты, которых
        # нет в бэкапе (иначе клиент, удалённый после снятия бэкапа, остаётся
        # orphan .conf/.png/.vpnuri). Scope строго managed client-globs - НЕ
        # трогаю скрипты, server-ключи, backups/, логи, .lock, awgsetup_cfg.init.
        rm -f "$AWG_DIR"/*.conf "$AWG_DIR"/*.png "$AWG_DIR"/*.vpnuri 2>/dev/null || true
        # Пустой clients/ - валидный случай (сервер без клиентских конфигов):
        # prune выше уже дал чистую замену, copy просто пропускаем (без compgen
        # голый glob "$td/clients/"* остался бы литералом и уронил cp -> откат).
        if compgen -G "$td/clients/*" > /dev/null; then
            if ! cp -a "$td/clients/"* "$AWG_DIR/"; then
                log_error "Ошибка копирования clients — восстановление прервано (запуск отката)."
                return 1
            fi
            chmod 600 "$AWG_DIR"/*.conf 2>/dev/null
            chmod 600 "$AWG_DIR"/*.png 2>/dev/null
            chmod 600 "$AWG_DIR"/*.vpnuri 2>/dev/null
            chmod 600 "$CONFIG_FILE" 2>/dev/null
            log_debug "Файлы клиентов восстановлены в $AWG_DIR"
        else
            log_debug "Бэкап без клиентских файлов (clients/ пуст) - пропуск копирования."
        fi
    fi

    if [[ -d "$td/keys" ]]; then
        log "Восстановление ключей..."
        mkdir -p "$KEYS_DIR"
        # C11: удаляю stale client-ключи, которых нет в бэкапе (server-ключи
        # лежат в AWG_DIR, не в KEYS_DIR, поэтому не затрагиваются).
        rm -f "$KEYS_DIR"/* 2>/dev/null || true
        # C2: keys/ в бэкапе может быть пустым (сервер без клиентских ключей).
        # Без compgen-guard голый glob "$td/keys/*" остался бы литералом, cp упал
        # бы, и весь restore ушёл бы в откат. Пустой keys/ - не ошибка.
        if ! compgen -G "$td/keys/*" > /dev/null; then
            log_debug "Бэкап без клиентских ключей (keys/ пуст) - пропуск, не ошибка."
        elif ! cp -a "$td/keys/"* "$KEYS_DIR/"; then
            log_error "Ошибка копирования keys — восстановление прервано (запуск отката)."
            return 1
        else
            chmod 600 "$KEYS_DIR"/* 2>/dev/null
            log_debug "Ключи восстановлены в $KEYS_DIR"
        fi
    fi

    # Серверные ключи: cp -a сохраняет mode из архива, поэтому форсируем 600
    # независимо от того с какими правами они лежали в backup-е (audit fix).
    if [[ -f "$td/server_private.key" ]]; then
        if ! cp -a "$td/server_private.key" "$AWG_DIR/"; then
            log_error "Ошибка копирования server_private.key — восстановление прервано (запуск отката)."
            return 1
        fi
        chmod 600 "$AWG_DIR/server_private.key" 2>/dev/null || true
    fi
    if [[ -f "$td/server_public.key" ]]; then
        if ! cp -a "$td/server_public.key" "$AWG_DIR/"; then
            log_error "Ошибка копирования server_public.key — восстановление прервано (запуск отката)."
            return 1
        fi
        chmod 600 "$AWG_DIR/server_public.key" 2>/dev/null || true
    fi

    if [[ -d "$td/expiry" ]]; then
        log "Восстановление данных expiry..."
        mkdir -p "${EXPIRY_DIR:-$AWG_DIR/expiry}"
        # C11: expiry НЕ пруним намеренно. Orphan-метки для несуществующих клиентов
        # безвредны: check_expired_clients при истечении распознаёт отсутствие peer
        # в конфиге и зачищает метку с артефактами сам. Prune здесь был бы небезопасен:
        # и rm, и последующий cp - best-effort (|| true), так что сбой copy после
        # prune молча оставил бы expiry пустым. Сами client-артефакты пруним выше.
        cp -a "$td/expiry/"* "${EXPIRY_DIR:-$AWG_DIR/expiry}/" 2>/dev/null || true
        chmod 600 "${EXPIRY_DIR:-$AWG_DIR/expiry}"/* 2>/dev/null
    fi
    if [[ -f "$td/awg-expiry" ]]; then
        cp -a "$td/awg-expiry" /etc/cron.d/awg-expiry
        chmod 644 /etc/cron.d/awg-expiry
    fi

    # Pre-flight: валидация восстановленного конфига ДО старта сервиса.
    # Если конфиг invalid — сервис гарантированно упадёт, лучше откатиться
    # сейчас и объяснить причину, чем стартовать сломанный awg-quick@awg0.
    if ! validate_awg_config >/dev/null 2>&1; then
        log_error "Восстановленный серверный конфиг не прошёл валидацию — запуск отката."
        return 1
    fi

    log "Запуск сервиса..."
    if ! systemctl start awg-quick@awg0; then
        log_error "Ошибка запуска сервиса — запуск отката."
        local status_out
        status_out=$(systemctl status awg-quick@awg0 --no-pager 2>&1) || true
        while IFS= read -r line; do log_error "  $line"; done <<< "$status_out"
        return 1
    fi

    # Успех — rollback не нужен, trap выполнит только cleanup
    _restore_ok=1
    log "Восстановление завершено."
    return 0
}

# ==============================================================================
# Изменение параметра клиента
# ==============================================================================

modify_client() {
    local name="$1" param="$2" value="$3"

    if [[ -z "$name" || -z "$param" || -z "$value" ]]; then
        log_error "Использование: modify <имя> <параметр> <значение>"
        return 1
    fi

    # Валидация ДО взятия блокировки (ранние return не требуют fd cleanup)
    local allowed_params="DNS|Endpoint|AllowedIPs|PersistentKeepalive"
    if ! [[ "$param" =~ ^($allowed_params)$ ]]; then
        log_error "Параметр '$param' нельзя изменить через modify."
        log_error "Допустимые параметры: ${allowed_params//|/, }"
        return 1
    fi

    case "$param" in
        DNS)
            # Структурная проверка списка DNS. Старый charset-only regex
            # ^[0-9a-fA-F.:,\ ]+$ пропускал мусор ('abc' - буквы a-f; '999.999.999.999' -
            # вне диапазона). DNS по контракту - только IP через запятую (без FQDN),
            # поэтому каждый элемент = bare IPv4 или IPv6, как у Endpoint/AllowedIPs.
            case "$value" in
                *$'\n'*|*$'\r'*|*\\*|*\"*|*\'*|"")
                    log_error "Невалидный DNS: '$value'"
                    return 1 ;;
            esac
            case "$value" in
                ,*|*,|*,,*)
                    log_error "Невалидный DNS '$value': пустой элемент списка (лишняя запятая)"
                    return 1 ;;
            esac
            local _dns_tok _dns_ifs="$IFS"
            IFS=','
            for _dns_tok in $value; do
                _dns_tok="${_dns_tok//[[:space:]]/}"
                if [[ -z "$_dns_tok" ]]; then
                    IFS="$_dns_ifs"
                    log_error "Невалидный DNS '$value': пустой элемент списка (лишняя запятая)"
                    return 1
                fi
                if ! _valid_ipv4 "$_dns_tok" && ! _valid_ipv6 "$_dns_tok"; then
                    IFS="$_dns_ifs"
                    log_error "Невалидный DNS '$value': '$_dns_tok' не похож на IPv4/IPv6-адрес"
                    return 1
                fi
            done
            IFS="$_dns_ifs"
            ;;
        PersistentKeepalive)
            if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -gt 65535 ]]; then
                log_error "Невалидный PersistentKeepalive: '$value' (допустимо: 0-65535)"
                return 1
            fi ;;
        Endpoint)
            # C5: помимо отсечения опасных символов - позитивная проверка host:port.
            case "$value" in
                *$'\n'*|*$'\r'*|*\\*|*\"*|*\'*|*' '*|*$'\t'*|"")
                    log_error "Невалидный Endpoint: '$value'"
                    return 1 ;;
            esac
            local _eh _ept
            if [[ "$value" == \[*\]:* ]]; then
                _eh="${value%]:*}"; _eh="${_eh#\[}"   # IPv6 без скобок
                _ept="${value##*]:}"
                _valid_ipv6 "$_eh" || { log_error "Невалидный Endpoint '$value': некорректный IPv6-хост"; return 1; }
            else
                _eh="${value%:*}"; _ept="${value##*:}"
                _valid_host_or_ipv4 "$_eh" || { log_error "Невалидный Endpoint '$value': ожидается host:port (FQDN / IPv4 / [IPv6])"; return 1; }
            fi
            { [[ "$_ept" =~ ^[0-9]+$ ]] && [[ "$_ept" -ge 1 && "$_ept" -le 65535 ]]; } || { log_error "Невалидный Endpoint '$value': порт должен быть 1-65535"; return 1; }
            ;;
        AllowedIPs)
            # C5: помимо отсечения опасных символов - позитивная проверка CIDR-списка.
            case "$value" in
                *$'\n'*|*$'\r'*|*\\*|*\"*|*\'*|"")
                    log_error "Невалидный AllowedIPs: '$value'"
                    return 1 ;;
            esac
            # Лишние запятые: word-splitting по IFS=',' молча отбрасывает
            # ХВОСТОВОЙ пустой элемент (например "10.0.0.0/24,"), поэтому проверяем
            # структуру списка отдельно: ведущая/хвостовая/двойная запятая.
            case "$value" in
                ,*|*,|*,,*)
                    log_error "Невалидный AllowedIPs '$value': пустой элемент списка (лишняя запятая)"
                    return 1 ;;
            esac
            local _aip_tok _aip_ifs="$IFS"
            IFS=','
            for _aip_tok in $value; do
                _aip_tok="${_aip_tok//[[:space:]]/}"
                if [[ -z "$_aip_tok" ]]; then
                    IFS="$_aip_ifs"
                    log_error "Невалидный AllowedIPs '$value': пустой элемент списка (лишняя запятая)"
                    return 1
                fi
                if ! _valid_cidr "$_aip_tok"; then
                    IFS="$_aip_ifs"
                    log_error "Невалидный AllowedIPs '$value': '$_aip_tok' не похож на CIDR (IPv4/IPv6 с опциональным префиксом /n)"
                    return 1
                fi
            done
            IFS="$_aip_ifs"
            ;;
    esac

    # Блокировка перед state-проверками (защита от TOCTOU с concurrent remove)
    local modify_lockfile="${AWG_DIR}/.awg_config.lock"
    local modify_lock_fd
    exec {modify_lock_fd}>"$modify_lockfile"
    if ! flock -x -w 10 "$modify_lock_fd"; then
        log_error "Не удалось получить блокировку конфигурации (другая операция выполняется)"
        exec {modify_lock_fd}>&-
        return 1
    fi

    if ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE"; then
        exec {modify_lock_fd}>&-
        die "Клиент '$name' не найден."
    fi

    local cf="$AWG_DIR/$name.conf"
    if [[ ! -f "$cf" ]]; then exec {modify_lock_fd}>&-; die "Файл $cf не найден."; fi

    if ! grep -q -E "^${param}[[:space:]]*=" "$cf"; then
        log_error "Параметр '$param' не найден в $cf."
        exec {modify_lock_fd}>&-
        return 1
    fi

    log "Изменение '$param' на '$value' для '$name'..."
    local bak
    bak="${cf}.bak-$(date +%F_%H-%M-%S)"
    # v5.11.0 A5.2: бэкап критически важен — если cp провалился, без бэкапа
    # destructive sed может повредить конфиг без возможности отката. Выходим.
    if ! cp "$cf" "$bak"; then
        log_error "Не удалось создать бэкап '$bak' — destructive sed отменён."
        exec {modify_lock_fd}>&-
        return 1
    fi
    log "Бэкап: $bak"

    local escaped_value
    escaped_value=$(escape_sed "$value")
    if ! sed -i "s#^${param}[[:space:]]*=[[:space:]]*.*#${param} = ${escaped_value}#" "$cf"; then
        log_error "Ошибка sed. Восстановление..."
        # После успешного отката .bak идентичен конфигу - удаляем, чтобы
        # повторные неудачные modify не копили .bak-файлы в $AWG_DIR.
        if cp "$bak" "$cf"; then rm -f "$bak"; else log_warn "Ошибка восстановления."; fi
        exec {modify_lock_fd}>&-
        return 1
    fi
    if ! grep -q -E "^${param} = " "$cf"; then
        log_error "Замена не выполнена для '$param'. Восстановление..."
        if cp "$bak" "$cf"; then rm -f "$bak"; else log_warn "Ошибка восстановления."; fi
        exec {modify_lock_fd}>&-
        return 1
    fi
    log_debug "sed: ${param} = ${value} в $cf"

    log "Параметр '$param' изменен."
    rm -f "$bak"

    log "Перегенерация QR-кода и vpn:// URI..."
    generate_qr "$name" || log_warn "Не удалось обновить QR-код."
    if generate_vpn_uri "$name"; then
        generate_qr_vpnuri "$name" || log_warn "Не удалось обновить QR vpn://."
    else
        log_warn "Не удалось обновить vpn:// URI."
    fi

    exec {modify_lock_fd}>&-
    return 0
}

# ==============================================================================
# Проверка состояния сервера
# ==============================================================================

check_server() {
    log "Проверка состояния сервера AmneziaWG 2.0..."
    local ok=1

    log "Статус сервиса:"
    if ! systemctl status awg-quick@awg0 --no-pager; then ok=0; fi

    log "Интерфейс awg0:"
    if ! ip addr show awg0 &>/dev/null; then
        log_error " - Интерфейс не найден!"
        ok=0
    else
        while IFS= read -r line; do log "  $line"; done < <(ip addr show awg0)
    fi

    log "Прослушивание порта:"
    safe_load_config "$CONFIG_FILE" 2>/dev/null
    local port=${AWG_PORT:-0}
    if [[ "$port" -eq 0 ]]; then
        log_warn " - Не удалось определить порт."
    else
        if ! ss -lunp | grep -q ":${port} "; then
            log_error " - Порт ${port}/udp НЕ прослушивается!"
            ok=0
        else
            log " - Порт ${port}/udp прослушивается."
        fi
    fi

    log "Настройки ядра:"
    local fwd
    fwd=$(sysctl -n net.ipv4.ip_forward)
    if [[ "$fwd" != "1" ]]; then
        log_error " - IP Forwarding выключен ($fwd)!"
        ok=0
    else
        log " - IP Forwarding включен."
    fi

    log "Правила UFW:"
    if command -v ufw &>/dev/null; then
        if [[ "$port" -eq 0 ]]; then
            # Порт не определился выше - grep по "0/udp" дал бы ложный warning.
            log_warn " - Порт не определён, проверка правила UFW пропущена."
        elif ! ufw status | grep -qw "${port}/udp"; then
            log_warn " - Правило UFW для ${port}/udp не найдено!"
        else
            log " - Правило UFW для ${port}/udp есть."
        fi
    else
        log_warn " - UFW не установлен."
    fi

    log "Статус AmneziaWG 2.0:"
    # Раньше awg show вызывался через process substitution без проверки exit code,
    # из-за чего check мог отрапортовать "Состояние OK" даже когда awg упал.
    # Теперь захватываем вывод и проверяем exit code (audit).
    local _awg_out
    if ! _awg_out=$(awg show awg0 2>&1); then
        log_error " - awg show awg0 завершился с ошибкой:"
        while IFS= read -r _l; do log_error "  $_l"; done <<< "$_awg_out"
        ok=0
    else
        while IFS= read -r _l; do log "  $_l"; done <<< "$_awg_out"
        if grep -q "jc:" <<< "$_awg_out"; then
            log " - AWG 2.0 параметры обфускации: активны"
        else
            log_warn " - AWG 2.0 параметры обфускации не обнаружены"
        fi
    fi

    if [[ "$ok" -eq 1 ]]; then
        log "Проверка завершена: Состояние OK."
        return 0
    else
        log_error "Проверка завершена: ОБНАРУЖЕНЫ ПРОБЛЕМЫ!"
        return 1
    fi
}

# ==============================================================================
# Diagnose: self-troubleshooting с опциональным сравнением по оператору
# ==============================================================================

# Известные операторы и рекомендуемые AWG-параметры.
# Формат: jc_min jc_max jmin_lo jmin_hi jmax_offset_lo jmax_offset_hi i1_mode
#   i1_mode: random (формат "<r N>"), absent (I1 не должно быть), binary ("<r N><b 0xHEX>")
# Источник: ADVANCED.md operator matrix (только подтверждённые ✅ строки).
# Megafon Москва из таблицы пока 🔄 тестируется (Jc=3, Jmin=80, Jmax=268) -
# параметры широкие и не вписываются в mobile preset; добавим когда оператор
# подтвердят и зафиксируют диапазоны. T-Mobile MO US - Discussion #45 (o2me).
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

# Вывод одной строки результата с цветом
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

# Главная функция: пробегается по health-checks + опционально сравнивает с оператором
diagnose_server() {
    local carrier="${CLI_CARRIER}"
    local ok=0 warn=0 fail=0

    log "Диагностика AmneziaWG 2.0 сервера..."
    if [[ -n "$carrier" ]] && ! _diagnose_carrier_known "$carrier" >/dev/null; then
        log_error "Неизвестный оператор: '$carrier'"
        log_error "Поддерживаемые: $(_diagnose_carrier_list)"
        return 1
    fi

    # 1. Kernel module
    if lsmod 2>/dev/null | awk '$1 == "amneziawg" {f=1} END {exit !f}'; then
        _diag_line OK "Модуль ядра amneziawg загружен"; ok=$((ok+1))
    else
        _diag_line FAIL "Модуль ядра amneziawg НЕ загружен"
        echo "        Fix: sudo bash $0 repair-module"
        fail=$((fail+1))
    fi

    # 2. Service active
    if systemctl is-active --quiet awg-quick@awg0 2>/dev/null; then
        _diag_line OK "Сервис awg-quick@awg0 активен"; ok=$((ok+1))
    else
        _diag_line FAIL "Сервис awg-quick@awg0 НЕактивен"
        echo "        Fix: sudo systemctl start awg-quick@awg0"
        fail=$((fail+1))
    fi

    # 3. Interface awg0 UP
    if ip link show awg0 2>/dev/null | grep -qE "state (UP|UNKNOWN)"; then
        local awg_ip
        awg_ip=$(ip -4 -o addr show awg0 2>/dev/null | awk '{print $4; exit}')
        _diag_line OK "Интерфейс awg0 UP (${awg_ip:-?})"; ok=$((ok+1))
    else
        _diag_line FAIL "Интерфейс awg0 не UP (или не существует)"
        fail=$((fail+1))
    fi

    # 4. sysctl ip_forward
    local fwd
    fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "?")
    if [[ "$fwd" == "1" ]]; then
        _diag_line OK "sysctl net.ipv4.ip_forward=1"; ok=$((ok+1))
    else
        _diag_line FAIL "sysctl net.ipv4.ip_forward=$fwd (требуется 1)"
        echo "        Fix: echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.d/99-awg.conf && sudo sysctl --system"
        fail=$((fail+1))
    fi

    # 5. BBR congestion control (recommended, not required)
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
    if [[ "$cc" == "bbr" ]]; then
        _diag_line OK "sysctl tcp_congestion_control=bbr"; ok=$((ok+1))
    else
        _diag_line WARN "sysctl tcp_congestion_control=$cc (рекомендуется bbr)"
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
                _diag_line WARN "UFW active, но ${awg_port}/udp не в ALLOW (трафик может не приходить)"
                warn=$((warn+1))
            fi
        else
            _diag_line WARN "UFW не active ($ufw_st)"; warn=$((warn+1))
        fi
    else
        _diag_line WARN "ufw не установлен"; warn=$((warn+1))
    fi

    # 7. Peer count
    local peer_count
    peer_count=$(awg show awg0 peers 2>/dev/null | wc -l)
    _diag_line INFO "Peers сконфигурировано: $peer_count"

    # 8. AWG params snapshot (один вызов awg show вместо четырёх)
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
        log "Сравнение с профилем оператора '$carrier'..."
        local row
        row=$(_diagnose_carrier_known "$carrier")
        # row: jc_min jc_max jmin_lo jmin_hi jmax_off_lo jmax_off_hi i1_mode
        local rc_jc_min rc_jc_max rc_jmin_lo rc_jmin_hi rc_jmax_off_lo rc_jmax_off_hi rc_i1
        read -r rc_jc_min rc_jc_max rc_jmin_lo rc_jmin_hi rc_jmax_off_lo rc_jmax_off_hi rc_i1 <<<"$row"

        # Jc range check
        if [[ -n "$jc" && "$jc" =~ ^[0-9]+$ && "$jc" -ge "$rc_jc_min" && "$jc" -le "$rc_jc_max" ]]; then
            _diag_line OK "Jc=$jc в диапазоне [$rc_jc_min..$rc_jc_max] для $carrier"; ok=$((ok+1))
        else
            _diag_line WARN "Jc=${jc:-?} вне рекомендуемого [$rc_jc_min..$rc_jc_max] для $carrier"
            warn=$((warn+1))
        fi

        # Jmin range check
        if [[ -n "$jmin" && "$jmin" =~ ^[0-9]+$ && "$jmin" -ge "$rc_jmin_lo" && "$jmin" -le "$rc_jmin_hi" ]]; then
            _diag_line OK "Jmin=$jmin в диапазоне [$rc_jmin_lo..$rc_jmin_hi] для $carrier"; ok=$((ok+1))
        else
            _diag_line WARN "Jmin=${jmin:-?} вне рекомендуемого [$rc_jmin_lo..$rc_jmin_hi] для $carrier"
            warn=$((warn+1))
        fi

        # Jmax offset check (Jmax should be in [Jmin+off_lo, Jmin+off_hi])
        if [[ -n "$jmax" && -n "$jmin" && "$jmax" =~ ^[0-9]+$ && "$jmin" =~ ^[0-9]+$ ]]; then
            local jmax_off=$((jmax - jmin))
            if [[ "$jmax_off" -ge "$rc_jmax_off_lo" && "$jmax_off" -le "$rc_jmax_off_hi" ]]; then
                _diag_line OK "Jmax-Jmin=$jmax_off в диапазоне [$rc_jmax_off_lo..$rc_jmax_off_hi]"; ok=$((ok+1))
            else
                _diag_line WARN "Jmax-Jmin=$jmax_off вне [$rc_jmax_off_lo..$rc_jmax_off_hi] (для $carrier меньше Jmax часто стабильнее)"
                warn=$((warn+1))
            fi
        else
            _diag_line WARN "Jmax-Jmin не удалось вычислить (Jmax=${jmax:-?}, Jmin=${jmin:-?})"
            warn=$((warn+1))
        fi

        # I1 mode check
        case "$rc_i1" in
            absent)
                if [[ -z "$i1" || "$i1" == "absent" ]]; then
                    _diag_line OK "I1 отсутствует (требуется для $carrier)"; ok=$((ok+1))
                else
                    _diag_line WARN "I1=$i1, но $carrier требует I1=absent"
                    echo "        Fix: отредактировать /etc/amnezia/amneziawg/awg0.conf, удалить строку 'I1 = ...', sudo systemctl restart awg-quick@awg0"
                    warn=$((warn+1))
                fi
                ;;
            random)
                if [[ -n "$i1" && "$i1" =~ ^\<r\ [0-9]+\>$ ]]; then
                    _diag_line OK "I1 random ($i1) - подходит для $carrier"; ok=$((ok+1))
                elif [[ -z "$i1" ]]; then
                    _diag_line WARN "I1 отсутствует, $carrier обычно работает с I1 random (<r N>)"
                    warn=$((warn+1))
                else
                    _diag_line WARN "I1=$i1 нестандартный формат (для $carrier обычно <r N>)"
                    warn=$((warn+1))
                fi
                ;;
            binary)
                if [[ -n "$i1" && "$i1" =~ ^\<r\ [0-9]+\>\<b\ 0x[0-9A-Fa-f]+\> ]]; then
                    _diag_line OK "I1 binary ($i1) - подходит для $carrier"; ok=$((ok+1))
                else
                    _diag_line WARN "I1=${i1:-absent}, $carrier (T-Mobile MO) требует binary I1 (<r N><b 0xHEX>)"
                    warn=$((warn+1))
                fi
                ;;
        esac
    fi

    # Summary
    echo ""
    log "Итого: OK=$ok WARN=$warn FAIL=$fail"
    if [[ "$fail" -gt 0 ]]; then
        return 1
    fi
    return 0
}

# ==============================================================================
# Список клиентов
# ==============================================================================

list_clients() {
    log "Получение списка клиентов..."
    local clients
    clients=$(grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //' | sort) || clients=""
    if [[ -z "$clients" ]]; then
        if [[ "$JSON_OUTPUT" -eq 1 ]]; then
            echo "[]"
        else
            log "Клиенты не найдены."
        fi
        return 0
    fi

    local verbose=$VERBOSE_LIST
    local act=0 tot=0

    # Однопроходный парсинг серверного конфига: name → pubkey
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

    # Однопроходный парсинг awg show dump: pubkey → handshake timestamp
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
            printf "%-20s | %-7s | %-7s | %-36s | %-15s | %s\n" "Имя клиента" "Conf" "QR" "IP-адрес" "Ключ (нач.)" "Статус"
            printf -- "-%.0s" {1..114}
            echo
        else
            printf "%-20s | %-7s | %-7s | %s\n" "Имя клиента" "Conf" "QR" "Статус"
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

        local cf="?" png="?" pk="-" ip="-" ip6="-" st="Нет данных" st_code="no_data"
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
                        st="Активен"; st_code="active"
                        [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;32m"
                        ((act++))
                    elif [[ $diff -lt 86400 ]]; then
                        st="Недавно"; st_code="recent"
                        [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;33m"
                        ((act++))
                    else
                        st="Нет handshake"; st_code="no_handshake"
                        [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;37m"
                    fi
                else
                    st="Нет handshake"; st_code="no_handshake"
                    [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;37m"
                fi
            else
                pk="?"
                st="Ошибка ключа"; st_code="key_error"
                [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;31m"
            fi
        fi

        # Expiry info: только для табличного вывода (JSON его не печатает -
        # лишнее чтение файла на каждого клиента). Принимаем только числовой
        # timestamp: повреждённый expiry-файл дал бы ошибку bash-арифметики
        # из format_remaining прямо в таблице.
        local exp_str=""
        if [[ "$JSON_OUTPUT" -ne 1 ]]; then
            local exp_ts
            exp_ts=$(get_client_expiry "$name" 2>/dev/null)
            if [[ "$exp_ts" =~ ^[0-9]+$ ]]; then
                exp_str=" [$(format_remaining "$exp_ts")]"
            elif [[ -n "$exp_ts" ]]; then
                exp_str=" [expiry повреждён]"
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
        ( IFS=","; echo "[${json_entries[*]}]" )
    else
        echo ""
        log "Всего клиентов: $tot, Активных/Недавно: $act"
    fi
}

# ==============================================================================
# Статистика трафика
# ==============================================================================

# Экранирование строки для безопасного включения в JSON
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# Форматирование размера в человекочитаемый формат
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
            log "Клиенты не найдены."
        fi
        return 0
    fi

    # Получаем данные awg show awg0
    local awg_dump
    awg_dump=$(awg show awg0 dump 2>/dev/null) || {
        log_error "Ошибка получения данных awg show."
        return 1
    }

    # Маппинг: публичный ключ → имя клиента (single-pass)
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
    # date +%s один раз до цикла (а не subprocess на каждого пира);
    # точности секундного среза для статусов active/recent достаточно.
    local _stats_now
    _stats_now=$(date +%s)

    # awg show dump: каждая строка пира = pubkey psk endpoint allowed-ips latest-handshake rx tx keepalive
    # shellcheck disable=SC2034
    while IFS=$'\t' read -r pk psk ep aips handshake rx tx keepalive; do
        local cname="${pk_to_name[$pk]:-unknown}"
        if [[ "$cname" == "unknown" ]]; then continue; fi

        local ip="-"
        if [[ -f "$AWG_DIR/${cname}.conf" ]]; then
            ip=$(grep -oP 'Address = \K[0-9.]+' "$AWG_DIR/${cname}.conf" 2>/dev/null) || ip="?"
        fi

        local hs_str="никогда"
        local status="Неактивен" status_code="inactive"
        if [[ "$handshake" =~ ^[0-9]+$ && "$handshake" -gt 0 ]]; then
            local diff=$((_stats_now - handshake))
            if [[ $diff -lt 180 ]]; then
                status="Активен"; status_code="active"
            elif [[ $diff -lt 86400 ]]; then
                status="Недавно"; status_code="recent"
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
        ( IFS=","; echo "[${json_entries[*]}]" )
    else
        log "Статистика трафика клиентов:"
        echo ""
        printf "%-15s | %-15s | %-12s | %-12s | %-19s | %s\n" "Имя" "IP" "Получено" "Отправлено" "Последний handshake" "Статус"
        printf -- "-%.0s" {1..95}
        echo
        for row in "${table_rows[@]}"; do
            echo "$row"
        done
        echo ""
        log "Итого: Получено $(format_bytes "$total_rx"), Отправлено $(format_bytes "$total_tx")"
    fi
}

# ==============================================================================
# Справка
# ==============================================================================

usage() {
    # C1: явный help (rc=0) -> stdout + exit 0; ошибка использования (rc!=0,
    # дефолт) -> stderr + exit 1. Явные help-вызовы передают 0, error-вызовы
    # опускают аргумент (получают 1).
    local _rc="${1:-1}"
    [[ "$_rc" -ne 0 ]] && exec >&2
    echo ""
    echo "Скрипт управления AmneziaWG 2.0 (v${SCRIPT_VERSION})"
    echo "=============================================="
    echo "Использование: $0 [ОПЦИИ] <КОМАНДА> [АРГУМЕНТЫ]"
    echo ""
    echo "Опции:"
    echo "  -h, --help            Показать эту справку"
    echo "  -v, --verbose         Расширенный вывод (для команды list)"
    echo "  --no-color            Отключить цветной вывод"
    echo "  --json                Машиночитаемый JSON-вывод (для команд list / stats)"
    echo "  --expires=ВРЕМЯ       Срок действия при add (1h, 12h, 1d, 7d, 30d, 4w)"
    echo "  --conf-dir=ПУТЬ       Указать директорию AWG (умолч: $AWG_DIR)"
    echo "  --server-conf=ПУТЬ    Указать файл конфига сервера"
    echo "  --apply-mode=РЕЖИМ    syncconf (умолч.) или restart (обход kernel panic)"
    echo "  --psk                 (только для add) сгенерировать PresharedKey для клиента"
    echo "  --reset-routes        (только для regen) сбросить AllowedIPs клиентов на текущий"
    echo "                        глобальный режим маршрутизации (Issue #170)"
    echo "  --yes                 Не спрашивать подтверждение (эквивалент ENV AWG_YES=1)"
    echo "  --carrier=NAME        (только для diagnose) сравнить AWG-параметры с профилем оператора"
    echo "                        Доступные: beeline_msk yota_msk tele2_msk tele2_krasnoyarsk"
    echo "                                   tattelecom megafon_regions tmobile_us"
    echo "                        Exit code: 1 только при FAIL или неизвестном операторе (WARN -> 0)"
    echo ""
    echo "Команды:"
    echo "  add <имя> [имя2 ...]        Добавить клиента(ов). --expires применяется ко всем"
    echo "  remove <имя> [имя2 ...]     Удалить клиента(ов)"
    echo "  list [-v] [--json]    Показать список клиентов (--json: машиночитаемый, с client_ipv6)"
    echo "  stats [--json]        Статистика трафика по клиентам"
    echo "  regen [имя ...] [--reset-routes]  Перегенерировать файлы клиента(ов), можно несколько имён"
    echo "  modify <имя> <пар> <зн> Изменить параметр клиента"
    echo "  backup                Создать бэкап"
    echo "  restore [файл]        Восстановить из бэкапа"
    echo "  check | status        Проверить состояние сервера"
    echo "  diagnose [--carrier=N] Self-troubleshooting: kernel/sysctl/UFW + сравнение с оператором"
    echo "  show                  Показать статус \`awg show\`"
    echo "  restart               Перезапустить сервис AmneziaWG"
    echo "  repair-module         Восстановить модуль ядра после kernel upgrade (alias: repair)"
    echo "                        (dkms autoinstall + modprobe + запуск awg-quick)"
    echo "  help                  Показать эту справку"
    echo ""
    exit "$_rc"
}

# ==============================================================================
# Основная логика
# ==============================================================================

if [[ -z "$COMMAND" ]]; then
    usage 1
fi
if [[ "$COMMAND" == "help" ]]; then
    usage "$HELP_EXIT_RC"
fi

check_dependencies || exit 1
cd "$AWG_DIR" || die "Ошибка перехода в $AWG_DIR"

log "Запуск команды '$COMMAND'..."
_cmd_rc=0

case $COMMAND in
    add)
        [[ ${#ARGS[@]} -eq 0 ]] && die "Не указано имя клиента."

        # Гарантируем, что модуль ядра amneziawg загружен и awg-quick@awg0 активен.
        # Без этого apply_config (awg syncconf) упадёт. См. также 'manage repair-module'.
        # AWG_SKIP_APPLY=1 (offline/batch edit без apply): пропускаем проверку модуля —
        # apply_config сам сделает no-op, и команда должна работать на dev-машине.
        if [[ "${AWG_SKIP_APPLY:-0}" != "1" ]]; then
            ensure_amneziawg_kernel_module \
                || die "Модуль ядра amneziawg недоступен. Запустите 'manage repair-module' и повторите."
        fi

        # --psk: включить опциональный PresharedKey для каждого нового клиента.
        # Export CLIENT_PSK="auto" → generate_client сам сгенерирует 32-байт
        # PSK через `awg genpsk` для каждого client'а в batch (разный PSK
        # на каждого).
        if [[ "${CLI_ADD_PSK:-0}" == "1" ]]; then
            export CLIENT_PSK="auto"
            log "PresharedKey будет сгенерирован для каждого нового клиента (--psk)."
        fi

        # --expires валидируем ОДИН раз ДО создания первого клиента. Иначе при
        # неверном формате (--expires=bad) клиенты создавались permanent, а
        # set_client_expiry молча падал per-client - временный клиент незаметно
        # становился постоянным. Плохой формат теперь рушит команду до изменений.
        if [[ -n "$EXPIRES_DURATION" ]]; then
            parse_duration "$EXPIRES_DURATION" >/dev/null \
                || die "Некорректный --expires='$EXPIRES_DURATION'. Используйте: 1h, 12h, 1d, 7d, 30d, 4w."
        fi

        _added=0
        for _cname in "${ARGS[@]}"; do
            validate_client_name "$_cname" || { _cmd_rc=1; continue; }

            if grep -qxF "#_Name = ${_cname}" "$SERVER_CONF_FILE"; then
                log_warn "Клиент '$_cname' уже существует, пропуск."
                continue
            fi

            # В batch-режиме каждому клиенту — свой PSK: сбрасываем на "auto"
            # чтобы generate_client сгенерировал новый.
            if [[ "${CLI_ADD_PSK:-0}" == "1" ]]; then
                export CLIENT_PSK="auto"
            fi

            log "Добавление '$_cname'..."
            if generate_client "$_cname"; then
                log "Клиент '$_cname' добавлен."
                # .png упоминаем только если QR реально создан (qrencode может
                # отсутствовать) - симметрично проверке .vpnuri ниже.
                if [[ -f "$AWG_DIR/${_cname}.png" ]]; then
                    log "Файлы: $AWG_DIR/${_cname}.conf, $AWG_DIR/${_cname}.png"
                else
                    log "Файлы: $AWG_DIR/${_cname}.conf"
                fi
                if [[ -f "$AWG_DIR/${_cname}.vpnuri" ]]; then
                    log "vpn:// URI: $AWG_DIR/${_cname}.vpnuri"
                fi
                if [[ -n "$EXPIRES_DURATION" ]]; then
                    if set_client_expiry "$_cname" "$EXPIRES_DURATION"; then
                        install_expiry_cron || { log_error "Клиент '$_cname' создан со сроком, но cron автоудаления НЕ установлен - истёкший клиент сам не удалится."; _cmd_rc=1; }
                    else
                        # Формат проверен выше, значит сбой записи expiry (FS/права).
                        # Клиент создан и рабочий, но БЕЗ авто-срока - сигналим явно,
                        # чтобы временный клиент не остался незаметно постоянным.
                        log_error "Клиент '$_cname' создан, но срок действия НЕ установлен (ошибка записи expiry). Клиент постоянный - задайте срок повторно или удалите."
                        _cmd_rc=1
                    fi
                fi
                ((_added++))
            else
                log_error "Ошибка добавления клиента '$_cname'."
                _cmd_rc=1
            fi
        done

        if [[ $_added -gt 0 ]]; then
            if [[ "${AWG_SKIP_APPLY:-0}" == "1" ]]; then
                # apply_config сам залогирует и вернёт 0
                apply_config
                log "Добавлено клиентов: $_added. Применение отложено (AWG_SKIP_APPLY=1)."
            elif apply_config; then
                log "Добавлено клиентов: $_added. Конфигурация применена."
            else
                log_error "Добавлено клиентов: $_added, но apply_config упал. Конфиг записан, но НЕ применён к live интерфейсу. Проверьте: systemctl status awg-quick@awg0"
                _cmd_rc=1
            fi
        fi
        # Hygiene: CLIENT_PSK не должен протекать в будущие операции
        unset CLIENT_PSK
        ;;

    remove)
        [[ ${#ARGS[@]} -eq 0 ]] && die "Не указано имя клиента."

        # Валидация всех имён перед удалением
        _valid_names=()
        for _rname in "${ARGS[@]}"; do
            validate_client_name "$_rname" || { _cmd_rc=1; continue; }
            if ! grep -qxF "#_Name = ${_rname}" "$SERVER_CONF_FILE"; then
                log_warn "Клиент '$_rname' не найден, пропуск."
                continue
            fi
            _valid_names+=("$_rname")
        done

        if [[ ${#_valid_names[@]} -eq 0 ]]; then
            log_error "Нет клиентов для удаления."
            _cmd_rc=1
        else
            # Подтверждение
            if [[ ${#_valid_names[@]} -eq 1 ]]; then
                if ! confirm_action "удалить" "клиента '${_valid_names[0]}'"; then exit 1; fi
            else
                if ! confirm_action "удалить" "${#_valid_names[@]} клиентов"; then exit 1; fi
            fi

            # Гарантируем загруженный модуль до любых мутаций (apply_config / awg syncconf).
            # AWG_SKIP_APPLY=1 (offline/batch edit без apply): пропускаем проверку модуля —
            # apply_config сам сделает no-op, и команда должна работать на dev-машине.
            if [[ "${AWG_SKIP_APPLY:-0}" != "1" ]]; then
                ensure_amneziawg_kernel_module \
                    || die "Модуль ядра amneziawg недоступен. Запустите 'manage repair-module' и повторите."
            fi

            _removed=0
            for _rname in "${_valid_names[@]}"; do
                log "Удаление '$_rname'..."
                if remove_peer_from_server "$_rname"; then
                    _remove_client_files "$_rname"
                    remove_client_expiry "$_rname"
                    log "Клиент '$_rname' удалён."
                    ((_removed++))
                else
                    log_error "Ошибка удаления '$_rname'."
                    _cmd_rc=1
                fi
            done

            if [[ $_removed -gt 0 ]]; then
                if [[ "${AWG_SKIP_APPLY:-0}" == "1" ]]; then
                    apply_config
                    log "Удалено клиентов: $_removed. Применение отложено (AWG_SKIP_APPLY=1)."
                elif apply_config; then
                    log "Удалено клиентов: $_removed. Конфигурация применена."
                else
                    log_error "Удалено клиентов: $_removed, но apply_config упал. Peer-ы убраны из конфига, но могут оставаться на live интерфейсе. Проверьте: systemctl status awg-quick@awg0"
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
        log "Перегенерация файлов конфигурации и QR..."
        # --reset-routes (Issue #170): передаём флаг в regenerate_client через
        # ENV - обычный regen сохраняет индивидуальные AllowedIPs клиентов, с
        # флагом ставит всем глобальный режим из awgsetup_cfg.init.
        if [[ "${CLI_RESET_ROUTES:-0}" == "1" ]]; then
            export AWG_REGEN_RESET_ROUTES=1
            log "AllowedIPs всех перегенерируемых клиентов будут сброшены на глобальный режим (--reset-routes)."
        fi
        if [[ ${#ARGS[@]} -eq 0 ]]; then
            # Без аргументов — все клиенты (сохраняет прежнее поведение).
            all_clients=$(grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //')
            if [[ -z "$all_clients" ]]; then
                log "Клиенты не найдены."
            else
                while IFS= read -r cname; do
                    cname="${cname## }"; cname="${cname%% }"
                    [[ -z "$cname" ]] && continue
                    log "Перегенерация '$cname'..."
                    regenerate_client "$cname" || { log_warn "Ошибка перегенерации '$cname'"; _cmd_rc=1; }
                done <<< "$all_clients"
                log "Перегенерация завершена."
            fi
        else
            # С аргументами — обрабатываем каждое имя отдельно (паритет с add/remove).
            # До v5.11.5 здесь читался только $CLIENT_NAME (=ARGS[0]), остальные имена
            # молча терялись (Issue #70).
            _regen_count=0
            for _cname in "${ARGS[@]}"; do
                validate_client_name "$_cname" || { _cmd_rc=1; continue; }
                if ! grep -qxF "#_Name = ${_cname}" "$SERVER_CONF_FILE"; then
                    log_warn "Клиент '$_cname' не найден, пропуск."
                    _cmd_rc=1
                    continue
                fi
                log "Перегенерация '$_cname'..."
                if regenerate_client "$_cname"; then
                    _regen_count=$((_regen_count + 1))
                else
                    log_error "Ошибка перегенерации '$_cname'."
                    _cmd_rc=1
                fi
            done
            if [[ $_regen_count -gt 0 ]]; then
                log "Перегенерация завершена. Обработано: $_regen_count из ${#ARGS[@]}."
            fi
        fi
        ;;

    modify)
        [[ -z "$CLIENT_NAME" ]] && die "Не указано имя клиента."
        validate_client_name "$CLIENT_NAME" || exit 1
        modify_client "$CLIENT_NAME" "$PARAM" "$VALUE" || _cmd_rc=1
        ;;

    backup)
        backup_configs || _cmd_rc=1
        ;;

    restore)
        restore_backup "$CLIENT_NAME" || _cmd_rc=1 # CLIENT_NAME используется как [файл]
        ;;

    check|status)
        check_server || _cmd_rc=1
        ;;

    show)
        log "Статус AmneziaWG 2.0..."
        if ! awg show; then log_error "Ошибка awg show."; _cmd_rc=1; fi
        ;;

    restart)
        log "Перезапуск сервиса..."
        if ! confirm_action "перезапустить" "сервис"; then exit 1; fi
        # Перед systemctl restart убеждаемся, что модуль ядра загружен (mode=module-only,
        # т.к. сам systemctl ниже стартует unit явно — повторный start от ensure избыточен).
        ensure_amneziawg_kernel_module module-only \
            || die "Модуль ядра amneziawg недоступен. Запустите 'manage repair-module' и повторите."
        if ! systemctl restart awg-quick@awg0; then
            log_error "Ошибка перезапуска."
            status_out=$(systemctl status awg-quick@awg0 --no-pager 2>&1) || true
            while IFS= read -r line; do log_error "  $line"; done <<< "$status_out"
            exit 1
        else
            log "Сервис перезапущен."
        fi
        ;;

    repair-module|repair)
        # Явная пользовательская команда: после kernel upgrade модуль может
        # требовать пересборки DKMS. Здесь разрешаем apt-установку headers
        # (AWG_ALLOW_APT_IN_ENSURE=1) — пользователь явно запросил восстановление.
        log "Восстановление модуля ядра amneziawg (может занять до 5 минут — DKMS rebuild)..."
        if AWG_ALLOW_APT_IN_ENSURE=1 ensure_amneziawg_kernel_module full; then
            log "Модуль ядра amneziawg восстановлен, сервис awg-quick@awg0 активен."
        else
            log_error "Не удалось восстановить модуль ядра. См. лог выше; при необходимости выполните ручное восстановление."
            _cmd_rc=1
        fi
        ;;

    diagnose)
        diagnose_server || _cmd_rc=1
        ;;

    # Ветки help) здесь нет намеренно: все пути, выставляющие COMMAND="help"
    # (-h/--help, неизвестная опция, позиционный help), перехватываются ДО
    # диспетчера ранним `usage` (он завершает процесс через exit).

    *)
        log_error "Неизвестная команда: '$COMMAND'"
        _cmd_rc=1
        usage
        ;;
esac

log "Скрипт управления завершил работу."
exit $_cmd_rc
