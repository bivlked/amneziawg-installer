#!/usr/bin/env bats
# Регрессия на сборщик таблиц клиентов и хостов в ADVANCED
# (scripts/update-client-tables.sh) и на его проверку 15b в
# scripts/check-docs-consistency.sh.
#
# Таблицы несут дату и обещают читателю, какой клиент понимает 3.1 и какое
# поколение получит его сервер. Опасен не отказ, а тихий успех: проверка,
# которая печатает "совпадают", ничего не сверив, оставляет датированную
# неправду в документации. Почти каждый кейс ломает одну связь и требует, чтобы
# сторож на ней упал, причём с нужным кодом: 1 - таблица разошлась или
# устарела, 2 - проверить не удалось. Контрольные кейсы требуют обратного.
#
# Рабочее дерево не трогается: сборщик получает корень через AWG_CLIENTS_ROOT.
# 🔴 Кейсы не опираются на живые значения docs/clients-matrix.json: каждый
# работает на синтетической строке t-row или правит рендер общими
# литералами (шапка, разделитель, маркеры). Плановое обновление снимка раз в
# 30 дней не должно ронять тесты.

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT="$ROOT/scripts/update-client-tables.sh"
    TMP="$BATS_TEST_TMPDIR/repo"
    VER="$(grep -m1 '^SCRIPT_VERSION=' "$ROOT/install_amneziawg.sh" | cut -d'"' -f2)"
    [ -n "$VER" ] || { echo "не прочитался SCRIPT_VERSION"; return 1; }
    mkdir -p "$TMP/docs"
    for f in ADVANCED.md ADVANCED.en.md CHANGELOG.md install_amneziawg.sh install_amneziawg_en.sh; do
        cp "$ROOT/$f" "$TMP/$f"
    done
    cp "$ROOT/docs/clients-matrix.json" "$ROOT/docs/support-matrix.json" "$TMP/docs/"
}

_check() { AWG_CLIENTS_ROOT="$TMP" bash "$SCRIPT" --check 2>&1; }
_write() { AWG_CLIENTS_ROOT="$TMP" bash "$SCRIPT" --write 2>&1; }

# Замена с гарантией, что она состоялась: несработавшая мутация дала бы зелёный
# тест, ничего не проверив.
_sub() {
    python3 - "$TMP/$1" "$2" "$3" <<'PY'
import io, sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
t = io.open(path, encoding='utf-8', newline='').read()
if old not in t:
    sys.exit('мутация не применилась: в %s нет %r' % (path, old))
io.open(path, 'w', encoding='utf-8', newline='').write(t.replace(old, new, 1))
PY
}

# Правка JSON как данных. $1 - файл в docs/, $2 - код python над d (и R - строка
# t-row, если она есть).
_json() {
    python3 - "$TMP/docs/$1" "$2" <<'PY'
import io, json, sys
path, code = sys.argv[1], sys.argv[2]
d = json.load(io.open(path, encoding='utf-8'))
R = next((r for r in d.get('clients', []) if r.get('id') == 't-row'), None)
exec(code)
io.open(path, 'w', encoding='utf-8', newline='\n').write(json.dumps(d, ensure_ascii=False, indent=2))
PY
}

# Синтетическая строка со всеми полями. Добавляется в конец списка; checked_at
# совпадает с самой старой датой живых строк, чтобы не менять шапку таблицы.
_row() {
    _json clients-matrix.json '
import datetime
old = min(r["checked_at"] for r in d["clients"])
day = lambda n: (datetime.date.fromisoformat(old) - datetime.timedelta(days=n)).isoformat()
d["clients"].append({"id": "t-row", "name": {"ru": "Тестовый клиент", "en": "Test client"},
    "support": "yes", "version": "1.0", "version_date": day(1), "since": "0.9", "since_date": day(40),
    "since_note": {"ru": "тестовая заметка", "en": "test note"}, "where": "test-site",
    "basis": "vendor-docs", "evidence": {"url": "https://example.org/t"}, "checked_at": old})'
}

# Все строки на одну дату, версии и since не позже неё; freshness_days явно 30.
_all_checked() {
    _json clients-matrix.json "
d['freshness_days'] = 30
for r in d['clients']:
    r['checked_at'] = '$1'
    for k in ('version_date', 'since_date'):
        if k in r and r[k] > '$1':
            r[k] = '$1'"
}

# Дата релиза текущей версии в копии CHANGELOG: $1 - новая дата.
_release_date() {
    python3 - "$TMP/CHANGELOG.md" "$VER" "$1" <<'PY'
import io, re, sys
path, ver, date = sys.argv[1], sys.argv[2], sys.argv[3]
t = io.open(path, encoding='utf-8').read()
t2, n = re.subn(r'^(## \[%s\] - )\d{4}-\d{2}-\d{2}' % re.escape(ver), r'\g<1>' + date, t, flags=re.M)
if n != 1:
    sys.exit('нет заголовка версии %s' % ver)
io.open(path, 'w', encoding='utf-8', newline='\n').write(t2)
PY
}

_snap() { cp "$TMP/ADVANCED.md" "$BATS_TEST_TMPDIR/ru"; cp "$TMP/ADVANCED.en.md" "$BATS_TEST_TMPDIR/en"; }
_unchanged() { cmp "$TMP/ADVANCED.md" "$BATS_TEST_TMPDIR/ru" && cmp "$TMP/ADVANCED.en.md" "$BATS_TEST_TMPDIR/en"; }

# Расхождение в таблице клиентов без опоры на данные: лишняя строка перед маркером конца.
_drift_clients() { _sub "$1" '<!-- clients:end -->' $'| лишняя | строка |\n<!-- clients:end -->'; }

# ---------------------------------------------------------------- контроль ----

@test "control: the repository tables match their sources" {
    run _check
    [ "$status" -eq 0 ]
    [[ "$output" == *"совпадают с источниками"* ]]
}

@test "no mode and an unknown argument are refusals, not a silent write" {
    _snap
    run env AWG_CLIENTS_ROOT="$TMP" bash "$SCRIPT"
    [ "$status" -eq 2 ]
    run env AWG_CLIENTS_ROOT="$TMP" bash "$SCRIPT" --chek
    [ "$status" -eq 2 ]
    _unchanged
}

@test "--write with nothing to change says so and writes nothing" {
    _snap
    run _write
    [ "$status" -eq 0 ]
    [[ "$output" == *"писать нечего"* ]]
    _unchanged
}

# ------------------------------------------------------------- расхождение ----

@test "a hand edit inside the clients table fails the check and --check writes nothing" {
    _drift_clients ADVANCED.md
    _snap
    run _check
    [ "$status" -eq 1 ]
    [[ "$output" == *"ADVANCED.md: таблица clients разошлась"* ]]
    _unchanged
}

@test "a hand edit inside the hosts table fails the check and --check writes nothing" {
    _sub ADVANCED.en.md '| System | Stock kernel | x86_64 | ARM |' '| System | Kernel | x86_64 | ARM |'
    _snap
    run _check
    [ "$status" -eq 1 ]
    [[ "$output" == *"ADVANCED.en.md: таблица hosts разошлась"* ]]
    _unchanged
}

@test "--write restores both tables and keeps everything outside the markers byte for byte" {
    _drift_clients ADVANCED.md
    _sub ADVANCED.en.md '| System | Stock kernel | x86_64 | ARM |' '| System | Kernel | x86_64 | ARM |'
    run _write
    [ "$status" -eq 0 ]
    cmp "$TMP/ADVANCED.md" "$ROOT/ADVANCED.md"
    cmp "$TMP/ADVANCED.en.md" "$ROOT/ADVANCED.en.md"
    run _check
    [ "$status" -eq 0 ]
}

@test "CRLF inside the markers fails the check; CRLF outside them survives --write" {
    _sub ADVANCED.md '|---|---|---|---|---|---|' $'|---|---|---|---|---|---|\r'
    run _check
    [ "$status" -eq 1 ]
    cp "$ROOT/ADVANCED.md" "$TMP/ADVANCED.md"
    _sub ADVANCED.md '<a id="client-gen-adv"></a>' $'<a id="client-gen-adv"></a>\r'
    _drift_clients ADVANCED.md
    run _write
    [ "$status" -eq 0 ]
    grep -q $'<a id="client-gen-adv"></a>\r$' "$TMP/ADVANCED.md"
}

@test "a write that fails on the second file leaves both documents as they were, no temp files" {
    [ "$(id -u)" -ne 0 ] || skip "root ignores file permissions"
    _drift_clients ADVANCED.md
    _drift_clients ADVANCED.en.md
    _snap
    : > "$TMP/ADVANCED.en.md.tables-tmp"
    chmod 000 "$TMP/ADVANCED.en.md.tables-tmp"
    run _write
    [ "$status" -eq 1 ]
    [[ "$output" == *"не удалось записать таблицы"* ]]
    _unchanged
    [ ! -e "$TMP/ADVANCED.md.tables-tmp" ]
}

@test "an unexpected exception (no UTF-8 on stdout) is code 2, not a drift" {
    run env PYTHONIOENCODING=ascii AWG_CLIENTS_ROOT="$TMP" bash "$SCRIPT" --check
    [ "$status" -eq 2 ]
    [[ "$output" == *"UnicodeEncodeError"* ]]
}

# Сбой на конкретном системном вызове внедряется через sitecustomize.py в
# PYTHONPATH: сборщик зовёт python без -I, и так проверяются пути, которые на
# Linux иначе не воспроизвести (занятый файл на Windows, обрыв записи).
_inject() {
    mkdir -p "$BATS_TEST_TMPDIR/inject"
    printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/inject/sitecustomize.py"
}
_write_injected() { env PYTHONPATH="$BATS_TEST_TMPDIR/inject" AWG_CLIENTS_ROOT="$TMP" bash "$SCRIPT" --write 2>&1; }

@test "a failed second replace rolls the first document back and leaves no temp files" {
    _inject 'import os
_r = os.replace
def replace(src, dst, *a, **k):
    if str(src).endswith("ADVANCED.en.md.tables-tmp"):
        raise PermissionError(13, "injected", dst)
    return _r(src, dst, *a, **k)
os.replace = replace'
    _drift_clients ADVANCED.md
    _drift_clients ADVANCED.en.md
    _snap
    run _write_injected
    [ "$status" -eq 1 ]
    [[ "$output" == *"возвращены к исходному: ADVANCED.md"* ]]
    _unchanged
    [ ! -e "$TMP/ADVANCED.md.tables-tmp" ]
    [ ! -e "$TMP/ADVANCED.en.md.tables-tmp" ]
    [ ! -e "$TMP/ADVANCED.md.tables-restore" ]
    [ ! -e "$TMP/ADVANCED.en.md.tables-restore" ]
}

@test "a rollback that fails too is reported as such, with the original text kept aside" {
    _inject 'import os
_r = os.replace
def replace(src, dst, *a, **k):
    if str(src).endswith(("ADVANCED.en.md.tables-tmp", ".tables-restore")):
        raise PermissionError(13, "injected", dst)
    return _r(src, dst, *a, **k)
os.replace = replace'
    _drift_clients ADVANCED.md
    _drift_clients ADVANCED.en.md
    cp "$TMP/ADVANCED.md" "$BATS_TEST_TMPDIR/ru-orig"
    run _write_injected
    [ "$status" -eq 1 ]
    [[ "$output" == *"НЕ возвращены к исходному: ADVANCED.md"* ]]
    [[ "$output" == *"исходный текст оставлен в ADVANCED.md.tables-restore"* ]]
    cmp "$TMP/ADVANCED.md.tables-restore" "$BATS_TEST_TMPDIR/ru-orig"
    # следующий запуск не пишет поверх оставленной копии
    _snap
    run _write
    [ "$status" -eq 2 ]
    [[ "$output" == *"ADVANCED.md.tables-restore остался от прошлого"* ]]
    _unchanged
}

@test "a rollback whose own write fails does not claim a kept copy" {
    _inject 'import os
_r = os.replace
_f = os.fsync
_n = [0]
def replace(src, dst, *a, **k):
    if str(src).endswith("ADVANCED.en.md.tables-tmp"):
        raise PermissionError(13, "injected", dst)
    return _r(src, dst, *a, **k)
def fsync(fd):
    _n[0] += 1
    if _n[0] == 3:
        raise OSError(28, "injected: no space")
    return _f(fd)
os.replace = replace
os.fsync = fsync'
    _drift_clients ADVANCED.md
    _drift_clients ADVANCED.en.md
    run _write_injected
    [ "$status" -eq 1 ]
    [[ "$output" == *"копию исходного текста записать не удалось"* ]]
    [[ "$output" != *"исходный текст оставлен"* ]]
    # возможно неполная копия переименована: следующий --write не примет её за
    # исходный текст, и с диска она не пропала
    [[ "$output" == *"возможно неполная копия - ADVANCED.md.tables-restore.incomplete"* ]]
    [ ! -e "$TMP/ADVANCED.md.tables-restore" ]
    [ -e "$TMP/ADVANCED.md.tables-restore.incomplete" ]
    # и она, пока не разобрана, тоже останавливает следующий --write
    run _write
    [ "$status" -eq 2 ]
    [[ "$output" == *"ADVANCED.md.tables-restore.incomplete остался от прошлого"* ]]
}

@test "a temp file whose write failed (fsync) is cleaned up" {
    _inject 'import os
_f = os.fsync
_n = [0]
def fsync(fd):
    _n[0] += 1
    if _n[0] == 2:
        raise OSError(28, "injected: no space")
    return _f(fd)
os.fsync = fsync'
    _drift_clients ADVANCED.md
    _drift_clients ADVANCED.en.md
    _snap
    run _write_injected
    [ "$status" -eq 1 ]
    [[ "$output" == *"ни один документ не изменён"* ]]
    _unchanged
    [ ! -e "$TMP/ADVANCED.md.tables-tmp" ]
    [ ! -e "$TMP/ADVANCED.en.md.tables-tmp" ]
}
# ---------------------------------------------------------------- маркеры ----

@test "nested blocks are refused before anything is written" {
    # hosts переезжает внутрь clients: прежняя форма дублировала файл и
    # рапортовала успех.
    python3 - "$TMP/ADVANCED.md" <<'PY'
import io, re, sys
p = sys.argv[1]
t = io.open(p, encoding='utf-8').read()
hosts = re.search(r'<!-- hosts:begin -->.*?<!-- hosts:end -->', t, re.S).group(0)
t = t.replace(hosts, '')
t = t.replace('<!-- clients:end -->', hosts + '\n<!-- clients:end -->')
io.open(p, 'w', encoding='utf-8', newline='\n').write(t)
PY
    _snap
    run _write
    [ "$status" -eq 2 ]
    [[ "$output" == *"пересекаются"* ]]
    _unchanged
}

@test "crossed blocks are refused" {
    _sub ADVANCED.md '<!-- hosts:begin -->' ''
    _sub ADVANCED.md '<!-- clients:end -->' $'<!-- hosts:begin -->\n<!-- clients:end -->'
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"пересекаются"* || "$output" == *"раньше"* ]]
}

@test "an end marker before its begin, a missing marker and a duplicate are refused with code 2" {
    _sub ADVANCED.md '<!-- hosts:end -->' ''
    _sub ADVANCED.md '<!-- hosts:begin -->' $'<!-- hosts:end -->\n<!-- hosts:begin -->'
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"стоит раньше"* ]]
    cp "$ROOT/ADVANCED.md" "$TMP/ADVANCED.md"
    _sub ADVANCED.en.md '<!-- clients:end -->' ''
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"ровно одна пара маркеров <!-- clients:begin -->"* ]]
    cp "$ROOT/ADVANCED.en.md" "$TMP/ADVANCED.en.md"
    printf '\n<!-- hosts:begin -->\n' >> "$TMP/ADVANCED.en.md"
    run _check
    [ "$status" -eq 2 ]
}

@test "broken markers in the second file leave the first one unwritten" {
    _drift_clients ADVANCED.md
    _snap
    _sub ADVANCED.en.md '<!-- hosts:end -->' ''
    run _write
    [ "$status" -eq 2 ]
    [[ "$output" == *"ADVANCED.en.md"* ]]
    cmp "$TMP/ADVANCED.md" "$BATS_TEST_TMPDIR/ru"
}

# --------------------------------------------------------------- свежесть ----

@test "freshness: a row 31 days older than the release fails with code 1, 30 days passes" {
    _all_checked 2026-10-05
    _release_date 2026-11-04
    run _write
    [ "$status" -eq 0 ]
    run _check
    [ "$status" -eq 0 ]
    _release_date 2026-11-05
    run _check
    [ "$status" -eq 1 ]
    [[ "$output" == *"устарела к релизу"* ]]
    [[ "$output" == *"проверен 2026-10-05, это за 31 дн."* ]]
}

@test "freshness uses the oldest row, not the first one" {
    _all_checked 2026-10-05
    _row
    _json clients-matrix.json 'R.update(checked_at="2026-09-01", version_date="2026-09-01", since_date="2026-09-01")'
    _release_date 2026-10-05
    run _check
    [ "$status" -eq 1 ]
    [[ "$output" == *"t-row: проверен 2026-09-01"* ]]
}

@test "a check date in the future is refused: it would switch freshness off for good" {
    _row
    _json clients-matrix.json 'R["checked_at"] = "2062-10-05"'
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"в будущем"* ]]
}

@test "freshness_days outside 1..90 is refused" {
    _json clients-matrix.json 'd["freshness_days"] = 100000'
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"freshness_days"* ]]
    _json clients-matrix.json 'd["freshness_days"] = 0'
    run _check
    [ "$status" -eq 2 ]
}

@test "a missing or impossible release date is code 2, and no clock is used instead" {
    _sub CHANGELOG.md "## [$VER] - " "## [0.0.0] - "
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"нет заголовка \"## [$VER]"* ]]
    cp "$ROOT/CHANGELOG.md" "$TMP/CHANGELOG.md"
    _release_date 2026-02-30
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"не дата"* ]]
}

# ----------------------------------------------------------------- схема ----

@test "a row with basis unknown may not name a generation, nor a version since which it has 3.1" {
    _row
    _json clients-matrix.json 'R["basis"] = "unknown"; R["evidence"] = {}'
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"без основания поколение не называется"* ]]
    for k in since since_date since_note; do
        cp "$ROOT/docs/clients-matrix.json" "$TMP/docs/"
        _row
        _json clients-matrix.json "R.update(basis='unknown', support='unknown', evidence={}); [R.pop(x) for x in ('since', 'since_date', 'since_note') if x != '$k']"
        run _check
        [ "$status" -eq 2 ] || { echo "прошло с $k"; return 1; }
    done
}

@test "evidence required by the basis: env, ref, url" {
    _row
    _json clients-matrix.json 'R["basis"] = "verified-behaviour"; R["evidence"] = {"version": "1.0"}'
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"обязателен непустой env"* ]]
    _json clients-matrix.json 'R["basis"] = "build-pin"; R["evidence"] = {"url": "https://example.org"}'
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"обязателен непустой ref"* ]]
    for b in vendor-docs inference-from-dates; do
        _json clients-matrix.json "R['basis'] = '$b'; R['evidence'] = {'ref': 'x'}"
        run _check
        [ "$status" -eq 2 ] || { echo "прошло: $b без url"; return 1; }
        [[ "$output" == *"обязателен непустой url"* ]]
    done
}

@test "evidence.url must be one https link: http, TODO and a trailing newline are refused" {
    _row
    for bad in 'http://example.org' 'TODO' $'https://example.org\n'; do
        _json clients-matrix.json "R['evidence']['url'] = $(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$bad")"
        run _check
        [ "$status" -eq 2 ] || { echo "прошло: $bad"; return 1; }
        [[ "$output" == *"не https-ссылка"* ]]
    done
}

@test "a misspelt key is an error, not a silently lost value" {
    _row
    _json clients-matrix.json 'R["since_dat"] = R.pop("since_date")'
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"неизвестные ключи since_dat"* ]]
}

@test "since_note and since_date without since are refused, not dropped from the table" {
    for k in since_note since_date; do
        cp "$ROOT/docs/clients-matrix.json" "$TMP/docs/"
        _row
        _json clients-matrix.json "R.pop('since'); [R.pop(x) for x in ('since_note', 'since_date') if x != '$k']"
        run _check
        [ "$status" -eq 2 ]
        [[ "$output" == *"$k без since"* ]]
    done
}

@test "every text field refuses a pipe, CR, LF and an empty value" {
    for k in name version since since_note where; do
        for bad in 'a | b' $'a\rb' $'a\nb' '   '; do
            cp "$ROOT/docs/clients-matrix.json" "$TMP/docs/"
            _row
            _json clients-matrix.json "R['$k'] = $(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$bad")"
            run _check
            [ "$status" -eq 2 ] || { echo "прошло: $k = $(printf %q "$bad")"; return 1; }
            [[ "$output" == *"$k: "* ]]
        done
    done
}

@test "a duplicate id and dates after the check are refused" {
    _row
    _json clients-matrix.json 'd["clients"].append(dict(R))'
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"повторяется"* ]]
    for k in version_date since_date; do
        cp "$ROOT/docs/clients-matrix.json" "$TMP/docs/"
        _row
        _json clients-matrix.json "import datetime; R['$k'] = (datetime.date.fromisoformat(R['checked_at']) + datetime.timedelta(days=1)).isoformat()"
        run _check
        [ "$status" -eq 2 ]
        [[ "$output" == *"$k позже checked_at"* ]]
    done
}

@test "broken JSON and a missing data file are code 2 and name the file" {
    printf '{ broken' > "$TMP/docs/clients-matrix.json"
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"clients-matrix.json не прошёл формат"* ]]
    rm "$TMP/docs/clients-matrix.json"
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"нет docs/clients-matrix.json"* ]]
}

# ------------------------------------------------------------------ рендер ----

@test "the row renders every field and each of its three dates in both languages" {
    _all_checked 2026-10-05
    _release_date 2026-10-10
    _row
    run _write
    [ "$status" -eq 0 ]
    grep -qxF '| Тестовый клиент | да | 1.0 (4 окт 2026) | 0.9 (26 авг 2026); тестовая заметка | test-site | страницы проекта |' "$TMP/ADVANCED.md"
    grep -qxF '| Test client | yes | 1.0 (4 Oct 2026) | 0.9 (26 Aug 2026); test note | test-site | project pages |' "$TMP/ADVANCED.en.md"
    _json clients-matrix.json '[R.pop(x) for x in ("since", "since_date", "since_note", "where", "version_date")]'
    run _write
    [ "$status" -eq 0 ]
    grep -qxF '| Тестовый клиент | да | 1.0 | - | - | страницы проекта |' "$TMP/ADVANCED.md"
    grep -qxF '| Test client | yes | 1.0 | - | - | project pages |' "$TMP/ADVANCED.en.md"
}

@test "every basis and support value has its own label in both languages" {
    _row
    while IFS='|' read -r basis ev ru en; do
        _json clients-matrix.json "R['basis'] = '$basis'; R['evidence'] = $ev"
        run _write
        [ "$status" -eq 0 ] || { echo "$basis: $output"; return 1; }
        grep -qF "| test-site | $ru |" "$TMP/ADVANCED.md" || { echo "нет RU $ru"; return 1; }
        grep -qF "| test-site | $en |" "$TMP/ADVANCED.en.md" || { echo "нет EN $en"; return 1; }
    done <<'EOF'
verified-behaviour|{"version": "1", "env": "x"}|проверено на профиле 3.1|tested on a 3.1 profile
build-pin|{"ref": "x"}|код проекта|project code
vendor-docs|{"url": "https://example.org"}|страницы проекта|project pages
inference-from-dates|{"url": "https://example.org"}|вывод по датам|inferred from dates
EOF
    while IFS='|' read -r support ru en; do
        _json clients-matrix.json "R['support'] = '$support'"
        run _write
        [ "$status" -eq 0 ]
        grep -qF "| Тестовый клиент | $ru |" "$TMP/ADVANCED.md" || { echo "нет RU $ru"; return 1; }
        grep -qF "| Test client | $en |" "$TMP/ADVANCED.en.md" || { echo "нет EN $en"; return 1; }
    done <<'EOF'
no|нет|no
dev-channel|только в канале разработки|development channel only
nightly|в ежедневном фиде, без тега|in the daily feed, no tag
EOF
    _json clients-matrix.json 'R.update(support="unknown", basis="unknown", evidence={}); [R.pop(x) for x in ("since", "since_date", "since_note")]'
    run _write
    [ "$status" -eq 0 ]
    grep -qF '| Тестовый клиент | не знаем | 1.0 (' "$TMP/ADVANCED.md"
    grep -qF '| test-site | нет |' "$TMP/ADVANCED.md"
    grep -qF '| Test client | unknown | 1.0 (' "$TMP/ADVANCED.en.md"
    grep -qF '| test-site | none |' "$TMP/ADVANCED.en.md"
}

@test "a row checked later than the rest shows its own date; the header takes the oldest" {
    _all_checked 2026-10-05
    _release_date 2026-10-10
    _row
    # Позже проверена ПЕРВАЯ строка: так «первая» и «самая старая» расходятся.
    _json clients-matrix.json 'd["clients"].remove(R); d["clients"].insert(0, R); R["checked_at"] = "2026-10-07"'
    run _write
    [ "$status" -eq 0 ]
    grep -q 'Строки, проверенные позже, несут свою дату' "$TMP/ADVANCED.md"
    grep -qF '| test-site | страницы проекта, 7 окт 2026 |' "$TMP/ADVANCED.md"
    grep -qF '| test-site | project pages, 7 Oct 2026 |' "$TMP/ADVANCED.en.md"
    grep -qF '| Версия на 5 окт 2026 |' "$TMP/ADVANCED.md"
    grep -qF '| Version on 5 Oct 2026 |' "$TMP/ADVANCED.en.md"
}

@test "a hostile BASH_ENV in the caller does not reach the gate" {
    printf 'echo noise >&2\n' > "$BATS_TEST_TMPDIR/bashenv"
    run env BASH_ENV="$BATS_TEST_TMPDIR/bashenv" AWG_CLIENTS_ROOT="$TMP" bash "$SCRIPT" --check
    [ "$status" -eq 0 ]
}

@test "a gate that also accepts the kernel just below its stated threshold is refused" {
    _sub install_amneziawg.sh '(kmaj == min_maj && kmin >= min_min)' '(kmaj == min_maj && kmin >= min_min - 1)'
    _sub install_amneziawg_en.sh '(kmaj == min_maj && kmin >= min_min)' '(kmaj == min_maj && kmin >= min_min - 1)'
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"не совпадает с поведением проверки"* ]]
}

@test "an unreadable document (broken UTF-8) is code 2 naming the file" {
    printf '\xff\xfe broken\n' >> "$TMP/ADVANCED.md"
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"не прочитан ADVANCED.md"* ]]
}

# ------------------------------------------- хосты: поведение установщика ----

@test "the host cells are the step 0 check's answers: the threshold edge 6.7 gets 3.1, 6.6 does not" {
    _json support-matrix.json 'd["platforms"][0].update(stock_kernel="6.7", lifecycle="supported"); d["platforms"][1].update(stock_kernel="6.6", lifecycle="supported")'
    run _write
    [ "$status" -eq 0 ]
    grep -q '| 6.7 | 3.1 | 2.0, код `arm` |' "$TMP/ADVANCED.md"
    grep -q '| 6.6 | 2.0, код `kernel` | 2.0, код `arm` |' "$TMP/ADVANCED.md"
}

@test "an unreleased platform stays out of the host table" {
    _json support-matrix.json 'p = dict(d["platforms"][0]); p.update(id="ubuntu-99.04", version="99.04", lifecycle="unreleased"); d["platforms"].append(p)'
    run _write
    [ "$status" -eq 0 ]
    if grep -q 'Ubuntu 99.04' "$TMP/ADVANCED.md" "$TMP/ADVANCED.en.md"; then return 1; fi
    _json support-matrix.json 'd["platforms"][-1]["lifecycle"] = "supported"'
    run _write
    [ "$status" -eq 0 ]
    grep -q 'Ubuntu 99.04' "$TMP/ADVANCED.md"
}

@test "a reversed kernel comparison in the installers is caught by behaviour, not by text" {
    _sub install_amneziawg.sh 'kmin >= min_min' 'kmin > min_min'
    _sub install_amneziawg_en.sh 'kmin >= min_min' 'kmin > min_min'
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"не совпадает с поведением проверки"* ]]
}

@test "an ARM branch that stops returning breaks the footnote's promise and is refused" {
    _sub install_amneziawg.sh "printf 'arm'" ":"
    _sub install_amneziawg_en.sh "printf 'arm'" ":"
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"ответ не arm"* ]]
}

@test "a removed x86_64 branch is caught: x86_64 no longer gets 3.1 even above the threshold" {
    _sub install_amneziawg.sh 'amd64|x86_64)' 'amd64x|x86_64x)'
    _sub install_amneziawg_en.sh 'amd64|x86_64)' 'amd64x|x86_64x)'
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"не совпадает с поведением проверки"* ]]
}

@test "a step 3 code named in the footnote must exist in the gate" {
    _sub install_amneziawg.sh "printf 'module_probe_failed'" "printf 'module_probe_gone'"
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"кода module_probe_failed нет в проверке"* ]]
}

@test "the RU and EN installers with different thresholds are refused" {
    _sub install_amneziawg_en.sh 'local min_maj=6 min_min=7' 'local min_maj=6 min_min=9'
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"порог ядра в установщиках разный"* ]]
}

@test "RU and EN installers that answer differently with the same threshold are refused" {
    _json support-matrix.json 'd["platforms"][0].update(stock_kernel="7.0", lifecycle="supported")'
    _sub install_amneziawg_en.sh 'local kver="${1:-$(uname -r)}" kmaj kmin' $'local kver="${1:-$(uname -r)}" kmaj kmin\n    [[ "$kver" == 7.0* ]] && return 1'
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"RU и EN установщиках отвечает по-разному"* ]]
}

@test "arm64 and armhf getting different answers is refused: one ARM column cannot show it" {
    _sub install_amneziawg.sh 'arm*|aarch64*)' 'arm64|aarch64*)'
    _sub install_amneziawg_en.sh 'arm*|aarch64*)' 'arm64|aarch64*)'
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"arm64 и armhf"* ]]
}

@test "a gate that writes to stderr (a missing helper) is code 2, not its stdout read as an answer" {
    _sub install_amneziawg.sh 'if ! _kernel_supports_awg3 "$kver"; then' 'if ! _awg_gone_helper "$kver"; then'
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"проверка шага 0"* && "$output" == *"stderr"* ]]
}

@test "a gate that exits early (no answer at all) is code 2, not an empty answer read as 3.1" {
    _sub install_amneziawg.sh '    local stage="${1-}" arch="${2:-}" kver="${3:-}"' $'    local stage="${1-}" arch="${2:-}" kver="${3:-}"\n    exit 0'
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"проверка шага 0"* ]]
}

@test "a gate function defined twice, in either syntax, is refused" {
    python3 - "$TMP/install_amneziawg.sh" <<'PY'
import io, re, sys
p = sys.argv[1]
t = io.open(p, encoding='utf-8').read()
fn = re.search(r'^_kernel_supports_awg3\(\) \{\n.*?^\}\n', t, re.M | re.S).group(0)
io.open(p, 'w', encoding='utf-8', newline='\n').write(t + '\n' + fn)
PY
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"функция _kernel_supports_awg3 определена 2 раз"* ]]
    cp "$ROOT/install_amneziawg.sh" "$TMP/install_amneziawg.sh"
    printf '\nif true; then\n    function _kernel_supports_awg3 { return 0; }\nfi\n' >> "$TMP/install_amneziawg.sh"
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"определена 2 раз"* ]]
}

@test "a gate that returns non-zero with no output is refused, as the installer refuses it" {
    _sub install_amneziawg.sh $'        printf \'kernel\'\n        return 0' $'        return 1'
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"проверка шага 0"* ]]
}

@test "a redefinition with the brace on the next line or after a semicolon is counted" {
    printf '\n_kernel_supports_awg3()\n{\n    return 0\n}\n' >> "$TMP/install_amneziawg.sh"
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"определена 2 раз"* ]]
    cp "$ROOT/install_amneziawg.sh" "$TMP/install_amneziawg.sh"
    printf '\ntrue; _kernel_supports_awg3() { return 0; }\n' >> "$TMP/install_amneziawg.sh"
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"определена 2 раз"* ]]
}

@test "a step 3 code present only in a comment or as a prefix does not count" {
    _sub install_amneziawg.sh "printf 'module_probe_failed'" "printf 'module_probe_failedx'"
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"кода module_probe_failed нет в проверке"* ]]
    cp "$ROOT/install_amneziawg.sh" "$TMP/install_amneziawg.sh"
    _sub install_amneziawg.sh "*) printf 'module_probe_failed'; return 0 ;;" $'*) printf \'module_x\'; return 0 ;;\n            # printf \'module_probe_failed\''
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"кода module_probe_failed нет в проверке"* ]]
}
@test "the fallback decision must allow 2.0 for every footnote code, and the post stage must be called" {
    _sub install_amneziawg.sh 'AWG31_FALLBACK_POST_CODES="tools_old module_line2 module_probe_failed"' 'AWG31_FALLBACK_POST_CODES="tools_old module_line2"'
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"а сноска называет"* ]]
    cp "$ROOT/install_amneziawg.sh" "$TMP/install_amneziawg.sh"
    _sub install_amneziawg.sh '"$AWG31_FALLBACK_PRE_CODES $AWG31_FALLBACK_POST_CODES"' '"$AWG31_FALLBACK_PRE_CODES"'
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"автооткат на 2.0 по коду tools_old не разрешён"* ]]
    cp "$ROOT/install_amneziawg.sh" "$TMP/install_amneziawg.sh"
    _sub install_amneziawg.sh '_awg31_code_in "$code" "$AWG31_FALLBACK_PRE_CODES $AWG31_FALLBACK_POST_CODES" || return 1' ':'
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"по коду internal_error разрешён"* ]]
    cp "$ROOT/install_amneziawg.sh" "$TMP/install_amneziawg.sh"
    _sub install_amneziawg.sh '$(awg31_environment_blocker post)' '$(echo "")'
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"стадия post не вызывается"* ]]
}

@test "a later reassignment of a code list or redefinition of the fallback decision is refused" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        printf '\nif true; then\n    AWG31_FALLBACK_POST_CODES="tools_old module_line2"\nfi\n' >> "$TMP/$f"
    done
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"присваивание AWG31_FALLBACK_POST_CODES найдено 2 раз"* ]]
    for form in 'AWG31_FALLBACK_POST_CODES+=" module_old"' 'AWG31_FALLBACK_POST_CODES[0]="tools_old"'; do
        for f in install_amneziawg.sh install_amneziawg_en.sh; do
            cp "$ROOT/$f" "$TMP/$f"
            printf '\n%s\n' "$form" >> "$TMP/$f"
        done
        run _check
        [ "$status" -eq 2 ] || { echo "прошло: $form"; return 1; }
        [[ "$output" == *"присваивание AWG31_FALLBACK_POST_CODES найдено 2 раз"* ]]
    done
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        cp "$ROOT/$f" "$TMP/$f"
        printf '\n_awg31_post_fallback_allowed() { return 1; }\n' >> "$TMP/$f"
    done
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"функция _awg31_post_fallback_allowed определена 2 раз"* ]]
}

@test "an extra step 3 code, or the fallback decision not called at step 3, is refused" {
    _sub install_amneziawg.sh 'AWG31_FALLBACK_POST_CODES="tools_old module_line2 module_probe_failed"' 'AWG31_FALLBACK_POST_CODES="tools_old module_line2 module_probe_failed module_old"'
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"а сноска называет"* ]]
    cp "$ROOT/install_amneziawg.sh" "$TMP/install_amneziawg.sh"
    _sub install_amneziawg.sh '&& _awg31_post_fallback_allowed "$_awg31_blocker" "$_awg31_rc"' '&& false'
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"решение об автооткате не вызывается на результате гейта шага 3"* ]]
    # закомментированный вызов с живой заглушкой рядом тоже не засчитывается
    cp "$ROOT/install_amneziawg.sh" "$TMP/install_amneziawg.sh"
    _sub install_amneziawg.sh 'if [[ "$where" == step3 ]] && _awg31_post_fallback_allowed "$_awg31_blocker" "$_awg31_rc"; then' $'if false; then\n    # if [[ "$where" == step3 ]] && _awg31_post_fallback_allowed "$_awg31_blocker" "$_awg31_rc"; then'
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"решение об автооткате не вызывается"* ]]
    cp "$ROOT/install_amneziawg.sh" "$TMP/install_amneziawg.sh"
    _sub install_amneziawg.sh '_awg31_blocker=$(awg31_environment_blocker post); _awg31_rc=$?' $'_awg31_blocker=""; _awg31_rc=0\n    # _awg31_blocker=$(awg31_environment_blocker post); _awg31_rc=$?'
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"стадия post не вызывается"* ]]
}

@test "a redefinition inside an if is counted" {
    printf '\nif :; then awg31_environment_blocker() { return 0; }; fi\n' >> "$TMP/install_amneziawg.sh"
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"функция awg31_environment_blocker определена 2 раз"* ]]
}

@test "extra output from the gate besides its code is refused" {
    # В обоих установщиках, чтобы тест не зависел от порядка проверок в сборщике.
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        _sub "$f" $'        printf \'kernel\'\n        return 0' $'        printf \'kernel extra\'\n        return 0'
    done
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"проверка шага 0"* ]]
    [[ "$output" == *"kernel extra"* ]]
}
@test "a missing gate function is code 2" {
    _sub install_amneziawg.sh '_kernel_supports_awg3() {' '_kernel_supports_awg3_gone() {'
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"функция _kernel_supports_awg3 определена 0 раз"* ]]
}

@test "a platform without stock_kernel is a format error" {
    _json support-matrix.json 'del d["platforms"][0]["stock_kernel"]'
    run _check
    [ "$status" -eq 2 ]
    [[ "$output" == *"support-matrix.json не прошёл формат"* ]]
    [[ "$output" == *"stock_kernel"* ]]
}

# ------------------------------------------------- проверка 15b в чекере ----
# Чекер гоняется в маленьком репозитории с заглушкой вместо сборщика: остальные
# его проверки там падают, поэтому провал 15b доказывается РОСТОМ числа
# провалов в сводке против той же фикстуры с подписанным успехом, а не общим
# статусом.

_fixture() {
    FIX="$BATS_TEST_TMPDIR/fix"
    rm -rf "$FIX"
    mkdir -p "$FIX/scripts"
    cp "$ROOT/scripts/check-docs-consistency.sh" "$FIX/scripts/"
    (cd "$FIX" && git init -q . && printf '# x\n' > README.md && git add -A >/dev/null)
    if [ -n "${1:-}" ]; then
        printf '#!/bin/bash\n%s\n' "$1" > "$FIX/scripts/update-client-tables.sh"
    fi
}
_guard() { run bash "$FIX/scripts/check-docs-consistency.sh"; }
_failed() { sed -n 's/.*summary: [0-9]* passed, \([0-9]*\) failed.*/\1/p' <<<"$output"; }
_baseline() {
    _fixture 'echo "таблицы клиентов и хостов совпадают с источниками (stub)"; exit 0'
    _guard
    BASE=$(_failed)
    [ -n "$BASE" ]
}

@test "15b: a signed success passes" {
    _baseline
    [[ "$output" == *"PASS: таблицы клиентов и хостов в ADVANCED собраны из данных"* ]]
}

@test "15b: a drift (code 1) is one more FAIL, naming the drift" {
    _baseline
    _fixture 'echo "таблица clients разошлась" >&2; exit 1'
    _guard
    [ "$status" -ne 0 ]
    [ "$(_failed)" -eq $((BASE + 1)) ]
    [[ "$output" == *"FAIL: таблицы клиентов и хостов разошлись с данными или устарели"* ]]
    [[ "$output" != *"PASS: таблицы клиентов"* ]]
}

@test "15b: code 2 is one more FAIL saying the tables were not verified" {
    _baseline
    _fixture 'exit 2'
    _guard
    [ "$(_failed)" -eq $((BASE + 1)) ]
    [[ "$output" == *"FAIL: таблицы клиентов и хостов НЕ ПРОВЕРЕНЫ: проверить не удалось"* ]]
}

@test "15b: success without the signature is one more FAIL" {
    _baseline
    _fixture 'exit 0'
    _guard
    [ "$(_failed)" -eq $((BASE + 1)) ]
    [[ "$output" == *"НЕ ПРОВЕРЕНЫ: сборщик завершился успехом без подписи"* ]]
}

@test "15b: a missing generator is one more FAIL" {
    _baseline
    _fixture
    _guard
    [ "$(_failed)" -eq $((BASE + 1)) ]
    [[ "$output" == *"FAIL: нет scripts/update-client-tables.sh"* ]]
}

@test "15b: a leftover AWG_CLIENTS_ROOT does not redirect the check" {
    _fixture '[ -z "${AWG_CLIENTS_ROOT:-}" ] || exit 1; echo "таблицы клиентов и хостов совпадают с источниками"; exit 0'
    AWG_CLIENTS_ROOT=/nonexistent _guard
    [[ "$output" == *"PASS: таблицы клиентов и хостов в ADVANCED собраны из данных"* ]]
}

@test "15b on the real repository: the check runs and passes" {
    run bash "$ROOT/scripts/check-docs-consistency.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS: таблицы клиентов и хостов в ADVANCED собраны из данных"* ]]
}
