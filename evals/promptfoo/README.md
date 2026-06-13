# Promptfoo evals — Layer 1 (task-level model/prompt selection)

Per `.arbor/roadmap/1-brainstorming/eval-system-architecture.md`: every LLM task that
reduces to "render prompt → call model → assert on output" is evaluated here with
promptfoo. Arbor-in-the-loop evals (memory ablations, agent-turn e2e, engine evals) do
NOT belong here — those are Layer 2 (`mix arbor.eval` / eval-as-DOT).

## Conventions

- **One directory per task**, named after the task inventory id
  (`.arbor/roadmap/1-brainstorming/llm-task-inventory-and-model-selection.md`):
  `evals/promptfoo/<task>/promptfooconfig.yaml` + dataset + README with provenance.
- **Provider identity includes endpoint + quant.** Same model can behave differently
  across serving layers (2026-05-26: Ollama granite quant collapsed on needs_tools;
  LM Studio granite scored 15/16). Always use distinct labeled providers per
  (model, quant, endpoint). Shared provider definitions: `providers/`.
- **Sensitive task corpora use local-only providers.** No cloud provider entries in
  configs for tasks marked sensitive in the inventory.
- **Telemetry off:** `export PROMPTFOO_DISABLE_TELEMETRY=1` (also in `.env.example`).
- **Results feed the EvalRun store.** Run with `-o results.json`, then import (importer
  `mix arbor.eval.import_promptfoo` — planned, eval-system-architecture step 4) so
  task-level results are queryable alongside Layer 2 runs. Until the importer exists,
  commit the results JSON next to the config with the run-identity facts (git sha,
  model+quant+provider, dataset hash) in the filename or a sidecar note.

## Running

```bash
cd evals/promptfoo/<task>
npx promptfoo@latest eval -c promptfooconfig.yaml -o results.json
npx promptfoo@latest view   # diff UI
```

## Tasks

| Task | Status |
|---|---|
| `needs-tools/` | scaffold — corpus port from personal scripts pending (see its README) |
| `dot-compilation/` | providers file only (original vestigial attempt); config TODO |
