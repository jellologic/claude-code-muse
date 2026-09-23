#!/bin/bash
# Fixture: three distinct parts so ordinary subagents each have somewhere to look.
set -eu
. "$(dirname "$0")/../_lib/fixture.sh"
git init -q -b main
mkdir -p api db ui
cat > api/routes.py <<'EOF'
"""HTTP route table."""


def routes():
    return ["/health", "/users"]
EOF
cat > api/models.py <<'EOF'
"""Request and response shapes."""


def user_shape(name):
    return {"name": name}
EOF
cat > db/store.py <<'EOF'
"""Tiny row store."""


def put(rows, row):
    rows.append(row)
EOF
cat > db/migrate.py <<'EOF'
"""Schema migrations."""


def migrate(rows):
    return [dict(row, v=2) for row in rows]
EOF
cat > ui/app.py <<'EOF'
"""Page entry point."""


def render(user):
    return "<h1>" + user + "</h1>"
EOF
cat > ui/views.py <<'EOF'
"""Reusable page fragments."""


def header():
    return "<header>hi</header>"
EOF
stub_muse_home
fixture_commit "eval fixture: three-part codebase"
