#!/usr/bin/env bash
# check-markers.sh <base> [head]
#
# Fails when a forbidden marker appears in the commits of <base>..<head> OR in
# the lines those commits ADD. One implementation, one list, two surfaces.
#
# Why the content half exists. The pull-request workflow used to read commit
# messages only, and preflight-check.sh reads the diff but runs at tag time over
# main..HEAD - so anything already merged is outside its range. A marker written
# into a FILE therefore passed every gate on the way in and became invisible the
# moment it landed. That is not hypothetical: on 30 aug 2026 a release added two
# such lines and a pull request the next day added a third, all with green
# checks.
#
# Why the list lives here and nowhere else. It used to be copied into two files
# with a comment asking future readers to keep them in step. They drifted anyway
# - one copy carried a phrase the other did not - and nothing noticed, because
# the check that would notice was the one being copied.
#
# 🔴 Why the exclusion is per LINE, not per file. The two files that used to
# define the list were skipped whole, on the reasoning that their marker words
# are a search pattern rather than a violation. True of the pattern line, false
# of everything else in them, and that blanket skip hid ordinary prose in those
# files for as long as it existed - two of the three leaks above sat in a file
# the scan was told to ignore. A line that genuinely has to spell a marker out
# carries the tag below, and only that line is skipped.
set -uo pipefail

# The one and only list. Case-insensitive. Word boundaries where a marker also
# occurs inside ordinary domain terms.
MARKERS='generated with|claude|anthropic|\bcodex\b|chatgpt|openai|gpt-[0-9]|copilot|\bllm\b|myai-[a-z0-9]{4}'  # allow-markers

# A line carrying this tag is exempt from the CONTENT scan. Deliberately visible
# in review: silencing a real hit with it is a conscious act someone has to read
# past, not a file-wide rule nobody sees. It does not exempt commit messages.
ALLOW_TAG='allow-markers'

usage() {
    echo "usage: $0 <base-ref> [head-ref]" >&2
    exit 2
}

base="${1:-}"
head_ref="${2:-HEAD}"
[ -n "$base" ] || usage

tmp="$(mktemp -d)" || { echo "cannot create a temp dir" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT

bad=0

# --- commits -----------------------------------------------------------------
# Collected before the loop rather than piped into it: read through a process
# substitution a failure is invisible, the body never runs, and the scan reports
# the commits clean having looked at none of them.
if ! shas="$(git rev-list "$base..$head_ref" 2>/dev/null)"; then
    echo "cannot list commits over $base..$head_ref" >&2
    exit 1
fi

while read -r sha; do
    [ -n "$sha" ] || continue
    author="$(git log -1 --format='%ae' "$sha")"
    # Automated authors sign their own commits and would fail on their own
    # trailer; rejecting that would mean rejecting every dependency bump.
    case "$author" in
        *dependabot*|*github-actions*) continue ;;
    esac
    msg="$(git log -1 --format='%B' "$sha")"
    hit="$(printf '%s' "$msg" | grep -inE "$MARKERS" || true)"
    if [ -n "$hit" ]; then
        echo "commit ${sha:0:7} carries a forbidden marker:" >&2
        printf '%s\n' "$hit" >&2
        bad=1
    fi
    # Same commits, same exemption, so it rides along rather than repeating the
    # loop elsewhere. Reported separately: the fix is different.
    trailer="$(printf '%s' "$msg" | grep -inE '\bco-authored-by\b' || true)"
    if [ -n "$trailer" ]; then
        echo "commit ${sha:0:7} carries a co-author trailer:" >&2
        printf '%s\n' "$trailer" >&2
        bad=1
    fi
done <<< "$shas"

# --- added lines -------------------------------------------------------------
if git rev-parse --verify "$base" >/dev/null 2>&1; then
    # Three dots: with two, anything the base branch changed after this one left
    # it reads as an addition made here.
    if ! git diff "$base...$head_ref" --unified=0 -- . > "$tmp/raw"; then
        echo "cannot diff $base...$head_ref" >&2
        exit 1
    fi
    # Only grep is allowed to "fail" here, and only because finding no added
    # lines is a legitimate result.
    grep '^+' "$tmp/raw" | grep -v '^+++' > "$tmp/added" || true

    skipped="$(grep -c -- "$ALLOW_TAG" "$tmp/added" 2>/dev/null || true)"
    [ -n "$skipped" ] || skipped=0
    # Printed even when zero: an exemption that nobody sees is an exemption that
    # grows.
    echo "content scan: $(wc -l < "$tmp/added") added lines, $skipped tagged exempt"

    hits="$(grep -v -- "$ALLOW_TAG" "$tmp/added" | grep -inE "$MARKERS" || true)"
    if [ -n "$hits" ]; then
        echo "added lines carry a forbidden marker:" >&2
        printf '%s\n' "$hits" >&2
        bad=1
    fi
fi

if [ "$bad" -ne 0 ]; then
    echo "Remove the marker. If a line must spell one out, tag that line with ${ALLOW_TAG}." >&2
    exit 1
fi

echo "No forbidden markers in $base..$head_ref (commits and added lines)."
