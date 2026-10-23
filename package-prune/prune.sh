#!/usr/bin/env bash
#
# Deletes the Maven package versions a repository published to GitHub Packages that no build
# will ask for again. GitHub bills Maven storage and never expires a snapshot, and each
# snapshot version holds every timestamped build pushed to it.
#
# A branch's snapshot goes once its branch is gone. A plain snapshot goes once a release at or
# after its version exists and it is no longer the version the default branch builds. Releases,
# the current version and any version of a shape this script does not know are kept. Deleting
# a whole package also removes a version published between listing and deleting; GitHub keeps
# it restorable for 30 days.
#
# Usage: prune.sh --owner <owner> --repository <repo> --default-branch <branch>
#                 --current-version <version> --mode dry-run|delete [--max-deletions <n>]
# The token comes from GH_TOKEN, as for any gh call.
set -euo pipefail

readonly USAGE="Usage: prune.sh --owner <owner> --repository <repo> --default-branch <branch> \
--current-version <version> --mode dry-run|delete [--max-deletions <n>]"
readonly RELEASE='^[0-9]+\.[0-9]+\.[0-9]+$'
readonly DEV_SNAPSHOT='^([0-9]+\.[0-9]+\.[0-9]+)-SNAPSHOT$'
readonly BRANCH_SNAPSHOT='^[0-9]+\.[0-9]+\.[0-9]+-([A-Za-z0-9]+(-[A-Za-z0-9]+)*)-SNAPSHOT$'

owner="" repository="" default_branch="" current_version="" mode="" max_deletions=50
while [ $# -gt 0 ]; do
    case "$1" in
        --owner) owner="${2:-}" ;;
        --repository) repository="${2:-}" ;;
        --default-branch) default_branch="${2:-}" ;;
        --current-version) current_version="${2:-}" ;;
        --mode) mode="${2:-}" ;;
        --max-deletions) max_deletions="${2:-}" ;;
        *) echo "$USAGE" >&2; exit 2 ;;
    esac
    shift 2 || { echo "$USAGE" >&2; exit 2; }
done
if [ -z "$owner" ] || [ -z "$repository" ] || [ -z "$default_branch" ] \
    || [ -z "$current_version" ] || [[ ! "$mode" =~ ^(dry-run|delete)$ ]] \
    || [[ ! "$max_deletions" =~ ^[0-9]+$ ]]; then
    echo "$USAGE" >&2
    exit 2
fi
# A qualifier such as 1.2.3-alpha-SNAPSHOT reads as a branch slug, and the current version
# would then be deleted as the snapshot of a gone branch.
if [[ ! "$current_version" =~ $DEV_SNAPSHOT ]]; then
    echo "--current-version must be a plain x.y.z-SNAPSHOT version, not $current_version" >&2
    exit 2
fi

# Must stay identical to snapshot-version/branch-version.sh; test/run.sh checks that it is.
slug_of() {
    local slug
    slug="$(printf '%s' "$1" | tr -cs 'A-Za-z0-9' '-')"
    slug="${slug#-}"
    printf '%s\n' "${slug%-}"
}

released_at_or_after() {
    local base="$1" releases="$2" release
    while IFS= read -r release; do
        if [ -n "$release" ] && printf '%s\n' "$base" "$release" | sort -V -C; then
            return 0
        fi
    done <<< "$releases"
    return 1
}

# verdict <version> <the package's releases>: prints "keep, <why>" or "delete, <why>".
verdict() {
    local version="$1" releases="$2"
    if [ "$version" = "$current_version" ]; then
        echo "keep, the current version"
    elif [[ "$version" =~ $RELEASE ]]; then
        echo "keep, a release"
    elif [[ "$version" =~ $DEV_SNAPSHOT ]]; then
        if released_at_or_after "${BASH_REMATCH[1]}" "$releases"; then
            echo "delete, released at or after ${BASH_REMATCH[1]}"
        else
            echo "keep, not released yet"
        fi
    elif [[ "$version" =~ $BRANCH_SNAPSHOT ]]; then
        if grep -qxF -- "${BASH_REMATCH[1]}" <<< "$live_slugs"; then
            echo "keep, a live branch slugs to ${BASH_REMATCH[1]}"
        else
            echo "delete, no live branch slugs to ${BASH_REMATCH[1]}"
        fi
    else
        echo "keep, unrecognised version"
    fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

owner_response="$(gh api -i "users/$owner" | tr -d '\r')"
scopes="$(awk '/^$/ { exit } tolower($0) ~ /^x-oauth-scopes:/ { sub(/^[^:]*: */, ""); print }' \
    <<< "$owner_response")"
echo "token scopes: ${scopes:-none reported}"
owner_type="$(awk 'body { print } /^$/ { body = 1 }' <<< "$owner_response" | jq -r .type)"
case "$owner_type" in
    Organization) packages_path="orgs/$owner/packages" ;;
    User) packages_path="users/$owner/packages" ;;
    *) echo "::error::cannot tell whether $owner is an organization or a user ($owner_type)"; exit 1 ;;
esac

packages="$(gh api --paginate "$packages_path?package_type=maven" \
    | jq -r --arg repo "$repository" '.[] | select(.repository.name == $repo) | .name')"

# One line per version: package, id, version.
while IFS= read -r package; do
    if [ -n "$package" ]; then
        gh api --paginate "$packages_path/maven/$package/versions" \
            | jq -r --arg package "$package" '.[] | [$package, (.id | tostring), .name] | @tsv'
    fi
done <<< "$packages" > "$work/versions"

# Listed after the versions, so a version always has its branch listed if the branch still
# exists; the other order would miss a branch created in between.
branches="$(gh api --paginate "repos/$owner/$repository/branches" | jq -r '.[].name')"
if ! grep -qxF -- "$default_branch" <<< "$branches"; then
    echo "::error::the branch list of $owner/$repository lacks $default_branch, so it cannot be trusted; deleting nothing"
    exit 1
fi
live_slugs="$(while IFS= read -r branch; do slug_of "$branch"; done <<< "$branches")"

# One line per DELETE: package, version and its id, or no id when every version is stale and
# the package goes whole, because GitHub refuses to delete a package's last version.
: > "$work/deletes"
stale_count=0
while IFS= read -r package; do
    [ -n "$package" ] || continue
    awk -F '\t' -v package="$package" '$1 == package { print $2 "\t" $3 }' "$work/versions" \
        > "$work/package-versions"
    releases="$(cut -f 2 "$work/package-versions" | grep -E "$RELEASE" || true)"
    version_count=0
    : > "$work/package-deletes"
    while IFS=$'\t' read -r id version; do
        version_count=$((version_count + 1))
        decision="$(verdict "$version" "$releases")"
        echo "$package $version: $decision"
        if [[ "$decision" == delete,* ]]; then
            printf '%s\t%s\t%s\n' "$package" "$version" "$id" >> "$work/package-deletes"
        fi
    done < "$work/package-versions"
    package_stale="$(wc -l < "$work/package-deletes")"
    stale_count=$((stale_count + package_stale))
    if [ "$package_stale" -gt 0 ] && [ "$package_stale" -eq "$version_count" ]; then
        printf '%s\t(every version)\t\n' "$package" >> "$work/deletes"
    else
        cat "$work/package-deletes" >> "$work/deletes"
    fi
done <<< "$packages"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "### package-prune ($mode)"
        echo
        if [ -s "$work/deletes" ]; then
            awk -F '\t' '{ print "- " $1 " " $2 }' "$work/deletes"
        else
            echo "Nothing to prune."
        fi
    } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$stale_count" -eq 0 ]; then
    echo "nothing to prune"
    exit 0
fi

if [ "$stale_count" -gt "$max_deletions" ]; then
    message="$stale_count stale versions exceed the cap of $max_deletions; raise it with --max-deletions after reading the list above"
    if [ "$mode" = delete ]; then
        echo "::error::$message; deleting nothing"
        exit 1
    fi
    echo "::warning::$message; delete mode would delete nothing"
fi

while IFS=$'\t' read -r package version id; do
    if [ -n "$id" ]; then
        endpoint="$packages_path/maven/$package/versions/$id"
    else
        endpoint="$packages_path/maven/$package"
    fi
    if [ "$mode" = dry-run ]; then
        echo "dry run: would delete $package $version"
        continue
    fi
    if ! gh api -X DELETE "$endpoint" > /dev/null 2> "$work/error"; then
        error="$(cat "$work/error")"
        if [[ "$error" =~ \(HTTP\ 403\) ]]; then
            echo "::error::deleting $package $version was refused ($error). The token needs the delete:packages scope: set the packages-token secret to a classic PAT that has it."
        elif [[ "$error" =~ \(HTTP\ 404\) ]]; then
            echo "::error::deleting $package $version was refused or already gone ($error). If it still exists, the token needs the delete:packages scope: set the packages-token secret to a classic PAT that has it."
        else
            echo "::error::deleting $package $version failed: $error"
        fi
        exit 1
    fi
    echo "deleted $package $version"
done < "$work/deletes"
