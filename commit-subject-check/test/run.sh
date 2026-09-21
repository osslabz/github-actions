#!/usr/bin/env bash
#
# Checks the commit-subject gate against a fixture repository with a remote, so every kind of
# push the gate meets (a plain push, a new branch, a force-push, a dispatch) has a range to read.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly HERE
readonly SCRIPT="$HERE/../check-commit-subjects.sh"
WORK="$(mktemp -d)"
readonly WORK
readonly ZERO="0000000000000000000000000000000000000000"
readonly UNKNOWN_SHA="1234567890abcdef1234567890abcdef12345678"
trap 'rm -rf "$WORK"' EXIT

export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid

readonly SEED="$WORK/seed"
readonly CLONE="$WORK/clone"

commit() {
    git -C "$SEED" commit --quiet --allow-empty -m "$1"
    git -C "$SEED" rev-parse HEAD
}

expect_pass() {
    local description="$1"
    shift
    if ! "$SCRIPT" "$@" > "$WORK/out" 2>&1; then
        echo "expected a pass: $description" >&2
        cat "$WORK/out" >&2
        exit 1
    fi
}

expect_failure() {
    local description="$1" message="$2"
    shift 2
    if "$SCRIPT" "$@" > "$WORK/out" 2>&1; then
        echo "expected a failure: $description" >&2
        cat "$WORK/out" >&2
        exit 1
    fi
    if ! grep -qF -- "$message" "$WORK/out"; then
        echo "expected '$message' in the output: $description" >&2
        cat "$WORK/out" >&2
        exit 1
    fi
}

expect_not_reported() {
    local subject="$1"
    if grep -qxF -- "  $subject" "$WORK/out"; then
        echo "'$subject' must not be reported" >&2
        cat "$WORK/out" >&2
        exit 1
    fi
}

git init --quiet --bare --initial-branch=dev "$WORK/origin.git"
git init --quiet --initial-branch=dev "$SEED"
git -C "$SEED" remote add origin "$WORK/origin.git"

# History from before the gate existed: never checked unless it is in the range.
commit "Initial import" > /dev/null
released="$(commit "feat: decode tuples")"
git -C "$SEED" tag -a 0.1.0 -m 0.1.0 "$released"
commit "[release] prepare for next development iteration" > /dev/null
commit "Update README.md" > /dev/null
pushed_before="$(git -C "$SEED" rev-parse HEAD)"

commit "feat(decoder)!: return typed values" > /dev/null
commit "fix: keep leading zeros" > /dev/null
commit "chore(deps-dev): bump org.junit.jupiter:junit-jupiter from 6.1.2 to 6.1.3" > /dev/null
commit "chore(deps): bump the github-actions group across 1 directory with 2 updates" > /dev/null
commit "chore(release): set version to 0.2.0" > /dev/null
commit "chore(release): prepare next development iteration" > /dev/null
commit "revert: drop the tuple cache" > /dev/null
commit "feat!: drop the legacy encoder" > /dev/null
git -C "$SEED" checkout --quiet -b topic
commit "docs: explain tuples" > /dev/null
git -C "$SEED" checkout --quiet dev
git -C "$SEED" merge --quiet --no-ff -m "Merge branch 'topic' into dev" topic
pushed_after="$(git -C "$SEED" rev-parse HEAD)"

git -C "$SEED" checkout --quiet -b feat/clean
clean_branch="$(commit "test: cover empty arrays")"

git -C "$SEED" checkout --quiet -b feat/sloppy dev
commit "Feat: capitalised type" > /dev/null
commit "feat (decoder): space before the scope" > /dev/null
commit "feat:no space after the colon" > /dev/null
commit "feat(ui/table)!: slash scope" > /dev/null
commit "feat(ui.table): dot scope" > /dev/null
commit "feat(ui,table): comma-list scope" > /dev/null
commit "fixup! fix: keep leading zeros" > /dev/null
sloppy_branch="$(commit "wip")"
git -C "$SEED" checkout --quiet dev

git -C "$SEED" push --quiet origin dev feat/clean feat/sloppy refs/tags/0.1.0
git clone --quiet "$WORK/origin.git" "$CLONE"

echo "checking a push of conventional subjects passes, merge and release commits included"
expect_pass "a conventional push" "$CLONE" "$pushed_before" "$pushed_after" dev

echo "checking each non-conventional subject is reported, and only those"
expect_failure "a sloppy push" "not conventional commits" "$CLONE" "$pushed_after" "$sloppy_branch" dev
for subject in "Feat: capitalised type" "feat (decoder): space before the scope" \
    "feat:no space after the colon" "feat(ui/table)!: slash scope" \
    "feat(ui.table): dot scope" "feat(ui,table): comma-list scope" \
    "fixup! fix: keep leading zeros" "wip"; do
    grep -qxF -- "  $subject" "$WORK/out" || { echo "'$subject' was not reported" >&2; exit 1; }
done
expect_not_reported "fix: keep leading zeros"

echo "checking a new branch is checked from where it left the default branch"
expect_pass "a new conventional branch" "$CLONE" "$ZERO" "$clean_branch" dev
expect_failure "a new sloppy branch" "wip" "$CLONE" "$ZERO" "$sloppy_branch" dev
expect_not_reported "Update README.md"

echo "checking a force-pushed branch is checked from where it left the default branch"
expect_pass "a force-pushed conventional branch" "$CLONE" "$UNKNOWN_SHA" "$clean_branch" dev
expect_failure "a force-pushed sloppy branch" "wip" "$CLONE" "$UNKNOWN_SHA" "$sloppy_branch" dev

# The fallback base equals the pushed head here; the last version tag bounds the range instead.
# The release plugin's pre-conventional commit after that tag passes.
echo "checking a force-pushed default branch is checked since the last version tag"
expect_failure "a force-pushed default branch" "Update README.md" "$CLONE" "$UNKNOWN_SHA" "$pushed_after" dev
expect_not_reported "Initial import"
expect_not_reported "[release] prepare for next development iteration"

# A main that stands at the release puts the pre-gate README commit into the new branch's range.
echo "checking the default branch is selectable"
git -C "$CLONE" update-ref refs/remotes/origin/main "$released"
expect_failure "a new branch off main" "Update README.md" "$CLONE" "$ZERO" "$clean_branch" main

echo "checking a run without a pushed range passes without looking"
expect_pass "a dispatched run" "$CLONE" "" "" dev
grep -q "no pushed range" "$WORK/out"
expect_pass "a deleted branch" "$CLONE" "$pushed_after" "$ZERO" dev
grep -q "no pushed range" "$WORK/out"

# A range git cannot read must fail, not pass through the `|| true` of the filters.
echo "checking an unreadable range fails"
expect_failure "an unknown head" "cannot read the commit range" "$CLONE" "$pushed_before" "$UNKNOWN_SHA" dev

echo "checking a shallow checkout is refused"
git clone --quiet --depth 1 "file://$WORK/origin.git" "$WORK/shallow"
expect_failure "a shallow clone" "fetch-depth: 0" "$WORK/shallow" "$pushed_before" "$pushed_after" dev

echo "all commit-subject checks passed"
