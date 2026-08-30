#!/usr/bin/env bash
#
# Собирает блок "факты на дату" в README.md и README.en.md из данных самого
# репозитория и проверяет, что записанное в файлах совпадает с источниками.
#
# ЗАЧЕМ ОТДЕЛЬНЫЙ ГЕНЕРАТОР, А НЕ ПРОСТО ТЕКСТ В README.
# Блок с датой - обещание читателю, что цифры свежие. Рукописный блок это
# обещание нарушает молча: он врёт ровно с того дня, когда кто-то забыл его
# поправить, и выглядит при этом достовернее обычного текста, потому что рядом
# стоит дата. Поэтому все значения выводятся из источников, а не пишутся руками:
#
#   версия и дата релиза  -> SCRIPT_VERSION + заголовок CHANGELOG.md
#   перечни ОС            -> docs/support-matrix.json (project_policy)
#   дата сверки по ОС     -> verification.last_verified из той же матрицы
#   архитектуры           -> поля arch: в .github/workflows/arm-build.yml
#
# 🔴 ДАТА БЕРЁТСЯ ИЗ РЕПОЗИТОРИЯ, А НЕ ИЗ ЧАСОВ. Если подставлять сегодняшнее
# число, режим --check краснеет на следующий же день после коммита и перестаёт
# что-либо значить - проверка, падающая по умолчанию, читается как сломанная и
# её начинают игнорировать.
#
# Использование:
#   bash scripts/update-facts-block.sh           # переписать блок в README
#   bash scripts/update-facts-block.sh --check   # только сверить, ничего не писать
#
# Режим --check вызывается из scripts/check-docs-consistency.sh, то есть идёт и
# в CI (docs-check.yml), и в preflight перед тегом.

set -o pipefail

# AWG_FACTS_ROOT существует ради тестов: они собирают из репозитория временную
# копию нужных файлов и портят её, не трогая рабочее дерево. В обычной работе
# переменная не задаётся, и корнем становится сам репозиторий.
ROOT="${AWG_FACTS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT" || exit 1

MODE="write"
case "${1:-}" in
    "")        MODE="write" ;;
    --check)   MODE="check" ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)         echo "неизвестный аргумент: $1 (ожидается --check или ничего)" >&2; exit 2 ;;
esac

# python выбирается ЗАПУСКОМ, а не наличием в PATH: на Windows `python3` часто
# оказывается заглушкой Microsoft Store, которая command -v проходит, а код не
# выполняет. Тот же приём, что в check-docs-consistency.sh.
PY=""
for _c in python3 python; do
    if printf 'print(1)' | "$_c" - >/dev/null 2>&1; then PY="$_c"; break; fi
done
if [[ -z "$PY" ]]; then
    echo "не найден рабочий python (нужен для чтения docs/support-matrix.json)" >&2
    exit 2
fi

"$PY" - "$MODE" <<'PYEOF'
# -*- coding: utf-8 -*-
import io
import json
import os
import re
import sys

MODE = sys.argv[1]

# Путь к матрице ЖЁСТКИЙ, а не из AWG_MATRIX_FILE, хотя эта переменная в
# репозитории есть. Смысл проверки - сверить README с НАСТОЯЩИМИ источниками
# репозитория; подмена матрицы проверяла бы генератор, а это делает свой тест.
# Практическое следствие важнее принципа: тесты сторожа матрицы подсовывают
# через AWG_MATRIX_FILE заведомо испорченный файл, и если бы блок фактов её
# читал, их кейс "протухший снимок предупреждает, но не роняет" стал бы падать
# из-за постороннего расхождения.
MATRIX = 'docs/support-matrix.json'
ARM_YML = '.github/workflows/arm-build.yml'
BEGIN = '<!-- facts:begin -->'
END = '<!-- facts:end -->'


def die(msg):
    sys.stderr.write('  %s\n' % msg)
    sys.exit(1)


def read(path):
    if not os.path.isfile(path):
        die('нет %s' % path)
    return io.open(path, encoding='utf-8').read()


# --- версия установщика -------------------------------------------------
# Источник тот же, что у остальных проверок: SCRIPT_VERSION в install-скрипте.
# Совпадение версии в шести скриптах и двух changelog уже стережёт
# check-docs-consistency.sh, поэтому здесь достаточно одного файла.
m = re.search(r'^SCRIPT_VERSION="([^"]+)"', read('install_amneziawg.sh'), re.M)
if not m:
    die('не нашёл SCRIPT_VERSION в install_amneziawg.sh')
version = m.group(1)

# --- дата релиза этой версии --------------------------------------------
# Берётся из заголовка CHANGELOG, а не из git-тега: тег в момент подготовки
# релиза ещё не существует, а preflight обязан отработать ДО пуша тега.
m = re.search(r'^## \[%s\] - (\d{4}-\d{2}-\d{2})\s*$' % re.escape(version),
              read('CHANGELOG.md'), re.M)
if not m:
    die('в CHANGELOG.md нет заголовка "## [%s] - YYYY-MM-DD" '
        '(блок фактов берёт дату релиза оттуда)' % version)
released = m.group(1)

# --- платформы ----------------------------------------------------------
matrix = json.loads(read(MATRIX))

last_verified = matrix.get('verification', {}).get('last_verified')
if not re.match(r'^\d{4}-\d{2}-\d{2}$', last_verified or ''):
    die('verification.last_verified в %s не дата вида YYYY-MM-DD: %r'
        % (MATRIX, last_verified))

OS_LABEL = {'ubuntu': 'Ubuntu', 'debian': 'Debian'}
buckets = {'default': [], 'allowed': [], 'discouraged': []}

for p in matrix['platforms']:
    pid = p.get('id')
    family = p.get('os')
    if family not in OS_LABEL:
        die('неизвестное семейство %r у платформы %r' % (family, pid))
    policy = p.get('project_policy')
    if policy not in buckets:
        die('неизвестный project_policy %r у платформы %r' % (policy, pid))
    # Невышедшая платформа не должна попасть в перечень как рабочая: строка
    # блока обещает читателю, что на этом можно ставить прямо сейчас.
    if p.get('lifecycle') == 'unreleased':
        continue
    buckets[policy].append('%s %s' % (OS_LABEL[family], p['version']))

for name in ('default', 'allowed', 'discouraged'):
    if not buckets[name]:
        die('в %s не осталось ни одной платформы с project_policy=%s - '
            'строку блока надо переписать осознанно, а не оставлять пустой'
            % (MATRIX, name))

# --- архитектуры --------------------------------------------------------
# ARM-часть выводится из матрицы сборки, чтобы обещание "ARMv7" не пережило
# удаление armhf-таргета. x86_64 в arm-build.yml отсутствует по определению:
# на нём модуль всегда собирается через DKMS, готовых пакетов нет.
ARCH_LABEL = {'arm64': 'ARM64', 'armhf': 'ARMv7'}
arches = []
for raw in re.findall(r'^\s*arch:\s*(\S+)\s*$', read(ARM_YML), re.M):
    a = raw.strip().strip('"\'')
    if a not in ARCH_LABEL:
        die('в %s встретилась архитектура %r, для которой в этом скрипте нет '
            'человекочитаемого имени - добавьте её в ARCH_LABEL осознанно' % (ARM_YML, a))
    if ARCH_LABEL[a] not in arches:
        arches.append(ARCH_LABEL[a])
if not arches:
    die('в %s не нашлось ни одного поля arch:' % ARM_YML)
arch_line = ', '.join(['x86_64'] + arches)

# --- профиль конфигурации: единственное утверждение, которое не выводится --
# Все прочие значения блока берутся из данных. Строка про профиль конфигурации
# это утверждение о поведении кода, поэтому она привязывается к самому коду:
# если в шаблон конфига попадёт параметр третьей линии, блок начнёт обещать
# неправду, и генератор обязан остановиться, а не молча собрать старый текст.
#
# ⚠️ Граница проверки названа честно: ловится параметр, записанный с начала
# строки в форме "Имя = ..." - именно так лежат Jc/S1/H1/I1 в шаблонах. Параметр,
# собранный в строку через переменную, сюда не попадёт. Сужение осознанное:
# широкий поиск по именам даёт ложные срабатывания на перечнях параметров и на
# маскировании секретов в диагностике, где эти имена упоминаются законно.
AWG3_PARAMS = ('HeaderProtectionKey', 'RandomTrailers', 'ContentPaddingAddition',
               'DisableCookies', 'MaxHandshakeAttempts')
AWG3_RE = re.compile(r'^[ \t]*(%s)[ \t]*=' % '|'.join(AWG3_PARAMS), re.M)
SCRIPTS = ('awg_common.sh', 'awg_common_en.sh',
           'install_amneziawg.sh', 'install_amneziawg_en.sh',
           'manage_amneziawg.sh', 'manage_amneziawg_en.sh')

hits = []
for name in SCRIPTS:
    body = read(name)
    for m in AWG3_RE.finditer(body):
        hits.append('%s:%d: %s' % (name, body[:m.start()].count('\n') + 1, m.group(1)))
if hits:
    for h in hits:
        sys.stderr.write('  %s\n' % h)
    die('в конфиг пишется параметр третьей линии, а блок фактов обещает профиль '
        'AmneziaWG 2.0 - строку профиля надо переписать в этом скрипте осознанно')

# --- рендер -------------------------------------------------------------
# Обе языковые версии собираются из ОДНИХ И ТЕХ ЖЕ значений, поэтому разойтись
# между RU и EN они физически не могут - расходиться умеют только подписи.
TEXT = {
    'README.md': {
        'note': ['<!-- Собирается scripts/update-facts-block.sh из данных репозитория.',
                 '     Руками не править: check-docs-consistency.sh сверит блок с источниками. -->'],
        'lead': ('**Факты на %s.** Установщик %s. Сроки поддержки ОС проверены по данным '
                 'вендоров %s.' % (released, version, last_verified)),
        'rows': [
            ('Для нового сервера', '%s'),
            ('Тоже поддерживается', '%s'),
            ('Не для новых серверов', '%s - вне обычной поддержки вендора'),
        ],
        'arch': ('Архитектуры', arch_line),
        'module': ('Модуль ядра', 'DKMS из PPA Amnezia; для части ARM - готовые сборки'),
        'profile': ('Профиль конфигурации',
                    'AmneziaWG 2.0 (модуль может быть 3.x - генерируемые конфиги остаются 2.0)'),
    },
    'README.en.md': {
        'note': ['<!-- Generated by scripts/update-facts-block.sh from repository data.',
                 '     Do not edit by hand: check-docs-consistency.sh verifies it against the sources. -->'],
        'lead': ('**Facts as of %s.** Installer %s. OS support dates verified against vendor '
                 'data on %s.' % (released, version, last_verified)),
        'rows': [
            ('For a new server', '%s'),
            ('Also supported', '%s'),
            ('Not for new servers', '%s - past vendor regular support'),
        ],
        'arch': ('Architectures', arch_line),
        'module': ('Kernel module', 'DKMS from the Amnezia PPA; prebuilt packages for some ARM targets'),
        'profile': ('Config profile',
                    'AmneziaWG 2.0 (the kernel module may be 3.x - generated configs stay 2.0)'),
    },
}

ORDER = ('default', 'allowed', 'discouraged')


def render(path):
    t = TEXT[path]
    out = [BEGIN] + t['note'] + [
           t['lead'],
           '',
           '| | |',
           '|---|---|']
    for (label, tmpl), bucket in zip(t['rows'], ORDER):
        out.append('| **%s** | %s |' % (label, tmpl % ', '.join(buckets[bucket])))
    for key in ('arch', 'module', 'profile'):
        label, value = t[key]
        out.append('| **%s** | %s |' % (label, value))
    out.append(END)
    return '\n'.join(out)


# --- запись или сверка --------------------------------------------------
failed = 0
for path in ('README.md', 'README.en.md'):
    body = read(path)
    i = body.find(BEGIN)
    j = body.find(END)
    if i < 0 or j < 0:
        die('в %s нет маркеров %s / %s - блок фактов вставляется между ними'
            % (path, BEGIN, END))
    if j < i:
        die('в %s маркер конца стоит раньше маркера начала' % path)
    if body.count(BEGIN) != 1 or body.count(END) != 1:
        die('в %s маркеров больше одной пары' % path)

    current = body[i:j + len(END)]
    wanted = render(path)
    if current == wanted:
        continue

    if MODE == 'check':
        import difflib
        sys.stderr.write('  %s: блок фактов разошёлся с источниками\n' % path)
        for line in difflib.unified_diff(current.split('\n'), wanted.split('\n'),
                                         fromfile='%s (сейчас)' % path,
                                         tofile='%s (должно быть)' % path, lineterm=''):
            sys.stderr.write('    %s\n' % line)
        failed = 1
    else:
        # newline='\n' обязателен: .gitattributes держит .md в LF, а текстовый
        # режим на Windows иначе перепишет ВЕСЬ файл в CRLF и даст диff на 770
        # строк вместо десяти.
        io.open(path, 'w', encoding='utf-8', newline='\n').write(
            body[:i] + wanted + body[j + len(END):])
        sys.stdout.write('обновлён блок фактов: %s\n' % path)

if failed:
    sys.stderr.write('  почини командой: bash scripts/update-facts-block.sh\n')
    sys.exit(1)

if MODE == 'check':
    sys.stdout.write('блок фактов совпадает с источниками (%s, релиз %s, ОС сверены %s)\n'
                     % (version, released, last_verified))
PYEOF
