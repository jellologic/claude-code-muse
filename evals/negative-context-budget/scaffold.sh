#!/bin/bash
# Fixture: a repo that plausibly reads as large — several dirs plus one big
# generated JSON file. Pure shell (no python/jot/seq) for portability; the loop
# writes roughly 250 KB and the whole fixture stays well under 1 MB.
set -eu
. "$(dirname "$0")/../_lib/fixture.sh"
git init -q -b main
mkdir -p src docs tests data
cat > src/main.py <<'EOF'
"""Entry point."""


def main():
    print("big repo energy")
EOF
cat > src/worker.py <<'EOF'
"""Background worker."""


def work(item):
    return item
EOF
echo "# Docs" > docs/guide.md
echo "# Changelog" > docs/changelog.md
cat > tests/test_main.py <<'EOF'
"""Smoke test."""


def test_true():
    assert True
EOF
{
  echo "["
  i=1
  while [ "$i" -le 2500 ]; do
    printf '  {"id": %s, "name": "fixture-row-%s", "payload": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"},\n' "$i" "$i"
    i=$((i + 1))
  done
  echo "]"
} > data/fixtures.json
stub_muse_home
fixture_commit "eval fixture: large-looking repo with generated data"
