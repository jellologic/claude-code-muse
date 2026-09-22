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
            rows.extend(json.load(open(f)).get("rows") or [])
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
        cur = excl.read_text() if excl.exists() else ""
        add = [p for p in (".muse/", ".muse-fleet/") if p not in cur]
        if add:
            excl.parent.mkdir(parents=True, exist_ok=True)
            excl.write_text(cur.rstrip("\n") + "\n" + "\n".join(add) + "\n")
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
        sch = json.loads(Path(path).read_text())
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
            m = re.search(r'"workspaceRoot"\s*:\s*"([^"]+)"', f.read_text())
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
    if not (base / ".msp-view-v1" / session_id).is_dir() \
            and not any(base.glob("*/*/*/" + session_id)):
        return False
    if workspace:
        recorded = session_workspace(session_id)
        if recorded and os.path.realpath(recorded) != os.path.realpath(str(workspace)):
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
SCAN_MAX_FILES = 5000          # bound the walk; a fan-out runs this per task


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
                text = f.read_text(errors="strict")
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


def kill_process_tree(p) -> None:
    """Kill a child and everything it spawned, as far as the platform allows.

    p.kill() signals only the direct child. Anything it started -- npm, pytest, a build
    -- survives, keeps writing into the worktree and keeps costing money after the
    timeout has been declared. Where process groups exist we kill the whole group; where
    they do not (Windows) we fall back to the direct child, which is weaker but is what
    the platform offers.
    """
    killed_group = False
    if HAVE_PROCESS_GROUPS:
        try:
            os.killpg(os.getpgid(p.pid), signal.SIGKILL)
            killed_group = True
        except (ProcessLookupError, PermissionError, OSError):
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
           "text": "", "elapsed_s": 0.0}

    events.parent.mkdir(parents=True, exist_ok=True)
    with events.open("w") as fo, stderr.open("w") as fe:
        # Its own session, so a timeout can signal the whole tree. A --yolo muse run
        # spawns builds and test runners; killing only the direct child leaves those
        # writing into a worktree we are about to delete, and still spending.
        p = subprocess.Popen([*cmd, prompt], cwd=str(repo), stdout=fo, stderr=fe,
                             text=True, start_new_session=True)
        try:
            p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            kill_process_tree(p)
            out["status"] = "timeout"
            out["reason"] = "exceeded {}s".format(timeout)
    out["elapsed_s"] = round(_time.time() - started, 1)

    if out["status"] == "timeout":
        return out

    # run_terminal is the single authoritative record; everything else is noise.
    term = None
    try:
        with events.open() as f:
            for line in f:
                try:
                    pl = json.loads(line).get("payload", {})
                except ValueError:
                    continue
                if pl.get("kind") == "run_terminal":
                    term = pl
                elif pl.get("kind") == "run_model_configured":
                    out["model_actual"] = pl.get("model_id")
    except OSError:
        pass

    if term is None:
        out["status"] = "no_terminal"
        out["reason"] = "muse produced no run_terminal record (crash or kill?)"
    else:
        out["status"] = "completed" if term.get("terminal") == "completed" else "failed"
        out["reason"] = term.get("reason")
        out["text"] = term.get("text") or ""
    return out


def harvest(wt: Path, base: str, excludes, patch_path: Path):
    """Stage everything and diff against base.

    Staging first is essential: muse leaves the worktree dirty and never commits, and a
    plain `git diff` silently omits newly created files -- a whole new test suite can
    read as "no changes"."""
    spec = ["--"] + [":(exclude,glob){}".format(p) for p in excludes] \
                  + [":(exclude,glob)**/{}".format(p) for p in excludes]
    rec = {"patch_lines": 0, "files_changed": [], "harvest_error": None}
    try:
        # git's exit status matters here, and ignoring it is silent data loss: a missing
        # worktree, a held index.lock or a bad base ref all return rc!=0 with empty
        # stdout, which would overwrite a good patch.diff with an empty file and report
        # a clean zero-line result. The supervisor then reads a failure as "the worker
        # decided nothing needed doing".
        add = subprocess.run(["git", "-C", str(wt), "add", "-A", *spec],
                             capture_output=True, text=True)
        if add.returncode != 0:
            rec["harvest_error"] = "git add failed: {}".format(add.stderr.strip()[:300])
            return rec
        diff = subprocess.run(["git", "-C", str(wt), "diff", "--cached", base, *spec],
                              capture_output=True, text=True)
        if diff.returncode != 0:
            rec["harvest_error"] = "git diff failed: {}".format(diff.stderr.strip()[:300])
            return rec
        # Only now is it safe to replace whatever patch.diff already held.
        patch_path.parent.mkdir(parents=True, exist_ok=True)
        patch_path.write_text(diff.stdout)
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
