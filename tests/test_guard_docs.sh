#!/usr/bin/env bash
# guarddocs: the supervisor's prose matches its guard. The agent's command
# lines must pass the PreToolUse guard, the SubagentStop reason must run as
# printed, the recorded check must work only inside its task's worktree, and
# the cleanup / routing / SECURITY pointers must name what the code does.
# Sourced by scripts/validate.sh (shares ok/bad/skip/head_/SKILL/LAB and the
# PATH helpers) and runnable standalone with `bash tests/test_guard_docs.sh`.
GD_STANDALONE=0
if ! command -v ok >/dev/null 2>&1; then
  GD_STANDALONE=1
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
  LAB="$(native_path "${MUSE_FLEET_LAB:-$(mktemp -d "${TMPDIR:-/tmp}/museguarddocs.XXXXXX")}")"
  if [ -z "${LAB:-}" ] || [ ! -d "$LAB" ]; then echo "no scratch dir" >&2; exit 1; fi
  PASS=0; FAIL=0; SKIP=0
  ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
  bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && echo "        $2"; }
  skip() { local n="$1"; shift; SKIP=$((SKIP+n)); printf '  SKIP  %s\n' "$*"; }
fi

if [ -z "${LAB:-}" ] || [ ! -d "${LAB:-}" ]; then
  echo "guarddocs: refusing to run without a scratch dir" >&2
  if [ "$GD_STANDALONE" = 1 ]; then exit 1; else return 1; fi
fi

command -v head_ >/dev/null 2>&1 && head_ "guarddocs: supervisor prose matches its guard"

GD="$LAB/guarddocs"; rm -rf "$GD"; mkdir -p "$GD"
GD_GUARD="$SKILL/hooks/supervisor_guard.py"
GD_STOP="$SKILL/hooks/supervisor_stop.py"

# Python helpers are written to files before use: a heredoc inside $( ) does
# not parse on macOS bash 3.2. Values reach python through the environment or
# argv, never interpolated into source.
cat > "$GD/mkpayload.py" <<'PY'
import json, os
print(json.dumps({
    "session_id": "sess-gd",
    "transcript_path": os.path.join(os.environ["GD_H_CWD"], "t.jsonl"),
    "cwd": os.environ["GD_H_CWD"],
    "hook_event_name": "PreToolUse",
    "tool_name": "Bash",
    "tool_input": {"command": os.environ["GD_H_CMD"]},
    "agent_id": "a-gd",
    "agent_type": "muse:muse-supervisor",
}))
PY
cat > "$GD/parse.py" <<'PY'
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

# GD_hook <command> <cwd-native> <project-native>: build the guard payload
# WITH PYTHON (values pass through the environment, never interpolated into
# python source), run the guard, strip CR native Windows python emits.
GD_hook() {
  GD_H_PAYLOAD="$GD/payload.json"; GD_H_OUT="$GD/out.txt"; GD_H_ERR="$GD/err.txt"
  GD_H_CMD="$1" GD_H_CWD="$2" python3 "$GD/mkpayload.py" > "$GD_H_PAYLOAD" 2> "$GD_H_ERR"
  if [ ! -s "$GD_H_PAYLOAD" ]; then
    bad "guarddocs: hook payload was empty" "the test measured nothing"
    return 1
  fi
  CLAUDE_PROJECT_DIR="$3" python3 "$GD_GUARD" < "$GD_H_PAYLOAD" > "$GD_H_OUT.raw" 2> "$GD_H_ERR"
  GD_RC=$?
  tr -d '\r' < "$GD_H_OUT.raw" > "$GD_H_OUT"
  return 0
}
GD_verdict() {
  GD_V_OUTCOME="$(python3 "$GD/parse.py" "$GD_H_OUT" 2>/dev/null | tr -d '\r')"
}
GD_expect_deny() {  # GD_expect_deny <label> <command> <cwd> <proj>
  GD_D_LABEL="$1"
  if ! GD_hook "$2" "$3" "$4"; then return 0; fi
  GD_verdict
  if [ "$GD_RC" -eq 0 ] && [ "$GD_V_OUTCOME" = "deny" ]; then
    ok "guarddocs: $GD_D_LABEL"
  else
    bad "guarddocs: $GD_D_LABEL" "rc=$GD_RC outcome=$GD_V_OUTCOME out=[$(cat "$GD_H_OUT")]"
  fi
}
GD_expect_allow() {  # GD_expect_allow <label> <command> <cwd> <proj>
  GD_A_LABEL="$1"
  if ! GD_hook "$2" "$3" "$4"; then return 0; fi
  GD_verdict
  if [ "$GD_RC" -eq 0 ] && [ "$GD_V_OUTCOME" = "empty" ]; then
    ok "guarddocs: $GD_A_LABEL"
  else
    bad "guarddocs: $GD_A_LABEL" "rc=$GD_RC outcome=$GD_V_OUTCOME out=[$(cat "$GD_H_OUT")]"
  fi
}

# -- 1-2. every muse-task line in the agent body passes the guard -----------
cat > "$GD/extract.py" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read().replace("\r\n", "\n")
fenced = []
inside = False
for line in src.splitlines():
    if line.strip().startswith("```"):
        inside = not inside
        continue
    if inside:
        tok = line.strip().split(None, 1)
        if tok and tok[0] == "muse-task":
            fenced.append(line.strip())
plain_lines = []
inside = False
for line in src.splitlines():
    if line.strip().startswith("```"):
        inside = not inside
        continue
    if not inside:
        plain_lines.append(line)
inline = [s for s in re.findall(r"`([^`\n]*)`", "\n".join(plain_lines))
          if s.startswith("muse-task")]
sub = re.compile(r"<[^<>]*>")
with open(sys.argv[2], "w", encoding="utf-8") as f:
    for line in fenced + inline:
        f.write(sub.sub("x", line) + "\n")
print("FENCED %d" % len(fenced))
print("SECOND %s" % ",".join(sorted({l.split()[1] for l in fenced if len(l.split()) > 1})))
print("INLINE %d" % len(inline))
PY
GD_EMPTY="$GD/empty"; mkdir -p "$GD_EMPTY"
GD_EXTRACT_OUT="$(python3 "$GD/extract.py" "$SKILL/agents/muse-supervisor.md" "$GD/lines.sub" 2>&1 | tr -d '\r')"
GD_FENCED="$(printf '%s' "$GD_EXTRACT_OUT" | sed -n 's/^FENCED //p')"
GD_SECOND="$(printf '%s' "$GD_EXTRACT_OUT" | sed -n 's/^SECOND //p')"
GD_INLINE_N="$(printf '%s' "$GD_EXTRACT_OUT" | sed -n 's/^INLINE //p')"
GD_FENCED_OK=1
if [ -z "${GD_FENCED:-}" ] || [ "$GD_FENCED" -lt 5 ] 2>/dev/null; then GD_FENCED_OK=0; fi
for GD_TOK in run verify revise show finish; do
  case ",$GD_SECOND," in *",$GD_TOK,"*) ;; *) GD_FENCED_OK=0;; esac
done
if [ -z "${GD_INLINE_N:-}" ]; then GD_FENCED_OK=0; fi
if [ "$GD_FENCED_OK" -ne 1 ]; then
  bad "guarddocs: every muse-task line in the agent body is allowed by the guard" "extraction measured nothing: [$GD_EXTRACT_OUT]"
else
  GD_DENIED=""
  GD_NLINES=0
  while IFS= read -r GD_LINE; do
    [ -n "$GD_LINE" ] || continue
    GD_NLINES=$((GD_NLINES+1))
    if ! GD_hook "$GD_LINE" "$(native_path "$GD_EMPTY")" "$(native_path "$GD_EMPTY")"; then
      GD_DENIED="$GD_DENIED
(hook failed) $GD_LINE"
      continue
    fi
    GD_verdict
    if [ "$GD_V_OUTCOME" != "empty" ]; then
      GD_DENIED="$GD_DENIED
$GD_LINE"
    fi
  done < "$GD/lines.sub"
  if [ "$GD_NLINES" -eq 0 ]; then
    bad "guarddocs: every muse-task line in the agent body is allowed by the guard" "no lines extracted"
  elif [ -n "$GD_DENIED" ]; then
    bad "guarddocs: every muse-task line in the agent body is allowed by the guard" "denied:$GD_DENIED"
  else
    ok "guarddocs: every muse-task line in the agent body is allowed by the guard"
  fi
fi

GD_expect_deny "probe: the harness denies the old --verdict accept|revise|reject line" \
  'muse-task finish --id t1 --out /x --verdict accept|revise|reject --summary "..."' \
  "$(native_path "$GD_EMPTY")" "$(native_path "$GD_EMPTY")"

# -- 3. no --feedback-file in supervisor instructions ------------------------
cat > "$GD/check3.py" <<'PY'
import sys
fails = []
agent = open(sys.argv[1], encoding="utf-8").read().replace("\r\n", "\n")
fenced = []
inside = False
for line in agent.splitlines():
    if line.strip().startswith("```"):
        inside = not inside
        continue
    if inside:
        tok = line.strip().split(None, 1)
        if tok and tok[0] == "muse-task":
            fenced.append(line.strip())
if not fenced:
    fails.append("no fenced muse-task lines: the absence check measured nothing")
for line in fenced:
    if "--feedback-file" in line:
        fails.append("fenced line still revises with --feedback-file: %s" % line)
wf = open(sys.argv[2], encoding="utf-8").read().replace("\r\n", "\n")
hits = [l for l in wf.splitlines() if "${TASK} revise" in l]
if not hits or not any(l.strip() for l in hits):
    fails.append("no ${TASK} revise line in the workflow: the absence check measured nothing")
for line in hits:
    if "--feedback-file" in line:
        fails.append("workflow revise line uses --feedback-file: %s" % line.strip())
if fails:
    sys.stdout.write("\n".join(fails) + "\n")
    sys.exit(1)
print("fenced=%d reviseline ok" % len(fenced))
PY
GD_CHECK3_OUT="$(python3 "$GD/check3.py" "$SKILL/agents/muse-supervisor.md" "$SKILL/workflows/muse-supervised-fleet.js" 2>&1 | tr -d '\r')"
GD_CHECK3_RC=$?
if [ "$GD_CHECK3_RC" -eq 0 ]; then
  ok "guarddocs: no supervisor instruction revises with --feedback-file"
else
  bad "guarddocs: no supervisor instruction revises with --feedback-file" "$GD_CHECK3_OUT"
fi

# -- 4-6. the SubagentStop finish command runs as printed --------------------
GD_mkrepo() {
  rm -rf "$1"; mkdir -p "$1"; git init -q -b main "$1"
  printf 'def add(a,b):\n    return a+b\n' > "$1/calc.py"
  git -C "$1" add -A
  git -C "$1" -c user.email=t@l -c user.name=t commit -qm init
}
GD_FIX="$GD/stopfix"
GD_mkrepo "$GD_FIX"
cat > "$GD/stop_setup.py" <<'PY'
import json, os
repo = os.environ["GD_REPO"]
d = os.path.join(repo, ".muse-fleet", "tasks", "gd1")
os.makedirs(d, exist_ok=True)
with open(os.path.join(d, "state.json"), "w", encoding="utf-8") as f:
    json.dump({"id": "gd1", "done": False, "branch": "muse/20260101-gd/gd1",
               "rounds": [{"n": 1}]}, f)
with open(os.path.join(repo, "transcript.jsonl"), "w", encoding="utf-8") as f:
    f.write("run muse/20260101-gd/gd1 ok\n")
PY
GD_REPO="$GD_FIX" python3 "$GD/stop_setup.py"
cat > "$GD/stop_in.py" <<'PY'
import json, sys
print(json.dumps({"hook_event_name": "SubagentStop",
                  "agent_type": "muse:muse-supervisor",
                  "stop_hook_active": False,
                  "agent_transcript_path": sys.argv[1]}))
PY
python3 "$GD/stop_in.py" "$(native_path "$GD_FIX/transcript.jsonl")" > "$GD/stop_in.json" 2>/dev/null
GD_STOP_OUT="$(CLAUDE_PROJECT_DIR="$(native_path "$GD_FIX")" python3 "$GD_STOP" < "$GD/stop_in.json" 2>/dev/null | tr -d '\r')"
cat > "$GD/stop_lines.py" <<'PY'
import json, sys
reason = json.loads(open(sys.argv[1], encoding="utf-8").read()).get("reason", "")
finish = [l for l in reason.splitlines() if l.startswith("muse-task finish")]
rest = [l for l in reason.splitlines() if not l.startswith("muse-task finish")]
with open(sys.argv[2], "w", encoding="utf-8") as f:
    for l in finish:
        f.write(l + "\n")
with open(sys.argv[3], "w", encoding="utf-8") as f:
    f.write("\n".join(rest) + "\n")
print("FINISH %d" % len(finish))
PY
printf '%s' "$GD_STOP_OUT" > "$GD/stop_out.json"
GD_STOP_N="$(python3 "$GD/stop_lines.py" "$GD/stop_out.json" "$GD/finish_lines.txt" "$GD/reason_rest.txt" 2>&1 | tr -d '\r' | sed -n 's/^FINISH //p')"
if [ -z "${GD_STOP_N:-}" ] || [ "$GD_STOP_N" -lt 1 ] 2>/dev/null; then
  bad "guarddocs: the SubagentStop finish command runs as printed" "no muse-task finish line in reason: [$GD_STOP_OUT]"
  GD_FINLINE=""
else
  mkdir -p "$GD/stub"
  cat > "$GD/stub/muse-task" <<'SH'
#!/bin/sh
printf 'CALL\n' >> "$GD_ARGV"
for a in "$@"; do printf '%s\n' "$a" >> "$GD_ARGV"; done
SH
  chmod +x "$GD/stub/muse-task"
  cat > "$GD/argv_check.py" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().replace("\r\n", "\n").splitlines()
fails = []
if lines.count("CALL") != 1 or (lines and lines[0] != "CALL"):
    fails.append("want exactly one CALL first, saw %r" % lines[:5])
args = [l for l in lines if l != "CALL"]
if args.count("--verdict") != 1:
    fails.append("want exactly one --verdict, saw %d in %r" % (args.count("--verdict"), args))
else:
    v = args[args.index("--verdict") + 1]
    if v not in ("accept", "revise", "reject"):
        fails.append("verdict %r not a choice" % v)
if args.count("--id") != 1:
    fails.append("want exactly one --id, saw %r" % args)
elif args[args.index("--id") + 1] != "gd1":
    fails.append("--id %r is not gd1" % args[args.index("--id") + 1])
if fails:
    sys.stdout.write("; ".join(fails) + "\n")
    sys.exit(1)
print("argv ok")
PY
  GD_RUN_OK=1; GD_RUN_WHY=""
  while IFS= read -r GD_FLINE; do
    [ -n "$GD_FLINE" ] || continue
    if [ -z "${GD_FINLINE:-}" ]; then GD_FINLINE="$GD_FLINE"; fi
    : > "$GD/argv.txt"
    GD_ARGV="$GD/argv.txt" PATH="$(shell_path "$GD/stub"):$PATH" bash -c "$GD_FLINE" 2>/dev/null
    GD_SH_RC=$?
    if [ "$GD_SH_RC" -ne 0 ]; then
      GD_RUN_OK=0; GD_RUN_WHY="$GD_RUN_WHY rc=$GD_SH_RC for [$GD_FLINE]"
      continue
    fi
    GD_ARGV_WHY="$(python3 "$GD/argv_check.py" "$GD/argv.txt" 2>&1 | tr -d '\r')"
    if [ $? -ne 0 ]; then
      GD_RUN_OK=0; GD_RUN_WHY="$GD_RUN_WHY $GD_ARGV_WHY"
    fi
  done < "$GD/finish_lines.txt"
  if [ "$GD_RUN_OK" -eq 1 ]; then
    ok "guarddocs: the SubagentStop finish command runs as printed"
  else
    bad "guarddocs: the SubagentStop finish command runs as printed" "$GD_RUN_WHY"
  fi
fi

GD_REST="$(cat "$GD/reason_rest.txt" 2>/dev/null | tr -d '\r')"
GD_MISS=""
case "$GD_REST" in *accept*) ;; *) GD_MISS="$GD_MISS accept";; esac
case "$GD_REST" in *revise*) ;; *) GD_MISS="$GD_MISS revise";; esac
case "$GD_REST" in *reject*) ;; *) GD_MISS="$GD_MISS reject";; esac
if [ -n "$GD_STOP_OUT" ] && [ -z "$GD_MISS" ]; then
  ok "guarddocs: the SubagentStop reason lists accept, revise and reject as choices"
else
  bad "guarddocs: the SubagentStop reason lists accept, revise and reject as choices" "missing:$GD_MISS out=[$GD_STOP_OUT]"
fi

if [ -n "${GD_FINLINE:-}" ]; then
  GD_expect_allow "the SubagentStop finish command is allowed by the guard" \
    "$GD_FINLINE" "$(native_path "$GD_FIX")" "$(native_path "$GD_FIX")"
else
  bad "guarddocs: the SubagentStop finish command is allowed by the guard" "no finish line extracted above"
fi

# -- 7-10. the recorded check works only inside its task's worktree ----------
cat > "$GD/rc_setup.py" <<'PY'
import json, os
gd = os.environ["GD_DIR"]
proj = os.path.join(gd, "rcproj")
wt = os.path.join(gd, "wt", "t1")
os.makedirs(os.path.join(proj, ".muse-fleet", "tasks", "t1"), exist_ok=True)
os.makedirs(os.path.join(wt, "sub"), exist_ok=True)
os.makedirs(os.path.join(gd, "wt", "t1-other"), exist_ok=True)
with open(os.path.join(proj, ".muse-fleet", "tasks", "t1", "state.json"),
          "w", encoding="utf-8") as f:
    json.dump({"id": "t1", "worktree": wt, "done": False,
               "verifications": [{"command": "test -f added.py"}]}, f)
PY
GD_DIR="$GD" python3 "$GD/rc_setup.py"
GD_RCPROJ="$(native_path "$GD/rcproj")"
GD_RCWT="$(native_path "$GD/wt/t1")"
GD_RCSUB="$(native_path "$GD/wt/t1/sub")"
GD_RSIB="$(native_path "$GD/wt/t1-other")"
GD_RCMD="test -f added.py"
GD_expect_deny "a recorded check is refused from the project root" "$GD_RCMD" "$GD_RCPROJ" "$GD_RCPROJ"
GD_expect_deny "a recorded check is refused from a sibling sharing the worktree's name prefix" "$GD_RCMD" "$GD_RSIB" "$GD_RCPROJ"
GD_expect_allow "a recorded check is allowed from inside its task worktree" "$GD_RCMD" "$GD_RCWT" "$GD_RCPROJ"
GD_expect_allow "a recorded check is allowed from a subdirectory of its task worktree" "$GD_RCMD" "$GD_RCSUB" "$GD_RCPROJ"

# -- 11. every 'full script' pointer names a real workflow script ------------
cat > "$GD/check11.py" <<'PY'
import glob, os, re, sys
root = sys.argv[1]
fails = []
found = 0
paths = (glob.glob(os.path.join(root, "references", "*.md"))
         + glob.glob(os.path.join(root, "skills", "*", "SKILL.md"))
         + glob.glob(os.path.join(root, "commands", "*.md"))
         + glob.glob(os.path.join(root, "agents", "*.md")))
for path in sorted(paths):
    for line in open(path, encoding="utf-8").read().replace("\r\n", "\n").splitlines():
        if "full script" not in line:
            continue
        found += 1
        ticked = re.findall(r"`([^`\n]*)`", line)
        if not ticked:
            fails.append("%s: 'full script' line names no path: %s"
                         % (os.path.relpath(path, root), line.strip()[:120]))
            continue
        for cand in ticked:
            full = os.path.join(root, cand)
            if not os.path.isfile(full):
                fails.append("%s: no such file: %s" % (os.path.relpath(path, root), cand))
            elif "export const meta" not in open(full, encoding="utf-8").read():
                fails.append("%s is not a workflow script" % cand)
print("LINES %d" % found)
if fails:
    sys.stdout.write("\n".join(fails) + "\n")
    sys.exit(1)
PY
GD_CHECK11_OUT="$(python3 "$GD/check11.py" "$(native_path "$SKILL")" 2>&1 | tr -d '\r')"
GD_CHECK11_RC=$?
GD_CHECK11_LINES="$(printf '%s' "$GD_CHECK11_OUT" | sed -n 's/^LINES //p')"
if [ "$GD_CHECK11_RC" -eq 0 ] && [ -n "${GD_CHECK11_LINES:-}" ] && [ "$GD_CHECK11_LINES" -ge 1 ] 2>/dev/null; then
  ok "guarddocs: every 'full script' pointer names a real workflow script"
else
  bad "guarddocs: every 'full script' pointer names a real workflow script" "$GD_CHECK11_OUT"
fi

# -- 12. cleanup.md and SECURITY.md name what the code uses ------------------
cat > "$GD/check12.py" <<'PY'
import re, sys
fails = []
cleanup = open(sys.argv[1], encoding="utf-8").read().replace("\r\n", "\n")
paras = [p for p in re.split(r"\n\s*\n", cleanup) if "disposable" in p]
if not paras:
    fails.append("cleanup.md: no paragraph containing 'disposable'")
else:
    for p in paras:
        if "--discard-unharvested" not in p:
            fails.append("cleanup.md: disposable paragraph names no --discard-unharvested")
        if "`--all` is how" in p:
            fails.append("cleanup.md: disposable paragraph still claims `--all` is how")
sec = open(sys.argv[2], encoding="utf-8").read().replace("\r\n", "\n")
paras = [p for p in re.split(r"\n\s*\n", sec)
         if "structurally unmistakable credential" in re.sub(r"\s+", " ", p)]
if not paras:
    fails.append("SECURITY.md: no bullet containing 'structurally unmistakable credential'")
else:
    bull = re.sub(r"\s+", " ", paras[0])
    for claim in ("muse-task run", "muse-fleet", "muse-ask --write", "gitignored"):
        if claim not in bull:
            fails.append("SECURITY.md: credential bullet names no %s" % claim)
if fails:
    sys.stdout.write("\n".join(fails) + "\n")
    sys.exit(1)
print("prose ok")
PY
GD_CHECK12_OUT="$(python3 "$GD/check12.py" "$SKILL/commands/cleanup.md" "$SKILL/SECURITY.md" 2>&1 | tr -d '\r')"
if [ $? -eq 0 ]; then
  ok "guarddocs: cleanup.md and SECURITY.md name the flags and drivers the code uses"
else
  bad "guarddocs: cleanup.md and SECURITY.md name the flags and drivers the code uses" "$GD_CHECK12_OUT"
fi

if [ "$GD_STANDALONE" = 1 ]; then
  printf 'guarddocs: %d passed, %d failed\n' "$PASS" "$FAIL"
  if [ "$FAIL" -gt 0 ] || [ "$PASS" -eq 0 ]; then exit 1; fi
  exit 0
fi
