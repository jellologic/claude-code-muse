# Muse Code CLI — verified reference

Everything here was confirmed empirically against **Muse Code 1.3.0 (1.3.0-R3401.1)** on macOS. That version is declared in code as `MUSE_TESTED_VERSION` in `scripts/muse_core.py`, and `/muse:doctor` and the SessionStart preflight warn on a major/minor mismatch — the event schema, the `exec` flags, the catalog row shape and the session directory layout are all coupled to it, and a rename in any of them surfaces as every round failing identically. Bumping that constant means re-checking this file.
Where a claim is inferred rather than tested, it says so.

## Contents
- [Models](#models)
- [Headless invocation](#headless-invocation)
- [The JSONL event stream](#the-jsonl-event-stream)
- [Worktrees and isolation](#worktrees-and-isolation)
- [Structured output](#structured-output)
- [Safety flags](#safety-flags)
- [Sessions and cross-session messaging](#sessions-and-cross-session-messaging)
- [Failure modes](#failure-modes)

---

## Models

Read the live catalog rather than trusting memory — it is refreshed by muse itself:

```bash
cat ~/.local/share/muse/model-catalog/*.json | python3 -m json.tool
```

Verified rows (catalog refreshed 2026-09-18):

| model_id | released | notes |
|---|---|---|
| `muse-spark-1.3-contributor` | 2026-09-02 | **`is_default: true`** — prefer this |
| `muse-spark-1.3` | 2026-09-02 | full-price sibling |
| `muse-spark-1.2-contributor` | 2026-08-05 | older, faster/steadier latency today |
| `muse-spark-1.2` | 2026-08-05 | full-price sibling |

All four report `context_limit: 1007997` and `output_limit: 128000`.

**Contributor models are the cheap tier.** Their catalog `description` states the tradeoff
plainly: *"Your content, including inter-session messages, may be used for product
improvement."* That is the price of the discount — do not route proprietary or
client-confidential code through a contributor model without deciding that is acceptable.
For 1.2 the published rates were $0.10/$0.20 per M in/out versus $1.25/$4.25 for the
full model; the 1.3 rows currently return `cost: null` in the catalog, so quote 1.3
pricing from Meta's docs rather than from the catalog.

### Resolve the model, do not hardcode it

`~/.config/muse/settings.json` carries a `model` key that interactive sessions use.
Muse maintains this file itself — it was observed rewriting `muse-spark-1.2-contributor`
to `muse-spark-1.3-contributor` once the catalog refreshed, and adding its own `tui` keys
at the same time. So the pin does self-heal; it is simply stale in the window before a
refresh, and hand-editing it is pointless because muse will rewrite it anyway.

For scripted runs, pass `--model` explicitly and compute the value from the catalog rather
than writing a version into your script. Select on `release_date` among visible models
whose id ends in `-contributor`:

```python
cands = [r for r in rows
         if r["model_id"].endswith("-contributor")
         and r.get("visibility", "visible") == "visible"]
cands.sort(key=lambda r: str(r.get("release_date") or ""), reverse=True)
latest = cands[0]["model_id"]
```

Deliberately ignore `is_default`: it tracks the provider's preference, which could move to
a full-price tier, whereas you want the newest discounted one. Keep a hardcoded fallback
for when the catalog is missing or corrupt — a stale pick beats refusing to run.

Check the flag took effect (see the caveat under `run_model_configured` — this echoes the
requested id, so it catches a flag that never applied, not a provider-side substitution):

```bash
... | jq -r 'select(.payload.kind=="run_model_configured") | .payload.model_id'
```

### Reasoning effort

`--reasoning-effort none|minimal|low|medium|high|xhigh|max` (default: `high`).
1.3 advertises variants through `max`; its catalog entry annotates `xhigh` as
*"Use this for deepest analysis and complex fixes."*

Latency on 1.3-contributor is **highly variable and not monotonic in effort** — the same
trivial prompt took 216s at `minimal` and 15s at `low` in back-to-back runs. Treat that as
queueing/contention on a freshly released model, not as a tuning signal. The practical
consequence is that timeouts must be generous and concurrency bounded.

---

## Headless invocation

```bash
muse exec [OPTIONS] "PROMPT"
```

Flags that matter for orchestration:

| flag | why it matters |
|---|---|
| `--json` | JSONL event stream on stdout — the only machine-readable channel |
| `--model <ID>` | pin the model; defeats settings.json drift |
| `--reasoning-effort <E>` | cost/latency dial |
| `-w, --worktree create` | isolate this run in its own git worktree |
| `--worktree-base <REF>` | base ref for the new worktree (default `HEAD`) |
| `--worktree-existing <PATH>` | reuse a worktree you created yourself |
| `--output-schema <FILE>` | force the final answer to match a JSON schema |
| `--session-id <UUID>` | choose the session id up front instead of discovering it |
| `--prompt-file <PATH>` | avoid shell-quoting hell for long prompts |
| `--max-model-steps <N>` | hard cap on agent loop length — a runaway-cost circuit breaker |
| `--max-tool-output-bytes <N>` | cap tool output fed back to the model |
| `--user-input-auto-resolve` | auto-cancel interactive prompts so a headless run cannot hang on one |
| `--no-session-log` | skip persisting session logs |
| `--disable-web-tools` | cut network research when you want a purely local edit |

Auth in CI is an API key rather than the browser flow; muse reads it from the environment
(`muse auth set --api-key-stdin` stores one locally). On this machine credentials already
live in `~/.config/muse/auth.json`.

---

## The JSONL event stream

`--json` emits one JSON object per line. Envelope keys:

```
schema_version  id  stream  sequence  recorded_at
record_type  durability  causation_id
payload_type  payload_schema_version  payload
```

The discriminator is **`payload.kind`**. Observed kinds from real runs:

```
task_lifecycle  task_stream_linked  run_output_delta  tool_result
workspace_branch_observed  command_accepted  session_run_linked
run_model_configured  turn_input_user  run_started  run_terminal
```

`task_lifecycle` dominates by volume (114 of 153 records in one small run) — it is noise
for orchestration purposes. Three kinds carry the signal:

**`run_terminal`** — the one record that decides success. Exactly one per run:

```json
{"kind":"run_terminal","command_id":"…","run_stream":{"kind":"run","id":"…"},
 "terminal":"completed","text":"<final answer>","reason":null}
```

`terminal` is `completed` or `failed`; on failure `reason` carries the message and `text`
is empty. Parse this rather than scraping prose.

**`run_terminal.text` can hold several concatenated answers.** An agent that answers,
notices a problem, fixes it and answers again emits both, back to back with no separator:

```
{"confidence":"medium","verification":"pytest failed: No module named pytest",…}{"confidence":"high","verification":".venv/bin/python -m pytest: 4 passed",…}
```

`json.loads` rejects this with `Extra data: line 1 column 459`. In prose runs it shows up
as a visibly duplicated summary. **The last object is the finished state** — the earlier
ones are superseded, and taking the first gives you a stale, more pessimistic report.
Decode in a loop with `json.JSONDecoder().raw_decode` and keep the last result.

**`run_model_configured`** — reports the model the run was *configured* with. This is the
requested id echoed back, **not proof that model served the answer**: a run with a
nonexistent model id still emits `run_model_configured` naming it. Use it to catch a flag
that never took effect, not as evidence of what the provider actually ran.

**`workspace_branch_observed`** — the workspace root, branch name, commit and dirty flag.
In a worktree run the `workspace_root` is the worktree path and `reference.name` is the
muse branch, which is how you locate the output without parsing stderr.

Extracting the essentials:

```bash
jq -c 'select(.payload.kind=="run_terminal") | {t:.payload.terminal, text:.payload.text, reason:.payload.reason}'
```

**Stream the file, do not slurp it.** A long run produces thousands of records and the
`run_output_delta` text is chunked; concatenate deltas in `sequence` order if you want the
streamed answer, though `run_terminal.text` already holds the complete final answer.

### Exit codes

`0` on `terminal: "completed"`, `1` on `failed`. The exit code and `run_terminal.terminal`
agreed in every observed run, so either is usable — but `reason` is only in the JSON.

---

## Worktrees and isolation

```bash
muse exec --json -w create --worktree-base main "…"
```

Verified behaviour:

- The worktree is created **inside the repo** at `<repo>/.muse/worktrees/<YYYYMMDD>-<hash>`.
- It is checked out on a fresh branch named `muse/session-<session-uuid>`.
- **The main working copy is untouched.** `git status --porcelain` in the repo root stayed
  empty across single and concurrent worktree runs.
- Concurrent runs each get a distinct worktree and branch, so they do not collide.

Two consequences that bite if you miss them:

**Agents create build junk, and `git add -A` harvests it.** An agent told to verify with
pytest built a `.venv` inside its worktree; the harvest swept in **1,057 files and a 14MB
patch** around a single-file change. Nothing was wrong with the work — the signal was just
buried. Exclude build artifacts at harvest time without touching tracked fixes: stage
tracked changes unconditionally, then add only the untracked files no exclude matches:

```bash
git -C "$WT" add -u
git -C "$WT" ls-files --others --exclude-standard -z | filter-out-excluded | xargs -0 git -C "$WT" add --
git -C "$WT" diff --cached --binary --full-index "$BASE"
```

Excludes use git glob rules: `*` stays within a segment, `**` spans segments; a bare
name matches any path component; a pattern that matches a directory covers its contents.
Tracked files are always harvested even when an exclude matches them, so a fix under an
excluded directory still reaches the patch.

Cover at minimum `.venv venv __pycache__ .pytest_cache .mypy_cache node_modules dist build
target *.pyc`. Treat any unexpectedly large patch as artifacts until proven otherwise.

**Muse does not commit.** The run ends with the worktree *dirty* — stderr says
`session worktree retained at … (dirty worktree retained)`. Nothing is committed to the
muse branch, so `git log` on that branch shows only the base commit. Harvest with a diff
against the base ref, or commit inside the worktree yourself:

```bash
git -C "$WT" add -A
git -C "$WT" -c user.email=muse@local -c user.name=muse commit -qm "muse: $TASK"
```

**`.muse/` is not gitignored.** Because worktrees land inside the repo, an un-ignored
`.muse/` shows up as untracked noise and can be committed by accident. Add it to
`.git/info/exclude` (local, does not dirty the repo's tracked `.gitignore`):

```bash
grep -qxF '.muse/' .git/info/exclude || echo '.muse/' >> .git/info/exclude
```

Cleanup is manual:

```bash
git worktree remove --force "$WT"
git branch -D "muse/session-$SID"
git worktree prune
```

### `--subagent-worktree-isolation`

A compatibility flag; the help text states the capability already defaults on and that
"only an affirmative per-child request asks for isolation; omission stays shared." So
muse's *own internal* subagents share the session workspace unless a child asks otherwise.
Do not rely on it for the isolation you care about — get isolation from one `-w create`
per muse **process**, which is tested and unambiguous.

---

## Structured output

`--output-schema FILE` takes a JSON Schema file (meta provider only) and shapes the final
answer. This turns `run_terminal.text` into parseable JSON instead of prose, which is what
makes fan-out results aggregatable.

```json
{"type":"object","required":["summary","files_changed","confidence"],
 "properties":{"summary":{"type":"string"},
               "files_changed":{"type":"array","items":{"type":"string"}},
               "confidence":{"type":"string","enum":["high","medium","low"]}},
 "additionalProperties":false}
```

**Every property must also be listed in `required`.** The Meta API has no notion of an
optional field and rejects the request outright:

```
API error 400: 'required' is required to be supplied and to be an array
including every key in properties. Missing 'concerns'. (invalid_request_error)
```

This arrives as `terminal: "failed"` about 2s in, per task — so a malformed schema fails an
entire fleet at once, for real money. Validate locally before spawning:

```python
props, req = set(sch.get("properties", {})), set(sch.get("required", []))
assert not props - req, f"must be in required: {sorted(props - req)}"
```

Model "optional" fields as always-present-but-empty (`"concerns": []`) instead.

Treat the schema as a *request*, not a guarantee: still wrap the parse in try/except and
fall back to the raw text, because a failed run returns empty `text` and no JSON at all.

---

## Safety flags

Approval and sandboxing are **on by default**, which would block a headless run waiting for
a prompt that never comes. The relevant switches:

| flag | effect |
|---|---|
| `--yolo` | disable approval **and** sandbox, trust workspace, for this run |
| `--disable-approval` | drop approval prompts only |
| `--trust-workspace` | load the workspace's skills and rules without saving trust |
| `--disable-sandbox` | drop filesystem/network sandboxing only |
| `--sandbox-network <MODE>` | `restricted`\|`enabled`\|`proxy-only` (default `proxy-only`) |
| `--disable-write` | no non-shell filesystem writes |
| `--disable-shell` | no shell execution |
| `--approval-mode <MODE>` | `untrusted`\|`on-request`\|`never` (default `on-request`) |

`--yolo` is the blunt instrument and is what most scripted examples reach for. It is
defensible *because the worktree is the blast radius* — an agent that can only write inside
a throwaway worktree on a throwaway branch cannot damage the main checkout. The safer
composition when you do not need network or shell is
`--disable-approval --sandbox-network restricted`, which keeps the sandbox on.

Never point `--yolo` at a dirty main working copy. The isolation is what makes it safe.

---

## Muse inherits your Claude Code skills

Muse imports Claude Code personal skills and announces it on stderr:

```
muse: Including your 1 Claude Code personal skill — manage with /settings.
```

`muse skills import --from claude|codex` does this explicitly, but foreign personal context
is picked up by default. For a fleet this is worse than useless: a worker can load the very
orchestration skill that spawned it and start reasoning about fanning out its own subtasks
instead of making the one edit it was asked for.

Pass `--no-foreign-personal-context` to keep workers scoped to their prompt. Use
`--trust-workspace` if you *do* want the repo's own project skills and rules, which are
usually relevant in a way your personal skills are not.

## Sessions and cross-session messaging

- `muse resume --last` or `muse resume <uuid|name>` continues a session.
- `muse exec --session-id <UUID>` fixes the id ahead of time, and **reusing that id on a
  later `muse exec` continues the same conversation.** Measured: a codeword planted in one
  invocation is recalled in the next; a fresh id and no id both answer "NONE". This is what
  `muse_task.py revise` uses so a revision is a follow-up rather than a re-brief.
- An unknown `--session-id` is **not** an error. Muse starts a new conversation under that
  id silently, so anything depending on continuity must verify the session exists first —
  `muse_core.session_exists()` checks `<data-dir>/sessions/.msp-view-v1/<uuid>` and the
  dated `sessions/YYYY/MM/DD/<uuid>` tree.
- `--no-session-log` disables session persistence, which also disables resume.
- Session state: `~/.local/share/muse/sessions/`, index at `session-index.db`.
- `muse session-message list [--json]` and
  `muse session-message send --target <uuid-or-name> [--in-reply-to <token>] < body`
  pass messages between **live local sessions** over a Unix socket
  (`~/.local/share/muse/runtime/muse/session-msg-ns2.sock`). macOS/Linux only, not Windows.

Cross-session messaging only works between sessions that are *concurrently alive*, so it
suits a long-lived lead session coordinating long-lived workers. For batch fan-out where
each worker is a short `muse exec` that exits, the filesystem (worktree diffs + JSONL) is
the more reliable channel. Note that on a contributor model, inter-session messages are
explicitly named as content that may be used for product improvement.

---

## Failure modes

**Trivial prompts never reach the provider.** `muse exec "hi"` returns a canned greeting
("Hello! How can I help you today?") in ~550ms and exits 0 — *even with a nonexistent model
id*. Muse short-circuits greetings locally, so the model is never validated.

The consequence for testing: a smoke test that sends "hi" proves only that the binary runs.
Any check meant to exercise the model, validate credentials, or confirm a model id must use
a prompt that requires actual work ("Reply with exactly: OK" is enough).

**Invalid model id** — with a prompt that does reach the provider, fails fast, ~2s, cleanly:

```json
{"kind":"run_terminal","terminal":"failed","text":"",
 "reason":"model `muse-spark-9.9-contributor` does not exist or you lack access [request_id=…]"}
```

Exit code 1. A *hang* therefore does not mean a bad model id — it means contention.

**Slow runs.** 1.3-contributor took 216s on a trivial prompt in one run and 15s in another.
Always impose your own wall-clock timeout and kill the process; muse will not do it for you.

**Not a git repo.** `-w create` requires git. Guard before fanning out.

**`timeout(1)` does not exist on macOS.** Use `gtimeout` from coreutils, or implement the
timeout in the supervising process — silently doing nothing is the failure mode if you
forget.
