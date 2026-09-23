# shellcheck shell=bash
# The offline count guard must count executed checks (PASS+FAIL), not skips: a
# SKIP is a check that did not run, and the old PASS+FAIL+SKIP tally let a
# machine without node stay green with fewer executed checks. Sourced by
# scripts/validate.sh (one line) and runnable standalone for a fast loop.
if ! declare -F ok >/dev/null 2>&1; then CG_STANDALONE=1; PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  PASS  $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && echo "        $2"; }; SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; LAB="$(mktemp -d "${TMPDIR:-/tmp}/cgtest.XXXXXX")"; fi

# Lift the real definitions out of validate.sh -- the probe runs the shipped
# guard, not a copy of it, so a regression in the source breaks this test.
CG_EXTRACT="$(python3 - "$SKILL/scripts/validate.sh" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
assert lines.count("PASS=0; FAIL=0; SKIP=0") == 1, "start anchor not found exactly once"
heads = [i for i, l in enumerate(lines) if l.startswith("head_()")]
assert len(heads) == 1, "head_() anchor not found exactly once"
start = lines.index("PASS=0; FAIL=0; SKIP=0")
extract = lines[start:heads[0]]
assert extract, "extract is empty"
blob = "\n".join(extract)
assert "offline_count_guard()" in blob, "guard function missing from extract"
assert "EXPECTED_OFFLINE=" in blob, "EXPECTED_OFFLINE missing from extract"
print(blob)
PY
)"; CG_RC=$?
if [ "$CG_RC" -eq 0 ] && [ -n "$CG_EXTRACT" ]; then
  ok "count guard extract holds the shipped definitions"
else
  bad "count guard extract holds the shipped definitions" "rc=$CG_RC"
fi

CG_EXPECTED="$(printf '%s\n' "$CG_EXTRACT" | sed -n 's/^EXPECTED_OFFLINE=\([0-9][0-9]*\)$/\1/p')"
if printf '%s' "$CG_EXPECTED" | grep -q '^[0-9][0-9]*$'; then
  ok "EXPECTED_OFFLINE is numeric ($CG_EXPECTED)"
else
  bad "EXPECTED_OFFLINE is numeric" "got '$CG_EXPECTED'"
fi

mkdir -p "$LAB/v_countguard"
{
  printf '#!/usr/bin/env bash\n'
  printf '%s\n' "$CG_EXTRACT"
  cat <<'PROBE'
n="$1"; s="$2"; i=0; while [ "$i" -lt "$n" ]; do ok "p$i" >/dev/null; i=$((i+1)); done
[ "$s" -gt 0 ] && skip "$s" probe >/dev/null
offline_count_guard
[ "$FAIL" -eq 0 ]
PROBE
} > "$LAB/v_countguard/probe.sh"
chmod +x "$LAB/v_countguard/probe.sh"

CG_OUT="$(CI= bash "$LAB/v_countguard/probe.sh" "$CG_EXPECTED" 0 2>&1)"; CG_RC=$?
if [ "$CG_RC" -eq 0 ]; then
  ok "count guard passes a full run with no skips"
else
  bad "count guard passes a full run with no skips" "rc=$CG_RC out: $CG_OUT"
fi

# One executed check swapped for a skip: PASS+FAIL is EXPECTED-1, so this must
# fail. Under the old PASS+FAIL+SKIP tally it passed, which is the defect.
CG_OUT="$(CI= bash "$LAB/v_countguard/probe.sh" "$((CG_EXPECTED-1))" 1 2>&1)"; CG_RC=$?
if [ "$CG_RC" -ne 0 ] && printf '%s\n' "$CG_OUT" | grep -q "EXPECTED_OFFLINE"; then
  ok "count guard fails when a check is skipped instead of run"
else
  bad "count guard fails when a check is skipped instead of run" "rc=$CG_RC out: $CG_OUT"
fi

CG_OUT="$(CI= bash "$LAB/v_countguard/probe.sh" "$((CG_EXPECTED-1))" 0 2>&1)"; CG_RC=$?
if [ "$CG_RC" -ne 0 ]; then
  ok "count guard fails when a check is deleted"
else
  bad "count guard fails when a check is deleted" "rc=$CG_RC out: $CG_OUT"
fi

if [ "${CG_STANDALONE:-0}" = 1 ]; then rm -rf "$LAB"; echo "RESULT: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit $?; fi
