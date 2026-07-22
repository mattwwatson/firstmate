#!/usr/bin/env bash
# Behavior tests for the Bitbucket merge action: bin/fm-bb-pr-merge.sh's
# 200/202/409/429/555 protocol with its confirmed-MERGED success rule,
# bin/fm-forge-credential.sh's pr-merge and merge-capable subcommands, the
# strategy negotiation against the pull request's permitted list, the
# fm-pr-merge.sh strategy mapping for Bitbucket, and the two
# capability-mismatch warnings (session-start bootstrap and project-mode
# merge-grant resolution).
#
# Every case runs against a DUMMY credential pair through a fake keychain tool
# and a fake curl, so no case needs a real token or the network, and every
# captured stream is asserted free of the dummy pair - the same leak assertion
# tests/fm-forge-credential.test.sh carries. The fake curl answers each
# Bitbucket endpoint from FAKE_BB_* knobs, with numbered per-endpoint variants
# (FAKE_BB_PR_BODY_1, FAKE_BB_PR_BODY_2, ...) consumed in call order so one
# case can hold an OPEN pre-merge read alongside a MERGED confirmation read.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BB_MERGE="$ROOT/bin/fm-bb-pr-merge.sh"
PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
RESOLVER="$ROOT/bin/fm-forge-credential.sh"
PROJECT_MODE="$ROOT/bin/fm-project-mode.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
TMP_ROOT=$(fm_test_tmproot fm-bb-pr-merge-tests)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

DUMMY_USER='dummy@example.invalid'
DUMMY_SECRET='dummy-token-value'

BB_URL='https://bitbucket.org/mattw_watson/hexbattle/pull-requests/12'
BB_PATH=mattw_watson/hexbattle
TASK_LOCATION='https://api.bitbucket.org/2.0/repositories/mattw_watson/hexbattle/pullrequests/12/merge/task-status/%7Bde305d54%7D'

SHORT_HEAD=68443e3d6f3d
FULL_HEAD=68443e3d6f3d12efa5dbb361aab24c768df5240e

GREEN_STATUSES='{"values": [{"key": "ci/build", "state": "SUCCESSFUL", "updated_on": "2026-07-21T10:00:00+00:00"}], "next": null}'
DEFAULT_PR_BODY='{"state": "OPEN", "source": {"commit": {"hash": "68443e3d6f3d"}, "branch": {"merge_strategies": ["merge_commit", "squash", "fast_forward"]}}}'
READONLY_403_BODY='{"type": "error", "error": {"message": "Your credentials lack one or more required privilege scopes.", "detail": {"granted": ["read:pullrequest:bitbucket", "read:repository:bitbucket", "read:pipeline:bitbucket"], "required": ["read:account"]}}}'
WRITE_403_BODY='{"type": "error", "error": {"message": "Your credentials lack one or more required privilege scopes.", "detail": {"granted": ["write:pullrequest:bitbucket", "read:pipeline:bitbucket"], "required": ["read:account"]}}}'

pr_body() {  # <state> [<merge_strategies json array>]
  printf '{"state": "%s", "source": {"commit": {"hash": "%s"}, "branch": {"merge_strategies": %s}}}' \
    "$1" "$SHORT_HEAD" "${2:-[\"merge_commit\", \"squash\"]}"
}

# A case dir with the fake toolchain: a fake `security` answering the
# firstmate keychain services with the dummy pair, and a fake `curl` that
# reproduces the contract the resolver depends on - the config arrives on
# stdin (asserted to be the Basic pair, never recorded), the body lands in
# --output, headers land in --dump-header, and the HTTP status goes to stdout.
# Endpoints are answered from FAKE_BB_* with numbered call-order variants via
# per-endpoint counters under FAKE_BB_SEQ_DIR.
make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/seq" "$fakebin"
  cat > "$fakebin/security" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = find-generic-password ] || exit 1
service=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -s) service=\$2; shift 2 ;;
    *) shift ;;
  esac
done
case "\$service" in
  firstmate-bitbucket-email) mode=\${FAKE_KEYCHAIN_USER:-ok}; value='$DUMMY_USER' ;;
  firstmate-bitbucket-token) mode=\${FAKE_KEYCHAIN_SECRET:-ok}; value='$DUMMY_SECRET' ;;
  *) exit 44 ;;
esac
case "\$mode" in
  ok) printf '%s\n' "\$value" ;;
  absent) exit 44 ;;
esac
SH
  cat > "$fakebin/curl" <<SH
#!/usr/bin/env bash
config=\$(cat)
if [ "\$config" = 'user = "$DUMMY_USER:$DUMMY_SECRET"' ]; then
  printf '%s\n' AUTH_PRESENT >> "\${FAKE_CURL_STDIN_LOG:-/dev/null}"
else
  printf '%s\n' AUTH_ABSENT >> "\${FAKE_CURL_STDIN_LOG:-/dev/null}"
fi
printf '%s\n' "\$*" >> "\${FAKE_CURL_ARGV_LOG:-/dev/null}"
out=
hdr=
url=
method=GET
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --output) out=\$2; shift 2 ;;
    --dump-header) hdr=\$2; shift 2 ;;
    --request) method=\$2; shift 2 ;;
    https://*) url=\$1; shift ;;
    *) shift ;;
  esac
done
seq_next() {
  local n
  n=\$(cat "\${FAKE_BB_SEQ_DIR:-/tmp}/\$1" 2>/dev/null || echo 0)
  n=\$((n + 1))
  printf '%s' "\$n" > "\${FAKE_BB_SEQ_DIR:-/tmp}/\$1"
  printf '%s' "\$n"
}
status=\${FAKE_CURL_STATUS:-200}
body='{}'
case "\$method:\$url" in
  POST:*"/merge")
    n=\$(seq_next post)
    eval "status=\\\${FAKE_BB_MERGE_STATUS_\$n:-}"
    [ -n "\$status" ] || status=\${FAKE_BB_MERGE_STATUS:-200}
    eval "body=\\\${FAKE_BB_MERGE_BODY_\$n:-}"
    [ -n "\$body" ] || body=\${FAKE_BB_MERGE_BODY:-'{}'}
    if [ -n "\$hdr" ]; then
      : > "\$hdr"
      [ -z "\${FAKE_BB_MERGE_LOCATION:-}" ] || printf 'Location: %s\r\n' "\$FAKE_BB_MERGE_LOCATION" >> "\$hdr"
      [ -z "\${FAKE_BB_MERGE_RETRY_AFTER:-}" ] || printf 'Retry-After: %s\r\n' "\$FAKE_BB_MERGE_RETRY_AFTER" >> "\$hdr"
    fi
    if [ -n "\${FAKE_BB_MERGE_EXIT:-}" ]; then
      printf '%s' 000
      exit "\$FAKE_BB_MERGE_EXIT"
    fi
    ;;
  *"/merge/task-status/"*)
    n=\$(seq_next task)
    eval "body=\\\${FAKE_BB_TASK_BODY_\$n:-}"
    [ -n "\$body" ] || body=\${FAKE_BB_TASK_BODY:-'{"task_status": "PENDING"}'}
    ;;
  *"/statuses"*)
    body=\${FAKE_BB_STATUSES_BODY:-'$GREEN_STATUSES'}
    ;;
  *"/2.0/user"*)
    status=\${FAKE_BB_USER_STATUS:-200}
    body=\${FAKE_BB_USER_BODY:-'{"display_name": "fm"}'}
    ;;
  *"/commit/"*)
    body='{"hash": "$FULL_HEAD"}'
    ;;
  *"/pullrequests/"*)
    n=\$(seq_next pr)
    eval "body=\\\${FAKE_BB_PR_BODY_\$n:-}"
    [ -n "\$body" ] || body=\${FAKE_BB_PR_BODY:-'$DEFAULT_PR_BODY'}
    ;;
esac
[ -z "\$out" ] || printf '%s' "\$body" > "\$out"
printf '%s' "\$status"
SH
  chmod +x "$fakebin/security" "$fakebin/curl"
  : > "$dir/curl-argv"
  : > "$dir/curl-stdin"
  printf '%s\n' "$dir"
}

# Run a target with the fake toolchain and fast merge bounds. The FAKE_BB_*
# knobs pass through from the caller's prefix assignments.
run_with_fakes() {  # <dir> <command...>
  local dir=$1
  shift
  FM_FORGE_KEYCHAIN_TOOL_OVERRIDE="$dir/fakebin/security" \
    FAKE_CURL_ARGV_LOG="$dir/curl-argv" \
    FAKE_CURL_STDIN_LOG="$dir/curl-stdin" \
    FAKE_BB_SEQ_DIR="$dir/seq" \
    FM_BB_MERGE_POLL_DELAY=0 \
    FM_BB_MERGE_POLL_ATTEMPTS="${FM_BB_MERGE_POLL_ATTEMPTS:-4}" \
    FM_BB_MERGE_RETRY_ATTEMPTS="${FM_BB_MERGE_RETRY_ATTEMPTS:-3}" \
    FM_BB_MERGE_BACKOFF_BASE=0 \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$@"
}

assert_no_credential_leak() {  # <text> <label>
  assert_not_contains "$1" "$DUMMY_SECRET" "$2 leaked the token value"
  assert_not_contains "$1" "$DUMMY_USER" "$2 leaked the account value"
}

merge_posts() {  # <dir> -> how many merge POSTs reached curl
  grep -c 'request POST' "$1/curl-argv" || true
}

# --- the merge protocol ------------------------------------------------------

test_200_confirms_merged_before_reporting_success() {
  local dir out rc
  dir=$(make_case confirm-200)
  set +e
  out=$(FAKE_BB_PR_BODY_1=$(pr_body OPEN) FAKE_BB_PR_BODY_2=$(pr_body MERGED) \
    run_with_fakes "$dir" "$BB_MERGE" "$BB_URL" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "a confirmed 200 merge should succeed"
  assert_contains "$out" "merged: $BB_URL" "success did not name the merged pull request"
  grep -q 'request POST' "$dir/curl-argv" || fail "no merge POST reached the forge"
  grep -q 'pullrequests/12/merge$' "$dir/curl-argv" \
    || fail "the merge POST did not target this pull request's merge endpoint"
  grep -qF '"merge_strategy": "squash"' "$dir/curl-argv" \
    || fail "the default squash strategy did not reach the merge request body"
  grep -q AUTH_PRESENT "$dir/curl-stdin" || fail "the merge POST was not authenticated via stdin config"
  assert_no_credential_leak "$out" "the merge success output"
  pass "a 200 merge succeeds only after the pull request reads back as MERGED"
}

test_200_without_merged_readback_refuses_success() {
  local dir out rc
  dir=$(make_case unconfirmed-200)
  set +e
  out=$(FAKE_BB_PR_BODY=$(pr_body OPEN) \
    run_with_fakes "$dir" "$BB_MERGE" "$BB_URL" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "a 200 with no MERGED read-back must not be success"
  assert_contains "$out" 'refusing to report success' \
    "the 2xx-shortcut defect guard did not fire"
  assert_not_contains "$out" "merged: $BB_URL" "an unconfirmed merge was reported as merged"
  pass "a 200 whose read-back is not MERGED is a failure, never a success"
}

test_202_polls_task_status_to_merged() {
  local dir out rc
  dir=$(make_case task-poll-success)
  set +e
  out=$(FAKE_BB_MERGE_STATUS=202 FAKE_BB_MERGE_LOCATION="$TASK_LOCATION" \
    FAKE_BB_TASK_BODY_1='{"task_status": "PENDING"}' \
    FAKE_BB_TASK_BODY_2='{"task_status": "SUCCESS"}' \
    FAKE_BB_PR_BODY_1=$(pr_body OPEN) FAKE_BB_PR_BODY_2=$(pr_body MERGED) \
    run_with_fakes "$dir" "$BB_MERGE" "$BB_URL" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "a 202 whose task reaches SUCCESS should succeed"
  assert_contains "$out" "merged: $BB_URL" "the async merge success did not name the pull request"
  [ "$(grep -c 'merge/task-status/' "$dir/curl-argv")" -ge 2 ] \
    || fail "the task-status endpoint was not polled through PENDING"
  assert_no_credential_leak "$out" "the async merge output"
  pass "a 202 polls its task-status endpoint through PENDING to SUCCESS and then confirms MERGED"
}

test_202_task_failure_reports_the_reason() {
  local dir out rc
  dir=$(make_case task-poll-failure)
  set +e
  out=$(FAKE_BB_MERGE_STATUS=202 FAKE_BB_MERGE_LOCATION="$TASK_LOCATION" \
    FAKE_BB_TASK_BODY_1='{"task_status": "FAILED", "error": {"message": "merge conflict on src/main.c"}}' \
    FAKE_BB_PR_BODY=$(pr_body OPEN) \
    run_with_fakes "$dir" "$BB_MERGE" "$BB_URL" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "a failed merge task must fail"
  assert_contains "$out" 'merge task failed' "the task failure was not reported"
  assert_contains "$out" 'merge conflict on src/main.c' "the task failure lost its reason"
  pass "a 202 whose task fails reports the task's own reason"
}

test_202_still_pending_after_bound_is_retry_later() {
  local dir out rc
  dir=$(make_case task-poll-exhausted)
  set +e
  out=$(FAKE_BB_MERGE_STATUS=202 FAKE_BB_MERGE_LOCATION="$TASK_LOCATION" \
    FAKE_BB_PR_BODY=$(pr_body OPEN) \
    run_with_fakes "$dir" "$BB_MERGE" "$BB_URL" 2>&1)
  rc=$?
  set -e
  expect_code 3 "$rc" "an unfinished merge task must be retry-later, not failure or success"
  assert_contains "$out" 'retry later' "the exhausted poll did not say retry later"
  assert_not_contains "$out" "merged: $BB_URL" "an unfinished merge was reported as merged"
  pass "a 202 still PENDING after the poll bound is a retry-later outcome"
}

test_202_foreign_location_is_refused() {
  local dir out rc
  dir=$(make_case foreign-location)
  set +e
  out=$(FAKE_BB_MERGE_STATUS=202 \
    FAKE_BB_MERGE_LOCATION='https://evil.example/2.0/repositories/mattw_watson/hexbattle/pullrequests/12/merge/task-status/x' \
    FAKE_BB_PR_BODY=$(pr_body OPEN) \
    run_with_fakes "$dir" "$BB_MERGE" "$BB_URL" 2>&1)
  rc=$?
  set -e
  expect_code 3 "$rc" "a foreign task location must be refused"
  assert_contains "$out" 'task location' "the refusal did not name the location problem"
  assert_no_grep 'evil.example' "$dir/curl-argv" "the poll followed a foreign task location"

  : > "$dir/curl-argv"
  rm -f "$dir"/seq/*
  set +e
  out=$(FAKE_BB_MERGE_STATUS=202 \
    FAKE_BB_MERGE_LOCATION='https://api.bitbucket.org/2.0/repositories/other_ws/other-repo/pullrequests/9/merge/task-status/x' \
    FAKE_BB_PR_BODY=$(pr_body OPEN) \
    run_with_fakes "$dir" "$BB_MERGE" "$BB_URL" 2>&1)
  rc=$?
  set -e
  expect_code 3 "$rc" "another pull request's task location must be refused"
  assert_no_grep 'other_ws' "$dir/curl-argv" "the poll followed another pull request's task"
  pass "a 202 Location is followed only to this pull request's own task on the fixed API host"
}

test_409_reports_without_blind_retry() {
  local dir out rc
  dir=$(make_case ref-moved-409)
  set +e
  out=$(FAKE_BB_MERGE_STATUS=409 \
    FAKE_BB_MERGE_BODY='{"type": "error", "error": {"message": "Source branch has been modified"}}' \
    FAKE_BB_PR_BODY=$(pr_body OPEN) \
    run_with_fakes "$dir" "$BB_MERGE" "$BB_URL" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "a 409 must fail for inspection"
  assert_contains "$out" 'HTTP 409' "the 409 was not named"
  assert_contains "$out" 'Source branch has been modified' "the 409 lost the forge's reason"
  [ "$(merge_posts "$dir")" = 1 ] || fail "a 409 was retried blindly"
  pass "a 409 is reported for inspection and never retried blindly"
}

test_429_backs_off_and_retries() {
  local dir out rc
  dir=$(make_case rate-limit-retry)
  set +e
  out=$(FAKE_BB_MERGE_STATUS_1=429 FAKE_BB_MERGE_STATUS_2=200 \
    FAKE_BB_MERGE_RETRY_AFTER=0 \
    FAKE_BB_PR_BODY_1=$(pr_body OPEN) FAKE_BB_PR_BODY_2=$(pr_body MERGED) \
    run_with_fakes "$dir" "$BB_MERGE" "$BB_URL" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "a 429 followed by 200 should succeed after backoff"
  assert_contains "$out" "merged: $BB_URL" "the retried merge did not report success"
  [ "$(merge_posts "$dir")" = 2 ] || fail "the 429 was not retried exactly once"
  pass "a 429 backs off and retries, then still confirms MERGED"
}

test_429_exhausted_is_retry_later() {
  local dir out rc
  dir=$(make_case rate-limit-exhausted)
  set +e
  out=$(FAKE_BB_MERGE_STATUS=429 FAKE_BB_MERGE_RETRY_AFTER=0 \
    FM_BB_MERGE_RETRY_ATTEMPTS=2 \
    FAKE_BB_PR_BODY=$(pr_body OPEN) \
    run_with_fakes "$dir" "$BB_MERGE" "$BB_URL" 2>&1)
  rc=$?
  set -e
  expect_code 3 "$rc" "exhausted rate-limit retries must be retry-later"
  assert_contains "$out" 'retry later' "the exhausted 429 did not say retry later"
  [ "$(merge_posts "$dir")" = 2 ] || fail "the 429 retry bound was not honored"
  pass "exhausted 429 retries end as a retry-later outcome within the bound"
}

test_555_settles_by_reading_the_state_back() {
  local dir out rc
  dir=$(make_case timeout-555-merged)
  set +e
  out=$(FAKE_BB_MERGE_STATUS=555 \
    FAKE_BB_PR_BODY_1=$(pr_body OPEN) FAKE_BB_PR_BODY_2=$(pr_body MERGED) \
    run_with_fakes "$dir" "$BB_MERGE" "$BB_URL" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "a 555 whose read-back is MERGED is a confirmed success"
  assert_contains "$out" "merged: $BB_URL" "the settled 555 did not report the merge"
  [ "$(merge_posts "$dir")" = 1 ] || fail "a 555 was retried blindly"

  dir=$(make_case timeout-555-open)
  set +e
  out=$(FAKE_BB_MERGE_STATUS=555 \
    FAKE_BB_PR_BODY=$(pr_body OPEN) \
    run_with_fakes "$dir" "$BB_MERGE" "$BB_URL" 2>&1)
  rc=$?
  set -e
  expect_code 3 "$rc" "a 555 with the state still OPEN must be retry-later"
  assert_contains "$out" 'retry later' "the unsettled 555 did not say retry later"
  [ "$(merge_posts "$dir")" = 1 ] || fail "an unsettled 555 was retried blindly"
  pass "a 555 reads the state back: MERGED confirms, anything else is retry-later"
}

test_unanswered_merge_request_settles_by_reading_back() {
  local dir out rc
  dir=$(make_case transport-drop)
  set +e
  out=$(FAKE_BB_MERGE_EXIT=7 \
    FAKE_BB_PR_BODY_1=$(pr_body OPEN) FAKE_BB_PR_BODY_2=$(pr_body MERGED) \
    run_with_fakes "$dir" "$BB_MERGE" "$BB_URL" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "an unanswered POST whose read-back is MERGED is a confirmed success"
  assert_contains "$out" "merged: $BB_URL" "the settled transport drop did not report the merge"
  pass "an unanswered merge request is settled by the state read-back, never assumed either way"
}

# --- refusals before anything can mutate -------------------------------------

test_red_build_refuses_before_any_merge_request() {
  local dir out rc
  dir=$(make_case red-build)
  set +e
  out=$(FAKE_BB_STATUSES_BODY='{"values": [{"key": "ci", "state": "FAILED", "updated_on": "2026-07-21T10:00:00+00:00"}]}' \
    run_with_fakes "$dir" "$BB_MERGE" "$BB_URL" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "a red build must refuse the merge"
  assert_contains "$out" 'failing builds' "the red refusal did not name the failure"
  assert_no_grep 'request POST' "$dir/curl-argv" "a red build still sent a merge request"
  pass "a red build verdict refuses before any merge request exists"
}

test_scope_refusal_names_the_missing_scope() {
  local dir out rc
  dir=$(make_case scope-refusal)
  set +e
  out=$(FAKE_BB_MERGE_STATUS=403 \
    FAKE_BB_PR_BODY=$(pr_body OPEN) \
    run_with_fakes "$dir" "$BB_MERGE" "$BB_URL" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "a scope-refused merge must fail"
  assert_contains "$out" 'pull-request write' "the refusal did not name the missing scope"
  assert_not_contains "$out" "merged: $BB_URL" "a scope-refused merge was reported as merged"
  assert_no_credential_leak "$out" "the scope refusal output"
  pass "a credential whose scopes cannot merge is refused naming the missing scope"
}

test_strategy_not_permitted_refuses_naming_the_list() {
  local dir out rc
  dir=$(make_case strategy-excluded)
  set +e
  out=$(FAKE_BB_PR_BODY=$(pr_body OPEN '["merge_commit"]') \
    run_with_fakes "$dir" "$BB_MERGE" "$BB_URL" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "an excluded strategy must refuse, not silently switch"
  assert_contains "$out" 'does not permit the squash strategy' \
    "the refusal did not name the excluded strategy"
  assert_contains "$out" 'merge_commit' "the refusal did not name what is permitted"
  assert_no_grep 'request POST' "$dir/curl-argv" "an excluded strategy still sent a merge request"
  pass "a strategy the destination does not permit refuses naming the permitted list"
}

test_explicit_strategy_reaches_the_request() {
  local dir out rc
  dir=$(make_case explicit-strategy)
  set +e
  out=$(FAKE_BB_PR_BODY_1=$(pr_body OPEN) FAKE_BB_PR_BODY_2=$(pr_body MERGED) \
    run_with_fakes "$dir" "$BB_MERGE" "$BB_URL" --strategy merge_commit 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "an explicit permitted strategy should merge"
  grep -qF '"merge_strategy": "merge_commit"' "$dir/curl-argv" \
    || fail "the explicit strategy did not reach the merge request body"
  pass "an explicit permitted strategy reaches the merge request"
}

test_already_merged_reports_without_a_request() {
  local dir out rc
  dir=$(make_case already-merged)
  set +e
  out=$(FAKE_BB_PR_BODY=$(pr_body MERGED) \
    run_with_fakes "$dir" "$BB_MERGE" "$BB_URL" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "an already-MERGED pull request is the goal state"
  assert_contains "$out" "merged: $BB_URL" "the already-merged state was not reported as merged"
  assert_no_grep 'request POST' "$dir/curl-argv" "an already-merged pull request was merged again"

  dir=$(make_case declined)
  set +e
  out=$(FAKE_BB_PR_BODY=$(pr_body DECLINED) \
    run_with_fakes "$dir" "$BB_MERGE" "$BB_URL" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "a DECLINED pull request must refuse"
  assert_contains "$out" 'DECLINED' "the declined refusal did not name the state"
  assert_no_grep 'request POST' "$dir/curl-argv" "a declined pull request was merged"
  pass "MERGED short-circuits as confirmed success and DECLINED refuses, neither sending a request"
}

# --- the resolver subcommands ------------------------------------------------

test_merge_capable_reads_the_real_scope_list() {
  local dir out rc
  dir=$(make_case merge-capable)

  out=$(FAKE_BB_USER_STATUS=403 FAKE_BB_USER_BODY="$READONLY_403_BODY" \
    run_with_fakes "$dir" "$RESOLVER" merge-capable bitbucket 2>&1)
  [ "$out" = no ] || fail "a read-only scope list did not answer no (got: $out)"

  out=$(FAKE_BB_USER_STATUS=403 FAKE_BB_USER_BODY="$WRITE_403_BODY" \
    run_with_fakes "$dir" "$RESOLVER" merge-capable bitbucket 2>&1)
  [ "$out" = yes ] || fail "a granular write scope did not answer yes (got: $out)"

  out=$(FAKE_BB_USER_STATUS=403 \
    FAKE_BB_USER_BODY='{"type": "error", "error": {"message": "x", "detail": {"granted": ["pullrequest:write"], "required": ["account"]}}}' \
    run_with_fakes "$dir" "$RESOLVER" merge-capable bitbucket 2>&1)
  [ "$out" = yes ] || fail "pullrequest:write did not answer yes (got: $out)"

  out=$(run_with_fakes "$dir" "$RESOLVER" merge-capable bitbucket 2>&1)
  [ "$out" = unknown ] || fail "a 2xx probe did not answer unknown (got: $out)"

  out=$(FAKE_BB_USER_STATUS=403 FAKE_BB_USER_BODY='not json' \
    run_with_fakes "$dir" "$RESOLVER" merge-capable bitbucket 2>&1)
  [ "$out" = unknown ] || fail "an unreadable 403 body did not answer unknown (got: $out)"

  set +e
  out=$(FAKE_BB_USER_STATUS=401 run_with_fakes "$dir" "$RESOLVER" merge-capable bitbucket 2>&1)
  rc=$?
  set -e
  expect_code 5 "$rc" "a rejected credential must classify as rejected, not as a capability"
  assert_no_credential_leak "$out" "the merge-capable output"
  pass "merge-capable proves yes and no from the 403 scope list and never guesses past it"
}

test_pr_merge_subcommand_validates_before_any_request() {
  local dir out rc
  dir=$(make_case pr-merge-validation)

  set +e
  out=$(run_with_fakes "$dir" "$RESOLVER" pr-merge bitbucket "$BB_PATH" 12 delete-everything 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "an unknown strategy must be a usage refusal"
  assert_contains "$out" 'not a Bitbucket merge strategy' "the strategy refusal did not explain itself"

  set +e
  out=$(run_with_fakes "$dir" "$RESOLVER" pr-merge bitbucket '../etc' 12 squash 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "an invalid repository must be a usage refusal"

  set +e
  out=$(run_with_fakes "$dir" "$RESOLVER" pr-merge bitbucket "$BB_PATH" 0 squash 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "an invalid number must be a usage refusal"
  [ ! -s "$dir/curl-argv" ] || fail "a refused pr-merge still reached curl"

  out=$(FAKE_BB_MERGE_STATUS=202 FAKE_BB_MERGE_LOCATION="$TASK_LOCATION" FAKE_BB_MERGE_RETRY_AFTER=7 \
    run_with_fakes "$dir" "$RESOLVER" pr-merge bitbucket "$BB_PATH" 12 squash 2>&1) \
    || fail "a valid pr-merge failed"
  [ "$(printf '%s\n' "$out" | sed -n 1p)" = 'status=202' ] || fail "pr-merge line 1 is not the status"
  [ "$(printf '%s\n' "$out" | sed -n 2p)" = "location=$TASK_LOCATION" ] || fail "pr-merge line 2 is not the location"
  [ "$(printf '%s\n' "$out" | sed -n 3p)" = 'retry-after=7' ] || fail "pr-merge line 3 is not retry-after"
  assert_no_credential_leak "$out" "the pr-merge output"
  pass "pr-merge validates its identifiers and strategy before any request and reports the protocol headers"
}

# --- the fm-pr-merge.sh dispatch ---------------------------------------------

# A home with a task meta and guard stub so the real fm-pr-check.sh can record
# pr= on the way to the dispatched merge, as the entry point always does.
make_dispatch_home() {  # <case-name>
  local dir
  dir=$(make_case "$1")
  mkdir -p "$dir/home/state" "$dir/root/bin" "$dir/wt"
  cat > "$dir/root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/root/bin/fm-guard.sh"
  fm_write_meta "$dir/home/state/task-a.meta" \
    "window=fm-task-a" \
    "worktree=$dir/wt" \
    "kind=ship"
  printf '%s\n' "$dir"
}

run_dispatch() {  # <dir> <args...>
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    run_with_fakes "$dir" "$PR_MERGE" "$@"
}

test_dispatch_maps_gh_method_flags_to_bb_strategies() {
  local dir out rc
  dir=$(make_dispatch_home dispatch-mapping)
  set +e
  out=$(FAKE_BB_PR_BODY_1=$(pr_body OPEN) FAKE_BB_PR_BODY_2=$(pr_body OPEN) \
    FAKE_BB_PR_BODY_3=$(pr_body MERGED) \
    run_dispatch "$dir" task-a "$BB_URL" -- --merge 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "the dispatched bitbucket merge should succeed (got: $out)"
  assert_contains "$out" "merged: $BB_URL" "the dispatch did not report the confirmed merge"
  grep -qxF "pr=$BB_URL" "$dir/home/state/task-a.meta" \
    || fail "pr= was not recorded before the dispatched merge"
  grep -qF '"merge_strategy": "merge_commit"' "$dir/curl-argv" \
    || fail "--merge was not mapped to the merge_commit strategy"
  assert_no_credential_leak "$out" "the dispatch output"
  pass "fm-pr-merge maps gh-style method flags to Bitbucket strategies and records pr= first"
}

test_dispatch_refuses_unsupported_extra_args() {
  local dir out rc
  dir=$(make_dispatch_home dispatch-unsupported)
  set +e
  out=$(run_dispatch "$dir" task-a "$BB_URL" -- --delete-branch 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "an unforwardable extra argument must refuse"
  assert_contains "$out" 'not supported for a Bitbucket pull request merge' \
    "the refusal did not name the unsupported argument class"
  assert_no_grep "pr=$BB_URL" "$dir/home/state/task-a.meta" \
    "a refused merge still recorded pr="
  assert_no_grep 'request POST' "$dir/curl-argv" "a refused merge still sent a merge request"
  pass "fm-pr-merge refuses extra args it cannot honor on Bitbucket before recording anything"
}

# --- the capability-mismatch warnings ----------------------------------------

# A home whose registry grants merge on a Bitbucket clone, for the two warning
# sites. Echoes the case dir; the home is <dir>/home.
make_grant_home() {  # <case-name> <registry-flags>
  local dir home
  dir=$(make_case "$1")
  home="$dir/home"
  mkdir -p "$home/data" "$home/projects"
  printf '%s\n' "- hexbattle [no-mistakes $2] - x (added 2026-07-22)" > "$home/data/projects.md"
  git init -q "$home/projects/hexbattle"
  git -C "$home/projects/hexbattle" remote add origin "https://bitbucket.org/$BB_PATH.git"
  printf '%s\n' "$dir"
}

run_project_mode() {  # <dir> <args...>
  local dir=$1
  shift
  FM_HOME="$dir/home" run_with_fakes "$dir" "$PROJECT_MODE" "$@"
}

test_project_mode_warns_when_merge_is_granted_but_incapable() {
  local dir err
  dir=$(make_grant_home grant-incapable '+yolo:merge')

  err=$({ FAKE_BB_USER_STATUS=403 FAKE_BB_USER_BODY="$READONLY_403_BODY" \
    run_project_mode "$dir" hexbattle --grant merge >/dev/null; } 2>&1) \
    || fail "the merge grant answer changed: the warning must be advisory"
  assert_contains "$err" 'cannot merge' "no warning at merge-grant resolution"
  assert_contains "$err" 'pull-request write' "the warning did not name the missing scope"
  assert_no_credential_leak "$err" "the project-mode warning"

  # A capable credential resolves the same grant silently.
  err=$({ FAKE_BB_USER_STATUS=403 FAKE_BB_USER_BODY="$WRITE_403_BODY" \
    run_project_mode "$dir" hexbattle --grant merge >/dev/null; } 2>&1) \
    || fail "a capable credential failed the merge grant query"
  [ -z "$err" ] || fail "a capable credential still warned: $err"

  # An unprovable scope list must not warn speculatively.
  err=$({ run_project_mode "$dir" hexbattle --grant merge >/dev/null; } 2>&1) \
    || fail "an unknown capability failed the merge grant query"
  [ -z "$err" ] || fail "an unknown capability warned speculatively: $err"

  # Bootstrap's scan suppression: no probe request, no warning.
  : > "$dir/curl-argv"
  err=$({ FM_MERGE_CAPABILITY_PROBE=0 FAKE_BB_USER_STATUS=403 FAKE_BB_USER_BODY="$READONLY_403_BODY" \
    run_project_mode "$dir" hexbattle --grant merge >/dev/null; } 2>&1) \
    || fail "the suppressed probe changed the grant answer"
  [ -z "$err" ] || fail "a suppressed probe still warned: $err"
  [ ! -s "$dir/curl-argv" ] || fail "a suppressed probe still made a request"

  # Another grant's query never probes.
  dir=$(make_grant_home grant-findings '+yolo:findings,merge')
  : > "$dir/curl-argv"
  err=$({ FAKE_BB_USER_STATUS=403 FAKE_BB_USER_BODY="$READONLY_403_BODY" \
    run_project_mode "$dir" hexbattle --grant findings >/dev/null; } 2>&1) \
    || fail "the findings grant query failed"
  [ -z "$err" ] || fail "a findings query warned about merge capability: $err"
  [ ! -s "$dir/curl-argv" ] || fail "a findings query probed the credential"
  pass "merge-grant resolution warns exactly when the credential provably cannot merge"
}

test_project_mode_ungranted_merge_stays_silent() {
  local dir err rc
  dir=$(make_grant_home no-merge-grant '+yolo:findings')
  : > "$dir/curl-argv"
  set +e
  err=$({ FAKE_BB_USER_STATUS=403 FAKE_BB_USER_BODY="$READONLY_403_BODY" \
    run_project_mode "$dir" hexbattle --grant merge >/dev/null; } 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "an ungranted merge must still answer not-granted"
  [ -z "$err" ] || fail "a read-only credential with no merge grant warned: $err"
  [ ! -s "$dir/curl-argv" ] || fail "an ungranted merge query probed the credential"
  pass "a read-only credential with no merge grant stays silent - the healthy fleet shape"
}

make_bootstrap_tools() {  # <fakebin>
  local fakebin=$1
  fm_fake_exit0 "$fakebin" tmux node gh-axi chrome-devtools-axi lavish-axi quota-axi gh
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
fi
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && printf '%s\n' 'no-mistakes version v1.31.2'
exit 0
SH
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  --version:*) printf '%s\n' 0.1.1 ;;
  update:--help) printf '%s\n' '  --archive-body' ;;
  mv:--help) printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>' ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/no-mistakes" "$fakebin/tasks-axi"
}

run_bootstrap() {  # <dir>
  local dir=$1
  mkdir -p "$dir/home/config"
  printf '%s\n' manual > "$dir/home/config/backlog-backend"
  make_bootstrap_tools "$dir/fakebin"
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/home" FM_BOOTSTRAP_DETECT_ONLY=1 \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    run_with_fakes "$dir" "$BOOTSTRAP"
}

test_bootstrap_warns_on_merge_grant_without_capability() {
  local dir out
  dir=$(make_grant_home bootstrap-incapable '+yolo:merge')
  out=$(FAKE_BB_USER_STATUS=403 FAKE_BB_USER_BODY="$READONLY_403_BODY" run_bootstrap "$dir")
  assert_contains "$out" 'FORGE_CREDENTIAL: bitbucket:' \
    "session start did not report the capability mismatch"
  assert_contains "$out" 'hexbattle' "the mismatch line did not name the granting project"
  assert_contains "$out" 'cannot merge' "the mismatch line did not state the consequence"
  assert_no_credential_leak "$out" "the bootstrap capability diagnostic"

  # A capable credential with the same grant stays silent.
  out=$(FAKE_BB_USER_STATUS=403 FAKE_BB_USER_BODY="$WRITE_403_BODY" run_bootstrap "$dir")
  assert_not_contains "$out" 'cannot merge' "a capable credential was reported as incapable"
  pass "session start reports a merge grant the credential cannot honor, once per start while it persists"
}

test_bootstrap_stays_silent_with_no_merge_grants() {
  local dir out
  dir=$(make_grant_home bootstrap-healthy '+yolo:findings')
  out=$(FAKE_BB_USER_STATUS=403 FAKE_BB_USER_BODY="$READONLY_403_BODY" run_bootstrap "$dir")
  assert_not_contains "$out" 'cannot merge' \
    "a read-only credential with no merge grants produced a capability line"
  assert_not_contains "$out" 'FORGE_CREDENTIAL' \
    "a healthy read-only home produced a credential diagnostic"
  pass "a read-only credential with no merge grants anywhere stays silent at session start"
}

test_200_confirms_merged_before_reporting_success
test_200_without_merged_readback_refuses_success
test_202_polls_task_status_to_merged
test_202_task_failure_reports_the_reason
test_202_still_pending_after_bound_is_retry_later
test_202_foreign_location_is_refused
test_409_reports_without_blind_retry
test_429_backs_off_and_retries
test_429_exhausted_is_retry_later
test_555_settles_by_reading_the_state_back
test_unanswered_merge_request_settles_by_reading_back
test_red_build_refuses_before_any_merge_request
test_scope_refusal_names_the_missing_scope
test_strategy_not_permitted_refuses_naming_the_list
test_explicit_strategy_reaches_the_request
test_already_merged_reports_without_a_request
test_merge_capable_reads_the_real_scope_list
test_pr_merge_subcommand_validates_before_any_request
test_dispatch_maps_gh_method_flags_to_bb_strategies
test_dispatch_refuses_unsupported_extra_args
test_project_mode_warns_when_merge_is_granted_but_incapable
test_project_mode_ungranted_merge_stays_silent
test_bootstrap_warns_on_merge_grant_without_capability
test_bootstrap_stays_silent_with_no_merge_grants

printf '%s\n' "fm-bb-pr-merge: all tests passed"
