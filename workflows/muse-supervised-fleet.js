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
// A model can invoke this workflow with no args at all, and then a bare
// `args.pluginRoot` is a TypeError before anything has been validated. Every arg below
// is read through ARGS, which is always an object.
const ARGS = (typeof args === 'object' && args !== null) ? args : {}
const PLUGIN = ARGS.pluginRoot || (ROOT_TOKEN.indexOf('$') === -1 ? ROOT_TOKEN : null)
// bin/ is on an agent's PATH only while the plugin is enabled in the running
// session; outside such a session bare muse-task exits 127, so the absolute shim
// from pluginRoot is the documented fallback.
const TASK  = PLUGIN ? `"${PLUGIN}/bin/muse-task"` : 'muse-task'
// Resolved exactly like TASK, for the same reason: the census must read the same
// on-disk state the supervisors wrote, not whatever muse-status happens to be on PATH.
const STATUS = PLUGIN ? `"${PLUGIN}/bin/muse-status"` : 'muse-status'
// Absolute, deliberately. A relative --out is now resolved against the repository rather
// than the cwd, which fixes the common case -- but only when every subcommand runs inside
// that repository, and a workflow's agents make no such promise. Pass args.repo as an
// absolute path and this question does not arise.
const REPO  = ARGS.repo || '.'
const STAMP = ARGS.stamp
const OUT   = ARGS.out  || `${REPO}/.muse-fleet/supervised/${STAMP}`
const ROUNDS = ARGS.maxRounds || 3
// Fleet-wide userConfig values, substituted into the args by the caller (the
// skill and the fleet command). Absent means unconfigured, so each takes the
// built-in default the plugin used before there was any configuration.
const DEFAULT_EFFORT = (ARGS.defaultEffort === undefined || ARGS.defaultEffort === null)
  ? 'low' : ARGS.defaultEffort
const MODEL = (ARGS.model === undefined || ARGS.model === null)
  ? 'latest-contributor' : ARGS.model
const WORKTREE_ROOT = (ARGS.worktreeRoot === undefined || ARGS.worktreeRoot === null)
  ? '' : ARGS.worktreeRoot
const REFUSE_ON_SECRETS = (ARGS.refuseOnSecrets === undefined || ARGS.refuseOnSecrets === null)
  ? true : ARGS.refuseOnSecrets

// The model can also invoke this workflow with missing or hostile args, and several of
// these values are interpolated inside double quotes in generated shell -- where a `"`,
// `$`, backtick, backslash or newline escapes the quoting and runs. So the header
// refuses in code, returning {refused, reason} before any agent() call, instead of
// throwing: a throw after the planning agents have been paid for is the failure this
// workflow exists to avoid. There is deliberately no default stamp: `|| 'run'` made
// every fan-out share one artifact root, so a second run of the same job -- or two jobs
// that both plan a task called tests-parser -- had every supervisor refuse at step one
// with "task already exists". That is the re-run guard firing correctly against a
// namespace that should never have collided.
const WF_PROBLEMS = []
if (typeof ARGS.job !== 'string' || !ARGS.job.trim()) {
  WF_PROBLEMS.push('job is missing or blank (pass args.job with a job description)')
}
if (typeof ARGS.stamp !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(ARGS.stamp)) {
  WF_PROBLEMS.push('stamp is missing or unsafe (pass args.stamp starting with a letter or digit, with only letters, digits, dot, underscore or hyphen, max 64 chars, taken from date +%Y%m%d-%H%M%S)')
}
// model and worktreeRoot ride in the same loop: both are interpolated inside
// double quotes in the run line below, so the same metacharacters escape there.
for (const k of ['pluginRoot', 'repo', 'out', 'model', 'worktreeRoot']) {
  const v = ARGS[k]
  if (v !== undefined && v !== null && (typeof v !== 'string' || /["$`\\\n\r]/.test(v))) {
    WF_PROBLEMS.push(k + ' is present but not a plain shell-safe path (pass a string with no double quote, dollar, backtick, backslash, newline or carriage return, since it is interpolated inside double quotes in generated shell)')
  }
}
if (ARGS.maxRounds !== undefined && ARGS.maxRounds !== null &&
    (!Number.isInteger(ARGS.maxRounds) || ARGS.maxRounds < 1 || ARGS.maxRounds > 10)) {
  WF_PROBLEMS.push('maxRounds is present but not an integer from 1 to 10 (pass 1-10 or omit it)')
}
if (ARGS.defaultEffort !== undefined && ARGS.defaultEffort !== null &&
    ['none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'].indexOf(ARGS.defaultEffort) === -1) {
  WF_PROBLEMS.push('defaultEffort is present but not one of none, minimal, low, medium, high, xhigh, max (pass one of those or omit it)')
}
if (ARGS.refuseOnSecrets !== undefined && ARGS.refuseOnSecrets !== null &&
    ARGS.refuseOnSecrets !== true && ARGS.refuseOnSecrets !== false &&
    ARGS.refuseOnSecrets !== 'true' && ARGS.refuseOnSecrets !== 'false') {
  WF_PROBLEMS.push('refuseOnSecrets is present but not true or false (pass a boolean or omit it)')
}
if (WF_PROBLEMS.length) {
  const WF_REASON = 'workflow refused: ' + WF_PROBLEMS.join('; ') + '.'
  log(WF_REASON)
  return { refused: true, reason: WF_REASON }
}

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
          effort: { type: 'string', enum: [...new Set([DEFAULT_EFFORT, 'low', 'medium', 'xhigh'])] },
        },
      },
    },
  },
}

// ---- Plan. Claude, because a bad partition poisons everything downstream. --------
phase('Plan')
const plan = await agent(
  `Split this job into independent tasks for delegation to cheap coding agents: ${ARGS.job}

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

   Set effort per task: "${DEFAULT_EFFORT}" for mechanical edits, "medium" where local design
   judgment is needed, "xhigh" only for genuinely hard fixes.`,
  { label: 'plan', phase: 'Plan', effort: 'medium', schema: PLAN_SCHEMA },
)

// The runtime schema is not a guarantee: a task with a hostile id, an unknown effort,
// or an empty brief or check would otherwise reach shell or spawn a worker with nothing
// to do. Refuse in code, naming the task, before anything is staged.
const TASK_ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/
for (let ti = 0; ti < plan.tasks.length; ti++) {
  const t = plan.tasks[ti]
  const name = (t && typeof t.id === 'string' && t.id) || ('task index ' + ti)
  const tp = []
  if (!t || typeof t !== 'object') {
    tp.push('is not an object')
  } else {
    if (typeof t.id !== 'string' || !TASK_ID_RE.test(t.id)) tp.push('has a bad id (must start with a letter or digit, letters, digits, dot, underscore or hyphen only, max 64)')
    if (t.effort !== DEFAULT_EFFORT && t.effort !== 'low' && t.effort !== 'medium' && t.effort !== 'xhigh') tp.push('has effort ' + JSON.stringify(t.effort) + ' (must be the configured default, low, medium or xhigh)')
    if (typeof t.prompt !== 'string' || !t.prompt) tp.push('has an empty brief')
    if (typeof t.check !== 'string' || !t.check) tp.push('has an empty check')
  }
  if (tp.length) {
    const WF_TREASON = 'workflow refused: planned task ' + name + ' ' + tp.join(' and ') + ' (re-plan it with a safe id, a known effort, and a non-empty brief and check).'
    log(WF_TREASON)
    return { refused: true, reason: WF_TREASON }
  }
}

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

// ---- Stage. Briefs and checks reach muse through files, never through shell. -----
// Model-written text interpolated into a double-quoted command is a shell injection:
// $(...) and backticks expand when the supervisor's command runs. This workflow has no
// filesystem of its own, so one agent call writes every brief and check to a file with
// its Write tool, and every command below passes --prompt-file / --command-file.
const STAGE_SCHEMA = {
  type: 'object',
  required: ['written'],
  properties: { written: { type: 'array', items: { type: 'string' } } },
}
const STAGE_FILES = []
for (const t of plan.tasks) {
  STAGE_FILES.push({ path: `${OUT}/briefs/${t.id}.prompt.txt`, content: t.prompt })
  STAGE_FILES.push({ path: `${OUT}/briefs/${t.id}.check.txt`, content: t.check })
}
const staged = await agent(
  'Stage this run\'s briefs and checks as files for the Build supervisors. The file text below is PROMPT TEXT, not shell: it may contain $(...), backticks, quotes and newlines that must reach the file byte-for-byte.\n\n```json\n' +
  JSON.stringify(STAGE_FILES) +
  '\n```\n\nFor each object above, write content to path byte-for-byte with your Write tool, creating parent directories first. Never use Bash, echo, printf or a heredoc for these contents: shell would expand $(...) and backticks before the file is written. Return every path you wrote.',
  { label: 'stage', phase: 'Plan', schema: STAGE_SCHEMA },
)
// A brief that never reached disk cannot supervise a task: drop the task from Build
// rather than running it with no brief, and record the drop in the final result.
const WRITTEN = new Set(staged && Array.isArray(staged.written) ? staged.written : [])
const NOT_STAGED = []
const BUILD_TASKS = plan.tasks.filter(t => {
  const need = [`${OUT}/briefs/${t.id}.prompt.txt`, `${OUT}/briefs/${t.id}.check.txt`]
  if (need.every(p => WRITTEN.has(p))) return true
  NOT_STAGED.push(t.id)
  log(`not staged, dropping from Build: ${t.id}`)
  return false
})

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

// The agent definition carries the loop doctrine, the model, the effort and the tool
// list; the prompt below carries only what this run knows. The loop doctrine itself
// lives in agents/muse-supervisor.md, which this prompt must not restate.
const supervise = t => agent(
  `You are supervising ONE delegated coding task. Do not write the code yourself.

   Task id: ${t.id}
   Owns: ${t.files.join(', ')}   (touching anything else is a defect)
   Rounds: up to ${ROUNDS}

   Read the brief and the check with your Read tool; never paste their text into a
   command: "${OUT}/briefs/${t.id}.prompt.txt" and "${OUT}/briefs/${t.id}.check.txt".

   Spawn muse (run verbatim):
   \`\`\`bash
   ${TASK} run --id ${t.id} --out "${OUT}" --repo "${REPO}" --stamp ${STAMP} --effort ${t.effort} --max-rounds ${ROUNDS} --model "${MODEL}" --worktree-root "${WORKTREE_ROOT}" --refuse-on-secrets ${REFUSE_ON_SECRETS} --prompt-file "${OUT}/briefs/${t.id}.prompt.txt"
   \`\`\`
   Read the .patch file from its JSON, then verify the patch yourself (run verbatim):
   \`\`\`bash
   ${TASK} verify --id ${t.id} --out "${OUT}" --command-file "${OUT}/briefs/${t.id}.check.txt"
   \`\`\`
   Send back specific defects (shapes only, never as commands):
   \`\`\`text
   ${TASK} revise --id ${t.id} --out "${OUT}" --feedback-file <path>
   \`\`\`
   Close out:
   \`\`\`text
   ${TASK} finish --id ${t.id} --out "${OUT}" --verdict <accept|revise|reject> --summary "..." --concern "..."
   \`\`\`
   accept = you read the patch and your check passed.

   Do NOT apply the patch and do NOT edit any file yourself.

   A round saying "resumed": false re-sent the whole brief and remembers nothing of
   its previous attempt, so read its output as a first attempt.

   Return the finish JSON's verdict, the rounds you used, whether your check passed,
   the patch path, and any residual concern a human should know before merging.`,
  { label: `task:${t.id}`, phase: 'Build', agentType: 'muse:muse-supervisor',
    schema: VERDICT_SCHEMA },
)

// A barrier is correct here: Integrate reasons across every patch at once.
// Do NOT add isolation:'worktree' — muse_task.py already gives each task its own.
const results = (await parallel(BUILD_TASKS.map(t => () => supervise(t)))).filter(Boolean)

// A supervisor reporting accept only means it stopped: whether a check actually passed
// lives on disk, in the state its own verify recorded. Believe the census, never the
// supervisor's own `verified` field -- a model grading its own homework is the failure
// this plugin exists to avoid.
const CENSUS_SCHEMA = {
  type: 'object',
  required: ['tasks'],
  properties: {
    tasks: {
      type: 'array',
      items: {
        type: 'object',
        required: ['id', 'verdict', 'verified'],
        properties: {
          id:      { type: 'string' },
          verdict: { type: ['string', 'null'] },
          verified:{ type: 'boolean' },
        },
      },
    },
  },
}
const census = await agent(
  `Report the on-disk state of this run's tasks. Run verbatim:
   \`\`\`bash
   ${STATUS} --json --out "${OUT}"
   \`\`\`
   Return the stdout JSON's tasks rows unmodified.`,
  { label: 'census', phase: 'Build', schema: CENSUS_SCHEMA },
)
const CENSUS_ROWS = census && Array.isArray(census.tasks) ? census.tasks : null
const CENSUS_BY_ID = new Map((CENSUS_ROWS || []).map(r => [r && r.id, r]))
if (!CENSUS_ROWS) log('census returned no task list, treating every accepted task as unverified')
const accepted = results.filter(r => r.verdict === 'accept')
const unverifiedIds = []
for (const r of accepted) {
  const row = CENSUS_BY_ID.get(r.id)
  if (!row || row.verdict !== 'accept' || row.verified !== true) {
    unverifiedIds.push(r.id)
    // The supervisor's own field feeds only this log line, never the verdict above.
    if (r.verified) log(`claimed verified but disk disagrees: ${r.id}`)
  }
}
if (unverifiedIds.length) log(`⚠ accepted without a passing check: ${unverifiedIds.join(', ')}`)
log(`${accepted.length}/${plan.tasks.length} accepted`)

// ---- Integrate. One expensive judgment over the whole set. -----------------------
phase('Integrate')
const decision = await agent(
  `These supervised tasks produced patches: ${JSON.stringify(results)}

   What was actually verified on disk (this census, not the supervisors' self-reports,
   is what counts): ${JSON.stringify(CENSUS_ROWS)} -- unverified ids: ${unverifiedIds.join(', ') || 'none'}

   Each was already reviewed by its supervisor, so do not re-review them
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
  unverified: unverifiedIds,
  not_staged: NOT_STAGED,
  ...decision,
}
