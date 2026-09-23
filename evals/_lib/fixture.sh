#!/bin/sh
# Shared fixture helper for eval scaffolds. Sourced, never executed:
#   . "$(dirname "$0")/../_lib/fixture.sh"
# bash 3.2 compatible. No absolute paths, no machine-specific strings.

# Writes fake credentials and a model catalog into "$HOME" (the sandbox home
# the harness gives the scaffold and later the agent). The muse binary itself
# is NOT written here: the committed stub at evals/_lib/bin/muse reaches the
# sandbox through the operator's PATH, because case.yaml `execution.env`
# accepts only EVAL_* keys and production preflight reads no EVAL_* var.
stub_muse_home() {
  mkdir -p "$HOME/.config/muse" "$HOME/.local/share/muse/model-catalog"
  printf '{"stub": "claude plugin eval fixture, not a credential"}' > "$HOME/.config/muse/auth.json"
  printf '{"rows":[{"model_id":"muse-eval-1.0-contributor","visibility":"visible","release_date":"2026-01-01"}]}' > "$HOME/.local/share/muse/model-catalog/eval.json"
}

# The scaffold runs with an empty HOME and GIT_CONFIG_NOSYSTEM=1, so there is no
# git identity; commit with an explicit one-off identity instead.
fixture_commit() {
  git add -A && git -c user.name=eval -c user.email=eval@example.invalid commit -q -m "$1"
}
