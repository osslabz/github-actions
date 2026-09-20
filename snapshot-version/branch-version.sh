#!/usr/bin/env bash
#
# Prints the -SNAPSHOT version a branch's build publishes under.
#
# Every branch carries the same version, so publishing them all under one coordinate would
# leave the last push standing and silently replace dev's build. `dev` keeps the plain
# coordinate, which is what a project depending on peekaboot's snapshots means; every other
# branch folds its name into the version so its build is addressable without touching that.
#
# Usage: branch-version.sh <pom> <branch> [default-branch]
set -euo pipefail

pom="${1:-}"
branch="${2:-}"
# Which branch keeps the plain coordinate differs per repo - most osslabz repos integrate
# on dev, bitcoin-commons and lnd-rest-client on main - so the caller names it.
default_branch="${3:-dev}"

if [ ! -r "$pom" ]; then
    echo "cannot read a pom at '$pom'" >&2
    exit 1
fi

# A Spring Boot application's root pom inherits spring-boot-starter-parent, whose <version>
# comes first in the file and is not the project's. Drop the <parent> element, then the first
# <version> left is the project's own.
version="$(sed '/<parent>/,/<\/parent>/d' "$pom" \
    | sed -n '/<version>/{s:.*<version>\(.*\)</version>.*:\1:p;q;}')"

if [ -z "$version" ]; then
    echo "cannot read a version from '$pom'" >&2
    exit 1
fi

if [ "${version%-SNAPSHOT}" = "$version" ]; then
    echo "$version is not a snapshot; only snapshots publish from a branch" >&2
    exit 1
fi

if [ "$branch" = "$default_branch" ]; then
    echo "$version"
    exit 0
fi

# Maven takes any string as a version, but one carrying a branch name's slashes and dots
# reads as a path and sorts unpredictably, so every run of them collapses to one separator.
slug="$(printf '%s' "$branch" | tr -cs 'A-Za-z0-9' '-')"
slug="${slug#-}"
slug="${slug%-}"

if [ -z "$slug" ]; then
    echo "branch '$branch' leaves no usable version" >&2
    exit 1
fi

echo "${version%-SNAPSHOT}-${slug}-SNAPSHOT"
