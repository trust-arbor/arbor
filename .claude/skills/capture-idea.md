# Capture Idea Skill

## Description

Captures brainstorming ideas and new feature thoughts into the roadmap tracker without interrupting the current workflow.

## When to Use

Use this skill **proactively** when the user:
- Says "brainstorm:" or "idea:" at the start of a message
- Discusses a new feature or improvement idea mid-conversation
- Says things like "we should also...", "what if we...", "it would be nice to..."
- Mentions something for "later" or "future consideration"

**Do NOT interrupt** the current work. Capture the idea quickly and continue with whatever task is active.

## How to Use

1. Create a markdown file in `.arbor/roadmap/1-brainstorming/`
2. Use naming convention: `YYYY-MM-DD-short-slug.md`
3. Fill in the template with:
   - Summary of the idea (from conversation context)
   - Why it matters (infer from discussion)
   - Initial acceptance criteria (if obvious)
   - Notes linking to the conversation context

4. Briefly acknowledge the capture: "Captured idea: [title] in roadmap brainstorming."
5. **Continue with the current task** - don't derail the conversation

## File Template

```markdown
# [Short Title]

**Created:** YYYY-MM-DD
**Priority:** medium
**Category:** idea | feature | refactor | infrastructure

## Summary

[One paragraph from conversation context]

## Why It Matters

[Inferred value/reasoning]

## Acceptance Criteria

- [ ] [Initial criteria if obvious]

## Notes

Captured from conversation on YYYY-MM-DD.
[Any relevant context]

## Related Files

- [If mentioned in conversation]
```

## Example

**User says:** "brainstorm: we should add property-based tests for contract structs"

**Action:**
1. Create `.arbor/roadmap/1-brainstorming/2026-01-27-property-based-contract-tests.md`
2. Fill in template with testing idea details
3. Say: "Captured idea: Property-Based Contract Tests in roadmap brainstorming."
4. Continue with current work

## Managing the Roadmap

Other useful commands:
- **List ideas:** `ls .arbor/roadmap/1-brainstorming/`
- **Move to planned:** `git mv .arbor/roadmap/1-brainstorming/file.md .arbor/roadmap/2-planned/`
