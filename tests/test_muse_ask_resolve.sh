# shellcheck shell=bash
# muse_ask's default model goes through the resolution at muse_ask.sh:71-86, which
# imports "$SKILL_DIR/scripts/muse_core.py". Loading $CORE directly would pass while
# that path stayed broken (mutant M15), so this runs the real script with no --model.
AR_STANDALONE=0
if ! declare -F ok >/dev/null 2>&1; then
  AR_STANDALONE=1
  PASS=0; FAIL=0
  ok() { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
  bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ -n "${2:-}" ] && echo "        $2"; }
  SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  LAB="$(mktemp -d "${TMPDIR:-/tmp}/musetest.XXXXXX")"
  native_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
  }
  shell_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi
  }
fi

AR_BASE="$LAB/v_askres"
AR_BIN="$AR_BASE/bin"
AR_CAT="$AR_BASE/cat"
AR_REPO="$AR_BASE/repo"
AR_DATA="$AR_BASE/data"
mkdir -p "$AR_BIN" "$AR_CAT" "$AR_REPO" "$AR_DATA"
AR_LOG="$AR_BASE/model.log"
: > "$AR_LOG"
# Same shape as the stub at validate.sh's ask section: record --model, emit terminal.
cat > "$AR_BIN/muse" <<'STUB'
#!/usr/bin/env bash
prev=""
for a in "$@"; do
  if [ "$prev" = "--model" ]; then
    printf '%s\n' "$a" >> "$MUSE_STUB_MODEL_LOG"
  fi
  prev="$a"
done
printf '{"payload":{"kind":"run_terminal","terminal":"completed","text":"ok"}}\n'
STUB
chmod +x "$AR_BIN/muse"
printf '{"rows":[{"model_id":"muse-spark-7.7-contributor","release_date":"2031-01-01","visibility":"visible"}]}' > "$AR_CAT/c.json"
AR_ERR="$AR_BASE/stderr.log"
AR_OUT="$AR_BASE/stdout.log"
( cd "$AR_REPO" && PATH="$(shell_path "$AR_BIN"):$PATH" MUSE_STUB_MODEL_LOG="$(native_path "$AR_LOG")" MUSE_CATALOG_GLOB="$(native_path "$AR_CAT/*.json")" CLAUDE_PLUGIN_DATA="$AR_BASE/data" bash "$SKILL/scripts/muse_ask.sh" "q" >"$AR_OUT" 2>"$AR_ERR" )
AR_RC=$?
AR_GOT="$(cat "$AR_LOG" 2>/dev/null)"
AR_ERRTAIL="$(tail -3 "$AR_ERR" 2>/dev/null)"
if [ "$AR_RC" -eq 0 ] && [ "$AR_GOT" = "muse-spark-7.7-contributor" ]; then
  ok "muse_ask resolves latest-contributor through its own import path"
else
  bad "muse_ask resolve import" "rc=$AR_RC model='$AR_GOT' stderr='$AR_ERRTAIL'"
fi

if [ "$AR_STANDALONE" -eq 1 ]; then
  rm -rf "$LAB"
  exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
fi
