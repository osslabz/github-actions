# github-actions

Shared composite actions for the Java build pipelines across `osslabz` and `peekaboot-org`.
Public because a private repository's actions cannot be used from another organisation, nor
from a public repository at all.

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

The version is also an output:

```yaml
- uses: osslabz/github-actions/snapshot-version@v1
  id: snapshot
- run: echo "${{ steps.snapshot.outputs.version }}"
```

| Input | Default | |
| --- | --- | --- |
| `default-branch` | `dev` | The branch that keeps the plain version. `main` for `bitcoin-commons` and `lnd-rest-client`. |
| `pom` | `pom.xml` | The reactor's root pom. |
| `branch` | `github.ref_name` | The branch to derive from. |

It publishes nothing and knows no registry: the `deploy` step stays in the calling workflow,
because where to publish is the caller's choice.

`versions-maven-plugin` is named in full, so no consuming repository has to pin it. The rewrite
passes `-DupdateBuildOutputTimestampPolicy=never`, without which the plugin replaces
`project.build.outputTimestamp` with the run's own clock and a reproducible build stops being
reproducible.

## Tests

`snapshot-version/test/run.sh` checks the derivation against a fixture pom. It needs bash and
nothing else, and runs on every push.
