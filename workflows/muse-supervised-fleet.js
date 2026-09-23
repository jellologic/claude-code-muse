export const meta = {
  name: 'muse-supervised-fleet',
  description: 'Decompose a job, then one Opus supervisor per task drives muse to a reviewed patch',
  phases: [
    { title: 'Plan',      detail: 'Claude partitions the job into disjoint, checkable tasks' },
    { title: 'Build',     detail: 'One Opus supervisor per task: spawn muse, verify, revise until right' },
    { title: 'Integrate', detail: 'One judgment over the whole set: merge order and cross-task conflicts' },
  ],
}

// Registered by the manifest's `workflows` key, so the model runs it by name instead of
// transcribing 200 lines out of a markdown fence -- which was the most fragile step on
// this plugin's headline path. A dropped line or a mangled template literal surfaced as
// a script that throws AFTER the planning agents had already been paid for.
//
// Whether a plugin-owned workflow gets ${CLAUDE_PLUGIN_ROOT} substituted is not
// documented and was not verified, so this asks rather than assumes. Single quotes, not
// a template literal: JavaScript must leave the token alone for the loader to have a
// chance at it, and if nothing substituted it the string still contains a dollar sign,
// which is how we tell the two cases apart.
const ROOT_TOKEN = '${CLAUDE_PLUGIN_ROOT}'
const PLUGIN = args.pluginRoot || (ROOT_TOKEN.indexOf('$') === -1 ? ROOT_TOKEN : null)
// bin/ is on an agent's PATH only while the plugin is enabled in the running
// session; outside such a session bare muse-task exits 127, so the absolute shim
// from pluginRoot is the documented fallback.
const TASK  = PLUGIN ? `"${PLUGIN}/bin/muse-task"` : 'muse-task'
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
