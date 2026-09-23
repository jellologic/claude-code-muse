# shellcheck shell=bash
# The stamp-entropy guard must look for a real secrets.token_hex CALL, not the
# name in text: a docstring or string constant naming token_hex satisfies a
# string match while computing collideable stamps. Sourced by scripts/validate.sh
# (one line) and runnable standalone for a fast loop.
if ! declare -F ok >/dev/null 2>&1; then SG_STANDALONE=1; PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  PASS  $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && echo "        $2"; }; SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; LAB="$(mktemp -d "${TMPDIR:-/tmp}/sgtest.XXXXXX")"; fi
SG_CHK="$SKILL/tests/stamp_entropy_check.py"

SG_OUT="$(python3 "$SG_CHK" "$SKILL" 2>&1)"; SG_RC=$?
if [ "$SG_RC" -eq 0 ]; then
  ok "stamp guard passes the shipped drivers"
else
  bad "stamp guard passes the shipped drivers" "rc=$SG_RC out: $SG_OUT"
fi

# A docstring naming token_hex satisfies the OLD ast.dump string match, so this
# case is the point of the guard: it must fail here and name muse_fleet.py.
SG_CASE="$LAB/v_stampguard/fleet_docstring"; mkdir -p "$SG_CASE/scripts"
cp "$SKILL/scripts/muse_task.py" "$SKILL/scripts/muse_fleet.py" "$SG_CASE/scripts/"
python3 - "$SG_CASE/scripts/muse_fleet.py" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
old = ('    return "{}-{}".format(dt.datetime.now().strftime("%Y%m%d-%H%M%S"),\n'
       '                          secrets.token_hex(4))')
assert text.count(old) == 1, "fleet stamp snippet not found exactly once"
new = ('    """Entropy comes from secrets.token_hex(4)."""\n'
       '    return dt.datetime.now().strftime("%Y%m%d-%H%M%S")')
open(path, "w", encoding="utf-8").write(text.replace(old, new, 1))
PY
if cmp -s "$SG_CASE/scripts/muse_fleet.py" "$SKILL/scripts/muse_fleet.py"; then
  bad "stamp guard refuses a docstring in place of entropy" "rewrite left the file byte-identical -- the test measured nothing"
else
  SG_OUT="$(python3 "$SG_CHK" "$SG_CASE" 2>&1)"; SG_RC=$?
  if [ "$SG_RC" -ne 0 ] && printf '%s\n' "$SG_OUT" | grep -q "muse_fleet.py"; then
    ok "stamp guard refuses a docstring in place of entropy"
  else
    bad "stamp guard refuses a docstring in place of entropy" "rc=$SG_RC out: $SG_OUT"
  fi
fi

# A string constant naming token_hex is an ast.Constant, never a Call.
SG_CASE="$LAB/v_stampguard/task_string"; mkdir -p "$SG_CASE/scripts"
cp "$SKILL/scripts/muse_task.py" "$SKILL/scripts/muse_fleet.py" "$SG_CASE/scripts/"
python3 - "$SG_CASE/scripts/muse_task.py" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
assert text.count("secrets.token_hex(4))") == 1, "task stamp snippet not found exactly once"
open(path, "w", encoding="utf-8").write(text.replace("secrets.token_hex(4))", '"secrets.token_hex(4)")', 1))
PY
if cmp -s "$SG_CASE/scripts/muse_task.py" "$SKILL/scripts/muse_task.py"; then
  bad "stamp guard refuses a string constant in place of entropy" "rewrite left the file byte-identical -- the test measured nothing"
else
  SG_OUT="$(python3 "$SG_CHK" "$SG_CASE" 2>&1)"; SG_RC=$?
  if [ "$SG_RC" -ne 0 ] && printf '%s\n' "$SG_OUT" | grep -q "muse_task.py"; then
    ok "stamp guard refuses a string constant in place of entropy"
  else
    bad "stamp guard refuses a string constant in place of entropy" "rc=$SG_RC out: $SG_OUT"
  fi
fi

if [ "${SG_STANDALONE:-0}" = 1 ]; then rm -rf "$LAB"; echo "RESULT: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit $?; fi
