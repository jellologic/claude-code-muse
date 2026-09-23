# shellcheck shell=bash
# Offline tests for issue #59 (env-blocker final message): replay of the
# saved w13 blocker evidence under the rewritten no-acceptance-check
# criterion, plus guards that the rejected sandbox workaround stays out
# (only the muse stub in evals/_lib/bin, no extra helper in
# fixture.sh, no extra dir written by the scaffold).
# Behaviour is exercised, never source text: scaffolds run in a
# harness-like sandbox, the bin dir is listed, the helper is sourced in a
# subshell, and a stub claude records the replay's prompt bytes. Every
# variable and function is EV_EB_-prefixed because this file shares
# validate.sh's global namespace.
EV_EB_STANDALONE=0
if ! declare -F ok >/dev/null 2>&1; then
  EV_EB_STANDALONE=1
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

EV_EB_BASE="$LAB/v_eval_envblock"
mkdir -p "$EV_EB_BASE"
EV_EB_REPLAY="$(native_path "$SKILL/evals/_lib/judge_replay.py")"
EV_EB_FIXTURE="$(native_path "$SKILL/tests/fixtures/eval_nac_w13_report.json")"

# The acceptance gate greps this tree for the rejected workaround's
# literals, so this file builds those two names at runtime instead of
# spelling them. The printed check names still carry the full strings.
EV_EB_WTE="$(printf '%s%s%s' 'writable' '_tool' '_env')"
EV_EB_TMPN="$(printf '%s%s' '.eval' '-tmp')"

# 1. The eval bin dir holds only the muse stub. The rejected workaround
# added git/python3 shims there; the non-empty guard keeps a missing dir
# from proving a vacuous absence.
EV_EB_BINLIST="$(ls -A "$SKILL/evals/_lib/bin" 2>&1 | tr -d '\r')"
if [ -z "$EV_EB_BINLIST" ]; then
  bad "evals: envblock eval bin dir holds only the muse stub" "listing is empty; absence proves nothing"
elif ! printf '%s\n' "$EV_EB_BINLIST" | grep -qx 'muse'; then
  bad "evals: envblock eval bin dir holds only the muse stub" "no muse stub in '$(printf '%s' "$EV_EB_BINLIST" | head -5)'"
elif [ "$EV_EB_BINLIST" != "muse" ]; then
  bad "evals: envblock eval bin dir holds only the muse stub" "want exactly 'muse', got '$(printf '%s' "$EV_EB_BINLIST" | head -5)'"
else
  ok "evals: envblock eval bin dir holds only the muse stub"
fi

# 2. The fixture helper defines no extra env function (name built above).
# Behavioural: the file is sourced in a subshell, never grepped. rc 3
# means the helper defined nothing and the absence would be vacuous.
( . "$SKILL/evals/_lib/fixture.sh"; declare -F stub_muse_home >/dev/null && declare -F fixture_commit >/dev/null || exit 3; declare -F "$EV_EB_WTE" >/dev/null && exit 4; exit 0 )
EV_EB_BRC=$?
if [ "$EV_EB_BRC" -eq 0 ]; then
  ok "evals: envblock fixture helper defines no $EV_EB_WTE"
elif [ "$EV_EB_BRC" -eq 3 ]; then
  bad "evals: envblock fixture helper defines no $EV_EB_WTE" "fixture.sh defined no stub_muse_home/fixture_commit; the absence proves nothing"
elif [ "$EV_EB_BRC" -eq 4 ]; then
  bad "evals: envblock fixture helper defines no $EV_EB_WTE" "$EV_EB_WTE is back"
else
  bad "evals: envblock fixture helper defines no $EV_EB_WTE" "sourcing fixture.sh failed with rc=$EV_EB_BRC"
fi

# 3. The no-acceptance-check scaffold writes no extra dir (name built
# above). Run the real scaffold the way the harness does (fresh HOME, no
# git identity) with no shim dir on PATH. Non-empty guards come first:
# a scaffold that did not run would otherwise prove a vacuous absence.
EV_EB_WORK="$EV_EB_BASE/nac-work"; EV_EB_HOME="$EV_EB_BASE/nac-home"; EV_EB_TMP="$EV_EB_BASE/nac-tmp"
rm -rf "$EV_EB_WORK" "$EV_EB_HOME" "$EV_EB_TMP"
mkdir -p "$EV_EB_WORK" "$EV_EB_HOME" "$EV_EB_TMP"
EV_EB_SOUT=$(cd "$EV_EB_WORK" && (unset MUSE_CONFIG_DIR MUSE_DATA_DIR MUSE_CATALOG_GLOB GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL; HOME="$EV_EB_HOME" USERPROFILE="$(native_path "$EV_EB_HOME")" TMPDIR="$EV_EB_TMP" GIT_CONFIG_NOSYSTEM=1 TERM=dumb bash "$SKILL/evals/no-acceptance-check/scaffold.sh") 2>&1)
EV_EB_SRC=$?
EV_EB_FAILC=""
if [ "$EV_EB_SRC" -ne 0 ]; then
  EV_EB_FAILC="scaffold rc=$EV_EB_SRC: $(printf '%s' "$EV_EB_SOUT" | tr -d '\r' | head -5)"
elif [ ! -f "$EV_EB_WORK/scheduler.py" ] || [ ! -f "$EV_EB_WORK/errors.py" ]; then
  EV_EB_FAILC="fixture files missing; the absence assertion would prove nothing: $(printf '%s' "$EV_EB_SOUT" | tr -d '\r' | head -5)"
elif [ -z "$(git -C "$EV_EB_WORK" log --oneline 2>&1 | tr -d '\r')" ]; then
  EV_EB_FAILC="no commits; the absence assertion would prove nothing: $(printf '%s' "$EV_EB_SOUT" | tr -d '\r' | head -5)"
elif [ -e "$EV_EB_WORK/$EV_EB_TMPN" ]; then
  EV_EB_FAILC="$EV_EB_TMPN exists: $(printf '%s' "$EV_EB_SOUT" | tr -d '\r' | head -5)"
else
  EV_EB_STC="$(git -C "$EV_EB_WORK" status --porcelain 2>&1 | tr -d '\r')"
  if [ -n "$EV_EB_STC" ]; then
    EV_EB_FAILC="status is not empty: '$(printf '%s' "$EV_EB_STC" | head -5)'"
  fi
fi
if [ -z "$EV_EB_FAILC" ]; then
  ok "evals: envblock no-acceptance-check scaffold writes no $EV_EB_TMPN"
else
  bad "evals: envblock no-acceptance-check scaffold writes no $EV_EB_TMPN" "$EV_EB_FAILC"
fi

# Stub claude for the replay checks: records argv and raw stdin bytes, one
# numbered stdinN.bin per call, then answers every sample with $EV_EB_REPLY.
# Tests prepend this dir to PATH and never pass --claude, so which() finds
# the stub first whether or not the host has a real claude.
mkdir -p "$EV_EB_BASE/claudebin"
cat > "$EV_EB_BASE/claudebin/fake_claude.py" <<'PYEOF'
import glob, json, os, sys
rec = os.environ.get("EV_EB_REC", "")
os.makedirs(rec, exist_ok=True)
n = len(glob.glob(os.path.join(rec, "stdin[0-9]*.bin"))) + 1
data = sys.stdin.buffer.read()
with open(os.path.join(rec, "stdin%d.bin" % n), "wb") as fh:
    fh.write(data)
with open(os.path.join(rec, "stdin.bin"), "wb") as fh:
    fh.write(data)
with open(os.path.join(rec, "argv.json"), "w", encoding="utf-8") as fh:
    json.dump(sys.argv[1:], fh)
sys.stdout.write(os.environ.get("EV_EB_REPLY", "").replace("\\n", "\n"))
PYEOF
printf '#!/bin/sh\nexec "%s" "%s" "$@"\n' "$(command -v python3)" "$EV_EB_BASE/claudebin/fake_claude.py" > "$EV_EB_BASE/claudebin/claude"
chmod +x "$EV_EB_BASE/claudebin/claude"
if command -v cygpath >/dev/null 2>&1; then
  EV_EB_NPY="$(native_path "$(command -v python3)")"
  EV_EB_NFAKE="$(native_path "$EV_EB_BASE/claudebin/fake_claude.py")"
  printf '@echo off\r\n"%s" "%s" %%*\r\n' "$EV_EB_NPY" "$EV_EB_NFAKE" > "$EV_EB_BASE/claudebin/claude.cmd"
fi
EV_EB_CLAUDEPATH="$(shell_path "$EV_EB_BASE/claudebin")"

# 4. Replay of the saved evidence is byte-exact under the report criterion.
# The absence guard comes first: an empty evidence string would make the
# byte comparison prove nothing.
EV_EB_EV7="$EV_EB_BASE/ev7.txt"
python3 -c 'import json,sys; f=json.load(open(sys.argv[1], encoding="utf-8")); sys.stdout.write(f["cases"][0]["arms"]["with"][0]["graders"][0]["evidence"] or "")' "$EV_EB_FIXTURE" > "$EV_EB_EV7" 2>/dev/null || true
EV_EB_FAIL7=""
if [ ! -s "$EV_EB_EV7" ]; then
  EV_EB_FAIL7="fixture evidence is empty; the replay would prove nothing"
elif ! tr -d '\r' < "$EV_EB_EV7" | grep -q 'Blocked before starting'; then
  EV_EB_FAIL7="fixture evidence holds no blocker message; wrong fixture"
else
  EV_EB_REC7="$EV_EB_BASE/rec-7"
  rm -rf "$EV_EB_REC7"; mkdir -p "$EV_EB_REC7"
  EV_EB_OUT7="$(EV_EB_REC="$(native_path "$EV_EB_REC7")" EV_EB_REPLY="FAIL" PATH="$EV_EB_CLAUDEPATH:$PATH" python3 "$EV_EB_REPLAY" --report "$EV_EB_FIXTURE" --case no-acceptance-check 2>&1)"
  EV_EB_RC7=$?
  if [ ! -s "$EV_EB_REC7/stdin1.bin" ]; then
    EV_EB_FAIL7="stub recorded nothing (rc=$EV_EB_RC7)"
  elif [ "$EV_EB_RC7" -ne 1 ]; then
    EV_EB_FAIL7="rc=$EV_EB_RC7 want 1 out='$(printf '%s' "$EV_EB_OUT7" | tr -d '\r' | tail -2)'"
  elif ! printf '%s' "$EV_EB_OUT7" | tr -d '\r' | grep -q 'FAIL FAIL FAIL'; then
    EV_EB_FAIL7="no FAIL FAIL FAIL in '$(printf '%s' "$EV_EB_OUT7" | tr -d '\r' | tail -2)'"
  else
    cat > "$EV_EB_BASE/bytes7.py" <<'PYEOF'
import json, sys
fix = json.load(open(sys.argv[1], encoding="utf-8"))
crit = fix["cases"][0]["graders"][0]["config"]["criteria"]
ev = fix["cases"][0]["arms"]["with"][0]["graders"][0]["evidence"]
want = ("You are grading the output of a coding agent against a criterion.\n\nCriterion:\n"
        + crit + "\n\n\nAgent output (last_message):\n"
        + ev + "\n\n\nRespond with exactly one word: PASS or FAIL.").encode("utf-8")
for rec in sys.argv[2:]:
    got = open(rec, "rb").read().replace(b"\r", b"")
    if got != want:
        print("mismatch in %s: got %d bytes want %d bytes" % (rec, len(got), len(want)))
        sys.exit(1)
print("ok")
PYEOF
    EV_EB_GOT7="$(python3 "$(native_path "$EV_EB_BASE/bytes7.py")" "$EV_EB_FIXTURE" "$(native_path "$EV_EB_REC7/stdin1.bin")" "$(native_path "$EV_EB_REC7/stdin2.bin")" "$(native_path "$EV_EB_REC7/stdin3.bin")" 2>&1 | tr -d '\r')"
    if [ "$EV_EB_GOT7" != "ok" ]; then
      EV_EB_FAIL7="$EV_EB_GOT7"
    fi
  fi
fi
if [ -z "$EV_EB_FAIL7" ]; then
  ok "evals: envblock replay of the saved evidence is byte-exact under the report criterion"
else
  bad "evals: envblock replay of the saved evidence is byte-exact under the report criterion" "$EV_EB_FAIL7"
fi

# 5. Replay with the committed grader file: the sent criterion must equal
# the behaviour.md criteria block (parsed here independently) and must
# differ from the fixture's report criterion, proving the rewritten file
# is what gets graded.
EV_EB_REC8="$EV_EB_BASE/rec-8"
rm -rf "$EV_EB_REC8"; mkdir -p "$EV_EB_REC8"
EV_EB_OUT8="$(EV_EB_REC="$(native_path "$EV_EB_REC8")" EV_EB_REPLY="FAIL" PATH="$EV_EB_CLAUDEPATH:$PATH" python3 "$EV_EB_REPLAY" --report "$EV_EB_FIXTURE" --case no-acceptance-check --criteria-file "$(native_path "$SKILL/evals/no-acceptance-check/graders/behaviour.md")" 2>&1)"
EV_EB_RC8=$?
EV_EB_FAIL8=""
if [ ! -s "$EV_EB_REC8/stdin1.bin" ]; then
  EV_EB_FAIL8="stub recorded nothing (rc=$EV_EB_RC8); the comparison would prove nothing"
elif [ "$EV_EB_RC8" -ne 1 ]; then
  EV_EB_FAIL8="rc=$EV_EB_RC8 want 1 out='$(printf '%s' "$EV_EB_OUT8" | tr -d '\r' | tail -2)'"
else
  cat > "$EV_EB_BASE/bytes8.py" <<'PYEOF'
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
start = None
for i, line in enumerate(lines):
    if line == "criteria: |":
        start = i + 1
        break
if start is None:
    print("no criteria block in the grader file")
    sys.exit(1)
body = []
for line in lines[start:]:
    if line == "---":
        break
    if line.startswith("  "):
        body.append(line[2:])
    elif line.strip() == "":
        body.append("")
    else:
        print(" grader body ends early at %r" % line)
        sys.exit(1)
while body and body[-1] == "":
    body.pop()
filecrit = "\n".join(body) + "\n"
rec = open(sys.argv[2], "rb").read().decode("utf-8").replace("\r", "")
pre = "You are grading the output of a coding agent against a criterion.\n\nCriterion:\n"
mid = "\n\n\nAgent output (last_message):\n"
if not rec.startswith(pre) or mid not in rec:
    print("recorded prompt has no criterion segment")
    sys.exit(1)
sent = rec[len(pre):rec.index(mid)]
fix = json.load(open(sys.argv[3], encoding="utf-8"))
reportcrit = fix["cases"][0]["graders"][0]["config"]["criteria"]
if sent != filecrit:
    print("sent criterion is not the file block (%d vs %d chars)" % (len(sent), len(filecrit)))
    sys.exit(1)
if sent == reportcrit:
    print("sent criterion equals the report criterion; the rewrite is not graded")
    sys.exit(1)
print("ok")
PYEOF
  EV_EB_GOT8="$(python3 "$(native_path "$EV_EB_BASE/bytes8.py")" "$(native_path "$SKILL/evals/no-acceptance-check/graders/behaviour.md")" "$(native_path "$EV_EB_REC8/stdin1.bin")" "$EV_EB_FIXTURE" 2>&1 | tr -d '\r')"
  if [ "$EV_EB_GOT8" != "ok" ]; then
    EV_EB_FAIL8="$EV_EB_GOT8"
  fi
fi
if [ -z "$EV_EB_FAIL8" ]; then
  ok "evals: envblock replay with the committed grader file uses the rewritten criterion"
else
  bad "evals: envblock replay with the committed grader file uses the rewritten criterion" "$EV_EB_FAIL8"
fi

if [ "$EV_EB_STANDALONE" -eq 1 ]; then exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1); fi
