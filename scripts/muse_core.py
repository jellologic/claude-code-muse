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

import glob
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import uuid
import sys
from pathlib import Path

# Sentinel: resolve the newest contributor model from the live catalog at run time.
# Hard-coding a version is how a machine ends up silently a generation behind -- exactly
# what a stale `model` pin in ~/.config/muse/settings.json does.
LATEST = "latest-contributor"
FALLBACK_MODEL = "muse-spark-1.3-contributor"
# Overridable so model resolution can be tested anywhere, including a machine with no
# muse install. Without a seam the only way to test it is to trust whatever catalog
# happens to be on the host, which makes the result environment-dependent.
CATALOG_GLOB = os.environ.get(
    "MUSE_CATALOG_GLOB", "~/.local/share/muse/model-catalog/*.json")
MUSE_DATA_DIR = os.environ.get("MUSE_DATA_DIR", "~/.local/share/muse")

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
# wrong far more often than it was right.
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

def user_option(key, default):
    """A `userConfig` value if the runtime supplied one, else the built-in default.

    The runtime exports these to HOOKS as CLAUDE_PLUGIN_OPTION_<KEY>. Whether a Bash tool
    call in a session sees them is not documented and was not verified here, so this is a
    fallback rather than the mechanism -- the commands and the skill pass
    ${user_config.<key>} explicitly, which is the documented path.

    Every default below is what the plugin did before there was any configuration, so an
    install that skips the prompts behaves exactly as it used to. That is the property
    worth protecting: configuration should let someone change behaviour, never change it
    for someone who did not ask.
    """
    raw = os.environ.get("CLAUDE_PLUGIN_OPTION_" + key.upper())
    if raw is None or raw == "":
        return default
    if isinstance(default, bool):
        return raw.strip().lower() not in ("0", "false", "no", "off")
    if isinstance(default, int):
        try:
            return int(raw)
        except ValueError:
            return default
    return raw


DEFAULT_EFFORT = "low"
DEFAULT_TIMEOUT = 900
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
        capture_output=True, text=True,
    )
    if check and r.returncode != 0:
        raise RuntimeError("git {} failed: {}".format(" ".join(args), r.stderr.strip()))
    return r.stdout.strip()


def drop_worktree(repo: Path, wt: Path, branch: str) -> None:
    """Tear down a worktree and its branch, tolerating every half-state git can leave.

    A branch cannot be deleted while some worktree still has it checked out, and a
    worktree whose directory was removed by hand lingers in git's metadata until it is
    pruned. Handling both is what makes re-running safe."""
    subprocess.run(["git", "-C", str(repo), "worktree", "remove", "--force", str(wt)],
                   capture_output=True, text=True)
    subprocess.run(["git", "-C", str(repo), "worktree", "prune"], capture_output=True)
    # Any other worktree still holding this branch would block the delete.
    listing = subprocess.run(["git", "-C", str(repo), "worktree", "list", "--porcelain"],
                             capture_output=True, text=True).stdout
    path = None
    for line in listing.splitlines():
        if line.startswith("worktree "):
            path = line.split(" ", 1)[1]
        elif line.strip() == "branch refs/heads/{}".format(branch) and path:
            subprocess.run(["git", "-C", str(repo), "worktree", "remove", "--force", path],
                           capture_output=True)
    subprocess.run(["git", "-C", str(repo), "worktree", "prune"], capture_output=True)
    subprocess.run(["git", "-C", str(repo), "branch", "-D", branch], capture_output=True)


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

    dirty = git(repo, "status", "--porcelain", check=False)
    if dirty and require_clean:
        raise PreflightError(
            "working copy is dirty; commit/stash first, or pass --allow-dirty.\n"
            "Worktrees branch from a committed ref, so uncommitted work is invisible "
            "to the run and will look like the agents deleted it."
        )

    # Worktrees created under the repo would otherwise show up as untracked noise.
    excl = repo / ".git" / "info" / "exclude"
    try:
        cur = excl.read_text(encoding="utf-8") if excl.exists() else ""
        add = [p for p in (".muse/", ".muse-fleet/") if p not in cur]
        if add:
            excl.parent.mkdir(parents=True, exist_ok=True)
            excl.write_text(cur.rstrip("\n") + "\n" + "\n".join(add) + "\n", encoding="utf-8")
    except OSError:
        pass

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
                           capture_output=True, text=True)
    except OSError:
        return None
    top = (r.stdout or "").strip()
    return Path(top) if r.returncode == 0 and top else None


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
        "--worktree", "existing", "--worktree-existing", str(wt),
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
    ("Stripe live key", re.compile(r"\bsk_live_[0-9a-zA-Z]{20,}\b")),
    ("Anthropic API key", re.compile(r"\bsk-ant-[A-Za-z0-9_\-]{20,}")),
    ("OpenAI-style API key", re.compile(r"\bsk-[A-Za-z0-9]{32,}\b")),
]

POSSIBLE_PATTERNS = [
    ("credential-shaped assignment", re.compile(
        r"(?i)\b(?:api[_-]?key|secret|passwd|password|access[_-]?token|auth[_-]?token)\b"
        r"\s*[:=]\s*['\"][^'\"\s]{12,}['\"]")),
]

SCAN_SKIP_DIRS = set(DEFAULT_EXCLUDES) | {".git"}
SCAN_MAX_BYTES = 1_000_000     # a file larger than this is not hand-written config
# Bound the walk -- a fan-out runs this per task -- but 5000 was too low to be honest
# about: `scanned` counts successfully decoded TEXT files, so it is a count of source
# files, and a mid-size repo passes it. Truncation is now stated wherever the result is
# reported, which matters more than the number. Overridable so the truncation path can
# be exercised without synthesising 20k files.
SCAN_MAX_FILES = int(os.environ.get("MUSE_SCAN_MAX_FILES", "20000"))


def scan_secrets(root: Path, max_files: int = SCAN_MAX_FILES):
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
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SCAN_SKIP_DIRS]
        for name in filenames:
            if scanned >= max_files:
                truncated = True
                return {"certain": certain, "possible": possible,
                        "files_scanned": scanned, "truncated": truncated}
            f = Path(dirpath) / name
            try:
                if f.is_symlink() or not f.is_file() or f.stat().st_size > SCAN_MAX_BYTES:
                    continue
                text = f.read_text(encoding="utf-8", errors="strict")
            except (OSError, ValueError, UnicodeDecodeError):
                continue    # binary or unreadable: not hand-written config
            scanned += 1
            rel = str(f.relative_to(root))
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


# os.killpg, os.getpgid and signal.SIGKILL are POSIX-only -- on Windows they do not
# exist as attributes at all, so touching them raises AttributeError rather than OSError.
# Resolve the capability once, at import, instead of discovering it inside a timeout
# handler where the failure would mask the timeout it was called to handle.
HAVE_PROCESS_GROUPS = (hasattr(os, "killpg") and hasattr(os, "getpgid")
                       and hasattr(signal, "SIGKILL"))


def muse_version():
    """The version string `muse --version` reports, or None if it cannot be obtained.

    Parsed out rather than compared whole: the line carries more than the number, and
    the number is the only part with a stable meaning."""
    try:
        r = subprocess.run(["muse", "--version"], capture_output=True, text=True, timeout=10)
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
        try:
            killed_group = subprocess.run(
                ["taskkill", "/F", "/T", "/PID", str(p.pid)],
                capture_output=True, text=True).returncode == 0
        except OSError:
            pass
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


def run_muse(cmd, prompt: str, repo: Path, events: Path, stderr: Path, timeout: int):
    """Run one muse round to completion. Returns a dict of what the event stream said.

    Run from the repo root, not the worktree: muse treats cwd as the source repository
    and rejects a --worktree-existing path equal to it."""
    import time as _time
    started = _time.time()
    out = {"status": "completed", "reason": None, "model_actual": None,
           "text": "", "elapsed_s": 0.0, "exit_code": None, "stderr_tail": ""}

    events.parent.mkdir(parents=True, exist_ok=True)
    with events.open("w", encoding="utf-8") as fo, stderr.open("w", encoding="utf-8") as fe:
        # Its own session, so a timeout can signal the whole tree. A --yolo muse run
        # spawns builds and test runners; killing only the direct child leaves those
        # writing into a worktree we are about to delete, and still spending.
        # Popen uses CreateProcess on Windows, which never consults PATHEXT: a muse
        # installed as a .cmd shim is FileNotFoundError under its bare name even though
        # shutil.which (what preflight checks) resolves it. Resolve the same way first.
        exe = shutil.which(cmd[0]) or cmd[0]
        p = subprocess.Popen([exe, *cmd[1:], prompt], cwd=str(repo), stdout=fo, stderr=fe,
                             text=True, start_new_session=True)
        try:
            p.wait(timeout=timeout)
            out["exit_code"] = p.returncode
        except subprocess.TimeoutExpired:
            kill_process_tree(p)
            out["status"] = "timeout"
            out["reason"] = "exceeded {}s".format(timeout)
    out["elapsed_s"] = round(_time.time() - started, 1)

    # muse's exit code and stderr are the only things that distinguish an unknown flag
    # from a bad model id from an expired credential -- and every one of those used to
    # come back as the same sentence, leaving a supervisor nothing to do but retry
    # blind, which this plugin's own guidance tells it not to do.
    try:
        tail = stderr.read_text(encoding="utf-8", errors="replace")
    except OSError:
        tail = ""
    out["stderr_tail"] = tail[-2000:].strip()

    if out["status"] == "timeout":
        return out

    # run_terminal is the single authoritative record; everything else is noise.
    term = None
    try:
        with events.open(encoding="utf-8") as f:
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


def _diff_spec(excludes):
    """The pathspec harvest diffs through. Shared so a fingerprint measures exactly the
    bytes that end up in patch.diff and not one byte more."""
    return ["--"] + [":(exclude,glob){}".format(p) for p in excludes] \
                  + [":(exclude,glob)**/{}".format(p) for p in excludes]


def stage_all(wt: Path, spec):
    """Stage the whole worktree. Returns None on success, or an error string.

    `git add -A -- :(exclude,glob)X` exits 1 when a path git ALREADY ignores matches one
    of those excludes, and DEFAULT_EXCLUDES is a list of precisely the things a real repo
    gitignores -- __pycache__, node_modules, .venv, dist, build. So on any repo with a
    .gitignore, the first time a worker generated a __pycache__, every harvest from that
    point on reported "git add failed" and patch.diff stopped being updated. It never
    showed up here because the suite's fixture repos have no .gitignore.

    Retrying without the pathspec is correct, not a workaround: git skips ignored files
    on its own, and the diff applies the same excludes afterwards. The pathspec on the
    first attempt is only there to avoid staging a huge unignored node_modules, and that
    case is exactly the one that does not hit this error."""
    add = subprocess.run(["git", "-C", str(wt), "add", "-A", *spec],
                         capture_output=True, text=True)
    if add.returncode == 0:
        return None
    retry = subprocess.run(["git", "-C", str(wt), "add", "-A"],
                           capture_output=True, text=True)
    if retry.returncode == 0:
        return None
    return (add.stderr or retry.stderr).strip()[:300] or "git add exited {}".format(add.returncode)


def patch_fingerprint(wt: Path, base: str, excludes):
    """A hash of the patch this worktree currently produces, or None if it cannot be taken.

    This is what binds a verification to the thing it verified, and it deliberately
    fingerprints the PATCH rather than the worktree. A tree hash would move whenever an
    acceptance check dropped a `__pycache__` or a `.pytest_cache` -- churn that never
    reaches patch.diff -- and every such run would come back refused. The deliverable is
    the diff; certify the diff."""
    try:
        spec = _diff_spec(excludes)
        if stage_all(wt, spec) is not None:
            return None
        diff = subprocess.run(["git", "-C", str(wt), "diff", "--cached", base, *spec],
                              capture_output=True, text=True)
        if diff.returncode != 0:
            return None
        return hashlib.sha256(diff.stdout.encode("utf-8", "replace")).hexdigest()
    except OSError:
        return None


def harvest(wt: Path, base: str, excludes, patch_path: Path):
    """Stage everything and diff against base.

    Staging first is essential: muse leaves the worktree dirty and never commits, and a
    plain `git diff` silently omits newly created files -- a whole new test suite can
    read as "no changes"."""
    spec = _diff_spec(excludes)
    rec = {"patch_lines": 0, "files_changed": [], "harvest_error": None}
    try:
        # git's exit status matters here, and ignoring it is silent data loss: a missing
        # worktree, a held index.lock or a bad base ref all return rc!=0 with empty
        # stdout, which would overwrite a good patch.diff with an empty file and report
        # a clean zero-line result. The supervisor then reads a failure as "the worker
        # decided nothing needed doing".
        staging_error = stage_all(wt, spec)
        if staging_error is not None:
            rec["harvest_error"] = "git add failed: {}".format(staging_error)
            return rec
        diff = subprocess.run(["git", "-C", str(wt), "diff", "--cached", base, *spec],
                              capture_output=True, text=True)
        if diff.returncode != 0:
            rec["harvest_error"] = "git diff failed: {}".format(diff.stderr.strip()[:300])
            return rec
        # Only now is it safe to replace whatever patch.diff already held.
        patch_path.parent.mkdir(parents=True, exist_ok=True)
        patch_path.write_text(diff.stdout, encoding="utf-8")
        rec["patch_lines"] = diff.stdout.count("\n")
        names = subprocess.run(
            ["git", "-C", str(wt), "diff", "--cached", base, "--name-only", *spec],
            capture_output=True, text=True)
        rec["files_changed"] = names.stdout.split() if names.returncode == 0 else []
    except Exception as e:
        rec["harvest_error"] = str(e)
    return rec


def commit_worktree(wt: Path, message: str) -> None:
    subprocess.run(
        ["git", "-C", str(wt), "-c", "user.email=muse@local", "-c", "user.name=muse",
         "commit", "-qm", message],
        capture_output=True,
    )
