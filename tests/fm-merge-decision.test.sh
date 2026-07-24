#!/usr/bin/env bash
# Behavior tests for bin/fm-merge-decision.sh and the observability declaration
# grammar it reads (status_observability in bin/fm-classify-lib.sh).
#
# The hazard this file exists for: the merge-unobservable grant lets firstmate
# merge a pull request with nobody looking at it. Every condition it depends on
# must therefore fail toward "hold", and a worker that simply forgets to declare
# must never be read as having declared the change unobservable. Each test names
# the exact way the decision could go wrong if the script guessed instead.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-merge-decision)
DECIDE="$ROOT/bin/fm-merge-decision.sh"

PR_URL='https://github.com/captain/hexbattle/pull/7'
BB_URL='https://bitbucket.org/captain/hexbattle/pull-requests/7'

# make_home <registry-flags> -> echoes a home whose registry carries those flags
# on the project "hexbattle", with a fakebin dir alongside it.
make_home() {  # <registry-flags>
  local home
  home=$(mktemp -d "$TMP_ROOT/home.XXXXXX")
  mkdir -p "$home/data" "$home/state" "$home/projects/hexbattle" "$home/fakebin"
  printf '%s\n' "- hexbattle [no-mistakes $1] - fixture (added 2026-07-24)" \
    > "$home/data/projects.md"
  printf '%s\n' "$home"
}

# arm <home> <task-id> <pr-url> <status-line>... -> write the task's metadata and
# status stream. A task with no status lines gets an empty (but present) file.
arm() {  # <home> <id> <pr-url> [<status-line>...]
  local home=$1 id=$2 url=$3
  shift 3
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/wt-$id" \
    "project=$home/projects/hexbattle" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "grants=merge-unobservable" \
    "pr=$url"
  : > "$home/state/$id.status"
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >> "$home/state/$id.status"
  done
}

# fake_gh <home> <rollup-verdict> -> a gh stub whose `pr view` prints that
# verdict, standing in for the jq expression gh evaluates against the real
# statusCheckRollup. "die" makes the call fail, standing in for an unreachable
# forge or an unauthenticated gh.
fake_gh() {  # <home> <verdict|die>
  local home=$1 verdict=$2
  cat > "$home/fakebin/gh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = pr ] && [ "\${2:-}" = view ]; then
  [ "$verdict" = die ] && exit 1
  printf '%s\n' "$verdict"
  exit 0
fi
exit 1
SH
  chmod +x "$home/fakebin/gh"
}

# decide <home> <id> -> "<exit>|<stdout>", with stderr dropped. The exit code is
# the whole interface for callers, so every case asserts on it.
decide() {  # <home> <id>
  local home=$1 id=$2 out rc
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$DECIDE" "$id" 2>/dev/null) && rc=0 || rc=$?
  printf '%s|%s' "$rc" "$out"
}

# --- the three conditions, each proven necessary -----------------------------

test_green_granted_and_declared_unobservable_merges() {
  local home out
  home=$(make_home '+yolo:merge-unobservable')
  fake_gh "$home" passing
  arm "$home" green-a1 "$PR_URL" "done: PR $PR_URL checks green [observable=no]"
  out=$(decide "$home" green-a1)
  [ "${out%%|*}" = 0 ] || fail "the one case the grant exists for must merge, got: $out"
  assert_contains "${out#*|}" "merge:" "the merge verdict must say so on stdout"
  pass "green + granted + declared unobservable is the only combination that merges"
}

test_declared_observable_holds() {
  local home out
  home=$(make_home '+yolo:merge-unobservable')
  fake_gh "$home" passing
  arm "$home" seen-a2 "$PR_URL" "done: PR $PR_URL checks green [observable=yes]"
  out=$(decide "$home" seen-a2)
  [ "${out%%|*}" = 1 ] || fail "a change the captain can hand-test must hold, got: $out"
  assert_contains "${out#*|}" "captain-observable" "the hold must name the worker's declaration"
  pass "a declared-observable change holds for the captain even when green and granted"
}

# The silent-merge hazard: a worker that never declared must be indistinguishable
# from one that declared "observable", never from one that declared "no".
test_missing_declaration_holds() {
  local home out
  home=$(make_home '+yolo:merge-unobservable')
  fake_gh "$home" passing
  arm "$home" quiet-a3 "$PR_URL" "done: PR $PR_URL checks green"
  out=$(decide "$home" quiet-a3)
  [ "${out%%|*}" = 1 ] || fail "a forgotten declaration must never auto-merge, got: $out"
  assert_contains "${out#*|}" "no observability" "the hold must say the declaration is missing"

  # An empty stream and an absent stream are the same answer.
  arm "$home" quiet-a4 "$PR_URL"
  [ "$(decide "$home" quiet-a4)" = "1|hold: the worker declared no observability" ] \
    || fail "an empty status stream must hold: $(decide "$home" quiet-a4)"
  rm -f "$home/state/quiet-a4.status"
  [ "$(decide "$home" quiet-a4)" = "1|hold: the worker declared no observability" ] \
    || fail "an absent status stream must hold: $(decide "$home" quiet-a4)"
  pass "an absent declaration holds instead of being read as unobservable"
}

test_ambiguous_declaration_holds() {
  local home out
  home=$(make_home '+yolo:merge-unobservable')
  fake_gh "$home" passing

  # Two tokens on one line: the worker contradicted itself, so nothing is proven.
  arm "$home" mixed-a5 "$PR_URL" "done: PR $PR_URL green [observable=no] [observable=yes]"
  out=$(decide "$home" mixed-a5)
  [ "${out%%|*}" = 1 ] || fail "contradicting tokens must hold, got: $out"
  assert_contains "${out#*|}" "ambiguous" "the hold must name the ambiguity"

  # A value that is neither yes nor no is not a declaration.
  arm "$home" mixed-a6 "$PR_URL" "done: PR $PR_URL green [observable=maybe]"
  [ "$(decide "$home" mixed-a6)" = "1|hold: the worker's observability declaration is ambiguous" ] \
    || fail "an unparseable value must hold: $(decide "$home" mixed-a6)"

  # A token written before the colon lands inside the verb and breaks wake
  # classification; it must not also authorise a merge.
  arm "$home" mixed-a7 "$PR_URL" "done [observable=no]: PR $PR_URL green"
  [ "$(decide "$home" mixed-a7)" = "1|hold: the worker declared no observability" ] \
    || fail "a token outside the note must not declare: $(decide "$home" mixed-a7)"
  pass "contradictory, unparseable, and misplaced declarations all hold"
}

test_ungranted_project_never_merges() {
  local home out
  home=$(make_home '+yolo:findings,merge')
  fake_gh "$home" passing
  arm "$home" nogrant-a8 "$PR_URL" "done: PR $PR_URL checks green [observable=no]"
  out=$(decide "$home" nogrant-a8)
  [ "${out%%|*}" = 1 ] || fail "a project without the grant must hold, got: $out"
  assert_contains "${out#*|}" "does not grant merge-unobservable" \
    "the hold must name the missing grant"

  # The live registry is the authority, not the grants recorded at dispatch: a
  # withdrawn grant must take effect before the next merge, not after teardown.
  printf '%s\n' "- hexbattle [no-mistakes] - grant withdrawn (added 2026-07-24)" \
    > "$home/data/projects.md"
  [ "$(decide "$home" nogrant-a8)" = "1|hold: hexbattle does not grant merge-unobservable" ] \
    || fail "a withdrawn grant must hold immediately: $(decide "$home" nogrant-a8)"
  pass "the grant is read live from the registry and its absence holds"
}

# --- a red pull request is never merged, whatever else is true ---------------

test_unproven_checks_never_merge() {
  local home verdict out
  home=$(make_home '+yolo:merge-unobservable')
  arm "$home" checks-a9 "$PR_URL" "done: PR $PR_URL [observable=no]"
  for verdict in failing pending none die; do
    fake_gh "$home" "$verdict"
    out=$(decide "$home" checks-a9)
    [ "${out%%|*}" = 1 ] \
      || fail "checks=$verdict must hold even when granted and declared, got: $out"
  done

  # No gh at all is an unreadable check state, not a green one.
  cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 127
SH
  chmod +x "$home/fakebin/gh"
  out=$(decide "$home" checks-a9)
  [ "${out%%|*}" = 1 ] || fail "an unusable gh must hold, got: $out"
  pass "failing, running, absent, and unreadable check states all hold"
}

test_unsupported_forge_holds() {
  local home out
  home=$(make_home '+yolo:merge-unobservable')
  fake_gh "$home" passing
  arm "$home" gitlab-b1 'https://gitlab.com/captain/hexbattle/-/merge_requests/7' \
    "done: PR ready [observable=no]"
  out=$(decide "$home" gitlab-b1)
  [ "${out%%|*}" = 1 ] || fail "a forge with no check reader must hold, got: $out"
  assert_contains "${out#*|}" "could not be read" "the hold must say the check state is unknown"
  pass "a forge this script cannot read checks on holds rather than merging blind"
}

# The Bitbucket path reuses bin/fm-bb-build-status.sh, whose verdict vocabulary
# differs from GitHub's; a mistranslation there would merge on a red build.
test_bitbucket_build_verdicts_translate() {
  local home out stub pair rc
  home=$(make_home '+yolo:merge-unobservable')
  arm "$home" bb-b2 "$BB_URL" "done: PR $BB_URL [observable=no]"

  # The decision script calls its sibling by path, so the stub replaces that
  # sibling in a copy of bin/ rather than on PATH.
  mkdir -p "$home/bin"
  cp "$ROOT"/bin/fm-merge-decision.sh "$ROOT"/bin/fm-pr-lib.sh \
    "$ROOT"/bin/fm-classify-lib.sh "$ROOT"/bin/fm-project-mode.sh \
    "$ROOT"/bin/fm-crew-state.sh "$home/bin/"
  stub="$home/bin/fm-bb-build-status.sh"

  for pair in "green:0" "red:1" "pending:1" "none:1" "garbage:1"; do
    cat > "$stub" <<SH
#!/usr/bin/env bash
printf '%s\n' "${pair%%:*}"
SH
    chmod +x "$stub"
    out=$(FM_MERGE_CAPABILITY_PROBE=0 FM_HOME="$home" "$home/bin/fm-merge-decision.sh" bb-b2 2>/dev/null) \
      && rc=0 || rc=$?
    [ "$rc" = "${pair##*:}" ] \
      || fail "bitbucket build verdict ${pair%%:*} decided wrong (exit $rc): $out"
  done

  # An unreadable build status (the read-only credential case) holds.
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$stub"
  FM_MERGE_CAPABILITY_PROBE=0 FM_HOME="$home" "$home/bin/fm-merge-decision.sh" bb-b2 >/dev/null 2>&1 \
    && fail "an unreadable Bitbucket build status must hold"
  pass "every Bitbucket build verdict translates, and only green proceeds"
}

# --- unusable task state is refused, never decided ---------------------------

test_unusable_task_state_is_refused() {
  local home rc
  home=$(make_home '+yolo:merge-unobservable')
  fake_gh "$home" passing

  FM_HOME="$home" "$DECIDE" >/dev/null 2>&1 && rc=0 || rc=$?
  expect_code 2 "$rc" "a missing task id must be a usage error"
  FM_HOME="$home" "$DECIDE" ../escape >/dev/null 2>&1 && rc=0 || rc=$?
  expect_code 2 "$rc" "a path-shaped task id must be refused"
  FM_HOME="$home" "$DECIDE" absent-task >/dev/null 2>&1 && rc=0 || rc=$?
  expect_code 2 "$rc" "a task with no metadata must be refused"

  # A task that has not reported a pull request yet is an ordinary hold.
  arm "$home" nopr-b3 "$PR_URL" "working: implementing"
  sed -i.bak '/^pr=/d' "$home/state/nopr-b3.meta" && rm -f "$home/state/nopr-b3.meta.bak"
  FM_HOME="$home" "$DECIDE" nopr-b3 >/dev/null 2>&1 && rc=0 || rc=$?
  expect_code 1 "$rc" "a task with no recorded pull request must hold"
  pass "unusable invocations and task state are refused instead of decided"
}

# --- the declaration grammar itself -----------------------------------------

test_status_observability_reads_the_stream() {
  local dir f
  # shellcheck source=bin/fm-classify-lib.sh
  . "$ROOT/bin/fm-classify-lib.sh"
  dir=$(mktemp -d "$TMP_ROOT/obs.XXXXXX")
  f="$dir/x.status"

  printf '%s\n' "working: started" > "$f"
  [ "$(status_observability "$f")" = absent ] || fail "no token must read as absent"

  printf '%s\n' "done: PR url [observable=no]" >> "$f"
  [ "$(status_observability "$f")" = no ] || fail "a no token must read as no"

  # Last declaration wins, so a worker can correct itself.
  printf '%s\n' "resolved: rechecked, it does change the board [observable=yes]" >> "$f"
  [ "$(status_observability "$f")" = yes ] || fail "the last declaration must win"

  # A later line with no token does not erase the declaration.
  printf '%s\n' "working: rebasing" >> "$f"
  [ "$(status_observability "$f")" = yes ] || fail "an unrelated later line must not erase it"

  [ "$(status_observability "$dir/missing.status")" = absent ] \
    || fail "an absent file must read as absent"
  pass "status_observability folds the stream last-declaration-wins and never guesses"
}

test_green_granted_and_declared_unobservable_merges
test_declared_observable_holds
test_missing_declaration_holds
test_ambiguous_declaration_holds
test_ungranted_project_never_merges
test_unproven_checks_never_merge
test_unsupported_forge_holds
test_bitbucket_build_verdicts_translate
test_unusable_task_state_is_refused
test_status_observability_reads_the_stream

echo "# all fm-merge-decision tests passed"
