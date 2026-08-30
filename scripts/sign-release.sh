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

# Ключ ищется по нескольким путям, а не по одному $HOME. На Windows значение
# HOME зависит от того, откуда запущен bash: из Git Bash это обычно профиль
# пользователя, а из PowerShell или cmd - выдуманный /home/<имя>, которого на
# диске нет. Один путь давал бы отказ "ключ не найден" там, где ключ на месте.
# Путь вида C:\Users\biv переводится в /c/Users/biv СВОИМИ силами, без cygpath.
# Запущенный из PowerShell или cmd bash наследует PATH Windows, а cygpath из
# состава Git лежит в его собственном usr/bin и туда обычно не входит. Зависеть
# от него значит потерять запасной путь ровно в той среде, ради которой он и
# добавлен.
_win_to_posix() {
    # Замена через tr, а не через ${x//\\//}: замерено на bash 5 в Git Bash,
    # что подстановка возвращает строку НЕТРОНУТОЙ. Ошибка при этом молчаливая
    # и почти безвредная на вид, потому что MSYS соглашается открыть смешанный
    # путь C:\Users\biv/.minisign/..., то есть проверка -f проходит и дефект
    # прячется до первой среды, которая такой путь не примет. \134 - восьмеричный
    # код обратного слеша: так tr не спорит о том, что считать экранированием.
    local u drive rest
    u="$(printf '%s' "$1" | tr '\134' '/')"
    case "$u" in
        [A-Za-z]:/*)
            drive="${u%%:*}"
            rest="${u#*:}"
            printf '/%s%s' "$(printf '%s' "$drive" | tr 'A-Z' 'a-z')" "$rest"
            ;;
        *) printf '%s' "$u" ;;
    esac
}

KEY="${MINISIGN_KEY:-}"
_candidates=()
if [[ -z "$KEY" ]]; then
    _candidates+=("$HOME/.minisign/amneziawg-installer.key")
    for _base in "${USERPROFILE:-}" "${HOMEDRIVE:-}${HOMEPATH:-}"; do
        [[ -n "$_base" ]] || continue
        _candidates+=("$(_win_to_posix "$_base")/.minisign/amneziawg-installer.key")
    done
    for _c in "${_candidates[@]}"; do
        if [[ -f "$_c" ]]; then KEY="$_c"; break; fi
    done
fi
if [[ -z "$KEY" || ! -f "$KEY" ]]; then
    echo "ОШИБКА: приватный ключ не найден." >&2
    for _c in "${_candidates[@]:-$KEY}"; do echo "        искал: $_c" >&2; done
    echo "        Путь можно задать переменной MINISIGN_KEY." >&2
    # 🔴 На Windows команда `bash` из PowerShell или cmd - это чаще всего НЕ Git
    # Bash, а пусковой файл WSL (C:\Windows\System32\bash.exe). Он не наследует
    # окружение Windows вообще: пусты и USERPROFILE, и HOMEDRIVE, и даже
    # MINISIGN_KEY, заданная строкой выше в той же командной строке. Симптом при
    # этом выглядит как дефект скрипта, а не как выбор не той оболочки, поэтому
    # называем причину прямо.
    if [[ -r /proc/version ]] && grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
        echo "" >&2
        echo "        Похоже, это WSL, а не Git Bash: команда 'bash' в PowerShell" >&2
        echo "        обычно запускает C:\\Windows\\System32\\bash.exe. Окружение" >&2
        echo "        Windows туда не передаётся, поэтому и MINISIGN_KEY не видна." >&2
        echo "        Запустите через Git Bash:" >&2
        echo "          & \"C:\\Program Files\\Git\\bin\\bash.exe\" scripts/sign-release.sh $TAG" >&2
    fi
    exit 2
fi
echo "ключ: $KEY"
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
    # Диагностика minisign сохраняется и печатается ПРИ ОТКАЗЕ. Отправлять её
    # в /dev/null безусловно значит превращать "неверный пароль", "нет места"
    # и "ключ повреждён" в одно безликое "ОШИБКА подписи".
    if err="$(printf '%s\n' "$PASSWORD" | minisign -Sm "$f" -s "$KEY" \
            -x "signing/${f}.minisig" \
            -t "amneziawg-installer ${TAG} ${f}" 2>&1 >/dev/null)"; then
        echo "  подписан  $f"
        signed=$((signed + 1))
    else
        echo "  ОШИБКА подписи: $f" >&2
        # Строка "Password:" - это приглашение, а не диагноз; остальное полезно.
        printf '%s\n' "$err" | grep -v '^Password:' | sed 's/^/      /' >&2
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
