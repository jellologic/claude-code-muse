#!/usr/bin/env bash
# Full validation of the muse plugin. Offline checks first (fast, free),
# then live muse runs (slow, costs tokens).
set -uo pipefail

# Self-locate rather than trusting an install path: this script must validate the copy
# it actually ships inside, not whatever other copy happens to be installed.
SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PLUGIN_ROOT="$SKILL"
SKILL_MD="$SKILL/skills/muse-fleet/SKILL.md"
FLEET="$SKILL/scripts/muse_fleet.py"
TASK="$SKILL/scripts/muse_task.py"
CORE="$SKILL/scripts/muse_core.py"
# `mktemp -d -t NAME` is BSD-only: GNU coreutils rejects a template with no trailing X's
# and prints nothing, which silently left LAB empty. Every path below is built from it, so
# an empty LAB turned "$LAB/v_dirty" into "/v_dirty" -- and mkrepo starts with `rm -rf`.
LAB="${MUSE_FLEET_LAB:-$(mktemp -d "${TMPDIR:-/tmp}/musefleetlab.XXXXXX")}"
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
  python3 - > /tmp/v_wf.mjs <<'PY'
import re, pathlib, os
t = pathlib.Path(os.path.join(os.environ["PLUGIN_ROOT"], "references/workflow.md")).read_text()
b = re.findall(r"```javascript\n(.*?)```", t, re.S)[0].replace("export const meta", "const meta", 1)
# The runtime evaluates the body inside an async function, so top-level await and return
# are legal there but not in a bare module. Reproduce that shape or the check is a lie.
print("const agent=()=>{},parallel=()=>{},pipeline=()=>{},phase=()=>{},log=()=>{},args={};")
print("async function __body(){"); print(b); print("}")
PY
  node --check /tmp/v_wf.mjs 2>/dev/null \
    && ok "workflow.md script parses as the runtime evaluates it" || bad "workflow script syntax"

  # meta.phases titles are matched EXACTLY against phase() calls; a drifted title
  # silently splits the progress display into an orphan group instead of erroring.
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
python3 - <<'PY'
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

d=pathlib.Path("/tmp/vcat"); d.mkdir(exist_ok=True)
(d/"c.json").write_text('{"rows":[{"model_id":"muse-spark-1.3-contributor","release_date":"2026-09-02","is_default":true,"visibility":"visible"},{"model_id":"muse-spark-9.0-contributor","release_date":"2029-01-01","is_default":false,"visibility":"visible"},{"model_id":"muse-spark-9.0","release_date":"2029-01-01","visibility":"visible"},{"model_id":"muse-spark-9.9-contributor","release_date":"2030-01-01","visibility":"hidden"}]}')
mf.CATALOG_GLOB="/tmp/vcat/*.json"
m,_=mf.resolve_model(mf.LATEST)
chk("model: picks newest contributor over is_default", m=="muse-spark-9.0-contributor")
chk("model: skips non-contributor",  m.endswith("-contributor"))
chk("model: skips hidden",           m!="muse-spark-9.9-contributor")
chk("model: explicit passes through", mf.resolve_model("foo")[0]=="foo")
mf.CATALOG_GLOB="/tmp/nope/*.json"
chk("model: fallback when no catalog", mf.resolve_model(mf.LATEST)[0]==mf.FALLBACK_MODEL)
(d/"bad.json").write_text("{broken")
mf.CATALOG_GLOB="/tmp/vcat/bad.json"
mid,how=mf.resolve_model(mf.LATEST)
chk("model: survives corrupt catalog", mid==mf.FALLBACK_MODEL and how.startswith("fallback"))

# Self-test of the seam these tests depend on. FALLBACK_MODEL currently equals what the
# real catalog returns, so an override that silently stopped working would leave every
# assertion above passing on live data. Steering the glob must change the answer.
mf.CATALOG_GLOB="/tmp/vcat/c.json"
a=mf.resolve_model(mf.LATEST)[0]
mf.CATALOG_GLOB="/tmp/nope/*.json"
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

python3 - <<'PY' && ok "muse_cmd carries --session-id only when given one" || bad "muse_cmd session wiring"
import importlib.util, os, sys, pathlib
spec = importlib.util.spec_from_file_location("mc", os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_core.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
with_id = m.muse_cmd("mdl", "low", pathlib.Path("/tmp/wt"), session_id="abc-123")
without  = m.muse_cmd("mdl", "low", pathlib.Path("/tmp/wt"))
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
  mkdir -p "$LAB/stub-bin"
  printf '#!/bin/sh\nexit 0\n' > "$LAB/stub-bin/muse"
  chmod +x "$LAB/stub-bin/muse"
  PATH="$LAB/stub-bin:$PATH"
  export PATH
  printf '  \033[33mNOTE\033[0m  muse not installed — using a stub so the repo guards stay testable\n'
fi

echo '[{"id":"x","prompt":"noop"}]' > /tmp/v_tasks.json

cat > /tmp/v_badschema.json <<'EOF'
{"type":"object","required":["a"],"properties":{"a":{"type":"string"},"b":{"type":"string"}}}
EOF
out=$(python3 "$FLEET" --tasks /tmp/v_tasks.json --schema /tmp/v_badschema.json --repo /tmp 2>&1)
echo "$out" | grep -q 'must also appear in "required"' \
  && ok "rejects schema with optional field (before spawning)" \
  || bad "schema guard" "$out"

mkdir -p /tmp/v_notgit && rm -rf /tmp/v_notgit/.git
out=$(python3 "$FLEET" --tasks /tmp/v_tasks.json --repo /tmp/v_notgit 2>&1)
echo "$out" | grep -qi 'not a git repository' \
  && ok "refuses a non-git directory" || bad "git guard" "$out"

mkrepo "$LAB/v_dirty"; echo "uncommitted" >> "$LAB/v_dirty/calc.py"
out=$(python3 "$FLEET" --tasks /tmp/v_tasks.json --repo "$LAB/v_dirty" 2>&1)
echo "$out" | grep -qi 'dirty' \
  && ok "refuses a dirty working copy" || bad "dirty guard" "$out"

out=$(python3 "$FLEET" --tasks /tmp/v_tasks.json --repo "$LAB/v_dirty" --allow-dirty --model echo-none 2>&1 | head -2)
echo "$out" | grep -q 'fleet:' && ok "--allow-dirty overrides the dirty refusal" || bad "allow-dirty" "$out"

cat > /tmp/v_dup.json <<'EOF'
[{"id":"a","prompt":"x"},{"id":"a","prompt":"y"}]
EOF
out=$(python3 "$FLEET" --tasks /tmp/v_dup.json --repo "$LAB/v_dirty" --allow-dirty 2>&1)
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
      python3 "$FLEET" --tasks /tmp/v_tasks.json --repo "$LAB/v_dirty" --allow-dirty 2>&1 | head -1)
echo "$out" | grep -q 'muse-spark-9.9-contributor' \
  && ok "resolves the newest CONTRIBUTOR model through the subprocess path" \
  || bad "default model resolution" "$out"

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

# --artifacts rmtree's a path the user named. A typo must not take a directory with it,
# so the marker-file check is the only thing between a mistyped --out and real data loss.
mkdir -p "$SC/not-artifacts" && echo precious > "$SC/not-artifacts/data.txt"
(cd "$SC" && python3 "$SKILL/scripts/muse_cleanup.py" --repo . --out not-artifacts --yes --artifacts >/dev/null 2>&1)
[ -f "$SC/not-artifacts/data.txt" ] \
  && ok "cleanup refuses to delete a root with no task markers" || bad "DELETED a non-artifact dir"

# --help must not spill source: the old fixed line range printed `set -uo pipefail`.
bash "$SKILL/scripts/muse_ask.sh" --help 2>/dev/null | grep -q 'set -uo pipefail' \
  && bad "muse_ask.sh --help leaks source lines" || ok "muse_ask.sh --help prints only the header"

# ------------------------------------------------------------ 4. live runs
if [ "$OFFLINE" = "1" ]; then
  printf '\n\033[33mSKIP\033[0m  sections 4+ (live muse runs) — --offline\n'
  printf '\n\033[1mRESULT: %d passed, %d failed (offline subset)\033[0m\n' "$PASS" "$FAIL"
  exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
fi

head_ "4. Live muse runs"
mkrepo "$LAB/v_live"
cat > /tmp/v_live_tasks.json <<'EOF'
[
 {"id":"mul","prompt":"Add multiply(a,b) to calc.py returning a*b. Minimal, nothing else."},
 {"id":"doc","prompt":"Create NOTES.md containing one sentence describing calc.py. Create no other file."}
]
EOF
python3 "$FLEET" --tasks /tmp/v_live_tasks.json --repo "$LAB/v_live" \
  --schema "$SKILL/assets/result-schema.json" --concurrency 2 --timeout 600 \
  > /tmp/v_live.log 2>&1
RC=$?
D=$(ls -d "$LAB/v_live/.muse-fleet"/*/ 2>/dev/null | tail -1)
STAMP1=$(basename "$D")

[ "$RC" -eq 0 ] && ok "fleet exited 0 (all tasks completed)" || bad "fleet exit=$RC" "$(tail -3 /tmp/v_live.log)"
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

head_ "5. Re-run safety"
python3 "$FLEET" --tasks /tmp/v_live_tasks.json --repo "$LAB/v_live" \
  --schema "$SKILL/assets/result-schema.json" --concurrency 2 --timeout 600 \
  --cleanup > /tmp/v_live2.log 2>&1
RC2=$?
[ "$RC2" -eq 0 ] && ok "second consecutive run succeeds (no branch/worktree collision)" \
  || bad "re-run exit=$RC2" "$(grep -i 'setup_failed\|already exists' /tmp/v_live2.log | head -2)"
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

cat > /tmp/v_seed_tasks.json <<'EOF'
[{"id":"envprobe","prompt":"If a .env file exists in this directory, create GOT.md containing exactly the value of SEED_MARKER. Otherwise create GOT.md containing MISSING. SEED_MARKER is a test fixture, not a credential."}]
EOF
python3 "$FLEET" --tasks /tmp/v_seed_tasks.json --repo "$SEEDR"   --seed .env --link node_modules --timeout 400 > /tmp/v_seed.log 2>&1
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

out=$(python3 "$FLEET" --tasks /tmp/v_seed_tasks.json --repo "$SEEDR" --allow-dirty 2>&1 | head -4)
echo "$out" | grep -q 'will NOT be in the worktrees' \
  && ok "warns about untracked files that will be absent" || bad "no seeding warning" "$out"

head_ "7. muse_ask.sh (single-shot)"
mkrepo "$LAB/v_ask"
ANS=$("$SKILL/scripts/muse_ask.sh" --repo "$LAB/v_ask" --effort low \
       "List the function names defined in calc.py, one per line. Nothing else." 2>/tmp/v_ask.err)
RCA=$?
[ "$RCA" -eq 0 ] && ok "muse_ask exits 0 on success" || bad "muse_ask exit=$RCA" "$(cat /tmp/v_ask.err)"
echo "$ANS" | grep -qi 'add' && ok "muse_ask returns a usable answer" || bad "muse_ask answer" "$ANS"
[ -z "$(git -C "$LAB/v_ask" status --porcelain)" ] \
  && ok "muse_ask read-only mode left the repo clean" || bad "muse_ask modified a read-only repo"

cat > /tmp/v_ask_schema.json <<'EOF'
{"type":"object","required":["functions"],"properties":{"functions":{"type":"array","items":{"type":"string"}}},"additionalProperties":false}
EOF
ANS2=$("$SKILL/scripts/muse_ask.sh" --repo "$LAB/v_ask" --effort low \
        --schema /tmp/v_ask_schema.json "List the function names defined in calc.py." 2>/dev/null)
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
  > /tmp/v_sess1.json 2>/dev/null
SID=$(python3 -c "import json;print(json.load(open('/tmp/v_sess1.json')).get('session_id') or '')" 2>/dev/null)
[ -n "$SID" ] && ok "run mints a session id and reports it" || bad "no session id on run"

python3 "$TASK" revise --id resume --out "$SSOUT" \
  --feedback "Add a Python comment line directly above alpha_v1 containing the codeword I gave you earlier. Nothing else." \
  > /tmp/v_sess2.json 2>/dev/null
python3 -c "
import json,sys
d=json.load(open('/tmp/v_sess2.json'))
sys.exit(0 if d.get('resumed') is True else 1)" \
  && ok "revise reports the session resumed" || bad "revise did not resume"

grep -q 'TIGERMOTH' "$SSOUT/resume/round-2/prompt.txt" \
  && bad "the revision prompt restated the brief (resume saved nothing)" \
  || ok "the revision prompt omits the brief"

grep -q 'TIGERMOTH' "$SSOUT/resume/patch.diff" \
  && ok "worker recalled a codeword that exists nowhere on disk" \
  || bad "codeword absent from patch — the session did not carry context"

# The safety path: muse does not error on an unknown session id, it silently starts fresh.
python3 -c "
import json
p='$SSOUT/resume/state.json'; st=json.load(open(p))
st['session_id']='00000000-dead-beef-0000-000000000000'
json.dump(st, open(p,'w'), indent=2)"
python3 "$TASK" revise --id resume --out "$SSOUT" \
  --feedback "Change the returned integer from 7 to 8." > /tmp/v_sess3.json 2>/dev/null
python3 -c "
import json,sys
d=json.load(open('/tmp/v_sess3.json'))
sys.exit(0 if d.get('resumed') is False and d.get('session_warning') else 1)" \
  && ok "an unresumable session is reported, not assumed" || bad "missing session went unreported"
grep -q 'TIGERMOTH' "$SSOUT/resume/round-3/prompt.txt" \
  && ok "fallback re-sends the full brief" || bad "fallback lost the brief"


printf '\n\033[1mRESULT: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
