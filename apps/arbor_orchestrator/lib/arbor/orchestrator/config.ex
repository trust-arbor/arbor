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
          # Per-stage model + provider (provider is :ollama | :lm_studio) and a
          # uniform `enabled:` toggle. Consolidated onto LM Studio + one model.
          needs_tools: [provider: :lm_studio, model: "gemma-4-e4b-it-qat",
                        base_url: "http://localhost:1234/v1", max_tokens: 200],
          complexity:  [provider: :lm_studio, model: "gemma-4-e4b-it-qat",
                        base_url: "http://localhost:1234/v1", max_tokens: 1024],
          intent:      [provider: :lm_studio, model: "gemma-4-e4b-it-qat", enabled: false],
          decompose:   [provider: :lm_studio, model: "gemma-4-e4b-it-qat", enabled: false],
          retrieval:   [provider: :lm_studio, embed_model: "mxbai-embed-large-v1",
                        base_url: "http://localhost:1234/v1", enabled: false,
                        index_path: nil, top_k: 8],
          # runtime-resolved gateway modules (avoids a compile-time cross-library dep)
          prompt_classifier: Arbor.Gateway.PromptClassifier,
          intent_extractor: Arbor.Gateway.IntentExtractor,
          timeout_ms: 30_000
        ]

  Every stage honors `enabled:` (under the master `preprocessor_enabled?`).
  Defaults preserve historical behavior: sensitivity/needs_tools/complexity on,
  intent/retrieval off.
  """

  @app :arbor_orchestrator

  # Consolidated onto LM Studio (one provider, one model) for accessibility — users
  # without multi-model VRAM run the whole preprocessor on a single ~4.2GB model.
  # `gemma-4-e4b-it-qat` won the 2026-06-25 sweep: lowest false-negatives on the
  # needs_tools gate (4 vs granite's 18-20) AND clears complexity MULTI_STEP recall.
  @default_preprocessor [
    needs_tools: [
      provider: :lm_studio,
      model: "gemma-4-e4b-it-qat",
      base_url: "http://localhost:1234/v1",
      max_tokens: 200
    ],
    # Same model; generous token budget (the 3-way judgment reasons more than the
    # binary gate — too tight a budget truncates mid-reasoning → empty output).
    complexity: [
      provider: :lm_studio,
      model: "gemma-4-e4b-it-qat",
      base_url: "http://localhost:1234/v1",
      max_tokens: 1024
    ],
    # intent (goal/risk_level) is the slowest stage and currently unconsumed —
    # gated off by default. Enable once a downstream consumer reads it.
    intent: [provider: :lm_studio, model: "gemma-4-e4b-it-qat", enabled: false],
    decompose: [provider: :lm_studio, model: "gemma-4-e4b-it-qat", enabled: false],
    retrieval: [
      provider: :lm_studio,
      embed_model: "mxbai-embed-large-v1",
      base_url: "http://localhost:1234/v1",
      enabled: false,
      index_path: nil,
      # NOTE before enabling: the committed action index was embedded with the
      # Ollama mxbai model; rebuild it with this LM Studio embed model (same
      # embedding space) or cosine scores are meaningless.
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

  @doc """
  The security module used for capability authorization (must expose
  `authorize/4`). Defaults to `Arbor.Security`; overridable via the
  `:security_module` app env for testing / dependency injection. Production
  should leave it unset.
  """
  @spec security_module() :: module()
  def security_module do
    Application.get_env(@app, :security_module, Arbor.Security)
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

  # ===========================================================================
  # Coding task pipeline (TaskExecutor seam)
  # ===========================================================================

  @coding_pipeline_relpath "pipelines/coding-change-v1.dot"
  @default_coding_pipeline_runner Arbor.Orchestrator
  @default_pipeline_status_module Arbor.Orchestrator.PipelineStatus
  @default_coding_task_control_facade Arbor.AI

  @doc """
  Absolute path to the packaged coding-change-v1 DOT graph.

  Defaults to `:code.priv_dir(:arbor_orchestrator)/pipelines/coding-change-v1.dot`.
  Overridable via `:coding_pipeline_path` for tests or alternate packaging.
  """
  @spec coding_pipeline_path() :: String.t()
  def coding_pipeline_path do
    case Application.get_env(@app, :coding_pipeline_path) do
      path when is_binary(path) and path != "" ->
        path

      _ ->
        default_coding_pipeline_path()
    end
  end

  @doc """
  Module used to run the coding pipeline graph (`run_file/2`).

  Defaults to `Arbor.Orchestrator`. Tests may inject a fake runner that
  captures opts without executing the Engine.
  """
  @spec coding_pipeline_runner() :: module()
  def coding_pipeline_runner do
    Application.get_env(@app, :coding_pipeline_runner, @default_coding_pipeline_runner)
  end

  @doc """
  Base directory for coding-task pipeline manifests, status, and checkpoints.

  `Arbor.Orchestrator.CodingTaskExecutor` creates a deterministic, path-safe
  child directory for each task. Defaults to a dedicated directory under the
  system temporary directory.
  """
  @spec coding_pipeline_logs_root() :: String.t()
  def coding_pipeline_logs_root do
    case Application.get_env(@app, :coding_pipeline_logs_root) do
      path when is_binary(path) ->
        case String.trim(path) do
          "" -> default_coding_pipeline_logs_root()
          configured -> Path.expand(configured)
        end

      _ ->
        default_coding_pipeline_logs_root()
    end
  end

  @doc """
  Explicit trusted roots that may contain repositories for structured coding
  tasks. Missing or malformed configuration has no fallback and is rejected by
  `CodingTaskExecutor` before it invokes the pipeline.
  """
  @spec coding_repo_roots() ::
          {:ok, [String.t()]}
          | {:error, {:coding_roots_not_configured | :invalid_coding_roots, :repo}}
  def coding_repo_roots do
    configured_coding_roots(:coding_repo_roots, :repo)
  end

  @doc """
  Explicit trusted roots under which structured coding tasks may create Git
  worktrees. The executor uses the first canonical root when a task omits
  `worktree_base_dir`.
  """
  @spec coding_worktree_roots() ::
          {:ok, [String.t()]}
          | {:error, {:coding_roots_not_configured | :invalid_coding_roots, :worktree}}
  def coding_worktree_roots do
    configured_coding_roots(:coding_worktree_roots, :worktree)
  end

  @doc """
  Facade used for pipeline progress/cancel bookkeeping (`get/1`,
  `mark_abandoned/1`). Defaults to `Arbor.Orchestrator.PipelineStatus`.
  """
  @spec pipeline_status_module() :: module()
  def pipeline_status_module do
    Application.get_env(@app, :pipeline_status_module, @default_pipeline_status_module)
  end

  @doc """
  Public facade used to deliver coding-task controls to managed ACP sessions.

  Defaults to `Arbor.AI`, whose task-control API resolves exclusively by task
  and principal. Tests may inject a narrow facade implementing
  `acp_managed_deliver_task_control/4`.
  """
  @spec coding_task_control_facade() :: module()
  def coding_task_control_facade do
    Application.get_env(
      @app,
      :coding_task_control_facade,
      @default_coding_task_control_facade
    )
  end

  defp default_coding_pipeline_path do
    candidates =
      case :code.priv_dir(@app) do
        path when is_list(path) ->
          [Path.join(to_string(path), @coding_pipeline_relpath)]

        _ ->
          []
      end ++
        [
          Path.expand("apps/arbor_orchestrator/priv/#{@coding_pipeline_relpath}"),
          Path.expand("priv/#{@coding_pipeline_relpath}")
        ]

    Enum.find(candidates, List.first(candidates), &File.exists?/1)
  end

  defp default_coding_pipeline_logs_root do
    Path.join([System.tmp_dir!(), "arbor_orchestrator", "coding_tasks"])
  end

  defp configured_coding_roots(key, kind) do
    case Application.fetch_env(@app, key) do
      :error ->
        {:error, {:coding_roots_not_configured, kind}}

      {:ok, roots} when is_list(roots) and roots != [] ->
        normalize_configured_roots(roots, kind)

      {:ok, _invalid} ->
        {:error, {:invalid_coding_roots, kind}}
    end
  end

  defp normalize_configured_roots(roots, kind) do
    Enum.reduce_while(roots, {:ok, []}, fn root, {:ok, acc} ->
      case normalize_configured_root(root) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        :error -> {:halt, {:error, {:invalid_coding_roots, kind}}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, normalized |> Enum.reverse() |> Enum.uniq()}
      {:error, _} = error -> error
    end
  end

  defp normalize_configured_root(root) when is_binary(root) do
    if String.valid?(root) do
      trimmed = String.trim(root)

      if trimmed != "" and Path.type(trimmed) == :absolute and Path.expand(trimmed) != "/" do
        {:ok, trimmed}
      else
        :error
      end
    else
      :error
    end
  end

  defp normalize_configured_root(_root), do: :error
end
