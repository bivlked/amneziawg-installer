#!/bin/bash
# update-sha-pins.sh - синхронизация SHA256-пинов helper-скриптов в установщиках
#
# Установщики (install_amneziawg.sh / install_amneziawg_en.sh) скачивают
# awg_common*.sh и manage_amneziawg*.sh по сети и проверяют их sha256sum
# против захардкоженных пинов COMMON_SCRIPT_SHA256 / MANAGE_SCRIPT_SHA256.
# При каждом релизе эти 4 пина (2 RU + 2 EN) надо пересчитывать строго после
# финализации helper-скриптов, иначе secure-download откажет в установке.
#
# Использование:
#   bash scripts/update-sha-pins.sh            # пересчитать и записать 4 пина
#   bash scripts/update-sha-pins.sh --verify   # только проверить, exit!=0 при рассинхроне
#
# Карта пинов:
#   install_amneziawg.sh     COMMON  <- awg_common.sh
#   install_amneziawg.sh     MANAGE  <- manage_amneziawg.sh
#   install_amneziawg_en.sh  COMMON  <- awg_common_en.sh
#   install_amneziawg_en.sh  MANAGE  <- manage_amneziawg_en.sh
#
# Идемпотентно: повторный запуск без изменений helper-скриптов ничего не пишет.
# Запись атомарна (temp + mv). Меняется только 64-символьное hex-значение пина.

set -o pipefail

# Корень репозитория = родитель каталога этого скрипта.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERIFY_ONLY=0
if [[ "${1:-}" == "--verify" ]]; then
    VERIFY_ONLY=1
elif [[ -n "${1:-}" ]]; then
    echo "ОШИБКА: неизвестный аргумент '$1' (поддерживается только --verify)" >&2
    exit 2
fi

# Пары: installer | имя пина | helper-файл
# Порядок полей разделён через '|'.
PIN_MAP=(
    "install_amneziawg.sh|COMMON_SCRIPT_SHA256|awg_common.sh"
    "install_amneziawg.sh|MANAGE_SCRIPT_SHA256|manage_amneziawg.sh"
    "install_amneziawg_en.sh|COMMON_SCRIPT_SHA256|awg_common_en.sh"
    "install_amneziawg_en.sh|MANAGE_SCRIPT_SHA256|manage_amneziawg_en.sh"
)

# Вычислить sha256 файла (только hex, без имени).
_sha256() {
    sha256sum "$1" | cut -d' ' -f1
}

# Прочитать текущий пин из установщика (первое совпадение).
_read_pin() {
    local installer="$1" pin_name="$2"
    grep -oP "${pin_name}=\"\\K[0-9a-f]{64}" "$REPO_ROOT/$installer" | head -n1
}

# Записать новый пин в установщик атомарно. Меняется только hex-значение
# у строки, начинающейся с <pin_name>="...". Возвращает 0 при записи.
_write_pin() {
    local installer="$1" pin_name="$2" new_hash="$3"
    local src="$REPO_ROOT/$installer"
    local tmp
    tmp="$(mktemp "${src}.XXXXXX")" || return 1
    # Заменяем только значение в кавычках для конкретного пина.
    sed -E "s|^(${pin_name}=\")[0-9a-f]{64}(\")|\\1${new_hash}\\2|" "$src" > "$tmp" || { rm -f "$tmp"; return 1; }
    # mktemp создаёт файл 0600: без выравнивания прав mv молча заменил бы
    # installer на 0600 (git mode не меняется, diff-сигнала нет).
    chmod --reference="$src" "$tmp" 2>/dev/null || chmod 644 "$tmp"
    mv "$tmp" "$src" || { rm -f "$tmp"; return 1; }
    return 0
}

rc=0
mismatched=()

for entry in "${PIN_MAP[@]}"; do
    IFS='|' read -r installer pin_name helper <<< "$entry"

    if [[ ! -f "$REPO_ROOT/$helper" ]]; then
        echo "ОШИБКА: helper-файл не найден: $helper" >&2
        rc=1
        continue
    fi
    if [[ ! -f "$REPO_ROOT/$installer" ]]; then
        echo "ОШИБКА: установщик не найден: $installer" >&2
        rc=1
        continue
    fi

    actual="$(_sha256 "$REPO_ROOT/$helper")"
    pinned="$(_read_pin "$installer" "$pin_name")"

    if [[ -z "$actual" || ${#actual} -ne 64 ]]; then
        echo "ОШИБКА: не удалось вычислить sha256 для $helper" >&2
        rc=1
        continue
    fi
    if [[ -z "$pinned" ]]; then
        echo "ОШИБКА: пин $pin_name не найден в $installer" >&2
        rc=1
        continue
    fi

    if [[ "$actual" == "$pinned" ]]; then
        echo "OK:    $installer $pin_name = $actual ($helper)"
        continue
    fi

    if [[ "$VERIFY_ONLY" -eq 1 ]]; then
        echo "MISMATCH: $installer $pin_name" >&2
        echo "          pinned: $pinned" >&2
        echo "          actual: $actual ($helper)" >&2
        mismatched+=("$installer:$pin_name")
        rc=1
    else
        if _write_pin "$installer" "$pin_name" "$actual"; then
            echo "UPDATE: $installer $pin_name -> $actual ($helper)"
        else
            echo "ОШИБКА: не удалось записать пин $pin_name в $installer" >&2
            rc=1
        fi
    fi
done

if [[ "$VERIFY_ONLY" -eq 1 && ${#mismatched[@]} -gt 0 ]]; then
    echo "" >&2
    echo "Рассинхрон SHA-пинов (${#mismatched[@]}): ${mismatched[*]}" >&2
    echo "Запустите без --verify для исправления: bash scripts/update-sha-pins.sh" >&2
fi

exit "$rc"
