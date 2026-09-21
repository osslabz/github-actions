# github-actions

![GitHub](https://img.shields.io/github/license/osslabz/github-actions)
![GitHub Workflow Status](https://img.shields.io/github/actions/workflow/status/osslabz/github-actions/test.yml?branch=main&label=tests&logo=git)

Shared CI for Maven projects across the owner's organisations: composite actions and reusable
workflows. Public because a private repository's actions and workflows cannot be used from
another organisation, nor from a public repository at all.

| | Kind | Called from the project's |
| --- | --- | --- |
| [snapshot-version](#snapshot-version) | composite action | `build-on-push.yml` |
| [commit-subject-check](#commit-subject-check) | composite action | `build-on-push.yml` |
| [release.yml](#release) | reusable workflow | `release.yml` |
| [dependabot-auto-merge.yml](#dependabot-auto-merge) | reusable workflow | `dependabot-auto-merge.yml` |

Callers use `@v1`, a tag that moves with the latest `v1.x`.

## The project side

A project integrates on `dev`, its default branch, and releases from there; `main` only ever
fast-forwards to the latest release tag. It keeps four files:

- `.github/workflows/build-on-push.yml`, its own, because builds differ too much to share
  (images, skipped tests, extra tools). It runs on `push` to every branch but `main` and on
  `workflow_dispatch`: the shared workflows find it by this file name, wait for it and
  dispatch it.
- `.github/workflows/release.yml` and `.github/workflows/dependabot-auto-merge.yml`, a few
  lines each, calling the reusable workflows.
- `.github/dependabot.yml`.

The pom carries maven-release-plugin with
[conventional-commits-version-policy](https://github.com/nielsbasjes/conventional-commits-maven-release),
`tagNameFormat` `@{project.version}`, and release commits with conventional subjects like
every other commit:

```xml
<scmCommentPrefix>chore(release):</scmCommentPrefix>
<scmReleaseCommitComment>@{prefix} set version to @{releaseLabel}</scmReleaseCommitComment>
<scmDevelopmentCommitComment>@{prefix} prepare next development iteration</scmDevelopmentCommitComment>
```

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
| `default-branch` | `dev` | The branch that keeps the plain version. `main` for `bitcoin-commons` and `lnd-rest-client`. |
| `pom` | `pom.xml` | The reactor's root pom, read for the version and rewritten with the new one. |
| `branch` | `github.ref_name` | The branch to derive from. |

It publishes nothing and knows no registry: the `deploy` step stays in the calling workflow,
because where to publish is the caller's choice.

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
conventional and which still follow the last tag in older repositories.

Only what the push brought is checked, never older history:

| Push | Range checked |
| --- | --- |
| to an existing branch | `before..after` of the push |
| creating a branch | from where it left `origin/<default-branch>` |
| force-push to a branch | the same, since the old tip is gone |
| force-push to the default branch | since the last `x.y.z` tag, what the next release weighs |
| `workflow_dispatch` and other events | nothing |

A shallow checkout fails the step: its range would end at the clone's depth and pass whatever
lies beyond. Dependabot's commits pass when `dependabot.yml` sets
`commit-message: {prefix: chore, include: scope}` for every ecosystem, which gives
`chore(deps): …` and `chore(deps-dev): …` whatever the repository's history looks like.

| Input | Default | |
| --- | --- | --- |
| `default-branch` | `dev` | The branch a new or force-pushed branch is compared against. |
| `before` | `github.event.before` | The branch's commit before the push. |
| `after` | `github.event.after` | The branch's commit after the push. |

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
| `packages-token` | `github-packages` | A classic token with `write:packages`; it also reads the owner's other packages, which the job's own token cannot. |

The steps of the `release` job, and why each is there:

| Step | Why |
| --- | --- |
| `concurrency: release` | A second dispatch waits for the first instead of racing it to the push. It then checks out the SHA `dev` was at when it was dispatched, not the first run's result, so it is the preflight's dev-moved check, not this alone, that refuses it. |
| `guard-release-ref` | `workflow_dispatch` has no branch filter. A failing step, not a job `if`, which would report a mis-dispatch as a green skip. |
| `checkout` | Full history and tags for the version policy and the preflight. No `ref`: maven-scm pushes to the branch checked out, which is `dev`. |
| `preflight` | Refuses, before anything is tagged or published: `dev` at a different commit than this run checked out, which is what a second dispatch queued behind a completed one sees, since its checkout is pinned to its own dispatch time; a wrong `publish-target` or a missing secret; a malformed or taken `release-version`; nothing committed since the last tag but its next development version (a second dispatch would publish an identical patch release, which Central never deletes); a `main` that `dev` does not contain, or merge commits between them, which main's linear-history rule refuses. |
| `setup-jdk` | JDK, Maven cache, the server credentials and the signing key in an isolated keyring. |
| `configure-git-user` | The identity checkout documents for commits made with the built-in token. `git config` rather than an action: nothing third-party runs in the job that holds the keys and the token. |
| `release-prepare-perform` | The profiles go on the command line, so `release:prepare`'s own `clean verify` builds javadoc and signs before anything is pushed. There is no separate build step: that `clean verify` is it. |
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
this repository's own reusable workflows, which waits for a human like a Maven major does:
`build-on-push` never runs `release.yml` or `dependabot-auto-merge.yml`, so a breaking major
would still go green. The list is positive: an update whose metadata could not be read has no
ecosystem and never merges.

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

## Tests

`test.yml` runs on every push: the scripts' tests (`snapshot-version/test/run.sh`,
`commit-subject-check/test/run.sh`, bash and git only), both composite actions run the way a
caller runs them, `commit-subject-check` on this repository's own pushes, actionlint over every
workflow, and shellcheck over the composite actions' scripts, both downloaded and checked
against their published checksums.
