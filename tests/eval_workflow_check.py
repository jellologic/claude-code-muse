#!/usr/bin/env python3
"""Offline checker for .github/workflows/evals.yml. Stdlib only, 3.9 compatible.

Usage: eval_workflow_check.py <workflow.yml> <evals-root>

Asserts the manual-only workflow runs the documented `claude plugin eval .`
command with every gated tool the positive cases need on the trailing
--allow-tools. The gated set is derived, not hardcoded: the union of
execution.allowed_tools over the cases whose tags contain `positive`
(loaded with tests/eval_case.py's stdlib parser), minus the ungated tools
{Read, Glob, Grep, Skill, Agent}. A case that adds a newly gated tool to
allowed_tools without extending the workflow command fails here.

Uses PyYAML when importable; otherwise the workflow command is found by
plain text matching while the case.yaml side still parses through
eval_case.load_case. Under CI=true without PyYAML the workflow parse cannot
run, so exit 1. Exit 0 on success, 1 with one reason per line on failure.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import eval_case  # noqa: E402

UNGATED = {"Read", "Glob", "Grep", "Skill", "Agent"}


def fail(errs):
    print("\n".join("        " + e for e in errs[:8]))
    return 1


def derived_gated(evals_root):
    """Return (needed_set, errors). needed_set is the gated tools the
    positive cases require on the operator's --allow-tools."""
    needed = set()
    positives = 0
    try:
        names = sorted(os.listdir(evals_root))
    except OSError as e:
        return needed, ["cannot list evals root %r: %s" % (evals_root, e)]
    for name in names:
        casedir = os.path.join(evals_root, name)
        if not os.path.isfile(os.path.join(casedir, "case.yaml")):
            continue
        doc, lerrs = eval_case.load_case(casedir)
        if lerrs or doc is None:
            return needed, ["cannot load %s/case.yaml: %s"
                            % (name, "; ".join(lerrs) or "no doc")]
        if "positive" not in (doc.get("tags") or []):
            continue
        positives += 1
        tools = (doc.get("execution") or {}).get("allowed_tools") or []
        for tool in tools:
            needed.add(tool)
    if positives == 0:
        return needed, ["no positive case found under %r" % evals_root]
    needed -= UNGATED
    return needed, []


def check_grants(blob, needed):
    """Assert every derived gated tool rides the trailing --allow-tools."""
    errs = []
    if not needed:
        errs.append("derived gated set is empty -- nothing to check")
        return errs
    for must in ("Bash", "Workflow"):
        if must not in needed:
            errs.append("derived gated set lacks %s (got %s)"
                        % (must, sorted(needed)))
    if "--allow-tools" not in blob:
        errs.append("eval command lacks --allow-tools for the gated tools")
        return errs
    tail = blob.split("--allow-tools", 1)[1].split()
    for tool in sorted(needed):
        if tool not in tail:
            errs.append("eval command's --allow-tools lacks gated tool %s"
                        % tool)
    return errs


def main(argv):
    if len(argv) != 3:
        print("usage: eval_workflow_check.py <workflow.yml> <evals-root>")
        return 2
    path, evals_root = argv[1], argv[2]
    needed, derrs = derived_gated(evals_root)
    if derrs:
        return fail(derrs)
    try:
        import yaml
    except ImportError:
        yaml = None
        if os.environ.get("CI") == "true":
            print("        PyYAML absent under CI=true -- "
                  "the workflow parse did not run")
            return 1
        # No YAML parser on this host: check the same behaviours with plain
        # string handling on the run: block. Skipping here would emit no
        # check and trip the offline count guard, so this path still
        # passes or fails.
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
        blob = None
        for i, line in enumerate(lines):
            if "claude plugin eval ." in line:
                start = i
                while start > 0 and not lines[start].lstrip().startswith(
                        "run:"):
                    start -= 1
                end = i + 1
                while end < len(lines) and (
                        not lines[end].strip()
                        or lines[end].startswith(" ")):
                    end += 1
                blob = "\n".join(lines[start:end])
                break
        if blob is None:
            return fail(["no step runs `claude plugin eval .`"])
        errs = []
        for flag in ("--runs 3", "--max-cost-usd 5", "--threshold 0.8",
                     "--json", "--scaffold", "--trust-plugin"):
            if flag not in blob:
                errs.append("eval command lacks %s" % flag)
        errs.extend(check_grants(blob, needed))
        if "evals/_lib/bin" not in blob:
            errs.append("eval command lacks the evals/_lib/bin PATH prefix")
        raw = "\n".join(lines)
        if "workflow_dispatch" not in raw:
            errs.append("workflow is not manual-only (no workflow_dispatch)")
        if "secrets.ANTHROPIC_API_KEY" not in raw:
            errs.append("ANTHROPIC_API_KEY is not wired to "
                        "secrets.ANTHROPIC_API_KEY")
        if "actions/upload-artifact" not in raw:
            errs.append("no upload-artifact step")
        if errs:
            return fail(errs)
        print("ok evals.yml (text fallback, no PyYAML)")
        return 0
    with open(path, encoding="utf-8") as fh:
        d = yaml.safe_load(fh)
    trg = d.get(True, d.get("on"))
    names = []
    if isinstance(trg, str):
        names = [trg]
    elif isinstance(trg, list):
        names = [str(t) for t in trg]
    elif isinstance(trg, dict):
        names = sorted(str(t) for t in trg)
    errs = []
    if names != ["workflow_dispatch"]:
        errs.append("triggers must be exactly workflow_dispatch, got %r"
                    % (names,))
    jobs = d.get("jobs") or {}
    blob = None
    for _jn, job in jobs.items():
        for step in (job or {}).get("steps") or []:
            run = (step or {}).get("run") or ""
            if "claude plugin eval ." in run:
                blob = run
    if blob is None:
        errs.append("no step runs `claude plugin eval .`")
    else:
        for flag in ("--runs 3", "--max-cost-usd 5", "--threshold 0.8",
                     "--json", "--scaffold", "--trust-plugin"):
            if flag not in blob:
                errs.append("eval command lacks %s" % flag)
        # Gated tools ride a trailing --allow-tools, and the stub dir
        # travels on the operator's PATH (case.yaml env accepts only
        # EVAL_* keys).
        errs.extend(check_grants(blob, needed))
        if "evals/_lib/bin" not in blob:
            errs.append("eval command lacks the evals/_lib/bin PATH prefix")
    found_key = []
    found_art = False
    for _jn, job in jobs.items():
        for env in [(job or {}).get("env") or {}] + \
                   [(s or {}).get("env") or {}
                    for s in (job or {}).get("steps") or []]:
            if env.get("ANTHROPIC_API_KEY") == \
                    "${{ secrets.ANTHROPIC_API_KEY }}":
                found_key.append(1)
        for step in (job or {}).get("steps") or []:
            uses = (step or {}).get("uses") or ""
            if "actions/upload-artifact" in uses and \
                    str((step or {}).get("if")) == "always()":
                found_art = True
    if not found_key:
        errs.append("ANTHROPIC_API_KEY is not wired to "
                    "secrets.ANTHROPIC_API_KEY")
    if not found_art:
        errs.append("no upload-artifact step under if: always()")
    if errs:
        return fail(errs)
    print("ok evals.yml")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
