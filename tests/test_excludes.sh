# shellcheck shell=bash
# Harvest excludes follow git glob rules (issue w11-excludes). Sourced by
# scripts/validate.sh; also runs standalone.
EX_STANDALONE=0
if ! declare -F ok >/dev/null 2>&1; then
  EX_STANDALONE=1
  PASS=0; FAIL=0
  ok() { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
  bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ -n "${2:-}" ] && echo "        $2"; }
  SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  LAB="$(mktemp -d "${TMPDIR:-/tmp}/musetest.XXXXXX")"
  export PYTHONUTF8=1
  shell_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi; }
fi
EX_TASK="$SKILL/scripts/muse_task.py"
EX="$LAB/v_excludes"; rm -rf "$EX"; mkdir -p "$EX/bin"

# The stub stands in for a worker: it runs $EX_ACTION against the worktree
# muse_task hands it, then emits the one terminal event run_muse needs.
cat > "$EX/bin/muse" <<'STUB'
#!/usr/bin/env bash
wt=""; prev=""
for a in "$@"; do [ "$prev" = "--workspace" ] && wt="$a"; prev="$a"; done
[ -n "$wt" ] && [ -n "${EX_ACTION:-}" ] && python3 "$EX_ACTION" "$wt"
printf '{"payload":{"kind":"run_terminal","terminal":"completed","text":"ok"}}\n'
STUB
chmod +x "$EX/bin/muse"
. "$(dirname "${BASH_SOURCE[0]}")/lib_stub.sh"
win_cmd_shim "$EX/bin/muse"
EX_PATH="$(shell_path "$EX/bin"):$PATH"

ex_repo_seg() {  # ex_repo_seg <dir> -- one tracked file under an excluded dir name
  rm -rf "$1"; mkdir -p "$1/a/b"
  git init -q -b main "$1"
  printf 't = 1\n' > "$1/a/t.py"
  git -C "$1" add -A
  git -C "$1" -c user.email=t@l -c user.name=t commit -qm init
}
ex_run() {  # ex_run <repo> <id> <action.py> [extra run args...] -> JSON on stdout
  local repo="$1" id="$2" action="$3"; shift 3
  (cd "$repo" && PATH="$EX_PATH" EX_ACTION="$action" python3 "$EX_TASK" run --id "$id" \
     --repo "$repo" --out "$repo/.muse-fleet/tasks" --worktree-root "$repo.wt" \
     --prompt noop "$@" 2>/dev/null)
}

# 1. Unit table: * stays in one segment, ** spans segments.
EX_T1=$(python3 - "$SKILL" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import muse_core as m
rows = [
    ("a/c.py", "a/*.py", True),
    ("a/b/c.py", "a/*.py", False),
    ("ab/c.py", "a/*.py", False),
    ("a/b/c.py", "a/**/*.py", True),
    ("a/c.py", "a/**/*.py", True),
    ("node_modules/a.js", "**/node_modules/**", True),
    ("sub/node_modules/y/i.js", "**/node_modules/**", True),
    ("src/node_modules_util.py", "**/node_modules/**", False),
    ("a/b/x.txt", "a/*", True),
    ("x/y/c.py", "**/c.py", True),
    ("c.py", "**/c.py", True),
    ("a/b/c.py", "a/**/b/c.py", True),
    ("a/bc/d.py", "a/?/d.py", False),
    ("a/x.py", "a/[xy].py", True),
    ("a/b/c", "a/[!x]/c", True),
    (".muse-fleet/tasks/v/patch.diff", ".muse-fleet/", True),
    ("d/e/f.pyc", "*.pyc", True),
    ("x/build/o", "build", True),
]
if not rows:
    print("empty table")
    sys.exit(1)
bad = 0
for path, pat, want in rows:
    got = m._excluded(path, [pat])
    if got != want:
        bad += 1
        print("MISS %r %r got=%r want=%r" % (path, pat, got, want))
sys.exit(1 if bad else 0)
PY
)
if [ $? -eq 0 ]; then
  ok "excludes: _excluded follows git glob rules (* stays in one segment, ** spans segments)"
else
  bad "excludes: _excluded follows git glob rules (* stays in one segment, ** spans segments)" "$EX_T1"
fi

cat > "$EX/seg.py" <<'PY'
import os, sys
wt = sys.argv[1]
open(os.path.join(wt, "a/t.py"), "w").write("t = 2\n")
for rel in ("a/c.py", "a/b/c.py"):
    p = os.path.join(wt, rel); os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w").write("new\n")
PY

# 2. a/*.py drops new a/c.py, keeps new a/b/c.py and the tracked a/t.py edit.
ex_repo_seg "$EX/r1"
EX_R2=$(ex_run "$EX/r1" v "$EX/seg.py" --exclude 'a/*.py' --exclude .muse-fleet/)
echo "$EX_R2" | python3 -c '
import json,sys; d=json.load(sys.stdin); fc=d.get("files_changed")
sys.exit(0 if isinstance(fc,list) and sorted(fc)==["a/b/c.py","a/t.py"] else 1)' \
  && ok "excludes: a/*.py drops new a/c.py, keeps new a/b/c.py and the tracked a/t.py edit" \
  || bad "excludes: a/*.py drops new a/c.py, keeps new a/b/c.py and the tracked a/t.py edit" "$EX_R2"

# 3. a/**/*.py drops both new files, keeps the tracked edit.
ex_repo_seg "$EX/r2"
EX_R3=$(ex_run "$EX/r2" v "$EX/seg.py" --exclude 'a/**/*.py' --exclude .muse-fleet/)
echo "$EX_R3" | python3 -c '
import json,sys; d=json.load(sys.stdin); fc=d.get("files_changed")
sys.exit(0 if isinstance(fc,list) and sorted(fc)==["a/t.py"] else 1)' \
  && ok "excludes: a/**/*.py drops a/c.py and a/b/c.py, keeps the tracked a/t.py edit" \
  || bad "excludes: a/**/*.py drops a/c.py and a/b/c.py, keeps the tracked a/t.py edit" "$EX_R3"

# 4. Root and nested node_modules contents drop; a lookalike name stays.
cat > "$EX/nested.py" <<'PY'
import os, sys
wt = sys.argv[1]
open(os.path.join(wt, "keep.txt"), "w").write("new\n")
for rel in ("node_modules/a.js", "sub/node_modules/y/i.js", "src/node_modules_util.py"):
    p = os.path.join(wt, rel); os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w").write("x\n")
PY
rm -rf "$EX/r3"; mkdir -p "$EX/r3"; git init -q -b main "$EX/r3"
printf 'old\n' > "$EX/r3/keep.txt"
git -C "$EX/r3" add -A
git -C "$EX/r3" -c user.email=t@l -c user.name=t commit -qm init
EX_R4=$(ex_run "$EX/r3" v "$EX/nested.py" --exclude '**/node_modules/**' --exclude .muse-fleet/)
echo "$EX_R4" | python3 -c '
import json,sys; d=json.load(sys.stdin); fc=d.get("files_changed")
sys.exit(0 if isinstance(fc,list) and sorted(fc)==["keep.txt","src/node_modules_util.py"] else 1)' \
  && ok "excludes: **/node_modules/** drops root and nested contents, keeps a lookalike name" \
  || bad "excludes: **/node_modules/** drops root and nested contents, keeps a lookalike name" "$EX_R4"

# 5. The CLI doc no longer shows pathspec excludes applied to tracked files.
EX_T5=$(python3 - "$SKILL" <<'PY'
import sys
p = sys.argv[1] + "/references/muse-cli.md"
s = open(p, encoding="utf-8").read()
if not s or "harvest" not in s:
    print("doc empty or missing harvest")
    sys.exit(1)
if ":(exclude,glob)" in s:
    print("doc still shows pathspec excludes")
    sys.exit(1)
if "Tracked files are always harvested" not in s:
    print("doc does not state tracked files are always harvested")
    sys.exit(1)
sys.exit(0)
PY
)
if [ $? -eq 0 ]; then
  ok "excludes: muse-cli.md no longer documents pathspec excludes applied to tracked files"
else
  bad "excludes: muse-cli.md no longer documents pathspec excludes applied to tracked files" "$EX_T5"
fi

if [ "$EX_STANDALONE" -eq 1 ]; then
  rm -rf "$LAB"
  exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
fi
