defmodule Arbor.AI do
  @moduledoc """
  Unified LLM interface for Arbor.

  Provides a simple facade for text generation. All LLM calls are routed
  through the orchestrator's UnifiedLLM layer — CLI and API providers are
  unified. `claude_cli` is just another provider, same as `anthropic` or `openai`.

  ## Quick Start

      # Generate text with default settings
      {:ok, result} = Arbor.AI.generate_text("What is 2+2?")
      result.text
      #=> "2+2 equals 4."

      # Use a specific provider (CLI or API — doesn't matter)
      {:ok, result} = Arbor.AI.generate_text("Hello", provider: :claude_cli)
      {:ok, result} = Arbor.AI.generate_text("Hello", provider: :anthropic)
      {:ok, result} = Arbor.AI.generate_text("Hello", provider: :ollama)

      # With custom options
      {:ok, result} = Arbor.AI.generate_text(
        "Analyze this code for security issues.",
        system_prompt: "You are a security reviewer.",
        max_tokens: 2048,
        temperature: 0.3
      )

  ## Configuration

  Configure defaults in your config:

      config :arbor_ai,
        default_provider: :anthropic,
        default_model: "claude-sonnet-4-5-20250514",
        timeout: 60_000

  API keys are loaded from environment variables:

      ANTHROPIC_API_KEY=sk-ant-...
      OPENAI_API_KEY=sk-...
  """

  @behaviour Arbor.Contracts.API.AI
  @behaviour Arbor.Contracts.API.Embedding

  alias Arbor.AI.{
    AcpSession,
    Backends.OllamaEmbedding,
    Backends.OpenAIEmbedding,
    Backends.TestEmbedding,
    BudgetTracker,
    Config,
    LLMTrace,
    SessionReader,
    SystemPromptBuilder,
    ToolSignals,
    UnifiedBridge,
    UsageStats
  }

  # Note: Arbor.Memory.* and Arbor.Actions are higher in the hierarchy than arbor_ai (Standalone).
  # All calls use Code.ensure_loaded?/apply to avoid compile-time dependency.

  require Logger

  @eval_subjects %{
    "embedding_retrieval" => Arbor.AI.Eval.Subjects.EmbeddingRetrieval,
    "llm_router" => Arbor.AI.Eval.Subjects.LLMRouter,
    "hybrid_retrieval" => Arbor.AI.Eval.Subjects.HybridRetrieval
  }

  @eval_graders %{
    "embedding_similarity" => Arbor.AI.Eval.Graders.EmbeddingSimilarity,
    "intent_conformance" => Arbor.AI.Eval.Graders.IntentConformance
  }

  @doc """
  Resolves an AI-owned evaluation subject from its closed symbolic catalog.

  Unknown values return `nil`; this function never interns atoms or resolves
  module names dynamically.
  """
  @spec eval_subject(term()) :: module() | nil
  def eval_subject(name) when is_binary(name), do: Map.get(@eval_subjects, name)
  def eval_subject(_name), do: nil

  @doc "Returns all registered AI-owned eval subject symbolic names."
  @spec eval_subject_names() :: [String.t()]
  def eval_subject_names, do: Map.keys(@eval_subjects)

  @doc """
  Resolves an AI-owned evaluation grader from its closed symbolic catalog.

  Unknown values return `nil`; this function never interns atoms or resolves
  module names dynamically.
  """
  @spec eval_grader(term()) :: module() | nil
  def eval_grader(name) when is_binary(name), do: Map.get(@eval_graders, name)
  def eval_grader(_name), do: nil

  @doc "Returns all registered AI-owned eval grader symbolic names."
  @spec eval_grader_names() :: [String.t()]
  def eval_grader_names, do: Map.keys(@eval_graders)
  # ── Authorized API (for agent callers) ──

  @doc """
  Generate text with authorization check.

  Verifies the agent has the `arbor://ai/request/{provider}` capability before
  making the LLM request. Use this for agent-initiated AI requests where
  authorization should be enforced.

  This protects against unauthorized data exfiltration (prompts sent to external APIs)
  and cost overruns (paid API calls).

  ## Parameters

  - `agent_id` - The agent's ID for capability lookup
  - `prompt` - The prompt to send to the LLM
  - `opts` - Options passed to `generate_text/2`, plus:
    - `:trace_id` - Optional trace ID for correlation
    - `:provider` - Provider to use (determines capability URI), default: "auto"

  ## Returns

  - `{:ok, result}` on success (same as `generate_text/2`)
  - `{:error, {:unauthorized, reason}}` if agent lacks the required capability
  - `{:ok, :pending_approval, proposal_id}` if escalation needed
  - `{:error, reason}` on other errors
  """
  @spec authorize_generate(String.t(), String.t(), keyword()) ::
          {:ok, map()}
          | {:ok, :pending_approval, String.t()}
          | {:error, {:unauthorized, term()} | term()}
  def authorize_generate(agent_id, prompt, opts \\ []) do
    with_llm_deadline(opts, Config.timeout(), fn opts, _timeout ->
      do_authorize_generate(agent_id, prompt, opts)
    end)
  end

  defp do_authorize_generate(agent_id, prompt, opts) do
    provider = extract_provider(opts)
    resource = "arbor://ai/request/#{provider}"
    {trace_id, opts} = Keyword.pop(opts, :trace_id)

    case Arbor.Security.authorize(agent_id, resource, :request,
           trace_id: trace_id,
           verify_identity: false
         ) do
      {:ok, :authorized} ->
        generate_text(prompt, opts)

      {:ok, :pending_approval, proposal_id} ->
        {:ok, :pending_approval, proposal_id}

      {:error, reason} ->
        {:error, {:unauthorized, reason}}
    end
  end

  # Extract provider from opts for capability URI
  defp extract_provider(opts) do
    case Keyword.get(opts, :provider) do
      nil -> "auto"
      provider when is_atom(provider) -> Atom.to_string(provider)
      provider when is_binary(provider) -> provider
    end
  end

  # ── Unchecked API (for system callers) ──

  @impl true
  @spec generate_text(String.t(), keyword()) ::
          {:ok, Arbor.Contracts.API.AI.result()} | {:error, term()}
  def generate_text(prompt, opts \\ []) do
    with_llm_deadline(opts, Config.timeout(), fn opts, _timeout ->
      opts = snapshot_config(opts)
      provider = Keyword.fetch!(opts, :provider)
      model = Keyword.fetch!(opts, :model)
      agent_id = Keyword.get(opts, :agent_id)

      trace = LLMTrace.start(:generate_text, provider, model, agent_id, prompt)
      result = UnifiedBridge.generate_text(prompt, opts)
      LLMTrace.finish(trace, result)
      result
    end)
  end

  @doc """
  Stream text generation with optional real-time event callbacks.

  By default, collects the stream and returns the same response format as
  `generate_text/2`. Pass `collect: false` to get a lazy stream enumerable.

  ## Additional Options (beyond `generate_text/2`)

  - `:on_event` — callback `(StreamEvent.t() -> any())` invoked per event.
    Use this for real-time UI updates, TTFT measurement, or logging.
  - `:collect` — if `true` (default), consumes stream and returns response.
    If `false`, returns `{:ok, stream_enumerable}` for lazy consumption.

  ## Examples

      # Collected (same return shape as generate_text)
      {:ok, response} = Arbor.AI.stream_text("hello", provider: :openrouter, model: "...")

      # With event callback for real-time observation
      {:ok, response} = Arbor.AI.stream_text("hello",
        provider: :openrouter, model: "...",
        on_event: fn event -> IO.write(event.data["text"] || "") end
      )

      # Lazy stream for manual consumption
      {:ok, stream} = Arbor.AI.stream_text("hello",
        provider: :openrouter, model: "...",
        collect: false
      )
  """
  @spec stream_text(String.t(), keyword()) :: {:ok, map() | Enumerable.t()} | {:error, term()}
  def stream_text(prompt, opts \\ []) do
    with_llm_deadline(opts, Config.timeout(), fn opts, _timeout ->
      opts = snapshot_config(opts)
      UnifiedBridge.generate_text_stream(prompt, opts)
    end)
  end

  @doc """
  Generate text using the API backend with tool/action support.

  Uses jido_ai's CallWithTools for an agentic loop where the LLM receives
  Arbor.Actions as tools, can call them, and loops until a final answer.

  Wraps with arbor infrastructure: signals, budget tracking, usage stats.

  ## Options

  - `:provider` - LLM provider atom (e.g. `:openrouter`, `:zai_coding_plan`)
  - `:model` - Model string (e.g. `"openai/gpt-oss-120b:free"`)
  - `:system_prompt` - Optional system prompt
  - `:max_tokens` - Max tokens (default: 4096)
  - `:temperature` - Sampling temperature (default: 0.7)
  - `:auto_execute` - Auto-execute tool calls (default: true)
  - `:max_turns` - Max tool-use turns (default: 10)
  - `:tools` - List of Jido.Action modules (default: Arbor.Actions.all_actions())
  - `:agent_id` - Agent ID for memory/action context (required for memory tools)
  - `:context` - Additional context map merged into tool execution context
  """
  @spec generate_text_with_tools(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def generate_text_with_tools(prompt, opts \\ []) do
    with_llm_deadline(opts, 600_000, fn opts, _timeout ->
      do_generate_text_with_tools(prompt, opts)
    end)
  end

  defp do_generate_text_with_tools(prompt, opts) do
    # SECURITY: Snapshot config at entry point to prevent TOCTOU race.
    opts = snapshot_config(opts)

    provider = Keyword.fetch!(opts, :provider)
    model = Keyword.fetch!(opts, :model)

    # ACP providers handle tool calling on the CLI agent side
    if provider == :acp do
      start_time = System.monotonic_time(:millisecond)
      ToolSignals.emit_started(provider, model, String.length(prompt))
      fallback_via_unified_bridge(prompt, opts, start_time, provider, model)
    else
      generate_with_tool_loop(prompt, provider, model, opts)
    end
  end

  # Route all tool-calling through UnifiedLLM's ToolLoop.
  # Single path: Client → ToolLoop → provider adapters. No fallbacks.
  defp generate_with_tool_loop(prompt, provider, model, opts) do
    agent_id = Keyword.get(opts, :agent_id)

    trace = LLMTrace.start(:generate_with_tools, provider, model, agent_id, prompt)
    ToolSignals.emit_started(provider, model, String.length(prompt))
    start_time = System.monotonic_time(:millisecond)

    # Auto-build rich system prompt if none provided
    system_prompt =
      case Keyword.get(opts, :system_prompt) do
        nil -> if agent_id, do: build_rich_system_prompt(agent_id, opts), else: nil
        p -> p
      end

    # Get the UnifiedLLM client and build request. arbor_llm is a direct dep,
    # so these are compile-time references — no runtime bridge needed.
    client = Arbor.LLM.Client.default_client()

    # Build messages
    messages =
      case system_prompt do
        nil ->
          [Arbor.LLM.Message.new(:user, prompt)]

        sys ->
          [Arbor.LLM.Message.new(:system, sys), Arbor.LLM.Message.new(:user, prompt)]
      end

    request =
      struct!(Arbor.LLM.Request, %{
        provider: to_string(provider),
        model: model,
        messages: messages,
        max_tokens: Keyword.get(opts, :max_tokens, 16_384),
        temperature: Keyword.get(opts, :temperature, 0.7),
        top_p: Keyword.get(opts, :top_p),
        provider_options: Keyword.get(opts, :provider_options) || %{},
        # Slow local reasoning models (e.g. qwen3.5-122b-a10b-mtp) spend 3-5 min in a hidden reasoning
        # channel before emitting content. Without a generous HTTP receive_timeout, ReqLLM's short
        # default cuts them off mid-generation → EMPTY content on the heaviest-reasoning runs (the
        # qwen-122b ~25% empty-content issue, 2026-07-05). The LlmHandler/DOT path already sets this
        # (e5096925); generate_text_with_tools — the path the eval agent + tool-callers use — did not.
        # Honor the caller's :receive_timeout / :timeout, else default to 10 min.
        receive_timeout: Keyword.fetch!(opts, :timeout_ms)
      })

    # ToolLoop options
    tool_loop_opts = [
      max_turns: Keyword.get(opts, :max_turns, 10),
      agent_id: agent_id || "system",
      signer: Keyword.get(opts, :signer),
      on_tool_call: Keyword.get(opts, :on_tool_call),
      timeout_ms: Keyword.fetch!(opts, :timeout_ms)
    ]

    # Run ToolLoop — single path through UnifiedLLM
    case Arbor.LLM.ToolLoop.run(client, request, tool_loop_opts) do
      {:ok, response} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time

        result = %{
          text: response.content,
          thinking: nil,
          usage: response.usage,
          model: model,
          provider: to_string(provider),
          tool_calls: response.tool_history,
          tool_rounds: response.tool_rounds,
          type: :tool_loop
        }

        ToolSignals.emit_completed(provider, model, duration_ms, result)
        ToolSignals.record_budget_usage(provider, opts, result)
        ToolSignals.record_usage_success(provider, opts, result, duration_ms)
        LLMTrace.finish(trace, {:ok, result})
        {:ok, result}

      {:error, reason} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        ToolSignals.emit_failed(provider, model, reason)
        ToolSignals.record_usage_failure(provider, opts, reason, duration_ms)
        LLMTrace.finish(trace, {:error, reason})
        {:error, reason}
    end
  end

  # ACP fallback: route through UnifiedBridge directly (no Jido.AI).
  # ACP CLI agents handle tool calling internally.
  defp fallback_via_unified_bridge(prompt, opts, start_time, provider, model) do
    case UnifiedBridge.generate_text(prompt, opts) do
      {:ok, response} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        ToolSignals.emit_completed(provider, model, duration_ms, response)
        ToolSignals.record_budget_usage(provider, opts, response)
        ToolSignals.record_usage_success(provider, opts, response, duration_ms)
        {:ok, response}

      :unavailable ->
        {:error, :acp_unavailable}

      {:error, reason} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        ToolSignals.emit_failed(provider, model, reason)
        ToolSignals.record_usage_failure(provider, opts, reason, duration_ms)
        Logger.warning("ACP generation failed: #{Arbor.LLM.inspect_external_reason(reason)}")
        {:error, reason}
    end
  end

  # ── Rich System Prompt ──

  defdelegate build_stable_system_prompt(agent_id, opts \\ []), to: SystemPromptBuilder
  defdelegate build_volatile_context(agent_id, opts \\ []), to: SystemPromptBuilder
  defdelegate build_rich_system_prompt(agent_id, opts \\ []), to: SystemPromptBuilder

  # ── Embedding API ──

  @doc """
  Generate an embedding for a single text.

  Routes to the appropriate embedding provider based on configuration.
  Selects the first available provider from the `:embedding_routing` config,
  or accepts an explicit `:provider` option.

  ## Options

  - `:provider` - Explicit provider atom (`:ollama`, `:openai`, `:lmstudio`, `:test`)
  - `:model` - Model override
  - `:dimensions` - Requested dimensions (if provider supports it)
  - `:timeout` - Request timeout in ms

  ## Examples

      {:ok, result} = Arbor.AI.embed("Hello world")
      result.embedding  #=> [0.123, 0.456, ...]
      result.dimensions  #=> 768

      {:ok, result} = Arbor.AI.embed("Hello", provider: :test)
  """
  @impl Arbor.Contracts.API.Embedding
  @spec embed(String.t(), keyword()) ::
          {:ok, Arbor.Contracts.API.Embedding.result()} | {:error, term()}
  def embed(text, opts \\ []) do
    with_llm_deadline(opts, Config.timeout(), fn opts, _timeout ->
      opts = snapshot_embedding_config(opts)

      # Try UnifiedBridge first (orchestrator layer), fall back to legacy backends
      case UnifiedBridge.embed(text, opts) do
        {:ok, _} = result ->
          result

        :unavailable ->
          embed_via_legacy(text, opts)

        {:error, {:embed_not_supported, _}} ->
          embed_via_legacy(text, opts)

        {:error, {:unknown_provider, _}} ->
          embed_via_legacy(text, opts)

        {:error, {:bridge_exception, _}} ->
          embed_via_legacy(text, opts)

        {:error, {:bridge_exit, _}} ->
          embed_via_legacy(text, opts)

        {:error, {:bridge_failure, _kind, _reason}} ->
          embed_via_legacy(text, opts)

        {:error, _} = error ->
          error
      end
    end)
  end

  @doc """
  Generate embeddings for multiple texts in a single request.

  Routes to the appropriate embedding provider based on configuration.

  ## Options

  Same as `embed/2`.

  ## Examples

      {:ok, result} = Arbor.AI.embed_batch(["Hello", "World"])
      result.embeddings  #=> [[0.123, ...], [0.456, ...]]
  """
  @impl Arbor.Contracts.API.Embedding
  @spec embed_batch([String.t()], keyword()) ::
          {:ok, Arbor.Contracts.API.Embedding.batch_result()} | {:error, term()}
  def embed_batch(texts, opts \\ []) do
    with_llm_deadline(opts, Config.timeout(), fn opts, _timeout ->
      opts = snapshot_embedding_config(opts)

      # Try UnifiedBridge first, fall back to legacy backends
      case UnifiedBridge.embed_batch(texts, opts) do
        {:ok, _} = result ->
          result

        :unavailable ->
          embed_batch_via_legacy(texts, opts)

        {:error, {:embed_not_supported, _}} ->
          embed_batch_via_legacy(texts, opts)

        {:error, {:unknown_provider, _}} ->
          embed_batch_via_legacy(texts, opts)

        {:error, {:bridge_exception, _}} ->
          embed_batch_via_legacy(texts, opts)

        {:error, {:bridge_exit, _}} ->
          embed_batch_via_legacy(texts, opts)

        {:error, {:bridge_failure, _kind, _reason}} ->
          embed_batch_via_legacy(texts, opts)

        {:error, _} = error ->
          error
      end
    end)
  end

  # ── Thinking Integration ──

  @doc """
  Record thinking blocks from a response to the memory system.

  If the response contains thinking blocks (from extended thinking),
  this records them to `Arbor.Memory.Thinking` for the given agent.

  ## Options

  - `:significant` — flag as significant for reflection (default: false)
  - `:metadata` — additional metadata map

  ## Examples

      {:ok, response} = Arbor.AI.generate_text(prompt, thinking: true)
      Arbor.AI.record_thinking("my_agent", response)
  """
  @spec record_thinking(String.t(), map(), keyword()) :: :ok | {:ok, [map()]}
  def record_thinking(agent_id, response, opts \\ [])

  def record_thinking(_agent_id, %{thinking: nil}, _opts), do: :ok
  def record_thinking(_agent_id, %{thinking: []}, _opts), do: :ok

  def record_thinking(agent_id, %{thinking: blocks}, opts) when is_list(blocks) do
    # Only try to record if arbor_memory is available and Thinking server is running
    # arbor_ai is Standalone and can't depend on arbor_memory at compile time
    with true <- Code.ensure_loaded?(Arbor.Memory.Thinking),
         pid when is_pid(pid) <- Process.whereis(Arbor.Memory.Thinking) do
      entries =
        Enum.map(blocks, fn block ->
          text = block[:text] || block["text"] || ""
          # credo:disable-for-next-line Credo.Check.Refactor.Apply
          {:ok, entry} = apply(Arbor.Memory.Thinking, :record_thinking, [agent_id, text, opts])
          entry
        end)

      {:ok, entries}
    else
      _ ->
        Logger.debug("Thinking server not available, skipping thinking record")
        :ok
    end
  end

  def record_thinking(_agent_id, _response, _opts), do: :ok

  @doc """
  Read thinking blocks from a Claude Code session file.

  Session files are stored in `~/.claude/projects/` as JSONL files.
  Each line is a JSON event, and thinking blocks appear in assistant messages.

  ## Options

  - `:base_dir` — custom session directory (default: `~/.claude/projects`)

  ## Examples

      {:ok, blocks} = Arbor.AI.read_session_thinking("abc-123-session-id")
      Enum.each(blocks, fn block ->
        IO.puts(block.text)
        IO.puts("Signature: \#{block.signature}")
      end)
  """
  @spec read_session_thinking(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  defdelegate read_session_thinking(session_id, opts \\ []),
    to: SessionReader,
    as: :read_thinking

  @doc """
  Read thinking blocks from the most recently modified session.

  ## Options

  - `:project_path` — filter to sessions for a specific project path
  - `:base_dir` — custom session directory

  ## Examples

      # Get thinking from latest session
      {:ok, blocks} = Arbor.AI.latest_session_thinking()

      # Get thinking from latest session for a specific project
      {:ok, blocks} = Arbor.AI.latest_session_thinking(project_path: "~/code/my-project")
  """
  @spec latest_session_thinking(keyword()) :: {:ok, [map()]} | {:error, term()}
  defdelegate latest_session_thinking(opts \\ []),
    to: SessionReader,
    as: :latest_thinking

  @doc """
  Import thinking blocks from a session into the memory system.

  Reads thinking blocks from a session file and records them to
  `Arbor.Memory.Thinking` for the given agent.

  ## Options

  - `:significant` — flag all as significant (default: false)
  - `:session_id` — specific session to import (otherwise uses latest)
  - `:base_dir` — custom session directory

  ## Examples

      # Import from latest session
      {:ok, entries} = Arbor.AI.import_session_thinking("my_agent")

      # Import from specific session
      {:ok, entries} = Arbor.AI.import_session_thinking("my_agent", session_id: "abc-123")
  """
  @spec import_session_thinking(String.t(), keyword()) :: :ok | {:ok, [map()]} | {:error, term()}
  def import_session_thinking(agent_id, opts \\ []) do
    session_id = Keyword.get(opts, :session_id)

    reading_result =
      if session_id do
        SessionReader.read_thinking(session_id, opts)
      else
        SessionReader.latest_thinking(opts)
      end

    case reading_result do
      {:ok, []} ->
        :ok

      {:ok, blocks} ->
        # Convert SessionReader format to Response.thinking format
        response = %{
          thinking: Enum.map(blocks, fn b -> %{text: b.text, signature: b.signature} end)
        }

        record_thinking(agent_id, response, opts)

      {:error, _} = error ->
        error
    end
  end

  # ── Sensitivity Routing ──

  @doc """
  Select the best `{provider, model}` pair for the given data sensitivity.

  Delegates to `SensitivityRouter.select/2`. Filters configured candidates
  by `BackendTrust.can_see?/3`, preferring lower-priority (cheaper/faster) options.

  ## Options

  - `:current_provider` — prefer this provider if it qualifies (stability)
  - `:current_model` — prefer this model if it qualifies (stability)
  - `:candidates` — override the configured candidate pool

  ## Examples

      {:ok, {:ollama, "llama3.2"}} = Arbor.AI.select_for_sensitivity(:restricted)
      {:ok, {:anthropic, "claude-sonnet-4-5-20250514"}} = Arbor.AI.select_for_sensitivity(:confidential)
  """
  @spec select_for_sensitivity(atom(), keyword()) ::
          {:ok, {atom(), String.t()}} | {:error, :no_candidates}
  defdelegate select_for_sensitivity(sensitivity, opts \\ []),
    to: Arbor.AI.SensitivityRouter,
    as: :select

  @doc """
  Make a sensitivity routing decision with mode-based behavior.

  Returns a `%RoutingDecision{}` struct describing what should happen when
  the current provider can't handle the data sensitivity level. The decision
  includes the routing mode (`:auto`/`:warn`/`:gated`/`:block`) based on
  the agent's trust tier.

  ## Options

  - `:agent_id` — agent ID for trust-tier lookup and per-agent overrides
  - `:candidates` — override the configured candidate pool
  - `:mode` — explicit mode override (bypasses trust-tier resolution)

  ## Examples

      decision = Arbor.AI.sensitivity_routing_decision(:openrouter, "model", :restricted, agent_id: "agent_001")
      decision.action   #=> :rerouted
      decision.mode     #=> :gated
      decision.alternative  #=> {:ollama, "llama3.2"}
  """
  @spec sensitivity_routing_decision(atom(), String.t(), atom() | nil, keyword()) ::
          Arbor.AI.SensitivityRouter.RoutingDecision.t()
  defdelegate sensitivity_routing_decision(provider, model, sensitivity, opts \\ []),
    to: Arbor.AI.SensitivityRouter,
    as: :decide

  @doc """
  Check if a `{provider, model}` pair can handle data at the given sensitivity.

  Delegates to `BackendTrust.can_see?/3` for model-granular trust checks.

  ## Examples

      Arbor.AI.can_handle_sensitivity?(:anthropic, "claude-sonnet-4-5-20250514", :confidential)
      #=> true

      Arbor.AI.can_handle_sensitivity?(:openrouter, "random/model", :restricted)
      #=> false
  """
  @spec can_handle_sensitivity?(atom(), String.t(), atom()) :: boolean()
  defdelegate can_handle_sensitivity?(provider, model, sensitivity),
    to: Arbor.AI.BackendTrust,
    as: :can_see?

  # ── Stats & Observability ──

  @doc """
  Get all routing stats as a map keyed by {backend, model}.

  Delegates to `UsageStats.all_stats/0`.

  ## Examples

      stats = Arbor.AI.routing_stats()
      #=> %{
      #=>   {:anthropic, "claude-opus-4"} => %{requests: 47, successes: 46, ...},
      #=>   {:gemini, "gemini-pro"} => %{requests: 23, successes: 21, ...}
      #=> }
  """
  @spec routing_stats() :: map()
  def routing_stats do
    UsageStats.all_stats()
  end

  @doc """
  Get stats for a specific backend (aggregated across all models).

  Delegates to `UsageStats.get_stats/1`.

  ## Examples

      stats = Arbor.AI.backend_stats(:anthropic)
      stats.requests    #=> 47
      stats.successes   #=> 46
      stats.avg_latency_ms #=> 2340.5
  """
  @spec backend_stats(atom()) :: map()
  def backend_stats(backend) when is_atom(backend) do
    UsageStats.get_stats(backend)
  end

  @doc """
  Get all backends sorted by success rate (descending).

  Returns a list of `{backend, success_rate}` tuples.

  Delegates to `UsageStats.reliability_ranking/0`.

  ## Examples

      Arbor.AI.reliability_ranking()
      #=> [{:ollama, 0.991}, {:anthropic, 0.979}, {:gemini, 0.913}]
  """
  @spec reliability_ranking() :: [{atom(), float()}]
  def reliability_ranking do
    UsageStats.reliability_ranking()
  end

  @doc """
  Get current budget status.

  Delegates to `BudgetTracker.get_status/0`.

  ## Examples

      {:ok, status} = Arbor.AI.budget_status()
      status.daily_budget      #=> 10.0
      status.spent_today       #=> 2.35
      status.remaining         #=> 7.65
      status.percent_remaining #=> 0.765
  """
  @spec budget_status() :: {:ok, map()}
  def budget_status do
    BudgetTracker.get_status()
  end

  # ── ACP Session API ──

  @doc """
  Start a new ACP coding agent session.

  Returns `{:ok, pid}` where pid is the AcpSession GenServer.
  The session must be initialized with `acp_create_session/2` before sending messages.

  ## Options

  - `:provider` — provider atom (required): `:claude`, `:codex`, `:gemini`, etc.
  - `:model` — model string override
  - `:system_prompt` — system prompt for the agent
  - `:cwd` — working directory for the session
  - `:stream_callback` — `fn(update) -> any()` for streaming events
  - `:agent_id` — Arbor agent ID for security integration

  ## Examples

      {:ok, session} = Arbor.AI.acp_start_session(:claude, model: "opus")
  """
  @spec acp_start_session(atom(), keyword()) :: GenServer.on_start()
  def acp_start_session(provider, opts \\ []) do
    if Code.ensure_loaded?(AcpSession) do
      AcpSession.start_link(Keyword.put(opts, :provider, provider))
    else
      {:error, :acp_not_available}
    end
  end

  @doc """
  Create a new session on a started ACP agent.

  ## Options

  - `:cwd` — working directory override
  """
  @spec acp_create_session(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def acp_create_session(session, opts \\ []) do
    AcpSession.create_session(session, opts)
  end

  @doc """
  Send a message/prompt to an ACP session.

  Blocks until the agent returns a response.
  """
  @spec acp_send_message(GenServer.server(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def acp_send_message(session, content, opts \\ []) do
    AcpSession.send_message(session, content, opts)
  end

  @doc """
  Resume an existing ACP session by session ID.

  ## Options

  - `:timeout` — resume timeout (default: 120_000)
  """
  @spec acp_resume_session(GenServer.server(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def acp_resume_session(session, session_id, opts \\ []) do
    AcpSession.resume_session(session, session_id, opts)
  end

  @doc """
  Close an ACP session and disconnect from the agent.
  """
  @spec acp_close_session(GenServer.server()) :: :ok
  def acp_close_session(session) do
    AcpSession.close(session)
  end

  @doc """
  List all known ACP provider atoms from the catalog — native + adapted +
  any `config :arbor_ai, :acp_providers` overrides.

  This is the authoritative provider allowlist: callers that gate on provider
  identity (e.g. `Arbor.Actions.Acp`) should derive from this rather than
  duplicating a static list, so adding an agent to the catalog is the only edit.
  """
  @spec acp_providers() :: [atom()]
  def acp_providers do
    if Code.ensure_loaded?(AcpSession.Config) do
      AcpSession.Config.list_providers() |> Enum.map(&elem(&1, 0))
    else
      []
    end
  end

  @doc "Whether `provider` is a known ACP provider in the catalog."
  @spec acp_known_provider?(atom()) :: boolean()
  def acp_known_provider?(provider) when is_atom(provider), do: provider in acp_providers()
  def acp_known_provider?(_), do: false

  @doc """
  Classify whether an ACP resume failed because the provider does not support
  the `load_session` capability.

  This is deliberately an exact structural match. Provider messages, generic
  JSON-RPC errors, transport failures, and timeouts are not evidence that a
  fresh session is safe to start.
  """
  @spec classify_resume_unavailability(term()) :: :resume_unavailable | :not_resume_unavailable
  def classify_resume_unavailability({:unsupported_capability, :load_session}),
    do: :resume_unavailable

  def classify_resume_unavailability(%{"code" => -32_002}), do: :resume_unavailable

  def classify_resume_unavailability(_reason), do: :not_resume_unavailable

  # -- ACP Pool API --

  @doc """
  Checkout an ACP session from the pool for the given agent.

  Returns `{:ok, session_pid}` on success. The session must be returned
  via `acp_checkin/1` when done.

  Reuse is fail-closed over the full `SessionProfile` (agent, task scope,
  cwd/workspace, model, tools, trust domain, and immutable startup fingerprint).
  Different coding tasks never inherit another task's provider conversation or
  cwd implicitly; cross-task continuity is only via explicit managed resume.

  ## Options

  - `:model` — model override (immutable reuse boundary)
  - `:cwd` / `:workspace` — working directory (canonicalized; immutable)
  - `:task_id` — coding task scope for pool matching
  - `:agent_id` — owning agent (`nil` matches only `nil`)
  - `:timeout` — checkout timeout (default: 30_000)
  """
  @spec acp_checkout(atom(), keyword()) :: {:ok, pid()} | {:error, term()}
  def acp_checkout(agent, opts \\ []) do
    alias Arbor.AI.AcpPool

    if Code.ensure_loaded?(AcpPool) and is_pid(Process.whereis(AcpPool)) do
      AcpPool.checkout(agent, opts)
    else
      {:error, :pool_not_available}
    end
  end

  @doc """
  Return a session to the ACP pool.

  Compatible non-tool sessions become idle for same-profile reuse.
  Tool-enabled sessions are closed on checkin because provider MCP registration
  is immutable; the next checkout mints a fresh process and ToolServer.
  """
  @spec acp_checkin(pid()) :: :ok | {:error, term()}
  def acp_checkin(session) do
    alias Arbor.AI.AcpPool

    if Code.ensure_loaded?(AcpPool) and is_pid(Process.whereis(AcpPool)) do
      AcpPool.checkin(session)
    else
      {:error, :pool_not_available}
    end
  end

  @doc """
  Get ACP pool status for all providers.
  """
  @spec acp_pool_status() :: map() | {:error, term()}
  def acp_pool_status do
    alias Arbor.AI.AcpPool

    if Code.ensure_loaded?(AcpPool) and is_pid(Process.whereis(AcpPool)) do
      AcpPool.status()
    else
      {:error, :pool_not_available}
    end
  end

  # -- Managed ACP Session API (opaque durable handles) --

  @doc """
  Start a managed ACP session and return a JSON-clean opaque handle.

  The live caller process becomes the session owner (any `:owner` / `:owner_pid`
  option is stripped). PIDs stay inside the AI-owned registry; callers receive
  only `worker_session_id` metadata suitable for Engine context / checkpoints.

  ## Options

  - `:use_pool` / `:pooled` - checkout from `AcpPool` instead of starting a
    temporary managed child (default: false). Pooled coding checkouts are
    task-scoped: `:task_id` is included in pool profile matching so another
    task cannot reuse this process's provider conversation or cwd.
  - `:return_to_pool` - on owner death / close of a pooled session, check in
    rather than hard-close (default: true when pooled). Explicit close may
    override this stored default via `acp_managed_close_session/2`.
  - `:create_session` - when pooled, force `create_session` on checkout
    (default: false; pooled sessions are often pre-created)
  - `:task_id` / `:principal_id` / `:agent_id` - cross-process resume authority
    (both non-empty `task_id` and principal required for non-owner access).
    `:agent_id` is also forwarded to the session/pool so ACP file/exec callbacks
    authorize as the owning agent. `:task_id` is also forwarded to the pool for
    SessionProfile scoping and is stripped before `AcpSession` start.
  - `:session_id` - resume an existing provider session after start on a fresh
    or same-task-compatible local process (explicit cross-task continuity only;
    never inferred from an idle pool entry of another task)
  - `:model`, `:cwd`, `:timeout`, `:client_opts`, `:agent_id` - forwarded to the
    session / pool as immutable reuse boundaries where applicable
  - `:session_module`, `:pool_module`, `:supervisor`, `:server` - injectable for
    tests (defaults: `AcpSession`, `AcpPool`, managed supervisor/registry)

  ## Returns

  `{:ok, meta}` where meta includes `worker_session_id`, `session_id` (provider),
  `provider`, `model`, `status`, `pooled` - no PID/ref/function/struct.
  """
  @spec acp_managed_start_session(atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def acp_managed_start_session(provider, opts \\ []) when is_atom(provider) do
    Arbor.AI.AcpManaged.start_session(provider, opts)
  end

  @doc """
  Send a message on a managed ACP session.

  Authority is resolved quickly in the registry; the actual `AcpSession`
  call runs in the **original facade caller process** so caller-death prompt
  cancellation remains owned by the task process (not the registry).
  """
  @spec acp_managed_send_message(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def acp_managed_send_message(worker_session_id, content, opts \\ [])
      when is_binary(worker_session_id) and is_binary(content) do
    Arbor.AI.AcpManaged.send_message(worker_session_id, content, opts)
  end

  @doc """
  Deliver a JSON-clean task control to exactly one managed ACP session.

  Resolution is by the nonblank `task_id` and `principal_id` pair only. Worker
  handles and session PIDs are deliberately not accepted as task-control
  authority. While a prompt is active the result is immediately
  `{:ok, :queued, :same_session_follow_up}`; an idle session returns
  `{:ok, :deferred, :same_session_follow_up}`.
  """
  @spec acp_managed_deliver_task_control(String.t(), String.t(), map(), keyword()) ::
          {:ok, :queued | :delivered | :deferred, :same_session_follow_up} | {:error, term()}
  def acp_managed_deliver_task_control(task_id, principal_id, control, opts \\ [])
      when is_binary(task_id) and is_binary(principal_id) and is_map(control) do
    Arbor.AI.AcpManaged.deliver_task_control(task_id, principal_id, control, opts)
  end

  @doc "Return the provider's operator-declared ACP task-control capabilities."
  @spec acp_task_control_capabilities(atom()) :: map()
  def acp_task_control_capabilities(provider) when is_atom(provider) do
    AcpSession.Config.task_control_capabilities(provider)
  end

  @doc """
  Query managed session status (JSON-clean).

  Registry authority check is quick; live status is read from the session
  process by the facade caller. Returns fields needed by action migration:
  `worker_session_id`, provider `session_id`, `provider`, `model`, `status`,
  `pooled`, `context_pressure`, `context_tokens`, and `usage`.

  If live status fails/raises/exits, returns `{:error, :session_unavailable}`
  without inventing metadata or invalidating a still-live handle.
  """
  @spec acp_managed_session_status(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def acp_managed_session_status(worker_session_id, opts \\ [])
      when is_binary(worker_session_id) do
    Arbor.AI.AcpManaged.session_status(worker_session_id, opts)
  end

  @doc """
  Close a managed ACP session or return a pooled session to the pool.

  Idempotent: closing an unknown/already-closed handle returns success with
  `status: "already_closed"`.

  For pooled sessions, `return_to_pool: true|false` on this call overrides the
  stored close policy for the explicit close only. Owner-death cleanup still
  uses the policy stored at start.
  """
  @spec acp_managed_close_session(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def acp_managed_close_session(worker_session_id, opts \\ [])
      when is_binary(worker_session_id) do
    Arbor.AI.AcpManaged.close_session(worker_session_id, opts)
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  # ── Tool-calling helpers ──

  defp with_llm_deadline(opts, default_timeout, fun) when is_function(fun, 2) do
    with {:ok, opts, timeout} <- Arbor.LLM.normalize_timeout_options(opts, default_timeout) do
      Arbor.LLM.run_with_deadline(
        fn -> fun.(opts, timeout) end,
        timeout,
        Arbor.LLM.RequestTimeoutError.exception(timeout_ms: timeout)
      )
    end
  end

  # SECURITY: Snapshot provider and model from Application config at the call boundary.
  # This prevents TOCTOU races where another process could change the global config
  # between our read and use. Idempotent — if already snapshotted (present in opts),
  # the existing values are kept.
  @spec snapshot_config(keyword()) :: keyword()
  defp snapshot_config(opts) do
    opts
    |> Keyword.put_new_lazy(:provider, fn -> Config.default_provider() end)
    |> Keyword.put_new_lazy(:model, fn -> Config.default_model() end)
  end

  # ===========================================================================
  # Private Helpers - Embedding
  # ===========================================================================

  # Snapshot embedding config at entry point, similar to snapshot_config for generation.
  # Ensures provider and model are resolved from config if not provided.
  @spec snapshot_embedding_config(keyword()) :: keyword()
  defp snapshot_embedding_config(opts) do
    case Keyword.get(opts, :provider) do
      nil ->
        if Application.get_env(:arbor_ai, :embedding_test_fallback, false) do
          # Test/CI stub: force the deterministic hash backend ahead of
          # any routing-config discovery. Otherwise discovery would pin
          # `:provider` to the first configured provider (e.g. `:ollama`)
          # and route real embeddings through a (slow) local server even
          # when generation legitimately uses Ollama. Generation routing
          # is unaffected — this only governs the embedding entry point.
          opts
          |> Keyword.put_new(:provider, :test)
          |> Keyword.put_new(:model, "test-hash-768d")
        else
          # Resolve from config and inject provider + model
          config = embedding_config()

          case config.providers do
            [{backend, model} | _] ->
              opts
              |> Keyword.put_new(:provider, backend)
              |> Keyword.put_new(:model, model)

            _ ->
              opts
          end
        end

      _provider ->
        # Provider already specified, ensure model has a default
        opts
        |> Keyword.put_new_lazy(:model, fn ->
          case Keyword.get(opts, :provider) do
            :ollama -> "nomic-embed-text"
            :lmstudio -> "text-embedding"
            :openai -> "text-embedding-3-small"
            :test -> "test-hash-768d"
            _ -> "nomic-embed-text"
          end
        end)
    end
  end

  # Legacy embedding path — uses the old backend modules directly
  defp embed_via_legacy(text, opts) do
    case resolve_embedding_provider(opts) do
      {:ok, {module, provider_opts}} ->
        module.embed(text, Keyword.merge(provider_opts, opts))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp embed_batch_via_legacy(texts, opts) do
    case resolve_embedding_provider(opts) do
      {:ok, {module, provider_opts}} ->
        module.embed_batch(texts, Keyword.merge(provider_opts, opts))

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Resolve which embedding provider module to use.
  #
  # Priority:
  # 1. Explicit :provider opt → use that provider directly
  # 2. Config-based discovery → read embedding_routing config, filter by availability
  # 3. TestEmbedding fallback if embedding_test_fallback: true
  @spec resolve_embedding_provider(keyword()) ::
          {:ok, {module(), keyword()}} | {:error, term()}
  defp resolve_embedding_provider(opts) do
    case Keyword.get(opts, :provider) do
      nil ->
        resolve_from_config(opts)

      provider when is_atom(provider) ->
        case provider_to_module(provider) do
          {:ok, module} -> {:ok, {module, [provider: provider]}}
          :error -> {:error, {:unknown_provider, provider}}
        end
    end
  end

  # Inline embedding provider discovery (replaces Router.route_embedding/1).
  # Reads the embedding_routing config, filters by ProviderCatalog availability,
  # and returns the first available provider module.
  defp resolve_from_config(opts) do
    config = embedding_config()
    prefer = Keyword.get(opts, :prefer, config.preferred)
    providers = sort_embedding_providers(config.providers, prefer)

    available =
      Enum.filter(providers, fn {backend, _model} ->
        embedding_backend_available?(backend)
      end)

    case pick_embedding_provider(available) do
      {:ok, _} = result ->
        result

      {:error, :no_embedding_providers} ->
        # Try cloud fallback if configured
        if config.fallback_to_cloud do
          cloud_available =
            config.providers
            |> sort_embedding_providers(:cloud)
            |> Enum.filter(fn {backend, _model} -> embedding_backend_available?(backend) end)

          case pick_embedding_provider(cloud_available) do
            {:ok, _} = result -> result
            {:error, _} -> maybe_test_fallback()
          end
        else
          maybe_test_fallback()
        end
    end
  end

  defp pick_embedding_provider([{backend, model} | _]) do
    case provider_to_module(backend) do
      {:ok, module} -> {:ok, {module, [provider: backend, model: model]}}
      :error -> {:error, {:unknown_provider, backend}}
    end
  end

  defp pick_embedding_provider([]), do: {:error, :no_embedding_providers}

  defp maybe_test_fallback do
    if Application.get_env(:arbor_ai, :embedding_test_fallback, false) do
      {:ok, {TestEmbedding, [provider: :test]}}
    else
      {:error, :no_embedding_providers}
    end
  end

  @default_embedding_config %{
    preferred: :local,
    providers: [
      {:ollama, "nomic-embed-text"},
      {:lmstudio, "text-embedding"},
      {:openai, "text-embedding-3-small"}
    ],
    fallback_to_cloud: true
  }

  defp embedding_config do
    default = @default_embedding_config
    config = Application.get_env(:arbor_ai, :embedding_routing, %{})

    %{
      preferred: Map.get(config, :preferred, default.preferred),
      providers: Map.get(config, :providers, default.providers),
      fallback_to_cloud: Map.get(config, :fallback_to_cloud, default.fallback_to_cloud)
    }
  end

  @cloud_embedding_providers [:openai, :anthropic, :gemini, :cohere]

  defp sort_embedding_providers(providers, :cloud) do
    {cloud, local} =
      Enum.split_with(providers, fn {backend, _model} ->
        backend in @cloud_embedding_providers
      end)

    cloud ++ local
  end

  defp sort_embedding_providers(providers, _prefer), do: providers

  # Check if an embedding backend is available via ProviderCatalog (runtime bridge)
  defp embedding_backend_available?(backend) do
    provider_str = embedding_backend_to_provider(backend)

    # arbor_llm is a direct dep — call the catalog directly.
    catalog = Arbor.LLM.ProviderCatalog.all([])
    Enum.any?(catalog, fn entry -> entry.provider == provider_str and entry.available? end)
  rescue
    _ -> true
  catch
    :exit, _ -> true
  end

  defp embedding_backend_to_provider(:anthropic), do: "anthropic"
  defp embedding_backend_to_provider(:openai), do: "openai"
  defp embedding_backend_to_provider(:gemini), do: "google"
  defp embedding_backend_to_provider(:lmstudio), do: "lm_studio"
  defp embedding_backend_to_provider(:ollama), do: "ollama"
  defp embedding_backend_to_provider(other), do: Atom.to_string(other)

  @embedding_providers %{
    ollama: OllamaEmbedding,
    openai: OpenAIEmbedding,
    lmstudio: OpenAIEmbedding,
    test: TestEmbedding
  }

  defp provider_to_module(provider) do
    case Map.fetch(@embedding_providers, provider) do
      {:ok, module} -> {:ok, module}
      :error -> :error
    end
  end
end
