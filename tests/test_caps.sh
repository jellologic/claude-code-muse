#!/usr/bin/env bash
# Capability surface: the repo event stream, the monitor, the status line and
# the release helper. Sourced by validate.sh; also runnable alone.
# Every check here starts with "caps: " so CI failures attribute to this task.
CAPS_STANDALONE=0
if ! declare -F ok >/dev/null 2>&1; then
  CAPS_STANDALONE=1
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
  LAB="$(mktemp -d "${TMPDIR:-/tmp}/muse-caps.XXXXXX")"
  # Every path below is built from LAB and the next lines rm -rf under it.
  if [ -z "$LAB" ] || [ ! -d "$LAB" ]; then echo "no scratch dir" >&2; exit 1; fi
  LAB="$(native_path "$LAB")"
  PASS=0; FAIL=0
  ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
  bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && echo "        $2"; }
fi
. "$(dirname "${BASH_SOURCE[0]}")/lib_stub.sh"

CAPS_MON="$SKILL/scripts/muse_monitor.py"
CAPS_STATUS="$SKILL/scripts/muse_statusline.py"
CAPS_RELEASE="$SKILL/scripts/release.sh"
CAPS_DIR="$LAB/v_caps"
rm -rf "$CAPS_DIR"; mkdir -p "$CAPS_DIR/bin" "$CAPS_DIR/musedata"
# A muse that edits the worktree it is handed and emits the terminal record,
# the same shape tests/test_roundtrip.sh stubs.
cat > "$CAPS_DIR/bin/muse" <<'STUB'
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
echo "$wt" >> "$CAPS_STUB_LOG"
printf '{"payload":{"kind":"run_terminal","terminal":"completed","text":"ok"}}\n'
STUB
chmod +x "$CAPS_DIR/bin/muse"
win_cmd_shim "$CAPS_DIR/bin/muse"

# The stub goes FIRST on PATH; the env var is removed so it cannot satisfy
# assertions by accident. shell_path keeps the entry intact on Windows.
caps_py() {
  env -u CLAUDE_PLUGIN_OPTION_MAX_ROUNDS PATH="$(shell_path "$CAPS_DIR/bin"):$PATH" MUSE_DATA_DIR="$CAPS_DIR/musedata" \
    CAPS_STUB_LOG="$CAPS_DIR/stub.log" python3 "$@"
}
caps_jget() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))" "$@"; }

caps_mkrepo() {
  rm -rf "$1"; mkdir -p "$1"; git init -q -b main "$1"
  printf 'def add(a,b):\n    return a+b\n' > "$1/calc.py"
  git -C "$1" add -A; git -C "$1" -c user.email=t@l -c user.name=t commit -qm init
}

# 1. The manifest points at a real monitors file, and that file is sound.
# Strict validation cannot see a path-referenced file, so this is structural.
cat > "$CAPS_DIR/c1.py" <<'PY'
import json, os, sys
root = sys.argv[1]
d = json.load(open(os.path.join(root, ".claude-plugin", "plugin.json")))
mon = d.get("experimental", {}).get("monitors")
assert isinstance(mon, str) and mon, "experimental.monitors is not a string: %r" % (mon,)
p = os.path.join(root, mon)
assert os.path.isfile(p), "monitors file does not exist: %s" % mon
entries = json.load(open(p))
assert isinstance(entries, list) and entries, "monitors file is not a non-empty list"
names = []
for e in entries:
    assert isinstance(e, dict), "entry is not an object: %r" % (e,)
    for k in ("name", "command", "description"):
        assert isinstance(e.get(k), str) and e[k], "entry lacks non-empty %s: %r" % (k, e)
    assert "${user_config" not in e["command"], "command uses user_config: %r" % (e,)
    names.append(e["name"])
assert len(set(names)) == len(names), "duplicate monitor names: %s" % (names,)
print("monitors file holds %d sound entr%s" % (len(entries), "y" if len(entries) == 1 else "ies"))
PY
CAPS_MON_ERR="$(python3 "$CAPS_DIR/c1.py" "$SKILL" 2>&1)"; CAPS_PY1=$?
if [ "$CAPS_PY1" -eq 0 ]; then ok "caps: plugin.json names a sound monitors file ($CAPS_MON_ERR)"; else bad "caps: plugin.json monitors wiring" "$CAPS_MON_ERR"; fi

# 2. settings.json holds only supported keys and names a real script.
cat > "$CAPS_DIR/c2.py" <<'PY'
import json, os, sys
root = sys.argv[1]
d = json.load(open(os.path.join(root, "settings.json")))
assert isinstance(d, dict), "settings.json is not an object"
assert set(d) <= {"agent", "subagentStatusLine"}, "unsupported keys: %s" % sorted(set(d))
sl = d["subagentStatusLine"]
assert sl["type"] == "command", "subagentStatusLine.type is not command: %r" % (sl.get("type"),)
cmd = sl["command"].replace("${CLAUDE_PLUGIN_ROOT}", root)
toks = [t.strip('"') for t in cmd.split()]
cands = [t for t in toks if t.endswith("muse_statusline.py")]
assert cands, "no statusline script in command: %r" % (sl["command"],)
assert os.path.isfile(cands[0]), "statusline script missing: %s" % cands[0]
print("settings.json points at an existing statusline script")
PY
CAPS_SET_ERR="$(python3 "$CAPS_DIR/c2.py" "$SKILL" 2>&1)"; CAPS_PY2=$?
if [ "$CAPS_PY2" -eq 0 ]; then ok "caps: settings.json names an existing statusline script"; else bad "caps: settings.json wiring" "$CAPS_SET_ERR"; fi

# 3-5. A stub-driven task writes round, verify and verdict events into the repo.
CAPS_REPO="$CAPS_DIR/repo"; caps_mkrepo "$CAPS_REPO"
CAPS_OUT="$CAPS_DIR/out"; : > "$CAPS_DIR/stub.log"
(cd "$CAPS_REPO" && caps_py "$TASK" run --id t1 --repo "$CAPS_REPO" --out "$CAPS_OUT" --worktree-root "$CAPS_DIR/wt" \
  --model stub-model --base main --max-rounds 2 --prompt "add feature" >"$CAPS_DIR/run.json" 2>"$CAPS_DIR/run.err")
(cd "$CAPS_REPO" && caps_py "$TASK" verify --id t1 --out "$CAPS_OUT" --command "exit 0" >"$CAPS_DIR/ver0.json" 2>/dev/null)
(cd "$CAPS_REPO" && caps_py "$TASK" verify --id t1 --out "$CAPS_OUT" --command "exit 1" >"$CAPS_DIR/ver1.json" 2>/dev/null)
(cd "$CAPS_REPO" && caps_py "$TASK" finish --id t1 --out "$CAPS_OUT" --verdict reject --summary s >"$CAPS_DIR/fin.json" 2>/dev/null)
CAPS_EV="$CAPS_REPO/.muse-fleet/events.jsonl"

cat > "$CAPS_DIR/c3.py" <<'PY'
import json, sys
evs = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
assert len(evs) >= 2, "fewer than 2 events: %d" % len(evs)
a, b = evs[0], evs[1]
assert a.get("event") == "round_started" and b.get("event") == "round_finished", \
    "first two events are %r, %r" % (a.get("event"), b.get("event"))
for e in (a, b):
    assert e.get("task") == "t1" and e.get("round") == 1 and e.get("max_rounds") == 2, repr(e)
assert a.get("kind") == "initial", repr(a)
print("round_started then round_finished, round 1 of max_rounds 2")
PY
CAPS_E3="$(python3 "$CAPS_DIR/c3.py" "$CAPS_EV" 2>&1)"; CAPS_PY3=$?
if [ "$CAPS_PY3" -eq 0 ]; then ok "caps: task run writes round_started then round_finished"; else bad "caps: task run writes round_started then round_finished" "$CAPS_E3"; fi

cat > "$CAPS_DIR/c4.py" <<'PY'
import json, sys
evs = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
vs = [e for e in evs if e.get("event") == "verify"]
assert len(vs) >= 2, "fewer than 2 verify events: %d" % len(vs)
assert vs[0].get("passed") is True and vs[0].get("exit_code") == 0, repr(vs[0])
assert vs[1].get("passed") is False and vs[1].get("exit_code") == 1, repr(vs[1])
print("verify passed=true/exit 0 then passed=false/exit 1")
PY
CAPS_E4="$(python3 "$CAPS_DIR/c4.py" "$CAPS_EV" 2>&1)"; CAPS_PY4=$?
if [ "$CAPS_PY4" -eq 0 ]; then ok "caps: verify writes passed and failed check events"; else bad "caps: verify writes passed and failed check events" "$CAPS_E4"; fi

cat > "$CAPS_DIR/c5.py" <<'PY'
import json, sys
evs = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
vs = [e for e in evs if e.get("event") == "verdict"]
assert len(vs) == 1, "expected 1 verdict event, got %d" % len(vs)
assert vs[0].get("verdict") == "reject" and vs[0].get("task") == "t1", repr(vs[0])
print("verdict reject recorded")
PY
CAPS_E5="$(python3 "$CAPS_DIR/c5.py" "$CAPS_EV" 2>&1)"; CAPS_PY5=$?
if [ "$CAPS_PY5" -eq 0 ]; then ok "caps: finish writes the verdict event"; else bad "caps: finish writes the verdict event" "$CAPS_E5"; fi

# 6. A directory squatting on the events path must not fail the round.
CAPS_REPO6="$CAPS_DIR/repo6"; caps_mkrepo "$CAPS_REPO6"
mkdir -p "$CAPS_REPO6/.muse-fleet/events.jsonl"
if [ -d "$CAPS_REPO6/.muse-fleet/events.jsonl" ]; then
  (cd "$CAPS_REPO6" && caps_py "$TASK" run --id t6 --repo "$CAPS_REPO6" --out "$CAPS_DIR/out6" --worktree-root "$CAPS_DIR/wt6" \
    --model stub-model --base main --max-rounds 2 --prompt "add feature" >"$CAPS_DIR/run6.json" 2>"$CAPS_DIR/run6.err")
  CAPS_RC6=$?
  cat > "$CAPS_DIR/c6.py" <<'PY'
import json, sys
st = json.load(open(sys.argv[1], encoding="utf-8"))
out = json.load(open(sys.argv[2], encoding="utf-8"))
assert len(st["rounds"]) == 1, "rounds: %r" % (st.get("rounds"),)
assert out.get("status") == "completed", repr(out.get("status"))
print("1 round, stdout status completed")
PY
  CAPS_E6="$(python3 "$CAPS_DIR/c6.py" "$CAPS_DIR/out6/t6/state.json" "$CAPS_DIR/run6.json" 2>&1)"
  CAPS_PY6=$?
  if [ "$CAPS_RC6" = 0 ] && [ "$CAPS_PY6" = 0 ]; then
    ok "caps: a blocked events path still completes the round"
  else
    bad "caps: a blocked events path still completes the round" "rc=$CAPS_RC6 $CAPS_E6"
  fi
else
  bad "caps: a blocked events path still completes the round" "the events.jsonl directory was not created, so nothing is under test"
fi

# 7. Fleet tasks report into the repo stream with their stamp.
CAPS_REPO7="$CAPS_DIR/repo7"; caps_mkrepo "$CAPS_REPO7"
echo '[{"id":"f1","prompt":"add feature"}]' > "$CAPS_DIR/tasks7.json"
(cd "$CAPS_REPO7" && caps_py "$FLEET" --tasks "$CAPS_DIR/tasks7.json" --repo "$CAPS_REPO7" --out "$CAPS_DIR/fout7" \
  --worktree-root "$CAPS_DIR/fwt7" --model stub-model --base main >/dev/null 2>"$CAPS_DIR/fleet7.err")
cat > "$CAPS_DIR/c7.py" <<'PY'
import json, sys
evs = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
got = [e for e in evs if e.get("task") == "f1"]
assert got, "no events for f1 in %d events" % len(evs)
kinds = [e.get("event") for e in got]
assert "round_started" in kinds and "round_finished" in kinds, repr(kinds)
assert all(e.get("fleet") for e in got), "missing fleet stamp: %r" % (got,)
print("f1 round_started+round_finished, stamped %r" % (got[0]["fleet"],))
PY
CAPS_E7="$(python3 "$CAPS_DIR/c7.py" "$CAPS_REPO7/.muse-fleet/events.jsonl" 2>&1)"; CAPS_PY7=$?
if [ "$CAPS_PY7" -eq 0 ]; then ok "caps: fleet writes stamped round events"; else bad "caps: fleet writes stamped round events" "$CAPS_E7"; fi

# 8-10. The monitor renders one line per valid event, honours its config file,
# and degrades to defaults on a bad one.
CAPS_FIX="$CAPS_DIR/fixture.jsonl"
printf '%s\n' '{"event":"round_started","task":"t9","round":2,"max_rounds":3,"kind":"revise"}' \
  '{"event":"round_finished","task":"t9","round":2,"max_rounds":3,"status":"completed","patch_lines":14}' \
  'not json{' \
  '{"event":"verify","task":"t9","round":2,"max_rounds":3,"passed":true,"exit_code":0,"timed_out":false}' \
  '{"event":"verdict","task":"t9","max_rounds":3,"verdict":"accept","rounds_used":2,"verified":true}' \
  '' > "$CAPS_FIX"
if grep -q 'not json{' "$CAPS_FIX"; then
  python3 "$CAPS_MON" --once --file "$CAPS_FIX" >"$CAPS_DIR/mon8.out" 2>"$CAPS_DIR/mon8.err"
  CAPS_RC8=$?
  cat > "$CAPS_DIR/c8.py" <<'PY'
import sys
lines = [l for l in open(sys.argv[1], encoding="utf-8").read().replace("\r", "").split("\n") if l.strip()]
assert len(lines) == 4, "expected 4 lines, got %d: %r" % (len(lines), lines)
assert all("t9" in l for l in lines), repr(lines)
assert "passed" in lines[2], repr(lines[2])
assert "accept" in lines[3], repr(lines[3])
assert lines[0].startswith("muse[t9] round 2/3 started"), repr(lines[0])
print("4 ordered lines, malformed and blank skipped")
PY
  CAPS_E8="$(python3 "$CAPS_DIR/c8.py" "$CAPS_DIR/mon8.out" 2>&1)"
  CAPS_PY8=$?
  if [ "$CAPS_RC8" = 0 ] && [ "$CAPS_PY8" = 0 ]; then
    ok "caps: monitor renders one line per valid event"
  else
    bad "caps: monitor renders one line per valid event" "rc=$CAPS_RC8 $CAPS_E8"
  fi
else
  bad "caps: monitor renders one line per valid event" "the fixture lost its malformed line, so the skip is untested"
fi

printf '%s' '{"events":["verdict"]}' > "$CAPS_DIR/cfg9.json"
python3 "$CAPS_MON" --once --file "$CAPS_FIX" --config "$CAPS_DIR/cfg9.json" >"$CAPS_DIR/mon9.out" 2>/dev/null
cat > "$CAPS_DIR/c9.py" <<'PY'
import sys
lines = [l for l in open(sys.argv[1], encoding="utf-8").read().replace("\r", "").split("\n") if l.strip()]
assert len(lines) == 1, "expected 1 line, got %d: %r" % (len(lines), lines)
assert "accept" in lines[0], repr(lines)
print("only the verdict delivered")
PY
CAPS_E9="$(python3 "$CAPS_DIR/c9.py" "$CAPS_DIR/mon9.out" 2>&1)"; CAPS_PY9=$?
if [ "$CAPS_PY9" -eq 0 ]; then ok "caps: monitor config filters to verdict only"; else bad "caps: monitor config filters to verdict only" "$CAPS_E9"; fi

printf '%s' 'not json{' > "$CAPS_DIR/cfg10.json"
python3 "$CAPS_MON" --once --file "$CAPS_FIX" --config "$CAPS_DIR/cfg10.json" >"$CAPS_DIR/mon10.out" 2>"$CAPS_DIR/mon10.err"
CAPS_RC10=$?
cat > "$CAPS_DIR/c10.py" <<'PY'
import sys
lines = [l for l in open(sys.argv[1], encoding="utf-8").read().replace("\r", "").split("\n") if l.strip()]
assert len(lines) == 4, "expected 4 lines, got %d" % len(lines)
print("defaults survived a bad config")
PY
CAPS_E10="$(python3 "$CAPS_DIR/c10.py" "$CAPS_DIR/mon10.out" 2>&1)"
CAPS_PY10=$?
if [ "$CAPS_RC10" = 0 ] && [ "$CAPS_PY10" = 0 ]; then
  ok "caps: monitor falls back to defaults on a bad config"
else
  bad "caps: monitor falls back to defaults on a bad config" "rc=$CAPS_RC10 $CAPS_E10"
fi

# 11-12. Follow mode delivers only new events and dies quietly on SIGTERM.
CAPS_FOLLOW="$CAPS_DIR/follow.jsonl"
printf '%s\n' '{"event":"round_started","task":"pre","round":1,"max_rounds":1,"kind":"initial"}' > "$CAPS_FOLLOW"
CAPS_TRIG="$CAPS_DIR/term.trigger"
caps_bg() {
  rm -f "$CAPS_TRIG"
  if is_windows; then
    python3 "$SKILL/tests/sig_driver.py" "$CAPS_TRIG" "$@" &
  else
    python3 "$@" &
  fi
  CAPS_BGPID=$!
}
caps_bg "$CAPS_MON" --file "$CAPS_FOLLOW" --poll 0.2 >"$CAPS_DIR/follow.out" 2>"$CAPS_DIR/follow.err"
sleep 2
printf '%s\n' '{"event":"round_finished","task":"fw","round":1,"max_rounds":1,"status":"completed","patch_lines":3}' \
  '{"event":"verdict","task":"fw","max_rounds":1,"verdict":"accept","rounds_used":1,"verified":true}' >> "$CAPS_FOLLOW"
CAPS_GOT=0
for CAPS_I in $(seq 1 150); do
  if [ -f "$CAPS_DIR/follow.out" ]; then
    CAPS_GOT=$(tr -d '\r' < "$CAPS_DIR/follow.out" | grep -c . || true)
  else
    CAPS_GOT=0
  fi
  [ "$CAPS_GOT" -ge 2 ] && break
  sleep 0.1
done
cat > "$CAPS_DIR/c11.py" <<'PY'
import sys
lines = [l for l in open(sys.argv[1], encoding="utf-8").read().replace("\r", "").split("\n") if l.strip()]
assert len(lines) == 2, "expected exactly 2 lines, got %d: %r" % (len(lines), lines)
assert all("fw" in l for l in lines), repr(lines)
assert not any("pre" in l for l in lines), "pre-existing event replayed: %r" % (lines,)
print("only the 2 appended events delivered")
PY
CAPS_E11="$(python3 "$CAPS_DIR/c11.py" "$CAPS_DIR/follow.out" 2>&1)"; CAPS_PY11=$?
if [ "$CAPS_PY11" -eq 0 ]; then ok "caps: monitor follow mode delivers only new events"; else bad "caps: monitor follow mode delivers only new events" "$CAPS_E11"; fi

# A pid is "gone" when it vanished or its jobs line says Done: a
# dead-but-unreaped monitor is a zombie that still answers kill -0, so
# kill -0 alone would wait out the whole timeout on a clean exit.
caps_gone() {
  kill -0 "$1" 2>/dev/null || return 0
  jobs -l 2>/dev/null | grep -w "$1" | grep -q 'Running' && return 1 || return 0
}
# Bound the shutdown: an unbounded wait stalls the whole suite when the
# monitor ignores the signal. After KILL the final wait is bounded (SIGKILL
# cannot be caught), so only the graceful window is polled.
if [ -n "${CAPS_BGPID:-}" ]; then
  if is_windows; then : > "$CAPS_TRIG"; else kill -TERM "$CAPS_BGPID" 2>/dev/null; fi
  CAPS_DEAD=0
  for CAPS_J in $(seq 1 100); do
    if caps_gone "$CAPS_BGPID"; then CAPS_DEAD=1; break; fi
    sleep 0.1
  done
  if [ "$CAPS_DEAD" = 0 ]; then
    # Still running after ~10s: the monitor ignored SIGTERM. Escalate and
    # fail below (the wait reports 137, not 0).
    kill -KILL "$CAPS_BGPID" 2>/dev/null || true
  fi
  wait "$CAPS_BGPID"; CAPS_RC12=$?
  # Leftover cleanup in every path before moving on.
  kill -KILL "$CAPS_BGPID" 2>/dev/null || true
  wait "$CAPS_BGPID" 2>/dev/null || true
else
  CAPS_RC12=1; CAPS_DEAD=0
fi
if [ "$CAPS_DEAD" = 1 ] && [ "$CAPS_RC12" = 0 ] && ! grep -q 'Traceback' "$CAPS_DIR/follow.err" 2>/dev/null; then
  ok "caps: monitor exits 0 without a traceback on SIGTERM"
else
  bad "caps: monitor exits 0 without a traceback on SIGTERM" "rc=$CAPS_RC12 dead=$CAPS_DEAD $(cat "$CAPS_DIR/follow.err" 2>/dev/null | head -3)"
fi

# 13-14. The status line overrides the supervisor row and leaves others alone.
CAPS_SLREPO="$CAPS_DIR/slrepo"; caps_mkrepo "$CAPS_SLREPO"
mkdir -p "$CAPS_SLREPO/.muse-fleet"
printf '%s\n' '{"event":"round_started","task":"t1","round":2,"max_rounds":3,"kind":"revise"}' \
  '{"event":"verify","task":"t1","round":2,"max_rounds":3,"passed":false,"exit_code":1,"timed_out":false}' > "$CAPS_SLREPO/.muse-fleet/events.jsonl"
python3 - "$CAPS_SLREPO" > "$CAPS_DIR/sl-in.json" <<'PY'
import json, sys
repo = sys.argv[1]
print(json.dumps({"cwd": repo, "columns": 200, "tasks": [
    {"id": "a1", "type": "muse:muse-supervisor", "label": "task:t1",
     "description": "x", "cwd": repo},
    {"id": "a2", "type": "general-purpose", "description": "t1", "cwd": repo}]}))
PY
python3 "$CAPS_STATUS" < "$CAPS_DIR/sl-in.json" >"$CAPS_DIR/sl.out" 2>"$CAPS_DIR/sl.err"
CAPS_RC13=$?
cat > "$CAPS_DIR/c13.py" <<'PY'
import json, sys
lines = [l for l in open(sys.argv[1], encoding="utf-8").read().replace("\r", "").split("\n") if l.strip()]
assert len(lines) == 1, "expected 1 row, got %d: %r" % (len(lines), lines)
row = json.loads(lines[0])
assert row.get("id") == "a1", repr(row)
for needle in ("t1", "2/3", "FAILED"):
    assert needle in row.get("content", ""), "%r not in %r" % (needle, row)
print(row["content"])
PY
CAPS_E13="$(python3 "$CAPS_DIR/c13.py" "$CAPS_DIR/sl.out" 2>&1)"
CAPS_PY13=$?
if [ "$CAPS_RC13" = 0 ] && [ "$CAPS_PY13" = 0 ]; then
  ok "caps: statusline overrides the supervisor row ($CAPS_E13)"
else
  bad "caps: statusline overrides the supervisor row" "rc=$CAPS_RC13 $CAPS_E13"
fi

if grep -q '"a2"' "$CAPS_DIR/sl-in.json"; then
  cat > "$CAPS_DIR/c14.py" <<'PY'
import json, sys
lines = [l for l in open(sys.argv[1], encoding="utf-8").read().replace("\r", "").split("\n") if l.strip()]
assert any(json.loads(l).get("id") == "a1" for l in lines), "no supervisor row"
PY
  if ! python3 "$CAPS_DIR/c14.py" "$CAPS_DIR/sl.out" 2>/dev/null; then
    bad "caps: statusline leaves the non-supervisor row alone" "the statusline printed no supervisor row, so the absence is untested"
  elif ! grep -q '"a2"' "$CAPS_DIR/sl.out" 2>/dev/null; then
    ok "caps: statusline leaves the non-supervisor row alone"
  else
    bad "caps: statusline leaves the non-supervisor row alone" "a2 row was overridden: $(cat "$CAPS_DIR/sl.out")"
  fi
else
  bad "caps: statusline leaves the non-supervisor row alone" "the input lost its a2 row, so the absence is untested"
fi

# 15. No events file means no rows and a quiet exit 0.
CAPS_SLREPO2="$CAPS_DIR/slrepo2"; caps_mkrepo "$CAPS_SLREPO2"
python3 - "$CAPS_SLREPO2" > "$CAPS_DIR/sl15-in.json" <<'PY'
import json, sys
repo = sys.argv[1]
print(json.dumps({"cwd": repo, "columns": 200, "tasks": [
    {"id": "b1", "type": "muse:muse-supervisor", "label": "task:zz",
     "description": "zz", "cwd": repo}]}))
PY
python3 "$CAPS_STATUS" < "$CAPS_DIR/sl15-in.json" >"$CAPS_DIR/sl15.out" 2>"$CAPS_DIR/sl15.err"
if [ $? = 0 ] && [ ! -s "$CAPS_DIR/sl15.out" ]; then
  ok "caps: statusline is silent when no events file exists"
else
  bad "caps: statusline is silent when no events file exists" "$(cat "$CAPS_DIR/sl15.out" "$CAPS_DIR/sl15.err" 2>/dev/null | head -3)"
fi

# 16. Bad stdin and bad-only event lines both mean exit 0 and empty stdout.
printf '%s' 'not json' | python3 "$CAPS_STATUS" >"$CAPS_DIR/sl16.out" 2>"$CAPS_DIR/sl16.err"
CAPS_RC16=$?
mkdir -p "$CAPS_SLREPO2/.muse-fleet"
printf '%s\n' 'zzz' '{{{' > "$CAPS_SLREPO2/.muse-fleet/events.jsonl"
python3 "$CAPS_STATUS" < "$CAPS_DIR/sl15-in.json" >"$CAPS_DIR/sl16b.out" 2>"$CAPS_DIR/sl16b.err"
CAPS_RC16B=$?
if [ "$CAPS_RC16" = 0 ] && [ ! -s "$CAPS_DIR/sl16.out" ] && ! grep -q 'Traceback' "$CAPS_DIR/sl16.err" \
  && [ "$CAPS_RC16B" = 0 ] && [ ! -s "$CAPS_DIR/sl16b.out" ]; then
  ok "caps: statusline never traces back on bad stdin or bad events"
else
  bad "caps: statusline never traces back on bad stdin or bad events" "rc=$CAPS_RC16/$CAPS_RC16B"
fi

# 17. Without claude on PATH the release helper refuses and names the command.
CAPS_NOPATH="$(dirname "$(command -v bash)"):$(dirname "$(command -v python3)"):$(dirname "$(command -v git)")"
if env PATH="$CAPS_NOPATH" command -v claude >/dev/null 2>&1; then
  bad "caps: release.sh without claude refuses" "claude is on the minimal PATH, so the refusal is untestable here"
else
  CAPS_REL17="$(env PATH="$CAPS_NOPATH" bash "$CAPS_RELEASE" --dry-run 2>&1)"
  CAPS_RC17=$?
  if [ "$CAPS_RC17" -ne 0 ] && printf '%s' "$CAPS_REL17" | grep -q 'claude plugin tag'; then
    ok "caps: release.sh without claude refuses"
  else
    bad "caps: release.sh without claude refuses" "rc=$CAPS_RC17 out=$CAPS_REL17"
  fi
fi

# 18. A failing dry run stops the release after exactly one claude call.
mkdir -p "$CAPS_DIR/fakebin18"
cat > "$CAPS_DIR/fakebin18/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CAPS_CLAUDE_LOG"
if [[ " $* " == *" --dry-run "* ]]; then exit 1; fi
exit 0
STUB
chmod +x "$CAPS_DIR/fakebin18/claude"
: > "$CAPS_DIR/claude18.log"
CAPS_REL18="$(CAPS_CLAUDE_LOG="$CAPS_DIR/claude18.log" PATH="$(shell_path "$CAPS_DIR/fakebin18"):$PATH" bash "$CAPS_RELEASE" 2>&1)"
CAPS_RC18=$?
CAPS_N18=$(tr -d '\r' < "$CAPS_DIR/claude18.log" | grep -c . || true)
if [ "$CAPS_RC18" -ne 0 ] && [ "$CAPS_N18" = 1 ] && grep -q -- '--dry-run' "$CAPS_DIR/claude18.log"; then
  ok "caps: release.sh stops when the dry run fails"
else
  bad "caps: release.sh stops when the dry run fails" "rc=$CAPS_RC18 calls=$CAPS_N18"
fi

# 19. A passing dry run is followed by the real tag with --push and -m.
cat > "$CAPS_DIR/fakebin18/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CAPS_CLAUDE_LOG"
exit 0
STUB
chmod +x "$CAPS_DIR/fakebin18/claude"
: > "$CAPS_DIR/claude19.log"
CAPS_CLAUDE_LOG="$CAPS_DIR/claude19.log" PATH="$(shell_path "$CAPS_DIR/fakebin18"):$PATH" bash "$CAPS_RELEASE" --push >/dev/null 2>&1
CAPS_RC19=$?
cat > "$CAPS_DIR/c19.py" <<'PY'
import sys
lines = [l for l in open(sys.argv[1], encoding="utf-8").read().replace("\r", "").split("\n") if l.strip()]
assert len(lines) == 2, "expected 2 claude calls, got %d: %r" % (len(lines), lines)
assert "--dry-run" in lines[0], repr(lines[0])
assert "--dry-run" not in lines[1] and "--push" in lines[1] and "-m" in lines[1], repr(lines[1])
print("dry-run then tag with --push and -m")
PY
CAPS_E19="$(python3 "$CAPS_DIR/c19.py" "$CAPS_DIR/claude19.log" 2>&1)"; CAPS_PY19=$?
if [ "$CAPS_RC19" = 0 ] && [ "$CAPS_PY19" -eq 0 ]; then
  ok "caps: release.sh tags with --push after the dry run"
else
  bad "caps: release.sh tags with --push after the dry run" "rc=$CAPS_RC19 $CAPS_E19"
fi

# 20. The rejected capabilities are on the record. Presence only, not behaviour.
# Only the section itself counts: matches in Sources or later text prove nothing.
cat > "$CAPS_DIR/c20.py" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
heads = [i for i, l in enumerate(lines) if l.strip() == "## Considered, not adopted"]
assert heads, "heading missing"
start = heads[0] + 1
ends = [i for i in range(start, len(lines)) if lines[i].startswith("## ")]
section = lines[start:ends[0] if ends else len(lines)]
bullets = [l for l in section if l.startswith("- ")]
assert bullets, "no bullets in the section"
sec = "\n".join(bullets).lower().replace(" ", "")
for needle in ("lsp", "outputstyles", "themes", "channels", "dependencies", "worktreecreate"):
    assert needle in sec, needle
print("all six rejections named on bullets")
PY
CAPS_E20="$(python3 "$CAPS_DIR/c20.py" "$SKILL/references/field-notes.md" 2>&1)"; CAPS_PY20=$?
if [ "$CAPS_PY20" -eq 0 ]; then ok "caps: field notes record the rejected capabilities"; else bad "caps: field notes record the rejected capabilities" "$CAPS_E20"; fi

# 21. A labelled supervisor row never shows another task: with a single live
# task the live-fallback would paint every row, so the second labelled row must
# stay silent. The a1 row is the guard: without it the absence of a3 is untested.
CAPS_SLREPO21="$CAPS_DIR/slrepo21"; caps_mkrepo "$CAPS_SLREPO21"
mkdir -p "$CAPS_SLREPO21/.muse-fleet"
printf '%s\n' '{"event":"round_started","task":"t1","round":1,"max_rounds":3,"kind":"initial"}' > "$CAPS_SLREPO21/.muse-fleet/events.jsonl"
python3 - "$CAPS_SLREPO21" > "$CAPS_DIR/sl21-in.json" <<'PY'
import json, sys
repo = sys.argv[1]
print(json.dumps({"cwd": repo, "columns": 200, "tasks": [
    {"id": "a1", "type": "muse:muse-supervisor", "label": "task:t1",
     "description": "x", "cwd": repo},
    {"id": "a3", "type": "muse:muse-supervisor", "label": "task:zz",
     "description": "x", "cwd": repo}]}))
PY
python3 "$CAPS_STATUS" < "$CAPS_DIR/sl21-in.json" >"$CAPS_DIR/sl21.out" 2>"$CAPS_DIR/sl21.err"
CAPS_RC21=$?
cat > "$CAPS_DIR/c21.py" <<'PY'
import json, sys
lines = [l for l in open(sys.argv[1], encoding="utf-8").read().replace("\r", "").split("\n") if l.strip()]
rows = [json.loads(l) for l in lines]
assert any(r.get("id") == "a1" for r in rows), "the statusline printed no a1 row, so the absence of a3 is untested"
assert not any(r.get("id") == "a3" for r in rows), "labelled row a3 shows another task: %r" % (rows,)
assert len(rows) == 1, "expected exactly 1 row, got %d: %r" % (len(rows), rows)
print("a1 only")
PY
CAPS_E21="$(python3 "$CAPS_DIR/c21.py" "$CAPS_DIR/sl21.out" 2>&1)"; CAPS_PY21=$?
if [ "$CAPS_RC21" = 0 ] && [ "$CAPS_PY21" -eq 0 ]; then
  ok "caps: statusline never shows another task on a labelled row"
else
  bad "caps: statusline never shows another task on a labelled row" "rc=$CAPS_RC21 $CAPS_E21"
fi

# 22. A supervisor row whose own cwd is outside any repo falls back to the
# top-level cwd repo. The rev-parse guard proves the row cwd is repo-less,
# without which the fallback path is untested.
CAPS_PLAIN="$CAPS_DIR/plain"; mkdir -p "$CAPS_PLAIN"
python3 - "$CAPS_SLREPO" "$CAPS_PLAIN" > "$CAPS_DIR/sl22-in.json" <<'PY'
import json, sys
repo, plain = sys.argv[1], sys.argv[2]
print(json.dumps({"cwd": repo, "columns": 200, "tasks": [
    {"id": "b1", "type": "muse:muse-supervisor", "label": "task:t1",
     "description": "x", "cwd": plain}]}))
PY
python3 "$CAPS_STATUS" < "$CAPS_DIR/sl22-in.json" >"$CAPS_DIR/sl22.out" 2>"$CAPS_DIR/sl22.err"
CAPS_RC22=$?
if git -C "$CAPS_PLAIN" rev-parse --git-dir >/dev/null 2>&1; then
  bad "caps: statusline falls back to the top-level cwd repo" "the directory is inside a repo so the fallback is untested"
else
  cat > "$CAPS_DIR/c22.py" <<'PY'
import json, sys
lines = [l for l in open(sys.argv[1], encoding="utf-8").read().replace("\r", "").split("\n") if l.strip()]
assert len(lines) == 1, "expected 1 row, got %d: %r" % (len(lines), lines)
row = json.loads(lines[0])
assert row.get("id") == "b1", repr(row)
assert "t1" in row.get("content", ""), repr(row)
print(row["content"])
PY
  CAPS_E22="$(python3 "$CAPS_DIR/c22.py" "$CAPS_DIR/sl22.out" 2>&1)"; CAPS_PY22=$?
  if [ "$CAPS_RC22" = 0 ] && [ "$CAPS_PY22" -eq 0 ]; then
    ok "caps: statusline falls back to the top-level cwd repo"
  else
    bad "caps: statusline falls back to the top-level cwd repo" "rc=$CAPS_RC22 $CAPS_E22"
  fi
fi

# 23. An unlabelled row naming two tasks shows the most recently active one.
CAPS_SLREPO23="$CAPS_DIR/slrepo23"; caps_mkrepo "$CAPS_SLREPO23"
mkdir -p "$CAPS_SLREPO23/.muse-fleet"
printf '%s\n' '{"event":"round_started","task":"alpha","round":1,"max_rounds":2,"kind":"initial"}' \
  '{"event":"round_started","task":"beta","round":1,"max_rounds":2,"kind":"initial"}' > "$CAPS_SLREPO23/.muse-fleet/events.jsonl"
python3 - "$CAPS_SLREPO23" > "$CAPS_DIR/sl23-in.json" <<'PY'
import json, sys
repo = sys.argv[1]
print(json.dumps({"cwd": repo, "columns": 200, "tasks": [
    {"id": "c1", "type": "muse:muse-supervisor", "label": "sup",
     "description": "was alpha, now beta", "cwd": repo}]}))
PY
python3 "$CAPS_STATUS" < "$CAPS_DIR/sl23-in.json" >"$CAPS_DIR/sl23.out" 2>"$CAPS_DIR/sl23.err"
CAPS_RC23=$?
if ! grep -q '"alpha"' "$CAPS_SLREPO23/.muse-fleet/events.jsonl" || ! grep -q '"beta"' "$CAPS_SLREPO23/.muse-fleet/events.jsonl"; then
  bad "caps: statusline picks the most recently active task" "the events file lost a task, so the choice is untested"
else
  cat > "$CAPS_DIR/c23.py" <<'PY'
import json, sys
lines = [l for l in open(sys.argv[1], encoding="utf-8").read().replace("\r", "").split("\n") if l.strip()]
assert len(lines) == 1, "expected 1 row, got %d: %r" % (len(lines), lines)
row = json.loads(lines[0])
assert row.get("id") == "c1", repr(row)
content = row.get("content", "")
assert "beta" in content, repr(row)
assert "alpha" not in content, repr(row)
print(content)
PY
  CAPS_E23="$(python3 "$CAPS_DIR/c23.py" "$CAPS_DIR/sl23.out" 2>&1)"; CAPS_PY23=$?
  if [ "$CAPS_RC23" = 0 ] && [ "$CAPS_PY23" -eq 0 ]; then
    ok "caps: statusline picks the most recently active task"
  else
    bad "caps: statusline picks the most recently active task" "rc=$CAPS_RC23 $CAPS_E23"
  fi
fi

# Bounded shutdown shared by the follow checks: TERM (or the Windows trigger
# file), a ~10s graceful window, then KILL. Reports nothing by itself.
caps_stop() {
  if [ -n "${CAPS_BGPID:-}" ]; then
    if is_windows; then : > "$CAPS_TRIG"; else kill -TERM "$CAPS_BGPID" 2>/dev/null; fi
    CAPS_SDEAD=0
    for CAPS_SJ in $(seq 1 100); do
      if caps_gone "$CAPS_BGPID"; then CAPS_SDEAD=1; break; fi
      sleep 0.1
    done
    if [ "$CAPS_SDEAD" = 0 ]; then
      kill -KILL "$CAPS_BGPID" 2>/dev/null || true
    fi
    wait "$CAPS_BGPID" 2>/dev/null || true
    kill -KILL "$CAPS_BGPID" 2>/dev/null || true
    wait "$CAPS_BGPID" 2>/dev/null || true
  fi
}

# 24. follow() holds a torn line until its newline: the half must not render,
# and the completed line must render exactly once. The readiness line proves
# the monitor was already reading when the half landed; without it a skip
# would look like buffering.
CAPS_TORN="$CAPS_DIR/torn.jsonl"
: > "$CAPS_TORN"
caps_bg "$CAPS_MON" --file "$CAPS_TORN" --poll 0.2 >"$CAPS_DIR/torn.out" 2>"$CAPS_DIR/torn.err"
# follow() starts at EOF, so an append that lands before the monitor's first
# stat is skipped by design. Re-append every ~2s until one is seen: once the
# monitor is up every later append is delivered, and the loop stops before
# the next one, so exactly one readiness line ever renders.
CAPS_READY=0
for CAPS_I in $(seq 1 150); do
  if [ -f "$CAPS_DIR/torn.out" ] && tr -d '\r' < "$CAPS_DIR/torn.out" | grep -q ready; then CAPS_READY=1; break; fi
  if [ $((CAPS_I % 20)) = 1 ]; then
    printf '%s\n' '{"event":"round_started","task":"ready","round":1,"max_rounds":1,"kind":"initial"}' >> "$CAPS_TORN"
  fi
  sleep 0.1
done
if [ "$CAPS_READY" = 0 ]; then
  bad "caps: monitor follow emits a torn line once, whole" "the readiness line never appeared, so the monitor was not reading"
  caps_stop
else
  CAPS_FULL='{"event":"round_finished","task":"torn","round":1,"max_rounds":1,"status":"completed","patch_lines":7}'
  CAPS_BEFORE=$(wc -c < "$CAPS_TORN" | tr -d ' \r')
  printf '%s' "${CAPS_FULL:0:40}" >> "$CAPS_TORN"
  CAPS_AFTER=$(wc -c < "$CAPS_TORN" | tr -d ' \r')
  if [ "$CAPS_AFTER" -le "$CAPS_BEFORE" ]; then
    bad "caps: monitor follow emits a torn line once, whole" "the half line did not land, so the buffering is untested"
    caps_stop
  else
    # Many polls pass over the half line; it must stay silent until completed.
    sleep 1.5
    printf '%s\n' "${CAPS_FULL:40}" >> "$CAPS_TORN"
    for CAPS_I in $(seq 1 150); do
      CAPS_N24=$(tr -d '\r' < "$CAPS_DIR/torn.out" | grep -c . || true)
      [ "$CAPS_N24" -ge 2 ] && break
      sleep 0.1
    done
    cat > "$CAPS_DIR/c24.py" <<'PY'
import sys
lines = [l for l in open(sys.argv[1], encoding="utf-8").read().replace("\r", "").split("\n") if l.strip()]
assert len(lines) == 2, "expected exactly 2 lines, got %d: %r" % (len(lines), lines)
torn = [l for l in lines if "torn" in l]
assert len(torn) == 1, "expected exactly 1 torn line, got %d: %r" % (len(torn), lines)
for needle in ("torn", "finished", "7 patch lines"):
    assert needle in torn[0], "%r not in %r" % (needle, torn[0])
print(torn[0])
PY
    CAPS_E24="$(python3 "$CAPS_DIR/c24.py" "$CAPS_DIR/torn.out" 2>&1)"; CAPS_PY24=$?
    if [ "$CAPS_PY24" -eq 0 ]; then
      ok "caps: monitor follow emits a torn line once, whole"
    else
      bad "caps: monitor follow emits a torn line once, whole" "$CAPS_E24"
    fi
    caps_stop
  fi
fi

# 25. The monitor config path and the plugin-details gap are on the record.
# Only the sections themselves count, the way check 20 scopes its match.
cat > "$CAPS_DIR/c25.py" <<'PY'
import sys
def section(path, heading):
    lines = open(path, encoding="utf-8").read().split("\n")
    heads = [i for i, l in enumerate(lines) if l.strip() == heading]
    assert heads, "%s heading missing in %s" % (heading, path)
    start = heads[0] + 1
    ends = [i for i in range(start, len(lines)) if lines[i].startswith("## ")]
    return "\n".join(lines[start:ends[0] if ends else len(lines)])
adopted = section(sys.argv[1], "## Adopted capabilities")
for needle in ("${CLAUDE_PLUGIN_DATA}/monitor.json", "enabled", "events",
               "round_started", "round_finished", "verify", "verdict",
               "plugin details"):
    assert needle in adopted, needle
configuring = section(sys.argv[2], "## Configuring it")
assert "monitor.json" in configuring, "README Configuring it"
print("monitor.json and the details gap recorded")
PY
CAPS_E25="$(python3 "$CAPS_DIR/c25.py" "$SKILL/references/field-notes.md" "$SKILL/README.md" 2>&1)"; CAPS_PY25=$?
if [ "$CAPS_PY25" -eq 0 ]; then ok "caps: docs record monitor.json and the plugin details gap"; else bad "caps: docs record monitor.json and the plugin details gap" "$CAPS_E25"; fi

# 26. round_finished carries the harvested count end to end: the run JSON's
# patch_lines N (> 0, since the stub appends to feature.txt), the event's
# patch_lines == N, and the monitor renders "N patch lines". N is read from
# the run JSON, not asserted literally: patch_lines counts git diff lines,
# headers included, so a one-line stub file yields more than 1.
CAPS_REPO26="$CAPS_DIR/repo26"; caps_mkrepo "$CAPS_REPO26"
: > "$CAPS_DIR/stub.log"
(cd "$CAPS_REPO26" && caps_py "$TASK" run --id t26 --repo "$CAPS_REPO26" --out "$CAPS_DIR/out26" --worktree-root "$CAPS_DIR/wt26" \
  --model stub-model --base main --max-rounds 2 --prompt "add feature" >"$CAPS_DIR/run26.json" 2>"$CAPS_DIR/run26.err")
CAPS_RC26=$?
python3 "$CAPS_MON" --once --file "$CAPS_REPO26/.muse-fleet/events.jsonl" >"$CAPS_DIR/mon26.out" 2>"$CAPS_DIR/mon26.err"
cat > "$CAPS_DIR/c26.py" <<'PY'
import json, re, sys
run = json.load(open(sys.argv[1], encoding="utf-8"))
evs = [json.loads(l) for l in open(sys.argv[2], encoding="utf-8") if l.strip()]
n = run.get("patch_lines")
assert isinstance(n, int) and n > 0, "run patch_lines is not positive: %r" % (run,)
fin = [e for e in evs if e.get("event") == "round_finished" and e.get("round") == 1]
assert len(fin) == 1, "expected exactly one round_finished for round 1, got %d: %r" % (len(fin), evs)
assert fin[0].get("patch_lines") == n, "event %r does not match run %r" % (fin[0].get("patch_lines"), n)
lines = [l for l in open(sys.argv[3], encoding="utf-8").read().replace("\r", "").split("\n") if "finished" in l]
assert len(lines) == 1, "expected one finished line, got %r" % (lines,)
assert re.search(r"\b%d patch lines" % n, lines[0]), "%r does not report %d patch lines" % (lines[0], n)
print("round_finished carries %d patch lines" % n)
PY
CAPS_E26="$(python3 "$CAPS_DIR/c26.py" "$CAPS_DIR/run26.json" "$CAPS_REPO26/.muse-fleet/events.jsonl" "$CAPS_DIR/mon26.out" 2>&1)"
CAPS_PY26=$?
if [ "$CAPS_RC26" = 0 ] && [ "$CAPS_PY26" = 0 ]; then
  ok "caps: monitor reports the harvested patch line count"
else
  bad "caps: monitor reports the harvested patch line count" "rc=$CAPS_RC26 $CAPS_E26"
fi

# 27. A held index.lock breaks harvest: the run JSON, the round_finished
# event and the monitor must all report the failure, never a count. The
# monitor runs with only round_finished delivered and asserts on the whole
# stdout: exactly one line in total, so the multi-line git reason must
# collapse to a single bounded line instead of one notification per line.
mkdir -p "$CAPS_DIR/bin27"
cat > "$CAPS_DIR/bin27/muse" <<'STUB'
#!/usr/bin/env bash
wt=""; prev=""
for a in "$@"; do
  [ "$prev" = "--workspace" ] && wt="$a"
  prev="$a"
done
[ -n "$wt" ] && [ -d "$wt" ] || { echo "stub: no --workspace" >&2; exit 2; }
echo "work" > "$wt/locked.txt"
: > "$(git -C "$wt" rev-parse --absolute-git-dir)/index.lock"
printf '{"payload":{"kind":"run_terminal","terminal":"completed","text":"ok"}}\n'
STUB
chmod +x "$CAPS_DIR/bin27/muse"
win_cmd_shim "$CAPS_DIR/bin27/muse"
CAPS_REPO27="$CAPS_DIR/repo27"; caps_mkrepo "$CAPS_REPO27"
(cd "$CAPS_REPO27" && env -u CLAUDE_PLUGIN_OPTION_MAX_ROUNDS PATH="$(shell_path "$CAPS_DIR/bin27"):$PATH" MUSE_DATA_DIR="$CAPS_DIR/musedata" \
  python3 "$TASK" run --id t27 --repo "$CAPS_REPO27" --out "$CAPS_DIR/out27" --worktree-root "$CAPS_DIR/wt27" \
  --model stub-model --base main --max-rounds 2 --prompt "add feature" >"$CAPS_DIR/run27.json" 2>"$CAPS_DIR/run27.err")
CAPS_RC27=$?
printf '%s\n' '{"events":["round_finished"]}' > "$CAPS_DIR/mon27.cfg"
python3 "$CAPS_MON" --once --file "$CAPS_REPO27/.muse-fleet/events.jsonl" --config "$CAPS_DIR/mon27.cfg" >"$CAPS_DIR/mon27.out" 2>"$CAPS_DIR/mon27.err"
cat > "$CAPS_DIR/c27.py" <<'PY'
import json, sys
run = json.load(open(sys.argv[1], encoding="utf-8"))
evs = [json.loads(l) for l in open(sys.argv[2], encoding="utf-8") if l.strip()]
assert run.get("harvest_error"), \
    "no harvest_error in run JSON %r: the lock did not take effect, so the error path is untested" % (run,)
fin = [e for e in evs if e.get("event") == "round_finished" and e.get("round") == 1]
assert len(fin) == 1, "expected exactly one round_finished for round 1, got %d: %r" % (len(fin), evs)
assert fin[0].get("harvest_error"), "round_finished lacks harvest_error: %r" % (fin,)
he = fin[0].get("harvest_error")
parts = [p.strip() for p in he.replace("\r\n", "\n").replace("\r", "\n").split("\n")]
nonempty = [p for p in parts if p]
assert len(nonempty) > 1, \
    "harvest_error reason is one line, so the collapse is untested: %r" % (he,)
raw = open(sys.argv[3], encoding="utf-8", newline="").read()
text = raw.replace("\r\n", "\n")
assert text.endswith("\n") and text.count("\n") == 1, \
    "expected exactly one newline-terminated line in total, got %r" % (text,)
line = text[:-1]
assert "\r" not in line, "carriage return in monitor line: %r" % (line,)
assert len(line) <= 300, "monitor line longer than 300 chars: %d" % (len(line),)
assert "harvest failed" in line, "%r does not report the harvest failure" % (line,)
assert "patch lines" not in line, "%r reports a count for a failed harvest" % (line,)
assert nonempty[0][:30] in line, \
    "%r does not carry the collapsed reason %r" % (line, nonempty[0][:30])
print("harvest error reported instead of a count")
PY
CAPS_E27="$(python3 "$CAPS_DIR/c27.py" "$CAPS_DIR/run27.json" "$CAPS_REPO27/.muse-fleet/events.jsonl" "$CAPS_DIR/mon27.out" 2>&1)"
CAPS_PY27=$?
# No rc assertion: a failed harvest makes cmd_run exit 1 by design
# (round_exit_code), and the run JSON is still the record under test.
if [ "$CAPS_PY27" = 0 ]; then
  ok "caps: monitor reports a harvest error instead of a count"
else
  bad "caps: monitor reports a harvest error instead of a count" "rc=$CAPS_RC27 $CAPS_E27"
fi

# 28. A round_started clears the previous round's check: round 1 failed its
# check, round 2 started, so the row must show 2/3 with no check verdict.
CAPS_SLREPO28="$CAPS_DIR/slrepo28"; caps_mkrepo "$CAPS_SLREPO28"
mkdir -p "$CAPS_SLREPO28/.muse-fleet"
printf '%s\n' '{"event":"round_started","task":"t1","round":1,"max_rounds":3,"kind":"initial"}' \
  '{"event":"verify","task":"t1","round":1,"max_rounds":3,"passed":false,"exit_code":1,"timed_out":false}' \
  '{"event":"round_started","task":"t1","round":2,"max_rounds":3,"kind":"revise"}' > "$CAPS_SLREPO28/.muse-fleet/events.jsonl"
python3 - "$CAPS_SLREPO28" > "$CAPS_DIR/sl28-in.json" <<'PY'
import json, sys
repo = sys.argv[1]
print(json.dumps({"cwd": repo, "columns": 200, "tasks": [
    {"id": "a1", "type": "muse:muse-supervisor", "label": "task:t1",
     "description": "x", "cwd": repo}]}))
PY
python3 "$CAPS_STATUS" < "$CAPS_DIR/sl28-in.json" >"$CAPS_DIR/sl28.out" 2>"$CAPS_DIR/sl28.err"
CAPS_RC28=$?
cat > "$CAPS_DIR/c28.py" <<'PY'
import json, sys
lines = [l for l in open(sys.argv[1], encoding="utf-8").read().replace("\r", "").split("\n") if l.strip()]
assert len(lines) == 1, "expected 1 row, got %d: %r" % (len(lines), lines)
content = json.loads(lines[0]).get("content", "")
assert content, "the row is empty, so the stale-check absence is untested"
assert "2/3" in content, "round 2/3 not shown: %r" % (content,)
for needle in ("FAILED", "exit 1", "passed"):
    assert needle not in content, "round 1's check leaked into round 2: %r" % (content,)
print(content)
PY
CAPS_E28="$(python3 "$CAPS_DIR/c28.py" "$CAPS_DIR/sl28.out" 2>&1)"
CAPS_PY28=$?
if [ "$CAPS_RC28" = 0 ] && [ "$CAPS_PY28" = 0 ]; then
  ok "caps: statusline drops round 1's check when round 2 starts"
else
  bad "caps: statusline drops round 1's check when round 2 starts" "rc=$CAPS_RC28 $CAPS_E28"
fi

# 29. An empty or unsubstituted --project falls back to the cwd repo.
# CLAUDE_PROJECT_DIR is unset so the fallback reaches the cwd deterministically.
CAPS_REPO29="$CAPS_DIR/repo29"; caps_mkrepo "$CAPS_REPO29"
mkdir -p "$CAPS_REPO29/.muse-fleet"
printf '%s\n' '{"event":"verdict","task":"tq","max_rounds":2,"verdict":"accept","rounds_used":1,"verified":true}' > "$CAPS_REPO29/.muse-fleet/events.jsonl"
(cd "$CAPS_REPO29" && env -u CLAUDE_PROJECT_DIR python3 "$CAPS_MON" --once --project "" >"$CAPS_DIR/mon29a.out" 2>"$CAPS_DIR/mon29a.err")
CAPS_RC29A=$?
(cd "$CAPS_REPO29" && env -u CLAUDE_PROJECT_DIR python3 "$CAPS_MON" --once --project '${CLAUDE_PROJECT_DIR}' >"$CAPS_DIR/mon29b.out" 2>"$CAPS_DIR/mon29b.err")
CAPS_RC29B=$?
if [ "$CAPS_RC29A" = 0 ] && grep -q tq "$CAPS_DIR/mon29a.out" 2>/dev/null \
  && [ "$CAPS_RC29B" = 0 ] && grep -q tq "$CAPS_DIR/mon29b.out" 2>/dev/null; then
  ok "caps: monitor falls back to the cwd repo when --project is empty or unsubstituted"
else
  bad "caps: monitor falls back to the cwd repo when --project is empty or unsubstituted" \
    "rc=$CAPS_RC29A/$CAPS_RC29B a=[$(cat "$CAPS_DIR/mon29a.out" 2>/dev/null | head -2)] b=[$(cat "$CAPS_DIR/mon29b.out" 2>/dev/null | head -2)]"
fi

# 30. Outside any repo the monitor prints one diagnostic line to stdout and
# exits 0, with and without --once. The rev-parse guard proves the directory
# is repo-less, without which the diagnostic path is untested; the ceiling
# keeps git from walking past the scratch dir. The non---once run goes
# through a subprocess with a timeout so a regression that enters follow()
# fails instead of hanging the suite.
CAPS_NOREPO="$CAPS_DIR/norepo/deep"; mkdir -p "$CAPS_NOREPO"
if git -C "$CAPS_NOREPO" rev-parse --git-dir >/dev/null 2>&1; then
  bad "caps: monitor outside a repo prints one diagnostic line and exits 0" "the directory is inside a repo so the diagnostic is untested"
else
  CAPS_CEIL="$(native_path "$CAPS_DIR/norepo")"
  (cd "$CAPS_NOREPO" && env -u CLAUDE_PROJECT_DIR GIT_CEILING_DIRECTORIES="$CAPS_CEIL" python3 "$CAPS_MON" --once --project "" \
    >"$CAPS_DIR/mon30a.out" 2>"$CAPS_DIR/mon30a.err")
  CAPS_RC30A=$?
  cat > "$CAPS_DIR/c30run.py" <<'PY'
import subprocess, sys
mon, cwd, ceil, outp, errp, rcp = sys.argv[1:7]
import os
env = dict(os.environ)
env["GIT_CEILING_DIRECTORIES"] = ceil
env.pop("CLAUDE_PROJECT_DIR", None)
proc = subprocess.Popen([sys.executable, mon, "--project", ""], cwd=cwd, env=env,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    out, err = proc.communicate(timeout=20)
except subprocess.TimeoutExpired:
    proc.kill()
    out, err = proc.communicate()
    print("the monitor without --once did not exit within 20s outside a repo")
    sys.exit(1)
open(outp, "wb").write(out)
open(errp, "wb").write(err)
open(rcp, "w").write(str(proc.returncode))
PY
  python3 "$CAPS_DIR/c30run.py" "$CAPS_MON" "$CAPS_NOREPO" "$CAPS_CEIL" "$CAPS_DIR/mon30b.out" "$CAPS_DIR/mon30b.err" "$CAPS_DIR/mon30b.rc" \
    >"$CAPS_DIR/mon30b.drv" 2>&1
  CAPS_RC30B=$?
  CAPS_RC30BV=$(tr -d '\r ' < "$CAPS_DIR/mon30b.rc" 2>/dev/null)
  cat > "$CAPS_DIR/c30.py" <<'PY'
import sys
lines = [l for l in open(sys.argv[1], encoding="utf-8").read().replace("\r", "").split("\n") if l.strip()]
assert sys.argv[3] == "0", "rc=%s for %s" % (sys.argv[3], sys.argv[4])
assert len(lines) == 1, "expected exactly 1 line for %s, got %r" % (sys.argv[4], lines)
assert "Traceback" not in open(sys.argv[2], encoding="utf-8").read(), "traceback on stderr for %s" % (sys.argv[4],)
print(lines[0])
PY
  CAPS_E30A="$(python3 "$CAPS_DIR/c30.py" "$CAPS_DIR/mon30a.out" "$CAPS_DIR/mon30a.err" "$CAPS_RC30A" --once 2>&1)"
  CAPS_PY30A=$?
  if [ "$CAPS_RC30B" = 0 ] && [ "$CAPS_RC30BV" = 0 ]; then
    CAPS_E30B="$(python3 "$CAPS_DIR/c30.py" "$CAPS_DIR/mon30b.out" "$CAPS_DIR/mon30b.err" "$CAPS_RC30BV" follow 2>&1)"
    CAPS_PY30B=$?
  else
    CAPS_E30B="the follow-mode driver failed: $(cat "$CAPS_DIR/mon30b.drv" 2>/dev/null | head -2)"
    CAPS_PY30B=1
  fi
  if [ "$CAPS_PY30A" = 0 ] && [ "$CAPS_PY30B" = 0 ]; then
    ok "caps: monitor outside a repo prints one diagnostic line and exits 0"
  else
    bad "caps: monitor outside a repo prints one diagnostic line and exits 0" "once=[$CAPS_E30A] follow=[$CAPS_E30B]"
  fi
fi

# 31. A multi-line reason collapses to one bounded line per event: the
# fixture mixes CR, LF and blank lines, and the long reason must truncate
# with an ellipsis instead of spilling a second notification. The input
# assertions prove the file held both events before absence is asserted.
python3 - "$CAPS_DIR/mon31.jsonl" <<'PY'
import json, sys
evs = [
    {"event": "round_finished", "task": "ta", "round": 1, "max_rounds": 2,
     "status": "completed", "harvest_error": "alpha\r\nbeta\n\n  gamma  \r"},
    {"event": "round_finished", "task": "tb", "round": 1, "max_rounds": 2,
     "status": "completed", "harvest_error": "x" * 5000 + "\nTAILMARK"},
]
with open(sys.argv[1], "w", encoding="utf-8", newline="\n") as fh:
    for e in evs:
        fh.write(json.dumps(e) + "\n")
PY
python3 "$CAPS_MON" --once --file "$CAPS_DIR/mon31.jsonl" >"$CAPS_DIR/mon31.out" 2>"$CAPS_DIR/mon31.err"
cat > "$CAPS_DIR/c31.py" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8", newline="").read()
assert src.count("\n") == 2, \
    "event file does not hold 2 lines, so the two-line assertion is untested: %r" % (src[-60:],)
assert "TAILMARK" in src, \
    "TAILMARK missing from the event file, so the truncation assertion is untested"
raw = open(sys.argv[2], encoding="utf-8", newline="").read()
text = raw.replace("\r\n", "\n")
assert text.endswith("\n"), "stdout is not newline-terminated: %r" % (raw[-20:] if raw else raw,)
lines = text[:-1].split("\n")
assert len(lines) == 2, "expected exactly 2 lines in total, got %d: %r" % (len(lines), lines)
a, b = lines
assert "\r" not in a and "\r" not in b, "carriage return in monitor output: %r" % (lines,)
assert len(a) <= 300 and len(b) <= 300, \
    "line longer than 300 chars: %d, %d" % (len(a), len(b))
assert "harvest failed" in a, "%r does not report the harvest failure" % (a,)
assert "alpha | beta | gamma" in a, "%r did not collapse the multi-line reason" % (a,)
assert "harvest failed" in b, "%r does not report the harvest failure" % (b,)
assert "TAILMARK" not in b, "the long reason was not truncated: the tail leaked into %r" % (b[-40:],)
assert b.endswith("..."), "truncated line does not end with ...: %r" % (b[-20:],)
print("multi-line events collapse to one bounded line each")
PY
CAPS_E31="$(python3 "$CAPS_DIR/c31.py" "$CAPS_DIR/mon31.jsonl" "$CAPS_DIR/mon31.out" 2>&1)"
CAPS_PY31=$?
if [ "$CAPS_PY31" = 0 ]; then
  ok "caps: monitor collapses a multi-line event to one bounded line"
else
  bad "caps: monitor collapses a multi-line event to one bounded line" "$CAPS_E31"
fi

unset -f caps_py caps_jget caps_mkrepo caps_bg caps_gone caps_stop 2>/dev/null || true
if [ "$CAPS_STANDALONE" = 1 ]; then
  printf 'caps: %d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]; CAPS_RC=$?
  # Standalone mode owns $LAB, so remove it; sourced mode must leave LAB alone.
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
  exit "$CAPS_RC"
fi
