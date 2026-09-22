#!/usr/bin/env python3
"""
muse_cleanup.py — reap the worktrees, branches and artifacts a delegated run leaves behind.

A fan-out leaves one worktree and one branch per task, plus an artifact directory holding
the patches. Nothing removes them automatically, because the patch inside a worktree is
real work and deleting it is not undoable.

So this refuses to guess. It is a dry run unless you pass --yes, and by default it skips
any task that has not reached a verdict — an unfinished task's worktree is the only place
its work exists. --all overrides that once you have decided the work is disposable.

    muse_cleanup.py                      # show what would be removed
    muse_cleanup.py --yes                # remove finished tasks' worktrees and branches
    muse_cleanup.py --yes --artifacts    # also delete .muse-fleet/
    muse_cleanup.py --yes --all          # include tasks with no verdict
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load_core():
    """Reuse muse_core's teardown rather than reimplementing it.

    drop_worktree tolerates every half-state git can leave — a directory removed by hand,
    a branch still checked out somewhere else — and getting that wrong leaves metadata
    that blocks the next run with a confusing error.
    """
    spec = importlib.util.spec_from_file_location("muse_core", HERE / "muse_core.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def git(repo: Path, *a) -> str:
    r = subprocess.run(["git", "-C", str(repo), *a], capture_output=True, text=True)
    return r.stdout


def list_worktrees(repo: Path):
    """(path, branch) for every registered worktree except the main one."""
    out, cur = [], {}
    for line in git(repo, "worktree", "list", "--porcelain").splitlines():
        if line.startswith("worktree "):
            if cur:
                out.append(cur)
            cur = {"path": line.split(" ", 1)[1], "branch": None}
        elif line.startswith("branch "):
            cur["branch"] = line.split(" ", 1)[1].replace("refs/heads/", "")
    if cur:
        out.append(cur)
    return [w for w in out if Path(w["path"]).resolve() != repo.resolve()]


def artifact_index(root: Path):
    """branch -> task record, so a worktree can be matched to what it produced."""
    idx = {}
    if not root.exists():
        return idx
    for dirpath, _dirs, files in os.walk(root):
        if "state.json" not in files and "task.json" not in files:
            continue
        d = Path(dirpath)
        st, task = None, None
        for name, target in (("state.json", "st"), ("task.json", "task")):
            try:
                val = json.loads((d / name).read_text())
            except (OSError, ValueError):
                val = None
            if target == "st":
                st = val
            else:
                task = val
        st = st or {}
        rec = {
            "id": st.get("id") or (task or {}).get("id") or d.name,
            "dir": d,
            "branch": st.get("branch"),
            "worktree": st.get("worktree"),
            "verdict": (task or {}).get("verdict") or st.get("verdict"),
            "finished": bool((task or {}).get("verdict") or st.get("done")),
            "has_patch": (d / "patch.diff").exists(),
        }
        if rec["branch"]:
            idx[rec["branch"]] = rec
    return idx


def looks_like_artifact_root(root: Path) -> bool:
    """Does this directory actually hold delegated-task artifacts?

    --out is free-form, and --artifacts deletes the whole tree. A typo must not take a
    directory with it, so require the marker files a task always writes before removing
    anything.
    """
    if not root.is_dir():
        return False
    for _dirpath, _dirs, files in os.walk(root):
        if "state.json" in files or "task.json" in files:
            return True
    return False


def remove_artifact_root(out: str) -> None:
    root = Path(out)
    if not root.exists():
        return
    if not looks_like_artifact_root(root):
        print("refusing to delete {}: no state.json or task.json anywhere under it, so "
              "this does not look like a muse artifact root".format(root))
        return
    # No ignore_errors: a partial delete must be visible, not swallowed.
    shutil.rmtree(root)
    print("removed artifact root {}".format(root))


def main() -> int:
    ap = argparse.ArgumentParser(description="Reap muse delegation worktrees and artifacts.")
    ap.add_argument("--repo", default=".")
    ap.add_argument("--out", default=".muse-fleet", help="artifact root (default: .muse-fleet)")
    ap.add_argument("--prefix", action="append", default=None,
                    help="branch prefix to consider (repeatable; default: muse, fleet)")
    ap.add_argument("--yes", action="store_true", help="actually remove (default is a dry run)")
    ap.add_argument("--all", action="store_true",
                    help="include tasks that never reached a verdict")
    ap.add_argument("--artifacts", action="store_true",
                    help="also delete the artifact root after removing worktrees")
    args = ap.parse_args()

    repo = Path(args.repo).resolve()
    if not (repo / ".git").exists():
        sys.exit("{} is not a git repository".format(repo))

    prefixes = tuple((args.prefix or ["muse", "fleet"]))
    idx = artifact_index(Path(args.out))

    targets, skipped = [], []
    for w in list_worktrees(repo):
        br = w["branch"] or ""
        if not br.startswith(tuple(p + "/" for p in prefixes)):
            continue
        rec = idx.get(br)
        # No artifact record at all is itself a reason to be careful: nothing here
        # proves the patch was ever harvested out of that tree.
        unfinished = rec is None or not rec["finished"]
        if unfinished and not args.all:
            skipped.append((w, rec))
            continue
        targets.append((w, rec))

    if skipped:
        print("skipping {} unfinished task(s) — their work exists only in the worktree:"
              .format(len(skipped)))
        for w, rec in skipped:
            print("  {}  {}{}".format(
                w["branch"], w["path"],
                "" if rec and rec["has_patch"] else "   (no harvested patch)"))
        print("  pass --all to remove these too\n")

    if not targets:
        print("nothing to remove under {}".format(repo))
        if args.artifacts and args.yes:
            remove_artifact_root(args.out)
        return 0

    print("{} worktree(s) to remove:".format(len(targets)))
    for w, rec in targets:
        print("  {}  {}   verdict={}{}".format(
            w["branch"], w["path"],
            (rec or {}).get("verdict") or "none",
            "" if not rec else ("   patch: %s" % (rec["dir"] / "patch.diff")
                                if rec["has_patch"] else "   (no patch harvested)")))

    if not args.yes:
        print("\ndry run — nothing removed. Re-run with --yes to apply.")
        return 0

    core = load_core()
    removed = 0
    for w, _rec in targets:
        core.drop_worktree(repo, Path(w["path"]), w["branch"])
        removed += 1
        print("removed {}".format(w["branch"]))

    # Prune the empty parent the drivers create next to the repo, but only if it is
    # empty: a sibling run's worktrees may still live there.
    wt_root = repo.parent / ".muse-fleet-wt-{}".format(repo.name)
    if wt_root.is_dir() and not any(wt_root.iterdir()):
        wt_root.rmdir()
        print("removed empty {}".format(wt_root))

    if args.artifacts:
        remove_artifact_root(args.out)

    print("\n{} worktree(s) removed.".format(removed))
    return 0


if __name__ == "__main__":
    sys.exit(main())
