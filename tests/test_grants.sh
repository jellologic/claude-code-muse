#!/usr/bin/env bash
# grants: the supervisor does not write. The auto-triggering skill pre-approves
# only read-only status/doctor shims, and hooks/supervisor_guard.py denies the
# supervisor's writes. Sourced by scripts/validate.sh (shares ok/bad/skip/head_/
# SKILL/LAB) and runnable standalone.
GR_STANDALONE=0
if ! command -v ok >/dev/null 2>&1; then
  GR_STANDALONE=1
  set -uo pipefail
  export PYTHONUTF8=1
  native_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
  }
  shell_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi
  }
  SKILL="$(native_path "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)")"
  export PLUGIN_ROOT="$SKILL"
  LAB="$(native_path "${MUSE_FLEET_LAB:-$(mktemp -d "${TMPDIR:-/tmp}/musegrants.XXXXXX")}")"
  if [ -z "${LAB:-}" ] || [ ! -d "$LAB" ]; then echo "no scratch dir" >&2; exit 1; fi
  PASS=0; FAIL=0; SKIP=0
  ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
  bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && echo "        $2"; }
  skip() { SKIP=$((SKIP+$1)); shift; printf '  SKIP  %s\n' "$*"; }
fi
command -v head_ >/dev/null 2>&1 && head_ "grants: the supervisor does not write"
GR="$LAB/grants"; rm -rf "$GR"; mkdir -p "$GR"
GR_GUARD="$SKILL/hooks/supervisor_guard.py"
GR_WT="$GR/wt/t1"

# Fixture task owning the payload cwd, with one recorded check. Written by
# python json.dump so the exact bytes are never a quoting accident.
GR_WT_ENV="$GR_WT" GR_PROJ_ENV="$GR/proj" python3 - <<'PY'
import json, os
wt = os.environ["GR_WT_ENV"]
proj = os.environ["GR_PROJ_ENV"]
os.makedirs(wt, exist_ok=True)
os.makedirs(os.path.join(proj, ".muse-fleet", "tasks", "t1"), exist_ok=True)
with open(os.path.join(proj, ".muse-fleet", "tasks", "t1", "state.json"), "w",
          encoding="utf-8") as f:
    json.dump({"id": "t1", "worktree": wt, "done": False,
               "verifications": [{"command": "test -f added.py"}]}, f)
PY
# A lookalike shim outside the plugin: the guard must deny it by directory,
# not by name. It is never executed, only path-compared.
mkdir -p "$GR/evil/bin"
printf '#!/bin/sh\nexit 0\n' > "$GR/evil/bin/muse-task"
chmod +x "$GR/evil/bin/muse-task"

# GR_hook <agent_type|""> <tool_name> <tool_input-json-or-raw-command>: build the
# hook payload WITH PYTHON (values pass through the environment, never
# interpolated into python source), assert it is non-empty, run the guard with
# the fixture project dir, and strip CR native Windows python emits.
GR_hook() {
  GR_H_AGENT="$1"; GR_H_TOOL="$2"; GR_H_IN="$3"
  GR_H_PAYLOAD="$GR/payload.json"; GR_H_OUT="$GR/out.txt"; GR_H_ERR="$GR/err.txt"
  GR_H_CWD="$GR_WT" GR_H_AGENT="$GR_H_AGENT" GR_H_TOOL="$GR_H_TOOL" GR_H_IN="$GR_H_IN" python3 - > "$GR_H_PAYLOAD" <<'PY'
import json, os
agent = os.environ["GR_H_AGENT"]
tool = os.environ["GR_H_TOOL"]
raw = os.environ["GR_H_IN"]
if tool == "Bash":
    tool_input = {"command": raw}
else:
    tool_input = json.loads(raw)
payload = {"session_id": "sess-gr",
           "transcript_path": os.path.join(os.environ["GR_H_CWD"], "t.jsonl"),
           "cwd": os.environ["GR_H_CWD"],
           "hook_event_name": "PreToolUse",
           "tool_name": tool,
           "tool_input": tool_input,
           "agent_id": "a-gr"}
if agent != "":
    payload["agent_type"] = agent
print(json.dumps(payload))
PY
  if [ ! -s "$GR_H_PAYLOAD" ]; then
    bad "grants: hook payload was empty for $GR_H_TOOL" "the test measured nothing"
    return 1
  fi
  CLAUDE_PROJECT_DIR="$GR/proj" python3 "$GR_GUARD" < "$GR_H_PAYLOAD" > "$GR_H_OUT.raw" 2> "$GR_H_ERR"
  GR_RC=$?
  tr -d '\r' < "$GR_H_OUT.raw" > "$GR_H_OUT"
  return 0
}

# GR_parse: classify stdout as deny (deny JSON with a non-empty reason),
# empty (allowed: the hook must never emit "allow"), or other. The helper is
# written to a file first: a heredoc inside $( ) does not parse on macOS bash
# 3.2, which would leave every outcome empty.
cat > "$GR/parse.py" <<'PY'
import json, sys
t = open(sys.argv[1], encoding="utf-8").read()
if not t.strip():
    print("empty")
else:
    try:
        o = json.loads(t)
        h = o["hookSpecificOutput"]
        r = h.get("permissionDecisionReason", "")
        if (h.get("hookEventName") == "PreToolUse"
                and h.get("permissionDecision") == "deny"
                and isinstance(r, str) and r.strip()):
            print("deny")
        else:
            print("other")
    except Exception:
        print("other")
PY
GR_parse() {
  GR_OUTCOME="$(python3 "$GR/parse.py" "$GR_H_OUT")"
}

GR_expect_deny() {
  GR_D_LABEL="$1"; GR_hook "$2" "$3" "$4" || return 0
  GR_parse
  if [ "$GR_RC" -eq 0 ] && [ "$GR_OUTCOME" = "deny" ]; then
    ok "grants: $GR_D_LABEL"
  else
    bad "grants: $GR_D_LABEL" "rc=$GR_RC outcome=$GR_OUTCOME out=[$(cat "$GR_H_OUT")]"
  fi
}

GR_expect_allow() {
  GR_A_LABEL="$1"; GR_hook "$2" "$3" "$4" || return 0
  GR_parse
  if [ "$GR_RC" -eq 0 ] && [ "$GR_OUTCOME" = "empty" ]; then
    ok "grants: $GR_A_LABEL"
  else
    bad "grants: $GR_A_LABEL" "rc=$GR_RC outcome=$GR_OUTCOME out=[$(cat "$GR_H_OUT")]"
  fi
}

GR_SUP="muse:muse-supervisor"
GR_expect_deny "supervisor Bash denied: echo redirect" "$GR_SUP" Bash 'echo x > f'
GR_expect_deny "supervisor Bash denied: git redirect" "$GR_SUP" Bash 'git status > out.txt'
GR_expect_deny "supervisor Bash denied: pipe to tee" "$GR_SUP" Bash 'cat a.txt | tee b.txt'
GR_expect_deny "supervisor Bash denied: sed -i" "$GR_SUP" Bash 'sed -i s/a/b/ f.txt'
GR_expect_deny "supervisor Bash denied: chained rm" "$GR_SUP" Bash 'git status; rm -rf x'
GR_expect_deny "supervisor Bash denied: command substitution" "$GR_SUP" Bash 'git log $(rm -rf x)'
GR_expect_deny "supervisor Bash denied: git -c" "$GR_SUP" Bash 'git -c core.pager=sh log'
GR_expect_deny "supervisor Bash denied: git --output" "$GR_SUP" Bash 'git diff --output=x.patch'
GR_expect_deny "supervisor Bash denied: append redirect" "$GR_SUP" Bash 'ls >> f'
GR_expect_deny "supervisor Bash denied: env prefix" "$GR_SUP" Bash 'FOO=1 git status'
GR_expect_deny "supervisor Bash denied: python3" "$GR_SUP" Bash "python3 -c \"open('f','w')\""
GR_expect_deny "supervisor Bash denied: lookalike shim outside the plugin" "$GR_SUP" Bash "\"$GR/evil/bin/muse-task\" verify"
GR_expect_deny "supervisor Bash denied: unrecorded check is the control" "$GR_SUP" Bash 'test -f other.py'

# No skip on Windows or under root: the deny holds whether or not chmod took
# effect, so the count is fixed on every leg.
mkdir -p "$GR/proj/.muse-fleet/tasks/locked/inner"
chmod 000 "$GR/proj/.muse-fleet/tasks/locked"
GR_expect_deny "an unreadable task dir does not switch the guard off" "$GR_SUP" Bash 'echo x > f'
chmod 755 "$GR/proj/.muse-fleet/tasks/locked"
rm -rf "$GR/proj/.muse-fleet/tasks/locked"

GR_expect_allow "supervisor Bash allowed: muse-task verify" "$GR_SUP" Bash 'muse-task verify --id t1 --out .muse-fleet/tasks --command "test -f added.py"'
GR_expect_allow "supervisor Bash allowed: absolute plugin shim" "$GR_SUP" Bash "\"$SKILL/bin/muse-task\" show --id t1 --out x"
GR_expect_allow "supervisor Bash allowed: git status" "$GR_SUP" Bash 'git status'
GR_expect_allow "supervisor Bash allowed: git -C diff" "$GR_SUP" Bash "git -C \"$GR_WT\" diff"
GR_expect_allow "supervisor Bash allowed: cat" "$GR_SUP" Bash 'cat patch.diff'
GR_expect_allow "supervisor Bash allowed: quoted metachars in feedback" "$GR_SUP" Bash "muse-task revise --id t1 --out o --feedback 'the \`x\` > y is wrong'"
GR_expect_allow "supervisor Bash allowed: the recorded check" "$GR_SUP" Bash 'test -f added.py'

GR_WRITE_IN='{"file_path":"wt/t1/note.txt","content":"x"}'
GR_EDIT_IN='{"file_path":"wt/t1/note.txt","old_string":"a","new_string":"b"}'
GR_NB_IN='{"notebook_path":"n.ipynb","cell_id":"c","new_source":"x"}'
GR_expect_deny "supervisor Write denied" "$GR_SUP" Write "$GR_WRITE_IN"
GR_expect_deny "supervisor Edit denied" "$GR_SUP" Edit "$GR_EDIT_IN"
GR_expect_deny "supervisor NotebookEdit denied" "$GR_SUP" NotebookEdit "$GR_NB_IN"

# The supervisor Write deny above is the control proving these empty outputs
# are a live hook scoping by agent_type, not a dead hook.
GR_expect_allow "general-purpose Write allowed" "general-purpose" Write "$GR_WRITE_IN"
GR_expect_allow "general-purpose Bash redirect allowed" "general-purpose" Bash 'echo x > f'
GR_expect_allow "main session Write allowed" "" Write "$GR_WRITE_IN"

# Malformed input must exit 0 with nothing on either stream. One check for all
# three inputs.
GR_M_OK=1
for GR_M_IN in '{not json' '' '[]'; do
  printf '%s' "$GR_M_IN" | CLAUDE_PROJECT_DIR="$GR/proj" python3 "$GR_GUARD" > "$GR/mout.txt" 2> "$GR/merr.txt"
  GR_M_RC=$?
  tr -d '\r' < "$GR/mout.txt" > "$GR/mout.clean"
  if [ "$GR_M_RC" -ne 0 ] || [ -s "$GR/mout.clean" ] || [ -s "$GR/merr.txt" ]; then
    GR_M_OK=0
  fi
done
if [ "$GR_M_OK" -eq 1 ]; then
  ok "grants: malformed hook input exits 0 silently"
else
  bad "grants: malformed hook input exits 0 silently" "rc=$GR_M_RC out/err not both empty"
fi

# hooks.json registers the guard and nothing else is asserted about other events.
python3 - "$SKILL/hooks/hooks.json" > "$GR/hookcheck.out" 2>&1 <<'PY'
import json, sys
hooks = json.load(open(sys.argv[1], encoding="utf-8"))
entries = hooks["hooks"]["PreToolUse"]
want = set(["Bash", "Write", "Edit", "NotebookEdit"])
want_args = ["${CLAUDE_PLUGIN_ROOT}/hooks/supervisor_guard.py"]
found = False
for e in entries:
    if set(e.get("matcher", "").split("|")) != want:
        continue
    for sub in e.get("hooks", []):
        if (sub.get("command") == "python3" and sub.get("args") == want_args
                and sub.get("timeout")):
            found = True
if not found:
    print("no PreToolUse entry with the guard matcher, python3, plugin-root args and a timeout")
    sys.exit(1)
print("hook entry ok")
PY
GR_HRC=$?
if [ "$GR_HRC" -eq 0 ]; then
  ok "grants: hooks.json registers the supervisor guard on PreToolUse"
else
  bad "grants: hooks.json registers the supervisor guard on PreToolUse" "$(cat "$GR/hookcheck.out")"
fi

# Skill grants helper: prints BAD for any allowed-tools entry that is bare
# Bash/Agent/Task/Workflow/Write/Edit or any Bash(...) beyond the read-only
# status/doctor shims. It asserts the allowed-tools line is non-empty first,
# so a missing line cannot pass as clean.
cat > "$GR/skillcheck.py" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"^allowed-tools:(.*)$", text, re.M)
assert m and m.group(1).strip(), "no non-empty allowed-tools line found"
for e in [x.strip() for x in m.group(1).split(",")]:
    if e in ("Bash", "Agent", "Task", "Workflow", "Write", "Edit"):
        print("BAD grants %s" % e)
    elif (e.startswith("Bash(")
          and e not in ("Bash(muse-status:*)", "Bash(muse-doctor:*)")):
        print("BAD grants %s" % e)
PY
python3 "$GR/skillcheck.py" "$SKILL/skills/muse-fleet/SKILL.md" > "$GR/skill.out" 2>&1
GR_SRC=$?
if [ "$GR_SRC" -eq 0 ] && ! grep -q '^BAD ' "$GR/skill.out"; then
  ok "grants: the shipped skill pre-approves only status/doctor and readers"
else
  bad "grants: the shipped skill pre-approves only status/doctor and readers" "$(cat "$GR/skill.out")"
fi
printf '%s\n' '---' 'allowed-tools: Bash, Read, Agent, Workflow' '---' '' '# probe' > "$GR/probe.md"
python3 "$GR/skillcheck.py" "$GR/probe.md" > "$GR/probe.out" 2>&1
if grep -q '^BAD ' "$GR/probe.out"; then
  ok "grants: the grant check still fires on a loose probe"
else
  bad "grants: the grant check still fires on a loose probe" "probe with Bash/Agent/Workflow reported nothing"
fi

if [ "$GR_STANDALONE" = "1" ]; then
  rm -rf "$LAB"
  printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ] || exit 1
fi
