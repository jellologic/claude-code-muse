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
const TASK  = `python3 ${PLUGIN}/scripts/muse_task.py`
const REPO  = args.repo || '.'
const OUT   = args.out  || '.muse-fleet/supervised'
const STAMP = args.stamp || 'run'   // Date.now() throws in workflow scripts — pass one in.
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
          id:     { type: 'string' },
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
                                    repo: ".", stamp: "20260919-1430", maxRounds: 3 } })
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
  `Run: ${SKILL}/scripts/muse_ask.sh --effort low \\
     "List every file importing 'requests', with line numbers"
   Return its stdout verbatim.`,
  { label: 'inventory', effort: 'low' })
```

**Raw throughput, review batched to the end** — when there are thirty trivial tasks and
per-task supervision costs more than it saves, `muse_fleet.py` still does the old
unsupervised fan-out. Use it knowing nothing checked the work.

**Escalation** — give a `revise` verdict one more attempt at higher effort before handing
it to a human, by re-running that task's supervisor with `--effort xhigh` and the previous
concerns appended to the brief.

**Competing implementations** — point N supervisors at the same brief with different
approaches and disjoint output paths, then have Integrate pick a winner. The disjoint-file
rule still holds; they just write to `impl_a.py`, `impl_b.py`.

## Things that go wrong

**Accepting without verifying.** The single failure this architecture exists to prevent.
The script exposes it (`verified_by_supervisor` in `task.json`, the `⚠` log line) rather
than hiding it, because a supervisor that skipped its check produces a report
indistinguishable from a good one unless you surface it.

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
