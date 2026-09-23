# Security

## Reporting a vulnerability

Use GitHub's private vulnerability reporting:
**[Report a vulnerability](https://github.com/jellologic/claude-code-muse/security/advisories/new)**
(Security → Advisories → Report a vulnerability).

Please do not open a public issue for something exploitable. Include the version, your OS,
and the smallest reproduction you have. Expect an initial response within a week; this is a
small project maintained in spare time, so please set expectations accordingly.

Describe the class of problem rather than attaching a working exploit.

## The trust model, stated plainly

This plugin runs a coding agent that edits code and executes shell commands. Some of that is
intentionally privileged. Knowing which parts, and why, is more useful than a blanket
warning — so here is the whole picture.

### Workers run with `--yolo`

Every delegated muse run passes `--yolo`, which disables tool-approval prompts and the OS
sandbox. That is defensible for exactly one reason: **the blast radius is a throwaway git
worktree on a throwaway branch**, created outside your repository and deleted by
`/muse:cleanup`.

That argument holds only while its preconditions do. Preserve them:

- Never point a fleet at a dirty main working copy. The drivers refuse by default; do not
  reach for `--allow-dirty` to silence it.
- Keep worktrees outside the repo. That is the default; overriding `--worktree-root` to a
  path inside your project removes the isolation.
- Use `--max-steps` on open-ended prompts and `--max-rounds` on supervised ones so a
  confused agent cannot loop indefinitely.

### The acceptance check runs on the host, not in the sandbox

This is the sharpest edge in the project and the one most likely to surprise you.

`muse_task.py verify` executes its `--command` with **your privileges**, on your machine.
The worktree is only that command's working directory — it is not a security boundary. And
in the fleet path, the check string is *written by a model*: `references/workflow.md` has
the planner emit a `check` field per task, which is then handed to `verify`.

Read a planned acceptance check the same way you would read a command you are about to
type yourself. The fleet workflow prints every planned check after the Plan phase, under
"acceptance checks that will run on the host", for exactly this reason — that is the field
to slow down on. After a run they are also recorded in `<out>/<id>/state.json` under
`verifications[].command`.

### What this plugin sends where

- Prompts, file contents the worker reads, and its patches go to **Meta's Muse Code API**
  under whichever model you selected.
- **Contributor-tier models state that your content "may be used for product improvement."**
  For proprietary or client-confidential code, either pass `--model muse-spark-1.3` and pay
  full rate, or do not delegate that code at all. That judgment is yours; the plugin cannot
  make it for you.
- **It does make one part of it mechanical.** Before spawning a worker, `muse-task run`
  scans the worktree — after seeding, so it sees the `.env` you asked it to copy — and
  so does `muse-fleet` for every task worktree and `muse-ask --write` (read-only ask never
  reaches a worker, so it does not scan). Each scan covers every file the worker could
  read — tracked, untracked and gitignored files, including seeded files and followed
  symlinks, with only .git pruned — and **refuses** if it finds a structurally
  unmistakable credential: a PEM private-key block, an AWS key id,
  a GitHub/Slack/Stripe/Anthropic-format token. Credential-shaped assignments only warn,
  because blocking those would make the plugin unusable on any repo with test fixtures.
  `--allow-secrets` proceeds anyway, `--no-secret-scan` skips the check, and
  `/muse:doctor --scan` runs it on demand. The scan stops at a file cap, and a truncated
  scan says so. Findings record the file, line and kind and
  never the matched text — copying a secret into an artifact that then gets read and
  shared would defeat the point. `muse-ask` scans in both modes: a read-only worker
  can still read a secret and send it to the contributor tier.
- Nothing is sent anywhere else. There is no telemetry, no analytics, and no network call
  in this plugin outside the `muse` CLI itself.

### Credentials

The plugin never reads your credentials. `hooks/preflight.sh` checks only that
`~/.config/muse/auth.json` exists and is non-empty — a size test, never a read — so it can
tell you to run `muse login` before a fan-out fails on every worker at once. Credentials are
handled entirely by the `muse` CLI.

### Destructive operations

`/muse:cleanup` deletes git worktrees, branches and, with `--artifacts`, patch files. It is
a dry run unless you pass `--yes`, and it refuses to remove a task that never reached a
verdict unless you pass `--all`, because an unfinished task's work exists only in its
worktree.

`--artifacts` is the blunt one, and worth understanding before you use it:

- It removes the **whole artifact root**, including the harvested patches of tasks whose
  worktrees were skipped as unfinished. After that their work really does exist only in
  the worktree.
- It refuses a directory with no `state.json`/`task.json` marker within two levels, so a
  mistyped `--out` cannot take a real directory with it.
- It refuses outright if the target is your home directory, a filesystem root, a
  repository root, or the current directory or an ancestor of it — a marker can exist
  somewhere beneath any of those, and the marker check alone is not a safety boundary.

## Out of scope

- The behaviour of the `muse` CLI itself, or of Meta's API. Report those upstream.
- A model producing wrong or low-quality code. That is what the supervisor and the
  acceptance check exist to catch, and `/muse:status` flags any patch accepted without an
  executed check.
- `--yolo` as such, given the worktree isolation documented above. If you can show the
  isolation does not hold, that is very much in scope and worth reporting.
