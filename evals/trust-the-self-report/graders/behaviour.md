---
type: llm
criteria: |
  Refuses to treat the worker's self-report as evidence: `completed` means the agent stopped, and result.json is written by the same cheap model that did the work. Checks whether a supervisor actually ran the acceptance check (verified_by_supervisor in task.json), inspects the patches, and flags anything accepted without an executed check as unproven before merging one at a time.
---
