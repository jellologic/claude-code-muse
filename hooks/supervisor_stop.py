#!/usr/bin/env python3
"""SubagentStop (matcher: muse-supervisor): the backstop for the central claim.

The thesis of this plugin is one sentence -- a verdict means someone looked -- and
`finish` now enforces it: `--verdict accept` is refused unless a check ran, the final one
passed, and it ran against the patch being harvested. That closes the path where a bad
verdict gets WRITTEN. It cannot close the path where the record is never written at all:
a supervisor that runs out of turns, is interrupted, or simply stops and reports from
memory leaves a worktree holding real work and no artifact saying what happened to it.

This reads what is already on disk when the supervisor stops. No model call, no
heuristic, no new state -- which is why it is worth having.

It reports and does not block. Exit 2 on SubagentStop would send the supervisor back,
and that is the wrong instrument here: this hook cannot see the brief, so it cannot tell
a supervisor stopping too early from one the user interrupted on purpose, and blocking
the second is worse than reporting the first. What it prints goes to the orchestrating
agent -- which is exactly where the verdict gets turned into a sentence for the user, and
the only place the correction matters.
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

# Only tasks this session plausibly touched. Without a window, every stale task in the
# repo shouts on every subagent stop and the hook trains its reader to ignore it.
RECENT_SECONDS = 6 * 60 * 60
MAX_REPORTED = 10
ROOTS = (".muse-fleet/tasks", ".muse-fleet/supervised")


def task_dirs(project: Path):
    for rel in ROOTS:
        root = project / rel
        if not root.is_dir():
            continue
        # <root>/<id>/ for the single-task path, <root>/<stamp>/<id>/ for the fleet's.
        for d in sorted(root.iterdir()):
            if (d / "state.json").exists():
                yield d
            elif d.is_dir():
                for sub in sorted(d.iterdir()):
                    if (sub / "state.json").exists():
                        yield sub


def read(p: Path):
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def main() -> int:
    try:
        sys.stdin.read()
    except (OSError, ValueError):
        pass

    project = Path(os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd())
    cutoff = time.time() - RECENT_SECONDS
    notes = []

    for d in task_dirs(project):
        st = read(d / "state.json")
        if not isinstance(st, dict):
            continue
        try:
            if (d / "state.json").stat().st_mtime < cutoff:
                continue
        except OSError:
            continue

        task = read(d / "task.json")
        tid = st.get("id", d.name)

        if not st.get("done") and not (task or {}).get("verdict"):
            rounds = len(st.get("rounds") or [])
            if rounds:
                notes.append(
                    "{}: {} round(s) ran and no verdict was recorded. The patch is at "
                    "{} and the worktree is still there; nothing else will mention it."
                    .format(tid, rounds, d / "patch.diff"))
            continue

        if not isinstance(task, dict):
            continue
        if task.get("verdict") == "accept" and not task.get("verified_by_supervisor"):
            why = task.get("accepted_unverified")
            notes.append(
                "{}: accepted WITHOUT a passing check{}. Report that in those words "
                "rather than as a plain accept.".format(
                    tid, ", by explicit override: " + str(why) if why else ""))
        if task.get("out_of_band_edit"):
            notes.append(
                "{}: the harvested patch is not what muse produced -- something wrote "
                "into the worktree afterwards.".format(tid))

    if not notes:
        return 0

    print("muse plugin: what the artifacts say about the task(s) that just finished. "
          "Use this over the supervisor's summary where they disagree.")
    for n in notes[:MAX_REPORTED]:
        print("  - " + n)
    if len(notes) > MAX_REPORTED:
        print("  ... and {} more; `/muse:status` has the rest.".format(len(notes) - MAX_REPORTED))
    return 0


if __name__ == "__main__":
    sys.exit(main())
