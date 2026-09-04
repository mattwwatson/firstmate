#!/usr/bin/env bash
# Behavior tests for the standalone summariser: skills/no-mistakes-pr-summariser.
#
# tests/fm-pr-reshape.test.sh already pins the reshape behaviour reached through
# firstmate's entry point. This suite pins the part that firstmate cannot prove,
# because firstmate supplies its own state directory, its own credential, and its
# own gh: that the SAME implementation still holds its three safety guarantees
# when it is run the way an installed skill runs it, with nothing of firstmate
# present.
#
# The guarantees, restated here because this suite is what proves them on this
# path:
#   - the complete original description is saved privately BEFORE the first write
#   - the detail comment is posted BEFORE the description is trimmed, so a failed
#     post leaves the description whole
#   - a second run declines instead of compounding
#
# It also pins what is new on this path and has no firstmate equivalent: the
# private record lands somewhere a person can find with no state directory
# configured, and the Bitbucket credential refuses by name rather than half
# authenticating.
#
# The credential cases run in two layers. The refusal cases never reach curl, so
# they prove the diagnostics alone. The cases below them run against a fake curl
# that records its own argument list and its own standard input, and every
# request this skill makes - the read, the comment post, and the description
# write - is checked there: the credential must arrive on standard input, and
# neither the token nor the account may appear in argv, because a token in argv
# reaches ps, shell history, and an agent's transcript. Moving the credential to
# --user turns all three of those cases red.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL_DIR="$ROOT/skills/no-mistakes-pr-summariser"
SUMMARISE="$SKILL_DIR/bin/pr-summarise.sh"
FORGE_ENV="$SKILL_DIR/bin/pr-forge-env.sh"
TMP_ROOT=$(fm_test_tmproot pr-summarise)

GH_URL='https://github.com/o/r/pull/7'
BB_URL='https://bitbucket.org/ws/repo/pull-requests/9'

sample_body() {
  cat <<'MD'
## Intent

A long intent that grew across fix rounds and reads as a diary rather than a summary.

## What Changed

- The thing that changed.

## Testing

Ran the suites.

## Pipeline

### Review - 7 issues

Round one raised these and here is how each was answered.
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

# A case dir with a fake forge that STORES the description, so the read-modify-
# write-verify cycle is exercised rather than only logged.
new_case() {
  local dir
  mkdir -p "$TMP_ROOT"
  dir=$(mktemp -d "$TMP_ROOT/case.XXXXXX")
  mkdir -p "$dir/bin" "$dir/home"
  sample_body > "$dir/forge-body.md"
  sample_opening > "$dir/opening.md"

  cat > "$dir/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
case "$2" in
  view) cat "$FAKE_FORGE_BODY"; exit 0 ;;
  edit)
    for a in "$@"; do
      if [ "$prev" = --body-file ] 2>/dev/null; then cp -- "$a" "$FAKE_FORGE_BODY"; fi
      prev=$a
    done
    exit 0
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

  cat > "$dir/bin/forge" <<'SH'
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
  pr-description) cat > "$FAKE_FORGE_BODY"; exit 0 ;;
  pr-comment) cat > "$FAKE_COMMENT_OUT"; exit "${FAKE_FORGE_COMMENT_EXIT:-0}" ;;
esac
exit 0
SH
  chmod +x "$dir/bin/gh" "$dir/bin/forge"
  printf '%s\n' "$dir"
}

# Run the summariser the way an installed skill runs it: its own environment
# names only, and HOME pointed at the case so an unset state directory lands
# somewhere this test can read. XDG_STATE_HOME is cleared rather than pointed
# anywhere, because the default resolution under HOME is the thing these cases
# exercise; a case that means to redirect the state directory exports
# PR_SUMMARISER_STATE_DIR, which survives this. Echoes "<exit>|<stdout+stderr>".
run_summarise() {  # <case-dir> <url> [extra args...]
  local dir=$1 url=$2 out status
  shift 2
  out=$(env -u XDG_STATE_HOME \
    HOME="$dir/home" \
    PR_SUMMARISER_GH_BIN="$dir/bin/gh" \
    PR_SUMMARISER_FORGE_BIN="$dir/bin/forge" \
    FAKE_FORGE_BODY="$dir/forge-body.md" \
    FAKE_COMMENT_OUT="$dir/comment.md" \
    FAKE_GH_LOG="$dir/gh.log" \
    FAKE_FORGE_LOG="$dir/forge.log" \
    FAKE_GH_COMMENT_EXIT="${FAKE_GH_COMMENT_EXIT:-0}" \
    FAKE_FORGE_COMMENT_EXIT="${FAKE_FORGE_COMMENT_EXIT:-0}" \
    "$SUMMARISE" "$url" --opening-file "$dir/opening.md" "$@" 2>&1)
  status=$?
  printf '%s|%s' "$status" "$out"
}

field() {
  case "$2" in
    1) printf '%s' "${1%%|*}" ;;
    *) printf '%s' "${1#*|}" ;;
  esac
}

# --- the property the whole arrangement exists for ---------------------------

test_firstmate_runs_this_exact_implementation() {
  local through_wrapper direct
  # The implementation prints its help by reading its OWN file at run time, so
  # what comes back through firstmate's entry point is evidence of which file
  # that entry point actually reached - which reading either script's text is
  # not.
  through_wrapper=$("$ROOT/bin/fm-pr-reshape.sh" --help 2>&1)
  direct=$("$SUMMARISE" --help 2>&1)
  assert_contains "$through_wrapper" \
    'Usage: pr-summarise.sh <pr-url> --opening-file <path>' \
    "firstmate's entry point must reach the summariser rather than hold its own copy"
  # Its own one line of context first, then the implementation's help verbatim:
  # a second copy answering instead would differ somewhere in those 60 lines.
  [ "${through_wrapper#*"$direct"}" != "$through_wrapper" ] || \
    fail "firstmate's entry point must relay the summariser's own help unchanged"
  assert_contains "$through_wrapper" "firstmate's entry point" \
    "the entry point must say which command was run before the implementation's usage"
  pass "pr-summarise.sh: one implementation, and firstmate runs that one"
}

test_the_wrapper_finds_the_implementation_through_a_symlinked_bin() {
  # A synthetic root that symlinks the real bin/ into it is a supported layout -
  # tests/fm-session-start.test.sh builds exactly this, and an operator gets it
  # from a symlinked bin directory. bin/fm-pr-lib.sh resolves its skill sibling
  # physically so it works there; the wrapper performs the SAME lookup and must
  # agree, or the two disagree about where the one implementation lives.
  local root out marker
  mkdir -p "$TMP_ROOT"
  root=$(mktemp -d "$TMP_ROOT/synthetic.XXXXXX")
  ln -s "$ROOT/bin" "$root/bin"

  out=$("$root/bin/fm-pr-reshape.sh" --help 2>&1) \
    || fail "the wrapper must find the implementation through a symlinked bin/"
  assert_contains "$out" 'Usage: pr-summarise.sh <pr-url> --opening-file <path>' \
    "the wrapper must reach the implementation from a synthetic root, not just from the real one"

  # The sibling that already resolved this correctly, in the same layout: both
  # halves of the lookup have to answer the same way.
  marker=$(bash -c 'set -eu; . "$1"; printf "%s" "$FM_PR_RESHAPE_MARKER"' _ "$root/bin/fm-pr-lib.sh" 2>&1) \
    || fail "the shared library must also source its skill sibling through a symlinked bin/"
  [ -n "$marker" ] || fail "the shared library resolved no reshape marker through a symlinked bin/"
  pass "pr-summarise.sh: the wrapper and the shared library agree through a symlinked bin/"
}

test_the_skill_directory_is_self_contained() {
  # An installed skill is copied whole and can reach nothing outside itself, so
  # every path the summariser sources or execs must resolve inside this
  # directory. Run from a COPY of just the skill directory, with nothing else of
  # the repository present: any escape from it fails here, in whatever form it
  # is spelled.
  local dir record
  dir=$(new_case)
  cp -R "$SKILL_DIR" "$dir/installed"
  record=$(env -u XDG_STATE_HOME \
    HOME="$dir/home" \
    PR_SUMMARISER_GH_BIN="$dir/bin/gh" \
    PR_SUMMARISER_FORGE_BIN="$dir/bin/forge" \
    FAKE_FORGE_BODY="$dir/forge-body.md" \
    FAKE_COMMENT_OUT="$dir/comment.md" \
    FAKE_GH_LOG="$dir/gh.log" \
    FAKE_FORGE_LOG="$dir/forge.log" \
    "$dir/installed/bin/pr-summarise.sh" "$GH_URL" --opening-file "$dir/opening.md" 2>&1)
  expect_code 0 "$?" "a copy of the skill directory alone must reshape successfully"
  assert_contains "$record" "reshaped from" "the installed copy must report a reshape"
  assert_not_contains "$(cat "$dir/forge-body.md")" '## Pipeline' \
    "the installed copy must actually trim the description"
  pass "pr-summarise.sh: the skill directory runs with nothing else of the repository present"
}

# --- the three guarantees, on this path --------------------------------------

test_the_original_is_saved_privately_before_the_write() {
  local dir saved mode dirmode
  dir=$(new_case)
  run_summarise "$dir" "$GH_URL" >/dev/null
  saved=$(find "$dir/home" -name 'original-*.md' 2>/dev/null | head -1)
  [ -n "$saved" ] || fail "the original description must be saved privately"
  assert_contains "$(cat "$saved")" 'Round one raised these' \
    "the saved original must be the complete pre-reshape description"
  mode=$(if [ "$(uname)" = Darwin ]; then stat -f %Lp "$saved"; else stat -c %a "$saved"; fi)
  expect_code 600 "$mode" "the saved original must be private"
  dirmode=$(if [ "$(uname)" = Darwin ]; then stat -f %Lp "$(dirname "$saved")"; else stat -c %a "$(dirname "$saved")"; fi)
  expect_code 700 "$dirmode" "the private record directory must be private"
  pass "pr-summarise.sh: the original is saved privately before the first write"
}

test_a_failed_comment_leaves_the_description_alone() {
  local dir record before
  dir=$(new_case)
  before=$(cat "$dir/forge-body.md")
  record=$(FAKE_GH_COMMENT_EXIT=1 run_summarise "$dir" "$GH_URL")
  expect_code 5 "$(field "$record" 1)" "a failed comment post must classify as a forge failure"
  assert_contains "$(field "$record" 2)" "the description is unchanged" \
    "a failed comment post must say the description was left alone"
  [ "$before" = "$(cat "$dir/forge-body.md")" ] || \
    fail "the description must not be trimmed when the record could not be posted"
  pass "pr-summarise.sh: a failed comment post never trims the description"
}

test_a_second_run_changes_nothing() {
  local dir first second edits
  dir=$(new_case)
  run_summarise "$dir" "$GH_URL" >/dev/null
  first=$(cat "$dir/forge-body.md")
  second=$(run_summarise "$dir" "$GH_URL")
  expect_code 0 "$(field "$second" 1)" "a re-run on a reshaped body must succeed quietly"
  assert_contains "$(field "$second" 2)" "already reshaped" \
    "a re-run must say the body is already reshaped"
  [ "$first" = "$(cat "$dir/forge-body.md")" ] || fail "a re-run must not change the description again"
  edits=$(grep -c 'pr edit' "$dir/gh.log" || true)
  expect_code 1 "$edits" "a re-run must not issue a second description write"
  pass "pr-summarise.sh: a second run neither re-trims the body nor posts again"
}

# --- what is new on this path ------------------------------------------------

test_the_private_record_lands_somewhere_findable() {
  local dir saved
  dir=$(new_case)
  run_summarise "$dir" "$GH_URL" >/dev/null
  saved=$(find "$dir/home/.local/state/no-mistakes-pr-summariser/pr-reshape" \
    -name 'original-*.md' 2>/dev/null | head -1)
  [ -n "$saved" ] || \
    fail "with no state directory configured the original must land under ~/.local/state/no-mistakes-pr-summariser"
  assert_contains "$saved" 'github__o__r__7' \
    "the private record must be keyed by the pull request it belongs to"
  pass "pr-summarise.sh: with nothing configured the original lands under XDG state"
}

test_an_explicit_state_directory_is_honoured() {
  local dir saved
  dir=$(new_case)
  # Exported rather than a command prefix, because the runner passes the child
  # its own explicit list and an unexported value would not reach it.
  ( export PR_SUMMARISER_STATE_DIR="$dir/elsewhere"; run_summarise "$dir" "$GH_URL" >/dev/null )
  saved=$(find "$dir/elsewhere" -name 'original-*.md' 2>/dev/null | head -1)
  [ -n "$saved" ] || fail "PR_SUMMARISER_STATE_DIR must decide where the original is saved"
  pass "pr-summarise.sh: an explicit state directory is honoured"
}

test_bitbucket_routes_through_the_environment_credential() {
  local dir record
  dir=$(new_case)
  record=$(run_summarise "$dir" "$BB_URL")
  expect_code 0 "$(field "$record" 1)" "a Bitbucket reshape must succeed"
  assert_contains "$(cat "$dir/forge.log")" "pr-comment bitbucket ws/repo 9" \
    "Bitbucket must post the detail through the forge helper"
  assert_contains "$(cat "$dir/forge.log")" "pr-description bitbucket ws/repo 9" \
    "Bitbucket must write the description through the forge helper"
  assert_not_contains "$(cat "$dir/forge-body.md")" '## Pipeline' \
    "the Bitbucket description must actually be trimmed"
  pass "pr-summarise.sh: Bitbucket routes through the forge helper"
}

# --- the credential ----------------------------------------------------------

# Each refusal must name the value that is missing, so an agent arriving with no
# knowledge of this skill can act on the message alone.
test_a_missing_credential_refuses_by_name() {
  local out status
  for pair in \
    "::BITBUCKET_EMAIL and BITBUCKET_API_TOKEN are both unset" \
    "a@b.c::BITBUCKET_API_TOKEN is unset" \
    ":tok:BITBUCKET_EMAIL is unset"
  do
    local email=${pair%%:*} rest=${pair#*:} token expect
    token=${rest%%:*}
    expect=${rest#*:}
    out=$(env -u BITBUCKET_EMAIL -u BITBUCKET_API_TOKEN \
      ${email:+BITBUCKET_EMAIL="$email"} ${token:+BITBUCKET_API_TOKEN="$token"} \
      "$FORGE_ENV" api-get bitbucket /2.0/user 2>&1) && status=0 || status=$?
    expect_code 2 "$status" "a missing credential must be refused as a usage error"
    assert_contains "$out" "$expect" "the refusal must name what is missing"
  done
  pass "pr-forge-env.sh: an absent credential refuses and names the missing value"
}

test_a_malformed_request_never_reaches_the_credential() {
  local out status
  out=$(BITBUCKET_EMAIL=a@b.c BITBUCKET_API_TOKEN=tok \
    "$FORGE_ENV" pr-comment bitbucket 'ws/repo/extra' 9 </dev/null 2>&1) && status=0 || status=$?
  expect_code 2 "$status" "an invalid repository identifier must be refused"
  assert_contains "$out" "is not a valid Bitbucket pull request identifier" \
    "the refusal must name the identifier it rejected"
  out=$("$FORGE_ENV" api-get github /x 2>&1) && status=0 || status=$?
  expect_code 2 "$status" "another forge must be refused rather than attempted"
  assert_contains "$out" "gh CLI" "the refusal must say where GitHub goes instead"
  pass "pr-forge-env.sh: a malformed request is refused before any credential is used"
}

test_an_empty_write_is_refused() {
  local out status
  out=$(BITBUCKET_EMAIL=a@b.c BITBUCKET_API_TOKEN=tok \
    "$FORGE_ENV" pr-description bitbucket ws/repo 9 </dev/null 2>&1) && status=0 || status=$?
  expect_code 2 "$status" "an empty description must be refused"
  assert_contains "$out" "refusing to send an empty description" \
    "an empty description would erase the field rather than shorten it"
  pass "pr-forge-env.sh: an empty write is refused rather than erasing the field"
}

# --- the request itself, against a fake curl --------------------------------

# The refusal tests above never reach curl. These do, so they prove what the
# request actually looks like: that the credential arrives on curl's stdin and
# NOT in its argument list, which is the property that keeps a token out of ps,
# shell history, and an agent's transcript.
#
# The fake APPENDS to each record rather than truncating it, so every invocation
# leaves a trace. That is what makes the count observable: a preflight request, a
# retry, or any other second authenticated call adds a line instead of hiding
# behind the last writer.
FAKE_EMAIL='someone@example.com'
FAKE_TOKEN='tok-abc-123'

new_curl_case() {
  local dir
  mkdir -p "$TMP_ROOT"
  dir=$(mktemp -d "$TMP_ROOT/curl.XXXXXX")
  mkdir -p "$dir/bin"
  cat > "$dir/bin/curl" <<'SH'
#!/usr/bin/env bash
cat >> "$FAKE_CURL_STDIN"
printf '%s\n' "$*" >> "$FAKE_CURL_ARGV"
out=; url=; method=GET; data=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) out=$2; shift 2 ;;
    --request) method=$2; shift 2 ;;
    --data) data=$2; shift 2 ;;
    https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
printf '%s %s\n' "$method" "$url" >> "$FAKE_CURL_REQ"
case "$data" in
  @*) cat -- "${data#@}" >> "$FAKE_CURL_BODY" ;;
esac
[ -z "$out" ] || printf '%s' "${FAKE_CURL_RESPONSE:-{\}}" > "$out"
printf '%s' "${FAKE_CURL_STATUS:-200}"
exit 0
SH
  chmod +x "$dir/bin/curl"
  printf '%s\n' "$dir"
}

run_forge() {  # <case-dir> <args...>
  local dir=$1 status
  shift
  PATH="$dir/bin:$PATH" \
  BITBUCKET_EMAIL="$FAKE_EMAIL" BITBUCKET_API_TOKEN="$FAKE_TOKEN" \
  FAKE_CURL_STDIN="$dir/stdin" FAKE_CURL_ARGV="$dir/argv" \
  FAKE_CURL_REQ="$dir/req" FAKE_CURL_BODY="$dir/body" \
  FAKE_CURL_STATUS="${FAKE_CURL_STATUS:-200}" \
    "$FORGE_ENV" "$@" >"$dir/out" 2>"$dir/err" && status=0 || status=$?
  printf '%s' "$status"
}

test_the_token_reaches_stdin_and_never_argv() {
  local dir status
  dir=$(new_curl_case)
  status=$(run_forge "$dir" api-get bitbucket /2.0/repositories/ws/repo/pullrequests/9)
  expect_code 0 "$status" "a 200 read must succeed"
  expect_code 1 "$(wc -l < "$dir/req" | tr -d ' ')" \
    "a read must send exactly one request"
  assert_contains "$(cat "$dir/stdin")" "user = \"$FAKE_EMAIL:$FAKE_TOKEN\"" \
    "the credential must arrive on curl's standard input"
  assert_not_contains "$(cat "$dir/argv")" "$FAKE_TOKEN" \
    "the token must never appear in curl's argument list"
  assert_not_contains "$(cat "$dir/argv")" "$FAKE_EMAIL" \
    "the account must never appear in curl's argument list"
  assert_contains "$(cat "$dir/req")" \
    'GET https://api.bitbucket.org/2.0/repositories/ws/repo/pullrequests/9' \
    "the read must go to the pull request on the fixed API host"
  pass "pr-forge-env.sh: the credential reaches curl on stdin, never in argv"
}

test_each_action_sends_its_one_request() {
  local dir status body
  dir=$(new_curl_case)
  status=$(printf 'the detail\n' | run_forge "$dir" pr-comment bitbucket ws/repo 9)
  expect_code 0 "$status" "a 200 comment post must succeed"
  expect_code 1 "$(wc -l < "$dir/req" | tr -d ' ')" \
    "a comment post must send exactly one request, not a preflight or a retry as well"
  assert_contains "$(cat "$dir/req")" \
    'POST https://api.bitbucket.org/2.0/repositories/ws/repo/pullrequests/9/comments' \
    "a comment must POST the comments endpoint"
  body=$(cat "$dir/body")
  assert_contains "$body" '"raw": "the detail' "the comment body must be JSON-encoded from stdin"
  assert_not_contains "$(cat "$dir/argv")" 'the detail' \
    "the comment body must reach curl as a file, never on the command line"
  assert_contains "$(cat "$dir/stdin")" "user = \"$FAKE_EMAIL:$FAKE_TOKEN\"" \
    "the comment post's credential must arrive on curl's standard input"
  assert_not_contains "$(cat "$dir/argv")" "$FAKE_TOKEN" \
    "the token must never appear in the comment post's argument list"
  assert_not_contains "$(cat "$dir/argv")" "$FAKE_EMAIL" \
    "the account must never appear in the comment post's argument list"

  dir=$(new_curl_case)
  status=$(printf 'the new description\n' | run_forge "$dir" pr-description bitbucket ws/repo 9)
  expect_code 0 "$status" "a 200 description write must succeed"
  expect_code 1 "$(wc -l < "$dir/req" | tr -d ' ')" \
    "a description write must send exactly one request, not a preflight or a retry as well"
  assert_contains "$(cat "$dir/req")" \
    'PUT https://api.bitbucket.org/2.0/repositories/ws/repo/pullrequests/9' \
    "a description must PUT the pull request itself"
  body=$(cat "$dir/body")
  assert_contains "$body" '"description": "the new description' \
    "the description must be JSON-encoded from stdin"
  assert_not_contains "$body" 'title' "the write must send a description and no other field"
  assert_not_contains "$(cat "$dir/argv")" 'the new description' \
    "the description body must reach curl as a file, never on the command line"
  assert_contains "$(cat "$dir/stdin")" "user = \"$FAKE_EMAIL:$FAKE_TOKEN\"" \
    "the description write's credential must arrive on curl's standard input"
  assert_not_contains "$(cat "$dir/argv")" "$FAKE_TOKEN" \
    "the token must never appear in the description write's argument list"
  assert_not_contains "$(cat "$dir/argv")" "$FAKE_EMAIL" \
    "the account must never appear in the description write's argument list"
  pass "pr-forge-env.sh: each action sends exactly its own single request"
}

test_forge_statuses_classify_distinctly() {
  local dir status pair code expect
  for pair in "401:5" "403:5" "404:8" "500:9"; do
    code=${pair%%:*}
    expect=${pair#*:}
    dir=$(new_curl_case)
    status=$(FAKE_CURL_STATUS="$code" run_forge "$dir" api-get bitbucket /2.0/repositories/ws/repo/pullrequests/9)
    expect_code "$expect" "$status" "HTTP $code must classify distinctly"
    [ -s "$dir/err" ] || fail "HTTP $code must report one reason line"
    assert_not_contains "$(cat "$dir/err")" "$FAKE_TOKEN" \
      "a diagnostic must never carry the token"
  done
  pass "pr-forge-env.sh: rejection, invisibility, and unexpected statuses each classify distinctly"
}

test_firstmate_runs_this_exact_implementation
test_the_wrapper_finds_the_implementation_through_a_symlinked_bin
test_the_skill_directory_is_self_contained
test_the_original_is_saved_privately_before_the_write
test_a_failed_comment_leaves_the_description_alone
test_a_second_run_changes_nothing
test_the_private_record_lands_somewhere_findable
test_an_explicit_state_directory_is_honoured
test_bitbucket_routes_through_the_environment_credential
test_a_missing_credential_refuses_by_name
test_a_malformed_request_never_reaches_the_credential
test_an_empty_write_is_refused
test_the_token_reaches_stdin_and_never_argv
test_each_action_sends_its_one_request
test_forge_statuses_classify_distinctly
