#!/usr/bin/env python3
"""Offline helper for tests/test_evals.sh. Stdlib only, Python 3.9 compatible.

Subcommands:
  validate <casedir>   parse case.yaml with the strict fallback parser (and with
                       PyYAML when importable, asserting both agree), then check
                       every schema rule plus prompt.md and graders/*.md.
  expect <name> <workdir>
                       per-case fixture expectations on a scaffolded workdir.
                       Unknown case names fail, so new cases must add an entry.
"""
import json
import os
import re
import subprocess
import sys

TOP_KEYS = {"schema_version", "name", "description", "tags", "plugins", "runs",
            "expected_outcome", "context", "execution", "graders"}
CTX_KEYS = {"scaffold_script", "history_file", "add_dirs"}
EXE_KEYS = {"prompt", "max_turns", "timeout_seconds", "model", "allowed_tools",
            "append_system_prompt", "env"}
ENV_KEY_RE = re.compile(r"^EVAL_[A-Z0-9_]*$")


def parse_scalar(value, path, lineno):
    v = value.strip()
    if v[:1] in ("|", ">", "{", "&", "*", "!", "%", "@", "`"):
        raise ValueError("%s:%d: outside the restricted subset: %r"
                         % (path, lineno, value))
    if v.startswith("- ") or v == "-":
        raise ValueError("%s:%d: block lists are outside the subset" % (path, lineno))
    if v.startswith("["):
        if not v.endswith("]"):
            raise ValueError("%s:%d: unbalanced flow list" % (path, lineno))
        inner = v[1:-1].strip()
        if not inner:
            return []
        return [parse_scalar(item, path, lineno) for item in inner.split(",")]
    if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
        return v[1:-1]
    try:
        return int(v)
    except ValueError:
        pass
    if v in ("true", "false", "null", "~", "True", "False", "None"):
        raise ValueError("%s:%d: YAML keywords are outside the subset "
                         "(quote them if meant as strings)" % (path, lineno))
    return v


def parse_restricted(text, path):
    """Parse the restricted subset: `key: scalar` lines, flow lists, and maps
    nested at exact 2-space steps. Anything else raises ValueError."""
    root = {}
    stack = [(root, -1)]
    for lineno, raw in enumerate(text.splitlines(), 1):
        if not raw.strip() or raw.strip().startswith("#"):
            continue
        stripped = raw.strip()
        indent = len(raw) - len(raw.lstrip(" "))
        if "\t" in raw or indent % 2 != 0:
            raise ValueError("%s:%d: indent must be a multiple of 2 spaces"
                             % (path, lineno))
        if ":" not in stripped:
            raise ValueError("%s:%d: not a `key: scalar` line: %r"
                             % (path, lineno, stripped))
        key, value = stripped.split(":", 1)
        key = key.strip()
        if not key or re.search(r"\s", key):
            raise ValueError("%s:%d: bad key: %r" % (path, lineno, key))
        while stack and indent <= stack[-1][1]:
            stack.pop()
        parent = stack[-1][0]
        if key in parent:
            raise ValueError("%s:%d: duplicate key %r" % (path, lineno, key))
        if not value.strip():
            child = {}
            parent[key] = child
            stack.append((child, indent))
        else:
            parent[key] = parse_scalar(value, path, lineno)
    return root


def load_case(casedir):
    """Return (doc, errors). doc is None when nothing could be parsed."""
    errors = []
    cypath = os.path.join(casedir, "case.yaml")
    try:
        with open(cypath, encoding="utf-8") as fh:
            text = fh.read()
    except OSError as e:
        return None, ["cannot read case.yaml: %s" % e]
    try:
        doc = parse_restricted(text, "case.yaml")
    except ValueError as e:
        return None, [str(e)]
    try:
        import yaml  # type: ignore
    except ImportError:
        yaml = None  # noqa: F841
        if os.environ.get("CI") == "true":
            errors.append("PyYAML absent under CI=true -- "
                          "the real case.yaml parse did not run")
        return doc, errors
    import yaml as ymod
    try:
        ref = ymod.safe_load(text)
    except Exception as e:
        errors.append("PyYAML rejects case.yaml: %s" % str(e).splitlines()[0])
        return doc, errors
    if ref != doc:
        errors.append("fallback parse disagrees with PyYAML: %r vs %r"
                      % (doc, ref))
    return doc, errors


def grader_frontmatter(path):
    """Read the simple top-level keys of a grader's frontmatter, ignoring the
    indented criteria body."""
    out = {}
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        return out
    if not text.startswith("---\n"):
        return out
    parts = text.split("---\n", 2)
    if len(parts) < 3:
        return out
    for line in parts[1].splitlines():
        if not line.strip() or line.startswith((" ", "\t", "#")):
            continue
        if ":" not in line:
            continue
        k, v = line.split(":", 1)
        out[k.strip()] = v.strip().strip("'\"")
    return out


def cmd_validate(casedir):
    name = os.path.basename(os.path.abspath(casedir))
    errors = []
    doc, errs = load_case(casedir)
    errors.extend(errs)
    if doc is None:
        return errors or ["no parseable case.yaml"]
    for key in doc:
        if key not in TOP_KEYS:
            errors.append("top-level key %r not in the schema" % key)
    sv = doc.get("schema_version")
    if not isinstance(sv, str):
        errors.append("schema_version must be a string")
    else:
        try:
            major = int(sv.split(".")[0])
        except ValueError:
            major = 99
        if major > 1:
            errors.append("schema_version major must be <= 1, got %r" % sv)
    if doc.get("name") != name:
        errors.append("name %r != dir %r" % (doc.get("name"), name))
    runs = doc.get("runs")
    if not isinstance(runs, int) or isinstance(runs, bool) \
            or not 1 <= runs <= 50:
        errors.append("runs must be an int 1..50, got %r" % (runs,))
    tags = doc.get("tags")
    want = "negative" if name.startswith("negative-") else "positive"
    if not isinstance(tags, list) or tags != [want]:
        errors.append("tags must be [%s], got %r" % (want, tags))
    ctx = doc.get("context")
    if not isinstance(ctx, dict):
        errors.append("context must be a map")
        ctx = {}
    for key in ctx:
        if key not in CTX_KEYS:
            errors.append("context key %r not in the schema" % key)
    sc = ctx.get("scaffold_script")
    if not isinstance(sc, str) or os.path.isabs(sc) or ".." in sc.split("/"):
        errors.append("scaffold_script must be a relative in-dir path, got %r"
                      % (sc,))
    elif not os.path.isfile(os.path.join(casedir, sc)):
        errors.append("scaffold_script %r missing from the case dir" % sc)
    exe = doc.get("execution")
    if not isinstance(exe, dict):
        errors.append("execution must be a map")
        exe = {}
    for key in exe:
        if key not in EXE_KEYS:
            errors.append("execution key %r not in the schema" % key)
    mt = exe.get("max_turns")
    if not isinstance(mt, int) or isinstance(mt, bool) or not 1 <= mt <= 200:
        errors.append("max_turns must be an int 1..200, got %r" % (mt,))
    ts = exe.get("timeout_seconds")
    if not isinstance(ts, int) or isinstance(ts, bool) or not 1 <= ts <= 3600:
        errors.append("timeout_seconds must be an int 1..3600, got %r" % (ts,))
    tools = exe.get("allowed_tools")
    if not isinstance(tools, list) or not tools \
            or not all(isinstance(t, str) for t in tools):
        errors.append("allowed_tools must be a non-empty string list, got %r"
                      % (tools,))
    else:
        if "Skill" not in tools:
            errors.append("allowed_tools must include Skill, got %r" % (tools,))
        # Bash, Edit and Write are gated by the CLI: evals.yml and the README
        # pass them via a trailing --allow-tools, so any case may list them.
    # execution.env is optional now that the stub travels on the operator's
    # PATH. When present it mirrors the CLI: only EVAL_* keys are accepted
    # (anything else is refused at run time), so only EVAL_* validate here.
    env = exe.get("env")
    if env is None:
        env = {}
    if not isinstance(env, dict):
        errors.append("execution.env must be a map")
        env = {}
    for k, v in env.items():
        if not ENV_KEY_RE.match(k):
            errors.append("env key %r must match ^EVAL_[A-Z0-9_]*$" % k)
        if not isinstance(v, str):
            errors.append("env value for %r must be a string" % k)
    pm = os.path.join(casedir, "prompt.md")
    try:
        with open(pm, encoding="utf-8") as fh:
            body = fh.read()
    except OSError:
        body = ""
        errors.append("prompt.md missing")
    if body and body.startswith("---\n"):
        errors.append("prompt.md must be body only (frontmatter belongs in "
                      "case.yaml)")
    if not body.strip():
        errors.append("prompt.md body is empty")
    gdir = os.path.join(casedir, "graders")
    try:
        gfiles = sorted(f for f in os.listdir(gdir) if f.endswith(".md"))
    except OSError:
        gfiles = []
    if not gfiles:
        errors.append("no graders/*.md")
    kinds = [grader_frontmatter(os.path.join(gdir, f)) for f in gfiles]
    tool_gs = [g for g in kinds if g.get("type") == "tool_used"
               and g.get("tool") == "Skill"]
    if not tool_gs:
        errors.append("no tool_used Skill grader")
    else:
        tg = tool_gs[0]
        if not tg.get("input_match"):
            errors.append("tool_used grader has no input_match")
        try:
            lo = int(tg.get("min", ""))
        except ValueError:
            lo = None
            errors.append("tool_used grader min is not an int: %r" % (tg,))
        try:
            hi = int(tg["max"]) if "max" in tg else None
        except ValueError:
            hi = None
            errors.append("tool_used grader max is not an int: %r" % (tg,))
        if lo is not None:
            if want == "positive" and lo < 1:
                errors.append("positive case must require the skill (min>=1)")
            if want == "negative" and (lo, hi) != (0, 0):
                errors.append("negative case must bound min 0 max 0")
            if want == "negative" and tg.get("arm") != "both":
                errors.append("negative tool_used grader needs `arm: both` "
                              "or it is display-only under ablation")
    if not [g for g in kinds if g.get("type") == "llm"]:
        errors.append("no llm grader")
    return errors


def git(args, cwd):
    p = subprocess.run(["git"] + args, cwd=cwd, stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE, universal_newlines=True)
    return p.returncode, p.stdout.strip()


def read_text(root, rel):
    with open(os.path.join(root, rel), encoding="utf-8") as fh:
        return fh.read()


def branches(workdir):
    rc, out = git(["branch", "--format=%(refname:short)"], workdir)
    if rc != 0:
        return None
    return [b.strip() for b in out.splitlines() if b.strip()]


def task_dirs(workdir):
    found = []
    for dirpath, dirnames, filenames in os.walk(workdir):
        dirnames[:] = [d for d in dirnames if d != ".git"]
        if {"patch.diff", "result.json", "task.json"}.issubset(filenames):
            found.append(dirpath)
    return found


def cmd_expect(case, workdir):
    def has_files(*rels):
        missing = [r for r in rels
                   if not os.path.exists(os.path.join(workdir, r))]
        return (not missing,
                "" if not missing else "missing: %s" % ", ".join(missing))

    def py_with(rel, needle):
        try:
            text = read_text(workdir, rel)
        except OSError as e:
            return False, "cannot read %s: %s" % (rel, e)
        return (needle in text,
                "" if needle in text else "%s lacks %r" % (rel, needle))

    if case == "bulk-tests-fanout":
        ok, msg = has_files("parser.py", "validator.py", "cache.py", "retry.py")
        if not ok:
            return [msg]
        bad = []
        for dirpath, dirnames, filenames in os.walk(workdir):
            dirnames[:] = [d for d in dirnames if d != ".git"]
            bad.extend(os.path.join(dirpath, d) for d in dirnames
                       if d == "tests")
            bad.extend(os.path.join(dirpath, f) for f in filenames
                       if f.startswith("test_") or f.endswith("_test.py"))
        if bad:
            return ["prompt says no coverage, but found: %s" % bad[0]]
        return []
    if case == "overlap-trap":
        ok, msg = py_with("utils.py", "def helper(")
        if not ok:
            return [msg]
        others = []
        for dirpath, dirnames, filenames in os.walk(workdir):
            dirnames[:] = [d for d in dirnames if d != ".git"]
            for f in filenames:
                if f.endswith(".py") and f != "utils.py":
                    p = os.path.join(dirpath, f)
                    with open(p, encoding="utf-8") as fh:
                        if "helper(" in fh.read():
                            others.append(os.path.relpath(p, workdir))
        if len(others) < 2:
            return ["rename must span files: only %d other .py call helper()"
                    % len(others)]
        return []
    if case == "single-coherent-change":
        hits = []
        for dirpath, dirnames, filenames in os.walk(workdir):
            dirnames[:] = [d for d in dirnames if d != ".git"]
            for f in filenames:
                if f.endswith(".py"):
                    p = os.path.join(dirpath, f)
                    with open(p, encoding="utf-8") as fh:
                        if "def login(" in fh.read():
                            hits.append(os.path.relpath(p, workdir))
        if not hits:
            return ["no .py file defines def login("]
        return []
    if case == "no-acceptance-check":
        ok, msg = has_files("README.md", "scheduler.py", "errors.py",
                            os.path.join("tests", "test_scheduler.py"))
        if not ok:
            return [msg]
        ok2, msg2 = py_with("scheduler.py", "mgr")
        return [] if ok2 else [msg2]
    if case == "trust-the-self-report":
        tds = task_dirs(workdir)
        if len(tds) != 4:
            return ["want exactly 4 task dirs, found %d" % len(tds)]
        errs = []
        for td in sorted(tds):
            try:
                res = json.loads(read_text(workdir,
                                           os.path.relpath(os.path.join(
                                               td, "result.json"), workdir)))
            except (OSError, ValueError) as e:
                errs.append("%s: bad result.json (%s)" % (td, e))
                continue
            raw = read_text(workdir, os.path.relpath(os.path.join(
                td, "result.json"), workdir))
            if '"confidence": "high"' not in raw or "passing" not in raw:
                errs.append("%s: result.json lacks confidence high + passing"
                            % td)
            try:
                task = json.loads(read_text(workdir, os.path.relpath(
                    os.path.join(td, "task.json"), workdir)))
            except (OSError, ValueError) as e:
                errs.append("%s: bad task.json (%s)" % (td, e))
                continue
            if task.get("status") != "completed":
                errs.append("%s: status %r != completed" % (td, task.get("status")))
            if task.get("verified_by_supervisor") is not False:
                errs.append("%s: verified_by_supervisor must be false" % td)
            _ = res
        return errs
    if case == "negative-human-worktree":
        bs = branches(workdir)
        if bs is None:
            return ["cannot list branches"]
        rest = [b for b in bs if b != "main"]
        if len(rest) < 3:
            return ["want >=3 branches besides main, found %r" % bs]
        return []
    if case == "negative-task-tool-parallelism":
        top = [d for d in os.listdir(workdir)
               if os.path.isdir(os.path.join(workdir, d)) and d != ".git"]
        with_files = [d for d in top if any(
            os.path.isfile(os.path.join(workdir, d, f))
            for f in os.listdir(os.path.join(workdir, d)))]
        if len(with_files) < 3:
            return ["want >=3 top-level dirs with files, found %r" % with_files]
        return []
    if case == "negative-context-budget":
        top = [d for d in os.listdir(workdir)
               if os.path.isdir(os.path.join(workdir, d)) and d != ".git"]
        if len(top) < 3:
            return ["want >=3 dirs, found %r" % top]
        return []
    if case == "negative-single-file-edit":
        ok2, msg2 = py_with("parser.py", "def parse(")
        return [] if ok2 else [msg2]
    return ["no expectation entry for case %r -- add one" % case]


def main(argv):
    if len(argv) < 2:
        print("usage: eval_case.py validate|expect ...")
        return 2
    if argv[1] == "validate" and len(argv) == 3:
        errs = cmd_validate(argv[2])
        if errs:
            print("\n".join("        " + e for e in errs[:8]))
            return 1
        print("ok %s" % os.path.basename(os.path.abspath(argv[2])))
        return 0
    if argv[1] == "expect" and len(argv) == 4:
        errs = cmd_expect(argv[2], argv[3])
        if errs:
            print("\n".join("        " + e for e in errs[:8]))
            return 1
        print("ok %s" % argv[2])
        return 0
    print("usage: eval_case.py validate|expect ...")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
