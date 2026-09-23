#!/usr/bin/env python3
"""
muse_fleet.py — fan work out to N concurrent Muse Code instances, each in its own
git worktree, then harvest the results as patches.

THIS IS THE UNSUPERVISED PATH. It runs every task once and hands you a pile of
patches to review afterwards. Nothing checks the work before it lands in the report.

Prefer `muse_task.py` driven from a workflow (see SKILL.md) when the work matters:
there each task gets a supervisor that reads the patch, runs the acceptance check and
sends muse back with specific defects, so a task finishes already reviewed. Use this
script when you deliberately want raw throughput with review batched to the end --
many tiny tasks, or a first look at how a job decomposes.

    ./muse_fleet.py --tasks tasks.json --repo . --concurrency 3

tasks.json is a list of objects:

    [
      {"id": "divide", "prompt": "Add divide(a,b) to calc.py ..."},
      {"id": "tests",  "prompt": "Add pytest tests ...", "effort": "medium"}
    ]

Per-task optional keys: effort, model, timeout, max_steps, base.

Results land in --out (default .muse-fleet/<timestamp>/):

    <out>/report.json          machine-readable summary of every task
    <out>/report.md            the same thing for a human
    <out>/<id>/events.jsonl    raw muse event stream
    <out>/<id>/stderr.log      muse stderr
    <out>/<id>/result.json     parsed structured answer (if --schema was used)
    <out>/<id>/patch.diff      the task's work, as a patch against its base

Nothing is applied to your working copy. Harvesting is deliberately separate from
merging so that a bad run costs you a discarded patch file, not a dirty repo.

The worktree, seeding, exclusion and harvest logic lives in muse_core.py, shared with
muse_task.py so the two paths cannot disagree about what a patch contains.
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import datetime as dt
import importlib.util
import json
import secrets
import sys
import time
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "muse_core", str(Path(__file__).resolve().parent / "muse_core.py"))
core = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(core)

# Re-exported so any existing caller that imports this module for resolve_model keeps
# working unchanged.
#
# These are COPIES, not aliases. Rebinding one here (e.g. CATALOG_GLOB in a test) does
# not change what muse_core's own functions read, so they will go on using the real
# value and the override will pass silently. Patch muse_core directly instead.
LATEST = core.LATEST
FALLBACK_MODEL = core.FALLBACK_MODEL
CATALOG_GLOB = core.CATALOG_GLOB
DEFAULT_EFFORT = core.DEFAULT_EFFORT
DEFAULT_TIMEOUT = core.DEFAULT_TIMEOUT
DEFAULT_EXCLUDES = core.DEFAULT_EXCLUDES
COMMON_LOCAL = core.COMMON_LOCAL

catalog_rows = core.catalog_rows
resolve_model = core.resolve_model
parse_answers = core.parse_answers
git = core.git
drop_worktree = core.drop_worktree
seed_worktree = core.seed_worktree
preflight = core.preflight
check_schema = core.check_schema


# ------------------------------------------------------------------ one task

def run_task(task: dict, repo: Path, out: Path, args) -> dict:
    tid = task["id"]
    tdir = out / tid
    tdir.mkdir(parents=True, exist_ok=True)

    base = task.get("base", args.base)
    # Pin to a sha for the same reason muse_task does: a ref that moves mid-run makes the
    # harvested patch carry -- and on apply, delete -- commits this task never touched.
    try:
        base = git(repo, "rev-parse", "--verify", base).strip() or base
    except Exception:
        pass    # unresolvable ref: worktree add below will fail with a clearer message
    model, _ = resolve_model(task.get("model", args.model))
    effort = task.get("effort", args.effort)
    timeout = int(task.get("timeout", args.timeout))
    # Namespace the branch by run stamp as well as task id. Worktree paths are already
    # unique per run; branches must be too, or a second run collides with the branches
    # the first one left behind and every task dies in setup.
    branch = f"{args.branch_prefix}/{out.name}/{tid}"
    wt = Path(args.worktree_root) / f"{out.name}-{tid}"

    rec: dict = {
        "id": tid, "branch": branch, "worktree": str(wt), "base": base,
        "status": "unknown", "model": model, "model_actual": None,
        "elapsed_s": None, "reason": None, "summary": None,
        "files_changed": [], "patch_lines": 0,
    }

    # Fresh worktree. Pre-creating it (rather than letting muse generate one under
    # .muse/) gives a deterministic path and branch we can harvest without having to
    # parse them back out of the event stream.
    #
    # Refuse rather than force-remove if something is already there. With a unique run
    # stamp this should be impossible, so reaching it means two runs are sharing a
    # namespace -- almost certainly the same explicit --out -- and the existing tree is
    # another run's live work. The shared check also covers a committed branch or a
    # harvested patch left by an earlier run of this --out, which dropping would reset
    # and overwrite.
    hit = core.collision(repo, wt, branch, patch=tdir / "patch.diff")
    if hit:
        rec["status"] = "setup_failed"
        rec["reason"] = (hit["reason"] + " This --out was used before; use a fresh "
                         "--out (or omit it), or apply/copy the patch and remove the "
                         "branch/patch first.")
        return rec
    drop_worktree(repo, wt, branch)
    try:
        git(repo, "worktree", "add", "-q", "-b", branch, str(wt), base)
    except Exception as e:
        rec["status"], rec["reason"] = "setup_failed", str(e)
        return rec

    seeded = seed_worktree(repo, wt, args.seed or [], args.link or [])
    if seeded:
        rec["seeded"] = seeded

    pf = core.preflight_secrets([wt], {"allow_secrets": getattr(args, "allow_secrets", False),
                                       "no_secret_scan": getattr(args, "no_secret_scan", False)})
    rec["secret_scan"] = {"certain": len(pf["certain"]), "possible": len(pf["possible"]),
                          "files_scanned": pf["files_scanned"],
                          "truncated": pf["truncated"], "skipped": pf["skipped"]}
    if pf["refuse"]:
        drop_worktree(repo, wt, branch)
        rec["status"] = "refused"
        rec["reason"] = pf["reason"]
        rec["secrets"] = pf["certain"][:20]
        return rec
    if pf["certain"] or pf["possible"] or pf["truncated"]:
        print("muse_fleet[{}]: secret scan — {} certain, {} possible across {} files{}"
              .format(tid, len(pf["certain"]), len(pf["possible"]), pf["files_scanned"],
                      " (PARTIAL — hit the file cap, the rest of the tree was not "
                      "scanned)" if pf["truncated"] else ""), file=sys.stderr)

    cmd = core.muse_cmd(model, effort, wt, schema=args.schema,
                        max_steps=task.get("max_steps") or args.max_steps,
                        inherit_skills=args.inherit_skills)

    res = core.run_muse(cmd, task["prompt"], wt, tdir / "events.jsonl",
                        tdir / "stderr.log", timeout)
    rec["elapsed_s"] = res["elapsed_s"]
    rec["status"] = res["status"]
    rec["reason"] = res["reason"]
    rec["model_actual"] = res["model_actual"]

    if res["status"] not in ("timeout",):
        text = res["text"]
        parsed = parse_answers(text) if (args.schema and text.strip()) else None
        if not isinstance(parsed, dict):
            parsed = None
        if parsed is not None:
            (tdir / "result.json").write_text(json.dumps(parsed, indent=2), encoding="utf-8")
            rec["summary"] = parsed.get("summary")
            rec["files_changed"] = parsed.get("files_changed", [])
            rec["confidence"] = parsed.get("confidence")
        else:
            rec["summary"] = text[:2000] or None

    h = core.harvest(wt, base, args.exclude, tdir / "patch.diff")
    rec["patch_lines"] = h["patch_lines"]
    if not rec["files_changed"]:
        rec["files_changed"] = h["files_changed"]
    if h["harvest_error"]:
        rec["harvest_error"] = h["harvest_error"]
    if rec["patch_lines"] > args.warn_patch_lines:
        # Almost always build junk the excludes did not anticipate, not real work.
        rec["oversized"] = True
    if args.commit and rec["patch_lines"]:
        core.commit_worktree(wt, f"muse({tid}): {(rec['summary'] or tid)[:70]}")

    # A failed harvest means the work exists only in the worktree: reporting
    # "completed" would let cleanup reap a tree whose patch was never saved.
    if h["harvest_error"] and rec["status"] == "completed":
        rec["status"] = "harvest_failed"
        rec["reason"] = ("harvest failed ({}); the work exists only in "
                         "worktree {}".format(h["harvest_error"], wt))
    # muse_status and muse_cleanup both key on state.json/task.json. Without them a
    # fleet's worktrees are unreapable (cleanup sees no record and refuses as
    # "unfinished") and status reports this path as having produced nothing at all.
    # There is no supervisor here, so verified_by_supervisor is false by construction.
    state = {
        "id": tid, "repo": str(repo), "worktree": str(wt), "branch": branch,
        "base": base, "model": model, "effort": effort,
        "brief": task.get("prompt", ""),
        "max_rounds": 1,
        "rounds": [{"n": 1, "kind": "initial", "status": rec.get("status"),
                    "resumed": False}],
        "verifications": [],
        "done": not bool(rec.get("harvest_error")),
        "harvest_error": rec.get("harvest_error"),
        "verdict": None,
        "final_patch_lines": rec.get("patch_lines", 0),
        "final_files_changed": rec.get("files_changed") or [],
        "unsupervised": True,
    }
    (tdir / "state.json").write_text(json.dumps(state, indent=2), encoding="utf-8")
    (tdir / "task.json").write_text(json.dumps({
        "id": tid, "verdict": None, "summary": rec.get("summary"), "concerns": [],
        "patch": str(tdir / "patch.diff"), "patch_lines": rec.get("patch_lines", 0),
        "files_changed": rec.get("files_changed") or [],
        "rounds_used": 1, "worktree": str(wt), "branch": branch,
        "verified_by_supervisor": False, "verifications": [],
        "unsupervised": True,
    }, indent=2), encoding="utf-8")

    # Never sweep a worktree whose harvest failed under --cleanup: the patch was
    # never saved, so the tree is the only copy of the work.
    if args.cleanup and not rec.get("harvest_error"):
        drop_worktree(repo, wt, branch)
    elif args.cleanup and rec.get("harvest_error"):
        rec["kept_worktree"] = True
    return rec


# A 1-second stamp is not a unique namespace. Two fleets started in the same second
# computed identical branch names AND identical worktree paths, and run_task opens
# with drop_worktree -- so the second run force-removed the first's LIVE worktrees,
# destroying in-flight work silently. Add entropy; the stamp stays human-readable
# and still sorts chronologically.
# 4 bytes, not 2. Two bytes is 65536 values, and the birthday bound puts a collision
# at ~1.9% across only 50 runs -- which a probabilistic test in the suite duly hit.
# Four bytes takes that to ~0.0005% across 200.
def new_stamp() -> str:
    return "{}-{}".format(dt.datetime.now().strftime("%Y%m%d-%H%M%S"),
                          secrets.token_hex(4))


# ---------------------------------------------------------------------- main

def main() -> int:
    core.install_signal_handlers(interrupt=True)
    ap = argparse.ArgumentParser(description="Fan work out to concurrent Muse Code instances.")
    ap.add_argument("--tasks", required=True, help="JSON file: list of {id, prompt, ...}")
    ap.add_argument("--repo", default=".")
    ap.add_argument("--out")
    ap.add_argument("--concurrency", type=int, default=3)
    ap.add_argument("--model", default=LATEST,
                    help=f"model id, or '{LATEST}' (default) to resolve the newest "
                         "contributor model from the live catalog")
    ap.add_argument("--effort", default=DEFAULT_EFFORT,
                    choices=["none", "minimal", "low", "medium", "high", "xhigh", "max"])
    ap.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT, help="per-task seconds")
    ap.add_argument("--max-steps", type=int, default=0, help="cap agent loop length")
    ap.add_argument("--base", default="HEAD", help="ref each worktree branches from")
    ap.add_argument("--schema", help="JSON Schema file for structured answers")
    ap.add_argument("--branch-prefix", default="fleet")
    ap.add_argument("--worktree-root", default=None,
                    help="where worktrees live (default: sibling of repo, keeps repo clean)")
    ap.add_argument("--commit", action="store_true", help="commit inside each worktree")
    ap.add_argument("--cleanup", action="store_true", help="remove worktrees+branches after harvest")
    ap.add_argument("--allow-dirty", action="store_true")
    ap.add_argument("--seed", action="append", default=None, metavar="PATH",
                    help="copy this untracked path into each worktree (e.g. .env); repeatable")
    ap.add_argument("--link", action="append", default=None, metavar="PATH",
                    help="symlink this path into each worktree (e.g. node_modules); "
                         "only safe if nothing writes to it")
    ap.add_argument("--exclude", action="append", default=None,
                    help="path pattern to keep out of harvested patches (repeatable)")
    ap.add_argument("--warn-patch-lines", type=int, default=5000,
                    help="flag patches larger than this as oversized")
    ap.add_argument("--inherit-skills", action="store_true",
                    help="let workers load your Claude Code personal skills (off by default)")
    ap.add_argument("--no-secret-scan", action="store_true",
                    help="skip the pre-delegation credential scan")
    ap.add_argument("--allow-secrets", action="store_true",
                    default=not core.user_option("refuse_on_secrets", True),
                    help="scan, report, but do not refuse on a confirmed credential")
    args = ap.parse_args()

    if args.exclude is None:
        args.exclude = DEFAULT_EXCLUDES
    args.model, how = resolve_model(args.model)
    repo = Path(args.repo).resolve()
    if args.schema:
        try:
            check_schema(args.schema)
        except core.PreflightError as e:
            sys.exit(str(e))
    try:
        head = preflight(repo, require_clean=not args.allow_dirty)
    except core.PreflightError as e:
        sys.exit(str(e))

    stamp = new_stamp()
    out = Path(args.out).resolve() if args.out else repo / ".muse-fleet" / stamp
    out.mkdir(parents=True, exist_ok=True)
    if args.worktree_root is None:
        args.worktree_root = str(repo.parent / f".muse-fleet-wt-{repo.name}")
    Path(args.worktree_root).mkdir(parents=True, exist_ok=True)

    tasks = json.loads(Path(args.tasks).read_text(encoding="utf-8"))
    if not isinstance(tasks, list) or not tasks:
        sys.exit("--tasks must be a non-empty JSON list")
    # Each id becomes a worktree directory and a git branch component; a path separator
    # would place artifacts outside the run's output root.
    for task in tasks:
        try:
            core.validate_task_id(str(task.get("id", "")))
        except core.PreflightError as e:
            sys.exit(str(e))
    ids = [t["id"] for t in tasks]
    if len(set(ids)) != len(ids):
        sys.exit("task ids must be unique (they name worktrees and branches)")

    print(f"fleet: {len(tasks)} task(s), concurrency={args.concurrency}, "
          f"model={args.model} [{how}], effort={args.effort}", file=sys.stderr)
    print(f"fleet: base={args.base} ({head[:12]}) out={out}", file=sys.stderr)

    # A fresh worktree has no untracked files. Saying so beats letting every agent
    # rediscover it by failing to run the verification command.
    named = set(args.seed or []) | set(args.link or [])
    absent = [f for f in COMMON_LOCAL if (repo / f).exists() and f not in named]
    if absent:
        print(f"fleet: note — {', '.join(absent)} exist in the repo but will NOT be in the "
              f"worktrees (git does not track them). Pass --seed/--link if tasks need them.",
              file=sys.stderr)

    t0 = time.time()
    results: list[dict] = []
    # Ctrl-C used to cost the whole remaining fleet: the executor's context manager
    # waits for every queued task before the exception propagates, and the traceback then
    # escaped before the report was written -- leaving harvested patches with no index.
    interrupted = False
    ex = cf.ThreadPoolExecutor(max_workers=args.concurrency)
    try:
        futs = {ex.submit(run_task, t, repo, out, args): t["id"] for t in tasks}
        for fut in cf.as_completed(futs):
            tid = futs[fut]
            try:
                rec = fut.result()
            except Exception as e:  # a crashed worker must not sink the fleet
                rec = {"id": tid, "status": "crashed", "reason": str(e)}
            results.append(rec)
            print(f"  [{rec['status']:>9}] {tid}  {rec.get('elapsed_s','?')}s  "
                  f"{rec.get('patch_lines',0)} patch lines", file=sys.stderr)
    except KeyboardInterrupt:
        interrupted = True
        print("\ninterrupted — cancelling queued tasks; already-started ones finish. "
              "The report below covers what completed.", file=sys.stderr)
        try:
            ex.shutdown(wait=True, cancel_futures=True)
        except TypeError:   # cancel_futures is 3.9+
            ex.shutdown(wait=True)
    finally:
        ex.shutdown(wait=True)

    results.sort(key=lambda r: ids.index(r["id"]) if r["id"] in ids else 0)
    wall = round(time.time() - t0, 1)
    ok = sum(1 for r in results if r["status"] == "completed")
    serial = round(sum(r.get("elapsed_s") or 0 for r in results), 1)

    report = {
        "generated_at": dt.datetime.now().isoformat(timespec="seconds"),
        "repo": str(repo), "base": args.base, "base_commit": head,
        "model": args.model, "model_selection": how, "effort": args.effort,
        "concurrency": args.concurrency,
        "wall_clock_s": wall, "serial_equivalent_s": serial,
        "completed": ok, "total": len(results),
        "interrupted": interrupted, "planned": len(tasks),
        "out_dir": str(out), "worktree_root": args.worktree_root,
        "tasks": results,
    }
    (out / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")

    lines = [
        f"# muse-fleet report — {ok}/{len(results)} completed"
        + (f" (INTERRUPTED — {len(tasks)} were planned)" if interrupted else ""),
        "",
        f"- base `{args.base}` @ `{head[:12]}`",
        f"- model `{args.model}`, effort `{args.effort}`, concurrency {args.concurrency}",
        f"- wall clock **{wall}s** (serial equivalent {serial}s)",
        f"- patches in `{out}`",
        "",
        "| task | status | time | files | patch | summary |",
        "|---|---|---|---|---|---|",
    ]
    for r in results:
        files = ", ".join(f"`{f}`" for f in (r.get("files_changed") or [])[:4]) or "—"
        summ = (r.get("summary") or r.get("reason") or "").replace("\n", " ")[:110]
        size = str(r.get("patch_lines", 0))
        if r.get("oversized"):
            size += " ⚠"
        lines.append(
            f"| {r['id']} | {r['status']} | {r.get('elapsed_s','?')}s | {files} "
            f"| {size} | {summ} |"
        )
    big = [r for r in results if r.get("oversized")]
    if big:
        lines += ["", "## Oversized patches", "",
                  "Larger than expected — check for build artifacts the excludes missed "
                  "before applying:", ""]
        lines += [f"- **{r['id']}**: {r['patch_lines']} lines" for r in big]
    failed = [r for r in results if r["status"] != "completed"]
    if failed:
        lines += ["", "## Needs attention", ""]
        lines += [f"- **{r['id']}** ({r['status']}): {r.get('reason') or 'see stderr.log'}"
                  for r in failed]
    lines += ["", "## Apply a patch", "",
              "```bash", f"git apply --3way {out}/<id>/patch.diff", "```", ""]
    (out / "report.md").write_text("\n".join(lines), encoding="utf-8")

    print(f"\nfleet: {ok}/{len(results)} completed in {wall}s "
          f"(serial would be ~{serial}s)", file=sys.stderr)
    print(f"fleet: report -> {out}/report.md", file=sys.stderr)
    # An interrupted run is not a success even if everything that ran succeeded.
    return 0 if (ok == len(results) and not interrupted) else 1


if __name__ == "__main__":
    sys.exit(main())
