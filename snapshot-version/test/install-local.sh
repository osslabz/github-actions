#!/usr/bin/env bash
#
# Checks the local install wrapper against fixture repositories. The derivation itself is
# covered by run.sh; what matters here is that the branch comes from git, that the default
# branch is left alone, and that a rewritten pom is always put back.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly HERE
readonly SCRIPT="$HERE/../install-local.sh"
WORK="$(mktemp -d)"
readonly WORK
trap 'rm -rf "$WORK"' EXIT

# A repository on a named branch with a pom carrying the given version.
make_repo() {
    local dir="$WORK/$1" branch="$2" version="$3"
    mkdir -p "$dir"
    cat > "$dir/pom.xml" <<POM
<?xml version="1.0" encoding="UTF-8"?>
<project>
    <groupId>net.codelabz</groupId>
    <artifactId>fixture</artifactId>
    <version>$version</version>
</project>
POM
    git -C "$dir" init --quiet --initial-branch="$branch"
    git -C "$dir" add pom.xml
    git -C "$dir" -c user.email=t@t -c user.name=t commit --quiet -m "fixture"
    printf '%s' "$dir"
}

expect_print() {
    local dir="$1" expected="$2" actual
    shift 2
    actual="$("$SCRIPT" --print --directory "$dir" "$@")"
    if [ "$actual" != "$expected" ]; then
        echo "expected $expected, got $actual" >&2
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
    if ! grep -q "$message" "$WORK/out"; then
        echo "expected '$message' in the failure for $description, got:" >&2
        cat "$WORK/out" >&2
        exit 1
    fi
}

echo "checking the branch is read from git"
repo="$(make_repo feature feat/rate-limit 0.1.0-SNAPSHOT)"
expect_print "$repo" "0.1.0-feat-rate-limit-SNAPSHOT"

echo "checking the default branch keeps the plain coordinate"
plain="$(make_repo plain dev 0.1.0-SNAPSHOT)"
expect_print "$plain" "0.1.0-SNAPSHOT"

echo "checking the default branch is configurable"
mainline="$(make_repo mainline main 2.0.0-SNAPSHOT)"
expect_print "$mainline" "2.0.0-SNAPSHOT" --default-branch main
expect_print "$mainline" "2.0.0-main-SNAPSHOT" --default-branch dev

echo "checking a dry run names both the rewrite and the revert"
out="$("$SCRIPT" --dry-run --directory "$repo")"
grep -q "versions-maven-plugin" <<< "$out"
grep -q "0.1.0-feat-rate-limit-SNAPSHOT" <<< "$out"
grep -qE '(^| )install( |$)' <<< "$out"
# Without the revert a local build leaves the pom rewritten, and the next commit carries it.
grep -q ":revert" <<< "$out"

echo "checking the default branch installs without rewriting anything"
out="$("$SCRIPT" --dry-run --directory "$plain")"
grep -qE '(^| )install( |$)' <<< "$out"
if grep -q ":set" <<< "$out"; then
    echo "the default branch must not rewrite its pom" >&2
    exit 1
fi

echo "checking a directory that is not a repository is refused"
mkdir -p "$WORK/bare"
cp "$plain/pom.xml" "$WORK/bare/pom.xml"
expect_failure "a directory with no git" "not a git repository" --print --directory "$WORK/bare"

echo "checking a missing pom is refused"
# A git repository whose pom is gone, so the guard under test is the pom one and not the git one.
nopom="$(make_repo nopom dev 0.1.0-SNAPSHOT)"
rm "$nopom/pom.xml"
expect_failure "a repository with no pom" "cannot read" --print --directory "$nopom"

echo "checking a detached HEAD is refused"
detached="$(make_repo detached dev 0.1.0-SNAPSHOT)"
git -C "$detached" checkout --quiet --detach HEAD
expect_failure "a detached HEAD" "detached HEAD" --print --directory "$detached"

echo "all local install checks passed"
