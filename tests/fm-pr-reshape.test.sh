#!/usr/bin/env bash
# Behavior tests for bin/fm-pr-reshape.sh, which moves a pull request's
# build-history detail out of the description and into a comment.
#
# The fake forge here STORES the description rather than only logging the call,
# so the script's read-modify-write-verify cycle is exercised end to end: a test
# that only logged writes could not catch a body that was never really changed,
# which is the exact failure the read-back exists to catch.
#
# The properties pinned here are the ones the mechanism depends on:
#   - Testing, Pipeline and the original Intent move; every other section stays,
#     including one a human added by hand
#   - the no-mistakes attestation comment stays in the description, while a
#     findings line that merely quotes its token stays in the moved record
#   - a "## " heading quoted inside a fenced code block does not reroute the
#     section it sits in, and one kept in the new description does not make the
#     read-back call a completed reshape unverified
#   - a body whose fences are unbalanced refuses, because an unterminated fence
#     hides every heading after it and would move a hand-added section silently
#   - the original description is saved privately before the first write
#   - the detail comment is posted BEFORE the description is trimmed, so a
#     failed post leaves the record intact in the description
#   - it is idempotent: a second run changes nothing and posts nothing, while a
#     body that merely quotes the marker token in prose is still reshaped
#   - an opening that would make the written description unconfirmable is
#     refused before the comment is posted, not after
#   - a pipeline run that restores the long body can be reshaped again, without
#     posting an identical detail comment twice
#   - a write that does not survive read-back is reported, not called success,
#     including when the forge serves the body back with CRLF line endings
#   - GitLab, a missing opening, an absent Pipeline, and an oversized detail
#     each classify distinctly and write nothing
# Every case runs against fake forge tools, so the suite needs no credential.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RESHAPE="$ROOT/bin/fm-pr-reshape.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-reshape)

# A description shaped like the ones no-mistakes really emits: the five template
# sections, an attestation comment inside Pipeline, and a sixth section a human
# added by hand after the pull request was opened. That last one is why the
# splitter names what it moves instead of keeping a fixed five.
sample_body() {
  cat <<'MD'
## Intent

A long intent that grew across fix rounds and reads as a diary rather than a summary.
It is the section a reviewer opens first and learns least from.

## What Changed

- The thing that changed.
- The other thing that changed.

## Risk Assessment

Low: narrow and covered.

## Testing

Ran the suites.

### Evidence: a transcript

Lots of transcript detail here.

## Pipeline

Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)

<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"abc123","steps":[{"step":"intent","status":"completed"}]} -->

### Review - 7 issues

Round one raised these and here is how each was answered.

### Test - 1 info

Round two.

## Two pre-existing test failures were approved past at the test gate

A human wrote this after the pull request was opened, and a reviewer needs it.
MD
}

sample_opening() {
  cat <<'MD'
Counts award depth per patrol so the board tells a holder from someone who patrols.

## Intent

Four sentences, written when the work was finished.
It says what the change is for.
It does not narrate the rounds.
It is about 400 characters.
MD
}

# A case dir holding the fake forge's stored description plus fake gh and
# fm-forge-credential.sh that read and write it.
new_case() {
  local dir
  mkdir -p "$TMP_ROOT"
  dir=$(mktemp -d "$TMP_ROOT/case.XXXXXX")
  mkdir -p "$dir/state" "$dir/bin"
  sample_body > "$dir/forge-body.md"
  sample_opening > "$dir/opening.md"

  # Fake gh: view prints the stored description, edit replaces it, comment logs
  # the posted file. FAKE_GH_EDIT_NOOP makes a write report success while
  # changing nothing, which is the silent-failure case.
  cat > "$dir/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
case "$2" in
  view) cat "$FAKE_FORGE_BODY"; exit "${FAKE_GH_EXIT:-0}" ;;
  edit)
    [ "${FAKE_GH_EDIT_NOOP:-0}" = 1 ] && exit 0
    for a in "$@"; do
      if [ "$prev" = --body-file ] 2>/dev/null; then cp -- "$a" "$FAKE_FORGE_BODY"; fi
      prev=$a
    done
    # A forge that keeps a moved section and serves the body back with CRLF
    # line endings, which is how GitHub stores a body edited through the web UI.
    if [ "${FAKE_FORGE_CRLF_LEFTOVER:-0}" = 1 ]; then
      printf '## Pipeline \nRound one raised these and here is how each was answered.\n' \
        >> "$FAKE_FORGE_BODY"
      python3 -c '
import sys
p = sys.argv[1]
data = open(p, "rb").read().replace(b"\n", b"\r\n")
open(p, "wb").write(data)
' "$FAKE_FORGE_BODY"
    fi
    exit "${FAKE_GH_EXIT:-0}"
    ;;
  comment)
    for a in "$@"; do
      if [ "$prev" = --body-file ] 2>/dev/null; then cp -- "$a" "$FAKE_COMMENT_OUT"; fi
      prev=$a
    done
    exit "${FAKE_GH_COMMENT_EXIT:-0}"
    ;;
esac
exit 0
SH

  cat > "$dir/bin/fm-forge-credential.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_FORGE_LOG"
case "$1" in
  api-get)
    python3 -c '
import json,sys
body=open(sys.argv[1],encoding="utf-8").read()
json.dump({"description":body},sys.stdout)
' "$FAKE_FORGE_BODY"
    exit 0
    ;;
  pr-description)
    [ "${FAKE_FORGE_WRITE_EXIT:-0}" = 0 ] || { echo "error: refused" >&2; exit "$FAKE_FORGE_WRITE_EXIT"; }
    cat > "$FAKE_FORGE_BODY"
    exit 0
    ;;
  pr-comment)
    cat > "$FAKE_COMMENT_OUT"
    exit "${FAKE_FORGE_COMMENT_EXIT:-0}"
    ;;
esac
exit 0
SH
  chmod +x "$dir/bin/gh" "$dir/bin/fm-forge-credential.sh"
  printf '%s\n' "$dir"
}

# Run the reshaper against a case dir. Echoes "<exit>|<stdout+stderr>".
run_reshape() {  # <case-dir> <url> [extra args...]
  local dir=$1 url=$2 out status
  shift 2
  out=$(FM_STATE_OVERRIDE="$dir/state" \
    FM_GH_BIN="$dir/bin/gh" \
    FM_FORGE_CREDENTIAL_BIN="$dir/bin/fm-forge-credential.sh" \
    FAKE_FORGE_BODY="$dir/forge-body.md" \
    FAKE_COMMENT_OUT="$dir/comment.md" \
    FAKE_GH_LOG="$dir/gh.log" \
    FAKE_FORGE_LOG="$dir/forge.log" \
    FAKE_GH_EXIT="${FAKE_GH_EXIT:-0}" \
    FAKE_GH_EDIT_NOOP="${FAKE_GH_EDIT_NOOP:-0}" \
    FAKE_GH_COMMENT_EXIT="${FAKE_GH_COMMENT_EXIT:-0}" \
    FAKE_FORGE_COMMENT_EXIT="${FAKE_FORGE_COMMENT_EXIT:-0}" \
    FAKE_FORGE_WRITE_EXIT="${FAKE_FORGE_WRITE_EXIT:-0}" \
    FAKE_FORGE_CRLF_LEFTOVER="${FAKE_FORGE_CRLF_LEFTOVER:-0}" \
    "$RESHAPE" "$url" --opening-file "$dir/opening.md" "$@" 2>&1)
  status=$?
  printf '%s|%s' "$status" "$out"
}

# Split on the FIRST "|" using parameter expansion rather than cut, because a
# run can legitimately print more than one outcome line and cut would then
# return a field per line.
field() {
  case "$2" in
    1) printf '%s' "${1%%|*}" ;;
    *) printf '%s' "${1#*|}" ;;
  esac
}
GH_URL='https://github.com/o/r/pull/7'
BB_URL='https://bitbucket.org/ws/repo/pull-requests/9'

test_it_moves_the_build_history_and_keeps_the_reviewer_sections() {
  local dir record body comment
  dir=$(new_case)
  record=$(run_reshape "$dir" "$GH_URL")
  expect_code 0 "$(field "$record" 1)" "a GitHub reshape must succeed"
  body=$(cat "$dir/forge-body.md")
  comment=$(cat "$dir/comment.md")

  assert_not_contains "$body" '## Pipeline' "the pipeline log must leave the description"
  assert_not_contains "$body" '## Testing' "the testing detail must leave the description"
  assert_not_contains "$body" 'Round one raised these' "the round-by-round findings must leave the description"
  assert_contains "$body" '## What Changed' "What Changed must stay in the description"
  assert_contains "$body" '## Risk Assessment' "Risk Assessment must stay in the description"
  assert_contains "$body" 'Four sentences, written when the work was finished.' \
    "the supplied opening must become the description's intent"

  assert_contains "$comment" '## Pipeline' "the pipeline log must arrive in the comment"
  assert_contains "$comment" '## Testing' "the testing detail must arrive in the comment"
  assert_contains "$comment" 'Round one raised these' "the findings log must arrive in the comment intact"
  assert_contains "$comment" 'a diary rather than a summary' \
    "the original intent must be moved rather than discarded"
  pass "fm-pr-reshape.sh: build history moves to the comment and the reviewer sections stay"
}

test_a_hand_added_section_is_kept() {
  local dir body
  dir=$(new_case)
  run_reshape "$dir" "$GH_URL" >/dev/null
  body=$(cat "$dir/forge-body.md")
  assert_contains "$body" 'Two pre-existing test failures were approved past at the test gate' \
    "a section a human added must survive the reshape"
  assert_contains "$body" 'A human wrote this after the pull request was opened' \
    "the hand-added section's body must survive too"
  pass "fm-pr-reshape.sh: a hand-added section is kept, not discarded with the template ones"
}

test_the_attestation_stays_in_the_description() {
  local dir body comment
  dir=$(new_case)
  run_reshape "$dir" "$GH_URL" >/dev/null
  body=$(cat "$dir/forge-body.md")
  comment=$(cat "$dir/comment.md")
  assert_contains "$body" 'no-mistakes-pipeline-attestation:v1' \
    "the attestation must stay in the description, where a later run reads and rewrites it"
  assert_contains "$body" 'abc123' "the attestation must be kept verbatim, head_sha included"
  assert_not_contains "$comment" 'no-mistakes-pipeline-attestation' \
    "the attestation must not be moved out with the section it sat in"
  pass "fm-pr-reshape.sh: the attestation comment stays in the description"
}

test_the_original_is_saved_privately_before_the_write() {
  local dir saved mode
  dir=$(new_case)
  run_reshape "$dir" "$GH_URL" >/dev/null
  saved=$(find "$dir/state/pr-reshape" -name 'original-*.md' 2>/dev/null | head -1)
  [ -n "$saved" ] || fail "the original description must be saved privately"
  assert_contains "$(cat "$saved")" 'Round one raised these' \
    "the saved original must be the complete pre-reshape description"
  mode=$(if [ "$(uname)" = Darwin ]; then stat -f %Lp "$saved"; else stat -c %a "$saved"; fi)
  expect_code 600 "$mode" "the saved original must be private"
  pass "fm-pr-reshape.sh: the original is saved privately before the first write"
}

test_a_second_run_changes_nothing() {
  local dir first second edits
  dir=$(new_case)
  run_reshape "$dir" "$GH_URL" >/dev/null
  first=$(cat "$dir/forge-body.md")
  second=$(run_reshape "$dir" "$GH_URL")
  expect_code 0 "$(field "$second" 1)" "a re-run on a reshaped body must succeed quietly"
  assert_contains "$(field "$second" 2)" "already reshaped" \
    "a re-run must say the body is already reshaped"
  [ "$first" = "$(cat "$dir/forge-body.md")" ] || fail "a re-run must not change the description again"
  edits=$(grep -c 'pr edit' "$dir/gh.log" || true)
  expect_code 1 "$edits" "a re-run must not issue a second description write"
  pass "fm-pr-reshape.sh: a second run neither re-trims the body nor posts again"
}

test_a_restored_long_body_reshapes_again_without_duplicating_the_detail() {
  local dir comments record
  dir=$(new_case)
  run_reshape "$dir" "$GH_URL" >/dev/null
  # A later pipeline run reaching its pull-request step restores the long body,
  # exactly as observed on the captain's own pull request 113.
  sample_body > "$dir/forge-body.md"
  record=$(run_reshape "$dir" "$GH_URL")
  expect_code 0 "$(field "$record" 1)" "a restored long body must be reshapable again"
  assert_not_contains "$(cat "$dir/forge-body.md")" '## Pipeline' \
    "the restored body must be trimmed again"
  assert_contains "$(field "$record" 2)" "already posted" \
    "an identical detail must not be posted a second time"
  comments=$(grep -c 'pr comment' "$dir/gh.log" || true)
  expect_code 1 "$comments" "the same detail must reach the forge as exactly one comment"
  pass "fm-pr-reshape.sh: a restored long body reshapes again without duplicating the detail"
}

test_a_failed_comment_leaves_the_description_alone() {
  local dir record before
  dir=$(new_case)
  before=$(cat "$dir/forge-body.md")
  record=$(FAKE_GH_COMMENT_EXIT=1 run_reshape "$dir" "$GH_URL")
  expect_code 5 "$(field "$record" 1)" "a failed comment post must classify as a forge failure"
  assert_contains "$(field "$record" 2)" "the description is unchanged" \
    "a failed comment post must say the description was left alone"
  [ "$before" = "$(cat "$dir/forge-body.md")" ] || \
    fail "the description must not be trimmed when the record could not be posted"
  pass "fm-pr-reshape.sh: a failed comment post never trims the description"
}

test_bitbucket_routes_through_the_firstmate_credential() {
  local dir record
  dir=$(new_case)
  record=$(run_reshape "$dir" "$BB_URL")
  expect_code 0 "$(field "$record" 1)" "a Bitbucket reshape must succeed"
  assert_contains "$(cat "$dir/forge.log")" "pr-comment bitbucket ws/repo 9" \
    "Bitbucket must post the detail through fm-forge-credential.sh pr-comment"
  assert_contains "$(cat "$dir/forge.log")" "pr-description bitbucket ws/repo 9" \
    "Bitbucket must write the description through fm-forge-credential.sh pr-description"
  assert_not_contains "$(cat "$dir/forge-body.md")" '## Pipeline' \
    "the Bitbucket description must actually be trimmed"
  pass "fm-pr-reshape.sh: Bitbucket routes through firstmate's own credential"
}

test_a_write_that_does_not_survive_read_back_is_reported() {
  local dir record
  dir=$(new_case)
  record=$(FAKE_GH_EDIT_NOOP=1 run_reshape "$dir" "$GH_URL")
  expect_code 6 "$(field "$record" 1)" \
    "a write that reports success without changing anything must classify distinctly"
  assert_contains "$(field "$record" 2)" "does not carry the reshape marker" \
    "the unverified write must say what the read-back found"
  pass "fm-pr-reshape.sh: a silent no-op write is caught by reading the description back"
}

test_a_findings_line_quoting_the_attestation_stays_in_the_record() {
  local dir body comment kept
  dir=$(new_case)
  cat > "$dir/forge-body.md" <<'MD'
## Intent

A long intent.

## What Changed

- The thing that changed.

## Testing

Ran the suites.

## Pipeline

Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)

<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"abc123","steps":[]} -->

### Review - 1 issue

Finding: docs/pr-description-reshape.md line 105 mentions no-mistakes-pipeline-attestation:v1 and should say why.
MD
  run_reshape "$dir" "$GH_URL" >/dev/null
  body=$(cat "$dir/forge-body.md")
  comment=$(cat "$dir/comment.md")
  assert_not_contains "$body" 'Finding: docs/pr-description-reshape.md' \
    "a findings line that quotes the attestation token must not be printed into the description"
  assert_contains "$comment" 'Finding: docs/pr-description-reshape.md line 105' \
    "a findings line that quotes the attestation token must stay in the moved record"
  assert_contains "$body" 'abc123' "the real attestation must still be kept in the description"
  kept=$(printf '%s\n' "$body" | grep -c 'no-mistakes-pipeline-attestation' || true)
  expect_code 1 "$kept" "only the attestation itself may be lifted into the description"
  pass "fm-pr-reshape.sh: a findings line quoting the attestation token stays with the record"
}

test_a_fenced_heading_inside_a_moved_section_does_not_reroute_it() {
  local dir body comment fences
  dir=$(new_case)
  cat > "$dir/forge-body.md" <<'MD'
## Intent

A long intent.

## What Changed

- The thing that changed.

## Pipeline

Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)

### Review - 1 issue

The reviewer quoted the description it was reading:

```markdown
## What Changed

- a quoted line from the build history
## Pipeline
```

Round two follows the quoted block.

## Two pre-existing test failures were approved past at the test gate

A human wrote this after the pull request was opened.
MD
  run_reshape "$dir" "$GH_URL" >/dev/null
  body=$(cat "$dir/forge-body.md")
  comment=$(cat "$dir/comment.md")
  assert_not_contains "$body" 'a quoted line from the build history' \
    "markdown quoted inside a fence must not be left behind in the description"
  assert_not_contains "$body" 'Round two follows the quoted block' \
    "a fenced heading must not reroute the remainder of the section it sits in"
  assert_not_contains "$body" '```' "no fragment of a fenced block may be left in the description"
  assert_contains "$comment" 'a quoted line from the build history' \
    "the fenced quote must move with the section that contains it"
  assert_contains "$comment" 'Round two follows the quoted block' \
    "the text after the fenced quote must move with its section too"
  fences=$(printf '%s\n' "$comment" | grep -c '^```' || true)
  expect_code 2 "$fences" "the moved record must carry both fence lines, unchanged"
  assert_contains "$body" 'A human wrote this after the pull request was opened' \
    "a genuine hand-added section after the fenced block must still be kept"
  pass "fm-pr-reshape.sh: a fenced '## ' inside a moved section does not reroute it"
}

test_a_moved_heading_surviving_with_crlf_is_caught() {
  local dir record
  dir=$(new_case)
  record=$(FAKE_FORGE_CRLF_LEFTOVER=1 run_reshape "$dir" "$GH_URL")
  expect_code 6 "$(field "$record" 1)" \
    "a moved section surviving a CRLF write must classify as unverified"
  assert_contains "$(field "$record" 2)" "still carries a moved section" \
    "the read-back must say a moved section survived"
  pass "fm-pr-reshape.sh: a moved heading surviving with CRLF is caught by the read-back"
}

test_a_kept_fenced_quote_of_a_moved_heading_is_not_called_unverified() {
  local dir record body
  dir=$(new_case)
  cat > "$dir/forge-body.md" <<'MD'
## Intent

A long intent.

## What Changed

- The reshape now quotes the headings it moves, so this description shows one:

```markdown
## Pipeline
```

## Testing

Ran the suites.

## Pipeline

Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)

### Review - 1 issue

Round one raised these.
MD
  record=$(run_reshape "$dir" "$GH_URL")
  expect_code 0 "$(field "$record" 1)" \
    "a fenced quote of a moved heading in a kept section must not fail the read-back"
  assert_contains "$(field "$record" 2)" "reshaped from" "the reshape must report itself complete"
  body=$(cat "$dir/forge-body.md")
  assert_contains "$body" 'so this description shows one' \
    "the kept section carrying the fenced quote must survive"
  assert_not_contains "$body" 'Round one raised these' \
    "the real pipeline log must still leave the description"
  pass "fm-pr-reshape.sh: a kept fenced quote of a moved heading is not called unverified"
}

test_an_unclosed_fence_refuses_rather_than_moving_a_hand_added_section() {
  local dir record before
  dir=$(new_case)
  cat > "$dir/forge-body.md" <<'MD'
## Intent

A long intent.

## What Changed

- The thing that changed.

## Pipeline

Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)

### Review - 1 issue

The reviewer pasted a fence it never closed:

```markdown
## Some heading it quoted

## Reviewer notes added by hand

A human wrote this after the pull request was opened, and a reviewer needs it.
MD
  before=$(cat "$dir/forge-body.md")
  record=$(run_reshape "$dir" "$GH_URL")
  expect_code 3 "$(field "$record" 1)" \
    "a body whose fences are unbalanced must refuse rather than guess at its headings"
  assert_contains "$(field "$record" 2)" "unterminated code fence" \
    "the refusal must name the reason the split could not be trusted"
  [ "$before" = "$(cat "$dir/forge-body.md")" ] || \
    fail "an unterminated fence must leave the description exactly as it was"
  assert_absent "$dir/comment.md" \
    "a hand-added section must not be posted into a comment on an unreadable split"
  pass "fm-pr-reshape.sh: an unclosed fence refuses rather than moving a hand-added section"
}

test_a_findings_line_quoting_the_marker_is_still_reshaped() {
  local dir record body comment
  dir=$(new_case)
  cat > "$dir/forge-body.md" <<'MD'
## Intent

A long intent.

## What Changed

- The thing that changed.

## Pipeline

Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)

### Review - 1 issue

Finding: the guard matches the bare token fm-pr-reshape:v1 rather than the footer it writes.
MD
  record=$(run_reshape "$dir" "$GH_URL")
  expect_code 0 "$(field "$record" 1)" "a body that only quotes the marker must still reshape"
  assert_contains "$(field "$record" 2)" "reshaped from" \
    "a body that quotes the marker in prose must not be declared already reshaped"
  body=$(cat "$dir/forge-body.md")
  comment=$(cat "$dir/comment.md")
  assert_not_contains "$body" 'Round one' "the pipeline log must leave the description"
  assert_contains "$comment" 'Finding: the guard matches the bare token' \
    "the findings line that quoted the marker must move with its section"
  assert_contains "$body" 'Moved to a comment on this pull request' \
    "the reshaped description must carry the footer the guard matches"
  pass "fm-pr-reshape.sh: a findings line quoting the marker token is still reshaped"
}

test_an_unusable_opening_is_refused_before_anything_is_posted() {
  local dir record before
  dir=$(new_case)
  before=$(cat "$dir/forge-body.md")
  cat > "$dir/opening.md" <<'MD'
Counts award depth per patrol.

## Intent

Four sentences, written when the work was finished.

## Testing

The author wrote a heading the reshape moves out.
MD
  record=$(run_reshape "$dir" "$GH_URL")
  expect_code 2 "$(field "$record" 1)" \
    "an opening carrying a moved heading must be refused as a usage error"
  assert_contains "$(field "$record" 2)" "$dir/opening.md" \
    "the refusal must name the opening file the caller has to correct"
  [ "$before" = "$(cat "$dir/forge-body.md")" ] || \
    fail "an unusable opening must leave the description exactly as it was"
  assert_absent "$dir/comment.md" "an unusable opening must not post the detail comment first"

  dir=$(new_case)
  before=$(cat "$dir/forge-body.md")
  cat > "$dir/opening.md" <<'MD'
Counts award depth per patrol.

## Intent

Four sentences, and an example the author never closed:

```sh
fm-pr-reshape.sh "$URL" --opening-file opening.md
MD
  record=$(run_reshape "$dir" "$GH_URL")
  expect_code 2 "$(field "$record" 1)" \
    "an opening leaving a code fence open must be refused as a usage error"
  assert_contains "$(field "$record" 2)" "code fence open" \
    "the refusal must say what about the opening could not be used"
  [ "$before" = "$(cat "$dir/forge-body.md")" ] || \
    fail "an opening with an open fence must leave the description exactly as it was"
  assert_absent "$dir/comment.md" "an opening with an open fence must post nothing"
  pass "fm-pr-reshape.sh: an unusable opening is refused before anything is posted"
}

test_nothing_to_move_is_reported_and_writes_nothing() {
  local dir record
  dir=$(new_case)
  printf '## Intent\n\nShort already.\n\n## What Changed\n\n- one thing\n' > "$dir/forge-body.md"
  record=$(run_reshape "$dir" "$GH_URL")
  expect_code 3 "$(field "$record" 1)" "a body with no build history must classify distinctly"
  assert_contains "$(field "$record" 2)" "no Testing or Pipeline section" \
    "the script must say why there was nothing to do"
  assert_absent "$dir/comment.md" "a body with nothing to move must post no comment"
  pass "fm-pr-reshape.sh: a body with no build history is reported and left alone"
}

test_an_oversized_detail_refuses_rather_than_truncating() {
  local dir record
  dir=$(new_case)
  {
    printf '## Intent\n\nshort\n\n## What Changed\n\n- one\n\n## Pipeline\n\n'
    awk 'BEGIN { for (i = 0; i < 1400; i++) print "A findings line long enough to matter for the comment size cap." }'
  } > "$dir/forge-body.md"
  record=$(run_reshape "$dir" "$GH_URL")
  expect_code 7 "$(field "$record" 1)" "an oversized detail must classify distinctly"
  assert_contains "$(field "$record" 2)" "over the" "the refusal must name the limit"
  assert_absent "$dir/comment.md" "an oversized detail must not be posted truncated"
  assert_contains "$(cat "$dir/forge-body.md")" '## Pipeline' \
    "an oversized detail must leave the description untouched"
  pass "fm-pr-reshape.sh: an oversized detail refuses rather than truncating a record"
}

test_a_dry_run_writes_nothing() {
  local dir record before
  dir=$(new_case)
  before=$(cat "$dir/forge-body.md")
  record=$(run_reshape "$dir" "$GH_URL" --dry-run --keep-dir "$dir/preview")
  expect_code 0 "$(field "$record" 1)" "a dry run must succeed"
  assert_contains "$(field "$record" 2)" "dry run, nothing written" "a dry run must say so"
  [ "$before" = "$(cat "$dir/forge-body.md")" ] || fail "a dry run must not change the description"
  assert_absent "$dir/comment.md" "a dry run must post no comment"
  assert_present "$dir/preview/new-description.md" "a dry run must leave the planned description to inspect"
  assert_present "$dir/preview/detail-comment.md" "a dry run must leave the planned comment to inspect"
  pass "fm-pr-reshape.sh: a dry run writes nothing to the forge"
}

test_gitlab_reports_itself_unsupported() {
  local dir record
  dir=$(new_case)
  record=$(run_reshape "$dir" 'https://gitlab.com/g/p/-/merge_requests/3')
  expect_code 4 "$(field "$record" 1)" "an unsupported forge must classify distinctly"
  assert_contains "$(field "$record" 2)" "not supported" "an unsupported forge must report itself plainly"
  pass "fm-pr-reshape.sh: GitLab reports itself unsupported"
}

test_a_missing_opening_is_refused() {
  local dir out status
  dir=$(new_case)
  out=$(FM_STATE_OVERRIDE="$dir/state" FM_GH_BIN="$dir/bin/gh" \
    FAKE_FORGE_BODY="$dir/forge-body.md" FAKE_GH_LOG="$dir/gh.log" \
    "$RESHAPE" "$GH_URL" --opening-file "$dir/absent.md" 2>&1)
  status=$?
  expect_code 2 "$status" "a missing opening must be a usage refusal"
  assert_contains "$out" "no opening written" "the refusal must name the missing opening"
  pass "fm-pr-reshape.sh: a missing opening is refused before any forge call"
}

test_it_moves_the_build_history_and_keeps_the_reviewer_sections
test_a_hand_added_section_is_kept
test_the_attestation_stays_in_the_description
test_the_original_is_saved_privately_before_the_write
test_a_second_run_changes_nothing
test_a_restored_long_body_reshapes_again_without_duplicating_the_detail
test_a_failed_comment_leaves_the_description_alone
test_bitbucket_routes_through_the_firstmate_credential
test_a_write_that_does_not_survive_read_back_is_reported
test_a_findings_line_quoting_the_attestation_stays_in_the_record
test_a_fenced_heading_inside_a_moved_section_does_not_reroute_it
test_a_moved_heading_surviving_with_crlf_is_caught
test_a_kept_fenced_quote_of_a_moved_heading_is_not_called_unverified
test_an_unclosed_fence_refuses_rather_than_moving_a_hand_added_section
test_a_findings_line_quoting_the_marker_is_still_reshaped
test_an_unusable_opening_is_refused_before_anything_is_posted
test_nothing_to_move_is_reported_and_writes_nothing
test_an_oversized_detail_refuses_rather_than_truncating
test_a_dry_run_writes_nothing
test_gitlab_reports_itself_unsupported
test_a_missing_opening_is_refused
