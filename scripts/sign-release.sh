#!/usr/bin/env bash
#
# Подписать релизные файлы для тега.
#
#   bash scripts/sign-release.sh v5.29.0
#
# Зачем скрипт, если в docs/RELEASE_PROCESS.md есть цикл из четырёх строк:
#
#   1. Доверенный комментарий подписи обязан быть в точности
#      "amneziawg-installer <TAG> <файл>". Опечатка в нём даёт подпись, которая
#      проверяется криптографически, но отвергается verify-signatures.sh, и
#      обнаруживается это уже после пуша тега.
#   2. Ключ защищён паролем, minisign спрашивает его на КАЖДЫЙ файл. Здесь он
#      спрашивается один раз и передаётся шести вызовам.
#   3. 🔴 Отсутствие терминала. Ручной цикл с `read -rsp`, запущенный там, где
#      stdin не терминал, обрывается на самом `read`: подписи не создаются,
#      сообщения об ошибке нет, а следующая команда цепочки выполняется как ни
#      в чём не бывало. Именно это и произошло 30 aug 2026. Здесь отсутствие
#      терминала - явный отказ с объяснением, а не тишина.
#
# Пароль нигде не сохраняется: он живёт в переменной оболочки этого процесса.
# Приватный ключ не покидает машину и в GitHub Actions не попадает никогда.

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TAG="${1:-}"
if [[ -z "$TAG" ]]; then
    echo "usage: bash scripts/sign-release.sh vX.Y.Z" >&2
    exit 2
fi
# Формат проверяется до чтения пароля: ошибиться в теге легко, а обнаружилась
# бы ошибка только на проверке подписей, после шести подписаний.
if ! [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
    echo "ОШИБКА: тег '$TAG' не похож на vX.Y.Z или vX.Y.Z-suffix" >&2
    exit 2
fi

KEY="${MINISIGN_KEY:-$HOME/.minisign/amneziawg-installer.key}"
if [[ ! -f "$KEY" ]]; then
    echo "ОШИБКА: приватный ключ не найден: $KEY" >&2
    echo "        путь можно задать переменной MINISIGN_KEY" >&2
    exit 2
fi
if ! command -v minisign >/dev/null 2>&1; then
    echo "ОШИБКА: minisign не найден в PATH" >&2
    exit 2
fi

cd "$REPO_ROOT" || exit 2

# Список читается в переменную с проверкой статуса: через `done < <(...)`
# провал построения списка невидим для set -e, цикл просто не выполнится ни
# разу, и скрипт отчитается об успехе, не подписав ничего.
if ! files="$(bash "$SCRIPT_DIR/signed-file-list.sh")"; then
    echo "ОШИБКА: не удалось получить список подписываемых файлов" >&2
    exit 1
fi
if [[ -z "${files//[[:space:]]/}" ]]; then
    echo "ОШИБКА: список подписываемых файлов пуст" >&2
    exit 1
fi

if [[ ! -t 0 ]]; then
    echo "ОШИБКА: нет терминала для ввода пароля." >&2
    echo "        Запустите скрипт из окна терминала, а не через конвейер," >&2
    echo "        не в фоне и не из среды без stdin." >&2
    exit 2
fi

mkdir -p signing

read -rsp "Пароль от ключа minisign: " PASSWORD
echo
if [[ -z "$PASSWORD" ]]; then
    echo "ОШИБКА: пустой пароль" >&2
    exit 2
fi

signed=0
failed=0
while read -r f; do
    [[ -n "$f" ]] || continue
    if [[ ! -f "$f" ]]; then
        echo "  ОШИБКА: нет файла $f" >&2
        failed=$((failed + 1))
        continue
    fi
    if printf '%s\n' "$PASSWORD" | minisign -Sm "$f" -s "$KEY" \
            -x "signing/${f}.minisig" \
            -t "amneziawg-installer ${TAG} ${f}" >/dev/null 2>&1; then
        echo "  подписан  $f"
        signed=$((signed + 1))
    else
        echo "  ОШИБКА подписи: $f" >&2
        failed=$((failed + 1))
    fi
done <<< "$files"
unset PASSWORD

echo "подписано $signed, ошибок $failed"
if [[ "$failed" -ne 0 ]]; then
    echo "ОТКАЗ: подписаны не все файлы" >&2
    exit 1
fi

# Своя же работа проверяется чужой проверкой - той самой, которую выполнит
# release.yml. Иначе "подписано 6" означало бы лишь то, что minisign не упал.
echo
bash "$SCRIPT_DIR/verify-signatures.sh" "$TAG"
