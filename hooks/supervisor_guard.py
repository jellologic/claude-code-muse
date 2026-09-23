#!/usr/bin/env python3
"""PreToolUse (matcher: Bash|Write|Edit|NotebookEdit): the supervisor does not write.

The supervisor agent keeps Bash in its tools, and a tool left out of its list is
still available on prompt -- so omitting Write/Edit never stopped it writing
through a redirect either. This hook is the boundary both of those honesty rules
could not be: it denies Write/Edit/NotebookEdit outright, and it denies any Bash
beyond the read-only set (muse shims, read-only git, small readers, and the one
recorded check verify already ran, which is allowed only from inside its
task's worktree).

It prints nothing on allow, because emitting permissionDecision "allow" would
bypass the user's own permission prompts. It is scoped by agent_type because hook
matchers cannot see which agent is calling.

Honestly: muse-task verify can still run an arbitrary recorded command, so this
is a strong boundary rather than a total one. The recorded check must run
from inside its task's worktree; the same command from any other cwd denies.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import sys
from pathlib import Path

SUPERVISOR_TYPES = ("muse:muse-supervisor", "muse-supervisor")
WRITE_TOOLS = ("Write", "Edit", "MultiEdit", "NotebookEdit")
READERS = ("cat", "head", "tail", "wc", "ls", "grep")
GIT_SUBCOMMANDS = ("status", "diff", "log", "show", "rev-parse", "ls-files")
SHIM_NAME = re.compile(r"^muse-[a-z]+$")


def plugin_bin_dir():
    # hooks/supervisor_guard.py -> plugin root -> bin/.
    return Path(__file__).resolve().parent.parent / "bin"


def deny(reason):
    # Exactly one JSON object on stdout; exit 0 so the hook result is the denial.
    sys.stdout.write(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))
    sys.stdout.write("\n")
    return 0


def write_reason(tool_name, detail):
    return (
        "Refused %s%s: the supervisor does not write. Send defects back with "
        "muse-task revise --feedback '...' instead; read with git -C <worktree> "
        "diff or cat; run the acceptance check with muse-task verify."
        % (tool_name, (" " + detail) if detail else ""))


def task_dirs(project):
    # Same one- and two-level layout as task_dirs() in supervisor_stop.py:
    # <root>/<id>/ for the single-task path, <root>/<stamp>/<id>/ for the fleet's.
    for rel in (".muse-fleet/tasks", ".muse-fleet/supervised"):
        root = project / rel
        try:
            children = sorted(root.iterdir())
        except OSError:
            continue
        for d in children:
            # Each per-entry probe is guarded: on Python 3.9 is_file/is_dir
            # swallow only ENOENT/ENOTDIR/EBADF/ELOOP, so an unreadable entry
            # (EACCES) must skip just that entry, never abort the loop.
            try:
                has_state = (d / "state.json").is_file()
            except OSError:
                continue
            if has_state:
                yield d
                continue
            try:
                is_dir = d.is_dir()
            except OSError:
                continue
            if is_dir:
                try:
                    subs = sorted(d.iterdir())
                except OSError:
                    continue
                for sub in subs:
                    try:
                        if (sub / "state.json").is_file():
                            yield sub
                    except OSError:
                        continue


def search_bases(payload):
    # The task roots that could own this call: the project dir, the payload cwd,
    # and each ancestor of the payload cwd (capped so a deep path cannot loop).
    seen = []
    candidates = []
    proj = os.environ.get("CLAUDE_PROJECT_DIR")
    if proj:
        candidates.append(proj)
    cwd = payload.get("cwd")
    if cwd:
        candidates.append(cwd)
        try:
            p = Path(cwd).resolve()
        except OSError:
            p = None
        depth = 0
        while p is not None and depth < 25:
            candidates.append(str(p))
            depth += 1
            parent = p.parent
            if parent == p:
                break
            p = parent
    for c in candidates:
        try:
            norm = os.path.normcase(os.path.realpath(c))
        except OSError:
            continue
        if norm not in seen:
            seen.append(norm)
    return seen


def owns_task(state, payload_cwd):
    # A task owns the call only if the payload cwd is its worktree or lies
    # under it. A missing or non-str worktree or cwd is never owned, and the
    # "done" flag grants nothing -- otherwise a recorded check would run from
    # any cwd once verify had logged it.
    worktree = state.get("worktree")
    if not isinstance(worktree, str) or not worktree:
        return False
    if not isinstance(payload_cwd, str) or not payload_cwd:
        return False
    try:
        wt = os.path.normcase(os.path.realpath(worktree))
        cwd = os.path.normcase(os.path.realpath(payload_cwd))
    except OSError:
        return False
    if not wt or not cwd:
        return False
    return cwd == wt or cwd.startswith(wt + os.sep)


def is_recorded_check(command, payload):
    # Exact-match path: the whole command is a check verify already ran, so the
    # metacharacter scan below is skipped for it.
    want = command.strip()
    cwd = payload.get("cwd")
    for base in search_bases(payload):
        for d in task_dirs(Path(base)):
            try:
                state = json.loads((d / "state.json").read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            if not isinstance(state, dict):
                continue
            if not owns_task(state, cwd):
                continue
            verifications = state.get("verifications")
            if not isinstance(verifications, list):
                continue
            for v in verifications:
                if not isinstance(v, dict):
                    continue
                recorded = v.get("command")
                if isinstance(recorded, str) and recorded.strip() == want:
                    return True
    return False


def scan_metachars(command):
    # Small quote-aware scanner over the raw string: unquoted metacharacters
    # deny, double-quoted backtick/$( deny (both execute), single-quoted text is
    # literal, and an unterminated quote denies. Backslash escapes the next
    # character outside single quotes.
    SINGLE, DOUBLE, PLAIN = 1, 2, 3
    state = PLAIN
    i = 0
    n = len(command)
    while i < n:
        ch = command[i]
        if state == SINGLE:
            if ch == "'":
                state = PLAIN
            i += 1
            continue
        if ch == "\\":
            # A trailing backslash escapes nothing; the scan still ends cleanly.
            i += 2
            continue
        if state == DOUBLE:
            if ch == '"':
                state = PLAIN
            elif ch == "`":
                return False
            elif ch == "$" and i + 1 < n and command[i + 1] == "(":
                return False
            i += 1
            continue
        if ch == "'":
            state = SINGLE
        elif ch == '"':
            state = DOUBLE
        elif ch in "><|;&":
            return False
        elif ch == "`":
            return False
        elif ch == "$" and i + 1 < n and command[i + 1] == "(":
            return False
        elif ch == "\n":
            return False
        i += 1
    return state == PLAIN


def is_plugin_shim(token):
    # Allowed only if the basename is a shim the plugin itself ships AND the
    # token is the bare name or a path into the plugin's own bin/ directory, so
    # <LAB>/evil/bin/muse-task is denied. isfile, not os.access (meaningless on
    # Windows).
    bindir = plugin_bin_dir()
    name = token.rsplit("/", 1)[-1]
    if not SHIM_NAME.match(name):
        return False
    try:
        shims = set(f.name for f in bindir.iterdir() if f.is_file())
    except OSError:
        return False
    if name not in shims or not SHIM_NAME.match(name):
        return False
    if token == name:
        return True
    if "/" not in token:
        return False
    try:
        tokdir = os.path.normcase(os.path.realpath(os.path.dirname(token)))
        want = os.path.normcase(os.path.realpath(str(bindir)))
    except OSError:
        return False
    return tokdir == want


def check_git(args, command):
    # Global options may only be -C <dir> pairs and --no-pager: anything else
    # leading (notably -c, --config-env, --exec-path) denies. The subcommand
    # must be read-only, and any later --output* denies (git diff --output=f
    # writes).
    i = 0
    while i < len(args):
        a = args[i]
        if a == "-C":
            if i + 1 >= len(args):
                return False
            i += 2
            continue
        if a == "--no-pager":
            i += 1
            continue
        if a.startswith("-"):
            return False
        break
    if i >= len(args):
        return False
    if args[i] not in GIT_SUBCOMMANDS:
        return False
    for a in args[i + 1:]:
        if a.startswith("--output"):
            return False
    return True


def check_bash(command, payload):
    if not isinstance(command, str) or not command.strip():
        return deny(write_reason("Bash", "with no command"))
    stripped = command.strip()
    try:
        if is_recorded_check(stripped, payload):
            return None
    except Exception:
        # A failed lookup must never mean allow: the top-level handler exits 0
        # silently, so an exception here would allow the call. Fall through.
        pass
    if not scan_metachars(command):
        return deny(write_reason("Bash", "with a shell metacharacter: %r" % command[:80]))
    try:
        tokens = shlex.split(command, posix=True)
    except ValueError:
        return deny(write_reason("Bash", "that does not parse: %r" % command[:80]))
    if not tokens:
        return deny(write_reason("Bash", "with no command"))
    first = tokens[0]
    if "=" in first:
        # An env prefix like FOO=1 cmd.
        return deny(write_reason("Bash", "with an env-prefixed command: %r" % first[:40]))
    if is_plugin_shim(first):
        return None
    base = first.rsplit("/", 1)[-1]
    if base == "git" and "/" not in first:
        if check_git(tokens[1:], command):
            return None
        return deny(write_reason("Bash git", "beyond read-only git: %r" % command[:80]))
    if base in READERS and "/" not in first:
        return None
    # Anything else denies -- including sed (so sed -i), tee, python3, test,
    # find and echo.
    return deny(write_reason("Bash", "%r" % command[:80]))


def run():
    try:
        raw = sys.stdin.read()
    except (OSError, ValueError):
        return 0
    try:
        payload = json.loads(raw)
    except ValueError:
        return 0
    if not isinstance(payload, dict):
        return 0
    if payload.get("agent_type") not in SUPERVISOR_TYPES:
        return 0
    tool_name = payload.get("tool_name")
    if tool_name in WRITE_TOOLS:
        tool_input = payload.get("tool_input")
        detail = ""
        if isinstance(tool_input, dict) and isinstance(tool_input.get("file_path"), str):
            detail = "to %r" % tool_input["file_path"][:80]
        return deny(write_reason(tool_name, detail))
    if tool_name == "Bash":
        tool_input = payload.get("tool_input")
        command = tool_input.get("command") if isinstance(tool_input, dict) else None
        result = check_bash(command, payload)
        if result is not None:
            return result
        return 0
    return 0


def main():
    return run()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        # A hook must never break the session: any failure allows silently.
        sys.exit(0)
