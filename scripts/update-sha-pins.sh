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

# Откуда установщик РЕАЛЬНО скачает помощника: он берёт его с
# raw.githubusercontent.com/<repo>/${AWG_BRANCH}/<helper>, где AWG_BRANCH по
# умолчанию равен v$SCRIPT_VERSION. Значит эталон для пина - байты помощника
# НА ТЕГЕ, и только пока тега нет (релиз готовится, тег пушится последним)
# эталоном служит рабочее дерево.
#
# ВАЖНО, ЧЕГО ЭТА ЛОГИКА НЕ УМЕЕТ: локальный набор тегов принимается за истину.
# Чекаут, в котором тег v$SCRIPT_VERSION просто не выкачан (shallow, --no-tags,
# форк, сделанный до тега) либо устарел после git tag -f, неотличим здесь от
# честного "релиз готовится". Поэтому переход на дерево ОБЪЯВЛЯЕТСЯ вслух, а
# перед выпуском полагается git fetch --tags --force (docs/RELEASE_PROCESS.md).
_tag_of_installer() {
    local ver
    ver="$(grep -oP '^SCRIPT_VERSION="\K[0-9.]+' "$REPO_ROOT/$1" | head -n1)"
    [[ -n "$ver" ]] || return 1
    printf 'v%s' "$ver"
}

# sha содержимого пути НА ТЕГЕ. Через временный файл, а не через $(...):
# подстановка срезала бы завершающие переводы строк и изменила хеш, а
# конвейер "git show | sha256sum" на пустом выводе честно посчитал бы хеш
# ПУСТОГО ВВОДА - 64 валидных hex-символа, которые прошли бы любую проверку
# длины и выглядели бы как настоящий эталон.
_sha256_at_tag() {
    local tag="$1" path="$2" tmp out
    tmp="$(mktemp)" || return 1
    if ! git -C "$REPO_ROOT" show "refs/tags/$tag:$path" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    out="$(_sha256 "$tmp")"
    rm -f "$tmp"
    [[ "$out" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "$out"
}

# Печатает "<sha> <источник>", где источник - "tag vX.Y.Z" либо "worktree".
# При невозможности определить не печатает В STDOUT ничего и возвращает !=0.
# Вызывающий ОБЯЗАН проверять этот код возврата отдельным присваиванием:
# "read ... <<< $(...)" его не увидит, потому что here-string всегда даёт
# перевод строки и read возвращает 0 даже на пустом выводе.
_expected_sha() {
    local installer="$1" helper="$2" tag sha
    if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        echo "ОШИБКА: не git-чекаут, эталон для пина определить нечем" >&2
        return 1
    fi
    if [[ -z "$(git -C "$REPO_ROOT" tag --list | head -n1)" ]]; then
        echo "ОШИБКА: в чекауте нет ни одного тега (склонируйте с тегами)" >&2
        return 1
    fi
    tag="$(_tag_of_installer "$installer")" || {
        echo "ОШИБКА: не удалось прочитать SCRIPT_VERSION из $installer" >&2
        return 1
    }
    if git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1; then
        if ! sha="$(_sha256_at_tag "$tag" "$helper")"; then
            # Причину не называем: сюда приводит и отсутствие файла на теге, и
            # повреждённый объект, и недокачанный shallow-чекаут.
            echo "ОШИБКА: не удалось прочитать $tag:$helper" >&2
            return 1
        fi
        printf '%s tag %s' "$sha" "$tag"
        return 0
    fi
    printf '%s worktree' "$(_sha256 "$REPO_ROOT/$helper")"
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
    # Записанное ПЕРЕЧИТЫВАЕТСЯ. Успех sed не означает замену: при нуле замен он
    # тоже возвращает 0, и тогда скрипт печатал бы "UPDATE: <желаемый sha>",
    # то есть отчитывался бы о работе, которой не было, показывая при этом
    # значение, которого в файле нет. Достижимо, например, если присваивание
    # перестанет стоять в первой колонке: _read_pin ищет пин где угодно в
    # строке, а замена заякорена на ^.
    if [[ "$(_read_pin "$installer" "$pin_name")" != "$new_hash" ]]; then
        echo "ОШИБКА: запись пина $pin_name в $installer не состоялась" >&2
        echo "        (замена не применилась: проверьте, что строка начинается с ${pin_name}=)" >&2
        return 1
    fi
    return 0
}

rc=0
mismatched=()
worktree_notice_shown=0
actual_src=""
expected_line=""

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

    if ! expected_line="$(_expected_sha "$installer" "$helper")"; then
        rc=1
        continue
    fi
    read -r actual actual_src <<< "$expected_line"

    # Замечание печатает вызывающий, а не _expected_sha: та исполняется внутри
    # $( ), то есть в подоболочке, и любой флаг "уже показано" там умирает
    # вместе с ней - предупреждение печаталось бы на каждый из четырёх пинов.
    if [[ "$actual_src" == "worktree" && "$worktree_notice_shown" -eq 0 ]]; then
        worktree_notice_shown=1
        echo "ЗАМЕЧАНИЕ: тега $(_tag_of_installer "$installer") в этом чекауте нет:" >&2
        echo "           считаю, что релиз готовится, и сверяю с рабочим деревом." >&2
        echo "           Если тег уже опубликован - git fetch --tags --force и повторить." >&2
    fi
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
        echo "OK:    $installer $pin_name = $actual ($helper, $actual_src)"
        continue
    fi

    if [[ "$VERIFY_ONLY" -eq 1 ]]; then
        echo "MISMATCH: $installer $pin_name" >&2
        echo "          pinned: $pinned" >&2
        echo "          ожидалось: $actual ($helper, источник: $actual_src)" >&2
        mismatched+=("$installer:$pin_name")
        rc=1
    else
        # Записывается ЭТАЛОН, а не хеш дерева: при существующем теге это
        # байты с тега, то есть ровно то, что установщик примет. Прежняя
        # редакция здесь отказывалась писать и тем блокировала единственную
        # верную починку разъехавшегося пина.
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
