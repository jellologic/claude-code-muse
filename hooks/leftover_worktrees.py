#!/usr/bin/env python3
"""SessionStart leftover report: name delegation worktrees still open.

SessionEnd output is discarded, so the old SessionEnd hook reported to
nobody. SessionStart plain stdout does reach the model, which makes it the
only hook that can name leftovers where someone will see them.

Only worktrees with an artifact record are named: /muse:cleanup refuses
unrecorded ones, and an unrecorded muse/ branch may be a human's. The verdict
comes from the same record, so the model can tell a finished patch from work
that exists only in its worktree.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

OURS = re.compile(r"^refs/heads/(muse|fleet)/")


def artifact_records(project: Path):
    # branch -> finished, mirrored from muse_cleanup.artifact_index but bounded
    # to state.json at depth <= 3 under .muse-fleet, so $HOME never gets walked.
    idx = {}
    fleet = project / ".muse-fleet"
    try:
        if not fleet.is_dir():
            return idx
    except (OSError, ValueError):
        return idx
    try:
        cands = list(fleet.rglob("state.json"))
    except (OSError, ValueError):
        return idx
    for cand in cands:
        try:
            rel = cand.relative_to(fleet)
        except (OSError, ValueError):
            continue
        if len(rel.parts) - 1 > 3:
            continue
        d = cand.parent
        try:
            st = json.loads(cand.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(st, dict):
            continue
        branch = st.get("branch")
        if not isinstance(branch, str) or not branch:
            continue
        finished = bool(st.get("done"))
        try:
            task = json.loads((d / "task.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            task = None
        if isinstance(task, dict) and task.get("verdict"):
            finished = True
        idx[branch] = finished
    return idx


def main() -> int:
    project = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    try:
        r = subprocess.run(
            ["git", "-C", project, "worktree", "list", "--porcelain"],
            capture_output=True, text=True, timeout=10)
    except (OSError, ValueError, subprocess.SubprocessError):
        return 0
    if r.returncode != 0:
        return 0

    found = []
    path = None
    # splitlines handles CRLF from native Windows git; paths are used
    # opaquely so C:\... native paths pass through untouched.
    for line in r.stdout.splitlines():
        if line.startswith("worktree "):
            path = line[len("worktree "):]
        elif line.startswith("branch ") and path is not None:
            full = line[len("branch "):]
            if OURS.match(full):
                found.append((path, full.replace("refs/heads/", "")))
            path = None

    if not found:
        return 0
    try:
        records = artifact_records(Path(project))
    except (OSError, ValueError):
        return 0
    kept = [(p, b) for p, b in found if b in records]
    if not kept:
        return 0

    print("muse plugin: {} delegation worktree(s) from this project are still open:".format(len(kept)))
    for wt, branch in kept[:10]:
        verdict = "verdict recorded" if records.get(branch) else "no verdict yet"
        print("  - {}  ({}, {})".format(wt, branch, verdict))
    if len(kept) > 10:
        print("  ... and {} more".format(len(kept) - 10))
    print("Each holds an unapplied patch until it is reaped. `/muse:cleanup` lists what it would remove; `/muse:cleanup --yes` removes it. It refuses a task that never reached a verdict unless you pass --all, because that task's work exists only in its worktree.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BaseException:
        try:
            sys.stdout.write("")
        except BaseException:
            pass
        sys.exit(0)
