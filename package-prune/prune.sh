#!/usr/bin/env bash
#
# Deletes the package versions a repository published to GitHub Packages that no build
# will ask for again. GitHub bills Maven storage and never expires a snapshot, and each
# snapshot version holds every timestamped build pushed to it.
#
# A branch's snapshot goes once its branch is gone. A plain snapshot goes once a release at or
# after its version exists and it is no longer the version the default branch builds. Releases,
# the current version and any version of a shape this script does not know are kept. Deleting
# a whole package also removes a version published between listing and deleting; GitHub keeps
# it restorable for 30 days.
#
# An image (container package) keeps every tagged version and every digest a tagged multi-arch
# index lists; an untagged version older than seven days goes, except the newest such one, kept
# to roll back to. A package without any tag is left alone.
#
# Usage: prune.sh --owner <owner> --repository <repo> --default-branch <branch>
#                 --current-version <version> --mode dry-run|delete [--max-deletions <n>]
# The token is the one gh uses: GH_TOKEN, or gh's own login. It must be a classic PAT, the only
# kind GitHub lists Maven packages to; delete mode refuses any other, and refuses one without
# delete:packages once something is stale. A dry run with any other token warns and passes.
set -euo pipefail

readonly USAGE="Usage: prune.sh --owner <owner> --repository <repo> --default-branch <branch> \
--current-version <version> --mode dry-run|delete [--max-deletions <n>]"
readonly RELEASE='^[0-9]+\.[0-9]+\.[0-9]+$'
readonly DEV_SNAPSHOT='^([0-9]+\.[0-9]+\.[0-9]+)-SNAPSHOT$'
readonly BRANCH_SNAPSHOT='^[0-9]+\.[0-9]+\.[0-9]+-([A-Za-z0-9]+(-[A-Za-z0-9]+)*)-SNAPSHOT$'
readonly UNTAGGED_DAYS=7
readonly MANIFEST_TYPES='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

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

# registry_token <image>: a ghcr.io pull token for one of the owner's images, asked for with the
# token gh uses. Credentials go through curl's config on stdin, never the command line.
registry_token() {
    curl -fsS -K - "https://ghcr.io/token?scope=repository:${owner,,}/$1:pull&service=ghcr.io" \
        <<< "user = \"prune:${GH_TOKEN:-$(gh auth token)}\"" | jq -r .token
}

# index_children <image> <registry token> <digest>: the digests a multi-arch index lists, which
# are untagged versions of the same package; nothing for a single image.
index_children() {
    curl -fsS -K - "https://ghcr.io/v2/${owner,,}/$1/manifests/$3" \
        <<< "header = \"Authorization: Bearer $2\"
header = \"Accept: $MANIFEST_TYPES\"" | jq -r '.manifests[]?.digest'
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

owner_response="$(gh api -i "users/$owner" | tr -d '\r')"
scopes="$(awk '/^$/ { exit } tolower($0) ~ /^x-oauth-scopes:/ { sub(/^[^:]*: */, ""); print }' \
    <<< "$owner_response")"
echo "token scopes: ${scopes:-none reported}"
# Only a classic PAT reports scopes, and GitHub lists no Maven packages to any other token: an
# empty list would read as nothing to prune.
if [ -z "$scopes" ]; then
    message="the token is not a classic PAT, so it cannot see $owner's packages; set the packages-token secret to a classic PAT with read:packages and delete:packages"
    if [ "$mode" = delete ]; then
        echo "::error::$message"
        exit 1
    fi
    echo "::warning::$message; nothing was checked"
    exit 0
fi
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

# One line per DELETE: what to call it in the log, and its endpoint. A package whose every
# version is stale goes whole, because GitHub refuses to delete a package's last version.
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
            printf '%s %s\t%s\n' "$package" "$version" "$packages_path/maven/$package/versions/$id" >> "$work/package-deletes"
        fi
    done < "$work/package-versions"
    package_stale="$(wc -l < "$work/package-deletes")"
    stale_count=$((stale_count + package_stale))
    if [ "$package_stale" -gt 0 ] && [ "$package_stale" -eq "$version_count" ]; then
        printf '%s (every version)\t%s\n' "$package" "$packages_path/maven/$package" >> "$work/deletes"
    else
        cat "$work/package-deletes" >> "$work/deletes"
    fi
done <<< "$packages"

containers="$(gh api --paginate "$packages_path?package_type=container" \
    | jq -r --arg repo "$repository" '.[] | select(.repository.name == $repo) | .name')"
cutoff="$(date -u -d "$UNTAGGED_DAYS days ago" +%Y-%m-%dT%H:%M:%SZ)"
while IFS= read -r image; do
    [ -n "$image" ] || continue
    # One line per version, newest first: id, digest, creation time, tags (comma-separated, empty
    # if untagged). Tab is whitespace to read, so an empty creation time would shift the tags into
    # its place.
    gh api --paginate "$packages_path/container/$image/versions" \
        | jq -r '.[] | [(.id | tostring), .name, (.created_at // error("\(.name) has no created_at")),
            (.metadata.container.tags | join(","))] | @tsv' \
        | sort -t $'\t' -k3,3r > "$work/image-versions"
    if ! awk -F '\t' '$4 != "" { found = 1 } END { exit !found }' "$work/image-versions"; then
        echo "$image: keep every version, none is tagged"
        continue
    fi
    token="$(registry_token "$image")"
    : > "$work/referenced"
    while IFS=$'\t' read -r _ digest _ tags; do
        if [ -n "$tags" ]; then
            index_children "$image" "$token" "$digest" >> "$work/referenced"
        fi
    done < "$work/image-versions"
    rollback_kept=false
    while IFS=$'\t' read -r id digest created tags; do
        if [ -n "$tags" ]; then
            decision="keep, tagged $tags"
        elif grep -qxF -- "$digest" "$work/referenced"; then
            decision="keep, a tagged index lists it"
        elif [[ "$created" > "$cutoff" ]]; then
            decision="keep, created less than $UNTAGGED_DAYS days ago"
        elif ! $rollback_kept; then
            decision="keep, newest untagged"
            rollback_kept=true
        else
            decision="delete, untagged, older than $UNTAGGED_DAYS days and in no tagged index"
        fi
        echo "$image $digest: $decision"
        if [[ "$decision" == delete,* ]]; then
            printf '%s %s\t%s\n' "$image" "$digest" "$packages_path/container/$image/versions/$id" >> "$work/deletes"
            stale_count=$((stale_count + 1))
        fi
    done < "$work/image-versions"
done <<< "$containers"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "### package-prune ($mode)"
        echo
        if [ -s "$work/deletes" ]; then
            awk -F '\t' '{ print "- " $1 }' "$work/deletes"
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

# Checked only once something is stale, so a token that cannot delete still passes a run with
# nothing to prune.
if [ "$mode" = delete ] && ! tr ',' '\n' <<< "$scopes" | tr -d ' ' | grep -qxF delete:packages; then
    echo "::error::the token lacks the delete:packages scope, so it cannot delete the $stale_count stale versions above; set the packages-token secret to a classic PAT that has it. Deleting nothing"
    exit 1
fi

while IFS=$'\t' read -r label endpoint; do
    if [ "$mode" = dry-run ]; then
        echo "dry run: would delete $label"
        continue
    fi
    if ! gh api -X DELETE "$endpoint" > /dev/null 2> "$work/error"; then
        error="$(cat "$work/error")"
        if [[ "$error" =~ \(HTTP\ 403\) ]]; then
            echo "::error::deleting $label was refused ($error). The token needs the delete:packages scope: set the packages-token secret to a classic PAT that has it."
        elif [[ "$error" =~ \(HTTP\ 404\) ]]; then
            echo "::error::deleting $label was refused or already gone ($error). If it still exists, the token needs the delete:packages scope: set the packages-token secret to a classic PAT that has it."
        else
            echo "::error::deleting $label failed: $error"
        fi
        exit 1
    fi
    echo "deleted $label"
done < "$work/deletes"
