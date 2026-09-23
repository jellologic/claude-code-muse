#!/usr/bin/env python3
# The allowed-tools rule in scripts/validate.sh ("component frontmatter holds
# the contract") could only run against the real repo, so no probe could show
# it still fires. This file holds that heredoc body verbatim; a probe hands it
# a scratch root with a doctored SKILL.md and watches it refuse.
import json, os, pathlib, re, sys

ROOT = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(os.environ["PLUGIN_ROOT"])

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
else:
    # allowed-tools PRE-APPROVES what it lists: an auto-triggering skill may only
    # pre-approve the read-only status/doctor shims, never a writer, an agent or
    # a workflow.
    for _e in [x.strip() for x in skill["allowed-tools"].split(",")]:
        if _e in ("Bash", "Agent", "Task", "Workflow", "Write", "Edit",
                  "MultiEdit", "NotebookEdit"):
            problems.append("the auto-triggering skill pre-approves %r: an "
                            "inferred trigger must prompt for that" % _e)
        elif _e.startswith("Bash(") and _e not in ("Bash(muse-status:*)",
                                                   "Bash(muse-doctor:*)"):
            problems.append("the auto-triggering skill pre-approves %r: an "
                            "inferred trigger must prompt for that" % _e)

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
