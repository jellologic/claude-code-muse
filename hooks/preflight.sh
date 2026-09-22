#!/usr/bin/env bash
# SessionStart preflight for the muse plugin.
#
# Silent by design. Most sessions never delegate anything, and a status line printed into
# every one of them is a permanent context cost for an occasional benefit. This speaks up
# only when something would make a delegation fail, and says what to do about it.
#
# The failure it exists to prevent: a fan-out spawns N workers, every one of them dies on
# the same missing binary or missing credential, and you find out N task-timeouts later.
# Checking costs a few milliseconds here and saves a whole run there.
#
# Always exits 0. A preflight that can block a session is worse than no preflight.

set -uo pipefail

MUSE_CONFIG="${MUSE_CONFIG_DIR:-$HOME/.config/muse}"
MUSE_DATA="${MUSE_DATA_DIR:-$HOME/.local/share/muse}"
problems=()

# 1. The binary. Everything else is moot without it.
if ! command -v muse >/dev/null 2>&1; then
  problems+=("muse is not on PATH — the /muse:* commands and the muse-fleet skill cannot run. Install Muse Code, or check that its install dir (commonly ~/.local/bin) is on PATH.")
else
  # 2. Stored credentials. Existence only — never read the file.
  if [ ! -s "$MUSE_CONFIG/auth.json" ]; then
    problems+=("muse has no stored credentials at $MUSE_CONFIG/auth.json — run \`muse login\` (or \`muse auth set --api-key-stdin\`) before delegating, or every worker will fail identically.")
  fi

  # 3. The version. The event schema, the ten `exec` flags and the session directory
  #    layout are all coupled to a muse this plugin has actually been run against, and a
  #    rename in any of them shows up as every worker in a fan-out failing identically --
  #    which is precisely the class of failure this hook exists to get ahead of. One
  #    extra exec of a binary we have already located.
  TESTED=$(grep -m1 '^MUSE_TESTED_VERSION' "${CLAUDE_PLUGIN_ROOT:-.}/scripts/muse_core.py" 2>/dev/null | sed 's/.*"\(.*\)".*/\1/')
  FOUND=$(muse --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  if [ -n "$TESTED" ] && [ -n "$FOUND" ] \
     && [ "${TESTED%.*}" != "${FOUND%.*}" ]; then
    problems+=("this plugin is verified against Muse Code $TESTED and you have $FOUND — the event schema, the \`exec\` flags and the session layout are all coupled, so a rename in any of them shows up as every worker failing identically. Delegation may still work; \`/muse:doctor\` reports what resolves.")
  fi

  # 4. The model catalog. Its absence is not fatal: resolve_model falls back to a known-good
  #    id rather than refusing to run. But the fallback is pinned and goes stale, which is
  #    exactly the silent generation-drift the resolve-at-runtime design exists to avoid.
  if ! grep -qs -- '-contributor' "$MUSE_DATA"/model-catalog/*.json 2>/dev/null; then
    problems+=("muse's model catalog has no contributor models cached at $MUSE_DATA/model-catalog/ — delegation will fall back to a hardcoded model id instead of resolving the newest. Run any \`muse exec\` once to populate it.")
  fi
fi

[ ${#problems[@]} -eq 0 ] && exit 0

echo "muse plugin preflight found ${#problems[@]} issue(s) that would break delegation:"
for p in "${problems[@]}"; do
  echo "  - $p"
done
echo "Mention this only if the user tries to delegate work to muse; it is not relevant otherwise."
exit 0
