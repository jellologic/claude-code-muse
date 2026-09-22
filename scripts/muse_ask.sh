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
# Read-only by default: writes are disabled and the sandbox stays on, so this is safe to
# point at a dirty working copy. --write opts into editing (and disables the sandbox),
# which you should only do against a worktree or a repo you are willing to have modified.
#
# Exits 0 and prints the final answer, or exits 1 and prints the failure reason to stderr.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EFFORT="low"
MODEL="latest-contributor"
SCHEMA=""
REPO="."
WRITE=0
TIMEOUT=600
MAX_STEPS=""

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --effort)    EFFORT="$2"; shift 2 ;;
    --model)     MODEL="$2"; shift 2 ;;
    --schema)    SCHEMA="$2"; shift 2 ;;
    --repo)      REPO="$2"; shift 2 ;;
    --timeout)   TIMEOUT="$2"; shift 2 ;;
    --max-steps) MAX_STEPS="$2"; shift 2 ;;
    --write)     WRITE=1; shift ;;
    -h|--help)   usage 0 ;;
    --)          shift; break ;;
    -*)          echo "unknown flag: $1" >&2; usage 1 ;;
    *)           break ;;
  esac
done

PROMPT="${*:-}"
[[ -z "$PROMPT" ]] && { echo "no prompt given" >&2; usage 1; }

command -v muse >/dev/null || { echo "muse not found on PATH" >&2; exit 1; }

# Resolve "latest-contributor" through the same logic the fleet uses, so a single ask and
# a fleet run never silently disagree about which model they are paying for.
if [[ "$MODEL" == "latest-contributor" ]]; then
  MODEL="$(python3 -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('mc', '$SKILL_DIR/scripts/muse_core.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
sys.stdout.write(m.resolve_model(m.LATEST)[0])
" 2>/dev/null)" || MODEL="muse-spark-1.3-contributor"
  [[ -z "$MODEL" ]] && MODEL="muse-spark-1.3-contributor"
fi

ARGS=(exec --json --model "$MODEL" --reasoning-effort "$EFFORT"
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

EVENTS="$(mktemp -t muse_ask)"
trap 'rm -f "$EVENTS"' EXIT

( cd "$REPO" && muse "${ARGS[@]}" "$PROMPT" ) > "$EVENTS" 2>/dev/null &
PID=$!
# The watchdog MUST NOT inherit stdout. A background process holding the write end keeps
# command substitution -- ANS=$(muse_ask.sh ...), which is how any caller uses this --
# blocked until the sleep expires, long after muse itself has exited.
( sleep "$TIMEOUT"; kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG=$!
wait "$PID" 2>/dev/null
kill "$WATCHDOG" 2>/dev/null
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
