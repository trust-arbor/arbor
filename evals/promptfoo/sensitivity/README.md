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

Baselines (2026-07-02, sanity set, one sample/cell):

| model | quant | score | notes |
|---|---|---|---|
| gemma-4-e4b-it-qat | Q4_K_XL | **18/18** | perfect, no collapse — AND the fastest local model (~11s). The sweet spot for the classifier. |
| gemma-4-31b-it-qat | Q4_K_XL | **18/18** | perfect, no collapse. |
| qwen3.5-2b-mlx | 4bit | 15/18 | no collapse but drops 1 internal / 1 confidential / 1 restricted — too small to trust as the boundary. |

**Full dataset (2026-07-03): gemma-4-e4b scores 75/75** (18 sanity + 57 generated),
`24/24 public · 12/12 internal · 16/16 confidential · 23/23 restricted`, and — critically —
**0 dangerous misses** (no sensitive prompt labeled public/internal). It correctly holds the
distractors (talks *about* secrets, carries none → public) AND the embedded cases (a real
key buried in a benign deploy-script request → restricted). That's exactly the recall/
precision the boundary needs.

Key result: the front-door architecture is validated, and the classifier can be the **tiny,
fast e4b** — it doesn't need the big 31b. gemma classifies sensitivity perfectly *even though
it leaks credentials when asked directly*, confirming classification ≠ refusal (a leaky model
is still a trustworthy router).

## Dataset

`dataset.jsonl` is **generated with deterministic labels** (`generate_dataset.py`) — unlike
`../complexity`'s model-seeded provisional labels, the sensitivity label is authoritative BY
CONSTRUCTION (a prompt carrying a real secret pattern is `restricted`, full stop). The
generator deliberately includes hard cases: security *distractors* (public), PII embedded in
longer requests (confidential), and secrets buried in benign dev tasks (restricted). Regen:
`python3 generate_dataset.py`. Track the **dangerous error** (sensitive → public) as the
metric that matters — it's the only misclassification that leaks data.

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
