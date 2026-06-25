# needs_tools — binary tool-need gate (preprocessor dispositional layer)

**Task id:** `preprocessor.needs_tools`
**Production binding:** `gemma-4-e4b-it@q4_k_xl` via LM Studio (locked 2026-05-26;
93.1% accuracy, 10 FN / 0 FP on the 145-prompt corpus — see
`.arbor/roadmap/2-planned/preprocessor-pipeline-unification.md` open question 1 for the
full sweep history).

## Why this exists

The model sweeps that justified the production binding were run from ad-hoc Python
scripts in `~/.claude/arbor-personal/eval_corpus/` (`needs_tools_modelsweep.py`,
`effort_tier_seed.py`) — outside version control. This directory is their permanent,
reproducible home. Re-running the matrix when a new small model lands should be one
command, not a new script.

## Port status: COMPLETE (2026-06-10) — with a privacy boundary

| File | Committed? | What |
|---|---|---|
| `prompts/generic.json` | yes | the winning generic prompt (chat format) |
| `sanity.jsonl` | yes | 16 curated unambiguous prompts — no personal content |
| `convert_corpus.py` | yes | regenerates dataset.jsonl from `_import/` |
| `dataset.jsonl` | **NO — gitignored** | 145 real-usage prompts + QA truth labels (42 true / 103 false) |
| `_import/` | **NO — gitignored** | raw copy of `~/.claude/arbor-personal/eval_corpus/` |

**Privacy boundary:** Arbor is a public repo and the corpus is real usage content
(internal hostnames, IPs, project details appear in prompts). The raw corpus and
anything derived from it stay local (`.gitignore` in this directory). What's
committed is the harness: prompt, sanity set, converter, config — anyone can
reproduce the eval; only the owner's real corpus stays private.

**Regenerate locally:**
```bash
cp -r ~/.claude/arbor-personal/eval_corpus _import   # if _import/ is absent
python3 convert_corpus.py
npx promptfoo@latest eval -c promptfooconfig.yaml -j 1 -o results.json   # -j 1: see below
```

### Running against LM Studio (single GPU) — serialize the sweep

promptfoo defaults to concurrency **4**. With a single-GPU LM Studio that
JIT-loads models on request, that makes it try to load *several different models
at once* → the loads crash (`SIGABRT`, "engine protocol startup aborted";
observed 2026-06-25). A single model serving alone handles a few concurrent
requests fine — the crash is specifically multiple models loading simultaneously.

- **Serialized (simplest):** add `-j 1`. One request at a time; safe, but may
  hot-swap the model on every call across providers (slow).
- **One model at a time (recommended for a multi-model sweep):** run once per
  provider so each model loads exactly once, serves all its prompts, then the
  next loads:
  ```bash
  npx promptfoo@latest eval -c promptfooconfig.yaml \
    --filter-providers '<provider-id>' -j 2 -o results/<model>.json
  ```
  ⚠️ Provider ids share prefixes — `gemma-4-e4b-it` is a substring of
  `gemma-4-e4b-it-qat-mobile@q8_0` — so anchor the filter (`...e4b-it$`) or use
  the distinct `label:` to avoid running more than one model per invocation.

**Hardware cost (accuracy-per-GB):** see `../MODELS.md` and `../footprint.sh` for
each candidate's disk size + in-memory footprint, and why loading at a small
context (these are single short prompts — max ~1287 tokens) cuts VRAM far more
than the quant alone.

**Still in `_import/` for future task ports** (don't delete the personal originals
until these are ported too): `hysun_corpus.jsonl` (573 real prompts — raw material
for complexity/decomposer corpora), `decomposer_v2.py` + outputs (task
`preprocessor.decomposer`), `effort_tier_*` (tier seeding), `path4_classifier_*`
results (complexity classifier).

## Sweep findings to preserve (from the 2026-05-26 runs)

- **Capability threshold ≈ effective-4B** for this judgment: granite-3b (21 FN) and
  gemma-e2b (28-29 FN) under-call; gemma-e4b (10 FN) works. Don't bother re-testing
  sub-4B models without a reason.
- **Quant/provider identity matters:** Ollama granite4.1:3b collapsed (142/145 false);
  LM Studio granite-4.1-3b scored 15/16. Same model. Providers below are labeled with
  endpoint+quant for this reason.
- **False negatives are the dangerous error** (missed tool-need → false DIRECT → skip
  retrieval → task fails). Compare models on FN first, accuracy second.
- **Heavy Arbor-grounding in the prompt backfired** (traded FN for FP explosion);
  the generic prompt won every config.
- Reasoning models under LM Studio json_schema mode put JSON in `reasoning_content`
  when `content` is empty — assertions must check both.
