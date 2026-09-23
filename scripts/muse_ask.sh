#!/usr/bin/env bash
# One muse question, one answer on stdout. The cheap primitive for delegating a single
# bounded task -- analysis, summarisation, a contained edit -- without the worktree
# machinery of muse_fleet.py.
#
#   muse_ask.sh "Summarise what retry.py does and list its public functions"
#   muse_ask.sh --effort xhigh "Why would connect() return None after a timeout?"
#   muse_ask.sh --schema s.json --effort low "List every file importing requests"
#   muse_ask.sh --write --effort medium "Add a docstring to add() in calc.py"
#
# Follow-ups: every run prints its session id on stderr and remembers the last one per
# repo, so the usual case needs no copying:
#
#   muse_ask.sh "Summarise retry.py"                     # prints: session <uuid>
#   muse_ask.sh --continue "Now list its callers"        # resumes that conversation
#   muse_ask.sh --session <uuid> "..."                   # or name one explicitly
#
# The remembered id lives under ${CLAUDE_PLUGIN_DATA} (or ~/.claude/plugins/data/muse),
# keyed by the absolute repo path -- that directory is shared across every repo you work
# in, so an unkeyed "last session" would hand one project's context to another. It holds
# nothing but session ids.
#
# Read-only by default: writes are disabled and the sandbox stays on, so this is safe to
# point at a dirty working copy. --write opts into editing (and disables the sandbox),
# which you should only do against a worktree or a repo you are willing to have modified.
#
# Every run scans the repo for credentials first and refuses when it finds a
# confirmed one, in --write and read-only mode alike: a read-only worker can still
# read a secret and send it to the contributor tier. --allow-secrets scans and
# reports but does not refuse; --no-secret-scan skips the scan entirely.
#
# --model, --repo, --timeout and --max-steps override the configured defaults for one
# run; --refuse-on-secrets carries the configured default for the credential scan.
# --effort sets the reasoning effort; --session and --continue resume a past answer.
#
# Exits 0 and prints the final answer, or exits 1 and prints the failure reason to stderr.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Unset sentinels: an empty value means the flag was not given, so the effective
# value comes from userConfig (CLAUDE_PLUGIN_OPTION_*) with the historical default
# behind that. A literal here would silently override a configured value.
EFFORT=""
SESSION=""
CONTINUE=0
MODEL=""
SCHEMA=""
REPO="."
REFUSE_ON_SECRETS=""
WRITE=0
TIMEOUT=600
MAX_STEPS=""
ALLOW_SECRETS=0
NO_SECRET_SCAN=0

# Print the header comment block, stopping at the first non-comment line. A fixed line
# range drifts the moment the header is edited -- which is how `--help` started printing
# `set -uo pipefail` as if it were documentation.
usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --effort)    EFFORT="$2"; shift 2 ;;
    --model)     MODEL="$2"; shift 2 ;;
    --schema)    SCHEMA="$2"; shift 2 ;;
    --repo)      REPO="$2"; shift 2 ;;
    --timeout)   TIMEOUT="$2"; shift 2 ;;
    --max-steps) MAX_STEPS="$2"; shift 2 ;;
    --write)     WRITE=1; shift ;;
    --allow-secrets) ALLOW_SECRETS=1; shift ;;
    --refuse-on-secrets) REFUSE_ON_SECRETS="$2"; shift 2 ;;
    --no-secret-scan) NO_SECRET_SCAN=1; shift ;;
    --session)   SESSION="$2"; shift 2 ;;
    --continue)  CONTINUE=1; shift ;;
    -h|--help)   usage 0 ;;
    --)          shift; break ;;
    -*)          echo "unknown flag: $1" >&2; usage 1 ;;
    *)           break ;;
  esac
done

PROMPT="${*:-}"
[[ -z "$PROMPT" ]] && { echo "no prompt given" >&2; usage 1; }

# One Python call resolves all three values: the CLI flag wins, then userConfig,
# then the historical default. A CLI value is validated the same way a configured
# one is, so a typo refuses rather than billing a run on a fallback. Prints the
# effective effort, model and refuse_on_secrets, one per line; on ConfigError it
# names the refusal on stderr and exits nonzero.
ASK_CFG="$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
try:
    eff, _ = m.option_with_source("default_effort", sys.argv[2], "low")
    mod, _ = m.option_with_source("default_model", sys.argv[3], "latest-contributor")
    refuse, _ = m.option_with_source("refuse_on_secrets", sys.argv[4], True)
    sys.stdout.write("%s\n%s\n%s\n" % (eff, mod, refuse))
except m.ConfigError as e:
    sys.stderr.write("muse_ask: refused: %s\n" % e)
    sys.exit(2)
' "$SKILL_DIR/scripts/muse_core.py" "$EFFORT" "$MODEL" "$REFUSE_ON_SECRETS" | tr -d '\r')"
if [ "$?" -ne 0 ]; then exit 1; fi
EFFORT="$(printf '%s\n' "$ASK_CFG" | sed -n '1p')"
MODEL="$(printf '%s\n' "$ASK_CFG" | sed -n '2p')"
ASK_REFUSE="$(printf '%s\n' "$ASK_CFG" | sed -n '3p')"
if [[ -z "$EFFORT" || -z "$MODEL" || -z "$ASK_REFUSE" ]]; then
  echo "muse_ask: refused: could not resolve effort/model/refuse_on_secrets from userConfig" >&2
  exit 1
fi
# An explicit --allow-secrets always allows; otherwise refusing is the default and
# a false here (from the flag or userConfig) opts out of the --write refusal.
if [[ "$ASK_REFUSE" == "False" ]]; then ALLOW_SECRETS=1; fi

command -v muse >/dev/null || { echo "muse not found on PATH" >&2; exit 1; }

# Resolve "latest-contributor" through the same logic the fleet uses, so a single ask and
# a fleet run never silently disagree about which model they are paying for.
if [[ "$MODEL" == "latest-contributor" ]]; then
  # The path goes in as argv, not interpolated into the source: a plugin root containing
  # an apostrophe would otherwise break the Python literal. resolve_model already falls
  # back to muse_core.FALLBACK_MODEL on its own when the catalog is missing, so a second
  # literal here would just be a pin that goes stale independently.
  MODEL="$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
sys.stdout.write(m.resolve_model(m.LATEST)[0])
' "$SKILL_DIR/scripts/muse_core.py" 2>/dev/null)"
  if [[ -z "$MODEL" ]]; then
    echo "could not load $SKILL_DIR/scripts/muse_core.py to resolve a model" >&2
    exit 1
  fi
fi

# Where the last session id per repo is remembered. ${CLAUDE_PLUGIN_DATA} is the
# per-plugin directory that survives plugin updates; it is not set outside a Claude Code
# session, so fall back to the path the runtime allocates.
DATA_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/muse}"
REPO_ABS="$(cd "$REPO" 2>/dev/null && pwd || echo "$REPO")"
# Keyed by a hash of the absolute repo path. The directory is shared across every repo,
# and a filename built from the path itself would need escaping on three platforms.
SESSION_KEY="$(printf '%s' "$REPO_ABS" | python3 -c 'import hashlib,sys;print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:16])' 2>/dev/null)"
SESSION_FILE="$DATA_DIR/last-session/$SESSION_KEY"

# Scan for credentials BEFORE anything is recorded or spawned, in --write and
# read-only mode alike: a read-only worker still reads the repo, and reading a
# secret sends it to the contributor tier just as writing does.
if [[ "$NO_SECRET_SCAN" -eq 0 ]]; then
  ASK_SCAN_OUT="$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
# ALLOW_SECRETS already folds the flag, userConfig and the default together
# (resolved above), so the scan takes it as given rather than re-reading env —
# a --refuse-on-secrets flag must beat a differently-set userConfig value.
allow = sys.argv[3] == "1"
pf = m.preflight_secrets([sys.argv[2]], {"allow_secrets": allow, "no_secret_scan": False})
if pf["refuse"]:
    sys.stderr.write("muse_ask: refused: %s\n" % (pf["reason"] or ""))
    for f in pf["certain"][:20]:
        sys.stderr.write("  %s:%s %s\n" % (f["file"], f["line"], f["kind"]))
    sys.exit(3)
if pf["certain"] or pf["possible"] or pf["truncated"]:
    sys.stderr.write("muse_ask: secret scan — %d certain, %d possible across %d files%s\n"
                     % (len(pf["certain"]), len(pf["possible"]), pf["files_scanned"],
                        " (PARTIAL — hit the file cap)" if pf["truncated"] else ""))
sys.exit(0)
' "$SKILL_DIR/scripts/muse_core.py" "$REPO_ABS" "$ALLOW_SECRETS" 2>&1)"
  ASK_RC=$?
  if [ -n "$ASK_SCAN_OUT" ]; then printf '%s\n' "$ASK_SCAN_OUT" >&2; fi
  if [ "$ASK_RC" -eq 3 ]; then exit 1; fi
  if [ "$ASK_RC" -ne 0 ]; then
    echo "muse_ask: refused: the credential scan could not run (exit $ASK_RC); pass --no-secret-scan to skip it" >&2
    exit 1
  fi
fi

if [[ "$CONTINUE" -eq 1 && -z "$SESSION" ]]; then
  if [[ -s "$SESSION_FILE" ]]; then
    SESSION="$(head -c 100 "$SESSION_FILE" | tr -d '[:space:]')"
    echo "muse_ask: continuing session $SESSION" >&2
  else
    # Not an error. --continue with nothing to continue is a fresh conversation, and
    # failing here would make the flag unsafe to put in a script.
    echo "muse_ask: no previous session recorded for $REPO_ABS — starting a new one" >&2
  fi
fi

# Reusing a session id across invocations continues that conversation; an id muse has
# never seen simply starts a new one under that id, so this is safe either way.
if [[ -z "$SESSION" ]]; then
  SESSION="$(python3 -c 'import uuid;print(uuid.uuid4())')"
fi

# Recorded BEFORE the run, not after: a run that times out or crashes has still created
# the session on muse's side, and that is exactly the one a user wants to resume.
if [[ -n "$SESSION_KEY" ]]; then
  mkdir -p "$DATA_DIR/last-session" 2>/dev/null \
    && printf '%s\n' "$SESSION" > "$SESSION_FILE" 2>/dev/null || true
fi

ARGS=(exec --json --model "$MODEL" --reasoning-effort "$EFFORT"
      --session-id "$SESSION"
      --user-input-auto-resolve --no-foreign-personal-context)

if [[ "$WRITE" -eq 1 ]]; then
  ARGS+=(--yolo)
else
  # Keep the sandbox on; just forbid edits. Note muse can still write via shell, so this
  # is a strong default rather than a hard guarantee -- use a worktree if that matters.
  ARGS+=(--disable-approval --disable-write --trust-workspace)
fi

[[ -n "$SCHEMA" ]]    && ARGS+=(--output-schema "$SCHEMA")
[[ -n "$MAX_STEPS" ]] && ARGS+=(--max-model-steps "$MAX_STEPS")

# `mktemp -t NAME` is BSD-only; GNU coreutils rejects a template with no trailing X's and
# prints nothing, which would leave EVENTS empty and break every run on Linux. Same bug
# validate.sh had.
EVENTS="$(mktemp "${TMPDIR:-/tmp}/muse_ask.XXXXXX")"
if [[ -z "$EVENTS" || ! -f "$EVENTS" ]]; then
  echo "could not create a temp file for muse output" >&2
  exit 1
fi
# Kill the watchdog's whole group, not just the subshell: killing the subshell alone
# leaves its `sleep` running, and an orphaned watchdog would still fire later against a
# PID the kernel has since recycled. INT/TERM matter as much as EXIT -- those are the
# paths where the watchdog would otherwise outlive the script.
PID=""
cleanup() {
  if [[ -n "${WATCHDOG:-}" ]]; then
    kill -- -"$WATCHDOG" 2>/dev/null || kill "$WATCHDOG" 2>/dev/null
  fi
  rm -f "$EVENTS"
}
# Signal the muse group BEFORE cleanup kills the watchdog: muse runs --yolo in its
# own process group, so killing only the watchdog left it running unbounded. The
# explicit exit stops the script from falling through to parse a half-written file.
on_signal() { if [[ -n "${PID:-}" ]]; then kill -9 -- -"$PID" 2>/dev/null || kill -9 "$PID" 2>/dev/null; fi; cleanup; trap - EXIT; exit "$1"; }
trap cleanup EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP

# Printed so a follow-up is possible: pass it back with --session to continue this
# conversation instead of re-explaining the context. stderr, so it never pollutes the
# answer on stdout that callers capture with $(...).
echo "muse_ask: session $SESSION" >&2

# Job control, so each background job leads its own process group and can be signalled
# as a group. Without it the timeout below killed a bash subshell and left the real muse
# process running unbounded -- writing into a deleted temp file and holding its session.
set -m
cd "$REPO" || { echo "cannot enter $REPO" >&2; exit 1; }
muse "${ARGS[@]}" "$PROMPT" > "$EVENTS" 2>/dev/null &
PID=$!
# The watchdog MUST NOT inherit stdout. A background process holding the write end keeps
# command substitution -- ANS=$(muse_ask.sh ...), which is how any caller uses this --
# blocked until the sleep expires, long after muse itself has exited.
( sleep "$TIMEOUT"; kill -0 "$PID" 2>/dev/null && kill -9 -- -"$PID" 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG=$!
set +m
wait "$PID" 2>/dev/null
kill -- -"$WATCHDOG" 2>/dev/null || kill "$WATCHDOG" 2>/dev/null
wait "$WATCHDOG" 2>/dev/null

python3 - "$EVENTS" <<'PY'
import json, sys

term = None
for line in open(sys.argv[1], errors="replace"):
    try:
        p = json.loads(line).get("payload", {})
    except ValueError:
        continue
    if p.get("kind") == "run_terminal":
        term = p

if term is None:
    print("muse produced no run_terminal record (timed out or crashed)", file=sys.stderr)
    sys.exit(1)
if term.get("terminal") != "completed":
    print(term.get("reason") or "muse run failed", file=sys.stderr)
    sys.exit(1)

# Muse can emit several final answers concatenated; the last one is the finished state.
text = (term.get("text") or "").strip()
dec, idx, last, any_obj = json.JSONDecoder(), 0, None, False
while idx < len(text):
    try:
        obj, end = dec.raw_decode(text, idx)
    except ValueError:
        break
    last, any_obj, idx = obj, True, end
    while idx < len(text) and text[idx] in " \t\r\n":
        idx += 1

print(json.dumps(last, indent=2) if any_obj else text)
PY
