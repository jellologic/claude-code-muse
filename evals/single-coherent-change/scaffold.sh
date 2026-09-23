#!/bin/bash
# Fixture: a login/refresh pair where the bug cascades across both files, so the
# fix needs whole-picture context rather than parallel workers.
set -eu
. "$(dirname "$0")/../_lib/fixture.sh"
git init -q -b main
cat > auth.py <<'EOF'
"""Login flow against an expiring session store."""
SESSIONS = {}


def login(user, session):
    """Return the user record, or None when the session expired mid-request."""
    record = SESSIONS.get(session)
    if record is None:
        return None
    if record.get("user") != user:
        return None
    if record.get("expired"):
        return None
    return record


def logout(session):
    """Drop a session from the store."""
    SESSIONS.pop(session, None)
EOF
cat > session.py <<'EOF'
"""Session refresh path that leans on auth.login."""
import auth


def refresh(user, session):
    """Refresh an expiring session; propagates login failures to the caller."""
    current = auth.login(user, session)
    if current is None:
        return None
    return {"user": user, "session": session, "refreshed": True}
EOF
cat > refresh.py <<'EOF'
"""Retry wrapper around the session refresh."""
import session


def refresh_with_retry(user, old_session, attempts=2):
    """Try the refresh path, giving up after attempts failures."""
    for _ in range(attempts):
        result = session.refresh(user, old_session)
        if result is not None:
            return result
    return None
EOF
stub_muse_home
fixture_commit "eval fixture: linked auth bug across login and refresh"
