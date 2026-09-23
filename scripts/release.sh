#!/usr/bin/env bash
# release.sh — tag a muse release with `claude plugin tag`, dry-run first.
#
# The dry run checks that plugin.json and the enclosing marketplace entry agree
# without creating anything, so version skew fails before any tag exists. There
# is deliberately no -f/--force passthrough: the dirty-tree and existing-tag
# refusals are the point of using `claude plugin tag` instead of git tag.
set -uo pipefail

DRY_RUN=0
PUSH=0
REMOTE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --push) PUSH=1; shift ;;
    --remote)
      if [ $# -lt 2 ]; then
        echo "release.sh: --remote needs a name" >&2
        exit 2
      fi
      REMOTE="$2"; shift 2 ;;
    -h|--help)
      echo "usage: bash scripts/release.sh [--dry-run] [--push] [--remote NAME]" >&2
      exit 0 ;;
    *)
      echo "release.sh: unknown argument '$1'" >&2
      echo "usage: bash scripts/release.sh [--dry-run] [--push] [--remote NAME]" >&2
      exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v claude >/dev/null 2>&1; then
  echo "release.sh: 'claude' is not on PATH; install the Claude Code CLI to run 'claude plugin tag'" >&2
  exit 2
fi

if ! claude plugin tag --dry-run "$ROOT"; then
  echo "release.sh: 'claude plugin tag --dry-run' failed; not tagging" >&2
  exit 1
fi

if [ "$DRY_RUN" = 1 ]; then
  exit 0
fi

ARGS=(-m "muse v%s")
if [ "$PUSH" = 1 ]; then
  ARGS+=(--push)
fi
if [ -n "$REMOTE" ]; then
  ARGS+=(--remote "$REMOTE")
fi
claude plugin tag "${ARGS[@]}" "$ROOT"
