# Primary turn-end supervision guard

This is the authoritative current contract for the "no turn ends blind" primary backstop referenced from AGENTS.md section 8.
The predicate lives in `bin/fm-turnend-guard.sh`.
Primary scope lives in `bin/fm-primary-scope-lib.sh`, shared with the native session-start nudge in [`sessionstart-nudge.md`](sessionstart-nudge.md).
Harness hook files adapt each enabled primary harness integration's turn-end mechanism to that shared predicate.

Related PreToolUse guards deny unsafe commands before execution rather than detecting a blind turn end afterward.
Their separate owners are [`arm-pretool-check.md`](arm-pretool-check.md), [`cd-guard.md`](cd-guard.md), and [`subagent-guard.md`](subagent-guard.md).
Do not infer this guard's scope, loop safety, or compatibility tradeoffs for those guards.

## Current invariant

`bin/fm-guard.sh` is a pull-based warning that runs only when another supervision command invokes it.
The turn-end guard closes the remaining gap at the primary's own turn boundary.
When work is in flight and no identity-matched watcher has a fresh beacon, the harness integration must either block the turn end or force one bounded follow-up that uses the recovery instruction from the emitted session-start protocol.
The guard remains a backstop; [`watcher-continuity.md`](watcher-continuity.md) owns normal continuity.

## Shared predicate

The guard first calls the shared primary scope.
A secondmate home runs its own primary Firstmate session, so a genuine `.fm-secondmate-home` marker includes it whether the home is a linked worktree or plain clone.
The marker must be a regular non-symlink file whose whitespace-stripped first line is a non-empty identifier containing only letters, digits, dots, underscores, and dashes.
An unmarked checkout or invalid marker falls through to the git-dir check.
That check keeps crewmate and scout linked worktrees inert because their git dir differs from their git common dir.
It also requires `AGENTS.md`, `bin/`, and the effective state directory.

For an in-scope primary, the guard counts in-flight work from `state/*.meta`.
The default cross-harness mode exits silently with no work in flight.
Claude's `--claude` mode also treats `state/x-watch.check.sh` as supervision need, so X-mode relay polling remains guarded without an in-flight task.
Otherwise it calls `fm_watcher_healthy <state-dir> <watch-path> [grace-seconds] [home]` from `bin/fm-wake-lib.sh`, the same identity-matched lock and fresh-beacon check used by `bin/fm-watch-arm.sh`.
A stale beacon blocks even when a watcher pid is live.
A fresh leftover beacon blocks when the lock is missing, dead, or identity-mismatched.

`FM_STATE_OVERRIDE` wins over `FM_HOME/state`, and `FM_HOME` wins over repository-root `state/`.
`FM_GUARD_GRACE` controls beacon freshness and defaults to 300 seconds.
If `jq` is missing or hook stdin is empty, the guard exits 0 because it cannot safely read loop-guard fields; on a missing `jq` the in-scope turn-activity marker clear (2026-07-22 section) still runs first.

## Harness integrations

- Claude registers two `Stop` hooks in `.claude/settings.json`, both anchored through `CLAUDE_PROJECT_DIR`: `bin/fm-turnend-guard.sh --claude`, and `bin/fm-claude-stop-autoarm.sh` with `asyncRewake: true` and `timeout: 28800`.
  It also registers an all-tools `PreToolUse` turn-activity stamp through `bin/fm-turn-pretool-stamp.sh`, the input to the captain-wait deferral (2026-07-22 section).
- Codex registers a `Stop` hook in `.codex/hooks.json`, anchors the executable to the hook process working directory, verifies a Firstmate-shaped hook-bearing root, and passes the original payload to the shared guard.
- OpenCode listens for `session.idle` in `.opencode/plugins/fm-primary-turnend-guard.js`, lets the watcher coordinator act first, and calls `client.session.promptAsync` once when the guard returns 2.
- Pi listens for `agent_settled` in `.pi/extensions/fm-primary-turnend-guard.ts`, runs once per logical agent run, and calls `pi.sendUserMessage(..., { deliverAs: "followUp" })` once when the guard returns 2.
- Grok registers a `Stop` hook in `.grok/hooks/fm-primary-turnend-guard.json` and delegates capability selection to `bin/fm-turnend-guard-grok.sh`.
  The tracked Claude Stop entries are inert when `GROK_AGENT` is present, so Grok's Claude-compatible settings loading cannot create a second continuation path.

Claude and Codex can block a Stop directly with exit status 2 and stderr.
Both payloads carry `stop_hook_active`.
In the default Codex mode, a true value lets the second stop finish after one forced continuation.

Claude runs the guard with `--claude`, which ignores `stop_hook_active` and cooperates with the Stop-owned auto-arm.
Claude Code sets `stop_hook_active=true` on every stop after any stop-hook continuation, including `asyncRewake` rewakes, which re-opened the 2026-07-21 blind window under the default one-shot behavior.
The Claude mode waits up to `FM_CLAUDE_AUTOARM_SYNC_WAIT_MS` (default 800 milliseconds) and allows the stop when the watcher is healthy, `state/.claude-autoarm.lock` has a live owner, or `state/.claude-autoarm-epoch` contains a fresh rewake outcome.
When none of those proofs appears, it re-blocks up to `FM_CLAUDE_TURNEND_BLOCK_BUDGET` times (default 3, below Claude's 8-block override), then allows degraded with a visible `systemMessage`.
Any allow resets the budget.

OpenCode, Pi, and pi-signed expose passive callbacks for this purpose.
Their adapters fail open at the hook boundary to protect the user session but schedule one bounded follow-up when the predicate blocks.
The generated prompts use the canonical `turn-end-guard` kind after the U+2063 `FIRSTMATE_OP: ` prefix, so Ahoy does not treat them as captain messages.
Each passive adapter owns a loop latch.
Pi keeps the latch across internal tool turns and clears it only when the generated follow-up settles or delivery fails.
OpenCode's forced follow-up is supported for persistent TUI sessions and remains fail-open in headless `opencode run`.

Grok makes exactly one typed capability decision from each running Stop payload.
A boolean `stopHookActive` selects native blocking, including both false on the initial stop and true on the bounded continuation.
The camel-case field has precedence when both spellings appear; when it is absent, a boolean `stop_hook_active` selects the same native path for compatibility.
The native path returns the shared guard's status and stderr to the same Grok process and never starts `grok --resume`.
When both capability spellings are absent, the adapter preserves one pre-native `grok --resume` fallback guarded by `GROK_TURNEND_GUARD_ACTIVE` and intentionally omits `--permission-mode`.
Malformed JSON, a selected field with a non-boolean type, missing `jq`, missing hook prerequisites, or an already-active legacy guard allows the stop without starting either continuation path.
Grok's project hook requires the checkout to be trusted with `/hooks-trust` or launch-time `--trust`; genuine pre-native builds can run the same tracked hook from an isolated global hook directory.

If a passive adapter cannot invoke its SDK, or the Grok legacy fallback cannot find `grok` or a session id, the next pull-based `fm-guard.sh` call reports the problem.
That warning uses `bin/fm-supervision-instructions.sh --repair-line`, so it always points to the active harness protocol rather than embedding another repair command.

## Compatibility limits

- Child crewmate and scout worktrees are outside scope.
- A valid secondmate home is in scope; an idle secondmate endpoint with no X-mode relay poll remains healthy because it has no supervision need.
- The direct-blocking and bounded passive-follow-up split is limited to the primary integrations listed above.
- OpenCode headless mode and untrusted Grok project hooks remain fail-open at the host boundary.
- Kimi Code CLI 0.29.1 exposes only global `[[hooks]]` configuration in `~/.kimi-code/config.toml`, including a `Stop` event with snake_case payload fields `hook_event_name`, `session_id`, `cwd`, and `stop_hook_active`.
- Kimi has no project-level hook configuration and remains outside the primary guard integrations above.
- Captain-approved Kimi crew wake support uses `bin/fm-kimi-turnend-hook.sh` to edit only one marker-delimited Firstmate region in that global config and install a silent always-zero hook.
- The hook remains inert unless the payload `cwd` contains a per-task token pointer that resolves through Firstmate's private registry to one `state/<id>.turn-ended` marker.
- Installation refuses before writing unless `python3` with `tomllib` and `jq` are available.
- If `jq` is removed after installation, the hook remains silent and exits 0, turn-end wakes stop, and Kimi crews fall back to idle detection.
- Unreadable hook input remains fail-open.
- No harness adapter uses a shell ampersand to manufacture supervision.

## Regression coverage

### 2026-07-22: captain-wait supervision gap and the hand-off false alarm

Two related symptoms were observed live on 21-22/07/2026 in the main home (backlog `fm-supervision-gap-on-captain-wait`) and fixed together.

First, fleet supervision lapsed while firstmate waited on a captain decision: the cycle ledger `state/.watch-cycle-exits.log` shows 902s and 2518s stretches with zero watcher cycles, each beginning at an actionable watcher exit and ending only when the captain's answer produced a turn, and each reported by this guard as "WATCHER DOWN" only at that first turn end - truthful, but entirely after the fact.

Second, the guard fired "TURN WOULD END BLIND ... last beat: 2s ago" during the benign seconds-long hand-off after every actionable exit (previous cycle just notified and exited, fresh arm not yet holding the lock), training the operator to discount real alarms.

Three first-hand measurements on Claude Code 2.1.217 (Darwin 24.6.0, macOS 15.7.3, interactive session in a tmux pane) established the mechanism:

1. **Idle re-invocation works even with a pending question.**
   Procedure: launch a detached `run_in_background` Bash task (`sleep 25`, epoch markers to the session scratchpad), then end the turn with a question pending in the final assistant text.
   Observed: `launch=1784708317 complete=1784708342 reinvoke=1784708347` - re-invoked 5s after completion with zero human input, via a `<task-notification>` whose system notice stated no human input had been received.
   So a plain-chat question does NOT suppress the background-notify wake.
2. **Notifications deliver mid-turn at tool boundaries.**
   Procedure: launch a background `sleep 10` task, then run a foreground `sleep 40` tool call in the same turn.
   Observed: the task completed during the foreground call and its notification was delivered immediately after that tool returned, inside the same turn.
3. **A hook command's parent is the session process.**
   Procedure: scratch project with a PreToolUse hook logging `$$`, `$PPID`, and `ps -o comm= -p $PPID`; run `claude -p 'Run the bash command `true` ...' --dangerously-skip-permissions`.
   Observed: `self=14867 ppid=8316 pcomm=claude` - the hook's parent is the long-lived `claude` session process, so a stamp recording `$PPID` self-invalidates when the session dies.

Together with the ledger, measurements 1 and 2 pin the lapse's masking condition: the only state in which a completed arm task can wake nothing is a turn blocked INSIDE a captain-decision tool call (AskUserQuestion awaiting the captain), which lasts exactly as long as the captain wait.
Both reproductions were confirmed end to end against unfixed `main` (0278fc3) before the fix: an actionable exit with no following turn left the beacon stale past grace with the wake durably queued, and a Stop landing seconds after an actionable exit blocked with "last beat: 3s ago".

The surviving fix has one guard-side part, plus the watcher-side captain-wait deferral owned by [`watcher-continuity.md`](watcher-continuity.md):

- **Marker clearing.** Every in-scope Stop removes `state/.primary-turn-active`, the turn-activity marker `bin/fm-turn-pretool-stamp.sh` maintains from PreToolUse; that clear is the deferral's release signal and runs before the `jq` degrade so it works on every real primary turn end.

### Superseded: the one-shot hand-off pass (`--notify-wake`)

The second symptom above - the benign hand-off false alarm - was originally fixed with a one-shot pass.
A `--notify-wake` adapter flag let the guard allow exactly one stop per undrained `state/.wake-queue` record, keyed on that record's epoch-seq in `state/.turnend-handoff-pass`, on the reasoning that the undrained fresh wake IS the in-flight notification and the turn end is what lets the harness deliver it.

That mechanism is **retired**, superseded by the Stop-owned auto-arm (`bin/fm-claude-stop-autoarm.sh`) described under "Harness integrations" above.
The two were built independently to fix the same false alarm and are not equivalent: the pass merely permitted one blind stop and relied on the model's next turn to re-arm, whereas the auto-arm re-arms from the Stop hook itself, so the window closes rather than being tolerated.
Keeping both would have left two owners of one continuity contract.
`--notify-wake`, the `NOTIFY_WAKE` parser block, and `state/.turnend-handoff-pass` no longer exist; the flag is now rejected as an unknown argument.

The first symptom's fix - the captain-wait deferral - is **not** superseded and is retained deliberately.
The auto-arm's own contract accepts a residual active-turn window in which the durable wake queue preserves events and the successor arm starts only at the next Stop after the handling turn.
That residual window is exactly the 902s and 2518s lapse measured above, which occurs while no Stop can happen at all.
The deferral therefore composes with the auto-arm rather than duplicating it.

## Tests

`tests/fm-turnend-guard.test.sh` covers the predicate, main and secondmate primary scope, child-worktree exclusion, `FM_HOME` and `FM_STATE_OVERRIDE` precedence, the cooperative `--claude` claim wait, epoch allow, re-block budget, Pi logical-run latching, missing-`jq` behavior, all five primary registrations, Grok native and legacy selection, typed field precedence, malformed input, and exactly-one-path safety.
`tests/fm-kimi-harness.test.sh` covers the separate Kimi crew hook's format preservation, idempotence, refusal cases, token guard, spawn registration, and teardown cleanup.
`tests/fm-supervision-instructions.test.sh` covers recovery-line ownership and pi-signed's identity-preserving reuse of Pi's protocol.
`tests/fm-turnend-guard.test.sh` also covers turn-activity marker clearing and its primary scoping, and `bin/fm-turn-pretool-stamp.sh`'s stamp, scope, and jq fail-open behavior.
`tests/fm-watch-captain-wait.test.sh` holds the end-to-end captain-wait reproductions and the watcher deferral suite.
`FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh` is the opt-in isolated Pi path.
[`verification/supervision.md`](verification/supervision.md#turn-end-guard) records the active cross-harness empirical evidence, including the 2026-07-24 Claude `asyncRewake` revalidation.
