---
name: git-devsync
description: Git workflow for incrementally replaying a feature branch's not-yet-deployed commits onto the latest dev branch through a sibling _devsync branch, resolving cherry-pick conflicts there, merging the resolved devsync branch back into dev, and returning to the source feature branch. Use when the user asks to create or refresh a current-branch_devsync branch from latest dev, cherry-pick only pending source branch changes, handle conflicts, merge back to dev, and avoid remaining on the intermediate _devsync branch.
---

# Git Devsync

## Overview

Use this skill to project a feature branch onto `dev` without rebasing, merging `dev` into the feature branch, or rewriting the source branch.

The core idea is incremental deployment: create or refresh `<source-branch>_devsync` from the current effective `dev`, cherry-pick only the source commits that are not already deployed to `dev`, resolve conflicts on `_devsync`, run checks, fast-forward local `dev` to `_devsync`, then return the invoking worktree to `<source-branch>`.

## Safety Rules

- Do not rewrite, reset, or delete the source feature branch.
- Require a clean worktree before syncing or merging back. Ask the user whether to commit or stash if there are local changes.
- Do not push `dev`, `_devsync`, or the source branch unless the user explicitly asks.
- If `git fetch` fails over SSH, test the configured SSH host with `ssh -T` when discoverable from `git remote -v`; if fetch still fails, give the exact commands for the user to run in their terminal.
- If the source branch contains merge commits, stop and inspect manually. Plain `git cherry-pick` of merge commits requires choosing a mainline parent.
- If `_devsync` exists and is not contained in effective `dev`, do not overwrite it unless the user explicitly wants `--recreate`.
- Return to the source feature branch only after merge-back succeeds. Preserve the current branch and conflict state when sync, validation, or merge-back fails.

## Deployed Commit Detection

Do not identify deployed commits by SHA alone. Cherry-pick creates new SHAs.

The script uses layered detection:

1. `git cherry-pick -x` trailer: new syncs record the original source SHA in the dev commit message, so later runs can skip that source commit even if conflict resolution changed the patch.
2. `git cherry` patch-id: legacy commits without `-x` can still be skipped when the patch is equivalent in `dev`.
3. Manual review: if a historical commit was cherry-picked without `-x` and conflict resolution changed the patch, automation cannot prove it is deployed. Treat it as pending unless the user gives an explicit base or skip strategy.

## Locate the Bundled Script

Resolve `DEVSYNC_SKILL_DIR` to the absolute directory containing this loaded `SKILL.md`. Derive it from the skill path provided by Codex; do not assume a username, installation directory, or the current working directory.

Set `DEVSYNC_SKILL_DIR` to that resolved path before using the commands below. If subsequent shell calls start fresh sessions, set it again in each call. Keep the working directory inside the Git repository being synced; do not change into the skill directory to execute the script. Invoke the script with `bash` so installation methods that drop executable permissions still work.

## Quick Start

From the source feature branch, inspect what would sync:

```bash
bash "$DEVSYNC_SKILL_DIR/scripts/devsync.sh" status
```

Create or refresh `_devsync` and cherry-pick only pending commits:

```bash
bash "$DEVSYNC_SKILL_DIR/scripts/devsync.sh" sync
```

`start` remains an alias for `sync` for compatibility:

```bash
bash "$DEVSYNC_SKILL_DIR/scripts/devsync.sh" start
```

If conflicts occur, resolve them on `_devsync`:

```bash
git status
git diff
git add <resolved-files>
git cherry-pick --continue
```

After conflicts are resolved and tests pass:

```bash
bash "$DEVSYNC_SKILL_DIR/scripts/devsync.sh" merge-back
```

After a successful merge-back, the script automatically switches the invoking worktree back to the source feature branch.

## Workflow

1. Inspect the current branch and worktree:

```bash
git status --short --branch
git rev-parse --abbrev-ref HEAD
```

2. Check pending commits:

```bash
bash "$DEVSYNC_SKILL_DIR/scripts/devsync.sh" status
```

The status output shows:
- source branch and source base
- effective dev ref
- source commits
- commits already deployed by `-x` trailer
- commits already deployed by patch-id
- pending commits

3. Sync pending commits:

```bash
bash "$DEVSYNC_SKILL_DIR/scripts/devsync.sh" sync
```

The script:
- fetches `origin dev`
- chooses effective `dev`: local `dev` if it already contains `origin/dev`, otherwise `origin/dev`
- chooses source base from upstream, then `origin/main`/`main` when it is an ancestor, otherwise merge-base with effective `dev`
- creates or safely refreshes `<source>_devsync` from effective `dev`
- cherry-picks only pending commits with `git cherry-pick -x`

4. If cherry-pick conflicts happen, stay on `_devsync`, resolve conflicts, and continue:

```bash
git status --short --branch
git diff
git add <resolved-files>
git cherry-pick --continue
```

Repeat until cherry-pick finishes.

5. Run the relevant checks for the repository. Prefer targeted tests first, then broader tests when the change touches shared code.

6. Merge back to local `dev` and return to the source feature branch:

```bash
bash "$DEVSYNC_SKILL_DIR/scripts/devsync.sh" merge-back
```

The merge-back step fetches `origin/dev`, switches to local `dev`, fast-forwards it to `origin/dev`, fast-forwards it to `_devsync`, then switches the invoking worktree back to the source feature branch. If `dev` is checked out in another worktree, perform the two `--ff-only` merges there and explicitly switch the invoking worktree back to the source branch after they succeed.

## Repeated Syncs

When a feature branch receives more commits after an earlier dev deployment, run `status` then `sync` again from the feature branch. The script should skip previously deployed commits by `-x` trailer or patch-id and cherry-pick only the new pending commits.

If an existing `_devsync` branch was already merged into `dev`, `sync` may safely refresh it from effective `dev`. If `_devsync` contains unresolved or unmerged work, use `--reuse` to continue there or `--recreate` only when discarding that branch state is intentional.

## Options

Use `--source <branch>` when not currently on the source branch. `merge-back` also uses this value as the branch to restore after success:

```bash
bash "$DEVSYNC_SKILL_DIR/scripts/devsync.sh" sync --source feature/example
```

Use `--source-base <ref>` when the branch's own commits should be calculated relative to a specific base:

```bash
bash "$DEVSYNC_SKILL_DIR/scripts/devsync.sh" sync --source-base origin/main
```

Use `--reuse` only when continuing with an existing `_devsync` branch is intentional.

Use `--recreate` only when intentionally resetting an existing `_devsync` branch to effective `dev`.

Use `--dry-run` to print mutating commands without changing branches.
