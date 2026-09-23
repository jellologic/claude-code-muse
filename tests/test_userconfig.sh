#!/usr/bin/env bash
# userConfig end-to-end: the five plugin options reach every driver, refuse loudly
# when set-but-invalid, and change nothing when unset. Sourced by validate.sh;
# also runnable alone with `bash tests/test_userconfig.sh`.
UC_STANDALONE=0
if ! declare -F ok >/dev/null 2>&1; then
  UC_STANDALONE=1
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
  LAB="$(native_path "$(mktemp -d "${TMPDIR:-/tmp}/muse-uc.XXXXXX")")"
  if [ -z "${LAB:-}" ] || [ ! -d "$LAB" ]; then echo "no scratch dir" >&2; exit 1; fi
  PASS=0; FAIL=0; SKIP=0
  ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
  bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && echo "        $2"; }
  skip() { local n="$1"; shift; SKIP=$((SKIP+n)); printf '  SKIP  %s\n' "$*"; }
fi

if [ -z "${LAB:-}" ] || [ ! -d "${LAB:-}" ]; then
  echo "userconfig: refusing to run without a scratch dir" >&2
  if [ "$UC_STANDALONE" = 1 ]; then exit 1; else return 1; fi
fi

UC_TASK="$SKILL/scripts/muse_task.py"
UC_FLEET="$SKILL/scripts/muse_fleet.py"
UC_CORE="$SKILL/scripts/muse_core.py"
UC_ASK="$SKILL/scripts/muse_ask.sh"
UC_DOC="$SKILL/scripts/muse_doctor.py"
UC_DIR="$LAB/v_userconfig"
UC_N=0
rm -rf "$UC_DIR"; mkdir -p "$UC_DIR/bin" "$UC_DIR/data" "$UC_DIR/askdata" "$UC_DIR/other"
UC_DATA="$UC_DIR/data"
UC_CAT="$UC_DIR/nocat/*.json"

# A muse that logs its argv and immediately completes. A non-empty log proves the
# worker started; its content proves which flags it was started with.
cat > "$UC_DIR/bin/muse" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "muse 1.3.0"; exit 0; fi
printf '%s\n' "$@" >> "$UC_STUB_LOG"
printf '{"payload":{"kind":"run_terminal","terminal":"completed","text":"ok"}}\n'
STUB
chmod +x "$UC_DIR/bin/muse"
# Native python on Windows cannot execute the extensionless bash stub: shutil.which
# honours PATHEXT (so it needs muse.cmd) and CreateProcess never consults PATHEXT at
# all, so even the .cmd is unreachable under the bare name unless run_muse resolves it
# via which() first. Same shape as validate.sh's make_muse_stub.
if command -v cygpath >/dev/null 2>&1; then
  printf '@echo off\r\n"%s" "%s" %%*\r\nexit /b %%ERRORLEVEL%%\r\n' \
    "$(native_path "$(command -v bash)")" \
    "$(native_path "$UC_DIR/bin/muse")" > "$UC_DIR/bin/muse.cmd"
fi
UC_PATH="$(shell_path "$UC_DIR/bin"):$PATH"

uc_mkrepo() {  # uc_mkrepo <dir> -- calc.py tracked, clean tree
  rm -rf "$1"; mkdir -p "$1"; git init -q -b main "$1"
  printf 'def add(a,b):\n    return a+b\n' > "$1/calc.py"
  git -C "$1" add -A
  git -C "$1" -c user.email=t@l -c user.name=t commit -qm init
}

# Every invocation goes through here: all five CLAUDE_PLUGIN_OPTION_* vars are
# unset first, then the ones under test are set, and the model catalog points
# into the lab so no host state leaks in.
uc_run() {  # uc_run [VAR=val ...] -- cmd [args ...]
  local UC_A=()
  while [ "$1" != "--" ]; do UC_A+=("$1"); shift; done
  shift
  env -u CLAUDE_PLUGIN_OPTION_DEFAULT_EFFORT \
      -u CLAUDE_PLUGIN_OPTION_MAX_ROUNDS \
      -u CLAUDE_PLUGIN_OPTION_REFUSE_ON_SECRETS \
      -u CLAUDE_PLUGIN_OPTION_DEFAULT_MODEL \
      -u CLAUDE_PLUGIN_OPTION_WORKTREE_ROOT \
      "${UC_A[@]}" MUSE_DATA_DIR="$UC_DATA" MUSE_CATALOG_GLOB="$UC_CAT" "$@"
}

uc_field() {  # uc_field <key> -- one JSON field from stdin, empty when absent
  python3 -c 'import json,sys
try: d=json.loads(sys.stdin.read())
except Exception: sys.exit(2)
v=d.get(sys.argv[1])
print("" if v is None else (v if isinstance(v,str) else json.dumps(v)))' "$1"
}

# 1. A bad default_effort is refused before muse is spawned. The control comes
# first: a normal run must log argv, or an empty refusal log proves nothing.
UC_N=$((UC_N+1)); uc_mkrepo "$UC_DIR/repo1"
export UC_STUB_LOG="$UC_DIR/stub-$UC_N.log"; : > "$UC_STUB_LOG"
UC_OUT="$(uc_run PATH="$UC_PATH" -- python3 "$UC_TASK" run --id uc-ok --repo "$(native_path "$UC_DIR/repo1")" --out "$(native_path "$UC_DIR/out-1")" --model stub-model --prompt p 2>/dev/null)"
UC_OK_RC=$?
UC_OUT2=""; UC_RC2=0
if [ "$UC_OK_RC" -eq 0 ] && [ "$(printf '%s' "$UC_OUT" | uc_field status)" = "completed" ] \
    && [ -s "$UC_STUB_LOG" ]; then
  UC_N=$((UC_N+1))
  # A fresh repo: the control run above already created repo1's default root, so
  # asserting absence must happen where nothing has ever run.
  uc_mkrepo "$UC_DIR/repo1b"
  export UC_STUB_LOG="$UC_DIR/stub-$UC_N.log"; : > "$UC_STUB_LOG"
  UC_OUT2="$(uc_run PATH="$UC_PATH" CLAUDE_PLUGIN_OPTION_DEFAULT_EFFORT=High -- python3 "$UC_TASK" run --id uc-bad --repo "$(native_path "$UC_DIR/repo1b")" --out "$(native_path "$UC_DIR/out-1b")" --model stub-model --prompt p 2>/dev/null)"
  UC_RC2=$?
  printf '%s' "$UC_OUT2" > "$UC_DIR/out-1b.json"
  python3 - "$UC_DIR/out-1b.json" "$UC_STUB_LOG" "$(native_path "$UC_DIR/.muse-fleet-wt-repo1b")" "$UC_RC2" <<'PY' 2>/dev/null \
    && ok "config: task refuses a bad default_effort before spawning muse" \
    || bad "config: task refuses a bad default_effort before spawning muse" "$(cat "$UC_DIR/out-1b.json" 2>/dev/null)"
import json, os, sys
raw = open(sys.argv[1], encoding="utf-8").read()
if not raw.strip():
    sys.exit(1)    # refusal JSON was empty: nothing to assert absence against
d = json.loads(raw)
log = sys.argv[2]
wt_default = sys.argv[3]
rc = int(sys.argv[4])
ok = (rc != 0 and d.get("status") == "refused"
      and "default_effort" in str(d.get("reason", ""))
      and (not os.path.exists(log) or os.path.getsize(log) == 0)
      and not os.path.exists(wt_default))
sys.exit(0 if ok else 1)
PY
else
  bad "config: task refuses a bad default_effort before spawning muse" "control run did not complete-and-log: rc=$UC_OK_RC out=$UC_OUT"
fi

# 2. The same bad value stops the fleet and ask drivers, with muse never called.
UC_N=$((UC_N+1)); uc_mkrepo "$UC_DIR/repo2"
printf '[{"id":"a","prompt":"p"}]' > "$UC_DIR/tasks-2.json"
export UC_STUB_LOG="$UC_DIR/stub-$UC_N.log"; : > "$UC_STUB_LOG"
uc_run PATH="$UC_PATH" CLAUDE_PLUGIN_OPTION_DEFAULT_EFFORT=High -- python3 "$UC_FLEET" --tasks "$(native_path "$UC_DIR/tasks-2.json")" --repo "$(native_path "$UC_DIR/repo2")" --out "$(native_path "$UC_DIR/fout-2")" --model stub-model >/dev/null 2>"$UC_DIR/err-2f.txt"
UC_FRC=$?
UC_N=$((UC_N+1))
export UC_STUB_LOG="$UC_DIR/stub-$UC_N.log"; : > "$UC_STUB_LOG"
(cd "$UC_DIR/repo2" && uc_run PATH="$UC_PATH" CLAUDE_PLUGIN_OPTION_DEFAULT_EFFORT=High CLAUDE_PLUGIN_DATA="$UC_DIR/askdata" -- bash "$UC_ASK" "summarise this" >"$UC_DIR/out-2a.txt" 2>"$UC_DIR/err-2a.txt")
UC_ARC=$?
UC_FMSG="$(cat "$UC_DIR/err-2f.txt" 2>/dev/null)"; UC_AMSG="$(cat "$UC_DIR/err-2a.txt" 2>/dev/null)"
if [ "$UC_FRC" -ne 0 ] && printf '%s' "$UC_FMSG" | grep -q "default_effort" \
    && [ ! -s "$UC_DIR/stub-$((UC_N-1)).log" ] \
    && [ "$UC_ARC" -eq 1 ] && printf '%s' "$UC_AMSG" | grep -q "default_effort" \
    && [ ! -s "$UC_STUB_LOG" ]; then
  ok "config: fleet and ask refuse a bad default_effort without calling muse"
else
  bad "config: fleet and ask refuse a bad default_effort without calling muse" "fleet rc=$UC_FRC msg=$UC_FMSG ask rc=$UC_ARC msg=$UC_AMSG"
fi

# 3. Out-of-range and non-integer round caps refuse, from the env and the CLI.
# A cap is a count: only plain digits survive, so 1e1, 3.5 and 10.0 refuse
# exactly like 0 and 999 do.
UC_N=$((UC_N+1)); uc_mkrepo "$UC_DIR/repo3"
export UC_STUB_LOG="$UC_DIR/stub-$UC_N.log"; : > "$UC_STUB_LOG"
UC_MISS=""
for UC_V in 0 -2 999 3.5 1e1 10.0 1_0; do
  UC_O="$(uc_run PATH="$UC_PATH" CLAUDE_PLUGIN_OPTION_MAX_ROUNDS="$UC_V" -- python3 "$UC_TASK" run --id "uc-r$UC_V" --repo "$(native_path "$UC_DIR/repo3")" --out "$(native_path "$UC_DIR/out-3")" --model stub-model --prompt p 2>/dev/null)"
  UC_C=$?
  if [ "$UC_C" -eq 0 ] || [ "$(printf '%s' "$UC_O" | uc_field status)" != "refused" ] \
      || ! printf '%s' "$UC_O" | uc_field reason | grep -q "max_rounds"; then
    UC_MISS="$UC_MISS env:$UC_V"
  fi
done
for UC_V in 999 1e1 3.5 10.0; do
  UC_O="$(uc_run PATH="$UC_PATH" -- python3 "$UC_TASK" run --id uc-rcli --repo "$(native_path "$UC_DIR/repo3")" --out "$(native_path "$UC_DIR/out-3")" --max-rounds "$UC_V" --model stub-model --prompt p 2>/dev/null)"
  UC_C=$?
  if [ "$UC_C" -eq 0 ] || [ "$(printf '%s' "$UC_O" | uc_field status)" != "refused" ] \
      || ! printf '%s' "$UC_O" | uc_field reason | grep -q "max_rounds"; then
    UC_MISS="$UC_MISS cli:$UC_V"
  fi
done
[ -z "$UC_MISS" ] && [ ! -s "$UC_STUB_LOG" ] \
  && ok "config: task refuses out-of-range max_rounds from env and CLI" \
  || bad "config: task refuses out-of-range max_rounds from env and CLI" "not refused:$UC_MISS"

# 4. The boundary values 1 and 10 are accepted and stored.
UC_N=$((UC_N+1)); uc_mkrepo "$UC_DIR/repo4"
export UC_STUB_LOG="$UC_DIR/stub-$UC_N.log"; : > "$UC_STUB_LOG"
uc_run PATH="$UC_PATH" CLAUDE_PLUGIN_OPTION_MAX_ROUNDS=1 -- python3 "$UC_TASK" run --id uc-lo --repo "$(native_path "$UC_DIR/repo4")" --out "$(native_path "$UC_DIR/out-4")" --model stub-model --prompt p >/dev/null 2>&1
uc_run PATH="$UC_PATH" CLAUDE_PLUGIN_OPTION_MAX_ROUNDS=10 -- python3 "$UC_TASK" run --id uc-hi --repo "$(native_path "$UC_DIR/repo4")" --out "$(native_path "$UC_DIR/out-4")" --model stub-model --prompt p >/dev/null 2>&1
python3 - "$(native_path "$UC_DIR/out-4/uc-lo/state.json")" "$(native_path "$UC_DIR/out-4/uc-hi/state.json")" <<'PY' 2>/dev/null \
  && ok "config: task accepts max_rounds 1 and 10" \
  || bad "config: task accepts max_rounds 1 and 10"
import json, sys
lo = json.load(open(sys.argv[1], encoding="utf-8"))
hi = json.load(open(sys.argv[2], encoding="utf-8"))
sys.exit(0 if lo.get("max_rounds") == 1 and hi.get("max_rounds") == 10 else 1)
PY

# 5. The issue's acceptance: configured rounds and effort reach state.json and the
# stub's argv; unset means 3 and low.
UC_N=$((UC_N+1)); uc_mkrepo "$UC_DIR/repo5"
export UC_STUB_LOG="$UC_DIR/stub-$UC_N.log"; : > "$UC_STUB_LOG"
uc_run PATH="$UC_PATH" CLAUDE_PLUGIN_OPTION_MAX_ROUNDS=5 CLAUDE_PLUGIN_OPTION_DEFAULT_EFFORT=medium -- python3 "$UC_TASK" run --id uc-cfg --repo "$(native_path "$UC_DIR/repo5")" --out "$(native_path "$UC_DIR/out-5")" --model stub-model --prompt p >/dev/null 2>&1
UC_N=$((UC_N+1))
export UC_STUB_LOG="$UC_DIR/stub-$UC_N.log"; : > "$UC_STUB_LOG"
uc_run PATH="$UC_PATH" -- python3 "$UC_TASK" run --id uc-def --repo "$(native_path "$UC_DIR/repo5")" --out "$(native_path "$UC_DIR/out-5")" --model stub-model --prompt p >/dev/null 2>&1
python3 - "$(native_path "$UC_DIR/out-5/uc-cfg/state.json")" "$(native_path "$UC_DIR/out-5/uc-def/state.json")" "$UC_DIR/stub-$((UC_N-1)).log" "$UC_STUB_LOG" <<'PY' 2>/dev/null \
  && ok "config: task applies max_rounds and default_effort, unset means 3 and low" \
  || bad "config: task applies max_rounds and default_effort, unset means 3 and low"
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
dflt = json.load(open(sys.argv[2], encoding="utf-8"))
def effort_of(path):
    lines = [ln.strip() for ln in open(path, encoding="utf-8").read().splitlines()]
    for i, ln in enumerate(lines):
        if ln == "--reasoning-effort" and i + 1 < len(lines):
            return lines[i + 1]
    return None
ok = (cfg.get("max_rounds") == 5 and cfg.get("effort") == "medium"
      and effort_of(sys.argv[3]) == "medium"
      and dflt.get("max_rounds") == 3 and dflt.get("effort") == "low"
      and effort_of(sys.argv[4]) == "low")
sys.exit(0 if ok else 1)
PY

# 6. The fleet and ask drivers hand the configured effort to muse.
UC_N=$((UC_N+1)); uc_mkrepo "$UC_DIR/repo6"
printf '[{"id":"a","prompt":"p"}]' > "$UC_DIR/tasks-6.json"
export UC_STUB_LOG="$UC_DIR/stub-$UC_N.log"; : > "$UC_STUB_LOG"
uc_run PATH="$UC_PATH" CLAUDE_PLUGIN_OPTION_DEFAULT_EFFORT=medium -- python3 "$UC_FLEET" --tasks "$(native_path "$UC_DIR/tasks-6.json")" --repo "$(native_path "$UC_DIR/repo6")" --out "$(native_path "$UC_DIR/fout-6")" --model stub-model >/dev/null 2>&1
UC_N=$((UC_N+1))
export UC_STUB_LOG="$UC_DIR/stub-$UC_N.log"; : > "$UC_STUB_LOG"
(cd "$UC_DIR/repo6" && uc_run PATH="$UC_PATH" CLAUDE_PLUGIN_OPTION_DEFAULT_EFFORT=medium CLAUDE_PLUGIN_DATA="$UC_DIR/askdata" -- bash "$UC_ASK" "summarise this" >/dev/null 2>&1)
python3 - "$UC_DIR/stub-$((UC_N-1)).log" "$UC_STUB_LOG" <<'PY' 2>/dev/null \
  && ok "config: fleet and ask hand the configured effort to muse" \
  || bad "config: fleet and ask hand the configured effort to muse"
import sys
def effort_of(path):
    lines = [ln.strip() for ln in open(path, encoding="utf-8").read().splitlines()]
    if not lines:
        return None    # an empty log means the stub never ran: fail, do not pass
    for i, ln in enumerate(lines):
        if ln == "--reasoning-effort" and i + 1 < len(lines):
            return lines[i + 1]
    return None
sys.exit(0 if effort_of(sys.argv[1]) == "medium" and effort_of(sys.argv[2]) == "medium" else 1)
PY

# 7. Booleans coerce strictly: true/false/1/0 work, anything else refuses.
UC_MSG="$(python3 - "$UC_CORE" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
fails = []
for raw, want in (("true", True), ("True", True), ("1", True),
                  ("false", False), ("False", False), ("0", False)):
    try:
        got = mc.coerce_option("refuse_on_secrets", raw)
    except mc.ConfigError as e:
        fails.append("%r refused: %s" % (raw, e)); continue
    if got is not want:
        fails.append("%r gave %r, want %r" % (raw, got, want))
for raw in ("yes", "maybe"):
    try:
        fails.append("%r accepted as %r" % (raw, mc.coerce_option("refuse_on_secrets", raw)))
    except mc.ConfigError:
        pass
print("; ".join(fails))
sys.exit(1 if fails else 0)
PY
)"
[ $? -eq 0 ] \
  && ok "config: refuse_on_secrets coerces true/false/1/0 and refuses the rest" \
  || bad "config: refuse_on_secrets coerces true/false/1/0 and refuses the rest" "$UC_MSG"

# 8. A relative root that lands inside the repo is refused and leaves it clean.
# The refusal JSON must be non-empty first, or the cleanliness proves nothing.
UC_N=$((UC_N+1)); uc_mkrepo "$UC_DIR/repo8"
export UC_STUB_LOG="$UC_DIR/stub-$UC_N.log"; : > "$UC_STUB_LOG"
(cd "$UC_DIR/repo8" && uc_run PATH="$UC_PATH" -- python3 "$UC_TASK" run --id uc-wt --repo . --out "$(native_path "$UC_DIR/out-8")" --worktree-root wts --model stub-model --prompt p >"$UC_DIR/out-8.json" 2>/dev/null)
UC_RC=$?
UC_PORCELAIN="$(git -C "$UC_DIR/repo8" status --porcelain 2>/dev/null | tr -d '\r')"
if [ -s "$UC_DIR/out-8.json" ] \
    && [ "$(uc_field status <"$UC_DIR/out-8.json")" = "refused" ] \
    && uc_field reason <"$UC_DIR/out-8.json" | grep -q "worktree_root" \
    && [ "$UC_RC" -ne 0 ] && [ -z "$UC_PORCELAIN" ] \
    && [ ! -e "$UC_DIR/repo8/wts" ]; then
  ok "config: task refuses a relative worktree root inside the repo and leaves it clean"
else
  bad "config: task refuses a relative worktree root inside the repo and leaves it clean" "rc=$UC_RC json=$(cat "$UC_DIR/out-8.json" 2>/dev/null) porcelain=$UC_PORCELAIN"
fi

# 9. A relative root escapes the repo: from another cwd it lands under the repo's
# parent. Compared with samefile, never with string equality on a bash path.
UC_N=$((UC_N+1)); uc_mkrepo "$UC_DIR/repo9"
export UC_STUB_LOG="$UC_DIR/stub-$UC_N.log"; : > "$UC_STUB_LOG"
(cd "$UC_DIR/other" && uc_run PATH="$UC_PATH" -- python3 "$UC_TASK" run --id uc-rel --repo "$(native_path "$UC_DIR/repo9")" --out "$(native_path "$UC_DIR/out-9")" --worktree-root ../uc-wt-rel --model stub-model --prompt p >"$UC_DIR/out-9.json" 2>/dev/null)
UC_RC=$?
python3 - "$UC_DIR/out-9.json" "$(native_path "$UC_DIR/uc-wt-rel")" "$UC_RC" <<'PY' 2>/dev/null \
  && ok "config: task resolves a relative worktree root against the repo" \
  || bad "config: task resolves a relative worktree root against the repo" "$(cat "$UC_DIR/out-9.json" 2>/dev/null)"
import json, os, sys
raw = open(sys.argv[1], encoding="utf-8").read()
if not raw.strip():
    sys.exit(1)
d = json.loads(raw)
if int(sys.argv[3]) != 0 or d.get("status") != "completed" or not d.get("worktree"):
    sys.exit(1)
sys.exit(0 if os.path.samefile(os.path.dirname(os.path.realpath(d["worktree"])),
                                os.path.realpath(sys.argv[2])) else 1)
PY

# 10. A ~ root expands under the configured home (HOME and USERPROFILE both set,
# so native Windows Python agrees), and no literal ~ directory appears.
UC_N=$((UC_N+1)); uc_mkrepo "$UC_DIR/repo10"
mkdir -p "$UC_DIR/home"
export UC_STUB_LOG="$UC_DIR/stub-$UC_N.log"; : > "$UC_STUB_LOG"
(cd "$UC_DIR/other" && uc_run PATH="$UC_PATH" HOME="$UC_DIR/home" USERPROFILE="$UC_DIR/home" CLAUDE_PLUGIN_OPTION_WORKTREE_ROOT="~/muse-wt" -- python3 "$UC_TASK" run --id uc-home --repo "$(native_path "$UC_DIR/repo10")" --out "$(native_path "$UC_DIR/out-10")" --model stub-model --prompt p >"$UC_DIR/out-10.json" 2>/dev/null)
UC_RC=$?
if python3 - "$UC_DIR/out-10.json" "$(native_path "$UC_DIR/home/muse-wt")" "$UC_RC" <<'PY' 2>/dev/null
import json, os, sys
raw = open(sys.argv[1], encoding="utf-8").read()
if not raw.strip():
    sys.exit(1)
d = json.loads(raw)
if int(sys.argv[3]) != 0 or d.get("status") != "completed" or not d.get("worktree"):
    sys.exit(1)
sys.exit(0 if os.path.samefile(os.path.dirname(os.path.realpath(d["worktree"])),
                                os.path.realpath(sys.argv[2])) else 1)
PY
then
  if [ ! -e "$UC_DIR/repo10/~" ] && [ ! -e "$UC_DIR/other/~" ]; then
    ok "config: task expands a ~ worktree root under the configured home"
  else
    bad "config: task expands a ~ worktree root under the configured home" "a literal ~ directory was created"
  fi
else
  bad "config: task expands a ~ worktree root under the configured home" "$(cat "$UC_DIR/out-10.json" 2>/dev/null)"
fi

# 11. An absolute root inside the repo is refused by task and by fleet alike.
UC_N=$((UC_N+1)); uc_mkrepo "$UC_DIR/repo11"
export UC_STUB_LOG="$UC_DIR/stub-$UC_N.log"; : > "$UC_STUB_LOG"
UC_O="$(uc_run PATH="$UC_PATH" -- python3 "$UC_TASK" run --id uc-in --repo "$(native_path "$UC_DIR/repo11")" --out "$(native_path "$UC_DIR/out-11")" --worktree-root "$(native_path "$UC_DIR/repo11/inner-wt")" --model stub-model --prompt p 2>/dev/null)"
UC_TRC=$?
printf '[{"id":"a","prompt":"p"}]' > "$UC_DIR/tasks-11.json"
uc_run PATH="$UC_PATH" -- python3 "$UC_FLEET" --tasks "$(native_path "$UC_DIR/tasks-11.json")" --repo "$(native_path "$UC_DIR/repo11")" --out "$(native_path "$UC_DIR/fout-11")" --worktree-root "$(native_path "$UC_DIR/repo11/inner-wt")" --model stub-model >/dev/null 2>"$UC_DIR/err-11.txt"
UC_FRC=$?
if [ "$UC_TRC" -ne 0 ] && [ "$(printf '%s' "$UC_O" | uc_field status)" = "refused" ] \
    && printf '%s' "$UC_O" | uc_field reason | grep -q "worktree_root" \
    && [ "$UC_FRC" -ne 0 ] && grep -q "worktree_root" "$UC_DIR/err-11.txt" \
    && [ ! -e "$UC_DIR/repo11/inner-wt" ]; then
  ok "config: task and fleet refuse a worktree root inside the repo"
else
  bad "config: task and fleet refuse a worktree root inside the repo" "task rc=$UC_TRC out=$UC_O fleet rc=$UC_FRC err=$(cat "$UC_DIR/err-11.txt" 2>/dev/null)"
fi

# 12. Doctor shows the configured root, and fails a bad userConfig value. Only
# those two rows are asserted: CI has no muse or credentials, so never assert ready.
UC_N=$((UC_N+1)); uc_mkrepo "$UC_DIR/repo12"
UC_D1="$(uc_run PATH="$UC_PATH" CLAUDE_PLUGIN_OPTION_WORKTREE_ROOT="$(native_path "$UC_DIR/cfg-wt")" -- python3 "$UC_DOC" --json --repo "$(native_path "$UC_DIR/repo12")" 2>/dev/null)"
UC_D2="$(uc_run PATH="$UC_PATH" CLAUDE_PLUGIN_OPTION_DEFAULT_EFFORT=High -- python3 "$UC_DOC" --json --repo "$(native_path "$UC_DIR/repo12")" 2>/dev/null)"
printf '%s' "$UC_D1" > "$UC_DIR/doc-1.json"; printf '%s' "$UC_D2" > "$UC_DIR/doc-2.json"
python3 - "$UC_DIR/doc-1.json" "$UC_DIR/doc-2.json" "$(native_path "$UC_DIR/cfg-wt")" <<'PY' 2>/dev/null \
  && ok "config: doctor reports the configured worktree root and bad userConfig" \
  || bad "config: doctor reports the configured worktree root and bad userConfig"
import json, os, sys
d1 = json.load(open(sys.argv[1], encoding="utf-8"))
d2 = json.load(open(sys.argv[2], encoding="utf-8"))
want = os.path.realpath(sys.argv[3])
wt = [c for c in d1["checks"] if c["name"] == "worktree root"]
badcfg = [c for c in d2["checks"] if c["name"] == "userConfig"]
ok = (len(wt) == 1 and want in wt[0]["value"]
      and len(badcfg) == 1 and badcfg[0]["severity"] == "FAIL"
      and "default_effort" in badcfg[0]["value"])
sys.exit(0 if ok else 1)
PY

# 13. The code matches the manifest: the round bounds equal the constants, the
# effort options equal EFFORTS, and every manifest default coerces cleanly.
python3 - "$UC_CORE" "$(native_path "$SKILL/.claude-plugin/plugin.json")" <<'PY' 2>/dev/null \
  && ok "config: manifest defaults match the code and coerce cleanly" \
  || bad "config: manifest defaults match the code and coerce cleanly"
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
manifest = json.load(open(sys.argv[2], encoding="utf-8"))
cfg = manifest.get("userConfig") or {}
fails = []
mm = cfg.get("max_rounds", {})
if mm.get("min") != mc.MAX_ROUNDS_MIN or mm.get("max") != mc.MAX_ROUNDS_MAX:
    fails.append("manifest max_rounds min/max %r/%r != code %r/%r"
                 % (mm.get("min"), mm.get("max"), mc.MAX_ROUNDS_MIN, mc.MAX_ROUNDS_MAX))
if cfg.get("default_effort", {}).get("options") != mc.EFFORTS:
    fails.append("manifest default_effort options != EFFORTS")
for key, field in cfg.items():
    try:
        mc.coerce_option(key, field.get("default"))
    except mc.ConfigError as e:
        fails.append("manifest default for %s refused: %s" % (key, e))
if fails:
    print("; ".join(fails))
    sys.exit(1)
PY

# 14. Every substituted placeholder names a real userConfig key, and all five
# keys are used. Only this check and check 15 read files statically.
python3 - "$SKILL" <<'PY' 2>/dev/null \
  && ok "config: every user_config placeholder names a real userConfig key" \
  || bad "config: every user_config placeholder names a real userConfig key"
import json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
cfg = json.loads((root / ".claude-plugin/plugin.json").read_text(encoding="utf-8"))["userConfig"]
corpus_files = (sorted((root / "agents").glob("*.md"))
                + sorted((root / "commands").glob("*.md"))
                + sorted((root / "skills").glob("*/SKILL.md")))
corpus = "\n".join(p.read_text(encoding="utf-8") for p in corpus_files)
names = re.findall(r"\$\{user_config\.([^}]*)\}", corpus)
fails = []
if not names:
    fails.append("no ${user_config.*} placeholder found: the checker is measuring nothing")
for n in names:
    if n not in cfg:
        fails.append("%r is not a userConfig key" % n)
for key in ("default_effort", "max_rounds", "worktree_root", "refuse_on_secrets", "default_model"):
    if key not in names:
        fails.append("%s appears nowhere" % key)
sup = (root / "agents/muse-supervisor.md").read_text(encoding="utf-8")
dlg = (root / "commands/delegate.md").read_text(encoding="utf-8")
for f, text in (("muse-supervisor.md", sup), ("delegate.md", dlg)):
    for key in ("max_rounds", "default_effort"):
        if key not in re.findall(r"\$\{user_config\.([^}]*)\}", text):
            fails.append("%s missing in %s" % (key, f))
probe = re.findall(r"\$\{user_config\.([^}]*)\}", "x ${user_config.nope} y")
if not probe or all(n in cfg for n in probe):
    fails.append("the checker does not flag ${user_config.nope}")
for pat in ("workflows/*.js", "references/*.md"):
    for p in sorted(root.glob(pat)):
        if "${user_config." in p.read_text(encoding="utf-8"):
            fails.append("%s must not be substituted" % p.name)
if fails:
    print("; ".join(fails))
    sys.exit(1)
PY

# 15. Every script invocation in prose carries its userConfig flags. The helper
# scans fenced blocks (plus the workflow's ${TASK} run line), asserts non-empty
# input itself, and its --self-test proves it fires on mutated real lines.
UC_FLAGS_OUT="$(python3 "$SKILL/tests/check_userconfig_flags.py" "$SKILL" 2>&1)"
UC_FLAGS_RC=$?
UC_SELF_OUT="$(python3 "$SKILL/tests/check_userconfig_flags.py" "$SKILL" --self-test 2>&1)"
UC_SELF_RC=$?
if [ "$UC_FLAGS_RC" -eq 0 ] && [ "$UC_SELF_RC" -eq 0 ]; then
  ok "config: every muse-task run / muse-fleet / muse-ask --write line carries the userConfig flags"
else
  bad "config: every muse-task run / muse-fleet / muse-ask --write line carries the userConfig flags" "$UC_FLAGS_OUT $UC_SELF_OUT"
fi

# 16. The workflow takes the fleet args through ARGS, refuses bad ones with
# {refused:true} before any agent call, and forwards all five flags to run.
# The body runs inside __run (the runtime's shape: top-level await and return
# are legal there), called once per scenario with fresh args.
if command -v node >/dev/null 2>&1; then
  sed 's/^export const meta/const meta/' "$SKILL/workflows/muse-supervised-fleet.js" > "$UC_DIR/wf-body.js"
  cat > "$UC_DIR/wf-head.js" <<'HARNESS'
let __CAP = [];
let __CALLS = 0;
async function __run(__args, __EFFORT) {
  const args = __args;
  async function agent(prompt, opts) {
    __CALLS++;
    const label = (opts && opts.label) || '';
    if (label === 'plan') {
      return { tasks: [{ id: 't1', prompt: 'do it', files: ['a.txt'], check: 'true', effort: __EFFORT }] };
    }
    if (label === 'stage') {
      const o = __args.out || '/o';
      return { written: [o + '/briefs/t1.prompt.txt', o + '/briefs/t1.check.txt'] };
    }
    if (label === 'census') {
      return { tasks: [{ id: 't1', verdict: 'accept', verified: true }] };
    }
    if (label === 'integrate') {
      return { merge_order: [], conflicts: [], manual_checks: [], unproven: [] };
    }
    __CAP.push(prompt);
    return { id: 't1', verdict: 'accept', rounds_used: 1, verified: true,
             patch: 'p', summary: 's', concerns: [] };
  }
  async function parallel(fns) { return Promise.all(fns.map(function (f) { return f(); })); }
  function phase() {}
  function log() {}
HARNESS
  cat > "$UC_DIR/wf-tail.js" <<'HARNESS'
}
const __fails = [];
function __has(s, sub, what) {
  if ((s || '').indexOf(sub) === -1) { __fails.push(what + ' missing ' + sub); }
}
try {
  let __res = await __run({ job: 'j', repo: '/r', out: '/o', stamp: 'S', maxRounds: 5,
    defaultEffort: 'high', model: 'm1', worktreeRoot: '/w', refuseOnSecrets: false }, 'high');
  if (!__res || __res.refused) { __fails.push('full args refused: ' + JSON.stringify(__res)); }
  else {
    const p = __CAP[__CAP.length - 1] || '';
    if (!p) { __fails.push('no supervise prompt was captured'); }
    __has(p, '--max-rounds 5', 'flags');
    __has(p, '--effort high', 'flags');
    __has(p, '--model "m1"', 'flags');
    __has(p, '--worktree-root "/w"', 'flags');
    __has(p, '--refuse-on-secrets false', 'flags');
  }
  __res = await __run({ job: 'j', repo: '/r', out: '/o', stamp: 'S' }, 'low');
  if (!__res || __res.refused) { __fails.push('bare args refused: ' + JSON.stringify(__res)); }
  else {
    const p = __CAP[__CAP.length - 1] || '';
    __has(p, '--max-rounds 3', 'defaults');
    __has(p, '--refuse-on-secrets true', 'defaults');
    __has(p, '--model "latest-contributor"', 'defaults');
    __has(p, '--worktree-root ""', 'defaults');
  }
  const __bad = [{ job: 'j', repo: '/r', out: '/o', stamp: 'S', defaultEffort: 'High' },
                 { job: 'j', repo: '/r', out: '/o', stamp: 'S', refuseOnSecrets: 'maybe' },
                 { job: 'j', repo: '/r', out: '/o', stamp: 'S', worktreeRoot: 'a"b' }];
  for (const argv of __bad) {
    const before = __CALLS;
    __res = await __run(argv, 'low');
    if (!__res || !__res.refused) { __fails.push('not refused: ' + JSON.stringify(argv)); }
    else if (__CALLS !== before) { __fails.push('agent called while refusing: ' + JSON.stringify(argv)); }
  }
} catch (e) {
  __fails.push('harness: ' + ((e && e.stack) || e));
}
console.log('WFRESULT ' + JSON.stringify({ fails: __fails }));
HARNESS
  cat "$UC_DIR/wf-head.js" "$UC_DIR/wf-body.js" "$UC_DIR/wf-tail.js" > "$UC_DIR/wf-run.mjs"
  UC_WF="$(node "$(native_path "$UC_DIR/wf-run.mjs")" 2>&1 | grep '^WFRESULT ' || true)"
  UC_WF_FAILS="$(printf '%s' "$UC_WF" | python3 -c 'import json,sys
try: d=json.loads(sys.stdin.read().split("WFRESULT ",1)[1])
except Exception: print("no WFRESULT"); sys.exit(0)
print("; ".join(d.get("fails", [])))' 2>/dev/null)"
  if [ -n "$UC_WF" ] && [ -z "$UC_WF_FAILS" ]; then
    ok "config: workflow forwards fleet args to run and refuses bad ones"
  else
    bad "config: workflow forwards fleet args to run and refuses bad ones" "${UC_WF_FAILS:-no WFRESULT: $UC_WF}"
  fi
else
  if [ "${CI:-}" = "true" ]; then
    FAIL=$((FAIL+1)); printf '  FAIL  node not found under CI — workflow userConfig check not run\n'
  else
    skip 1 "node not found — workflow userConfig check not run"
  fi
fi

# 17. Doctor with flags while env holds DIFFERENT valid values: every key
# reports the flag value with (flag). Only the userConfig row is asserted.
UC_N=$((UC_N+1)); uc_mkrepo "$UC_DIR/repo17"
mkdir -p "$UC_DIR/flag-wt" "$UC_DIR/env-wt"
UC_D="$(uc_run PATH="$UC_PATH" CLAUDE_PLUGIN_OPTION_DEFAULT_EFFORT=low CLAUDE_PLUGIN_OPTION_MAX_ROUNDS=2 CLAUDE_PLUGIN_OPTION_REFUSE_ON_SECRETS=false CLAUDE_PLUGIN_OPTION_DEFAULT_MODEL=env-m CLAUDE_PLUGIN_OPTION_WORKTREE_ROOT="$(native_path "$UC_DIR/env-wt")" -- python3 "$UC_DOC" --json --repo "$(native_path "$UC_DIR/repo17")" --effort medium --max-rounds 5 --model flag-m --refuse-on-secrets true --worktree-root "$(native_path "$UC_DIR/flag-wt")" 2>/dev/null)"
printf '%s' "$UC_D" > "$UC_DIR/doc-17.json"
python3 - "$UC_DIR/doc-17.json" "$(native_path "$UC_DIR/flag-wt")" <<'PY' 2>/dev/null \
  && ok "config: doctor reports flag values with sources when flags beat env" \
  || bad "config: doctor reports flag values with sources when flags beat env" "$(python3 -c 'import json;print([c for c in json.load(open("'"$UC_DIR/doc-17.json"'"))["checks"] if c["name"]=="userConfig"])' 2>/dev/null)"
import json, os, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
rows = [c for c in d["checks"] if c["name"] == "userConfig"]
want_wt = os.path.realpath(sys.argv[2])
ok = (len(rows) == 1 and rows[0]["severity"] == "OK"
      and "effort=medium (flag)" in rows[0]["value"]
      and "max_rounds=5 (flag)" in rows[0]["value"]
      and "model=flag-m (flag)" in rows[0]["value"]
      and "refuse_on_secrets=True (flag)" in rows[0]["value"]
      and ("worktree_root=%s (flag)" % want_wt) in rows[0]["value"])
sys.exit(0 if ok else 1)
PY

# 18. Doctor with env only: every key reports (env).
UC_D="$(uc_run PATH="$UC_PATH" CLAUDE_PLUGIN_OPTION_DEFAULT_EFFORT=medium CLAUDE_PLUGIN_OPTION_MAX_ROUNDS=5 CLAUDE_PLUGIN_OPTION_REFUSE_ON_SECRETS=false CLAUDE_PLUGIN_OPTION_DEFAULT_MODEL=env-m CLAUDE_PLUGIN_OPTION_WORKTREE_ROOT="$(native_path "$UC_DIR/env-wt")" -- python3 "$UC_DOC" --json --repo "$(native_path "$UC_DIR/repo17")" 2>/dev/null)"
printf '%s' "$UC_D" > "$UC_DIR/doc-18.json"
python3 - "$UC_DIR/doc-18.json" "$(native_path "$UC_DIR/env-wt")" <<'PY' 2>/dev/null \
  && ok "config: doctor reports env values with sources" \
  || bad "config: doctor reports env values with sources"
import json, os, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
rows = [c for c in d["checks"] if c["name"] == "userConfig"]
want_wt = os.path.realpath(sys.argv[2])
ok = (len(rows) == 1 and rows[0]["severity"] == "OK"
      and "effort=medium (env)" in rows[0]["value"]
      and "max_rounds=5 (env)" in rows[0]["value"]
      and "model=env-m (env)" in rows[0]["value"]
      and "refuse_on_secrets=False (env)" in rows[0]["value"]
      and ("worktree_root=%s (env)" % want_wt) in rows[0]["value"])
sys.exit(0 if ok else 1)
PY

# 19. Doctor with neither: built-in defaults with (default).
UC_D="$(uc_run PATH="$UC_PATH" -- python3 "$UC_DOC" --json --repo "$(native_path "$UC_DIR/repo17")" 2>/dev/null)"
printf '%s' "$UC_D" > "$UC_DIR/doc-19.json"
python3 - "$UC_DIR/doc-19.json" <<'PY' 2>/dev/null \
  && ok "config: doctor reports defaults with sources" \
  || bad "config: doctor reports defaults with sources"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
rows = [c for c in d["checks"] if c["name"] == "userConfig"]
ok = (len(rows) == 1 and rows[0]["severity"] == "OK"
      and "effort=low (default)" in rows[0]["value"]
      and "max_rounds=3 (default)" in rows[0]["value"]
      and "model=latest-contributor (default)" in rows[0]["value"]
      and "refuse_on_secrets=True (default)" in rows[0]["value"]
      and "worktree_root=" in rows[0]["value"]
      and "(default)" in rows[0]["value"])
sys.exit(0 if ok else 1)
PY

# 20. Doctor with a bad flag value: FAIL naming the key and its source.
UC_D="$(uc_run PATH="$UC_PATH" -- python3 "$UC_DOC" --json --repo "$(native_path "$UC_DIR/repo17")" --max-rounds 1e1 2>/dev/null)"
printf '%s' "$UC_D" > "$UC_DIR/doc-20.json"
python3 - "$UC_DIR/doc-20.json" <<'PY' 2>/dev/null \
  && ok "config: doctor FAILs a bad flag value naming the key and source" \
  || bad "config: doctor FAILs a bad flag value naming the key and source"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
rows = [c for c in d["checks"] if c["name"] == "userConfig"]
ok = (len(rows) == 1 and rows[0]["severity"] == "FAIL"
      and "max_rounds" in rows[0]["value"]
      and "1e1" in rows[0]["value"]
      and "flag" in rows[0]["value"])
sys.exit(0 if ok else 1)
PY

# 21. A repo path in different case refuses exactly when the filesystem folds
# case. The test probes that itself: the lower-cased spelling exists as a
# directory only on a case-insensitive host. Both branches run the real task
# (refused with an empty stub log and a clean repo, or completed) plus a
# direct resolve_worktree_root call with the same expectation.
uc_mkrepo "$UC_DIR/RepoCase"
UC_LOWER="$(printf '%s' "$UC_DIR/RepoCase" | tr 'A-Z' 'a-z')"
if [ -d "$UC_LOWER" ]; then UC_FOLDS=1; else UC_FOLDS=0; fi
UC_N=$((UC_N+1))
export UC_STUB_LOG="$UC_DIR/stub-$UC_N.log"; : > "$UC_STUB_LOG"
UC_O="$(uc_run PATH="$UC_PATH" -- python3 "$UC_TASK" run --id uc-case --repo "$(native_path "$UC_DIR/RepoCase")" --out "$(native_path "$UC_DIR/out-21")" --worktree-root "$(native_path "$UC_LOWER/wts")" --model stub-model --prompt p 2>/dev/null)"
UC_C=$?
UC_PORCELAIN="$(git -C "$UC_DIR/RepoCase" status --porcelain 2>/dev/null | tr -d '\r')"
python3 - "$UC_CORE" "$(native_path "$UC_DIR/RepoCase")" "$(native_path "$UC_LOWER/wts")" "$UC_FOLDS" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
try:
    mc.resolve_worktree_root(sys.argv[2], sys.argv[3])
    refused = False
except mc.ConfigError:
    refused = True
sys.exit(0 if refused == (sys.argv[4] == "1") else 1)
PY
UC_DIRECT_RC=$?
if [ "$UC_FOLDS" = "1" ]; then
  if [ "$UC_C" -ne 0 ] && [ "$(printf '%s' "$UC_O" | uc_field status)" = "refused" ] \
      && printf '%s' "$UC_O" | uc_field reason | grep -q "worktree_root" \
      && [ ! -s "$UC_STUB_LOG" ] && [ -z "$UC_PORCELAIN" ] \
      && [ "$UC_DIRECT_RC" -eq 0 ]; then
    ok "config: task refuses a differently-cased worktree root on a case-insensitive filesystem"
  else
    bad "config: task refuses a differently-cased worktree root on a case-insensitive filesystem" "rc=$UC_C out=$UC_O porcelain=$UC_PORCELAIN direct_rc=$UC_DIRECT_RC"
  fi
else
  if [ "$(printf '%s' "$UC_O" | uc_field status)" = "completed" ] \
      && ! printf '%s' "$UC_O" | uc_field reason 2>/dev/null | grep -q "worktree_root" \
      && [ "$UC_DIRECT_RC" -eq 0 ]; then
    ok "config: task refuses a differently-cased worktree root on a case-insensitive filesystem"
  else
    bad "config: task refuses a differently-cased worktree root on a case-insensitive filesystem" "rc=$UC_C out=$UC_O direct_rc=$UC_DIRECT_RC"
  fi
fi

# 22. The new driver flags change behaviour: --refuse-on-secrets beats or yields
# to userConfig per invocation, --allow-secrets always allows, and empty
# --model/--effort fall back to env. The repo holds a committed AWS example key
# (assembled by printf so the literal never enters the test source), and the
# stub log is checked every time: empty means muse never spawned.
UC_N=$((UC_N+1)); uc_mkrepo "$UC_DIR/repo22"
printf 'AKIA%s\n' 'IOSFODNN7EXAMPLE' > "$UC_DIR/repo22/keys.txt"
git -C "$UC_DIR/repo22" add -A
git -C "$UC_DIR/repo22" -c user.email=t@l -c user.name=t commit -qm keys
UC_SMISS=""
# a. env false plus --refuse-on-secrets true: the flag wins, task refuses.
export UC_STUB_LOG="$UC_DIR/stub-$UC_N.log"; : > "$UC_STUB_LOG"
UC_O="$(uc_run PATH="$UC_PATH" CLAUDE_PLUGIN_OPTION_REFUSE_ON_SECRETS=false -- python3 "$UC_TASK" run --id uc-s1 --repo "$(native_path "$UC_DIR/repo22")" --out "$(native_path "$UC_DIR/out-22")" --model stub-model --prompt p --refuse-on-secrets true 2>/dev/null)"
if [ "$?" -ne 0 ] && [ "$(printf '%s' "$UC_O" | uc_field status)" = "refused" ] \
    && [ ! -s "$UC_STUB_LOG" ]; then :; else UC_SMISS="$UC_SMISS a"; fi
# b. env unset plus --refuse-on-secrets false: not refused, muse runs.
UC_N=$((UC_N+1)); export UC_STUB_LOG="$UC_DIR/stub-$UC_N.log"; : > "$UC_STUB_LOG"
UC_O="$(uc_run PATH="$UC_PATH" -- python3 "$UC_TASK" run --id uc-s2 --repo "$(native_path "$UC_DIR/repo22")" --out "$(native_path "$UC_DIR/out-22")" --model stub-model --prompt p --refuse-on-secrets false 2>/dev/null)"
if [ "$(printf '%s' "$UC_O" | uc_field status)" = "completed" ] \
    && [ -s "$UC_STUB_LOG" ]; then :; else UC_SMISS="$UC_SMISS b"; fi
# c. --refuse-on-secrets true with --allow-secrets: the override always allows.
UC_N=$((UC_N+1)); export UC_STUB_LOG="$UC_DIR/stub-$UC_N.log"; : > "$UC_STUB_LOG"
UC_O="$(uc_run PATH="$UC_PATH" -- python3 "$UC_TASK" run --id uc-s3 --repo "$(native_path "$UC_DIR/repo22")" --out "$(native_path "$UC_DIR/out-22")" --model stub-model --prompt p --refuse-on-secrets true --allow-secrets 2>/dev/null)"
if [ "$(printf '%s' "$UC_O" | uc_field status)" = "completed" ] \
    && [ -s "$UC_STUB_LOG" ]; then :; else UC_SMISS="$UC_SMISS c"; fi
# d. fleet with env false plus --refuse-on-secrets true: refuses, muse silent.
UC_N=$((UC_N+1)); export UC_STUB_LOG="$UC_DIR/stub-$UC_N.log"; : > "$UC_STUB_LOG"
printf '[{"id":"sa","prompt":"p"}]' > "$UC_DIR/tasks-22.json"
uc_run PATH="$UC_PATH" CLAUDE_PLUGIN_OPTION_REFUSE_ON_SECRETS=false -- python3 "$UC_FLEET" --tasks "$(native_path "$UC_DIR/tasks-22.json")" --repo "$(native_path "$UC_DIR/repo22")" --out "$(native_path "$UC_DIR/fout-22")" --model stub-model --refuse-on-secrets true >/dev/null 2>"$UC_DIR/err-22.txt"
if [ "$?" -ne 0 ] && grep -q "refused" "$UC_DIR/err-22.txt" \
    && [ ! -s "$UC_STUB_LOG" ]; then :; else UC_SMISS="$UC_SMISS d"; fi
# e. ask --write with env false plus --refuse-on-secrets true: refuses.
UC_N=$((UC_N+1)); export UC_STUB_LOG="$UC_DIR/stub-$UC_N.log"; : > "$UC_STUB_LOG"
(cd "$UC_DIR/repo22" && uc_run PATH="$UC_PATH" CLAUDE_PLUGIN_OPTION_REFUSE_ON_SECRETS=false CLAUDE_PLUGIN_DATA="$UC_DIR/askdata" -- bash "$UC_ASK" --write --refuse-on-secrets true "edit the key" >"$UC_DIR/out-22a.txt" 2>"$UC_DIR/err-22a.txt")
if [ "$?" -eq 1 ] && grep -q "muse_ask: refused:" "$UC_DIR/err-22a.txt" \
    && [ ! -s "$UC_STUB_LOG" ]; then :; else UC_SMISS="$UC_SMISS e"; fi
# f. --model "" falls back to env; g. --effort "" falls back to env.
UC_N=$((UC_N+1)); export UC_STUB_LOG="$UC_DIR/stub-$UC_N.log"; : > "$UC_STUB_LOG"
UC_FLOG="$UC_STUB_LOG"
uc_run PATH="$UC_PATH" CLAUDE_PLUGIN_OPTION_DEFAULT_MODEL=env-model -- python3 "$UC_TASK" run --id uc-s4 --repo "$(native_path "$UC_DIR/repo22")" --out "$(native_path "$UC_DIR/out-22")" --model "" --prompt p --refuse-on-secrets false >/dev/null 2>&1
UC_N=$((UC_N+1)); export UC_STUB_LOG="$UC_DIR/stub-$UC_N.log"; : > "$UC_STUB_LOG"
UC_GLOG="$UC_STUB_LOG"
uc_run PATH="$UC_PATH" CLAUDE_PLUGIN_OPTION_DEFAULT_EFFORT=medium -- python3 "$UC_TASK" run --id uc-s5 --repo "$(native_path "$UC_DIR/repo22")" --out "$(native_path "$UC_DIR/out-22")" --effort "" --model stub-model --prompt p --refuse-on-secrets false >/dev/null 2>&1
python3 - "$UC_FLOG" "$UC_GLOG" <<'PY' 2>/dev/null || UC_SMISS="$UC_SMISS fg"
import sys
def val_of(path, flag):
    lines = [ln.strip() for ln in open(path, encoding="utf-8").read().splitlines()]
    if not lines:
        return None
    for i, ln in enumerate(lines):
        if ln == flag and i + 1 < len(lines):
            return lines[i + 1]
    return None
sys.exit(0 if val_of(sys.argv[1], "--model") == "env-model"
         and val_of(sys.argv[2], "--reasoning-effort") == "medium" else 1)
PY
if [ -z "$UC_SMISS" ]; then
  ok "config: --refuse-on-secrets and an empty --model reach task, fleet and ask"
else
  bad "config: --refuse-on-secrets and an empty --model reach task, fleet and ask" "failed:$UC_SMISS"
fi

if [ "$UC_STANDALONE" = 1 ]; then
  printf 'userconfig: %d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]; exit $?
fi
