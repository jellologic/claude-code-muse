#!/usr/bin/env bash
# Frontmatter allowlist checks for scripts/check_frontmatter.py. Sourced by
# scripts/validate.sh (one line) and runnable standalone for a fast loop.
if ! declare -F ok >/dev/null 2>&1; then FM_STANDALONE=1; PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  PASS  $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && echo "        $2"; }; PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; LAB="$(mktemp -d "${TMPDIR:-/tmp}/fmtest.XXXXXX")"; fi
FM_CHK="$PLUGIN_ROOT/scripts/check_frontmatter.py"

# A fresh probe tree per mutation: cp -R into a dir the checker then scans, so
# a failure names a real file rather than a heredoc the suite never ships.
FM_fresh_probe() {
  rm -rf "$LAB/v_fm_probe"; mkdir -p "$LAB/v_fm_probe"
  cp -R "$PLUGIN_ROOT/commands" "$PLUGIN_ROOT/agents" "$PLUGIN_ROOT/skills" "$LAB/v_fm_probe/"
}

# Insert one line right after the opening --- fence of a probe file.
FM_insert_after_fence() {
  python3 - "$LAB/v_fm_probe/$1" "$2" <<'PY'
import sys
path, line = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read().replace("\r\n", "\n")
lines = text.split("\n")
assert lines[0] == "---", "no opening fence in " + path
lines.insert(1, line)
open(path, "w", encoding="utf-8").write("\n".join(lines))
PY
}

# Assert the checker (exit 1) names the offending key in a mutated probe tree.
# The cmp guard first: without it an unmutated file would still exit 1 from a
# neighbouring mutation, or exit 0 and fail closed -- either way unmeasured.
FM_refuses_key() {
  FM_REL="$1"; FM_KEY="$2"; FM_LABEL="$3"; FM_EXTRA="${4:-}"
  if cmp -s "$LAB/v_fm_probe/$FM_REL" "$PLUGIN_ROOT/$FM_REL"; then
    bad "$FM_LABEL" "mutation left $FM_REL byte-identical -- the test measured nothing"
    return
  fi
  FM_OUT="$(python3 "$FM_CHK" --root "$LAB/v_fm_probe" 2>&1)"; FM_RC=$?
  if [ "$FM_RC" -eq 1 ] && printf '%s\n' "$FM_OUT" | grep -q "$FM_KEY" && { [ -z "$FM_EXTRA" ] || printf '%s\n' "$FM_OUT" | grep -q "$FM_EXTRA"; }; then
    ok "$FM_LABEL"
  else
    bad "$FM_LABEL" "rc=$FM_RC out: $FM_OUT"
  fi
}

FM_OUT="$(python3 "$FM_CHK" --root "$PLUGIN_ROOT" 2>&1)"; FM_RC=$?
FM_N="$(printf '%s\n' "$FM_OUT" | sed -n 's/^checked \([0-9][0-9]*\) files$/\1/p')"
if [ "$FM_RC" -eq 0 ] && [ -n "$FM_N" ] && [ "$FM_N" -ge 9 ]; then
  ok "check_frontmatter passes the shipped components"
else
  bad "check_frontmatter passes the shipped components" "rc=$FM_RC n=${FM_N:-?} out: $FM_OUT"
fi

FM_fresh_probe
FM_OUT="$(python3 "$FM_CHK" --root "$LAB/v_fm_probe" 2>&1)"; FM_RC=$?
if [ "$FM_RC" -eq 0 ]; then
  ok "check_frontmatter control copy is clean"
else
  bad "check_frontmatter control copy is clean" "rc=$FM_RC out: $FM_OUT"
fi

FM_fresh_probe
FM_insert_after_fence "commands/ask.md" "disable-model-invocaton: true"
FM_refuses_key "commands/ask.md" "disable-model-invocaton" "check_frontmatter refuses a misspelled key (disable-model-invocaton)"

FM_fresh_probe
python3 - "$LAB/v_fm_probe/agents/muse-supervisor.md" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
assert "maxTurns: 60" in text, "control lost its maxTurns line"
open(path, "w", encoding="utf-8").write(text.replace("maxTurns: 60", "maxTurns: sixty", 1))
PY
FM_refuses_key "agents/muse-supervisor.md" "maxTurns" "check_frontmatter refuses a non-integer maxTurns"

FM_fresh_probe
FM_insert_after_fence "agents/muse-supervisor.md" "permissionMode: acceptEdits"
FM_refuses_key "agents/muse-supervisor.md" "permissionMode" "check_frontmatter refuses permissionMode on a plugin agent" "ignored for plugin agents"

FM_fresh_probe
FM_insert_after_fence "agents/muse-supervisor.md" "hooks: {}"
FM_refuses_key "agents/muse-supervisor.md" "hooks" "check_frontmatter refuses hooks on a plugin agent"

FM_fresh_probe
FM_insert_after_fence "agents/muse-supervisor.md" "mcpServers: {}"
FM_refuses_key "agents/muse-supervisor.md" "mcpServers" "check_frontmatter refuses mcpServers on a plugin agent"

FM_fresh_probe
FM_insert_after_fence "skills/muse-fleet/SKILL.md" "effort: extreme"
FM_refuses_key "skills/muse-fleet/SKILL.md" "effort" "check_frontmatter refuses an effort outside the enum"

# The self-test must be able to fire: a checker that finds nothing and a
# checker that refuses everything both have to come back non-empty, and the
# real checker must come back empty. Paths travel in argv, never in the
# program string, so this also works under Windows Git Bash driving a native
# python (argv is translated, an embedded literal is not).
FM_SELF="$(python3 - "$FM_CHK" <<'PY'
import importlib.util
import sys
spec = importlib.util.spec_from_file_location("fmcheck", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
FM_R1 = mod.self_test()
FM_R2 = mod.self_test(lambda kind, text, rel: [])
FM_R3 = mod.self_test(lambda k, t, r: ["x: y: z"])
if FM_R1 == [] and len(FM_R2) > 0 and len(FM_R3) > 0:
    print("FM_SELF_OK")
else:
    print("real=%r silent=%r noisy=%r" % (FM_R1, FM_R2, FM_R3))
PY
)"
if [ "$FM_SELF" = "FM_SELF_OK" ]; then
  ok "check_frontmatter self-test fails a checker that inspects nothing"
else
  bad "check_frontmatter self-test fails a checker that inspects nothing" "$FM_SELF"
fi

rm -rf "$LAB/v_fm_empty"; mkdir -p "$LAB/v_fm_empty"
FM_OUT="$(python3 "$FM_CHK" --root "$LAB/v_fm_empty" 2>&1)"; FM_RC=$?
if [ "$FM_RC" -eq 2 ]; then
  ok "check_frontmatter refuses to pass an empty tree"
else
  bad "check_frontmatter refuses to pass an empty tree" "rc=$FM_RC out: $FM_OUT"
fi

if [ "${FM_STANDALONE:-0}" = 1 ]; then rm -rf "$LAB"; echo "RESULT: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit $?; fi
