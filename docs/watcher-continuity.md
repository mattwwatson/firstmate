# Watcher continuity

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Must-work continuity now lives above that process boundary instead of depending on the model remembering a re-arm step.

## Ownership

Pi's `.pi/extensions/fm-primary-pi-watch.ts` and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` own continuous re-arm after an actionable child close.
Each adapter starts the next arm before delivering the wake prompt, checks current session-lock ownership at launch, preserves one child or scheduled retry at a time, and applies bounded exponential retry after an unexpected or failed close.
A failed follow-up never cancels continuity restoration.

## Actionable wake ordering

After an actionable Pi or OpenCode child close, the adapter starts and verifies one singleton successor before it delivers the original wake.
It waits at most one readiness timeout per attempt, then sends TERM and waits a bounded retirement confirmation before the next lock-verified exponential retry.
If the unready arm does not retire within that bound, the adapter keeps ownership, starts no overlapping retry, and delivers the typed fallback immediately.
When that retained arm later closes, its actual close is classified as a new supervised event without replaying the earlier fallback.
After the configured retry bound is exhausted, it delivers the original wake with a typed continuity-restoration failure even if every successor arm hung without reporting readiness.
This is deliberate Option B ordering: the fleet is protected before the model handles the wake whenever restoration succeeds, but the model is never left blind when it does not.

Claude retains its native tracked background-task completion path, extended on 2026-07-22 by the captain-wait deferral below.
Its new PreToolUse continuity gate allows wake drain, arm recovery, and independently fail-closed teardown, but refuses other fleet commands while tasks are in flight and no identity-matched live watcher holds the home lock.
Allowing an ordinary literal teardown prevents a terminal wake from creating a recovery circle: forced or dynamically constructed teardown remains blocked, ordinary teardown itself still refuses dirty, unlanded, incomplete-scout, and unresolved-decision cases, and the turn-end guard continues to require supervision for any tasks left in flight.
Codex retains its bounded foreground checkpoint protocol.
Grok retains its tracked background-task notification protocol.
No adapter starts a replacement with shell `&`.

This continuity mechanism does not modify the turn-end guard or its adapters.
They remain the final backstop rather than the normal continuity mechanism.

## Captain-wait deferral (Claude)

Claude's continuity depends on the primary taking a turn: a completed arm task re-invokes the model, and the model's next turn re-arms.
On 21/07/2026 that dependency starved twice in one live session: firstmate asked the captain something, the one-shot watcher fired an actionable wake and exited during the wait, and with the turn blocked inside the captain-decision tool call neither the completion notification nor a new turn could happen - the cycle ledger shows 902s and 2518s stretches with zero watcher cycles, ended only by the captain's answer.
Notifications deliver at tool boundaries and idle re-invocation works even with a pending chat question (both measured 2026-07-22, [`turnend-guard.md`](turnend-guard.md)), so the ONLY starved state is a turn blocked inside such a tool call - and it lasts exactly as long as the captain takes.

The deferral closes that window at the watcher, keeping the one-shot contract for every other path:

- `bin/fm-turn-pretool-stamp.sh`, an all-tools Claude PreToolUse hook, records `<tool> TAB <session-pid> TAB <epoch>` in `state/.primary-turn-active`; `bin/fm-turnend-guard.sh` removes it at every in-scope Stop, so the marker means "the primary is mid-turn, last tool = X".
- When `bin/fm-watch.sh` is about to exit with an actionable wake and the marker names a captain-decision tool (`FM_WATCH_DEFER_TOOLS`, default `AskUserQuestion`) stamped by a live session pid, it defers: the wake is already durably queued, so it keeps polling - beacon fresh, wedge evidence accruing, checks running - and holds the reason.
- It flushes every deferred reason and exits the moment the marker is cleared (the turn ended), overwritten with a different tool (the captain answered and the turn resumed), invalidated by the stamping session dying, or `FM_WATCH_DEFER_MAX` (default 3600s) running out.
  The arm then completes normally and the notification is deliverable again.
- Deferral never engages for ordinary working tools (a long Bash call keeps today's immediate exit and mid-turn delivery), while away mode is active (the daemon owns triage and wakes the primary by pane injection), or once the cap is spent, so a leaked marker - a turn aborted mid-question - degrades to exactly today's behavior after at most one deferral window.

Only Claude's tracked hooks write the marker, so codex, opencode, pi, and grok homes never defer and are unchanged.
The beacon stays honest: it is only ever touched by a genuinely live watcher, and a deferring watcher IS the live supervision cycle, so the turn-end guard needs no special case for it.
A permission-prompt wait (a blocked tool other than the configured decision tools) is not covered and keeps today's behavior; extend `FM_WATCH_DEFER_TOOLS` only with evidence.

Worst-case latency accounting: a wake during a normal working turn is unchanged; a wake during a captain wait was previously delivered at the end of the wait anyway (the notification could not deliver earlier) and now arrives within one poll plus one notification latency of the wait ending, with the fleet supervised throughout instead of unsupervised; a leaked marker holds wakes for at most `FM_WATCH_DEFER_MAX` before reverting to today's exit-and-notify.

## Arm-layer cycle contract

`bin/fm-watch-arm.sh` never returns a clean empty success.
An actionable child output returns that reason normally.
A zero/empty child return rechecks the home lock and beacon, attaches to a verified healthy successor when one exists, or emits `watcher: FAILED - cycle ended without an actionable reason` and exits nonzero.
An attached arm follows verified identity-matched successors and reports the same typed failure if that chain ends without one.

The arm layer appends one tab-separated record per observed cycle to `state/.watch-cycle-exits.log`.
Each record includes arm and watcher PIDs, start and end timestamps, exit code and signal, classified reason, beacon age, lock identity before and after close, and successor disposition.
The file is size-capped through `FM_WATCH_CYCLE_LOG_MAX_BYTES` and `FM_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.watch-triage.log` remains only the watcher's bounded absorbed-wake debug log and carries no lifecycle semantics.

The default 300-second grace is unchanged.
Only the watcher process touches `state/.last-watcher-beat`; no helper process can make a wedged watcher appear healthy.

## Regression coverage

`tests/fm-pi-watch-extension.test.sh` simulates actionable and empty child closes against the actual Pi and OpenCode close handlers, blocks prompt delivery to prove the successor launches first, verifies single-flight behavior, changes the session lock before close to prove ownership is rechecked, and hangs each successor arm to prove bounded fallback delivery includes the typed restoration failure.
`tests/fm-watcher-lock.test.sh` covers verified-successor attach, the typed self-eviction failure, bounded and successor-linked lifecycle rows, and a SIGSTOP counterfactual that distinguishes a live PID from a stale beacon before classifying termination.
`tests/fm-continuity-pretool-check.test.sh` proves the Claude gate rejects only non-recovery fleet execution in the precise unhealthy state and preserves the existing Stop registration.
`tests/fm-watch-captain-wait.test.sh` holds the captain-wait regressions: the preserved no-marker lapse-and-detect baseline, deferral holding supervision through the wait with a fresh beacon, flush on marker clear with every held wake delivered, and the working-tool, dead-session, away-mode, and cap exclusions.

## Sanitized live evidence, 2026-07-17

All five harnesses ran against git-initialized scratch projects and isolated `FM_HOME` state.
Existing harness-managed credentials remained in place, no credential bytes were copied into a fixture or transcript, and no account was created.
Pi used the existing shared Pi auth store with the explicit `openai-codex/gpt-5.6-sol` provider/model pin and low thinking.
Each run used the smallest prompt needed to exercise the harness-native path.

Harness versions:

```text
Claude Code 2.1.214
codex-cli 0.144.4
OpenCode 1.17.18
Pi 0.80.10
grok 0.2.103 (89c3d36fb6f1) [stable]
```

Claude ran an arm fixture through its native tracked background option, observed background completion, allowed the wake drain, and refused the next unrelated fleet command before its body executed.
The captured system message exactly named `[watcher-continuity]`, `bin/fm-wake-drain.sh`, tracked Claude re-arm through `bin/fm-watch-arm.sh`, and the blocked `fm-crew-state.sh` command.
Command: `FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-continuity-live-e2e.test.sh`.
Observed result: `ok - Claude 2.1.214 (Claude Code) live E2E refused only the post-completion fleet command with exact re-arm guidance`.

Codex ran the real one-second foreground watcher checkpoint and returned `checkpoint: no actionable wake within 1s` without switching to the arm wrapper.
Command: `FM_CODEX_LIVE_E2E=1 tests/fm-codex-continuity-live-e2e.test.sh`.
Observed result: `ok - codex-cli 0.144.4 live E2E preserved the one-second foreground checkpoint path`.

OpenCode ran its persistent TUI plugin, established the first watcher from `session.idle`, received an actionable close, and ledger-linked a live successor before the model handled the wake.
The model executed no watcher-arm command and the turn-end backstop did not fire.
Command: `FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh`.
Observed result: `ok - OpenCode 1.17.18 live E2E auto-started one successor before prompt handling without a model re-arm`.

Pi loaded the tracked extensions in its interactive TUI, called `fm_watch_arm_pi` once, received an actionable close, and ledger-linked a successor before the handling turn ended.
The turn-end backstop did not fire, and `/quit` removed both the watcher and arm child.
Command: `FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh`.
Observed result: `ok - Pi 0.80.10 live E2E used shared Codex auth, auto-started one successor before turn end, and cleaned up`.

Grok ran the real arm wrapper through `run_terminal_command` with its tracked background option, surfaced its native task-completion notification after the actionable close, and recorded `reason=actionable-signal` in the cycle ledger.
No shell ampersand was used.
Command: `FM_GROK_LIVE_E2E=1 tests/fm-grok-continuity-live-e2e.test.sh`.
Observed result: `ok - grok 0.2.103 (89c3d36fb6f1) [stable] live E2E preserved tracked background completion and shared ledger classification`.

The goal is continuity with fewer supervision tokens and no Pi/OpenCode model-memory re-arm step.
No zero-latency guarantee is claimed; lock verification, watcher startup, and bounded retry delays remain deliberate safety work.
