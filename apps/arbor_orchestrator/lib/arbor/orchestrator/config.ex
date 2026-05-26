defmodule Arbor.Orchestrator.Config do
  @moduledoc """
  Configuration accessors for `arbor_orchestrator`, following the per-library
  `Config` module convention (read from `Application.get_env/3` with safe defaults).

  ## Preprocessor pipeline

  The preprocessor runs before a turn's LLM call and attaches enrichment to the
  turn context under `session.preprocessor.*`. It is **disabled by default** and
  **fails open** (any stage error → the turn proceeds without preprocessing).

  See `docs/arbor/PREPROCESSOR.md` for the full feature description.

  ### Flags & config (all under `config :arbor_orchestrator`)

      config :arbor_orchestrator,
        preprocessor_enabled: false,
        preprocessor: [
          # per-stage model + provider. provider is :ollama | :lm_studio.
          needs_tools: [provider: :lm_studio, model: "gemma-4-e4b-it@q4_k_xl",
                        base_url: "http://localhost:1234/v1"],
          complexity:  [provider: :ollama, model: "granite4.1:3b",
                        base_url: "http://localhost:11434"],
          intent:      [provider: :ollama, model: "granite4.1:3b"],
          decompose:   [provider: :ollama, model: "granite4.1:3b", enabled: false],
          retrieval:   [provider: :ollama, model: "granite4:1b",
                        embed_model: "mxbai-embed-large", enabled: false,
                        index_path: nil, top_k: 5],
          # runtime-resolved gateway modules (avoids a compile-time cross-library dep)
          prompt_classifier: Arbor.Gateway.PromptClassifier,
          intent_extractor: Arbor.Gateway.IntentExtractor,
          timeout_ms: 30_000
        ]
  """

  @app :arbor_orchestrator

  @default_preprocessor [
    needs_tools: [
      provider: :lm_studio,
      model: "gemma-4-e4b-it@q4_k_xl",
      base_url: "http://localhost:1234/v1"
    ],
    complexity: [provider: :ollama, model: "granite4.1:3b", base_url: "http://localhost:11434"],
    intent: [provider: :ollama, model: "granite4.1:3b"],
    decompose: [provider: :ollama, model: "granite4.1:3b", enabled: false],
    retrieval: [
      provider: :ollama,
      model: "granite4:1b",
      embed_model: "mxbai-embed-large",
      enabled: false,
      index_path: nil,
      # Recall-oriented for injection: take the top-K *modules*, inject all their
      # actions. Order/p@1 doesn't matter (we inject the whole set), so a wider K
      # raises the chance the right tool is present (mxbai recall@5 ≈ 66%).
      top_k: 8
    ],
    prompt_classifier: Arbor.Gateway.PromptClassifier,
    intent_extractor: Arbor.Gateway.IntentExtractor,
    # Engine consumption: when tier == DIRECT, empty the tool list (no-tools fast
    # lane). Set false to keep DIRECT advisory-only as insurance against the
    # classifier's residual false-negatives.
    direct_skips_tools: true,
    timeout_ms: 30_000
  ]

  @doc "Whether the pre-turn preprocessor pipeline runs. Default: false (off)."
  @spec preprocessor_enabled?() :: boolean()
  def preprocessor_enabled? do
    Application.get_env(@app, :preprocessor_enabled, false)
  end

  @doc """
  Full preprocessor config (keyword list), merged over defaults so partial
  overrides in `config.exs` work without restating every key.
  """
  @spec preprocessor() :: keyword()
  def preprocessor do
    user = Application.get_env(@app, :preprocessor, [])
    deep_merge(@default_preprocessor, user)
  end

  @doc "Config for a single preprocessor stage (`:needs_tools`, `:complexity`, etc.)."
  @spec preprocessor_stage(atom()) :: keyword()
  def preprocessor_stage(stage) do
    Keyword.get(preprocessor(), stage, [])
  end

  # Shallow-deep merge: top-level keys merged; keyword-list values merged one level.
  defp deep_merge(defaults, overrides) do
    Keyword.merge(defaults, overrides, fn _k, d, o ->
      if Keyword.keyword?(d) and Keyword.keyword?(o), do: Keyword.merge(d, o), else: o
    end)
  end
end
