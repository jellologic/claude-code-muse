# shellcheck shell=bash
# A killed supervisor must not leave a --yolo worker running. Driven through the real
# scripts with a stub muse that sleeps and then writes late.txt: if the stub survives the
# parent, late.txt appears after the parent is gone and the round count never saw it.
SG_STANDALONE=0
if ! declare -F ok >/dev/null 2>&1; then
  SG_STANDALONE=1
  PASS=0; FAIL=0
  ok() { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
  bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ -n "${2:-}" ] && echo "        $2"; }
  SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  LAB="$(mktemp -d "${TMPDIR:-/tmp}/musetest.XXXXXX")"
  shell_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi
  }
fi

SG_BASE="$LAB/v_signals"
SG_BIN="$SG_BASE/bin"
SG_REPO="$SG_BASE/repo"
SG_OUT="$SG_BASE/out"
SG_WT="$SG_BASE/wt"
SG_LOG="$SG_BASE/stub.log"
rm -rf "$SG_BASE"; mkdir -p "$SG_BIN" "$SG_OUT" "$SG_WT" "$SG_BASE/data" "$SG_BASE/plugdata"
: > "$SG_LOG"
cat > "$SG_BIN/muse" <<'STUB'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then echo "muse 0.0.0"; exit 0; fi
wt=""; prev=""
for a in "$@"; do
  [ "$prev" = "--workspace" ] && wt="$a"
  prev="$a"
done
echo "$$" >> "$SG_STUB_LOG"
sleep "${SG_STUB_SLEEP:-4}"
: > "${wt:-.}/late.txt"
printf '{"payload":{"kind":"run_terminal","terminal":"completed","text":"ok"}}\n'
STUB
chmod +x "$SG_BIN/muse"
git init -q -b main "$SG_REPO"
printf 'x = 1\n' > "$SG_REPO/a.py"
git -C "$SG_REPO" add -A
git -C "$SG_REPO" -c user.email=t@l -c user.name=t commit -qm init
SG_PATH="$(shell_path "$SG_BIN"):$PATH"
export SG_STUB_LOG="$SG_LOG"

sg_task() {  # sg_task <subcommand> <id> [args...]
  local c="$1" i="$2"; shift 2
  PATH="$SG_PATH" MUSE_DATA_DIR="$SG_BASE/data" python3 "$SKILL/scripts/muse_task.py" "$c" \
    --id "$i" --out "$SG_OUT" "$@"
}
sg_field() {  # sg_field <json> <key>
  printf '%s' "$1" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get(sys.argv[1], ""))
except Exception: print("")' "$2"
}
sg_state_wt() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["worktree"])' "$SG_OUT/$1/state.json" 2>/dev/null; }
sg_alive() {  # any pid in the stub log still running?
  local p
  for p in $(cat "$SG_LOG"); do kill -0 "$p" 2>/dev/null && return 0; done
  pgrep -f "$SG_BIN/muse" >/dev/null 2>&1
}

# Control: left alone, the stub does write late.txt, so its absence later means something.
SG_STUB_SLEEP=1 sg_task run ctl --repo "$SG_REPO" --worktree-root "$SG_WT" --model stub-model \
  --no-secret-scan --prompt p >/dev/null 2>&1
SG_CWT="$(sg_state_wt ctl)"
if [ -n "$SG_CWT" ] && [ -f "$SG_CWT/late.txt" ]; then
  ok "signals: control — an uninterrupted stub writes late.txt"
else
  bad "signals: control — an uninterrupted stub writes late.txt" "worktree='$SG_CWT'"
fi

: > "$SG_LOG"
SG_STUB_SLEEP=4 PATH="$SG_PATH" MUSE_DATA_DIR="$SG_BASE/data" python3 "$SKILL/scripts/muse_task.py" run \
  --id sig --out "$SG_OUT" --repo "$SG_REPO" --worktree-root "$SG_WT" --model stub-model \
  --no-secret-scan --prompt p >"$SG_BASE/run.out" 2>"$SG_BASE/run.err" &
SG_RUNPID=$!
SG_i=0
while [ "$SG_i" -lt 50 ] && ! [ -s "$SG_LOG" ]; do sleep 0.1; SG_i=$((SG_i+1)); done
SG_i=0
while [ "$SG_i" -lt 20 ] && ! grep -q round_in_flight "$SG_OUT/sig/state.json" 2>/dev/null; do sleep 0.1; SG_i=$((SG_i+1)); done
if [ -s "$SG_LOG" ] && sg_alive; then
  ok "signals: the worker stub is running before the parent is signalled"
else
  bad "signals: the worker stub is running before the parent is signalled" "$(cat "$SG_BASE/run.err")"
fi

SG_REV="$(SG_STUB_SLEEP=0 sg_task revise sig --feedback x 2>/dev/null)"; SG_REVRC=$?
SG_NSTUB="$(wc -l < "$SG_LOG" | tr -d ' ')"
if [ "$SG_REVRC" -ne 0 ] && [ "$(sg_field "$SG_REV" status)" = "round_in_flight" ] && [ "$SG_NSTUB" = "1" ]; then
  ok "signals: revise while a round is live refuses with round_in_flight"
else
  bad "signals: revise while a round is live refuses with round_in_flight" "rc=$SG_REVRC stubs=$SG_NSTUB out=$SG_REV"
fi

SG_WTP="$(sg_state_wt sig)"
kill -TERM "$SG_RUNPID" 2>/dev/null
wait "$SG_RUNPID" 2>/dev/null
sleep 5
if [ -n "$SG_WTP" ] && ! sg_alive && ! [ -e "$SG_WTP/late.txt" ]; then
  ok "signals: SIGTERM to muse_task leaves no worker alive and no late write"
else
  bad "signals: SIGTERM to muse_task leaves no worker alive and no late write" \
    "worktree='$SG_WTP' alive=$(sg_alive && echo yes || echo no) late=$([ -e "$SG_WTP/late.txt" ] && echo yes || echo no)"
fi
pkill -f "$SG_BIN/muse" 2>/dev/null
# The killed round still spent money and touched the tree, so it must count against
# max_rounds; unrecorded, the round breaker is bypassed exactly as the issue observed.
SG_LAST="$(python3 -c 'import json,sys
st=json.load(open(sys.argv[1])); r=st.get("rounds") or [{}]
print("{}|{}".format(len(st.get("rounds") or []), r[-1].get("status")))' "$SG_OUT/sig/state.json" 2>/dev/null)"
SG_RUNST="$(sg_field "$(cat "$SG_BASE/run.out" 2>/dev/null)" status)"
if [ "$SG_LAST" = "1|interrupted" ] && [ "$SG_RUNST" = "interrupted" ]; then
  ok "signals: the interrupted round is recorded and reported as interrupted"
else
  bad "signals: the interrupted round is recorded and reported as interrupted" "state=$SG_LAST stdout_status=$SG_RUNST"
fi

# A marker whose pid is dead is stale: revise clears it and runs.
SG_DEAD="$(sh -c 'echo $$')"
python3 - "$SG_OUT/sig/state.json" "$SG_DEAD" <<'PY'
import json, sys
p, pid = sys.argv[1], int(sys.argv[2])
st = json.load(open(p))
st["round_in_flight"] = {"pid": pid, "pgid": pid, "started": "2000-01-01T00:00:00"}
json.dump(st, open(p, "w"))
PY
: > "$SG_LOG"
SG_REV2="$(SG_STUB_SLEEP=0 sg_task revise sig --feedback x 2>/dev/null)"
SG_LEFT="$(python3 -c 'import json,sys; print("round_in_flight" in json.load(open(sys.argv[1])))' "$SG_OUT/sig/state.json" 2>/dev/null)"
if [ "$(sg_field "$SG_REV2" status)" = "completed" ] && [ -s "$SG_LOG" ] && [ "$SG_LEFT" = "False" ]; then
  ok "signals: a stale round_in_flight marker is cleared and the round runs"
else
  bad "signals: a stale round_in_flight marker is cleared and the round runs" "left=$SG_LEFT out=$SG_REV2"
fi

# muse_ask.sh --write: the trap must take the muse group down, not just the watchdog.
: > "$SG_LOG"
SG_AREPO="$SG_BASE/askrepo"; mkdir -p "$SG_AREPO"
( cd "$SG_AREPO" && SG_STUB_SLEEP=4 PATH="$SG_PATH" CLAUDE_PLUGIN_DATA="$SG_BASE/plugdata" \
    exec bash "$SKILL/scripts/muse_ask.sh" --model stub-model --write --timeout 60 "q" ) \
  >/dev/null 2>&1 &
SG_ASKPID=$!
SG_i=0
while [ "$SG_i" -lt 50 ] && ! [ -s "$SG_LOG" ]; do sleep 0.1; SG_i=$((SG_i+1)); done
if [ -s "$SG_LOG" ] && sg_alive; then
  kill -TERM "$SG_ASKPID" 2>/dev/null
  wait "$SG_ASKPID" 2>/dev/null
  sleep 5
  if ! sg_alive && ! [ -e "$SG_AREPO/late.txt" ]; then
    ok "signals: SIGTERM to muse_ask.sh leaves no worker alive and no late write"
  else
    bad "signals: SIGTERM to muse_ask.sh leaves no worker alive and no late write" \
      "alive=$(sg_alive && echo yes || echo no) late=$([ -e "$SG_AREPO/late.txt" ] && echo yes || echo no)"
  fi
else
  bad "signals: muse_ask.sh stub started" "stub log empty"
fi
pkill -f "$SG_BIN/muse" 2>/dev/null

# muse_fleet.py: same property, and the report must still be written, marked interrupted.
: > "$SG_LOG"
SG_FOUT="$SG_BASE/fleet-out"; SG_FWT="$SG_BASE/fleet-wt"
printf '[{"id":"f1","prompt":"p"}]' > "$SG_BASE/tasks.json"
SG_STUB_SLEEP=4 PATH="$SG_PATH" MUSE_DATA_DIR="$SG_BASE/data" python3 "$SKILL/scripts/muse_fleet.py" \
  --tasks "$SG_BASE/tasks.json" --repo "$SG_REPO" --out "$SG_FOUT" --worktree-root "$SG_FWT" \
  --model stub-model >/dev/null 2>"$SG_BASE/fleet.err" &
SG_FPID=$!
SG_i=0
while [ "$SG_i" -lt 50 ] && ! [ -s "$SG_LOG" ]; do sleep 0.1; SG_i=$((SG_i+1)); done
if [ -s "$SG_LOG" ] && sg_alive; then
  kill -TERM "$SG_FPID" 2>/dev/null
  wait "$SG_FPID" 2>/dev/null
  sleep 5
  SG_FLATE="$(find "$SG_FWT" -name late.txt 2>/dev/null | head -1)"
  SG_FINT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("interrupted"))' "$SG_FOUT/report.json" 2>/dev/null)"
  if ! sg_alive && [ -z "$SG_FLATE" ] && [ "$SG_FINT" = "True" ]; then
    ok "signals: SIGTERM to muse_fleet.py kills the worker and still writes an interrupted report"
  else
    bad "signals: SIGTERM to muse_fleet.py kills the worker and still writes an interrupted report" \
      "alive=$(sg_alive && echo yes || echo no) late='$SG_FLATE' interrupted='$SG_FINT'"
  fi
else
  bad "signals: muse_fleet.py stub started" "$(tail -3 "$SG_BASE/fleet.err")"
fi
pkill -f "$SG_BIN/muse" 2>/dev/null

# The Bash tool kills its command at 600s; a longer default lets the tool kill the
# parent while the worker keeps running, which is this whole bug by another route.
SG_TO="$(python3 -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("mc", sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.DEFAULT_TIMEOUT)' "$SKILL/scripts/muse_core.py" 2>/dev/null)"
if [ -n "$SG_TO" ] && [ "$SG_TO" -lt 600 ]; then
  ok "signals: DEFAULT_TIMEOUT ($SG_TO) is below the Bash tool's 600s ceiling"
else
  bad "signals: DEFAULT_TIMEOUT is below the Bash tool's 600s ceiling" "got '$SG_TO'"
fi

if [ "$SG_STANDALONE" -eq 1 ]; then
  rm -rf "$LAB"
  exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
fi
