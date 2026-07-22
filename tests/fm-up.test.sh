#!/usr/bin/env bash
# Behavior tests for bin/fm-up.sh.
#
# The launcher must cd to the firstmate repo root resolved from its own
# location (so the primary session's Claude hooks load), exec claude with
# --permission-mode acceptEdits and the fire-up prompt, forward extra args
# before the prompt, leave an exported FM_HOME untouched, and fail with a
# clear one-line error when claude is not on PATH. No test launches a real
# claude: a fake claude on PATH records its cwd, arguments, and environment.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-up)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
CAPTURE="$TMP_ROOT/claude-capture"

# Fake claude: record cwd, FM_HOME, and each argument on its own line.
cat > "$FAKEBIN/claude" <<SH
#!/usr/bin/env bash
{
  printf 'cwd=%s\n' "\$(pwd -P)"
  printf 'fm_home=%s\n' "\${FM_HOME-__unset__}"
  for arg in "\$@"; do printf 'arg=%s\n' "\$arg"; done
} > '$CAPTURE'
SH
chmod +x "$FAKEBIN/claude"

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-up.sh" --help)
  assert_contains "$help" "never sets" "fm-up.sh --help omitted its header terminator"
  pass "fm-up.sh: --help renders the complete header"
}

test_launches_from_repo_root_with_mode_and_prompt() {
  local rc real_root
  rm -f "$CAPTURE"
  (cd "$TMP_ROOT" && PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-up.sh"); rc=$?
  expect_code 0 "$rc" "fm-up.sh should exit 0 with claude present"
  assert_present "$CAPTURE" "fake claude was never invoked"
  real_root=$(cd "$ROOT" && pwd -P)
  assert_grep "cwd=$real_root" "$CAPTURE" \
    "fm-up.sh must cd to the repo root resolved from bin/.., not the caller's cwd"
  assert_grep "arg=--permission-mode" "$CAPTURE" "missing --permission-mode flag"
  assert_grep "arg=acceptEdits" "$CAPTURE" "missing acceptEdits mode"
  assert_grep "arg=fire up firstmate" "$CAPTURE" "missing fire-up prompt"
  pass "fm-up.sh: launches claude from the repo root with acceptEdits and the prompt"
}

test_forwards_extra_args_before_prompt() {
  local args
  rm -f "$CAPTURE"
  PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-up.sh" --continue --model opus
  assert_present "$CAPTURE" "fake claude was never invoked"
  args=$(grep '^arg=' "$CAPTURE")
  assert_contains "$args" "arg=--continue" "extra flag --continue not forwarded"
  assert_contains "$args" "arg=--model" "extra flag --model not forwarded"
  assert_contains "$args" "arg=opus" "extra flag value not forwarded"
  # The prompt must be the LAST argument, after every forwarded flag.
  [ "$(printf '%s\n' "$args" | tail -1)" = "arg=fire up firstmate" ] \
    || fail "fire-up prompt must come after forwarded extra args"
  pass "fm-up.sh: forwards extra args to claude before the prompt"
}

test_fm_home_passes_through_untouched() {
  rm -f "$CAPTURE"
  FM_HOME="/some/other/home" PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-up.sh"
  assert_grep "fm_home=/some/other/home" "$CAPTURE" \
    "exported FM_HOME must reach claude unchanged"
  rm -f "$CAPTURE"
  env -u FM_HOME PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-up.sh"
  assert_grep "fm_home=__unset__" "$CAPTURE" \
    "fm-up.sh must not set FM_HOME when the caller has none"
  pass "fm-up.sh: passes FM_HOME through untouched and never sets it"
}

test_fails_cleanly_when_claude_absent() {
  local out rc emptybin
  emptybin="$TMP_ROOT/emptybin"
  mkdir -p "$emptybin"
  out=$(PATH="$emptybin:/usr/bin:/bin" "$ROOT/bin/fm-up.sh" 2>&1); rc=$?
  expect_code 1 "$rc" "fm-up.sh must exit nonzero when claude is absent"
  assert_contains "$out" "claude not found on PATH" \
    "missing-claude error must be a clear one-liner"
  pass "fm-up.sh: fails cleanly when claude is not on PATH"
}

test_help_includes_entire_header
test_launches_from_repo_root_with_mode_and_prompt
test_forwards_extra_args_before_prompt
test_fm_home_passes_through_untouched
test_fails_cleanly_when_claude_absent
