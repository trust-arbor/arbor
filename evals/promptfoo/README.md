# Promptfoo Evals for Arbor

This directory pilots [promptfoo](https://promptfoo.dev/) as a more mature alternative (or complement) to Arbor's built-in `Arbor.Orchestrator.Eval` framework + `mix arbor.eval`.

**Primary focus right now:** whether any local models you have loaded in **LM Studio** are good enough for the critical `SKILL.md → DOT` compilation step that powers the orchestrator (heartbeats, sessions, JIT skill execution).

## Why promptfoo here?

- Arbor's internal eval is excellent for DOT-specific structural grading + Postgres history, but promptfoo wins on:
  - Assertion ecosystem (JS, Python, exec, llm-rubric, embeddings, json-schema…)
  - First-class OpenAI-compatible provider support (LM Studio is literally 4 lines)
  - Beautiful HTML/JSON reports + GitHub Action
  - Red teaming, datasets, vars, CI ergonomics
- We keep the **single source of truth** for the compilation prompt in `apps/arbor_actions/lib/arbor/actions/skill/compilation_prompt.ex`.

## Quick Start (LM Studio)

1. **Start LM Studio local server**
   - Load the model you want to test (e.g. `qwen2.5-coder-7b`, `llama-3.1-8b`, whatever you have)
   - Local Inference Server → Start Server (default `http://localhost:1234/v1`)

2. **Dump the live system prompt** (one time, or whenever the Elixir prompt changes)
   ```bash
   mix run --no-start evals/promptfoo/scripts/dump-compilation-prompt.exs
   ```
   This writes `prompts/skill-to-dot-system.txt` from the real `CompilationPrompt` module.

3. **Edit the model you want to test**
   Open `dot-compilation/promptfooconfig.yaml` and change:
   ```yaml
   defaultTest:
     vars:
       model: "your-model-name-in-lm-studio"   # <-- change this
   ```

4. **Run the eval**
   ```bash
   npx promptfoo@latest eval \
     -c evals/promptfoo/dot-compilation/promptfooconfig.yaml \
     --no-cache \
     -o .arbor/evals/promptfoo-runs/$(date +%Y-%m-%d-%H%M)-report.html
   ```

   Or with explicit model override:
   ```bash
   npx promptfoo@latest eval -c ... -D model="phi-4-mini" -D base_url="http://localhost:1234/v1"
   ```

5. **View results**
   - The HTML report opens in your browser automatically in many setups.
   - Look at the "Table" and "Eval" tabs.
   - Failures will show the exact `score-structural-similarity` breakdown + the output of `mix arbor.pipeline.validate`.

## What "sufficient for Arbor orchestrator" means (current bar)

A model is considered **ready for JIT skill compilation** when, across the test set:

- **100%** of outputs parse cleanly with `mix arbor.pipeline.validate` (no syntax errors, has start + done sentinels).
- Average structural similarity (ported `DotDiff` logic) ≥ **0.75–0.78** (historical floor from strong cloud models on the 6-seed set).
- LLM rubric passes on semantic fidelity (the generated pipeline actually does what the skill description says, with correct node granularity and handler choices).
- Reference skills (heartbeat cognitive modes) produce the minimal 3-node pattern; workflow skills produce appropriate branching/loops with `max_iterations` and `simulate="true"`.

See the rubric text inside `promptfooconfig.yaml` for the exact prompts used.

## Directory Layout

```
evals/promptfoo/
├── README.md
├── dot-compilation/
│   └── promptfooconfig.yaml          # main eval you care about today
├── heartbeat-contract/               # future: JSON schema / heartbeat response format
├── coding/                           # future: Elixir code gen evals
├── prompts/
│   └── skill-to-dot-system.txt       # generated (never hand-edit)
├── datasets/
│   └── dot-compilation-seed.jsonl    # the 6 original + real skills (clean sidecar)
├── assertions/
│   ├── extract-dot.js                # strips fences + <think> blocks
│   ├── validate-with-arbor.js        # calls real mix arbor.pipeline.validate (hard gate)
│   └── score-structural-similarity.js# port of DotDiff (node/edge/handler/keyword)
├── scripts/
│   └── dump-compilation-prompt.exs   # keeps prompt in sync with Elixir source
└── .env.example
```

## Prompt Experimentation (Current Recommended Workflow)

We are in active prompt iteration mode using **clean, standalone configs** (no fragile `extends`).

### Running a Specific Variation (Reliable Method)

```bash
# Baseline (current main prompt)
npx promptfoo@latest eval -c evals/promptfoo/variations/configs/promptfooconfig.baseline.yaml --no-cache -j 4

# Variation 1: Fidelity Plus
npx promptfoo@latest eval -c evals/promptfoo/variations/configs/promptfooconfig.v1-fidelity-plus.yaml --no-cache -j 4

# Variation 2: Staged Internal Thinking
npx promptfoo@latest eval -c evals/promptfoo/variations/configs/promptfooconfig.v2-staged-internal.yaml --no-cache -j 4

# Variation 3: Critique-First
npx promptfoo@latest eval -c evals/promptfoo/variations/configs/promptfooconfig.v3-critique-first.yaml --no-cache -j 4
```

All configs:
- Are fully self-contained (no `extends`)
- Target your 6 loaded Ollama cloud models
- Use the strong multi-dimensional LLM judge rubric
- Run the full shared test suite via `tests/skill-to-dot-tests.yaml`

### Quick Comparison

Compare the generated JSONs, focusing on the LLM rubric scores and written reasons (especially on the `seo-audit` case). The judge is deliberately strict on translation fidelity: how accurately the model turned the SKILL.md's intent, logic, and content into a coherent state machine (nodes as states/phases, edges as control flow). Structural optimality, robustness, and "agent would prefer this" are de-emphasized for now (low-weighted or removed from the primary rubric) because those can be tuned/automated separately later.

Edit the files in `prompts/variations/` freely and re-run the matching config.

The stage files in `prompts/stages/` remain available as building blocks when we move to a real multi-call staged compiler in Elixir.

## Running Cloud / Hosted Baselines

To understand the ceiling for this task and decide whether the `CompilationPrompt` needs tuning, it is very useful to run the same eval against strong hosted models (Kimi K2, GLM-5/6, Minimax, Nemotron Super, DeepSeek, Claude, GPT-4o, etc.).

1. Create the necessary API keys and export them:
   ```bash
   export KIMI_API_KEY=sk-...
   export GLM_API_KEY=...
   export MINIMAX_API_KEY=...
   export NVIDIA_API_KEY=...
   # etc.
   ```

2. Run against the cloud set:
   ```bash
   npx promptfoo@latest eval \
     -c evals/promptfoo/dot-compilation/promptfooconfig.yaml \
     --providers evals/promptfoo/dot-compilation/providers.cloud.yaml \
     --no-cache \
     -j 4 \
     -o .arbor/evals/promptfoo-runs/cloud-baseline-$(date +%Y%m%d).json
   ```

A ready-made `providers.cloud.yaml` is already present with the models you mentioned (Kimi, GLM, Minimax, Nemotron Super) plus examples for others. Most use standard OpenAI-compatible endpoints.

Strong cloud models (especially Kimi and the latest GLM/Qwen variants) are usually dramatically better than local models at:
- Strictly obeying "Output ONLY the DOT"
- Correct category classification
- Proper node granularity
- High-quality node prompts

Running them gives you the target quality level and immediately shows where the current prompt is too weak for smaller models.

## Adding a New Real Skill as a Test Case

1. Pick (or create) a `SKILL.md` in `.arbor/skills/...` or `.claude/skills/...`.
2. Add a test entry in `promptfooconfig.yaml` (or the sidecar jsonl + reference it).
3. For the first run, either:
   - Let a strong model (Claude Haiku / your best local) generate a candidate DOT, then review it by hand and paste as `expected_dot`, **or**
   - Write a minimal expected by hand (especially easy for "reference" category heartbeat skills).
4. Commit the test case + the `expected_dot` so future model upgrades are regression-tested.

Once you have real `COMPILED.dot` files checked into the skill directories, those become perfect ground truth.

## Comparison with the Old Framework

| Aspect                    | Old (`mix arbor.eval`)          | Promptfoo (this pilot)                  |
|---------------------------|----------------------------------|-----------------------------------------|
| LM Studio support         | Excellent (`--provider lm_studio --base-url`) | Trivial (4 lines of YAML)              |
| Structural DOT scoring    | `DotDiff` (Elixir, very good)   | JS port + real `mix validate` gate     |
| Reports                   | JSON in `.arbor/eval_runs/` + dashboard | Beautiful interactive HTML + JSON      |
| Assertions                | Limited set of graders          | JS/Python/exec/llm-rubric/embeddings   |
| Adding new skills         | Edit jsonl + re-run             | Edit YAML or sidecar; very ergonomic   |
| CI / GitHub               | Custom                           | Official GitHub Action + `promptfoo eval --ci` |
| History / model tracking  | Postgres + dashboard             | Files + you can still write summaries into `.arbor/` |

**Recommendation after the pilot:** keep both. Use promptfoo for rapid iteration and local model shopping; keep the old one for the persisted historical record and the nice LiveView dashboard.

## Tips & Gotchas

- **Temperature 0** is set in the config for determinism.
- Long-running local models: the `timeout: 120000` in the provider config + the assertion `timeout` in `validate-with-arbor.js` are intentionally generous.
- If `mix arbor.pipeline.validate` hangs or the server isn't running, the assertion will fail fast with a clear message.
- The JS scorer does **not** re-implement the full DOT parser — it relies on the validate gate having already passed. This is intentional.
- Want to run only the tiny reference tests for a 30-second smoke? Add `filter: "category=reference"` to the command or config.

## Next (planned in this pilot)

- Sufficiency summarizer script that emits a one-page Markdown verdict you can paste into `.arbor/decisions/`.
- One more non-DOT example eval (heartbeat JSON contract is the highest leverage).
- Optional thin `mix arbor.promptfoo` wrapper task.
- CI job example.

Run the eval on your actual LM Studio inventory, look at the numbers + the generated DOTs, and you will have a clear answer to the question "which (if any) of my local models are good enough for Arbor orchestrator skill compilation?"

Happy evalling.
