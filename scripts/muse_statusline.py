#!/usr/bin/env python3
"""muse_statusline.py — per-supervisor rows for the subagent status line.

Reads the stdin JSON (base hook fields plus `columns` and `tasks`), folds
each supervisor row's repo event stream into one short status, and prints one
`{"id", "content"}` line per row it overrides. Rows it omits keep their
default rendering.

Runs on every refresh tick, so it ALWAYS exits 0 and never prints a
traceback: main is wrapped broad, and failure prints nothing.

Python 3.9 stdlib only.
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import sys
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "muse_core", str(Path(__file__).resolve().parent / "muse_core.py"))
core = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(core)

LABEL_RE = re.compile(r"^task:(\S+)$")
TAIL_BYTES = 64 * 1024


def repo_for(row, top_cwd, cache):
    """owning_repo of the row's cwd, else the top-level cwd, else the cwd."""
    cand = row.get("cwd") or top_cwd or os.getcwd()
    if cand not in cache:
        try:
            cache[cand] = core.owning_repo(Path(cand))
        except Exception:
            cache[cand] = None
        if cache[cand] is None and cand != (top_cwd or os.getcwd()):
            try:
                cache[cand] = core.owning_repo(Path(top_cwd or os.getcwd()))
            except Exception:
                pass
    return cache[cand]


def read_tail(path: Path):
    """Last 64 KiB of the stream, complete lines only, dicts only."""
    try:
        with open(str(path), "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            fh.seek(max(0, size - TAIL_BYTES))
            data = fh.read()
    except OSError:
        return []
    lines = data.split(b"\n")
    if size > TAIL_BYTES:
        # The first chunk starts mid-line; it belongs to an older event.
        lines = lines[1:]
    out = []
    for raw in lines:
        try:
            ev = json.loads(raw.decode("utf-8", errors="replace").replace("\r", ""))
        except ValueError:
            continue
        if isinstance(ev, dict):
            out.append(ev)
    return out


def fold(events):
    """Per-task state: last round, last check, verdict, last event index."""
    tasks = {}
    for i, ev in enumerate(events):
        tid = ev.get("task")
        if not isinstance(tid, str) or not tid:
            continue
        t = tasks.setdefault(tid, {"last_index": -1})
        t["last_index"] = i
        if ev.get("event") == "round_started":
            # A new round has no check yet: without this the row keeps showing
            # the previous round's pass/fail until the next verify lands.
            t.pop("check", None)
            if ev.get("round") is not None:
                t["round"] = ev["round"]
            if ev.get("max_rounds") is not None:
                t["max_rounds"] = ev["max_rounds"]
        elif ev.get("event") == "round_finished":
            if ev.get("round") is not None:
                t["round"] = ev["round"]
            if ev.get("max_rounds") is not None:
                t["max_rounds"] = ev["max_rounds"]
        elif ev.get("event") == "verify":
            t["check"] = {"passed": bool(ev.get("passed")),
                          "exit_code": ev.get("exit_code"),
                          "timed_out": bool(ev.get("timed_out"))}
        elif ev.get("event") == "verdict":
            t["verdict"] = ev.get("verdict")
    return tasks


def pick_task(row, tasks):
    """Which task this supervisor row shows, or None to leave it alone."""
    label = row.get("label") or ""
    desc = row.get("description") or ""
    m = LABEL_RE.match(label) if isinstance(label, str) else None
    if m:
        # An explicit label decides the row: a labelled row never shows a
        # different task, and a label with no events shows nothing.
        return m.group(1) if m.group(1) in tasks else None
    hay = " ".join(x for x in (label, desc) if isinstance(x, str))
    # Most recently active first: a supervisor re-prompted on task B should
    # stop showing task A the moment B's events exist.
    for tid in sorted(tasks, key=lambda t: tasks[t].get("last_index", -1),
                      reverse=True):
        if re.search(r"\b%s\b" % re.escape(tid), hay):
            return tid
    live = [t for t in tasks if "verdict" not in tasks[t]]
    if len(live) == 1:
        return live[0]
    return None


def content_for(tid, t):
    rnd = t.get("round", "?")
    mx = t.get("max_rounds", "?")
    if t.get("verdict") is not None:
        return "muse {} \u00b7 verdict {}".format(tid, t["verdict"])
    check = t.get("check")
    if check is None:
        status = "no check yet"
    elif check.get("timed_out"):
        status = "check timed out"
    elif check.get("passed"):
        status = "check passed"
    elif check.get("exit_code") is not None:
        status = "check FAILED (exit {})".format(check["exit_code"])
    else:
        status = "check FAILED"
    return "muse {} \u00b7 round {}/{} \u00b7 {}".format(tid, rnd, mx, status)


def run(payload):
    if not isinstance(payload, dict):
        return
    tasks_in = payload.get("tasks")
    if not isinstance(tasks_in, list):
        return
    columns = payload.get("columns")
    top_cwd = payload.get("cwd")
    cache = {}
    streams = {}
    for row in tasks_in:
        if not isinstance(row, dict):
            continue
        rid = row.get("id")
        if not rid:
            continue
        if not (str(row.get("type") or "").endswith("muse-supervisor")
                or str(row.get("name") or "").endswith("muse-supervisor")):
            continue
        repo = repo_for(row, top_cwd, cache)
        if repo is None:
            continue
        key = str(repo)
        if key not in streams:
            streams[key] = fold(read_tail(core.events_path(repo)))
        tasks = streams[key]
        tid = pick_task(row, tasks)
        if tid is None or tid not in tasks:
            continue
        text = content_for(tid, tasks[tid])
        if isinstance(columns, int) and columns > 0 and len(text) > columns:
            text = text[:columns]
        print(json.dumps({"id": rid, "content": text}), flush=True)


def main() -> int:
    try:
        raw = sys.stdin.read()
    except Exception:
        return 0
    try:
        payload = json.loads(raw)
    except ValueError:
        return 0
    try:
        run(payload)
    except Exception:
        # Every-tick process: a traceback here overwrites the status line.
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
