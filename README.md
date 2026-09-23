# muse — a Claude Code plugin that delegates bulk coding work to Muse Code, with a supervisor that actually checks

[![muse: delegate bulk coding work from Claude Code to Muse Code workers, with a supervisor that checks every patch](https://jellologic.github.io/claude-code-muse/og.png)](https://jellologic.github.io/claude-code-muse/)

A **Claude Code plugin** that offloads repetitive coding work to cheap **Muse Code** workers,
each running in its own isolated **git worktree**. Every worker is supervised by a Claude
agent that reads the patch, **runs your acceptance check itself**, and sends the worker back
with specific defects until the work is right. Nothing is applied to your repository unless
you apply it.

[![validate](https://github.com/jellologic/claude-code-muse/actions/workflows/validate.yml/badge.svg)](https://github.com/jellologic/claude-code-muse/actions/workflows/validate.yml)
[![release](https://img.shields.io/github/v/release/jellologic/claude-code-muse?label=release)](https://github.com/jellologic/claude-code-muse/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Claude Code plugin](https://img.shields.io/badge/Claude%20Code-plugin-8A2BE2)](https://code.claude.com/docs/en/plugins)
[![good first issues](https://img.shields.io/github/issues/jellologic/claude-code-muse/good%20first%20issue?label=good%20first%20issue)](https://github.com/jellologic/claude-code-muse/labels/good%20first%20issue)

**muse types, Claude judges.** A test file per module, one migration pattern applied
repo-wide, type hints across a package, bulk lint fixes: work that is too big to do by hand
and too boring to spend your context window on. Push it to a cheap model, and spend your own
budget on the part that needs judgment.

**Website:** [jellologic.github.io/claude-code-muse](https://jellologic.github.io/claude-code-muse/)

## Contents

- [The 30 seconds that explain it](#the-30-seconds-that-explain-it)
- [Install](#install)
- [When to use it, and when not to](#when-to-use-it-and-when-not-to)
- [Why a supervisor, and not just "review it afterwards"](#why-a-supervisor-and-not-just-review-it-afterwards)
- [Commands](#commands)
- [Three rules that decide whether this works for you](#three-rules-that-decide-whether-this-works-for-you)
- [It refuses to send your credentials](#it-refuses-to-send-your-credentials)
- [Configuring it](#configuring-it)
- [Guardrails](#guardrails)
- [How it is verified](#how-it-is-verified)
- [FAQ](#faq)
- [Contributing](#contributing)
- [Docs](#docs)

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

## Install

In Claude Code:

```
/plugin marketplace add jellologic/claude-code-muse
/plugin install muse@claude-code-muse
```

Requires the Muse Code CLI (`muse`) on `PATH`, plus `git`, Python 3.9+ and Claude Code.
CI exercises Python 3.9, 3.11 and 3.13 on Linux, plus a blocking Windows Git Bash leg
(`.github/workflows/validate.yml` job "offline suite (windows)"); development is on
macOS.

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

## When to use it, and when not to

| Good fit | Poor fit |
|---|---|
| Many independent, mechanical edits: tests per module, a migration pattern, type hints, lint fixes | One coherent change that needs to be designed as a whole |
| Work you can check with a command (`pytest`, `tsc`, a linter, a grep) | Work with no runnable check; it can only be guessed at |
| Tasks that partition cleanly by file | Edits that all touch the same routing table, registry or lockfile |
| Open-source or non-sensitive code on the contributor tier | Proprietary code, unless you pin a full-rate model |

`references/routing.md` has the longer version, including when plain Claude is cheaper.

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
recorded and `/muse:status` prints it.

The supervisor does not write code. It has no `Write` or `Edit` tool, and because it still
has `Bash` (where a redirect is a write), a **PreToolUse hook enforces it**: any write,
edit or Bash command other than a muse-* shim call, read-only git, a file reader or the
task's recorded check is denied with a reason. A supervisor that could patch the worktree by hand
would, and then the next round would start from a tree muse did not produce. As a second
line, `finish` fingerprints what muse produced, compares it with what it harvests, and
reports any `out_of_band_edit`.

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

Three surfaces can fire without a slash command: (1) the `muse-fleet` skill, which
fires on its description; (2) the `muse-supervisor` agent, which the main agent can pick
through the Agent tool on its description, which now describes rather than invites —
`/muse:delegate` and the `muse-supervised-fleet` workflow spawn it by type; and (3) the
registered workflow, listed as `muse:muse-supervised-fleet`, which on an inferred trigger
must state its plan and cost and get a yes first. Called without `job`/`stamp`, or with
unsafe values, the workflow returns `{refused:true, reason}` and spawns no agent. Every
`/muse:*` command stays opt-in — and `/muse:cleanup` guessing that you meant it would
remove worktrees.

Four hook events are registered, all exec-form, and none adds model context cost unless
it speaks: **SessionStart** (`hooks/preflight.sh`) warns when delegation would fail (no
binary, no credentials, an unverified muse version), and through
`hooks/leftover_worktrees.py` names recorded muse/ and fleet/ worktrees still open with
their verdict — SessionStart stdout reaches the model;
**SubagentStop**, matcher `^muse:muse-supervisor$` (`hooks/supervisor_stop.py`), blocks a
supervisor that stops while the task it owns has no verdict, giving at most two blocks per
task before letting it go; **PostToolUse** on `Agent` (`hooks/supervisor_result.py`) tells
the orchestrator where the on-disk artifacts disagree with a returning supervisor's
summary; **PreToolUse**, matcher `Bash|Write|Edit|NotebookEdit`
(`hooks/supervisor_guard.py`), denies the muse-supervisor agent's Write/Edit/NotebookEdit
and any Bash beyond muse-* shims, read-only git, readers and the recorded check, and
prints nothing on allow.

The `muse-fleet` skill also triggers on its own when a job obviously wants fan-out — a
phrasing like *"this is a lot of grunt work"*, *"don't burn my tokens on this"*, *"farm
this out"*, or naming Muse Code directly. The explicit commands are more reliable;
natural language is the convenience path.

### What's on PATH

The plugin's `bin/` holds seven shims — `muse-ask`, `muse-cleanup`, `muse-doctor`,
`muse-fleet`, `muse-model`, `muse-status` and `muse-task` — on PATH while the plugin is
enabled. Each one execs its script under `scripts/`, so docs and grants name them bare
(`muse-task`, never `scripts/muse_task.py`).

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

Before a worker starts, the plugin scans **every file that worker could read**: tracked,
untracked and gitignored files, seeded files like the `.env` you asked it to copy, and
followed symlinks. It **refuses** on a structurally unmistakable credential: a PEM
private-key block, an AWS key id, or a GitHub, Slack, Stripe, OpenAI or Anthropic-format
token. `muse-task`, `muse-fleet` and `muse-ask` all scan, including read-only `muse-ask`,
because a read-only worker can still read a secret and send it to the contributor tier.
Contributor-tier content may be used for product improvement, and that is not undoable.

Credential-shaped assignments warn rather than block, because blocking those would make the
plugin unusable on any repo with test fixtures. Findings record file, line and kind — never
the matched text. `/muse:doctor --scan` runs the same check on demand.

See [SECURITY.md](SECURITY.md) for the full trust model, including the sharpest edge: your
acceptance check runs on the **host**, with your privileges.

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

How the values travel: Claude Code substitutes `${user_config.KEY}` into the command,
agent and skill bodies, and those pass each value as a CLI flag
(`--effort`, `--max-rounds`, `--model`, `--worktree-root`, `--refuse-on-secrets`).
The workflow gets them as args instead.
Each script then resolves flag first, then `CLAUDE_PLUGIN_OPTION_<KEY>`, then the
default — see `option_with_source` in `scripts/muse_core.py` — and refuses a
set-but-invalid value rather than falling back.
`default_effort` now carries `options` in `.claude-plugin/plugin.json`, and
`/muse:doctor` reports each value with its source.

The `muse-events` monitor reads its own config at `${CLAUDE_PLUGIN_DATA}/monitor.json`
(monitors/monitors.json passes it as --config): a JSON object with `enabled` (bool,
default true; false makes the monitor exit without notifying) and `events` (the event
kinds to deliver: `round_started`, `round_finished`, `verify`, `verdict`; default all).
A missing, unparsable or misshapen file falls back to the defaults, with one stderr
line — monitors receive no user_config, so this file is the only knob.

## Guardrails

Workers run with `--yolo`, which disables approval prompts and the sandbox. That is
defensible **only because the blast radius is a throwaway worktree on a throwaway branch.**
Never point a fleet at a dirty main working copy, keep worktrees outside the repo, and use
`--max-steps` and `--max-rounds` so a confused agent cannot loop up a bill.

For proprietary or client-confidential code, pass `--model muse-spark-1.3` and pay full
rate, or do not delegate it.

## How it is verified

This project's stated rule is *trust the measured result over what a change claims about
itself*, and it is applied to itself:

- **A free offline suite** — `bash scripts/validate.sh --offline` spawns no muse, needs no
  credentials, and runs in about a minute. CI runs it on every pull request across three
  Python versions, plus a blocking Windows Git Bash leg (`.github/workflows/validate.yml`
  job "offline suite (windows)"). The expected check count is held in the script, so a
  check that silently stops running fails the build.
- **A mutation harness** — `bash scripts/mutate.sh` plants every bug this project has ever
  fixed, one at a time, and fails if the suite stays green for any of them.
- **Real evals** — `evals/<case>/case.yaml` runs with `claude plugin eval`: cases where the
  skill must fire and cases where it must **not**, graded on behaviour as well as
  triggering. `evals/README.md` records the measured scores and vote splits.
- **Every guard is negative-controlled.** A check that inspects nothing passes exactly like
  a check that found nothing, so each one is broken on purpose and confirmed to go red.
- **End-to-end, not just unit.** `/muse:delegate` and `/muse:fleet` are exercised as real
  commands in fresh `claude -p` sessions, and the resulting patches are applied and tested
  independently.

That process has caught things reading never would: a `cleanup --artifacts` path that could
have deleted a home directory, a harvest that dropped tracked build files and then certified
an empty patch, a hook that had never fired because its matcher could not match, and plugin
options that no script ever received.

## FAQ

### How do I delegate coding tasks from Claude Code to a cheaper model?

Install this plugin, then run `/muse:delegate <task>` with the exact files and a runnable
check. A Claude supervisor hands the typing to a Muse Code worker in its own git worktree,
runs your check itself, and returns a verdict and a patch path. For many independent tasks,
`/muse:fleet <job>` plans them and runs one supervisor per task.

### What is Muse Code, and how does it compare with Claude Code?

Muse Code is a coding-agent CLI (`muse`) backed by Meta's Muse Code API, with
contributor-tier models that cost a fraction of full-rate models. This plugin drives it headlessly and treats its output as untrusted
until a check proves otherwise. It does not replace Claude Code here: muse does the typing,
and Claude Code plans, reviews and runs your check. `references/muse-cli.md` records the CLI
surface this plugin was verified against.

### Can a Claude Code subagent use a different, cheaper model?

A Claude Code subagent can run on a smaller Claude model, but it still types the code
itself. muse routes the *typing* to a different model entirely: a Muse Code worker edits in
an isolated worktree, and a Claude subagent does only the judging. It reads the patch, runs
the check, and re-prompts.

### Does it save Claude Code tokens?

It moves the typing off Claude. The Muse Code worker generates the code, and Claude spends
its tokens reviewing the patch and running the check rather than writing boilerplate. The
plugin itself adds about 625 always-on tokens.

### Does it apply patches to my repository automatically?

No. Every command stops at a verdict and a patch path. An accepted patch is still a patch you
have not read, so applying it is your call.

### Does it send my code or my secrets anywhere?

Your code goes to Muse Code, which is the point of delegating. Before any worker starts, a
credential scan refuses to send a structurally unmistakable secret. The plugin itself has no
telemetry and makes no other network calls. For proprietary code, pin a full-rate model or
do not delegate it.

### What happens if the worker gets it wrong?

The supervisor sends it back with the specific defects, up to a round cap (3 by default,
configurable). If it still is not right, the verdict is `revise` or `reject`, never a
silent `accept`.

### Does it work on Windows?

The offline test suite runs on a blocking Windows Git Bash CI leg on every pull request.
Day-to-day development and live delegation are exercised on macOS and Linux.

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

## Docs

| | |
|---|---|
| [AGENTS.md](AGENTS.md) | For AI agents: how to contribute here |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Dev loop, house rules, the live suite, releasing |
| [SECURITY.md](SECURITY.md) | Trust model, `--yolo`, host-side checks, credentials |
| [CHANGELOG.md](CHANGELOG.md) | What changed |
| `references/workflow.md` | Why the fleet workflow is shaped that way, and embedding muse in your own |
| `workflows/muse-supervised-fleet.js` | The registered workflow itself — `Workflow({ name: "muse-supervised-fleet" })` |
| `references/muse-cli.md` | The verified `muse` CLI surface and event schema |
| `references/routing.md` | When to use muse and when to use Claude |
| `references/field-notes.md` | Platform facts measured along the way, and what other teams learned running agent fleets |
| `evals/README.md` | The eval cases, how to run them, and measured scores |

## License

MIT — see [LICENSE](LICENSE).
