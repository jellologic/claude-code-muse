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

# 1. The static check passes on a clean tree.
OUT="$(bash "$ROOT/scripts/mutate.sh" --check 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "18"; then
  ok "--check passes and reports all 18 mutants"
else
  bad "--check should exit 0 and mention 18" "rc=$RC out=$OUT"
fi

# 2. A mutant whose snippet drifted is stale, and the run stops before validate.
S="$T/stale"; fresh_repo "$S"
if grep -Fq 'key.upper()' "$S/scripts/muse_core.py"; then
  ok "stale-test precondition: M17 snippet present"
else
  bad "stale-test precondition: M17 snippet present" "harness would report stale on an empty input"
fi
python3 - "$S/scripts/muse_core.py" <<'PY'
import sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
assert t.count("key.upper()") == 1
open(p, "w", encoding="utf-8").write(t.replace("key.upper()", "key.casefold()", 1))
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

# 3. A MUST_KILL survivor fails the run (M02 survives today; pick a still-surviving
# id if a later PR kills it).
S2="$T/mustkill"; fresh_repo "$S2"
OUT="$(MUTATE_ONLY=M02 MUTATE_MUST_KILL="M02" bash "$S2/scripts/mutate.sh" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "MUST_KILL M02"; then
  ok "a MUST_KILL survivor fails the run"
else
  bad "a MUST_KILL survivor should fail naming M02" "rc=$RC out=$(printf '%s' "$OUT" | tail -5)"
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

printf '\nRESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
