#!/bin/bash
# check-docs-consistency.sh - быстрые проверки согласованности документации
#
# Лёгкий аналог preflight для документации и метаданных: ничего не собирает,
# не качает по сети, не гоняет bats. Только дешёвые детерминированные проверки,
# которые ловят классы рассинхрона, проскакивающие мимо shellcheck/test
# (битые внутренние ссылки, рассогласование версий, протухшая матрица ОС).
#
# Запускается локально и в CI (docs-check workflow), а также включён в
# preflight-check.sh как один из шагов.
#
# Использование:
#   bash scripts/check-docs-consistency.sh
#
# Проверки:
#   1. Внутренние markdown-ссылки (#anchor) резолвятся в этом же файле.
#   2. CHANGELOG: у каждого version-heading есть reference-link; набор версий
#      в RU == EN; [Unreleased] присутствует в обоих.
#   3. Version triple: README badge == SCRIPT_VERSION == верхний changelog
#      heading (RU и EN).
#   4. Матрица ОС: Ubuntu 26.04 присутствует во всех заявленных местах.
#   5. SECURITY/CONTRIBUTING не протухли (текущий minor в supported-таблице;
#      нет захардкоженного test-count baseline).

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || { echo "ОШИБКА: не удалось перейти в $REPO_ROOT" >&2; exit 2; }

PASS=0
FAIL=0
declare -a RESULTS

_ok()  { echo "PASS: $1"; RESULTS+=("PASS: $1"); PASS=$((PASS+1)); }
_bad() { echo "FAIL: $1" >&2; RESULTS+=("FAIL: $1"); FAIL=$((FAIL+1)); }

# Файлы документации с внутренними якорями.
DOC_FILES=(
    README.md README.en.md
    ADVANCED.md ADVANCED.en.md
    CHANGELOG.md CHANGELOG.en.md
    SECURITY.md CONTRIBUTING.md INSTALL_VPS.md
    docs/SIGNING_DESIGN.md docs/RELEASE_PROCESS.md
)

echo "=== check-docs-consistency ==="

# GitHub-совместимая slug-генерация из текста заголовка:
# lowercase, убрать всё кроме букв/цифр/пробела/дефиса, пробелы -> дефисы,
# срезать ведущие/хвостовые дефисы (их даёт, например, emoji в начале heading -
# GitHub их тоже не оставляет).
_slug() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"   # ltrim
    s="${s%"${s##*[![:space:]]}"}"   # rtrim
    printf '%s' "$s" \
        | tr '[:upper:]' '[:lower:]' \
        | LC_ALL=C sed -E 's/[^a-z0-9 _-]//g' \
        | tr ' ' '-' \
        | sed -E 's/^-+//; s/-+$//'
}

# Удалить из markdown код, чтобы примеры разметки внутри него не парсились как
# реальные ссылки/якоря: fenced-блоки (``` ... ```) целиком + inline-спаны
# (`...`). Иначе документированный в backticks пример вида `](#anchor)` дал бы
# ложный FAIL.
_strip_code() {
    awk '/^```/ { infence = !infence; next } !infence { print }' "$1" \
        | sed 's/`[^`]*`//g'
}

# --- 1. Внутренние anchor-ссылки резолвятся ---
anchor_fail=0
for f in "${DOC_FILES[@]}"; do
    [[ -f "$f" ]] || continue

    # Анализируем файл с вырезанным кодом (примеры в backticks - не разметка).
    stripped="$(_strip_code "$f")"

    # Целевые якоря в файле: явные <a id=..> / <a name=..> + slug'и заголовков.
    declare -A anchors=()
    while IFS= read -r a; do
        [[ -n "$a" ]] && anchors["$a"]=1
    done < <(printf '%s\n' "$stripped" | grep -oiP '<a\s+(id|name)="\K[^"]+')
    while IFS= read -r h; do
        # Заголовки ATX: "# ...". Текст уже без ведущих #, slug'им.
        sl="$(_slug "$h")"
        [[ -n "$sl" ]] && anchors["$sl"]=1
    done < <(printf '%s\n' "$stripped" | grep -E '^#{1,6}[[:space:]]' | sed -E 's/^#{1,6}[[:space:]]+//')

    # Внутренние ссылки вида ](#anchor) в этом файле.
    while IFS= read -r ref; do
        [[ -z "$ref" ]] && continue
        if [[ -z "${anchors[$ref]:-}" ]]; then
            echo "  $f: битая внутренняя ссылка #$ref" >&2
            anchor_fail=1
        fi
    done < <(printf '%s\n' "$stripped" | grep -oP '\]\(#\K[^)]+')

    unset anchors
done
if [[ "$anchor_fail" -eq 0 ]]; then _ok "внутренние anchor-ссылки резолвятся"; else _bad "битые внутренние anchor-ссылки"; fi

# --- 2. CHANGELOG: heading <-> reference-link, RU == EN ---
changelog_fail=0
_changelog_versions() {  # печатает версии из "## [X]" headings
    grep -oP '^##\s+\[\K[^]]+' "$1"
}
_changelog_refs() {      # печатает версии из "[X]:" reference-links
    grep -oP '^\[\K[^]]+(?=\]:)' "$1"
}
for f in CHANGELOG.md CHANGELOG.en.md; do
    [[ -f "$f" ]] || { _bad "нет $f"; changelog_fail=1; continue; }
    while IFS= read -r v; do
        [[ -z "$v" ]] && continue
        if ! _changelog_refs "$f" | grep -qxF "$v"; then
            echo "  $f: heading [$v] без reference-link [$v]:" >&2
            changelog_fail=1
        fi
    done < <(_changelog_versions "$f")
    if ! _changelog_versions "$f" | grep -qxF "Unreleased"; then
        echo "  $f: нет heading [Unreleased]" >&2
        changelog_fail=1
    fi
done
# RU == EN набор версий (отсортированные уникальные heading-списки).
if [[ -f CHANGELOG.md && -f CHANGELOG.en.md ]]; then
    ru_set="$(_changelog_versions CHANGELOG.md | sort -u)"
    en_set="$(_changelog_versions CHANGELOG.en.md | sort -u)"
    if [[ "$ru_set" != "$en_set" ]]; then
        echo "  набор версий CHANGELOG.md != CHANGELOG.en.md:" >&2
        diff <(printf '%s\n' "$ru_set") <(printf '%s\n' "$en_set") >&2 || true
        changelog_fail=1
    fi
fi
if [[ "$changelog_fail" -eq 0 ]]; then _ok "CHANGELOG headings/refs согласованы, RU == EN"; else _bad "CHANGELOG рассинхрон"; fi

# --- 3. Version triple: badge == SCRIPT_VERSION == верхний changelog heading ---
ver_fail=0
script_ver="$(awk -F'"' '/^SCRIPT_VERSION=/{print $2; exit}' install_amneziawg.sh)"
# Верхний non-Unreleased heading в каждом changelog.
top_ru="$(grep -oP '^##\s+\[\K[0-9]+\.[0-9]+\.[0-9]+' CHANGELOG.md | head -n1)"
top_en="$(grep -oP '^##\s+\[\K[0-9]+\.[0-9]+\.[0-9]+' CHANGELOG.en.md | head -n1)"
for pair in "README.md:$script_ver" "README.en.md:$script_ver"; do
    rf="${pair%%:*}"; expect="${pair##*:}"
    badge="$(grep -oP 'Installer_Version-\K[0-9]+\.[0-9]+\.[0-9]+' "$rf" | head -n1)"
    if [[ "$badge" != "$expect" ]]; then
        echo "  $rf badge='$badge' != SCRIPT_VERSION='$expect'" >&2
        ver_fail=1
    fi
done
if [[ "$top_ru" != "$script_ver" ]]; then echo "  CHANGELOG.md top heading '$top_ru' != SCRIPT_VERSION '$script_ver'" >&2; ver_fail=1; fi
if [[ "$top_en" != "$script_ver" ]]; then echo "  CHANGELOG.en.md top heading '$top_en' != SCRIPT_VERSION '$script_ver'" >&2; ver_fail=1; fi
if [[ "$ver_fail" -eq 0 ]]; then _ok "version triple согласован ($script_ver)"; else _bad "version triple рассинхрон"; fi

# --- 4. Матрица ОС: Ubuntu 26.04 во всех заявленных местах ---
os_fail=0
for f in README.md README.en.md install_amneziawg.sh install_amneziawg_en.sh .github/ISSUE_TEMPLATE/bug_report.yml; do
    [[ -f "$f" ]] || { echo "  нет $f (проверка 26.04)" >&2; os_fail=1; continue; }
    if ! grep -q '26\.04' "$f"; then
        echo "  $f: нет упоминания Ubuntu 26.04 в матрице ОС" >&2
        os_fail=1
    fi
done
if [[ "$os_fail" -eq 0 ]]; then _ok "Ubuntu 26.04 присутствует в матрице ОС"; else _bad "Ubuntu 26.04 отсутствует где-то в матрице ОС"; fi

# --- 5. SECURITY/CONTRIBUTING не протухли ---
stale_fail=0
# Текущий minor (X.Y) должен фигурировать в SECURITY supported-таблице.
minor="$(printf '%s' "$script_ver" | grep -oP '^[0-9]+\.[0-9]+')"
if [[ -f SECURITY.md ]]; then
    if ! grep -qE "${minor//./\\.}\.[x0-9]" SECURITY.md; then
        echo "  SECURITY.md: текущий minor $minor.x не найден в supported-таблице" >&2
        stale_fail=1
    fi
else
    echo "  нет SECURITY.md" >&2; stale_fail=1
fi
# CONTRIBUTING не должен хардкодить число тестов (хрупкий baseline).
if [[ -f CONTRIBUTING.md ]]; then
    if grep -qiP '\b[0-9]{3,}\s+tests?\b' CONTRIBUTING.md; then
        echo "  CONTRIBUTING.md: захардкоженный счётчик тестов (хрупкий baseline)" >&2
        stale_fail=1
    fi
fi
if [[ "$stale_fail" -eq 0 ]]; then _ok "SECURITY/CONTRIBUTING не протухли"; else _bad "SECURITY/CONTRIBUTING протухли"; fi

# --- Summary ---
echo ""
echo "=== docs-consistency summary: $PASS passed, $FAIL failed ==="
for r in "${RESULTS[@]}"; do echo "  $r"; done

[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
