#!/bin/bash
# Fixture: four small modules with public functions and deliberately no tests.
set -eu
. "$(dirname "$0")/../_lib/fixture.sh"
git init -q -b main
cat > parser.py <<'EOF'
"""Tiny line-oriented record parser."""


def parse(text):
    """Split text into a list of stripped, non-empty lines."""
    return [line.strip() for line in text.splitlines() if line.strip()]


def parse_file(path):
    """Read path and parse its contents."""
    with open(path, encoding="utf-8") as fh:
        return parse(fh.read())


def tokenize(text):
    """Split text on whitespace into tokens."""
    return text.split()
EOF
cat > validator.py <<'EOF'
"""Record shape validation."""


def validate(record):
    """Return True when record is a dict with a non-empty id."""
    return isinstance(record, dict) and bool(record.get("id"))


def check_schema(record, required):
    """Return the list of required keys missing from record."""
    return [key for key in required if key not in record]
EOF
cat > cache.py <<'EOF'
"""A small in-memory cache with explicit invalidation."""


def make_cache():
    """Create a new empty cache dict."""
    return {}


def set(cache, key, value):
    """Store value under key."""
    cache[key] = value


def get(cache, key, default=None):
    """Fetch key, returning default when absent."""
    return cache.get(key, default)


def invalidate(cache, key):
    """Drop key from the cache when present."""
    cache.pop(key, None)
EOF
cat > retry.py <<'EOF'
"""Retry helpers for flaky calls."""


def retry(func, attempts=3):
    """Call func until it succeeds or attempts run out."""
    last = None
    for _ in range(attempts):
        try:
            return func()
        except Exception as exc:  # noqa: BLE001 - retryable by contract
            last = exc
    raise last


def with_backoff(attempt):
    """Return a wait in seconds for a 1-based attempt number."""
    return min(2 ** attempt, 30)
EOF
stub_muse_home
fixture_commit "eval fixture: four untested modules"
