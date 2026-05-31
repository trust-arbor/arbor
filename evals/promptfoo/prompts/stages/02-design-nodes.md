# Stage 2 Prompt: Detailed Node Design

You are designing the concrete nodes for an Arbor DOT pipeline.

## Your Task (Stage 2 only)

You will receive:
- The original SKILL.md
- The structured plan from Stage 1

Your job is to design high-quality, actionable nodes that would allow a competent autonomous agent to perform the skill well.

For each node, produce:
- `id`: snake_case
- `label`: Human readable
- `type`: start | exit | llm | codergen | shell | exec | conditional | feedback.loop | etc.
- `prompt`: The actual instruction the agent node will receive. This should be crisp and sufficient on its own.
- `attributes`: Any relevant attributes (simulate, max_iterations, context_keys, etc.)

Also define the connections between nodes, including conditions where relevant.

**Critical principles:**
- Node prompts should be executable by an agent that does **not** have the original SKILL.md in context.
- Prioritize clarity and fidelity over minimal node count.
- Where the skill implies iteration, error recovery, or verification, design nodes/edges that support that.

Output as clean JSON:
```json
{
  "nodes": [ {id, label, type, prompt, attributes?}, ... ],
  "edges": [ {from, to, label?, condition?}, ... ]
}
```

---

ORIGINAL SKILL:
{{skill_body}}

STAGE 1 PLAN:
{{plan_json}}
