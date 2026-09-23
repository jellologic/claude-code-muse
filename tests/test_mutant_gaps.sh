# shellcheck shell=bash
# Gap checks for mutants M14 (doctor muse-version comparison) and M16
# (muse-status "last check exited N" flag). Sourced by scripts/validate.sh
# (one line) and runnable standalone for a fast loop.
if ! declare -F ok >/dev/null 2>&1; then GP_STANDALONE=1; PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  PASS  $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && echo "        $2"; }; SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; LAB="$(mktemp -d "${TMPDIR:-/tmp}/ggaps.XXXXXX")"; shell_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi; }; fi

# MUSE_TESTED_VERSION is the only version that may appear literally: the stub
# versions are derived from it, so a bump cannot silently desync the fixtures.
GP_TESTED="$(python3 - "$SKILL/scripts/muse_core.py" <<'PY'
import importlib.util
import sys
spec = importlib.util.spec_from_file_location("mcc", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(m.MUSE_TESTED_VERSION)
PY
)"
# version_mismatch compares major.minor only, so the "different" stub must move
# major or minor; a patch-only move would warn under neither code path.
GP_MAJOR="${GP_TESTED%%.*}"
GP_NEWV="$((GP_MAJOR + 1)).0.0"

GP_BASE="$LAB/v_gaps"
GP_NEWDIR="$GP_BASE/stub_new"
GP_OKDIR="$GP_BASE/stub_ok"
mkdir -p "$GP_NEWDIR" "$GP_OKDIR"
printf '#!/bin/sh\necho "muse %s"\n' "$GP_NEWV" > "$GP_NEWDIR/muse"
printf '#!/bin/sh\necho "muse %s"\n' "$GP_TESTED" > "$GP_OKDIR/muse"
chmod +x "$GP_NEWDIR/muse" "$GP_OKDIR/muse"
if command -v cygpath >/dev/null 2>&1; then
  printf '@echo off\r\necho muse %s\r\n' "$GP_NEWV" > "$GP_NEWDIR/muse.cmd"
  printf '@echo off\r\necho muse %s\r\n' "$GP_TESTED" > "$GP_OKDIR/muse.cmd"
fi

# The value string alone cannot kill M14: even under the mutant it prints both
# version numbers ("muse 2.0.0 (verified against 1.3.0)"). Only the severity
# plus both versions across value+fix separates the warn path from the OK path.
GP_JSON="$(env PATH="$(shell_path "$GP_NEWDIR"):$PATH" python3 "$SKILL/scripts/muse_doctor.py" --repo "$SKILL" --json 2>/dev/null)"
if printf '%s' "$GP_JSON" | python3 -c "
import json,sys
newv, tested = sys.argv[1], sys.argv[2]
d = json.load(sys.stdin)
assert isinstance(d.get('checks'), list) and d['checks'], 'empty checks list'
rows = [c for c in d['checks'] if c['name'] == 'muse binary']
assert rows, 'no muse binary row'
r = rows[0]
assert r['severity'] in ('WARN', 'FAIL'), 'severity is %r' % r['severity']
assert newv in (r['value'] + ' ' + r['fix']), 'stub version missing'
assert tested in (r['value'] + ' ' + r['fix']), 'tested version missing'
" "$GP_NEWV" "$GP_TESTED"; then
  ok "gaps: doctor warns on a muse of a different major.minor, naming both versions"
else
  bad "gaps: doctor warns on a muse of a different major.minor, naming both versions" "new=$GP_NEWV tested=$GP_TESTED"
fi

GP_JSON="$(env PATH="$(shell_path "$GP_OKDIR"):$PATH" python3 "$SKILL/scripts/muse_doctor.py" --repo "$SKILL" --json 2>/dev/null)"
if printf '%s' "$GP_JSON" | python3 -c "
import json,sys
d = json.load(sys.stdin)
assert isinstance(d.get('checks'), list) and d['checks'], 'empty checks list'
rows = [c for c in d['checks'] if c['name'] == 'muse binary']
assert rows, 'no muse binary row'
assert rows[0]['severity'] == 'OK', 'severity is %r' % rows[0]['severity']
"; then
  ok "gaps: doctor passes a muse at the tested version"
else
  bad "gaps: doctor passes a muse at the tested version" "tested=$GP_TESTED"
fi

GP_FLEET="$GP_BASE/fleet"
mkdir -p "$GP_FLEET/t1"
printf '%s' '{"id":"t1","max_rounds":3,"rounds":[{"n":1,"kind":"initial"}],"verifications":[{"command":"false","exit_code":3,"passed":false}]}' > "$GP_FLEET/t1/state.json"

# The text output always shows "check: false -> exit 3" even under M16, so
# matching "exit 3" anywhere proves nothing; only the !! flag line kills it.
GP_OUT="$(python3 "$SKILL/scripts/muse_status.py" --out "$GP_FLEET" 2>/dev/null)"
if [ -n "$GP_OUT" ] && printf '%s' "$GP_OUT" | grep -q "t1"; then
  if printf '%s\n' "$GP_OUT" | grep -q '!! last check exited 3'; then
    ok "gaps: muse-status text flags 'last check exited 3'"
  else
    bad "gaps: muse-status text flags 'last check exited 3'" "flag line missing"
  fi
else
  bad "gaps: muse-status text flags 'last check exited 3'" "empty output or t1 missing -- the flag assertion would measure nothing"
fi

# Same trap in JSON: "last_exit": 3 survives M16 untouched, so only membership
# in the task's flags list separates the flag path from the dropped one.
GP_JSON="$(python3 "$SKILL/scripts/muse_status.py" --out "$GP_FLEET" --json 2>/dev/null)"
if printf '%s' "$GP_JSON" | python3 -c "
import json,sys
d = json.load(sys.stdin)
tasks = d.get('tasks') or []
rows = [t for t in tasks if t.get('id') == 't1']
assert rows, 'no t1 task'
assert 'last check exited 3' in (rows[0].get('flags') or []), 'flag missing: %r' % (rows[0].get('flags'),)
"; then
  ok "gaps: muse-status --json flags 'last check exited 3'"
else
  bad "gaps: muse-status --json flags 'last check exited 3'" "flag not in t1 flags list"
fi

# The flag is about the LAST check: a red check followed by a green one must
# leave no "last check exited" flag. An absence assertion on empty input proves
# nothing, so the parse, the single task and the flags list are preconditions.
GP_FLEET2="$GP_BASE/fleet2"
mkdir -p "$GP_FLEET2/t2"
printf '%s' '{"id":"t2","max_rounds":3,"rounds":[{"n":1,"kind":"initial"}],"verifications":[{"command":"false","exit_code":3,"passed":false},{"command":"true","exit_code":0,"passed":true}]}' > "$GP_FLEET2/t2/state.json"
GP_JSON="$(python3 "$SKILL/scripts/muse_status.py" --out "$GP_FLEET2" --json 2>/dev/null)"
if printf '%s' "$GP_JSON" | python3 -c "
import json,sys
d = json.load(sys.stdin)
tasks = d.get('tasks') or []
assert len(tasks) == 1 and tasks[0].get('id') == 't2', 'want exactly the t2 task, got %r' % ([t.get('id') for t in tasks],)
flags = tasks[0].get('flags')
assert isinstance(flags, list), 'flags is not a list'
assert not [f for f in flags if f.startswith('last check exited')], 'unexpected flag: %r' % (flags,)
"; then
  ok "gaps: a task whose last check exited 0 carries no 'last check exited' flag"
else
  bad "gaps: a task whose last check exited 0 carries no 'last check exited' flag" "stale flag present or fixture unreadable"
fi

if [ "${GP_STANDALONE:-0}" = 1 ]; then rm -rf "$LAB"; echo "RESULT: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit $?; fi
