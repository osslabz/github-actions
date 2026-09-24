#!/usr/bin/env bash
#
# Installs a project into the local Maven repository under the version its branch publishes
# under in CI, so a branch build can never shadow the integration branch's coordinate.
#
# CI already does this when it publishes: the integration branch keeps the plain version and
# every other branch folds its name in. Locally, a plain `mvn install` on a feature branch
# writes that build over `~/.m2`'s copy of the integration branch's snapshot, and every
# project that depends on it then compiles against the feature branch without saying so.
# Because `~/.m2` is per machine, two machines sharing a checkout end up building different
# code from the same commit, with no diff to explain it.
#
# The derivation is branch-version.sh, the same script the CI action calls. One rule, one home.
#
# Usage: install-local.sh [--print | --dry-run] [--directory DIR] [--default-branch NAME]
#                         [--pom FILE] [-- mvn args...]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly HERE
readonly DERIVE="$HERE/branch-version.sh"

directory=.
default_branch=dev
pom=pom.xml
mode=install

while [ $# -gt 0 ]; do
    case "$1" in
        --print) mode=print; shift ;;
        --dry-run) mode=dry-run; shift ;;
        --directory) directory="${2:?--directory needs a path}"; shift 2 ;;
        --default-branch) default_branch="${2:?--default-branch needs a name}"; shift 2 ;;
        --pom) pom="${2:?--pom needs a path}"; shift 2 ;;
        --) shift; break ;;
        -*) echo "unknown option '$1'" >&2; exit 1 ;;
        *) break ;;
    esac
done

cd "$directory" || exit 1

if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    echo "'$directory' is not a git repository, so there is no branch to derive from" >&2
    exit 1
fi

branch="$(git rev-parse --abbrev-ref HEAD)"
if [ "$branch" = HEAD ]; then
    echo "'$directory' has a detached HEAD, so there is no branch to derive from" >&2
    exit 1
fi

version="$("$DERIVE" "$pom" "$branch" "$default_branch")"

if [ "$mode" = print ]; then
    printf '%s\n' "$version"
    exit 0
fi

if [ -x ./mvnw ]; then maven=./mvnw; else maven=mvn; fi

# Named in full rather than by the `versions:` prefix, so an unpinned prefix cannot resolve
# whatever is latest that day. Matches what the CI action pins.
readonly VERSIONS=org.codehaus.mojo:versions-maven-plugin:2.22.0

set_args=("$maven" --batch-mode --file "$pom" "$VERSIONS:set"
    -DnewVersion="$version" -DprocessAllModules=true
    -DupdateBuildOutputTimestampPolicy=never)
install_args=("$maven" --batch-mode --file "$pom" install "$@")
revert_args=("$maven" --batch-mode --file "$pom" "$VERSIONS:revert")

# The integration branch's derived version is the one the pom already carries, so rewriting it
# would change nothing and still cost two Maven starts.
if [ "$version" = "$("$DERIVE" "$pom" "$default_branch" "$default_branch")" ]; then
    if [ "$mode" = dry-run ]; then
        printf '%s\n' "${install_args[*]}"
        exit 0
    fi
    exec "${install_args[@]}"
fi

if [ "$mode" = dry-run ]; then
    printf '%s\n' "${set_args[*]}" "${install_args[*]}" "${revert_args[*]}"
    exit 0
fi

# Unlike CI, which throws its checkout away, this runs in a tree someone is working in. The
# rewritten pom has to go back even if the install fails or the run is interrupted, or the
# next commit carries a branch-suffixed version into the repository.
revert() { "${revert_args[@]}" > /dev/null 2>&1 || true; }
trap revert EXIT

"${set_args[@]}"
"${install_args[@]}"

echo "installed $version"
