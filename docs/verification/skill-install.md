# Skill install verification

Audience: maintainer verification.

This record contains reusable version-scoped evidence for the active guarantee that a script shipped inside a public skill is executable once installed.
[`skills/no-mistakes-pr-summariser/SKILL.md`](../../skills/no-mistakes-pr-summariser/SKILL.md) owns that skill's current behaviour, setup, and limits.
Exact task chronology, branch names, and temporary paths remain in private reports or PR evidence.

## The executable bit survives an install

`skills/no-mistakes-pr-summariser` is the first public skill in this repository to ship a script rather than prose alone, and firstmate's own `bin/fm-pr-reshape.sh` execs that script.
If an installer stripped the executable bit, the skill would fail on first use with no warning, so the design depends on the bit surviving.

Verified on 2026-09-04 with the `skills` CLI 1.5.23 on macOS, using a throwaway skill carrying one `bin/probe.sh` committed at mode 100755.
Three install paths were exercised, because they are separate code paths in the CLI: a local directory, a git clone, and a global install.

```sh
npx skills add <source> --skill execbit-probe --agent claude-code -y
npx skills add "file://<source>" --skill execbit-probe --agent claude-code -y
skills add "file://<source>" --skill execbit-probe --agent claude-code --global -y
```

Observed modes on the installed copy, in that order:

```text
-rwxr-xr-x  .claude/skills/execbit-probe/bin/probe.sh
-rwxrwxr-x  .claude/skills/execbit-probe/bin/probe.sh
-rwxrwxr-x  <config dir>/skills/execbit-probe/bin/probe.sh
```

Each installed copy ran directly and printed its own output.
The group bit differs with the umask in effect; the owner execute bit is set on every path.

The real artifact behaves the same: installing `no-mistakes-pr-summariser` from this repository leaves `bin/pr-summarise.sh` at `-rwxrwxr-x`, and that installed copy reshapes a pull request end to end with nothing else of this repository present.

Re-run this check when the `skills` CLI major or minor version changes, because it is the installer, not this repository, that decides file modes.

## The global install destination follows CLAUDE_CONFIG_DIR, not HOME

`--global` resolves its destination from the agent's own configuration directory, which for Claude Code is `CLAUDE_CONFIG_DIR` when that is set.
Overriding `HOME` alone does not redirect it, so a global install intended for a scratch directory lands in the real configuration directory instead.

Verified on 2026-09-04 with the same CLI version: a `--global` install run with `HOME` pointed at an empty scratch directory reported its destination as `<CLAUDE_CONFIG_DIR>/skills/execbit-probe`, and the scratch directory stayed empty.

Test a global install by overriding `CLAUDE_CONFIG_DIR`, or stay project-level, which writes only into the current directory.
