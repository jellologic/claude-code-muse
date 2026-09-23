# shellcheck shell=bash
# Guards for the eval suite (evals/): the --allow-tools checker fires when a
# gated tool goes missing, and case enumeration never yields a literal '*'.
# Behaviour is exercised, never source text: the mutated workflow copy runs
# the same tests/eval_workflow_check.py the suite uses, and EV_LIST_CASES
# runs against scratch dirs built under $LAB.
# Sourced from validate.sh AFTER tests/test_evals.sh (which defines
# EV_LIST_CASES). Every variable is EV_G_-prefixed because this file shares
# validate.sh's global namespace.
if ! declare -F ok >/dev/null 2>&1; then
  PASS=0; FAIL=0; SKIP=0
  ok() { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
  bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ -n "${2:-}" ] && echo "        $2"; }
  skip() { local n="$1"; shift; if [ "${CI:-}" = "true" ]; then FAIL=$((FAIL+n)); printf '  \033[31mFAIL\033[0m  SKIP counts as a failure under CI: %s\n' "$*"; else SKIP=$((SKIP+n)); printf '  \033[33mSKIP\033[0m  %s\n' "$*"; fi; }
  SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  LAB="$(mktemp -d "${TMPDIR:-/tmp}/musetest.XXXXXX")"
  # Standalone only: falling off the end must not leave the lab behind under TMPDIR.
  trap 'rm -rf "$LAB"' EXIT
  native_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
  }
fi

EV_G_BASE="$LAB/v_evals_guards"
mkdir -p "$EV_G_BASE"

# The --allow-tools check must fire on a workflow missing Workflow: copy
# evals.yml under $LAB, delete ` Workflow` from the eval command, and run
# the same checker the suite uses against the copy.
EV_G_YML="$EV_G_BASE/evals-missing-workflow.yml"
cp "$SKILL/.github/workflows/evals.yml" "$EV_G_YML"
EV_G_RUN=$(grep 'claude plugin eval \.' "$EV_G_YML" | head -1 | tr -d '\r')
if [ -z "$EV_G_RUN" ]; then
  bad "evals: the --allow-tools check fires on a workflow missing Workflow" "setup broken: no eval command in the copied workflow"
elif ! printf '%s' "$EV_G_RUN" | grep -q -- '--allow-tools.*Bash.*Edit.*Write.*Workflow'; then
  bad "evals: the --allow-tools check fires on a workflow missing Workflow" "setup broken: the copied command lacks a tool already: $EV_G_RUN"
else
  # Scope the deletion to the eval command line so only the grant changes.
  sed '/claude plugin eval/s/ Workflow//' "$EV_G_YML" > "$EV_G_YML.mut"
  mv "$EV_G_YML.mut" "$EV_G_YML"
  EV_G_MUT=$(grep 'claude plugin eval \.' "$EV_G_YML" | head -1 | tr -d '\r')
  # An absence assertion proves nothing on an empty input: the mutated line
  # must still hold the command with --allow-tools and Bash, minus Workflow.
  if [ -z "$EV_G_MUT" ] || ! printf '%s' "$EV_G_MUT" | grep -q -- '--allow-tools' \
    || ! printf '%s' "$EV_G_MUT" | grep -q 'Bash' \
    || printf '%s' "$EV_G_MUT" | grep -q 'Workflow'; then
    bad "evals: the --allow-tools check fires on a workflow missing Workflow" "mutation failed: $EV_G_MUT"
  else
    EV_G_OUT=$(python3 "$(native_path "$SKILL/tests/eval_workflow_check.py")" "$(native_path "$EV_G_YML")" "$(native_path "$SKILL/evals")" 2>&1)
    EV_G_RC=$?
    if [ "$EV_G_RC" -ne 0 ] && printf '%s' "$EV_G_OUT" | grep -q 'Workflow'; then
      ok "evals: the --allow-tools check fires on a workflow missing Workflow"
    else
      bad "evals: the --allow-tools check fires on a workflow missing Workflow" "rc=$EV_G_RC out='$(printf '%s' "$EV_G_OUT" | tr -d '\r' | head -3)'"
    fi
  fi
fi

# Non-empty control: one case.yaml in a one-case dir lists exactly that case.
EV_G_ONE="$EV_G_BASE/one"
rm -rf "$EV_G_ONE"; mkdir -p "$EV_G_ONE/x"
printf 'name: x\n' > "$EV_G_ONE/x/case.yaml"
if ! declare -F EV_LIST_CASES >/dev/null 2>&1; then
  bad "evals: case enumeration lists the one case in a one-case dir" "EV_LIST_CASES is not defined; source tests/test_evals.sh first"
  bad "evals: case enumeration yields nothing for a dir with no case.yaml" "EV_LIST_CASES is not defined; source tests/test_evals.sh first"
else
  EV_G_GOT=$(EV_LIST_CASES "$EV_G_ONE")
  if [ "$EV_G_GOT" = "x" ]; then
    ok "evals: case enumeration lists the one case in a one-case dir"
  else
    bad "evals: case enumeration lists the one case in a one-case dir" "got '$EV_G_GOT', want exactly 'x'"
  fi

  # Empty dir with a subdir but no case.yaml: bash 3.2 leaves the glob
  # unexpanded, so without the [ -f ] guard this would yield a literal '*'.
  EV_G_EMPTY="$EV_G_BASE/empty"
  rm -rf "$EV_G_EMPTY"; mkdir -p "$EV_G_EMPTY/y"
  if [ ! -d "$EV_G_EMPTY/y" ]; then
    bad "evals: case enumeration yields nothing for a dir with no case.yaml" "setup broken: no subdir to test"
  else
    EV_G_GOT2=$(EV_LIST_CASES "$EV_G_EMPTY")
    if [ -z "$EV_G_GOT2" ]; then
      ok "evals: case enumeration yields nothing for a dir with no case.yaml"
    else
      bad "evals: case enumeration yields nothing for a dir with no case.yaml" "got '$EV_G_GOT2', want empty (never a literal '*')"
    fi
  fi
fi
