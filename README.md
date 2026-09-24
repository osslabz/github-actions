# github-actions

![GitHub](https://img.shields.io/github/license/osslabz/github-actions)
![GitHub Workflow Status](https://img.shields.io/github/actions/workflow/status/osslabz/github-actions/test.yml?branch=main&label=tests&logo=git)

Shared CI for Maven projects across the owner's organisations: composite actions and reusable
workflows. Public because a private repository's actions and workflows cannot be used from
another organisation, nor from a public repository at all.

| | Kind | Used by |
| --- | --- | --- |
| [build.yml](#build) | reusable workflow | the project's `build-on-push.yml` |
| [snapshot-version](#snapshot-version) | composite action | `build.yml`, or a project's own build |
| [commit-subject-check](#commit-subject-check) | composite action | `build.yml`, or a project's own build |
| [release.yml](#release) | reusable workflow | the project's `release.yml` |
| [dependabot-auto-merge.yml](#dependabot-auto-merge) | reusable workflow | the project's `dependabot-auto-merge.yml` |

Callers use `@v1`, a tag that moves with the latest `v1.x` (see [Releasing](#releasing)).

## The project side

A project integrates on `dev`, its default branch, and releases from there; `main` only ever
fast-forwards to the latest release tag. It keeps four files:

- `.github/workflows/build-on-push.yml`, `.github/workflows/release.yml` and
  `.github/workflows/dependabot-auto-merge.yml`, a few lines each, calling the reusable
  workflows. build-on-push runs on `push` to every branch but `main` and on
  `workflow_dispatch`: the shared workflows find it by this file name, wait for it and
  dispatch it. A project whose build `build.yml` does not cover keeps a build-on-push of its
  own under that name and uses the two composite actions directly.
- `.github/dependabot.yml`.

The pom carries maven-release-plugin with
[conventional-commits-version-policy](https://github.com/nielsbasjes/conventional-commits-maven-release),
`tagNameFormat` `@{project.version}`, and release commits with conventional subjects like
every other commit:

```xml
<!-- xml:space="preserve" keeps the trailing space Plexus would otherwise trim;
     ScmTagPhase concatenates this prefix straight into the tag message. -->
<scmCommentPrefix xml:space="preserve">chore(release): </scmCommentPrefix>
<scmReleaseCommitComment>@{prefix} set version to @{releaseLabel}</scmReleaseCommitComment>
<scmDevelopmentCommitComment>@{prefix} prepare next development iteration</scmDevelopmentCommitComment>
```

Third-party and GitHub-owned actions are pinned by commit SHA with the version as a comment,
here and in the projects, because a tag can be moved to other code. Dependabot keeps the pins
current in one grouped pull request a week. Projects use this repository's own actions and
workflows at `@v1`: same owner, and a SHA would turn every change here into a pull request
everywhere. `build.yml` names its two actions by commit instead (see [Releasing](#releasing)).

## snapshot-version

Gives a branch's build a Maven version of its own, so every branch can publish a snapshot
without standing on another branch's coordinate. The integration branch keeps the plain
version out of the pom; every other branch folds its name in.

```
dev                          0.3.1-SNAPSHOT
feat/async-instrumentation   0.3.1-feat-async-instrumentation-SNAPSHOT
```

```yaml
- uses: osslabz/github-actions/snapshot-version@v1
  with:
    default-branch: dev
```

Run it after the step that sets the JDK up and before `deploy`. `actions/setup-java` keys its
Maven cache on the poms' contents, so rewriting them earlier misses that cache on every branch
but the default one. The action leaves the poms rewritten in the workspace; nothing commits them.
On the default branch it rewrites nothing, since the version stays what the pom says, and
Maven does not start.

The version is also an output:

```yaml
- uses: osslabz/github-actions/snapshot-version@v1
  id: snapshot
- run: echo "${{ steps.snapshot.outputs.version }}"
```

| Input | Default | |
| --- | --- | --- |
| `default-branch` | `dev` | The branch that keeps the plain version. |
| `pom` | `pom.xml` | The reactor's root pom, read for the version and rewritten with the new one. |
| `branch` | `github.ref_name` | The branch to derive from. |

It publishes nothing and knows no registry: the `deploy` step stays in the calling workflow,
because where to publish is the caller's choice.

### Installing a branch's snapshot locally

`snapshot-version/install-local.sh` applies the same rule to `mvn install`, so a branch build
cannot shadow the integration branch's coordinate in `~/.m2`.

```
cd ../codelabz-user-management
../osslabz/github-actions/snapshot-version/install-local.sh
```

On the integration branch that is a plain `mvn install`. On any other branch it rewrites the
poms, installs, and puts them back — unlike CI, this runs in a tree someone is working in, so
the revert is in a trap and survives a failed install or a interrupted run.

Without it, `mvn install` on a feature branch writes that build over `~/.m2`'s copy of the
integration branch's snapshot, and every project depending on it compiles against the feature
branch without saying so. `~/.m2` is per machine, so two machines sharing a checkout build
different code from the same commit with no diff to explain it. That cost hodlfolio-v2 a
morning in September 2026.

A consuming project points at a branch build by naming the version in a property:

```xml
<codelabz-user-management.version>0.1.0-SNAPSHOT</codelabz-user-management.version>
```

```
mvn -Dcodelabz-user-management.version="$(../osslabz/github-actions/snapshot-version/install-local.sh --print --directory ../codelabz-user-management)" test
```

| Option | Default | |
| --- | --- | --- |
| `--print` | | Print the version and stop. |
| `--dry-run` | | Print the Maven commands and stop. |
| `--directory` | `.` | The project to install. |
| `--default-branch` | `dev` | The branch that keeps the plain version. |
| `--pom` | `pom.xml` | The reactor's root pom. |

Anything after `--` is passed to the `install` invocation.

`versions-maven-plugin` is named in full, so no consuming repository has to pin it. The rewrite
passes `-DupdateBuildOutputTimestampPolicy=never`, without which the plugin replaces
`project.build.outputTimestamp` with the run's own clock and a reproducible build stops being
reproducible.

## commit-subject-check

Fails the build when a pushed commit subject is not a
[conventional commit](https://www.conventionalcommits.org/). The release reads its version from
these subjects, and a subject the version policy cannot parse counts as a patch, whatever it
changed. Put it first after the checkout, which needs the full history:

```yaml
- uses: actions/checkout@<sha> # v7.0.1
  with:
    fetch-depth: 0
- uses: osslabz/github-actions/commit-subject-check@v1
  with:
    default-branch: dev
```

A subject passes as `type(scope)!: description`, scope and `!` optional, with the type one of
`feat fix perf refactor docs test build ci chore style revert`. A scope, when given, is letters,
digits, `_` and `-` only: what `conventional-commits-version-policy` 1.0.9 parses by default. A
slash, a dot or a comma-separated list would pass a laxer check but not that policy, which would
then derive a patch from the subject regardless of what it changed. Merge commits are skipped,
and so are `[release] …` subjects, which the release plugin wrote before release commits became
conventional and which still follow the last tag in older repositories. `git revert` writes
`Revert "feat: …"`, which fails; reword it to `revert: …`.

Only what the push brought is checked, never older history:

| Push | Range checked |
| --- | --- |
| to an existing branch | `before..after` of the push |
| creating a branch | from where it left `origin/<default-branch>` |
| force-push, or `before` not an ancestor of `after` | nothing: the range is meaningless, so the step logs why and passes |
| `workflow_dispatch` and other events | nothing |

A rewrite (`git filter-repo`, a force-pushed rebase) leaves `before` unresolvable, or resolvable
but no longer an ancestor of `after`; either way there is no meaningful range, and widening it
to the default branch would walk into history the gate was never meant to audit. A force-push
is already a deliberate, logged admin act, so the step skips instead, logging why.

A shallow checkout fails the step: its range would end at the clone's depth and pass whatever
lies beyond. Dependabot's commits pass when `dependabot.yml` sets
`commit-message: {prefix: chore, include: scope}` for every ecosystem, which gives
`chore(deps): …` and `chore(deps-dev): …` whatever the repository's history looks like.

A push that queues behind a running build on `dev` can be replaced by a later push before it
starts. The replaced push's own commits are then never checked.

| Input | Default | |
| --- | --- | --- |
| `default-branch` | `dev` | The branch a new branch is compared against. |
| `before` | `github.event.before` | The branch's commit before the push. |
| `after` | `github.event.after` | The branch's commit after the push. |
| `forced` | `github.event.forced` | Whether the push was a force-push. |

## build

Builds a project on every push but to `main`: checks the pushed commit subjects, gives the
branch its snapshot version, runs Maven, and publishes the snapshot, and an application's
image, where the caller's policy says so. The caller, for a library on Central that publishes
from `dev` only:

```yaml
name: build-on-push

on:
  push:
    branches-ignore:
      - main
  # Pushes made with GITHUB_TOKEN start no run, so the release and the Dependabot merge
  # dispatch this workflow on dev to build and publish what they pushed.
  workflow_dispatch:

concurrency:
  group: build-on-push-${{ github.ref }}
  cancel-in-progress: ${{ github.ref_name != 'dev' }}

jobs:
  build-on-push:
    permissions:
      contents: read
    uses: osslabz/github-actions/.github/workflows/build.yml@v1
    with:
      publish-target: central
      publish-branches: dev
      maven-profiles: osslabz-publish
    secrets:
      central-username: ${{ secrets.OSSRH_USERNAME }}
      central-token: ${{ secrets.OSSRH_TOKEN }}
```

A library on GitHub Packages that publishes every branch, needs native libraries from the
runner and skips its tests:

```yaml
  build-on-push:
    permissions:
      contents: read
    uses: osslabz/github-actions/.github/workflows/build.yml@v1
    with:
      publish-target: github-packages
      publish-branches: all
      maven-arguments: -DskipTests
      system-packages: tesseract-ocr libtesseract-dev
    secrets:
      packages-token: ${{ secrets.PACKAGES_TOKEN }}
```

A Spring Boot application whose image the same Maven run builds:

```yaml
  build-on-push:
    permissions:
      contents: read
      packages: write
    uses: osslabz/github-actions/.github/workflows/build.yml@v1
    with:
      publish-target: github-packages
      publish-branches: all
      maven-profiles: coverage
      image-build: spring-boot-goal
      image-names: my-app
    secrets:
      packages-token: ${{ secrets.PACKAGES_TOKEN }}
```

Triggers and concurrency stay in the caller. A newer push cancels a running branch build; a
run on `dev` is never cancelled, so two deploys of one snapshot coordinate never overlap.

| Input | Default | |
| --- | --- | --- |
| `publish-target` | required | `central`: server `central`, Central's snapshot repository through the publishing profile. `github-packages`: server `github`, the repository's own package. |
| `publish-branches` | required | `dev`: only `dev` publishes, other branches verify, for Central's publishing limits. `all`: every branch publishes under its own snapshot version. Dependabot's runs never publish. |
| `maven-profiles` | empty | Active in the Maven run, e.g. the profile that carries the publishing plugin. |
| `maven-arguments` | empty | More arguments, split on spaces and passed as written, e.g. `-DskipTests` for tests that need live services. |
| `java-version` | `25` | The JDK the build runs on. |
| `system-packages` | empty | apt packages installed before the build, e.g. a native library a test loads. |
| `image-build` | `none` | `spring-boot-goal`: the Maven run adds `spring-boot:build-image-no-fork` after its lifecycle phase. `pom-bound`: the pom binds the image build to a phase itself, in each module that builds one. |
| `image-names` | empty | The artifactIds whose images are pushed as `ghcr.io/<owner>/<artifactId>:<version>`. Required with an `image-build`. |

`maven-arguments`, `system-packages` and `image-names` split on whitespace, spaces or newlines
alike, so a YAML block scalar works the same as a single line.

| Secret | For | |
| --- | --- | --- |
| `central-username`, `central-token` | `central` | Central Portal user token. Maven gets it only in runs that publish. |
| `packages-token` | `github-packages` | A classic token with `read:packages`, plus `write:packages` where it publishes. Empty: the job's own token. |

GitHub Packages resolves and deploys through one server, `github`. The job's own token deploys
to the repository's package but cannot read the owner's other private packages; a build that
depends on them passes `packages-token`. Dependabot's runs see Dependabot secrets only: a
Dependabot secret of the same name with `read:packages` alone covers them, since they never
publish.

The job declares no `permissions`. A called workflow can lower the caller's but never raise
them, so it holds what the caller grants: `contents: read`, plus `packages: write` where the
job's own token deploys or an image is pushed.

The steps, and why each is there:

| Step | Why |
| --- | --- |
| `check-inputs` | Fails a mistyped input before anything runs, and decides whether the run publishes: on `dev`, or on every branch with `all`, never for Dependabot, whose runs hold a read-only token. Compared in bash, because expression comparisons ignore case and a branch `Dev` is not `dev`. Publishing to Central without its secrets fails here rather than at the upload. |
| `checkout` | Full history for `check-commit-subjects` and for plugins that read git. No persisted token: nothing in the build pushes. |
| `check-commit-subjects` | [commit-subject-check](#commit-subject-check) on the pushed range. |
| `install-system-packages` | Only with `system-packages`. The names are checked first, so no option reaches `apt-get`. |
| `setup-jdk` | JDK, Maven cache and the target's server. Dependabot branches read the cache but never save to it: their poms miss it, and the entry would be readable from that branch only. |
| `set-snapshot-version` | [snapshot-version](#snapshot-version), after `setup-jdk`, whose cache key hashes the poms. |
| `maven-build` | `deploy` in a run that publishes, `verify` otherwise, with the project's `./mvnw` where there is one. `install` is skipped: nothing reads the local repository afterwards, and the project's own artifacts would otherwise fill the Maven cache. Images are built in every run, so an update that breaks the image never goes green. |
| `push-images` | Only in runs that publish. Spring Boot names each image `<artifactId>:<version>`; this tags it for `ghcr.io` and pushes it with the job's token. |

## release

Releases the project from `dev`: `release:prepare` commits the release version, tags it and
commits the next development version; `release:perform` publishes the tag; `main` follows the
tag; a GitHub release gets generated notes; and `build-on-push` runs on `dev` for the next
snapshot. The caller, publishing to Central:

```yaml
name: release

on:
  workflow_dispatch:
    inputs:
      releaseVersion:
        description: Overrides the version the commit subjects imply (x.y.z). Empty keeps it.
        required: false
        type: string

jobs:
  release:
    # Covers every job of the shared workflow; each job takes only what it needs.
    permissions:
      contents: write
      actions: write
    uses: osslabz/github-actions/.github/workflows/release.yml@v1
    with:
      publish-target: central
      maven-profiles: osslabz-release,osslabz-publish
      release-version: ${{ inputs.releaseVersion }}
    secrets:
      central-username: ${{ secrets.OSSRH_USERNAME }}
      central-token: ${{ secrets.OSSRH_TOKEN }}
      gpg-private-key: ${{ secrets.OSSRH_GPG_SECRET_KEY }}
      gpg-passphrase: ${{ secrets.OSSRH_GPG_SECRET_KEY_PASSWORD }}
```

Publishing to GitHub Packages instead, with tests skipped in the release's builds:

```yaml
    with:
      publish-target: github-packages
      maven-profiles: release
      release-arguments: -DskipTests
      release-version: ${{ inputs.releaseVersion }}
    secrets:
      packages-token: ${{ secrets.PACKAGES_TOKEN }}
```

Secrets are passed by name: `secrets: inherit` does not cross organisations, and naming them
hands the workflow no more than it uses. The caller's `permissions` must cover both jobs,
because a called workflow can only lower them.

| Input | Default | |
| --- | --- | --- |
| `publish-target` | required | `central`: server `central`, signed with the GPG key. `github-packages`: server `github`, no signature. |
| `maven-profiles` | required | Active in `release:prepare`'s build and in `release:perform`. List the profiles that sign and build javadoc here. |
| `release-arguments` | empty | Passed as `-Darguments`, which reaches the builds both goals fork, e.g. `-DskipTests` for tests that need live services. A pom that sets `<arguments>` itself wins over it. |
| `release-version` | empty | `x.y.z` to release instead of what the commit subjects imply, e.g. a deliberate 1.0.0 or a repository whose tags confuse the policy. |
| `java-version` | `25` | The JDK the release builds with. |

| Secret | For | |
| --- | --- | --- |
| `central-username`, `central-token` | `central` | Central Portal user token. |
| `gpg-private-key`, `gpg-passphrase` | `central` | ASCII-armored signing key and its passphrase. |
| `packages-token` | `github-packages` | A classic token with `write:packages`, which also reads the owner's other packages. No `repo` scope: git and a pom's scm URL use the job's own token. |

The steps of the `release` job, and why each is there:

| Step | Why |
| --- | --- |
| `concurrency: release` | A second dispatch waits for the first instead of racing it to the push. It then checks out the SHA `dev` was at when it was dispatched, not the first run's result, so it is the preflight's dev-moved check, not this alone, that refuses it. |
| `guard-release-ref` | `workflow_dispatch` has no branch filter. A failing step, not a job `if`, which would report a mis-dispatch as a green skip. |
| `checkout` | Full history and tags for the version policy and the preflight. No `ref`: maven-scm pushes to the branch checked out, which is `dev`. |
| `preflight` | Refuses, before anything is tagged or published: `dev` at a different commit than this run checked out, which is what a second dispatch queued behind a completed one sees, since its checkout is pinned to its own dispatch time; a wrong `publish-target` or a missing secret; a malformed or taken `release-version`; nothing committed since the last tag but its next development version (a second dispatch would publish an identical patch release, which Central never deletes); a `main` that `dev` does not contain, or merge commits between them, which main's linear-history rule refuses. Such merges come from the old `--no-ff` flow; a repository admin fast-forwards `main` to `dev` once, past the rule, with the command the error prints. |
| `setup-jdk` | JDK, Maven cache, the server credentials and the signing key in an isolated keyring. For GitHub Packages the server's password is the packages token, under a variable of its own: `GITHUB_TOKEN` stays the job's token, which a pom's scm URL hands to `release:perform`'s clone of a private repository. |
| `configure-git-user` | The identity checkout documents for commits made with the built-in token. `git config` rather than an action: nothing third-party runs in the job that holds the keys and the token. |
| `release-prepare-perform` | The profiles go on the command line, so `release:prepare`'s own `clean verify` builds javadoc and signs before anything is pushed. There is no separate build step: that `clean verify` is it. The project's `./mvnw` runs where there is one. |
| `released-tag` | `release:prepare` leaves `HEAD` one commit after the tag; `git describe` names the tag this run made, not the newest one. |
| `fast-forward-main` | Pushes the tag's commit to `main` without `--force`, so git refuses anything but a fast-forward. Runs before the release notes, so their failure cannot leave `main` behind. |
| `create-github-release` | `gh release create --verify-tag --generate-notes`: fails rather than create a tag if the pushed one is missing. |

A second job, `build-next-snapshot`, dispatches `build-on-push.yml` on `dev` once the release
succeeded. The release pushed with `GITHUB_TOKEN`, and pushes made with it start no workflow,
so without this the next snapshot would wait for the next human push. It is a job of its own
so that the Maven build never holds `actions: write`.

When a release fails, what it left behind decides the way out. A re-run repeats the workflow at
the dispatched commit, so after the first push it can only fail at the push again.

| Failed in | State | Way out |
| --- | --- | --- |
| guard, preflight, setup, `release:prepare`'s build | nothing pushed | fix the cause, dispatch again |
| the push of the release commit (dev moved meanwhile) | nothing pushed | dispatch again |
| the tag push | `dev` has the release commit but no tag, and its pom carries no snapshot, which fails `build-on-push` | commit the next `-SNAPSHOT` on `dev`, then release with `releaseVersion` |
| `release:perform` | tag and `dev` commits public, artifacts not published | a cause outside the code (credentials, an outage): deploy the tag from a machine holding the key; a cause in the code: the version is burned, fix on `dev` and release the next one. Either way, this run never reached `fast-forward-main`: fast-forward `main` to the tag, create the GitHub release and dispatch `build-on-push` on `dev` by hand |
| `fast-forward-main` | published | repair `main`, then push the tag's commit to it. This run never reached `create-github-release` or `build-next-snapshot` either: create the GitHub release and dispatch `build-on-push` on `dev` by hand |
| `create-github-release` | published, `main` moved | run the step's command by hand |
| `build-next-snapshot` | released | dispatch `build-on-push` on `dev` by hand |

## dependabot-auto-merge

Merges a Dependabot pull request into `dev` once its `build-on-push` run is green. The caller:

```yaml
name: dependabot-auto-merge

on:
  pull_request:
    branches:
      - dev

jobs:
  dependabot-auto-merge:
    # Covers every job of the shared workflow; each job takes only what it needs.
    permissions:
      contents: write
      pull-requests: write
      actions: write
    uses: osslabz/github-actions/.github/workflows/dependabot-auto-merge.yml@v1
```

A run Dependabot triggers gets a read-only token unless `permissions` raises it, as the caller
does, and no Actions secrets, which this workflow does not use.

What merges: Maven patch and minor updates, and every GitHub Actions update, except a major of
this repository's own workflows, which waits for a human like a Maven major does:
`build-on-push` runs `build.yml` but never `release.yml` or `dependabot-auto-merge.yml`, so a
breaking major would still go green. The list is positive: an update whose metadata could not
be read has no ecosystem and never merges.

| Job / step | Why |
| --- | --- |
| `metadata` | Runs `fetch-metadata` in its own, read-only job, so the ecosystem and update type are known before the job that holds `contents: write` and `pull-requests: write` starts. |
| job `if` | Only pull requests opened and pushed by Dependabot. A human's push to one leaves the merge to a human. Repeated on `merge` rather than relied on through `needs`, so a mis-triggered run reads as a skip, not a failure. |
| `merge` concurrency | Scoped to the pull request: a Dependabot push that supersedes an in-progress merge attempt cancels it instead of racing it. Job-level and left off `build-merged-dev`, so cancelling an attempt here never cancels the dispatch that follows one that already succeeded. |
| wait for the build | Polls up to five minutes for the head commit's `build-on-push` run, which may not exist yet, then watches it. Not `gh pr checks --watch`, which counts this job as pending and would wait for itself. A red or cancelled build fails the job and the pull request stays open. |
| approve | After the green build, so a red pull request never shows as approved. The repository must allow Actions to approve pull requests. |
| merge | `--rebase` keeps history linear and Dependabot's conventional subject, which squash would replace with the title. `--match-head-commit` refuses a head the build did not cover. |

A third job, `build-merged-dev`, dispatches `build-on-push.yml` on `dev` after a merge. The
merge rebased the pull request onto whatever `dev` had become, a combination nobody built, and
pushed it with `GITHUB_TOKEN`, which starts no workflow. The dispatched build tests it and
publishes the snapshot.

Re-running a red build does not re-run this workflow. Re-running this workflow's own failed run
after the build is green does merge it, since it looks the build up again by head commit.
Otherwise, comment `@dependabot rebase` on the pull request, or merge it by hand.

## Releasing

Changes land on `main` by fast-forward, and `test.yml` must be green there first. A project
can try a change before any tag moves by using the commit's full SHA in place of `@v1`, for
the actions and the workflows alike.

Then tag the commit and move `v1` to it. Both tags are annotated, like the existing ones:

```
git tag -a v1.1.0 -m "v1.1.0" <sha>
git tag -f -a v1 -m "v1 at v1.1.0" <sha>
git push origin v1.1.0
git push --force origin v1
```

Moving `v1` changes every caller's next run at once. A change a caller has to adapt to goes to
`v2`. Dependabot's updates of the pins here reach callers the same way, with the next tag.

`build.yml` runs `commit-subject-check` and `snapshot-version` at the commit its `uses:` lines
name, not at `@v1`: `uses:` takes no expression, so a reusable workflow cannot name the commit
it runs from. A change to either action lands first; a second commit points `build.yml` at it.
`test/build-workflow.sh` fails while it lags behind, so the two commits push together:
`test.yml` runs on the pushed head, and a push that stops at the action's commit alone leaves
that head red until the pin-bumping commit joins it.

## Tests

`test.yml` runs on every push: the scripts' tests (`snapshot-version/test/run.sh`,
`commit-subject-check/test/run.sh`, bash and git only); `test/build-workflow.sh`, which runs
`build.yml`'s shell steps against stubs for `mvn`, `docker` and `sudo` and checks its pinned
actions; both composite actions run the way a caller runs them; `commit-subject-check` on this
repository's own pushes; actionlint over every workflow; and shellcheck over the scripts. Both
linters are downloaded and checked against their published checksums.
