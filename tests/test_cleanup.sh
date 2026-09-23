# shellcheck shell=bash
# Cleanup data-loss guards (issue #36), driven through the real scripts throughout:
# --artifacts refuses roots that hold repositories, worktrees with no artifact record
# are never reaped, and a fleet harvest failure is recorded as failure, not success.
CL_STANDALONE=0
if ! declare -F ok >/dev/null 2>&1; then
  CL_STANDALONE=1
  PASS=0; FAIL=0
  ok() { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
  bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ -n "${2:-}" ] && echo "        $2"; }
  SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  LAB="$(mktemp -d "${TMPDIR:-/tmp}/musetest.XXXXXX")"
  shell_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi; }
fi
. "$(dirname "${BASH_SOURCE[0]}")/lib_stub.sh"

CL_mkrepo() {  # CL_mkrepo <path>
  rm -rf "$1"; mkdir -p "$1"; git init -q -b main "$1"
  printf 'def add(a,b):\n    return a+b\n' > "$1/calc.py"
  git -C "$1" add -A
  git -C "$1" -c user.email=t@l -c user.name=t commit -qm init
}

# T1: --artifacts on a directory that CONTAINS the repo must refuse, not rmtree it.
CL_ANC="$LAB/v_cl_anc"
mkdir -p "$CL_ANC/projects" "$CL_ANC/elsewhere"
CL_mkrepo "$CL_ANC/projects/webapp"
CL_mkrepo "$CL_ANC/projects/other"
printf '{}\n' > "$CL_ANC/projects/webapp/state.json"
git -C "$CL_ANC/projects/webapp" add -A
git -C "$CL_ANC/projects/webapp" -c user.email=t@l -c user.name=t commit -qm state
if [ -d "$CL_ANC/projects/webapp/.git" ] && [ -d "$CL_ANC/projects/other/.git" ]; then
  ok "cleanup T1 pre: both repos exist"
else
  bad "cleanup T1 pre: both repos exist"
fi
CL_OUT1="$(cd "$CL_ANC/elsewhere" && python3 "$SKILL/scripts/muse_cleanup.py" --repo "$CL_ANC/projects/webapp" --out "$CL_ANC/projects" --yes --artifacts 2>&1)"
CL_RC1=$?
if [ "$CL_RC1" -ne 0 ]; then
  ok "cleanup T1: ancestor root is refused with a non-zero exit"
else
  bad "cleanup T1: ancestor root is refused with a non-zero exit" "$CL_OUT1"
fi
if printf '%s\n' "$CL_OUT1" | grep -q 'REFUSING'; then
  ok "cleanup T1: refusal names itself REFUSING"
else
  bad "cleanup T1: refusal names itself REFUSING" "$CL_OUT1"
fi
if [ -d "$CL_ANC/projects/webapp/.git" ] && [ -f "$CL_ANC/projects/webapp/calc.py" ] \
    && [ -d "$CL_ANC/projects/other/.git" ] && [ -f "$CL_ANC/projects/other/calc.py" ]; then
  ok "cleanup T1: both repos survive the refused --artifacts"
else
  bad "cleanup T1: both repos survive the refused --artifacts"
fi

# T1b: a directory holding some other nested repo is refused even when a state.json
# inside names the real repo, so the marker check alone cannot bless it.
CL_HOLD="$LAB/v_cl_hold"
CL_mkrepo "$CL_HOLD/repo"
mkdir -p "$CL_HOLD/arts/t1"
printf '{"id":"t1","repo":"%s","branch":"muse/x/t1","worktree":"/nonexistent","done":true}\n' "$CL_HOLD/repo" > "$CL_HOLD/arts/t1/state.json"
CL_mkrepo "$CL_HOLD/arts/nested"
if [ -d "$CL_HOLD/arts/nested/.git" ] && [ -f "$CL_HOLD/arts/t1/state.json" ]; then
  ok "cleanup T1b pre: nested repo and marker exist"
else
  bad "cleanup T1b pre: nested repo and marker exist"
fi
CL_OUT1B="$(cd "$CL_HOLD" && python3 "$SKILL/scripts/muse_cleanup.py" --repo "$CL_HOLD/repo" --out "$CL_HOLD/arts" --yes --artifacts 2>&1)"
CL_RC1B=$?
if [ "$CL_RC1B" -ne 0 ] && printf '%s\n' "$CL_OUT1B" | grep -q 'REFUSING'; then
  ok "cleanup T1b: a root containing a git repository is refused"
else
  bad "cleanup T1b: a root containing a git repository is refused" "rc=$CL_RC1B out=$CL_OUT1B"
fi
if [ -d "$CL_HOLD/arts/nested/.git" ] && [ -f "$CL_HOLD/arts/t1/state.json" ]; then
  ok "cleanup T1b: nested repo and marker survive"
else
  bad "cleanup T1b: nested repo and marker survive"
fi

# T1c: a marker naming a DIFFERENT repo does not bless the root either.
CL_MISM="$LAB/v_cl_mism"
CL_mkrepo "$CL_MISM/repo"
mkdir -p "$CL_MISM/arts2/t1"
printf '{"id":"t1","repo":"/definitely/not/a/repo","branch":"muse/does/not-exist","done":true}\n' > "$CL_MISM/arts2/t1/state.json"
if [ -f "$CL_MISM/arts2/t1/state.json" ]; then
  ok "cleanup T1c pre: foreign marker exists"
else
  bad "cleanup T1c pre: foreign marker exists"
fi
CL_OUT1C="$(cd "$CL_MISM" && python3 "$SKILL/scripts/muse_cleanup.py" --repo "$CL_MISM/repo" --out "$CL_MISM/arts2" --yes --artifacts 2>&1)"
CL_RC1C=$?
if [ "$CL_RC1C" -ne 0 ] && printf '%s\n' "$CL_OUT1C" | grep -qi 'refusing'; then
  ok "cleanup T1c: a root whose marker names another repo is refused"
else
  bad "cleanup T1c: a root whose marker names another repo is refused" "rc=$CL_RC1C out=$CL_OUT1C"
fi
if [ -f "$CL_MISM/arts2/t1/state.json" ]; then
  ok "cleanup T1c: the foreign marker survives"
else
  bad "cleanup T1c: the foreign marker survives"
fi

# T-M11: the cwd check that kills mutant M11. Run from inside the artifact root with
# a marker that names this repo, so only the cwd refusal stands between it and rmtree.
CL_CWD="$LAB/v_cl_cwd"
CL_mkrepo "$CL_CWD/repo"
mkdir -p "$CL_CWD/arts/t1"
printf '{"id":"t1","repo":"%s","branch":"muse/x/t1","worktree":"/nonexistent","done":true}\n' "$CL_CWD/repo" > "$CL_CWD/arts/t1/state.json"
if [ -f "$CL_CWD/arts/t1/state.json" ]; then
  ok "cleanup T-M11 pre: marker exists"
else
  bad "cleanup T-M11 pre: marker exists"
fi
CL_OUTM="$(cd "$CL_CWD/arts/t1" && python3 "$SKILL/scripts/muse_cleanup.py" --repo "$CL_CWD/repo" --out "$CL_CWD/arts" --yes --artifacts 2>&1)"
CL_RCM=$?
if [ -f "$CL_CWD/arts/t1/state.json" ] && printf '%s\n' "$CL_OUTM" | grep -q 'current directory'; then
  ok "cleanup T-M11: the cwd (or its ancestor) is refused"
else
  bad "cleanup T-M11: the cwd (or its ancestor) is refused" "rc=$CL_RCM out=$CL_OUTM"
fi

# T2: human worktrees/branches on a matching prefix with no artifact record are never
# removed, whatever the flags.
CL_HUMAN="$LAB/v_cl_human"
CL_mkrepo "$CL_HUMAN"
CL_HWT="$LAB/v_cl_human_wt"
git -C "$CL_HUMAN" worktree add -q -b fleet/billing-redesign "$CL_HWT" HEAD
printf 'x = 1\n' > "$CL_HWT/b.py"
git -C "$CL_HWT" add -A
git -C "$CL_HWT" -c user.email=t@l -c user.name=t commit -qm work
printf 'wip\n' > "$CL_HWT/wip.py"
CL_HWT2="$LAB/v_cl_human_wt2"
git -C "$CL_HUMAN" worktree add -q -b muse/manual "$CL_HWT2" HEAD
if git -C "$CL_HUMAN" rev-parse -q --verify refs/heads/fleet/billing-redesign >/dev/null \
    && [ -f "$CL_HWT/wip.py" ]; then
  ok "cleanup T2 pre: human branch and uncommitted work exist"
else
  bad "cleanup T2 pre: human branch and uncommitted work exist"
fi
CL_OUT2="$(cd "$CL_HUMAN" && python3 "$SKILL/scripts/muse_cleanup.py" --repo . --yes --all 2>&1)"
CL_RC2=$?
if git -C "$CL_HUMAN" rev-parse -q --verify refs/heads/fleet/billing-redesign >/dev/null \
    && git -C "$CL_HUMAN" rev-parse -q --verify refs/heads/muse/manual >/dev/null; then
  ok "cleanup T2: record-less branches survive --yes --all"
else
  bad "cleanup T2: record-less branches survive --yes --all" "$CL_OUT2"
fi
if [ -f "$CL_HWT/wip.py" ] \
    && git -C "$CL_HUMAN" ls-tree -r --name-only fleet/billing-redesign | grep -q '^b.py$'; then
  ok "cleanup T2: uncommitted and committed human work survives"
else
  bad "cleanup T2: uncommitted and committed human work survives" "$CL_OUT2"
fi
if printf '%s\n' "$CL_OUT2" | grep -q 'no artifact record'; then
  ok "cleanup T2: output says the worktrees have no artifact record"
else
  bad "cleanup T2: output says the worktrees have no artifact record" "$CL_OUT2"
fi
if printf '%s\n' "$CL_OUT2" | grep -q 'removed fleet/billing-redesign'; then
  bad "cleanup T2: human branch was reported removed" "$CL_OUT2"
else
  ok "cleanup T2: human branch was not reported removed"
fi

# T3: a fleet whose harvest fails must not record success, and cleanup must not reap
# the worktree that is the only copy of the work.
CL_FLEET="$LAB/v_cl_fleet"
CL_mkrepo "$CL_FLEET"
mkdir -p "$LAB/v_cl_fleet_bin"
cat > "$LAB/v_cl_fleet_bin/muse" <<'STUB'
#!/bin/sh
wt=""
while [ $# -gt 0 ]; do [ "$1" = "--workspace" ] && wt="$2"; shift; done
for i in 1 2 3; do echo "f$i" > "$wt/feature$i.py"; done
: > "$(git -C "$wt" rev-parse --absolute-git-dir)/index.lock"
echo '{"payload":{"kind":"run_terminal","terminal":"completed","text":"done"}}'
STUB
chmod +x "$LAB/v_cl_fleet_bin/muse"
win_cmd_shim "$LAB/v_cl_fleet_bin/muse"
printf '[{"id":"a","prompt":"p"}]\n' > "$LAB/v_cl_fleet_tasks.json"
CL_FOUT="$LAB/v_cl_fleet_out"
CL_FWTROOT="$LAB/v_cl_fleet_wt"
CL_OUT3="$(PATH="$(shell_path "$LAB/v_cl_fleet_bin"):$PATH" python3 "$SKILL/scripts/muse_fleet.py" --tasks "$LAB/v_cl_fleet_tasks.json" --repo "$CL_FLEET" --out "$CL_FOUT" --worktree-root "$CL_FWTROOT" --model x 2>&1)"
CL_RC3=$?
if [ "$CL_RC3" -ne 0 ]; then
  ok "cleanup T3 pre: fleet with a failed harvest exits non-zero"
else
  bad "cleanup T3 pre: fleet with a failed harvest exits non-zero" "$CL_OUT3"
fi
if python3 - "$CL_FOUT/report.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d["tasks"] and d["tasks"][0].get("status") != "completed" else 1)
PY
then
  ok "cleanup T3: report status is not completed"
else
  bad "cleanup T3: report status is not completed"
fi
if python3 - "$CL_FOUT/a/state.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d.get("done") is False else 1)
PY
then
  ok "cleanup T3: state.json has done false"
else
  bad "cleanup T3: state.json has done false"
fi
CL_FWT="$CL_FWTROOT/v_cl_fleet_out-a"
if [ -d "$CL_FWT" ] && [ -f "$CL_FWT/feature1.py" ]; then
  ok "cleanup T3 pre: failed-harvest worktree and its work exist"
else
  bad "cleanup T3 pre: failed-harvest worktree and its work exist"
fi
CL_OUT3Y="$(cd "$CL_FLEET" && python3 "$SKILL/scripts/muse_cleanup.py" --repo "$CL_FLEET" --out "$CL_FOUT" --yes 2>&1)"
if [ -f "$CL_FWT/feature1.py" ] && [ -f "$CL_FWT/feature2.py" ] && [ -f "$CL_FWT/feature3.py" ]; then
  ok "cleanup T3: --yes leaves the unharvested worktree alone"
else
  bad "cleanup T3: --yes leaves the unharvested worktree alone" "$CL_OUT3Y"
fi
CL_OUT3A="$(cd "$CL_FLEET" && python3 "$SKILL/scripts/muse_cleanup.py" --repo "$CL_FLEET" --out "$CL_FOUT" --yes --all 2>&1)"
if [ -f "$CL_FWT/feature1.py" ] && [ -f "$CL_FWT/feature2.py" ] && [ -f "$CL_FWT/feature3.py" ]; then
  ok "cleanup T3: --yes --all leaves the unharvested worktree alone"
else
  bad "cleanup T3: --yes --all leaves the unharvested worktree alone" "$CL_OUT3A"
fi
if printf '%s\n' "$CL_OUT3A" | grep -q -- '--discard-unharvested'; then
  ok "cleanup T3: --yes --all points at --discard-unharvested"
else
  bad "cleanup T3: --yes --all points at --discard-unharvested" "$CL_OUT3A"
fi

# T3b: fleet --cleanup keeps a worktree whose harvest failed.
CL_FC="$LAB/v_cl_fleetc"
CL_mkrepo "$CL_FC"
CL_FCOUT="$LAB/v_cl_fleetc_out"
CL_FCWTROOT="$LAB/v_cl_fleetc_wt"
CL_OUT3B="$(PATH="$(shell_path "$LAB/v_cl_fleet_bin"):$PATH" python3 "$SKILL/scripts/muse_fleet.py" --tasks "$LAB/v_cl_fleet_tasks.json" --repo "$CL_FC" --out "$CL_FCOUT" --worktree-root "$CL_FCWTROOT" --model x --cleanup 2>&1)"
CL_RC3B=$?
if [ -d "$CL_FCWTROOT/v_cl_fleetc_out-a" ] && [ -f "$CL_FCWTROOT/v_cl_fleetc_out-a/feature1.py" ]; then
  ok "cleanup T3b: --cleanup keeps the failed-harvest worktree"
else
  bad "cleanup T3b: --cleanup keeps the failed-harvest worktree" "rc=$CL_RC3B out=$CL_OUT3B"
fi

# T4: --discard-unharvested is the only way to reap a finished record with no patch,
# and even then an unmerged branch is kept.
CL_DISC="$LAB/v_cl_disc"
CL_mkrepo "$CL_DISC"
CL_DISCWT="$LAB/v_cl_disc_wt"
mkdir -p "$CL_DISCWT" "$CL_DISC/.muse-fleet/tasks/clean" "$CL_DISC/.muse-fleet/tasks/ahead"
git -C "$CL_DISC" worktree add -q -b muse/s/clean "$CL_DISCWT/clean" HEAD
git -C "$CL_DISC" worktree add -q -b muse/s/ahead "$CL_DISCWT/ahead" HEAD
printf 'ahead\n' > "$CL_DISCWT/ahead/a.py"
git -C "$CL_DISCWT/ahead" add -A
git -C "$CL_DISCWT/ahead" -c user.email=t@l -c user.name=t commit -qm ahead
printf '{"id":"clean","repo":"%s","branch":"muse/s/clean","worktree":"%s","done":true}\n' "$CL_DISC" "$CL_DISCWT/clean" > "$CL_DISC/.muse-fleet/tasks/clean/state.json"
printf '{"id":"ahead","repo":"%s","branch":"muse/s/ahead","worktree":"%s","done":true}\n' "$CL_DISC" "$CL_DISCWT/ahead" > "$CL_DISC/.muse-fleet/tasks/ahead/state.json"
if [ -d "$CL_DISCWT/clean" ] && [ -d "$CL_DISCWT/ahead" ]; then
  ok "cleanup T4 pre: both unharvested worktrees exist"
else
  bad "cleanup T4 pre: both unharvested worktrees exist"
fi
CL_OUT4="$(cd "$CL_DISC" && python3 "$SKILL/scripts/muse_cleanup.py" --repo "$CL_DISC" --out "$CL_DISC/.muse-fleet" --yes 2>&1)"
if [ -d "$CL_DISCWT/clean" ] && [ -d "$CL_DISCWT/ahead" ] \
    && printf '%s\n' "$CL_OUT4" | grep -q -- '--discard-unharvested'; then
  ok "cleanup T4: --yes refuses unharvested worktrees and names the flag"
else
  bad "cleanup T4: --yes refuses unharvested worktrees and names the flag" "$CL_OUT4"
fi
CL_OUT4D="$(cd "$CL_DISC" && python3 "$SKILL/scripts/muse_cleanup.py" --repo "$CL_DISC" --out "$CL_DISC/.muse-fleet" --yes --discard-unharvested 2>&1)"
if [ ! -d "$CL_DISCWT/clean" ] && [ ! -d "$CL_DISCWT/ahead" ]; then
  ok "cleanup T4: --discard-unharvested removes the worktree dirs"
else
  bad "cleanup T4: --discard-unharvested removes the worktree dirs" "$CL_OUT4D"
fi
if ! git -C "$CL_DISC" rev-parse -q --verify refs/heads/muse/s/clean >/dev/null \
    && git -C "$CL_DISC" rev-parse -q --verify refs/heads/muse/s/ahead >/dev/null; then
  ok "cleanup T4: merged branch deleted, unmerged branch kept"
else
  bad "cleanup T4: merged branch deleted, unmerged branch kept" "$CL_OUT4D"
fi
if printf '%s\n' "$CL_OUT4D" | grep -q 'kept branch muse/s/ahead'; then
  ok "cleanup T4: output reports the kept branch"
else
  bad "cleanup T4: output reports the kept branch" "$CL_OUT4D"
fi

if [ "$CL_STANDALONE" -eq 1 ]; then
  rm -rf "$LAB"
  exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
fi
