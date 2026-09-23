#!/usr/bin/env bash
# Point ~/.config/muse/settings.json at the newest contributor model in muse's catalog.
#
# The fleet script resolves this per run, so this exists for *interactive* `muse`
# sessions, which read settings.json. A hand-written pin there is how a machine ends up
# a generation behind without anyone noticing -- re-run this after muse ships a new model.
#
#   use_latest_contributor.sh          # show what would change
#   use_latest_contributor.sh --write  # apply it (backs up first)

set -euo pipefail

SETTINGS="${MUSE_SETTINGS:-$HOME/.config/muse/settings.json}"
WRITE=0
[[ "${1:-}" == "--write" ]] && WRITE=1
CORE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/muse_core.py"

python3 - "$SETTINGS" "$WRITE" "$CORE" <<'PY'
import importlib.util, json, os, shutil, sys, time

settings_path, write = sys.argv[1], sys.argv[2] == "1"

# The catalog glob lives in muse_core, the single source, so MUSE_DATA_DIR and
# MUSE_CATALOG_GLOB redirect this script exactly as they redirect the fleet.
spec = importlib.util.spec_from_file_location("muse_core", sys.argv[3])
core = importlib.util.module_from_spec(spec)
spec.loader.exec_module(core)
rows = core.catalog_rows()

if not rows:
    sys.exit("no model catalog found — run any `muse exec` once to populate it")

cands = [r for r in rows
         if str(r.get("model_id", "")).endswith("-contributor")
         and r.get("visibility", "visible") == "visible"]
if not cands:
    sys.exit("catalog has no visible contributor models")

cands.sort(key=lambda r: (str(r.get("release_date") or ""), bool(r.get("is_default"))),
           reverse=True)
latest = cands[0]["model_id"]

try:
    cfg = json.load(open(settings_path))
except FileNotFoundError:
    cfg = {"schema_version": 1, "provider": "meta"}
except ValueError:
    sys.exit(f"{settings_path} is not valid JSON; fix or remove it first")

current = cfg.get("model")
print(f"catalog latest contributor : {latest} (released {cands[0].get('release_date')})")
print(f"settings.json currently    : {current or '(unset — follows catalog default)'}")

if current == latest:
    print("\nalready current, nothing to do")
    sys.exit(0)

if not write:
    print(f"\nwould set model -> {latest}")
    print("re-run with --write to apply")
    sys.exit(0)

if os.path.exists(settings_path):
    backup = f"{settings_path}.bak-{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.copy2(settings_path, backup)
    print(f"\nbacked up -> {backup}")

cfg["model"] = latest
os.makedirs(os.path.dirname(settings_path), exist_ok=True)
with open(settings_path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print(f"set model -> {latest}")
PY
