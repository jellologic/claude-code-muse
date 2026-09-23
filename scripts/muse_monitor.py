#!/usr/bin/env python3
"""muse_monitor.py — tail the muse capability event stream for Claude.

Monitors run only in the interactive CLI, and every stdout line becomes a
notification to Claude, so stdout carries rendered events and nothing else:
config complaints go to stderr, and signals exit 0 with no traceback.

The one exception is the outside-a-repo diagnostic: when no project
directory resolves to a git repository there is no stream to watch, and
staying silent would leave Claude waiting on events that can never arrive —
so main() prints one stdout line naming the directory and exits 0 instead
of following nothing.

Python 3.9 stdlib only.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import signal
import sys
import time
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "muse_core", str(Path(__file__).resolve().parent / "muse_core.py"))
core = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(core)

ALL_KINDS = ("round_started", "round_finished", "verify", "verdict")


def _exit_quietly(_signum, _frame):
    # A monitor that dumps a traceback on SIGTERM trains nobody; exit 0.
    # core.install_signal_handlers is deliberately NOT used here: that one
    # exits 128+n, which reads as a crash in a process whose whole job is
    # to be killed when the session ends.
    sys.exit(0)


def install_handlers() -> None:
    for name in ("SIGTERM", "SIGINT", "SIGHUP"):
        if hasattr(signal, name):
            signal.signal(getattr(signal, name), _exit_quietly)


def load_config(path):
    """(enabled, kinds). Anything unreadable or misshapen means defaults.

    Monitors get no user_config, so this file is the only knob -- and a bad
    one must degrade to defaults, never to silence: the alternative is a
    monitor that stops notifying because of a typo nobody sees.
    """
    if path is None:
        return True, set(ALL_KINDS)
    try:
        raw = Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return True, set(ALL_KINDS)
    try:
        cfg = json.loads(raw)
    except ValueError:
        cfg = None
    if not isinstance(cfg, dict):
        print("muse_monitor: {} is not a JSON object; using defaults".format(path),
              file=sys.stderr)
        return True, set(ALL_KINDS)
    enabled = cfg.get("enabled", True)
    events = cfg.get("events", list(ALL_KINDS))
    if not isinstance(enabled, bool) or not isinstance(events, list) or \
            any(not isinstance(k, str) for k in events):
        print("muse_monitor: {} has the wrong shape; using defaults".format(path),
              file=sys.stderr)
        return True, set(ALL_KINDS)
    return enabled, set(events)


def _fmt(v) -> str:
    # Missing fields render as "?", never as a KeyError traceback.
    return "?" if v is None else str(v)


def _head(task, ev) -> str:
    # Fleet tasks share one repo stream, so the stamp disambiguates them.
    if ev.get("fleet"):
        return "muse[{}]".format("{}/{}".format(ev["fleet"], _fmt(task)))
    return "muse[{}]".format(_fmt(task))


def render(ev: dict):
    """One notification line, or None for an event with no rendering."""
    kind = ev.get("event")
    task = ev.get("task")
    if kind == "round_started":
        return "{} round {}/{} started ({})".format(
            _head(task, ev), _fmt(ev.get("round")),
            _fmt(ev.get("max_rounds")), _fmt(ev.get("kind")))
    if kind == "round_finished":
        if ev.get("harvest_error"):
            # The patch was never saved, so a line count would be a lie:
            # name the failure instead.
            return "{} round {}/{} finished: {}, harvest failed: {}".format(
                _head(task, ev), _fmt(ev.get("round")),
                _fmt(ev.get("max_rounds")), _fmt(ev.get("status")),
                ev.get("harvest_error"))
        if "patch_lines" not in ev:
            # Interrupted before any harvest ran: the count is unknown, and a
            # zero would read as "the worker produced nothing".
            return "{} round {}/{} finished: {}".format(
                _head(task, ev), _fmt(ev.get("round")),
                _fmt(ev.get("max_rounds")), _fmt(ev.get("status")))
        return "{} round {}/{} finished: {}, {} patch lines".format(
            _head(task, ev), _fmt(ev.get("round")),
            _fmt(ev.get("max_rounds")), _fmt(ev.get("status")),
            _fmt(ev.get("patch_lines")))
    if kind == "verify":
        if ev.get("timed_out"):
            return "{} check timed out after round {}/{}".format(
                _head(task, ev), _fmt(ev.get("round")),
                _fmt(ev.get("max_rounds")))
        if ev.get("passed"):
            return "{} check passed after round {}/{}".format(
                _head(task, ev), _fmt(ev.get("round")),
                _fmt(ev.get("max_rounds")))
        return "{} check FAILED (exit {}) after round {}/{}".format(
            _head(task, ev), _fmt(ev.get("exit_code")),
            _fmt(ev.get("round")), _fmt(ev.get("max_rounds")))
    if kind == "verdict":
        return "{} verdict: {} ({}/{} rounds, {})".format(
            _head(task, ev), _fmt(ev.get("verdict")),
            _fmt(ev.get("rounds_used")), _fmt(ev.get("max_rounds")),
            "verified" if ev.get("verified") else "unverified")
    return None


def one_line(text, limit=300):
    # Each stdout line is a separate notification to Claude, so a multi-line
    # reason would split one event into several notifications — and an
    # unbounded reason would flood the notification stream.
    if not isinstance(text, str):
        text = str(text)
    pieces = [p.strip() for p in text.replace("\r\n", "\n").replace("\r", "\n").split("\n")]
    collapsed = " | ".join(p for p in pieces if p)
    if len(collapsed) > limit:
        collapsed = collapsed[:limit - 3] + "..." if limit >= 3 else collapsed[:limit]
    return collapsed


def emit(line: str) -> None:
    try:
        print(line, flush=True)
    except BrokenPipeError:
        # Claude went away; dying loudly about it helps nobody.
        sys.exit(0)


def handle_line(raw: bytes, kinds) -> None:
    try:
        ev = json.loads(raw.decode("utf-8", errors="replace").replace("\r", ""))
    except ValueError:
        return
    if not isinstance(ev, dict):
        return
    if ev.get("event") not in kinds:
        return
    try:
        line = render(ev)
    except Exception:
        return
    if line:
        emit(one_line(line))


def dump(path: Path, kinds) -> None:
    try:
        with open(str(path), "rb") as fh:
            for raw in fh:
                handle_line(raw.rstrip(b"\n"), kinds)
    except OSError:
        pass


def follow(path: Path, kinds, poll: float, from_start: bool) -> None:
    try:
        offset = 0 if from_start else os.path.getsize(str(path))
    except OSError:
        offset = 0
    buf = b""
    while True:
        try:
            size = os.path.getsize(str(path))
        except OSError:
            # Not there yet (or rotated away): wait for it to appear.
            time.sleep(poll)
            continue
        if size < offset:
            # Truncated or replaced; the old offset points past EOF.
            offset, buf = 0, b""
        if size > offset:
            try:
                with open(str(path), "rb") as fh:
                    fh.seek(offset)
                    chunk = fh.read(size - offset)
            except OSError:
                time.sleep(poll)
                continue
            offset = size
            # A trailing partial line waits for its newline next poll: a
            # torn write must not become a torn notification.
            pieces = (buf + chunk).split(b"\n")
            if chunk.endswith(b"\n"):
                complete, buf = pieces[:-1], b""
            else:
                complete, buf = pieces[:-1], pieces[-1]
            for raw in complete:
                handle_line(raw, kinds)
        time.sleep(poll)


def _resolve_project(explicit):
    """First usable project dir: --project, CLAUDE_PROJECT_DIR, then cwd.

    The monitor command carries ${CLAUDE_PROJECT_DIR} unsubstituted when the
    substitution is unavailable, so a candidate that is empty, still holds a
    "${", or is not an existing directory means "not given", not an error.
    """
    cands = [explicit, os.environ.get("CLAUDE_PROJECT_DIR"), os.getcwd()]
    for cand in cands:
        if isinstance(cand, str) and cand and "${" not in cand \
                and os.path.isdir(cand):
            return cand
    return None


def main(argv=None) -> int:
    install_handlers()
    ap = argparse.ArgumentParser(description="Tail muse capability events.")
    ap.add_argument("--project", default=None)
    ap.add_argument("--file", default=None)
    ap.add_argument("--config", default=None)
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--from-start", action="store_true")
    ap.add_argument("--poll", type=float, default=1.0)
    args = ap.parse_args(argv)
    try:
        if args.file:
            path = Path(args.file)
        else:
            project = _resolve_project(args.project)
            try:
                repo = core.owning_repo(Path(project)) if project is not None else None
            except Exception:
                repo = None
            if repo is None:
                # No git repo to watch: no events can ever arrive here. This
                # is stdout, not stderr, because a monitor's stdout lines are
                # what reach Claude and stderr does not -- silence would leave
                # Claude waiting on a stream that does not exist.
                print(one_line("muse monitor: {} is not inside a git repository; "
                             "not watching for muse events".format(project)),
                      flush=True)
                return 0
            path = core.events_path(repo)
        cfg = args.config
        if not cfg or "${" in cfg:
            # Empty or unsubstituted: behave as if no config was passed.
            cfg = None
        enabled, kinds = load_config(cfg)
        if not enabled:
            return 0
        if args.once:
            dump(path, kinds)
            return 0
        follow(path, kinds, args.poll, args.from_start)
    except KeyboardInterrupt:
        return 0
    except BrokenPipeError:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
