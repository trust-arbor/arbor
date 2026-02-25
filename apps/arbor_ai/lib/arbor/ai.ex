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
    Backends.OllamaEmbedding,
    Backends.OpenAIEmbedding,
    Backends.TestEmbedding,
    BudgetTracker,
    Config,
    ResponseNormalizer,
    SessionBridge,
    SessionReader,
    SystemPromptBuilder,
    ToolAuthorization,
    ToolSignals,
    UnifiedBridge,
    UsageStats
  }

  # Note: Arbor.Memory.* and Arbor.Actions are higher in the hierarchy than arbor_ai (Standalone).
  # All calls use Code.ensure_loaded?/apply to avoid compile-time dependency.

  alias Jido.AI.Actions.ToolCalling.CallWithTools
  alias Jido.AI.ToolAdapter

  require Logger

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
    provider = extract_provider(opts)
    resource = "arbor://ai/request/#{provider}"
    {trace_id, opts} = Keyword.pop(opts, :trace_id)

    case Arbor.Security.authorize(agent_id, resource, :request, trace_id: trace_id) do
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
    # SECURITY: Snapshot config at entry point to prevent TOCTOU race.
    # Another process could change Application env between our read and use.
    opts = snapshot_config(opts)

    provider = Keyword.fetch!(opts, :provider)
    Logger.debug("Arbor.AI generating with provider #{inspect(provider)}")

    # All providers (CLI + API) are handled by the orchestrator's UnifiedLLM layer.
    UnifiedBridge.generate_text(prompt, opts)
  end

  @doc """
  Generate text using the API backend with tool/action support.

  Uses jido_ai's CallWithTools for an agentic loop where the LLM receives
  Arbor.Actions as tools, can call them, and loops until a final answer.

  Wraps with arbor infrastructure: signals, budget tracking, usage stats.

  ## Options

  - `:provider` - LLM provider atom (e.g. `:openrouter`, `:zai_coding_plan`)
  - `:model` - Model string (e.g. `"arcee-ai/trinity-large-preview:free"`)
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
    # SECURITY: Snapshot config at entry point to prevent TOCTOU race.
    opts = snapshot_config(opts)

    provider = Keyword.fetch!(opts, :provider)
    model = Keyword.fetch!(opts, :model)

    # Arbor layer: signal + timing
    ToolSignals.emit_started(provider, model, String.length(prompt))
    start_time = System.monotonic_time(:millisecond)

    # Build model struct (bypasses LLMDB lookup, avoids base_url bug)
    model_struct = build_model_spec(provider, model)

    # Build jido_ai tools map from Arbor.Actions
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    default_tools =
      if Code.ensure_loaded?(Arbor.Actions), do: apply(Arbor.Actions, :all_actions, []), else: []

    action_modules = Keyword.get(opts, :tools, default_tools)
    tools_map = ToolAdapter.to_action_map(action_modules)

    # SECURITY: Filter tools map to only include tools the agent is authorized
    # to execute. This prevents the confused deputy attack where the LLM acting
    # as the agent's deputy could call tools the agent itself lacks capability for.
    # Pre-flight authorization ensures the LLM never even sees unauthorized tools.
    agent_id = Keyword.get(opts, :agent_id)
    tools_map = ToolAuthorization.filter_authorized_tools(agent_id, tools_map)

    # Auto-build rich system prompt if none provided and agent_id is available
    system_prompt =
      case Keyword.get(opts, :system_prompt) do
        nil ->
          if agent_id, do: build_rich_system_prompt(agent_id, opts), else: nil

        prompt ->
          prompt
      end

    params = %{
      model: model_struct,
      prompt: prompt,
      system_prompt: system_prompt,
      max_tokens: Keyword.get(opts, :max_tokens, 16_384),
      temperature: Keyword.get(opts, :temperature, 0.7),
      auto_execute: Keyword.get(opts, :auto_execute, true),
      max_turns: Keyword.get(opts, :max_turns, 10)
    }

    # Build execution context — agent_id needed for memory actions
    extra_context = Keyword.get(opts, :context, %{})

    context =
      %{tools: tools_map}
      |> maybe_put(:agent_id, agent_id)
      |> Map.merge(extra_context)

    # ── SessionBridge (strangler fig) ──────────────────────────────
    # Try the Session path first. If unavailable, fall back to CallWithTools.
    # The Session path runs the turn.dot graph which handles tool loops
    # internally via graph cycles (dispatch_tools → call_llm).
    session_opts =
      opts
      |> Keyword.put(:system_prompt, system_prompt)
      |> Keyword.put(:tools, action_modules)

    case SessionBridge.try_session_call(prompt, session_opts) do
      {:ok, response} ->
        # Session path succeeded — response is already in the right format
        duration_ms = System.monotonic_time(:millisecond) - start_time
        ToolSignals.emit_completed(provider, model, duration_ms, response)
        ToolSignals.record_budget_usage(provider, opts, response)
        ToolSignals.record_usage_success(provider, opts, response, duration_ms)
        {:ok, response}

      {:unavailable, _reason} ->
        # Fall back to CallWithTools (the legacy path)
        result = CallWithTools.run(params, context)
        duration_ms = System.monotonic_time(:millisecond) - start_time

        case result do
          {:ok, raw_result} ->
            response = format_tools_response(raw_result, provider, model)
            ToolSignals.emit_completed(provider, model, duration_ms, response)
            ToolSignals.record_budget_usage(provider, opts, response)
            ToolSignals.record_usage_success(provider, opts, response, duration_ms)
            {:ok, response}

          {:error, reason} ->
            duration_ms_err = System.monotonic_time(:millisecond) - start_time
            ToolSignals.emit_failed(provider, model, reason)
            ToolSignals.record_usage_failure(provider, opts, reason, duration_ms_err)
            Logger.warning("Arbor.AI tool-calling generation failed: #{inspect(reason)}")
            {:error, reason}
        end
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
    case resolve_embedding_provider(opts) do
      {:ok, {module, provider_opts}} ->
        module.embed(text, Keyword.merge(provider_opts, opts))

      {:error, reason} ->
        {:error, reason}
    end
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
    case resolve_embedding_provider(opts) do
      {:ok, {module, provider_opts}} ->
        module.embed_batch(texts, Keyword.merge(provider_opts, opts))

      {:error, reason} ->
        {:error, reason}
    end
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

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  # ── Tool-calling helpers ──

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp format_tools_response(result, provider, model) do
    ResponseNormalizer.format_tools_response(result, provider, model)
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

  defp build_model_spec(provider, model) do
    # Build raw LLMDB.Model struct to bypass LLMDB lookup.
    # This allows using models not yet in the database.
    # Note: Map.put adds :base_url to work around req_llm accessing
    # model.base_url even though LLMDB.Model doesn't define that field.
    %LLMDB.Model{
      provider: provider,
      model: model,
      id: model
    }
    |> Map.put(:base_url, nil)
  end

  # ===========================================================================
  # Private Helpers - Embedding
  # ===========================================================================

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

    if Code.ensure_loaded?(Arbor.Orchestrator.UnifiedLLM.ProviderCatalog) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      catalog = apply(Arbor.Orchestrator.UnifiedLLM.ProviderCatalog, :all, [[]])
      Enum.any?(catalog, fn entry -> entry.provider == provider_str and entry.available? end)
    else
      true
    end
  rescue
    _ -> true
  catch
    :exit, _ -> true
  end

  defp embedding_backend_to_provider(:anthropic), do: "anthropic"
  defp embedding_backend_to_provider(:openai), do: "openai"
  defp embedding_backend_to_provider(:gemini), do: "gemini"
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
