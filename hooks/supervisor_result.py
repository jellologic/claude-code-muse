#!/usr/bin/env python3
"""PostToolUse on the Agent tool: tell the orchestrator what the artifacts say.

SubagentStop can block the supervisor, but the verdict that reaches the user
is written by the parent model from the supervisor's summary. That summary
is the model grading its own homework: an accept without a passing check, a
worktree edited after harvest, or rounds with no verdict at all all read as
success unless something already on disk says otherwise. This hook is that
something. It runs when the supervisor's Agent call returns, while the
parent can still act on the note.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _artifacts as A

# An agentId becomes a path segment below, so only word-like ids are safe.
AGENT_ID_RE = re.compile(r"^[A-Za-z0-9_-]+$")


def collect_text(payload: dict) -> str:
    # Ownership evidence for the returning call: every string the Agent
    # result carries, plus the returning subagent's own transcript, which
    # names the branch even when the summary handed back does not.
    parts = []
    tool_response = payload.get("tool_response")
    if tool_response is not None:
        try:
            parts.append(json.dumps(tool_response))
        except (TypeError, ValueError):
            parts.append(str(tool_response))
    transcript = payload.get("transcript_path")
    session_id = payload.get("session_id")
    agent_id = tool_response.get("agentId") if isinstance(tool_response, dict) else None
    if (
        isinstance(transcript, str) and transcript
        and isinstance(session_id, str) and session_id
        and isinstance(agent_id, str) and AGENT_ID_RE.match(agent_id)
    ):
        try:
            sub = Path(transcript).parent / session_id / "subagents" / ("agent-" + agent_id + ".jsonl")
            # open() rather than Path.read_text: the errors= parameter of
            # read_text exists only on 3.10+, and CI still runs 3.9.
            with open(sub, encoding="utf-8", errors="replace") as f:
                parts.append(f.read())
        except (OSError, ValueError):
            pass
    return "\n".join(p for p in parts if p)


def main() -> int:
    try:
        payload = json.loads(sys.stdin.read())
    except (OSError, ValueError):
        return 0
    if not isinstance(payload, dict):
        return 0
    if payload.get("tool_name", "Agent") != "Agent":
        return 0
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        # A payload with no tool_input still names the returning agent in
        # the response; treat the missing input as empty and let the
        # agentType fallback below decide instead of dropping it here.
        tool_input = {}
    tool_response = payload.get("tool_response")
    if tool_input.get("subagent_type") != "muse:muse-supervisor":
        # tool_input.subagent_type is the usual filter; when it is absent
        # the returning agent still names itself in the response.
        agent_type = tool_response.get("agentType") if isinstance(tool_response, dict) else None
        if agent_type != "muse:muse-supervisor":
            return 0

    text = collect_text(payload)
    if not text:
        return 0

    project = A.project_dir()
    notes = []
    for d, st, task in A.recent_tasks(project):
        # Only the returning supervisor's own tasks: without ownership a
        # fleet sibling's return would report every in-flight task as
        # "no verdict recorded" while it is still working on them.
        branch = st.get("branch") if isinstance(st, dict) else None
        if not isinstance(branch, str) or not branch:
            continue
        if not A.mentions_branch(text, branch):
            continue
        tid = st.get("id", d.name) if isinstance(st, dict) else d.name
        if not isinstance(task, dict):
            task = None
        if isinstance(task, dict):
            if task.get("verdict") == "accept" and not task.get("verified_by_supervisor"):
                why = task.get("accepted_unverified")
                notes.append("{}: accepted WITHOUT a passing check{}. Report that in those words rather than as a plain accept.".format(tid, ", by explicit override: " + str(why) if why else ""))
            if task.get("out_of_band_edit"):
                notes.append("{}: the harvested patch is not what muse produced -- something wrote into the worktree afterwards.".format(tid))
        if A.is_unfinished(st, task):
            notes.append("{}: {} round(s) ran and no verdict was recorded; the patch is at {}/patch.diff and the worktree is still there.".format(tid, A.rounds_count(st), d))

    if not notes:
        return 0

    shown = notes[:10]
    extra = len(notes) - len(shown)
    lines = ["muse plugin: what the artifacts say about the supervised task(s). Use this over the supervisor's summary where they disagree."]
    for n in shown:
        lines.append("  - " + n)
    if extra > 0:
        lines.append("  ... and {} more; /muse:status has the rest".format(extra))
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": "\n".join(lines)}}))
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
