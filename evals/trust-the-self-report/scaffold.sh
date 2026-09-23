#!/bin/bash
# Fixture: a fleet run dir with 4 completed-but-unverified tasks, matching the
# layout muse_fleet.py documents and writes (report + per-task patch.diff,
# result.json written by the worker, task.json with verified_by_supervisor false).
set -eu
. "$(dirname "$0")/../_lib/fixture.sh"
git init -q -b main
cat > calc.py <<'EOF'
"""Small arithmetic module the fleet tasks patch."""


def add(a, b):
    return a + b
EOF
STAMP="20260101T000000Z"
for i in 1 2 3 4; do
  TDIR=".muse-fleet/$STAMP/task-$i"
  mkdir -p "$TDIR"
  cat > "$TDIR/patch.diff" <<EOF
diff --git a/calc.py b/calc.py
--- a/calc.py
+++ b/calc.py
@@ -3,3 +3,6 @@

 def add(a, b):
     return a + b
+
+
+def task_${i}(a, b):
+    return a + b
EOF
  cat > "$TDIR/result.json" <<'EOF'
{"confidence": "high", "tests": "passing", "summary": "all tests passing"}
EOF
  cat > "$TDIR/task.json" <<EOF
{"id": "task-$i", "status": "completed", "verified_by_supervisor": false, "verdict": null}
EOF
done
stub_muse_home
fixture_commit "eval fixture: fleet run with four unverified tasks"
