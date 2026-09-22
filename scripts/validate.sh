#!/usr/bin/env bash
# Full validation of the muse plugin. Offline checks first (fast, free),
# then live muse runs (slow, costs tokens).
set -uo pipefail

# Self-locate rather than trusting an install path: this script must validate the copy
# it actually ships inside, not whatever other copy happens to be installed.
# On Windows this is Git Bash driving a NATIVE python. Bash translates MSYS paths in
# argv when it invokes a native program, so `python3 /d/a/x.py` works -- but a path
# embedded in a python -c STRING, or exported in an environment variable, gets no
# translation and reaches python as an unresolvable literal. Normalise once, here, so
# every consumer downstream is handed something both shells understand. cygpath -m gives
# "D:/a/repo": native, with forward slashes, so it stays safe to embed either side.
# Windows Python defaults to cp1252 for text I/O, and this repo's own files contain
# UTF-8 (em dashes, box drawing, arrows) -- so every embedded `open(...).read()` below
# would raise UnicodeDecodeError there. PYTHONUTF8=1 puts the interpreter in UTF-8 mode
# for the whole suite, which is one line instead of an encoding= on 23 call sites. The
# SHIPPED scripts do not rely on this: they pass encoding= explicitly, because a user
# runs those directly and will not have this variable set.
export PYTHONUTF8=1

native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# A stub `muse` that BOTH shells can find. shutil.which() on Windows honours PATHEXT, so
# a bare shell script named "muse" is invisible to native python no matter how executable
# bash thinks it is -- which made every preflight-dependent check fail there for a reason
# that had nothing to do with the code under test.
shell_path() {   # inverse of native_path: PATH entries must not contain a drive colon
  if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi
}

# A PATH with python and git but deliberately without muse. "/usr/bin:/bin" is not a
# portable way to express that -- on Windows it omits python entirely, so the doctor
# could not run at all and reported no verdict.
minimal_path() {
  printf '%s:%s' "$(dirname "$(command -v python3)")" "$(dirname "$(command -v git)")"
}

make_muse_stub() {  # make_muse_stub <dir>
  mkdir -p "$1"
  printf '#!/bin/sh\nexit 0\n' > "$1/muse"
  chmod +x "$1/muse"
  if command -v cygpath >/dev/null 2>&1; then
    printf '@echo off\r\nexit /b 0\r\n' > "$1/muse.cmd"
  fi
}

SKILL="$(native_path "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)")"
export PLUGIN_ROOT="$SKILL"
SKILL_MD="$SKILL/skills/muse-fleet/SKILL.md"
FLEET="$SKILL/scripts/muse_fleet.py"
TASK="$SKILL/scripts/muse_task.py"
CORE="$SKILL/scripts/muse_core.py"
# `mktemp -d -t NAME` is BSD-only: GNU coreutils rejects a template with no trailing X's
# and prints nothing, which silently left LAB empty. Every path below is built from it, so
# an empty LAB turned "$LAB/v_dirty" into "/v_dirty" -- and mkrepo starts with `rm -rf`.
LAB="$(native_path "${MUSE_FLEET_LAB:-$(mktemp -d "${TMPDIR:-/tmp}/musefleetlab.XXXXXX")}")"
if [ -z "${LAB:-}" ] || [ ! -d "$LAB" ]; then
  echo "refusing to run: could not create a scratch dir (LAB='${LAB:-}')" >&2
  echo "every test path is built from it, and this script rm -rf's those paths." >&2
  exit 1
fi

# --offline stops before section 4. Sections 1-3 spawn no muse and cost nothing, so they
# can run on every change; the live sections cost real money and several minutes.
OFFLINE=0
[[ "${1:-}" == "--offline" ]] && OFFLINE=1
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ -n "${2:-}" ] && echo "        $2"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

mkrepo() {  # mkrepo <path>
  rm -rf "$1"; mkdir -p "$1"; git init -q -b main "$1"
  printf 'def add(a,b):\n    return a+b\n' > "$1/calc.py"
  git -C "$1" add -A
  git -C "$1" -c user.email=t@l -c user.name=t commit -qm init
}

# ---------------------------------------------------------------- 1. static
head_ "1. Static checks"
python3 -m py_compile "$FLEET" && ok "muse_fleet.py compiles" || bad "compile"
python3 -m py_compile "$CORE" && ok "muse_core.py compiles" || bad "core compile"
python3 -m py_compile "$TASK" && ok "muse_task.py compiles" || bad "task compile"
for c in run revise verify show finish cleanup; do
  python3 "$TASK" "$c" --help >/dev/null 2>&1 \
    && ok "muse_task.py $c subcommand parses" || bad "muse_task $c"
done
# The two paths must share one harvest implementation, or a patch produced through the
# workflow differs from the same patch produced through the CLI.
python3 -c "
import sys
t=open('$TASK').read(); f=open('$FLEET').read()
sys.exit(0 if 'core.harvest(' in t and 'core.harvest(' in f else 1)" \
  && ok "both paths harvest through muse_core" || bad "harvest logic has forked"
python3 -c "import json;json.load(open('$SKILL/assets/result-schema.json'))" \
  && ok "result-schema.json is valid JSON" || bad "schema json"
python3 - <<PY && ok "schema satisfies Meta required-all rule" || bad "schema required-all"
import json,sys
s=json.load(open("$SKILL/assets/result-schema.json"))
sys.exit(0 if not set(s["properties"])-set(s["required"]) else 1)
PY
python3 -c "
import re,sys
t=open('$SKILL_MD').read()
assert t.startswith('---'), 'no frontmatter'
fm=t.split('---')[1]
assert 'name:' in fm and 'description:' in fm
sys.exit(0)" && ok "SKILL.md frontmatter well-formed" || bad "frontmatter"
bash -n "$SKILL/scripts/use_latest_contributor.sh" && ok "use_latest_contributor.sh parses" || bad "bash syntax"
bash -n "$SKILL/scripts/muse_ask.sh" && ok "muse_ask.sh parses" || bad "muse_ask syntax"
for f in routing.md workflow.md muse-cli.md field-notes.md; do
  [ -s "$SKILL/references/$f" ] && ok "references/$f present" || bad "missing references/$f"
done
grep -q 'references/routing.md' "$SKILL_MD" && ok "SKILL.md points at routing.md" || bad "routing.md unreferenced"

# Every command registers as a skill and can fire on its description, not only when
# typed -- commands/ and skills/ are loaded identically, which is the opposite of the
# premise commands/ was chosen on. There is deliberately ONE auto-triggering surface,
# whose description was tightened with exclusions; seven more competing for the same
# prompts undermines it, and /muse:cleanup firing on an inference removes worktrees.
python3 - <<'PY' && ok "only the fleet skill auto-triggers; every command is opt-in" || bad "a command can fire without being typed"
import json, os, pathlib, re, sys
ROOT = pathlib.Path(os.environ["PLUGIN_ROOT"])
problems = []
for f in sorted((ROOT / "commands").glob("*.md")):
    head = f.read_text(encoding="utf-8").split("---")[1] if "---" in f.read_text(encoding="utf-8") else ""
    if not re.search(r"^disable-model-invocation:\s*true\s*$", head, re.M):
        problems.append("commands/%s can be invoked by the model" % f.name)
skill = (ROOT / "skills/muse-fleet/SKILL.md").read_text(encoding="utf-8")
if re.search(r"^disable-model-invocation:\s*true\s*$", skill.split("---")[1], re.M):
    problems.append("the fleet skill is opted out of auto-triggering -- it is the one "
                    "surface that is supposed to fire on its own")
# Registered hooks, and the two disciplines their scripts follow.
hooks = json.loads((ROOT / "hooks/hooks.json").read_text(encoding="utf-8"))
if "hooks" not in hooks:
    problems.append('hooks.json must wrap events in a top-level "hooks" key or it '
                    'registers nothing while parsing fine')
else:
    for ev in ("SessionStart", "SubagentStop", "SessionEnd"):
        if ev not in hooks["hooks"]:
            problems.append("hook event %s is not registered" % ev)
    sub = hooks["hooks"].get("SubagentStop") or [{}]
    if sub[0].get("matcher") != "muse-supervisor":
        problems.append("SubagentStop is not scoped to muse-supervisor (matcher=%r), so "
                        "it would fire on unrelated subagents" % sub[0].get("matcher"))
    for ev, entries in hooks["hooks"].items():
        for e in entries:
            for h in e.get("hooks", []):
                if "${CLAUDE_PLUGIN_ROOT}" not in h.get("command", ""):
                    problems.append("%s hook command is not rooted at "
                                    "${CLAUDE_PLUGIN_ROOT}: %r" % (ev, h.get("command")))
                if not h.get("timeout"):
                    problems.append("%s hook declares no timeout" % ev)
if problems:
    for p in problems: print("        " + p)
    sys.exit(1)
PY

# Frontmatter that does not parse is not an error at load time -- it is SILENCE. The
# validator's own words: "At runtime this command loads with empty metadata (all
# frontmatter fields silently dropped)." Three commands shipped that way, because
# `argument-hint: [--scan] [--repo <path>]` is not valid YAML, and four more shipped a
# hint that parsed as a LIST rather than a string. Nothing noticed for as long as the
# plugin has existed.
#
# PyYAML is not in the stdlib and the offline suite promises to need only git, python3
# and bash, so the real parse runs only where PyYAML happens to exist. The quoting rule
# below runs everywhere and is what actually catches this class.
python3 - <<'PY' && ok "every component's frontmatter parses, and its scalars are scalars" || bad "frontmatter would load as empty metadata"
import os, pathlib, re, sys
ROOT = pathlib.Path(os.environ["PLUGIN_ROOT"])
files = sorted((ROOT / "commands").glob("*.md")) + \
        sorted((ROOT / "agents").glob("*.md")) + \
        sorted((ROOT / "skills").glob("*/SKILL.md"))
if not files:
    print("        no component files found -- this guard is measuring nothing")
    sys.exit(1)

try:
    import yaml
except ImportError:
    yaml = None

SCALAR_KEYS = {"description", "argument-hint", "allowed-tools", "name", "model",
               "color", "effort"}

problems = []
for f in files:
    rel = f.relative_to(ROOT)
    t = f.read_text(encoding="utf-8")
    m = re.match(r"---\n(.*?)\n---\n", t, re.S)
    if not m:
        problems.append("%s has no frontmatter block" % rel)
        continue
    head = m.group(1)
    # The portable floor, applied only to the keys whose value must be a STRING --
    # `tools:` is legitimately a sequence and this rule fired on it, which is the first
    # thing this guard caught. A scalar value opening with one of these characters is
    # YAML syntax, not text: `[` and `{` are flow collections, `*` an alias, `&` an
    # anchor, `!` a tag, `%` a directive. Each either fails to parse -- dropping EVERY
    # field in the block -- or silently yields the wrong type.
    for line in head.splitlines():
        km = re.match(r"^([A-Za-z-]+):[ \t]+(\S.*)$", line)
        if km and km.group(1) in SCALAR_KEYS and km.group(2)[0] in "[{*&!%@`":
            problems.append("%s: %s must be quoted -- %r is YAML syntax, not a string"
                            % (rel, km.group(1), km.group(2)))
    if yaml is not None:
        try:
            d = yaml.safe_load(head)
        except Exception as e:
            problems.append("%s: frontmatter does not parse (%s)"
                            % (rel, str(e).splitlines()[0]))
            continue
        for k in SCALAR_KEYS:
            if k in d and not isinstance(d[k], str):
                problems.append("%s: %s parsed as %s, not a string"
                                % (rel, k, type(d[k]).__name__))
print("        (parsed with PyYAML)" if yaml is not None
      else "        (PyYAML absent -- quoting rule only)")
if problems:
    for p in problems: print("        " + p)
    sys.exit(1)
PY

# The registered workflow is the plugin's headline path now, so its registration is a
# thing that can break. A `workflows` key pointing at nothing, or a script whose meta.name
# does not match the name the skill tells the model to invoke, both fail at run time --
# after the planning agents have been paid for.
python3 - <<'PY' && ok "the fleet workflow is registered under the name the docs tell you to call" || bad "the registered workflow and the documented name disagree"
import json, os, pathlib, re, sys
ROOT = pathlib.Path(os.environ["PLUGIN_ROOT"])
problems = []
manifest = json.loads((ROOT / ".claude-plugin/plugin.json").read_text(encoding="utf-8"))
wf_key = manifest.get("workflows")
if not wf_key:
    problems.append("plugin.json declares no `workflows` key, so nothing is registered")
else:
    wdir = (ROOT / wf_key.lstrip("./")).resolve()
    scripts = sorted(wdir.glob("*.js")) if wdir.is_dir() else []
    if not scripts:
        problems.append("`workflows` points at %s, which holds no .js" % wf_key)
    names = set()
    for f in scripts:
        src = f.read_text(encoding="utf-8")
        if not src.lstrip().startswith("export const meta"):
            problems.append("%s: meta must be the first statement or the loader cannot "
                            "read it" % f.name)
        m = re.search(r"name:\s*'([^']+)'", src)
        if not m:
            problems.append("%s: meta declares no name" % f.name)
        else:
            names.add(m.group(1))
    # Whatever the docs and the command tell the model to invoke has to be in there.
    for doc in ("skills/muse-fleet/SKILL.md", "commands/fleet.md", "references/workflow.md"):
        for called in set(re.findall(r'name:\s*"([a-z0-9-]+)"',
                                     (ROOT / doc).read_text(encoding="utf-8"))):
            if called not in names:
                problems.append("%s tells the model to run %r, which no registered "
                                "workflow declares (registered: %s)"
                                % (doc, called, sorted(names) or "none"))
if problems:
    for p in problems: print("        " + p)
    sys.exit(1)
PY

# Component frontmatter. `claude plugin validate` does walk these files from the PLUGIN
# manifest, and it does reject frontmatter that fails to parse -- but it does not reject
# an unknown frontmatter KEY, measured by putting one in and watching it pass. Nor does
# it know what this project requires of the values. So the validator in CI is a floor,
# not a substitute for the contract below.
python3 - <<'PY' && ok "component frontmatter holds the contract the docs claim for it" || bad "component frontmatter has drifted from the documented contract"
import json, os, pathlib, re, sys

ROOT = pathlib.Path(os.environ["PLUGIN_ROOT"])

def front(path):
    t = (ROOT / path).read_text(encoding="utf-8")
    m = re.match(r"---\n(.*?)\n---\n", t, re.S)
    if not m:
        return None
    # Only top-level `key:` lines; the multi-line description block is indented.
    return dict(re.findall(r"^([A-Za-z-]+):[ \t]*(.*)$", m.group(1), re.M))

problems = []

sup = front("agents/muse-supervisor.md")
if sup is None:
    problems.append("the supervisor agent has no frontmatter at all")
else:
    # Rule 3 in AGENTS.md calls this load-bearing and nothing checked it until now.
    try:
        tools = json.loads(sup.get("tools", "null"))
    except ValueError:
        tools = None
    if tools != ["Bash", "Read", "Grep", "Glob"]:
        problems.append("supervisor tools are %r, not exactly [Bash, Read, Grep, Glob]" % (tools,))
    # Every other runaway path has a ceiling -- --max-rounds on the task, --max-steps on
    # muse, a round budget -- and the supervisor's own agent loop had none.
    try:
        turns = int(sup.get("maxTurns", ""))
    except ValueError:
        turns = None
    if turns is None or not (1 <= turns <= 200):
        problems.append("supervisor maxTurns is %r; it needs a declared, sane ceiling"
                        % (sup.get("maxTurns"),))

skill = front("skills/muse-fleet/SKILL.md")
if skill is None or "allowed-tools" not in skill:
    problems.append("the auto-triggering skill declares no allowed-tools")
elif re.search(r"\b(Write|Edit)\b", skill["allowed-tools"]):
    problems.append("the skill grants Write or Edit: %r" % skill["allowed-tools"])

CHEAP = {"commands/status.md", "commands/doctor.md", "commands/model.md",
         "commands/cleanup.md"}
for f in sorted(p.name for p in (ROOT / "commands").glob("*.md")):
    rel = "commands/" + f
    fm = front(rel) or {}
    tools = fm.get("allowed-tools", "")
    # Agent and Task are the new and legacy names for one tool.
    if re.search(r"\bAgent\b", tools) and re.search(r"\bTask\b", tools):
        problems.append("%s lists both Agent and Task" % rel)
    # A plugin whose thesis is "push mechanical work down to a cheaper model" should not
    # run its own script-relaying commands on the session model.
    if rel in CHEAP and not fm.get("model"):
        problems.append("%s relays a script and declares no cheap model" % rel)

mk = json.loads((ROOT / ".claude-plugin/marketplace.json").read_text(encoding="utf-8"))
rel = (mk["plugins"][0].get("relevance") or {})
cli = ((rel.get("signals") or {}).get("cli") or [])
if "muse" not in cli:
    problems.append("the marketplace entry declares no cli relevance signal for `muse`")
# A signal that fires on everything is worse than none: it surfaces the plugin to people
# it cannot help.
generic = {"git", "npm", "pnpm", "python", "python3", "pytest", "node", "cargo", "make"}
if generic & set(cli):
    problems.append("generic cli signals would surface this to the wrong people: %r"
                    % sorted(generic & set(cli)))

if problems:
    for p in problems: print("        " + p)
    sys.exit(1)
PY

# The workflow script in references/workflow.md is the skill's primary path and is copied
# out verbatim to be run. Nothing else would notice a typo in it until someone spent real
# money discovering it mid-run.
if command -v node >/dev/null 2>&1; then
  # EVERY javascript block, not just the first: the embedding section ships snippets that
  # users copy-paste, and a syntax error in one of those is exactly as broken as one in
  # the main script.
  WF_SYNTAX=$(python3 - <<'PY'
import re, pathlib, os, subprocess, tempfile
ROOT = pathlib.Path(os.environ["PLUGIN_ROOT"])
t = (ROOT / "references/workflow.md").read_text()
# The registered workflow FIRST -- it is the one the runtime loads and the model runs by
# name. The markdown fences are the copy-paste snippets, and a syntax error in one of
# those is exactly as broken for whoever pastes it.
blocks = [f.read_text() for f in sorted((ROOT / "workflows").glob("*.js"))] \
       + re.findall(r"```javascript\n(.*?)```", t, re.S)
if not blocks:
    print("no javascript found"); raise SystemExit
bad = []
for i, b in enumerate(blocks, 1):
    src = b.replace("export const meta", "const meta", 1)
    # The runtime evaluates the body inside an async function, so top-level await and
    # return are legal there but not in a bare module. Reproduce that shape or the
    # check is a lie.
    body = ("const agent=async()=>({tasks:[]}),parallel=async()=>[],pipeline=async()=>[],"
            "phase=()=>{},log=()=>{};\nglobalThis.args={pluginRoot:'/p',stamp:'s',repo:'/r'};"
            "\nconst tasks=[];\nasync function __body(){\n" + src + "\n}")
    f = tempfile.NamedTemporaryFile("w", suffix=".mjs", delete=False)
    f.write(body); f.close()
    r = subprocess.run(["node", "--check", f.name], capture_output=True, text=True)
    os.unlink(f.name)
    if r.returncode != 0:
        bad.append("block %d: %s" % (i, r.stderr.strip().splitlines()[-1][:80] if r.stderr.strip() else "?"))
print("; ".join(bad))
PY
)
  [ -z "$WF_SYNTAX" ] \
    && ok "every workflow.md javascript block parses as the runtime evaluates it" \
    || bad "workflow script syntax" "$WF_SYNTAX"

  # meta.phases titles are matched EXACTLY against phase() calls; a drifted title
  # silently splits the progress display into an orphan group instead of erroring.
  # The same doctrine reaches a supervisor two ways -- the agent definition when
  # /muse:delegate spawns it, the workflow prompt when the fleet does -- and the two
  # drift independently. Compared on NORMALISED whitespace: both sources wrap their
  # prose, and a literal grep for a phrase that happens to straddle a line break fails
  # for a reason that has nothing to do with drift. That is how this guard first broke.
  python3 - <<'PY' && ok "supervisor doctrine is present in both paths" || bad "doctrine drift between the agent and the workflow prompt"
import os, pathlib, re, sys
ROOT = pathlib.Path(os.environ["PLUGIN_ROOT"])
flat = lambda p: re.sub(r"\s+", " ", (ROOT / p).read_text(encoding="utf-8")).lower()
agent = flat("agents/muse-supervisor.md")
wf = flat("workflows/muse-supervised-fleet.js")
RULES = ["not write the code", "not apply the patch", "verify", "resumed"]
missing = [r for r in RULES if r not in agent or r not in wf]
for r in RULES:
    where = [n for n, t in (("the agent", agent), ("the workflow", wf)) if r not in t]
    if where:
        print("        %r missing from %s" % (r, " and ".join(where)))
sys.exit(1 if missing else 0)
PY

  # `const STAMP = args.stamp || 'run'` made every fan-out share one artifact root, so a
  # second run of the same job -- or two jobs that both planned a task called
  # tests-parser -- had every supervisor refuse at step one with "task already exists":
  # the re-run guard firing correctly against a namespace that should never have
  # collided. Branches and worktrees were stamped; --out was the one part that was not.
  #
  # The header is EXECUTED here rather than greped, so a default that creeps back in as
  # `args.stamp ?? 'run'` or a ternary is caught too.
  python3 - <<'PY' && ok "every workflow header demands a stamp and puts it in --out" || bad "the workflow artifact root is not namespaced"
import json, os, pathlib, re, subprocess, sys, tempfile
ROOT = pathlib.Path(os.environ["PLUGIN_ROOT"])
t = (ROOT / "references/workflow.md").read_text()
blocks = [b for b in [f.read_text() for f in sorted((ROOT / "workflows").glob("*.js"))]
          + re.findall(r"```javascript\n(.*?)```", t, re.S) if "const STAMP" in b]
if not blocks:
    print("        nothing defines STAMP -- this guard is measuring nothing")
    sys.exit(1)

def run_header(src, argv):
    lines = src.splitlines()
    cut = max(i for i, l in enumerate(lines)
              if re.match(r"const (OUT|STAMP|ROUNDS)\s*=", l))
    body = ("globalThis.args=" + json.dumps(argv) + ";\n"
            + "\n".join(lines[:cut + 1])
            + "\nconsole.log(JSON.stringify({OUT, STAMP}));\n")
    f = tempfile.NamedTemporaryFile("w", suffix=".mjs", delete=False, encoding="utf-8")
    f.write(body); f.close()
    r = subprocess.run([os.environ.get("NODE_BIN", "node"), f.name],
                       capture_output=True, text=True)
    os.unlink(f.name)
    return r

problems = []
for i, b in enumerate(blocks, 1):
    ok_run = run_header(b, {"pluginRoot": "/p", "repo": "/r", "stamp": "STAMP1234"})
    if ok_run.returncode != 0:
        problems.append("block %d: header failed with a stamp: %s"
                        % (i, (ok_run.stderr or "").strip().splitlines()[-1][:90]))
        continue
    got = json.loads(ok_run.stdout)
    if "STAMP1234" not in got["OUT"]:
        problems.append("block %d: --out %r does not carry the stamp, so two runs collide"
                        % (i, got["OUT"]))
    no_stamp = run_header(b, {"pluginRoot": "/p", "repo": "/r"})
    if no_stamp.returncode == 0:
        problems.append("block %d: a missing stamp silently defaulted to %r instead of throwing"
                        % (i, json.loads(no_stamp.stdout).get("STAMP")))
if problems:
    for p in problems: print("        " + p)
    sys.exit(1)
PY

  python3 - <<'PY' && ok "workflow meta.phases cover every phase() call" || bad "phase titles drift"
import re, pathlib, os, sys
b = (pathlib.Path(os.environ["PLUGIN_ROOT"]) / "workflows/muse-supervised-fleet.js").read_text()
meta  = set(re.findall(r"title:\s*'([^']+)'", b))
calls = set(re.findall(r"phase\('([^']+)'\)", b)) | set(re.findall(r"phase:\s*'([^']+)'", b))
if calls - meta:
    print("        orphan phases:", sorted(calls - meta))
sys.exit(0 if calls <= meta else 1)
PY
else
  printf '  \033[33mSKIP\033[0m  node not found — workflow script not syntax-checked\n'
fi

# ------------------------------------------------------- 2. pure functions
head_ "2. Unit tests — parse_answers / resolve_model"
python3 - "$LAB" <<'PY'
import importlib.util, os, sys, pathlib
# These live in muse_core now. Load THAT module, not muse_fleet: muse_fleet only holds
# re-exported copies, and rebinding a copied constant there does not change what
# core.catalog_rows() reads -- which silently turned these tests into no-ops once.
spec=importlib.util.spec_from_file_location("mf", os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_core.py"))
mf=importlib.util.module_from_spec(spec); spec.loader.exec_module(mf)
fails=[]
def chk(n,c):
    print(("  PASS  " if c else "  FAIL  ")+n)
    if not c: fails.append(n)

pa=mf.parse_answers
chk("parse: single object",        pa('{"a":1}')=={"a":1})
chk("parse: concatenated -> last", pa('{"a":1}{"a":2}')=={"a":2})
chk("parse: whitespace separated", pa('{"a":1}\n {"a":2}')=={"a":2})
chk("parse: three -> last",        pa('{"a":1}{"a":2}{"a":3}')=={"a":3})
chk("parse: trailing prose",       pa('{"a":1} trailing')=={"a":1})
chk("parse: no json -> None",      pa('nothing')is None)
chk("parse: empty -> None",        pa('')is None)
chk("parse: nested objects",       pa('{"a":{"b":[1,2]}}')=={"a":{"b":[1,2]}})

d=pathlib.Path(sys.argv[1])/"vcat"; d.mkdir(parents=True, exist_ok=True)
(d/"c.json").write_text('{"rows":[{"model_id":"muse-spark-1.3-contributor","release_date":"2026-09-02","is_default":true,"visibility":"visible"},{"model_id":"muse-spark-9.0-contributor","release_date":"2029-01-01","is_default":false,"visibility":"visible"},{"model_id":"muse-spark-9.0","release_date":"2029-01-01","visibility":"visible"},{"model_id":"muse-spark-9.9-contributor","release_date":"2030-01-01","visibility":"hidden"}]}')
mf.CATALOG_GLOB=str(d/"*.json")
m,_=mf.resolve_model(mf.LATEST)
chk("model: picks newest contributor over is_default", m=="muse-spark-9.0-contributor")
chk("model: skips non-contributor",  m.endswith("-contributor"))
chk("model: skips hidden",           m!="muse-spark-9.9-contributor")
chk("model: explicit passes through", mf.resolve_model("foo")[0]=="foo")
mf.CATALOG_GLOB=str(pathlib.Path(sys.argv[1])/"nope"/"*.json")
chk("model: fallback when no catalog", mf.resolve_model(mf.LATEST)[0]==mf.FALLBACK_MODEL)
(d/"bad.json").write_text("{broken")
mf.CATALOG_GLOB=str(d/"bad.json")
mid,how=mf.resolve_model(mf.LATEST)
chk("model: survives corrupt catalog", mid==mf.FALLBACK_MODEL and how.startswith("fallback"))

# Self-test of the seam these tests depend on. FALLBACK_MODEL currently equals what the
# real catalog returns, so an override that silently stopped working would leave every
# assertion above passing on live data. Steering the glob must change the answer.
mf.CATALOG_GLOB=str(d/"c.json")
a=mf.resolve_model(mf.LATEST)[0]
mf.CATALOG_GLOB=str(pathlib.Path(sys.argv[1])/"nope"/"*.json")
b=mf.resolve_model(mf.LATEST)[0]
chk("CATALOG_GLOB is a live seam (overrides still steer resolution)", a!=b)
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] && PASS=$((PASS+15)) || FAIL=$((FAIL+1))

# muse_ask.sh reaches resolve_model by importing a module path; if that import breaks,
# it silently falls back to a hardcoded model id instead of failing.
python3 -c "
import importlib.util,os,sys
spec=importlib.util.spec_from_file_location('m', os.path.expanduser('$CORE'))
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
sys.exit(0 if m.resolve_model(m.LATEST)[0].endswith('-contributor') else 1)" \
  && ok "muse_ask's resolve_model import path works" || bad "muse_ask resolve import"

# ------------------------------------------------------------ 3. guardrails
# ------------------------------------------------- 2b. session plumbing (no muse spawned)
head_ "2b. Session resume plumbing"

# Reusing --session-id across `muse exec` calls continues the conversation, which is what
# lets a revision be a follow-up instead of a re-brief. These check the wiring; the live
# section checks that muse actually remembers.
SESSDATA="$LAB/v_sessdata"
mkdir -p "$SESSDATA/sessions/.msp-view-v1/11111111-1111-1111-1111-111111111111"
mkdir -p "$SESSDATA/sessions/2026/09/22/22222222-2222-2222-2222-222222222222"
MUSE_DATA_DIR="$SESSDATA" python3 - <<'PY' && ok "session_exists finds both storage layouts and rejects the rest" || bad "session_exists"
import importlib.util, os, sys, pathlib
spec = importlib.util.spec_from_file_location("mc", os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_core.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
checks = [
    ("view-index layout",  m.session_exists("11111111-1111-1111-1111-111111111111"), True),
    ("dated layout",       m.session_exists("22222222-2222-2222-2222-222222222222"), True),
    ("unknown id",         m.session_exists("33333333-3333-3333-3333-333333333333"), False),
    ("empty id",           m.session_exists(""),                                     False),
]
bad = [n for n, got, want in checks if got != want]
if bad:
    print("        wrong:", bad)
sys.exit(1 if bad else 0)
PY

# Muse refuses to resume a session bound to another workspace, and FAILS the run rather
# than starting fresh -- so treating "exists" as "resumable" burns a round for nothing.
WSDATA="$LAB/v_wsdata"
WSID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
mkdir -p "$WSDATA/sessions/.msp-view-v1/$WSID"
printf '{"x":{"viewCursor":"v:1","workspaceRoot":"%s/the-right-place"}}\n' "$LAB" \
  > "$WSDATA/sessions/.msp-view-v1/$WSID/snapshot-1.json"
mkdir -p "$LAB/the-right-place" "$LAB/somewhere-else"
MUSE_DATA_DIR="$WSDATA" python3 - "$LAB" "$WSID" <<'PY' && ok "a session bound to another workspace counts as not resumable" || bad "workspace binding ignored"
import importlib.util, os, sys
lab, sid = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("mc", os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_core.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
checks = [
    ("no workspace arg -> exists",   m.session_exists(sid),                                  True),
    ("matching workspace",           m.session_exists(sid, lab + "/the-right-place"),        True),
    ("different workspace",          m.session_exists(sid, lab + "/somewhere-else"),         False),
    ("workspace recorded",           m.session_workspace(sid) == lab + "/the-right-place",   True),
]
wrong = [n for n, got, want in checks if got != want]
if wrong: print("        wrong:", wrong)
sys.exit(1 if wrong else 0)
PY

# The one coupling point that failed OPEN. `if recorded and ...` treated "cannot tell
# which workspace" as "no constraint": a view directory that survives a muse schema
# change with `workspaceRoot` renamed came back resumable, muse refused the cross-
# workspace resume, and the round died producing nothing -- verbatim the failure the
# code documents and claims to route around.
UNK="$LAB/v_wsunknown"
UNKID="ffffffff-0000-1111-2222-333333333333"
mkdir -p "$UNK/sessions/.msp-view-v1/$UNKID"
# A snapshot muse 1.4 might plausibly write: same file, same directory, renamed key.
printf '{"x":{"viewCursor":"v:1","workspacePath":"%s/the-right-place"}}\n' "$LAB" \
  > "$UNK/sessions/.msp-view-v1/$UNKID/snapshot-1.json"
# A session known only from the dated tree has no snapshot to read, which is a different
# question and must not be answered the same way.
DATEDID="ffffffff-0000-1111-2222-444444444444"
mkdir -p "$UNK/sessions/2026/09/22/$DATEDID"
MUSE_DATA_DIR="$UNK" python3 - "$LAB" "$UNKID" "$DATEDID" <<'PY' && ok "an unreadable workspace fails closed, and only where a snapshot exists" || bad "session_exists still fails open on an unknown schema"
import importlib.util, os, sys
lab, unk, dated = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("mc", os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_core.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
checks = [
    ("snapshot present, workspace unreadable", m.session_exists(unk, lab + "/the-right-place"), False),
    ("no workspace asked for",                 m.session_exists(unk),                            True),
    ("dated-tree only, nothing to read",       m.session_exists(dated, lab + "/the-right-place"), True),
]
wrong = [n for n, got, want in checks if got != want]
if wrong: print("        wrong:", wrong)
sys.exit(1 if wrong else 0)
PY

# The coupling to muse was real and undeclared. A version bump that renames an event key
# surfaces as every round failing identically, and doctor reported the version it found
# without ever comparing it to anything.
python3 - <<'PY' && ok "a muse version mismatch is named, and a match is not" || bad "version coupling is unchecked"
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("mc", os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_core.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
tested = m.MUSE_TESTED_VERSION
major, minor = tested.split(".")[:2]
checks = [
    ("exact match",        m.version_mismatch(tested) is None,                       True),
    ("patch bump is fine", m.version_mismatch("%s.%s.99" % (major, minor)) is None,  True),
    ("minor bump warns",   m.version_mismatch("%s.%d.0" % (major, int(minor) + 1)) is not None, True),
    ("major bump warns",   m.version_mismatch("%d.0.0" % (int(major) + 1)) is not None,         True),
    ("unknown stays quiet", m.version_mismatch(None) is None,                        True),
]
wrong = [n for n, got, want in checks if got != want]
if wrong: print("        wrong:", wrong)
sys.exit(1 if wrong else 0)
PY

# Muse rotates these snapshots. A stat() inside a sort key raises if one vanishes
# between the glob and the sort, and that FileNotFoundError came straight out of
# cmd_revise as a traceback -- exactly where a supervisor expects one JSON object.
ROT="$LAB/v_rotate"
ROTSID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
mkdir -p "$ROT/sessions/.msp-view-v1/$ROTSID"
printf '{"x":{"workspaceRoot":"%s/real"}}\n' "$LAB" \
  > "$ROT/sessions/.msp-view-v1/$ROTSID/snapshot-good.json"
ln -s "$ROT/sessions/.msp-view-v1/$ROTSID/gone.json" \
      "$ROT/sessions/.msp-view-v1/$ROTSID/snapshot-dangling.json" 2>/dev/null
MUSE_DATA_DIR="$ROT" python3 - "$LAB" "$ROTSID" <<'PY' && ok "a snapshot that vanishes mid-walk does not raise" || bad "session_workspace raised on a rotated snapshot"
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("mc", os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_core.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
lab, sid = sys.argv[1], sys.argv[2]
try:
    got = m.session_workspace(sid)
except Exception as e:
    print("        raised:", type(e).__name__, e); sys.exit(1)
sys.exit(0 if got == lab + "/real" else 1)
PY

python3 - <<'PY' && ok "muse_cmd carries --session-id only when given one" || bad "muse_cmd session wiring"
import importlib.util, os, sys, pathlib
spec = importlib.util.spec_from_file_location("mc", os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_core.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
wt = pathlib.Path(os.environ["PLUGIN_ROOT"]) / "not-a-real-worktree"
with_id = m.muse_cmd("mdl", "low", wt, session_id="abc-123")
without  = m.muse_cmd("mdl", "low", wt)
ok1 = "--session-id" in with_id and with_id[with_id.index("--session-id") + 1] == "abc-123"
ok2 = "--session-id" not in without
# A generated id must be a real uuid, not a placeholder that collides across tasks.
import uuid
try:
    uuid.UUID(m.new_session_id()); ok3 = m.new_session_id() != m.new_session_id()
except Exception:
    ok3 = False
sys.exit(0 if (ok1 and ok2 and ok3) else 1)
PY

# The fallback is the safety property: muse does not error on an unknown --session-id, it
# silently starts fresh, so a revision that assumed continuity would send bare feedback
# with no brief behind it.
grep -q 'REVISION_RESUMED_TEMPLATE' "$SKILL/scripts/muse_task.py" \
  && grep -q 'core.session_exists' "$SKILL/scripts/muse_task.py" \
  && ok "revise selects its prompt from a verified session, not an assumed one" \
  || bad "revise does not check session_exists"

python3 - <<'PY' && ok "the resumed prompt omits the brief and the fallback keeps it" || bad "revision templates"
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("mt", os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_task.py"))
mt = importlib.util.module_from_spec(spec); spec.loader.exec_module(mt)
resumed  = mt.REVISION_RESUMED_TEMPLATE.format(n=2, feedback="FB")
fallback = mt.REVISION_TEMPLATE.format(n=2, feedback="FB", brief="THEBRIEF")
sys.exit(0 if ("THEBRIEF" not in resumed and "{brief}" not in resumed
               and "THEBRIEF" in fallback) else 1)
PY

head_ "3. Preflight guardrails (no muse spawned)"

# core.preflight() checks `shutil.which("muse")` before it checks anything about the repo,
# so without muse on PATH every guard below reports "muse not found" and four real guards
# go untested -- which is exactly the environment CI and a new contributor have. This
# section spawns nothing, so a stub that satisfies the which() lookup is enough to reach
# the guards. If muse is genuinely installed, nothing here changes.
if ! command -v muse >/dev/null 2>&1; then
  make_muse_stub "$LAB/stub-bin"
  PATH="$(shell_path "$LAB/stub-bin"):$PATH"
  export PATH
  printf '  \033[33mNOTE\033[0m  muse not installed — using a stub so the repo guards stay testable\n'
fi

mkdir -p "$LAB/v_notgit"
echo '[{"id":"x","prompt":"noop"}]' > "$LAB/v_tasks.json"

cat > "$LAB/v_badschema.json" <<'EOF'
{"type":"object","required":["a"],"properties":{"a":{"type":"string"},"b":{"type":"string"}}}
EOF
out=$(python3 "$FLEET" --tasks "$LAB/v_tasks.json" --schema "$LAB/v_badschema.json" --repo "$LAB/v_notgit" 2>&1)
echo "$out" | grep -q 'must also appear in "required"' \
  && ok "rejects schema with optional field (before spawning)" \
  || bad "schema guard" "$out"

rm -rf "$LAB/v_notgit/.git"
out=$(python3 "$FLEET" --tasks "$LAB/v_tasks.json" --repo "$LAB/v_notgit" 2>&1)
echo "$out" | grep -qi 'not a git repository' \
  && ok "refuses a non-git directory" || bad "git guard" "$out"

mkrepo "$LAB/v_dirty"; echo "uncommitted" >> "$LAB/v_dirty/calc.py"
out=$(python3 "$FLEET" --tasks "$LAB/v_tasks.json" --repo "$LAB/v_dirty" 2>&1)
echo "$out" | grep -qi 'dirty' \
  && ok "refuses a dirty working copy" || bad "dirty guard" "$out"

out=$(python3 "$FLEET" --tasks "$LAB/v_tasks.json" --repo "$LAB/v_dirty" --allow-dirty --model echo-none 2>&1 | head -2)
echo "$out" | grep -q 'fleet:' && ok "--allow-dirty overrides the dirty refusal" || bad "allow-dirty" "$out"

cat > "$LAB/v_dup.json" <<'EOF'
[{"id":"a","prompt":"x"},{"id":"a","prompt":"y"}]
EOF
out=$(python3 "$FLEET" --tasks "$LAB/v_dup.json" --repo "$LAB/v_dirty" --allow-dirty 2>&1)
echo "$out" | grep -qi 'unique' && ok "rejects duplicate task ids" || bad "dup id guard" "$out"

# Seed a catalog rather than trusting the host's. On a machine with no muse install the
# old form of this check asserted "latest contributor" against a fallback path and failed
# for a correct reason, which is how it went red on CI's first run.
mkdir -p "$LAB/v_catalog"
cat > "$LAB/v_catalog/c.json" <<'CATALOG'
{"rows": [
  {"model_id": "muse-spark-9.9-contributor", "visibility": "visible", "release_date": "2030-01-01"},
  {"model_id": "muse-spark-0.1-contributor", "visibility": "visible", "release_date": "2020-01-01"},
  {"model_id": "muse-spark-9.9",             "visibility": "visible", "release_date": "2031-01-01"}
]}
CATALOG
out=$(MUSE_CATALOG_GLOB="$LAB/v_catalog/*.json" \
      python3 "$FLEET" --tasks "$LAB/v_tasks.json" --repo "$LAB/v_dirty" --allow-dirty 2>&1 | head -1)
echo "$out" | grep -q 'muse-spark-9.9-contributor' \
  && ok "resolves the newest CONTRIBUTOR model through the subprocess path" \
  || bad "default model resolution" "$out"

# os.killpg/os.getpgid/signal.SIGKILL are POSIX-only and absent on Windows as ATTRIBUTES,
# so touching them raises AttributeError -- which the OSError handler did not catch. A
# timeout handler that crashes turns a recoverable timeout into a lost run.
python3 - <<'PY' && ok "process-tree kill degrades instead of crashing without process groups" || bad "kill_process_tree raises where process groups are unavailable"
import importlib.util, os, subprocess, sys, time
real = {}
for name in ("killpg", "getpgid"):          # exactly what Windows lacks and we call
    if hasattr(os, name):
        real[name] = getattr(os, name); delattr(os, name)
try:
    spec = importlib.util.spec_from_file_location(
        "mc", os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_core.py"))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    if m.HAVE_PROCESS_GROUPS:
        print("        capability probe did not notice the missing attributes"); sys.exit(1)
    p = subprocess.Popen(["sh", "-c", "sleep 60"])
    time.sleep(0.3)
    m.kill_process_tree(p)                   # must not raise
    if p.poll() is None:
        print("        child survived the fallback kill"); sys.exit(1)
finally:
    for n, v in real.items(): setattr(os, n, v)
PY

# A 1-second stamp is not a unique namespace: two fleets started in the same second
# computed identical branches AND worktree paths, and run_task opens with drop_worktree,
# so the second silently force-removed the first's live worktrees.
python3 - <<'PY' && ok "fleet run stamps are unique within the same second" || bad "stamp collision still possible"
import importlib.util, os, re, sys
src = open(os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_fleet.py")).read()
# The stamp must carry entropy, not just a second-resolution clock.
if "secrets.token_hex" not in src:
    print("        stamp has no entropy source"); sys.exit(1)
import datetime as dt, secrets
# Mirror what muse_fleet actually does, including the width -- a test that samples less
# entropy than the code would pass while the code stayed weak.
import re as _re
width = int(_re.search(r"secrets\.token_hex\((\d+)\)", src).group(1))
if width < 4:
    print("        token_hex(%d) is too thin: ~1.9%% collision across 50 runs" % width)
    sys.exit(1)
mk = lambda: "{}-{}".format(dt.datetime.now().strftime("%Y%m%d-%H%M%S"), secrets.token_hex(width))
s = [mk() for _ in range(200)]
if len(set(s)) != len(s):
    print("        collided in 200 draws"); sys.exit(1)
# and must still sort chronologically on its time prefix
if [x[:15] for x in s] != sorted(x[:15] for x in s):
    print("        no longer chronological"); sys.exit(1)
PY

# Every muse-side failure used to come back as the same sentence -- "muse produced no
# run_terminal record (crash or kill?)" -- whether the flag was unknown, the model id was
# wrong, the credential had expired or the binary on PATH was not Muse Code at all. The
# exit code was never read and stderr.log was listed as an artifact nothing told the
# supervisor to open, so the only available move was to retry blind.
#
# Driven through run_muse with a fake binary, so no muse is spawned and no money is
# spent. sys.executable rather than `sh -c`: the Windows leg runs a native Python that
# has no sh on its PATH.
python3 - <<'PY' && ok "a failed round is diagnosable: exit code, stderr, and a reason that differs" || bad "every muse failure still reports the same reason"
import importlib.util, os, pathlib, sys, tempfile
spec = importlib.util.spec_from_file_location(
    "mc", os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_core.py"))
mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)

def run(script):
    d = pathlib.Path(tempfile.mkdtemp())
    return mc.run_muse([sys.executable, "-c", script], "brief", d,
                       d / "events.jsonl", d / "stderr.log", 30)

crashed = run("import sys; sys.stderr.write('error: unknown flag --nope\\n'); sys.exit(7)")
silent  = run("pass")
noisy   = run("import sys; sys.stderr.write('warning: model deprecated\\n')")

problems = []
if crashed.get("exit_code") != 7:
    problems.append("exit code not recorded: %r" % (crashed.get("exit_code"),))
if "unknown flag" not in (crashed.get("stderr_tail") or ""):
    problems.append("stderr not carried into the record: %r" % (crashed.get("stderr_tail"),))
if "7" not in (crashed.get("reason") or "") or "unknown flag" not in (crashed.get("reason") or ""):
    problems.append("reason does not name what happened: %r" % (crashed.get("reason"),))
reasons = {crashed.get("reason"), silent.get("reason"), noisy.get("reason")}
if len(reasons) != 3:
    problems.append("three different failures produced %d distinct reasons: %r"
                    % (len(reasons), sorted(str(r) for r in reasons)))
if not all(r.get("status") == "no_terminal" for r in (crashed, silent, noisy)):
    problems.append("status is no longer no_terminal, so this guard is measuring "
                    "something other than the path it claims")
if problems:
    for p in problems: print("        " + p)
    sys.exit(1)
PY

# An agent's Bash cwd resets between tool calls, and the documented --out is relative.
# Resolving it against the cwd meant `run` from the repo root and `verify` from a
# subdirectory addressed two different task directories: the second reported
# no_such_task, and the supervisor's natural recovery -- `run --force` -- discards the
# patch the first one just made. Two documents disagreed about this and the wrong one
# was the command a user actually runs.
CWD="$LAB/v_cwd"; mkrepo "$CWD"
printf '.muse-fleet/\n' >> "$CWD/.git/info/exclude"
mkdir -p "$CWD/sub/deeper"
CWDSHA=$(git -C "$CWD" rev-parse --verify HEAD)
git -C "$CWD" worktree add -q -b muse/cwd/t1 "$LAB/v_cwd_wt" "$CWDSHA"
mkdir -p "$CWD/.muse-fleet/tasks/t1"
python3 - "$CWD" "$LAB/v_cwd_wt" "$CWDSHA" <<'PY'
import json, sys
repo, wt, sha = sys.argv[1:4]
json.dump({"id": "t1", "repo": repo, "worktree": wt, "branch": "muse/cwd/t1",
           "base": "HEAD", "base_sha": sha, "excludes": [".muse-fleet/"],
           "model": "muse-spark-1.3-contributor", "effort": "low",
           "rounds": [{"n": 1, "kind": "initial", "patch_lines": 2,
                       "files_changed": ["calc.py"]}],
           "max_rounds": 3, "done": False},
          open(repo + "/.muse-fleet/tasks/t1/state.json", "w"))
PY
SUBOUT=$(cd "$CWD/sub/deeper" && python3 "$TASK" show --id t1 --out .muse-fleet/tasks 2>/dev/null)
echo "$SUBOUT" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if d.get('id')=='t1' and d.get('status')!='no_such_task' else 1)" \
  && ok "a relative --out finds the same task from a subdirectory" \
  || bad "the artifact root moved with the cwd" "$SUBOUT"
# The control: an ABSOLUTE --out must still mean exactly what it says, and a genuinely
# absent task must still report no_such_task rather than being conjured by the anchor.
ABSOUT=$(cd "$CWD/sub" && python3 "$TASK" show --id t1 --out "$CWD/.muse-fleet/tasks" 2>/dev/null)
echo "$ABSOUT" | python3 -c "
import json,sys
sys.exit(0 if json.load(sys.stdin).get('id')=='t1' else 1)" \
  && ok "an absolute --out is left alone" || bad "absolute --out was re-anchored" "$ABSOUT"
MISSOUT=$(cd "$CWD/sub" && python3 "$TASK" show --id nosuch --out .muse-fleet/tasks 2>/dev/null)
echo "$MISSOUT" | python3 -c "
import json,sys
sys.exit(0 if json.load(sys.stdin).get('status')=='no_such_task' else 1)" \
  && ok "an absent task still reports no_such_task" || bad "the anchor invented a task" "$MISSOUT"
# And the one case the anchor cannot rescue: --repo naming a different repository than
# the cwd, where the later subcommands have nothing to resolve against.
OTHER="$LAB/v_cwd_other"; mkrepo "$OTHER"
XOUT=$(cd "$CWD" && python3 "$TASK" run --id x --repo "$OTHER" --out .muse-fleet/tasks --prompt noop 2>/dev/null)
echo "$XOUT" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if d.get('status')=='refused' and 'relative' in (d.get('reason') or '') else 1)" \
  && ok "a relative --out against another repo is refused, with the absolute path named" \
  || bad "a task was created where later subcommands cannot find it" "$XOUT"

# Entropy handles the common case. This is the one it cannot: two runs handed the same
# explicit --out collide however unique the stamp is.
COL="$LAB/v_collide"; mkrepo "$COL"
printf '.muse-fleet/\n' >> "$COL/.git/info/exclude"
COLWT="$LAB/v_collide_wt"; mkdir -p "$COLWT"
# A REAL registered worktree, standing in for another run's live one. A plain directory
# does not reproduce the hazard: drop_worktree only removes worktrees git knows about, so
# the first version of this fixture survived even with the guard disabled, and git's own
# "already exists" error matched the assertion by coincidence.
git -C "$COL" worktree add -q -b "fleet/OTHERRUN/t1" "$COLWT/RUNX-t1" HEAD
echo "another run's in-flight work" > "$COLWT/RUNX-t1/PRECIOUS.txt"
cat > "$LAB/v_collide_tasks.json" <<'JSON'
[{"id":"t1","prompt":"noop"}]
JSON
python3 "$FLEET" --tasks "$LAB/v_collide_tasks.json" --repo "$COL" \
  --out "$LAB/v_collide/RUNX" --worktree-root "$COLWT" --allow-dirty >/dev/null 2>&1
[ -f "$COLWT/RUNX-t1/PRECIOUS.txt" ] \
  && ok "the fleet refuses a worktree another run is using instead of deleting it" \
  || bad "the fleet destroyed another run's live worktree"
python3 -c "
import json,sys
d=json.load(open('$LAB/v_collide/RUNX/report.json'))
t=d['tasks'][0]
sys.exit(0 if t['status']=='setup_failed' and 'already exists' in (t.get('reason') or '') else 1)
" 2>/dev/null && ok "the collision is reported as setup_failed, not silently skipped" \
  || bad "collision not reported in the fleet report"

# The same hazard on the documented single-task path, which had neither defence. The
# branch guard above it does not answer this question: the live worktree is checked out
# on a DIFFERENT branch, so the name does not collide and drop_worktree's
# `git worktree remove --force` would have taken it.
TCOL="$LAB/v_tcollide"; mkrepo "$TCOL"
printf '.muse-fleet/\n' >> "$TCOL/.git/info/exclude"
TCOLWT="$LAB/v_tcollide_wt"; mkdir -p "$TCOLWT"
git -C "$TCOL" worktree add -q -b "someone-elses/branch" "$TCOLWT/FIXED-t1" HEAD
echo "another run's in-flight work" > "$TCOLWT/FIXED-t1/PRECIOUS.txt"
TCOLOUT=$(cd "$TCOL" && python3 "$TASK" run --id t1 --repo "$TCOL" --stamp FIXED \
  --worktree-root "$TCOLWT" --out "$TCOL/.muse-fleet/tasks" --prompt noop 2>/dev/null)
[ -f "$TCOLWT/FIXED-t1/PRECIOUS.txt" ] \
  && ok "muse_task refuses a live worktree instead of force-removing it" \
  || bad "muse_task destroyed a live worktree checked out on another branch"
echo "$TCOLOUT" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if d.get('status')=='refused' and 'already exists' in (d.get('reason') or '') else 1)" \
  && ok "the single-task collision is refused in JSON, not a traceback" \
  || bad "collision not reported by muse_task" "$TCOLOUT"

# Both drivers need entropy in the stamp, and greping either source for `token_hex` is a
# guard that cannot fail -- the import and the constant can both survive while the stamp
# expression stops using them. Parse instead, and look at the expression actually
# assigned to `stamp`.
python3 - <<'PY' && ok "both drivers put entropy in the stamp expression itself" || bad "a stamp collision is still possible"
import ast, os, sys
problems = []
for name in ("muse_task.py", "muse_fleet.py"):
    src = open(os.path.join(os.environ["PLUGIN_ROOT"], "scripts", name)).read()
    exprs = [ast.dump(n.value) for n in ast.walk(ast.parse(src))
             if isinstance(n, ast.Assign)
             and any(isinstance(t, ast.Name) and t.id == "stamp" for t in n.targets)]
    if not exprs:
        problems.append("%s: nothing is assigned to `stamp`" % name)
    elif not any("token_hex" in e for e in exprs):
        problems.append("%s: the stamp expression has no entropy, so two runs in the "
                        "same second compute the same worktree path" % name)
if problems:
    for p in problems: print("        " + p)
    sys.exit(1)
PY

# harvest used to diff against the ref NAME. A branch that moves mid-task then pulls
# other people's commits into this task's patch -- and `git apply --3way`, the command
# the README tells users to run, DELETES their work. Reproduced end to end here because
# it is the worst outcome this plugin can produce: a silent revert inside a green accept.
MOV="$LAB/v_movingbase"; mkrepo "$MOV"
printf '.muse-fleet/\n' >> "$MOV/.git/info/exclude"
MOVWT="$LAB/v_movingbase_wt"
BASESHA=$(git -C "$MOV" rev-parse --verify HEAD)
git -C "$MOV" worktree add -q -b task/work "$MOVWT" "$BASESHA"
printf 'def added():\n    return 1\n' > "$MOVWT/task_work.py"

# Meanwhile, someone lands an unrelated commit on the branch the task named.
printf 'important\n' > "$MOV/UNRELATED.txt"
git -C "$MOV" add -A
git -C "$MOV" -c user.email=t@l -c user.name=t commit -qm "unrelated work"

python3 - "$MOV" "$MOVWT" "$BASESHA" <<'PY' && ok "a base ref that moves mid-task cannot pull unrelated commits into the patch" || bad "moving base contaminated the patch"
import importlib.util, os, pathlib, sys
spec = importlib.util.spec_from_file_location("mc", os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_core.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
repo, wt, sha = sys.argv[1], pathlib.Path(sys.argv[2]), sys.argv[3]
out = pathlib.Path(repo) / "harvested.diff"

# Against the pinned sha: only this task's file.
rec = m.harvest(wt, sha, m.DEFAULT_EXCLUDES, out)
pinned = out.read_text(encoding="utf-8")
# Against the ref name, the way it used to work: the unrelated commit shows up as a
# deletion. Kept as a live control so the guard cannot pass by checking nothing.
m.harvest(wt, "main", m.DEFAULT_EXCLUDES, pathlib.Path(repo) / "byref.diff")
byref = (pathlib.Path(repo) / "byref.diff").read_text(encoding="utf-8")

problems = []
if "task_work.py" not in pinned:
    problems.append("pinned harvest lost the task's own work")
if "UNRELATED.txt" in pinned:
    problems.append("pinned harvest contaminated by the moving branch")
if "UNRELATED.txt" not in byref:
    problems.append("control failed: diffing by ref name no longer reproduces the bug, "
                    "so this guard is not testing what it claims")
if problems:
    for p in problems: print("        " + p)
    sys.exit(1)
PY

# Exercise the driver's own choice of base, not just muse_core.harvest. Greping for a
# function NAME passed while the function body was reverted -- a guard that could not
# fail, which is the one thing this suite refuses to ship.
python3 - <<'PY' && ok "muse_task selects the pinned sha over the ref name" || bad "muse_task still selects the ref name"
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location(
    "mt", os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_task.py"))
mt = importlib.util.module_from_spec(spec); spec.loader.exec_module(mt)
pinned = mt.harvest_base({"base": "main", "base_sha": "deadbeefcafe"})
legacy = mt.harvest_base({"base": "main"})          # state written before base_sha existed
problems = []
if pinned != "deadbeefcafe":
    problems.append("chose %r over the pinned sha" % pinned)
if legacy != "main":
    problems.append("old state without base_sha should fall back to the ref, got %r" % legacy)
if problems:
    for p in problems: print("        " + p)
    sys.exit(1)
PY

# Found by the excluded-path guard above, and it had been shipped: `git add -A --
# :(exclude,glob)__pycache__` exits 1 when git ALREADY ignores __pycache__, and
# DEFAULT_EXCLUDES is a list of exactly what a real repo gitignores. Every harvest on
# such a repo returned "git add failed" from the moment a worker generated one, and
# patch.diff stopped being updated. Invisible here for as long as it was, because every
# fixture repo in this suite is created without a .gitignore.
IGN="$LAB/v_ignored"; IGNWT="$LAB/v_ignored_wt"; mkrepo "$IGN"
printf '__pycache__/\nnode_modules/\n' > "$IGN/.gitignore"
git -C "$IGN" add -A
git -C "$IGN" -c user.email=t@l -c user.name=t commit -qm gitignore
IGNSHA=$(git -C "$IGN" rev-parse --verify HEAD)
git -C "$IGN" worktree add -q -b task/ignored "$IGNWT" "$IGNSHA"
printf 'def worked():\n    return 1\n' > "$IGNWT/the_work.py"
mkdir -p "$IGNWT/__pycache__" && printf 'bytecode\n' > "$IGNWT/__pycache__/calc.cpython-311.pyc"
python3 - "$IGN" "$IGNWT" "$IGNSHA" <<'PY' && ok "a gitignored build dir does not abort the harvest" || bad "harvest fails on any repo with a .gitignore"
import importlib.util, os, pathlib, sys
spec = importlib.util.spec_from_file_location(
    "mc", os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_core.py"))
mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
repo, wt, sha = sys.argv[1], pathlib.Path(sys.argv[2]), sys.argv[3]
out = pathlib.Path(repo) / "ignored.diff"
rec = mc.harvest(wt, sha, mc.DEFAULT_EXCLUDES, out)
problems = []
if rec["harvest_error"]:
    problems.append("harvest_error: %s" % rec["harvest_error"])
if "the_work.py" not in rec["files_changed"]:
    problems.append("the work is missing from the patch: %r" % (rec["files_changed"],))
if any(".pyc" in f for f in rec["files_changed"]):
    problems.append("the ignored build output reached the patch: %r" % (rec["files_changed"],))
# The control. Without it this guard passes on a harvest that silently stopped
# excluding anything, which is the other way to make the symptom disappear.
if mc.patch_fingerprint(wt, sha, mc.DEFAULT_EXCLUDES) is None:
    problems.append("fingerprint unobtainable on the same tree")
if problems:
    for p in problems: print("        " + p)
    sys.exit(1)
PY

# ------------------------------------------- 3b. status + cleanup (no muse spawned)
head_ "3b. Status and cleanup"

# Real git worktrees and real branches, with artifacts synthesised in the exact shape
# muse_task.py writes. No muse call is needed to exercise the reporting and reaping
# logic, and keeping these free means they run on every change rather than once a release.
SC="$LAB/v_sc"
mkrepo "$SC"
SCWT="$LAB/v_sc_wt"; mkdir -p "$SCWT"
SCOUT="$SC/.muse-fleet/tasks"
for spec in "muse/s/a:a:1:1" "muse/s/b:b:1:0" "fleet/s/c:c:0:0"; do
  IFS=: read -r br id fin ver <<< "$spec"
  git -C "$SC" worktree add -q -b "$br" "$SCWT/$id" HEAD
  mkdir -p "$SCOUT/$id"
  printf 'diff --git a/calc.py b/calc.py\n+x\n' > "$SCOUT/$id/patch.diff"
  python3 - "$SCOUT/$id" "$id" "$br" "$fin" "$ver" "$SC" "$SCWT/$id" <<'MKART'
import json, sys
d, tid, br, fin, ver, repo, wt = sys.argv[1:8]
fin, ver = fin == "1", ver == "1"
verifs = [{"after_round": 1, "command": "true", "exit_code": 0, "passed": True}] if ver else []
st = {"id": tid, "repo": repo, "worktree": wt, "branch": br, "base": "HEAD",
      "model": "m", "effort": "low", "max_rounds": 3, "rounds": [{"n": 1}],
      "verifications": verifs, "done": fin}
if fin:
    st.update({"verdict": "accept", "final_patch_lines": 2, "final_files_changed": ["calc.py"]})
open(d + "/state.json", "w").write(json.dumps(st))
if fin:
    open(d + "/task.json", "w").write(json.dumps({
        "id": tid, "verdict": "accept", "patch_lines": 2, "files_changed": ["calc.py"],
        "rounds_used": 1, "worktree": wt, "branch": br,
        "verified_by_supervisor": ver, "verifications": verifs}))
MKART
done

ST=$(cd "$SC" && python3 "$SKILL/scripts/muse_status.py" --out .muse-fleet 2>&1)
# The single most important thing this report does: an accept nobody checked must not
# read like a good run. If this stops firing, the report is actively misleading.
echo "$ST" | grep -q 'ACCEPTED WITHOUT AN EXECUTED CHECK' \
  && ok "status flags an accept with no executed check" || bad "unverified accept not flagged" "$ST"
echo "$ST" | grep -qE '^  a  \[accept\] verified' \
  && ok "status marks a genuinely verified task verified" || bad "verified task mislabelled" "$ST"

SJ=$(cd "$SC" && python3 "$SKILL/scripts/muse_status.py" --out .muse-fleet --json)
echo "$SJ" | python3 -c "
import json,sys; d=json.load(sys.stdin)
sys.exit(0 if len(d['tasks'])==3 else 1)" \
  && ok "status --json finds every task at either nesting depth" || bad "status --json task count"

# A dry run must be a dry run: the commonest way to lose delegated work is a reap that
# ran before anyone looked at it.
DRY=$(cd "$SC" && python3 "$SKILL/scripts/muse_cleanup.py" --repo . --out .muse-fleet 2>&1)
[ "$(git -C "$SC" worktree list | wc -l)" -eq 4 ] \
  && ok "cleanup dry run removes nothing" || bad "dry run removed worktrees"
echo "$DRY" | grep -q 'skipping 1 unfinished' \
  && ok "cleanup skips tasks with no verdict" || bad "unfinished task not skipped" "$DRY"

(cd "$SC" && python3 "$SKILL/scripts/muse_cleanup.py" --repo . --out .muse-fleet --yes >/dev/null 2>&1)
[ "$(git -C "$SC" worktree list | wc -l)" -eq 2 ] \
  && ok "cleanup --yes reaps finished tasks only" || bad "wrong worktree count after --yes"
git -C "$SC" branch --format='%(refname:short)' | grep -q '^fleet/s/c$' \
  && ok "unfinished task's branch survives --yes" || bad "unfinished branch deleted"

(cd "$SC" && python3 "$SKILL/scripts/muse_cleanup.py" --repo . --out .muse-fleet --yes --all --artifacts >/dev/null 2>&1)
[ "$(git -C "$SC" worktree list | wc -l)" -eq 1 ] \
  && ok "cleanup --all reaps the rest" || bad "worktrees left after --all"
[ ! -d "$SC/.muse-fleet" ] \
  && ok "cleanup --artifacts removes the artifact root" || bad "artifact root survived"

# Fixed scratch paths collide between users on a shared host and can be pre-created as
# symlinks before the suite writes them. LAB is already a mktemp dir; everything scratch
# belongs under it. The pattern is assembled at runtime so this guard does not match its
# own source line -- the first version of it did exactly that and failed on a clean tree.
# Matches any fixed scratch path, not just the v_ prefix the first version looked for --
# a "vcat" directory slipped past it and only surfaced on Windows, where native python
# read the MSYS path as a backslash literal. The pattern is assembled at runtime and this
# comment names no literal path, because BOTH earlier versions of this guard matched
# their own source. The trailing character class also means the TMPDIR fallback below,
# which ends in a brace, is not a hit.
TMPPAT="$(printf '/tmp/%s' '[A-Za-z0-9]')"
TMPLEAK=$(grep -nE "$TMPPAT" "$SKILL/scripts/validate.sh" || true)
[ -z "$TMPLEAK" ] \
  && ok "the suite writes no fixed scratch path (all of it is under \$LAB)" \
  || bad "a fixed scratch path crept back in" "$TMPLEAK"

# The converted eval suite cannot be RUN here -- `claude plugin eval` is early access --
# so these checks hold what can be held without it: the layout the CLI's own --help
# documents, and consistency with the legacy evals.json that is still the source of
# truth until someone runs the new suite green.
python3 - <<'PY' && ok "eval cases are well-formed and consistent with evals.json" || bad "eval suite"
import glob, json, os, pathlib, sys
root = pathlib.Path(os.environ["PLUGIN_ROOT"]) / "evals"
legacy = json.loads((root / "evals.json").read_text(encoding="utf-8"))["evals"]
problems = []

dirs = sorted(p for p in root.iterdir() if p.is_dir())
if len(dirs) != len(legacy):
    problems.append("%d case dirs vs %d in evals.json" % (len(dirs), len(legacy)))

def frontmatter(path):
    # Deliberately not pyyaml: CI's setup-python does not install it, and a guard that
    # silently skips on ImportError is a guard that checks nothing.
    t = path.read_text(encoding="utf-8")
    if not t.startswith("---\n"):
        return None
    body = t.split("---\n", 2)
    if len(body) < 3:
        return None
    out = {}
    for line in body[1].splitlines():
        if ":" in line and not line.startswith((" ", "\t", "#")):
            k, v = line.split(":", 1)
            out[k.strip()] = v.strip()
    return out

for d in dirs:
    pm = d / "prompt.md"
    if not pm.exists():
        problems.append("%s: no prompt.md" % d.name); continue
    fm = frontmatter(pm)
    if not fm or "name" not in fm:
        problems.append("%s: prompt.md frontmatter missing or nameless" % d.name); continue
    graders = sorted((d / "graders").glob("*.md")) if (d / "graders").is_dir() else []
    if not graders:
        problems.append("%s: no graders" % d.name); continue

    negative = d.name.startswith("negative-")
    kinds = {}
    for g in graders:
        gfm = frontmatter(g) or {}
        kinds[g.name] = gfm
        if "type" not in gfm:
            problems.append("%s/%s: grader has no type" % (d.name, g.name))
    tool_graders = [v for v in kinds.values() if v.get("type") == "tool_used"]
    if not tool_graders:
        problems.append("%s: no tool_used grader, so skill firing is unasserted" % d.name)
        continue
    tg = tool_graders[0]
    if negative:
        # A negative case whose bounds are not both zero asserts nothing useful.
        if tg.get("min") != "0" or tg.get("max") != "0":
            problems.append("%s: negative case must bound the skill at min 0 max 0, got "
                            "min=%s max=%s" % (d.name, tg.get("min"), tg.get("max")))
    else:
        if tg.get("min") in (None, "0"):
            problems.append("%s: positive case must require the skill (min >= 1)" % d.name)

# Every legacy case must have a converted home, or the conversion silently dropped one.
names = {d.name for d in dirs}
import re
for case in legacy:
    slug = re.sub(r"[^a-z0-9]+", "-", case["name"].lower()).strip("-")
    if slug not in names:
        problems.append("evals.json case %r has no converted directory" % case["name"])

if problems:
    for p in problems[:8]:
        print("        " + p)
    sys.exit(1)
PY

# The input_match regex is the part of the converted suite most likely to be silently
# wrong: a pattern that matches nothing makes every positive case fail, and one that
# matches too much makes every negative case pass for the wrong reason. It is also the
# one part testable WITHOUT the eval runner, against the payload shape a real Skill
# tool_use record carries: {"skill": "plugin:skill-name"}.
python3 - <<'PY' && ok "the skill matcher accepts real Skill payloads and rejects near misses" || bad "input_match regex"
import os, pathlib, re, sys
root = pathlib.Path(os.environ["PLUGIN_ROOT"]) / "evals"
pats = set()
for g in root.glob("*/graders/*.md"):
    m = re.search(r"input_match:\s*'(.+?)'\s*$", g.read_text(encoding="utf-8"), re.M)
    if m:
        pats.add(m.group(1))
if len(pats) != 1:
    print("        expected one shared matcher, found:", sorted(pats)); sys.exit(1)
rx = re.compile(pats.pop())
cases = [
    ('{"skill": "muse:muse-fleet"}',             True),   # the real plugin-scoped shape
    ('{"skill":"muse:muse-fleet"}',              True),   # no space after the colon
    ('{"skill": "muse-fleet"}',                  True),   # unscoped
    ('{"skill": "other-plugin:muse-fleet"}',     True),   # plugin renamed
    ('{"skill": "muse-fleet-extra"}',            False),  # shares the prefix
    ('{"skill": "notmuse-fleet"}',               False),  # shares the suffix
    ('{"skill": "plugin-dev:plugin-structure"}', False),  # an unrelated real skill
    ('{"skill": "muse:ask"}',                    False),  # a sibling in this plugin
]
wrong = [p for p, want in cases if bool(rx.search(p)) != want]
if wrong:
    print("        wrong verdict for:", wrong); sys.exit(1)
PY

# Numbers in prose rot: README and CONTRIBUTING both claimed "55 checks" long after the
# suite reached 65, and nothing noticed. The suite prints its own count, so the docs must
# not restate it. CHANGELOG is exempt -- a released version's count is a historical fact.
DRIFT=$(grep -rnE '[0-9]+ (free )?checks|[0-9]+/[0-9]+ offline' \
        "$SKILL/README.md" "$SKILL/CONTRIBUTING.md" "$SKILL/skills/muse-fleet/SKILL.md" \
        "$SKILL/.github/PULL_REQUEST_TEMPLATE.md" 2>/dev/null)
[ -z "$DRIFT" ] \
  && ok "no doc restates the check count (it rots; the suite prints it)" \
  || bad "a doc hardcodes a check count" "$DRIFT"

# Both of these produced a raw Python traceback or escaped the artifact root before.
# muse_task promises exactly one JSON object on stdout; a supervisor parses that stream,
# and a traceback or an empty stream tells it nothing.
EDG="$LAB/v_edge"; mkdir -p "$EDG"; git init -q -b main "$EDG"
EOUT=$(cd "$EDG" && python3 "$TASK" run --id x --repo "$EDG" --prompt noop 2>/dev/null)
echo "$EOUT" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if d.get('status')=='refused' and 'no commits' in d.get('reason','') else 1)" \
  && ok "a repo with no commits is refused in JSON, not a traceback" \
  || bad "empty repo did not refuse cleanly" "$EOUT"

# An id becomes a directory name and a git branch component.
TRAV="$LAB/v_trav"; mkrepo "$TRAV"
printf '.muse-fleet/\n' >> "$TRAV/.git/info/exclude"
TOUT=$(cd "$TRAV" && python3 "$TASK" run --id "../../ESCAPED" --repo "$TRAV" --prompt noop 2>/dev/null)
echo "$TOUT" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if d.get('status')=='refused' else 1)" \
  && ok "a task id with a path separator is refused" || bad "traversal id accepted" "$TOUT"
[ ! -d "$LAB/ESCAPED" ] && [ ! -d "$TRAV/ESCAPED" ] \
  && ok "no artifacts were written outside the artifact root" || bad "id escaped the artifact root"

python3 - <<'PY' && ok "task id validation accepts normal ids and rejects the dangerous shapes" || bad "validate_task_id logic"
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("mc", os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_core.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
good = ["tests-auth", "a", "mod_1.2", "A9"]
bad_ids = ["../x", "a/b", "", ".", "..", "-lead", "x" * 65, "a b", "x;rm -rf /", "a\nb"]
wrong = []
for g in good:
    try: m.validate_task_id(g)
    except Exception: wrong.append("rejected good: " + g)
for b in bad_ids:
    try:
        m.validate_task_id(b); wrong.append("accepted bad: %r" % b)
    except m.PreflightError: pass
if wrong: print("        ", wrong)
sys.exit(1 if wrong else 0)
PY

# Re-running an existing task id overwrote its harvested patch and orphaned its worktree,
# both silently. The lost patch may be work nobody applied yet.
CLB="$LAB/v_clobber"; mkrepo "$CLB"
printf '.muse/\n.muse-fleet/\n' >> "$CLB/.git/info/exclude"
mkdir -p "$CLB/.muse-fleet/tasks/dup" "$LAB/v_clobber_wt"
printf 'diff --git a/calc.py b/calc.py\n+precious\n' > "$CLB/.muse-fleet/tasks/dup/patch.diff"
python3 - "$CLB" "$LAB/v_clobber_wt/old" <<'PY'
import json, sys
repo, wt = sys.argv[1], sys.argv[2]
json.dump({"id":"dup","repo":repo,"worktree":wt,"branch":"muse/old/dup",
           "rounds":[{"n":1}],"verdict":"accept","done":True},
          open(repo + "/.muse-fleet/tasks/dup/state.json","w"))
PY
CLBOUT=$(cd "$CLB" && python3 "$TASK" run --id dup --repo "$CLB" --prompt noop 2>/dev/null)
echo "$CLBOUT" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if d.get('status')=='refused' else 1)" \
  && ok "run refuses to clobber an existing task's patch" || bad "run clobbered an existing task" "$CLBOUT"
grep -q precious "$CLB/.muse-fleet/tasks/dup/patch.diff" \
  && ok "the existing patch survived the refusal" || bad "existing patch was destroyed"

# The central guarantee: `accept` means a check PASSED, not that some check once did.
# Observed in a real run -- a supervisor ran a cheap `--collect-only` gate (exit 0) and
# then the real acceptance check (exit 1), and "any passed" marked the task verified.
VER="$LAB/v_ver"; mkdir -p "$VER/.muse-fleet/tasks/gate"
cat > "$VER/.muse-fleet/tasks/gate/state.json" <<'JSON'
{"id":"gate","done":true,"verdict":"accept","max_rounds":3,"rounds":[{"n":1,"kind":"initial"}],
 "verifications":[{"after_round":1,"command":"pytest --collect-only","exit_code":0,"passed":true},
                  {"after_round":1,"command":"pytest -q","exit_code":1,"passed":false}]}
JSON
cat > "$VER/.muse-fleet/tasks/gate/task.json" <<'JSON'
{"id":"gate","verdict":"accept","patch_lines":5,"files_changed":["a.py"],"rounds_used":1,
 "verified_by_supervisor":true,
 "verifications":[{"after_round":1,"command":"pytest --collect-only","exit_code":0,"passed":true},
                  {"after_round":1,"command":"pytest -q","exit_code":1,"passed":false}]}
JSON
VEROUT=$(python3 "$SKILL/scripts/muse_status.py" --out "$VER/.muse-fleet" 2>&1)
echo "$VEROUT" | grep -q 'UNVERIFIED' \
  && ok "a gate-passed/check-failed task reads UNVERIFIED, not verified" \
  || bad "a failing final check read as verified" "$VEROUT"
echo "$VEROUT" | grep -q 'final check FAILED' \
  && ok "status distinguishes a failed check from no check at all" \
  || bad "wrong wording for a failed final check"

# A green check against a tree that is not the one harvested is the one case status
# cannot reconstruct from exit codes: from here the run looks perfect. `finish` writes
# an explicit false for it, so that false has to outrank the evidence in exactly this
# direction -- and only this one, so an old task.json's stale true cannot launder a red
# check into a green row.
STL="$LAB/v_stale"; mkdir -p "$STL/.muse-fleet/tasks/moved"
cat > "$STL/.muse-fleet/tasks/moved/state.json" <<'JSON'
{"id":"moved","done":true,"verdict":"accept","max_rounds":3,"rounds":[{"n":1,"kind":"initial"}],
 "verifications":[{"after_round":1,"command":"pytest -q","exit_code":0,"passed":true,
                   "patch_after":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}
JSON
cat > "$STL/.muse-fleet/tasks/moved/task.json" <<'JSON'
{"id":"moved","verdict":"accept","patch_lines":5,"files_changed":["a.py"],"rounds_used":1,
 "verified_by_supervisor":false,
 "verifications":[{"after_round":1,"command":"pytest -q","exit_code":0,"passed":true,
                   "patch_after":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}
JSON
STLOUT=$(python3 "$SKILL/scripts/muse_status.py" --out "$STL/.muse-fleet" 2>&1)
echo "$STLOUT" | grep -q 'UNVERIFIED' \
  && ok "a check that passed against a different tree reads UNVERIFIED" \
  || bad "a stale certification read as verified" "$STLOUT"

# The override is not a defect -- finish refuses without it -- but it is the one row a
# human has to read before merging, so it has to say why, not just flag a boolean.
OVR="$LAB/v_override"; mkdir -p "$OVR/.muse-fleet/tasks/xfail"
cat > "$OVR/.muse-fleet/tasks/xfail/state.json" <<'JSON'
{"id":"xfail","done":true,"verdict":"accept","max_rounds":3,"rounds":[{"n":1,"kind":"initial"}]}
JSON
cat > "$OVR/.muse-fleet/tasks/xfail/task.json" <<'JSON'
{"id":"xfail","verdict":"accept","patch_lines":5,"files_changed":["a.py"],"rounds_used":1,
 "verified_by_supervisor":false,"verifications":[],
 "accepted_unverified":"the check encodes the bug this patch fixes"}
JSON
OVROUT=$(python3 "$SKILL/scripts/muse_status.py" --out "$OVR/.muse-fleet" 2>&1)
echo "$OVROUT" | grep -q 'the check encodes the bug this patch fixes' \
  && ok "status quotes the reason an accept was overridden" \
  || bad "the override reason is not surfaced" "$OVROUT"

# #8 and #9 together: `accept` is GATED, not merely annotated. Every document in this
# repo says accept means a supervisor ran a check that passed ON THIS PATCH, and until
# now nothing enforced it -- this suite itself asserted that an accept with no check was
# allowed. Driven through the real CLI on a real worktree, because the guard this
# replaced greped muse_task.py for the gate's SHAPE, and a source grep stays green while
# the body is reverted.
GATE="$LAB/v_gate"; GATEWT="$LAB/v_gate_wt"
mkrepo "$GATE"; mkdir -p "$GATEWT"
printf '.muse-fleet/\n' >> "$GATE/.git/info/exclude"
GATESHA=$(git -C "$GATE" rev-parse --verify HEAD)
GOUT="$GATE/.muse-fleet/tasks"

gate_task() {   # gate_task <id> -- a task in the exact shape `run` leaves behind
  git -C "$GATE" worktree add -q -b "muse/gate/$1" "$GATEWT/$1" "$GATESHA"
  mkdir -p "$GOUT/$1"
  printf 'def added():\n    return 1\n' > "$GATEWT/$1/added.py"
  # The round's patch_fingerprint is stamped the way do_round stamps it -- through
  # muse_core, over the tree muse would have left -- so these fixtures cannot drift from
  # what a real round writes.
  python3 - "$GATE" "$GATEWT/$1" "$GATESHA" "$1" "$GOUT" <<'PY'
import importlib.util, json, os, pathlib, sys
spec = importlib.util.spec_from_file_location(
    "mc", os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_core.py"))
mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
repo, wt, sha, tid, out = sys.argv[1:6]
excludes = [".muse-fleet/", "build"]
# "HEAD" is what --base defaults to, and it is not interchangeable with "main" here:
# inside a worktree HEAD resolves to that worktree's own branch, so after finish
# --commit a diff against it is empty. That is the shape of the erasure these fixtures
# have to be able to reproduce.
json.dump({"id": tid, "repo": repo, "worktree": wt, "branch": "muse/gate/" + tid,
           "base": "HEAD", "base_sha": sha, "excludes": excludes,
           "rounds": [{"n": 1, "kind": "initial",
                       "patch_fingerprint": mc.patch_fingerprint(
                           pathlib.Path(wt), sha, excludes)}],
           "max_rounds": 3, "done": False},
          open(os.path.join(out, tid, "state.json"), "w", encoding="utf-8"))
PY
}

gate_json() {   # gate_json <emitted json> <python expr over d>
  echo "$1" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if ($2) else 1)"
}

gate_task gnone
GJ=$(python3 "$TASK" finish --id gnone --out "$GOUT" --verdict accept 2>/dev/null)
gate_json "$GJ" "d.get('status')=='refused' and d.get('passed') is False" \
  && ok "accept with no acceptance check at all is refused" \
  || bad "accepted a patch that nobody ever checked" "$GJ"

# The original sighting: a supervisor ran `--collect-only` (exit 0) and then the real
# check (exit 1). Under any-passed that task read verified.
gate_task gred
python3 "$TASK" verify --id gred --out "$GOUT" --command "true"   >/dev/null 2>&1
python3 "$TASK" verify --id gred --out "$GOUT" --command "exit 3" >/dev/null 2>&1
GJ=$(python3 "$TASK" finish --id gred --out "$GOUT" --verdict accept 2>/dev/null)
gate_json "$GJ" "d.get('status')=='refused' and d.get('passed') is False and 'exited 3' in (d.get('reason') or '')" \
  && ok "a cheap gate that passed cannot certify a real check that failed" \
  || bad "any-passed still certifies an accept" "$GJ"

# #8: the window between `verify` and `finish`. The check was green, then the tree moved
# -- a supervisor hand-edit, a stray build, a second agent -- and finish harvests a patch
# no check ever saw. The exit code alone cannot tell those apart; the tree hash can.
gate_task gstale
python3 "$TASK" verify --id gstale --out "$GOUT" --command "test -f added.py" >/dev/null 2>&1
printf 'SNEAKED = True\n' > "$GATEWT/gstale/sneaked.py"
GJ=$(python3 "$TASK" finish --id gstale --out "$GOUT" --verdict accept 2>/dev/null)
gate_json "$GJ" "d.get('status')=='refused' and d.get('passed') is True and d.get('stale') is True" \
  && ok "a tree edited after the check passed cannot be accepted on that check" \
  || bad "the harvested patch was never the one that was verified" "$GJ"

# The control. A gate that refuses everything passes the three tests above and is
# useless, so the legitimate path has to be shown to still go through.
gate_task gok
python3 "$TASK" verify --id gok --out "$GOUT" --command "test -f added.py" >/dev/null 2>&1
GJ=$(python3 "$TASK" finish --id gok --out "$GOUT" --verdict accept 2>/dev/null)
gate_json "$GJ" "d.get('verdict')=='accept' and d.get('verified_by_supervisor') is True" \
  && ok "a check that passed on this exact tree accepts" \
  || bad "the gate refuses a legitimately verified patch" "$GJ"

# Some correct patches make a check legitimately fail -- a strict xfail that starts
# XPASSing is the shipped example. The override exists so that case is recorded rather
# than laundered through a check that was made to pass.
gate_task gxfail
GJ=$(python3 "$TASK" finish --id gxfail --out "$GOUT" --verdict accept \
       --accept-unverified "the check encodes the bug this patch fixes" 2>/dev/null)
gate_json "$GJ" "d.get('verdict')=='accept' and d.get('verified_by_supervisor') is False and d.get('accepted_unverified')" \
  && ok "--accept-unverified records the override instead of faking a check" \
  || bad "the escape hatch either blocks or hides itself" "$GJ"

# A check is allowed to change the worktree. Builds, formatters, migrations and code
# generators all do, and pytest drops a __pycache__ into any tree that does not ignore
# one. Certifying the PATCH rather than the worktree, and fingerprinting AFTER the
# command rather than before, is what keeps every one of those from coming back refused.
gate_task gbuild
python3 "$TASK" verify --id gbuild --out "$GOUT" \
  --command "printf 'generated\\n' > built.txt; test -f added.py" >/dev/null 2>&1
GJ=$(python3 "$TASK" finish --id gbuild --out "$GOUT" --verdict accept 2>/dev/null)
gate_json "$GJ" "d.get('verdict')=='accept' and d.get('verified_by_supervisor') is True" \
  && ok "a check that writes into the worktree still certifies its own patch" \
  || bad "a check with side effects is refused as a TOCTOU" "$GJ"
gate_json "$GJ" "d.get('out_of_band_edit') is True and d.get('mutating_checks')" \
  && ok "the check that changed the patch is named, not folded into muse's work" \
  || bad "an acceptance check's writes were attributed to muse" "$GJ"

# The same write with nothing to account for it. This is #10's real shape: the supervisor
# has no Write or Edit tool and it has Bash, so a redirect into the worktree is a write
# that `finish` would otherwise harvest and report as muse's output.
gate_task gbash
printf 'HAND_WRITTEN = True\n' > "$GATEWT/gbash/by_hand.py"
python3 "$TASK" verify --id gbash --out "$GOUT" --command "test -f added.py" >/dev/null 2>&1
GJ=$(python3 "$TASK" finish --id gbash --out "$GOUT" --verdict accept 2>/dev/null)
gate_json "$GJ" "d.get('verdict')=='accept' and d.get('out_of_band_edit') is True and not d.get('mutating_checks')" \
  && ok "a hand-written file with no check to explain it is reported as out of band" \
  || bad "an out-of-band write passed as muse's output" "$GJ"

# The control for both: a task nobody touched must not be accused of anything. A flag
# that is always on is exactly as useless as one that never fires.
gate_json "$(cat "$GOUT/gok/task.json")" "d.get('out_of_band_edit') is False and not d.get('mutating_checks')" \
  && ok "an untouched worktree is not flagged as edited out of band" \
  || bad "out_of_band_edit fires on a clean task" "$(cat "$GOUT/gok/task.json")"

# Excluded paths are not part of the deliverable, so churn there cannot invalidate a
# check. `build/` here is excluded but NOT gitignored, which is the case that separates
# the two designs: a whole-worktree hash stages it and refuses the accept, a fingerprint
# of the patch never sees it. A check that compiles something is the everyday shape of
# this, and refusing every one of those would make the gate unusable.
gate_task gexcl
python3 "$TASK" verify --id gexcl --out "$GOUT" --command "test -f added.py" >/dev/null 2>&1
mkdir -p "$GATEWT/gexcl/build" && printf 'compiled\n' > "$GATEWT/gexcl/build/out.o"
mkdir -p "$GATEWT/gexcl/.muse-fleet" && printf 'noise\n' > "$GATEWT/gexcl/.muse-fleet/junk"
GJ=$(python3 "$TASK" finish --id gexcl --out "$GOUT" --verdict accept 2>/dev/null)
gate_json "$GJ" "d.get('verdict')=='accept' and d.get('verified_by_supervisor') is True and d.get('out_of_band_edit') is False" \
  && ok "churn in an excluded path invalidates nothing" \
  || bad "an excluded file broke the certification" "$GJ"

# The timeout path had no test at all, and the comment above it claimed a group kill
# that never happened: subprocess.run's timeout signals the direct child only, and
# start_new_session made that strictly worse by detaching the survivors into a session
# nothing could find afterwards. They keep writing into a worktree `finish --cleanup` is
# about to force-remove, and those writes land in the patch after the check was declared.
#
# Detected by consequence rather than by process listing, because pgrep is not portable
# and a surviving process that does nothing is not the problem: the grandchild appends to
# a file on a loop, and a tree that is really dead stops appending.
gate_task gkill
KILLMARK="$LAB/v_gate_survivor.txt"
: > "$KILLMARK"
KOUT=$(python3 "$TASK" verify --id gkill --out "$GOUT" --timeout 2 \
  --command "sh -c 'while : ; do printf . >> \"$KILLMARK\" ; sleep 0.1 ; done' & sleep 60" 2>/dev/null)
gate_json "$KOUT" "d.get('timed_out') is True and d.get('passed') is False" \
  && ok "a hung check times out as a parseable failure" || bad "timeout did not report" "$KOUT"
# The control for the guard itself: if the grandchild never ran, a dead-tree assertion
# passes for the wrong reason.
KILLED_AT=$(wc -c < "$KILLMARK" | tr -d ' ')
[ "$KILLED_AT" -gt 0 ] \
  && ok "the check really did spawn a grandchild that outlived its shell" \
  || bad "the survivor fixture never started, so the next check proves nothing"
sleep 2
KILLED_AFTER=$(wc -c < "$KILLMARK" | tr -d ' ')
[ "$KILLED_AFTER" -eq "$KILLED_AT" ] \
  && ok "a timed-out check leaves no survivors writing into the worktree" \
  || bad "grandchildren outlived the timeout" "grew from $KILLED_AT to $KILLED_AFTER bytes"

# The deliverable erased from every record, then the branch holding it reaped as
# finished. finish --commit advances the worktree HEAD after the harvest, and the second
# finish used to diff against the muse commit: 9 lines became 0, task.json reported an
# empty patch, and cleanup treats a finished task as safe to reap. Pinning the base to a
# sha closed that path; this holds it closed, because the symptom is silent.
gate_task gtwice
python3 "$TASK" verify --id gtwice --out "$GOUT" --command "test -f added.py" >/dev/null 2>&1
python3 "$TASK" finish --id gtwice --out "$GOUT" --verdict accept --commit --summary "first" >/dev/null 2>&1
TWICE_BYTES=$(wc -c < "$GOUT/gtwice/patch.diff" | tr -d ' ')
GJ=$(python3 "$TASK" finish --id gtwice --out "$GOUT" --verdict reject --summary "second" 2>/dev/null)
gate_json "$GJ" "d.get('status')=='refused' and d.get('verdict')=='accept'" \
  && ok "a second finish is refused rather than replacing the first verdict" \
  || bad "the second verdict overwrote the first" "$GJ"
# --force is the escape hatch, and the thing it must NOT do is lose the work. This is
# the original data-loss reproduction, run with the guard deliberately out of the way.
GJ=$(python3 "$TASK" finish --id gtwice --out "$GOUT" --verdict accept --force --summary "third" 2>/dev/null)
gate_json "$GJ" "d.get('patch_lines') and d.get('patch_lines') > 0" \
  && ok "a forced re-finish after --commit still sees the work" \
  || bad "the committed work vanished from the harvest" "$GJ"
[ "$(wc -c < "$GOUT/gtwice/patch.diff" | tr -d ' ')" -eq "$TWICE_BYTES" ] \
  && ok "patch.diff is byte-identical across the re-finish" \
  || bad "patch.diff changed size across a re-finish" \
      "was $TWICE_BYTES, now $(wc -c < "$GOUT/gtwice/patch.diff" | tr -d ' ')"

# A refusal is not a finish. The accept gate returns before `done` is set, so the path
# the gate tells a supervisor to take -- verify, then finish again -- must stay open.
python3 "$TASK" verify --id gnone --out "$GOUT" --command "test -f added.py" >/dev/null 2>&1
GJ=$(python3 "$TASK" finish --id gnone --out "$GOUT" --verdict accept 2>/dev/null)
gate_json "$GJ" "d.get('verdict')=='accept' and d.get('verified_by_supervisor') is True" \
  && ok "the recovery the gate prescribes is not blocked by the re-finish guard" \
  || bad "a refused accept locked the task out of finishing" "$GJ"

# Only `accept` claims verification. Gating `reject` would strand a task whose check
# never passed -- which is precisely the task most in need of a verdict.
gate_task greject
GJ=$(python3 "$TASK" finish --id greject --out "$GOUT" --verdict reject --summary "wrong approach" 2>/dev/null)
gate_json "$GJ" "d.get('verdict')=='reject' and d.get('verified_by_supervisor') is False" \
  && ok "a verdict that never claimed verification still finishes without a check" \
  || bad "the gate swallowed a non-accept verdict" "$GJ"

# A revision that could not resume is a silent quality problem -- the worker got feedback
# and a re-sent brief but no memory of its own attempt, so it is closer to a fresh try
# than a correction. It must be visible in the report, not buried in state.json.
CTX="$LAB/v_ctx"; mkdir -p "$CTX/.muse-fleet/tasks/lost"
cat > "$CTX/.muse-fleet/tasks/lost/state.json" <<'JSON'
{"id":"lost","done":true,"verdict":"accept","session_id":"s1","max_rounds":3,
 "rounds":[{"n":1,"kind":"initial","resumed":false},
           {"n":2,"kind":"revision","resumed":true},
           {"n":3,"kind":"revision","resumed":false}],
 "verifications":[{"after_round":3,"command":"true","exit_code":0,"passed":true}]}
JSON
CTXOUT=$(python3 "$SKILL/scripts/muse_status.py" --out "$CTX/.muse-fleet" 2>&1)
echo "$CTXOUT" | grep -q 'could not resume the muse session' \
  && ok "status flags a revision that lost its session context" \
  || bad "lost context not surfaced" "$CTXOUT"
# Round 1 is legitimately unresumed and round 2 did resume; naming either is a false alarm.
echo "$CTXOUT" | grep -q 'round(s) 3 could not resume' \
  && ok "status names only the revision that actually lost context" \
  || bad "wrong rounds named" "$(echo "$CTXOUT" | grep 'could not resume')"

# --artifacts rmtree's a path the user named. A typo must not take a directory with it,
# so the marker-file check is the only thing between a mistyped --out and real data loss.
mkdir -p "$SC/not-artifacts" && echo precious > "$SC/not-artifacts/data.txt"
(cd "$SC" && python3 "$SKILL/scripts/muse_cleanup.py" --repo . --out not-artifacts --yes --artifacts >/dev/null 2>&1)
[ -f "$SC/not-artifacts/data.txt" ] \
  && ok "cleanup refuses to delete a root with no task markers" || bad "DELETED a non-artifact dir"

# --help must not spill source: the old fixed line range printed `set -uo pipefail`.
bash "$SKILL/scripts/muse_ask.sh" --help 2>/dev/null | grep -q 'set -uo pipefail' \
  && bad "muse_ask.sh --help leaks source lines" || ok "muse_ask.sh --help prints only the header"

# The two hooks that speak. Both follow the discipline preflight.sh set -- silent unless
# there is something to say, and always exit 0, because a hook that can fail a session is
# worse than no hook -- so "silent" and "exit 0" are the two things most worth asserting,
# and a guard that only checks the loud path would miss both.
HK="$LAB/v_hooks"; mkrepo "$HK"
printf '.muse-fleet/\n' >> "$HK/.git/info/exclude"

# SessionEnd, nothing open. The control that the loud case below is not unconditional.
HQ=$(echo '{}' | CLAUDE_PROJECT_DIR="$HK" python3 "$SKILL/hooks/session_end.py" 2>&1)
HQRC=$?
[ -z "$HQ" ] && [ "$HQRC" -eq 0 ] \
  && ok "SessionEnd says nothing when no worktree is open" \
  || bad "SessionEnd is not silent on a clean project" "rc=$HQRC out=$HQ"

# SessionEnd with one of ours and one of the user's own. Only ours is our business.
git -C "$HK" worktree add -q -b "muse/20260101-aaaa/t1" "$LAB/v_hooks_wt1" HEAD
git -C "$HK" worktree add -q -b "my-own-feature" "$LAB/v_hooks_wt2" HEAD
HL=$(echo '{}' | CLAUDE_PROJECT_DIR="$HK" python3 "$SKILL/hooks/session_end.py" 2>&1)
HLRC=$?
[ "$HLRC" -eq 0 ] && ok "SessionEnd exits 0 even when it has something to say" \
  || bad "SessionEnd can fail a session" "rc=$HLRC"
echo "$HL" | grep -q 'muse/20260101-aaaa/t1' \
  && ok "SessionEnd names the delegation worktree still open" \
  || bad "an open worktree went unreported" "$HL"
echo "$HL" | grep -q 'my-own-feature' \
  && bad "SessionEnd reports the user's own worktrees" "$HL" \
  || ok "SessionEnd leaves the user's own worktrees alone"

# SubagentStop, the backstop for the path `finish` cannot close: the record is never
# written at all because the supervisor ran out of turns, was interrupted, or stopped and
# reported from memory.
mkdir -p "$HK/.muse-fleet/tasks/stopped" "$HK/.muse-fleet/tasks/clean"
cat > "$HK/.muse-fleet/tasks/stopped/state.json" <<'JSON'
{"id":"stopped","done":false,"rounds":[{"n":1,"kind":"initial","patch_lines":12}]}
JSON
cat > "$HK/.muse-fleet/tasks/clean/state.json" <<'JSON'
{"id":"clean","done":true,"verdict":"accept","rounds":[{"n":1,"kind":"initial"}]}
JSON
cat > "$HK/.muse-fleet/tasks/clean/task.json" <<'JSON'
{"id":"clean","verdict":"accept","verified_by_supervisor":true,"out_of_band_edit":false}
JSON
HS=$(echo '{}' | CLAUDE_PROJECT_DIR="$HK" python3 "$SKILL/hooks/supervisor_stop.py" 2>&1)
HSRC=$?
[ "$HSRC" -eq 0 ] && ok "SubagentStop reports without blocking the supervisor" \
  || bad "SubagentStop blocks or crashes" "rc=$HSRC out=$HS"
echo "$HS" | grep -q 'stopped' \
  && ok "a supervisor that stopped without a verdict is surfaced" \
  || bad "a verdict-less task went unmentioned" "$HS"
echo "$HS" | grep -q "^  - clean:" \
  && bad "SubagentStop complains about a properly verified task" "$HS" \
  || ok "a verified task produces no note"

# And the fully clean project: nothing to say, nothing said.
rm -rf "$HK/.muse-fleet/tasks/stopped"
HS2=$(echo '{}' | CLAUDE_PROJECT_DIR="$HK" python3 "$SKILL/hooks/supervisor_stop.py" 2>&1)
[ -z "$HS2" ] && ok "SubagentStop is silent when the artifacts are clean" \
  || bad "SubagentStop speaks on a clean run" "$HS2"

head_ "3c. Data-loss and process guards"

# harvest ignored git's exit status, so a missing worktree or a held index.lock
# overwrote a good patch.diff with an empty file and reported "no changes".
HVD="$LAB/v_harvest"; mkdir -p "$HVD"
printf 'diff --git a/x b/x\n+real work\n' > "$HVD/patch.diff"
python3 - "$HVD" <<'PY' && ok "a failed harvest reports an error and preserves the patch" || bad "harvest clobbered on failure"
import importlib.util, os, pathlib, sys
spec = importlib.util.spec_from_file_location("mc", os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_core.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
d = pathlib.Path(sys.argv[1])
rec = m.harvest(d / "does-not-exist", "HEAD", [], d / "patch.diff")
kept = "real work" in (d / "patch.diff").read_text()
sys.exit(0 if (rec["harvest_error"] and kept) else 1)
PY

# `git branch -D` discards unmerged commits without asking, and the branch name can
# belong to something that is not this task.
BRC="$LAB/v_branch"; mkrepo "$BRC"
printf '.muse-fleet/\n' >> "$BRC/.git/info/exclude"
git -C "$BRC" branch "muse/20260101-120000/taken" >/dev/null 2>&1
BOUT=$(cd "$BRC" && python3 "$TASK" run --id taken --stamp 20260101-120000 --repo "$BRC" --prompt noop 2>/dev/null)
echo "$BOUT" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if d.get('status')=='refused' else 1)" \
  && ok "run refuses a branch name it did not create" || bad "run would delete a foreign branch" "$BOUT"
git -C "$BRC" branch --format='%(refname:short)' | grep -q 'taken' \
  && ok "the foreign branch survived" || bad "foreign branch was deleted"

# "exists but unreadable" is not "absent": treating it as absent silently defeated the
# re-run guard and overwrote the patch.
CRP="$LAB/v_corrupt"; mkrepo "$CRP"
printf '.muse-fleet/\n' >> "$CRP/.git/info/exclude"
mkdir -p "$CRP/.muse-fleet/tasks/c"; printf '{"broken' > "$CRP/.muse-fleet/tasks/c/state.json"
COUT=$(cd "$CRP" && python3 "$TASK" run --id c --repo "$CRP" --prompt noop 2>/dev/null)
echo "$COUT" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if d.get('status')=='refused' else 1)" \
  && ok "corrupt task state refuses rather than reading as absent" || bad "corrupt state bypassed the guard" "$COUT"
SOUT=$(cd "$CRP" && python3 "$TASK" show --id c 2>/dev/null)
echo "$SOUT" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if d.get('status')=='state_corrupt' else 1)" \
  && ok "corrupt state emits JSON on every subcommand, not a traceback" || bad "load_state broke the JSON contract" "$SOUT"

python3 - <<'PY' && ok "a timed-out or unharvestable round exits non-zero" || bad "dead round reported success"
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("mt", os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_task.py"))
mt = importlib.util.module_from_spec(spec); spec.loader.exec_module(mt)
cases = [({"status": "completed"}, 0), ({"status": "timeout"}, 1),
         ({"status": "no_terminal"}, 1), ({"status": "completed", "harvest_error": "x"}, 1)]
sys.exit(0 if all(mt.round_exit_code(o) == w for o, w in cases) else 1)
PY

# The marker check alone answered "yes" for $HOME -- an unbounded walk meets some stray
# state.json eventually -- which made `--yes --artifacts --out ~` an rmtree of it.
python3 - <<'PY' && ok "cleanup refuses \$HOME, / and a repo root as an artifact root" || bad "dangerous root not refused"
import importlib.util, os, pathlib, sys
spec = importlib.util.spec_from_file_location("mcl", os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_cleanup.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
home = pathlib.Path(os.path.expanduser("~"))
repo = pathlib.Path(os.environ["PLUGIN_ROOT"])
checks = [m.refuse_dangerous_root(home, repo), m.refuse_dangerous_root(pathlib.Path("/"), repo),
          m.refuse_dangerous_root(repo, repo)]
sys.exit(0 if all(c is not None for c in checks) else 1)
PY

grep -q '"state.json"' "$SKILL/scripts/muse_fleet.py" && grep -q '"task.json"' "$SKILL/scripts/muse_fleet.py" \
  && ok "the fleet writes the artifacts status and cleanup key on" \
  || bad "fleet worktrees remain invisible to status/cleanup"

head_ "3d. Doctor and credential scan"
# A diagnostic that only works on a healthy machine is not a diagnostic.
DOC="$SKILL/scripts/muse_doctor.py"
DLAB="$LAB/v_doctor"; mkdir -p "$DLAB/empty"
make_muse_stub "$DLAB/stubbin"

# The doctor is the tool you reach for when things are ALREADY broken, so the property
# that matters is that it never dies on the way to telling you. It must survive a hostile
# machine, including a binary called `muse` that exits 0 and prints nothing -- which CI
# has, because section 3 stubs one, and which crashed it with an IndexError.
# Note: asserting "exits 0 here" would be asserting the HOST is healthy, which CI's is
# deliberately not. Test the behaviour, not the host.
DOC_CRASHED=""
for COND in "healthy" "stub" "bare"; do
  case "$COND" in
    healthy) DOUT=$(python3 "$DOC" --repo "$SKILL" 2>&1) ;;
    stub)    DOUT=$(env PATH="$(shell_path "$DLAB/stubbin"):$PATH" python3 "$DOC" --repo "$SKILL" 2>&1) ;;
    bare)    DOUT=$(env PATH="$(minimal_path)" MUSE_CONFIG_DIR="$DLAB/nocfg" \
                    MUSE_CATALOG_GLOB="$DLAB/nocat/*.json" python3 "$DOC" --repo "$DLAB/empty" 2>&1) ;;
  esac
  case "$DOUT" in
    *Traceback*) DOC_CRASHED="$DOC_CRASHED $COND(traceback)" ;;
  esac
  case "$DOUT" in
    *READY*|*"NOT READY"*) : ;;
    *) DOC_CRASHED="$DOC_CRASHED $COND(no verdict)" ;;
  esac
done
[ -z "$DOC_CRASHED" ] \
  && ok "doctor reaches a verdict on a healthy, stubbed and bare machine" \
  || bad "doctor crashed or gave no verdict" "$DOC_CRASHED"

env PATH="$(minimal_path)" MUSE_CONFIG_DIR="$DLAB/nocfg" python3 "$DOC" --repo "$DLAB/empty" >/dev/null 2>&1
[ $? -ne 0 ] && ok "doctor exits non-zero when something is blocking" || bad "doctor reported a broken machine as ready"

# Well-formed regardless of verdict: a consumer parses this to decide what to do about a
# machine that is, by definition, possibly broken.
for COND in "$SKILL" "$DLAB/empty"; do
  DJSON=$(env MUSE_CONFIG_DIR="$DLAB/nocfg" python3 "$DOC" --repo "$COND" --json 2>/dev/null)
  echo "$DJSON" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert isinstance(d.get('checks'), list) and d['checks']
assert {'severity','name','value','fix'} <= set(d['checks'][0])
assert isinstance(d.get('ready'), bool)
assert all(c['severity'] in ('OK','WARN','FAIL') for c in d['checks'])
" 2>/dev/null || { bad "doctor --json shape" "$DJSON"; DJSON_BAD=1; }
done
[ -z "${DJSON_BAD:-}" ] && ok "doctor --json is well-formed whatever the verdict" || true

# The credential scan is the one that must not leak what it found into an artifact.
SCANDIR="$LAB/v_scan"; mkdir -p "$SCANDIR/sub" "$SCANDIR/node_modules"
printf 'AKIAIOSFODNN7EXAMPLE\n' > "$SCANDIR/sub/creds.txt"
printf -- '-----BEGIN RSA PRIVATE KEY-----\n' > "$SCANDIR/k.pem"
printf 'password = "averylongplaceholder"\n' > "$SCANDIR/sub/maybe.py"
printf 'AKIAIOSFODNN7EXAMPLE\n' > "$SCANDIR/node_modules/vendor.txt"
printf 'def f():\n    return 1\n' > "$SCANDIR/sub/clean.py"
python3 - "$SCANDIR" <<'PY' && ok "secret scan separates certain from possible and leaks neither" || bad "secret scan"
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("mc", os.path.join(os.environ["PLUGIN_ROOT"], "scripts/muse_core.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
r = m.scan_secrets(sys.argv[1])
kinds = {f["kind"] for f in r["certain"]}
blob = json.dumps(r)
problems = []
if "AWS access key id" not in kinds: problems.append("missed AWS key")
if "private key block" not in kinds: problems.append("missed PEM header")
if not r["possible"]: problems.append("missed credential-shaped assignment")
if any("node_modules" in f["file"] for f in r["certain"]): problems.append("scanned node_modules")
if "AKIAIOSFODNN7EXAMPLE" in blob: problems.append("LEAKED the secret into its own findings")
if any("clean.py" in f["file"] for f in r["certain"]): problems.append("false positive on clean code")
if problems: print("        ", problems)
sys.exit(1 if problems else 0)
PY

# Refusing before spawning is the point: once sent, it is not undoable.
SECR="$LAB/v_secret"; mkrepo "$SECR"
printf '.muse-fleet/\n' >> "$SECR/.git/info/exclude"
printf 'AKIAIOSFODNN7EXAMPLE\n' > "$SECR/leaked.txt"
git -C "$SECR" add -A && git -C "$SECR" -c user.email=t@l -c user.name=t commit -qm creds >/dev/null 2>&1
SECOUT=$(cd "$SECR" && python3 "$TASK" run --id secret --repo "$SECR" --prompt noop 2>/dev/null)
echo "$SECOUT" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if d.get('status')=='refused' and d.get('secrets') else 1)" \
  && ok "run refuses to delegate a tree containing a confirmed credential" \
  || bad "run would have sent a credential" "$SECOUT"
[ "$(git -C "$SECR" worktree list | wc -l)" -eq 1 ] \
  && ok "the refused run left no worktree behind" || bad "refused run leaked a worktree"

# A partial scan and a clean scan used to be indistinguishable in every output: the flag
# was written into state.json and printed nowhere, the refusal quoted a count without
# saying the count was a floor, and doctor ignored it entirely. That is the exact failure
# mode this suite negative-controls everything else against, sitting on the one control
# between a private key and a tier whose own catalog says content may be used for
# training. Driven through the real cap, lowered by env rather than by synthesising 20k
# files -- the same seam the catalog tests use.
TRUNC="$LAB/v_truncated"; mkrepo "$TRUNC"
printf '.muse-fleet/\n' >> "$TRUNC/.git/info/exclude"
for i in 1 2 3 4 5 6; do printf 'harmless %s\n' "$i" > "$TRUNC/file$i.txt"; done
printf 'AKIAIOSFODNN7EXAMPLE\n' > "$TRUNC/zz-leaked.txt"
git -C "$TRUNC" add -A
git -C "$TRUNC" -c user.email=t@l -c user.name=t commit -qm many >/dev/null 2>&1
TROUT=$(cd "$TRUNC" && MUSE_SCAN_MAX_FILES=2 python3 "$TASK" run --id trunc --repo "$TRUNC" \
  --allow-secrets --prompt noop 2>&1 >/dev/null)
echo "$TROUT" | grep -q 'PARTIAL' \
  && ok "a truncated scan says so instead of reading as a clean one" \
  || bad "a partial scan is indistinguishable from a complete one" "$TROUT"
# And the same fact has to reach the machine-readable path, not only a human note.
# Captured rather than piped: doctor exits non-zero whenever anything FAILs, and under
# pipefail that status would be read as the assertion failing.
DOC_CAPPED=$(MUSE_SCAN_MAX_FILES=2 python3 "$SKILL/scripts/muse_doctor.py" \
  --repo "$TRUNC" --scan --json 2>/dev/null)
DOC_FULL=$(MUSE_SCAN_MAX_FILES=5000 python3 "$SKILL/scripts/muse_doctor.py" \
  --repo "$TRUNC" --scan --json 2>/dev/null)
echo "$DOC_CAPPED" | python3 -c "
import json,sys
c=[x for x in json.load(sys.stdin)['checks'] if x['name']=='credential scan']
sys.exit(0 if any(x['severity']=='WARN' and 'PARTIAL' in x['value'] for x in c) else 1)" \
  && ok "doctor reports a partial scan as a warning, not an OK" \
  || bad "doctor treats a truncated scan as a clean one" "$DOC_CAPPED"
# The control: the same repo, an uncapped scan, must NOT claim to be partial.
echo "$DOC_FULL" | python3 -c "
import json,sys
c=[x for x in json.load(sys.stdin)['checks'] if x['name']=='credential scan']
sys.exit(0 if c and not any('PARTIAL' in x['value'] for x in c) else 1)" \
  && ok "a scan that covered the tree is not labelled partial" \
  || bad "the partial label fires unconditionally" "$DOC_FULL"

# ------------------------------------------------------------ 4. live runs
if [ "$OFFLINE" = "1" ]; then
  printf '\n\033[33mSKIP\033[0m  sections 4+ (live muse runs) — --offline\n'
  printf '\n\033[1mRESULT: %d passed, %d failed (offline subset)\033[0m\n' "$PASS" "$FAIL"
  exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
fi

head_ "4. Live muse runs"
mkrepo "$LAB/v_live"
cat > "$LAB/v_live_tasks.json" <<'EOF'
[
 {"id":"mul","prompt":"Add multiply(a,b) to calc.py returning a*b. Minimal, nothing else."},
 {"id":"doc","prompt":"Create NOTES.md containing one sentence describing calc.py. Create no other file."}
]
EOF
python3 "$FLEET" --tasks "$LAB/v_live_tasks.json" --repo "$LAB/v_live" \
  --schema "$SKILL/assets/result-schema.json" --concurrency 2 --timeout 600 \
  > "$LAB/v_live.log" 2>&1
RC=$?
D=$(ls -d "$LAB/v_live/.muse-fleet"/*/ 2>/dev/null | tail -1)
STAMP1=$(basename "$D")

[ "$RC" -eq 0 ] && ok "fleet exited 0 (all tasks completed)" || bad "fleet exit=$RC" "$(tail -3 "$LAB/v_live.log")"
[ -z "$(git -C "$LAB/v_live" status --porcelain)" ] \
  && ok "main working copy stayed clean" || bad "main repo dirtied"
[ -f "$D/report.json" ] && ok "report.json written" || bad "no report.json"
[ -f "$D/report.md" ]   && ok "report.md written"   || bad "no report.md"

python3 - "$D" <<'PY' && ok "every task completed with a parsed result.json" || bad "task results"
import json,sys,os
d=sys.argv[1]; r=json.load(open(os.path.join(d,"report.json")))
bad=[t["id"] for t in r["tasks"] if t["status"]!="completed"]
missing=[t["id"] for t in r["tasks"] if not os.path.exists(os.path.join(d,t["id"],"result.json"))]
if bad or missing:
    print("        incomplete:",bad,"missing result.json:",missing); sys.exit(1)
PY

python3 - "$D" <<'PY' && ok "model recorded matches a contributor model" || bad "model record"
import json,sys,os
r=json.load(open(os.path.join(sys.argv[1],"report.json")))
sys.exit(0 if r["model"].endswith("-contributor") else 1)
PY

python3 - "$D" <<'PY' && ok "run_model_configured confirms the requested model" || bad "model actually used"
import json,sys,os
d=sys.argv[1]; r=json.load(open(os.path.join(d,"report.json")))
for t in r["tasks"]:
    if t.get("model_actual") and t["model_actual"]!=r["model"]:
        print("        asked",r["model"],"got",t["model_actual"]); sys.exit(1)
PY

for f in "$D"/*/patch.diff; do
  grep -qE '(^|/)\.venv/|node_modules/|__pycache__/' "$f" && { bad "build junk leaked into $(basename $(dirname $f))"; break; }
done
grep -rqE '(^|/)\.venv/' "$D"/*/patch.diff 2>/dev/null || ok "no build artifacts in any patch"

cd "$LAB/v_live"
APPLY_OK=1
for f in "$D"/*/patch.diff; do
  [ -s "$f" ] || continue
  git apply --check "$f" 2>/dev/null || APPLY_OK=0
done
[ "$APPLY_OK" -eq 1 ] && ok "all patches apply cleanly to base" || bad "a patch does not apply"
cd - >/dev/null

# This plugin's whole premise is cost arbitrage, and it reports no spend -- because muse
# exposes none. That is documented in README/CHANGELOG and in the issue as a hard block.
# The moment muse starts emitting usage, that documentation becomes false, and "find a
# doc that lies" is a defect class here. So this FAILS when the block lifts: the failure
# is the notification, and it costs nothing because it reads events the fleet already
# wrote.
python3 - "$D" <<'PY' && ok "muse still exposes no usage data (cost reporting stays blocked)" || bad "muse NOW EXPOSES USAGE — the docs claiming otherwise are stale"
import glob, os, re, sys
d = sys.argv[1]
found, scanned = {}, 0
for f in glob.glob(os.path.join(d, "*", "events.jsonl")):
    scanned += 1
    with open(f, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            # JSON KEYS only. The word "Usage:" appears in every --help banner and is not
            # what this is looking for.
            for m in re.finditer(r'"([a-z_]*(?:token|usage|cost)[a-z_]*)"\s*:', line, re.I):
                found[m.group(1)] = found.get(m.group(1), 0) + 1
if not scanned:
    print("        no events.jsonl to inspect — this probe checked nothing"); sys.exit(1)
if found:
    print("        usage-ish keys now present:", dict(list(found.items())[:8]))
    print("        Cost reporting is unblocked. Implement it in /muse:status and the")
    print("        fleet report, update README/CHANGELOG, and retire this check.")
    sys.exit(1)
sys.exit(0)
PY

head_ "5. Re-run safety"
python3 "$FLEET" --tasks "$LAB/v_live_tasks.json" --repo "$LAB/v_live" \
  --schema "$SKILL/assets/result-schema.json" --concurrency 2 --timeout 600 \
  --cleanup > "$LAB/v_live2.log" 2>&1
RC2=$?
[ "$RC2" -eq 0 ] && ok "second consecutive run succeeds (no branch/worktree collision)" \
  || bad "re-run exit=$RC2" "$(grep -i 'setup_failed\|already exists' "$LAB/v_live2.log" | head -2)"
# Only the --cleanup run's own artifacts should be gone. The first run deliberately
# ran without --cleanup, so its worktrees are expected to still be present.
STAMP2=$(basename "$(ls -d "$LAB/v_live/.muse-fleet"/*/ | tail -1)")
git -C "$LAB/v_live" worktree list | grep -q "$STAMP2" \
  && bad "--cleanup left its own worktrees ($STAMP2)" \
  || ok "--cleanup removed its own worktrees"
[ "$(git -C "$LAB/v_live" branch --list "fleet/$STAMP2/*" | wc -l | tr -d ' ')" = "0" ] \
  && ok "--cleanup removed its own branches" || bad "--cleanup left its own branches"
git -C "$LAB/v_live" worktree list | grep -q "$STAMP1" \
  && ok "run without --cleanup correctly retained its worktrees" \
  || bad "non-cleanup run lost its worktrees (harvest would be unrecoverable)"

head_ "6. Worktree seeding"
SEEDR="$LAB/v_seed"
mkrepo "$SEEDR"
# Deliberately NOT a credential-shaped value. An earlier version used
# API_KEY=secret123 and the probe asked the worker to write that value into a file --
# muse correctly refused to copy a secret, and the run failed as "seeding failed" even
# though .env had been copied in fine. The probe must test the mechanism, not the
# worker's willingness to handle credentials.
printf 'SEED_MARKER=seedok7391\n' > "$SEEDR/.env"
printf '.env\nnode_modules/\n' > "$SEEDR/.gitignore"
mkdir -p "$SEEDR/node_modules/pkg"; echo 1 > "$SEEDR/node_modules/pkg/i.js"
git -C "$SEEDR" add .gitignore
git -C "$SEEDR" -c user.email=t@l -c user.name=t commit -qm ignore

WT="$LAB/v_seed_wt"; rm -rf "$WT"
git -C "$SEEDR" worktree add -q -b seedprobe "$WT" main
[ ! -f "$WT/.env" ] && ok "fresh worktree correctly lacks untracked .env" \
  || bad "worktree unexpectedly had .env"
git -C "$SEEDR" worktree remove --force "$WT" 2>/dev/null; git -C "$SEEDR" branch -D seedprobe 2>/dev/null

cat > "$LAB/v_seed_tasks.json" <<'EOF'
[{"id":"envprobe","prompt":"If a .env file exists in this directory, create GOT.md containing exactly the value of SEED_MARKER. Otherwise create GOT.md containing MISSING. SEED_MARKER is a test fixture, not a credential."}]
EOF
python3 "$FLEET" --tasks "$LAB/v_seed_tasks.json" --repo "$SEEDR"   --seed .env --link node_modules --timeout 400 > "$LAB/v_seed.log" 2>&1
SD=$(ls -d "$SEEDR/.muse-fleet"/*/ | tail -1)
grep -q 'seedok7391' "$SD/envprobe/patch.diff" 2>/dev/null \
  && ok "--seed made .env readable inside the worktree" \
  || bad "seeding failed" "$(grep -h '^+' "$SD/envprobe/patch.diff" 2>/dev/null | head -2)"
grep -q '^+++ b/\.env' "$SD/envprobe/patch.diff" 2>/dev/null \
  && bad "seeded .env leaked into the patch" || ok "seeded .env did not leak into the patch"
grep -q 'node_modules' "$SD/envprobe/patch.diff" 2>/dev/null \
  && bad "linked node_modules leaked into the patch" || ok "linked node_modules did not leak"
python3 -c "
import json,sys
t=json.load(open('$SD/report.json'))['tasks'][0]
s=t.get('seeded') or []
sys.exit(0 if 'copied .env' in s and 'linked node_modules' in s else 1)" \
  && ok "report records what was seeded" || bad "seeded not recorded"

out=$(python3 "$FLEET" --tasks "$LAB/v_seed_tasks.json" --repo "$SEEDR" --allow-dirty 2>&1 | head -4)
echo "$out" | grep -q 'will NOT be in the worktrees' \
  && ok "warns about untracked files that will be absent" || bad "no seeding warning" "$out"

head_ "7. muse_ask.sh (single-shot)"
mkrepo "$LAB/v_ask"
ANS=$("$SKILL/scripts/muse_ask.sh" --repo "$LAB/v_ask" --effort low \
       "List the function names defined in calc.py, one per line. Nothing else." 2>"$LAB/v_ask.err")
RCA=$?
[ "$RCA" -eq 0 ] && ok "muse_ask exits 0 on success" || bad "muse_ask exit=$RCA" "$(cat "$LAB/v_ask.err")"
echo "$ANS" | grep -qi 'add' && ok "muse_ask returns a usable answer" || bad "muse_ask answer" "$ANS"
[ -z "$(git -C "$LAB/v_ask" status --porcelain)" ] \
  && ok "muse_ask read-only mode left the repo clean" || bad "muse_ask modified a read-only repo"

cat > "$LAB/v_ask_schema.json" <<'EOF'
{"type":"object","required":["functions"],"properties":{"functions":{"type":"array","items":{"type":"string"}}},"additionalProperties":false}
EOF
ANS2=$("$SKILL/scripts/muse_ask.sh" --repo "$LAB/v_ask" --effort low \
        --schema "$LAB/v_ask_schema.json" "List the function names defined in calc.py." 2>/dev/null)
echo "$ANS2" | python3 -c "
import json,sys
d=json.load(sys.stdin)
sys.exit(0 if isinstance(d.get('functions'),list) and d['functions'] else 1)" \
  && ok "muse_ask --schema returns parsed JSON" || bad "muse_ask schema" "$ANS2"

# NOT "hi": muse answers greetings from a local canned path in ~550ms without calling the
# provider, so a bogus model id is never validated and the run succeeds.
OUT=$("$SKILL/scripts/muse_ask.sh" --repo "$LAB/v_ask" --model muse-spark-9.9-contributor \
        "Reply with exactly: OK" 2>&1)
RCB=$?
[ "$RCB" -ne 0 ] && ok "muse_ask exits non-zero on a failed run" || bad "muse_ask masked a failure" "$OUT"

# Regression: the timeout watchdog must not inherit stdout, or command substitution
# stays blocked until the sleep expires even though muse exited seconds earlier.
TS=$(date +%s)
_=$("$SKILL/scripts/muse_ask.sh" --repo "$LAB/v_ask" --model muse-spark-9.9-contributor \
      --timeout 600 "Reply with exactly: OK" 2>/dev/null)
TE=$(( $(date +%s) - TS ))
[ "$TE" -lt 60 ] && ok "muse_ask returns as soon as muse exits (watchdog does not block \$( ))" \
  || bad "muse_ask blocked ${TE}s — watchdog is holding stdout"

# --------------------------------------------------- 8. the supervisor loop
# The architecture's load-bearing claim is that a revision round edits the PREVIOUS
# round's work rather than starting from a clean checkout. If that breaks, every
# multi-round task silently discards the work it was meant to build on, so this
# section exists to make that failure loud.
head_ "8. Supervised task loop (live)"
SLAB="$LAB/v_sup"; SOUT="$LAB/v_sup_out"; SWT="$LAB/v_sup_wt"
mkrepo "$SLAB"

R1=$(python3 "$TASK" run --id divide --out "$SOUT" --repo "$SLAB" --worktree-root "$SWT" \
       --max-rounds 2 --effort low \
       --prompt "Add a divide(a, b) function to calc.py returning a / b. Do not change add(). Create no other files." 2>/dev/null)
echo "$R1" | python3 -c "
import json,sys; d=json.load(sys.stdin)
sys.exit(0 if d['status']=='completed' and d['patch_lines']>0 else 1)" \
  && ok "run: muse produced a patch" || bad "run" "$R1"

V1=$(python3 "$TASK" verify --id divide --out "$SOUT" \
       --command "python3 -c 'import calc; print(calc.divide(10,2))'" 2>/dev/null)
echo "$V1" | python3 -c "
import json,sys; d=json.load(sys.stdin)
sys.exit(0 if d['passed'] and d['exit_code']==0 and d['after_round']==1 else 1)" \
  && ok "verify: check runs inside the worktree and is recorded" || bad "verify" "$V1"

R2=$(python3 "$TASK" revise --id divide --out "$SOUT" \
       --feedback "divide() must raise ValueError('division by zero') when b == 0. Keep all other behaviour." 2>/dev/null)
echo "$R2" | python3 -c "
import json,sys; d=json.load(sys.stdin)
sys.exit(0 if d['round']==2 and d['kind']=='revision' and d['status']=='completed' else 1)" \
  && ok "revise: second round ran in the same worktree" || bad "revise" "$R2"

# Both assertions in one command: the revision must be present AND round 1's work must
# have survived it. This is the regression that matters.
V2=$(python3 "$TASK" verify --id divide --out "$SOUT" --command "python3 -c \"
import calc
assert calc.divide(10,2) == 5
assert calc.add(1,2) == 3
try:
    calc.divide(1,0); raise SystemExit('no ValueError')
except ValueError: print('ok')
\"" 2>/dev/null)
echo "$V2" | python3 -c "
import json,sys; d=json.load(sys.stdin)
sys.exit(0 if d['passed'] else 1)" \
  && ok "revision is cumulative — round 1's work survived round 2" \
  || bad "revision clobbered round 1" "$V2"

BRK=$(python3 "$TASK" revise --id divide --out "$SOUT" --feedback "one more" 2>/dev/null)
echo "$BRK" | python3 -c "
import json,sys; d=json.load(sys.stdin)
sys.exit(0 if d['status']=='max_rounds_exhausted' else 1)" \
  && ok "max-rounds breaker refuses a third round" || bad "breaker did not fire" "$BRK"

FIN=$(python3 "$TASK" finish --id divide --out "$SOUT" --verdict accept --summary "divide added" 2>/dev/null)
echo "$FIN" | python3 -c "
import json,sys; d=json.load(sys.stdin)
sys.exit(0 if d['verdict']=='accept' and d['verified_by_supervisor'] and len(d['verifications'])==2 else 1)" \
  && ok "finish: verdict records the checks the supervisor actually ran" || bad "finish" "$FIN"

grep -q 'def divide' "$SLAB/calc.py" 2>/dev/null \
  && bad "task leaked into the source repo" \
  || ok "source repo untouched — work stayed in the worktree"

python3 "$TASK" cleanup --id divide --out "$SOUT" >/dev/null 2>&1
[ "$(git -C "$SLAB" worktree list | wc -l)" -eq 1 ] \
  && ok "cleanup removed the worktree" || bad "worktree left behind"

# An accept with no executed check is REFUSED, not merely flagged, and the refusal has to
# leave the task recoverable: --cleanup was requested here, and reaping the worktree on
# the way out would destroy the only copy of the work the supervisor was just told to go
# verify. Offline coverage of the gate is in section 3; this proves it holds on a task a
# real muse actually produced.
python3 "$TASK" run --id noverify --out "$SOUT" --repo "$SLAB" --worktree-root "$SWT" \
  --prompt "Add a noop() function to calc.py that returns None." >/dev/null 2>&1
NOVWT=$(python3 -c "
import json,sys
print(json.load(open(sys.argv[1]))['worktree'])" "$SOUT/noverify/state.json" 2>/dev/null)
FIN2=$(python3 "$TASK" finish --id noverify --out "$SOUT" --verdict accept --cleanup 2>/dev/null)
echo "$FIN2" | python3 -c "
import json,sys; d=json.load(sys.stdin)
sys.exit(0 if d.get('status')=='refused' and d.get('passed') is False else 1)" \
  && ok "a live accept with no executed check is refused" || bad "unverified accept was allowed" "$FIN2"
[ -n "$NOVWT" ] && [ -d "$NOVWT" ] \
  && ok "a refused finish leaves the worktree intact despite --cleanup" \
  || bad "the refusal reaped the work it asked the supervisor to go verify" "$NOVWT"

# The same task, once a check has actually run against that tree.
python3 "$TASK" verify --id noverify --out "$SOUT" --command "test -f calc.py" >/dev/null 2>&1
FIN3=$(python3 "$TASK" finish --id noverify --out "$SOUT" --verdict accept --cleanup 2>/dev/null)
echo "$FIN3" | python3 -c "
import json,sys; d=json.load(sys.stdin)
sys.exit(0 if d.get('verdict')=='accept' and d['verified_by_supervisor'] is True else 1)" \
  && ok "the same task accepts once a check has run on its tree" || bad "gate blocks a verified live task" "$FIN3"

head_ "9. Session resume (live)"
# The offline section proves the flag is wired. This proves muse actually remembers:
# the codeword exists ONLY in round 1's brief, never on disk, and the revision prompt
# does not restate it. If it lands in the patch, the conversation was continued.
SSLAB="$LAB/v_sess"; SSOUT="$SSLAB/.muse-fleet/tasks"
mkrepo "$SSLAB"
python3 "$TASK" run --id resume --out "$SSOUT" --repo "$SSLAB" --worktree-root "$LAB/v_sess_wt" \
  --prompt "Add a function named alpha_v1() to calc.py that returns the integer 7. Change nothing else. Also note this codeword for later: TIGERMOTH-9." \
  > "$LAB/v_sess1.json" 2>/dev/null
SID=$(python3 -c "import json;print(json.load(open('$LAB/v_sess1.json')).get('session_id') or '')" 2>/dev/null)
[ -n "$SID" ] && ok "run mints a session id and reports it" || bad "no session id on run"

python3 "$TASK" revise --id resume --out "$SSOUT" \
  --feedback "Add a Python comment line directly above alpha_v1 containing the codeword I gave you earlier. Nothing else." \
  > "$LAB/v_sess2.json" 2>/dev/null
python3 -c "
import json,sys
d=json.load(open('$LAB/v_sess2.json'))
sys.exit(0 if d.get('resumed') is True else 1)" \
  && ok "revise reports the session resumed" || bad "revise did not resume"

grep -q 'TIGERMOTH' "$SSOUT/resume/round-2/prompt.txt" \
  && bad "the revision prompt restated the brief (resume saved nothing)" \
  || ok "the revision prompt omits the brief"

grep -q 'TIGERMOTH' "$SSOUT/resume/patch.diff" \
  && ok "worker recalled a codeword that exists nowhere on disk" \
  || bad "codeword absent from patch — the session did not carry context"

# The safety path: muse does not error on an unknown session id, it silently starts fresh.
# A FRESH uuid every run. A hardcoded one stops being fake the moment an earlier run
# writes a real session under it -- which happened here, and muse then refused to resume
# it across workspaces instead of starting fresh, so the test measured the wrong thing.
DEADSID=$(python3 -c "import uuid;print(uuid.uuid4())")
python3 -c "
import json,sys
p='$SSOUT/resume/state.json'; st=json.load(open(p))
st['session_id']=sys.argv[1]
json.dump(st, open(p,'w'), indent=2)" "$DEADSID"
python3 "$TASK" revise --id resume --out "$SSOUT" \
  --feedback "Change the returned integer from 7 to 8." > "$LAB/v_sess3.json" 2>/dev/null
python3 -c "
import json,sys
d=json.load(open('$LAB/v_sess3.json'))
sys.exit(0 if d.get('resumed') is False and d.get('session_warning') else 1)" \
  && ok "an unresumable session is reported, not assumed" || bad "missing session went unreported"
grep -q 'TIGERMOTH' "$SSOUT/resume/round-3/prompt.txt" \
  && ok "fallback re-sends the full brief" || bad "fallback lost the brief"


printf '\n\033[1mRESULT: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
