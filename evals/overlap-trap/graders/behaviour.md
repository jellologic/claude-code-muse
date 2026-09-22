---
type: llm
criteria: |
  Recognises all three tasks target utils.py and that (c) spans multiple files, so fan-out would produce conflicting patches. Either merges them into one task or runs sequential waves, and explains why rather than silently fanning out 3 colliding tasks. Worktree isolation must not be offered as a fix — it isolates processes, not intentions.
---
