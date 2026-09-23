---
type: llm
criteria: |
  Must NOT trigger muse-fleet. This is a human asking for ordinary git worktree hygiene on their own branches; nothing is being delegated and no coding agent is involved. The skill's description names worktree isolation, which is exactly the overlap this case exists to catch. Correct behaviour is to run, or give the exact, `git worktree add` command for each of the three branches that exist in the repo and explain the layout.
---
