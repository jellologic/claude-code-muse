# shellcheck shell=bash
# Gap checks for mutants M19-M28 (issue #55) plus the three "Also" fixes.
# Sourced by scripts/validate.sh (one line) and runnable standalone for a
# fast loop. Every variable is MG_-prefixed: the file is sourced into
# validate.sh's global namespace. All scratch lives under "$LAB/v_mgaps".
MG_STANDALONE=0
if ! declare -F ok >/dev/null 2>&1; then
  MG_STANDALONE=1
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
  LAB="$(native_path "$(mktemp -d "${TMPDIR:-/tmp}/muse-mgaps.XXXXXX")")"
  if [ -z "${LAB:-}" ] || [ ! -d "$LAB" ]; then echo "no scratch dir" >&2; exit 1; fi
  PASS=0; FAIL=0; SKIP=0
  ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
  bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && echo "        $2"; }
  skip() { local n="$1"; shift; SKIP=$((SKIP+n)); printf '  SKIP  %s\n' "$*"; }
  mkrepo() {
    rm -rf "$1"; mkdir -p "$1"; git init -q -b main "$1"
    printf 'def add(a,b):\n    return a+b\n' > "$1/calc.py"
    git -C "$1" add -A
    git -C "$1" -c user.email=t@l -c user.name=t commit -qm init
  }
fi

if [ -z "${LAB:-}" ] || [ ! -d "${LAB:-}" ]; then
  echo "mgaps: refusing to run without a scratch dir" >&2
  if [ "$MG_STANDALONE" = 1 ]; then exit 1; else return 1; fi
fi

MG_BASE="$LAB/v_mgaps"
rm -rf "$MG_BASE"; mkdir -p "$MG_BASE"

# One finished-task fixture: state done:true plus a task.json body handed in.
mg_mkres() {  # mg_mkres <proj> <id> <branch> <taskjson-or-empty>
  mkdir -p "$1/.muse-fleet/tasks/$2"
  python3 - "$1/.muse-fleet/tasks/$2/state.json" "$2" "$3" <<'PY'
import json, sys
json.dump({"id": sys.argv[2], "done": True, "branch": sys.argv[3],
           "rounds": [{"n": 1}]}, open(sys.argv[1], "w"))
PY
  if [ -n "${4:-}" ]; then
    python3 - "$1/.muse-fleet/tasks/$2/task.json" "$4" <<'PY'
import json, sys
json.dump(json.loads(sys.argv[2]), open(sys.argv[1], "w"))
PY
  fi
}

# One SubagentStop task fixture: done handed in, optional verdict.
mg_mkstop() {  # mg_mkstop <proj> <id> <done> <branch> [verdict]
  mkdir -p "$1/.muse-fleet/tasks/$2"
  python3 - "$1/.muse-fleet/tasks/$2/state.json" "$2" "$3" "$4" <<'PY'
import json, sys
json.dump({"id": sys.argv[2], "done": sys.argv[3] == "true",
           "branch": sys.argv[4], "rounds": [{"n": 1}]},
          open(sys.argv[1], "w"))
PY
  if [ -n "${5:-}" ]; then
    python3 - "$1/.muse-fleet/tasks/$2/task.json" "$2" "$5" <<'PY'
import json, sys
json.dump({"id": sys.argv[2], "verdict": sys.argv[3]}, open(sys.argv[1], "w"))
PY
  fi
}

# -- M19: a missing or non-dict tool_input still reaches the agentType check --
MG_P19="$MG_BASE/p19"
mg_mkres "$MG_P19" "mgacc" "muse/20260101-mgaa/mgacc" '{"id":"mgacc","verdict":"accept"}'
python3 - "$MG_BASE/pay19.json" "muse/20260101-mgaa/mgacc" <<'PY'
import json, sys
json.dump({"hook_event_name": "PostToolUse", "tool_name": "Agent",
           "tool_response": {"agentType": "muse:muse-supervisor",
                             "content": [{"type": "text",
                                          "text": "finished " + sys.argv[2] + " ok"}]}},
          open(sys.argv[1], "w"))
PY
MG_CTX19="$(CLAUDE_PROJECT_DIR="$MG_P19" python3 "$SKILL/hooks/supervisor_result.py" < "$MG_BASE/pay19.json" 2>/dev/null | tr -d '\r' | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' 2>/dev/null)"
if [ -n "$MG_CTX19" ] && printf '%s' "$MG_CTX19" | grep -q 'mgacc: accepted WITHOUT a passing check'; then
  ok "mgaps: supervisor_result falls back to agentType when tool_input is missing"
else
  bad "mgaps: supervisor_result falls back to agentType when tool_input is missing" "ctx=$MG_CTX19"
fi

# Same hole through a non-dict tool_input: a string must not return early either.
python3 - "$MG_BASE/pay19s.json" "muse/20260101-mgaa/mgacc" <<'PY'
import json, sys
json.dump({"hook_event_name": "PostToolUse", "tool_name": "Agent",
           "tool_input": "x",
           "tool_response": {"agentType": "muse:muse-supervisor",
                             "content": [{"type": "text",
                                          "text": "finished " + sys.argv[2] + " ok"}]}},
          open(sys.argv[1], "w"))
PY
MG_CTX19S="$(CLAUDE_PROJECT_DIR="$MG_P19" python3 "$SKILL/hooks/supervisor_result.py" < "$MG_BASE/pay19s.json" 2>/dev/null | tr -d '\r' | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' 2>/dev/null)"
if [ -n "$MG_CTX19S" ] && printf '%s' "$MG_CTX19S" | grep -q 'mgacc: accepted WITHOUT a passing check'; then
  ok "mgaps: supervisor_result falls back to agentType when tool_input is not a dict"
else
  bad "mgaps: supervisor_result falls back to agentType when tool_input is not a dict" "ctx=$MG_CTX19S"
fi

# Control: a general-purpose return over the same fixture stays silent. The two
# notes above are what makes the emptiness below meaningful.
python3 - "$MG_BASE/pay19g.json" "muse/20260101-mgaa/mgacc" <<'PY'
import json, sys
json.dump({"hook_event_name": "PostToolUse", "tool_name": "Agent",
           "tool_response": {"agentType": "general-purpose",
                             "content": [{"type": "text",
                                          "text": "finished " + sys.argv[2] + " ok"}]}},
          open(sys.argv[1], "w"))
PY
MG_OUT19G="$(CLAUDE_PROJECT_DIR="$MG_P19" python3 "$SKILL/hooks/supervisor_result.py" < "$MG_BASE/pay19g.json" 2>/dev/null | tr -d '\r')"
if [ -n "$MG_CTX19" ] && [ -s "$MG_BASE/pay19g.json" ] && [ -z "$MG_OUT19G" ]; then
  ok "mgaps: supervisor_result stays silent for a non-supervisor agent return"
else
  bad "mgaps: supervisor_result stays silent for a non-supervisor agent return" "out=$MG_OUT19G"
fi

# -- M23: the out_of_band_edit note --
MG_P23="$MG_BASE/p23"
mg_mkres "$MG_P23" "mgobb" "muse/20260101-mgaa/mgobb" '{"id":"mgobb","verdict":"accept","verified_by_supervisor":true,"out_of_band_edit":true}'
python3 - "$MG_BASE/pay23.json" "muse/20260101-mgaa/mgobb" <<'PY'
import json, sys
json.dump({"hook_event_name": "PostToolUse", "tool_name": "Agent",
           "tool_input": {"subagent_type": "muse:muse-supervisor"},
           "tool_response": {"content": [{"type": "text",
                                          "text": "finished " + sys.argv[2] + " ok"}]}},
          open(sys.argv[1], "w"))
PY
MG_CTX23="$(CLAUDE_PROJECT_DIR="$MG_P23" python3 "$SKILL/hooks/supervisor_result.py" < "$MG_BASE/pay23.json" 2>/dev/null | tr -d '\r' | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' 2>/dev/null)"
if [ -n "$MG_CTX23" ] && printf '%s' "$MG_CTX23" | grep -q 'not what muse produced'; then
  ok "mgaps: supervisor_result reports a worktree edited after harvest"
else
  bad "mgaps: supervisor_result reports a worktree edited after harvest" "ctx=$MG_CTX23"
fi

# -- M20: done tasks never block, even when the transcript names them --
MG_P20="$MG_BASE/p20"
mg_mkstop "$MG_P20" "mgdone" "true" "muse/20260101-mgaa/mgdone"
mg_mkstop "$MG_P20" "mgopen" "false" "muse/20260101-mgaa/mgopen"
printf 'run %s ok\nrun %s ok\n' "muse/20260101-mgaa/mgdone" "muse/20260101-mgaa/mgopen" > "$MG_BASE/tr20.jsonl"
python3 - "$MG_BASE/stop20.json" "$(native_path "$MG_BASE/tr20.jsonl")" <<'PY'
import json, sys
json.dump({"agent_type": "muse:muse-supervisor", "stop_hook_active": False,
           "agent_transcript_path": sys.argv[2]}, open(sys.argv[1], "w"))
PY
MG_OUT20="$(CLAUDE_PROJECT_DIR="$MG_P20" python3 "$SKILL/hooks/supervisor_stop.py" < "$MG_BASE/stop20.json" 2>/dev/null | tr -d '\r')"
MG_DEC20="$(printf '%s' "$MG_OUT20" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("decision",""))' 2>/dev/null)"
MG_REA20="$(printf '%s' "$MG_OUT20" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("reason",""))' 2>/dev/null)"
if [ "$MG_DEC20" = "block" ] && printf '%s' "$MG_REA20" | grep -q 'mgopen' && ! printf '%s' "$MG_REA20" | grep -q 'mgdone'; then
  ok "mgaps: supervisor_stop blocks over the unfinished task, not the finished one"
else
  bad "mgaps: supervisor_stop blocks over the unfinished task, not the finished one" "out=$MG_OUT20"
fi

# -- M21: a recorded verdict is finished, even with done:false --
MG_P21="$MG_BASE/p21"
mg_mkstop "$MG_P21" "mgopen" "false" "muse/20260101-mgaa/mgopen"
mg_mkstop "$MG_P21" "mgver" "false" "muse/20260101-mgaa/mgver" "revise"
printf 'run %s ok\nrun %s ok\n' "muse/20260101-mgaa/mgopen" "muse/20260101-mgaa/mgver" > "$MG_BASE/tr21.jsonl"
python3 - "$MG_BASE/stop21.json" "$(native_path "$MG_BASE/tr21.jsonl")" <<'PY'
import json, sys
json.dump({"agent_type": "muse:muse-supervisor", "stop_hook_active": False,
           "agent_transcript_path": sys.argv[2]}, open(sys.argv[1], "w"))
PY
MG_OUT21="$(CLAUDE_PROJECT_DIR="$MG_P21" python3 "$SKILL/hooks/supervisor_stop.py" < "$MG_BASE/stop21.json" 2>/dev/null | tr -d '\r')"
MG_DEC21="$(printf '%s' "$MG_OUT21" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("decision",""))' 2>/dev/null)"
MG_REA21="$(printf '%s' "$MG_OUT21" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("reason",""))' 2>/dev/null)"
if [ "$MG_DEC21" = "block" ] && printf '%s' "$MG_REA21" | grep -q 'mgopen' && ! printf '%s' "$MG_REA21" | grep -q 'mgver'; then
  ok "mgaps: supervisor_stop blocks over the task with no verdict, not one with a verdict"
else
  bad "mgaps: supervisor_stop blocks over the task with no verdict, not one with a verdict" "out=$MG_OUT21"
fi

# -- M22: only the supervisor type blocks --
MG_P22A="$MG_BASE/p22a"; MG_P22B="$MG_BASE/p22b"
mg_mkstop "$MG_P22A" "mgown" "false" "muse/20260101-mgaa/mgown"
mg_mkstop "$MG_P22B" "mgown" "false" "muse/20260101-mgaa/mgown"
printf 'run %s ok\n' "muse/20260101-mgaa/mgown" > "$MG_BASE/tr22.jsonl"
python3 - "$MG_BASE/stop22s.json" "$(native_path "$MG_BASE/tr22.jsonl")" "muse:muse-supervisor" <<'PY'
import json, sys
json.dump({"agent_type": sys.argv[3], "stop_hook_active": False,
           "agent_transcript_path": sys.argv[2]}, open(sys.argv[1], "w"))
PY
python3 - "$MG_BASE/stop22g.json" "$(native_path "$MG_BASE/tr22.jsonl")" "general-purpose" <<'PY'
import json, sys
json.dump({"agent_type": sys.argv[3], "stop_hook_active": False,
           "agent_transcript_path": sys.argv[2]}, open(sys.argv[1], "w"))
PY
MG_OUT22S="$(CLAUDE_PROJECT_DIR="$MG_P22A" python3 "$SKILL/hooks/supervisor_stop.py" < "$MG_BASE/stop22s.json" 2>/dev/null | tr -d '\r')"
MG_DEC22S="$(printf '%s' "$MG_OUT22S" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("decision",""))' 2>/dev/null)"
if [ "$MG_DEC22S" = "block" ] && printf '%s' "$MG_OUT22S" | grep -q 'mgown'; then
  ok "mgaps: supervisor_stop blocks a supervisor that owns unfinished work"
else
  bad "mgaps: supervisor_stop blocks a supervisor that owns unfinished work" "out=$MG_OUT22S"
fi
# A fresh copy of the fixture: the control above bumped the block count in the
# first copy, so a shared fixture would go silent for the wrong reason.
MG_OUT22G="$(CLAUDE_PROJECT_DIR="$MG_P22B" python3 "$SKILL/hooks/supervisor_stop.py" < "$MG_BASE/stop22g.json" 2>/dev/null | tr -d '\r')"
if [ -n "$MG_OUT22S" ] && [ -s "$MG_BASE/stop22g.json" ] && [ -z "$MG_OUT22G" ]; then
  ok "mgaps: supervisor_stop stays silent for a non-supervisor agent type"
else
  bad "mgaps: supervisor_stop stays silent for a non-supervisor agent type" "out=$MG_OUT22G"
fi

# -- M24: tasks older than the recent window stay silent --
MG_P24="$MG_BASE/p24"
mg_mkstop "$MG_P24" "mg5h" "false" "muse/20260101-mgaa/mg5h"
mg_mkstop "$MG_P24" "mg7h" "false" "muse/20260101-mgaa/mg7h"
python3 - "$MG_P24" <<'PY'
import os, sys, time
now = time.time()
os.utime(sys.argv[1] + "/.muse-fleet/tasks/mg5h/state.json", (now - 5 * 3600, now - 5 * 3600))
os.utime(sys.argv[1] + "/.muse-fleet/tasks/mg7h/state.json", (now - 7 * 3600, now - 7 * 3600))
PY
printf 'run %s ok\nrun %s ok\n' "muse/20260101-mgaa/mg5h" "muse/20260101-mgaa/mg7h" > "$MG_BASE/tr24.jsonl"
python3 - "$MG_BASE/stop24.json" "$(native_path "$MG_BASE/tr24.jsonl")" <<'PY'
import json, sys
json.dump({"agent_type": "muse:muse-supervisor", "stop_hook_active": False,
           "agent_transcript_path": sys.argv[2]}, open(sys.argv[1], "w"))
PY
MG_OUT24="$(CLAUDE_PROJECT_DIR="$MG_P24" python3 "$SKILL/hooks/supervisor_stop.py" < "$MG_BASE/stop24.json" 2>/dev/null | tr -d '\r')"
MG_DEC24="$(printf '%s' "$MG_OUT24" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("decision",""))' 2>/dev/null)"
MG_REA24="$(printf '%s' "$MG_OUT24" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("reason",""))' 2>/dev/null)"
if [ "$MG_DEC24" = "block" ] && printf '%s' "$MG_REA24" | grep -q 'mg5h' && ! printf '%s' "$MG_REA24" | grep -q 'mg7h'; then
  ok "mgaps: supervisor_stop ignores tasks older than the recent window"
else
  bad "mgaps: supervisor_stop ignores tasks older than the recent window" "out=$MG_OUT24"
fi

# -- M25: the leftover report keeps the verdict label --
MG_P25="$MG_BASE/p25"
mkrepo "$MG_P25"
mkdir -p "$MG_P25/.muse-fleet/tasks/mgfin" "$MG_P25/.muse-fleet/tasks/mgopen"
python3 - "$MG_P25" <<'PY'
import json, sys
base = sys.argv[1] + "/.muse-fleet/tasks"
json.dump({"id": "mgfin", "done": True, "branch": "muse/20260101-mgaa/mgfin",
           "rounds": [{"n": 1}]}, open(base + "/mgfin/state.json", "w"))
json.dump({"id": "mgfin", "verdict": "accept", "verified_by_supervisor": True},
          open(base + "/mgfin/task.json", "w"))
json.dump({"id": "mgopen", "done": False, "branch": "fleet/20260101-mgbb/mgopen",
           "rounds": [{"n": 2}]}, open(base + "/mgopen/state.json", "w"))
PY
git -C "$MG_P25" add -A 2>/dev/null
git -C "$MG_P25" -c user.email=t@l -c user.name=t commit -qm artifacts 2>/dev/null || true
git -C "$MG_P25" worktree add -q -b "muse/20260101-mgaa/mgfin" "$MG_BASE/wt25a" HEAD 2>/dev/null
git -C "$MG_P25" worktree add -q -b "fleet/20260101-mgbb/mgopen" "$MG_BASE/wt25b" HEAD 2>/dev/null
MG_OUT25="$(CLAUDE_PROJECT_DIR="$MG_P25" python3 "$SKILL/hooks/leftover_worktrees.py" 2>/dev/null | tr -d '\r')"
MG_LINE25F="$(printf '%s' "$MG_OUT25" | grep 'muse/20260101-mgaa/mgfin' || true)"
MG_LINE25O="$(printf '%s' "$MG_OUT25" | grep 'fleet/20260101-mgbb/mgopen' || true)"
if [ -n "$MG_LINE25F" ] && printf '%s' "$MG_LINE25F" | grep -q 'verdict recorded'; then
  ok "mgaps: leftover report marks a finished worktree as verdict recorded"
else
  bad "mgaps: leftover report marks a finished worktree as verdict recorded" "out=$MG_OUT25"
fi
if [ -n "$MG_LINE25O" ] && printf '%s' "$MG_LINE25O" | grep -q 'no verdict yet'; then
  ok "mgaps: leftover report marks an open worktree as no verdict yet"
else
  bad "mgaps: leftover report marks an open worktree as no verdict yet" "out=$MG_OUT25"
fi
git -C "$MG_P25" worktree remove --force --force "$MG_BASE/wt25a" 2>/dev/null || true
git -C "$MG_P25" worktree remove --force --force "$MG_BASE/wt25b" 2>/dev/null || true
git -C "$MG_P25" worktree prune 2>/dev/null || true

# -- M26: a same-key placeholder flag with a bad env value is blamed on env --
MG_R26="$MG_BASE/r26"
mkrepo "$MG_R26"
MG_DOC26="$(env -u CLAUDE_PLUGIN_OPTION_DEFAULT_EFFORT -u CLAUDE_PLUGIN_OPTION_DEFAULT_MODEL -u CLAUDE_PLUGIN_OPTION_REFUSE_ON_SECRETS -u CLAUDE_PLUGIN_OPTION_WORKTREE_ROOT CLAUDE_PLUGIN_OPTION_MAX_ROUNDS=99 python3 "$SKILL/scripts/muse_doctor.py" --json --repo "$MG_R26" --max-rounds '${user_config.max_rounds}' 2>/dev/null)"
MG_UC26="$(printf '%s' "$MG_DOC26" | python3 -c '
import json, sys
d = json.load(sys.stdin)
rows = [c for c in (d.get("checks") or []) if c.get("name") == "userConfig"]
assert rows, "no userConfig row"
print(rows[0]["severity"] + "\n" + rows[0]["value"])' 2>/dev/null)"
MG_SEV26="$(printf '%s' "$MG_UC26" | sed -n '1p')"
MG_VAL26="$(printf '%s' "$MG_UC26" | sed -n '2p')"
if [ "$MG_SEV26" = "FAIL" ] && printf '%s' "$MG_VAL26" | grep -q "max_rounds='99' (env)"; then
  ok "mgaps: doctor blames a same-key placeholder flag with an invalid env value on env"
else
  bad "mgaps: doctor blames a same-key placeholder flag with an invalid env value on env" "sev=$MG_SEV26 val=$MG_VAL26"
fi

# -- M27: --refuse-on-secrets false opts out of the --write refusal --
MG_ASKD="$MG_BASE/ask"; MG_ASKR="$MG_BASE/askrepo"
rm -rf "$MG_ASKD" "$MG_ASKR"; mkdir -p "$MG_ASKD/bin" "$MG_ASKD/data"
cat > "$MG_ASKD/bin/muse" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "muse 1.3.0"; exit 0; fi
printf '%s\n' "$*" >> "$MG_STUB_LOG"
printf '{"payload":{"kind":"run_terminal","terminal":"completed","text":"ok"}}\n'
STUB
chmod +x "$MG_ASKD/bin/muse"
if command -v cygpath >/dev/null 2>&1; then
  printf '@echo off\r\n"%s" "%s" %%*\r\nexit /b %%ERRORLEVEL%%\r\n' \
    "$(native_path "$(command -v bash)")" \
    "$(native_path "$MG_ASKD/bin/muse")" > "$MG_ASKD/bin/muse.cmd"
fi
MG_ASKPATH="$(shell_path "$MG_ASKD/bin"):$PATH"
mkrepo "$MG_ASKR"
python3 - "$MG_ASKR/cred.txt" <<'PY'
import sys
open(sys.argv[1], "w").write("key = " + "AKIA" + "IOSFODNN7EXAMPLE" + "\n")
PY
git -C "$MG_ASKR" add -A
git -C "$MG_ASKR" -c user.email=t@l -c user.name=t commit -qm cred 2>/dev/null
if [ ! -s "$MG_ASKR/cred.txt" ] || ! git -C "$MG_ASKR" ls-files | grep -q 'cred.txt'; then
  bad "mgaps: ask --refuse-on-secrets false opts out of the --write refusal" "credential fixture missing -- the proceed assertion would measure nothing"
else
  export MG_STUB_LOG="$MG_ASKD/stub-flag.log"; : > "$MG_STUB_LOG"
  (cd "$MG_ASKR" && env -u CLAUDE_PLUGIN_OPTION_REFUSE_ON_SECRETS PATH="$MG_ASKPATH" CLAUDE_PLUGIN_DATA="$MG_ASKD/data" bash "$SKILL/scripts/muse_ask.sh" --model stub-model --write --refuse-on-secrets false "q" >"$MG_ASKD/out-flag.txt" 2>"$MG_ASKD/err-flag.txt")
  MG_RC27=$?
  if [ "$MG_RC27" -eq 0 ] && [ -s "$MG_STUB_LOG" ] && ! grep -q 'muse_ask: refused' "$MG_ASKD/err-flag.txt"; then
    ok "mgaps: ask --refuse-on-secrets false opts out of the --write refusal"
  else
    bad "mgaps: ask --refuse-on-secrets false opts out of the --write refusal" "rc=$MG_RC27 err=$(head -2 "$MG_ASKD/err-flag.txt" 2>/dev/null)"
  fi
fi
# Control: without the flag the same repo still refuses and never starts muse.
export MG_STUB_LOG="$MG_ASKD/stub-ctl.log"; : > "$MG_STUB_LOG"
(cd "$MG_ASKR" && env -u CLAUDE_PLUGIN_OPTION_REFUSE_ON_SECRETS PATH="$MG_ASKPATH" CLAUDE_PLUGIN_DATA="$MG_ASKD/data" bash "$SKILL/scripts/muse_ask.sh" --model stub-model --write "q" >"$MG_ASKD/out-ctl.txt" 2>"$MG_ASKD/err-ctl.txt")
MG_RC27C=$?
if [ "$MG_RC27C" -eq 1 ] && grep -q 'muse_ask: refused' "$MG_ASKD/err-ctl.txt" && [ ! -s "$MG_STUB_LOG" ]; then
  ok "mgaps: ask --write refuses on a credential without opt-out"
else
  bad "mgaps: ask --write refuses on a credential without opt-out" "rc=$MG_RC27C"
fi

# -- M28: the frontmatter contract fires against a doctored root --
MG_FM="$MG_BASE/fmroot"
rm -rf "$MG_FM"; mkdir -p "$MG_FM"
cp -R "$SKILL/agents" "$MG_FM/agents"
cp -R "$SKILL/skills" "$MG_FM/skills"
cp -R "$SKILL/commands" "$MG_FM/commands"
cp -R "$SKILL/.claude-plugin" "$MG_FM/.claude-plugin"
MG_FM_OUT="$(python3 "$SKILL/tests/frontmatter_contract.py" "$MG_FM" 2>&1)"
MG_FM_RC=$?
if [ "$MG_FM_RC" -eq 0 ] && [ -z "$MG_FM_OUT" ]; then
  ok "mgaps: frontmatter contract passes the real tree"
else
  bad "mgaps: frontmatter contract passes the real tree" "rc=$MG_FM_RC out=$MG_FM_OUT"
fi
# GNU and BSD sed disagree on -i, so the rewrite is python.
MG_FM_REWRITE="$MG_BASE/rewrite.py"
cat > "$MG_FM_REWRITE" <<'PY'
import sys
p = sys.argv[1] + "/skills/muse-fleet/SKILL.md"
lines = open(p, encoding="utf-8").read().splitlines(keepends=True)
assert any(l.startswith("allowed-tools:") for l in lines), "no allowed-tools line"
open(p, "w", encoding="utf-8").write(
    "".join(("allowed-tools: " + sys.argv[2] + "\n") if l.startswith("allowed-tools:") else l
            for l in lines))
PY
python3 "$MG_FM_REWRITE" "$MG_FM" "Bash, Read, Grep, Glob"
MG_FM_OUT="$(python3 "$SKILL/tests/frontmatter_contract.py" "$MG_FM" 2>&1)"
MG_FM_RC=$?
if [ "$MG_FM_RC" -ne 0 ] && printf '%s' "$MG_FM_OUT" | grep -q 'Bash'; then
  ok "mgaps: frontmatter contract refuses bare Bash pre-approval"
else
  bad "mgaps: frontmatter contract refuses bare Bash pre-approval" "rc=$MG_FM_RC out=$MG_FM_OUT"
fi
python3 "$MG_FM_REWRITE" "$MG_FM" "Bash(git:*), Read"
MG_FM_OUT="$(python3 "$SKILL/tests/frontmatter_contract.py" "$MG_FM" 2>&1)"
MG_FM_RC=$?
if [ "$MG_FM_RC" -ne 0 ] && printf '%s' "$MG_FM_OUT" | grep -q 'Bash'; then
  ok "mgaps: frontmatter contract refuses a Bash(...) pre-approval"
else
  bad "mgaps: frontmatter contract refuses a Bash(...) pre-approval" "rc=$MG_FM_RC out=$MG_FM_OUT"
fi

# -- C1: the doctor reports the default the task runs on --
MG_NROUNDS="$(python3 - "$SKILL/scripts/muse_task.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("mgtask", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(m.DEFAULT_MAX_ROUNDS)
PY
)"
MG_DOC1="$(env -u CLAUDE_PLUGIN_OPTION_DEFAULT_EFFORT -u CLAUDE_PLUGIN_OPTION_MAX_ROUNDS -u CLAUDE_PLUGIN_OPTION_DEFAULT_MODEL -u CLAUDE_PLUGIN_OPTION_REFUSE_ON_SECRETS -u CLAUDE_PLUGIN_OPTION_WORKTREE_ROOT python3 "$SKILL/scripts/muse_doctor.py" --json --repo "$MG_R26" 2>/dev/null)"
MG_UC1="$(printf '%s' "$MG_DOC1" | python3 -c '
import json, sys
d = json.load(sys.stdin)
rows = [c for c in (d.get("checks") or []) if c.get("name") == "userConfig"]
assert rows, "no userConfig row"
print(rows[0]["severity"] + "\n" + rows[0]["value"])' 2>/dev/null)"
MG_SEV1="$(printf '%s' "$MG_UC1" | sed -n '1p')"
MG_VAL1="$(printf '%s' "$MG_UC1" | sed -n '2,99p')"
if [ -n "$MG_NROUNDS" ] && [ "$MG_SEV1" = "OK" ] && printf '%s' "$MG_VAL1" | grep -q "max_rounds=$MG_NROUNDS (default)"; then
  ok "mgaps: doctor reports the default max_rounds the task runs on"
else
  bad "mgaps: doctor reports the default max_rounds the task runs on" "n=$MG_NROUNDS sev=$MG_SEV1 val=$MG_VAL1"
fi

# -- C2: an empty defaultEffort is unconfigured, not refused --
if command -v node >/dev/null 2>&1; then
  MG_WF="$MG_BASE/wf"; MG_WFREPO="$MG_WF/repo"
  rm -rf "$MG_WF"; mkdir -p "$MG_WFREPO"
  mkrepo "$MG_WFREPO"
  MG_WF_SRC="$SKILL/workflows/muse-supervised-fleet.js"
  MG_WF_PLUG="$(native_path "$SKILL")"
  MG_WF_REPO_N="$(native_path "$MG_WFREPO")"
  MG_WF_OUT_N="$(native_path "$MG_WF/out")"
  export MG_WF_REPO_N MG_WF_OUT_N MG_WF_PLUG
  python3 - "$MG_WF_SRC" "$MG_WF/run.mjs" <<'PY'
import json, os, sys
src, dest = sys.argv[1], sys.argv[2]
plug, repo, out = (os.environ[k] for k in ("MG_WF_PLUG", "MG_WF_REPO_N", "MG_WF_OUT_N"))
harness = """import fs from 'node:fs';
const PLUG = %s;
const REPO = %s;
const OUTD = %s;
const RAW = process.env.MG_WF_ARGS_JSON;
if (RAW !== 'undefined') globalThis.args = JSON.parse(RAW);
const calls = [];
globalThis.phase = (t) => {};
globalThis.log = (m) => {};
globalThis.parallel = (fns) => Promise.all(fns.map((f) => f()));
globalThis.agent = async (prompt, opts) => {
  opts = opts || {};
  calls.push({ label: opts.label || '', prompt: String(prompt) });
  throw new Error('MG_SENTINEL');
};
async function __body(){
""" % tuple(json.dumps(s) for s in (plug, repo, out))
body = open(src, encoding="utf-8").read().replace("export const meta", "const meta", 1)
tail = """
}
__body().then(
  (result) => console.log(JSON.stringify({ result, calls, error: null })),
  (err) => console.log(JSON.stringify({ result: null, calls, logs: null, error: String((err && err.stack) || err) }))
);
"""
open(dest, "w", encoding="utf-8").write(harness + body + tail)
PY
  MG_WF_ARGS_JSON="$(python3 -c 'import json,os; print(json.dumps({"pluginRoot":os.environ["MG_WF_PLUG"],"repo":os.environ["MG_WF_REPO_N"],"out":os.environ["MG_WF_OUT_N"],"stamp":"mg1","job":"j","defaultEffort":""}))')"
  export MG_WF_ARGS_JSON
  MG_WF_RES="$(node "$MG_WF/run.mjs" 2>/dev/null)"
  if printf '%s' "$MG_WF_RES" | python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert "MG_SENTINEL" in (d.get("error") or ""), "plan was never reached: %r" % (d,)
calls = d.get("calls") or []
plans = [c for c in calls if c.get("label") == "plan"]
assert plans, "no plan call recorded: %r" % (calls,)
assert not (d.get("result") or {}).get("refused"), "empty effort was refused"
assert "\"low\" for mechanical edits" in plans[0]["prompt"], "plan prompt lost the default effort"
' "$MG_WF_RES" 2>/dev/null; then
    ok "mgaps: workflow treats an empty defaultEffort as unconfigured"
  else
    bad "mgaps: workflow treats an empty defaultEffort as unconfigured" "$(printf '%s' "$MG_WF_RES" | head -c 300)"
  fi
  MG_WF_ARGS_JSON="$(python3 -c 'import json,os; print(json.dumps({"pluginRoot":os.environ["MG_WF_PLUG"],"repo":os.environ["MG_WF_REPO_N"],"out":os.environ["MG_WF_OUT_N"],"stamp":"mg1","job":"j","defaultEffort":"bogus"}))')"
  export MG_WF_ARGS_JSON
  MG_WF_RES="$(node "$MG_WF/run.mjs" 2>/dev/null)"
  if printf '%s' "$MG_WF_RES" | python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert (d.get("result") or {}).get("refused") is True, "bogus effort was not refused: %r" % (d,)
assert not (d.get("calls") or []), "agent ran before the refusal: %r" % (d.get("calls"),)
' "$MG_WF_RES" 2>/dev/null; then
    ok "mgaps: workflow still refuses a bogus defaultEffort"
  else
    bad "mgaps: workflow still refuses a bogus defaultEffort" "$(printf '%s' "$MG_WF_RES" | head -c 300)"
  fi
  unset MG_WF_ARGS_JSON
else
  skip 2 "mgaps: node missing, workflow empty-effort checks skipped"
fi

# -- C3: a single quote in worktree_root gets its own fix --
MG_QDIR="$MG_BASE/qu'ote"
rm -rf "$MG_BASE/qu'ote"; mkdir -p "$MG_QDIR"
MG_DOCQ="$(python3 "$SKILL/scripts/muse_doctor.py" --json --repo "$MG_R26" --worktree-root "$MG_QDIR" 2>/dev/null)"
MG_WTQ="$(printf '%s' "$MG_DOCQ" | python3 -c '
import json, sys
d = json.load(sys.stdin)
rows = [c for c in (d.get("checks") or []) if c.get("name") == "worktree root"]
assert rows, "no worktree root row"
print(rows[0]["severity"] + "\n" + rows[0]["fix"])' 2>/dev/null)"
MG_QSEV="$(printf '%s' "$MG_WTQ" | sed -n '1p')"
MG_QFIX="$(printf '%s' "$MG_WTQ" | sed -n '2,99p')"
if [ -n "$MG_QDIR" ] && [ "$MG_QSEV" = "FAIL" ] && printf '%s' "$MG_QFIX" | grep -q 'single quote' && ! printf '%s' "$MG_QFIX" | grep -q 'outside the repository'; then
  ok "mgaps: doctor tells the user to remove a single quote from worktree_root"
else
  bad "mgaps: doctor tells the user to remove a single quote from worktree_root" "sev=$MG_QSEV fix=$MG_QFIX"
fi
MG_DOCQI="$(python3 "$SKILL/scripts/muse_doctor.py" --json --repo "$MG_R26" --worktree-root "$MG_R26/wts" 2>/dev/null)"
MG_WTQI="$(printf '%s' "$MG_DOCQI" | python3 -c '
import json, sys
d = json.load(sys.stdin)
rows = [c for c in (d.get("checks") or []) if c.get("name") == "worktree root"]
assert rows, "no worktree root row"
print(rows[0]["severity"] + "\n" + rows[0]["fix"])' 2>/dev/null)"
MG_QISEV="$(printf '%s' "$MG_WTQI" | sed -n '1p')"
MG_QIFIX="$(printf '%s' "$MG_WTQI" | sed -n '2,99p')"
if [ "$MG_QISEV" = "FAIL" ] && printf '%s' "$MG_QIFIX" | grep -q 'outside the repository'; then
  ok "mgaps: doctor keeps the outside-the-repository fix for a plain inside-repo root"
else
  bad "mgaps: doctor keeps the outside-the-repository fix for a plain inside-repo root" "sev=$MG_QISEV fix=$MG_QIFIX"
fi

if [ "${MG_STANDALONE:-0}" = 1 ]; then rm -rf "$LAB"; echo "RESULT: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit $?; fi
