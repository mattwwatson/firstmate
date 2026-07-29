# Hand-off note: retiring the board section in data/captain.md

**This is a hand-off note, not shipped documentation.**
It exists because `data/captain.md` is local and gitignored, so the crewmate that moved the board rules into the `board` skill could not edit it.
Firstmate applies the replacement below to the primary home's `data/captain.md` after this lands, then deletes this file.

## Why

The board's format contract was stated in full in two places: `data/captain.md` and the practised shape of `data/board.md`.
The [`board` skill](../.agents/skills/board/SKILL.md) now owns it, with `bin/fm-board.sh` owning the mechanics and [`configuration.md`](configuration.md) owning the geometry schema.
Two copies of a format contract drift the moment either is edited, so the `data/captain.md` section becomes a pointer and keeps only what is genuinely captain-preference rather than format contract.

`data/captain.md` itself anticipated this, in the section being replaced: "When that lands, this whole section becomes a pointer to the `board` skill".

## What moves and what stays

Moving out to the `board` skill: the section list and their order, the emoji headings, the header stamp format, the identifier rule, the no-lessons rule, the rebuild triggers, and the dated drift records that justify them.
Moving out to `config/board-geometry` and `configuration.md`: the 50 rows by 150 columns geometry and the rows-plus-ten padding rule.
Staying in `data/captain.md`: weekly capacity, which is a working preference rather than a board format, and the clocking-off standing-orders behaviour.

The dated miss records of 22/07, 25/07 and 27/07/2026 are deliberately not carried into the replacement text.
Their operative content is now the skill's rebuild triggers.
If firstmate wants to keep them as evidence, they belong in `data/learnings.md` as dated fleet-local operational facts, not as a second copy of the contract.

## Replacement text

Replace the whole `## Status board and capacity (22/07/2026; format tightened 23/07/2026)` section - from its heading up to but not including `## Pre-build design validation (23/07/2026)` - with exactly this:

```markdown
## Status board and capacity (22/07/2026; board contract moved to the `board` skill 29/07/2026)

The captain watches a live terminal board at `data/board.md` with `tail -f`, and wants it
current on every change. The `board` skill owns that contract in full - the sections and their
order, the header stamp, how work is named, and when the board is rebuilt - and `bin/fm-board.sh`
owns the padding, the stamp and the geometry check. His terminal geometry lives in
`config/board-geometry`. Do not restate any of that here: one owner, or it drifts.

The one thing worth repeating, because it is the miss that keeps recurring: if he has to ask why
the board has not moved, it was already too late.

He is conscious of weekly capacity (was at 32% mid-session). Do not auto-dispatch queued work
into a low tank - surface capacity and let him choose. When he pauses jobs to conserve it, hold
them on his EXPLICIT word to resume, not auto-resume when others finish. `quota-axi` reports the
windows and can read Claude's (verified working 22-23/07/2026); the weekly window resets
Wednesday 6am local (confirmed live: 2026-07-22T20:00Z).

When clocking off he gives conditional standing orders ("if everything else finishes this
evening and is parked, kick off X") and expects them executed without a further ask when the
condition is met - evaluate the condition honestly (a decision-parked worker counts as parked)
and record the authority in the task before he leaves. Worked exactly as intended for the
stage-4 evening dispatch, 22/07/2026.
```

## After applying it

Write the captain's geometry to the primary home's `config/board-geometry`, which does not exist yet:

```
rows = 50
columns = 150
```

Then confirm with `bin/fm-board.sh geometry` that it reports `rows=50`, `columns=150`, `padding=60`, and the config file as its source.
