---
description: Show which Muse Code model delegation will use, and optionally update the interactive pin
argument-hint: [--write]
allowed-tools: Bash, Read
---

# Which muse model is in play

There are two answers and they drift apart, which is the reason this command exists.

**Delegated runs** resolve the model at run time. `muse_core.resolve_model` reads muse's live
catalog, keeps visible models whose id ends in `-contributor`, and picks the newest by
`release_date` — so a future `muse-spark-1.5-contributor` gets used the day it lands with no
edit anywhere. Show what that resolves to right now:

```bash
python3 -c "
import importlib.util, os
spec = importlib.util.spec_from_file_location('c', os.path.join(os.environ['CLAUDE_PLUGIN_ROOT'], 'scripts/muse_core.py'))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print('%s  (%s)' % m.resolve_model(m.LATEST))
"
```

A result of `fallback (no catalog found)` means the catalog is missing and runs will use a
hardcoded id that goes stale — run any `muse exec` once to populate it.

**Interactive `muse` sessions** ignore all of that and read `~/.config/muse/settings.json`.
A hand-written pin there is how a machine ends up a generation behind without anyone
noticing. Show it, and update it if the user passed `--write`:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/use_latest_contributor.sh"           # preview the change
"${CLAUDE_PLUGIN_ROOT}/scripts/use_latest_contributor.sh" --write   # apply it (backs up first)
```

Without `--write` this is read-only — report the difference and let the user decide.

## Reporting

Give both answers and say plainly whether they agree. If the user asked what a *past* run
actually used, that is a different question with a different source:

```bash
jq -r 'select(.payload.kind=="run_model_configured") | .payload.model_id' <task-dir>/round-1/events.jsonl
```

Read that as the requested id echoed back, not as proof the provider served it — a run with
a nonexistent model still reports that model there. What it catches is a `--model` flag that
silently never applied, which is the realistic failure.
