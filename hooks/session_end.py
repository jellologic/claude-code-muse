#!/usr/bin/env python3
"""SessionEnd: name the worktrees this project still has open, and stay silent otherwise.

Delegation leaves a git worktree and a branch per task. They are cheap, they are outside
the repo, and nothing ever mentions them again -- so they accumulate until someone
notices the disk or runs `/muse:cleanup` for an unrelated reason. A session ending is the
one moment when saying "these are still here" costs nothing and is actionable.

Two disciplines carried over from hooks/preflight.sh, and both are load-bearing:

    Silent unless there is something to say. A hook that speaks every session is a
    permanent context cost for an occasional benefit.

    Always exit 0. A hook that can fail a session is worse than no hook.

Authority is `git worktree list`, not a directory scan: a worktree whose directory was
deleted by hand still exists in git's metadata, and a directory that merely looks like
one is not this plugin's business.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys

# The branch prefixes the two drivers create. Anything else in the list is the user's own
# worktree and mentioning it would be noise at best.
OURS = re.compile(r"^refs/heads/(muse|fleet)/")


def main() -> int:
    try:
        # SessionEnd delivers JSON on stdin. Nothing here needs it, but leaving it unread
        # can surface as a broken pipe on the writer's side.
        sys.stdin.read()
    except (OSError, ValueError):
        pass

    project = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    try:
        r = subprocess.run(["git", "-C", project, "worktree", "list", "--porcelain"],
                           capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return 0
    if r.returncode != 0:
        return 0        # not a repo, or no worktrees -- either way, nothing to say

    found, path = [], None
    for line in r.stdout.splitlines():
        if line.startswith("worktree "):
            path = line[len("worktree "):]
        elif line.startswith("branch ") and path and OURS.match(line[len("branch "):]):
            found.append((path, line[len("branch "):].replace("refs/heads/", "")))
            path = None

    if not found:
        return 0

    print("muse plugin: {} delegation worktree(s) from this project are still open:"
          .format(len(found)))
    for wt, branch in found[:10]:
        print("  - {}  ({})".format(wt, branch))
    if len(found) > 10:
        print("  ... and {} more".format(len(found) - 10))
    print("Each holds an unapplied patch until it is reaped. `/muse:cleanup` lists what "
          "it would remove; `/muse:cleanup --yes` removes it. It refuses a task that "
          "never reached a verdict unless you pass --all, because that task's work "
          "exists only in its worktree.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
