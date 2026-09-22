---
description: Decompose a job into disjoint tasks and run the supervised muse fleet — one Opus supervisor per task, each verified before it completes
argument-hint: <job> — e.g. "add a pytest file for each module in src/"
allowed-tools: Bash, Read, Grep, Glob, Workflow, Agent, AskUserQuestion
---

# Run the supervised fleet

Fan `$ARGUMENTS` out across several Muse Code workers, each sealed in its own git worktree
and each owned by an Opus supervisor that reads the patch, runs the acceptance check and
sends muse back for revisions until the work is right.

## 1. Decide whether this should fan out at all

Fan-out pays when tasks are **independent** and **mechanical**. It costs more than it saves
when they are neither, and the failure is not a slow run — it is three coherent patches that
do not merge.

Push back, in a sentence, when the job is:

- **one coherent change threaded through many files** — that is one edit, not N
- **debugging** — needs the whole picture, and the tasks are causally linked
- **anything needing a design decision** — no oracle, so the judgment is the output
- **several tasks that all rewrite the same file** — merge them, or run sequential waves

The deciding question: *could a competent contractor do this task knowing only this one
prompt and the repo?* If it needs context that lives in the user's head or in the other
tasks, it is not ready to delegate. Say so and offer the alternative rather than fanning out
something that will not merge.

## 2. Preflight

```bash
echo "${CLAUDE_PLUGIN_ROOT}"     # the workflow script cannot read its own env — pass this in
date +%Y%m%d-%H%M                # the workflow script cannot call Date.now() either
git status --porcelain           # must be clean; worktrees branch from a committed ref
git status --ignored --porcelain | grep '^!!' | head -20   # what the worktrees will lack
```

A dirty tree stops this: stop and offer to commit or stash. Untracked-but-needed files
(`.env`, `node_modules`, `.venv`) must be seeded or symlinked, or every worker will fail to
run its check and report a success it never verified.

## 3. Run the workflow

Invoking this command is explicit opt-in to the Workflow tool. Read the script at
`${CLAUDE_PLUGIN_ROOT}/references/workflow.md` — the JavaScript block is the script — and run
it with the values from step 2:

```
Workflow({ script: <the javascript block from references/workflow.md>,
           args: { job: "$ARGUMENTS",
                   repo: ".",
                   pluginRoot: "<the echoed CLAUDE_PLUGIN_ROOT>",
                   stamp: "<the date you just ran>",
                   maxRounds: 3 } })
```

It plans the partition, enforces file-disjointness in code (it throws on overlap rather than
asking nicely), spawns one supervisor per task, and returns a merge order.

Raise `maxRounds` only if the user asks. It is the runaway-cost breaker.

## 4. Report

Give per-task **verdicts**, not raw statuses, and name the distinction if any task finished
without an executed check. Then give the merge order the workflow returned.

**Apply nothing.** Patches land one at a time, with the test suite run in between, and that
is the user's call:

```bash
git apply --check <patch>   # will it apply?
git apply --3way  <patch>   # apply it
```

If two patches conflict, the decomposition was wrong. Fix the partition and re-run those
tasks rather than hand-merging — hand-merging hides the bad partition and it recurs.

Worktrees and branches survive the run so patches stay recoverable. `/muse:cleanup` reaps
them once the work has landed; `/muse:status` shows what every task did.
