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
  #    The glob lives in muse_core, the single source -- asking it keeps this check and
  #    `doctor` pointed at the same files when MUSE_DATA_DIR moves them.
  if command -v python3 >/dev/null 2>&1; then
    # A missing python3 or an unloadable muse_core.py must still be said once, under
    # the same header: without either, the catalog was not checked, and the silence
    # below would otherwise read as "everything is fine".
    CATALOG_OUT=$(python3 -c "import glob, importlib.util, os, sys; spec = importlib.util.spec_from_file_location(\"muse_core\", sys.argv[1]); mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod); print(os.path.expanduser(mod.CATALOG_GLOB)); [print(f) for f in glob.glob(os.path.expanduser(mod.CATALOG_GLOB))]" "${CLAUDE_PLUGIN_ROOT:-.}/scripts/muse_core.py" 2>/dev/null | tr -d '\r')
    if [ -z "$CATALOG_OUT" ]; then
      problems+=("could not load ${CLAUDE_PLUGIN_ROOT:-.}/scripts/muse_core.py with python3 — the model catalog check was skipped; reinstall the plugin or run /muse:doctor.")
    fi
    if [ -n "$CATALOG_OUT" ]; then
      CATALOG_GLOB_RESOLVED=$(printf '%s\n' "$CATALOG_OUT" | sed -n '1p')
      CATALOG_FILES=$(printf '%s\n' "$CATALOG_OUT" | tail -n +2)
      CATALOG_HIT=""
      while IFS= read -r f; do
        if [ -n "$f" ] && grep -qs -- "-contributor" "$f" 2>/dev/null; then
          CATALOG_HIT=1
          break
        fi
      done <<CATALOG_EOF
$CATALOG_FILES
CATALOG_EOF
      if [ -z "$CATALOG_HIT" ]; then
        problems+=("muse's model catalog has no contributor models cached at $CATALOG_GLOB_RESOLVED — delegation will fall back to a hardcoded model id instead of resolving the newest. Run any \`muse exec\` once to populate it.")
      fi
    fi
  else
    problems+=("python3 is not on PATH — the model catalog check was skipped, and muse-task / muse-fleet cannot run without it.")
  fi
fi

if [ ${#problems[@]} -gt 0 ]; then
  echo "muse plugin preflight found ${#problems[@]} issue(s) that would break delegation:"
  for p in "${problems[@]}"; do
    echo "  - $p"
  done
  echo "Mention this only if the user tries to delegate work to muse; it is not relevant otherwise."
fi

# Leftover delegation worktrees have an artifact record to show for them, so
# they are reported from SessionStart: SessionEnd output is discarded and
# reaches nobody. Silent when python3 is missing or there is nothing to say.
if command -v python3 >/dev/null 2>&1; then
  WT_OUT="$(python3 "${CLAUDE_PLUGIN_ROOT:-.}/hooks/leftover_worktrees.py" 2>/dev/null)"
  if [ -n "$WT_OUT" ]; then
    printf '%s\n' "$WT_OUT"
  fi
fi
exit 0
