---
type: llm
criteria: |
  Must NOT trigger muse-fleet. The user is asking for parallel Task-tool subagents, not for work to be delegated to Muse Code; this vocabulary overlaps the skill's, so this is the highest-risk false positive. Judge only the final message. PASS when it reports running ordinary subagents (one per area: api/, db/, ui/) and relays their findings, or honestly reports that it could not spawn them. FAIL if it routes the work to Muse Code, mentions muse or a cheaper model without the user raising cost, or edits files.
---
