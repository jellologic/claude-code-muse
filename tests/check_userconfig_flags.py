#!/usr/bin/env python3
"""Every script invocation in prose carries its userConfig substitutions.

The runtime substitutes ${user_config.KEY} into agent, skill and command bodies
only — references/ never get values, and a hard-coded flag silently overrides
whatever the user configured. So each `muse-task run`, `muse-fleet` and
`muse-ask --write` command line inside a fenced code block must carry every
required flag with exactly '${user_config.<mapped key>}' as its value, in
single quotes: an unsubstituted placeholder must reach the shell literally,
and double quotes make the shell fail with `bad substitution` before the
scripts ever see it. A double-quoted or bare placeholder is a miss, and the
workflow's single ${TASK} run line must carry every run flag as a JS
interpolation (${...}, optionally quoted), never a literal.

Run: python3 tests/check_userconfig_flags.py <repo-root>
  --self-test also fires the checker at mutated copies of REAL extracted lines
  (a deleted --max-rounds pair, a hard-coded effort) and fails unless each is
  flagged — a checker that cannot go red proves nothing.
"""

import pathlib
import re
import sys

RUN_FLAGS = {
    "--effort": "default_effort",
    "--max-rounds": "max_rounds",
    "--model": "default_model",
    "--worktree-root": "worktree_root",
    "--refuse-on-secrets": "refuse_on_secrets",
}
# muse-fleet has no round cap of its own; everything else rides along.
FLEET_FLAGS = {k: v for k, v in RUN_FLAGS.items() if k != "--max-rounds"}
# Only the --write form of muse-ask can edit, so only it needs the scan flags.
ASK_FLAGS = {
    "--effort": "default_effort",
    "--model": "default_model",
    "--refuse-on-secrets": "refuse_on_secrets",
}

RUN_RE = re.compile(r"(^|[;\s&|(`])muse-task\s+run(?=[\s\\]|$)")
FLEET_RE = re.compile(r"(^|[;\s&|(`])muse-fleet(?=[\s\\]|$)")
ASK_RE = re.compile(r"(^|[;\s&|(`])muse-ask\b")
# A value never starts with a dash: without that, a value-less boolean like
# --write swallows the next flag as its value and the real pair goes missing.
FLAG_RE = re.compile(r"--([a-z][a-z-]*)(?:\s*=\s*|\s+)(?P<q>\"?)"
                     r"(?P<val>[^\s\"\\-](?:[^\s\"\\]|\\.)*)(?P=q)")


def fenced_lines(text):
    """(lineno, line) for lines inside ``` fences; the fence may name a language."""
    inside = False
    for n, line in enumerate(text.splitlines(), 1):
        if line.strip().startswith("```"):
            inside = not inside
            continue
        if inside:
            yield n, line


def join_continuations(entries):
    """Fold backslash-continued lines; the reported lineno is the logical start."""
    out = []
    buf, start = None, 0
    for n, line in entries:
        stripped = line.rstrip()
        if buf is None:
            buf, start = stripped, n
        else:
            buf += " " + stripped.lstrip()
        if buf.endswith("\\"):
            buf = buf[:-1].rstrip()
        else:
            out.append((start, buf))
            buf = None
    if buf is not None:
        out.append((start, buf))
    return out


def iter_md_commands(root):
    """Yield (path, lineno, kind, text) for each command line under test."""
    files = (sorted((root / "agents").glob("*.md"))
             + sorted((root / "commands").glob("*.md"))
             + sorted((root / "skills").glob("*/SKILL.md")))
    for path in files:
        text = path.read_text(encoding="utf-8")
        if not text.strip():
            continue
        for n, line in join_continuations(list(fenced_lines(text))):
            if RUN_RE.search(line):
                yield str(path), n, "run", line
            elif FLEET_RE.search(line):
                yield str(path), n, "fleet", line
            elif ASK_RE.search(line) and ("--write" in line or "[--write]" in line):
                yield str(path), n, "ask", line


def check_md_line(kind, line):
    """Missing flags or wrongly quoted values on one md command line.

    Each value must be exactly '${user_config.<key>}' with single quotes: the
    FLAG_RE quote group captures an optional double quote, so a single-quoted
    value arrives as val WITH its quotes while a double-quoted one arrives
    without them — comparing against the single-quoted want separates the
    two cases, and a bare placeholder never matches either.
    """
    required = {"run": RUN_FLAGS, "fleet": FLEET_FLAGS, "ask": ASK_FLAGS}[kind]
    found = {}
    for m in FLAG_RE.finditer(line):
        q, val = m.group("q"), m.group("val")
        found["--" + m.group(1)] = (q + val + q) if q else val
    misses = []
    for flag, key in required.items():
        want = "'${user_config.%s}'" % key
        if flag not in found:
            misses.append("missing %s (want %s)" % (flag, want))
        elif found[flag] != want:
            misses.append("%s=%s must be single-quoted %s"
                          % (flag, found[flag], want))
    return misses


def iter_workflow_runs(root):
    """(lineno, text) for the template-literal ${TASK} run lines."""
    path = root / "workflows" / "muse-supervised-fleet.js"
    out = []
    for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if "${TASK} run" in line:
            out.append((n, line.strip()))
    return out


def check_workflow_line(line):
    """Each run flag present as a JS interpolation, never a literal."""
    found = {}
    for m in FLAG_RE.finditer(line):
        found["--" + m.group(1)] = m.group("val")
    misses = []
    for flag in RUN_FLAGS:
        if flag not in found:
            misses.append("missing %s" % flag)
        elif not re.fullmatch(r'"?\$\{[^}]+\}"?', found[flag]):
            misses.append("%s=%r is a literal, not a ${...} interpolation"
                          % (flag, found[flag]))
    return misses


def check_repo(root):
    """Full scan; returns (misses, counts) where misses are file:line strings."""
    misses = []
    counts = {"run": 0, "fleet": 0, "ask": 0, "workflow": 0}
    for path, n, kind, line in iter_md_commands(root):
        counts[kind] += 1
        for miss in check_md_line(kind, line):
            misses.append("%s:%d: [%s] %s\n    %s" % (path, n, kind, miss, line.strip()))
    for n, line in iter_workflow_runs(root):
        counts["workflow"] += 1
        for miss in check_workflow_line(line):
            misses.append("workflows/muse-supervised-fleet.js:%d: [run] %s\n    %s"
                          % (n, miss, line.strip()))
    if counts["run"] < 1 or counts["fleet"] < 1 or counts["ask"] < 1:
        misses.append("checker saw nothing: run=%d fleet=%d ask=%d — "
                      "it is measuring no input" % (counts["run"], counts["fleet"],
                                                    counts["ask"]))
    if counts["workflow"] != 1:
        misses.append("checker saw %d workflow ${TASK} run lines, want exactly 1"
                      % counts["workflow"])
    return misses, counts


def self_test(root):
    """Fire the checker at mutated REAL lines; fail unless every probe is caught."""
    problems = []
    run_lines = [(p, n, l) for p, n, k, l in iter_md_commands(root) if k == "run"]
    fleet_lines = [(p, n, l) for p, n, k, l in iter_md_commands(root) if k == "fleet"]
    if not run_lines or not fleet_lines:
        return ["self-test has no real run/fleet line to mutate"]
    _, _, run = run_lines[0]
    # Probe 1: delete the --max-rounds pair from a real run line.
    cut = re.sub(r"\s*--max-rounds(\s*=\s*|\s+)(?:\"[^\"]*\"|\S+)", "", run)
    if cut == run or not check_md_line("run", cut):
        problems.append("deleting --max-rounds from a real run line was not flagged")
    # Probe 2: hard-code the effort on a real run line.
    hard = re.sub(r"--effort(\s*=\s*|\s+)(?:\"[^\"]*\"|\S+)", r"--effort\1low", run)
    if hard == run or not check_md_line("run", hard):
        problems.append("a hard-coded --effort low on a real run line was not flagged")
    # Probe 3: the same deletion on a real fleet line.
    _, _, fleet = fleet_lines[0]
    cut_f = re.sub(r"\s*--model(\s*=\s*|\s+)(?:\"[^\"]*\"|\S+)", "", fleet)
    if cut_f == fleet or not check_md_line("fleet", cut_f):
        problems.append("deleting --model from a real fleet line was not flagged")
    # Probe 4: a double-quoted placeholder on a real run line must be flagged.
    dq = re.sub(r"'(\$\{user_config\.[A-Za-z0-9_]+\})'", r'"\1"', run)
    if dq == run or not check_md_line("run", dq):
        problems.append("a double-quoted placeholder on a real run line was not flagged")
    # Probe 5: a bare placeholder on a real run line must be flagged.
    bare = re.sub(r"'(\$\{user_config\.[A-Za-z0-9_]+\})'", r"\1", run)
    if bare == run or not check_md_line("run", bare):
        problems.append("a bare placeholder on a real run line was not flagged")
    return problems


def main(argv):
    root = pathlib.Path(argv[1]) if len(argv) > 1 else pathlib.Path(".")
    misses, counts = check_repo(root)
    if misses:
        sys.stdout.write("\n".join(misses) + "\n")
        return 1
    if "--self-test" in argv:
        problems = self_test(root)
        if problems:
            sys.stdout.write("\n".join(problems) + "\n")
            return 1
        sys.stdout.write("self-test: 5 probes fired on real lines "
                         "(run=%d fleet=%d ask=%d workflow=%d)\n" % (
                             counts["run"], counts["fleet"],
                             counts["ask"], counts["workflow"]))
        return 0
    sys.stdout.write("all command lines carry their userConfig flags "
                     "(run=%d fleet=%d ask=%d workflow=%d)\n" % (
                         counts["run"], counts["fleet"],
                         counts["ask"], counts["workflow"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
