#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the crew kill-guard PreToolUse seatbelt (docs/kill-guard.md).
#
# Incident regression (2026-07-22, backlog fm-crew-cleanup-broad-kill): a
# no-mistakes test-step agent, cleaning up its own dev server inside a task
# worktree, ran `pkill -f 'concurrently.*dev'` and killed the captain's
# pre-existing dev server in another checkout. The end-to-end test below
# reproduces that hazard shape with sandboxed processes: it proves the
# name-pattern actually matches a process rooted OUTSIDE the worktree, that
# the guard denies exactly that command, and that legitimate own-process
# teardown (kill by recorded PID, worktree-scoped pattern) still works and
# leaves the outside process alive.
#
# bin/fm-kill-command-policy.mjs is the single owner of the block/allow
# decision; it reuses the shell classifier owned by bin/fm-arm-command-policy.mjs.
# bin/fm-kill-pretool-check.sh is the stable transport driving all five harness
# entry forms. This suite proves the decision matrix, the harness-output
# shaping, the fail-open transport behavior, the prefilter fast path, the
# policy CLI contract, and the fm-spawn worktree-hook wiring. No harness is
# spawned; live per-harness evidence lives in docs/kill-guard.md.
#
# Safety: every process this suite starts is its own tracked child under the
# test temp root, and the only pattern-kill it executes for real is scoped to a
# unique mktemp path that matches nothing else on the machine.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-kill-pretool-check)

CHECK="$ROOT/bin/fm-kill-pretool-check.sh"
POLICY="$ROOT/bin/fm-kill-command-policy.mjs"

# The worktree identity every matrix case runs against. A plain directory is
# enough: the transport's scope is the --worktree argument itself (fm-spawn
# only installs the hook into task worktrees), not a checkout-shape probe.
# The logical pwd re-read collapses any doubled slash a trailing-slash TMPDIR
# leaves in the mktemp path, matching the canonical form fm-spawn hands out.
WT_FIX="$TMP_ROOT/task-wt"
mkdir -p "$WT_FIX/apps"
WT_FIX=$(cd "$WT_FIX" && pwd)

# --- full cross-harness acceptance matrix ----------------------------------

MATRIX_IDS=()
MATRIX_EXPECTED=()
MATRIX_COMMANDS=()

matrix_case() {
  MATRIX_IDS+=("$1")
  MATRIX_EXPECTED+=("$2")
  MATRIX_COMMANDS+=("$3")
}

# DENY broad-kill: a name-pattern kill (or pattern-matched PID consumption)
# with no worktree scoping. K01 is the exact incident command.
matrix_case K01 broad-kill "pkill -f 'concurrently.*dev'"
matrix_case K02 broad-kill 'pkill -f concurrently'
matrix_case K03 broad-kill 'killall node'
matrix_case K04 broad-kill 'pkill -9 -f vite'
matrix_case K05 broad-kill 'sudo pkill -f dev'
matrix_case K06 broad-kill 'command pkill -f dev'
matrix_case K07 broad-kill 'kill $(pgrep -f vite)'
matrix_case K08 broad-kill 'kill "$(pgrep -f vite)"'
matrix_case K09 broad-kill "bash -c 'pkill -f dev'"
matrix_case K10 broad-kill 'eval "pkill -f dev"'
matrix_case K11 broad-kill 'pgrep -f dev | xargs kill'
matrix_case K12 broad-kill 'pgrep -f dev | xargs -n1 kill -9'
matrix_case K13 broad-kill 'PIDS=$(pgrep -f dev); kill $PIDS'
matrix_case K14 broad-kill 'cd apps && pkill -f dev'
matrix_case K15 broad-kill 'pkill -u "$USER"'
matrix_case K16 broad-kill '(pkill -f dev)'
matrix_case K17 broad-kill 'p"kill" -f dev'
matrix_case K18 broad-kill 'echo dev | xargs pkill -f'
matrix_case K19 broad-kill '(pgrep -f dev) | xargs kill'
matrix_case K20 broad-kill '{ pgrep -f dev; } | xargs kill'
matrix_case K21 broad-kill 'echo dev | xargs -I{} pkill -f {}'
matrix_case K22 broad-kill 'echo dev | xargs -I {} pkill -f {}'
# K23-K25: a shell run AS the xargs utility cannot launder a kill the direct
# form would deny (captain decision, 2026-07-23).
matrix_case K23 broad-kill 'echo x | xargs bash -c "pkill -f dev"'
matrix_case K24 broad-kill 'pgrep -f dev | xargs -I{} bash -c "kill {}"'
matrix_case K25 broad-kill 'echo x | xargs -0 sh -c "killall node"'
# K26-K28: an executed kill must not launder through one more wrapper layer -
# a nested xargs inside the payload, a doubly-nested shell, or a direct shell
# stage of the pgrep-fed pipeline.
matrix_case K26 broad-kill 'pgrep -f dev | xargs -I{} bash -c "echo {} | xargs kill"'
matrix_case K27 broad-kill 'pgrep -f dev | xargs -I{} bash -c "echo x | xargs sh -c \"kill {}\""'
matrix_case K28 broad-kill 'pgrep -f dev | bash -c "xargs kill"'

# DENY unclassifiable-kill: unsupported grammar carrying a name-pattern kill
# verb cannot be proven safe, mirroring the arm seatbelt's fail-closed backstop.
matrix_case U01 unclassifiable-kill 'while true; do pkill -f dev; done'
matrix_case U02 unclassifiable-kill 'for x in 1; do killall node; done'
matrix_case U03 unclassifiable-kill 'until false; do kill $(pgrep -f dev); done'
matrix_case U04 unclassifiable-kill 'echo dev | xargs --max-procs=1 pkill -f'

# ALLOW: kill-by-PID, worktree-scoped patterns, read-only pgrep, and data
# mentions. A01-A03 are the legitimate own-process teardown shapes the deny
# reason itself recommends.
matrix_case A01 allow 'kill 12345'
matrix_case A02 allow 'kill "$(cat .fm-dev.pid)"'
matrix_case A03 allow "pkill -f 'WTFIX/apps'"
matrix_case A04 allow 'kill -9 $SERVER_PID'
matrix_case A05 allow 'pkill -f "$PWD/apps"'
matrix_case A06 allow 'pkill -f "$(pwd)/apps"'
matrix_case A07 allow 'kill $(pgrep -f "WTFIX/vite")'
matrix_case A08 allow 'pgrep -f "WTFIX" | xargs kill'
matrix_case A09 allow 'pgrep -f concurrently'
matrix_case A10 allow 'pgrep -fl dev || true'
matrix_case A11 allow 'echo "pkill -f dev"'
matrix_case A12 allow 'git commit -m "add pkill guard"'
matrix_case A13 allow 'grep -rn pkill bin/'
matrix_case A14 allow 'npm run dev & echo $! > .fm-dev.pid'
matrix_case A15 allow 'PIDS=$(cat .fm-dev.pid); kill $PIDS'
matrix_case A16 allow 'ls .agents/skills'
matrix_case A17 allow 'for t in tests/*.test.sh; do bash "$t"; done'
matrix_case A18 allow "printf '%s\\n' 'killall node'"
matrix_case A19 allow 'kill %1'
matrix_case A20 allow 'wait $DEV_PID'
matrix_case A21 allow "echo 'WTFIX/dev' | xargs pkill -f"
matrix_case A22 allow 'git ls-files | xargs grep -n pkill'
matrix_case A23 allow 'ls | xargs echo killall'
matrix_case A24 allow 'ls | xargs -I {} echo killall {}'
# A25-A28: xargs shell payloads that are scoped, data-only, PID-only, or fed
# by a worktree-scoped pgrep stay allowed under the recursive classification.
matrix_case A25 allow "echo x | xargs bash -c 'pkill -f \"WTFIX/dev\"'"
matrix_case A26 allow 'ls | xargs bash -c "echo pkill"'
matrix_case A27 allow 'echo x | xargs bash -c "kill 123"'
matrix_case A28 allow "pgrep -f 'WTFIX' | xargs -I{} bash -c 'kill {}'"
# A29-A30: a direct shell stage stays allowed when its pipe carries no
# unscoped pgrep output or the pgrep is worktree-scoped.
matrix_case A29 allow 'echo x | bash -c "kill 123"'
matrix_case A30 allow "pgrep -f 'WTFIX' | bash -c 'xargs kill'"

MATRIX_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-kill-policy-matrix.XXXXXX")
FM_TEST_CLEANUP_DIRS+=("$MATRIX_TMP")

run_matrix_entry() {
  local id=$1 expected=$2 entry=$3 cmd=$4 payload out_file err_file rc
  out_file="$MATRIX_TMP/$id-$entry.out"
  err_file="$MATRIX_TMP/$id-$entry.err"
  # WTFIX is a placeholder for the fixture worktree's absolute path, so scoped
  # cases stay readable above.
  cmd=${cmd//WTFIX/$WT_FIX}

  case "$entry" in
    codex)
      payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" --worktree "$WT_FIX" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    claude)
      payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" --claude --worktree "$WT_FIX" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    grok)
      payload=$(jq -cn --arg command "$cmd" '{toolName:"run_terminal_command",toolInput:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" --worktree "$WT_FIX" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    opencode|pi)
      "$CHECK" --command "$cmd" --worktree "$WT_FIX" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    *)
      fail "unknown matrix entry form: $entry"
      ;;
  esac

  if [ "$expected" = allow ]; then
    [ "$rc" -eq 0 ] || fail "$id via $entry must allow, got exit $rc: $(cat "$err_file")"
    [ ! -s "$out_file" ] || fail "$id via $entry allow must leave stdout empty: $(cat "$out_file")"
    [ ! -s "$err_file" ] || fail "$id via $entry allow must leave stderr empty: $(cat "$err_file")"
    return
  fi

  [ "$rc" -eq 2 ] || fail "$id via $entry must deny, got exit $rc"
  jq -e --arg code "$expected" '.hookSpecificOutput.permissionDecision == "deny" and (.systemMessage | test("\\[" + $code + "\\]"))' "$err_file" >/dev/null 2>&1 \
    || fail "$id via $entry deny must carry the $expected reason code on stderr: $(cat "$err_file")"
  if [ "$entry" = claude ]; then
    [ ! -s "$out_file" ] || fail "$id via claude deny must leave stdout empty: $(cat "$out_file")"
  elif [ "$entry" = grok ]; then
    jq -e '.decision == "deny"' "$out_file" >/dev/null 2>&1 \
      || fail "$id via grok deny must carry decision=deny on stdout: $(cat "$out_file")"
  fi
}

test_full_acceptance_matrix() {
  local i entry
  for ((i = 0; i < ${#MATRIX_IDS[@]}; i++)); do
    for entry in codex claude grok opencode pi; do
      run_matrix_entry "${MATRIX_IDS[$i]}" "${MATRIX_EXPECTED[$i]}" "$entry" "${MATRIX_COMMANDS[$i]}"
    done
  done
  pass "kill-guard acceptance matrix: ${#MATRIX_IDS[@]} cases x 5 harness entry forms, block/allow all correct"
}

# --- end-to-end incident reproduction ---------------------------------------
#
# The regression demanded by the incident record: a name-pattern kill issued
# from a worktree context matches a process rooted elsewhere. Both processes
# are children of this test; the only real pattern-kill executed is scoped to
# the unique fixture worktree path.

wait_for_exit() {
  local pid=$1 i=0
  while [ "$i" -lt 50 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# A background `bash -c ... &` child only shows its marker cmdline once its
# exec completes; until then pgrep still sees the parent script's argv. Poll
# until the pattern matches the pid so the assertions are exec-race-free.
# The sandbox processes are spawned as `exec -a '<marker>' sleep 300` because
# bash 5 (Linux CI) execs the final command of a -c string, which would replace
# a plain `: marker; sleep 300` cmdline with `sleep 300` and lose the marker;
# exec -a pins the marker into argv for the process's whole life on both
# platforms.
wait_for_cmdline() {
  local pattern=$1 pid=$2 i=0
  while [ "$i" -lt 50 ]; do
    if pgrep -f "$pattern" | grep -qx "$pid"; then return 0; fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_e2e_incident_reproduction() {
  local marker pattern victim own out rc
  marker="fm-kill-guard-e2e-$$"

  # The captain-shaped VICTIM: rooted outside the task worktree, command line
  # matching the incident-shaped dev-server pattern.
  bash -c "exec -a '${marker}-concurrently dev-server' sleep 300" &
  victim=$!
  fm_test_track_pid "$victim"
  disown "$victim" 2>/dev/null || true

  # The crew's OWN dev server: command line carries the worktree path, PID
  # recorded the way the brief's cleanup rule instructs.
  bash -c "exec -a '$WT_FIX/dev-server' sleep 300" &
  own=$!
  fm_test_track_pid "$own"
  disown "$own" 2>/dev/null || true
  printf '%s\n' "$own" > "$WT_FIX/.fm-dev.pid"

  # HAZARD PROOF: the broad name-pattern matches the victim, a process rooted
  # entirely outside the worktree. An unguarded pkill would have killed it.
  pattern="${marker}-concurrently.*dev"
  wait_for_cmdline "$pattern" "$victim" \
    || fail "hazard did not reproduce: broad pattern must match the outside victim process"

  # THE GUARD: the exact incident-shaped command is denied before execution.
  out=$("$CHECK" --claude --worktree "$WT_FIX" --command "pkill -f '$pattern'" 2>&1); rc=$?
  expect_code 2 "$rc" "guard must deny the incident-shaped broad kill from the worktree context"
  assert_contains "$out" '[broad-kill]' "incident denial must carry the broad-kill reason code"

  # LEGITIMATE TEARDOWN still works: both recommended shapes are allowed, and
  # executing them kills only the crew's own process.
  "$CHECK" --claude --worktree "$WT_FIX" --command "kill \"\$(cat $WT_FIX/.fm-dev.pid)\"" \
    || fail "guard must allow kill-by-recorded-PID teardown"
  "$CHECK" --claude --worktree "$WT_FIX" --command "pkill -f '$WT_FIX/dev-server'" \
    || fail "guard must allow the worktree-scoped pattern teardown"
  wait_for_cmdline "$WT_FIX/dev-server" "$own" \
    || fail "own dev server's cmdline never became visible for the scoped teardown"
  pkill -f "$WT_FIX/dev-server" || true
  wait_for_exit "$own" || fail "worktree-scoped teardown did not stop the crew's own dev server"
  kill -0 "$victim" 2>/dev/null \
    || fail "the outside victim process died: scoped teardown must never reach it"

  pass "kill-guard e2e: hazard reproduced, broad kill denied, scoped own-process teardown works, outside process survives"
}

# --- fail-open transport behavior ------------------------------------------

test_fail_open_empty_stdin() {
  local out rc
  out=$("$CHECK" --worktree "$WT_FIX" < /dev/null 2>&1); rc=$?
  expect_code 0 "$rc" "transport must exit 0 on empty stdin"
  [ -z "$out" ] || fail "transport produced output on empty stdin: $out"
  pass "kill-guard: fails open on empty stdin"
}

test_fail_open_unparseable_json() {
  local out rc
  out=$(printf 'not json at all' | "$CHECK" --worktree "$WT_FIX" 2>&1); rc=$?
  expect_code 0 "$rc" "transport must exit 0 on unparseable stdin JSON"
  [ -z "$out" ] || fail "transport produced output on unparseable JSON: $out"
  pass "kill-guard: fails open on unparseable stdin JSON"
}

test_fail_open_missing_worktree() {
  local out rc
  out=$("$CHECK" --command 'pkill -f dev' 2>&1); rc=$?
  expect_code 0 "$rc" "transport must fail open when no --worktree identity is supplied"
  [ -z "$out" ] || fail "transport produced output without a worktree: $out"
  pass "kill-guard: fails open (never blocks) without a worktree identity"
}

test_fail_open_missing_node() {
  local fakebin tool tool_path out rc
  fakebin=$(fm_fakebin "$TMP_ROOT/nonode")
  for tool in bash sh dirname cat printf sed tr jq; do
    tool_path=$(command -v "$tool") || continue
    ln -s "$tool_path" "$fakebin/$tool"
  done
  # node deliberately absent from this PATH.
  out=$(PATH="$fakebin" "$CHECK" --command 'pkill -f dev' --worktree "$WT_FIX" 2>&1); rc=$?
  expect_code 0 "$rc" "transport must fail open when node is unavailable"
  [ -z "$out" ] || fail "transport produced output without node: $out"
  pass "kill-guard: fails open (never blocks) when node is missing"
}

test_fail_open_missing_jq_on_stdin() {
  local fakebin tool tool_path out rc
  fakebin=$(fm_fakebin "$TMP_ROOT/nojq")
  for tool in bash sh dirname cat printf sed tr node; do
    tool_path=$(command -v "$tool") || continue
    ln -s "$tool_path" "$fakebin/$tool"
  done
  # jq deliberately absent: the stdin transport cannot extract the command.
  out=$(printf '{"tool_input":{"command":"pkill -f dev"}}' | PATH="$fakebin" "$CHECK" --worktree "$WT_FIX" 2>&1); rc=$?
  expect_code 0 "$rc" "stdin transport must fail open when jq is unavailable"
  [ -z "$out" ] || fail "transport produced output without jq on the stdin path: $out"
  pass "kill-guard: fails open on the stdin path when jq is missing"
}

# --- prefilter fast path ----------------------------------------------------

test_prefilter_skips_node_without_kill_substring() {
  local fakebin marker tool tool_path out rc
  fakebin=$(fm_fakebin "$TMP_ROOT/prefilter-fake")
  marker="$TMP_ROOT/prefilter-node-called"
  for tool in bash sh dirname cat printf sed tr jq; do
    tool_path=$(command -v "$tool") || continue
    ln -s "$tool_path" "$fakebin/$tool"
  done
  cat > "$fakebin/node" <<EOF
#!/usr/bin/env bash
: > "$marker"
exit 0
EOF
  chmod +x "$fakebin/node"
  # No kill substring: the prefilter must fast-allow before the policy runtime
  # is ever consulted.
  out=$(PATH="$fakebin" "$CHECK" --command 'git status' --worktree "$WT_FIX" 2>&1); rc=$?
  expect_code 0 "$rc" "prefilter must fast-allow a command with no kill substring"
  [ -z "$out" ] || fail "prefilter fast-allow produced output: $out"
  [ ! -e "$marker" ] || fail "prefilter fast-allow still invoked the node policy owner"
  pass "kill-guard: prefilter fast-allows (skips node) when no kill substring is present"
}

test_prefilter_delegates_obfuscated_kill() {
  local out rc
  # Quoted command-word fragments must still reach the classifier (K17 covers
  # the deny; this proves the prefilter did not fast-allow past it).
  out=$("$CHECK" --claude --command 'p"kill" -f dev' --worktree "$WT_FIX" 2>&1); rc=$?
  expect_code 2 "$rc" "prefilter must delegate a quote-split pkill to the classifier"
  assert_contains "$out" '[broad-kill]' "quote-split pkill must deny with the broad-kill code"
  pass "kill-guard: prefilter stays a strict superset for quote-split kill verbs"
}

# --- policy CLI contract ----------------------------------------------------

test_policy_cli_direct() {
  [ "$(node "$POLICY" --command 'pkill -f dev' --worktree "$WT_FIX" | cut -f1)" = deny ] \
    || fail "policy CLI must deny an unscoped pkill"
  [ "$(node "$POLICY" --command 'kill 12345' --worktree "$WT_FIX")" = allow ] \
    || fail "policy CLI must allow kill-by-PID"
  [ "$(node "$POLICY" --command "pkill -f '$WT_FIX/dev'" --worktree "$WT_FIX")" = allow ] \
    || fail "policy CLI must allow a worktree-scoped pattern"
  [ "$(node "$POLICY" --command 'pkill -f dev')" = allow ] \
    || fail "policy CLI must fail open without a worktree identity"
  [ "$(node "$POLICY" --worktree "$WT_FIX")" = allow ] \
    || fail "policy CLI must allow when no command is supplied"
  node "$POLICY" --command 'pkill -f dev' --worktree "$WT_FIX" | grep -qF "$WT_FIX" \
    || fail "policy deny reason must name the worktree path the pattern should scope to"
  pass "kill-guard: fm-kill-command-policy.mjs CLI honors the deny/allow output contract"
}

# --- fm-spawn worktree-hook wiring ------------------------------------------
#
# fm-spawn installs the guard as a worktree-resident hook on every harness with
# a trust-free worktree hook surface (claude, opencode, pi) - the layer that
# also reaches sub-agents another tool launches with cwd inside the worktree.
# These assertions pin the generated hook content in bin/fm-spawn.sh itself so
# a template edit cannot silently drop the guard or break the JSON.

test_spawn_claude_hook_template() {
  local template rendered
  template=$(sed -n '/settings.local.json" <<EOF$/{n;p;}' "$ROOT/bin/fm-spawn.sh")
  [ -n "$template" ] || fail "fm-spawn claude settings.local.json template not found"
  assert_contains "$template" '$KILLCHECK' "claude worktree settings must invoke the kill-guard checker"
  assert_contains "$template" '--claude' "claude worktree hook must pass --claude (stdout must stay empty on deny)"
  assert_contains "$template" '--worktree' "claude worktree hook must pass the worktree identity"
  assert_contains "$template" 'PreToolUse' "claude worktree settings must register a PreToolUse hook"
  assert_contains "$template" 'Stop' "claude worktree settings must keep the turn-end Stop hook"
  # The template must stay valid JSON once fm-spawn substitutes its variables.
  rendered=$(printf '%s\n' "$template" | sed -e "s|\$KILLCHECK|/x/fm-kill-pretool-check.sh|g" -e "s|\$TURNEND|/x/te|g" -e "s|\$WT|/x/wt|g")
  printf '%s' "$rendered" | jq -e '.hooks.PreToolUse[0].matcher == "Bash" and (.hooks.PreToolUse[0].hooks[0].command | contains("fm-kill-pretool-check.sh")) and (.hooks.Stop[0].hooks[0].command | contains("touch"))' >/dev/null \
    || fail "claude worktree settings template does not render to the expected JSON: $rendered"
  pass "fm-spawn: claude worktree settings install the kill-guard PreToolUse hook alongside the turn-end Stop hook"
}

test_spawn_opencode_plugin_template() {
  local spawn="$ROOT/bin/fm-spawn.sh"
  grep -qF 'fm-kill-guard.js' "$spawn" \
    || fail "fm-spawn must write the OpenCode kill-guard plugin"
  grep -qF 'tool.execute.before' "$spawn" \
    || fail "OpenCode kill-guard plugin must run before tool execution"
  grep -qF "exclude_path '.opencode/plugins/fm-kill-guard.js'" "$spawn" \
    || fail "OpenCode kill-guard plugin must be excluded from git's view"
  pass "fm-spawn: OpenCode worktree plugin installs the kill-guard (tool.execute.before, gitignored)"
}

test_spawn_pi_extension_template() {
  local spawn="$ROOT/bin/fm-spawn.sh"
  grep -qF 'pi.on("tool_call"' "$spawn" \
    || fail "pi per-task extension must register a tool_call kill-guard handler"
  grep -qF 'block: true' "$spawn" \
    || fail "pi kill-guard handler must block on a checker exit 2"
  pass "fm-spawn: pi per-task extension carries the kill-guard tool_call handler"
}

test_spawn_codex_grok_gaps_documented() {
  local spawn="$ROOT/bin/fm-spawn.sh"
  grep -qF 'No crew kill-guard here: codex' "$spawn" \
    || fail "the codex kill-guard gap must be documented at the codex hook case"
  grep -qF 'No crew kill-guard here for the same trust reason' "$spawn" \
    || fail "the grok kill-guard gap must be documented at the grok hook case"
  pass "fm-spawn: codex/grok worktree-hook gaps are documented in place (brief rule is the operative layer)"
}

test_brief_cleanup_rule() {
  local data brief
  data=$(mktemp -d "${TMPDIR:-/tmp}/fm-kill-brief.XXXXXX")
  FM_TEST_CLEANUP_DIRS+=("$data")
  FM_DATA_OVERRIDE="$data" FM_STATE_OVERRIDE="$data" "$ROOT/bin/fm-brief.sh" kg-ship-x demo-repo >/dev/null 2>&1 \
    || fail "fm-brief.sh ship scaffold failed"
  brief=$(cat "$data/kg-ship-x/brief.md")
  assert_contains "$brief" 'name-pattern kill' "ship brief must carry the process-cleanup rule"
  assert_contains "$brief" 'record its PID' "ship brief must instruct PID-recorded teardown"
  FM_DATA_OVERRIDE="$data" FM_STATE_OVERRIDE="$data" "$ROOT/bin/fm-brief.sh" kg-scout-x demo-repo --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh scout scaffold failed"
  brief=$(cat "$data/kg-scout-x/brief.md")
  assert_contains "$brief" 'name-pattern kill' "scout brief must carry the process-cleanup rule"
  pass "fm-brief.sh: ship and scout scaffolds carry the process-cleanup rule (every harness reads it)"
}

test_scripts_are_shellcheck_clean() {
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  shellcheck "$ROOT/bin/fm-kill-pretool-check.sh" >/dev/null 2>&1 \
    || fail "bin/fm-kill-pretool-check.sh is not shellcheck-clean"
  pass "bin/fm-kill-pretool-check.sh is shellcheck-clean"
}

test_full_acceptance_matrix
test_e2e_incident_reproduction
test_fail_open_empty_stdin
test_fail_open_unparseable_json
test_fail_open_missing_worktree
test_fail_open_missing_node
test_fail_open_missing_jq_on_stdin
test_prefilter_skips_node_without_kill_substring
test_prefilter_delegates_obfuscated_kill
test_policy_cli_direct
test_spawn_claude_hook_template
test_spawn_opencode_plugin_template
test_spawn_pi_extension_template
test_spawn_codex_grok_gaps_documented
test_brief_cleanup_rule
test_scripts_are_shellcheck_clean
