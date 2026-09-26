#!/bin/bash

# ==============================================================================
# Общая библиотека функций для AmneziaWG 2.0
# Автор: @bivlked
# Версия: 5.36.2
# Дата: 2026-09-24
# Репозиторий: https://github.com/bivlked/amneziawg-installer
# ==============================================================================
#
# Этот файл содержит общие функции для генерации ключей, конфигураций,
# управления пирами и работы с AWG 2.0 параметрами.
# Предназначен для подключения через source из install и manage скриптов.
# ==============================================================================

# --- Константы (могут быть переопределены до source) ---
AWG_DIR="${AWG_DIR:-/root/awg}"
CONFIG_FILE="${CONFIG_FILE:-$AWG_DIR/awgsetup_cfg.init}"
SERVER_CONF_FILE="${SERVER_CONF_FILE:-/etc/amnezia/amneziawg/awg0.conf}"
KEYS_DIR="${KEYS_DIR:-$AWG_DIR/keys}"

# Версия библиотеки. manage-скрипт сверяет её со своей по MAJOR.MINOR после
# source и падает с понятной ошибкой, если awg_common.sh и manage разъехались
# (обновили один файл, забыли второй) - иначе рассинхрон всплывает как
# "command not found" в случайном месте. Бампается вместе с остальными версиями.
# shellcheck disable=SC2034  # используется в manage-скрипте после source
AWG_COMMON_VERSION="5.36.2"

# --- Автоочистка временных файлов ---
# ВАЖНО: trap НЕ устанавливается здесь, чтобы не перезаписать trap вызывающего скрипта.
# Вызывающий скрипт должен вызвать _awg_cleanup() в своём обработчике EXIT.
_AWG_TEMP_FILES=()
# Файл-реестр temp-файлов: awg_mktemp часто вызывается через $(...) (subshell),
# где правка массива _AWG_TEMP_FILES теряется в родителе. Файл переживает
# subshell, поэтому _awg_cleanup надёжно удалит даже temp, созданный в
# подстановке команды (например прерванная запись конфига между mktemp и mv).
# $$ = PID вызывающего скрипта, стабилен для всех его subshell.
# Реестр лежит в $AWG_DIR (root-only 0700), а НЕ в общедоступном /tmp:
# предсказуемое имя в /tmp позволяло бы локальному пользователю заранее
# подложить файл со списком чужих путей, которые _awg_cleanup удалил бы от root.
_AWG_TEMP_REGISTRY="${AWG_DIR}/.awg_temp_registry.$$"

_awg_cleanup() {
    local f
    for f in "${_AWG_TEMP_FILES[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
    # Файловый кэш public IP (см. get_server_public_ip) - per-PID, подчищаем.
    rm -f "${AWG_DIR}/.public_ip.cache.$$" 2>/dev/null
    # Guard от symlink-подмены реестра: читаем только обычный файл.
    if [[ -n "${_AWG_TEMP_REGISTRY:-}" && -f "$_AWG_TEMP_REGISTRY" && ! -L "$_AWG_TEMP_REGISTRY" ]]; then
        while IFS= read -r f; do
            [[ -n "$f" && -f "$f" ]] && rm -f "$f"
        done < "$_AWG_TEMP_REGISTRY"
        rm -f "$_AWG_TEMP_REGISTRY"
    fi
}

# Обёртка mktemp с автоочисткой.
# Опциональный 1-й аргумент - целевой каталог: temp создаётся в нём же, где
# окажется итоговый файл, чтобы последующий mv был атомарным rename в пределах
# одной ФС, а не cross-fs copy+unlink (важно, когда /tmp смонтирован как tmpfs).
# Без аргумента поведение прежнее (/tmp или $TMPDIR) - обратная совместимость.
awg_mktemp() {
    local dir="${1:-}" f
    if [[ -n "$dir" ]]; then
        mkdir -p "$dir" 2>/dev/null
        f=$(mktemp -p "$dir") || return 1
    else
        f=$(mktemp) || return 1
    fi
    _AWG_TEMP_FILES+=("$f")
    # Дублируем путь в файл-реестр - он переживает subshell ($(awg_mktemp ...)),
    # в отличие от массива выше.
    [[ -n "${_AWG_TEMP_REGISTRY:-}" ]] && printf '%s\n' "$f" >> "$_AWG_TEMP_REGISTRY" 2>/dev/null
    echo "$f"
}

# --- Заглушки для логирования (переопределяются вызывающим скриптом) ---
if ! declare -f log >/dev/null 2>&1; then
    log()       { echo "[INFO] $1"; }
    log_warn()  { echo "[WARN] $1" >&2; }
    log_error() { echo "[ERROR] $1" >&2; }
    log_debug() { echo "[DEBUG] $1"; }
fi

# ==============================================================================
# Утилиты
# ==============================================================================

# --- Валидаторы IP / CIDR (общие для install и manage) ---
# Проверяют не только форму, но и числовые диапазоны: октеты IPv4 0-255,
# префикс IPv4 0-32, IPv6 0-128. Без префикса адрес валиден (wireguard-tools
# трактует голый IPv4 как /32, IPv6 как /128 - host-route).

# _valid_ipv4 <addr> : ровно 4 октета, каждый 0-255 (10# защищает от трактовки
# ведущего нуля как восьмеричного числа в (( )) ).
_valid_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local o
    for o in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
        (( 10#$o <= 255 )) || return 1
    done
    return 0
}

# _valid_ipv6 <addr> : структурная проверка (не только charset). Допускает одну
# компрессию "::"; без неё требует ровно 8 групп по 1-4 hex; с ней - не более 7.
# Встроенный IPv4 (::ffff:1.2.3.4) намеренно не поддержан - в AllowedIPs туннеля
# не встречается, а точки уже отсекаются charset-проверкой.
_valid_ipv6() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    case "$ip" in
        *:::*)   return 1 ;;                     # три и более ":" подряд
        *::*::*) return 1 ;;                     # более одной "::"
    esac
    [[ "$ip" == :* && "$ip" != ::* ]] && return 1   # одиночное ведущее ":"
    [[ "$ip" == *: && "$ip" != *:: ]] && return 1   # одиночное хвостовое ":"
    local has_dcolon=0
    [[ "$ip" == *::* ]] && has_dcolon=1
    local IFS=':' parts=() p ngroups=0
    read -ra parts <<< "$ip"
    for p in "${parts[@]}"; do
        [[ -z "$p" ]] && continue                 # пустые поля от "::"
        [[ "$p" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        (( ngroups++ ))
    done
    if [[ $has_dcolon -eq 1 ]]; then
        (( ngroups <= 7 )) || return 1            # "::" заменяет >=1 группу
    else
        (( ngroups == 8 )) || return 1
    fi
    return 0
}

# _valid_cidr <token> : IPv4/IPv6 адрес с опциональным префиксом. Префикс, если
# задан, обязан быть числом в допустимом диапазоне (IPv4 0-32, IPv6 0-128).
# Пустой префикс после "/" (например "1.2.3.4/") отвергается.
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

# _valid_host_or_ipv4 <host> : для Endpoint - корректный IPv4 ИЛИ FQDN.
_valid_host_or_ipv4() {
    local host="$1"
    _valid_ipv4 "$host" && return 0
    [[ "$host" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$ ]] || return 1
    # Полностью числовая последняя метка = не настоящий TLD (RFC 3696), а скорее
    # битый IPv4 (например "999.1.1.1"); отвергаем, чтобы не принять опечатку в IP.
    local last="${host##*.}"
    [[ "$last" =~ ^[0-9]+$ ]] && return 1
    return 0
}

# Порту из конфига нельзя доверять до проверки: и awgsetup_cfg.init, и ListenPort
# в живом awg0.conf правят руками, и там оказывается что угодно. Значение уходит
# в 'Endpoint = IP:PORT' клиентского .conf (add/regen), в JSON без кавычек
# ("number":abc не разбирается) и в арифметические сравнения (где bash выполняет
# подстановку команд из строки вида a[$(...)]) у check, и в regex правил UFW у
# diagnose. Функция, а не пара строк по месту: так её исполняет тест, а не копия
# логики.
_sanitize_port() {
    local p="${1:-}"
    # Пробелы по краям срезаю: 'AWG_PORT=39743 ' - обычный след ручной правки,
    # и это тот же самый порт. Раньше такой конфиг ронял проверку впустую.
    p="${p#"${p%%[![:space:]]*}"}"
    p="${p%"${p##*[![:space:]]}"}"
    # {1,5} отсекает переполнение 64-битной арифметики: длинная строка цифр
    # молча приземлилась бы внутрь допустимого диапазона. 10# снимает
    # восьмеричную трактовку значений с ведущим нулём (0070 иначе даст 56).
    if [[ "$p" =~ ^[0-9]{1,5}$ ]] && (( 10#$p >= 1 && 10#$p <= 65535 )); then
        printf '%s' "$((10#$p))"
    else
        printf '0'
    fi
}

# --- CIDR-арифметика (общая для аллокатора IPv4/IPv6) ---
# Чистые функции, только bash-арифметика ($(( ))), без внешних зависимостей.
# set-e-safe: значения берём через $(( ))/local, guard'ы через "|| return".

# _ipv4_to_int <a.b.c.d> : 32-битное целое из IPv4. Guard входа - _valid_ipv4
# (не переизобретаем проверку октетов). 10# защищает от трактовки ведущего нуля
# как восьмеричного числа.
_ipv4_to_int() {
    _valid_ipv4 "$1" || return 1
    local IFS=. o
    read -ra o <<< "$1"
    echo $(( (10#${o[0]} << 24) | (10#${o[1]} << 16) | (10#${o[2]} << 8) | 10#${o[3]} ))
}

# _int_to_ipv4 <int> : IPv4 из 32-битного целого.
_int_to_ipv4() {
    local n="$1"
    echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
}

# _cidr_bounds <addr/prefix> : печатает "network_int broadcast_int".
# Единственный источник формулы network/broadcast в awg_common.
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

# --- Полный туннель: решение по СВОЙСТВУ набора маршрутов, а не по строке ---

# Диапазоны IPv4, отсутствие которых в AllowedIPs НЕ делает туннель раздельным.
# Это список ДОПУСКА, а НЕ описание того, что исключает какой-либо режим: наш
# дефолтный список исключает только 0/8, 10/8, 172.16/12, 192.168/16 и 224/3, а
# остальные диапазоны таблицы он как раз ведёт в туннель. Путать эти две вещи
# опасно: по прочтению 'режимы оставляют их вне туннеля' кто-нибудь выровняет
# генератор списка под таблицу и молча изменит состав дефолтного туннеля.
# Состав - это ПОЛИТИКА, а не механика, поэтому основания названы явно: частные
# сети (10/8, 172.16/12, 192.168/16) и CGNAT (100.64/10) живут у провайдера и в
# домашней сети; 0/8, 127/8 и 169.254/16 не маршрутизируются; 192.0.0/24 отдан
# под назначения IETF, 192.0.2/24, 198.51.100/24 и 203.0.113/24 - под примеры в
# документации, 198.18/15 - под замеры производительности; 224/3 - это
# multicast, зарезервированное пространство и широковещательный адрес. Ни один
# класс не является местом, куда пользователь ходит через VPN, поэтому их
# отсутствие полноте туннеля не мешает.
# Порядок возрастающий и без пересечений - на этом держится проход в
# _awg_ipv4_range_is_non_public.
_AWG_NON_PUBLIC_IPV4=(
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
    172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16
    198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/3
)

# _awg_ipv4_range_is_non_public <lo> <hi> : целиком ли интервал [lo, hi] лежит
# внутри служебных диапазонов. Проход по отсортированному списку с курсором:
# каждый диапазон либо остался позади, либо обязан начинаться не дальше курсора,
# иначе между ними публичный адрес - и ответ отрицательный.
_awg_ipv4_range_is_non_public() {
    local hi="$2" cidr b slo shi cur="$1"
    for cidr in "${_AWG_NON_PUBLIC_IPV4[@]}"; do
        b=$(_cidr_bounds "$cidr") || {
            # Таблица - константа, поэтому отказ здесь означает испорченный код,
            # а не пользовательский ввод. Молчаливое 'раздельный' в этом месте
            # выглядело бы как честный ответ.
            log_error "Внутренняя таблица служебных диапазонов испорчена: '$cidr'."
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

# _is_full_tunnel <allowed_ips> : покрывает ли список ВЕСЬ публичный IPv4.
#
# Режим 1 задаёт полный туннель строкой 0.0.0.0/0, режим 2 (был дефолтом
# установки до v5.34.0) - списком из 34 записей: весь публичный IPv4 минус частные сети. Списком, а не
# нулём, он записан только чтобы обойти баг iOS на 0.0.0.0/5 (issue #42), по
# смыслу это тоже полный туннель. Сравнение строки с литералом отвечало на эти
# два случая по-разному, и установка по умолчанию теряла тогда ::/0 - IPv6 устройства
# уходил наружу со своим настоящим адресом.
#
# Настоящая раздельная маршрутизация (режим 3) не покрывает публичное
# пространство и получает отрицательный ответ, как и раньше.
#
# Возврат: 0 - полный туннель, 1 - нет. Неразобранный маршрут тоже даёт 1, но
# ГРОМКО: молчаливое 'считаю раздельным' здесь неотличимо от честного ответа.
_is_full_tunnel() {
    local list="$1" tok b lo hi pairs="" cur=0
    local -a toks=()
    # read берёт ТОЛЬКО ПЕРВУЮ СТРОКУ, даже когда перевод строки стоит в IFS,
    # поэтому переводы строк и возвраты каретки превращаю в пробелы заранее.
    # AllowedIPs бывает многострочным (wg допускает повтор ключа, D#38), а
    # конфиг, поправленный из Windows, приносит \r в конце последнего токена.
    list="${list//$'\r'/}"
    list="${list//$'\n'/, }"
    local IFS=$', \t'
    read -ra toks <<< "$list"
    IFS=$' \t\n'
    # Верхняя граница на размер списка. Каждый токен стоит одной подстановки
    # команды, то есть процесса: наши списки короче 40 записей, а вот
    # пользовательский на десятки тысяч сетей (инверсия страновых диапазонов -
    # популярный в тредах приём) сделал бы каждый add и regen многоминутным.
    # Отказ ГРОМКИЙ и с числом: поведение остаётся прежним (::/0 не
    # дописывается), но причина видна, а не выглядит как «проверил и сошлось».
    if (( ${#toks[@]} > 512 )); then
        log_warn "AllowedIPs: маршрутов ${#toks[@]}, это больше предела проверки (512) - список считаю раздельным, ::/0 не дописываю."
        return 1
    fi
    for tok in "${toks[@]}"; do
        [[ -z "$tok" ]] && continue
        # IPv6-токен на покрытие IPv4 не влияет: dual-stack список уже содержит
        # свою IPv6-часть, и она не должна мешать ответу про IPv4.
        [[ "$tok" == *:* ]] && continue
        [[ "$tok" == */* ]] || tok="${tok}/32"
        if ! b=$(_cidr_bounds "$tok"); then
            log_warn "AllowedIPs: маршрут '$tok' не разобран - список считаю раздельным, ::/0 не дописываю."
            return 1
        fi
        pairs+="${b}"$'\n'
    done
    # Пустой список (или только IPv6) - не полный туннель.
    [[ -n "$pairs" ]] || return 1
    # Проход по объединению интервалов: всё, что осталось непокрытым, обязано
    # целиком лежать в служебных диапазонах. sort -n даёт возрастающий порядок,
    # перекрытия и дубликаты схлопываются курсором cur.
    # Сортировка в переменную, а НЕ подстановкой процесса: отказ sort внутри
    # <(...) родительской оболочке не виден, и предикат молча отвечал бы
    # 'раздельный' на исправном списке - то есть на сломанном хосте тихо
    # вернулось бы поведение до этой правки, включая режим 1, который от sort
    # раньше не зависел вовсе.
    local sorted
    sorted=$(printf '%s' "$pairs" | LC_ALL=C sort -n -k1,1 -k2,2) || {
        log_warn "AllowedIPs: не удалось упорядочить маршруты - полноту туннеля не проверяю, ::/0 не дописываю."
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

# Префикс «стока» IPv6 для списочного полного туннеля (режим 2).
#
# Зачем. Клиент AmneziaWG для Windows (форк wireguard-windows) включает
# kill-switch, если у единственного пира есть 0.0.0.0/0 ИЛИ ::/0, и этот
# kill-switch отрезает локальную сеть - а режим 2 существует ради неё (замер на
# стенде: шлюз, соседние хосты и SSH недоступны). Без IPv6-адреса на интерфейсе
# Windows не ставит вообще никакой IPv6-маршрут (amneziawg-windows-client #112),
# поэтому один 2000::/3 вместо ::/0 вернул бы LAN, но выпустил бы IPv6 мимо
# туннеля. Поэтому списку достаётся 2000::/3 (весь глобальный IPv6) плюс адрес
# из этого префикса: маршрут встаёт, IPv6 уходит в туннель и гаснет там
# (сервер без IPv6-туннеля такой источник отбрасывает), LAN остаётся снаружи.
# Замерено на Windows, Linux awg-quick и Android с настоящим IPv6.
# Префикс отдельный от туннельной подсети dual-stack (fddd:2c4:2c4:2c4::/64):
# vpn:// и regen отличают сток от настоящего IPv6-адреса клиента по префиксу.
AWG_V6_SINK_PREFIX="fddd:2c4:2c4:ffff"

# _awg_v6_sink_addr <ipv4> : адрес стока клиента - префикс плюс его IPv4 в
# младших 32 битах (10.9.9.5 -> fddd:2c4:2c4:ffff::a09:905). Уникален для
# клиента, не меняется при regen и считается без хранимого состояния.
_awg_v6_sink_addr() {
    local ip="${1:-}" o1 o2 o3 o4
    _valid_ipv4 "$ip" || return 1
    IFS=. read -r o1 o2 o3 o4 <<< "$ip"
    printf '%s::%x:%x' "$AWG_V6_SINK_PREFIX" \
        $(( (10#$o1 << 8) | 10#$o2 )) $(( (10#$o3 << 8) | 10#$o4 ))
}

# _is_v6_sink_addr <адрес[/длина]> : адрес из префикса стока.
_is_v6_sink_addr() {
    local a="${1%%/*}"
    a="${a,,}"
    [[ -n "$a" && "$a" == "${AWG_V6_SINK_PREFIX}:"* ]]
}

# _aip_tokens <список> : элементы списка AllowedIPs по одному в строке, без
# пробелов. Перевод строки и запятая - разделители, возврат каретки не значим.
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

# _aip_has_token <список> <элемент> : есть ли в списке ровно такой элемент.
# Без конвейера: grep -q выходит на первом совпадении, генератор получает
# SIGPIPE, и под pipefail конвейер отвечает «нет» на присутствующий элемент
# (на списке в 400 маршрутов - почти всегда).
_aip_has_token() {
    local toks
    toks=$(_aip_tokens "$1") || return 1
    grep -qxF -- "$2" <<< "$toks"
}

# _aip_wants_v6_sink <список> : нужен ли клиенту адрес стока - в списке есть
# 2000::/3 и нет ::/0 (с ::/0 kill-switch Windows включается всё равно).
_aip_wants_v6_sink() {
    _aip_has_token "$1" "2000::/3" && ! _aip_has_token "$1" "::/0"
}

# _append_ipv6_full_tunnel_route <allowed_ips> : печатает список с IPv6-частью
# полного туннеля, если это полный туннель без IPv6; иначе список как есть.
#
# Зачем: IPv6 через IPv4-туннель не проходит, поэтому без IPv6-маршрута он идёт
# мимо VPN со своим настоящим адресом - заблокированный ресурс с записью AAAA
# остаётся заблокированным, а выглядит это как 'VPN не работает на мобильном'.
# Маршрут забирает IPv6 в туннель, где он гасится, и клиент откатывается на IPv4
# (Happy Eyeballs). Того же требует iOS AmneziaVPN для режима 'весь трафик'.
# Какой маршрут:
#   - в списке есть 0.0.0.0/0 (режим 1) -> ::/0, как раньше: kill-switch
#     Windows там включает сам 0.0.0.0/0;
#   - полный туннель списком (режим 2) -> 2000::/3, адрес стока дописывает
#     render_client_config (см. AWG_V6_SINK_PREFIX).
# Список, где IPv6-часть уже есть, не трогается: явный ::/0 из --allowed-ips -
# выбор пользователя. Наш прежний ::/0 у списка режима 2 (v5.31.0-v5.36.x)
# заменяет regen через _aip_migrate_legacy_v6: только он знает, откуда список.
#
# Идемпотентность обязательна: regen выполняется многократно и в том числе
# поверх dual-stack клиента, чья IPv6-часть уже сформирована.
_append_ipv6_full_tunnel_route() {
    local list="$1"
    # Решение принимается по нормализованной копии, поэтому и печатать надо её.
    # Иначе возврат каретки из середины строки уехал бы в клиентский конфиг
    # вместе с дописанным маршрутом, а такой токен клиенты отвергают.
    # Возврат каретки не значим НИКОГДА и просто удаляется; перевод строки - это
    # разделитель элементов, поэтому он становится запятой, а не пробелом:
    # пробел склеил бы два маршрута в один нечитаемый токен.
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

# _aip_migrate_legacy_v6 <список клиента> <список сервера> : печатает список,
# где наш прежний ::/0 заменён на 2000::/3, иначе список как есть.
# v5.31.0-v5.36.x дописывали списку режима 2 голый ::/0, и на Windows он
# отрезает локальную сеть. Заменяется ТОЛЬКО то, что написали мы: IPv4-часть
# совпадает с глобальным списком сервера (набором маршрутов), IPv6-часть ровно
# ::/0, и этот список - полный туннель без 0.0.0.0/0. Полный туннель, который
# человек расписал сам (--allowed-ips, modify), остаётся его выбором. Клиента с
# настоящим IPv6 (dual-stack) regen сюда не передаёт вовсе.
_aip_migrate_legacy_v6() {
    local list="$1" base="$2" toks v6 mine srv tok out="" rc
    toks=$(_aip_tokens "$list") || return 1
    # Код 1 у grep - «строк нет», это ответ; 2 и выше - отказ, и его нельзя
    # выдавать за ответ: миграция молча не случилась бы.
    v6=$(grep -F ':' <<< "$toks"); rc=$?
    (( rc > 1 )) && return 1
    if [[ "$v6" != "::/0" || -z "$base" || "$base" == *:* ]] \
       || _aip_has_token "$base" "0.0.0.0/0" || ! _is_full_tunnel "$base"; then
        printf '%s' "$list"
        return 0
    fi
    # Без IPv4-части (modify принимает и голый ::/0) это не наш список. Не в
    # конвейере: под pipefail «строк нет» ронял бы regen на валидном списке.
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

# _sync_v6_sink_address <конфиг клиента> : привести Address к AllowedIPs того же
# файла - адрес стока есть ровно тогда, когда его требует список. Нужен там, где
# список меняют после рендера: regen, восстанавливающий индивидуальный список, и
# modify AllowedIPs. Dual-stack клиента (второй адрес не из стока) не трогает.
# Раскладку, которую мы не пишем (Address в несколько строк, три адреса), не
# трогает тоже, но говорит об этом: молча оставленный сток разошёлся бы с
# маршрутами. Каждый отказ назван, вызывающий добавит, что было откачено.
_sync_v6_sink_address() {
    local conf="$1" addr aips v4 second new sink n_addr
    local -a parts=()
    # Отсутствующий файл дойдёт до awk ниже и будет назван там.
    n_addr=$(grep -c '^[[:space:]]*Address[[:space:]]*=' "$conf" 2>/dev/null) || n_addr=0
    if (( n_addr > 1 )); then
        log_warn "Address в $conf задан несколькими строками - адрес стока IPv6 не выравниваю, проверьте его вручную."
        return 0
    fi
    addr=$(awk '/^[[:space:]]*Address[[:space:]]*=/{sub(/^[[:space:]]*Address[[:space:]]*=[[:space:]]*/, ""); sub(/\r$/, ""); print; exit}' "$conf") || {
        log_error "Address: не удалось прочитать $conf."
        return 1
    }
    # Все строки AllowedIPs: wg их складывает, и 2000::/3 на второй строке
    # такой же маршрут, как на первой.
    aips=$(awk '/^[[:space:]]*AllowedIPs[[:space:]]*=/{sub(/^[[:space:]]*AllowedIPs[[:space:]]*=[[:space:]]*/, ""); sub(/\r$/, ""); printf "%s%s", sep, $0; sep=", "}' "$conf") || {
        log_error "AllowedIPs: не удалось прочитать $conf."
        return 1
    }
    IFS=',' read -ra parts <<< "$addr"
    v4="${parts[0]//[[:space:]]/}"
    second="${parts[1]:-}"
    second="${second//[[:space:]]/}"
    if (( ${#parts[@]} > 2 )); then
        log_warn "Address в $conf несёт больше двух адресов - адрес стока IPv6 не выравниваю, проверьте его вручную."
        return 0
    fi
    [[ -n "$second" ]] && ! _is_v6_sink_addr "$second" && return 0
    # IPv4 проверяется целиком: значение уходит в замену sed, и '&' в нём
    # размножил бы строку при коде возврата 0. Пустой Address отвергается здесь же.
    if [[ ! "$v4" =~ ^[0-9.]+(/([0-9]|[12][0-9]|3[0-2]))?$ ]] || ! _valid_ipv4 "${v4%%/*}"; then
        log_error "Address в $conf не разобран ('$v4')."
        return 1
    fi
    new="$v4"
    if _aip_wants_v6_sink "$aips"; then
        sink=$(_awg_v6_sink_addr "${v4%%/*}") || {
            log_error "Address: не удалось вычислить адрес стока для '$v4'."
            return 1
        }
        new="${v4}, ${sink}/128"
    fi
    [[ "$new" == "$addr" ]] && return 0
    sed -i "s|^[[:space:]]*Address[[:space:]]*=.*|Address = ${new}|" "$conf" || {
        log_error "Address: не удалось записать $conf."
        return 1
    }
}

# Полный туннель с явной IPv6-частью AllowedIPs, но без ::/0, на сервере с
# нативным IPv6 (Issue #253): ровно то состояние, о котором regen предупреждает
# при сохранении индивидуального списка. Единый предикат для regen и render -
# две копии условия разъедутся молча. Условие про нативный IPv6 обязательно:
# без него клиенту положена туннельная ULA вместо ::/0, это документированное
# правило, а не утечка, и предупреждение звало бы чинить исправное.
_aip_full_tunnel_v6_gap() {
    local list="$1"
    [[ "${SERVER_HAS_NATIVE_IPV6:-0}" == "1" && "$list" == *:* ]] \
        && ! _aip_has_token "$list" "::/0" && ! _aip_has_token "$list" "2000::/3" \
        && _is_full_tunnel "$list"
}

# Определение основного сетевого интерфейса (egress).
# Цепочка fallback, чтобы не падать на хостах, где зонд к 1.1.1.1 не отдаёт
# интерфейс: провайдер null-route'ит/блокирует адрес, policy-routing или
# IPv6-only egress (наблюдалось на Ubuntu 26.04 / Timeweb, issue #166).
# Ручное переопределение: export AWG_MAIN_NIC=<iface> перед запуском.
get_main_nic() {
    # Ручной оверрайд принимаем только если это существующий безопасный ifname:
    # значение попадает в PostUp/PostDown (iptables -o ...), поэтому имена с
    # shell-метасимволами и несуществующие интерфейсы отвергаем (fall-through
    # к авто-детекту).
    if [[ -n "${AWG_MAIN_NIC:-}" ]]; then
        if [[ "$AWG_MAIN_NIC" =~ ^[A-Za-z0-9._-]+$ ]] \
            && ip link show dev "$AWG_MAIN_NIC" &>/dev/null; then
            printf '%s\n' "$AWG_MAIN_NIC"
            return 0
        fi
        # Невалидный оверрайд отбрасываем ГРОМКО (log_warn идёт в stderr, вывод
        # $() не загрязняет): молчаливый fall-through путал бы пользователя,
        # который уже выполнил подсказку export AWG_MAIN_NIC=... с опечаткой.
        log_warn "AWG_MAIN_NIC='${AWG_MAIN_NIC}' проигнорирован: интерфейс не найден или имя некорректно - продолжаю авто-детект."
    fi
    local nic
    # 1) Реальный egress к публичному адресу (FIB-lookup, быстрый путь для большинства хостов).
    nic=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    # 2) Дефолтный IPv4-маршрут (когда зонд недостижим/заблокирован).
    [[ -z "$nic" ]] && nic=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    # 3) Первый UP-интерфейс с глобальным IPv4 (нет дефолт-маршрута). Исключаем
    #    туннельные/виртуальные (awg0 сам UP с 10.x scope global при --force
    #    переустановке, docker0/br-*/veth* на хостах с контейнерами) - иначе
    #    NAT ушёл бы в hairpin через сам туннель, а IPv6-only warning молча
    #    подавился бы (у awg0 есть глобальный IPv4).
    [[ -z "$nic" ]] && nic=$(ip -o -4 addr show up scope global 2>/dev/null \
        | awk '{sub(/@.*/,"",$2); if ($2!="lo" && $2 !~ /^(awg|wg|docker|br-|virbr|veth|lxc|tun|tap)/) { print $2; exit }}')
    # 4) Дефолтный IPv6-маршрут (IPv6-only egress).
    [[ -z "$nic" ]] && nic=$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [[ -n "$nic" ]] || return 1
    printf '%s\n' "$nic"
}

# Возвращает 0, если у хоста нет IPv4-выхода: нет дефолтного IPv4-маршрута И у
# интерфейса $1 нет глобального IPv4-адреса. Такой хост IPv6-only (issue #166:
# Timeweb Ubuntu 26.04) - IPv4-туннель (10.x) не сможет NAT'иться наружу.
# Оба условия должны совпасть: на dual-stack/IPv4 хостах функция вернёт 1.
host_lacks_ipv4_egress() {
    local nic="$1"
    # [[ -z $(...) ]] вместо "| grep -q .": grep -q выходит на первой строке, и
    # под pipefail многострочный вывод ip (несколько default-маршрутов) мог бы
    # дать SIGPIPE=141 -> ложное "маршрута нет" на здоровом dual-stack хосте.
    [[ -z "$(ip -4 route show default 2>/dev/null)" ]] \
        && [[ -z "$(ip -o -4 addr show dev "$nic" up scope global 2>/dev/null)" ]]
}

# Определение внешнего IP-адреса сервера (с кэшированием).
#
# Список 6 сервисов покрывает основные NAT и cloud-сценарии без
# жёсткого ранжирования по uptime: ifconfig.me исторически стабилен
# на обычных VPS (Hetzner, Vultr, OVH), checkip.amazonaws.com -
# доступен даже из AWS / GCP / OCI private subnet за NAT Gateway,
# ipinfo.io / icanhazip / ifconfig.io - дополнительные fallback'и
# на случай rate-limit одного из endpoint'ов. Порядок alphabetical
# (детерминирован для тестов и diff'ов). First-wins: при первом
# валидном ответе остальные не запрашиваются.
_CACHED_PUBLIC_IP=""
# Файловый дубль кэша: get_server_public_ip практически всегда вызывается как
# $(...) (subshell), где присваивание _CACHED_PUBLIC_IP теряется в родителе и
# кэш-переменная никогда не срабатывает. Файл с PID-суффиксом переживает
# subshell (тот же приём, что _AWG_TEMP_REGISTRY) и удаляется в _awg_cleanup.
# Без него `manage regen` по N клиентам делал бы N curl-раундов (до 6 сервисов
# по 5 сек каждый) при пустом AWG_ENDPOINT.
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

# Fallback: первый non-loopback IPv4 с сетевого интерфейса.
# Нужен когда curl до ifconfig.me / ipify / ... не проходит (LXC без egress,
# fail2ban на outbound, firewall, и т.п.). На bare metal / обычных VPS
# обычно совпадает с public IP; на NAT'нутом хосте даёт private IP — в
# этом случае вызывающий код должен написать log_warn чтобы пользователь
# сам исправил Endpoint в клиентских .conf.
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

# Note: apt_update_tolerant() определена inline в install_amneziawg.sh
# (нужна в шагах 1-2 до скачивания этого файла). Здесь её нет — мёртвый код.

# ==============================================================================
# Генерация AWG 2.0 параметров (используется в тестах + manage)
# ==============================================================================

# Случайное число [min, max] через /dev/urandom (поддержка uint32).
# Дублирует install_amneziawg.sh:rand_range — нужно здесь для тестов и regen.
rand_range() {
    local min=$1 max=$2
    local range=$((max - min + 1))
    local random_val
    random_val=$(od -An -tu4 -N4 /dev/urandom 2>/dev/null | tr -d ' ')
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
# Минимальная ширина каждого диапазона = 1000.
# Печатает 4 строки "low-high" в stdout. Возвращает 1 при неудаче.
# Защита от ТСПУ-фингерпринта по статическим H-значениям (#38).
#
# Диапазон: [0, 2^31-1] = [0, 2147483647]. Спецификация AmneziaWG
# допускает полный uint32 (0-4294967295), но standalone Windows-клиент
# `amneziawg-windows-client` имеет UI-валидатор ограниченный 2^31-1 в
# `ui/syntax/highlighter.go:isValidHField()` (upstream bug
# amnezia-vpn/amneziawg-windows-client#85, не исправлен). Значения
# выше 2^31-1 на сервере работают, но клиентский редактор подчёркивает
# их красным и не даёт сохранять правки. Для совместимости генерируем
# в безопасной половине диапазона (#40).
#
# Оптимизация: один вызов `od -N32 -tu4` читает 32 байта = 8 uint32 значений
# одной операцией, вместо 8 отдельных subprocess через rand_range.
# Fallback на rand_range если /dev/urandom недоступен.
generate_awg_h_ranges() {
    local attempt=0 max_attempts=20
    while (( attempt < max_attempts )); do
        local raw arr=() _v
        # Один read 32 байт из /dev/urandom = 8 uint32 значений
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
        # Fallback: 8 отдельных вызовов rand_range (если urandom недоступен)
        if (( ${#arr[@]} != 8 )); then
            arr=()
            local _i
            for _i in 1 2 3 4 5 6 7 8; do
                arr+=("$(rand_range 0 2147483647)")
            done
        fi
        # Сортировка
        local sorted
        sorted=$(printf '%s\n' "${arr[@]}" | sort -n)
        arr=()
        while IFS= read -r _v; do arr+=("$_v"); done <<< "$sorted"
        # Проверка: минимальная ширина каждой пары, строгий зазор между
        # парами (без касания границ) и нижняя граница вне зарезервированных
        # значений 1-4 (типы сообщений vanilla WireGuard).
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
# DKMS / Автовосстановление модуля ядра amneziawg
# ==============================================================================

# awg_module_version : версия модуля amneziawg (пустая строка, если определить
# не удалось). Сначала спрашиваем ЗАГРУЖЕННЫЙ модуль, и только потом файл.
#
# ⚠️ Почему не просто modinfo: modinfo читает метаданные того .ko, который
# ВЫБРАН на диске по modules.dep, а не того объекта, что работает в ядре.
# В норме это одно и то же, поэтому расхождение не всплывало. Но если на хосте
# оказались ДВА дерева с модулем одного имени - закреплённый 2.0 в extra/ и
# DKMS-3.0 в updates/dkms/ - modinfo назовёт тот, что выиграл по приоритету
# поиска, а загружен может быть другой (например, прежний, до перезагрузки).
# Тогда наша же диагностика сообщила бы версию, которой в ядре нет.
# /sys/module/amneziawg/version отражает именно загруженное и существует в
# ОБЕИХ линиях: MODULE_VERSION(WIREGUARD_VERSION) объявлен в src/main.c и в
# закреплённом 2.0-теге, и в 3.0.
# modinfo остаётся вторым путём - он работает, когда модуль не загружен.
#
# AWG_MODULE_VERSION_PATH переопределяется только тестами (bats): подменить
# /sys иначе нельзя, а проверить надо именно приоритет «загруженное важнее файла».
awg_module_version() {
    local ver="" sysfile="${AWG_MODULE_VERSION_PATH:-/sys/module/amneziawg/version}"
    if [[ -r "$sysfile" ]]; then
        # ⚠️ `|| true`, а НЕ `|| ver=""`: на файле без завершающего перевода
        # строки read возвращает 1, УЖЕ присвоив прочитанное. Сброс в пустую
        # строку затёр бы верное значение и молча уронил нас на modinfo.
        # ⚠️ И `2>/dev/null` стоит ДО `<`, а не после: перенаправления
        # применяются слева направо, поэтому при обратном порядке ошибка
        # открытия файла успевает уйти в исходный stderr - проверено, сырая
        # строка `bash: ...` вылезала посреди вывода manage check.
        IFS= read -r ver 2>/dev/null < "$sysfile" || true
        ver="${ver//[[:space:]]/}"
        # 🔴 Файл был читаем - отвечаем тем, что он дал, даже если это пустота,
        # и на modinfo НЕ уходим. Подмена ответом с диска - ровно то, от чего
        # эта функция создана уходить: при двух деревьях modinfo назовёт версию,
        # которой в ядре нет, а diagnose на её основании объявит линию протокола.
        # Пустая версия честнее неверной: потребители печатают строку без версии.
        printf '%s' "$ver"
        return 0
    fi
    ver=$(modinfo amneziawg 2>/dev/null | awk '/^version:/{print $2; exit}')
    printf '%s' "$ver"
}

# awg_module_build_id : признак СБОРКИ загруженного модуля, одной строкой.
# Пустая строка, если ничего опознать не удалось.
#
# 🔴 Зачем это отдельно от awg_module_version. Строка версии модуля сборку НЕ
# различает: замер на стенде 30 aug 2026 дал `3.1.20260812` И для сборки PPA от
# 14 aug (`4680320`), И для сборки от 28 aug (`3c38e16`) - MODULE_VERSION статичен
# в исходниках и меняется реже, чем сам код. Различают только srcversion (хеш
# исходников, который считает сборщик модуля) и версия пакета.
# Без этого признака диагностический отчёт не отвечает на вопрос «какая у тебя
# сборка», а именно он нужен, когда расходятся модуль ядра и userspace-клиент.
#
# AWG_MODULE_SRCVERSION_PATH переопределяется только тестами: подменить /sys
# иначе нельзя, а проверить надо именно чтение загруженного модуля.
awg_module_build_id() {
    local src="" pkg="" out=""
    local sysfile="${AWG_MODULE_SRCVERSION_PATH:-/sys/module/amneziawg/srcversion}"
    if [[ -r "$sysfile" ]]; then
        # `|| true` по той же причине, что и в awg_module_version: на файле без
        # завершающего перевода строки read возвращает 1, УЖЕ присвоив прочитанное.
        IFS= read -r src 2>/dev/null < "$sysfile" || true
        src="${src//[[:space:]]/}"
    fi
    # Только ПЕРВАЯ строка: при нескольких совпадениях склейка дала бы
    # правдоподобную, но несуществующую версию, а это хуже отказа.
    pkg=$(dpkg-query -W -f='${Version}\n' amneziawg-dkms 2>/dev/null | head -n 1 || true)
    pkg="${pkg//[[:space:]]/}"
    # 🔴 Две части НАЗВАНЫ ПО-РАЗНОМУ намеренно: это разные вещи, и они
    # расходятся штатно. Пакет можно обновить, а модуль в памяти останется
    # прежним до перезагрузки или modprobe - ровно это наблюдалось на стенде
    # 30 aug 2026. Слить их в один «признак сборки» значило бы выдать версию
    # пакета за версию загруженного кода.
    [[ -n "$src" ]] && out="srcversion загруженного $src"
    if [[ -n "$pkg" ]]; then
        [[ -n "$out" ]] && out="$out; "
        out="${out}установлен пакет $pkg"
    fi
    printf '%s' "$out"
}

#
# После apt upgrade ядра DKMS-модуль должен пересобраться для нового kernel.
# Если это не произошло (или модуль был отвязан), 4 функции ниже выполняют
# idempotent восстановление:
#
#   _sanitize_awg_dkms_conf       — убрать deprecated REMAKE_INITRD= из dkms.conf
#   _install_kernel_headers       — distro-aware fallback chain (Ubuntu/Debian)
#   _ensure_awg_quick_running     — стартовать awg-quick@awg0 если неактивен
#   ensure_amneziawg_kernel_module — master, публичная точка входа
#
# === Контекст использования и safety contract ===
#
# Master ensure_amneziawg_kernel_module() исходит из того, что running kernel
# (uname -r) и есть target kernel — то есть подходит только для post-reboot
# контекстов: manage repair-module, manage add/remove (после reboot user'а),
# systemd unit (стартует на boot когда ядро уже новое). Из DPkg::Post-Invoke
# хука uname -r всё ещё возвращает СТАРОЕ ядро — для этого случая Phase 3
# Apt hook helper будет использовать отдельную обёртку, итерирующую target
# ядра через /lib/modules/*/build.
#
# Master НЕ вызывает apt-get install по умолчанию (это deadlock в любом
# контексте где parent держит /var/lib/dpkg/lock-frontend). Вызов apt
# гейтится переменной окружения AWG_ALLOW_APT_IN_ENSURE=1 — её устанавливает
# только install_amneziawg step 2 / manage repair-module. Apt hook helper
# и systemd unit её НЕ устанавливают, master skip'ит шаг с headers.
#
# Headers нужно ставить отдельно — на этапе install через мета-пакет
# (linux-headers-$(arch) для Debian, linux-headers-generic для Ubuntu) —
# apt сам подтянет matching headers при apt upgrade ядра.

# Удаление deprecated директивы REMAKE_INITRD= из dkms.conf модуля amneziawg.
# Современные версии DKMS считают её deprecated и печатают noisy warnings.
_sanitize_awg_dkms_conf() {
    local conf
    for conf in /var/lib/dkms/amneziawg/*/source/dkms.conf; do
        [[ -f "$conf" ]] && sed -i '/^REMAKE_INITRD=/d' "$conf"
    done
}

# Установка пакета kernel headers через distro-aware fallback chain.
# Аргумент: версия ядра (по умолчанию $(uname -r)).
# Возвращает: 0 если хотя бы один кандидат установлен успешно, 1 если все провалились.
#
# ВАЖНО: вызывается только из контекстов где apt lock доступен (install_amneziawg
# step 2 или manage repair-module). НЕ должна вызываться из DPkg::Post-Invoke хука.
#
# Поддерживается распознавание Raspberry Pi Foundation kernel (+rpt/-rpi suffix):
# linux-headers-rpi-2712 (Pi 5 / Cortex-A76) или linux-headers-rpi-v8 (Pi 3/4 arm64).
_install_kernel_headers() {
    # Defense-in-depth: эта функция вызывает apt-get install и не должна
    # запускаться из hook-context (deadlock на dpkg lock). Master уже гейтит
    # её через AWG_ALLOW_APT_IN_ENSURE, но _ префикс не enforced — добавляем
    # тот же гард сюда чтобы случайный direct call из чужого скрипта не
    # обошёл защиту.
    if [[ "${AWG_ALLOW_APT_IN_ENSURE:-0}" != "1" ]]; then
        log_error "_install_kernel_headers: AWG_ALLOW_APT_IN_ENSURE не выставлен — apt-вызов запрещён в этом контексте."
        return 1
    fi

    local kernel_ver="${1:-$(uname -r)}"
    local candidates=()

    # RPi Foundation kernel (suffix +rpt или -rpi) — отдельный мета-пакет
    # независимо от distro. Pattern check order: 2712 → v7l → v7 → v8 (default).
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
                # Cloud-images Debian используют отдельный мета-пакет
                # linux-headers-cloud-${arch} вместо обычного linux-headers-${arch}
                # (kernel ABI в них другая — sched/IRQ-таймеры урезаны под VM).
                # Prefer cloud-meta когда running kernel явно cloud — иначе
                # repair-module падает на AWS/Azure/GCP/cloud-Hetzner после
                # kernel upgrade, хотя headers доступны через cloud-meta.
                if [[ "$kernel_ver" == *-cloud-* ]]; then
                    candidates+=("linux-headers-cloud-${arch}")
                fi
                candidates+=("linux-headers-${arch}")
            fi
            ;;
        *)
            log_error "Установка kernel headers: неизвестный OS_ID='${OS_ID:-}' (поддерживаются только ubuntu/debian)."
            return 1
            ;;
    esac

    local pkg
    for pkg in "${candidates[@]}"; do
        if apt-get install -y "$pkg" >/dev/null 2>&1; then
            log "Установлены kernel headers: $pkg"
            return 0
        fi
        log_warn "Не удалось установить $pkg, пробую следующий кандидат..."
    done
    log_error "Не удалось установить ни один из пакетов kernel headers (${candidates[*]})."
    return 1
}

# Запуск awg-quick@<iface>, если сервис не активен.
# Аргумент: имя интерфейса (по умолчанию awg0).
# Возвращает: 0 при успешном старте или если сервис уже активен, 1 при сбое.
_ensure_awg_quick_running() {
    local iface="${1:-awg0}"
    local svc="awg-quick@${iface}.service"

    if systemctl is-active --quiet "$svc"; then
        return 0
    fi

    log "Запуск $svc (был неактивен)..."
    if systemctl start "$svc"; then
        log "$svc запущен."
        return 0
    fi
    log_error "Не удалось запустить $svc. Подробности: systemctl status $svc"
    return 1
}

# Master: гарантирует что модуль ядра amneziawg собран и загружен для running kernel.
# Idempotent: fast-path возвращает 0 если модуль уже loaded.
#
# Аргумент: режим — "full" (по умолчанию: модуль + старт awg-quick) или
#                  "module-only" (только модуль, без старта сервиса).
#
# ВАЖНО: master рассчитан на post-reboot контексты (manage repair-module,
# manage add/remove после reboot, systemd unit на boot). Apt/dpkg хук код
# НЕ должен звать master — uname -r в Post-Invoke возвращает старое ядро,
# поэтому хук должен использовать отдельную обёртку, итерирующую target
# kernels через /lib/modules/*/build (Phase 3 helper).
#
# Окружение: AWG_ALLOW_APT_IN_ENSURE=1 разрешает шаг установки kernel headers
# через apt-get install (опасно в hook context — deadlock на dpkg lock).
# Не установлено → шаг с headers пропускается с warn (предполагается что
# headers уже на диске через мета-пакет linux-headers-$(arch)).
#
# При необходимости запускает 5-шаговое восстановление:
#   headers → sanitize → dkms autoinstall → depmod → modprobe.
#
# Возвращает:
#   0 — модуль успешно загружен (и в "full" режиме awg-quick активен).
#   1 — финальный modprobe провалился, либо невалидный режим
#       (с печатью 4-шагового manual recovery).
#   2 - только "full": модуль в порядке, но awg-quick@awg0 не стартовал
#       (сервис-проблема: битый конфиг, занятый порт и т.п.). Раньше это
#       гасилось в log_warn + return 0, и repair-module рапортовал
#       "сервис активен" при лежащем сервисе (Issue #175).
ensure_amneziawg_kernel_module() {
    local mode="${1:-full}"
    case "$mode" in
        full|module-only) ;;
        *)
            log_error "ensure_amneziawg_kernel_module: невалидный режим '$mode' (ожидается 'full' или 'module-only')."
            return 1
            ;;
    esac
    local kernel_ver
    kernel_ver="$(uname -r)"

    # Fast-path: модуль уже загружен.
    if lsmod 2>/dev/null | awk '{print $1}' | grep -qx 'amneziawg'; then
        if [[ "$mode" == "full" ]]; then
            _ensure_awg_quick_running awg0 || {
                log_warn "Модуль активен, но awg-quick@awg0 не стартовал (модуль OK, это сервис-проблема)."
                return 2
            }
        fi
        return 0
    fi

    # Модуль на диске для running kernel — пробуем modprobe до full repair.
    if find "/lib/modules/${kernel_ver}" -name 'amneziawg.ko*' -print -quit 2>/dev/null | grep -q .; then
        if modprobe amneziawg 2>/dev/null && \
           lsmod 2>/dev/null | awk '{print $1}' | grep -qx 'amneziawg'; then
            log "amneziawg-модуль найден на диске и успешно загружен."
            if [[ "$mode" == "full" ]]; then
                _ensure_awg_quick_running awg0 || {
                    log_warn "Модуль загружен, но awg-quick@awg0 не стартовал (модуль OK, это сервис-проблема)."
                    return 2
                }
            fi
            return 0
        fi
    fi

    log_warn "amneziawg-модуль не загружен и не собран для ядра ${kernel_ver}."
    log_warn "Запускаю автоматическое восстановление..."

    # Step 1: kernel headers — только если apt разрешён вызвавшим контекстом.
    if [[ "${AWG_ALLOW_APT_IN_ENSURE:-0}" == "1" ]]; then
        case "${OS_ID:-}" in
            ubuntu|debian)
                local headers_pkg="linux-headers-${kernel_ver}"
                if ! dpkg-query -W -f='${Status}' "$headers_pkg" 2>/dev/null | grep -q 'install ok installed'; then
                    log "Kernel headers ($headers_pkg) не установлены. Устанавливаю..."
                    _install_kernel_headers "$kernel_ver" || \
                        log_warn "Не удалось установить kernel headers. Сборка DKMS-модуля может провалиться."
                fi
                ;;
        esac
    elif [[ ! -d "/lib/modules/${kernel_ver}/build" ]]; then
        log_warn "/lib/modules/${kernel_ver}/build отсутствует, headers не установлены."
        log_warn "Apt-установка пропущена (контекст не разрешает apt). Сборка DKMS-модуля скорее всего провалится."
    fi

    # Step 2: убрать deprecated REMAKE_INITRD из dkms.conf
    _sanitize_awg_dkms_conf

    # Step 3: dkms autoinstall для running kernel.
    # Если шаг ошибётся, всё равно пробуем modprobe ниже — он окончательный indicator.
    if command -v dkms >/dev/null 2>&1; then
        log "Запуск: dkms autoinstall -k ${kernel_ver}"
        if ! dkms autoinstall -k "${kernel_ver}" >/dev/null 2>&1; then
            log_warn "dkms autoinstall завершился с ошибкой для ядра ${kernel_ver}."
            local dkms_log
            dkms_log=$(find /var/lib/dkms/amneziawg -name 'make.log' -path "*${kernel_ver}*" 2>/dev/null | head -n 1)
            if [[ -n "$dkms_log" ]]; then
                log_warn "Последние 20 строк лога сборки DKMS (${dkms_log}):"
                tail -20 "$dkms_log" | while IFS= read -r line; do log_warn "  $line"; done
            else
                log_warn "Лог сборки не найден. Подробности в /var/lib/dkms/amneziawg/."
            fi
        fi
    else
        log_warn "Пакет dkms не установлен. Пересборка модуля ядра невозможна."
    fi

    # Step 4: обновить module dependency cache для конкретного ядра.
    if command -v depmod >/dev/null 2>&1; then
        depmod -a "$kernel_ver" >/dev/null 2>&1 || \
            log_warn "depmod -a $kernel_ver завершился с ошибкой; modprobe ниже даст финальный диагноз."
    fi

    # Step 5: финальная попытка modprobe.
    if ! modprobe amneziawg 2>/dev/null; then
        log_error "Модуль ядра amneziawg не удалось загрузить для ядра ${kernel_ver}."
        log_error "Модуль отсутствует в /lib/modules/${kernel_ver}/."
        log_error "Ручное восстановление:"
        log_error "  1. apt install -y \"linux-headers-${kernel_ver}\""
        log_error "  2. dkms autoinstall -k \"${kernel_ver}\" && depmod -a"
        log_error "  3. modprobe amneziawg"
        log_error "  4. systemctl start \"awg-quick@awg0\""
        return 1
    fi

    log "Модуль amneziawg успешно загружен для ядра ${kernel_ver}."
    if [[ "$mode" == "full" ]]; then
        _ensure_awg_quick_running awg0 || {
            log_warn "Модуль загружен, но awg-quick@awg0 не стартовал (модуль OK, это сервис-проблема)."
            return 2
        }
    fi
    return 0
}

# ==============================================================================
# Загрузка / сохранение параметров
# ==============================================================================

# Безопасная загрузка конфигурации (whitelist-парсер, без source/eval)
# Парсит только разрешённые ключи формата KEY=VALUE или export KEY=VALUE
safe_load_config() {
    local config_file="${1:-$CONFIG_FILE}"
    # CLIENT_DNS живёт только в файле: без сброса переменная из окружения root
    # (CLIENT_DNS=... manage add) молча ушла бы в новых клиентов на установках,
    # где строки в файле ещё нет.
    unset CLIENT_DNS
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
                AWG_H1|AWG_H2|AWG_H3|AWG_H4|AWG_I1|AWG_I2|AWG_I3|AWG_I4|AWG_I5|AWG_PRESET|NO_TWEAKS|NO_CPS|KEEP_PACKAGES|\
                AWG_APPLY_MODE|ALLOW_IPV6_TUNNEL|IPV6_SUBNET|SERVER_HAS_NATIVE_IPV6|PREV_AWG_PORT|CLIENT_ISOLATION|CLIENT_ISOLATION_NET|AWG_PROTOCOL|AWG_CPA|AWG_SERVER_NAME|CLIENT_DNS)
                    export "$key=$value"
                    ;;
            esac
        fi
    done < "$config_file"
}

# awg_installed_protocol : поколение УСТАНОВКИ по маркеру AWG_PROTOCOL из
# awgsetup_cfg.init (файл уже загружен safe_load_config). Печатает '2.0' или '3.1'.
# 🔴 Отсутствие поля - это 2.0, а не «не знаю»: так выглядят все установки,
# сделанные до появления маркера, и любой другой ответ мог бы молча сменить им
# поколение. Любое другое значение - отказ (код 1) БЕЗ вывода и без тихого
# дефолта: испорченный маркер на сервере третьей линии иначе (когда regen начнёт
# учитывать маркер) заставил бы regen выдать профили второй, которые молча не
# подключаются. Текст ошибки печатает
# вызывающий: тело функции одинаково во всех четырёх копиях (RU/EN, общая
# библиотека/установщик), и тест паритета это проверяет.
# Необязательный аргумент - путь к init. С ним файл проверяется fail-closed
# одним anchored-grep без конвейера (конвейер под pipefail на большом файле
# получал SIGPIPE и выключал сторожа): строка вида «AWG_PROTOCOL =» в любом
# регистре при пустом значении (поле не разобралось: сдвиг, пробелы вокруг
# «=», сломанные кавычки; либо записано пустым) - это порча маркера, а не его
# отсутствие; две и больше таких строк - тоже порча (какая из них истинная,
# угадать нельзя). В обоих случаях отказ, иначе испорченный маркер тихо стал
# бы «2.0».
# 🔴 BOM в начале файла образец допускает СОЗНАТЕЛЬНО: safe_load_config такую
# строку разбирает, значит и сторож обязан её видеть. Без этого испорченный
# маркер под BOM (файл, побывавший в редакторе Windows) не совпадал с образцом,
# сторож считал маркер отсутствующим и отвечал «2.0» - то есть ровно та тихая
# подмена, против которой он и написан. По той же причине не совпадала вторая
# строка при BOM у первой, и дубль проходил как одиночный маркер.
# 🔴 Код возврата grep различается: 1 - совпадений нет (норма), 2 и выше - отказ
# самого grep (обычный файл не читается). Прежняя форма
# «|| n=0» уравнивала их и превращала отказ в «маркера нет», то есть в
# уверенное «2.0». Ошибка чтения теперь тоже отказ.
# 🔴 grep получает только обычный файл (-f): на FIFO он ждал бы писателя вечно,
# на /dev/zero читал бы бесконечно. Отсутствующий путь и необычный файл на месте
# init до grep не доходят и читаются как «маркера нет», поэтому -f убирать нельзя.
# В manage живой init такого вида до функции не доходит: check_dependencies отказывает раньше.
# Установщик на шаге 0 считает его отсутствующим и вызывает функцию с тем же
# путём; ответ «2.0» без зависания даёт ему именно проверка -f.
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

# _awg_generation_from_init <init> : поколение установки по файлу init.
# Печатает 2.0 или 3.1; на испорченном маркере - отказ (код 1)
# без вывода. Правила целиком в awg_installed_protocol, здесь только
# чтение файла.
# 🔴 Подоболочка обязательна, и не только из-за AWG_PROTOCOL:
# safe_load_config ЭКСПОРТИРУЕТ всё, что разобрал, поэтому
# вызывающий, спросивший всего лишь про поколение, иначе
# молча получил бы ещё и порт с подсетью ИЗ ФАЙЛА.
# Значение для нечитаемого маркера выбирает вызывающий: у
# restore это «?» с предупреждением, у проверки ключа - broken
# и отказ только там, где ключ есть.
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

# awg_restore_generation_notice <init из бэкапа> <живой init>
# restore - явное действие и возвращает согласованный набор «конфиг + init +
# ключи», поэтому смену поколения он не запрещает, но и молчаливой она быть не
# должна: если поколение в бэкапе отличается от текущего, предупреждение
# печатается ДО остановки сервиса, сразу после проверки полноты бэкапа, когда
# архив уже распакован и человек ещё может прервать restore. Отсутствие поля
# читается как 2.0 (правило awg_installed_protocol); отсутствие самого init в
# бэкапе - отдельное предупреждение (маркер тогда остаётся текущим, файл
# restore не трогает); нечитаемый маркер печатается как «?» и предупреждение
# даёт всегда, даже если вторая сторона тоже нечитаема. Всегда возвращает 0:
# restore не прерывается, предупреждение остаётся в журнале.
awg_restore_generation_notice() {
    local backup_init="$1" live_init="$2" backup_gen live_gen
    live_gen=$(_awg_generation_from_init "$live_init") || live_gen="?"
    if [[ ! -f "$backup_init" ]]; then
        log_warn "В бэкапе нет awgsetup_cfg.init: маркер поколения останется текущим (${live_gen}). После восстановления сверьте его с восстановленным серверным конфигом."
        return 0
    fi
    backup_gen=$(_awg_generation_from_init "$backup_init") || backup_gen="?"
    if [[ "$backup_gen" == "?" || "$live_gen" == "?" ]]; then
        log_warn "Маркер поколения AWG_PROTOCOL не читается (в бэкапе: ${backup_gen}, у текущей установки: ${live_gen}; допустимы 2.0 и 3.1). После восстановления проверьте ${live_init} вручную."
    elif [[ "$backup_gen" != "$live_gen" ]]; then
        log_warn "Поколение протокола в бэкапе: ${backup_gen}, у текущей установки: ${live_gen}. После восстановления сервер станет поколения ${backup_gen}; клиентские профили другого поколения к нему не подключатся."
    fi
    return 0
}

# Парсер живого серверного конфига AmneziaWG (источник истины для AWG_*).
# Читает секцию [Interface] из awg0.conf и экспортирует AWG_* переменные
# АТОМАРНО: либо все 11 обязательных параметров (Jc/Jmin/Jmax/S1-S4/H1-H4)
# найдены и экспортированы, либо ничего не меняется в окружении и возврат 1.
# Это защищает от mixed-state при частично corrupt awg0.conf.
# I1-I5, ListenPort - опциональные, экспортируются если нашлись.
# Решает баг #38: regen использовал устаревшие значения из init-файла,
# а не актуальные из awg0.conf после ручной правки.
# shellcheck disable=SC2120  # Опциональный аргумент используется только в тестах
# load_awg_params_from_server_conf [конфиг] : параметры обфускации из живого конфига.
# Цикл разбора держит в переменных каждую строку [Interface], включая PrivateKey и
# HeaderProtectionKey, поэтому тело идёт с выключенной трассировкой.
load_awg_params_from_server_conf() {
    _awg_xtrace_guard _load_awg_params_from_server_conf_body "$@"
}

_load_awg_params_from_server_conf_body() {
    local conf="${1:-$SERVER_CONF_FILE}"
    [[ -f "$conf" ]] || return 1

    # Локальное накопление — экспортируем всё-или-ничего в конце
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
            # Комментарий после значения срезаем так же, как amneziawg-tools
            # (config_read_line режет строку по #). Иначе хвост `# ...` уехал бы
            # в клиентский конфиг и в vpn://, а проверка I1-I5 его не видит.
            value="${value%%#*}"
            # Trim trailing whitespace
            value="${value%"${value##*[![:space:]]}"}"
            # ContentPaddingAddition необязателен и читается без учёта регистра, как
            # его читают amneziawg-tools: иначе строчная запись применилась бы на
            # сервере и не попала бы в клиентские профили.
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

    # Atomic check: все 11 обязательных полей найдены?
    [[ -n "$_Jc" && -n "$_Jmin" && -n "$_Jmax" && \
       -n "$_S1" && -n "$_S2" && -n "$_S3" && -n "$_S4" && \
       -n "$_H1" && -n "$_H2" && -n "$_H3" && -n "$_H4" ]] || return 1

    # Atomic export — окружение модифицируется только при полном успехе
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

# Загрузка AWG параметров.
#
# Семантика источников (важно для предотвращения split-brain между сервером
# и клиентскими конфигами, см. #38):
#
#   * init-файл ($CONFIG_FILE = awgsetup_cfg.init) — для НЕ-AWG настроек
#     (OS_ID, ALLOWED_IPS, AWG_PORT, AWG_ENDPOINT и т.п.). Загружается всегда
#     если существует.
#   * Live server config ($SERVER_CONF_FILE = /etc/amnezia/amneziawg/awg0.conf)
#     — ЕДИНСТВЕННЫЙ источник истины для AWG протокольных параметров
#     (Jc/Jmin/Jmax/S1-S4/H1-H4/I1-I5) когда файл существует.
#
# Если live server config существует но НЕ содержит полного набора AWG
# параметров (повреждение / неполная ручная правка) — функция возвращает 1
# с явной ошибкой. Молчаливый fallback на устаревшие значения из init-файла
# создал бы split-brain: сервер живёт по новому awg0.conf, а regen выпускал
# бы клиентам старые J*/S*/H*. Это именно тот класс проблем, который
# elvaleto и Klavishnik сообщили в Discussion #38.
#
# Init-файл используется для AWG параметров ТОЛЬКО когда live server config
# вообще отсутствует — это путь bootstrap первой установки, когда awg0.conf
# ещё не записан, а generate_awg_params уже сохранил значения в init.
load_awg_params() {
    # 1. Базовые настройки из init (всегда, для не-AWG ключей)
    if [[ -f "$CONFIG_FILE" ]]; then
        # Режим применения, заданный до вызова (--apply-mode или окружение),
        # важнее сохранённого в init: иначе init затирал бы явный выбор.
        local _apply_mode_keep="${AWG_APPLY_MODE:-}"
        safe_load_config "$CONFIG_FILE" || log_warn "Не удалось загрузить $CONFIG_FILE"
        [[ -z "$_apply_mode_keep" ]] || export AWG_APPLY_MODE="$_apply_mode_keep"
    fi

    # Откуда пришли AWG-параметры: этим файлом отказ по I1-I5 называет место
    # правки. По умолчанию init-файл; ветка живого конфига ниже переопределяет.
    _AWG_PARAMS_SOURCE="$CONFIG_FILE"

    # 2. AWG протокольные параметры
    # Если CLI задал --preset/--jc/--jmin/--jmax, параметры уже set через generate_awg_params.
    # Пропускаем перезагрузку из awg0.conf чтобы не перезатереть свежие значения.
    if [[ -n "${CLI_PRESET:-}" || -n "${CLI_JC:-}" || -n "${CLI_JMIN:-}" || -n "${CLI_JMAX:-}" ]]; then
        log_debug "CLI overrides заданы — AWG params из generate_awg_params, не из $SERVER_CONF_FILE"
    elif [[ -f "$SERVER_CONF_FILE" ]]; then
        # Live config существует — он единственный источник истины.
        # Никакого fallback на init: иначе получим split-brain.
        # Unset I1-I5 перед парсингом: они опциональны, если их нет в live conf -
        # не должны утечь stale из init-файла.
        unset AWG_I1 AWG_I2 AWG_I3 AWG_I4 AWG_I5 AWG_CPA
        if ! load_awg_params_from_server_conf; then
            log_error "В $SERVER_CONF_FILE отсутствуют обязательные AWG-параметры"
            log_error "(Jc/Jmin/Jmax/S1-S4/H1-H4). Не использую устаревшие значения"
            log_error "из $CONFIG_FILE, чтобы не создавать split-brain между сервером"
            log_error "и клиентскими конфигами. Восстановите [Interface] секцию в"
            log_error "$SERVER_CONF_FILE или восстановите awg0.conf из бэкапа."
            return 1
        fi
        log_debug "AWG параметры загружены из $SERVER_CONF_FILE (live config)"
        _AWG_PARAMS_SOURCE="$SERVER_CONF_FILE"
    else
        # Bootstrap: server config ещё не существует (первая установка).
        # AWG_* должны быть в env через safe_load_config выше.
        log_debug "$SERVER_CONF_FILE не существует — использую AWG params из $CONFIG_FILE (bootstrap)"
    fi

    # 2а. Ключ защиты заголовков - до любого рендера. Проверка идёт и в ветке
    # CLI override, которая параметры из живого конфига не читает: ключ в нём от
    # этого не исчезает. Пока конфига нет (первая установка), проверку делает шаг 6
    # установщика в режиме install - единственном, где ключ можно создать.
    if [[ -f "$SERVER_CONF_FILE" ]]; then
        awg_hpk_ensure manage || return 1
    fi

    # 3. Проверка обязательных AWG 2.0 параметров
    local missing=0
    local param
    for param in AWG_Jc AWG_Jmin AWG_Jmax AWG_S1 AWG_S2 AWG_S3 AWG_S4 AWG_H1 AWG_H2 AWG_H3 AWG_H4; do
        if [[ -z "${!param:-}" ]]; then
            log_error "Параметр $param не найден"
            missing=1
        fi
    done
    if [[ $missing -eq 1 ]]; then
        return 1
    fi
    # 4. Безопасность I1-I5, по значениям ЛЮБОГО источника. Отсюда параметры
    # уходят в серверный конфиг и в клиентские профили: generate_client,
    # regenerate_client и render_server_config на отказе падают, а modify
    # vpn:// не собирает, прежний файл он удалил ещё до правки. Опасное
    # значение, вписанное в awg0.conf руками или приехавшее с чужим конфигом,
    # останавливается здесь, а не раздаётся клиентам.
    # ⚠️ Граница: пути, которые применяют уже лежащий awg0.conf к интерфейсу, эту
    # функцию не зовут и I1-I5 не проверяют: применение после remove и cron
    # истечения, manage restart, repair-module, откат restore, systemctl restart
    # и старт при загрузке системы. Отказ их не блокирует, но и не защищает.
    # ⚠️ Одно исключение: когда нас зовёт render_server_config, проверку делает
    # он сам, ПОСЛЕ --no-cps, который обнуляет I1. Иначе переустановка с
    # --no-cps - штатный способ убрать I1 - упиралась бы в отказ из-за того
    # самого I1, который она убирает. Отсрочка привязана к ИМЕНИ
    # непосредственного вызывающего, а не к переменной: переменную можно
    # унаследовать из окружения и тихо выключить проверку. Клиентские пути
    # NO_CPS не учитывают, для них отсрочки нет.
    if [[ "${FUNCNAME[1]:-}" != "render_server_config" ]]; then
        awg_cps_refuse_unsafe || return 1
    fi
    return 0
}

# Предупреждение о расхождении awgsetup_cfg.init с живым awg0.conf (issue #196).
#
# После установки awg0.conf - единственный источник параметров обфускации, а
# init читается для них только на bootstrap первой установки (см. load_awg_params
# выше). Правка AWG_* в init после установки на клиентов не влияет, и до этой
# проверки она игнорировалась МОЛЧА: файл назван как конфиг установки, человек
# правит его и не получает ни намёка, что смотреть надо в другое место.
#
# Гейт по времени модификации отсекает ложные срабатывания на штатном пути.
# Рекомендованный способ тюнинга (правка [Interface] в awg0.conf + regen) тоже
# разводит эти файлы, но init после установки никто не перезаписывает, поэтому
# там он остаётся СТАРШЕ live-конфига. Предупреждаем только когда init тронут
# ПОЗЖЕ awg0.conf - это и есть случай "поправил init, эффекта нет".
#
# Проверку намеренно не вешаем на load_awg_params: её зовёт и установщик на
# шаге 6, где init заведомо свежее ещё не перезаписанного awg0.conf, и
# предупреждение всплывало бы посреди штатной установки.
_AWG_DRIFT_KEYS=(AWG_Jc AWG_Jmin AWG_Jmax AWG_S1 AWG_S2 AWG_S3 AWG_S4 \
                 AWG_H1 AWG_H2 AWG_H3 AWG_H4 AWG_I1 AWG_I2 AWG_I3 AWG_I4 AWG_I5 AWG_CPA)

# _awg_drift_dump <init|live> <файл>: по строке на ключ в порядке массива выше,
# поэтому дампы двух источников сравнимы построчно. Читаем в subshell, чтобы не
# трогать окружение вызывающего - функцию можно звать в любой момент, не рискуя
# перетереть уже загруженные параметры.
_awg_drift_dump() {
    local mode="$1" src="$2"
    (
        # Наследованные значения гасим: иначе ключ, которого в источнике нет,
        # показался бы равным тому, что уже лежит в окружении. Если погасить
        # не удалось (переменная readonly в вызывающем окружении), сравнивать
        # нечего - выходим без маркера.
        unset "${_AWG_DRIFT_KEYS[@]}" 2>/dev/null || exit 1
        if [[ "$mode" == "init" ]]; then
            safe_load_config "$src" >/dev/null 2>&1 || exit 1
        else
            load_awg_params_from_server_conf "$src" >/dev/null 2>&1 || exit 1
        fi
        # Маркер успеха первой строкой: mapfile не отдаёт код возврата
        # процесса-поставщика, поэтому без него отказ парсера не отличить от
        # набора пустых значений.
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
    # init не новее live - значит расхождение, если оно есть, создано правкой
    # самого awg0.conf, то есть штатным путём. Молчим.
    [[ "$init" -nt "$live" ]] || return 0

    local -a ivals lvals
    mapfile -t ivals < <(_awg_drift_dump init "$init")
    mapfile -t lvals < <(_awg_drift_dump live "$live")
    # Без маркера сравнение недостоверно: разбор одного из источников отказал.
    # Молчим, а не объявляем разошедшимися все ключи разом - реальную причину
    # (например неполный [Interface]) дальше назовёт load_awg_params.
    [[ "${ivals[0]:-}" == "ok" && "${lvals[0]:-}" == "ok" ]] || return 0

    local drift="" i
    for i in "${!_AWG_DRIFT_KEYS[@]}"; do
        [[ "${ivals[i+1]:-}" == "${lvals[i+1]:-}" ]] || drift+="${_AWG_DRIFT_KEYS[i]#AWG_} "
    done
    [[ -n "$drift" ]] || return 0

    log_warn "Файл $init изменён позже $live, и параметры обфускации в них расходятся: ${drift% }"
    log_warn "Действуют значения из $live - после установки он единственный источник этих параметров. Если вы правили их в $init, до клиентов правка не дойдёт: меняйте секцию [Interface] в $live, затем перезапустите awg-quick@awg0 и выполните regen нужных клиентов."
    return 0
}

# ==============================================================================
# Генерация ключей
# ==============================================================================

# Генерация пары ключей (приватный + публичный)
# generate_keypair <name>
# Результат: keys/<name>.private, keys/<name>.public
generate_keypair() {
    case $- in *x*) _awg_xtrace_guard generate_keypair "$@"; return ;; esac
    local name="$1"
    if [[ -z "$name" ]]; then
        log_error "generate_keypair: не указано имя"
        return 1
    fi
    mkdir -p "$KEYS_DIR" || {
        log_error "Ошибка создания $KEYS_DIR"
        return 1
    }
    # 700 сразу при создании: mkdir -p с дефолтным umask дал бы 755, и до
    # secure_files инсталлера каталог ключей был бы доступен на чтение всем.
    chmod 700 "$KEYS_DIR"

    local privkey pubkey
    privkey=$(awg genkey) || {
        log_error "Ошибка генерации приватного ключа для '$name'"
        return 1
    }
    pubkey=$(echo "$privkey" | awg pubkey) || {
        log_error "Ошибка генерации публичного ключа для '$name'"
        return 1
    }

    # umask 077 в subshell: файл рождается сразу 600, без окна world-readable
    # между записью и chmod (при дефолтном umask 022 ключ был бы 644 на миг).
    ( umask 077; echo "$privkey" > "$KEYS_DIR/${name}.private" ) || {
        log_error "Ошибка записи приватного ключа для '$name'"
        return 1
    }
    ( umask 077; echo "$pubkey" > "$KEYS_DIR/${name}.public" ) || {
        log_error "Ошибка записи публичного ключа для '$name'"
        return 1
    }
    chmod 600 "$KEYS_DIR/${name}.private" "$KEYS_DIR/${name}.public" || {
        log_error "Ошибка установки прав на ключи '$name'"
        return 1
    }
    log_debug "Ключи для '$name' сгенерированы."
    return 0
}

# Генерация серверных ключей
# Результат: server_private.key, server_public.key в AWG_DIR
generate_server_keys() {
    case $- in *x*) _awg_xtrace_guard generate_server_keys; return ;; esac
    local privkey pubkey
    privkey=$(awg genkey) || {
        log_error "Ошибка генерации приватного ключа сервера"
        return 1
    }
    pubkey=$(echo "$privkey" | awg pubkey) || {
        log_error "Ошибка генерации публичного ключа сервера"
        return 1
    }

    # umask 077: без окна world-readable между записью и chmod (см. generate_keypair).
    ( umask 077; echo "$privkey" > "$AWG_DIR/server_private.key" ) || return 1
    ( umask 077; echo "$pubkey" > "$AWG_DIR/server_public.key" ) || return 1
    chmod 600 "$AWG_DIR/server_private.key" "$AWG_DIR/server_public.key" || {
        log_error "Ошибка установки прав на серверные ключи"
        return 1
    }
    log "Серверные ключи сгенерированы."
    return 0
}

# Гарантирует наличие $AWG_DIR/server_public.key.
# Если файла нет — пытается восстановить его из PrivateKey в awg0.conf
# (полезно для ручных установок вне нашего installer, где кеш серверного
# pubkey не создаётся на шаге 6). Возвращает 0 если ключ уже есть или
# успешно восстановлен, 1 если ни того ни другого.
_ensure_server_public_key() {
    case $- in *x*) _awg_xtrace_guard _ensure_server_public_key; return ;; esac
    [[ -f "$AWG_DIR/server_public.key" ]] && return 0

    [[ -f "$SERVER_CONF_FILE" ]] || {
        log_error "Не могу восстановить server_public.key — отсутствует $SERVER_CONF_FILE"
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
        log_error "Не найден PrivateKey в $SERVER_CONF_FILE — восстановить server_public.key невозможно"
        return 1
    fi
    mkdir -p "$AWG_DIR"
    local _tmp
    _tmp=$(awg_mktemp "$AWG_DIR") || return 1
    if ! echo "$_srv_priv" | awg pubkey > "$_tmp"; then
        rm -f "$_tmp"
        log_error "Не удалось вычислить публичный ключ через awg pubkey"
        return 1
    fi
    if ! mv -f "$_tmp" "$AWG_DIR/server_public.key"; then
        rm -f "$_tmp"
        log_error "Ошибка перемещения в $AWG_DIR/server_public.key"
        return 1
    fi
    chmod 600 "$AWG_DIR/server_public.key" 2>/dev/null || true
    log "server_public.key восстановлен из awg0.conf PrivateKey."
    return 0
}

# _mask_report_secrets : фильтр секретов для всего, что уходит на экран или в
# журнал из awg show и конфигов. Копия фильтра установщика: там он нужен и без
# скачанной библиотеки (--diagnostic), здесь - для manage check, show, diagnose и
# текста состояния службы в check и при отказе restore и restart.
# Тело во всех четырёх копиях одно и то же, тест паритета это проверяет; правила
# и пять строковых литералов апстрима разобраны в комментарии установщика.
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

# awg_hpk_path : путь к файлу ключа защиты заголовков (HeaderProtectionKey).
# Одно место и только по текущему AWG_DIR: путь не хранится в init, иначе второй
# источник пути пришлось бы сверять с этим при каждом переносе бэкапа.
awg_hpk_path() {
    [[ -n "${AWG_DIR:-}" ]] || return 1
    printf '%s\n' "$AWG_DIR/server_hpk.key"
}

# _awg_xtrace_guard <функция> [аргументы] : вызвать функцию, которая держит
# секрет, с выключенной трассировкой и вернуть прежнее состояние и её код.
# Установщик под --verbose включает set -x на весь прогон, и любое присваивание
# значения ключа уехало бы в stderr. Ограничения контракта: аргументы
# трассируются ДО выключения, поэтому передавать только несекретное; тело не
# делает exit и die, только return, иначе трассировка останется выключенной;
# значение секрета тело не печатает в stdout для $( ) вызывающего.
# Функции, которые сами держат ключи (генерация ключей, рендер серверного
# конфига, создание и перевыпуск клиентов, add_peer_to_server, vpn://,
# apply_config и функции manage, читающие ключи или состояние службы),
# начинаются строкой самозащиты:
#     case $- in *x*) _awg_xtrace_guard <своё имя> "$@"; return ;; esac
# (без "$@" у функции, которая аргументов не принимает).
# Под трассировкой функция вызывает себя повторно уже без неё, и тело
# выполняется один раз; имя функции и FUNCNAME[1] вложенных вызовов
# сохраняются. Для функции с секретом в аргументах так нельзя: строка
# самозащиты сама печатает аргументы. Исключение из запрета die: modify_client
# завершает процесс через die на части отказов; трассировка там не
# возвращается, но процесс и так выходит.
# Тело выполняется под `||` (у функций со строкой самозащиты - под трассировкой,
# у обёрток вида `_awg_xtrace_guard _..._body` - всегда), поэтому set -e и
# ловушка ERR в нём не действуют. Точки входа, которые загружают эту
# библиотеку, их не включают, а установщик вызывает эти функции под `||`; если
# set -e появится, этот механизм надо пересмотреть.
_awg_xtrace_guard() {
    local _xt=0 _rc=0
    case $- in *x*) _xt=1; set +x ;; esac
    "$@" || _rc=$?
    if (( _xt )); then set -x; fi
    return "$_rc"
}

# _awg_hpk_file_valid <файл> : файл ключа ровно из одной строки с LF, и эта
# строка - ключ в форме key_from_base64 amneziawg-tools (44 символа, в конце '=',
# последний значащий символ несёт нулевые младшие биты). CRLF, пустой файл,
# вторая строка, каталог или символическая ссылка - не ключ. Первая строка
# читается во внутреннюю переменную (функцию зовут только тела под
# _awg_xtrace_guard): read без завершающего LF отказывает, а размер ровно 45 байт
# исключает хвост или вторую строку после ключа. Строка не попадает в argv.
_awg_hpk_file_valid() {
    local f="$1" n _hv_line
    [[ -f "$f" && ! -L "$f" && -r "$f" ]] || return 1
    IFS= read -r _hv_line < "$f" || return 1
    [[ "$_hv_line" =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]] || return 1
    n=$(wc -c < "$f") || return 1
    [[ "$n" -eq 45 ]]
}

# awg_generate_hpk : создать файл ключа, если его нет. Ключ - вывод `awg genkey`
# (приложение Amnezia генерирует этот ключ так же, как приватный ключ WireGuard),
# записанный СРАЗУ во временный файл: значение не проходит через переменные и
# argv. Существующий файл не трогается. Итоговое имя появляется через ln, который
# отказывает, если файл уже есть: без окна, в котором чужой ключ перезаписался бы.
# Если файла ключа нет, а серверный конфиг уже есть, отказывает: новый ключ появляется
# только на первой установке, до записи конфига. Рабочий код эту обёртку не вызывает:
# awg_hpk_ensure зовёт _awg_generate_hpk_body внутри своей защиты от трассировки.
awg_generate_hpk() {
    _awg_xtrace_guard _awg_generate_hpk_body
}

_awg_generate_hpk_body() {
    local key tmp state
    key=$(awg_hpk_path) || { log_error "Ошибка: AWG_DIR не задан, ключ защиты заголовков не создаю"; return 1; }
    state=$(_awg_hpk_file_state "$key")
    case "$state" in
        ok)     return 0 ;;
        absent) ;;
        *)      _awg_hpk_file_refuse "$key" "$state"; return 1 ;;
    esac
    if [[ -f "$SERVER_CONF_FILE" ]]; then
        local _hs_any=0 _hs_if=0 _hs_out=0 _hs_val=""
        _awg_hpk_conf_scan "$SERVER_CONF_FILE" || { log_error "Ошибка: не удалось разобрать $SERVER_CONF_FILE, новый ключ защиты заголовков не создаю"; return 1; }
        if (( _hs_any > 0 )); then
            log_error "Ошибка: HeaderProtectionKey уже есть в $SERVER_CONF_FILE, новый ключ не создаю"
            return 1
        fi
        log_error "Ошибка: $SERVER_CONF_FILE уже существует без HeaderProtectionKey, новый ключ поверх существующего конфига не создаю"
        return 1
    fi
    mkdir -p "$AWG_DIR" || return 1
    tmp=$(awg_mktemp "$AWG_DIR") || {
        log_error "Ошибка: не удалось сгенерировать ключ защиты заголовков: не создан временный файл в $AWG_DIR"
        return 1
    }
    if ! ( umask 077; awg genkey > "$tmp" ); then
        rm -f "$tmp"
        log_error "Ошибка: не удалось сгенерировать ключ защиты заголовков (awg genkey)"
        return 1
    fi
    if ! _awg_hpk_file_valid "$tmp"; then
        rm -f "$tmp"
        log_error "Ошибка: awg genkey вернул значение не в форме ключа, файл ключа не записан"
        return 1
    fi
    if ! chmod 600 "$tmp" || ! ln -T "$tmp" "$key" 2>/dev/null; then
        rm -f "$tmp"
        log_error "Ошибка: не удалось сохранить ключ защиты заголовков в $key"
        return 1
    fi
    rm -f "$tmp"
    log "Ключ защиты заголовков создан: $key"
    return 0
}

# _awg_hpk_conf_scan <конфиг> : строки HeaderProtectionKey конфига тем же разбором,
# что у валидатора (регистр ключа и секции не важен, комментарий и пробелы сняты).
# Значение не печатает: выставляет переменные, объявленные локально в вызывающей
# функции, - _hs_any (строк в любой секции), _hs_if (в [Interface]), _hs_out (вне
# неё, включая строки до первого заголовка), _hs_val (значение последней строки в
# [Interface]). Сбой разбора - код 1.
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

# _awg_hpk_file_state <файл> : absent, notregular (каталог или символическая
# ссылка), unreadable, damaged или ok. «Не читается» и «нет» различаются: ошибка
# чтения не превращается в тихое отсутствие, после которого файл перезаписали бы.
_awg_hpk_file_state() {
    local f="$1"
    if [[ -L "$f" ]]; then echo notregular; return 0; fi
    if [[ ! -e "$f" ]]; then echo absent; return 0; fi
    if [[ ! -f "$f" ]]; then echo notregular; return 0; fi
    if [[ ! -r "$f" ]]; then echo unreadable; return 0; fi
    if _awg_hpk_file_valid "$f"; then echo ok; else echo damaged; fi
    return 0
}

# _awg_hpk_write_value <файл> : записать значение _hs_val вызывающей функции через
# временный файл: builtin printf (значение не в argv), проверка формы, права 600, ln
# на итоговое имя без перезаписи существующего.
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
        notregular) log_error "Файл ключа $1 не обычный файл (каталог или символическая ссылка): ключ защиты заголовков не проверить" ;;
        unreadable) log_error "Файл ключа $1 не читается" ;;
        *)          log_error "Файл ключа $1 повреждён: нужна одна строка с ключом" ;;
    esac
}

# awg_hpk_ensure <install|manage> : согласованность ключа защиты заголовков перед
# любым рендером профиля. awg0.conf - источник истины, server_hpk.key - его копия.
#   - маркер из init читается заново в подоболочке: переменная AWG_PROTOCOL,
#     оставшаяся в окружении от прежней загрузки, решать не должна;
#   - установка 2.0 с ключом в конфиге (в любой секции) - отказ: рендер выдал бы
#     профили без ключа, которые молча не подключаются; лишний файл - предупреждение;
#   - 3.1: ключ в конфиге проверяется как у валидатора (одна строка в [Interface],
#     форма ключа); потерянный файл восстанавливается из конфига и НИКОГДА не
#     заменяется новым ключом; расходящийся файл - отказ, файл не трогается;
#   - новый ключ создаётся только в режиме install и только пока серверного конфига
#     ещё нет (первая установка); поверх существующего конфига - никогда.
# Граница: живой интерфейс не проверяется (ключ на нём залипает), manage restore
# этой проверкой не защищён.
awg_hpk_ensure() {
    _awg_xtrace_guard _awg_hpk_ensure_body "$@"
}

_awg_hpk_ensure_body() {
    local mode="${1:-}" key gen state _line
    local _hs_any=0 _hs_if=0 _hs_out=0 _hs_val=""
    case "$mode" in
        install|manage) ;;
        *) log_error "awg_hpk_ensure: нужен режим install или manage"; return 1 ;;
    esac
    key=$(awg_hpk_path) || { log_error "AWG_DIR не задан: ключ защиты заголовков не проверен"; return 1; }
    gen=$(_awg_generation_from_init "$CONFIG_FILE") || gen=broken
    if [[ -f "$SERVER_CONF_FILE" ]]; then
        _awg_hpk_conf_scan "$SERVER_CONF_FILE" || { log_error "Не удалось разобрать $SERVER_CONF_FILE: ключ защиты заголовков не проверен"; return 1; }
    fi

    # Испорченный маркер важен только там, где ключ есть. Без ключа установка ведёт себя
    # как 2.0 до появления маркера, и add или regen не должны отказать из-за правки init.
    if [[ "$gen" == broken ]]; then
        if (( _hs_any > 0 )) || [[ -e "$key" || -L "$key" ]]; then
            log_error "Маркер поколения AWG_PROTOCOL в $CONFIG_FILE не читается (допустимы 2.0 и 3.1): ключ защиты заголовков не проверен"
            return 1
        fi
        log_warn "Маркер поколения AWG_PROTOCOL в $CONFIG_FILE не читается (допустимы 2.0 и 3.1): ключ защиты заголовков не проверен"
        return 0
    fi

    if [[ "$gen" != "3.1" ]]; then
        if (( _hs_any > 0 )); then
            log_error "В $SERVER_CONF_FILE задан HeaderProtectionKey (третья линия), а установка помечена поколением 2.0: профили без ключа не подключатся. Проверьте маркер AWG_PROTOCOL в $CONFIG_FILE или уберите ключ из конфига"
            return 1
        fi
        if [[ -e "$key" || -L "$key" ]]; then
            log_warn "Файл $key не используется: установка помечена поколением 2.0"
        fi
        return 0
    fi

    if [[ ! -f "$SERVER_CONF_FILE" ]]; then
        if [[ "$mode" != install ]]; then
            log_error "Установка помечена поколением 3.1, а серверного конфига нет ($SERVER_CONF_FILE): ключ защиты заголовков не проверить"
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
        log_error "HeaderProtectionKey стоит вне секции [Interface] в $SERVER_CONF_FILE"
        return 1
    fi
    if (( _hs_if > 1 )); then
        log_error "HeaderProtectionKey задан в [Interface] ${_hs_if} раза в $SERVER_CONF_FILE: оставьте один ключ"
        return 1
    fi
    state=$(_awg_hpk_file_state "$key")
    if (( _hs_if == 0 )); then
        if [[ "$state" == absent ]]; then
            log_error "Установка помечена поколением 3.1, а HeaderProtectionKey нет ни в $SERVER_CONF_FILE, ни в $key: выдавать профили нельзя"
        else
            log_error "HeaderProtectionKey убран из $SERVER_CONF_FILE, а файл ключа $key есть: верните ключ в конфиг или восстановите конфиг из бэкапа"
        fi
        return 1
    fi
    if ! [[ "$_hs_val" =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]]; then
        log_error "HeaderProtectionKey в $SERVER_CONF_FILE не похож на ключ: нужны 32 байта в base64, 44 символа"
        return 1
    fi
    case "$state" in
        absent)
            if ! _awg_hpk_write_value "$key"; then
                log_error "Ошибка: не удалось восстановить файл ключа защиты заголовков $key"
                return 1
            fi
            log "Файл ключа защиты заголовков восстановлен из $SERVER_CONF_FILE: $key"
            return 0
            ;;
        ok)
            if ! IFS= read -r _line < "$key"; then
                log_error "Файл ключа $key не читается"
                return 1
            fi
            [[ "$_line" == "$_hs_val" ]] && return 0
            log_error "Ключ в $key не совпадает с HeaderProtectionKey в $SERVER_CONF_FILE: это ручная правка или неудачный restore. Какой из них верный, решите вручную"
            return 1
            ;;
        *)
            _awg_hpk_file_refuse "$key" "$state"
            return 1
            ;;
    esac
}

# ==============================================================================
# Рендеринг конфигураций
# ==============================================================================

# Вычисление IPv6-адреса сервера (хост ::1) из туннельной подсети.
# Вход: PREFIX::/MASK (например fddd:2c4:2c4:2c4::/64).
# Выход: PREFIX::1/MASK (например fddd:2c4:2c4:2c4::1/64).
# Допущение: подсеть всегда оканчивается на ::/MASK (так формирует install-скрипт).
# Если завершающего ::/ нет - возвращаю вход без изменений (defensive fallback).
_derive_ipv6_server_addr() {
    local subnet="$1"
    if [[ "$subnet" == *"::/"* ]]; then
        echo "${subnet/::\//::1\/}"
    else
        echo "$subnet"
    fi
}

# _awg31_append_profile_lines <файл> : дописать в [Interface] строки третьей
# линии - HeaderProtectionKey и ContentPaddingAddition.
# На установке 2.0 не делает ничего и возвращает 0: ветка 2.0 не меняется. При
# нечитаемом маркере без файла ключа тоже ничего не пишет (правило awg_hpk_ensure).
# 🔴 Значение ключа НЕ проходит через argv и не попадает в трассировку:
# функция обёрнута защитой, а из файла читается перенаправлением. Клиентский
# рендер сам не защищён (ключ клиента приходит аргументом; защищены его
# вызывающие generate_client и regenerate_client), поэтому читать ключ прямо в нём
# было бы утечкой под --verbose.
# Значение берётся из файла ключа. Сверять его здесь с серверным конфигом НЕ
# надо: при существующем awg0.conf оба рендера идут через load_awg_params, а тот
# зовёт awg_hpk_ensure, который расхождение файла и конфига уже ловит и называет
# причину. На первой установке конфига ещё нет, и согласованность обеспечивает
# awg_hpk_ensure install в шаге 6. Вторая проверка тем же кодом была бы мёртвой и
# создавала бы вид двойной защиты.
_awg31_append_profile_lines() {
    _awg_xtrace_guard _awg31_append_profile_lines_body "$@"
}

_awg31_append_profile_lines_body() {
    local target="$1" gen keyfile key why cpa
    # Нечитаемый маркер - то же правило, что в awg_hpk_ensure: без ключа это не
    # повод отнимать add и regen из-за правки init, строки третьей линии просто
    # не пишутся; с файлом ключа поколение не угадать, и это отказ.
    if ! gen=$(_awg_generation_from_init "$CONFIG_FILE"); then
        keyfile=$(awg_hpk_path) || { log_error "AWG_DIR не задан: ключ защиты заголовков не проверен"; return 1; }
        if [[ -e "$keyfile" || -L "$keyfile" ]]; then
            log_error "Маркер поколения AWG_PROTOCOL в $CONFIG_FILE не читается (допустимы 2.0 и 3.1), а файл ключа $keyfile есть: конфиг не записан"
            return 1
        fi
        return 0
    fi
    [[ "$gen" == "3.1" ]] || return 0
    keyfile=$(awg_hpk_path) || { log_error "AWG_DIR не задан: ключ защиты заголовков не прочитать"; return 1; }
    if [[ ! -f "$keyfile" ]]; then
        log_error "Установка помечена поколением 3.1, а файла ключа $keyfile нет: профиль без ключа не подключится, конфиг не записан"
        return 1
    fi
    IFS= read -r key < "$keyfile" || { log_error "Файл ключа $keyfile не читается: конфиг не записан"; return 1; }
    if ! [[ "$key" =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]]; then
        log_error "Файл ключа $keyfile не похож на ключ: нужны 32 байта в base64, 44 символа"
        return 1
    fi
    # Пишем ровно то значение, которое проверили: комментарий и пробелы
    # awg_cpa_check_safe отбрасывает так же, как tools, а в конфиге и дальше в
    # ссылке vpn:// они стали бы частью значения.
    cpa="${AWG_CPA:-}"
    cpa="${cpa%%#*}"
    cpa="${cpa//[[:space:]]/}"
    why=$(awg_cpa_check_safe "$cpa") || {
        log_error "ContentPaddingAddition: ${why}. Конфиг не записан"
        return 1
    }
    printf 'HeaderProtectionKey = %s\n' "$key" >> "$target" || {
        log_error "Ошибка записи ключа защиты заголовков в конфиг"
        return 1
    }
    printf 'ContentPaddingAddition = %s\n' "$cpa" >> "$target" || {
        log_error "Ошибка записи ContentPaddingAddition в конфиг"
        return 1
    }
    return 0
}

# Рендер серверного конфига AWG 2.0
# render_server_config [peers_source_file]
# Использует глобальные переменные из load_awg_params()
# peers_source_file (необязательный): файл, чьи [Peer]-блоки переносятся в
# новый конфиг ДО атомарного mv (обычно бэкап живого awg0.conf). Благодаря
# этому живой конфиг ни на мгновение не остаётся без пиров - сбой между
# render и отдельным append оставлял бы безпировый файл, а повторный запуск
# шага 6 уже бэкапил бы его (потеря всех пиров при --force reinstall).
# shellcheck disable=SC2154  # AWG_* vars loaded via load_awg_params -> source
render_server_config() {
    case $- in *x*) _awg_xtrace_guard render_server_config "$@"; return ;; esac
    local peers_source="${1:-}"
    load_awg_params || return 1

    # --no-cps (issue #159): load_awg_params перечитывает I1 из живого awg0.conf
    # при переустановке. При NO_CPS=1 намеренно обнуляем I1, иначе серверный
    # конфиг тихо восстановил бы CPS вопреки флагу.
    if grep -qE '^[[:space:]]*(export[[:space:]]+)?NO_CPS=1' "$CONFIG_FILE" 2>/dev/null; then
        AWG_I1=''
    fi
    # I1-I5 проверяем здесь, ПОСЛЕ --no-cps: load_awg_params эту проверку для
    # нас отложил (см. там шаг 4), иначе переустановка с --no-cps упиралась бы в
    # отказ из-за того самого I1, который она убирает.
    awg_cps_refuse_unsafe || return 1

    # Порт для НОВОГО awg0.conf берём из init-файла (намерение пользователя:
    # флаг --port или сохранённый прежний порт), а НЕ из перезаписываемого
    # старого awg0.conf. load_awg_params перечитывает ListenPort из живого
    # конфига, поэтому без этого --port при --force молча игнорировался бы.
    # render_server_config вызывается только из install, regen клиентов
    # (regenerate_client) идёт своим путём и не затрагивается.
    local _init_port
    _init_port=$(grep -oP '^\s*export AWG_PORT=\K[0-9]+' "$CONFIG_FILE" 2>/dev/null | head -n1)
    [[ -n "$_init_port" ]] && AWG_PORT="$_init_port"

    local server_privkey
    if [[ -f "$AWG_DIR/server_private.key" ]]; then
        server_privkey=$(cat "$AWG_DIR/server_private.key")
    else
        log_error "Приватный ключ сервера не найден: $AWG_DIR/server_private.key"
        return 1
    fi

    local nic
    nic=$(get_main_nic)
    if [[ -z "$nic" ]]; then
        log_error "Не удалось определить сетевой интерфейс."
        log_error "Укажите его вручную и перезапустите шаг 6: export AWG_MAIN_NIC=<iface>"
        log_error "Доступные интерфейсы: $(ip -br link 2>/dev/null | awk '$1!="lo"{printf "%s ", $1}')"
        return 1
    fi

    # IPv6-only egress: интерфейс есть, но IPv4-выхода нет. Туннель на IPv4 (10.x)
    # NAT'ится через MASQUERADE - на таком хосте IPv4-трафик клиентов наружу не
    # пойдёт (issue #166). Предупреждаем, не блокируем: peer-to-peer внутри
    # туннеля и IPv6-туннель (--allow-ipv6-tunnel) работают.
    if host_lacks_ipv4_egress "$nic"; then
        log_warn "Похоже, хост IPv6-only: у $nic нет IPv4-выхода."
        log_warn "VPN туннелирует IPv4, поэтому IPv4-трафик клиентов наружу не пойдёт."
        log_warn "Нужен хост с IPv4-адресом (dual-stack) или NAT64."
    fi

    local server_ip subnet_mask
    server_ip=$(echo "$AWG_TUNNEL_SUBNET" | cut -d'/' -f1)
    subnet_mask=$(echo "$AWG_TUNNEL_SUBNET" | cut -d'/' -f2)

    # Адрес [Interface]: IPv4 всегда, IPv6 только при включённом туннеле.
    # Сервер берёт хост ::1 в туннельной IPv6-подсети.
    # IPV6_SUBNET имеет форму PREFIX::/MASK (по умолчанию fddd:2c4:2c4:2c4::/64),
    # поэтому адрес сервера получаю заменой завершающего ::/MASK на ::1/MASK.
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
        log_error "Ошибка создания $conf_dir"
        return 1
    }

    # PostUp/PostDown правила для маршрутизации
    local postup="iptables -I FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${nic} -j MASQUERADE"
    local postdown="iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${nic} -j MASQUERADE"

    # MSS/PMTU-clamp: фиксируем TCP MSS под туннельный MTU, чтобы крупные сегменты
    # не упирались в 1280-туннель при фильтрованном ICMP "frag needed" (PMTUD-блэкхол:
    # VPN подключается, но крупные страницы/закачки виснут на мобильных/double-NAT/
    # каскадных путях). Фикс из AWG_MTU детерминирован при жёстко заданном MTU и
    # авто-синхронен с ним; clamp-to-pmtu зависел бы от egress-маршрута. Би-directional
    # (-o %i и -i %i) кэпит MSS в обе стороны. IPv4: MTU-40, IPv6: MTU-60. Только SYN,
    # таблица mangle (отдельная от UFW/filter). Стиль -A/-D зеркалит MASQUERADE выше.
    local awg_mtu="${AWG_MTU:-1280}"
    local mss4=$(( awg_mtu - 40 ))
    local mss6=$(( awg_mtu - 60 ))
    postup="${postup}; iptables -t mangle -A FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss4}; iptables -t mangle -A FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss4}"
    postdown="${postdown}; iptables -t mangle -D FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss4}; iptables -t mangle -D FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss4}"

    # Изоляция клиентов (issue #178): DROP awg0->awg0 до общего ACCEPT.
    # PostUp выполняется слева направо, -I вставляет в начало цепочки -
    # правило, добавленное В СТРОКЕ ПОЗЖЕ, оказывается В ЦЕПОЧКЕ ВЫШЕ, поэтому
    # DROP дописывается в конец postup. Перед -I дренируем stale-копии циклом
    # -D: после сбойного PostDown копия DROP иначе копилась бы с каждым up
    # (ревью PR #179). Именно drain, а не -C: stale-копия к этому моменту
    # лежит НИЖЕ свежевставленного ACCEPT, -C нашёл бы её, пропустил вставку -
    # и awg0->awg0 трафик уходил бы в ACCEPT (изоляция молча сломана).
    # PostDown с '2>/dev/null || true': после переустановки on->off правила в
    # running-наборе нет, и упавший -D не должен ронять awg-quick down
    # (down-фаза restart работает уже с новым конфигом). Unset
    # CLIENT_ISOLATION = 1: конфиги до v5.20 изолированы.
    if [[ "${CLIENT_ISOLATION:-1}" -eq 1 ]]; then
        postup="${postup}; while iptables -D FORWARD -i %i -o %i -j DROP 2>/dev/null; do :; done; iptables -I FORWARD -i %i -o %i -j DROP"
        postdown="${postdown}; iptables -D FORWARD -i %i -o %i -j DROP 2>/dev/null || true"
    fi

    # IPv6 правила: при включённом IPv6-туннеле (FORWARD внутри туннеля + MASQUERADE
    # на публичный интерфейс). MASQUERADE безвреден если у VPS нет native IPv6 -
    # это no-op, пока нет IPv6 default route, зато peer-to-peer внутри туннеля работает.
    # Использую тот же nic, что и IPv4 MASQUERADE (не хардкожу интерфейс).
    # Условие DISABLE_IPV6=0 сохранено для байт-в-байт совместимости с v5.14.x:
    # установка с --allow-ipv6 (без туннеля) получает те же IPv6-правила фильтра, что и раньше.
    if [[ "${ALLOW_IPV6_TUNNEL:-0}" -eq 1 || "${DISABLE_IPV6:-1}" -eq 0 ]]; then
        postup="${postup}; ip6tables -I FORWARD -i %i -j ACCEPT; ip6tables -t nat -A POSTROUTING -o ${nic} -j MASQUERADE; ip6tables -t mangle -A FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss6}; ip6tables -t mangle -A FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss6}"
        postdown="${postdown}; ip6tables -D FORWARD -i %i -j ACCEPT; ip6tables -t nat -D POSTROUTING -o ${nic} -j MASQUERADE; ip6tables -t mangle -D FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss6}; ip6tables -t mangle -D FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss6}"
        # Изоляция и для IPv6-туннеля: без DROP dual-stack клиенты в split-
        # режимах достижимы друг для друга по fddd::/64 (IPV6_SUBNET уже в их
        # AllowedIPs через render_client_config) - issue #178.
        if [[ "${ALLOW_IPV6_TUNNEL:-0}" -eq 1 && "${CLIENT_ISOLATION:-1}" -eq 1 ]]; then
            postup="${postup}; while ip6tables -D FORWARD -i %i -o %i -j DROP 2>/dev/null; do :; done; ip6tables -I FORWARD -i %i -o %i -j DROP"
            postdown="${postdown}; ip6tables -D FORWARD -i %i -o %i -j DROP 2>/dev/null || true"
        fi
    fi

    # Формируем конфиг через временный файл (атомарная запись).
    # temp создаём в каталоге итогового конфига, чтобы mv был атомарным rename
    # на той же ФС (а не cross-fs copy+unlink, если /tmp = tmpfs).
    local tmpfile
    tmpfile=$(awg_mktemp "$(dirname "$SERVER_CONF_FILE")") || { log_error "Ошибка mktemp"; return 1; }

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

    # Добавляем I1-I5 только если заданы (CPS-параметры опциональны).
    # I2-I5 задаются админом вручную в awg0.conf (issue #71), переносятся как есть.
    [[ -n "${AWG_I1:-}" ]] && echo "I1 = ${AWG_I1}" >> "$tmpfile"
    [[ -n "${AWG_I2:-}" ]] && echo "I2 = ${AWG_I2}" >> "$tmpfile"
    [[ -n "${AWG_I3:-}" ]] && echo "I3 = ${AWG_I3}" >> "$tmpfile"
    [[ -n "${AWG_I4:-}" ]] && echo "I4 = ${AWG_I4}" >> "$tmpfile"
    [[ -n "${AWG_I5:-}" ]] && echo "I5 = ${AWG_I5}" >> "$tmpfile"
    _awg31_append_profile_lines "$tmpfile" || { rm -f "$tmpfile"; return 1; }

    # Перенос [Peer]-блоков из peers_source в temp ДО mv (см. док-комментарий).
    # Буфер сбрасывается на каждом новом [Peer]: переносятся ВСЕ блоки.
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
                log_error "Ошибка переноса [Peer]-блоков в новый конфиг"
                return 1
            }
        fi
    fi

    if ! mv "$tmpfile" "$SERVER_CONF_FILE"; then
        rm -f "$tmpfile"
        log_error "Ошибка записи серверного конфига"
        return 1
    fi
    chmod 600 "$SERVER_CONF_FILE"
    log "Серверный конфиг создан: $SERVER_CONF_FILE"
    return 0
}

# Предупредить, что списочное значение задано несколькими строками и они были
# объединены. Молчать тут нельзя: объединение меняет то, что человек написал
# руками, и если он ошибся, узнать об этом он должен от нас, а не от клиента.
_awg_warn_multiline() {
    local raw="$1" key="$2" name="$3" n
    n=$(printf '%s\n' "$raw" | grep -c '[^[:space:]]') || n=0
    (( n > 1 )) && log_warn "'${key}' у клиента '${name}' задан ${n} строками - значения объединены в одну."
    return 0
}

# Нормализация списка через запятую к каноническому виду "a, b, c".
#
# Зачем: установщик пишет AllowedIPs и DNS через запятую С ПРОБЕЛОМ, а
# regenerate_client читал эти значения через `tr -d '[:space:]'` и записывал
# прочитанное обратно, поэтому первый же regen оставлял в .conf слипшийся
# список (D#38 @humowns). Здесь список разбирается поэлементно, а разделитель
# ставится канонически, и повторный regen ЛЕЧИТ уже испорченные конфиги.
#
# 🔴 НЕ применять к значению, которое уходит в JSON-массив allowed_ips сборщика
# vpn:// (см. комментарий у generate_vpn_uri): там нужна КОМПАКТНАЯ форма.
# Одна редакция этой правки нормализацию туда уже завела, и на стенде это дало
# ведущий пробел внутри 33 элементов массива из 34.
#
# Пробелы срезаются ВНУТРИ элемента, а не только по краям: элементы этих двух
# списков (CIDR и адреса резолверов) пробелов не содержат никогда, а валидатор
# `manage modify` чистит их так же, через `${tok//[[:space:]]/}`. Заодно это
# лечит значения вида "1.1.1. 1", которые прежний `tr` вычищал случайно.
#
# Разбор через `read -a`, а не `for x in $raw`, чтобы значение не попало под
# glob-раскрутку. Trim инлайном, без вызова функции: подстановка на КАЖДЫЙ
# элемент порождает subshell, и на списке в 2000 записей это 18 секунд против
# 0.1 - а regen без имени идёт по всем клиентам сразу.
#
# ⚠️ Контракт: вход ОДНОСТРОЧНЫЙ. `read` без `-d` возьмёт только первую строку,
# поэтому многострочное значение вызывающий обязан склеить сам (`paste -sd, -`).
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

# Валидация списка AllowedIPs как значения для клиентского конфига (Issue #253).
# Отсечение опасных символов + позитивная проверка каждого токена как CIDR
# (IPv4/IPv6 с опциональным /n) + запрет пустых элементов (ведущая/хвостовая/
# двойная запятая). Исходный вызывающий - modify (исторически валидация жила
# инлайн в его диспетчере, C5); с Issue #253 хелпер - единая точка и для ранней
# валидации `manage add --allowed-ips` (до создания первого клиента), и для
# defense-in-depth в generate_client (env-контракт CLIENT_ALLOWED_IPS).
# Разбор через read -a с квоченным обходом, а не `for x in $value`: невошедший
# в кавычки цикл раскрывает пути (файл с именем «10.0.0.0» в текущем каталоге
# пропускал значение «10.0.0.*»), та же причина, по которой awg_normalize_csv
# парсит массивом.
awg_validate_allowed_ips_list() {
    local value="$1"
    case "$value" in
        *$'\n'*|*$'\r'*|*\\*|*\"*|*\'*|"")
            log_error "Невалидный AllowedIPs: '$value'"
            return 1 ;;
    esac
    case "$value" in
        ,*|*,|*,,*)
            log_error "Невалидный AllowedIPs '$value': пустой элемент списка (лишняя запятая)"
            return 1 ;;
    esac
    local -a _aip_parts
    local _aip_tok
    IFS=',' read -r -a _aip_parts <<< "$value"
    for _aip_tok in "${_aip_parts[@]}"; do
        _aip_tok="${_aip_tok//[[:space:]]/}"
        if [[ -z "$_aip_tok" ]]; then
            log_error "Невалидный AllowedIPs '$value': пустой элемент списка (лишняя запятая)"
            return 1
        fi
        if ! _valid_cidr "$_aip_tok"; then
            log_error "Невалидный AllowedIPs '$value': '$_aip_tok' не похож на CIDR (IPv4/IPv6 с опциональным префиксом /n)"
            return 1
        fi
    done
    return 0
}

# Валидация списка DNS для клиентского конфига: только IPv4/IPv6 через запятую,
# без имён хостов и пустых элементов. Единая точка для `manage modify DNS` и для
# CLIENT_DNS из awgsetup_cfg.init (две инлайн-копии разъезжаются, см. выше про
# AllowedIPs). Разбор через read -a, а не `for x in $value`: прежний цикл в modify
# раскрывал шаблоны, и «1.1.1.*» проходило, если в текущем каталоге лежал файл 1.1.1.1.
awg_validate_dns_list() {
    local value="$1" tok
    local -a parts
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
    IFS=',' read -r -a parts <<< "$value"
    for tok in "${parts[@]}"; do
        tok="${tok//[[:space:]]/}"
        if [[ -z "$tok" ]]; then
            log_error "Невалидный DNS '$value': пустой элемент списка (лишняя запятая)"
            return 1
        fi
        if ! _valid_ipv4 "$tok" && ! _valid_ipv6 "$tok"; then
            log_error "Невалидный DNS '$value': '$tok' не похож на IPv4/IPv6-адрес"
            return 1
        fi
    done
    return 0
}

# DNS для НОВОГО клиентского конфига: CLIENT_DNS из awgsetup_cfg.init, иначе
# прежнее «1.1.1.1, 1.0.0.1». Невалидное значение - громкий отказ, а не тихий
# откат на значение по умолчанию: человек, который вписал свой резолвер, иначе
# получил бы клиентов с Cloudflare и не узнал бы об этом. Существующих клиентов
# не касается: regen сохраняет их DNS из текущего .conf.
awg_client_dns() {
    if [[ -z "${CLIENT_DNS:-}" ]]; then
        printf '%s' "1.1.1.1, 1.0.0.1"
        return 0
    fi
    if ! awg_validate_dns_list "$CLIENT_DNS"; then
        log_error "CLIENT_DNS в $CONFIG_FILE невалиден ('$CLIENT_DNS'). Исправьте значение (IP через запятую) или удалите строку - тогда будет 1.1.1.1, 1.0.0.1."
        return 1
    fi
    awg_normalize_csv "$CLIENT_DNS"
}

# Допустимый диапазон MTU для AWG / WireGuard.
# Минимум 576 (классический минимум IPv4), максимум 9100 (verge на jumbo frame).
# Значения вне диапазона трактуются как ошибочные и игнорируются (fallback к 1280).
_validate_mtu() {
    local v="$1"
    [[ "$v" =~ ^[0-9]+$ ]] || return 1
    (( v >= 576 && v <= 9100 )) || return 1
    return 0
}

# Извлечение MTU из секции [Interface] серверного awg0.conf (если файл существует).
# Печатает целое число в stdout, либо ничего если MTU не найден / файл недоступен.
# Last-wins: если в [Interface] несколько строк MTU = ..., возвращается последняя
# (так же как awg-quick применяет последнее присвоение).
# Используется render_client_config для синхронизации MTU клиента с сервером
# (баг v5.14.0: ручная правка MTU в awg0.conf не подхватывалась regen-ом).
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

# Рендер клиентского конфига AWG 2.0
# render_client_config <name> <client_ip> <client_privkey> <server_pubkey> <endpoint> <port> [client_ipv6]
#
# client_ipv6 (необязательный, 7-й аргумент): IPv6-адрес клиента без префикса
# длины (например fddd:2c4:2c4:2c4::5). Если непустой и ALLOW_IPV6_TUNNEL=1:
#   - Address = <ipv4>/32, <ipv6>/128
#   - AllowedIPs (зеркалю IPv4 routing mode в IPv6, intent-mirroring):
#       full tunnel (_is_full_tunnel, режимы 1 и 2): + ::/0 (native) или + <IPV6_SUBNET> (no-native)
#       split tunnel (режим 3): IPv4-список БЕЗ изменений + ТОЛЬКО <IPV6_SUBNET>,
#         НИКОГДА ::/0 - нет IPv6 split-list, нельзя угонять весь IPv6 (ломает split-tunnel).
# Если пустой (legacy-клиент): Address = <ipv4>/32, AllowedIPs без изменений.
render_client_config() {
    local name="$1"
    local client_ip="$2"
    local client_privkey="$3"
    local server_pubkey="$4"
    local endpoint="$5"
    local port="$6"
    local client_ipv6="${7:-}"
    # 8-й аргумент - DNS живого клиента от regenerate_client. Аргумент, а не переменная:
    # переменную можно унаследовать из окружения и обойти проверку CLIENT_DNS.
    local keep_dns="${8:-}"

    load_awg_params || return 1

    # DNS нового клиента: CLIENT_DNS или значение по умолчанию. Считаем ДО tmpfile,
    # чтобы невалидный CLIENT_DNS не оставил недописанного конфига. regenerate_client
    # с живым .conf передаёт DNS клиента 8-м аргументом: тогда CLIENT_DNS не нужен
    # и не проверяется, и опечатка в нём не блокирует regen чужих клиентов.
    local client_dns
    if [[ -n "$keep_dns" ]]; then
        client_dns="$keep_dns"
    else
        client_dns=$(awg_client_dns) || return 1
    fi

    local conf_file="$AWG_DIR/${name}.conf"
    # База маршрутов: индивидуальный override клиента (CLIENT_ALLOWED_IPS,
    # Issue #253) или глобальный режим сервера (ALLOWED_IPS из
    # awgsetup_cfg.init).
    local _aip_base="${CLIENT_ALLOWED_IPS:-${ALLOWED_IPS:-0.0.0.0/0}}"
    local allowed_ips
    if [[ -n "$client_ipv6" ]]; then
        # Dual-stack: зеркалю IPv4 routing intent в IPv6.
        # full tunnel (IPv4=0.0.0.0/0) -> ::/0 (native) или tunnel-ULA (no-native).
        # split tunnel -> IPv4-split AS-IS + ТОЛЬКО tunnel-ULA, никогда ::/0
        # (нет IPv6 split-list, нельзя угонять весь IPv6).
        # Override с явными IPv6-токенами не зеркалируется поверх самого себя:
        # пользователь расписал обе семьи явно - то же правило, по которому regen
        # не трогает IPv6-часть индивидуальных списков. Гейт ключуется на САМ
        # override, а не на слитую базу: awgsetup_cfg.init правят руками, и
        # глобальный список может нести IPv6-токены - такой список идёт
        # зеркалированием, как всегда (dedup ниже для этого и живёт), иначе
        # dual-stack клиент молча теряет маршрут до туннельной подсети.
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
            # Защитный de-dup: не дублирую ipv6_part, если он уже присутствует
            # токеном в списке (достижимо для глобального списка с IPv6-токенами
            # из hand-edited awgsetup_cfg.init).
            case ",${ipv4_part// /}," in
                *",${ipv6_part},"*) allowed_ips="$ipv4_part" ;;
                *)                  allowed_ips="${ipv4_part}, ${ipv6_part}" ;;
            esac
        fi
    else
        allowed_ips="$_aip_base"
        # iOS AmneziaVPN в режиме "весь трафик" требует обе семьи адресов: при
        # голом 0.0.0.0/0 он считает это незавершённой раздельной маршрутизацией
        # и не поднимает туннель. Для полного туннеля добавляем IPv6-маршрут:
        # ::/0 при 0.0.0.0/0 (режим 1), 2000::/3 с адресом стока у списка
        # режима 2 (см. _append_ipv6_full_tunnel_route). IPv6 уходит в туннель
        # (и отсекается, если у сервера нет нативного IPv6), наружу мимо VPN не
        # утекает. Полный туннель определяется покрытием маршрутов, поэтому сюда
        # попадают и режим 1, и режим 2; раздельная маршрутизация - нет.
        # Проверка результата подстановки обязательна: старый код был чистым
        # сравнением строк и отказать не мог, а подстановка команды при отказе
        # fork/exec вернёт пустую строку. Без проверки в конфиг ушло бы
        # 'AllowedIPs = ' при коде возврата 0, то есть громкий отказ стал бы
        # тихой выдачей нерабочего профиля.
        local _aip_new
        _aip_new=$(_append_ipv6_full_tunnel_route "$allowed_ips") && [[ -n "$_aip_new" ]] || {
            log_error "Не удалось вычислить AllowedIPs - клиентский конфиг не создан."
            return 1
        }
        allowed_ips="$_aip_new"
    fi

    # Индивидуальный список с явным IPv6 без ::/0 при полном туннеле: regen о
    # таком состоянии предупреждает (правило сохранения индивидуальных списков),
    # и создатель конфига не должен быть тише regen-а - иначе человек узнает о
    # своих маршрутах месяц спустя и от другой команды. Глобальный режим не
    # предупреждаем: установщик такие списки не пишет, а hand-edited вариант и
    # раньше проходил молча.
    if [[ -n "${CLIENT_ALLOWED_IPS:-}" ]] && _aip_full_tunnel_v6_gap "$allowed_ips"; then
        log_warn "Клиент '$name': индивидуальный AllowedIPs расписан по IPv6 без ::/0 - при полном туннеле IPv6 устройства идёт мимо туннеля. Нужно ::/0 - допишите его в --allowed-ips или выполните regen --reset-routes '$name'."
    fi

    # MTU: приоритет server awg0.conf > AWG_MTU из awgsetup_cfg.init > 1280 fallback.
    # Server config - источник правды для уже работающего сервера: пользователь
    # мог поправить MTU в /etc/amnezia/amneziawg/awg0.conf руками, и regen должен
    # это подхватить (Discussion #38). Невалидные значения (вне 576-9100)
    # на любом этапе откатываются к 1280.
    local mtu
    mtu=$(_extract_mtu_from_server_conf) || mtu=""
    if [[ -z "$mtu" ]]; then
        if _validate_mtu "${AWG_MTU:-}"; then
            mtu="$AWG_MTU"
        else
            mtu=1280
        fi
    fi

    # temp в каталоге клиентского конфига ($AWG_DIR) -> mv = атомарный rename.
    local tmpfile
    tmpfile=$(awg_mktemp "$AWG_DIR") || { log_error "Ошибка mktemp"; return 1; }

    local address_line
    if [[ -n "$client_ipv6" ]]; then
        address_line="${client_ip}/32, ${client_ipv6}/128"
    else
        address_line="${client_ip}/32"
        # Адрес стока для 2000::/3 (см. AWG_V6_SINK_PREFIX): без него Windows
        # маршрут не поставит и IPv6 пойдёт мимо туннеля.
        if _aip_wants_v6_sink "$allowed_ips"; then
            local _sink
            _sink=$(_awg_v6_sink_addr "$client_ip") || {
                rm -f "$tmpfile"
                log_error "Не удалось вычислить IPv6-адрес стока для '$name' ($client_ip) - клиентский конфиг не создан."
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

    # I1-I5: переносим заданные CPS-параметры в клиентский конфиг (issue #71).
    # Совпадать с серверными не обязаны - приёмник их не валидирует; regen
    # просто разносит по клиентам то, что задано на сервере.
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
    # PresharedKey — опциональный дополнительный слой поверх AWG 2.0
    # обфускации (включается через `manage add --psk`). Должен совпадать
    # в server peer и client [Peer].
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
        log_error "Ошибка записи конфига клиента '$name'"
        return 1
    fi
    chmod 600 "$conf_file"
    log_debug "Конфиг для '$name' создан: $conf_file"
    return 0
}

# ==============================================================================
# Операции, перезапускающие интерфейс: предупреждение и обратимость
# ==============================================================================

# awg_ssh_client_addr : адрес источника текущей SSH-сессии (пусто, если это не
# SSH или определить не удалось).
#
# ⚠️ Одного $SSH_CONNECTION НЕДОСТАТОЧНО: скрипт запускают через sudo, а sudo по
# умолчанию делает env_reset, и SSH_CONNECTION в env_keep Debian/Ubuntu не
# входит. Поэтому второй путь - who по нашему собственному tty.
# who может отдать имя хоста вместо адреса (при UseDNS yes); тогда сверка с
# подсетью не состоится, и вызывающий получит "определить не удалось" - это
# честнее, чем угадывать.
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
    # ⚠️ Приоритет у данных ПО НАШЕМУ tty, а не у унаследованной переменной.
    # SSH_CONNECTION приезжает из окружения и в переподключённой сессии
    # tmux/screen может указывать на ПРЕЖНЕЕ подключение - тогда мы выдали бы
    # уверенно неверный вердикт. utmp по своему tty описывает текущее.
    # Но если tty-путь дал не адрес (при UseDNS yes там будет имя хоста),
    # берём переменную: годный адрес полезнее честного «не знаю».
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

# _awg_tunnel_subnet : подсеть туннеля как addr/prefix, либо пустая строка.
#
# 🔴 ДЕФОЛТА ЗДЕСЬ НЕТ СОЗНАТЕЛЬНО, и это исправление критического дефекта.
# Прежняя редакция подставляла литерал 10.9.9.1/24, а manage на пути команды
# restart НЕ загружает awgsetup_cfg.init - значит AWG_TUNNEL_SUBNET там пуст.
# У любого, кто поставил сервер с --subnet, сессия из его подсети (например
# 10.66.66.2) сравнивалась с чужой 10.9.9.0/24 и объявлялась "не через туннель":
# скрипт уверенно утверждал ОБРАТНОЕ ИСТИНЕ ровно в том сценарии, ради которого
# проверка написана, и не показывал ни предупреждения, ни подсказки про консоль.
# Подставленный литерал превращает "данных нет" в "данные есть, и они такие".
#
# Источники по убыванию достоверности: живой интерфейс, конфиг сервера,
# переменная (её выставляет load_awg_params на других путях). Ничего не нашли -
# пусто, и вызывающий обязан сказать "не знаю", а не угадывать.
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

# awg_session_via_tunnel [адрес] : идёт ли текущая сессия ЧЕРЕЗ туннель VPN.
#   0 - да, адрес источника лежит в подсети туннеля (перезапуск оборвёт доступ);
#   1 - нет, адрес вне подсети;
#   2 - определить не удалось (не SSH, адрес не IPv4, подсеть НЕИЗВЕСТНА).
# Три состояния, а не два, сознательно: "не знаю" и "не через туннель" требуют
# РАЗНЫХ формулировок, а склеивание их в 1 выдавало бы догадку за факт.
# Адрес можно передать аргументом, чтобы вызывающий не спрашивал utmp дважды и
# не получил вердикт по одному адресу с текстом про другой.
awg_session_via_tunnel() {
    local addr="${1:-}" subnet net_int bcast_int addr_int
    [[ -n "$addr" ]] || addr="$(awg_ssh_client_addr)"
    [[ -n "$addr" ]] || return 2
    [[ "$addr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 2
    subnet="$(_awg_tunnel_subnet)"
    [[ -n "$subnet" ]] || return 2
    # 🔴 Префикс /31 и /32 не несёт диапазона хостов, поэтому по нему нельзя
    # ответить на наш вопрос: любой адрес кроме серверного окажется "вне
    # подсети", и мы уверенно сказали бы "доступ не пострадает" человеку,
    # сидящему в туннеле. Наш генератор пишет /16../30, но путь через живой
    # интерфейс наследует ЛЮБОЙ префикс, а /32 в [Interface] - обычная
    # практика WireGuard. Отвечаем "не знаю" (проверено на стенде).
    [[ "${subnet##*/}" =~ ^[0-9]+$ ]] || return 2
    (( 10#${subnet##*/} <= 30 )) || return 2
    read -r net_int bcast_int < <(_cidr_bounds "$subnet" 2>/dev/null) || return 2
    [[ -n "$net_int" && -n "$bcast_int" ]] || return 2
    addr_int="$(_ipv4_to_int "$addr" 2>/dev/null)" || return 2
    [[ -n "$addr_int" ]] || return 2
    (( addr_int >= net_int && addr_int <= bcast_int )) && return 0
    return 1
}

# awg_warn_interface_disruption : предупредить ДО операции, перезапускающей
# интерфейс. Вызывать раньше confirm_action, чтобы предупреждение было видно и
# при --yes (неинтерактивные запуски тоже отрезают людей от сервера).
awg_warn_interface_disruption() {
    local rc addr subnet
    log_warn "Интерфейс awg0 будет перезапущен - соединения всех клиентов прервутся на несколько секунд."
    # Адрес спрашиваем ОДИН раз и передаём в проверку: два независимых вызова
    # могли дать вердикт по одному адресу и текст про другой (или пустой).
    addr="$(awg_ssh_client_addr)"
    # Подсеть тоже резолвим ОДИН раз и ДО вердикта: прежняя редакция
    # спрашивала её второй раз уже после, и напечатанная подсеть могла
    # оказаться не той, по которой вердикт вынесен.
    subnet="$(_awg_tunnel_subnet)"
    # rc берём формой `|| rc=$?`, а НЕ `cmd; rc=$?`: под set -e вторая форма
    # прерывает функцию на ненулевом коде, то есть предупреждение оборвалось
    # бы на середине. В репозитории есть встроенный скрипт с set -euo
    # pipefail, поэтому это не гипотетический случай.
    rc=0
    awg_session_via_tunnel "$addr" || rc=$?
    case "$rc" in
        0)
            log_warn "ВНИМАНИЕ: похоже, вы подключены к серверу ЧЕРЕЗ этот же VPN."
            log_warn "  Адрес вашей сессии $addr входит в подсеть туннеля ${subnet},"
            log_warn "  значит после перезапуска текущее подключение оборвётся."
            log_warn "  Если доступ не вернётся сам - заходите через консоль или VNC в панели"
            log_warn "  вашего провайдера: она работает в обход VPN."
            ;;
        1)
            log_debug "Сессия идёт не через туннель (адрес $addr) - доступ к серверу не пострадает."
            ;;
        *)
            log_warn "  Если вы подключены к серверу ЧЕРЕЗ этот VPN, вы потеряете доступ."
            log_warn "  Запасной путь на такой случай - консоль или VNC в панели провайдера."
            ;;
    esac
}

# awg_cps_decoded_size <строка I> [...] : суммарный ДЕКОДИРОВАННЫЙ размер в байтах.
#
# Зачем. Параметры I1-I5 попадают в атрибуты устройства, которые ядро отдаёт
# одним netlink-сообщением дампа. Когда атрибуты устройства занимают почти весь
# буфер, первый пир в него уже не помещается, и `wg_get_device_dump` не
# продвигается и не падает: он возвращает ненулевую длину, netlink спрашивает
# снова, и то же сообщение выдаётся бесконечно. Читатель крутится и растёт в
# памяти; на роутере этого достаточно, чтобы уронить устройство. Разбор с кодом:
# amneziawg-linux-kernel-module#228 (31 aug 2026), симптом у пользователя - #148.
# Полоса чуть выше зацикливания отвечает `Unable to access interface: Message
# too long`, и это ЛУЧШЕ: ошибка хотя бы останавливает. Формулировка ровно
# такая: errno EMSGSIZE, glibc печатает «too long», и грепать свой лог надо по
# этим словам.
#
# 🔴 Считается ДЕКОДИРОВАННЫЙ размер, а не длина строки. `<r 1000>` - восемь
# символов и тысяча байт на проводе; сравнение по длине строки не заметило бы
# ровно того случая, ради которого проверка написана.
#
# Набор тегов - пересечение двух реализаций, оно же документированный вендором
# набор: `<b 0xHEX>` литеральные байты, `<r N>` случайные байты, `<rc N>`
# случайные буквы, `<rd N>` случайные цифры, `<t>` метка времени (4 байта).
# `<c>` считаем теми же 4 байтами: он есть в модуле ядра и отсутствует в
# amneziawg-go, то есть влияет на переносимость, но не на размер.
# Неизвестное не додумывается: выдуманное число хуже честного отказа. Но и
# молчать о нём нельзя, поэтому всё неразобранное - неизвестный тег, оборванная
# скобка, мусор между тегами, неправдоподобно большое число - метит результат
# кодом возврата 2 «сумма занижена». Ноль с кодом 0 обязан означать «разобрал
# всё, размера нет», иначе вызывающий примет мусор за пустоту.
awg_cps_decoded_size() {
    local total=0 s tag n hex mat pre unknown=0
    for s in "$@"; do
        [[ -n "$s" ]] || continue
        # Форму без пробела принимаем НАРОЧНО, хотя обе реализации её
        # отвергают: ядро режет тег по пробелу (`strsep`), amneziawg-go - через
        # `strings.Fields`, поэтому `<r64>` для них неизвестный ключ и
        # интерфейс не поднимется. Считать её всё равно правильно: мы оцениваем
        # размер, и завышенная оценка приводит к предупреждению, а пропуск - к
        # зависанию. ⚠️ В конфиг такую форму писать нельзя.
        while [[ "$s" =~ \<[[:space:]]*([a-zA-Z]+)[[:space:]]*([^\>]*)\> ]]; do
            # 🔴 Совпадение сохраняем ДО case: внутри ветки `b` стоит свой
            # `[[ =~ ]]`, и он затирает BASH_REMATCH. Пока продвижение по
            # строке шло по первому `>`, это ничего не ломало; теперь строка
            # режется по совпадению, и взятое после case было бы hex-ом.
            mat="${BASH_REMATCH[0]}"
            tag="${BASH_REMATCH[1]}"
            n="${BASH_REMATCH[2]}"
            n="${n//[[:space:]]/}"
            # Всё, что стоит ПЕРЕД тегом, тегом не является. Без этой строки
            # `<><r 5>` проходил как честные пять байт.
            pre="${s%%"$mat"*}"
            [[ -z "${pre//[[:space:]]/}" ]] || unknown=1
            case "${tag,,}" in
                b)
                    hex="${n#0x}"; hex="${hex#0X}"
                    # Два hex-символа - один байт. Нечётный хвост не считаем:
                    # такой тег реализации отвергают, додумывать за них нечего.
                    if [[ "$hex" =~ ^[0-9a-fA-F]+$ && $(( ${#hex} % 2 )) -eq 0 ]]; then
                        total=$(( total + ${#hex} / 2 ))
                    else
                        unknown=1
                    fi
                    ;;
                r|rc|rd)
                    # 🔴 `10#` обязателен. Без него bash читает число с ведущим
                    # нулём как восьмеричное, `<r 08>` роняет арифметику, вся
                    # функция возвращает ПУСТОТУ, и проверка на превышение
                    # порога молча не срабатывает - тихий отказ ровно там, где
                    # он опаснее всего. Замерено 31 aug 2026.
                    # Длина ограничена девятью цифрами не из вкуса:
                    # `<r 18446744073709551617>` переполняет 64-битную
                    # арифметику bash и даёт в сумме ЕДИНИЦУ, то есть заведомо
                    # опасное значение проскакивает под порогом. Замерено
                    # 1 sep 2026. Вендор ограничивает r/rc/rd тысячей, так что
                    # девять цифр - запас, а не рамка.
                    if [[ "$n" =~ ^[0-9]{1,9}$ ]]; then
                        total=$(( total + 10#$n ))
                    else
                        unknown=1
                    fi
                    ;;
                t|c)
                    # 🔴 У `<t>` и `<c>` полезной нагрузки нет, поэтому непустое
                    # содержимое означает, что мы разобрали НЕ ТО. `<t <r 4096>`
                    # ловится этой регуляркой как один тег со значением
                    # `<r 4096`, и без проверки давал четыре байта с кодом
                    # успеха: четыре тысячи байт превращались в четыре, а
                    # диагностика шла в опасный вызов с чистой совестью.
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
            # 🔴 Продвигаемся за КОНЕЦ СОВПАДЕНИЯ. Форма `${s#*>}` резала до
            # первого `>` в строке, а он мог стоять ДО совпадения - тогда тот
            # же тег считался второй раз.
            s="${s#*"$mat"}"
        done
        # Непустой остаток тегом не является. Без этого `garbage` и оборванный
        # `<r 5` возвращали ноль с кодом 0, то есть «разобрал, размера нет».
        [[ -z "${s//[[:space:]]/}" ]] || unknown=1
    done
    printf '%s' "$total"
    # Код 2 значит «сумма занижена, встретилось неразобранное». Вызывающий
    # обязан сказать об этом вслух: занижение здесь неотличимо от измеренного
    # маленького размера, а это и есть ложное «проверил и сошлось».
    [[ "$unknown" -eq 0 ]] || return 2
    return 0
}

# Есть ли у CPS-строки СТРУКТУРА, а не просто случайные байты.
#
# 🔴 Отвечает на вопрос диагностики «ругаться ли на это значение», и граница
# здесь важнее удобства. Замер 10 sep 2026 на живом российском операторе: пакет
# из случайных байт рукопожатие не собирает, пакет формы DNS-ответа того же
# размера собирает. Значит «структурный» должно означать именно структуру, а не
# наличие где-то в строке одного литерального тега: `<r 200><b 0xaa>` - это
# двести байт случайности с однобайтовым хвостом, и первая редакция проверки
# такое благословляла. Три условия, каждое своё:
#   1. строка разбирается нашим счётчиком целиком (обрывки и нечётный hex прочь);
#   2. теги только из пересечения реализаций - `<c>` и `<d>` ломают переносимость;
#   3. ни один случайный кусок не длиннее метки DNS (63 байта), а литеральных
#      байт не меньше тридцати. Наш генератор даёт метку до 62 и от 48 байт
#      литералов, документированные рецепты QUIC - почти сплошные литералы.
#
# Возвращает 0, если структура есть.
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

# awg_cps_check_safe <строка I> : безопасна ли строка CPS для ОБЕИХ реализаций.
# 0 - безопасна; 1 - нет, и тогда в stdout причина.
#
# Зачем. Модуль ядра разбирает длину `<r>`/`<rc>`/`<rd>` через kstrtoint и на
# само значение не смотрит: размеры тегов складываются в int и идут в выделение
# памяти, а длина каждого тега - в копирование. Отрицательная длина рядом с
# `<b>` оставляет сумму маленькой и положительной, буфер выходит маленьким, а
# копирование литерала нет (апстрим amneziawg-linux-kernel-module#233 и #187);
# одиночная отрицательная длина даёт отрицательную сумму, и тогда ядро отказывает
# само. amneziawg-go берёт ту же длину через strconv.Atoi и падает на срезе при
# сборке пакета. Такой конфиг принимается без ошибки, а regen раздал бы его всем
# клиентам.
#
# 🔴 Отказ узкий НАМЕРЕННО: только то, что опасно по коду обеих реализаций.
# Длина обязана быть неотрицательным десятичным числом не длиннее девяти
# значащих цифр (знак, ведущие нули и `-0` обе реализации понимают, рабочий
# конфиг с ними ломать нельзя); сумма - не больше 65535, больше в UDP заведомо
# не влезает. Девять цифр - предел НАШЕЙ арифметики, а не свойство реализаций:
# bash молча сворачивает 2^64+1 в 1. Неизвестный тег и мусор НЕ трогаем:
# реализации отвергают их громко сами, а наш отказ мог бы сломать
# userspace-сервер, который работает сегодня.
#
# 🔴 Значение читается ТАК, КАК ЕГО ПРИМЕНЯЮТ, иначе любая разница - обход:
#   - amneziawg-tools режут строку по `#`, поэтому комментарий отбрасываем;
#   - ядро делит теги через strsep, а strsep без `>` отдаёт остаток строки,
#     поэтому незакрытый ПОСЛЕДНИЙ тег разбирается как закрытый;
#   - имя тега обе реализации сравнивают с учётом регистра (strcmp и map),
#     поэтому `<R -1>` для них неизвестный тег, и мы его не трогаем.
# Форма без пробела (`<r-1>`) разбирается как в awg_cps_decoded_size; отказ на
# ней безвреден, обе реализации такую форму отвергают сами.
# Сумму считаем здесь, а не через awg_cps_decoded_size: тот ведущий плюс не
# принимает, и `<r +999999999>` трижды прошёл бы мимо проверки переполнения.
awg_cps_check_safe() {
    local s="${1:-}" rest mat tag n digits hex total=0
    s="${s%%#*}"
    [[ -n "${s//[[:space:]]/}" ]] || return 0
    rest="$s"
    while [[ "$rest" =~ \<[[:space:]]*([a-zA-Z]+)[[:space:]]*([^\>]*)(\>|$) ]]; do
        # 🔴 Совпадение сохраняем и строку продвигаем ДО любых других [[ =~ ]]:
        # они затирают BASH_REMATCH, и продвижение по затёртому совпадению не
        # укорачивало бы строку. На `<b 0xGG>` или `<r 1 2>` цикл тогда не
        # завершается, а в restore это случилось бы после замены файлов, до
        # отката.
        mat="${BASH_REMATCH[0]}"
        tag="${BASH_REMATCH[1]}"
        n="${BASH_REMATCH[2]//[[:space:]]/}"
        rest="${rest#*"$mat"}"
        case "$tag" in
            r|rc|rd)
                # Знак снимаем один раз, ведущие нули - до лимита цифр: `-0`,
                # `+0` и `0000000001` обе реализации читают как обычные числа,
                # и отказ на них ломал бы рабочий конфиг.
                digits="${n#[-+]}"
                if ! [[ "$digits" =~ ^[0-9]+$ ]]; then
                    printf 'длина в теге <%s %s> не десятичное число' "$tag" "$n"
                    return 1
                fi
                while [[ "$digits" == 0?* ]]; do digits="${digits#0}"; done
                # Текст про нарушение памяти - только для настоящего
                # отрицательного числа, а не для минуса перед нулём или мусором.
                if [[ "$n" == -* && "$digits" != "0" ]]; then
                    printf 'отрицательная длина в теге <%s %s>: amneziawg-go падает на ней при сборке пакета, а модуль ядра рядом с <b> пишет за границу буфера' "$tag" "$n"
                    return 1
                fi
                if ! [[ "$digits" =~ ^[0-9]{1,9}$ ]]; then
                    printf 'длина в теге <%s %s> длиннее девяти значащих цифр: заведомо больше 65535 байт, а в арифметике проверки такое число переполнилось бы' "$tag" "$n"
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
        printf 'суммарный размер %s байт больше 65535: такой пакет заведомо не помещается в UDP, а огромные длины переполняют сумму размеров в модуле ядра' "$total"
        return 1
    fi
    return 0
}

# awg_cpa_check_safe <значение> : ContentPaddingAddition в форме, которую
# amneziawg-tools разберут без молчаливого искажения.
# Tools читают значение через u16_range_from_string и сворачивают число по
# модулю 65536: 65536 становится 0, то есть профилем без добавочного паддинга
# при полностью зелёной установке (замер 10 sep 2026). Поэтому потолок 65535
# проверяем сами, до инструмента. Число длиннее 10 значащих цифр отвергаем ДО
# арифметики оболочки: иначе огромное значение перевалит через 2^63 и сравнение
# соврёт; ведущие нули в длину не входят (_awg_dec_strip). Перевёрнутый
# диапазон tools отвергают громко и сами, здесь он
# отвергается раньше, до запуска сервиса.
# Возврат: 0 - безопасно; 1 - нет, причина в stdout.
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
        printf 'значение "%s" не число и не диапазон MIN-MAX' "$v"
        return 1
    fi
    lo=$(_awg_dec_strip "$lo")
    hi=$(_awg_dec_strip "$hi")
    if (( ${#lo} > 10 || ${#hi} > 10 )) || (( lo > 4294967295 || hi > 4294967295 )); then
        printf 'значение "%s" больше 4294967295: amneziawg-tools его не примут' "$v"
        return 1
    fi
    if (( lo > 65535 || hi > 65535 )); then
        printf 'значение "%s" больше 65535: amneziawg-tools молча свернут его по модулю 65536' "$v"
        return 1
    fi
    if (( lo > hi )); then
        printf 'в диапазоне "%s" нижняя граница больше верхней' "$v"
        return 1
    fi
    return 0
}

# _awg_dec_strip <цифры> : то же число без ведущих нулей ("0", если нули одни).
# Длину числа для проверки переполнения считаем по значащим цифрам: tools читают
# 00000000001 как 1, и отказ по длине записи был бы ложным. Результат без ведущих
# нулей безопасен и для арифметики оболочки, которая иначе читала бы 010 как 8.
_awg_dec_strip() {
    local d="${1#"${1%%[!0]*}"}"
    printf '%s' "${d:-0}"
}

# _awg_conf_pairs <файл> : строки "секция<TAB>ключ<TAB>значение" конфига в том
# виде, в каком их читают amneziawg-tools: заголовок секции и ключ без учёта
# регистра (ключ печатается в нижнем регистре), комментарий после # и все
# пробельные символы отброшены, CR снят. Секция - interface, other или none (строка
# до первого заголовка; tools на ней отказывают, а нам важно не пропустить её
# молча). Совпадает с tools для однотокенных ключей; пробелы внутри I1-I5 не
# сохраняются, поэтому для I1-I5 эта функция не годится. Порядок сохранён, дубли
# НЕ схлопываются.
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

# awg_cps_refuse_unsafe : проверить AWG_I1..AWG_I5 текущего окружения.
# 0 - все безопасны; 1 - нет, причины уже записаны в журнал.
# Общий текст отказа для load_awg_params и render_server_config; валидатор
# проверяет строки файла сам и пишет свой. Файл для правки называется по
# фактическому источнику, который записывает load_awg_params: на первой
# установке awg0.conf ещё нет, и значения приходят из init-файла.
awg_cps_refuse_unsafe() {
    local v why bad=0
    for v in AWG_I1 AWG_I2 AWG_I3 AWG_I4 AWG_I5; do
        [[ -n "${!v:-}" ]] || continue
        if ! why=$(awg_cps_check_safe "${!v}"); then
            log_error "Параметр ${v#AWG_} небезопасен: ${why}."
            bad=1
        fi
    done
    if [[ $bad -eq 1 ]]; then
        log_error "Профили и серверный конфиг с таким значением не выпускаю (апстрим amneziawg-linux-kernel-module#233). Исправьте I1-I5 в ${_AWG_PARAMS_SOURCE:-$SERVER_CONF_FILE}."
        return 1
    fi
    return 0
}


# _awg_device_param_names : имена device-параметров AWG (2.0, 3.0 и 3.1), которые
# живут в секции [Interface] и которые syncconf НЕ снимает.
_awg_device_param_names() {
    printf '%s\n' Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4 I1 I2 I3 I4 I5 \
        ContentPaddingAddition HeaderProtectionKey MaxHandshakeAttempts \
        KeepaliveTimeout RejectAfterTime RekeyAfterTime RekeyTimeout \
        RandomTrailers DisableCookies
}

# _awg_device_params_fingerprint [конфиг] : отсортированный список ИМЁН
# device-параметров, присутствующих в секции [Interface]. Одной строкой.
# Только имена: значения syncconf применяет корректно, проблема ровно в снятии.
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

# _awg_save_device_params <файл состояния> <отпечаток> : запомнить применённый
# набор. Файл в AWG_DIR (root-only), потеря = мягкая деградация: следующая
# проверка просто не сработает, лишнего перезапуска не будет.
# Запись АТОМАРНАЯ (temp + mv): оборванная запись оставила бы полупустой
# снимок, а он читается как «параметры убрали» и порождает ложное
# предупреждение. Отказ не глушим совсем - пишем в debug, иначе тихая потеря
# состояния выглядела бы как успех.
# Имя temp-файла ФИКСИРОВАННОЕ, а не с $$: если процесс убьют между записью и
# mv, следующий запуск перезапишет тот же файл, а не оставит россыпь сирот.
# Гонки нет - весь участок держит flock apply_config.
# ⚠️ Отказ записи идёт в log_warn, а НЕ в log_debug. log_debug печатает только
# при --verbose и в лог-файл при этом не попадает вовсе, то есть прежняя
# редакция обещала «не глушим совсем», а по факту глушила полностью. Причины
# отказа под root (ENOSPC, remount read-only, пропавший AWG_DIR) не мягкие: в
# этот момент под угрозой и awg0.conf, и бэкапы, и лог. return 0 оставлен -
# применение конфигурации не должно падать из-за диагностического снимка.
_awg_save_device_params() {
    local state="$1" fp="$2" tmp="${1}.tmp"
    if ! printf '%s\n' "$fp" > "$tmp" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        log_warn "Не удалось записать снимок параметров интерфейса ($state) - проверьте место на диске и права."
        return 0
    fi
    chmod 600 "$tmp" 2>/dev/null || true
    if ! mv -f "$tmp" "$state" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        log_warn "Не удалось заменить снимок параметров интерфейса ($state) - проверьте место на диске и права."
    fi
    return 0
}

# awg_record_device_params : запомнить, какой набор device-параметров стоит в
# конфиге СЕЙЧАС. Вызывать ПОСЛЕ успешного применения или пересоздания
# интерфейса - снимок обязан означать «то, что реально стоит на живом
# интерфейсе», иначе обнаружение снятия начинает врать в обе стороны.
#
# 🔴 Два правила, каждое из которых закрывает найденный ревью дефект:
# 1. Отпечаток считается ЗАНОВО, а не берётся посчитанный до применения: если в
#    тот момент файл перезаписывался, посчитанное было неполным, и сохранение
#    его закрепило бы неверный набор.
# 2. ПУСТОЙ набор не пишем НИКОГДА. Пустой снимок отключает проверку навсегда
#    (сравнивать не с чем), а пустота почти всегда означает недочитанный файл:
#    наш генератор всегда пишет Jc/S/H. Лучше сохранить прежний хороший снимок.
awg_record_device_params() {
    local state="${AWG_DIR}/.awg_device_params" fp
    [[ -r "$SERVER_CONF_FILE" ]] || return 0
    fp="$(_awg_device_params_fingerprint "$SERVER_CONF_FILE" 2>/dev/null)" || return 0
    [[ -n "$fp" ]] || return 0
    _awg_save_device_params "$state" "$fp"
}

# ==============================================================================
# Применение конфигурации (syncconf)
# ==============================================================================

# Применение изменений конфигурации
# AWG_SKIP_APPLY=1: пропустить apply (для batch-автоматизации)
# AWG_APPLY_MODE=syncconf|restart: режим применения (конфиг или --apply-mode CLI)
# flock на .awg_apply.lock: защита от параллельных вызовов
apply_config() {
    case $- in *x*) _awg_xtrace_guard apply_config; return ;; esac
    # Пропуск apply (AWG_SKIP_APPLY=1 manage add/remove ...)
    if [[ "${AWG_SKIP_APPLY:-0}" == "1" ]]; then
        log_debug "apply_config пропущен (AWG_SKIP_APPLY=1)."
        return 0
    fi

    # Межпроцессная блокировка apply_config
    local apply_lockfile="${AWG_DIR}/.awg_apply.lock"
    local apply_fd
    exec {apply_fd}>"$apply_lockfile"
    if ! flock -x -w 120 "$apply_fd"; then
        log_warn "Не удалось получить блокировку apply_config."
        exec {apply_fd}>&-
        return 1
    fi

    local rc=0

    # 🔴 syncconf НЕ СНИМАЕТ device-параметры AWG. Проверено на модуле
    # 3.0.20260731-04: поставленные Jc/S4/H1/I1/ContentPaddingAddition/
    # RekeyAfterTime остались на живом интерфейсе после применения конфига, где
    # их нет. Семантика WireGuard («setconf = полная картина») для AWG-параметров
    # не действует, она аддитивна. Значит операция «убрать параметр из awg0.conf
    # и применить» тихо не сработала бы: файл изменился, интерфейс нет, и такое
    # расхождение ничем не ловится. Снять параметр можно только пересозданием
    # интерфейса, то есть перезапуском сервиса.
    #
    # Сравниваем НАБОР ИМЁН параметров с тем, что применяли в прошлый раз, а не
    # с живым интерфейсом: `awg showconf` печатает и нейтральные значения
    # (S4 = 0, H1 = 1), поэтому сверка с ним давала бы ложные срабатывания на
    # каждом применении. Значения не сравниваем вовсе - их syncconf применяет
    # корректно, проблема ровно в снятии.
    # Состояния нет (первая установка, потерянный файл) - молчим: сравнивать не
    # с чем, а предупреждать наугад хуже, чем не предупреждать.
    local params_state="${AWG_DIR}/.awg_device_params"
    local now_fp="" prev_fp="" removed=""
    if [[ -r "$SERVER_CONF_FILE" ]]; then
        # Путь передаём явно, хотя он же и по умолчанию: иначе shellcheck 0.9
        # (та версия, что стоит в CI) справедливо ругается SC2120 на параметр,
        # который никто никогда не передаёт.
        now_fp="$(_awg_device_params_fingerprint "$SERVER_CONF_FILE" 2>/dev/null)" || now_fp=""
        [[ -r "$params_state" ]] && IFS= read -r prev_fp 2>/dev/null < "$params_state"
        # ⚠️ Пустой набор при непустом прежнем НЕ считаем удалением всего.
        # Наш генератор всегда пишет Jc/S/H, поэтому пустота означает скорее
        # недочитанный или переписываемый в этот момент файл, чем реальную
        # чистку. Молчим: ложная тревога тут дороже пропущенной.
        if [[ -n "$prev_fp" && -n "$now_fp" ]]; then
            local _p
            for _p in $prev_fp; do
                [[ " $now_fp " == *" $_p "* ]] || removed+="${removed:+, }$_p"
            done
        fi
    fi

    # Режим не задан ни опцией, ни окружением (remove и cron init не загружают) -
    # берём сохранённый в init тем же разборщиком, что и load_awg_params. Разбор
    # в подоболочке: остальные ключи init сюда не попадают.
    local AWG_APPLY_MODE="${AWG_APPLY_MODE:-}"
    if [[ -z "$AWG_APPLY_MODE" && -f "$CONFIG_FILE" ]]; then
        AWG_APPLY_MODE=$(safe_load_config "$CONFIG_FILE" >/dev/null 2>&1; printf '%s' "${AWG_APPLY_MODE:-}")
    fi
    if [[ "${AWG_APPLY_MODE:-syncconf}" == "restart" ]]; then
        # Явный restart-режим рвёт соединения клиентов, в том числе SSH через
        # туннель, поэтому предупреждаем так же, как при manage restart.
        awg_warn_interface_disruption
        log "Перезапуск сервиса (apply-mode=restart)..."
        systemctl restart awg-quick@awg0 2>/dev/null; rc=$?
        if [[ $rc -ne 0 ]]; then
            log_warn "Ошибка перезапуска."
        else
            awg_record_device_params
        fi
        exec {apply_fd}>&-
        return $rc
    fi

    # 🔴 Обнаруженное снятие параметра НЕ перезапускаем сами - предупреждаем.
    # Первая редакция этой правки перезапускала сервис автоматически, и это было
    # ХУЖЕ той ловушки, которую закрывало: перезапуск рвёт соединения ВСЕХ
    # клиентов, а состояние может отстать без всякой вины пользователя. Пример:
    # человек убрал строку и применил её через `manage restart` - интерфейс уже
    # пересоздан, параметр уже снят, но снимок набора остался прежним, и
    # следующий обычный `add` увидел бы "удаление" второй раз и оборвал всех
    # заново. Цена ложного предупреждения - строка в журнале; цена ложного
    # перезапуска - обрыв у всех. Поэтому говорим, а решает человек.
    # ⚠️ Снимок здесь НЕ обновляем. Он обновляется только ПОСЛЕ успешного
    # применения, ниже. Прежняя редакция обновляла его сразу, и это гасило
    # предупреждение навсегда, если применение потом падало: состояние уже
    # «догнало» файл, а на живом интерфейсе не изменилось ничего.
    if [[ -n "$removed" ]]; then
        log_warn "Из секции [Interface] убрано: ${removed}."
        log_warn "  syncconf такие параметры НЕ снимает - на живом интерфейсе они останутся."
        log_warn "  Чтобы снятие вступило в силу, интерфейс надо пересоздать:"
        log_warn "    systemctl restart awg-quick@awg0"
        log_warn "  Это оборвёт соединения всех клиентов на несколько секунд, поэтому"
        log_warn "  сами мы этого не делаем. Если вы уже перезапускали сервис вручную,"
        log_warn "  предупреждение можно игнорировать: после успешного применения снимок"
        log_warn "  обновится, и на следующих запусках этой строки не будет."
    fi

    local strip_out
    strip_out=$(timeout 10 awg-quick strip awg0 2>/dev/null) || {
        log_warn "awg-quick strip не удался или timeout, использую полный перезапуск."
        # Этот перезапуск НЕ ожидаем: человек запускал рутинный add/remove.
        # Он рвёт всех клиентов, поэтому предупреждаем и здесь, а не только в
        # явном restart-режиме.
        awg_warn_interface_disruption
        systemctl restart awg-quick@awg0 2>/dev/null; rc=$?
        if [[ $rc -ne 0 ]]; then
            log_warn "Ошибка перезапуска."
        else
            awg_record_device_params
        fi
        exec {apply_fd}>&-
        return $rc
    }
    echo "$strip_out" | timeout 10 awg syncconf awg0 /dev/stdin 2>/dev/null || {
        log_warn "awg syncconf не удался или timeout, использую полный перезапуск."
        # Как и выше: незапланированный перезапуск оборвёт всех, включая
        # SSH-сессию через туннель, - об этом надо сказать до, а не после.
        awg_warn_interface_disruption
        systemctl restart awg-quick@awg0 2>/dev/null; rc=$?
        if [[ $rc -ne 0 ]]; then
            log_warn "Ошибка перезапуска."
        else
            awg_record_device_params
        fi
        exec {apply_fd}>&-
        return $rc
    }
    log_debug "Конфигурация применена (syncconf)."
    awg_record_device_params
    exec {apply_fd}>&-
    return 0
}

# ==============================================================================
# Управление пирами
# ==============================================================================

# Получить следующий свободный IP в подсети (произвольная маска /16-/30).
# Сервер = network+1; диапазон хостов [network+1 .. broadcast-1]. Возвращает
# наименьший свободный (ранний выход) - для /16 это до 65534 позиций, но без
# полного скана в типичном случае.
get_next_client_ip() {
    local subnet="${AWG_TUNNEL_SUBNET:-10.9.9.1/24}"
    local net_int bcast_int
    read -r net_int bcast_int < <(_cidr_bounds "$subnet") || {
        log_error "get_next_client_ip: не удалось разобрать подсеть '$subnet'"
        return 1
    }
    local server_int=$(( net_int + 1 ))

    # Ассоциативный массив для O(1) lookup. Сервер (network+1) занят.
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

    log_error "Нет свободных IP в подсети ${subnet}"
    return 1
}

# Получить IPv6-адрес клиента из его IPv4. Используется только при
# ALLOW_IPV6_TUNNEL=1. Индекс = смещение хоста в подсети (offset = ipv4 - network),
# что даёт уникальность при любой маске. Кодирование суффикса зависит от маски:
#   prefix == 24 -> десятичный offset (== последний октет; байт-в-байт как ранее),
#   иначе        -> корректный hex (printf '%x').
# Сервер (network+1, offset 1) даёт "1" в обоих режимах -> ::1 (см.
# _derive_ipv6_server_addr, не меняется). Клиенты имеют offset >= 2.
# Возвращает строку без префикса длины.
#
# get_next_client_ipv6 <ipv4_addr>
get_next_client_ipv6() {
    local ipv4="$1"
    if [[ -z "$ipv4" ]]; then
        log_error "get_next_client_ipv6: не передан IPv4-адрес"
        return 1
    fi
    local tunnel="${AWG_TUNNEL_SUBNET:-10.9.9.1/24}"
    local tprefix="${tunnel##*/}"
    local net_int bcast_int ip_int offset suffix
    read -r net_int bcast_int < <(_cidr_bounds "$tunnel") || {
        log_error "get_next_client_ipv6: не удалось разобрать подсеть '$tunnel'"
        return 1
    }
    ip_int=$(_ipv4_to_int "$ipv4") || {
        log_error "get_next_client_ipv6: некорректный IPv4 '$ipv4'"
        return 1
    }
    offset=$(( ip_int - net_int ))
    (( offset >= 1 && offset < bcast_int - net_int )) || { log_error "get_next_client_ipv6: IPv4 '$ipv4' вне подсети '$tunnel'"; return 1; }
    if [[ "$tprefix" == "24" ]]; then
        suffix="$offset"
    else
        suffix=$(printf '%x' "$offset")
    fi
    local subnet="${IPV6_SUBNET:-fddd:2c4:2c4:2c4::/64}"
    local prefix="${subnet%%::*}"
    [[ "$prefix" == *:* ]] || { log_error "get_next_client_ipv6: IPV6_SUBNET не содержит :: (значение: $subnet)"; return 1; }
    echo "${prefix}::${suffix}"
    return 0
}

# Добавление [Peer] в серверный конфиг (атомарно через tmpfile + mv).
#
# КОНТРАКТ БЛОКИРОВКИ: вызывающий код ОБЯЗАН держать exclusive flock на
# ${AWG_DIR}/.awg_config.lock когда вызывает эту функцию. Эту блокировку
# берёт generate_client() — единственный текущий caller. Не вызывать
# add_peer_to_server напрямую без удержания lock'а.
#
# Почему inner flock здесь невозможен: bash flock не re-entrant между
# разными file descriptors на тот же файл. generate_client() открывает
# .awg_config.lock на свой fd и держит exclusive lock, а попытка
# открыть тот же файл на новый fd внутри add_peer_to_server и взять
# на нём exclusive lock приводит к самоблокировке (родительский lock
# виден как чужой). Контракт-based locking — единственный надёжный
# вариант для bash в этой ситуации. Re-entrant поведение возможно
# только если sub-функция использует TOТ ЖЕ fd что родитель (через
# inheritance), но это требует передачи fd как аргумента.
#
# add_peer_to_server <name> <pubkey> <client_ip> [client_ipv6]
#
# client_ipv6 (необязательный, 4-й аргумент): IPv6-адрес без префикса длины.
# Если непустой: AllowedIPs = <ipv4>/32, <ipv6>/128
# Если пустой (legacy): AllowedIPs = <ipv4>/32
add_peer_to_server() {
    case $- in *x*) _awg_xtrace_guard add_peer_to_server "$@"; return ;; esac
    local name="$1"
    local pubkey="$2"
    local client_ip="$3"
    local client_ipv6="${4:-}"

    if [[ -z "$name" || -z "$pubkey" || -z "$client_ip" ]]; then
        log_error "add_peer_to_server: недостаточно аргументов"
        return 1
    fi
    # Имя уходит в heredoc конфига (#_Name = ...): перевод строки в имени
    # дал бы инъекцию секции [Peer]. Defense-in-depth, см. generate_client.
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "add_peer_to_server: невалидное имя клиента '$name'"
        return 1
    fi

    if grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE" 2>/dev/null; then
        log_error "Пир '$name' уже существует в конфиге"
        return 1
    fi

    # Добавляем пир через временный файл (атомарно).
    # temp в каталоге серверного конфига -> mv = атомарный rename на той же ФС.
    local tmpfile
    tmpfile=$(awg_mktemp "$(dirname "$SERVER_CONF_FILE")") || { log_error "Ошибка mktemp"; return 1; }

    cp "$SERVER_CONF_FILE" "$tmpfile" || {
        rm -f "$tmpfile"
        log_error "Ошибка копирования серверного конфига"
        return 1
    }

    cat >> "$tmpfile" << EOF

[Peer]
#_Name = ${name}
PublicKey = ${pubkey}
EOF
    # PresharedKey — опционально, пишется если передан через CLIENT_PSK env.
    # Должен совпадать у server peer и client [Peer].
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
        log_error "Ошибка обновления серверного конфига"
        return 1
    fi
    chmod 600 "$SERVER_CONF_FILE"
    log "Пир '$name' добавлен в серверный конфиг."
    return 0
}

# Удаление [Peer] из серверного конфига по имени (с блокировкой)
# remove_peer_from_server <name>
remove_peer_from_server() {
    local name="$1"

    if [[ -z "$name" ]]; then
        log_error "remove_peer_from_server: не указано имя"
        return 1
    fi
    # Defense-in-depth: тот же контракт, что в add_peer_to_server.
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "remove_peer_from_server: невалидное имя клиента '$name'"
        return 1
    fi

    # Межпроцессная блокировка
    local lockfile="${AWG_DIR}/.awg_config.lock"
    local lock_fd
    exec {lock_fd}>"$lockfile"
    if ! flock -x -w 10 "$lock_fd"; then
        log_error "Не удалось получить блокировку конфига"
        exec {lock_fd}>&-
        return 1
    fi

    if ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE" 2>/dev/null; then
        log_error "Пир '$name' не найден в конфиге"
        exec {lock_fd}>&-
        return 1
    fi

    # temp в каталоге серверного конфига -> финальный mv = атомарный rename.
    local tmpfile
    tmpfile=$(awg_mktemp "$(dirname "$SERVER_CONF_FILE")") || { log_error "Ошибка mktemp"; exec {lock_fd}>&-; return 1; }

    # Удаляем блок [Peer] содержащий #_Name = name
    # Логика: буферизуем каждый [Peer] блок, проверяем имя, выводим только если не совпадает
    awk -v target="$name" '
    BEGIN { buf=""; is_target=0 }
    /^\[Peer\]/ {
        # Вывести предыдущий буфер если он не target
        if (buf != "" && !is_target) printf "%s", buf
        buf = $0 "\n"
        is_target = 0
        next
    }
    /^\[/ && !/^\[Peer\]/ {
        # Любая другая секция — сбросить буфер
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
        log_error "Ошибка фильтрации серверного конфига (awk)"
        rm -f "$tmpfile"
        exec {lock_fd}>&-
        return 1
    }

    # Sanity-check ДО mv: при ENOSPC/I/O-сбое awk оставил бы пустой/обрезанный
    # tmpfile, и атомарный mv заменил бы рабочий конфиг битым (потеря
    # PrivateKey сервера и всех пиров). [Interface] обязан сохраниться.
    if ! grep -q '^\[Interface\]' "$tmpfile"; then
        log_error "Результат удаления пира выглядит битым ([Interface] отсутствует) - конфиг не изменён"
        rm -f "$tmpfile"
        exec {lock_fd}>&-
        return 1
    fi

    # Нормализация: сжать множественные пустые строки в одну.
    # tmpclean - на той же ФС, что и tmpfile (mv tmpclean->tmpfile атомарен).
    local tmpclean
    tmpclean=$(awg_mktemp "$(dirname "$SERVER_CONF_FILE")") || { log_error "Ошибка mktemp"; exec {lock_fd}>&-; return 1; }
    if cat -s "$tmpfile" > "$tmpclean" 2>/dev/null; then
        mv "$tmpclean" "$tmpfile"
    else
        rm -f "$tmpclean"
    fi

    if ! mv "$tmpfile" "$SERVER_CONF_FILE"; then
        rm -f "$tmpfile"
        log_error "Ошибка обновления серверного конфига"
        exec {lock_fd}>&-
        return 1
    fi
    chmod 600 "$SERVER_CONF_FILE"
    exec {lock_fd}>&-
    log "Пир '$name' удалён из серверного конфига."
    return 0
}

# ==============================================================================
# Полный цикл работы с клиентом
# ==============================================================================

# Генерация QR-кода для клиента
# generate_qr <name>
generate_qr() {
    local name="$1"
    local conf_file="$AWG_DIR/${name}.conf"
    local png_file="$AWG_DIR/${name}.png"

    if [[ ! -f "$conf_file" ]]; then
        log_error "Конфиг клиента '$name' не найден: $conf_file"
        return 1
    fi

    if ! command -v qrencode &>/dev/null; then
        log_warn "qrencode не установлен, QR-код не создан для '$name'."
        return 1
    fi

    # C4: генерируем во временный файл и атомарно переносим (mv) - чтобы
    # прерывание qrencode не оставило частичный/битый PNG поверх рабочего.
    # awg_mktemp "$AWG_DIR" кладёт tmp в ту же папку (mv = атомарный rename на
    # одной ФС) И регистрирует его в общем cleanup-реестре, поэтому SIGKILL
    # между qrencode и mv не оставит осиротевший tmp.
    local tmp_png
    tmp_png=$(awg_mktemp "$AWG_DIR") || { log_error "Ошибка mktemp для QR '$name'"; return 1; }
    if ! qrencode -t png -o "$tmp_png" < "$conf_file"; then
        log_error "Ошибка генерации QR-кода для '$name'"
        rm -f "$tmp_png"
        return 1
    fi
    chmod 600 "$tmp_png" 2>/dev/null
    if ! mv -f "$tmp_png" "$png_file"; then
        log_error "Ошибка сохранения QR-кода для '$name'"
        rm -f "$tmp_png"
        return 1
    fi
    log_debug "QR-код для '$name' создан: $png_file"
    return 0
}

# Генерация vpn:// URI для импорта в Amnezia Client
# generate_vpn_uri <name>
generate_vpn_uri() {
    case $- in *x*) _awg_xtrace_guard generate_vpn_uri "$@"; return ;; esac
    local name="$1"
    local conf_file="$AWG_DIR/${name}.conf"
    local uri_file="$AWG_DIR/${name}.vpnuri"

    if [[ ! -f "$conf_file" ]]; then
        log_error "Конфиг клиента '$name' не найден: $conf_file"
        return 1
    fi

    if ! command -v perl &>/dev/null; then
        log_warn "perl не найден, vpn:// URI не создан для '$name'."
        return 1
    fi

    if ! perl -MCompress::Zlib -MMIME::Base64 -e '1' 2>/dev/null; then
        log_warn "Perl модули Compress::Zlib/MIME::Base64 не найдены, vpn:// URI не создан."
        return 1
    fi

    load_awg_params || return 1

    # AWG_PORT - единственное НЕкавыченное числовое поле inner JSON ("port":N).
    # Пустое/нечисловое значение дало бы "port":, - синтаксически битый JSON,
    # который Amnezia Client молча не импортирует.
    if ! [[ "${AWG_PORT:-}" =~ ^[0-9]+$ ]]; then
        log_warn "AWG_PORT не определён или не число ('${AWG_PORT:-}') - vpn:// URI не создан для '$name'."
        return 1
    fi

    local client_privkey client_ip client_ipv6 server_pubkey endpoint allowed_ips client_psk
    client_privkey=$(grep -oP 'PrivateKey\s*=\s*\K\S+' "$conf_file") || { log_warn "PrivateKey не прочитан из '$conf_file' - vpn:// URI не создан для '$name'."; return 1; }
    # Извлекаем IPv4 из Address (первое поле до запятой, без /prefix).
    # Regex останавливается на цифрах и точках - не захватывает IPv6 при dual-stack.
    client_ip=$(awk '/^Address[[:space:]]*=/{
        sub(/^Address[[:space:]]*=[[:space:]]*/, "")
        sub(/\r$/, "")
        n = split($0, parts, /[[:space:]]*,[[:space:]]*/)
        sub(/\/[0-9]+$/, "", parts[1])
        print parts[1]; exit
    }' "$conf_file") || return 1
    # Извлекаем IPv6 из Address (второе поле, если присутствует), без /prefix.
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
    # Адрес стока - не IPv6 клиента: в client_ipv6 он не идёт.
    if _is_v6_sink_addr "$client_ipv6"; then
        client_ipv6=""
    fi
    _ensure_server_public_key || return 1
    server_pubkey=$(cat "$AWG_DIR/server_public.key" 2>/dev/null) || { log_warn "Не прочитан $AWG_DIR/server_public.key - vpn:// URI не создан для '$name'."; return 1; }
    # PresharedKey — опциональный. awk вместо grep чтобы пустой результат
    # не считался ошибкой (grep -P без match → rc=1, нам это здесь не нужно).
    # Дополнительно срезаем CR (CRLF от Windows-редакторов) и хвостовые
    # пробелы — иначе они улетят в JSON psk_key и сломают handshake так же,
    # как полное отсутствие поля. Без psk_key в inner JSON AmneziaVPN импорт
    # vpn:// теряет PSK и handshake падает (issue #67, fix v5.11.4).
    client_psk=$(awk '/^[[:space:]]*PresharedKey[[:space:]]*=/{sub(/^[[:space:]]*PresharedKey[[:space:]]*=[[:space:]]*/, ""); sub(/\r$/, ""); sub(/[ \t]+$/, ""); print; exit}' "$conf_file" 2>/dev/null)
    # Третья линия: ключ и паддинг берём ИЗ КЛИЕНТСКОГО .conf - ссылка описывает
    # именно его, и так же берётся PresharedKey. Поля пишутся только на установке
    # 3.1, как и строки в рендерах: на 2.0 и при нечитаемом маркере ссылка та же,
    # что была. На 3.1 отсутствие ключа или паддинга в профиле - отказ: такая
    # ссылка выглядит рабочей и молча не подключается, а человек видит только
    # «не работает».
    local client_hpk client_cpa uri_gen
    client_hpk=$(awk '/^[[:space:]]*HeaderProtectionKey[[:space:]]*=/{sub(/^[[:space:]]*HeaderProtectionKey[[:space:]]*=[[:space:]]*/, ""); sub(/\r$/, ""); sub(/[ \t]+$/, ""); print; exit}' "$conf_file" 2>/dev/null)
    client_cpa=$(awk '/^[[:space:]]*ContentPaddingAddition[[:space:]]*=/{sub(/^[[:space:]]*ContentPaddingAddition[[:space:]]*=[[:space:]]*/, ""); sub(/\r$/, ""); sub(/[ \t]+$/, ""); print; exit}' "$conf_file" 2>/dev/null)
    uri_gen=$(_awg_generation_from_init "$CONFIG_FILE") || uri_gen=broken
    if [[ "$uri_gen" == "3.1" ]]; then
        if [[ -z "$client_hpk" ]]; then
            log_error "В конфиге клиента '$name' нет HeaderProtectionKey, а установка помечена поколением 3.1: ссылка vpn:// не создана, иначе она выглядела бы рабочей и не подключилась бы"
            return 1
        fi
        if [[ -z "$client_cpa" ]]; then
            log_error "В конфиге клиента '$name' нет ContentPaddingAddition, а установка помечена поколением 3.1: ссылка vpn:// не создана"
            return 1
        fi
    else
        client_hpk=""
        client_cpa=""
    fi
    local raw_endpoint
    raw_endpoint=$(grep -oP 'Endpoint\s*=\s*\K\S+' "$conf_file") || { log_warn "Endpoint не прочитан из '$conf_file' - vpn:// URI не создан для '$name'."; return 1; }
    if [[ "$raw_endpoint" == \[* ]]; then
        # IPv6: [addr]:port
        endpoint="${raw_endpoint%%]:*}"
        endpoint="${endpoint#\[}"
    else
        # IPv4/hostname: addr:port
        endpoint="${raw_endpoint%:*}"
    fi
    # tr -d ' \r' - стирает пробелы И CR (на CRLF-конфигах '.+' жадно
    # затягивает \r в значение, что ломает JSON.allowed_ips).
    #
    # v5.27.1: НЕ трогать. Значение уходит в JSON-массив allowed_ips через
    # split(/,/), поэтому пробелы тут вредны - они уехали бы внутрь элементов
    # массива. Пробелы в клиентском .conf этот путь не портит: встроенный
    # конфиг вкладывается из файла как есть.
    allowed_ips=$(grep -oP 'AllowedIPs\s*=\s*\K.+' "$conf_file" | paste -sd, - | tr -d ' \r')
    # Проверяем ПУСТОТУ, а не код возврата: `||` тут не срабатывал даже на
    # строке "AllowedIPs = " без значения, потому что grep находил пробел и
    # выходил с нулём, а конвейер с paste делает статус тем более бесполезным.
    [[ -n "$allowed_ips" ]] || { log_warn "AllowedIPs не прочитан из '$conf_file' - в ссылку уйдёт полный туннель."; allowed_ips="0.0.0.0/0"; }

    # MTU/PersistentKeepalive/DNS из .conf - могли быть изменены через manage modify.
    # Клиент Amnezia при импорте vpn:// использует структурные поля inner JSON
    # (awgConfigurator берёт mtu именно из структурного поля, не из embedded config),
    # поэтому хардкод рассинхронизировал бы их с .conf - тот же класс, что issue #67
    # (structured-поле psk_key было авторитетным).
    local mtu keepalive dns_line dns1 dns2
    mtu=$(grep -oP '^MTU\s*=\s*\K[0-9]+' "$conf_file" | head -n1); mtu="${mtu:-1280}"
    keepalive=$(grep -oP '^PersistentKeepalive\s*=\s*\K[0-9]+' "$conf_file" | head -n1); keepalive="${keepalive:-33}"
    dns_line=$(grep -oP '^DNS\s*=\s*\K.+' "$conf_file" | paste -sd, - | tr -d ' \r')
    dns1="${dns_line%%,*}"; dns1="${dns1:-1.1.1.1}"
    if [[ "$dns_line" == *,* ]]; then dns2="${dns_line#*,}"; dns2="${dns2%%,*}"; else dns2="$dns1"; fi

    local vpn_uri perl_err
    perl_err=$(awg_mktemp "$AWG_DIR") || { log_warn "Ошибка mktemp - vpn:// URI не создан для '$name'."; return 1; }
    # Секреты (privkey клиента, PSK) передаются в perl через env, НЕ через argv:
    # командная строка процесса видна всем пользователям в /proc/<pid>/cmdline
    # на время работы perl. server_pubkey не секрет, но идёт той же группой.
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
        log_warn "Ошибка генерации vpn:// URI для '$name'."
        [[ -s "$perl_err" ]] && log_warn "Perl: $(cat "$perl_err")"
        rm -f "$perl_err"
        return 1
    fi
    rm -f "$perl_err"

    # Пишем через tmp + atomic mv (как .conf/.png), чтобы обрыв записи не оставил
    # пустой/обрезанный .vpnuri поверх рабочего.
    local _uri_tmp
    _uri_tmp=$(awg_mktemp "$AWG_DIR") || { log_error "Ошибка mktemp для vpn:// URI '$name'"; return 1; }
    printf '%s\n' "$vpn_uri" > "$_uri_tmp" || { rm -f "$_uri_tmp"; log_error "Ошибка записи vpn:// URI для '$name'"; return 1; }
    chmod 600 "$_uri_tmp"
    if ! mv -f "$_uri_tmp" "$uri_file"; then
        rm -f "$_uri_tmp"
        log_error "Ошибка сохранения vpn:// URI для '$name'"
        return 1
    fi
    log_debug "vpn:// URI для '$name' создан: $uri_file"
    return 0
}

# Генерация QR-кода из vpn:// URI (для импорта в Amnezia VPN app Android/iOS/Desktop)
# generate_qr_vpnuri <name>
#
# Пишет через tmp в той же директории + atomic mv, чтобы при сбое qrencode
# или chmod пользователь никогда не увидел обрезанный `.vpnuri.png`:
# старая версия файла остаётся на месте, новая появляется только целиком.
generate_qr_vpnuri() {
    local name="$1"
    local uri_file="$AWG_DIR/${name}.vpnuri"
    local png_file="$AWG_DIR/${name}.vpnuri.png"
    local tmp_png

    if [[ ! -f "$uri_file" ]]; then
        log_error "vpn:// URI для '$name' не найден: $uri_file"
        return 1
    fi

    if ! command -v qrencode &>/dev/null; then
        log_warn "qrencode не установлен, QR vpn:// не создан для '$name'."
        return 1
    fi

    # tmp через awg_mktemp (общий cleanup-реестр + atomic mv в той же ФС).
    tmp_png=$(awg_mktemp "$AWG_DIR") || { log_error "Ошибка mktemp для QR vpn:// '$name'"; return 1; }

    # Флаги qrencode для длинных vpn:// URI с PSK (issue #72):
    #   -8    единый 8-битный byte-режим. Без него оптимизатор qrencode дробит
    #         base64-URI на чередующиеся alnum/byte сегменты, и overhead смены
    #         режимов раздувает поток за ёмкость v40-L (2953 байта). Большие
    #         конфиги с I1-I5/CPS падали с "Input data too large", хотя сами
    #         данные под лимитом (URI ~2929 байт < 2953) - в один byte-сегмент
    #         влезают. Репортёр: pqqsnupl (ntc.party).
    #   -s 6  размер модуля 6 пикселей вместо дефолтных 3 - это и есть основной фикс.
    #         На дефолтном масштабе модули были слишком мелкими, чтобы камера iPhone
    #         различала их при сканировании PNG с экрана компьютера - отсюда ошибка 900
    #         ImportInvalidConfigError в AmneziaVPN iOS у @haritos90 в issue #72.
    #   -l L  низший уровень коррекции ошибок - это уже дефолт qrencode, фиксируем явно
    #         для защиты от смены дефолта в будущих версиях библиотеки.
    #   -m 4  стандартная тихая зона из 4 модулей - тоже дефолт, фиксируем явно.
    if ! qrencode -8 -t png -l L -s 6 -m 4 -o "$tmp_png" < "$uri_file"; then
        log_error "Ошибка генерации QR vpn:// для '$name' (возможно, конфиг слишком велик для одного QR - импортируйте vpn:// из файла ${name}.vpnuri вручную)."
        rm -f "$tmp_png"
        return 1
    fi

    if ! chmod 600 "$tmp_png"; then
        log_error "Не удалось выставить права 600 на $tmp_png"
        rm -f "$tmp_png"
        return 1
    fi

    if ! mv -f "$tmp_png" "$png_file"; then
        log_error "Ошибка сохранения QR vpn:// для '$name'"
        rm -f "$tmp_png"
        return 1
    fi
    log_debug "QR vpn:// для '$name' создан: $png_file"
    return 0
}

# Удаляет частично созданные артефакты клиента (ключи + .conf). Используется
# в early-error путях generate_client - C10: не оставлять orphan-ключи при сбое
# до коммита пира в серверный конфиг.
_rollback_client_artifacts() {
    rm -f "$KEYS_DIR/$1.private" "$KEYS_DIR/$1.public" "$AWG_DIR/$1.conf"
}

# _awg31_require_client_tools : инструменты, без которых профиль 3.1 неполон.
# На 3.1 клиент получает комплект из четырёх файлов, и ссылка vpn:// для него не
# удобство, а единственный простой способ внести профиль в приложение. Ссылку
# делает perl с Compress::Zlib и MIME::Base64, оба QR - qrencode. Поэтому на 3.1
# отсутствие инструмента - отказ ДО изменений, с именем того, чего не хватает,
# а не сбой на середине установки. На 2.0 функция не делает ничего.
_awg31_require_client_tools() {
    local gen
    gen=$(_awg_generation_from_init "$CONFIG_FILE") || {
        log_error "Маркер поколения AWG_PROTOCOL в $CONFIG_FILE не читается: набор инструментов не проверен"
        return 1
    }
    [[ "$gen" == "3.1" ]] || return 0
    if ! command -v qrencode >/dev/null 2>&1; then
        log_error "Для профиля 3.1 нужен qrencode: без него не будет ни QR конфига, ни QR ссылки. Установите qrencode и повторите"
        return 1
    fi
    if ! command -v perl >/dev/null 2>&1; then
        log_error "Для профиля 3.1 нужен perl: без него не собрать ссылку vpn://. Установите perl и повторите"
        return 1
    fi
    if ! perl -MCompress::Zlib -MMIME::Base64 -e '1' 2>/dev/null; then
        log_error "Для профиля 3.1 нужны модули perl Compress::Zlib и MIME::Base64: без них не собрать ссылку vpn://. Установите их и повторите"
        return 1
    fi
    return 0
}

# _awg31_refuse_client_leftovers <имя> [<имя>...] : остатки файлов клиента.
# generate_client отказывает клиенту, у которого уже есть ключи или .conf. На 2.0
# шаг 6 пишет об этом предупреждение и идёт дальше; на 3.1 такой отказ случился бы
# уже ПОСЛЕ перезаписи серверного конфига и означал бы откат, поэтому остатки
# проверяются до первой правки и файл называется. .png, .vpnuri и .vpnuri.png
# тоже остатки, хотя generate_client их перезаписывает: при сбое новой ссылки
# старый файл прошёл бы проверку комплекта как настоящий. На 2.0 функция не
# делает ничего, при нечитаемом маркере отказывает.
_awg31_refuse_client_leftovers() {
    local gen name f
    gen=$(_awg_generation_from_init "$CONFIG_FILE") || {
        log_error "Маркер поколения AWG_PROTOCOL в $CONFIG_FILE не читается: остатки файлов клиентов не проверены"
        return 1
    }
    [[ "$gen" == "3.1" ]] || return 0
    for name in "$@"; do
        for f in "$AWG_DIR/${name}.conf" "$AWG_DIR/${name}.png" "$AWG_DIR/${name}.vpnuri" \
                 "$AWG_DIR/${name}.vpnuri.png" "$KEYS_DIR/${name}.private" "$KEYS_DIR/${name}.public"; do
            if [[ -e "$f" || -L "$f" ]]; then
                log_error "Остался файл клиента '$name': $f. Установка 3.1 остановлена до первых изменений: уберите остатки прежнего клиента и повторите"
                return 1
            fi
        done
    done
    return 0
}

# awg_client_artifacts_check <имя> : комплект файлов клиента как ЕДИНОЕ целое.
# Клиенту выдают четыре файла - .conf, его QR, ссылку vpn:// и QR ссылки. Их
# делают разные шаги, и сбой одного из них раньше был предупреждением: человек
# получал папку, которая выглядит полной, и клиента, который не работает.
# Проверяются существование, обычный файл (не ссылка) и непустота каждого, а
# также что .vpnuri действительно начинается с vpn://.
# На установке 3.1 дополнительно проверяется сам профиль: в [Interface] ровно
# один HeaderProtectionKey, равный файлу ключа, и ContentPaddingAddition, равный
# паддингу установки. Профиль с чужим ключом от рабочего не отличить, пока
# туннель не откажется подниматься.
# 🔴 Функция защищена от трассировки: она сравнивает значение ключа.
# Ожидаемый паддинг берётся из УЖЕ ЗАГРУЖЕННЫХ параметров ($AWG_CPA), в той же
# нормализованной форме, в какой его пишут рендеры: вызывающий обязан до этого
# загрузить параметры (load_awg_params), иначе сравнение идёт с тем, что лежит в
# окружении: пустым или устаревшим значением.
# Паддинг ищется по первой строке ContentPaddingAddition в файле; секция и
# единственность, в отличие от ключа, не проверяются.
awg_client_artifacts_check() {
    _awg_xtrace_guard _awg_client_artifacts_check_body "$@"
}

_awg_client_artifacts_check_body() {
    local name="${1:-}" f gen keyfile key conf uri_first conf_cpa want_cpa
    local _hs_any=0 _hs_if=0 _hs_out=0 _hs_val=""
    if [[ -z "$name" ]]; then
        log_error "awg_client_artifacts_check: не указано имя клиента"
        return 1
    fi
    conf="$AWG_DIR/${name}.conf"
    for f in "$conf" "$AWG_DIR/${name}.png" "$AWG_DIR/${name}.vpnuri" "$AWG_DIR/${name}.vpnuri.png"; do
        if [[ -L "$f" ]]; then
            log_error "Комплект клиента '$name' неполон: $f - символьная ссылка, а должен быть обычный файл"
            return 1
        fi
        if [[ ! -f "$f" ]]; then
            log_error "Комплект клиента '$name' неполон: нет файла $f"
            return 1
        fi
        if [[ ! -s "$f" ]]; then
            log_error "Комплект клиента '$name' неполон: файл $f пуст"
            return 1
        fi
    done
    if ! IFS= read -r uri_first < "$AWG_DIR/${name}.vpnuri"; then
        log_error "Комплект клиента '$name': файл ссылки $AWG_DIR/${name}.vpnuri не читается"
        return 1
    fi
    if [[ "$uri_first" != vpn://* ]]; then
        log_error "Комплект клиента '$name': $AWG_DIR/${name}.vpnuri не начинается с vpn:// - такую ссылку клиент не импортирует"
        return 1
    fi
    gen=$(_awg_generation_from_init "$CONFIG_FILE") || {
        log_error "Маркер поколения AWG_PROTOCOL в $CONFIG_FILE не читается: комплект клиента '$name' не проверен"
        return 1
    }
    [[ "$gen" == "3.1" ]] || return 0
    keyfile=$(awg_hpk_path) || { log_error "AWG_DIR не задан: комплект клиента '$name' не проверен"; return 1; }
    if [[ ! -f "$keyfile" ]]; then
        log_error "Комплект клиента '$name': установка помечена поколением 3.1, а файла ключа $keyfile нет"
        return 1
    fi
    if ! IFS= read -r key < "$keyfile"; then
        log_error "Комплект клиента '$name': файл ключа $keyfile не читается"
        return 1
    fi
    _awg_hpk_conf_scan "$conf" || {
        log_error "Комплект клиента '$name': не удалось разобрать $conf"
        return 1
    }
    if (( _hs_out > 0 )); then
        log_error "Комплект клиента '$name': HeaderProtectionKey стоит вне секции [Interface] в $conf"
        return 1
    fi
    if (( _hs_if != 1 )); then
        log_error "Комплект клиента '$name': в [Interface] $conf должен быть ровно один HeaderProtectionKey, найдено ${_hs_if}"
        return 1
    fi
    if [[ "$_hs_val" != "$key" ]]; then
        log_error "Комплект клиента '$name': HeaderProtectionKey в $conf не совпадает с файлом ключа $keyfile - такой профиль не подключится"
        return 1
    fi
    conf_cpa=$(awk '/^[[:space:]]*ContentPaddingAddition[[:space:]]*=/{sub(/^[[:space:]]*ContentPaddingAddition[[:space:]]*=[[:space:]]*/, ""); sub(/\r$/, ""); sub(/[ \t]+$/, ""); print; exit}' "$conf" 2>/dev/null)
    if [[ -z "$conf_cpa" ]]; then
        log_error "Комплект клиента '$name': в $conf нет ContentPaddingAddition, а установка помечена поколением 3.1"
        return 1
    fi
    want_cpa="${AWG_CPA:-}"
    want_cpa="${want_cpa%%#*}"
    want_cpa="${want_cpa//[[:space:]]/}"
    if [[ "$conf_cpa" != "$want_cpa" ]]; then
        log_error "Комплект клиента '$name': ContentPaddingAddition в $conf ('$conf_cpa') не совпадает с параметром установки ('$want_cpa')"
        return 1
    fi
    return 0
}

# Полный набор клиентских артефактов (conf/png/vpnuri/vpnuri.png + ключи).
# Единый список для `manage remove` и автоудаления истёкших, чтобы пути не
# расходились (раньше expiry-cleanup забывал .vpnuri.png). НЕ трогает expiry-метку
# и cron - это делает вызывающий (remove_client_expiry / rm "$efile").
_remove_client_files() {
    local name="$1"
    rm -f "$AWG_DIR/${name}.conf" "$AWG_DIR/${name}.png" \
        "$AWG_DIR/${name}.vpnuri" "$AWG_DIR/${name}.vpnuri.png" \
        "$KEYS_DIR/${name}.private" "$KEYS_DIR/${name}.public"
}

# Полный цикл создания клиента:
# keypair → next IP → client config → add peer → QR
# generate_client <name> [endpoint]
#
# Env var contract:
#   CLIENT_PSK — необязательный. Если установлен в "auto", генерирует
#     свежий PSK через `awg genpsk` и прописывает его и в серверный
#     [Peer], и в клиентский [Peer]. Если установлен в конкретное
#     значение (32-байт base64) — использует его без генерации. Если
#     пуст/не установлен — PSK не добавляется (default behaviour).
#   CLIENT_ALLOWED_IPS - необязательный (Issue #253). Индивидуальные
#     маршруты клиента вместо глобального режима сервера (ALLOWED_IPS):
#     список CIDR IPv4/IPv6 через запятую. Значение проверяется и
#     нормализуется здесь же; пустой/unset - глобальный режим как раньше.
#     Экспортирует `manage add --allowed-ips=...`; прямой вызов с env -
#     тоже валиден (контракт библиотеки, а не только CLI).
generate_client() {
    case $- in *x*) _awg_xtrace_guard generate_client "$@"; return ;; esac
    local name="$1"
    local endpoint="${2:-}"

    if [[ -z "$name" ]]; then
        log_error "generate_client: не указано имя"
        return 1
    fi
    # Контракт библиотеки (defense-in-depth): имя с метасимволами/переводами
    # строк дало бы инъекцию в пути и heredoc серверного конфига. Тот же
    # regex, что validate_client_name в manage и set_client_expiry здесь.
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "generate_client: невалидное имя клиента '$name'"
        return 1
    fi

    # CLIENT_ALLOWED_IPS (Issue #253): валидация ДО генерации ключей и
    # блокировки - невалидное значение не должно оставлять артефактов и не
    # должно занимать lock. Проверка здесь дублирует раннюю валидацию в
    # manage add: env-контракт доступен и напрямую, без CLI.
    if [[ -n "${CLIENT_ALLOWED_IPS:-}" ]]; then
        if ! awg_validate_allowed_ips_list "$CLIENT_ALLOWED_IPS"; then
            log_error "generate_client: некорректный CLIENT_ALLOWED_IPS - клиент '$name' НЕ создан."
            return 1
        fi
        CLIENT_ALLOWED_IPS=$(awg_normalize_csv "$CLIENT_ALLOWED_IPS")
        [[ -n "$CLIENT_ALLOWED_IPS" ]] || {
            log_error "generate_client: нормализация CLIENT_ALLOWED_IPS дала пустое значение - клиент '$name' НЕ создан."
            return 1
        }
    fi

    # Загружаем параметры
    load_awg_params || return 1

    # Опциональный PresharedKey: "auto" → `awg genpsk`, иначе используем
    # переданное значение как есть. Пустое/unset → без PSK.
    if [[ "${CLIENT_PSK:-}" == "auto" ]]; then
        # --psk запрошен явно: при сбое awg genpsk НЕ деградируем молча в клиента
        # без PSK (это ослабило бы запрошенную безопасность). Fail-closed; здесь
        # ещё нет созданных артефактов (ключи/конфиг создаются ниже), откат не нужен.
        CLIENT_PSK=$(awg genpsk) || {
            log_error "awg genpsk не сработал - клиент с PresharedKey (--psk) НЕ создан. Повторите."
            return 1
        }
    fi

    # Межпроцессная блокировка: атомарность IP-аллокации + добавления пира
    local lockfile="${AWG_DIR}/.awg_config.lock"
    local lock_fd
    exec {lock_fd}>"$lockfile"
    if ! flock -x -w 30 "$lock_fd"; then
        log_error "Не удалось получить блокировку конфига"
        exec {lock_fd}>&-
        return 1
    fi

    # C6: клиент не должен уже существовать. Проверяю ПОД локом, ДО генерации
    # ключей - иначе `add <существующее_имя>` молча перезатёр бы ключи живого
    # клиента (generate_keypair перезаписывает безусловно), а параллельный add
    # того же имени гонялся бы за перезапись.
    if [[ -e "$KEYS_DIR/${name}.private" || -e "$KEYS_DIR/${name}.public" || -e "$AWG_DIR/${name}.conf" ]]; then
        log_error "Клиент '$name' уже существует. Используйте 'remove' или другое имя."
        exec {lock_fd}>&-
        return 1
    fi

    # Генерация ключей. С этого момента любой ранний сбой обязан удалить уже
    # созданные ключи/conf (C10) через _rollback_client_artifacts.
    generate_keypair "$name" || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }

    # Следующий свободный IP
    local client_ip
    client_ip=$(get_next_client_ip) || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }

    # IPv6-адрес клиента (при ALLOW_IPV6_TUNNEL=1)
    local client_ipv6=""
    if [[ "${ALLOW_IPV6_TUNNEL:-0}" == "1" ]]; then
        client_ipv6=$(get_next_client_ipv6 "$client_ip") || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }
        log_debug "Выделен IPv6-адрес ${client_ipv6} для клиента ${name}"
    fi

    # Читаем ключи
    local client_privkey client_pubkey server_pubkey
    client_privkey=$(cat "$KEYS_DIR/${name}.private") || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }
    client_pubkey=$(cat "$KEYS_DIR/${name}.public") || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }

    # Пытаемся восстановить server_public.key из awg0.conf если кеша нет
    # (поддержка ручных установок без installer-шага 6).
    _ensure_server_public_key || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }
    server_pubkey=$(cat "$AWG_DIR/server_public.key") || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }

    # Endpoint: из аргумента → AWG_ENDPOINT (awgsetup_cfg.init) → curl до
    # внешних сервисов → локальный IP с сетевого интерфейса.
    # Последний fallback для LXC / сред без egress: может быть NAT-адресом,
    # поэтому предупреждаем пользователя в лог.
    if [[ -z "$endpoint" ]]; then
        endpoint="${AWG_ENDPOINT:-}"
    fi
    if [[ -z "$endpoint" ]]; then
        endpoint=$(get_server_public_ip)
    fi
    if [[ -z "$endpoint" ]]; then
        endpoint=$(_try_local_ip) && log_warn "Используется локальный IP сервера как Endpoint ('$endpoint') — curl до внешних сервисов не прошёл. Если сервер за NAT, поправьте Endpoint в клиентских .conf вручную."
    fi
    if [[ -z "$endpoint" ]]; then
        log_error "Не удалось определить внешний IP сервера. Задайте AWG_ENDPOINT в awgsetup_cfg.init (или переустановите с --endpoint=IP)."
        _rollback_client_artifacts "$name"
        exec {lock_fd}>&-
        return 1
    fi

    # Порт сервера приходит из живого awg0.conf (ListenPort), иначе из
    # awgsetup_cfg.init - оба правятся руками. render ставит его в
    # 'Endpoint = IP:PORT' клиентского .conf: битый порт уносится на устройство
    # и отлаживается вслепую. Отказываем явно, как generate_vpn_uri для vpn://
    # URI. Артефакты откатит _rollback ниже.
    local _cport
    _cport=$(_sanitize_port "${AWG_PORT:-}")
    if [[ "$_cport" == "0" ]]; then
        log_error "AWG_PORT некорректен ('${AWG_PORT:-}') - клиентский конфиг для '$name' не создан. Проверьте ListenPort в $SERVER_CONF_FILE (или AWG_PORT в $CONFIG_FILE)."
        _rollback_client_artifacts "$name"
        exec {lock_fd}>&-
        return 1
    fi

    # Конфиг клиента
    render_client_config "$name" "$client_ip" "$client_privkey" "$server_pubkey" "$endpoint" "$_cport" "$client_ipv6" || {
        log_error "Откат: удаление артефактов '$name'"
        _rollback_client_artifacts "$name"
        exec {lock_fd}>&-
        return 1
    }

    # Добавляем пир в серверный конфиг
    if ! add_peer_to_server "$name" "$client_pubkey" "$client_ip" "$client_ipv6"; then
        log_error "Откат: удаление артефактов '$name'"
        _rollback_client_artifacts "$name"
        exec {lock_fd}>&-
        return 1
    fi

    # Освобождаем блокировку — пир записан, дальше некритичные операции
    exec {lock_fd}>&-

    # QR-код (необязательный, ошибка не фатальна)
    if ! generate_qr "$name"; then
        log_warn "QR-код не создан. Конфиг: $AWG_DIR/${name}.conf"
    fi

    # vpn:// URI и QR для Amnezia VPN app (необязательные).
    # QR vpn:// пробуем только если URI создан успешно — иначе читать нечего.
    if ! generate_vpn_uri "$name"; then
        log_warn "vpn:// URI не создан для '$name'."
    elif ! generate_qr_vpnuri "$name"; then
        log_warn "QR vpn:// не создан для '$name'."
    fi

    log "Клиент '$name' создан (IP: $client_ip)."
    return 0
}

# Перегенерация конфига и QR для существующего клиента
# regenerate_client <name> [endpoint]
#
# v5.11.0 A5.3: защищается блокировкой .awg_config.lock (сериализация
# с modify_client / remove и параллельными regen на том же имени) и
# проверяет возврат каждого sed -i при восстановлении пользовательских
# настроек — прежде молча игнорировались ошибки sed.
#
# Lock scope: держится только пока мутируется $AWG_DIR/${name}.conf.
# generate_qr / generate_vpn_uri / generate_qr_vpnuri вызываются ВНЕ lock
# как best-effort derived artifacts — если между sed-ом и QR-генерацией
# concurrent modify успеет изменить conf, QR может устареть на один такт.
# Также concurrent `manage remove <name>` может удалить клиента после
# release lock, и regen «воскресит» `.conf` / `.png` / `.vpnuri` /
# `.vpnuri.png` для уже удалённого peer-а (stale artefacts в $AWG_DIR).
# Это приемлемо: пользователь получит актуальное состояние на следующей
# операции (повторный `remove` или `regen`), и peer уже удалён из server-
# конфига — трафик через него не идёт. Включать QR/URI в lock дороже
# (lock на несколько секунд — блокирует другие клиенты) без выигрыша
# по целостности server-state.
regenerate_client() {
    case $- in *x*) _awg_xtrace_guard regenerate_client "$@"; return ;; esac
    local name="$1"
    local endpoint="${2:-}"

    if [[ -z "$name" ]]; then
        log_error "regenerate_client: не указано имя"
        return 1
    fi
    # Контракт библиотеки (defense-in-depth): имя интерполируется в пути и
    # конфиг, поэтому валидируем здесь же, не полагаясь на вызывающего
    # (manage делает свой validate_client_name, но cron/чужой скрипт - нет).
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "regenerate_client: невалидное имя клиента '$name'"
        return 1
    fi

    # Межпроцессная блокировка: защита от race с modify_client/remove и
    # параллельных regen на одном имени клиента.
    local lockfile="${AWG_DIR}/.awg_config.lock"
    local lock_fd
    exec {lock_fd}>"$lockfile"
    if ! flock -x -w 10 "$lock_fd"; then
        log_error "Не удалось получить блокировку конфига (другая операция выполняется)"
        exec {lock_fd}>&-
        return 1
    fi

    load_awg_params || { exec {lock_fd}>&-; return 1; }

    # Гигиена (Issue #253): CLIENT_ALLOWED_IPS - контракт генерации НОВОГО
    # клиента (manage add --allowed-ips), у regen его быть не должно. Без
    # зачистки утёкший в env override доехал бы до render_client_config, а с
    # --reset-routes ещё и остался бы в конфиге, отменяя сам смысл сброса
    # маршрутов на глобальный режим. Регенерируем всегда глобальным режимом,
    # индивидуальное значение ниже восстанавливается из существующего .conf.
    unset CLIENT_ALLOWED_IPS

    # Проверяем, что клиент существует в серверном конфиге
    if ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE" 2>/dev/null; then
        log_error "Клиент '$name' не найден в серверном конфиге"
        exec {lock_fd}>&-
        return 1
    fi

    # Читаем приватный ключ клиента
    local client_privkey client_ip server_pubkey
    if [[ -f "$KEYS_DIR/${name}.private" ]]; then
        client_privkey=$(cat "$KEYS_DIR/${name}.private")
    elif [[ -f "$AWG_DIR/${name}.conf" ]]; then
        # Пробуем извлечь из существующего конфига
        client_privkey=$(sed -n 's/^PrivateKey[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf" | tr -d '[:space:]')
    fi

    if [[ -z "$client_privkey" ]]; then
        log_error "Приватный ключ клиента '$name' не найден"
        exec {lock_fd}>&-
        return 1
    fi

    # IP клиента из серверного конфига
    # Ищем блок [Peer] с #_Name = name, затем AllowedIPs
    # Для dual-stack: ips[1] = IPv4/32, ips[2] = IPv6/128 (если есть)
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
        log_error "IP клиента '$name' не найден в серверном конфиге"
        exec {lock_fd}>&-
        return 1
    fi

    # Auto-gen из awg0.conf если кеша нет (ручная установка)
    _ensure_server_public_key || { exec {lock_fd}>&-; return 1; }
    server_pubkey=$(cat "$AWG_DIR/server_public.key" 2>/dev/null) || {
        log_error "Публичный ключ сервера не найден"
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
        endpoint=$(_try_local_ip) && log_warn "Используется локальный IP сервера как Endpoint ('$endpoint') — curl до внешних сервисов не прошёл."
    fi
    if [[ -z "$endpoint" ]]; then
        log_error "Не удалось определить внешний IP сервера."
        exec {lock_fd}>&-
        return 1
    fi

    # Сохраняем пользовательские настройки из текущего .conf (modify)
    # current_dns пуст, пока нет старого .conf: тогда DNS в конфиге - тот, что записал
    # render_client_config (CLIENT_DNS или значение по умолчанию), и перезаписывать его
    # зашитой константой нельзя - так терялся CLIENT_DNS на пути восстановления.
    local current_dns="" current_keepalive="33" current_allowed_ips="${ALLOWED_IPS:-0.0.0.0/0}"
    local _had_conf=0
    if [[ -f "$AWG_DIR/${name}.conf" ]]; then
        _had_conf=1
        local _v _raw
        # tr -d '[:space:]' стирал здесь пробелы после запятых, и regen писал
        # в .conf слипшийся список (D#38). Нормализуем, а не выкусываем.
        #
        # Строки СКЛЕИВАЮТСЯ, а не берётся первая: wg допускает повтор DNS и
        # AllowedIPs, значения при этом складываются. Прежний `tr` слеплял их в
        # заведомо невалидный CIDR, и awg-quick отказывался поднимать интерфейс
        # ГРОМКО; взять первую строку означало бы отдать пользователю валидный
        # конфиг, из которого часть сетей исчезла молча.
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
        # v5.11.1: preserve PresharedKey через regen — если у клиента
        # был PSK (создан с manage add --psk), regen без этого сохранения
        # выбросил бы его и сломал handshake (server peer всё ещё с PSK,
        # client conf уже без). CLIENT_PSK передаётся в render_client_config.
        local _psk
        _psk=$(sed -n '/^\[Peer\]/,$ s/^PresharedKey[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf" | tr -d '[:space:]')
        if [[ -n "$_psk" ]]; then
            export CLIENT_PSK="$_psk"
        else
            unset CLIENT_PSK
        fi
    else
        # Клиентский .conf утерян (regen как восстановление): PresharedKey
        # восстанавливаем из server [Peer]-блока, иначе пересозданный конфиг
        # вышел бы без PSK при живом PSK на сервере - handshake молча ломается.
        # Порядок полей в блоке контролируем мы (add_peer_to_server пишет
        # #_Name первым), поэтому found-then-PSK достаточно.
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

    # Тот же port-контроль, что в generate_client: битый AWG_PORT не должен
    # уйти в Endpoint пересозданного .conf.
    local _cport
    _cport=$(_sanitize_port "${AWG_PORT:-}")
    if [[ "$_cport" == "0" ]]; then
        log_error "AWG_PORT некорректен ('${AWG_PORT:-}') - конфиг '$name' не перегенерирован. Проверьте ListenPort в $SERVER_CONF_FILE (или AWG_PORT в $CONFIG_FILE)."
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    fi

    # Перегенерация конфига (передаём client_ipv6 если dual-stack). DNS живого клиента
    # отдаём render напрямую (8-й аргумент): его всё равно восстановим ниже.
    local _keep_dns=""
    [[ "$_had_conf" -eq 1 && -n "$current_dns" ]] && _keep_dns="$current_dns"
    render_client_config "$name" "$client_ip" "$client_privkey" "$server_pubkey" "$endpoint" "$_cport" "$client_ipv6" "$_keep_dns" || {
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    }

    # При regen подтягиваем новые дефолты для НЕ-кастомизированных клиентов:
    # полный туннель получает IPv6-маршрут (::/0 при 0.0.0.0/0, 2000::/3 у
    # списка режима 2; нужно iOS AmneziaVPN и закрывает утечку IPv6), одиночный
    # DNS 1.1.1.1 становится парой с резервом. Раздельная
    # маршрутизация, заданная пользователем через modify, полным туннелем не
    # является и сохраняется как есть.
    # Развилка живёт и здесь намеренно: без неё перевыпуск профиля не доставлял
    # бы исправление уже выданным клиентам, и совет 'обновите профиль' не лечил
    # бы утечку.
    # Всё это имеет смысл ТОЛЬКО когда сохранённые настройки будут
    # восстанавливаться. При --reset-routes и на пути восстановления
    # (конфига не было) значение ниже не используется вовсе, а отказ по нему
    # уронил бы уже удавшийся перевыпуск.
    if [[ "${AWG_REGEN_RESET_ROUTES:-0}" != "1" && "$_had_conf" -eq 1 ]]; then
        local _aip_new
        # Наш прежний ::/0 у списка режима 2 (v5.31.0-v5.36.x) отрезает на
        # Windows локальную сеть; обычный regen должен доставить замену. У
        # dual-stack клиента ::/0 - его собственная схема, её не трогаем.
        if [[ -z "$client_ipv6" ]]; then
            _aip_new=$(_aip_migrate_legacy_v6 "$current_allowed_ips" "${ALLOWED_IPS:-}") && [[ -n "$_aip_new" ]] || {
                log_error "Не удалось вычислить AllowedIPs для клиента '$name'. Конфиг уже перегенерирован из текущего режима маршрутизации, но индивидуальные настройки НЕ восстановлены - проверьте $AWG_DIR/${name}.conf."
                exec {lock_fd}>&-
                unset CLIENT_PSK
                return 1
            }
            if [[ "$_aip_new" != "$current_allowed_ips" ]]; then
                log "Клиент '$name': IPv6-маршрут ::/0 заменён на 2000::/3 (с ::/0 клиент для Windows отрезает локальную сеть)."
                current_allowed_ips="$_aip_new"
            elif _aip_has_token "$current_allowed_ips" "::/0" \
                 && ! _aip_has_token "$current_allowed_ips" "0.0.0.0/0" \
                 && _is_full_tunnel "$current_allowed_ips"; then
                # Наш ли это ::/0, доказать нельзя: список сервера с тех пор
                # мог поменяться (изоляция, подсеть), а мог быть задан вручную.
                # Оставляем, но молчать нельзя - это и есть отрезанная сеть.
                # Совет по режиму сервера: --reset-routes выдаёт СПИСОК СЕРВЕРА,
                # и помогает только когда тот сам в режиме 2; на режиме 1 или 3
                # он выдал бы 0.0.0.0/0 или раздельный список и стёр бы свой, а при
                # ::/0 в самом списке сервера вернул бы его же.
                if [[ "${ALLOWED_IPS:-}" != *:* ]] && ! _aip_has_token "${ALLOWED_IPS:-}" "0.0.0.0/0" \
                   && _is_full_tunnel "${ALLOWED_IPS:-}"; then
                    log_warn "Клиент '$name': полный туннель с ::/0 оставлен как есть - с ::/0 клиент AmneziaWG для Windows отрезает локальную сеть. Если маршрут выдан прежней версией установщика, выполните regen --reset-routes '$name'."
                else
                    log_warn "Клиент '$name': полный туннель с ::/0 оставлен как есть - с ::/0 клиент AmneziaWG для Windows отрезает локальную сеть. Чтобы сеть оставалась доступной, замените в его AllowedIPs ::/0 на 2000::/3 командой modify '$name' AllowedIPs."
                fi
            fi
        fi
        _aip_new=$(_append_ipv6_full_tunnel_route "$current_allowed_ips") && [[ -n "$_aip_new" ]] || {
            # Файл к этому моменту УЖЕ переписан render_client_config, поэтому
            # «конфиг не изменён» было бы ложью о состоянии, а это хуже отказа:
            # у человека не осталось бы повода заглянуть в файл.
            log_error "Не удалось вычислить AllowedIPs для клиента '$name'. Конфиг уже перегенерирован из текущего режима маршрутизации, но индивидуальные настройки НЕ восстановлены - проверьте $AWG_DIR/${name}.conf."
            exec {lock_fd}>&-
            unset CLIENT_PSK
            return 1
        }
        # Клиент, выданный с --allow-ipv6-tunnel, несёт в списке свою IPv6-часть,
        # и приёмник её не трогает - иначе перевыпуск ломал бы индивидуальную
        # настройку. Следствие: полному туннелю такого клиента ::/0 обычным regen
        # НЕ достаётся, а лечится это перевыпуском с --reset-routes.
        # 🔴 Условие про нативный IPv6 обязательно: БЕЗ него клиенту и положена
        # туннельная ULA вместо ::/0, это документированное правило, а не утечка.
        # Без этой проверки предупреждение печаталось бы всегда и советовало бы
        # команду, которая ничего не изменит - то есть звало бы чинить исправное.
        # С Issue #253 условие живёт в предикате _aip_full_tunnel_v6_gap и
        # разделяется с render_client_config (создаёт такие же списки).
        if _aip_full_tunnel_v6_gap "$current_allowed_ips"; then
            log_warn "Клиент '$name': IPv6-часть AllowedIPs сохранена как есть, ::/0 не дописан. Чтобы раздать текущий режим маршрутизации, выполните regen --reset-routes."
        fi
        current_allowed_ips="$_aip_new"
    fi
    # Одиночный 1.1.1.1 от старых версий становится парой, но не когда это
    # осознанный выбор через CLIENT_DNS='1.1.1.1'.
    [[ "$current_dns" == "1.1.1.1" && "$(awg_normalize_csv "${CLIENT_DNS:-}")" != "1.1.1.1" ]] && current_dns="1.1.1.1, 1.0.0.1"

    # Восстанавливаем пользовательские настройки (экранируем & и \ для sed replacement)
    local _dns _ka _aip
    _dns=$(printf '%s' "$current_dns" | sed 's/[&\\/]/\\&/g')
    _ka=$(printf '%s' "$current_keepalive" | sed 's/[&\\/]/\\&/g')
    _aip=$(printf '%s' "$current_allowed_ips" | sed 's/[&\\/]/\\&/g')
    local _client_conf="$AWG_DIR/${name}.conf"
    if [[ -n "$current_dns" ]]; then
        if ! sed -i "s/^DNS = .*/DNS = ${_dns}/" "$_client_conf"; then
            log_error "Ошибка sed при записи DNS в $_client_conf"
            exec {lock_fd}>&-
            unset CLIENT_PSK
            return 1
        fi
    fi
    if ! sed -i "s/^PersistentKeepalive = .*/PersistentKeepalive = ${_ka}/" "$_client_conf"; then
        log_error "Ошибка sed при записи PersistentKeepalive в $_client_conf"
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    fi
    # Делимитер '/' (а не '|'): класс экранирования выше покрывает & \ / -
    # символ '|' в значении сломал бы sed-выражение с '|'-делимитером.
    # regen --reset-routes (Issue #170): НЕ восстанавливаем старый AllowedIPs
    # клиента - оставляем значение из render_client_config, вычисленное из
    # глобального режима маршрутизации (awgsetup_cfg.init) с корректным
    # IPv6-зеркалированием. Обычный regen сохраняет индивидуальные настройки.
    if [[ "${AWG_REGEN_RESET_ROUTES:-0}" == "1" ]]; then
        log "AllowedIPs клиента '$name' сброшен на глобальный режим маршрутизации (--reset-routes)."
    elif [[ "$_had_conf" -eq 0 ]]; then
        # Конфига не было (regen как восстановление) - сохранять нечего, и
        # значение из render_client_config остаётся как есть. Прежде сюда
        # подставлялся глобальный список, из-за чего dual-stack клиент на
        # сервере без нативного IPv6 получал ::/0 вопреки собственному правилу.
        log "Конфиг клиента '$name' отсутствовал - AllowedIPs взят из текущего режима маршрутизации."
    elif ! sed -i "s/^AllowedIPs = .*/AllowedIPs = ${_aip}/" "$_client_conf"; then
        log_error "Ошибка sed при записи AllowedIPs в $_client_conf"
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    fi
    # Восстановленный список мог не совпасть с тем, под который render написал
    # Address (индивидуальный раздельный список на сервере в режиме 2).
    if ! _sync_v6_sink_address "$_client_conf"; then
        log_error "Не удалось привести Address клиента '$name' к его AllowedIPs: маршруты в $_client_conf уже записаны, а адрес стока IPv6 может им не соответствовать; QR и vpn:// не пересобраны. Устраните причину и повторите regen '$name'."
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    fi

    # Освобождаем блокировку — конфиг записан, дальше некритичные операции
    exec {lock_fd}>&-

    # QR-код
    generate_qr "$name"

    # vpn:// URI и QR для Amnezia VPN app (best-effort).
    # QR vpn:// пробуем только если URI пересоздан успешно.
    if generate_vpn_uri "$name"; then
        generate_qr_vpnuri "$name" || log_warn "QR vpn:// не обновлён для '$name'."
    else
        log_warn "vpn:// URI не обновлён для '$name'."
    fi

    # Hygiene: PSK не должен протекать в следующие операции в том же shell
    unset CLIENT_PSK

    log "Конфиг клиента '$name' перегенерирован."
    return 0
}

# ==============================================================================
# Валидация
# ==============================================================================

# validate_awg_config : проверка серверного конфига. Разбор держит значение ключа
# защиты заголовков в переменных, поэтому тело идёт с выключенной трассировкой:
# под --verbose установщика иначе ключ уехал бы в stderr.
validate_awg_config() {
    _awg_xtrace_guard _validate_awg_config_body "$@"
}

_validate_awg_config_body() {
    if [[ ! -f "$SERVER_CONF_FILE" ]]; then
        log_error "Серверный конфиг не найден: $SERVER_CONF_FILE"
        return 1
    fi

    local ok=1
    local param val
    local int_params=("Jc" "Jmin" "Jmax" "S1" "S2" "S3" "S4")
    local range_params=("H1" "H2" "H3" "H4")

    # Ключ защиты заголовков и паддинг содержимого разбираем ПЕРВЫМИ: от ключа
    # зависит, откуда брать остальные числа. Правила ключа включаются ЕГО
    # НАЛИЧИЕМ в файле, а не маркером поколения: restore проверяет
    # восстановленные файлы, модуль ядра и amneziawg-go включают защиту
    # заголовков по наличию ключа, а клиент вендора определяет поколение по
    # наличию таких ключей в конфиге. Разбор повторяет amneziawg-tools (секция и ключ
    # без учёта регистра, последнее значение). Граница: проверка читает только
    # файл и не видит ключ, оставшийся на живом интерфейсе.
    local _pairs _sec _k _v _cpa_why _hpk=0 _hpk_count=0 _hpk_val=""
    local -A _if_last=()
    if ! _pairs=$(_awg_conf_pairs "$SERVER_CONF_FILE"); then
        # Без разбора молча выключились бы все правила ключа, включая потолок
        # ContentPaddingAddition, который модуль ядра сам не ловит.
        log_error "Не удалось разобрать $SERVER_CONF_FILE: ключ защиты заголовков и ContentPaddingAddition не проверены"
        ok=0
    fi
    while IFS=$'\t' read -r _sec _k _v; do
        [[ -n "$_k" ]] || continue
        case "$_k" in
            headerprotectionkey)
                if [[ "$_sec" != "interface" ]]; then
                    log_error "HeaderProtectionKey стоит вне секции [Interface]"
                    ok=0
                    continue
                fi
                _hpk_count=$((_hpk_count + 1))
                _hpk_val="$_v"
                ;;
            contentpaddingaddition)
                # Каждую строку, а не последнюю. Tools применяют последнюю, но
                # строка вне допустимого - признак ручной правки, и надёжнее
                # отказать, чем полагаться на порядок строк.
                if ! _cpa_why=$(awg_cpa_check_safe "$_v"); then
                    log_error "Параметр 'ContentPaddingAddition' небезопасен: ${_cpa_why}"
                    ok=0
                fi
                ;;
        esac
        [[ "$_sec" == "interface" ]] && _if_last[$_k]="$_v"
    done <<< "$_pairs"

    if [[ "$_hpk_count" -ge 1 ]]; then
        _hpk=1
        if [[ "$_hpk_count" -gt 1 ]]; then
            log_error "HeaderProtectionKey задан в [Interface] ${_hpk_count} раза: применится только последний, оставьте один ключ"
            ok=0
        # Как key_from_base64 в tools: 44 символа, в конце '=', последний
        # значащий символ несёт нулевые младшие биты. Значение не печатаем.
        elif ! [[ "$_hpk_val" =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]]; then
            log_error "HeaderProtectionKey не похож на ключ: нужны 32 байта в base64, 44 символа"
            ok=0
        fi
    fi

    # Без ключа парсинг выровнен с load_awg_params_from_server_conf:
    # произвольные пробелы вокруг '=', last-wins при дублях строк (валидируем то значение, которое
    # реально загрузится), trim пробелов/CR. Раньше валидатор требовал ровно
    # один пробел и брал first-wins - вручную поправленный 'Jc=4' успешно
    # загружался, но проваливал валидацию с ложным "параметр не найден".
    # При ключе числа берутся из разбора выше, как их применят tools: иначе
    # строчный `s4 = 12` дал бы ложное "не найден", а поздний `s4 = 33` прошёл бы
    # мимо верхней границы. Без ключа путь прежний.
    for param in "${int_params[@]}"; do
        if [[ "$_hpk" -eq 1 ]]; then
            val="${_if_last[${param,,}]:-}"
        else
            val=$(sed -n "s/^[[:space:]]*${param}[[:space:]]*=[[:space:]]*//p" "$SERVER_CONF_FILE" | tail -1 | sed 's/#.*//' | tr -d '[:space:]')
        fi
        if [[ -z "$val" ]]; then
            log_error "Параметр '$param' не найден в серверном конфиге"
            ok=0
        elif ! [[ "$val" =~ ^[0-9]+$ ]]; then
            log_error "Параметр '$param' содержит невалидное значение: '$val' (ожидается целое число)"
            ok=0
        elif [[ "$_hpk" -eq 1 ]]; then
            # Число длиннее int64 bash молча заворачивает, и 20 цифр прошли бы
            # сравнения ниже как малое значение. Отсекаем до любой арифметики.
            val=$(_awg_dec_strip "$val")
            if (( ${#val} > 10 )) || (( val > 4294967295 )); then
                log_error "Параметр '$param': значение больше 4294967295"
                ok=0
            fi
        fi
    done

    # Протокольные границы (defense-in-depth для восстановленных бэкапов)
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
            log_error "Jc=$jc вне допустимого диапазона (1-128)"
            ok=0
        fi
    fi
    if [[ "$jmin" =~ ^[0-9]+$ && "$jmax" =~ ^[0-9]+$ ]]; then
        if [[ "$jmin" -gt 1280 ]]; then
            log_error "Jmin=$jmin превышает 1280"
            ok=0
        fi
        if [[ "$jmax" -gt 1280 ]]; then
            log_error "Jmax=$jmax превышает 1280"
            ok=0
        fi
        if [[ "$jmax" -lt "$jmin" ]]; then
            log_error "Jmax ($jmax) меньше Jmin ($jmin)"
            ok=0
        fi
    fi
    if [[ "$s3" =~ ^[0-9]+$ && "$s3" -gt 64 ]]; then
        log_error "S3=$s3 превышает максимум (64)"
        ok=0
    fi
    if [[ "$s4" =~ ^[0-9]+$ && "$s4" -gt 32 ]]; then
        log_error "S4=$s4 превышает максимум (32)"
        ok=0
    fi

    if [[ "$_hpk" -eq 1 ]]; then
    # При ключе первые 12 байт S-паддинга служат nonce, и модуль ядра
    # (netlink.c), и amneziawg-go (uapi.go) отвергают S ниже 12. Наличие и форму
    # проверил цикл выше по тому же разбору, числа больше uint32 он уже отверг;
    # ведущие нули не прячут малое число.
        local _sn _sv
        for _sn in s1 s2 s3 s4; do
            _sv="${_if_last[$_sn]:-}"
            [[ "$_sv" =~ ^[0-9]+$ ]] || continue
            _sv=$(_awg_dec_strip "$_sv")
            if (( ${#_sv} <= 10 )) && (( _sv < 12 )); then
                log_error "${_sn^^}=${_if_last[$_sn]} меньше 12: при HeaderProtectionKey первые 12 байт S-паддинга служат nonce, и модуль ядра, и amneziawg-go такой конфиг отвергают"
                ok=0
            fi
        done
    fi

    local _h_ranges=()
    for param in "${range_params[@]}"; do
        # При ключе H берём из того же разбора. Без ключа наш профиль требует
        # диапазонов (защита от отпечатка по H); при ключе заголовок закрыт и
        # одно число ничего не раскрывает, поэтому его допускаем. Протокол одно
        # число принимает в обоих случаях. Без ключа путь прежний.
        if [[ "$_hpk" -eq 1 ]]; then
            val="${_if_last[${param,,}]:-}"
        else
            val=$(sed -n "s/^[[:space:]]*${param}[[:space:]]*=[[:space:]]*//p" "$SERVER_CONF_FILE" | tail -1 | sed 's/#.*//' | tr -d '[:space:]')
        fi
        if [[ -z "$val" ]]; then
            log_error "Параметр '$param' не найден в серверном конфиге"
            ok=0
        elif [[ "$_hpk" -eq 1 && "$val" =~ ^[0-9]+$ ]]; then
            # Числа H читаем в десятичной системе, как tools (strtoul, основание
            # 10): без снятия нулей 010 было бы восьмеричным 8, а 08 - ошибкой,
            # после которой пара молча не сравнивается. Длину значащих цифр
            # проверяем ДО арифметики.
            val=$(_awg_dec_strip "$val")
            if (( ${#val} > 10 )) || (( val > 4294967295 )); then
                log_error "Параметр '$param': значение больше 4294967295"
                ok=0
            else
                _h_ranges+=("$val $val $param")
            fi
        elif ! [[ "$val" =~ ^[0-9]+-[0-9]+$ ]]; then
            log_error "Параметр '$param' содержит невалидное значение: '$val' (ожидается формат MIN-MAX)"
            ok=0
        else
            local range_lo range_hi
            range_lo=$(_awg_dec_strip "${val%-*}")
            range_hi=$(_awg_dec_strip "${val#*-}")
            # Границы тоже без ведущих нулей и с проверкой длины до арифметики.
            # Без ключа диапазон строго возрастающий, как и раньше; при ключе
            # допустимо и N-N, это тот же скаляр.
            if (( ${#range_lo} > 10 || ${#range_hi} > 10 )) || (( range_lo > 4294967295 || range_hi > 4294967295 )); then
                log_error "Параметр '$param': граница диапазона больше 4294967295"
                ok=0
            elif (( range_lo > range_hi )) || [[ "$_hpk" -ne 1 && "$range_lo" -eq "$range_hi" ]]; then
                log_error "Параметр '$param': нижняя граница ($range_lo) >= верхней ($range_hi)"
                ok=0
            else
                _h_ranges+=("$range_lo $range_hi $param")
            fi
        fi
    done

    # Попарное непересечение H1-H4 - ключевой инвариант AWG 2.0. Без этой
    # проверки конфиг из чужого бэкапа с пересекающимися диапазонами
    # проходил валидацию, хотя протокол его не допускает.
    if [[ ${#_h_ranges[@]} -eq 4 ]]; then
        local _i _j _lo1 _hi1 _n1 _lo2 _hi2 _n2
        for ((_i = 0; _i < 4; _i++)); do
            for ((_j = _i + 1; _j < 4; _j++)); do
                read -r _lo1 _hi1 _n1 <<< "${_h_ranges[$_i]}"
                read -r _lo2 _hi2 _n2 <<< "${_h_ranges[$_j]}"
                if (( _lo1 <= _hi2 && _lo2 <= _hi1 )); then
                    log_error "Диапазоны ${_n1} (${_lo1}-${_hi1}) и ${_n2} (${_lo2}-${_hi2}) пересекаются"
                    ok=0
                fi
            done
        done
    fi

    # I1-I5: те же опасные длины, что отвергает load_awg_params. restore зовёт
    # валидатор ДО старта сервиса и откатывается на отказе, поэтому именно здесь
    # опасный бэкап не доезжает до живого интерфейса.
    # 🔴 Смотрим КАЖДУЮ строку I1-I5 файла, в любом регистре и в любой секции, а
    # не значения загрузчика. Конфиг применяет не загрузчик, а amneziawg-tools:
    # они сравнивают ключ и заголовок секции без учёта регистра, так что `i1 = `
    # и `I1` под вторым заголовком `[interface]` уходят в устройство, а загрузчик
    # их не видит. Надмножество не может спрятать настоящее значение; лишний
    # отказ возможен только на строке из [Peer], а её tools отвергают сами.
    local _cps_line _cps_key _cps_why
    while IFS= read -r _cps_line || [[ -n "$_cps_line" ]]; do
        [[ "$_cps_line" =~ ^[[:space:]]*([Ii][1-5])[[:space:]]*=(.*)$ ]] || continue
        _cps_key="${BASH_REMATCH[1]}"
        if ! _cps_why=$(awg_cps_check_safe "${BASH_REMATCH[2]}"); then
            log_error "Параметр '$_cps_key' небезопасен: ${_cps_why} (апстрим amneziawg-linux-kernel-module#233)"
            ok=0
        fi
    done < "$SERVER_CONF_FILE"

    # I1 опционален. Отсутствие = либо не задан, либо намеренно отключён через
    # --no-cps (issue #159): десктопный AmneziaVPN на macOS не поддерживает CPS.
    if ! grep -qE '^[[:space:]]*I1[[:space:]]*=' "$SERVER_CONF_FILE"; then
        if grep -qE '^[[:space:]]*(export[[:space:]]+)?NO_CPS=1' "$CONFIG_FILE" 2>/dev/null; then
            log "I1 (CPS) отключён намеренно (--no-cps) - ожидаемо для десктопного AmneziaVPN на macOS"
        else
            log_warn "Параметр I1 (CPS) не найден - CPS concealment не активен"
        fi
    fi

    if [[ $ok -eq 1 ]]; then
        log "Валидация AWG 2.0 конфига: OK"
        return 0
    else
        return 1
    fi
}

# ==============================================================================
# Срок действия клиентов (expiry)
# ==============================================================================

EXPIRY_DIR="${AWG_DIR}/expiry"
EXPIRY_CRON="${EXPIRY_CRON:-/etc/cron.d/awg-expiry}"

# Парсинг длительности в секунды: 1h, 12h, 1d, 7d, 30d
# parse_duration <duration_string>
parse_duration() {
    local input="$1"
    local num unit
    if [[ "$input" =~ ^([0-9]+)([hdw])$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"
    else
        log_error "Некорректный формат длительности: '$input'. Используйте: 1h, 12h, 1d, 7d, 4w"
        return 1
    fi
    case "$unit" in
        h) echo $((num * 3600)) ;;
        d) echo $((num * 86400)) ;;
        w) echo $((num * 604800)) ;; # 7 дней
        *) return 1 ;;
    esac
}

# Установка срока действия клиента
# set_client_expiry <name> <duration>
set_client_expiry() {
    local name="$1"
    local duration="$2"
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "Невалидное имя клиента: '$name'"
        return 1
    fi
    if ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE" 2>/dev/null; then
        log_error "Клиент '$name' не найден."
        return 1
    fi
    local seconds
    seconds=$(parse_duration "$duration") || return 1
    local now
    now=$(date +%s)
    local expires_at=$((now + seconds))

    mkdir -p "$EXPIRY_DIR" || {
        log_error "Ошибка создания $EXPIRY_DIR"
        return 1
    }
    echo "$expires_at" > "$EXPIRY_DIR/$name" || {
        log_error "Ошибка записи expiry для '$name'"
        return 1
    }
    chmod 600 "$EXPIRY_DIR/$name"
    local expires_date
    expires_date=$(date -d "@$expires_at" '+%F %T' 2>/dev/null || echo "$expires_at")
    log "Срок действия '$name': $expires_date ($duration)"
    return 0
}

# Получение срока действия клиента (unix timestamp или пустая строка)
# get_client_expiry <name>
get_client_expiry() {
    local name="$1"
    local efile="$EXPIRY_DIR/$name"
    if [[ -f "$efile" ]]; then
        cat "$efile"
    fi
}

# Форматирование оставшегося времени
# format_remaining <expires_at_timestamp>
format_remaining() {
    local expires_at="$1"
    local now
    now=$(date +%s)
    local diff=$((expires_at - now))
    if [[ $diff -le 0 ]]; then
        local ago=$(( (-diff) / 3600 ))
        if [[ $ago -ge 24 ]]; then
            echo "истёк $(( ago / 24 ))д назад"
        elif [[ $ago -ge 1 ]]; then
            echo "истёк ${ago}ч назад"
        else
            local ago_mins=$(( (-diff) / 60 ))
            if [[ $ago_mins -ge 1 ]]; then
                echo "истёк ${ago_mins}м назад"
            else
                echo "только что истёк"
            fi
        fi
        return 0
    fi
    local days=$((diff / 86400))
    local hours=$(( (diff % 86400) / 3600 ))
    if [[ $days -gt 0 ]]; then
        echo "${days}д ${hours}ч"
    else
        local mins=$(( (diff % 3600) / 60 ))
        echo "${hours}ч ${mins}м"
    fi
}

# Проверка и удаление истёкших клиентов
check_expired_clients() {
    if [[ ! -d "$EXPIRY_DIR" ]]; then return 0; fi

    local removed=0
    local efile
    for efile in "$EXPIRY_DIR"/*; do
        [[ -f "$efile" ]] || continue
        local name
        name=$(basename "$efile")
        # Валидация имени: тот же regex что validate_client_name в manage_amneziawg.sh.
        # Defense-in-depth — EXPIRY_DIR доступен только root, но защита от
        # случайно попавшего невалидного файла (или symlink attack если expiry_dir
        # когда-то станет shared) нужна перед использованием $name в путях
        # и передачей в remove_peer_from_server (self-audit).
        if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            log_warn "Пропуск невалидного expiry файла: '$name'"
            continue
        fi
        local expires_at
        # Код возврата ловим так же, как в list_clients: cat может отдать
        # разборные байты и при этом упасть (ошибка ввода-вывода, обрыв). Без
        # проверки статуса ЭТОТ читатель, единственный из трёх умеющий удалять,
        # принял бы решение по данным неудавшегося чтения.
        local _exp_rc=0
        expires_at=$(cat "$efile" 2>/dev/null) || _exp_rc=$?
        if [[ "$_exp_rc" -ne 0 ]]; then
            log_warn "Метка срока для '$name' не прочитана (код $_exp_rc) - клиента не трогаю."
            continue
        fi
        # Каноническая десятичная запись, не длиннее 15 знаков - та же форма,
        # что и в list_clients, и расходиться им нельзя. Прежняя ^[0-9]+$
        # принимала ведущий ноль, а сравнение ниже читает такое значение как
        # ВОСЬМЕРИЧНОЕ: метка 01750000000 превращалась в 262144000, то есть в
        # 1978 год, условие срабатывало и клиент удалялся молча по фальшивой
        # дате. Со значением, где есть 8 или 9, сравнение вместо этого падало с
        # 'value too great for base', давало ложь и клиент оставался - то есть
        # одна и та же поломка вела себя двумя разными способами. Ограничение
        # длины закрывает третий путь: значение за пределами разрядности bash
        # молча заворачивается в арифметике.
        if [[ -z "$expires_at" || ! "$expires_at" =~ ^(0|[1-9][0-9]*)$ || "${#expires_at}" -gt 15 ]]; then
            log_warn "Некорректные данные expiry для '$name': '$(head -c 50 "$efile" 2>/dev/null)'"
            continue
        fi

        local now
        now=$(date +%s)
        if [[ $now -ge $expires_at ]]; then
            log "Клиент '$name' истёк. Удаление..."
            if [[ -r "$SERVER_CONF_FILE" ]] && ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE"; then
                # Orphan-метка: peer уже удалён из конфига (вручную, через awg
                # или restore старого бэкапа). Без этой ветки cron каждые 5
                # минут вечно ретраил бы remove_peer_from_server и копил warn
                # в expiry.log, а артефакты клиента никогда не зачищались.
                # Гард [[ -r ]]: временно отсутствующий/нечитаемый конфиг
                # (mid-restore, сбой ФС) НЕ повод стирать артефакты клиента -
                # такой случай уходит в обычную ветку с warn и повтором позже.
                _remove_client_files "$name"
                remove_client_expiry "$name"
                log "Клиент '$name': peer отсутствует в конфиге - зачищены осиротевшие артефакты и expiry-метка."
            elif remove_peer_from_server "$name" 2>/dev/null; then
                _remove_client_files "$name"
                remove_client_expiry "$name"
                log "Клиент '$name' удалён (истёк)."
                ((removed++))
            else
                log_warn "Не удалось удалить истёкшего клиента '$name'."
            fi
        fi
    done

    if [[ $removed -gt 0 ]]; then
        log "Удалено истёкших клиентов: $removed. Применение конфигурации..."
        if ! apply_config; then
            log_error "apply_config упал после удаления истёкших клиентов. Peer-ы убраны из конфига и expiry/, но могут оставаться на live интерфейсе. Требуется ручной перезапуск: systemctl restart awg-quick@awg0"
            return 1
        fi
    fi
    return 0
}

# Установка cron-задачи для автоудаления
install_expiry_cron() {
    # Идемпотентность по СОДЕРЖИМОМУ, не по факту существования файла. Раньше
    # ранний выход «файл есть» оставлял stale-пути после restore/переноса/
    # --conf-dir: cron продолжал смотреть в старый AWG_DIR. Генерируем ожидаемый
    # текст и заменяем файл, только если он отличается.
    local _cron_tmp
    _cron_tmp=$(awg_mktemp "$(dirname "$EXPIRY_CRON")") || { log_error "Ошибка mktemp для cron expiry"; return 1; }
    # Проверяем успех записи ДО cmp/mv: иначе сбой (диск/права) мог бы атомарно
    # заменить рабочий cron пустым/частичным tmp.
    if ! cat > "$_cron_tmp" << CRONEOF
# AmneziaWG client expiry check - every 5 minutes
AWG_DIR="${AWG_DIR}"
CONFIG_FILE="${CONFIG_FILE}"
SERVER_CONF_FILE="${SERVER_CONF_FILE}"
*/5 * * * * root /bin/bash -c 'source "${AWG_DIR}/awg_common.sh" || exit 1; trap _awg_cleanup EXIT; check_expired_clients' >> "${AWG_DIR}/expiry.log" 2>&1
CRONEOF
    then
        rm -f "$_cron_tmp"
        log_error "Ошибка записи cron-задачи expiry"
        return 1
    fi
    if [[ -f "$EXPIRY_CRON" ]] && cmp -s "$_cron_tmp" "$EXPIRY_CRON"; then
        rm -f "$_cron_tmp"
        log_debug "Cron-задача expiry уже актуальна."
        return 0
    fi
    chmod 644 "$_cron_tmp"
    if ! mv -f "$_cron_tmp" "$EXPIRY_CRON"; then
        rm -f "$_cron_tmp"
        log_error "Ошибка установки cron-задачи expiry: $EXPIRY_CRON"
        return 1
    fi
    log "Cron-задача expiry установлена/обновлена: $EXPIRY_CRON"
}

# Удаление expiry-данных клиента
remove_client_expiry() {
    local name="$1"
    rm -f "$EXPIRY_DIR/$name" 2>/dev/null
    # Удаляем cron если больше нет клиентов с expiry
    if [[ -d "$EXPIRY_DIR" ]] && [[ -z "$(ls -A "$EXPIRY_DIR" 2>/dev/null)" ]]; then
        rm -f "$EXPIRY_CRON" 2>/dev/null
        log_debug "Cron-задача expiry удалена (нет клиентов с expiry)."
    fi
}
