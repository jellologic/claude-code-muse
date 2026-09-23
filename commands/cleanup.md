---
description: Reap the worktrees, branches and artifacts left behind by delegated muse runs
argument-hint: "[--yes] [--all] [--artifacts] [--discard-unharvested]"
disable-model-invocation: true
allowed-tools: Bash(muse-cleanup:*), Read
model: haiku
---

# Reap delegation leftovers

Every delegated task leaves a worktree and a branch, and nothing removes them automatically —
because the patch inside an unfinished worktree is the only copy of that work.

Always show the dry run first:

```bash
muse-cleanup [--repo .] [--out .muse-fleet]
```

It lists what would go, and separately lists the tasks it is skipping because they never
reached a verdict. Relay both. Then, only with the user's say-so:

```bash
muse-cleanup --yes                 # finished tasks
muse-cleanup --yes --all           # unfinished too
muse-cleanup --yes --artifacts     # and the patches
muse-cleanup --yes --discard-unharvested  # also reap worktrees whose patch was never harvested (that work exists only in the worktree)
```

## What to check before removing anything

`--artifacts` deletes the patches, not just the worktrees. Before passing it, confirm the
work has actually landed — `git log` showing the change on a branch, or the user saying so.
A patch is recoverable from a worktree right up until both are gone.

Treat anything the dry run marks `(no harvested patch)` as work that exists nowhere else, and
say that explicitly rather than folding it into a count. `--discard-unharvested` is how the
user tells you that work is disposable (plus `--all` if the task also has no verdict);
`--all` alone never removes a `(no harvested patch)` worktree. It is not yours to assume.

If the run reports nothing to remove, that is a clean result — say so rather than widening
the search to other repos or other roots.
