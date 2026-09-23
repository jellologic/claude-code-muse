# shellcheck shell=bash
# Issue #37: bytes a worker or a check writes, prompts muse's option parser or argv
# limit would eat, and exceptions that used to leave stdout without its one JSON object.
# Sourced by scripts/validate.sh; also runs standalone.
BY_STANDALONE=0
if ! declare -F ok >/dev/null 2>&1; then
  BY_STANDALONE=1
  set -uo pipefail
  export PYTHONUTF8=1
  native_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
  shell_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi; }
  SKILL="$(native_path "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)")"
  LAB="$(mktemp -d "${TMPDIR:-/tmp}/musebytes.XXXXXX")"
  # Every path below is built from LAB and the next lines rm -rf under it.
  if [ -z "$LAB" ] || [ ! -d "$LAB" ]; then echo "no scratch dir" >&2; exit 1; fi
  LAB="$(native_path "$LAB")"
  PASS=0; FAIL=0
  ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
  bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && echo "        $2"; }
fi
BY_TASK="$SKILL/scripts/muse_task.py"
BY_CORE="$SKILL/scripts/muse_core.py"
BY="$LAB/v_bytes37"; rm -rf "$BY"; mkdir -p "$BY/bin" "$BY/musedata"

# Parses its argv the way muse 1.3.0 does (measured with --provider echo): a prompt after
# `--` or in --prompt-file is taken as-is, and a bare positional starting with '-' is
# refused as "unknown option". It records what it received, then writes a non-UTF-8 byte.
cat > "$BY/bin/muse" <<'STUB'
#!/usr/bin/env bash
wt=""; pf=""; prev=""; after=0; have=0; inline=""
for a in "$@"; do
  if [ "$after" = 1 ] && [ "$have" = 0 ]; then inline="$a"; have=1; fi
  [ "$prev" = "--worktree-existing" ] && wt="$a"
  [ "$prev" = "--prompt-file" ] && pf="$a"
  [ "$a" = "--" ] && [ "$after" = 0 ] && after=1
  prev="$a"
done
echo call >> "$BY_DIR/calls.log"
if [ -n "$pf" ]; then
  cp "$pf" "$BY_DIR/seen_prompt.txt"; echo file > "$BY_DIR/seen_via.txt"
elif [ "$have" = 1 ]; then
  printf '%s' "$inline" > "$BY_DIR/seen_prompt.txt"; echo inline > "$BY_DIR/seen_via.txt"
else
  last="${!#}"
  case "$last" in -*) echo "unknown option $last" >&2; echo refused > "$BY_DIR/seen_via.txt"; exit 2;; esac
  printf '%s' "$last" > "$BY_DIR/seen_prompt.txt"; echo bare > "$BY_DIR/seen_via.txt"
fi
[ -n "$wt" ] && printf 'caf\xe9\n' > "$wt/x.txt"
printf '{"payload":{"kind":"run_terminal","terminal":"completed","text":"ok"}}\n'
STUB
chmod +x "$BY/bin/muse"
# Native Windows python finds only PATHEXT files, and CreateProcess needs the .cmd.
if command -v cygpath >/dev/null 2>&1; then
  printf '@echo off\r\n"%s" "%s" %%*\r\nexit /b %%ERRORLEVEL%%\r\n' \
    "$(native_path "$(command -v bash)")" "$(native_path "$BY/bin/muse")" > "$BY/bin/muse.cmd"
fi
# The absolute interpreter: verify runs its command under cmd.exe on Windows, where a
# bare `python3` may not resolve.
BY_PYEXE="$(python3 -c 'import sys; print(sys.executable)')"

by_py() {
  env -u CLAUDE_PLUGIN_OPTION_MAX_ROUNDS PATH="$(shell_path "$BY/bin"):$PATH" \
    MUSE_DATA_DIR="$BY/musedata" BY_DIR="$BY" python3 "$@"
}
by_repo() {
  rm -rf "$1"; mkdir -p "$1"; git init -q -b main "$1"; echo a > "$1/a.txt"
  git -C "$1" add -A; git -C "$1" -c user.email=t@l -c user.name=t commit -qm init
}
by_run() {  # by_run <repo> <id> [run args...] -> JSON on stdout
  local repo="$1" id="$2"; shift 2
  (cd "$repo" && by_py "$BY_TASK" run --id "$id" --repo "$repo" --out "$repo/.muse-fleet/tasks" \
     --worktree-root "$repo.wt" --model stub-model --no-secret-scan "$@" 2>/dev/null)
}
by_do() {  # by_do <repo> <subcommand> <id> [args...] -> JSON on stdout
  local repo="$1" sub="$2" id="$3"; shift 3
  (cd "$repo" && by_py "$BY_TASK" "$sub" --id "$id" --out "$repo/.muse-fleet/tasks" "$@" 2>/dev/null)
}

# 1. The issue's reproduction: the worker writes caf\xe9, --max-rounds 1, then 1 run and
#    2 revises. A crash before save_state un-counted the round and let muse run again.
R="$BY/r1"; by_repo "$R"; rm -f "$BY/calls.log"
by_run "$R" c --prompt noop --max-rounds 1 > "$BY/run1.json"
by_do "$R" revise c --feedback more > "$BY/rev1.json"
by_do "$R" revise c --feedback more > "$BY/rev2.json"
python3 - "$BY" "$R/.muse-fleet/tasks/c/state.json" <<'PY' \
  && ok "bytes: a worker writing caf\\xe9 under --max-rounds 1: run + 2 revises = 1 muse call, 1 round, max_rounds_exhausted" \
  || bad "bytes: a non-UTF-8 worker file broke the round count" "$(head -c 400 "$BY/run1.json")"
import json, os, sys
d = sys.argv[1]
run = json.load(open(os.path.join(d, "run1.json"), encoding="utf-8"))
assert run.get("status") == "completed" and run.get("files_changed") == ["x.txt"], run
st = json.load(open(sys.argv[2], encoding="utf-8"))
assert len(st["rounds"]) == 1, st["rounds"]
assert sum(1 for _ in open(os.path.join(d, "calls.log"))) == 1
for f in ("rev1.json", "rev2.json"):
    assert json.load(open(os.path.join(d, f), encoding="utf-8"))["status"] == "max_rounds_exhausted", f
PY

# 2. A check whose output is not UTF-8 is still a check that passed.
printf 'import sys\nsys.stdout.buffer.write(b"ok \\xe9\\n")\nsys.stderr.buffer.write(b"\\xff\\x81\\n")\n' > "$BY/emit.py"
by_do "$R" verify c --command "\"$BY_PYEXE\" \"$BY/emit.py\"" > "$BY/ver.json"; BY_RC=$?
python3 - "$BY/ver.json" "$BY_RC" "$R/.muse-fleet/tasks/c/state.json" <<'PY' \
  && ok "bytes: verify on a command printing non-UTF-8 bytes records a pass" \
  || bad "bytes: verify crashed or failed on non-UTF-8 output" "$(head -c 400 "$BY/ver.json")"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert sys.argv[2] == "0" and d["status"] == "verified" and d["passed"] is True, d
assert d["stdout_tail"].startswith("ok "), d
assert len(json.load(open(sys.argv[3], encoding="utf-8"))["verifications"]) == 1
PY

# 3. A prompt beyond ARG_MAX (Linux: 128 KiB for one argument).
R="$BY/r3"; by_repo "$R"
by_run "$R" g --prompt noop > /dev/null
python3 -c "import sys; open(sys.argv[1], 'w').write('y' * 1300000 + 'END-OF-FEEDBACK')" "$BY/big.txt"
by_do "$R" revise g --feedback-file "$BY/big.txt" > "$BY/big.json"
python3 - "$BY" "$R/.muse-fleet/tasks/g/state.json" <<'PY' \
  && ok "bytes: a 1.3MB --feedback-file reaches muse whole and returns round JSON" \
  || bad "bytes: a 1.3MB prompt crashed the round" "$(head -c 400 "$BY/big.json")"
import json, os, sys
d = sys.argv[1]
out = json.load(open(os.path.join(d, "big.json"), encoding="utf-8"))
assert out["status"] == "completed", out
p = open(os.path.join(d, "seen_prompt.txt"), encoding="utf-8").read()
assert len(p) > 1300000 and "END-OF-FEEDBACK" in p, len(p)
assert len(json.load(open(sys.argv[2], encoding="utf-8"))["rounds"]) == 2
PY

# 4. A markdown bullet as the brief. Real muse answers "unknown option - fix it".
R="$BY/r4"; by_repo "$R"; rm -f "$BY/seen_prompt.txt" "$BY/seen_via.txt"
by_run "$R" dash --prompt "- fix it" > "$BY/dash.json"
python3 - "$BY" <<'PY' \
  && ok "bytes: a brief of '- fix it' arrives as the prompt, not as an option" \
  || bad "bytes: a brief starting with '-' was parsed as an option" "$(cat "$BY/seen_via.txt" 2>/dev/null)"
import json, os, sys
d = sys.argv[1]
assert open(os.path.join(d, "seen_prompt.txt"), encoding="utf-8").read() == "- fix it"
assert json.load(open(os.path.join(d, "dash.json"), encoding="utf-8"))["status"] == "completed"
PY

# 5. The round is on disk before anything after the worker can throw.
python3 - "$BY_TASK" "$BY/r4/.muse-fleet/tasks/dash" 2>"$BY/c5.err" <<'PY' \
  && ok "bytes: a round is recorded before fingerprinting; a fingerprint error neither raises nor un-counts it" \
  || bad "bytes: an exception after the worker ran left the round unrecorded" "$(tail -3 "$BY/c5.err")"
import importlib.util, json, pathlib, sys
spec = importlib.util.spec_from_file_location("mt", sys.argv[1])
mt = importlib.util.module_from_spec(spec); spec.loader.exec_module(mt)
tdir = pathlib.Path(sys.argv[2])
rounds = lambda: json.loads((tdir / "state.json").read_text(encoding="utf-8"))["rounds"]
assert len(rounds()) == 1
mt.core.run_muse = lambda *a, **k: {"status": "completed", "reason": None, "model_actual": None,
                                    "text": "", "elapsed_s": 0.0, "exit_code": 0, "stderr_tail": ""}
def err(*a, **k): raise RuntimeError("fingerprint exploded")
mt.core.patch_fingerprint = err
st = json.loads((tdir / "state.json").read_text(encoding="utf-8"))
mt.do_round(st, tdir, "p", None, "revision", resumed=False)   # must not raise
assert len(rounds()) == 2 and rounds()[-1].get("patch_fingerprint") is None, rounds()[-1]
def intr(*a, **k): raise KeyboardInterrupt
mt.core.patch_fingerprint = intr
st = json.loads((tdir / "state.json").read_text(encoding="utf-8"))
try:
    mt.do_round(st, tdir, "p", None, "revision", resumed=False)
except KeyboardInterrupt:
    pass
assert len(rounds()) == 3, len(rounds())
PY

# 6. A muse that cannot be started (E2BIG, ENOENT, EACCES) is a failed round, not a raise.
python3 - "$BY_CORE" "$BY" <<'PY' \
  && ok "bytes: a muse that cannot be spawned comes back as status spawn_failed" \
  || bad "bytes: a spawn failure raised out of run_muse"
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
d = pathlib.Path(sys.argv[2]) / "spawn"; d.mkdir(parents=True, exist_ok=True)
r = mc.run_muse([str(d / "no-such-muse")], "p", d, d / "events.jsonl", d / "stderr.log", 10)
assert r["status"] == "spawn_failed" and r["reason"] and r["exit_code"] is None, r
PY

# 7. Every subcommand's top level: an unexpected exception is JSON, not a traceback.
R="$BY/r7"; by_repo "$R"; mkdir -p "$R/.muse-fleet/tasks/h"
printf '{"id": "h"}' > "$R/.muse-fleet/tasks/h/state.json"
BY_ALL=1; BY_WHY=""
by_err() {  # by_err <subcommand> [args...]: stdout must be one {"status":"error"} object
  by_do "$R" "$1" h "${@:2}" > "$BY/e_$1.json"; local rc=$?
  python3 - "$BY/e_$1.json" "$rc" <<'PY2' || { BY_ALL=0; BY_WHY="$BY_WHY $1"; }
import json, sys
t = open(sys.argv[1], encoding="utf-8").read()
assert t.strip(), "stdout empty"
assert sys.argv[2] != "0"
assert json.loads(t)["status"] == "error"
PY2
}
by_err revise --feedback x
by_err verify --command true
by_err finish --verdict reject
by_err cleanup
[ "$BY_ALL" = 1 ] \
  && ok "bytes: revise/verify/finish/cleanup on unusable state print {\"status\":\"error\"} JSON" \
  || bad "bytes: a subcommand crashed without JSON on stdout" "failed:$BY_WHY"

if [ "$BY_STANDALONE" -eq 1 ]; then
  rm -rf "$LAB"
  exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
fi
