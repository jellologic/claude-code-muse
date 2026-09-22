---
type: llm
criteria: |
  Must NOT trigger muse-fleet. The user is asking for parallel Task-tool subagents, not for work to be delegated to Muse Code. 'fan out' and 'in parallel' appear in the skill description, so this is the highest-risk false positive. Correct behaviour is to spawn ordinary subagents; muse should not be mentioned unless the user raises cost or names it.
---
