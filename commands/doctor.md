---
description: Report whether this machine can delegate to muse, what model it would use, and what would go wrong
argument-hint: [--scan] [--repo <path>]
disable-model-invocation: true
allowed-tools: Bash(python3:*), Read
model: haiku
---

# Can this machine delegate?

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/muse_doctor.py" [--repo <path>] [--scan] [--json]
```

Checks the muse binary and version, stored credentials (existence only, never contents),
the model catalog and what it resolves to, the interactive model pin, Python and git, the
plugin's own scripts, the repo's git state, and the worktree root. Exits non-zero if
anything is blocking, so it can gate a script.

`--scan` adds a credential scan of the repo. It is slower on a large tree, which is why
it is opt-in here — but run it before a first delegation from an unfamiliar repo.

## Reading the output

Three severities, and the distinction is the whole point:

- **FAIL** — delegation cannot work until it is fixed. Every FAIL line carries its own fix.
- **WARN** — it will work, but not the way you probably expect. A stale catalog means a
  pinned model instead of the newest; a dirty tree means both drivers will refuse.
- **OK** — checked, *with the value shown*. "muse-spark-1.3-contributor (released
  2026-09-02)" is a different claim from "present".

Report the FAIL lines first with their fixes, then the WARNs. Do not paraphrase a value
into "fine" — the resolved model id and the catalog age are the two things people are
usually surprised by, so quote them.

If it reports NOT READY, fix that before delegating rather than letting a fan-out
discover the same problem N times in parallel.

## When to reach for this

- A `/muse:*` command failed and the reason was not obvious
- First use on a new machine, or after reinstalling muse
- Before a large fan-out, where one missing credential wastes every task at once
- The SessionStart hook reported a problem and you want the full picture
