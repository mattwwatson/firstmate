#!/usr/bin/env bash
# Behavior tests for fm-forge-credential.sh and the bootstrap detection built on
# it.
#
# The resolver is the only thing between an unattended poll and a forge, so the
# properties pinned here are the ones whose absence caused real incidents:
#   - a complete pair resolves, and a half-resolved one never reaches a request
#   - each refusal names WHICH requirement failed, with its own exit code, so
#     "no credential" is never confused with "credential rejected"
#   - the pair reaches curl through a config on stdin, never argv, and no
#     diagnostic, output stream, or error path can emit its value
#   - the resolver reads the keychain itself and never no-mistakes' separate
#     write-capable entry
# Every case runs against a DUMMY pair through a fake keychain tool and a fake
# curl, so the suite needs no real credential and works on Linux CI.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RESOLVER="$ROOT/bin/fm-forge-credential.sh"
TMP_ROOT=$(fm_test_tmproot fm-forge-credential-tests)

# The dummy pair. Nothing in the suite may print these, exactly as nothing in
# production may print the real ones; the leak assertions below check for them
# in every captured stream.
DUMMY_USER='dummy@example.invalid'
DUMMY_SECRET='dummy-token-value'

# A fake `security` that answers only the firstmate-specific services. Each
# service's behavior is set per case through FAKE_KEYCHAIN_<half>:
#   ok      - return the dummy value
#   absent  - exit non-zero, as a real keychain does for a missing entry
#   empty   - return an empty value
#   newline - return a value carrying an embedded line break
#   stall   - never answer, as a real keychain does when the item's access
#             control raises a confirmation dialog no unattended session can
#             answer; this is what the store watchdog exists for
make_fake_keychain() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/security" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = find-generic-password ] || exit 1
service=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -s) service=\$2; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' "\$service" >> "\${FAKE_KEYCHAIN_LOG:-/dev/null}"
case "\$service" in
  firstmate-bitbucket-email) mode=\${FAKE_KEYCHAIN_USER:-ok}; value='$DUMMY_USER' ;;
  firstmate-bitbucket-token) mode=\${FAKE_KEYCHAIN_SECRET:-ok}; value='$DUMMY_SECRET' ;;
  *) exit 44 ;;
esac
case "\$mode" in
  ok) printf '%s\n' "\$value" ;;
  absent) exit 44 ;;
  empty) printf '\n' ;;
  newline) printf '%s\noutput = /tmp/fm-forge-injected\n' "\$value" ;;
  colon) printf 'user:with:colons\n' ;;
  stall) exec sleep 20 ;;
esac
SH
  chmod +x "$dir/security"
  printf '%s\n' "$dir/security"
}

# A fake curl that records HOW it was called without ever recording the
# credential: it writes the literal argv it received (asserted credential-free)
# and a boolean for whether the expected Basic-auth config arrived on stdin.
# FAKE_CURL_STATUS sets the HTTP status it reports; FAKE_CURL_EXIT makes it fail
# like a transport error; FAKE_CURL_404_MATCH answers 404 for just the requests
# whose argv contains that substring, so one run can hold a repository the
# credential cannot see alongside one it can.
make_fake_curl() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/curl" <<SH
#!/usr/bin/env bash
argv_log=\${FAKE_CURL_ARGV_LOG:-/dev/null}
stdin_log=\${FAKE_CURL_STDIN_LOG:-/dev/null}
argv_all=\$*
printf '%s\n' "\$*" >> "\$argv_log"
config=\$(cat)
if [ "\$config" = 'user = "$DUMMY_USER:$DUMMY_SECRET"' ]; then
  printf '%s\n' AUTH_PRESENT >> "\$stdin_log"
else
  printf '%s\n' AUTH_ABSENT >> "\$stdin_log"
fi
out=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --output) out=\$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -z "\$out" ] || printf '%s\n' '{"fake":"body"}' > "\$out"
if [ -n "\${FAKE_CURL_EXIT:-}" ] && [ "\${FAKE_CURL_EXIT}" -ne 0 ]; then
  printf '%s' 000
  exit "\$FAKE_CURL_EXIT"
fi
if [ -n "\${FAKE_CURL_404_MATCH:-}" ]; then
  case "\$argv_all" in
    *"\$FAKE_CURL_404_MATCH"*) printf '%s' 404; exit 0 ;;
  esac
fi
printf '%s' "\${FAKE_CURL_STATUS:-200}"
SH
  chmod +x "$dir/curl"
}

# A fresh case dir with fake tools installed. mktemp rather than a counter: this
# runs inside a command substitution, so a counter would increment in a subshell
# and silently hand every case the same directory.
new_case() {
  local dir
  mkdir -p "$TMP_ROOT"
  dir=$(mktemp -d "$TMP_ROOT/case.XXXXXX")
  mkdir -p "$dir/bin"
  make_fake_keychain "$dir/bin" >/dev/null
  make_fake_curl "$dir/bin"
  printf '%s\n' "$dir"
}

# Run the resolver with the fake toolchain. Echoes "<exit>|<stdout>|<stderr>".
run_resolver() {  # <case-dir> <args...>
  local dir=$1 out err status
  shift
  err="$dir/stderr"
  out=$(PATH="$dir/bin:$PATH" \
    FM_FORGE_KEYCHAIN_TOOL_OVERRIDE="$dir/bin/security" \
    FAKE_KEYCHAIN_USER="${FAKE_KEYCHAIN_USER:-ok}" \
    FAKE_KEYCHAIN_SECRET="${FAKE_KEYCHAIN_SECRET:-ok}" \
    FAKE_KEYCHAIN_LOG="$dir/keychain-services" \
    FAKE_CURL_ARGV_LOG="$dir/curl-argv" \
    FAKE_CURL_STDIN_LOG="$dir/curl-stdin" \
    FAKE_CURL_STATUS="${FAKE_CURL_STATUS:-200}" \
    FAKE_CURL_EXIT="${FAKE_CURL_EXIT:-0}" \
    FM_FORGE_CREDENTIAL_TIMEOUT="${FM_FORGE_CREDENTIAL_TIMEOUT:-}" \
    FM_FORGE_KEYCHAIN_TIMEOUT="${FM_FORGE_KEYCHAIN_TIMEOUT:-}" \
    "$RESOLVER" "$@" 2>"$err")
  status=$?
  printf '%s|%s|%s' "$status" "$out" "$(cat "$err")"
}

# Every captured stream must be free of both halves of the pair. This is the
# assertion that would have caught the real leak: a presence check written as
# ${VAR:+SET}${VAR:-UNSET} prints the value whenever the variable is set.
assert_no_credential_leak() {  # <text> <label>
  assert_not_contains "$1" "$DUMMY_SECRET" "$2 leaked the token value"
  assert_not_contains "$1" "$DUMMY_USER" "$2 leaked the account value"
}

field() {  # <record> <1=exit|2=stdout|3=stderr>
  printf '%s' "$1" | cut -d'|' -f"$2"
}

# A permanent negative control for the guard above, not a one-off manual
# mutation. assert_not_contains passes trivially on an empty haystack, so every
# leak assertion in this file would keep passing if a refactor ever stopped
# capturing the stream it is handed - the suite would look green while proving
# nothing. This case seeds a haystack with each half of the dummy pair in turn
# and requires the guard to REJECT it, so the leak assertion can never silently
# become vacuous. `fail` exits, hence the subshell: a guard that fires makes it
# exit non-zero, and a guard that has gone vacuous makes it exit zero.
test_the_leak_guard_can_still_fail() {
  local leaked
  leaked="an error mentioning $DUMMY_SECRET where it must not"
  if ( assert_no_credential_leak "$leaked" "a deliberately leaking stream" ) 2>/dev/null; then
    fail "the leak guard did not reject a stream containing the token value"
  fi
  leaked="an error mentioning $DUMMY_USER where it must not"
  if ( assert_no_credential_leak "$leaked" "a deliberately leaking stream" ) 2>/dev/null; then
    fail "the leak guard did not reject a stream containing the account value"
  fi
  pass "the credential-leak guard still rejects a stream that does leak"
}

test_a_stalling_store_times_out_instead_of_hanging() {
  local dir record err
  # `security` has no timeout flag and blocks forever when the stored item
  # prompts, so an unbounded read would hang session start - the exact class of
  # stall this whole check exists to remove.
  dir=$(new_case)
  record=$(FAKE_KEYCHAIN_SECRET=stall FM_FORGE_KEYCHAIN_TIMEOUT=1 \
    run_resolver "$dir" check bitbucket mattw_watson/hexbattle)
  expect_code 10 "$(field "$record" 1)" "a credential store that never answers"
  err=$(field "$record" 3)
  assert_contains "$err" "firstmate-bitbucket-token" "the reason must name the entry that stalled"
  assert_contains "$err" "did not answer" "a stalled store must read as a stall"
  assert_not_contains "$err" "no credential store" \
    "a stalled store must not be confused with having no store at all"
  assert_not_contains "$err" "absent" "a stalled store must not read as an absent entry"
  assert_absent "$dir/curl-argv" "a stalled store must never reach a request"
  assert_no_credential_leak "$err" "the store-timeout refusal"
  pass "a store that never answers is its own outcome, not a hang and not a pass"
}

test_a_zero_bound_falls_back_to_the_default() {
  local dir record
  # Zero is not "do not wait": curl reads --max-time 0 as no limit at all, and a
  # zero store bound would fail every read the store did not answer instantly.
  dir=$(new_case)
  record=$(FM_FORGE_CREDENTIAL_TIMEOUT=0 run_resolver "$dir" check bitbucket mattw_watson/hexbattle)
  expect_code 0 "$(field "$record" 1)" "a zero request bound"
  assert_grep "--max-time 10" "$dir/curl-argv" \
    "a zero request bound must fall back to the documented default, never to no limit"

  dir=$(new_case)
  record=$(FM_FORGE_KEYCHAIN_TIMEOUT=0 run_resolver "$dir" check bitbucket mattw_watson/hexbattle)
  expect_code 0 "$(field "$record" 1)" "a zero store bound"

  dir=$(new_case)
  record=$(FM_FORGE_CREDENTIAL_TIMEOUT=notanumber run_resolver "$dir" check bitbucket mattw_watson/hexbattle)
  expect_code 0 "$(field "$record" 1)" "a non-numeric request bound"
  assert_grep "--max-time 10" "$dir/curl-argv" \
    "a non-numeric request bound must fall back to the documented default"
  pass "a zero or non-numeric bound falls back to the default instead of removing the bound"
}

test_complete_pair_resolves_and_authenticates() {
  local dir record status
  dir=$(new_case)
  record=$(run_resolver "$dir" check bitbucket mattw_watson/hexbattle)
  status=$(field "$record" 1)
  expect_code 0 "$status" "a complete pair with an accepted credential"
  [ -z "$(field "$record" 3)" ] || fail "a working credential must report nothing"
  assert_grep AUTH_PRESENT "$dir/curl-stdin" \
    "the pair must reach curl as a Basic-auth config on stdin"
  assert_grep firstmate-bitbucket-email "$dir/keychain-services" \
    "the resolver must read its own account entry"
  assert_grep firstmate-bitbucket-token "$dir/keychain-services" \
    "the resolver must read its own token entry"
  pass "a complete pair resolves, authenticates, and reports nothing"
}

test_offline_resolution_needs_no_network() {
  local dir record
  dir=$(new_case)
  record=$(run_resolver "$dir" check bitbucket)
  expect_code 0 "$(field "$record" 1)" "resolution without a repository"
  assert_absent "$dir/curl-argv" "resolution without a repository must make no request"
  pass "check without a repository proves the store locally and makes no request"
}

test_missing_entry_refuses_with_an_actionable_reason() {
  local dir record err
  dir=$(new_case)
  record=$(FAKE_KEYCHAIN_SECRET=absent run_resolver "$dir" check bitbucket mattw_watson/hexbattle)
  expect_code 3 "$(field "$record" 1)" "an absent keychain entry"
  err=$(field "$record" 3)
  assert_contains "$err" "firstmate-bitbucket-token" "the reason must name the missing entry"
  assert_contains "$err" "absent" "the reason must say the entry is absent"
  assert_absent "$dir/curl-argv" "an unresolved credential must never reach a request"
  pass "a missing entry refuses with the entry name and its own exit code"
}

test_empty_value_refuses_distinctly_from_absent() {
  local dir record err
  dir=$(new_case)
  record=$(FAKE_KEYCHAIN_SECRET=empty run_resolver "$dir" check bitbucket mattw_watson/hexbattle)
  expect_code 4 "$(field "$record" 1)" "an empty keychain entry"
  err=$(field "$record" 3)
  assert_contains "$err" "firstmate-bitbucket-token" "the reason must name the empty entry"
  assert_contains "$err" "empty" "the reason must say the entry is empty"
  assert_absent "$dir/curl-argv" "an empty credential must never reach a request"
  pass "an empty value refuses distinctly from an absent entry"
}

test_half_a_pair_never_reaches_a_request() {
  local dir record
  dir=$(new_case)
  # The account half resolves, the token half does not: the resolver must
  # refuse rather than send a partial credential.
  record=$(FAKE_KEYCHAIN_USER=ok FAKE_KEYCHAIN_SECRET=absent \
    run_resolver "$dir" api-get bitbucket /2.0/repositories/mattw_watson/hexbattle)
  expect_code 3 "$(field "$record" 1)" "a half-resolved pair"
  [ -z "$(field "$record" 2)" ] || fail "a refused api-get must print no body"
  assert_absent "$dir/curl-argv" "a half-resolved pair must never reach a request"
  pass "a half-resolved pair refuses instead of sending a partial credential"
}

test_unusable_values_refuse() {
  local dir record err
  # A line break would end the curl config line and let the rest act as further
  # curl directives, so it must be refused rather than escaped away.
  dir=$(new_case)
  record=$(FAKE_KEYCHAIN_SECRET=newline run_resolver "$dir" check bitbucket mattw_watson/hexbattle)
  expect_code 4 "$(field "$record" 1)" "a value carrying a line break"
  err=$(field "$record" 3)
  assert_contains "$err" "line break" "the reason must name the line break"
  assert_no_credential_leak "$err" "the line-break refusal"
  assert_absent "$dir/curl-argv" "a value carrying curl directives must never reach curl"

  # An account half with a colon cannot be an HTTP Basic username.
  dir=$(new_case)
  record=$(FAKE_KEYCHAIN_USER='colon' run_resolver "$dir" check bitbucket mattw_watson/hexbattle)
  expect_code 4 "$(field "$record" 1)" "an account value containing a colon"
  assert_contains "$(field "$record" 3)" "Basic username" "the reason must name the username problem"
  pass "values that cannot be used safely refuse instead of being sent"
}

test_rejected_credential_is_distinct_from_absent() {
  local dir record err
  dir=$(new_case)
  record=$(FAKE_CURL_STATUS=401 run_resolver "$dir" check bitbucket mattw_watson/hexbattle)
  expect_code 5 "$(field "$record" 1)" "a credential the forge rejects"
  err=$(field "$record" 3)
  assert_contains "$err" "401" "a rejection must report the forge's verdict"
  assert_contains "$err" "rejected" "a rejection must read as a rejection"
  assert_not_contains "$err" "absent" "a rejection must not read as an absent entry"

  dir=$(new_case)
  record=$(FAKE_CURL_STATUS=403 run_resolver "$dir" check bitbucket mattw_watson/hexbattle)
  expect_code 5 "$(field "$record" 1)" "a credential refused for scope"
  assert_contains "$(field "$record" 3)" "read scopes" "an under-scoped credential must say so"
  pass "a rejected credential is reported distinctly from an absent one"
}

test_unreachable_forge_is_inconclusive_not_a_verdict() {
  local dir record
  dir=$(new_case)
  record=$(FAKE_CURL_EXIT=7 run_resolver "$dir" check bitbucket mattw_watson/hexbattle)
  expect_code 7 "$(field "$record" 1)" "a forge that cannot be reached"
  assert_not_contains "$(field "$record" 3)" "rejected" \
    "an unreachable forge must not be reported as a rejection"
  pass "an unreachable forge is inconclusive, never a credential verdict"
}

test_invisible_repository_and_unexpected_response_are_separate() {
  local dir record
  dir=$(new_case)
  record=$(FAKE_CURL_STATUS=404 run_resolver "$dir" check bitbucket mattw_watson/hexbattle)
  expect_code 8 "$(field "$record" 1)" "a repository the credential cannot see"
  assert_contains "$(field "$record" 3)" "cannot see" "an invisible repository must say so"

  dir=$(new_case)
  record=$(FAKE_CURL_STATUS=410 run_resolver "$dir" check bitbucket mattw_watson/hexbattle)
  expect_code 9 "$(field "$record" 1)" "an unexpected forge response"
  assert_contains "$(field "$record" 3)" "410" "an unexpected response must report its status"
  pass "an invisible repository and an unexpected response stay separate outcomes"
}

test_no_stream_can_emit_a_credential_value() {
  local dir record mode statuses status all
  all=
  for mode in ok absent empty newline colon; do
    for status in 200 401 403 404 410; do
      dir=$(new_case)
      record=$(FAKE_KEYCHAIN_SECRET="$mode" FAKE_CURL_STATUS="$status" \
        run_resolver "$dir" check bitbucket mattw_watson/hexbattle)
      all="$all$(field "$record" 2)$(field "$record" 3)"
      # argv is world-readable through ps, so the pair must never appear there.
      [ ! -f "$dir/curl-argv" ] || all="$all$(cat "$dir/curl-argv")"
    done
  done
  dir=$(new_case)
  record=$(run_resolver "$dir" api-get bitbucket /2.0/repositories/mattw_watson/hexbattle)
  all="$all$(field "$record" 2)$(field "$record" 3)$(cat "$dir/curl-argv")"
  all="$all$("$RESOLVER" --help 2>&1)"
  assert_no_credential_leak "$all" "some resolver output path"
  statuses=$(grep -c . "$dir/curl-argv")
  [ "$statuses" -ge 1 ] || fail "the api-get case should have made a request"
  pass "no output, diagnostic, or argv path can emit a credential value"
}

test_no_mistakes_credential_is_out_of_reach() {
  # Separation from no-mistakes' write-capable credential is the point of the
  # design, so it is pinned statically as well as by the fake keychain, which
  # answers only the firstmate-specific services.
  assert_no_grep "no-mistakes-bitbucket" "$RESOLVER" \
    "the resolver must never name no-mistakes' credential"
  assert_no_grep 'NO_MISTAKES_BITBUCKET' "$RESOLVER" \
    "the resolver must never read no-mistakes' credential environment"
  assert_no_grep ':+SET' "$RESOLVER" \
    "the resolver must not use the presence idiom that prints the value"
  pass "no-mistakes' write-capable credential stays out of the resolver's reach"
}

test_forge_and_repository_identity() {
  local out
  while IFS='^' read -r url forge repo; do
    [ -n "$url" ] || continue
    if [ "$forge" = - ]; then
      out=$("$RESOLVER" forge-of "$url" 2>/dev/null) && fail "$url should name no known forge (got $out)"
    else
      out=$("$RESOLVER" forge-of "$url" 2>/dev/null) || fail "$url should resolve to $forge"
      [ "$out" = "$forge" ] || fail "$url: expected forge $forge, got $out"
    fi
    if [ "$repo" = - ]; then
      out=$("$RESOLVER" repo-of "$url" 2>/dev/null) && fail "$url should name no repository (got $out)"
    else
      out=$("$RESOLVER" repo-of "$url" 2>/dev/null) || fail "$url should resolve to repository $repo"
      [ "$out" = "$repo" ] || fail "$url: expected repository $repo, got $out"
    fi
  done <<'ROWS'
git@bitbucket.org:mattw_watson/hexbattle.git^bitbucket^mattw_watson/hexbattle
https://bitbucket.org/mattw_watson/hexbattle^bitbucket^mattw_watson/hexbattle
ssh://git@bitbucket.org/ws/repo.git^bitbucket^ws/repo
https://github.com/owner/repo.git^github^owner/repo
https://evil.example/bitbucket.org/repo^-^-
file:///tmp/local.git^-^-
https://bitbucket.org/ws/repo/../../other^bitbucket^-
ROWS
  pass "forge and repository identity are read from the host, never the path"
}

test_github_has_no_firstmate_credential() {
  local dir record
  dir=$(new_case)
  record=$(run_resolver "$dir" check github owner/repo)
  expect_code 2 "$(field "$record" 1)" "a forge firstmate holds no credential for"
  assert_contains "$(field "$record" 3)" "gh CLI" "GitHub must point at the tool that owns its credential"
  assert_absent "$dir/keychain-services" "an unsupported forge must not read the keychain"
  pass "GitHub reports that gh owns its credential instead of inventing one"
}

test_no_credential_store_is_its_own_outcome() {
  local dir record
  dir=$(new_case)
  record=$(FM_FORGE_KEYCHAIN_TOOL_OVERRIDE="$dir/bin/absent-tool" \
    PATH="$dir/bin:$PATH" "$RESOLVER" check bitbucket mattw_watson/hexbattle 2>&1)
  # Run directly so the override is not replaced by run_resolver's fake tool.
  case "$record" in
    *"no credential store"*) : ;;
    *) fail "a machine with no credential store should say so, got: $record" ;;
  esac
  pass "a machine with no credential store reports that, not a missing entry"
}

# The rest of the toolchain a bootstrap run expects, installed alongside the
# fake keychain and curl new_case already put in the case dir, so every
# bootstrap case below starts from the same silent baseline and only the
# credential behavior varies.
make_bootstrap_tools() {  # <fakebin>
  local fakebin=$1
  fm_fake_exit0 "$fakebin" tmux node gh-axi chrome-devtools-axi lavish-axi quota-axi
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && printf '%s\n' 'no-mistakes version v1.31.2'
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  --version:*) printf '%s\n' 0.1.1 ;;
  update:--help) printf '%s\n' '  --archive-body' ;;
  mv:--help) printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
}

# A bootstrap-ready home in a fresh case dir, tracking the given clones. Each
# clone is "<name>=<origin-url>". Echoes the case dir; the home is <case>/home
# and the fake toolchain is <case>/bin.
new_bootstrap_case() {  # <clone>...
  local dir home spec name url
  dir=$(new_case)
  home="$dir/home"
  mkdir -p "$home/config" "$home/projects"
  printf '%s\n' manual > "$home/config/backlog-backend"
  for spec in "$@"; do
    name=${spec%%=*}
    url=${spec#*=}
    git init -q "$home/projects/$name"
    git -C "$home/projects/$name" remote add origin "$url"
  done
  make_bootstrap_tools "$dir/bin"
  printf '%s\n' "$dir"
}

test_bootstrap_reports_a_broken_credential_at_session_start() {
  local dir home fakebin out
  dir=$(new_bootstrap_case \
    'hexbattle=git@bitbucket.org:mattw_watson/hexbattle.git' \
    'gh-only=https://github.com/owner/repo.git')
  home="$dir/home"
  fakebin="$dir/bin"

  out=$(PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_BOOTSTRAP_DETECT_ONLY=1 \
    FM_FORGE_KEYCHAIN_TOOL_OVERRIDE="$fakebin/security" \
    FAKE_KEYCHAIN_SECRET=absent FAKE_KEYCHAIN_LOG="$dir/bootstrap-keychain" \
    FAKE_CURL_ARGV_LOG="$dir/bootstrap-curl-argv" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$out" "FORGE_CREDENTIAL: bitbucket:" \
    "session start must report a broken Bitbucket credential"
  assert_contains "$out" "firstmate-bitbucket-token" \
    "the startup line must name the missing entry"
  assert_no_credential_leak "$out" "the bootstrap diagnostic"

  # The same home with a working credential stays silent, and a GitHub-only home
  # is never asked about a credential firstmate does not hold.
  out=$(PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_BOOTSTRAP_DETECT_ONLY=1 \
    FM_FORGE_KEYCHAIN_TOOL_OVERRIDE="$fakebin/security" \
    FAKE_CURL_STATUS=200 FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_not_contains "$out" "FORGE_CREDENTIAL" "a working credential must stay silent"

  # A clone whose remote names the forge but no repository still gets the local
  # proof, so a missing credential is reported rather than silently skipped.
  git -C "$home/projects/hexbattle" remote set-url origin 'https://bitbucket.org/'
  out=$(PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_BOOTSTRAP_DETECT_ONLY=1 \
    FM_FORGE_KEYCHAIN_TOOL_OVERRIDE="$fakebin/security" \
    FAKE_KEYCHAIN_SECRET=absent FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$out" "FORGE_CREDENTIAL: bitbucket:" \
    "a Bitbucket clone with an unusable remote must still get the local credential proof"

  rm -rf "$home/projects/hexbattle"
  out=$(PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_BOOTSTRAP_DETECT_ONLY=1 \
    FM_FORGE_KEYCHAIN_TOOL_OVERRIDE="$fakebin/security" \
    FAKE_KEYCHAIN_SECRET=absent FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_not_contains "$out" "FORGE_CREDENTIAL" \
    "a home tracking no Bitbucket repository must never be asked for that credential"
  pass "session start reports a broken forge credential and stays silent otherwise"
}

test_bootstrap_reports_no_store_once_per_home() {
  local dir home fakebin out marker
  # A machine with no credential store cannot be fixed by retrying, so repeating
  # the line at every session start would train the reader to skim past startup
  # diagnostics - which is the whole mechanism this change relies on. Staying
  # silent would push discovery back to a failed pull-request step, which is what
  # the change exists to prevent. So: exactly once per home.
  dir=$(new_bootstrap_case 'hexbattle=git@bitbucket.org:mattw_watson/hexbattle.git')
  home="$dir/home"
  fakebin="$dir/bin"

  out=$(PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_BOOTSTRAP_DETECT_ONLY=1 \
    FM_FORGE_KEYCHAIN_TOOL_OVERRIDE="$fakebin/no-such-store" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$out" "FORGE_CREDENTIAL: bitbucket: no credential store on this platform" \
    "the first session start on a machine with no credential store must say so"
  assert_contains "$out" "unavailable here" \
    "the line must state the consequence rather than imply a fault to retry"
  marker="$home/state/forge-credential-no-store.bitbucket"
  assert_present "$marker" "the report must be recorded durably in the home's state directory"
  [ ! -s "$marker" ] || fail "the marker must record only that the line was said, never any value"

  out=$(PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_BOOTSTRAP_DETECT_ONLY=1 \
    FM_FORGE_KEYCHAIN_TOOL_OVERRIDE="$fakebin/no-such-store" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_not_contains "$out" "FORGE_CREDENTIAL" \
    "a home that has already been told about the missing store must stay silent"

  # A different home has not been told yet, so it hears it once too.
  dir=$(new_bootstrap_case 'hexbattle=git@bitbucket.org:mattw_watson/hexbattle.git')
  home="$dir/home"
  fakebin="$dir/bin"
  out=$(PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_BOOTSTRAP_DETECT_ONLY=1 \
    FM_FORGE_KEYCHAIN_TOOL_OVERRIDE="$fakebin/no-such-store" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$out" "FORGE_CREDENTIAL: bitbucket: no credential store on this platform" \
    "a home that has not been told yet must still hear it once"
  pass "a machine with no credential store is reported once per home, then silently"
}

test_bootstrap_reports_an_invisible_repository_only_when_none_is_readable() {
  local dir home fakebin out
  # Directory order must not decide which repository owns the diagnostic: the
  # credential is account-wide, so one unreadable clone proves nothing about it.
  dir=$(new_bootstrap_case \
    'a-invisible=git@bitbucket.org:mattw_watson/invisible.git' \
    'z-readable=git@bitbucket.org:mattw_watson/readable.git')
  home="$dir/home"
  fakebin="$dir/bin"

  out=$(PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_BOOTSTRAP_DETECT_ONLY=1 \
    FM_FORGE_KEYCHAIN_TOOL_OVERRIDE="$fakebin/security" \
    FAKE_CURL_404_MATCH='mattw_watson/invisible' \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_not_contains "$out" "FORGE_CREDENTIAL" \
    "a readable clone must suppress an earlier clone's not-visible result"

  # A credential-level verdict is true whichever repository was probed, so it is
  # reported straight from the first clone rather than waiting for the scan.
  out=$(PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_BOOTSTRAP_DETECT_ONLY=1 \
    FM_FORGE_KEYCHAIN_TOOL_OVERRIDE="$fakebin/security" \
    FAKE_KEYCHAIN_SECRET=absent \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$out" "firstmate-bitbucket-token" \
    "a credential-level verdict must be reported from the first clone that produced it"
  assert_not_contains "$out" "sees none of the tracked" \
    "a credential-level verdict must not be reported as a repository-access problem"

  # No tracked repository on the forge is readable: now it is worth saying, and
  # the wording must point at access rather than at the credential.
  dir=$(new_bootstrap_case 'a-invisible=git@bitbucket.org:mattw_watson/invisible.git')
  home="$dir/home"
  fakebin="$dir/bin"
  out=$(PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_BOOTSTRAP_DETECT_ONLY=1 \
    FM_FORGE_KEYCHAIN_TOOL_OVERRIDE="$fakebin/security" \
    FAKE_CURL_404_MATCH='mattw_watson/invisible' \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$out" "FORGE_CREDENTIAL: bitbucket: the credential authenticates but sees none of the tracked" \
    "a forge with no readable tracked repository must be reported as an access problem"
  pass "a not-visible repository is reported only when no tracked clone on that forge is readable"
}

test_bootstrap_reports_a_stalled_store_every_time() {
  local dir home fakebin out
  # Unlike the missing store, a stalled read IS actionable - re-cache the item so
  # an unattended read is allowed - so it is never recorded away into silence.
  dir=$(new_bootstrap_case 'hexbattle=git@bitbucket.org:mattw_watson/hexbattle.git')
  home="$dir/home"
  fakebin="$dir/bin"
  out=$(PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_BOOTSTRAP_DETECT_ONLY=1 \
    FM_FORGE_KEYCHAIN_TOOL_OVERRIDE="$fakebin/security" \
    FAKE_KEYCHAIN_USER=stall FM_FORGE_KEYCHAIN_TIMEOUT=1 \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$out" "FORGE_CREDENTIAL: bitbucket:" \
    "a store that never answers must be reported, not waited on"
  assert_contains "$out" "did not answer" "the line must name the stall"
  assert_not_contains "$out" "no credential store on this platform" \
    "a stall must not be reported as having no store at all"
  assert_no_credential_leak "$out" "the stalled-store diagnostic"
  pass "a stalled credential store is reported at session start rather than hanging it"
}

test_a_tool_two_checks_need_is_reported_once() {
  # curl is required by both the forge-credential check and the X-mode relay
  # poll, and the digest is parsed line by line, so both go through the single
  # deduping reporter rather than echoing a MISSING line of their own.
  local owners
  assert_grep 'report_missing_tool curl' "$ROOT/bin/fm-bootstrap.sh" \
    "the forge-credential check must report a missing curl through the deduping reporter"
  # shellcheck disable=SC2016 # The line being counted is literal shell source.
  owners=$(grep -Fc -- 'echo "MISSING: $tool (install:' "$ROOT/bin/fm-bootstrap.sh")
  [ "$owners" -eq 1 ] || fail "the MISSING tool line must have exactly one owner, found $owners"
  assert_no_grep 'echo "MISSING: curl' "$ROOT/bin/fm-bootstrap.sh" \
    "no check may echo a MISSING curl line around the deduping reporter"
  assert_no_grep 'echo "MISSING: jq' "$ROOT/bin/fm-bootstrap.sh" \
    "no check may echo a MISSING jq line around the deduping reporter"
  pass "a tool two checks both need is named once in the digest"
}

test_bootstrap_diagnostic_has_one_owner_and_one_trigger() {
  local trigger count
  assert_grep 'FORGE_CREDENTIAL: <forge>: <reason>' "$ROOT/bin/fm-bootstrap.sh" \
    "bootstrap's header must own the FORGE_CREDENTIAL line format"
  count=$(grep -Fc -- '`FORGE_CREDENTIAL:' "$ROOT/.agents/skills/bootstrap-diagnostics/SKILL.md")
  [ "$count" -ge 1 ] || fail "bootstrap-diagnostics must own the FORGE_CREDENTIAL response"
  # shellcheck disable=SC2016 # The backtick-delimited prefixes are literal Markdown.
  trigger=$(sed -n '/- `bootstrap-diagnostics`/,/- `diagnostic-reasoning`/p' "$ROOT/AGENTS.md")
  assert_contains "$trigger" "FORGE_CREDENTIAL:" \
    "AGENTS.md must list FORGE_CREDENTIAL as an actionable bootstrap prefix"
  pass "the new diagnostic has one owner, one response playbook, and one trigger"
}

test_the_leak_guard_can_still_fail
test_complete_pair_resolves_and_authenticates
test_offline_resolution_needs_no_network
test_missing_entry_refuses_with_an_actionable_reason
test_empty_value_refuses_distinctly_from_absent
test_half_a_pair_never_reaches_a_request
test_unusable_values_refuse
test_rejected_credential_is_distinct_from_absent
test_unreachable_forge_is_inconclusive_not_a_verdict
test_invisible_repository_and_unexpected_response_are_separate
test_no_stream_can_emit_a_credential_value
test_no_mistakes_credential_is_out_of_reach
test_forge_and_repository_identity
test_github_has_no_firstmate_credential
test_no_credential_store_is_its_own_outcome
test_a_stalling_store_times_out_instead_of_hanging
test_a_zero_bound_falls_back_to_the_default
test_bootstrap_reports_a_broken_credential_at_session_start
test_bootstrap_reports_no_store_once_per_home
test_bootstrap_reports_an_invisible_repository_only_when_none_is_readable
test_bootstrap_reports_a_stalled_store_every_time
test_a_tool_two_checks_need_is_reported_once
test_bootstrap_diagnostic_has_one_owner_and_one_trigger
