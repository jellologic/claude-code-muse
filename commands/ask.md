---
description: Ask Muse Code one question, or have it make one contained edit — no worktree, answer on stdout
argument-hint: [--write] [--effort low|medium|xhigh] <question or edit>
allowed-tools: Bash, Read
---

# One question for muse

Run `$ARGUMENTS` through a single muse call and report what comes back. This is the cheap
primitive: no worktree, no supervisor, no rounds. Use it for an inventory, a summary, an
explanation, or one small contained edit — anything where the orchestration of
`/muse:delegate` would cost more than the task.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/muse_ask.sh" [--effort <e>] [--write] [--schema <file>] "<prompt>"
```

Read-only by default: writes are disabled and the sandbox stays on, so it is safe to point
at a dirty working copy. It exits 0 and prints the final answer, or exits 1 and prints the
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

## Reporting

Relay the answer. If the prompt asked muse to inspect the repo, treat the reply as a claim
to spot-check rather than a finding to repeat — it is a cheap model reading code without
supervision, which is exactly the setup this plugin does not otherwise trust. A quick
`grep` against one or two of its assertions is usually enough to tell a real answer from a
plausible one.

If it exits non-zero, show the stderr reason rather than retrying blind. A failure here is
almost always missing credentials, a missing binary, or a prompt muse refused — none of
which a second identical attempt fixes.
