#!/usr/bin/env bash
# Prose command lines survive an unsubstituted ${user_config.KEY}. Every placeholder
# on a shell command line is single-quoted, so an unset key reaches the muse-*
# scripts as literal text (which they treat as "not given") instead of killing the
# shell with `bad substitution`. Sourced by validate.sh; also runnable alone with
# `bash tests/test_quoting.sh`.
Q_STANDALONE=0
if ! declare -F ok >/dev/null 2>&1; then
  Q_STANDALONE=1
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
  LAB="$(native_path "$(mktemp -d "${TMPDIR:-/tmp}/muse-q.XXXXXX")")"
  if [ -z "${LAB:-}" ] || [ ! -d "$LAB" ]; then echo "no scratch dir" >&2; exit 1; fi
  # Standalone only: an early exit must not leave the lab behind under TMPDIR.
  trap 'rm -rf "$LAB"' EXIT
  PASS=0; FAIL=0; SKIP=0
  ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
  bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && echo "        $2"; }
  skip() { local n="$1"; shift; SKIP=$((SKIP+n)); printf '  SKIP  %s\n' "$*"; }
fi

if [ -z "${LAB:-}" ] || [ ! -d "${LAB:-}" ]; then
  echo "quoting: refusing to run without a scratch dir" >&2
  if [ "$Q_STANDALONE" = 1 ]; then exit 1; else return 1; fi
fi

Q_TASK="$SKILL/scripts/muse_task.py"
Q_FLEET="$SKILL/scripts/muse_fleet.py"
Q_ASK="$SKILL/scripts/muse_ask.sh"
Q_DOC="$SKILL/scripts/muse_doctor.py"
Q_DIR="$LAB/v_quoting"
rm -rf "$Q_DIR"; mkdir -p "$Q_DIR/bin" "$Q_DIR/data" "$Q_DIR/askdata" "$Q_DIR/logs"
Q_DATA="$Q_DIR/data"
Q_CAT="$Q_DIR/nocat/*.json"

# A muse that logs its argv and immediately completes. A non-empty log proves the
# worker started; its content proves which flags it was started with.
cat > "$Q_DIR/bin/muse" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "muse 1.3.0"; exit 0; fi
printf '%s\n' "$@" >> "$Q_STUB_LOG"
printf '{"payload":{"kind":"run_terminal","terminal":"completed","text":"ok"}}\n'
STUB
chmod +x "$Q_DIR/bin/muse"
# Native python on Windows cannot execute the extensionless bash stub: shutil.which
# honours PATHEXT (so it needs muse.cmd) and CreateProcess never consults PATHEXT at
# all, so even the .cmd is unreachable under the bare name unless run_muse resolves it
# via which() first. Same shape as validate.sh's make_muse_stub.
if command -v cygpath >/dev/null 2>&1; then
  printf '@echo off\r\n"%s" "%s" %%*\r\nexit /b %%ERRORLEVEL%%\r\n' \
    "$(native_path "$(command -v bash)")" \
    "$(native_path "$Q_DIR/bin/muse")" > "$Q_DIR/bin/muse.cmd"
fi

q_mkrepo() {  # q_mkrepo <dir> -- calc.py and tasks.json tracked, clean tree
  rm -rf "$1"; mkdir -p "$1"; git init -q -b main "$1"
  printf 'def add(a,b):\n    return a+b\n' > "$1/calc.py"
  printf '[{"id":"a","prompt":"p"}]' > "$1/tasks.json"
  git -C "$1" add -A
  git -C "$1" -c user.email=t@l -c user.name=t commit -qm init
}
q_mkrepo "$Q_DIR/qrepo"

# zsh is a sub-assertion inside checks 1-4, never a check of its own, so the
# number of checks is the same on every platform. On Windows there is no zsh:
# leave it out silently — skip() counts as FAIL under CI and would break the
# Windows leg. Elsewhere an absent zsh fails check 1 under CI, else a note.
Q_IS_WINDOWS=0
if command -v cygpath >/dev/null 2>&1; then
  Q_IS_WINDOWS=1
else
  case "$(uname -s 2>/dev/null || printf '')" in MINGW*|MSYS*|CYGWIN*) Q_IS_WINDOWS=1;; esac
fi
Q_RUN_ZSH=0
if [ "$Q_IS_WINDOWS" = 0 ] && command -v zsh >/dev/null 2>&1; then Q_RUN_ZSH=1; fi
Q_ZSH_REQUIRED=0
if [ "$Q_IS_WINDOWS" = 0 ] && [ "${CI:-}" = "true" ]; then Q_ZSH_REQUIRED=1; fi

export Q_SKILL="$SKILL" Q_DIR Q_DATA Q_CAT
export Q_BIN_PATH="$(shell_path "$Q_DIR/bin"):$(shell_path "$SKILL/bin"):$PATH"
# Native Windows python resolves a bare "bash" to the WSL launcher, not Git
# Bash, so every Python subprocess call below uses this absolute path as
# argv[0] — the same way the stub's .cmd wrapper already finds Git Bash.
export Q_BASH="$(native_path "$(command -v bash)")"
Q_ZSH=""
if command -v zsh >/dev/null 2>&1; then Q_ZSH="$(command -v zsh)"; fi
export Q_ZSH
# Native-format dirs for the child PATH Python builds on Windows (a
# colon-joined POSIX list is not reliably understood when native python.exe
# launches Git Bash, which expects Windows-format semicolon-separated PATH).
export Q_STUB_NATIVE="$(native_path "$Q_DIR/bin")"
export Q_BIN_NATIVE="$(native_path "$SKILL/bin")"
export Q_RUN_ZSH Q_ZSH_REQUIRED

# Extraction lives in Python (paths with / or & are not a sed-escaping problem):
# fenced blocks in agents/commands/skills/SKILL.md/references are folded on
# backslash continuations, and every logical line holding ${user_config.} is
# either a muse-* shell command or an unclassified failure. A fenced block whose
# first line starts with Workflow( is JS tool-call args, not shell.
python3 - "$SKILL" "$(native_path "$Q_DIR/qrepo")" "$Q_DIR" <<'PY'
import json, pathlib, re, sys
root, repo, qdir = sys.argv[1], sys.argv[2], sys.argv[3]
SHELL_CMDS = ("muse-task", "muse-fleet", "muse-ask", "muse-doctor")
files = (sorted((pathlib.Path(root) / "agents").glob("*.md"))
         + sorted((pathlib.Path(root) / "commands").glob("*.md"))
         + sorted((pathlib.Path(root) / "skills").glob("*/SKILL.md"))
         + sorted((pathlib.Path(root) / "references").glob("*.md")))
entries, unclassified, unfilled = [], [], []
counts = {"task": 0, "fleet": 0, "ask": 0, "doctor": 0}
n = 0
for path in files:
    text = path.read_text(encoding="utf-8").replace("\r\n", "\n")
    if not text.strip():
        continue
    inside, block_first, buf, start = False, None, None, 0
    logical = []
    for lineno, line in enumerate(text.splitlines(), 1):
        if line.strip().startswith("```"):
            inside = not inside
            if inside:
                block_first, buf, start = None, None, 0
            else:
                if buf is not None:
                    logical.append((start, block_first, buf))
                block_first, buf = None, None
            continue
        if not inside:
            continue
        stripped = line.rstrip()
        if block_first is None and stripped.strip():
            block_first = stripped.strip()
        if buf is None:
            buf, start = stripped, lineno
        else:
            buf += " " + stripped.lstrip()
        if buf.endswith("\\"):
            buf = buf[:-1].rstrip()
        else:
            logical.append((start, block_first, buf))
            buf = None
    if inside and buf is not None:
        logical.append((start, block_first, buf))
    rel = path.relative_to(root).as_posix()
    for lineno, firstline, line in logical:
        if "${user_config." not in line:
            continue
        if firstline is not None and firstline.startswith("Workflow("):
            continue
        tok = line.strip().split(None, 1)[0] if line.strip() else ""
        if tok not in SHELL_CMDS:
            unclassified.append("%s:%d" % (rel, lineno))
            continue
        n += 1
        uid, out = "q%d" % n, "%s/out-%d" % (qdir, n)
        cmd = line.replace("<brief>", "p").replace("<prompt>", "p")
        cmd = cmd.replace("[--repo <path>]", "--repo %s" % repo)
        cmd = cmd.replace("[--json]", "--json").replace("[--write]", "--write")
        for drop in ("[--scan]", "[--schema <file>]", "[--continue | --session <id>]"):
            cmd = cmd.replace(drop, "")
        cmd = cmd.replace("<id>", uid).replace("<out>", out).replace("<repo>", repo)
        cmd = re.sub(r"\s+", " ", cmd).strip()
        if re.search(r"[<>\[\]]", cmd):
            unfilled.append("%s:%d: unfilled slot: %s" % (rel, lineno, cmd))
            continue
        cmd = re.sub(r"--id\s+\S+", "--id " + uid, cmd)
        kind = {"muse-task": "task", "muse-fleet": "fleet",
                "muse-ask": "ask", "muse-doctor": "doctor"}[tok]
        counts[kind] += 1
        out_eff = out
        if "--out" not in cmd.split():
            out_eff = repo + "/.muse-fleet/tasks"
        entries.append({"kind": kind, "file": "%s:%d" % (rel, lineno),
                        "cmd": cmd, "out": out_eff, "id": uid, "repo": repo})
manifest = {"entries": entries, "unclassified": unclassified,
            "unfilled": unfilled, "counts": counts}
with open(qdir + "/cmds.json", "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=1)
print("extracted %d (%s); unclassified=%d unfilled=%d"
      % (len(entries), " ".join("%s=%d" % kv for kv in sorted(counts.items())),
         len(unclassified), len(unfilled)))
PY

# One runner for checks 1 and 2: mode "bare" runs each extracted line as-is
# (placeholders unsubstituted), mode "sub" replaces each ${user_config.KEY} with
# a realistic value while keeping the line's own quoting — a spaced
# worktree_root proves the quoting keeps it in one piece, and breaks the line
# when the quoting is wrong.
q_run_modes() {  # q_run_modes <bare|sub> -- asserts every extracted line
python3 - "$Q_DIR" "$1" <<'PY'
import glob, json, os, re, subprocess, sys
qdir, mode = sys.argv[1], sys.argv[2]
man = json.load(open(qdir + "/cmds.json", encoding="utf-8"))
fails = []
if man["unclassified"]:
    fails.append("unclassified placeholder line(s): %s" % " ".join(man["unclassified"]))
if man["unfilled"]:
    fails.extend(man["unfilled"])
counts = man["counts"]
for k in ("task", "fleet", "ask", "doctor"):
    if counts.get(k, 0) < 1:
        fails.append("no %s line extracted: the runner is measuring nothing" % k)
if not man["entries"]:
    fails.append("no command lines extracted at all")
SUB = {"default_effort": "medium", "max_rounds": "5", "default_model": "stub-model",
       "worktree_root": qdir + "/wt root", "refuse_on_secrets": "false"}
OPT_KEYS = ("CLAUDE_PLUGIN_OPTION_DEFAULT_EFFORT", "CLAUDE_PLUGIN_OPTION_MAX_ROUNDS",
            "CLAUDE_PLUGIN_OPTION_REFUSE_ON_SECRETS", "CLAUDE_PLUGIN_OPTION_DEFAULT_MODEL",
            "CLAUDE_PLUGIN_OPTION_WORKTREE_ROOT")
SHELL_BIN = {"bash": [os.environ["Q_BASH"], "--norc", "--noprofile", "-c"]}
if os.environ.get("Q_ZSH"):
    SHELL_BIN["zsh"] = [os.environ["Q_ZSH"], "-f", "-c"]


def child_path():
    # A colon-joined POSIX PATH is not reliably understood when a non-MSYS
    # parent (native python.exe) launches Git Bash, which expects a
    # Windows-format, semicolon-separated PATH and converts it itself.
    if os.name == "nt":
        return os.pathsep.join([os.environ["Q_STUB_NATIVE"],
                                os.environ["Q_BIN_NATIVE"],
                                os.environ["PATH"]])
    return os.environ["Q_BIN_PATH"]
want_zsh = os.environ.get("Q_RUN_ZSH") == "1"
if os.environ.get("Q_ZSH_REQUIRED") == "1" and not want_zsh:
    fails.append("zsh is required under CI but was not found")
shells = ("bash", "zsh") if want_zsh else ("bash",)
if not want_zsh and os.environ.get("Q_ZSH_REQUIRED") != "1":
    print("note: no zsh here, bash only")


def base_env(log):
    env = dict(os.environ)
    for k in OPT_KEYS:
        env.pop(k, None)
    env["PATH"] = child_path()
    env["CLAUDE_PLUGIN_ROOT"] = os.environ["Q_SKILL"]
    env["MUSE_DATA_DIR"] = qdir + "/data"
    env["CLAUDE_PLUGIN_DATA"] = qdir + "/askdata"
    env["MUSE_CATALOG_GLOB"] = qdir + "/nocat/*.json"
    env["Q_STUB_LOG"] = log
    return env


def run(cmd, repo, log, shell):
    with open(log, "w", encoding="utf-8"):
        pass
    p = subprocess.run(SHELL_BIN[shell] + [cmd], cwd=repo, env=base_env(log),
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       universal_newlines=True, timeout=300)
    return p


def check_task(e, cmd, repo, tag, exp_rounds, exp_effort, exp_wt=None):
    log = "%s/logs/%s-task.log" % (qdir, tag)
    for shell in shells:
        # `run` refuses over an existing id, so each shell gets its own.
        cid = e["id"] + "-" + shell
        cmd_s = cmd.replace("--id " + e["id"], "--id " + cid, 1)
        sout = e["out"]
        if re.search(r"--out\s", cmd_s):
            sout = e["out"] + "-" + shell
            cmd_s = re.sub(r"--out\s+\S+", "--out " + sout, cmd_s, count=1)
        p = run(cmd_s, repo, log + "." + shell, shell)
        if "bad substitution" in p.stderr:
            fails.append("%s [%s]: bad substitution: %s" % (e["file"], shell, p.stderr.strip()[:200]))
            continue
        if p.returncode != 0:
            fails.append("%s [%s]: rc=%d stderr=%s stdout=%s" % (e["file"], shell, p.returncode, p.stderr.strip()[:200], p.stdout.strip()[:300]))
            continue
        try:
            obj = json.loads(p.stdout.strip())
            assert isinstance(obj, dict)
        except Exception:
            fails.append("%s [%s]: stdout is not one JSON object: %r" % (e["file"], shell, p.stdout[:200]))
            continue
        if obj.get("status") != "completed":
            fails.append("%s [%s]: status=%r" % (e["file"], shell, obj.get("status")))
            continue
        try:
            st = json.load(open("%s/%s/state.json" % (sout, cid), encoding="utf-8"))
        except Exception as ex:
            fails.append("%s [%s]: no state.json: %s" % (e["file"], shell, ex))
            continue
        if st.get("max_rounds") != exp_rounds or st.get("effort") != exp_effort:
            fails.append("%s [%s]: state=%r, want %r/%r"
                         % (e["file"], shell, st, exp_rounds, exp_effort))
        if exp_wt is not None:
            got = os.path.realpath(obj.get("worktree") or "")
            if got != exp_wt and not got.startswith(exp_wt + os.sep):
                fails.append("%s [%s]: worktree %r not under %r" % (e["file"], shell, got, exp_wt))


def check_fleet(e, cmd, repo, tag, exp_effort, exp_wt=None):
    before = set(glob.glob(repo + "/.muse-fleet/*/report.json"))
    log = "%s/logs/%s-fleet.log" % (qdir, tag)
    for shell in shells:
        p = run(cmd, repo, log + "." + shell, shell)
        if "bad substitution" in p.stderr:
            fails.append("%s [%s]: bad substitution: %s" % (e["file"], shell, p.stderr.strip()[:200]))
            continue
        if p.returncode != 0:
            fails.append("%s [%s]: rc=%d stderr=%s stdout=%s" % (e["file"], shell, p.returncode, p.stderr.strip()[:200], p.stdout.strip()[:300]))
            continue
        after = set(glob.glob(repo + "/.muse-fleet/*/report.json")) - before
        if not after:
            fails.append("%s [%s]: no report.json appeared" % (e["file"], shell))
            continue
        rep = json.load(open(sorted(after)[0], encoding="utf-8"))
        if rep.get("effort") != exp_effort:
            fails.append("%s [%s]: report effort=%r, want %r" % (e["file"], shell, rep.get("effort"), exp_effort))
        if exp_wt is not None:
            if os.path.realpath(rep.get("worktree_root") or "") != exp_wt:
                fails.append("%s [%s]: worktree_root=%r, want %r"
                             % (e["file"], shell, rep.get("worktree_root"), exp_wt))
        before |= after


def check_doctor(e, cmd, repo, tag, want_effort, want_rounds):
    log = "%s/logs/%s-doctor.log" % (qdir, tag)
    for shell in shells:
        p = run(cmd, repo, log + "." + shell, shell)
        if "bad substitution" in p.stderr:
            fails.append("%s [%s]: bad substitution: %s" % (e["file"], shell, p.stderr.strip()[:200]))
            continue
        try:
            obj = json.loads(p.stdout.strip())
            checks = obj["checks"]
            assert isinstance(checks, list)
        except Exception:
            fails.append("%s [%s]: stdout is not JSON with a checks list: %r"
                         % (e["file"], shell, p.stdout[:200]))
            continue
        uc = [c for c in checks if isinstance(c, dict) and c.get("name") == "userConfig"]
        if not uc:
            fails.append("%s [%s]: no userConfig check in output" % (e["file"], shell))
            continue
        v = str(uc[0].get("value") or "")
        if want_effort not in v or want_rounds not in v:
            fails.append("%s [%s]: userConfig value %r lacks %r and %r"
                         % (e["file"], shell, v[:200], want_effort, want_rounds))


def check_ask(e, cmd, repo, tag, want_effort):
    log = "%s/logs/%s-ask.log" % (qdir, tag)
    for shell in shells:
        slog = log + "." + shell
        p = run(cmd, repo, slog, shell)
        if "bad substitution" in p.stderr:
            fails.append("%s [%s]: bad substitution: %s" % (e["file"], shell, p.stderr.strip()[:200]))
            continue
        if p.returncode != 0:
            fails.append("%s [%s]: rc=%d stderr=%s stdout=%s" % (e["file"], shell, p.returncode, p.stderr.strip()[:200], p.stdout.strip()[:300]))
            continue
        if p.stdout.strip() != "ok":
            fails.append("%s [%s]: stdout=%r, want 'ok'" % (e["file"], shell, p.stdout[:200]))
            continue
        argv = open(slog, encoding="utf-8").read().replace("\r\n", "\n").split("\n")
        hit = [i for i, a in enumerate(argv) if a == "--reasoning-effort"]
        if not hit or argv[hit[0] + 1] != want_effort:
            fails.append("%s [%s]: stub log lacks --reasoning-effort %s" % (e["file"], shell, want_effort))


for i, e in enumerate(man["entries"]):
    cmd = e["cmd"]
    if mode == "sub":
        cmd = re.sub(r"\$\{user_config\.([A-Za-z0-9_]+)\}",
                     lambda m: SUB[m.group(1)], cmd)
        if "${user_config." in cmd:
            fails.append("%s: unknown placeholder survived substitution" % e["file"])
            continue
    # `run` refuses over an existing id, and bare already used the manifest
    # out/id — so each mode gets its own.
    ee = dict(e)
    if mode == "sub":
        ee["id"] = e["id"] + "s"
        cmd = cmd.replace("--id " + e["id"], "--id " + ee["id"], 1)
        if re.search(r"--out\s", cmd):
            ee["out"] = e["out"] + "-sub"
            cmd = re.sub(r"--out\s+\S+", "--out " + ee["out"], cmd, count=1)
    tag = "%s-%d" % (mode, i)
    if ee["kind"] == "task":
        if mode == "bare":
            check_task(ee, cmd, ee["repo"], tag, 3, "low")
        else:
            check_task(ee, cmd, ee["repo"], tag, 5, "medium",
                       os.path.realpath(SUB["worktree_root"]))
    elif ee["kind"] == "fleet":
        if mode == "bare":
            check_fleet(ee, cmd, ee["repo"], tag, "low")
        else:
            check_fleet(ee, cmd, ee["repo"], tag, "medium",
                        os.path.realpath(SUB["worktree_root"]))
    elif ee["kind"] == "doctor":
        if mode == "bare":
            check_doctor(ee, cmd, ee["repo"], tag, "effort=low (default)", "max_rounds=3 (default)")
        else:
            check_doctor(ee, cmd, ee["repo"], tag, "effort=medium (flag)", "max_rounds=5 (flag)")
    elif ee["kind"] == "ask":
        check_ask(ee, cmd, ee["repo"], tag, "low" if mode == "bare" else "medium")
if fails:
    sys.stdout.write("\n".join(fails) + "\n")
    sys.exit(1)
print("%s: all %d lines ran" % (mode, len(man["entries"])))
PY
}

Q_OUT1="$(q_run_modes bare 2>&1)"; Q_RC1=$?
if [ "$Q_RC1" -eq 0 ]; then
  ok "quoting: every prose command line runs unsubstituted under bash and zsh"
else
  bad "quoting: every prose command line runs unsubstituted under bash and zsh" "$Q_OUT1"
fi

Q_OUT2="$(q_run_modes sub 2>&1)"; Q_RC2=$?
if [ "$Q_RC2" -eq 0 ]; then
  ok "quoting: every prose command line runs with substituted values"
else
  bad "quoting: every prose command line runs with substituted values" "$Q_OUT2"
fi

# 3-4. The workflow's generated run line runs with placeholder args (3) and with
# substituted args (4). The harness embeds the workflow verbatim with
# `export const meta` replaced — the same shape as tests/test_placeholder.sh
# section 7, duplicated here rather than sourced — and mocks agent(): plan
# returns one task, the task: label captures the prompt and stops.
q_run_wf() {  # q_run_wf <tag: 3|4> <plan-effort> <ph|sub>
python3 - "$Q_DIR" "$1" "$2" "$3" <<'PY'
import json, os, re, subprocess, sys
qdir, tag, wfeffort, argmode = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
skill = os.environ["Q_SKILL"]
repo = qdir + "/qrepowf" + tag
out = qdir + "/wfout" + tag
fails = []
OPT_KEYS = ("CLAUDE_PLUGIN_OPTION_DEFAULT_EFFORT", "CLAUDE_PLUGIN_OPTION_MAX_ROUNDS",
            "CLAUDE_PLUGIN_OPTION_REFUSE_ON_SECRETS", "CLAUDE_PLUGIN_OPTION_DEFAULT_MODEL",
            "CLAUDE_PLUGIN_OPTION_WORKTREE_ROOT")


def child_path():
    # Same Windows PATH rule as the checks 1-2 runner: native python.exe
    # launching Git Bash needs Windows-format semicolon-separated PATH.
    if os.name == "nt":
        return os.pathsep.join([os.environ["Q_STUB_NATIVE"],
                                os.environ["Q_BIN_NATIVE"],
                                os.environ["PATH"]])
    return os.environ["Q_BIN_PATH"]


def shell_argv(shell):
    # A bare "bash" resolves to the WSL launcher under native Windows
    # python, so use the absolute Git Bash path (and likewise for zsh).
    if shell == "bash":
        return [os.environ["Q_BASH"], "--norc", "--noprofile", "-c"]
    return [os.environ.get("Q_ZSH") or "zsh", "-f", "-c"]


src = open(skill + "/workflows/muse-supervised-fleet.js", encoding="utf-8").read()
if "export const meta" not in src:
    fails.append("workflow has no `export const meta` to embed")
    src = src
else:
    src = src.replace("export const meta", "const meta", 1)
head = """const RAW = process.env.Q_WF_ARGS_JSON;
if (RAW !== undefined) globalThis.args = JSON.parse(RAW);
const EFF = process.env.Q_WF_EFFORT || 'low';
let TASK_PROMPT = null;
globalThis.phase = () => {};
globalThis.log = () => {};
globalThis.parallel = (fns) => Promise.all(fns.map((f) => f()));
globalThis.agent = async (prompt, opts) => {
  const label = (opts && opts.label) || '';
  if (label === 'plan') {
    return { tasks: [{ id: 't1', prompt: 'p', files: ['calc.py'], check: 'true', effort: EFF }] };
  }
  if (label === 'stage') {
    const m = prompt.match(/```json\\n([\\s\\S]*?)\\n```/);
    if (!m) throw new Error('stage: no json block');
    return { written: JSON.parse(m[1]).map((it) => it.path) };
  }
  if (label.indexOf('task:') === 0) { TASK_PROMPT = prompt; throw new Error('Q_STOP'); }
  if (label === 'census') return { tasks: [] };
  if (label === 'integrate') return { merge_order: [], conflicts: [], manual_checks: [], unproven: [] };
  throw new Error('unexpected agent label: ' + label);
};
async function __body(){
"""
tail = """
}
(async () => {
  try {
    const r = await __body();
    console.log('QRESULT ' + JSON.stringify({ result: r, taskPrompt: TASK_PROMPT, error: null }));
  } catch (e) {
    console.log('QRESULT ' + JSON.stringify({ result: null, taskPrompt: TASK_PROMPT, error: String((e && e.message) || e) }));
  }
})();
"""
harness = qdir + "/wf-q" + tag + ".mjs"
open(harness, "w", encoding="utf-8").write(head + src + tail)
if argmode == "ph":
    args = {"pluginRoot": skill, "repo": repo, "out": out, "stamp": "q1", "job": "x",
            "maxRounds": "${user_config.max_rounds}",
            "defaultEffort": "${user_config.default_effort}",
            "model": "${user_config.default_model}",
            "worktreeRoot": "${user_config.worktree_root}",
            "refuseOnSecrets": "${user_config.refuse_on_secrets}"}
    exp_rounds, exp_effort, exp_wt = 3, "low", None
else:
    args = {"pluginRoot": skill, "repo": repo, "out": out, "stamp": "q1", "job": "x",
            "maxRounds": 5, "defaultEffort": "medium", "model": "stub-model",
            "worktreeRoot": qdir + "/wf wt root", "refuseOnSecrets": False}
    exp_rounds, exp_effort = 5, "medium"
    exp_wt = os.path.realpath(qdir + "/wf wt root")
env = dict(os.environ)
env["Q_WF_ARGS_JSON"] = json.dumps(args)
env["Q_WF_EFFORT"] = wfeffort
p = subprocess.run(["node", harness], env=env, stdout=subprocess.PIPE,
                   stderr=subprocess.PIPE, universal_newlines=True, timeout=300)
res = [ln for ln in p.stdout.replace("\r\n", "\n").split("\n") if ln.startswith("QRESULT ")]
if not res:
    sys.stdout.write("no QRESULT from workflow harness: %s\n" % p.stderr.strip()[:300])
    sys.exit(1)
got = json.loads(res[0][len("QRESULT "):])
if "Q_STOP" not in str(got.get("error") or ""):
    fails.append("workflow never reached Build: %r" % (got.get("error"),))
    tp = ""
else:
    tp = got.get("taskPrompt") or ""
prefix = '"%s/bin/muse-task" run' % skill
line = ""
for ln in tp.split("\n"):
    if ln.strip().startswith(prefix):
        line = ln.strip()
        break
if not line:
    fails.append("no quoted <pluginRoot>/bin/muse-task run line in task prompt")
else:
    m = re.search(r'--prompt-file\s+"([^"]+)"', line)
    if not m:
        fails.append("run line names no --prompt-file: %s" % line[:200])
    else:
        pf = m.group(1)
        parent = os.path.dirname(pf)
        if parent:
            try:
                os.makedirs(parent, exist_ok=True)
            except TypeError:
                if not os.path.isdir(parent):
                    os.makedirs(parent)
        open(pf, "w", encoding="utf-8").write("p\n")
    shells = ("bash", "zsh") if os.environ.get("Q_RUN_ZSH") == "1" else ("bash",)
    if os.environ.get("Q_ZSH_REQUIRED") == "1" and shells == ("bash",):
        fails.append("zsh is required under CI but was not found")
    for shell in shells:
        cid = "t1-" + shell
        sout = out + "-" + shell
        cmd = line.replace("--id t1", "--id " + cid, 1)
        cmd = re.sub(r"--out\s+\S+", "--out " + sout, cmd, count=1)
        runenv = dict(os.environ)
        for k in OPT_KEYS:
            runenv.pop(k, None)
        runenv["PATH"] = child_path()
        runenv["CLAUDE_PLUGIN_ROOT"] = skill
        runenv["MUSE_DATA_DIR"] = qdir + "/data"
        runenv["CLAUDE_PLUGIN_DATA"] = qdir + "/askdata"
        runenv["MUSE_CATALOG_GLOB"] = qdir + "/nocat/*.json"
        slog = "%s/logs/wf-%s-%s.log" % (qdir, tag, shell)
        runenv["Q_STUB_LOG"] = slog
        with open(slog, "w", encoding="utf-8"):
            pass
        r = subprocess.run(shell_argv(shell) + [cmd], cwd=repo, env=runenv,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           universal_newlines=True, timeout=300)
        if "bad substitution" in r.stderr:
            fails.append("[%s]: bad substitution: %s" % (shell, r.stderr.strip()[:200]))
            continue
        if r.returncode != 0:
            fails.append("[%s]: rc=%d stderr=%s stdout=%s" % (shell, r.returncode, r.stderr.strip()[:200], r.stdout.strip()[:300]))
            continue
        try:
            obj = json.loads(r.stdout.strip())
            assert isinstance(obj, dict) and obj.get("status") == "completed"
        except Exception:
            fails.append("[%s]: stdout is not a completed JSON object: %r" % (shell, r.stdout[:200]))
            continue
        try:
            st = json.load(open("%s/%s/state.json" % (sout, cid), encoding="utf-8"))
        except Exception as ex:
            fails.append("[%s]: no state.json: %s" % (shell, ex))
            continue
        if st.get("max_rounds") != exp_rounds or st.get("effort") != exp_effort:
            fails.append("[%s]: state=%r, want %r/%r" % (shell, st, exp_rounds, exp_effort))
        if exp_wt is not None:
            gotwt = os.path.realpath(obj.get("worktree") or "")
            if gotwt != exp_wt and not gotwt.startswith(exp_wt + os.sep):
                fails.append("[%s]: worktree %r not under %r" % (shell, gotwt, exp_wt))
if fails:
    sys.stdout.write("\n".join(fails) + "\n")
    sys.exit(1)
print("workflow run line ran (%s args)" % argmode)
PY
}

if command -v node >/dev/null 2>&1; then
  # Each workflow check gets its own repo: both use stamp q1 and ids t1-*,
  # so sharing one repo refuses the second run over the existing branch.
  q_mkrepo "$Q_DIR/qrepowf3"
  q_mkrepo "$Q_DIR/qrepowf4"
  Q_OUT3="$(q_run_wf 3 low ph 2>&1)"; Q_RC3=$?
  if [ "$Q_RC3" -eq 0 ]; then
    ok "quoting: the workflow's generated run line runs with placeholder args"
  else
    bad "quoting: the workflow's generated run line runs with placeholder args" "$Q_OUT3"
  fi
  Q_OUT4="$(q_run_wf 4 medium sub 2>&1)"; Q_RC4=$?
  if [ "$Q_RC4" -eq 0 ]; then
    ok "quoting: the workflow's generated run line runs with substituted args"
  else
    bad "quoting: the workflow's generated run line runs with substituted args" "$Q_OUT4"
  fi
else
  skip 2 "node not found — workflow quoting checks not run"
fi

# 5. A double-quoted placeholder still fails the shell. The probe takes the REAL
# extracted supervisor run line and converts its single quotes back, so a suite
# that stays green on a broken shell proves nothing.
q_probe() {
python3 - "$Q_DIR" <<'PY'
import json, os, re, subprocess, sys
qdir = sys.argv[1]


def child_path():
    # Same Windows PATH rule as the other runners: native python.exe
    # launching Git Bash needs Windows-format semicolon-separated PATH.
    if os.name == "nt":
        return os.pathsep.join([os.environ["Q_STUB_NATIVE"],
                                os.environ["Q_BIN_NATIVE"],
                                os.environ["PATH"]])
    return os.environ["Q_BIN_PATH"]
man = json.load(open(qdir + "/cmds.json", encoding="utf-8"))
cands = [e for e in man["entries"]
         if e["kind"] == "task" and e["file"].startswith("agents/muse-supervisor.md")]
if not cands:
    print("no supervisor run line extracted: the probe is measuring nothing")
    sys.exit(1)
e = cands[0]
if "'${user_config." not in e["cmd"]:
    print("probe has nothing to convert: placeholders are not single-quoted")
    sys.exit(1)
dq = re.sub(r"'(\$\{user_config\.[A-Za-z0-9_]+\})'", r'"\1"', e["cmd"])
out, tid = qdir + "/out-probe", "qprobe"
dq = re.sub(r"--out\s+\S+", "--out " + out, dq, count=1)
dq = dq.replace("--id " + e["id"], "--id " + tid, 1)
env = dict(os.environ)
for k in ("CLAUDE_PLUGIN_OPTION_DEFAULT_EFFORT", "CLAUDE_PLUGIN_OPTION_MAX_ROUNDS",
          "CLAUDE_PLUGIN_OPTION_REFUSE_ON_SECRETS", "CLAUDE_PLUGIN_OPTION_DEFAULT_MODEL",
          "CLAUDE_PLUGIN_OPTION_WORKTREE_ROOT"):
    env.pop(k, None)
env["PATH"] = child_path()
env["CLAUDE_PLUGIN_ROOT"] = os.environ["Q_SKILL"]
env["MUSE_DATA_DIR"] = qdir + "/data"
env["CLAUDE_PLUGIN_DATA"] = qdir + "/askdata"
env["MUSE_CATALOG_GLOB"] = qdir + "/nocat/*.json"
env["Q_STUB_LOG"] = qdir + "/logs/probe.log"
open(env["Q_STUB_LOG"], "w", encoding="utf-8").close()
p = subprocess.run([os.environ["Q_BASH"], "--norc", "--noprofile", "-c", dq], cwd=e["repo"],
                   env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                   universal_newlines=True, timeout=300)
fails = []
if p.returncode == 0:
    fails.append("double-quoted line exited 0: the shell no longer rejects it")
if "bad substitution" not in p.stderr:
    fails.append("stderr lacks 'bad substitution': %r" % p.stderr.strip()[:200])
try:
    open("%s/%s/state.json" % (out, tid), encoding="utf-8").close()
    fails.append("state.json was written: muse-task started despite the bad shell")
except IOError:
    pass
if fails:
    sys.stdout.write("\n".join(fails) + "\n")
    sys.exit(1)
print("double-quoted probe failed the shell as it must")
PY
}
Q_OUT5="$(q_probe 2>&1)"; Q_RC5=$?
if [ "$Q_RC5" -eq 0 ]; then
  ok "quoting: a double-quoted placeholder still fails the shell (probe)"
else
  bad "quoting: a double-quoted placeholder still fails the shell (probe)" "$Q_OUT5"
fi

# 6. A worktree_root containing a single quote is refused: substituted values are
# pasted inside '...', so a ' in the value would end the quoting early. Called
# as argv (not through a shell string), then the same through the env hook, with
# a quoteless control proving the refusal — and the stub log — measure something.
q_mkrepo "$Q_DIR/qrepo6"
q_refuse_env() {  # q_refuse_env [VAR=val ...] -- extra task args
  local Q_A=()
  while [ "$1" != "--" ]; do Q_A+=("$1"); shift; done
  shift
  env -u CLAUDE_PLUGIN_OPTION_DEFAULT_EFFORT \
      -u CLAUDE_PLUGIN_OPTION_MAX_ROUNDS \
      -u CLAUDE_PLUGIN_OPTION_REFUSE_ON_SECRETS \
      -u CLAUDE_PLUGIN_OPTION_DEFAULT_MODEL \
      -u CLAUDE_PLUGIN_OPTION_WORKTREE_ROOT \
      "${Q_A[@]}" MUSE_DATA_DIR="$Q_DATA" MUSE_CATALOG_GLOB="$Q_CAT" "$@"
}
export Q_STUB_LOG="$Q_DIR/stub-6a.log"; : > "$Q_STUB_LOG"
Q_OUT6A="$(q_refuse_env PATH="$Q_BIN_PATH" -- python3 "$Q_TASK" run --id q6a --repo "$(native_path "$Q_DIR/qrepo6")" --out "$(native_path "$Q_DIR/out-6a")" --model stub-model --prompt p --worktree-root "$Q_DIR/it's" 2>"$Q_DIR/err-6a.txt")"
Q_RC6A=$?
export Q_STUB_LOG="$Q_DIR/stub-6b.log"; : > "$Q_STUB_LOG"
Q_OUT6B="$(q_refuse_env PATH="$Q_BIN_PATH" CLAUDE_PLUGIN_OPTION_WORKTREE_ROOT="$Q_DIR/it's" -- python3 "$Q_TASK" run --id q6b --repo "$(native_path "$Q_DIR/qrepo6")" --out "$(native_path "$Q_DIR/out-6b")" --model stub-model --prompt p 2>"$Q_DIR/err-6b.txt")"
Q_RC6B=$?
export Q_STUB_LOG="$Q_DIR/stub-6c.log"; : > "$Q_STUB_LOG"
Q_OUT6C="$(q_refuse_env PATH="$Q_BIN_PATH" -- python3 "$Q_TASK" run --id q6c --repo "$(native_path "$Q_DIR/qrepo6")" --out "$(native_path "$Q_DIR/out-6c")" --model stub-model --prompt p --worktree-root "$Q_DIR/its" 2>"$Q_DIR/err-6c.txt")"
Q_RC6C=$?
q_verdict6() {
python3 - "$Q_DIR" "$Q_OUT6A" "$Q_RC6A" "$Q_OUT6B" "$Q_RC6B" "$Q_OUT6C" "$Q_RC6C" <<'PY'
import json, os, sys
qdir, outa, rca, outb, rcb, outc, rcc = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7]
fails = []
if not outa.strip() or not outb.strip() or not outc.strip():
    fails.append("a refusal/control JSON was empty: absence asserts prove nothing")
    sys.stdout.write("\n".join(fails) + "\n")
    sys.exit(1)
a, b, c = json.loads(outa), json.loads(outb), json.loads(outc)
if not (int(rca) != 0 and a.get("status") == "refused"
        and "worktree_root" in str(a.get("reason", ""))
        and "single quote" in str(a.get("reason", ""))):
    fails.append("flag refusal wrong: rc=%s out=%s" % (rca, outa.strip()[:200]))
if not (int(rcb) != 0 and b.get("status") == "refused"
        and "worktree_root" in str(b.get("reason", ""))
        and "single quote" in str(b.get("reason", ""))):
    fails.append("env refusal wrong: rc=%s out=%s" % (rcb, outb.strip()[:200]))
if not (int(rcc) == 0 and c.get("status") == "completed"):
    fails.append("control did not complete: rc=%s out=%s" % (rcc, outc.strip()[:200]))
# The refusals must leave the stub unspawned while the control proves the log works.
for log, want_empty in (("stub-6a.log", True), ("stub-6b.log", True), ("stub-6c.log", False)):
    try:
        nonempty = os.path.getsize(qdir + "/" + log) > 0
    except OSError:
        nonempty = False
    if want_empty and nonempty:
        fails.append("%s non-empty: muse was spawned on a refusal" % log)
    if not want_empty and not nonempty:
        fails.append("%s empty: the control never spawned muse, so the log proves nothing" % log)
if fails:
    sys.stdout.write("\n".join(fails) + "\n")
    sys.exit(1)
print("flag, env and control all behaved")
PY
}
Q_OUT6="$(q_verdict6 2>&1)"
if [ "$Q_OUT6" = "flag, env and control all behaved" ]; then
  ok "quoting: muse_core refuses a worktree_root containing a single quote"
else
  bad "quoting: muse_core refuses a worktree_root containing a single quote" "$Q_OUT6 flag rc=$Q_RC6A env rc=$Q_RC6B control rc=$Q_RC6C"
fi

if [ "$Q_STANDALONE" = 1 ]; then
  printf 'quoting: %d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]; exit $?
fi
