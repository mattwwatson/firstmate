#!/usr/bin/env bash
# Behavior tests for bin/fm-pr-comment.sh, which posts a ship task's
# Manual-testing section to its PR as a comment via firstmate's own credential.
#
# The properties pinned here are the ones the mechanism depends on:
#   - GitHub posts through gh, Bitbucket through fm-forge-credential.sh, each
#     with the section file as the body
#   - it is idempotent: a re-run never posts a second comment
#   - a section the builder never wrote is a surfaced gap, not a silent no-op
#   - a failed post writes no marker, so firstmate can retry by re-arming
#   - an unsupported forge reports itself plainly
# Every case runs against fake forge tools, so the suite needs no credential.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

POSTER="$ROOT/bin/fm-pr-comment.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-comment)

# A case dir with a state/ dir and fake gh + fm-forge-credential.sh that log
# their calls. FAKE_GH_EXIT / FAKE_FORGE_EXIT make a post fail like a real one.
new_case() {
  local dir
  mkdir -p "$TMP_ROOT"
  dir=$(mktemp -d "$TMP_ROOT/case.XXXXXX")
  mkdir -p "$dir/state" "$dir/bin"
  cat > "$dir/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
exit "${FAKE_GH_EXIT:-0}"
SH
  cat > "$dir/bin/fm-forge-credential.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_FORGE_LOG"
cat > "$FAKE_FORGE_STDIN"
exit "${FAKE_FORGE_EXIT:-0}"
SH
  chmod +x "$dir/bin/gh" "$dir/bin/fm-forge-credential.sh"
  printf '%s\n' "$dir"
}

# Run the poster against a case dir. Echoes "<exit>|<stdout+stderr>".
run_poster() {  # <case-dir> <id> <url>
  local dir=$1 id=$2 url=$3 out status
  out=$(FM_STATE_OVERRIDE="$dir/state" \
    FM_GH_BIN="$dir/bin/gh" \
    FM_FORGE_CREDENTIAL_BIN="$dir/bin/fm-forge-credential.sh" \
    FAKE_GH_LOG="$dir/gh.log" \
    FAKE_FORGE_LOG="$dir/forge.log" \
    FAKE_FORGE_STDIN="$dir/forge.stdin" \
    FAKE_GH_EXIT="${FAKE_GH_EXIT:-0}" \
    FAKE_FORGE_EXIT="${FAKE_FORGE_EXIT:-0}" \
    "$POSTER" "$id" "$url" 2>&1)
  status=$?
  printf '%s|%s' "$status" "$out"
}

write_section() {  # <case-dir> <id> <body>
  printf '%s\n' "$3" > "$1/state/$2-manual-testing-section.md"
}

field() { printf '%s' "$1" | cut -d'|' -f"$2"; }

test_github_posts_the_section_file_and_marks_it() {
  local dir record
  dir=$(new_case)
  write_section "$dir" t1 '## Manual testing
No hand-testable surface; covered by automated tests'
  record=$(run_poster "$dir" t1 'https://github.com/o/r/pull/7')
  expect_code 0 "$(field "$record" 1)" "a GitHub post must succeed"
  assert_contains "$(field "$record" 2)" "posted to https://github.com/o/r/pull/7" \
    "the poster must report the outcome as a posted comment"
  assert_contains "$(cat "$dir/gh.log")" "pr comment https://github.com/o/r/pull/7 --body-file" \
    "GitHub must post the section file as the comment body via gh"
  assert_present "$dir/state/t1.manual-testing-posted" "a successful post must leave the idempotency marker"
  pass "fm-pr-comment.sh: GitHub posts the section file and records the marker"
}

test_bitbucket_posts_through_the_firstmate_credential() {
  local dir record
  dir=$(new_case)
  write_section "$dir" t2 '## Manual testing
walkthrough'
  record=$(run_poster "$dir" t2 'https://bitbucket.org/ws/repo/pull-requests/9')
  expect_code 0 "$(field "$record" 1)" "a Bitbucket post must succeed"
  assert_contains "$(cat "$dir/forge.log")" "pr-comment bitbucket ws/repo 9" \
    "Bitbucket must route through fm-forge-credential.sh pr-comment"
  assert_contains "$(cat "$dir/forge.stdin")" "walkthrough" \
    "the section body must reach the credential helper on stdin"
  pass "fm-pr-comment.sh: Bitbucket posts through firstmate's own credential"
}

test_it_never_double_posts() {
  local dir record
  dir=$(new_case)
  write_section "$dir" t3 'body'
  run_poster "$dir" t3 'https://github.com/o/r/pull/3' >/dev/null
  record=$(run_poster "$dir" t3 'https://github.com/o/r/pull/3')
  expect_code 0 "$(field "$record" 1)" "a re-run for an already-posted task must succeed quietly"
  expect_code 1 "$(grep -c 'pr comment' "$dir/gh.log")" \
    "re-arming a task must not post a second comment (gh must be called exactly once)"
  pass "fm-pr-comment.sh: a re-run never double-posts"
}

test_a_missing_section_is_surfaced_not_silent() {
  local dir record
  dir=$(new_case)
  record=$(run_poster "$dir" t4 'https://github.com/o/r/pull/4')
  expect_code 3 "$(field "$record" 1)" "a builder-omitted section must surface with its own code"
  assert_contains "$(field "$record" 2)" "no section written" \
    "the poster must say the section is missing rather than posting nothing silently"
  assert_absent "$dir/gh.log" "a missing section must not reach the forge"
  pass "fm-pr-comment.sh: a missing section is a surfaced gap, not a silent no-op"
}

test_a_failed_post_leaves_no_marker() {
  local dir record
  dir=$(new_case)
  write_section "$dir" t5 'body'
  record=$(FAKE_GH_EXIT=1 run_poster "$dir" t5 'https://github.com/o/r/pull/5')
  expect_code 5 "$(field "$record" 1)" "a failed post must classify distinctly"
  assert_contains "$(field "$record" 2)" "post failed" "a failed post must say so"
  assert_absent "$dir/state/t5.manual-testing-posted" \
    "a failed post must leave no marker, so firstmate can retry by re-arming"
  pass "fm-pr-comment.sh: a failed post leaves no marker"
}

test_an_unsupported_forge_reports_itself() {
  local dir record
  dir=$(new_case)
  write_section "$dir" t6 'body'
  record=$(run_poster "$dir" t6 'https://gitlab.com/g/p/-/merge_requests/3')
  expect_code 4 "$(field "$record" 1)" "an unsupported forge must classify distinctly"
  assert_contains "$(field "$record" 2)" "not supported" "an unsupported forge must report itself plainly"
  pass "fm-pr-comment.sh: an unsupported forge reports itself"
}

test_github_posts_the_section_file_and_marks_it
test_bitbucket_posts_through_the_firstmate_credential
test_it_never_double_posts
test_a_missing_section_is_surfaced_not_silent
test_a_failed_post_leaves_no_marker
test_an_unsupported_forge_reports_itself
