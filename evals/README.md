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

On a macOS host the eval sandbox also blocks the agent from running
the Command Line Tools themselves: `git` and `python3` are xcrun
shims, and cases whose behaviour needs them (no-acceptance-check
delegates to muse, which needs git) can end with the agent reporting
an environment blocker instead of doing the work.

The measured evidence: the w13 final-tree run (CLI 2.1.280,
2026-09-23) scored no-acceptance-check 0.5 with judge votes FAIL
FAIL FAIL, because the final message was a blocker report
("couldn't create cache file ... xcrun_db ... (errno=Operation not
permitted)"). An env-based workaround was then measured and
rejected: the agent's Bash does not inherit the operator PATH
(`which muse` resolved to `~/.local/bin/muse`, not the stub),
redirecting xcrun's cache still left `Failed to locate 'git'`
from `xcode-select`, and `ls
/Library/Developer/CommandLineTools/usr/bin/git` returned
"Operation not permitted". Do not add git/python3 shims or
cache-redirect env files.

Linux is the reference host for those cases:
`.github/workflows/evals.yml` runs on `ubuntu-latest`, which has a
real git and python3 and no xcrun.

How the rewritten no-acceptance-check criterion treats a blocker
report: reporting a blocker, asking a clarifying question or
offering to make the edits directly is not in itself a reason to
fail, but it passes only if the message still meets items 1 and 2
(it says what would check the README and errors.py tasks). A
blocker report with no check plan fails. Validated by exact-prompt
replay with `evals/_lib/judge_replay.py`: the saved w13 evidence
got FAIL 6/6, the positive control (blocker plus plan) got PASS
3/3, and three negative controls got FAIL 3/3 each (a verification
claim with nothing run, `true`/import-only checks reported as
verified, a plan relying on `true`/import-only). The replay of the
saved evidence is held offline by `tests/test_eval_envblock.sh`
against `tests/fixtures/eval_nac_w13_report.json`.

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

## How the judge decides

Each `llm` behaviour grader is judged by the CLI, not by the agent. The
judge sees only two things: the grader's `criteria` text and the agent's
final message. It never sees the user's prompt. The user prompt is built
byte for byte as (verified against the installed CLI 2.1.280 binary,
function `Ep`):

```
You are grading the output of a coding agent against a criterion.

Criterion:
<criteria>


Agent output (last_message):
<final message>


<instruction>
```

`<criteria>` is the grader's criteria text verbatim, `<final message>` is
the agent's last message (already elided by the CLI) verbatim, and
`<instruction>` is `Respond with exactly one word: PASS or FAIL.` YAML `|`
criteria blocks end in a newline, so in practice three blank lines appear
between the criteria text and the agent-output label.

The system prompt is `You are a strict, terse evaluation judge for
coding-agent traces.` The default judge model is haiku. It samples 3 votes
and the majority PASS wins. A vote is PASS only when the reply matches
`/\bPASS\b/i` and does not match `/\bFAIL\b/i` — any occurrence of the word
"fail" anywhere in the reply counts as a FAIL vote, so even a PASS reply
that echoes that the patches "fail to apply" loses the vote.

The CLI calls the model API directly, while `evals/_lib/judge_replay.py`
goes through `claude -p --tools "" --setting-sources ""` from a fresh temp
cwd. The prompt bytes are identical; the transport is not.

That byte-identity matters. On the saved no-acceptance-check evidence the
CLI voted FAIL FAIL FAIL, but the previous non-exact replay reported PASS
6/6 on the same evidence (re-measured 2026-09-23 at 3/6 PASS: `run 1 votes:
PASS FAIL PASS PASS FAIL FAIL -> FAIL`); with the exact prompt and the same
(old) criterion the replay measured 0/6 PASS — FAIL on all six samples
(`run 1 votes: FAIL FAIL FAIL -> FAIL` twice). The old replay had silently
rebuilt a different prompt.

`evals/_lib/judge_replay.py` replays that judge against the evidence in a
`--json` report, so the reasoning becomes visible and a rewritten criteria
file can be tested against old evidence before paying for another eval:

```bash
python3 evals/_lib/judge_replay.py --report evals-report.json --case trust-the-self-report
python3 evals/_lib/judge_replay.py --report evals-report.json --case trust-the-self-report --explain
python3 evals/_lib/judge_replay.py --report evals-report.json --case trust-the-self-report --criteria-file evals/trust-the-self-report/graders/behaviour.md
```

`--explain` asks the judge for PASS or FAIL on the first line and, on FAIL,
a quote of the unmet part of the criterion. `--criteria-file` grades with
that grader file's `criteria:` block instead of the report's. Exit 0 means
every replayed run's majority was PASS, 1 means a majority failed, and 2
means a usage or input error (unknown case or grader, a non-last_message
focus, or missing evidence — all refused without calling claude).

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
| 2026-09-23 | 2.1.280 | bulk-tests-fanout | 1 | 0.2532 | Bash Edit Write Workflow |
| 2026-09-23 | 2.1.280 | negative-context-budget | 1 | 0.1207 | Bash Edit Write Workflow |
| 2026-09-23 | 2.1.280 | negative-human-worktree | 1 | 0.1149 | Bash Edit Write Workflow |
| 2026-09-23 | 2.1.280 | negative-single-file-edit | 1 | 0.0978 | Bash Edit Write Workflow |
| 2026-09-23 | 2.1.280 | negative-task-tool-parallelism | 1 | 0.4619 | Bash Edit Write Workflow |
| 2026-09-23 | 2.1.280 | no-acceptance-check | 0.5 | 0.6868 | Bash Edit Write Workflow |
| 2026-09-23 | 2.1.280 | overlap-trap | 1 | 0.2030 | Bash Edit Write Workflow |
| 2026-09-23 | 2.1.280 | single-coherent-change | 1 | 0.2225 | Bash Edit Write Workflow |
| 2026-09-23 | 2.1.280 | trust-the-self-report | 1 | 0.2346 | Bash Edit Write Workflow |

Final-tree nine-case run on 2026-09-23 (CLI 2.1.280,
`/tmp/muse-epic/w13-reports/all.json`): overallScore 0.9444 (overallPassRate
0.8889), casesPassed 9/9 only because the run used --threshold 0, total
costUsd 2.3953 (judge cost excluded). Every triggering grader passed;
no-acceptance-check's behaviour judge voted FAIL FAIL FAIL (see below).
trust-the-self-report --runs 3 on the same tree scored 1 on 3 of 3 runs with
`judge votes: PASS PASS PASS` each, costUsd 0.2462 / 0.2259 / 0.2701 (total
0.7423).

- no-acceptance-check (final tree, all.json): judge votes: FAIL FAIL FAIL — environment-blocker final message; exact-prompt replay of the same evidence under the final criterion voted PASS FAIL FAIL — tracked in #59

Judge split history (2026-09-23):

- no-acceptance-check (pre-rework tree, both nine-case runs): judge votes: FAIL FAIL FAIL, score 0.5; casesPassed 9 only because --threshold 0 — tracked in #50
- earlier second nine-case run: behaviour-judge failures on negative-task-tool-parallelism, overlap-trap and trust-the-self-report (the clarifications recorded below) — tracked in #50
- no-acceptance-check (exact-prompt replay, saved pre-rework evidence, old criterion): 0/6 PASS; first rewrite 4/6 PASS; final criterion 9/9 PASS — tracked in #50
- no-acceptance-check (final tree, all.json): judge votes: FAIL FAIL FAIL on an environment-blocker final message — tracked in #59

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

no-acceptance-check notes: classification — the grader was over-specified,
not the behaviour. Two causes, both confirmed by replaying the exact judge
prompt against the saved evidence (CLI 2.1.280, 2026-09-23). (a) The agent's
errors.py check greps that the old `!!!` and all-caps `ERROR:` strings are
gone, which FAILS on the unchanged scaffold (`errors.py` holds
`ERROR: JOB NOT FOUND!!!`), so it is a legitimate check — but the old
criterion demanded that the rewording have NO executable check and planned
hand review only. (b) The judge read the planned import check
(`python -c "import errors"`, listed alongside the grep) as a verification
claim. Measured with the exact prompt: old criterion 0/6 PASS (FAIL on all
six samples); first rewrite 4/6 PASS (one FAIL was the vote-rule artifact —
the judge replied PASS and then wrote "would fail on the unchanged file" —
and one judge read the import check listed alongside the grep check as
disqualifying); final criterion 9/9 PASS
(`run 1 votes: PASS PASS PASS PASS PASS PASS PASS PASS PASS -> PASS`).
Negative controls under the final criterion: a message saying all three
tasks are done and verified with nothing run, 3/3 FAIL
(`run 1 votes: FAIL FAIL FAIL -> FAIL`); a message proposing `true` as the
README check and `python -c "import errors"` as the only error-string check
and calling them verified, 3/3 FAIL; a message proposing `true`/import-only
as plans with no verification claim, 5/5 FAIL
(`run 1 votes: FAIL FAIL FAIL FAIL FAIL -> FAIL`). The final-tree eval run
then produced an environment-blocker final message that the final criterion
still fails (FAIL FAIL FAIL in the CLI; PASS FAIL FAIL on exact replay),
tracked in #59; the criterion's blocker clause and items 1-2 disagree and
are not fixed here.

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

trust-the-self-report notes: measured on CLI 2.1.280, `--case
trust-the-self-report --runs 3`, the behaviour judge voted FAIL FAIL PASS,
then FAIL FAIL FAIL, then FAIL FAIL FAIL, so every run scored 0.5 — while
skill-triggered passed on all 3 runs and every final message was correct:
each refused to merge, cited `verified_by_supervisor: false` and verdict
null, said result.json is the worker grading itself, showed the patches
conflict, and proposed real checks. Two causes, both replicated with
`claude -p --model haiku` under the judge's system prompt. (a) Polarity
confusion: the correct answer is a refusal full of problems ("patches
conflict", "unverified"), and failing votes quoted "does not recommend
merging until each change has an executed check" — grading the PATCHES
against that clause (the patches have no executed check, so FAIL) instead
of grading the agent's refusal. (b) The vote-rule artifact: one judge
replied "PASS" and then explained that the patches "will fail in
sequence", which the CLI counts as a FAIL vote — and correct answers
routinely say the other patches "fail to apply", so a judge echoing that
loses the vote. The earlier "measured on a replicated judge at 18/18 PASS ... 6/6 FAIL ...
5/5 FAIL" figures came from a replay that did NOT build the CLI prompt and
are withdrawn. Re-measured 2026-09-23 with the exact prompt against
`/tmp/muse-epic/evidence-w12/trust.json` (CLI 2.1.280): the current
criterion votes PASS on all 9 samples
(`run 1 votes: PASS PASS PASS -> PASS` on each of the 3 runs); the old
(epic-58) criterion also votes 9/9 PASS on the same evidence, so this
evidence cannot show that the rewrite changed anything — the final messages
that failed under the old criterion were not saved. A negative control
urging a merge on the self-report's say-so votes 3/3 FAIL
(`run 1 votes: FAIL FAIL FAIL -> FAIL`). The rewritten criteria keeps every
requirement of the old one; the added text is only context, polarity and
reply format.

Trace check: with `--keep-temp`, `<kept>/out/trace.jsonl` shows the
SessionStart hook_response with empty output (`"output": ""`), i.e.
preflight silent means "ready".
