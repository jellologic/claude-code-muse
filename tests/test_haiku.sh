#!/usr/bin/env bash
# Haiku-model checks: the field-notes measurement of `model:` frontmatter
# must agree with the frontmatter commands/ actually carries. Sourced by
# scripts/validate.sh (shares ok/bad/SKILL/LAB and the PATH helpers) and
# runnable standalone with `bash tests/test_haiku.sh`.
HK_STANDALONE=0
if ! declare -F ok >/dev/null 2>&1; then
  HK_STANDALONE=1
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
  LAB="$(native_path "$(mktemp -d "${TMPDIR:-/tmp}/muse-haiku.XXXXXX")")"
  if [ -z "${LAB:-}" ] || [ ! -d "$LAB" ]; then echo "no scratch dir" >&2; exit 1; fi
  PASS=0; FAIL=0; SKIP=0
  ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
  bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && echo "        $2"; }
  skip() { local n="$1"; shift; SKIP=$((SKIP+n)); printf '  SKIP  %s\n' "$*"; }
fi

if [ -z "${LAB:-}" ] || [ ! -d "${LAB:-}" ]; then
  echo "haiku: refusing to run without a scratch dir" >&2
  if [ "$HK_STANDALONE" = 1 ]; then exit 1; else return 1; fi
fi

command -v head_ >/dev/null 2>&1 && head_ "3g. haiku model claims"

HK_PY="$SKILL/tests/model_claims.py"

# Run the checker on a plugin ROOT, stripping CR so CRLF checkouts and
# native Windows Python output compare the same. Sets HK_OUT/HK_RC; the
# redirect (not a pipe) keeps the checker's own exit status.
hk_check() {
  HK_TMP_OUT="$LAB/hk-out.txt"
  python3 "$HK_PY" "$1" >"$HK_TMP_OUT" 2>&1; HK_RC=$?
  HK_OUT="$(tr -d '\r' <"$HK_TMP_OUT")"
}

# Copy the tree a probe needs into a fresh scratch root. The checker reads
# commands/ and references/; skills and agents ride along so a probe root
# stays a plausible plugin tree.
hk_probe_root() {  # hk_probe_root <n> — prints the fresh root
  HK_P="$LAB/haiku-probe-$1"
  rm -rf "$HK_P"; mkdir -p "$HK_P"
  cp -R "$SKILL/commands" "$SKILL/references" "$SKILL/skills" "$SKILL/agents" "$HK_P/"
  cp "$SKILL/CHANGELOG.md" "$HK_P/"
  printf '%s' "$HK_P"
}

# Check 1: the checker passes the shipped tree, and its summary names a
# non-empty input (an absence assertion over zero rows would pass vacuously).
hk_check "$SKILL"
HK_N="$(printf '%s\n' "$HK_OUT" | sed -n 's/^checked \([0-9]*\) rows, \([0-9]*\) command files with model:$/\1/p')"
HK_M="$(printf '%s\n' "$HK_OUT" | sed -n 's/^checked \([0-9]*\) rows, \([0-9]*\) command files with model:$/\2/p')"
if [ "$HK_RC" -eq 0 ] && [ -n "${HK_N:-}" ] && [ -n "${HK_M:-}" ] && [ "$HK_N" -ge 5 ] && [ "$HK_M" -ge 1 ]; then
  ok "haiku: model_claims passes the shipped tree"
else
  bad "haiku: model_claims passes the shipped tree" "rc=$HK_RC out=[$HK_OUT]"
fi

# Check 2: deleting the measurement section must fail, and name SECTION.
HK_P2="$(hk_probe_root 2)"
if ! grep -q '^## Measured: model frontmatter on commands and skills' "$HK_P2/references/field-notes.md"; then
  bad "haiku: probe — deleting the measurement section fails" "setup: heading absent before cutting"
else
  python3 - "$HK_P2" <<'EOF'
import sys
p = sys.argv[1] + "/references/field-notes.md"
with open(p, encoding="utf-8") as fh:
    text = fh.read()
lines = text.split("\n")
head = "## Measured: model frontmatter on commands and skills"
s = next((i for i, l in enumerate(lines) if l.strip() == head), None)
if s is None:
    sys.exit("heading absent")
e = next((i for i in range(s + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
del lines[s:e]
with open(p, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("\n".join(lines))
EOF
  if [ $? -ne 0 ]; then
    bad "haiku: probe — deleting the measurement section fails" "setup: python cut failed"
  else
    hk_check "$HK_P2"
    if [ "$HK_RC" -ne 0 ] && printf '%s' "$HK_OUT" | grep -q "SECTION"; then
      ok "haiku: probe — deleting the measurement section fails"
    else
      bad "haiku: probe — deleting the measurement section fails" "rc=$HK_RC out=[$HK_OUT]"
    fi
  fi
fi

# Check 3: a command model no row measured must fail and name the file.
HK_P3="$(hk_probe_root 3)"
python3 - "$HK_P3" <<'EOF'
import sys
p = sys.argv[1] + "/commands/status.md"
with open(p, encoding="utf-8") as fh:
    text = fh.read()
with open(p, "w", encoding="utf-8", newline="\n") as fh:
    fh.write(text.replace("model: haiku", "model: sonnet"))
EOF
if cmp -s "$SKILL/commands/status.md" "$HK_P3/commands/status.md"; then
  bad "haiku: probe — a command model no row measured fails and names the file" "setup: status.md did not change"
else
  hk_check "$HK_P3"
  if [ "$HK_RC" -ne 0 ] && printf '%s' "$HK_OUT" | grep -q "status.md"; then
    ok "haiku: probe — a command model no row measured fails and names the file"
  else
    bad "haiku: probe — a command model no row measured fails and names the file" "rc=$HK_RC out=[$HK_OUT]"
  fi
fi

# Check 4: rows claiming haiku never served a command must fail while the
# commands still carry model: haiku.
HK_P4="$(hk_probe_root 4)"
HK_N4="$(python3 - "$HK_P4" <<'EOF'
import sys
p = sys.argv[1] + "/references/field-notes.md"
with open(p, encoding="utf-8") as fh:
    lines = fh.read().split("\n")
n = 0
out = []
for line in lines:
    s = line.strip()
    if s.startswith("|"):
        parts = [c.strip() for c in s.split("|")]
        if len(parts) == 7 and parts[0] == "" and parts[-1] == "" and parts[2].startswith("command") and "haiku" in parts[4].lower():
            line = "| " + " | ".join([parts[1], parts[2], parts[3], "claude-sonnet-5", parts[5]]) + " |"
            n += 1
    out.append(line)
with open(p, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("\n".join(out))
print(n)
EOF
)"
if [ -z "${HK_N4:-}" ] || [ "$HK_N4" -lt 1 ]; then
  bad "haiku: probe — rows claiming haiku never served a command fail while commands keep model: haiku" "setup: rewrote $HK_N4 rows, want >= 1"
else
  hk_check "$HK_P4"
  if [ "$HK_RC" -ne 0 ] && printf '%s' "$HK_OUT" | grep -q "FRONTMATTER"; then
    ok "haiku: probe — rows claiming haiku never served a command fail while commands keep model: haiku"
  else
    bad "haiku: probe — rows claiming haiku never served a command fail while commands keep model: haiku" "rc=$HK_RC out=[$HK_OUT]"
  fi
fi

# Check 5: the same rows pass once model: is removed from every command —
# the issue's "remove it" branch stays accepted.
HK_N5="$(python3 - "$HK_P4" <<'EOF'
import sys
import glob
import os
d = os.path.join(sys.argv[1], "commands")
n = 0
for f in glob.glob(os.path.join(d, "*.md")):
    with open(f, encoding="utf-8") as fh:
        lines = fh.read().split("\n")
    kept = [l for l in lines if not l.startswith("model:")]
    if len(kept) < len(lines):
        n += 1
        with open(f, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("\n".join(kept))
print(n)
EOF
)"
if [ -z "${HK_N5:-}" ] || [ "$HK_N5" -lt 1 ]; then
  bad "haiku: probe — the same rows pass once model: is removed from every command" "setup: removed model: from $HK_N5 files, want >= 1"
else
  hk_check "$HK_P4"
  if [ "$HK_RC" -eq 0 ]; then
    ok "haiku: probe — the same rows pass once model: is removed from every command"
  else
    bad "haiku: probe — the same rows pass once model: is removed from every command" "rc=$HK_RC out=[$HK_OUT]"
  fi
fi

# Check 6: dropping the skill control row must fail with CONTROL.
HK_P6="$(hk_probe_root 6)"
HK_N6="$(python3 - "$HK_P6" <<'EOF'
import sys
p = sys.argv[1] + "/references/field-notes.md"
with open(p, encoding="utf-8") as fh:
    lines = fh.read().split("\n")
n = 0
out = []
for line in lines:
    s = line.strip()
    if s.startswith("|"):
        parts = [c.strip() for c in s.split("|")]
        if len(parts) == 7 and parts[0] == "" and parts[-1] == "" and parts[2].startswith("skill"):
            n += 1
            continue
    out.append(line)
with open(p, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("\n".join(out))
print(n)
EOF
)"
if [ -z "${HK_N6:-}" ] || [ "$HK_N6" -lt 1 ]; then
  bad "haiku: probe — dropping the skill control row fails" "setup: removed $HK_N6 skill rows, want >= 1"
else
  hk_check "$HK_P6"
  if [ "$HK_RC" -ne 0 ] && printf '%s' "$HK_OUT" | grep -q "CONTROL"; then
    ok "haiku: probe — dropping the skill control row fails"
  else
    bad "haiku: probe — dropping the skill control row fails" "rc=$HK_RC out=[$HK_OUT]"
  fi
fi

# Check 7: a commented model line is parsed, not ignored — `model: sonnet
# # cheap` must fail naming the file, not pass vacuously as model-less.
HK_P7="$(hk_probe_root 7)"
python3 - "$HK_P7" <<'EOF'
import sys
p = sys.argv[1] + "/commands/status.md"
with open(p, encoding="utf-8") as fh:
    text = fh.read()
with open(p, "w", encoding="utf-8", newline="\n") as fh:
    fh.write(text.replace("model: haiku", "model: sonnet # cheap"))
EOF
if cmp -s "$SKILL/commands/status.md" "$HK_P7/commands/status.md"; then
  bad "haiku: probe - a commented model line is parsed, not ignored" "setup: status.md did not change"
else
  hk_check "$HK_P7"
  if [ "$HK_RC" -ne 0 ] && printf '%s' "$HK_OUT" | grep -q "FRONTMATTER" && printf '%s' "$HK_OUT" | grep -q "status.md"; then
    ok "haiku: probe - a commented model line is parsed, not ignored"
  else
    bad "haiku: probe - a commented model line is parsed, not ignored" "rc=$HK_RC out=[$HK_OUT]"
  fi
fi

# Check 8: a quoted model value is parsed — `model: "sonnet"` must fail.
HK_P8="$(hk_probe_root 8)"
python3 - "$HK_P8" <<'EOF'
import sys
p = sys.argv[1] + "/commands/status.md"
with open(p, encoding="utf-8") as fh:
    text = fh.read()
with open(p, "w", encoding="utf-8", newline="\n") as fh:
    fh.write(text.replace("model: haiku", 'model: "sonnet"'))
EOF
if cmp -s "$SKILL/commands/status.md" "$HK_P8/commands/status.md"; then
  bad "haiku: probe - a quoted model value is parsed" "setup: status.md did not change"
else
  hk_check "$HK_P8"
  if [ "$HK_RC" -ne 0 ] && printf '%s' "$HK_OUT" | grep -q "status.md"; then
    ok "haiku: probe - a quoted model value is parsed"
  else
    bad "haiku: probe - a quoted model value is parsed" "rc=$HK_RC out=[$HK_OUT]"
  fi
fi

# Check 9: quoted haiku with a comment still passes and counts the file.
HK_P9="$(hk_probe_root 9)"
python3 - "$HK_P9" <<'EOF'
import sys
p = sys.argv[1] + "/commands/status.md"
with open(p, encoding="utf-8") as fh:
    text = fh.read()
with open(p, "w", encoding="utf-8", newline="\n") as fh:
    fh.write(text.replace("model: haiku", "model: 'haiku'  # cheap"))
EOF
if cmp -s "$SKILL/commands/status.md" "$HK_P9/commands/status.md"; then
  bad "haiku: probe - quoted haiku with a comment passes and counts the file" "setup: status.md did not change"
else
  hk_check "$HK_P9"
  HK_M9="$(printf '%s\n' "$HK_OUT" | sed -n 's/^checked \([0-9]*\) rows, \([0-9]*\) command files with model:$/\2/p')"
  if [ "$HK_RC" -eq 0 ] && [ -n "${HK_M9:-}" ] && [ -n "${HK_M:-}" ] && [ "$HK_M9" -ge 1 ] && [ "$HK_M9" = "$HK_M" ]; then
    ok "haiku: probe - quoted haiku with a comment passes and counts the file"
  else
    bad "haiku: probe - quoted haiku with a comment passes and counts the file" "rc=$HK_RC out=[$HK_OUT] want M=$HK_M"
  fi
fi

# Check 10: reverting the CHANGELOG bullet alone fails — field-notes stays
# untouched, so only the CHANGELOG hold can catch it.
HK_P10="$(hk_probe_root 10)"
HK_N10="$(python3 - "$HK_P10" <<'EOF'
import sys
p = sys.argv[1] + "/CHANGELOG.md"
with open(p, encoding="utf-8") as fh:
    lines = fh.read().split("\n")
old = ["- `model: haiku` on the reporting commands (Refs #29) is unverified: headless runs of",
       "  `/muse:model` and `/muse:status` ran on the session model. The frontmatter is left as",
       "  is, and the claim is stated plainly as unverified rather than delivered."]
out = []
i = 0
replaced = 0
while i < len(lines):
    line = lines[i]
    if line.startswith("- ") and "model: haiku" in line and "#57" in line:
        j = i + 1
        while j < len(lines) and lines[j] != "" and not lines[j].startswith("- ") and not lines[j].startswith("#"):
            j += 1
        out.extend(old)
        replaced += 1
        i = j
    else:
        out.append(line)
        i += 1
with open(p, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("\n".join(out))
print(replaced)
EOF
)"
if [ -z "${HK_N10:-}" ] || [ "$HK_N10" != 1 ]; then
  bad "haiku: probe - reverting the CHANGELOG bullet alone fails" "setup: replaced $HK_N10 bullets, want 1"
else
  hk_check "$HK_P10"
  if [ "$HK_RC" -ne 0 ] && printf '%s' "$HK_OUT" | grep -q "CHANGELOG"; then
    ok "haiku: probe - reverting the CHANGELOG bullet alone fails"
  else
    bad "haiku: probe - reverting the CHANGELOG bullet alone fails" "rc=$HK_RC out=[$HK_OUT]"
  fi
fi

# Check 11: a CHANGELOG bullet missing a measured mode fails.
HK_P11="$(hk_probe_root 11)"
HK_N11="$(python3 - "$HK_P11" <<'EOF'
import re
import sys
p = sys.argv[1] + "/CHANGELOG.md"
with open(p, encoding="utf-8") as fh:
    lines = fh.read().split("\n")
in_pick = False
n = 0
out = []
for line in lines:
    if line.startswith("- "):
        in_pick = ("model: haiku" in line and "#57" in line)
    elif line.strip() == "" or line.startswith("#"):
        in_pick = False
    if in_pick and re.search(r"\bplan\b", line):
        line = re.sub(r"\bplan\b", "", line, count=1)
        n += 1
    out.append(line)
with open(p, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("\n".join(out))
print(n)
EOF
)"
if [ -z "${HK_N11:-}" ] || [ "$HK_N11" -lt 1 ]; then
  bad "haiku: probe - a CHANGELOG bullet missing a measured mode fails" "setup: removed plan from $HK_N11 lines, want >= 1"
else
  hk_check "$HK_P11"
  if [ "$HK_RC" -ne 0 ] && printf '%s' "$HK_OUT" | grep -q "CHANGELOG"; then
    ok "haiku: probe - a CHANGELOG bullet missing a measured mode fails"
  else
    bad "haiku: probe - a CHANGELOG bullet missing a measured mode fails" "rc=$HK_RC out=[$HK_OUT]"
  fi
fi

# Check 12: dropping the plan row fails — every measured mode needs its row.
HK_P12="$(hk_probe_root 12)"
HK_N12="$(python3 - "$HK_P12" <<'EOF'
import sys
p = sys.argv[1] + "/references/field-notes.md"
with open(p, encoding="utf-8") as fh:
    lines = fh.read().split("\n")
n = 0
out = []
for line in lines:
    s = line.strip()
    if s.startswith("|"):
        parts = [c.strip() for c in s.split("|")]
        if len(parts) == 7 and parts[0] == "" and parts[-1] == "" and parts[1].endswith("plan"):
            n += 1
            continue
    out.append(line)
with open(p, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("\n".join(out))
print(n)
EOF
)"
if [ -z "${HK_N12:-}" ] || [ "$HK_N12" -lt 1 ]; then
  bad "haiku: probe - dropping the plan row fails" "setup: removed $HK_N12 plan rows, want >= 1"
else
  hk_check "$HK_P12"
  if [ "$HK_RC" -ne 0 ] && printf '%s' "$HK_OUT" | grep -q "MODES"; then
    ok "haiku: probe - dropping the plan row fails"
  else
    bad "haiku: probe - dropping the plan row fails" "rc=$HK_RC out=[$HK_OUT]"
  fi
fi

# Check 13: a command cell disagreeing with its mode fails.
HK_P13="$(hk_probe_root 13)"
python3 - "$HK_P13" <<'EOF'
import sys
p = sys.argv[1] + "/references/field-notes.md"
with open(p, encoding="utf-8") as fh:
    text = fh.read()
with open(p, "w", encoding="utf-8", newline="\n") as fh:
    fh.write(text.replace("--permission-mode acceptEdits", "--permission-mode default", 1))
EOF
if cmp -s "$HK_P13/references/field-notes.md" "$SKILL/references/field-notes.md"; then
  bad "haiku: probe - a command cell disagreeing with its mode fails" "setup: field-notes.md did not change"
else
  hk_check "$HK_P13"
  if [ "$HK_RC" -ne 0 ] && printf '%s' "$HK_OUT" | grep -q "MODES"; then
    ok "haiku: probe - a command cell disagreeing with its mode fails"
  else
    bad "haiku: probe - a command cell disagreeing with its mode fails" "rc=$HK_RC out=[$HK_OUT]"
  fi
fi

if [ "$HK_STANDALONE" = 1 ]; then
  printf 'haiku: %d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]; exit $?
fi
