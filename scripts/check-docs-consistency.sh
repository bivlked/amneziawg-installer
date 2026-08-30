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
# ⚠️ ДОБАВЛЯЕШЬ СЮДА НОВУЮ ПРОВЕРКУ - ПОДВИНЬ СЧЁТ В ДВУХ ТЕСТАХ.
# tests/test_v5153_docs_check.bats и tests/test_v5153_docs_check_slug.bats
# ассертят точную строку сводки вида "N passed, 0 failed". Любая добавленная
# проверка роняет оба файла, и связь эта ниоткуда не видна: сам скрипт про них
# не знает, а падение выглядит немотивированным.
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
#  6b. Форма пина: все raw-URL теги имеют вид vX.Y.Z числами. Отдельная проверка
#      потому, что регулярка #6 нечисловой пин не видит ВООБЩЕ (см. её комментарий).
#   7. ADVANCED: устаревшие IPv6 split-tunnel формулировки не вернулись
#      (present-tense "не поддерживается / implies full-tunnel"; past-tense
#      историческая заметка разрешена).
#   8. Issue-template: placeholder версии нейтральный (не протухающий X.Y.Z).
#   9. Матрица OS×arch×prebuilt-target: supported Ubuntu-версии без ARM
#      prebuilt-таргета в arm-build.yml помечены DKMS-only для ARM в INSTALL_VPS.
#  15. Блок "факты на дату" в обоих README совпадает с тем, что собирает
#      scripts/update-facts-block.sh из данных репозитория (см. её комментарий:
#      источников шесть, и один из них - сами скрипты).
#  10. Установочные/update wget-сниппеты качают install_amneziawg*.sh через -O
#      (голый wget <url> пишет .1 при повторном запуске, и chmod/bash берут
#      старый файл; злейший кейс - update-флоу с --force).

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
# Предупреждение НЕ входит в счёт: строку итога "N passed, M failed"
# проверяют bats-тесты, и третий счётчик их сломает. Сигнал при этом не
# теряется: он идёт в stderr и в список результатов.
_warn() { echo "WARN: $1" >&2; RESULTS+=("WARN: $1"); }

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
# Ожидаемый набор выводится из docs/support-matrix.json. Раньше он стоял здесь
# литеральным массивом, то есть был ШЕСТОЙ копией матрицы: проверка сравнивала
# копии друг с другом и потому означала "копии совпадают", а не "написана
# правда". Ubuntu 25.10 вышла из поддержки 2026-07-01, Debian 12 - 2026-07-11,
# и ни одна сверка документов между собой этого поймать не могла, потому что
# факт изменился СНАРУЖИ. Теперь платформы берутся из матрицы, а её собственные
# lifecycle-значения пересчитываются из дат (проверка 4b ниже).
#
# Токены подобраны так, чтобы матчиться во всех форматах (badge, таблица
# совместимости, install --help, issue dropdown): голые версии Ubuntu +
# "Debian N" с контекстом семейства.
MATRIX_FILE="${AWG_MATRIX_FILE:-docs/support-matrix.json}"

# python выбирается ЗАПУСКОМ, а не наличием в PATH: на Windows `python3` часто
# оказывается заглушкой Microsoft Store, которая command -v проходит, а код не
# выполняет.
PY=""
for _c in python3 python; do
    if printf 'print(1)' | "$_c" - >/dev/null 2>&1; then PY="$_c"; break; fi
done

if [[ -z "$PY" ]]; then
    _bad "не найден рабочий python (нужен для чтения $MATRIX_FILE)"
elif [[ ! -f "$MATRIX_FILE" ]]; then
    _bad "нет $MATRIX_FILE - единого источника матрицы ОС"
else
    # Вывод захватывается С ПРОВЕРКОЙ СТАТУСА, а не читается через process
    # substitution: там статусом команды становится статус mapfile, а не Python.
    # Питон, упавший на середине списка, оставил бы массив непустым, и проверка
    # прошла бы по урезанному набору, ничего не сказав.
    EXPECTED_OS=()
    if ! expected_os_out="$("$PY" - "$MATRIX_FILE" <<'PYEOF'
import io, json, sys

# На Windows текстовый stdout дописывает к каждой строке возврат каретки, и
# токен приезжает в bash вместе с ним: grep -qF ищет "24.04CR" и не находит
# ничего ни в одном файле. В CI на Linux этого нет, поэтому дефект был бы
# виден только тому, кто гоняет проверку локально.
sys.stdout.reconfigure(newline='\n')

d = json.load(io.open(sys.argv[1], encoding='utf-8'))
for p in d['platforms']:
    # Неизвестное семейство иначе стало бы токеном вида "Debian 41" и молча
    # проверялось бы как Debian.
    if p['os'] not in ('ubuntu', 'debian'):
        sys.exit('неизвестный os %r у платформы %r' % (p['os'], p.get('id')))
    if not isinstance(p.get('version'), str) or not p['version'].strip():
        sys.exit('version у %r не непустая строка: %r' % (p.get('id'), p.get('version')))
    print(p['version'] if p['os'] == 'ubuntu' else 'Debian %s' % p['version'])
PYEOF
)"; then
        _bad "не удалось вывести набор ОС из $MATRIX_FILE (см. ошибку выше)"
    else
        # printf без перевода строки, а не here-string: `<<<""` даёт массив
        # из ОДНОГО пустого элемента, и проверка на пустоту становится
        # недостижимой, а пустой токен матчится грепом в любом файле.
        mapfile -t EXPECTED_OS < <(printf '%s' "$expected_os_out")
    fi
    if [[ "${#EXPECTED_OS[@]}" -eq 0 ]]; then
        _bad "из $MATRIX_FILE не прочиталась ни одна платформа"
    else
        OS_MATRIX_FILES=(README.md README.en.md install_amneziawg.sh install_amneziawg_en.sh .github/ISSUE_TEMPLATE/bug_report.yml)
        os_fail=0
        for f in "${OS_MATRIX_FILES[@]}"; do
            [[ -f "$f" ]] || { echo "  нет $f (проверка матрицы ОС)" >&2; os_fail=1; continue; }
            for os in "${EXPECTED_OS[@]}"; do
                # Пустой токен превратил бы grep -qF в поиск пустой строки,
                # то есть в совпадение с любым файлом.
                if [[ -z "$os" ]]; then
                    echo "  пустой токен ОС из $MATRIX_FILE" >&2
                    os_fail=1
                    continue
                fi
                if ! grep -qF -- "$os" "$f"; then
                    echo "  $f: нет '$os' в матрице ОС" >&2
                    os_fail=1
                fi
            done
        done
        if [[ "$os_fail" -eq 0 ]]; then _ok "матрица ОС полна во всех заявленных местах (${EXPECTED_OS[*]})"; else _bad "матрица ОС неполна где-то"; fi
    fi

    # --- 4b. lifecycle в матрице пересчитывается из дат ---
    # Ловит класс, который сверка документов между собой не ловит В ПРИНЦИПЕ:
    # внешний факт изменился, а запись осталась прежней. Именно так пропустили
    # окончание поддержки Debian 12 - аудит смотрел на согласованность
    # документов, а не на календарь.
    if lifecycle_out="$("$PY" - "$MATRIX_FILE" <<'PYEOF'
import datetime, io, json, sys

sys.stdout.reconfigure(newline='\n')  # см. про возврат каретки выше

import re


def die_schema(msg):
    """Ошибка схемы или чтения - это НЕ расхождение с датами. Отдельный код,
    иначе испорченный файл отчитается как «lifecycle разошёлся», и чинить пойдут
    не то."""
    print('матрица не прошла проверку формата: %s' % msg)
    sys.exit(4)


try:
    d = json.load(io.open(sys.argv[1], encoding='utf-8'))
    platforms = d['platforms']
except Exception as exc:
    die_schema('%s: %s' % (type(exc).__name__, exc))

if not isinstance(platforms, list):
    die_schema('platforms не список')

today = datetime.date.today()
DATE_RE = re.compile(r'^\d{4}-\d{2}-\d{2}$')


def as_date(value, field, pid):
    """fromisoformat принимает и компактную форму 20290531, поэтому лексика
    проверяется отдельно: матрица объявляет именно YYYY-MM-DD."""
    if value is None:
        return None
    if not isinstance(value, str) or not DATE_RE.match(value):
        die_schema('%s.%s не дата вида YYYY-MM-DD: %r' % (pid, field, value))
    try:
        return datetime.date.fromisoformat(value)
    except ValueError as exc:
        die_schema('%s.%s: %s' % (pid, field, exc))


# Инварианты, объявленные в самой матрице. Раньше не проверялся ни один, а
# нарушение половины из них прямо меняет то, что мы рекомендуем пользователю.
ids, pairs_ov, defaults = [], [], {}
for p in platforms:
    if not isinstance(p, dict):
        die_schema('элемент platforms не объект')
    pid = p.get('id', '<без id>')
    for req in ('id', 'os', 'version', 'released', 'lifecycle', 'project_policy'):
        if req not in p:
            die_schema('%s: нет поля %s' % (pid, req))
    if p['os'] not in ('ubuntu', 'debian'):
        die_schema('%s: неизвестный os %r' % (pid, p['os']))
    if p['project_policy'] not in ('default', 'allowed', 'discouraged'):
        die_schema('%s: неизвестный project_policy %r' % (pid, p['project_policy']))
    for f in ('id', 'version'):
        # Пустая version деградирует токен до пустой строки, а она грепается
        # в любом файле: проверка полноты матрицы стала бы тавтологией.
        if not isinstance(p[f], str) or not p[f].strip():
            die_schema('%s: %s должно быть непустой строкой, а не %r' % (pid, f, p[f]))
    ids.append(p['id'])
    pairs_ov.append((p['os'], p['version']))
    rel = as_date(p['released'], 'released', pid)
    if rel is None:
        die_schema('%s: released обязателен' % pid)
    reg = as_date(p.get('vendor_regular_eol'), 'vendor_regular_eol', pid)
    lts = as_date(p.get('vendor_lts_eol'), 'vendor_lts_eol', pid)
    if reg is not None and not rel < reg:
        die_schema('%s: released не раньше vendor_regular_eol' % pid)
    if lts is not None and reg is not None and not lts > reg:
        die_schema('%s: vendor_lts_eol не позже vendor_regular_eol' % pid)
    if p['project_policy'] == 'default':
        defaults[p['os']] = defaults.get(p['os'], 0) + 1
    if p['project_policy'] in ('default', 'allowed') and p['lifecycle'] != 'supported':
        die_schema('%s: policy %s при lifecycle %s - рекомендуем систему без '
                   'поддержки вендора' % (pid, p['project_policy'], p['lifecycle']))

if len(ids) != len(set(ids)):
    die_schema('идентификаторы платформ не уникальны')
if len(pairs_ov) != len(set(pairs_ov)):
    die_schema('пара (os, version) не уникальна')
# Обход по НАЙДЕННЫМ ключам не может обнаружить отсутствующее семейство:
# если ни одна Ubuntu не помечена default, словарь просто не содержит ключа,
# и цикл по нему молчит. Идём по известному списку семейств.
for os_name in ('ubuntu', 'debian'):
    n = defaults.get(os_name, 0)
    if n != 1:
        die_schema('у %s ровно один default быть должен, а их %d' % (os_name, n))


def classify(released, regular, lts):
    """Правило записано в самой матрице, ключ lifecycle.derivation."""
    if datetime.date.fromisoformat(released) > today:
        return 'unreleased'
    if regular and datetime.date.fromisoformat(regular) >= today:
        return 'supported'
    if lts and datetime.date.fromisoformat(lts) >= today:
        return 'extended-support'
    return 'eol'


# Контроль классификатора. По существу этой проверке предстоит срабатывать раз
# в годы, а проверка, которая никогда не срабатывала, может быть сломана, и об
# этом никто не узнает. Контроль отличает "проверка отработала и ничего не
# нашла" от "проверка не выполнилась".
past = (today - datetime.timedelta(days=400)).isoformat()
future = (today + datetime.timedelta(days=400)).isoformat()
today_s = today.isoformat()
control = [
    classify('2000-01-01', past, None) == 'eol',
    classify('2000-01-01', future, None) == 'supported',
    classify('2000-01-01', past, future) == 'extended-support',
    classify(future, None, None) == 'unreleased',
    # Граница, объявленная в самой матрице: дата, равная сегодняшней, всё
    # ещё считается поддержкой. Без этого случая замена >= на > проходит
    # контроль, а вердикт врёт ровно в день окончания поддержки - в
    # единственный день, когда проверка кому-то нужна.
    classify('2000-01-01', today_s, None) == 'supported',
    classify('2000-01-01', past, today_s) == 'extended-support',
    # Обычной поддержки нет вовсе, но продлённая жива.
    classify('2000-01-01', None, future) == 'extended-support',
    # Выпущено сегодня - уже выпущено.
    classify(today_s, future, None) == 'supported',
    # Действуют ОБЕ даты: обычная поддержка должна побеждать продлённую. Без
    # этого случая перестановка двух веток проходит контроль целиком и при
    # этом объявляет три живые платформы продлённой поддержкой.
    classify('2000-01-01', future, future) == 'supported',
]
if not all(control):
    print('контроль классификатора ПРОВАЛЕН: %r' % control)
    sys.exit(2)

bad = 0
checked = 0
for p in platforms:
    want = classify(p['released'], p.get('vendor_regular_eol'), p.get('vendor_lts_eol'))
    checked += 1
    if want != p['lifecycle']:
        print('  %s: записано "%s", по датам "%s"' % (p['id'], p['lifecycle'], want))
        bad += 1
if bad:
    sys.exit(1)

# Сверено ноль платформ - это не успех, а невыполненная проверка. Раньше
# печаталось len(platforms), поэтому пустой список давал бодрое
# 'сходятся с датами' при нулевой работе.
if checked == 0:
    print('ни одна платформа не сверена: список platforms пуст')
    sys.exit(3)

print('контроль %d/%d, сверено платформ: %d' % (len(control), len(control), checked))

# Возраст снимка внешних фактов - предупреждение, не отказ: краснеть просто от
# течения времени значит приучить к красному.
ver = d.get('verification')
if not isinstance(ver, dict):
    die_schema('verification не объект')
lv = as_date(ver.get('last_verified'), 'last_verified', 'verification')
if lv:
    age = (today - lv).days
    if age > 180:
        print('STALE %d' % age)
PYEOF
)"; then
        _ok "lifecycle в матрице сходится с датами ($(printf '%s' "$lifecycle_out" | head -n1))"
        stale="$(printf '%s' "$lifecycle_out" | grep -oP '^STALE \K[0-9]+' || true)"
        [[ -n "$stale" ]] && _warn "внешние факты в $MATRIX_FILE сверялись $stale дней назад (verification.last_verified)"
    else
        rc=$?
        printf '%s\n' "$lifecycle_out" >&2
        case "$rc" in
            1) _bad "lifecycle в $MATRIX_FILE разошёлся с датами (пересчитать и обновить)" ;;
            2) _bad "проверка lifecycle НЕ ВЫПОЛНИЛАСЬ: контроль классификатора провален" ;;
            3) _bad "проверка lifecycle НЕ ВЫПОЛНИЛАСЬ: сверять было нечего" ;;
            4) _bad "проверка lifecycle НЕ ВЫПОЛНИЛАСЬ: матрица не прошла формат" ;;
            # Любой другой код - это упавший python, а не вердикт о датах.
            # Раньше он приходил под тем же кодом 1 и отчитывался как
            # расхождение, то есть называл неверную причину.
            *) _bad "проверка lifecycle НЕ ВЫПОЛНИЛАСЬ: неожиданный код $rc" ;;
        esac
    fi
fi

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
# CASCADE.md/.en.md включены: awg-routing.sh закрепляет тег в fallback-URL снимка
# ru.zone (raw .../vX.Y.Z/cascade/ru.zone). Пин на тег = иммутабельный снимок, а не
# подвижный main; проверка не даёт ему протухнуть на новом релизе (бампать каждый релиз).
url_fail=0
URL_DOCS=(README.md README.en.md ADVANCED.md ADVANCED.en.md INSTALL_VPS.md INSTALL_VPS.ru.md CASCADE.md CASCADE.en.md WARP-RU.md WARP-RU.en.md)
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

# --- 6b. Форма пина: все raw-URL теги обязаны быть vX.Y.Z числами ---
# Проверка 6 выше сравнивает НАЙДЕННЫЕ ЧИСЛОВЫЕ теги со SCRIPT_VERSION, и это
# её единственная задача. Но её регулярка требует три группы цифр, поэтому
# нечисловой пин в выборку не попадает ВООБЩЕ и проверка остаётся зелёной.
# Замер 25 aug 2026: из пяти форм (v5.27.1, vX.Y.Z, v5.27, vLATEST, main) она
# видела ОДНУ. Опаснее всего v5.27 - правдоподобная опечатка из двух групп,
# выглядит настоящим тегом и молча ведёт в никуда.
# Живой случай: INSTALL_VPS.md отдавал команду обновления с буквальным vX.Y.Z
# внутри блока кода; docs/RELEASE_PROCESS.md шаг 3 прямо пишет, что пользователи
# копируют такие однострочники дословно.
# Здесь берём ВСЕ вхождения (`[^/]+`, вместе с ведущим v) и требуем форму.
# ⚠️ URL_DOCS намеренно переиспользуется как есть: выборка та же, менять её
# незачем, и её вид - якорь публикационного пакета русского INSTALL_VPS.
form_fail=0
for f in "${URL_DOCS[@]}"; do
    [[ -f "$f" ]] || continue
    while IFS= read -r pin; do
        [[ -z "$pin" ]] && continue
        if [[ ! "$pin" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "  $f: пин '$pin' не имеет формы vX.Y.Z (плейсхолдер, ветка или усечённый тег)" >&2
            form_fail=1
        fi
    done < <(grep -oP 'raw\.githubusercontent\.com/bivlked/amneziawg-installer/\K[^/]+' "$f")
done
if [[ "$form_fail" -eq 0 ]]; then _ok "форма пинов raw-URL (все vX.Y.Z числами)"; else _bad "нечисловые пины в raw-URL"; fi

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
if [[ "${#EXPECTED_OS[@]}" -eq 0 ]]; then
    # Пустой набор дал бы ноль итераций и бодрый PASS о работе, которой не
    # было. Проверка зависит от секции 4 и обязана падать вместе с ней.
    _bad "ARM prebuilt-покрытие НЕ ПРОВЕРЕНО: набор ОС пуст"
elif [[ -f "$arm_yml" ]]; then
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
if [[ "${#EXPECTED_OS[@]}" -eq 0 ]]; then
    :   # уже сообщено выше
elif [[ "$arm_matrix_fail" -eq 0 ]]; then _ok "ARM prebuilt-покрытие согласовано (OS×arch×target)"; else _bad "ARM prebuilt-покрытие рассинхронизировано"; fi

# --- 10. Установочные wget-сниппеты используют -O (re-run .1-ловушка) ---
# Голый `wget <url>/install_amneziawg*.sh` без -O при повторном запуске пишет
# install_amneziawg.sh.1, а следующий `chmod +x` / `bash install_amneziawg.sh`
# берут СТАРЫЙ первый файл. Злейший кейс - update-флоу с `--force`: старый скрипт
# присутствует всегда, и юзер переустанавливает прошлую версию, думая что
# обновился. Все сниппеты обязаны пинить имя через `-O` (паттерн как в FAQ
# recovery). Регрессия, ради которой добавлена проверка (PR #114). Детект (два
# шага): строка вызывает `wget` и качает install_amneziawg*.sh по raw-URL, но в
# ней нет `-O`/`--output-document` (пин имени). Ловит и `wget -q <url>` с флагами
# перед URL, не только голую форму. `wget -O name url`, `wget -O- url | bash` и
# `curl`-альтернативы (без `wget`) под паттерн не попадают.
wget_o_fail=0
WGET_DOCS=(README.md README.en.md ADVANCED.md ADVANCED.en.md INSTALL_VPS.md)
for f in "${WGET_DOCS[@]}"; do
    [[ -f "$f" ]] || continue
    while IFS= read -r hit; do
        [[ -z "$hit" ]] && continue
        echo "  $f:$hit" >&2
        echo "    ^ wget без -O: повторный запуск возьмёт .1; используйте 'wget -O <файл> <url>'" >&2
        wget_o_fail=1
    done < <(grep -nE 'wget[[:space:]].*https?://[^[:space:]]*install_amneziawg[a-z_]*\.sh' "$f" \
             | grep -vE -- '(^|[[:space:]])(-O|--output-document)')
done
if [[ "$wget_o_fail" -eq 0 ]]; then _ok "установочные wget-сниппеты используют -O (нет .1-ловушки)"; else _bad "wget-сниппет без -O (.1-ловушка вернулась)"; fi

# --- Summary ---
# --- 14. Управляющие байты в отслеживаемых текстовых файлах ---
# Оплачено 30 aug 2026. Правка документации, собранная python-строкой со
# строкой вида "System32\bash.exe", записала на месте \b БАЙТ ЗАБОЯ (0x08):
# в файле осталась команда, которую нельзя выполнить. Глазами это не видно,
# терминал такой байт не показывает, а обычный греп по тексту его не ищет.
# Python при этом предупредил про СОСЕДНИЙ escape и промолчал про этот,
# потому что \b у него валиден - предупреждение назвало безобидное и скрыло
# вредное.
#
# Проверка нарочно обходится без шестнадцатеричных экранирований: попытка
# записать класс [\x00-\x08...] тем же способом уложила в скрипт уже сырые
# управляющие байты, включая NUL, и проверка стала ловить что попало. tr сам
# понимает \t и \n, поэтому оболочке экранировать нечего.
ctrl_fail=0
while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    if LC_ALL=C tr -d '\t\n' < "$f" | LC_ALL=C grep -q '[[:cntrl:]]'; then
        echo "  $f: управляющие байты (см. cat -v)" >&2
        ctrl_fail=1
    fi
done < <(git ls-files '*.md' '*.sh' '*.yml' '*.yaml' '*.bats' 2>/dev/null)
if [[ "$ctrl_fail" -eq 0 ]]; then
    _ok "управляющих байтов в текстовых файлах нет"
else
    _bad "управляющие байты в текстовых файлах"
fi

# --- 15. Блок "факты на дату" в README собран из источников ---
# Блок с датой обещает читателю, что цифры свежие, поэтому он не пишется руками,
# а собирается scripts/update-facts-block.sh. Источники: SCRIPT_VERSION из
# install_amneziawg.sh, заголовок текущей версии в CHANGELOG.md,
# docs/support-matrix.json, поля arch: в arm-build.yml, оба README (текст между
# маркерами) и ШЕСТЬ основных скриптов - последние потому, что генератор
# отказывается собирать блок, если в конфиг начали писать параметр третьей
# линии, пока блок обещает профиль 2.0. Если секция упала после правки
# awg_common.sh, причина именно в этом.
#
# Проверка нужна именно как проверка, а не как "просто запускайте генератор":
# забыть запустить его при смене матрицы легко, а результат забывчивости -
# датированная неправда на первом экране обоих README.
#
# 🔴 Успех подтверждается ПОДПИСЬЮ В ВЫВОДЕ, а не только кодом возврата.
# Ревью 30 aug показало цену прежней формы: генератор печатает фразу-отчёт о
# проделанной работе, а проверка её выбрасывала и верила одному коду 0. Пустой
# файл на месте генератора давал PASS. Сам генератор с тех пор требует явный
# режим (--check / --write), так что потеря токена больше не приводит к тихой
# правке дерева, но проверять надо всё равно результат, а не факт завершения.
FACTS_OK_SIGN="совпадает с источниками"
if [[ ! -f scripts/update-facts-block.sh ]]; then
    _bad "нет scripts/update-facts-block.sh (генератор блока фактов)"
else
    facts_out="$(bash scripts/update-facts-block.sh --check 2>&1)"
    facts_rc=$?
    if [[ "$facts_rc" -eq 0 && "$facts_out" == *"$FACTS_OK_SIGN"* ]]; then
        _ok "блок фактов в README собран из источников"
    else
        printf '%s\n' "$facts_out" >&2
        # Код 2 это отказ инструмента или входных данных (нет python, нет файла,
        # неизвестный аргумент), а не расхождение блока. Валить их в одну
        # формулировку значит отправлять читателя пересобирать README вместо
        # починки окружения.
        if [[ "$facts_rc" -eq 2 ]]; then
            _bad "блок фактов НЕ ПРОВЕРЕН: генератор не смог отработать (см. причину выше)"
        elif [[ "$facts_rc" -eq 0 ]]; then
            _bad "блок фактов НЕ ПРОВЕРЕН: генератор завершился успехом без подписи '$FACTS_OK_SIGN'"
        else
            _bad "блок фактов в README разошёлся с источниками (bash scripts/update-facts-block.sh --write)"
        fi
    fi
fi

echo ""
echo "=== docs-consistency summary: $PASS passed, $FAIL failed ==="
for r in "${RESULTS[@]}"; do echo "  $r"; done

[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
