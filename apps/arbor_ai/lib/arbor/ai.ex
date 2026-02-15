defmodule Arbor.AI do
  @moduledoc """
  Unified LLM interface for Arbor.

  Provides a simple facade for text generation with automatic routing
  between API backends (ReqLLM, paid) and CLI backends (Claude Code, etc., "free").

  ## Quick Start

      # Generate text with default settings (uses routing strategy)
      {:ok, result} = Arbor.AI.generate_text("What is 2+2?")
      result.text
      #=> "2+2 equals 4."

      # Explicitly use CLI backend (free via subscriptions)
      {:ok, result} = Arbor.AI.generate_text("Hello", backend: :cli)

      # Explicitly use API backend (paid)
      {:ok, result} = Arbor.AI.generate_text("Hello", backend: :api)

      # With custom options
      {:ok, result} = Arbor.AI.generate_text(
        "Analyze this code for security issues.",
        system_prompt: "You are a security reviewer.",
        max_tokens: 2048,
        temperature: 0.3
      )

  ## Backend Options

  - `:backend` - Backend selection:
    - `:api` - Use ReqLLM (paid API calls)
    - `:cli` - Use CLI agents (Claude Code, Codex, Gemini CLI, etc.)
    - `:auto` - Use routing strategy to decide (default)

  ## Configuration

  Configure defaults in your config:

      config :arbor_ai,
        # API settings
        default_provider: :anthropic,
        default_model: "claude-sonnet-4-5-20250514",
        timeout: 60_000,

        # Routing
        default_backend: :auto,
        routing_strategy: :cost_optimized,  # Try CLI first

        # CLI fallback chain
        cli_fallback_chain: [:anthropic, :openai, :gemini, :lmstudio]

  API keys are loaded from environment variables:

      ANTHROPIC_API_KEY=sk-ant-...
      OPENAI_API_KEY=sk-...
  """

  @behaviour Arbor.Contracts.API.AI
  @behaviour Arbor.Contracts.API.Embedding

  alias Arbor.AI.{
    BackendRegistry,
    Backends.OllamaEmbedding,
    Backends.OpenAIEmbedding,
    Backends.TestEmbedding,
    BudgetTracker,
    CliImpl,
    Config,
    ResponseNormalizer,
    Router,
    SessionReader,
    SystemPromptBuilder,
    TaskMeta,
    UsageStats
  }

  # Note: Arbor.Memory.* and Arbor.Actions are higher in the hierarchy than arbor_ai (Standalone).
  # All calls use Code.ensure_loaded?/apply to avoid compile-time dependency.

  alias Jido.AI.Actions.ToolCalling.CallWithTools
  alias Jido.AI.Executor

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
    backend = Router.select_backend(opts)

    Logger.debug("Arbor.AI routing to #{backend} backend")

    case backend do
      :cli ->
        generate_text_via_cli(prompt, opts)

      :api ->
        generate_text_via_api(prompt, opts)
    end
  end

  @doc """
  Generate text using the CLI backend directly.

  Bypasses routing and uses CLI agents (Claude Code, Codex, etc.).
  """
  @spec generate_text_via_cli(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def generate_text_via_cli(prompt, opts \\ []) do
    # SECURITY: Snapshot config if called directly (not via generate_text/2)
    opts = snapshot_config(opts)

    case CliImpl.generate_text(prompt, opts) do
      {:ok, response} ->
        {:ok, normalize_response(response)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generate text using the API backend directly.

  Bypasses routing and uses ReqLLM (paid API calls).
  """
  @spec generate_text_via_api(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def generate_text_via_api(prompt, opts \\ []) do
    # SECURITY: Snapshot config if called directly (not via generate_text/2)
    opts = snapshot_config(opts)

    # Strangler fig: try unified Client first, fall back to ReqLLM
    case Arbor.AI.UnifiedBridge.generate_text(prompt, opts) do
      {:ok, response} ->
        {:ok, response}

      :unavailable ->
        # Fallback to legacy ReqLLM path
        generate_text_via_reqllm(prompt, opts)

      {:error, reason} ->
        Logger.warning("Unified LLM failed, falling back to ReqLLM: #{inspect(reason)}")
        generate_text_via_reqllm(prompt, opts)
    end
  end

  defp generate_text_via_reqllm(prompt, opts) do
    provider = Keyword.fetch!(opts, :provider)
    model = Keyword.fetch!(opts, :model)
    system_prompt = Keyword.get(opts, :system_prompt)
    max_tokens = Keyword.get(opts, :max_tokens, 1024)
    temperature = Keyword.get(opts, :temperature, 0.7)
    thinking_enabled = Keyword.get(opts, :thinking, false)
    thinking_budget = Keyword.get(opts, :thinking_budget, 4096)

    messages = build_messages(prompt, system_prompt)
    model_spec = build_model_spec(provider, model)

    req_opts =
      [
        max_tokens: max_tokens,
        temperature: temperature
      ]
      |> maybe_add_system_prompt(system_prompt)
      |> maybe_add_api_key(provider)
      |> maybe_add_thinking(thinking_enabled, thinking_budget)

    Logger.debug(
      "Arbor.AI API generating with #{provider}:#{model} via ReqLLM (fallback), thinking: #{thinking_enabled}"
    )

    case ReqLLM.generate_text(model_spec, messages, req_opts) do
      {:ok, response} ->
        {:ok, format_api_response(response, provider, model)}

      {:error, reason} ->
        Logger.warning("Arbor.AI API generation failed: #{inspect(reason)}")
        {:error, reason}
    end
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
    emit_tool_request_started(provider, model, String.length(prompt))
    start_time = System.monotonic_time(:millisecond)

    # Build model struct (bypasses LLMDB lookup, avoids base_url bug)
    model_struct = build_model_spec(provider, model)

    # Build jido_ai tools map from Arbor.Actions
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    default_tools =
      if Code.ensure_loaded?(Arbor.Actions), do: apply(Arbor.Actions, :all_actions, []), else: []

    action_modules = Keyword.get(opts, :tools, default_tools)
    tools_map = Executor.build_tools_map(action_modules)

    # SECURITY: Filter tools map to only include tools the agent is authorized
    # to execute. This prevents the confused deputy attack where the LLM acting
    # as the agent's deputy could call tools the agent itself lacks capability for.
    # Pre-flight authorization ensures the LLM never even sees unauthorized tools.
    agent_id = Keyword.get(opts, :agent_id)
    tools_map = filter_authorized_tools(agent_id, tools_map)

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

    case Arbor.AI.SessionBridge.try_session_call(prompt, session_opts) do
      {:ok, response} ->
        # Session path succeeded — response is already in the right format
        duration_ms = System.monotonic_time(:millisecond) - start_time
        emit_tool_request_completed(provider, model, duration_ms, response)
        record_tool_budget_usage(provider, opts, response)
        record_tool_usage_stats_success(provider, opts, response, duration_ms)
        {:ok, response}

      {:unavailable, _reason} ->
        # Fall back to CallWithTools (the legacy path)
        result = CallWithTools.run(params, context)
        duration_ms = System.monotonic_time(:millisecond) - start_time

        case result do
          {:ok, raw_result} ->
            response = format_tools_response(raw_result, provider, model)
            emit_tool_request_completed(provider, model, duration_ms, response)
            record_tool_budget_usage(provider, opts, response)
            record_tool_usage_stats_success(provider, opts, response, duration_ms)
            {:ok, response}

          {:error, reason} ->
            duration_ms_err = System.monotonic_time(:millisecond) - start_time
            emit_tool_request_failed(provider, model, reason)
            record_tool_usage_stats_failure(provider, opts, reason, duration_ms_err)
            Logger.warning("Arbor.AI tool-calling generation failed: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  # ── Rich System Prompt ──

  defdelegate build_stable_system_prompt(agent_id, opts \\ []), to: SystemPromptBuilder
  defdelegate build_volatile_context(agent_id, opts \\ []), to: SystemPromptBuilder
  defdelegate build_rich_system_prompt(agent_id, opts \\ []), to: SystemPromptBuilder

  @doc """
  Check available backends.

  Returns a list of available backends with their status.
  """
  @spec available_backends() :: [atom()]
  def available_backends do
    BackendRegistry.available_backends()
  end

  # ── Task-Aware Routing ──

  @doc """
  Route a task to an appropriate backend and model.

  Delegates to `Router.route_task/2`. Accepts either a prompt string
  (which gets classified) or a TaskMeta struct.

  ## Options

  - `:model` - Manual override `{backend, model}` - bypasses routing entirely
  - `:min_trust` - Override minimum trust level
  - `:exclude` - List of backends to exclude

  ## Returns

  - `{:ok, {backend, model}}` - Selected backend and model
  - `{:error, reason}` - Routing failed

  ## Examples

      {:ok, {:anthropic, "claude-opus-4-20250514"}} = Arbor.AI.route_task("Fix auth vulnerability")
  """
  @spec route_task(Arbor.AI.TaskMeta.t() | String.t(), keyword()) ::
          {:ok, {atom(), String.t()}} | {:error, term()}
  def route_task(task_or_prompt, opts \\ []) do
    Router.route_task(task_or_prompt, opts)
  end

  @doc """
  Route an embedding request to an appropriate provider.

  Delegates to `Router.route_embedding/1`.

  ## Options

  - `:prefer` - `:local`, `:cloud`, or `:auto` (default: configured preference)

  ## Returns

  - `{:ok, {backend, model}}` - Selected embedding provider and model
  - `{:error, :no_embedding_providers}` - No providers available

  ## Examples

      {:ok, {:ollama, "nomic-embed-text"}} = Arbor.AI.route_embedding()
      {:ok, {:openai, "text-embedding-3-small"}} = Arbor.AI.route_embedding(prefer: :cloud)
  """
  @spec route_embedding(keyword()) :: {:ok, {atom(), String.t()}} | {:error, term()}
  def route_embedding(opts \\ []) do
    Router.route_embedding(opts)
  end

  # ── Embedding API ──

  @doc """
  Generate an embedding for a single text.

  Routes to the appropriate embedding provider based on configuration.
  Uses `Router.route_embedding/1` to select the provider, or accepts
  an explicit `:provider` option.

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

  @doc """
  Classify a prompt into task metadata for routing decisions.

  Delegates to `TaskMeta.classify/2`.

  ## Examples

      meta = Arbor.AI.classify_task("Fix the security vulnerability in auth.ex")
      meta.risk_level  #=> :critical
      meta.domain      #=> :security
  """
  @spec classify_task(String.t(), keyword()) :: Arbor.AI.TaskMeta.t()
  def classify_task(prompt, opts \\ []) do
    TaskMeta.classify(prompt, opts)
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

  defp normalize_response(response), do: ResponseNormalizer.normalize_response(response)

  defp build_messages(prompt, nil) do
    [%{role: "user", content: prompt}]
  end

  defp build_messages(prompt, _system_prompt) do
    # System prompt is passed via opts, not messages for ReqLLM
    [%{role: "user", content: prompt}]
  end

  defp maybe_add_system_prompt(opts, nil), do: opts
  defp maybe_add_system_prompt(opts, system), do: Keyword.put(opts, :system_prompt, system)

  # Add extended thinking configuration for Anthropic models
  # See: https://docs.anthropic.com/en/docs/build-with-claude/extended-thinking
  defp maybe_add_thinking(opts, false, _budget), do: opts

  defp maybe_add_thinking(opts, true, budget) do
    Keyword.put(opts, :thinking, %{type: :enabled, budget_tokens: budget})
  end

  # Inject API key from environment since ReqLLM.put_key may not work
  # after application startup
  defp maybe_add_api_key(opts, provider) do
    key_var = api_key_env_var(provider)

    case System.get_env(key_var) do
      nil -> opts
      "" -> opts
      key -> Keyword.put(opts, :api_key, key)
    end
  end

  defp api_key_env_var(:openrouter), do: "OPENROUTER_API_KEY"
  defp api_key_env_var(:anthropic), do: "ANTHROPIC_API_KEY"
  defp api_key_env_var(:openai), do: "OPENAI_API_KEY"
  defp api_key_env_var(:google), do: "GOOGLE_API_KEY"
  defp api_key_env_var(:gemini), do: "GEMINI_API_KEY"
  defp api_key_env_var(:zai_coding_plan), do: "ZAI_API_KEY"
  defp api_key_env_var(_), do: nil

  # ── Tool authorization (confused deputy prevention) ──

  # Filter a tools map to only include tools the agent is authorized to execute.
  # This is the pre-flight check: the LLM will only see tools the agent holds
  # capabilities for, preventing it from acting as a confused deputy.
  #
  # If no agent_id is provided (system-level call), all tools pass through.
  # If Arbor.Security is not loaded (e.g. in test), all tools pass through
  # with a debug log.
  @spec filter_authorized_tools(String.t() | nil, map()) :: map()
  defp filter_authorized_tools(nil, tools_map), do: tools_map

  defp filter_authorized_tools(agent_id, tools_map) when map_size(tools_map) == 0 do
    _ = agent_id
    tools_map
  end

  defp filter_authorized_tools(agent_id, tools_map) do
    {authorized, denied} =
      Enum.split_with(tools_map, fn {tool_name, _module} ->
        check_tool_authorization(agent_id, tool_name) == :authorized
      end)

    if denied != [] do
      denied_names = Enum.map(denied, fn {name, _} -> name end)

      Logger.info(
        "Tool authorization: filtered #{length(denied)} unauthorized tools " <>
          "for agent #{agent_id}: #{inspect(denied_names)}"
      )

      emit_tool_authorization_denied(agent_id, denied_names)
    end

    Map.new(authorized)
  end

  # Check whether an agent is authorized to execute a specific tool.
  #
  # Uses the Code.ensure_loaded?/apply bridge pattern to avoid compile-time
  # dependency on arbor_security (which is Level 1; arbor_ai is Standalone).
  #
  # Returns:
  #   :authorized - agent holds the capability (or security unavailable)
  #   :unauthorized - agent lacks the capability
  #   :pending_approval - requires escalation
  @spec check_tool_authorization(String.t(), String.t()) ::
          :authorized | :unauthorized | :pending_approval
  defp check_tool_authorization(agent_id, tool_name) do
    if Code.ensure_loaded?(Arbor.Security) do
      resource = "arbor://actions/execute/#{tool_name}"

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(Arbor.Security, :authorize, [agent_id, resource, :execute, []]) do
        {:ok, :authorized} ->
          :authorized

        {:ok, :pending_approval, _proposal_id} ->
          Logger.debug(
            "Tool #{tool_name} requires approval for agent #{agent_id}, " <>
              "excluding from available tools"
          )

          :pending_approval

        {:error, reason} ->
          Logger.debug(
            "Tool authorization denied for #{tool_name}, agent #{agent_id}: #{inspect(reason)}"
          )

          :unauthorized
      end
    else
      Logger.debug(
        "Arbor.Security not loaded — tool authorization check skipped for #{tool_name}"
      )

      :authorized
    end
  rescue
    e ->
      Logger.warning(
        "Tool authorization check failed for #{tool_name}: #{inspect(e)}, defaulting to deny"
      )

      :unauthorized
  catch
    :exit, reason ->
      Logger.warning(
        "Tool authorization check exited for #{tool_name}: #{inspect(reason)}, defaulting to deny"
      )

      :unauthorized
  end

  # Emit a signal when tools are denied due to authorization failure.
  # Useful for security observability and audit trails.
  defp emit_tool_authorization_denied(agent_id, denied_tool_names) do
    Arbor.Signals.emit(:security, :tool_authorization_denied, %{
      agent_id: agent_id,
      denied_tools: denied_tool_names,
      denied_count: length(denied_tool_names),
      source: :generate_text_with_tools
    })
  rescue
    _ -> :ok
  end

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

  # Note: API key resolution is handled by ReqLLM.Keys.get/2 which checks
  # (1) opts[:api_key], (2) Application.get_env(:req_llm, ...), (3) System.get_env.
  # We no longer pre-populate Application env from System env (was a TOCTOU race).
  # For generate_text_via_api, the key flows via maybe_add_api_key/2 → opts[:api_key].
  # For generate_text_with_tools, ReqLLM resolves from System.get_env directly.

  # ── Signal emission for tool requests ──

  defp emit_tool_request_started(provider, model, prompt_length) do
    Arbor.Signals.emit(:ai, :tool_request_started, %{
      provider: provider,
      model: model,
      prompt_length: prompt_length,
      backend: :api_with_tools
    })
  rescue
    _ -> :ok
  end

  defp emit_tool_request_completed(provider, model, duration_ms, response) do
    Arbor.Signals.emit(:ai, :tool_request_completed, %{
      provider: provider,
      model: model,
      duration_ms: duration_ms,
      turns: response[:turns],
      tool_calls_count: length(response[:tool_calls] || []),
      backend: :api_with_tools
    })
  rescue
    _ -> :ok
  end

  defp emit_tool_request_failed(provider, model, reason) do
    Arbor.Signals.emit(:ai, :tool_request_failed, %{
      provider: provider,
      model: model,
      error: inspect(reason),
      backend: :api_with_tools
    })
  rescue
    _ -> :ok
  end

  # ── Budget/stats for tool requests ──

  defp record_tool_budget_usage(provider, opts, response) do
    if BudgetTracker.started?() do
      usage = response[:usage] || %{}

      BudgetTracker.record_usage(provider, %{
        input_tokens: usage[:input_tokens] || 0,
        output_tokens: usage[:output_tokens] || 0,
        model: Keyword.get(opts, :model, "unknown")
      })
    end
  rescue
    _ -> :ok
  end

  defp record_tool_usage_stats_success(provider, opts, response, latency_ms) do
    if UsageStats.started?() do
      usage = response[:usage] || %{}

      UsageStats.record_success(provider, %{
        model: Keyword.get(opts, :model, "unknown"),
        input_tokens: usage[:input_tokens] || 0,
        output_tokens: usage[:output_tokens] || 0,
        latency_ms: latency_ms,
        backend: :api_with_tools
      })
    end
  rescue
    _ -> :ok
  end

  defp record_tool_usage_stats_failure(provider, opts, error, latency_ms) do
    if UsageStats.started?() do
      UsageStats.record_failure(provider, %{
        model: Keyword.get(opts, :model, "unknown"),
        error: inspect(error),
        latency_ms: latency_ms,
        backend: :api_with_tools
      })
    end
  rescue
    _ -> :ok
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

  defp format_api_response(response, provider, model) do
    ResponseNormalizer.format_api_response(response, provider, model)
  end

  # ===========================================================================
  # Private Helpers - Embedding
  # ===========================================================================

  # Resolve which embedding provider module to use.
  #
  # Priority:
  # 1. Explicit :provider opt → use that provider directly
  # 2. Router.route_embedding/1 → map backend atom to module
  # 3. TestEmbedding fallback if embedding_test_fallback: true
  @spec resolve_embedding_provider(keyword()) ::
          {:ok, {module(), keyword()}} | {:error, term()}
  defp resolve_embedding_provider(opts) do
    case Keyword.get(opts, :provider) do
      nil ->
        resolve_via_router(opts)

      provider when is_atom(provider) ->
        case provider_to_module(provider) do
          {:ok, module} -> {:ok, {module, [provider: provider]}}
          :error -> {:error, {:unknown_provider, provider}}
        end
    end
  end

  defp resolve_via_router(opts) do
    case Router.route_embedding(opts) do
      {:ok, {backend, model}} ->
        case provider_to_module(backend) do
          {:ok, module} ->
            {:ok, {module, [provider: backend, model: model]}}

          :error ->
            {:error, {:unknown_provider, backend}}
        end

      {:error, :no_embedding_providers} ->
        maybe_test_fallback()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_test_fallback do
    if Application.get_env(:arbor_ai, :embedding_test_fallback, false) do
      {:ok, {TestEmbedding, [provider: :test]}}
    else
      {:error, :no_embedding_providers}
    end
  end

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
