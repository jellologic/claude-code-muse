# Changelog

All notable changes to this plugin are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **`finish --verdict accept` is now gated rather than annotated** (#9). Every document in
  this repo said `accept` means a supervisor ran a check that passed; nothing enforced it,
  `--verdict` was a plain argparse choice, and the suite's most relevant test asserted that
  an accept with no check at all was allowed. `finish` now refuses, emits `status:
  refused`, exits non-zero, and names which of the three conditions failed. The worktree
  survives the refusal even under `--cleanup`, because reaping it would destroy the only
  copy of the work the supervisor was just told to go verify.
- **`--accept-unverified "<reason>"` is the one way past the gate.** Some correct patches
  make a check legitimately go red — a strict xfail that starts XPASSing is the shipped
  example. The reason lands in `task.json` and `/muse:status` prints it on the row, so the
  override costs a human a decision instead of disappearing into a boolean.

- **The "no Write/Edit tool" guarantee is now measured instead of asserted** (#10). Two
  places in the codebase said the toolset enforced it. The supervisor has `Bash`, a shell
  redirect is a write, and `verify --command` runs with `shell=True` inside the worktree —
  in the review's reproduction the *entire harvested patch* was produced by `echo >` and
  `finish` attributed it to muse. Each round now fingerprints the patch muse produced;
  `finish` compares it against what it harvests and reports `out_of_band_edit`, with
  `mutating_checks` naming any acceptance check that accounts for part of the difference.
  `/muse:status` prints it on the row. The claims are reworded to describe the real
  mechanism: the toolset is a strong default, the measurement is the enforcement.

### Fixed

- **`harvest` failed on any repository with a `.gitignore`.** Found by a guard written for
  the above, and shipped for as long as the exclude list has existed. `git add -A --
  ':(exclude,glob)__pycache__'` exits 1 when git *already* ignores `__pycache__`, and
  `DEFAULT_EXCLUDES` is a list of exactly what a real repo gitignores — `__pycache__`,
  `node_modules`, `.venv`, `dist`, `build`. From the first moment a worker generated one,
  every harvest returned `git add failed` and `patch.diff` stopped being updated. It was
  invisible because every fixture repo in the suite is created without a `.gitignore`.
  Staging now retries without the pathspec, which is correct rather than a workaround:
  git skips ignored files on its own and the diff applies the same excludes afterwards.
- **A verification is now bound to the tree it certified** (#8). `verify` recorded
  `after_round` and nothing ever read it, so a check could pass at round *n*, the worktree
  could change, and `finish` would harvest a patch no check had ever seen and report
  `verified_by_supervisor: true`. The review reproduced it end to end: `test ! -f
  BACKDOOR.py` exited 0, `BACKDOOR.py` was then created, and the task came out accepted and
  verified with zero flags. `verify` now records a `git write-tree` hash of the staged
  worktree and `finish` compares it against the tree it harvests; a mismatch is reported as
  stale and refuses the accept. The fingerprint is taken over the **patch** rather than
  the worktree, and **after** the acceptance command rather than before, so a check that
  builds, formats or generates does not come back refused as a TOCTOU — only a change
  between the check finishing and the harvest does, which is the window the attack lives
  in.
- **`/muse:status` no longer reads a stale certification as verified.** It computed
  `verified` from exit codes alone, which cannot see this case — from the artifacts a run
  with a moved tree looks perfect. An explicit `false` written by `finish` now outranks the
  evidence in that one direction only, so an old `task.json`'s stale `true` still cannot
  launder a red check into a green row.

### Documentation

- **The session-restart requirement is documented.** Plugin commands, skills and agents
  register at session start, so `/muse:*` does not exist in the session you installed
  from. It was the first thing a new user hit and appeared nowhere — now in the README
  install steps, the contributor dev loop, and the skill itself so it can diagnose the
  symptom when someone reports a missing command.
- A "writing a delegation that comes back right" section in the README: name the exact
  files, give a runnable check, say what must not change, start from a clean tree.
- The README names the phrasings that trigger the skill on its own, and points at
  `/muse:ask --session` for follow-ups.

### Fixed

- **A fleet no longer deletes a concurrent run's live worktrees** (#2). The run namespace
  was a 1-second timestamp, so two fleets started in the same second computed identical
  branches and worktree paths — and `run_task` opens with `drop_worktree`. The stamp now
  carries entropy, and a worktree that exists and is non-empty is refused rather than
  force-removed.
- **`session_workspace` raised when a snapshot vanished mid-walk** (#5). The `stat()` ran
  inside a sort key, outside the `try`; muse rotates those snapshots, so the resulting
  `FileNotFoundError` came out of `cmd_revise` as a traceback where a supervisor expects
  one JSON object.
- **`kill_process_tree` crashed where process groups do not exist** (part of #3).
  `os.killpg`, `os.getpgid` and `signal.SIGKILL` are absent on Windows *as attributes*, so
  they raise `AttributeError` rather than the `OSError` that was being caught — turning a
  recoverable timeout into a lost run. The capability is now probed once at import and the
  kill degrades to the direct child.

### Changed

- **Windows is now tested and green**, and its CI leg is blocking. Getting there fixed a
  real shipped bug (see cp1252 below) and several harness faults. `muse` itself is never
  invoked there, so live delegation on Windows remains unverified.
- **All text I/O passes `encoding="utf-8"`.** Windows Python defaults to cp1252, four of
  this repo's own files cannot be decoded that way, and muse's patches routinely contain
  UTF-8 — so every unguarded `read_text()` was a crash waiting on a non-ASCII byte.
- **Fleet stamp entropy raised from 2 bytes to 4.** 16 bits gives a ~1.9% collision across
  50 runs by the birthday bound, and that namespace's collision deletes another run's live
  worktrees.
- The test suite writes no fixed scratch path; everything is under its own `mktemp` dir
  (#1). Fixed `/tmp` paths collide between users on a shared host and can be pre-created
  as symlinks. Also stops `--repo /tmp`, which would have had preflight write
  `.git/info/exclude` there.

## [1.2.0] - 2026-09-22

### Fixed after tagging

- `muse_doctor.py` crashed with an `IndexError` when a binary named `muse` exited 0 and
  printed no version — which is exactly what the test suite's own stub does. A diagnostic
  that dies on the way to telling you something is the worst possible failure, so every
  check is now individually guarded and an unexpected error becomes a FAIL line rather
  than a traceback. Caught by CI within minutes of the tag; the tag was moved rather than
  leaving a release whose CI was red.

### Fixed

- **The fleet script's `--out` defaulted to a relative path.** `muse_task` resolves it
  against the current directory and an agent's Bash cwd resets between tool calls, so
  `run` and `verify` could address different task directories and the second would report
  "no such task". It is now absolute, and the rule is documented for hand-written
  workflows.
- **`cleanup --artifacts` could `rmtree` your home directory.** The marker check walked the
  tree unbounded, so it answered "this is an artifact root" for `$HOME` — any stray
  `state.json` anywhere beneath it. The check is now bounded to two levels, and a separate
  guard refuses a home directory, a filesystem root, a repository root, or the current
  directory or an ancestor of it outright.
- **A failed harvest overwrote a good patch with an empty file.** `git add`/`git diff`
  exit status was ignored, so a missing worktree or a held `index.lock` produced empty
  stdout, replaced `patch.diff`, and reported a clean zero-line result — a failure
  presented to the supervisor as "the worker decided nothing needed doing".
- **`run` deleted a git branch it did not create.** The teardown before `worktree add` ran
  unconditionally and ends in `git branch -D`, which discards unmerged commits without
  asking. It now refuses a colliding branch that is not this task's.
- **A corrupt `state.json` read as "no prior task"**, silently defeating the re-run guard.
  "Exists but unreadable" is now a refusal, and `save_state` writes atomically.
- **`--timeout` killed a shell, not muse.** `muse_ask.sh` backgrounded a subshell, so the
  timeout killed the wrapper while muse ran on unbounded, writing into a deleted temp file.
  Muse is now the direct child and is signalled as a process group.
- **An orphaned watchdog could SIGKILL an unrelated process.** If the script died before
  disarming it, the watchdog survived its parent and fired up to `--timeout` later against
  a PID the kernel had recycled. It is now killed as a group from an `EXIT INT TERM` trap,
  which also stops each run leaking a stray `sleep`.
- **Timeouts killed only the direct child.** A `--yolo` run that spawned a build or test
  runner left those running against a worktree about to be deleted. Both muse runs and
  `verify` commands now run in their own session and are killed as a tree.
- **`run` and `revise` exited 0 on a timed-out or crashed round**, so automation branching
  on `$?` proceeded to `verify`/`finish` on nothing.
- **A task id was never validated** though it names a directory and a git branch:
  `--id ../../x` wrote outside the artifact root, where `status` cannot see it.
- **A repo with no commits produced a traceback** instead of a JSON refusal. Unknown ids,
  corrupt state and bad schemas now all honour the one-JSON-object-on-stdout contract.
- **The unsupervised fleet wrote no `state.json`/`task.json`**, so `status` reported it as
  having produced nothing and `cleanup` refused to reap its worktrees.
- **Ctrl-C ran the entire remaining fleet** before propagating, then lost the report.
- The fleet workflow now prints every planned acceptance check before the Build phase.
  `SECURITY.md` claimed this existed; it did not. These are model-written commands that
  `verify` executes on the host with your privileges.
- Task ids in the fleet plan schema now carry the pattern the code enforces, so a plan
  cannot pass planning and then have every task refused.

### Added

- **`/muse:doctor`** — reports whether this machine can delegate and what it would use:
  muse version, credentials (existence only), catalog freshness, the model that actually
  resolves, the interactive pin, Python/git, the plugin's own scripts, repo git state and
  worktree-root writability. Three severities, each FAIL carrying its own fix, non-zero
  exit when blocking. The SessionStart hook answers "would this fail right now?"; this
  answers "what exactly is my setup?".
- **Pre-delegation credential scan.** `run` scans the worktree after seeding — so it sees
  a `--seed`-ed `.env` — and refuses on a structurally unmistakable credential (PEM
  private-key block, AWS key id, GitHub/Slack/Stripe/Anthropic token formats).
  Credential-shaped assignments warn only. `--allow-secrets` overrides,
  `--no-secret-scan` skips, `/muse:doctor --scan` runs it on demand. Findings record
  file, line and kind and never the matched text. `SECURITY.md` documented this exposure
  and offered no tooling for it.
- **Guidance for embedding muse in your own Claude Code workflow** — muse as one stage of
  a workflow you are writing, rather than only the shipped fan-out. Verified by running a
  real workflow that delegated a task and got back an independently-checked `accept`.

### Documentation

- The supervisor agent still said "muse has no memory between rounds" — the one file the
  earlier correction missed.
- `README`/`SKILL` said `accept` *requires* a passing check; nothing enforces the verdict,
  the enforcement is `/muse:status` flagging it afterwards.
- `/muse:ask` read-only mode is a strong default, not a guarantee — muse can still write
  through the shell, as the script's own comment says.

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

[Unreleased]: https://github.com/jellologic/claude-code-muse/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/jellologic/claude-code-muse/releases/tag/v1.2.0
[1.1.0]: https://github.com/jellologic/claude-code-muse/releases/tag/v1.1.0
