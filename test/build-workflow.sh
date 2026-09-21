#!/usr/bin/env bash
#
# Runs the shell steps of .github/workflows/build.yml the way the runner does, against stubs
# for mvn, docker and sudo, and checks that build.yml runs this repository's actions as they
# are at HEAD.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly HERE
readonly ROOT="$HERE/.."
readonly WORKFLOW="$ROOT/.github/workflows/build.yml"
WORK="$(mktemp -d)"
readonly WORK
trap 'rm -rf "$WORK"' EXIT

readonly PLAN_DEFAULTS=(PUBLISH_TARGET=central PUBLISH_BRANCHES=dev IMAGE_BUILD=none IMAGE_NAMES=
    SYSTEM_PACKAGES= HAS_CENTRAL_SECRETS=true BRANCH=dev ACTOR=octocat)

# Prints the `run: |` block of the step with the given id without its indentation, which is
# the script the runner writes for that step.
step_script() {
    awk -v id="$1" '
        in_run && $0 != "" && index($0, indent) != 1 { exit }
        in_run { print substr($0, length(indent) + 1); next }
        in_step && /^ *run: \|$/ {
            match($0, /^ */)
            indent = ""
            for (i = 0; i < RLENGTH + 2; i++) indent = indent " "
            in_run = 1
            next
        }
        $0 ~ "^ *id: " id "$" { in_step = 1 }
    ' "$WORKFLOW"
}

# Records its own name and arguments, one per line, and what --password-stdin reads. Fails
# when its first argument is $STUB_FAIL.
write_stub() {
    cat > "$1" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$(basename "\$0")" "\$@" >> "$WORK/calls"
for argument in "\$@"; do
    if [ "\$argument" = --password-stdin ]; then printf 'stdin=%s\n' "\$(cat)" >> "$WORK/calls"; fi
done
if [ -n "\${STUB_FAIL:-}" ] && [ "\${1:-}" = "\$STUB_FAIL" ]; then exit 1; fi
exit 0
STUB
    chmod +x "$1"
}

# Runs a step's script with only the given variables set, as `shell: bash` does.
run_step() {
    local id="$1"
    shift
    : > "$WORK/output"
    : > "$WORK/calls"
    (cd "$WORK/project" && env -i PATH="$WORK/bin:$PATH" GITHUB_OUTPUT="$WORK/output" "$@" \
        bash --noprofile --norc -eo pipefail "$WORK/$id.sh") < /dev/null > "$WORK/log" 2>&1
}

expect_plan() {
    local publish="$1" goal="$2" push_images="$3" pair
    shift 3
    if ! run_step plan "${PLAN_DEFAULTS[@]}" "$@"; then
        echo "check-inputs failed for: $*" >&2
        cat "$WORK/log" >&2
        exit 1
    fi
    for pair in "publish=$publish" "goal=$goal" "push-images=$push_images"; do
        if ! grep -qxF -- "$pair" "$WORK/output"; then
            echo "expected $pair for: $*" >&2
            cat "$WORK/output" >&2
            exit 1
        fi
    done
}

expect_plan_failure() {
    local message="$1"
    shift
    if run_step plan "${PLAN_DEFAULTS[@]}" "$@"; then
        echo "expected check-inputs to fail for: $*" >&2
        exit 1
    fi
    if ! grep -qF -- "::error::$message" "$WORK/log"; then
        echo "expected '::error::$message' for: $*" >&2
        cat "$WORK/log" >&2
        exit 1
    fi
}

expect_calls() {
    if ! diff <(printf '%s\n' "$@") "$WORK/calls" > "$WORK/diff"; then
        echo "unexpected commands (< expected, > actual):" >&2
        cat "$WORK/diff" >&2
        exit 1
    fi
}

mkdir -p "$WORK/bin" "$WORK/project"
write_stub "$WORK/bin/mvn"
write_stub "$WORK/bin/docker"
write_stub "$WORK/bin/sudo"

for id in plan system-packages maven-build push-images; do
    step_script "$id" > "$WORK/$id.sh"
    if [ ! -s "$WORK/$id.sh" ]; then
        echo "build.yml has no run block for the step with id $id" >&2
        exit 1
    fi
done

echo "checking no run block interpolates an expression"
# shellcheck disable=SC2016 # the literal characters are what the check looks for
if grep -nF '${{' "$WORK"/*.sh; then
    echo "values reach the run blocks through env only" >&2
    exit 1
fi

echo "checking dev publishes and a feature branch verifies"
expect_plan true deploy false
expect_plan false verify false BRANCH=feat/decoder

# Expression comparisons ignore case; the branch that publishes is exactly dev.
echo "checking a branch named Dev is not dev"
expect_plan false verify false BRANCH=Dev

echo "checking every branch publishes when publish-branches is all"
expect_plan true deploy false PUBLISH_TARGET=github-packages PUBLISH_BRANCHES=all BRANCH=feat/decoder

echo "checking Dependabot's runs never publish"
expect_plan false verify false ACTOR='dependabot[bot]'
expect_plan false verify false PUBLISH_TARGET=github-packages PUBLISH_BRANCHES=all \
    ACTOR='dependabot[bot]' BRANCH=dependabot/maven/org.foo-bar-1.2.3

echo "checking images are pushed only by runs that publish"
expect_plan true deploy true PUBLISH_TARGET=github-packages PUBLISH_BRANCHES=all \
    IMAGE_BUILD=spring-boot-goal IMAGE_NAMES=my-app BRANCH=feat/decoder
expect_plan false verify false PUBLISH_TARGET=github-packages PUBLISH_BRANCHES=all \
    IMAGE_BUILD=pom-bound IMAGE_NAMES="web-private web-public" ACTOR='dependabot[bot]'

echo "checking a run that only verifies needs no Central secrets"
expect_plan false verify false HAS_CENTRAL_SECRETS=false BRANCH=feat/decoder
expect_plan_failure "publishing to Central needs the secrets central-username and central-token" \
    HAS_CENTRAL_SECRETS=false

echo "checking unknown input values are refused"
expect_plan_failure "publish-target is 'Central'" PUBLISH_TARGET=Central
expect_plan_failure "publish-branches is 'main'" PUBLISH_BRANCHES=main
expect_plan_failure "image-build is 'paketo'" IMAGE_BUILD=paketo

echo "checking image-build and image-names come together"
expect_plan_failure "image-names needs image-build spring-boot-goal or pom-bound" IMAGE_NAMES=my-app
expect_plan_failure "image-build pom-bound needs image-names" IMAGE_BUILD=pom-bound

echo "checking image and package names are checked, globs included"
expect_plan true deploy true IMAGE_BUILD=pom-bound IMAGE_NAMES="web-private web_2 web.public"
expect_plan_failure "image name 'My-App'" IMAGE_BUILD=pom-bound IMAGE_NAMES="web My-App"
expect_plan_failure "image name '*'" IMAGE_BUILD=spring-boot-goal IMAGE_NAMES='*'
expect_plan true deploy false SYSTEM_PACKAGES="tesseract-ocr libtesseract-dev"
expect_plan_failure "system package '-oAPT::Get::Assume-Yes=1'" \
    SYSTEM_PACKAGES="tesseract-ocr -oAPT::Get::Assume-Yes=1"

echo "checking list inputs split on newlines too, as a YAML block passes them"
expect_plan true deploy true IMAGE_BUILD=pom-bound IMAGE_NAMES=$'web-private\nweb-public'
expect_plan true deploy false SYSTEM_PACKAGES=$'tesseract-ocr\nlibtesseract-dev'

echo "checking the system packages are installed after an index update"
run_step system-packages SYSTEM_PACKAGES="tesseract-ocr libtesseract-dev"
expect_calls sudo apt-get update sudo apt-get install -y tesseract-ocr libtesseract-dev

echo "checking system packages split on newlines are all installed"
run_step system-packages SYSTEM_PACKAGES=$'tesseract-ocr\nlibtesseract-dev'
expect_calls sudo apt-get update sudo apt-get install -y tesseract-ocr libtesseract-dev

echo "checking the Maven run for a verify"
run_step maven-build GOAL=verify MAVEN_PROFILES= MAVEN_ARGUMENTS= IMAGE_BUILD=none
expect_calls mvn --batch-mode --update-snapshots -Dmaven.install.skip=true verify

echo "checking profiles, the image goal and extra arguments reach the Maven run"
run_step maven-build GOAL=deploy MAVEN_PROFILES=coverage,publish \
    MAVEN_ARGUMENTS="-DskipTests  -Dspring-boot.build-image.skip=true" IMAGE_BUILD=spring-boot-goal
expect_calls mvn --batch-mode --update-snapshots -Dmaven.install.skip=true deploy -P coverage,publish \
    spring-boot:build-image-no-fork -DskipTests -Dspring-boot.build-image.skip=true

echo "checking extra arguments split on newlines are all passed"
run_step maven-build GOAL=verify MAVEN_PROFILES= \
    MAVEN_ARGUMENTS=$'-DskipTests\n-Dspring-boot.build-image.skip=true' IMAGE_BUILD=none
expect_calls mvn --batch-mode --update-snapshots -Dmaven.install.skip=true verify \
    -DskipTests -Dspring-boot.build-image.skip=true

echo "checking a pom-bound image adds nothing to the Maven run"
run_step maven-build GOAL=deploy MAVEN_PROFILES= MAVEN_ARGUMENTS= IMAGE_BUILD=pom-bound
expect_calls mvn --batch-mode --update-snapshots -Dmaven.install.skip=true deploy

echo "checking an argument is passed as written, never globbed"
touch -- "$WORK/project/-Dpattern=a.txt"
run_step maven-build GOAL=verify MAVEN_PROFILES= MAVEN_ARGUMENTS="-Dpattern=*.txt" IMAGE_BUILD=none
expect_calls mvn --batch-mode --update-snapshots -Dmaven.install.skip=true verify "-Dpattern=*.txt"
rm -- "$WORK/project/-Dpattern=a.txt"

echo "checking the project's Maven wrapper is preferred"
write_stub "$WORK/project/mvnw"
run_step maven-build GOAL=verify MAVEN_PROFILES= MAVEN_ARGUMENTS= IMAGE_BUILD=none
expect_calls mvnw --batch-mode --update-snapshots -Dmaven.install.skip=true verify
rm "$WORK/project/mvnw"

echo "checking each image is tagged for ghcr.io under the lower-cased owner and pushed"
run_step push-images IMAGE_NAMES="web-private web-public" VERSION=0.4.0-feat-x-SNAPSHOT \
    OWNER=Example-Org REGISTRY_TOKEN=registry-token
expect_calls docker login ghcr.io --username Example-Org --password-stdin stdin=registry-token \
    docker tag web-private:0.4.0-feat-x-SNAPSHOT ghcr.io/example-org/web-private:0.4.0-feat-x-SNAPSHOT \
    docker push ghcr.io/example-org/web-private:0.4.0-feat-x-SNAPSHOT \
    docker tag web-public:0.4.0-feat-x-SNAPSHOT ghcr.io/example-org/web-public:0.4.0-feat-x-SNAPSHOT \
    docker push ghcr.io/example-org/web-public:0.4.0-feat-x-SNAPSHOT

echo "checking image names split on newlines are all tagged and pushed"
run_step push-images IMAGE_NAMES=$'web-private\nweb-public' VERSION=0.4.0-SNAPSHOT \
    OWNER=example-org REGISTRY_TOKEN=registry-token
expect_calls docker login ghcr.io --username example-org --password-stdin stdin=registry-token \
    docker tag web-private:0.4.0-SNAPSHOT ghcr.io/example-org/web-private:0.4.0-SNAPSHOT \
    docker push ghcr.io/example-org/web-private:0.4.0-SNAPSHOT \
    docker tag web-public:0.4.0-SNAPSHOT ghcr.io/example-org/web-public:0.4.0-SNAPSHOT \
    docker push ghcr.io/example-org/web-public:0.4.0-SNAPSHOT

echo "checking an image the build did not produce fails the push"
if run_step push-images IMAGE_NAMES=missing VERSION=0.4.0-SNAPSHOT OWNER=example-org \
    REGISTRY_TOKEN=registry-token STUB_FAIL=tag; then
    echo "expected push-images to fail when docker tag fails" >&2
    exit 1
fi
if grep -qx push "$WORK/calls"; then
    echo "nothing may be pushed after a failed tag" >&2
    exit 1
fi

echo "checking build.yml runs this repository's actions as they are at HEAD"
for action in commit-subject-check snapshot-version; do
    pin="$(sed -n "s#^ *uses: osslabz/github-actions/${action}@\([0-9a-f]\{40\}\)\$#\1#p" "$WORKFLOW")"
    if [ -z "$pin" ]; then
        echo "build.yml names no commit for $action" >&2
        exit 1
    fi
    if ! git -C "$ROOT" merge-base --is-ancestor "$pin" HEAD; then
        echo "$pin, the commit build.yml runs $action from, is not in HEAD's history" >&2
        exit 1
    fi
    if ! git -C "$ROOT" diff --quiet "$pin" HEAD -- "$action"; then
        echo "$action changed after $pin, the commit build.yml runs it from" >&2
        exit 1
    fi
done

echo "all build workflow checks passed"
