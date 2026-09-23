# shellcheck shell=bash
# The CRLF-python defects below are platform-independent, so the Linux legs guard them
# too: a python whose stdout ends lines in CRLF (what native Windows python gives Git Bash).
# The timed-out-round check is different: kill_process_tree has one branch per platform,
# so each leg exercises only its own -- os.killpg on POSIX, taskkill /T via _taskkill_tree
# on Windows -- and neither leg covers the other. Sourced by validate.sh.
CG_STANDALONE=0
if ! declare -F ok >/dev/null 2>&1; then
  CG_STANDALONE=1
  PASS=0; FAIL=0
  ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
  bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && echo "        $2"; }
  SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  LAB="$(mktemp -d "${TMPDIR:-/tmp}/musetest.XXXXXX")"
  export PYTHONUTF8=1
  shell_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi; }
fi
. "$(dirname "${BASH_SOURCE[0]}")/lib_stub.sh"

CG="$LAB/v_cigreen"; rm -rf "$CG"; mkdir -p "$CG/crlfpy" "$CG/bin" "$CG/cfg" "$CG/data/model-catalog"
CG_REALPY="$(command -v python3)"
# A python3 that ends every stdout line in CRLF. preflight.sh finds it by bash PATH lookup,
# so an extensionless script works on Windows too.
cat > "$CG/crlfpy/python3" <<STUB
#!/usr/bin/env bash
"$CG_REALPY" "\$@" | "$CG_REALPY" -c 'import sys; sys.stdout.buffer.write(sys.stdin.buffer.read().replace(b"\r\n", b"\n").replace(b"\n", b"\r\n"))'
STUB
chmod +x "$CG/crlfpy/python3"
CG_TESTED="$(sed -n 's/^MUSE_TESTED_VERSION = "\(.*\)"/\1/p' "$SKILL/scripts/muse_core.py")"
printf '#!/bin/sh\necho "muse %s"\n' "$CG_TESTED" > "$CG/bin/muse"; chmod +x "$CG/bin/muse"
printf '{"k":"v"}' > "$CG/cfg/auth.json"
cg_pf() {
  PATH="$(shell_path "$CG/crlfpy"):$(shell_path "$CG/bin"):/usr/bin:/bin" MUSE_CONFIG_DIR="$CG/cfg" \
    MUSE_DATA_DIR="$CG/data" CLAUDE_PLUGIN_ROOT="$SKILL" bash "$SKILL/hooks/preflight.sh" 2>/dev/null
}
CG_CR="$(PATH="$(shell_path "$CG/crlfpy"):$PATH" python3 -c 'print(1)' | od -c | tr -d ' \n')"
CG_OUT_MISSING="$(cg_pf)"
printf '{"rows":[{"model_id":"x-contributor"}]}' > "$CG/data/model-catalog/c.json"
CG_OUT_PRESENT="$(cg_pf)"; CG_RC=$?
if printf '%s' "$CG_CR" | grep -q '1\\r\\n' && printf '%s' "$CG_OUT_MISSING" | grep -q 'model catalog'; then
  ok "cigreen: preflight's catalog check runs through a CRLF python (a missing catalog is reported)"
else
  bad "cigreen: preflight's catalog check runs through a CRLF python (a missing catalog is reported)" "cr='$CG_CR' out='$CG_OUT_MISSING'"
fi
if printf '%s' "$CG_OUT_MISSING" | grep -q 'model catalog' && [ "$CG_RC" -eq 0 ] && [ -z "$CG_OUT_PRESENT" ]; then
  ok "cigreen: a CRLF python does not turn a present catalog into a missing one"
else
  bad "cigreen: a CRLF python does not turn a present catalog into a missing one" "rc=$CG_RC out='$CG_OUT_PRESENT'"
fi

# A timed-out round: run_muse's kill_process_tree must take the stub's whole tree down.
# This leg exercises only its own branch (os.killpg on POSIX; taskkill /T via
# _taskkill_tree on the Windows leg). The late write runs in a grandchild on purpose:
# a write in the stub's own shell dies with that shell, so only a grandchild
# distinguishes a group kill from killing the direct child.
mkdir -p "$CG/tbin"
cat > "$CG/tbin/muse" <<'STUB'
#!/bin/sh
wt=""; prev=""
for a in "$@"; do [ "$prev" = "--workspace" ] && wt="$a"; prev="$a"; done
echo "$$" >> "$CG_STUB_LOG"
( sleep 6; : > "${wt:-.}/late.txt" ) &
wait
printf '{"payload":{"kind":"run_terminal","terminal":"completed","text":"ok"}}\n'
STUB
chmod +x "$CG/tbin/muse"; win_cmd_shim "$CG/tbin/muse"
git init -q -b main "$CG/repo"; printf 'x\n' > "$CG/repo/a.txt"
git -C "$CG/repo" add -A; git -C "$CG/repo" -c user.email=t@l -c user.name=t commit -qm init
: > "$CG/stub.log"
CG_T="$(PATH="$(shell_path "$CG/tbin"):$PATH" CG_STUB_LOG="$CG/stub.log" MUSE_DATA_DIR="$CG/data" \
  python3 "$SKILL/scripts/muse_task.py" run --id to --out "$CG/out" --repo "$CG/repo" \
  --worktree-root "$CG/wt" --model stub-model --no-secret-scan --timeout 2 --prompt p 2>/dev/null)"
sleep 7
CG_ST="$(printf '%s' "$CG_T" | python3 -c 'import json,sys
try: d=json.load(sys.stdin); print(d.get("status"), d.get("worktree"))
except Exception: print("")')"
CG_WT="${CG_ST#* }"
CG_ALIVE=no
for CG_P in $(cat "$CG/stub.log"); do kill -0 "$CG_P" 2>/dev/null && CG_ALIVE=yes; done
if [ -s "$CG/stub.log" ] && [ "${CG_ST%% *}" = "timeout" ] && [ -d "$CG_WT" ] \
    && [ ! -e "$CG_WT/late.txt" ] && [ "$CG_ALIVE" = no ]; then
  ok "cigreen: a timed-out round kills the worker's whole tree, and nothing writes after it"
else
  bad "cigreen: a timed-out round kills the worker's whole tree, and nothing writes after it" \
    "log=$(tr '\n' ' ' < "$CG/stub.log") st='$CG_ST' alive=$CG_ALIVE late=$([ -e "$CG_WT/late.txt" ] && echo yes || echo no)"
fi

if [ "$CG_STANDALONE" -eq 1 ]; then
  rm -rf "$LAB"
  echo "RESULT: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit $?
fi
