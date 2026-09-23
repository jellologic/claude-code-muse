# shellcheck shell=bash
# Exercises the muse hooks through the real scripts, never their source text.
# Every stdout assertion discards stderr (2>/dev/null); stdout JSON is parsed
# with python3 json.loads, never grepped out of a 2>&1 capture, so a mutant
# that moves the JSON to stderr (M06) fails the parse instead of passing.
HK_STANDALONE=0
if ! declare -F ok >/dev/null 2>&1; then
  HK_STANDALONE=1
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
  mkrepo() {
    rm -rf "$1"; mkdir -p "$1"; git init -q -b main "$1"
    printf 'def add(a,b):\n    return a+b\n' > "$1/calc.py"
    git -C "$1" add -A
    git -C "$1" -c user.email=t@l -c user.name=t commit -qm init
  }
  make_muse_stub() {
    mkdir -p "$1"
    printf '#!/bin/sh\nexit 0\n' > "$1/muse"
    chmod +x "$1/muse"
    if command -v cygpath >/dev/null 2>&1; then
      printf '@echo off\r\nexit /b 0\r\n' > "$1/muse.cmd"
    fi
  }
fi

HK_BASE="$LAB/v_hooks_cases"
HK="$HK_BASE/proj"
HK_POST="$HK_BASE/post"
HK_MAL="$HK_BASE/mal"
HK_WT="$HK_BASE/wt"
rm -rf "$HK_BASE"; mkdir -p "$HK_BASE"

# -- 1. registration ---------------------------------------------------------
HK_REG="$(python3 - "$SKILL" <<'PY' 2>/dev/null
import json, sys
sk = sys.argv[1]
h = json.load(open(sk + "/hooks/hooks.json"))
ev = h.get("hooks", {})
print(json.dumps({"keys": sorted(ev.keys())}))
PY
)"
if printf '%s' "$HK_REG" | grep -q 'SessionStart' && printf '%s' "$HK_REG" | grep -q 'SubagentStop' && printf '%s' "$HK_REG" | grep -q 'PostToolUse' && ! printf '%s' "$HK_REG" | grep -q 'SessionEnd'; then
  ok "hooks: SessionStart, SubagentStop and PostToolUse are registered and SessionEnd is not"
else
  bad "hooks: SessionStart, SubagentStop and PostToolUse are registered and SessionEnd is not" "keys=$HK_REG"
fi

HK_EXEC="$(python3 - "$SKILL" <<'PY' 2>/dev/null
import json, os, sys
sk = sys.argv[1]
h = json.load(open(sk + "/hooks/hooks.json"))
bad = []
for ev, entries in h.get("hooks", {}).items():
    for e in entries:
        for hook in e.get("hooks", []):
            if not hook.get("timeout"):
                bad.append("%s: no timeout" % ev)
            cmd = hook.get("command", "")
            if "${CLAUDE_PLUGIN_ROOT}" in cmd or " " in cmd or not cmd:
                bad.append("%s: command not exec form: %r" % (ev, cmd))
            args = hook.get("args", [])
            if not args or not args[0].startswith("${CLAUDE_PLUGIN_ROOT}/hooks/"):
                bad.append("%s: args missing plugin-root hook path" % ev)
            else:
                rel = args[0].replace("${CLAUDE_PLUGIN_ROOT}/", "")
                if not os.path.isfile(os.path.join(sk, rel)):
                    bad.append("%s: hook file missing: %s" % (ev, rel))
print("OK" if not bad else "; ".join(bad))
PY
)"
if [ "$HK_EXEC" = "OK" ]; then
  ok "hooks: every hook uses exec form with timeout and an existing file"
else
  bad "hooks: every hook uses exec form with timeout and an existing file" "$HK_EXEC"
fi

# -- 2. matcher semantics ----------------------------------------------------
HK_MATCH="$(python3 - "$SKILL" <<'PY' 2>/dev/null
import json, re, sys
h = json.load(open(sys.argv[1] + "/hooks/hooks.json"))
def fires(matcher, name):
    if re.fullmatch(r"[A-Za-z0-9_|, -]*", matcher):
        return name in [p.strip() for p in re.split(r"[|,]", matcher)]
    return re.search(matcher, name) is not None
sub = h["hooks"]["SubagentStop"][0].get("matcher", "")
post = h["hooks"]["PostToolUse"][0].get("matcher", "")
print(json.dumps({
  "sub_hits_plugin": fires(sub, "muse:muse-supervisor"),
  "sub_hits_bare": fires(sub, "muse-supervisor"),
  "sub_hits_other": fires(sub, "general-purpose"),
  "post_hits_agent": fires(post, "Agent"),
  "post_hits_bash": fires(post, "Bash"),
}))
PY
)"
HK_SUB_PLUGIN="$(printf '%s' "$HK_MATCH" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sub_hits_plugin"])' 2>/dev/null)"
HK_SUB_BARE="$(printf '%s' "$HK_MATCH" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sub_hits_bare"])' 2>/dev/null)"
HK_SUB_OTHER="$(printf '%s' "$HK_MATCH" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sub_hits_other"])' 2>/dev/null)"
if [ "$HK_SUB_PLUGIN" = "True" ] && [ "$HK_SUB_BARE" = "False" ] && [ "$HK_SUB_OTHER" = "False" ]; then
  ok "hooks: SubagentStop matcher matches the plugin agent type only"
else
  bad "hooks: SubagentStop matcher matches the plugin agent type only" "match=$HK_MATCH"
fi

# The matcher under test is read from hooks.json, never hard-coded: the
# evaluator below applies the documented rule (a matcher made only of
# [A-Za-z0-9_|, -] is an exact-name list, anything else is a regex searched
# against the name) and reports whether the registered SubagentStop matcher
# fires for the plugin agent type. Reverting hooks.json to the legacy value
# must turn it red -- the self-test underneath proves the guard can fire.
hk_eval_matcher() {
  python3 - "$1" <<'PY' 2>/dev/null
import json, re, sys
h = json.load(open(sys.argv[1]))
m = h["hooks"]["SubagentStop"][0].get("matcher", "")
def fires(matcher, name):
    if re.fullmatch(r"[A-Za-z0-9_|, -]*", matcher):
        return name in [p.strip() for p in re.split(r"[|,]", matcher)]
    return re.search(matcher, name) is not None
print("MATCH" if fires(m, "muse:muse-supervisor") else "NOMATCH")
PY
}
HK_NEW_MATCH="$(hk_eval_matcher "$SKILL/hooks/hooks.json")"
if [ "$HK_NEW_MATCH" = "MATCH" ]; then
  ok "hooks: the registered SubagentStop matcher fires for the plugin agent type"
else
  bad "hooks: the registered SubagentStop matcher fires for the plugin agent type" "eval=$HK_NEW_MATCH"
fi

HK_LEGACY_JSON="$HK_BASE/legacy_hooks.json"
cp "$SKILL/hooks/hooks.json" "$HK_LEGACY_JSON"
python3 - "$HK_LEGACY_JSON" <<'PY' 2>/dev/null
import json, sys
p = sys.argv[1]
h = json.load(open(p))
h["hooks"]["SubagentStop"][0]["matcher"] = "muse-supervisor"
json.dump(h, open(p, "w"))
PY
HK_LEGACY_MATCH="$(hk_eval_matcher "$HK_LEGACY_JSON")"
if [ "$HK_LEGACY_MATCH" = "NOMATCH" ]; then
  ok "hooks: the matcher check fails on the legacy hooks.json"
else
  bad "hooks: the matcher check fails on the legacy hooks.json" "eval=$HK_LEGACY_MATCH"
fi

HK_POST_A="$(printf '%s' "$HK_MATCH" | python3 -c 'import json,sys; print(json.load(sys.stdin)["post_hits_agent"])' 2>/dev/null)"
HK_POST_B="$(printf '%s' "$HK_MATCH" | python3 -c 'import json,sys; print(json.load(sys.stdin)["post_hits_bash"])' 2>/dev/null)"
if [ "$HK_POST_A" = "True" ] && [ "$HK_POST_B" = "False" ]; then
  ok "hooks: PostToolUse matcher matches Agent only"
else
  bad "hooks: PostToolUse matcher matches Agent only" "match=$HK_MATCH"
fi

# -- 3-7. SubagentStop block / guard / cap / ownership / finished ------------
mkrepo "$HK"
printf '.muse-fleet/\n' >> "$HK/.git/info/exclude"
mkdir -p "$HK/.muse-fleet/tasks/stopped"
cat > "$HK/.muse-fleet/tasks/stopped/state.json" <<'JSON'
{"id":"stopped","done":false,"branch":"muse/20260101-aaaa/stopped","rounds":[{"n":1}]}
JSON
printf 'run %s ok\n' "muse/20260101-aaaa/stopped" > "$HK_BASE/transcript.jsonl"
HK_TR_NATIVE="$(native_path "$HK_BASE/transcript.jsonl")"
HK_STOP_IN="$HK_BASE/stop.json"
python3 - "$HK_TR_NATIVE" > "$HK_STOP_IN" <<'PY' 2>/dev/null
import json, sys
print(json.dumps({"hook_event_name": "SubagentStop", "agent_type": "muse:muse-supervisor",
                  "stop_hook_active": False, "agent_transcript_path": sys.argv[1]}))
PY

HK_OUT1="$(CLAUDE_PROJECT_DIR="$HK" python3 "$SKILL/hooks/supervisor_stop.py" < "$HK_STOP_IN" 2>/dev/null)"
HK_RC1=$?
HK_DEC1="$(printf '%s' "$HK_OUT1" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("decision",""))' 2>/dev/null)"
HK_REASON1="$(printf '%s' "$HK_OUT1" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("reason",""))' 2>/dev/null)"
if [ "$HK_RC1" -eq 0 ] && [ "$HK_DEC1" = "block" ] && printf '%s' "$HK_REASON1" | grep -q 'stopped' && printf '%s' "$HK_REASON1" | grep -q '1 round'; then
  ok "hooks: SubagentStop blocks a supervisor that owns an unfinished task"
else
  bad "hooks: SubagentStop blocks a supervisor that owns an unfinished task" "rc=$HK_RC1 out=$HK_OUT1"
fi

# Loop guard: the same input with stop_hook_active true stays silent. The
# non-empty assertion above is what makes the emptiness below meaningful.
HK_GUARD_IN="$HK_BASE/guard.json"
python3 - "$HK_TR_NATIVE" > "$HK_GUARD_IN" <<'PY' 2>/dev/null
import json, sys
print(json.dumps({"hook_event_name": "SubagentStop", "agent_type": "muse:muse-supervisor",
                  "stop_hook_active": True, "agent_transcript_path": sys.argv[1]}))
PY
HK_GUARD_OUT="$(CLAUDE_PROJECT_DIR="$HK" python3 "$SKILL/hooks/supervisor_stop.py" < "$HK_GUARD_IN" 2>/dev/null)"
if [ -n "$HK_OUT1" ] && [ -z "$HK_GUARD_OUT" ]; then
  ok "hooks: SubagentStop stays silent when stop_hook_active is set"
else
  bad "hooks: SubagentStop stays silent when stop_hook_active is set" "out=$HK_GUARD_OUT"
fi

# Cap: the first block above was call 1; call 2 still blocks, call 3 is silent.
HK_OUT2="$(CLAUDE_PROJECT_DIR="$HK" python3 "$SKILL/hooks/supervisor_stop.py" < "$HK_STOP_IN" 2>/dev/null)"
HK_DEC2="$(printf '%s' "$HK_OUT2" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("decision",""))' 2>/dev/null)"
if [ -n "$HK_OUT1" ] && [ "$HK_DEC2" = "block" ]; then
  ok "hooks: SubagentStop blocks at most twice per task"
else
  bad "hooks: SubagentStop blocks at most twice per task" "out=$HK_OUT2"
fi
HK_OUT3="$(CLAUDE_PROJECT_DIR="$HK" python3 "$SKILL/hooks/supervisor_stop.py" < "$HK_STOP_IN" 2>/dev/null)"
if [ -n "$HK_OUT2" ] && [ -z "$HK_OUT3" ]; then
  ok "hooks: SubagentStop lets go after the cap"
else
  bad "hooks: SubagentStop lets go after the cap" "out=$HK_OUT3"
fi

# Ownership: a sibling task absent from the transcript is never named. The cap
# file is reset so the owned task blocks first and the assertion has teeth.
rm -f "$HK/.muse-fleet/tasks/stopped/stop_hook_blocks.json"
mkdir -p "$HK/.muse-fleet/tasks/sibling"
cat > "$HK/.muse-fleet/tasks/sibling/state.json" <<'JSON'
{"id":"sibling","done":false,"branch":"muse/20260101-aaaa/sibling","rounds":[{"n":2}]}
JSON
HK_OWN_OUT="$(CLAUDE_PROJECT_DIR="$HK" python3 "$SKILL/hooks/supervisor_stop.py" < "$HK_STOP_IN" 2>/dev/null)"
HK_OWN_REASON="$(printf '%s' "$HK_OWN_OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("reason",""))' 2>/dev/null)"
if [ -n "$HK_OWN_OUT" ] && printf '%s' "$HK_OWN_REASON" | grep -q 'stopped' && ! printf '%s' "$HK_OWN_REASON" | grep -q 'sibling'; then
  ok "hooks: SubagentStop does not block over a sibling supervisor's task"
else
  bad "hooks: SubagentStop does not block over a sibling supervisor's task" "out=$HK_OWN_OUT"
fi

# Finished tasks never block, even when the transcript names their branch.
mkdir -p "$HK/.muse-fleet/tasks/fin"
cat > "$HK/.muse-fleet/tasks/fin/state.json" <<'JSON'
{"id":"fin","done":true,"branch":"muse/20260101-aaaa/fin","rounds":[{"n":1}]}
JSON
cat > "$HK/.muse-fleet/tasks/fin/task.json" <<'JSON'
{"id":"fin","verdict":"accept","verified_by_supervisor":true}
JSON
printf 'run %s ok\n' "muse/20260101-aaaa/fin" > "$HK_BASE/transcript_fin.jsonl"
HK_FIN_IN="$HK_BASE/fin.json"
python3 - "$(native_path "$HK_BASE/transcript_fin.jsonl")" > "$HK_FIN_IN" <<'PY' 2>/dev/null
import json, sys
print(json.dumps({"hook_event_name": "SubagentStop", "agent_type": "muse:muse-supervisor",
                  "stop_hook_active": False, "agent_transcript_path": sys.argv[1]}))
PY
HK_FIN_OUT="$(CLAUDE_PROJECT_DIR="$HK" python3 "$SKILL/hooks/supervisor_stop.py" < "$HK_FIN_IN" 2>/dev/null)"
if [ -z "$HK_FIN_OUT" ]; then
  ok "hooks: SubagentStop stays silent for finished tasks"
else
  bad "hooks: SubagentStop stays silent for finished tasks" "out=$HK_FIN_OUT"
fi

# -- prefix ownership: sibling branches share one stamp prefix ---------------
# fleet/S/api is a strict prefix of fleet/S/api-docs, so a substring test
# blocks both whenever the transcript names one. The hook must block only
# the owner, in both directions.
HK_PFX="$HK_BASE/prefix"
mkrepo "$HK_PFX"
printf '.muse-fleet/\n' >> "$HK_PFX/.git/info/exclude"
mkdir -p "$HK_PFX/.muse-fleet/supervised/S/api" "$HK_PFX/.muse-fleet/supervised/S/api-docs"
printf '{"id":"api","done":false,"branch":"fleet/S/api","rounds":[{"n":1}]}' > "$HK_PFX/.muse-fleet/supervised/S/api/state.json"
printf '{"id":"api-docs","done":false,"branch":"fleet/S/api-docs","rounds":[{"n":1}]}' > "$HK_PFX/.muse-fleet/supervised/S/api-docs/state.json"
hk_stop_ids() {
  printf '%s' "$1" | python3 -c 'import json,shlex,sys; ids=set()
for line in json.loads(sys.stdin.read()).get("reason","").splitlines():
    if line.startswith("muse-task finish"):
        argv = shlex.split(line.split(" --verdict")[0])
        ids.update(argv[i+1] for i,a in enumerate(argv[:-1]) if a == "--id")
print(",".join(sorted(ids)))' 2>/dev/null
}
HK_PFX_OK=1; HK_PFX_WHY=""
printf '{"branch": "fleet/S/api-docs"}\n' > "$HK_BASE/transcript_docs.jsonl"
HK_DOCS_IN="$HK_BASE/docs.json"
python3 - "$(native_path "$HK_BASE/transcript_docs.jsonl")" > "$HK_DOCS_IN" <<'PY' 2>/dev/null
import json, sys
print(json.dumps({"hook_event_name": "SubagentStop", "agent_type": "muse:muse-supervisor",
                  "stop_hook_active": False, "agent_transcript_path": sys.argv[1]}))
PY
rm -f "$HK_PFX/.muse-fleet/supervised/S/api/stop_hook_blocks.json" "$HK_PFX/.muse-fleet/supervised/S/api-docs/stop_hook_blocks.json"
HK_DOCS_OUT="$(CLAUDE_PROJECT_DIR="$HK_PFX" python3 "$SKILL/hooks/supervisor_stop.py" < "$HK_DOCS_IN" 2>/dev/null)"
if [ "$(hk_stop_ids "$HK_DOCS_OUT")" != "api-docs" ]; then HK_PFX_OK=0; HK_PFX_WHY="$HK_PFX_WHY docs-ids=$(hk_stop_ids "$HK_DOCS_OUT")"; fi
printf '{"branch": "fleet/S/api"}\n' > "$HK_BASE/transcript_api.jsonl"
HK_API_IN="$HK_BASE/api.json"
python3 - "$(native_path "$HK_BASE/transcript_api.jsonl")" > "$HK_API_IN" <<'PY' 2>/dev/null
import json, sys
print(json.dumps({"hook_event_name": "SubagentStop", "agent_type": "muse:muse-supervisor",
                  "stop_hook_active": False, "agent_transcript_path": sys.argv[1]}))
PY
rm -f "$HK_PFX/.muse-fleet/supervised/S/api/stop_hook_blocks.json" "$HK_PFX/.muse-fleet/supervised/S/api-docs/stop_hook_blocks.json"
HK_API_OUT="$(CLAUDE_PROJECT_DIR="$HK_PFX" python3 "$SKILL/hooks/supervisor_stop.py" < "$HK_API_IN" 2>/dev/null)"
if [ "$(hk_stop_ids "$HK_API_OUT")" != "api" ]; then HK_PFX_OK=0; HK_PFX_WHY="$HK_PFX_WHY api-ids=$(hk_stop_ids "$HK_API_OUT")"; fi
if [ "$HK_PFX_OK" -eq 1 ]; then
  ok "hooks: SubagentStop blocks only the owner when task ids share a prefix"
else
  bad "hooks: SubagentStop blocks only the owner when task ids share a prefix" "$HK_PFX_WHY"
fi

# -- one finish command per owned task ---------------------------------------
# finish takes a single --id and fleet tasks need their stamp dir as --out,
# so the reason must carry one runnable muse-task line per owned task whose
# --out resolves to that task's parent dir.
printf 'saw fleet/S/api and fleet/S/api-docs\n' > "$HK_BASE/transcript_both.jsonl"
HK_BOTH_IN="$HK_BASE/both.json"
python3 - "$(native_path "$HK_BASE/transcript_both.jsonl")" > "$HK_BOTH_IN" <<'PY' 2>/dev/null
import json, sys
print(json.dumps({"hook_event_name": "SubagentStop", "agent_type": "muse:muse-supervisor",
                  "stop_hook_active": False, "agent_transcript_path": sys.argv[1]}))
PY
rm -f "$HK_PFX/.muse-fleet/supervised/S/api/stop_hook_blocks.json" "$HK_PFX/.muse-fleet/supervised/S/api-docs/stop_hook_blocks.json"
HK_BOTH_OUT="$(CLAUDE_PROJECT_DIR="$HK_PFX" python3 "$SKILL/hooks/supervisor_stop.py" < "$HK_BOTH_IN" 2>/dev/null)"
printf '%s' "$HK_BOTH_OUT" > "$HK_BASE/both_out.json"
HK_BOTH_RES="$(python3 - "$HK_BASE/both_out.json" "$HK_PFX" <<'PY' 2>/dev/null
import json, os, shlex, sys
reason = json.load(open(sys.argv[1])).get("reason", "")
proj = sys.argv[2]
parent = os.path.join(proj, ".muse-fleet", "supervised", "S")
seen = {}
bad = ""
count = 0
for line in reason.splitlines():
    if not line.startswith("muse-task finish"):
        continue
    count += 1
    try:
        argv = shlex.split(line.split(" --verdict")[0])
    except ValueError:
        bad = "unshlexable"; break
    if argv[:2] != ["muse-task", "finish"] or argv.count("--id") != 1 or argv.count("--out") != 1:
        bad = "shape: " + line; break
    tid = argv[argv.index("--id") + 1]
    out = argv[argv.index("--out") + 1]
    try:
        same = os.path.samefile(out, parent)
    except OSError:
        same = False
    if not same:
        bad = "out: " + out; break
    seen[tid] = True
print("OK" if not bad and count == 2 and sorted(seen) == ["api", "api-docs"] else (bad or ("count: %d ids: %s" % (count, ",".join(sorted(seen))))))
PY
)"
if [ "$HK_BOTH_RES" = "OK" ]; then
  ok "hooks: SubagentStop gives one finish command per owned task"
else
  bad "hooks: SubagentStop gives one finish command per owned task" "$HK_BOTH_RES out=$HK_BOTH_OUT"
fi

# -- 8. malformed input never crashes -----------------------------------------
mkrepo "$HK_MAL"
printf '.muse-fleet/\n' >> "$HK_MAL/.git/info/exclude"
mkdir -p "$HK_MAL/.muse-fleet/tasks/m" "$HK_MAL/.muse-fleet/tasks/lst" "$HK_MAL/.muse-fleet/tasks/locked" "$HK_MAL/.muse-fleet/tasks/zgood"
printf '{"id":"m","done":false,"rounds":5}' > "$HK_MAL/.muse-fleet/tasks/m/state.json"
printf '{"id":"lst","done":false,"rounds":[{"n":1}]}' > "$HK_MAL/.muse-fleet/tasks/lst/state.json"
printf '[1,2]' > "$HK_MAL/.muse-fleet/tasks/lst/task.json"
printf '{"id":"locked","done":false,"rounds":[{"n":1}]}' > "$HK_MAL/.muse-fleet/tasks/locked/state.json"
printf '{"id":"zgood","done":false,"branch":"muse/20260101-aaaa/zgood","rounds":[{"n":1}]}' > "$HK_MAL/.muse-fleet/tasks/zgood/state.json"
chmod 000 "$HK_MAL/.muse-fleet/tasks/locked" 2>/dev/null || true
printf 'run %s ok\n' "muse/20260101-aaaa/zgood" > "$HK_BASE/transcript_mal.jsonl"
HK_MAL_IN="$HK_BASE/mal.json"
python3 - "$(native_path "$HK_BASE/transcript_mal.jsonl")" > "$HK_MAL_IN" <<'PY' 2>/dev/null
import json, sys
print(json.dumps({"hook_event_name": "SubagentStop", "agent_type": "muse:muse-supervisor",
                  "stop_hook_active": False, "agent_transcript_path": sys.argv[1]}))
PY
HK_MAL_OK=1
HK_MAL_WHY=""
printf 'not json at all' > "$HK_BASE/notjson.txt"
rm -f "$HK_MAL/.muse-fleet/tasks/zgood/stop_hook_blocks.json"
for HK_CASE in valid notjson; do
  if [ "$HK_CASE" = "valid" ]; then HK_IN="$HK_MAL_IN"; else HK_IN="$HK_BASE/notjson.txt"; fi
  HK_MOUT="$(CLAUDE_PROJECT_DIR="$HK_MAL" python3 "$SKILL/hooks/supervisor_stop.py" < "$HK_IN" 2>"$HK_BASE/mal_stop.err")"
  HK_MRC=$?
  if [ "$HK_MRC" -ne 0 ]; then HK_MAL_OK=0; HK_MAL_WHY="$HK_MAL_WHY stop/$HK_CASE rc=$HK_MRC"; fi
  if grep -q 'Traceback' "$HK_BASE/mal_stop.err" 2>/dev/null; then HK_MAL_OK=0; HK_MAL_WHY="$HK_MAL_WHY stop/$HK_CASE traceback"; fi
  if ! printf '%s' "$HK_MOUT" | python3 -c 'import json,sys; d=sys.stdin.read(); sys.exit(0 if not d.strip() else (0 if json.loads(d) else 1))' 2>/dev/null; then HK_MAL_OK=0; HK_MAL_WHY="$HK_MAL_WHY stop/$HK_CASE badjson"; fi
  if [ "$HK_CASE" = "valid" ]; then
    HK_MDEC="$(printf '%s' "$HK_MOUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("decision",""))' 2>/dev/null)"
    HK_MREASON="$(printf '%s' "$HK_MOUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("reason",""))' 2>/dev/null)"
    if [ "$HK_MDEC" != "block" ] || ! printf '%s' "$HK_MREASON" | grep -q 'zgood'; then HK_MAL_OK=0; HK_MAL_WHY="$HK_MAL_WHY stop/valid missed-zgood"; fi
  else
    if [ -n "$HK_MOUT" ]; then HK_MAL_OK=0; HK_MAL_WHY="$HK_MAL_WHY stop/notjson not-empty"; fi
  fi
done
chmod 755 "$HK_MAL/.muse-fleet/tasks/locked" 2>/dev/null || true
if [ "$HK_MAL_OK" -eq 1 ]; then
  ok "hooks: malformed input never crashes supervisor_stop.py"
else
  bad "hooks: malformed input never crashes supervisor_stop.py" "$HK_MAL_WHY"
fi

HK_RES_OK=1
HK_RES_WHY=""
HK_RES_IN="$HK_BASE/mal_post.json"
printf '{"hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"subagent_type":"muse:muse-supervisor"},"tool_response":{"content":[{"type":"text","text":"run muse/20260101-aaaa/zgood ok"}]}}' > "$HK_RES_IN"
chmod 000 "$HK_MAL/.muse-fleet/tasks/locked" 2>/dev/null || true
for HK_CASE in valid notjson; do
  if [ "$HK_CASE" = "valid" ]; then HK_IN="$HK_RES_IN"; else HK_IN="$HK_BASE/notjson.txt"; fi
  HK_ROUT="$(CLAUDE_PROJECT_DIR="$HK_MAL" python3 "$SKILL/hooks/supervisor_result.py" < "$HK_IN" 2>"$HK_BASE/mal_res.err")"
  HK_RRC=$?
  if [ "$HK_RRC" -ne 0 ]; then HK_RES_OK=0; HK_RES_WHY="$HK_RES_WHY result/$HK_CASE rc=$HK_RRC"; fi
  if grep -q 'Traceback' "$HK_BASE/mal_res.err" 2>/dev/null; then HK_RES_OK=0; HK_RES_WHY="$HK_RES_WHY result/$HK_CASE traceback"; fi
  if ! printf '%s' "$HK_ROUT" | python3 -c 'import json,sys; d=sys.stdin.read(); sys.exit(0 if not d.strip() else (0 if json.loads(d) else 1))' 2>/dev/null; then HK_RES_OK=0; HK_RES_WHY="$HK_RES_WHY result/$HK_CASE badjson"; fi
  if [ "$HK_CASE" = "valid" ]; then
    HK_RCTX="$(printf '%s' "$HK_ROUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' 2>/dev/null)"
    if ! printf '%s' "$HK_RCTX" | grep -q 'zgood'; then HK_RES_OK=0; HK_RES_WHY="$HK_RES_WHY result/valid missed-zgood"; fi
  else
    if [ -n "$HK_ROUT" ]; then HK_RES_OK=0; HK_RES_WHY="$HK_RES_WHY result/notjson not-empty"; fi
  fi
done
chmod 755 "$HK_MAL/.muse-fleet/tasks/locked" 2>/dev/null || true
if [ "$HK_RES_OK" -eq 1 ]; then
  ok "hooks: malformed input never crashes supervisor_result.py"
else
  bad "hooks: malformed input never crashes supervisor_result.py" "$HK_RES_WHY"
fi

# -- 9-10. PostToolUse notes and filter ---------------------------------------
mkrepo "$HK_POST"
printf '.muse-fleet/\n' >> "$HK_POST/.git/info/exclude"
mkdir -p "$HK_POST/.muse-fleet/tasks/unverified" "$HK_POST/.muse-fleet/tasks/clean"
printf '{"id":"unverified","done":true,"branch":"muse/20260101-aaaa/unverified","rounds":[{"n":1}]}' > "$HK_POST/.muse-fleet/tasks/unverified/state.json"
printf '{"id":"unverified","verdict":"accept","verified_by_supervisor":false}' > "$HK_POST/.muse-fleet/tasks/unverified/task.json"
printf '{"id":"clean","done":true,"branch":"muse/20260101-aaaa/clean","rounds":[{"n":1}]}' > "$HK_POST/.muse-fleet/tasks/clean/state.json"
printf '{"id":"clean","verdict":"accept","verified_by_supervisor":true}' > "$HK_POST/.muse-fleet/tasks/clean/task.json"
HK_POST_IN="$HK_BASE/post.json"
printf '{"hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"subagent_type":"muse:muse-supervisor"},"tool_response":{"content":[{"type":"text","text":"supervised muse/20260101-aaaa/unverified done"}]}}' > "$HK_POST_IN"
HK_POST_OUT="$(CLAUDE_PROJECT_DIR="$HK_POST" python3 "$SKILL/hooks/supervisor_result.py" < "$HK_POST_IN" 2>/dev/null)"
HK_POST_EV="$(printf '%s' "$HK_POST_OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["hookEventName"])' 2>/dev/null)"
HK_POST_CTX="$(printf '%s' "$HK_POST_OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' 2>/dev/null)"
if printf '%s' "$HK_POST_CTX" | grep -q 'unverified' && printf '%s' "$HK_POST_CTX" | grep -q 'WITHOUT a passing check' && [ "$HK_POST_EV" = "PostToolUse" ] && ! printf '%s\n' "$HK_POST_CTX" | grep -q -- '- clean:'; then
  ok "hooks: PostToolUse reports an accept without a passing check"
else
  bad "hooks: PostToolUse reports an accept without a passing check" "out=$HK_POST_OUT"
fi

HK_FILT_IN="$HK_BASE/filt.json"
printf '{"hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"subagent_type":"general-purpose"},"tool_response":{"content":[{"type":"text","text":"supervised muse/20260101-aaaa/unverified done"}]}}' > "$HK_FILT_IN"
HK_FILT_OUT="$(CLAUDE_PROJECT_DIR="$HK_POST" python3 "$SKILL/hooks/supervisor_result.py" < "$HK_FILT_IN" 2>/dev/null)"
if [ -n "$HK_POST_OUT" ] && [ -z "$HK_FILT_OUT" ]; then
  ok "hooks: PostToolUse ignores other subagent types"
else
  bad "hooks: PostToolUse ignores other subagent types" "out=$HK_FILT_OUT"
fi

mkrepo "$HK_BASE/empty"
HK_EMPTY_OUT="$(CLAUDE_PROJECT_DIR="$HK_BASE/empty" python3 "$SKILL/hooks/supervisor_result.py" < "$HK_POST_IN" 2>/dev/null)"
if [ -z "$HK_EMPTY_OUT" ]; then
  ok "hooks: PostToolUse is silent on a clean project"
else
  bad "hooks: PostToolUse is silent on a clean project" "out=$HK_EMPTY_OUT"
fi

# -- PostToolUse ownership: only the returning supervisor's task ------------
# Mine is unfinished, the sibling is an accept without a passing check, but
# the returning result names only my branch -- the sibling still has a
# supervisor working on it and must not be reported.
HK_OWN="$HK_BASE/own"
mkrepo "$HK_OWN"
printf '.muse-fleet/\n' >> "$HK_OWN/.git/info/exclude"
mkdir -p "$HK_OWN/.muse-fleet/tasks/mine" "$HK_OWN/.muse-fleet/tasks/other"
printf '{"id":"mine","done":false,"branch":"muse/20260101-aaaa/mine","rounds":[{"n":1}]}' > "$HK_OWN/.muse-fleet/tasks/mine/state.json"
printf '{"id":"other","done":true,"branch":"muse/20260101-aaaa/other","rounds":[{"n":1}]}' > "$HK_OWN/.muse-fleet/tasks/other/state.json"
printf '{"id":"other","verdict":"accept","verified_by_supervisor":false}' > "$HK_OWN/.muse-fleet/tasks/other/task.json"
HK_OWN_IN="$HK_BASE/own.json"
printf '{"hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"subagent_type":"muse:muse-supervisor"},"tool_response":{"content":[{"type":"text","text":"finished muse/20260101-aaaa/mine ok"}]}}' > "$HK_OWN_IN"
HK_OWN_OUT="$(CLAUDE_PROJECT_DIR="$HK_OWN" python3 "$SKILL/hooks/supervisor_result.py" < "$HK_OWN_IN" 2>/dev/null)"
HK_OWN_CTX="$(printf '%s' "$HK_OWN_OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' 2>/dev/null)"
if [ -n "$HK_OWN_CTX" ] && printf '%s' "$HK_OWN_CTX" | grep -q 'mine' && ! printf '%s' "$HK_OWN_CTX" | grep -q 'other'; then
  ok "hooks: PostToolUse reports only the returning supervisor task"
else
  bad "hooks: PostToolUse reports only the returning supervisor task" "out=$HK_OWN_OUT"
fi

# -- PostToolUse ownership via the subagent transcript -----------------------
# The result text names no branch; ownership comes from the returning
# subagent's own transcript file. Removing that file must silence the hook,
# which proves the note came from the transcript and not from thin air.
HK_SUB="$HK_BASE/sub"
mkrepo "$HK_SUB"
printf '.muse-fleet/\n' >> "$HK_SUB/.git/info/exclude"
mkdir -p "$HK_SUB/.muse-fleet/tasks/solo"
printf '{"id":"solo","done":false,"branch":"fleet/20260101-aaaa/solo","rounds":[{"n":2}]}' > "$HK_SUB/.muse-fleet/tasks/solo/state.json"
HK_SUB_D="$HK_BASE/subt"
rm -rf "$HK_SUB_D"; mkdir -p "$HK_SUB_D/sess1/subagents"
printf '{"branch": "fleet/20260101-aaaa/solo"}\n' > "$HK_SUB_D/sess1/subagents/agent-abc123.jsonl"
HK_SUB_IN="$HK_BASE/sub.json"
python3 - "$(native_path "$HK_SUB_D/sess1.jsonl")" > "$HK_SUB_IN" <<'PY' 2>/dev/null
import json, sys
print(json.dumps({"hook_event_name": "PostToolUse", "tool_name": "Agent",
                  "tool_input": {"subagent_type": "muse:muse-supervisor"},
                  "tool_response": {"agentId": "abc123", "content": [{"type": "text", "text": "done"}]},
                  "session_id": "sess1", "transcript_path": sys.argv[1]}))
PY
HK_SUB_OUT="$(CLAUDE_PROJECT_DIR="$HK_SUB" python3 "$SKILL/hooks/supervisor_result.py" < "$HK_SUB_IN" 2>/dev/null)"
HK_SUB_CTX="$(printf '%s' "$HK_SUB_OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' 2>/dev/null)"
rm -f "$HK_SUB_D/sess1/subagents/agent-abc123.jsonl"
HK_SUB_OUT2="$(CLAUDE_PROJECT_DIR="$HK_SUB" python3 "$SKILL/hooks/supervisor_result.py" < "$HK_SUB_IN" 2>/dev/null)"
if [ -n "$HK_SUB_CTX" ] && printf '%s' "$HK_SUB_CTX" | grep -q 'solo' && [ -z "$HK_SUB_OUT2" ]; then
  ok "hooks: PostToolUse finds ownership through the subagent transcript"
else
  bad "hooks: PostToolUse finds ownership through the subagent transcript" "out=$HK_SUB_OUT out2=$HK_SUB_OUT2"
fi

# -- 11. leftover worktrees via SessionStart ----------------------------------
mkrepo "$HK_WT"
mkdir -p "$HK_WT/.muse-fleet/tasks/t1" "$HK_WT/.muse-fleet/tasks/t2"
printf '{"id":"t1","done":true,"branch":"muse/20260101-aaaa/t1","rounds":[{"n":1}]}' > "$HK_WT/.muse-fleet/tasks/t1/state.json"
printf '{"id":"t1","verdict":"accept","verified_by_supervisor":true}' > "$HK_WT/.muse-fleet/tasks/t1/task.json"
printf '{"id":"t2","done":false,"branch":"fleet/20260101-bbbb/t2","rounds":[{"n":2}]}' > "$HK_WT/.muse-fleet/tasks/t2/state.json"
git -C "$HK_WT" add -A 2>/dev/null
git -C "$HK_WT" -c user.email=t@l -c user.name=t commit -qm artifacts 2>/dev/null || true
git -C "$HK_WT" worktree add -q -b "muse/20260101-aaaa/t1" "$HK_BASE/wt1" HEAD 2>/dev/null
git -C "$HK_WT" worktree add -q -b "fleet/20260101-bbbb/t2" "$HK_BASE/wt2" HEAD 2>/dev/null
git -C "$HK_WT" worktree add -q -b "muse/20260101-cccc/norec" "$HK_BASE/wt3" HEAD 2>/dev/null
git -C "$HK_WT" worktree add -q -b "my-own-feature" "$HK_BASE/wt4" HEAD 2>/dev/null
HK_WT_OUT="$(CLAUDE_PROJECT_DIR="$HK_WT" python3 "$SKILL/hooks/leftover_worktrees.py" 2>/dev/null)"
if printf '%s' "$HK_WT_OUT" | grep -q 'muse/20260101-aaaa/t1' && printf '%s' "$HK_WT_OUT" | grep -q 'fleet/20260101-bbbb/t2'; then
  ok "hooks: leftover report names muse/ and fleet/ worktrees with records"
else
  bad "hooks: leftover report names muse/ and fleet/ worktrees with records" "out=$HK_WT_OUT"
fi
if [ -n "$HK_WT_OUT" ] && ! printf '%s' "$HK_WT_OUT" | grep -q 'norec' && ! printf '%s' "$HK_WT_OUT" | grep -q 'my-own-feature'; then
  ok "hooks: leftover report leaves unrecorded and user worktrees alone"
else
  bad "hooks: leftover report leaves unrecorded and user worktrees alone" "input was empty or matched: $HK_WT_OUT"
fi

# Preflight surfaces the same report on its stdout: stub muse at the tested
# version with auth and a catalog, so the problems block stays silent.
HK_PF_CFG="$HK_BASE/pfcfg"; HK_PF_DATA="$HK_BASE/pfdata"; HK_PF_BIN="$HK_BASE/pfbin"
rm -rf "$HK_PF_CFG" "$HK_PF_DATA" "$HK_PF_BIN"; mkdir -p "$HK_PF_CFG" "$HK_PF_DATA/model-catalog" "$HK_PF_BIN"
HK_TESTED="$(sed -n 's/^MUSE_TESTED_VERSION = "\(.*\)"/\1/p' "$SKILL/scripts/muse_core.py")"
printf '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "muse %s"; else echo "muse %s"; fi\nexit 0\n' "$HK_TESTED" "$HK_TESTED" > "$HK_PF_BIN/muse"
chmod +x "$HK_PF_BIN/muse"
if command -v cygpath >/dev/null 2>&1; then
  printf '@echo off\r\nexit /b 0\r\n' > "$HK_PF_BIN/muse.cmd"
fi
printf '{"k":"v"}' > "$HK_PF_CFG/auth.json"
printf '[{"model_id":"x-contributor"}]' > "$HK_PF_DATA/model-catalog/c.json"
HK_PF_PATH="$(shell_path "$HK_PF_BIN"):$(shell_path "$(dirname "$(command -v python3)")"):$(shell_path "$(dirname "$(command -v git)")"):/usr/bin:/bin"
HK_PF_OUT="$(PATH="$HK_PF_PATH" MUSE_CONFIG_DIR="$HK_PF_CFG" MUSE_DATA_DIR="$HK_PF_DATA" CLAUDE_PLUGIN_ROOT="$SKILL" CLAUDE_PROJECT_DIR="$HK_WT" bash "$SKILL/hooks/preflight.sh" 2>/dev/null)"
if printf '%s' "$HK_PF_OUT" | grep -q 'muse/20260101-aaaa/t1'; then
  ok "hooks: preflight.sh surfaces the leftover report on its stdout"
else
  bad "hooks: preflight.sh surfaces the leftover report on its stdout" "out=$HK_PF_OUT"
fi

git -C "$HK_WT" worktree remove --force --force "$HK_BASE/wt1" 2>/dev/null || true
git -C "$HK_WT" worktree remove --force --force "$HK_BASE/wt2" 2>/dev/null || true
git -C "$HK_WT" worktree remove --force --force "$HK_BASE/wt3" 2>/dev/null || true
git -C "$HK_WT" worktree remove --force --force "$HK_BASE/wt4" 2>/dev/null || true
git -C "$HK_WT" worktree prune 2>/dev/null || true
HK_WT_EMPTY="$(CLAUDE_PROJECT_DIR="$HK_WT" python3 "$SKILL/hooks/leftover_worktrees.py" 2>/dev/null)"
HK_WT_RC=$?
if [ -z "$HK_WT_EMPTY" ] && [ "$HK_WT_RC" -eq 0 ]; then
  ok "hooks: leftover report is silent when nothing is open"
else
  bad "hooks: leftover report is silent when nothing is open" "rc=$HK_WT_RC out=$HK_WT_EMPTY"
fi

if [ "$HK_STANDALONE" -eq 1 ]; then
  rm -rf "$LAB"
  exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
fi
