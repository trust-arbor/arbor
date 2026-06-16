---
name: heartbeat-response-format
description: Response format instructions appended to heartbeat prompts — specifies required and optional JSON keys.
tags: [heartbeat, response-format]
category: heartbeat
version: 1.0.0
---

## Response Format
Respond with valid JSON only — no markdown wrapping, no explanation outside the JSON object.
Required keys: "thinking", "actions", "memory_notes", "goal_updates".
Optional keys: "new_goals", "concerns", "curiosity", "proposal_decisions", "decompositions", "identity_insights".
If you have no active goals, use "new_goals" to create some.
In plan_execution mode, use "decompositions" to break goals into executable steps.
