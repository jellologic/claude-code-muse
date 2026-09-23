#!/usr/bin/env python3
"""Hold the field-notes model measurement against command frontmatter.

references/field-notes.md records which frontmatter `model:` values were
actually observed serving a turn; every commands/*.md file carrying a
`model:` line must have a measured table row showing that model serving a
command turn, or the prose and the code have drifted apart. Stdlib only,
Python 3.9 compatible. Reads files only; takes the plugin ROOT.

Usage: python3 tests/model_claims.py ROOT
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

HEADING = "## Measured: model frontmatter on commands and skills"
HEADER = "| Mode | Surface | Frontmatter model | Served by | Command |"
SEPARATOR = "|---|---|---|---|---|"


def read_text(path):
    """File text with CRLF normalised, so Windows checkouts parse the same."""
    with open(str(path), "r", encoding="utf-8") as fh:
        return fh.read().replace("\r\n", "\n").replace("\r", "\n")


def section_lines(text):
    """Lines of the measurement section, or None when the heading is absent."""
    lines = text.split("\n")
    start = None
    for i, line in enumerate(lines):
        if line.strip() == HEADING:
            start = i
            break
    if start is None:
        return None
    out = []
    for line in lines[start + 1:]:
        # The section ends at the next level-2 heading; a deeper heading or
        # body text belongs to it.
        if line.startswith("## "):
            break
        out.append(line)
    return out


def parse_rows(lines, errors):
    """Data rows of the measurement table. Appends ROW-format errors."""
    rows = []
    header_at = None
    for i, line in enumerate(lines):
        if line.strip() == HEADER:
            header_at = i
            break
    if header_at is None:
        errors.append("TABLE: missing header row `%s`" % HEADER)
        return rows
    body = lines[header_at + 1:]
    if not body or body[0].strip() != SEPARATOR:
        errors.append("TABLE: missing separator row `%s`" % SEPARATOR)
        return rows
    for line in body[1:]:
        stripped = line.strip()
        if not stripped.startswith("|"):
            continue
        # The Command cell must never contain a literal pipe: cells are split
        # naively on `|`, so a pipe inside a cell would silently shift every
        # column after it instead of failing loudly.
        parts = [cell.strip() for cell in stripped.split("|")]
        if len(parts) != 7 or parts[0] != "" or parts[-1] != "":
            errors.append("ROW: malformed table row (want 5 cells): %s"
                          % stripped)
            continue
        rows.append({
            "mode": parts[1],
            "surface": parts[2],
            "frontmatter": parts[3],
            "served": parts[4],
            "command": parts[5],
        })
    return rows


def frontmatter_model(path):
    """The `model:` value in a command file's frontmatter, or None."""
    try:
        text = read_text(path)
    except OSError:
        return None
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        return None
    for line in lines[1:]:
        if line.strip() == "---":
            break
        m = re.match(r"^model:(.*)$", line)
        if not m:
            continue
        # Strip a YAML comment: `#` starts one only when unquoted and
        # preceded by whitespace, so `haiku#x` stays a value while
        # `haiku # cheap` ends at the `#`.
        rest = m.group(1)
        cut = None
        in_single = False
        in_double = False
        for i, ch in enumerate(rest):
            if ch == "'" and not in_double:
                in_single = not in_single
            elif ch == '"' and not in_single:
                in_double = not in_double
            elif ch == "#" and not in_single and not in_double:
                if i > 0 and rest[i - 1] in (" ", "\t"):
                    cut = i
                    break
        if cut is not None:
            rest = rest[:cut]
        rest = rest.strip()
        if not rest:
            return None
        # Strip one pair of matching surrounding quotes.
        if len(rest) >= 2 and ((rest[0] == '"' and rest[-1] == '"')
                               or (rest[0] == "'" and rest[-1] == "'")):
            rest = rest[1:-1]
        if not rest:
            return None
        return rest
    return None


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: model_claims.py ROOT\n")
        return 2
    root = Path(argv[1])
    errors = []

    try:
        notes = read_text(root / "references" / "field-notes.md")
    except OSError as exc:
        print("SECTION: cannot read references/field-notes.md: %s" % exc)
        return 1
    sec = section_lines(notes)
    if sec is None:
        print("SECTION: missing `%s` in references/field-notes.md" % HEADING)
        return 1

    rows = parse_rows(sec, errors)
    for row in rows:
        if not row["command"] or "claude" not in row["command"]:
            errors.append("ROW: command cell must name the claude invocation "
                          "run: %s" % row["surface"])
    measured = [r for r in rows if "not measured" not in r["served"]]
    if len(measured) < 5:
        errors.append("ROWS: only %d measured data rows, need at least 5 "
                      "(default, acceptEdits, bypassPermissions, auto, "
                      "plan)" % len(measured))

    allowed_modes = ("default", "acceptEdits", "bypassPermissions",
                     "auto", "plan")
    for row in rows:
        mode = row["mode"].split(",")[-1].strip()
        if mode not in allowed_modes:
            errors.append("MODES: unknown mode %r in row: %s"
                          % (row["mode"], row["surface"]))
    have_modes = set()
    for row in measured:
        have_modes.add(row["mode"].split(",")[-1].strip())
    for mode in allowed_modes:
        if mode not in have_modes:
            errors.append("MODES: no measured row for mode %r" % mode)
    for row in measured:
        m = re.search(r"--permission-mode\s+(\S+)", row["command"])
        if m is None or m.group(1) != row["mode"].split(",")[-1].strip():
            errors.append("MODES: command cell disagrees with mode %r: %s"
                          % (row["mode"], row["command"]))

    try:
        changelog = read_text(root / "CHANGELOG.md")
    except OSError as exc:
        changelog = None
        errors.append("CHANGELOG: cannot read CHANGELOG.md: %s" % exc)
    if changelog is not None:
        bullets = []
        current = None
        for line in changelog.split("\n"):
            # A bullet runs until the next bullet, a blank line or a heading.
            if line.startswith("- "):
                if current is not None:
                    bullets.append("\n".join(current))
                current = [line]
            elif line.strip() == "" or line.startswith("#"):
                if current is not None:
                    bullets.append("\n".join(current))
                    current = None
            elif current is not None:
                current.append(line)
        if current is not None:
            bullets.append("\n".join(current))
        picked = [b for b in bullets
                  if "model: haiku" in b and "#57" in b]
        if len(picked) != 1:
            errors.append("CHANGELOG: want exactly 1 bullet with "
                          "`model: haiku` and `#57`, found %d"
                          % len(picked))
        else:
            bullet = picked[0]
            if "unverified" in bullet:
                errors.append("CHANGELOG: bullet still says unverified")
            for mode in sorted(have_modes):
                if not re.search(r"\b%s\b" % re.escape(mode), bullet):
                    errors.append("CHANGELOG: bullet names no measured "
                                  "mode %r" % mode)
            if any("haiku" not in r["served"].lower() for r in measured) \
                    and "session model" not in bullet:
                errors.append("CHANGELOG: bullet lacks `session model` "
                              "though a measured row kept it")
            for row in measured:
                if "haiku" in row["served"].lower() \
                        and row["served"] not in bullet:
                    errors.append("CHANGELOG: bullet lacks measured "
                                  "haiku model %r" % row["served"])

    try:
        cmd_files = sorted((root / "commands").glob("*.md"))
    except OSError:
        cmd_files = []
    with_model = []
    for path in cmd_files:
        value = frontmatter_model(path)
        if value is not None:
            with_model.append((path.name, value))
    for name, value in with_model:
        hit = any(r["surface"].startswith("command")
                  and r["frontmatter"] == value
                  and value.lower() in r["served"].lower()
                  for r in measured)
        if not hit:
            errors.append(
                "FRONTMATTER: commands/%s sets model: %s but no measured row "
                "shows %s serving a command turn" % (name, value, value))
    if not any(r["surface"].startswith("skill") for r in measured):
        errors.append("CONTROL: no measured skill row; the control proving "
                      "the table can tell haiku from the session model is "
                      "missing")

    if errors:
        for line in errors:
            # One error per line; callers grep these, so keep them single.
            print(line.split("\n")[0])
        return 1
    print("checked %d rows, %d command files with model:"
          % (len(rows), len(with_model)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
