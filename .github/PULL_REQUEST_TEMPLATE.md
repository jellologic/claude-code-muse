## What this changes

<!-- One or two sentences. If this is a rename plus a behaviour change, please split it. -->

## What you measured

<!-- Measured results, not expectations. Paste the RESULT line; it beats "tested and working". -->

- [ ] `bash scripts/validate.sh --offline` passes (paste the RESULT line)
- [ ] `bash scripts/validate.sh` (live, costs money) — ran it / not needed because:
- [ ] Reinstalled and ran `claude plugin details muse`, and every component count is
      non-zero (a zero count is how a mis-shaped config fails, silently)

```
paste the RESULT line here
```

## If you added or changed a guard

A check that inspects nothing passes exactly like a check that found nothing, so please
prove it can fail: break the behaviour, confirm the suite goes red and names the right
check, restore, confirm green.

- [ ] Negative-controlled, or: no guard was added
- What I broke, and what went red:

## Checklist

- [ ] Intra-plugin paths use `${CLAUDE_PLUGIN_ROOT}` — no absolute paths, no `~/`, no
      cwd-relative paths
- [ ] `muse-supervisor` still has no `Write` or `Edit` tool (see CONTRIBUTING.md)
- [ ] Nothing conflates `completed` with `accept`
- [ ] Comments explain *why something would break*, not what the line does

## Anything you could not verify

<!-- Genuinely useful. More useful than a confident claim that turns out to be wrong. -->
