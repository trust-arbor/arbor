# Preprocessor Pipeline

The preprocessor runs **before** a turn's LLM call and attaches enrichment to the
turn context under `session.preprocessor.*`. It is **disabled by default** and
**fails open** — any stage error leaves the turn exactly as it would have run
without preprocessing.

It is the production landing of the eval work in
[`.arbor/roadmap/2-planned/preprocessor-pipeline-unification.md`](../../.arbor/roadmap/2-planned/preprocessor-pipeline-unification.md)
and [`.arbor/evals/preprocessor-tool-retrieval-2026-05-20.md`](../../.arbor/evals/preprocessor-tool-retrieval-2026-05-20.md).

## What it does

On each user turn, when enabled, `Arbor.Orchestrator.Preprocessor.run/2` runs:

| Stage | What it produces | Provider (default) |
|---|---|---|
| **sensitivity** | PII/secret scan → routing recommendation | `Arbor.Gateway.PromptClassifier` (runtime-resolved) |
| **needs_tools** | boolean: does this need tools, or a pure conversational answer? (the effort-tier gate) | LM Studio, `gemma-4-e4b-it@q4_k_xl` |
| **complexity** | SIMPLE / MULTI_STEP / NON_ACTIONABLE (actionable turns only) | Ollama, `granite4.1:3b` |
| **intent** | goal / risk_level (actionable turns only) | `Arbor.Gateway.IntentExtractor` (runtime-resolved) |
| **tier** | DERIVED: see below | — |

**Tier derivation** (not asked of any model — computed from the two reliable signals):

- `needs_tools == false` → **DIRECT** (no tools; conversational fast lane)
- `needs_tools == true` + SIMPLE → **STANDARD** (one bounded action)
- `needs_tools == true` + MULTI_STEP or NON_ACTIONABLE → **DEEP** (multi-step / investigation)

Optional, config-gated sub-stages (default **off**, need an action index): **decompose**
(MULTI_STEP → sub-requests) and **retrieval** (JIT tool injection).

### Why these models

Chosen by eval against a 145-prompt corpus of real prompts (see the design doc).
`gemma-4-e4b-it@q4` won the `needs_tools` judgment: 93.1% accuracy, 10 false-negatives,
0 false-positives — vs Granite 3B's 21 false-negatives (2× the dangerous misses).
There's a capability threshold around effective-4b: smaller models (Granite 3B, Gemma
e2b) spike false-negatives. Revisit when newer/faster models land — it's a one-line config swap.

## Enable / disable

Disabled by default. To enable, in `config/config.exs` (or an env-specific config):

```elixir
config :arbor_orchestrator, preprocessor_enabled: true
```

To disable again, set it back to `false` (or remove the line). When disabled,
`Preprocessor.run/2` returns `{:ok, %{}}` and the turn path is byte-for-byte unchanged.

**Enabling requires the configured providers to be reachable** — by default Ollama on
`localhost:11434` (complexity/intent) and LM Studio on `localhost:1234` (needs_tools),
with the named models pulled/loaded. If a provider is unreachable, that stage fails
open: `needs_tools` fails **safe** (assumes `true` → no wrongful fast-lane skip), other
stages degrade to a sensible default and the turn proceeds.

## Configuration options

All under `config :arbor_orchestrator, :preprocessor`. Partial overrides are merged
over defaults, so you only restate what you change.

```elixir
config :arbor_orchestrator, :preprocessor,
  # needs_tools — the effort-tier gate (the locked winner)
  needs_tools: [
    provider: :lm_studio,                  # :lm_studio | :ollama
    model: "gemma-4-e4b-it@q4_k_xl",
    base_url: "http://localhost:1234/v1"   # LM Studio OpenAI-compatible base
  ],

  # complexity — SIMPLE / MULTI_STEP / NON_ACTIONABLE
  complexity: [
    provider: :ollama,
    model: "granite4.1:3b",
    base_url: "http://localhost:11434"
  ],

  # intent — gateway IntentExtractor; provider/model passed through to it
  intent: [provider: :ollama, model: "granite4.1:3b"],

  # decompose — MULTI_STEP → sub-requests (OPTIONAL, default off)
  decompose: [provider: :ollama, model: "granite4.1:3b", enabled: false],

  # retrieval — JIT tool injection (OPTIONAL, default off; needs an action index)
  retrieval: [
    provider: :ollama,
    model: "granite4:1b",              # reranker
    embed_model: "mxbai-embed-large",  # recall stage
    enabled: false,
    index_path: nil,                   # path to the action index json
    top_k: 5
  ],

  # Gateway modules resolved at RUNTIME (no compile-time cross-library dep).
  # Override for testing or to swap implementations.
  prompt_classifier: Arbor.Gateway.PromptClassifier,
  intent_extractor: Arbor.Gateway.IntentExtractor,

  timeout_ms: 30_000
```

### Provider values

- `:ollama` — calls `<base_url>/api/chat` with `format: "json"`, `think: false`.
  Default base `http://localhost:11434`.
- `:lm_studio` — calls `<base_url>/chat/completions` with a `json_schema` response
  format; reads `content`, falling back to `reasoning_content` for reasoning models.
  Default base `http://localhost:1234/v1`.

## What the turn sees

When enabled, these keys are merged into the turn context (string keys, namespaced):

```
session.preprocessor.enabled       => true
session.preprocessor.sensitivity   => %{"level" => "...", "routing" => "..."} | nil
session.preprocessor.needs_tools   => true | false
session.preprocessor.tier          => "DIRECT" | "STANDARD" | "DEEP"
session.preprocessor.complexity    => "SIMPLE" | "MULTI_STEP" | "NON_ACTIONABLE"   # actionable only
session.preprocessor.intent        => %{"goal" => "...", "risk_level" => "..."} | nil  # actionable only
```

DIRECT turns carry only `enabled`, `sensitivity`, `needs_tools`, `tier` (complexity/intent
are skipped — that's the fast lane).

## Engine consumption (what the turn does with the output)

The turn consumes the preprocessor via `session.tools`: `LlmHandler.resolve_tools/3`
reads `context["session.tools"]` first, so overriding it controls exactly which tools
the LLM call sees. The decision is the pure function `Preprocessor.tool_override/2`,
applied in `Session.maybe_preprocess/2`:

1. **Retrieved tools (JIT injection)** — if the preprocessor produced a `retrieved_tools`
   list, the turn uses *exactly* that subset. **Implemented** (config-gated, default off).
   The `retrieval` stage embeds the prompt (mxbai), takes the top-K modules by cosine
   similarity, and expands each to its action names via the runtime action registry
   (`Arbor.Actions.all_actions/0` + `action_module_to_name/1`) — e.g. retrieved
   `Arbor.Actions.File` → `["file.read", "file.write", ...]` (dot-form names the resolver
   accepts). Recall-oriented (top-K *modules*, all their actions injected) since the
   agent just needs the right tool present in the set, not ranked first.
2. **DIRECT fast lane** — `tier == "DIRECT"` empties the tool list (`session.tools = []`),
   so the LLM answers directly with no tool loop. Toggle with `direct_skips_tools`
   (default `true`).
3. **STANDARD / DEEP** — no override; normal trust-tier-based tool resolution.

### Soft-signal caveat (why DIRECT is toggleable)

`gemma` has ~10 residual false-negatives on the eval corpus — DIRECT-when-actually-tool-needed.
With `direct_skips_tools: true`, those turns would run tool-less and could fail the task.
That's an accepted risk while the feature is experimental/opt-in. Set
`direct_skips_tools: false` to keep DIRECT *advisory* (attached to context but not acting
on tools) — the conservative setting that treats the tier as a soft signal.

### Enabling retrieval

```elixir
config :arbor_orchestrator, preprocessor_enabled: true
config :arbor_orchestrator, :preprocessor, retrieval: [enabled: true]
```

With it on, actionable turns get `session.preprocessor.retrieved_tools` (action names)
and the turn's `session.tools` is narrowed to that set. Needs the embed model
(`mxbai-embed-large`) reachable and the action index present (defaults to the
eval index under `priv/eval_datasets/...`). Retrieval quality is the eval-measured
embedding recall (~66% recall@5); noisy entries from internal action modules can appear
in the injected set — harmless (extra tools), but a cleaner production index or hybrid
LLM rerank would tighten it.

## Still not done

- **Production action index** — currently defaults to the eval index (built from action
  moduledocs). A purpose-built production index (excluding internal/meta actions) would
  cut retrieval noise. Hybrid LLM rerank (the eval's Path 3 winner, 62% p@1) is the
  quality upgrade if recall-only proves insufficient.
- **Decompose consumption** (MULTI_STEP → sub-requests routed/executed separately).
- Acting on tier beyond tools (e.g., skipping the LLM entirely on a pure-chitchat DIRECT,
  or enabling verification execution on DEEP).

## Architecture notes

- `arbor_orchestrator` does not depend on `arbor_gateway`/`arbor_ai` at compile time
  (library hierarchy). Gateway modules are resolved at **runtime**
  (`Code.ensure_loaded?` + `function_exported?`), so there's no cross-library compile
  dependency. LLM calls use `Req` (external) directly to Ollama / LM Studio.
- **Fail-open everywhere.** `Preprocessor.run/2` never returns `{:error, _}`; the Session
  integration (`maybe_preprocess/2`) also rescues, so a preprocessor failure can never
  break a turn.
- **Per-stage config** means each stage's model/provider is independent and hot-swappable
  via config without touching code.

## Files

- `apps/arbor_orchestrator/lib/arbor/orchestrator/preprocessor.ex` — the pipeline
- `apps/arbor_orchestrator/lib/arbor/orchestrator/config.ex` — flag + config accessors
- `apps/arbor_orchestrator/lib/arbor/orchestrator/session.ex` — integration (`maybe_preprocess/2`, called in `do_send_message_async/3`)
- `config/config.exs` — default (disabled) config block
