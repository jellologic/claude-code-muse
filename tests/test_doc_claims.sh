#!/usr/bin/env bash
# Doc-claims checks: prose counts (commands, shims, auto-triggering surfaces),
# hook events and flags named in prose must match the code. Sourced by
# scripts/validate.sh (shares ok/bad/SKILL/LAB and the PATH helpers) and
# runnable standalone with `bash tests/test_doc_claims.sh`.
DC_STANDALONE=0
if ! declare -F ok >/dev/null 2>&1; then
  DC_STANDALONE=1
  set -uo pipefail
  export PYTHONUTF8=1
  if ! declare -F shell_path >/dev/null 2>&1; then
    native_path() {
      if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
    }
    shell_path() {
      if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi
    }
  fi
  SKILL="$(native_path "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)")"
  LAB="$(native_path "$(mktemp -d "${TMPDIR:-/tmp}/muse-docs.XXXXXX")")"
  if [ -z "${LAB:-}" ] || [ ! -d "$LAB" ]; then echo "no scratch dir" >&2; exit 1; fi
  # Standalone only: an early exit must not leave the lab behind under TMPDIR.
  trap 'rm -rf "$LAB"' EXIT
  PASS=0; FAIL=0; SKIP=0
  ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
  bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && echo "        $2"; }
  skip() { local n="$1"; shift; SKIP=$((SKIP+n)); printf '  SKIP  %s\n' "$*"; }
fi

if [ -z "${LAB:-}" ] || [ ! -d "${LAB:-}" ]; then
  echo "doc-claims: refusing to run without a scratch dir" >&2
  if [ "$DC_STANDALONE" = 1 ]; then exit 1; else return 1; fi
fi

command -v head_ >/dev/null 2>&1 && head_ "3f. doc claims"

DC_PY="$SKILL/tests/doc_claims.py"
DC_TAB="$(printf '\t')"
# A neutral cwd for shim runs, so a shim can never resolve against the repo
# under test or the caller's directory.
DC_NEUTRAL="$LAB/dc-neutral"
mkdir -p "$DC_NEUTRAL"

# The three probes below share these: each takes a plugin ROOT (native path)
# and prints the checker output on stdout. Counts and events exit nonzero on
# any mismatch; flags always exits 0 because it only extracts triples.
dc_counts() { python3 "$DC_PY" counts "$1" 2>&1 | tr -d '\r'; }
dc_events() { python3 "$DC_PY" events "$1" 2>&1 | tr -d '\r'; }
dc_triples() { python3 "$DC_PY" flags "$1" 2>&1 | tr -d '\r'; }

# Fetch one shim's --help output through bash by bare name, the way the
# plugin's Bash tool finds it. Native Windows Python cannot exec the
# extensionless shims, so Python only ever reads text here. Prints the cached
# help-file path; nonzero when the shim itself failed.
dc_help_file() {  # dc_help_file <root> <shim> <sub>
  DC_H_ROOT="$1"; DC_H_SHIM="$2"; DC_H_SUB="${3:-}"
  DC_H_KEY="$(printf '%s' "$DC_H_ROOT" | tr -c 'A-Za-z0-9' '_')"
  DC_H_FILE="$LAB/dc-help-${DC_H_KEY}-${DC_H_SHIM}-${DC_H_SUB:-nosub}.txt"
  if [ ! -f "$DC_H_FILE" ]; then
    if [ -n "$DC_H_SUB" ]; then
      (cd "$DC_NEUTRAL" && PATH="$(shell_path "$DC_H_ROOT/bin"):$PATH" "$DC_H_SHIM" "$DC_H_SUB" --help >"$DC_H_FILE.raw" 2>&1)
    else
      (cd "$DC_NEUTRAL" && PATH="$(shell_path "$DC_H_ROOT/bin"):$PATH" "$DC_H_SHIM" --help >"$DC_H_FILE.raw" 2>&1)
    fi
    DC_H_RC=$?
    tr -d '\r' <"$DC_H_FILE.raw" >"$DC_H_FILE"
    printf '%d' "$DC_H_RC" >"$DC_H_FILE.rc"
  fi
  if [ "$(cat "$DC_H_FILE.rc")" != "0" ]; then return 1; fi
  printf '%s' "$DC_H_FILE"
  return 0
}

# Check every prose (shim, subcommand, flag) triple against the help text the
# shim itself prints. Prints one line per missing flag; nonzero on any miss or
# when the extractor found almost nothing (an extractor that finds nothing
# would otherwise pass exactly like one that found no stale flags).
dc_flags() {  # dc_flags <root>
  DC_F_ROOT="$1"
  DC_F_TRIPLES="$(dc_triples "$DC_F_ROOT")"
  if [ -z "$DC_F_TRIPLES" ]; then DC_F_N=0;
  else DC_F_N="$(printf '%s\n' "$DC_F_TRIPLES" | grep -c . || true)"; fi
  DC_F_OUT=""; DC_F_BAD=0
  # TAB is IFS whitespace, so `read` would collapse the empty subcommand field
  # (`muse-ask\t\t--effort` splits into two fields, not three). Parse the
  # two tabs with parameter expansion instead, which keeps empty fields.
  while IFS= read -r DC_LINE; do
    [ -z "${DC_LINE:-}" ] && continue
    DC_F_SHIM="${DC_LINE%%$DC_TAB*}"
    DC_F_REST="${DC_LINE#*$DC_TAB}"
    DC_F_SUB="${DC_F_REST%%$DC_TAB*}"
    DC_F_FLAG="${DC_F_REST#*$DC_TAB}"
    [ -z "${DC_F_SHIM:-}" ] && continue
    DC_F_HELP=""
    DC_F_HELP="$(dc_help_file "$DC_F_ROOT" "$DC_F_SHIM" "$DC_F_SUB")" || DC_F_HELP=""
    if [ -z "$DC_F_HELP" ]; then
      DC_F_OUT="${DC_F_OUT}FLAG: ${DC_F_SHIM}${DC_F_SUB:+ $DC_F_SUB} --help failed, cannot verify ${DC_F_FLAG}; "
      DC_F_BAD=1
      continue
    fi
    if ! grep -Eq -- "(^|[^A-Za-z0-9-])${DC_F_FLAG}([^A-Za-z0-9-]|$)" "$DC_F_HELP"; then
      DC_F_OUT="${DC_F_OUT}FLAG: ${DC_F_SHIM}${DC_F_SUB:+ $DC_F_SUB} ${DC_F_FLAG} not in ${DC_F_SHIM}${DC_F_SUB:+ $DC_F_SUB} --help; "
      DC_F_BAD=1
    fi
  done <<< "$DC_F_TRIPLES"
  if [ "$DC_F_N" -lt 30 ]; then
    DC_F_OUT="${DC_F_OUT}FLAG: only ${DC_F_N} prose triples extracted, expected at least 30; "
    DC_F_BAD=1
  fi
  [ -n "$DC_F_OUT" ] && printf '%s\n' "$DC_F_OUT"
  return "$DC_F_BAD"
}

# Copy the tree a probe needs into a fresh scratch root. Scripts ride along
# because the shims exec them; the flag probe runs real --help through them.
dc_probe_root() {  # dc_probe_root <n> — prints the fresh root
  DC_P="$LAB/docs-probe-$1"
  rm -rf "$DC_P"; mkdir -p "$DC_P"
  cp "$SKILL/README.md" "$SKILL/AGENTS.md" "$SKILL/CONTRIBUTING.md" "$SKILL/SECURITY.md" "$DC_P/"
  for DC_D in skills commands agents references bin scripts hooks workflows assets; do
    cp -R "$SKILL/$DC_D" "$DC_P/$DC_D"
  done
  printf '%s' "$DC_P"
}

# Checks 1-3 share one checker whose lines are tagged COMMANDS:/SHIMS:/
# SURFACES:, so each check below fails only on its own claim.
DC_ALL="$(dc_counts "$SKILL")"
if [ -z "$(printf '%s\n' "$DC_ALL" | grep '^COMMANDS: ' || true)" ]; then
  ok "docs: command count in README, SKILL.md and AGENTS.md matches commands/"
else
  bad "docs: command count in README, SKILL.md and AGENTS.md matches commands/" "$(printf '%s\n' "$DC_ALL" | grep '^COMMANDS: ' || true)"
fi
if [ -z "$(printf '%s\n' "$DC_ALL" | grep '^SHIMS: ' || true)" ]; then
  ok "docs: shim count in README and AGENTS.md matches bin/"
else
  bad "docs: shim count in README and AGENTS.md matches bin/" "$(printf '%s\n' "$DC_ALL" | grep '^SHIMS: ' || true)"
fi
if [ -z "$(printf '%s\n' "$DC_ALL" | grep '^SURFACES: ' || true)" ]; then
  ok "docs: auto-triggering surface count matches skills, agents, workflows and opt-in commands"
else
  bad "docs: auto-triggering surface count matches skills, agents, workflows and opt-in commands" "$(printf '%s\n' "$DC_ALL" | grep '^SURFACES: ' || true)"
fi

DC_F_MSG="$(dc_flags "$SKILL")"
if [ $? -eq 0 ]; then
  ok "docs: every muse-* flag named in prose appears in that shim's --help"
else
  bad "docs: every muse-* flag named in prose appears in that shim's --help" "$DC_F_MSG"
fi

DC_E_MSG="$(dc_events "$SKILL")"
if [ $? -eq 0 ]; then
  ok "docs: every hook event README names is registered in hooks/hooks.json, and every registered one is named"
else
  bad "docs: every hook event README names is registered in hooks/hooks.json, and every registered one is named" "$DC_E_MSG"
fi

# Probe 6: a command file with no prose update must fail the command count,
# and the failure must name the planted file.
DC_P6="$(dc_probe_root 6)"
cp "$DC_P6/commands/status.md" "$DC_P6/commands/zz-probe.md"
DC_P6_OUT="$(dc_counts "$DC_P6")"; DC_P6_RC=$?
if [ "$DC_P6_RC" -ne 0 ] && printf '%s' "$DC_P6_OUT" | grep -q "zz-probe"; then
  ok "docs: probe — adding a command without updating the prose fails the command count"
else
  bad "docs: probe — adding a command without updating the prose fails the command count" "rc=$DC_P6_RC out=[$DC_P6_OUT]"
fi

# Probe 7: a shim file with no prose update must fail the shim count.
DC_P7="$(dc_probe_root 7)"
cp "$DC_P7/bin/muse-status" "$DC_P7/bin/muse-zzprobe"
chmod +x "$DC_P7/bin/muse-zzprobe"
DC_P7_OUT="$(dc_counts "$DC_P7")"; DC_P7_RC=$?
if [ "$DC_P7_RC" -ne 0 ] && printf '%s' "$DC_P7_OUT" | grep -q "muse-zzprobe"; then
  ok "docs: probe — adding a shim fails the shim count"
else
  bad "docs: probe — adding a shim fails the shim count" "rc=$DC_P7_RC out=[$DC_P7_OUT]"
fi

# Probe 8: a new agent file must fail the surface count.
DC_P8="$(dc_probe_root 8)"
printf '%s\n' "---" "name: zz-probe" "description: Probe surface for the doc-claims check." "---" "" "Probe." > "$DC_P8/agents/zz-probe.md"
DC_P8_OUT="$(dc_counts "$DC_P8")"; DC_P8_RC=$?
if [ "$DC_P8_RC" -ne 0 ] && printf '%s' "$DC_P8_OUT" | grep -q "zz-probe"; then
  ok "docs: probe — a new auto-triggering surface fails the surface count"
else
  bad "docs: probe — a new auto-triggering surface fails the surface count" "rc=$DC_P8_RC out=[$DC_P8_OUT]"
fi

# Per-doc probes: 6-8 above change the code side, so every doc mismatches at
# once and a disabled comparison for one doc stays green. Each probe below
# rewrites one claim in one doc -- the number word becomes 99, so no count is
# hard-coded -- and requires the failure to name that file and no other doc.
DC_P11="$(dc_probe_root 11)"
python3 - "$DC_P11/README.md" <<'PY'
import re, sys
p = sys.argv[1]
old = open(p, encoding="utf-8").read()
new = re.sub(r"^\| `/muse:[A-Za-z0-9_-]+.*\n", "", old, count=1, flags=re.M)
assert new != old, "no `/muse:` table row found"
open(p, "w", encoding="utf-8").write(new)
PY
DC_P11_PYRC=$?
DC_P11_OUT="$(dc_counts "$DC_P11")"; DC_P11_RC=$?
if [ "$DC_P11_PYRC" -eq 0 ] && [ "$DC_P11_RC" -ne 0 ] \
  && printf '%s\n' "$DC_P11_OUT" | grep -q '^COMMANDS: .*README\.md' \
  && ! printf '%s\n' "$DC_P11_OUT" | grep '^COMMANDS: ' | grep -q 'SKILL\.md\|AGENTS\.md'; then
  ok "testfix: docs probe — README commands count is held on its own"
else
  bad "testfix: docs probe — README commands count is held on its own" "pyrc=$DC_P11_PYRC rc=$DC_P11_RC out=[$DC_P11_OUT]"
fi

DC_P12="$(dc_probe_root 12)"
python3 - "$DC_P12/skills/muse-fleet/SKILL.md" <<'PY'
import re, sys
p = sys.argv[1]
old = open(p, encoding="utf-8").read()
new = re.sub(r"(\w+) commands you type", "99 commands you type", old, count=1)
assert new != old, "no '<word> commands you type' phrase found"
open(p, "w", encoding="utf-8").write(new)
PY
DC_P12_PYRC=$?
DC_P12_OUT="$(dc_counts "$DC_P12")"; DC_P12_RC=$?
if [ "$DC_P12_PYRC" -eq 0 ] && [ "$DC_P12_RC" -ne 0 ] \
  && printf '%s\n' "$DC_P12_OUT" | grep -q '^COMMANDS: .*SKILL\.md' \
  && ! printf '%s\n' "$DC_P12_OUT" | grep '^COMMANDS: ' | grep -q 'README\.md\|AGENTS\.md'; then
  ok "testfix: docs probe — SKILL.md commands count is held on its own"
else
  bad "testfix: docs probe — SKILL.md commands count is held on its own" "pyrc=$DC_P12_PYRC rc=$DC_P12_RC out=[$DC_P12_OUT]"
fi

DC_P13="$(dc_probe_root 13)"
python3 - "$DC_P13/AGENTS.md" <<'PY'
import re, sys
p = sys.argv[1]
old = open(p, encoding="utf-8").read()
new = re.sub(r"The (\w+) `/muse:\*` commands", "The 99 `/muse:*` commands", old, count=1)
assert new != old, "no 'The <word> `/muse:*` commands' phrase found"
open(p, "w", encoding="utf-8").write(new)
PY
DC_P13_PYRC=$?
DC_P13_OUT="$(dc_counts "$DC_P13")"; DC_P13_RC=$?
if [ "$DC_P13_PYRC" -eq 0 ] && [ "$DC_P13_RC" -ne 0 ] \
  && printf '%s\n' "$DC_P13_OUT" | grep -q '^COMMANDS: .*AGENTS\.md' \
  && ! printf '%s\n' "$DC_P13_OUT" | grep '^COMMANDS: ' | grep -q 'README\.md\|SKILL\.md'; then
  ok "testfix: docs probe — AGENTS.md commands count is held on its own"
else
  bad "testfix: docs probe — AGENTS.md commands count is held on its own" "pyrc=$DC_P13_PYRC rc=$DC_P13_RC out=[$DC_P13_OUT]"
fi

DC_P14="$(dc_probe_root 14)"
python3 - "$DC_P14/README.md" <<'PY'
import re, sys
p = sys.argv[1]
old = open(p, encoding="utf-8").read()
new = re.sub(r"(\w+) shims", "99 shims", old, count=1)
assert new != old, "no '<word> shims' phrase found"
open(p, "w", encoding="utf-8").write(new)
PY
DC_P14_PYRC=$?
DC_P14_OUT="$(dc_counts "$DC_P14")"; DC_P14_RC=$?
if [ "$DC_P14_PYRC" -eq 0 ] && [ "$DC_P14_RC" -ne 0 ] \
  && printf '%s\n' "$DC_P14_OUT" | grep -q '^SHIMS: .*README\.md' \
  && ! printf '%s\n' "$DC_P14_OUT" | grep '^SHIMS: ' | grep -q 'AGENTS\.md'; then
  ok "testfix: docs probe — README shims count is held on its own"
else
  bad "testfix: docs probe — README shims count is held on its own" "pyrc=$DC_P14_PYRC rc=$DC_P14_RC out=[$DC_P14_OUT]"
fi

DC_P15="$(dc_probe_root 15)"
python3 - "$DC_P15/AGENTS.md" <<'PY'
import re, sys
p = sys.argv[1]
old = open(p, encoding="utf-8").read()
new = re.sub(r"(\w+) shims", "99 shims", old, count=1)
assert new != old, "no '<word> shims' phrase found"
open(p, "w", encoding="utf-8").write(new)
PY
DC_P15_PYRC=$?
DC_P15_OUT="$(dc_counts "$DC_P15")"; DC_P15_RC=$?
if [ "$DC_P15_PYRC" -eq 0 ] && [ "$DC_P15_RC" -ne 0 ] \
  && printf '%s\n' "$DC_P15_OUT" | grep -q '^SHIMS: .*AGENTS\.md' \
  && ! printf '%s\n' "$DC_P15_OUT" | grep '^SHIMS: ' | grep -q 'README\.md'; then
  ok "testfix: docs probe — AGENTS.md shims count is held on its own"
else
  bad "testfix: docs probe — AGENTS.md shims count is held on its own" "pyrc=$DC_P15_PYRC rc=$DC_P15_RC out=[$DC_P15_OUT]"
fi

DC_P16="$(dc_probe_root 16)"
python3 - "$DC_P16/README.md" <<'PY'
import re, sys
p = sys.argv[1]
old = open(p, encoding="utf-8").read()
new = re.sub(r"(\w+) surfaces can fire without a slash command",
             "99 surfaces can fire without a slash command", old, count=1)
assert new != old, "no '<word> surfaces can fire' phrase found"
open(p, "w", encoding="utf-8").write(new)
PY
DC_P16_PYRC=$?
DC_P16_OUT="$(dc_counts "$DC_P16")"; DC_P16_RC=$?
if [ "$DC_P16_PYRC" -eq 0 ] && [ "$DC_P16_RC" -ne 0 ] \
  && printf '%s\n' "$DC_P16_OUT" | grep -q '^SURFACES: .*README\.md' \
  && ! printf '%s\n' "$DC_P16_OUT" | grep '^SURFACES: ' | grep -q 'AGENTS\.md'; then
  ok "testfix: docs probe — README surfaces count is held on its own"
else
  bad "testfix: docs probe — README surfaces count is held on its own" "pyrc=$DC_P16_PYRC rc=$DC_P16_RC out=[$DC_P16_OUT]"
fi

DC_P17="$(dc_probe_root 17)"
python3 - "$DC_P17/AGENTS.md" <<'PY'
import re, sys
p = sys.argv[1]
old = open(p, encoding="utf-8").read()
new = re.sub(r"(\w+) auto-triggering surfaces", "99 auto-triggering surfaces", old, count=1)
assert new != old, "no '<word> auto-triggering surfaces' phrase found"
open(p, "w", encoding="utf-8").write(new)
PY
DC_P17_PYRC=$?
DC_P17_OUT="$(dc_counts "$DC_P17")"; DC_P17_RC=$?
if [ "$DC_P17_PYRC" -eq 0 ] && [ "$DC_P17_RC" -ne 0 ] \
  && printf '%s\n' "$DC_P17_OUT" | grep -q '^SURFACES: .*AGENTS\.md' \
  && ! printf '%s\n' "$DC_P17_OUT" | grep '^SURFACES: ' | grep -q 'README\.md'; then
  ok "testfix: docs probe — AGENTS.md surfaces count is held on its own"
else
  bad "testfix: docs probe — AGENTS.md surfaces count is held on its own" "pyrc=$DC_P17_PYRC rc=$DC_P17_RC out=[$DC_P17_OUT]"
fi

# Probe 9: a flag no shim accepts must fail the flag check.
DC_P9="$(dc_probe_root 9)"
printf '%s\n' "Run \`muse-status --zz-bogus-flag\`." >> "$DC_P9/README.md"
DC_P9_OUT="$(dc_flags "$DC_P9")"; DC_P9_RC=$?
if [ "$DC_P9_RC" -ne 0 ] && printf '%s' "$DC_P9_OUT" | grep -q -- "--zz-bogus-flag"; then
  ok "docs: probe — a flag the shim does not accept fails the flag check"
else
  bad "docs: probe — a flag the shim does not accept fails the flag check" "rc=$DC_P9_RC out=[$DC_P9_OUT]"
fi

# Probe 10: naming an unregistered hook event must fail the event check.
DC_P10="$(dc_probe_root 10)"
printf '%s\n' "The SessionEnd hook names leftover worktrees still open." >> "$DC_P10/README.md"
DC_P10_OUT="$(dc_events "$DC_P10")"; DC_P10_RC=$?
if [ "$DC_P10_RC" -ne 0 ] && printf '%s' "$DC_P10_OUT" | grep -q "SessionEnd"; then
  ok "docs: probe — naming an unregistered hook event fails the event check"
else
  bad "docs: probe — naming an unregistered hook event fails the event check" "rc=$DC_P10_RC out=[$DC_P10_OUT]"
fi

# An event no list holds must still be refused in either prose form: bold
# CamelCase or CamelCase followed by "hook". A hard-coded KNOWN_EVENTS lookup
# sees neither, so both probes fail on the reverted checker.
DC_P18="$(dc_probe_root 18)"
printf '\n%s\n' '**ZzUnlistedEvent** (`hooks/zz.py`) does a thing.' >> "$DC_P18/README.md"
DC_P18_OUT="$(dc_events "$DC_P18")"; DC_P18_RC=$?
if [ "$DC_P18_RC" -ne 0 ] && printf '%s' "$DC_P18_OUT" | grep -q "ZzUnlistedEvent"; then
  ok "testfix: docs probe — a bold unlisted event fails the event check"
else
  bad "testfix: docs probe — a bold unlisted event fails the event check" "rc=$DC_P18_RC out=[$DC_P18_OUT]"
fi

DC_P19="$(dc_probe_root 19)"
printf '\n%s\n' 'The ZzUnlistedEvent hook does a thing.' >> "$DC_P19/README.md"
DC_P19_OUT="$(dc_events "$DC_P19")"; DC_P19_RC=$?
if [ "$DC_P19_RC" -ne 0 ] && printf '%s' "$DC_P19_OUT" | grep -q "ZzUnlistedEvent"; then
  ok "testfix: docs probe — an unlisted event followed by hook fails the event check"
else
  bad "testfix: docs probe — an unlisted event followed by hook fails the event check" "rc=$DC_P19_RC out=[$DC_P19_OUT]"
fi

if [ "$DC_STANDALONE" = 1 ]; then
  printf 'doc-claims: %d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]; exit $?
fi
