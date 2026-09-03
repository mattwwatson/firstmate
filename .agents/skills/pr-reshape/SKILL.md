---
name: pr-reshape
description: >-
  Reshape a pull request's description for the people who review it, keeping the short reviewer-facing sections and moving the build-history detail to a comment.
  Load when the captain invokes /pr-reshape or asks for a pull request's description to be shortened, trimmed, reshaped, or made readable for reviewers, with or without a URL.
  Also load when a reviewer complains that a pull request is a wall of text.
user-invocable: true
metadata:
  internal: true
---

# Reshaping a pull request description

This skill is the single owner of the judgement in a reshape: which pull request, and what the replacement opening says.
`bin/fm-pr-reshape.sh` owns every mechanic - the split, the two writes, the private copy, the idempotency, the read-back check - and its `--help` is authoritative for commands, flags, and exit codes.
Nothing here restates those mechanics, and nothing there decides what the opening says.

## Why this exists, in one measurement

A no-mistakes pull request's description ends up dominated by the record of *building* the change, sitting in the field a reviewer opens to learn what the change *is*.
On the pull request that prompted this, the description was 39,393 characters and the round-by-round findings log was 23,832 of them.
`docs/pr-description-reshape.md` holds that measurement and the forge behaviour behind every design decision, including why the detail goes to a comment rather than a collapsible section.

**Read that document before changing anything here or in the script.**

## When a reshape is the right answer

Reshape when a pull request is open or recently opened, its description carries a `## Testing` or `## Pipeline` section, and a human is going to read it.
Do not reshape a description a human wrote by hand: the mechanism is aimed at generated build history, and a hand-written body has no such section to move.
The script refuses that case on its own, but choosing not to run it is better than relying on the refusal.

**A reshape is worth doing after the work is finished, not while it is still moving.**
A pipeline run that reaches its pull-request step rewrites the description wholesale, so a reshape applied while further runs are expected will be undone by the next one.
That is not a failure to work around - it is why this is an explicit action the captain takes rather than something that happens automatically at every pull request.
Re-running the skill after such a rewrite is the intended remedy, and it neither re-trims a trimmed body nor posts the same detail twice.

## The one thing only an agent can do: the opening

The script cannot summarise, so it never tries.
Every run supplies an opening file containing a one-line summary and a short `## Intent` of about four sentences.
There are two sources for it, and they are not equally authoritative.

**Prefer the author's own words.** A ship crewmate on a pull-request-producing task writes its own opening at PR-ready, to the path `bin/fm-pr-lib.sh`'s `fm_pr_opening_path` names (`state/<id>-pr-opening.md`).
When that file exists for the task behind this pull request, use it as the opening unchanged.
It was written off first-hand knowledge of the work by the worker that did it, which no later reading of the diff can match.

**Otherwise derive a best attempt, and say that it is one.** With no such file - a pull request opened before this existed, one from another home, or one whose task state is gone - read the published description's existing `## Intent`, `## What Changed` and `## Risk Assessment`, and the diff, and write the opening from those.
Summarising finished work from its own description and diff is a job an agent does well.
It is still not the author speaking, so when reporting the outcome say the summary was derived from the pull request rather than presenting it as the author's.
Never invent intent that the description and the diff do not support; if they do not support a confident four sentences, write fewer and say so.

Write the opening to a file under the scratch area, never inline on a command line, and keep it inside the shape the reshaped description expects: a single summary line, a blank line, `## Intent`, then the sentences.

## Procedure

1. Resolve the pull request. Take a URL the captain gave; otherwise find the pull request from the task's durable record or ask one concise question. Never guess between two candidates.
2. Read the current description. This is also how you learn which headings it actually has, which is a question to answer per pull request rather than assumed from a template.
3. Get the opening: the crewmate's file if it exists, else derived as above.
4. Run the script with `--dry-run --keep-dir <dir>` first and read the planned description and comment. This writes nothing, and it is the cheapest possible check that the opening reads well and the split landed where you expected.
5. Run it for real. Relay the outcome.
6. If the script reports anything other than success, report the concrete reason and stop. Every refusal it makes leaves the pull request unchanged, so a refusal is never something to work around by hand.

## Reporting it to the captain

Follow `AGENTS.md` section 9: outcomes, not mechanics.
Give the pull request's full `https://...` URL, what the description now says, and where the detail went.
Say whether the summary is the author's own or your derived best attempt - that distinction is the captain's to know, not an internal detail.
Do not mention the private saved copy, the marker, exit codes, or the read-back check unless something failed and the captain needs the reason to act.

A reshape changes an outward-facing surface that other people read, so it is a captain-authorised action every time.
Standing autonomy grants for merges and review findings do not cover it, and neither does having reshaped a different pull request earlier.

## What is never at risk

The script guarantees these, and they are the reason a reshape is safe to run on a published pull request:
the complete original description is saved privately before the first write, every time;
the moved sections are posted as a comment before the description is trimmed, so a failed post leaves the description whole;
and a second run declines instead of compounding.
`tests/fm-pr-reshape.test.sh` pins each of them.

If the captain asks for the pre-reshape description back, it is in the private per-pull-request directory `fm_pr_reshape_dir` names, under a timestamped file that is never overwritten.
