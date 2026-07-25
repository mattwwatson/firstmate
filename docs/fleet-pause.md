# Fleet pause

Reference record for the captain-invoked fleet pause: the incident it exists for, what each readiness check actually proves, and the design decisions that are not obvious from the code.

Mechanics live in the scripts' own headers and `--help` (`bin/fm-fleet-pause.sh`, `bin/fm-fleet-resume.sh`, `bin/fm-quiesce.sh`, `bin/fm-nm-abort.sh`, `bin/fm-quiesce-lib.sh`).
The operating procedure lives in the `/pause` and `/resume` skills.
Nothing here restates either.

## The incident

24/07/2026. The captain closed the laptop with the fleet running.

Workers themselves came back fine: they are local processes that suspend and resume with the machine.
What did not come back was everything mid-flight over the network at the moment the lid closed.
The sleep wedged the shared no-mistakes daemon and left seven orphaned monitor runs behind it.

The orphans have a specific cause, and it is not the sleep.
A no-mistakes run does not end when its pull request goes green: it stays in its "monitoring until merged or closed" phase, holding the shared daemon, until the pull request lands or the run is aborted.
Nothing in firstmate aborted it.
So every task torn down before its pull request merged left a run monitoring a worktree that no longer existed, and those accumulated silently until the daemon was wedged and the whole fleet stalled.
That bug was filed separately as `fm-teardown-orphans-nomistakes-run` and is fixed by the same shared abort the pause uses, `bin/fm-nm-abort.sh`.

The failure was silent for a second reason worth recording: the shared daemon captures its environment from a non-interactive login shell, which never sources `.zshrc`, so a daemon that restarts without its forge token fails with `bitbucket client is not configured` and nothing says so until something needs the forge.
A daemon problem after a sleep therefore does not announce itself.

## Design decisions

**Full quiesce, not a soft freeze.**
"Do not start new runs" was considered and rejected: it leaves in place exactly the dangling monitor runs that caused the incident.
Each worker instead finishes its step, commits its work in progress, and stops its run outright.

**Built on the existing declared-pause primitive, not beside it.**
A quiesced worker declares itself with the ordinary `paused:` verb that supervision already understands, plus one token naming the pause instance it answers (`bin/fm-classify-lib.sh`'s `status_quiesce_epoch`).
There is no second pause vocabulary and no second set of supervision rules.
The fleet-wide layer adds only the durable record, the confirmation ledger, and per-task suppression of the two sightings the pause cadence would otherwise still produce.

**Suppression is per task and evidence-based.**
It applies only while a valid pause record exists and that task's own current status confirms that exact instance.
A worker that never confirmed keeps its normal supervision and still surfaces, which is the entire point of asking.
Any later status event retires the token and restores normal treatment at once, so a paused worker that reports `blocked:` or `done:` is never swallowed.

**The all-workers-paused case is the one that must not break.**
With the lid shut there is nobody to re-arm a supervision cycle, and every surfaced wake ends one.
A fleet where every task is correctly paused therefore has to produce no wakes at all, or `/resume` has nothing listening when the captain comes back.
That is why the confirmation append itself is absorbed, not just the later re-surface.

**A dead endpoint is verified, never skipped.**
A task whose worker is already gone cannot be asked anything, but it can still be holding a monitoring run - the orphan above.
Those are verified anyway, and because no live worker owns the run, firstmate reaps it.
A live worker's run is only checked, never aborted from outside: that run belongs to the worker driving it.

**Gone has to be proven, because reaping is an action.**
An endpoint probe that fails cannot tell a pane that is closed from one that merely could not be read, and the reap cancels a pipeline.
So a single failed probe never licenses it: the worker counts as gone only on the backend's own agent probe reading `dead`, or on the endpoint being absent across two consecutive verify passes a poll interval apart.
Anything short of that is reported as a worker whose liveness could not be established, which holds the fleet unsafe with the run untouched.
This is the same rule `bin/fm-backend.sh`'s `fm_backend_agent_alive` already records for the secondmate-liveness sweep, and for the same reason: a momentary read glitch must never be mistaken for a death.

**A worker that cannot be released keeps the pause record, unless it is confidently gone.**
The mirror of a false safe-to-close is a false "everything is back".
If a worker that quiesced for this pause cannot be reached when `/resume` runs, it is still sitting on its `paused:` line, and the record is the only thing that says so - clearing it would strand that worker with nothing left to wake it.
So the resume reports exit 4, names the worker, and leaves the record in place for a second attempt.
The one exception is a worker whose window is confidently gone by the same reading the pause uses: there is nothing left to release, and holding the record for it would leave the home under an open pause that no re-run could ever close.

**The resume releases only workers that are still paused, and is therefore idempotent.**
The confirmation token is what says a worker is stopped and waiting to be told to carry on, and any later status event retires it - including the `working:` line a released worker reports.
So a second `/resume` after a partial one cannot type a second instruction into a worker that is already back at work and mid-turn, and a worker that never paused is never steered at all.
Both cases are named in the output rather than skipped silently, so "nothing happened for this task" is always visible and explained.

**Out of scope, deliberately.**
Automatic lid-close detection (a system sleep/wake hook such as `sleepwatcher`) as an involuntary-drop safety net is not built here.
The deliberate path lands and gets proven first.

## Verification evidence

All commands run 25/07/2026 on macOS 15 (Darwin 24.6.0), `gh` 2.x, `no-mistakes` v1.41.2 (867d64d).

**`gh auth status` really does contact the host, so it fails when the network is gone.**
This is what makes it a reachability check and not just a "is a token stored" check.
Simulated by pointing the proxy at a dead local port:

```
$ HTTPS_PROXY=http://127.0.0.1:1 HTTP_PROXY=http://127.0.0.1:1 gh auth status
github.com
  X Failed to log in to github.com account mattwwatson (keyring)
  - Active account: true
  - The token in keyring is invalid.
$ echo $?
1
```

With the network present the same command exits 0 in ~0.4s, consistent with a real round trip.
`bin/fm-bootstrap.sh` gates dispatch on this same command, so the resume check and the session-start check cannot drift.

**`no-mistakes daemon status` is a read-only liveness command.**

```
$ no-mistakes daemon status
  ● daemon running (pid 27721)
$ echo $?
0
```

It is run under a hard time bound, and a timeout FAILS the check.
That is the point rather than an edge case: a daemon wedged by a sleep does not refuse requests, it stops answering them, so a check that waited patiently would pass exactly when it must not.
Nothing in the pause or resume path starts, stops, or restarts that daemon - one instance serves every home, so restarting it would kill other homes' in-flight runs.

**`no-mistakes axi abort --run <id>` works from outside the run's worktree.**
From `no-mistakes axi abort --help` on v1.41.2:

> Pass `--run <id>` to cancel a specific run by its id from anywhere - including outside its worktree - so an orphaned CI monitor (e.g. after a worktree was torn down) can be reaped deterministically.

This is what lets teardown reap a run whose worktree is about to disappear.

**A repository with no no-mistakes gate answers by declining, and that is not a failure.**

```
$ cd <worktree with no gate> && no-mistakes axi status
error: repo not initialized (run 'no-mistakes init' first)
$ echo $?
1
```

`bin/fm-nm-abort.sh` separates this from a timeout deliberately: a declining answer is a legitimate no-run state and must never refuse a teardown, while silence past the bound is ambiguous and does.
Reading the two the same way made teardown refuse every `local-only` project, which is how the distinction was found.
