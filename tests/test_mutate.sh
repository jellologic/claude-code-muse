#!/usr/bin/env bash
# Standalone self-test for scripts/mutate.sh. It is NOT wired into validate.sh,
# because validate would then call mutate, which calls validate.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ -n "${2:-}" ] && echo "        $2"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/mutatetest.XXXXXX")"
# Every scratch repo below is built under T, so a failed mktemp must stop here.
if [ -z "$T" ] || [ ! -d "$T" ]; then
  echo "mutatetest: cannot create scratch dir" >&2
  exit 2
fi
trap 'rm -rf "$T"' EXIT

fresh_repo() {  # fresh_repo <dir>: scratch git repo at HEAD plus the working harness
  mkdir -p "$1"
  git -C "$ROOT" archive HEAD | tar -x -C "$1"
  # The harness itself may be uncommitted, so the archive cannot supply it.
  cp "$ROOT/scripts/mutate.sh" "$1/scripts/"
  git -C "$1" init -q
  git -C "$1" add -A
  git -C "$1" -c user.email=t@l -c user.name=t commit -qm base
}

stub_repo() {  # stub_repo <dir>: fresh_repo with validate.sh replaced by a stub
  fresh_repo "$1"
  cat > "$1/scripts/validate.sh" <<'STUB'
#!/usr/bin/env bash
here="$(cd "$(dirname "$0")" && pwd)"
if grep -q '^    verified = passed$' "$here/muse_task.py"; then   # only the M03 mutant tree
  case "${STUB_MODE:-}" in
    kill)  printf '  \033[31mFAIL\033[0m  planted\n\nRESULT: 0 passed, 1 failed\n'; exit 1 ;;
    crash) echo 'Traceback (most recent call last):'; exit 1 ;;
    hang)  sleep 120; exit 0 ;;
  esac
fi
printf '\nRESULT: 1 passed, 0 failed\n'; exit 0
STUB
  git -C "$1" -c user.email=t@l -c user.name=t commit -qam stub
}

# 1. The static check passes on a clean tree, with a derived total.
OUT="$(bash "$ROOT/scripts/mutate.sh" --check 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -Eq "all [0-9][0-9]* mutants apply cleanly"; then
  ok "--check passes and reports a derived mutant total"
else
  bad "--check should exit 0 and report all N mutants" "rc=$RC out=$OUT"
fi

# 1b. The total is derived from the table, not typed: one more row moves it by one.
S="$T/derived"; fresh_repo "$S"
OUT="$(bash "$S/scripts/mutate.sh" --check 2>&1)"; RC=$?
N="$(printf '%s' "$OUT" | sed -n 's/^mutate: all \([0-9][0-9]*\) mutants apply cleanly$/\1/p')"
if [ "$RC" -ne 0 ] || [ -z "$N" ]; then
  bad "derived total follows the table" "no baseline total to derive from: rc=$RC out=$OUT"
else
cp "$S/scripts/mutate.sh" "$T/derived.orig"
python3 - "$S/scripts/mutate.sh" "$S/scripts/muse_status.py" <<'PY'
import sys
mp, sp = sys.argv[1], sys.argv[2]
old = '        out.append("empty patch")'
assert open(sp, encoding="utf-8").read().count(old) == 1, "probe snippet not found exactly once"
row = (' ("M19", "scripts/muse_status.py", %r, %r, "probe row"),\n'
       % (old, old + "  # probe"))
text = open(mp, encoding="utf-8").read()
anchor = ' ("M17",'
assert text.count(anchor) == 1, "M17 row not found exactly once"
line_start = text.index(anchor)
line_end = text.index("\n", line_start) + 1
open(mp, "w", encoding="utf-8").write(text[:line_end] + row + text[line_end:])
PY
if cmp -s "$T/derived.orig" "$S/scripts/mutate.sh"; then
  bad "derived total follows the table" "insertion left mutate.sh byte-identical -- the test measured nothing"
else
  git -C "$S" -c user.email=t@l -c user.name=t commit -qam row20
  OUT="$(bash "$S/scripts/mutate.sh" --check 2>&1)"; RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "all $((N+1)) mutants"; then
    ok "derived total follows the table"
  else
    bad "derived total should say all $((N+1)) mutants" "rc=$RC out=$OUT"
  fi
fi
fi

# 1c. An unknown MUTATE_ONLY id fails fast, before any validate runs.
SECONDS=0
OUT="$(MUTATE_ONLY=M99 bash "$ROOT/scripts/mutate.sh" 2>&1)"; RC=$?
ELAPSED=$SECONDS
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "M99" && [ "$ELAPSED" -lt 10 ]; then
  ok "unknown MUTATE_ONLY id fails fast without running validate (${ELAPSED}s)"
else
  bad "unknown MUTATE_ONLY id should fail fast naming M99" "rc=$RC elapsed=${ELAPSED}s out=$OUT"
fi
OUT="$(MUTATE_ONLY=M03,M3 bash "$ROOT/scripts/mutate.sh" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "M3"; then
  ok "unknown id inside a MUTATE_ONLY list fails naming it"
else
  bad "MUTATE_ONLY=M03,M3 should fail naming M3" "rc=$RC out=$OUT"
fi

# 2. A mutant whose snippet drifted is stale, and the run stops before validate.
S="$T/stale"; fresh_repo "$S"
if grep -Fq '    raw = os.environ.get("CLAUDE_PLUGIN_OPTION_" + key.upper())' "$S/scripts/muse_core.py"; then
  ok "stale-test precondition: M17 snippet present"
else
  bad "stale-test precondition: M17 snippet present" "harness would report stale on an empty input"
fi
python3 - "$S/scripts/muse_core.py" <<'PY'
import sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
assert t.count('    raw = os.environ.get("CLAUDE_PLUGIN_OPTION_" + key.upper())') == 1
open(p, "w", encoding="utf-8").write(t.replace('    raw = os.environ.get("CLAUDE_PLUGIN_OPTION_" + key.upper())', '    raw = os.environ.get("CLAUDE_PLUGIN_OPTION_" + key.casefold())', 1))
PY
git -C "$S" -c user.email=t@l -c user.name=t commit -qam drift
OUT="$(bash "$S/scripts/mutate.sh" --check 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "M17"; then
  ok "--check names the drifted M17 mutant"
else
  bad "--check should fail naming M17" "rc=$RC out=$OUT"
fi
SECONDS=0
OUT="$(MUTATE_ONLY=M17 bash "$S/scripts/mutate.sh" 2>&1)"; RC=$?
ELAPSED=$SECONDS
# A stale mutant must fail without running validate: either it finishes well under
# a validate run, or its output says STALE outright.
if [ "$RC" -ne 0 ] && { [ "$ELAPSED" -lt 10 ] || printf '%s' "$OUT" | grep -q "STALE"; }; then
  ok "stale mutant fails fast without running validate (${ELAPSED}s)"
else
  bad "stale mutant should fail without running validate" "rc=$RC elapsed=${ELAPSED}s out=$OUT"
fi

# 3. A MUST_KILL survivor fails the run. The real suite now kills all 18, so
# only a stub -- green for every tree -- can stage a survivor.
S2="$T/mustkill"; stub_repo "$S2"
OUT="$(MUTATE_JOBS=2 MUTATE_ONLY=M03 MUTATE_MUST_KILL="M03" bash "$S2/scripts/mutate.sh" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "MUST_KILL M03"; then
  ok "a MUST_KILL survivor (M03) fails the run"
else
  bad "a MUST_KILL survivor should fail naming M03" "rc=$RC out=$(printf '%s' "$OUT" | tail -5)"
fi

# 4. A red control fails the run even for a mutant the suite would kill.
S3="$T/redcontrol"; fresh_repo "$S3"
python3 - "$S3/scripts/validate.sh" <<'PY'
import sys
p = sys.argv[1]
lines = open(p, encoding="utf-8").read().split("\n")
lines.insert(1, "exit 1")
open(p, "w", encoding="utf-8").write("\n".join(lines))
PY
git -C "$S3" -c user.email=t@l -c user.name=t commit -qam red
OUT="$(MUTATE_ONLY=M03 bash "$S3/scripts/mutate.sh" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "RED"; then
  ok "a red control fails the run"
else
  bad "a red control should fail the run" "rc=$RC out=$(printf '%s' "$OUT" | tail -5)"
fi

# 5. Positive path on the real tree: M03 is killed, the control stays green.
OUT="$(MUTATE_ONLY=M03 bash "$ROOT/scripts/mutate.sh" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] \
    && printf '%s' "$OUT" | grep -q "^M03  killed" \
    && printf '%s' "$OUT" | grep -q "control: green"; then
  ok "positive path: M03 killed, control green"
else
  bad "positive path should exit 0 with M03 killed" "rc=$RC out=$(printf '%s' "$OUT" | tail -5)"
fi

# 6. Stub-validate verdicts, in seconds: kill / crash / timeout classification.
S4="$T/stubkill"; stub_repo "$S4"
OUT="$(STUB_MODE=kill MUTATE_JOBS=2 MUTATE_ONLY=M03 bash "$S4/scripts/mutate.sh" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] \
    && printf '%s' "$OUT" | grep -q "^M03  killed" \
    && printf '%s' "$OUT" | grep -q "killed 1 of 1" \
    && printf '%s' "$OUT" | grep -q "control: green"; then
  ok "stub kill: M03 killed, control green"
else
  bad "stub kill should exit 0 with M03 killed" "rc=$RC out=$(printf '%s' "$OUT" | tail -5)"
fi

S5="$T/stubcrash"; stub_repo "$S5"
OUT="$(STUB_MODE=crash MUTATE_JOBS=2 MUTATE_ONLY=M03 bash "$S5/scripts/mutate.sh" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] \
    && printf '%s' "$OUT" | grep -q "^M03  crashed" \
    && printf '%s' "$OUT" | grep -q "killed 0 of 1"; then
  ok "stub crash: M03 crashed, run fails"
else
  bad "stub crash should fail with M03 crashed" "rc=$RC out=$(printf '%s' "$OUT" | tail -5)"
fi

S6="$T/stubhang"; stub_repo "$S6"
SECONDS=0
OUT="$(STUB_MODE=hang MUTATE_JOBS=2 MUTATE_TIMEOUT=3 MUTATE_ONLY=M03 bash "$S6/scripts/mutate.sh" 2>&1)"; RC=$?
ELAPSED=$SECONDS
if [ "$RC" -ne 0 ] \
    && printf '%s' "$OUT" | grep -q "^M03  timeout" \
    && [ "$ELAPSED" -lt 60 ]; then
  ok "stub hang: M03 times out (${ELAPSED}s)"
else
  bad "stub hang should fail with M03 timeout" "rc=$RC elapsed=${ELAPSED}s out=$(printf '%s' "$OUT" | tail -5)"
fi

# 7. M09 and M15 are in the committed MUST_KILL: with no override, two survivors
# from the stub's green tree fail the run naming both.
S7="$T/stubmustkill"; stub_repo "$S7"
OUT="$(MUTATE_JOBS=2 MUTATE_ONLY=M09,M15 bash "$S7/scripts/mutate.sh" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] \
    && printf '%s' "$OUT" | grep -q "MUST_KILL M09" \
    && printf '%s' "$OUT" | grep -q "MUST_KILL M15"; then
  ok "M09 and M15 survivors fail via the committed MUST_KILL"
else
  bad "M09/M15 survivors should fail naming both" "rc=$RC out=$(printf '%s' "$OUT" | tail -5)"
fi

printf '\nRESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
