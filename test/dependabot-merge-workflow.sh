#!/usr/bin/env bash
#
# Runs the shell steps of .github/workflows/dependabot-merge-on-build.yml the way the runner
# does, against a stub gh that serves one pull request and its commits, and checks which
# updates merge and how.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly HERE
readonly WORKFLOW="$HERE/../.github/workflows/dependabot-merge-on-build.yml"
WORK="$(mktemp -d)"
readonly WORK
readonly API="$WORK/api"
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=test/workflow-steps.sh
source "$HERE/workflow-steps.sh"

readonly SHA=1111111111111111111111111111111111111111
readonly OTHER_SHA=2222222222222222222222222222222222222222
readonly MAVEN_BRANCH=dependabot/maven/org.acme-lib-1.3.0
readonly ACTIONS_BRANCH=dependabot/github_actions/github-actions-f9cd762853
readonly NPM_BRANCH=dependabot/npm_and_yarn/eslint-10.2.0
readonly GRADLE_BRANCH=dependabot/gradle/org.acme-lib-1.3.0
readonly URL=https://github.com/acme/app/pull/7
readonly BASE_MOVED='GraphQL: Base branch was modified. Review and try the merge again. (mergePullRequest)'

mkdir -p "$WORK/bin" "$API"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Records every call. Serves $STUB_API/pulls to the pull request lookup and $STUB_API/commits
# to the commit listing. `gh pr merge` answers with the next line of $STUB_API/merge-results:
# `ok`, or an error message it prints before failing.
set -euo pipefail
printf '%s\n' "$*" >> "$STUB_API/calls"
case "$*" in
    "api --method GET repos/acme/app/pulls "*) cat "$STUB_API/pulls" ;;
    "api repos/acme/app/pulls/7/commits") cat "$STUB_API/commits" ;;
    "pr merge "*)
        result="$(head -n 1 "$STUB_API/merge-results")"
        sed -i 1d "$STUB_API/merge-results"
        if [ "$result" != ok ]; then
            echo "$result" >&2
            exit 1
        fi
        ;;
esac
STUB
chmod +x "$WORK/bin/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/sleep"
chmod +x "$WORK/bin/sleep"

for id in check merge dispatch; do
    step_script "$WORKFLOW" "$id" > "$WORK/$id.sh"
    if [ ! -s "$WORK/$id.sh" ]; then
        echo "dependabot-merge-on-build.yml has no run block for the step with id $id" >&2
        exit 1
    fi
done

fail() {
    echo "FAILED: $1" >&2
    cat "$WORK/log" >&2
    exit 1
}

# Runs a step's script with only the given variables set, as `shell: bash` does.
run_step() {
    local id="$1"
    shift
    : > "$WORK/output"
    : > "$API/calls"
    (env -i PATH="$WORK/bin:$PATH" GITHUB_OUTPUT="$WORK/output" STUB_API="$API" GH_TOKEN=job-token "$@" \
        bash --noprofile --norc -eo pipefail "$WORK/$id.sh") < /dev/null > "$WORK/log" 2>&1
}

run_check() {
    run_step check HEAD_BRANCH="$1" HEAD_SHA="$SHA" OWNER=acme GH_REPO=acme/app \
        || fail "check-update failed for $1"
}

expect_merge() {
    run_check "$1"
    grep -qx merge=true "$WORK/output" || fail "expected $1 to merge"
    grep -qxF "pull-request=$URL" "$WORK/output" || fail "expected the pull request's URL as output"
}

expect_left() {
    run_check "$1"
    grep -qx merge=false "$WORK/output" || fail "expected $1 to be left to a human"
    grep -qF -- "$2" "$WORK/log" || fail "expected the reason '$2'"
}

# serve_pull_request <author> <base> <head sha>: the single open pull request from the branch.
serve_pull_request() {
    jq -n --arg author "$1" --arg base "$2" --arg sha "$3" --arg url "$URL" \
        '[{number: 7, html_url: $url, user: {login: $author}, base: {ref: $base}, head: {sha: $sha}}]' \
        > "$API/pulls"
}

# serve_commit <author> <verified> <message> [<sha>]: the pull request's only commit, at $SHA
# unless given.
serve_commit() {
    jq -n --arg author "$1" --argjson verified "$2" --arg message "$3" --arg sha "${4:-$SHA}" \
        '[{sha: $sha, author: {login: $author}, commit: {message: $message, verification: {verified: $verified}}}]' \
        > "$API/commits"
}

# update <name> [<semver level>]: one entry of Dependabot's updated-dependencies list.
update() {
    printf -- '- dependency-name: %s\n  dependency-version: 1.3.0\n  dependency-type: direct:production\n' "$1"
    if [ -n "${2:-}" ]; then
        printf '  update-type: version-update:semver-%s\n' "$2"
    fi
}

# dependabot_message <entry>...: a commit message laid out the way Dependabot writes it.
dependabot_message() {
    printf 'chore(deps): bump the group\n\nBumps the group with updates.\n\n---\nupdated-dependencies:\n'
    printf '%s\n' "$@"
    printf '...\n\nSigned-off-by: dependabot[bot] <support@github.com>\n'
}

# serve_update <entry>...: Dependabot's open pull request at $SHA with one verified commit.
serve_update() {
    serve_pull_request 'dependabot[bot]' dev "$SHA"
    serve_commit 'dependabot[bot]' true "$(dependabot_message "$@")"
}

echo "checking a Maven minor update merges, found by its head branch"
serve_update "$(update org.acme:lib minor)"
expect_merge "$MAVEN_BRANCH"
grep -qxF "api --method GET repos/acme/app/pulls -f state=open -f head=acme:$MAVEN_BRANCH" "$API/calls" \
    || fail "expected the open pull request to be looked up by its head branch"

echo "checking a group of Maven patch and minor updates merges"
serve_update "$(update org.acme:lib minor)" "$(update org.acme:other patch)"
expect_merge "$MAVEN_BRANCH"

echo "checking a group holding a Maven major is left to a human"
serve_update "$(update org.acme:lib minor)" "$(update org.acme:other major)"
expect_left "$MAVEN_BRANCH" "outside the maven policy"

echo "checking a Maven update without an update type is left to a human"
serve_update "$(update org.acme:lib)"
expect_left "$MAVEN_BRANCH" "outside the maven policy"

echo "checking action updates merge, pinned commits and majors of other actions included"
serve_update "$(update osslabz/github-actions/commit-subject-check)" \
    "$(update actions/setup-java minor)" "$(update actions/checkout major)"
expect_merge "$ACTIONS_BRANCH"

echo "checking a major of this repository's workflows is left to a human"
serve_update "$(update actions/setup-java minor)" \
    "$(update osslabz/github-actions/.github/workflows/build.yml major)"
expect_left "$ACTIONS_BRANCH" "outside the github_actions policy"
serve_update "$(update OSSLabz/GitHub-Actions/.github/workflows/build.yml major)"
expect_left "$ACTIONS_BRANCH" "outside the github_actions policy"

echo "checking npm patch and minor updates merge, grouped or single"
serve_update "$(update eslint minor)"
expect_merge "$NPM_BRANCH"
serve_update "$(update eslint minor)" "$(update stylelint patch)"
expect_merge "$NPM_BRANCH"

echo "checking an npm group holding a major is left to a human"
serve_update "$(update eslint minor)" "$(update globals major)"
expect_left "$NPM_BRANCH" "outside the npm_and_yarn policy"

echo "checking other ecosystems are left to a human"
serve_update "$(update org.acme:lib minor)"
expect_left "$GRADLE_BRANCH" "gradle, which is not merged automatically"

echo "checking a branch without exactly one open pull request is left alone"
serve_update "$(update org.acme:lib minor)"
echo '[]' > "$API/pulls"
expect_left "$MAVEN_BRANCH" "no single open pull request"
serve_pull_request 'dependabot[bot]' dev "$SHA"
jq '. + .' "$API/pulls" > "$API/two" && mv "$API/two" "$API/pulls"
expect_left "$MAVEN_BRANCH" "no single open pull request"

echo "checking a pull request someone else opened is left to a human"
serve_update "$(update org.acme:lib minor)"
serve_pull_request octocat dev "$SHA"
expect_left "$MAVEN_BRANCH" "opened by octocat"

echo "checking a pull request into another branch is left to a human"
serve_update "$(update org.acme:lib minor)"
serve_pull_request 'dependabot[bot]' main "$SHA"
expect_left "$MAVEN_BRANCH" "targets main"

echo "checking a pull request that moved on since the build is left to its next build"
serve_update "$(update org.acme:lib minor)"
serve_pull_request 'dependabot[bot]' dev "$OTHER_SHA"
expect_left "$MAVEN_BRANCH" "moved on to $OTHER_SHA"
serve_update "$(update org.acme:lib minor)"
serve_commit 'dependabot[bot]' true "$(dependabot_message "$(update org.acme:lib minor)")" "$OTHER_SHA"
expect_left "$MAVEN_BRANCH" "moved on to $OTHER_SHA"

echo "checking a commit by someone else, or unverified, is left to a human"
serve_update "$(update org.acme:lib minor)"
serve_commit octocat true "$(dependabot_message "$(update org.acme:lib minor)")"
expect_left "$MAVEN_BRANCH" "not Dependabot's verified commit"
serve_commit 'dependabot[bot]' false "$(dependabot_message "$(update org.acme:lib minor)")"
expect_left "$MAVEN_BRANCH" "not Dependabot's verified commit"

echo "checking a commit without update metadata is left to a human"
serve_update "$(update org.acme:lib minor)"
serve_commit 'dependabot[bot]' true 'chore(deps): bump org.acme:lib from 1.2.0 to 1.3.0'
expect_left "$MAVEN_BRANCH" "carries no update metadata"

echo "checking the merge approves, then rebases exactly the built commit"
echo ok > "$API/merge-results"
run_step merge PR_URL="$URL" HEAD_SHA="$SHA" || fail "the merge failed"
diff <(printf '%s\n' "pr review --approve $URL" "pr merge --rebase --match-head-commit $SHA $URL") \
    "$API/calls" || fail "unexpected gh calls"
grep -qx merged=true "$WORK/output" || fail "expected merged=true"

echo "checking a merge refused because dev just moved is tried again"
printf '%s\n' "$BASE_MOVED" ok > "$API/merge-results"
run_step merge PR_URL="$URL" HEAD_SHA="$SHA" || fail "the retried merge failed"
[ "$(grep -c '^pr merge ' "$API/calls")" = 2 ] || fail "expected a second merge attempt"
grep -qx merged=true "$WORK/output" || fail "expected merged=true after the retry"

echo "checking any other refusal fails at once"
printf '%s\n' 'GraphQL: Pull Request is not mergeable (mergePullRequest)' ok > "$API/merge-results"
if run_step merge PR_URL="$URL" HEAD_SHA="$SHA"; then fail "expected the merge to fail"; fi
[ "$(grep -c '^pr merge ' "$API/calls")" = 1 ] || fail "expected no second attempt"
if grep -q merged=true "$WORK/output"; then fail "a failed merge must not report merged"; fi

echo "checking a merge refused on every attempt fails after three"
printf '%s\n' "$BASE_MOVED" "$BASE_MOVED" "$BASE_MOVED" ok > "$API/merge-results"
if run_step merge PR_URL="$URL" HEAD_SHA="$SHA"; then fail "expected the merge to fail"; fi
[ "$(grep -c '^pr merge ' "$API/calls")" = 3 ] || fail "expected three attempts"

echo "checking the merged dev is built"
run_step dispatch || fail "the dispatch failed"
diff <(echo "workflow run build-on-push.yml --ref dev") "$API/calls" || fail "unexpected gh calls"

echo "checking no run block interpolates an expression"
# shellcheck disable=SC2016 # the literal characters are what the check looks for
if grep -nF '${{' "$WORK"/check.sh "$WORK"/merge.sh "$WORK"/dispatch.sh; then
    fail "values reach the run blocks through env only"
fi

echo "all dependabot merge workflow checks passed"
