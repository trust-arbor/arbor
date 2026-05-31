# Additional High-Quality Skills for the DOT Compilation Eval Suite

The current suite (dot_compilation.jsonl + a few .arbor/skills examples) is small but useful. To properly pressure-test the multi-stage compiler and the CompilationPrompt, we want more diverse, high-signal examples — especially workflows with:

- Explicit multi-stage processes
- Context gathering as a first-class phase
- Tool-using / verification loops
- Error handling & robustness needs
- Reference vs. procedural distinction
- Real production intent (not toy examples)

## Top Recommended Additions (from the public Agent Skills ecosystem)

All of these come from the canonical collection at https://github.com/anthropics/skills (and related repos). They are battle-tested examples of well-written SKILL.md files.

### 1. pptx (High Priority)
- **Why excellent**: Complex creation + editing workflow, mandatory QA/visual verification loop, sub-agent usage for image inspection, strong design principles, references to supporting files/scripts.
- **Path**: `skills/pptx/SKILL.md`
- **Characteristics**: Tool-using, iterative "generate → inspect → fix" pattern, design constraints.
- **Link**: https://github.com/anthropics/skills/blob/main/skills/pptx/SKILL.md

### 2. webapp-testing (Already referenced in our earlier data — confirm we have the full version)
- Excellent branching logic, reconnaissance, error handling paths.
- Good candidate for testing conditional + parallel patterns in generated DOTs.

### 3. skill-creator (Meta — Very High Value)
- The skill that teaches people how to write good skills.
- Contains deep guidance on structure, progressive disclosure, testing with evals, trigger descriptions, etc.
- Perfect for expanding our "how to write a good skill" few-shots and for testing whether the compiler can handle meta/skills-about-skills content.
- **Path**: `skills/skill-creator/SKILL.md`

### 4. doc-coauthoring (Already in our suite)
- Keep and expand. One of the best examples of explicit multi-stage collaboration with reader-testing.

### 5. Additional Strong Candidates to Evaluate
- Research / deep-dive workflows (many teams have internal "context-gathering" or "codebase-exploration" skills — the synthesized example in the web search results is a good template).
- PR / code review skills (common in the ecosystem).
- Data analysis / reporting skills (good for accumulator + report generation patterns).
- Brand voice / writing standards skills (reference + procedural mix).

## How to Add Them

1. Copy the raw `SKILL.md` (and any key references/) into `evals/promptfoo/skills-to-evaluate/`.
2. Create a minimal expected DOT (or use a strong model + human review).
3. Add to `datasets/` or the main promptfoo config as a new test case with:
   - `skill_name`
   - `skill_body` (full content)
   - `category` (reference / pipeline / etc.)
   - `expected_dot` (or rely more on LLM rubric for semantic fidelity)
4. Run the relaxed-prompt eval and compare structural + rubric scores against the current suite.

## Next Actions (Proposed)

- [ ] Add `pptx` and `skill-creator` as the first two expansions (they stress different aspects than our current set).
- [ ] Create a small script or mix task that can ingest a folder of SKILL.md files + optional expected DOTs into the promptfoo dataset format.
- [ ] After we have 12–15 high-quality cases, re-run the full cloud + local comparison with the multi-stage compiler.

These additions will make the "does this DOT make me want to throw away the SKILL.md?" test much more rigorous.
