#!/bin/bash

# Проверка минимальной версии Bash
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "ОШИБКА: Требуется Bash >= 4.0 (текущая: ${BASH_VERSION})" >&2; exit 1
fi

# ==============================================================================
# Скрипт для управления пользователями (пирами) AmneziaWG 2.0
# Автор: @bivlked
# Версия: 5.1
# Дата: 2026-03-01
# Репозиторий: https://github.com/bivlked/amneziawg-installer
# ==============================================================================

# --- Безопасный режим и Константы ---
set -o pipefail
AWG_DIR="/root/awg"
SERVER_CONF_FILE="/etc/amnezia/amneziawg/awg0.conf"
CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init"
KEYS_DIR="$AWG_DIR/keys"
COMMON_SCRIPT_PATH="$AWG_DIR/awg_common.sh"
LOG_FILE="$AWG_DIR/manage_amneziawg.log"
NO_COLOR=0
VERBOSE_LIST=0

# --- Обработка аргументов ---
COMMAND=""
ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)         COMMAND="help"; break ;;
        -v|--verbose)      VERBOSE_LIST=1; shift ;;
        --no-color)        NO_COLOR=1; shift ;;
        --conf-dir=*)      AWG_DIR="${1#*=}"; shift ;;
        --server-conf=*)   SERVER_CONF_FILE="${1#*=}"; shift ;;
        --*)               echo "Неизвестная опция: $1" >&2; COMMAND="help"; break ;;
        *)
            if [[ -z "$COMMAND" ]]; then
                COMMAND=$1
            else
                ARGS+=("$1")
            fi
            shift ;;
    esac
done
ARGS+=("$@")
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
    if ! is_interactive; then return 0; fi
    local action="$1" subject="$2"
    read -p "Вы действительно хотите $action $subject? [y/N]: " confirm < /dev/tty
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
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

backup_configs() {
    log "Создание бэкапа..."
    local bd="$AWG_DIR/backups"
    mkdir -p "$bd" || die "Ошибка mkdir $bd"
    local ts bf td
    ts=$(date +%F_%T)
    bf="$bd/awg_backup_${ts}.tar.gz"
    td=$(mktemp -d)

    mkdir -p "$td/server" "$td/clients" "$td/keys"
    cp -a "$SERVER_CONF_FILE"* "$td/server/" 2>/dev/null
    cp -a "$AWG_DIR"/*.conf "$AWG_DIR"/*.png "$CONFIG_FILE" "$td/clients/" 2>/dev/null || true
    cp -a "$KEYS_DIR"/* "$td/keys/" 2>/dev/null || true
    cp -a "$AWG_DIR/server_private.key" "$AWG_DIR/server_public.key" "$td/" 2>/dev/null || true

    tar -czf "$bf" -C "$td" . || { rm -rf "$td"; die "Ошибка tar $bf"; }
    rm -rf "$td"
    chmod 600 "$bf" || log_warn "Ошибка chmod бэкапа"

    # Оставляем максимум 10 бэкапов
    find "$bd" -maxdepth 1 -name "awg_backup_*.tar.gz" -printf '%T@ %p\n' | \
        sort -nr | tail -n +11 | cut -d' ' -f2- | xargs -r rm -f || \
        log_warn "Ошибка удаления старых бэкапов"

    log "Бэкап создан: $bf"
}

restore_backup() {
    local bf="$1"
    local bd="$AWG_DIR/backups"

    if [[ -z "$bf" ]]; then
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

        read -p "Номер для восстановления (0-отмена): " choice < /dev/tty
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -eq 0 ]] || [[ "$choice" -ge "$i" ]]; then
            log "Отмена."
            return 1
        fi
        bf="${bl[$choice]}"
    fi

    if [[ ! -f "$bf" ]]; then die "Файл бэкапа '$bf' не найден."; fi
    log "Восстановление из $bf"
    if ! confirm_action "восстановить" "конфигурацию из '$bf'"; then return 1; fi

    log "Создание бэкапа текущей..."
    backup_configs

    local td
    td=$(mktemp -d)
    if ! tar -xzf "$bf" -C "$td"; then
        log_error "Ошибка tar $bf"
        rm -rf "$td"
        return 1
    fi

    log "Остановка сервиса..."
    systemctl stop awg-quick@awg0 || log_warn "Сервис не остановлен."

    if [[ -d "$td/server" ]]; then
        log "Восстановление конфига сервера..."
        cp -a "$td/server/"* /etc/amnezia/amneziawg/ || log_error "Ошибка копирования server"
        chmod 600 /etc/amnezia/amneziawg/*.conf
        chmod 700 /etc/amnezia/amneziawg
    fi

    if [[ -d "$td/clients" ]]; then
        log "Восстановление файлов клиентов..."
        cp -a "$td/clients/"* "$AWG_DIR/" || log_error "Ошибка копирования clients"
        chmod 600 "$AWG_DIR"/*.conf 2>/dev/null
        chmod 600 "$CONFIG_FILE" 2>/dev/null
    fi

    if [[ -d "$td/keys" ]]; then
        log "Восстановление ключей..."
        mkdir -p "$KEYS_DIR"
        cp -a "$td/keys/"* "$KEYS_DIR/" || log_error "Ошибка копирования keys"
        chmod 600 "$KEYS_DIR"/* 2>/dev/null
    fi

    # Серверные ключи
    [[ -f "$td/server_private.key" ]] && cp -a "$td/server_private.key" "$AWG_DIR/"
    [[ -f "$td/server_public.key" ]] && cp -a "$td/server_public.key" "$AWG_DIR/"

    rm -rf "$td"

    log "Запуск сервиса..."
    if ! systemctl start awg-quick@awg0; then
        log_error "Ошибка запуска сервиса!"
        systemctl status awg-quick@awg0 --no-pager | log_msg "ERROR"
        return 1
    fi
    log "Восстановление завершено."
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

    if ! grep -q "^#_Name = ${name}$" "$SERVER_CONF_FILE"; then
        die "Клиент '$name' не найден."
    fi

    local cf="$AWG_DIR/$name.conf"
    if [[ ! -f "$cf" ]]; then die "Файл $cf не найден."; fi

    if ! grep -q -E "^${param}\s*=" "$cf"; then
        log_error "Параметр '$param' не найден в $cf."
        return 1
    fi

    log "Изменение '$param' на '$value' для '$name'..."
    local bak
    bak="${cf}.bak-$(date +%F_%T)"
    cp "$cf" "$bak" || log_warn "Ошибка бэкапа $bak"
    log "Бэкап: $bak"

    local escaped_value
    escaped_value=$(escape_sed "$value")
    if ! sed -i "s#^${param} = .*#${param} = ${escaped_value}#" "$cf"; then
        log_error "Ошибка sed. Восстановление..."
        cp "$bak" "$cf" || log_warn "Ошибка восстановления."
        return 1
    fi

    log "Параметр '$param' изменен."

    # Перегенерация QR для важных параметров
    if [[ "$param" =~ ^(AllowedIPs|Address|PublicKey|Endpoint|PrivateKey|DNS)$ ]]; then
        log "Перегенерация QR-кода..."
        generate_qr "$name" || log_warn "Не удалось обновить QR-код."
    fi

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
    # shellcheck source=/dev/null
    source "$CONFIG_FILE" 2>/dev/null
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
        if ! ufw status | grep -qw "${port}/udp"; then
            log_warn " - Правило UFW для ${port}/udp не найдено!"
        else
            log " - Правило UFW для ${port}/udp есть."
        fi
    else
        log_warn " - UFW не установлен."
    fi

    log "Статус AmneziaWG 2.0:"
    while IFS= read -r line; do log "  $line"; done < <(awg show)

    # AWG 2.0 диагностика
    if awg show awg0 2>/dev/null | grep -q "jc:"; then
        log " - AWG 2.0 параметры обфускации: активны"
    else
        log_warn " - AWG 2.0 параметры обфускации не обнаружены"
    fi

    if [[ "$ok" -eq 1 ]]; then
        log "Проверка завершена: Состояние OK."
    else
        log_error "Проверка завершена: ОБНАРУЖЕНЫ ПРОБЛЕМЫ!"
    fi
    return $ok
}

# ==============================================================================
# Список клиентов
# ==============================================================================

list_clients() {
    log "Получение списка клиентов..."
    local clients
    clients=$(grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //' | sort) || clients=""
    if [[ -z "$clients" ]]; then
        log "Клиенты не найдены."
        return 0
    fi

    local verbose=$VERBOSE_LIST
    local awg_stat act=0 tot=0
    awg_stat=$(awg show 2>/dev/null) || awg_stat=""

    if [[ $verbose -eq 1 ]]; then
        printf "%-20s | %-7s | %-7s | %-15s | %-15s | %s\n" "Имя клиента" "Conf" "QR" "IP-адрес" "Ключ (нач.)" "Статус"
        printf -- "-%.0s" {1..85}
        echo
    else
        printf "%-20s | %-7s | %-7s | %s\n" "Имя клиента" "Conf" "QR" "Статус"
        printf -- "-%.0s" {1..50}
        echo
    fi

    while IFS= read -r name; do
        name=$(echo "$name" | xargs)
        if [[ -z "$name" ]]; then continue; fi
        ((tot++))

        local cf="?" png="?" pk="-" ip="-" st="Нет данных"
        local color_start="\033[0m" color_end="\033[0m"
        if [[ "$NO_COLOR" -eq 0 ]]; then color_start="\033[0;37m"; fi

        [[ -f "$AWG_DIR/${name}.conf" ]] && cf="+"
        [[ -f "$AWG_DIR/${name}.png" ]] && png="+"

        if [[ "$cf" == "+" ]]; then
            ip=$(grep -oP 'Address = \K[0-9.]+' "$AWG_DIR/${name}.conf" 2>/dev/null) || ip="?"

            # Извлекаем публичный ключ из серверного конфига
            local current_pk=""
            local peer_block_started=0
            while IFS= read -r line || [[ -n "$line" ]]; do
                if [[ "$line" == "[Peer]"* && "$peer_block_started" -eq 1 ]]; then break; fi
                if [[ "$line" == "#_Name = ${name}" ]]; then peer_block_started=1; fi
                if [[ "$peer_block_started" -eq 1 && "$line" == "PublicKey = "* ]]; then
                    current_pk=$(echo "$line" | cut -d' ' -f3)
                    break
                fi
            done < "$SERVER_CONF_FILE"

            if [[ -n "$current_pk" ]]; then
                pk=$(echo "$current_pk" | head -c 10)"..."
                if echo "$awg_stat" | grep -qF "$current_pk"; then
                    local handshake_line
                    handshake_line=$(echo "$awg_stat" | grep -A 3 -F "$current_pk" | grep 'latest handshake:')
                    if [[ -n "$handshake_line" && ! "$handshake_line" =~ "never" ]]; then
                        if echo "$handshake_line" | grep -q "seconds ago"; then
                            local sec
                            sec=$(echo "$handshake_line" | grep -oP '\d+(?= seconds ago)')
                            if [[ "$sec" -lt 180 ]]; then
                                st="Активен"
                                color_start="\033[0;32m"
                                ((act++))
                            else
                                st="Недавно"
                                color_start="\033[0;33m"
                                ((act++))
                            fi
                        else
                            st="Недавно"
                            color_start="\033[0;33m"
                            ((act++))
                        fi
                    else
                        st="Нет handshake"
                        color_start="\033[0;37m"
                    fi
                else
                    st="Не найден"
                    color_start="\033[0;31m"
                fi
            else
                pk="?"
                st="Ошибка ключа"
                color_start="\033[0;31m"
            fi
        fi

        if [[ $verbose -eq 1 ]]; then
            printf "%-20s | %-7s | %-7s | %-15s | %-15s | ${color_start}%s${color_end}\n" "$name" "$cf" "$png" "$ip" "$pk" "$st"
        else
            printf "%-20s | %-7s | %-7s | ${color_start}%s${color_end}\n" "$name" "$cf" "$png" "$st"
        fi
    done <<< "$clients"
    echo ""
    log "Всего клиентов: $tot, Активных/Недавно: $act"
}

# ==============================================================================
# Справка
# ==============================================================================

usage() {
    exec >&2
    echo ""
    echo "Скрипт управления AmneziaWG 2.0 (v5.1)"
    echo "=============================================="
    echo "Использование: $0 [ОПЦИИ] <КОМАНДА> [АРГУМЕНТЫ]"
    echo ""
    echo "Опции:"
    echo "  -h, --help            Показать эту справку"
    echo "  -v, --verbose         Расширенный вывод (для команды list)"
    echo "  --no-color            Отключить цветной вывод"
    echo "  --conf-dir=ПУТЬ       Указать директорию AWG (умолч: $AWG_DIR)"
    echo "  --server-conf=ПУТЬ    Указать файл конфига сервера"
    echo ""
    echo "Команды:"
    echo "  add <имя>             Добавить клиента"
    echo "  remove <имя>          Удалить клиента"
    echo "  list [-v]             Показать список клиентов"
    echo "  regen [имя]           Перегенерировать файлы клиента(ов)"
    echo "  modify <имя> <пар> <зн> Изменить параметр клиента"
    echo "  backup                Создать бэкап"
    echo "  restore [файл]        Восстановить из бэкапа"
    echo "  check | status        Проверить состояние сервера"
    echo "  show                  Показать статус \`awg show\`"
    echo "  restart               Перезапустить сервис AmneziaWG"
    echo "  help                  Показать эту справку"
    echo ""
    echo "ВАЖНО: После 'add', 'remove' перезапустите сервис:"
    echo "  sudo systemctl restart awg-quick@awg0 (или $0 restart)"
    echo ""
    exit 1
}

# ==============================================================================
# Основная логика
# ==============================================================================

check_dependencies || exit 1
cd "$AWG_DIR" || die "Ошибка перехода в $AWG_DIR"

if [[ -z "$COMMAND" ]]; then usage; fi

log "Запуск команды '$COMMAND'..."

case $COMMAND in
    add)
        [[ -z "$CLIENT_NAME" ]] && die "Не указано имя клиента."
        validate_client_name "$CLIENT_NAME" || exit 1

        if grep -q "^#_Name = ${CLIENT_NAME}$" "$SERVER_CONF_FILE"; then
            die "Клиент '$CLIENT_NAME' уже существует."
        fi

        log "Добавление '$CLIENT_NAME'..."
        if generate_client "$CLIENT_NAME"; then
            log "Клиент '$CLIENT_NAME' добавлен."
            log "Файлы: $AWG_DIR/${CLIENT_NAME}.conf, $AWG_DIR/${CLIENT_NAME}.png"
            log "ВАЖНО: Требуется перезапуск сервиса: sudo systemctl restart awg-quick@awg0"
        else
            log_error "Ошибка добавления клиента '$CLIENT_NAME'."
        fi
        ;;

    remove)
        [[ -z "$CLIENT_NAME" ]] && die "Не указано имя клиента."
        if ! grep -q "^#_Name = ${CLIENT_NAME}$" "$SERVER_CONF_FILE"; then
            die "Клиент '$CLIENT_NAME' не найден."
        fi
        if ! confirm_action "удалить" "клиента '$CLIENT_NAME'"; then exit 1; fi

        log "Удаление '$CLIENT_NAME'..."
        if remove_peer_from_server "$CLIENT_NAME"; then
            log "Клиент '$CLIENT_NAME' удален из серверного конфига."
            rm -f "$AWG_DIR/$CLIENT_NAME.conf" "$AWG_DIR/$CLIENT_NAME.png"
            rm -f "$KEYS_DIR/${CLIENT_NAME}.private" "$KEYS_DIR/${CLIENT_NAME}.public"
            log "Файлы клиента удалены."
            log "ВАЖНО: Требуется перезапуск сервиса: sudo systemctl restart awg-quick@awg0"
        else
            log_error "Ошибка удаления клиента '$CLIENT_NAME'."
        fi
        ;;

    list)
        list_clients
        ;;

    regen)
        log "Перегенерация файлов конфигурации и QR..."
        if [[ -n "$CLIENT_NAME" ]]; then
            # Перегенерация одного клиента
            validate_client_name "$CLIENT_NAME" || exit 1
            if ! grep -q "^#_Name = ${CLIENT_NAME}$" "$SERVER_CONF_FILE"; then
                die "Клиент '$CLIENT_NAME' не найден."
            fi
            regenerate_client "$CLIENT_NAME" || log_error "Ошибка перегенерации '$CLIENT_NAME'."
        else
            # Перегенерация всех клиентов
            all_clients=$(grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //')
            if [[ -z "$all_clients" ]]; then
                log "Клиенты не найдены."
            else
                echo "$all_clients" | while IFS= read -r cname; do
                    cname=$(echo "$cname" | xargs)
                    [[ -z "$cname" ]] && continue
                    log "Перегенерация '$cname'..."
                    regenerate_client "$cname" || log_warn "Ошибка перегенерации '$cname'"
                done
                log "Перегенерация завершена."
            fi
        fi
        ;;

    modify)
        modify_client "$CLIENT_NAME" "$PARAM" "$VALUE"
        ;;

    backup)
        backup_configs
        ;;

    restore)
        restore_backup "$CLIENT_NAME" # CLIENT_NAME используется как [файл]
        ;;

    check|status)
        check_server
        ;;

    show)
        log "Статус AmneziaWG 2.0..."
        if ! awg show; then log_error "Ошибка awg show."; fi
        ;;

    restart)
        log "Перезапуск сервиса..."
        if ! confirm_action "перезапустить" "сервис"; then exit 1; fi
        if ! systemctl restart awg-quick@awg0; then
            log_error "Ошибка перезапуска."
            systemctl status awg-quick@awg0 --no-pager | log_msg "ERROR"
            exit 1
        else
            log "Сервис перезапущен."
        fi
        ;;

    help)
        usage
        ;;

    *)
        log_error "Неизвестная команда: '$COMMAND'"
        usage
        ;;
esac

log "Скрипт управления завершил работу."
exit 0
