# The supervised fleet workflow

This is the skill's primary architecture. `SKILL.md` summarises it; this file is the
script and the reasons behind its shape.

The Workflow tool requires explicit opt-in, and a skill instructing you to call it counts
as that opt-in — so invoking muse-fleet for a fan-out job authorises this script. It does
not authorise a workflow for unrelated work later in the session.

## The inversion

The old design ran every task once and reviewed the pile afterwards. It had a structural
flaw: **the cheap model's last word was the deliverable.** A patch that missed its brief
stayed missed until a human caught it, and the reviewer was a separate agent with no
ability to do anything about what it found except write it down.

Here the unit of work is not a muse run. It is a **supervisor that owns a task until the
task is right**:

```
            ┌─────────────── one Opus supervisor, one task ───────────────┐
  plan ──▶  │  muse run ──▶ read patch ──▶ verify ──▶ revise ──▶ verify   │ ──▶ integrate
            │       ▲                                    │                │
            │       └────────────── until right ─────────┘                │
            └─────────────────────────────────────────────────────────────┘
```

Three consequences worth being explicit about:

1. **Defects get fixed by the engine that is cheap at fixing them.** The supervisor does
   not rewrite muse's patch; it tells muse exactly what is wrong and muse edits its own
   work in the same worktree. Judgment stays with Claude, typing stays with muse.
2. **The acceptance check is run by the reviewer, not the author.** `muse_task.py verify`
   executes the command inside the worktree and records the exit code and output in
   `state.json`. This is the one thing that reliably separates a patch that works from a
   patch that claims to.
3. **A task reports a verdict, not a status.** `completed` only ever meant "the agent
   stopped". `accept` / `revise` / `reject` means someone looked.

## The script

It is **not** reproduced here. It lives at
[`workflows/muse-supervised-fleet.js`](../workflows/muse-supervised-fleet.js) and is
registered by the manifest's `workflows` key, so the runtime loads it and the model runs
it **by name**.

That matters more than it sounds. Shipping 200 lines of JavaScript inside a markdown
fence meant every fan-out began with a model transcribing it into the Workflow tool, and
a dropped line or a mangled template literal surfaced as a script that throws *after* the
planning agents had already been paid for. It was the most fragile step on this plugin's
headline path, and it was fragile in the most expensive place.

Read the file for the code; read the rest of this page for why it is shaped that way.


Invoke it by name, with the job and the repo as `args`:

```
Workflow({ name: "muse-supervised-fleet",
           args: { job: "add pytest coverage to the four untested modules",
                   repo: "<absolute path>", pluginRoot: "<echo ${CLAUDE_PLUGIN_ROOT}>",
                   stamp: "20260919-1430", maxRounds: 3 } })
```

`pluginRoot` is optional. Pass it so the script can fall back to the absolute
`bin/muse-task` when the plugin is not enabled in the session running the workflow;
without it the agents call bare `muse-task` from PATH, which is there only while the
plugin is enabled.

## Why each choice is the way it is

**Opus for the supervisor.** The supervisor's output is a judgment with no oracle above
it — exactly the case the routing rule assigns to the strongest model. It is also the
cheapest place to spend: one Opus agent replaces both the old review agent and the human
pass that followed it, and every round it saves is a round of muse tokens plus your
attention. `model: 'opus'` is set explicitly here rather than inherited, because this
stage should not silently drop to a weaker tier when the session model changes.

**`effort: 'high'`, not `max`.** Reviewing a bounded patch against a written brief with a
green check in hand is not a `max`-effort problem. Raise it for security-sensitive or
subtle work.

**The supervisor does not write code.** If it patches the worktree by hand, the next
revision round starts from a tree muse did not produce and cannot reason about, and the
economics invert — you are now paying Opus rates to type. `finish` re-harvests the
worktree, so a hand-edit would silently be folded into the patch and misattributed.

**No `isolation: 'worktree'` on the agents.** `muse_task.py` already creates one worktree
per task, outside the repo. Adding workflow-level isolation nests a worktree inside a
worktree; you get a patch against the wrong base and a confusing cleanup.

**`--stamp` comes from `args`.** Workflow scripts cannot call `Date.now()` or
`new Date()` — they throw, because they would break resume. Pass a stamp in so sibling
tasks share one branch namespace, or omit it and let each task stamp itself.

**One barrier, deliberately.** `parallel()` before Integrate is a real barrier, justified
because the integration judgment genuinely needs every result at once. Everything before
it — the whole spawn/verify/revise loop — already runs concurrently inside each
supervisor, so no task waits on another's rounds.

## Variations

**Cheap analysis inside a Claude pipeline** — a bounded read-only question does not need
a worktree at all:

```javascript
const inventory = await agent(
  `Run: muse-ask --effort low \\
     "List every file importing 'requests', with line numbers"
   Return its stdout verbatim.`,
  { label: 'inventory', effort: 'low' })
```

**Raw throughput, review batched to the end** — when there are thirty trivial tasks and
per-task supervision costs more than it saves, `muse_fleet.py` still does the old
unsupervised fan-out. Use it knowing nothing checked the work.

**Escalation** — give a `revise` verdict one more attempt at higher effort. Use a fresh
id (`${t.id}-retry`): `run` refuses an id that already has a task, since re-running would
overwrite its patch and orphan its worktree before handing
it to a human, by re-running that task's supervisor with `--effort xhigh` and the previous
concerns appended to the brief.

**Competing implementations** — point N supervisors at the same brief with different
approaches and disjoint output paths, then have Integrate pick a winner. The disjoint-file
rule still holds; they just write to `impl_a.py`, `impl_b.py`.

## Embedding muse in your own workflow

The script above is the whole fan-out. More often you want muse as **one stage** of a
workflow you are writing — research, then delegate, then review. The shape is small:

```javascript
// Plugin bin/ directories are on an agent's Bash PATH only while the muse plugin
// is enabled in the session running the workflow. When it is not enabled, bare
// `muse-task` exits 127 ("command not found"), so pass `args.pluginRoot` and the
// absolute shim is used instead.
const TASK  = args.pluginRoot ? `"${args.pluginRoot}/bin/muse-task"` : 'muse-task'
const REPO  = args.repo || '.'
const STAMP = args.stamp
if (!STAMP) throw new Error('args.stamp is required: Date.now() throws in workflow scripts, so pass one in')
// Absolute AND stamped: absolute for the cwd rule below, stamped so a second run of the
// same workflow does not collide with the first and get refused task by task.
const OUT   = `${REPO}/.muse-fleet/supervised/${STAMP}`

const VERDICT = {
  type: 'object',
  required: ['verdict', 'check_exit_code', 'patch_path', 'notes'],
  properties: {
    verdict:         { type: 'string', enum: ['accept', 'revise', 'reject'] },
    check_exit_code: { type: 'integer' },
    patch_path:      { type: 'string' },
    notes:           { type: 'string' },
  },
}

const delegate = t => agent(
  `Own one delegated task to a verdict. Do not write the code yourself and do not
   apply the patch.
     ${TASK} run    --id ${t.id} --out ${OUT} --repo ${REPO} --stamp ${STAMP} \\
       --effort ${t.effort || 'low'} --prompt ${JSON.stringify(t.prompt)}
   Read the patch it prints. Then run the check YOURSELF:
     ${TASK} verify --id ${t.id} --out ${OUT} --command ${JSON.stringify(t.check)}
   Wrong or failing -> revise --feedback "<specific defects>" and verify again.
   Then finish --verdict <accept|revise|reject>. finish REFUSES accept unless the final
   check passed against the current tree; re-verify rather than working around it.`,
  { label: `muse:${t.id}`, phase: 'Delegate', model: 'opus', effort: 'high', schema: VERDICT })

phase('Delegate')
const done = (await parallel(tasks.map(t => () => delegate(t)))).filter(Boolean)
```

Four rules that are not obvious from the API:

- **A workflow script cannot call muse.** Scripts have no filesystem and no Node API, so
  every muse invocation happens inside an `agent()` that runs Bash. The script decides
  *what* and *how many*; the agent does.
- **Thread `stamp` through `args`, and `pluginRoot` when the plugin may not be enabled.**
  `Date.now()` throws in script scope, so `stamp` is always required — pass it in from
  the turn that calls Workflow, or the run fails at the first shell call after the
  planning agents have already been paid for. `pluginRoot` is only needed when the
  session running the workflow may not have the muse plugin enabled: without it the
  agents call bare `muse-task` from PATH, which is there only while the plugin is enabled.
- **Task ids must match `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`.** An id names a worktree
  directory and a git branch, and `run` refuses anything else. If a planning agent
  invents ids, put that pattern in its schema, or every task dies at step one.
- **Use an absolute `--out`, and pass `repo` absolute.** A relative `--out` is resolved
  against the **repository**, not the cwd, so `run` from the repo root and `verify` from
  a subdirectory now agree — that was measured to produce two different task directories
  and a "no such task" on the second call. What that fix does not cover is a workflow
  whose agents run outside the repository at all, or a `--repo` pointing somewhere other
  than the cwd, which `run` refuses outright rather than creating a task the later
  subcommands cannot find. Absolute sidesteps the whole question.
- **Stamp the artifact root.** Branches and worktrees were stamped and `--out` was not,
  so a second run of the same job — or two jobs both planning a task called
  `tests-parser` — had every supervisor refuse at step one with "task already exists".
- **Reap what you spawn.** Each task leaves a worktree and a branch. A workflow that fans
  out many of them should finish with `muse-cleanup --yes` (or `finish --cleanup` per
  task) once the patches are harvested, or the worktree root grows every run.
- **Do not add `isolation: 'worktree'`.** `muse_task.py` already gives each task its own
  worktree; a second one nests them and costs setup per agent for nothing.

### Using the plugin's own supervisor agent

`agentType` reuses `agents/muse-supervisor.md` instead of restating the doctrine inline,
which keeps one source of truth:

```javascript
agent(`Task id: ${t.id}\nRepo: ${REPO}\n` +
      `Brief: ${t.prompt}\nAcceptance check: ${t.check}`,
      { agentType: 'muse:muse-supervisor', label: `muse:${t.id}`, phase: 'Delegate' })
```

The catch, measured: `agent({agentType})` **throws** when the type is not registered —
`agent type 'muse:muse-supervisor' not found` — and plugin agents only register for
sessions that started *after* the plugin was installed. Worse, a thunk that throws inside
`parallel()` resolves to `null`, so the task is **silently dropped** rather than failing
loudly. Prefer the inline prompt above when the workflow has to run anywhere; use
`agentType` when you control the environment, and `.filter(Boolean)` either way.

## Things that go wrong

**Accepting without verifying.** The single failure this architecture exists to prevent.
`finish` now refuses the verdict outright, so this surfaces as a task that never reached
`accept` rather than one that reached it hollow — expect `null` from a delegate agent that
tried to skip the check, and read the `⚠` log line. `verified_by_supervisor` in `task.json`
is still the field to aggregate on, because `--accept-unverified` can put a reasoned
override through the gate.

**A task with no runnable check.** The planner is told to produce one for every task. If
it genuinely cannot — a docs rewrite, a naming change — say so in the plan and expect to
review that patch by hand; do not invent a check that always passes.

**Merging inside the workflow.** Don't. Return the accepted list and let a human apply
patches with `git apply --3way`, running the suite between each. A workflow that merges
autonomously converts a reviewable pile of patches into an unreviewable commit.

**A dirty repo.** `muse_task.py run` refuses rather than starting, which surfaces as an
early failure in every task at once. Commit or stash first.

**Round budget as a target.** `--max-rounds 3` is a ceiling, not a goal. A task that needs
all three rounds every time is a task whose brief is wrong; fix the decomposition rather
than raising the cap.
