---
description: Ask Muse Code one question, or have it make one contained edit — no worktree, answer on stdout
argument-hint: "[--write] [--effort low|medium|xhigh] <question or edit>"
disable-model-invocation: true
allowed-tools: Bash, Read
---

# One question for muse

Run `$ARGUMENTS` through a single muse call and report what comes back. This is the cheap
primitive: no worktree, no supervisor, no rounds. Use it for an inventory, a summary, an
explanation, or one small contained edit — anything where the orchestration of
`/muse:delegate` would cost more than the task.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/muse_ask.sh" [--effort <e>] [--write] [--schema <file>] \
  [--continue | --session <id>] "<prompt>"
```

Read-only by default: workspace writes are disabled and the sandbox stays on, which makes
it a strong default against a dirty working copy rather than a guarantee — muse can still
write through the shell. Point it at a worktree if that distinction matters. It exits 0 and prints the final answer, or exits 1 and prints the
reason to stderr. The model is resolved to the newest contributor tier at run time.

## Reading the request

- Default `--effort low`. Raise to `medium` for something needing local design judgment, or
  `xhigh` for one genuinely hard analysis question. Effort is a difficulty dial, not a speed
  dial — muse latency is dominated by service contention, and the same trivial prompt has
  taken 15s and 216s. Keep timeouts generous and do not read a slow run as a stuck one.
- Pass `--write` **only** if the user clearly asked for an edit. It disables the sandbox and
  lets muse modify the working tree in place, with no worktree isolation and no supervisor
  checking the result. Before using it, confirm the tree is clean enough that the user could
  undo the change with `git checkout`, and say that is what you are about to do.
- For a task that deserves isolation, verification and revision rounds, stop and use
  `/muse:delegate` instead. The boundary is whether a wrong answer costs anything.

## Following up

`--continue` resumes the last conversation from this repo, so a follow-up needs only the
new question:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/muse_ask.sh" "Summarise what retry.py does"
# stderr: muse_ask: session 7f3a...
"${CLAUDE_PLUGIN_ROOT}/scripts/muse_ask.sh" --continue "Now list everything that calls it"
```

The id is remembered per repo under `${CLAUDE_PLUGIN_DATA}` — that directory is shared
across every repo, so it is keyed by path and one project's conversation never reaches
another. `--session <uuid>` still names one explicitly, which is what you want for two
threads in the same repo; every run prints its id on stderr for that.

Use `--continue` for the user's follow-ups on the same topic rather than re-explaining the
context. Drop it when the subject changes — a long session carries irrelevant context and
costs tokens to re-read.

## Reporting

Relay the answer. If the prompt asked muse to inspect the repo, treat the reply as a claim
to spot-check rather than a finding to repeat — it is a cheap model reading code without
supervision, which is exactly the setup this plugin does not otherwise trust. A quick
`grep` against one or two of its assertions is usually enough to tell a real answer from a
plausible one.

If it exits non-zero, show the stderr reason rather than retrying blind. A failure here is
almost always missing credentials, a missing binary, or a prompt muse refused — none of
which a second identical attempt fixes.
