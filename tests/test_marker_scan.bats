#!/usr/bin/env bats
# scripts/check-markers.sh: forbidden markers in commits AND in content.
#
# The case that matters is "marker in a file, clean commit message". The
# pull-request workflow used to read commit messages only, so such a line passed
# every check on the way in, and once merged the tag-time scan could not see it
# either - it diffs main..HEAD, and anything already in main is outside that
# range. Three lines reached the public tree that way before this was noticed.
#
# 🔴 The fixtures never spell a marker out. They build one at runtime from
# pieces, so this file does not need an exemption to describe what an exemption
# is for. A test that had to silence the very check it tests would be a poor
# witness for it.

SCRIPT="${BATS_TEST_DIRNAME}/../scripts/check-markers.sh"

# A tracker-shaped identifier, assembled so the literal never appears here.
_marker() { printf 'my%s-abcd' 'ai'; }

setup() {
    REPO="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$REPO"
    cd "$REPO" || return 1
    git init -q .
    git config user.email "tester@example.invalid"
    git config user.name "Tester"
    git config commit.gpgsign false
    echo "base" > file.txt
    git add file.txt
    git commit -q -m "base commit"
    BASE="$(git rev-parse HEAD)"
}

_commit() {  # _commit <message> [file-content]
    if [ $# -ge 2 ]; then
        printf '%s\n' "$2" >> file.txt
        git add file.txt
    else
        echo "harmless $RANDOM" >> file.txt
        git add file.txt
    fi
    git commit -q -m "$1"
}

@test "markers: a clean commit and clean content pass" {
    _commit "chore: tidy up"
    run bash "$SCRIPT" "$BASE" HEAD
    [ "$status" -eq 0 ]
    [[ "$output" == *"No forbidden markers"* ]]
}

@test "markers: a marker in the commit MESSAGE fails" {
    _commit "chore: see $(_marker) for context"
    run bash "$SCRIPT" "$BASE" HEAD
    [ "$status" -eq 1 ]
    [[ "$output" == *"carries a forbidden marker"* ]]
}

# 🔴 The regression this script exists for.
@test "markers: a marker in FILE CONTENT fails even with a clean message" {
    _commit "chore: tidy up" "# see $(_marker) for context"
    run bash "$SCRIPT" "$BASE" HEAD
    [ "$status" -eq 1 ]
    [[ "$output" == *"added lines carry a forbidden marker"* ]]
}

@test "markers: content hits name the offending text" {
    _commit "chore: tidy up" "# see $(_marker) for context"
    run bash "$SCRIPT" "$BASE" HEAD
    [ "$status" -eq 1 ]
    [[ "$output" == *"for context"* ]]
}

@test "markers: a line tagged as exempt is skipped" {
    _commit "chore: tidy up" "MARKERS='$(_marker)'  # allow-markers"
    run bash "$SCRIPT" "$BASE" HEAD
    [ "$status" -eq 0 ]
}

# 🔴 The exemption is per line. If it ever becomes per file, or per diff, this
# goes red - which is the whole difference between the new rule and the old one.
@test "markers: an exempt line does not cover an untagged one beside it" {
    printf "%s  # allow-markers\n" "MARKERS='$(_marker)'" >> file.txt
    printf "# and here without a tag: %s\n" "$(_marker)" >> file.txt
    git add file.txt
    git commit -q -m "chore: two lines"
    run bash "$SCRIPT" "$BASE" HEAD
    [ "$status" -eq 1 ]
    [[ "$output" == *"without a tag"* ]]
}

@test "markers: the number of exempt lines is reported even when zero" {
    _commit "chore: tidy up"
    run bash "$SCRIPT" "$BASE" HEAD
    [ "$status" -eq 0 ]
    [[ "$output" == *"0 tagged exempt"* ]]
}

@test "markers: a co-author trailer in a commit message fails" {
    _commit "chore: tidy up

Co-authored-by: Someone <someone@example.invalid>"
    run bash "$SCRIPT" "$BASE" HEAD
    [ "$status" -eq 1 ]
    [[ "$output" == *"co-author trailer"* ]]
}

# Automated authors sign their own commits; rejecting that would reject every
# dependency bump, which is not what the rule is for.
@test "markers: an automated author's own trailer is not held against it" {
    echo "bump" >> file.txt
    git add file.txt
    git -c user.email="49699333+dependabot[bot]@users.noreply.github.com" \
        -c user.name="dependabot[bot]" \
        commit -q -m "build: bump a dependency

Co-authored-by: dependabot[bot] <support@github.com>"
    run bash "$SCRIPT" "$BASE" HEAD
    [ "$status" -eq 0 ]
}

# --- text on stdin ----------------------------------------------------------
# The third surface. A pull request title and body are published when the
# request opens and outlive it, yet neither is a commit message nor a diff
# line, so both git-side scans above look straight past them.

# 🔴 The case the text mode exists for: the marker sits ONLY in the body.
# Commits and diff are clean, both scans above pass, and before this mode the
# text went public with every check green.
@test "markers: a marker in text on stdin fails" {
    body="Summary of the change.

    Closes $(_marker)."
    run bash "$SCRIPT" --text "pull request body" <<< "$body"
    [ "$status" -eq 1 ]
    [[ "$output" == *"pull request body carries a forbidden marker"* ]]
}

@test "markers: clean text on stdin passes" {
    run bash "$SCRIPT" --text "pull request title" <<< "feat: an ordinary title"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No forbidden markers in pull request title"* ]]
}

# The label is what tells whoever has to fix it WHICH text is at fault, so it
# has to reach the message rather than stay decoration at the call site.
@test "markers: the text scan names the surface it was given" {
    run bash "$SCRIPT" --text "annotated tag message" <<< "see $(_marker)"
    [ "$status" -eq 1 ]
    [[ "$output" == *"annotated tag message carries"* ]]
}

@test "markers: the per-line exemption applies to text too" {
    line="MARKERS='$(_marker)'  # allow-markers"
    run bash "$SCRIPT" --text "pull request body" <<< "$line"
    [ "$status" -eq 0 ]
}

# Without a label the scan would still run and still report, just anonymously.
# Refusing keeps the caller honest about what it is scanning.
@test "markers: --text without a label refuses rather than scanning anonymously" {
    run bash "$SCRIPT" --text <<< "x"
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage"* ]]
}

# An empty body is the normal state of a small pull request, not an error.
@test "markers: empty text on stdin passes" {
    run bash "$SCRIPT" --text "pull request body" < /dev/null
    [ "$status" -eq 0 ]
}
@test "markers: an unreadable base ref is a loud failure, not a clean pass" {
    run bash "$SCRIPT" "does-not-exist-ref" HEAD
    [ "$status" -ne 0 ]
    [[ "$output" != *"No forbidden markers"* ]]
}

@test "markers: called without a base ref it refuses rather than scanning nothing" {
    run bash "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage"* ]]
}
