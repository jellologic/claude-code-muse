# shellcheck shell=bash
# The claude CLI floor lives in scripts/muse_core.py alone: CI installs it via
# the doctor flag and the doctor warns below it. Sourced by scripts/validate.sh
# (one line) and runnable standalone for a fast loop.
if ! declare -F ok >/dev/null 2>&1; then CV_STANDALONE=1; PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  PASS  $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && echo "        $2"; }; SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; LAB="$(mktemp -d "${TMPDIR:-/tmp}/cvtest.XXXXXX")"; shell_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi; }; fi

CV_MIN="$(python3 "$SKILL/scripts/muse_doctor.py" --min-claude-version 2>/dev/null)"
CV_BASE="$LAB/v_claudever"
for CV_V in "2.1.99" "$CV_MIN" "9.0.0"; do
  case "$CV_V" in
    "2.1.99") CV_D="$CV_BASE/old" ;;
    "9.0.0") CV_D="$CV_BASE/new" ;;
    *) CV_D="$CV_BASE/exact" ;;
  esac
  mkdir -p "$CV_D"
  printf '#!/bin/sh\necho "%s (Claude Code)"\n' "$CV_V" > "$CV_D/claude"
  chmod +x "$CV_D/claude"
  if command -v cygpath >/dev/null 2>&1; then
    printf '@echo off\r\necho %s (Claude Code)\r\n' "$CV_V" > "$CV_D/claude.cmd"
  fi
done

# A native Windows python only finds PATHEXT files, which is why the .cmd
# mirrors exist -- the same reason validate.sh builds its muse stub that way.
CV_JSON="$(python3 "$SKILL/scripts/muse_doctor.py" --repo "$SKILL" --json 2>/dev/null)"
if printf '%s' "$CV_JSON" | python3 -c "
import json,sys
d = json.load(sys.stdin)
sys.exit(0 if isinstance(d.get('checks'), list) and d['checks'] else 1)"; then
  ok "doctor --json parses with a non-empty checks list"
else
  bad "doctor --json parses with a non-empty checks list" "the version assertions below would measure nothing"
fi

CV_row() {  # CV_row <dir>: prints severity, then value, of the claude CLI row
  env PATH="$(shell_path "$1"):$PATH" python3 "$SKILL/scripts/muse_doctor.py" \
    --repo "$SKILL" --json 2>/dev/null | python3 -c "
import json,sys
d = json.load(sys.stdin)
assert isinstance(d.get('checks'), list) and d['checks'], 'empty checks list'
r = [c for c in d['checks'] if c['name'] == 'claude CLI']
assert r, 'no claude CLI row'
print(r[0]['severity'])
print(r[0]['value'])"
}

CV_OUT="$(CV_row "$CV_BASE/old")"; CV_RC=$?
CV_SEV="$(printf '%s\n' "$CV_OUT" | sed -n '1p')"; CV_VAL="$(printf '%s\n' "$CV_OUT" | sed -n '2p')"
if [ "$CV_RC" -eq 0 ] && [ -n "$CV_SEV" ] \
    && [ "$CV_SEV" = "WARN" ] \
    && printf '%s' "$CV_VAL" | grep -q "2.1.99" \
    && printf '%s' "$CV_VAL" | grep -q "$CV_MIN"; then
  ok "doctor warns on a claude CLI below the floor (2.1.99 counts as older than $CV_MIN)"
else
  bad "doctor warns on a claude CLI below the floor" "rc=$CV_RC sev=$CV_SEV val=$CV_VAL"
fi

CV_OUT="$(CV_row "$CV_BASE/exact")"; CV_RC=$?
CV_SEV="$(printf '%s\n' "$CV_OUT" | sed -n '1p')"
if [ "$CV_RC" -eq 0 ] && [ "$CV_SEV" = "OK" ]; then
  ok "doctor passes a claude CLI exactly at the floor"
else
  bad "doctor passes a claude CLI exactly at the floor" "rc=$CV_RC sev=$CV_SEV out=$CV_OUT"
fi

CV_OUT="$(CV_row "$CV_BASE/new")"; CV_RC=$?
CV_SEV="$(printf '%s\n' "$CV_OUT" | sed -n '1p')"
if [ "$CV_RC" -eq 0 ] && [ "$CV_SEV" = "OK" ]; then
  ok "doctor passes a claude CLI above the floor"
else
  bad "doctor passes a claude CLI above the floor" "rc=$CV_RC sev=$CV_SEV out=$CV_OUT"
fi

CV_FLAG="$(python3 - "$SKILL/scripts/muse_core.py" "$CV_MIN" <<'PY'
import importlib.util
import re
import sys
spec = importlib.util.spec_from_file_location("mcc", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
flag = sys.argv[2]
mine = m.MIN_CLAUDE_VERSION
if flag == mine and re.match(r"^[0-9]+\.[0-9]+\.[0-9]+$", mine):
    print("CV_FLAG_OK " + mine)
else:
    print("flag=%r core=%r" % (flag, mine))
PY
)"
if [ "$CV_FLAG" = "CV_FLAG_OK $CV_MIN" ]; then
  ok "--min-claude-version prints the muse_core floor ($CV_MIN)"
else
  bad "--min-claude-version prints the muse_core floor" "$CV_FLAG"
fi

# The CI YAML cannot be executed offline -- there is no runner and no npm here --
# so this one check inspects its text rather than running it. That is the only
# justified text inspection in this file; everything above runs the real doctor.
CV_YML="$SKILL/.github/workflows/validate.yml"
if [ ! -s "$CV_YML" ]; then
  bad "CI installs the claude CLI from the doctor floor" "workflow file is missing or empty -- the check measured nothing"
elif ! grep -q "npm install -g" "$CV_YML"; then
  bad "CI installs the claude CLI from the doctor floor" "no install step found -- the check measured nothing"
elif grep -q "muse_doctor.py --min-claude-version" "$CV_YML" \
    && ! grep -q 'claude-code@[0-9]' "$CV_YML" \
    && ! grep -q 'MIN_CLAUDE_VERSION: "' "$CV_YML"; then
  ok "CI installs the claude CLI from the doctor floor"
else
  bad "CI installs the claude CLI from the doctor floor" "the workflow still pins or duplicates the version"
fi

if [ "${CV_STANDALONE:-0}" = 1 ]; then rm -rf "$LAB"; echo "RESULT: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit $?; fi
