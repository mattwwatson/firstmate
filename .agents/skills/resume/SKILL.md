---
name: resume
description: >-
  Lift a captain-invoked fleet pause and put every paused worker back to work, when the captain invokes /resume, says they are back, or says the network is back and the fleet should carry on.
  It proves the forge is reachable and authenticated and the shared validation daemon is answering BEFORE clearing the pause or releasing anyone, and releases nobody when a check fails.
user-invocable: true
metadata:
  internal: true
---

# resume

The captain is back and believes the network is genuinely back with it.
`/resume` has to earn that belief rather than take it, because resuming into a half-present network recreates the failure the pause existed to prevent.

## What to run

`bin/fm-fleet-resume.sh` owns the whole procedure: the readiness checks, the order of the lift, and the instruction to each worker.
Read its `--help` before first use; it is the authority on what each check proves.

- `bin/fm-fleet-resume.sh` - check readiness, then lift the pause and release every worker.
- `bin/fm-fleet-resume.sh check` - run the readiness checks only and report. Changes nothing, so it is the right answer to "is the network back yet?".

Exit 0 means the pause is lifted and every worker was released.
Exit 3 means a check failed: **nothing was released and the fleet is still paused.**
Exit 4 means a worker was not released, and that worker needs a look.
If it had already quiesced for this pause, it is still sitting paused and the pause record is deliberately kept, so the fleet is not fully back: deal with that worker, then run `/resume` again to finish the lift.

## The one rule that matters

**A failed check is a stop, not a warning.**
On exit 3, tell the captain the fleet is still paused and name the concrete thing that is missing - the forge is unreachable, the credential is not valid, the validation service is not answering - and do not release any worker by hand to work around it.
Wait until the network is genuinely back, then run it again.

If the validation service is the thing that is down, report it.
Do not restart it: one instance serves every fleet, so restarting it would kill other work that is mid-flight.

## After a successful resume

Resume the normal supervision cycle for this session's primary harness, exactly as at session start.
Then pick the fleet back up: workers carry on where they left off, so re-read the fleet before assuming anything about where each one got to.

On exit 4, handle the named worker through the normal recovery path before treating the fleet as fully back, and run `/resume` again if the command said the pause record was kept.

## Reporting it

One short answer: whether the fleet is running again, or what is still down and that the fleet stayed paused because of it.
Do not relay the check output verbatim.
