#!/bin/bash
# Fixture: utils.py owns helper(); two other modules import and call it, so a
# rename must span files and the three edits collide on one file.
set -eu
. "$(dirname "$0")/../_lib/fixture.sh"
git init -q -b main
cat > utils.py <<'EOF'
"""Shared string helpers."""


def helper(name):
    return name.strip().lower()


def format_name(name):
    return helper(name).title()


def slugify(name):
    return helper(name).replace(" ", "-")
EOF
cat > app.py <<'EOF'
"""CLI entry point that greets one user."""
from utils import helper


def greet(raw_name):
    return "hello " + helper(raw_name)


def main(name):
    print(greet(name))
EOF
cat > tasks.py <<'EOF'
"""Background jobs that normalise labels."""
import utils


def normalise_label(label):
    return utils.helper(label)


def run(labels):
    return [normalise_label(label) for label in labels]
EOF
stub_muse_home
fixture_commit "eval fixture: shared helper used across files"
