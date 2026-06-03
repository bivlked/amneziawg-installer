#!/bin/bash
# build-release-notes.sh - assemble bilingual GitHub release notes (and a
# descriptive title) from CHANGELOG.md (RU) + CHANGELOG.en.md (EN) for one
# version. release.yml calls this so the published release already carries both
# languages and a real title; the manual `gh release edit` becomes an emergency
# fallback rather than a required per-release step.
#
# Usage:
#   build-release-notes.sh <X.Y.Z>            # bilingual body -> stdout
#   build-release-notes.sh --title <X.Y.Z>    # descriptive title -> stdout
#
# Body layout (the established bilingual template):
#   ## Русская версия
#   [English version below](#english-version)
#   <RU section>
#   <a id="english-version"></a>
#   ## English version
#   <EN section>
#
# Title: from the EN lead line "**vX.Y.Z** - <summary>." -> "vX.Y.Z: <summary>";
# falls back to "vX.Y.Z" if no lead sentence is present.
#
# Exit 1 if the version section is missing in either changelog, 2 on usage error.
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

mode="body"
if [[ "${1:-}" == "--title" ]]; then mode="title"; shift; fi
version="${1:-}"
if [[ -z "$version" ]]; then
    echo "usage: build-release-notes.sh [--title] <X.Y.Z>" >&2
    exit 2
fi

# Allow overriding the changelog paths for testing.
RU_CHANGELOG="${RU_CHANGELOG:-$REPO_ROOT/CHANGELOG.md}"
EN_CHANGELOG="${EN_CHANGELOG:-$REPO_ROOT/CHANGELOG.en.md}"
esc="${version//./\\.}"

# Section body: lines after "## [X.Y.Z] ..." up to the next "## [" heading.
_section() {
    awk "/^## \\[${esc}\\]/{found=1; next} /^## \\[/{if(found) exit} found" "$1"
}

# Drop leading and trailing blank lines.
_trim_blanks() {
    sed -e '/./,$!d' | tac | sed -e '/./,$!d' | tac
}

for f in "$RU_CHANGELOG" "$EN_CHANGELOG"; do
    if ! grep -q "^## \[${esc}\]" "$f" 2>/dev/null; then
        echo "::error::version ${version} not found in $(basename "$f")" >&2
        exit 1
    fi
done

en_body="$(_section "$EN_CHANGELOG" | _trim_blanks)"

if [[ "$mode" == "title" ]]; then
    # Lead line like "**v5.15.3** - short summary. More text..."
    local_lead="$(printf '%s\n' "$en_body" | grep -m1 -E '^\*\*v?'"${esc}"'\*\*' || true)"
    summary=""
    if [[ -n "$local_lead" ]]; then
        summary="${local_lead#*\*\* }"   # drop "**vX.Y.Z** "
        summary="${summary#- }"           # drop a leading "- "
        summary="${summary%%. *}"         # keep only the first sentence
        summary="${summary%.}"            # drop a trailing period
        summary="${summary//\*/}"         # strip stray bold markers
    fi
    if [[ -n "$summary" && "$summary" != "$local_lead" ]]; then
        printf 'v%s: %s\n' "$version" "$summary"
    else
        printf 'v%s\n' "$version"
    fi
    exit 0
fi

ru_body="$(_section "$RU_CHANGELOG" | _trim_blanks)"

printf '## Русская версия\n\n'
printf '[English version below](#english-version)\n\n'
printf '%s\n\n' "$ru_body"
printf '<a id="english-version"></a>\n\n'
printf '## English version\n\n'
printf '%s\n' "$en_body"
