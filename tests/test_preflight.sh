# shellcheck shell=bash
# Exercises hooks/preflight.sh through the real script, never its source text.
# Check 2 (authenticated + matching + catalog = silent) and check 3 (absent auth
# warns) both fail when line 25 is inverted to `-s`, which is mutant M09.
PF_STANDALONE=0
if ! declare -F ok >/dev/null 2>&1; then
  PF_STANDALONE=1
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

PF_BASE="$LAB/v_preflight"
PF_CFG="$PF_BASE/cfg"
PF_DATA="$PF_BASE/data"
PF_BIN="$PF_BASE/bin"
PF_BIN_BAD="$PF_BASE/bin-bad"
# The version the plugin was run against; the matching stub reports exactly this.
PF_TESTED="$(sed -n 's/^MUSE_TESTED_VERSION = "\(.*\)"/\1/p' "$SKILL/scripts/muse_core.py")"
PF_reset() {
  rm -rf "$PF_CFG" "$PF_DATA" "$PF_BIN" "$PF_BIN_BAD"
  mkdir -p "$PF_CFG" "$PF_DATA/model-catalog" "$PF_BIN" "$PF_BIN_BAD"
  printf '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "muse %s"; else echo "muse %s"; fi\nexit 0\n' "$PF_TESTED" "$PF_TESTED" > "$PF_BIN/muse"
  chmod +x "$PF_BIN/muse"
  printf '#!/bin/sh\necho "muse 99.0.0"\nexit 0\n' > "$PF_BIN_BAD/muse"
  chmod +x "$PF_BIN_BAD/muse"
  printf '{"k":"v"}' > "$PF_CFG/auth.json"
  printf '[{"model_id":"x-contributor"}]' > "$PF_DATA/model-catalog/c.json"
}
PF_run() {  # PF_run <bindir-or-empty> -> sets PF_OUT, PF_RC; stdout only, it reaches Claude
  PF_BINDIR="$1"
  if [ -n "$PF_BINDIR" ]; then
    PF_PATH="$(shell_path "$PF_BINDIR"):/usr/bin:/bin"
  else
    PF_PATH="/usr/bin:/bin"
  fi
  PF_OUT="$(PATH="$PF_PATH" MUSE_CONFIG_DIR="$PF_CFG" MUSE_DATA_DIR="$PF_DATA" CLAUDE_PLUGIN_ROOT="$SKILL" bash "$SKILL/hooks/preflight.sh" 2>/dev/null)"
  PF_RC=$?
}

if bash -n "$SKILL/hooks/preflight.sh"; then
  ok "preflight: hooks/preflight.sh parses"
else
  bad "preflight: hooks/preflight.sh parses"
fi

PF_reset
PF_run "$PF_BIN"
if [ "$PF_RC" -eq 0 ] && [ -z "$PF_OUT" ]; then
  ok "preflight: authenticated with matching version and catalog is silent"
else
  bad "preflight: authenticated with matching version and catalog is silent" "rc=$PF_RC out='$PF_OUT'"
fi

PF_reset
rm -f "$PF_CFG/auth.json"
PF_run "$PF_BIN"
if [ "$PF_RC" -eq 0 ] && printf '%s\n' "$PF_OUT" | grep -q 'no stored credentials' && printf '%s\n' "$PF_OUT" | grep -q 'auth.json'; then
  ok "preflight: missing credentials are reported"
else
  bad "preflight: missing credentials are reported" "rc=$PF_RC out='$PF_OUT'"
fi

PF_reset
: > "$PF_CFG/auth.json"
PF_run "$PF_BIN"
if [ "$PF_RC" -eq 0 ] && printf '%s\n' "$PF_OUT" | grep -q 'no stored credentials'; then
  ok "preflight: an empty auth.json counts as missing credentials"
else
  bad "preflight: an empty auth.json counts as missing credentials" "rc=$PF_RC out='$PF_OUT'"
fi

PF_reset
rm -f "$PF_CFG/auth.json"
PF_HOST_MUSE="$(PATH=/usr/bin:/bin bash -c 'command -v muse' 2>/dev/null)"
if [ -n "$PF_HOST_MUSE" ]; then
  bad "preflight: muse absent from PATH" "host provides muse at $PF_HOST_MUSE, so the absent-binary case cannot be simulated"
else
  PF_run ""
  if [ "$PF_RC" -eq 0 ] && [ -n "$PF_OUT" ] && printf '%s\n' "$PF_OUT" | grep -q 'not on PATH' && ! printf '%s\n' "$PF_OUT" | grep -q 'no stored credentials'; then
    ok "preflight: a missing binary is reported without checking auth"
  else
    bad "preflight: a missing binary is reported without checking auth" "rc=$PF_RC out='$PF_OUT'"
  fi
fi

PF_reset
PF_run "$PF_BIN_BAD"
if [ "$PF_RC" -eq 0 ] && printf '%s\n' "$PF_OUT" | grep -q 'verified against Muse Code'; then
  ok "preflight: a version mismatch names the tested version"
else
  bad "preflight: a version mismatch names the tested version" "rc=$PF_RC out='$PF_OUT'"
fi

PF_reset
rm -f "$PF_DATA/model-catalog/c.json"
PF_run "$PF_BIN"
if [ "$PF_RC" -eq 0 ] && printf '%s\n' "$PF_OUT" | grep -q 'model catalog'; then
  ok "preflight: a missing model catalog is reported"
else
  bad "preflight: a missing model catalog is reported" "rc=$PF_RC out='$PF_OUT'"
fi

if [ "$PF_STANDALONE" -eq 1 ]; then
  rm -rf "$LAB"
  exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
fi
