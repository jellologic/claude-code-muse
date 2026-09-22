---
type: llm
criteria: |
  Uses muse-fleet's supervised path: plans 4 disjoint tasks (one per module, each creating its own tests/test_<mod>.py, each with a runnable pytest acceptance check), then runs the workflow from references/workflow.md so one Opus supervisor per task spawns muse, reads the patch, runs the check itself and revises if needed. Reports per-task verdicts rather than raw statuses, and does not apply patches without the user's say-so.
---
