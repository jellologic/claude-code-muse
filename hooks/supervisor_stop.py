#!/usr/bin/env python3
"""SubagentStop (matcher: ^muse:muse-supervisor$): stop a supervisor that owns unfinished work.

The old version of this hook never fired and never blocked: its matcher was
an exact-name list that plugin agent types never equal, and its plain stdout
reached nobody on SubagentStop. Blocking is safe now for two reasons it did
not have before. First, ownership: the supervisor's own transcript names the
branch `muse_task.py run` printed, so a fleet of sibling supervisors blocks
only over the task it actually owns instead of every in-flight task in the
project. Second, a per-task cap of two blocks: a supervisor that cannot or
will not finish is sent back twice, then let go rather than looped forever.
"""

from __future__ import annotations

import json
import os
import shlex
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _artifacts as A

MAX_BLOCKS_PER_TASK = 2
BLOCKS_FILE = "stop_hook_blocks.json"


def read_transcript_text(payload: dict) -> str:
    parts = []
    tp = payload.get("agent_transcript_path")
    if isinstance(tp, str) and tp:
        try:
            # open() rather than Path.read_text: the errors= parameter of
            # read_text exists only on 3.10+, and CI still runs 3.9.
            with open(tp, encoding="utf-8", errors="replace") as f:
                parts.append(f.read())
        except (OSError, ValueError):
            pass
    lam = payload.get("last_assistant_message")
    if isinstance(lam, str) and lam:
        parts.append(lam)
    return "\n".join(parts)


def block_count(taskdir: Path):
    try:
        val = json.loads((taskdir / BLOCKS_FILE).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return 0
    if isinstance(val, dict) and isinstance(val.get("count"), int):
        return val["count"]
    if isinstance(val, int):
        return val
    return 0


def bump_count(taskdir: Path) -> bool:
    try:
        n = block_count(taskdir) + 1
        (taskdir / BLOCKS_FILE).write_text(json.dumps({"count": n}), encoding="utf-8")
        return True
    except (OSError, ValueError):
        return False


def main() -> int:
    try:
        payload = json.loads(sys.stdin.read())
    except (OSError, ValueError):
        return 0
    if not isinstance(payload, dict):
        return 0
    agent_type = payload.get("agent_type")
    if agent_type is not None and agent_type != "muse:muse-supervisor":
        return 0
    # stop_hook_active means this hook already blocked the current stop, so
    # blocking again would loop; stay silent and leave the counts alone.
    if payload.get("stop_hook_active") is True:
        return 0

    project = A.project_dir()
    text = read_transcript_text(payload)
    if not text:
        return 0

    blocking = []
    for d, st, task in A.recent_tasks(project):
        if not A.is_unfinished(st, task):
            continue
        branch = st.get("branch")
        if not isinstance(branch, str) or not branch:
            continue
        if not A.mentions_branch(text, branch):
            continue
        if block_count(d) >= MAX_BLOCKS_PER_TASK:
            continue
        tid = st.get("id", d.name)
        blocking.append((d, tid, A.rounds_count(st)))
        if len(blocking) >= 10:
            break

    if not blocking:
        return 0

    # A count file that cannot be written fails open: an unbounded loop is
    # worse than letting one task go, so uncountable tasks are dropped.
    named = []
    for d, tid, n in blocking:
        if bump_count(d):
            named.append((d, tid, n))
    if not named:
        return 0

    # One runnable finish command per owned task: finish takes a single
    # --id, a fleet task needs its stamp dir as --out rather than the
    # default tasks root, and the verdict is one concrete choice (revise
    # claims the least) with the other choices named on a following line --
    # a placeholder word would fail argparse, and the old accept|revise|reject
    # spelling is a bash pipe that exits 127 when pasted.
    # shlex.quote keeps an odd id runnable; as_posix keeps a Windows C:/...
    # out usable from Git Bash instead of losing backslashes to shlex.
    summaries = []
    commands = []
    for d, tid, n in named:
        summaries.append("task {} has {} round(s) and no verdict".format(tid, n))
        out = Path(os.path.abspath(d.parent)).as_posix()
        commands.append(
            "muse-task finish --id {} --out {} --verdict revise --summary \"...\"".format(
                shlex.quote(str(tid)), shlex.quote(out)
            )
        )
    reason = "{}: run one finish command per task before stopping.\n{}\n{}".format(
        "; ".join(summaries), "\n".join(commands),
        "The verdict is one of accept, revise, reject: replace revise with "
        "accept (finish refuses it unless the final recorded check passed on "
        "this tree) or reject as your judgement says.",
    )
    print(json.dumps({"decision": "block", "reason": reason}))
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
