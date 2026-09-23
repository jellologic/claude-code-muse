#!/usr/bin/env python3
"""Replay the CLI's llm judge against evidence in a `claude plugin eval --json` report.

The CLI records only the votes, not the judge's reasoning. This tool rebuilds
the exact judge prompt from the report and samples it again, so a flaky or
biased grader can be diagnosed (with --explain) or a rewritten criteria file
tested (with --criteria-file) before paying for another eval. Stdlib only,
Python 3.9 compatible.
"""
import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile

SYS_PROMPT = "You are a strict, terse evaluation judge for coding-agent traces."
ONE_WORD_INSTRUCTION = "Respond with exactly one word: PASS or FAIL."
EXPLAIN_INSTRUCTION = ("Respond with PASS or FAIL on the first line and, "
                       "if FAIL, quote the unmet part of the criterion.")


def fail(msg):
    sys.stderr.write("%s\n" % msg)
    return 2


def build_prompt(criteria, evidence, instruction):
    return ("You are grading the output of a coding agent against a criterion.\n\nCriterion:\n"
            + criteria + "\n\n\nAgent output (last_message):\n"
            + evidence + "\n\n\n" + instruction)


def load_criteria_file(path):
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError as e:
        return None, "cannot read criteria file %s: %s" % (path, e)
    start = None
    for i, line in enumerate(lines):
        if line == "criteria: |":
            start = i + 1
            break
    if start is None:
        return None, "no `criteria: |` block in %s" % path
    body = []
    for line in lines[start:]:
        if line == "---":
            break
        if line.startswith("  "):
            body.append(line[2:])
        elif line.strip() == "":
            body.append("")
        else:
            return None, "no `criteria: |` block in %s" % path
    else:
        return None, "no `criteria: |` block in %s" % path
    while body and body[-1] == "":
        body.pop()
    return "\n".join(body) + "\n", None


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--report", required=True)
    ap.add_argument("--case", required=True)
    ap.add_argument("--grader", default=None,
                    help="default: the case's first grader with type llm")
    ap.add_argument("--run", type=int, default=None,
                    help="1-based run index; default is every run")
    ap.add_argument("--criteria-file", default=None)
    ap.add_argument("--samples", type=int, default=3)
    ap.add_argument("--judge-model", default="haiku")
    ap.add_argument("--explain", action="store_true")
    ap.add_argument("--claude", default=None)
    args = ap.parse_args(argv)

    try:
        with open(args.report, encoding="utf-8") as fh:
            report = json.load(fh)
    except (OSError, ValueError) as e:
        return fail("unreadable report %s: %s" % (args.report, e))

    cases = {c.get("name"): c for c in report.get("cases", [])}
    case = cases.get(args.case)
    if case is None:
        return fail("unknown case %r" % args.case)

    case_graders = case.get("graders", [])
    if args.grader:
        match = [g for g in case_graders if g.get("name") == args.grader]
        if not match:
            return fail("unknown grader %r" % args.grader)
        grader_cfg = match[0]
    else:
        llms = [g for g in case_graders if g.get("type") == "llm"]
        if not llms:
            return fail("no llm grader in case %r" % args.case)
        grader_cfg = llms[0]
    grader_name = grader_cfg.get("name")

    focus = (grader_cfg.get("config") or {}).get("focus", "last_message")
    if focus != "last_message":
        return fail("unsupported focus %r (only last_message)" % focus)

    criteria = (grader_cfg.get("config") or {}).get("criteria", "")
    if args.criteria_file:
        criteria, err = load_criteria_file(args.criteria_file)
        if err is not None:
            return fail(err)

    runs = (case.get("arms") or {}).get("with", [])
    if args.run is not None:
        if args.run < 1 or args.run > len(runs):
            return fail("run %d out of range (1..%d)"
                        % (args.run, len(runs)))
        wanted = [args.run]
    else:
        wanted = list(range(1, len(runs) + 1))

    instruction = EXPLAIN_INSTRUCTION if args.explain else ONE_WORD_INSTRUCTION
    # Collect every prompt before touching claude: input refusals (unknown
    # case/grader, wrong focus, bad criteria file, missing evidence) must
    # never depend on whether a claude binary happens to be installed.
    prompts = []
    for n in wanted:
        run = runs[n - 1]
        ev = ""
        for g in run.get("graders", []):
            if g.get("name") == grader_name:
                ev = g.get("evidence") or ""
                break
        if not ev.strip():
            return fail("run %d has no last-message evidence for grader %r"
                        % (n, grader_name))
        prompts.append((n, build_prompt(criteria, ev, instruction)))

    claude = args.claude or shutil.which("claude")
    if not claude:
        return fail("no claude binary found")

    all_pass = True
    for n, prompt in prompts:
        votes = []
        for k in range(1, args.samples + 1):
            # Fresh cwd plus empty setting sources: without them a measured
            # judge reply cited the surrounding repo's rules instead of the
            # criterion, because project settings leak into `claude -p`.
            tmpd = tempfile.mkdtemp()
            try:
                try:
                    proc = subprocess.run(
                        [claude, "-p", "--model", args.judge_model,
                         "--setting-sources", "",
                         "--system-prompt", SYS_PROMPT,
                         "--tools", ""],
                        input=prompt.encode("utf-8"),
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        cwd=tmpd, timeout=120)
                except OSError as e:
                    return fail("cannot run claude: %s" % e)
                except subprocess.TimeoutExpired:
                    return fail("claude timed out on run %d sample %d"
                                % (n, k))
                if proc.returncode != 0:
                    sys.stderr.write(
                        proc.stderr.decode("utf-8",
                                           errors="replace").replace("\r", ""))
                    if not proc.stderr:
                        sys.stderr.write("claude exited %d\n"
                                         % proc.returncode)
                    return 2
                reply = proc.stdout.decode("utf-8",
                                           errors="replace").replace("\r", "")
            finally:
                # rmtree, not rmdir: claude may write cache files under cwd,
                # and rmdir would silently leave the whole temp dir behind.
                shutil.rmtree(tmpd, ignore_errors=True)
            # Match the CLI's vote rule exactly: a PASS reply that mentions
            # "fail" anywhere (e.g. echoing that patches "fail to apply")
            # must still count as FAIL, or replays would disagree with evals.
            vote = ("PASS" if re.search(r"\bPASS\b", reply, re.I)
                    and not re.search(r"\bFAIL\b", reply, re.I)
                    else "FAIL")
            votes.append(vote)
            one_line = reply.replace("\n", " ")[:300]
            print("run %d sample %d: vote=%s reply=%s" % (n, k, vote, one_line))
        majority = "PASS" if votes.count("PASS") > len(votes) / 2 else "FAIL"
        print("run %d votes: %s -> %s" % (n, " ".join(votes), majority))
        if majority != "PASS":
            all_pass = False
    return 0 if all_pass else 1


if __name__ == "__main__":
    sys.exit(main())
