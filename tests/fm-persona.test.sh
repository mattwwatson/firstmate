#!/usr/bin/env bash
# Behavior tests for bin/fm-persona.sh - the captain's git-identity personas.
#
# The defect this machinery guards: the captain's global config applies a WORK
# identity to repos under ~/work/moroku/ via `includeIf gitdir:`, and that
# condition does not cover $FM_HOME/projects. A work repo cloned into the fleet
# therefore silently resolves to the PERSONAL identity - misattributed commits
# and a push signed by the wrong SSH key, with nothing reporting it.
# The persona registry replaces inferring the right identity from disk
# location: the captain RECORDS which persona a project uses (@<slug> in
# data/projects.md), registration applies it to the clone, and check verifies a
# clone against the record. test_recorded_persona_catches_the_wrong_identity is
# the end-to-end reproduction of the defect being caught through the record.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-persona)

PERSONA="$ROOT/bin/fm-persona.sh"

# The fixture reproduces the captain's arrangement: personal identity globally,
# work identity applied to ~/work/moroku/ through includeIf gitdir. Each caller
# gets its own HOME so cases cannot contaminate each other.
#
# fm_persona_fixture <name> -> echoes the fixture HOME
fm_persona_fixture() {
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
  printf '%s\n' "$home"
}

# fm_persona_repo <home> <name> -> echoes a repo path under the fleet's
# projects/ dir, where no includeIf reaches.
fm_persona_repo() {
  local repo="$1/fm/projects/$2"
  git init -q "$repo"
  printf '%s\n' "$repo"
}

# Run a command with the fixture HOME and no ambient identity overrides, so the
# resolved identity comes from the fixture's git config alone.
# fm_persona_run <home> <cmd...>; sets OUT and CODE.
fm_persona_run() {
  local home=$1
  shift
  OUT=$(HOME="$home" env -u XDG_CONFIG_HOME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_EMAIL \
    -u GIT_AUTHOR_NAME -u GIT_COMMITTER_NAME -u GIT_CONFIG_GLOBAL \
    GIT_CONFIG_NOSYSTEM=1 "$@" 2>&1)
  CODE=$?
  return 0
}

# --- detection ---------------------------------------------------------------

test_detects_global_and_includeif_personas() {
  local home
  home=$(fm_persona_fixture detect)
  fm_persona_run "$home" "$PERSONA" list --porcelain
  expect_code 0 "$CODE" "list failed"
  assert_contains "$OUT" "default	mattw.watson@gmail.com	Matthew Watson" \
    "global identity was not detected as the default persona"
  assert_contains "$OUT" "moroku	mattw@moroku.com		ssh -i ~/.ssh/id_moroku" \
    "includeIf identity was not detected as a persona named after its subtree"
  pass "fm-persona.sh: detects the global and each includeIf identity from the real config"
}

test_list_presents_email_and_key_per_persona() {
  local home
  home=$(fm_persona_fixture human)
  fm_persona_run "$home" "$PERSONA" list
  expect_code 0 "$CODE" "list failed"
  assert_contains "$OUT" "persona: default" "default persona missing from the listing"
  assert_contains "$OUT" "persona: moroku" "moroku persona missing from the listing"
  assert_contains "$OUT" "mattw@moroku.com" "listing does not show the work email"
  assert_contains "$OUT" "ssh -i ~/.ssh/id_moroku" "listing does not show the work SSH key"
  assert_contains "$OUT" ".gitconfig-moroku" "listing does not cite the config a persona came from"
  pass "fm-persona.sh: the captain-facing listing shows each persona's email and key"
}

test_detects_multiple_work_identities() {
  local home
  home=$(fm_persona_fixture multi)
  mkdir -p "$home/work/acme"
  cat >> "$home/.gitconfig" <<EOF
[includeIf "gitdir:~/work/acme/"]
	path = ~/work/acme/.gitconfig-acme
EOF
  cat > "$home/work/acme/.gitconfig-acme" <<'EOF'
[user]
	email = mattw@acme.example
EOF
  fm_persona_run "$home" "$PERSONA" list --porcelain
  expect_code 0 "$CODE" "list failed with two work identities"
  assert_contains "$OUT" "moroku	mattw@moroku.com" "first work persona missing"
  assert_contains "$OUT" "acme	mattw@acme.example" "second work persona missing"
  pass "fm-persona.sh: extends to multiple work identities, one persona each"
}

test_glob_condition_slug_falls_back_to_the_config_name() {
  local home
  home=$(fm_persona_fixture glob)
  cat > "$home/.gitconfig" <<EOF
[user]
	name = Matthew Watson
	email = mattw.watson@gmail.com
[includeIf "gitdir:~/work/*/"]
	path = ~/work/moroku/.gitconfig-moroku
EOF
  fm_persona_run "$home" "$PERSONA" list --porcelain
  expect_code 0 "$CODE" "list failed on a glob condition"
  assert_contains "$OUT" "moroku	mattw@moroku.com" \
    "glob condition did not fall back to naming the persona after its config file"
  pass "fm-persona.sh: a glob condition still yields a persona, named from its config file"
}

test_show_prints_the_effective_identity() {
  local home
  home=$(fm_persona_fixture show)
  fm_persona_run "$home" "$PERSONA" show moroku
  expect_code 0 "$CODE" "show failed"
  assert_contains "$OUT" "slug=moroku" "show missing the slug"
  assert_contains "$OUT" "email=mattw@moroku.com" "show missing the email"
  assert_contains "$OUT" "name=Matthew Watson" "show did not fall back to the global name"
  assert_contains "$OUT" "ssh=ssh -i ~/.ssh/id_moroku" "show missing the SSH command"
  assert_contains "$OUT" "condition=gitdir:~/work/moroku/" "show missing the condition"
  pass "fm-persona.sh: show prints the effective identity with global fallbacks filled in"
}

# --- apply and worktree inheritance ------------------------------------------

test_apply_writes_identity_and_worktrees_inherit_it() {
  local home repo email ssh author
  home=$(fm_persona_fixture apply)
  repo=$(fm_persona_repo "$home" pay-api)

  fm_persona_run "$home" "$PERSONA" apply moroku "$repo"
  expect_code 0 "$CODE" "apply failed: $OUT"
  assert_contains "$OUT" "applied:" "verdict line missing"
  email=$(git -C "$repo" config --local --get user.email)
  ssh=$(git -C "$repo" config --local --get core.sshCommand)
  [ "$email" = "mattw@moroku.com" ] || fail "apply wrote user.email '$email'"
  [ "$ssh" = "ssh -i ~/.ssh/id_moroku" ] || fail "apply wrote core.sshCommand '$ssh'"

  # Worktrees share the parent clone's local config, so a task worktree of the
  # applied clone must commit as the recorded persona with no further setup.
  HOME="$home" env -u XDG_CONFIG_HOME GIT_CONFIG_NOSYSTEM=1 git -C "$repo" \
    -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
  HOME="$home" env -u XDG_CONFIG_HOME GIT_CONFIG_NOSYSTEM=1 git -C "$repo" \
    worktree add -q "$home/fm/wt" -b task
  printf 'work\n' > "$home/fm/wt/f.txt"
  HOME="$home" env -u XDG_CONFIG_HOME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_EMAIL \
    -u GIT_AUTHOR_NAME -u GIT_COMMITTER_NAME GIT_CONFIG_NOSYSTEM=1 git -C "$home/fm/wt" add f.txt
  HOME="$home" env -u XDG_CONFIG_HOME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_EMAIL \
    -u GIT_AUTHOR_NAME -u GIT_COMMITTER_NAME GIT_CONFIG_NOSYSTEM=1 git -C "$home/fm/wt" commit -qm "fix: x"
  author=$(HOME="$home" env -u XDG_CONFIG_HOME GIT_CONFIG_NOSYSTEM=1 git -C "$home/fm/wt" log -1 --pretty='%ae')
  [ "$author" = "mattw@moroku.com" ] || fail "worktree commit authored as '$author', not the applied persona"
  pass "fm-persona.sh: apply writes the clone's local identity and task worktrees inherit it"
}

test_apply_converges_stale_local_overrides() {
  local home repo
  home=$(fm_persona_fixture converge)
  repo=$(fm_persona_repo "$home" back-to-personal)
  # The clone previously carried the work persona; re-applying default must
  # remove the stale work key, not leave it to sign personal pushes.
  git -C "$repo" config user.email mattw@moroku.com
  git -C "$repo" config core.sshCommand 'ssh -i ~/.ssh/id_moroku'

  fm_persona_run "$home" "$PERSONA" apply default "$repo"
  expect_code 0 "$CODE" "apply default failed: $OUT"
  [ "$(git -C "$repo" config --local --get user.email)" = "mattw.watson@gmail.com" ] \
    || fail "apply did not rewrite user.email"
  if git -C "$repo" config --local --get core.sshCommand >/dev/null 2>&1; then
    fail "apply left a stale core.sshCommand the persona does not set"
  fi
  fm_persona_run "$home" "$PERSONA" check default "$repo"
  expect_code 0 "$CODE" "check disagrees with the apply it just converged"
  pass "fm-persona.sh: apply converges the clone, removing overrides the persona does not set"
}

# --- check: the backstop against the recorded persona ------------------------

test_recorded_persona_catches_the_wrong_identity() {
  local home fmhome repo persona
  home=$(fm_persona_fixture repro)
  repo=$(fm_persona_repo "$home" pay-api)

  # The defect: the fleet clone silently resolves the PERSONAL identity even
  # though the project is work - no includeIf covers fm/projects.
  local fleet
  fleet=$(HOME="$home" env -u XDG_CONFIG_HOME GIT_CONFIG_NOSYSTEM=1 git -C "$repo" config --get user.email)
  [ "$fleet" = "mattw.watson@gmail.com" ] || fail "fixture broken: fleet clone resolved '$fleet'"

  # The captain recorded the project's persona in the registry; the check runs
  # against that RECORD, not against any inference from disk location.
  fmhome="$home/fmhome"
  mkdir -p "$fmhome/data"
  printf '%s\n' '- pay-api [no-mistakes @moroku] - payments (added 2026-07-23)' > "$fmhome/data/projects.md"
  persona=$(FM_HOME="$fmhome" "$ROOT/bin/fm-project-mode.sh" pay-api --persona)
  [ "$persona" = "moroku" ] || fail "registry did not record persona 'moroku', got '$persona'"

  fm_persona_run "$home" "$PERSONA" check "$persona" "$repo"
  expect_code 2 "$CODE" "check did not refuse the clone that contradicts its recorded persona"
  assert_contains "$OUT" "mismatch:" "verdict line missing"
  assert_contains "$OUT" "mattw.watson@gmail.com" "does not name the email that actually resolved"
  assert_contains "$OUT" "mattw@moroku.com" "does not name the recorded persona's email"
  assert_contains "$OUT" "apply" "does not offer the fix"
  pass "fm-persona.sh: the recorded persona catches the silently-wrong identity end to end"
}

test_check_refuses_the_wrong_ssh_key() {
  local home repo
  home=$(fm_persona_fixture sshkey)
  repo=$(fm_persona_repo "$home" ssh-only)
  # Right email, but still no work SSH key: the push would be rejected.
  git -C "$repo" config user.email mattw@moroku.com

  fm_persona_run "$home" "$PERSONA" check moroku "$repo"
  expect_code 2 "$CODE" "check accepted a clone missing the persona's SSH key"
  assert_contains "$OUT" "core.sshCommand" "does not report the SSH command mismatch"
  assert_contains "$OUT" "id_moroku" "does not name the SSH key the persona records"
  pass "fm-persona.sh: check refuses a matching email that would still push with the wrong key"
}

test_check_passes_a_correctly_applied_clone() {
  local home repo
  home=$(fm_persona_fixture happy)
  repo=$(fm_persona_repo "$home" fixed-api)
  git -C "$repo" config user.email mattw@moroku.com
  git -C "$repo" config core.sshCommand 'ssh -i ~/.ssh/id_moroku'

  fm_persona_run "$home" "$PERSONA" check moroku "$repo"
  expect_code 0 "$CODE" "check refused a clone that resolves its recorded persona"
  assert_contains "$OUT" "ok:" "verdict line missing"

  fm_persona_run "$home" "$PERSONA" check default "$(fm_persona_repo "$home" personal)"
  expect_code 0 "$CODE" "check refused a fresh clone recorded as the default persona"
  pass "fm-persona.sh: check passes clones that resolve their recorded persona"
}

test_check_refuses_an_unknown_recorded_persona() {
  local home repo
  home=$(fm_persona_fixture unknown)
  repo=$(fm_persona_repo "$home" mystery)

  fm_persona_run "$home" "$PERSONA" check retired-org "$repo"
  expect_code 3 "$CODE" "check did not refuse a persona no config defines"
  assert_contains "$OUT" "unreadable:" "verdict line missing"
  assert_contains "$OUT" "retired-org" "does not name the unknown persona"
  assert_contains "$OUT" "default moroku" "does not list the personas that were detected"
  pass "fm-persona.sh: a recorded persona the config no longer defines refuses, never passes"
}

test_check_refuses_an_unresolvable_identity() {
  local home repo
  home=$(fm_persona_fixture noident)
  repo=$(fm_persona_repo "$home" orphan)
  # The global config keeps its includeIf (so the moroku persona exists) but
  # loses its own identity; the untouched clone then resolves no email at all.
  cat > "$home/.gitconfig" <<EOF
[includeIf "gitdir:~/work/moroku/"]
	path = ~/work/moroku/.gitconfig-moroku
EOF

  fm_persona_run "$home" "$PERSONA" check moroku "$repo"
  expect_code 3 "$CODE" "check did not refuse a clone resolving no identity"
  assert_contains "$OUT" "unreadable:" "verdict line missing"
  pass "fm-persona.sh: a clone resolving no identity refuses rather than reading as fine"
}

test_unreadable_include_refuses() {
  local home
  home=$(fm_persona_fixture badinclude)
  # The rule that defines a persona cannot be read, so the persona set is
  # unknowable. Unknowable must refuse, not pass.
  rm -f "$home/work/moroku/.gitconfig-moroku"

  fm_persona_run "$home" "$PERSONA" list
  expect_code 3 "$CODE" "list did not refuse an unreadable identity rule"
  assert_contains "$OUT" "unreadable:" "verdict line missing"
  assert_contains "$OUT" ".gitconfig-moroku" "does not name the config it could not read"
  pass "fm-persona.sh: refuses when an identity rule cannot be read"
}

test_non_repo_errors() {
  local home dir
  home=$(fm_persona_fixture notrepo)
  dir="$home/fm/projects/not-a-repo"
  mkdir -p "$dir"

  fm_persona_run "$home" "$PERSONA" check moroku "$dir"
  expect_code 1 "$CODE" "check did not error on a path that is not a git repository"
  assert_contains "$OUT" "not a git repository" "does not say the path is not a repository"
  pass "fm-persona.sh: errors on a path that is not a git repository"
}

# --- match: the migration aid ------------------------------------------------

test_match_names_the_persona_a_clone_already_resolves() {
  local home repo
  home=$(fm_persona_fixture match)
  repo=$(fm_persona_repo "$home" migrate-me)

  # An untouched fleet clone resolves the global identity.
  fm_persona_run "$home" "$PERSONA" match "$repo"
  expect_code 0 "$CODE" "match failed on a clone resolving the default persona"
  [ "$OUT" = "default" ] || fail "match printed '$OUT', expected 'default'"

  # After applying the work persona, match reports the migration answer.
  fm_persona_run "$home" "$PERSONA" apply moroku "$repo"
  expect_code 0 "$CODE" "apply failed"
  fm_persona_run "$home" "$PERSONA" match "$repo"
  expect_code 0 "$CODE" "match failed on an applied clone"
  [ "$OUT" = "moroku" ] || fail "match printed '$OUT', expected 'moroku'"
  pass "fm-persona.sh: match reports which persona a clone already resolves"
}

test_match_reports_when_nothing_matches() {
  local home repo
  home=$(fm_persona_fixture nomatch)
  repo=$(fm_persona_repo "$home" stranger)
  git -C "$repo" config user.email someone@else.example

  fm_persona_run "$home" "$PERSONA" match "$repo"
  expect_code 1 "$CODE" "match claimed a persona for an identity no config defines"
  assert_contains "$OUT" "someone@else.example" "does not name the identity that failed to match"
  pass "fm-persona.sh: match reports a non-matching identity instead of guessing"
}

# --- secondmate seeding carries the recorded persona -------------------------

test_seeded_secondmate_clone_carries_the_recorded_persona() {
  local home fmhome sub email ssh
  home=$(fm_persona_fixture seed)
  fmhome="$home/fmhome"
  sub="$home/subhome"
  mkdir -p "$fmhome/projects" "$fmhome/data" "$fmhome/state"
  fm_git_init_commit "$fmhome/projects/pay-api"
  fm_git_add_origin "$fmhome/projects/pay-api" "$home/remotes/pay-api.git"
  printf '%s\n' '- pay-api [direct-PR @moroku] - payments (added 2026-07-23)' > "$fmhome/data/projects.md"

  # A fresh clone does not carry the parent clone's local config, so seeding
  # must re-apply the recorded persona or the secondmate commits as the
  # global identity - the exact defect the registry exists to stop.
  fm_persona_run "$home" env FM_HOME="$fmhome" \
    FM_SECONDMATE_CHARTER='payments work' FM_SECONDMATE_SCOPE='payments work' \
    "$ROOT/bin/fm-home-seed.sh" pay "$sub" pay-api
  expect_code 0 "$CODE" "seed failed: $OUT"
  email=$(git -C "$sub/projects/pay-api" config --local --get user.email)
  ssh=$(git -C "$sub/projects/pay-api" config --local --get core.sshCommand)
  [ "$email" = "mattw@moroku.com" ] || fail "seeded clone user.email is '$email', not the recorded persona"
  [ "$ssh" = "ssh -i ~/.ssh/id_moroku" ] || fail "seeded clone core.sshCommand is '$ssh'"

  # The registry line, persona token included, reached the secondmate home.
  [ "$(FM_HOME="$sub" "$ROOT/bin/fm-project-mode.sh" pay-api --persona)" = "moroku" ] \
    || fail "persona token did not propagate into the secondmate registry"
  pass "fm-home-seed.sh: a seeded clone carries the recorded persona, not the global identity"
}

test_detects_global_and_includeif_personas
test_list_presents_email_and_key_per_persona
test_detects_multiple_work_identities
test_glob_condition_slug_falls_back_to_the_config_name
test_show_prints_the_effective_identity
test_apply_writes_identity_and_worktrees_inherit_it
test_apply_converges_stale_local_overrides
test_recorded_persona_catches_the_wrong_identity
test_check_refuses_the_wrong_ssh_key
test_check_passes_a_correctly_applied_clone
test_check_refuses_an_unknown_recorded_persona
test_check_refuses_an_unresolvable_identity
test_unreadable_include_refuses
test_non_repo_errors
test_match_names_the_persona_a_clone_already_resolves
test_match_reports_when_nothing_matches
test_seeded_secondmate_clone_carries_the_recorded_persona

echo "# all fm-persona tests passed"
