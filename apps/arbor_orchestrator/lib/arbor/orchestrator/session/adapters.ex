defmodule Arbor.Orchestrator.Session.Adapters do
  @moduledoc """
  Factory that builds adapter function maps for Session GenServer injection.

  Each adapter bridges a session operation to real Arbor infrastructure using
  runtime bridges (`Code.ensure_loaded?/1` + `apply/3`). The orchestrator has
  zero compile-time dependencies on other Arbor libraries — all cross-library
  calls go through `bridge/4`.

  ## Usage

      adapters = Adapters.build(agent_id: "agent_abc123")

      # Inject into Session start_link:
      Session.start_link(
        session_id: "session-1",
        agent_id: "agent_abc123",
        trust_tier: :established,
        adapters: adapters,
        turn_dot: "specs/pipelines/session/turn.dot",
        heartbeat_dot: "specs/pipelines/session/heartbeat.dot"
      )

  ## Adapter Contract

  The `build/1` function returns a map of adapter functions matching the
  `SessionHandler` adapter contract:

    * `:llm_call`           -- `fn messages, mode, call_opts -> {:ok, response} | {:error, reason}`
    * `:tool_dispatch`      -- `fn tool_calls, agent_id -> {:ok, results} | {:error, reason}`
    * `:memory_recall`      -- `fn agent_id, query -> {:ok, memories} | {:error, reason}`
    * `:recall_goals`       -- `fn agent_id -> {:ok, goals} | {:error, reason}`
    * `:recall_intents`     -- `fn agent_id -> {:ok, intents} | {:error, reason}`
    * `:recall_beliefs`     -- `fn agent_id -> {:ok, beliefs_map} | {:error, reason}`
    * `:memory_update`      -- `fn agent_id, turn_data -> :ok`
    * `:checkpoint`         -- `fn session_id, turn_count, snapshot -> :ok`
    * `:route_actions`      -- `fn actions, agent_id -> :ok`
    * `:route_intents`      -- `fn agent_id -> :ok`
    * `:update_goals`       -- `fn goal_updates, new_goals, agent_id -> :ok`
    * `:background_checks`  -- `fn agent_id -> results`

  ## Design

  - **No GenServer, no state** — pure factory function returning closures
  - **Runtime bridges** — `Code.ensure_loaded?` before every `apply/3`
  - **Graceful degradation** — missing modules return sensible defaults
  - **Fail-loud on errors** — adapter bodies use `try/catch :exit` for
    GenServer calls that might fail, but propagate real errors
  - **Single completion only** — the LLM adapter does ONE completion per call;
    the turn graph handles tool loops via graph edges
  """

  require Logger

  alias Arbor.Orchestrator.UnifiedLLM.{Client, Message, Request, Tool}

  @doc """
  Build a map of adapter functions for Session injection.

  ## Options

    * `:agent_id` (required) — the agent these adapters serve
    * `:trust_tier` (default `:established`) — authorization context
    * `:llm_provider` (default `nil`) — override UnifiedLLM provider
    * `:llm_model` (default `nil`) — override model
    * `:llm_client` (default `nil`) — pre-built `Client` struct; otherwise
      uses `Client.default_client/0` with fallback to `nil`
    * `:tools` (default `[]`) — list of `Tool` structs for the agent
    * `:system_prompt` (default `nil`) — base system prompt for LLM calls
    * `:config` (default `%{}`) — additional session config

  ## Returns

  A map of adapter functions matching the `SessionHandler` adapter contract.
  """
  @spec build(keyword()) :: map()
  def build(opts \\ []) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    trust_tier = Keyword.get(opts, :trust_tier, :established)
    llm_provider = Keyword.get(opts, :llm_provider)
    llm_model = Keyword.get(opts, :llm_model)
    tools = Keyword.get(opts, :tools, [])
    system_prompt = Keyword.get(opts, :system_prompt)
    config = Keyword.get(opts, :config, %{})

    # Resolve LLM client at build time so misconfiguration is caught early.
    # If default_client() raises (no provider configured), fall back to nil.
    # The llm_call adapter will return {:error, :no_llm_client} at call time.
    client = resolve_client(opts)

    %{
      llm_call: build_llm_call(client, llm_provider, llm_model, tools, system_prompt, config),
      tool_dispatch: build_tool_dispatch(agent_id, trust_tier),
      memory_recall: build_memory_recall(),
      recall_goals: build_recall_goals(),
      recall_intents: build_recall_intents(),
      recall_beliefs: build_recall_beliefs(),
      memory_update: build_memory_update(),
      checkpoint: build_checkpoint(),
      route_actions: build_route_actions(),
      route_intents: build_route_intents(),
      update_goals: build_update_goals(),
      background_checks: build_background_checks(),
      trust_tier_resolver: build_trust_tier_resolver()
    }
  end

  # ── LLM Call ────────────────────────────────────────────────────────
  #
  # SINGLE completion only. The turn graph handles tool loops via edges.
  # SessionHandler calls: llm_call.(messages, mode, call_opts)
  # Returns: {:ok, %{content: text}} | {:ok, %{tool_calls: calls}} | {:error, reason}

  defp build_llm_call(client, llm_provider, llm_model, tools, system_prompt, config) do
    fn messages, _mode, call_opts ->
      if is_nil(client) do
        {:error, :no_llm_client}
      else
        try do
          do_llm_call(client, messages, call_opts, %{
            provider: llm_provider,
            model: llm_model,
            tools: tools,
            system_prompt: system_prompt,
            config: config
          })
        catch
          :exit, reason -> {:error, {:llm_exit, reason}}
        end
      end
    end
  end

  defp do_llm_call(client, messages, call_opts, adapter_opts) do
    request = build_request(client, messages, call_opts, adapter_opts)

    case Client.complete(client, request) do
      {:ok, response} -> format_llm_response(response)
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_request(client, messages, call_opts, adapter_opts) do
    %Request{
      provider: to_string(adapter_opts.provider || client.default_provider),
      model: resolve_model(adapter_opts) || "",
      messages: build_messages(messages, adapter_opts.system_prompt),
      tools: normalize_tools(adapter_opts.tools),
      temperature: resolve_opt(call_opts, adapter_opts.config, :temperature, "temperature"),
      max_tokens: resolve_opt(call_opts, adapter_opts.config, :max_tokens, "max_tokens")
    }
  end

  # Normalize tools from various formats:
  # - Tool structs → as_definition
  # - Action modules (atoms with to_tool/0) → convert then as_definition
  # - Maps with :name → pass through as_definition
  defp normalize_tools(tools) do
    tools
    |> List.wrap()
    |> Enum.map(&normalize_one_tool/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_one_tool(%Tool{} = tool), do: Tool.as_definition(tool)

  defp normalize_one_tool(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :to_tool, 0) do
      spec = module.to_tool()

      Tool.as_definition(
        struct(Tool,
          name: spec[:name] || Map.get(spec, :name, ""),
          description: spec[:description] || Map.get(spec, :description),
          input_schema: spec[:parameters_schema] || Map.get(spec, :parameters_schema, %{})
        )
      )
    end
  rescue
    _ -> nil
  end

  defp normalize_one_tool(%{name: _} = map), do: Tool.as_definition(struct(Tool, map))
  defp normalize_one_tool(_), do: nil

  defp resolve_model(adapter_opts) do
    adapter_opts.model ||
      Map.get(adapter_opts.config, :model) ||
      Map.get(adapter_opts.config, "model")
  end

  defp resolve_opt(call_opts, config, atom_key, string_key) do
    Map.get(call_opts, atom_key) ||
      Map.get(config, atom_key) ||
      Map.get(config, string_key)
  end

  defp build_messages(messages, nil), do: convert_messages(messages)

  defp build_messages(messages, system_prompt) when is_binary(system_prompt) do
    [Message.new(:system, system_prompt) | convert_messages(messages)]
  end

  defp convert_messages(messages) when is_list(messages) do
    Enum.map(messages, fn
      %Message{} = msg ->
        msg

      msg when is_map(msg) ->
        role = msg_role(msg)
        content = Map.get(msg, "content") || Map.get(msg, :content, "")
        Message.new(role, content)
    end)
  end

  defp convert_messages(_), do: []

  defp msg_role(msg) do
    role = Map.get(msg, "role") || Map.get(msg, :role, "user")

    case to_string(role) do
      "system" -> :system
      "assistant" -> :assistant
      "tool" -> :tool
      "developer" -> :developer
      _ -> :user
    end
  end

  defp format_llm_response(response) do
    tool_calls = extract_tool_calls(response)

    if tool_calls != [] do
      {:ok, %{tool_calls: tool_calls}}
    else
      {:ok, %{content: response.text || ""}}
    end
  end

  defp extract_tool_calls(response) do
    # First try parsed content_parts (reliable — each adapter already parses tool calls)
    from_parts =
      case Map.get(response, :content_parts) do
        parts when is_list(parts) ->
          parts
          |> Enum.filter(&(Map.get(&1, :kind) == :tool_call))
          |> Enum.map(fn part ->
            %{
              "id" => Map.get(part, :id, "call"),
              "name" => Map.get(part, :name, "unknown"),
              "arguments" => Map.get(part, :arguments, %{})
            }
          end)

        _ ->
          []
      end

    if from_parts != [] do
      from_parts
    else
      # Fallback: check raw response (for mock responses or non-standard providers)
      case Map.get(response, :raw) do
        raw when is_map(raw) ->
          calls = Map.get(raw, "tool_calls") || Map.get(raw, :tool_calls) || []
          if is_list(calls), do: calls, else: []

        _ ->
          []
      end
    end
  end

  # ── Tool Dispatch ───────────────────────────────────────────────────
  #
  # Dispatches tool calls through the agent's executor.
  # SessionHandler calls: tool_dispatch.(tool_calls, agent_id)
  # Returns: {:ok, results} where results is a list of result strings.

  defp build_tool_dispatch(agent_id, trust_tier) do
    fn tool_calls, call_agent_id ->
      effective_agent_id = call_agent_id || agent_id

      try do
        dispatch_tools(tool_calls, effective_agent_id, trust_tier)
      catch
        :exit, reason -> {:error, {:tool_dispatch_exit, reason}}
      end
    end
  end

  defp dispatch_tools(tool_calls, agent_id, trust_tier) do
    results = Enum.map(tool_calls, &dispatch_single_tool(&1, agent_id, trust_tier))
    {:ok, results}
  end

  defp dispatch_single_tool(call, agent_id, trust_tier) do
    name = Map.get(call, "name") || Map.get(call, :name, "unknown")
    args = Map.get(call, "arguments") || Map.get(call, :arguments, %{})
    bridge_args = [name, args, agent_id, [trust_tier: trust_tier]]

    case bridge(Arbor.Agent.ToolBridge, :authorize_and_execute, bridge_args, nil) do
      {:ok, result} when is_binary(result) -> result
      {:ok, result} -> inspect(result)
      {:error, reason} -> "error: #{inspect(reason)}"
      nil -> "tool_dispatch_unavailable: #{name} called with #{inspect(args)}"
    end
  end

  # ── Memory Recall ───────────────────────────────────────────────────
  #
  # SessionHandler calls: memory_recall.(agent_id, query)
  # Returns: {:ok, memories} | {:error, reason}

  defp build_memory_recall do
    fn agent_id, query ->
      case bridge(Arbor.Memory, :recall, [agent_id, query], {:ok, []}) do
        {:ok, memories} -> {:ok, memories}
        {:error, reason} -> {:error, reason}
        memories when is_list(memories) -> {:ok, memories}
        other -> {:ok, List.wrap(other)}
      end
    end
  end

  # ── Memory Update ───────────────────────────────────────────────────
  #
  # SessionHandler calls: memory_update.(agent_id, turn_data)
  # Returns: :ok

  defp build_memory_update do
    fn agent_id, turn_data ->
      bridge(Arbor.Memory, :index_memory_notes, [agent_id, turn_data], :ok)
      :ok
    end
  end

  # ── Checkpoint ──────────────────────────────────────────────────────
  #
  # SessionHandler calls: checkpoint.(session_id, turn_count, snapshot)
  # Returns: :ok

  defp build_checkpoint do
    fn session_id, turn_count, snapshot ->
      bridge(
        Arbor.Persistence.Checkpoint,
        :write,
        [session_id, snapshot, [turn: turn_count]],
        :ok
      )

      :ok
    end
  end

  # ── Route Actions ───────────────────────────────────────────────────
  #
  # SessionHandler calls: route_actions.(actions, agent_id)
  # Returns: :ok

  defp build_route_actions do
    fn actions, agent_id ->
      bridge(
        Arbor.Actions,
        :execute_batch,
        [actions, [agent_id: agent_id]],
        :ok
      )

      :ok
    end
  end

  # ── Update Goals ────────────────────────────────────────────────────
  #
  # SessionHandler calls: update_goals.(goal_updates, new_goals, agent_id)
  # Returns: :ok

  defp build_update_goals do
    fn goal_updates, new_goals, agent_id ->
      goal_store = Arbor.Memory.GoalStore

      Enum.each(List.wrap(goal_updates), fn update ->
        bridge(goal_store, :update_goal, [agent_id, update], :ok)
      end)

      Enum.each(List.wrap(new_goals), fn goal_desc ->
        bridge(goal_store, :add_goal, [agent_id, goal_desc, []], :ok)
      end)

      :ok
    end
  end

  # ── Background Checks ──────────────────────────────────────────────
  #
  # SessionHandler calls: background_checks.(agent_id)
  # Returns: results map

  defp build_background_checks do
    fn agent_id ->
      bridge(Arbor.Agent.BackgroundChecks, :run, [agent_id, []], %{})
    end
  end

  # ── Trust Tier Resolver ─────────────────────────────────────────────
  #
  # Session.init calls: trust_tier_resolver.(agent_id)
  # Returns: {:ok, tier_atom}

  defp build_trust_tier_resolver do
    fn agent_id ->
      case bridge(Arbor.Trust, :get_tier, [agent_id], nil) do
        {:ok, tier} -> {:ok, tier}
        nil -> {:ok, :established}
        other -> {:ok, other}
      end
    end
  end

  # ── Recall Goals ────────────────────────────────────────────────────
  #
  # SessionHandler calls: recall_goals.(agent_id)
  # Returns: {:ok, goals_list}

  defp build_recall_goals do
    fn agent_id ->
      case bridge(Arbor.Memory.GoalStore, :get_active_goals, [agent_id], []) do
        {:ok, goals} -> {:ok, goals}
        goals when is_list(goals) -> {:ok, goals}
        _ -> {:ok, []}
      end
    end
  end

  # ── Recall Intents ──────────────────────────────────────────────────
  #
  # SessionHandler calls: recall_intents.(agent_id)
  # Returns: {:ok, intents_list}

  defp build_recall_intents do
    fn agent_id ->
      case bridge(Arbor.Memory.IntentStore, :pending_intents_for_agent, [agent_id], []) do
        {:ok, intents} -> {:ok, intents}
        intents when is_list(intents) -> {:ok, intents}
        _ -> {:ok, []}
      end
    end
  end

  # ── Recall Beliefs ──────────────────────────────────────────────────
  #
  # SessionHandler calls: recall_beliefs.(agent_id)
  # Returns: {:ok, beliefs_map}

  defp build_recall_beliefs do
    fn agent_id ->
      wm = bridge(Arbor.Memory, :load_working_memory, [agent_id], %{})
      beliefs = if is_map(wm), do: wm, else: %{}
      {:ok, beliefs}
    end
  end

  # ── Route Intents ───────────────────────────────────────────────────
  #
  # SessionHandler calls: route_intents.(agent_id)
  # Returns: :ok

  defp build_route_intents do
    fn agent_id ->
      bridge(
        Arbor.Agent.ExecutorIntegration,
        :route_pending_intentions,
        [agent_id],
        :ok
      )

      :ok
    end
  end

  # ── Private helpers ─────────────────────────────────────────────────

  @doc false
  @spec bridge(module(), atom(), [term()], term()) :: term()
  def bridge(module, function, args, default) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(args)) do
      try do
        apply(module, function, args)
      catch
        :exit, reason ->
          Logger.warning(
            "[Adapters] #{inspect(module)}.#{function}/#{length(args)} exited: #{inspect(reason)}"
          )

          default
      end
    else
      default
    end
  end

  defp resolve_client(opts) do
    case Keyword.get(opts, :llm_client) do
      %Client{} = client ->
        client

      nil ->
        try do
          Client.default_client()
        catch
          kind, reason ->
            Logger.info(
              "[Adapters] No LLM client available (#{kind}: #{inspect(reason)}). " <>
                "LLM calls will return {:error, :no_llm_client}."
            )

            nil
        end

      _other ->
        nil
    end
  rescue
    e ->
      Logger.info(
        "[Adapters] Failed to resolve LLM client: #{Exception.message(e)}. " <>
          "LLM calls will return {:error, :no_llm_client}."
      )

      nil
  end
end
