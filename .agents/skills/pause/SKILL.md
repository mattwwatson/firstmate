---
name: pause
description: >-
  Quiesce the whole fleet so the captain can safely close the laptop or drop off the network, when they invoke /pause, say they are pausing, say they are about to close the lid or lose connectivity, or when a pause is already recorded but has not completed.
  Every live worker finishes its step, commits its work in progress, and stops any validation run outright rather than leaving it monitoring, and the fleet is reported safe to close only once every worker has actually confirmed and been independently verified.
user-invocable: true
metadata:
  internal: true
---

# pause

The captain is about to close the laptop, or otherwise lose the network.
Local workers survive a sleep; what does not survive is anything mid-flight over the network when the lid closes - a push, a forge call, and above all a validation run sitting in its monitoring phase.
`/pause` brings all of that to a stop first.

## What to run

`bin/fm-fleet-pause.sh` owns the whole procedure: the durable record, the instruction to each worker, and the verification.
Read its `--help` before first use; it is the authority on flags and mechanics.

- `bin/fm-fleet-pause.sh` - open the pause, ask every live worker to quiesce, verify until they confirm.
- `bin/fm-fleet-pause.sh check` - verify again without asking anyone. Use this after a firstmate restart mid-pause, or after fixing one worker by hand.
- `bin/fm-fleet-pause.sh status` - read the record; changes nothing.

Exit 0 is the only result that means safe to close.
Exit 3 means one or more workers did not confirm, and each is named with its reason.

## The one rule that matters

**Never tell the captain the fleet is safe on the strength of having asked.**
Report safe to close only on exit 0, and only in the same turn you got it.
When the command exits 3, say plainly that the fleet is not safe to close yet, name each worker that did not confirm in the captain's own nouns, and say what is holding it.

Typical holds and what they mean to the captain:

- a worker that has not confirmed - it is still finishing its step, or it has stopped responding.
- a validation run that would not stop - that run is still talking to the network and is exactly what must not be mid-flight.
- uncommitted work - a worker still has changes that are not saved to its branch.
- a second mate whose own fleet is not quiesced - its crew is still running.
- a worker whose liveness could not be established - its window did not answer and nothing proves it is gone, so its validation run was deliberately left alone rather than cancelled on a bad read.
- a worker that stopped but could not quiesce - it obeyed the order and is waiting, and it reports its own reason, most often a worktree mid-rebase or a validation run that would not stop. It still needs dealing with before the fleet is safe, and `/resume` will still release it when the time comes.

For anything still holding, either give it more time and run `check` again, or deal with the specific worker through the normal recovery path, then run `check`.
Only report safe to close when `check` finally exits 0.

## While the fleet is paused

Keep supervision live.
A paused worker is deliberately stopped, not stuck, so supervision stays quiet about it on its own - but only for workers that actually confirmed.
One that never confirmed keeps its normal treatment and will still surface, which is what you want.

Do not arm anything extra, do not start new work, and do not steer a paused worker back to work by hand.
The pause survives a firstmate restart: session start prints it, and the next step is `/resume`, never an ad-hoc restart.

## Reporting it

Give the captain one short answer: whether it is safe to close, and if not, which work is still finishing and why.
Do not relay the command's per-task lines verbatim.

Say "safe to close" only when it is.
