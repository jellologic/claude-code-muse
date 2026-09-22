#!/usr/bin/env python3
"""
muse_doctor.py — is this machine actually able to delegate, and what would it use?

The SessionStart hook answers one question ("would delegation fail right now?") and
stays silent otherwise, which is right for a hook and useless for diagnosing. This is
the other half: every input a run depends on, its current value, and whether that value
is a problem.

Three severities, and the distinction is the point:

    FAIL   delegation cannot work until you fix this
    WARN   it will work, but not the way you probably expect
    OK     checked, with the value shown -- not merely "present"

Exits non-zero if anything FAILed, so it can gate a script.

    muse_doctor.py                  # this machine, and the repo in the current directory
    muse_doctor.py --repo /path     # a specific repo
    muse_doctor.py --scan           # also scan that repo for credentials
    muse_doctor.py --json           # machine-readable
"""

from __future__ import annotations

import argparse
import glob
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load_core():
    spec = importlib.util.spec_from_file_location("muse_core", HERE / "muse_core.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def run(cmd, timeout=10):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, (r.stdout or r.stderr).strip()
    except (OSError, subprocess.SubprocessError) as e:
        return 1, str(e)


def check_muse(out):
    if shutil.which("muse") is None:
        out.append(("FAIL", "muse binary", "not on PATH",
                    "Install Muse Code, or add its install dir (often ~/.local/bin) to PATH."))
        return False
    rc, ver = run(["muse", "--version"])
    if rc != 0:
        out.append(("FAIL", "muse binary", "found but `muse --version` failed: %s" % ver[:60],
                    "The binary on PATH may be broken or a different program."))
        return False
    first = (ver.splitlines() or [""])[0].strip()
    if not first:
        # A binary named `muse` that exits 0 and prints nothing is not Muse Code -- most
        # likely a stub or a different program of the same name. Saying "OK" here would
        # be worse than saying nothing.
        out.append(("WARN", "muse binary", "on PATH but `muse --version` printed nothing",
                    "That is probably not Muse Code. Check `which muse`."))
        return True
    out.append(("OK", "muse binary", first[:60], ""))
    return True


def check_credentials(out, core):
    cfg = Path(os.path.expanduser(os.environ.get("MUSE_CONFIG_DIR", "~/.config/muse")))
    auth = cfg / "auth.json"
    # Existence and size only -- never the contents.
    try:
        size = auth.stat().st_size
    except OSError:
        out.append(("FAIL", "credentials", "no %s" % auth,
                    "Run `muse login` (or `muse auth set --api-key-stdin`). Without this "
                    "every worker in a fan-out fails identically."))
        return
    if size == 0:
        out.append(("FAIL", "credentials", "%s is empty" % auth, "Run `muse login`."))
        return
    out.append(("OK", "credentials", "present (%d bytes, contents not read)" % size, ""))


def check_catalog(out, core):
    files = glob.glob(os.path.expanduser(core.CATALOG_GLOB))
    if not files:
        out.append(("WARN", "model catalog", "none cached at %s" % core.CATALOG_GLOB,
                    "Delegation falls back to the pinned %s instead of resolving the "
                    "newest. Run any `muse exec` once to populate it." % core.FALLBACK_MODEL))
        return
    newest = max(files, key=lambda f: os.path.getmtime(f))
    age_days = (time.time() - os.path.getmtime(newest)) / 86400
    rows = core.catalog_rows()
    contributors = [r for r in rows
                    if str(r.get("model_id", "")).endswith("-contributor")
                    and r.get("visibility", "visible") == "visible"]
    if not contributors:
        out.append(("WARN", "model catalog", "%d models, none visible contributor tier" % len(rows),
                    "Runs will fall back to %s." % core.FALLBACK_MODEL))
        return
    sev = "WARN" if age_days > 30 else "OK"
    note = ("Catalog is %d days old; a newer contributor model may exist."
            % int(age_days)) if sev == "WARN" else ""
    out.append((sev, "model catalog",
                "%d models, %d contributor, refreshed %d day(s) ago"
                % (len(rows), len(contributors), int(age_days)), note))


def check_resolution(out, core):
    model, how = core.resolve_model(core.LATEST)
    if how.startswith("fallback"):
        out.append(("WARN", "model resolution", "%s (%s)" % (model, how),
                    "A pinned id goes stale. Populate the catalog to resolve the newest."))
    else:
        out.append(("OK", "model resolution", "%s (%s)" % (model, how), ""))


def check_interactive_pin(out):
    settings = Path(os.path.expanduser(
        os.environ.get("MUSE_CONFIG_DIR", "~/.config/muse"))) / "settings.json"
    try:
        pinned = json.loads(settings.read_text(encoding="utf-8")).get("model")
    except (OSError, ValueError):
        out.append(("OK", "interactive pin", "unset (interactive muse follows the catalog)", ""))
        return
    if not pinned:
        out.append(("OK", "interactive pin", "unset (follows the catalog)", ""))
    elif pinned.endswith("-contributor"):
        out.append(("OK", "interactive pin", pinned, ""))
    else:
        out.append(("WARN", "interactive pin", pinned,
                    "Interactive `muse` is pinned to a non-contributor model and bills at "
                    "full rate. Delegation is unaffected. "
                    "`use_latest_contributor.sh --write` changes it."))


def check_python_git(out):
    v = sys.version_info
    sev = "OK" if v >= (3, 9) else "FAIL"
    out.append((sev, "python", "%d.%d.%d" % (v.major, v.minor, v.micro),
                "" if sev == "OK" else "The scripts are tested on 3.9+."))
    if shutil.which("git") is None:
        out.append(("FAIL", "git", "not on PATH", "Worktree isolation requires git."))
        return
    rc, ver = run(["git", "--version"])
    out.append(("OK" if rc == 0 else "FAIL", "git", ver[:40], ""))


def check_repo(out, core, repo: Path):
    if not (repo / ".git").exists():
        out.append(("WARN", "repo", "%s is not a git repository" % repo,
                    "Delegation needs one; worktrees branch from a committed ref."))
        return False
    rc, _ = run(["git", "-C", str(repo), "rev-parse", "HEAD"])
    if rc != 0:
        out.append(("FAIL", "repo", "%s has no commits" % repo,
                    "Worktrees branch from a committed ref. Commit something first."))
        return False
    rc, dirty = run(["git", "-C", str(repo), "status", "--porcelain"])
    if dirty.strip():
        n = len(dirty.strip().splitlines())
        out.append(("WARN", "repo", "%d uncommitted change(s)" % n,
                    "Both drivers refuse a dirty tree: uncommitted work is invisible to a "
                    "worktree and its absence looks like the agents deleted it."))
    else:
        out.append(("OK", "repo", "%s, clean" % repo.name, ""))
    return True


def check_worktree_root(out, repo: Path):
    root = repo.parent / ".muse-fleet-wt-{}".format(repo.name)
    target = root if root.exists() else repo.parent
    if not os.access(str(target), os.W_OK):
        out.append(("FAIL", "worktree root", "%s is not writable" % target,
                    "Worktrees are created beside the repo. Pass --worktree-root to move them."))
        return
    existing = len([d for d in root.iterdir() if d.is_dir()]) if root.exists() else 0
    if existing:
        out.append(("WARN", "worktree root", "%s holds %d worktree(s)" % (root, existing),
                    "Left over from earlier runs. `/muse:cleanup` reaps them."))
    else:
        out.append(("OK", "worktree root", "%s (writable)" % target, ""))


def check_scripts(out):
    needed = ["muse_core.py", "muse_task.py", "muse_fleet.py",
              "muse_status.py", "muse_cleanup.py", "muse_ask.sh"]
    missing = [n for n in needed if not (HERE / n).exists()]
    if missing:
        out.append(("FAIL", "plugin scripts", "missing: %s" % ", ".join(missing),
                    "The install is incomplete; reinstall the plugin."))
    else:
        out.append(("OK", "plugin scripts", "%d present in %s" % (len(needed), HERE), ""))


def check_secrets(out, core, repo: Path):
    scan = core.scan_secrets(repo)
    if scan["certain"]:
        where = ", ".join(sorted({f["file"] for f in scan["certain"]})[:3])
        out.append(("FAIL", "credential scan",
                    "%d confirmed in %d files (%s)"
                    % (len(scan["certain"]), len({f["file"] for f in scan["certain"]}), where),
                    "`run` refuses on these. Contributor-tier content may be used for "
                    "product improvement, and that is not undoable."))
    elif scan["possible"]:
        out.append(("WARN", "credential scan",
                    "%d credential-shaped assignment(s) across %d files"
                    % (len(scan["possible"]), scan["files_scanned"]),
                    "Not blocking — often test fixtures. Worth a glance before delegating."))
    else:
        out.append(("OK", "credential scan",
                    "nothing found in %d files" % scan["files_scanned"], ""))


def main() -> int:
    ap = argparse.ArgumentParser(description="Report whether this machine can delegate to muse.")
    ap.add_argument("--repo", default=".")
    ap.add_argument("--scan", action="store_true",
                    help="also scan the repo for credentials (slower on large trees)")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    core = load_core()
    repo = Path(args.repo).resolve()
    out = []

    def guarded(name, fn, *a):
        try:
            return fn(*a)
        except Exception as e:
            out.append(("FAIL", name, "check itself failed: %s: %s"
                        % (type(e).__name__, str(e)[:80]),
                        "This is a bug in muse_doctor.py — please report it."))
            return False

    have_muse = guarded("muse binary", check_muse, out)
    guarded("credentials", check_credentials, out, core)
    guarded("model catalog", check_catalog, out, core)
    guarded("model resolution", check_resolution, out, core)
    guarded("interactive pin", check_interactive_pin, out)
    guarded("python/git", check_python_git, out)
    guarded("plugin scripts", check_scripts, out)
    if guarded("repo", check_repo, out, core, repo):
        guarded("worktree root", check_worktree_root, out, repo)
        if args.scan:
            guarded("credential scan", check_secrets, out, core, repo)

    fails = [r for r in out if r[0] == "FAIL"]
    warns = [r for r in out if r[0] == "WARN"]

    if args.json:
        print(json.dumps({
            "ready": not fails,
            "fail": len(fails), "warn": len(warns), "ok": len(out) - len(fails) - len(warns),
            "checks": [{"severity": s, "name": n, "value": v, "fix": f} for s, n, v, f in out],
        }, indent=2))
        return 1 if fails else 0

    width = max(len(n) for _, n, _, _ in out)
    for sev, name, value, fix in out:
        print("  %-4s  %-*s  %s" % (sev, width, name, value))
        if fix:
            print("        %s %s" % (" " * width, fix))

    print()
    if fails:
        print("NOT READY — %d blocking, %d warning(s). Fix the FAIL lines above."
              % (len(fails), len(warns)))
    elif warns:
        print("READY, with %d warning(s). Delegation will work; read the warnings to know how."
              % len(warns))
    else:
        print("READY — every check passed.")
    if not have_muse:
        print("Everything below the muse check is reported anyway, so one run tells you "
              "the whole story rather than one problem at a time.")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
