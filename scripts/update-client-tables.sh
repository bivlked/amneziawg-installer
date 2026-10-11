#!/usr/bin/env bash
#
# Собирает в ADVANCED.md и ADVANCED.en.md две таблицы из машиночитаемых данных и
# проверяет, что записанное в файлах совпадает с источниками:
#
#   таблица клиентов (какой клиент понимает 3.1)  -> docs/clients-matrix.json
#   таблица хостов (какое поколение получает      -> docs/support-matrix.json (stock_kernel)
#   новая установка на какой системе)               + ответы проверки шага 0 установщика
#
# ЗАЧЕМ. Клиенты переходят на 3.1 раз в несколько дней, и рукописная таблица с
# датой врёт ровно с того дня, когда её забыли обновить, а выглядит при этом
# достовернее обычного текста. Здесь у каждой строки есть основание (откуда это
# известно) и дата проверки, обе локали собираются из одних значений, а возраст
# строк сверяется с датой релиза.
#
# 🔴 СВЕЖЕСТЬ СЧИТАЕТСЯ ОТ ДАТЫ РЕЛИЗА, А НЕ ОТ ЧАСОВ. Дата берётся из заголовка
# CHANGELOG для текущего SCRIPT_VERSION. Между релизами опорная дата не движется,
# поэтому со временем проверка не краснеет; когда готовится релиз (новая версия
# и её дата вписаны), строки старше freshness_days роняют проверку, и тег не
# уходит со старой таблицей. Проверка по часам краснела бы на чужих PR через месяц после
# снимка и приучала бы не верить ей (тот же довод, что у блока фактов). Часы
# используются только как ВЕРХНЯЯ граница: дата проверки из будущего (опечатка
# в годе) навсегда отключила бы свежесть, а со временем эта граница не краснеет.
#
# 🔴 ТАБЛИЦА ХОСТОВ СТРОИТСЯ ИЗ ПОВЕДЕНИЯ, А НЕ ИЗ ТЕКСТА. Из обоих установщиков
# вырезаются функции awg31_environment_blocker и _kernel_supports_awg3, и
# стадия pre вызывается на штатном ядре каждой системы для x86_64 (amd64) и
# ARM (arm64, armhf). Ячейка - это её ответ: пусто = 3.1, иначе 2.0 с кодом.
# Сверка по регуляркам пропускала бы перевёрнутое сравнение и ветку ARM, которая
# перестала возвращаться (ревью 11 oct). Шаг 3 (утилиты и модуль) этим не
# проверяется: он зависит от того, что приедет на машину, и описан в сноске
# (её утверждения про ARM сверяются с той же функцией, коды шага 3 - с ней,
# с решением об автооткате _awg31_post_fallback_allowed, с наличием его
# вызова на переменных гейта шага 3 и с вызовом стадии post). Платформы
# с lifecycle unreleased в таблицу не попадают.
#
# Использование:
#   bash scripts/update-client-tables.sh --write   # переписать обе таблицы в ADVANCED
#   bash scripts/update-client-tables.sh --check   # только сверить, ничего не писать
#
# Коды выхода: 0 - таблицы совпадают (или переписаны); 1 - таблица разошлась с
# данными, строки устарели к релизу или --write не смог записать файлы; 2 -
# проверить не удалось: нет python или bash, неверный вызов, файл не прочитан,
# данные или маркеры не прошли формат, проверка шага 0 из установщиков не
# отработала или ответила по-разному в RU и EN, утверждения сноски (порог,
# ARM, коды шага 3 и их полный список, автооткат и его вызов, вызов стадии
# post) не подтвердились, непредвиденная ошибка сборщика; при --write также:
# от прошлого запуска остался *.tables-restore или *.tables-restore.incomplete.
#
# Режим --check вызывается из scripts/check-docs-consistency.sh, то есть идёт и
# в CI (docs-check.yml), и в preflight перед тегом.

set -o pipefail

# AWG_CLIENTS_ROOT существует ради тестов: они портят временную копию файлов, не
# трогая рабочее дерево. В обычной работе корень - сам репозиторий (и
# check-docs-consistency.sh сбрасывает переменную, чтобы забытый export не увёл
# проверку на чужое дерево).
ROOT="${AWG_CLIENTS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if [[ -z "$ROOT" ]]; then
    echo "не удалось определить корень репозитория" >&2
    exit 2
fi
cd "$ROOT" || exit 2

# Запись только по явному --write: вызов без аргументов из чекера не должен
# превращаться в тихую правку рабочего дерева.
MODE=""
case "${1:-}" in
    --check)   MODE="check" ;;
    --write)   MODE="write" ;;
    -h|--help) sed -n '/^# Использование:/,/^$/p' "${BASH_SOURCE[0]}"; exit 0 ;;
    "")        echo "нужен режим: --check (сверить) или --write (переписать таблицы)" >&2; exit 2 ;;
    *)         echo "неизвестный аргумент: $1 (ожидается --check или --write)" >&2; exit 2 ;;
esac

# python выбирается запуском, а не наличием в PATH: на Windows `python3` бывает
# заглушкой Microsoft Store. Тот же приём, что в update-facts-block.sh.
PY=""
for _c in python3 python; do
    if printf 'print(1)' | "$_c" - >/dev/null 2>&1; then PY="$_c"; break; fi
done
if [[ -z "$PY" ]]; then
    echo "не найден рабочий python (нужен для чтения docs/clients-matrix.json)" >&2
    exit 2
fi

# Python вызывает функции установщика через ЭТОТ ЖЕ bash. Путь передаётся явно:
# на Windows `bash` в PATH питона может оказаться WSL-обёрткой из System32, а
# POSIX-путь Git Bash питону непонятен, поэтому он переводится через cygpath.
AWG_BASH="$BASH"
if command -v cygpath >/dev/null 2>&1; then
    AWG_BASH="$(cygpath -w "$BASH")" || AWG_BASH=""
fi
if [[ -z "$AWG_BASH" ]]; then
    echo "не удалось определить путь к bash для вызова проверки шага 0" >&2
    exit 2
fi
export AWG_BASH

"$PY" - "$MODE" <<'PYEOF'
# -*- coding: utf-8 -*-
import datetime
import io
import json
import os
import re
import subprocess
import sys

MODE = sys.argv[1]
CLIENTS = 'docs/clients-matrix.json'
MATRIX = 'docs/support-matrix.json'
INSTALLERS = ('install_amneziawg.sh', 'install_amneziawg_en.sh')
DOCS = ('ADVANCED.md', 'ADVANCED.en.md')
LANG = {'ADVANCED.md': 'ru', 'ADVANCED.en.md': 'en'}
BLOCKS = ('clients', 'hosts')
MAX_FRESHNESS_DAYS = 90


def _unexpected(kind, value, tb):
    # Непредвиденное исключение (битая дата, ошибка рендера) - это «проверить не
    # удалось», а не «таблица разошлась»: без перехвата python вышел бы кодом 1,
    # и чекер отправил бы читателя пересобирать таблицу.
    import traceback
    traceback.print_exception(kind, value, tb)
    sys.stderr.write('  внутренняя ошибка сборщика: %s: %s\n' % (kind.__name__, value))
    sys.exit(2)


sys.excepthook = _unexpected


def die(msg):
    # Расхождение таблицы с данными, устаревание или сбой записи: код 1.
    sys.stderr.write('  %s\n' % msg)
    sys.exit(1)


def unverified(msg):
    # Проверить не удалось (нет файла, формат, маркеры): код 2, чтобы чекер не
    # отправил читателя пересобирать таблицу вместо починки входа.
    sys.stderr.write('  %s\n' % msg)
    sys.exit(2)


def read(path):
    if not os.path.isfile(path):
        unverified('нет %s' % path)
    # newline='' - читать байты переводов строк как есть: иначе CRLF внутри
    # маркеров совпал бы с ожидаемым LF, а --write молча переписал бы CRLF вне их.
    try:
        return io.open(path, encoding='utf-8', newline='').read()
    except Exception as e:
        unverified('не прочитан %s: %s: %s' % (path, type(e).__name__, e))


def as_date(value, what):
    if not isinstance(value, str) or not re.match(r'^\d{4}-\d{2}-\d{2}\Z', value):
        raise ValueError('%s не дата вида YYYY-MM-DD: %r' % (what, value))
    return datetime.date.fromisoformat(value)


# --- дата релиза текущей версии -------------------------------------------
# Тот же источник, что у блока фактов: SCRIPT_VERSION и заголовок CHANGELOG.
m = re.search(r'^SCRIPT_VERSION="([^"]+)"', read('install_amneziawg.sh'), re.M)
if not m:
    unverified('не нашёл SCRIPT_VERSION в install_amneziawg.sh')
version = m.group(1)
m = re.search(r'^## \[%s\] - (\d{4}-\d{2}-\d{2})\s*$' % re.escape(version),
              read('CHANGELOG.md'), re.M)
if not m:
    unverified('в CHANGELOG.md нет заголовка "## [%s] - YYYY-MM-DD" '
               '(свежесть таблицы клиентов считается от даты релиза)' % version)
try:
    released = datetime.date.fromisoformat(m.group(1))
except ValueError as e:
    unverified('дата релиза %s в CHANGELOG.md не дата: %s' % (m.group(1), e))
# Верхняя граница для checked_at - дата по UTC плюс сутки: CI живёт в UTC, а
# восточнее UTC после местной полуночи дата уже следующая, и запись «сегодня»
# иначе выглядела бы в CI датой из будущего.
date_ceiling = datetime.datetime.now(datetime.timezone.utc).date() + datetime.timedelta(days=1)

# --- клиенты: разбор и схема -----------------------------------------------
# Неизвестный ключ - ошибка, а не тишина: опечатка вроде "since_dat" иначе
# молча теряла бы значение, а таблица оставалась бы зелёной.
SUPPORT = ('yes', 'no', 'dev-channel', 'nightly', 'unknown')
BASIS = ('verified-behaviour', 'build-pin', 'vendor-docs', 'inference-from-dates', 'unknown')
ROW_KEYS = {'id', 'name', 'support', 'version', 'version_date', 'since', 'since_date',
            'since_note', 'where', 'basis', 'evidence', 'checked_at'}
REQUIRED = {'id', 'name', 'support', 'version', 'basis', 'evidence', 'checked_at'}
TEXT_KEYS = ('name', 'version', 'since', 'since_note', 'where')
EVIDENCE_KEYS = {'url', 'ref', 'version', 'env'}
# Что обязано стоять в evidence при каждом основании. Без этого «проверено
# поведением» можно было бы записать, не сказав, на какой версии и где.
EVIDENCE_NEEDS = {'verified-behaviour': ('version', 'env'), 'build-pin': ('ref',),
                  'vendor-docs': ('url',), 'inference-from-dates': ('url',), 'unknown': ()}


def text_value(value, what):
    # Текстовое поле - либо одна строка для обеих локалей, либо {"ru": ..., "en": ...}.
    # Вертикальная черта и перевод строки ломают строку таблицы markdown.
    if isinstance(value, str):
        parts = [value]
    elif isinstance(value, dict) and set(value) == {'ru', 'en'}:
        parts = [value['ru'], value['en']]
    else:
        raise ValueError('%s: нужна строка или объект ровно с ключами ru и en: %r' % (what, value))
    for p in parts:
        if not isinstance(p, str) or not p.strip():
            raise ValueError('%s: пустое значение' % what)
        if '|' in p or '\n' in p or '\r' in p:
            raise ValueError('%s: в ячейке таблицы нельзя "|" и перевод строки: %r' % (what, p))


try:
    data = json.loads(read(CLIENTS))
    if data.get('schema_version') != 1:
        raise ValueError('schema_version должен быть 1')
    fresh_days = data.get('freshness_days')
    # Верхний предел: freshness_days = 100000 отключил бы проверку правкой одного
    # числа, заметной только в диффе.
    if (not isinstance(fresh_days, int) or isinstance(fresh_days, bool)
            or not 0 < fresh_days <= MAX_FRESHNESS_DAYS):
        raise ValueError('freshness_days должен быть целым от 1 до %d: %r'
                         % (MAX_FRESHNESS_DAYS, fresh_days))
    rows = data.get('clients')
    if not isinstance(rows, list) or not rows:
        raise ValueError('clients пуст или не список')
    seen = set()
    for r in rows:
        if not isinstance(r, dict):
            raise ValueError('строка clients не объект: %r' % r)
        rid = r.get('id')
        where = 'клиент %r' % rid
        if not isinstance(rid, str) or not rid:
            raise ValueError('у строки нет id: %r' % r)
        if rid in seen:
            raise ValueError('%s повторяется' % where)
        seen.add(rid)
        extra = set(r) - ROW_KEYS
        if extra:
            raise ValueError('%s: неизвестные ключи %s' % (where, ', '.join(sorted(extra))))
        missing = REQUIRED - set(r)
        if missing:
            raise ValueError('%s: нет ключей %s' % (where, ', '.join(sorted(missing))))
        for k in TEXT_KEYS:
            if k in r:
                text_value(r[k], '%s, %s' % (where, k))
        if r['support'] not in SUPPORT:
            raise ValueError('%s: support %r не из %s' % (where, r['support'], SUPPORT))
        if r['basis'] not in BASIS:
            raise ValueError('%s: basis %r не из %s' % (where, r['basis'], BASIS))
        # «Не знаем» не называет поколение: строка без основания не может сказать
        # ни «да», ни «нет», ни «с какой версии».
        if r['basis'] == 'unknown' and r['support'] != 'unknown':
            raise ValueError('%s: basis unknown, а support %r - без основания поколение '
                             'не называется' % (where, r['support']))
        if r['support'] == 'unknown' and any(k in r for k in ('since', 'since_date', 'since_note')):
            raise ValueError('%s: support unknown, а since задан - версия, с которой есть 3.1, '
                             'тоже называет поколение' % where)
        ev = r['evidence']
        if not isinstance(ev, dict):
            raise ValueError('%s: evidence не объект' % where)
        if set(ev) - EVIDENCE_KEYS:
            raise ValueError('%s: неизвестные ключи evidence %s'
                             % (where, ', '.join(sorted(set(ev) - EVIDENCE_KEYS))))
        for k in EVIDENCE_NEEDS[r['basis']]:
            if not isinstance(ev.get(k), str) or not ev[k].strip():
                raise ValueError('%s: при basis %s в evidence обязателен непустой %s'
                                 % (where, r['basis'], k))
        if 'url' in ev and not re.match(r'^https://\S+\Z', ev['url']):
            raise ValueError('%s: evidence.url не https-ссылка: %r' % (where, ev['url']))
        checked = as_date(r['checked_at'], '%s, checked_at' % where)
        if checked > date_ceiling:
            raise ValueError('%s: checked_at %s в будущем - так проверка свежести не сработала '
                             'бы никогда' % (where, checked))
        for k in ('version_date', 'since_date'):
            if k in r and as_date(r[k], '%s, %s' % (where, k)) > checked:
                # Версию, вышедшую позже проверки, увидеть было нельзя.
                raise ValueError('%s: %s позже checked_at' % (where, k))
        for k in ('since_note', 'since_date'):
            if k in r and 'since' not in r:
                raise ValueError('%s: %s без since - значение выпало бы из таблицы' % (where, k))
except SystemExit:
    raise
except Exception as e:
    unverified('%s не прошёл формат: %s' % (CLIENTS, e))

# --- свежесть ----------------------------------------------------------------
stale = []
for r in rows:
    age = (released - datetime.date.fromisoformat(r['checked_at'])).days
    if age > fresh_days:
        stale.append('%s: проверен %s, это за %d дн. до релиза %s %s (предел %d)'
                     % (r['id'], r['checked_at'], age, version, released, fresh_days))
if stale:
    for s in stale:
        sys.stderr.write('  %s\n' % s)
    die('таблица клиентов устарела к релизу: перепроверьте строки по их источникам, '
        'обновите checked_at в %s и пересоберите таблицы (--write)' % CLIENTS)

# --- хосты: ответы проверки шага 0 из обоих установщиков -----------------------
BASH = os.environ.get('AWG_BASH')
if not BASH:
    unverified('AWG_BASH не задан: сборщик запускается через свою bash-обёртку')
FUNCS = ('_kernel_supports_awg3', 'awg31_environment_blocker')
SENTINEL = '@@gate-done@@'
STEP3_CODES = ('tools_old', 'module_line2', 'module_probe_failed')


# Определения функций и присваивания переменных считаются С ЗАПАСОМ: любое
# `name()` или `function name`, любое `VAR=` или `VAR+=` вне строк-комментариев,
# где бы оно ни стояло (после `then`, `;`, внутри if, с readonly/declare).
# Установщик исполняет последнее определение или присваивание, а вырезается
# первое, поэтому недосчёт означал бы проверку не той копии; лишнее совпадение
# даёт громкий код 2 (для `VAR+=` «последнее» значит «дописанное», вывод тот
# же). Граница проверки - то, что не видно: определения через eval, source и
# имя, перенесённое обратным слешем; присваивания через printf -v, read,
# ${VAR:=...} и unset.
def _nocomment(body):
    return re.sub(r'^[ \t]*#.*$', '', body, flags=re.M)


def cut_function(name, body, fn):
    n = re.escape(fn)
    defs = re.findall(r'(?<![\w-])%s[ \t]*\([ \t]*\)|\bfunction[ \t]+%s(?![\w-])' % (n, n),
                      _nocomment(body))
    found = re.findall(r'^%s\(\) \{\n.*?^\}\n' % n, body, re.M | re.S)
    if len(defs) != 1 or len(found) != 1:
        unverified('%s: функция %s определена %d раз (в нужной форме %d), нужна ровно одна'
                   % (name, fn, len(defs), len(found)))
    return found[0]


def cut_assignment(name, body, var):
    n = re.escape(var)
    sets = re.findall(r'(?<![\w$-])%s(?:\[[^]\n]*\])?\+?=' % n, _nocomment(body))
    found = re.findall(r'^%s="([^"\n]*)"[ \t]*$' % n, body, re.M)
    if len(sets) != 1 or len(found) != 1:
        unverified('%s: присваивание %s найдено %d раз (в нужной форме %d), нужно ровно одно'
                   % (name, var, len(sets), len(found)))
    return '%s="%s"\n' % (var, found[0]), found[0]


def gate_source(name):
    body = read(name)
    return ''.join(cut_function(name, body, fn) for fn in FUNCS)


def gate(src, name, arch, kver):
    # Пустой ответ = 3.1, иначе код причины. Защиты от пустоты по другой причине:
    # stderr обязан быть пуст («command not found» от недостающей функции), метка
    # после вызова обязана дойти (ранний exit в вырезанном куске), окружение
    # минимальное (BASH_ENV и SHELLOPTS не наследуются), код идёт через stdin, а
    # не аргументом: разбор командной строки на Windows мог бы его исказить.
    # Метка несёт код возврата функции: установщик принимает ответ только при
    # коде 0 (ненулевой код - отказ даже при пустом выводе, автооткат на 2.0
    # тоже требует 0), поэтому и сборщик считает его сбоем, а не ответом 3.1.
    script = (src + 'awg31_environment_blocker pre "$1" "$2"\n'
              'printf "%s%%d" "$?"\n' % SENTINEL)
    try:
        p = subprocess.run([BASH, '-s', arch, kver], input=script.encode('utf-8'),
                           capture_output=True, timeout=30,
                           env={'PATH': os.environ.get('PATH', ''), 'LC_ALL': 'C'})
    except Exception as e:
        unverified('%s: не удалось вызвать проверку шага 0 через %s: %s' % (name, BASH, e))
    out, err = p.stdout.decode('utf-8', 'replace'), p.stderr.decode('utf-8', 'replace')
    m = re.match(r'^([a-z0-9_]*)%s(\d+)\Z' % re.escape(SENTINEL), out)
    ok = bool(m) and m.group(2) == '0'
    out = m.group(1) if m else out
    if p.returncode != 0 or err.strip() or not ok:
        unverified('%s: проверка шага 0 (%s, %s) ответила rc=%d, вывод %r, stderr %r'
                   % (name, arch, kver, p.returncode, out, err.strip()))
    return out


try:
    platforms = json.loads(read(MATRIX))['platforms']
    stock = []
    # lifecycle - производное поле, но его сверяет с датами проверка 4b в
    # check-docs-consistency.sh, поэтому здесь ему можно верить.
    for p in platforms:
        if p.get('lifecycle') == 'unreleased':
            continue
        kv = p.get('stock_kernel')
        if not isinstance(kv, str) or not re.match(r'^\d+\.\d+\Z', kv):
            raise ValueError('stock_kernel у %r не вида N.N: %r' % (p.get('id'), kv))
        label = {'ubuntu': 'Ubuntu', 'debian': 'Debian'}[p['os']]
        stock.append(('%s %s' % (label, p['version']), kv))
    if not stock:
        raise ValueError('не осталось ни одной вышедшей платформы')
except SystemExit:
    raise
except Exception as e:
    unverified('%s не прошёл формат: %s: %s' % (MATRIX, type(e).__name__, e))

FALLBACK_FUNCS = ('_awg31_code_in', '_awg31_post_fallback_allowed')


def fallback_allowed(name, code):
    body = read(name)
    parts = [cut_assignment(name, body, var)[0]
             for var in ('AWG31_FALLBACK_PRE_CODES', 'AWG31_FALLBACK_POST_CODES')]
    parts += [cut_function(name, body, fn) for fn in FALLBACK_FUNCS]
    script = (''.join(parts) + '_awg_install_state() { echo 2; }\n'
              'AWG_PROTOCOL_SOURCE=default AWG_INSTALL_STATE_AT_START=0 CONFIG_FILE=/nonexistent\n'
              '_awg31_post_fallback_allowed "$1" 0\nprintf "%s%%d" "$?"\n' % SENTINEL)
    try:
        p = subprocess.run([BASH, '-s', code], input=script.encode('utf-8'), capture_output=True,
                           timeout=30, env={'PATH': os.environ.get('PATH', ''), 'LC_ALL': 'C'})
    except Exception as e:
        unverified('%s: не удалось вызвать проверку автоотката: %s' % (name, e))
    out, err = p.stdout.decode('utf-8', 'replace'), p.stderr.decode('utf-8', 'replace')
    m = re.match(r'^%s(\d+)\Z' % re.escape(SENTINEL), out)
    if p.returncode != 0 or err.strip() or not m:
        unverified('%s: проверка автоотката (%s) ответила rc=%d, вывод %r, stderr %r'
                   % (name, code, p.returncode, out, err.strip()))
    return m.group(1) == '0'


answers = {}
threshold = None
for name in INSTALLERS:
    src = gate_source(name)
    rows_h = []
    for label, kv in stock:
        k = kv + '.0'
        arm = {gate(src, name, a, k) for a in ('arm64', 'armhf')}
        if len(arm) != 1:
            unverified('%s: arm64 и armhf на ядре %s получают разное: %s - столбец ARM '
                       'это не выражает' % (name, kv, sorted(arm)))
        rows_h.append((label, kv, gate(src, name, 'amd64', k), arm.pop()))
    answers[name] = rows_h
    # Порог для сноски - литерал из функции, подтверждённый поведением: на нём
    # x86_64 получает 3.1, на версии чуть ниже (минорная минус один, при
    # минорной 0 - предыдущая мажорная с минорной 99) - нет.
    lit = re.findall(r'^[ \t]*local min_maj=(\d+) min_min=(\d+)[ \t]*$', src, re.M)
    if len(lit) != 1:
        unverified('%s: порог ядра (local min_maj=N min_min=N) найден %d раз' % (name, len(lit)))
    maj, mnr = int(lit[0][0]), int(lit[0][1])
    below = '%d.%d.0' % ((maj, mnr - 1) if mnr > 0 else (maj - 1, 99))
    if gate(src, name, 'amd64', '%d.%d.0' % (maj, mnr)) != '' or (
            gate(src, name, 'amd64', below) == ''):
        unverified('%s: порог %d.%d в тексте не совпадает с поведением проверки' % (name, maj, mnr))
    if threshold not in (None, (maj, mnr)):
        unverified('порог ядра в установщиках разный: %s и %s' % (threshold, (maj, mnr)))
    threshold = (maj, mnr)
    # Сноска утверждает «на ARM 2.0 при любом ядре» и называет коды шага 3:
    # оба утверждения сверяются с поведением установщика, а не берутся на веру.
    for kv in ('%d.%d.0' % threshold, '99.0.0'):
        if {gate(src, name, a, kv) for a in ('arm64', 'armhf')} != {'arm'}:
            unverified('%s: на ARM с ядром %s ответ не arm, а сноска обещает 2.0 при любом ядре'
                       % (name, kv))
    # Переход на 2.0 по кодам шага 3 решает _awg31_post_fallback_allowed: она
    # вызывается на каждом коде сноски (состояние заглушено как новая установка
    # без следов шага 6), и каждый обязан дать «можно». Контроль: internal_error
    # обязан дать «нельзя», иначе проба ничего не различает. Список кодов шага 3
    # обязан совпадать со сноской целиком: она называет его полностью. И решение
    # обязано вызываться на результате гейта шага 3 ($_awg31_blocker,
    # $_awg31_rc). Граница: проводку внутри установщика (условие перед &&,
    # вызов гейта из шага 3, затенение через local, unset) сборщик не сверяет -
    # это поведение установщика, его держат тесты test_awg31_fallback.bats.
    post = set(cut_assignment(name, read(name), 'AWG31_FALLBACK_POST_CODES')[1].split())
    if post != set(STEP3_CODES):
        unverified('%s: AWG31_FALLBACK_POST_CODES = %s, а сноска называет %s'
                   % (name, ' '.join(sorted(post)), ', '.join(STEP3_CODES)))
    if not re.search(r'^[^#\n]*&&[ \t]*_awg31_post_fallback_allowed "\$_awg31_blocker" '
                     r'"\$_awg31_rc"', read(name), re.M):
        unverified('%s: решение об автооткате не вызывается на результате гейта шага 3, '
                   'а сноска его обещает' % name)
    for code in STEP3_CODES + ('internal_error',):
        want = code != 'internal_error'
        if fallback_allowed(name, code) != want:
            unverified('%s: автооткат на 2.0 по коду %s %s, а сноска обещает переход на 2.0 '
                       'по кодам %s' % (name, code, 'не разрешён' if want else 'разрешён',
                                         ', '.join(STEP3_CODES)))
    if not re.search(r'^[^#\n]*\$\(awg31_environment_blocker post\)', read(name), re.M):
        unverified('%s: стадия post не вызывается, а сноска описывает шаг 3' % name)
    # Код засчитывается только как printf вне комментария и целиком
    # (tools_old_x не считается); строка, где до printf стоит `#` (например
    # `${#x}`), тоже не засчитается, и проверка уйдёт в код 2 - громко.
    for code in STEP3_CODES:
        if not re.search(r"^[ \t]*[^#\n]*\bprintf '%s'(?![\w'])" % code, src, re.M):
            unverified('%s: кода %s нет в проверке, а сноска его называет' % (name, code))
if answers[INSTALLERS[0]] != answers[INSTALLERS[1]]:
    unverified('проверка шага 0 в RU и EN установщиках отвечает по-разному: %s / %s'
               % (answers[INSTALLERS[0]], answers[INSTALLERS[1]]))
hosts = answers[INSTALLERS[0]]

# --- рендер ------------------------------------------------------------------
MONTHS = {
    'ru': ('янв', 'фев', 'мар', 'апр', 'мая', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'),
    'en': ('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'),
}
MONTHS_LONG = {
    'ru': ('января', 'февраля', 'марта', 'апреля', 'мая', 'июня', 'июля', 'августа',
           'сентября', 'октября', 'ноября', 'декабря'),
    'en': ('January', 'February', 'March', 'April', 'May', 'June', 'July', 'August',
           'September', 'October', 'November', 'December'),
}


def fmt(iso, lang, long=False):
    d = datetime.date.fromisoformat(iso)
    return '%d %s %d' % (d.day, (MONTHS_LONG if long else MONTHS)[lang][d.month - 1], d.year)


def loc(value, lang):
    return value if isinstance(value, str) else value[lang]


T = {
    'ru': {
        'note': '<!-- Собирается scripts/update-client-tables.sh из docs/clients-matrix.json.\n'
                '     Руками не править: check-docs-consistency.sh сверит таблицу с файлом. -->',
        'intro': 'Снято {date} со страниц релизов, магазинов и кода проектов, проверить можно там же. '
                 'Клиенты двигаются раз в несколько дней, поэтому у строк стоят даты. «С какой '
                 'версии» - по заметкам к выпускам и страницам самих проектов, «Основание» - откуда '
                 'известно поколение.',
        'intro_mixed': ' Строки, проверенные позже, несут свою дату в столбце «Основание».',
        'head': '| Клиент | 3.1 | Версия на {short} | С какой версии 3.1 | Где брать | Основание |',
        'support': {'yes': 'да', 'no': 'нет', 'dev-channel': 'только в канале разработки',
                    'nightly': 'в ежедневном фиде, без тега', 'unknown': 'не знаем'},
        'basis': {'verified-behaviour': 'проверено на профиле 3.1', 'build-pin': 'код проекта',
                  'vendor-docs': 'страницы проекта', 'inference-from-dates': 'вывод по датам',
                  'unknown': 'нет'},
        'hnote': '<!-- Собирается scripts/update-client-tables.sh из docs/support-matrix.json и\n'
                 '     ответов проверки шага 0 в установщике. Руками не править. -->',
        'hintro': 'Поколение новой установки без `--protocol` по системам, на штатном ядре:',
        'hhead': '| Система | Штатное ядро | x86_64 | ARM |',
        'ok': '3.1', 'code': '2.0, код `{c}`',
        'hfoot': 'Установщик смотрит на работающее ядро, а не на штатное: система на x86_64, '
                 'загруженная с ядром {k} или новее (например, из backports), получает 3.1; на ARM '
                 'поколение 2.0 при любом ядре. Это проверка шага 0. На шаге 3 установщик может '
                 'перейти на 2.0 и на подходящей системе, если утилиты `awg` или модуль не понимают '
                 'третью линию или проверить модуль не удалось (коды {codes}).',
    },
    'en': {
        'note': '<!-- Generated by scripts/update-client-tables.sh from docs/clients-matrix.json.\n'
                '     Do not edit by hand: check-docs-consistency.sh verifies it against the file. -->',
        'intro': 'Recorded {date} from the release pages, the app stores and the projects\' code, '
                 'and you can check the same way. Clients move every few days, so the rows carry '
                 'dates. "3.1 since" comes from the projects\' own release notes and pages, "Basis" '
                 'says how the generation is known.',
        'intro_mixed': ' Rows checked later carry their own date in the "Basis" column.',
        'head': '| Client | 3.1 | Version on {short} | 3.1 since | Where to get it | Basis |',
        'support': {'yes': 'yes', 'no': 'no', 'dev-channel': 'development channel only',
                    'nightly': 'in the daily feed, no tag', 'unknown': 'unknown'},
        'basis': {'verified-behaviour': 'tested on a 3.1 profile', 'build-pin': 'project code',
                  'vendor-docs': 'project pages', 'inference-from-dates': 'inferred from dates',
                  'unknown': 'none'},
        'hnote': '<!-- Generated by scripts/update-client-tables.sh from docs/support-matrix.json and\n'
                 '     the answers of the installer step 0 check. Do not edit by hand. -->',
        'hintro': 'The generation a new install gets without `--protocol`, by system, on the stock kernel:',
        'hhead': '| System | Stock kernel | x86_64 | ARM |',
        'ok': '3.1', 'code': '2.0, code `{c}`',
        'hfoot': 'The installer looks at the running kernel, not the stock one: a system on x86_64 '
                 'booted with kernel {k} or newer (from backports, for example) gets 3.1; on ARM the '
                 'generation is 2.0 with any kernel. That is the step 0 check. At step 3 the installer '
                 'can also switch to 2.0 on a suitable system when the `awg` tools or the module do '
                 'not understand the third line or the module check itself fails (codes {codes}).',
    },
}

oldest = min(r['checked_at'] for r in rows)
mixed = any(r['checked_at'] != oldest for r in rows)


def render_clients(lang):
    t = T[lang]
    intro = t['intro'].format(date=fmt(oldest, lang, long=True))
    if mixed:
        intro += t['intro_mixed']
    out = [t['note'], intro, '', t['head'].format(short=fmt(oldest, lang)),
           '|---|---|---|---|---|---|']
    for r in rows:
        ver = loc(r['version'], lang)
        if 'version_date' in r:
            ver += ' (%s)' % fmt(r['version_date'], lang)
        if 'since' in r:
            since = loc(r['since'], lang)
            if 'since_date' in r:
                since += ' (%s)' % fmt(r['since_date'], lang)
            if 'since_note' in r:
                since += '; ' + loc(r['since_note'], lang)
        else:
            since = '-'
        basis = t['basis'][r['basis']]
        if r['checked_at'] != oldest:
            basis += ', ' + fmt(r['checked_at'], lang)
        out.append('| %s | %s | %s | %s | %s | %s |' % (
            loc(r['name'], lang), t['support'][r['support']], ver, since,
            loc(r['where'], lang) if 'where' in r else '-', basis))
    return '\n'.join(out)


def cell(code, t):
    return t['ok'] if code == '' else t['code'].format(c=code)


def render_hosts(lang):
    t = T[lang]
    out = [t['hnote'], t['hintro'], '', t['hhead'], '|---|---|---|---|']
    for label, kv, x86, arm in hosts:
        out.append('| %s | %s | %s | %s |' % (label, kv, cell(x86, t), cell(arm, t)))
    out += ['', t['hfoot'].format(k='%d.%d' % threshold,
                                  codes=', '.join('`%s`' % c for c in STEP3_CODES))]
    return '\n'.join(out)


RENDER = {'clients': render_clients, 'hosts': render_hosts}


def spans(body, path):
    # Позиции всех блоков считаются по ИСХОДНОМУ тексту, и блоки не могут
    # пересекаться или вкладываться: прежняя форма искала маркеры уже в частично
    # переписанном тексте, и при вложенных блоках --write дублировал файл и
    # рапортовал успех (ревью 11 oct).
    out = []
    for block in BLOCKS:
        begin, end = '<!-- %s:begin -->' % block, '<!-- %s:end -->' % block
        if body.count(begin) != 1 or body.count(end) != 1:
            unverified('в %s нужна ровно одна пара маркеров %s / %s' % (path, begin, end))
        i, j = body.find(begin), body.find(end)
        if j < i:
            unverified('в %s маркер %s стоит раньше %s' % (path, end, begin))
        out.append((i, j + len(end), block))
    out.sort()
    for (a0, a1, an), (b0, b1, bn) in zip(out, out[1:]):
        if b0 < a1:
            unverified('в %s блоки %s и %s пересекаются' % (path, an, bn))
    return out


# --- сверка, затем запись ------------------------------------------------------
# Оба файла разбираются и проверяются до того, как записан хоть один.
failed = 0
plans = []
for path in DOCS:
    body = read(path)
    pieces, pos = [], 0
    for i, j, block in spans(body, path):
        current = body[i:j]
        begin, end = '<!-- %s:begin -->' % block, '<!-- %s:end -->' % block
        wanted = begin + '\n' + RENDER[block](LANG[path]) + '\n' + end
        if current != wanted and MODE == 'check':
            import difflib
            sys.stderr.write('  %s: таблица %s разошлась с источниками\n' % (path, block))
            for line in difflib.unified_diff(current.split('\n'), wanted.split('\n'),
                                             fromfile='%s (сейчас)' % path,
                                             tofile='%s (должно быть)' % path, lineterm=''):
                sys.stderr.write('    %s\n' % line)
            failed = 1
        pieces += [body[pos:i], wanted]
        pos = j
    pieces.append(body[pos:])
    new_body = ''.join(pieces)
    # Текст вне блоков переносится кусками исходника, поэтому сохраняется по
    # построению; держит это тест cmp после --write.
    if MODE == 'write' and new_body != body:
        plans.append((path, new_body, body))

# Сначала оба временных файла, потом замены: отказ при записи второго файла
# (место, права) не оставляет языки в разных состояниях. Остаётся окно между
# двумя os.replace - один системный вызов.
# Если замена второго файла всё же откажет (на Windows файл бывает занят),
# первый пытаемся вернуть к исходному тексту из памяти тем же путём: временный
# файл с fsync и os.replace. Ошибки уборки временных файлов откат не прерывают.


def put(path, text, suffix):
    # with + flush + fsync: ошибка записи последнего блока (кончилось место)
    # иначе гасилась бы при сборке объекта, и на место встал бы обрезанный файл.
    tmp = path + suffix
    with io.open(tmp, 'w', encoding='utf-8', newline='') as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    return tmp


# Откат возвращает ровно тот текст, из которого строилась новая версия, а не
# перечитанный файл: правка между чтениями иначе молча ушла бы в «исходное».
# Проверяются ОБА документа, а не только те, что надо переписать: после
# неудачного отката первый уже новый и в план не попадает, а его копия цела.
for path in (DOCS if MODE == 'write' else ()):
    for leftover in (path + '.tables-restore', path + '.tables-restore.incomplete'):
        if os.path.exists(leftover):
            unverified('%s остался от прошлого неудачного запуска: разберите его и удалите, '
                       'затем повторите (новый сбой иначе мог бы его перезаписать)' % leftover)
originals = {path: body for path, _, body in plans}
tmps, replaced = [], []
try:
    for path, new_body, _ in plans:
        # Путь регистрируется ДО записи: оборванный на середине временный файл
        # тоже должен уйти при уборке, а не остаться в рабочем дереве.
        tmps.append(path + '.tables-tmp')
        put(path, new_body, '.tables-tmp')
    for path, _, _ in plans:
        os.replace(path + '.tables-tmp', path)
        replaced.append(path)
except Exception as e:
    for tmp in tmps:
        try:
            if os.path.exists(tmp):
                os.remove(tmp)
        except Exception as e3:
            sys.stderr.write('  не удалён временный %s: %s: %s\n' % (tmp, type(e3).__name__, e3))
    restored, lost = [], []
    for path in replaced:
        kept = None
        try:
            kept = put(path, originals[path], '.tables-restore')
            os.replace(kept, path)
            restored.append(path)
        except Exception as e2:
            lost.append(path)
            partial = None
            if kept is None and os.path.exists(path + '.tables-restore'):
                # put оборвался, но текст мог успеть записаться целиком (отказал
                # только fsync). Текст вне таблиц цел и в самом документе, а
                # прежнее содержимое таблиц есть только здесь, поэтому файл не
                # удаляется, а переименовывается; как и .tables-restore, он
                # останавливает следующий --write, пока его не разберут.
                partial = path + '.tables-restore.incomplete'
                try:
                    os.replace(path + '.tables-restore', partial)
                except Exception as e4:
                    partial = path + '.tables-restore'
                    sys.stderr.write('  не переименован %s: %s: %s\n'
                                     % (partial, type(e4).__name__, e4))
            # Сохранённым называется только файл, ЦЕЛИКОМ записанный в этом
            # запуске: put мог оборваться на середине, а старых копий здесь нет
            # (их наличие останавливает запись заранее).
            sys.stderr.write('  НЕ ВОССТАНОВЛЕН %s: %s: %s; %s\n' % (
                path, type(e2).__name__, e2,
                'исходный текст оставлен в %s' % kept if kept else
                'копию исходного текста записать не удалось; возможно неполная копия - %s, '
                'сверьте её с git' % partial if partial else
                'копию исходного текста записать не удалось, верните файл из git'))
    if lost:
        die('не удалось записать таблицы: %s: %s; уже переписаны и НЕ возвращены к исходному: %s'
            '%s - языковые версии могут расходиться'
            % (type(e).__name__, e, ', '.join(lost),
               '; возвращены: %s' % ', '.join(restored) if restored else ''))
    die('не удалось записать таблицы: %s: %s; %s'
        % (type(e).__name__, e,
           'возвращены к исходному: %s' % ', '.join(restored) if restored
           else 'ни один документ не изменён'))
for path in replaced:
    sys.stdout.write('обновлены таблицы клиентов и хостов: %s\n' % path)
if MODE == 'write' and not plans:
    sys.stdout.write('таблицы клиентов и хостов уже совпадают с источниками, писать нечего\n')

if failed:
    sys.stderr.write('  почини командой: bash scripts/update-client-tables.sh --write\n')
    sys.exit(1)

if MODE == 'check':
    sys.stdout.write('таблицы клиентов и хостов совпадают с источниками (%d клиентов, снимок %s, '
                     'релиз %s %s, предел %d дн.)\n'
                     % (len(rows), oldest, version, released, fresh_days))
PYEOF
