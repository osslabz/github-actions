#!/usr/bin/env bash
#
# Runs prune.sh against a stub gh that serves fixed API responses and records every call, so
# its decisions are checked without a token and without a package to lose.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly HERE
readonly SCRIPT="$HERE/../prune.sh"
readonly BRANCH_VERSION="$HERE/../../snapshot-version/branch-version.sh"
WORK="$(mktemp -d)"
readonly WORK
readonly API="$WORK/api"
readonly OUT="$WORK/out"
readonly LIB="orgs/acme/packages/maven/net.acme.lib"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Serves $STUB_API/<endpoint>.<page>; --paginate concatenates every page, as gh does.
set -euo pipefail

if [ "${1:-}" != api ]; then
    echo "stub gh: only 'gh api' is served" >&2
    exit 1
fi
shift
method=GET include=false paginate=false endpoint=""
while [ $# -gt 0 ]; do
    case "$1" in
        -X|--method) method="$2"; shift ;;
        -i|--include) include=true ;;
        --paginate) paginate=true ;;
        -*) echo "stub gh: unexpected flag $1" >&2; exit 1 ;;
        *) endpoint="$1" ;;
    esac
    shift
done
echo "$method $endpoint" >> "$STUB_API/calls"

if [ "$method" = DELETE ]; then
    if [ -f "$STUB_API/delete-status" ]; then
        echo "gh: Must have admin rights to Repository. (HTTP $(cat "$STUB_API/delete-status"))" >&2
        exit 1
    fi
    exit 0
fi

response="$STUB_API/$(printf '%s' "$endpoint" | tr '/?&=' '____')"
if [ ! -f "$response.1" ]; then
    echo "gh: Not Found (HTTP 404)" >&2
    exit 1
fi
if $include; then
    printf 'HTTP/2.0 200 OK\n'
    if [ -f "$response.headers" ]; then sed 's/$/\r/' "$response.headers"; fi
    printf '\r\n'
fi
if $paginate; then cat "$response".[0-9]*; else cat "$response.1"; fi
STUB
chmod +x "$WORK/bin/gh"

fail() {
    echo "FAILED: $1" >&2
    echo "--- prune.sh output ---" >&2
    cat "$OUT" >&2
    exit 1
}

# serve <endpoint> <page>...
serve() {
    local endpoint="$1" key page=0 body
    shift
    key="$(printf '%s' "$endpoint" | tr '/?&=' '____')"
    for body in "$@"; do
        page=$((page + 1))
        printf '%s\n' "$body" > "$API/$key.$page"
    done
}

# owner_is <type> [scopes]; without scopes the response carries no X-OAuth-Scopes header,
# as for a workflow's GITHUB_TOKEN.
owner_is() {
    serve users/acme "{\"login\":\"acme\",\"type\":\"$1\"}"
    echo "Content-Type: application/json; charset=utf-8" > "$API/users_acme.headers"
    if [ $# -gt 1 ]; then echo "X-Oauth-Scopes: $2" >> "$API/users_acme.headers"; fi
}

packages_page() {
    printf '%s\n' "${@:2}" | jq -cnR --arg repo "$1" '[inputs | {name: ., repository: {name: $repo}}]'
}

# versions_page <first id> <version>...
versions_page() {
    printf '%s\n' "${@:2}" \
        | jq -cnR --argjson first "$1" '[[inputs] | to_entries[] | {id: ($first + .key), name: .value}]'
}

branches_page() {
    printf '%s\n' "$@" | jq -cnR '[inputs | {name: .}]'
}

# library <version>...: repo lib publishes one package, net.acme.lib, with these versions.
library() {
    serve "orgs/acme/packages?package_type=maven" "$(packages_page lib net.acme.lib)"
    serve "$LIB/versions" "$(versions_page 1 "$@")"
}

branches() {
    serve "repos/acme/lib/branches" "$(branches_page "$@")"
}

new_case() {
    echo "checking $1"
    rm -rf "$API"
    mkdir -p "$API"
    touch "$API/calls"
    owner_is Organization "repo, delete:packages"
    summary=""
}

run_prune() {
    status=0
    PATH="$WORK/bin:$PATH" STUB_API="$API" GITHUB_STEP_SUMMARY="$summary" "$SCRIPT" \
        --owner acme --repository lib --default-branch dev \
        --current-version 1.3.0-SNAPSHOT --mode delete "$@" > "$OUT" 2>&1 || status=$?
}

expect_status() {
    if [ "$status" -ne "$1" ]; then fail "expected exit status $1, got $status"; fi
}

# expect_deletes <endpoint>...: exactly these DELETEs, in this order.
expect_deletes() {
    local expected actual
    expected="$(if [ $# -gt 0 ]; then printf 'DELETE %s\n' "$@"; fi)"
    actual="$(grep '^DELETE ' "$API/calls" || true)"
    if [ "$actual" != "$expected" ]; then
        fail "expected deletes:
${expected:-(none)}
got:
${actual:-(none)}"
    fi
}

expect_output() {
    if ! grep -qF -- "$1" "$OUT"; then fail "expected output containing: $1"; fi
}

new_case "a branch snapshot goes once its branch is gone"
library 1.2.0 1.3.0-SNAPSHOT 1.3.0-feat-gone-SNAPSHOT
branches dev
run_prune
expect_status 0
expect_deletes "$LIB/versions/3"

new_case "a branch snapshot stays while its branch lives"
library 1.2.0 1.3.0-SNAPSHOT 1.3.0-feat-live-SNAPSHOT
branches dev feat/live
run_prune
expect_status 0
expect_deletes

# A slug cannot be turned back into its branch name, so a live branch with the same slug as a
# deleted one keeps the version: the version may well be the live branch's.
new_case "a snapshot stays while any live branch slugs to its name"
library 1.2.0 1.3.0-SNAPSHOT 1.3.0-feat-x-SNAPSHOT
branches dev feat-x
run_prune
expect_status 0
expect_deletes

# Branch names are case-sensitive, and branch-version.sh keeps their case in the slug.
new_case "a Dev branch's snapshot goes when only dev lives"
library 1.2.0 1.3.0-SNAPSHOT 1.3.0-Dev-SNAPSHOT
branches dev
run_prune
expect_status 0
expect_deletes "$LIB/versions/3"

new_case "a Dev branch's snapshot stays while Dev lives"
library 1.2.0 1.3.0-SNAPSHOT 1.3.0-Dev-SNAPSHOT
branches dev Dev
run_prune
expect_status 0
expect_deletes

new_case "a plain snapshot goes once its version is released"
library 1.2.0-SNAPSHOT 1.2.0 1.3.0-SNAPSHOT
branches dev
run_prune
expect_status 0
expect_deletes "$LIB/versions/1"

# The release policy may bump a snapshot's version on release.
new_case "a plain snapshot goes once a later version is released"
library 2.0.1-SNAPSHOT 2.1.0 2.1.1-SNAPSHOT
branches dev
run_prune --current-version 2.1.1-SNAPSHOT
expect_status 0
expect_deletes "$LIB/versions/1"

new_case "versions compare by number, not as text"
library 1.9.0-SNAPSHOT 1.10.0 1.10.1-SNAPSHOT
branches dev
run_prune --current-version 1.10.1-SNAPSHOT
expect_status 0
expect_deletes "$LIB/versions/1"

new_case "a plain snapshot stays when only a numerically lower release exists"
library 1.9.0 1.10.0-SNAPSHOT 1.10.1-SNAPSHOT
branches dev
run_prune --current-version 1.10.1-SNAPSHOT
expect_status 0
expect_deletes

new_case "a plain snapshot with no release at or after it stays"
library 1.2.0 1.3.0-SNAPSHOT 1.4.0-SNAPSHOT
branches dev
run_prune --current-version 1.4.0-SNAPSHOT
expect_status 0
expect_deletes

new_case "the current version stays even when it is released"
library 1.3.0 1.3.0-SNAPSHOT
branches dev
run_prune
expect_status 0
expect_deletes

new_case "releases stay"
library 1.0.0 1.1.0 1.2.0
branches dev
run_prune
expect_status 0
expect_deletes

new_case "a version of no known shape stays and is logged"
library 1.2.0 1.3 1.3.0-RC1 1.3.0--SNAPSHOT 1.3.0-feat_x-SNAPSHOT latest
branches dev
run_prune
expect_status 0
expect_deletes
for version in 1.3 1.3.0-RC1 1.3.0--SNAPSHOT 1.3.0-feat_x-SNAPSHOT latest; do
    expect_output "net.acme.lib $version: keep, unrecognised version"
done

# A branch list without the default branch is incomplete or for the wrong repo; every branch
# snapshot would read as orphaned.
new_case "a branch list without the default branch deletes nothing"
library 1.2.0 1.3.0-SNAPSHOT 1.3.0-feat-gone-SNAPSHOT
branches main feat/other
run_prune
expect_status 1
expect_deletes
expect_output "::error::"
expect_output "dev"

new_case "more stale versions than the default cap of 50 delete nothing"
mapfile -t many < <(for i in $(seq 51); do echo "1.3.0-b$i-SNAPSHOT"; done)
library 1.2.0 "${many[@]}"
branches dev
run_prune
expect_status 1
expect_deletes
expect_output "::error::"
expect_output "--max-deletions"

new_case "--max-deletions raises the cap"
library 1.2.0 "${many[@]}"
branches dev
run_prune --max-deletions 51
expect_status 0
deletes=()
for i in $(seq 2 52); do deletes+=("$LIB/versions/$i"); done
expect_deletes "${deletes[@]}"

new_case "a dry run over the cap warns and passes"
library 1.2.0 1.3.0-a-SNAPSHOT 1.3.0-b-SNAPSHOT
branches dev
run_prune --mode dry-run --max-deletions 1
expect_status 0
expect_deletes
expect_output "::warning::"

expect_failure() {
    if [ "$status" -eq 0 ]; then fail "expected a non-zero exit status"; fi
}

new_case "a delete refused with 403 names the scope and the secret"
library 1.2.0 1.3.0-feat-gone-SNAPSHOT 1.3.0-feat-also-gone-SNAPSHOT
branches dev
echo 403 > "$API/delete-status"
run_prune
expect_failure
expect_deletes "$LIB/versions/2"
expect_output "::error::"
expect_output "delete:packages"
expect_output "packages-token"

# GitHub answers 404 both to a token that may not see the package and for a version already
# deleted, so the scope is only one of two causes.
new_case "a delete refused with 404 says it may already be gone"
library 1.2.0 1.3.0-feat-gone-SNAPSHOT 1.3.0-feat-also-gone-SNAPSHOT
branches dev
echo 404 > "$API/delete-status"
run_prune
expect_failure
expect_deletes "$LIB/versions/2"
expect_output "::error::"
expect_output "refused or already gone"

new_case "a failing branch listing deletes nothing"
library 1.2.0 1.3.0-feat-gone-SNAPSHOT
run_prune
expect_failure
expect_deletes

new_case "a failing version listing deletes nothing"
serve "orgs/acme/packages?package_type=maven" "$(packages_page lib net.acme.lib net.acme.broken)"
serve "$LIB/versions" "$(versions_page 1 1.2.0 1.3.0-feat-gone-SNAPSHOT)"
branches dev
run_prune
expect_failure
expect_deletes

new_case "an owner of unknown type deletes nothing"
owner_is Bot "repo, delete:packages"
library 1.2.0 1.3.0-feat-gone-SNAPSHOT
branches dev
run_prune
expect_failure
expect_deletes

new_case "nothing stale passes with a token that cannot delete"
owner_is Organization "repo"
library 1.2.0 1.3.0-SNAPSHOT
branches dev
run_prune
expect_status 0
expect_deletes
expect_output "token scopes: repo"

new_case "a token that reports no scopes is logged as such"
owner_is Organization
library 1.2.0 1.3.0-SNAPSHOT
branches dev
run_prune
expect_status 0
expect_output "token scopes: none reported"

new_case "a dry run deletes nothing"
library 1.2.0 1.3.0-SNAPSHOT 1.3.0-feat-gone-SNAPSHOT
branches dev
run_prune --mode dry-run
expect_status 0
expect_deletes
expect_output "dry run: would delete net.acme.lib 1.3.0-feat-gone-SNAPSHOT"

# GitHub refuses to delete a package's last version; the package itself has to go.
new_case "a package whose every version is stale is deleted whole"
serve "orgs/acme/packages?package_type=maven" "$(packages_page lib net.acme.lib net.acme.old)"
serve "$LIB/versions" "$(versions_page 1 1.2.0 1.3.0-SNAPSHOT 1.3.0-feat-gone-SNAPSHOT)"
serve "orgs/acme/packages/maven/net.acme.old/versions" \
    "$(versions_page 10 1.0.0-feat-a-SNAPSHOT 1.0.0-feat-b-SNAPSHOT)"
branches dev
run_prune
expect_status 0
expect_deletes "$LIB/versions/3" "orgs/acme/packages/maven/net.acme.old"

# The stub has no versions for net.acme.other, so asking for them would fail the run.
new_case "packages of other repositories are left alone"
serve "orgs/acme/packages?package_type=maven" \
    "$(jq -cn --argjson lib "$(packages_page lib net.acme.lib)" \
        --argjson other "$(packages_page other net.acme.other)" '$other + $lib')"
serve "$LIB/versions" "$(versions_page 1 1.2.0 1.3.0-SNAPSHOT 1.3.0-feat-gone-SNAPSHOT)"
branches dev
run_prune
expect_status 0
expect_deletes "$LIB/versions/3"

new_case "a user's packages are reached under /users/"
owner_is User "repo, delete:packages"
serve "users/acme/packages?package_type=maven" "$(packages_page lib net.acme.lib)"
serve "users/acme/packages/maven/net.acme.lib/versions" \
    "$(versions_page 1 1.2.0 1.3.0-SNAPSHOT 1.3.0-feat-gone-SNAPSHOT)"
branches dev
run_prune
expect_status 0
expect_deletes "users/acme/packages/maven/net.acme.lib/versions/3"

new_case "every page of packages, versions and branches is read"
serve "orgs/acme/packages?package_type=maven" \
    "$(packages_page other net.acme.other)" "$(packages_page lib net.acme.lib)"
serve "$LIB/versions" "$(versions_page 1 1.2.0 1.3.0-SNAPSHOT)" \
    "$(versions_page 3 1.3.0-feat-gone-SNAPSHOT 1.3.0-feat-live-SNAPSHOT)"
serve "repos/acme/lib/branches" "$(branches_page dev)" "$(branches_page feat/live)"
run_prune
expect_status 0
expect_deletes "$LIB/versions/3"

# A branch created after its versions were listed cannot be mistaken for gone; one created
# between a branch listing and a version listing could.
new_case "branches are listed after every package's versions"
serve "orgs/acme/packages?package_type=maven" "$(packages_page lib net.acme.lib net.acme.two)"
serve "$LIB/versions" "$(versions_page 1 1.2.0 1.3.0-SNAPSHOT)"
serve "orgs/acme/packages/maven/net.acme.two/versions" "$(versions_page 10 1.2.0 1.3.0-SNAPSHOT)"
branches dev
run_prune
expect_status 0
last_versions="$(grep -n '/versions$' "$API/calls" | tail -n 1 | cut -d: -f1)"
first_branches="$(grep -n 'branches$' "$API/calls" | head -n 1 | cut -d: -f1)"
if [ "$first_branches" -le "$last_versions" ]; then fail "branches were listed before versions"; fi

new_case "the delete list reaches the step summary"
library 1.2.0-SNAPSHOT 1.2.0 1.3.0-SNAPSHOT 1.3.0-feat-gone-SNAPSHOT
branches dev
summary="$WORK/summary"
: > "$summary"
run_prune
expect_status 0
grep -qF "net.acme.lib 1.2.0-SNAPSHOT" "$summary" || fail "summary lacks 1.2.0-SNAPSHOT"
grep -qF "net.acme.lib 1.3.0-feat-gone-SNAPSHOT" "$summary" || fail "summary lacks the branch snapshot"

# A qualifier would read as a branch slug, and the version every downstream build depends on
# would be deleted as the snapshot of a gone branch.
for current in 1.2.3-alpha-SNAPSHOT 1.3.0 1.3-SNAPSHOT; do
    new_case "a current version of $current is refused"
    library 1.2.0 1.2.3-alpha-SNAPSHOT
    branches dev
    run_prune --current-version "$current"
    expect_status 2
    expect_deletes
    expect_output "--current-version"
done

new_case "an unknown mode is refused"
library 1.2.0
branches dev
run_prune --mode yes
expect_status 2
expect_deletes

new_case "a missing argument is refused"
status=0
PATH="$WORK/bin:$PATH" STUB_API="$API" "$SCRIPT" --owner acme --mode dry-run > "$OUT" 2>&1 || status=$?
expect_status 2
expect_output "Usage:"

# prune.sh carries its own copy of branch-version.sh's slug; a branch whose version the two
# slug differently would have its live snapshot deleted. Every name below is published by
# branch-version.sh, then must be kept while the branch lives and deleted once it is gone.
new_case "prune.sh slugs every branch name as branch-version.sh does"
printf '<project>\n    <version>0.0.1-SNAPSHOT</version>\n</project>\n' > "$WORK/pom.xml"
names=(
    feat/async-instrumentation
    fix/v1.2.3
    "dependabot/maven/org.foo//bar-1.2.3"
    dependabot/github_actions/actions/checkout-7.0.1
    a..b
    x--y
    Feature/MixedCase
    /leading
    trailing/
    --both--
    "with space"
    under_score
    SNAPSHOT
    123
)
published=()
for name in "${names[@]}"; do
    published+=("$("$BRANCH_VERSION" "$WORK/pom.xml" "$name" dev)")
done
library 0.0.1 "${published[@]}"
branches dev "${names[@]}"
run_prune --current-version 0.0.2-SNAPSHOT
expect_status 0
expect_deletes

rm -f "$API/calls"
branches dev
run_prune --current-version 0.0.2-SNAPSHOT
expect_status 0
deletes=()
for i in $(seq 2 $((${#names[@]} + 1))); do deletes+=("$LIB/versions/$i"); done
expect_deletes "${deletes[@]}"

echo "all package-prune checks passed"
