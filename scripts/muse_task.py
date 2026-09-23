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

Rounds share one worktree AND one muse session. Reusing --session-id across `muse exec`
invocations continues the conversation -- measured: a fact planted in one call is recalled
in the next, while a fresh id or no id is not -- so a revision arrives as a follow-up rather
than a re-brief. When the session cannot be found on disk the round falls back to resending
the full brief, because muse starts a fresh conversation silently rather than erroring.

The worktree matters independently of the session:
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
import secrets
import subprocess
import sys
import traceback
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "muse_core", str(Path(__file__).resolve().parent / "muse_core.py"))
core = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(core)

DEFAULT_MAX_ROUNDS = 3


def state_path(tdir: Path) -> Path:
    return tdir / "state.json"


def load_state(tdir: Path) -> dict:
    """Read task state, or emit a JSON refusal and exit.

    Every subcommand is documented as printing one JSON object on stdout, and a
    supervisor parses that stream -- a bare exit or a JSONDecodeError traceback tells it
    nothing it can act on."""
    p = state_path(tdir)
    if not p.exists():
        emit({"id": tdir.name, "status": "no_such_task",
              "reason": "no state at {}. Run `muse_task.py run --id <id> --out <dir> ...` "
                        "first.".format(p)})
        sys.exit(1)
    try:
        st = json.loads(p.read_text(encoding="utf-8"))
    except (ValueError, OSError) as e:
        emit({"id": tdir.name, "status": "state_corrupt",
              "reason": "{} is not readable task state ({}). It may be a crash mid-write; "
                        "inspect it, or re-run `run --force` to start over.".format(p, e)})
        sys.exit(1)
    if not isinstance(st, dict):
        emit({"id": tdir.name, "status": "state_corrupt",
              "reason": "{} does not contain a task object".format(p)})
        sys.exit(1)
    return st


def save_state(tdir: Path, st: dict) -> None:
    """Write state atomically.

    A plain write truncates first, so a crash or ENOSPC mid-write leaves unparseable
    JSON -- and every later subcommand on that task then fails on it."""
    p = state_path(tdir)
    tmp = p.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(st, indent=2), encoding="utf-8")
    os.replace(str(tmp), str(p))


def emit(obj: dict) -> None:
    """One JSON object on stdout. The supervisor parses this; everything else is stderr."""
    print(json.dumps(obj, indent=2))


def _nt_pid_alive(pid: int) -> bool:
    import ctypes
    k = ctypes.windll.kernel32
    h = k.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not h:
        return False
    code = ctypes.c_ulong()
    try:
        return bool(k.GetExitCodeProcess(h, ctypes.byref(code))) and code.value == 259
    finally:
        k.CloseHandle(h)


def marker_live(m) -> bool:
    """Whether a round_in_flight marker names a worker that is still running."""
    if not isinstance(m, dict) or not isinstance(m.get("pid"), int):
        return False
    if os.name == "nt":
        # No signal-0 probe there, and os.kill on Windows TERMINATES the process.
        return _nt_pid_alive(m["pid"])
    if not core.HAVE_PROCESS_GROUPS:
        return False
    try:
        os.kill(m["pid"], 0)
        return True
    except PermissionError:
        return True
    except ProcessLookupError:
        pass
    except OSError:
        return False
    pgid = m.get("pgid")
    if isinstance(pgid, int):
        try:
            os.killpg(pgid, 0)
            return True
        except PermissionError:
            return True
        except (ProcessLookupError, OSError):
            pass
    return False


def refuse_if_in_flight(tdir: Path, st: dict) -> bool:
    """Refuse to start a second worker while the recorded round is still alive."""
    m = st.get("round_in_flight")
    if not m:
        return False
    if marker_live(m):
        emit({"id": st["id"], "status": "round_in_flight",
              "pid": m.get("pid"), "pgid": m.get("pgid"), "started": m.get("started"),
              "reason": ("a muse round is still running in this worktree (pid {})"
                         "; starting another would put two workers in one tree and one "
                         "session. Wait for it, or kill that process group, then retry."
                         .format(m.get("pid")))})
        return True
    st.pop("round_in_flight", None)
    save_state(tdir, st)
    print("muse_task[{}]: cleared a stale round_in_flight marker".format(st["id"]),
          file=sys.stderr)
    return False


def artifact_root(args) -> Path:
    """Where `<out>/<id>/` lives, resolved so it does not move with the cwd.

    An agent's Bash cwd resets between tool calls and the documented `--out` is the
    relative `.muse-fleet/tasks`, so `Path(out).resolve()` meant `run` from the repo root
    and `verify` from a subdirectory addressed two different task directories. The second
    reported `no_such_task`, and the supervisor's natural recovery -- `run --force` --
    discards the patch the first one had just made.

    A relative `--out` resolves against the owning repository, which is what it is
    actually relative to. A task worktree and a linked worktree share the owning
    repo's common dir, so `--show-toplevel` would return the worktree itself and
    lose the task. An absolute `--out` is untouched. Outside a repository there is
    nothing better than the cwd, which is where this started."""
    out = Path(args.out)
    if out.is_absolute():
        return out.resolve()
    # On `run` the repository is whatever --repo names; everywhere else the only thing
    # available is the cwd, and cmd_run refuses the combination where those disagree.
    anchor = Path(getattr(args, "repo", ".") or ".")
    top = core.owning_repo(anchor if anchor.exists() else Path.cwd())
    return ((top or Path.cwd()) / out).resolve()


def task_dir(args) -> Path:
    return artifact_root(args) / args.id


def harvest_base(st: dict) -> str:
    """What to diff the worktree against.

    The pinned sha, always, when we have one. Diffing against the ref NAME means a branch
    that moves mid-task silently pulls other people's commits into this task's patch --
    and `git apply` then deletes their work. State written before base_sha was recorded
    falls back to the ref so old tasks still harvest."""
    return st.get("base_sha") or st["base"]


def round_exit_code(out: dict) -> int:
    """0 only when the round actually produced something.

    A timed-out or crashed round still emits a full record, and returning 0 for it tells
    any caller branching on $? that the work succeeded."""
    if out.get("status") != "completed":
        return 1
    if out.get("harvest_error"):
        return 1
    return 0


def do_round(st: dict, tdir: Path, prompt: str, args, kind: str,
             resumed: bool | None = None) -> dict:
    """Run one muse round into the existing worktree and harvest the cumulative patch."""
    repo = Path(st["repo"])
    wt = Path(st["worktree"])
    n = len(st["rounds"]) + 1
    rdir = tdir / "round-{}".format(n)
    rdir.mkdir(parents=True, exist_ok=True)
    (rdir / "prompt.txt").write_bytes(prompt.encode("utf-8", "surrogateescape"))

    cmd = core.muse_cmd(
        st["model"], st.get("effort", core.DEFAULT_EFFORT), wt,
        schema=st.get("schema"), max_steps=st.get("max_steps") or 0,
        inherit_skills=st.get("inherit_skills", False),
        session_id=st.get("session_id"),
    )
    print("muse_task[{}]: round {} ({}) model={} effort={} session={}".format(
        st["id"], n, kind, st["model"], st.get("effort"),
        "resumed" if resumed else ("new" if resumed is None else "NOT RESUMED")),
        file=sys.stderr)

    def on_spawn(p):
        st["round_in_flight"] = {
            "pid": p.pid,
            "pgid": p.pid if core.HAVE_PROCESS_GROUPS else None,
            "started": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        }
        save_state(tdir, st)

    try:
        res = core.run_muse(cmd, prompt, wt, rdir / "events.jsonl",
                            rdir / "stderr.log",
                            int(st.get("timeout") or core.DEFAULT_TIMEOUT),
                            on_spawn=on_spawn)
    except BaseException:
        # The round spent money and touched the tree, so it must count against
        # max_rounds. Stdout must still carry one JSON object.
        reason = ("supervisor received a termination signal; "
                  "the worker's process group was killed")
        rnd = {"n": n, "kind": kind, "status": "interrupted", "reason": reason,
               "session_id": st.get("session_id"), "resumed": bool(resumed),
               "patch_lines": 0, "files_changed": [],
               "events": str(rdir / "events.jsonl"),
               "stderr": str(rdir / "stderr.log")}
        st.pop("round_in_flight", None)
        st["rounds"].append(rnd)
        save_state(tdir, st)
        emit({"id": st["id"], "round": n, "kind": kind, "status": "interrupted",
              "reason": reason, "worktree": st["worktree"],
              "rounds_used": n,
              "rounds_left": max(0, int(st["max_rounds"]) - n)})
        raise

    rnd = {
        "n": n, "kind": kind, "status": res["status"], "reason": res["reason"],
        "session_id": st.get("session_id"), "resumed": bool(resumed),
        "elapsed_s": res["elapsed_s"], "model_actual": res["model_actual"],
        # What muse itself said, so a failed round is diagnosable from the record
        # instead of only from a log file nothing tells the supervisor to open.
        "exit_code": res.get("exit_code"), "stderr_tail": res.get("stderr_tail", "")[-800:],
        "events": str(rdir / "events.jsonl"),
        "stderr": str(rdir / "stderr.log"),
        "patch_lines": 0, "files_changed": [], "patch_fingerprint": None,
    }
    # The round spent money, and an exception later in harvest or fingerprinting used
    # to un-count it, letting max_rounds be bypassed. Record it before that can happen.
    st.pop("round_in_flight", None)
    st["rounds"].append(rnd)
    save_state(tdir, st)

    # Structured self-report, when a schema was supplied. This is a set of CLAIMS by the
    # same cheap model that did the work -- the supervisor checks it against the patch
    # and against `verify`, it is never evidence on its own.
    result = None
    if st.get("schema") and (res["text"] or "").strip():
        parsed = core.parse_answers(res["text"])
        if isinstance(parsed, dict):
            result = parsed
            (rdir / "result.json").write_text(json.dumps(parsed, indent=2), encoding="utf-8")
    if result is None and res["text"]:
        rnd["text"] = res["text"][:2000]

    h = core.harvest(wt, harvest_base(st), st["excludes"], tdir / "patch.diff")
    try:
        fp = core.patch_fingerprint(wt, harvest_base(st), st["excludes"])
    except Exception as e:
        fp = None
        rnd["fingerprint_error"] = "{}: {}".format(type(e).__name__, e)[:300]
    rnd.update({"patch_lines": h["patch_lines"], "files_changed": h["files_changed"],
                # The deliverable as muse left it. finish compares against this to tell
                # muse's work apart from anything written into the worktree afterwards.
                "patch_fingerprint": fp})
    if h["harvest_error"]:
        rnd["harvest_error"] = h["harvest_error"]
    save_state(tdir, st)

    out = {
        "id": st["id"], "round": n, "kind": kind,
        "status": res["status"], "reason": res["reason"],
        "exit_code": res.get("exit_code"),
        "stderr_tail": res.get("stderr_tail", "")[-800:],
        # The supervisor needs to know whether this round continued the conversation or
        # started a fresh one: a revision that did NOT resume only knows what its prompt
        # carried, which changes how its output should be read.
        "session_id": st.get("session_id"), "resumed": bool(resumed),
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
    if rnd.get("fingerprint_error"):
        out["fingerprint_error"] = rnd["fingerprint_error"]
    return out


# ---------------------------------------------------------------------- run

def cmd_run(args) -> int:
    repo = Path(args.repo).resolve()
    # A relative --out is resolved against the repository it belongs to. `run` knows
    # which one that is; `verify` and `finish` have only the cwd. When those two are
    # different repositories the later commands cannot find the task, and the failure
    # looks like a missing task rather than a mis-resolved path -- so refuse here, where
    # the absolute path to pass is still known.
    if not Path(args.out).is_absolute():
        here = core.owning_repo(Path.cwd())
        there = core.owning_repo(repo)
        if there is not None and (here is None or here.resolve() != there.resolve()):
            emit({"id": args.id, "status": "refused",
                  "reason": "--out {!r} is relative and --repo points at a different "
                            "repository than the current directory, so the later "
                            "subcommands would resolve it somewhere else and report "
                            "no_such_task. Pass --out {}."
                            .format(args.out, (there / args.out).resolve())})
            return 1
    try:
        core.validate_task_id(args.id)
        head = core.preflight(repo, require_clean=not args.allow_dirty)
        if args.schema:
            core.check_schema(args.schema)
    except core.PreflightError as e:
        # One JSON object on stdout, even on refusal: a supervisor parses this stream and
        # an empty one tells it nothing.
        emit({"id": args.id, "status": "refused", "reason": str(e)})
        return 1

    model, how = core.resolve_model(args.model)
    tdir = task_dir(args)
    tdir.mkdir(parents=True, exist_ok=True)

    # Re-running an id that already has a task is destructive twice over: harvest
    # overwrites patch.diff, and replacing state.json orphans the previous worktree and
    # branch -- `cleanup` then has no record of them and skips them as unfinished. Both
    # happen silently, and the lost patch may be work nobody applied yet.
    prior, unreadable = None, False
    if state_path(tdir).exists():
        try:
            prior = json.loads(state_path(tdir).read_text(encoding="utf-8"))
        except (ValueError, OSError):
            unreadable = True
        if prior is not None and not isinstance(prior, dict):
            prior, unreadable = None, True
    if unreadable and not args.force:
        # "Exists but unreadable" is not "absent". Treating it as absent is how a crash
        # mid-write silently defeats this very guard and overwrites the patch.
        emit({"id": args.id, "status": "refused",
              "reason": "{} exists but is not readable task state. It may be a crash "
                        "mid-write. Inspect or remove it, or pass --force to start over "
                        "(which discards any patch already harvested there)."
                        .format(state_path(tdir))})
        return 1
    if isinstance(prior, dict) and marker_live(prior.get("round_in_flight")):
        # Even with --force: it force-removes the worktree a live worker is writing
        # into. A stale marker needs no action: run replaces the state.
        m = prior.get("round_in_flight")
        emit({"id": args.id, "status": "round_in_flight",
              "pid": m.get("pid"), "pgid": m.get("pgid"), "started": m.get("started"),
              "reason": ("a muse round is still running in this worktree (pid {})"
                         "; starting another would put two workers in one tree and one "
                         "session. Wait for it, or kill that process group, then retry."
                         .format(m.get("pid")))})
        return 1
    if prior is not None and not args.force:
        emit({
            "id": args.id, "status": "refused",
            "reason": "task {} already exists at {}. Re-running would overwrite its patch "
                      "and orphan its worktree. Apply or copy the patch first, then pass "
                      "--force, or use a different --id.".format(args.id, tdir),
            "existing_patch": str(tdir / "patch.diff") if (tdir / "patch.diff").exists() else None,
            "existing_worktree": prior.get("worktree"),
            "existing_verdict": prior.get("verdict"),
            "rounds_used": len(prior.get("rounds") or []),
        })
        return 1
    if prior is not None:
        # --force: tear down what we are about to orphan, using the OLD recorded paths.
        # The `wt`/`branch` computed below belong to the new stamp and would not match.
        try:
            core.drop_worktree(Path(prior["repo"]), Path(prior["worktree"]), prior["branch"])
        except (KeyError, OSError) as e:
            print("muse_task[{}]: could not drop the previous worktree ({}); "
                  "it may need `git worktree prune`".format(args.id, e), file=sys.stderr)

    # Entropy in the stamp, for the reason muse_fleet.py already carries it: a bare
    # second-resolution timestamp means two runs started in the same second compute the
    # same branch and the same worktree path, and `drop_worktree` below opens with
    # `git worktree remove --force`. This is the documented single-task path and it was
    # the only one without the defence. 4 bytes, not 2 -- the birthday bound on 2 bytes
    # is ~1.9% across 50 runs, which a probabilistic test in the suite duly hit.
    stamp = args.stamp or "{}-{}".format(
        dt.datetime.now().strftime("%Y%m%d-%H%M%S"), secrets.token_hex(4))
    branch = "{}/{}/{}".format(args.branch_prefix, stamp, args.id)
    wt_root = Path(args.worktree_root) if args.worktree_root \
        else repo.parent / ".muse-fleet-wt-{}".format(repo.name)
    wt_root.mkdir(parents=True, exist_ok=True)
    wt = wt_root / "{}-{}".format(stamp, args.id)

    base = args.base
    # Pin the base to a SHA now. harvest used to diff against the ref NAME, so a branch
    # that moved mid-task made the patch include -- and on `git apply` delete -- whatever
    # landed on it meanwhile. The ref is kept for display; the sha is what we diff.
    try:
        base_sha = core.git(repo, "rev-parse", "--verify", base).strip()
    except Exception:
        emit({"id": args.id, "status": "refused",
              "reason": "--base {!r} does not resolve to a commit".format(base)})
        return 1
    ours = bool(prior) and prior.get("branch") == branch
    hit = None if args.force else core.collision(repo, wt, branch, ours_branch=ours)
    if hit:
        rec = {"id": args.id, "status": "refused",
               "reason": hit["reason"] + " Use a different --id or "
                         "--branch-prefix/--worktree-root, or pass --force."}
        if hit["kind"] == "branch":
            rec["branch"] = branch
        elif hit["kind"] == "worktree":
            rec["worktree"] = str(wt)
        emit(rec)
        return 1
    core.drop_worktree(repo, wt, branch)
    try:
        core.git(repo, "worktree", "add", "-q", "-b", branch, str(wt), base)
    except Exception as e:
        emit({"id": args.id, "status": "setup_failed", "reason": str(e)})
        return 1

    seeded = core.seed_worktree(repo, wt, args.seed or [], args.link or [])

    # Scan the worktree AFTER seeding and BEFORE spawning muse -- seeding is the step
    # that deliberately copies untracked secrets (`--seed .env`) into the tree a worker
    # can read. Refusing on a `certain` hit is the safe default because the exposure is
    # not undoable: contributor-tier models state that content may be used for product
    # improvement. `possible` hits only warn; blocking on those would make the plugin
    # unusable on any repo with test fixtures.
    pf = core.preflight_secrets([wt], {"allow_secrets": args.allow_secrets,
                                       "no_secret_scan": args.no_secret_scan})
    scan = {"certain": pf["certain"], "possible": pf["possible"],
            "files_scanned": pf["files_scanned"], "truncated": pf["truncated"]}
    if pf["refuse"]:
        core.drop_worktree(repo, wt, branch)
        emit({
            "id": args.id, "status": "refused",
            "reason": pf["reason"],
            "secrets": pf["certain"][:20],
            "possible_secrets": len(pf["possible"]),
            "files_scanned": pf["files_scanned"],
            "truncated": pf["truncated"],
        })
        return 1
    if scan["certain"] or scan["possible"] or scan["truncated"]:
        print("muse_task[{}]: secret scan — {} certain, {} possible across {} files{}"
              .format(args.id, len(scan["certain"]), len(scan["possible"]),
                      scan["files_scanned"],
                      " (PARTIAL — hit the file cap, the rest of the tree was not "
                      "scanned)" if scan["truncated"] else ""), file=sys.stderr)
    absent = core.absent_locals(repo, (args.seed or []) + (args.link or []))
    if absent:
        print("muse_task[{}]: note — {} exist in the repo but NOT in the worktree; "
              "pass --seed/--link if the acceptance check needs them."
              .format(args.id, ", ".join(absent)), file=sys.stderr)

    st = {
        "id": args.id, "repo": str(repo), "worktree": str(wt), "branch": branch,
        "base": base, "base_sha": base_sha, "model": model, "model_choice": how,
        "effort": args.effort, "timeout": args.timeout, "max_steps": args.max_steps,
        "schema": str(Path(args.schema).resolve()) if args.schema else None,
        "excludes": args.exclude if args.exclude is not None else core.DEFAULT_EXCLUDES,
        "inherit_skills": args.inherit_skills,
        "warn_patch_lines": args.warn_patch_lines,
        "max_rounds": args.max_rounds,
        "brief": args.prompt,
        # One session for the whole task, so every later round continues this conversation.
        "session_id": core.new_session_id(),
        "seeded": seeded, "absent_locals": absent,
        "secret_scan": {"certain": len(scan["certain"]),
                        "possible": len(scan["possible"]),
                        "files_scanned": scan["files_scanned"],
                        "truncated": scan["truncated"],
                        "skipped": bool(args.no_secret_scan)},
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
    return round_exit_code(out)


# ------------------------------------------------------------------- revise

# Used when the muse session resumed: the worker still has the brief, the files it read
# and its own reasoning in context, so restating all of it wastes tokens and invites it to
# re-litigate settled decisions.
REVISION_RESUMED_TEMPLATE = """REVISION ROUND {n}, continuing our session. Your previous
attempt is already in this working tree.

A reviewer inspected your work and requires these specific changes:

{feedback}

Fix exactly these points. Do NOT revert or rewrite unrelated work already in the tree that
the reviewer did not object to, and do not start over from scratch.
"""

# Used when the session could not be found. muse does not error on an unknown --session-id,
# it silently starts fresh -- so this round must carry the whole brief or the worker gets
# bare feedback with nothing behind it.
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
    if refuse_if_in_flight(tdir, st):
        return 1
    if st.get("done"):
        emit({"id": st["id"], "status": "refused",
              "reason": "task already finished. Start a fresh attempt with a new --id, or "
                        "`run --force` on this one (which discards its patch and worktree)."})
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
        feedback = Path(args.feedback_file).read_text(encoding="utf-8", errors="replace")
    # Pass the worktree: a session bound to a different workspace is not resumable, and
    # muse fails the whole run rather than starting fresh if you try.
    resumed = core.session_exists(st.get("session_id") or "", workspace=st["worktree"])
    if resumed:
        prompt = REVISION_RESUMED_TEMPLATE.format(n=used + 1, feedback=feedback)
    else:
        prompt = REVISION_TEMPLATE.format(n=used + 1, feedback=feedback, brief=st["brief"])

    out = do_round(st, tdir, prompt, args, "revision", resumed=resumed)
    if not resumed:
        out["session_warning"] = (
            "muse session {} is not resumable here -- either it is not on disk, or it is "
            "bound to a different workspace -- so this round re-sent the full brief "
            "instead of continuing the conversation. The worker does not remember its "
            "previous reasoning.".format(st.get("session_id"))
        )
    out["next"] = ("Re-run `verify`, then `finish` with a verdict. "
                   "{} round(s) left.".format(out["rounds_left"]))
    emit(out)
    return round_exit_code(out)


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
    fp = lambda: core.patch_fingerprint(wt, harvest_base(st), st["excludes"])
    rec = {
        "after_round": len(st["rounds"]),
        "command": args.command,
        # The patch this check actually ran against.
        "patch_before": fp(),
    }
    # Popen rather than subprocess.run, and this is the whole point of the method: run's
    # timeout kills only the direct child. The command is a shell line that spawns a test
    # runner or a build, and start_new_session detaches those into their own session --
    # which makes a shell-only kill strictly WORSE, because nothing afterwards can find
    # them. They keep writing into a worktree that `finish --cleanup` is about to force
    # remove, and those writes land in the harvested patch after the check was declared.
    # kill_process_tree signals the whole group, which is what the session was created
    # for. This comment used to claim the group kill happened; it did not.
    p = subprocess.Popen(args.command, cwd=str(wt), shell=True,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         start_new_session=True)
    dec = lambda b: (b or b"").decode("utf-8", "replace")
    try:
        stdout, stderr = p.communicate(timeout=args.timeout)
        rec.update({
            "exit_code": p.returncode,
            "passed": p.returncode == 0,
            "stdout_tail": tail(dec(stdout)),
            "stderr_tail": tail(dec(stderr)),
        })
    except subprocess.TimeoutExpired:
        # A hung check must come back as a parseable failure. Raising here would hand
        # the supervisor a traceback on stdout instead of JSON, and it would have no
        # way to tell "the check hung" from "the script is broken".
        core.kill_process_tree(p)
        try:
            # Drain whatever it managed to write. Safe to block briefly now: every
            # writer holding the other end of these pipes has just been signalled.
            stdout, stderr = p.communicate(timeout=10)
        except (subprocess.TimeoutExpired, ValueError, OSError):
            stdout = stderr = b""
        rec.update({
            "exit_code": None, "passed": False, "timed_out": True,
            "stdout_tail": tail(dec(stdout)),
            "stderr_tail": "acceptance check exceeded {}s".format(args.timeout),
        })
    # Taken AFTER the command, and this is the one finish compares against. A check is
    # allowed to change the worktree -- a build step, a formatter, a migration -- and
    # comparing against the pre-command fingerprint would refuse every one of those as a
    # TOCTOU. What must not happen is a change between the check finishing and the
    # harvest, which is the window an out-of-band write actually lives in.
    rec["patch_after"] = fp()
    if rec["patch_before"] != rec["patch_after"]:
        # Not fatal, but the patch that ships is then not the patch the check read.
        rec["check_mutated_patch"] = True
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
        # .get throughout: this is the inspection command, so it is what a supervisor
        # reaches for when something has already gone wrong. State written by an older
        # version, or truncated by a crash, must come back as JSON with holes in it
        # rather than a KeyError traceback on the stream the supervisor parses.
        "id": st.get("id", args.id), "done": st.get("done", False),
        "worktree": st.get("worktree"), "branch": st.get("branch"), "base": st.get("base"),
        "model": st.get("model"), "effort": st.get("effort"),
        "rounds_used": len(st.get("rounds") or []), "max_rounds": st.get("max_rounds"),
        "patch": str(tdir / "patch.diff"),
        "patch_lines": (st.get("rounds") or [{}])[-1].get("patch_lines", 0),
        "files_changed": (st.get("rounds") or [{}])[-1].get("files_changed", []),
        "verifications": st.get("verifications", []),
        "rounds": [{k: r.get(k) for k in ("n", "kind", "status", "elapsed_s", "patch_lines")}
                   for r in (st.get("rounds") or [])],
    })
    return 0


def cmd_finish(args) -> int:
    tdir = task_dir(args)
    st = load_state(tdir)

    # cmd_revise refuses a finished task and this had no equivalent guard, so a second
    # finish silently replaced the first verdict, summary and concerns and re-harvested
    # on top -- folding in whatever had been written since. A refusal is not a finish:
    # the accept gate returns before `done` is set, so re-verifying and finishing again
    # after one is the normal path and is not what this stops.
    if st.get("done") and not args.force:
        emit({"id": st["id"], "status": "refused",
              "reason": "task already finished with verdict '{}'. Finishing again would "
                        "replace that verdict and re-harvest over the recorded patch. "
                        "Pass --force if that is genuinely what you want."
                        .format(st.get("verdict")),
              "verdict": st.get("verdict"),
              "patch": str(tdir / "patch.diff")})
        return 1

    # Re-harvest so the recorded patch reflects the tree as it stands right now. Note what
    # that means: a supervisor that edited the worktree by hand gets its edit folded into
    # this patch. Withholding Write and Edit from the supervisor makes that unlikely, not
    # impossible -- it still has Bash, and a shell redirect is a write -- so the fold is
    # measured below as out_of_band_edit rather than assumed away.
    wt_here = Path(st["worktree"])
    h = core.harvest(wt_here, harvest_base(st), st["excludes"], tdir / "patch.diff") \
        if wt_here.exists() else {"patch_lines": 0, "files_changed": [],
                                  "harvest_error": "worktree missing"}
    # Taken here, beside the harvest, and deliberately BEFORE --commit: this has to
    # describe the same bytes that just went into patch.diff. Pinning the base to a sha
    # makes a commit invisible to the diff, so measuring after would give the same answer
    # today -- but it would make this correct by coincidence rather than by construction.
    now = core.patch_fingerprint(wt_here, harvest_base(st), st["excludes"]) \
        if wt_here.exists() else None
    if args.commit and h["patch_lines"]:
        core.commit_worktree(Path(st["worktree"]),
                             "muse({}): {}".format(st["id"], (args.summary or st["id"])[:70]))

    # The LAST verification, not "any that ever passed". A supervisor legitimately runs
    # several checks -- a cheap gate first, the real acceptance check after, and failing
    # rounds before a fixed one -- so "any passed" marks a task verified whenever a
    # collect-only gate succeeded and the real check went red. Observed exactly that.
    verifs = st.get("verifications", [])
    final = verifs[-1] if verifs else None
    # Three separate questions, deliberately not collapsed: did a check run, did the last
    # one pass, and was it looking at THIS patch. Only all three together mean verified.
    passed = bool(final) and bool(final.get("passed"))
    certified = bool(final) and bool(final.get("patch_after")) and final["patch_after"] == now
    stale = passed and bool(final.get("patch_after")) and not certified
    verified = passed and certified

    # #10: the supervisor has no Write or Edit tool, and it has Bash -- a shell redirect
    # is a write, and `verify --command` runs with shell=True inside the worktree. The
    # toolset is a strong default, not a boundary, so the honest move is to measure the
    # delta rather than claim it cannot happen. Anything between what muse last produced
    # and what is being harvested now was written by something other than muse.
    last_round_fp = next((r.get("patch_fingerprint") for r in reversed(st["rounds"])
                          if r.get("patch_fingerprint")), None)
    out_of_band = bool(last_round_fp) and bool(now) and last_round_fp != now
    mutating = [v["command"] for v in verifs if v.get("check_mutated_patch")]

    # #9: the verdict is now GATED, not merely annotated. Four documents say `accept`
    # means a supervisor ran a check that passed; until now nothing stopped an accept
    # with no check at all, and the suite asserted that was allowed.
    if args.verdict == "accept" and not verified and not args.accept_unverified:
        if stale:
            why = ("the check that passed produced a different patch than the one being "
                   "harvested -- something changed the worktree after the check finished")
        elif final is None:
            why = "no acceptance check was ever run on this task"
        elif not passed:
            why = "the final acceptance check exited {}".format(final.get("exit_code"))
        else:
            why = ("the passing check recorded no patch fingerprint, so it cannot be tied "
                   "to this patch (state written by an older version)")
        emit({"id": st["id"], "status": "refused", "reason":
              "refusing --verdict accept: {}. Run `verify` against the current tree, or "
              "pass --accept-unverified \"<reason>\" if this is the known case where a "
              "correct patch makes a check legitimately fail.".format(why),
              "passed": passed, "certified": certified, "stale": stale})
        return 1

    st.update({
        "done": True,
        "verdict": args.verdict,
        "summary": args.summary,
        "concerns": args.concern or [],
        "final_patch_lines": h["patch_lines"],
        "final_files_changed": h["files_changed"],
        "out_of_band_edit": out_of_band,
        "accepted_unverified": args.accept_unverified or None,
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
        "accepted_unverified": args.accept_unverified or None,
        # Attribution, not accusation: the harvested patch differs from what muse left,
        # and `mutating_checks` names the acceptance checks that account for part of it.
        "out_of_band_edit": out_of_band,
        "mutating_checks": mutating,
        "verifications": st.get("verifications", []),
    }
    if h.get("harvest_error"):
        out["harvest_error"] = h["harvest_error"]
    (tdir / "task.json").write_text(json.dumps(out, indent=2), encoding="utf-8")

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
    core.install_signal_handlers()
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
    # Defaults come from userConfig where the runtime supplied it, and are otherwise
    # exactly what they have always been -- an install that skipped the prompts must
    # behave identically to one from before there was any configuration.
    p.add_argument("--model", default=core.user_option("default_model", core.LATEST))
    p.add_argument("--effort", default=core.user_option("default_effort", core.DEFAULT_EFFORT),
                   choices=core.EFFORTS)
    p.add_argument("--timeout", type=int, default=core.DEFAULT_TIMEOUT)
    p.add_argument("--max-steps", type=int, default=0)
    p.add_argument("--max-rounds", type=int,
                   default=core.user_option("max_rounds", DEFAULT_MAX_ROUNDS),
                   help="hard cap on revision rounds (runaway-cost breaker)")
    p.add_argument("--base", default="HEAD")
    p.add_argument("--schema")
    p.add_argument("--branch-prefix", default="muse")
    p.add_argument("--worktree-root", default=core.user_option("worktree_root", None))
    p.add_argument("--stamp", default=None,
                   help="shared run stamp so sibling tasks land under one namespace")
    p.add_argument("--allow-dirty", action="store_true")
    p.add_argument("--seed", action="append", default=None, metavar="PATH")
    p.add_argument("--link", action="append", default=None, metavar="PATH")
    p.add_argument("--exclude", action="append", default=None)
    p.add_argument("--warn-patch-lines", type=int, default=5000)
    p.add_argument("--inherit-skills", action="store_true")
    p.add_argument("--force", action="store_true",
                   help="re-run over an existing task, discarding its patch and worktree")
    p.add_argument("--no-secret-scan", action="store_true",
                   help="skip the pre-delegation credential scan")
    p.add_argument("--allow-secrets", action="store_true",
                   default=not core.user_option("refuse_on_secrets", True),
                   help="scan, report, but do not refuse on a confirmed credential")
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
    p.add_argument("--accept-unverified", metavar="REASON",
                   help="accept despite no passing check tied to this tree; the reason is "
                        "recorded in task.json and shown by /muse:status")
    p.add_argument("--summary", default="")
    p.add_argument("--concern", action="append", default=None,
                   help="residual concern for the human reviewer (repeatable)")
    p.add_argument("--commit", action="store_true")
    p.add_argument("--cleanup", action="store_true")
    p.add_argument("--force", action="store_true",
                   help="finish a task that already has a verdict, replacing it")
    p.set_defaults(fn=cmd_finish)

    p = sub.add_parser("cleanup", help="drop the worktree and branch")
    common(p)
    p.set_defaults(fn=cmd_cleanup)

    args = ap.parse_args()
    # Every subcommand turns --id into a filesystem path; cmd_run re-checks so its
    # refusal carries the same JSON shape as its other failures.
    try:
        core.validate_task_id(args.id)
    except core.PreflightError as e:
        emit({"id": args.id, "status": "refused", "reason": str(e)})
        return 1
    try:
        return args.fn(args)
    except Exception as e:
        traceback.print_exc(file=sys.stderr)
        emit({"id": args.id, "status": "error", "error_type": type(e).__name__,
              "reason": "{}: {}".format(type(e).__name__, e)[:2000]})
        return 1


if __name__ == "__main__":
    sys.exit(main())
