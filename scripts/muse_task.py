#!/usr/bin/env python3
"""
muse_task.py — ONE muse task in a persistent worktree, driven round by round.

This is the instrument a supervisor agent holds. The supervisor decides; this script
only does. Each subcommand is one turn of the loop:

    run      create the worktree, run muse once, harvest the patch
    verify   run the acceptance command INSIDE the worktree and record the result
    revise   run muse again in the SAME worktree with reviewer feedback
    show     re-read state without spending anything
    finish   final harvest, mark the task done, write the task record
    cleanup  drop the worktree and branch

The difference from muse_fleet.py is who reviews. The fleet harvests N patches and
hands them to a human afterwards. Here a supervisor reads the patch, runs the check
itself, and sends muse back with specific defects until the work is right -- so the
task completes already reviewed, or completes explicitly marked as not good enough.

Why rounds share one worktree: muse has no memory between `muse exec` invocations, so
a revision would otherwise start from a clean checkout and redo the work. Reusing the
worktree means round 2 edits round 1's output, and the harvested patch is always the
cumulative diff against base -- i.e. the thing you would actually merge.

Every subcommand prints one JSON object to stdout and diagnostics to stderr, so a
supervisor can parse stdout without the noise.
"""

from __future__ import annotations

import argparse
import datetime as dt
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "muse_core", str(Path(__file__).resolve().parent / "muse_core.py"))
core = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(core)

DEFAULT_MAX_ROUNDS = 3


def state_path(tdir: Path) -> Path:
    return tdir / "state.json"


def load_state(tdir: Path) -> dict:
    p = state_path(tdir)
    if not p.exists():
        sys.exit(
            "no state at {}\nRun `muse_task.py run --id <id> --out <dir> ...` first."
            .format(p))
    return json.loads(p.read_text())


def save_state(tdir: Path, st: dict) -> None:
    state_path(tdir).write_text(json.dumps(st, indent=2))


def emit(obj: dict) -> None:
    """One JSON object on stdout. The supervisor parses this; everything else is stderr."""
    print(json.dumps(obj, indent=2))


def task_dir(args) -> Path:
    return Path(args.out).resolve() / args.id


def do_round(st: dict, tdir: Path, prompt: str, args, kind: str) -> dict:
    """Run one muse round into the existing worktree and harvest the cumulative patch."""
    repo = Path(st["repo"])
    wt = Path(st["worktree"])
    n = len(st["rounds"]) + 1
    rdir = tdir / "round-{}".format(n)
    rdir.mkdir(parents=True, exist_ok=True)
    (rdir / "prompt.txt").write_text(prompt)

    cmd = core.muse_cmd(
        st["model"], st.get("effort", core.DEFAULT_EFFORT), wt,
        schema=st.get("schema"), max_steps=st.get("max_steps") or 0,
        inherit_skills=st.get("inherit_skills", False),
    )
    print("muse_task[{}]: round {} ({}) model={} effort={}".format(
        st["id"], n, kind, st["model"], st.get("effort")), file=sys.stderr)

    res = core.run_muse(cmd, prompt, repo, rdir / "events.jsonl",
                        rdir / "stderr.log", int(st.get("timeout") or core.DEFAULT_TIMEOUT))

    rnd = {
        "n": n, "kind": kind, "status": res["status"], "reason": res["reason"],
        "elapsed_s": res["elapsed_s"], "model_actual": res["model_actual"],
        "events": str(rdir / "events.jsonl"),
        "stderr": str(rdir / "stderr.log"),
    }

    # Structured self-report, when a schema was supplied. This is a set of CLAIMS by the
    # same cheap model that did the work -- the supervisor checks it against the patch
    # and against `verify`, it is never evidence on its own.
    result = None
    if st.get("schema") and (res["text"] or "").strip():
        parsed = core.parse_answers(res["text"])
        if isinstance(parsed, dict):
            result = parsed
            (rdir / "result.json").write_text(json.dumps(parsed, indent=2))
    if result is None and res["text"]:
        rnd["text"] = res["text"][:2000]

    h = core.harvest(wt, st["base"], st["excludes"], tdir / "patch.diff")
    rnd.update({"patch_lines": h["patch_lines"], "files_changed": h["files_changed"]})
    if h["harvest_error"]:
        rnd["harvest_error"] = h["harvest_error"]

    st["rounds"].append(rnd)
    save_state(tdir, st)

    out = {
        "id": st["id"], "round": n, "kind": kind,
        "status": res["status"], "reason": res["reason"],
        "worktree": st["worktree"], "branch": st["branch"], "base": st["base"],
        "patch": str(tdir / "patch.diff"),
        "patch_lines": h["patch_lines"],
        "files_changed": h["files_changed"],
        "oversized": h["patch_lines"] > int(st.get("warn_patch_lines") or 5000),
        "elapsed_s": res["elapsed_s"],
        "model": st["model"], "model_actual": res["model_actual"],
        "events": str(rdir / "events.jsonl"),
        "self_report": result,
        "rounds_used": n,
        "rounds_left": max(0, int(st["max_rounds"]) - n),
    }
    if rnd.get("text"):
        out["text"] = rnd["text"]
    if h["harvest_error"]:
        out["harvest_error"] = h["harvest_error"]
    return out


# ---------------------------------------------------------------------- run

def cmd_run(args) -> int:
    repo = Path(args.repo).resolve()
    head = core.preflight(repo, require_clean=not args.allow_dirty)
    if args.schema:
        core.check_schema(args.schema)

    model, how = core.resolve_model(args.model)
    tdir = task_dir(args)
    tdir.mkdir(parents=True, exist_ok=True)

    stamp = args.stamp or dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    branch = "{}/{}/{}".format(args.branch_prefix, stamp, args.id)
    wt_root = Path(args.worktree_root) if args.worktree_root \
        else repo.parent / ".muse-fleet-wt-{}".format(repo.name)
    wt_root.mkdir(parents=True, exist_ok=True)
    wt = wt_root / "{}-{}".format(stamp, args.id)

    base = args.base
    # A re-run of the same id must not inherit the previous attempt's tree.
    core.drop_worktree(repo, wt, branch)
    try:
        core.git(repo, "worktree", "add", "-q", "-b", branch, str(wt), base)
    except Exception as e:
        emit({"id": args.id, "status": "setup_failed", "reason": str(e)})
        return 1

    seeded = core.seed_worktree(repo, wt, args.seed or [], args.link or [])
    absent = core.absent_locals(repo, (args.seed or []) + (args.link or []))
    if absent:
        print("muse_task[{}]: note — {} exist in the repo but NOT in the worktree; "
              "pass --seed/--link if the acceptance check needs them."
              .format(args.id, ", ".join(absent)), file=sys.stderr)

    st = {
        "id": args.id, "repo": str(repo), "worktree": str(wt), "branch": branch,
        "base": base, "base_sha": head, "model": model, "model_choice": how,
        "effort": args.effort, "timeout": args.timeout, "max_steps": args.max_steps,
        "schema": str(Path(args.schema).resolve()) if args.schema else None,
        "excludes": args.exclude if args.exclude is not None else core.DEFAULT_EXCLUDES,
        "inherit_skills": args.inherit_skills,
        "warn_patch_lines": args.warn_patch_lines,
        "max_rounds": args.max_rounds,
        "brief": args.prompt,
        "seeded": seeded, "absent_locals": absent,
        "rounds": [], "verifications": [], "done": False,
    }
    save_state(tdir, st)

    out = do_round(st, tdir, args.prompt, args, "initial")
    out["seeded"] = seeded
    out["absent_locals"] = absent
    out["model_choice"] = how
    out["next"] = ("Read the patch. Run your acceptance check with `verify`. "
                   "Then `revise --feedback ...` or `finish --verdict accept`.")
    emit(out)
    return 0


# ------------------------------------------------------------------- revise

REVISION_TEMPLATE = """REVISION ROUND {n}. Your previous attempt is ALREADY PRESENT in this working tree.

A reviewer inspected your work and requires these specific changes:

{feedback}

Fix exactly these points. Do NOT revert or rewrite unrelated work already in the tree
that the reviewer did not object to, and do not start over from scratch.

For reference, the original brief was:
{brief}
"""


def cmd_revise(args) -> int:
    tdir = task_dir(args)
    st = load_state(tdir)
    if st.get("done"):
        emit({"id": st["id"], "status": "refused",
              "reason": "task already finished; re-run `run` to start a new attempt"})
        return 1

    used = len(st["rounds"])
    if used >= int(st["max_rounds"]):
        # The circuit breaker. A supervisor convinced it is one more round from success
        # is the standard way an agent loop burns money; make it stop and escalate.
        emit({"id": st["id"], "status": "max_rounds_exhausted",
              "rounds_used": used, "max_rounds": st["max_rounds"],
              "patch": str(tdir / "patch.diff"),
              "reason": "round budget spent; finish with a verdict of revise/reject, "
                        "or re-run with a higher --max-rounds if genuinely warranted"})
        return 1

    if not Path(st["worktree"]).exists():
        emit({"id": st["id"], "status": "worktree_missing",
              "reason": "worktree {} is gone; cannot revise".format(st["worktree"])})
        return 1

    if args.effort:
        # Escalating effort on a revision is the documented move when round 1 produced
        # plausible-but-wrong work rather than a mechanical miss.
        st["effort"] = args.effort
    feedback = args.feedback
    if args.feedback_file:
        feedback = Path(args.feedback_file).read_text()
    prompt = REVISION_TEMPLATE.format(n=used + 1, feedback=feedback, brief=st["brief"])

    out = do_round(st, tdir, prompt, args, "revision")
    out["next"] = ("Re-run `verify`, then `finish` with a verdict. "
                   "{} round(s) left.".format(out["rounds_left"]))
    emit(out)
    return 0


# ------------------------------------------------------------------- verify

def cmd_verify(args) -> int:
    """Run the acceptance command inside the worktree and RECORD it.

    This exists because the single highest-value fact about a delegated patch is
    whether a real command really passed on it. A worker's own claim that tests pass
    is worth very little -- one observed run reported `confidence: high` on a suite it
    made pass by quietly building a .venv. When the supervisor runs the check itself
    and the exit code is recorded here, the final report cites evidence instead of a
    claim."""
    tdir = task_dir(args)
    st = load_state(tdir)
    wt = Path(st["worktree"])
    if not wt.exists():
        emit({"id": st["id"], "status": "worktree_missing", "passed": False,
              "reason": "worktree {} is gone".format(wt)})
        return 1

    tail = lambda s: s[-args.max_output:] if len(s) > args.max_output else s
    rec = {
        "after_round": len(st["rounds"]),
        "command": args.command,
    }
    try:
        r = subprocess.run(args.command, cwd=str(wt), shell=True,
                           capture_output=True, text=True, timeout=args.timeout)
        rec.update({
            "exit_code": r.returncode,
            "passed": r.returncode == 0,
            "stdout_tail": tail(r.stdout),
            "stderr_tail": tail(r.stderr),
        })
    except subprocess.TimeoutExpired as e:
        # A hung check must come back as a parseable failure. Raising here would hand
        # the supervisor a traceback on stdout instead of JSON, and it would have no
        # way to tell "the check hung" from "the script is broken".
        rec.update({
            "exit_code": None, "passed": False, "timed_out": True,
            "stdout_tail": tail((e.stdout or b"").decode(errors="replace")
                                if isinstance(e.stdout, bytes) else (e.stdout or "")),
            "stderr_tail": "acceptance check exceeded {}s".format(args.timeout),
        })
    st.setdefault("verifications", []).append(rec)
    save_state(tdir, st)

    emit({"id": st["id"], "status": "verified", **rec,
          "next": "passed → `finish --verdict accept`; failed → `revise --feedback ...` "
                  "quoting the failure output"})
    return 0 if rec["passed"] else 1


# ------------------------------------------------------------- show / finish

def cmd_show(args) -> int:
    tdir = task_dir(args)
    st = load_state(tdir)
    emit({
        "id": st["id"], "done": st.get("done", False),
        "worktree": st["worktree"], "branch": st["branch"], "base": st["base"],
        "model": st["model"], "effort": st.get("effort"),
        "rounds_used": len(st["rounds"]), "max_rounds": st["max_rounds"],
        "patch": str(tdir / "patch.diff"),
        "patch_lines": st["rounds"][-1]["patch_lines"] if st["rounds"] else 0,
        "files_changed": st["rounds"][-1]["files_changed"] if st["rounds"] else [],
        "verifications": st.get("verifications", []),
        "rounds": [{k: r.get(k) for k in ("n", "kind", "status", "elapsed_s", "patch_lines")}
                   for r in st["rounds"]],
    })
    return 0


def cmd_finish(args) -> int:
    tdir = task_dir(args)
    st = load_state(tdir)

    # Re-harvest so the recorded patch reflects the tree as it stands right now. Note what
    # that means: a supervisor that edited the worktree by hand would have its edit folded
    # into this patch and misattributed to muse. That is why the supervisor has no Write or
    # Edit tool -- the architecture is enforced by the toolset, not by this comment.
    h = core.harvest(Path(st["worktree"]), st["base"], st["excludes"], tdir / "patch.diff") \
        if Path(st["worktree"]).exists() else {"patch_lines": 0, "files_changed": [],
                                               "harvest_error": "worktree missing"}
    if args.commit and h["patch_lines"]:
        core.commit_worktree(Path(st["worktree"]),
                             "muse({}): {}".format(st["id"], (args.summary or st["id"])[:70]))

    verified = [v for v in st.get("verifications", []) if v.get("passed")]
    st.update({
        "done": True,
        "verdict": args.verdict,
        "summary": args.summary,
        "concerns": args.concern or [],
        "final_patch_lines": h["patch_lines"],
        "final_files_changed": h["files_changed"],
    })
    save_state(tdir, st)

    out = {
        "id": st["id"], "verdict": args.verdict, "summary": args.summary,
        "concerns": args.concern or [],
        "patch": str(tdir / "patch.diff"),
        "patch_lines": h["patch_lines"], "files_changed": h["files_changed"],
        "rounds_used": len(st["rounds"]),
        "worktree": st["worktree"], "branch": st["branch"],
        # The distinction that matters downstream: a green check the supervisor ran
        # itself, versus a patch nobody executed.
        "verified_by_supervisor": bool(verified),
        "verifications": st.get("verifications", []),
    }
    if h.get("harvest_error"):
        out["harvest_error"] = h["harvest_error"]
    (tdir / "task.json").write_text(json.dumps(out, indent=2))

    if args.cleanup:
        core.drop_worktree(Path(st["repo"]), Path(st["worktree"]), st["branch"])
        out["cleaned_up"] = True
    emit(out)
    return 0


def cmd_cleanup(args) -> int:
    tdir = task_dir(args)
    st = load_state(tdir)
    core.drop_worktree(Path(st["repo"]), Path(st["worktree"]), st["branch"])
    emit({"id": st["id"], "status": "cleaned", "worktree": st["worktree"]})
    return 0


# --------------------------------------------------------------------- main

def main() -> int:
    ap = argparse.ArgumentParser(
        description="One muse task in a persistent worktree, driven round by round.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p):
        p.add_argument("--id", required=True, help="task id; names the worktree and branch")
        p.add_argument("--out", default=".muse-fleet/tasks",
                       help="artifact root; task artifacts land in <out>/<id>/")

    p = sub.add_parser("run", help="create the worktree and run muse once")
    common(p)
    p.add_argument("--prompt", required=True)
    p.add_argument("--repo", default=".")
    p.add_argument("--model", default=core.LATEST)
    p.add_argument("--effort", default=core.DEFAULT_EFFORT, choices=core.EFFORTS)
    p.add_argument("--timeout", type=int, default=core.DEFAULT_TIMEOUT)
    p.add_argument("--max-steps", type=int, default=0)
    p.add_argument("--max-rounds", type=int, default=DEFAULT_MAX_ROUNDS,
                   help="hard cap on revision rounds (runaway-cost breaker)")
    p.add_argument("--base", default="HEAD")
    p.add_argument("--schema")
    p.add_argument("--branch-prefix", default="muse")
    p.add_argument("--worktree-root", default=None)
    p.add_argument("--stamp", default=None,
                   help="shared run stamp so sibling tasks land under one namespace")
    p.add_argument("--allow-dirty", action="store_true")
    p.add_argument("--seed", action="append", default=None, metavar="PATH")
    p.add_argument("--link", action="append", default=None, metavar="PATH")
    p.add_argument("--exclude", action="append", default=None)
    p.add_argument("--warn-patch-lines", type=int, default=5000)
    p.add_argument("--inherit-skills", action="store_true")
    p.set_defaults(fn=cmd_run)

    p = sub.add_parser("revise", help="run muse again in the same worktree with feedback")
    common(p)
    p.add_argument("--feedback", default="")
    p.add_argument("--feedback-file", default=None,
                   help="read feedback from a file (avoids shell-quoting a long review)")
    p.add_argument("--effort", default=None, choices=core.EFFORTS,
                   help="escalate effort for this round")
    p.set_defaults(fn=cmd_revise)

    p = sub.add_parser("verify", help="run the acceptance command inside the worktree")
    common(p)
    p.add_argument("--command", required=True)
    p.add_argument("--timeout", type=int, default=600)
    p.add_argument("--max-output", type=int, default=4000,
                   help="truncate captured output to this many chars")
    p.set_defaults(fn=cmd_verify)

    p = sub.add_parser("show", help="print current state")
    common(p)
    p.set_defaults(fn=cmd_show)

    p = sub.add_parser("finish", help="final harvest and verdict")
    common(p)
    p.add_argument("--verdict", required=True, choices=["accept", "revise", "reject"])
    p.add_argument("--summary", default="")
    p.add_argument("--concern", action="append", default=None,
                   help="residual concern for the human reviewer (repeatable)")
    p.add_argument("--commit", action="store_true")
    p.add_argument("--cleanup", action="store_true")
    p.set_defaults(fn=cmd_finish)

    p = sub.add_parser("cleanup", help="drop the worktree and branch")
    common(p)
    p.set_defaults(fn=cmd_cleanup)

    args = ap.parse_args()
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
