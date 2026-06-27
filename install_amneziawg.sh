#!/bin/bash

# Проверка минимальной версии Bash
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "ОШИБКА: Требуется Bash >= 4.0 (текущая: ${BASH_VERSION})" >&2; exit 1
fi

# ==============================================================================
# Скрипт для установки и настройки AmneziaWG 2.0 на Ubuntu/Debian серверах
# Автор: @bivlked
# Версия: 5.18.1
# Дата: 2026-06-27
# Репозиторий: https://github.com/bivlked/amneziawg-installer
# ==============================================================================

# --- Безопасный режим и Константы ---
set -o pipefail

SCRIPT_VERSION="5.18.1"
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
COMMON_SCRIPT_SHA256="140bbb323ec490ba5b7f49b81ed3d9a27195d123ac3a9ad761994b2b050419f2"
MANAGE_SCRIPT_SHA256="4c8cdec3b7a5a32fb9873f2d1ae64d8b56edd1c53165c85921ec861ba01de632"

# Флаги CLI
UNINSTALL=0; HELP=0; HELP_EXIT_RC=0; DIAGNOSTIC=0; VERBOSE=0; NO_COLOR=0; AUTO_YES=0; NO_TWEAKS=0
FORCE_REINSTALL=0
_APT_UPDATED=0
CLI_PORT=""; CLI_SUBNET=""; CLI_DISABLE_IPV6="default"; CLI_SSH_PORT=""
CLI_ROUTING_MODE="default"; CLI_CUSTOM_ROUTES=""; CLI_ENDPOINT=""; CLI_NO_TWEAKS=0
CLI_ALLOW_IPV6_TUNNEL=0

# --- Автоочистка временных файлов ---
_install_temp_files=()
_install_cleaned=0
_install_cleanup() {
    # Идемпотентно: на INT/TERM зовётся из сигнального обработчика, затем ещё раз
    # на EXIT - второй вызов должен быть no-op.
    [[ "$_install_cleaned" -eq 1 ]] && return 0
    _install_cleaned=1
    local f
    for f in "${_install_temp_files[@]}"; do [[ -f "$f" ]] && rm -f "$f"; done
    # Очистка временных файлов из awg_common.sh (если уже подключён через source)
    type _awg_cleanup &>/dev/null && _awg_cleanup
}
# На INT/TERM раньше cleanup срабатывал, но скрипт НЕ завершался - выполнение
# продолжалось после прерванной команды (опасно посреди apt/dpkg/правки конфигов),
# и cleanup ещё раз шёл на EXIT. Теперь сигнал = cleanup + явный выход 130/143.
_install_on_signal() {
    _install_cleanup
    exit "$1"
}
trap _install_cleanup EXIT
trap '_install_on_signal 130' INT
trap '_install_on_signal 143' TERM

# --- Обработка аргументов ---
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
        --force|-f)      FORCE_REINSTALL=1 ;;
        --preset=*)      CLI_PRESET="${1#*=}" ;;
        --jc=*)          CLI_JC="${1#*=}" ;;
        --jmin=*)        CLI_JMIN="${1#*=}" ;;
        --jmax=*)        CLI_JMAX="${1#*=}" ;;
        *) echo "Неизвестный аргумент: $1" >&2; HELP=1; HELP_EXIT_RC=1 ;;
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
    # --ppa-amnezia-tolerant: дополнительно игнорируем ошибки от PPA Amnezia.
    # Используется на step 2 — там apt_wait_for_ppa_package сам делает retry
    # для outage'а ppa.launchpadcontent.net (issue #68). Без этого флага мы
    # должны fall-fail на любых non-source ошибках, иначе скрипт продолжит
    # установку на stale apt-cache (PR #69 review finding).
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

    # Фильтруем строки ошибок. Игнорируем:
    #   1. Строки про source-пакеты (deb-src / /source/ / Sources)
    #   2. Generic 'Some index files failed to download' — симптом, не причина
    # Дополнительно исключаем заведомо информационные W:-строки, которые не
    # бывают ПРИЧИНОЙ rc!=0, но переживали фильтры и превращали tolerable-сбой
    # (например deb-src 404 при задвоенных sources) в ложный fatal:
    #   - "Target ... is configured multiple times" (дубль sources-записей)
    #   - "... stored in legacy trusted.gpg keyring" (старый формат ключей)
    non_src_errors=$(printf '%s\n' "$err_output" \
        | grep -E '^(E:|Err:|W:)' \
        | grep -vE '(deb-src|/source/|Sources([^[:alpha:]]|$))' \
        | grep -vE 'Some index files failed to download' \
        | grep -vE '^W: (Target .* is configured multiple times|.* stored in legacy trusted\.gpg)' || true)

    # Запоминаем pre-PPA filter состояние: нужно различать «были реальные APT-ошибки,
    # но все на PPA Amnezia» (tolerant OK) от «классифицируемых ошибок не было
    # вообще» (OOM / silent crash — НЕ tolerant даже если в выводе мелькает PPA URL).
    [[ -n "$non_src_errors" ]] && raw_had_non_src_errors=1

    # Опционально (step 2): убираем ошибки только на PPA Amnezia — они будут
    # повторно проверены через apt_wait_for_ppa_package по apt-cache (issue #68).
    if [[ $ppa_tolerant -eq 1 && -n "$non_src_errors" ]]; then
        non_src_errors=$(printf '%s\n' "$non_src_errors" \
            | grep -vE 'ppa\.launchpadcontent\.net.*amnezia' || true)
    fi

    if [[ -z "$non_src_errors" ]]; then
        # Граничный случай: rc != 0, но ни одной классифицируемой строки E:/Err:/W:
        # не найдено (SIGKILL от OOM, silent crash, неизвестный формат вывода apt).
        # Игнорировать можно ТОЛЬКО если в выводе есть явные source-маркеры,
        # либо ppa-tolerant + были реальные APT-строки и все они — на PPA Amnezia.
        if printf '%s\n' "$err_output" | grep -qE '(deb-src|/source/|Sources([^[:alpha:]]|$))'; then
            log_warn "apt update: source packages недоступны в зеркале (ожидаемо, игнорируется)"
            return 0
        fi
        if [[ $ppa_tolerant -eq 1 && $raw_had_non_src_errors -eq 1 ]] \
            && printf '%s\n' "$err_output" | grep -qE 'ppa\.launchpadcontent\.net.*amnezia'; then
            log_warn "apt update: ошибки только на PPA Amnezia (issue #68), продолжаем с retry."
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
# apt_wait_for_ppa_package <package> [max_attempts] [initial_delay_seconds]
#   Ждёт, пока пакет станет видимым в apt-cache, с экспоненциальным
#   backoff между попытками. Нужно на шаге 2 после добавления PPA
#   Amnezia: ppa.launchpadcontent.net иногда коротко лежит (issue #68),
#   и без ретрая первая холодная установка валится, хотя через минуту
#   PPA уже доступен.
#
#   ВАЖНО: проверяется именно apt-cache show, а не rc от apt-get update.
#   apt-get update toлerantно возвращает 0 даже когда какой-то InRelease
#   не скачался — поэтому простого retry на rc недостаточно для outage
#   PPA. Видимость пакета в apt-cache — единственный надёжный сигнал,
#   что PPA реально проиндексировался.
#
#   С дефолтами (3 попытки × initial=30с) сценарий такой: попытка 1 →
#   sleep 30с → apt update + попытка 2 → sleep 60с → apt update +
#   попытка 3 (последняя). После третьего fail возвращаем 1.
#   Итого ожидание между попытками ≈1.5 минуты.
#
#   Cap на delay (1800с) защищает от арифметического переполнения, если
#   кто-то вызовет helper с очень большим max.
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
        log_warn "Пакет '${pkg}' не появился в apt-cache (попытка ${attempt}/${max}, PPA пока недоступен), повтор через ${delay}с..."
        sleep "$delay"
        apt_update_tolerant >/dev/null 2>&1 || true
        delay=$(( delay * 2 > 1800 ? 1800 : delay * 2 ))
    done
    return 1
}

# ==============================================================================
# Справка
# ==============================================================================

show_help() {
    cat << 'EOF'
Использование: sudo bash install_amneziawg.sh [ОПЦИИ]
Скрипт для установки и настройки AmneziaWG 2.0 на Ubuntu (24.04 / 25.10 / 26.04) и Debian (12 / 13).

Опции:
  -h, --help            Показать эту справку и выйти
  --uninstall           Удалить AmneziaWG и все его конфигурации
  --diagnostic          Создать диагностический отчет и выйти
  -v, --verbose         Расширенный вывод для отладки (включая DEBUG)
  --no-color            Отключить цветной вывод в терминале
  --port=НОМЕР          Установить UDP порт (1-65535) неинтерактивно
  --ssh-port=ПОРТ       SSH-порт для правила UFW (по умолчанию определяется
                        автоматически; список через запятую). Используйте, если
                        SSH на нестандартном порту и автодетект недоступен
  --subnet=ПОДСЕТЬ      Подсеть туннеля, только /24 (напр. 10.9.9.1/24) неинтерактивно
  --allow-ipv6          Оставить IPv6 включенным неинтерактивно
  --disallow-ipv6       Принудительно отключить IPv6 неинтерактивно
  --allow-ipv6-tunnel   Включить dual-stack IPv6 внутри туннеля (ULA, opt-in)
  --route-all           Использовать режим 'Весь трафик' неинтерактивно
  --route-amnezia       Использовать режим 'Amnezia' неинтерактивно
  --route-custom=СЕТИ   Использовать режим 'Пользовательский' неинтерактивно
  --endpoint=АДРЕС      Внешний endpoint сервера: FQDN, IPv4 или [IPv6] (для NAT)
  -y, --yes             Автоматическое подтверждение (перезагрузки, UFW и т.д.)
  -f, --force           Принудительная переустановка поверх уже работающего AmneziaWG
                        (по умолчанию запуск на сконфигурированном сервере прерывается;
                        ENV: AWG_FORCE_REINSTALL=1 эквивалентен флагу)
  --no-tweaks           Пропустить необязательный hardening/оптимизацию (UFW,
                        Fail2Ban); минимальный forwarding-sysctl применяется всегда
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
    # Явный --help завершается с 0; неизвестный аргумент - с 1 (ложный успех в CI).
    exit "${HELP_EXIT_RC:-0}"
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
        log "ОС: ${OS_ID^} $OS_VERSION ($OS_CODENAME) — поддерживается"
    else
        log_warn "Обнаружена $OS_ID $OS_VERSION ($OS_CODENAME). Скрипт протестирован на Ubuntu 24.04/25.10/26.04 и Debian 12/13."
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
        # C4: жёсткая ошибка apt_update_tolerant (GPG / сеть на binary-репо / OOM) -
        # это НЕ source-шум, а реальный сбой; продолжать на устаревшем кэше нельзя
        # (контракт стр.138, как у вызовов 1975/2108). die завершает установку, так
        # что _APT_UPDATED=1 проставляется только при успехе - иначе повторный
        # install_packages в этой сессии молча пропустил бы update.
        apt_update_tolerant || die "Ошибка apt update."
        _APT_UPDATED=1
    fi
    if ! DEBIAN_FRONTEND=noninteractive apt install -y "${to_install[@]}"; then
        # v5.13.0: типичный сбой на 25.10/26.04 после in-place upgrade с 24.04 —
        # dpkg postinst пакета amneziawg-dkms запускает `dkms autoinstall`,
        # который итерируется по ВСЕМ ядрам в /lib/modules/. Старые 6.8.x
        # headers скомпилированы gcc-13, а в 25.10 по умолчанию только
        # gcc-15 → autoinstall фолится, dpkg не configure'ит зависящие
        # amneziawg-tools / amneziawg. Принудительно собираем модуль для
        # running ядра и завершаем dpkg --configure -a.
        if printf '%s\n' "${to_install[@]}" | grep -qx "amneziawg-dkms"; then
            log_warn "apt install не завершился — пробую DKMS-сборку только для текущего ядра $(uname -r)..."
            local _mver
            _mver="$(ls /var/lib/dkms/amneziawg/ 2>/dev/null | head -n1)"
            if [[ -n "$_mver" ]] \
               && dkms install -m amneziawg -v "$_mver" -k "$(uname -r)" --force \
               && DEBIAN_FRONTEND=noninteractive dpkg --configure -a; then
                log "DKMS-модуль собран для $(uname -r), dpkg сконфигурирован."
                log "Пакеты установлены."
                return 0
            fi
        fi
        die "Ошибка установки пакетов."
    fi
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

# Определение наличия native IPv6 на VPS.
# Native IPv6 = глобально маршрутизируемый адрес (НЕ ULA fc00::/7, НЕ link-local
# fe80::) И наличие IPv6 default-маршрута. Любого из условий по отдельности мало:
#   - global-адрес без default route -> нет выхода в IPv6-интернет (клиент с ::/0
#     получит black-hole);
#   - ULA (fddd::/...) для `ip` имеет scope global, но в интернет не маршрутизируется.
# Эхо 1 только когда выполнены оба условия, иначе 0.
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
    # IPv6-туннель требует включённого IPv6 на хосте. Снимаю --disallow-ipv6 И
    # активно включаю IPv6 в рантайме ДО detection/render: при upgrade с дефолтной
    # прошлой установки (IPv6 был выключен в рантайме) ядро скрывает все IPv6-адреса,
    # поэтому detect_native_ipv6 дал бы false-negative, а клиент отрендерился бы с
    # IPv6 Address при выключенном в ядре IPv6 (awg-quick restart может упасть). weaq P1.
    if [[ "$ALLOW_IPV6_TUNNEL" -eq 1 ]]; then
        if [[ "$DISABLE_IPV6" -eq 1 ]]; then
            log_warn "--allow-ipv6-tunnel requires host IPv6 forwarding; overriding --disallow-ipv6 (DISABLE_IPV6=0)"
            DISABLE_IPV6=0
        fi
        sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || true
    fi
    # Native IPv6 определяю ПОСЛЕ runtime-включения (кэширую в init для client render Phase 4).
    SERVER_HAS_NATIVE_IPV6=$(detect_native_ipv6)
    if [[ "$ALLOW_IPV6_TUNNEL" -eq 1 && "$SERVER_HAS_NATIVE_IPV6" -eq 0 ]]; then
        log_warn "Native IPv6 не обнаружен на VPS - туннель IPv6 будет работать peer-to-peer без выхода в IPv6-интернет."
    fi
    export ALLOW_IPV6_TUNNEL IPV6_SUBNET SERVER_HAS_NATIVE_IPV6 DISABLE_IPV6
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
                DISABLE_IPV6|ALLOWED_IPS_MODE|ALLOWED_IPS|AWG_ENDPOINT|AWG_MTU|\
                AWG_Jc|AWG_Jmin|AWG_Jmax|AWG_S1|AWG_S2|AWG_S3|AWG_S4|\
                AWG_H1|AWG_H2|AWG_H3|AWG_H4|AWG_I1|AWG_I2|AWG_I3|AWG_I4|AWG_I5|AWG_PRESET|NO_TWEAKS|\
                AWG_APPLY_MODE|ALLOW_IPV6_TUNNEL|IPV6_SUBNET|SERVER_HAS_NATIVE_IPV6)
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
    # ^[1-9][0-9]{0,4}$ запрещает ведущие нули ('0080' иначе трактуется как octal
    # в арифметике и проскакивает проверку диапазона) и ограничивает длину: без
    # лимита 64-битная арифметика (( )) переполняется и 2^64+51820 проходил бы
    # range-check. Сравнение - на чистом decimal.
    if ! [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] || (( port > 65535 )); then
        die "Некорректный порт: '$port'. Допустимый диапазон: 1-65535."
    fi
}

validate_subnet() {
    local subnet="$1" o
    # Октеты без ведущих нулей: '010.008...' иначе трактуется как octal в [[ -gt ]]
    # и проскакивает проверку. Диапазон считаем на чистых decimal-значениях.
    if ! [[ "$subnet" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})/24$ ]]; then
        die "Некорректная подсеть: '$subnet'. Поддерживается только /24."
    fi
    for o in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
        (( o <= 255 )) || die "Некорректная подсеть: '$subnet'. Октет вне диапазона 0-255."
    done
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
    # Форма [IPv6]: структурная проверка содержимого скобок. Прежний charset-only
    # пропускал мусор вроде [:::] / [1:2:3]. Зеркало _valid_ipv6 из awg_common.sh.
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
    # Иначе FQDN или IPv4
    [[ "$ep" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*|[0-9]{1,3}(\.[0-9]{1,3}){3})$ ]] || return 1
    # Если IPv4 формат - дополнительно проверяем диапазон октетов 0-255
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
    # Перевод строки = инъекция в awgsetup_cfg.init (read <<< видит только первую
    # строку, остальное прошло бы без проверки). Аналогично validate_endpoint.
    [[ "$input" != *$'\n'* ]] || return 1
    # Структурная проверка запятых до split: bash IFS отбрасывает хвостовой пустой
    # элемент, поэтому '10.0.0.0/24,' раньше проходил. Отвергаем ведущую/хвостовую/
    # двойную запятую и пустой ввод (пробелы игнорируем при этой проверке).
    nospace="${input// /}"
    case "$nospace" in
        ""|,*|*,|*,,*) return 1 ;;
    esac
    IFS=',' read -ra cidrs <<< "$input"
    for cidr in "${cidrs[@]}"; do
        cidr="${cidr// /}"
        # Октеты без ведущих нулей; префикс 0-32 прямо в regex (без octal-арифметики).
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
           # iOS рвёт туннель, если список начинается с 0.0.0.0/5: этот блок включает
           # служебный 0.0.0.0/8, на котором ядро iOS спотыкается и не доходит до остальных
           # маршрутов. 1.0.0.0/8 + 2.0.0.0/7 + 4.0.0.0/6 = тот же охват без нулевого блока
           # (0.0.0.0/8 всё равно не маршрутизируется). Не возвращать к 0.0.0.0/5 (Issue #42).
           ALLOWED_IPS="1.0.0.0/8, 2.0.0.0/7, 4.0.0.0/6, 8.0.0.0/7, 11.0.0.0/8, 12.0.0.0/6, 16.0.0.0/4, 32.0.0.0/3, 64.0.0.0/2, 128.0.0.0/3, 160.0.0.0/5, 168.0.0.0/6, 172.0.0.0/12, 172.32.0.0/11, 172.64.0.0/10, 172.128.0.0/9, 173.0.0.0/8, 174.0.0.0/7, 176.0.0.0/4, 192.0.0.0/9, 192.128.0.0/11, 192.160.0.0/13, 192.169.0.0/16, 192.170.0.0/15, 192.172.0.0/14, 192.176.0.0/12, 192.192.0.0/10, 193.0.0.0/8, 194.0.0.0/7, 196.0.0.0/6, 200.0.0.0/5, 208.0.0.0/4, 8.8.8.8/32, 1.1.1.1/32"
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
        # Fallback: три $RANDOM (15 бит каждый) с XOR-перекрытием покрывают
        # биты 0-30, т.е. весь [0, 2^31-1]. Прежний вариант (RANDOM<<15|RANDOM)
        # давал только 30 бит - верхняя половина диапазона H никогда не выпадала.
        random_val=$(( (RANDOM << 16) ^ (RANDOM << 8) ^ RANDOM ))
    fi
    echo $(( (random_val % range) + min ))
}

# Генерация 4 непересекающихся диапазонов для AWG H1-H4.
# Алгоритм: 8 случайных значений → sort → 4 пары (low, high).
# Сортировка даёт low <= high; строгие проверки ниже гарантируют зазор между
# парами (касание границ = пересечение в одной точке) и нижнюю границу >= 5
# (значения 1-4 зарезервированы под типы сообщений vanilla WireGuard).
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

    # I2-I5 здесь НЕ генерируются (admin задаёт их вручную в awg0.conf, issue #71).
    # Свежая генерация набора (первая установка или --preset/--jc/--jmin/--jmax)
    # сбрасывает возможные stale I2-I5, загруженные из awgsetup_cfg.init, чтобы новый
    # набор обфускации не тащил старые значения (--preset перегенерирует весь набор).
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

    # Снимок default route ДО очистки - для проверки что мы не сломали сеть.
    # Issue #84: на чистой Ubuntu 26.04 server (subiquity, без cloud-init
    # netplan-маркеров) apt-get autoremove после purge cloud-init сносил
    # netplan-generator как transitive dep, и сервер терял IP после reboot.
    local pre_default_route
    pre_default_route="$(ip -4 route show default 2>/dev/null | head -1 || true)"
    log_debug "Pre-cleanup default route: ${pre_default_route:-<none>}"

    # apt-mark hold на критичные пакеты сетевого стека: защита от случайного
    # удаления через transitive deps. Покрываем оба варианта именования netplan
    # (netplan.io на 24.04, netplan-generator на 25.10/26.04), а также
    # systemd-resolved и netcfg/ifupdown legacy. Пакета systemd-networkd
    # отдельно не существует - бинарь живёт внутри systemd, hold-ить нечего.
    # Перед hold снимаем снимок текущих hold-ов пользователя, чтобы при unhold
    # не затереть его pre-existing holds (например на linux-image-*).
    local _hold_pkgs="netplan.io netplan-generator systemd-resolved netcfg ifupdown"
    local _preexisting_holds=""
    _preexisting_holds="$(apt-mark showhold 2>/dev/null || true)"
    local _held_actual=()
    local _hpkg
    for _hpkg in $_hold_pkgs; do
        if dpkg-query -W -f='${Status}' "$_hpkg" 2>/dev/null | grep -q "ok installed"; then
            # Пропускаем уже залоченные пользователем - их hold не наш и снимать его нельзя.
            if grep -qxF "$_hpkg" <<<"$_preexisting_holds"; then
                continue
            fi
            apt-mark hold "$_hpkg" >/dev/null 2>&1 && _held_actual+=("$_hpkg")
        fi
    done
    [ ${#_held_actual[@]} -gt 0 ] && log_debug "Apt-mark hold: ${_held_actual[*]}"

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

    # apt-get autoremove убран (был источник Issue #84 на Ubuntu 26.04 ISO):
    # autoremove зачищал netplan-generator как transitive dep cloud-init.
    # Орфанные пакеты после purge займут ~50-200 МБ - приемлемо ради стабильности.
    # Пользователь может вручную: apt-get autoremove --no-install-recommends.

    # Снимаем hold, чтобы не оставлять "застывшие" пакеты в состоянии hold.
    local _upkg
    for _upkg in "${_held_actual[@]}"; do
        apt-mark unhold "$_upkg" >/dev/null 2>&1 || true
    done

    # Проверка что default route не пропал. Если пропал - пробуем восстановить.
    # Восстанавливаем netplan.io безусловно (есть на всех supported distro),
    # netplan-generator - только если он реально доступен в архивах данной
    # системы (на Debian 12 этого пакета ещё нет, apt-get install <missing>
    # абортит транзакцию даже с || true для всей строки).
    local post_default_route
    post_default_route="$(ip -4 route show default 2>/dev/null | head -1 || true)"
    if [[ -n "$pre_default_route" && -z "$post_default_route" ]]; then
        log_error "Маршрут по умолчанию потерян после очистки. Попытка восстановления..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            netplan.io 2>/dev/null || true
        if apt-cache show netplan-generator &>/dev/null; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
                netplan-generator 2>/dev/null || true
        fi
        systemctl restart systemd-networkd 2>/dev/null || true
        netplan apply 2>/dev/null || true
        # Цикл ожидания маршрута: до ~26 секунд, проверка раз в 1-5 секунд.
        # Фиксированные sleep не годятся - время появления DHCP-маршрута
        # на медленных VM непредсказуемо.
        local _wait
        for _wait in 1 2 3 5 5 5 5; do
            post_default_route="$(ip -4 route show default 2>/dev/null | head -1 || true)"
            [[ -n "$post_default_route" ]] && break
            sleep "$_wait"
        done
        # Last-ditch: поднять интерфейс из pre_default_route. Сначала пробуем
        # networkctl renew (для systemd-networkd-managed link), если маршрут не
        # появился - переходим на dhclient (для ifupdown-managed link).
        if [[ -z "$post_default_route" ]]; then
            local _iface
            _iface="$(awk '{for (i=1; i<=NF; i++) if ($i == "dev") { print $(i+1); exit } }' <<<"$pre_default_route")"
            if [[ -n "$_iface" ]]; then
                log_warn "Финальная попытка поднять интерфейс $_iface..."
                ip link set "$_iface" up 2>/dev/null || true
                if command -v networkctl &>/dev/null; then
                    networkctl renew "$_iface" 2>/dev/null || true
                    sleep 3
                    post_default_route="$(ip -4 route show default 2>/dev/null | head -1 || true)"
                fi
                # Если networkctl не привёл маршрут к жизни (или его нет) - dhclient.
                if [[ -z "$post_default_route" ]] && command -v dhclient &>/dev/null; then
                    dhclient -4 "$_iface" 2>/dev/null || true
                    sleep 3
                    post_default_route="$(ip -4 route show default 2>/dev/null | head -1 || true)"
                fi
            fi
        fi
        if [[ -z "$post_default_route" ]]; then
            die "Сеть не восстановилась после cleanup_system. Восстановите её с консоли (например: sudo dhclient -4 <интерфейс>) и перезапустите установщик с флагом --no-tweaks."
        fi
        log_warn "Сеть восстановлена: $post_default_route"
    fi

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
        # Добавляем в fstab если отсутствует. Точная проверка по полям:
        # игнорируем закомментированные строки и partial matches (например,
        # `/swapfile.bak` или старая строка в комментарии).
        if ! awk '!/^[[:space:]]*#/ && $1 == "/swapfile" && $3 == "swap" {found=1} END {exit !(found+0)}' \
             /etc/fstab; then
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

# Определение реального SSH-порта(ов) для корректного правила UFW.
# Без этого ufw limit 22/tcp + default deny incoming отрезает доступ к серверу
# после ufw enable, если SSH поднят на нестандартном порту (Issue #91).
# Функция самодостаточна: вызывается на шаге 4, ДО подключения awg_common.sh.
# Источники:
#   1. CLI_SSH_PORT (--ssh-port=, ручной override, список через запятую) - авторитетно
#   иначе ОБЪЕДИНЕНИЕ (union, не fallback - так не пропустим реальный порт):
#   2. sshd -T   (эффективный конфиг: `Port` И `ListenAddress host:port`, учитывает drop-ins)
#   3. ss -tlnp  (реальные listening-сокеты sshd: ground truth для ListenAddress)
#   4. /etc/ssh/sshd_config + sshd_config.d/*.conf (парсинг, только если 2-3 пусты)
#   5. 22 (дефолт, если ничего не найдено)
# Выводит уникальные валидные порты (1-65535) через пробел в stdout.
# ВАЖНО: внутри только log_warn/log_error (stderr); log() пишет в stdout и
# испортил бы перехват $(detect_ssh_ports).
detect_ssh_ports() {
    local ports="" p pp valid=""
    # awk: достаёт порт из строк `port N` и `listenaddress host:port`
    # (IPv4 и [IPv6]); голый адрес без порта пропускается.
    local awk_ports='tolower($1)=="port"&&$2~/^[0-9]+$/{print $2} tolower($1)=="listenaddress"{v=$2; if(v~/\]:[0-9]+$/){sub(/.*\]:/,"",v); print v} else if(v~/^[0-9.]+:[0-9]+$/){sub(/.*:/,"",v); print v}}'

    if [[ -n "$CLI_SSH_PORT" ]]; then
        # 1. Ручной override - авторитетный источник
        ports="${CLI_SSH_PORT//,/ }"
    else
        # 2. sshd -T: эффективная конфигурация (Port + ListenAddress, drop-ins)
        if command -v sshd &>/dev/null; then
            ports+=" $(sshd -T 2>/dev/null | awk "$awk_ports" | tr '\n' ' ')"
        fi
        # 3. ss: реальные listening-сокеты sshd. Объединяем, не fallback -
        #    ловит ListenAddress-порт, даже если sshd -T печатает дефолтный port 22.
        if command -v ss &>/dev/null; then
            ports+=" $(ss -H -tlnp 2>/dev/null | awk '/"sshd"/{n=split($4,a,":"); print a[n]}' | tr '\n' ' ')"
        fi
        # 4. Парсинг конфигов - только если sshd -T и ss ничего не дали
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

    # Валидация (десятичная 1-65535, 10# против octal) + дедуп с сохранением порядка
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

    # 5. Дефолт, если детект ничего валидного не дал
    if [[ -z "$valid" ]]; then
        [[ -n "$CLI_SSH_PORT" ]] && log_warn "--ssh-port не содержит валидных портов, использую 22."
        valid="22"
    fi
    printf '%s' "$valid"
}

setup_improved_firewall() {
    log "Настройка UFW..."
    if ! command -v ufw &>/dev/null; then install_packages ufw; fi

    # Определяем основной сетевой интерфейс для правила маршрутизации
    local main_nic
    main_nic=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    if [[ -z "$main_nic" ]]; then
        log_warn "Не удалось определить сетевой интерфейс для UFW route."
    fi

    # Определяем реальный SSH-порт(ы), чтобы не отрезать доступ при нестандартном порту (Issue #91)
    local ssh_ports _sp
    ssh_ports=$(detect_ssh_ports)
    log "SSH-порт(ы) для правила UFW: ${ssh_ports}"

    local ufw_errors=0
    if ufw status 2>/dev/null | grep -q inactive; then
        log "UFW неактивен. Настройка..."
        ufw default deny incoming  || { log_warn "UFW: ошибка default deny incoming"; ufw_errors=1; }
        ufw default allow outgoing || { log_warn "UFW: ошибка default allow outgoing"; ufw_errors=1; }
        for _sp in $ssh_ports; do
            ufw limit "${_sp}/tcp" comment "SSH Rate Limit" || { log_warn "UFW: ошибка limit SSH (порт ${_sp})"; ufw_errors=1; }
        done
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
        log_warn "UFW разрешит SSH ТОЛЬКО на порту(ах): ${ssh_ports}. Убедитесь, что подключаетесь по нему."
        if [[ "$ssh_ports" != "22" ]]; then
            log_warn "ВНИМАНИЕ: SSH на нестандартном порту. Если порт определён неверно - доступ к серверу пропадёт."
            log_warn "Override при необходимости: --ssh-port=ПОРТ"
        fi
        local confirm_ufw="y"
        if [[ "$AUTO_YES" -eq 0 ]]; then
            sleep 5
            read -rp "Включить UFW? [y/N]: " confirm_ufw < /dev/tty
        else
            log "Автоматическое включение UFW (--yes)."
        fi
        if ! [[ "$confirm_ufw" =~ ^[Yy]$ ]]; then
            log_warn "UFW настроен, но не активирован по вашему выбору."
            log_warn "Сервер работает БЕЗ фаервола. Включить позже: sudo ufw enable"
            return 0
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
        for _sp in $ssh_ports; do
            ufw limit "${_sp}/tcp" comment "SSH Rate Limit" || { log_warn "UFW: ошибка limit SSH (порт ${_sp})"; ufw_errors=1; }
        done
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
    if ! command -v fail2ban-client &>/dev/null; then
        install_packages fail2ban
        # Маркер: пакет fail2ban доустановлен нашим установщиком (а не стоял
        # до него). step_uninstall выполняет purge fail2ban только при наличии
        # маркера, чтобы не снести SSH-защиту, настроенную пользователем заранее
        # (симметрично .ufw_enabled_by_installer).
        if command -v fail2ban-client &>/dev/null; then
            touch "$AWG_DIR/.fail2ban_installed_by_installer" 2>/dev/null || \
                log_warn "Не удалось создать fail2ban marker - uninstall не будет удалять пакет fail2ban."
        fi
    fi
    if ! command -v fail2ban-client &>/dev/null; then
        log_warn "Fail2ban не установлен, пропускаем."
        return 1
    fi

    # banaction=ufw действует только при активном UFW: если на шаге 4
    # пользователь отказался включать UFW, баны добавляются в неактивный
    # набор правил и фактически не работают (fail2ban при этом "зелёный").
    if ufw status 2>/dev/null | grep -q inactive; then
        log_warn "UFW не активен: fail2ban-баны (banaction=ufw) не действуют, пока UFW выключен. Включить: sudo ufw enable"
    fi

    # Debian: journald вместо rsyslog, нужен python3-systemd
    if [[ "${OS_ID:-}" == "debian" ]]; then
        install_packages python3-systemd
    fi

    mkdir -p /etc/fail2ban/jail.d 2>/dev/null

    # Backend: systemd для Debian и Ubuntu (нет rsyslog)
    local f2b_backend="systemd"

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

    systemctl restart fail2ban
    # Одну секунду, сервис перезапускается...
    sleep 1

    if systemctl is-active --quiet fail2ban; then
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
    # --diagnostic вызывается ДО initialize_setup (где живёт основной root-check):
    # под обычным пользователем запись в /root/awg падает на каждом log_msg,
    # отчёт не создаётся, а exit 0 выглядел бы как ложный успех.
    if [ "$(id -u)" -ne 0 ]; then die "Запустите скрипт от root (sudo bash $0 --diagnostic)."; fi
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
    # v5.12.0+: автовосстановление модуля при обновлении ядра.
    # Удаляем apt hook и systemd unit ДО apt purge, чтобы хук не сработал
    # во время purge amneziawg-dkms (helper попытался бы пересобрать DKMS,
    # но пакета уже нет). Файлы могут отсутствовать у установок до v5.12.0 —
    # все операции idempotent.
    log "Удаление компонентов автовосстановления модуля (v5.12.0+)..."
    if systemctl is-enabled amneziawg-ensure-module.service &>/dev/null; then
        systemctl disable amneziawg-ensure-module.service 2>/dev/null || true
    fi
    rm -f /etc/systemd/system/amneziawg-ensure-module.service \
        /etc/apt/apt.conf.d/99-amneziawg-post-kernel \
        /etc/logrotate.d/amneziawg-ensure-module \
        /usr/local/sbin/amneziawg-ensure-module \
        2>/dev/null
    # Также подчищаем staging dotfiles, оставшиеся от прерванного install (atomic deploy).
    rm -f /etc/systemd/system/.amneziawg-ensure-module.service.new \
        /etc/apt/apt.conf.d/.99-amneziawg-post-kernel.new \
        /etc/logrotate.d/.amneziawg-ensure-module.new \
        /usr/local/sbin/.amneziawg-ensure-module.new \
        2>/dev/null || true
    rm -f /var/log/amneziawg-ensure-module.log* 2>/dev/null || true
    rm -rf /var/lib/amneziawg 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
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
        local _purge_pkgs=(amneziawg-dkms amneziawg-tools qrencode)
        # fail2ban purge-им только если сами его доустановили (маркер из
        # setup_fail2ban) - иначе пользовательская SSH-защита, стоявшая до
        # установщика, не должна исчезать вместе с VPN. Наш jail-файл
        # удаляется ниже в любом случае. Backwards compat: старые установки
        # без маркера сохраняют fail2ban установленным.
        if [[ -f "$AWG_DIR/.fail2ban_installed_by_installer" ]]; then
            _purge_pkgs+=(fail2ban)
        else
            log "fail2ban оставлен установленным (стоял до установщика или старая версия инсталлятора)."
        fi
        DEBIAN_FRONTEND=noninteractive apt-get purge -y "${_purge_pkgs[@]}" 2>/dev/null || log_warn "Ошибка purge."
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
        # Если fail2ban не purge-ился (стоял до нас) - перезапускаем его без
        # нашего jail: выше он был остановлен (systemctl stop fail2ban).
        if command -v fail2ban-client &>/dev/null && [[ ! -f "$AWG_DIR/.fail2ban_installed_by_installer" ]]; then
            systemctl restart fail2ban 2>/dev/null || log_warn "Не удалось перезапустить fail2ban после удаления нашего jail."
        fi
    fi
    log "Удаление DKMS..."
    rm -rf /var/lib/dkms/amneziawg* || log_warn "Ошибка удаления DKMS."
    log "Восстановление sysctl..."
    # Только точные строки, которые писали legacy-версии нашего инсталлятора
    # (=1 для all/default/lo). Раньше удалялась ЛЮБАЯ строка с disable_ipv6 -
    # включая добавленные самим пользователем (например =0 override).
    if grep -qE '^net\.ipv6\.conf\.(all|default|lo)\.disable_ipv6[[:space:]]*=[[:space:]]*1[[:space:]]*$' /etc/sysctl.conf 2>/dev/null; then
        sed -i -E '/^net\.ipv6\.conf\.(all|default|lo)\.disable_ipv6[[:space:]]*=[[:space:]]*1[[:space:]]*$/d' /etc/sysctl.conf || log_warn "Ошибка sed sysctl.conf"
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
        # Интерактивный ввод: опечатка не убивает установку (валидатор в
        # subshell -> die печатает ошибку, но завершает только subshell, и
        # запрос повторяется). Финальные validate_* вне цикла остаются
        # авторитетными для CLI/конфиг-значений (там die уместен).
        if [[ "$AUTO_YES" -eq 0 ]]; then
            while true; do
                read -rp "Введите UDP порт AmneziaWG (1-65535) [${AWG_PORT}]: " input_port < /dev/tty
                [[ -z "$input_port" ]] && break
                if ( validate_port "$input_port" ); then AWG_PORT=$input_port; break; fi
                log_warn "Повторите ввод порта."
            done
        fi
        validate_port "$AWG_PORT"
        if [[ "$AUTO_YES" -eq 0 ]]; then
            while true; do
                read -rp "Введите подсеть туннеля [${AWG_TUNNEL_SUBNET}]: " input_subnet < /dev/tty
                [[ -z "$input_subnet" ]] && break
                if ( validate_subnet "$input_subnet" ); then AWG_TUNNEL_SUBNET=$input_subnet; break; fi
                log_warn "Повторите ввод подсети."
            done
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
    configure_ipv6_tunnel
    if [[ "$ALLOWED_IPS_MODE" == "default" ]]; then ALLOWED_IPS_MODE=2; fi
    if [[ -z "$ALLOWED_IPS" ]]; then configure_routing_mode; fi

    # Единая обязательная валидация AllowedIPs до сохранения конфига: CLI
    # --route-custom на первом запуске присваивал ALLOWED_IPS без проверки
    # (configure_routing_mode пропускался, т.к. режим уже был 3). Проверяем
    # любой непустой список независимо от источника (CLI / конфиг / выбор режима).
    if [[ -n "$ALLOWED_IPS" ]] && ! validate_cidr_list "$ALLOWED_IPS"; then
        die "Некорректный ALLOWED_IPS: '$ALLOWED_IPS'. Ожидается список x.x.x.x/y[,x.x.x.x/y]."
    fi

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
        # generate_awg_params перегенерирует ВЕСЬ набор (S1-S4, H1-H4, I1), а
        # не только запрошенный параметр: при переустановке поверх живого
        # сервера все выданные клиентские конфиги хранят старые H1-H4 и
        # перестанут подключаться. Предупреждаем громко.
        if [[ "$config_exists" -eq 1 && -n "${AWG_Jc:-}" ]]; then
            log_warn "ВНИМАНИЕ: --preset/--jc/--jmin/--jmax при переустановке перегенерируют ВСЕ параметры обфускации (включая H1-H4/S1-S4/I1)."
            log_warn "Все существующие клиентские конфиги перестанут подключаться - перевыпустите их после установки: sudo bash $MANAGE_SCRIPT_PATH regen"
        fi
        generate_awg_params
    else
        log "AWG 2.0 параметры уже заданы из конфига."
    fi

    # Сохранение конфигурации
    log "Сохранение настроек в $CONFIG_FILE..."
    # temp в каталоге итогового конфига -> mv = атомарный rename на той же ФС
    # (а не cross-fs copy+unlink, если /tmp смонтирован как tmpfs).
    local temp_conf cfg_dir
    cfg_dir="$(dirname "$CONFIG_FILE")"
    mkdir -p "$cfg_dir" 2>/dev/null
    temp_conf=$(mktemp -p "$cfg_dir") || die "Ошибка mktemp."
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
export AWG_APPLY_MODE='${AWG_APPLY_MODE:-syncconf}'
export ALLOW_IPV6_TUNNEL=${ALLOW_IPV6_TUNNEL:-0}
export IPV6_SUBNET='${IPV6_SUBNET}'
export SERVER_HAS_NATIVE_IPV6=${SERVER_HAS_NATIVE_IPV6:-0}
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
    # Кэш свежий: install_packages ниже не должен гонять apt update повторно
    # (источники в шаге 1 не меняются).
    _APT_UPDATED=1

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

    # --ppa-amnezia-tolerant ОБЯЗАТЕЛЕН уже здесь: если на диске остался
    # PPA-файл с битым suite (404 Release; например questing от старой версии
    # или после in-place upgrade), строгий update умирал ДО repair-блоков ниже
    # и ремонт никогда не срабатывал (live-репро на Debian 12, v5.16.0 cycle).
    # Ошибки базовых репозиториев по-прежнему fail-closed; PPA-ошибки чинит
    # repair + post-PPA update + apt_wait_for_ppa_package ниже.
    apt_update_tolerant --ppa-amnezia-tolerant || die "Ошибка apt update."

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
            # Для Ubuntu non-LTS (questing/plucky/oracular/...) PPA Amnezia
            # пакетов не публикует — там 404 на dists/<codename>/Release.
            # Проверяем доступность через HEAD-запрос и переключаемся на
            # noble (LTS): сборка для noble корректно DKMS-собирается под
            # текущее ядро.
            # Связано: amnezia-vpn/amneziawg-linux-kernel-module#118
            case "$ppa_codename" in
                noble|jammy|focal)
                    # Known LTS — пропускаем pre-check (PPA точно опубликован)
                    ;;
                *)
                    log "Проверка доступности PPA Amnezia для Ubuntu '${ppa_codename}'..."
                    if ! curl -fsI --max-time 15 --retry 2 --retry-delay 5 \
                        "https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu/dists/${ppa_codename}/Release" \
                        >/dev/null 2>&1; then
                        log_warn "PPA Amnezia не публикует пакеты для Ubuntu '${ppa_codename}' (HTTP 404 или host недоступен)."
                        log_warn "Переключаюсь на 'noble' — DKMS соберёт модуль под текущее ядро."
                        log_warn "Контекст: https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/issues/118"
                        ppa_codename="noble"
                    else
                        log "PPA Amnezia доступен для '${ppa_codename}'."
                    fi
                    ;;
            esac
            ;;
    esac

    local keyring_dir="/etc/apt/keyrings"
    local keyring_file="${keyring_dir}/amnezia-ppa.gpg"
    local ppa_sources="/etc/apt/sources.list.d/amnezia-ppa.sources"
    local ppa_list="/etc/apt/sources.list.d/amnezia-ppa.list"
    # Проверка на legacy-файлы (от add-apt-repository предыдущих версий)
    local legacy_list="/etc/apt/sources.list.d/amnezia-ubuntu-ppa-${codename}.list"
    local legacy_sources="/etc/apt/sources.list.d/amnezia-ubuntu-ppa-${codename}.sources"
    # Повторный запуск на сервере, где предыдущий (≤ v5.12.1) создал .sources
    # с «битым» Suites=questing/plucky/etc.: если найденный suite не совпадает
    # с целевым ppa_codename — удаляем файл, чтобы пересоздать ниже с правильным.
    # Та же проверка для устаревшего .sources (формат от add-apt-repository).
    # Если файл существует, но строка `Suites:` не парсится — считаем повреждённым
    # и тоже пересоздаём, иначе сломанный файл проскочит как «PPA уже добавлен».
    local existing_suite=""
    if [[ -f "$ppa_sources" ]]; then
        existing_suite=$(awk '/^Suites:/{print $2; exit}' "$ppa_sources" 2>/dev/null)
    fi
    if [[ -f "$ppa_sources" && ( -z "$existing_suite" || "$existing_suite" != "$ppa_codename" ) ]]; then
        if [[ -z "$existing_suite" ]]; then
            log_warn "$ppa_sources существует, но строка Suites: не найдена — пересоздание."
        else
            log_warn "Существующий PPA suite='${existing_suite}', целевой='${ppa_codename}' — пересоздание $ppa_sources."
        fi
        rm -f "$ppa_sources" "$ppa_list"
    fi
    local legacy_suite=""
    if [[ -f "$legacy_sources" ]]; then
        legacy_suite=$(awk '/^Suites:/{print $2; exit}' "$legacy_sources" 2>/dev/null)
    fi
    if [[ -f "$legacy_sources" && ( -z "$legacy_suite" || "$legacy_suite" != "$ppa_codename" ) ]]; then
        log_warn "Устаревший PPA-файл $legacy_sources (suite='${legacy_suite:-<пусто>}') не соответствует целевому '${ppa_codename}' — удаление."
        rm -f "$legacy_sources" "$legacy_list"
    fi
    # Тот же ремонт для traditional .list (Debian 12): suite - токен после URL
    # в строке 'deb [opts] URL <suite> main'. Без проверки файл со старым/чужим
    # suite (например после in-place upgrade bookworm->trixie) проскочил бы
    # ниже как "PPA уже добавлен", и apt продолжил бы тянуть не тот suite.
    local list_suite=""
    if [[ -f "$ppa_list" ]]; then
        list_suite=$(awk '/^deb([[:space:]]|$)/ {
            for (i = 2; i <= NF; i++) {
                if ($i ~ /^https?:/) { print $(i+1); exit }
            }
        }' "$ppa_list" 2>/dev/null)
        if [[ -z "$list_suite" || "$list_suite" != "$ppa_codename" ]]; then
            log_warn "Существующий $ppa_list (suite='${list_suite:-<пусто>}') не соответствует целевому '${ppa_codename}' - пересоздание."
            rm -f "$ppa_list"
        fi
    fi
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
        # Запрос по ПОЛНОМУ 40-символьному fingerprint, не по короткому ID:
        # для коротких 32-битных ID существуют preimage-коллизии (evil32), а
        # keyserver.ubuntu.com принимает загрузку чужих ключей. Подменённый
        # ключ не дал бы RCE (подпись пакетов не сойдётся), но ломал бы
        # установку малопонятной ошибкой apt.
        local _ppa_key_fpr="75C9DD72C799870E310542E24166F2C257290828"
        if ! curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${_ppa_key_fpr}" \
             | gpg --batch --no-tty --yes --dearmor -o "$_kf_tmp"; then
            rm -f "$_kf_tmp" 2>/dev/null
            die "Ошибка импорта GPG ключа Amnezia PPA."
        fi
        # Сверка fingerprint скачанного ключа с ожидаемым (pin).
        local _got_fpr
        _got_fpr=$(gpg --batch --no-tty --show-keys --with-colons "$_kf_tmp" 2>/dev/null \
            | awk -F: '/^fpr:/{print $10; exit}')
        if [[ "$_got_fpr" != "$_ppa_key_fpr" ]]; then
            rm -f "$_kf_tmp" 2>/dev/null
            die "GPG ключ Amnezia PPA не прошёл проверку fingerprint (получен: '${_got_fpr:-<пусто>}')."
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
    # apt-get update + классификация ошибок:
    #   - Ошибки ТОЛЬКО на PPA Amnezia → продолжаем, apt_wait_for_ppa_package
    #     ниже сделает retry (issue #68: ppa.launchpadcontent.net коротко лежит).
    #   - Любая другая non-source ошибка (DNS / GPG mismatch / dpkg lock на base
    #     mirror) → fall-fail. Продолжать на stale apt-cache небезопасно —
    #     следующий apt-get install упадёт с менее actionable сообщением
    #     (PR #69 review finding).
    if ! apt_update_tolerant --ppa-amnezia-tolerant; then
        log_error "apt-get update завершился с hard error — не PPA outage (issue #68)."
        log_error "Проверьте: DNS, доступ к archive.ubuntu.com / deb.debian.org,"
        log_error "целостность ключей в /etc/apt/keyrings, занятость dpkg lock."
        die "apt update вернул ошибку (rc!=0, не PPA Amnezia)."
    fi
    # PPA добавлен, кэш обновлён: дальше в шаге 2 источники не меняются,
    # поэтому install_packages не должен повторять apt update (на медленных
    # зеркалах каждый прогон = 10-60 секунд).
    _APT_UPDATED=1
    # apt-get update толерантен к недоступному InRelease (rc=0 даже когда PPA
    # лежит). Поэтому проверяем именно появление пакета amneziawg-dkms в
    # apt-cache, с тремя попытками и backoff 30с/60с (≈1.5 мин total).
    # Кратковременный outage ppa.launchpadcontent.net (issue #68) не должен
    # валить установку.
    if ! apt_wait_for_ppa_package amneziawg-dkms 3 30; then
        log_error "Пакет amneziawg-dkms не появился в apt-cache после 3 попыток."
        log_error "Похоже, ppa.launchpadcontent.net сейчас недоступен — это outage"
        log_error "инфраструктуры Launchpad, не баг скрипта."
        log_error "Подождите 10–15 минут и запустите скрипт снова той же командой."
        log_error "Подробнее: https://github.com/bivlked/amneziawg-installer/issues/68"
        die "PPA Amnezia временно недоступен."
    fi

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
            # request_reboot всегда завершает процесс (exit), сюда не вернёмся.
            request_reboot 3
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
    # v5.13.0: на 25.10/26.04 после in-place upgrade с 24.04 в системе могут
    # остаться kernel headers от 24.04 (6.8.x), скомпилированные gcc-13. В
    # 25.10 по умолчанию ставится только gcc-15 → dkms autoinstall в postinst
    # пакета amneziawg-dkms падает при сборке под устаревшие ядра, и dpkg
    # оставляет amneziawg* unconfigured. Если в системе обнаружены kernel
    # headers, отличные от running, заранее доставляем gcc-13 (доступен в
    # questing/universe и 26.04 archive), чтобы autoinstall прошёл для всех
    # ядер.
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
            log "Обнаружены устаревшие kernel headers (≠ $_running_kernel) — устанавливаю gcc-13 для совместимости DKMS autoinstall."
            DEBIAN_FRONTEND=noninteractive apt install -y gcc-13 \
                || log_warn "Не удалось установить gcc-13 — DKMS autoinstall может падать на устаревших ядрах."
        else
            log_warn "Обнаружены устаревшие kernel headers, но gcc-13 недоступен в repo — DKMS autoinstall может падать."
        fi
    fi
    install_packages "${packages[@]}"

    # v5.12.0: мета-пакет linux-headers, чтобы apt автоматически подтягивал
    # заголовки при kernel upgrade. Без меты ставится только
    # linux-headers-$(uname -r) — он не tracking новые ядра, и на следующем
    # apt upgrade DKMS-модуль не успеет пересобраться.
    #
    # Detect kernel flavor (Ubuntu cloud images: aws/azure/gcp/oracle/kvm/
    # lowlatency/raspi; Debian cloud-amd64) — обычный linux-headers-generic
    # на Azure-VM tracking не тот kernel-pipeline. Берём суффикс uname -r,
    # пробуем flavor-specific meta, fallback на generic/arch.
    local arch_meta kernel_rel
    arch_meta="$(dpkg --print-architecture 2>/dev/null || echo '')"
    kernel_rel="$(uname -r)"
    local -a meta_candidates=()
    if [[ "$kernel_rel" == *+rpt* || "$kernel_rel" == *-rpi* ]]; then
        : # RPi: мета linux-headers-rpi-{2712,v8} уже добавлена в packages выше.
    elif [[ "${OS_ID:-ubuntu}" == "ubuntu" ]]; then
        # Ubuntu uname -r формат: 6.8.0-49-generic / 6.8.0-1009-aws / ...
        local flavor="${kernel_rel##*-}"
        if [[ -n "$flavor" && "$flavor" != "$kernel_rel" ]]; then
            meta_candidates+=("linux-headers-${flavor}")
        fi
        meta_candidates+=("linux-headers-generic")
    elif [[ "${OS_ID:-}" == "debian" && -n "$arch_meta" ]]; then
        # Debian: обычное ядро 6.12.85+deb13-amd64, cloud — 6.12.85+deb13-cloud-amd64.
        [[ "$kernel_rel" == *-cloud-* ]] \
            && meta_candidates+=("linux-headers-cloud-${arch_meta}")
        meta_candidates+=("linux-headers-${arch_meta}")
    fi
    local meta meta_installed=0
    for meta in "${meta_candidates[@]}"; do
        if dpkg-query -W -f='${Status}' "$meta" 2>/dev/null \
                | grep -q 'install ok installed'; then
            log "$meta уже установлен (auto-tracking ядерных обновлений)."
            meta_installed=1
            break
        fi
        log "Установка мета-пакета $meta..."
        if DEBIAN_FRONTEND=noninteractive apt install -y "$meta" 2>/dev/null; then
            log "$meta установлен."
            meta_installed=1
            break
        fi
        log_warn "Не удалось установить $meta — пробуем следующий вариант."
    done
    if [[ ${#meta_candidates[@]} -gt 0 && $meta_installed -eq 0 ]]; then
        log_warn "Ни один meta-пакет kernel-headers не установлен — auto-rebuild при kernel upgrade может не работать."
    fi

    # v5.12.0: standalone helper /usr/local/sbin/amneziawg-ensure-module
    # вызывается из apt hook (DPkg::Post-Invoke) и из Phase 4 systemd-юнита.
    # Helper самодостаточен — не source awg_common.sh, чтобы оставаться
    # рабочим даже после ручного перемещения /root/awg/.
    #
    # Развёртывание делается через staging-файл в той же FS, что и target,
    # с финальным `mv -f` — гарантирует atomic-подмену (cross-FS rename
    # = copy+remove, НЕ atomic). Стейджинг-файл начинается с точки —
    # apt и logrotate пропускают dotfiles при сканировании каталога.
    log "Развёртывание helper'а DKMS auto-repair..."
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
        || { rm -f "$_stage_helper"; die "Не удалось chmod helper'а."; }
    mv -f "$_stage_helper" /usr/local/sbin/amneziawg-ensure-module \
        || { rm -f "$_stage_helper"; die "Не удалось развернуть helper amneziawg-ensure-module."; }
    log "Helper /usr/local/sbin/amneziawg-ensure-module развёрнут."

    # v5.12.0: apt hook DPkg::Post-Invoke вызывает helper после kernel upgrade.
    mkdir -p /etc/apt/apt.conf.d
    local _stage_hook=/etc/apt/apt.conf.d/.99-amneziawg-post-kernel.new
    cat > "$_stage_hook" <<'AWG_APT_HOOK_EOF'
// amneziawg-installer (v5.12.0+): rebuild DKMS module after kernel upgrades.
// Generated by install_amneziawg.sh — do not edit; re-run the installer to refresh.
DPkg::Post-Invoke {"if [ -x /usr/local/sbin/amneziawg-ensure-module ]; then /usr/local/sbin/amneziawg-ensure-module --hook >>/var/log/amneziawg-ensure-module.log 2>&1 || true; fi";};
AWG_APT_HOOK_EOF
    chown root:root "$_stage_hook" 2>/dev/null || true
    chmod 0644 "$_stage_hook" \
        || { rm -f "$_stage_hook"; die "Не удалось chmod apt-hook."; }
    mv -f "$_stage_hook" /etc/apt/apt.conf.d/99-amneziawg-post-kernel \
        || { rm -f "$_stage_hook"; die "Не удалось развернуть apt-hook."; }
    log "Apt-hook 99-amneziawg-post-kernel установлен (auto-rebuild при apt upgrade ядра)."

    # v5.12.0: logrotate для /var/log/amneziawg-ensure-module.log
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
        || { rm -f "$_stage_logrotate"; die "Не удалось chmod logrotate-конфиг."; }
    mv -f "$_stage_logrotate" /etc/logrotate.d/amneziawg-ensure-module \
        || { rm -f "$_stage_logrotate"; die "Не удалось развернуть logrotate-конфиг."; }
    log "Logrotate-конфиг /etc/logrotate.d/amneziawg-ensure-module установлен (weekly, rotate 4)."

    # v5.12.0 Phase 4: systemd unit гарантирует, что модуль ядра построен
    # и загружен ДО старта awg-quick@awg0 на каждом boot. Type=oneshot +
    # RemainAfterExit=yes + Before=awg-quick@awg0.service — стандартный
    # pre-load pattern (после kernel upgrade DKMS пересборка может
    # понадобиться сразу при первом boot нового ядра).
    log "Развёртывание systemd-юнита amneziawg-ensure-module.service..."
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
        || { rm -f "$_stage_unit"; die "Не удалось chmod systemd unit."; }
    mv -f "$_stage_unit" /etc/systemd/system/amneziawg-ensure-module.service \
        || { rm -f "$_stage_unit"; die "Не удалось развернуть systemd unit."; }
    if ! systemctl daemon-reload; then
        log_warn "systemctl daemon-reload завершился с ошибкой — unit может не активироваться до перезагрузки."
    fi
    if ! systemctl enable amneziawg-ensure-module.service; then
        log_warn "Не удалось enable amneziawg-ensure-module.service — boot-time auto-rebuild не будет срабатывать."
    fi
    log "Systemd-юнит amneziawg-ensure-module.service установлен и enabled (Before=awg-quick@awg0)."

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

    # Создание серверного конфига AWG 2.0 с переносом ВСЕХ существующих
    # [Peer]-блоков из бэкапа ОДНОЙ атомарной записью (render_server_config
    # доклеивает пиры в temp ДО mv). Раньше append шёл ПОСЛЕ render отдельной
    # операцией: сбой в окне между ними оставлял живой конфиг без пиров, а
    # повторный запуск шага 6 бэкапил уже безпировый файл - все клиенты
    # терялись при --force reinstall (восстановление только вручную из
    # timestamped .bak).
    # C5-история (важно сохранить семантику): восстанавливаются ВСЕ блоки,
    # включая дефолтные my_phone/my_laptop - идемпотентный цикл ниже
    # пропускает уже существующие пиры, а guard в generate_client отвергает
    # повторное создание при наличии артефактов.
    log "Создание серверного конфига..."
    render_server_config "${s_bak:-}" || die "Ошибка создания серверного конфига."
    if [[ -n "${s_bak:-}" && -f "$s_bak" ]] && grep -q '^\[Peer\]' "$s_bak" 2>/dev/null; then
        log "Существующие пиры восстановлены из бэкапа."
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

# v5.13.0: idempotency-страж — если AmneziaWG уже установлен и работает,
# повторный запуск даром тратит ~20 минут (Step 1 ещё раз настраивает sysctl/swap/BBR,
# `apt-get upgrade` может подтянуть новое ядро и заставить пользователя
# заново перезагружаться, Step 7 рестартит awg-quick@awg0 — handshake
# отваливаются на несколько секунд). Серверные ключи, пиры и параметры
# обфускации сохраняются при повторе, но без явного opt-in это поведение
# выглядит как «тихая переустановка». Защищаемся явным флагом.
# Поднимает ENV AWG_FORCE_REINSTALL=1 ровно так же, как CLI-флаг.
if [[ "${AWG_FORCE_REINSTALL:-0}" == "1" ]]; then
    FORCE_REINSTALL=1
fi
if [[ "$FORCE_REINSTALL" -ne 1 ]] && [[ -f "$SERVER_CONF_FILE" ]] \
   && systemctl is-active --quiet awg-quick@awg0 2>/dev/null; then
    log_error "AmneziaWG уже установлен и запущен."
    log_error "Чтобы переустановить — добавьте --force (или AWG_FORCE_REINSTALL=1)."
    log_error "ВНИМАНИЕ: переустановка снова прогонит шаги 1 (sysctl/swap/BBR) и 7 (рестарт сервиса)."
    log_error "          Параметры обфускации (Jc/Jmin/Jmax/H1-H4/I1) сохранятся, ЕСЛИ не передавать"
    log_error "          --preset/--jc/--jmin/--jmax (эти флаги перегенерируют весь набор - все"
    log_error "          выданные клиентские конфиги придётся перевыпустить через regen)."
    log_error "Для управления клиентами:  sudo bash $MANAGE_SCRIPT_PATH help"
    log_error "Для полного удаления:      sudo bash $0 --uninstall"
    exit 0
fi

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
