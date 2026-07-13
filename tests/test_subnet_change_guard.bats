#!/usr/bin/env bats
# v5.19: guard_subnet_change_with_peers - запрет смены подсети туннеля при
# существующих [Peer] в awg0.conf (ответ на ревью PR #167). Harness как в
# test_cidr_subnet_validation.bats: extract + eval с заглушками die/log.

ROOT="$BATS_TEST_DIRNAME/.."

setup() {
    die()       { echo "DIE: $*"; exit 1; }
    log()       { :; }
    log_warn()  { echo "WARN: $*"; }
    log_error() { :; }
    # shellcheck disable=SC2034  # используется внутри eval-извлечённого guard (die-сообщение)
    MANAGE_SCRIPT_PATH="/root/awg/manage_amneziawg.sh"
    eval "$(awk '/^validate_port\(\) \{/{f=1} f{print} /^configure_routing_mode\(\) \{/{exit}' \
        "$ROOT/install_amneziawg.sh" | sed '/^configure_routing_mode/d')"
    SERVER_CONF_FILE="$BATS_TEST_TMPDIR/awg0.conf"
}

# Собрать awg0.conf: $1 - значение Address (пусто = без строки Address),
# $2 - 1 чтобы добавить [Peer]-блок.
mk_conf() {
    local address="$1" with_peers="$2"
    {
        echo "[Interface]"
        if [[ -n "$address" ]]; then echo "Address = $address"; fi
        echo "ListenPort = 39743"
        echo "PrivateKey = xxx"
        if [[ "$with_peers" == "1" ]]; then
            echo ""
            echo "[Peer]"
            echo "#_Name = my_phone"
            echo "PublicKey = yyy"
            echo "AllowedIPs = 10.9.9.2/32"
        fi
    } > "$SERVER_CONF_FILE"
}

@test "guard: no awg0.conf -> ok" {
    AWG_TUNNEL_SUBNET="10.9.0.1/16"
    run guard_subnet_change_with_peers
    [ "$status" -eq 0 ]
}

@test "guard: config without peers + subnet change -> ok" {
    mk_conf "10.9.9.1/24" 0
    AWG_TUNNEL_SUBNET="10.9.0.1/16"
    run guard_subnet_change_with_peers
    [ "$status" -eq 0 ]
}

@test "guard: peers + same subnet -> ok" {
    mk_conf "10.9.9.1/24" 1
    AWG_TUNNEL_SUBNET="10.9.9.1/24"
    run guard_subnet_change_with_peers
    [ "$status" -eq 0 ]
}

@test "guard: peers + subnet change -> die" {
    mk_conf "10.9.9.1/24" 1
    AWG_TUNNEL_SUBNET="10.9.0.1/16"
    run guard_subnet_change_with_peers
    [ "$status" -ne 0 ]
    [[ "$output" == *"DIE:"* ]]
    [[ "$output" == *"10.9.9.1/24"* ]]
    [[ "$output" == *"10.9.0.1/16"* ]]
}

@test "guard: network form normalized by validate_subnet before compare -> ok" {
    mk_conf "10.9.9.1/24" 1
    AWG_TUNNEL_SUBNET="10.9.9.0/24"
    validate_subnet "$AWG_TUNNEL_SUBNET"
    run guard_subnet_change_with_peers
    [ "$status" -eq 0 ]
}

@test "guard: Address with IPv6 tail after comma - IPv4 element picked" {
    mk_conf "10.9.9.1/24, fddd:2c4:2c4:2c4::1/64" 1
    AWG_TUNNEL_SUBNET="10.9.9.1/24"
    run guard_subnet_change_with_peers
    [ "$status" -eq 0 ]
    AWG_TUNNEL_SUBNET="10.9.0.1/16"
    run guard_subnet_change_with_peers
    [ "$status" -ne 0 ]
}

# v5.19.1: dual-stack Address в ЛЮБОМ порядке - guard выбирает именно IPv4-CIDR,
# а не первый comma-элемент (IPv6-первый Address раньше давал ложную "смену").
@test "guard: Address with IPv6 FIRST - IPv4 element still picked" {
    mk_conf "fddd:2c4:2c4:2c4::1/64, 10.9.9.1/24" 1
    AWG_TUNNEL_SUBNET="10.9.9.1/24"
    run guard_subnet_change_with_peers
    [ "$status" -eq 0 ]
    AWG_TUNNEL_SUBNET="10.9.0.1/16"
    run guard_subnet_change_with_peers
    [ "$status" -ne 0 ]
    [[ "$output" == *"DIE:"* ]]
}

# Fail-closed (ревью v5.19.0): пиры есть, а старую подсеть определить нельзя -
# молчаливое продолжение перерендерило бы конфиг в новой подсети и сломало
# клиентов, поэтому guard прерывает установку, а не пропускает проверку.
@test "guard: peers but no Address line -> die (fail-closed)" {
    mk_conf "" 1
    AWG_TUNNEL_SUBNET="10.9.0.1/16"
    run guard_subnet_change_with_peers
    [ "$status" -ne 0 ]
    [[ "$output" == *"DIE:"* ]]
    [[ "$output" == *"Address"* ]]
}

# --- edge cases: без пробелов вокруг "=" и CRLF-концы строк ---
# Пин для sed 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*//p' и
# последующего tr -d '[:space:]': оба должны корректно есть "Address=..."
# без пробелов и \r в конце строки (CRLF-конфиг).

@test "guard: Address without spaces around '=' + peers + same subnet -> ok" {
    {
        echo "[Interface]"
        echo "Address=10.9.9.1/24"
        echo "ListenPort = 39743"
        echo "PrivateKey = xxx"
        echo ""
        echo "[Peer]"
        echo "#_Name = my_phone"
        echo "PublicKey = yyy"
        echo "AllowedIPs = 10.9.9.2/32"
    } > "$SERVER_CONF_FILE"
    AWG_TUNNEL_SUBNET="10.9.9.1/24"
    run guard_subnet_change_with_peers
    [ "$status" -eq 0 ]
}

@test "guard: CRLF config + peers + same subnet -> ok" {
    {
        echo "[Interface]"
        echo "Address = 10.9.9.1/24"
        echo "ListenPort = 39743"
        echo "PrivateKey = xxx"
        echo ""
        echo "[Peer]"
        echo "#_Name = my_phone"
        echo "PublicKey = yyy"
        echo "AllowedIPs = 10.9.9.2/32"
    } | sed 's/$/\r/' > "$SERVER_CONF_FILE"
    AWG_TUNNEL_SUBNET="10.9.9.1/24"
    run guard_subnet_change_with_peers
    [ "$status" -eq 0 ]
}

@test "guard: CRLF config + peers + subnet change -> die" {
    {
        echo "[Interface]"
        echo "Address = 10.9.9.1/24"
        echo "ListenPort = 39743"
        echo "PrivateKey = xxx"
        echo ""
        echo "[Peer]"
        echo "#_Name = my_phone"
        echo "PublicKey = yyy"
        echo "AllowedIPs = 10.9.9.2/32"
    } | sed 's/$/\r/' > "$SERVER_CONF_FILE"
    AWG_TUNNEL_SUBNET="10.9.0.1/16"
    run guard_subnet_change_with_peers
    [ "$status" -ne 0 ]
    [[ "$output" == *"DIE:"* ]]
}

# --- RU/EN parity (тело функции идентично без учёта комментариев и
# локализованных сообщений log_warn/die) ---

@test "guard: RU/EN guard_subnet_change_with_peers bodies identical modulo comments and messages" {
    local ru en
    ru=$(awk '/^guard_subnet_change_with_peers\(\) \{$/,/^}$/' "$ROOT/install_amneziawg.sh" \
        | grep -v '^[[:space:]]*#' \
        | grep -v 'log_warn "' \
        | grep -v 'die "')
    en=$(awk '/^guard_subnet_change_with_peers\(\) \{$/,/^}$/' "$ROOT/install_amneziawg_en.sh" \
        | grep -v '^[[:space:]]*#' \
        | grep -v 'log_warn "' \
        | grep -v 'die "')
    [ -n "$ru" ]
    [ "$ru" = "$en" ]
}
