#!/bin/bash
# Fixture: three small tasks, of which only the rename has an executable check.
set -eu
. "$(dirname "$0")/../_lib/fixture.sh"
git init -q -b main
cat > README.md <<'EOF'
# Scheduler

This tool runs jobs. It is old and cranky and the docs reflect that.

## Usage

Run `python scheduler.py` and hope for the best.
EOF
cat > scheduler.py <<'EOF'
"""A tiny job scheduler."""


def schedule(mgr, job):
    """Register job with the manager."""
    mgr.add(job)
    return mgr.pending()


def run_all(mgr):
    """Run every pending job the manager holds."""
    results = []
    for job in mgr.pending():
        results.append(job())
    return results
EOF
cat > errors.py <<'EOF'
"""Error strings, currently written in ALL CAPS."""

NOT_FOUND = "ERROR: JOB NOT FOUND!!!"
ALREADY_DONE = "ERROR: JOB ALREADY FINISHED!!!"
QUEUE_FULL = "ERROR: QUEUE IS FULL!!!"
EOF
mkdir -p tests
cat > tests/test_scheduler.py <<'EOF'
"""Executable check for the scheduler rename."""
import scheduler


class FakeManager:
    def __init__(self):
        self.jobs = []

    def add(self, job):
        self.jobs.append(job)

    def pending(self):
        return list(self.jobs)


def test_schedule_registers_job():
    mgr = FakeManager()
    scheduler.schedule(mgr, lambda: 1)
    assert len(mgr.pending()) == 1
EOF
stub_muse_home
fixture_commit "eval fixture: three tasks, one executable check"
