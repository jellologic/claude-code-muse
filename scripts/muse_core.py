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
import shutil
import subprocess
import sys
from pathlib import Path

# Sentinel: resolve the newest contributor model from the live catalog at run time.
# Hard-coding a version is how a machine ends up silently a generation behind -- exactly
# what a stale `model` pin in ~/.config/muse/settings.json does.
LATEST = "latest-contributor"
FALLBACK_MODEL = "muse-spark-1.3-contributor"
CATALOG_GLOB = "~/.local/share/muse/model-catalog/*.json"
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
        sys.exit("muse not found on PATH")
    try:
        git(repo, "rev-parse", "--git-dir")
    except Exception:
        sys.exit("{} is not a git repository (worktree isolation requires git)".format(repo))

    dirty = git(repo, "status", "--porcelain", check=False)
    if dirty and require_clean:
        sys.exit(
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

    return git(repo, "rev-parse", "HEAD")


def check_schema(path: str) -> None:
    """The Meta structured-output API rejects a schema whose `required` does not list
    every key in `properties` -- there is no such thing as an optional field. Catching
    that here turns a fleet-wide 400 into a one-line message before anything spawns."""
    try:
        sch = json.loads(Path(path).read_text())
    except Exception as e:
        sys.exit("--schema {}: not readable/parseable JSON ({})".format(path, e))
    props = set((sch.get("properties") or {}).keys())
    req = set(sch.get("required") or [])
    if props - req:
        sys.exit(
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

def muse_cmd(model, effort, wt: Path, schema=None, max_steps=0, inherit_skills=False):
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
        p = subprocess.Popen([*cmd, prompt], cwd=str(repo), stdout=fo, stderr=fe, text=True)
        try:
            p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
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
        subprocess.run(["git", "-C", str(wt), "add", "-A", *spec], capture_output=True)
        patch = subprocess.run(
            ["git", "-C", str(wt), "diff", "--cached", base, *spec],
            capture_output=True, text=True,
        ).stdout
        patch_path.parent.mkdir(parents=True, exist_ok=True)
        patch_path.write_text(patch)
        rec["patch_lines"] = patch.count("\n")
        rec["files_changed"] = subprocess.run(
            ["git", "-C", str(wt), "diff", "--cached", base, "--name-only", *spec],
            capture_output=True, text=True,
        ).stdout.split()
    except Exception as e:
        rec["harvest_error"] = str(e)
    return rec


def commit_worktree(wt: Path, message: str) -> None:
    subprocess.run(
        ["git", "-C", str(wt), "-c", "user.email=muse@local", "-c", "user.name=muse",
         "commit", "-qm", message],
        capture_output=True,
    )
