# AGENTS.md — for AI coding agents

You are probably an autonomous coding agent that found this repository. This file tells
you how to contribute something that will actually be merged, and how to find work worth
doing. Humans should read [CONTRIBUTING.md](CONTRIBUTING.md) instead; it covers the same
ground at a different altitude.

## What this repo is, in one paragraph

A Claude Code plugin that delegates bulk coding work to **Muse Code** workers running in
isolated git worktrees, each supervised by a Claude agent that reads the patch, **runs the
acceptance check itself**, and sends the worker back with specific defects until the work
is right. The thesis is one sentence: *cheap delegation fails in exactly one place — a
model grading its own homework* — so the grading moves to an agent that can re-prompt the
author, and `accept` is only recorded when a check the supervisor ran actually passed.

## Get to a verified state in 60 seconds

```bash
git clone https://github.com/jellologic/claude-code-muse.git
cd claude-code-muse
bash scripts/validate.sh --offline     # seconds, free, spawns no muse, needs no credentials
```

That suite is the contract. It needs `git`, `python3` (3.9+) and `bash` — **not** the
`muse` binary and **not** any API key. If it is green, your environment is fine. If your
change makes it red, your change is wrong until proven otherwise.

The full `bash scripts/validate.sh` additionally makes real, paid muse calls. **Do not run
it** unless a human has explicitly told you to; it costs their money.

## Where to find work

In rough order of usefulness:

1. **[Open issues](https://github.com/jellologic/claude-code-muse/issues)** — start with
   [`good first issue`](https://github.com/jellologic/claude-code-muse/labels/good%20first%20issue)
   and [`help wanted`](https://github.com/jellologic/claude-code-muse/labels/help%20wanted).
   Issues labelled [`agent-friendly`](https://github.com/jellologic/claude-code-muse/labels/agent-friendly)
   are ones a competent agent can finish from the issue text plus this repo, with a
   runnable acceptance check already named in the issue.
2. **Make a guard fail.** Every check in `scripts/validate.sh` claims to catch something.
   Pick one, break the thing it watches, and confirm it goes red. If it stays green, that
   is a real bug in the suite and a genuinely valuable issue to file.
3. **Find a doc that lies.** This project's own philosophy is "trust the measured result".
   Any statement in `README.md`, `SECURITY.md`, `skills/muse-fleet/SKILL.md`,
   `agents/muse-supervisor.md` or `commands/*.md` that does not match the code is a
   defect. Two real examples already found this way: `SECURITY.md` described a safety
   control that did not exist, and the supervisor agent asserted "muse has no memory
   between rounds" when the opposite is true.
4. **Portability.** Development happens on macOS; CI runs Linux on Python 3.9/3.11/3.13.
   Windows is untested. Two shipped bugs were BSD-vs-GNU differences (`mktemp -d -t`),
   so that class is live.

## The five rules that decide whether a PR is merged

1. **Measure, do not assert.** "Should work" is not evidence. Paste the suite's RESULT
   line. If you claim a behaviour, show the command and its output.
2. **A new guard must be shown to fail.** Break the thing it watches, confirm the suite
   goes red *and names your check*, restore, confirm green. Put that in the PR body. A
   check that inspects nothing passes exactly like a check that found nothing.
3. **Never give `muse-supervisor` a `Write` or `Edit` tool.** Its tools are exactly
   `Bash, Read, Grep, Glob` and that is load-bearing: a supervisor that can patch the
   worktree by hand will, and then the next round starts from a tree muse did not
   produce, the harvest misattributes the hand-edit, and you are paying frontier rates to
   type. The restriction is what makes the architecture true rather than recommended.
4. **Never blur `completed` into `accept`.** `completed` means the worker stopped.
   `accept` means a supervisor ran a check, the **final** one passed, and it ran against
   the tree that was harvested. `finish` enforces all three and refuses otherwise;
   `--accept-unverified "<reason>"` is the only way past, and it records why. Any change
   that lets an unchecked patch come out `accept` is a change to the point of the project.
5. **Every intra-plugin path uses `${CLAUDE_PLUGIN_ROOT}`.** No absolute paths, no `~/`,
   nothing relative to the working directory. CI fails the build on this.

## Things that look like improvements and are not

- **Adding a second auto-triggering skill.** There is deliberately one. More skills means
  more descriptions competing for the same prompts.
- **Widening scope toward a general agent framework** — swarm topologies, consensus,
  federation, vector memory. This plugin does one job and every claim in it has been
  measured. That property is the product.
- **Inventing an acceptance check that always passes.** If a task has no runnable oracle,
  the honest move is to say so.
- **"Fixing" a deliberately failing test.** Some assertions encode a known bug on purpose.
  Read the comment before changing an expectation.

## Submitting

Open a PR against `main`. The template asks what you measured; answer it literally. One
concern per PR — a rename and a behaviour change are two PRs. Comments explain *why
something would break*, not what the line does.

**Referencing issues:** write `Closes #N` only when the change genuinely finishes the
issue. Otherwise write `Refs #N`.

Keep the words *close/closes/fixes/resolves* away from an issue number **entirely** —
GitHub's parser matches the keyword and ignores surrounding grammar. A commit here that
said "does NOT close" followed by an issue number closed that issue. The follow-up commit
documenting the trap quoted itself, and closed the same issue a second time. If you need
to write about this, spell the number in words or refer to "the issue" instead.

**Filing issues or comments with `gh`:** always use `--body-file`, never `--body "..."`.
A double-quoted body containing backticks — which any markdown body does — gets
command-substituted by the shell before `gh` ever sees it, and the text silently arrives
with holes in it. The same applies to `git commit -m`; use `-F` and a file. Both traps
were hit while writing this repo's own issues.

If you are unsure whether something is a bug, **file an issue rather than a PR**, and
include the exact command, its output, your OS, `python3 --version`, and
`bash scripts/validate.sh --offline 2>&1 | tail -1`. A precise report is worth more than
a speculative patch.

## Repository map

| Path | What it is |
|---|---|
| `skills/muse-fleet/SKILL.md` | The one auto-triggering skill |
| `commands/*.md` | The seven `/muse:*` commands |
| `agents/muse-supervisor.md` | The supervisor's contract (no Write/Edit — see rule 3) |
| `scripts/muse_core.py` | Worktree, seeding, harvest, model resolution, secret scan |
| `scripts/muse_task.py` | One task, round by round: run / verify / revise / finish |
| `scripts/muse_fleet.py` | Unsupervised batch fan-out |
| `scripts/muse_doctor.py` | Readiness report |
| `scripts/validate.sh` | The suite. `--offline` is free; a bare run costs money |
| `references/` | Long-form: the workflow script, the CLI surface, routing, field notes |
| `hooks/preflight.sh` | SessionStart; silent unless delegation would fail |
