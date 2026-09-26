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

@test "16: a broken percent-encoded link fails on its own (the plain link stays valid)" {
    # Only the encoded link is damaged: the plain link to the same heading still
    # resolves, so the failure can come from the encoded one alone.
    sed -i 's/%D1%80%D0%B0%D0%B7/%D1%80%D0%B1%D0%B7/' docs/B.md
    _run_guard
    [[ "$output" == *"битая межфайловая или HTML-ссылка: ../A.md#рбзздел-про-кириллицу"* || "$output" == *"битая межфайловая или HTML-ссылка: ../A.md#р"* ]]
    [[ "$output" == *"FAIL: битые межфайловые или HTML-ссылки на якоря"* ]]
}

@test "16: a cross-file HTML link to a missing anchor fails" {
    sed -i 's|href="../A.md#explicit-adv"|href="../A.md#gone-html-adv"|' docs/B.md
    _run_guard
    [[ "$output" == *"битая межфайловая или HTML-ссылка: ../A.md#gone-html-adv"* ]]
}

@test "16: finding no links at all is a failure, not a pass" {
    printf '# B\n\nno links here\n' > docs/B.md
    printf '# RU\n' > INSTALL_VPS.ru.md
    _run_guard
    [[ "$output" == *"FAIL: межфайловые ссылки НЕ ПРОВЕРЕНЫ: разбор не нашёл ни одной"* ]]
}

@test "16: link forms the parser cannot see are rejected, an uppercase URL scheme is not" {
    printf '[ok](HTTPS://example.com/X.md#nothing)\n' >> docs/B.md
    _run_guard
    [[ "$output" == *"PASS: межфайловые и HTML-ссылки на якоря резолвятся ("* ]]
    for form in "[r]: ../A.md#gone" "<a href='../A.md#gone'>x</a>" '<a href = "../A.md#gone">x</a>' '<a href= "../A.md#gone">x</a>' \
                '<A HREF="../A.md#gone">x</A>' '[x](../A.MD#gone)' '[x]( ../A.md#gone)' '<a href=../A.md#gone>x</a>' '[r]: <../A.md#gone>' \
                $'<a\nhref=\x27../A.md#gone\x27>x</a>' $'<a\nhref=../A.md#gone>x</a>' $'<a\nHREF=\"../A.md#gone\">x</a>'; do
        git checkout -q -- docs/B.md
        printf '%s\n' "$form" >> docs/B.md
        _run_guard
        [[ "$output" == *"неканоническая форма ссылки"* ]] || { echo "not rejected: $form"; false; }
    done
    # External URLs are outside this guard in every form: none of these may fail it.
    for ext in '[r]: https://github.com/o/r/blob/main/README.md#x' "<a href='https://example.com'>x</a>" \
               '<a href="https://example.com/X.MD#y">x</a>' '[x](HTTPS://example.com/README.MD#y)' \
               '[x](https://example.com/?href=foo.md#x)' '[r]: <https://example.com/README.md#x>'; do
        git checkout -q -- docs/B.md
        printf '%s\n' "$ext" >> docs/B.md
        _run_guard
        [[ "$output" != *"неканоническая форма ссылки"* ]] || { echo "external URL rejected: $ext"; false; }
        [[ "$output" == *"PASS: межфайловые и HTML-ссылки на якоря резолвятся ("* ]] || { echo "external URL broke the check: $ext"; false; }
    done
}

@test "guard stops when grep has no -P support" {
    mkdir -p "$BATS_TEST_TMPDIR/shim"
    printf '#!/bin/sh\ncase " $* " in *" -"*P*) exit 2 ;; esac\nexec /usr/bin/grep "$@"\n' > "$BATS_TEST_TMPDIR/shim/grep"
    chmod +x "$BATS_TEST_TMPDIR/shim/grep"
    PATH="$BATS_TEST_TMPDIR/shim:$PATH" run bash "$FIX/scripts/check-docs-consistency.sh"
    [ "$status" -eq 2 ]
    [[ "$output" == *"нужен grep с поддержкой -P"* ]]
}

@test "7b: a missing file and a grep error are failures, not passes" {
    _run_guard
    [[ "$output" == *"README.en.md: нет файла - проверка 7b по нему НЕ ВЫПОЛНЕНА"* ]]
    [[ "$output" == *"FAIL: дефолтный режим снова назван раздельной маршрутизацией"* ]]
    # all ten files present and grep failing on the 7b pattern
    for f in ADVANCED.md ADVANCED.en.md README.md README.en.md INSTALL_VPS.md INSTALL_VPS.ru.md WARP-RU.md WARP-RU.en.md CASCADE.md CASCADE.en.md; do
        [ -f "$f" ] || printf '# %s\n' "$f" > "$f"
    done
    mkdir -p "$BATS_TEST_TMPDIR/shim7b"
    printf '#!/bin/sh\ncase "$*" in *"modes 2 and 3"*) exit 2 ;; esac\nexec /usr/bin/grep "$@"\n' > "$BATS_TEST_TMPDIR/shim7b/grep"
    chmod +x "$BATS_TEST_TMPDIR/shim7b/grep"
    PATH="$BATS_TEST_TMPDIR/shim7b:$PATH" run bash "$FIX/scripts/check-docs-consistency.sh"
    [[ "$output" == *"grep не смог выполнить шаблон - проверка НЕ ВЫПОЛНЕНА"* ]]
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

@test "17: a pair with no extractable anchors fails instead of comparing two empty sets" {
    printf '# WARP\n' > WARP-RU.md
    printf '# WARP\n' > WARP-RU.en.md
    _run_guard
    [[ "$output" == *"WARP-RU.md WARP-RU.en.md: явные якоря не извлечены"* ]]
    [[ "$output" == *"FAIL: явные якоря в парах RU/EN разошлись"* ]]
}

@test "18: the corrected links pass, the old misrouted forms fail" {
    _run_guard
    [[ "$output" == *"PASS: исправленные ссылки не вернулись в чужие разделы"* ]]
    printf '[README, управление клиентами](README.md#posle-ustanovki)\n' >> INSTALL_VPS.ru.md
    _run_guard
    [[ "$output" == *"«управление клиентами» живёт в README.md#upravlenie"* ]]
    [[ "$output" == *"FAIL: ссылка снова ведёт в чужой раздел"* ]]
    printf '[ADVANCED, импорт клиентов](ADVANCED.md#client-compat-adv)\n' >> INSTALL_VPS.ru.md
    _run_guard
    [[ "$output" == *"про два QR-кода нужен ADVANCED.md#vpnuri-adv"* ]]
}

@test "18: the wrong target with a different link text still fails" {
    printf '[команды клиентов](README.md#posle-ustanovki)\n' >> INSTALL_VPS.ru.md
    _run_guard
    [[ "$output" == *"ссылка на README.md#posle-ustanovki"* ]]
    [[ "$output" == *"FAIL: ссылка снова ведёт в чужой раздел"* ]]
}

@test "18: the wrong target in other wrappers fails, the same link inside a code block does not" {
    printf '[a](./README.md#posle-ustanovki)\n' >> INSTALL_VPS.ru.md
    _run_guard
    [[ "$output" == *"ссылка на README.md#posle-ustanovki"* ]]
    git checkout -q -- INSTALL_VPS.ru.md
    printf '<a href="ADVANCED.md#client-compat-adv">x</a>\n' >> INSTALL_VPS.ru.md
    printf '# A\n\n<a id="client-compat-adv"></a>\n## C\n' > ADVANCED.md
    _run_guard
    [[ "$output" == *"ссылка на ADVANCED.md#client-compat-adv"* ]]
    git checkout -q -- INSTALL_VPS.ru.md
    printf '```\n[old](README.md#posle-ustanovki)\n```\n' >> INSTALL_VPS.ru.md
    _run_guard
    [[ "$output" == *"PASS: исправленные ссылки не вернулись в чужие разделы"* ]]
}

@test "18: a title, a leading slash, angle brackets or percent-encoding do not hide the wrong target" {
    for form in '[a](README.md#posle-ustanovki "t")' '[a](/README.md#posle-ustanovki)' \
                '[a](<README.md#posle-ustanovki>)' '[a](README.md#posle%2Dustanovki)' $'[a](\n README.md#posle-ustanovki)'; do
        git checkout -q -- INSTALL_VPS.ru.md
        printf '%s\n' "$form" >> INSTALL_VPS.ru.md
        _run_guard
        [[ "$output" == *"ссылка на README.md#posle-ustanovki"* ]] || { echo "not caught: $form"; false; }
    done
    # A path named in prose is not a link.
    git checkout -q -- INSTALL_VPS.ru.md
    printf 'See README.md#posle-ustanovki for details.\n' >> INSTALL_VPS.ru.md
    _run_guard
    [[ "$output" == *"PASS: исправленные ссылки не вернулись в чужие разделы"* ]]
}

@test "code blocks: an indented closing fence ends the block, an unclosed block fails" {
    printf '```bash\nx\n   ```\n[y](../A.md#gone-after-fence)\n' >> docs/B.md
    _run_guard
    [[ "$output" == *"битая межфайловая или HTML-ссылка: ../A.md#gone-after-fence"* ]]
    git checkout -q -- docs/B.md
    printf '```bash\nx\n' >> docs/B.md
    _run_guard
    [[ "$output" == *"docs/B.md: незакрытый блок кода"* ]]
    [[ "$output" == *"FAIL: битые межфайловые или HTML-ссылки на якоря"* ]]
}

@test "18: a missing file is a failure, not a silent skip" {
    git rm -qf INSTALL_VPS.ru.md
    _run_guard
    [[ "$output" == *"нет INSTALL_VPS.ru.md - проверка по нему НЕ ВЫПОЛНЕНА"* ]]
    [[ "$output" == *"FAIL: ссылка снова ведёт в чужой раздел"* ]]
}

@test "8: a concrete version in the Q&A discussion template placeholder fails" {
    mkdir -p .github/ISSUE_TEMPLATE .github/DISCUSSION_TEMPLATE
    printf '      placeholder: "e.g., 5.x.y"\n' > .github/ISSUE_TEMPLATE/bug_report.yml
    printf '      placeholder: "e.g., 5.x.y"\n' > .github/DISCUSSION_TEMPLATE/q-a.yml
    _run_guard
    [[ "$output" == *"PASS: issue-template: placeholder версии нейтральный"* ]]
    printf '      placeholder: "e.g., 5.1.2"\n' > .github/DISCUSSION_TEMPLATE/q-a.yml
    _run_guard
    [[ "$output" == *".github/DISCUSSION_TEMPLATE/q-a.yml: конкретный X.Y.Z в placeholder версии"* ]]
    rm .github/DISCUSSION_TEMPLATE/q-a.yml
    _run_guard
    [[ "$output" == *"нет .github/DISCUSSION_TEMPLATE/q-a.yml - проверка по нему НЕ ВЫПОЛНЕНА"* ]]
}
