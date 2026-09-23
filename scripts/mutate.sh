#!/usr/bin/env bash
# Mutation harness for the offline suite (issue #32).
#
# How much the suite actually catches is measured, not claimed: this script plants
# each known bug one at a time into a scratch copy of HEAD and runs
# `bash scripts/validate.sh --offline` against it. A mutant the suite still passes
# has "survived"; one that makes it fail is "killed".
#
# Every mutant is checked statically before anything runs. A mutant whose snippet no
# longer matches HEAD exactly once is STALE -- a guard that cannot fire -- so the run
# fails up front instead of spending minutes on validates that prove nothing.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Every known mutant is held: a regression that re-opens a once-killed hole
# fails the run again. A new mutant row appends its id here with its checks.
MUST_KILL="M01 M02 M03 M04 M05 M06 M07 M08 M09 M10 M11 M12 M13 M14 M15 M16 M17 M18 M19 M20 M21 M22 M23 M24 M25 M26 M27 M28"
if [ -n "${MUTATE_MUST_KILL:-}" ]; then
  # Self-tests stage a failing run through the environment without touching this file.
  echo "mutate: MUST_KILL overridden by environment: $MUTATE_MUST_KILL" >&2
  MUST_KILL="$MUTATE_MUST_KILL"
fi

JOBS="${MUTATE_JOBS:-4}"

mutants() {
python3 - "$@" <<'PY'
import sys

M = [
 ("M00", "scripts/muse_task.py", 'def harvest_base(st: dict) -> str:', 'def harvest_base(st: dict) -> str:  # mutate.sh control: comment only', "control: comment-only change, suite must stay green"),
 ("M01", "scripts/muse_task.py", '    h = core.harvest(wt, harvest_base(st), st["excludes"], tdir / "patch.diff")', '    h = core.harvest(wt, st["base"], st["excludes"], tdir / "patch.diff")', "round harvest diffs against the ref name, not base_sha"),
 ("M02", "scripts/muse_fleet.py", '        base = git(repo, "rev-parse", "--verify", base).strip() or base', '        base = base', "fleet never pins the base to a sha"),
 ("M03", "scripts/muse_task.py", '    verified = passed and certified', '    verified = passed', "accept gate ignores certification"),
 ("M04", "scripts/muse_core.py", '    refuse = bool(scan["certain"]) and not opts.get("allow_secrets")', '    refuse = bool(scan["certain"]) and bool(opts.get("allow_secrets"))', "secret refusal inverted"),
 ("M05", "scripts/muse_core.py", '    for f in _expand_paths(root, paths):', '    for f in [p for p in _expand_paths(root, paths) if not p.name.startswith(".")]:', "secret scan skips dotfiles, so .env is never scanned"),
 ("M06", "hooks/supervisor_result.py", '    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": "\\n".join(lines)}}))', '    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": "\\n".join(lines)}}), file=sys.stderr)', "PostToolUse hook writes its JSON to stderr instead of stdout"),
 ("M07", "hooks/supervisor_result.py", '            if task.get("verdict") == "accept" and not task.get("verified_by_supervisor"):', '            if False:', 'PostToolUse drops the "accepted without a passing check" note'),
 ("M08", "scripts/muse_task.py", '        "max_rounds": args.max_rounds,', '        "max_rounds": DEFAULT_MAX_ROUNDS,', "--max-rounds parsed but a constant stored"),
 ("M09", "hooks/preflight.sh", '  if [ ! -s "$MUSE_CONFIG/auth.json" ]; then', '  if [ -s "$MUSE_CONFIG/auth.json" ]; then', "preflight auth check inverted"),
 ("M10", "hooks/leftover_worktrees.py", 'OURS = re.compile(r"^refs/heads/(muse|fleet)/")', 'OURS = re.compile(r"^refs/heads/(muse)/")', "SessionStart worktree report ignores fleet/ worktrees"),
 ("M11", "scripts/muse_cleanup.py", '    if rp == cwd or rp in cwd.parents:', '    if False:', "cleanup stops refusing the cwd or its ancestors"),
 ("M12", "scripts/muse_task.py", '    if used >= int(st["max_rounds"]):', '    if used > int(st["max_rounds"]):', "round breaker off by one (>= changed to >)"),
 ("M13", "scripts/muse_task.py", '        core.kill_process_tree(p)', '        p.kill()', "verify timeout kills only the shell"),
 ("M14", "scripts/muse_doctor.py", '    note = core.version_mismatch(core.muse_version())', '    note = None', "doctor never compares the muse version"),
 ("M15", "scripts/muse_ask.sh", '\' "$SKILL_DIR/scripts/muse_core.py" 2>/dev/null)"', '\' "$SKILL_DIR/muse_core.py" 2>/dev/null)"', "muse_ask.sh points at the wrong muse_core.py"),
 ("M16", "scripts/muse_status.py", '        out.append("last check exited {}".format(r["last_exit"]))', '        pass', 'status drops the "last check exited N" flag'),
 ("M17", "scripts/muse_core.py", '    raw = os.environ.get("CLAUDE_PLUGIN_OPTION_" + key.upper())', '    raw = os.environ.get("CLAUDE_PLUGIN_OPTION_" + key)', "userConfig env var name case bug"),
 ("M18", "scripts/muse_core.py", '            os.killpg(os.getpgid(p.pid), signal.SIGKILL)', '            raise OSError("mutate.sh: killpg removed")', "worker timeout kills only the direct child, not its process group"),
 ("M19", "hooks/supervisor_result.py", '        tool_input = {}', '        return 0', "a non-dict or missing tool_input returns instead of falling through to the agentType check"),
 ("M20", "hooks/_artifacts.py", '    if st.get("done"):', '    if False:', "is_unfinished ignores done"),
 ("M21", "hooks/_artifacts.py", '    if isinstance(task, dict) and task.get("verdict"):', '    if False:', "is_unfinished ignores a recorded verdict"),
 ("M22", "hooks/supervisor_stop.py", '    if agent_type is not None and agent_type != "muse:muse-supervisor":', '    if False:', "SubagentStop blocks any agent type, not only the supervisor"),
 ("M23", "hooks/supervisor_result.py", '            if task.get("out_of_band_edit"):', '            if False:', "PostToolUse drops the out_of_band_edit note"),
 ("M24", "hooks/_artifacts.py", 'RECENT_SECONDS = 6 * 60 * 60', 'RECENT_SECONDS = 600 * 60 * 60', "recent window widened, so stale tasks shout"),
 ("M25", "hooks/leftover_worktrees.py", '        verdict = "verdict recorded" if records.get(branch) else "no verdict yet"', '        verdict = "no verdict yet"', "leftover report loses the verdict label"),
 ("M26", "scripts/muse_doctor.py", '                given = core.flag_given(key, cli)', '                given = cli is not None and cli != ""', "doctor blames a same-key placeholder flag with an invalid env value on flag instead of env"),
 ("M27", "scripts/muse_ask.sh", 'if [[ "$ASK_REFUSE" == "False" ]]; then ALLOW_SECRETS=1; fi', 'if [[ "$ASK_REFUSE" == "False" && -z "$REFUSE_ON_SECRETS" ]]; then ALLOW_SECRETS=1; fi', "only the env var can opt out of the --write secret refusal"),
 ("M28", "tests/frontmatter_contract.py", '        if _e in ("Bash", "Agent", "Task", "Workflow", "Write", "Edit",', '        if _e in ("Agent", "Task", "Workflow", "Write", "Edit",', "the auto-triggering skill may pre-approve bare Bash"),
]

def lookup(mid):
    for (i, f, old, new, _d) in M:
        if i == mid:
            return (f, old, new)
    return None

cmd = sys.argv[1]
if cmd == "ids":
    for (i, _f, _o, _n, _d) in M:
        print(i)
elif cmd == "desc":
    row = lookup(sys.argv[2])
    if row is not None:
        for (i, _f, _o, _n, d) in M:
            if i == sys.argv[2]:
                print(d)
elif cmd == "check":
    root = sys.argv[2]
    bad = 0
    for (i, f, old, new, _d) in M:
        try:
            text = open(root + "/" + f, encoding="utf-8").read()
        except OSError:
            print("STALE %s: %s missing" % (i, f))
            bad = 1
            continue
        n = text.count(old)
        if n != 1:
            print("STALE %s: snippet found %d times in %s, want exactly 1" % (i, n, f))
            bad = 1
        elif old == new:
            print("STALE %s: replacement is identical to the original" % i)
            bad = 1
    sys.exit(1 if bad else 0)
elif cmd == "apply":
    mid = sys.argv[2]
    root = sys.argv[3]
    row = lookup(mid)
    if row is None:
        print("STALE %s: unknown mutant id" % mid)
        sys.exit(3)
    (f, old, new) = row
    try:
        text = open(root + "/" + f, encoding="utf-8").read()
    except OSError:
        print("STALE %s: %s missing" % (mid, f))
        sys.exit(3)
    if text.count(old) != 1 or old == new:
        print("STALE %s: snippet no longer applies cleanly to %s" % (mid, f))
        sys.exit(3)
    open(root + "/" + f, "w", encoding="utf-8").write(text.replace(old, new, 1))
else:
    print("unknown mutants subcommand: %s" % cmd)
    sys.exit(2)
PY
}

run_one() {  # run_one <id>: plant one mutant, run the suite, record the verdict
  id="$1"
  d="$WORK/$id"
  mkdir -p "$d/tree" "$d/tmp"
  tar -x -C "$d/tree" -f "$WORK/head.tar"
  if ! mutants apply "$id" "$d/tree" >"$d/apply.log" 2>&1; then
    # Unreachable when the static check passed, but every selected id needs a
    # verdict file or the report below would misread a missing one as a survivor.
    echo "stale" > "$d/verdict"
    return 0
  fi
  # Each validate gets its own TMPDIR so parallel runs never share a LAB, and an
  # emptied MUSE_FLEET_LAB so validate mktemps a fresh one inside it; the EXIT trap
  # reaps the whole WORK tree afterwards.
  # GNU `timeout` is not on macOS, so the per-mutant timeout is a python3 wrapper
  # (python3 is already required). The program string is inline in the function,
  # because run_one travels via `export -f` + `xargs bash -c` and a variable
  # holding it would not be exported.
  if TMPDIR="$d/tmp" MUSE_FLEET_LAB= python3 -c '
import os, signal, subprocess, sys
t = int(sys.argv[1])
mark = sys.argv[2]
cmd = sys.argv[3:]
p = subprocess.Popen(cmd, start_new_session=True, stdin=subprocess.DEVNULL)
try:
    rc = p.wait(timeout=t)
except subprocess.TimeoutExpired:
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except (AttributeError, OSError):
        p.kill()
    p.wait()
    open(mark, "w").write("timed out\n")
    sys.stderr.write("mutate: timed out after %ds\n" % t)
    sys.exit(124)
sys.exit(rc if rc >= 0 else 128 - rc)
' "$MUTATE_TIMEOUT" "$d/timedout" bash "$d/tree/scripts/validate.sh" --offline >"$d/log" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  # A non-zero exit with no FAIL line and no RESULT is a harness or script crash,
  # not a suite kill -- and a hang killed by the wrapper above is its own verdict.
  # Strip ANSI first (a FAIL line arrives colourised); esc is local because the
  # global ESC is not visible in the xargs subshell.
  esc="$(printf '\033')"
  if [ -e "$d/timedout" ]; then
    echo "timeout" > "$d/verdict"
  elif [ "$rc" -eq 0 ]; then
    echo "survived" > "$d/verdict"
  elif sed "s/${esc}\[[0-9;]*m//g" "$d/log" 2>/dev/null | grep -Eq '^[[:space:]]*FAIL[[:space:]]|RESULT:'; then
    echo "killed" > "$d/verdict"
  else
    echo "crashed" > "$d/verdict"
  fi
}

MODE="run"
if [ "${1:-}" = "--check" ]; then
  MODE="check"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/musemutate.XXXXXX")"
# Every path below is built from WORK, so a failed mktemp must stop here instead of
# scattering mutant trees across whatever the empty string resolves to.
if [ -z "$WORK" ] || [ ! -d "$WORK" ]; then
  echo "mutate: cannot create scratch dir" >&2
  exit 2
fi
cleanup() {
  # An orphan left by a mutant that disables process-tree kill keeps writing into
  # its tmp dir after its validate has exited, so one rm races it and leaves the
  # whole WORK tree behind; retry a few times, then name the leftover path.
  n=0
  rm -rf "$WORK" 2>/dev/null || true
  while [ -e "$WORK" ] && [ "$n" -lt 5 ]; do
    sleep 1
    rm -rf "$WORK" 2>/dev/null || true
    n=$((n+1))
  done
  if [ -e "$WORK" ]; then
    echo "mutate: warning: could not remove scratch dir $WORK" >&2
  fi
}
if [ -n "${MUTATE_KEEP:-}" ]; then
  # Keep the mutant trees around for inspection after the run.
  echo "work: $WORK"
else
  trap cleanup EXIT
fi

# Mutate the committed HEAD, never the working tree, so results reproduce from a
# clean checkout instead of depending on whatever happens to be uncommitted.
if [ -n "$(git -C "$REPO" status --porcelain)" ]; then
  echo "mutate: warning: uncommitted changes are NOT in what gets mutated (HEAD snapshot)" >&2
fi
git -C "$REPO" archive HEAD > "$WORK/head.tar"

mkdir -p "$WORK/check"
tar -x -C "$WORK/check" -f "$WORK/head.tar"
CHECK_RC=0
CHECK_OUT="$(mutants check "$WORK/check" 2>&1)" || CHECK_RC=$?
if [ "$CHECK_RC" -ne 0 ]; then
  # A stale mutant is a guard that cannot fire: fail before running anything,
  # because a green run past this point would prove nothing.
  [ -n "$CHECK_OUT" ] && printf '%s\n' "$CHECK_OUT"
  exit 1
fi

# The table is the single source of the totals: a new row changes every count
# below without a second literal to update.
N_TABLE=$(mutants ids | wc -l | tr -d ' ')

MUTATE_TIMEOUT="${MUTATE_TIMEOUT:-300}"
case "$MUTATE_TIMEOUT" in
  ''|*[!0-9]*) echo "mutate: MUTATE_TIMEOUT must be a positive integer, got '$MUTATE_TIMEOUT'" >&2; exit 2 ;;
esac
if [ -z "$(printf '%s' "$MUTATE_TIMEOUT" | tr -d '0')" ]; then
  echo "mutate: MUTATE_TIMEOUT must be a positive integer, got '$MUTATE_TIMEOUT'" >&2; exit 2
fi

# A typo in MUTATE_ONLY must fail here, in milliseconds. Without this the run
# selects only the M00 control, prints a small killed count, and exits 0.
if [ -n "${MUTATE_ONLY:-}" ]; then
  _known=" $(mutants ids | tr '\n' ' ') "
  _tokens=0
  for _tok in $(printf '%s' "$MUTATE_ONLY" | tr ',' ' '); do
    _tokens=$((_tokens+1))
    case "$_known" in
      *" $_tok "*) ;;
      *) echo "mutate: unknown mutant id in MUTATE_ONLY: $_tok" >&2; exit 2 ;;
    esac
  done
  if [ "$_tokens" -eq 0 ]; then
    echo "mutate: MUTATE_ONLY is set but names no mutant ids" >&2; exit 2
  fi
  unset _known _tokens _tok
fi

if [ "$MODE" = "check" ]; then
  # Fast guard only: proves the harness can still fire, runs no validate.
  echo "mutate: all $N_TABLE mutants apply cleanly"
  exit 0
fi

# MUTATE_ONLY filters the run to a few ids. M00 always stays: every other verdict is
# meaningless if the unmutated suite is not green, so the control gates everything.
ONLY=" $(printf '%s' "${MUTATE_ONLY:-}" | tr ',' ' ') "
IDS=""
for id in $(mutants ids); do
  if [ "$id" = "M00" ]; then
    IDS="$IDS $id"
  elif [ -z "${MUTATE_ONLY:-}" ]; then
    IDS="$IDS $id"
  else
    case "$ONLY" in
      *" $id "*) IDS="$IDS $id" ;;
    esac
  fi
done

export -f run_one mutants
export WORK MUTATE_TIMEOUT
# Word-splitting IDS here is the point: one id per xargs line, run in parallel.
# shellcheck disable=SC2086
printf '%s\n' $IDS | xargs -P "$JOBS" -I{} bash -c 'run_one "$1"' _ {}

ESC="$(printf '\033')"
RC=0
KILLED=0
N_SELECTED=0
for id in $IDS; do
  verdict="$(cat "$WORK/$id/verdict" 2>/dev/null || echo MISSING)"
  desc="$(mutants desc "$id")"
  line="$id  $verdict  $desc"
  if [ "$id" != "M00" ]; then
    N_SELECTED=$((N_SELECTED+1))
  fi
  if [ "$verdict" = "killed" ]; then
    if [ "$id" != "M00" ]; then
      KILLED=$((KILLED+1))
    fi
    fail="$(grep -m1 FAIL "$WORK/$id/log" 2>/dev/null | sed "s/${ESC}\[[0-9;]*m//g" || true)"
    [ -n "$fail" ] && line="$line  $fail"
  fi
  printf '%s\n' "$line"
  case "$verdict" in
    timeout|crashed)
      # A hang or a crash is neither evidence the suite caught the mutant nor
      # that it missed it: show the tail and fail the run.
      printf 'mutate: %s %s\n' "$id" "$verdict"
      tail -5 "$WORK/$id/log" 2>/dev/null || true
      RC=1 ;;
  esac
done

CONTROL="green"
if [ "$(cat "$WORK/M00/verdict" 2>/dev/null || echo MISSING)" != "survived" ] \
    || ! grep -q " 0 failed" "$WORK/M00/log" 2>/dev/null; then
  # The control must both exit 0 and report zero failures: a passing exit with a
  # skipped or miscounted suite would otherwise certify every mutant below it.
  CONTROL="RED"
fi
printf 'killed %d of %d (M00 control: %s)\n' "$KILLED" "$N_SELECTED" "$CONTROL"

if [ "$CONTROL" != "green" ]; then
  echo "mutate: control M00 did not stay green" >&2
  RC=1
fi
for id in $IDS; do
  if [ "$(cat "$WORK/$id/verdict" 2>/dev/null || echo MISSING)" = "stale" ]; then
    cat "$WORK/$id/apply.log" 2>/dev/null || true
    RC=1
  fi
done
for id in $MUST_KILL; do
  case " $IDS " in
    *" $id "*) ;;
    *) continue ;;
  esac
  verdict="$(cat "$WORK/$id/verdict" 2>/dev/null || echo MISSING)"
  if [ "$verdict" != "killed" ]; then
    echo "MUST_KILL $id not killed ($verdict)"
    RC=1
  fi
done
exit "$RC"
