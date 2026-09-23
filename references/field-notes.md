# Field notes: what practitioners learned running parallel coding agents

Lessons from teams running fleets of coding agents in 2025–2026, plus what they imply for
this skill. Sources at the bottom. Where a claim is contested or thinly evidenced, it says so.

## The consensus that has formed

Independently, almost everyone arrived at the same three things:

1. **Worktree-per-agent (or container-per-agent) is the isolation primitive.** Not a
   preference — a correctness requirement. Two agents in one checkout editing `src/lib.rs`
   produced *silent data loss*: agent B's write overwrote agent A's additions with no
   conflict marker and no error. Worktrees convert that invisible loss into a visible merge
   conflict you can resolve deliberately.
2. **Decomposition matters more than agent count.** "More agents without more structure
   equals more chaos."
3. **Verification, not generation, is the bottleneck.** Agents produce diffs faster than
   humans read them.

This skill already implements (1). The rest of this file is mostly about (2) and (3).

## Decomposition: the failure that keeps recurring

The canonical disaster, reported almost verbatim by several teams: **"Refactor the backend"
given to three agents.** One moved to async handlers, one restructured error types, one
renamed half the functions. Three coherent patches, mutually incompatible, nothing merged.
That is 5x the mess, not 5x the output.

The fix is unglamorous: tasks must be *independent, specific and testable*. "Add JWT
validation middleware to the auth route" is a task; "improve the backend" is a prompt for
three different projects. One practitioner's estimate — 20 minutes of precise task writing
saves hours of conflict resolution — matches the structure of the problem, since conflicts
surface at merge time when context is gone.

**Conflict magnets.** Disjoint *feature* boundaries are not enough, because certain files
are touched by nearly every feature: routing tables, config files, component registries,
dependency manifests and lockfiles, DI containers, `__init__.py`/barrel exports, migration
directories. Partition by these files explicitly, or assign one task ownership of the
registry and have the others leave it alone.

There is a deeper version of this argument worth knowing: recurring merge conflicts are
evidence of **architectural misalignment**, not a tooling problem. God classes and
technical-layer (MVC-style) rather than domain-driven separation force unrelated features
into the same files, so agents collide wherever the architecture already made humans
collide — just faster. That framing is argued from anecdote rather than measurement, so
treat it as a useful lens rather than a finding. The practical read: if a repo cannot absorb
parallel change, fan-out will expose that, and the fix is in the codebase, not the fleet.

## How many agents

**3–5 is the reported sweet spot.** 2–3 is comfortable for one person supervising; beyond
~5, merge complexity and the codebase's capacity to absorb parallel change become the
limit, not the tooling. Anthropic's own research system spins up 3–5 subagents per query.
This skill defaults to concurrency 3 for that reason, not an arbitrary one.

## Verification is the real constraint

The bottleneck insight is the most important one here, and the one most likely to be
ignored because it is not fun: **if you cannot review at the rate agents produce, parallel
agents buy you a review backlog and under-reviewed code shipped under time pressure.**
Throughput gains are capped by review bandwidth, so the only way to actually go faster is
to make automation filter most regressions before a human sees a diff.

The single highest-leverage gate reported: **run the test suite and check the exit code.**
Zero means mergeable; non-zero hands the failure output back to the agent to retry. One
team put the failure-rate reduction at roughly 80%, with the residue attributable to thin
test coverage rather than agent capability. That is a self-reported number from one team,
not a measurement you should quote as fact — but the mechanism is sound and cheap, and it
is why every task prompt in this skill is supposed to carry an executable acceptance check.

The related failure: **agents declare completion on plausibility, not correctness.** One
committed code that looked right, broke a shared interface, and cascaded test failures
across other branches. This matches what testing this skill turned up directly — a worker
reporting `confidence: high` and a passing pytest run, having quietly built a `.venv` to
get there. Neither was dishonest. Both were insufficient as evidence.

## Supervision, not fire-and-forget

Of three agents run unattended, one pursued a wrong approach for an hour, one entered a
retry loop, and one succeeded. The honest framing of the leverage: *"I supervise five
workstreams instead of doing one task myself"* — not *"I do nothing."* Budget attention for
course-correction, and cap runaway cost structurally (`--max-steps`, per-task timeouts)
rather than by watching.

## Dispatch and duplication

Told to "work on the backlog," two agents picked the same feature and one agent's work was
wasted. Teams converged on a kanban file — Todo / In Progress / Done, one task per agent,
plain Markdown so `cat` and `git diff` work. This skill sidesteps the problem by assigning
tasks explicitly up front; it becomes relevant if you move to long-lived workers pulling
from a queue.

## Environment isolation — the gap that bites

A worktree is a *clean checkout*. Everything git does not track is absent: `.env`,
`node_modules`, `.venv`, local certs, `.envrc`. Verified directly — a repo with `.env` and
`node_modules` produced a worktree with neither.

Consequences, in order of how quietly they fail:

- The agent cannot run the verification command, so it reports success it never checked.
- The agent *rebuilds* what it thinks is missing — this is exactly where a stray `.venv`
  and a 14MB patch came from in testing here.
- Config-dependent code paths are untestable, so bugs in them survive.

Practitioner guidance, which this skill implements as `--seed` and `--link`: **copy** small
config (`.env`) so each agent gets its own and cannot contaminate the original, and
**symlink** heavy directories to avoid N installs — but only where nothing writes to them,
since concurrent installs into one shared `node_modules` corrupt it. Also assign distinct
ports per agent if they start dev servers.

## Heterogeneous fleets

Teams do route different CLIs by task type — Codex for complex backend work, Claude Code
for iteration, Gemini for UI polish — with each agent in its own worktree on its own branch
and a tmux session per agent. This is the same shape as routing between muse and Claude,
and it validates the core bet: the orchestrator holds context and writes specialised
prompts; the workers are interchangeable executors chosen per task.

The multi-model review variant is also worth noting: several reviewers independently assess
each PR before a human looks. That is cheap when the reviewers are cheap.

## Anthropic's orchestrator–worker findings

From the research system (a different domain — breadth-first search, not code — so port the
structure, not the numbers):

- Lead agent plans, 3–5 subagents run in parallel, a **separate pass** verifies high-stakes
  output (citations there; patch review here).
- **~15x the tokens of a chat interaction**, and token usage alone explains ~80% of
  performance variance. Multi-agent is expensive by construction.
- *"Architecture follows task structure. Multi-agent only wins when the task decomposes
  into independent parallel threads."*

Three portable patterns they call out, all of which this skill uses: externalise state
before context fills (patches and `report.json` on disk), isolate workers with
**self-contained task descriptions**, and verify high-stakes output in a separate pass.

The 15x figure is the strongest argument for the cheap-worker bet. If fan-out inherently
multiplies token spend, the cost per worker token is what decides whether it is worth doing
— which is the whole reason to put muse on the bulk work and reserve Claude for judgment.
A related warning circulating as "3 agents cost 10x" points the same way, though I have not
verified its methodology.

## Reaching the scripts: bin/ shims, not an MCP server

The considered alternative was a plugin MCP server exposing task_run/verify/finish as
typed tools: schema-validated args, no shell, and tools grantable by name. That shape
would have removed a whole class of quoting and environment failures at once.

Why bin/ won: the MCP server costs a long-running process and a larger rewrite. The
shims fix the quoting and environment failures now — the old recipe stored a quoted
interpreter-plus-script-path in a shell variable and re-expanded it at each call site,
which broke on word-splitting and did not survive between Bash tool calls — make grants
like Bash(muse-task:*) a real restriction, and run the same command in a workflow agent,
a supervisor and a human terminal. The MCP server stays the route if Bash itself should
be removed from the supervisor.

## What this changed in the skill

- `--seed` / `--link` for untracked local files, plus a preflight warning naming files that
  exist in the repo but will be absent from worktrees.
- Named conflict magnets in the decomposition guidance, beyond "disjoint files."
- Concurrency default of 3, justified rather than arbitrary.
- Emphasis that an executable acceptance check in each prompt is the load-bearing quality
  gate, not a nicety.

## Sources

- [5 Lessons from Running AI Coding Agents in Parallel](https://dev.to/battyterm/5-lessons-from-running-ai-coding-agents-in-parallel-53on)
- [Parallel Agentic Development With Git Worktrees: A Practical Playbook](https://www.mindstudio.ai/blog/parallel-agentic-development-git-worktrees)
- [Why Merge Conflicts became the new Agentic Bottleneck](https://adamtornhill.substack.com/p/why-merge-conflicts-became-the-new)
- [How I Orchestrate Claude Code, Codex, and Gemini CLI as a Swarm](https://dev.to/elophanto/how-i-orchestrate-claude-code-codex-and-gemini-cli-as-a-swarm-4p3c)
- [How Anthropic Built a Multi-Agent Research System](https://blog.bytebytego.com/p/how-anthropic-built-a-multi-agent)
- [Multi-Agent Cost Compounding](https://www.augmentcode.com/guides/multi-agent-cost-compounding)
- [When Multi-Agent Is Overkill](https://www.augmentcode.com/guides/when-multi-agent-ai-is-overkill)
- [The Best Tools to Run Multiple Claude Code Agents](https://munderdiffl.in/blog/best-claude-code-multi-agent-tools/)
