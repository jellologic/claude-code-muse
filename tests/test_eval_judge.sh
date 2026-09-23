# shellcheck shell=bash
# Offline tests for evals/_lib/judge_replay.py: the replay must rebuild the
# CLI's judge prompt, apply the CLI's vote rule, honour --criteria-file and
# --explain, and refuse non-last_message evidence without calling claude.
# Behaviour is exercised, never source text: a stub claude records its argv
# and raw stdin and prints a canned reply. Every variable is EV_J_-prefixed
# because this file shares validate.sh's global namespace.
EV_J_STANDALONE=0
if ! declare -F ok >/dev/null 2>&1; then
  EV_J_STANDALONE=1
  PASS=0; FAIL=0; SKIP=0
  ok() { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
  bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ -n "${2:-}" ] && echo "        $2"; }
  skip() { local n="$1"; shift; if [ "${CI:-}" = "true" ]; then FAIL=$((FAIL+n)); printf '  \033[31mFAIL\033[0m  SKIP counts as a failure under CI: %s\n' "$*"; else SKIP=$((SKIP+n)); printf '  \033[33mSKIP\033[0m  %s\n' "$*"; fi; }
  SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  LAB="$(mktemp -d "${TMPDIR:-/tmp}/musetest.XXXXXX")"
  # Standalone only: falling off the end must not leave the lab behind under TMPDIR.
  trap 'rm -rf "$LAB"' EXIT
  native_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
  }
fi
if ! declare -F shell_path >/dev/null 2>&1; then
  shell_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi
  }
fi

EV_J_BASE="$LAB/v_eval_judge"
mkdir -p "$EV_J_BASE"
EV_J_REPLAY="$(native_path "$SKILL/evals/_lib/judge_replay.py")"

# Stub claude: records argv (JSON) and raw stdin bytes under $EV_J_REC, one
# numbered stdinN.bin/argvN.json per call plus stdin.bin/argv.json for the
# last call, then answers the k-th call with the k-th item of $EV_J_REPLIES
# (a "|" list) or with $EV_J_REPLY when no list is set. The call counter
# lives in the record dir, not the cwd, because the replay runs each sample
# in a fresh temp cwd. A developer host may carry a real claude while CI
# has none, so tests prepend this dir to PATH and never pass --claude;
# which() then finds the stub first on either machine.
mkdir -p "$EV_J_BASE/bin"
cat > "$EV_J_BASE/bin/fake_claude.py" <<'PYEOF'
import glob, json, os, sys
rec = os.environ.get("EV_J_REC", "")
os.makedirs(rec, exist_ok=True)
n = len(glob.glob(os.path.join(rec, "stdin[0-9]*.bin"))) + 1
data = sys.stdin.buffer.read()
with open(os.path.join(rec, "stdin%d.bin" % n), "wb") as fh:
    fh.write(data)
with open(os.path.join(rec, "stdin.bin"), "wb") as fh:
    fh.write(data)
with open(os.path.join(rec, "argv%d.json" % n), "w", encoding="utf-8") as fh:
    json.dump(sys.argv[1:], fh)
with open(os.path.join(rec, "argv.json"), "w", encoding="utf-8") as fh:
    json.dump(sys.argv[1:], fh)
replies = os.environ.get("EV_J_REPLIES", "")
if replies:
    items = replies.split("|")
    reply = items[min(n - 1, len(items) - 1)]
else:
    reply = os.environ.get("EV_J_REPLY", "")
sys.stdout.write(reply.replace("\\n", "\n"))
PYEOF
printf '#!/bin/sh\nexec "%s" "%s" "$@"\n' "$(command -v python3)" "$EV_J_BASE/bin/fake_claude.py" > "$EV_J_BASE/bin/claude"
chmod +x "$EV_J_BASE/bin/claude"
if command -v cygpath >/dev/null 2>&1; then
  EV_J_NPY="$(native_path "$(command -v python3)")"
  EV_J_NFAKE="$(native_path "$EV_J_BASE/bin/fake_claude.py")"
  printf '@echo off\r\n"%s" "%s" %%*\r\n' "$EV_J_NPY" "$EV_J_NFAKE" > "$EV_J_BASE/bin/claude.cmd"
fi

# Fixture report in the real `claude plugin eval --json` shape.
cat > "$EV_J_BASE/report.json" <<'JSONEOF'
{"cases": [{"name": "demo-case", "graders": [{"name": "behaviour", "type": "llm", "config": {"criteria": "CRIT-MARKER: decline to merge without a check\n", "focus": "last_message"}}, {"name": "skill-triggered", "type": "tool_used", "config": {}}], "arms": {"with": [{"score": 1, "graders": [{"name": "behaviour", "passed": true, "explanation": "judge votes: PASS PASS PASS", "evidence": "No, not yet. EVIDENCE-MARKER: the patches conflict."}, {"name": "skill-triggered", "passed": true, "explanation": "Skill called 1x"}]}]}}]}
JSONEOF

# EV_J_RUN <recname>: clear the record dir and run the replay with the stub
# first on PATH; sets EV_J_RC and EV_J_OUT.
EV_J_RUN() {
  EV_J_RECNAME="$1"; shift
  EV_J_RECDIR="$EV_J_BASE/rec-$EV_J_RECNAME"
  rm -rf "$EV_J_RECDIR"; mkdir -p "$EV_J_RECDIR"
  EV_J_OUT="$(EV_J_REC="$(native_path "$EV_J_RECDIR")" EV_J_REPLY="$EV_J_REPLY" EV_J_REPLIES="${EV_J_REPLIES:-}" PATH="$(shell_path "$EV_J_BASE/bin"):$PATH" python3 "$EV_J_REPLAY" "$@" 2>&1)"
  EV_J_RC=$?
}

# EV_J_RUN_NOCLAUDE <recname>: like EV_J_RUN but with claude absent from PATH
# and python by absolute path. A refusal that happened after binary resolution
# would print "no claude binary found" instead of naming its cause, which is
# how the refusal checks below prove the refusals come first.
EV_J_RUN_NOCLAUDE() {
  EV_J_RECNAME="$1"; shift
  EV_J_RECDIR="$EV_J_BASE/rec-$EV_J_RECNAME"
  rm -rf "$EV_J_RECDIR"; mkdir -p "$EV_J_RECDIR"
  EV_J_OUT="$(EV_J_REC="$(native_path "$EV_J_RECDIR")" PATH="$EV_J_NOCLAUDE_PATH" "$EV_J_PY" "$EV_J_REPLAY" "$@" 2>&1)"
  EV_J_RC=$?
}

EV_J_SYS="You are a strict, terse evaluation judge for coding-agent traces."
EV_J_ONEWORD="Respond with exactly one word: PASS or FAIL."

# 1. The replay sends the CLI judge prompt and system prompt. The argv half is
# judged by a checker that prints exactly `ok`: the previous inline `python3
# -c` signalled only through its exit code while the test read its (always
# empty) stdout, so deleting "-p" from the replay still passed.
cat > "$EV_J_BASE/argv_check.py" <<'PYEOF'
import json
import sys
expected = sys.argv[1]
try:
    argv = json.loads(sys.stdin.read())
except ValueError as exc:
    print("argv is not JSON: %s" % exc)
else:
    missing = []
    if "-p" not in argv:
        missing.append("missing -p")
    if "--model" in argv:
        at = argv.index("--model")
        if at + 1 >= len(argv) or argv[at + 1] != "haiku":
            missing.append("judge model is not haiku")
    else:
        missing.append("missing --model haiku")
    if "--system-prompt" in argv:
        at = argv.index("--system-prompt")
        if at + 1 >= len(argv) or argv[at + 1] != expected:
            missing.append("--system-prompt value differs")
    else:
        missing.append("missing --system-prompt")
    if "--tools" in argv:
        at = argv.index("--tools")
        if at + 1 >= len(argv) or argv[at + 1] != "":
            missing.append("--tools value is not the empty string")
    else:
        missing.append("missing --tools")
    if "--setting-sources" in argv:
        at = argv.index("--setting-sources")
        if at + 1 >= len(argv) or argv[at + 1] != "":
            missing.append("--setting-sources value is not the empty string")
    else:
        missing.append("missing --setting-sources")
    if missing:
        print("; ".join(missing))
    else:
        print("ok")
PYEOF
EV_J_CHECK="$(native_path "$EV_J_BASE/argv_check.py")"
EV_J_REPLY="PASS"
EV_J_RUN one --report "$(native_path "$EV_J_BASE/report.json")" --case demo-case
if [ "$EV_J_RC" -ne 0 ]; then
  bad "evals: judge: replay sends the CLI judge prompt and system prompt" "rc=$EV_J_RC out='$EV_J_OUT'"
elif [ ! -s "$EV_J_BASE/rec-one/stdin.bin" ] || [ ! -s "$EV_J_BASE/rec-one/argv.json" ]; then
  bad "evals: judge: replay sends the CLI judge prompt and system prompt" "stub recorded nothing (rc=$EV_J_RC)"
else
  EV_J_STDIN="$(tr -d '\r' < "$EV_J_BASE/rec-one/stdin.bin")"
  EV_J_LAST="$(printf '%s' "$EV_J_STDIN" | tail -1)"
  EV_J_ARGVOK="$(python3 "$EV_J_CHECK" "$EV_J_SYS" < "$EV_J_BASE/rec-one/argv.json" | tr -d '\r')"
  if printf '%s' "$EV_J_STDIN" | grep -q 'CRIT-MARKER' \
    && printf '%s' "$EV_J_STDIN" | grep -q 'Agent output (last_message):' \
    && printf '%s' "$EV_J_STDIN" | grep -q 'EVIDENCE-MARKER' \
    && [ "$EV_J_LAST" = "$EV_J_ONEWORD" ] \
    && [ "$EV_J_ARGVOK" = "ok" ]; then
    ok "evals: judge: replay sends the CLI judge prompt and system prompt"
  else
    bad "evals: judge: replay sends the CLI judge prompt and system prompt" "last='$EV_J_LAST' argvcheck='$EV_J_ARGVOK'"
  fi
fi

# The five probes below mutate the REAL recorded argv, so each proves the
# checker fires on the exact breakage it names; a probe against an empty
# recording would pass trivially, hence the non-empty guard on each.
if [ ! -s "$EV_J_BASE/rec-one/argv.json" ]; then
  bad "evals: judge: argv check fires when -p is missing" "recorded argv is empty; the probe would prove nothing"
else
  EV_J_PROBE="$(python3 -c 'import json,sys; a=json.load(open(sys.argv[1])); a.remove("-p"); print(json.dumps(a))' "$(native_path "$EV_J_BASE/rec-one/argv.json")" | python3 "$EV_J_CHECK" "$EV_J_SYS" | tr -d '\r')"
  if [ "$EV_J_PROBE" = "ok" ]; then
    bad "evals: judge: argv check fires when -p is missing" "checker still says ok without -p"
  else
    ok "evals: judge: argv check fires when -p is missing"
  fi
fi
if [ ! -s "$EV_J_BASE/rec-one/argv.json" ]; then
  bad "evals: judge: argv check fires when the judge model is not haiku" "recorded argv is empty; the probe would prove nothing"
else
  EV_J_PROBE="$(python3 -c 'import json,sys; a=json.load(open(sys.argv[1])); a[a.index("--model")+1]="sonnet"; print(json.dumps(a))' "$(native_path "$EV_J_BASE/rec-one/argv.json")" | python3 "$EV_J_CHECK" "$EV_J_SYS" | tr -d '\r')"
  if [ "$EV_J_PROBE" = "ok" ]; then
    bad "evals: judge: argv check fires when the judge model is not haiku" "checker still says ok for sonnet"
  else
    ok "evals: judge: argv check fires when the judge model is not haiku"
  fi
fi
if [ ! -s "$EV_J_BASE/rec-one/argv.json" ]; then
  bad "evals: judge: argv check fires when --system-prompt is missing" "recorded argv is empty; the probe would prove nothing"
else
  EV_J_PROBE="$(python3 -c 'import json,sys; a=json.load(open(sys.argv[1])); del a[a.index("--system-prompt"):a.index("--system-prompt")+2]; print(json.dumps(a))' "$(native_path "$EV_J_BASE/rec-one/argv.json")" | python3 "$EV_J_CHECK" "$EV_J_SYS" | tr -d '\r')"
  if [ "$EV_J_PROBE" = "ok" ]; then
    bad "evals: judge: argv check fires when --system-prompt is missing" "checker still says ok without --system-prompt"
  else
    ok "evals: judge: argv check fires when --system-prompt is missing"
  fi
fi
if [ ! -s "$EV_J_BASE/rec-one/argv.json" ]; then
  bad "evals: judge: argv check fires when --tools is missing" "recorded argv is empty; the probe would prove nothing"
else
  EV_J_PROBE="$(python3 -c 'import json,sys; a=json.load(open(sys.argv[1])); del a[a.index("--tools"):a.index("--tools")+2]; print(json.dumps(a))' "$(native_path "$EV_J_BASE/rec-one/argv.json")" | python3 "$EV_J_CHECK" "$EV_J_SYS" | tr -d '\r')"
  if [ "$EV_J_PROBE" = "ok" ]; then
    bad "evals: judge: argv check fires when --tools is missing" "checker still says ok without --tools"
  else
    ok "evals: judge: argv check fires when --tools is missing"
  fi
fi
if [ ! -s "$EV_J_BASE/rec-one/argv.json" ]; then
  bad "evals: judge: argv check fires when --setting-sources is missing" "recorded argv is empty; the probe would prove nothing"
else
  EV_J_PROBE="$(python3 -c 'import json,sys; a=json.load(open(sys.argv[1])); del a[a.index("--setting-sources"):a.index("--setting-sources")+2]; print(json.dumps(a))' "$(native_path "$EV_J_BASE/rec-one/argv.json")" | python3 "$EV_J_CHECK" "$EV_J_SYS" | tr -d '\r')"
  if [ "$EV_J_PROBE" = "ok" ]; then
    bad "evals: judge: argv check fires when --setting-sources is missing" "checker still says ok without --setting-sources"
  else
    ok "evals: judge: argv check fires when --setting-sources is missing"
  fi
fi

# 2. A PASS reply that says "fail" is a FAIL vote under the CLI's rule.
EV_J_REPLY='PASS\nthe other three patches fail to apply'
EV_J_RUN two --report "$(native_path "$EV_J_BASE/report.json")" --case demo-case
if [ ! -s "$EV_J_BASE/rec-two/stdin.bin" ]; then
  bad "evals: judge: a PASS reply that says fail is a FAIL vote" "stub recorded nothing (rc=$EV_J_RC)"
elif [ "$EV_J_RC" -ne 1 ]; then
  bad "evals: judge: a PASS reply that says fail is a FAIL vote" "rc=$EV_J_RC want 1 out='$(printf '%s' "$EV_J_OUT" | tr -d '\r' | head -3)'"
elif printf '%s' "$EV_J_OUT" | tr -d '\r' | grep -q 'vote=FAIL'; then
  ok "evals: judge: a PASS reply that says fail is a FAIL vote"
else
  bad "evals: judge: a PASS reply that says fail is a FAIL vote" "out='$(printf '%s' "$EV_J_OUT" | tr -d '\r' | head -3)'"
fi

# 3. A bare FAIL reply fails the run.
EV_J_REPLY="FAIL"
EV_J_RUN three --report "$(native_path "$EV_J_BASE/report.json")" --case demo-case
if [ ! -s "$EV_J_BASE/rec-three/stdin.bin" ]; then
  bad "evals: judge: a bare FAIL reply fails the run" "stub recorded nothing (rc=$EV_J_RC)"
elif [ "$EV_J_RC" -ne 1 ]; then
  bad "evals: judge: a bare FAIL reply fails the run" "rc=$EV_J_RC want 1 out='$(printf '%s' "$EV_J_OUT" | tr -d '\r' | head -3)'"
else
  ok "evals: judge: a bare FAIL reply fails the run"
fi

# 4. --criteria-file grades with the grader file's criteria block.
printf -- '---\ntype: llm\ncriteria: |\n  FILE-CRIT-ONE\n  FILE-CRIT-TWO\n---\n' > "$EV_J_BASE/grader.md"
EV_J_REPLY="PASS"
EV_J_RUN four --report "$(native_path "$EV_J_BASE/report.json")" --case demo-case --criteria-file "$(native_path "$EV_J_BASE/grader.md")"
if [ ! -s "$EV_J_BASE/rec-four/stdin.bin" ]; then
  bad "evals: judge: --criteria-file grades with the grader file's criteria block" "stub recorded nothing (rc=$EV_J_RC)"
else
  EV_J_STDIN4="$(tr -d '\r' < "$EV_J_BASE/rec-four/stdin.bin")"
  if printf '%s' "$EV_J_STDIN4" | grep -q 'FILE-CRIT-ONE' \
    && printf '%s' "$EV_J_STDIN4" | grep -q 'FILE-CRIT-TWO' \
    && ! printf '%s' "$EV_J_STDIN4" | grep -q '  FILE-CRIT' \
    && ! printf '%s' "$EV_J_STDIN4" | grep -q 'CRIT-MARKER'; then
    ok "evals: judge: --criteria-file grades with the grader file's criteria block"
  else
    bad "evals: judge: --criteria-file grades with the grader file's criteria block" "criteria block not applied as expected"
  fi
fi

# 5. --explain asks the judge to quote the unmet requirement.
EV_J_REPLY="PASS"
EV_J_RUN five --report "$(native_path "$EV_J_BASE/report.json")" --case demo-case --explain
if [ ! -s "$EV_J_BASE/rec-five/stdin.bin" ]; then
  bad "evals: judge: --explain asks the judge to quote the unmet requirement" "stub recorded nothing (rc=$EV_J_RC)"
else
  EV_J_LAST5="$(tr -d '\r' < "$EV_J_BASE/rec-five/stdin.bin" | tail -1)"
  if [ "$EV_J_RC" -ne 0 ]; then
    bad "evals: judge: --explain asks the judge to quote the unmet requirement" "rc=$EV_J_RC want 0"
  elif [ "$EV_J_LAST5" = "$EV_J_ONEWORD" ]; then
    bad "evals: judge: --explain asks the judge to quote the unmet requirement" "last line is still the one-word instruction"
  elif printf '%s' "$EV_J_LAST5" | grep -qi 'quote'; then
    ok "evals: judge: --explain asks the judge to quote the unmet requirement"
  else
    bad "evals: judge: --explain asks the judge to quote the unmet requirement" "last='$EV_J_LAST5'"
  fi
fi

# 5b. The prompt bytes are exactly the CLI 2.1.280 template. The helper reads
# tests/fixtures/judge_prompt_2.1.280.txt (the Ep template with its JS
# placeholders), strips \r plus one trailing \n from the fixture copy only,
# and substitutes the report criteria, the last_message focus label, the
# verbatim evidence and the instruction; the result must equal the RAW stdin
# bytes (no \r stripping) of EVERY recorded sample. The markers are
# multi-line with criteria text distinct from evidence text, so swapping the
# two cannot hide.
cat > "$EV_J_BASE/report-multi.json" <<'MJSONEOF'
{"cases": [{"name": "demo-case", "graders": [{"name": "behaviour", "type": "llm", "config": {"criteria": "CRIT-LINE-A\nCRIT-LINE-B\n", "focus": "last_message"}}], "arms": {"with": [{"score": 1, "graders": [{"name": "behaviour", "passed": true, "explanation": "judge votes: PASS PASS PASS", "evidence": "EV-LINE-1\n\nEV-LINE-2"}]}]}}]}
MJSONEOF
cat > "$EV_J_BASE/prompt_check.py" <<'PCEOF'
import sys
fixture = open(sys.argv[1], "rb").read().decode("utf-8").replace("\r", "")
if fixture.endswith("\n"):
    fixture = fixture[:-1]
criteria = open(sys.argv[2], "rb").read().decode("utf-8")
evidence = open(sys.argv[3], "rb").read().decode("utf-8")
instruction = open(sys.argv[4], "rb").read().decode("utf-8")
recorded = open(sys.argv[5], "rb").read()
want = (fixture.replace("${e.criteria}", criteria)
        .replace("${Ro(e.focus)}", "last_message")
        .replace("${h}", evidence)
        .replace("${s}", instruction).encode("utf-8"))
if recorded == want:
    print("ok")
else:
    print("mismatch: got=%r want=%r" % (recorded, want))
PCEOF
EV_J_PCHECK="$(native_path "$EV_J_BASE/prompt_check.py")"
EV_J_FIXTURE="$(native_path "$SKILL/tests/fixtures/judge_prompt_2.1.280.txt")"
printf 'CRIT-LINE-A\nCRIT-LINE-B\n' > "$EV_J_BASE/crit.txt"
printf 'EV-LINE-1\n\nEV-LINE-2' > "$EV_J_BASE/ev.bin"
printf '%s' "$EV_J_ONEWORD" > "$EV_J_BASE/instr-one.txt"
EV_J_EXPLAIN="Respond with PASS or FAIL on the first line and, if FAIL, quote the unmet part of the criterion."
printf '%s' "$EV_J_EXPLAIN" > "$EV_J_BASE/instr-explain.txt"
EV_J_CRIT="$(native_path "$EV_J_BASE/crit.txt")"
EV_J_EV="$(native_path "$EV_J_BASE/ev.bin")"
EV_J_INSTR_ONE="$(native_path "$EV_J_BASE/instr-one.txt")"
EV_J_INSTR_EXPLAIN="$(native_path "$EV_J_BASE/instr-explain.txt")"
# EV_J_PROMPT_OK <recname> <label> <instruction-file>: every recorded sample
# (stdin1..3.bin) must be byte-identical to the template substitution.
EV_J_PROMPT_OK() {
  EV_J_P_REC="$EV_J_BASE/rec-$1"; EV_J_P_LABEL="$2"; EV_J_P_INSTR="$3"
  EV_J_P_K=0
  for EV_J_P_K in 1 2 3; do
    if [ ! -s "$EV_J_P_REC/stdin$EV_J_P_K.bin" ]; then
      bad "$EV_J_P_LABEL" "sample $EV_J_P_K recorded nothing; the comparison would prove nothing"
      return
    fi
    EV_J_P_GOT="$(python3 "$EV_J_PCHECK" "$EV_J_FIXTURE" "$EV_J_CRIT" "$EV_J_EV" "$EV_J_P_INSTR" "$(native_path "$EV_J_P_REC/stdin$EV_J_P_K.bin")" | tr -d '\r')"
    if [ "$EV_J_P_GOT" != "ok" ]; then
      bad "$EV_J_P_LABEL" "sample $EV_J_P_K: $EV_J_P_GOT"
      return
    fi
  done
  if [ -e "$EV_J_P_REC/stdin4.bin" ]; then
    bad "$EV_J_P_LABEL" "stub saw more than 3 samples"
    return
  fi
  ok "$EV_J_P_LABEL"
}
EV_J_REPLIES=""
EV_J_REPLY="PASS"
EV_J_RUN six --report "$(native_path "$EV_J_BASE/report-multi.json")" --case demo-case
EV_J_PROMPT_OK six "evals: judge: prompt is byte-identical to the CLI 2.1.280 template" "$EV_J_INSTR_ONE"

# Self-test: the comparator above must be able to fire. Feed it the recorded
# bytes with the Criterion label removed and require a mismatch; the
# non-empty guard keeps an empty recording from proving anything.
if [ ! -s "$EV_J_BASE/rec-six/stdin1.bin" ]; then
  bad "evals: judge: prompt comparator fires on a broken template" "recorded stdin is empty; the probe would prove nothing"
else
  python3 -c 'import sys; d=open(sys.argv[1],"rb").read(); open(sys.argv[2],"wb").write(d.replace(b"Criterion:\n", b""))' "$(native_path "$EV_J_BASE/rec-six/stdin1.bin")" "$(native_path "$EV_J_BASE/broken.bin")"
  EV_J_BROKEN_GOT="$(python3 "$EV_J_PCHECK" "$EV_J_FIXTURE" "$EV_J_CRIT" "$EV_J_EV" "$EV_J_INSTR_ONE" "$(native_path "$EV_J_BASE/broken.bin")" | tr -d '\r')"
  if [ "$EV_J_BROKEN_GOT" = "ok" ]; then
    bad "evals: judge: prompt comparator fires on a broken template" "comparator still says ok without the Criterion label"
  else
    ok "evals: judge: prompt comparator fires on a broken template"
  fi
fi

# --criteria-file path: the grader block holds the same text plus a trailing
# blank line before `---`, which only the clip semantics absorb.
printf -- '---\ntype: llm\ncriteria: |\n  CRIT-LINE-A\n  CRIT-LINE-B\n\n---\n' > "$EV_J_BASE/grader-multi.md"
EV_J_RUN seven --report "$(native_path "$EV_J_BASE/report-multi.json")" --case demo-case --criteria-file "$(native_path "$EV_J_BASE/grader-multi.md")"
EV_J_PROMPT_OK seven "evals: judge: --criteria-file prompt is byte-identical to the CLI 2.1.280 template" "$EV_J_INSTR_ONE"

# --explain path: same template with the explain instruction as ${s}.
EV_J_RUN eight --report "$(native_path "$EV_J_BASE/report-multi.json")" --case demo-case --explain
EV_J_PROMPT_OK eight "evals: judge: --explain prompt is byte-identical to the CLI 2.1.280 template" "$EV_J_INSTR_EXPLAIN"

# Disagreeing samples: the stub answers the k-th call with the k-th item of
# $EV_J_REPLIES. A 2-1 split either way must follow the majority, which kills
# both an any-vote-passes (>= 1) and an all-must-pass (== len) rule.
EV_J_REPLIES="PASS|FAIL|FAIL"
EV_J_RUN nine --report "$(native_path "$EV_J_BASE/report-multi.json")" --case demo-case
EV_J_NINECALLS=0
for EV_J_K in 1 2 3 4; do [ -f "$EV_J_BASE/rec-nine/stdin$EV_J_K.bin" ] && EV_J_NINECALLS=$((EV_J_NINECALLS+1)); done
if [ "$EV_J_NINECALLS" -ne 3 ]; then
  bad "evals: judge: disagreeing samples PASS FAIL FAIL fail the run" "stub saw $EV_J_NINECALLS calls, want exactly 3"
elif [ "$EV_J_RC" -ne 1 ]; then
  bad "evals: judge: disagreeing samples PASS FAIL FAIL fail the run" "rc=$EV_J_RC want 1 out='$(printf '%s' "$EV_J_OUT" | tr -d '\r' | tail -2)'"
elif printf '%s' "$EV_J_OUT" | tr -d '\r' | grep -q 'votes: PASS FAIL FAIL -> FAIL'; then
  ok "evals: judge: disagreeing samples PASS FAIL FAIL fail the run"
else
  bad "evals: judge: disagreeing samples PASS FAIL FAIL fail the run" "out='$(printf '%s' "$EV_J_OUT" | tr -d '\r' | tail -2)'"
fi
EV_J_REPLIES="FAIL|PASS|PASS"
EV_J_RUN ten --report "$(native_path "$EV_J_BASE/report-multi.json")" --case demo-case
EV_J_TENCALLS=0
for EV_J_K in 1 2 3 4; do [ -f "$EV_J_BASE/rec-ten/stdin$EV_J_K.bin" ] && EV_J_TENCALLS=$((EV_J_TENCALLS+1)); done
if [ "$EV_J_TENCALLS" -ne 3 ]; then
  bad "evals: judge: disagreeing samples FAIL PASS PASS pass the run" "stub saw $EV_J_TENCALLS calls, want exactly 3"
elif [ "$EV_J_RC" -ne 0 ]; then
  bad "evals: judge: disagreeing samples FAIL PASS PASS pass the run" "rc=$EV_J_RC want 0 out='$(printf '%s' "$EV_J_OUT" | tr -d '\r' | tail -2)'"
elif printf '%s' "$EV_J_OUT" | tr -d '\r' | grep -q 'votes: FAIL PASS PASS -> PASS'; then
  ok "evals: judge: disagreeing samples FAIL PASS PASS pass the run"
else
  bad "evals: judge: disagreeing samples FAIL PASS PASS pass the run" "out='$(printf '%s' "$EV_J_OUT" | tr -d '\r' | tail -2)'"
fi
EV_J_REPLIES=""

# 6a. The replay script must exist: python exits 2 for a missing file too, so
# without this the refusal checks below could pass with nothing under test.
if [ -f "$SKILL/evals/_lib/judge_replay.py" ]; then
  ok "evals: judge: judge_replay.py exists"
else
  bad "evals: judge: judge_replay.py exists" "replay script is missing; the refusal checks would prove nothing"
fi

# 6b. Precondition for the refusal runs: a PATH with no claude on it. Without
# this guard a host claude could answer and the refusals would prove nothing.
EV_J_PY="$(command -v python3)"
EV_J_PYDIR="$(dirname "$EV_J_PY")"
mkdir -p "$EV_J_BASE/noclaude"
EV_J_NOCLAUDE_PATH="$(shell_path "$EV_J_BASE/noclaude")"
EV_J_WHICH="$(PATH="$EV_J_NOCLAUDE_PATH" "$EV_J_PY" -c 'import shutil; print(shutil.which("claude"))' 2>&1 | tr -d '\r')"
if [ "$EV_J_WHICH" != "None" ] && command -v cygpath >/dev/null 2>&1; then
  # A bare-PATH python may not start on Windows (its own directory can be
  # needed beside the exe); retry with it appended. The None assertion below
  # stays the guard either way.
  EV_J_NOCLAUDE_PATH="$(shell_path "$EV_J_BASE/noclaude"):$(shell_path "$EV_J_PYDIR")"
  EV_J_WHICH="$(PATH="$EV_J_NOCLAUDE_PATH" "$EV_J_PY" -c 'import shutil; print(shutil.which("claude"))' 2>&1 | tr -d '\r')"
fi
if [ "$EV_J_WHICH" = "None" ]; then
  ok "evals: judge: the no-claude PATH really hides claude"
else
  bad "evals: judge: the no-claude PATH really hides claude" "shutil.which(claude)='$EV_J_WHICH'"
fi

# 6c. A trace-focus grader is refused before any judge call. The fixture has
# NON-EMPTY evidence, so only the focus refusal can stop it; and claude is
# absent, so a refusal that happened after binary resolution would say "no
# claude binary found" instead of naming focus. An empty fixture would make
# the evidence refusal fire instead, proving nothing about focus.
cat > "$EV_J_BASE/report-focus.json" <<'JSONEOF'
{"cases": [{"name": "demo-case", "graders": [{"name": "behaviour", "type": "llm", "config": {"criteria": "CRIT-MARKER\n", "focus": "trace"}}], "arms": {"with": [{"score": 0, "graders": [{"name": "behaviour", "passed": false, "explanation": "trace evidence present", "evidence": "EVIDENCE-MARKER: a full trace"}]}]}}]}
JSONEOF
EV_J_RUN_NOCLAUDE focus --report "$(native_path "$EV_J_BASE/report-focus.json")" --case demo-case
EV_J_FOCUSOUT="$(printf '%s' "$EV_J_OUT" | tr -d '\r')"
if [ ! -s "$EV_J_BASE/report-focus.json" ]; then
  bad "evals: judge: trace focus is refused before any judge call" "fixture report is empty; the refusal would prove nothing"
elif [ "$EV_J_RC" -ne 2 ]; then
  bad "evals: judge: trace focus is refused before any judge call" "rc=$EV_J_RC want 2 out='$(printf '%s' "$EV_J_FOCUSOUT" | head -3)'"
elif ! printf '%s' "$EV_J_FOCUSOUT" | grep -q 'focus'; then
  bad "evals: judge: trace focus is refused before any judge call" "output names no focus: '$(printf '%s' "$EV_J_FOCUSOUT" | head -3)'"
elif ! printf '%s' "$EV_J_FOCUSOUT" | grep -q 'trace'; then
  bad "evals: judge: trace focus is refused before any judge call" "output names no trace: '$(printf '%s' "$EV_J_FOCUSOUT" | head -3)'"
elif printf '%s' "$EV_J_FOCUSOUT" | grep -q 'no claude binary'; then
  bad "evals: judge: trace focus is refused before any judge call" "refusal came after binary resolution"
elif [ -e "$EV_J_BASE/rec-focus/stdin.bin" ]; then
  bad "evals: judge: trace focus is refused before any judge call" "claude was called despite the refusal"
else
  ok "evals: judge: trace focus is refused before any judge call"
fi

# 6d. A grader with no last-message evidence is refused before any judge call.
# The fixture uses focus last_message, so only the evidence refusal can stop
# it; claude is absent for the same reason as in 6c.
cat > "$EV_J_BASE/report-noev.json" <<'JSONEOF'
{"cases": [{"name": "demo-case", "graders": [{"name": "behaviour", "type": "llm", "config": {"criteria": "CRIT-MARKER\n", "focus": "last_message"}}], "arms": {"with": [{"score": 0, "graders": [{"name": "behaviour", "passed": false, "explanation": "no evidence"}]}]}}]}
JSONEOF
EV_J_RUN_NOCLAUDE noev --report "$(native_path "$EV_J_BASE/report-noev.json")" --case demo-case
EV_J_NOEVOUT="$(printf '%s' "$EV_J_OUT" | tr -d '\r')"
if [ ! -s "$EV_J_BASE/report-noev.json" ]; then
  bad "evals: judge: missing evidence is refused before any judge call" "fixture report is empty; the refusal would prove nothing"
elif [ "$EV_J_RC" -ne 2 ]; then
  bad "evals: judge: missing evidence is refused before any judge call" "rc=$EV_J_RC want 2 out='$(printf '%s' "$EV_J_NOEVOUT" | head -3)'"
elif ! printf '%s' "$EV_J_NOEVOUT" | grep -q 'evidence'; then
  bad "evals: judge: missing evidence is refused before any judge call" "output names no evidence: '$(printf '%s' "$EV_J_NOEVOUT" | head -3)'"
elif printf '%s' "$EV_J_NOEVOUT" | grep -q 'no claude binary'; then
  bad "evals: judge: missing evidence is refused before any judge call" "refusal came after binary resolution"
elif [ -e "$EV_J_BASE/rec-noev/stdin.bin" ]; then
  bad "evals: judge: missing evidence is refused before any judge call" "claude was called despite the refusal"
else
  ok "evals: judge: missing evidence is refused before any judge call"
fi

if [ "$EV_J_STANDALONE" -eq 1 ]; then exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1); fi
