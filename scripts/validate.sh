#!/usr/bin/env bash
# Full validation of the muse plugin. Offline checks first (fast, free),
# then live muse runs (slow, costs tokens).
set -uo pipefail

# Self-locate rather than trusting an install path: this script must validate the copy
# it actually ships inside, not whatever other copy happens to be installed.
# On Windows this is Git Bash driving a NATIVE python. Bash translates MSYS paths in
# argv when it invokes a native program, so `python3 /d/a/x.py` works -- but a path
# embedded in a python -c STRING, or exported in an environment variable, gets no
# translation and reaches python as an unresolvable literal. Normalise once, here, so
# every consumer downstream is handed something both shells understand. cygpath -m gives
# "D:/a/repo": native, with forward slashes, so it stays safe to embed either side.
# Windows Python defaults to cp1252 for text I/O, and this repo's own files contain
# UTF-8 (em dashes, box drawing, arrows) -- so every embedded `open(...).read()` below
# would raise UnicodeDecodeError there. PYTHONUTF8=1 puts the interpreter in UTF-8 mode
# for the whole suite, which is one line instead of an encoding= on 23 call sites. The
# SHIPPED scripts do not rely on this: they pass encoding= explicitly, because a user
# runs those directly and will not have this variable set.
export PYTHONUTF8=1

native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# A stub `muse` that BOTH shells can find. shutil.which() on Windows honours PATHEXT, so
# a bare shell script named "muse" is invisible to native python no matter how executable
# bash thinks it is -- which made every preflight-dependent check fail there for a reason
# that had nothing to do with the code under test.
shell_path() {   # inverse of native_path: PATH entries must not contain a drive colon
  if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi
}

# A PATH with python and git but deliberately without muse. "/usr/bin:/bin" is not a
# portable way to express that -- on Windows it omits python entirely, so the doctor
# could not run at all and reported no verdict.
minimal_path() {
  printf '%s:%s' "$(dirname "$(command -v python3)")" "$(dirname "$(command -v git)")"
}

make_muse_stub() {  # make_muse_stub <dir>
  mkdir -p "$1"
  printf '#!/bin/sh\nexit 0\n' > "$1/muse"
  chmod +x "$1/muse"
  if command -v cygpath >/dev/null 2>&1; then
    printf '@echo off\r\nexit /b 0\r\n' > "$1/muse.cmd"
  fi
}

SKILL="$(native_path "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)")"
export PLUGIN_ROOT="$SKILL"
SKILL_MD="$SKILL/skills/muse-fleet/SKILL.md"
FLEET="$SKILL/scripts/muse_fleet.py"
TASK="$SKILL/scripts/muse_task.py"
CORE="$SKILL/scripts/muse_core.py"
# `mktemp -d -t NAME` is BSD-only: GNU coreutils rejects a template with no trailing X's
# and prints nothing, which silently left LAB empty. Every path below is built from it, so
# an empty LAB turned "$LAB/v_dirty" into "/v_dirty" -- and mkrepo starts with `rm -rf`.
LAB="$(native_path "${MUSE_FLEET_LAB:-$(mktemp -d "${TMPDIR:-/tmp}/musefleetlab.XXXXXX")}")"
if [ -z "${LAB:-}" ] || [ ! -d "$LAB" ]; then
  echo "refusing to run: could not create a scratch dir (LAB='${LAB:-}')" >&2
  echo "every test path is built from it, and this script rm -rf's those paths." >&2
  exit 1
fi

# --offline stops before section 4. Sections 1-3 spawn no muse and cost nothing, so they
# can run on every change; the live sections cost real money and several minutes.
OFFLINE=0
[[ "${1:-}" == "--offline" ]] && OFFLINE=1
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ -n "${2:-}" ] && echo "        $2"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

mkrepo() {  # mkrepo <path>
  rm -rf "$1"; mkdir -p "$1"; git init -q -b main "$1"
  printf 'def add(a,b):\n    return a+b\n' > "$1/calc.py"
  git -C "$1" add -A
  git -C "$1" -c user.email=t@l -c user.name=t commit -qm init
}

# ---------------------------------------------------------------- 1. static
head_ "1. Static checks"
python3 -m py_compile "$FLEET" && ok "muse_fleet.py compiles" || bad "compile"
python3 -m py_compile "$CORE" && ok "muse_core.py compiles" || bad "core compile"
python3 -m py_compile "$TASK" && ok "muse_task.py compiles" || bad "task compile"
for c in run revise verify show finish cleanup; do
  python3 "$TASK" "$c" --help >/dev/null 2>&1 \
    && ok "muse_task.py $c subcommand parses" || bad "muse_task $c"
done
# The two paths must share one harvest implementation, or a patch produced through the
# workflow differs from the same patch produced through the CLI.
python3 -c "
import sys
t=open('$TASK').read(); f=open('$FLEET').read()
sys.exit(0 if 'core.harvest(' in t and 'core.harvest(' in f else 1)" \
  && ok "both paths harvest through muse_core" || bad "harvest logic has forked"
python3 -c "import json;json.load(open('$SKILL/assets/result-schema.json'))" \
  && ok "result-schema.json is valid JSON" || bad "schema json"
python3 - <<PY && ok "schema satisfies Meta required-all rule" || bad "schema required-all"
import json,sys
s=json.load(open("$SKILL/assets/result-schema.json"))
sys.exit(0 if not set(s["properties"])-set(s["required"]) else 1)
PY
python3 -c "
import re,sys
t=open('$SKILL_MD').read()
assert t.startswith('---'), 'no frontmatter'
fm=t.split('---')[1]
assert 'name:' in fm and 'description:' in fm
sys.exit(0)" && ok "SKILL.md frontmatter well-formed" || bad "frontmatter"
bash -n "$SKILL/scripts/use_latest_contributor.sh" && ok "use_latest_contributor.sh parses" || bad "bash syntax"
bash -n "$SKILL/scripts/muse_ask.sh" && ok "muse_ask.sh parses" || bad "muse_ask syntax"
for f in routing.md workflow.md muse-cli.md field-notes.md; do
  [ -s "$SKILL/references/$f" ] && ok "references/$f present" || bad "missing references/$f"
done
grep -q 'references/routing.md' "$SKILL_MD" && ok "SKILL.md points at routing.md" || bad "routing.md unreferenced"

# The workflow script in references/workflow.md is the skill's primary path and is copied
# out verbatim to be run. Nothing else would notice a typo in it until someone spent real
# money discovering it mid-run.
if command -v node >/dev/null 2>&1; then
  # EVERY javascript block, not just the first: the embedding section ships snippets that
  # users copy-paste, and a syntax error in one of those is exactly as broken as one in
  # the main script.
  WF_SYNTAX=$(python3 - <<'PY'
import re, pathlib, os, subprocess, tempfile
t = pathlib.Path(os.path.join(os.environ["PLUGIN_ROOT"], "references/workflow.md")).read_text()
blocks = re.findall(r"```javascript\n(.*?)```", t, re.S)
if not blocks:
    print("no javascript blocks found"); raise SystemExit
bad = []
for i, b in enumerate(blocks, 1):
    src = b.replace("export const meta", "const meta", 1)
    # The runtime evaluates the body inside an async function, so top-level await and
    # return are legal there but not in a bare module. Reproduce that shape or the
    # check is a lie.
    body = ("const agent=async()=>({tasks:[]}),parallel=async()=>[],pipeline=async()=>[],"
            "phase=()=>{},log=()=>{};\nglobalThis.args={pluginRoot:'/p',stamp:'s',repo:'/r'};"
            "\nconst tasks=[];\nasync function __body(){\n" + src + "\n}")
    f = tempfile.NamedTemporaryFile("w", suffix=".mjs", delete=False)
    f.write(body); f.close()
    r = subprocess.run(["node", "--check", f.name], capture_output=True, text=True)
    os.unlink(f.name)
    if r.returncode != 0:
        bad.append("block %d: %s" % (i, r.stderr.strip().splitlines()[-1][:80] if r.stderr.strip() else "?"))
print("; ".join(bad))
PY
)
  [ -z "$WF_SYNTAX" ] \
    && ok "every workflow.md javascript block parses as the runtime evaluates it" \
    || bad "workflow script syntax" "$WF_SYNTAX"

  # meta.phases titles are matched EXACTLY against phase() calls; a drifted title
  # silently splits the progress display into an orphan group instead of erroring.
  for RULE in "not write the code" "do NOT apply the patch" "verify" "resumed"; do
    grep -qi "$RULE" "$SKILL/agents/muse-supervisor.md" \
      && grep -qi "$RULE" "$SKILL/references/workflow.md" \
      && ok "supervisor doctrine present in both paths: $RULE" \
      || bad "doctrine drift between the agent and the workflow prompt: $RULE"
  done

  python3 - <<'PY' && ok "workflow meta.phases cover every phase() call" || bad "phase titles drift"
import re, pathlib, os, sys
t = pathlib.Path(os.path.join(os.environ["PLUGIN_ROOT"], "references/workflow.md")).read_text()
b = re.findall(r"```javascript\n(.*?)```", t, re.S)[0]
meta  = set(re.findall(r"title:\s*'([^']+)'", b))
calls = set(re.findall(r"phase\('([^']+)'\)", b)) | set(re.findall(r"phase:\s*'([^']+)'", b))
if calls - meta:
    print("        orphan phases:", sorted(calls - meta))
sys.exit(0 if calls <= meta else 1)
PY
else
  printf '  \033[33mSKIP\033[0m  node not found — workflow script not syntax-checked\n'
fi

# ------------------------------------------------------- 2. pure functions
head_ "2. Unit tests — parse_answers / resolve_model"
python3 - "$LAB" <<'PY'
import importlib.util, os, sys, pathlib
# These live in muse_core now. Load THAT module, not muse_fleet: muse_fleet only holds
# re-exported copies, and rebinding a copied constant there does not change what
# core.catalog_rows() reads -- which silently turned these tests into no-ops once.
spec=importlib.util.spec_from_file_location("mf", os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_core.py"))
mf=importlib.util.module_from_spec(spec); spec.loader.exec_module(mf)
fails=[]
def chk(n,c):
    print(("  PASS  " if c else "  FAIL  ")+n)
    if not c: fails.append(n)

pa=mf.parse_answers
chk("parse: single object",        pa('{"a":1}')=={"a":1})
chk("parse: concatenated -> last", pa('{"a":1}{"a":2}')=={"a":2})
chk("parse: whitespace separated", pa('{"a":1}\n {"a":2}')=={"a":2})
chk("parse: three -> last",        pa('{"a":1}{"a":2}{"a":3}')=={"a":3})
chk("parse: trailing prose",       pa('{"a":1} trailing')=={"a":1})
chk("parse: no json -> None",      pa('nothing')is None)
chk("parse: empty -> None",        pa('')is None)
chk("parse: nested objects",       pa('{"a":{"b":[1,2]}}')=={"a":{"b":[1,2]}})

d=pathlib.Path(sys.argv[1])/"vcat"; d.mkdir(parents=True, exist_ok=True)
(d/"c.json").write_text('{"rows":[{"model_id":"muse-spark-1.3-contributor","release_date":"2026-09-02","is_default":true,"visibility":"visible"},{"model_id":"muse-spark-9.0-contributor","release_date":"2029-01-01","is_default":false,"visibility":"visible"},{"model_id":"muse-spark-9.0","release_date":"2029-01-01","visibility":"visible"},{"model_id":"muse-spark-9.9-contributor","release_date":"2030-01-01","visibility":"hidden"}]}')
mf.CATALOG_GLOB=str(d/"*.json")
m,_=mf.resolve_model(mf.LATEST)
chk("model: picks newest contributor over is_default", m=="muse-spark-9.0-contributor")
chk("model: skips non-contributor",  m.endswith("-contributor"))
chk("model: skips hidden",           m!="muse-spark-9.9-contributor")
chk("model: explicit passes through", mf.resolve_model("foo")[0]=="foo")
mf.CATALOG_GLOB=str(pathlib.Path(sys.argv[1])/"nope"/"*.json")
chk("model: fallback when no catalog", mf.resolve_model(mf.LATEST)[0]==mf.FALLBACK_MODEL)
(d/"bad.json").write_text("{broken")
mf.CATALOG_GLOB=str(d/"bad.json")
mid,how=mf.resolve_model(mf.LATEST)
chk("model: survives corrupt catalog", mid==mf.FALLBACK_MODEL and how.startswith("fallback"))

# Self-test of the seam these tests depend on. FALLBACK_MODEL currently equals what the
# real catalog returns, so an override that silently stopped working would leave every
# assertion above passing on live data. Steering the glob must change the answer.
mf.CATALOG_GLOB=str(d/"c.json")
a=mf.resolve_model(mf.LATEST)[0]
mf.CATALOG_GLOB=str(pathlib.Path(sys.argv[1])/"nope"/"*.json")
b=mf.resolve_model(mf.LATEST)[0]
chk("CATALOG_GLOB is a live seam (overrides still steer resolution)", a!=b)
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] && PASS=$((PASS+15)) || FAIL=$((FAIL+1))

# muse_ask.sh reaches resolve_model by importing a module path; if that import breaks,
# it silently falls back to a hardcoded model id instead of failing.
python3 -c "
import importlib.util,os,sys
spec=importlib.util.spec_from_file_location('m', os.path.expanduser('$CORE'))
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
sys.exit(0 if m.resolve_model(m.LATEST)[0].endswith('-contributor') else 1)" \
  && ok "muse_ask's resolve_model import path works" || bad "muse_ask resolve import"

# ------------------------------------------------------------ 3. guardrails
# ------------------------------------------------- 2b. session plumbing (no muse spawned)
head_ "2b. Session resume plumbing"

# Reusing --session-id across `muse exec` calls continues the conversation, which is what
# lets a revision be a follow-up instead of a re-brief. These check the wiring; the live
# section checks that muse actually remembers.
SESSDATA="$LAB/v_sessdata"
mkdir -p "$SESSDATA/sessions/.msp-view-v1/11111111-1111-1111-1111-111111111111"
mkdir -p "$SESSDATA/sessions/2026/09/22/22222222-2222-2222-2222-222222222222"
MUSE_DATA_DIR="$SESSDATA" python3 - <<'PY' && ok "session_exists finds both storage layouts and rejects the rest" || bad "session_exists"
import importlib.util, os, sys, pathlib
spec = importlib.util.spec_from_file_location("mc", os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_core.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
checks = [
    ("view-index layout",  m.session_exists("11111111-1111-1111-1111-111111111111"), True),
    ("dated layout",       m.session_exists("22222222-2222-2222-2222-222222222222"), True),
    ("unknown id",         m.session_exists("33333333-3333-3333-3333-333333333333"), False),
    ("empty id",           m.session_exists(""),                                     False),
]
bad = [n for n, got, want in checks if got != want]
if bad:
    print("        wrong:", bad)
sys.exit(1 if bad else 0)
PY

# Muse refuses to resume a session bound to another workspace, and FAILS the run rather
# than starting fresh -- so treating "exists" as "resumable" burns a round for nothing.
WSDATA="$LAB/v_wsdata"
WSID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
mkdir -p "$WSDATA/sessions/.msp-view-v1/$WSID"
printf '{"x":{"viewCursor":"v:1","workspaceRoot":"%s/the-right-place"}}\n' "$LAB" \
  > "$WSDATA/sessions/.msp-view-v1/$WSID/snapshot-1.json"
mkdir -p "$LAB/the-right-place" "$LAB/somewhere-else"
MUSE_DATA_DIR="$WSDATA" python3 - "$LAB" "$WSID" <<'PY' && ok "a session bound to another workspace counts as not resumable" || bad "workspace binding ignored"
import importlib.util, os, sys
lab, sid = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("mc", os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_core.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
checks = [
    ("no workspace arg -> exists",   m.session_exists(sid),                                  True),
    ("matching workspace",           m.session_exists(sid, lab + "/the-right-place"),        True),
    ("different workspace",          m.session_exists(sid, lab + "/somewhere-else"),         False),
    ("workspace recorded",           m.session_workspace(sid) == lab + "/the-right-place",   True),
]
wrong = [n for n, got, want in checks if got != want]
if wrong: print("        wrong:", wrong)
sys.exit(1 if wrong else 0)
PY

# Muse rotates these snapshots. A stat() inside a sort key raises if one vanishes
# between the glob and the sort, and that FileNotFoundError came straight out of
# cmd_revise as a traceback -- exactly where a supervisor expects one JSON object.
ROT="$LAB/v_rotate"
ROTSID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
mkdir -p "$ROT/sessions/.msp-view-v1/$ROTSID"
printf '{"x":{"workspaceRoot":"%s/real"}}\n' "$LAB" \
  > "$ROT/sessions/.msp-view-v1/$ROTSID/snapshot-good.json"
ln -s "$ROT/sessions/.msp-view-v1/$ROTSID/gone.json" \
      "$ROT/sessions/.msp-view-v1/$ROTSID/snapshot-dangling.json" 2>/dev/null
MUSE_DATA_DIR="$ROT" python3 - "$LAB" "$ROTSID" <<'PY' && ok "a snapshot that vanishes mid-walk does not raise" || bad "session_workspace raised on a rotated snapshot"
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("mc", os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_core.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
lab, sid = sys.argv[1], sys.argv[2]
try:
    got = m.session_workspace(sid)
except Exception as e:
    print("        raised:", type(e).__name__, e); sys.exit(1)
sys.exit(0 if got == lab + "/real" else 1)
PY

python3 - <<'PY' && ok "muse_cmd carries --session-id only when given one" || bad "muse_cmd session wiring"
import importlib.util, os, sys, pathlib
spec = importlib.util.spec_from_file_location("mc", os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_core.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
wt = pathlib.Path(os.environ["PLUGIN_ROOT"]) / "not-a-real-worktree"
with_id = m.muse_cmd("mdl", "low", wt, session_id="abc-123")
without  = m.muse_cmd("mdl", "low", wt)
ok1 = "--session-id" in with_id and with_id[with_id.index("--session-id") + 1] == "abc-123"
ok2 = "--session-id" not in without
# A generated id must be a real uuid, not a placeholder that collides across tasks.
import uuid
try:
    uuid.UUID(m.new_session_id()); ok3 = m.new_session_id() != m.new_session_id()
except Exception:
    ok3 = False
sys.exit(0 if (ok1 and ok2 and ok3) else 1)
PY

# The fallback is the safety property: muse does not error on an unknown --session-id, it
# silently starts fresh, so a revision that assumed continuity would send bare feedback
# with no brief behind it.
grep -q 'REVISION_RESUMED_TEMPLATE' "$SKILL/scripts/muse_task.py" \
  && grep -q 'core.session_exists' "$SKILL/scripts/muse_task.py" \
  && ok "revise selects its prompt from a verified session, not an assumed one" \
  || bad "revise does not check session_exists"

python3 - <<'PY' && ok "the resumed prompt omits the brief and the fallback keeps it" || bad "revision templates"
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("mt", os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_task.py"))
mt = importlib.util.module_from_spec(spec); spec.loader.exec_module(mt)
resumed  = mt.REVISION_RESUMED_TEMPLATE.format(n=2, feedback="FB")
fallback = mt.REVISION_TEMPLATE.format(n=2, feedback="FB", brief="THEBRIEF")
sys.exit(0 if ("THEBRIEF" not in resumed and "{brief}" not in resumed
               and "THEBRIEF" in fallback) else 1)
PY

head_ "3. Preflight guardrails (no muse spawned)"

# core.preflight() checks `shutil.which("muse")` before it checks anything about the repo,
# so without muse on PATH every guard below reports "muse not found" and four real guards
# go untested -- which is exactly the environment CI and a new contributor have. This
# section spawns nothing, so a stub that satisfies the which() lookup is enough to reach
# the guards. If muse is genuinely installed, nothing here changes.
if ! command -v muse >/dev/null 2>&1; then
  make_muse_stub "$LAB/stub-bin"
  PATH="$(shell_path "$LAB/stub-bin"):$PATH"
  export PATH
  printf '  \033[33mNOTE\033[0m  muse not installed — using a stub so the repo guards stay testable\n'
fi

mkdir -p "$LAB/v_notgit"
echo '[{"id":"x","prompt":"noop"}]' > "$LAB/v_tasks.json"

cat > "$LAB/v_badschema.json" <<'EOF'
{"type":"object","required":["a"],"properties":{"a":{"type":"string"},"b":{"type":"string"}}}
EOF
out=$(python3 "$FLEET" --tasks "$LAB/v_tasks.json" --schema "$LAB/v_badschema.json" --repo "$LAB/v_notgit" 2>&1)
echo "$out" | grep -q 'must also appear in "required"' \
  && ok "rejects schema with optional field (before spawning)" \
  || bad "schema guard" "$out"

rm -rf "$LAB/v_notgit/.git"
out=$(python3 "$FLEET" --tasks "$LAB/v_tasks.json" --repo "$LAB/v_notgit" 2>&1)
echo "$out" | grep -qi 'not a git repository' \
  && ok "refuses a non-git directory" || bad "git guard" "$out"

mkrepo "$LAB/v_dirty"; echo "uncommitted" >> "$LAB/v_dirty/calc.py"
out=$(python3 "$FLEET" --tasks "$LAB/v_tasks.json" --repo "$LAB/v_dirty" 2>&1)
echo "$out" | grep -qi 'dirty' \
  && ok "refuses a dirty working copy" || bad "dirty guard" "$out"

out=$(python3 "$FLEET" --tasks "$LAB/v_tasks.json" --repo "$LAB/v_dirty" --allow-dirty --model echo-none 2>&1 | head -2)
echo "$out" | grep -q 'fleet:' && ok "--allow-dirty overrides the dirty refusal" || bad "allow-dirty" "$out"

cat > "$LAB/v_dup.json" <<'EOF'
[{"id":"a","prompt":"x"},{"id":"a","prompt":"y"}]
EOF
out=$(python3 "$FLEET" --tasks "$LAB/v_dup.json" --repo "$LAB/v_dirty" --allow-dirty 2>&1)
echo "$out" | grep -qi 'unique' && ok "rejects duplicate task ids" || bad "dup id guard" "$out"

# Seed a catalog rather than trusting the host's. On a machine with no muse install the
# old form of this check asserted "latest contributor" against a fallback path and failed
# for a correct reason, which is how it went red on CI's first run.
mkdir -p "$LAB/v_catalog"
cat > "$LAB/v_catalog/c.json" <<'CATALOG'
{"rows": [
  {"model_id": "muse-spark-9.9-contributor", "visibility": "visible", "release_date": "2030-01-01"},
  {"model_id": "muse-spark-0.1-contributor", "visibility": "visible", "release_date": "2020-01-01"},
  {"model_id": "muse-spark-9.9",             "visibility": "visible", "release_date": "2031-01-01"}
]}
CATALOG
out=$(MUSE_CATALOG_GLOB="$LAB/v_catalog/*.json" \
      python3 "$FLEET" --tasks "$LAB/v_tasks.json" --repo "$LAB/v_dirty" --allow-dirty 2>&1 | head -1)
echo "$out" | grep -q 'muse-spark-9.9-contributor' \
  && ok "resolves the newest CONTRIBUTOR model through the subprocess path" \
  || bad "default model resolution" "$out"

# os.killpg/os.getpgid/signal.SIGKILL are POSIX-only and absent on Windows as ATTRIBUTES,
# so touching them raises AttributeError -- which the OSError handler did not catch. A
# timeout handler that crashes turns a recoverable timeout into a lost run.
python3 - <<'PY' && ok "process-tree kill degrades instead of crashing without process groups" || bad "kill_process_tree raises where process groups are unavailable"
import importlib.util, os, subprocess, sys, time
real = {}
for name in ("killpg", "getpgid"):          # exactly what Windows lacks and we call
    if hasattr(os, name):
        real[name] = getattr(os, name); delattr(os, name)
try:
    spec = importlib.util.spec_from_file_location(
        "mc", os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_core.py"))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    if m.HAVE_PROCESS_GROUPS:
        print("        capability probe did not notice the missing attributes"); sys.exit(1)
    p = subprocess.Popen(["sh", "-c", "sleep 60"])
    time.sleep(0.3)
    m.kill_process_tree(p)                   # must not raise
    if p.poll() is None:
        print("        child survived the fallback kill"); sys.exit(1)
finally:
    for n, v in real.items(): setattr(os, n, v)
PY

# A 1-second stamp is not a unique namespace: two fleets started in the same second
# computed identical branches AND worktree paths, and run_task opens with drop_worktree,
# so the second silently force-removed the first's live worktrees.
python3 - <<'PY' && ok "fleet run stamps are unique within the same second" || bad "stamp collision still possible"
import importlib.util, os, re, sys
src = open(os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_fleet.py")).read()
# The stamp must carry entropy, not just a second-resolution clock.
if "secrets.token_hex" not in src:
    print("        stamp has no entropy source"); sys.exit(1)
import datetime as dt, secrets
# Mirror what muse_fleet actually does, including the width -- a test that samples less
# entropy than the code would pass while the code stayed weak.
import re as _re
width = int(_re.search(r"secrets\.token_hex\((\d+)\)", src).group(1))
if width < 4:
    print("        token_hex(%d) is too thin: ~1.9%% collision across 50 runs" % width)
    sys.exit(1)
mk = lambda: "{}-{}".format(dt.datetime.now().strftime("%Y%m%d-%H%M%S"), secrets.token_hex(width))
s = [mk() for _ in range(200)]
if len(set(s)) != len(s):
    print("        collided in 200 draws"); sys.exit(1)
# and must still sort chronologically on its time prefix
if [x[:15] for x in s] != sorted(x[:15] for x in s):
    print("        no longer chronological"); sys.exit(1)
PY

# Entropy handles the common case. This is the one it cannot: two runs handed the same
# explicit --out collide however unique the stamp is.
COL="$LAB/v_collide"; mkrepo "$COL"
printf '.muse-fleet/\n' >> "$COL/.git/info/exclude"
COLWT="$LAB/v_collide_wt"; mkdir -p "$COLWT"
# A REAL registered worktree, standing in for another run's live one. A plain directory
# does not reproduce the hazard: drop_worktree only removes worktrees git knows about, so
# the first version of this fixture survived even with the guard disabled, and git's own
# "already exists" error matched the assertion by coincidence.
git -C "$COL" worktree add -q -b "fleet/OTHERRUN/t1" "$COLWT/RUNX-t1" HEAD
echo "another run's in-flight work" > "$COLWT/RUNX-t1/PRECIOUS.txt"
cat > "$LAB/v_collide_tasks.json" <<'JSON'
[{"id":"t1","prompt":"noop"}]
JSON
python3 "$FLEET" --tasks "$LAB/v_collide_tasks.json" --repo "$COL" \
  --out "$LAB/v_collide/RUNX" --worktree-root "$COLWT" --allow-dirty >/dev/null 2>&1
[ -f "$COLWT/RUNX-t1/PRECIOUS.txt" ] \
  && ok "the fleet refuses a worktree another run is using instead of deleting it" \
  || bad "the fleet destroyed another run's live worktree"
python3 -c "
import json,sys
d=json.load(open('$LAB/v_collide/RUNX/report.json'))
t=d['tasks'][0]
sys.exit(0 if t['status']=='setup_failed' and 'already exists' in (t.get('reason') or '') else 1)
" 2>/dev/null && ok "the collision is reported as setup_failed, not silently skipped" \
  || bad "collision not reported in the fleet report"

# ------------------------------------------- 3b. status + cleanup (no muse spawned)
head_ "3b. Status and cleanup"

# Real git worktrees and real branches, with artifacts synthesised in the exact shape
# muse_task.py writes. No muse call is needed to exercise the reporting and reaping
# logic, and keeping these free means they run on every change rather than once a release.
SC="$LAB/v_sc"
mkrepo "$SC"
SCWT="$LAB/v_sc_wt"; mkdir -p "$SCWT"
SCOUT="$SC/.muse-fleet/tasks"
for spec in "muse/s/a:a:1:1" "muse/s/b:b:1:0" "fleet/s/c:c:0:0"; do
  IFS=: read -r br id fin ver <<< "$spec"
  git -C "$SC" worktree add -q -b "$br" "$SCWT/$id" HEAD
  mkdir -p "$SCOUT/$id"
  printf 'diff --git a/calc.py b/calc.py\n+x\n' > "$SCOUT/$id/patch.diff"
  python3 - "$SCOUT/$id" "$id" "$br" "$fin" "$ver" "$SC" "$SCWT/$id" <<'MKART'
import json, sys
d, tid, br, fin, ver, repo, wt = sys.argv[1:8]
fin, ver = fin == "1", ver == "1"
verifs = [{"after_round": 1, "command": "true", "exit_code": 0, "passed": True}] if ver else []
st = {"id": tid, "repo": repo, "worktree": wt, "branch": br, "base": "HEAD",
      "model": "m", "effort": "low", "max_rounds": 3, "rounds": [{"n": 1}],
      "verifications": verifs, "done": fin}
if fin:
    st.update({"verdict": "accept", "final_patch_lines": 2, "final_files_changed": ["calc.py"]})
open(d + "/state.json", "w").write(json.dumps(st))
if fin:
    open(d + "/task.json", "w").write(json.dumps({
        "id": tid, "verdict": "accept", "patch_lines": 2, "files_changed": ["calc.py"],
        "rounds_used": 1, "worktree": wt, "branch": br,
        "verified_by_supervisor": ver, "verifications": verifs}))
MKART
done

ST=$(cd "$SC" && python3 "$SKILL/scripts/muse_status.py" --out .muse-fleet 2>&1)
# The single most important thing this report does: an accept nobody checked must not
# read like a good run. If this stops firing, the report is actively misleading.
echo "$ST" | grep -q 'ACCEPTED WITHOUT AN EXECUTED CHECK' \
  && ok "status flags an accept with no executed check" || bad "unverified accept not flagged" "$ST"
echo "$ST" | grep -qE '^  a  \[accept\] verified' \
  && ok "status marks a genuinely verified task verified" || bad "verified task mislabelled" "$ST"

SJ=$(cd "$SC" && python3 "$SKILL/scripts/muse_status.py" --out .muse-fleet --json)
echo "$SJ" | python3 -c "
import json,sys; d=json.load(sys.stdin)
sys.exit(0 if len(d['tasks'])==3 else 1)" \
  && ok "status --json finds every task at either nesting depth" || bad "status --json task count"

# A dry run must be a dry run: the commonest way to lose delegated work is a reap that
# ran before anyone looked at it.
DRY=$(cd "$SC" && python3 "$SKILL/scripts/muse_cleanup.py" --repo . --out .muse-fleet 2>&1)
[ "$(git -C "$SC" worktree list | wc -l)" -eq 4 ] \
  && ok "cleanup dry run removes nothing" || bad "dry run removed worktrees"
echo "$DRY" | grep -q 'skipping 1 unfinished' \
  && ok "cleanup skips tasks with no verdict" || bad "unfinished task not skipped" "$DRY"

(cd "$SC" && python3 "$SKILL/scripts/muse_cleanup.py" --repo . --out .muse-fleet --yes >/dev/null 2>&1)
[ "$(git -C "$SC" worktree list | wc -l)" -eq 2 ] \
  && ok "cleanup --yes reaps finished tasks only" || bad "wrong worktree count after --yes"
git -C "$SC" branch --format='%(refname:short)' | grep -q '^fleet/s/c$' \
  && ok "unfinished task's branch survives --yes" || bad "unfinished branch deleted"

(cd "$SC" && python3 "$SKILL/scripts/muse_cleanup.py" --repo . --out .muse-fleet --yes --all --artifacts >/dev/null 2>&1)
[ "$(git -C "$SC" worktree list | wc -l)" -eq 1 ] \
  && ok "cleanup --all reaps the rest" || bad "worktrees left after --all"
[ ! -d "$SC/.muse-fleet" ] \
  && ok "cleanup --artifacts removes the artifact root" || bad "artifact root survived"

# Fixed scratch paths collide between users on a shared host and can be pre-created as
# symlinks before the suite writes them. LAB is already a mktemp dir; everything scratch
# belongs under it. The pattern is assembled at runtime so this guard does not match its
# own source line -- the first version of it did exactly that and failed on a clean tree.
# Matches any fixed scratch path, not just the v_ prefix the first version looked for --
# a "vcat" directory slipped past it and only surfaced on Windows, where native python
# read the MSYS path as a backslash literal. The pattern is assembled at runtime and this
# comment names no literal path, because BOTH earlier versions of this guard matched
# their own source. The trailing character class also means the TMPDIR fallback below,
# which ends in a brace, is not a hit.
TMPPAT="$(printf '/tmp/%s' '[A-Za-z0-9]')"
TMPLEAK=$(grep -nE "$TMPPAT" "$SKILL/scripts/validate.sh" || true)
[ -z "$TMPLEAK" ] \
  && ok "the suite writes no fixed scratch path (all of it is under \$LAB)" \
  || bad "a fixed scratch path crept back in" "$TMPLEAK"

# Numbers in prose rot: README and CONTRIBUTING both claimed "55 checks" long after the
# suite reached 65, and nothing noticed. The suite prints its own count, so the docs must
# not restate it. CHANGELOG is exempt -- a released version's count is a historical fact.
DRIFT=$(grep -rnE '[0-9]+ (free )?checks|[0-9]+/[0-9]+ offline' \
        "$SKILL/README.md" "$SKILL/CONTRIBUTING.md" "$SKILL/skills/muse-fleet/SKILL.md" \
        "$SKILL/.github/PULL_REQUEST_TEMPLATE.md" 2>/dev/null)
[ -z "$DRIFT" ] \
  && ok "no doc restates the check count (it rots; the suite prints it)" \
  || bad "a doc hardcodes a check count" "$DRIFT"

# Both of these produced a raw Python traceback or escaped the artifact root before.
# muse_task promises exactly one JSON object on stdout; a supervisor parses that stream,
# and a traceback or an empty stream tells it nothing.
EDG="$LAB/v_edge"; mkdir -p "$EDG"; git init -q -b main "$EDG"
EOUT=$(cd "$EDG" && python3 "$TASK" run --id x --repo "$EDG" --prompt noop 2>/dev/null)
echo "$EOUT" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if d.get('status')=='refused' and 'no commits' in d.get('reason','') else 1)" \
  && ok "a repo with no commits is refused in JSON, not a traceback" \
  || bad "empty repo did not refuse cleanly" "$EOUT"

# An id becomes a directory name and a git branch component.
TRAV="$LAB/v_trav"; mkrepo "$TRAV"
printf '.muse-fleet/\n' >> "$TRAV/.git/info/exclude"
TOUT=$(cd "$TRAV" && python3 "$TASK" run --id "../../ESCAPED" --repo "$TRAV" --prompt noop 2>/dev/null)
echo "$TOUT" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if d.get('status')=='refused' else 1)" \
  && ok "a task id with a path separator is refused" || bad "traversal id accepted" "$TOUT"
[ ! -d "$LAB/ESCAPED" ] && [ ! -d "$TRAV/ESCAPED" ] \
  && ok "no artifacts were written outside the artifact root" || bad "id escaped the artifact root"

python3 - <<'PY' && ok "task id validation accepts normal ids and rejects the dangerous shapes" || bad "validate_task_id logic"
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("mc", os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_core.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
good = ["tests-auth", "a", "mod_1.2", "A9"]
bad_ids = ["../x", "a/b", "", ".", "..", "-lead", "x" * 65, "a b", "x;rm -rf /", "a\nb"]
wrong = []
for g in good:
    try: m.validate_task_id(g)
    except Exception: wrong.append("rejected good: " + g)
for b in bad_ids:
    try:
        m.validate_task_id(b); wrong.append("accepted bad: %r" % b)
    except m.PreflightError: pass
if wrong: print("        ", wrong)
sys.exit(1 if wrong else 0)
PY

# Re-running an existing task id overwrote its harvested patch and orphaned its worktree,
# both silently. The lost patch may be work nobody applied yet.
CLB="$LAB/v_clobber"; mkrepo "$CLB"
printf '.muse/\n.muse-fleet/\n' >> "$CLB/.git/info/exclude"
mkdir -p "$CLB/.muse-fleet/tasks/dup" "$LAB/v_clobber_wt"
printf 'diff --git a/calc.py b/calc.py\n+precious\n' > "$CLB/.muse-fleet/tasks/dup/patch.diff"
python3 - "$CLB" "$LAB/v_clobber_wt/old" <<'PY'
import json, sys
repo, wt = sys.argv[1], sys.argv[2]
json.dump({"id":"dup","repo":repo,"worktree":wt,"branch":"muse/old/dup",
           "rounds":[{"n":1}],"verdict":"accept","done":True},
          open(repo + "/.muse-fleet/tasks/dup/state.json","w"))
PY
CLBOUT=$(cd "$CLB" && python3 "$TASK" run --id dup --repo "$CLB" --prompt noop 2>/dev/null)
echo "$CLBOUT" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if d.get('status')=='refused' else 1)" \
  && ok "run refuses to clobber an existing task's patch" || bad "run clobbered an existing task" "$CLBOUT"
grep -q precious "$CLB/.muse-fleet/tasks/dup/patch.diff" \
  && ok "the existing patch survived the refusal" || bad "existing patch was destroyed"

# The central guarantee: `accept` means a check PASSED, not that some check once did.
# Observed in a real run -- a supervisor ran a cheap `--collect-only` gate (exit 0) and
# then the real acceptance check (exit 1), and "any passed" marked the task verified.
VER="$LAB/v_ver"; mkdir -p "$VER/.muse-fleet/tasks/gate"
cat > "$VER/.muse-fleet/tasks/gate/state.json" <<'JSON'
{"id":"gate","done":true,"verdict":"accept","max_rounds":3,"rounds":[{"n":1,"kind":"initial"}],
 "verifications":[{"after_round":1,"command":"pytest --collect-only","exit_code":0,"passed":true},
                  {"after_round":1,"command":"pytest -q","exit_code":1,"passed":false}]}
JSON
cat > "$VER/.muse-fleet/tasks/gate/task.json" <<'JSON'
{"id":"gate","verdict":"accept","patch_lines":5,"files_changed":["a.py"],"rounds_used":1,
 "verified_by_supervisor":true,
 "verifications":[{"after_round":1,"command":"pytest --collect-only","exit_code":0,"passed":true},
                  {"after_round":1,"command":"pytest -q","exit_code":1,"passed":false}]}
JSON
VEROUT=$(python3 "$SKILL/scripts/muse_status.py" --out "$VER/.muse-fleet" 2>&1)
echo "$VEROUT" | grep -q 'UNVERIFIED' \
  && ok "a gate-passed/check-failed task reads UNVERIFIED, not verified" \
  || bad "a failing final check read as verified" "$VEROUT"
echo "$VEROUT" | grep -q 'final check FAILED' \
  && ok "status distinguishes a failed check from no check at all" \
  || bad "wrong wording for a failed final check"

python3 - <<'PY' && ok "finish records verified from the FINAL check, not any that passed" || bad "verified_by_supervisor uses any-passed"
import importlib.util, os, sys, re
src = open(os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_task.py")).read()
# The old form marked a task verified whenever ANY check had ever passed.
bad_form = re.search(r"verified\s*=\s*\[v for v in st\.get\(\"verifications\".*if v\.get\(\"passed\"\)\]", src)
good_form = "verifs[-1].get(\"passed\")" in src
sys.exit(0 if (good_form and not bad_form) else 1)
PY

# A revision that could not resume is a silent quality problem -- the worker got feedback
# and a re-sent brief but no memory of its own attempt, so it is closer to a fresh try
# than a correction. It must be visible in the report, not buried in state.json.
CTX="$LAB/v_ctx"; mkdir -p "$CTX/.muse-fleet/tasks/lost"
cat > "$CTX/.muse-fleet/tasks/lost/state.json" <<'JSON'
{"id":"lost","done":true,"verdict":"accept","session_id":"s1","max_rounds":3,
 "rounds":[{"n":1,"kind":"initial","resumed":false},
           {"n":2,"kind":"revision","resumed":true},
           {"n":3,"kind":"revision","resumed":false}],
 "verifications":[{"after_round":3,"command":"true","exit_code":0,"passed":true}]}
JSON
CTXOUT=$(python3 "$SKILL/scripts/muse_status.py" --out "$CTX/.muse-fleet" 2>&1)
echo "$CTXOUT" | grep -q 'could not resume the muse session' \
  && ok "status flags a revision that lost its session context" \
  || bad "lost context not surfaced" "$CTXOUT"
# Round 1 is legitimately unresumed and round 2 did resume; naming either is a false alarm.
echo "$CTXOUT" | grep -q 'round(s) 3 could not resume' \
  && ok "status names only the revision that actually lost context" \
  || bad "wrong rounds named" "$(echo "$CTXOUT" | grep 'could not resume')"

# --artifacts rmtree's a path the user named. A typo must not take a directory with it,
# so the marker-file check is the only thing between a mistyped --out and real data loss.
mkdir -p "$SC/not-artifacts" && echo precious > "$SC/not-artifacts/data.txt"
(cd "$SC" && python3 "$SKILL/scripts/muse_cleanup.py" --repo . --out not-artifacts --yes --artifacts >/dev/null 2>&1)
[ -f "$SC/not-artifacts/data.txt" ] \
  && ok "cleanup refuses to delete a root with no task markers" || bad "DELETED a non-artifact dir"

# --help must not spill source: the old fixed line range printed `set -uo pipefail`.
bash "$SKILL/scripts/muse_ask.sh" --help 2>/dev/null | grep -q 'set -uo pipefail' \
  && bad "muse_ask.sh --help leaks source lines" || ok "muse_ask.sh --help prints only the header"

head_ "3c. Data-loss and process guards"

# harvest ignored git's exit status, so a missing worktree or a held index.lock
# overwrote a good patch.diff with an empty file and reported "no changes".
HVD="$LAB/v_harvest"; mkdir -p "$HVD"
printf 'diff --git a/x b/x\n+real work\n' > "$HVD/patch.diff"
python3 - "$HVD" <<'PY' && ok "a failed harvest reports an error and preserves the patch" || bad "harvest clobbered on failure"
import importlib.util, os, pathlib, sys
spec = importlib.util.spec_from_file_location("mc", os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_core.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
d = pathlib.Path(sys.argv[1])
rec = m.harvest(d / "does-not-exist", "HEAD", [], d / "patch.diff")
kept = "real work" in (d / "patch.diff").read_text()
sys.exit(0 if (rec["harvest_error"] and kept) else 1)
PY

# `git branch -D` discards unmerged commits without asking, and the branch name can
# belong to something that is not this task.
BRC="$LAB/v_branch"; mkrepo "$BRC"
printf '.muse-fleet/\n' >> "$BRC/.git/info/exclude"
git -C "$BRC" branch "muse/20260101-120000/taken" >/dev/null 2>&1
BOUT=$(cd "$BRC" && python3 "$TASK" run --id taken --stamp 20260101-120000 --repo "$BRC" --prompt noop 2>/dev/null)
echo "$BOUT" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if d.get('status')=='refused' else 1)" \
  && ok "run refuses a branch name it did not create" || bad "run would delete a foreign branch" "$BOUT"
git -C "$BRC" branch --format='%(refname:short)' | grep -q 'taken' \
  && ok "the foreign branch survived" || bad "foreign branch was deleted"

# "exists but unreadable" is not "absent": treating it as absent silently defeated the
# re-run guard and overwrote the patch.
CRP="$LAB/v_corrupt"; mkrepo "$CRP"
printf '.muse-fleet/\n' >> "$CRP/.git/info/exclude"
mkdir -p "$CRP/.muse-fleet/tasks/c"; printf '{"broken' > "$CRP/.muse-fleet/tasks/c/state.json"
COUT=$(cd "$CRP" && python3 "$TASK" run --id c --repo "$CRP" --prompt noop 2>/dev/null)
echo "$COUT" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if d.get('status')=='refused' else 1)" \
  && ok "corrupt task state refuses rather than reading as absent" || bad "corrupt state bypassed the guard" "$COUT"
SOUT=$(cd "$CRP" && python3 "$TASK" show --id c 2>/dev/null)
echo "$SOUT" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if d.get('status')=='state_corrupt' else 1)" \
  && ok "corrupt state emits JSON on every subcommand, not a traceback" || bad "load_state broke the JSON contract" "$SOUT"

python3 - <<'PY' && ok "a timed-out or unharvestable round exits non-zero" || bad "dead round reported success"
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("mt", os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_task.py"))
mt = importlib.util.module_from_spec(spec); spec.loader.exec_module(mt)
cases = [({"status": "completed"}, 0), ({"status": "timeout"}, 1),
         ({"status": "no_terminal"}, 1), ({"status": "completed", "harvest_error": "x"}, 1)]
sys.exit(0 if all(mt.round_exit_code(o) == w for o, w in cases) else 1)
PY

# The marker check alone answered "yes" for $HOME -- an unbounded walk meets some stray
# state.json eventually -- which made `--yes --artifacts --out ~` an rmtree of it.
python3 - <<'PY' && ok "cleanup refuses \$HOME, / and a repo root as an artifact root" || bad "dangerous root not refused"
import importlib.util, os, pathlib, sys
spec = importlib.util.spec_from_file_location("mcl", os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_cleanup.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
home = pathlib.Path(os.path.expanduser("~"))
repo = pathlib.Path(os.environ["PLUGIN_ROOT"])
checks = [m.refuse_dangerous_root(home, repo), m.refuse_dangerous_root(pathlib.Path("/"), repo),
          m.refuse_dangerous_root(repo, repo)]
sys.exit(0 if all(c is not None for c in checks) else 1)
PY

grep -q '"state.json"' "$SKILL/scripts/muse_fleet.py" && grep -q '"task.json"' "$SKILL/scripts/muse_fleet.py" \
  && ok "the fleet writes the artifacts status and cleanup key on" \
  || bad "fleet worktrees remain invisible to status/cleanup"

head_ "3d. Doctor and credential scan"
# A diagnostic that only works on a healthy machine is not a diagnostic.
DOC="$SKILL/scripts/muse_doctor.py"
DLAB="$LAB/v_doctor"; mkdir -p "$DLAB/empty"
make_muse_stub "$DLAB/stubbin"

# The doctor is the tool you reach for when things are ALREADY broken, so the property
# that matters is that it never dies on the way to telling you. It must survive a hostile
# machine, including a binary called `muse` that exits 0 and prints nothing -- which CI
# has, because section 3 stubs one, and which crashed it with an IndexError.
# Note: asserting "exits 0 here" would be asserting the HOST is healthy, which CI's is
# deliberately not. Test the behaviour, not the host.
DOC_CRASHED=""
for COND in "healthy" "stub" "bare"; do
  case "$COND" in
    healthy) DOUT=$(python3 "$DOC" --repo "$SKILL" 2>&1) ;;
    stub)    DOUT=$(env PATH="$(shell_path "$DLAB/stubbin"):$PATH" python3 "$DOC" --repo "$SKILL" 2>&1) ;;
    bare)    DOUT=$(env PATH="$(minimal_path)" MUSE_CONFIG_DIR="$DLAB/nocfg" \
                    MUSE_CATALOG_GLOB="$DLAB/nocat/*.json" python3 "$DOC" --repo "$DLAB/empty" 2>&1) ;;
  esac
  case "$DOUT" in
    *Traceback*) DOC_CRASHED="$DOC_CRASHED $COND(traceback)" ;;
  esac
  case "$DOUT" in
    *READY*|*"NOT READY"*) : ;;
    *) DOC_CRASHED="$DOC_CRASHED $COND(no verdict)" ;;
  esac
done
[ -z "$DOC_CRASHED" ] \
  && ok "doctor reaches a verdict on a healthy, stubbed and bare machine" \
  || bad "doctor crashed or gave no verdict" "$DOC_CRASHED"

env PATH="$(minimal_path)" MUSE_CONFIG_DIR="$DLAB/nocfg" python3 "$DOC" --repo "$DLAB/empty" >/dev/null 2>&1
[ $? -ne 0 ] && ok "doctor exits non-zero when something is blocking" || bad "doctor reported a broken machine as ready"

# Well-formed regardless of verdict: a consumer parses this to decide what to do about a
# machine that is, by definition, possibly broken.
for COND in "$SKILL" "$DLAB/empty"; do
  DJSON=$(env MUSE_CONFIG_DIR="$DLAB/nocfg" python3 "$DOC" --repo "$COND" --json 2>/dev/null)
  echo "$DJSON" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert isinstance(d.get('checks'), list) and d['checks']
assert {'severity','name','value','fix'} <= set(d['checks'][0])
assert isinstance(d.get('ready'), bool)
assert all(c['severity'] in ('OK','WARN','FAIL') for c in d['checks'])
" 2>/dev/null || { bad "doctor --json shape" "$DJSON"; DJSON_BAD=1; }
done
[ -z "${DJSON_BAD:-}" ] && ok "doctor --json is well-formed whatever the verdict" || true

# The credential scan is the one that must not leak what it found into an artifact.
SCANDIR="$LAB/v_scan"; mkdir -p "$SCANDIR/sub" "$SCANDIR/node_modules"
printf 'AKIAIOSFODNN7EXAMPLE\n' > "$SCANDIR/sub/creds.txt"
printf -- '-----BEGIN RSA PRIVATE KEY-----\n' > "$SCANDIR/k.pem"
printf 'password = "averylongplaceholder"\n' > "$SCANDIR/sub/maybe.py"
printf 'AKIAIOSFODNN7EXAMPLE\n' > "$SCANDIR/node_modules/vendor.txt"
printf 'def f():\n    return 1\n' > "$SCANDIR/sub/clean.py"
python3 - "$SCANDIR" <<'PY' && ok "secret scan separates certain from possible and leaks neither" || bad "secret scan"
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("mc", os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_core.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
r = m.scan_secrets(sys.argv[1])
kinds = {f["kind"] for f in r["certain"]}
blob = json.dumps(r)
problems = []
if "AWS access key id" not in kinds: problems.append("missed AWS key")
if "private key block" not in kinds: problems.append("missed PEM header")
if not r["possible"]: problems.append("missed credential-shaped assignment")
if any("node_modules" in f["file"] for f in r["certain"]): problems.append("scanned node_modules")
if "AKIAIOSFODNN7EXAMPLE" in blob: problems.append("LEAKED the secret into its own findings")
if any("clean.py" in f["file"] for f in r["certain"]): problems.append("false positive on clean code")
if problems: print("        ", problems)
sys.exit(1 if problems else 0)
PY

# Refusing before spawning is the point: once sent, it is not undoable.
SECR="$LAB/v_secret"; mkrepo "$SECR"
printf '.muse-fleet/\n' >> "$SECR/.git/info/exclude"
printf 'AKIAIOSFODNN7EXAMPLE\n' > "$SECR/leaked.txt"
git -C "$SECR" add -A && git -C "$SECR" -c user.email=t@l -c user.name=t commit -qm creds >/dev/null 2>&1
SECOUT=$(cd "$SECR" && python3 "$TASK" run --id secret --repo "$SECR" --prompt noop 2>/dev/null)
echo "$SECOUT" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if d.get('status')=='refused' and d.get('secrets') else 1)" \
  && ok "run refuses to delegate a tree containing a confirmed credential" \
  || bad "run would have sent a credential" "$SECOUT"
[ "$(git -C "$SECR" worktree list | wc -l)" -eq 1 ] \
  && ok "the refused run left no worktree behind" || bad "refused run leaked a worktree"

# ------------------------------------------------------------ 4. live runs
if [ "$OFFLINE" = "1" ]; then
  printf '\n\033[33mSKIP\033[0m  sections 4+ (live muse runs) — --offline\n'
  printf '\n\033[1mRESULT: %d passed, %d failed (offline subset)\033[0m\n' "$PASS" "$FAIL"
  exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
fi

head_ "4. Live muse runs"
mkrepo "$LAB/v_live"
cat > "$LAB/v_live_tasks.json" <<'EOF'
[
 {"id":"mul","prompt":"Add multiply(a,b) to calc.py returning a*b. Minimal, nothing else."},
 {"id":"doc","prompt":"Create NOTES.md containing one sentence describing calc.py. Create no other file."}
]
EOF
python3 "$FLEET" --tasks "$LAB/v_live_tasks.json" --repo "$LAB/v_live" \
  --schema "$SKILL/assets/result-schema.json" --concurrency 2 --timeout 600 \
  > "$LAB/v_live.log" 2>&1
RC=$?
D=$(ls -d "$LAB/v_live/.muse-fleet"/*/ 2>/dev/null | tail -1)
STAMP1=$(basename "$D")

[ "$RC" -eq 0 ] && ok "fleet exited 0 (all tasks completed)" || bad "fleet exit=$RC" "$(tail -3 "$LAB/v_live.log")"
[ -z "$(git -C "$LAB/v_live" status --porcelain)" ] \
  && ok "main working copy stayed clean" || bad "main repo dirtied"
[ -f "$D/report.json" ] && ok "report.json written" || bad "no report.json"
[ -f "$D/report.md" ]   && ok "report.md written"   || bad "no report.md"

python3 - "$D" <<'PY' && ok "every task completed with a parsed result.json" || bad "task results"
import json,sys,os
d=sys.argv[1]; r=json.load(open(os.path.join(d,"report.json")))
bad=[t["id"] for t in r["tasks"] if t["status"]!="completed"]
missing=[t["id"] for t in r["tasks"] if not os.path.exists(os.path.join(d,t["id"],"result.json"))]
if bad or missing:
    print("        incomplete:",bad,"missing result.json:",missing); sys.exit(1)
PY

python3 - "$D" <<'PY' && ok "model recorded matches a contributor model" || bad "model record"
import json,sys,os
r=json.load(open(os.path.join(sys.argv[1],"report.json")))
sys.exit(0 if r["model"].endswith("-contributor") else 1)
PY

python3 - "$D" <<'PY' && ok "run_model_configured confirms the requested model" || bad "model actually used"
import json,sys,os
d=sys.argv[1]; r=json.load(open(os.path.join(d,"report.json")))
for t in r["tasks"]:
    if t.get("model_actual") and t["model_actual"]!=r["model"]:
        print("        asked",r["model"],"got",t["model_actual"]); sys.exit(1)
PY

for f in "$D"/*/patch.diff; do
  grep -qE '(^|/)\.venv/|node_modules/|__pycache__/' "$f" && { bad "build junk leaked into $(basename $(dirname $f))"; break; }
done
grep -rqE '(^|/)\.venv/' "$D"/*/patch.diff 2>/dev/null || ok "no build artifacts in any patch"

cd "$LAB/v_live"
APPLY_OK=1
for f in "$D"/*/patch.diff; do
  [ -s "$f" ] || continue
  git apply --check "$f" 2>/dev/null || APPLY_OK=0
done
[ "$APPLY_OK" -eq 1 ] && ok "all patches apply cleanly to base" || bad "a patch does not apply"
cd - >/dev/null

# This plugin's whole premise is cost arbitrage, and it reports no spend -- because muse
# exposes none. That is documented in README/CHANGELOG and in the issue as a hard block.
# The moment muse starts emitting usage, that documentation becomes false, and "find a
# doc that lies" is a defect class here. So this FAILS when the block lifts: the failure
# is the notification, and it costs nothing because it reads events the fleet already
# wrote.
python3 - "$D" <<'PY' && ok "muse still exposes no usage data (cost reporting stays blocked)" || bad "muse NOW EXPOSES USAGE — the docs claiming otherwise are stale"
import glob, os, re, sys
d = sys.argv[1]
found, scanned = {}, 0
for f in glob.glob(os.path.join(d, "*", "events.jsonl")):
    scanned += 1
    with open(f, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            # JSON KEYS only. The word "Usage:" appears in every --help banner and is not
            # what this is looking for.
            for m in re.finditer(r'"([a-z_]*(?:token|usage|cost)[a-z_]*)"\s*:', line, re.I):
                found[m.group(1)] = found.get(m.group(1), 0) + 1
if not scanned:
    print("        no events.jsonl to inspect — this probe checked nothing"); sys.exit(1)
if found:
    print("        usage-ish keys now present:", dict(list(found.items())[:8]))
    print("        Cost reporting is unblocked. Implement it in /muse:status and the")
    print("        fleet report, update README/CHANGELOG, and retire this check.")
    sys.exit(1)
sys.exit(0)
PY

head_ "5. Re-run safety"
python3 "$FLEET" --tasks "$LAB/v_live_tasks.json" --repo "$LAB/v_live" \
  --schema "$SKILL/assets/result-schema.json" --concurrency 2 --timeout 600 \
  --cleanup > "$LAB/v_live2.log" 2>&1
RC2=$?
[ "$RC2" -eq 0 ] && ok "second consecutive run succeeds (no branch/worktree collision)" \
  || bad "re-run exit=$RC2" "$(grep -i 'setup_failed\|already exists' "$LAB/v_live2.log" | head -2)"
# Only the --cleanup run's own artifacts should be gone. The first run deliberately
# ran without --cleanup, so its worktrees are expected to still be present.
STAMP2=$(basename "$(ls -d "$LAB/v_live/.muse-fleet"/*/ | tail -1)")
git -C "$LAB/v_live" worktree list | grep -q "$STAMP2" \
  && bad "--cleanup left its own worktrees ($STAMP2)" \
  || ok "--cleanup removed its own worktrees"
[ "$(git -C "$LAB/v_live" branch --list "fleet/$STAMP2/*" | wc -l | tr -d ' ')" = "0" ] \
  && ok "--cleanup removed its own branches" || bad "--cleanup left its own branches"
git -C "$LAB/v_live" worktree list | grep -q "$STAMP1" \
  && ok "run without --cleanup correctly retained its worktrees" \
  || bad "non-cleanup run lost its worktrees (harvest would be unrecoverable)"

head_ "6. Worktree seeding"
SEEDR="$LAB/v_seed"
mkrepo "$SEEDR"
# Deliberately NOT a credential-shaped value. An earlier version used
# API_KEY=secret123 and the probe asked the worker to write that value into a file --
# muse correctly refused to copy a secret, and the run failed as "seeding failed" even
# though .env had been copied in fine. The probe must test the mechanism, not the
# worker's willingness to handle credentials.
printf 'SEED_MARKER=seedok7391\n' > "$SEEDR/.env"
printf '.env\nnode_modules/\n' > "$SEEDR/.gitignore"
mkdir -p "$SEEDR/node_modules/pkg"; echo 1 > "$SEEDR/node_modules/pkg/i.js"
git -C "$SEEDR" add .gitignore
git -C "$SEEDR" -c user.email=t@l -c user.name=t commit -qm ignore

WT="$LAB/v_seed_wt"; rm -rf "$WT"
git -C "$SEEDR" worktree add -q -b seedprobe "$WT" main
[ ! -f "$WT/.env" ] && ok "fresh worktree correctly lacks untracked .env" \
  || bad "worktree unexpectedly had .env"
git -C "$SEEDR" worktree remove --force "$WT" 2>/dev/null; git -C "$SEEDR" branch -D seedprobe 2>/dev/null

cat > "$LAB/v_seed_tasks.json" <<'EOF'
[{"id":"envprobe","prompt":"If a .env file exists in this directory, create GOT.md containing exactly the value of SEED_MARKER. Otherwise create GOT.md containing MISSING. SEED_MARKER is a test fixture, not a credential."}]
EOF
python3 "$FLEET" --tasks "$LAB/v_seed_tasks.json" --repo "$SEEDR"   --seed .env --link node_modules --timeout 400 > "$LAB/v_seed.log" 2>&1
SD=$(ls -d "$SEEDR/.muse-fleet"/*/ | tail -1)
grep -q 'seedok7391' "$SD/envprobe/patch.diff" 2>/dev/null \
  && ok "--seed made .env readable inside the worktree" \
  || bad "seeding failed" "$(grep -h '^+' "$SD/envprobe/patch.diff" 2>/dev/null | head -2)"
grep -q '^+++ b/\.env' "$SD/envprobe/patch.diff" 2>/dev/null \
  && bad "seeded .env leaked into the patch" || ok "seeded .env did not leak into the patch"
grep -q 'node_modules' "$SD/envprobe/patch.diff" 2>/dev/null \
  && bad "linked node_modules leaked into the patch" || ok "linked node_modules did not leak"
python3 -c "
import json,sys
t=json.load(open('$SD/report.json'))['tasks'][0]
s=t.get('seeded') or []
sys.exit(0 if 'copied .env' in s and 'linked node_modules' in s else 1)" \
  && ok "report records what was seeded" || bad "seeded not recorded"

out=$(python3 "$FLEET" --tasks "$LAB/v_seed_tasks.json" --repo "$SEEDR" --allow-dirty 2>&1 | head -4)
echo "$out" | grep -q 'will NOT be in the worktrees' \
  && ok "warns about untracked files that will be absent" || bad "no seeding warning" "$out"

head_ "7. muse_ask.sh (single-shot)"
mkrepo "$LAB/v_ask"
ANS=$("$SKILL/scripts/muse_ask.sh" --repo "$LAB/v_ask" --effort low \
       "List the function names defined in calc.py, one per line. Nothing else." 2>"$LAB/v_ask.err")
RCA=$?
[ "$RCA" -eq 0 ] && ok "muse_ask exits 0 on success" || bad "muse_ask exit=$RCA" "$(cat "$LAB/v_ask.err")"
echo "$ANS" | grep -qi 'add' && ok "muse_ask returns a usable answer" || bad "muse_ask answer" "$ANS"
[ -z "$(git -C "$LAB/v_ask" status --porcelain)" ] \
  && ok "muse_ask read-only mode left the repo clean" || bad "muse_ask modified a read-only repo"

cat > "$LAB/v_ask_schema.json" <<'EOF'
{"type":"object","required":["functions"],"properties":{"functions":{"type":"array","items":{"type":"string"}}},"additionalProperties":false}
EOF
ANS2=$("$SKILL/scripts/muse_ask.sh" --repo "$LAB/v_ask" --effort low \
        --schema "$LAB/v_ask_schema.json" "List the function names defined in calc.py." 2>/dev/null)
echo "$ANS2" | python3 -c "
import json,sys
d=json.load(sys.stdin)
sys.exit(0 if isinstance(d.get('functions'),list) and d['functions'] else 1)" \
  && ok "muse_ask --schema returns parsed JSON" || bad "muse_ask schema" "$ANS2"

# NOT "hi": muse answers greetings from a local canned path in ~550ms without calling the
# provider, so a bogus model id is never validated and the run succeeds.
OUT=$("$SKILL/scripts/muse_ask.sh" --repo "$LAB/v_ask" --model muse-spark-9.9-contributor \
        "Reply with exactly: OK" 2>&1)
RCB=$?
[ "$RCB" -ne 0 ] && ok "muse_ask exits non-zero on a failed run" || bad "muse_ask masked a failure" "$OUT"

# Regression: the timeout watchdog must not inherit stdout, or command substitution
# stays blocked until the sleep expires even though muse exited seconds earlier.
TS=$(date +%s)
_=$("$SKILL/scripts/muse_ask.sh" --repo "$LAB/v_ask" --model muse-spark-9.9-contributor \
      --timeout 600 "Reply with exactly: OK" 2>/dev/null)
TE=$(( $(date +%s) - TS ))
[ "$TE" -lt 60 ] && ok "muse_ask returns as soon as muse exits (watchdog does not block \$( ))" \
  || bad "muse_ask blocked ${TE}s — watchdog is holding stdout"

# --------------------------------------------------- 8. the supervisor loop
# The architecture's load-bearing claim is that a revision round edits the PREVIOUS
# round's work rather than starting from a clean checkout. If that breaks, every
# multi-round task silently discards the work it was meant to build on, so this
# section exists to make that failure loud.
head_ "8. Supervised task loop (live)"
SLAB="$LAB/v_sup"; SOUT="$LAB/v_sup_out"; SWT="$LAB/v_sup_wt"
mkrepo "$SLAB"

R1=$(python3 "$TASK" run --id divide --out "$SOUT" --repo "$SLAB" --worktree-root "$SWT" \
       --max-rounds 2 --effort low \
       --prompt "Add a divide(a, b) function to calc.py returning a / b. Do not change add(). Create no other files." 2>/dev/null)
echo "$R1" | python3 -c "
import json,sys; d=json.load(sys.stdin)
sys.exit(0 if d['status']=='completed' and d['patch_lines']>0 else 1)" \
  && ok "run: muse produced a patch" || bad "run" "$R1"

V1=$(python3 "$TASK" verify --id divide --out "$SOUT" \
       --command "python3 -c 'import calc; print(calc.divide(10,2))'" 2>/dev/null)
echo "$V1" | python3 -c "
import json,sys; d=json.load(sys.stdin)
sys.exit(0 if d['passed'] and d['exit_code']==0 and d['after_round']==1 else 1)" \
  && ok "verify: check runs inside the worktree and is recorded" || bad "verify" "$V1"

R2=$(python3 "$TASK" revise --id divide --out "$SOUT" \
       --feedback "divide() must raise ValueError('division by zero') when b == 0. Keep all other behaviour." 2>/dev/null)
echo "$R2" | python3 -c "
import json,sys; d=json.load(sys.stdin)
sys.exit(0 if d['round']==2 and d['kind']=='revision' and d['status']=='completed' else 1)" \
  && ok "revise: second round ran in the same worktree" || bad "revise" "$R2"

# Both assertions in one command: the revision must be present AND round 1's work must
# have survived it. This is the regression that matters.
V2=$(python3 "$TASK" verify --id divide --out "$SOUT" --command "python3 -c \"
import calc
assert calc.divide(10,2) == 5
assert calc.add(1,2) == 3
try:
    calc.divide(1,0); raise SystemExit('no ValueError')
except ValueError: print('ok')
\"" 2>/dev/null)
echo "$V2" | python3 -c "
import json,sys; d=json.load(sys.stdin)
sys.exit(0 if d['passed'] else 1)" \
  && ok "revision is cumulative — round 1's work survived round 2" \
  || bad "revision clobbered round 1" "$V2"

BRK=$(python3 "$TASK" revise --id divide --out "$SOUT" --feedback "one more" 2>/dev/null)
echo "$BRK" | python3 -c "
import json,sys; d=json.load(sys.stdin)
sys.exit(0 if d['status']=='max_rounds_exhausted' else 1)" \
  && ok "max-rounds breaker refuses a third round" || bad "breaker did not fire" "$BRK"

FIN=$(python3 "$TASK" finish --id divide --out "$SOUT" --verdict accept --summary "divide added" 2>/dev/null)
echo "$FIN" | python3 -c "
import json,sys; d=json.load(sys.stdin)
sys.exit(0 if d['verdict']=='accept' and d['verified_by_supervisor'] and len(d['verifications'])==2 else 1)" \
  && ok "finish: verdict records the checks the supervisor actually ran" || bad "finish" "$FIN"

grep -q 'def divide' "$SLAB/calc.py" 2>/dev/null \
  && bad "task leaked into the source repo" \
  || ok "source repo untouched — work stayed in the worktree"

python3 "$TASK" cleanup --id divide --out "$SOUT" >/dev/null 2>&1
[ "$(git -C "$SLAB" worktree list | wc -l)" -eq 1 ] \
  && ok "cleanup removed the worktree" || bad "worktree left behind"

# An accept with no executed check must stay visible rather than reading like a good run.
python3 "$TASK" run --id noverify --out "$SOUT" --repo "$SLAB" --worktree-root "$SWT" \
  --prompt "Add a noop() function to calc.py that returns None." >/dev/null 2>&1
FIN2=$(python3 "$TASK" finish --id noverify --out "$SOUT" --verdict accept --cleanup 2>/dev/null)
echo "$FIN2" | python3 -c "
import json,sys; d=json.load(sys.stdin)
sys.exit(0 if d['verified_by_supervisor'] is False else 1)" \
  && ok "unverified accept is flagged, not hidden" || bad "unverified accept looked verified" "$FIN2"

head_ "9. Session resume (live)"
# The offline section proves the flag is wired. This proves muse actually remembers:
# the codeword exists ONLY in round 1's brief, never on disk, and the revision prompt
# does not restate it. If it lands in the patch, the conversation was continued.
SSLAB="$LAB/v_sess"; SSOUT="$SSLAB/.muse-fleet/tasks"
mkrepo "$SSLAB"
python3 "$TASK" run --id resume --out "$SSOUT" --repo "$SSLAB" --worktree-root "$LAB/v_sess_wt" \
  --prompt "Add a function named alpha_v1() to calc.py that returns the integer 7. Change nothing else. Also note this codeword for later: TIGERMOTH-9." \
  > "$LAB/v_sess1.json" 2>/dev/null
SID=$(python3 -c "import json;print(json.load(open('$LAB/v_sess1.json')).get('session_id') or '')" 2>/dev/null)
[ -n "$SID" ] && ok "run mints a session id and reports it" || bad "no session id on run"

python3 "$TASK" revise --id resume --out "$SSOUT" \
  --feedback "Add a Python comment line directly above alpha_v1 containing the codeword I gave you earlier. Nothing else." \
  > "$LAB/v_sess2.json" 2>/dev/null
python3 -c "
import json,sys
d=json.load(open('$LAB/v_sess2.json'))
sys.exit(0 if d.get('resumed') is True else 1)" \
  && ok "revise reports the session resumed" || bad "revise did not resume"

grep -q 'TIGERMOTH' "$SSOUT/resume/round-2/prompt.txt" \
  && bad "the revision prompt restated the brief (resume saved nothing)" \
  || ok "the revision prompt omits the brief"

grep -q 'TIGERMOTH' "$SSOUT/resume/patch.diff" \
  && ok "worker recalled a codeword that exists nowhere on disk" \
  || bad "codeword absent from patch — the session did not carry context"

# The safety path: muse does not error on an unknown session id, it silently starts fresh.
# A FRESH uuid every run. A hardcoded one stops being fake the moment an earlier run
# writes a real session under it -- which happened here, and muse then refused to resume
# it across workspaces instead of starting fresh, so the test measured the wrong thing.
DEADSID=$(python3 -c "import uuid;print(uuid.uuid4())")
python3 -c "
import json,sys
p='$SSOUT/resume/state.json'; st=json.load(open(p))
st['session_id']=sys.argv[1]
json.dump(st, open(p,'w'), indent=2)" "$DEADSID"
python3 "$TASK" revise --id resume --out "$SSOUT" \
  --feedback "Change the returned integer from 7 to 8." > "$LAB/v_sess3.json" 2>/dev/null
python3 -c "
import json,sys
d=json.load(open('$LAB/v_sess3.json'))
sys.exit(0 if d.get('resumed') is False and d.get('session_warning') else 1)" \
  && ok "an unresumable session is reported, not assumed" || bad "missing session went unreported"
grep -q 'TIGERMOTH' "$SSOUT/resume/round-3/prompt.txt" \
  && ok "fallback re-sends the full brief" || bad "fallback lost the brief"


printf '\n\033[1mRESULT: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
