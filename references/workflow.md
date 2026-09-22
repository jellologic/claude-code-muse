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

## Full script

```javascript
export const meta = {
  name: 'muse-supervised-fleet',
  description: 'Decompose a job, then one Opus supervisor per task drives muse to a reviewed patch',
  phases: [
    { title: 'Plan',      detail: 'Claude partitions the job into disjoint, checkable tasks' },
    { title: 'Build',     detail: 'One Opus supervisor per task: spawn muse, verify, revise until right' },
    { title: 'Integrate', detail: 'One judgment over the whole set: merge order and cross-task conflicts' },
  ],
}

// Workflow scripts see no environment, so ${CLAUDE_PLUGIN_ROOT} cannot be read here.
// The caller resolves it (`echo ${CLAUDE_PLUGIN_ROOT}`) and passes it in as args.pluginRoot.
const PLUGIN = args.pluginRoot
if (!PLUGIN) throw new Error('args.pluginRoot is required: pass the value of ${CLAUDE_PLUGIN_ROOT}')
const TASK  = `python3 "${PLUGIN}/scripts/muse_task.py"`
// Absolute, deliberately. A relative --out is now resolved against the repository rather
// than the cwd, which fixes the common case -- but only when every subcommand runs inside
// that repository, and a workflow's agents make no such promise. Pass args.repo as an
// absolute path and this question does not arise.
const REPO  = args.repo || '.'
// Throw rather than default. `|| 'run'` made every fan-out share one namespace, so a
// second run of the same job -- or two jobs that both plan a task called tests-parser --
// had every supervisor refuse at step one with "task already exists". That is the re-run
// guard firing correctly against a namespace that should never have collided.
const STAMP = args.stamp
if (!STAMP) throw new Error('args.stamp is required: Date.now() throws in workflow scripts, so pass one in (`date +%Y%m%d-%H%M%S`)')
// Stamped, like the branches and the worktrees already were. The artifact root was the
// one part of the namespace that was not.
const OUT   = args.out  || `${REPO}/.muse-fleet/supervised/${STAMP}`
const ROUNDS = args.maxRounds || 3

const PLAN_SCHEMA = {
  type: 'object',
  required: ['tasks'],
  properties: {
    tasks: {
      type: 'array',
      items: {
        type: 'object',
        required: ['id', 'prompt', 'files', 'check', 'effort'],
        properties: {
          id:     { type: 'string', pattern: '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' },
          prompt: { type: 'string' },
          files:  { type: 'array', items: { type: 'string' } },
          check:  { type: 'string' },   // shell command; the supervisor runs this itself
          effort: { type: 'string', enum: ['low', 'medium', 'xhigh'] },
        },
      },
    },
  },
}

// ---- Plan. Claude, because a bad partition poisons everything downstream. --------
phase('Plan')
const plan = await agent(
  `Split this job into independent tasks for delegation to cheap coding agents: ${args.job}

   Repo: ${REPO}

   Hard constraints:
   - Each task must touch a DISJOINT set of files. Two tasks editing one file produce
     patches that conflict at merge time.
   - Each task needs an executable acceptance check: a single shell command, run from
     the repo root, exiting 0 only when the task is genuinely done. This is not
     optional — a task with no runnable check cannot be supervised, only guessed at.
   - Each prompt must be self-contained. The worker sees the repo and that prompt and
     nothing else, and cannot ask a question. Name its exact target files and say what
     must NOT change.

   Each task id names a directory AND a git branch: start with a letter or digit and
   use only letters, digits, dot, underscore or hyphen (max 64). "tests-parser" is fine,
   "tests: parser.py" is refused before the task runs.

   Set effort per task: "low" for mechanical edits, "medium" where local design
   judgment is needed, "xhigh" only for genuinely hard fixes.`,
  { label: 'plan', phase: 'Plan', effort: 'medium', schema: PLAN_SCHEMA },
)

// Enforce the invariant the whole design rests on, in code rather than by asking nicely.
const owner = new Map()
for (const t of plan.tasks) {
  for (const f of t.files) {
    if (owner.has(f)) throw new Error(`overlap: ${t.id} and ${owner.get(f)} both edit ${f}`)
    owner.set(f, t.id)
  }
}
log(`${plan.tasks.length} disjoint tasks over ${owner.size} files, ≤${ROUNDS} rounds each`)

// Every acceptance check below was written by a model and will be executed by
// `muse_task.py verify` ON THE HOST, with your privileges -- the worktree is only its
// working directory, not a sandbox. Print them so they can be read like commands you are
// about to type yourself, rather than discovered afterwards in state.json.
log('acceptance checks that will run on the host:')
for (const t of plan.tasks) log(`  ${t.id}: ${t.check}`)

// ---- Build. One Opus supervisor per task, each owning its task to a verdict. -----
const VERDICT_SCHEMA = {
  type: 'object',
  required: ['id', 'verdict', 'rounds_used', 'verified', 'patch', 'summary', 'concerns'],
  properties: {
    id:          { type: 'string' },
    verdict:     { type: 'string', enum: ['accept', 'revise', 'reject'] },
    rounds_used: { type: 'number' },
    verified:    { type: 'boolean' },   // did YOUR check actually pass
    patch:       { type: 'string' },
    summary:     { type: 'string' },
    concerns:    { type: 'array', items: { type: 'string' } },
  },
}

const supervise = t => agent(
  `You are supervising ONE delegated coding task. A cheap model (muse) does the typing;
   you decide whether the work is right and send it back until it is. Do not write the
   code yourself — your edits would not be reproducible by the next round.

   Task id: ${t.id}
   Brief:   ${t.prompt}
   Owns:    ${t.files.join(', ')}   (touching anything else is a defect)
   Check:   ${t.check}

   Step 1 — spawn muse:
     ${TASK} run --id ${t.id} --out ${OUT} --repo ${REPO} --stamp ${STAMP} \\
       --effort ${t.effort} --max-rounds ${ROUNDS} \\
       --prompt ${JSON.stringify(t.prompt)}

   It prints JSON: patch path, files changed, and muse's own self-report. The worktree
   persists between rounds, so muse's next round edits this round's output.

   Step 2 — look at the actual patch. Read the file at .patch from that JSON. The
   self_report field is a CLAIM by the model that did the work; check it against the
   diff rather than believing it. Judge: does it meet the brief, does it stay inside
   the owned files, does it change behaviour it was told not to, are the tests asserting
   correct behaviour rather than current behaviour?

   Step 3 — run the check yourself:
     ${TASK} verify --id ${t.id} --out ${OUT} --command ${JSON.stringify(t.check)}
   A patch nobody executed is not a finished task. An empty patch reported as success
   almost always means the prompt was misread.

   Step 4 — if the patch is wrong or the check failed, send it back with SPECIFIC
   defects (quote the failing output, name the line):
     ${TASK} revise --id ${t.id} --out ${OUT} --feedback ${'"<what is wrong and what to do>"'}
   Vague feedback produces a vague fix. Add --effort medium if round 1 was
   plausible-but-wrong rather than a mechanical miss. Then verify again. You have
   ${ROUNDS} rounds total; the script refuses past that rather than letting you loop.

   Step 5 — close it out with an honest verdict:
     ${TASK} finish --id ${t.id} --out ${OUT} --verdict <accept|revise|reject> \\
       --summary "..." --concern "..."
   accept = you read the patch and your check passed. revise = out of rounds, close but
   not there. reject = wrong approach, a human should look. Do not report accept on a
   check you did not run.

   Do NOT apply the patch and do NOT edit any file yourself. Integration is decided
   once, later, over an unmodified repo; a supervisor that applies its own patch breaks
   that for every other task.

   If a round's JSON says "resumed": false there is a "session_warning": that round
   re-sent the whole brief and muse remembers nothing of its previous attempt, so read
   its output as a first attempt rather than a correction.

   Return the finish JSON's verdict, the rounds you used, whether your check passed,
   the patch path, and any residual concern a human should know before merging.`,
  { label: `task:${t.id}`, phase: 'Build', model: 'opus', effort: 'high',
    schema: VERDICT_SCHEMA },
)

// A barrier is correct here: Integrate reasons across every patch at once.
// Do NOT add isolation:'worktree' — muse_task.py already gives each task its own.
const results = (await parallel(plan.tasks.map(t => () => supervise(t)))).filter(Boolean)

const accepted = results.filter(r => r.verdict === 'accept')
const unverified = accepted.filter(r => !r.verified)
if (unverified.length) log(`⚠ accepted without a passing check: ${unverified.map(r => r.id).join(', ')}`)
log(`${accepted.length}/${plan.tasks.length} accepted`)

// ---- Integrate. One expensive judgment over the whole set. -----------------------
phase('Integrate')
const decision = await agent(
  `These supervised tasks produced patches: ${JSON.stringify(results)}

   Each was already reviewed and verified by its supervisor, so do not re-review them
   line by line. Your job is the cross-task view only:

   - a merge order that minimises rework
   - any pair that will conflict DESPITE disjoint files — a shared import, a renamed
     symbol used elsewhere, two tasks both assuming they land first
   - what a human must check by hand before merging
   - whether anything accepted without a passing check should be treated as unproven

   Patches are at <out>/<id>/patch.diff. Apply nothing.`,
  { label: 'integrate', phase: 'Integrate', model: 'opus', effort: 'high',
    schema: { type: 'object',
              required: ['merge_order', 'conflicts', 'manual_checks', 'unproven'],
              properties: { merge_order:   { type: 'array', items: { type: 'string' } },
                            conflicts:     { type: 'array', items: { type: 'string' } },
                            manual_checks: { type: 'array', items: { type: 'string' } },
                            unproven:      { type: 'array', items: { type: 'string' } } } } },
)

return {
  out_dir: OUT,
  accepted: accepted.map(r => r.id),
  needs_work: results.filter(r => r.verdict !== 'accept'),
  ...decision,
}
```

Invoke it with the job and the repo as `args`:

```
Workflow({ script: <above>, args: { job: "add pytest coverage to the four untested modules",
                                    repo: ".", pluginRoot: "<echo ${CLAUDE_PLUGIN_ROOT}>",
                                    stamp: "20260919-1430", maxRounds: 3 } })
```

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
  `Run: ${PLUGIN}/scripts/muse_ask.sh --effort low \\
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
// Two values a workflow script cannot obtain for itself. Pass both in via args:
//   ${CLAUDE_PLUGIN_ROOT} is not expanded in script scope, and Date.now() throws.
// Resolve them in the turn that calls Workflow: `echo ${CLAUDE_PLUGIN_ROOT}` and `date`.
const TASK  = `python3 "${args.pluginRoot}/scripts/muse_task.py"`
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
- **Thread `pluginRoot` and `stamp` through `args`.** `${CLAUDE_PLUGIN_ROOT}` is not
  expanded in script scope and `Date.now()` throws — both would otherwise fail at the
  first shell call, after the planning agents have already been paid for.
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
  out many of them should finish with `muse_cleanup.py --yes` (or `finish --cleanup` per
  task) once the patches are harvested, or the worktree root grows every run.
- **Do not add `isolation: 'worktree'`.** `muse_task.py` already gives each task its own
  worktree; a second one nests them and costs setup per agent for nothing.

### Using the plugin's own supervisor agent

`agentType` reuses `agents/muse-supervisor.md` instead of restating the doctrine inline,
which keeps one source of truth:

```javascript
agent(`Task id: ${t.id}\nRepo: ${REPO}\nPlugin root: ${args.pluginRoot}\n` +
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
