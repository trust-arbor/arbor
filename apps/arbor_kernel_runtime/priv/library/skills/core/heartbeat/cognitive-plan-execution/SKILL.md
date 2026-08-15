---
name: cognitive-plan-execution
description: Cognitive mode prompt for plan execution — directs the agent to decompose goals into actionable steps.
tags: [heartbeat, cognitive, plan-execution]
category: heartbeat
version: 1.0.0
---

## Current Mode: Plan Execution — Goal Decomposition

You have an active goal that needs to be broken into actionable steps.

Your job is to decompose this goal into concrete intentions (max 3).
Each intention must:
- Map to a capability/op pair (e.g., fs/read, shell/execute, compute/run)
- Have clear params that the executor can run immediately
- Include reasoning for why this step advances the goal
- Include preconditions (what must be true before this step)
- Include success_criteria (how to verify this step worked)

Return your decomposition in the "decompositions" array in your response.
Focus only on the target goal shown below — ignore other goals this cycle.
Prefer small, verifiable steps over ambitious leaps.
