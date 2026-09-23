#!/bin/bash
# Fixture: parser.py with an undocumented parse(); the whole task is one edit.
set -eu
. "$(dirname "$0")/../_lib/fixture.sh"
git init -q -b main
cat > parser.py <<'EOF'
"""Tiny line-oriented record parser."""


def parse(text):
    return [line.strip() for line in text.splitlines() if line.strip()]


def parse_file(path):
    """Read path and parse its contents."""
    with open(path, encoding="utf-8") as fh:
        return parse(fh.read())
EOF
stub_muse_home
fixture_commit "eval fixture: one undocumented function"
