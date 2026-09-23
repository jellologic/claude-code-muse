#!/usr/bin/env python3
"""Shared artifact scan for the muse hooks.

Both the SubagentStop block and the PostToolUse note read the same task
records, so they share the directory walk and the tolerant JSON read here.
Every filesystem and parse call tolerates failure and skips the entry: a
hook that crashes on a half-written task dir trains its reader to ignore
it, and an unreadable dir must never hide its readable neighbours.
"""

from __future__ import annotations

import json
import os
import re
import time
from pathlib import Path

# Only tasks this session plausibly touched. Without a window, every stale
# task in the repo shouts on every hook and the note trains its reader to
# ignore it.
RECENT_SECONDS = 6 * 60 * 60
MAX_REPORTED = 10
ROOTS = (".muse-fleet/tasks", ".muse-fleet/supervised")


def project_dir():
    # CLAUDE_PROJECT_DIR names the project the hooks run in; outside Claude
    # (tests, shells) the working directory is the only thing available.
    return Path(os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd())


def task_dirs(project: Path):
    # Yields <root>/<id>/ and <root>/<stamp>/<id>/ dirs holding state.json.
    # Each step is guarded so one unreadable dir skips instead of aborting
    # the walk (a chmod 000 dir raises PermissionError, an OSError subclass).
    for rel in ROOTS:
        try:
            root = project / rel
            if not root.is_dir():
                continue
        except (OSError, ValueError):
            continue
        try:
            entries = sorted(root.iterdir())
        except (OSError, ValueError):
            continue
        for d in entries:
            try:
                if (d / "state.json").exists():
                    yield d
                elif d.is_dir():
                    try:
                        subs = sorted(d.iterdir())
                    except (OSError, ValueError):
                        continue
                    for sub in subs:
                        try:
                            if (sub / "state.json").exists():
                                yield sub
                        except (OSError, ValueError):
                            continue
            except (OSError, ValueError):
                continue


def read_json(p: Path):
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def recent_tasks(project: Path, now: float | None = None):
    # (dir, state, task) for recent dict states; task may be None or non-dict.
    # Callers apply their own verdict/rounds rules on top.
    cutoff = (time.time() if now is None else now) - RECENT_SECONDS
    out = []
    for d in task_dirs(project):
        st = read_json(d / "state.json")
        if not isinstance(st, dict):
            continue
        try:
            if (d / "state.json").stat().st_mtime < cutoff:
                continue
        except (OSError, ValueError):
            continue
        task = read_json(d / "task.json")
        out.append((d, st, task))
    return out


def is_unfinished(st: dict, task) -> bool:
    # A task with no verdict and at least one round still holds work only in
    # its worktree, so stopping now would orphan it. A non-list rounds (an
    # int left by a half-write) counts as zero rounds: no block, no crash.
    if st.get("done"):
        return False
    if isinstance(task, dict) and task.get("verdict"):
        return False
    rounds = st.get("rounds")
    if not isinstance(rounds, list):
        return False
    return len(rounds) >= 1


def rounds_count(st: dict) -> int:
    rounds = st.get("rounds")
    if not isinstance(rounds, list):
        return 0
    return len(rounds)


def mentions_branch(text, branch) -> bool:
    # Fleet tasks share one stamp, so sibling branches share a prefix
    # (fleet/S/api and fleet/S/api-docs): a plain `in` test fires for every
    # sibling whenever one of them is named. Match the branch as a whole
    # token instead -- anything that could continue the name right after it
    # disqualifies the hit, while a closing quote, whitespace, comma, brace
    # or JSON-escaped newline (all non-name characters) still matches.
    if not isinstance(text, str) or not isinstance(branch, str) or not branch:
        return False
    try:
        return re.search(re.escape(branch) + r"(?![A-Za-z0-9._-])", text) is not None
    except (re.error, ValueError):
        return False
