# Bitbucket merge watch and build results verification

Empirical record for the merge watch and build-status reading on Bitbucket Cloud, alongside the existing GitHub and GitLab watches.
Every live command below was run on 2026-07-22 against the live Bitbucket Cloud API and its output is reproduced exactly; the credential used is firstmate's own read-only pair (docs/configuration.md "Forge credentials"), and no live command in this record changed anything on Bitbucket.
The stage-4 merge action section is dated where it appears and its evidence is stubbed, for the reason recorded there.
The stubbed no-network coverage for the same behavior lives in `tests/fm-bb-merge-watch.test.sh`.

## Versions

```
$ python3 --version
Python 3.9.6

$ bash --version | head -1
GNU bash, version 3.2.57(1)-release (arm64-apple-darwin24)
```

python3 is the poll's JSON reader and its only tool beyond POSIX shell; `bin/fm-pr-check.sh` refuses to arm a Bitbucket watch without it, and the poll itself stays silent rather than guessing.
The sidecar-driven run below executed under stock macOS bash 3.2, so the poll depends on no newer shell.

## The evidence pull requests

All live evidence reads `atlassian/atlaskit-mk-2`, a public repository whose pull requests exist in every state this change must distinguish: 5157 is merged, 1892 is declined, and 8026 was open when this record was made.
Reading them needs only firstmate's read-only credential, and the poll never falls back to anonymous access even though these particular repositories would allow it - an unauthenticated fallback is exactly the silent degradation the arm-time verification exists to prevent.

## Why Bitbucket has its own byte-static poll

GitHub and GitLab share `bin/fm-pr-poll.sh`, which shells out to their credential-owning CLIs (`gh`, `glab`).
Bitbucket has no such CLI, so its poll resolves a credential through `bin/fm-forge-credential.sh` and parses JSON with python3 - machinery the audited gh/glab poll must not absorb, which is why `bin/fm-bb-pr-poll.sh` is a separate byte-static program.
The registration record's provider tag selects which template a task's check must match byte-for-byte and which program the watcher executes; `fm_pr_poll_template_for_provider` in `bin/fm-pr-lib.sh` is the single owner of that mapping, and every trust property still rests on the unchanged artifact validation against the selected template.
Existing GitHub and GitLab polls therefore keep their bytes, their v2 registrations, and their armed state through this change; `tests/fm-bb-merge-watch.test.sh` asserts a canonical GitHub poll rides through the migration byte-identical.

## End to end: arming and polling a real pull request

Arming verifies the exact pull request with one authenticated read before any artifact is written, records the source head expanded to the full commit id, and surfaces the build verdict:

```
$ FM_HOME=/tmp/bb-e2e fm-pr-check.sh e1 https://bitbucket.org/atlassian/atlaskit-mk-2/pull-requests/5157
armed: state/e1.check.sh
build: green

$ cat state/e1.pr-poll
bitbucket
https://bitbucket.org/atlassian/atlaskit-mk-2/pull-requests/5157
bitbucket.org
atlassian/atlaskit-mk-2
5157

$ head -3 state/e1.pr-poll-registration
fm-pr-poll-registration-v2
e1
bitbucket

$ cat state/e1.meta
window=fm-e1
pr=https://bitbucket.org/atlassian/atlaskit-mk-2/pull-requests/5157
pr_head=68443e3d6f3d12efa5dbb361aab24c768df5240e
```

The `pr_head` line is why the expansion step exists: the pull-request object abbreviates `source.commit.hash` to 12 characters (`68443e3d6f3d`), `fm_pr_head_valid` rightly refuses anything shorter than a full commit id, and one deterministic read of `/2.0/repositories/{ws}/{repo}/commit/{hash}` returns the full 40-character id recorded above.

Running the poll the way the watcher does, against each state - an empty result means the poll stayed silent and produced no wake:

```
$ fm-bb-pr-poll.sh --validated bitbucket https://bitbucket.org/atlassian/atlaskit-mk-2/pull-requests/5157 bitbucket.org atlassian/atlaskit-mk-2 5157
merged
$ fm-bb-pr-poll.sh --validated bitbucket https://bitbucket.org/atlassian/atlaskit-mk-2/pull-requests/1892 bitbucket.org atlassian/atlaskit-mk-2 1892
declined
$ fm-bb-pr-poll.sh --validated bitbucket https://bitbucket.org/atlassian/atlaskit-mk-2/pull-requests/8026 bitbucket.org atlassian/atlaskit-mk-2 8026
```

The state vocabulary is exactly `OPEN`, `MERGED`, `DECLINED`, `SUPERSEDED`; only the three terminal values print (`merged`, `declined`, `superseded`), `SUPERSEDED` is never treated as merged, and everything else - including every error - is silent.
`declined` and `superseded` wake firstmate because the watch would otherwise stay silent forever on a pull request that can no longer merge.

The same bytes work in the watcher's manual sidecar-driven mode, where the published check locates its own record:

```
$ bash state/e1.check.sh
merged
```

## Build results

`bin/fm-bb-build-status.sh` reads `/2.0/repositories/{ws}/{repo}/pullrequests/{id}/statuses` and prints the verdict, then the latest entry per build key:

```
$ fm-bb-build-status.sh https://bitbucket.org/atlassian/atlaskit-mk-2/pull-requests/5157
green
SUCCESSFUL -488070497
SUCCESSFUL 285181905
SUCCESSFUL Netlify build - 68443e
```

Three behaviors of that reader are deliberate, each pinned by `tests/fm-bb-merge-watch.test.sh` against stubbed responses:

- Bitbucket keeps every status ever posted against the source head, so an old `FAILED` under a rerun key would poison the verdict after a green rerun; only the latest entry per `key` is judged, ordered by parsed timestamps so entries with different UTC offsets compare correctly.
- The commit-status vocabulary is `SUCCESSFUL`, `FAILED`, `INPROGRESS` (no underscore), `STOPPED` - distinct from the pipeline-state and filter vocabularies; an unrecognised state refuses rather than guesses.
- One request with `pagelen=100` is made and pagination is never followed; a response pointing at a next page refuses loudly rather than judging a set that may hide a failure.

`bin/fm-pr-check.sh` surfaces the verdict at arm time (the `build: green` line above) because no-mistakes covers builds only while its run is live; this covers the post-run and direct-PR cases.
A statuses hiccup at arm time surfaces `build: unknown` without unarming the merge watch.

The merge path refuses anything not provably green before any merge request exists, naming the failing build; `tests/fm-bb-merge-watch.test.sh` pins those refusals and asserts no request reaches the merge endpoint until the verdict passes.
A green pull request proceeds into the stage-4 merge action below.

## A missing credential produces one wake, never a false merge and never a silent never-merge

The GitHub and GitLab polls treat every failure as silence, which is correct for them: a missing CLI is refused at arm time, and nothing can quietly revoke their credentials between polls.
A Bitbucket credential can be revoked, expire, or lose its keychain entry after arming, and pure silence would mean merge detection quietly never fires - the exact failure the arm-time verification exists to prevent.
The poll therefore distinguishes three outcomes: a credential problem prints `bitbucket-auth-missing`, an authenticated-but-invisible pull request prints `bitbucket-pr-unreachable`, and everything inconclusive (an unreachable forge, an unreadable response) stays silent for the next cycle.

With the credential store unreachable, against the genuinely merged pull request:

```
$ FM_FORGE_KEYCHAIN_TOOL_OVERRIDE=/usr/bin/false fm-bb-pr-poll.sh --validated bitbucket https://bitbucket.org/atlassian/atlaskit-mk-2/pull-requests/5157 bitbucket.org atlassian/atlaskit-mk-2 5157
bitbucket-auth-missing
```

The watcher wakes firstmate on that line once per task and kind, guarded by a `state/<id>.bb-poll-warned.*` marker, because the warning is news the first time and unactionable wallpaper every 300 seconds after; the marker is removed with the task's other poll artifacts at teardown.

Arming is still the load-bearing refusal - a watch that could never report is never armed, and the diagnostic names the failing requirement without ever printing a credential value:

```
$ FM_FORGE_KEYCHAIN_TOOL_OVERRIDE=/usr/bin/false FM_HOME=/tmp/bb-e2e fm-pr-check.sh e2 https://bitbucket.org/atlassian/atlaskit-mk-2/pull-requests/5157
error: cannot verify the Bitbucket pull request before arming: keychain entry firstmate-bitbucket-email is absent from the login keychain
$ ls /tmp/bb-e2e/state/e2.check.sh
ls: /tmp/bb-e2e/state/e2.check.sh: No such file or directory
```

## Upgrade path from an existing armed watch

Nothing changes for armed GitHub and GitLab polls: their template bytes and v2 registrations are untouched, so they validate exactly as before with no re-arm and no migration event.
A legacy Bitbucket check (arbitrary bytes with a canonical `pr=` in task metadata) is handled by the existing non-executing migration, which now selects the rebuild template from the recorded URL's provider: the legacy bytes are quarantined unrun and a canonical poll is rebuilt against `bin/fm-bb-pr-poll.sh`.
`tests/fm-bb-merge-watch.test.sh` pins both properties in one migration run.

## Stage 4: the merge action (23/07/2026)

`bin/fm-pr-merge.sh` now dispatches a canonical Bitbucket pull request URL to `bin/fm-bb-pr-merge.sh` after recording `pr=` through `bin/fm-pr-check.sh`, exactly as the GitHub path records before merging; the GitHub path itself is byte-for-byte untouched and `tests/fm-pr-merge.test.sh` passes unchanged.
The merge POST goes through the same shared credential the poller holds, per the captain's one-credential decision: `bin/fm-forge-credential.sh pr-merge` is the resolver's ONE write action, fixed to the merge endpoint of a validated repository and pull-request number, so no caller can turn the credential into a general write channel.
A read-only credential keeps the whole path dormant because the forge itself answers the POST with 403, which the merge script reports as the missing pull-request write scope.

The protocol handling follows section 8.4 of the parity investigation and is pinned case-by-case by `tests/fm-bb-pr-merge.test.sh` against stubbed HTTP:

- Success is reported ONLY on a pull-request state read back from the API as exactly `MERGED`; a 200 whose read-back is not `MERGED` is reported as a failure.
- A 202 validates its `Location` header down to this pull request's own `merge/task-status/{id}` endpoint on `api.bitbucket.org` and polls it (`task_status` `PENDING` until `SUCCESS`) within a bounded number of polls before the same read-back confirmation; a foreign or malformed location is never followed.
- A 409 (a ref moved underneath the merge) is reported for inspection and never retried blindly.
- A 429 backs off using `Retry-After` when present, bounded in attempts and per-wait seconds.
- Bitbucket's non-standard 555 (merge took too long) and an unanswered POST are settled by reading the state back: `MERGED` confirms, anything else is a retry-later outcome, never a blind retry and never an assumed failure.
- The strategy defaults to squash, must be one of the six documented names, and is checked against the pull request's `source.branch.merge_strategies` when readable: an excluded strategy refuses naming the permitted list rather than silently switching.
- The build gate above runs inside the merge script, so a red or pending verdict refuses even when the script is invoked directly.

Merge capability is detected from the credential's REAL scopes, not assumed from configuration: `bin/fm-forge-credential.sh merge-capable` reads the scope list a 403 rejection of `GET /2.0/user` names in `error.detail.granted` (the documented probe; firstmate's recommended credential deliberately lacks the account read scope, so the probe reliably 403s) and answers `yes`, `no`, or `unknown` without guessing.
The mismatch warning fires at exactly two moments, per the capability-checked decision of 22/07/2026: session-start bootstrap prints a `FORGE_CREDENTIAL:` line naming every Bitbucket project whose `merge` grant the credential provably cannot honor, and `bin/fm-project-mode.sh` warns on a granted `--grant merge` query for such a project.
A read-only credential with no merge grants anywhere stays silent - that is a healthy fleet shape, not a diagnostic - and an unprovable scope list warns nowhere, because the merge attempt itself still fails closed at the forge.

Evidence for this stage is the stubbed suite (`bash tests/fm-bb-pr-merge.test.sh`, 24 cases, all passing on 23/07/2026, macOS bash 3.2/Python 3.9.6 toolchain as recorded above); no live merge was performed because this home's credential is read-only and the captain merges every pull request himself.

### Deferred live smoke test

Open question 8 of the parity investigation - whether the live API honours the request's `merge_strategy` (and a `message`) or overrides them from repository settings - remains unverified: an old Jira issue reported the override and was closed Invalid in 2019, and settling it needs one real merge with a write-capable credential on a scratch pull request.
Until a captain with such a credential runs that smoke test, treat the strategy actually applied by a live merge as unconfirmed; the confirmed-MERGED success rule is unaffected either way.
