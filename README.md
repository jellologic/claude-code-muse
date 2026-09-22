# muse — delegate bulk coding work from Claude Code, with a supervisor that actually checks

A **Claude Code plugin** that offloads repetitive coding work to **Muse Code** workers
running in isolated **git worktrees** — each one supervised by a Claude agent that reads
the patch, **runs your acceptance check itself**, and sends the worker back with specific
defects until the work is right.

[![validate](https://github.com/jellologic/claude-code-muse/actions/workflows/validate.yml/badge.svg)](https://github.com/jellologic/claude-code-muse/actions/workflows/validate.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Claude Code plugin](https://img.shields.io/badge/Claude%20Code-plugin-8A2BE2)](https://docs.claude.com/en/docs/claude-code/plugins)
[![good first issues](https://img.shields.io/github/issues/jellologic/claude-code-muse/good%20first%20issue?label=good%20first%20issue)](https://github.com/jellologic/claude-code-muse/labels/good%20first%20issue)

**muse types, Claude judges.** A test file per module, one migration pattern applied
repo-wide, type hints across a package, bulk lint fixes — work that is too big to do by
hand and too boring to spend your context window on. Push it to a cheap model, and spend
your own budget on the part that needs judgment.

---

## The 30 seconds that explain it

```
/muse:delegate Create tests/test_ratio.py covering percent() in ratio.py.
               Do not modify ratio.py. Check: python3 -m pytest tests/test_ratio.py -q
```

A supervisor spawns a worker in its own worktree, reads the patch, runs `pytest` **itself**,
and comes back:

> **Verdict: accept** — 1 round of 3. The supervisor ran the check itself and it passed.
> **Check:** `python3 -m pytest tests/test_ratio.py -q` → exit 0, `3 passed, 1 xfailed`.
> **Flagged:** the strict xfail is a tripwire by design — whoever fixes `slugify` gets an
> XPASS *failure* and has to delete the marker in the same commit.
> *Patch not applied — your call.*

That is real output. The worker was asked to test a function whose docstring and
implementation disagree; it asserted the **documented** behaviour, found the bug, and
encoded it as `xfail(strict=True)` so the suite passes honestly while the bug stays
recorded. The supervisor then verified with `-rxX` that the xfail was a genuine assertion
failure rather than a collection error in disguise.

Nothing was applied to the repository. That is the default.

## Why a supervisor, and not just "review it afterwards"

Cheap delegation fails in exactly one place: **a model grading its own homework.**

A reviewer that can only file a report is strictly weaker than one that can re-prompt the
author in the round where fixing is still cheap. So the grading moves *into* the agent that
owns the task, and the cheap model's last word is never the deliverable.

```
          ┌────────────── one supervisor, one task ──────────────┐
 plan ──▶ │  muse run ──▶ read patch ──▶ verify ──▶ revise ──▶ … │ ──▶ integrate
          │       ▲                                   │          │
          │       └───────────── until right ─────────┘          │
          └──────────────────────────────────────────────────────┘
```

Two words that are not interchangeable, and the whole design rests on the gap between them:

| | means |
|---|---|
| `completed` | the worker stopped |
| `accept` | a supervisor ran a check and the **final** one passed |

`finish --verdict accept` **refuses** unless the final check passed *and* ran against the
tree being harvested — so a green check from before something touched the worktree does not
certify the patch that ships. `--accept-unverified "<reason>"` is the deliberate way past
it, for the case where a correct patch makes a check legitimately go red; the reason is
recorded and `/muse:status` prints it. The supervisor agent has **no `Write` or `Edit` tool** — not an oversight. A
supervisor that can patch the worktree by hand will, and then the next round starts from a
tree muse did not produce. That removal is a strong default, not a boundary: the supervisor
still has `Bash`, and a shell redirect is a write. So the delta is **measured** rather than
assumed away — `finish` fingerprints what muse produced, compares it with what it harvests,
and reports `out_of_band_edit` with the acceptance checks that account for it. Claiming the
toolset enforced this would be the more comfortable sentence and the false one.

## Install

```
/plugin marketplace add jellologic/claude-code-muse
/plugin install muse@claude-code-muse
```

Requires the Muse Code CLI (`muse`) on `PATH`, plus `git`, Python 3.9+ and Claude Code.
CI exercises Python 3.9, 3.11 and 3.13 on Linux; development is on macOS.

**Then start a new session** (or `/clear`). Plugin commands, skills and agents register at
session start, so `/muse:*` will not exist in the session you installed from. This is the
first thing everyone hits.

Then `muse login` once. Not sure it's set up right?

```
/muse:doctor
```

…reports the muse version, whether credentials exist, how fresh the model catalog is,
**which model would actually be used**, your repo's git state and whether the worktree
root is writable — with a fix on every failing line.

## Commands

| Command | Does |
|---|---|
| `/muse:delegate <task>` | One task, supervised end to end — run, verify, revise, verdict |
| `/muse:fleet <job>` | Decompose a job and fan out, one supervisor per task |
| `/muse:ask <question>` | One question or one contained edit, no worktree, answer on stdout |
| `/muse:status` | What every task did, and whether a check actually ran |
| `/muse:doctor` | Whether this machine can delegate, and what would break |
| `/muse:model` | Which contributor model delegation will use |
| `/muse:cleanup` | Reap worktrees, branches and artifacts a run left behind |

Only the `muse-fleet` skill fires on its own; every `/muse:*` command is opt-in, because
one carefully-scoped auto-triggering surface beats eight competing for the same prompts —
and `/muse:cleanup` guessing that you meant it would remove worktrees.

Three hooks, all silent unless they have something to say: **SessionStart** warns when
delegation would fail (no binary, no credentials, a muse version this plugin has not been
verified against), **SubagentStop** reports what a finished task's artifacts say where
they disagree with the supervisor's summary, and **SessionEnd** names delegation
worktrees still holding unapplied patches.

The `muse-fleet` skill also triggers on its own when a job obviously wants fan-out — a
phrasing like *"this is a lot of grunt work"*, *"don't burn my tokens on this"*, *"farm
this out"*, or naming Muse Code directly. The explicit commands are more reliable;
natural language is the convenience path.

### Writing a delegation that comes back right

The worker sees your brief and the repo, and **cannot ask a question** — ambiguity does
not come back as a question, it comes back as confidently wrong work. Three things decide
the outcome:

1. **Name the exact files.** "Add tests for auth" invites a rewrite of `auth.py`;
   "create `tests/test_auth.py`, do not modify `auth.py`" does not.
2. **Give a runnable acceptance check.** The highest-leverage part of the whole prompt —
   it is what the supervisor executes itself instead of trusting the worker.
3. **Say what must not change.** The boundary matters as much as the goal.

Your working tree must be **clean**: worktrees branch from a committed ref, so
uncommitted work is invisible to the worker and its absence looks like the agent deleted
it.

For a quick question, `/muse:ask` needs none of that — and `--continue` resumes the last
conversation from that repo, so a follow-up costs one sentence instead of a re-explanation.

**No command applies a patch.** They stop at a verdict and a patch path, because an
accepted patch is still a patch you have not read.

## Three rules that decide whether this works for you

**Partition by file.** Worktrees isolate agents from each other's *process*, not from each
other's *intentions*. Two agents editing `calc.py` each produce a clean patch, and those
patches conflict at merge. Watch for conflict magnets: routing tables, config, registries,
DI containers, lockfiles, barrel exports, migration directories.

**Every task needs a runnable check.** The supervisor's leverage is an executable oracle.
A task with no check cannot be supervised, only guessed at — say so up front and review
that patch by hand rather than inventing a check that always passes.

**Seed what git does not track.** A worktree is a clean checkout, so `.env`, `node_modules`
and `.venv` are missing. This fails quietly: the worker cannot run the check, so it reports
a success it never verified.

## It refuses to send your credentials

Before spawning a worker, `run` scans the worktree — after seeding, so it sees the `.env`
you asked it to copy — and **refuses** on a structurally unmistakable credential: a PEM
private-key block, an AWS key id, a GitHub/Slack/Stripe/Anthropic-format token.
Contributor-tier content may be used for training, and that is not undoable.

Credential-shaped assignments warn rather than block, because blocking those would make the
plugin unusable on any repo with test fixtures. Findings record file, line and kind — never
the matched text. `/muse:doctor --scan` runs the same check on demand.

See [SECURITY.md](SECURITY.md) for the full trust model, including the sharpest edge: your
acceptance check runs on the **host**, with your privileges.

## How it is verified

This project's stated rule is *trust the measured result over what a change claims about
itself*, and it is applied to itself:

- **A free offline suite** — `bash scripts/validate.sh --offline` spawns no muse, needs no
  credentials, and runs in seconds. CI runs it on every pull request across three Python
  versions.
- **A paid live suite** — the full `bash scripts/validate.sh` drives real muse runs through
  the fleet, the supervised loop, seeding, re-run safety and session resume.
- **Every guard is negative-controlled.** A check that inspects nothing passes exactly like
  a check that found nothing, so each one is broken on purpose and confirmed to go red.
- **End-to-end, not just unit.** `/muse:delegate` and `/muse:fleet` are exercised as real
  commands in fresh sessions, and the resulting patches are applied and tested independently.

That process has caught things reading never would: a `cleanup --artifacts` path that could
have deleted a home directory, a harvest that overwrote good patches with empty files on a
git failure, a `--timeout` that killed a shell while the real worker ran on unbounded, and a
documented safety control that did not exist.

## Contributing

**Issues and pull requests are welcome, including from AI agents.**

- 🤖 **If you are an AI coding agent, start with [AGENTS.md](AGENTS.md)** — how to reach a
  verified state in 60 seconds, where to find work, and the five rules that decide whether a
  PR gets merged.
- 👤 Humans: [CONTRIBUTING.md](CONTRIBUTING.md) covers the dev loop and house rules.
- 🔎 Looking for something to do? Try
  [`good first issue`](https://github.com/jellologic/claude-code-muse/labels/good%20first%20issue),
  [`help wanted`](https://github.com/jellologic/claude-code-muse/labels/help%20wanted), or
  [`agent-friendly`](https://github.com/jellologic/claude-code-muse/labels/agent-friendly)
  — issues self-contained enough to finish from the issue text plus this repo, each with a
  runnable acceptance check already named.

Two contributions that are always valuable and need no permission:

1. **Make a guard fail.** Every check in `scripts/validate.sh` claims to catch something.
   Break the thing it watches. If it stays green, that is a real bug and a great issue.
2. **Find a doc that lies.** Any statement that does not match the code is a defect here.
   Two have already been found this way, both in this repo's own documentation.

```bash
git clone https://github.com/jellologic/claude-code-muse.git
cd claude-code-muse
bash scripts/validate.sh --offline     # free, seconds, no credentials needed
```

## Configuring it

`/plugin install` prompts for five values, each with a default that is exactly what the
plugin did before there was any configuration — skip every prompt and nothing changes.

| | |
|---|---|
| **Default reasoning effort** | `low`. Raise it and every task costs more; lower it and more tasks need a revision round. |
| **Maximum rounds per task** | `3`, bounded 1–10. The runaway-cost breaker. |
| **Worktree root** | empty, meaning beside the repository. A path *inside* the repo removes the isolation that makes `--yolo` defensible. |
| **Refuse on a credential** | on. Turn it off only where the credential-shaped content is entirely test fixtures. |
| **Model** | `latest-contributor`, resolved from muse's catalog at run time. Pin `muse-spark-1.3` for proprietary code. |

Every flag still overrides the configured value for one run.

## Guardrails

Workers run with `--yolo`, which disables approval prompts and the sandbox. That is
defensible **only because the blast radius is a throwaway worktree on a throwaway branch.**
Never point a fleet at a dirty main working copy, keep worktrees outside the repo, and use
`--max-steps` and `--max-rounds` so a confused agent cannot loop up a bill.

For proprietary or client-confidential code, pass `--model muse-spark-1.3` and pay full
rate, or do not delegate it.

## Docs

| | |
|---|---|
| [AGENTS.md](AGENTS.md) | For AI agents: how to contribute here |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Dev loop, house rules, the live suite |
| [SECURITY.md](SECURITY.md) | Trust model, `--yolo`, host-side checks, credentials |
| [CHANGELOG.md](CHANGELOG.md) | What changed |
| `references/workflow.md` | Why the fleet workflow is shaped that way, and embedding muse in your own |
| `workflows/muse-supervised-fleet.js` | The registered workflow itself — `Workflow({ name: "muse-supervised-fleet" })` |
| `references/muse-cli.md` | The verified `muse` CLI surface and event schema |
| `references/routing.md` | When to use muse and when to use Claude |
| `references/field-notes.md` | What other teams learned running agent fleets |
| `evals/evals.json` | Skill-triggering cases: five that must fire, four that must **not** |

## License

MIT — see [LICENSE](LICENSE).
