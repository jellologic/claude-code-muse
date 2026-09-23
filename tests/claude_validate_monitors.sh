#!/usr/bin/env bash
# claude_validate_monitors.sh — strict-validate the monitors config in CI.
#
# Standalone: NOT sourced by scripts/validate.sh (it needs `claude` on PATH,
# which the offline suite never assumes). The strict validator ignores a
# path-referenced monitors file -- measured: it passes even when the file holds
# [{"name":"x"}] -- so this script inlines the parsed array from
# monitors/monitors.json into a COPY of the manifest and validates that.
# A validation that cannot fail proves nothing, so the negative control feeds
# [{"name":"x"}] and requires --strict to reject it.
set -uo pipefail

if ! command -v claude >/dev/null 2>&1; then
  echo "claude_validate_monitors.sh: 'claude' is not on PATH" >&2
  exit 1
fi

SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/muse-monitors.XXXXXX")"
if [ -z "$SCRATCH" ] || [ ! -d "$SCRATCH" ]; then
  echo "claude_validate_monitors.sh: no scratch dir" >&2
  exit 1
fi
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

cp -r "$SKILL/.claude-plugin" "$SCRATCH/.claude-plugin"
# The manifest references ./workflows relatively; without it the copy fails
# for a reason that has nothing to do with the monitors under test.
if [ -d "$SKILL/workflows" ]; then cp -r "$SKILL/workflows" "$SCRATCH/workflows"; fi
export MON_COPY="$SCRATCH/.claude-plugin/plugin.json"
export MON_FILE="$SKILL/monitors/monitors.json"
python3 - <<'PY'
import json, os
copy = os.environ["MON_COPY"]
monitors = json.load(open(os.environ["MON_FILE"]))
d = json.load(open(copy))
d["experimental"]["monitors"] = monitors
json.dump(d, open(copy, "w"), indent=2)
PY
if ! claude plugin validate "$SCRATCH/.claude-plugin/plugin.json" --strict; then
  echo "claude_validate_monitors.sh: --strict rejected the inlined monitors" >&2
  exit 1
fi
echo "monitors validate: --strict accepts the inlined array"

python3 - <<'PY'
import json, os
copy = os.environ["MON_COPY"]
d = json.load(open(copy))
d["experimental"]["monitors"] = [{"name": "x"}]
json.dump(d, open(copy, "w"), indent=2)
PY
if claude plugin validate "$SCRATCH/.claude-plugin/plugin.json" --strict; then
  echo "claude_validate_monitors.sh: control did not fire (--strict accepted [{\"name\":\"x\"}])" >&2
  exit 1
fi
echo "control confirmed: --strict rejects a monitor without its required fields"
