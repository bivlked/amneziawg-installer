#!/bin/bash

# Проверка минимальной версии Bash
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "ОШИБКА: Требуется Bash >= 4.0 (текущая: ${BASH_VERSION})" >&2; exit 1
fi

# ==============================================================================
# Скрипт для установки и настройки AmneziaWG 2.0 на Ubuntu 24.04 LTS Minimal
# Автор: @bivlked
# Версия: 5.1
# Дата: 2026-03-01
# Репозиторий: https://github.com/bivlked/amneziawg-installer
# ==============================================================================

# --- Безопасный режим и Константы ---
set -o pipefail

# Trap для автоочистки временных файлов (до source awg_common.sh)
_INSTALL_TEMP_FILES=()
_install_cleanup() {
    local f
    for f in "${_INSTALL_TEMP_FILES[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
}
trap _install_cleanup EXIT
AWG_DIR="/root/awg"
CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init"
STATE_FILE="$AWG_DIR/setup_state"
LOG_FILE="$AWG_DIR/install_amneziawg.log"
KEYS_DIR="$AWG_DIR/keys"
SERVER_CONF_FILE="/etc/amnezia/amneziawg/awg0.conf"
COMMON_SCRIPT_URL="https://raw.githubusercontent.com/bivlked/amneziawg-installer/main/awg_common.sh"
COMMON_SCRIPT_PATH="$AWG_DIR/awg_common.sh"
MANAGE_SCRIPT_URL="https://raw.githubusercontent.com/bivlked/amneziawg-installer/main/manage_amneziawg.sh"
MANAGE_SCRIPT_PATH="$AWG_DIR/manage_amneziawg.sh"

# Флаги CLI
UNINSTALL=0; HELP=0; DIAGNOSTIC=0; VERBOSE=0; NO_COLOR=0; AUTO_YES=0
CLI_PORT=""; CLI_SUBNET=""; CLI_DISABLE_IPV6="default"
CLI_ROUTING_MODE="default"; CLI_CUSTOM_ROUTES=""; CLI_ENDPOINT=""

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
    safe_msg=$(echo "$msg" | sed 's/%/%%/g')
    local entry="[$ts] $type: $safe_msg"
    local color_start="" color_end="\033[0m"

    if [[ "$NO_COLOR" -eq 0 ]]; then
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
    else
        printf "${color_start}%s${color_end}\n" "$entry"
    fi
}

log()       { log_msg "INFO" "$1"; }
log_warn()  { log_msg "WARN" "$1"; }
log_error() { log_msg "ERROR" "$1"; }
log_debug() { if [[ "$VERBOSE" -eq 1 ]]; then log_msg "DEBUG" "$1"; fi; }
die()       { log_error "КРИТИЧЕСКАЯ ОШИБКА: $1"; log_error "Установка прервана. Лог: $LOG_FILE"; exit 1; }

# ==============================================================================
# Справка
# ==============================================================================

show_help() {
    cat << 'EOF'
Использование: sudo bash install_amneziawg.sh [ОПЦИИ]
Скрипт для автоматической установки и настройки AmneziaWG 2.0 на Ubuntu 24.04.

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

Примеры:
  sudo bash install_amneziawg.sh                             # Интерактивная установка
  sudo bash install_amneziawg.sh --port=51820 --route-all    # Неинтерактивная
  sudo bash install_amneziawg.sh --route-amnezia --yes       # Полностью автоматическая
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
    # Атомарная запись с flock для предотвращения race condition
    (
        flock -x 200
        echo "$next_step" > "$STATE_FILE" || die "Ошибка записи состояния"
    ) 200>"${STATE_FILE}.lock"
    log "Состояние: следующий шаг - $next_step"
}

request_reboot() {
    local next_step=$1
    update_state "$next_step"
    echo "" >> "$LOG_FILE"
    log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    log_warn "!!! ТРЕБУЕТСЯ ПЕРЕЗАГРУЗКА СИСТЕМЫ                        !!!"
    log_warn "!!! После перезагрузки, запустите скрипт снова командой:   !!!"
    log_warn "!!! sudo bash $0 [с теми же параметрами, если были]       !!!"
    log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "" >> "$LOG_FILE"
    local confirm="y"
    if [[ "$AUTO_YES" -eq 0 ]]; then
        read -p "Перезагрузить сейчас? [y/N]: " confirm < /dev/tty
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
    if ! command -v lsb_release &>/dev/null; then
        log_warn "lsb_release не найден."
        return 0
    fi
    local os_id os_ver
    os_id=$(lsb_release -si)
    os_ver=$(lsb_release -sr)
    if [[ "$os_id" != "Ubuntu" || "$os_ver" != "24.04" ]]; then
        log_warn "Обнаружена $os_id $os_ver. Скрипт разработан для Ubuntu 24.04 LTS."
        if [[ "$AUTO_YES" -eq 0 ]]; then
            read -p "Продолжить? [y/N]: " confirm < /dev/tty
            if ! [[ "$confirm" =~ ^[Yy]$ ]]; then die "Отмена."; fi
        else
            log "Продолжаем на $os_id $os_ver (--yes)."
        fi
    else
        log "ОС: Ubuntu $os_ver (OK)"
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
            read -p "Продолжить? [y/N]: " confirm < /dev/tty
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
    apt update -y || log_warn "Не удалось обновить apt."
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
        read -p "Отключить IPv6 (рекомендуется)? [Y/n]: " dis_ipv6 < /dev/tty
        if [[ "$dis_ipv6" =~ ^[Nn]$ ]]; then
            DISABLE_IPV6=0
        else
            DISABLE_IPV6=1
        fi
    fi
    export DISABLE_IPV6
    log "Отключение IPv6: $(if [ "$DISABLE_IPV6" -eq 1 ]; then echo 'Да'; else echo 'Нет'; fi)"
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
        read -p "Ваш выбор [2]: " r_mode < /dev/tty
        ALLOWED_IPS_MODE=${r_mode:-2}
    fi
    case "$ALLOWED_IPS_MODE" in
        1) ALLOWED_IPS="0.0.0.0/0"
           log "Выбран режим: Весь трафик." ;;
        3) if [[ -z "$CLI_CUSTOM_ROUTES" ]]; then
               read -p "Введите сети (a.b.c.d/xx,...): " custom < /dev/tty
               ALLOWED_IPS=$custom
           else
               ALLOWED_IPS=$CLI_CUSTOM_ROUTES
           fi
           if ! echo "$ALLOWED_IPS" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}(,([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2})*$'; then
               log_warn "Формат сетей ('$ALLOWED_IPS') некорректен."
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

# Генерация 4 непересекающихся диапазонов H1-H4
# Стратегия: 4 сектора в пространстве uint32
generate_h_ranges() {
    # Секторы:
    #   H1: [100000 — 800000]
    #   H2: [1000000 — 8000000]
    #   H3: [10000000 — 80000000]
    #   H4: [100000000 — 800000000]
    local sectors_lo=(100000 1000000 10000000 100000000)
    local sectors_hi=(800000 8000000 80000000 800000000)
    local results=()
    local i

    for i in 0 1 2 3; do
        local lo=${sectors_lo[$i]}
        local hi=${sectors_hi[$i]}
        local sector_range=$((hi - lo))
        local start end span

        start=$(( lo + $(rand_range 0 $((sector_range / 2))) ))
        span=$(rand_range 10000 $((sector_range / 4)))
        end=$((start + span))
        if [[ $end -gt $hi ]]; then end=$hi; fi

        results+=("${start}-${end}")
    done

    echo "${results[0]}"
    echo "${results[1]}"
    echo "${results[2]}"
    echo "${results[3]}"
}

# Генерация CPS строки для I1
# Формат: "<r N>" где N — количество случайных байт (32-256)
generate_cps_i1() {
    local n
    n=$(rand_range 32 256)
    echo "<r ${n}>"
}

# Генерация всех AWG 2.0 параметров
generate_awg_params() {
    log "Генерация параметров AWG 2.0..."

    AWG_Jc=$(rand_range 4 8)
    AWG_Jmin=$(rand_range 40 89)
    AWG_Jmax=$(( AWG_Jmin + $(rand_range 100 999) ))
    AWG_S1=$(rand_range 15 150)
    AWG_S2=$(rand_range 15 150)

    # Критическое ограничение из kernel: S1+56 != S2
    # Предотвращает одинаковый размер init и response сообщений
    while [[ $((AWG_S1 + 56)) -eq $AWG_S2 ]]; do
        AWG_S2=$(rand_range 15 150)
    done

    AWG_S3=$(rand_range 8 55)
    AWG_S4=$(rand_range 4 27)

    # H1-H4: непересекающиеся диапазоны
    local h_ranges
    h_ranges=$(generate_h_ranges)
    AWG_H1=$(echo "$h_ranges" | sed -n '1p')
    AWG_H2=$(echo "$h_ranges" | sed -n '2p')
    AWG_H3=$(echo "$h_ranges" | sed -n '3p')
    AWG_H4=$(echo "$h_ranges" | sed -n '4p')

    # I1: CPS concealment
    AWG_I1=$(generate_cps_i1)

    export AWG_Jc AWG_Jmin AWG_Jmax AWG_S1 AWG_S2 AWG_S3 AWG_S4
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
    local packages_to_remove=()
    local pkg
    for pkg in snapd modemmanager networkd-dispatcher unattended-upgrades packagekit lxd-agent-loader udisks2; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
            packages_to_remove+=("$pkg")
        fi
    done

    if [ ${#packages_to_remove[@]} -gt 0 ]; then
        log "Удаление: ${packages_to_remove[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get purge -y "${packages_to_remove[@]}" || log_warn "Ошибка удаления некоторых пакетов"
    fi

    # Очистка snap артефактов
    if [[ -d /snap ]]; then
        log "Очистка snap артефактов..."
        rm -rf /snap /var/snap /var/lib/snapd 2>/dev/null || log_warn "Ошибка очистки snap"
    fi

    # cloud-init: удалять только если НЕ управляет сетью
    if dpkg-query -W -f='${Status}' cloud-init 2>/dev/null | grep -q "ok installed"; then
        local cloud_manages_network=0
        if [[ -d /etc/netplan ]]; then
            # Проверяем содержимое и имена файлов netplan
            if grep -rq "renderer.*NetworkManager\|renderer.*networkd" /etc/netplan/ 2>/dev/null; then
                cloud_manages_network=0
            elif grep -rq "cloud-init" /etc/netplan/ 2>/dev/null; then
                cloud_manages_network=1
            elif ls /etc/netplan/*cloud-init* &>/dev/null; then
                cloud_manages_network=1
            fi
        else
            # Нет netplan — cloud-init может управлять сетью через /etc/network/
            if [[ -f /etc/network/interfaces ]] && grep -q "cloud-init" /etc/network/interfaces 2>/dev/null; then
                cloud_manages_network=1
            fi
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
# Автоматически сгенерировано install_amneziawg.sh v5.1

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
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
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

    if ufw status | grep -q inactive; then
        log "UFW неактивен. Настройка..."
        ufw default deny incoming
        ufw default allow outgoing
        ufw limit 22/tcp comment "SSH Rate Limit"
        ufw allow "${AWG_PORT}/udp" comment "AmneziaWG VPN"
        log "Правила UFW добавлены."
        log_warn "--- ВКЛЮЧЕНИЕ UFW ---"
        log_warn "Проверьте SSH доступ!"
        local confirm_ufw="y"
        if [[ "$AUTO_YES" -eq 0 ]]; then
            sleep 5
            read -p "Включить UFW? [y/N]: " confirm_ufw < /dev/tty
        else
            log "Автоматическое включение UFW (--yes)."
        fi
        if ! [[ "$confirm_ufw" =~ ^[Yy]$ ]]; then
            log_warn "UFW не включен."
            return 1
        fi
        if ! ufw enable <<< "y"; then die "Ошибка включения UFW."; fi
        log "UFW включен."
    else
        log "UFW активен. Обновление правил..."
        ufw limit 22/tcp comment "SSH Rate Limit"
        ufw allow "${AWG_PORT}/udp" comment "AmneziaWG VPN"
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
    cat > /etc/fail2ban/jail.local << 'EOF' || { log_warn "Ошибка записи jail.local"; return 1; }
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
banaction = ufw

[sshd]
enabled = true
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
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
        port_check=$(source "$CONFIG_FILE" && echo "$AWG_PORT")
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
        echo "Generated: $(date)"
        echo "Hostname: $(hostname)"
        echo "Installer: v5.1"
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
        cat "$CONFIG_FILE" 2>/dev/null || echo "File not found"
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
    local confirm="yes" backup="Y"
    if [[ "$AUTO_YES" -eq 0 ]]; then
        read -p "Уверены? (введите 'yes'): " confirm < /dev/tty
        if [[ "$confirm" != "yes" ]]; then log "Деинсталляция отменена."; exit 1; fi
        read -p "Создать бэкап перед удалением? [Y/n]: " backup < /dev/tty
    else
        log "Автоматическое подтверждение деинсталляции (--yes)."
    fi
    if [[ -z "$backup" || "$backup" =~ ^[Yy]$ ]]; then
        local bf
        bf="$HOME/awg_uninstall_backup_$(date +%F_%T).tar.gz"
        log "Создание бэкапа: $bf"
        tar -czf "$bf" -C / etc/amnezia "$AWG_DIR" --ignore-failed-read 2>/dev/null || log_warn "Ошибка создания бэкапа $bf"
        chmod 600 "$bf" || log_warn "Ошибка chmod бэкапа"
        log "Бэкап создан: $bf"
    fi
    log "Остановка сервиса..."
    systemctl stop awg-quick@awg0 2>/dev/null
    systemctl disable awg-quick@awg0 2>/dev/null
    log "Снятие блокировок Fail2Ban..."
    if command -v fail2ban-client &>/dev/null; then
        fail2ban-client unban --all 2>/dev/null || true
        systemctl stop fail2ban 2>/dev/null
    fi
    log "Удаление правил UFW..."
    if command -v ufw &>/dev/null; then
        local port_to_del
        if [[ -f "$CONFIG_FILE" ]]; then
            # shellcheck source=/dev/null
            port_to_del=$(source "$CONFIG_FILE" && echo "$AWG_PORT")
        fi
        port_to_del=${port_to_del:-39743}
        ufw delete allow "${port_to_del}/udp" 2>/dev/null
        log "Отключение UFW..."
        ufw --force disable 2>/dev/null
    fi
    log "Удаление пакетов..."
    DEBIAN_FRONTEND=noninteractive apt-get purge -y amneziawg-dkms amneziawg-tools fail2ban qrencode 2>/dev/null || log_warn "Ошибка purge."
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>/dev/null || log_warn "Ошибка autoremove."
    log "Удаление PPA и файлов..."
    rm -f /etc/apt/sources.list.d/amnezia-ppa.sources \
        /etc/apt/sources.list.d/amnezia-ubuntu-ppa-*.list \
        /etc/apt/sources.list.d/amnezia-ubuntu-ppa-*.sources \
        /etc/apt/keyrings/amnezia-ppa.gpg 2>/dev/null
    rm -rf /etc/amnezia "$AWG_DIR" \
        /etc/modules-load.d/amneziawg.conf \
        /etc/sysctl.d/99-amneziawg-security.conf \
        /etc/logrotate.d/amneziawg* \
        /etc/fail2ban/jail.local || log_warn "Ошибка удаления файлов."
    log "Удаление DKMS..."
    rm -rf /var/lib/dkms/amneziawg* || log_warn "Ошибка удаления DKMS."
    log "Восстановление sysctl..."
    if grep -q "disable_ipv6" /etc/sysctl.conf 2>/dev/null; then
        sed -i '/disable_ipv6/d' /etc/sysctl.conf || log_warn "Ошибка sed sysctl.conf"
    fi
    sysctl -p --system 2>/dev/null
    log "Удаление cron и скриптов..."
    rm -f /etc/cron.d/*amneziawg* /usr/local/bin/*amneziawg*.sh 2>/dev/null
    log "=== ДЕИНСТАЛЛЯЦИЯ ЗАВЕРШЕНА ==="
    exit 0
}

# ==============================================================================
# ШАГ 0: Инициализация
# ==============================================================================

initialize_setup() {
    mkdir -p "$AWG_DIR" || die "Ошибка создания $AWG_DIR"
    chown root:root "$AWG_DIR"
    touch "$LOG_FILE" || die "Не удалось создать лог-файл $LOG_FILE"
    chmod 640 "$LOG_FILE"
    log "--- НАЧАЛО УСТАНОВКИ AmneziaWG 2.0 (v5.1) ---"
    log "### ШАГ 0: Инициализация и проверка параметров ###"
    if [ "$(id -u)" -ne 0 ]; then die "Запустите скрипт от root (sudo bash $0)."; fi
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
        source "$CONFIG_FILE" || log_warn "Не удалось полностью загрузить настройки из $CONFIG_FILE."
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
    if [[ -n "$CLI_ENDPOINT" ]]; then AWG_ENDPOINT=$CLI_ENDPOINT; fi

    # Запрос у пользователя только на первом запуске
    if [[ "$config_exists" -eq 0 ]]; then
        log "Запрос настроек у пользователя (первый запуск)."
        if [[ "$AUTO_YES" -eq 0 ]]; then
            read -p "Введите UDP порт AmneziaWG (1024-65535) [${AWG_PORT}]: " input_port < /dev/tty
            if [[ -n "$input_port" ]]; then AWG_PORT=$input_port; fi
        fi
        if ! [[ "$AWG_PORT" =~ ^[0-9]+$ ]] || [ "$AWG_PORT" -lt 1024 ] || [ "$AWG_PORT" -gt 65535 ]; then
            die "Некорректный порт."
        fi
        if [[ "$AUTO_YES" -eq 0 ]]; then
            read -p "Введите подсеть туннеля [${AWG_TUNNEL_SUBNET}]: " input_subnet < /dev/tty
            if [[ -n "$input_subnet" ]]; then AWG_TUNNEL_SUBNET=$input_subnet; fi
        fi
        if ! [[ "$AWG_TUNNEL_SUBNET" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            die "Некорректная подсеть: '$AWG_TUNNEL_SUBNET'."
        fi
        if [[ "$DISABLE_IPV6" == "default" ]]; then configure_ipv6; fi
        if [[ "$ALLOWED_IPS_MODE" == "default" ]]; then configure_routing_mode; fi
    else
        log "Используются настройки из $CONFIG_FILE."
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

    # Генерация AWG 2.0 параметров (только на первом запуске)
    if [[ -z "${AWG_Jc:-}" ]]; then
        generate_awg_params
    else
        log "AWG 2.0 параметры уже заданы из конфига."
    fi

    # Сохранение конфигурации
    log "Сохранение настроек в $CONFIG_FILE..."
    local temp_conf
    temp_conf=$(mktemp) || die "Ошибка mktemp."
    cat > "$temp_conf" << EOF
# Конфигурация установки AmneziaWG 2.0 (Авто-генерация)
# Используется скриптами установки и управления
export AWG_PORT=${AWG_PORT}
export AWG_TUNNEL_SUBNET='${AWG_TUNNEL_SUBNET}'
export DISABLE_IPV6=${DISABLE_IPV6}
export ALLOWED_IPS_MODE=${ALLOWED_IPS_MODE}
export ALLOWED_IPS='$(echo "$ALLOWED_IPS" | sed 's/\\,/,/g')'
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
    cleanup_system

    log "Обновление списка пакетов..."
    apt update -y || die "Ошибка apt update."

    log "Разблокировка dpkg..."
    if ! apt-get check &>/dev/null; then
        log_warn "dpkg заблокирован или повреждён, исправление..."
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a || log_warn "dpkg --configure -a."
    fi

    log "Обновление системы..."
    DEBIAN_FRONTEND=noninteractive apt full-upgrade -y || die "Ошибка apt full-upgrade."
    log "Система обновлена."

    install_packages curl wget gpg sudo ethtool

    # Оптимизация системы
    optimize_system

    # Настройка sysctl
    setup_advanced_sysctl

    log "Шаг 1 успешно завершен."
    request_reboot 2
}

# ==============================================================================
# ШАГ 2: Установка AmneziaWG и зависимостей
# ==============================================================================

step2_install_amnezia() {
    update_state 2
    log "### ШАГ 2: Установка AmneziaWG и зависимостей ###"

    local sources_file="/etc/apt/sources.list.d/ubuntu.sources"

    # Включение deb-src
    log "Проверка/включение deb-src..."
    if [[ -f "$sources_file" ]]; then
        if grep -q "^Types: deb$" "$sources_file"; then
            log "Включение deb-src..."
            local bak
            bak="${sources_file}.bak-$(date +%F_%T)"
            cp "$sources_file" "$bak" || log_warn "Ошибка бэкапа"
            local tmp_sed
            tmp_sed=$(mktemp)
            sed '/^Types: deb$/s/Types: deb/Types: deb deb-src/' "$sources_file" > "$tmp_sed" || {
                rm -f "$tmp_sed"; die "Ошибка sed."
            }
            if ! mv "$tmp_sed" "$sources_file"; then
                rm -f "$tmp_sed"; die "Ошибка mv $sources_file"
            fi
            apt update -y || die "Ошибка apt update."
        else
            apt update -y
        fi
    else
        log_warn "$sources_file не найден, пропуск deb-src."
        apt update -y
    fi

    # PPA Amnezia (без software-properties-common)
    log "Добавление PPA Amnezia..."
    local codename
    codename=$(lsb_release -sc 2>/dev/null || echo "noble")
    local keyring_dir="/etc/apt/keyrings"
    local keyring_file="${keyring_dir}/amnezia-ppa.gpg"
    local ppa_sources="/etc/apt/sources.list.d/amnezia-ppa.sources"
    # Проверка на legacy-файлы (от add-apt-repository предыдущих версий)
    local legacy_list="/etc/apt/sources.list.d/amnezia-ubuntu-ppa-${codename}.list"
    local legacy_sources="/etc/apt/sources.list.d/amnezia-ubuntu-ppa-${codename}.sources"
    if [[ -f "$legacy_list" ]] || [[ -f "$legacy_sources" ]]; then
        log "PPA уже добавлен (legacy-формат)."
    elif [[ -f "$ppa_sources" ]]; then
        log "PPA уже добавлен."
    else
        mkdir -p "$keyring_dir"
        log "Импорт GPG ключа Amnezia PPA..."
        curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x57290828" \
            | gpg --dearmor -o "$keyring_file" \
            || die "Ошибка импорта GPG ключа Amnezia PPA."
        chmod 644 "$keyring_file"
        cat > "$ppa_sources" <<PPASRC || die "Ошибка создания sources PPA."
Types: deb
URIs: https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu
Suites: ${codename}
Components: main
Signed-By: ${keyring_file}
PPASRC
        chmod 644 "$ppa_sources"
        log "PPA добавлен."
    fi
    apt update -y || die "Ошибка apt update."

    # Пакеты AmneziaWG + qrencode (БЕЗ Python!)
    log "Установка пакетов AmneziaWG..."
    local packages=("amneziawg-dkms" "amneziawg-tools" "wireguard-tools" "dkms"
                    "linux-headers-$(uname -r)" "build-essential" "dpkg-dev" "qrencode")
    if ! dpkg -s "linux-headers-$(uname -r)" &>/dev/null; then
        log_warn "Нет headers для $(uname -r)..."
        packages+=("linux-headers-generic")
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
    cv=$(modinfo amneziawg 2>/dev/null | grep vermagic | awk '{print $2}') || cv="?"
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
    log "### ШАГ 4: Настройка фаервола UFW ###"
    install_packages ufw
    setup_improved_firewall || die "Ошибка настройки UFW."
    log "Шаг 4 завершен."
    update_state 5
}

# ==============================================================================
# ШАГ 5: Скачивание скриптов (БЕЗ Python!)
# ==============================================================================

step5_download_scripts() {
    update_state 5
    log "### ШАГ 5: Скачивание скриптов управления ###"
    cd "$AWG_DIR" || die "Ошибка перехода в $AWG_DIR"

    # Скачивание awg_common.sh
    log "Скачивание $COMMON_SCRIPT_PATH..."
    if curl -fLso "$COMMON_SCRIPT_PATH" "$COMMON_SCRIPT_URL"; then
        chmod 700 "$COMMON_SCRIPT_PATH" || die "Ошибка chmod awg_common.sh"
        log "awg_common.sh скачан."
    else
        die "Ошибка скачивания awg_common.sh"
    fi

    # Скачивание manage_amneziawg.sh
    log "Скачивание $MANAGE_SCRIPT_PATH..."
    if curl -fLso "$MANAGE_SCRIPT_PATH" "$MANAGE_SCRIPT_URL"; then
        chmod 700 "$MANAGE_SCRIPT_PATH" || die "Ошибка chmod manage_amneziawg.sh"
        log "manage_amneziawg.sh скачан."
    else
        log_error "Ошибка скачивания manage_amneziawg.sh"
    fi

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

    # Создание серверного конфига AWG 2.0
    log "Создание серверного конфига..."
    render_server_config || die "Ошибка создания серверного конфига."

    # Бэкап серверного конфига
    local s_bak
    s_bak="${SERVER_CONF_FILE}.bak-$(date +%F_%T)"
    cp "$SERVER_CONF_FILE" "$s_bak" || log_warn "Ошибка бэкапа $s_bak"
    log "Бэкап серверного конфига: $s_bak"

    # Генерация клиентов по умолчанию
    log "Создание клиентов по умолчанию..."
    local client_name
    for client_name in my_phone my_laptop; do
        if grep -q "^#_Name = ${client_name}$" "$SERVER_CONF_FILE" 2>/dev/null; then
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
    systemctl enable --now awg-quick@awg0 || die "Ошибка enable --now."
    log "Сервис включен и запущен."

    log "Проверка статуса сервиса..."
    sleep 3
    check_service_status || die "Проверка статуса сервиса не пройдена."

    # Fail2Ban
    setup_fail2ban

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
    log "Очистка apt..."
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
    rm -f "$STATE_FILE" || log_warn "Не удалось удалить $STATE_FILE"
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

current_step=0
if [[ -f "$STATE_FILE" ]]; then current_step=$(cat "$STATE_FILE"); fi
if ! [[ "$current_step" =~ ^[0-9]+$ ]]; then current_step=1; fi

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
