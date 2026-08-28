#!/bin/bash
# preflight-check.sh - единый прогон всех pre-tag проверок перед релизом
#
# Запускает в одной команде полный pre-tag чеклист (см. docs/RELEASE_PROCESS.md).
# Каждая проверка печатает PASS/FAIL, в конце - сводка. Exit!=0 если хоть одна
# провалилась.
#
# Использование:
#   bash scripts/preflight-check.sh
#   BASE_REF=origin/main bash scripts/preflight-check.sh   # detached checkout
#
# Переменные окружения:
#   BASE_REF   git-ref для diff-проверок пунктуации/маркеров. Если не задан,
#              берётся первый существующий из: main, origin/main. На detached
#              checkout без локального main задавайте явно BASE_REF=origin/main.
#   LOG_RANGE  git-диапазон для проверки commit-сообщений. Default: <base>..HEAD
#              (только коммиты ветки релиза; merged-from-main коммиты с legacy
#              human/bot Co-authored-by трейлерами в проверку НЕ попадают).
#
# Проверки:
#   1. bash -n на 6 скриптах
#   2. shellcheck -s bash -S warning на 6 скриптах
#   3. bats tests/ (FAIL при "^not ok" ИЛИ при non-zero exit без "not ok" на
#      flock-хосте; на flock-less хосте non-zero без "not ok" = WARN)
#   4. реально добавленных em/en-dash (U+2013/U+2014) в diff BASE_REF...HEAD = 0
#   5. AI/tool-mention в diff + commit-логе = 0
#   6. Co-authored-by в commit-логе = 0
#   7. SCRIPT_VERSION консистентен в 4 версионированных скриптах
#   8. SHA-пины синхронны (update-sha-pins.sh --verify)
#   9. Согласованность документации (check-docs-consistency.sh)
#  10. Подписи релиза (verify-signatures.sh): нет подписей = WARN,
#      есть но неверные = FAIL

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || { echo "ОШИБКА: не удалось перейти в $REPO_ROOT" >&2; exit 2; }

# BASE_REF fallback: уважаем явно заданный, иначе первый резолвящийся из
# main / origin/main. Это переживает detached checkout (CI на теге), где
# локального main нет, но origin/main подтянут (fetch-depth:0 + fetch main).
if [[ -z "${BASE_REF:-}" ]]; then
    for _cand in main origin/main; do
        if git rev-parse --verify "$_cand" >/dev/null 2>&1; then
            BASE_REF="$_cand"
            break
        fi
    done
fi
if [[ -z "${BASE_REF:-}" ]]; then
    echo "ОШИБКА: не найден base-ref для diff-проверок (пробовал main, origin/main)." >&2
    echo "        Задайте явно, например: BASE_REF=origin/main bash scripts/preflight-check.sh" >&2
    exit 2
fi
LOG_RANGE="${LOG_RANGE:-${BASE_REF}..HEAD}"

SCRIPTS=(
    install_amneziawg.sh
    install_amneziawg_en.sh
    manage_amneziawg.sh
    manage_amneziawg_en.sh
    awg_common.sh
    awg_common_en.sh
)

# Запрещённые маркеры в публичном тексте и коммитах (case-insensitive).
# Слитный список во избежание ложных срабатываний на доменных терминах.
FORBIDDEN_MARKERS='claude|anthropic|\bcodex\b|chatgpt|openai|gpt-[0-9]|copilot|\bllm\b'

PASS=0
FAIL=0
WARN=0
declare -a RESULTS

_ok()   { echo "PASS: $1"; RESULTS+=("PASS: $1"); PASS=$((PASS+1)); }
_bad()  { echo "FAIL: $1" >&2; RESULTS+=("FAIL: $1"); FAIL=$((FAIL+1)); }
_warn() { echo "WARN: $1" >&2; RESULTS+=("WARN: $1"); WARN=$((WARN+1)); }

echo "=== preflight-check (BASE_REF=$BASE_REF, LOG_RANGE=$LOG_RANGE) ==="

# --- 1. bash -n ---
syntax_fail=0
for f in "${SCRIPTS[@]}"; do
    if ! bash -n "$f" 2>/tmp/preflight-syntax.$$; then
        cat /tmp/preflight-syntax.$$ >&2
        syntax_fail=1
    fi
done
rm -f /tmp/preflight-syntax.$$
if [[ "$syntax_fail" -eq 0 ]]; then _ok "bash -n (6 scripts)"; else _bad "bash -n (6 scripts)"; fi

# --- 2. shellcheck ---
if command -v shellcheck >/dev/null 2>&1; then
    sc_fail=0
    for f in "${SCRIPTS[@]}"; do
        if ! shellcheck -s bash -S warning "$f"; then
            sc_fail=1
        fi
    done
    if [[ "$sc_fail" -eq 0 ]]; then _ok "shellcheck -S warning (6 scripts)"; else _bad "shellcheck -S warning (6 scripts)"; fi
else
    _bad "shellcheck not found in PATH"
fi

# --- 3. bats ---
# Реальные падения теста = строки "^not ok". Но один лишь grep "not ok" слеп к
# раннему краху bats (повреждённое окружение, отсутствующий хелпер, ошибка
# запуска): такой прогон вернёт non-zero БЕЗ строк "not ok" и раньше молча
# проходил как "0 failures". Поэтому учитываем И exit-code, И "^not ok":
#   - есть "^not ok"            -> FAIL (реальные падения теста);
#   - нет "^not ok", но rc != 0 -> на flock-less хосте (Windows/Git Bash, где
#     require_flock-тесты SKIP, а bats печатает "Executed N instead of expected M"
#     и возвращает non-zero без падений) ИЛИ при AWG_PREFLIGHT_TOLERATE_BATS_RC=1
#     это терпимо (WARN); иначе (Linux CI с flock) rc!=0 без "not ok" = аномалия
#     запуска -> FAIL с полным выводом.
# Авто-детект flock: на Windows flock отсутствует -> tolerant-ветка без ручного
# env. На Linux CI flock есть -> строгий режим. Релизный gate не пропустит
# инфраструктурный сбой как успех.
if command -v bats >/dev/null 2>&1; then
    bats_rc=0
    bats_out=$(bats tests/ 2>&1) || bats_rc=$?
    bats_fails=$(printf '%s\n' "$bats_out" | grep -cE '^not ok' || true)
    if [[ "$bats_fails" -gt 0 ]]; then
        printf '%s\n' "$bats_out" | grep -E '^not ok' >&2
        _bad "bats tests/ ($bats_fails failing)"
    elif [[ "$bats_rc" -ne 0 ]]; then
        if [[ "${AWG_PREFLIGHT_TOLERATE_BATS_RC:-0}" == "1" ]] || ! command -v flock >/dev/null 2>&1; then
            _warn "bats tests/ exit $bats_rc без 'not ok' (flock-less хост или TOLERATE_BATS_RC=1, терпимо)"
        else
            printf '%s\n' "$bats_out" >&2
            _bad "bats tests/ exit $bats_rc без 'not ok' - вероятный сбой запуска (повреждённое окружение)"
        fi
    else
        _ok "bats tests/ (0 failures)"
    fi
else
    _bad "bats not found in PATH"
fi

# --- 4. newly added em/en-dash in diff ---
# Политика проекта (CLAUDE.md): новый текст - только hyphen-minus; legacy
# em/en-dash в существующих строках сохраняется без mass-purge, а point-edit
# легаси-строки НЕ обязывает переписывать тире на этой строке. Поэтому ловим
# ТОЛЬКО реально добавленные тире. word-diff=porcelain помечает префиксом '+'
# лишь изменённые слова, так что тире в неизменённой части правленой строки в
# '+' не попадает (legacy не даёт ложный FAIL); под флаг идёт только заново
# внесённый символ тире (новая строка/слово). Байты UTF-8: en-dash U+2013 =
# E2 80 93, em-dash U+2014 = E2 80 94 (LC_ALL=C + \xHH, codepoint-форма \x{}
# падает на GNU grep Git Bash).
dash_added=$(git diff --word-diff=porcelain "${BASE_REF}...HEAD" \
    | LC_ALL=C grep -nP '^\+.*(\xe2\x80\x93|\xe2\x80\x94)' || true)
if [[ -z "$dash_added" ]]; then
    _ok "no newly added em/en-dash in diff ${BASE_REF}...HEAD"
else
    echo "$dash_added" >&2
    _bad "newly added em/en-dash in diff ${BASE_REF}...HEAD"
fi

# --- 5. AI/tool-mention in diff + commit log ---
marker_fail=0
if git rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
    # Исключаем файлы, которые ОПРЕДЕЛЯЮТ список маркеров: у них имена
    # маркеров стоят как паттерн поиска, а не как нарушение. Без этого
    # проверка находит сама себя и обязательный предмержевый прогон
    # падает на ветке, которая ничего не нарушила.
    diff_markers=$(git diff "${BASE_REF}...HEAD" -- . ':(exclude)scripts/preflight-check.sh' ':(exclude).github/workflows/commit-hygiene.yml' | grep -nP '^\+' | grep -iP "$FORBIDDEN_MARKERS" || true)
    if [[ -n "$diff_markers" ]]; then
        echo "diff markers:" >&2; echo "$diff_markers" >&2
        marker_fail=1
    fi
fi
log_markers=$(git log "$LOG_RANGE" --format='%B' 2>/dev/null | grep -iP "$FORBIDDEN_MARKERS" || true)
if [[ -n "$log_markers" ]]; then
    echo "commit-log markers:" >&2; echo "$log_markers" >&2
    marker_fail=1
fi
if [[ "$marker_fail" -eq 0 ]]; then _ok "no AI/tool markers in diff + commit log"; else _bad "AI/tool markers found"; fi

# --- 6. Co-authored-by in commit log ---
coauthor=$(git log "$LOG_RANGE" --format='%B' 2>/dev/null | grep -iE '\bco-authored-by\b' || true)
if [[ -z "$coauthor" ]]; then
    _ok "no Co-authored-by in commit log ($LOG_RANGE)"
else
    echo "$coauthor" >&2
    _bad "Co-authored-by found in commit log ($LOG_RANGE)"
fi

# --- 7. SCRIPT_VERSION consistency ---
ref_ver=$(awk -F'"' '/^SCRIPT_VERSION=/{print $2; exit}' install_amneziawg.sh)
ver_fail=0
if [[ ! "$ref_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "install_amneziawg.sh SCRIPT_VERSION='$ref_ver' not semver" >&2
    ver_fail=1
fi
for f in install_amneziawg_en.sh manage_amneziawg.sh manage_amneziawg_en.sh; do
    v=$(awk -F'"' '/^SCRIPT_VERSION=/{print $2; exit}' "$f")
    if [[ "$v" != "$ref_ver" ]]; then
        echo "$f SCRIPT_VERSION='$v' != '$ref_ver'" >&2
        ver_fail=1
    fi
done
# Заголовки-комментарии версии во всех 6 скриптах (# Версия: / # Version:).
# awg_common*.sh не имеют SCRIPT_VERSION-переменной, только этот заголовок.
for f in "${SCRIPTS[@]}"; do
    hv=$(grep -m1 -oE '^# (Версия|Version):[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+' "$f" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+$')
    if [[ "$hv" != "$ref_ver" ]]; then
        echo "$f version header='$hv' != '$ref_ver'" >&2
        ver_fail=1
    fi
done
# AWG_COMMON_VERSION-переменная в обеих библиотеках == ref_ver (version guard,
# issue #183). manage сверяет её по MAJOR.MINOR; при релизе бампается вместе с
# остальными, поэтому здесь требуем точного равенства.
for f in awg_common.sh awg_common_en.sh; do
    cv=$(awk -F'"' '/^AWG_COMMON_VERSION=/{print $2; exit}' "$f")
    if [[ "$cv" != "$ref_ver" ]]; then
        echo "$f AWG_COMMON_VERSION='$cv' != '$ref_ver'" >&2
        ver_fail=1
    fi
done
if [[ "$ver_fail" -eq 0 ]]; then _ok "SCRIPT_VERSION + 6 headers + AWG_COMMON_VERSION consistent ($ref_ver)"; else _bad "SCRIPT_VERSION/header drift"; fi

# --- 8. SHA pins ---
if bash "$SCRIPT_DIR/update-sha-pins.sh" --verify; then
    _ok "SHA pins in lockstep (update-sha-pins.sh --verify)"
else
    _bad "SHA pins out of sync (run: bash scripts/update-sha-pins.sh)"
fi

# --- 9. Docs consistency ---
# Тот же скрипт гоняет docs-check workflow. Здесь - часть единого pre-tag gate.
if bash "$SCRIPT_DIR/check-docs-consistency.sh" >/tmp/preflight-docs.$$ 2>&1; then
    _ok "docs consistency (check-docs-consistency.sh)"
else
    cat /tmp/preflight-docs.$$ >&2
    _bad "docs consistency (run: bash scripts/check-docs-consistency.sh)"
fi
rm -f /tmp/preflight-docs.$$

# --- 10. Release signatures ---
# Signatures are produced offline and committed under signing/ before the tag.
# release.yml refuses to publish without them, so the point of checking here is
# to fail on the maintainer's machine, where the commit can still be amended,
# rather than after the tag is already pushed.
#
# Absent signatures are a WARNING, not a failure: preflight also runs on
# ordinary branches where no release is being prepared. Present-but-wrong is a
# hard failure, because that is a real defect rather than a state.
sig_count=$(find signing -name '*.minisig' 2>/dev/null | grep -c . || true)
sig_expected=$(bash "$SCRIPT_DIR/signed-file-list.sh" | grep -c . || true)
if [[ "$sig_count" -eq 0 ]]; then
    _warn "no release signatures staged (fine outside a release; required before a tag)"
elif [[ "$sig_count" -ne "$sig_expected" ]]; then
    _bad "release signatures: $sig_count file(s) under signing/, expected $sig_expected"
elif ! command -v minisign >/dev/null 2>&1; then
    _warn "minisign not installed - $sig_count signature(s) present but unverified locally (CI will verify)"
else
    # The tag these signatures must name is derived from the version being
    # released, not guessed: that is exactly the tag the maintainer will push.
    #
    # Signatures stay in the tree between releases, so on any branch that edits
    # a signed script they stop matching. That is ordinary development, not a
    # defect. The two are told apart by the tag the signatures name: one naming
    # an earlier release is stale by design and only warns, one naming THIS
    # version and still failing is real. A gate that is red on every branch
    # stops being read, and then it protects nothing.
    sig_tag=$(sed -n 's/^trusted comment: amneziawg-installer \([^ ]*\) .*/\1/p' \
                  signing/*.minisig 2>/dev/null | head -n1)
    if bash "$SCRIPT_DIR/verify-signatures.sh" "v${ref_ver}" >/tmp/preflight-sig.$$ 2>&1; then
        _ok "release signatures verified for v${ref_ver} ($sig_expected files)"
    elif [[ -n "$sig_tag" && "$sig_tag" != "v${ref_ver}" ]]; then
        _warn "signatures on disk are for $sig_tag, not v${ref_ver} - re-sign before tagging"
    else
        cat /tmp/preflight-sig.$$ >&2
        _bad "release signatures (run: bash scripts/verify-signatures.sh v${ref_ver})"
    fi
    rm -f /tmp/preflight-sig.$$
fi

# --- Summary ---
echo ""
echo "=== preflight summary: $PASS passed, $FAIL failed, $WARN warnings ==="
for r in "${RESULTS[@]}"; do echo "  $r"; done

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
