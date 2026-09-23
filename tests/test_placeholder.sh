#!/usr/bin/env bash
# Unsubstituted ${user_config.KEY} placeholders count as "flag not given".
# The runtime substitutes a key into prose only when the user configured it;
# an unset key arrives as the literal text, so every driver must fall through
# to env and then the default instead of refusing. Sourced by validate.sh;
# also runnable alone with `bash tests/test_placeholder.sh`.
PH_STANDALONE=0
if ! declare -F ok >/dev/null 2>&1; then
  PH_STANDALONE=1
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
  LAB="$(native_path "$(mktemp -d "${TMPDIR:-/tmp}/muse-ph.XXXXXX")")"
  if [ -z "${LAB:-}" ] || [ ! -d "$LAB" ]; then echo "no scratch dir" >&2; exit 1; fi
  PASS=0; FAIL=0; SKIP=0
  ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
  bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && echo "        $2"; }
  skip() { local n="$1"; shift; SKIP=$((SKIP+n)); printf '  SKIP  %s\n' "$*"; }
fi

if [ -z "${LAB:-}" ] || [ ! -d "${LAB:-}" ]; then
  echo "placeholder: refusing to run without a scratch dir" >&2
  if [ "$PH_STANDALONE" = 1 ]; then exit 1; else return 1; fi
fi

PH_TASK="$SKILL/scripts/muse_task.py"
PH_FLEET="$SKILL/scripts/muse_fleet.py"
PH_CORE="$SKILL/scripts/muse_core.py"
PH_ASK="$SKILL/scripts/muse_ask.sh"
PH_DOC="$SKILL/scripts/muse_doctor.py"
PH_PLUGIN="$SKILL/.claude-plugin/plugin.json"
PH_DIR="$LAB/v_placeholder"
PH_N=0
rm -rf "$PH_DIR"; mkdir -p "$PH_DIR/bin" "$PH_DIR/data" "$PH_DIR/askdata"
PH_DATA="$PH_DIR/data"
PH_CAT="$PH_DIR/nocat/*.json"

# A muse that logs its argv and immediately completes. A non-empty log proves the
# worker started; its content proves which flags it was started with.
cat > "$PH_DIR/bin/muse" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "muse 1.3.0"; exit 0; fi
printf '%s\n' "$@" >> "$PH_STUB_LOG"
printf '{"payload":{"kind":"run_terminal","terminal":"completed","text":"ok"}}\n'
STUB
chmod +x "$PH_DIR/bin/muse"
# Native python on Windows cannot execute the extensionless bash stub: shutil.which
# honours PATHEXT (so it needs muse.cmd) and CreateProcess never consults PATHEXT at
# all, so even the .cmd is unreachable under the bare name unless run_muse resolves it
# via which() first. Same shape as validate.sh's make_muse_stub.
if command -v cygpath >/dev/null 2>&1; then
  printf '@echo off\r\n"%s" "%s" %%*\r\nexit /b %%ERRORLEVEL%%\r\n' \
    "$(native_path "$(command -v bash)")" \
    "$(native_path "$PH_DIR/bin/muse")" > "$PH_DIR/bin/muse.cmd"
fi
PH_PATH="$(shell_path "$PH_DIR/bin"):$PATH"

ph_mkrepo() {  # ph_mkrepo <dir> -- calc.py tracked, clean tree
  rm -rf "$1"; mkdir -p "$1"; git init -q -b main "$1"
  printf 'def add(a,b):\n    return a+b\n' > "$1/calc.py"
  git -C "$1" add -A
  git -C "$1" -c user.email=t@l -c user.name=t commit -qm init
}

# Every invocation goes through here: all five CLAUDE_PLUGIN_OPTION_* vars are
# unset first so no host config leaks in, and the model catalog points at a
# nonexistent dir so the default model deterministically resolves to the
# fallback muse-spark-1.3-contributor with model_choice starting "fallback".
ph_run() {  # ph_run [VAR=val ...] -- cmd [args ...]
  local PH_A=()
  while [ "$1" != "--" ]; do PH_A+=("$1"); shift; done
  shift
  env -u CLAUDE_PLUGIN_OPTION_DEFAULT_EFFORT \
      -u CLAUDE_PLUGIN_OPTION_MAX_ROUNDS \
      -u CLAUDE_PLUGIN_OPTION_REFUSE_ON_SECRETS \
      -u CLAUDE_PLUGIN_OPTION_DEFAULT_MODEL \
      -u CLAUDE_PLUGIN_OPTION_WORKTREE_ROOT \
      ${PH_A[@]+"${PH_A[@]}"} MUSE_DATA_DIR="$PH_DATA" MUSE_CATALOG_GLOB="$PH_CAT" "$@"
}

# 1. option_with_source: a same-key placeholder (even padded with spaces) falls
# through to env and then the plugin.json default; a different-key one refuses
# naming both keys; a partial match stays a flag value.
PH_MSG="$(ph_run -- python3 - "$PH_CORE" "$PH_PLUGIN" <<'PY' 2>&1
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
manifest = json.load(open(sys.argv[2], encoding="utf-8"))
cfg = manifest["userConfig"]
fails = []
ENVVAL = {"default_effort": "medium", "max_rounds": "5",
          "default_model": "stub-m", "refuse_on_secrets": "false",
          "worktree_root": "/tmp/ph-wt-x"}
ENVWANT = {"default_effort": "medium", "max_rounds": 5,
           "default_model": "stub-m", "refuse_on_secrets": False,
           "worktree_root": "/tmp/ph-wt-x"}
KEYS = ["default_effort", "max_rounds", "default_model",
        "refuse_on_secrets", "worktree_root"]
for PH_K in KEYS:
    PH_PH = "${user_config.%s}" % PH_K
    for PH_V in (PH_PH, "  " + PH_PH + "  "):
        os.environ.pop("CLAUDE_PLUGIN_OPTION_" + PH_K.upper(), None)
        try:
            PH_GOT = mc.option_with_source(PH_K, PH_V, cfg[PH_K]["default"])
        except mc.ConfigError as PH_E:
            fails.append("%s %r refused: %s" % (PH_K, PH_V, PH_E)); continue
        if list(PH_GOT) != [cfg[PH_K]["default"], "default"]:
            fails.append("%s %r gave %r, want (%r, 'default')"
                         % (PH_K, PH_V, PH_GOT, cfg[PH_K]["default"]))
        os.environ["CLAUDE_PLUGIN_OPTION_" + PH_K.upper()] = ENVVAL[PH_K]
        try:
            PH_GOT = mc.option_with_source(PH_K, PH_V, cfg[PH_K]["default"])
        except mc.ConfigError as PH_E:
            fails.append("%s %r with env refused: %s" % (PH_K, PH_V, PH_E))
        else:
            if list(PH_GOT) != [ENVWANT[PH_K], "env"]:
                fails.append("%s %r with env gave %r" % (PH_K, PH_V, PH_GOT))
        finally:
            os.environ.pop("CLAUDE_PLUGIN_OPTION_" + PH_K.upper(), None)
for PH_I, PH_K in enumerate(KEYS):
    PH_O = KEYS[(PH_I + 1) % len(KEYS)]
    try:
        mc.option_with_source(PH_K, "${user_config.%s}" % PH_O, cfg[PH_K]["default"])
        fails.append("%s with %s placeholder accepted" % (PH_K, PH_O))
    except mc.ConfigError as PH_E:
        if PH_K not in str(PH_E) or PH_O not in str(PH_E):
            fails.append("different-key error names neither key: %s" % PH_E)
PH_GOT = mc.option_with_source("worktree_root", "/x/${user_config.worktree_root}/y", "")
if list(PH_GOT) != ["/x/${user_config.worktree_root}/y", "flag"]:
    fails.append("partial match gave %r" % (PH_GOT,))
if mc.flag_given("default_model", None) is not False:
    fails.append("None counts as given")
if mc.flag_given("default_model", "") is not False:
    fails.append("empty counts as given")
print("; ".join(fails))
sys.exit(1 if fails else 0)
PY
)"
if [ $? -eq 0 ]; then
  ok "config: placeholder counts as unset in option_with_source"
else
  bad "config: placeholder counts as unset in option_with_source" "$PH_MSG"
fi

# 2. The measured supervisor line: three placeholders where the unset keys were
# left literal. Must run to completion on defaults, and muse must never see a
# placeholder in its argv.
PH_N=$((PH_N+1)); ph_mkrepo "$PH_DIR/phrepo2"
export PH_STUB_LOG="$PH_DIR/stub-$PH_N.log"; : > "$PH_STUB_LOG"
PH_OUT="$(ph_run PATH="$PH_PATH" -- python3 "$PH_TASK" run --id t1 --out "$(native_path "$PH_DIR/out-2")" --repo "$(native_path "$PH_DIR/phrepo2")" --effort medium --max-rounds 5 --model '${user_config.default_model}' --worktree-root '${user_config.worktree_root}' --refuse-on-secrets '${user_config.refuse_on_secrets}' --prompt p 2>/dev/null)"
PH_RC=$?
printf '%s' "$PH_OUT" > "$PH_DIR/out-2.json"
python3 - "$PH_DIR/out-2.json" "$PH_STUB_LOG" "$(native_path "$PH_DIR/out-2/t1/state.json")" "$(native_path "$PH_DIR/.muse-fleet-wt-phrepo2")" "$PH_RC" <<'PY' 2>/dev/null \
  && [ -s "$PH_STUB_LOG" ] && ! grep -q -F '${user_config' "$PH_STUB_LOG" \
  && ok "config: placeholder the measured supervisor line runs with defaults" \
  || bad "config: placeholder the measured supervisor line runs with defaults" "$(cat "$PH_DIR/out-2.json" 2>/dev/null)"
import json, os, sys
raw = open(sys.argv[1], encoding="utf-8").read()
if not raw.strip():
    sys.exit(1)    # refusal JSON was empty: nothing to assert absence against
d = json.loads(raw)
log = open(sys.argv[2], encoding="utf-8").read()
if not log.strip():
    sys.exit(1)    # an empty stub log proves nothing about the absence below
if "${user_config" in log:
    sys.exit(1)
if int(sys.argv[5]) != 0 or d.get("status") != "completed":
    sys.exit(1)
st = json.load(open(sys.argv[3], encoding="utf-8"))
wt = d.get("worktree") or ""
ok = (st.get("max_rounds") == 5 and st.get("effort") == "medium"
      and st.get("model") == "muse-spark-1.3-contributor"
      and str(st.get("model_choice", "")).startswith("fallback")
      and os.path.samefile(os.path.dirname(os.path.realpath(wt)),
                           os.path.realpath(sys.argv[4])))
sys.exit(0 if ok else 1)
PY

# 3. An unset refuse_on_secrets (placeholder) still refuses a real credential.
# The control runs first with an explicit false: it must complete, proving the
# run works and the scan input is non-empty, or the refusal below proves nothing.
PH_N=$((PH_N+1)); ph_mkrepo "$PH_DIR/phrepo3"
python3 - "$PH_DIR/phrepo3/cred.txt" <<'PY'
import sys
open(sys.argv[1], "w").write("aws_key=" + "AKIA" + "IOSFODNN7EXAMPLE" + "\n")
PY
git -C "$PH_DIR/phrepo3" add -A
git -C "$PH_DIR/phrepo3" -c user.email=t@l -c user.name=t commit -qm cred
export PH_STUB_LOG="$PH_DIR/stub-$PH_N.log"; : > "$PH_STUB_LOG"
PH_CTL="$(ph_run PATH="$PH_PATH" -- python3 "$PH_TASK" run --id ph-sec-ok --out "$(native_path "$PH_DIR/out-3")" --repo "$(native_path "$PH_DIR/phrepo3")" --effort medium --max-rounds 5 --model '${user_config.default_model}' --worktree-root '${user_config.worktree_root}' --refuse-on-secrets false --prompt p 2>/dev/null)"
PH_CTLRC=$?
PH_CTLLOG="$PH_STUB_LOG"
PH_N=$((PH_N+1))
export PH_STUB_LOG="$PH_DIR/stub-$PH_N.log"; : > "$PH_STUB_LOG"
PH_OUT="$(ph_run PATH="$PH_PATH" -- python3 "$PH_TASK" run --id ph-sec-ph --out "$(native_path "$PH_DIR/out-3")" --repo "$(native_path "$PH_DIR/phrepo3")" --effort medium --max-rounds 5 --model '${user_config.default_model}' --worktree-root '${user_config.worktree_root}' --refuse-on-secrets '${user_config.refuse_on_secrets}' --prompt p 2>/dev/null)"
PH_RC=$?
printf '%s' "$PH_CTL" > "$PH_DIR/out-3ctl.json"; printf '%s' "$PH_OUT" > "$PH_DIR/out-3.json"
python3 - "$PH_DIR/out-3ctl.json" "$PH_DIR/out-3.json" "$PH_CTLLOG" "$PH_CTLRC" "$PH_RC" <<'PY' 2>/dev/null \
  && [ ! -s "$PH_STUB_LOG" ] \
  && ok "config: placeholder refuse_on_secrets defaults to refusing" \
  || bad "config: placeholder refuse_on_secrets defaults to refusing" "$(cat "$PH_DIR/out-3.json" 2>/dev/null)"
import json, os, sys
ctl = json.loads(open(sys.argv[1], encoding="utf-8").read() or "{}")
d = json.loads(open(sys.argv[2], encoding="utf-8").read() or "{}")
if int(sys.argv[4]) != 0 or ctl.get("status") != "completed":
    sys.exit(1)    # control did not run: the refusal below is unproven
if not open(sys.argv[3], encoding="utf-8").read().strip():
    sys.exit(1)    # control never reached muse: the scan input may be empty
ok = (int(sys.argv[5]) != 0 and d.get("status") == "refused"
      and bool(d.get("reason")) and "userConfig" not in str(d.get("reason", ""))
      and bool(d.get("secrets")))
sys.exit(0 if ok else 1)
PY

# 4. Doctor with placeholder flags reports the default worktree root and the
# mixed flag/default userConfig row. Only those two rows are asserted: CI has
# no muse or credentials, so never assert overall readiness.
PH_N=$((PH_N+1)); ph_mkrepo "$PH_DIR/phrepo4"
PH_D="$(ph_run PATH="$PH_PATH" -- python3 "$PH_DOC" --json --repo "$(native_path "$PH_DIR/phrepo4")" --effort medium --max-rounds 5 --model '${user_config.default_model}' --refuse-on-secrets '${user_config.refuse_on_secrets}' --worktree-root '${user_config.worktree_root}' 2>/dev/null)"
printf '%s' "$PH_D" > "$PH_DIR/doc-4.json"
python3 - "$PH_DIR/doc-4.json" <<'PY' 2>/dev/null \
  && ok "config: placeholder doctor reports the default worktree root" \
  || bad "config: placeholder doctor reports the default worktree root" "$(cat "$PH_DIR/doc-4.json" 2>/dev/null)"
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
if not raw.strip():
    sys.exit(1)
d = json.loads(raw)
wt = [c for c in d["checks"] if c["name"] == "worktree root"]
uc = [c for c in d["checks"] if c["name"] == "userConfig"]
if len(wt) != 1 or len(uc) != 1:
    sys.exit(1)
ok = (wt[0]["severity"] != "FAIL"
      and ".muse-fleet-wt-phrepo4" in wt[0]["value"] and "default" in wt[0]["value"]
      and uc[0]["severity"] == "OK"
      and "max_rounds=5 (flag)" in uc[0]["value"]
      and "refuse_on_secrets=True (default)" in uc[0]["value"]
      and "model=latest-contributor (default)" in uc[0]["value"]
      and "worktree_root=" in uc[0]["value"] and "(default)" in uc[0]["value"])
sys.exit(0 if ok else 1)
PY

# 5. Fleet and ask accept placeholders: configured effort reaches muse, and no
# placeholder text leaks into any argv the stub records.
PH_N=$((PH_N+1)); ph_mkrepo "$PH_DIR/phrepo5"
printf '[{"id":"a","prompt":"p"}]' > "$PH_DIR/tasks-5.json"
export PH_STUB_LOG="$PH_DIR/stub-$PH_N.log"; : > "$PH_STUB_LOG"
ph_run PATH="$PH_PATH" -- python3 "$PH_FLEET" --tasks "$(native_path "$PH_DIR/tasks-5.json")" --repo "$(native_path "$PH_DIR/phrepo5")" --out "$(native_path "$PH_DIR/fout-5")" --effort medium --model '${user_config.default_model}' --worktree-root '${user_config.worktree_root}' --refuse-on-secrets '${user_config.refuse_on_secrets}' >/dev/null 2>&1
PH_FRC=$?
PH_FLOG="$PH_STUB_LOG"
PH_N=$((PH_N+1))
export PH_STUB_LOG="$PH_DIR/stub-$PH_N.log"; : > "$PH_STUB_LOG"
(cd "$PH_DIR/phrepo5" && ph_run PATH="$PH_PATH" CLAUDE_PLUGIN_DATA="$PH_DIR/askdata" -- bash "$PH_ASK" --effort medium --model '${user_config.default_model}' --refuse-on-secrets '${user_config.refuse_on_secrets}' "summarise this" >"$PH_DIR/out-5a.txt" 2>"$PH_DIR/err-5a.txt")
PH_ARC=$?
python3 - "$PH_FLOG" "$PH_STUB_LOG" "$PH_FRC" "$PH_ARC" <<'PY' 2>/dev/null \
  && ok "config: placeholder fleet and ask accept placeholders" \
  || bad "config: placeholder fleet and ask accept placeholders" "fleet rc=$PH_FRC ask rc=$PH_ARC"
import sys
def PH_EFFORT(path):
    lines = [ln.strip() for ln in open(path, encoding="utf-8").read().splitlines()]
    if not lines:
        return None    # an empty log means the stub never ran: fail, do not pass
    for PH_I, PH_LN in enumerate(lines):
        if PH_LN == "--reasoning-effort" and PH_I + 1 < len(lines):
            return lines[PH_I + 1]
    return None
PH_LOGS = [open(sys.argv[1], encoding="utf-8").read(),
           open(sys.argv[2], encoding="utf-8").read()]
if not all(PH_L.strip() for PH_L in PH_LOGS):
    sys.exit(1)
if any("${user_config" in PH_L for PH_L in PH_LOGS):
    sys.exit(1)
sys.exit(0 if int(sys.argv[3]) == 0 and int(sys.argv[4]) == 0
         and PH_EFFORT(sys.argv[1]) == "medium"
         and PH_EFFORT(sys.argv[2]) == "medium" else 1)
PY

# 6. A placeholder naming a DIFFERENT key is a wiring bug: every driver refuses
# naming both keys, muse is never spawned, and no worktree root is created.
# Check 2 is the control proving the same shape otherwise runs.
PH_N=$((PH_N+1)); ph_mkrepo "$PH_DIR/phrepo6"
export PH_STUB_LOG="$PH_DIR/stub-$PH_N.log"; : > "$PH_STUB_LOG"
PH_OUT="$(ph_run PATH="$PH_PATH" -- python3 "$PH_TASK" run --id ph-wrong --out "$(native_path "$PH_DIR/out-6")" --repo "$(native_path "$PH_DIR/phrepo6")" --model '${user_config.max_rounds}' --prompt p 2>/dev/null)"
PH_TRC=$?
printf '%s' "$PH_OUT" > "$PH_DIR/out-6.json"
PH_TLOG="$PH_STUB_LOG"
PH_N=$((PH_N+1)); export PH_STUB_LOG="$PH_DIR/stub-$PH_N.log"; : > "$PH_STUB_LOG"
ph_run PATH="$PH_PATH" -- python3 "$PH_FLEET" --tasks "$(native_path "$PH_DIR/tasks-5.json")" --repo "$(native_path "$PH_DIR/phrepo6")" --out "$(native_path "$PH_DIR/fout-6")" --model '${user_config.max_rounds}' >/dev/null 2>"$PH_DIR/err-6f.txt"
PH_FRC=$?
PH_FLOG="$PH_STUB_LOG"
PH_N=$((PH_N+1)); export PH_STUB_LOG="$PH_DIR/stub-$PH_N.log"; : > "$PH_STUB_LOG"
(cd "$PH_DIR/phrepo6" && ph_run PATH="$PH_PATH" CLAUDE_PLUGIN_DATA="$PH_DIR/askdata" -- bash "$PH_ASK" --model '${user_config.max_rounds}' "summarise this" >"$PH_DIR/out-6a.txt" 2>"$PH_DIR/err-6a.txt")
PH_ARC=$?
python3 - "$PH_DIR/out-6.json" "$PH_DIR/err-6f.txt" "$PH_DIR/err-6a.txt" "$PH_TRC" "$PH_FRC" "$PH_ARC" <<'PY' 2>/dev/null \
  && [ ! -s "$PH_TLOG" ] && [ ! -s "$PH_FLOG" ] && [ ! -s "$PH_STUB_LOG" ] \
  && [ ! -e "$PH_DIR/.muse-fleet-wt-phrepo6" ] \
  && ok "config: placeholder naming another key is refused" \
  || bad "config: placeholder naming another key is refused" "task rc=$PH_TRC fleet rc=$PH_FRC ask rc=$PH_ARC out=$(cat "$PH_DIR/out-6.json" 2>/dev/null)"
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
if not raw.strip():
    sys.exit(1)
d = json.loads(raw)
ok = (int(sys.argv[4]) != 0 and d.get("status") == "refused"
      and "default_model" in str(d.get("reason", ""))
      and "max_rounds" in str(d.get("reason", "")))
PH_FERR = open(sys.argv[2], encoding="utf-8", errors="replace").read()
PH_AERR = open(sys.argv[3], encoding="utf-8", errors="replace").read()
ok = ok and int(sys.argv[5]) != 0 and "default_model" in PH_FERR
ok = ok and int(sys.argv[6]) == 1 and "default_model" in PH_AERR
sys.exit(0 if ok else 1)
PY

# 7. The workflow maps same-key placeholders to its built-ins and refuses a
# cross-key one before any agent call. Built like tests/test_workflow.sh: the
# workflow source is embedded verbatim with `export const meta` replaced, the
# body runs inside __body, args arrive as JSON through the environment.
if command -v node >/dev/null 2>&1; then
  ph_mkrepo "$PH_DIR/phrepo7"
  PH_WF_ARGS_A="$(python3 -c 'import json,sys; print(json.dumps({"pluginRoot":sys.argv[1],"repo":sys.argv[2],"out":sys.argv[3],"stamp":"ph1","job":"x","maxRounds":"${user_config.max_rounds}","defaultEffort":"${user_config.default_effort}","model":"${user_config.default_model}","worktreeRoot":"${user_config.worktree_root}","refuseOnSecrets":"${user_config.refuse_on_secrets}"}))' "$(native_path "$PH_DIR")" "$(native_path "$PH_DIR/phrepo7")" "$(native_path "$PH_DIR/wfout")")"
  PH_WF_ARGS_B="$(python3 -c 'import json,sys; print(json.dumps({"pluginRoot":sys.argv[1],"repo":sys.argv[2],"out":sys.argv[3],"stamp":"ph1","job":"x","maxRounds":"${user_config.max_rounds}","defaultEffort":"${user_config.default_effort}","model":"${user_config.worktree_root}","worktreeRoot":"${user_config.worktree_root}","refuseOnSecrets":"${user_config.refuse_on_secrets}"}))' "$(native_path "$PH_DIR")" "$(native_path "$PH_DIR/phrepo7")" "$(native_path "$PH_DIR/wfout")")"
  python3 - "$SKILL/workflows/muse-supervised-fleet.js" "$PH_DIR/wf-run.mjs" <<'PY'
import sys
PH_SRC, PH_DEST = sys.argv[1], sys.argv[2]
PH_BODY = open(PH_SRC, encoding="utf-8").read().replace("export const meta", "const meta", 1)
PH_HEAD = """const RAW = process.env.PH_WF_ARGS_JSON;
if (RAW !== undefined) globalThis.args = JSON.parse(RAW);
const CALLS = [];
let PLAN_PROMPT = null, TASK_PROMPT = null;
globalThis.phase = () => {};
globalThis.log = () => {};
globalThis.parallel = (fns) => Promise.all(fns.map((f) => f()));
globalThis.agent = async (prompt, opts) => {
  const label = (opts && opts.label) || '';
  CALLS.push(label);
  if (label === 'plan') {
    PLAN_PROMPT = prompt;
    return { tasks: [{ id: 't1', prompt: 'p', files: ['a.py'], check: 'true', effort: 'low' }] };
  }
  if (label === 'stage') {
    const m = prompt.match(/```json\\n([\\s\\S]*?)\\n```/);
    if (!m) throw new Error('stage: no json block');
    return { written: JSON.parse(m[1]).map((it) => it.path) };
  }
  if (label.indexOf('task:') === 0) { TASK_PROMPT = prompt; throw new Error('PH_STOP'); }
  if (label === 'census') return { tasks: [] };
  if (label === 'integrate') return { merge_order: [], conflicts: [], manual_checks: [], unproven: [] };
  throw new Error('unexpected agent label: ' + label);
};
async function __body(){
"""
PH_TAIL = """
}
(async () => {
  try {
    const r = await __body();
    console.log('PHRESULT ' + JSON.stringify({ result: r, calls: CALLS, planPrompt: PLAN_PROMPT, taskPrompt: TASK_PROMPT, error: null }));
  } catch (e) {
    console.log('PHRESULT ' + JSON.stringify({ result: null, calls: CALLS, planPrompt: PLAN_PROMPT, taskPrompt: TASK_PROMPT, error: String((e && e.message) || e) }));
  }
})();
"""
open(PH_DEST, "w", encoding="utf-8").write(PH_HEAD + PH_BODY + PH_TAIL)
PY
  PH_WF_ARGS_JSON="$PH_WF_ARGS_A" node "$(native_path "$PH_DIR/wf-run.mjs")" > "$PH_DIR/wf-a.json" 2>"$PH_DIR/wf-a.err"
  PH_WF_ARGS_JSON="$PH_WF_ARGS_B" node "$(native_path "$PH_DIR/wf-run.mjs")" > "$PH_DIR/wf-b.json" 2>"$PH_DIR/wf-b.err"
  PH_WFA="$(grep '^PHRESULT ' "$PH_DIR/wf-a.json" 2>/dev/null || true)"
  PH_WFB="$(grep '^PHRESULT ' "$PH_DIR/wf-b.json" 2>/dev/null || true)"
  printf '%s' "$PH_WFA" > "$PH_DIR/wf-a.res"; printf '%s' "$PH_WFB" > "$PH_DIR/wf-b.res"
  python3 - "$PH_DIR/wf-a.res" "$PH_DIR/wf-b.res" <<'PY' 2>/dev/null \
    && ok "config: placeholder workflow args fall back to defaults" \
    || bad "config: placeholder workflow args fall back to defaults" "no PHRESULT or wrong prompts"
import json, sys
def PH_GET(path):
    raw = open(path, encoding="utf-8").read()
    if not raw.strip():
        return None
    return json.loads(raw.split("PHRESULT ", 1)[1])
a = PH_GET(sys.argv[1]); b = PH_GET(sys.argv[2])
if a is None or b is None:
    sys.exit(1)
if "PH_STOP" not in str(a.get("error") or ""):
    sys.exit(1)    # case A never reached Build: the flag asserts below are unproven
tp = a.get("taskPrompt") or ""
if not tp:
    sys.exit(1)    # no supervise prompt was captured: absence asserts prove nothing
for PH_WANT in ('--max-rounds 3', '--model "latest-contributor"',
                '--worktree-root ""', '--refuse-on-secrets true'):
    if PH_WANT not in tp:
        sys.exit(1)
if "user_config" in tp:
    sys.exit(1)
if '"low"' not in str(a.get("planPrompt") or ""):
    sys.exit(1)
ok = (isinstance(b.get("result"), dict) and b["result"].get("refused") is True
      and "model" in str(b["result"].get("reason", "")) and b.get("calls") == [])
sys.exit(0 if ok else 1)
PY
else
  skip 1 "node not found — placeholder workflow check not run"
fi

if [ "$PH_STANDALONE" = 1 ]; then
  printf 'placeholder: %d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]; exit $?
fi
