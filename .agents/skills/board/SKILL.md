---
name: board
description: >-
  Rebuild the captain's terminal fleet board at data/board.md.
  Load whenever the board must be rebuilt: work becomes ready for the captain, work stops being ready, work is dispatched, the queue changes, a new decision for the captain surfaces, or a stretch of consecutive review-gate decisions ends.
  Also invocable by the captain as /board for an on-demand rebuild.
user-invocable: true
metadata:
  internal: true
---

# The fleet board

This skill is the single owner of the board's section contract, its naming rule, and when it is rebuilt.
`bin/fm-board.sh` owns the mechanics - the scroll padding, the generation stamp, and the geometry check - and its `--help` is authoritative for commands and flags.
Nothing here restates those mechanics, and nothing there decides what goes on the board.

## What the board is

`data/board.md` is the captain's at-a-glance view of the fleet, watched in a terminal with `tail -f`.
It is regenerated in full every time, never appended to, and the blank lines above it scroll the previous version out of the tail window.
It is not a log, and no crewmate, tool, or other agent reads it.

Because it is the surface the captain actually watches, a stale board is worse than a quiet one: the stamp in the header is read every time, and if the captain has to ask why the board has not moved, it was already too late.

## Rebuild triggers

Rebuild the board when something on it materially changes:

- work becomes ready for the captain - a pull request reaches them for review, merge, or a hands-on test;
- work stops being ready - a pull request goes back into validation, becomes blocked, or is withdrawn;
- work is dispatched to a worker;
- the queue changes;
- a new decision for the captain surfaces;
- and at the END of any stretch of consecutive review-gate decisions.

That last one is the trigger that gets missed.
Gate handling is absorbing and produces no natural pause, so the board rots through exactly the stretch in which most of what is on it changes.
Rebuild once when the stretch ends, before doing anything else.

Reaching ready and leaving ready are equally board-worthy.
A board that still shows a pull request as waiting on the captain after it has gone back into validation sends them to review something that is not there.

## Section contract

The sections below are the whole board, in this order.
Keep the emoji headings; the captain likes them and uses them to find their place.

1. **The header line.**
   `bin/fm-board.sh` renders it, carrying the date and the generation time in 12-hour am/pm form.
   It tells the captain at a glance how stale the tail they are watching has become, and it is theirs by explicit request.
2. **Waiting on the captain.**
   What needs the captain's review, their merge, or their hands-on test.
   Give every pull request its full `https://...` URL, never a bare `#number`.
   Fold the day's merges into a compact line here rather than giving them a section of their own.
3. **Underway.**
   What the workers are building right now, and what each one is actually doing.
4. **Queued or coming next**, grouped BY REPO.
   Only repos actually being worked appear.
   This is deliberately not every roadmap - it is what is coming next on the projects in play.
5. **Optional extra sections**, where they earn their place.
   The upstream pull-request watch is the current example.
   An optional section that has nothing to say is dropped, not left empty.
6. **Decisions blocked on the captain, LAST**, pinned at the bottom under a `🔴` heading so they stand out.

There is **no lessons or retrospective section**, ever.
Operational learning goes to `data/learnings.md`; it never appears on the board.
Long analysis belongs in the backlog item, with a pointer line at most on the board.

## Naming work

Name every item so it is unambiguous which repo it belongs to.

For a project whose backlog lives in Jira, use the Jira key plus the repo slug: `SLS-53 - sls-scheduling`.
Firstmate's own work has no Jira key, so it uses its task name plus `firstmate`.

Firstmate ruled the firstmate-side half of this; the captain has been told and may correct it.

## Building it

1. Write the sections to a scratch file, in the order above, with no padding and no header line - `bin/fm-board.sh` adds both.
2. Render it with `bin/fm-board.sh render --content <file>`.
3. If the render is refused, the board did not fit.
   Trim the content and render again rather than forcing it, because a line wider than the captain's terminal wraps and corrupts every line below it.

Fit is a real constraint on what goes on the board, not an afterthought.
When there is more to say than fits, the board carries the outcome and a pointer, and the detail lives in the backlog item.

## Geometry

The captain's terminal size lives in `config/board-geometry`, which is local and gitignored so one captain's personal geometry never ships to another firstmate user.
`docs/configuration.md` owns the schema and the default.

If `bin/fm-board.sh geometry` reports `source=default`, this home has no geometry recorded.
Ask the captain once for their terminal's rows and columns, write them to `config/board-geometry`, and do not ask again.
Until they answer, the default renders a smaller board that is correct everywhere rather than a wide one that might wrap.
