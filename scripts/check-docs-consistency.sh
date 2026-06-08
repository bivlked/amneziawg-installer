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
#   4. Матрица ОС: полный набор релизов (Ubuntu 24.04/25.10/26.04, Debian 12/13)
#      + архитектур (x86_64/ARM64/ARMv7) во всех заявленных местах.
#   5. SECURITY/CONTRIBUTING не протухли (текущий minor в supported-таблице;
#      нет захардкоженного test-count baseline).
#   6. Pinned raw-URL теги в README/ADVANCED/INSTALL_VPS == SCRIPT_VERSION
#      (CHANGELOG исключён - там теги исторические).
#   7. ADVANCED: устаревшие IPv6 split-tunnel формулировки не вернулись
#      (present-tense "не поддерживается / implies full-tunnel"; past-tense
#      историческая заметка разрешена).
#   8. Issue-template: placeholder версии нейтральный (не протухающий X.Y.Z).
#   9. Матрица OS×arch×prebuilt-target: supported Ubuntu-версии без ARM
#      prebuilt-таргета в arm-build.yml помечены DKMS-only для ARM в INSTALL_VPS.

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || { echo "ОШИБКА: не удалось перейти в $REPO_ROOT" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "ОШИБКА: нужен perl (slug-генерация якорей)" >&2; exit 2; }

PASS=0
FAIL=0
declare -a RESULTS

_ok()  { echo "PASS: $1"; RESULTS+=("PASS: $1"); PASS=$((PASS+1)); }
_bad() { echo "FAIL: $1" >&2; RESULTS+=("FAIL: $1"); FAIL=$((FAIL+1)); }

# Файлы документации с внутренними якорями. Обнаруживаются динамически: ВСЕ
# tracked *.md, чтобы новый markdown (например CODE_OF_CONDUCT.md) автоматически
# попадал под anchor-валидацию. Раньше список был захардкожен (#4 docs-audit), и
# новый MD проходил CI без проверки якорей. Спец-проверки ниже (README/CHANGELOG/
# SECURITY/CONTRIBUTING/ОС-матрица) остаются точечными по своим файлам.
mapfile -t DOC_FILES < <(git ls-files '*.md' 2>/dev/null | sort)
if [[ "${#DOC_FILES[@]}" -eq 0 ]]; then
    # Fallback вне git-дерева: явный базовый набор.
    DOC_FILES=(
        README.md README.en.md ADVANCED.md ADVANCED.en.md
        CHANGELOG.md CHANGELOG.en.md SECURITY.md CONTRIBUTING.md
        CODE_OF_CONDUCT.md INSTALL_VPS.md
        docs/SIGNING_DESIGN.md docs/RELEASE_PROCESS.md docs/ROADMAP.md
    )
fi

echo "=== check-docs-consistency ==="

# GitHub-совместимая slug-генерация (Unicode-aware, один perl-проход на файл
# вместо 4 subprocess на КАЖДЫЙ заголовок). Прежняя версия и тормозила
# (fork-оверхед на сотнях заголовков), и резала кириллицу через LC_ALL=C,
# из-за чего RU-заголовки давали пустой slug. Читает заголовки построчно из
# stdin, печатает по slug на строку: Unicode-lowercase, оставить буквы/цифры/
# пробел/подчёркивание/дефис (кириллица сохраняется, как у GitHub), пробелы ->
# дефисы, срезать крайние дефисы (их даёт, например, emoji в начале заголовка).
_slug_stream() {
    perl -CSD -ne '
        chomp;
        s/^\s+//; s/\s+$//;
        $_ = lc;
        s/[^\p{L}\p{N} _-]//g;
        s/ /-/g;
        s/^-+//; s/-+$//;
        print "$_\n";
    '
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
    # Заголовки ATX: "# ...". Снимаем ведущие #, слугаем все заголовки файла
    # одним perl-проходом (а не subprocess на каждый заголовок).
    while IFS= read -r sl; do
        [[ -n "$sl" ]] && anchors["$sl"]=1
    done < <(printf '%s\n' "$stripped" | grep -E '^#{1,6}[[:space:]]' | sed -E 's/^#{1,6}[[:space:]]+//' | _slug_stream)

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

# --- 4. Матрица ОС + архитектур: полный набор во всех заявленных местах ---
# Единый источник ожидаемого набора. Прежняя узкая проверка ловила только
# "26.04" и пропускала общий drift: при будущем добавлении/удалении одной ОС
# часть документов осталась бы со старой матрицей при зелёном docs-check.
# Токены подобраны так, чтобы матчиться во всех форматах (badge, таблица
# совместимости, install --help, issue dropdown): голые версии Ubuntu +
# "Debian N" с контекстом семейства.
EXPECTED_OS=("24.04" "25.10" "26.04" "Debian 12" "Debian 13")
OS_MATRIX_FILES=(README.md README.en.md install_amneziawg.sh install_amneziawg_en.sh .github/ISSUE_TEMPLATE/bug_report.yml)
os_fail=0
for f in "${OS_MATRIX_FILES[@]}"; do
    [[ -f "$f" ]] || { echo "  нет $f (проверка матрицы ОС)" >&2; os_fail=1; continue; }
    for os in "${EXPECTED_OS[@]}"; do
        if ! grep -qF "$os" "$f"; then
            echo "  $f: нет '$os' в матрице ОС" >&2
            os_fail=1
        fi
    done
done
if [[ "$os_fail" -eq 0 ]]; then _ok "матрица ОС полна во всех заявленных местах (${EXPECTED_OS[*]})"; else _bad "матрица ОС неполна где-то"; fi

# Архитектуры: x86_64 / ARM64 / ARMv7 согласованы между README RU/EN и issue-шаблоном.
EXPECTED_ARCH=("x86_64" "ARM64" "ARMv7")
ARCH_MATRIX_FILES=(README.md README.en.md .github/ISSUE_TEMPLATE/bug_report.yml)
arch_fail=0
for f in "${ARCH_MATRIX_FILES[@]}"; do
    [[ -f "$f" ]] || { echo "  нет $f (проверка матрицы архитектур)" >&2; arch_fail=1; continue; }
    for a in "${EXPECTED_ARCH[@]}"; do
        if ! grep -qF "$a" "$f"; then
            echo "  $f: нет '$a' в матрице архитектур" >&2
            arch_fail=1
        fi
    done
done
if [[ "$arch_fail" -eq 0 ]]; then _ok "матрица архитектур согласована (${EXPECTED_ARCH[*]})"; else _bad "матрица архитектур неполна где-то"; fi

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

# --- 6. Pinned raw-URL tags == SCRIPT_VERSION ---
# Пользовательские команды установки/обновления закрепляют тег в raw-URL вида
# raw.githubusercontent.com/bivlked/amneziawg-installer/vX.Y.Z/... . Они обязаны
# указывать на текущий релиз, иначе copy-paste из README ставит прошлую версию
# (регрессия, ради которой добавлена эта проверка). CHANGELOG исключён намеренно -
# там теги исторические (точки появления функций/прошлые релизы).
url_fail=0
URL_DOCS=(README.md README.en.md ADVANCED.md ADVANCED.en.md INSTALL_VPS.md)
for f in "${URL_DOCS[@]}"; do
    [[ -f "$f" ]] || continue
    while IFS= read -r tag; do
        [[ -z "$tag" ]] && continue
        if [[ "$tag" != "$script_ver" ]]; then
            echo "  $f: pinned raw-URL тег v$tag != SCRIPT_VERSION v$script_ver" >&2
            url_fail=1
        fi
    done < <(grep -oP 'raw\.githubusercontent\.com/bivlked/amneziawg-installer/v\K[0-9]+\.[0-9]+\.[0-9]+' "$f")
done
if [[ "$url_fail" -eq 0 ]]; then _ok "pinned raw-URL теги == SCRIPT_VERSION ($script_ver)"; else _bad "pinned raw-URL теги рассинхронизированы"; fi

# --- 7. ADVANCED: устаревшие IPv6 split-tunnel формулировки не вернулись ---
# После переписывания IPv6-раздела (v5.15.1 split-tunnel + dual-stack корректно
# сочетаются) present-tense заявления о неподдержке не должны появиться снова.
# Историческая заметка в past tense ("подразумевал", "implied") разрешена.
ipv6_phrase_fail=0
for f in ADVANCED.md ADVANCED.en.md; do
    [[ -f "$f" ]] || continue
    if grep -qE 'подразумевает full-tunnel|implies full-tunnel|пока не поддерживается|is not supported yet' "$f"; then
        echo "  $f: устаревшая IPv6 split-tunnel формулировка (см. T2 v5.15.3)" >&2
        ipv6_phrase_fail=1
    fi
done
if [[ "$ipv6_phrase_fail" -eq 0 ]]; then _ok "ADVANCED: нет устаревших IPv6 split-tunnel формулировок"; else _bad "ADVANCED: вернулась устаревшая IPv6 формулировка"; fi

# --- 8. Issue-template: placeholder версии нейтральный (не протухающий) ---
# bug_report.yml не должен фиксировать конкретный X.Y.Z в placeholder версии -
# он устаревает с каждым релизом. Нейтральный вид: "5.x.y".
tmpl_fail=0
bug_tmpl=".github/ISSUE_TEMPLATE/bug_report.yml"
if [[ -f "$bug_tmpl" ]]; then
    if grep -qE 'placeholder:[[:space:]]*"e\.g\.,[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+"' "$bug_tmpl"; then
        echo "  $bug_tmpl: конкретный X.Y.Z в placeholder версии (протухает; используйте 5.x.y)" >&2
        tmpl_fail=1
    fi
fi
if [[ "$tmpl_fail" -eq 0 ]]; then _ok "issue-template: placeholder версии нейтральный"; else _bad "issue-template: протухающий placeholder версии"; fi

# --- 9. Матрица OS×arch×prebuilt-target: ARM prebuilt-покрытие согласовано ---
# arm-build.yml собирает prebuilt ARM .deb только для образов из своей matrix.
# Заявленные supported Ubuntu-версии без ARM prebuilt-таргета обязаны быть явно
# помечены DKMS-only для ARM, иначе матрица ОС создаёт впечатление prebuilt там,
# где его нет (docs-audit #3: docs-check проверял OS и arch как независимые
# токены, не их пересечение с prebuilt-таргетом). Источник prebuilt-набора - сам
# arm-build.yml, поэтому проверка не протухнет при добавлении/удалении таргета.
arm_yml=".github/workflows/arm-build.yml"
arm_matrix_fail=0
if [[ -f "$arm_yml" ]]; then
    mapfile -t arm_ubuntu < <(grep -oP 'image:[[:space:]]*ubuntu:\K[0-9]+\.[0-9]+' "$arm_yml" | sort -u)
    for os in "${EXPECTED_OS[@]}"; do
        [[ "$os" =~ ^[0-9]+\.[0-9]+$ ]] || continue   # только Ubuntu version-токены
        has_prebuilt=0
        for u in "${arm_ubuntu[@]}"; do [[ "$u" == "$os" ]] && has_prebuilt=1; done
        [[ "$has_prebuilt" -eq 1 ]] && continue
        os_re="${os//./\\.}"
        if ! grep -qiE "${os_re} ARM64.*(DKMS|from source)" INSTALL_VPS.md 2>/dev/null; then
            echo "  INSTALL_VPS.md: Ubuntu $os без ARM prebuilt-таргета и не помечен DKMS-only для ARM" >&2
            arm_matrix_fail=1
        fi
    done
else
    echo "  нет $arm_yml (проверка ARM prebuilt-матрицы)" >&2; arm_matrix_fail=1
fi
if [[ "$arm_matrix_fail" -eq 0 ]]; then _ok "ARM prebuilt-покрытие согласовано (OS×arch×target)"; else _bad "ARM prebuilt-покрытие рассинхронизировано"; fi

# --- Summary ---
echo ""
echo "=== docs-consistency summary: $PASS passed, $FAIL failed ==="
for r in "${RESULTS[@]}"; do echo "  $r"; done

[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
