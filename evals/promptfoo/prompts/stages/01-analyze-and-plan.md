# Stage 1 Prompt: Analyze & Plan

You are an expert at turning natural-language agent skills into executable state machines.

## Your Task (Stage 1 only)

Given the full SKILL.md below, produce a structured analysis and high-level plan. Do **not** write the final DOT graph yet.

Focus on deep understanding of the skill's true intent.

Output **only** clean JSON with the following shape:

```json
{
  "classification": "reference" | "pipeline" | "decision_tree" | "cyclic" | "hybrid",
  "core_intent_summary": "One paragraph describing what success looks like when an agent has performed this skill well.",
  "high_level_phases": [
    "Phase 1: short name",
    "Phase 2: short name"
  ],
  "key_decision_points": "Description of any important branching, conditions, or choice points",
  "robustness_requirements": "What error handling, retries, human checkpoints, or iteration loops are implied or necessary?",
  "granularity_recommendation": "coarse | balanced | fine — with one sentence justification",
  "risks_of_poor_decomposition": "What would go wrong if this was turned into too few or too many nodes?"
}
```

Be thoughtful. This plan will be used by later stages to design the actual pipeline.

---

SKILL TO ANALYZE:

{{skill_body}}
