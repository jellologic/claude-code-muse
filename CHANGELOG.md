# Changelog

All notable changes to this plugin are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.0] - 2026-09-22

Epic #7: an adversarial review found the plugin's central claim — *`accept` means a
supervisor ran a check and it passed* — stated in four documents and enforced nowhere.
This release closes that gap and the twenty-one others the review and its follow-ups
found. The offline suite went from 99 to 147 checks, every new one negative-controlled.

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

- **The muse coupling is declared** (#16). `MUSE_TESTED_VERSION` names the version every
  assumption was verified against, the event-stream keys live in one documented block
  rather than scattered through a parser, and both `/muse:doctor` and the SessionStart
  preflight warn on a major/minor mismatch — doctor reported the version it found and
  never compared it to anything. A mismatch is never a refusal: muse ships faster than
  this plugin does.
- **The credential scan says when it was partial** (#14). `scan_secrets` stopped at 5000
  files and returned `truncated: True`, which was written into `state.json` and printed
  nowhere — the refusal quoted a count without saying it was a floor, and doctor ignored
  the flag. A truncated scan and a clean scan were indistinguishable in every output,
  which is exactly the failure this project negative-controls everything else against,
  sitting on the one control between a private key and a tier whose own catalog says
  content may be used for product improvement. The cap counts *decoded text* files, so
  it counted source files and a mid-size repo passed it; it is now 20000 and
  `MUSE_SCAN_MAX_FILES` overrides it.

- **Five values are configurable at install time** (#20). Every default was hard-coded:
  effort, round cap, worktree root, whether `run` refuses on a confirmed credential, and
  the model. Each `userConfig` entry ships the value the plugin already used, so an
  install that skips every prompt behaves exactly as before — configuration should let
  someone change behaviour, never change it for someone who did not ask, and the suite
  asserts both directions. `max_rounds` carries `min`/`max` because it is the
  runaway-cost breaker.

  Measured while writing it, and it contradicts the issue: this validator rejects
  `options` on a `userConfig` field in every shape tried — bare strings, `{value,label}`,
  `{name,value}`, `{title,value}` and a map. `title` is required; `description`,
  `default`, `required`, `sensitive`, `min` and `max` are accepted; the types are
  `string`, `number`, `boolean`, `directory` and `file`. The effort constraint is stated
  in the field's description instead, and `muse_task.py` validates it regardless.
- **`/muse:ask --continue`** (#23). The session id was printed to stderr and the user had
  to copy it, so the follow-up path that session resume exists to enable was one manual
  step away from unusable. The last id per repo now lives in `${CLAUDE_PLUGIN_DATA}` — the
  per-plugin directory that survives updates, previously allocated and unused. It is keyed
  by absolute repo path, because that directory is shared across every repo and an unkeyed
  "last session" would hand one project's conversation to another. Written *before* the
  run, not after: a run that times out has still created the session, and that is exactly
  the one worth resuming.
- **The fleet workflow is registered, not transcribed** (#26). It shipped as 200 lines of
  JavaScript inside a markdown code fence, so every fan-out began with a model copying it
  into the Workflow tool — the most fragile step on the plugin's headline path, and
  fragile in the most expensive place: a dropped line or a mangled template literal threw
  *after* the planning agents had been paid for. `workflows/muse-supervised-fleet.js` is
  registered by the manifest's `workflows` key and invoked by name. `references/workflow.md`
  keeps the reasoning and no longer carries the code. Whether a plugin-owned workflow gets
  `${CLAUDE_PLUGIN_ROOT}` substituted is undocumented and unverified, so the script tries
  the substitution and falls back to `args.pluginRoot` when the token arrives unexpanded.
- **A `SubagentStop` backstop for the central claim** (#28). `finish` now refuses a bad
  verdict, which closes the path where one gets *written*; it cannot close the path where
  no record is written at all, because the supervisor ran out of turns, was interrupted,
  or stopped and reported from memory. Scoped by matcher to `muse-supervisor`, it reads
  what is already on disk — no model call, no heuristic, no new state — and tells the
  orchestrating agent where the artifacts and the summary disagree. It reports rather than
  blocks: the hook cannot see the brief, so it cannot tell a supervisor stopping too early
  from one the user interrupted deliberately.
- **A `SessionEnd` hook names worktrees still open** (#22). They accumulate silently until
  someone runs `/muse:cleanup` for an unrelated reason. Authority is `git worktree list`,
  not a directory scan, and only `muse/` and `fleet/` branches are reported — the user's
  own worktrees are not this plugin's business.
- **Only the fleet skill auto-triggers now** (#21). All seven `/muse:*` commands
  registered as skills and could fire on their descriptions: `commands/` was chosen over
  `skills/` specifically to avoid that, and the two layouts turn out to be loaded
  identically. `disable-model-invocation: true` on all seven leaves them typeable and
  stops them competing with the one surface whose description was carefully tightened.
  `/muse:cleanup` firing on an inference was the worst case — it removes worktrees.
- **The supervisor has a turn ceiling** (#25). Every other runaway path was bounded —
  `--max-rounds` on the task, `--max-steps` on muse, a round budget — and the supervisor's
  own agent loop had none, which was the most consistent gap with the project's own stated
  guardrails. `maxTurns: 60` and an explicit `effort: high`, so the contract no longer
  depends on whatever spawns it.
- **The marketplace entry declares its relevance** (#27). This plugin's whole premise is a
  third-party CLI literally called `muse`, so `signals: { cli: ["muse"] }` surfaces it to
  anyone who types `muse login` in any session. Deliberately one token: a generic signal
  like `git` would surface it to people it cannot help, and the suite refuses those.
- **`claude plugin validate --strict` runs in CI** (#24), on both manifests and all three
  component directories — the path argument matters, because this repo is both a plugin
  and a single-plugin marketplace, so `validate .` checks `marketplace.json` and says
  nothing about `plugin.json`. The step breaks the manifest on purpose in a copy and
  confirms the validator goes red, because a validation step that cannot fail is worth
  nothing. `$schema`, `displayName` and `defaultEnabled` are declared.
- **The reporting commands run on a cheap model** (#29). `/muse:status`, `/muse:doctor`,
  `/muse:model` and `/muse:cleanup` run one Python script and relay what it printed.
  Running those on the session model, in a plugin whose entire thesis is *push mechanical
  work down to a cheaper model*, was the plugin failing to take its own advice. Their Bash
  grant is narrowed to `Bash(python3:*)` where that is provably all they run, the
  duplicate legacy `Task` tool is dropped from `delegate` and `fleet`, and the
  auto-triggering skill declares an `allowed-tools` list for the first time — without
  `Write` or `Edit`, for the same reason the supervisor has neither.
- **The fleet workflow's artifact root is stamped** (#18). Branches and worktrees carried
  the run stamp and `--out` did not, and `const STAMP = args.stamp || 'run'` defaulted the
  stamp to a literal despite the skill insisting a real one be passed. A second run of the
  same job — or two jobs both planning a task called `tests-parser` — had every supervisor
  refuse at step one with "task already exists": the re-run guard firing correctly against
  a namespace that should never have collided. A missing stamp now throws, and the guard
  *executes* both script headers rather than greping them, so a default creeping back as
  `?? 'run'` is caught too.

### Fixed

- **Three commands shipped with frontmatter that does not parse** (#31), so `/muse:ask`,
  `/muse:cleanup` and `/muse:doctor` have been loading with **no** description, no
  `allowed-tools` and no `argument-hint` for as long as they have existed. An unquoted
  `argument-hint: [--scan] [--repo <path>]` is a YAML flow sequence with trailing content
  after the bracket; the block fails to parse and every field in it is silently dropped.
  The other four parsed as a one-element *list* rather than a string, which is the same
  bug wearing a quieter hat. Found by the `--strict` CI step on its first run — the older
  CLI on the development machine reported `✔ Validation passed` on the same files.
- **A relative `--out` moved with the current directory** (#17). An agent's Bash cwd
  resets between tool calls, `commands/delegate.md` prescribed the relative
  `.muse-fleet/tasks`, and `references/workflow.md` said the opposite and called it
  *"Proven: the same `--out` from two directories yields two different task
  directories."* The wrong document was the command a user actually runs. `run` from the
  repo root and `verify` from a subdirectory addressed two task directories; the second
  reported `no_such_task`, and the supervisor's natural recovery — `run --force` —
  discards the patch the first one just made. A relative `--out` now resolves against the
  repository, which is what it is relative to, and `run` refuses a relative `--out`
  against a `--repo` elsewhere rather than creating a task the later subcommands cannot
  find. The three documents now agree.
- **`show` raised `KeyError` on partial state.** It is the command a supervisor reaches
  for when something has already gone wrong, and state written by an older version or
  truncated by a crash produced a traceback on the stream the supervisor parses.
- **`session_exists` failed OPEN on an unknown session schema** (#16). `if recorded and
  ...` read "cannot tell which workspace" as "no constraint", so a view directory that
  survived a muse schema change with `workspaceRoot` renamed came back resumable. Muse
  then refuses the cross-workspace resume and the round dies producing nothing — verbatim
  the failure the code documents and claims to route around. It now fails closed, and
  only where a snapshot exists to be read: a session known solely from the dated tree is
  a different question and is not answered the same way.
- **Every muse-side failure reported the same sentence** (#15). `run_muse` never read
  `returncode` and `stderr.log` was an artifact nothing told the supervisor to open, so
  an unknown flag, a bad model id, an expired credential and a binary that is not Muse
  Code all came back as "muse produced no run_terminal record (crash or kill?)". The
  exit code and a stderr tail are now in the round record and the emitted JSON, and the
  reason branches on them — leaving something to do other than retry blind, which this
  plugin's own guidance says not to do.
- **`muse_task` had neither worktree-collision defence `muse_fleet` was given** (#19),
  despite being the documented default path. Its stamp was a bare second-resolution
  timestamp, so two runs started in the same second computed the same branch and the
  same worktree path — and `cmd_run` calls `drop_worktree`, which is `git worktree remove
  --force` plus `git branch -D`. It also force-removed a live worktree sitting at that
  path under a *different* branch, which the branch-name guard cannot see. Both defences
  are ported, and the entropy guard now parses the `stamp` expression instead of greping
  for `token_hex`, which survives the expression that used it.
- **A timed-out acceptance check left its grandchildren running** (#13). `cmd_verify`
  carried a comment saying `start_new_session` let a hung check be killed as a group, and
  then called `subprocess.run(timeout=...)`, which signals only the direct child —
  `kill_process_tree` existed for exactly this and was never called. The session made it
  *worse*: survivors were detached where nothing could reap them. The review timed out a
  check at 3s and found five `sleep 600` processes still alive afterwards, writing into a
  worktree `finish --cleanup` was about to force-remove. It now uses `Popen` +
  `kill_process_tree`, matching `run_muse`. The timeout path had no test at all; it has
  three now, including a control proving the survivor fixture really spawns one. On
  Windows, where there are no process groups to signal, the kill now goes through
  `taskkill /F /T` instead of degrading to the direct child — the CI leg caught that the
  first fix was POSIX-only.
- **A second `finish` replaced the first verdict silently** (#12). `cmd_revise` refuses a
  finished task and this had no equivalent guard, so a second call overwrote the verdict,
  summary and concerns and re-harvested on top. With `--commit` it also used to erase the
  deliverable — 9 patch lines became 0, `task.json` reported an empty patch, and
  `/muse:cleanup` reaps a finished task's branch. Pinning the base to a sha closed the
  erasure; the guard now closes the overwrite. `--force` is the override, and a *refused*
  accept is not a finish, so the recovery the gate prescribes stays open.
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

[Unreleased]: https://github.com/jellologic/claude-code-muse/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/jellologic/claude-code-muse/releases/tag/v1.3.0
[1.2.0]: https://github.com/jellologic/claude-code-muse/releases/tag/v1.2.0
[1.1.0]: https://github.com/jellologic/claude-code-muse/releases/tag/v1.1.0
