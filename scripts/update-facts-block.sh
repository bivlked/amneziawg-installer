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
#   bash scripts/update-facts-block.sh --write   # переписать блок в README
#   bash scripts/update-facts-block.sh --check   # только сверить, ничего не писать
#
# Режим --check вызывается из scripts/check-docs-consistency.sh, то есть идёт и
# в CI (docs-check.yml), и в preflight перед тегом.

set -o pipefail

# AWG_FACTS_ROOT существует ради тестов: они собирают из репозитория временную
# копию нужных файлов и портят её, не трогая рабочее дерево. В обычной работе
# переменная не задаётся, и корнем становится сам репозиторий.
ROOT="${AWG_FACTS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# Пустой ROOT проверяется ОТДЕЛЬНО: `cd ""` в bash это no-op с кодом 0, поэтому
# одного `|| exit 1` мало - упавшая подстановка молча оставляла бы нас в чужом
# рабочем каталоге.
if [[ -z "$ROOT" ]]; then
    echo "не удалось определить корень репозитория" >&2
    exit 2
fi
cd "$ROOT" || exit 2

# 🔴 ЗАПИСЬ ТОЛЬКО ПО ЯВНОМУ --write, вызов без аргументов - ОШИБКА.
# Дефолт "без аргументов = писать" стоил бы дорого: чекер зовёт этот скрипт с
# --check, и потеря одного токена в вызове превращала проверку в тихую правку
# рабочего дерева прямо в CI, с бодрым PASS в придачу. Теперь такая опечатка
# ничего не пишет и громко падает.
MODE=""
case "${1:-}" in
    --check)   MODE="check" ;;
    --write)   MODE="write" ;;
    -h|--help) sed -n '/^# Использование:/,/^$/p' "${BASH_SOURCE[0]}"; exit 0 ;;
    "")        echo "нужен режим: --check (сверить) или --write (переписать блок)" >&2; exit 2 ;;
    *)         echo "неизвестный аргумент: $1 (ожидается --check или --write)" >&2; exit 2 ;;
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
# Источник тот же, что у соседней проверки версии: SCRIPT_VERSION в
# install-скрипте.
# ⚠️ Не рассчитывать, что рассинхрон версий между скриптами поймает CI:
# check-docs-consistency.sh сверяет SCRIPT_VERSION из install_amneziawg.sh с
# бейджами README и заголовками changelog, а согласованность ЧЕТЫРЁХ скриптов
# между собой (в awg_common*.sh переменной нет вовсе, там только заголовок
# "# Версия:") проверяет preflight-check.sh, который в CI не запускается.
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
# Разбор ОТДЕЛЁН от сверки: непрочитанная матрица это ошибка ФОРМАТА, а не
# расхождение блока с источниками. Без этого битый JSON уходил трейсбеком тем же
# кодом 1, и вызывающая проверка отправляла читателя пересобирать README вместо
# того, чтобы чинить файл.
try:
    matrix = json.loads(read(MATRIX))
    platforms = matrix['platforms']
    if not isinstance(platforms, list) or not platforms:
        raise ValueError('platforms пуст или не список')
except SystemExit:
    raise
except Exception as e:
    die('%s не прошёл формат: %s: %s' % (MATRIX, type(e).__name__, e))

last_verified = matrix.get('verification', {}).get('last_verified')
if not re.match(r'^\d{4}-\d{2}-\d{2}$', last_verified or ''):
    die('verification.last_verified в %s не дата вида YYYY-MM-DD: %r'
        % (MATRIX, last_verified))

OS_LABEL = {'ubuntu': 'Ubuntu', 'debian': 'Debian'}
buckets = {'default': [], 'allowed': [], 'discouraged': []}

for p in platforms:
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
    ver = p.get('version')
    if not isinstance(ver, str) or not ver.strip():
        die('%s не прошёл формат: version у %r не непустая строка: %r'
            % (MATRIX, pid, ver))
    buckets[policy].append('%s %s' % (OS_LABEL[family], ver))

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

# --- профиль конфигурации: утверждение, привязанное к коду, а не к данным ----
# Литералов в блоке три: строка про модуль ядра, "x86_64" в архитектурах и эта.
# Из них только эта поддаётся машинной привязке, и она же самая ломкая, поэтому
# сторож ставится именно сюда:
# если в шаблон конфига попадёт параметр третьей линии, блок начнёт обещать
# неправду, и генератор обязан остановиться, а не молча собрать старый текст.
#
# Форм записи в конфиг у нас ДВЕ, и ловить надо обе:
#   1. литерал в heredoc-шаблоне  - так лежат Jc/S1/H1;
#   2. `echo "Имя = ..." >> "$tmpfile"` - так пишутся ОПЦИОНАЛЬНЫЕ I1-I5
#      (awg_common.sh, около 1341 и 1560).
# 🔴 Вторая важнее первой: HeaderProtectionKey тоже опционален, значит его
# добавят ровно по образцу I1. Первая редакция этой проверки знала только форму
# 1, то есть пропускала самый вероятный способ появления параметра 3.x, а тест
# на ложную тревогу закреплял форму 2 как норму. Нашло ревью 30 aug.
#
# ⚠️ Граница названа честно: параметр, чьё ИМЯ собирается из переменной, сюда не
# попадёт. Сужение осознанное - широкий поиск по именам даёт ложные срабатывания
# на перечнях параметров (awg_common.sh:1740) и на маскировании секретов в
# диагностическом отчёте (install_amneziawg.sh:2603), где имена законны.
# 🔴 Набор обязан совпадать с тем, что перечисляет ADVANCED.md (раздел про
# параметры 3.0, таблица из СЕМИ ключей плюс RandomTrailers и DisableCookies из
# 3.1). Там же стоит утверждение, которое этот сторож и защищает: "Установщик не
# задаёт ни один из семи". Первая редакция знала пять имён из девяти, то есть
# охраняла утверждение уже, чем оно сформулировано - например KeepaliveTimeout,
# который как раз просится в конфиг диапазоном, прошёл бы молча. Нашло ревью
# 30 aug. Меняешь таблицу в ADVANCED.md - поправь и здесь.
AWG3_PARAMS = ('HeaderProtectionKey', 'ContentPaddingAddition', 'RekeyAfterTime',
               'RekeyTimeout', 'RejectAfterTime', 'KeepaliveTimeout',
               'MaxHandshakeAttempts',          # семь ключей 3.0
               'RandomTrailers', 'DisableCookies')  # добавка 3.1
AWG3_NAMES = '|'.join(AWG3_PARAMS)
AWG3_RE = re.compile(
    r'^[ \t]*(%s)[ \t]*='                      # форма 1: литерал в шаблоне
    r'|(?:echo|printf)[^"\n]*"[ \t]*(%s)[ \t]*='   # форма 2: запись строкой
    % (AWG3_NAMES, AWG3_NAMES), re.M)
SCRIPTS = ('awg_common.sh', 'awg_common_en.sh',
           'install_amneziawg.sh', 'install_amneziawg_en.sh',
           'manage_amneziawg.sh', 'manage_amneziawg_en.sh')

hits = []
for name in SCRIPTS:
    body = read(name)
    for m in AWG3_RE.finditer(body):
        hits.append('%s:%d: %s' % (name, body[:m.start()].count('\n') + 1,
                                   m.group(1) or m.group(2)))
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
                 'вендоров на %s.' % (released, version, last_verified)),
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
            ('Not for new servers', '%s - no longer under standard vendor support'),
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
        head, tail = body[:i], body[j + len(END):]
        new_body = head + wanted + tail

        # 🔴 Самопроверка ДО записи: всё вне маркеров обязано уцелеть побайтово.
        # Описка в срезах схлопнула бы README с восьми сотен строк до одного
        # блока, и ни --check, ни тесты этого бы не заметили - оба смотрят
        # ТОЛЬКО на текст между маркерами. Нашло ревью 30 aug.
        if not (new_body.startswith(head) and new_body.endswith(tail)):
            die('внутренняя ошибка: запись %s потеряла бы текст вне маркеров' % path)

        # Запись атомарная (temp + replace), как предписывает конвенция проекта:
        # прежняя форма усекала файл ДО записи, и отказ на середине оставлял
        # README пустым, а отказ на втором файле - репозиторий в половинчатом
        # состоянии.
        #
        # newline='\n' обязателен: .gitattributes держит .md в LF, а текстовый
        # режим на Windows иначе перепишет ВЕСЬ файл в CRLF и даст диff на все
        # восемь сотен строк вместо десяти.
        tmp = path + '.facts-tmp'
        try:
            io.open(tmp, 'w', encoding='utf-8', newline='\n').write(new_body)
            os.replace(tmp, path)
        except Exception as e:
            if os.path.exists(tmp):
                os.remove(tmp)
            die('не удалось записать %s: %s: %s' % (path, type(e).__name__, e))
        sys.stdout.write('обновлён блок фактов: %s\n' % path)

if failed:
    sys.stderr.write('  почини командой: bash scripts/update-facts-block.sh --write\n')
    sys.exit(1)

if MODE == 'check':
    sys.stdout.write('блок фактов совпадает с источниками (%s, релиз %s, ОС сверены %s)\n'
                     % (version, released, last_verified))
PYEOF
