#!/usr/bin/env bash
# shellcheck shell=bash
# Standalone hygiene: the scratch-heavy tests build their lab under $LAB, and an
# early exit used to orphan it under TMPDIR. Two representatives are exercised
# here; the acceptance loop covers all nine. Sourced by scripts/validate.sh
# (one line); also runnable alone with `bash tests/test_testfix.sh`.
TF_STANDALONE=0
if ! declare -F ok >/dev/null 2>&1; then
  TF_STANDALONE=1
  set -uo pipefail
  export PYTHONUTF8=1
  if ! declare -F shell_path >/dev/null 2>&1; then
    native_path() {
      if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
    }
    shell_path() {
      if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi
    }
  fi
  SKILL="$(native_path "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)")"
  LAB="$(native_path "$(mktemp -d "${TMPDIR:-/tmp}/muse-testfix.XXXXXX")")"
  if [ -z "${LAB:-}" ] || [ ! -d "$LAB" ]; then echo "no scratch dir" >&2; exit 1; fi
  # Standalone only: an early exit must not leave the lab behind under TMPDIR.
  trap 'rm -rf "$LAB"' EXIT
  PASS=0; FAIL=0; SKIP=0
  ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
  bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && echo "        $2"; }
  skip() { local n="$1"; shift; SKIP=$((SKIP+n)); printf '  SKIP  %s\n' "$*"; }
fi

if [ -z "${LAB:-}" ] || [ ! -d "${LAB:-}" ]; then
  echo "testfix: refusing to run without a scratch dir" >&2
  if [ "$TF_STANDALONE" = 1 ]; then exit 1; else return 1; fi
fi

# Run one test standalone in a fresh TMPDIR: it must exit 0, prove it did its
# work with a PASS line, and leave the fresh dir empty.
tf_standalone_clean() {
  TF_T="$1"
  TF_FRESH="$(mktemp -d "$LAB/tmpdir.XXXXXX")"
  TF_OUT="$(env -u MUSE_FLEET_LAB TMPDIR="$(shell_path "$TF_FRESH")" bash "$SKILL/tests/test_$TF_T.sh" 2>&1)"
  TF_RC=$?
  TF_LEFT="$(ls -A "$TF_FRESH")"
  if [ "$TF_RC" -eq 0 ] && printf '%s\n' "$TF_OUT" | grep -q 'PASS' \
    && [ -z "$TF_LEFT" ]; then
    ok "testfix: tests/test_$TF_T.sh run standalone leaves nothing under TMPDIR"
  else
    bad "testfix: tests/test_$TF_T.sh run standalone leaves nothing under TMPDIR" \
      "rc=$TF_RC left=[$TF_LEFT] tail=[$(printf '%s\n' "$TF_OUT" | tail -3 | tr '\n' ';')]"
  fi
}
tf_standalone_clean collision
tf_standalone_clean roundtrip
unset -f tf_standalone_clean 2>/dev/null || true

if [ "$TF_STANDALONE" = 1 ]; then
  printf 'testfix: %d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]; exit $?
fi
