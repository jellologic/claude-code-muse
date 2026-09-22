---
name: muse-fleet
description: >-
  Delegate bulk coding work to Muse Code (`muse exec`) instances running in isolated git
  worktrees, each supervised by an Opus agent that reviews the patch, runs the acceptance
  check and sends muse back for revisions until the work is right. Use this whenever a job
  splits into several independent, mechanical edits — repetitive refactors across many
  files, adding tests or docstrings to a list of modules, applying one migration pattern
  repo-wide, bulk dependency or lint fixes, drafting several independent implementations to
  compare — and especially whenever the user mentions muse, offloading work to a cheaper
  model, running agents in parallel, fanning out tasks, worktree isolation, conserving
  Claude usage limits, or says the work is "a lot of grunt work" or "don't burn my tokens
  on this". Prefer this over doing many similar edits inline.
---

# Muse Fleet

Run many Muse Code instances at once, each sealed in its own git worktree and each **owned
by an Opus supervisor** that spawns it, reads what came back, runs the acceptance check,
and sends it back for revisions until the work is right.

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

Six commands you type, one agent the fan-out uses, and the scripts underneath all three.

| Command | Does |
|---|---|
| `/muse:delegate <task>` | One task, supervised end to end — run, verify, revise, verdict. The common case. |
| `/muse:ask <question>` | One question or one contained edit, no worktree, answer on stdout. |
| `/muse:fleet <job>` | Decompose a job and run the supervised fleet: N tasks, one supervisor each. |
| `/muse:status` | What every task in the current run did, and whether a check actually ran. |
| `/muse:model` | The contributor model that will be used, and the interactive pin. |
| `/muse:cleanup` | Reap worktrees, branches and artifacts a run left behind. |

The `muse-supervisor` agent is what `/muse:delegate` and the fleet workflow spawn: one
Opus agent that owns one task to a verdict. **It has no Write or Edit tool.** That is not
an oversight — a supervisor that can patch the worktree itself will, and then the next
round starts from a tree muse did not produce, `finish` folds the hand-edit into the patch
and misattributes it, and you are paying Opus rates to type. Removing the tool makes the
architecture true rather than merely recommended.

None of the commands apply a patch. They stop at a verdict and a patch path and hand the
decision to you, because an accepted patch is still a patch you have not read.

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

**Type `/muse:fleet <job>` and this is all handled.** What follows is what that command
does, and is also the path to take when the skill triggered on its own rather than by a
typed command.

The Workflow tool requires explicit opt-in, and a skill
instructing you to call it is one of the accepted forms — so invoking this skill for a
fan-out job authorises the script in `${CLAUDE_PLUGIN_ROOT}/references/workflow.md`. Read that file and run it.
It plans the partition, spawns one Opus supervisor per task, and returns a merge order.

```
Workflow({ script: <${CLAUDE_PLUGIN_ROOT}/references/workflow.md>,
           args: { job: "...", repo: ".", pluginRoot: "<echo ${CLAUDE_PLUGIN_ROOT}>",
                   stamp: "<YYYYmmdd-HHMM>", maxRounds: 3 } })
```

Two args the script cannot work out for itself. `stamp`, because workflow scripts cannot
call `Date.now()`. And `pluginRoot`, because a workflow script sees no environment and so
cannot read `${CLAUDE_PLUGIN_ROOT}` itself — run `echo ${CLAUDE_PLUGIN_ROOT}` in Bash first
and pass the result. The script throws on a missing `pluginRoot` rather than shelling out
to a path that is not there.

### Driving one task by hand

`${CLAUDE_PLUGIN_ROOT}/scripts/muse_task.py` is the instrument the supervisor holds, and it works on its own when
you want one delegated task without the orchestration. Each subcommand is one turn of the
loop; every one prints a single JSON object on stdout.

```bash
T=${CLAUDE_PLUGIN_ROOT}/scripts/muse_task.py

python3 $T run    --id tests-auth --out .muse-fleet/x --repo . --effort low \
                  --prompt "Create tests/test_auth.py covering login() and logout(). Do not modify auth.py."
python3 $T verify --id tests-auth --out .muse-fleet/x --command "pytest tests/test_auth.py -q"
python3 $T revise --id tests-auth --out .muse-fleet/x \
                  --feedback "test_logout asserts the current buggy return of None; it must assert True."
python3 $T finish --id tests-auth --out .muse-fleet/x --verdict accept --summary "..."
```

Rounds share one worktree, so `revise` edits the previous round's output rather than
starting over, and the harvested patch is always the cumulative diff against base — the
thing you would actually merge. `--max-rounds` (default 3) is a hard ceiling: the script
refuses past it rather than letting a supervisor loop up a bill.

Artifacts land in `<out>/<id>/`:

```
patch.diff          cumulative work against base — the deliverable
state.json          rounds, feedback, and every recorded verification
task.json           the final verdict record, written by `finish`
round-<n>/          events.jsonl, stderr.log, prompt.txt, result.json per round
```

### Raw throughput without supervision

`${CLAUDE_PLUGIN_ROOT}/scripts/muse_fleet.py` still runs the old unsupervised fan-out: N tasks, one round each,
a report at the end and nothing checked in between. Reach for it when there are thirty
trivial tasks and per-task supervision costs more than it saves — and know that you are
buying a pile of unreviewed patches.

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/muse_fleet.py \
  --tasks tasks.json --repo . --concurrency 3 \
  --schema ${CLAUDE_PLUGIN_ROOT}/assets/result-schema.json
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

A muse instance has no memory of your conversation and cannot ask you a question — a
headless run with `--user-input-auto-resolve` cancels prompts rather than blocking. So
ambiguity does not surface as a question; it surfaces as confidently wrong work.

- **Name the files.** "Add tests for auth" invites a rewrite of `auth.py`; "Create
  `tests/test_auth.py`, do not modify `auth.py`" does not.
- **State the boundary.** What must *not* change is as important as what must.
- **Give an executable acceptance check.** The single highest-leverage thing in the whole
  prompt, and what the supervisor will run.
- **Keep scope to one sitting.** If a prompt needs three paragraphs, it is probably two tasks.

Muse has no memory *between rounds* either, which is why `revise` re-sends the original
brief alongside the feedback and tells the worker its previous attempt is already in the
tree. Feedback should quote the failing output and name the line — vague feedback produces
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
- `⚠ oversized` — nearly always build artifacts the excludes did not anticipate, such as a
  `.venv` created to run a check. Read the file list before assuming the change is big.

`result.json` / `self_report` is written by the same cheap model that did the work, so read
it as claims to check rather than findings to trust. Its `verification` field is the most
useful line in it: a worker that ran a real command and quoted real output is in a
different class from one that wrote `"none"`. Muse may emit several answers in sequence —
the scripts keep the last, so an early pessimistic self-report can be superseded by a later
one. The patch is ground truth either way.

`completed` means *the agent finished*. `accept` means *someone checked*. Only `finish`
produces the second, and `task.json` records `verified_by_supervisor` so an accept with no
executed check is visible rather than buried.

Apply patches one at a time and run the test suite between them. If two conflict, your
decomposition was wrong — fix the partition rather than hand-merging.

```bash
git apply --check .muse-fleet/x/tests-auth/patch.diff   # will it apply?
git apply --3way  .muse-fleet/x/tests-auth/patch.diff   # apply it
```

## Guardrails

Every muse run uses `--yolo`, which disables approval prompts and the sandbox. That is
defensible **only because the blast radius is a throwaway worktree on a throwaway branch**.
Preserve that property:

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
muse_task[tests-auth]: round 1 (initial) model=muse-spark-1.3-contributor effort=low
```

This deliberately ignores the catalog's `is_default` flag — the newest *contributor* model
is what you want, and the provider's default could move to a full-price tier.

To pass something else, name it: `--model muse-spark-1.3`. Interactive `muse` sessions read
`~/.config/muse/settings.json` instead, which muse maintains itself:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/use_latest_contributor.sh          # preview
${CLAUDE_PLUGIN_ROOT}/scripts/use_latest_contributor.sh --write  # apply
```

To see what a run was configured with:

```bash
jq -r 'select(.payload.kind=="run_model_configured") | .payload.model_id' round-1/events.jsonl
```

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
supervised task is overkill. `${CLAUDE_PLUGIN_ROOT}/scripts/muse_ask.sh` is one question, one answer on stdout:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/muse_ask.sh "List every file importing requests, with line numbers"
${CLAUDE_PLUGIN_ROOT}/scripts/muse_ask.sh --effort xhigh "Why does connect() return None after a timeout?"
${CLAUDE_PLUGIN_ROOT}/scripts/muse_ask.sh --write --effort low "Add a docstring to add() in calc.py"
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

`${CLAUDE_PLUGIN_ROOT}/references/workflow.md` is the primary path: the full supervised-fleet script, why each
choice is the way it is, and the variations (escalation, competing implementations, cheap
analysis inside a Claude pipeline).

`${CLAUDE_PLUGIN_ROOT}/references/muse-cli.md` documents the verified CLI surface: the JSONL event schema, the
`run_terminal` record that decides success, worktree mechanics, structured output, safety
flags, and the failure modes. Read it when adapting the scripts or debugging a run.

`${CLAUDE_PLUGIN_ROOT}/scripts/muse_core.py` holds the worktree, seeding, exclusion and harvest logic shared by
`muse_task.py` and `muse_fleet.py`, so the supervised and unsupervised paths cannot drift
apart in what a patch contains.

`${CLAUDE_PLUGIN_ROOT}/scripts/validate.sh` re-runs the full suite — static checks, unit tests, preflight
guardrails, live runs of both paths, the supervisor loop, re-run safety, seeding, and
`muse_ask`. It builds throwaway repos in a temp dir and touches nothing of yours. Run it
after changing the scripts, or when muse ships a new version and you want to know whether
any behaviour this skill depends on has moved:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/validate.sh
```

It makes real muse calls, so it costs a little and takes several minutes.

`${CLAUDE_PLUGIN_ROOT}/references/field-notes.md` collects what other teams learned running parallel coding agent
fleets — decomposition failures, the verification bottleneck, agent-count limits, conflict
magnets, and Anthropic's own orchestrator-worker findings. Read it when deciding *whether*
and *how hard* to fan out, rather than how to drive the CLI.

Two facts from it that bite hardest, repeated because they cause silent data loss:

- **Muse never commits.** It leaves the worktree dirty. Harvest by staging first.
- **`git diff` omits untracked files.** A brand-new test suite reads as "no changes" unless
  you `git add -A` before diffing. The scripts do this; anything you write by hand must too.
