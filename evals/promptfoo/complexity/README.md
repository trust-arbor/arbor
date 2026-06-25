# complexity — 3-way structural classifier (preprocessor)

**Task id:** `preprocessor.complexity`
**Production binding:** the live `@complexity_prompt` in
`apps/arbor_orchestrator/lib/arbor/orchestrator/preprocessor.ex` (labels:
`SIMPLE` / `MULTI_STEP` / `NON_ACTIONABLE`; default fallback `SIMPLE`).
Historically ran `granite4.1:3b` (~82.8% on the path-4 classifier eval).

## Why this exists

We want **one** local model to serve the whole preprocessor (needs_tools +
complexity, and later the effort tier), at the **smallest quant** that holds —
so users without multi-model VRAM can run it. That's a model-selection eval, and
complexity had no reproducible harness (only ad-hoc `path4_classifier_*` runs in
`_import/`). This is its permanent home, mirroring `../needs-tools/`. Run the
**same candidate matrix** here and there, then pick the model that clears both.

## ⚠️ Truth quality — read before ranking models

The 145-prompt `dataset.jsonl` labels are **`granite4.1:3b`-seeded
(`llm_seed_v2`), NOT human-QA'd** — the effort-tier review only collected human
truth for `needs_tools`. Consequences:

- **Do not rank models by corpus accuracy alone.** It's *circular* for granite
  (it generated the labels) and measures agreement-with-granite for everyone else.
- **Trustworthy signal #1: `sanity.jsonl`** — 12 curated, unambiguous,
  human-labeled prompts (committed, no personal content). A model that fails
  these is disqualified.
- **Trustworthy signal #2: collapse / distribution shape.** A model that maps
  everything to one label (e.g. all-`SIMPLE`) is useless even at high corpus
  "accuracy" on a `SIMPLE`-heavy set. Eyeball the per-label spread in
  `promptfoo view`. (Corpus distribution: NON_ACTIONABLE 75 / SIMPLE 49 /
  MULTI_STEP 21.)
- **To make corpus ranking authoritative:** do a human-QA pass on the 145 labels
  (as `needs_tools` got) or a multi-strong-model consensus re-seed, then update
  `truth_source` in `convert_corpus.py`.

## Privacy boundary (same as ../needs-tools)

Arbor is a public repo; the corpus is real usage content. Committed = the
harness (`promptfooconfig.yaml`, `prompts/`, `sanity.jsonl`, `convert_corpus.py`,
this README). Gitignored = `_import/` and the derived `dataset.jsonl`.

## Regenerate + run locally

```bash
cp -r ~/.claude/arbor-personal/eval_corpus _import   # if _import/ is absent
python3 convert_corpus.py                            # → dataset.jsonl (gitignored)
npx promptfoo@latest eval -c promptfooconfig.yaml -j 1 -o results.json   # -j 1: see note
npx promptfoo@latest view
```

**LM Studio (single GPU): serialize the sweep.** promptfoo's default concurrency
(4) makes LM Studio JIT-load multiple models at once → the loads crash
(`SIGABRT`). Use `-j 1`, or run one provider at a time. Full details +
the recommended `--filter-providers` pattern: see
`../needs-tools/README.md → "Running against LM Studio (single GPU)"`.

**Hardware cost:** `../MODELS.md` + `../footprint.sh` — disk + in-memory
footprint per candidate, and why a small loaded context (these are single short
prompts) is the biggest VRAM lever.

## Candidate matrix (2026-06-25)

`granite-4.1-3b`, `gemma-4-e4b-it`, `gemma-4-e4b-it-qat-mobile`,
`gemma-4-e2b-it-qat-mobile` — all LM Studio (`localhost:1234`). Provider/quant
identity matters (same granite behaved differently Ollama vs LM Studio — see
`../needs-tools/README.md`), so labels carry the endpoint.

**Hypothesis going in:** `granite-4.1-3b` is strong on complexity but *fails*
needs_tools (under-calls); `gemma-4-e2b` is likely too small for needs_tools. The
sweet spot for "one model, smallest quant" is most likely
`gemma-4-e4b-it-qat-mobile` — *if* its quant holds needs_tools FN low here and on
`../needs-tools`. This eval tests that.
