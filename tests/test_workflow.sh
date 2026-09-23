#!/usr/bin/env bash
# shellcheck shell=bash
# Issue #44: the registered fleet workflow bypassed the supervisor agent, believed the
# supervisor's own "verified" field, interpolated model-written briefs and checks into
# double-quoted shell, and threw when the model called it without args. Sourced by
# scripts/validate.sh (one line); also runnable alone. Every variable is WF_-prefixed
# because validate.sh sources this into its own global namespace.
WF_STANDALONE=0
if ! declare -F ok >/dev/null 2>&1; then
  WF_STANDALONE=1
  set -uo pipefail
  export PYTHONUTF8=1
  native_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
  shell_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi; }
  SKILL="$(native_path "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)")"
  LAB="$(mktemp -d "${TMPDIR:-/tmp}/musewf.XXXXXX")"
  # Every path below is built from LAB and the next lines rm -rf under it.
  if [ -z "$LAB" ] || [ ! -d "$LAB" ]; then echo "no scratch dir" >&2; exit 1; fi
  LAB="$(native_path "$LAB")"
  PASS=0; FAIL=0; SKIP=0
  ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
  bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && echo "        $2"; }
  skip() {
    local n="$1"; shift
    if [ "${CI:-}" = "true" ]; then
      FAIL=$((FAIL+n)); printf '  FAIL  SKIP counts as a failure under CI: %s\n' "$*"
    else
      SKIP=$((SKIP+n)); printf '  SKIP  %s\n' "$*"
    fi
  }
fi
if ! declare -F make_muse_stub >/dev/null 2>&1; then
  # Same logic as validate.sh's helper: a stub `muse` both shells can find, with the
  # .cmd wrapper native Windows Python needs.
  make_muse_stub() {
    mkdir -p "$1"
    printf '#!/bin/sh\nexit 0\n' > "$1/muse"
    chmod +x "$1/muse"
    if command -v cygpath >/dev/null 2>&1; then
      printf '@echo off\r\nexit /b 0\r\n' > "$1/muse.cmd"
    fi
  }
fi

WF="$LAB/v_workflow"; rm -rf "$WF"; mkdir -p "$WF/plugin/bin" "$WF/repo" "$WF/out"
# On Windows a bare 'bash' from node can resolve to WSL, so hand node the real one.
WF_BASH="$(native_path "$BASH")"
# On Git Bash $BASH is already /usr/bin/bash.exe, and MSYS test -f also answers true
# for bash.exe.exe (it resolves the .exe suffix itself), so only append when missing.
case "$WF_BASH" in
  *.exe) ;;
  *) [ -f "$BASH.exe" ] && WF_BASH="$WF_BASH.exe" ;;
esac

# A fake plugin dir: absolute shims so the workflow never does a PATH lookup.
WF_PLUG="$(native_path "$WF/plugin")"
cat > "$WF/plugin/bin/muse-task" <<EOF
#!/usr/bin/env bash
# Stub: records its argv, copies --prompt-file/--command-file bytes aside, prints {}.
WF_LOG="$WF/task-argv.log"
id=""; pf=""; cf=""; prev=""
for a in "\$@"; do
  [ "\$prev" = "--id" ] && id="\$a"
  [ "\$prev" = "--prompt-file" ] && pf="\$a"
  [ "\$prev" = "--command-file" ] && cf="\$a"
  prev="\$a"
done
printf '%s\n' "\$*" >> "\$WF_LOG"
[ -n "\$pf" ] && cp "\$pf" "$WF/seen_prompt.\$id"
[ -n "\$cf" ] && cp "\$cf" "$WF/seen_check.\$id"
printf '{}\n'
EOF
chmod +x "$WF/plugin/bin/muse-task"
printf '#!/usr/bin/env bash\nexec python3 "%s/scripts/muse_status.py" "$@"\n' "$SKILL" > "$WF/plugin/bin/muse-status"
chmod +x "$WF/plugin/bin/muse-status"

if command -v node >/dev/null 2>&1; then
  # The harness is built with python3, not node: the workflow source is embedded
  # verbatim (backticks and all), with `export const meta` replaced by `const meta`
  # and the body wrapped in `async function __body` -- the runtime's shape, where
  # top-level await and return are legal. globalThis.args comes from WF_ARGS_JSON;
  # the literal `undefined` leaves args undeclared, the way a model calling with no
  # args does.
  WF_SRC="$SKILL/workflows/muse-supervised-fleet.js"
  WF_LAB_N="$(native_path "$WF")"
  WF_REPO_N="$(native_path "$WF/repo")"
  WF_OUT_N="$(native_path "$WF/out")"
  WF_ARGS_MAIN="$(python3 -c 'import json,sys; print(json.dumps({"pluginRoot":sys.argv[1],"repo":sys.argv[2],"out":sys.argv[3],"stamp":"wf1","job":"test job"}))' "$WF_PLUG" "$WF_REPO_N" "$WF_OUT_N")"
  export WF_LAB_N WF_BASH WF_PLUG WF_REPO_N WF_OUT_N
  python3 - "$WF_SRC" "$WF/run.mjs" "$WF/expect.json" <<'PY'
import json, sys
src, dest, expect = sys.argv[1], sys.argv[2], sys.argv[3]
import os
lab, wbash, plug, repo, out = (os.environ[k] for k in
    ("WF_LAB_N", "WF_BASH", "WF_PLUG", "WF_REPO_N", "WF_OUT_N"))
bad_prompt = "touch-probe $(touch %s/pwned1) `touch %s/pwned2`" % (lab, lab)
bad_check = "test -f x && echo $(touch %s/pwned3)" % lab
good_prompt = "a plain brief with no metacharacters"
good_check = "true"
harness = """import fs from 'node:fs';
import path from 'node:path';
import cp from 'node:child_process';
const LAB = %s;
const WBASH = %s;
const OUTD = %s;
const BAD_PROMPT = %s;
const BAD_CHECK = %s;
const GOOD_PROMPT = %s;
const GOOD_CHECK = %s;
const RAW = process.env.WF_ARGS_JSON;
if (RAW !== 'undefined') globalThis.args = JSON.parse(RAW);
const calls = [];
const logs = [];
const phases = [];
globalThis.phase = (t) => { phases.push(t); };
globalThis.log = (m) => { logs.push(String(m)); };
globalThis.parallel = (fns) => Promise.all(fns.map((f) => f()));
globalThis.agent = async (prompt, opts) => {
  opts = opts || {};
  const label = opts.label || '';
  calls.push({ label, agentType: opts.agentType || null, prompt });
  if (label === 'plan') {
    return { tasks: [
      { id: 't-bad', prompt: BAD_PROMPT, files: ['a.py'], check: BAD_CHECK, effort: 'low' },
      { id: 't-good', prompt: GOOD_PROMPT, files: ['b.py'], check: GOOD_CHECK, effort: 'low' },
    ] };
  }
  if (label === 'stage') {
    const m = prompt.match(/```json\\n([\\s\\S]*?)\\n```/);
    if (!m) throw new Error('stage: no ```json block');
    if ((prompt.match(/```json/g) || []).length !== 1) throw new Error('stage: not exactly one ```json block');
    const items = JSON.parse(m[1]);
    const written = [];
    for (const it of items) {
      fs.mkdirSync(path.dirname(it.path), { recursive: true });
      fs.writeFileSync(it.path, it.content);
      written.push(it.path);
    }
    return { written };
  }
  if (label.indexOf('task:') === 0) {
    const blocks = [...prompt.matchAll(/```bash\\n([\\s\\S]*?)\\n\\s*```/g)].map((x) => x[1]);
    for (const b of blocks) cp.execFileSync(WBASH, ['-c', b], { stdio: 'pipe' });
    const id = label.slice(5);
    const dir = OUTD + '/' + id;
    fs.mkdirSync(dir, { recursive: true });
    if (id === 't-bad') {
      fs.writeFileSync(dir + '/state.json', JSON.stringify({ id, rounds: [], verifications: [] }));
      fs.writeFileSync(dir + '/task.json', JSON.stringify({ id, verdict: 'accept' }));
    } else {
      fs.writeFileSync(dir + '/state.json', JSON.stringify({ id, rounds: [], verifications: [{ command: 'true', exit_code: 0, passed: true }] }));
      fs.writeFileSync(dir + '/task.json', JSON.stringify({ id, verdict: 'accept', verified_by_supervisor: true }));
    }
    // Both supervisors claim verified: the workflow must still flag t-bad from disk.
    return { id, verdict: 'accept', verified: true, rounds_used: 1, patch: '', summary: '', concerns: [] };
  }
  if (label === 'census') {
    const blocks = [...prompt.matchAll(/```bash\\n([\\s\\S]*?)\\n\\s*```/g)].map((x) => x[1]);
    if (!blocks.length) throw new Error('census: no ```bash block');
    const stdout = cp.execFileSync(WBASH, ['-c', blocks[0]], { encoding: 'utf8' });
    return { tasks: JSON.parse(stdout).tasks };
  }
  if (label === 'integrate') return { merge_order: [], conflicts: [], manual_checks: [], unproven: [] };
  throw new Error('unexpected agent label: ' + label);
};
async function __body(){
""" % tuple(json.dumps(s) for s in (lab, wbash, out, bad_prompt, bad_check, good_prompt, good_check))
body = open(src, encoding="utf-8").read().replace("export const meta", "const meta", 1)
tail = """
}
__body().then(
  (result) => console.log(JSON.stringify({ result, calls, logs, error: null })),
  (err) => console.log(JSON.stringify({ result: null, calls, logs, error: String((err && err.stack) || err) }))
);
"""
open(dest, "w", encoding="utf-8").write(harness + body + tail)
json.dump({"bad_prompt": bad_prompt, "bad_check": bad_check}, open(expect, "w"))
PY

  WF_ARGS_JSON="$WF_ARGS_MAIN" node "$WF/run.mjs" > "$WF/main.json" 2>"$WF/main.err"
  # 1. Every task:* call names the supervisor agent definition.
  python3 - "$WF/main.json" <<'PY' \
    && ok "workflow: every task supervisor runs as muse:muse-supervisor" \
    || bad "workflow: every task supervisor runs as muse:muse-supervisor" "$(cat "$WF/main.err" | head -2)"
import json, sys
d = json.load(open(sys.argv[1]))
assert not d.get("error"), d.get("error")
calls = d.get("calls") or []
tasked = [c for c in calls if (c.get("label") or "").startswith("task:")]
assert tasked, "no task:* agent call was recorded, so the check measured nothing"
assert all(c.get("agentType") == "muse:muse-supervisor" for c in tasked), \
    [c.get("agentType") for c in tasked]
PY

  # 2. The dangerous text flowed through, the commands ran, and nothing executed it.
  python3 - "$WF/main.json" "$WF/task-argv.log" "$WF" <<'PY' \
    && ok "workflow: model-written briefs and checks never execute as shell" \
    || bad "workflow: model-written briefs and checks never execute as shell"
import json, os, sys
d = json.load(open(sys.argv[1]))
assert not d.get("error"), d.get("error")
log = open(sys.argv[2]).read() if os.path.exists(sys.argv[2]) else ""
lines = log.splitlines()
assert any(l.startswith("run ") for l in lines), \
    "stub saw no `run` invocation, so the commands never executed"
assert any(l.startswith("verify ") for l in lines), "stub saw no `verify` invocation"
prompts = " ".join(c.get("prompt") or "" for c in (d.get("calls") or []))
assert "$(touch" in prompts, "no recorded prompt contained $(touch -- the dangerous input was absent"
for n in ("pwned1", "pwned2", "pwned3"):
    assert not os.path.exists(os.path.join(sys.argv[3], n)), \
        "the dangerous text executed: %s exists" % n
PY

  # 3. The dangerous text reached muse-task intact, through a file.
  python3 - "$WF/expect.json" "$WF/seen_prompt.t-bad" "$WF/seen_check.t-bad" <<'PY' \
    && ok "workflow: the brief and check reach muse-task byte-for-byte through files" \
    || bad "workflow: the brief and check reach muse-task byte-for-byte through files"
import json, sys
exp = json.load(open(sys.argv[1]))
got_p = open(sys.argv[2], "rb").read().decode("utf-8")
got_c = open(sys.argv[3], "rb").read().decode("utf-8")
assert got_p == exp["bad_prompt"], "prompt bytes differ: %r" % got_p[:80]
assert got_c == exp["bad_check"], "check bytes differ: %r" % got_c[:80]
PY

  # 4-5. The census reads disk: t-bad is unverified despite verified:true, t-good is not.
  python3 - "$WF/main.json" <<'PY' \
    && ok "workflow: an accept with no passing check on disk is unverified" \
    || bad "workflow: an accept with no passing check on disk is unverified"
import json, sys
d = json.load(open(sys.argv[1]))
assert not d.get("error"), d.get("error")
unv = (d.get("result") or {}).get("unverified")
assert isinstance(unv, list), "result.unverified is %r, not an array" % (unv,)
assert "t-bad" in unv, "t-bad (verified:true, nothing on disk) is not in %r" % (unv,)
PY
  python3 - "$WF/main.json" <<'PY' \
    && ok "workflow: a genuinely verified accept is not flagged" \
    || bad "workflow: a genuinely verified accept is not flagged"
import json, sys
d = json.load(open(sys.argv[1]))
assert not d.get("error"), d.get("error")
unv = (d.get("result") or {}).get("unverified")
assert isinstance(unv, list), "result.unverified is %r, not an array" % (unv,)
assert "t-good" not in unv, "t-good (passing check on disk) flagged in %r" % (unv,)
PY

  # 6. No args, or empty args, refuses before any agent call.
  WF_REF_OK=1
  for WF_ARGV in '{}' 'undefined'; do
    WF_ARGS_JSON="$WF_ARGV" node "$WF/run.mjs" > "$WF/ref.json" 2>/dev/null
    python3 - "$WF/ref.json" "$WF_ARGV" <<'PY' || WF_REF_OK=0
import json, sys
d = json.load(open(sys.argv[1]))
assert not d.get("error"), "threw on args %s: %s" % (sys.argv[2], d.get("error"))
assert (d.get("result") or {}).get("refused") is True, "not refused: %r" % (d.get("result"),)
assert (d.get("result") or {}).get("reason"), "refusal names nothing"
assert (d.get("calls") or []) == [], "spawned agents while refusing"
PY
  done
  [ "$WF_REF_OK" = "1" \
    ] && ok "workflow: missing args refuses with no agent calls" \
    || bad "workflow: missing args refuses with no agent calls"

  # 7. Each unsafe value refuses with zero agent calls.
  WF_UNSAFE_OK=1
  WF_BASE_ARGS="$WF_ARGS_MAIN"
  python3 - "$WF_BASE_ARGS" > "$WF/unsafe-cases.txt" <<'PY'
import json, sys
base = json.loads(sys.argv[1])
cases = dict(base)
cases["stamp"] = "a;b"
print(json.dumps(cases))
cases = dict(base)
cases["repo"] = "/r/$(x)"
print(json.dumps(cases))
cases = dict(base)
cases["pluginRoot"] = "/p/`x`"
print(json.dumps(cases))
cases = dict(base)
cases["maxRounds"] = 0
print(json.dumps(cases))
PY
  while IFS= read -r WF_CASE; do
    WF_ARGS_JSON="$WF_CASE" node "$WF/run.mjs" > "$WF/ref.json" 2>/dev/null
    python3 - "$WF/ref.json" "$WF_CASE" <<'PY' || WF_UNSAFE_OK=0
import json, sys
d = json.load(open(sys.argv[1]))
assert not d.get("error"), "threw on %s: %s" % (sys.argv[2], d.get("error"))
assert (d.get("result") or {}).get("refused") is True, "not refused: %r" % (d.get("result"),)
assert (d.get("calls") or []) == [], "spawned agents while refusing %s" % sys.argv[2]
PY
  done < "$WF/unsafe-cases.txt"
  [ "$WF_UNSAFE_OK" = "1" \
    ] && ok "workflow: unsafe stamp, repo, pluginRoot and maxRounds each refuse" \
    || bad "workflow: unsafe stamp, repo, pluginRoot and maxRounds each refuse"
else
  skip 7 "workflow: node not found - fleet workflow not executed"
fi

# Checks 8-10 need no node: real muse_task.py with a stub muse on PATH.
WF_T="$SKILL/scripts/muse_task.py"
WF_R="$WF/repo8"; rm -rf "$WF_R"; mkdir -p "$WF_R"
git init -q -b main "$WF_R"
printf 'def add(a,b):\n    return a+b\n' > "$WF_R/calc.py"
git -C "$WF_R" add -A
git -C "$WF_R" -c user.email=t@e -c user.name=t commit -qm init
make_muse_stub "$WF/stubbin"
WF_OLDPATH="$PATH"
PATH="$(shell_path "$WF/stubbin"):$PATH"
export PATH

# 8. A brief staged under <repo>/.muse-fleet/ must not make the first run "dirty",
# and --prompt-file must carry it without executing it.
mkdir -p "$WF_R/.muse-fleet/briefs"
printf '%s' "brief \$(touch $WF/pwned4)" > "$WF_R/.muse-fleet/briefs/b.prompt.txt"
WF_RUN8=$(python3 "$WF_T" run --id pf --out "$WF_R/.muse-fleet/s" --repo "$WF_R" \
  --stamp wf1 --prompt-file "$WF_R/.muse-fleet/briefs/b.prompt.txt" \
  --worktree-root "$WF/wtroot" 2>/dev/null)
python3 - "$WF_R/.muse-fleet/s/pf/state.json" "$WF_R/.muse-fleet/briefs/b.prompt.txt" "$WF_RUN8" "$WF/pwned4" <<'PY' \
  && ok "workflow: --prompt-file runs from a brief staged under .muse-fleet/" \
  || bad "workflow: --prompt-file runs from a brief staged under .muse-fleet/" "$WF_RUN8"
import json, os, sys
st_path, brief_path, run_out, probe = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
d = json.loads(run_out)
assert d.get("status") != "refused", "refused: %r" % (d.get("reason"),)
st = json.load(open(st_path, encoding="utf-8"))
want = open(brief_path, encoding="utf-8").read()
assert st.get("brief") == want, "state brief %r != file %r" % (st.get("brief"), want)
assert not os.path.exists(probe), "the brief executed instead of travelling as bytes"
PY

# 9. --command-file records the file's text (minus one trailing newline), not its path.
printf 'echo wfcheck\n' > "$WF/check.txt"
WF_VER9=$(python3 "$WF_T" verify --id pf --out "$WF_R/.muse-fleet/s" \
  --command-file "$WF/check.txt" 2>/dev/null)
echo "$WF_VER9" | python3 -c "
import json,sys
d=json.load(sys.stdin)
sys.exit(0 if d.get('command')=='echo wfcheck' and d.get('exit_code')==0 else 1)" \
  && ok "workflow: --command-file records the check text" \
  || bad "workflow: --command-file records the check text" "$WF_VER9"

# 10. --prompt and --prompt-file together are a usage error.
python3 "$WF_T" run --id both --out "$WF_R/.muse-fleet/s" --repo "$WF_R" \
  --prompt x --prompt-file "$WF_R/.muse-fleet/briefs/b.prompt.txt" >/dev/null 2>&1
[ $? -ne 0 ] \
  && ok "workflow: --prompt with --prompt-file exits non-zero" \
  || bad "workflow: --prompt with --prompt-file exits non-zero" "both flags accepted"

PATH="$WF_OLDPATH"
export PATH

if [ "$WF_STANDALONE" = "1" ]; then
  printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ] || exit 1
fi
