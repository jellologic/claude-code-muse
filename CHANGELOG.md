# Changelog

All notable changes to this plugin are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Nothing yet.

## [1.1.0] - 2026-09-22

### Added

- **Session resume.** A task's rounds now share one muse session (`muse exec --session-id`),
  so a revision is a genuine follow-up: the worker still has its brief, the files it read
  and its own reasoning. The revision prompt no longer restates the task.
  Verified by planting a codeword in round 1's brief that exists nowhere on disk and
  finding it in round 2's patch, with the prompt containing no mention of it.
- `muse_ask.sh --session <id>` and a printed session id, so a one-off question can be
  followed up without re-explaining the context.
- `MUSE_CATALOG_GLOB` and `MUSE_DATA_DIR` overrides, so model resolution and session
  lookup can be tested on a machine with no muse install.
- `/muse:status` now flags a revision round that could not resume its session — the worker
  had feedback and a re-sent brief but no memory of its own attempt, which is closer to a
  fresh try than a correction.
- `scripts/validate.sh --offline`: 65 checks that spawn no muse, cost nothing and run in
  seconds. CI runs these on Python 3.9, 3.11 and 3.13.
- `muse_status.py` and `muse_cleanup.py`, plus the `/muse:status`, `/muse:model` and
  `/muse:cleanup` commands.

### Fixed

- **`accept` now requires the FINAL check to pass, not any check that ever passed.** Found
  by running `/muse:delegate` end to end: the supervisor ran a cheap gate
  (`pytest --collect-only`, exit 0) then the real acceptance check (`pytest -q`, exit 1),
  and the task recorded `verified_by_supervisor: true` with its acceptance check red — the
  plugin's central guarantee inverted. `/muse:status` now computes from the exit codes it
  can see rather than a stored flag, and distinguishes "accepted while the final check
  FAILED" from "accepted with no executed check".
- **A session bound to another workspace is no longer treated as resumable.** Muse records
  a `workspaceRoot` per session and refuses to resume elsewhere — and it *fails the run*
  rather than starting fresh, so the round died with no output, burned a round budget, and
  still reported `resumed: true`. `session_exists()` now verifies the binding and routes an
  unresumable session to the fallback that re-sends the brief.
- `hooks/hooks.json` registered **zero** hooks: a plugin needs its events under a top-level
  `"hooks"` key, and the unwrapped form parses fine while doing nothing.
- `mktemp -d -t NAME` is BSD-only. On Linux GNU coreutils rejected the template and printed
  nothing, leaving the scratch path empty — which made `validate.sh` operate on `/v_sc` and,
  since `mkrepo` opens with `rm -rf`, was latently destructive. The same bug in
  `muse_ask.sh` would have broken every run on Linux.
- `muse_cleanup.py --artifacts` removed whatever `--out` named, and did so in the
  zero-targets branch without printing what would go. It now requires a `state.json` or
  `task.json` marker under the root and no longer swallows partial failures.
- Three `${SKILL}` references in `references/` survived a rename and would have thrown
  `ReferenceError` inside the fleet workflow.
- `references/workflow.md`'s documented invocation omitted `pluginRoot`, the one argument
  the script throws on.
- `muse_ask.sh --help` printed `set -uo pipefail` as documentation, because it used a fixed
  line range that drifted when the header changed.
- `muse_ask.sh` no longer duplicates `muse_core.FALLBACK_MODEL`; a second copy of a pinned
  version is the exact staleness this plugin argues against.

### Changed

- Renamed to `claude-code-muse`. `muse-code` read as the CLI itself rather than a Claude
  Code plugin that drives it.
- The `muse-fleet` skill description gained a `muse`-on-PATH precondition and explicit
  exclusions; it was triggering on any worktree, parallel-agent or token-budget prompt.
- The skill now routes to the `muse-supervisor` agent by default for one or a few tasks.
  Previously the agent was described but never offered as a path, so a single task fell
  back to hand-driving `muse_task.py` — putting one agent in both the driving and judging
  seat, which is the separation the design exists to keep.
- Workflow opt-in is gated: a typed `/muse:fleet` is consent, an inferred skill trigger
  asks first. A fleet spawns N muse runs and N supervisors and costs real money.

### Documentation

- Corrected the claim that "muse has no memory between `muse exec` invocations", which was
  stated in `SKILL.md`, `muse-cli.md`, `muse_task.py` and the supervisor agent. It is false;
  see Session resume above.
- Added `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, issue and PR templates.
  `SECURITY.md` documents the trust model, including that `verify` runs its command on the
  **host** with full privileges while the worker is confined to a throwaway worktree.

[Unreleased]: https://github.com/jellologic/claude-code-muse/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/jellologic/claude-code-muse/releases/tag/v1.1.0
