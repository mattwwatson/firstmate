---
name: project-management
description: >-
  Agent-only procedure for Firstmate project management.
  Use before adding, creating, removing, or initializing a project.
  Owns project add, create, clone, remove, initialization, registry, delivery-mode, autonomy, persona, and outward-consent decisions.
user-invocable: false
metadata:
  internal: true
---

# project-management

Use this procedure before adding, creating, removing, or initializing a project.
This skill is the single owner of Firstmate's project-management procedure.
It does not replace `secondmate-provisioning`, which owns project clones inside persistent secondmate homes.

## Preconditions and registry

Projects normally live flat under `projects/`, and `data/projects.md` is the private fleet registry; a registry entry's `+path` token records a clone that deliberately lives elsewhere (for example so the captain's per-path git identity rules apply to it).
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
`findings`, `merge`, `merge-unobservable`, and `local-merge` are granted independently, so a captain who delegates one keeps the others; bare `+yolo` grants the original three and never the narrower `merge-unobservable`.
`merge-unobservable` suits a project whose work is often invisible to the captain: firstmate merges a green PR itself only when the crewmate that built the change declared it has nothing the captain could hand-test, and everything he could see or exercise still waits for him.
Offer it when the captain says he is a merge bottleneck for work he cannot review by eye, and name `merge` instead when he means any green PR.
Confirm which grants the captain intends rather than assuming a single posture, default them all off, and add them only on the captain's explicit instruction.
Destructive, irreversible, and security-sensitive decisions still require captain approval under every combination of grants.

## Add or clone an existing project

Confirm the source URL, local project name, delivery mode, autonomy posture, and persona.
Ask the persona question before cloning (see "Choose the project's persona"): the choice depends only on the captain and the detected personas, never on a local checkout, so a project registered from a bare GitHub or Bitbucket slug gets its persona the same way.
Clone into `projects/<name>` and add the registry entry only after the destination is known to be unused.
Between cloning and adding that entry, apply and verify the chosen persona on the clone.
A `no-mistakes` project must have an `origin` remote and must complete the initialization procedure below.
A `direct-PR` project needs an `origin` remote but skips no-mistakes initialization.
A `local-only` project may have no remote and skips no-mistakes initialization.

## Create a project

Creating a GitHub repository is outward-facing.
Before making that remote change, propose the repository name, owner or organization, visibility, delivery mode, and persona, defaulting visibility to private and delivery mode to `no-mistakes`, then obtain the captain's explicit consent for those values.
Use `gh-axi` for the approved GitHub operation and consult its current help rather than relying on remembered flags.
After remote creation succeeds, clone it locally, apply and verify the chosen persona on the clone (see "Choose the project's persona"), add the registry entry, and initialize it according to its delivery mode.

For a purely `local-only` project, create a local Git repository under its unused `projects/<name>` path, choose and apply the persona, add the registry entry, and make no GitHub call.
The captain's request to create that local project authorizes this local initialization, but it does not authorize an unmentioned remote repository.

## Choose the project's persona

A clone under `projects/` does not inherit any `includeIf gitdir:` identity the captain's global config scopes to their own work trees, so a repo enrolled here can resolve to the wrong identity: misattributed commits and a push signed by the wrong key, with nothing reporting it until it surfaces in a commit log or a rejected push long after the work is done.
The persona registry closes that gap by recording the captain's explicit choice instead of inferring an identity from disk location.
`bin/fm-persona.sh` owns persona detection, application, and verification; its header owns the exit codes and mechanics.

At every registration:

1. Run `bin/fm-persona.sh list` and present the detected personas to the captain with each one's email and key.
2. Ask which persona this project uses; when only one persona exists, confirm it in the same breath rather than asking an empty question.
3. Record the answer as a `@<slug>` token in the project's registry line, using the grammar owned by the header of `bin/fm-project-mode.sh`.
4. After the clone exists, run `bin/fm-persona.sh apply <slug> projects/<name>`, then `bin/fm-persona.sh check <slug> projects/<name>`.

The captain's persona answer at registration is the authorization to apply it; do not ask a second time.
Applying writes only that one clone's local config, and every task worktree inherits it because worktrees share the parent clone's config.
A check refusal at any later point is a stop-and-investigate result, never an obstacle to bypass: relay the concrete mismatch - the email that resolved and the persona the registry records - and get the captain's decision before touching the clone's identity.

Migrate an existing registered project on next touch: when this skill loads for a project whose `bin/fm-project-mode.sh <name> --persona` reports `none`, run `bin/fm-persona.sh match projects/<name>` to see which persona the clone already resolves, confirm that answer with the captain, then record and apply it as above.
Do not sweep every registered project in one pass; migration rides the operations that were already touching the project.

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
