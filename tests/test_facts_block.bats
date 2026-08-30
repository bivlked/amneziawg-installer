#!/usr/bin/env bats
# Регрессия на генератор блока "факты на дату" (scripts/update-facts-block.sh).
#
# Блок стоит на первом экране обоих README и несёт дату, то есть обещает
# читателю свежесть. Опасен здесь не отказ, а ТИХИЙ УСПЕХ: проверка, которая
# печатает "совпадает", ничего при этом не сверив, оставляет датированную
# неправду на витрине проекта и выглядит убедительнее обычного текста.
# Поэтому каждый кейс ниже ломает ровно одну связь и требует, чтобы сторож
# на ней упал.
#
# Рабочее дерево не трогается: генератор получает корень через AWG_FACTS_ROOT,
# и все правки идут по временной копии нужных файлов.

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT="$ROOT/scripts/update-facts-block.sh"
    TMP="$BATS_TEST_TMPDIR/repo"
    # Версия нужна тесту, чтобы целиться в заголовок ИМЕННО текущего релиза.
    VER="$(grep -m1 '^SCRIPT_VERSION=' "$ROOT/install_amneziawg.sh" | cut -d'"' -f2)"
    [ -n "$VER" ] || { echo "не прочитался SCRIPT_VERSION"; return 1; }

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
    AWG_FACTS_ROOT="$TMP" bash "$SCRIPT" 2>&1
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

@test "facts: контроль - нетронутая копия проходит" {
    run _check
    [ "$status" -eq 0 ]
    [[ "$output" == *"совпадает с источниками"* ]]
}

@test "facts: правка блока руками ловится и файл назван" {
    _sub README.md "Установщик 5" "Установщик 9"
    run _check
    [ "$status" -ne 0 ]
    [[ "$output" == *"README.md"* ]]
    [[ "$output" == *"разошёлся с источниками"* ]]
}

@test "facts: расхождение только в английском README тоже ловится" {
    # Классический дефект такого сторожа - проверить первый файл и выйти.
    _sub README.en.md "Also supported" "Also fine"
    run _check
    [ "$status" -ne 0 ]
    [[ "$output" == *"README.en.md"* ]]
}

@test "facts: смена матрицы без пересборки блока ловится" {
    # Ради этого сторож и существует: матрица уехала, README остался прежним.
    #
    # Мутация правит ИМЕННО version, а не id: блок рендерит версию, и первая
    # редакция этого теста ломала id - связь, которую сторож не держит. Тест
    # честно позеленел, ничего не проверив. Мутация обязана ломать ту самую
    # связь, на которой стоит проверка.
    _sub docs/support-matrix.json '"version": "26.04",' '"version": "26.10",'
    run _check
    [ "$status" -ne 0 ]
    [[ "$output" == *"26.10"* ]]
}

@test "facts: новая дата сверки в матрице обязана попасть в блок" {
    _sub docs/support-matrix.json '"last_verified": "' '"last_verified": "2030-01-01", "_old": "'
    run _check
    [ "$status" -ne 0 ]
    [[ "$output" == *"2030-01-01"* ]]
}

@test "facts: режим записи чинит ровно то, на что жаловалась проверка" {
    _sub README.md "Установщик 5" "Установщик 9"
    run _check
    [ "$status" -ne 0 ]
    run _write
    [ "$status" -eq 0 ]
    run _check
    [ "$status" -eq 0 ]
}

@test "facts: пропавшие маркеры это отказ, а не тихий пропуск файла" {
    _sub README.md "<!-- facts:end -->" ""
    run _check
    [ "$status" -ne 0 ]
    [[ "$output" == *"маркер"* ]]
}

@test "facts: нет заголовка версии в CHANGELOG - отказ с названной причиной" {
    # Иначе дата релиза молча взялась бы из чего попало или сторож упал бы
    # трейсбеком, что читается как поломка инструмента, а не как ошибка данных.
    # Ломается заголовок ИМЕННО текущей версии: замена по первому "## ["
    # попадала в "## [Unreleased]", заголовок версии оставался цел, и тест
    # зеленел, не проверив ничего.
    _sub CHANGELOG.md "## [$VER] - " "## [$VER] "
    run _check
    [ "$status" -ne 0 ]
    [[ "$output" == *"CHANGELOG.md"* ]]
}

@test "facts: неизвестная архитектура в arm-build.yml не подставляется молча" {
    # Доказывает, что строка архитектур ВЫВОДИТСЯ из матрицы сборки, а не
    # записана литералом: литерал на эту мутацию не отреагировал бы.
    _sub .github/workflows/arm-build.yml "arch: armhf" "arch: riscv64"
    run _check
    [ "$status" -ne 0 ]
    [[ "$output" == *"riscv64"* ]]
}

@test "facts: параметр третьей линии в шаблоне конфига роняет обещание про 2.0" {
    printf '\nHeaderProtectionKey = ${AWG_HPK}\n' >> "$TMP/awg_common.sh"
    run _check
    [ "$status" -ne 0 ]
    [[ "$output" == *"AmneziaWG 2.0"* ]]
    [[ "$output" == *"awg_common.sh"* ]]
}

@test "facts: упоминание параметра 3.x не в форме присваивания ложной тревоги не даёт" {
    # Обратная сторона предыдущего кейса: эти имена законно встречаются в
    # перечнях параметров и в маскировании секретов, и сторож обязан молчать.
    printf '\n# HeaderProtectionKey упоминается в комментарии\necho "HeaderProtectionKey = скрыт"\n' \
        >> "$TMP/awg_common.sh"
    run _check
    [ "$status" -eq 0 ]
}
