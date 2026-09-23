# shellcheck shell=bash
# Offline tests for the eval suite (evals/): case.yaml schema, scaffold
# fixtures, the stubbed preflight verdict, and the manual CI workflow.
# Behaviour is exercised, never source text: each scaffold runs in a
# harness-like sandbox (fresh HOME, no git identity) and preflight runs
# against the homes they build. Every variable is EV_-prefixed because this
# file is sourced into validate.sh's global namespace.
EV_STANDALONE=0
if ! declare -F ok >/dev/null 2>&1; then
  EV_STANDALONE=1
  PASS=0; FAIL=0; SKIP=0
  ok() { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
  bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ -n "${2:-}" ] && echo "        $2"; }
  skip() { local n="$1"; shift; if [ "${CI:-}" = "true" ]; then FAIL=$((FAIL+n)); printf '  \033[31mFAIL\033[0m  SKIP counts as a failure under CI: %s\n' "$*"; else SKIP=$((SKIP+n)); printf '  \033[33mSKIP\033[0m  %s\n' "$*"; fi; }
  SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  LAB="$(mktemp -d "${TMPDIR:-/tmp}/musetest.XXXXXX")"
  native_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
  }
  shell_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi
  }
fi

EV_HELPER="$(native_path "$SKILL/tests/eval_case.py")"
# One case dir name per existing case.yaml. The [ -f ] guard skips the
# literal unexpanded pattern bash 3.2 leaves behind when nothing matches
# (nullglob would leak into validate.sh's global shell if set here).
EV_LIST_CASES() {  # EV_LIST_CASES <evals-root>
  for EV_LC in "$1"/*/case.yaml; do
    [ -f "$EV_LC" ] || continue
    basename "$(dirname "$EV_LC")"
  done
}
EV_CASES=$(EV_LIST_CASES "$SKILL/evals")
# Word-splitting EV_CASES is the iteration; it holds only slug conjunctions.
# shellcheck disable=SC2086
EV_N_YAML=$(find "$SKILL/evals" -maxdepth 2 -name case.yaml | wc -l | tr -d ' \r')
EV_N_JSON=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1], encoding='utf-8'))['evals']))" "$(native_path "$SKILL/evals/evals.json")" | tr -d ' \r')
if [ "$EV_N_YAML" -gt 0 ] && [ "$EV_N_YAML" = "$EV_N_JSON" ]; then
  ok "evals: one case.yaml per evals.json entry ($EV_N_YAML cases)"
else
  bad "evals: one case.yaml per evals.json entry" "case.yaml=$EV_N_YAML evals.json=$EV_N_JSON"
fi

# shellcheck disable=SC2086
for EV_CASE in $EV_CASES; do
  if EV_OUT=$(python3 "$EV_HELPER" validate "$(native_path "$SKILL/evals/$EV_CASE")" 2>&1); then
    ok "evals: $EV_CASE case.yaml parses and matches the schema"
  else
    bad "evals: $EV_CASE case.yaml parses and matches the schema" "$(printf '%s' "$EV_OUT" | tr -d '\r' | head -8)"
  fi
done

EV_BASE="$LAB/v_evals"
mkdir -p "$EV_BASE"
# A decoy muse reporting a wrong version, so the ready verdicts below never
# depend on whether the host happens to have a real muse installed.
EV_DECOY="$EV_BASE/decoy"
mkdir -p "$EV_DECOY"
printf '#!/bin/sh\necho "muse 99.0.0"\nexit 0\n' > "$EV_DECOY/muse"
chmod +x "$EV_DECOY/muse"
EV_PYDIR="$(dirname "$(command -v python3)")"
EV_PATH="$(shell_path "$EV_DECOY"):$EV_PYDIR:/usr/bin:/bin"
# The committed stub travels on the operator's PATH (case.yaml env accepts
# only EVAL_* keys, and production preflight reads no EVAL_* var), so the
# ready verdict needs its absolute dir first on PATH.
EV_STUBPATH="$(shell_path "$SKILL/evals/_lib/bin"):$EV_PATH"

# Run one scaffold the way the harness does: fresh HOME, no git identity.
EV_SCAFFOLD() {  # EV_SCAFFOLD <case> <work> <home> <tmp>: sets EV_SOUT, EV_SRC
  EV_SC_CASE="$1"; EV_SC_WORK="$2"; EV_SC_HOME="$3"; EV_SC_TMP="$4"
  rm -rf "$EV_SC_WORK" "$EV_SC_HOME" "$EV_SC_TMP"
  mkdir -p "$EV_SC_WORK" "$EV_SC_HOME" "$EV_SC_TMP"
  EV_SOUT=$(cd "$EV_SC_WORK" && (unset MUSE_CONFIG_DIR MUSE_DATA_DIR MUSE_CATALOG_GLOB GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL; HOME="$EV_SC_HOME" USERPROFILE="$(native_path "$EV_SC_HOME")" TMPDIR="$EV_SC_TMP" GIT_CONFIG_NOSYSTEM=1 TERM=dumb bash "$SKILL/evals/$EV_SC_CASE/scaffold.sh") 2>&1)
  EV_SRC=$?
}

EV_READY_HOME=""
EV_READY_WORK=""
# shellcheck disable=SC2086
for EV_CASE in $EV_CASES; do
  EV_WORK="$EV_BASE/$EV_CASE/work"; EV_HOME="$EV_BASE/$EV_CASE/home"; EV_TMP="$EV_BASE/$EV_CASE/tmp"
  EV_SCAFF="$SKILL/evals/$EV_CASE/scaffold.sh"
  EV_WHY=""
  if ! bash -n "$EV_SCAFF"; then
    bad "evals: $EV_CASE scaffold builds the fixture its prompt names" "bash -n rejects the scaffold"
    bad "evals: $EV_CASE stubbed preflight reports ready" "scaffold failed; no home to test"
    continue
  fi
  EV_SCAFFOLD "$EV_CASE" "$EV_WORK" "$EV_HOME" "$EV_TMP"
  if [ "$EV_SRC" -ne 0 ]; then
    EV_WHY="exit $EV_SRC: $(printf '%s' "$EV_SOUT" | tr -d '\r' | head -5)"
  elif ! git -C "$EV_WORK" rev-parse HEAD >/dev/null 2>&1; then
    EV_WHY="scaffold left no commit"
  else
    EV_TOKENS=$(grep -oE '[A-Za-z0-9_./-]+\.(py|md|json|txt|toml)' "$SKILL/evals/$EV_CASE/prompt.md" | tr -d '\r' | sort -u)
    EV_MISS=""
    for EV_TOK in $EV_TOKENS; do
      EV_BTOK=$(basename "$EV_TOK")
      if [ -z "$(find "$EV_WORK" -path "$EV_WORK/.git" -prune -o -name "$EV_BTOK" -print 2>/dev/null | head -1)" ]; then
        EV_MISS="$EV_MISS $EV_BTOK"
      fi
    done
    if [ -n "$EV_MISS" ]; then
      EV_WHY="prompt names files the fixture lacks:$EV_MISS"
    elif EV_EOUT=$(python3 "$EV_HELPER" expect "$EV_CASE" "$(native_path "$EV_WORK")" 2>&1); then
      EV_WHY=""
    else
      EV_WHY="$(printf '%s' "$EV_EOUT" | tr -d '\r' | head -8)"
    fi
  fi
  if [ -z "$EV_WHY" ]; then
    ok "evals: $EV_CASE scaffold builds the fixture its prompt names"
  else
    bad "evals: $EV_CASE scaffold builds the fixture its prompt names" "$EV_WHY"
    bad "evals: $EV_CASE stubbed preflight reports ready" "scaffold failed; no home to test"
    continue
  fi
  # An empty-stdout assertion proves nothing unless the home was real first:
  # without auth.json and the catalog the verdict below measures an empty
  # dir, not the stub.
  if [ ! -s "$EV_HOME/.config/muse/auth.json" ] || [ ! -s "$EV_HOME/.local/share/muse/model-catalog/eval.json" ]; then
    bad "evals: $EV_CASE stubbed preflight reports ready" "scaffold built no credential home; no home to test"
    continue
  fi
  EV_POUT=$( (cd "$EV_WORK" && unset MUSE_CONFIG_DIR MUSE_DATA_DIR MUSE_CATALOG_GLOB; HOME="$EV_HOME" USERPROFILE="$(native_path "$EV_HOME")" CLAUDE_PLUGIN_ROOT="$SKILL" PATH="$EV_STUBPATH" bash "$SKILL/hooks/preflight.sh") 2>/dev/null | tr -d '\r')
  EV_PRC=$?
  if [ "$EV_PRC" -eq 0 ] && [ -z "$EV_POUT" ]; then
    ok "evals: $EV_CASE stubbed preflight reports ready"
    if [ -z "$EV_READY_HOME" ]; then
      EV_READY_HOME="$EV_HOME"
      EV_READY_WORK="$EV_WORK"
    fi
  else
    bad "evals: $EV_CASE stubbed preflight reports ready" "rc=$EV_PRC out='$(printf '%s' "$EV_POUT" | head -5)'"
  fi
done

# Control 1: the ready verdict can fire. Same scaffold home, but the stub dir
# off PATH (decoy only): the version check must speak up.
if [ -z "$EV_READY_HOME" ]; then
  bad "evals: without the stub on PATH preflight reports the version gap" "no case reached ready; no home to test"
else
  EV_C1=$( (cd "$EV_READY_WORK" && unset MUSE_CONFIG_DIR MUSE_DATA_DIR MUSE_CATALOG_GLOB; HOME="$EV_READY_HOME" USERPROFILE="$(native_path "$EV_READY_HOME")" CLAUDE_PLUGIN_ROOT="$SKILL" PATH="$EV_PATH" bash "$SKILL/hooks/preflight.sh") 2>/dev/null | tr -d '\r')
  if [ -n "$EV_C1" ] && printf '%s\n' "$EV_C1" | grep -q 'verified against Muse Code'; then
    ok "evals: without the stub on PATH preflight reports the version gap"
  else
    bad "evals: without the stub on PATH preflight reports the version gap" "out='$(printf '%s' "$EV_C1" | head -3)'"
  fi
fi

# Control 2: an empty HOME still fails. Stub on PATH, nothing else: the
# credential check must speak up.
EV_EMPTY="$EV_BASE/empty-home"
rm -rf "$EV_EMPTY"; mkdir -p "$EV_EMPTY"
if [ ! -x "$SKILL/evals/_lib/bin/muse" ]; then
  bad "evals: an empty HOME with the stub still reports missing credentials" "the stub is missing; no stub to test"
else
  EV_C2=$( (unset MUSE_CONFIG_DIR MUSE_DATA_DIR MUSE_CATALOG_GLOB; HOME="$EV_EMPTY" USERPROFILE="$(native_path "$EV_EMPTY")" CLAUDE_PLUGIN_ROOT="$SKILL" PATH="$EV_STUBPATH" bash "$SKILL/hooks/preflight.sh") 2>/dev/null | tr -d '\r')
  if [ -n "$EV_C2" ] && printf '%s\n' "$EV_C2" | grep -q 'no stored credentials'; then
    ok "evals: an empty HOME with the stub still reports missing credentials"
  else
    bad "evals: an empty HOME with the stub still reports missing credentials" "out='$(printf '%s' "$EV_C2" | head -3)'"
  fi
fi

# Control 3: production preflight reads no EVAL_* var. A home with auth.json,
# the catalog and a version-correct .local/bin/muse, but the decoy-only PATH:
# exporting EVAL_MUSE_STUB_BIN must change nothing, so the version gap stays.
EV_IGN="$EV_BASE/ignored-env"
rm -rf "$EV_IGN"; mkdir -p "$EV_IGN/.config/muse" "$EV_IGN/.local/share/muse/model-catalog" "$EV_IGN/.local/bin"
printf '{"stub": "claude plugin eval fixture, not a credential"}' > "$EV_IGN/.config/muse/auth.json"
printf '{"rows":[{"model_id":"muse-eval-1.0-contributor","visibility":"visible","release_date":"2026-01-01"}]}' > "$EV_IGN/.local/share/muse/model-catalog/eval.json"
EV_TESTED=$(sed -n 's/^MUSE_TESTED_VERSION = "\(.*\)"/\1/p' "$SKILL/scripts/muse_core.py" | tr -d '\r' | head -1)
printf '#!/bin/sh\necho "muse %s"\nexit 0\n' "$EV_TESTED" > "$EV_IGN/.local/bin/muse"
chmod +x "$EV_IGN/.local/bin/muse"
if [ ! -s "$EV_IGN/.config/muse/auth.json" ] || [ ! -x "$EV_IGN/.local/bin/muse" ]; then
  bad "evals: preflight ignores EVAL_* vars" "could not build the ignored-env home"
else
  EV_C3=$( (unset MUSE_CONFIG_DIR MUSE_DATA_DIR MUSE_CATALOG_GLOB; EVAL_MUSE_STUB_BIN=".local/bin"; export EVAL_MUSE_STUB_BIN; HOME="$EV_IGN" USERPROFILE="$(native_path "$EV_IGN")" CLAUDE_PLUGIN_ROOT="$SKILL" PATH="$EV_PATH" bash "$SKILL/hooks/preflight.sh") 2>/dev/null | tr -d '\r')
  if [ -z "$EV_C3" ]; then
    bad "evals: preflight ignores EVAL_* vars" "empty output proves nothing -- the version gap should have fired"
  elif printf '%s\n' "$EV_C3" | grep -q 'verified against Muse Code'; then
    ok "evals: preflight ignores EVAL_* vars"
  else
    bad "evals: preflight ignores EVAL_* vars" "out='$(printf '%s' "$EV_C3" | head -3)'"
  fi
fi

# A refusal that prints only head -3 of the JSON cuts off before the "reason"
# line, so a red round trip says nothing. This helper surfaces rc, status and
# the reason/error field on one line, then the stderr head.
EV_RT_DETAIL() {  # EV_RT_DETAIL <json-file> <err-file> <rc>
  EV_D_JSON="$1"; EV_D_ERR="$2"; EV_D_RC="$3"
  EV_D_SUM="$(python3 - "$EV_D_RC" "$(native_path "$EV_D_JSON")" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[2], encoding="utf-8") as fh:
        d = json.load(fh)
except Exception:
    print("UNPARSEABLE rc=%s" % sys.argv[1])
else:
    flat = lambda v: " ".join(str(v).split())
    print("rc=%s status=%s reason=%s" % (sys.argv[1], flat(d.get("status", "?")), flat(d.get("reason", d.get("error", "?")))))
PY
)"
  case "$EV_D_SUM" in
    UNPARSEABLE*)
      printf '%s (output did not parse as JSON)\n' "$EV_D_SUM"
      tr -d '\r' <"$EV_D_JSON" 2>/dev/null | head -10;;
    *)
      printf '%s\n' "$EV_D_SUM"
      tr -d '\r' <"$EV_D_ERR" 2>/dev/null | head -5;;
  esac
}

# Control 4: the stub round-trips a real task. Scaffold bulk-tests-fanout
# into $LAB, put the stub dir first on PATH, and drive run -> verify ->
# finish through muse_task.py the way tests/test_roundtrip.sh does.
EV_RT="$EV_BASE/stub-roundtrip"
EV_RT_REPO="$EV_RT/repo"; EV_RT_HOME="$EV_RT/home"; EV_RT_TMP="$EV_RT/tmp"
EV_RT_OUT="$EV_RT/out"; EV_RT_WT="$EV_RT/wt"
rm -rf "$EV_RT"; mkdir -p "$EV_RT_OUT" "$EV_RT_WT"
EV_SCAFFOLD "bulk-tests-fanout" "$EV_RT_REPO" "$EV_RT_HOME" "$EV_RT_TMP"
if [ "$EV_SRC" -ne 0 ] || ! git -C "$EV_RT_REPO" rev-parse HEAD >/dev/null 2>&1; then
  EV_RT_WHY="scaffold failed: exit $EV_SRC: $(printf '%s' "$EV_SOUT" | tr -d '\r' | head -5)"
  bad "evals: the stub round-trips a task run (rc 0, JSON parses)" "$EV_RT_WHY"
  bad "evals: the stub round-trip harvests tests/test_cache.py" "$EV_RT_WHY"
  bad "evals: the stub round-trip verifies (passed=true, exit_code=0)" "$EV_RT_WHY"
  bad "evals: the stub round-trip finishes accepted with supervisor proof" "$EV_RT_WHY"
else
  # Native python on Windows cannot execute the extensionless committed stub:
  # shutil.which honours PATHEXT and CreateProcess never consults it, so the
  # shim below (same shape as tests/lib_stub.sh win_cmd_shim) invokes the
  # absolute bash on the absolute committed stub. Written into $LAB, never
  # into the repo, and ahead of the stub dir on PATH. A no-op elsewhere.
  # Native Windows Python never sees Git Bash's /usr/bin, so without git's dir on PATH preflight refuses the repo as "not a git repository". Last, so a real muse beside git never shadows the stub.
  EV_RTPATH="$EV_STUBPATH:$(shell_path "$(dirname "$(command -v git)")")"
  if command -v cygpath >/dev/null 2>&1; then
    EV_RTSHIM="$EV_RT/shim"
    mkdir -p "$EV_RTSHIM"
    printf '@echo off\r\n"%s" "%s" %%*\r\nexit /b %%ERRORLEVEL%%\r\n' \
      "$(native_path "$(command -v bash)")" \
      "$(native_path "$SKILL/evals/_lib/bin/muse")" > "$EV_RTSHIM/muse.cmd"
    EV_RTPATH="$(shell_path "$EV_RTSHIM"):$EV_RTPATH"
  fi
  printf 'Write tests/test_cache.py covering the public functions of cache.py, with a runnable pytest acceptance check.\n' > "$EV_RT/prompt.txt"
  (cd "$EV_RT_REPO" && env -u CLAUDE_PLUGIN_OPTION_MAX_ROUNDS PATH="$EV_RTPATH" HOME="$EV_RT_HOME" USERPROFILE="$(native_path "$EV_RT_HOME")" \
    python3 "$(native_path "$SKILL/scripts/muse_task.py")" run --id t1 --repo "$(native_path "$EV_RT_REPO")" --out "$(native_path "$EV_RT_OUT")" --worktree-root "$(native_path "$EV_RT_WT")" --model stub-model --prompt-file "$(native_path "$EV_RT/prompt.txt")" >"$EV_RT/run.json" 2>"$EV_RT/run.err")
  EV_RT_RC=$?
  if [ "$EV_RT_RC" -eq 0 ] && python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$EV_RT/run.json" 2>/dev/null; then
    ok "evals: the stub round-trips a task run (rc 0, JSON parses)"
  else
    bad "evals: the stub round-trips a task run (rc 0, JSON parses)" "$(EV_RT_DETAIL "$EV_RT/run.json" "$EV_RT/run.err" "$EV_RT_RC")"
  fi
  EV_RT_PATCH="$EV_RT_OUT/t1/patch.diff"
  # A bare path match would also pass on a patch that only mentions the file,
  # so require the ADDED-file shape: the +++ header plus a new-file marker.
  if [ -s "$EV_RT_PATCH" ] && grep -q '^+++ b/tests/test_cache.py' "$EV_RT_PATCH" \
    && { grep -q 'new file mode' "$EV_RT_PATCH" || grep -q '^--- /dev/null' "$EV_RT_PATCH"; }; then
    ok "evals: the stub round-trip harvests tests/test_cache.py"
  else
    bad "evals: the stub round-trip harvests tests/test_cache.py" "$(ls -la "$EV_RT_PATCH" 2>&1 | tr -d '\r') $(EV_RT_DETAIL "$EV_RT/run.json" "$EV_RT/run.err" "$EV_RT_RC")"
  fi
  (cd "$EV_RT_REPO" && env -u CLAUDE_PLUGIN_OPTION_MAX_ROUNDS PATH="$EV_RTPATH" HOME="$EV_RT_HOME" USERPROFILE="$(native_path "$EV_RT_HOME")" \
    python3 "$(native_path "$SKILL/scripts/muse_task.py")" verify --id t1 --out "$(native_path "$EV_RT_OUT")" --command "python3 tests/test_cache.py" >"$EV_RT/ver.json" 2>"$EV_RT/ver.err")
  EV_RT_VRC=$?
  EV_RT_VP=""
  EV_RT_VE=""
  EV_RT_VP=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('passed'))" "$EV_RT/ver.json" 2>/dev/null || true)
  EV_RT_VE=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('exit_code'))" "$EV_RT/ver.json" 2>/dev/null || true)
  if [ "$EV_RT_VRC" -eq 0 ] && [ "$EV_RT_VP" = "True" ] && [ "$EV_RT_VE" = "0" ]; then
    ok "evals: the stub round-trip verifies (passed=true, exit_code=0)"
  else
    bad "evals: the stub round-trip verifies (passed=true, exit_code=0)" "passed=$EV_RT_VP exit_code=$EV_RT_VE $(EV_RT_DETAIL "$EV_RT/ver.json" "$EV_RT/ver.err" "$EV_RT_VRC")"
  fi
  (cd "$EV_RT_REPO" && env -u CLAUDE_PLUGIN_OPTION_MAX_ROUNDS PATH="$EV_RTPATH" HOME="$EV_RT_HOME" USERPROFILE="$(native_path "$EV_RT_HOME")" \
    python3 "$(native_path "$SKILL/scripts/muse_task.py")" finish --id t1 --out "$(native_path "$EV_RT_OUT")" --verdict accept --summary s >"$EV_RT/fin.json" 2>"$EV_RT/fin.err")
  EV_RT_FRC=$?
  EV_RT_FV=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('verified_by_supervisor'))" "$EV_RT/fin.json" 2>/dev/null || true)
  if [ "$EV_RT_FRC" -eq 0 ] && [ "$EV_RT_FV" = "True" ]; then
    ok "evals: the stub round-trip finishes accepted with supervisor proof"
  else
    bad "evals: the stub round-trip finishes accepted with supervisor proof" "verified_by_supervisor=$EV_RT_FV $(EV_RT_DETAIL "$EV_RT/fin.json" "$EV_RT/fin.err" "$EV_RT_FRC")"
  fi
fi

# Without git on PATH this probe refuses as "not a git repository" instead of
# "working copy is dirty", so this check also pins the git-dir PATH fix above.
EV_PROBE="$EV_BASE/refused-probe"
EV_PROBE_REPO="$EV_PROBE/repo"; EV_PROBE_OUT="$EV_PROBE/out"; EV_PROBE_WT="$EV_PROBE/wt"
rm -rf "$EV_PROBE"; mkdir -p "$EV_PROBE_REPO" "$EV_PROBE_OUT" "$EV_PROBE_WT"
git init -q "$EV_PROBE_REPO" 2>/dev/null
printf 'probe\n' > "$EV_PROBE_REPO/file.txt"
git -C "$EV_PROBE_REPO" add file.txt 2>/dev/null
git -C "$EV_PROBE_REPO" -c user.name=eval -c user.email=eval@example.invalid commit -q -m x 2>/dev/null
printf 'uncommitted\n' > "$EV_PROBE_REPO/dirty.txt"
printf 'Write tests.\n' > "$EV_PROBE/prompt.txt"
if [ -z "$(git -C "$EV_PROBE_REPO" status --porcelain 2>/dev/null | tr -d '\r')" ]; then
  bad "evals: a refused stub run names its refusal reason" "probe repo is not dirty; nothing to test"
elif [ -z "${EV_RTPATH:-}" ]; then
  bad "evals: a refused stub run names its refusal reason" "round trip never set EV_RTPATH; nothing to test"
else
  (cd "$EV_PROBE_REPO" && env -u CLAUDE_PLUGIN_OPTION_MAX_ROUNDS PATH="$EV_RTPATH" HOME="$EV_RT_HOME" USERPROFILE="$(native_path "$EV_RT_HOME")" \
    python3 "$(native_path "$SKILL/scripts/muse_task.py")" run --id p1 --repo "$(native_path "$EV_PROBE_REPO")" --out "$(native_path "$EV_PROBE_OUT")" --worktree-root "$(native_path "$EV_PROBE_WT")" --model stub-model --prompt-file "$(native_path "$EV_PROBE/prompt.txt")" >"$EV_PROBE/run.json" 2>"$EV_PROBE/run.err")
  EV_PROBE_RC=$?
  EV_PROBE_DETAIL="$(EV_RT_DETAIL "$EV_PROBE/run.json" "$EV_PROBE/run.err" "$EV_PROBE_RC")"
  if [ "$EV_PROBE_RC" -ne 0 ] \
    && printf '%s' "$EV_PROBE_DETAIL" | grep -q 'status=refused' \
    && printf '%s' "$EV_PROBE_DETAIL" | grep -q 'dirty'; then
    ok "evals: a refused stub run names its refusal reason"
  else
    bad "evals: a refused stub run names its refusal reason" "$EV_PROBE_DETAIL"
  fi
fi

# Control 5: the stub refuses what it does not emulate, and never phones home.
if [ ! -x "$SKILL/evals/_lib/bin/muse" ]; then
  bad "evals: the stub refuses unknown commands" "the stub is missing; no stub to test"
elif "$SKILL/evals/_lib/bin/muse" login >/dev/null 2>&1; then
  bad "evals: the stub refuses unknown commands" "login exited 0"
else
  ok "evals: the stub refuses unknown commands"
fi

EV_YML="$(native_path "$SKILL/.github/workflows/evals.yml")"
# The checker lives in tests/eval_workflow_check.py (argv: workflow path,
# evals root) so the Workflow-missing guard below runs the same code.
EV_YOUT=$(python3 "$(native_path "$SKILL/tests/eval_workflow_check.py")" "$EV_YML" "$(native_path "$SKILL/evals")" 2>&1)
EV_YRC=$?
if [ "$EV_YRC" -eq 0 ]; then
  ok "evals: evals.yml is manual-only and runs the documented command"
else
  bad "evals: evals.yml is manual-only and runs the documented command" "$(printf '%s' "$EV_YOUT" | tr -d '\r' | head -8)"
fi

if [ "$EV_STANDALONE" -eq 1 ]; then
  rm -rf "$LAB"
  if [ "$FAIL" -gt 0 ] || [ "$PASS" -eq 0 ]; then exit 1; else exit 0; fi
fi
