# shellcheck shell=bash
# Interruption and scanning gaps (issue #52). A signal landing after run_muse
# returns, errors misreported as signals, a false fleet message, a slow file
# listing, silent preflight skips and an unscanned read-only ask. Driven through
# the real scripts with a stub muse and the tests/interrupt_driver.py fault
# injector, never source text.
IT_STANDALONE=0
if ! declare -F ok >/dev/null 2>&1; then
  IT_STANDALONE=1
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

IT_BASE="$LAB/v_interrupt"
IT_BIN="$IT_BASE/bin"
IT_REPO="$IT_BASE/repo"
IT_OUT="$IT_BASE/out"
IT_WT="$IT_BASE/wt"
IT_LOG="$IT_BASE/stub.log"
IT_DATA="$IT_BASE/data"
rm -rf "$IT_BASE"; mkdir -p "$IT_BIN" "$IT_OUT" "$IT_WT" "$IT_DATA"
: > "$IT_LOG"
cat > "$IT_BIN/muse" <<'STUB'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then echo "muse 0.0.0"; exit 0; fi
wt=""; prev=""
for a in "$@"; do
  [ "$prev" = "--workspace" ] && wt="$a"
  prev="$a"
done
echo "$$" >> "$IT_STUB_LOG"
sleep "${IT_STUB_SLEEP:-0}"
: > "${wt:-.}/late.txt"
printf '{"payload":{"kind":"run_terminal","terminal":"completed","text":"ok"}}\n'
STUB
chmod +x "$IT_BIN/muse"
. "$(dirname "${BASH_SOURCE[0]}")/lib_stub.sh"
win_cmd_shim "$IT_BIN/muse"
# it_bg <script.py> [args...]: copied from test_signals.sh (sg_bg/sg_term).
# POSIX gets a real external SIGTERM. Windows cannot deliver one to a native
# process (see tests/sig_driver.py), so there the script runs under a driver
# that raises SIGTERM inside it once the trigger file appears.
IT_TRIG="$IT_BASE/term.trigger"
it_bg() {
  rm -f "$IT_TRIG"
  if is_windows; then
    env -u CLAUDE_PLUGIN_OPTION_REFUSE_ON_SECRETS PATH="$IT_PATH" MUSE_DATA_DIR="$IT_DATA" IT_STUB_SLEEP="${IT_STUB_SLEEP:-0}" python3 "$SKILL/tests/sig_driver.py" "$IT_TRIG" "$@" &
  else
    env -u CLAUDE_PLUGIN_OPTION_REFUSE_ON_SECRETS PATH="$IT_PATH" MUSE_DATA_DIR="$IT_DATA" IT_STUB_SLEEP="${IT_STUB_SLEEP:-0}" python3 "$@" &
  fi
  IT_BGPID=$!
}
it_term() {
  if is_windows; then : > "$IT_TRIG"; else kill -TERM "$1" 2>/dev/null; fi
}
git init -q -b main "$IT_REPO"
printf 'x = 1\n' > "$IT_REPO/a.py"
git -C "$IT_REPO" add -A
git -C "$IT_REPO" -c user.email=t@t -c user.name=t commit -qm init
IT_PATH="$(shell_path "$IT_BIN"):$PATH"
export IT_STUB_LOG="$IT_LOG"

it_task() {  # it_task <subcommand> <id> [args...]
  local c="$1" i="$2"; shift 2
  env -u CLAUDE_PLUGIN_OPTION_REFUSE_ON_SECRETS PATH="$IT_PATH" MUSE_DATA_DIR="$IT_DATA" \
    python3 "$SKILL/scripts/muse_task.py" "$c" --id "$i" --out "$IT_OUT" "$@"
}
it_driver() {  # it_driver <mode> <fired-file> <script.py> [args...]
  local m="$1" f="$2"; shift 2
  env -u CLAUDE_PLUGIN_OPTION_REFUSE_ON_SECRETS PATH="$IT_PATH" MUSE_DATA_DIR="$IT_DATA" \
    python3 "$SKILL/tests/interrupt_driver.py" "$m" "$f" "$@"
}
it_json() {  # it_json <stdout-file> -> "count|first_status"
  python3 - "$1" <<'PY'
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
dec = json.JSONDecoder()
i, n, objs = 0, len(raw), []
while True:
  while i < n and raw[i] in " \t\r\n":
    i += 1
  if i >= n:
    break
  o, i = dec.raw_decode(raw, i)
  objs.append(o)
print("%d|%s" % (len(objs), objs[0].get("status", "") if objs else ""))
PY
}
it_state() {  # it_state <id> -> "rounds|last_status|has_marker"
  python3 - "$IT_OUT/$1/state.json" <<'PY'
import json, sys
st = json.load(open(sys.argv[1]))
r = st.get("rounds") or []
print("%d|%s|%s" % (len(r), r[-1].get("status") if r else "", "round_in_flight" in st))
PY
}
it_logcount() { wc -l < "$IT_LOG" | tr -d ' '; }
# 1. A signal after run_muse returns must still leave exactly one interrupted
# round: the window between the return and the append used to leave rounds == []
# with a stale marker, and stdout empty.
IT_STUB_SLEEP=0 it_driver window "$IT_BASE/fired1" "$SKILL/scripts/muse_task.py" run \
  --id itw1 --out "$IT_OUT" --repo "$IT_REPO" --worktree-root "$IT_WT" --model stub-model \
  --no-secret-scan --prompt p >"$IT_BASE/w1.out" 2>"$IT_BASE/w1.err"
IT_RC=$?
if [ -f "$IT_BASE/fired1" ] && [ "$IT_RC" -ne 0 ] \
    && [ "$(it_state itw1)" = "1|interrupted|False" ] \
    && [ "$(it_json "$IT_BASE/w1.out")" = "1|interrupted" ]; then
  ok "interrupt: a signal after run_muse returns records exactly one interrupted round and no marker"
else
  bad "interrupt: a signal after run_muse returns records exactly one interrupted round and no marker" \
    "rc=$IT_RC state=$(it_state itw1 2>/dev/null) json=$(it_json "$IT_BASE/w1.out") fired=$([ -f "$IT_BASE/fired1" ] && echo yes || echo no)"
fi

# 2. A signal during harvest keeps the recorded round (with its muse status),
# clears the marker and still prints the one interrupted object.
IT_STUB_SLEEP=0 it_driver harvest "$IT_BASE/fired2" "$SKILL/scripts/muse_task.py" run \
  --id ith2 --out "$IT_OUT" --repo "$IT_REPO" --worktree-root "$IT_WT" --model stub-model \
  --no-secret-scan --prompt p >"$IT_BASE/w2.out" 2>"$IT_BASE/w2.err"
IT_RC=$?
IT_S2="$(it_state ith2 2>/dev/null)"
if [ -f "$IT_BASE/fired2" ] && [ "$IT_RC" -ne 0 ] \
    && [ "$(printf '%s' "$IT_S2" | cut -d'|' -f1)" = "1" ] \
    && [ "$(printf '%s' "$IT_S2" | cut -d'|' -f3)" = "False" ] \
    && [ "$(it_json "$IT_BASE/w2.out")" = "1|interrupted" ]; then
  ok "interrupt: a signal during harvest keeps one round, clears the marker and prints one interrupted object"
else
  bad "interrupt: a signal during harvest keeps one round, clears the marker and prints one interrupted object" \
    "rc=$IT_RC state=$IT_S2 json=$(it_json "$IT_BASE/w2.out") fired=$([ -f "$IT_BASE/fired2" ] && echo yes || echo no)"
fi

# 3. An OSError before the spawn (here: the events path is a directory, so
# opening it for writing fails on every OS) spent nothing: no new round, and
# main()'s single error object is the only stdout object.
IT_STUB_SLEEP=0 it_task run ite3 --repo "$IT_REPO" --worktree-root "$IT_WT" --model stub-model \
  --no-secret-scan --prompt p >/dev/null 2>&1
IT_RUNRC=$?
IT_N0="$(it_logcount)"
mkdir -p "$IT_OUT/ite3/round-2/events.jsonl"
IT_STUB_SLEEP=0 it_task revise ite3 --feedback x >"$IT_BASE/w3.out" 2>"$IT_BASE/w3.err"
IT_RC=$?
if [ "$IT_RUNRC" -eq 0 ] && [ "$IT_N0" -ge 1 ] && [ "$IT_RC" -ne 0 ] \
    && [ "$(it_logcount)" = "$IT_N0" ] \
    && [ "$(it_json "$IT_BASE/w3.out")" = "1|error" ] \
    && [ "$(it_state ite3)" = "1|completed|False" ]; then
  ok "interrupt: an OSError before spawn is an error, not an interrupted round"
else
  bad "interrupt: an OSError before spawn is an error, not an interrupted round" \
    "runrc=$IT_RUNRC rc=$IT_RC log=$IT_N0/$(it_logcount) state=$(it_state ite3 2>/dev/null) json=$(it_json "$IT_BASE/w3.out")"
fi

# 4. An OSError after the spawn spent a round: one error round is recorded and
# main()'s single error object is the only stdout object.
IT_STUB_SLEEP=0 it_task run itse4 --repo "$IT_REPO" --worktree-root "$IT_WT" --model stub-model \
  --no-secret-scan --prompt p >/dev/null 2>&1
IT_STUB_SLEEP=0 it_driver spawnerr "$IT_BASE/fired4" "$SKILL/scripts/muse_task.py" revise \
  --id itse4 --out "$IT_OUT" --feedback x >"$IT_BASE/w4.out" 2>"$IT_BASE/w4.err"
IT_RC=$?
if [ -f "$IT_BASE/fired4" ] && [ "$IT_RC" -ne 0 ] \
    && [ "$(it_state itse4)" = "2|error|False" ] \
    && [ "$(it_json "$IT_BASE/w4.out")" = "1|error" ]; then
  ok "interrupt: an OSError after spawn records one error round and prints one error object"
else
  bad "interrupt: an OSError after spawn records one error round and prints one error object" \
    "rc=$IT_RC state=$(it_state itse4 2>/dev/null) json=$(it_json "$IT_BASE/w4.out") fired=$([ -f "$IT_BASE/fired4" ] && echo yes || echo no)"
fi

# 5. The fleet KeyboardInterrupt message must say running workers were killed:
# the old "already-started ones finish" is false, the handler SIGKILLs them.
printf '[{"id":"itf5","prompt":"p"}]' > "$IT_BASE/tasks5.json"
IT_N0="$(it_logcount)"
IT_STUB_SLEEP=4 it_bg "$SKILL/scripts/muse_fleet.py" \
  --tasks "$IT_BASE/tasks5.json" --repo "$IT_REPO" --out "$IT_BASE/fleet5-out" \
  --worktree-root "$IT_BASE/fleet5-wt" --model stub-model >/dev/null 2>"$IT_BASE/fleet5.err"
IT_FPID=$IT_BGPID
IT_i=0
while [ "$IT_i" -lt 150 ] && [ "$(it_logcount)" = "$IT_N0" ]; do sleep 0.1; IT_i=$((IT_i+1)); done
if [ "$(it_logcount)" -gt "$IT_N0" ]; then
  it_term "$IT_FPID"
  wait "$IT_FPID" 2>/dev/null
  if grep -q "interrupted" "$IT_BASE/fleet5.err" && grep -q "killed" "$IT_BASE/fleet5.err" \
      && ! grep -q "already-started ones finish" "$IT_BASE/fleet5.err"; then
    ok "interrupt: an interrupted fleet says running workers were killed, not that they finish"
  else
    bad "interrupt: an interrupted fleet says running workers were killed, not that they finish" \
      "err=$(cat "$IT_BASE/fleet5.err")"
  fi
else
  bad "interrupt: an interrupted fleet says running workers were killed, not that they finish" \
    "worker never started: $(tail -3 "$IT_BASE/fleet5.err")"
fi
pkill -f "$IT_BIN/muse" 2>/dev/null || true

# 6. A 30s-slow `git ls-files` refuses the task before anything is spawned and
# drops the worktree it had just created. The stub-log count proves the absence:
# it is non-empty from the checks above, and unchanged after this run.
IT_N0="$(it_logcount)"
IT_STUB_SLEEP=0 it_driver lsfiles "$IT_BASE/fired6" "$SKILL/scripts/muse_task.py" run \
  --id itl6 --out "$IT_OUT" --repo "$IT_REPO" --worktree-root "$IT_BASE/wt6" --model stub-model \
  --prompt p >"$IT_BASE/w6.out" 2>"$IT_BASE/w6.err"
IT_RC=$?
if [ -f "$IT_BASE/fired6" ] && [ "$IT_N0" -ge 1 ] && [ "$IT_RC" -eq 1 ] \
    && [ "$(it_json "$IT_BASE/w6.out")" = "1|refused" ] \
    && grep -q "timed out" "$IT_BASE/w6.out" \
    && [ "$(it_logcount)" = "$IT_N0" ] \
    && { [ ! -e "$IT_BASE/wt6" ] || [ -z "$(ls -A "$IT_BASE/wt6")" ]; }; then
  ok "interrupt: a timed-out file listing refuses the task and leaves no worktree"
else
  bad "interrupt: a timed-out file listing refuses the task and leaves no worktree" \
    "rc=$IT_RC log=$IT_N0/$(it_logcount) json=$(it_json "$IT_BASE/w6.out") wt=$(ls -A "$IT_BASE/wt6" 2>/dev/null) fired=$([ -f "$IT_BASE/fired6" ] && echo yes || echo no)"
fi

# 7. The same slow listing in a fleet records the task as refused, not crashed.
printf '[{"id":"itf7","prompt":"p"}]' > "$IT_BASE/tasks7.json"
IT_N0="$(it_logcount)"
IT_STUB_SLEEP=0 it_driver lsfiles "$IT_BASE/fired7" "$SKILL/scripts/muse_fleet.py" \
  --tasks "$IT_BASE/tasks7.json" --repo "$IT_REPO" --out "$IT_BASE/fleet7-out" \
  --worktree-root "$IT_BASE/fleet7-wt" --model stub-model >/dev/null 2>"$IT_BASE/fleet7.err"
IT_F7ST="$(python3 -c 'import json,sys
rep = json.load(open(sys.argv[1]))
ts = [t for t in rep.get("tasks", []) if t.get("id") == "itf7"]
print(ts[0].get("status") if ts else "")' "$IT_BASE/fleet7-out/report.json" 2>/dev/null)"
if [ -f "$IT_BASE/fired7" ] && [ "$IT_N0" -ge 1 ] \
    && [ "$IT_F7ST" = "refused" ] && [ "$(it_logcount)" = "$IT_N0" ]; then
  ok "interrupt: a timed-out file listing refuses the fleet task instead of crashing it"
else
  bad "interrupt: a timed-out file listing refuses the fleet task instead of crashing it" \
    "status=$IT_F7ST log=$IT_N0/$(it_logcount) fired=$([ -f "$IT_BASE/fired7" ] && echo yes || echo no)"
fi
# 8. With no python3 on PATH the catalog check is skipped: that must be said in
# one line, under the same header, instead of passing silently.
IT_P8="$IT_BASE/no-python"; IT_CFG8="$IT_BASE/cfg8"
rm -rf "$IT_P8" "$IT_CFG8"; mkdir -p "$IT_P8" "$IT_CFG8"
IT_TESTED="$(sed -n 's/^MUSE_TESTED_VERSION = "\(.*\)"/\1/p' "$SKILL/scripts/muse_core.py")"
printf '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "muse %s"; else echo "muse %s"; fi\nexit 0\n' \
  "$IT_TESTED" "$IT_TESTED" > "$IT_P8/muse"
chmod +x "$IT_P8/muse"
printf '{"k":"v"}' > "$IT_CFG8/auth.json"
if is_windows; then
  IT_P8PATH="$(shell_path "$IT_P8"):/usr/bin:/bin"
else
  for IT_t in grep sed head tail tr cat; do
    ln -s "$(command -v "$IT_t")" "$IT_P8/$IT_t"
  done
  IT_P8PATH="$IT_P8"
fi
hash -r
if PATH="$IT_P8PATH" command -v python3 >/dev/null 2>&1; then
  bad "interrupt: preflight says in one line that python3 is missing" \
    "python3 unexpectedly resolvable with PATH=$IT_P8PATH"
else
  IT_P8OUT="$(PATH="$IT_P8PATH" MUSE_CONFIG_DIR="$IT_CFG8" MUSE_DATA_DIR="$IT_BASE/data8" \
    CLAUDE_PLUGIN_ROOT="$SKILL" "$BASH" "$SKILL/hooks/preflight.sh" 2>/dev/null)"
  IT_P8RC=$?
  IT_P8N="$(printf '%s\n' "$IT_P8OUT" | grep "python3" | grep -c "catalog")"
  if [ "$IT_P8RC" -eq 0 ] && [ "$IT_P8N" = "1" ]; then
    ok "interrupt: preflight says in one line that python3 is missing"
  else
    bad "interrupt: preflight says in one line that python3 is missing" \
      "rc=$IT_P8RC matches=$IT_P8N out='$IT_P8OUT'"
  fi
fi

# 9. With python3 present but muse_core.py unloadable, the skipped catalog check
# must likewise be said in one line naming the file.
rm -rf "$IT_BASE/fakeroot"; mkdir -p "$IT_BASE/fakeroot/scripts"
printf 'raise SystemExit(3)\n' > "$IT_BASE/fakeroot/scripts/muse_core.py"
IT_P9OUT="$(PATH="$IT_PATH" MUSE_CONFIG_DIR="$IT_CFG8" MUSE_DATA_DIR="$IT_BASE/data9" \
  CLAUDE_PLUGIN_ROOT="$IT_BASE/fakeroot" bash "$SKILL/hooks/preflight.sh" 2>/dev/null)"
IT_P9RC=$?
IT_P9N="$(printf '%s\n' "$IT_P9OUT" | grep "muse_core.py" | grep -c "catalog")"
if [ "$IT_P9RC" -eq 0 ] && [ "$IT_P9N" = "1" ]; then
  ok "interrupt: preflight says in one line that muse_core.py could not be loaded"
else
  bad "interrupt: preflight says in one line that muse_core.py could not be loaded" \
    "rc=$IT_P9RC matches=$IT_P9N out='$IT_P9OUT'"
fi

# 10-12 share one repo holding a tracked key. The header is assembled at runtime
# so this file itself contains no matching token.
IT_ASKREPO="$IT_BASE/askrepo"; mkdir -p "$IT_ASKREPO"
python3 - "$IT_ASKREPO/key.pem" <<'PY'
import sys
open(sys.argv[1], "w").write("-----BEGIN RSA " + "PRIVATE KEY-----\nfake fixture, not a key\n")
PY
git init -q -b main "$IT_ASKREPO" 2>/dev/null || git init -q "$IT_ASKREPO"
git -C "$IT_ASKREPO" add -A
git -C "$IT_ASKREPO" -c user.email=t@t -c user.name=t commit -qm init
it_ask() {  # it_ask [flags...] <prompt>, run inside $IT_ASKREPO by the caller
  env -u CLAUDE_PLUGIN_OPTION_REFUSE_ON_SECRETS PATH="$IT_PATH" \
    CLAUDE_PLUGIN_DATA="$IT_BASE/plugdata" bash "$SKILL/scripts/muse_ask.sh" --model stub-model "$@"
}

# 10. Read-only ask over a tree holding a key refuses without spawning: a
# read-only worker can still read the secret and send it to the contributor tier.
IT_N0="$(it_logcount)"
( cd "$IT_ASKREPO" && it_ask "read-only question" ) >"$IT_BASE/a10.out" 2>"$IT_BASE/a10.err"
IT_RC=$?
if [ "$IT_N0" -ge 1 ] && [ "$IT_RC" -eq 1 ] && grep -q "refused" "$IT_BASE/a10.err" \
    && [ "$(it_logcount)" = "$IT_N0" ]; then
  ok "interrupt: read-only muse-ask over a tree holding a key refuses"
else
  bad "interrupt: read-only muse-ask over a tree holding a key refuses" \
    "rc=$IT_RC log=$IT_N0/$(it_logcount) err=$(cat "$IT_BASE/a10.err")"
fi

# 11. Control: with the scan skipped the same question reaches the worker, which
# is what gives check 10's empty log its meaning.
IT_N0="$(it_logcount)"
( cd "$IT_ASKREPO" && it_ask --no-secret-scan "read-only question" ) >"$IT_BASE/a11.out" 2>"$IT_BASE/a11.err"
IT_RC=$?
if [ "$IT_RC" -eq 0 ] && [ "$(it_logcount)" -gt "$IT_N0" ]; then
  ok "interrupt: read-only muse-ask with --no-secret-scan reaches the worker"
else
  bad "interrupt: read-only muse-ask with --no-secret-scan reaches the worker" \
    "rc=$IT_RC log=$IT_N0/$(it_logcount) err=$(cat "$IT_BASE/a11.err")"
fi

# 12. With --allow-secrets the scan still runs and reports, but does not refuse.
IT_N0="$(it_logcount)"
( cd "$IT_ASKREPO" && it_ask --allow-secrets "read-only question" ) >"$IT_BASE/a12.out" 2>"$IT_BASE/a12.err"
IT_RC=$?
if [ "$IT_RC" -eq 0 ] && [ "$(it_logcount)" -gt "$IT_N0" ] \
    && grep -q "secret scan" "$IT_BASE/a12.err"; then
  ok "interrupt: read-only muse-ask with --allow-secrets scans, reports and proceeds"
else
  bad "interrupt: read-only muse-ask with --allow-secrets scans, reports and proceeds" \
    "rc=$IT_RC log=$IT_N0/$(it_logcount) err=$(cat "$IT_BASE/a12.err")"
fi

unset -f it_task it_driver it_json it_state it_logcount it_bg it_term it_ask
pkill -f "$IT_BIN/muse" 2>/dev/null || true
if [ "$IT_STANDALONE" -eq 1 ]; then
  rm -rf "$LAB"
  exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
fi


