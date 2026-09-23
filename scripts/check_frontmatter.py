#!/usr/bin/env python3
"""Allowlist checker for component frontmatter. Stdlib only.

`claude plugin validate --strict` walks the commands, agents and skills from
the plugin manifest but rejects only frontmatter that fails to PARSE as YAML
(measured on 2.1.280): a misspelled key, a wrong value type, and keys the
platform silently ignores on plugin agents all pass it. This script holds the
keys and value types instead, and it runs in the offline suite so it needs
nothing beyond the stdlib -- in particular no PyYAML, hence the minimal
parser below.
"""

import difflib
import re
import sys
from pathlib import Path

SKILL_KEYS = COMMAND_KEYS = (
    "name",
    "description",
    "when_to_use",
    "allowed-tools",
    "disallowed-tools",
    "disable-model-invocation",
    "user-invocable",
    "model",
    "effort",
    "context",
    "agent",
    "argument-hint",
    "arguments",
    "paths",
    "version",
)
AGENT_KEYS = (
    "name",
    "description",
    "tools",
    "disallowedTools",
    "model",
    "effort",
    "maxTurns",
    "skills",
    "memory",
    "background",
    "isolation",
    "color",
)
# Accepted by the YAML parse but silently dropped on plugin agents, so each
# one is reported as its own problem rather than as an unknown key.
AGENT_IGNORED = ("hooks", "mcpServers", "permissionMode")

BOOL_KEYS = frozenset(["disable-model-invocation", "user-invocable", "background"])
INT_KEYS = frozenset(["maxTurns"])
ENUMS = {
    "effort": frozenset(["low", "medium", "high", "xhigh", "max"]),
    "memory": frozenset(["user", "project", "local"]),
    "isolation": frozenset(["worktree"]),
}
LIST_OR_STRING_KEYS = frozenset(
    [
        "allowed-tools",
        "disallowed-tools",
        "tools",
        "disallowedTools",
        "skills",
        "paths",
        "arguments",
    ]
)

_KEY_RE = re.compile(r"^([A-Za-z][A-Za-z0-9_-]*):(.*)$")
_INT_RE = re.compile(r"^[1-9][0-9]*$")
_BLOCK_RE = re.compile(r"^[|>][+-]?$")
_LIST_ITEM_RE = re.compile(r"^\s*-\s+")


class _Quoted(str):
    """A scalar that carried one layer of '' or "" quotes in the source.

    A plain str subclass so value comparisons still work, but the checker can
    tell `"true"` (a string that happens to read true) from `true` (a bool).
    """


def _unquoted(text):
    text = text.strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in ("'", '"'):
        return text[1:-1]
    return text


def _scalar(text):
    text = text.strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in ("'", '"'):
        return _Quoted(text[1:-1])
    return text


def _indented(line):
    return line[:1] in (" ", "\t")


def parse_frontmatter(text):
    """Split the frontmatter block into values. Returns (dict, problems).

    Values are str for scalars and block strings, list of str for `- item`
    and `[a, b]` lists, and "" for a key with no value and no indented
    children. Problems are plain strings; most name the key they concern.
    """
    text = text.replace("\r\n", "\n")
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        return {}, ["no frontmatter block"]
    end = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end = i
            break
    if end is None:
        return {}, ["no frontmatter block"]
    head = lines[1:end]
    values = {}
    problems = []
    seen = set()
    i = 0
    while i < len(head):
        line = head[i]
        # Indented lines are block/list continuations consumed with their key;
        # a stray one at top level belongs to nothing, so skip it.
        if line.strip() == "" or line.startswith("#") or _indented(line):
            i += 1
            continue
        m = _KEY_RE.match(line)
        if not m:
            problems.append("unparseable line: %r" % line)
            i += 1
            continue
        key, rest = m.group(1), m.group(2)
        if key in seen:
            problems.append("%s: duplicate key" % key)
            # Keep the first occurrence so a doubled key cannot smuggle a
            # second value past the type checks below; still advance below.
        seen.add(key)
        s = rest.strip()
        if _BLOCK_RE.match(s):
            # `|`, `|-`, `>`, `>-`, with an optional `+`: the value is the
            # following indented lines, e.g. the multi-line description.
            buf = []
            i += 1
            while i < len(head) and (head[i].strip() == "" or _indented(head[i])):
                buf.append(head[i])
                i += 1
            if key not in values:
                values[key] = "\n".join(buf)
            continue
        if s == "":
            buf = []
            j = i + 1
            while j < len(head) and (head[j].strip() == "" or _indented(head[j])):
                buf.append(head[j])
                j += 1
            content = [b for b in buf if b.strip() != ""]
            if key not in values:
                if content and all(_LIST_ITEM_RE.match(b) for b in content):
                    values[key] = [_unquoted(_LIST_ITEM_RE.sub("", b)) for b in content]
                elif content:
                    values[key] = "\n".join(buf)
                else:
                    values[key] = ""
            i = j
            continue
        if s.startswith("[") and s.endswith("]"):
            inner = s[1:-1].strip()
            if key not in values:
                if inner == "":
                    values[key] = []
                else:
                    values[key] = [_unquoted(p) for p in inner.split(",")]
            i += 1
            continue
        if key not in values:
            values[key] = _scalar(s)
        i += 1
    return values, problems


def check_text(kind, text, rel):
    """Check one component's frontmatter. Returns ["rel: key: reason", ...]."""
    allow = AGENT_KEYS if kind == "agent" else SKILL_KEYS
    allowed = set(allow)
    values, problems = parse_frontmatter(text)
    out = ["%s: %s" % (rel, p) for p in problems]
    for key, val in values.items():
        if kind == "agent" and key in AGENT_IGNORED:
            out.append(
                "%s: %s: ignored for plugin agents "
                "-- accepted by the parse, silently dropped at runtime" % (rel, key)
            )
            continue
        if key not in allowed:
            hint = ""
            close = difflib.get_close_matches(key, list(allow), n=1, cutoff=0.8)
            if close:
                hint = " (did you mean %s?)" % close[0]
            out.append("%s: %s: unknown key%s" % (rel, key, hint))
            continue
        if isinstance(val, list):
            if key not in LIST_OR_STRING_KEYS:
                out.append("%s: %s: must be a string, not a list" % (rel, key))
            continue
        if key in BOOL_KEYS:
            if isinstance(val, _Quoted) or val not in ("true", "false"):
                out.append(
                    "%s: %s: must be the unquoted literal true or false, got %r"
                    % (rel, key, val)
                )
        elif key in INT_KEYS:
            if isinstance(val, _Quoted) or not _INT_RE.match(val):
                out.append(
                    "%s: %s: must be a positive integer, got %r" % (rel, key, val)
                )
        elif key in ENUMS:
            # A quoted enum is still the YAML string it names, so unlike bools
            # (where `"true"` is a string, not a bool) it validates by content.
            if val not in ENUMS[key]:
                out.append(
                    "%s: %s: must be one of %s, got %r"
                    % (rel, key, sorted(ENUMS[key]), val)
                )
        # Every other allowed key takes a string: a scalar or a block both
        # pass, and an empty value is left alone -- only typed keys (bool,
        # int, enum) fail on empty, which the branches above already enforce
        # since "" matches none of their grammars.
    return out


def _fm(*lines):
    return "---\n" + "\n".join(lines) + "\n---\n\nbody\n"


_GOOD = {
    "command": _fm(
        "description: Ask one question",
        'argument-hint: "[--write] <question>"',
        "disable-model-invocation: true",
        "allowed-tools: Bash, Read",
        "model: haiku",
    ),
    "agent": _fm(
        "name: muse-supervisor",
        "description: |",
        "  Own one delegated task end to end.",
        "",
        "  <example>",
        "  Context: one bounded task offloaded.",
        '  user: "Write tests for parser.py"',
        '  assistant: "I will supervise that task."',
        "  </example>",
        "model: opus",
        "effort: high",
        "maxTurns: 60",
        "color: magenta",
        'tools: ["Bash", "Read", "Grep", "Glob"]',
    ),
    "skill": _fm(
        "name: muse-fleet",
        "description: >-",
        "  Fan work out across supervised workers.",
        "  Requires the muse binary on PATH.",
        "allowed-tools: Bash, Read, Grep, Glob",
        # Quoted form of a valid enum member: the self-test must keep passing
        # this, so refusing quoted enums can never regress silently.
        "effort: \"medium\"",
    ),
}

_BAD = [
    ("command", _fm("description: probe", "disable-model-invocaton: true"),
     "probe", "disable-model-invocaton"),
    ("agent", _fm("description: probe", "maxTurns: sixty"), "probe", "maxTurns"),
    ("agent", _fm("description: probe", "permissionMode: acceptEdits"),
     "probe", "permissionMode"),
    ("agent", _fm("description: probe", "hooks:", "  onEvent: x"), "probe", "hooks"),
    ("agent", _fm("description: probe", "mcpServers: {}"), "probe", "mcpServers"),
    ("agent", _fm("description: probe", "background: maybe"), "probe", "background"),
    ("skill", _fm("description: probe", "effort: extreme"), "probe", "effort"),
    ("skill", _fm("description: probe", "bogus-key: x"), "probe", "bogus-key"),
    ("command", _fm("description: probe", 'user-invocable: "true"'),
     "probe", "user-invocable"),
]


def self_test(checker=check_text):
    """Exercise checker against in-memory probes. Returns [failures]."""
    failures = []
    for kind, text, rel, key in _BAD:
        try:
            found = checker(kind, text, rel)
        except Exception as e:  # noqa: BLE001 -- a raising checker is a finding
            failures.append("%s probe: checker raised %r" % (key, e))
            continue
        if not any(key in p for p in found):
            failures.append(
                "%s probe: checker reported nothing naming %r (got %r)" % (key, key, found)
            )
    for kind, text in _GOOD.items():
        try:
            found = checker(kind, text, "good-%s.md" % kind)
        except Exception as e:  # noqa: BLE001 -- see above
            failures.append("good %s probe: checker raised %r" % (kind, e))
            continue
        if found:
            failures.append(
                "good %s probe: expected zero problems, got %r" % (kind, found)
            )
    return failures


def _components(root):
    found = []
    for sub, kind, pattern in (
        ("commands", "command", "*.md"),
        ("agents", "agent", "*.md"),
    ):
        d = root / sub
        if d.is_dir():
            for f in sorted(d.glob(pattern)):
                found.append((f, kind))
    skills = root / "skills"
    if skills.is_dir():
        for f in sorted(skills.glob("*/SKILL.md")):
            found.append((f, "skill"))
    return found


def main(argv):
    args = argv[1:]
    root = None
    self_only = False
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "--self-test":
            self_only = True
            i += 1
        elif arg == "--root" and i + 1 < len(args):
            root = args[i + 1]
            i += 2
        elif arg.startswith("--root="):
            root = arg[len("--root="):]
            i += 1
        else:
            print("usage: check_frontmatter.py [--root DIR] [--self-test]", file=sys.stderr)
            return 2
    if self_only:
        failures = self_test()
        for f in failures:
            print("self-test: " + f)
        return 3 if failures else 0
    # A checker that inspects nothing passes exactly like one that found
    # nothing, so the self-test runs first and vetoes the whole scan.
    failures = self_test()
    if failures:
        for f in failures:
            print("self-test: " + f)
        return 3
    if root is None:
        root = str(Path(__file__).resolve().parent.parent)
    r = Path(root)
    comps = _components(r)
    if not comps:
        print("no component files found under %s -- measuring nothing" % root)
        return 2
    problems = []
    for path, kind in comps:
        rel = path.relative_to(r).as_posix()
        text = path.read_text(encoding="utf-8").replace("\r\n", "\n")
        problems.extend(check_text(kind, text, rel))
    if problems:
        for p in problems:
            print(p)
        return 1
    print("checked %d files" % len(comps))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
