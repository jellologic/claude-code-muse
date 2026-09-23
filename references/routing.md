# Routing work between muse and Claude

A workflow has two engines available and two dials on each. Using them well is mostly one
decision, repeated: **for this step, is there an oracle?**

## The routing rule

Route by **whether the output can be checked**, not by a ranking of model quality.

- **Work with an executable acceptance check** — the tests pass or they don't, mypy is
  clean or it isn't, the file parses or it doesn't → **muse**. A cheap model that can run
  the check and iterate against it converges on the same answer an expensive one would,
  because the check does the judging.
- **Work whose only judge is taste or consequence** — is this partition right, is this
  patch actually correct, is this test asserting the right thing, should we ship → **Claude**.
  There is no oracle, so the quality of the judgment *is* the output.

This is why muse should be the default workhorse: most bulk coding work has an oracle.
It is also why review stays with Claude even when muse wrote the code — a model grading its
own homework with no external check is the one place cheap delegation reliably fails.

Cost makes the same argument from the other side. For the 1.2 generation the published
split was $0.10/$0.20 per M in/out on the contributor tier against $1.25/$4.25 on the full
model — 12x and 21x. The catalog returns `cost: null` for the 1.3 rows, so treat that ratio
as the shape of the discount rather than a current quote, and check Meta's pricing page if
the exact number matters. Either way the question is never "which model is better in the
abstract" but "does this step need judgment I cannot verify cheaply?"

## The dials

**muse** — `--reasoning-effort none|minimal|low|medium|high|xhigh|max` (CLI default `high`;
these scripts default to `low`).

| effort | use for |
|---|---|
| `minimal`/`low` | mechanical edits with a check to iterate against — the common case |
| `medium` | edits needing local design judgment (naming an abstraction, picking an approach) |
| `xhigh` | one genuinely hard fix; the catalog annotates this as "deepest analysis and complex fixes" |
| `max` | reserve for when `xhigh` demonstrably failed |

Effort is not a reliable latency dial. The same trivial prompt has taken 216s at `minimal`
and 15s at `low` — service contention dominates. Raise effort for difficulty, not speed,
and keep timeouts generous either way.

**Claude** — `agent(prompt, { model, effort })`.

| option | notes |
|---|---|
| `model` | omit to inherit the session model — correct for most stages. Set it only when confident a tier fits: `haiku` for high-volume triage, `opus` for final judgment. |
| `effort` | `'low'` for mechanical stages, `'high'`/`'max'` for the hardest verify or judge stages. |

The workflow guidance is explicit that omitting `model` is the right default. Override it
where volume or stakes justify the choice, not reflexively on every call.

## A default routing table

| Step | Engine | Setting |
|---|---|---|
| Decompose a job into disjoint tasks | Claude | session model, `effort: 'medium'` |
| Bulk mechanical edits across N files | **muse**, one per task | `--effort low` |
| Supervise one delegated task to a verdict | Claude `opus` | `effort: 'high'` |
| Single contained edit | **muse ask** `--write` | `--effort low` |
| Read-only analysis, inventory, summarisation | **muse ask** | `--effort low` |
| One hard bug fix with a failing test to target | **muse ask** `--write` | `--effort xhigh` |
| Triage / classify / label at volume | Claude `haiku`, or muse | `effort: 'low'` |
| Review a patch for correctness | Claude | `effort: 'high'` |
| Adversarial verification of a finding | Claude | `effort: 'high'` |
| Final synthesis or ship/no-ship call | Claude `opus` | `effort: 'high'` |

Note that "review a patch" is no longer a separate downstream row in the default
architecture — it is folded into the supervisor row, because a reviewer that can re-prompt
the author in the same round is strictly more useful than one that can only file a report.

Treat this as a starting point. The useful instinct is to ask what would happen if this
step were wrong and nobody noticed — that is what decides how much to spend on it.

## Calling muse from a workflow

Workflow `agent()` runs Claude. Muse is reached by having an agent shell out — so the
fan-out unit is **one Opus agent per task**, each driving `muse_task.py` through as many
rounds as its task needs. `references/workflow.md` has the full script.

```javascript
const results = await parallel(tasks.map(t => () => agent(
  `Run:  muse-task run --id ${t.id} --out ${OUT} \\
           --prompt ${JSON.stringify(t.prompt)}
   Read the patch it prints. Run your own check:
         muse-task verify --id ${t.id} --out ${OUT} \\
           --command ${JSON.stringify(t.check)}
   Wrong or failing → revise --feedback "<specific defects>" and verify again.
   Then finish --verdict <accept|revise|reject>. Do not write the code yourself.`,
  { label: `task:${t.id}`, phase: 'Build', model: 'opus', effort: 'high',
    schema: VERDICT_SCHEMA })))
```

This is the opposite of the advice an earlier version of this file gave. The reason for the
change: one agent supervising the whole fleet can only report defects, while one agent per
task can *fix* them, in the round where fixing is still a cheap-model edit rather than your
problem at merge time. Per-task supervision costs more agents; it is worth it whenever the
work matters more than the throughput.

Do **not** add `isolation: 'worktree'` to these agents — `muse_task.py` already creates one
worktree per task, and nesting them produces a patch against the wrong base.

When the work genuinely does not merit supervision — thirty trivial tasks, or a first look
at how a job decomposes — `muse_fleet.py` still does the unsupervised fan-out in one agent,
with its own timeouts, harvesting, exclusions and teardown.

A single muse question — cheap analysis inside a larger Claude pipeline:

```javascript
const inventory = await agent(
  `Run: muse-ask --effort low \\
     "List every file importing 'requests' with its line number"
   Return its stdout verbatim.`,
  { label: 'inventory', effort: 'low' })
```

Per-task effort inside one fleet — mixing dials within a single fan-out:

```javascript
const tasks = [
  { id: 'hints-utils', prompt: 'Add type hints to utils.py …',  effort: 'low' },
  { id: 'fix-retry',   prompt: 'Fix the backoff bug in retry.py …', effort: 'xhigh' },
]
```

`muse_fleet.py` honours per-task `effort`, `model`, `timeout` and `max_steps`, so one fleet
can run cheap and expensive tasks side by side rather than paying the maximum for all of them.

## Mixed-engine shape that works

```
Claude (medium)   decompose ─────────────────► disjoint task list, each with a check
                                                 │
                  ┌──────────────────────────────┴─── per task, in parallel ───┐
Claude (opus)     │  spawn muse (low) ─► read patch ─► run the check ─┐        │
                  │        ▲                                          │        │
                  │        └──── revise with specific defects ◄───────┘        │
                  │                      …until accept / out of rounds         │
                  └──────────────────────────────┬────────────────────────────-┘
                                                 │
Claude (opus)     merge order, cross-task conflicts, what a human must check
```

Cheap where there is an oracle, expensive where there is a judgment. The reason to keep the
review stage on Claude is concrete rather than superstitious: in testing, a muse worker
reported `confidence: high` and a passing pytest run while having quietly built a `.venv`
to get there, and another emitted a stale first answer alongside its corrected second one.
Both were fine work. Neither self-report was sufficient on its own.

## What not to do

**Don't route decomposition to muse.** A bad partition — two tasks editing one file —
produces patches that conflict at merge, and the cost lands downstream where it is
expensive to unpick. This step is cheap and high-leverage; spend Claude on it.

**Don't skip review because muse reported success.** `completed` means the agent finished.
`confidence: high` is a claim from the model that did the work.

**Don't raise effort to fix a bad prompt.** An ambiguous prompt at `max` produces a
confidently wrong answer more slowly. Naming the files and giving an acceptance check beats
any effort setting.

**Don't set `model` on every Claude agent out of habit.** Inheriting the session model is
the documented default and is usually right; overriding everywhere mostly adds noise and
occasionally routes a hard judgment to a small model.
