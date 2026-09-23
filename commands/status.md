---
description: Report what every delegated muse task did — rounds, verdict, patch size, and whether a check actually ran
argument-hint: "[--out <artifact-root>]"
disable-model-invocation: true
allowed-tools: Bash(muse-status:*), Read
model: haiku
---

# Delegated task status

Report on the muse tasks in this repo.

```bash
muse-status [--out <root>] [--json]
```

Defaults to scanning `.muse-fleet`. Pass `--out` when the user named a different artifact
root; pass `--json` if you need to compute over the results rather than relay them.

## What to lead with

The script separates two things that get conflated, and your summary must keep them apart:

- **`completed` / `finished`** — the worker stopped, or a verdict was written. Bookkeeping.
- **`verified`** — a supervisor ran the acceptance command itself and the exit code was
  recorded. Evidence.

Two flags matter most, and both mean the same thing for the reader — the patch is
unproven. `ACCEPTED WITHOUT AN EXECUTED CHECK` means nothing ran.
`ACCEPTED WITHOUT A PASSING FINAL CHECK` is worse: a check ran and went red, and the task
was accepted anyway. Name either one first. It means
somebody said the patch was fine and nothing ran to confirm it — treat that patch as unproven
and say so in those words, whatever its verdict field claims.

Then surface, in order: tasks out of rounds with no verdict, non-zero last-check exit codes,
empty patches (the worker decided nothing needed doing — sometimes right, more often a misread
prompt), oversized patches (nearly always build artifacts the excludes did not anticipate, so
read the file list before concluding the change is big), and any residual concerns a
supervisor recorded.

If everything is clean, say so in one line with the patch paths, and offer the apply command
rather than running it:

```bash
git apply --check <patch> && git apply --3way <patch>
```

If the artifact root does not exist, nothing has been delegated from this repo yet. Say that
and stop — do not go hunting for other roots.
