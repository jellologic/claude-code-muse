#!/bin/bash
# bin/ shims: every documented command must reach its script through a bare name on
# PATH, and every mention in the docs must name a shim that answers --help. Sourced
# by scripts/validate.sh (shares ok/bad/skip/head_/SKILL/LAB and the PATH helpers)
# and runnable standalone.
_BIN_STANDALONE=0
if ! command -v ok >/dev/null 2>&1; then
  _BIN_STANDALONE=1
  set -uo pipefail
  export PYTHONUTF8=1
  native_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
  }
  shell_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi
  }
  SKILL="$(native_path "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)")"
  export PLUGIN_ROOT="$SKILL"
  LAB="$(native_path "${MUSE_FLEET_LAB:-$(mktemp -d "${TMPDIR:-/tmp}/musebintest.XXXXXX")}")"
  PASS=0; FAIL=0; SKIP=0
  ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
  bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && echo "        $2"; }
  skip() { SKIP=$((SKIP+$1)); shift; printf '  SKIP  %s\n' "$*"; }
fi
command -v head_ >/dev/null 2>&1 && head_ "3e. bin/ shims"
BIN_LAB="$LAB/bin-shims"; rm -rf "$BIN_LAB"; mkdir -p "$BIN_LAB/elsewhere" "$BIN_LAB/abs" "$BIN_LAB/rel" "$BIN_LAB/home"

BIN_NAMES="muse-task muse-fleet muse-status muse-cleanup muse-doctor muse-ask muse-model"
# Map each shim to its script and interpreter without associative arrays (bash 3.2).
BIN_script() {
  case "$1" in
    muse-task)    printf 'scripts/muse_task.py' ;;
    muse-fleet)   printf 'scripts/muse_fleet.py' ;;
    muse-status)  printf 'scripts/muse_status.py' ;;
    muse-cleanup) printf 'scripts/muse_cleanup.py' ;;
    muse-doctor)  printf 'scripts/muse_doctor.py' ;;
    muse-ask)     printf 'scripts/muse_ask.sh' ;;
    muse-model)   printf 'scripts/use_latest_contributor.sh' ;;
  esac
}
BIN_interp() {
  case "$1" in
    muse-ask|muse-model) printf 'bash' ;;
    *) printf 'python3' ;;
  esac
}
# Run a shim the way the plugin's Bash tool does: by bare name, found through PATH
# lookup in a neutral cwd. Native Windows Python cannot exec the extensionless shims
# (WinError 193), so every shim execution goes through bash like this; the Python
# helpers below only ever read text. <outfile> gets the help text with CR stripped,
# because native Python emits CRLF on Windows.
BIN_run_help() {  # BIN_run_help <outfile> <bindir-native> <argv...>
  BIN_RH_OUT="$1"; shift
  BIN_RH_DIR="$1"; shift
  BIN_RH_RAW="$BIN_RH_OUT.raw"
  (cd "$BIN_LAB/elsewhere" && HOME="$BIN_LAB/home" PATH="$(shell_path "$BIN_RH_DIR"):$PATH" "$@" >"$BIN_RH_RAW" 2>&1)
  BIN_RH_RC=$?
  tr -d '\r' < "$BIN_RH_RAW" > "$BIN_RH_OUT"
  return "$BIN_RH_RC"
}

# A. Each shim must run THAT script: --help through the shim is byte-identical to
# --help against the script, directly and through a relative symlink chain. The
# direct run and the shim run share one HOME, because Python on Windows ignores
# HOME (it uses USERPROFILE) and an asymmetric HOME only happens to work there.
for BIN_N in $BIN_NAMES; do
  BIN_S="$(BIN_script "$BIN_N")"
  BIN_I="$(BIN_interp "$BIN_N")"
  if [ ! -x "$SKILL/bin/$BIN_N" ]; then
    bad "bin: shim $BIN_N is executable" "$SKILL/bin/$BIN_N missing or not +x"
    continue
  fi
  HOME="$BIN_LAB/home" "$BIN_I" "$SKILL/$BIN_S" --help >"$BIN_LAB/want-$BIN_N.raw" 2>&1
  BIN_WANT_RC=$?
  BIN_WANT="$(tr -d '\r' < "$BIN_LAB/want-$BIN_N.raw")"
  if [ "$BIN_WANT_RC" -ne 0 ] || [ -z "$BIN_WANT" ]; then
    bad "bin: shim $BIN_N runs $BIN_S" "direct $BIN_S --help rc=$BIN_WANT_RC"
    continue
  fi
  BIN_run_help "$BIN_LAB/got-$BIN_N.txt" "$SKILL/bin" "$BIN_N" --help
  BIN_GOT_RC=$?
  BIN_GOT="$(cat "$BIN_LAB/got-$BIN_N.txt")"
  if [ "$BIN_GOT_RC" -ne 0 ]; then
    bad "bin: shim $BIN_N runs $BIN_S" "shim --help rc=$BIN_GOT_RC"
  elif [ "$BIN_GOT" != "$BIN_WANT" ]; then
    bad "bin: shim $BIN_N runs $BIN_S" "shim output differs from script --help"
  else
    ok "bin: bin/$BIN_N runs $BIN_S (--help identical)"
  fi
  # A plain ln -s in Git Bash silently makes a COPY, and a copied shim resolves
  # ../scripts relative to the copy and fails. On the cygpath branch the links are
  # created as native symlinks and asserted with -h in the same check, so a copy
  # can never pass silently.
  if command -v cygpath >/dev/null 2>&1; then
    MSYS=winsymlinks:nativestrict ln -sf "$(shell_path "$SKILL/bin/$BIN_N")" "$(shell_path "$BIN_LAB/abs")/$BIN_N"
    MSYS=winsymlinks:nativestrict ln -sf "../abs/$BIN_N" "$(shell_path "$BIN_LAB/rel")/$BIN_N"
    if [ ! -h "$(shell_path "$BIN_LAB/abs")/$BIN_N" ] || [ ! -h "$(shell_path "$BIN_LAB/rel")/$BIN_N" ]; then
      bad "bin: shim $BIN_N works through a symlink chain" "Git Bash made a copy, not a link"
      continue
    fi
    BIN_REL_DIR="$(shell_path "$BIN_LAB/rel")"
  else
    ln -sf "$SKILL/bin/$BIN_N" "$BIN_LAB/abs/$BIN_N"
    ln -sf "../abs/$BIN_N" "$BIN_LAB/rel/$BIN_N"
    BIN_REL_DIR="$BIN_LAB/rel"
  fi
  BIN_run_help "$BIN_LAB/rel-$BIN_N.txt" "$BIN_REL_DIR" "$BIN_N" --help
  BIN_REL_RC=$?
  BIN_REL_GOT="$(cat "$BIN_LAB/rel-$BIN_N.txt")"
  if [ "$BIN_REL_RC" -ne 0 ]; then
    bad "bin: shim $BIN_N works through a symlink chain" "rc=$BIN_REL_RC"
  elif [ "$BIN_REL_GOT" != "$BIN_WANT" ]; then
    bad "bin: shim $BIN_N works through a symlink chain" "output through rel chain differs"
  else
    ok "bin: bin/$BIN_N works through a symlink chain"
  fi
done

# B. Every shim mention in the docs must name a form that answers --help, and every
# subcommand must be one the shim accepts. The helper is pure text: it prints COUNT,
# NAMES, one FORM line per mention and the UNKNOWN lines, and never executes
# anything, because native Python on Windows cannot exec the shims and must not
# call bash either (that can resolve to WSL's bash.exe). Bash runs every --help
# itself through BIN_run_help. Helpers are written to files first: a heredoc with
# backticks inside $( ) does not parse on macOS bash 3.2.
cat > "$BIN_LAB/extract.py" <<'PY'
import glob, os, re, sys
root = sys.argv[1]
bindir = os.path.join(root, "bin")
have = set()
if os.path.isdir(bindir):
    have = set(f for f in os.listdir(bindir)
               if os.path.isfile(os.path.join(bindir, f))
               and os.access(os.path.join(bindir, f), os.X_OK))
names = sorted([n for n in have if re.fullmatch(r"muse-[a-z]+", n)],
               key=len, reverse=True)
pat = None
if names:
    pat = re.compile(r"(?:^|[\s`\"'(])(%s)(?![\w-])(?:[ \t]+([a-z][a-z-]*))?"
                     % "|".join(names))
cmd = re.compile(r"(?:^|[|;&(]|\$\()\s*(?:\$\s+)?(?:[A-Za-z_]\w*=\S*\s+)*"
                 r"(muse-[a-z]+(?:-[a-z]+)*)(?![\w.\-/])")
agents = set()
agents_dir = os.path.join(root, "agents")
if os.path.isdir(agents_dir):
    agents = set(os.path.splitext(f)[0] for f in os.listdir(agents_dir)
                 if f.endswith(".md"))
skills = set()
skills_dir = os.path.join(root, "skills")
if os.path.isdir(skills_dir):
    skills = set(f for f in os.listdir(skills_dir)
                 if os.path.isdir(os.path.join(skills_dir, f)))
wfs = set()
wf_dir = os.path.join(root, "workflows")
if os.path.isdir(wf_dir):
    wfs = set(os.path.splitext(f)[0] for f in os.listdir(wf_dir)
              if f.endswith(".js"))
extra = agents | skills | wfs
# Native Windows Python joins the glob hit with a backslash, which would put
# "commands\p1.md" in every printed location; forward slashes read identically
# on every platform, so the bash side can grep one spelling.
files = sorted(f.replace(os.sep, "/") for f in
               glob.glob(root + "/agents/*.md")
               + glob.glob(root + "/commands/*.md")
               + glob.glob(root + "/skills/*/SKILL.md")
               + glob.glob(root + "/references/*.md"))
SCAN_FENCES = {"", "bash", "sh", "shell", "zsh", "console"}
mentions = []
unknowns = []
cmdcount = 0
for f in files:
    in_fence = False
    scan = False
    for i, line in enumerate(open(f, encoding="utf-8", errors="replace"), 1):
        s = line.rstrip("\n")
        st = s.strip()
        if st.startswith("```"):
            if in_fence:
                in_fence = False
                scan = False
            else:
                info = st[3:].strip().split()
                info = info[0].lower() if info else ""
                in_fence = True
                scan = info in SCAN_FENCES
            continue
        if in_fence:
            units = [s] if scan else []
        else:
            units = re.findall(r"`([^`]+)`", s)
        for u in units:
            if pat is not None:
                for m in pat.finditer(u):
                    mentions.append((m.group(1), m.group(2) or "",
                                     "%s:%d" % (f, i)))
            for m in cmd.finditer(u):
                cmdcount += 1
                tok = m.group(1)
                if tok not in have and tok not in extra:
                    unknowns.append(("%s:%d" % (f, i), tok))
print("COUNT %d" % len(mentions))
print("NAMES %s" % " ".join(sorted(set(n for (n, _, _) in mentions))))
for (n, sub, loc) in mentions:
    print("FORM\t%s\t%s\t%s" % (n, sub, loc))
for (loc, tok) in unknowns:
    print("UNKNOWN %s %s" % (loc, tok))
print("CMDCOUNT %d" % cmdcount)
PY
python3 "$BIN_LAB/extract.py" "$SKILL" > "$BIN_LAB/extract.out"
BIN_NLINES="$(sed -n 's/^COUNT //p' "$BIN_LAB/extract.out")"
if [ -z "$BIN_NLINES" ]; then BIN_NLINES=0; fi
if [ "$BIN_NLINES" -lt 20 ]; then
  bad "bin: docs name at least 20 shim examples" "extracted $BIN_NLINES mentions"
fi
# The NAMES line only: the FORM and UNKNOWN lines carry paths like
# skills/muse-fleet/, which would match every name against the whole line.
BIN_SEEN="$(sed -n 's/^NAMES //p' "$BIN_LAB/extract.out")"
BIN_MISSING=""
for BIN_N in $BIN_NAMES; do
  case " $BIN_SEEN " in
    *" $BIN_N "*) ;;
    *) BIN_MISSING="$BIN_MISSING $BIN_N" ;;
  esac
done
if [ -n "$BIN_MISSING" ]; then
  bad "bin: docs name every shim" "never mentioned:$BIN_MISSING"
fi
# One --help per distinct shim name, run by bash through PATH lookup. The
# argparse subcommand set is the first "{a,b,...} ..." group; a bare "{low,medium}"
# with no trailing " ..." (an option's choices) does not count.
grep '^FORM' "$BIN_LAB/extract.out" > "$BIN_LAB/forms.all" || true
cut -f2 "$BIN_LAB/forms.all" | sort -u > "$BIN_LAB/form.names" || true
: > "$BIN_LAB/forms.bad"
while IFS= read -r BIN_HNAME; do
  case "$BIN_HNAME" in '') continue;; esac
  BIN_run_help "$BIN_LAB/help-$BIN_HNAME.txt" "$SKILL/bin" "$BIN_HNAME" --help
  printf '%s' "$?" > "$BIN_LAB/helprc-$BIN_HNAME"
  BIN_SET="$(sed -n 's/.*{\([a-z0-9_,-]*\)} \.\.\..*/\1/p' "$BIN_LAB/help-$BIN_HNAME.txt" | head -1)"
  printf '%s' "$BIN_SET" > "$BIN_LAB/helpset-$BIN_HNAME"
done < "$BIN_LAB/form.names"
# One run per distinct form: a subcommand in the set runs "name sub --help", a form
# with no set behind it runs "name --help", and a subcommand outside the set is
# reported without running anything. Membership is a case pattern (bash 3.2 has no
# associative arrays). Redirects, not pipes into while, so FAIL counts survive.
BIN_TAB="$(printf '\t')"
sort -t"$BIN_TAB" -k2,2 -k3,3 -u "$BIN_LAB/forms.all" > "$BIN_LAB/forms.uniq" || true
while IFS= read -r BIN_FLINE; do
  BIN_FNAME="$(printf '%s' "$BIN_FLINE" | cut -f2)"
  BIN_FSUB="$(printf '%s' "$BIN_FLINE" | cut -f3)"
  BIN_FLOC="$(printf '%s' "$BIN_FLINE" | cut -f4)"
  BIN_SET="$(cat "$BIN_LAB/helpset-$BIN_FNAME" 2>/dev/null)"
  BIN_HRC="$(cat "$BIN_LAB/helprc-$BIN_FNAME" 2>/dev/null)"
  if [ -n "$BIN_FSUB" ] && [ -n "$BIN_SET" ]; then
    case ",$BIN_SET," in
      *",$BIN_FSUB,"*)
        BIN_run_help "$BIN_LAB/subhelp-$BIN_FNAME-$BIN_FSUB.txt" "$SKILL/bin" "$BIN_FNAME" "$BIN_FSUB" --help
        BIN_SRC=$?
        if [ "$BIN_SRC" -ne 0 ]; then
          printf '%s\n' "$BIN_FLOC $BIN_FNAME $BIN_FSUB --help rc=$BIN_SRC" >> "$BIN_LAB/forms.bad"
        fi
        ;;
      *)
        printf '%s\n' "$BIN_FLOC $BIN_FNAME $BIN_FSUB: not a subcommand" >> "$BIN_LAB/forms.bad"
        ;;
    esac
  else
    if [ "$BIN_HRC" != "0" ]; then
      printf '%s\n' "$BIN_FLOC $BIN_FNAME --help rc=$BIN_HRC" >> "$BIN_LAB/forms.bad"
    fi
  fi
done < "$BIN_LAB/forms.uniq"
if [ -s "$BIN_LAB/forms.bad" ]; then
  while IFS= read -r BIN_ELINE; do
    bad "bin: doc example runs" "$BIN_ELINE"
  done < "$BIN_LAB/forms.bad"
elif [ "$BIN_NLINES" -gt 0 ]; then
  ok "bin: docs name $BIN_NLINES shim examples and every form answers --help"
fi
# A mistyped shim must be refused, not silently untested: every muse-* token used
# as a command in the docs has to name a shim in bin/ or an agent, skill or
# workflow derived from the tree. An absence check that found no input would pass
# vacuously, so CMDCOUNT proves the input was non-empty first.
BIN_CMDCOUNT="$(sed -n 's/^CMDCOUNT //p' "$BIN_LAB/extract.out")"
if [ -z "$BIN_CMDCOUNT" ]; then BIN_CMDCOUNT=0; fi
if [ "$BIN_CMDCOUNT" -eq 0 ]; then
  bad "bin: every muse-* command in the docs names a shim in bin/" "no command-position muse-* tokens found"
else
  grep '^UNKNOWN ' "$BIN_LAB/extract.out" > "$BIN_LAB/unknown.bad" || true
  if [ -s "$BIN_LAB/unknown.bad" ]; then
    while IFS= read -r BIN_ULINE; do
      bad "bin: every muse-* command in the docs names a shim in bin/" "$(printf '%s' "$BIN_ULINE" | sed 's/^UNKNOWN //')"
    done < "$BIN_LAB/unknown.bad"
  else
    ok "bin: every muse-* command in the docs names a shim in bin/"
  fi
fi
# Probe: a mistyped shim, a bad inline token, and the near-misses that must pass.
# Probe files go to files through quoted heredocs, and extract.py runs on the probe
# tree; the --help below is executed by bash through PATH lookup, never by Python.
BIN_NPROBE="$BIN_LAB/name-probe"
rm -rf "$BIN_NPROBE"; mkdir -p "$BIN_NPROBE/bin" "$BIN_NPROBE/agents" "$BIN_NPROBE/references"
printf '#!/bin/sh\nexit 0\n' > "$BIN_NPROBE/bin/muse-task"
chmod +x "$BIN_NPROBE/bin/muse-task"
printf '# probe\n' > "$BIN_NPROBE/agents/muse-helper.md"
cat > "$BIN_NPROBE/references/p.md" <<'MDEOF'
# probe

```bash
muse-tsak run --id x
muse-task run --id y
```

Prose with inline `muse-statsu`, inline `muse-helper`, inline `muse-spark-1.3-contributor` and inline `skills/muse-fleet/SKILL.md`.
MDEOF
python3 "$BIN_LAB/extract.py" "$BIN_NPROBE" > "$BIN_LAB/name-probe.out"
grep '^UNKNOWN ' "$BIN_LAB/name-probe.out" > "$BIN_LAB/name-probe.unk" || true
if grep -q ' muse-tsak$' "$BIN_LAB/name-probe.unk" \
  && grep -q ' muse-statsu$' "$BIN_LAB/name-probe.unk" \
  && ! grep -qE ' muse-(task|helper|spark|fleet)$' "$BIN_LAB/name-probe.unk"; then
  ok "bin: a mistyped shim name in a doc example is refused (probe)"
else
  BIN_NP_DETAIL="$(tr '\n' ';' < "$BIN_LAB/name-probe.out")"
  bad "bin: a mistyped shim name in a doc example is refused (probe)" "$BIN_NP_DETAIL"
fi
# Probe: the subcommand check must cover every shim with subcommands, not only
# muse-task. A fresh bin/ with one argparse script keeps the probe hermetic; bash
# runs it through PATH lookup and derives the subcommand set the same way.
BIN_SUBPROBE="$BIN_LAB/sub-probe"
rm -rf "$BIN_SUBPROBE"; mkdir -p "$BIN_SUBPROBE/bin" "$BIN_SUBPROBE/references"
cat > "$BIN_SUBPROBE/bin/muse-zed" <<'PYEOF'
#!/usr/bin/env python3
import argparse
p = argparse.ArgumentParser()
s = p.add_subparsers(dest="c", required=True)
s.add_parser("alpha")
s.add_parser("beta")
p.parse_args()
PYEOF
chmod +x "$BIN_SUBPROBE/bin/muse-zed"
cat > "$BIN_SUBPROBE/references/p.md" <<'MDEOF'
# probe

```bash
muse-zed alpha
muse-zed gamma
```
MDEOF
BIN_run_help "$BIN_LAB/help-muse-zed.txt" "$BIN_SUBPROBE/bin" muse-zed --help
BIN_ZED_RC=$?
BIN_ZED_SET="$(sed -n 's/.*{\([a-z0-9_,-]*\)} \.\.\..*/\1/p' "$BIN_LAB/help-muse-zed.txt" | head -1)"
BIN_ZED_BAD=0
if [ "$BIN_ZED_RC" -ne 0 ]; then
  BIN_ZED_BAD=1
else
  case ",$BIN_ZED_SET," in
    *",gamma,"*) BIN_ZED_BAD=1 ;;
  esac
  case ",$BIN_ZED_SET," in
    *",alpha,"*) ;;
    *) BIN_ZED_BAD=1 ;;
  esac
fi
if [ "$BIN_ZED_BAD" -eq 0 ]; then
  ok "bin: the subcommand check covers every shim with subcommands, not only muse-task"
else
  bad "bin: the subcommand check covers every shim with subcommands, not only muse-task" "set=[$BIN_ZED_SET] rc=$BIN_ZED_RC"
fi

# C. Grants: only muse-* shims, read-only git, echo and date may be granted; every
# mentioned shim granted; every granted shim real. The helper takes the tree root
# as argv[1] and the minimum file count as argv[2] so probes can reuse it.
cat > "$BIN_LAB/grants.py" <<'PY'
import glob, os, re, sys
root = sys.argv[1]
minimum = int(sys.argv[2])
# As in extract.py: native Windows Python joins glob hits with a backslash, so
# every printed location uses forward slashes and the bash grep needs one spelling.
files = sorted(f.replace(os.sep, "/") for f in
               glob.glob(root + "/commands/*.md")
               + glob.glob(root + "/skills/*/SKILL.md"))
print("COUNT %d" % len(files))
if len(files) < minimum:
    print("BAD scanned %d grant files, fewer than the minimum %d"
          % (len(files), minimum))
    sys.exit(2)
bindir = os.path.join(root, "bin")
have_bin = set(f for f in os.listdir(bindir)
               if os.path.isfile(os.path.join(bindir, f))
               and os.access(os.path.join(bindir, f), os.X_OK))
names = sorted([n for n in have_bin if re.fullmatch(r"muse-[a-z]+", n)],
               key=len, reverse=True)
pat = re.compile(r"(?:^|[\s`\"'(])(%s)(?![\w-])" % "|".join(names)) if names else None
for f in files:
    text = open(f, encoding="utf-8", errors="replace").read()
    m = re.search(r"^allowed-tools:(.*)$", text, re.M)
    if not m:
        if "/commands/" in f.replace(os.sep, "/"):
            print("BAD %s has no allowed-tools frontmatter line" % f)
        continue
    entries = [e.strip() for e in m.group(1).split(",")]
    for e in entries:
        if e == "Bash":
            print("BAD %s grants Bash: only muse-* shims, read-only git, echo and date may be granted" % f)
        elif e.startswith("Bash"):
            gm = re.fullmatch(r"Bash\((.*)\)", e)
            BIN_ok = False
            if gm:
                inner = gm.group(1)
                if re.fullmatch(r"(muse-[a-z]+):\*", inner):
                    BIN_ok = inner[:-2] in have_bin
                elif re.fullmatch(r"git (status|rev-parse|log|diff|show|ls-files):\*", inner):
                    BIN_ok = True
                elif inner in ("echo:*", "date:*"):
                    # A workflow script cannot read the plugin root or call Date.now(),
                    # so fleet/skill preflight must echo the root and run date.
                    # Neither command runs code or reads files.
                    BIN_ok = True
            if not BIN_ok:
                print("BAD %s grants %s: only muse-* shims, read-only git, echo and date may be granted" % (f, e))
    in_fence = False
    mentioned = set()
    for line in text.splitlines():
        if line.strip().startswith("```"):
            in_fence = not in_fence
            continue
        units = [line] if in_fence else re.findall(r"`([^`]+)`", line)
        for u in units:
            if pat:
                mentioned.update(x.group(1) for x in pat.finditer(u))
    for name in sorted(mentioned):
        if ("Bash(%s:*)" % name) not in entries:
            print("BAD %s mentions %s without granting Bash(%s:*)" % (f, name, name))
    for e in entries:
        gm = re.fullmatch(r"Bash\((muse-[a-z]+):\*\)", e)
        if gm and gm.group(1) not in have_bin:
            print("BAD %s grants %s with no such file in bin/" % (f, e))
PY
python3 "$BIN_LAB/grants.py" "$SKILL" 8 > "$BIN_LAB/grants.out" 2>&1
BIN_G_RC=$?
BIN_GRANTS_N="$(sed -n 's/^COUNT //p' "$BIN_LAB/grants.out")"
# A crashed helper must never read as green: a nonzero exit, a missing COUNT line
# and any BAD line are all failures.
if [ "$BIN_G_RC" -ne 0 ] || [ -z "$BIN_GRANTS_N" ]; then
  bad "bin: grants pin the shims" "helper failed: rc=$BIN_G_RC COUNT=${BIN_GRANTS_N:-missing}"
else
  grep '^BAD ' "$BIN_LAB/grants.out" > "$BIN_LAB/grants.bad" || true
  if [ -s "$BIN_LAB/grants.bad" ]; then
    while IFS= read -r BIN_GLINE; do
      bad "bin: grants" "$(printf '%s' "$BIN_GLINE" | sed 's/^BAD //')"
    done < "$BIN_LAB/grants.bad"
  else
    ok "bin: grants pin the shims ($BIN_GRANTS_N files, only muse shims, read-only git, echo and date)"
  fi
fi
# Probe: each loose grant must still fire, and a tight file must still pass.
BIN_GPROBE="$BIN_LAB/grant-probe"
rm -rf "$BIN_GPROBE"; mkdir -p "$BIN_GPROBE/bin" "$BIN_GPROBE/commands"
ln -sf "$SKILL/bin/muse-doctor" "$BIN_GPROBE/bin/muse-doctor"
BIN_GI=0
for BIN_G in 'Bash(*)' 'Bash(sh:*)' 'Bash(python:*)' 'Bash(curl:*)' 'Bash(git push:*)'; do
  BIN_GI=$((BIN_GI+1))
  printf '%s\n' '---' "allowed-tools: $BIN_G, Read" '---' '' '# probe' > "$BIN_GPROBE/commands/p$BIN_GI.md"
done
printf '%s\n' '---' 'allowed-tools: Bash(muse-doctor:*), Bash(git status:*), Bash(date:*), Read' '---' '' '# control' > "$BIN_GPROBE/commands/good.md"
python3 "$BIN_LAB/grants.py" "$BIN_GPROBE" 1 > "$BIN_LAB/grant-probe.out"
BIN_GI=0
for BIN_G in 'Bash(*)' 'Bash(sh:*)' 'Bash(python:*)' 'Bash(curl:*)' 'Bash(git push:*)'; do
  BIN_GI=$((BIN_GI+1))
  if grep -q "commands/p$BIN_GI.md" "$BIN_LAB/grant-probe.out"; then
    ok "bin: grant check fires on $BIN_G"
  else
    bad "bin: grant check fires on $BIN_G" "not reported"
  fi
done
if grep -q "good.md" "$BIN_LAB/grant-probe.out"; then
  bad "bin: grant check passes the control file" "good.md wrongly reported"
else
  ok "bin: grant check passes the control file"
fi
# Probe: grants.py enforces its own minimum instead of the bash side comparing
# against a hardcoded count separately.
BIN_MPROBE="$BIN_LAB/grant-min-probe"
rm -rf "$BIN_MPROBE"; mkdir -p "$BIN_MPROBE/bin" "$BIN_MPROBE/commands"
ln -sf "$SKILL/bin/muse-doctor" "$BIN_MPROBE/bin/muse-doctor"
printf '%s\n' '---' 'allowed-tools: Bash(muse-doctor:*), Read' '---' '' '# probe' > "$BIN_MPROBE/commands/x.md"
python3 "$BIN_LAB/grants.py" "$BIN_MPROBE" 2 > "$BIN_LAB/grant-min.out" 2>&1
BIN_M_RC=$?
if [ "$BIN_M_RC" -ne 0 ] && grep -q 'fewer than the minimum 2' "$BIN_LAB/grant-min.out"; then
  ok "bin: grants.py refuses a tree with fewer files than its minimum (probe)"
else
  BIN_M_DETAIL="$(tr '\n' ';' < "$BIN_LAB/grant-min.out")"
  bad "bin: grants.py refuses a tree with fewer files than its minimum (probe)" "rc=$BIN_M_RC: $BIN_M_DETAIL"
fi

# D. Absence: no old recipe may remain in the doc trees or the workflow script.
# The helper takes the tree root as argv[1] so probes can reuse it. The old-path
# rule fires on any variable-prefixed or interpreter-prefixed scripts/ path, not
# just the one spelling the docs used to use.
cat > "$BIN_LAB/absence.py" <<'PY'
import glob, os, re, sys
root = sys.argv[1]
# As in extract.py: native Windows Python joins glob hits with a backslash, so
# every printed location uses forward slashes and the bash grep needs one spelling.
files = sorted(f.replace(os.sep, "/") for f in
               glob.glob(root + "/agents/*.md")
               + glob.glob(root + "/commands/*.md")
               + glob.glob(root + "/skills/*/SKILL.md")
               + glob.glob(root + "/references/*.md")
               + glob.glob(root + "/workflows/*.js"))
old = re.compile(r"(\$\{?[A-Za-z_][A-Za-z0-9_.]*\}?/scripts/(muse_[a-z_]+\.(py|sh)|use_latest_contributor\.sh))|((python3?|bash|sh)\s+[\"']?\S*scripts/(muse_|use_latest_contributor))")
# Line numbers rot: cite the script, never a line in it.
cite = re.compile(r"scripts/[A-Za-z0-9_]+\.(py|sh):[0-9]+")
total = 0
for f in files:
    for i, line in enumerate(open(f, encoding="utf-8", errors="replace"), 1):
        total += len(line)
        if "os.environ" in line and "CLAUDE_PLUGIN_ROOT" in line:
            print("BAD %s:%d os.environ with CLAUDE_PLUGIN_ROOT" % (f, i))
        if re.search(r"\$T\b", line):
            print("BAD %s:%d uses $T" % (f, i))
        if re.match(r"\s*T=", line):
            print("BAD %s:%d sets T=" % (f, i))
        if old.search(line):
            print("BAD %s:%d old script path: %s" % (f, i, line.strip()[:100]))
        if cite.search(line):
            print("BAD %s:%d cites a script line number" % (f, i))
if total == 0:
    print("NOINPUT")
PY
python3 "$BIN_LAB/absence.py" "$SKILL" > "$BIN_LAB/absence.out"
if grep -q NOINPUT "$BIN_LAB/absence.out"; then
  bad "bin: absence input is non-empty" "scanned zero bytes"
elif grep -q '^BAD ' "$BIN_LAB/absence.out"; then
  grep '^BAD ' "$BIN_LAB/absence.out" > "$BIN_LAB/absence.bad"
  while IFS= read -r BIN_ALINE; do
    bad "bin: old recipe gone" "$(printf '%s' "$BIN_ALINE" | sed 's/^BAD //')"
  done < "$BIN_LAB/absence.bad"
else
  ok "bin: no script paths, T= recipes or os.environ pointers remain in the docs"
fi
# Probe: the check must fire on the exact pattern it used to exempt, on a script
# line-number citation, and on a bash <var>/scripts/muse_ form. Probe files are
# written to files, not from inside $( ), which does not parse on bash 3.2 when
# backticks are involved.
BIN_APROBE="$BIN_LAB/absence-probe"
rm -rf "$BIN_APROBE"; mkdir -p "$BIN_APROBE/references"
cat > "$BIN_APROBE/references/probe.md" <<'MDEOF'
# probe

```js
const TASK = `python3 "${args.pluginRoot}/scripts/muse_task.py"`
```
MDEOF
cat > "$BIN_APROBE/references/cite.md" <<'MDEOF'
# probe

See `scripts/muse_doctor.py:127`.
MDEOF
cat > "$BIN_APROBE/references/varform.md" <<'MDEOF'
# probe

```bash
bash "${args.pluginRoot}/scripts/muse_ask.sh" "question"
```
MDEOF
python3 "$BIN_LAB/absence.py" "$BIN_APROBE" > "$BIN_LAB/absence-probe.out"
if grep -q "probe.md" "$BIN_LAB/absence-probe.out"; then
  ok "bin: check D fires on a python3 \"\${...}/scripts/muse_*.py\" line"
else
  bad "bin: check D fires on a python3 \"\${...}/scripts/muse_*.py\" line" "not reported"
fi
if grep -q "cite.md" "$BIN_LAB/absence-probe.out"; then
  ok "bin: check D fires on a script line-number citation"
else
  bad "bin: check D fires on a script line-number citation" "not reported"
fi
if grep -q "varform.md" "$BIN_LAB/absence-probe.out"; then
  ok "bin: check D fires on a bash <var>/scripts/muse_ form (probe)"
else
  bad "bin: check D fires on a bash <var>/scripts/muse_ form (probe)" "not reported"
fi

# E. The doctor's interactive-pin advice must name the shim, not the script. Tested
# by behaviour: pin a non-contributor model, run the doctor's JSON path, and read
# what the check actually says. The doctor exits 1 on hosts without credentials,
# so its exit code is ignored; MUSE_CONFIG_DIR is an env var, so it stays native.
mkdir -p "$BIN_LAB/pincfg"
printf '{"model":"muse-spark-1.3"}' > "$BIN_LAB/pincfg/settings.json"
MUSE_CONFIG_DIR="$BIN_LAB/pincfg" python3 "$SKILL/scripts/muse_doctor.py" --json --repo "$BIN_LAB/elsewhere" > "$BIN_LAB/pin.out" 2>/dev/null || true
cat > "$BIN_LAB/pincheck.py" <<'PY'
import json, sys
try:
    checks = json.load(open(sys.argv[1], encoding="utf-8"))["checks"]
except Exception as e:
    print("doctor --json did not parse: %s" % e)
    sys.exit(1)
pin = [c for c in checks if c.get("name") == "interactive pin"]
if not pin:
    print("no check named 'interactive pin'")
    sys.exit(1)
c = pin[0]
problems = []
if c.get("severity") != "WARN":
    problems.append("severity is %r, not WARN" % (c.get("severity"),))
fix = c.get("fix") or ""
if "muse-model --write" not in fix:
    problems.append("fix does not name muse-model --write: %r" % fix)
if "use_latest_contributor" in fix:
    problems.append("fix still names use_latest_contributor: %r" % fix)
if problems:
    print("; ".join(problems))
    sys.exit(1)
PY
BIN_PINWHY="$(python3 "$BIN_LAB/pincheck.py" "$BIN_LAB/pin.out")"
if [ $? -eq 0 ]; then
  ok "bin: the doctor interactive-pin advice names muse-model --write"
else
  bad "bin: the doctor interactive-pin advice names muse-model --write" "$BIN_PINWHY"
fi

# F. The fleet workflow must shell to the shim, not the script: bare muse-task from
# PATH when the plugin is enabled in the running session, the absolute shim when
# pluginRoot is passed. Tested by behaviour: the header lines are executed by node
# twice, not grepped. A workflow script has no filesystem, so node runs the
# header the same way the other header checks in validate.sh do.
if command -v node >/dev/null 2>&1; then
  printf 'globalThis.args = %s;\n' '{}' > "$BIN_LAB/hdr.mjs"
  sed -n '1,/^const TASK/p' "$SKILL/workflows/muse-supervised-fleet.js" >> "$BIN_LAB/hdr.mjs"
  printf 'console.log(JSON.stringify(TASK));\n' >> "$BIN_LAB/hdr.mjs"
  node "$BIN_LAB/hdr.mjs" > "$BIN_LAB/task-bare.out" 2>/dev/null
  BIN_TB_RC=$?
  printf 'globalThis.args = %s;\n' '{"pluginRoot":"/p"}' > "$BIN_LAB/hdr.mjs"
  sed -n '1,/^const TASK/p' "$SKILL/workflows/muse-supervised-fleet.js" >> "$BIN_LAB/hdr.mjs"
  printf 'console.log(JSON.stringify(TASK));\n' >> "$BIN_LAB/hdr.mjs"
  node "$BIN_LAB/hdr.mjs" > "$BIN_LAB/task-root.out" 2>/dev/null
  BIN_TR_RC=$?
  BIN_TB="$(cat "$BIN_LAB/task-bare.out")"
  BIN_TR="$(cat "$BIN_LAB/task-root.out")"
  # TASK carries its own shell double quotes (a quoted word, safe for paths with
  # spaces), so JSON.stringify escapes them: the rooted run prints backslash-quote.
  if [ "$BIN_TB_RC" -eq 0 ] && [ "$BIN_TR_RC" -eq 0 ] && [ "$BIN_TB" = '"muse-task"' ] && [ "$BIN_TR" = '"\"/p/bin/muse-task\""' ]; then
    ok "bin: the fleet workflow runs muse-task, or the absolute shim when pluginRoot is given"
  else
    bad "bin: the fleet workflow runs muse-task, or the absolute shim when pluginRoot is given" "bare=[$BIN_TB] rc=$BIN_TB_RC rooted=[$BIN_TR] rc=$BIN_TR_RC"
  fi
else
  skip 1 "bin: node not found - fleet workflow TASK not executed"
fi

if [ "$_BIN_STANDALONE" = "1" ]; then
  rm -rf "$LAB"
  printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ] || exit 1
fi
