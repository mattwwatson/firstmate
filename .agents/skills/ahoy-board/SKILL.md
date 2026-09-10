---
name: ahoy-board
description: >-
  Give the captain the Ahoy session recap and rebuild the fleet board, in one command.
  Load when the captain invokes /ahoy-board or asks for the ahoy recap with the board refreshed.
user-invocable: true
metadata:
  internal: true
---

# ahoy-board

Run [`../ahoy/SKILL.md`](../ahoy/SKILL.md), then rebuild the board with [`../board/SKILL.md`](../board/SKILL.md).

Here the board gathers for itself.
Ahoy's ordinary recap branch gathers no fleet state at all, so there is no snapshot to reuse, and the board step must run `bin/fm-bearings-snapshot.sh` itself and compose from that output.

The one exception is Ahoy's Bearings fallback, which it takes when `/ahoy` is the session's first real captain message.
On that branch a fresh snapshot already exists, so compose the board from it rather than gathering a second time.

Each skill keeps its own contract, and this one restates neither.
Ahoy owns its recap interval, its captain-boundary exclusions, and its fallback condition.
The board skill owns the board's section contract, its naming rule, its rebuild triggers, and its geometry.
