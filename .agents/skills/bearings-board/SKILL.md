---
name: bearings-board
description: >-
  Give the captain the Bearings digest and rebuild the fleet board from the same snapshot, in one command.
  Load when the captain invokes /bearings-board or asks for bearings with the board refreshed.
user-invocable: true
metadata:
  internal: true
---

# bearings-board

Run [`../bearings/SKILL.md`](../bearings/SKILL.md), then rebuild the board with [`../board/SKILL.md`](../board/SKILL.md).

Compose the board from the snapshot Bearings just gathered, not from a second gather.
The board skill has no gather step of its own, so without this instruction the board would be composed from whatever happened to be in context.

Each skill keeps its own contract, and this one restates neither.
Bearings owns its read-only boundary, its invocation modes, and its four-section chat digest.
The board skill owns the board's section contract, its naming rule, its rebuild triggers, and its geometry.

Pass Bearings any options the captain gave, such as `file` or `include PRs`, exactly as Bearings defines them.
