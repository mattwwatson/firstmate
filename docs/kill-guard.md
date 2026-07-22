# Crew kill-guard PreToolUse seatbelt

This document is the authoritative human-readable contract for the crew kill-guard.
`bin/fm-kill-command-policy.mjs` is the single decision owner.
`bin/fm-kill-pretool-check.sh` is the stable harness transport and output renderer.
`bin/fm-spawn.sh` installs the guard as a worktree-resident hook; `bin/fm-brief.sh`'s cleanup rule is the instruction-layer companion.

It is the fourth member of the family of PreToolUse seatbelts sharing the same cross-harness hook machinery: the watcher-arm seatbelt (`docs/arm-pretool-check.md`), the cd-guard (`docs/cd-guard.md`), and the Claude continuity gate (`docs/watcher-continuity.md`).
Unlike those three, it guards CREW sessions inside task worktrees, not the primary firstmate session.

## The incident

On 22/07/2026 (backlog `fm-crew-cleanup-broad-kill`) a no-mistakes test-step agent, cleaning up the dev server it had started inside its task worktree, ran `pkill -f 'concurrently.*dev'`.
The pattern matched by command line across the whole machine and killed the captain's PRE-EXISTING `npm run dev` in the primary checkout of a different project (API :3001, web :5173) - a process entirely outside the task worktree.
This is the same hazard class firstmate already guards for the watcher (never `pkill -f` by name); the crew side had no equivalent guard.

## Purpose and boundary

A crew agent tearing down its own dev servers must select victims by identity, not by name pattern: a recorded PID, or a pattern that references the task worktree's absolute path (a process rooted elsewhere does not carry that path on its command line).
The guard denies a broad name-pattern kill before it runs; everything PID-scoped or worktree-scoped stays allowed.

This guard is not a sandbox.
It classifies shell command positions only; it never evaluates, expands, sources, or runs any byte of the submitted command.
Its threat model is agent mistakes - a habitual `pkill -f <dev-server-name>` cleanup - not a deliberately obfuscated bypass.

## Placement reasoning

The incident agent was not the crewmate itself but a sub-agent the no-mistakes pipeline launched inside the same worktree.
Guidance a sub-agent never reads is not a fix, so the enforcement layer had to be one that reaches every agent whose working directory is the task worktree:

1. **Worktree-resident harness hook (the operative layer).**
   `bin/fm-spawn.sh` already writes gitignored worktree hook files for the turn-end signal; the same trust-free surfaces now also arm the kill-guard.
   A hook that lives in the worktree fires for ANY session of that harness whose cwd is inside the worktree - the crewmate and the pipeline's step agents alike - which is exactly the incident class (verified live below).
2. **Brief cleanup rule (the instruction layer, all harnesses).**
   `bin/fm-brief.sh` ship and scout scaffolds carry a rule: record dev-server PIDs and tear down by PID, never a bare name-pattern kill; pattern kills must reference the worktree's absolute path.
   This reaches every crewmate on every harness, including the two without a trust-free worktree hook surface.
3. **A helper script was considered and rejected.**
   The safe forms the deny reason recommends (`kill "$(cat .fm-dev.pid)"`, `pkill -f '<worktree>/...'`) are one-liners; a wrapper script would add surface without adding safety, and a sub-agent that ignores guidance would ignore the wrapper too.
4. **Candidate upstream no-mistakes report.**
   The pipeline's own step agents run on whatever harness no-mistakes selects; a step agent on a harness without a worktree hook surface is out of firstmate's reach.
   Teaching no-mistakes itself to scope test-step cleanup kills is noted as a candidate upstream report in the shipping PR, not changed from here.

## Coverage

| Harness | Worktree hook surface | Kill-guard |
| --- | --- | --- |
| claude | `<worktree>/.claude/settings.local.json` PreToolUse Bash hook (loads with no trust dialog, verified live) | Installed by `fm-spawn` |
| opencode | `<worktree>/.opencode/plugins/fm-kill-guard.js` `tool.execute.before` (same verified mechanism as the primary cd plugin) | Installed by `fm-spawn` |
| pi | the per-task extension `state/<id>.pi-ext.ts` gains a `tool_call` handler (extension already loads via explicit `-e`, outside pi's trust gate) | Installed by `fm-spawn` |
| codex | none without trust: a worktree `.codex/hooks.json` loads only behind codex's hook-trust gate, and a blanket `--dangerously-bypass-hook-trust` on crew launches would also silently trust hooks the PROJECT repo ships - a worse trade | Brief rule only |
| grok | none without trust: project hooks need folder hook-trust, and a GLOBAL grok PreToolUse deny hook would fire in every grok session on the machine - too much blast radius for a crew-scoped guard | Brief rule only |

The hook files are written to git's `info/exclude` view exactly like the turn-end hooks, so they never dirty teardown's check or leak into a commit.
Secondmate spawns get no kill-guard hook (they are firstmate homes, not project worktrees); their child crew spawns get it like any other.

## Block vs allow

The discriminator is victim selection: by machine-wide name pattern (blocked) versus by PID or worktree-scoped pattern (allowed).

The guard **blocks**, with reason code `broad-kill`:

- An executed `pkill` or `killall` whose arguments never reference the worktree path: `pkill -f 'concurrently.*dev'` (the incident command), `killall node`, `pkill -u "$USER"`, `sudo pkill -f dev`, `command pkill -f dev`, and quote-split spellings such as `p"kill" -f dev`. Running the name-kill through `xargs` changes nothing - the check keys on the utility word xargs executes (skipping xargs's own options, so `echo dev | xargs pkill -f` and `echo dev | xargs -I{} pkill -f {}` are denied unless the worktree path appears in the xargs arguments or the pipe source), which is what keeps xargs-fed data mentions allowed.
- An executed `kill` consuming pattern-matched PIDs: `kill $(pgrep -f vite)`, the assignment-tainted `PIDS=$(pgrep -f dev); kill $PIDS`, and the pipeline `pgrep -f dev | xargs kill` - including group-wrapped pgrep stages such as `(pgrep -f dev) | xargs kill` and `{ pgrep -f dev; } | xargs kill`.
- A literal nested payload doing either: `bash -c 'pkill -f dev'`, `eval "pkill -f dev"`, `(pkill -f dev)`, and a broad kill anywhere in a command list such as `cd apps && pkill -f dev`.

The guard **blocks**, with reason code `unclassifiable-kill`, unsupported grammar (a loop, `case`, `if`, or other construct the classifier does not model, or an unrecognized xargs option that hides which word xargs would execute) whose raw bytes carry `pkill`/`killall`, or both `kill` and `pgrep`.
This mirrors the watcher-arm seatbelt's fail-closed backstop: when the classifier cannot prove which command position the kill occupies, it refuses rather than allowing, and the reason tells the agent to run the kill as a plain single command.

The guard **allows** everything else, including the legitimate teardown shapes its own deny reason recommends:

- Kill by PID: `kill 12345`, `kill -9 $SERVER_PID`, `kill "$(cat .fm-dev.pid)"`, `kill %1`, `PIDS=$(cat .fm-dev.pid); kill $PIDS`.
- Worktree-scoped patterns: `pkill -f '<worktree>/dev-server'`, `kill $(pgrep -f '<worktree>/vite')`, `pgrep -f '<worktree>' | xargs kill`, `echo '<worktree>/dev' | xargs pkill -f`, and the byte-visible cwd forms `pkill -f "$PWD/..."` and `pkill -f "$(pwd)/..."` (crew rules pin the shell inside the worktree; the classifier matches bytes, never expands).
- Read-only process inspection: a standalone `pgrep`, `pgrep -fl dev || true`.
- Every data mention: `echo "pkill -f dev"`, `git commit -m "add pkill guard"`, `grep -rn pkill bin/`, `printf '%s\n' 'killall node'`, kill verbs fed as data to another xargs-executed utility (`git ls-files | xargs grep -n pkill`, `ls | xargs echo killall`), and words that merely contain the bytes (`.agents/skills`).
- Starting servers and recording PIDs: `npm run dev & echo $! > .fm-dev.pid`.

### Accepted non-goals

Consistent with the agent-mistake threat model:

- A dynamic nested payload (`bash -c "$CMD"`) and a kill verb reconstructed by command substitution are not chased; deliberate obfuscation is out of scope.
- A heredoc fed to a shell's stdin (`bash <<EOF` with a kill inside) is not analyzed; heredoc bodies are data everywhere else, and this exotic execution shape is not a plausible cleanup mistake.
- Kills scoped to other legitimately-owned locations (for example a task temp dir) are denied when they carry no worktree reference; kill-by-recorded-PID always remains available and is the recommended shape anyway.

## Stable reason codes

| Code | Meaning |
| --- | --- |
| `broad-kill` | A name-pattern process kill (or kill consuming pattern-matched PIDs) with no worktree scoping. |
| `unclassifiable-kill` | Unsupported or malformed syntax carries a name-pattern kill verb and cannot be safely classified. |

The `broad-kill` reason names the concrete worktree path the pattern should reference, so the denied agent can self-correct in one step.
Reason codes are the stable contract for tests and adapters; prose may improve without changing adapter behavior.

## Transport and fail-open behavior

`bin/fm-kill-pretool-check.sh` supports the same five entry shapes as its siblings:

- Claude sends stdin JSON at `.tool_input.command` and adds `--claude` to preserve Claude's stderr-only deny requirement.
- Codex would send stdin JSON at `.tool_input.command` (accepted for shape parity; codex crew currently has no hook install, see Coverage).
- Grok would send stdin JSON at `.toolInput.command` (same parity note).
- OpenCode and Pi send the exact command string through `--command <exact string>`.

`--worktree <dir>` names the task worktree identity and is the guard's scope: `fm-spawn` embeds it when writing each hook, and the transport fails open without it.
There is no checkout-shape probe - installation location is the scope, which is what lets the guard fire for any agent working in the worktree while never existing anywhere else.

Processing order is cheapest-first: a strict-superset prefilter, then the Node policy owner.
The prefilter strips ordinary quotes, backslashes, and newlines before fast-allowing any command that carries no `kill` substring and no quoting-decoder marker (`$'` ANSI-C or `$"` locale); the marker set is coupled to the classifier's decoder set in `bin/fm-arm-command-policy.mjs` exactly as documented for the sibling guards.
Every deniable command - `pkill`, `killall`, and kill-consuming-`pgrep` - carries the `kill` byte sequence, so most commands never pay for the Node process.

Empty stdin, unparseable JSON, missing `jq` on the stdin path, a missing or empty `--worktree`, missing Node, a missing policy owner, or an invalid policy response all fail open with exit 0 and no output.
A broken hook must never deny every shell tool call.

## Output contract

Identical in shape to `docs/arm-pretool-check.md`:

- Allow returns exit 0 with both streams empty.
- Deny returns exit 2 and writes `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[code] reason"}` to stderr.
- Default deny mode also writes `{"decision":"deny","reason":"[code] reason"}` to stdout for Grok-shaped consumers.
- `--claude` suppresses stdout completely because Claude ignores a PreToolUse deny when stdout is nonempty.
- OpenCode throws only when the checker exits 2; Pi returns `{block: true}` only when the checker exits 2.

## Shared classifier ownership

`bin/fm-kill-command-policy.mjs` imports the shell tokenizer and command-position analysis (`Lexer`, `splitProgram`, `commandPosition`) from `bin/fm-arm-command-policy.mjs`, the sole owner of firstmate's shell classification.
It adds only the kill-specific decision: name-kill detection, worktree scoping, pgrep-consumption tracking (substitution, assignment taint, and pipeline-into-xargs), and the unsupported-grammar backstop.
`bin/fm-arm-command-policy.mjs` runs its own CLI only when invoked directly, never on import, so the policies stay independent CLIs over one parser.

## Live validation record, 2026-07-22

Validation ran in a scratch worktree-shaped directory under the task sandbox, with the real checker and policy from this change and a victim process started OUTSIDE the scratch worktree whose command line matched the incident-shaped pattern (`kg-live-marker-concurrently.*dev`).
No live fleet state, watcher, or real project checkout was involved; the victim was a sandboxed `sleep` owned by the test shell.

- **Claude Code 2.1.217** - headless `claude -p "$PROMPT" --dangerously-skip-permissions --output-format text`, cwd inside the scratch worktree, with `<worktree>/.claude/settings.local.json` carrying only the kill-guard PreToolUse hook (the exact shape `fm-spawn` writes).
  The worktree settings loaded with no trust dialog - the same mechanism a no-mistakes step agent hits when launched with cwd in the worktree.
  Claude ran the control `touch` (sentinel created), was blocked on `pkill -f 'kg-live-marker-concurrently.*dev'` and reported the hook's reason verbatim, and ran the PID-based `kill "$(cat .fm-dev.pid)"` fallback.
  The outside victim process remained alive.

OpenCode's `tool.execute.before` throw-to-block and Pi's `tool_call` `{block: true}` mechanisms are not re-validated here: the generated adapters are byte-level siblings of `.opencode/plugins/fm-primary-cd-check.js` and `.pi/extensions/fm-primary-turnend-guard.ts`, whose blocking behavior was verified live on 2026-07-09 (OpenCode 1.17.15, pi 0.80.5; `docs/arm-pretool-check.md`), and the checker's OpenCode/Pi-shaped CLI entries are covered by the automated matrix.

## Automated validation

`tests/fm-kill-pretool-check.test.sh` owns the acceptance matrix.
Every block and allow case runs through Codex-shaped stdin, Claude-shaped stdin, Grok-shaped stdin, OpenCode-shaped CLI, and Pi-shaped CLI entry forms.
The suite's end-to-end test is the incident regression: it starts a sandboxed victim process outside a fixture worktree and the crew's own recorded-PID process inside it, proves the broad pattern actually matches the outside victim, proves the guard denies the incident-shaped command, then executes the allowed worktree-scoped teardown and asserts the own process died while the outside victim survived.
It also proves the fail-open transport behavior, the prefilter fast path, the policy CLI contract, the `fm-spawn` worktree-hook templates (including JSON validity of the rendered claude settings), the documented codex/grok gaps, and the brief cleanup rule in both scaffolds.

Run:

```sh
bash -n bin/fm-kill-pretool-check.sh
shellcheck bin/fm-kill-pretool-check.sh tests/fm-kill-pretool-check.test.sh
node --check bin/fm-kill-command-policy.mjs
node --check bin/fm-arm-command-policy.mjs
tests/fm-kill-pretool-check.test.sh
```
