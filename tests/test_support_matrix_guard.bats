#!/usr/bin/env bats
# Регрессия на сторожа матрицы ОС (check-docs-consistency.sh, проверки 4 и 4b).
#
# Три раунда ревью нашли в этом коде по несколько дефектов каждый, и все были
# одного рода: сторож печатал успех, не сделав работы. Ни один из них не был
# закреплён тестом, поэтому четвёртый раунд нашёл бы их снова. Каждый кейс здесь
# это ровно тот вход, на котором сторож однажды промолчал.
#
# Матрица подсовывается через AWG_MATRIX_FILE, рабочее дерево не трогается.

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT="$ROOT/scripts/check-docs-consistency.sh"
    SRC="$ROOT/docs/support-matrix.json"
    MUT="$BATS_TEST_TMPDIR/matrix.json"
}

# Собрать испорченную копию матрицы: аргумент это тело python, меняющее d.
_mutate() {
    python3 - "$SRC" "$MUT" "$1" <<'PY'
import io, json, sys
d = json.load(io.open(sys.argv[1], encoding='utf-8'))
exec(sys.argv[3])
io.open(sys.argv[2], 'w', encoding='utf-8', newline='\n').write(
    json.dumps(d, ensure_ascii=False, indent=2))
PY
}

_run_guard() {
    cd "$ROOT" || return 1
    AWG_MATRIX_FILE="$MUT" bash "$SCRIPT" 2>&1
}

@test "matrix-guard: контроль - нетронутая матрица проходит целиком" {
    cp "$SRC" "$MUT"
    run _run_guard
    [ "$status" -eq 0 ]
    [[ "$output" == *"0 failed"* ]]
}

@test "matrix-guard: пустой список платформ не является успехом" {
    # Раньше давал PASS "матрица ОС полна во всех заявленных местах ()" и
    # незаработанный PASS у проверки ARM-покрытия.
    _mutate "d['platforms'] = []"
    run _run_guard
    [ "$status" -ne 0 ]
    [[ "$output" == *"ARM prebuilt-покрытие НЕ ПРОВЕРЕНО"* ]]
}

@test "matrix-guard: пустая version не превращает проверку в тавтологию" {
    # Худший из найденных: токен становился пустой строкой, grep -qF '' матчится
    # в любом файле, и весь прогон был зелёным на заведомо ложной матрице.
    _mutate "[x.__setitem__('version', '') for x in d['platforms'] if x['id'] == 'ubuntu-24.04']"
    run _run_guard
    [ "$status" -ne 0 ]
}

@test "matrix-guard: version не строкой отвергается как формат, а не как неполнота документов" {
    _mutate "d['platforms'][0]['version'] = ['24.04']"
    run _run_guard
    [ "$status" -ne 0 ]
    [[ "$output" == *"не удалось вывести набор ОС"* ]]
}

@test "matrix-guard: неизвестное семейство ОС отвергается" {
    # Иначе платформа с os fedora превращалась в токен вида "Debian 41".
    _mutate "d['platforms'][0]['os'] = 'fedora'"
    run _run_guard
    [ "$status" -ne 0 ]
}

@test "matrix-guard: сломанный формат называется форматом, а не расхождением дат" {
    # Неперехваченное исключение шло тем же кодом, что и настоящее расхождение,
    # и отправляло читателя пересчитывать даты вместо починки файла.
    _mutate "d['verification'] = '2026-08-29'"
    run _run_guard
    [ "$status" -ne 0 ]
    [[ "$output" == *"матрица не прошла формат"* ]]
    [[ "$output" != *"разошёлся с датами"* ]]
}

@test "matrix-guard: битая last_verified не проходит мимо разбора дат" {
    _mutate "d['verification']['last_verified'] = '2026-13-45'"
    run _run_guard
    [ "$status" -ne 0 ]
    [[ "$output" == *"матрица не прошла формат"* ]]
}

@test "matrix-guard: released обязателен" {
    _mutate "d['platforms'][0]['released'] = None"
    run _run_guard
    [ "$status" -ne 0 ]
    [[ "$output" == *"матрица не прошла формат"* ]]
}

@test "matrix-guard: отсутствие default у семейства ловится так же, как их избыток" {
    # Обход по НАЙДЕННЫМ ключам не мог обнаружить отсутствующее семейство, и
    # матрица без единой рекомендованной Ubuntu проходила зелёной.
    _mutate "[x.__setitem__('project_policy', 'allowed') for x in d['platforms'] if x['id'] == 'ubuntu-24.04']"
    run _run_guard
    [ "$status" -ne 0 ]
    [[ "$output" == *"default"* ]]
}

@test "matrix-guard: рекомендовать систему без поддержки вендора нельзя" {
    _mutate "[x.__setitem__('project_policy', 'allowed') for x in d['platforms'] if x['id'] == 'ubuntu-25.10']"
    run _run_guard
    [ "$status" -ne 0 ]
}

@test "matrix-guard: расхождение lifecycle с датами называется своим именем" {
    # Главное, ради чего проверка существует.
    _mutate "[x.__setitem__('lifecycle', 'supported') for x in d['platforms'] if x['id'] == 'debian-12']"
    run _run_guard
    [ "$status" -ne 0 ]
    [[ "$output" == *"разошёлся с датами"* ]]
    [[ "$output" == *"debian-12"* ]]
}

@test "matrix-guard: протухший снимок внешних фактов предупреждает, но не роняет" {
    # Краснеть просто от течения времени значит приучить к красному.
    _mutate "d['verification']['last_verified'] = '2020-01-01'"
    run _run_guard
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN"* ]]
    [[ "$output" != *"command not found"* ]]
}
