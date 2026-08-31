#!/usr/bin/env bats
# Tests for T9 (v5.15.3): scripts/build-release-notes.sh assembles a bilingual
# release body and a descriptive title from the RU/EN changelogs, so release.yml
# no longer needs a manual `gh release edit` for the Russian section and title.

load test_helper

SCRIPT="$BATS_TEST_DIRNAME/../scripts/build-release-notes.sh"

setup() {
    TEST_DIR=$(mktemp -d)
    cat > "$TEST_DIR/ru.md" <<'EOF'
# Changelog

## [Unreleased]

---

## [5.15.3] - 2026-06-03

**v5.15.3** - поддерживающий релиз. Чинит мелочи.

### Исправлено

- РУ-пункт про багфикс.

---

## [5.15.2] - 2026-06-02

**v5.15.2** - прошлый релиз.
EOF
    cat > "$TEST_DIR/en.md" <<'EOF'
# Changelog

## [Unreleased]

---

## [5.15.3] - 2026-06-03

**v5.15.3** - a maintenance release. Fixes small things.

### Fixed

- EN bugfix bullet.

---

## [5.15.2] - 2026-06-02

**v5.15.2** - the previous release.
EOF
    export RU_CHANGELOG="$TEST_DIR/ru.md"
    export EN_CHANGELOG="$TEST_DIR/en.md"
}

teardown() { rm -rf "$TEST_DIR"; }

@test "T9 body: bilingual layout with both sections, link and anchor" {
    run bash "$SCRIPT" 5.15.3
    [ "$status" -eq 0 ]
    [[ "$output" == *"## Русская версия"* ]]
    [[ "$output" == *"[English version below](#english-version)"* ]]
    [[ "$output" == *"РУ-пункт про багфикс."* ]]
    [[ "$output" == *'<a id="english-version"></a>'* ]]
    [[ "$output" == *"## English version"* ]]
    [[ "$output" == *"EN bugfix bullet."* ]]
}

@test "T9 body: RU section comes before the English anchor" {
    run bash "$SCRIPT" 5.15.3
    [ "$status" -eq 0 ]
    local ru_pos en_pos
    ru_pos=$(printf '%s\n' "$output" | grep -n 'РУ-пункт' | head -1 | cut -d: -f1)
    en_pos=$(printf '%s\n' "$output" | grep -n 'english-version"></a>' | head -1 | cut -d: -f1)
    [ "$ru_pos" -lt "$en_pos" ]
}

@test "T9 body: only the requested version is included" {
    run bash "$SCRIPT" 5.15.3
    [ "$status" -eq 0 ]
    [[ "$output" != *"previous release"* ]]
    [[ "$output" != *"прошлый релиз"* ]]
}

@test "T9 title: descriptive title from the EN lead sentence" {
    run bash "$SCRIPT" --title 5.15.3
    [ "$status" -eq 0 ]
    [ "$output" = "v5.15.3: a maintenance release" ]
}

@test "T9 title: falls back to the bare tag when there is no lead" {
    cat > "$EN_CHANGELOG" <<'EOF'
# Changelog
## [5.15.3] - 2026-06-03

### Fixed
- no lead paragraph here.
EOF
    # RU must also contain the version (body path validates both).
    run bash "$SCRIPT" --title 5.15.3
    [ "$status" -eq 0 ]
    [ "$output" = "v5.15.3" ]
}

@test "T9: missing version in either changelog exits 1" {
    run bash "$SCRIPT" 9.9.9
    [ "$status" -eq 1 ]
    [[ "$output" == *"not found"* ]]
}

@test "T9: usage error without a version exits 2" {
    run bash "$SCRIPT"
    [ "$status" -eq 2 ]
}

# The release process rehearses the pipeline on a throwaway pre-release tag
# (vX.Y.Z-rc1). release.yml passes the tag name through verbatim, so a version
# parser that rejects the suffix would kill the rehearsal at the notes step,
# before it reached the draft, the upload, the asset count and the publish -
# the whole point of rehearsing. The pre-release takes the base version's
# section: a pre-release has no changelog section of its own, and should not.

@test "T9: a pre-release suffix takes the base version section" {
    run bash "$SCRIPT" 5.15.3-rc1
    [ "$status" -eq 0 ]
    [[ "$output" == *"5.15.3"* ]]
    [[ "$output" == *"РУ-пункт про багфикс"* ]]
}

@test "T9: a pre-release suffix yields the base version title" {
    run bash "$SCRIPT" --title 5.15.3-rc1
    [ "$status" -eq 0 ]
    base=$(bash "$SCRIPT" --title 5.15.3)
    [ "$output" = "$base" ]
}

@test "T9: a malformed version is still rejected" {
    run bash "$SCRIPT" '5.15.3['
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid version format"* ]]
}

@test "T9: a heading with no body under it is refused, not published empty" {
    # The ordinary way this goes wrong: the section is opened during release
    # prep and the bullets are written later. Checking only for the heading let
    # that publish a release whose body was the bilingual skeleton and nothing
    # else, behind a green run.
    python3 - "$TEST_DIR/ru.md" <<'PY'
import io, sys
p = sys.argv[1]
t = io.open(p, encoding='utf-8', newline='').read()
i = t.index('## [5.15.3]')
j = t.index('## [5.15.2]')
io.open(p, 'w', encoding='utf-8', newline='').write(
    t[:i] + '## [5.15.3] - 2026-06-03\n\n' + t[j:])
PY
    run bash "$SCRIPT" 5.15.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"is empty"* ]]
}

@test "T9: a body line quoting the heading format does not cut the notes" {
    # The project prescribes the heading format "## [X.Y.Z] - YYYY-MM-DD", so
    # quoting it inside a changelog entry is natural. Ending the section on any
    # "## [" dropped everything after such a line, silently and with rc 0.
    python3 - "$TEST_DIR/en.md" <<'PY'
import io, sys
p = sys.argv[1]
t = io.open(p, encoding='utf-8', newline='').read()
old = '- EN bugfix bullet.'
assert t.count(old) == 1
io.open(p, 'w', encoding='utf-8', newline='').write(
    t.replace(old, '- Format is `## [X.Y.Z] - YYYY-MM-DD`, quoted here:\n'
                   '## [X.Y.Z] - YYYY-MM-DD\n' + old, 1))
PY
    run bash "$SCRIPT" 5.15.3
    [ "$status" -eq 0 ]
    [[ "$output" == *"EN bugfix bullet."* ]]
}
