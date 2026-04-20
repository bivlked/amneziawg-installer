#!/usr/bin/env bats
# Regression guard (added in v5.10.2 hotfix).
#
# v5.10.1 поставил apt_update_tolerant() только в awg_common.sh, но вызывал её
# в install_amneziawg.sh на шагах 1-2, ДО того как awg_common.sh скачивается
# (step 5). Результат: `apt_update_tolerant: command not found` на любой
# чистой установке, установка падала в step 1.
#
# Этот тест фиксирует инвариант:
#   • apt_update_tolerant() определена inline в install_amneziawg.sh (RU + EN).
#   • awg_common.sh / awg_common_en.sh НЕ содержат определения (только
#     комментарий-ссылка).
#
# Если кто-то снова попытается перенести функцию в awg_common — тест сломается
# и напомнит о регрессии.

@test "install_amneziawg.sh defines apt_update_tolerant() inline" {
    local f="${BATS_TEST_DIRNAME}/../install_amneziawg.sh"
    run grep -c '^apt_update_tolerant() {$' "$f"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
}

@test "install_amneziawg_en.sh defines apt_update_tolerant() inline" {
    local f="${BATS_TEST_DIRNAME}/../install_amneziawg_en.sh"
    run grep -c '^apt_update_tolerant() {$' "$f"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
}

@test "awg_common.sh does NOT define apt_update_tolerant() (only comment)" {
    local f="${BATS_TEST_DIRNAME}/../awg_common.sh"
    run grep -c '^apt_update_tolerant() {$' "$f"
    # grep returns 1 on zero matches — we want zero matches, so status=1.
    [ "$status" -eq 1 ]
    [ "$output" -eq 0 ]
}

@test "awg_common_en.sh does NOT define apt_update_tolerant() (only comment)" {
    local f="${BATS_TEST_DIRNAME}/../awg_common_en.sh"
    run grep -c '^apt_update_tolerant() {$' "$f"
    [ "$status" -eq 1 ]
    [ "$output" -eq 0 ]
}

# Все вызовы apt_update_tolerant в install.sh должны происходить ПОСЛЕ
# определения функции (строка ~135 в v5.10.2).
@test "install_amneziawg.sh: all apt_update_tolerant calls follow the definition" {
    local f="${BATS_TEST_DIRNAME}/../install_amneziawg.sh"
    local def_line
    def_line=$(grep -n '^apt_update_tolerant() {$' "$f" | head -1 | cut -d: -f1)
    [ -n "$def_line" ]

    # Все вызовы (не-определения) — строки, которые содержат apt_update_tolerant
    # но не начинаются с "apt_update_tolerant() {"
    local bad_calls
    bad_calls=$(grep -n 'apt_update_tolerant' "$f" \
        | grep -v '^[0-9]*:apt_update_tolerant() {$' \
        | grep -v '^[0-9]*:#' \
        | awk -F: -v d="$def_line" '$1 < d { print }' || true)

    if [ -n "$bad_calls" ]; then
        echo "Calls to apt_update_tolerant BEFORE its definition (line $def_line):" >&2
        echo "$bad_calls" >&2
        return 1
    fi
}

@test "install_amneziawg_en.sh: all apt_update_tolerant calls follow the definition" {
    local f="${BATS_TEST_DIRNAME}/../install_amneziawg_en.sh"
    local def_line
    def_line=$(grep -n '^apt_update_tolerant() {$' "$f" | head -1 | cut -d: -f1)
    [ -n "$def_line" ]

    local bad_calls
    bad_calls=$(grep -n 'apt_update_tolerant' "$f" \
        | grep -v '^[0-9]*:apt_update_tolerant() {$' \
        | grep -v '^[0-9]*:#' \
        | awk -F: -v d="$def_line" '$1 < d { print }' || true)

    if [ -n "$bad_calls" ]; then
        echo "Calls to apt_update_tolerant BEFORE its definition (line $def_line):" >&2
        echo "$bad_calls" >&2
        return 1
    fi
}
