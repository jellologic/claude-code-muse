# shellcheck shell=bash
# Issue #45: the owning repo, the exclude file and the catalog glob, driven through the
# real scripts with a stub muse. Every variable is WR_-prefixed because validate.sh
# sources this file into its own global namespace.
WR_STANDALONE=0
if ! declare -F ok >/dev/null 2>&1; then
  WR_STANDALONE=1
  PASS=0; FAIL=0
  ok() { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
  bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ -n "${2:-}" ] && echo "        $2"; }
  SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  LAB="$(mktemp -d "${TMPDIR:-/tmp}/musetest.XXXXXX")"
fi
WR="$LAB/v_wtres"; rm -rf "$WR"; mkdir -p "$WR/bin" "$WR/data" "$WR/cfg"
# Own stub, prepended explicitly: if a real muse is installed, validate.sh does not stub
# it, and a run here would spend tokens.
printf '#!/bin/sh\nexit 0\n' > "$WR/bin/muse"; chmod +x "$WR/bin/muse"
printf '{"k":1}' > "$WR/cfg/auth.json"
WR_PATH="$WR/bin:$PATH"
wr_repo() { mkdir -p "$1"; git init -q -b main "$1"; printf 'x\n' > "$1/a.txt"; git -C "$1" add -A; git -C "$1" -c user.email=t@l -c user.name=t commit -qm init; }
wr_task() { ( cd "$1" && shift && env PATH="$WR_PATH" MUSE_DATA_DIR="$WR/data" MUSE_CATALOG_GLOB="$WR/nocat/*.json" python3 "$SKILL/scripts/muse_task.py" "$@" 2>/dev/null ); }
wr_field() { python3 -c 'import json,sys
try: d=json.loads(sys.argv[1])
except Exception: sys.exit(1)
print(d.get(sys.argv[2]) or "")' "$1" "$2"; }

# 1. subcommands run from inside the task worktree
WR_R1="$WR/r1"; wr_repo "$WR_R1"
WR_O=$(wr_task "$WR_R1" run --id t1 --repo . --worktree-root "$WR/wt1" --prompt noop)
WR_WT=$(wr_field "$WR_O" worktree)
if [ -n "$WR_WT" ] && [ -d "$WR_WT" ]; then
  mkdir -p "$WR_WT/deep/er"
  WR_S=$(wr_task "$WR_WT" show --id t1)
  WR_V=$(wr_task "$WR_WT/deep/er" verify --id t1 --command true)
  [ "$(wr_field "$WR_S" id)" = t1 ] && [ -n "$(wr_field "$WR_S" worktree)" ] \
    && ok "show from inside the task worktree finds the task" || bad "show from inside the task worktree finds the task" "$WR_S"
  [ "$(wr_field "$WR_V" status)" = verified ] \
    && ok "verify from a task-worktree subdirectory finds the task" || bad "verify from a task-worktree subdirectory finds the task" "$WR_V"
else
  bad "run from the main checkout produced a worktree" "$WR_O"
fi

# 2. two runs from a linked worktree
WR_R2="$WR/r2"; wr_repo "$WR_R2"; WR_L2="$WR/l2"; git -C "$WR_R2" worktree add -q -b dev "$WR_L2"
WR_A=$(wr_task "$WR_L2" run --id a --repo . --worktree-root "$WR/wt2" --prompt noop)
WR_B=$(wr_task "$WR_L2" run --id b --repo . --worktree-root "$WR/wt2" --prompt noop)
WR_SA=$(wr_field "$WR_A" status); WR_SB=$(wr_field "$WR_B" status)
[ -n "$WR_SA" ] && [ "$WR_SA" != refused ] && [ -n "$WR_SB" ] && [ "$WR_SB" != refused ] \
  && ok "two consecutive runs from a linked worktree both start" || bad "two consecutive runs from a linked worktree both start" "a=$WR_A b=$WR_B"
# Absence of dirt is asserted only after proving run a actually wrote artifacts.
[ -n "$(wr_field "$WR_A" patch)" ] && [ -z "$(git -C "$WR_L2" status --porcelain)" ] && [ -z "$(git -C "$WR_R2" status --porcelain)" ] \
  && ok "task artifacts dirty neither the linked nor the main checkout" \
  || bad "task artifacts dirty neither the linked nor the main checkout" "linked='$(git -C "$WR_L2" status --porcelain)' main='$(git -C "$WR_R2" status --porcelain)'"

# 3. preflight, doctor and use_latest_contributor read one catalog
mkdir -p "$WR/full/model-catalog" "$WR/empty/model-catalog"
printf '{"rows":[{"model_id":"wr-fixture-contributor","visibility":"visible","release_date":"2099-01-01"}]}' > "$WR/full/model-catalog/c.json"
wr_pf() {  # wr_pf <data dir> [catalog glob]
  if [ -n "${2:-}" ]; then
    env PATH="$WR/bin:/usr/bin:/bin" MUSE_CATALOG_GLOB="$2" MUSE_CONFIG_DIR="$WR/cfg" MUSE_DATA_DIR="$1" CLAUDE_PLUGIN_ROOT="$SKILL" bash "$SKILL/hooks/preflight.sh" 2>/dev/null
  else
    env -u MUSE_CATALOG_GLOB PATH="$WR/bin:/usr/bin:/bin" MUSE_CONFIG_DIR="$WR/cfg" MUSE_DATA_DIR="$1" CLAUDE_PLUGIN_ROOT="$SKILL" bash "$SKILL/hooks/preflight.sh" 2>/dev/null
  fi
}
wr_doc() {  # wr_doc <data dir> [catalog glob] -> severity of the "model catalog" check
  if [ -n "${2:-}" ]; then
    WR_J=$(env PATH="$WR_PATH" MUSE_CATALOG_GLOB="$2" MUSE_DATA_DIR="$1" python3 "$SKILL/scripts/muse_doctor.py" --json --repo "$WR_R1" 2>/dev/null)
  else
    WR_J=$(env -u MUSE_CATALOG_GLOB PATH="$WR_PATH" MUSE_DATA_DIR="$1" python3 "$SKILL/scripts/muse_doctor.py" --json --repo "$WR_R1" 2>/dev/null)
  fi
  printf '%s' "$WR_J" | python3 -c 'import json,sys
d=json.load(sys.stdin); print([c["severity"] for c in d["checks"] if c["name"]=="model catalog"][0])' 2>/dev/null
}
for WR_C in "full|" "empty|" "empty|$WR/full/model-catalog/*.json"; do
  WR_DIR="$WR/${WR_C%%|*}"; WR_GLOB="${WR_C#*|}"
  WR_P=$(wr_pf "$WR_DIR" "$WR_GLOB"); WR_D=$(wr_doc "$WR_DIR" "$WR_GLOB")
  if printf '%s' "$WR_P" | grep -q 'model catalog'; then WR_PW=WARN; else WR_PW=OK; fi
  [ -n "$WR_D" ] && [ "$WR_PW" = "$WR_D" ] \
    && ok "preflight and doctor agree (MUSE_DATA_DIR=${WR_C%%|*}, MUSE_CATALOG_GLOB=${WR_GLOB:-unset})" \
    || bad "preflight and doctor agree (MUSE_DATA_DIR=${WR_C%%|*}, MUSE_CATALOG_GLOB=${WR_GLOB:-unset})" "preflight=$WR_PW doctor=$WR_D out='$WR_P'"
done
WR_U=$(env -u MUSE_CATALOG_GLOB MUSE_DATA_DIR="$WR/full" MUSE_SETTINGS="$WR/settings.json" bash "$SKILL/scripts/use_latest_contributor.sh" 2>&1)
printf '%s' "$WR_U" | grep -q 'wr-fixture-contributor' \
  && ok "use_latest_contributor.sh reads the catalog under MUSE_DATA_DIR" || bad "use_latest_contributor.sh reads the catalog under MUSE_DATA_DIR" "$WR_U"

if [ "$WR_STANDALONE" -eq 1 ]; then
  rm -rf "$LAB"
  exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
fi
