#!/usr/bin/env python3
"""
muse_core.py — the shared engine under muse_task.py and muse_fleet.py.

Everything here is about running one muse instance safely inside a disposable git
worktree and getting its work back out as a patch. Nothing here decides *what* to run
or *whether the result is any good* — those are the caller's job, and in the workflow
architecture they belong to an Opus supervisor agent.

Split out of muse_fleet.py so that the single-task path (muse_task.py, driven by a
supervisor that reviews and re-prompts) and the batch path (muse_fleet.py) cannot
drift apart in how they isolate, seed, exclude or harvest. A behaviour difference
between those two would show up as "the workflow produced a different patch than the
CLI did", which is exactly the class of bug nobody debugs quickly.
"""

from __future__ import annotations

import datetime as dt
import fnmatch
import glob
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import threading
import uuid
import sys
from pathlib import Path

# Sentinel: resolve the newest contributor model from the live catalog at run time.
# Hard-coding a version is how a machine ends up silently a generation behind -- exactly
# what a stale `model` pin in ~/.config/muse/settings.json does.
LATEST = "latest-contributor"
FALLBACK_MODEL = "muse-spark-1.3-contributor"
MUSE_DATA_DIR = os.environ.get("MUSE_DATA_DIR") or "~/.local/share/muse"
# Overridable so model resolution can be tested anywhere, including a machine with no
# muse install. Without a seam the only way to test it is to trust whatever catalog
# happens to be on the host, which makes the result environment-dependent.
# The data dir feeds the default glob so MUSE_DATA_DIR alone redirects the catalog;
# MUSE_CATALOG_GLOB stays the explicit override seam.
CATALOG_GLOB = os.environ.get(
    "MUSE_CATALOG_GLOB") or os.path.join(MUSE_DATA_DIR, "model-catalog", "*.json")

# ---------------------------------------------------------------- muse coupling
#
# Everything this plugin assumes about the muse CLI, in one place, because the coupling
# is real and was previously undeclared -- spread across an event parser, ten exec
# flags, a catalog row shape, a session directory layout and a raw-text regex. Most of
# those fail closed (a renamed key produces `no_terminal`, which is at least loud). The
# point of naming them together is that a version bump has one list to re-check.
#
# Verified against this version. A mismatch is a WARN, never a refusal: muse ships
# faster than this plugin does, and refusing to run on an untested version would be
# wrong far more often than it was right. The plugin relies on `exec --prompt-file`
# and on `--` ending option parsing.
MUSE_TESTED_VERSION = "1.3.0"

# Floor for the Claude Code CLI, and the single place it lives: CI installs this
# version and the doctor warns below it. Hyphen-exact matchers and
# ${user_config} rejection in shell-form hooks since 2.1.207 differ by CLI
# version, and CI once got 2.1.197 while local was 2.1.280.
MIN_CLAUDE_VERSION = "2.1.280"


def claude_below_floor(found):
    """A one-line note if `found` is older than MIN_CLAUDE_VERSION, else None.

    Compared as integer tuples, never as strings: "2.1.99" is older than
    "2.1.280" numerically but sorts newer lexicographically.
    """
    if not found:
        return None
    m = re.search(r"(\d+)\.(\d+)\.(\d+)", found)
    if not m:
        return None
    if tuple(int(g) for g in m.groups()) >= tuple(int(g) for g in MIN_CLAUDE_VERSION.split(".")):
        return None
    return ("claude CLI %s is older than the %s floor" % (m.group(0), MIN_CLAUDE_VERSION))

# Event stream (`muse exec --json`): one JSON object per line, the interesting part
# nested under "payload", discriminated by "kind".
EV_PAYLOAD = "payload"
EV_KIND = "kind"
EV_TERMINAL = "run_terminal"          # the single authoritative record of a round
EV_MODEL_CONFIGURED = "run_model_configured"
EV_MODEL_ID = "model_id"

PLACEHOLDER_RE = re.compile(r"^\$\{user_config\.([A-Za-z0-9_]+)\}$")


def flag_given(key, cli_value):
    """Whether a CLI flag value counts as explicitly given.

    False for None and "": the flag was absent or substituted from an empty
    userConfig value. Also False for an unsubstituted same-key placeholder
    ("${user_config.KEY}" naming the key being resolved, after strip()): the
    runtime leaves unset keys as literal text, so the flag carries no value
    and resolution falls through to the environment and then the default.
    The prose command lines single-quote their placeholders, so an unset key
    arrives here literally instead of killing the shell first.
    A placeholder naming a DIFFERENT key is a wiring bug in prose and raises
    ConfigError naming both keys. Any other value (including a partial match
    like "/x/${user_config.KEY}/y") counts as given.
    """
    if cli_value is None:
        return False
    if isinstance(cli_value, str):
        if cli_value == "":
            return False
        m = PLACEHOLDER_RE.match(cli_value.strip())
        if m:
            if m.group(1) == key:
                return False
            raise ConfigError(
                "userConfig {}={!r} is an unsubstituted placeholder for a "
                "different key ({})".format(key, cli_value, m.group(1)))
    return True


def user_option(key, default):
    """A `userConfig` value if the runtime supplied one, else the built-in default.

    The mechanism is Claude Code substituting ${user_config.KEY} into the agent,
    skill and command markdown bodies (non-sensitive values), which then reach the
    scripts as CLI flags. A key the user never set stays as the literal text
    ${user_config.KEY} even when plugin.json declares a default; option_with_source
    treats that same-key placeholder as not given. The CLAUDE_PLUGIN_OPTION_<KEY>
    environment variable is the hook/test path: the runtime exports it to HOOKS,
    so hooks and the offline suite use it to observe the same values without a
    live substitution.

    Every default below is what the plugin did before there was any configuration, so an
    install that skips the prompts behaves exactly as it used to. That is the property
    worth protecting: configuration should let someone change behaviour, never change it
    for someone who did not ask.
    """
    raw = os.environ.get("CLAUDE_PLUGIN_OPTION_" + key.upper())
    if raw is None or raw == "":
        return default
    return coerce_option(key, raw, default)


def option_with_source(key, cli_value, default):
    """Resolve one userConfig key and say where the value came from.

    One precedence rule for every driver: a non-empty CLI flag wins (source
    "flag"), then a non-empty CLAUDE_PLUGIN_OPTION_<KEY> (source "env"), then
    the built-in default (source "default"). An empty-string flag counts as not
    given, because that is what an empty userConfig value substitutes to in the
    supervisor's `run` line. A same-key "${user_config.KEY}" placeholder also
    counts as not given, because the runtime leaves unset keys as literal text
    (the prose lines single-quote their placeholders so the literal survives
    the shell and reaches this check);
    a placeholder naming a different key raises ConfigError. Flag and env values
    are validated with coerce_option, so a bad value raises ConfigError naming
    the key.
    """
    if flag_given(key, cli_value):
        return (coerce_option(key, cli_value, default), "flag")
    env_raw = os.environ.get("CLAUDE_PLUGIN_OPTION_" + key.upper())
    if env_raw is not None and env_raw != "":
        return (coerce_option(key, env_raw, default), "env")
    return (default, "default")


def coerce_option(key, raw, default=None):
    """Validate a userConfig value and return its coerced form, or refuse it.

    Refusal is loud on purpose: silently falling back to the default when someone
    explicitly configured a value would run their delegation on settings they did
    not ask for, and the bill would be the first sign. Raises ConfigError naming
    the key, the rejected value and what is allowed.
    """
    text = raw.strip() if isinstance(raw, str) else str(raw).strip()
    if key == "default_effort":
        if text in EFFORTS:
            return text
        raise ConfigError(
            "userConfig default_effort={!r} is not one of: {}".format(
                raw, ", ".join(EFFORTS)))
    if key == "max_rounds":
        # Digits only, matched in full: int() also accepts "+5", "1_0" and
        # non-ASCII digits, and a float branch once accepted "5.0" — a round cap
        # is a count, so anything that is not plain digits refuses.
        if re.fullmatch(r"[0-9]+", text) is None:
            raise ConfigError(
                "userConfig max_rounds={!r} is not an integer within {}..{}".format(
                    raw, MAX_ROUNDS_MIN, MAX_ROUNDS_MAX))
        value = int(text)
        if not (MAX_ROUNDS_MIN <= value <= MAX_ROUNDS_MAX):
            raise ConfigError(
                "userConfig max_rounds={!r} is not an integer within {}..{}".format(
                    raw, MAX_ROUNDS_MIN, MAX_ROUNDS_MAX))
        return value
    if key == "refuse_on_secrets":
        lowered = text.lower()
        if lowered in ("true", "1"):
            return True
        if lowered in ("false", "0"):
            return False
        raise ConfigError(
            "userConfig refuse_on_secrets={!r} is not a boolean: use true or false".format(raw))
    if key in ("default_model", "worktree_root"):
        if key == "worktree_root" and "'" in text:
            raise ConfigError(
                "userConfig worktree_root={!r} contains a single quote, which is "
                "not supported: the command lines pass it inside single quotes, "
                "so a quote in the value would end the quoting early".format(raw))
        return text
    # Unknown keys keep the historical type-based behaviour, except a bad int now
    # refuses instead of silently keeping the default.
    if isinstance(default, bool):
        return text.lower() not in ("0", "false", "no", "off")
    if isinstance(default, int):
        try:
            return int(text)
        except ValueError:
            raise ConfigError(
                "userConfig {}={!r} is not an integer".format(key, raw))
    return raw


def resolve_worktree_root(repo: Path, raw) -> Path:
    """Where task worktrees live for `repo`, honouring a configured root.

    None or "" means unset, which keeps the historical default beside the repo.
    A relative path joins against `repo`, never the cwd: the cwd resets between
    agent tool calls, so resolving there would scatter worktrees across whatever
    directory happened to be current. A root equal to the repo or inside it would
    remove the isolation --untracked worktree metadata inside the checkout that
    then shows up as dirt -- so it is refused rather than created.
    """
    repo = Path(repo)
    if isinstance(raw, str) and "'" in raw:
        raise ConfigError(
            "userConfig worktree_root={!r} contains a single quote, which is "
            "not supported: the command lines pass it inside single quotes, "
            "so a quote in the value would end the quoting early".format(raw))
    if raw is None or (isinstance(raw, str) and raw.strip() == ""):
        return repo.parent / ".muse-fleet-wt-{}".format(repo.name)
    text = raw.strip() if isinstance(raw, str) else str(raw).strip()
    candidate = Path(os.path.expanduser(text))
    if not candidate.is_absolute():
        candidate = repo / candidate
    resolved = candidate.resolve()
    # Fold case on both sides when the repo's own filesystem ignores it:
    # realpath keeps the given case for a non-existent tail, so without the
    # fold `/tmp/x/RepoCase` and `/tmp/x/repocase/wts` compare as unrelated on
    # APFS and the inside-the-repo root is accepted.
    fold = _fs_case_insensitive(repo)
    anchored = _fs_compare_key(repo.resolve(), fold)
    got = _fs_compare_key(resolved, fold)
    if got == anchored or got.startswith(anchored + os.sep):
        raise ConfigError(
            "userConfig worktree_root={!r} resolves to {!r}, which is the repository "
            "itself or inside it; worktrees there would dirty the checkout they are "
            "isolated from".format(raw, str(resolved)))
    return resolved


def _fs_case_insensitive(directory: Path) -> bool:
    """Whether `directory` lives on a case-insensitive filesystem, by probing it.

    Platform checks lie here: macOS APFS is case-insensitive by default while
    Linux ext4 is not, and either can be reformatted. So swap the case of the
    deepest path component containing a letter — if the swapped spelling exists
    and is the same directory, the filesystem folds case. A path with no letters
    anywhere cannot be case-swapped, so treat it as case-sensitive.
    """
    try:
        current = Path(os.path.realpath(directory))
    except OSError:
        return False
    parts = list(current.parts)
    for i in range(len(parts) - 1, -1, -1):
        if any(ch.isalpha() for ch in parts[i]):
            swapped = list(parts)
            swapped[i] = parts[i].swapcase()
            probe = os.path.join(*swapped)
            try:
                if os.path.isdir(probe) and os.path.samefile(probe, str(current)):
                    return True
            except OSError:
                return False
            return False
    return False


def _fs_compare_key(path: Path, fold_case: bool) -> str:
    """The string two paths are compared by when testing containment.

    realpath first so different spellings of the same directory compare equal,
    then normcase for Windows separators, then a casefold when the caller found
    the repo's filesystem case-insensitive.
    """
    key = os.path.normcase(os.path.realpath(path))
    return key.casefold() if fold_case else key


MAX_ROUNDS_MIN = 1
MAX_ROUNDS_MAX = 10
DEFAULT_EFFORT = "low"
# Must stay below the Bash tool's 600s ceiling. Otherwise the tool kills the parent
# mid-round and the worker outlives it. Long rounds belong in `run_in_background`.
DEFAULT_TIMEOUT = 540
EFFORTS = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

# Junk an agent creates while verifying its work. Harvesting with `git add -A` sweeps
# all of it into the patch -- one observed run buried a 1-file change under 1,057
# venv files and a 14MB diff.
DEFAULT_EXCLUDES = [
    ".venv", "venv", "env", "__pycache__", ".pytest_cache", ".mypy_cache",
    ".ruff_cache", ".tox", "node_modules", ".gradle", "target", "dist", "build",
    ".DS_Store", "*.pyc", "*.log", ".coverage", "htmlcov", ".muse",
]

# Local files git deliberately does not track. A fresh worktree has none of them, so an
# agent lands in a repo it cannot configure or run -- and helpfully rebuilds what it
# thinks is missing (this is where stray .venv directories come from).
COMMON_LOCAL = [".env", ".env.local", ".env.development", "node_modules", ".venv"]


# ------------------------------------------------------------------ catalog

def catalog_rows():
    """Every model row muse knows about. Muse refreshes these files itself on each run,
    so they track the provider rather than this script's release date."""
    rows = []
    for f in glob.glob(os.path.expanduser(CATALOG_GLOB)):
        try:
            rows.extend(json.load(open(f, encoding="utf-8")).get("rows") or [])
        except (OSError, ValueError, AttributeError):
            continue
    return rows


def resolve_model(requested: str):
    """Map the LATEST sentinel onto the newest visible contributor model.

    Returns (model_id, how_it_was_chosen). Contributor models are the discounted tier;
    picking the newest by release_date means a future muse-spark-1.4-contributor is used
    the day it appears, with no edit here. Falls back to a known-good id if the catalog
    is missing or unreadable -- a stale pick beats refusing to run."""
    if requested != LATEST:
        return requested, "explicit"

    cands = [
        r for r in catalog_rows()
        if isinstance(r.get("model_id"), str)
        and r["model_id"].endswith("-contributor")
        and r.get("visibility", "visible") == "visible"
    ]
    if not cands:
        return FALLBACK_MODEL, "fallback (no catalog found)"

    # Newest release wins; is_default breaks ties on a same-day release.
    cands.sort(key=lambda r: (str(r.get("release_date") or ""), bool(r.get("is_default"))),
               reverse=True)
    best = cands[0]
    return best["model_id"], "latest contributor (released {})".format(best.get("release_date"))


def parse_answers(text: str):
    """Return the last complete JSON object in `text`, or None.

    Muse can emit several final answers concatenated with no separator -- an agent
    that answers, notices a problem, fixes it and answers again produces
    `{...}{...}`, which json.loads rejects with "Extra data". The last object is the
    one that reflects the finished work."""
    dec, idx, last = json.JSONDecoder(), 0, None
    text = text.strip()
    while idx < len(text):
        try:
            obj, end = dec.raw_decode(text, idx)
        except ValueError:
            break
        last = obj
        idx = end
        while idx < len(text) and text[idx] in " \t\r\n":
            idx += 1
    return last


# ---------------------------------------------------------------- git helpers

def git(repo: Path, *args: str, **kw) -> str:
    check = kw.pop("check", True)
    r = subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True, text=True, encoding="utf-8", errors="replace",
    )
    if check and r.returncode != 0:
        raise RuntimeError("git {} failed: {}".format(" ".join(args), r.stderr.strip()))
    return r.stdout.strip()


def drop_worktree(repo: Path, wt: Path, branch: str, force_branch: bool = True) -> None:
    """Tear down a worktree and its branch, tolerating every half-state git can leave.

    A branch cannot be deleted while some worktree still has it checked out, and a
    worktree whose directory was removed by hand lingers in git's metadata until it is
    pruned. Handling both is what makes re-running safe."""
    subprocess.run(["git", "-C", str(repo), "worktree", "remove", "--force", str(wt)],
                   capture_output=True, text=True)
    subprocess.run(["git", "-C", str(repo), "worktree", "prune"], capture_output=True)
    # Any other worktree still holding this branch would block the delete.
    listing = subprocess.run(["git", "-C", str(repo), "worktree", "list", "--porcelain"],
                             capture_output=True, text=True,
                             encoding="utf-8", errors="surrogateescape").stdout
    path = None
    for line in listing.splitlines():
        if line.startswith("worktree "):
            path = line.split(" ", 1)[1]
        elif line.strip() == "branch refs/heads/{}".format(branch) and path:
            subprocess.run(["git", "-C", str(repo), "worktree", "remove", "--force", path],
                           capture_output=True)
    subprocess.run(["git", "-C", str(repo), "worktree", "prune"], capture_output=True)
    subprocess.run(["git", "-C", str(repo), "branch",
                    "-D" if force_branch else "-d", branch], capture_output=True)


def collision(repo: Path, wt: Path, branch: str, patch: Path = None,
              ours_branch: bool = False):
    """None when it is safe to (re)create `wt` on `branch`, else
    {"kind": "branch"|"worktree"|"patch", "path": str, "reason": str}."""
    # A re-run must not inherit a previous attempt's tree. But dropping
    # unconditionally ends in `git branch -D`, which discards unmerged commits without
    # asking -- and this branch name can collide with one that is not ours (a re-used
    # --out after its worktree dir vanished, same --id and --stamp under a different
    # --out, or any pre-existing branch of that name). Refusing keeps the commit.
    if not ours_branch and git(repo, "rev-parse", "--verify", "--quiet", branch,
                               check=False).strip():
        return {"kind": "branch", "path": branch,
                "reason": "branch {} already exists. Removing it would discard any "
                          "unmerged commits on it.".format(branch)}
    # The branch check above catches a name collision, and it is not the same question.
    # A live worktree can sit at this path under a DIFFERENT branch -- another run with
    # --branch-prefix, a branch someone renamed, a stamp passed in explicitly -- and
    # drop_worktree would force-remove it along with whatever was in flight there.
    if wt.exists() and any(wt.iterdir()):
        return {"kind": "worktree", "path": str(wt),
                "reason": "worktree {} already exists and is not empty. Removing it "
                          "would destroy that run's in-flight work.".format(wt)}
    # A harvested patch.diff is the only copy of the work once the worktree and branch
    # are gone (--cleanup). Overwriting it loses work nobody may have applied yet, so a
    # non-empty patch blocks a re-run on its own. An empty patch is not work.
    if patch is not None and patch.exists():
        try:
            nonempty = patch.stat().st_size > 0
        except OSError:
            nonempty = False
        if nonempty:
            return {"kind": "patch", "path": str(patch),
                    "reason": "{} already exists and is not empty; overwriting it "
                              "would lose a harvested patch nobody may have applied "
                              "yet.".format(patch)}
    return None


def seed_worktree(repo: Path, wt: Path, copies, links):
    """Bring untracked-but-needed files into a fresh worktree.

    Copy small config (.env) so each agent gets its own and cannot contaminate the
    original. Symlink heavy directories (node_modules, .venv) so N worktrees do not cost
    N installs -- but only when nothing will write to them, since concurrent installs
    into one shared directory corrupt it."""
    done = []
    for rel in copies or []:
        src, dst = repo / rel, wt / rel
        if not src.exists() or dst.exists():
            continue
        try:
            if src.is_dir():
                shutil.copytree(src, dst, symlinks=True, dirs_exist_ok=True)
            else:
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dst)
            done.append("copied {}".format(rel))
        except OSError as e:
            done.append("FAILED to copy {}: {}".format(rel, e))
    for rel in links or []:
        src, dst = repo / rel, wt / rel
        if not src.exists() or dst.exists():
            continue
        try:
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.symlink_to(src.resolve(), target_is_directory=src.is_dir())
            done.append("linked {}".format(rel))
        except OSError as e:
            done.append("FAILED to link {}: {}".format(rel, e))
    return done


def preflight(repo: Path, require_clean: bool) -> str:
    """Fail loudly before spawning anything. A run that dies halfway leaves worktrees
    behind, so it is much cheaper to refuse up front."""
    if shutil.which("muse") is None:
        raise PreflightError("muse not found on PATH")
    try:
        git(repo, "rev-parse", "--git-dir")
    except Exception:
        raise PreflightError(
            "{} is not a git repository (worktree isolation requires git)".format(repo))

    # Written BEFORE the dirty check below: briefs staged under <repo>/.muse-fleet/
    # exist before the first `run`, and the dirty check reads through this very
    # exclude -- so excluding after checking refused a clean repo for carrying the
    # brief it was told to carry.
    # Worktrees created under the repo would otherwise show up as untracked noise.
    # In a linked worktree .git is a file, so the exclude lives in the common dir,
    # which git applies to every worktree sharing it.
    excl = exclude_path(repo)
    if excl is None:
        excl = repo / ".git" / "info" / "exclude"
    try:
        cur = excl.read_text(encoding="utf-8") if excl.exists() else ""
        add = [p for p in (".muse/", ".muse-fleet/") if p not in cur]
        if add:
            excl.parent.mkdir(parents=True, exist_ok=True)
            excl.write_text(cur.rstrip("\n") + "\n" + "\n".join(add) + "\n", encoding="utf-8")
    except OSError as e:
        print("muse: could not update {} ({}); later runs may be refused as dirty".format(
            excl, e), file=sys.stderr)

    dirty = git(repo, "status", "--porcelain", check=False)
    if dirty and require_clean:
        raise PreflightError(
            "working copy is dirty; commit/stash first, or pass --allow-dirty.\n"
            "Worktrees branch from a committed ref, so uncommitted work is invisible "
            "to the run and will look like the agents deleted it."
        )

    try:
        return git(repo, "rev-parse", "HEAD")
    except Exception:
        # A fresh `git init` with nothing committed. Worktrees branch from a committed
        # ref, so there is nothing to branch from -- say that rather than surfacing
        # git's "ambiguous argument 'HEAD'" as a traceback.
        raise PreflightError(
            "{} has no commits yet. Worktrees branch from a committed ref, so commit "
            "something before delegating.".format(repo))


def check_schema(path: str) -> None:
    """The Meta structured-output API rejects a schema whose `required` does not list
    every key in `properties` -- there is no such thing as an optional field. Catching
    that here turns a fleet-wide 400 into a one-line message before anything spawns."""
    try:
        sch = json.loads(Path(path).read_text(encoding="utf-8"))
    except Exception as e:
        raise PreflightError(
            "--schema {}: not readable/parseable JSON ({})".format(path, e))
    props = set((sch.get("properties") or {}).keys())
    req = set(sch.get("required") or [])
    if props - req:
        raise PreflightError(
            "--schema {}: every property must also appear in \"required\"; "
            "missing {}.\n"
            "The Meta API rejects optional fields in structured output.".format(
                path, sorted(props - req))
        )


def absent_locals(repo: Path, named):
    """Untracked files that exist in the repo but will be missing from a fresh worktree.

    Surfacing this before the run beats letting the agent rediscover it by failing to
    execute the verification command and then reporting success it never checked."""
    named = set(named or [])
    return [f for f in COMMON_LOCAL if (repo / f).exists() and f not in named]


# ------------------------------------------------------------- running muse

class PreflightError(Exception):
    """A refusal to start, carrying a message meant for the caller.

    Raised rather than sys.exit'd so the caller can honour its own output contract --
    muse_task promises exactly one JSON object on stdout, and a bare exit leaves the
    supervisor parsing an empty stream."""


class ConfigError(PreflightError):
    """A userConfig value that is set but unusable.

    Separate from a generic preflight failure so callers that grep for a refused
    configuration can tell "you configured it wrong" apart from "the machine is
    not ready". Never a silent fallback: running on defaults the user did not ask
    for would bill them for settings they explicitly overrode."""


# Used for a worktree directory name and a git branch component, so it has to be safe for
# both. A bare `--id ../../x` escaped the artifact root entirely and left the task
# invisible to `status`, which scans below that root.
TASK_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")


def validate_task_id(task_id: str) -> str:
    """Return the id, or raise PreflightError explaining why it is unusable."""
    if not task_id:
        raise PreflightError("task id is empty")
    if not TASK_ID_RE.match(task_id):
        raise PreflightError(
            "task id {!r} is not usable: it names a directory and a git branch, so it must "
            "start with a letter or digit and contain only letters, digits, dot, underscore "
            "or hyphen (max 64 chars). A path separator or '..' would place artifacts "
            "outside the artifact root, where `status` cannot see them.".format(task_id))
    # git refuses a ref ending in .lock, and that regex allows it through. Better a clear
    # refusal here than git's error three calls later. ("." and ".." cannot reach this:
    # the pattern already requires a leading letter or digit.)
    if task_id.endswith(".lock"):
        raise PreflightError(
            "task id {!r} cannot end in .lock: it becomes a git branch name".format(task_id))
    return task_id


def git_toplevel(start: Path):
    """The repository root containing `start`, or None if there is not one."""
    try:
        r = subprocess.run(["git", "-C", str(start), "rev-parse", "--show-toplevel"],
                           capture_output=True, text=True,
                           encoding="utf-8", errors="surrogateescape")
    except OSError:
        return None
    top = (r.stdout or "").strip()
    return Path(top) if r.returncode == 0 and top else None


def _git_abs_path(start: Path, *revparse_args: str):
    """Resolve one `git rev-parse` path to absolute, or None outside a repo.

    Newer git prints absolute paths with `--path-format=absolute`; older git
    ignores the flag and prints a relative path, which is relative to the cwd
    git ran in, so join it onto `start`. Retrying without the flag covers git
    too old to accept it. `.resolve()` matters because macOS /var is a symlink
    to /private/var, so unresolved paths compare unequal."""
    for flag in (("--path-format=absolute",), ()):
        try:
            r = subprocess.run(
                ["git", "-C", str(start), "rev-parse", *flag, *revparse_args],
                capture_output=True, text=True,
                encoding="utf-8", errors="surrogateescape")
        except OSError:
            return None
        if r.returncode != 0:
            continue
        out = (r.stdout or "").strip()
        if not out:
            continue
        p = Path(out)
        if not p.is_absolute():
            p = start / p
        return p.resolve()
    return None


def owning_repo(start: Path):
    """The main checkout owning `start`, or None if `start` is not in a git repo.

    A task worktree and a linked worktree share the owning repo's common dir,
    so `--show-toplevel` would return the worktree itself and lose the task.
    When the common dir's basename is `.git` its parent is the main checkout;
    otherwise (bare repo, submodule, `--separate-git-dir`) fall back to
    `git_toplevel`."""
    common = _git_abs_path(start, "--git-common-dir")
    if common is None:
        return None
    if common.name == ".git":
        return common.parent
    return git_toplevel(start)


def exclude_path(repo: Path):
    """The `info/exclude` file git actually consults for `repo`, or None."""
    return _git_abs_path(repo, "--git-path", "info/exclude")


def session_workspace(session_id: str):
    """The workspace root a session is bound to, or None if it cannot be determined.

    Muse records this per session and REFUSES to resume in a different workspace --
    "session X was created in workspace A; refusing to resume in workspace B". Critically
    it fails the whole run rather than starting fresh, so a resume that would be refused
    costs a round and produces nothing. Read it from the newest snapshot; the key is
    nested, so match the text rather than assuming a shape that may change."""
    base = (Path(os.path.expanduser(MUSE_DATA_DIR)) / "sessions"
            / ".msp-view-v1" / session_id)
    # stat() each candidate defensively instead of inside a sort key. Muse rotates these
    # snapshots, so one can vanish between the glob and the stat -- and a sort key that
    # raises would send FileNotFoundError straight out of cmd_revise as a traceback,
    # breaking the one-JSON-object-on-stdout contract a supervisor parses.
    dated = []
    if base.is_dir():
        try:
            candidates = list(base.glob("snapshot-*.json"))
        except OSError:
            candidates = []
        for f in candidates:
            try:
                dated.append((f.stat().st_mtime, f))
            except OSError:
                continue    # rotated away mid-walk; the next snapshot will do
    snaps = [f for _, f in sorted(dated, key=lambda pair: pair[0], reverse=True)]
    for f in snaps:
        try:
            m = re.search(r'"workspaceRoot"\s*:\s*"([^"]+)"', f.read_text(encoding="utf-8"))
        except OSError:
            continue
        if m:
            return m.group(1)
    return None


def session_exists(session_id: str, workspace=None) -> bool:
    """Can this session actually be resumed, here?

    Two distinct ways a resume goes wrong, and neither surfaces as a clean error:

    - The session is unknown. Muse silently starts a fresh conversation, so a revision
      that assumed continuity arrives as bare feedback with no brief behind it -- the
      confidently-wrong-work failure this plugin exists to avoid.
    - The session exists but belongs to another workspace. Muse refuses and the run dies
      with no run_terminal record, burning a round for nothing.

    Treating both as "not resumable" routes them to the fallback that re-sends the brief,
    which is correct in both cases."""
    if not session_id:
        return False
    base = Path(os.path.expanduser(MUSE_DATA_DIR)) / "sessions"
    # The dated tree is the durable copy; the view index is derived from it.
    have_view = (base / ".msp-view-v1" / session_id).is_dir()
    if not have_view and not any(base.glob("*/*/*/" + session_id)):
        return False
    if workspace:
        recorded = session_workspace(session_id)
        if recorded is None:
            # Fail CLOSED, and only here. `if recorded and ...` used to fall through to
            # True: a view directory that survives a schema change with `workspaceRoot`
            # renamed reads as "no constraint" rather than "cannot tell". Muse then
            # refuses the cross-workspace resume, the round dies with no run_terminal
            # record, and a round is spent producing nothing -- verbatim the failure the
            # docstring above says this routes around. The fallback re-sends the brief,
            # which costs context and never costs a round.
            #
            # A session known ONLY from the dated tree has no snapshot to read, so this
            # is not the same question and it is not treated as one.
            return not have_view
        if os.path.realpath(recorded) != os.path.realpath(str(workspace)):
            return False
    return True


def new_session_id() -> str:
    return str(uuid.uuid4())


def muse_cmd(model, effort, wt: Path, schema=None, max_steps=0, inherit_skills=False,
             session_id=None):
    """The muse invocation both entry points use.

    --yolo is defensible only because the blast radius is a throwaway worktree; keep
    that property or this flag becomes indefensible."""
    cmd = [
        "muse", "exec", "--json",
        "--model", model,
        "--reasoning-effort", effort,
        "--worktree", "off", "--workspace", str(wt),
        "--user-input-auto-resolve",   # never block on an interactive prompt
        "--yolo",                      # safe *because* the blast radius is this worktree
    ]
    if session_id:
        # Reusing the id across invocations continues the conversation, so a later round
        # still has the brief, the files it read and its own reasoning in context.
        cmd += ["--session-id", session_id]
    if not inherit_skills:
        # Muse imports Claude Code personal skills by default, which means a run can
        # load the very skill that launched it. Keep workers on the task in front of
        # them rather than re-deriving the orchestration playbook.
        cmd.append("--no-foreign-personal-context")
    if schema:
        cmd += ["--output-schema", str(Path(schema).resolve())]
    if max_steps:
        cmd += ["--max-model-steps", str(max_steps)]
    return cmd


# ---------------------------------------------------------------- secret scanning

# Two tiers on purpose. CERTAIN patterns are structurally unmistakable -- a provider's
# own key format, or a PEM header -- so a hit is worth stopping for. POSSIBLE patterns
# are assignments that merely look credential-shaped; they matter for a human to glance
# at, but blocking on them would make the plugin unusable on any repo with test
# fixtures. Reporting them as one undifferentiated pile would train people to ignore all
# of it, which is worse than not scanning.
CERTAIN_PATTERNS = [
    ("private key block", re.compile(r"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----")),
    ("AWS access key id", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("GitHub token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}\b")),
    ("Slack token", re.compile(r"\bxox[baprs]-[0-9A-Za-z-]{10,}\b")),
    ("Google API key", re.compile(r"\bAIza[0-9A-Za-z_\-]{35}\b")),
    ("Stripe live key", re.compile(r"\b[rs]k_live_[0-9a-zA-Z]{20,}\b")),
    ("Anthropic API key", re.compile(r"\bsk-ant-[A-Za-z0-9_\-]{20,}")),
    ("OpenAI-style API key", re.compile(r"\bsk-(?!ant-)[A-Za-z0-9_\-]{32,}")),
    ("GitHub fine-grained token", re.compile(r"\bgithub_pat_[A-Za-z0-9_]{22,}")),
    ("PGP private key block", re.compile(r"-----BEGIN PGP PRIVATE KEY BLOCK-{5}")),
    ("AWS secret access key", re.compile(r"(?i)\baws_secret_access_key\b\s*[:=]\s*['\"]?[A-Za-z0-9/+]{40}(?![A-Za-z0-9/+])")),
]

POSSIBLE_PATTERNS = [
    ("credential-shaped assignment", re.compile(
        r"(?i)\b(?:api[_-]?key|secret|passwd|password|access[_-]?token|auth[_-]?token)\b"
        r"\s*[:=]\s*['\"][^'\"\s]{12,}['\"]")),
]

SCAN_MAX_BYTES = 1_000_000     # a file larger than this is not hand-written config
# Bound the walk -- a fan-out runs this per task -- but 5000 was too low to be honest
# about: `scanned` counts successfully decoded TEXT files, so it is a count of source
# files, and a mid-size repo passes it. Truncation is now stated wherever the result is
# reported, which matters more than the number. Overridable so the truncation path can
# be exercised without synthesising 20k files.
SCAN_MAX_FILES = int(os.environ.get("MUSE_SCAN_MAX_FILES", "20000"))


class ScanError(Exception):
    """The credential scan could not run because the file listing is unknown.

    Not a PreflightError: callers fail closed on it (refuse the task) rather
    than treating it as a misconfigured value. Kept separate so --allow-secrets
    (which waives a confirmed credential) cannot waive an unknown tree.
    """


def worker_files(root) -> list:
    """Everything a process whose cwd is `root` can read.

    Driven by git, not by a walk with a skip list: the harvest skip list answers
    "what goes into the patch", a different question from "what can the worker
    read". Gitignored files are included on purpose -- a --yolo worker reads
    those too. Falls back to the whole directory when git cannot answer.
    """
    root = Path(root)
    try:
        r = subprocess.run(
            ["git", "-C", str(root), "ls-files", "-z", "--cached", "--others"],
            capture_output=True, timeout=30)
    except subprocess.TimeoutExpired:
        # No fallback to the whole directory: that would scan an unknown set of
        # files and report a clean verdict on it. The caller fails closed.
        raise ScanError(
            "git ls-files timed out after 30s listing {}, so what the worker "
            "can read is unknown and the credential scan could not run".format(root))
    except OSError:
        return [Path(root)]
    if r.returncode != 0:
        return [Path(root)]
    out = []
    for entry in r.stdout.decode("utf-8", "surrogateescape").split("\0"):
        if not entry:
            continue
        if entry.split("/", 1)[0] == ".git":
            continue
        if not os.path.lexists(os.path.join(str(root), entry)):
            continue    # tracked upstream but deleted in this worktree
        p = Path(root) / entry
        out.append(p if not entry.endswith("/") else Path(os.path.join(str(root), entry)))
    return out


def _expand_paths(root, paths):
    """Yield every file under `paths`, following links into what the worker can read.

    Only .git is pruned -- everything else (build/, env/, node_modules/, dotfiles)
    is readable from the worktree. Directories already visited by real path are
    skipped so a symlink cycle terminates.
    """
    seen = set()
    for p in paths or []:
        p = Path(p)
        if os.path.isdir(p):
            for dirpath, dirnames, filenames in os.walk(p, followlinks=True):
                rp = os.path.realpath(dirpath)
                if rp in seen:
                    dirnames[:] = []
                    continue
                seen.add(rp)
                dirnames[:] = [d for d in dirnames
                               if d != ".git"
                               and os.path.realpath(os.path.join(dirpath, d)) not in seen]
                for name in filenames:
                    yield Path(dirpath) / name
        else:
            yield p


def scan_secrets(root: Path, max_files: int = SCAN_MAX_FILES, paths=None):
    """Look for credentials in the tree a worker is about to be able to read.

    This exists because contributor-tier models state that content "may be used for
    product improvement", and that is not undoable once sent. The plugin documented that
    risk and gave no way to act on it.

    Returns {"certain": [...], "possible": [...], "files_scanned": n, "truncated": bool}.
    Each finding is {file, line, kind} -- never the matched text, which would copy the
    secret into an artifact that then gets read and shared.
    """
    certain, possible, scanned, truncated = [], [], 0, False
    root = Path(root)
    if paths is None:
        paths = worker_files(root)
    for f in _expand_paths(root, paths):
        if scanned >= max_files:
            truncated = True
            return {"certain": certain, "possible": possible,
                    "files_scanned": scanned, "truncated": truncated}
        try:
            if not os.path.isfile(f) or os.path.getsize(f) > SCAN_MAX_BYTES:
                continue
            with open(f, encoding="utf-8", errors="strict") as fh:
                text = fh.read()
        except (OSError, ValueError, UnicodeDecodeError):
            continue    # binary or unreadable: not hand-written config
        scanned += 1
        try:
            rel = os.path.relpath(str(f), str(root))
        except ValueError:
            rel = str(f)
        for i, line in enumerate(text.splitlines(), 1):
            if len(line) > 4000:
                continue    # minified bundle; not where a human puts a key
            for kind, rx in CERTAIN_PATTERNS:
                if rx.search(line):
                    certain.append({"file": rel, "line": i, "kind": kind})
            for kind, rx in POSSIBLE_PATTERNS:
                if rx.search(line):
                    possible.append({"file": rel, "line": i, "kind": kind})
    return {"certain": certain, "possible": possible,
            "files_scanned": scanned, "truncated": truncated}


def preflight_secrets(paths, opts):
    """One credential gate every driver calls before spawning a worker.

    `paths` lists the directories a worker process could read; `opts` carries
    allow_secrets/no_secret_scan. Merges the per-root scans into one verdict.
    """
    opts = opts or {}
    if opts.get("no_secret_scan"):
        return {"refuse": False, "skipped": True, "certain": [], "possible": [],
                "files_scanned": 0, "truncated": False, "reason": None}
    certain, possible, scanned, truncated = [], [], 0, False
    for root in paths or []:
        try:
            r = scan_secrets(root)
        except ScanError as e:
            # Fail closed even when allow_secrets is true: that flag waives a
            # confirmed credential, not delegation without a scan.
            return {"refuse": True, "skipped": False, "certain": certain,
                    "possible": possible, "files_scanned": scanned,
                    "truncated": truncated,
                    "reason": "{}; pass --no-secret-scan to skip the scan".format(e)}
        certain += r["certain"]
        possible += r["possible"]
        scanned += r["files_scanned"]
        truncated = truncated or r["truncated"]
    scan = {"certain": certain, "possible": possible,
            "files_scanned": scanned, "truncated": truncated}
    refuse = bool(scan["certain"]) and not opts.get("allow_secrets")
    reason = None
    if refuse:
        partial = (" The scan stopped at {} files and did NOT cover the whole tree, so "
                   "this count is a floor, not a total.".format(scan["files_scanned"])
                   if scan["truncated"] else "")
        reason = ("{} credential(s) found in the tree this worker would be able "
                  "to read. Sending them to a contributor-tier model is not "
                  "undoable. Remove them from what the worker can read (tracked, "
                  "seeded, linked, or ignored files in its working directory), "
                  "or pass --allow-secrets if they are fake.{}"
                  .format(len(scan["certain"]), partial))
    return {"refuse": refuse, "skipped": False, "certain": certain,
            "possible": possible, "files_scanned": scanned,
            "truncated": truncated, "reason": reason}


# os.killpg, os.getpgid and signal.SIGKILL are POSIX-only -- on Windows they do not
# exist as attributes at all, so touching them raises AttributeError rather than OSError.
# Resolve the capability once, at import, instead of discovering it inside a timeout
# handler where the failure would mask the timeout it was called to handle.
HAVE_PROCESS_GROUPS = (hasattr(os, "killpg") and hasattr(os, "getpgid")
                       and hasattr(signal, "SIGKILL"))

# Popen objects of running muse children. A plain list, mutated only with
# append/remove, which are atomic under the GIL. No Lock: the signal handler runs on
# the main thread and may interrupt code holding such a lock, which deadlocks. The
# handler reads a snapshot _LIVE[:].
_LIVE = []
_SHUTDOWN = threading.Event()


def _taskkill_tree(pid) -> bool:
    """Kill a Windows process and every descendant. There are no process groups there,
    and TerminateProcess (p.kill) reaches only the direct child -- a .cmd shim's shell
    and whatever it started keep running and writing into the worktree."""
    try:
        return subprocess.run(["taskkill", "/F", "/T", "/PID", str(pid)],
                              capture_output=True, text=True,
                              encoding="utf-8", errors="replace").returncode == 0
    except OSError:
        return False


def _signal_group(p) -> None:
    """SIGKILL the child's process group without waiting.

    The pgid equals p.pid because of start_new_session=True. Do not call getpgid:
    the pid may already be reaped. Never calls p.wait(): Popen's internal
    _waitpid_lock is not re-entrant, and the main thread may be inside p.wait()
    when the signal lands.
    """
    if HAVE_PROCESS_GROUPS:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
    elif os.name == "nt" and _taskkill_tree(p.pid):
        return
    else:
        try:
            p.kill()
        except OSError:
            pass


def install_signal_handlers(interrupt=False) -> None:
    """Forward termination signals to every running muse child, then die loudly.

    With interrupt=True the handler raises KeyboardInterrupt; otherwise it raises
    SystemExit(128 + signum).
    """
    for name in ("SIGTERM", "SIGINT", "SIGHUP"):
        if not hasattr(signal, name):
            continue
        signum = getattr(signal, name)

        def _handler(sig, _frame, _signum=signum, _interrupt=interrupt):
            _SHUTDOWN.set()
            for child in _LIVE[:]:
                _signal_group(child)
            if _interrupt:
                raise KeyboardInterrupt
            raise SystemExit(128 + _signum)

        signal.signal(signum, _handler)


def muse_version():
    """The version string `muse --version` reports, or None if it cannot be obtained.

    Parsed out rather than compared whole: the line carries more than the number, and
    the number is the only part with a stable meaning."""
    try:
        r = subprocess.run([shutil.which("muse") or "muse", "--version"],
                           capture_output=True, text=True,
                           encoding="utf-8", errors="replace", timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    m = re.search(r"(\d+)\.(\d+)\.(\d+)", (r.stdout or r.stderr or ""))
    return m.group(0) if m else None


def version_mismatch(found):
    """A one-line note if `found` is a different muse line than the tested one, else None.

    Major.minor only. A patch bump that renames an event key would be a bug in muse, and
    warning on every patch release would train the reader to ignore the warning."""
    if not found:
        return None
    a = found.split(".")[:2]
    b = MUSE_TESTED_VERSION.split(".")[:2]
    if a == b:
        return None
    return ("this plugin is verified against muse {}; you have {}. The event schema, the "
            "`exec` flags and the session layout are all coupled, and a rename in any of "
            "them shows up as every round failing identically."
            .format(MUSE_TESTED_VERSION, found))


def kill_process_tree(p) -> None:
    """Kill a child and everything it spawned, as far as the platform allows.

    p.kill() signals only the direct child. Anything it started -- npm, pytest, a build
    -- survives, keeps writing into the worktree and keeps costing money after the
    timeout has been declared. Where process groups exist we signal the whole group; on
    Windows, which has none, `taskkill /T` walks the parent-child table instead. Only if
    both are unavailable does this degrade to the direct child.
    """
    killed_group = False
    if HAVE_PROCESS_GROUPS:
        try:
            os.killpg(os.getpgid(p.pid), signal.SIGKILL)
            killed_group = True
        except (ProcessLookupError, PermissionError, OSError):
            pass
    elif os.name == "nt":
        # `taskkill /T` has to run while the parent is still alive: it finds children by
        # walking parent ids, so killing the shell first orphans them beyond its reach.
        # This is the difference between a hung build dying with its timeout and one that
        # keeps writing into a worktree `finish --cleanup` is about to force-remove.
        killed_group = _taskkill_tree(p.pid)
    if not killed_group:
        try:
            p.kill()
        except (OSError, AttributeError):
            # AttributeError is belt-and-braces: Popen.kill uses SIGKILL on POSIX and
            # TerminateProcess on Windows, so it should always resolve -- but a partially
            # stubbed platform must not turn a timeout into a crash.
            pass
    try:
        p.wait(timeout=10)
    except Exception:
        pass


# Linux caps ONE argv string at 128 KiB (MAX_ARG_STRLEN). Windows caps the whole
# CreateProcess command line at 32767 chars. Over this size the prompt goes through
# `muse exec --prompt-file`, which muse 1.3.0 supports and which cannot be combined
# with an inline prompt.
PROMPT_ARG_MAX_BYTES = 16 * 1024


def run_muse(cmd, prompt: str, cwd: Path, events: Path, stderr: Path, timeout: int,
             on_spawn=None):
    """Run one muse round to completion. Returns a dict of what the event stream said.

    Started IN the worktree: a --yolo process can read everything under its cwd,
    and only the worktree is scanned, so the main repo must never be the cwd."""
    import time as _time
    started = _time.time()
    out = {"status": "completed", "reason": None, "model_actual": None,
           "text": "", "elapsed_s": 0.0, "exit_code": None, "stderr_tail": ""}

    if _SHUTDOWN.is_set():
        out["status"] = "interrupted"
        out["reason"] = "not started: the parent received a termination signal"
        out["elapsed_s"] = round(_time.time() - started, 1)
        return out

    events.parent.mkdir(parents=True, exist_ok=True)
    with events.open("w", encoding="utf-8") as fo, stderr.open("w", encoding="utf-8") as fe:
        # Its own session, so a timeout can signal the whole tree. A --yolo muse run
        # spawns builds and test runners; killing only the direct child leaves those
        # writing into a worktree we are about to delete, and still spending.
        # Popen uses CreateProcess on Windows, which never consults PATHEXT: a muse
        # installed as a .cmd shim is FileNotFoundError under its bare name even though
        # shutil.which (what preflight checks) resolves it. Resolve the same way first.
        exe = shutil.which(cmd[0]) or cmd[0]
        data = prompt.encode("utf-8", "surrogateescape")
        if len(data) > PROMPT_ARG_MAX_BYTES:
            pf = events.with_name("prompt.txt")
            pf.write_bytes(data)
            argv = [exe, *cmd[1:], "--prompt-file", str(pf.resolve())]
        else:
            # muse parses a positional that starts with '-' as an option and refuses
            # it ("unknown option - fix it", measured), so `--` must precede the prompt.
            argv = [exe, *cmd[1:], "--", prompt]
        try:
            p = subprocess.Popen(argv, cwd=str(cwd), stdout=fo, stderr=fe,
                                 start_new_session=True)
        except OSError as e:
            out["status"] = "spawn_failed"
            out["reason"] = "could not start muse: {}".format(e)
            out["elapsed_s"] = round(_time.time() - started, 1)
            return out
        _LIVE.append(p)
        try:
            # A signal may have arrived between the shutdown check and the spawn; the
            # handler cannot see a child it does not know about, so re-check now that
            # the child is registered.
            if _SHUTDOWN.is_set():
                _signal_group(p)
            try:
                if on_spawn:
                    on_spawn(p)
                # Sliced: on Windows one long wait is uninterruptible, so a termination
                # signal would not run its handler until the worker finished by itself.
                deadline = _time.time() + timeout
                while True:
                    left = deadline - _time.time()
                    if left <= 0:
                        raise subprocess.TimeoutExpired(cmd, timeout)
                    try:
                        p.wait(timeout=min(left, 0.5))
                        break
                    except subprocess.TimeoutExpired:
                        continue
                out["exit_code"] = p.returncode
            except subprocess.TimeoutExpired:
                kill_process_tree(p)
                out["status"] = "timeout"
                out["reason"] = "exceeded {}s".format(timeout)
            except BaseException:
                # The handler already SIGKILLed the group; reap it here, outside the
                # handler, where blocking is safe.
                kill_process_tree(p)
                raise
        finally:
            try:
                _LIVE.remove(p)
            except ValueError:
                pass
    out["elapsed_s"] = round(_time.time() - started, 1)
    if _SHUTDOWN.is_set():
        out["status"] = "interrupted"
        out["reason"] = ("the parent received a termination signal; "
                         "the worker's process group was killed")

    # muse's exit code and stderr are the only things that distinguish an unknown flag
    # from a bad model id from an expired credential -- and every one of those used to
    # come back as the same sentence, leaving a supervisor nothing to do but retry
    # blind, which this plugin's own guidance tells it not to do.
    try:
        tail = stderr.read_text(encoding="utf-8", errors="replace")
    except OSError:
        tail = ""
    out["stderr_tail"] = tail[-2000:].strip()

    if out["status"] in ("timeout", "interrupted"):
        return out

    # run_terminal is the single authoritative record; everything else is noise.
    term = None
    try:
        with events.open(encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    pl = json.loads(line).get(EV_PAYLOAD, {})
                except ValueError:
                    continue
                if pl.get(EV_KIND) == EV_TERMINAL:
                    term = pl
                elif pl.get(EV_KIND) == EV_MODEL_CONFIGURED:
                    out["model_actual"] = pl.get(EV_MODEL_ID)
    except OSError:
        pass

    if term is None:
        out["status"] = "no_terminal"
        if out["exit_code"]:
            out["reason"] = ("muse exited {} without a run_terminal record: {}".format(
                out["exit_code"],
                out["stderr_tail"].splitlines()[-1][:200] if out["stderr_tail"]
                else "nothing on stderr either"))
        elif out["stderr_tail"]:
            out["reason"] = ("muse exited 0 but produced no run_terminal record; stderr "
                             "says: {}".format(out["stderr_tail"].splitlines()[-1][:200]))
        else:
            out["reason"] = ("muse exited 0, wrote no run_terminal record and said "
                             "nothing on stderr -- most likely not Muse Code, or a "
                             "version whose event schema this plugin does not know")
    else:
        out["status"] = "completed" if term.get("terminal") == "completed" else "failed"
        out["reason"] = term.get("reason")
        out["text"] = term.get("text") or ""
    return out


def _excluded(path, excludes) -> bool:
    parts = path.split("/")
    prefixes = ["/".join(parts[:i]) for i in range(1, len(parts) + 1)]
    for raw in excludes or []:
        pat = raw.strip("/")
        if not pat:
            continue
        if "/" not in pat:
            for component in parts:
                if fnmatch.fnmatchcase(component, pat):
                    return True
        else:
            cands = {pat}
            s = pat
            while s.startswith("**/"):
                s = s[3:]
                cands.add(s)
            expanded = set(cands)
            for cand in list(cands):
                t = cand
                while t.endswith("/**"):
                    t = t[:-3]
                    expanded.add(t)
            for prefix in prefixes:
                for cand in expanded:
                    if cand and fnmatch.fnmatchcase(prefix, cand):
                        return True
    return False


def _split_nul(out: bytes):
    return [n.decode("utf-8", "surrogateescape") for n in out.split(b"\0") if n]


# Tracked files bypass excludes on purpose: an excluded tracked fix once produced an
# empty certified patch (issue #35), so excludes apply to untracked-at-base files only.
# Step 3 un-stages newly-added-but-excluded paths to cover junk the worker staged itself.
def stage_all(wt: Path, base: str, excludes):
    def _err(proc, cmd):
        msg = proc.stderr.decode("utf-8", "replace").strip()[:300]
        return msg or "{} exited {}".format(cmd, proc.returncode)

    add_u = subprocess.run(
        ["git", "-C", str(wt), "--literal-pathspecs", "add", "-u"],
        capture_output=True)
    if add_u.returncode != 0:
        return _err(add_u, "git add -u")
    ls = subprocess.run(
        ["git", "-C", str(wt), "--literal-pathspecs", "ls-files", "-z",
         "--others", "--exclude-standard"],
        capture_output=True)
    if ls.returncode != 0:
        return _err(ls, "git ls-files")
    fresh = [n for n in _split_nul(ls.stdout) if not _excluded(n, excludes)]
    for i in range(0, len(fresh), 200):
        chunk = [n.encode("utf-8", "surrogateescape") for n in fresh[i:i + 200]]
        if not chunk:
            continue
        add = subprocess.run(
            ["git", "-C", str(wt), "--literal-pathspecs", "add", "--", *chunk],
            capture_output=True)
        if add.returncode != 0:
            return _err(add, "git add")
    added = subprocess.run(
        ["git", "-C", str(wt), "--literal-pathspecs", "diff", "--cached",
         "--name-only", "-z", "--no-renames", "--diff-filter=A", base],
        capture_output=True)
    if added.returncode != 0:
        return _err(added, "git diff --cached --name-only")
    junk = [n for n in _split_nul(added.stdout) if _excluded(n, excludes)]
    for i in range(0, len(junk), 200):
        chunk = [n.encode("utf-8", "surrogateescape") for n in junk[i:i + 200]]
        if not chunk:
            continue
        rm = subprocess.run(
            ["git", "-C", str(wt), "--literal-pathspecs", "rm", "--cached", "-q",
             "--", *chunk],
            capture_output=True)
        if rm.returncode != 0:
            return _err(rm, "git rm --cached")
    return None


def _cached_diff(wt: Path, base: str, *extra):
    return subprocess.run(
        ["git", "-C", str(wt), "diff", "--cached", "--no-ext-diff", "--no-textconv",
         "--binary", "--full-index", *extra, base],
        capture_output=True)


def patch_fingerprint(wt: Path, base: str, excludes):
    """A hash of the patch this worktree currently produces, or None if it cannot be taken.

    This is what binds a verification to the thing it verified, and it deliberately
    fingerprints the PATCH rather than the worktree. A tree hash would move whenever an
    acceptance check dropped a `__pycache__` or a `.pytest_cache` -- churn that never
    reaches patch.diff -- and every such run would come back refused. The deliverable is
    the diff; certify the diff."""
    try:
        if stage_all(wt, base, excludes) is not None:
            return None
        diff = _cached_diff(wt, base)
        if diff.returncode != 0:
            return None
        return hashlib.sha256(diff.stdout).hexdigest()
    except Exception:
        return None


def harvest(wt: Path, base: str, excludes, patch_path: Path):
    """Stage everything and diff against base.

    Staging first is essential: muse leaves the worktree dirty and never commits, and a
    plain `git diff` silently omits newly created files -- a whole new test suite can
    read as "no changes"."""
    rec = {"patch_lines": 0, "files_changed": [], "harvest_error": None}
    try:
        # git's exit status matters here, and ignoring it is silent data loss: a missing
        # worktree, a held index.lock or a bad base ref all return rc!=0 with empty
        # stdout, which would overwrite a good patch.diff with an empty file and report
        # a clean zero-line result. The supervisor then reads a failure as "the worker
        # decided nothing needed doing".
        staging_error = stage_all(wt, base, excludes)
        if staging_error is not None:
            rec["harvest_error"] = "git add failed: {}".format(staging_error)
            return rec
        diff = _cached_diff(wt, base)
        if diff.returncode != 0:
            rec["harvest_error"] = "git diff failed: {}".format(
                diff.stderr.decode("utf-8", "replace").strip()[:300])
            return rec
        # Only now is it safe to replace whatever patch.diff already held.
        patch_path.parent.mkdir(parents=True, exist_ok=True)
        patch_path.write_bytes(diff.stdout)
        rec["patch_lines"] = diff.stdout.count(b"\n")
        names = _cached_diff(wt, base, "--name-only", "-z", "--no-renames")
        rec["files_changed"] = _split_nul(names.stdout) if names.returncode == 0 else []
    except Exception as e:
        rec["harvest_error"] = str(e)
    return rec


def commit_worktree(wt: Path, message: str) -> None:
    subprocess.run(
        ["git", "-C", str(wt), "-c", "user.email=muse@local", "-c", "user.name=muse",
         "commit", "-qm", message],
        capture_output=True,
    )


def events_path(repo) -> Path:
    """The one place the capability event stream path lives.

    The monitor and the status-line script import this rather than rebuilding
    the path, so a relocation changes one line instead of three files."""
    return Path(repo) / ".muse-fleet" / "events.jsonl"


def append_event(repo, event: dict) -> None:
    """Append one event to the repo's capability event stream, never raising.

    One json.dumps line in one os.write on an O_APPEND fd: parallel fleet
    tasks append at the same time, and anything less atomic interleaves.
    A full disk or a directory squatting on the path must never fail a paid
    round or stop it being recorded, so every failure is one stderr line.
    """
    try:
        ev = dict(event)
        ev["v"] = 1
        ev["ts"] = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
        data = (json.dumps(ev, separators=(",", ":")) + "\n").encode("utf-8")
        events_path(repo).parent.mkdir(parents=True, exist_ok=True)
        flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT
        if hasattr(os, "O_BINARY"):
            flags |= os.O_BINARY
        fd = os.open(str(events_path(repo)), flags, 0o666)
        try:
            os.write(fd, data)
        finally:
            os.close(fd)
    except (OSError, ValueError) as e:
        print("muse: could not append event ({}); continuing".format(e),
              file=sys.stderr)
