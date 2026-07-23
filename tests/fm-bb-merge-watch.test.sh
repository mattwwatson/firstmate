#!/usr/bin/env bash
# Behavior tests for the Bitbucket merge watch and build results: canonical
# URL parsing and provider dispatch, the byte-static bin/fm-bb-pr-poll.sh
# verdicts, arm-time verification in bin/fm-pr-check.sh, watcher template
# selection with the one-shot warning dedupe, bin/fm-bb-build-status.sh
# verdicts, the merge path's not-green refusal, and the migration's
# per-provider template set.
#
# Every case runs against a DUMMY credential pair through a fake keychain tool
# and a fake curl, so no case needs a real token or the network, and every
# captured stream is asserted free of the dummy pair - the same leak assertion
# tests/fm-forge-credential.test.sh carries.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$ROOT/bin/fm-pr-lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
MIGRATE="$ROOT/bin/fm-pr-check-migrate.sh"
BB_POLL="$ROOT/bin/fm-bb-pr-poll.sh"
BB_BUILD="$ROOT/bin/fm-bb-build-status.sh"
GH_POLL="$ROOT/bin/fm-pr-poll.sh"
RESOLVER="$ROOT/bin/fm-forge-credential.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-bb-merge-watch)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

DUMMY_USER='dummy@example.invalid'
DUMMY_SECRET='dummy-token-value'

BB_URL='https://bitbucket.org/mattw_watson/hexbattle/pull-requests/12'
BB_PATH=mattw_watson/hexbattle
BB_NUMBER=12

SHORT_HEAD=68443e3d6f3d
FULL_HEAD=68443e3d6f3d12efa5dbb361aab24c768df5240e

pr_body() {  # <state>
  printf '{"state": "%s", "source": {"commit": {"hash": "%s"}}}' "$1" "$SHORT_HEAD"
}

GREEN_STATUSES='{"values": [{"key": "ci/build", "state": "SUCCESSFUL", "updated_on": "2026-07-21T10:00:00+00:00"}], "next": null}'

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

state_snapshot() {
  local state=$1 file
  (
    cd "$state" || exit 1
    find . \( -type f -o -type l \) -print | LC_ALL=C sort | while IFS= read -r file; do
      printf 'file %s %s ' "$file" "$(file_mode "$file")"
      shasum -a 256 "$file" | awk '{print $1}'
    done
  )
}

# A case dir with the fake toolchain: a fake `security` answering the
# firstmate keychain services with the dummy pair, a fake `curl` answering
# each Bitbucket endpoint from FAKE_BB_* bodies, gh/glab stubs for GitHub
# fixture polls, a fm-guard stub, and a PATH copy of the real resolver for the
# poll's manual sidecar-driven mode.
make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/home/state" "$dir/wt" "$fakebin" "$dir/root/bin"
  cat > "$dir/root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
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
  # The fake curl reproduces the real contract the resolver depends on: the
  # config arrives on stdin (asserted to be the Basic pair, without recording
  # it), the body lands in --output, and the HTTP status goes to stdout.
  # FAKE_CURL_STATUS answers every request; FAKE_CURL_FAIL_MATCH answers
  # FAKE_CURL_FAIL_STATUS for just the requests whose argv contains that
  # substring, so one run can hold a failing endpoint alongside a working one.
  cat > "$fakebin/curl" <<SH
#!/usr/bin/env bash
argv_all=\$*
config=\$(cat)
if [ "\$config" = 'user = "$DUMMY_USER:$DUMMY_SECRET"' ]; then
  printf '%s\n' AUTH_PRESENT >> "\${FAKE_CURL_STDIN_LOG:-/dev/null}"
else
  printf '%s\n' AUTH_ABSENT >> "\${FAKE_CURL_STDIN_LOG:-/dev/null}"
fi
printf '%s\n' "\$argv_all" >> "\${FAKE_CURL_ARGV_LOG:-/dev/null}"
out=
url=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --output) out=\$2; shift 2 ;;
    https://*) url=\$1; shift ;;
    *) shift ;;
  esac
done
if [ -n "\${FAKE_CURL_EXIT:-}" ] && [ "\${FAKE_CURL_EXIT}" -ne 0 ]; then
  printf '%s' 000
  exit "\$FAKE_CURL_EXIT"
fi
status=\${FAKE_CURL_STATUS:-200}
if [ -n "\${FAKE_CURL_FAIL_MATCH:-}" ]; then
  case "\$argv_all" in
    *"\$FAKE_CURL_FAIL_MATCH"*) status=\${FAKE_CURL_FAIL_STATUS:-500} ;;
  esac
fi
case "\$url" in
  *"/statuses"*) body=\${FAKE_BB_STATUSES_BODY:-'$GREEN_STATUSES'} ;;
  *"/commit/"*) body=\${FAKE_BB_COMMIT_BODY:-'{"hash": "$FULL_HEAD"}'} ;;
  *"/pullrequests/"*) body=\${FAKE_BB_PR_BODY:-'{"state": "OPEN", "source": {"commit": {"hash": "$SHORT_HEAD"}}}'} ;;
  *) body='{}' ;;
esac
[ -z "\$out" ] || printf '%s' "\$body" > "\$out"
printf '%s' "\$status"
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" state "*) printf '%s\n' "${FM_TEST_GH_STATE:-OPEN}" ;;
  *" headRefOid "*) printf '%s\n' "${FM_TEST_GH_HEAD:-0123456789abcdef0123456789abcdef01234567}" ;;
esac
SH
  cat > "$fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$dir/gh-axi.log'
exit 0
SH
  cp "$RESOLVER" "$fakebin/fm-forge-credential.sh"
  chmod +x "$dir/root/bin/fm-guard.sh" "$fakebin/security" "$fakebin/curl" \
    "$fakebin/gh" "$fakebin/gh-axi" "$fakebin/fm-forge-credential.sh"
  : > "$dir/gh-axi.log"
  : > "$dir/curl-argv"
  : > "$dir/curl-stdin"
  printf '%s\n' "$dir"
}

# Run a target with the fake toolchain. The FAKE_* knobs are read from the
# caller's environment with defaults, so a case sets only what it changes.
run_with_fakes() {  # <dir> <command...>
  local dir=$1
  shift
  FM_FORGE_KEYCHAIN_TOOL_OVERRIDE="$dir/fakebin/security" \
    FAKE_KEYCHAIN_USER="${FAKE_KEYCHAIN_USER:-ok}" \
    FAKE_KEYCHAIN_SECRET="${FAKE_KEYCHAIN_SECRET:-ok}" \
    FAKE_CURL_ARGV_LOG="$dir/curl-argv" \
    FAKE_CURL_STDIN_LOG="$dir/curl-stdin" \
    FAKE_CURL_STATUS="${FAKE_CURL_STATUS:-200}" \
    FAKE_CURL_EXIT="${FAKE_CURL_EXIT:-0}" \
    FAKE_CURL_FAIL_MATCH="${FAKE_CURL_FAIL_MATCH:-}" \
    FAKE_CURL_FAIL_STATUS="${FAKE_CURL_FAIL_STATUS:-500}" \
    FAKE_BB_PR_BODY="${FAKE_BB_PR_BODY:-}" \
    FAKE_BB_COMMIT_BODY="${FAKE_BB_COMMIT_BODY:-}" \
    FAKE_BB_STATUSES_BODY="${FAKE_BB_STATUSES_BODY:-}" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$@"
}

run_check_entry() {  # <dir> <task-id> <url>
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    run_with_fakes "$dir" "$PR_CHECK" "$@"
}

run_merge_entry() {  # <dir> <task-id> <url>
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    run_with_fakes "$dir" "$PR_MERGE" "$@"
}

run_watcher_bounded() {  # <home-dir> <fakebin-dir>
  local home=$1 fakebin=$2
  perl -e 'my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } local $SIG{ALRM}=sub { kill "TERM", $pid; waitpid $pid, 0; exit 124 }; alarm 10; waitpid $pid, 0; alarm 0; exit($? >> 8)' \
    env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=5 \
      FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
      FM_FORGE_KEYCHAIN_TOOL_OVERRIDE="${home%/home}/fakebin/security" \
      FAKE_KEYCHAIN_USER="${FAKE_KEYCHAIN_USER:-ok}" \
      FAKE_KEYCHAIN_SECRET="${FAKE_KEYCHAIN_SECRET:-ok}" \
      FAKE_CURL_STATUS="${FAKE_CURL_STATUS:-200}" \
      FAKE_CURL_EXIT=0 \
      FAKE_BB_PR_BODY="${FAKE_BB_PR_BODY:-}" \
      PATH="$fakebin:$BASE_PATH" "$WATCH"
}

assert_no_credential_leak() {  # <text> <label>
  assert_not_contains "$1" "$DUMMY_SECRET" "$2 leaked the token value"
  assert_not_contains "$1" "$DUMMY_USER" "$2 leaked the account value"
}

write_task_meta() {  # <dir> <id>
  local dir=$1 id=$2
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fm-$id" \
    "worktree=$dir/wt" \
    "kind=ship"
}

arm_bb_fixture() {  # <dir> <id>  (arms through the real entry point)
  local dir=$1 id=$2
  write_task_meta "$dir" "$id"
  FAKE_BB_PR_BODY=$(pr_body OPEN) run_check_entry "$dir" "$id" "$BB_URL" >/dev/null 2>/dev/null \
    || fail "could not arm the Bitbucket poll fixture"
}

test_bitbucket_url_parsing() {
  local url
  fm_pr_url_parse "$BB_URL" || fail "canonical Bitbucket PR URL was refused"
  [ "$FM_PR_PROVIDER" = bitbucket ] || fail "provider was not bitbucket"
  [ "$FM_PR_HOST" = bitbucket.org ] || fail "host was not bitbucket.org"
  [ "$FM_PR_PATH" = "$BB_PATH" ] || fail "path was not workspace/repository"
  [ "$FM_PR_NUMBER" = "$BB_NUMBER" ] || fail "number was not parsed"
  [ -z "$FM_PR_OWNER" ] && [ -z "$FM_PR_REPO" ] \
    || fail "bitbucket parse set the GitHub-only owner/repo fields"

  fm_pr_url_parse 'https://bitbucket.org/w0rk-space_1/repo.name-x/pull-requests/345' \
    || fail "valid workspace and repository slug characters were refused"

  # shellcheck disable=SC2016 # literal rejected URL bytes are parser test data
  local invalid=(
    'https://bitbucket.org/mattw_watson/hexbattle/pull/12'
    'https://bitbucket.org/mattw_watson/hexbattle/pullrequests/12'
    'https://bitbucket.org/mattw_watson/hexbattle/pull-requests/0'
    'https://bitbucket.org/mattw_watson/hexbattle/pull-requests/012'
    'https://bitbucket.org/mattw_watson/hexbattle/pull-requests/12/'
    'https://bitbucket.org/mattw_watson/hexbattle/pull-requests/12?x=1'
    'https://bitbucket.org/MattW/hexbattle/pull-requests/12'
    'https://bitbucket.org/mattw.watson/hexbattle/pull-requests/12'
    'https://bitbucket.org/mattw_watson/hex/battle/pull-requests/12'
    'https://bitbucket.org/mattw_watson/./pull-requests/12'
    'https://bitbucket.org/mattw_watson/../pull-requests/12'
    'https://bitbucket.org/mattw_watson/hexbattle/pull-requests/'
    'https://bitbucket.org/hexbattle/pull-requests/12'
    'http://bitbucket.org/mattw_watson/hexbattle/pull-requests/12'
    'https://user@bitbucket.org/mattw_watson/hexbattle/pull-requests/12'
    'https://bitbucket.org:443/mattw_watson/hexbattle/pull-requests/12'
    'https://bitbucket.org/mattw_watson/hexbattle/pull-requests/12#comment'
    'https://bitbucket.org/g/p/-/merge_requests/1'
  )
  for url in "${invalid[@]}"; do
    if fm_pr_url_parse "$url"; then
      fail "non-canonical URL was accepted: $url"
    fi
  done

  # 62-character repository slugs are Bitbucket's cap; 63 must be refused.
  local repo62 repo63
  repo62=$(printf 'r%.0s' $(seq 1 62))
  repo63=$(printf 'r%.0s' $(seq 1 63))
  fm_pr_url_parse "https://bitbucket.org/w/$repo62/pull-requests/1" \
    || fail "a 62-character repository slug was refused"
  if fm_pr_url_parse "https://bitbucket.org/w/$repo63/pull-requests/1"; then
    fail "a 63-character repository slug was accepted"
  fi
  pass "bitbucket URL parsing accepts the canonical grammar and refuses everything else"
}

test_template_selection() {
  local dir state
  fm_pr_poll_template_for_provider "$ROOT/bin" github \
    || fail "github template selection failed"
  [ "$FM_PR_POLL_TASK_TEMPLATE" = "$GH_POLL" ] || fail "github selected the wrong template"
  fm_pr_poll_template_for_provider "$ROOT/bin" gitlab \
    || fail "gitlab template selection failed"
  [ "$FM_PR_POLL_TASK_TEMPLATE" = "$GH_POLL" ] || fail "gitlab selected the wrong template"
  fm_pr_poll_template_for_provider "$ROOT/bin" bitbucket \
    || fail "bitbucket template selection failed"
  [ "$FM_PR_POLL_TASK_TEMPLATE" = "$BB_POLL" ] || fail "bitbucket selected the wrong template"
  if fm_pr_poll_template_for_provider "$ROOT/bin" other; then
    fail "an unknown provider selected a template"
  fi
  [ -z "$FM_PR_POLL_TASK_TEMPLATE" ] || fail "a refused selection left a template set"

  dir=$(make_case template-selection)
  state="$dir/home/state"
  arm_bb_fixture "$dir" task-bb
  fm_write_meta "$state/task-gh.meta" 'window=fm-task-gh' 'pr=https://github.com/o/r/pull/10'
  fm_pr_poll_prepare "$state" task-gh github https://github.com/o/r/pull/10 github.com o/r 10 "$GH_POLL" \
    || fail "could not prepare the github fixture poll"
  fm_pr_poll_publish_prepared || fail "could not publish the github fixture poll"

  fm_pr_poll_task_template "$state" task-bb "$ROOT/bin" \
    || fail "task template selection failed for the armed bitbucket poll"
  [ "$FM_PR_POLL_TASK_TEMPLATE" = "$BB_POLL" ] || fail "armed bitbucket poll selected the wrong template"
  fm_pr_poll_artifacts_valid "$state" task-bb "$FM_PR_POLL_TASK_TEMPLATE" \
    || fail "armed bitbucket poll did not validate against its own template"
  fm_pr_poll_task_template "$state" task-gh "$ROOT/bin" \
    || fail "task template selection failed for the armed github poll"
  [ "$FM_PR_POLL_TASK_TEMPLATE" = "$GH_POLL" ] || fail "armed github poll selected the wrong template"
  fm_pr_poll_artifacts_valid "$state" task-gh "$FM_PR_POLL_TASK_TEMPLATE" \
    || fail "armed github poll did not validate against its own template"
  if fm_pr_poll_task_template "$state" task-none "$ROOT/bin"; then
    fail "a task with no registration selected a template"
  fi
  if fm_pr_poll_artifacts_valid "$state" task-bb "$GH_POLL"; then
    fail "a bitbucket poll validated against the github template"
  fi
  pass "the registration's provider tag selects each poll's own byte-static template"
}

test_bb_poll_verdicts() {
  local dir out
  dir=$(make_case poll-verdicts)

  out=$(FAKE_BB_PR_BODY=$(pr_body MERGED) run_with_fakes "$dir" "$BB_POLL" --validated \
    bitbucket "$BB_URL" bitbucket.org "$BB_PATH" "$BB_NUMBER")
  [ "$out" = merged ] || fail "MERGED did not print exactly 'merged' (got: $out)"
  out=$(FAKE_BB_PR_BODY=$(pr_body DECLINED) run_with_fakes "$dir" "$BB_POLL" --validated \
    bitbucket "$BB_URL" bitbucket.org "$BB_PATH" "$BB_NUMBER")
  [ "$out" = declined ] || fail "DECLINED did not print exactly 'declined' (got: $out)"
  out=$(FAKE_BB_PR_BODY=$(pr_body SUPERSEDED) run_with_fakes "$dir" "$BB_POLL" --validated \
    bitbucket "$BB_URL" bitbucket.org "$BB_PATH" "$BB_NUMBER")
  [ "$out" = superseded ] || fail "SUPERSEDED did not print exactly 'superseded' (got: $out)"
  for body in "$(pr_body OPEN)" 'not json at all' '{"state": 7}' '{}'; do
    out=$(FAKE_BB_PR_BODY=$body run_with_fakes "$dir" "$BB_POLL" --validated \
      bitbucket "$BB_URL" bitbucket.org "$BB_PATH" "$BB_NUMBER")
    [ -z "$out" ] || fail "a non-terminal or unreadable state produced output: $out"
  done

  out=$(FAKE_CURL_STATUS=401 run_with_fakes "$dir" "$BB_POLL" --validated \
    bitbucket "$BB_URL" bitbucket.org "$BB_PATH" "$BB_NUMBER")
  [ "$out" = bitbucket-auth-missing ] || fail "HTTP 401 did not report the credential problem"
  out=$(FAKE_CURL_STATUS=403 run_with_fakes "$dir" "$BB_POLL" --validated \
    bitbucket "$BB_URL" bitbucket.org "$BB_PATH" "$BB_NUMBER")
  [ "$out" = bitbucket-auth-missing ] || fail "HTTP 403 did not report the credential problem"
  out=$(FAKE_KEYCHAIN_SECRET=absent run_with_fakes "$dir" "$BB_POLL" --validated \
    bitbucket "$BB_URL" bitbucket.org "$BB_PATH" "$BB_NUMBER" 2>&1)
  [ "$out" = bitbucket-auth-missing ] || fail "an absent credential did not report the credential problem"
  assert_no_credential_leak "$out" "the no-token poll output"
  out=$(FAKE_CURL_STATUS=404 run_with_fakes "$dir" "$BB_POLL" --validated \
    bitbucket "$BB_URL" bitbucket.org "$BB_PATH" "$BB_NUMBER")
  [ "$out" = bitbucket-pr-unreachable ] || fail "HTTP 404 did not report the invisible pull request"
  out=$(FAKE_CURL_EXIT=7 run_with_fakes "$dir" "$BB_POLL" --validated \
    bitbucket "$BB_URL" bitbucket.org "$BB_PATH" "$BB_NUMBER")
  [ -z "$out" ] || fail "an unreachable forge produced output instead of staying silent: $out"
  out=$(FAKE_CURL_STATUS=500 run_with_fakes "$dir" "$BB_POLL" --validated \
    bitbucket "$BB_URL" bitbucket.org "$BB_PATH" "$BB_NUMBER")
  [ -z "$out" ] || fail "an unexpected HTTP status produced output instead of staying silent: $out"
  pass "the bitbucket poll prints one exact verdict or warning line and is otherwise silent"
}

test_bb_poll_identity_revalidation() {
  local dir out
  dir=$(make_case poll-revalidation)

  # Each doctored identity must be refused BEFORE any request is made.
  local -a doctored=(
    "github $BB_URL bitbucket.org $BB_PATH $BB_NUMBER"
    "bitbucket $BB_URL github.com $BB_PATH $BB_NUMBER"
    "bitbucket $BB_URL bitbucket.org other_ws/hexbattle $BB_NUMBER"
    "bitbucket $BB_URL bitbucket.org $BB_PATH 13"
    "bitbucket https://bitbucket.org/other/repo/pull-requests/12 bitbucket.org $BB_PATH $BB_NUMBER"
    "bitbucket $BB_URL bitbucket.org UPPER/hexbattle $BB_NUMBER"
    "bitbucket $BB_URL bitbucket.org mattw_watson/hex/battle $BB_NUMBER"
  )
  local args
  for args in "${doctored[@]}"; do
    # shellcheck disable=SC2086 # deliberate word-splitting of fixture argv
    out=$(FAKE_BB_PR_BODY=$(pr_body MERGED) run_with_fakes "$dir" "$BB_POLL" --validated $args)
    [ -z "$out" ] || fail "doctored identity produced output: $args"
  done
  [ ! -s "$dir/curl-argv" ] || fail "a doctored identity reached the network"
  pass "doctored sidecar identities are refused before any request is made"
}

test_bb_poll_sidecar_mode() {
  local dir state out
  dir=$(make_case poll-sidecar)
  state="$dir/home/state"
  cp "$BB_POLL" "$state/task-a.check.sh"
  printf '%s\n%s\n%s\n%s\n%s\n' bitbucket "$BB_URL" bitbucket.org "$BB_PATH" "$BB_NUMBER" \
    > "$state/task-a.pr-poll"
  chmod 0600 "$state/task-a.check.sh" "$state/task-a.pr-poll"
  out=$(FAKE_BB_PR_BODY=$(pr_body MERGED) run_with_fakes "$dir" bash "$state/task-a.check.sh")
  [ "$out" = merged ] || fail "sidecar-driven mode did not report the merged pull request (got: $out)"
  printf '%s\n%s\n%s\n%s\n%s\n%s\n' bitbucket "$BB_URL" bitbucket.org "$BB_PATH" "$BB_NUMBER" extra \
    > "$state/task-a.pr-poll"
  out=$(FAKE_BB_PR_BODY=$(pr_body MERGED) run_with_fakes "$dir" bash "$state/task-a.check.sh")
  [ -z "$out" ] || fail "a sidecar with extra records produced output"
  pass "the bitbucket poll's sidecar-driven mode reads and revalidates its own record"
}

test_arm_time_verification_success() {
  local dir state out
  dir=$(make_case arm-success)
  state="$dir/home/state"
  write_task_meta "$dir" task-a
  out=$(FAKE_BB_PR_BODY=$(pr_body OPEN) run_check_entry "$dir" task-a "$BB_URL" 2>&1) \
    || fail "arming against a verified pull request failed: $out"
  assert_contains "$out" 'armed: state/task-a.check.sh' "arm did not report the armed check"
  assert_contains "$out" 'build: green' "arm did not surface the build verdict"
  assert_no_credential_leak "$out" "the arm output"
  cmp -s "$BB_POLL" "$state/task-a.check.sh" \
    || fail "the armed check is not byte-for-byte bin/fm-bb-pr-poll.sh"
  [ "$(file_mode "$state/task-a.check.sh")" = 600 ] || fail "armed check mode was not private"
  grep -qxF "pr=$BB_URL" "$state/task-a.meta" || fail "pr= was not recorded in task metadata"
  grep -qxF "pr_head=$FULL_HEAD" "$state/task-a.meta" \
    || fail "the abbreviated source head was not expanded to the full commit id"
  grep -qxF bitbucket "$state/task-a.pr-poll" || fail "the sidecar does not carry the provider tag"
  head -1 "$state/task-a.pr-poll-registration" | grep -qxF fm-pr-poll-registration-v2 \
    || fail "the registration is not a v2 record"
  fm_pr_poll_artifacts_valid "$state" task-a "$BB_POLL" \
    || fail "the armed poll did not validate against the bitbucket template"
  ! grep -rF "$DUMMY_SECRET" "$state" >/dev/null \
    || fail "a state artifact holds the credential value"
  pass "arming a bitbucket watch verifies the pull request, records the expanded head, and surfaces the build verdict"
}

test_arm_time_verification_refusals() {
  local dir state out rc
  dir=$(make_case arm-refusals)
  state="$dir/home/state"
  write_task_meta "$dir" task-a

  set +e
  out=$(FAKE_CURL_STATUS=404 run_check_entry "$dir" task-a "$BB_URL" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an invisible pull request was armed anyway"
  assert_contains "$out" 'cannot verify the Bitbucket pull request' \
    "the 404 refusal did not name the arm-time verification"
  assert_absent "$state/task-a.check.sh" "the 404 refusal left a runnable check"
  assert_absent "$state/task-a.pr-poll" "the 404 refusal left a sidecar"
  assert_no_grep 'pr=' "$state/task-a.meta" "the 404 refusal changed task metadata"

  set +e
  out=$(FAKE_KEYCHAIN_SECRET=absent run_check_entry "$dir" task-a "$BB_URL" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a missing credential was armed anyway"
  assert_contains "$out" 'firstmate-bitbucket-token' \
    "the no-token refusal did not name the missing keychain entry"
  assert_no_credential_leak "$out" "the no-token arm output"
  assert_absent "$state/task-a.check.sh" "the no-token refusal left a runnable check"

  set +e
  out=$(FAKE_CURL_STATUS=401 run_check_entry "$dir" task-a "$BB_URL" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a rejected credential was armed anyway"
  assert_no_credential_leak "$out" "the rejected-credential arm output"
  pass "arming refuses loudly when the pull request cannot be verified, leaving nothing armed"
}

test_arm_survives_statuses_hiccup() {
  local dir state out
  dir=$(make_case arm-statuses-hiccup)
  state="$dir/home/state"
  write_task_meta "$dir" task-a
  out=$(FAKE_BB_PR_BODY=$(pr_body OPEN) FAKE_CURL_FAIL_MATCH=/statuses FAKE_CURL_FAIL_STATUS=500 \
    run_check_entry "$dir" task-a "$BB_URL" 2>&1) \
    || fail "a statuses hiccup failed the arm: $out"
  assert_contains "$out" 'armed: state/task-a.check.sh' "arm did not complete through the hiccup"
  assert_contains "$out" 'build: unknown' "the failed build read was not surfaced as unknown"
  fm_pr_poll_artifacts_valid "$state" task-a "$BB_POLL" \
    || fail "the merge watch was not armed through the statuses hiccup"
  pass "a statuses hiccup surfaces an unknown build verdict without unarming the merge watch"
}

test_build_status_verdicts() {
  local dir out rc
  dir=$(make_case build-status)

  out=$(run_with_fakes "$dir" "$BB_BUILD" "$BB_URL")
  [ "$(printf '%s\n' "$out" | head -1)" = green ] || fail "an all-successful set was not green"
  assert_contains "$out" 'SUCCESSFUL ci/build' "the green detail line is missing"

  out=$(FAKE_BB_STATUSES_BODY='{"values": [{"key": "a", "state": "SUCCESSFUL", "updated_on": "2026-07-21T10:00:00+00:00"}, {"key": "b", "state": "FAILED", "updated_on": "2026-07-21T10:00:00+00:00"}]}' \
    run_with_fakes "$dir" "$BB_BUILD" "$BB_URL")
  [ "$(printf '%s\n' "$out" | head -1)" = red ] || fail "a failed build was not red"
  assert_contains "$out" 'FAILED b' "the red verdict does not name the failing build"

  out=$(FAKE_BB_STATUSES_BODY='{"values": [{"key": "a", "state": "STOPPED", "updated_on": "2026-07-21T10:00:00+00:00"}]}' \
    run_with_fakes "$dir" "$BB_BUILD" "$BB_URL")
  [ "$(printf '%s\n' "$out" | head -1)" = red ] || fail "a stopped build was not red"

  out=$(FAKE_BB_STATUSES_BODY='{"values": [{"key": "a", "state": "SUCCESSFUL", "updated_on": "2026-07-21T10:00:00+00:00"}, {"key": "b", "state": "INPROGRESS", "updated_on": "2026-07-21T10:00:00+00:00"}]}' \
    run_with_fakes "$dir" "$BB_BUILD" "$BB_URL")
  [ "$(printf '%s\n' "$out" | head -1)" = pending ] || fail "a running build was not pending"

  out=$(FAKE_BB_STATUSES_BODY='{"values": []}' run_with_fakes "$dir" "$BB_BUILD" "$BB_URL")
  [ "$out" = none ] || fail "an empty status set was not none"

  # Bitbucket keeps every status posted against the head, so an old FAILED
  # under a rerun key must not poison the verdict: only the latest per key is
  # judged, ordered by parsed timestamps across different offsets.
  out=$(FAKE_BB_STATUSES_BODY='{"values": [{"key": "a", "state": "FAILED", "updated_on": "2026-07-21T12:00:00+02:00"}, {"key": "a", "state": "SUCCESSFUL", "updated_on": "2026-07-21T11:00:00+00:00"}]}' \
    run_with_fakes "$dir" "$BB_BUILD" "$BB_URL")
  [ "$(printf '%s\n' "$out" | head -1)" = green ] \
    || fail "a green rerun did not supersede the older failure on the same key (got: $out)"

  set +e
  out=$(FAKE_BB_STATUSES_BODY='{"values": [{"key": "a", "state": "SUCCESSFUL"}], "next": "https://api.bitbucket.org/next-page"}' \
    run_with_fakes "$dir" "$BB_BUILD" "$BB_URL" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a paginated status set was judged from one page"
  assert_contains "$out" 'refusing to judge' "the pagination refusal did not explain itself"

  set +e
  out=$(FAKE_BB_STATUSES_BODY='{"values": [{"key": "a", "state": "GREENISH"}]}' \
    run_with_fakes "$dir" "$BB_BUILD" "$BB_URL" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unrecognised build state was judged anyway"

  set +e
  run_with_fakes "$dir" "$BB_BUILD" 'https://github.com/o/r/pull/1' 2>/dev/null
  rc=$?
  set -e
  expect_code 2 "$rc" "a non-bitbucket URL must be a usage refusal"
  pass "build status reads one page, judges the latest entry per key, and refuses what it cannot prove"
}

# The full 200/202/409/429/555 merge protocol is pinned by
# tests/fm-bb-pr-merge.test.sh; this case pins what the fm-pr-merge.sh entry
# point guarantees around it: not-green build verdicts refuse before any merge
# request exists, a green one dispatches to the Bitbucket merge protocol
# rather than gh-axi, and no 2xx shortcut can report success without a
# confirmed MERGED read-back.
test_merge_refuses_not_green_and_dispatches_green() {
  local dir out rc
  dir=$(make_case merge-gate)
  write_task_meta "$dir" task-a

  set +e
  out=$(FAKE_BB_STATUSES_BODY='{"values": [{"key": "ci", "state": "FAILED", "updated_on": "2026-07-21T10:00:00+00:00"}]}' \
    run_merge_entry "$dir" task-a "$BB_URL" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "merge-red"
  assert_contains "$out" 'failing builds' "the red refusal did not name the failure"
  assert_contains "$out" 'FAILED ci' "the red refusal did not name the failing build key"

  set +e
  out=$(FAKE_BB_STATUSES_BODY='{"values": [{"key": "ci", "state": "INPROGRESS", "updated_on": "2026-07-21T10:00:00+00:00"}]}' \
    run_merge_entry "$dir" task-a "$BB_URL" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "merge-pending"
  assert_contains "$out" 'still running' "the pending refusal did not explain itself"

  set +e
  out=$(FAKE_CURL_FAIL_MATCH=/statuses FAKE_CURL_FAIL_STATUS=401 \
    run_merge_entry "$dir" task-a "$BB_URL" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "merge-unreadable"
  assert_contains "$out" 'could not be read' "an unreadable verdict was not refused"
  assert_no_credential_leak "$out" "the merge refusal output"

  # Every refusal above must have happened before any merge request existed.
  ! grep -qF 'pullrequests/12/merge' "$dir/curl-argv" \
    || fail "a refused merge still sent a Bitbucket merge request"

  # A green pull request dispatches to the Bitbucket merge protocol. The fake
  # answers the POST with 200 and an OPEN pull request, so the confirmation
  # read-back must refuse to report success - the 2xx-shortcut defect guard.
  set +e
  out=$(run_merge_entry "$dir" task-a "$BB_URL" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "merge-green-unconfirmed"
  grep -qF 'pullrequests/12/merge' "$dir/curl-argv" \
    || fail "a green pull request did not reach the Bitbucket merge request"
  assert_contains "$out" 'refusing to report success' \
    "a 200 without a MERGED read-back was reported as success"
  grep -qxF "pr=$BB_URL" "$dir/home/state/task-a.meta" \
    || fail "the merge path did not record pr= before merging"
  assert_no_credential_leak "$out" "the merge dispatch output"

  [ ! -s "$dir/gh-axi.log" ] || fail "a bitbucket merge reached gh-axi"
  pass "the merge path refuses not-green verdicts before any request and dispatches green to the confirmed Bitbucket protocol"
}

test_watcher_selects_bb_template_and_wakes_merged() {
  local dir state rc
  dir=$(make_case watcher-merged)
  state="$dir/home/state"
  arm_bb_fixture "$dir" task-a
  rm -f "$state/.last-check"
  set +e
  FAKE_BB_PR_BODY=$(pr_body MERGED) run_watcher_bounded "$dir/home" "$dir/fakebin" \
    > "$dir/watch.out" 2> "$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "the watcher did not surface the merged bitbucket poll (rc=$rc)"
  [ "$(grep -c '^check: .*: merged$' "$dir/watch.out")" -eq 1 ] \
    || fail "the watcher did not convert the merged poll into exactly one wake"
  ! grep -q 'rejected unauthenticated state checks' "$dir/watch.out" \
    || fail "the armed bitbucket poll was rejected as unauthenticated"
  pass "the watcher validates a bitbucket poll against its own template and wakes on merged"
}

test_watcher_warns_once_on_lost_credential() {
  local dir state rc
  dir=$(make_case watcher-warn-once)
  state="$dir/home/state"
  arm_bb_fixture "$dir" task-a

  rm -f "$state/.last-check"
  set +e
  FAKE_KEYCHAIN_SECRET=absent run_watcher_bounded "$dir/home" "$dir/fakebin" \
    > "$dir/watch1.out" 2> "$dir/watch1.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "the watcher did not surface the lost credential (rc=$rc)"
  grep -q '^check: .*: bitbucket-auth-missing$' "$dir/watch1.out" \
    || fail "the first credential warning did not wake"
  assert_present "$state/task-a.bb-poll-warned.auth" "the warning left no one-shot marker"

  rm -f "$state/.last-check"
  set +e
  FAKE_KEYCHAIN_SECRET=absent run_watcher_bounded "$dir/home" "$dir/fakebin" \
    > "$dir/watch2.out" 2> "$dir/watch2.err"
  rc=$?
  set -e
  expect_code 124 "$rc" "an already-warned credential problem must not wake again"
  ! grep -q bitbucket-auth-missing "$dir/watch2.out" \
    || fail "the credential warning woke a second time"
  assert_no_credential_leak "$(cat "$dir/watch1.out" "$dir/watch1.err" "$dir/watch2.out" "$dir/watch2.err")" \
    "the watcher warning output"
  pass "a lost credential wakes firstmate once per task, not every poll cycle"
}

test_migration_rebuilds_bb_and_leaves_github_untouched() {
  local dir state before after rc
  dir=$(make_case migration-template-set)
  state="$dir/home/state"

  # A healthy armed GitHub poll must ride through the migration byte-identical.
  fm_write_meta "$state/task-gh.meta" 'window=fm-task-gh' 'pr=https://github.com/o/r/pull/10'
  fm_pr_poll_prepare "$state" task-gh github https://github.com/o/r/pull/10 github.com o/r 10 "$GH_POLL" \
    || fail "could not prepare the github fixture poll"
  fm_pr_poll_publish_prepared || fail "could not publish the github fixture poll"

  # A legacy Bitbucket check (arbitrary bytes, canonical pr= in metadata) must
  # be quarantined and rebuilt against the bitbucket template, never run.
  fm_write_meta "$state/task-bb.meta" 'window=fm-task-bb' "pr=$BB_URL"
  printf 'legacy check bytes\n' > "$state/task-bb.check.sh"

  before=$(state_snapshot "$state" | grep task-gh)
  set +e
  FM_HOME="$dir/home" PATH="$BASE_PATH" "$MIGRATE" > "$dir/migrate.out" 2> "$dir/migrate.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "migration failed: $(cat "$dir/migrate.err")"
  cmp -s "$BB_POLL" "$state/task-bb.check.sh" \
    || fail "the legacy bitbucket poll was not rebuilt from the bitbucket template"
  fm_pr_poll_artifacts_valid "$state" task-bb "$BB_POLL" \
    || fail "the rebuilt bitbucket poll is not canonical"
  after=$(state_snapshot "$state" | grep task-gh)
  [ "$before" = "$after" ] || fail "migration changed an already-canonical github poll"
  grep -q 'canonical polls rebuilt and armed' "$dir/migrate.out" \
    || fail "migration did not report the rebuild"
  pass "migration rebuilds a legacy bitbucket poll from its own template without touching github polls"
}

test_bb_poll_contains_no_secret_machinery() {
  # The poll must never read the keychain or hold a token itself; the resolver
  # is its only credential path, and nothing in it may print a token. These are
  # source assertions in the spirit of the suite's gitlab.com check.
  ! grep -qF 'find-generic-password' "$BB_POLL" \
    || fail "the bitbucket poll reads the keychain directly"
  ! grep -qE '\$\{[A-Za-z_]*TOKEN' "$BB_POLL" \
    || fail "the bitbucket poll expands a token variable"
  grep -qF -- '--validated' "$BB_POLL" || fail "the bitbucket poll lost its validated argv contract"
  pass "the bitbucket poll holds no credential machinery of its own"
}

test_bitbucket_url_parsing
test_template_selection
test_bb_poll_verdicts
test_bb_poll_identity_revalidation
test_bb_poll_sidecar_mode
test_arm_time_verification_success
test_arm_time_verification_refusals
test_arm_survives_statuses_hiccup
test_build_status_verdicts
test_merge_refuses_not_green_and_dispatches_green
test_watcher_selects_bb_template_and_wakes_merged
test_watcher_warns_once_on_lost_credential
test_migration_rebuilds_bb_and_leaves_github_untouched
test_bb_poll_contains_no_secret_machinery

echo "fm-bb-merge-watch: all tests passed"
