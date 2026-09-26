#!/usr/bin/env bats
# Checks 16-18 of scripts/check-docs-consistency.sh (audit 2026-09, question 16).
# Each test builds a tiny throwaway repository with the real script, first in a
# correct state (the check must PASS) and then with one defect (it must FAIL with
# its own message). A check that only ever passes proves nothing, so every check
# here is shown failing on the defect it exists for. The other checks of the
# script fail in such a tiny repository; only the lines of checks 16-18 matter.

SCRIPT_SRC="$BATS_TEST_DIRNAME/../scripts/check-docs-consistency.sh"

setup() {
    FIX="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$FIX/scripts" "$FIX/docs"
    cp "$SCRIPT_SRC" "$FIX/scripts/"
    cd "$FIX" || return 1
    git init -q .
    cat > A.md <<'EOF'
# A

<a id="explicit-adv"></a>
## Раздел про кириллицу

Text.
EOF
    cat > docs/B.md <<'EOF'
# B

- [explicit](../A.md#explicit-adv)
- [heading](../A.md#раздел-про-кириллицу)
- [percent](../A.md#%D1%80%D0%B0%D0%B7%D0%B4%D0%B5%D0%BB-%D0%BF%D1%80%D0%BE-%D0%BA%D0%B8%D1%80%D0%B8%D0%BB%D0%BB%D0%B8%D1%86%D1%83)
- <a href="../A.md#explicit-adv">html cross-file</a>
- <a href="#b">html same file</a>
- [external](https://github.com/bivlked/amneziawg-installer/blob/main/README.en.md#nowhere)

## B
EOF
    for p in ADVANCED CASCADE WARP-RU; do
        printf '# %s\n\n<a id="one-adv"></a>\n## One\n' "$p" > "$p.md"
        printf '# %s\n\n<a id="one-adv"></a>\n## One\n' "$p" > "$p.en.md"
    done
    printf '# RU\n\n[README, управление клиентами](README.md#upravlenie)\n' > INSTALL_VPS.ru.md
    printf '# README\n\n<a id="upravlenie"></a>\n## Upr\n' > README.md
    git add -A >/dev/null
}

_run_guard() { run bash "$FIX/scripts/check-docs-consistency.sh"; }

@test "16: correct cross-file, percent-encoded and HTML links pass; external URLs are ignored" {
    _run_guard
    [[ "$output" == *"PASS: межфайловые и HTML-ссылки на якоря резолвятся ("* ]]
    [[ "$output" != *"битая межфайловая"* ]]
}

@test "16: a cross-file link to a missing anchor fails" {
    sed -i 's|../A.md#explicit-adv)|../A.md#gone-adv)|' docs/B.md
    _run_guard
    [[ "$output" == *"битая межфайловая или HTML-ссылка: ../A.md#gone-adv"* ]]
    [[ "$output" == *"FAIL: битые межфайловые или HTML-ссылки на якоря"* ]]
}

@test "16: a percent-encoded link to a renamed Cyrillic heading fails" {
    sed -i 's/^## Раздел про кириллицу$/## Другой раздел/' A.md
    _run_guard
    [[ "$output" == *"битая межфайловая или HTML-ссылка: ../A.md#раздел-про-кириллицу"* ]]
}

@test "16: an HTML href to a missing anchor in the same file fails" {
    sed -i 's|href="#b"|href="#nope"|' docs/B.md
    _run_guard
    [[ "$output" == *"битая межфайловая или HTML-ссылка: (этот файл)#nope"* ]]
}

@test "16: a link to a file that does not exist fails" {
    sed -i 's|../A.md#explicit-adv)|../Missing.md#explicit-adv)|' docs/B.md
    _run_guard
    [[ "$output" == *"ссылка на несуществующий файл: ../Missing.md#explicit-adv"* ]]
}

@test "17: equal RU/EN anchor sets pass, an anchor in one language only fails" {
    _run_guard
    [[ "$output" == *"PASS: явные якоря в парах RU/EN совпадают"* ]]
    printf '<a id="only-ru-adv"></a>\n' >> CASCADE.md
    _run_guard
    [[ "$output" == *"CASCADE.md / CASCADE.en.md: наборы якорей расходятся"* ]]
    [[ "$output" == *"only-ru-adv"* ]]
    [[ "$output" == *"FAIL: явные якоря в парах RU/EN разошлись"* ]]
}

@test "18: the corrected links pass, the old misrouted forms fail" {
    _run_guard
    [[ "$output" == *"PASS: исправленные ссылки не вернулись в чужие разделы"* ]]
    printf '[README, управление клиентами](README.md#posle-ustanovki)\n' >> INSTALL_VPS.ru.md
    _run_guard
    [[ "$output" == *"«управление клиентами» ведёт в «После установки»"* ]]
    [[ "$output" == *"FAIL: ссылка снова ведёт в чужой раздел"* ]]
    printf '[ADVANCED, импорт клиентов](ADVANCED.md#client-compat-adv)\n' >> INSTALL_VPS.ru.md
    _run_guard
    [[ "$output" == *"про два QR ведёт в таблицу совместимости"* ]]
}
