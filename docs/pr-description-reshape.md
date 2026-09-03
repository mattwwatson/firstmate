# Pull-request description reshape: measurement and forge behaviour

Empirical record behind `bin/fm-pr-reshape.sh` and the `pr-reshape` skill, which move a pull request's build-history detail out of its description and into a comment on the same pull request.
Every measurement below was taken on 03/09/2026 against live GitHub and Bitbucket Cloud APIs, and no command used to establish any of it changed anything on either forge.
The stubbed no-network coverage for the resulting behaviour lives in `tests/fm-pr-reshape.test.sh`.

`bin/fm-pr-reshape.sh`'s own header and `--help` own the mechanics: the split, the exit codes, and the flags.
Nothing here restates them.

## The measurement that justifies the work

`mattw_watson/sls-scheduling` pull request 114 carried a 39,393-character description.
Its sections, measured by counting the bytes between one `## ` heading and the next:

| section | bytes | disposition |
|---|---:|---|
| `## Intent` | 7,244 | moved; a short replacement is written in its place |
| `## What Changed` | 1,994 | kept |
| `## Risk Assessment` | 518 | kept |
| `## Testing` and its evidence blocks | 5,805 | moved |
| `## Pipeline` and the per-step findings logs | 23,832 | moved |

The findings log alone is 60% of the description.
It is the round-by-round record of what review, test and document raised and how each was answered, which is the history of *building* the change sitting in the field a reviewer opens to find out what the change *is*.

Keeping What Changed and Risk Assessment unchanged, with a one-line summary and an intent of about four sentences above them, produces a description of about 3,000 characters.
A dry run of `bin/fm-pr-reshape.sh` against that exact description produced 3,272 bytes from 39,502, with 37,299 bytes moved to the comment.
The same run against pull request 95's description gives about 2,700.

## Why the detail moves to a comment rather than a collapsible section

**Bitbucket does not support `<details>` in a pull-request description, and does not fail quietly about it: it prints the tags.**

This was settled by reading a pull request that already contained them rather than by publishing a test one.
Pull request 95's description carries 10 `<details>` and 10 `<summary>` tags, so Bitbucket's own renderer had already answered the question.
Requesting the rendered field returns the HTML Bitbucket serves for that description:

```
$ bin/fm-forge-credential.sh api-get bitbucket \
    "/2.0/repositories/mattw_watson/sls-scheduling/pullrequests/95?fields=rendered.description"
```

Counting tags in the returned `rendered.description.html`:

```
<details as an element:      0
&lt;details escaped to text: 10
<summary as an element:      0
&lt;summary escaped to text: 10
```

Bitbucket escapes both tags, so a reviewer opening that pull request reads the characters `<details>` and `<summary>Evidence: ...</summary>` as visible text.
A collapsible section is therefore not a simpler alternative to a second artifact on Bitbucket; it is not available at all.
This is also why `FM_PR_RESHAPE_MARKER` in `bin/fm-pr-lib.sh` is visible text rather than an HTML comment: an invisible marker on GitHub would be a visible one on Bitbucket.

`?fields=rendered.description` is the reproducible check for any future question about how Bitbucket renders a description.

## What rewrites a description after the pull request exists

**A no-mistakes run that reaches its pull-request step replaces the description wholesale.**
**A rebase on its own does not.**

That distinction is what makes the reshape usable, and it was established from description history rather than inferred.
Bitbucket's activity endpoint records the full description at every update plus a `changes` object naming what changed, so a Bitbucket description's history can be reconstructed exactly:

```
$ bin/fm-forge-credential.sh api-get bitbucket \
    "/2.0/repositories/mattw_watson/sls-scheduling/pullrequests/113/activity?pagelen=50"
```

A `pagelen` above 50 answers HTTP 400 on that endpoint.

Pull request 113's history is the case that decides the design:

| time (02-03/09/2026) | source commit | destination commit | changed | description |
|---|---|---|---|---|
| 10:31:36 | 8f6d25c18d | 6fe51f9fbc | created | 46,102 |
| 10:42:59 | 8f6d25c18d | 6fe51f9fbc | `description` | 46,102 to 6,648 |
| 23:07:04 | 66d9bfc8f4 | eb8b3bc8e1 | pushed, base advanced | 6,648 |
| 23:07:56 | 66d9bfc8f4 | eb8b3bc8e1 | `description`, `title` | 6,648 to 34,303 |

A description trimmed to 6,648 characters was replaced by a full 34,303-character one 52 seconds after a later run pushed to the branch.
That trim was firstmate's own, made by hand, and its loss went unnoticed until this history was read.

Eleven recent `sls-scheduling` pull requests were examined this way: 115, 114, 113, 111, 109, 107, 105, 104, 102, 100, 95.
Six recorded no push and no description change after creation: 115, 111, 109, 105, 104, 100.
Four recorded a description change, and in each the timing identifies the cause:

- 113 pushed at 23:07:04, description 52 seconds later.
- 102 pushed at 03:29:59, description 52 seconds later; pushed again at 04:17:48, description 56 seconds later.
- 114 never pushed again; description rewritten 7.5 minutes after creation, inside the originating run.
- 107 never pushed again; description rewritten 12.5 minutes after creation, the same shape.

The 52-to-56 second gap recurring after every push is what identifies these as one run's push step followed by its own pull-request step, rather than a timer or a watcher.

**The counter-case.** Pull request 95 was pushed at 12:59:43 with both its source and destination commits changing, so its base branch had advanced and the branch was rebased onto it, and no description change was recorded.
A rebase alone therefore does not rewrite the description.

At least 2 of those 11 pull requests would have lost a reshape applied once their checks were green, and possibly 4: whether 114's and 107's early rewrites fell before or after their checks went green cannot be read from the activity log.

**The consequence for the design.** A reshape is an explicit action taken when the work is finished, not an automatic step at every pull request, because an automatic one cannot know whether a further run will follow and would be silently undone when one did.
Re-running the reshape is the remedy, which is why `bin/fm-pr-reshape.sh` is idempotent in both directions: it declines an already-reshaped body, and it re-trims a restored one without posting the same detail twice.

The same two write modes are visible in finer detail on GitHub, where `userContentEdits` exposes each body version.
Upstream pull request 3508 recorded seven versions: two replaced the visible sections wholesale, and three changed only the hidden `no-mistakes-pipeline-attestation:v1` comment, swapping its `head_sha` and leaving every other byte identical.
A reshape survives that second kind and is lost to the first.

## The attestation comment is a per-pull-request fact

The attestation is the third line of the `## Pipeline` section, immediately after the "Updates from git push no-mistakes" line, on both forges that carry it.
Because that is the section a reshape moves, `bin/fm-pr-reshape.sh` lifts the attestation line out and keeps it in the description: it is machine state a later run reads and rewrites in place, and moving it to a comment would take it out of reach.

Whether a given pull request has one is a question to answer per pull request rather than per forge.
Measured on `sls-scheduling`, pull requests 95, 97, 100 and 102 (26/08 to 29/08) each carry one, and 104, 105, 107, 109, 111, 113, 114 and 115 (31/08 to 03/09) carry none.
Those same four older pull requests are the ones carrying `<details>`, and the later ones carry neither.
On GitHub both were still being emitted on 03/09: of twelve upstream pull requests read that day, the six with a `## Pipeline` section carried 8 to 14 `<details>` each, and the six without carried none.

## Relationship to the privacy scrub

Open upstream pull request 2904, "key descoped events and scrub PR details in place, not sections", rules that the privacy scrub must redact within lines and never remove or rewrite whole sections.
**That rule and this mechanism are compatible, and the difference is worth stating because they read as contradictory.**

The scrub's job is to remove machine paths, home directories, usernames and local-environment details from a description that is otherwise correct.
Deleting a section to achieve that would throw away reviewer-relevant content to fix a detail inside one line, which is why the scrub is forbidden from doing it.

A reshape is not scrubbing.
It is asked for explicitly, it moves whole sections deliberately, and it moves them to a comment on the same pull request rather than deleting them.
Nothing leaves the pull request, and the complete original description is additionally saved privately before the first write.
So the scrub's rule stands unchanged: a scrub still may not remove a section, and a reshape is not a scrub doing so.

## What the split names, and why it does not count

`bin/fm-pr-reshape.sh` moves the sections it names - `## Testing`, `## Pipeline`, and the original `## Intent` - and keeps every other section it finds, in its original order.

A fixed five-section list would have been wrong.
Pull request 2 in `mattwwatson/firstmate` carries a sixth section, "Two pre-existing test failures were approved past at the test gate", 1,824 characters, added by hand after the pull request was opened and squarely reviewer-relevant.
The question to answer for the pull request in front of you is which headings it actually has, not which ones a pipeline template emits.
