# muse

Offload bulk coding work to [Muse Code](https://muse.ai) instances running in isolated git
worktrees, each supervised by an Opus agent that reads the patch, runs the acceptance check
itself, and sends muse back for revisions until the work is right.

**muse types, Claude judges.** Mechanical edits do not need a frontier model deliberating
over them; push that work down to the discounted contributor tier and spend your own budget
on the parts that need judgment.

```
          ┌────────────── one Opus supervisor, one task ──────────────┐
 plan ──▶ │  muse run ──▶ read patch ──▶ verify ──▶ revise ──▶ verify │ ──▶ integrate
          │       ▲                                   │               │
          │       └───────────── until right ─────────┘               │
          └──────────────────────────────────────────────────────────-┘
```

A task does not finish when muse stops. It finishes when its supervisor says `accept`,
`revise` or `reject` — and `accept` requires a check the supervisor ran itself.

## Why supervision, not review

Cheap delegation fails in exactly one place: **a model grading its own homework.** A reviewer
that can only file a report is strictly weaker than one that can re-prompt the author in the
round where fixing is still cheap. So the grading moves into the agent that owns the task,
and the cheap model's last word is never the deliverable.

The `muse-supervisor` agent has **no Write or Edit tool**. That is deliberate — a supervisor
that can patch the worktree by hand will, and then the next round starts from a tree muse did
not produce, the harvested patch misattributes the hand-edit, and you are paying Opus rates
to type.

## Install

Requires [Muse Code](https://muse.ai) on `PATH`, `git`, `python3` and Claude Code.

```
/plugin marketplace add jellologic/muse-code
/plugin install muse@muse-code
```

Or from a local clone:

```
/plugin marketplace add ~/GitHub/muse-code
/plugin install muse@muse-code
```

Then authenticate muse once (`muse login`) and run any `muse exec` to populate its model
catalog. A SessionStart hook checks both and stays silent unless something is missing.

## Commands

| Command | Does |
|---|---|
| `/muse:delegate <task>` | One task, supervised end to end — run, verify, revise, verdict |
| `/muse:ask <question>` | One question or one contained edit, no worktree, answer on stdout |
| `/muse:fleet <job>` | Decompose a job and run the supervised fleet, one supervisor per task |
| `/muse:status` | What every task did, and whether a check actually ran |
| `/muse:model` | Which contributor model delegation will use, and the interactive pin |
| `/muse:cleanup` | Reap worktrees, branches and artifacts a run left behind |

The `muse-fleet` skill triggers on its own when a job obviously wants fan-out — repetitive
refactors across many files, tests for a list of modules, one migration pattern repo-wide.

**No command applies a patch.** They stop at a verdict and a patch path, because an accepted
patch is still a patch you have not read.

## The three rules that decide whether this works

**Partition by file.** Worktrees isolate agents from each other's *process*, not from each
other's *intentions*. Two agents editing `calc.py` each produce a clean patch, and those
patches conflict at merge. Watch for conflict magnets: routing tables, config, registries,
DI containers, lockfiles, barrel exports, migration directories.

**Every task needs a runnable check.** A supervisor's leverage is running an executable
oracle against the patch. A task with no check cannot be supervised, only guessed at — say so
up front and review that patch by hand rather than inventing a check that always passes.

**Seed what git does not track.** A worktree is a clean checkout, so `.env`, `node_modules`
and `.venv` are missing. This fails quietly: the worker cannot run the check, so it reports a
success it never verified. Copy small config (`--seed .env`), symlink heavy directories
(`--link node_modules`), and never symlink something an agent might install into.

## Layout

```
.claude-plugin/plugin.json     manifest
.claude-plugin/marketplace.json  single-plugin marketplace
commands/                      the six /muse:* commands
agents/muse-supervisor.md      Opus, owns one task to a verdict, cannot write code
hooks/preflight.sh             SessionStart; silent unless delegation would fail
skills/muse-fleet/SKILL.md     the auto-triggering surface
references/                    workflow script, CLI surface, routing, field notes
scripts/                       the drivers — see below
assets/result-schema.json      structured-output schema for worker self-reports
evals/evals.json               skill-triggering evals (see note below)
```

| Script | Does |
|---|---|
| `muse_core.py` | worktree, seeding, exclusion and harvest logic shared by both drivers |
| `muse_task.py` | one task, round by round: `run` / `verify` / `revise` / `show` / `finish` / `cleanup` |
| `muse_fleet.py` | unsupervised batch fan-out — raw throughput, review batched to the end |
| `muse_ask.sh` | one question, one answer on stdout |
| `muse_status.py` | what every task did, and what nobody checked |
| `muse_cleanup.py` | reap worktrees, branches, artifacts |
| `use_latest_contributor.sh` | point interactive muse at the newest contributor model |
| `validate.sh` | the full suite — static checks, unit tests, live runs, the supervisor loop |

## A note on the evals

`evals/evals.json` holds five skill-triggering cases — the overlap trap, the job with no
acceptance check, the coherent single change that should not fan out, and trusting a
worker's self-report. They encode the judgment calls this plugin exists to get right.

They are **not** in the `claude plugin eval` format, which wants `evals/**/case.yaml` or
`prompt.md` + `graders/*.md`. That runner is early access and was not enabled here, so the
cases were kept in their original shape rather than converted against a schema that could
not be run. Convert them when eval access lands.

## Guardrails

Workers run with `--yolo`, which disables approval prompts and the sandbox. That is
defensible **only because the blast radius is a throwaway worktree on a throwaway branch.**
Preserve that property: never point a fleet at a dirty main working copy, keep worktrees
outside the repo, and use `--max-steps` and `--max-rounds` so a confused agent cannot loop up
a bill.

Contributor models state that your content "may be used for product improvement." For
proprietary or client-confidential code, pass `--model muse-spark-1.3` and pay full rate, or
do not delegate it.

Workers run with `--no-foreign-personal-context`, because muse imports Claude Code personal
skills by default and a worker that loads a fan-out skill starts planning its own fan-out
instead of making the one edit it was asked for.

## Validating

```bash
bash scripts/validate.sh --offline   # free, seconds — spawns no muse
bash scripts/validate.sh             # everything, including live runs
```

`--offline` runs the static checks, the unit tests, the preflight guardrails and the
status/cleanup suite against real git worktrees. It spawns no muse, costs nothing and takes
seconds, so it can run on every change.

The full run adds live runs of both drivers, the supervisor loop, re-run safety, seeding and
`muse_ask`. It builds throwaway repos in a temp dir and touches nothing of yours, but it
makes real muse calls, so it costs a little and takes several minutes. Run it when muse ships
a new version and you want to know whether any behaviour this plugin depends on has moved.

## License

MIT
