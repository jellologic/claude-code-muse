#!/usr/bin/env bash
# Credential-scan coverage: one preflight every driver calls, the worker started in
# the worktree it was scanned in, wider key formats, and no dotfile blind spot.
# Sourced by validate.sh; also runnable alone.
SEC_STANDALONE=0
if ! declare -F ok >/dev/null 2>&1; then
  SEC_STANDALONE=1
  set -uo pipefail
  export PYTHONUTF8=1
  if ! declare -F shell_path >/dev/null 2>&1; then
    native_path() {
      if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
    }
    shell_path() {
      if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi
    }
  fi
  SKILL="$(native_path "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)")"
  LAB="$(native_path "$(mktemp -d "${TMPDIR:-/tmp}/muse-sec.XXXXXX")")"
  if [ -z "${LAB:-}" ] || [ ! -d "$LAB" ]; then echo "no scratch dir" >&2; exit 1; fi
  # Standalone only: an early exit must not leave the lab behind under TMPDIR.
  trap 'rm -rf "$LAB"' EXIT
  PASS=0; FAIL=0
  ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
  bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && echo "        $2"; }
fi

if [ -z "${LAB:-}" ] || [ ! -d "${LAB:-}" ]; then
  echo "secrets: refusing to run without a scratch dir" >&2
  if [ "$SEC_STANDALONE" = 1 ]; then exit 1; else return 1; fi
fi

SEC_TASK="$SKILL/scripts/muse_task.py"
SEC_FLEET="$SKILL/scripts/muse_fleet.py"
SEC_CORE="$SKILL/scripts/muse_core.py"
SEC_ASK="$SKILL/scripts/muse_ask.sh"
SEC_DIR="$LAB/v_secrets"
SEC_N=0
SEC_RC=0
rm -rf "$SEC_DIR"; mkdir -p "$SEC_DIR/bin" "$SEC_DIR/askdata"

# A muse that logs its cwd and immediately completes. The log proves whether the
# worker started; its content proves WHERE it started.
cat > "$SEC_DIR/bin/muse" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "muse 1.3.0"; exit 0; fi
( pwd -W 2>/dev/null || pwd ) >> "$SEC_STUB_LOG"
printf '{"payload":{"kind":"run_terminal","terminal":"completed","text":"ok"}}\n'
STUB
chmod +x "$SEC_DIR/bin/muse"
# Native python on Windows cannot execute the extensionless bash stub: shutil.which
# honours PATHEXT (so it needs muse.cmd) and CreateProcess never consults PATHEXT at
# all, so even the .cmd is unreachable under the bare name unless run_muse resolves it
# via which() first. Same shape as validate.sh's make_muse_stub.
if command -v cygpath >/dev/null 2>&1; then
  printf '@echo off\r\n"%s" "%s" %%*\r\nexit /b %%ERRORLEVEL%%\r\n' \
    "$(native_path "$(command -v bash)")" \
    "$(native_path "$SEC_DIR/bin/muse")" > "$SEC_DIR/bin/muse.cmd"
fi
SEC_PATH="$(shell_path "$SEC_DIR/bin"):$PATH"

sec_mkrepo() {  # sec_mkrepo <dir> -- calc.py tracked, clean tree
  rm -rf "$1"; mkdir -p "$1"; git init -q -b main "$1"
  printf 'def add(a,b):\n    return a+b\n' > "$1/calc.py"
  git -C "$1" add -A
  git -C "$1" -c user.email=t@l -c user.name=t commit -qm init
}
sec_commit() {  # sec_commit <dir> <msg>
  git -C "$1" add -A
  git -C "$1" -c user.email=t@l -c user.name=t commit -qm "$2" >/dev/null 2>&1
}
sec_task() {  # sec_task <repo> <id> <n> [extra run args...] -> stdout JSON
  local SEC_R="$1"; local SEC_I="$2"; local SEC_NN="$3"; shift 3
  export SEC_STUB_LOG="$SEC_DIR/stub-$SEC_NN.log"; : > "$SEC_STUB_LOG"
  (cd "$SEC_R" && env -u CLAUDE_PLUGIN_OPTION_REFUSE_ON_SECRETS PATH="$SEC_PATH" python3 "$SEC_TASK" run --id "$SEC_I" --repo "$SEC_R" --out "$SEC_DIR/out-$SEC_NN" --worktree-root "$SEC_DIR/wt-$SEC_NN" --model stub-model --prompt p "$@" 2>/dev/null)
}
sec_fleet() {  # sec_fleet <repo> <tasks> <n> [extra...] -> report at fout-<n>, sets SEC_RC
  local SEC_R="$1"; local SEC_T="$2"; local SEC_NN="$3"; shift 3
  export SEC_STUB_LOG="$SEC_DIR/stub-$SEC_NN.log"; : > "$SEC_STUB_LOG"
  env -u CLAUDE_PLUGIN_OPTION_REFUSE_ON_SECRETS PATH="$SEC_PATH" python3 "$SEC_FLEET" --tasks "$SEC_T" --repo "$SEC_R" --out "$SEC_DIR/fout-$SEC_NN" --worktree-root "$SEC_DIR/fwt-$SEC_NN" --model stub-model "$@" >/dev/null 2>&1
  SEC_RC=$?
}
sec_ask() {  # sec_ask <repo> <n> [extra...] -> out/err files, sets SEC_RC
  local SEC_R="$1"; local SEC_NN="$2"; shift 2
  export SEC_STUB_LOG="$SEC_DIR/stub-$SEC_NN.log"; : > "$SEC_STUB_LOG"
  (cd "$SEC_R" && env -u CLAUDE_PLUGIN_OPTION_REFUSE_ON_SECRETS PATH="$SEC_PATH" CLAUDE_PLUGIN_DATA="$SEC_DIR/askdata" bash "$SEC_ASK" --model stub-model "$@" "q" >"$SEC_DIR/ask-out-$SEC_NN.txt" 2>"$SEC_DIR/ask-err-$SEC_NN.txt")
  SEC_RC=$?
}

# Symlinks are the vector, not the tool: Git Bash's ln copies, so only python
# os.symlink proves anything. Probe once; hosts without it skip the link checks
# without changing the check count.
SEC_CAN_LINK=0
if python3 - "$LAB/sec-link-probe" <<'PY'
import os, sys
SEC_D = sys.argv[1]
os.makedirs(SEC_D + "/src", exist_ok=True)
open(SEC_D + "/src/f", "w").write("x\n")
try:
    os.symlink(SEC_D + "/src", SEC_D + "/dst", target_is_directory=True)
except (OSError, NotImplementedError):
    sys.exit(1)
sys.exit(0 if os.path.islink(SEC_D + "/dst") else 1)
PY
then SEC_CAN_LINK=1; fi

# Fake values, assembled at runtime so this file itself holds no matching token.
python3 - "$SEC_DIR/vals.json" <<'PY'
import json, sys
SEC_PEM = "-----BEGIN RSA " + "PRIVATE KEY-----"
SEC_AKIA = "AKIA" + "IOSFODNN7EXAMPLE"
SEC_SKPROJ = "sk" + "-proj-" + "FAKE_fake-" * 5
SEC_SKSVC = "sk" + "-svcacct-" + "FAKE_fake-" * 5
SEC_SKDASH = "sk" + "-" + "FAKE-fake_" * 4
SEC_GHPAT = "github" + "_pat_" + "11FAKE" + "0" * 16 + "_" + "F" * 59
SEC_PGP = "-----BEGIN PGP " + "PRIVATE KEY BLOCK-----"
SEC_RKLIVE = "rk" + "_live_" + "FAKE" + "0" * 24
SEC_AWSSEC = "aws_secret" + "_access_key = " + "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
json.dump({"pem": SEC_PEM, "akia": SEC_AKIA, "skproj": SEC_SKPROJ,
           "sksvc": SEC_SKSVC, "skdash": SEC_SKDASH, "ghpat": SEC_GHPAT,
           "pgp": SEC_PGP, "rklive": SEC_RKLIVE, "awssec": SEC_AWSSEC},
          open(sys.argv[1], "w"))
PY

# One single-value dir per widened pattern, plus the near-miss dir.
python3 - "$SEC_DIR" <<'PY'
import json, os, sys
SEC_D = sys.argv[1]
SEC_VALS = json.load(open(os.path.join(SEC_D, "vals.json")))
for SEC_NAME, SEC_KEY in [("u1", "skproj"), ("u2", "sksvc"), ("u3", "skdash"),
                          ("u4", "ghpat"), ("u5", "pgp"), ("u6", "rklive"),
                          ("u7", "awssec")]:
    os.makedirs(os.path.join(SEC_D, SEC_NAME), exist_ok=True)
    open(os.path.join(SEC_D, SEC_NAME, "val.txt"), "w").write(SEC_VALS[SEC_KEY] + "\n")
os.makedirs(os.path.join(SEC_D, "u8"), exist_ok=True)
SEC_ANT = "sk" + "-ant-" + "x" * 30
SEC_AWSMISS = "aws_secret" + "_access_key = os.environ[" + chr(34) + "X" + chr(34) + "]"
SEC_RKMISS = "rk" + "_live_" + "short"
open(os.path.join(SEC_D, "u8", "val.txt"), "w").write(
    "sk-short\n" + SEC_AWSMISS + "\n" + SEC_RKMISS + "\n" + SEC_ANT + "\n")
PY

# Case repos: calc.py tracked, exactly one secret location each.
SEC_R_ENV="$SEC_DIR/r-env"; sec_mkrepo "$SEC_R_ENV"
mkdir -p "$SEC_R_ENV/deploy/env"
python3 - "$SEC_R_ENV/deploy/env/prod.pem" "$SEC_DIR/vals.json" <<'PY'
import json, sys
open(sys.argv[1], "w").write(json.load(open(sys.argv[2]))["pem"] + "\n")
PY
sec_commit "$SEC_R_ENV" creds
SEC_R_BUILD="$SEC_DIR/r-build"; sec_mkrepo "$SEC_R_BUILD"
mkdir -p "$SEC_R_BUILD/build"
python3 - "$SEC_R_BUILD/build/prod.pem" "$SEC_DIR/vals.json" <<'PY'
import json, sys
open(sys.argv[1], "w").write(json.load(open(sys.argv[2]))["pem"] + "\n")
PY
sec_commit "$SEC_R_BUILD" creds
SEC_R_LINK="$SEC_DIR/r-link"
if [ "$SEC_CAN_LINK" = 1 ]; then
  sec_mkrepo "$SEC_R_LINK"
  printf 'secrets\n' > "$SEC_R_LINK/.gitignore"
  mkdir -p "$SEC_DIR/outside"
  python3 - "$SEC_DIR/outside/key.pem" "$SEC_DIR/vals.json" <<'PY'
import json, sys
open(sys.argv[1], "w").write(json.load(open(sys.argv[2]))["pem"] + "\n")
PY
  python3 - "$SEC_DIR/outside" "$SEC_R_LINK/secrets" <<'PY'
import os, sys
os.symlink(sys.argv[1], sys.argv[2], target_is_directory=True)
PY
  sec_commit "$SEC_R_LINK" creds
fi
SEC_R_DOT="$SEC_DIR/r-dot"; sec_mkrepo "$SEC_R_DOT"
printf '.env\n' > "$SEC_R_DOT/.gitignore"
python3 - "$SEC_R_DOT/.env" "$SEC_DIR/vals.json" <<'PY'
import json, sys
open(sys.argv[1], "w").write("export AWS_ACCESS_KEY_ID=" + json.load(open(sys.argv[2]))["akia"] + "\n")
PY
sec_commit "$SEC_R_DOT" creds
SEC_R_PAT="$SEC_DIR/r-pat"; sec_mkrepo "$SEC_R_PAT"
python3 - "$SEC_R_PAT" "$SEC_DIR/vals.json" <<'PY'
import json, os, sys
SEC_REPO, SEC_VF = sys.argv[1], sys.argv[2]
SEC_VALS = json.load(open(SEC_VF))
for SEC_I, SEC_K in enumerate(["skproj", "sksvc", "skdash", "ghpat", "pgp", "rklive", "awssec"], 1):
    open(os.path.join(SEC_REPO, "p%d.txt" % SEC_I), "w").write("token=" + SEC_VALS[SEC_K] + "\n")
PY
sec_commit "$SEC_R_PAT" creds
SEC_R_IGN="$SEC_DIR/r-ign"; sec_mkrepo "$SEC_R_IGN"
printf 'local/\n' > "$SEC_R_IGN/.gitignore"
mkdir -p "$SEC_R_IGN/local"
python3 - "$SEC_R_IGN/local/creds.txt" "$SEC_DIR/vals.json" <<'PY'
import json, sys
open(sys.argv[1], "w").write(json.load(open(sys.argv[2]))["pem"] + "\n")
PY
sec_commit "$SEC_R_IGN" creds
printf '[{"id":"f","prompt":"p"}]\n' > "$SEC_DIR/tasks.json"
SEC_U9="$SEC_DIR/u9"; mkdir -p "$SEC_U9"; cp "$SEC_CORE" "$SEC_U9/muse_core.py"

python3 - "$SEC_DIR/u1" "$SEC_CORE" <<'PY' && ok "secrets: scan finds an sk-proj- key" || bad "secrets: scan finds an sk-proj- key"
import importlib.util, sys
SEC_SPEC = importlib.util.spec_from_file_location("mc", sys.argv[2])
SEC_M = importlib.util.module_from_spec(SEC_SPEC); SEC_SPEC.loader.exec_module(SEC_M)
SEC_R = SEC_M.scan_secrets(sys.argv[1])
sys.exit(0 if [SEC_F["kind"] for SEC_F in SEC_R["certain"]] == ["OpenAI-style API key"] else 1)
PY
python3 - "$SEC_DIR/u2" "$SEC_CORE" <<'PY' && ok "secrets: scan finds an sk-svcacct- key" || bad "secrets: scan finds an sk-svcacct- key"
import importlib.util, sys
SEC_SPEC = importlib.util.spec_from_file_location("mc", sys.argv[2])
SEC_M = importlib.util.module_from_spec(SEC_SPEC); SEC_SPEC.loader.exec_module(SEC_M)
SEC_R = SEC_M.scan_secrets(sys.argv[1])
sys.exit(0 if [SEC_F["kind"] for SEC_F in SEC_R["certain"]] == ["OpenAI-style API key"] else 1)
PY
python3 - "$SEC_DIR/u3" "$SEC_CORE" <<'PY' && ok "secrets: scan finds an sk- key containing - and _" || bad "secrets: scan finds an sk- key containing - and _"
import importlib.util, sys
SEC_SPEC = importlib.util.spec_from_file_location("mc", sys.argv[2])
SEC_M = importlib.util.module_from_spec(SEC_SPEC); SEC_SPEC.loader.exec_module(SEC_M)
SEC_R = SEC_M.scan_secrets(sys.argv[1])
sys.exit(0 if [SEC_F["kind"] for SEC_F in SEC_R["certain"]] == ["OpenAI-style API key"] else 1)
PY
python3 - "$SEC_DIR/u4" "$SEC_CORE" <<'PY' && ok "secrets: scan finds a github_pat_ token" || bad "secrets: scan finds a github_pat_ token"
import importlib.util, sys
SEC_SPEC = importlib.util.spec_from_file_location("mc", sys.argv[2])
SEC_M = importlib.util.module_from_spec(SEC_SPEC); SEC_SPEC.loader.exec_module(SEC_M)
SEC_R = SEC_M.scan_secrets(sys.argv[1])
sys.exit(0 if [SEC_F["kind"] for SEC_F in SEC_R["certain"]] == ["GitHub fine-grained token"] else 1)
PY
python3 - "$SEC_DIR/u5" "$SEC_CORE" <<'PY' && ok "secrets: scan finds a PGP private key block" || bad "secrets: scan finds a PGP private key block"
import importlib.util, sys
SEC_SPEC = importlib.util.spec_from_file_location("mc", sys.argv[2])
SEC_M = importlib.util.module_from_spec(SEC_SPEC); SEC_SPEC.loader.exec_module(SEC_M)
SEC_R = SEC_M.scan_secrets(sys.argv[1])
sys.exit(0 if [SEC_F["kind"] for SEC_F in SEC_R["certain"]] == ["PGP private key block"] else 1)
PY
python3 - "$SEC_DIR/u6" "$SEC_CORE" <<'PY' && ok "secrets: scan finds an rk_live_ key" || bad "secrets: scan finds an rk_live_ key"
import importlib.util, sys
SEC_SPEC = importlib.util.spec_from_file_location("mc", sys.argv[2])
SEC_M = importlib.util.module_from_spec(SEC_SPEC); SEC_SPEC.loader.exec_module(SEC_M)
SEC_R = SEC_M.scan_secrets(sys.argv[1])
sys.exit(0 if [SEC_F["kind"] for SEC_F in SEC_R["certain"]] == ["Stripe live key"] else 1)
PY
python3 - "$SEC_DIR/u7" "$SEC_CORE" <<'PY' && ok "secrets: scan finds an unquoted aws_secret_access_key" || bad "secrets: scan finds an unquoted aws_secret_access_key"
import importlib.util, sys
SEC_SPEC = importlib.util.spec_from_file_location("mc", sys.argv[2])
SEC_M = importlib.util.module_from_spec(SEC_SPEC); SEC_SPEC.loader.exec_module(SEC_M)
SEC_R = SEC_M.scan_secrets(sys.argv[1])
sys.exit(0 if [SEC_F["kind"] for SEC_F in SEC_R["certain"]] == ["AWS secret access key"] else 1)
PY
python3 - "$SEC_DIR/u8" "$SEC_CORE" <<'PY' && ok "secrets: near-miss values are not certain findings" || bad "secrets: near-miss values are not certain findings"
import importlib.util, sys
SEC_SPEC = importlib.util.spec_from_file_location("mc", sys.argv[2])
SEC_M = importlib.util.module_from_spec(SEC_SPEC); SEC_SPEC.loader.exec_module(SEC_M)
SEC_R = SEC_M.scan_secrets(sys.argv[1])
sys.exit(0 if [SEC_F["kind"] for SEC_F in SEC_R["certain"]] == ["Anthropic API key"] else 1)
PY
python3 - "$SEC_U9" "$SEC_CORE" <<'PY' && ok "secrets: muse_core.py's own pattern table is not a finding" || bad "secrets: muse_core.py's own pattern table is not a finding"
import importlib.util, sys
SEC_SPEC = importlib.util.spec_from_file_location("mc", sys.argv[2])
SEC_M = importlib.util.module_from_spec(SEC_SPEC); SEC_SPEC.loader.exec_module(SEC_M)
SEC_R = SEC_M.scan_secrets(sys.argv[1])
sys.exit(0 if SEC_R["files_scanned"] == 1 and SEC_R["certain"] == [] else 1)
PY
python3 - "$SEC_R_PAT" "$SEC_CORE" "$SEC_DIR/vals.json" <<'PY' && ok "secrets: findings never carry the matched value" || bad "secrets: findings never carry the matched value"
import importlib.util, json, sys
SEC_SPEC = importlib.util.spec_from_file_location("mc", sys.argv[2])
SEC_M = importlib.util.module_from_spec(SEC_SPEC); SEC_SPEC.loader.exec_module(SEC_M)
SEC_R = SEC_M.scan_secrets(sys.argv[1])
SEC_VALS = json.load(open(sys.argv[3]))
SEC_BLOB = json.dumps(SEC_R)
SEC_LEAKED = [SEC_V for SEC_V in SEC_VALS.values() if SEC_V in SEC_BLOB]
sys.exit(0 if not SEC_LEAKED and SEC_R["certain"] else 1)
PY

# D1: tracked key under env/
SEC_N=$((SEC_N+1)); SEC_OUT="$(sec_task "$SEC_R_ENV" sec-tenv "$SEC_N")"
echo "$SEC_OUT" | python3 -c "import json,sys; SEC_D=json.load(sys.stdin); sys.exit(0 if SEC_D.get('status')=='refused' and SEC_D.get('secrets') else 1)" 2>/dev/null \
  && [ ! -s "$SEC_DIR/stub-$SEC_N.log" ] \
  && ok "secrets: task refuses a tracked key under env/ and never starts the worker" \
  || bad "secrets: task refuses a tracked key under env/ and never starts the worker" "$SEC_OUT"
SEC_N=$((SEC_N+1)); sec_fleet "$SEC_R_ENV" "$SEC_DIR/tasks.json" "$SEC_N"
[ "$SEC_RC" -ne 0 ] && python3 - "$SEC_DIR/fout-$SEC_N/report.json" <<'PY' 2>/dev/null && [ ! -s "$SEC_DIR/stub-$SEC_N.log" ] \
  && ok "secrets: fleet refuses a tracked key under env/ and never starts the worker" \
  || bad "secrets: fleet refuses a tracked key under env/ and never starts the worker"
import json, sys
SEC_D = json.load(open(sys.argv[1]))
SEC_T = SEC_D["tasks"][0]
sys.exit(0 if SEC_T.get("status") == "refused" and SEC_T.get("secrets") else 1)
PY
SEC_N=$((SEC_N+1)); sec_ask "$SEC_R_ENV" "$SEC_N" --write
[ "$SEC_RC" -eq 1 ] && grep -q "muse_ask: refused" "$SEC_DIR/ask-err-$SEC_N.txt" 2>/dev/null && [ ! -s "$SEC_DIR/stub-$SEC_N.log" ] \
  && ok "secrets: ask refuses a tracked key under env/ and never starts the worker" \
  || bad "secrets: ask refuses a tracked key under env/ and never starts the worker" "rc=$SEC_RC $(cat "$SEC_DIR/ask-err-$SEC_N.txt" 2>/dev/null | head -2)"

# D2: tracked key under build/
SEC_N=$((SEC_N+1)); SEC_OUT="$(sec_task "$SEC_R_BUILD" sec-tbuild "$SEC_N")"
echo "$SEC_OUT" | python3 -c "import json,sys; SEC_D=json.load(sys.stdin); sys.exit(0 if SEC_D.get('status')=='refused' and SEC_D.get('secrets') else 1)" 2>/dev/null \
  && [ ! -s "$SEC_DIR/stub-$SEC_N.log" ] \
  && ok "secrets: task refuses a tracked key under build/ and never starts the worker" \
  || bad "secrets: task refuses a tracked key under build/ and never starts the worker" "$SEC_OUT"
SEC_N=$((SEC_N+1)); sec_fleet "$SEC_R_BUILD" "$SEC_DIR/tasks.json" "$SEC_N"
[ "$SEC_RC" -ne 0 ] && python3 - "$SEC_DIR/fout-$SEC_N/report.json" <<'PY' 2>/dev/null && [ ! -s "$SEC_DIR/stub-$SEC_N.log" ] \
  && ok "secrets: fleet refuses a tracked key under build/ and never starts the worker" \
  || bad "secrets: fleet refuses a tracked key under build/ and never starts the worker"
import json, sys
SEC_D = json.load(open(sys.argv[1]))
SEC_T = SEC_D["tasks"][0]
sys.exit(0 if SEC_T.get("status") == "refused" and SEC_T.get("secrets") else 1)
PY
SEC_N=$((SEC_N+1)); sec_ask "$SEC_R_BUILD" "$SEC_N" --write
[ "$SEC_RC" -eq 1 ] && grep -q "muse_ask: refused" "$SEC_DIR/ask-err-$SEC_N.txt" 2>/dev/null && [ ! -s "$SEC_DIR/stub-$SEC_N.log" ] \
  && ok "secrets: ask refuses a tracked key under build/ and never starts the worker" \
  || bad "secrets: ask refuses a tracked key under build/ and never starts the worker" "rc=$SEC_RC $(cat "$SEC_DIR/ask-err-$SEC_N.txt" 2>/dev/null | head -2)"

# D3: key reached through a link
if [ "$SEC_CAN_LINK" = 1 ]; then
SEC_N=$((SEC_N+1)); SEC_OUT="$(sec_task "$SEC_R_LINK" sec-tlink "$SEC_N" --link secrets)"
echo "$SEC_OUT" | python3 -c "import json,sys; SEC_D=json.load(sys.stdin); sys.exit(0 if SEC_D.get('status')=='refused' and SEC_D.get('secrets') else 1)" 2>/dev/null \
  && [ ! -s "$SEC_DIR/stub-$SEC_N.log" ] \
  && ok "secrets: task refuses a key reached through a link and never starts the worker" \
  || bad "secrets: task refuses a key reached through a link and never starts the worker" "$SEC_OUT"
SEC_N=$((SEC_N+1)); sec_fleet "$SEC_R_LINK" "$SEC_DIR/tasks.json" "$SEC_N" --link secrets
[ "$SEC_RC" -ne 0 ] && python3 - "$SEC_DIR/fout-$SEC_N/report.json" <<'PY' 2>/dev/null && [ ! -s "$SEC_DIR/stub-$SEC_N.log" ] \
  && ok "secrets: fleet refuses a key reached through a link and never starts the worker" \
  || bad "secrets: fleet refuses a key reached through a link and never starts the worker"
import json, sys
SEC_D = json.load(open(sys.argv[1]))
SEC_T = SEC_D["tasks"][0]
sys.exit(0 if SEC_T.get("status") == "refused" and SEC_T.get("secrets") else 1)
PY
SEC_N=$((SEC_N+1)); sec_ask "$SEC_R_LINK" "$SEC_N" --write
[ "$SEC_RC" -eq 1 ] && grep -q "muse_ask: refused" "$SEC_DIR/ask-err-$SEC_N.txt" 2>/dev/null && [ ! -s "$SEC_DIR/stub-$SEC_N.log" ] \
  && ok "secrets: ask refuses a key reached through a link and never starts the worker" \
  || bad "secrets: ask refuses a key reached through a link and never starts the worker" "rc=$SEC_RC $(cat "$SEC_DIR/ask-err-$SEC_N.txt" 2>/dev/null | head -2)"
else
ok "secrets: task refuses a key reached through a link and never starts the worker (host cannot create symlinks; nothing can be linked)"
ok "secrets: fleet refuses a key reached through a link and never starts the worker (host cannot create symlinks; nothing can be linked)"
ok "secrets: ask refuses a key reached through a link and never starts the worker (host cannot create symlinks; nothing can be linked)"
fi

# D4: .env dotfile (seeded for task/fleet, in cwd for ask)
SEC_N=$((SEC_N+1)); SEC_OUT="$(sec_task "$SEC_R_DOT" sec-tdot "$SEC_N" --seed .env)"
echo "$SEC_OUT" | python3 -c "import json,sys; SEC_D=json.load(sys.stdin); sys.exit(0 if SEC_D.get('status')=='refused' and SEC_D.get('secrets') else 1)" 2>/dev/null \
  && [ ! -s "$SEC_DIR/stub-$SEC_N.log" ] \
  && ok "secrets: task refuses a .env dotfile and never starts the worker" \
  || bad "secrets: task refuses a .env dotfile and never starts the worker" "$SEC_OUT"
SEC_N=$((SEC_N+1)); sec_fleet "$SEC_R_DOT" "$SEC_DIR/tasks.json" "$SEC_N" --seed .env
[ "$SEC_RC" -ne 0 ] && python3 - "$SEC_DIR/fout-$SEC_N/report.json" <<'PY' 2>/dev/null && [ ! -s "$SEC_DIR/stub-$SEC_N.log" ] \
  && ok "secrets: fleet refuses a .env dotfile and never starts the worker" \
  || bad "secrets: fleet refuses a .env dotfile and never starts the worker"
import json, sys
SEC_D = json.load(open(sys.argv[1]))
SEC_T = SEC_D["tasks"][0]
sys.exit(0 if SEC_T.get("status") == "refused" and SEC_T.get("secrets") else 1)
PY
SEC_N=$((SEC_N+1)); sec_ask "$SEC_R_DOT" "$SEC_N" --write
[ "$SEC_RC" -eq 1 ] && grep -q "muse_ask: refused" "$SEC_DIR/ask-err-$SEC_N.txt" 2>/dev/null && [ ! -s "$SEC_DIR/stub-$SEC_N.log" ] \
  && ok "secrets: ask refuses a .env dotfile and never starts the worker" \
  || bad "secrets: ask refuses a .env dotfile and never starts the worker" "rc=$SEC_RC $(cat "$SEC_DIR/ask-err-$SEC_N.txt" 2>/dev/null | head -2)"

# D5: every widened pattern, all seven files named
SEC_N=$((SEC_N+1)); SEC_OUT="$(sec_task "$SEC_R_PAT" sec-tpat "$SEC_N")"
echo "$SEC_OUT" | python3 -c "import json,sys; SEC_D=json.load(sys.stdin); SEC_F={SEC_X['file'] for SEC_X in SEC_D.get('secrets',[])}; sys.exit(0 if SEC_D.get('status')=='refused' and all('p%d.txt'%SEC_I in SEC_F for SEC_I in range(1,8)) else 1)" 2>/dev/null \
  && [ ! -s "$SEC_DIR/stub-$SEC_N.log" ] \
  && ok "secrets: task refuses every widened pattern" \
  || bad "secrets: task refuses every widened pattern" "$SEC_OUT"
SEC_N=$((SEC_N+1)); sec_fleet "$SEC_R_PAT" "$SEC_DIR/tasks.json" "$SEC_N"
[ "$SEC_RC" -ne 0 ] && python3 - "$SEC_DIR/fout-$SEC_N/report.json" <<'PY' 2>/dev/null && [ ! -s "$SEC_DIR/stub-$SEC_N.log" ] \
  && ok "secrets: fleet refuses every widened pattern" \
  || bad "secrets: fleet refuses every widened pattern"
import json, sys
SEC_D = json.load(open(sys.argv[1]))
SEC_T = SEC_D["tasks"][0]
SEC_F = {SEC_X["file"] for SEC_X in SEC_T.get("secrets", [])}
sys.exit(0 if SEC_T.get("status") == "refused" and all("p%d.txt" % SEC_I in SEC_F for SEC_I in range(1, 8)) else 1)
PY
SEC_N=$((SEC_N+1)); sec_ask "$SEC_R_PAT" "$SEC_N" --write
SEC_PAT_OK=1
for SEC_I in 1 2 3 4 5 6 7; do grep -q "p$SEC_I.txt" "$SEC_DIR/ask-err-$SEC_N.txt" 2>/dev/null || SEC_PAT_OK=0; done
[ "$SEC_RC" -eq 1 ] && grep -q "muse_ask: refused" "$SEC_DIR/ask-err-$SEC_N.txt" 2>/dev/null && [ "$SEC_PAT_OK" -eq 1 ] && [ ! -s "$SEC_DIR/stub-$SEC_N.log" ] \
  && ok "secrets: ask refuses every widened pattern" \
  || bad "secrets: ask refuses every widened pattern" "rc=$SEC_RC $(cat "$SEC_DIR/ask-err-$SEC_N.txt" 2>/dev/null | head -9)"

# D6: --allow-secrets starts the worker (the paired control for D1-D5 absence)
SEC_N=$((SEC_N+1)); SEC_OUT="$(sec_task "$SEC_R_ENV" sec-tallow "$SEC_N" --allow-secrets)"
echo "$SEC_OUT" | python3 -c "import json,sys; SEC_D=json.load(sys.stdin); sys.exit(0 if SEC_D.get('status')!='refused' else 1)" 2>/dev/null \
  && [ -s "$SEC_DIR/stub-$SEC_N.log" ] \
  && ok "secrets: task --allow-secrets starts the worker" \
  || bad "secrets: task --allow-secrets starts the worker" "$SEC_OUT"
SEC_N=$((SEC_N+1)); sec_fleet "$SEC_R_ENV" "$SEC_DIR/tasks.json" "$SEC_N" --allow-secrets
[ "$SEC_RC" -eq 0 ] && [ -s "$SEC_DIR/stub-$SEC_N.log" ] \
  && ok "secrets: fleet --allow-secrets starts the worker" \
  || bad "secrets: fleet --allow-secrets starts the worker" "rc=$SEC_RC"
SEC_N=$((SEC_N+1)); sec_ask "$SEC_R_ENV" "$SEC_N" --write --allow-secrets
[ "$SEC_RC" -eq 0 ] && [ -s "$SEC_DIR/stub-$SEC_N.log" ] \
  && ok "secrets: ask --allow-secrets starts the worker" \
  || bad "secrets: ask --allow-secrets starts the worker" "rc=$SEC_RC $(cat "$SEC_DIR/ask-err-$SEC_N.txt" 2>/dev/null | head -2)"

# D7: the userConfig opt-out is honoured
SEC_N=$((SEC_N+1)); export SEC_STUB_LOG="$SEC_DIR/stub-$SEC_N.log"; : > "$SEC_STUB_LOG"
SEC_OUT="$(cd "$SEC_R_ENV" && env CLAUDE_PLUGIN_OPTION_REFUSE_ON_SECRETS=false PATH="$SEC_PATH" python3 "$SEC_TASK" run --id sec-tenvoff --repo "$SEC_R_ENV" --out "$SEC_DIR/out-$SEC_N" --worktree-root "$SEC_DIR/wt-$SEC_N" --model stub-model --prompt p 2>/dev/null)"
echo "$SEC_OUT" | python3 -c "import json,sys; SEC_D=json.load(sys.stdin); sys.exit(0 if SEC_D.get('status')!='refused' else 1)" 2>/dev/null \
  && [ -s "$SEC_DIR/stub-$SEC_N.log" ] \
  && ok "secrets: task honours CLAUDE_PLUGIN_OPTION_REFUSE_ON_SECRETS=false" \
  || bad "secrets: task honours CLAUDE_PLUGIN_OPTION_REFUSE_ON_SECRETS=false" "$SEC_OUT"
SEC_N=$((SEC_N+1)); export SEC_STUB_LOG="$SEC_DIR/stub-$SEC_N.log"; : > "$SEC_STUB_LOG"
env CLAUDE_PLUGIN_OPTION_REFUSE_ON_SECRETS=false PATH="$SEC_PATH" python3 "$SEC_FLEET" --tasks "$SEC_DIR/tasks.json" --repo "$SEC_R_ENV" --out "$SEC_DIR/fout-$SEC_N" --worktree-root "$SEC_DIR/fwt-$SEC_N" --model stub-model >/dev/null 2>&1
SEC_RC=$?
[ "$SEC_RC" -eq 0 ] && [ -s "$SEC_DIR/stub-$SEC_N.log" ] \
  && ok "secrets: fleet honours CLAUDE_PLUGIN_OPTION_REFUSE_ON_SECRETS=false" \
  || bad "secrets: fleet honours CLAUDE_PLUGIN_OPTION_REFUSE_ON_SECRETS=false" "rc=$SEC_RC"
SEC_N=$((SEC_N+1)); export SEC_STUB_LOG="$SEC_DIR/stub-$SEC_N.log"; : > "$SEC_STUB_LOG"
(cd "$SEC_R_ENV" && env CLAUDE_PLUGIN_OPTION_REFUSE_ON_SECRETS=false PATH="$SEC_PATH" CLAUDE_PLUGIN_DATA="$SEC_DIR/askdata" bash "$SEC_ASK" --model stub-model --write "q" >"$SEC_DIR/ask-out-$SEC_N.txt" 2>"$SEC_DIR/ask-err-$SEC_N.txt")
SEC_RC=$?
[ "$SEC_RC" -eq 0 ] && [ -s "$SEC_DIR/stub-$SEC_N.log" ] \
  && ok "secrets: ask honours CLAUDE_PLUGIN_OPTION_REFUSE_ON_SECRETS=false" \
  || bad "secrets: ask honours CLAUDE_PLUGIN_OPTION_REFUSE_ON_SECRETS=false" "rc=$SEC_RC $(cat "$SEC_DIR/ask-err-$SEC_N.txt" 2>/dev/null | head -2)"

# D8: --no-secret-scan starts the worker
SEC_N=$((SEC_N+1)); SEC_OUT="$(sec_task "$SEC_R_ENV" sec-tnoscan "$SEC_N" --no-secret-scan)"
echo "$SEC_OUT" | python3 -c "import json,sys; SEC_D=json.load(sys.stdin); sys.exit(0 if SEC_D.get('status')!='refused' else 1)" 2>/dev/null \
  && [ -s "$SEC_DIR/stub-$SEC_N.log" ] \
  && ok "secrets: task --no-secret-scan starts the worker" \
  || bad "secrets: task --no-secret-scan starts the worker" "$SEC_OUT"
SEC_N=$((SEC_N+1)); sec_fleet "$SEC_R_ENV" "$SEC_DIR/tasks.json" "$SEC_N" --no-secret-scan
[ "$SEC_RC" -eq 0 ] && [ -s "$SEC_DIR/stub-$SEC_N.log" ] \
  && ok "secrets: fleet --no-secret-scan starts the worker" \
  || bad "secrets: fleet --no-secret-scan starts the worker" "rc=$SEC_RC"
SEC_N=$((SEC_N+1)); sec_ask "$SEC_R_ENV" "$SEC_N" --write --no-secret-scan
[ "$SEC_RC" -eq 0 ] && [ -s "$SEC_DIR/stub-$SEC_N.log" ] \
  && ok "secrets: ask --no-secret-scan starts the worker" \
  || bad "secrets: ask --no-secret-scan starts the worker" "rc=$SEC_RC $(cat "$SEC_DIR/ask-err-$SEC_N.txt" 2>/dev/null | head -2)"

# E1/E2: the worker starts with the task worktree as its cwd
SEC_N=$((SEC_N+1)); SEC_OUT="$(sec_task "$SEC_R_ENV" sec-tcwd "$SEC_N" --allow-secrets)"
python3 - "$SEC_DIR/out-$SEC_N/sec-tcwd/state.json" "$SEC_DIR/stub-$SEC_N.log" <<'PY' 2>/dev/null \
  && ok "secrets: task starts the worker with the task worktree as its cwd" \
  || bad "secrets: task starts the worker with the task worktree as its cwd"
import json, os, sys
SEC_ST = json.load(open(sys.argv[1]))
SEC_WT = SEC_ST["worktree"]
SEC_LINES = [SEC_L.strip() for SEC_L in open(sys.argv[2], "rb").read().decode("utf-8", "replace").splitlines() if SEC_L.strip()]
sys.exit(0 if SEC_LINES and os.path.normcase(os.path.realpath(SEC_LINES[-1])) == os.path.normcase(os.path.realpath(SEC_WT)) else 1)
PY
SEC_N=$((SEC_N+1)); sec_fleet "$SEC_R_ENV" "$SEC_DIR/tasks.json" "$SEC_N" --allow-secrets
python3 - "$SEC_DIR/fout-$SEC_N/report.json" "$SEC_DIR/stub-$SEC_N.log" <<'PY' 2>/dev/null \
  && ok "secrets: fleet starts the worker with the task worktree as its cwd" \
  || bad "secrets: fleet starts the worker with the task worktree as its cwd"
import json, os, sys
SEC_REP = json.load(open(sys.argv[1]))
SEC_WT = SEC_REP["tasks"][0]["worktree"]
SEC_LINES = [SEC_L.strip() for SEC_L in open(sys.argv[2], "rb").read().decode("utf-8", "replace").splitlines() if SEC_L.strip()]
sys.exit(0 if SEC_LINES and os.path.normcase(os.path.realpath(SEC_LINES[-1])) == os.path.normcase(os.path.realpath(SEC_WT)) else 1)
PY

# E3: a gitignored file that is neither seeded nor linked stays out of the worktree
SEC_N=$((SEC_N+1)); SEC_OUT="$(sec_task "$SEC_R_DOT" sec-tnoseed "$SEC_N")"
[ -s "$SEC_R_DOT/.env" ] \
  && echo "$SEC_OUT" | python3 -c "import json,sys; SEC_D=json.load(sys.stdin); sys.exit(0 if SEC_D.get('status')!='refused' else 1)" 2>/dev/null \
  && [ -s "$SEC_DIR/stub-$SEC_N.log" ] \
  && ok "secrets: task does not refuse a gitignored file it neither seeds nor links" \
  || bad "secrets: task does not refuse a gitignored file it neither seeds nor links" "$SEC_OUT"

# E4: ask scans its cwd, so an ignored file there still refuses
SEC_N=$((SEC_N+1)); sec_ask "$SEC_R_IGN" "$SEC_N" --write
[ "$SEC_RC" -eq 1 ] && grep -q "muse_ask: refused" "$SEC_DIR/ask-err-$SEC_N.txt" 2>/dev/null \
  && ok "secrets: ask --write refuses an ignored file in its cwd" \
  || bad "secrets: ask --write refuses an ignored file in its cwd" "rc=$SEC_RC $(cat "$SEC_DIR/ask-err-$SEC_N.txt" 2>/dev/null | head -2)"

unset -f sec_mkrepo sec_commit sec_task sec_fleet sec_ask 2>/dev/null || true
if [ "$SEC_STANDALONE" = 1 ]; then
  printf 'secrets: %d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]; exit $?
fi
