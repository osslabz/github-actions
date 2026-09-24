#!/usr/bin/env bash
#
# Fails if a non-merge commit subject in the pushed range is not a conventional commit.
#
# The release derives its version from these subjects: a subject the version policy cannot
# parse counts as a patch, whatever it changed. Only the pushed range is checked, so history
# from before the check existed never fails a build.
#
# Usage: check-commit-subjects.sh <repo> <before> <after> [default-branch] [forced]
set -euo pipefail

readonly ZERO="0000000000000000000000000000000000000000"
readonly TYPES='feat|fix|perf|refactor|docs|test|build|ci|chore|style|revert'
# A scope, if given, is letters, digits, `_` and `-` only: what
# conventional-commits-version-policy 1.0.9 parses by default. A slash, a dot or a
# comma-separated list would pass a laxer pattern but not the policy, which would then derive
# a patch from the subject regardless of what it changed.
readonly SCOPE='\([A-Za-z0-9_-]+\)'

repo="$1"
before="$2"
after="$3"
default_branch="${4:-dev}"
forced="${5:-false}"

# A dispatched run, or any event other than a push, has no pushed range; a deleted branch
# has nothing left to check.
if [ -z "$before" ] || [ -z "$after" ] || [ "$after" = "$ZERO" ]; then
    echo "no pushed range to check"
    exit 0
fi

# A shallow clone would end the range at its depth and pass whatever lies beyond it.
if [ "$(git -C "$repo" rev-parse --is-shallow-repository)" = true ]; then
    echo "::error::the checkout is shallow; check out with fetch-depth: 0"
    exit 1
fi

resolves() {
    git -C "$repo" rev-parse --verify --quiet "$1^{commit}" > /dev/null
}

# A push that creates a branch reports the all-zero SHA as `before`, and the range starts where
# the branch left the default branch instead: that range is meaningful, so it is checked below.
#
# A force-push is different: `before` names a tip the rewrite discarded, so `before..after`
# would either fail to resolve or, if `before` happens to still resolve to some other commit,
# range over history that was never pushed by this event. Neither is worth widening to the
# default branch; a forced, deliberate rewrite is not what this gate is for, so it is skipped
# outright. `github.event.forced` is authoritative on its own: GitHub calls a push forced
# whenever it wasn't a fast-forward, whatever before and after happen to resolve to.
if [ "$before" != "$ZERO" ]; then
    if [ "$forced" = true ]; then
        echo "the push was forced; the range is meaningless, skipping the commit-subject check"
        exit 0
    fi
    # An unresolvable after is a different problem: read below, where git log fails loudly on
    # it instead of being read here as a rewrite.
    if ! resolves "$before" \
        || { resolves "$after" && ! git -C "$repo" merge-base --is-ancestor "$before" "$after"; }; then
        echo "before is not an ancestor of after; the range is meaningless, skipping the commit-subject check"
        exit 0
    fi
fi

base="$before"
if [ "$before" = "$ZERO" ]; then
    base="origin/$default_branch"
fi

range="$base..$after"

# Captured on its own so a range git cannot read fails here instead of reaching the filters
# below, where `|| true` would turn it into a pass.
if ! subjects="$(git -C "$repo" log --no-merges --format='%s' "$range")"; then
    echo "::error::cannot read the commit range $range"
    exit 1
fi

if [ -z "$subjects" ]; then
    echo "no commits to check in $range"
    exit 0
fi

# `[release] ...` is what maven-release-plugin wrote before release commits became
# conventional; such commits still sit after the last tag in repositories released before.
offenders="$(printf '%s\n' "$subjects" \
    | grep -vE "^($TYPES)(${SCOPE})?!?: .+" \
    | grep -vE '^\[release\] ' || true)"

if [ -n "$offenders" ]; then
    echo "::error::these commit subjects are not conventional commits:"
    printf '%s\n' "$offenders" | sed 's/^/  /'
    exit 1
fi

echo "all commit subjects in $range are conventional"
