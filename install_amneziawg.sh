#!/bin/bash

# Проверка минимальной версии Bash
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "ОШИБКА: Требуется Bash >= 4.0 (текущая: ${BASH_VERSION})" >&2; exit 1
fi

# ==============================================================================
# Скрипт для установки и настройки AmneziaWG 2.0 на Ubuntu/Debian серверах
# Автор: @bivlked
# Версия: 5.11.3
# Дата: 2026-04-28
# Репозиторий: https://github.com/bivlked/amneziawg-installer
# ==============================================================================

# --- Безопасный режим и Константы ---
set -o pipefail

SCRIPT_VERSION="5.11.3"
AWG_DIR="/root/awg"
CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init"
STATE_FILE="$AWG_DIR/setup_state"
LOG_FILE="$AWG_DIR/install_amneziawg.log"
KEYS_DIR="$AWG_DIR/keys"
SERVER_CONF_FILE="/etc/amnezia/amneziawg/awg0.conf"
AWG_BRANCH="${AWG_BRANCH:-v${SCRIPT_VERSION}}"
COMMON_SCRIPT_URL="https://raw.githubusercontent.com/bivlked/amneziawg-installer/${AWG_BRANCH}/awg_common.sh"
COMMON_SCRIPT_PATH="$AWG_DIR/awg_common.sh"
MANAGE_SCRIPT_URL="https://raw.githubusercontent.com/bivlked/amneziawg-installer/${AWG_BRANCH}/manage_amneziawg.sh"
MANAGE_SCRIPT_PATH="$AWG_DIR/manage_amneziawg.sh"

# SHA256 checksums скачиваемых скриптов. Обновляются при каждом релизе.
# Проверяются в step5_download_scripts() после curl.
# Если AWG_BRANCH переопределён (не v$SCRIPT_VERSION), проверка пропускается.
# Формат: sha256sum output (hex, 64 chars).
COMMON_SCRIPT_SHA256="669fe3142302a30efcae930c33f553f0813cbda6e657e2d5e77690b8b7dcebfc"
MANAGE_SCRIPT_SHA256="387d7999b81de8ae3df988adef7e8103aaa6d6a6c7a578674ba078bff62cbf18"

# Флаги CLI
UNINSTALL=0; HELP=0; DIAGNOSTIC=0; VERBOSE=0; NO_COLOR=0; AUTO_YES=0; NO_TWEAKS=0
_APT_UPDATED=0
CLI_PORT=""; CLI_SUBNET=""; CLI_DISABLE_IPV6="default"
CLI_ROUTING_MODE="default"; CLI_CUSTOM_ROUTES=""; CLI_ENDPOINT=""; CLI_NO_TWEAKS=0

# --- Автоочистка временных файлов ---
_install_temp_files=()
_install_cleanup() {
    local f
    for f in "${_install_temp_files[@]}"; do [[ -f "$f" ]] && rm -f "$f"; done
    # Очистка временных файлов из awg_common.sh (если уже подключён через source)
    type _awg_cleanup &>/dev/null && _awg_cleanup
}
trap _install_cleanup EXIT INT TERM

# --- Обработка аргументов ---
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
        *) echo "Неизвестный аргумент: $1"; HELP=1 ;;
    esac
    shift
done

# ==============================================================================
# Функции логирования
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
        echo "[$ts] ERROR: Ошибка записи лога $LOG_FILE" >&2
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
die()       { log_error "КРИТИЧЕСКАЯ ОШИБКА: $1"; log_error "Установка прервана. Лог: $LOG_FILE"; exit 1; }

# ==============================================================================
# apt-get update wrapper, игнорирующий 404 только на source packages (deb-src).
# INLINE: нужна в шагах 1-2 до скачивания awg_common.sh (Step 5).
# Некоторые зеркала (Hetzner, AWS) не раздают source, но дефолтный ubuntu.sources
# содержит 'Types: deb deb-src'. Source не нужен (DKMS + бинарные headers).
# Возвращает 0 если update прошёл ИЛИ если все ошибки — только на source-маркерах.
# Любая другая ошибка (GPG, сетевая на binary, silent crash/OOM/SIGKILL) → non-zero.
# ==============================================================================
apt_update_tolerant() {
    local err_output rc non_src_errors
    err_output=$(LANG=C LC_ALL=C apt-get update -y 2>&1)
    rc=$?
    echo "$err_output"

    if [[ $rc -eq 0 ]]; then
        return 0
    fi

    # Фильтруем строки ошибок. Игнорируем:
    #   1. Строки про source-пакеты (deb-src / /source/ / Sources)
    #   2. Generic 'Some index files failed to download' — симптом, не причина
    non_src_errors=$(printf '%s\n' "$err_output" \
        | grep -E '^(E:|Err:|W:)' \
        | grep -vE '(deb-src|/source/|Sources([^[:alpha:]]|$))' \
        | grep -vE 'Some index files failed to download' || true)

    if [[ -z "$non_src_errors" ]]; then
        # Граничный случай: rc != 0, но ни одной классифицируемой строки E:/Err:/W:
        # не найдено (SIGKILL от OOM, silent crash, неизвестный формат вывода apt).
        # Игнорировать можно ТОЛЬКО если в выводе есть явные source-маркеры.
        if printf '%s\n' "$err_output" | grep -qE '(deb-src|/source/|Sources([^[:alpha:]]|$))'; then
            log_warn "apt update: source packages недоступны в зеркале (ожидаемо, игнорируется)"
            return 0
        fi
        log_error "apt update завершился с rc=$rc без классифицируемых APT-строк — возможен silent crash / OOM / SIGKILL"
        return "$rc"
    fi

    log_error "apt update завершился с non-source ошибками:"
    printf '%s\n' "$non_src_errors" | while IFS= read -r line; do
        log_error "  $line"
    done
    return "$rc"
}

# ==============================================================================
# Справка
# ==============================================================================

show_help() {
    cat << 'EOF'
Использование: sudo bash install_amneziawg.sh [ОПЦИИ]
Скрипт для установки и настройки AmneziaWG 2.0 на Ubuntu (24.04 / 25.10) и Debian (12 / 13).

Опции:
  -h, --help            Показать эту справку и выйти
  --uninstall           Удалить AmneziaWG и все его конфигурации
  --diagnostic          Создать диагностический отчет и выйти
  -v, --verbose         Расширенный вывод для отладки (включая DEBUG)
  --no-color            Отключить цветной вывод в терминале
  --port=НОМЕР          Установить UDP порт (1024-65535) неинтерактивно
  --subnet=ПОДСЕТЬ      Установить подсеть туннеля (x.x.x.x/yy) неинтерактивно
  --allow-ipv6          Оставить IPv6 включенным неинтерактивно
  --disallow-ipv6       Принудительно отключить IPv6 неинтерактивно
  --route-all           Использовать режим 'Весь трафик' неинтерактивно
  --route-amnezia       Использовать режим 'Amnezia' неинтерактивно
  --route-custom=СЕТИ   Использовать режим 'Пользовательский' неинтерактивно
  --endpoint=IP         Указать внешний IP сервера (для серверов за NAT)
  -y, --yes             Автоматическое подтверждение (перезагрузки, UFW и т.д.)
  --no-tweaks           Пропустить hardening/оптимизацию (без UFW, Fail2Ban, sysctl tweaks)
  --preset=ТИП          Набор параметров обфускации: default, mobile
                        mobile: Jc=3, узкий Jmax — для мобильных операторов (Tele2, Yota, Megafon)
  --jc=N               Задать Jc вручную (1-128, поверх preset)
  --jmin=N             Задать Jmin вручную (0-1280, поверх preset)
  --jmax=N             Задать Jmax вручную (0-1280, поверх preset, должно быть >= Jmin)

Примеры:
  sudo bash install_amneziawg.sh                             # Интерактивная установка
  sudo bash install_amneziawg.sh --port=51820 --route-all    # Неинтерактивная
  sudo bash install_amneziawg.sh --route-amnezia --yes       # Полностью автоматическая
  sudo bash install_amneziawg.sh --preset=mobile --yes       # Оптимизация для мобильных сетей
  sudo bash install_amneziawg.sh --uninstall                 # Удаление
  sudo bash install_amneziawg.sh --diagnostic                # Диагностика

Репозиторий: https://github.com/bivlked/amneziawg-installer
EOF
    exit 0
}

# ==============================================================================
# Утилиты и валидация
# ==============================================================================

update_state() {
    local next_step=$1
    mkdir -p "$(dirname "$STATE_FILE")"
    # Атомарная запись: tmp-файл + flock + mv. Защита от битого
    # состояния при crash/power-loss между write и close.
    (
        flock -x 200
        local tmp="${STATE_FILE}.tmp.$BASHPID"
        if printf '%s\n' "$next_step" > "$tmp" && mv -f "$tmp" "$STATE_FILE"; then
            exit 0
        fi
        rm -f "$tmp" 2>/dev/null
        exit 1
    ) 200>"${STATE_FILE}.lock" || die "Ошибка записи состояния"
    log "Состояние: следующий шаг - $next_step"
}

request_reboot() {
    local next_step=$1
    update_state "$next_step"

    # Перед reboot-gate 1→2 сохраняем boot_id. На входе step 2
    # сравниваем с текущим — если совпадает, reboot не произошёл
    # и DKMS соберёт модуль под старое ядро (которое после следующего
    # reboot будет уже apt full-upgrade'нутым и не подхватит модуль).
    if [[ "$next_step" == "2" ]] && [[ -r /proc/sys/kernel/random/boot_id ]]; then
        if cat /proc/sys/kernel/random/boot_id > "$AWG_DIR/.boot_id_before_step2" 2>/dev/null; then
            log_debug "boot_id captured before reboot"
        fi
    fi

    echo "" >> "$LOG_FILE"
    log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    log_warn "!!! ТРЕБУЕТСЯ ПЕРЕЗАГРУЗКА СИСТЕМЫ                        !!!"
    log_warn "!!! После перезагрузки, запустите скрипт снова командой:   !!!"
    log_warn "!!! sudo bash $0 [с теми же параметрами, если были]       !!!"
    log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "" >> "$LOG_FILE"
    local confirm="y"
    if [[ "$AUTO_YES" -eq 0 ]]; then
        read -rp "Перезагрузить сейчас? [y/N]: " confirm < /dev/tty
    else
        log "Автоматическое подтверждение перезагрузки (--yes)."
    fi
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log "Инициирована перезагрузка..."
        sleep 5
        if ! reboot; then die "Команда reboot не удалась."; fi
        exit 1
    else
        log "Перезагрузка отменена. Перезагрузитесь вручную и запустите скрипт снова."
        exit 1
    fi
}

check_os_version() {
    log "Проверка ОС..."

    # Определение через /etc/os-release (универсально для Ubuntu и Debian)
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
        log_warn "Не удалось определить ОС (/etc/os-release и lsb_release не найдены)."
        return 0
    fi
    export OS_ID OS_VERSION OS_CODENAME

    # Поддерживаемые ОС
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
        log "ОС: ${OS_ID^} $OS_VERSION ($OS_CODENAME) — поддерживается"
    else
        log_warn "Обнаружена $OS_ID $OS_VERSION ($OS_CODENAME). Скрипт протестирован на Ubuntu 24.04/25.10 и Debian 12/13."
        if [[ "$AUTO_YES" -eq 0 ]]; then
            read -rp "Продолжить? [y/N]: " confirm < /dev/tty
            if ! [[ "$confirm" =~ ^[Yy]$ ]]; then die "Отмена."; fi
        else
            log "Продолжаем на $OS_ID $OS_VERSION (--yes)."
        fi
    fi
}

check_free_space() {
    log "Проверка места..."
    local req=2048
    local avail
    avail=$(df -m / | awk 'NR==2 {print $4}')
    if [[ -z "$avail" ]]; then
        log_warn "Не удалось определить свободное место."
        return 0
    fi
    if [ "$avail" -lt "$req" ]; then
        log_warn "Доступно $avail МБ. Рекомендуется >= $req МБ."
        if [[ "$AUTO_YES" -eq 0 ]]; then
            read -rp "Продолжить? [y/N]: " confirm < /dev/tty
            if ! [[ "$confirm" =~ ^[Yy]$ ]]; then die "Отмена."; fi
        else
            log "Продолжаем с $avail МБ (--yes)."
        fi
    else
        log "Свободно: $avail МБ (OK)"
    fi
}

check_port_availability() {
    local port=$1
    log "Проверка порта $port..."
    local proc
    proc=$(ss -lunp | grep ":${port} ")
    if [[ -n "$proc" ]]; then
        log_error "Порт ${port}/udp уже используется! Процесс: $proc"
        return 1
    else
        log "Порт $port/udp свободен."
        return 0
    fi
}

install_packages() {
    local packages=("$@")
    local to_install=()
    local pkg
    log "Проверка пакетов: ${packages[*]}..."
    for pkg in "${packages[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
            to_install+=("$pkg")
        fi
    done
    if [ ${#to_install[@]} -eq 0 ]; then
        log "Все пакеты уже установлены."
        return 0
    fi
    log "Установка: ${to_install[*]}..."
    if [[ "${_APT_UPDATED:-0}" -eq 0 ]]; then
        apt_update_tolerant || log_warn "Не удалось обновить apt."
        _APT_UPDATED=1
    fi
    DEBIAN_FRONTEND=noninteractive apt install -y "${to_install[@]}" || die "Ошибка установки пакетов."
    log "Пакеты установлены."
}

cleanup_apt() {
    log "Очистка apt..."
    apt-get clean || log_warn "Ошибка apt-get clean"
    rm -rf /var/lib/apt/lists/* || log_warn "Ошибка rm /var/lib/apt/lists/*"
    log "Кэш apt очищен."
}

configure_ipv6() {
    if [[ "$CLI_DISABLE_IPV6" != "default" ]]; then
        DISABLE_IPV6=$CLI_DISABLE_IPV6
        log "IPv6 из CLI: $DISABLE_IPV6"
    elif [[ "$AUTO_YES" -eq 1 ]]; then
        DISABLE_IPV6=1
        log "IPv6 отключен (--yes, по умолчанию)."
    else
        read -rp "Отключить IPv6 (рекомендуется)? [Y/n]: " dis_ipv6 < /dev/tty
        if [[ "$dis_ipv6" =~ ^[Nn]$ ]]; then
            DISABLE_IPV6=0
        else
            DISABLE_IPV6=1
        fi
    fi
    export DISABLE_IPV6
    log "Отключение IPv6: $(if [ "$DISABLE_IPV6" -eq 1 ]; then echo 'Да'; else echo 'Нет'; fi)"
}

# Безопасная загрузка конфигурации (whitelist-парсер, без source/eval)
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

# Чтение одного ключа из конфига (для точечных запросов)
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
        die "Некорректный порт: '$port'. Допустимый диапазон: 1024-65535."
    fi
}

validate_subnet() {
    local subnet="$1"
    if ! [[ "$subnet" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/24$ ]] \
       || [[ "${BASH_REMATCH[1]}" -gt 255 ]] || [[ "${BASH_REMATCH[2]}" -gt 255 ]] \
       || [[ "${BASH_REMATCH[3]}" -gt 255 ]] || [[ "${BASH_REMATCH[4]}" -gt 255 ]]; then
        die "Некорректная подсеть: '$subnet'. Поддерживается только /24."
    fi
    if [[ "${BASH_REMATCH[4]}" -eq 0 ]] || [[ "${BASH_REMATCH[4]}" -eq 255 ]]; then
        die "Некорректная подсеть: '$subnet'. Последний октет не может быть 0 (сетевой адрес) или 255 (broadcast)."
    fi
    if [[ "${BASH_REMATCH[4]}" -ne 1 ]]; then
        die "Некорректная подсеть: '$subnet'. Последний октет должен быть 1 (адрес сервера в подсети)."
    fi
}

# Валидация endpoint (FQDN / IPv4 / [IPv6]).
# Возвращает 0 если endpoint безопасен и попадает под один из форматов,
# иначе 1 (caller сам решает die или log_warn + unset).
# Запрещает newline/CR/quotes/backslash чтобы предотвратить injection в
# awgsetup_cfg.init и client.conf через --endpoint флаг (audit).
validate_endpoint() {
    local ep="$1"
    [[ -n "$ep" ]] || return 1
    # Запрещаем символы которые могут сломать конфиг или внести injection
    [[ "$ep" != *$'\n'* && "$ep" != *$'\r'* && \
       "$ep" != *"'"* && "$ep" != *'"'* && "$ep" != *'\\'* && \
       "$ep" != *' '* && "$ep" != *$'\t'* ]] || return 1
    # Один из трёх форматов: FQDN, IPv4, [IPv6]
    [[ "$ep" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*|[0-9]{1,3}(\.[0-9]{1,3}){3}|\[[0-9A-Fa-f:]+\])$ ]] || return 1
    # Если IPv4 формат — дополнительно проверяем диапазон октетов 0-255
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
            if [ -z "$ALLOWED_IPS" ]; then die "Не указаны сети для --route-custom."; fi
        fi
        log "Режим маршрутизации из CLI: $ALLOWED_IPS_MODE"
    elif [[ "$AUTO_YES" -eq 1 ]]; then
        ALLOWED_IPS_MODE=2
        log "Режим маршрутизации: Amnezia+DNS (--yes, по умолчанию)."
    else
        echo ""
        log "Выберите режим маршрутизации (AllowedIPs клиента):"
        echo "  1) Весь трафик (0.0.0.0/0) - Макс. приватность, может блокировать LAN"
        echo "  2) Список Amnezia+DNS (умолч.) - Рекомендуется для обхода блокировок"
        echo "  3) Только указанные сети (Split Tunneling)"
        read -rp "Ваш выбор [2]: " r_mode < /dev/tty
        ALLOWED_IPS_MODE=${r_mode:-2}
    fi
    case "$ALLOWED_IPS_MODE" in
        1) ALLOWED_IPS="0.0.0.0/0"
           log "Выбран режим: Весь трафик." ;;
        3) if [[ -z "$CLI_CUSTOM_ROUTES" ]]; then
               read -rp "Введите сети (a.b.c.d/xx,...): " ALLOWED_IPS < /dev/tty
               while ! validate_cidr_list "$ALLOWED_IPS"; do
                   log_warn "Некорректный формат CIDR: '$ALLOWED_IPS'. Ожидается: x.x.x.x/y[,x.x.x.x/y]"
                   read -rp "Повторите ввод: " ALLOWED_IPS < /dev/tty
               done
           else
               ALLOWED_IPS=$CLI_CUSTOM_ROUTES
               if ! validate_cidr_list "$ALLOWED_IPS"; then
                   die "Некорректный формат CIDR: '$ALLOWED_IPS'. Ожидается: x.x.x.x/y[,x.x.x.x/y]"
               fi
           fi
           log "Выбран режим: Пользовательский ($ALLOWED_IPS)" ;;
        *) ALLOWED_IPS_MODE=2
           ALLOWED_IPS="0.0.0.0/5, 8.0.0.0/7, 11.0.0.0/8, 12.0.0.0/6, 16.0.0.0/4, 32.0.0.0/3, 64.0.0.0/2, 128.0.0.0/3, 160.0.0.0/5, 168.0.0.0/6, 172.0.0.0/12, 172.32.0.0/11, 172.64.0.0/10, 172.128.0.0/9, 173.0.0.0/8, 174.0.0.0/7, 176.0.0.0/4, 192.0.0.0/9, 192.128.0.0/11, 192.160.0.0/13, 192.169.0.0/16, 192.170.0.0/15, 192.172.0.0/14, 192.176.0.0/12, 192.192.0.0/10, 193.0.0.0/8, 194.0.0.0/7, 196.0.0.0/6, 200.0.0.0/5, 208.0.0.0/4, 8.8.8.8/32, 1.1.1.1/32"
           log "Выбран режим: Список Amnezia+DNS." ;;
    esac
    if [ -z "$ALLOWED_IPS" ]; then die "Не удалось определить AllowedIPs."; fi
    export ALLOWED_IPS_MODE ALLOWED_IPS
}

# ==============================================================================
# Генерация AWG 2.0 параметров (inline — нужны в шаге 0, до скачивания awg_common.sh)
# ==============================================================================

# Случайное число [min, max] через /dev/urandom (поддержка uint32)
rand_range() {
    local min=$1 max=$2
    local range=$((max - min + 1))
    local random_val
    random_val=$(od -An -tu4 -N4 /dev/urandom | tr -d ' ')
    if [[ -z "$random_val" || ! "$random_val" =~ ^[0-9]+$ ]]; then
        # Fallback: комбинация двух $RANDOM для 30-битного диапазона
        random_val=$(( (RANDOM << 15) | RANDOM ))
    fi
    echo $(( (random_val % range) + min ))
}

# Генерация 4 непересекающихся диапазонов для AWG H1-H4.
# Алгоритм: 8 случайных значений → sort → 4 пары (low, high).
# Сортировка гарантирует low ≤ high и непересечение между парами.
# Минимальная ширина каждого диапазона = 1000 (для нормальной обфускации).
# Печатает 4 строки формата "low-high" в stdout.
# Возвращает 1 если за 20 попыток не удалось получить корректные диапазоны.
#
# Диапазон: [0, 2^31-1] = [0, 2147483647]. Спецификация AmneziaWG допускает
# полный uint32 (0-4294967295), но standalone Windows-клиент
# `amneziawg-windows-client` имеет UI-валидатор ограниченный 2^31-1 в
# `ui/syntax/highlighter.go:isValidHField()` (upstream bug
# amnezia-vpn/amneziawg-windows-client#85, не исправлен). Значения выше
# 2^31-1 на сервере работают, но клиентский редактор подчёркивает их
# красным и не даёт сохранять правки. Для совместимости генерируем в
# безопасной половине диапазона (#40).
#
# Оптимизация: один вызов `od -N32 -tu4` читает 32 байта = 8 uint32 значений
# одной операцией, вместо 8 отдельных subprocess через rand_range.
# Fallback на rand_range если /dev/urandom недоступен.
generate_awg_h_ranges() {
    local attempt=0 max_attempts=20
    while (( attempt < max_attempts )); do
        local raw arr=() _v
        raw=$(od -An -N32 -tu4 /dev/urandom 2>/dev/null | tr -s ' \n' '\n' | sed '/^$/d')
        if [[ -n "$raw" ]]; then
            local count=0
            while IFS= read -r _v; do
                [[ "$_v" =~ ^[0-9]+$ ]] || continue
                # Маска 0x7FFFFFFF: очищает старший бит, значение в [0, 2^31-1]
                # без bias (каждый младший бит независим).
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

# Генерация CPS строки для I1
# Формат: "<r N>" где N — количество случайных байт (32-256)
generate_cps_i1() {
    local n
    n=$(rand_range 32 256)
    echo "<r ${n}>"
}

# Генерация всех AWG 2.0 параметров
# Поддерживает --preset=default|mobile и точечные --jc/--jmin/--jmax overrides
generate_awg_params() {
    local preset="${CLI_PRESET:-default}"
    log "Генерация параметров AWG 2.0 (preset: $preset)..."

    case "$preset" in
        default)
            # Jc 3-6: компромисс между обфускацией и совместимостью с мобильными (Discussion #38)
            AWG_Jc=$(rand_range 3 6)
            AWG_Jmin=$(rand_range 40 89)
            # Jmax = Jmin + 50..250 (~90-339 байт, Issue #42)
            AWG_Jmax=$(( AWG_Jmin + $(rand_range 50 250) ))
            ;;
        mobile)
            # Jc=3 фиксированный: alkorrnd (Tele2) — Jc=3 >95%, Jc=4 ~30%, Jc=5 <5%
            # Узкий Jmax: markmokrenko (Yota) — Jmax=70 работает, Jmax>300 блокируется
            AWG_Jc=3
            AWG_Jmin=$(rand_range 30 50)
            AWG_Jmax=$(( AWG_Jmin + $(rand_range 20 80) ))
            log "  Preset 'mobile': Jc=3, узкий Jmax для мобильных сетей"
            ;;
        *)
            die "Неизвестный preset: '$preset'. Допустимые: default, mobile"
            ;;
    esac

    # Точечные CLI overrides (поверх preset)
    if [[ -n "${CLI_JC:-}" ]]; then
        validate_jc_value "$CLI_JC" || die "Невалидный --jc=$CLI_JC (допустимо: 1-128)"
        AWG_Jc="$CLI_JC"
    fi
    if [[ -n "${CLI_JMIN:-}" ]]; then
        validate_junk_size "$CLI_JMIN" || die "Невалидный --jmin=$CLI_JMIN (допустимо: 0-1280)"
        AWG_Jmin="$CLI_JMIN"
    fi
    if [[ -n "${CLI_JMAX:-}" ]]; then
        validate_junk_size "$CLI_JMAX" || die "Невалидный --jmax=$CLI_JMAX (допустимо: 0-1280)"
        AWG_Jmax="$CLI_JMAX"
    fi

    # Sanity: Jmax >= Jmin
    if [[ "$AWG_Jmax" -lt "$AWG_Jmin" ]]; then
        die "Jmax ($AWG_Jmax) не может быть меньше Jmin ($AWG_Jmin)"
    fi

    AWG_PRESET="$preset"
    AWG_S1=$(rand_range 15 150)
    AWG_S2=$(rand_range 15 150)

    # Критическое ограничение из kernel: S1+56 != S2
    # Предотвращает одинаковый размер init и response сообщений
    while [[ $((AWG_S1 + 56)) -eq $AWG_S2 ]]; do
        AWG_S2=$(rand_range 15 150)
    done

    AWG_S3=$(rand_range 8 55)
    AWG_S4=$(rand_range 4 27)

    # H1-H4: 4 случайных непересекающихся uint32 диапазона.
    # Рандомизация на каждую установку защищает от ТСПУ-фингерпринта
    # по статическим H-значениям (Discussion #38, elvaleto/Klavishnik).
    # Алгоритм: 8 случайных uint32 → sort → 4 непересекающиеся пары.
    local _h_lines
    mapfile -t _h_lines < <(generate_awg_h_ranges) || true
    if [[ ${#_h_lines[@]} -ne 4 ]]; then
        die "Не удалось сгенерировать H1-H4 диапазоны."
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
    log "Параметры AWG 2.0 сгенерированы."
}

# ==============================================================================
# Системная оптимизация (новое в v5.0)
# ==============================================================================

# Определение характеристик железа
detect_hardware() {
    TOTAL_RAM_MB=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
    CPU_CORES=$(nproc)
    MAIN_NIC=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    log "Железо: RAM=${TOTAL_RAM_MB}MB, CPU=${CPU_CORES} ядер, NIC=${MAIN_NIC}"
}

# Удаление ненужных пакетов и сервисов
cleanup_system() {
    log "Очистка системы от ненужных компонентов..."

    # Пакеты для удаления (безопасные для VPS)
    # snapd и lxd-agent-loader — только на Ubuntu, на Debian их нет
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
        log "Удаление: ${packages_to_remove[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get purge -y "${packages_to_remove[@]}" || log_warn "Ошибка удаления некоторых пакетов"
    fi

    # Очистка snap артефактов (только Ubuntu)
    if [[ "${OS_ID:-ubuntu}" == "ubuntu" && -d /snap ]]; then
        log "Очистка snap артефактов..."
        rm -rf /snap /var/snap /var/lib/snapd 2>/dev/null || log_warn "Ошибка очистки snap"
    fi

    # cloud-init: удалять только если НЕ управляет сетью
    # Консервативный подход: сначала проверяем маркеры cloud-init, затем renderer
    if dpkg-query -W -f='${Status}' cloud-init 2>/dev/null | grep -q "ok installed"; then
        local cloud_manages_network=0
        # Проверяем маркеры cloud-init (приоритет — безопасность)
        if ls /etc/netplan/*cloud-init* &>/dev/null 2>&1; then
            cloud_manages_network=1
        elif grep -rq "cloud-init" /etc/netplan/ 2>/dev/null; then
            cloud_manages_network=1
        elif [[ -f /etc/network/interfaces ]] && grep -q "cloud-init" /etc/network/interfaces 2>/dev/null; then
            cloud_manages_network=1
        fi
        if [[ $cloud_manages_network -eq 0 ]]; then
            log "Удаление cloud-init (сеть не зависит от него)..."
            DEBIAN_FRONTEND=noninteractive apt-get purge -y cloud-init 2>/dev/null || log_warn "Ошибка удаления cloud-init"
            rm -rf /etc/cloud /var/lib/cloud 2>/dev/null
        else
            log_warn "cloud-init управляет сетью — пропускаем удаление."
        fi
    fi

    apt-get autoremove -y 2>/dev/null || log_warn "Ошибка autoremove"
    log "Очистка системы завершена."
}

# Настройка swap
optimize_swap() {
    log "Оптимизация swap..."
    local target_swap_mb

    if [[ $TOTAL_RAM_MB -le 2048 ]]; then
        target_swap_mb=1024
    else
        target_swap_mb=512
    fi

    # Проверяем текущий swap
    local current_swap_mb
    current_swap_mb=$(free -m | awk '/Swap:/ {print $2}')

    if [[ $current_swap_mb -ge $target_swap_mb ]]; then
        log "Swap уже достаточен: ${current_swap_mb}MB (цель: ${target_swap_mb}MB)"
    else
        log "Создание swap файла: ${target_swap_mb}MB"
        # Отключаем существующий swap файл если есть
        if [[ -f /swapfile ]]; then
            swapoff /swapfile 2>/dev/null
            rm -f /swapfile
        fi
        dd if=/dev/zero of=/swapfile bs=1M count="$target_swap_mb" status=none 2>/dev/null || {
            log_warn "Ошибка создания swap файла"
            return 1
        }
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1 || { log_warn "Ошибка mkswap"; return 1; }
        swapon /swapfile || { log_warn "Ошибка swapon"; return 1; }
        # Добавляем в fstab если отсутствует
        if ! grep -q '/swapfile' /etc/fstab; then
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
        log "Swap файл создан: ${target_swap_mb}MB"
    fi

    # Настройка swappiness
    sysctl -w vm.swappiness=10 >/dev/null 2>&1
}

# Оптимизация сетевого интерфейса
optimize_nic() {
    if [[ -z "$MAIN_NIC" ]]; then
        log_warn "Основной NIC не определён, пропуск оптимизации."
        return 1
    fi

    if ! command -v ethtool &>/dev/null; then
        log_debug "ethtool не найден, пропуск NIC оптимизации."
        return 0
    fi

    log "Оптимизация NIC: $MAIN_NIC"
    # Отключение GRO/GSO/TSO — могут мешать VPN-трафику
    ethtool -K "$MAIN_NIC" gro off 2>/dev/null || log_debug "GRO: не поддерживается/уже выкл."
    ethtool -K "$MAIN_NIC" gso off 2>/dev/null || log_debug "GSO: не поддерживается/уже выкл."
    ethtool -K "$MAIN_NIC" tso off 2>/dev/null || log_debug "TSO: не поддерживается/уже выкл."
    log "NIC оптимизация завершена."
}

# Полная оптимизация системы
optimize_system() {
    log "Оптимизация системы под VPN-сервер..."
    detect_hardware
    optimize_swap
    optimize_nic
    log "Оптимизация системы завершена."
}

# ==============================================================================
# Настройка sysctl (минимальная, для --no-tweaks)
# ==============================================================================

setup_minimal_sysctl() {
    log "Настройка минимального sysctl (--no-tweaks)..."
    local f="/etc/sysctl.d/99-amneziawg-forwarding.conf"
    cat > "$f" << SYSEOF
# AmneziaWG — минимальные настройки (--no-tweaks)
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
    sysctl -p "$f" >/dev/null 2>&1 || log_warn "Ошибка sysctl -p"
    log "Минимальный sysctl настроен."
}

# ==============================================================================
# Настройка sysctl (расширенная)
# ==============================================================================

setup_advanced_sysctl() {
    log "Настройка sysctl..."
    local f="/etc/sysctl.d/99-amneziawg-security.conf"

    # Адаптивные буферы по объёму RAM
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
# Автоматически сгенерировано install_amneziawg.sh v${SCRIPT_VERSION}

# --- IP Forwarding ---
net.ipv4.ip_forward = 1
$(if [[ "${DISABLE_IPV6:-1}" -eq 1 ]]; then
    echo "net.ipv6.conf.all.disable_ipv6 = 1"
    echo "net.ipv6.conf.default.disable_ipv6 = 1"
    echo "net.ipv6.conf.lo.disable_ipv6 = 1"
else
    echo "# IPv6 не отключен"
    echo "net.ipv6.conf.all.forwarding = 1"
fi)

# --- TCP/IP Hardening ---
# rp_filter = 2 (loose mode): проверяет source IP по ANY маршруту в таблице,
# а не по обратному маршруту через тот же интерфейс. Strict mode (=1) ломает
# routing на облачных хостерах (Hetzner и подобных) где шлюз в другой подсети,
# чем IP самой VPS — ответные пакеты не проходят strict reverse path check.
# Loose mode безопасен: подделанные source IP всё равно отсеиваются если для
# них нет маршрута вообще. Discussion #41 (z036).
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

# Подавление kernel warning/notice messages в VNC-консоли хостера.
# Без этого fail2ban UFW-блокировки спамят VNC окно строками типа
# "[UFW BLOCK]" и делают консоль непригодной для работы.
# Format: console_loglevel default_msg_loglevel min_console_loglevel default_console_loglevel
# Значение 3 = KERN_ERR — на консоль идут только ошибки и критические.
# Discussion #41 (z036).
kernel.printk = 3 4 1 3
EOF

    log "Применение sysctl..."
    if ! sysctl -p "$f" >/dev/null 2>&1; then
        # nf_conntrack может быть недоступен до загрузки модуля
        log_warn "Некоторые параметры sysctl не применились (nf_conntrack будет доступен позже)."
        sysctl -p "$f" 2>/dev/null || true
    fi
}

# ==============================================================================
# Фаервол и безопасность
# ==============================================================================

setup_improved_firewall() {
    log "Настройка UFW..."
    if ! command -v ufw &>/dev/null; then install_packages ufw; fi

    # Определяем основной сетевой интерфейс для правила маршрутизации
    local main_nic
    main_nic=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    if [[ -z "$main_nic" ]]; then
        log_warn "Не удалось определить сетевой интерфейс для UFW route."
    fi

    local ufw_errors=0
    if ufw status 2>/dev/null | grep -q inactive; then
        log "UFW неактивен. Настройка..."
        ufw default deny incoming  || { log_warn "UFW: ошибка default deny incoming"; ufw_errors=1; }
        ufw default allow outgoing || { log_warn "UFW: ошибка default allow outgoing"; ufw_errors=1; }
        ufw limit 22/tcp comment "SSH Rate Limit" || { log_warn "UFW: ошибка limit SSH"; ufw_errors=1; }
        ufw allow "${AWG_PORT}/udp" comment "AmneziaWG VPN" || { log_warn "UFW: ошибка allow VPN port"; ufw_errors=1; }
        if [[ -n "$main_nic" ]]; then
            ufw route allow in on awg0 out on "$main_nic" comment "AmneziaWG Routing" \
                || { log_warn "UFW: ошибка route rule"; ufw_errors=1; }
            log "Правило маршрутизации VPN добавлено (awg0 → ${main_nic})."
        fi
        if [[ "$ufw_errors" -ne 0 ]]; then
            log_error "Одна или несколько правил UFW не применились. Проверьте настройки вручную."
            return 1
        fi
        log "Правила UFW добавлены."
        log_warn "--- ВКЛЮЧЕНИЕ UFW ---"
        log_warn "Проверьте SSH доступ!"
        local confirm_ufw="y"
        if [[ "$AUTO_YES" -eq 0 ]]; then
            sleep 5
            read -rp "Включить UFW? [y/N]: " confirm_ufw < /dev/tty
        else
            log "Автоматическое включение UFW (--yes)."
        fi
        if ! [[ "$confirm_ufw" =~ ^[Yy]$ ]]; then
            log_warn "UFW не включен."
            return 1
        fi
        if ! ufw enable <<< "y"; then die "Ошибка включения UFW."; fi
        log "UFW включен."
        # Маркер: UFW был включён нашим установщиком (а не пользователем заранее).
        # Используется в step_uninstall чтобы решить, безопасно ли отключать UFW.
        # Защита от destructive uninstall на VPS где UFW использовался для SSH/web
        # hardening ДО установки нашего скрипта (audit).
        touch "$AWG_DIR/.ufw_enabled_by_installer" 2>/dev/null || \
            log_warn "Не удалось создать UFW marker — uninstall не сможет отключить UFW автоматически."
    else
        log "UFW активен. Обновление правил..."
        ufw limit 22/tcp comment "SSH Rate Limit" || { log_warn "UFW: ошибка limit SSH"; ufw_errors=1; }
        ufw allow "${AWG_PORT}/udp" comment "AmneziaWG VPN" || { log_warn "UFW: ошибка allow VPN port"; ufw_errors=1; }
        if [[ -n "$main_nic" ]]; then
            ufw route allow in on awg0 out on "$main_nic" comment "AmneziaWG Routing" \
                || { log_warn "UFW: ошибка route rule"; ufw_errors=1; }
        fi
        if [[ "$ufw_errors" -ne 0 ]]; then
            log_error "Одна или несколько правил UFW не применились. Проверьте настройки вручную."
            return 1
        fi
        ufw reload || log_warn "Ошибка перезагрузки UFW."
        log "Правила обновлены."
    fi
    log "UFW настроен."
    log "$(ufw status verbose 2>&1)"
    return 0
}

secure_files() {
    log "Установка безопасных прав доступа..."
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
    log "Права доступа установлены."
}

setup_fail2ban() {
    log "Настройка Fail2Ban..."
    if ! command -v fail2ban-client &>/dev/null; then install_packages fail2ban; fi
    if ! command -v fail2ban-client &>/dev/null; then
        log_warn "Fail2ban не установлен, пропускаем."
        return 1
    fi

    # Debian: journald вместо rsyslog, нужен python3-systemd
    if [[ "${OS_ID:-}" == "debian" ]]; then
        install_packages python3-systemd
    fi

    mkdir -p /etc/fail2ban/jail.d 2>/dev/null

    # Backend: systemd для Debian (нет rsyslog), auto для Ubuntu
    local f2b_backend="auto"
    if [[ "${OS_ID:-}" == "debian" ]]; then
        f2b_backend="systemd"
    fi

    cat > /etc/fail2ban/jail.d/amneziawg.conf << JAILEOF || { log_warn "Ошибка записи jail.d/amneziawg.conf"; return 1; }
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
        log "Fail2Ban настроен и перезапущен."
    else
        log_warn "Ошибка перезапуска fail2ban"
    fi
    return 0
}

# ==============================================================================
# Проверка статуса сервиса
# ==============================================================================

check_service_status() {
    log "Проверка статуса сервиса..."
    local ok=1

    if systemctl is-failed --quiet awg-quick@awg0; then
        log_error "Сервис FAILED!"
        ok=0
    fi

    if ! ip addr show awg0 &>/dev/null; then
        log_error "Интерфейс awg0 не найден!"
        ok=0
    fi

    if ! awg show 2>/dev/null | grep -q "interface: awg0"; then
        log_error "awg show не видит интерфейс!"
        ok=0
    fi

    # Проверка порта
    local port_check=${AWG_PORT:-0}
    if [[ "$port_check" -eq 0 ]] && [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        port_check=$(safe_read_config_key "AWG_PORT" "$CONFIG_FILE")
        port_check=${port_check:-0}
    fi
    if [[ "$port_check" -ne 0 ]]; then
        if ! ss -lunp | grep -q ":${port_check} "; then
            log_error "Порт $port_check/udp не прослушивается!"
            ok=0
        fi
    fi

    # Проверка AWG 2.0 параметров
    if awg show awg0 2>/dev/null | grep -q "jc:"; then
        log "AWG 2.0 параметры активны."
    else
        log_warn "AWG 2.0 параметры не обнаружены в awg show."
    fi

    if [[ "$ok" -eq 1 ]]; then
        log "Статус сервиса и интерфейса OK."
        return 0
    else
        return 1
    fi
}

# ==============================================================================
# Диагностика
# ==============================================================================

create_diagnostic_report() {
    log "Создание диагностики..."
    local rf
    rf="$AWG_DIR/diag_$(date +%F_%T).txt"
    {
        echo "=== AMNEZIAWG 2.0 DIAGNOSTIC REPORT ==="
        echo ""
        echo "!!! ВНИМАНИЕ: Отчёт содержит IP-адреса, порты и маршруты."
        echo "!!! Перед публикацией в issue проверьте и замените приватные данные."
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
        # Маскируем приватный ключ
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
    } > "$rf" || log_error "Ошибка записи отчета."
    chmod 600 "$rf" || log_warn "Ошибка chmod отчета."
    log "Отчет: $rf"
}

# ==============================================================================
# Деинсталляция
# ==============================================================================

step_uninstall() {
    log "### ДЕИНСТАЛЛЯЦИЯ AMNEZIAWG ###"
    echo ""
    echo "ВНИМАНИЕ! Полное удаление AmneziaWG и конфигураций."
    echo "Процесс необратим!"
    echo ""
    local confirm="" backup="Y"
    if [[ "$AUTO_YES" -eq 0 ]]; then
        read -rp "Уверены? (введите 'yes'): " confirm < /dev/tty
        if [[ "$confirm" != "yes" ]]; then log "Деинсталляция отменена."; exit 1; fi
        read -rp "Создать бэкап перед удалением? [Y/n]: " backup < /dev/tty
    else
        log "Автоматическое подтверждение деинсталляции (--yes)."
    fi
    if [[ -z "$backup" || "$backup" =~ ^[Yy]$ ]]; then
        local bf
        bf="$HOME/awg_uninstall_backup_$(date +%F_%H-%M-%S).tar.gz"
        log "Создание бэкапа: $bf"
        if tar -czf "$bf" -C / etc/amnezia "$AWG_DIR" --ignore-failed-read 2>/dev/null \
            && chmod 600 "$bf"; then
            log "Бэкап создан: $bf"
        else
            log_warn "Бэкап не удался — проверьте $bf вручную перед продолжением"
        fi
    fi
    # Загружаем флаг --no-tweaks из сохранённой конфигурации
    local saved_no_tweaks=0
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        saved_no_tweaks=$(safe_read_config_key "NO_TWEAKS" "$CONFIG_FILE" 2>/dev/null) || saved_no_tweaks=0
        saved_no_tweaks=${saved_no_tweaks:-0}
    fi
    log "Остановка сервиса..."
    systemctl stop awg-quick@awg0 2>/dev/null
    systemctl disable awg-quick@awg0 2>/dev/null
    modprobe -r amneziawg 2>/dev/null || true
    if [[ "$saved_no_tweaks" -eq 0 ]]; then
        log "Очистка правил UFW для AmneziaWG..."
        if command -v ufw &>/dev/null; then
            local port_to_del
            if [[ -f "$CONFIG_FILE" ]]; then
                # shellcheck source=/dev/null
                port_to_del=$(safe_read_config_key "AWG_PORT" "$CONFIG_FILE")
            fi
            port_to_del=${port_to_del:-39743}
            # Удаление наших правил выполняется ВСЕГДА (idempotent)
            ufw delete allow "${port_to_del}/udp" 2>/dev/null
            # Для удаления route-правила нужно точное совпадение с тем как оно
            # было создано: "ufw route allow in on awg0 out on <nic>". Без "out on"
            # UFW не найдёт правило и оно останется в ufw status. Discussion #41.
            local _nic
            _nic=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
            if [[ -n "$_nic" ]]; then
                ufw route delete allow in on awg0 out on "$_nic" 2>/dev/null
            fi
            # Fallback: попытка удалить без out on (для совместимости со старыми правилами)
            ufw route delete allow in on awg0 2>/dev/null

            # ufw disable выполняется ТОЛЬКО если UFW был включён нашим установщиком.
            # Защита от destructive uninstall на VPS где UFW использовался для
            # SSH/web hardening ДО установки нашего скрипта (audit).
            # Backwards compat: старые установки без маркера сохраняют UFW активным.
            if [[ -f "$AWG_DIR/.ufw_enabled_by_installer" ]]; then
                log "Отключение UFW (был включён нашим установщиком)..."
                ufw --force disable 2>/dev/null
                rm -f "$AWG_DIR/.ufw_enabled_by_installer"
            else
                log "UFW оставлен активным (использовался до установки или старая версия инсталлятора)."
            fi
        fi
        log "Снятие блокировок Fail2Ban..."
        if command -v fail2ban-client &>/dev/null; then
            fail2ban-client unban --all 2>/dev/null || true
            systemctl stop fail2ban 2>/dev/null
        fi
    else
        log "Пропуск UFW/Fail2Ban (установка с --no-tweaks)."
    fi
    log "Удаление пакетов..."
    if [[ "$saved_no_tweaks" -eq 0 ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y amneziawg-dkms amneziawg-tools fail2ban qrencode 2>/dev/null || log_warn "Ошибка purge."
    else
        DEBIAN_FRONTEND=noninteractive apt-get purge -y amneziawg-dkms amneziawg-tools qrencode 2>/dev/null || log_warn "Ошибка purge."
    fi
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>/dev/null || log_warn "Ошибка autoremove."
    log "Удаление PPA и файлов..."
    rm -f /etc/apt/sources.list.d/amnezia-ppa.sources \
        /etc/apt/sources.list.d/amnezia-ppa.list \
        /etc/apt/sources.list.d/amnezia-ubuntu-ppa-*.list \
        /etc/apt/sources.list.d/amnezia-ubuntu-ppa-*.sources \
        /etc/apt/keyrings/amnezia-ppa.gpg 2>/dev/null
    rm -rf /etc/amnezia \
        /etc/modules-load.d/amneziawg.conf \
        /etc/sysctl.d/99-amneziawg-security.conf \
        /etc/sysctl.d/99-amneziawg-forwarding.conf \
        /etc/logrotate.d/amneziawg* || log_warn "Ошибка удаления файлов."
    if [[ "$saved_no_tweaks" -eq 0 ]]; then
        # Удаляем только наш собственный jail-файл.
        # Раньше здесь была эвристика "если jail.local содержит banaction = ufw,
        # удалить весь файл" — слишком широкий фильтр, мог снести чужой
        # jail.local с custom jails. Эвристика убрана (audit).
        # Если у юзера остался jail.local от очень старых версий нашего
        # инсталлятора — пусть сам решает что с ним делать.
        rm -f /etc/fail2ban/jail.d/amneziawg.conf 2>/dev/null
    fi
    log "Удаление DKMS..."
    rm -rf /var/lib/dkms/amneziawg* || log_warn "Ошибка удаления DKMS."
    log "Восстановление sysctl..."
    if grep -q "disable_ipv6" /etc/sysctl.conf 2>/dev/null; then
        sed -i '/disable_ipv6/d' /etc/sysctl.conf || log_warn "Ошибка sed sysctl.conf"
    fi
    sysctl -p --system 2>/dev/null
    rm -f /etc/apt/sources.list.d/*.bak-* "$AWG_DIR"/ubuntu.sources.bak-* 2>/dev/null || true
    log "Удаление cron и скриптов..."
    rm -f /etc/cron.d/awg-expiry 2>/dev/null
    log "=== ДЕИНСТАЛЛЯЦИЯ ЗАВЕРШЕНА ==="
    # Копируем лог и удаляем рабочую директорию
    cp "$LOG_FILE" "$HOME/awg_uninstall.log" 2>/dev/null || true
    rm -rf "$AWG_DIR" 2>/dev/null || true
    exit 0
}

# ==============================================================================
# ШАГ 0: Инициализация
# ==============================================================================

initialize_setup() {
    if [ "$(id -u)" -ne 0 ]; then die "Запустите скрипт от root (sudo bash $0)."; fi

    mkdir -p "$AWG_DIR" || die "Ошибка создания $AWG_DIR"
    chown root:root "$AWG_DIR"

    # Process-wide lock: предотвращает запуск двух экземпляров install_amneziawg.sh
    # одновременно. Без него два concurrent запуска могли бы прочитать одинаковый
    # setup_state, конкурентно дёргать apt-get/dkms/ufw и сломать package state
    # (audit).
    # FD выбран фиксированным (9) и не конфликтует с update_state (использует 200).
    # Lock держится открытым весь lifetime процесса — release автоматически на exit.
    INSTALL_LOCK_FILE="$AWG_DIR/.install.lock"
    exec 9>"$INSTALL_LOCK_FILE" || die "Не могу открыть $INSTALL_LOCK_FILE"
    if ! flock -n 9; then
        die "Другой экземпляр install_amneziawg.sh уже запущен. Подождите завершения, либо если процесс висит — удалите $INSTALL_LOCK_FILE и попробуйте снова."
    fi

    touch "$LOG_FILE" || die "Не удалось создать лог-файл $LOG_FILE"
    chmod 640 "$LOG_FILE"
    log "--- НАЧАЛО УСТАНОВКИ AmneziaWG 2.0 (v${SCRIPT_VERSION}) ---"
    log "### ШАГ 0: Инициализация и проверка параметров ###"
    cd "$AWG_DIR" || die "Ошибка перехода в $AWG_DIR"
    log "Рабочая директория: $AWG_DIR"
    log "Лог файл: $LOG_FILE"

    check_os_version
    check_free_space

    local default_port=39743
    local default_subnet="10.9.9.1/24"
    local config_exists=0

    # Инициализация переменных
    AWG_PORT=$default_port
    AWG_TUNNEL_SUBNET=$default_subnet
    DISABLE_IPV6="default"
    ALLOWED_IPS_MODE="default"
    ALLOWED_IPS=""
    AWG_ENDPOINT=""

    # Загрузка конфига
    if [[ -f "$CONFIG_FILE" ]]; then
        log "Найден файл конфигурации $CONFIG_FILE. Загрузка настроек..."
        config_exists=1
        # shellcheck source=/dev/null
        safe_load_config "$CONFIG_FILE" || log_warn "Не удалось полностью загрузить настройки из $CONFIG_FILE."
        AWG_PORT=${AWG_PORT:-$default_port}
        AWG_TUNNEL_SUBNET=${AWG_TUNNEL_SUBNET:-$default_subnet}
        DISABLE_IPV6=${DISABLE_IPV6:-"default"}
        ALLOWED_IPS_MODE=${ALLOWED_IPS_MODE:-"default"}
        ALLOWED_IPS=${ALLOWED_IPS:-""}
        AWG_ENDPOINT=${AWG_ENDPOINT:-""}
        log "Настройки из файла загружены."
    else
        log "Файл конфигурации $CONFIG_FILE не найден."
    fi

    # Переопределение из CLI
    AWG_PORT=${CLI_PORT:-$AWG_PORT}
    AWG_TUNNEL_SUBNET=${CLI_SUBNET:-$AWG_TUNNEL_SUBNET}
    if [[ "$CLI_DISABLE_IPV6" != "default" ]]; then DISABLE_IPV6=$CLI_DISABLE_IPV6; fi
    if [[ "$CLI_ROUTING_MODE" != "default" ]]; then
        ALLOWED_IPS_MODE=$CLI_ROUTING_MODE
        if [[ "$CLI_ROUTING_MODE" -eq 3 ]]; then ALLOWED_IPS=$CLI_CUSTOM_ROUTES; fi
    fi
    if [[ -n "$CLI_ENDPOINT" ]]; then
        if ! validate_endpoint "$CLI_ENDPOINT"; then
            die "Некорректный --endpoint: '$CLI_ENDPOINT'. Допустимые форматы: FQDN (vpn.example.com), IPv4 (1.2.3.4), [IPv6] ([2001:db8::1]). Запрещены пробелы, табы, кавычки, обратный слеш и переводы строк."
        fi
        AWG_ENDPOINT=$CLI_ENDPOINT
    fi
    if [[ "$CLI_NO_TWEAKS" -eq 1 ]]; then NO_TWEAKS=1; fi

    # Валидация после CLI override
    validate_port "$AWG_PORT"
    validate_subnet "$AWG_TUNNEL_SUBNET"
    # AWG_ENDPOINT мог прийти из CONFIG_FILE через safe_load_config (без CLI override).
    # Если значение есть и не валидно — log_warn + сброс в "" чтобы инсталлятор
    # вернулся к auto-detect через get_server_public_ip (audit).
    if [[ -n "$AWG_ENDPOINT" ]] && ! validate_endpoint "$AWG_ENDPOINT"; then
        log_warn "AWG_ENDPOINT='$AWG_ENDPOINT' из $CONFIG_FILE не валиден, использую auto-detect."
        AWG_ENDPOINT=""
    fi

    # Запрос у пользователя только на первом запуске
    if [[ "$config_exists" -eq 0 ]]; then
        log "Запрос настроек у пользователя (первый запуск)."
        if [[ "$AUTO_YES" -eq 0 ]]; then
            read -rp "Введите UDP порт AmneziaWG (1024-65535) [${AWG_PORT}]: " input_port < /dev/tty
            if [[ -n "$input_port" ]]; then AWG_PORT=$input_port; fi
        fi
        validate_port "$AWG_PORT"
        if [[ "$AUTO_YES" -eq 0 ]]; then
            read -rp "Введите подсеть туннеля [${AWG_TUNNEL_SUBNET}]: " input_subnet < /dev/tty
            if [[ -n "$input_subnet" ]]; then AWG_TUNNEL_SUBNET=$input_subnet; fi
        fi
        validate_subnet "$AWG_TUNNEL_SUBNET"
        if [[ "$DISABLE_IPV6" == "default" ]]; then configure_ipv6; fi
        if [[ "$ALLOWED_IPS_MODE" == "default" ]]; then configure_routing_mode; fi
    else
        log "Используются настройки из $CONFIG_FILE."
        if [[ "$ALLOWED_IPS_MODE" == "3" ]] && [[ -n "$ALLOWED_IPS" ]]; then
            if ! validate_cidr_list "$ALLOWED_IPS"; then
                die "Некорректный ALLOWED_IPS в конфиге: '$ALLOWED_IPS'. Удалите $CONFIG_FILE и запустите установку заново."
            fi
        fi
    fi

    # Значения по умолчанию
    if [[ "$DISABLE_IPV6" == "default" ]]; then DISABLE_IPV6=1; fi
    if [[ "$ALLOWED_IPS_MODE" == "default" ]]; then ALLOWED_IPS_MODE=2; fi
    if [[ -z "$ALLOWED_IPS" ]]; then configure_routing_mode; fi

    # Проверка порта (пропускаем если AWG-сервис уже слушает этот порт)
    if ! systemctl is-active --quiet awg-quick@awg0 2>/dev/null; then
        check_port_availability "$AWG_PORT" || die "Порт $AWG_PORT/udp занят."
    else
        log "Сервис AWG активен — пропуск проверки порта."
    fi

    # Генерация AWG 2.0 параметров
    # Перегенерация если: первый запуск ИЛИ явный CLI override (--preset/--jc/--jmin/--jmax)
    if [[ -z "${AWG_Jc:-}" ]] || [[ -n "${CLI_PRESET:-}" ]] || [[ -n "${CLI_JC:-}" ]] \
        || [[ -n "${CLI_JMIN:-}" ]] || [[ -n "${CLI_JMAX:-}" ]]; then
        generate_awg_params
    else
        log "AWG 2.0 параметры уже заданы из конфига."
    fi

    # Сохранение конфигурации
    log "Сохранение настроек в $CONFIG_FILE..."
    local temp_conf
    temp_conf=$(mktemp) || die "Ошибка mktemp."
    _install_temp_files+=("$temp_conf")
    cat > "$temp_conf" << EOF
# Конфигурация установки AmneziaWG 2.0 (Авто-генерация)
# Используется скриптами установки и управления
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
        die "Ошибка сохранения $CONFIG_FILE"
    fi
    chmod 600 "$CONFIG_FILE" || log_warn "Ошибка chmod $CONFIG_FILE"
    log "Настройки сохранены."
    export AWG_PORT AWG_TUNNEL_SUBNET DISABLE_IPV6 ALLOWED_IPS_MODE ALLOWED_IPS AWG_ENDPOINT
    log "Порт: ${AWG_PORT}/udp"
    log "Подсеть: ${AWG_TUNNEL_SUBNET}"
    log "Откл. IPv6: $DISABLE_IPV6"
    log "Режим AllowedIPs: $ALLOWED_IPS_MODE"

    # Загрузка состояния
    if [[ -f "$STATE_FILE" ]]; then
        current_step=$(cat "$STATE_FILE")
        if ! [[ "$current_step" =~ ^[0-9]+$ ]]; then
            log_warn "$STATE_FILE поврежден."
            current_step=1
            update_state 1
        else
            log "Продолжение с шага $current_step."
        fi
    else
        current_step=1
        log "Начало с шага 1."
        update_state 1
    fi
    log "Шаг 0 завершен."
}

# ==============================================================================
# ШАГ 1: Обновление системы, очистка и оптимизация
# ==============================================================================

step1_update_and_optimize() {
    update_state 1
    log "### ШАГ 1: Обновление, очистка и оптимизация системы ###"

    # Очистка ненужных компонентов (ДО обновления для экономии трафика/времени)
    if [[ "$NO_TWEAKS" -eq 0 ]]; then
        cleanup_system
    else
        log "Пропуск очистки системы (--no-tweaks)."
    fi

    log "Обновление списка пакетов..."
    apt_update_tolerant || die "Ошибка apt update."

    log "Разблокировка dpkg..."
    if ! apt-get check &>/dev/null; then
        log_warn "dpkg заблокирован или повреждён, исправление..."
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a || log_warn "dpkg --configure -a."
    fi

    log "Обновление системы..."
    DEBIAN_FRONTEND=noninteractive apt full-upgrade -y || die "Ошибка apt full-upgrade."
    log "Система обновлена."

    install_packages curl wget gpg sudo ethtool

    if [[ "$NO_TWEAKS" -eq 0 ]]; then
        # Оптимизация системы
        optimize_system
        # Настройка sysctl
        setup_advanced_sysctl
    else
        log "Пропуск оптимизации и hardening (--no-tweaks)."
        setup_minimal_sysctl
    fi

    log "Шаг 1 успешно завершен."
    request_reboot 2
}

# ==============================================================================
# Поддержка предсобранных пакетов для ARM
# ==============================================================================

# _try_install_prebuilt_arm — скачать и установить предсобранный .deb для
# текущего ARM-ядра из релиза arm-packages на GitHub.
#
# Возвращает 0 при успехе, 1 если совпадений нет или установка не удалась
# (в этом случае вызывающий код переходит к DKMS).
_try_install_prebuilt_arm() {
    local kernel arch target_id asset_name asset_url tmpfile tmpsha expected_sha actual_sha
    kernel="$(uname -r)"
    arch="$(dpkg --print-architecture)"

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
        log "Предсобранный пакет для ядра $kernel ($arch) не найден"
        return 1
    fi

    asset_name="amneziawg-kmod-${target_id}_${kernel}_${arch}.deb"
    asset_url="https://github.com/bivlked/amneziawg-installer/releases/download/arm-packages/${asset_name}"

    log "Попытка установки предсобранного пакета: $asset_name"
    tmpfile="$(mktemp /tmp/amneziawg-prebuilt-XXXXXX.deb)"
    tmpsha="$(mktemp /tmp/amneziawg-prebuilt-XXXXXX.deb.sha256)"

    # Сначала скачиваем контрольную сумму SHA256
    if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 \
            -o "$tmpsha" "${asset_url}.sha256" 2>/dev/null; then
        log "Предсобранный пакет недоступен для $kernel — используется DKMS"
        rm -f "$tmpfile" "$tmpsha"
        return 1
    fi

    if curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 \
            -o "$tmpfile" "$asset_url" 2>/dev/null; then
        # Проверяем целостность перед установкой модуля ядра
        expected_sha="$(cat "$tmpsha")"
        actual_sha="$(sha256sum "$tmpfile" | awk '{print $1}')"
        rm -f "$tmpsha"
        if [[ "$expected_sha" != "$actual_sha" ]]; then
            log_warn "Несовпадение SHA256 предсобранного пакета — скачивание отклонено"
            rm -f "$tmpfile"
            return 1
        fi

        log "Пакет скачан (SHA256 OK), установка..."
        if dpkg -i "$tmpfile" 2>/dev/null; then
            rm -f "$tmpfile"
            log "Предсобранный пакет установлен: $asset_name"
            return 0
        else
            log_warn "Ошибка установки (несовпадение vermagic или повреждённый пакет)"
            rm -f "$tmpfile"
            return 1
        fi
    else
        log "Предсобранный пакет недоступен для $kernel — используется DKMS"
        rm -f "$tmpfile" "$tmpsha"
        return 1
    fi
}

# ==============================================================================
# ШАГ 2: Установка AmneziaWG и зависимостей
# ==============================================================================

step2_install_amnezia() {
    update_state 2

    # Guard: убедиться что юзер действительно перезагрузился перед step 2.
    # Если boot_id совпадает с сохранённым в request_reboot 2 — reboot
    # не произошёл (например, юзер случайно запустил скрипт повторно).
    # В этом случае apt full-upgrade из step 1 подложил новое ядро на диск,
    # но работающее ядро всё ещё старое → DKMS соберёт модуль под старое,
    # после следующего reboot modprobe упадёт.
    local boot_id_file="$AWG_DIR/.boot_id_before_step2"
    if [[ -f "$boot_id_file" ]] && [[ -r /proc/sys/kernel/random/boot_id ]]; then
        local saved_boot_id current_boot_id
        saved_boot_id=$(< "$boot_id_file")
        current_boot_id=$(< /proc/sys/kernel/random/boot_id)
        if [[ -n "$saved_boot_id" ]] && [[ "$saved_boot_id" == "$current_boot_id" ]]; then
            die "Ожидалась перезагрузка перед шагом 2 (kernel upgrade активируется только после reboot). Выполните: sudo reboot — и запустите скрипт снова."
        fi
        log "Подтверждена перезагрузка (boot_id изменился) — продолжаем шаг 2"
        rm -f "$boot_id_file" 2>/dev/null || true
    fi

    log "### ШАГ 2: Установка AmneziaWG и зависимостей ###"
    _APT_UPDATED=0  # Reset: new sources will be added in this step

    apt_update_tolerant || die "Ошибка apt update."

    # PPA Amnezia (без software-properties-common)
    log "Добавление PPA Amnezia..."

    # Определение codename для PPA
    # На Debian маппим на ближайший Ubuntu codename, т.к. PPA — это Launchpad (Ubuntu)
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
    # Проверка на legacy-файлы (от add-apt-repository предыдущих версий)
    local legacy_list="/etc/apt/sources.list.d/amnezia-ubuntu-ppa-${codename}.list"
    local legacy_sources="/etc/apt/sources.list.d/amnezia-ubuntu-ppa-${codename}.sources"
    if [[ -f "$legacy_list" ]] || [[ -f "$legacy_sources" ]]; then
        log "PPA уже добавлен (legacy-формат)."
    elif [[ -f "$ppa_sources" ]] || [[ -f "$ppa_list" ]]; then
        log "PPA уже добавлен."
    else
        mkdir -p "$keyring_dir"
        log "Импорт GPG ключа Amnezia PPA..."
        # Atomic: pipe в temp, затем mv — полу-записанный keyring никогда не
        # окажется на целевом пути, даже если curl/gpg упали mid-way.
        local _kf_tmp
        _kf_tmp=$(mktemp -p "$keyring_dir" ".amnezia-ppa.gpg.tmp.XXXXXX") \
            || die "Не удалось создать временный файл для GPG ключа."
        # --batch --no-tty --yes: gpg не открывает /dev/tty (non-interactive
        # SSH, cloud-init, Ansible и т.п.) и не падает с "File exists" при
        # overwrite mktemp-файла. Без этих флагов gpg в батч-режиме откажется
        # писать в уже существующий пустой tmp-файл от mktemp.
        if ! curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x57290828" \
             | gpg --batch --no-tty --yes --dearmor -o "$_kf_tmp"; then
            rm -f "$_kf_tmp" 2>/dev/null
            die "Ошибка импорта GPG ключа Amnezia PPA."
        fi
        chmod 644 "$_kf_tmp" || { rm -f "$_kf_tmp" 2>/dev/null; die "Ошибка chmod GPG ключа."; }
        mv -f "$_kf_tmp" "$keyring_file" \
            || { rm -f "$_kf_tmp" 2>/dev/null; die "Ошибка перемещения GPG ключа."; }

        # Debian 12 использует traditional .list формат, Debian 13+ и Ubuntu 24.04+ — DEB822 .sources
        if [[ "${OS_ID:-ubuntu}" == "debian" && "${OS_VERSION}" == "12" ]]; then
            log "Debian 12: используем традиционный формат .list"
            echo "deb [signed-by=${keyring_file}] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu ${ppa_codename} main" \
                > "$ppa_list" || die "Ошибка создания $ppa_list"
            chmod 644 "$ppa_list"
        else
            cat > "$ppa_sources" <<PPASRC || die "Ошибка создания sources PPA."
Types: deb
URIs: https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu
Suites: ${ppa_codename}
Components: main
Signed-By: ${keyring_file}
PPASRC
            chmod 644 "$ppa_sources"
        fi
        log "PPA добавлен."
    fi
    apt_update_tolerant || die "Ошибка apt update."

    # Пакеты AmneziaWG + qrencode (БЕЗ Python!)
    log "Установка пакетов AmneziaWG..."

    # На ARM: сначала пробуем предсобранный .deb (не требует build-tools и headers).
    # Откат на DKMS если совпадения нет или скачивание не удалось.
    local arch
    arch="$(uname -m)"
    if [[ "$arch" == "aarch64" || "$arch" == "armv7l" ]]; then
        if _try_install_prebuilt_arm; then
            log "Модуль ядра установлен из предсобранного пакета. Установка утилит из PPA..."
            install_packages "amneziawg-tools" "wireguard-tools" "qrencode"
            log "Шаг 2 завершен (prebuilt ARM)."
            request_reboot 3
            return
        fi
        log "Совпадений не найдено — откат на DKMS."
    fi

    local packages=("amneziawg-dkms" "amneziawg-tools" "wireguard-tools" "dkms"
                    "build-essential" "dpkg-dev" "qrencode")

    # Linux headers: на Debian может не быть точного linux-headers-$(uname -r)
    local current_headers
    current_headers="linux-headers-$(uname -r)"
    if dpkg -s "$current_headers" &>/dev/null || apt-cache show "$current_headers" &>/dev/null 2>&1; then
        packages+=("$current_headers")
    else
        log_warn "Нет headers для $(uname -r), установка общего пакета..."
        local kernel_release
        kernel_release="$(uname -r)"
        if [[ "$kernel_release" == *+rpt* || "$kernel_release" == *-rpi* ]]; then
            # Ядро Raspberry Pi Foundation (+rpt suffix) — использовать мета-пакет RPi
            # linux-headers-rpi-2712: Pi 5 / Cortex-A76; linux-headers-rpi-v8: Pi 3/4 arm64
            local rpi_headers
            if [[ "$kernel_release" == *2712* ]]; then
                rpi_headers="linux-headers-rpi-2712"
            else
                rpi_headers="linux-headers-rpi-v8"
            fi
            log "Обнаружено ядро Raspberry Pi, используем $rpi_headers"
            packages+=("$rpi_headers")
        elif [[ "${OS_ID:-ubuntu}" == "debian" ]]; then
            # На Debian: linux-headers-$(dpkg --print-architecture)
            local arch_pkg
            arch_pkg="linux-headers-$(dpkg --print-architecture 2>/dev/null || echo "amd64")"
            packages+=("$arch_pkg")
        else
            packages+=("linux-headers-generic")
        fi
    fi
    install_packages "${packages[@]}"

    # DKMS статус
    log "Проверка статуса DKMS..."
    local dkms_stat
    dkms_stat=$(dkms status 2>&1)
    if ! echo "$dkms_stat" | grep -q 'amneziawg.*installed'; then
        log_warn "DKMS статус не OK."
        log_msg "WARN" "$dkms_stat"
    else
        log "DKMS статус OK."
    fi

    log "Шаг 2 завершен."
    request_reboot 3
}

# ==============================================================================
# ШАГ 3: Проверка модуля ядра
# ==============================================================================

step3_check_module() {
    update_state 3
    log "### ШАГ 3: Проверка модуля ядра ###"
    sleep 2

    if ! lsmod | grep -q -w amneziawg; then
        log "Модуль не загружен. Загрузка..."
        modprobe amneziawg || die "Ошибка modprobe amneziawg."
        log "Модуль загружен."
        local mf="/etc/modules-load.d/amneziawg.conf"
        mkdir -p "$(dirname "$mf")"
        if ! grep -qxF 'amneziawg' "$mf" 2>/dev/null; then
            echo "amneziawg" > "$mf" || log_warn "Ошибка записи $mf"
            log "Добавлено в $mf."
        fi
    else
        log "Модуль amneziawg загружен."
    fi

    log "Информация о модуле:"
    modinfo amneziawg | grep -E "filename|version|vermagic|srcversion" | while IFS= read -r line; do
        log "  $line"
    done

    local cv kr
    cv=$(modinfo amneziawg 2>/dev/null | awk '/^vermagic:/{print $2}')
    if [[ -z "$cv" ]]; then
        die "Не удалось прочитать vermagic модуля amneziawg. Проверьте: modprobe amneziawg && modinfo amneziawg"
    fi
    kr=$(uname -r)
    if [[ "$cv" != "$kr" ]]; then
        log_warn "VerMagic НЕ совпадает: Модуль($cv) != Ядро($kr)!"
    else
        log "VerMagic совпадает."
    fi

    # Проверка версии awg
    if command -v awg &>/dev/null; then
        local awg_ver
        awg_ver=$(awg --version 2>/dev/null || echo "неизвестна")
        log "Версия awg: $awg_ver"
    else
        log_warn "Команда awg не найдена!"
    fi

    log "Шаг 3 завершен."
    update_state 4
}

# ==============================================================================
# ШАГ 4: Настройка фаервола
# ==============================================================================

step4_setup_firewall() {
    update_state 4
    if [[ "$NO_TWEAKS" -eq 0 ]]; then
        log "### ШАГ 4: Настройка фаервола UFW ###"
        install_packages ufw
        setup_improved_firewall || die "Ошибка настройки UFW."
        log "Шаг 4 завершен."
    else
        log "### ШАГ 4: Пропуск настройки UFW (--no-tweaks) ###"
    fi
    update_state 5
}

# ==============================================================================
# ШАГ 5: Скачивание скриптов (БЕЗ Python!)
# ==============================================================================

verify_sha256() {
    local file="$1" expected="$2" label="$3"
    # Пропускаем проверку если:
    # - SHA не установлен (RELEASE_PLACEHOLDER — ещё не выпущен release)
    # - AWG_BRANCH переопределён (тестовая ветка)
    if [[ "$expected" == "RELEASE_PLACEHOLDER" ]]; then
        log_debug "SHA256 для $label: пропуск (placeholder, до release)."
        return 0
    fi
    if [[ "${AWG_BRANCH}" != "v${SCRIPT_VERSION}" ]]; then
        log_warn "SHA256 для $label: проверка пропущена (AWG_BRANCH=${AWG_BRANCH} != v${SCRIPT_VERSION}). Файл не верифицирован."
        return 0
    fi
    local actual
    actual=$(sha256sum "$file" 2>/dev/null | awk '{print $1}')
    if [[ "$actual" != "$expected" ]]; then
        log_error "SHA256 $label НЕ совпадает!"
        log_error "  Ожидался: $expected"
        log_error "  Получен:  $actual"
        log_error "  Файл мог быть подменён. Скачайте installer заново с GitHub."
        return 1
    fi
    log_debug "SHA256 $label: OK ($actual)"
    return 0
}

# _secure_download <url> <target> <expected_sha256> <label>
# Atomic download:
#   1. curl → mktemp на том же FS, что и target;
#   2. verify_sha256 на temp (не на target, чтобы corrupt-файл не оказался
#      на целевом пути даже на долю секунды);
#   3. chmod 700 на temp;
#   4. mv -f temp → target (атомарный rename).
# Если любой шаг падает — temp удаляется, target не трогается.
_secure_download() {
    local url="$1" target="$2" expected_sha256="$3" label="$4"
    local tmp target_dir
    target_dir=$(dirname "$target")
    tmp=$(mktemp -p "$target_dir" ".${label//\//_}.tmp.XXXXXX") \
        || die "Не удалось создать временный файл для $label"
    if ! curl -fLso "$tmp" --max-time 60 --retry 2 "$url"; then
        rm -f "$tmp" 2>/dev/null
        die "Ошибка скачивания $label"
    fi
    if ! verify_sha256 "$tmp" "$expected_sha256" "$label"; then
        rm -f "$tmp" 2>/dev/null
        die "Целостность $label не подтверждена (SHA256 mismatch). Установка прервана."
    fi
    if ! chmod 700 "$tmp"; then
        rm -f "$tmp" 2>/dev/null
        die "Ошибка chmod $label"
    fi
    if ! mv -f "$tmp" "$target"; then
        rm -f "$tmp" 2>/dev/null
        die "Ошибка перемещения $label на целевой путь"
    fi
    log "$label скачан и верифицирован."
}

step5_download_scripts() {
    update_state 5
    log "### ШАГ 5: Скачивание скриптов управления ###"
    cd "$AWG_DIR" || die "Ошибка перехода в $AWG_DIR"

    log "Скачивание $COMMON_SCRIPT_PATH..."
    _secure_download "$COMMON_SCRIPT_URL" "$COMMON_SCRIPT_PATH" \
        "$COMMON_SCRIPT_SHA256" "awg_common.sh"

    log "Скачивание $MANAGE_SCRIPT_PATH..."
    _secure_download "$MANAGE_SCRIPT_URL" "$MANAGE_SCRIPT_PATH" \
        "$MANAGE_SCRIPT_SHA256" "manage_amneziawg.sh"

    log "Шаг 5 завершен."
    update_state 6
}

# ==============================================================================
# ШАГ 6: Генерация конфигураций (нативная, без awgcfg.py)
# ==============================================================================

step6_generate_configs() {
    update_state 6
    log "### ШАГ 6: Генерация конфигураций AWG 2.0 ###"
    cd "$AWG_DIR" || die "Ошибка cd $AWG_DIR"

    # Подключаем общую библиотеку
    if [[ ! -f "$COMMON_SCRIPT_PATH" ]]; then
        die "awg_common.sh не найден. Шаг 5 не выполнен?"
    fi
    # shellcheck source=/dev/null
    source "$COMMON_SCRIPT_PATH"

    # Создаём директорию для ключей
    mkdir -p "$KEYS_DIR" || die "Ошибка создания $KEYS_DIR"

    # Генерация серверных ключей (если ещё нет)
    if [[ ! -f "$AWG_DIR/server_private.key" ]]; then
        log "Генерация серверных ключей..."
        generate_server_keys || die "Ошибка генерации серверных ключей."
    else
        log "Серверные ключи уже существуют."
    fi

    # Бэкап существующего серверного конфига ДО перезаписи
    if [[ -f "$SERVER_CONF_FILE" ]]; then
        local s_bak
        s_bak="${SERVER_CONF_FILE}.bak-$(date +%F_%H%M%S)"
        cp "$SERVER_CONF_FILE" "$s_bak" || log_warn "Ошибка бэкапа $s_bak"
        log "Бэкап серверного конфига: $s_bak"
    fi

    # Создание серверного конфига AWG 2.0
    log "Создание серверного конфига..."
    render_server_config || die "Ошибка создания серверного конфига."

    # Восстановление существующих [Peer] блоков из бэкапа (кроме дефолтных)
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
            log "Существующие пиры восстановлены из бэкапа."
        fi
    fi

    # Генерация клиентов по умолчанию
    log "Создание клиентов по умолчанию..."
    local client_name
    for client_name in my_phone my_laptop; do
        if grep -qxF "#_Name = ${client_name}" "$SERVER_CONF_FILE" 2>/dev/null; then
            log "Клиент '$client_name' уже существует."
        else
            log "Создание клиента '$client_name'..."
            generate_client "$client_name" || log_warn "Ошибка создания клиента '$client_name'"
        fi
    done

    # Валидация конфига
    validate_awg_config || log_warn "Валидация конфига выявила проблемы."

    # Установка прав доступа
    secure_files

    log "Конфигурационные файлы в $AWG_DIR:"
    ls -la "$AWG_DIR"/*.conf "$AWG_DIR"/*.png 2>/dev/null | while IFS= read -r line; do
        log "  $line"
    done

    log "Шаг 6 завершен."
    update_state 7
}

# ==============================================================================
# ШАГ 7: Запуск сервиса
# ==============================================================================

step7_start_service() {
    update_state 7
    log "### ШАГ 7: Запуск сервиса и настройка безопасности ###"

    log "Включение и запуск awg-quick@awg0..."
    if systemctl is-active --quiet awg-quick@awg0; then
        log "Сервис уже активен — перезапуск для применения конфигурации..."
        systemctl enable awg-quick@awg0 || log_warn "Не удалось enable awg-quick@awg0 — проверьте автозапуск вручную"
        systemctl restart awg-quick@awg0 || die "Ошибка restart awg-quick@awg0."
    else
        systemctl enable --now awg-quick@awg0 || die "Ошибка enable --now."
    fi
    log "Сервис включен и запущен."

    log "Проверка статуса сервиса..."
    local _attempt
    for _attempt in 1 2 3 4 5; do
        sleep 1
        check_service_status 2>/dev/null && break
        [[ $_attempt -lt 5 ]] && log_debug "Ожидание запуска сервиса... (попытка $_attempt/5)"
    done
    check_service_status || die "Проверка статуса сервиса не пройдена."

    # Fail2Ban
    if [[ "$NO_TWEAKS" -eq 0 ]]; then
        setup_fail2ban
    else
        log "Пропуск Fail2Ban (--no-tweaks)."
    fi

    log "Шаг 7 успешно завершен."
    update_state 99
}

# ==============================================================================
# ШАГ 99: Завершение
# ==============================================================================

step99_finish() {
    log "### ЗАВЕРШЕНИЕ УСТАНОВКИ ###"
    log "=============================================================================="
    log "Установка и настройка AmneziaWG 2.0 УСПЕШНО ЗАВЕРШЕНА!"
    log " "
    log "КЛИЕНТСКИЕ ФАЙЛЫ:"
    log "  Конфиги (.conf) и QR-коды (.png) в: $AWG_DIR"
    log "  Скопируйте их безопасным способом."
    log "  Пример (на вашем ПК):"
    log "    scp root@<IP_СЕРВЕРА>:$AWG_DIR/*.conf ./"
    log " "
    log "ПОЛЕЗНЫЕ КОМАНДЫ:"
    log "  sudo bash $MANAGE_SCRIPT_PATH help   # Управление клиентами"
    log "  systemctl status awg-quick@awg0      # Статус VPN"
    log "  awg show                              # Статус AmneziaWG"
    log "  ufw status verbose                    # Статус Firewall"
    log " "
    log "ВАЖНО: Для подключения используйте клиент Amnezia VPN >= 4.8.12.7"
    log "       с поддержкой протокола AWG 2.0"
    log " "
    cleanup_apt
    log " "

    # Финальные проверки
    if [[ -f "$CONFIG_FILE" ]]; then
        log "Файл настроек $CONFIG_FILE: OK"
    else
        log_error "Файл настроек $CONFIG_FILE ОТСУТСТВУЕТ!"
    fi

    # Удаление файла состояния
    log "Удаление файла состояния установки..."
    rm -f "$STATE_FILE" "${STATE_FILE}.lock" "$AWG_DIR/.boot_id_before_step2" || log_warn "Не удалось удалить $STATE_FILE"
    log "Установка полностью завершена. Лог: $LOG_FILE"
    log "=============================================================================="
}

# ==============================================================================
# Основной цикл выполнения
# ==============================================================================

if [[ "$HELP" -eq 1 ]]; then show_help; fi
if [[ "$UNINSTALL" -eq 1 ]]; then step_uninstall; fi
if [[ "$DIAGNOSTIC" -eq 1 ]]; then create_diagnostic_report; exit 0; fi
if [[ "$VERBOSE" -eq 1 ]]; then set -x; fi

initialize_setup

while (( current_step < 99 )); do
    log "Выполнение шага $current_step..."
    case $current_step in
        1) step1_update_and_optimize ;;
        2) step2_install_amnezia ;;
        3) step3_check_module; current_step=4 ;;
        4) step4_setup_firewall; current_step=5 ;;
        5) step5_download_scripts; current_step=6 ;;
        6) step6_generate_configs; current_step=7 ;;
        7) step7_start_service; current_step=99 ;;
        *) die "Ошибка: Неизвестный шаг $current_step." ;;
    esac
done

if (( current_step == 99 )); then step99_finish; fi
exit 0
