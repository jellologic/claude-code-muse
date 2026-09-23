#!/usr/bin/env bash
# Stub-driven offline round trip: run -> revise xN -> verify -> finish, plus a fleet run,
# against a base branch that MOVES after the task starts. Without a moved base, diffing
# against the ref name and against the pinned sha give identical bytes, so a regression to
# the ref name (#11) would pass every check. Sourced by validate.sh; also runnable alone.
RT_STANDALONE=0
if ! declare -F ok >/dev/null 2>&1; then
  RT_STANDALONE=1
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
  TASK="$SKILL/scripts/muse_task.py"
  FLEET="$SKILL/scripts/muse_fleet.py"
  LAB="$(mktemp -d "${TMPDIR:-/tmp}/muse-rt.XXXXXX")"
  # Every path below is built from LAB and the next lines rm -rf under it.
  if [ -z "$LAB" ] || [ ! -d "$LAB" ]; then echo "no scratch dir" >&2; exit 1; fi
  LAB="$(native_path "$LAB")"
  # Standalone only: an early exit must not leave the lab behind under TMPDIR.
  trap 'rm -rf "$LAB"' EXIT
  PASS=0; FAIL=0
  ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
  bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && echo "        $2"; }
fi

RT_DIR="$LAB/v_roundtrip"
rm -rf "$RT_DIR"; mkdir -p "$RT_DIR/bin" "$RT_DIR/musedata"
# A muse that edits the worktree it is handed (one new line per round, so a later round's
# patch must carry the earlier one), logs each call, and emits the terminal record. With
# RT_MOVE_BASE set it also commits to the source repo named there -- its own cwd is now
# the worktree, so it cannot commit by accident of directory -- which moves the base
# WHILE the worker is running.
cat > "$RT_DIR/bin/muse" <<'STUB'
#!/usr/bin/env bash
wt=""; prev=""
for a in "$@"; do
  [ "$prev" = "--workspace" ] && wt="$a"
  prev="$a"
done
[ -n "$wt" ] && [ -d "$wt" ] || { echo "stub: no --workspace" >&2; exit 2; }
n=1
[ -f "$wt/feature.txt" ] && n=$(( $(wc -l < "$wt/feature.txt") + 1 ))
echo "line-$n" >> "$wt/feature.txt"
echo "$wt" >> "$RT_STUB_LOG"
if [ -n "${RT_MOVE_BASE:-}" ]; then
  echo theirs > "$RT_MOVE_BASE/other.txt"
  git -C "$RT_MOVE_BASE" add other.txt && git -C "$RT_MOVE_BASE" -c user.email=t@l -c user.name=t commit -qm theirs >/dev/null
fi
printf '{"payload":{"kind":"run_terminal","terminal":"completed","text":"ok"}}\n'
STUB
chmod +x "$RT_DIR/bin/muse"
# Native python on Windows cannot execute the extensionless bash stub: shutil.which
# honours PATHEXT (so it needs muse.cmd) and CreateProcess never consults PATHEXT at
# all, so even the .cmd is unreachable under the bare name unless run_muse resolves it
# via which() first. Same shape as validate.sh's make_muse_stub.
if command -v cygpath >/dev/null 2>&1; then
  printf '@echo off\r\n"%s" "%s" %%*\r\nexit /b %%ERRORLEVEL%%\r\n' \
    "$(native_path "$(command -v bash)")" \
    "$(native_path "$RT_DIR/bin/muse")" > "$RT_DIR/bin/muse.cmd"
fi

# The stub goes FIRST on PATH so it beats both a real muse and the section-3 stub. The env
# var is removed because a value inherited from the caller would satisfy the max_rounds
# assertions by accident. shell_path keeps the entry intact on Windows, where a native
# C:/... path would otherwise split on its drive colon.
rt_py() {
  env -u CLAUDE_PLUGIN_OPTION_MAX_ROUNDS PATH="$(shell_path "$RT_DIR/bin"):$PATH" MUSE_DATA_DIR="$RT_DIR/musedata" \
    RT_STUB_LOG="$RT_DIR/stub.log" python3 "$@"
}
rt_jget() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))" "$@"; }

rt_mkrepo() {
  rm -rf "$1"; mkdir -p "$1"; git init -q -b main "$1"
  printf 'def add(a,b):\n    return a+b\n' > "$1/calc.py"
  git -C "$1" add -A; git -C "$1" -c user.email=t@l -c user.name=t commit -qm init
}

# Control: under exactly the rt helper's environment, the bare name must resolve to this
# stub, not to a real muse or the section-3 exit-0 stub earlier on PATH. The "exactly 2
# muse calls" stub.log assertion below is the proof the stub actually ran.
if env -u CLAUDE_PLUGIN_OPTION_MAX_ROUNDS PATH="$(shell_path "$RT_DIR/bin"):$PATH" \
  python3 -c "import shutil,os,sys; w=shutil.which('muse'); sys.exit(0 if w and os.path.samefile(os.path.dirname(w), sys.argv[1]) else 1)" "$RT_DIR/bin"; then
  ok "roundtrip: muse resolves to the round-trip stub, not another muse on PATH"
else
  RT_RESOLVED="$(env -u CLAUDE_PLUGIN_OPTION_MAX_ROUNDS PATH="$(shell_path "$RT_DIR/bin"):$PATH" \
    python3 -c "import shutil; print(shutil.which('muse') or 'none')" 2>/dev/null)"
  bad "roundtrip: muse resolves to the round-trip stub, not another muse on PATH" "$RT_RESOLVED"
fi

# ---- task: run -> base moves -> revise -> revise (exhausted) -> verify -> finish
RT_REPO="$RT_DIR/repo"; rt_mkrepo "$RT_REPO"; RT_OUT="$RT_DIR/out"; : > "$RT_DIR/stub.log"
RT_BASE0=$(git -C "$RT_REPO" rev-parse main)
# 2, not the default 3: a constant stored in place of the flag would still read 3.
(cd "$RT_REPO" && rt_py "$TASK" run --id rt --repo "$RT_REPO" --out "$RT_OUT" --worktree-root "$RT_DIR/wt" \
   --model stub-model --base main --max-rounds 2 --prompt "add feature" >"$RT_DIR/run.json" 2>"$RT_DIR/run.err")
RT_RC=$?
RT_STATE="$RT_OUT/rt/state.json"
[ "$RT_RC" = 0 ] && [ "$(rt_jget "$RT_STATE" 'd["max_rounds"]')" = 2 ] \
  && ok "roundtrip: --max-rounds 2 reaches state.max_rounds" \
  || bad "roundtrip: --max-rounds not stored" "rc=$RT_RC $(cat "$RT_DIR/run.json" "$RT_DIR/run.err" | tail -5)"
[ "$(rt_jget "$RT_STATE" 'd["base_sha"]')" = "$RT_BASE0" ] \
  && ok "roundtrip: base pinned to the sha at start" || bad "roundtrip: base_sha wrong"
RT_WT=$(rt_jget "$RT_STATE" 'd["worktree"]')
printf 'theirs\n' > "$RT_REPO/other.txt"; git -C "$RT_REPO" add other.txt
git -C "$RT_REPO" -c user.email=t@l -c user.name=t commit -qm theirs
# Precondition: without it the "no other.txt" assertions below pass on a base that never moved.
if [ "$(git -C "$RT_REPO" rev-parse main)" != "$RT_BASE0" ] \
   && git -C "$RT_WT" diff main --name-only | grep -q other.txt; then
  ok "roundtrip: base moved, and diffing against the ref name would show it"
else bad "roundtrip: the base did not move, so nothing below can fire"; fi
(cd "$RT_REPO" && rt_py "$TASK" revise --id rt --out "$RT_OUT" --feedback "more" >"$RT_DIR/rev1.json" 2>"$RT_DIR/rev1.err")
RT_RC=$?
RT_PATCH="$RT_OUT/rt/patch.diff"
[ "$RT_RC" = 0 ] && [ -s "$RT_PATCH" ] && grep -q '^+line-1$' "$RT_PATCH" && grep -q '^+line-2$' "$RT_PATCH" \
  && ok "roundtrip: round-2 patch carries both rounds" \
  || bad "roundtrip: round-2 patch wrong" "rc=$RT_RC $(head -20 "$RT_PATCH" 2>/dev/null)"
[ -s "$RT_PATCH" ] && ! grep -q 'other.txt' "$RT_PATCH" \
  && ok "roundtrip: round-2 patch is against base_sha, not the moved ref" \
  || bad "roundtrip: round patch pulled in the moved base" "$(grep -n other "$RT_PATCH")"
(cd "$RT_REPO" && rt_py "$TASK" revise --id rt --out "$RT_OUT" --feedback "again" >"$RT_DIR/rev2.json" 2>"$RT_DIR/rev2.err")
RT_RC=$?
# Exactly 2 muse calls: an off-by-one breaker spends a third round before refusing.
[ "$RT_RC" = 1 ] && [ "$(rt_jget "$RT_DIR/rev2.json" 'd["status"]')" = max_rounds_exhausted ] \
  && [ "$(rt_jget "$RT_DIR/rev2.json" 'd["rounds_used"]')" = 2 ] \
  && [ "$(wc -l < "$RT_DIR/stub.log" | tr -d ' ')" = 2 ] \
  && ok "roundtrip: max_rounds_exhausted at exactly 2, no third muse call" \
  || bad "roundtrip: breaker off" "rc=$RT_RC $(cat "$RT_DIR/rev2.json") calls=$(wc -l < "$RT_DIR/stub.log")"
# Failing control first: without it the passing check below cannot prove it can fail.
(cd "$RT_REPO" && rt_py "$TASK" verify --id rt --out "$RT_OUT" --command "grep -q line-3 feature.txt" \
  >"$RT_DIR/ver-fail.json" 2>"$RT_DIR/ver-fail.err")
RT_RC=$?
[ "$RT_RC" = 1 ] && [ "$(rt_jget "$RT_DIR/ver-fail.json" 'd["passed"]')" = False ] \
  && [ "$(rt_jget "$RT_DIR/ver-fail.json" 'd["exit_code"]')" = 1 ] \
  && ok "roundtrip: verify reports a failing check as passed=false, exit_code=1" \
  || bad "roundtrip: verify failing control wrong" "rc=$RT_RC $(cat "$RT_DIR/ver-fail.json" 2>/dev/null | tail -3)"
(cd "$RT_REPO" && rt_py "$TASK" verify --id rt --out "$RT_OUT" --command "grep -q line-2 feature.txt" \
  >"$RT_DIR/ver.json" 2>"$RT_DIR/ver.err")
RT_RC=$?
[ "$RT_RC" = 0 ] && [ "$(rt_jget "$RT_DIR/ver.json" 'd["status"]')" = verified ] \
  && [ "$(rt_jget "$RT_DIR/ver.json" 'd["passed"]')" = True ] \
  && [ "$(rt_jget "$RT_DIR/ver.json" 'd["exit_code"]')" = 0 ] \
  && ok "roundtrip: verify records the passing check (passed=true, exit_code=0)" \
  || bad "roundtrip: verify passing check wrong" "rc=$RT_RC $(cat "$RT_DIR/ver.json" 2>/dev/null | tail -3)"
# finish reads only the LAST verification, so the failing control above does not taint this.
(cd "$RT_REPO" && rt_py "$TASK" finish --id rt --out "$RT_OUT" --verdict accept --summary s >"$RT_DIR/fin.json" 2>"$RT_DIR/fin.err")
RT_RC=$?
[ "$RT_RC" = 0 ] && [ "$(rt_jget "$RT_DIR/fin.json" 'd["verified_by_supervisor"]')" = True ] \
  && [ -s "$RT_PATCH" ] && grep -q '^+line-2$' "$RT_PATCH" && ! grep -q other.txt "$RT_PATCH" \
  && ok "roundtrip: finish accepts a verified patch against base_sha" \
  || bad "roundtrip: finish wrong" "rc=$RT_RC $(cat "$RT_DIR/fin.json" "$RT_DIR/fin.err" | tail -5)"

# ---- the userConfig env var reaches state.max_rounds (5: neither the default nor the flag above)
# state.json alone cannot prove the run worked: do_round saves state before
# returning, so a raise after the save still leaves max_rounds behind. The run's
# own exit code and stdout status pin that the round actually completed.
RT_REPO2="$RT_DIR/repo2"; rt_mkrepo "$RT_REPO2"
(cd "$RT_REPO2" && env PATH="$(shell_path "$RT_DIR/bin"):$PATH" MUSE_DATA_DIR="$RT_DIR/musedata" RT_STUB_LOG="$RT_DIR/stub2.log" \
   CLAUDE_PLUGIN_OPTION_MAX_ROUNDS=5 python3 "$TASK" run --id rte --repo "$RT_REPO2" --out "$RT_DIR/out2" \
   --worktree-root "$RT_DIR/wt2" --model stub-model --prompt x >"$RT_DIR/rte.json" 2>"$RT_DIR/rte.err")
RT_RTE_RC=$?
RT_RTE_MAX="$(rt_jget "$RT_DIR/out2/rte/state.json" 'd["max_rounds"]' 2>"$RT_DIR/rte-jget.err")"
RT_RTE_JERR="$(cat "$RT_DIR/rte-jget.err")"
RT_RTE_STATUS="$(rt_jget "$RT_DIR/rte.json" 'd["status"]' 2>"$RT_DIR/rte-status.err")"
RT_RTE_SERR="$(cat "$RT_DIR/rte-status.err")"
if [ "$RT_RTE_RC" = 0 ] && [ "$RT_RTE_STATUS" = completed ] && [ "$RT_RTE_MAX" = 5 ]; then
  ok "roundtrip: CLAUDE_PLUGIN_OPTION_MAX_ROUNDS reaches state.max_rounds"
else
  bad "roundtrip: CLAUDE_PLUGIN_OPTION_MAX_ROUNDS reaches state.max_rounds" \
    "rc=$RT_RTE_RC status=$RT_RTE_STATUS max_rounds=$RT_RTE_MAX jget_err=[$RT_RTE_JERR] status_err=[$RT_RTE_SERR] $(tail -3 "$RT_DIR/rte.err" 2>/dev/null)"
fi

# ---- fleet: the base moves while the worker runs
RT_REPO3="$RT_DIR/repo3"; rt_mkrepo "$RT_REPO3"; RT_BASE3=$(git -C "$RT_REPO3" rev-parse main)
echo '[{"id":"f1","prompt":"add feature"}]' > "$RT_DIR/tasks.json"
(cd "$RT_REPO3" && env RT_MOVE_BASE="$RT_REPO3" PATH="$(shell_path "$RT_DIR/bin"):$PATH" MUSE_DATA_DIR="$RT_DIR/musedata" RT_STUB_LOG="$RT_DIR/stub3.log" \
   python3 "$FLEET" --tasks "$RT_DIR/tasks.json" --repo "$RT_REPO3" --out "$RT_DIR/fout" \
   --worktree-root "$RT_DIR/fwt" --model stub-model --base main >/dev/null 2>"$RT_DIR/fleet.err")
RT_FPATCH="$RT_DIR/fout/f1/patch.diff"
[ "$(git -C "$RT_REPO3" rev-parse main)" != "$RT_BASE3" ] && ok "roundtrip: fleet base moved mid-run" \
  || bad "roundtrip: fleet base did not move"
[ "$(rt_jget "$RT_DIR/fout/report.json" 'd["tasks"][0]["base"]' 2>/dev/null)" = "$RT_BASE3" ] \
  && [ -s "$RT_FPATCH" ] && grep -q '^+line-1$' "$RT_FPATCH" && ! grep -q other.txt "$RT_FPATCH" \
  && ok "roundtrip: fleet pins base to a sha and harvests against it" \
  || bad "roundtrip: fleet harvest followed the moved ref" "$(tail -3 "$RT_DIR/fleet.err"; cat "$RT_FPATCH" 2>/dev/null | head)"

unset -f rt_py rt_jget rt_mkrepo 2>/dev/null || true
if [ "$RT_STANDALONE" = 1 ]; then
  printf 'roundtrip: %d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]; exit $?
fi
