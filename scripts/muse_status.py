#!/usr/bin/env python3
"""
muse_status.py — what every delegated task in this repo actually did.

Reads the artifacts muse_task.py and muse_fleet.py leave behind and answers the one
question that matters when picking a run back up: which of these patches did somebody
actually check?

The distinction this script exists to make visible is `completed` versus `accept`.
A worker reporting `completed` only means it stopped. A task is verified when a
supervisor ran the acceptance command itself and the exit code was recorded, which is
what `verified_by_supervisor` in task.json means. A task that finished with a verdict
of `accept` and no recorded verification is the failure mode worth catching, so it is
flagged rather than shown as green.

    muse_status.py                    # scan ./.muse-fleet
    muse_status.py --out .muse-fleet/supervised
    muse_status.py --json             # machine-readable, for a supervisor or a script
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

DEFAULT_ROOT = ".muse-fleet"


def load(p: Path):
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def find_tasks(root: Path):
    """Every directory holding a state.json, newest run first.

    Both drivers nest one directory per task under a run directory, but they disagree
    on depth (muse_task.py uses <out>/<id>, muse_fleet.py uses <out>/<stamp>/<id>), so
    walk for the marker file rather than assuming a layout.
    """
    found = []
    for dirpath, _dirnames, filenames in os.walk(root):
        if "state.json" in filenames or "task.json" in filenames:
            found.append(Path(dirpath))
    return sorted(found, key=lambda p: p.stat().st_mtime, reverse=True)


def summarise(tdir: Path) -> dict:
    st = load(tdir / "state.json") or {}
    task = load(tdir / "task.json")

    verifs = (task or st).get("verifications") or st.get("verifications") or []
    # Final state, not best-ever: a gate check that passed must not outrank the real
    # acceptance check that failed after it.
    final_passed = bool(verifs) and bool(verifs[-1].get("passed"))
    last = verifs[-1] if verifs else None

    patch = tdir / "patch.diff"
    patch_lines = (task or {}).get("patch_lines")
    if patch_lines is None:
        patch_lines = st.get("final_patch_lines")
    if patch_lines is None and patch.exists():
        try:
            patch_lines = sum(1 for _ in patch.open(encoding="utf-8", errors="replace"))
        except OSError:
            patch_lines = None

    # A revision that could not resume its muse session is a silent quality problem: the
    # worker got feedback plus a re-sent brief but no memory of its own previous attempt,
    # so it is closer to a fresh try than a correction. Worth surfacing, not burying.
    lost_context = [r.get("n") for r in (st.get("rounds") or [])
                    if r.get("kind") == "revision" and not r.get("resumed")]

    # `finished` is about this script's bookkeeping; `verified` is about evidence.
    # Keep them separate — conflating them is how an unchecked patch reads as done.
    return {
        "id": st.get("id") or (task or {}).get("id") or tdir.name,
        "dir": str(tdir),
        "finished": bool((task or {}).get("verdict") or st.get("done")),
        "verdict": (task or {}).get("verdict") or st.get("verdict"),
        "rounds_used": (task or {}).get("rounds_used") or len(st.get("rounds") or []),
        "max_rounds": st.get("max_rounds"),
        # Evidence outranks the recorded flag. The exit codes are right here, and a
        # stored verified_by_supervisor can be stale (written by an older version) or
        # simply wrong -- neither should make a red final check read as green.
        "verified": final_passed if verifs else bool((task or {}).get("verified_by_supervisor")),
        "checks_run": len(verifs),
        "last_check": (last or {}).get("command"),
        "last_exit": (last or {}).get("exit_code"),
        "patch": str(patch) if patch.exists() else None,
        "patch_lines": patch_lines,
        "files_changed": (task or {}).get("files_changed") or st.get("final_files_changed") or [],
        "model": st.get("model"),
        "effort": st.get("effort"),
        "branch": st.get("branch"),
        "worktree": st.get("worktree"),
        "worktree_exists": bool(st.get("worktree") and Path(st["worktree"]).exists()),
        "concerns": (task or {}).get("concerns") or st.get("concerns") or [],
        "session_id": st.get("session_id"),
        "revisions_without_context": lost_context,
        "brief": (st.get("brief") or "")[:160],
    }


def flags(r: dict) -> list:
    """The things a human should not have to notice for themselves."""
    out = []
    if r["verdict"] == "accept" and not r["verified"]:
        out.append("ACCEPTED WITHOUT A PASSING FINAL CHECK"
                   if r["checks_run"] else "ACCEPTED WITHOUT AN EXECUTED CHECK")
    if r["finished"] and not r["patch_lines"]:
        out.append("empty patch")
    if r["patch_lines"] and r["patch_lines"] > 5000:
        out.append("oversized patch — check for build artifacts")
    if not r["finished"] and r["max_rounds"] and r["rounds_used"] >= r["max_rounds"]:
        out.append("out of rounds, no verdict")
    if r["last_exit"] not in (None, 0):
        out.append("last check exited {}".format(r["last_exit"]))
    if r["concerns"]:
        out.append("{} residual concern(s)".format(len(r["concerns"])))
    if r.get("revisions_without_context"):
        out.append("revision round(s) {} could not resume the muse session — the worker "
                   "had no memory of its previous attempt"
                   .format(", ".join(str(n) for n in r["revisions_without_context"])))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="Report on delegated muse tasks.")
    ap.add_argument("--out", default=DEFAULT_ROOT,
                    help="artifact root to scan (default: %s)" % DEFAULT_ROOT)
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args()

    root = Path(args.out)
    if not root.exists():
        msg = "no artifacts at {} — nothing has been delegated from here yet".format(root)
        print(json.dumps({"tasks": [], "reason": msg}) if args.json else msg)
        return 0

    rows = [summarise(d) for d in find_tasks(root)]
    for r in rows:
        r["flags"] = flags(r)

    if args.json:
        print(json.dumps({"root": str(root), "tasks": rows}, indent=2))
        return 0

    if not rows:
        print("no task artifacts under {}".format(root))
        return 0

    print("{} task(s) under {}\n".format(len(rows), root))
    for r in rows:
        verdict = r["verdict"] or ("in progress" if not r["finished"] else "no verdict")
        check = "verified" if r["verified"] else "UNVERIFIED"
        print("  {id}  [{verdict}] {check}".format(id=r["id"], verdict=verdict, check=check))
        print("      rounds {}{}   patch {} lines, {} file(s){}".format(
            r["rounds_used"],
            "/%s" % r["max_rounds"] if r["max_rounds"] else "",
            r["patch_lines"] if r["patch_lines"] is not None else "?",
            len(r["files_changed"]),
            "   %s @ %s" % (r["model"], r["effort"]) if r["model"] else ""))
        if r["last_check"]:
            print("      check: {}  -> exit {}".format(r["last_check"], r["last_exit"]))
        if r["patch"]:
            print("      patch: {}".format(r["patch"]))
        if r["worktree"]:
            print("      worktree: {}{}".format(
                r["worktree"], "" if r["worktree_exists"] else "  (gone)"))
        for f in r["flags"]:
            print("      !! {}".format(f))
        for c in r["concerns"]:
            print("      concern: {}".format(c))
        print()

    unverified = [r for r in rows if r["verdict"] == "accept" and not r["verified"]]
    if unverified:
        # Two different failures, and saying "nothing ran" about a check that ran and
        # went red would be its own inaccuracy.
        never = [r for r in unverified if not r["checks_run"]]
        failed = [r for r in unverified if r["checks_run"]]
        if never:
            print("{} task(s) accepted with no executed check: {}".format(
                len(never), ", ".join(r["id"] for r in never)))
        if failed:
            print("{} task(s) accepted while their final check FAILED: {}".format(
                len(failed), ", ".join(r["id"] for r in failed)))
        print("Treat those patches as unproven — `accept` there means somebody said so, "
              "not that a check passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
