# DOT Compilation Prompt Tuning Notes

This document captures observations from running the same SKILL.md → DOT eval across many models (local small/medium + strong cloud baselines) and concrete recommendations for improving `Arbor.Actions.Skill.CompilationPrompt`.

## Observed Failure Modes (across local models)

1. **Thinking trace leakage** (biggest problem)
   - Many models (especially 7B–30B class) emit long "Thinking:", classification, or planning text before or around the DOT.
   - This violates the "Output ONLY the DOT" rule and breaks downstream use.

2. **Over-fragmentation on reference skills**
   - Reference/guideline skills (most heartbeat cognitive modes, docker-expert, etc.) are frequently turned into 5–12 node workflows instead of the intended minimal 3-node pattern.

3. **Weak instruction following on output format**
   - Missing or misplaced `// Category:` comment.
   - Markdown fences or explanatory text after the graph.
   - Incorrect handler choices (`tool`/`exec` instead of `llm` for pure analysis steps).

4. **Prompt quality inside nodes**
   - Node prompts are often too vague or copy the skill text verbatim instead of being crisp, actionable instructions for the orchestrator node.

Strong cloud models (Kimi K2 series, latest GLM, Claude Sonnet, etc.) almost never exhibit problems 1–3 when given the current prompt. They are excellent at "think silently, emit only the required format."

This tells us the **current prompt is already high quality for strong models**, but insufficiently reinforced for the weaker models we actually want to run locally.

## Recommended Prompt Hardening (for better small/medium model behavior)

### 1. Stronger "silent thinking" instruction (add near the top)

Add something like this early in the system prompt, before the classification step:

> **Critical Output Discipline**
> You must perform all reasoning, classification, and planning **silently and internally**. 
> Your final response must contain **absolutely nothing** except the required DOT output (starting with the `// Category:` comment).
> Do not output "Thinking:", "Let me analyze...", explanations, markdown fences, or any text before or after the graph.
> If you produce any text other than the clean DOT graph, the output is invalid for this task.

### 2. Negative few-shot examples

Add 1–2 explicit "Bad output" examples in the few-shot section:

> **Bad example (do not do this):**
> Thinking: This skill is about Docker best practices, so it is a reference skill.
> I should output a minimal 3-node graph...
>
> ```dot
> digraph ...
> ```
>
> **Good example:**
> // Category: reference
> digraph docker_reference {
>   ...
> }

### 3. Even stricter final instruction (repeat at the very end)

Current ending is already good, but make it more aggressive:

> ## Final Output Rule (non-negotiable)
> Your entire response must be ONLY the DOT graph.
> It must begin with `// Category: ...` on the first line.
> It must contain exactly one `digraph` block.
> There must be zero characters of any other kind before the category comment or after the final `}`.
> Violating this rule makes the output unusable by the Arbor orchestrator.

### 4. Optional: Add a "reference skill detector" rule with teeth

Strengthen the classification guidance:

> If after classification you determine the skill is a pure reference/guideline document (no multi-step workflow, no branching, no loops), you **MUST** emit the minimal 3-node pattern:
> `start` → single `llm` reference node → `done`.
> Creating extra nodes for a reference skill is a failure.

### 5. Consider a "strict" variant for local models

We may want two versions of the system prompt:
- The current rich one (good for strong models / when we want sophisticated pipelines).
- A stricter, more constrained version optimized for smaller local models that forces simpler, cleaner output even if it sacrifices some nuance.

## Expected Results from Strong Cloud Models

When you run the cloud baselines (Kimi, GLM-5/6, etc.) you should see:
- Near-perfect adherence to "only the DOT".
- Correct category on the first line.
- Excellent node granularity (minimal for reference skills, appropriately decomposed for real workflows).
- High structural similarity scores even on complex cases.
- LLM-judge semantic fidelity scores in the 0.85–0.95+ range.

If the cloud models still produce mediocre DOTs on certain skills, that is a signal that the **few-shot examples or handler guidance** in the prompt itself need improvement, not just output discipline.

## Next Steps

1. Run the cloud baseline set (see README).
2. Compare the best cloud outputs against the current few-shot examples.
3. If cloud models are excellent but local models are not, apply the hardening suggestions above.
4. If even strong models struggle with certain skill types, expand the few-shot set or refine the classification + node-granularity rules.

This eval loop (local models + strong cloud baselines) is currently the fastest way to improve the quality of automatically generated orchestrator pipelines from SKILL.md files.
