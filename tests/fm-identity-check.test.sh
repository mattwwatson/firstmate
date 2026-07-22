#!/usr/bin/env bash
# Behavior tests for bin/fm-identity-check.sh - the enrolment-time git identity guard.
#
# The defect these tests pin down: the captain's global config applies the WORK
# identity to repos under ~/work/moroku/ via `includeIf gitdir:`, and that
# condition does not cover $FM_HOME/projects. A work repo cloned into the fleet
# therefore silently resolves to the PERSONAL identity - misattributed commits and
# a push signed by the wrong SSH key, with nothing reporting it at enrolment.
# test_reproduces_silent_wrong_identity is the end-to-end reproduction; the rest
# assert the guard's verdicts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-identity-check)

CHECK="$ROOT/bin/fm-identity-check.sh"

# The fixture reproduces the captain's arrangement: personal identity globally,
# work identity applied to ~/work/moroku/ through includeIf gitdir. Each caller
# gets its own HOME so cases cannot contaminate each other.
#
# fm_identity_fixture <name> -> echoes the fixture HOME
fm_identity_fixture() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/work/moroku" "$home/fm/projects"
  cat > "$home/.gitconfig" <<EOF
[user]
	name = Matthew Watson
	email = mattw.watson@gmail.com
[includeIf "gitdir:~/work/moroku/"]
	path = ~/work/moroku/.gitconfig-moroku
EOF
  cat > "$home/work/moroku/.gitconfig-moroku" <<'EOF'
[user]
	email = mattw@moroku.com
[core]
	sshCommand = ssh -i ~/.ssh/id_moroku
EOF
  # A work repo in the location the includeIf rule actually covers. This is the
  # evidence that ties the work identity to bitbucket.org/moroku remotes.
  git init -q "$home/work/moroku/pay-api"
  git -C "$home/work/moroku/pay-api" remote add origin git@bitbucket.org:moroku/pay-api.git
  printf '%s\n' "$home"
}

# fm_identity_clone <home> <name> [remote-url] -> echoes the clone path.
# Creates a repo under the fleet's projects/ dir, where no includeIf reaches.
fm_identity_clone() {
  local home=$1 name=$2 url=${3:-} repo="$1/fm/projects/$2"
  git init -q "$repo"
  [ -n "$url" ] && git -C "$repo" remote add origin "$url"
  printf '%s\n' "$repo"
}

# Run the guard with the fixture HOME and no ambient identity overrides, so the
# resolved identity comes from the fixture's git config alone.
# fm_identity_run <home> <args...>; sets OUT and CODE.
fm_identity_run() {
  local home=$1
  shift
  OUT=$(HOME="$home" env -u XDG_CONFIG_HOME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_EMAIL \
    -u GIT_AUTHOR_NAME -u GIT_COMMITTER_NAME -u GIT_CONFIG_GLOBAL \
    "$CHECK" "$@" 2>&1)
  CODE=$?
  return 0
}

# --- the reproduction -------------------------------------------------------

test_reproduces_silent_wrong_identity() {
  local home repo author
  home=$(fm_identity_fixture repro)
  repo=$(fm_identity_clone "$home" pay-api git@bitbucket.org:moroku/pay-api.git)

  # Same remote, two locations, two identities: this is the defect.
  local blessed fleet
  blessed=$(HOME="$home" env -u XDG_CONFIG_HOME git -C "$home/work/moroku/pay-api" config --get user.email)
  fleet=$(HOME="$home" env -u XDG_CONFIG_HOME git -C "$repo" config --get user.email)
  [ "$blessed" = "mattw@moroku.com" ] || fail "fixture broken: blessed location resolved '$blessed'"
  [ "$fleet" = "mattw.watson@gmail.com" ] || fail "fixture broken: fleet clone resolved '$fleet'"

  # A crewmate commits in the fleet clone and git says nothing at all.
  printf 'work\n' > "$repo/f.txt"
  HOME="$home" env -u XDG_CONFIG_HOME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_EMAIL \
    -u GIT_AUTHOR_NAME -u GIT_COMMITTER_NAME git -C "$repo" add f.txt
  HOME="$home" env -u XDG_CONFIG_HOME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_EMAIL \
    -u GIT_AUTHOR_NAME -u GIT_COMMITTER_NAME git -C "$repo" commit -qm "fix: something"
  author=$(HOME="$home" env -u XDG_CONFIG_HOME git -C "$repo" log -1 --pretty='%ae')
  [ "$author" = "mattw.watson@gmail.com" ] || fail "fixture broken: commit authored as '$author'"

  # The guard is what makes that failure loud at enrolment.
  fm_identity_run "$home" "$repo"
  expect_code 2 "$CODE" "guard did not refuse the misattributing clone"
  assert_contains "$OUT" "mismatch:" "verdict line missing"
  pass "fm-identity-check.sh: refuses the clone that would silently commit as the personal identity"
}

# --- concrete reporting -----------------------------------------------------

test_mismatch_message_is_actionable() {
  local home repo
  home=$(fm_identity_fixture concrete)
  repo=$(fm_identity_clone "$home" billing git@bitbucket.org:moroku/billing.git)

  fm_identity_run "$home" "$repo"
  expect_code 2 "$CODE" "guard did not refuse a work remote under the personal identity"
  assert_contains "$OUT" "mattw.watson@gmail.com" "does not name the email that actually resolved"
  assert_contains "$OUT" "mattw@moroku.com" "does not name the identity the captain probably wanted"
  assert_contains "$OUT" "bitbucket.org/moroku" "does not name the remote host and owner"
  assert_contains "$OUT" "git@bitbucket.org:moroku/billing.git" "does not name the remote URL"
  assert_contains "$OUT" "$home/.gitconfig" "does not say where the resolved identity came from"
  assert_contains "$OUT" ".gitconfig-moroku" "does not cite the config that applies the expected identity"
  assert_contains "$OUT" "--apply" "does not offer the per-repo fix"
  pass "fm-identity-check.sh: mismatch names the resolved email, the remote, and the expected identity"
}

test_wrong_ssh_key_is_a_mismatch() {
  local home repo
  home=$(fm_identity_fixture sshkey)
  repo=$(fm_identity_clone "$home" ssh-only git@bitbucket.org:moroku/ssh-only.git)
  # Right email, but still no work SSH key: the push would be rejected.
  git -C "$repo" config user.email mattw@moroku.com

  fm_identity_run "$home" "$repo"
  expect_code 2 "$CODE" "guard accepted a work remote with the wrong SSH key"
  assert_contains "$OUT" "core.sshCommand" "does not report the SSH command mismatch"
  assert_contains "$OUT" "id_moroku" "does not name the SSH key the captain probably wanted"
  pass "fm-identity-check.sh: refuses a matching email that would still push with the wrong SSH key"
}

# --- the matching cases proceed ---------------------------------------------

test_ungoverned_remote_proceeds() {
  local home repo
  home=$(fm_identity_fixture personal)
  repo=$(fm_identity_clone "$home" side-project git@github.com:mattwwatson/side-project.git)

  fm_identity_run "$home" "$repo"
  expect_code 0 "$CODE" "guard refused a remote no identity rule governs"
  assert_contains "$OUT" "ok:" "verdict line missing"
  assert_contains "$OUT" "mattw.watson@gmail.com" "does not state the identity that will be used"
  pass "fm-identity-check.sh: a remote governed by no rule proceeds under the global identity"
}

test_correct_per_repo_identity_proceeds() {
  local home repo
  home=$(fm_identity_fixture fixed)
  repo=$(fm_identity_clone "$home" fixed-api git@bitbucket.org:moroku/fixed-api.git)
  git -C "$repo" config user.email mattw@moroku.com
  git -C "$repo" config core.sshCommand 'ssh -i ~/.ssh/id_moroku'

  fm_identity_run "$home" "$repo"
  expect_code 0 "$CODE" "guard refused a clone whose per-repo identity already suits the remote"
  assert_contains "$OUT" "ok:" "verdict line missing"
  pass "fm-identity-check.sh: a clone already carrying the right per-repo identity proceeds"
}

test_remoteless_repo_proceeds() {
  local home repo
  home=$(fm_identity_fixture localonly)
  repo=$(fm_identity_clone "$home" scratch)

  fm_identity_run "$home" "$repo"
  expect_code 0 "$CODE" "guard refused a local-only project with no remote"
  assert_contains "$OUT" "ok:" "verdict line missing"
  pass "fm-identity-check.sh: a local-only project with no remote proceeds"
}

# --- absent or unreadable identity data refuses -----------------------------

test_missing_identity_refuses() {
  local home repo
  home=$(fm_identity_fixture noident)
  repo=$(fm_identity_clone "$home" orphan git@github.com:mattwwatson/orphan.git)
  # No identity configured anywhere: commits here would be attributed to whatever
  # git guesses, or refused outright. Never assume that is fine.
  : > "$home/.gitconfig"

  fm_identity_run "$home" "$repo"
  expect_code 3 "$CODE" "guard did not refuse an unresolvable identity"
  assert_contains "$OUT" "unreadable:" "verdict line missing"
  assert_contains "$OUT" "user.email" "does not name the missing setting"
  pass "fm-identity-check.sh: refuses when no identity resolves rather than assuming it is fine"
}

test_unreadable_include_refuses() {
  local home repo
  home=$(fm_identity_fixture badinclude)
  repo=$(fm_identity_clone "$home" mystery git@bitbucket.org:moroku/mystery.git)
  # The rule that would decide this clone's identity cannot be read, so whether a
  # mismatch exists is unknowable. Unknowable must refuse, not pass.
  rm -f "$home/work/moroku/.gitconfig-moroku"

  fm_identity_run "$home" "$repo"
  expect_code 3 "$CODE" "guard did not refuse an unreadable identity rule"
  assert_contains "$OUT" "unreadable:" "verdict line missing"
  assert_contains "$OUT" ".gitconfig-moroku" "does not name the config it could not read"
  pass "fm-identity-check.sh: refuses when an identity rule cannot be read"
}

test_non_repo_errors() {
  local home dir
  home=$(fm_identity_fixture notrepo)
  dir="$home/fm/projects/not-a-repo"
  mkdir -p "$dir"

  fm_identity_run "$home" "$dir"
  expect_code 1 "$CODE" "guard did not error on a path that is not a git repository"
  assert_contains "$OUT" "not a git repository" "does not say the path is not a repository"
  pass "fm-identity-check.sh: errors on a path that is not a git repository"
}

# --- the offered fix --------------------------------------------------------

test_apply_writes_per_repo_identity() {
  local home repo email ssh
  home=$(fm_identity_fixture apply)
  repo=$(fm_identity_clone "$home" apply-api git@bitbucket.org:moroku/apply-api.git)

  fm_identity_run "$home" --apply "$repo"
  expect_code 0 "$CODE" "--apply failed"
  assert_contains "$OUT" "applied:" "verdict line missing"

  email=$(git -C "$repo" config --local --get user.email)
  ssh=$(git -C "$repo" config --local --get core.sshCommand)
  [ "$email" = "mattw@moroku.com" ] || fail "--apply wrote user.email '$email'"
  [ "$ssh" = "ssh -i ~/.ssh/id_moroku" ] || fail "--apply wrote core.sshCommand '$ssh'"

  # Applying the fix is what makes the guard pass; re-running must now agree.
  fm_identity_run "$home" "$repo"
  expect_code 0 "$CODE" "guard still refuses after --apply wrote the expected identity"
  pass "fm-identity-check.sh: --apply writes the expected per-repo identity and clears the refusal"
}

test_apply_refuses_without_a_concrete_identity() {
  local home repo
  home=$(fm_identity_fixture applynothing)
  repo=$(fm_identity_clone "$home" unknown git@github.com:mattwwatson/unknown.git)

  fm_identity_run "$home" --apply "$repo"
  expect_code 1 "$CODE" "--apply invented an identity for a remote no rule governs"
  assert_contains "$OUT" "nothing to apply" "does not explain why there is nothing to apply"
  if git -C "$repo" config --local --get user.email >/dev/null 2>&1; then
    fail "--apply wrote a local identity it could not justify"
  fi
  pass "fm-identity-check.sh: --apply refuses when no rule names a concrete identity"
}

test_reproduces_silent_wrong_identity
test_mismatch_message_is_actionable
test_wrong_ssh_key_is_a_mismatch
test_ungoverned_remote_proceeds
test_correct_per_repo_identity_proceeds
test_remoteless_repo_proceeds
test_missing_identity_refuses
test_unreadable_include_refuses
test_non_repo_errors
test_apply_writes_per_repo_identity
test_apply_refuses_without_a_concrete_identity
