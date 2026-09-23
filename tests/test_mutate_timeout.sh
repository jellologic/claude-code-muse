#!/usr/bin/env bash
# Standalone self-test for scripts/mutate.sh timeout derivation (issue #56 slice).
# It is NOT wired into validate.sh, because validate would then call mutate,
# which calls validate.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ -n "${2:-}" ] && echo "        $2"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/mutatetimeout.XXXXXX")"
# Every scratch repo below is built under T, so a failed mktemp must stop here.
if [ -z "$T" ] || [ ! -d "$T" ]; then
  echo "mutatetimeout: cannot create scratch dir" >&2
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
if grep -q 'mutate.sh control: comment only' "$here/muse_task.py"; then
  sleep "${STUB_CONTROL_SLEEP:-0}"
  printf '\nRESULT: 1 passed, 0 failed\n'; exit 0
fi
if grep -q '^    verified = passed$' "$here/muse_task.py"; then   # only the M03 mutant tree
  sleep "${STUB_MUTANT_SLEEP:-0}"
  printf '  \033[31mFAIL\033[0m  planted\n\nRESULT: 0 passed, 1 failed\n'; exit 1
fi
printf '\nRESULT: 1 passed, 0 failed\n'; exit 0
STUB
  git -C "$1" -c user.email=t@l -c user.name=t commit -qam stub
}

# a. Derived timeout is at least 4x the control time.
S="$T/a"; stub_repo "$S"
OUT="$(STUB_CONTROL_SLEEP=3 MUTATE_TIMEOUT_FLOOR=1 MUTATE_JOBS=2 MUTATE_ONLY=M03 bash "$S/scripts/mutate.sh" 2>&1)"; RC=$?
P_T="$(printf '%s' "$OUT" | sed -n 's/^mutate: timeout \([0-9][0-9]*\)s.*/\1/p')"
if [ -z "$P_T" ]; then
  bad "mutate: derived timeout is at least 4x the control time" "no header timeout parsed: rc=$RC out=$(printf '%s' "$OUT" | tail -5)"
elif [ "$P_T" -ge 12 ] 2>/dev/null && [ "$RC" -eq 0 ] \
    && printf '%s' "$OUT" | grep -q "derived" \
    && printf '%s' "$OUT" | grep -q "^M03  killed"; then
  ok "mutate: derived timeout is at least 4x the control time (T=${P_T}s)"
else
  bad "mutate: derived timeout is at least 4x the control time" "rc=$RC T=$P_T out=$(printf '%s' "$OUT" | tail -8)"
fi

# b. A mutant slower than the floor but inside the derived timeout is not a timeout.
S="$T/b"; stub_repo "$S"
OUT="$(STUB_CONTROL_SLEEP=2 STUB_MUTANT_SLEEP=4 MUTATE_TIMEOUT_FLOOR=1 MUTATE_JOBS=2 MUTATE_ONLY=M03 bash "$S/scripts/mutate.sh" 2>&1)"; RC=$?
if [ -z "$OUT" ]; then
  bad "mutate: a mutant slower than the floor but inside the derived timeout is not a timeout" "empty output, nothing was measured"
elif [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "^M03  killed"; then
  ok "mutate: a mutant slower than the floor but inside the derived timeout is not a timeout"
else
  bad "mutate: a mutant slower than the floor but inside the derived timeout is not a timeout" "rc=$RC out=$(printf '%s' "$OUT" | tail -8)"
fi

# c. MUTATE_TIMEOUT overrides the derived timeout.
S="$T/c"; stub_repo "$S"
OUT="$(STUB_CONTROL_SLEEP=3 MUTATE_TIMEOUT_FLOOR=1 MUTATE_TIMEOUT=100 MUTATE_JOBS=2 MUTATE_ONLY=M03 bash "$S/scripts/mutate.sh" 2>&1)"; RC=$?
if [ -z "$OUT" ]; then
  bad "mutate: MUTATE_TIMEOUT overrides the derived timeout" "empty output, nothing was measured"
elif printf '%s' "$OUT" | grep -q "timeout 100s (MUTATE_TIMEOUT)"; then
  ok "mutate: MUTATE_TIMEOUT overrides the derived timeout"
else
  bad "mutate: MUTATE_TIMEOUT overrides the derived timeout" "rc=$RC out=$(printf '%s' "$OUT" | tail -8)"
fi

# d. A mutant past the derived timeout is reported timeout and fails the run.
S="$T/d"; stub_repo "$S"
SECONDS=0
OUT="$(STUB_CONTROL_SLEEP=1 STUB_MUTANT_SLEEP=60 MUTATE_TIMEOUT_FLOOR=1 MUTATE_JOBS=2 MUTATE_ONLY=M03 bash "$S/scripts/mutate.sh" 2>&1)"; RC=$?
ELAPSED=$SECONDS
if [ -z "$OUT" ]; then
  bad "mutate: a mutant past the derived timeout is reported timeout and fails the run" "empty output, nothing was measured"
elif [ "$RC" -ne 0 ] \
    && printf '%s' "$OUT" | grep -q "^M03  timeout" \
    && printf '%s' "$OUT" | grep -q "derived" \
    && printf '%s' "$OUT" | grep -q "MUTATE_TIMEOUT=" \
    && [ "$ELAPSED" -lt 40 ]; then
  ok "mutate: a mutant past the derived timeout is reported timeout and fails the run (${ELAPSED}s)"
else
  bad "mutate: a mutant past the derived timeout is reported timeout and fails the run" "rc=$RC elapsed=${ELAPSED}s out=$(printf '%s' "$OUT" | tail -8)"
fi

# e. High load lowers jobs; MUTATE_JOBS still overrides.
S="$T/e"; stub_repo "$S"
OUT="$(MUTATE_LOAD=999 MUTATE_TIMEOUT=30 MUTATE_ONLY=M03 bash "$S/scripts/mutate.sh" 2>&1)"; RC=$?
if [ -z "$OUT" ]; then
  bad "mutate: high load lowers jobs; MUTATE_JOBS still overrides" "empty output, nothing was measured"
elif printf '%s' "$OUT" | grep -q "jobs 1 (load"; then
  ok "mutate: high load lowers jobs"
else
  bad "mutate: high load lowers jobs" "rc=$RC out=$(printf '%s' "$OUT" | tail -8)"
fi
OUT2="$(MUTATE_LOAD=999 MUTATE_JOBS=3 MUTATE_TIMEOUT=30 MUTATE_ONLY=M03 bash "$S/scripts/mutate.sh" 2>&1)"; RC2=$?
if [ -z "$OUT2" ]; then
  bad "mutate: high load lowers jobs; MUTATE_JOBS still overrides" "empty override output, nothing was measured"
elif printf '%s' "$OUT2" | grep -q "jobs 3 (MUTATE_JOBS)"; then
  ok "mutate: MUTATE_JOBS still overrides"
else
  bad "mutate: MUTATE_JOBS still overrides" "rc=$RC2 out=$(printf '%s' "$OUT2" | tail -8)"
fi

# f. Bad MUTATE_TIMEOUT_FLOOR fails fast.
S="$T/f"; stub_repo "$S"
SECONDS=0
OUT="$(MUTATE_TIMEOUT_FLOOR=abc MUTATE_JOBS=2 MUTATE_ONLY=M03 bash "$S/scripts/mutate.sh" 2>&1)"; RC=$?
ELAPSED=$SECONDS
if [ -z "$OUT" ]; then
  bad "mutate: bad MUTATE_TIMEOUT_FLOOR fails fast" "empty output, nothing was measured"
elif [ "$RC" -ne 0 ] && [ "$ELAPSED" -lt 10 ] && printf '%s' "$OUT" | grep -q "MUTATE_TIMEOUT_FLOOR"; then
  ok "mutate: bad MUTATE_TIMEOUT_FLOOR fails fast (${ELAPSED}s)"
else
  bad "mutate: bad MUTATE_TIMEOUT_FLOOR fails fast" "rc=$RC elapsed=${ELAPSED}s out=$(printf '%s' "$OUT" | tail -5)"
fi

printf '\nRESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
