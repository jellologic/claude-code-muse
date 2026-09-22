---
description: Delegate one coding task to Muse Code under an Opus supervisor that runs the acceptance check and revises until the patch is right
argument-hint: <task> — name the target files and say what must not change
allowed-tools: Bash, Read, Grep, Glob, Agent, Task, AskUserQuestion
---

# Delegate one task to muse

Hand `$ARGUMENTS` to a Muse Code worker in an isolated git worktree, supervised to a verdict.
Muse types; you judge. Do not do the edit yourself — that is the whole point of the command.

## 1. Preflight

```bash
echo "${CLAUDE_PLUGIN_ROOT}"          # the supervisor needs this literal path
git rev-parse --show-toplevel         # must be a git repo
git status --porcelain                # must be clean
```

The drivers refuse to start on a dirty working copy, deliberately: worktrees branch from a
*committed* ref, so uncommitted work is invisible to the worker and its absence reads like
the agent deleted your changes. If the tree is dirty, say so and stop — offer to commit or
stash, do not pass `--allow-dirty` on the user's behalf.

If the SessionStart preflight reported a missing binary or missing credentials, surface that
now rather than letting the worker die on it. `/muse:doctor` gives the full picture when the
cause is not obvious.

`run` also scans the worktree for credentials before spawning anything and refuses on a
confirmed one — contributor-tier content may be used for training, and that is not
undoable. If it refuses, report which file and line, and do not reach for `--allow-secrets`
on the user's behalf; that is their call to make about their own repository.

## 2. Turn the request into a brief

The worker sees the repo and your brief and nothing else. It has no memory of this
conversation and **cannot ask a question** — headless runs auto-cancel prompts. Ambiguity
does not come back as a question; it comes back as confidently wrong work.

Produce four things:

- **id** — short kebab-case, names the worktree and branch (`tests-parser`, `typehints-utils`)
- **prompt** — self-contained. Name the exact files to create or edit. State what must
  **not** change. Keep it to one sitting; if it needs three paragraphs it is two tasks.
- **check** — one shell command, run from the repo root, exiting 0 only when the task is
  genuinely done (`pytest tests/test_parser.py -q`, `mypy utils.py`, `node -e "require('./dist')"`)
- **effort** — `low` for mechanical work (the default and the common case), `medium` where
  local design judgment is needed, `xhigh` only for a genuinely hard fix

Read the relevant files first if you need them to name targets precisely. Cheap, and it is
the difference between a brief that lands and one that invents its own scope.

**If no executable check exists** — a docs rewrite, a rename with no test coverage — say so
plainly before spawning anything, and either ask the user for a check or state that you will
review this patch by hand. Never invent a check that always passes; a task with no real
oracle cannot be supervised, only guessed at.

## 3. Check for untracked files the worktree will not have

A worktree is a clean checkout, so everything git ignores is missing: `.env`, `node_modules`,
`.venv`, local certs. This fails quietly in the worst way — the worker cannot run the check,
so it reports a success it never verified, and helpfully rebuilds what looks absent.

```bash
git status --ignored --porcelain | grep '^!!' | head -20
```

Copy small config with `--seed .env`; symlink heavy directories with `--link node_modules`.
Never symlink something the worker might install into.

## 4. Spawn the supervisor

Launch the `muse-supervisor` agent with one task. Give it the literal plugin root — it
cannot expand `${CLAUDE_PLUGIN_ROOT}` from your message, so paste the value you echoed.

The brief you hand the agent must contain: the task id, the artifact root
(`.muse-fleet/tasks` unless the user asked otherwise), the repo path, the prompt, the
acceptance check, the effort, any `--seed`/`--link` flags, and the round cap (3 unless told
otherwise). Tell it to return a verdict, the check it ran with its exit code, the patch path,
and any residual concerns — and that it must not apply the patch.

For several independent tasks, spawn one supervisor per task in a single message so they run
concurrently, and confirm first that no two tasks touch the same file. Two workers editing
one file produce two clean patches that conflict at merge time; worktrees isolate processes,
not intentions. Past roughly five concurrent tasks the limit stops being the tooling and
becomes merge complexity — prefer `/muse:fleet` for anything larger, since it enforces
disjointness in code.

## 5. Report, and stop

Give the user: the verdict, what the patch does, the check and its exit code, the patch path,
and anything the supervisor flagged.

**Do not apply the patch.** An accepted patch is still a patch the user has not read. Show
them how, and let them decide:

```bash
git apply --check .muse-fleet/tasks/<id>/patch.diff   # will it apply?
git apply --3way  .muse-fleet/tasks/<id>/patch.diff   # apply it
```

Apply one at a time with the test suite in between. If two patches conflict, the
decomposition was wrong — fix the partition rather than hand-merging.

State the verdict honestly. `completed` means the worker stopped; `accept` means the
supervisor ran a check and it passed. If a task finished without an executed check, say that
in those words rather than reporting it as done.
