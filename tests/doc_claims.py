#!/usr/bin/env python3
"""Hold prose doc claims against the code: counts, hook events, flags.

Numbers in prose rot, so each subcommand below measures the code side and
compares it with what the docs say. Every prose pattern with no match is a
failure, not a pass: a check that inspects nothing passes exactly like a
check that found nothing. Stdlib only, Python 3.9 compatible.

Subcommands (each takes the plugin ROOT so probes can point at a mutated copy):

  counts ROOT   command / shim / auto-triggering-surface counts in prose
                against commands/, bin/ and skills+agents+workflows.
                One stdout line per mismatch; exit nonzero on any.
  events ROOT   hook events named in README.md against the keys of
                hooks/hooks.json. One line per mismatch; exit nonzero.
  flags  ROOT   (shim, subcommand, flag) triples named in prose, one per
                line, tab-separated. The caller checks each against the
                shim's own --help, so this subcommand always exits 0.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

NUMBER_WORDS = {
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
    "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
    "twelve": 12,
}

KNOWN_EVENTS = (
    "SessionStart", "SessionEnd", "SubagentStart", "SubagentStop", "Stop",
    "PreToolUse", "PostToolUse", "UserPromptSubmit", "Notification",
    "PreCompact",
)

TASK_SUBCOMMANDS = ("run", "revise", "verify", "show", "finish", "cleanup")

FLAG_RE = re.compile(r"--[a-z][a-z0-9-]*")
SHIM_RE = re.compile(r"muse-([A-Za-z0-9-]+)")
SPAN_RE = re.compile(r"`([^`\n]*)`")
FENCE_RE = re.compile(r"```[^\n]*\n(.*?)```", re.S)
QUOTE_RE = re.compile(r'"[^"]*"')
SQUOTE_RE = re.compile(r"'[^']*'")


def number_value(word):
    """A number word (one..twelve, any case) or digits to int, else None."""
    if word is None:
        return None
    low = word.lower()
    if low in NUMBER_WORDS:
        return NUMBER_WORDS[low]
    if word.isdigit():
        return int(word)
    return None


def read(root, rel):
    return (root / rel).read_text(encoding="utf-8")


def frontmatter_of(path):
    """Frontmatter lines of a component file, or [] when it has none."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return []
    lines = text.replace("\r\n", "\n").split("\n")
    if not lines or lines[0].strip() != "---":
        return []
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            return lines[1:i]
    return []


def has_opt_out(path):
    """Whether the frontmatter carries `disable-model-invocation: true`."""
    for line in frontmatter_of(path):
        if re.match(r"^disable-model-invocation:\s*true\s*$", line):
            return True
    return False


def do_counts(root):
    problems = []

    # (a) COMMANDS: the code side is the files in commands/.
    cmd_files = sorted(p.stem for p in (root / "commands").glob("*.md"))
    code_n = len(cmd_files)
    readme = read(root, "README.md")
    skill = read(root, "skills/muse-fleet/SKILL.md")
    agents_doc = read(root, "AGENTS.md")

    rows = re.findall(r"^\| `/muse:([A-Za-z0-9_-]+)", readme, re.M)
    if len(rows) != code_n:
        problems.append(
            "COMMANDS: README.md lists %d `/muse:` table rows %s but "
            "commands/ holds %d files: %s"
            % (len(rows), sorted(set(rows)), code_n, cmd_files))

    m = re.search(r"(\w+) commands you type", skill)
    if m is None:
        problems.append(
            "COMMANDS: skills/muse-fleet/SKILL.md has no "
            "'<word> commands you type' phrase to hold the count")
    elif number_value(m.group(1)) != code_n:
        problems.append(
            "COMMANDS: SKILL.md says '%s commands you type' but commands/ "
            "holds %d files: %s" % (m.group(1), code_n, cmd_files))

    m2 = re.search(r"The (\w+) `/muse:\*` commands", agents_doc)
    if m2 is None:
        problems.append(
            "COMMANDS: AGENTS.md has no 'The <word> `/muse:*` commands' "
            "phrase to hold the count")
    elif number_value(m2.group(1)) != code_n:
        problems.append(
            "COMMANDS: AGENTS.md says 'The %s `/muse:*` commands' but "
            "commands/ holds %d files: %s" % (m2.group(1), code_n, cmd_files))

    # The sentence starting with that phrase must name exactly the commands.
    if m is not None:
        seg = skill[m.start():]
        cut = seg.find("\u2014 one agent")
        if cut != -1:
            seg = seg[:cut]
        named = set(re.findall(r"/muse:([A-Za-z0-9_-]+)", seg))
        if named != set(cmd_files):
            problems.append(
                "COMMANDS: SKILL.md prose names %s but commands/ holds %s: "
                "extra %s, missing %s"
                % (sorted(named), cmd_files, sorted(named - set(cmd_files)),
                   sorted(set(cmd_files) - named)))

    # (b) SHIMS: the code side is the files in bin/.
    bin_dir = root / "bin"
    try:
        bin_files = sorted(p.name for p in bin_dir.iterdir() if p.is_file())
    except OSError:
        bin_files = []
    for rel in ("README.md", "AGENTS.md"):
        text = read(root, rel)
        found = re.findall(r"(\w+) shims", text, re.I)
        if not found:
            problems.append(
                "SHIMS: %s has no '<word> shims' phrase to hold the count"
                % rel)
            continue
        for word in found:
            val = number_value(word)
            if val is None:
                problems.append(
                    "SHIMS: %s says '%s shims', which names no number"
                    % (rel, word))
            elif val != len(bin_files):
                problems.append(
                    "SHIMS: %s says '%s shims' but bin/ holds %d files: %s"
                    % (rel, word, len(bin_files), bin_files))

    # (c) SURFACES: skills and opt-in commands that can fire untyped, plus
    # every agent and every registered workflow script.
    items = []
    skills_dir = root / "skills"
    if skills_dir.is_dir():
        for f in sorted(skills_dir.glob("*/SKILL.md")):
            if not has_opt_out(f):
                items.append(f.relative_to(root).as_posix())
    for f in sorted((root / "commands").glob("*.md")):
        if not has_opt_out(f):
            items.append(f.relative_to(root).as_posix())
    for f in sorted((root / "agents").glob("*.md")):
        items.append(f.relative_to(root).as_posix())
    for f in sorted((root / "workflows").glob("*.js")):
        try:
            js = f.read_text(encoding="utf-8")
        except OSError:
            continue
        if "export const meta" in js:
            items.append(f.relative_to(root).as_posix())
    code_s = len(items)

    ms = re.search(r"(\w+) surfaces can fire without a slash command", readme)
    if ms is None:
        problems.append(
            "SURFACES: README.md has no '<word> surfaces can fire without a "
            "slash command' phrase to hold the count")
    elif number_value(ms.group(1)) != code_s:
        problems.append(
            "SURFACES: README.md says '%s surfaces can fire without a slash "
            "command' but the code counts %d: %s"
            % (ms.group(1), code_s, items))

    found_a = re.findall(r"(\w+) auto-triggering surfaces", agents_doc, re.I)
    if not found_a:
        problems.append(
            "SURFACES: AGENTS.md has no '<word> auto-triggering surfaces' "
            "phrase to hold the count")
    for word in found_a:
        val = number_value(word)
        if val is None:
            problems.append(
                "SURFACES: AGENTS.md says '%s auto-triggering surfaces', "
                "which names no number" % word)
        elif val != code_s:
            problems.append(
                "SURFACES: AGENTS.md says '%s auto-triggering surfaces' but "
                "the code counts %d: %s" % (word, code_s, items))

    for p in problems:
        print(p)
    return 1 if problems else 0


def do_events(root):
    problems = []
    readme = read(root, "README.md")
    named = [k for k in KNOWN_EVENTS if re.search(r"\b%s\b" % k, readme)]
    try:
        hooks = json.loads((root / "hooks" / "hooks.json")
                           .read_text(encoding="utf-8"))["hooks"]
        registered = list(hooks.keys())
    except (OSError, ValueError, KeyError, AttributeError):
        registered = []
    if not registered:
        problems.append("EVENTS: hooks/hooks.json registers zero hook events")
    if not named:
        problems.append("EVENTS: README.md names zero hook events")
    for extra in sorted(set(named) - set(registered)):
        problems.append(
            "EVENTS: README.md names hook event '%s', which is not "
            "registered in hooks/hooks.json" % extra)
    for missing in sorted(set(registered) - set(named)):
        problems.append(
            "EVENTS: hooks/hooks.json registers '%s', which README.md never "
            "names" % missing)
    for p in problems:
        print(p)
    return 1 if problems else 0


def scan_units(text):
    """Inline backtick spans plus logical lines of fenced code blocks."""
    units = SPAN_RE.findall(text)
    for block in FENCE_RE.findall(text):
        # A trailing backslash continues the command on the next line.
        logical = []
        buf = ""
        for line in block.split("\n"):
            stripped = line.rstrip()
            if stripped.endswith("\\"):
                buf += stripped[:-1] + " "
            else:
                logical.append(buf + line)
                buf = ""
        if buf:
            logical.append(buf)
        units.extend(logical)
    return units


def flags_in_unit(unit, bin_names):
    """(shim, subcommand, flag) triples in one span or logical line."""
    out = set()
    clean = SQUOTE_RE.sub("", QUOTE_RE.sub("", unit))
    for m in SHIM_RE.finditer(clean):
        shim = "muse-" + m.group(1)
        if shim not in bin_names:
            continue
        # Command position: span/line start, or after |, ; or &&. Anything
        # else (a grant list, a path, prose) is a mention, not an invocation.
        prefix = clean[:m.start()].rstrip()
        if prefix != "" and not prefix.endswith(("|", ";", "&&")):
            continue
        rest = clean[m.end():]
        toks = rest.split()
        sub = ""
        if shim == "muse-task" and toks:
            first = toks[0].strip("[(").rstrip("],).:;\"'")
            if first in TASK_SUBCOMMANDS:
                sub = first
                toks = toks[1:]
        for tok in toks:
            if tok in ("|", ";", "&&") or tok.startswith("#"):
                break
            flag = tok.strip("[(").rstrip("],).:;\"'")
            if FLAG_RE.fullmatch(flag):
                out.add((shim, sub, flag))
    return out


def do_flags(root):
    try:
        bin_names = set(p.name for p in (root / "bin").iterdir()
                        if p.is_file())
    except OSError:
        bin_names = set()
    rels = ["README.md", "AGENTS.md", "CONTRIBUTING.md", "SECURITY.md"]
    skills_dir = root / "skills"
    if skills_dir.is_dir():
        rels.extend(sorted(p.relative_to(root).as_posix()
                           for p in skills_dir.glob("*/SKILL.md")))
    rels.extend(sorted(p.relative_to(root).as_posix()
                       for p in (root / "commands").glob("*.md")))
    rels.extend(sorted(p.relative_to(root).as_posix()
                       for p in (root / "agents").glob("*.md")))
    refs_dir = root / "references"
    if refs_dir.is_dir():
        rels.extend(sorted(p.relative_to(root).as_posix()
                           for p in refs_dir.glob("*.md")))
    triples = set()
    for rel in rels:
        try:
            text = (root / rel).read_text(encoding="utf-8")
        except OSError:
            continue
        for unit in scan_units(text):
            triples.update(flags_in_unit(unit, bin_names))
    for shim, sub, flag in sorted(triples):
        sys.stdout.write("%s\t%s\t%s\n" % (shim, sub, flag))
    return 0


def main(argv):
    if len(argv) != 3 or argv[1] not in ("counts", "events", "flags"):
        sys.stderr.write("usage: doc_claims.py {counts|events|flags} ROOT\n")
        return 2
    root = Path(argv[2])
    if argv[1] == "counts":
        return do_counts(root)
    if argv[1] == "events":
        return do_events(root)
    return do_flags(root)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
