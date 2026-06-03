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

@test "D4: check-docs defines EXPECTED_OS and EXPECTED_ARCH sets" {
    run grep -E '^EXPECTED_OS=\(' "$ROOT/scripts/check-docs-consistency.sh"
    [ "$status" -eq 0 ]
    run grep -E '^EXPECTED_ARCH=\(' "$ROOT/scripts/check-docs-consistency.sh"
    [ "$status" -eq 0 ]
}

@test "D4: EXPECTED_OS lists all five supported releases" {
    line=$(grep -E '^EXPECTED_OS=\(' "$ROOT/scripts/check-docs-consistency.sh")
    [[ "$line" == *"24.04"* ]]
    [[ "$line" == *"25.10"* ]]
    [[ "$line" == *"26.04"* ]]
    [[ "$line" == *"Debian 12"* ]]
    [[ "$line" == *"Debian 13"* ]]
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
