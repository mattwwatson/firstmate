---
name: project-management
description: >-
  Agent-only procedure for Firstmate project management.
  Use before adding, creating, removing, or initializing a project.
  Owns project add, create, clone, remove, initialization, registry, delivery-mode, autonomy, and outward-consent decisions.
user-invocable: false
metadata:
  internal: true
---

# project-management

Use this procedure before adding, creating, removing, or initializing a project.
This skill is the single owner of Firstmate's project-management procedure.
It does not replace `secondmate-provisioning`, which owns project clones inside persistent secondmate homes.

## Preconditions and registry

Projects live flat under `projects/`, and `data/projects.md` is the private fleet registry.
Use the registry format and parser contract owned by the header of `bin/fm-project-mode.sh`.
Keep each registry description useful for identifying the project, but keep delivery posture, captain-private state, and detailed project knowledge in their existing designated homes.
Do not turn the registry into project documentation.

Resolve the project name, destination, delivery mode, and autonomy posture before changing local or remote state.
Keep a newly added clone and its registry entry consistent, and roll back only artifacts created by the incomplete operation when a later initialization step fails and that rollback is safe.
Do not overwrite or repurpose an existing path.

## Delivery posture

Choose the delivery mode when adding or creating the project:

- `no-mistakes` runs the full validation pipeline before a PR and is the default when the captain does not specify a mode.
- `direct-PR` pushes and opens a PR without the no-mistakes pipeline.
- `local-only` has no required remote or PR and lands only through the approved local fast-forward path.

The optional autonomy grants change routine approval authority but do not change the delivery mode.
`findings`, `merge`, and `local-merge` are granted independently, so a captain who delegates one keeps the others; bare `+yolo` grants all three.
Confirm which grants the captain intends rather than assuming a single posture, default them all off, and add them only on the captain's explicit instruction.
Destructive, irreversible, and security-sensitive decisions still require captain approval under every combination of grants.

## Add or clone an existing project

Confirm the source URL, local project name, delivery mode, and autonomy posture.
Clone into `projects/<name>` and add the registry entry only after the destination is known to be unused.
Between cloning and adding that entry, confirm the git identity suits the remote (see "Check the git identity suits the remote").
A `no-mistakes` project must have an `origin` remote and must complete the initialization procedure below.
A `direct-PR` project needs an `origin` remote but skips no-mistakes initialization.
A `local-only` project may have no remote and skips no-mistakes initialization.

## Create a project

Creating a GitHub repository is outward-facing.
Before making that remote change, propose the repository name, owner or organization, visibility, and delivery mode, defaulting visibility to private and delivery mode to `no-mistakes`, then obtain the captain's explicit consent for those values.
Use `gh-axi` for the approved GitHub operation and consult its current help rather than relying on remembered flags.
After remote creation succeeds, clone it locally, confirm the git identity suits the remote (see "Check the git identity suits the remote"), add the registry entry, and initialize it according to its delivery mode.

For a purely `local-only` project, create a local Git repository under its unused `projects/<name>` path, add the registry entry, and make no GitHub call.
The captain's request to create that local project authorizes this local initialization, but it does not authorize an unmentioned remote repository.

## Check the git identity suits the remote

A clone under `projects/` does not inherit any `includeIf gitdir:` identity the captain's global config scopes to their own work trees, so a repo enrolled here can resolve to the wrong identity: misattributed commits and a push signed by the wrong key, with nothing reporting it until it surfaces in a commit log or a rejected push long after the work is done.
After cloning and before adding the registry entry, run `bin/fm-identity-check.sh projects/<name>`; its header owns the exit codes and mechanics.
A non-zero result is a refusal to enrol, not an obstacle to bypass: relay the concrete mismatch it reports - the email that resolved, the remote, and the identity the captain probably wanted - and get the captain's decision.
Only on the captain's explicit word, apply the offered fix with `bin/fm-identity-check.sh --apply projects/<name>`, which writes the per-repo identity into that one clone; never write it silently.
This guards enrolment only; it never audits already-enrolled projects and never rewrites an existing project's identity as a side effect.

## Initialize

Run no-mistakes initialization only for `no-mistakes` projects:

```sh
cd projects/<name> && no-mistakes init && no-mistakes doctor
```

Initialization configures the local gate and does not vendor a no-mistakes skill into the project.
Do not create a commit merely because initialization ran.
If doctor reports an environment, authentication, or daemon problem, resolve that blocker before dispatching work and never restart the shared daemon from a project operation.

## Remove

Project removal is destructive and is not one of Firstmate's current direct-write exceptions under `projects/`.
Never issue a raw removal command from Firstmate.
First obtain the captain's explicit removal decision, then inspect the current digest and authoritative repositories for in-flight or queued work, registered secondmate clones, linked worktrees, dirty files, unpushed commits, and any other unlanded work.
If any dependency or unlanded work exists, stop and report it before changing the registry.
Until a guarded removal helper and corresponding prime-directive exception exist, report that implementation gap instead of bypassing the project-write boundary.
When a clone has already been removed through an approved guarded path, or the registry is provably stale because no clone exists, remove its registry line so navigation matches reality.
