# conversational — context-slice eval for referential turns

**Task:** `preprocessor.needs_tools` (the gate with solid human-QA truth).
**Question:** the production preprocessor classifies the **current user message only**.
Short referential replies — "yes", "go ahead", "the second one", "fix it", "keep
going" — are ambiguous on their own, because what they need depends on the prior
turn. Does giving the classifier a **slice of context** (the immediately preceding
assistant turn) fix those cases, and at what cost?

## What it measures

A/B over the **same** message, two prompt variants:

| variant | prompt | what the model sees |
|---|---|---|
| `single_turn` | `prompts/single_turn.json` | the user message only — **today's production behavior** |
| `with_context` | `prompts/with_context.json` | the prior assistant turn **+** the user message (truncated antecedent) |

Both reuse the production needs_tools system prompt verbatim (the `with_context`
one adds two sentences telling the model to resolve the reference against the prior
turn). Read results **by prompt variant**:

- **Referential rows** (`affirm_tool`, `affirm_notool`, `select`, `continue`,
  `deictic`): `single_turn` should fail — the model can't know what "yes" approves.
  `with_context` should recover them. That's the win we're testing for.
- **Control rows** (`control_selfcontained`, `control_nonactionable`): `with_context`
  must **not** degrade them. Adding context shouldn't flip a verdict that single-turn
  already got right. (Guards against "always prepend context" hurting clean cases.)

FN-first, like `../needs-tools`: a missed tool-need (FN) routes to the no-tools fast
lane and the task fails. The `vars.kind` field slices results by scenario type.

## Running

LM Studio JIT-loading several models at `-j 4` crashes (SIGABRT). **Pre-load first:**

```bash
lms load gemma-4-e4b-it-qat ; lms load gemma-4-e4b-it@q2_k_xl ; lms load gemma-4-e4b-it ; lms load granite-4.1-8b
npx promptfoo@latest eval -c promptfooconfig.yaml -j 4 --no-cache -o results.json
npx promptfoo@latest view     # compare single_turn vs with_context side by side
```

## Scope — what this is NOT (Hysun, 2026-06-25)

- **HITL / pending-action approval is a separate mechanism, not a context source.**
  When a tool call needs approval the engine **pauses the call mid-turn** and awaits
  a single key — `y`/`n`/`a` in the TUI, a click in a GUI. That approval is not a
  chat message and does not pass through this classifier, so the pending proposal is
  not fed to needs_tools. Don't wire it in here.
- **The zero-token routing policy is validated elsewhere.** The cheap safe-default
  ("short/referential reply → don't take the DIRECT no-tools lane; inherit the prior
  turn's disposition") is an orchestrator routing rule, not a model behavior, so it's
  tested in the orchestrator — not in this harness. This harness only answers whether
  a context slice improves the **model's** verdict, which is the input that decides
  whether building the context-slice tier is worth its tokens at all.

## Data

`sanity.jsonl` is curated, synthetic, no personal content — committed. If a real
conversational corpus is ever captured it goes in a gitignored `dataset.jsonl`
(see `.gitignore`), same split as the sibling `needs-tools` / `complexity` dirs.
