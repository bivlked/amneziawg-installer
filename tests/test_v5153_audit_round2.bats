#!/usr/bin/env bats
# v5.15.3 round-2 audit fixes: guards for the CI/process hardening tasks.
#
# D3: preflight-check.sh bats verdict considers exit code, not only "^not ok".
# D4: check-docs-consistency.sh verifies the FULL OS + arch matrix, not just 26.04.
# D5: docs-check.yml path filter includes the checker script itself.
#
# Scripts here are not sourceable (they run top-to-bottom), so D3/D5 use
# structural guards against regression; D4 also has an independent functional
# guard that every declared doc actually carries the whole support matrix.

ROOT="$BATS_TEST_DIRNAME/.."

# ---------- D3: preflight bats exit-code awareness ----------

@test "D3: preflight captures bats exit code (bats_rc)" {
    run grep -F 'bats_rc' "$ROOT/scripts/preflight-check.sh"
    [ "$status" -eq 0 ]
}

@test "D3: preflight defines a _warn helper" {
    run grep -E '^_warn\(\)' "$ROOT/scripts/preflight-check.sh"
    [ "$status" -eq 0 ]
}

@test "D3: preflight has the flock-less / TOLERATE tolerant branch" {
    run grep -F 'AWG_PREFLIGHT_TOLERATE_BATS_RC' "$ROOT/scripts/preflight-check.sh"
    [ "$status" -eq 0 ]
    run grep -F 'command -v flock' "$ROOT/scripts/preflight-check.sh"
    [ "$status" -eq 0 ]
}

@test "D3: preflight FAILs non-zero bats exit without 'not ok' on flock hosts" {
    # The strict branch must exist: rc != 0 and no 'not ok' -> _bad on flock host.
    run grep -F 'вероятный сбой запуска' "$ROOT/scripts/preflight-check.sh"
    [ "$status" -eq 0 ]
}

# ---------- D4: full OS + arch matrix in docs-check ----------

@test "D4: check-docs takes the OS set from the support matrix, not from a copy" {
    # Раньше здесь проверялось наличие литерального EXPECTED_OS=(...) в самом
    # скрипте. Это была шестая копия матрицы, и тест закреплял её существование.
    # Путь переопределяем через AWG_MATRIX_FILE, чтобы проверку 4b можно было
    # прогнать на испорченной копии; значение по умолчанию то же самое.
    run grep -F 'AWG_MATRIX_FILE:-docs/support-matrix.json' "$ROOT/scripts/check-docs-consistency.sh"
    [ "$status" -eq 0 ]
    run grep -E 'mapfile -t EXPECTED_OS' "$ROOT/scripts/check-docs-consistency.sh"
    [ "$status" -eq 0 ]
    # Литерального массива остаться не должно: иначе снова две правды.
    # Ловим литерал С СОДЕРЖИМЫМ, а не пустое объявление EXPECTED_OS=(),
    # которое нужно, чтобы зависящая проверка ARM не итерировала по
    # неустановленному массиву и не печатала незаработанный PASS.
    run grep -E '^[[:space:]]*EXPECTED_OS=\([^)]' "$ROOT/scripts/check-docs-consistency.sh"
    [ "$status" -ne 0 ]
    # Архитектуры в матрицу не переезжали, их литерал на месте.
    run grep -E '^EXPECTED_ARCH=\(' "$ROOT/scripts/check-docs-consistency.sh"
    [ "$status" -eq 0 ]
}

@test "D4: the tokens derived from the matrix are the five expected ones" {
    # Проверяем не id, а ТОКЕНЫ, которые чекер потом ищет в документах.
    # По id тест был слабее: подмена поля os у debian-12 на ubuntu
    # деградирует токен до голого "12", который грепается где угодно, а id
    # остаётся прежним и тест этого не видит.
    local m="$ROOT/docs/support-matrix.json"
    [ -f "$m" ]
    run python3 -c "
import io, json, sys
d = json.load(io.open(sys.argv[1], encoding='utf-8'))
print(';'.join(p['version'] if p['os'] == 'ubuntu' else 'Debian ' + p['version']
                for p in d['platforms']))
" "$m"
    [ "$status" -eq 0 ]
    for tok in "24.04" "25.10" "26.04" "Debian 12" "Debian 13"; do
        [[ "$output" == *"$tok"* ]]
    done
    # Ровно пять, ни больше ни меньше: выпавшая платформа гасит заодно и
    # проверку ARM-таргетов, которая ходит по тому же набору.
    [ "$(printf '%s' "$output" | tr -cd ';' | wc -c)" -eq 4 ]
}

@test "D4 functional: every OS-matrix doc carries the whole release set" {
    local files=(README.md README.en.md install_amneziawg.sh install_amneziawg_en.sh .github/ISSUE_TEMPLATE/bug_report.yml)
    local tokens=("24.04" "25.10" "26.04" "Debian 12" "Debian 13")
    for f in "${files[@]}"; do
        for t in "${tokens[@]}"; do
            run grep -qF "$t" "$ROOT/$f"
            [ "$status" -eq 0 ] || { echo "missing '$t' in $f"; false; }
        done
    done
}

@test "D4 functional: README RU/EN + issue template carry the whole arch set" {
    local files=(README.md README.en.md .github/ISSUE_TEMPLATE/bug_report.yml)
    local tokens=("x86_64" "ARM64" "ARMv7")
    for f in "${files[@]}"; do
        for t in "${tokens[@]}"; do
            run grep -qF "$t" "$ROOT/$f"
            [ "$status" -eq 0 ] || { echo "missing '$t' in $f"; false; }
        done
    done
}

@test "D4 functional: the real checker passes the OS+arch matrix on this repo" {
    run bash "$ROOT/scripts/check-docs-consistency.sh"
    # Whole script must be green, and specifically the matrix lines must PASS.
    [ "$status" -eq 0 ]
    [[ "$output" == *"матрица ОС полна"* ]]
    [[ "$output" == *"матрица архитектур согласована"* ]]
}

# ---------- D5: docs-check.yml triggers on the checker itself ----------

@test "D5: docs-check.yml path filter includes the checker script" {
    # Must appear under both push and pull_request paths (>= 2 occurrences).
    n=$(grep -cF 'scripts/check-docs-consistency.sh' "$ROOT/.github/workflows/docs-check.yml")
    [ "$n" -ge 2 ]
}

# ---------- C-ARM: reproducible module ref + manifest ----------

_source_arm() {
    # build-arm-deb.sh has a source guard, so sourcing exposes helpers only.
    unset MODULE_VERSION
    source "$ROOT/scripts/build-arm-deb.sh"
}

@test "C-ARM: _arm_module_ref returns MODULE_VERSION env when set (highest precedence)" {
    _source_arm
    local pin; pin="$(mktemp)"; echo "v1.0.PINNED" > "$pin"
    MODULE_VERSION="v9.9.OVERRIDE"
    run _arm_module_ref "$pin"
    [ "$status" -eq 0 ]
    [ "$output" = "v9.9.OVERRIDE" ]
    rm -f "$pin"
}

@test "C-ARM: _arm_module_ref reads a tag from the pin file when env is empty" {
    _source_arm
    local pin; pin="$(mktemp)"
    printf '# comment\nv1.0.20260223\n' > "$pin"
    run _arm_module_ref "$pin"
    [ "$status" -eq 0 ]
    [ "$output" = "v1.0.20260223" ]
    rm -f "$pin"
}

@test "C-ARM: _arm_module_ref treats HEAD pin as default-branch (empty output)" {
    _source_arm
    local pin; pin="$(mktemp)"
    printf '# only comments and HEAD\nHEAD\n' > "$pin"
    run _arm_module_ref "$pin"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    rm -f "$pin"
}

@test "C-ARM: _arm_module_ref returns empty when pin file has only comments" {
    _source_arm
    local pin; pin="$(mktemp)"
    printf '# a\n#b\n\n' > "$pin"
    run _arm_module_ref "$pin"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    rm -f "$pin"
}

@test "C-ARM: shipped pin file points at the 1.0.x line, not a floating HEAD" {
    # Was "defaults to HEAD" until 2026-07-31. Upstream merged AmneziaWG 3.0 into
    # its default branch, so HEAD stopped being an AWG 2.0 module and stopped
    # compiling on kernel 6.1 (nla_put_uint), which broke debian-bookworm-arm64.
    # The compile part was fixed upstream on 2026-07-31 (v3.0.20260731-04), but the
    # first part still holds: HEAD is a 3.0 module, so the pin is what keeps the ARM
    # prebuilts on 2.0.
    # The expected value is spelled out on purpose: moving this pin decides which
    # protocol version the ARM prebuilts implement, so it should be a deliberate
    # edit that updates this test, not a silent one.
    run _arm_module_ref_shipped_value
    [ "$status" -eq 0 ]
    [ "$output" = "v1.0.20260725" ]
}

_arm_module_ref_shipped_value() {
    grep -vE '^[[:space:]]*(#|$)' "$ROOT/scripts/arm-module-version.txt" | head -n1 | tr -d '[:space:]'
}

@test "C-ARM: build script writes a manifest with module_commit" {
    run grep -F 'manifest.json' "$ROOT/scripts/build-arm-deb.sh"
    [ "$status" -eq 0 ]
    run grep -F 'module_commit' "$ROOT/scripts/build-arm-deb.sh"
    [ "$status" -eq 0 ]
}

@test "C-ARM: arm-build.yml uploads the manifest asset" {
    run grep -F 'manifest.json' "$ROOT/.github/workflows/arm-build.yml"
    [ "$status" -eq 0 ]
}
