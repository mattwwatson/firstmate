---
name: no-mistakes-pr-summariser
description: Reshape a pull request whose description has been overrun by the record of building it - keep the short reviewer-facing sections in the description and move the build history to a comment, so the field a reviewer opens says what the change is. Use when a pull request description is a wall of text, when a reviewer complains it is unreadable, or when asked to shorten, trim, reshape, or summarise a pull request description. Works on GitHub and Bitbucket Cloud.
user-invocable: true
---

<!-- maintainers: this is the public, installer-facing skill. Keep it standalone: no private paths, no assumptions about a surrounding fleet, and nothing here that an agent in someone else's repository cannot act on. -->

# Summarising a pull request description

An automated pipeline writes its whole working record into the pull request description: every review round, every finding, every fix.
That record is worth keeping, but it ends up in the one field a reviewer opens to find out what the change *is*, and it buries the answer.

This skill moves the build history to a comment on the same pull request and leaves a short reviewer-facing description behind.
Nothing is discarded.

`bin/pr-summarise.sh` beside this file owns every mechanic - the split, the two writes, the private copy, the idempotency, the read-back check - and its `--help` is authoritative for commands, flags, and exit codes.
This file owns the one thing a script cannot do: deciding what the replacement opening says.

## Why this exists, in one measurement

On the pull request that prompted this, the description was 39,393 characters and the round-by-round findings log was 23,832 of them.
On another, a run took a 61,096-character description down to 3,034.
The detail goes to a **comment** rather than a collapsible section because Bitbucket renders neither `<details>` nor an HTML comment marker - it escapes HTML in a description and prints the markup to every reviewer as literal characters.

## What it needs

**GitHub** needs an authenticated `gh` on PATH and nothing else.
The whole GitHub path runs through `gh pr view`, `gh pr comment`, and `gh pr edit`, so whatever credential `gh` already holds is the credential used.

**Bitbucket Cloud** has no equivalent CLI, so it needs two environment values:

| Variable | What it holds |
|----------|---------------|
| `BITBUCKET_EMAIL` | the Atlassian account email the token belongs to |
| `BITBUCKET_API_TOKEN` | an Atlassian API token for that account, with the `pullrequest:write` scope |

The scope has to include write, because two of the three requests write: the detail comment and the new description.

If either value is missing the run refuses and names the one that is absent.
It never proceeds half-authenticated and never quietly falls back to an unauthenticated request, which a public repository would answer and a private one would not.

**Never type the token literally on a command line.**
Both bash and zsh record the command line in the history file verbatim, and a `VAR=value` command prefix is part of the command line, so a literal token written there is stored in plaintext.
A leading space does not save you either: recording it is the default in both shells, and suppressing it has to have been turned on beforehand - `HISTCONTROL` set to `ignorespace` or `ignoreboth` in bash, the `HIST_IGNORE_SPACE` option in zsh.

Obtain the value without putting it on the command line at all: by command substitution from a file only you can read, from a secret manager, or by reading it into the environment at a prompt.
Done that way the history file holds the command text and the token appears in it zero times.

```sh
BITBUCKET_EMAIL='you@example.com' \
BITBUCKET_API_TOKEN="$(cat ~/.config/bitbucket-api-token)" \
  <this skill's directory>/bin/pr-summarise.sh <pr-url> --opening-file <opening.md>
```

Give that file mode 0600.
Writing the two values as a command prefix rather than exporting them is still worth doing, because it scopes them to this one process instead of leaving them in the shell environment for everything else that shell runs - but prefixing is not what keeps the token out of history, and on its own it would not.
The token is passed to `curl` through a config on standard input, so it never appears in the process list.

`python3` is needed for the Bitbucket path only, to read and encode JSON.

## When a reshape is the right answer

Reshape when a pull request is open or recently opened, its description carries a `## Testing` or `## Pipeline` section, and a human is going to read it.

Do not reshape a description a human wrote by hand.
The mechanism is aimed at generated build history, and a hand-written body has no such section to move.
The script refuses that case on its own, but choosing not to run it is better than relying on the refusal.

**Do it when the work is finished, not while it is still moving.**
A pipeline run that reaches its pull-request step rewrites the description wholesale, so a reshape applied while further runs are expected will be undone by the next one.
Re-running after such a rewrite is the intended remedy: it neither re-trims a trimmed body nor posts the same detail twice.

**One thing to know on Bitbucket.**
The write sends the new description and no other field.
Whether that leaves an assigned reviewer list untouched has not been proven against a live pull request, so on a repository where reviewers are assigned, check them afterwards.
It is unproven rather than known to go wrong.

## The one thing only an agent can do: the opening

The script cannot summarise, so it never tries.
Every run supplies an opening file: a one-line summary of what the change does for whoever benefits, a blank line, `## Intent`, then about four sentences.
There are two sources for it, and they are not equally authoritative.

**Prefer the author's own words.**
If a file of them exists - one the author wrote when the work was finished, whatever the local convention calls it - use it unchanged.
It was written off first-hand knowledge of the work by whoever did it, which no later reading of the diff can match.

**Otherwise derive one, and say that you did.**
With no such file, read the published description's existing `## Intent`, `## What Changed` and `## Risk Assessment`, and the diff, and write the opening from those.
Summarising finished work from its own description and diff is a job an agent does well.
It is still not the author speaking, so when you report the outcome, say the summary was derived from the pull request rather than presenting it as the author's.
Never invent intent that the description and the diff do not support; if they do not support a confident four sentences, write fewer and say so.

Write the opening to a file.
Never pass it inline on a command line: backticks in it would be executed by the shell, silently.

## Procedure

1. Resolve the pull request.
   Take a URL you were given; otherwise find it from the current branch and ask one concise question if more than one candidate fits.
   Never guess between two.
2. Read the current description.
   This is also how you learn which headings it actually has, which is a question to answer per pull request rather than assumed from a template.
3. Get the opening: the author's file if one exists, else derived as above.
4. Run with `--dry-run --keep-dir <dir>` first and read the planned description and comment.
   This writes nothing, and it is the cheapest possible check that the opening reads well and the split landed where you expected.

   ```sh
   <this skill's directory>/bin/pr-summarise.sh <pr-url> \
     --opening-file <opening.md> --dry-run --keep-dir <dir>
   ```

5. Run it for real: the same command without `--dry-run` and `--keep-dir`.
   On Bitbucket both this run and the dry run above need the credential.
   Supply it as a command prefix whose token comes from a command substitution or a secret manager, exactly as [What it needs](#what-it-needs) shows.
   Never write the token's own characters into a command: the command you run is recorded in your transcript, which is one of the places this credential must not end up.
6. If it reports anything other than success, report the concrete reason and stop.
   Never work a refusal around by editing the pull request by hand.
   Read the reason before saying what happened, because a refusal does not always mean nothing was written - see below.

## What is never at risk

These three are the reason this is safe to run on a published pull request that other people are already reading:

- The complete original description is saved privately **before** the first write, every time, under a timestamped file that is never overwritten.
- The moved sections are posted as a comment **before** the description is trimmed, so a failed post leaves the description whole.
- A second run **declines** instead of compounding.

The guarantee is ordering, not inaction, and the outcome line says which side of that ordering a failure stopped on.

- A refusal naming no forge write - an unsupported forge, a missing opening, nothing to move, an unbalanced code fence, an oversized detail, an already-reshaped body, or a failed comment post - left the pull request untouched.
- A refusal saying *the detail comment is posted and the original is kept* means the comment is public and only the description write failed.
- A refusal saying the write could not be confirmed means both the comment and a description write may already have landed.
  Read the pull request before reporting and before any retry, or you will report that nothing changed on a pull request that now carries a comment.

In the last two cases, say so in your report, and check for an existing detail comment before re-running rather than posting a second one.

## Where the original is kept

Under `$XDG_STATE_HOME/no-mistakes-pr-summariser`, which is `~/.local/state/no-mistakes-pr-summariser` unless `XDG_STATE_HOME` says otherwise.
Set `PR_SUMMARISER_STATE_DIR` to put it somewhere else.

Inside it, `pr-reshape/` holds one directory per pull request, named `<provider>__<workspace>__<repo>__<number>`, holding every pre-reshape description of that pull request under a timestamped filename.
The directory is mode 0700 and the files 0600, because a description can quote private code.
If someone asks for the pre-reshape description back, that is where it is.

## Reporting it

Give the pull request's full `https://...` URL, what the description now says, and where the detail went.
Say whether the summary is the author's own or your derived best attempt - that distinction belongs to whoever reads the pull request, not in your notes.

A reshape rewrites a published pull request that other people read.
Confirm before running it, every time, and treat having reshaped one pull request earlier as no authority to reshape another.
