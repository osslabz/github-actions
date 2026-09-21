# github-actions

![GitHub](https://img.shields.io/github/license/osslabz/github-actions)
![GitHub Workflow Status](https://img.shields.io/github/actions/workflow/status/osslabz/github-actions/test.yml?branch=main&label=tests&logo=git)

Shared composite actions for the Java build pipelines across `osslabz` and `peekaboot-org`.
Public because a private repository's actions cannot be used from another organisation, nor
from a public repository at all.

| | Kind | Called from the project's |
| --- | --- | --- |
| [snapshot-version](#snapshot-version) | composite action | `build-on-push.yml` |
| [commit-subject-check](#commit-subject-check) | composite action | `build-on-push.yml` |

Callers use `@v1`, a tag that moves with the latest `v1.x`.

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

## Tests

`test.yml` runs on every push: the scripts' tests (`snapshot-version/test/run.sh`,
`commit-subject-check/test/run.sh`, bash and git only), both composite actions run the way a
caller runs them, and `commit-subject-check` on this repository's own pushes.
