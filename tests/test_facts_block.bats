#!/usr/bin/env bats
# Регрессия на генератор блока "факты на дату" (scripts/update-facts-block.sh).
#
# Блок стоит на первом экране обоих README и несёт дату, то есть обещает
# читателю свежесть. Опасен здесь не отказ, а ТИХИЙ УСПЕХ: проверка, которая
# печатает "совпадает", ничего при этом не сверив, оставляет датированную
# неправду на витрине проекта и выглядит убедительнее обычного текста.
#
# Почти каждый кейс ниже ломает ровно одну связь и требует, чтобы сторож на ней
# упал. Исключения намеренные и их два: контрольный кейс и кейс на отсутствие
# ложной тревоги - там требуется НЕ упасть.
#
# 🔴 Половина набора появилась после ревью 30 aug, которое собрало мутантов и
# показало, что прежние одиннадцать кейсов пропускают мутацию, уничтожающую оба
# README целиком: и проверка, и тесты смотрели ТОЛЬКО на текст между маркерами,
# и никто не утверждал, что запись сохранила остальной файл.
#
# Рабочее дерево не трогается: генератор получает корень через AWG_FACTS_ROOT,
# и все правки идут по временной копии нужных файлов.

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT="$ROOT/scripts/update-facts-block.sh"
    TMP="$BATS_TEST_TMPDIR/repo"
    # Версия нужна тесту, чтобы целиться в строки ИМЕННО текущего релиза.
    VER="$(grep -m1 '^SCRIPT_VERSION=' "$ROOT/install_amneziawg.sh" | cut -d'"' -f2)"
    [ -n "$VER" ] || { echo "не прочитался SCRIPT_VERSION"; return 1; }
    # Дата релиза читается тем же способом, что и генератором - из заголовка
    # CHANGELOG. Нужна, чтобы подменять её ВАЛИДНОЙ другой датой, а не ломать
    # формат строки: сломанный формат проверяет совсем другую ветку кода.
    REL="$(grep -m1 "^## \[$VER\] - " "$ROOT/CHANGELOG.md" | awk '{print $NF}')"
    [ -n "$REL" ] || { echo "не прочиталась дата релиза из CHANGELOG"; return 1; }

    mkdir -p "$TMP/docs" "$TMP/.github/workflows"
    for f in README.md README.en.md CHANGELOG.md \
             awg_common.sh awg_common_en.sh \
             install_amneziawg.sh install_amneziawg_en.sh \
             manage_amneziawg.sh manage_amneziawg_en.sh; do
        cp "$ROOT/$f" "$TMP/$f"
    done
    cp "$ROOT/docs/support-matrix.json" "$TMP/docs/"
    cp "$ROOT/.github/workflows/arm-build.yml" "$TMP/.github/workflows/"
}

_check() {
    AWG_FACTS_ROOT="$TMP" bash "$SCRIPT" --check 2>&1
}

_write() {
    AWG_FACTS_ROOT="$TMP" bash "$SCRIPT" --write 2>&1
}

# Замена по файлу с гарантией, что она СОСТОЯЛАСЬ: молча не сработавшая мутация
# дала бы зелёный тест, ничего не проверив.
_sub() {
    python3 - "$TMP/$1" "$2" "$3" <<'PY'
import io, sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
t = io.open(path, encoding='utf-8').read()
if old not in t:
    sys.exit('мутация не применилась: в %s нет %r' % (path, old))
io.open(path, 'w', encoding='utf-8', newline='\n').write(t.replace(old, new, 1))
PY
}

# Правка матрицы как данных, а не как текста - домашний стиль соседней сюиты
# tests/test_support_matrix_guard.bats.
_json() {
    python3 - "$TMP/docs/support-matrix.json" "$1" <<'PY'
import io, json, sys
path = sys.argv[1]
d = json.load(io.open(path, encoding='utf-8'))
exec(sys.argv[2])
io.open(path, 'w', encoding='utf-8', newline='\n').write(
    json.dumps(d, ensure_ascii=False, indent=2))
PY
}

# Отпечаток ВСЕГО файла за вычетом блока между маркерами. Ради него набор и
# переписан: без него мутация, схлопывающая README в один блок, зеленела.
_outside() {
    python3 - "$TMP/$1" <<'PY'
import hashlib, io, sys
t = io.open(sys.argv[1], encoding='utf-8').read()
b, e = '<!-- facts:begin -->', '<!-- facts:end -->'
i, j = t.find(b), t.find(e)
if i < 0 or j < 0:
    sys.exit('маркеров нет, отпечаток не имеет смысла')
outside = t[:i] + t[j + len(e):]
print('%s %d' % (hashlib.sha256(outside.encode('utf-8')).hexdigest(), len(t)))
PY
}

_hashall() {
    python3 - "$TMP/$1" <<'PY'
import hashlib, io, sys
print(hashlib.sha256(io.open(sys.argv[1], 'rb').read()).hexdigest())
PY
}

# --- контроль ------------------------------------------------------------

@test "facts: контроль - нетронутая копия проходит" {
    run _check
    [ "$status" -eq 0 ]
    [[ "$output" == *"совпадает с источниками"* ]]
}

# --- режимы и аргументы --------------------------------------------------

@test "facts: без аргументов НИЧЕГО не пишется и это отказ инструмента" {
    # Ради этого кейса запись сделана явной. Прежде дефолтом была ЗАПИСЬ, и
    # потеря токена --check в вызывающем коде превращала проверку в тихую правку
    # рабочего дерева прямо в CI, с бодрым PASS в придачу.
    before="$(_hashall README.md)"
    run env AWG_FACTS_ROOT="$TMP" bash "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"нужен режим"* ]]
    [ "$(_hashall README.md)" = "$before" ]
}

@test "facts: опечатка в режиме это код 2, а не молчаливая запись" {
    before="$(_hashall README.md)"
    run env AWG_FACTS_ROOT="$TMP" bash "$SCRIPT" --chek
    [ "$status" -eq 2 ]
    [ "$(_hashall README.md)" = "$before" ]
}

@test "facts: --check не пишет в файлы даже когда нашёл расхождение" {
    _sub README.md "Установщик $VER" "Установщик 9.99.9"
    before="$(_hashall README.md)"
    run _check
    [ "$status" -eq 1 ]
    [ "$(_hashall README.md)" = "$before" ]
}

# --- расхождение блока ---------------------------------------------------

@test "facts: правка блока руками ловится и файл назван" {
    _sub README.md "Установщик $VER" "Установщик 9.99.9"
    run _check
    [ "$status" -eq 1 ]
    [[ "$output" == *"README.md"* ]]
    [[ "$output" == *"разошёлся с источниками"* ]]
}

@test "facts: расхождение только в английском README тоже ловится" {
    # Классический дефект такого сторожа - проверить первый файл и выйти.
    _sub README.en.md "Also supported" "Also fine"
    run _check
    [ "$status" -eq 1 ]
    [[ "$output" == *"README.en.md"* ]]
    [[ "$output" == *"разошёлся с источниками"* ]]
}

# --- выведенность значений -----------------------------------------------

@test "facts: версия ВЫВОДИТСЯ из SCRIPT_VERSION, а не записана литералом" {
    # Кейс с правкой README доказывает лишь факт сравнения: захардкоженная
    # версия в генераторе оставила бы его зелёным. Здесь двигается ИСТОЧНИК.
    _sub install_amneziawg.sh "SCRIPT_VERSION=\"$VER\"" 'SCRIPT_VERSION="5.30.0"'
    _sub CHANGELOG.md "## [$VER] - " "## [5.30.0] - 2027-01-15"$'\n\n'"## [$VER] - "
    run _check
    [ "$status" -eq 1 ]
    [[ "$output" == *"5.30.0"* ]]
}

@test "facts: дата релиза ВЫВОДИТСЯ из заголовка CHANGELOG" {
    # Мутация ВАЛИДНОЙ другой датой: ломать формат заголовка недостаточно, такой
    # кейс пережил бы захардкоженную дату в генераторе.
    _sub CHANGELOG.md "## [$VER] - $REL" "## [$VER] - 2030-12-31"
    run _check
    [ "$status" -eq 1 ]
    [[ "$output" == *"2030-12-31"* ]]
}

@test "facts: смена матрицы без пересборки блока ловится" {
    # Ради этого сторож и существует: матрица уехала, README остался прежним.
    #
    # Мутация правит ИМЕННО version, а не id: блок рендерит версию, и первая
    # редакция этого теста ломала id - связь, которую сторож не держит. Тест
    # честно позеленел, ничего не проверив.
    _json "[x.__setitem__('version', '26.10') for x in d['platforms'] if x['id'] == 'ubuntu-26.04']"
    run _check
    [ "$status" -eq 1 ]
    [[ "$output" == *"26.10"* ]]
}

@test "facts: новая дата сверки в матрице обязана попасть в блок" {
    _json "d['verification']['last_verified'] = '2030-01-01'"
    run _check
    [ "$status" -eq 1 ]
    [[ "$output" == *"2030-01-01"* ]]
}

@test "facts: подписи архитектур ВЫВОДЯТСЯ из arm-build.yml" {
    # Мутация на ИЗВЕСТНУЮ метку: armhf -> arm64 убирает ARMv7 из блока.
    # Прежняя редакция меняла armhf на riscv64 и падала в валидацию ДО рендера,
    # то есть литеральная строка архитектур прошла бы тот кейс точно так же.
    _sub .github/workflows/arm-build.yml "arch: armhf" "arch: arm64"
    run _check
    [ "$status" -eq 1 ]
    [[ "$output" == *"x86_64, ARM64"* ]]
}

@test "facts: неизвестная архитектура в arm-build.yml не подставляется молча" {
    _sub .github/workflows/arm-build.yml "arch: armhf" "arch: riscv64"
    run _check
    [ "$status" -eq 1 ]
    [[ "$output" == *"riscv64"* ]]
}

# --- целость файла при записи --------------------------------------------

@test "facts: запись чинит блок и сохраняет ВЕСЬ остальной файл побайтово" {
    # Кейс, которого не хватало. Мутация "писать только блок" схлопывала README
    # с восьми сотен строк до тринадцати, и весь набор оставался зелёным.
    #
    # 🔴 Дрейф обязателен ДО записи: на файле без расхождения генератор не пишет
    # вовсе, и наивная проверка "запустить и сравнить" зеленела бы вакуумно.
    _sub README.md "Установщик $VER" "Установщик 9.99.9"
    _sub README.en.md "Installer $VER" "Installer 9.99.9"
    ru_before="$(_outside README.md)"
    en_before="$(_outside README.en.md)"

    run _write
    [ "$status" -eq 0 ]
    [[ "$output" == *"README.md"* ]]
    [[ "$output" == *"README.en.md"* ]]

    [ "$(_outside README.md)" = "$ru_before" ]
    [ "$(_outside README.en.md)" = "$en_before" ]

    run _check
    [ "$status" -eq 0 ]
}

@test "facts: повторная запись идемпотентна" {
    _sub README.md "Установщик $VER" "Установщик 9.99.9"
    run _write
    [ "$status" -eq 0 ]
    after_first="$(_hashall README.md)"
    run _write
    [ "$status" -eq 0 ]
    [ "$(_hashall README.md)" = "$after_first" ]
}

# --- маркеры -------------------------------------------------------------

@test "facts: пропавший маркер это отказ, а не тихий пропуск файла" {
    _sub README.md "<!-- facts:end -->" ""
    run _check
    [ "$status" -eq 1 ]
    [[ "$output" == *"нет маркеров"* ]]
}

@test "facts: вторая пара маркеров отвергается" {
    # Опаснее, чем кажется: без этой защиты запись поправила бы ПЕРВУЮ пару и
    # оставила на первом экране второй, устаревший датированный блок - ровно ту
    # беду, ради которой скрипт написан.
    _sub README.md "<!-- facts:begin -->" \
        "<!-- facts:begin --> старый блок <!-- facts:end -->"$'\n'"<!-- facts:begin -->"
    run _check
    [ "$status" -eq 1 ]
    [[ "$output" == *"больше одной пары"* ]]
}

@test "facts: перевёрнутый порядок маркеров отвергается своим сообщением" {
    _sub README.md "<!-- facts:begin -->" "@@MARK@@"
    _sub README.md "<!-- facts:end -->" "<!-- facts:begin -->"
    _sub README.md "@@MARK@@" "<!-- facts:end -->"
    run _check
    [ "$status" -eq 1 ]
    [[ "$output" == *"раньше маркера начала"* ]]
}

# --- формат входных данных -----------------------------------------------

@test "facts: битый JSON матрицы называется форматом, а не расхождением" {
    # Иначе трейсбек уходит тем же кодом, что настоящий дрейф, и вызывающая
    # проверка отправляет читателя пересобирать README вместо починки файла.
    printf '{ broken' > "$TMP/docs/support-matrix.json"
    run _check
    [ "$status" -eq 1 ]
    [[ "$output" == *"не прошёл формат"* ]]
    [[ "$output" != *"Traceback"* ]]
}

@test "facts: матрица без platforms называется форматом" {
    _json "d.pop('platforms')"
    run _check
    [ "$status" -eq 1 ]
    [[ "$output" == *"не прошёл формат"* ]]
    [[ "$output" != *"Traceback"* ]]
}

@test "facts: платформа без version называется форматом" {
    _json "d['platforms'][0].pop('version')"
    run _check
    [ "$status" -eq 1 ]
    [[ "$output" == *"не прошёл формат"* ]]
    [[ "$output" != *"Traceback"* ]]
}

@test "facts: невышедшая платформа в перечень не попадает" {
    # Ветка unreleased иначе не исполняется НИ ОДНИМ кейсом: в реальной матрице
    # таких платформ нет. Пометить существующую нельзя - Ubuntu 26.04 одна в
    # своей корзине, и кейс позеленел бы по посторонней причине (пустая корзина).
    # Поэтому платформа ДОБАВЛЯЕТСЯ синтетически.
    _json "d['platforms'].append({'id':'ubuntu-28.04','os':'ubuntu','version':'28.04','lifecycle':'unreleased','project_policy':'allowed'})"
    run _check
    [ "$status" -eq 0 ]
    [[ "$output" == *"совпадает с источниками"* ]]
}

@test "facts: пустая корзина project_policy это отказ, а не пустая строка блока" {
    _json "[x.__setitem__('project_policy', 'default') for x in d['platforms'] if x['id'] == 'ubuntu-26.04']"
    run _check
    [ "$status" -eq 1 ]
    [[ "$output" == *"allowed"* ]]
}

# --- профиль конфигурации ------------------------------------------------

@test "facts: параметр третьей линии литералом в шаблоне роняет обещание про 2.0" {
    printf '\nHeaderProtectionKey = ${AWG_HPK}\n' >> "$TMP/awg_common.sh"
    run _check
    [ "$status" -eq 1 ]
    [[ "$output" == *"AmneziaWG 2.0"* ]]
    [[ "$output" == *"awg_common.sh"* ]]
}

@test "facts: параметр третьей линии в форме echo ловится так же" {
    # 🔴 Форма, которую первая редакция сторожа пропускала ЦЕЛИКОМ, хотя именно
    # ею пишутся в конфиг опциональные I1-I5. HeaderProtectionKey тоже
    # опционален, значит его добавят ровно по этому образцу.
    printf '\n[[ -n "${AWG_HPK:-}" ]] && echo "HeaderProtectionKey = ${AWG_HPK}" >> "$tmpfile"\n' \
        >> "$TMP/awg_common.sh"
    run _check
    [ "$status" -eq 1 ]
    [[ "$output" == *"AmneziaWG 2.0"* ]]
}

@test "facts: сторож смотрит все шесть скриптов и не слепнет на отступе" {
    # Урезание списка файлов или потеря отступа в регулярке иначе остаются
    # незамеченными: параметры лежат в шаблонах С ОТСТУПОМ.
    printf '\n\tRandomTrailers = 1\n' >> "$TMP/manage_amneziawg_en.sh"
    run _check
    [ "$status" -eq 1 ]
    [[ "$output" == *"manage_amneziawg_en.sh"* ]]
}

@test "facts: законное упоминание параметра 3.x ложной тревоги не даёт" {
    # Обратная сторона трёх кейсов выше, и пробы здесь НЕ синтетические: это
    # реальные формы из нашего дерева - продолжение перечня параметров и
    # маскирование секретов в диагностическом отчёте.
    {
        printf '\n        ContentPaddingAddition HeaderProtectionKey MaxHandshakeAttempts \\\n'
        printf "        -e 's/^([[:space:]]*(PrivateKey|HeaderProtectionKey)[[:space:]]*=[[:space:]]*).*/x/I' \\\\\n"
    } >> "$TMP/awg_common.sh"
    run _check
    [ "$status" -eq 0 ]
    [[ "$output" == *"совпадает с источниками"* ]]
}

# --- отсутствующие входные файлы -----------------------------------------

@test "facts: пропавший входной файл называется по имени" {
    rm "$TMP/docs/support-matrix.json"
    run _check
    [ "$status" -eq 1 ]
    [[ "$output" == *"support-matrix.json"* ]]
    [[ "$output" != *"Traceback"* ]]
}
