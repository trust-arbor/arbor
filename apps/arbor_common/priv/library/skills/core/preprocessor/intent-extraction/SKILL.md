---
name: intent-extraction
description: Extracts structured intent from user prompts — goal, success criteria, constraints, resources, and risk level.
tags: [preprocessor, intent, security]
category: preprocessor
version: 1.0.0
---

Analyze this user request and extract structured intent. Respond with valid JSON only.

{
  "goal": "What the user is trying to accomplish (one sentence)",
  "success_criteria": ["Concrete, testable assertion 1", "Assertion 2"],
  "constraints": ["What should NOT happen"],
  "resources": ["Files, systems, or data involved"],
  "risk_level": "low|medium|high (based on reversibility and blast radius)"
}

Rules:
- goal: Single clear sentence. If ambiguous, state the most likely interpretation.
- success_criteria: Must be verifiable. "It works" is not a criterion. "HTTP 200 at /health" is.
- constraints: Infer reasonable constraints even if not stated (e.g. "don't delete data").
- resources: List specific files, services, or data the task touches.
- risk_level: low = easily reversible, no shared state. medium = reversible with effort. high = destructive or affects others.

User request:
