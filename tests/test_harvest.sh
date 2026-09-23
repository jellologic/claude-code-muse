# shellcheck shell=bash
# Issue #35: harvest through the real muse_task.py CLI, with a stub muse that edits the
# worktree the way a worker would. Sourced by scripts/validate.sh; also runs standalone.
HV_STANDALONE=0
if ! declare -F ok >/dev/null 2>&1; then
  HV_STANDALONE=1
  PASS=0; FAIL=0
  ok() { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
  bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ -n "${2:-}" ] && echo "        $2"; }
  SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  LAB="$(mktemp -d "${TMPDIR:-/tmp}/musetest.XXXXXX")"
  export PYTHONUTF8=1
  shell_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi; }
fi
HV_TASK="$SKILL/scripts/muse_task.py"
HV="$LAB/v_harvest35"; rm -rf "$HV"; mkdir -p "$HV/bin"

# The stub stands in for a worker: it runs $HV_ACTION against the worktree muse_task
# hands it, then emits the one terminal event run_muse needs to call the round completed.
cat > "$HV/bin/muse" <<'STUB'
#!/usr/bin/env bash
wt=""; prev=""
for a in "$@"; do [ "$prev" = "--worktree-existing" ] && wt="$a"; prev="$a"; done
[ -n "$wt" ] && [ -n "${HV_ACTION:-}" ] && python3 "$HV_ACTION" "$wt"
printf '{"payload":{"kind":"run_terminal","terminal":"completed","text":"ok"}}\n'
STUB
chmod +x "$HV/bin/muse"
HV_PATH="$(shell_path "$HV/bin"):$PATH"

hv_repo() {  # hv_repo <dir> -- tracks files under three DEFAULT_EXCLUDES entries
  rm -rf "$1"; mkdir -p "$1/build" "$1/dist" "$1/logs"; git init -q -b main "$1"
  printf "VERSION = 'BROKEN'\n" > "$1/build/version.py"
  printf 'ns = {}\nexec(open("build/version.py").read(), ns)\nassert ns["VERSION"] == "1.0", ns["VERSION"]\n' > "$1/check.py"
  printf 'old\n' > "$1/dist/index.js"
  printf 'old\n' > "$1/logs/keep.log"
  git -C "$1" add -A
  git -C "$1" -c user.email=t@l -c user.name=t commit -qm init
}
hv_run() {  # hv_run <repo> <id> <action.py> [extra run args...] -> JSON on stdout
  local repo="$1" id="$2" action="$3"; shift 3
  (cd "$repo" && PATH="$HV_PATH" HV_ACTION="$action" python3 "$HV_TASK" run --id "$id" \
     --repo "$repo" --out "$repo/.muse-fleet/tasks" --worktree-root "$repo.wt" \
     --prompt noop "$@" 2>/dev/null)
}
hv_do() {  # hv_do <repo> <subcommand> <id> [args...] -> JSON on stdout
  local repo="$1" sub="$2" id="$3"; shift 3
  PATH="$HV_PATH" python3 "$HV_TASK" "$sub" --id "$id" --out "$repo/.muse-fleet/tasks" "$@" 2>/dev/null
}

cat > "$HV/fix.py" <<'PY'
import sys
open(sys.argv[1] + "/build/version.py", "w").write("VERSION = '1.0'\n")
PY
cat > "$HV/many.py" <<'PY'
import os, sys
wt = sys.argv[1]
def w(rel, data):
    p = os.path.join(wt, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "wb").write(data)
w("build/version.py", b"VERSION = '1.0'\n")
w("dist/index.js", b"new\n")
w("logs/keep.log", b"new\n")
w("model.bin", bytes(range(256)) * 4)
w("my notes.md", b"n\n")
w("résumé.py", b"x = 1\n")
w("build/junk.o", b"junk\n")
w("app.log", b"junk\n")
w("sub/node_modules/y/i.js", b"junk\n")
PY

# 1. The issue's exact scenario: a tracked build/version.py is the whole fix.
hv_repo "$HV/r1"
hv_run "$HV/r1" v "$HV/fix.py" >/dev/null
hv_do "$HV/r1" verify v --command "python3 check.py" >/dev/null
HV_F1=$(hv_do "$HV/r1" finish v --verdict accept)
echo "$HV_F1" | python3 -c '
import json,sys; d=json.load(sys.stdin)
sys.exit(0 if d.get("verified_by_supervisor") is True and d.get("files_changed")==["build/version.py"] and d.get("patch_lines",0)>0 else 1)' \
  && ok "harvest: a fix in a TRACKED build/ file reaches the patch (issue #35)" \
  || bad "harvest: accept certified a patch missing the tracked fix" "$HV_F1"

# 2. Mixed tree: tracked files under excluded dirs, a binary, unicode and spaced names, junk.
hv_repo "$HV/r2"
HV_R2=$(hv_run "$HV/r2" m "$HV/many.py")
echo "$HV_R2" | python3 -c '
import json,sys,unicodedata
d=json.load(sys.stdin); n=lambda s: unicodedata.normalize("NFC", s)
got=sorted(n(f) for f in d.get("files_changed") or [])
want=sorted(n(f) for f in ["build/version.py","dist/index.js","logs/keep.log","model.bin","my notes.md","résumé.py"])
sys.exit(0 if got==want else 1)' \
  && ok "harvest: files_changed lists tracked, binary, spaced and unicode paths exactly, and no untracked junk" \
  || bad "harvest: files_changed is wrong" "$HV_R2"
HV_P2="$HV/r2/.muse-fleet/tasks/m/patch.diff"
HV_WT2=$(ls -d "$HV/r2.wt"/*-m)
rm -rf "$HV/fresh2"; git clone -q "$HV/r2" "$HV/fresh2"
[ -s "$HV_P2" ] && git -C "$HV/fresh2" apply "$HV_P2" 2>/dev/null \
  && (cd "$HV/fresh2" && python3 check.py) 2>/dev/null \
  && cmp -s "$HV/fresh2/model.bin" "$HV_WT2/model.bin" \
  && ok "harvest: the patch applies on a fresh clone, fixes the check, and the binary is byte-identical" \
  || bad "harvest: the patch does not apply cleanly on a fresh clone" "$(git -C "$HV/fresh2" apply --check "$HV_P2" 2>&1 | head -3)"

# 3. Fingerprint sees a TRACKED excluded-dir edit made after the check passed.
hv_repo "$HV/r3"
hv_run "$HV/r3" s "$HV/fix.py" >/dev/null
hv_do "$HV/r3" verify s --command "python3 check.py" >/dev/null
printf "VERSION = '1.0'\nSNEAK = 1\n" > "$(ls -d "$HV/r3.wt"/*-s)/build/version.py"
HV_F3=$(hv_do "$HV/r3" finish s --verdict accept)
echo "$HV_F3" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("status")=="refused" and d.get("stale") is True else 1)' \
  && ok "fingerprint: a tracked build/ edit after verify makes the check stale" \
  || bad "fingerprint: blind to an edit in a tracked build/ file" "$HV_F3"

# 4. An explicit nested exclude really excludes directory contents, root and nested.
cat > "$HV/nested.py" <<'PY'
import os, sys
wt = sys.argv[1]
for rel in ("node_modules/a.js", "sub/node_modules/y/i.js", "src/node_modules_util.py"):
    p = os.path.join(wt, rel); os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w").write("x\n")
PY
hv_repo "$HV/r4"
HV_R4=$(hv_run "$HV/r4" n "$HV/nested.py" --exclude '**/node_modules/**' --exclude .muse-fleet/)
echo "$HV_R4" | python3 -c '
import json,sys; d=json.load(sys.stdin); fc=d.get("files_changed") or []
sys.exit(0 if fc==["src/node_modules_util.py"] else 1)' \
  && ok "harvest: **/node_modules/** excludes root and nested contents, keeps a lookalike name" \
  || bad "harvest: nested exclude leaked or over-matched" "$HV_R4"

if [ "$HV_STANDALONE" -eq 1 ]; then
  rm -rf "$LAB"
  exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
fi
