---
name: muse-fleet
description: >-
  This skill should be used when a coding job splits into several independent, mechanical
  edits that can be delegated to Muse Code (`muse exec`) workers in isolated git worktrees,
  each supervised by an Opus agent that runs the acceptance check and re-prompts until the
  patch is right. Use it for repetitive refactors across many files, a test or a docstring
  per module in a list, one migration pattern applied repo-wide, bulk dependency or lint
  fixes, or competing drafts of one function — and whenever the user names Muse Code or
  `muse exec`, asks to offload coding work to a cheaper model, to fan tasks out across
  parallel workers, or says the work is grunt work or "don't burn my tokens on this".
  Requires the `muse` binary on PATH. Not for a single coherent change threaded through
  many files, for debugging, for work needing a design decision, or for parallelism that
  has nothing to do with muse — git worktrees on a human branch, Task-tool subagents, or
  background jobs.
allowed-tools: Bash(muse-status:*), Bash(muse-doctor:*), Read, Grep, Glob
---

# Muse Fleet

Run many Muse Code instances at once, each sealed in its own git worktree and each **owned
by an Opus supervisor** that spawns it, reads what came back, runs the acceptance check,
and sends it back for revisions until the work is right.

`allowed-tools` pre-approves the tools it lists; it does not restrict anything else.
This skill pre-approves only read-only status/doctor shims and readers, so an inferred
trigger cannot run muse, spawn agents or start a workflow without a prompt. Omitting
`Write` and `Edit` does not forbid them, it only leaves them prompted. The structural
guarantee for the supervisor is the PreToolUse hook `hooks/supervisor_guard.py` — see
[rule 3](../../AGENTS.md).

The economic case is the whole point. `muse-spark-1.3-contributor` is Meta's discounted
tier — for the 1.2 generation that was 0.10/0.20 USD per M tokens against 1.25/4.25 USD for the
full model. Mechanical edits do not need a frontier model deliberating over them. Push that
work down, spend your own budget on judgment.

The architectural case matters just as much. Cheap delegation fails in exactly one place:
**a model grading its own homework.** So the grading is moved out — to a supervisor that
can actually do something about what it finds, in the round where fixing it is still cheap.

## The shape

```
          ┌────────────── one Opus supervisor, one task ──────────────┐
 plan ──▶ │  muse run ──▶ read patch ──▶ verify ──▶ revise ──▶ verify │ ──▶ integrate
          │       ▲                                   │               │
          │       └───────────── until right ─────────┘               │
          └──────────────────────────────────────────────────────────-┘
   Claude                      muse types, Claude judges                  Claude
  (medium)                                                                (opus)
```

A task does not finish when muse stops. It finishes when its supervisor says
`accept`, `revise` or `reject` — and `accept` requires a check that the supervisor ran
itself.

## The plugin surface

Six commands you type — `/muse:delegate`, `/muse:ask`, `/muse:fleet`, `/muse:status`,
`/muse:model`, `/muse:cleanup`, `/muse:doctor` — one agent the fan-out spawns, and the
scripts under both.
"Running it" below says which to reach for.

The `muse-supervisor` agent is what `/muse:delegate` and the fleet workflow spawn: one
Opus agent that owns one task to a verdict. **It has no Write or Edit tool.** That is not
an oversight — a supervisor that can patch the worktree itself will, and then the next
round starts from a tree muse did not produce, `finish` folds the hand-edit into the patch
and misattributes it, and you are paying Opus rates to type.

Removing the tool is a strong default, not an enforced boundary: the supervisor has `Bash`,
and `>` is a write. `finish` therefore fingerprints the patch muse produced and compares it
with the one it harvests, reporting `out_of_band_edit` and naming any acceptance check that
accounts for part of the difference. `/muse:status` prints it on the task's row.

None of the commands apply a patch. They stop at a verdict and a patch path and hand the
decision to you, because an accepted patch is still a patch you have not read.

If a `/muse:*` command does not exist in the user's session, the plugin was installed
after that session started — commands, skills and agents register at session start. Tell
them to start a new session or `/clear`; reinstalling again will not help.

## Decide whether to fan out

Fan-out pays when tasks are **independent** and **mechanical**. It costs more than it saves
when they are neither.

Good candidates: add tests for each of 12 modules; add type hints file by file; convert
every callsite of a deprecated API; write a docstring per public function; draft three
competing implementations of one function to compare.

Poor candidates: a single change threaded through many files (one coherent edit, not N);
anything needing a design decision; debugging (needs the whole picture); tasks that all
rewrite the same file.

The deciding question is: **could a competent contractor do this task knowing only this
one prompt and the repo?** If it needs context that lives in your head or in the other
tasks, it is not ready to delegate.

### Disjoint files is the load-bearing rule

Worktrees isolate agents from *each other's process*, not from each other's *intentions*.
Two agents editing `calc.py` will each produce a clean patch, and those patches will
conflict when you merge them. Partition the work by file. If two tasks must touch one
file, either merge them into a single task or run them in sequential waves.

Feature-level disjointness is not enough, because some files are touched by nearly every
change. Watch for these conflict magnets: routing tables, config files, component or plugin
registries, DI containers, dependency manifests and lockfiles, barrel exports and
`__init__.py`, and migration directories. Either give exactly one task ownership of the
shared file, or do that edit yourself before fanning out.

The canonical failure, reported by several teams independently, is "refactor the backend"
handed to three agents: one moves to async handlers, one restructures error types, one
renames half the functions. Three coherent patches, mutually incompatible, nothing merges.
Vague tasks give you 5x the mess, not 5x the output.

### Every task needs a runnable check

This is a hard requirement here, not advice. The supervisor's leverage comes from running
an executable oracle against the patch — `pytest tests/test_auth.py`, `mypy utils.py`,
`node -e "require('./dist')"`. One team attributed roughly an 80% drop in failures to this
gate alone.

A task with no runnable check cannot be supervised, only guessed at. If a task genuinely
has none — a docs rewrite, a naming change — say so up front and plan to review that patch
by hand. Do not invent a check that always passes.

## Running it

Pick the path before doing anything else. Four exist and they are not interchangeable.

| Situation | Do |
|---|---|
| A question, an inventory, one small contained edit | `muse-ask` |
| One task needing a check and revision rounds | Spawn the `muse-supervisor` agent with the brief |
| 2–5 independent tasks, files already partitioned | One `muse-supervisor` agent per task, all spawned in one message |
| A job that still needs decomposing | The workflow script in `${CLAUDE_PLUGIN_ROOT}/references/workflow.md` |
| 20+ trivial tasks, review batched to the end | `muse-fleet` |

**Spawning `muse-supervisor` is the default for one or a few tasks.** Hand-driving
`muse_task.py` yourself puts the same agent in both the driving and the judging seat, which
is the one separation this whole design exists to keep.


When the job still needs decomposing, run the supervised fleet workflow below. It plans the
partition, spawns one Opus supervisor per task, and returns a merge order. (`/muse:fleet
<job>` runs exactly this; these steps are the path for when this skill triggered on its own
rather than by a typed command.)

The Workflow tool requires explicit opt-in. A typed `/muse:fleet` **is** that opt-in and
needs no further confirmation. When this skill fired on an inferred trigger instead, state
the plan and its cost and get a yes first — a fleet spawns N muse runs and N Opus
supervisors, every worker runs `--yolo`, and it all costs real money. An inferred trigger is
not consent to spend it.

The script is registered by the plugin. Run it **by name** — reading it and pasting it
into `script:` is the one step on this path that used to go wrong, because a dropped line
surfaced as a throw after the planning agents had already been paid for.

```
Workflow({ name: "muse-supervised-fleet",
           args: { job: "...", repo: "<absolute path>",
                   pluginRoot: "<echo ${CLAUDE_PLUGIN_ROOT}>",
                   stamp: "<YYYYmmdd-HHMM>", maxRounds: ${user_config.max_rounds}, defaultEffort: "${user_config.default_effort}", model: "${user_config.default_model}", worktreeRoot: "${user_config.worktree_root}", refuseOnSecrets: ${user_config.refuse_on_secrets} } })
```

`${CLAUDE_PLUGIN_ROOT}/references/workflow.md` is the reasoning behind its shape; the code
is `${CLAUDE_PLUGIN_ROOT}/workflows/muse-supervised-fleet.js`.

Two args need your help. `stamp` is required because workflow scripts cannot call
`Date.now()`. `pluginRoot` is optional: run `echo ${CLAUDE_PLUGIN_ROOT}` in Bash first
and pass it so the script can fall back to the absolute `bin/muse-task` when the
plugin is not enabled in the session running the workflow.

### Driving one task by hand

`muse-task` is the instrument the supervisor holds, and it works on its own when
you want one delegated task without the orchestration. Each subcommand is one turn of the
loop; every one prints a single JSON object on stdout.

```bash
# --out defaults to .muse-fleet/tasks; pass it only to override.
muse-task run    --id tests-auth --repo . --effort "${user_config.default_effort}" \
                 --max-rounds "${user_config.max_rounds}" --model "${user_config.default_model}" \
                 --worktree-root "${user_config.worktree_root}" --refuse-on-secrets "${user_config.refuse_on_secrets}" \
                 --prompt "Create tests/test_auth.py covering login() and logout(). Do not modify auth.py."
muse-task verify --id tests-auth --command "pytest tests/test_auth.py -q"
muse-task revise --id tests-auth --feedback-file /tmp/review.txt
muse-task finish --id tests-auth --verdict accept --summary "..."
```

`run` refuses over an id that already has a task, because re-running would overwrite its
`patch.diff` and orphan its worktree. Copy the patch first and pass `--force`, or use a new
`--id`.

Rounds share one worktree, so `revise` edits the previous round's output rather than
starting over, and the harvested patch is always the cumulative diff against base — the
thing you would actually merge. `--max-rounds` (${user_config.max_rounds}) is a hard ceiling: the script
refuses past it rather than letting a supervisor loop up a bill. It is accepted **only on
`run`**, where it goes into `state.json` and is then enforced on every later `revise` —
passing it to `revise` is an argparse error. Use `--feedback-file` for a review longer than
a sentence; it avoids shell-quoting a paragraph and keeps the text intact.

Artifacts land in `<out>/<id>/` (`<out>` defaults to `.muse-fleet/tasks`):

```
patch.diff          cumulative work against base — the deliverable
state.json          rounds, feedback, and every recorded verification
task.json           the final verdict record, written by `finish`
round-<n>/          events.jsonl, stderr.log, prompt.txt, result.json per round
```

### Raw throughput without supervision

`muse-fleet` still runs the old unsupervised fan-out: N tasks, one round each,
a report at the end and nothing checked in between. Reach for it when there are thirty
trivial tasks and per-task supervision costs more than it saves — and know that you are
buying a pile of unreviewed patches.

```bash
muse-fleet \
  --tasks tasks.json --repo . --concurrency 3 \
  --effort "${user_config.default_effort}" --model "${user_config.default_model}" \
  --worktree-root "${user_config.worktree_root}" --refuse-on-secrets "${user_config.refuse_on_secrets}" \
  --schema "${CLAUDE_PLUGIN_ROOT}/assets/result-schema.json"
```

**3–5 concurrent is the reported sweet spot.** Past roughly five, the limit stops being the
tooling and becomes merge complexity plus your own capacity to review what comes back.

### Seed the worktrees with what git doesn't track

A worktree is a *clean checkout*, so everything git ignores is missing: `.env`,
`node_modules`, `.venv`, local certs. This fails quietly and in the worst way — the agent
cannot run your verification command, so it reports success it never checked, and it
"helpfully" rebuilds what looks absent. A stray `.venv` and a 14MB patch in testing here
came from exactly this.

```bash
--seed .env            # copy: each agent gets its own, cannot contaminate the original
--link node_modules    # symlink: avoids N installs, but only if nothing writes to it
```

Copy small config; symlink heavy directories. Never symlink something an agent might
install into — concurrent installs into one shared `node_modules` corrupt it. Both scripts
warn at startup when they spot common local files that exist in the repo but will be absent
from the worktrees, so you find out before the fleet does.

Both scripts refuse to start on a dirty working copy. That is deliberate: worktrees branch
from a *committed* ref, so uncommitted work is invisible and its absence reads like the
agents deleted your changes.

## Writing prompts that come back correct

A muse instance has no memory of *your* conversation with the user, and cannot ask a
question — a headless run with `--user-input-auto-resolve` cancels prompts rather than
blocking. So ambiguity does not surface as a question; it surfaces as confidently wrong
work. (It does remember its own earlier rounds; see revisions below.)

- **Name the files.** "Add tests for auth" invites a rewrite of `auth.py`; "Create
  `tests/test_auth.py`, do not modify `auth.py`" does not.
- **State the boundary.** What must *not* change is as important as what must.
- **Give an executable acceptance check.** The single highest-leverage thing in the whole
  prompt, and what the supervisor will run.
- **Keep scope to one sitting.** If a prompt needs three paragraphs, it is probably two tasks.

Between rounds is different: **rounds share a muse session**, so a revision is a genuine
follow-up. `run` mints a session id, every later round passes the same `--session-id`, and
the worker still has the brief, the files it read and its own reasoning in context. So
feedback can say "the assertion on line 12 is wrong" without restating the task.

`revise` verifies the session exists on disk before relying on it, because muse does not
error on an unknown session id — it silently starts a fresh conversation. When the session
is gone the round re-sends the full brief and says so in `session_warning`, and the emitted
`resumed: false` is your signal that the worker knows only what that prompt carried.

Feedback should still quote the failing output and name the line — vague feedback produces
a vague fix.

## Supervising — what the Opus agent is actually for

**The supervisor does not write the code.** If it patches the worktree by hand, the next
round starts from a tree muse did not produce, `finish` folds the hand-edit into the patch
and misattributes it, and you are paying Opus rates to type. It reads, judges, and
re-prompts.

Watch for the failure shapes this setup produces:

- scope creep beyond the named files
- a test that asserts current behaviour rather than correct behaviour
- a claimed verification that never ran
- `status: completed` on a zero-line patch — the agent decided nothing needed doing,
  sometimes right, more often a misread prompt
- `"oversized": true` in the round JSON (the fleet report renders it `⚠`) — nearly always
  build artifacts the excludes did not anticipate, such as a
  `.venv` created to run a check. Read the file list before assuming the change is big.

`result.json` / `self_report` is written by the same cheap model that did the work, so read
it as claims to check rather than findings to trust. Its `verification` field is the most
useful line in it: a worker that ran a real command and quoted real output is in a
different class from one that wrote `"none"`. Muse may emit several answers in sequence —
the scripts keep the last, so an early pessimistic self-report can be superseded by a later
one. The patch is ground truth either way.

`completed` means *the agent finished*. `accept` means *someone checked*. Only `finish`
produces the second, and it **refuses** the verdict unless the **final** recorded check
passed and ran against the tree being harvested. Both halves are load-bearing: a supervisor
legitimately runs a cheap gate before the real check, so a gate passing must not outrank the
real check failing after it; and a check is only evidence about the tree it actually saw, so
a green result from before something touched the worktree certifies nothing about the patch
that ships. `--accept-unverified "<reason>"` is the deliberate way past, and `/muse:status`
prints the reason on the task's row.

A red check is sometimes the *correct* outcome — a test task that correctly asserts
documented behaviour against buggy code. The fix is never to weaken the assertion; it is to
encode the divergence so the suite passes honestly (`pytest.mark.xfail(strict=True)`), or to
finish with `revise` and name the bug. Blessing a bug is the most expensive defect here.

Apply patches one at a time and run the test suite between them. If two conflict, your
decomposition was wrong — fix the partition rather than hand-merging.

```bash
git apply --check .muse-fleet/tasks/tests-auth/patch.diff   # will it apply?
git apply --3way  .muse-fleet/tasks/tests-auth/patch.diff   # apply it
```

## Guardrails

Every muse run uses `--yolo`, which disables approval prompts and the sandbox. That is
defensible **only because the blast radius is a throwaway worktree on a throwaway branch**.
Preserve that property:

- **The acceptance check is not sandboxed.** The worker runs in a throwaway worktree, but
  `muse_task.py verify` runs its `--command` on the host with your privileges, and in the
  fleet path that string was written by a model. Read a planned check like a command you
  are about to type yourself; the worktree is only its working directory, not a boundary.
- Never point a fleet at a dirty main working copy.
- Keep worktrees outside the repo (the scripts' default) so `.muse/` never pollutes it.
- Use `--max-steps` on open-ended prompts and `--max-rounds` on supervised ones so a
  confused agent cannot loop up a bill.
- Contributor models state that your content "may be used for product improvement." For
  proprietary or client-confidential code, pass `--model muse-spark-1.3` and pay full rate,
  or do not delegate it.

Workers run with `--no-foreign-personal-context`, because muse imports Claude Code personal
skills by default and a worker that loads *this* skill starts planning its own fan-out
instead of making the one edit it was asked for. `--inherit-skills` turns that off if you
genuinely want your skills available to workers.

Structured-output schemas must list **every** property in `required` — the Meta API has no
optional fields and rejects the request with a 400 about two seconds in, killing every task
in the fleet at once. The scripts validate this before spawning anything; model optional
data as always-present-but-empty (`"concerns": []`).

## Model selection

**Always use the newest contributor model, and resolve it at run time.** The default
`--model latest-contributor` reads muse's live catalog, keeps only visible models whose id
ends in `-contributor`, and picks the most recent `release_date`. A future
`muse-spark-1.5-contributor` gets used the day it lands, with no edit here.

Resolving beats hardcoding for a reason worth internalising: any version written into a
config or a script is correct only until the next release. The choice is printed and
recorded, so it is always visible rather than assumed:

```
muse_task[tests-auth]: round 1 (initial) model=muse-spark-1.3-contributor effort=low session=new
```

`is_default` does not drive the choice — the newest *contributor* model is what you want,
and the provider's default could move to a full-price tier. It only breaks ties between
models released on the same day.

To pass something else, name it: `--model muse-spark-1.3`. Interactive `muse` sessions read
`~/.config/muse/settings.json` instead, which muse maintains itself:

```bash
muse-model          # preview
muse-model --write  # apply
```

To see what a run was configured with:

Use the Grep tool to search `round-1/events.jsonl` for `run_model_configured`
and read `payload.model_id` from the matching line.

Read that as the requested id echoed back, not as proof the provider served it — a run with
a nonexistent model still reports that model here. It catches a `--model` flag that silently
never applied, which is the realistic failure.

Effort defaults to `low`, which suits mechanical work. Raise per task for genuinely hard
edits, and on a revision round when round 1 came back plausible-but-wrong rather than
mechanically incomplete. Muse latency is dominated by service contention rather than effort
— the same trivial prompt has taken 15s and 216s — so keep timeouts generous and do not
read a slow run as a stuck one.

## One-off delegation without a fleet

For a single bounded task — an inventory, a summary, one contained edit — even one
supervised task is overkill. `muse-ask` is one question, one answer on stdout:

```bash
muse-ask "List every file importing requests, with line numbers"
muse-ask --effort xhigh "Why does connect() return None after a timeout?"
muse-ask --write --effort "${user_config.default_effort}" --model "${user_config.default_model}" --refuse-on-secrets "${user_config.refuse_on_secrets}" "Add a docstring to add() in calc.py"
```

Read-only by default (writes disabled, sandbox on), so it is safe against a dirty working
copy. `--write` opts into editing and disables the sandbox — point that at a worktree or a
repo you are willing to have modified. It resolves the model through the same logic
everything else uses.

## Mixing muse and Claude

Muse is the default workhorse; Claude is for judgment. The rule that decides each step is
**whether the output can be checked**:

- There is an executable acceptance check (tests pass, mypy clean, it parses) → **muse**.
  The check does the judging, so a cheap model converges where an expensive one would.
- The only judge is taste or consequence (is this partition right, is this patch correct,
  should we ship) → **Claude**. There is no oracle, so the judgment *is* the output.

`${CLAUDE_PLUGIN_ROOT}/references/routing.md` has the full table, both engines' effort dials, and the reasoning
behind each choice.

## Details worth knowing

Delegating from inside a workflow **you** are writing — muse as one stage rather than the
whole job — is covered by "Embedding muse in your own workflow" in that same file. The
short version: a workflow script has no filesystem, so muse always runs inside an
`agent()`; pass `pluginRoot` and `stamp` through `args`; keep `--out` absolute, because an
agent's Bash cwd resets between calls and `--out` resolves against it.

`${CLAUDE_PLUGIN_ROOT}/references/workflow.md` is the primary path: the full supervised-fleet script, why each
choice is the way it is, and the variations (escalation, competing implementations, cheap
analysis inside a Claude pipeline).

`${CLAUDE_PLUGIN_ROOT}/references/muse-cli.md` documents the verified CLI surface: the JSONL event schema, the
`run_terminal` record that decides success, worktree mechanics, structured output, safety
flags, and the failure modes. Read it when adapting the scripts or debugging a run.

`scripts/muse_core.py` (in the plugin root) holds the worktree, seeding, exclusion and harvest logic shared by
`muse_task.py` and `muse_fleet.py`, so the supervised and unsupervised paths cannot drift
apart in what a patch contains.

`${CLAUDE_PLUGIN_ROOT}/scripts/validate.sh` is the maintainer's suite — run it only if asked to
verify the plugin itself. `--offline` is free and takes seconds; a bare run makes real muse
calls. `${CLAUDE_PLUGIN_ROOT}/README.md` covers it.

`${CLAUDE_PLUGIN_ROOT}/references/field-notes.md` collects what other teams learned running parallel coding agent
fleets — decomposition failures, the verification bottleneck, agent-count limits, conflict
magnets, and Anthropic's own orchestrator-worker findings. Read it when deciding *whether*
and *how hard* to fan out, rather than how to drive the CLI.

Two facts that bite hardest, both from `${CLAUDE_PLUGIN_ROOT}/references/muse-cli.md`, repeated because they cause silent data loss:

- **Muse never commits.** It leaves the worktree dirty. Harvest by staging first.
- **`git diff` omits untracked files.** A brand-new test suite reads as "no changes" unless
  you `git add -A` before diffing. The scripts do this; anything you write by hand must too.
