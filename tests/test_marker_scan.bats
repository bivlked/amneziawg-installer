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
