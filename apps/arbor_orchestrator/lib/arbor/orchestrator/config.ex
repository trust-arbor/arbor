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
    # intent (goal/risk_level) is the slowest stage and currently unconsumed —
    # gated off by default. Enable once a downstream consumer reads it.
    intent: [provider: :ollama, model: "granite4.1:3b", enabled: false],
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

  # ===========================================================================
  # Security / Authorization policy (fail-closed by default)
  # ===========================================================================

  @doc """
  Whether the orchestrator requires the security subsystem to be available for
  `arbor://orchestrator/execute` gate checks (once-per-turn and per-node).

  When true (default): if Arbor.Security or CapabilityStore is unavailable,
  authorization gates return `{:error, :security_unavailable}` (fail-closed).

  Set to false ONLY for intentional standalone deployments without
  arbor_security. Not recommended for production agents.
  """
  @spec security_required?() :: boolean()
  def security_required? do
    Application.get_env(@app, :security_required, true)
  end

  @doc """
  Test-only override for security availability detection.

  When set to a boolean, bypasses the real Code.ensure_loaded?/whereis check.
  Used by security regression tests to simulate CapabilityStore or security
  app being down, without mutating global processes/ETS.

  Default: nil (use real detection).
  """
  @spec security_available_override() :: boolean() | nil
  def security_available_override do
    Application.get_env(@app, :security_available_override, nil)
  end

  @doc """
  Runtime check: is the security subsystem (CapabilityStore process) available
  right now? Respects `security_available_override/0` for tests.

  arbor_security is a hard dep so the module is always loaded; this is a pure
  process-liveness check on the CapabilityStore (the subsystem can be down even
  when the code is present — e.g. standalone slices or boot ordering).
  """
  @spec security_available?() :: boolean()
  def security_available? do
    case security_available_override() do
      nil ->
        Process.whereis(Arbor.Security.CapabilityStore) != nil

      bool when is_boolean(bool) ->
        bool
    end
  end

  # ===========================================================================
  # Timeouts (prevent indefinite hangs)
  # ===========================================================================

  @default_turn_timeout_ms 300_000

  @doc """
  Timeout (ms) for the GenServer.call inside Session.send_message/2 and
  related entry points.

  Replaces previous :infinity (which allowed callers to hang forever if the
  engine or LLM stalled). Default 5 minutes is generous for LLM+tool turns;
  configure higher only for specialized long-running workloads.

  On timeout the caller receives a timeout exit from GenServer.call, but
  Session monitors the caller and clears in-flight state so subsequent turns
  are not blocked.
  """
  @spec turn_timeout_ms() :: pos_integer()
  def turn_timeout_ms do
    Application.get_env(@app, :turn_timeout_ms, @default_turn_timeout_ms)
  end

  # ===========================================================================
  # Context size budgets (runaway protection, not workload limits)
  # ===========================================================================

  @default_context_budgets %{
    # Max distinct keys in a single pipeline's Context. A real pipeline has
    # dozens to hundreds. This bound catches runaway accumulation (e.g., an
    # exec action that JSON-spreads a 100k-key result into context).
    max_keys: 100_000,
    # Max bytes of a single value (via :erlang.external_size/1).
    # 10MB covers oversized LLM responses, attached files, large log blobs.
    max_value_bytes: 10_000_000,
    # Max total bytes across all context values.
    max_total_bytes: 100_000_000
  }

  @doc """
  Context-size budgets enforced by `Arbor.Orchestrator.Engine.Context`.

  Returns a map with `:max_keys`, `:max_value_bytes`, `:max_total_bytes`.
  Defaults are runaway-protection bounds, not workload limits — no
  legitimate pipeline should approach them. Override per-env via
  `config :arbor_orchestrator, :context_budgets, %{...}`.
  """
  @spec context_budgets() :: %{
          max_keys: pos_integer(),
          max_value_bytes: pos_integer(),
          max_total_bytes: pos_integer()
        }
  def context_budgets do
    user = Application.get_env(@app, :context_budgets, %{})
    Map.merge(@default_context_budgets, user)
  end

  @doc """
  How to react when a budget is exceeded: `:warn` (Logger.warning, proceed)
  or `:error` (return error, fail the write). Default `:warn` — the
  observability-first phase. Flip to `:error` per-env once operators
  understand which pipelines are noisy and have pruned them.
  """
  @spec context_budget_enforcement() :: :warn | :error
  def context_budget_enforcement do
    Application.get_env(@app, :context_budget_enforcement, :warn)
  end
end
