# sensitivity — local-vs-cloud routing classifier

The third **preprocessor classifier** (with [`../complexity`](../complexity) and
[`../needs-tools`](../needs-tools)). Given a user request, classify its sensitivity so the
private front-door agent can route it: **public/internal → cloud OK**, **confidential/
restricted → stays local**.

## Why this exists

The 2026-07-02 agentic-safety battery ran a credential-leak task across 26 models in three
tiers (frontier / Ollama-cloud / local). **24 of 26 hand over live secrets on request** —
only `claude-opus-4.8` and `openai/gpt-chat-latest` refuse; zero cloud, zero local. So the
model is never a reliable credential boundary, and the architecture answer is a **local,
private front-door** (`gemma-4-31b-it-qat` — 15/16 on that suite, 6/6 on vision, 100%
local) that classifies sensitivity and only routes *non-sensitive* work outward. This eval
measures which model is good enough to be that front-door.

Ties into: `.arbor/roadmap/1-brainstorming/sensitivity-routing-v2.md` (Layers 1-2,
classification) and `credential-exposure-defense-in-depth.md`. Vocabulary matches
`Arbor.Gateway.PromptClassifier` (`:public | :internal | :confidential | :restricted`).

## Labels

| label | meaning | routing |
|---|---|---|
| public | no sensitive data | any model |
| internal | non-public org context (roadmaps, policies) | local preferred |
| confidential | personal / customer data (PII) | local only |
| restricted | secrets, credentials, regulated IDs (keys, SSNs, cards) | local only |

## Run

LM Studio serves one model at a time, so running all providers at once thrashes
(load/unload → HTTP 500). **Run one provider at a time, serially:**

```
npx promptfoo@latest eval -c promptfooconfig.yaml --filter-providers "gemma-4-31b" -j 1 --no-cache
# then repeat per model: gemma-4-e4b, qwen3.5-2b
npx promptfoo@latest view
```

Baseline (2026-07-02): **gemma-4-31b-it-qat scores 18/18, no collapse** (4/4 each label) —
the front-door architecture validated. It classifies sensitivity perfectly *even though it
leaks credentials when asked directly*, confirming classification ≠ refusal.

## Reading results

- **`sanity.jsonl` (18 curated, human-labeled) is authoritative.** A larger provisional
  `dataset.jsonl` can be seeded later (see ../complexity's `convert_corpus.py` pattern) but
  don't rank on it un-QA'd.
- **Watch for collapse** — a model that labels everything `restricted` scores high on the
  restricted rows but is useless (over-routes everything local). Check the per-label spread.
- **Asymmetric error cost:** a false `public` on a restricted prompt is the dangerous one
  (sensitive data leaves the box). A false `restricted` on a public prompt is merely
  conservative. Weight the front-door decision toward caution.
- **Key question for the front-door:** does `gemma-4-31b` classify restricted prompts
  correctly *even though it leaks credentials when asked*? Classification ≠ refusal.
