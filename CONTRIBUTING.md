# Contributing

Thanks for being here. This is a small, opinionated plugin, and the fastest way to get a
change merged is to know the two or three things it is opinionated *about*.

## The one rule

**Trust the measured result over what a change claims about itself.** A file that parses, a
suite that prints green, a `status: completed` from a worker — none of those are evidence
that the thing you changed actually ran. Two real examples from this repo's own history:

- `hooks/hooks.json` was valid JSON, committed, and registered **zero** hooks, silently,
  because the events were not wrapped in a top-level `"hooks"` key. `claude plugin details`
  is what caught it.
- The offline suite went green while five preflight guards were never reached, because
  `muse` was missing from `PATH` and every one of them exited early with the same message.

If you add a guard, prove it can fail. See "Every guard must be negative-controlled" below.

## Setup

You need `git`, `python3`, `bash` and Claude Code. You need the Muse Code CLI (`muse`) on
`PATH` only to run the **live** suite — everything else works without it.

```bash
git clone https://github.com/jellologic/claude-code-muse.git
cd claude-code-muse
bash scripts/validate.sh --offline     # seconds, free, spawns no muse
```

## The dev loop

The installed plugin is a **cache copy** and does not live-update. Editing the repo changes
nothing in your running session until you reinstall. This trips up everyone once:

```bash
# 1. edit the repo
# 2. prove it still holds together (free, seconds)
bash scripts/validate.sh --offline

# 3. reinstall so Claude Code actually sees it (there is no --force)
claude plugin marketplace update claude-code-muse
claude plugin uninstall muse
claude plugin install muse@claude-code-muse

# 4. confirm every component was discovered
claude plugin details muse

# 5. start a NEW session — commands, skills and agents register at session start,
#    so the session you reinstalled from still has the old ones
```

That last step matters more than it looks. `claude plugin details` prints a component
inventory, and **a zero count is how a mis-shaped config announces itself** — there is no
error, no warning, just a component that silently is not there.

For local development, add the marketplace from the **directory**, not from GitHub, so you
can iterate without pushing:

```bash
claude plugin marketplace add /path/to/claude-code-muse
```

## Where things go

| You want to add | Put it in | Notes |
|---|---|---|
| A user-typed `/muse:*` command | `commands/<name>.md` | Needs `description`, `argument-hint`, `allowed-tools` frontmatter |
| Knowledge that should trigger on its own | `skills/muse-fleet/SKILL.md` | There is deliberately **one** auto-triggering skill; think hard before adding a second |
| An autonomous worker | `agents/<name>.md` | See the tool-restriction note below |
| Shared logic | `scripts/` | At the plugin **root**, because the skill, the agent and the commands all consume it |
| Long-form reasoning | `references/` | Also at the root, same reason |

Every intra-plugin path must use `${CLAUDE_PLUGIN_ROOT}`. Never a hardcoded absolute path,
never `~/`, never a path relative to the working directory. CI fails the build on this.

## Things that will get a PR sent back

**Giving the supervisor a Write or Edit tool.** `agents/muse-supervisor.md` has exactly
`Bash, Read, Grep, Glob`, and that is load-bearing rather than incidental. A supervisor that
can patch the worktree by hand will, and then the next round starts from a tree muse did not
produce, `finish` folds the hand-edit into the harvested patch and misattributes it, and you
are paying frontier-model rates to type. The restriction is what makes the architecture true
instead of merely recommended.

**Conflating `completed` with `accept`.** `completed` means the worker stopped. `accept`
means a supervisor ran an acceptance check, it passed, and it ran against the tree that was
harvested — `finish` refuses the verdict otherwise, and `--accept-unverified "<reason>"`
records the override rather than hiding it. Any change that lets those two blur together is
a change to the point of the project.

**A guard that cannot fail.** A check that inspects nothing passes exactly like a check that
found nothing.

**Inventing an acceptance check that always passes.** If a task genuinely has no runnable
oracle, the honest move is to say so and review by hand.

## Every guard must be negative-controlled

When you add a check to `scripts/validate.sh`, break the thing it watches, confirm the suite
goes red, restore it, confirm it goes green. Put the result in your PR description. This
takes two minutes and is the difference between a test suite and decoration.

```bash
bash scripts/validate.sh --offline        # green
# deliberately break the behaviour under test
bash scripts/validate.sh --offline        # must go red, and name the right check
git checkout scripts/<the file>           # restore
bash scripts/validate.sh --offline        # green again
```

### Testing model resolution

`MUSE_CATALOG_GLOB` overrides where `muse_core` looks for muse's model catalog. Point it at
a fixture and resolution becomes deterministic on any machine, including one with no muse
install:

```bash
MUSE_CATALOG_GLOB="/path/to/fixture/*.json" python3 scripts/muse_fleet.py --tasks t.json --repo .
```

This exists because the alternative is asserting against whatever catalog happens to be on
the host, which is environment-dependent by construction — and which is exactly how a check
in this suite went red on CI's first run for an entirely correct reason.

## The live suite

```bash
bash scripts/validate.sh                  # everything, including live muse runs
```

This spawns real muse instances, so it **costs real money** and takes several minutes. It
builds throwaway repos in a temp dir and touches nothing of yours. Run it when you change
`muse_core.py`, `muse_task.py` or `muse_fleet.py`, or when muse ships a new version and you
want to know whether any behaviour this plugin depends on has moved.

CI only runs `--offline`, because CI has no muse credentials and should not have any.

## Pull requests

- One concern per PR. A rename and a behaviour change in the same diff are two PRs.
- `Closes #N` only when the change finishes the issue; otherwise `Refs #N`. Keep
  close/closes/fixes/resolves away from an issue number **entirely** — GitHub matches the
  keyword and ignores the grammar around it. A negated sentence here closed an issue, and
  the commit documenting that quoted itself and closed it again. Spell the number in
  words if you must write about it.
- Say what you **measured**, not what you expect. Paste the suite's RESULT line and name
  what went red when you broke the thing your new guard watches — that is worth more than
  "tested and working".
- If you could not verify something, say which part and why. That is genuinely more useful
  than a confident claim that turns out to be wrong.
- Comments should explain *why something would break*, not what the line does.

Style: no trailing whitespace, keep the existing voice in docs, and prefer a sentence that
explains a failure mode over a sentence that describes a feature.

## Reporting bugs

Use the issue templates — they ask for `muse --version`, your OS, and the exact command,
which are the three things almost every report is missing. For anything security-shaped, read
[SECURITY.md](SECURITY.md) first; some of this plugin's behaviour is intentionally
privileged and is documented there.
