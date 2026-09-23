#!/usr/bin/env bash
# shellcheck shell=bash
# Issue #46: the fleet had no branch-collision guard, so re-using an --out after its
# worktree directory vanished reset a committed branch to base and overwrote patch.diff.
# Sourced by scripts/validate.sh (one line); also runnable alone. Every variable is
# CO_-prefixed because validate.sh sources this into its own global namespace.
CO_STANDALONE=0
if ! declare -F ok >/dev/null 2>&1; then
  CO_STANDALONE=1
  set -uo pipefail
  export PYTHONUTF8=1
  PASS=0; FAIL=0
  ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
  bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && echo "        $2"; }
fi
if ! declare -F shell_path >/dev/null 2>&1; then
  native_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
  shell_path()  { if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi; }
fi
if [ "$CO_STANDALONE" = 1 ]; then
  SKILL="$(native_path "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)")"
  LAB="$(mktemp -d "${TMPDIR:-/tmp}/muse-co.XXXXXX")"
  # Every path below is built from LAB and the next lines rm -rf under it.
  if [ -z "$LAB" ] || [ ! -d "$LAB" ]; then echo "no scratch dir" >&2; exit 1; fi
  LAB="$(native_path "$LAB")"
fi
CO_FLEET="$SKILL/scripts/muse_fleet.py"
CO_TASK="$SKILL/scripts/muse_task.py"

CO="$LAB/v_collision"
rm -rf "$CO"; mkdir -p "$CO/bin" "$CO/data" "$CO/wt" "$CO/out"
# A muse that writes DIFFERENT content on every call. With identical content a re-run
# that regenerated patch.diff would leave it byte-identical and the patch assertion
# below could not tell an overwrite from a refusal.
cat > "$CO/bin/muse" <<'STUB'
#!/usr/bin/env bash
wt=""; prev=""
for a in "$@"; do [ "$prev" = "--worktree-existing" ] && wt="$a"; prev="$a"; done
[ -n "$wt" ] && [ -d "$wt" ] || { echo "stub: no --worktree-existing" >&2; exit 2; }
echo call >> "$CO_STUB_LOG"
echo "call-$(wc -l < "$CO_STUB_LOG" | tr -d ' ')" > "$wt/feature.txt"
printf '{"payload":{"kind":"run_terminal","terminal":"completed","text":"ok"}}\n'
STUB
chmod +x "$CO/bin/muse"
# Native Windows python finds only PATHEXT files and CreateProcess cannot run a bash
# script, so the stub needs a .cmd that hands it to bash (same shape as test_roundtrip).
if command -v cygpath >/dev/null 2>&1; then
  printf '@echo off\r\n"%s" "%s" %%*\r\nexit /b %%ERRORLEVEL%%\r\n' \
    "$(native_path "$(command -v bash)")" "$(native_path "$CO/bin/muse")" > "$CO/bin/muse.cmd"
fi
co_py() { env PATH="$(shell_path "$CO/bin"):$PATH" MUSE_DATA_DIR="$CO/data" \
  MUSE_CATALOG_GLOB="$CO/nocat/*.json" CO_STUB_LOG="$CO/stub.log" python3 "$@"; }
co_fleet() {  # co_fleet <out name> [extra args]
  local o="$1"; shift
  co_py "$CO_FLEET" --tasks "$CO/tasks.json" --repo "$CO/repo" --model co-model \
    --out "$CO/out/$o" --worktree-root "$CO/wt" "$@" >"$CO/$o.log" 2>&1
}
co_task_field() {  # co_task_field <report.json> <key>
  python3 -c 'import json,sys
try: t=json.load(open(sys.argv[1]))["tasks"][0]
except Exception: sys.exit(1)
print(t.get(sys.argv[2]) or "")' "$1" "$2"
}
co_rev() { git -C "$CO/repo" rev-parse --verify --quiet "$1" 2>/dev/null | tr -d '\r'; }

rm -rf "$CO/repo"; mkdir -p "$CO/repo"; git init -q -b main "$CO/repo"
printf 'x\n' > "$CO/repo/a.txt"; git -C "$CO/repo" add -A
git -C "$CO/repo" -c user.email=t@l -c user.name=t commit -qm init
CO_INIT=$(co_rev HEAD)
printf '[{"id":"a","prompt":"noop"}]\n' > "$CO/tasks.json"

# 1. The reproduction from the issue: --commit, lose the worktree dir, re-run the --out.
co_fleet RUNX --commit
CO_SHA1=$(co_rev fleet/RUNX/a)
CO_PATCH="$CO/out/RUNX/a/patch.diff"
if [ -s "$CO_PATCH" ] && [ -n "$CO_SHA1" ] && [ "$CO_SHA1" != "$CO_INIT" ]; then
  ok "collision: first --commit run leaves a committed branch and a non-empty patch"
else
  bad "collision: first --commit run leaves a committed branch and a non-empty patch" \
    "sha=$CO_SHA1 init=$CO_INIT patch=$(wc -c < "$CO_PATCH" 2>/dev/null) $(tail -5 "$CO/RUNX.log")"
fi
cp "$CO_PATCH" "$CO/patch.saved" 2>/dev/null
rm -rf "$CO/wt/RUNX-a"
co_fleet RUNX; CO_RC=$?
[ "$(co_rev fleet/RUNX/a)" = "$CO_SHA1" ] && [ -n "$CO_SHA1" ] \
  && ok "collision: a re-run of the same --out leaves the committed branch where it was" \
  || bad "collision: a re-run of the same --out leaves the committed branch where it was" "was $CO_SHA1, now $(co_rev fleet/RUNX/a)"
[ -s "$CO/patch.saved" ] && cmp -s "$CO/patch.saved" "$CO_PATCH" \
  && ok "collision: a re-run of the same --out leaves patch.diff intact" \
  || bad "collision: a re-run of the same --out leaves patch.diff intact" "$(head -8 "$CO_PATCH" 2>/dev/null)"
CO_ST=$(co_task_field "$CO/out/RUNX/report.json" status)
CO_RS=$(co_task_field "$CO/out/RUNX/report.json" reason)
[ "$CO_RC" -ne 0 ] && [ "$CO_ST" = setup_failed ] && printf '%s' "$CO_RS" | grep -q "fleet/RUNX/a" \
  && ok "collision: the refusal is setup_failed, exits non-zero and names the branch" \
  || bad "collision: the refusal is setup_failed, exits non-zero and names the branch" "rc=$CO_RC status=$CO_ST reason=$CO_RS"

# 2. The patch guard on its own: --cleanup removed branch and worktree, so only the
# non-empty patch.diff stands between a re-run and the lost work.
co_fleet RUNY --cleanup
CO_PY="$CO/out/RUNY/a/patch.diff"; cp "$CO_PY" "$CO/patchy.saved" 2>/dev/null
if [ -s "$CO_PY" ] && [ -z "$(co_rev fleet/RUNY/a)" ]; then
  ok "collision: a --cleanup run leaves a non-empty patch and no branch"
else
  bad "collision: a --cleanup run leaves a non-empty patch and no branch" "branch=$(co_rev fleet/RUNY/a) $(tail -5 "$CO/RUNY.log")"
fi
co_fleet RUNY; CO_RC=$?
CO_RS=$(co_task_field "$CO/out/RUNY/report.json" reason)
[ -s "$CO/patchy.saved" ] && cmp -s "$CO/patchy.saved" "$CO_PY" && [ "$CO_RC" -ne 0 ] \
  && printf '%s' "$CO_RS" | grep -q "patch.diff" \
  && ok "collision: a non-empty patch.diff is refused, not overwritten, even with no branch" \
  || bad "collision: a non-empty patch.diff is refused, not overwritten, even with no branch" "rc=$CO_RC reason=$CO_RS"

# 3. Control: an EMPTY patch.diff is not work, so it must not block a run.
mkdir -p "$CO/out/RUNZ/a"; : > "$CO/out/RUNZ/a/patch.diff"
co_fleet RUNZ; CO_RC=$?
[ "$CO_RC" -eq 0 ] && [ "$(co_task_field "$CO/out/RUNZ/report.json" status)" = completed ] \
  && [ -s "$CO/out/RUNZ/a/patch.diff" ] \
  && ok "collision: an empty patch.diff does not block a run" \
  || bad "collision: an empty patch.diff does not block a run" "rc=$CO_RC $(tail -5 "$CO/RUNZ.log")"

# 4. muse_task still refuses a branch it did not create, through the shared check.
git -C "$CO/repo" branch muse/FIXED/t1 "$CO_SHA1"
CO_TO=$(cd "$CO/repo" && co_py "$CO_TASK" run --id t1 --repo . --stamp FIXED \
  --out "$CO/tout" --worktree-root "$CO/twt" --model co-model --prompt noop 2>/dev/null)
CO_TS=$(printf '%s' "$CO_TO" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
print(d.get("status") or "", d.get("branch") or "")' 2>/dev/null)
[ "$CO_TS" = "refused muse/FIXED/t1" ] && [ "$(co_rev muse/FIXED/t1)" = "$CO_SHA1" ] \
  && ok "collision: muse_task refuses a foreign branch and leaves it at its commit" \
  || bad "collision: muse_task refuses a foreign branch and leaves it at its commit" "out=$CO_TO"

if [ "$CO_STANDALONE" = 1 ]; then
  printf 'collision: %d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
fi
