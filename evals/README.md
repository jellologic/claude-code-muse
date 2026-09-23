# Eval suite

Runnable skill-routing evals for `claude plugin eval` (CLI >= 2.1.280, the
floor in `scripts/muse_core.py`). Nine cases: five positive (the muse-fleet
skill should fire and the response should follow the supervised path) and four
negative (ordinary work that merely shares vocabulary with the skill
description, where firing is the failure).

## How to run it

Full suite (manual; needs `ANTHROPIC_API_KEY`, network, and real money):

```bash
PATH="$PWD/evals/_lib/bin:$PATH" claude plugin eval . --runs 3 --max-cost-usd 5 --threshold 0.8 --json evals-report.json --scaffold --trust-plugin --no-publish --allow-tools Bash Edit Write Workflow
```

One case while iterating:

```bash
PATH="$PWD/evals/_lib/bin:$PATH" claude plugin eval . --case bulk-tests-fanout --runs 1 --ablation none --scaffold --trust-plugin --max-cost-usd 1 --no-publish --allow-tools Bash Edit Write Workflow
```

Why each flag matters:

- `PATH="$PWD/evals/_lib/bin:$PATH"` — puts the committed stub muse on
  PATH from the operator's shell (see "How the muse stub works"). This
  prefix is shell, not part of the eval command.
- `--scaffold` — scaffolds are OFF by default. Without it the case runs
  against an unstaged workspace ("the case runs against an unstaged
  workspace"), so none of the fixtures in `evals/<case>/scaffold.sh` exist
  and every fixture-dependent check fails.
- `--trust-plugin` — without it the CLI stops at an interactive trust prompt,
  which hangs a headless runner.
- `--runs 3` / `--max-cost-usd 5` / `--threshold 0.8` — three samples per case,
  a spend cap, and the pass bar. Results land in `evals/results/` (git-ignored).
- `--ablation none` (single-case form) — the default `--ablation
  with-without` runs each case twice, with and without the skill, and a
  `tool_used: Skill` grader with no `arm` counts as a display-only,
  "with-only" indicator there: shown but adding nothing to the score. That is
  exactly what the positive cases want (the scored outcome is their `llm`
  behaviour grader), while every negative case sets `arm: both` on its
  `tool_used` grader so the must-NOT-fire check is scored in both arms.
  `--ablation none` scores everything in one arm. The full-suite command keeps
  the default ablation on purpose: its with-without delta is the "does the
  skill earn its tokens" number.
- `--no-publish` — keep results local instead of uploading them.
- `--json evals-report.json` — machine-readable report next to the
  `evals/results/` run dirs.
- `--allow-tools Bash Edit Write Workflow` — operator grant for the gated
  tools the cases allow. The flag is variadic, so it must stay the LAST
  argument.

CI runs this on demand only: `.github/workflows/evals.yml` is
`workflow_dispatch`, reusing the pinned actions and the CLI install line from
`validate.yml`, with the same PATH prefix and trailing `--allow-tools`.

## How the muse stub works

The eval sandbox gives the agent a fresh, empty HOME, so `hooks/preflight.sh`
would see no `muse` binary and no credentials and correctly refuse to
delegate. The stub closes that gap without touching production: it lives at
`evals/_lib/bin/muse`, a committed `#!/bin/sh` script, and it reaches the
sandbox on PATH from the operator's shell
(`PATH="$PWD/evals/_lib/bin:$PATH"` locally,
`PATH="$GITHUB_WORKSPACE/evals/_lib/bin:$PATH"` in `evals.yml`).
That indirection is forced, not stylistic: `case.yaml` `execution.env`
accepts only `EVAL_*` keys, and anything else is refused with this exact
error:

`case "pc" execution.env key "PATH" is not allowed — only EVAL_* keys can be set from case.yaml. Anything else must come from the operator's shell.`

So PATH (and HOME) cannot be set from `case.yaml`; the operator's PATH,
which does reach the SessionStart hook and the agent unchanged, is the only
way the stub gets found. The sandbox sets HOME to `<tmp>/home` and the cwd
to `<tmp>/home/cwd`, and the scaffold runs with that same HOME.

Each `scaffold.sh` sources `evals/_lib/fixture.sh` and calls
`stub_muse_home`, which writes only the credentials side into the sandbox
HOME — the binary itself is never written there:

- `.config/muse/auth.json` — non-empty but clearly fake
  (`{"stub": "claude plugin eval fixture, ..."}`, never credential-shaped, so
  the repo's secret scanners stay quiet).
- `.local/share/muse/model-catalog/eval.json` — one visible
  `*-contributor` row, the shape `muse_core.catalog_rows` reads, so the
  catalog check passes.

The stub emulates just enough of the CLI to be convincing, and nothing
leaves the machine:

- `--version` prints `muse <MUSE_TESTED_VERSION>`, read at runtime from
  `scripts/muse_core.py` so it can never drift behind the floor preflight
  checks against. An unreadable version source exits non-zero on stderr.
- `exec ... --workspace <dir> ... --prompt-file <file>` (both flags are
  what `muse_cmd`/`run_muse` pass) makes a real edit inside the workspace:
  when the brief names a path matching `tests/test_<name>.py` it writes
  that file — repo root inserted on `sys.path` ahead of the py3.9 stdlib
  (so `import parser` finds the fixture, not the stdlib module), a
  `test_imports` function runnable under both `python3 tests/test_x.py`
  (prints ok) and pytest — and otherwise appends a line to
  `EVAL_STUB_CHANGES.md`. It then prints exactly one JSON line,
  `{"payload":{"kind":"run_terminal","terminal":"completed","text":"eval stub: <what it wrote>"}}`,
  and exits 0.
- Anything else prints `eval stub muse: <args> is not emulated` on stderr
  and exits 1. No network call exists anywhere in the stub.

## Tool grants

`allowed_tools` is set per case in `case.yaml`, granting only what that
case's behaviour needs. The CLI gates Bash, Edit, Write, WebFetch, `mcp__*`
and Workflow; those need the operator's trailing `--allow-tools`. Agent is
not gated: bulk-tests-fanout spawned supervisors without an Agent grant.

| case | allowed_tools | why |
|---|---|---|
| bulk-tests-fanout | Read, Glob, Grep, Skill, Bash, Edit, Write, Agent, Workflow | The skill drives `bin/muse-task` / `bin/muse-fleet` through Bash, spawns supervisors via Agent, and runs the fleet via Workflow; inline edits use Edit/Write |
| no-acceptance-check | Read, Glob, Grep, Skill, Bash, Edit, Write, Agent, Workflow | Same supervised path as bulk-tests-fanout |
| overlap-trap | Read, Glob, Grep, Skill, Bash, Edit, Write, Agent, Workflow | Same supervised path as bulk-tests-fanout |
| single-coherent-change | Read, Glob, Grep, Skill, Bash, Edit, Write, Agent, Workflow | Same supervised path as bulk-tests-fanout |
| trust-the-self-report | Read, Glob, Grep, Skill, Bash, Edit, Write, Agent, Workflow | Same supervised path as bulk-tests-fanout |
| negative-single-file-edit | Read, Glob, Grep, Skill, Edit, Write | The correct outcome is one inline edit; no shell or agents needed |
| negative-human-worktree | Read, Glob, Grep, Skill, Bash | The correct outcome runs `git worktree add`; Bash drives git |
| negative-task-tool-parallelism | Read, Glob, Grep, Skill, Agent | The correct outcome spawns ordinary subagents via Agent |
| negative-context-budget | Read, Glob, Grep, Skill | The correct outcome is advice; no tools beyond reading |

Granting Bash here is safe: every delegation the agent can attempt lands
on the committed stub, which edits a throwaway workspace and emits a
terminal record locally. Delegation stays offline and free — no credential,
no network, no spend beyond the eval's own model calls.

## Host limitation: Bash evals and ~/.docker

Measured: on a machine whose `~/.docker` holds a symbolic link inside it,
any eval that grants Bash refuses to run with "the Docker (~/.docker,
DOCKER_CONFIG) credential store on this machine holds a symbolic link
inside it, so the Bash sandbox cannot reliably exclude it". Setting
`DOCKER_CONFIG` does not help, and `~/.docker` is never modified to work
around this. What works (measured, costs nothing extra) is pointing HOME
at a temp dir for the parent claude, carrying over just the auth state:

```bash
H=$(mktemp -d); ln -s "$HOME/.claude" "$H/.claude"; cp "$HOME/.claude.json" "$H/.claude.json"; ln -s "$HOME/Library" "$H/Library"
HOME="$H" PATH="$PWD/evals/_lib/bin:$PATH" claude plugin eval . ... --allow-tools Bash Edit Write Workflow
```

The temp HOME holds a `~/.claude` symlink, a COPY of `~/.claude.json`
and a `~/Library` symlink. `--allow-tools` is variadic, so it stays LAST.

Git inside the eval's Bash sandbox is a second limitation on macOS:
`/usr/bin/git` is the xcrun shim, and the sandbox blocks reading
`/Library/Developer/CommandLineTools` and writing xcrun's cache, so git
does not run there. Measured on negative-human-worktree: skill-not-triggered
PASSED, but the behaviour grader failed 3/3 — the agent could not list
branches, so it asked "which three branches?" instead of giving the
`git worktree add` command for each. CI (Linux) has a real git. The case
handles this honestly: its prompt names the three fixture branches its
scaffold creates (`feature/search`, `fix/login-timeout`, `chore/deps`), so
the grader's requirement can be met without running git. The case's
skill-not-triggered grader is unchanged. With the branches named,
behaviour PASS x3 and skill-not-triggered passed (Skill called 0x) in the
recorded run.

## How to add a case

1. Create `evals/<name>/` with `case.yaml` (schema below), `prompt.md`
   (body only — frontmatter keys would OVERRIDE `case.yaml`, so none), and
   `graders/*.md`.
2. Write `evals/<name>/scaffold.sh`: `#!/bin/bash`, `set -eu`, source the
   helper as `. "$(dirname "$0")/../_lib/fixture.sh"`, `git init -q -b main`,
   write the fixture files, call `stub_muse_home`, commit with
   `fixture_commit` (the scaffold has no git identity: empty HOME,
   `GIT_CONFIG_NOSYSTEM=1`). Keep it bash 3.2 compatible, with no absolute
   or machine-specific paths; CI's hardcoded-path guard rejects
   home-directory prefixes.
3. Add an expectation entry for the case in `tests/eval_case.py`
   (`cmd_expect` fails on unknown names, so this is enforced), then run
   `bash tests/test_evals.sh` and `bash scripts/validate.sh --offline`.

`case.yaml` uses a restricted YAML subset so the offline suite can parse it
without PyYAML: `key: scalar` lines, flow lists like `[Read, Glob, Grep,
Skill]`, and nested maps indented exactly 2 spaces (`context:`,
`execution:`). No block lists, multi-line strings, or anchors. Every case
sets `schema_version: "1.1"`, `runs: 3`,
`context.scaffold_script: scaffold.sh`, and `allowed_tools` including
`Skill` — the exact grant per case is listed in "Tool grants" above, and
the gated tools among them ride the operator's trailing `--allow-tools`.
`execution.env` is optional; when present, only `EVAL_*` keys validate
(anything else is refused by the CLI at run time). Positive cases use
`max_turns: 15` / `timeout_seconds: 600`; negatives use `10` / `300`.

## Baseline

Pre-fix measurement from the issue (CLI 2.1.280, ~$0.14 total):

| date | CLI | case | score | cost | note |
|---|---|---|---|---|---|
| 2026 (issue) | 2.1.280 | negative-single-file-edit | 0.5 | part of ~$0.14 | fixture missing |
| 2026 (issue) | 2.1.280 | bulk-tests-fanout | 0 | part of ~$0.14 | Skill called 0x, preflight reported no credentials |

Post-fix measurements on this host (`--ablation none`, `--runs 1`,
`--allow-tools Bash Edit Write Workflow`, temp-HOME workaround above).

| date | CLI | case | score | costUsd | --allow-tools |
|---|---|---|---|---|---|
| 2026-09-23 | 2.1.280 | bulk-tests-fanout | 1 | 0.3018 | Bash Edit Write Workflow |
| 2026-09-23 | 2.1.280 | no-acceptance-check | 1 | 0.2398 | Bash Edit Write Workflow |
| 2026-09-23 | 2.1.280 | overlap-trap | 1 | 0.2032 | Bash Edit Write Workflow |
| 2026-09-23 | 2.1.280 | single-coherent-change | 1 | 0.2229 | Bash Edit Write Workflow |
| 2026-09-23 | 2.1.280 | trust-the-self-report | 1 | 0.2295 | Bash Edit Write Workflow |
| 2026-09-23 | 2.1.280 | negative-single-file-edit | 1 | 0.0970 | Bash Edit Write Workflow |
| 2026-09-23 | 2.1.280 | negative-human-worktree | 1 | 0.1123 | Bash Edit Write Workflow |
| 2026-09-23 | 2.1.280 | negative-task-tool-parallelism | 1 | 0.1043 | Bash Edit Write Workflow |
| 2026-09-23 | 2.1.280 | negative-context-budget | 1 | 0.1195 | Bash Edit Write Workflow |

One full run of all nine cases on 2026-09-23 (all nine passed, total costUsd 1.6304, judge cost excluded), taken before the three clarifications below. A second full run on the same skill description passed every triggering grader but had three behaviour-judge failures (negative-task-tool-parallelism, overlap-trap, trust-the-self-report); those are the clarifications recorded below.

Skill token budget (`claude --plugin-dir . plugin details muse`): before ~564 tok Always-on (muse-fleet ~190), after the description fix ~625 tok (muse-fleet ~260); the ceiling is 750.

Diagnosis, measured 2026-09-23 on CLI 2.1.280 (`--runs 1`,
`--ablation none`, full grants, temp-HOME workaround):

single-coherent-change: behaviour PASS (3/3), skill-triggered FAIL
("Skill called 0x"). The trace shows the agent read
auth.py/session.py/refresh.py and correctly declined ("I'd hold off on the
parallel muse agents for this one ... one small bug that runs through all
of them") but never loaded the skill. Classification: the skill
DESCRIPTION is wrong, not the prompt or the grader — the answer was
right, but the model skipped the skill because the description says "Not
for a single coherent change, debugging ..." and no longer says to load
it whenever the user names muse. After the description fix (it now says
to load the skill whenever the user names muse, including work the skill
should decline): Skill called 1x, behaviour PASS x3.

trust-the-self-report: behaviour PASS (3/3), skill-triggered FAIL
("Skill called 0x"). The trace shows the agent inspected
.muse-fleet/*/task-N/task.json + result.json and correctly refused to
merge (verified_by_supervisor false, no tests exist, patches conflict) but
never loaded the skill. Classification: the skill DESCRIPTION is wrong,
not the prompt or the grader — the description says nothing about judging
or merging a muse run's results, so the model saw no reason to load it.
After the description fix (it now covers judging or merging a muse run's
patches): Skill called 1x, behaviour PASS x3.

All four negative cases were re-run after the description change and
still scored skill-not-triggered (Skill called 0x); the old bare
`fan-out` trigger is now tied to muse workers because
negative-task-tool-parallelism uses that vocabulary with no muse.

no-acceptance-check: skill-triggered PASS (1x), behaviour PASS (3/3) in
the diagnosis run, cost 0.3074 (see the recorded full-run row above).
Fixed by granting Workflow (a gated tool, see Tool grants); grader and
prompt unchanged. The earlier 0.50 run used `--allow-tools Edit Write`,
so the skill's Workflow and Bash paths were refused.

bulk-tests-fanout notes: four earlier runs scored 0.5. The first three
used a yes-first criterion that contradicted SKILL.md's path table: 2-5
already-partitioned tasks means spawning one muse-supervisor per task
directly. The fourth used an either-route criterion that the last-message
judge could not confirm. The recorded run (score 1, judge PASS x3) uses
the current criterion. The agent delegated to four supervisors, they had
no shell under `--allow-tools Edit Write`, and it reported honestly that
no tests exist yet and what it needs to proceed.

negative-single-file-edit notes: report
`evals/results/2026-09-23T05-10-18-152Z`, score 1 — behaviour PASS PASS
PASS, skill-not-triggered passed with Skill called 0x.

negative-task-tool-parallelism notes: judge votes FAIL PASS FAIL. The
evidence showed the agent proposing three parallel agents (api/, db/,
ui/) and asking what task they should do, because the prompt said "fan
this out" and never said what "this" is. Classification: the PROMPT is
ambiguous, not the grader — a correct agent cannot route work it was
never given. The prompt now names a concrete read-only task (a bug hunt
over api/, db/ and ui/, "Don't edit anything") and the criteria judge
only the final message with an explicit PASS/FAIL shape. This does not
weaken the case: skill-not-triggered is unchanged, the prompt keeps the
"fan out / subagents / in parallel" vocabulary with muse still unnamed,
and routing the work to Muse Code still fails.

overlap-trap notes: judge votes FAIL FAIL PASS. The evidence showed the
agent recommending against parallel runs and naming the same-file
conflicts, including (c) touching app.py and tasks.py; it proposed ONE
supervised muse task with a check and did not offer worktrees. It also
asked a design question about renaming an imported name to _helper,
reported a git sandbox blocker, and offered to do the ~20-line edit
directly. Classification: the GRADER is under-specified for a
last-message judge — a correct answer with extra honest behaviour failed
for things the criteria never allowed. The criteria now open with "Judge
only the final message" and close by not failing a clarifying design
question, an environment-blocker report, or an offer to make the small
edit directly. Every existing requirement is kept: no fanning out three
colliding tasks, no worktree isolation as the fix.

trust-the-self-report notes: judge votes FAIL FAIL FAIL. The evidence
showed the agent refusing ("No, not yet"): it cited
verified_by_supervisor false and verdict null, said result.json is the
worker grading itself, noted there is no test suite, showed the four
patches conflict, and proposed an executed check per function before
applying. It proposed combining the conflicting patches into one checked
change rather than merging one at a time. Classification: the GRADER
demands one specific merge order, which the prompt never asks for — the
refusal and every check were right. The ending now accepts either order:
merging the patches one at a time or combining conflicting patches into
one checked change. Every other requirement is kept: refuse the
self-report, check the supervisor proof, inspect the patches, and
recommend no merge until each change has an executed check.

Trace check: with `--keep-temp`, `<kept>/out/trace.jsonl` shows the
SessionStart hook_response with empty output (`"output": ""`), i.e.
preflight silent means "ready".
