defmodule Arbor.Memory.ReflectionProcessor do
  @moduledoc """
  Structured self-analysis for agents.

  ReflectionProcessor enables agents to perform structured reflection on their
  behavior, decisions, and growth. It supports two modes:

  - **`reflect/3`** — Lightweight reflection with a specific prompt. Uses the
    configured LLM module (or MockLLM in tests) to generate insights.

  - **`deep_reflect/2`** — Full pipeline reflection that evaluates goals,
    integrates knowledge graph updates, detects insights, processes learnings,
    and runs post-reflection decay. This is the trust-arbor equivalent of
    arbor_seed's `perform_reflection/2`.

  ## LLM Integration

  Production code calls `Arbor.AI.generate_text/2` directly. For tests, inject
  a mock via the `:reflection_llm_module` config:

      config :arbor_memory, :reflection_llm_module, MyApp.MockLLM

  ## Usage

      # Lightweight reflection
      {:ok, reflection} = ReflectionProcessor.reflect("agent_001", "What patterns do I see?")

      # Full pipeline reflection
      {:ok, result} = ReflectionProcessor.deep_reflect("agent_001")

      # Periodic reflection (called during heartbeats)
      {:ok, reflection} = ReflectionProcessor.periodic_reflection("agent_001")

      # Get past reflections
      {:ok, history} = ReflectionProcessor.history("agent_001")
  """

  alias Arbor.Memory.{
    Events,
    GoalStore,
    IdentityConsolidator,
    Signals,
    Thinking,
    WorkingMemory
  }

  alias Arbor.Memory.Reflection.{GoalProcessor, PromptBuilder, ResponseParser}
  alias Arbor.Memory.ReflectionProcessor.Integrations

  require Logger

  # Backward-compat delegations for extracted modules (tests call these directly)
  @doc false
  defdelegate parse_reflection_response(response), to: ResponseParser
  @doc false
  defdelegate build_reflection_prompt(context), to: PromptBuilder
  @doc false
  defdelegate process_goal_updates(agent_id, goal_updates), to: GoalProcessor
  @doc false
  defdelegate process_new_goals(agent_id, new_goals), to: GoalProcessor
  @doc false
  defdelegate integrate_insights(agent_id, insights), to: Integrations
  @doc false
  defdelegate integrate_learnings(agent_id, learnings), to: Integrations
  @doc false
  defdelegate integrate_knowledge_graph(agent_id, nodes, edges), to: Integrations
  @doc false
  defdelegate process_relationships(agent_id, relationships), to: Integrations

  @type reflection :: %{
          id: String.t(),
          agent_id: String.t(),
          prompt: String.t(),
          analysis: String.t(),
          insights: [String.t()],
          self_assessment: map(),
          timestamp: DateTime.t(),
          goal_updates: [map()] | nil,
          new_goals: [map()] | nil,
          knowledge_nodes: [map()] | nil,
          knowledge_edges: [map()] | nil,
          learnings: [map()] | nil,
          duration_ms: non_neg_integer() | nil
        }

  # ETS table for reflection storage
  @reflections_ets :arbor_reflections

  # Maximum reflections to store per agent
  @max_reflections 100

  # Default minimum interval between reflections (10 minutes)
  @default_reflection_interval_ms 600_000

  # Default event count threshold to trigger reflection
  @default_signal_threshold 50

  # ============================================================================
  # Main API
  # ============================================================================

  @doc """
  Perform a reflection with a specific prompt.

  Builds a reflection context from the agent's SelfKnowledge and recent activity,
  calls the configured LLM module, parses the structured response, extracts
  insights, and stores the reflection.

  ## Options

  - `:include_self_knowledge` - Include SelfKnowledge in context (default: true)
  - `:include_recent_activity` - Include recent activity summary (default: true)
  - `:provider` - LLM provider override
  - `:model` - LLM model override

  ## Examples

      {:ok, reflection} = ReflectionProcessor.reflect("agent_001", "How can I improve?")
  """
  @spec reflect(String.t(), String.t(), keyword()) :: {:ok, reflection()} | {:error, term()}
  def reflect(agent_id, prompt, opts \\ []) do
    include_sk = Keyword.get(opts, :include_self_knowledge, true)
    include_activity = Keyword.get(opts, :include_recent_activity, true)

    # Build context
    context = build_reflection_context(agent_id, include_sk, include_activity)

    # Get LLM module (MockLLM only used if explicitly configured, e.g. in tests)
    llm_module = get_llm_module()

    # Call LLM
    case llm_module.reflect(prompt, context) do
      {:ok, response} ->
        reflection = %{
          id: generate_id(),
          agent_id: agent_id,
          prompt: prompt,
          analysis: response.analysis,
          insights: response.insights,
          self_assessment: response.self_assessment,
          timestamp: DateTime.utc_now(),
          goal_updates: nil,
          new_goals: nil,
          knowledge_nodes: nil,
          knowledge_edges: nil,
          learnings: nil,
          duration_ms: nil
        }

        # Store reflection
        store_reflection(agent_id, reflection)

        # Emit events
        Signals.emit_cognitive_adjustment(agent_id, :reflection_completed, %{
          reflection_id: reflection.id,
          insight_count: length(reflection.insights)
        })

        Events.record_reflection_completed(agent_id, %{
          reflection_id: reflection.id,
          prompt: prompt,
          insight_count: length(reflection.insights)
        })

        {:ok, reflection}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Perform a periodic reflection based on recent activity.

  Called during deeper heartbeats to reflect on recent work.
  Uses a standardized prompt focused on patterns and growth.

  ## Examples

      {:ok, reflection} = ReflectionProcessor.periodic_reflection("agent_001")
  """
  @spec periodic_reflection(String.t(), keyword()) ::
          {:ok, reflection()} | {:ok, :skipped} | {:error, term()}
  def periodic_reflection(agent_id, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    if force or should_reflect?(agent_id, opts) do
      prompt = """
      Reflect on my recent activity and patterns. Consider:
      - What tasks have I been focused on?
      - What patterns do I notice in my approach?
      - What have I learned or improved?
      - Are there areas where I could do better?
      """

      reflect(agent_id, prompt)
    else
      {:ok, :skipped}
    end
  end

  @doc """
  Perform a deep reflection with full goal evaluation, knowledge graph
  integration, and insight detection.

  This is the full pipeline equivalent of arbor_seed's `perform_reflection/2`:
  1. Build deep context (self-knowledge, goals, KG, working memory, thinking)
  2. Generate structured JSON prompt for LLM
  3. Call LLM and parse JSON response
  4. Process goal updates (progress, status changes)
  5. Create new goals from LLM suggestions
  6. Integrate insights into working memory
  7. Integrate learnings by category
  8. Update knowledge graph with new nodes and edges
  9. Run post-reflection decay/consolidation

  ## Options

  - `:provider` - LLM provider override
  - `:model` - LLM model override

  ## Examples

      {:ok, result} = ReflectionProcessor.deep_reflect("agent_001")
  """
  @spec deep_reflect(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def deep_reflect(agent_id, opts \\ []) do
    start_time = System.monotonic_time(:millisecond)

    Signals.emit_reflection_started(agent_id, %{type: :deep_reflect})

    with {:ok, context} <- build_deep_context(agent_id, opts),
         {:ok, prompt} <- {:ok, PromptBuilder.build_reflection_prompt(context)},
         {:ok, response_text} <- call_llm(prompt, Keyword.put(opts, :agent_id, agent_id)),
         {:ok, parsed} <- ResponseParser.parse_reflection_response(response_text) do
      # Integrate results into subsystems
      GoalProcessor.process_goal_updates(agent_id, parsed.goal_updates)
      GoalProcessor.process_new_goals(agent_id, parsed.new_goals)
      Integrations.integrate_insights(agent_id, parsed.insights)
      Integrations.integrate_learnings(agent_id, parsed.learnings)
      Integrations.integrate_knowledge_graph(agent_id, parsed.knowledge_nodes, parsed.knowledge_edges)
      Integrations.process_relationships(agent_id, parsed.relationships)
      Integrations.trigger_insight_detection(agent_id)
      Integrations.store_self_insight_suggestions(agent_id, parsed.self_insight_suggestions)
      Integrations.add_goals_to_knowledge_graph(agent_id, Map.get(context, :goals, []))
      archived_count = Integrations.run_post_reflection_decay(agent_id)

      duration = System.monotonic_time(:millisecond) - start_time

      result = %{
        goal_updates: parsed.goal_updates,
        new_goals: parsed.new_goals,
        insights: parsed.insights,
        learnings: parsed.learnings,
        knowledge_nodes_added: length(parsed.knowledge_nodes),
        knowledge_edges_added: length(parsed.knowledge_edges),
        self_insight_suggestions: parsed.self_insight_suggestions,
        insight_suggestions: parsed.self_insight_suggestions,
        knowledge_archived: archived_count,
        relationship_updates: length(parsed.relationships),
        duration_ms: duration
      }

      # Store as reflection for history
      history_entry = build_history_entry(agent_id, "deep_reflect", result)
      store_reflection(agent_id, history_entry)

      Signals.emit_reflection_completed(agent_id, %{
        duration_ms: duration,
        insight_count: length(parsed.insights),
        goal_update_count: length(parsed.goal_updates)
      })

      Events.record_reflection_completed(agent_id, %{
        reflection_id: history_entry.id,
        prompt: "deep_reflect",
        insight_count: length(parsed.insights),
        duration_ms: duration
      })

      {:ok, result}
    else
      {:error, _} = error ->
        duration = System.monotonic_time(:millisecond) - start_time

        Signals.emit_reflection_completed(agent_id, %{
          duration_ms: duration,
          insight_count: 0,
          goal_update_count: 0,
          error: true
        })

        error
    end
  end

  @doc """
  Get reflection history for an agent.

  ## Options

  - `:limit` - Maximum reflections to return (default: 10)
  - `:since` - Only reflections after this DateTime

  ## Examples

      {:ok, reflections} = ReflectionProcessor.history("agent_001")
      {:ok, recent} = ReflectionProcessor.history("agent_001", limit: 5)
  """
  @spec history(String.t(), keyword()) :: {:ok, [reflection()]}
  def history(agent_id, opts \\ []) do
    ensure_ets_exists()
    limit = Keyword.get(opts, :limit, 10)
    since = Keyword.get(opts, :since)

    reflections =
      case :ets.lookup(@reflections_ets, agent_id) do
        [{^agent_id, stored}] -> stored
        [] -> []
      end

    filtered =
      reflections
      |> maybe_filter_since(since)
      |> Enum.take(limit)

    {:ok, filtered}
  end

  @doc """
  Convenience wrapper that checks `should_reflect?/2` and runs `deep_reflect/2`
  only when reflection is needed.

  ## Options

  - `:force` - Force reflection regardless of gating (default: false)
  - All options from `deep_reflect/2` and `should_reflect?/2`

  ## Examples

      {:ok, result} = ReflectionProcessor.maybe_reflect("agent_001")
      {:ok, :skipped} = ReflectionProcessor.maybe_reflect("agent_001")
  """
  @spec maybe_reflect(String.t(), keyword()) :: {:ok, map()} | {:ok, :skipped} | {:error, term()}
  def maybe_reflect(agent_id, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    if force or should_reflect?(agent_id, opts) do
      deep_reflect(agent_id, opts)
    else
      {:ok, :skipped}
    end
  end

  @doc """
  Force an immediate deep reflection, bypassing gating checks.

  This is an alias for `deep_reflect/2` matching arbor_seed's `reflect_now/2` API.

  ## Examples

      {:ok, result} = ReflectionProcessor.reflect_now("agent_001")
  """
  @spec reflect_now(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def reflect_now(agent_id, opts \\ []), do: deep_reflect(agent_id, opts)

  @doc """
  Returns the default reflection configuration.

  ## Examples

      config = ReflectionProcessor.default_config()
      # => %{min_reflection_interval: 600_000, signal_threshold: 50, ...}
  """
  @spec default_config() :: map()
  def default_config do
    %{
      min_reflection_interval: @default_reflection_interval_ms,
      signal_threshold: @default_signal_threshold,
      llm_provider: Application.get_env(:arbor_memory, :reflection_provider),
      reflection_model: Application.get_env(:arbor_memory, :reflection_model)
    }
  end

  @doc """
  Check whether a reflection should be triggered based on time and activity.

  Returns `true` if enough time has passed since the last reflection OR
  enough events have occurred since the last reflection.

  ## Options

  - `:interval_ms` - Minimum ms between reflections (default: from config or 600_000)
  - `:threshold` - Event count threshold (default: from config or 50)

  ## Examples

      true = ReflectionProcessor.should_reflect?("agent_001")
      false = ReflectionProcessor.should_reflect?("agent_001", interval_ms: 3_600_000)
  """
  @spec should_reflect?(String.t(), keyword()) :: boolean()
  def should_reflect?(agent_id, opts \\ []) do
    min_interval =
      Keyword.get(
        opts,
        :interval_ms,
        Application.get_env(:arbor_memory, :reflection_interval_ms, @default_reflection_interval_ms)
      )

    threshold =
      Keyword.get(
        opts,
        :threshold,
        Application.get_env(:arbor_memory, :reflection_signal_threshold, @default_signal_threshold)
      )

    time_elapsed = time_since_last_reflection(agent_id)
    time_triggered = time_elapsed == :infinity or time_elapsed >= min_interval

    event_triggered = event_count_since_last_reflection(agent_id) >= threshold

    time_triggered or event_triggered
  end

  # ============================================================================
  # Deep Context Building
  # ============================================================================

  @doc false
  def build_deep_context(agent_id, _opts) do
    sk = IdentityConsolidator.get_self_knowledge(agent_id)

    # Include active + blocked goals (not achieved/abandoned)
    goals =
      GoalStore.get_all_goals(agent_id)
      |> Enum.filter(&(&1.status in [:active, :blocked]))

    {:ok,
     %{
       agent_id: agent_id,
       self_knowledge: sk,
       self_knowledge_text: format_self_knowledge_or_default(sk),
       goals: goals,
       goals_text: PromptBuilder.format_goals_for_prompt(goals),
       knowledge_graph_text: get_knowledge_text(agent_id),
       working_memory_text: get_working_memory_text(agent_id),
       recent_thinking_text: format_recent_thinking(agent_id),
       recent_activity_text: get_recent_activity_text(agent_id)
     }}
  end

  defp format_self_knowledge_or_default(nil), do: "(No self-knowledge established yet)"
  defp format_self_knowledge_or_default(sk), do: PromptBuilder.format_self_knowledge(sk)

  defp get_knowledge_text(agent_id) do
    case get_knowledge_summary(agent_id) do
      {:ok, text} -> text
      _ -> "(No knowledge graph)"
    end
  end

  defp get_working_memory_text(agent_id) do
    case Arbor.Memory.get_working_memory(agent_id) do
      nil -> ""
      wm -> WorkingMemory.to_prompt_text(wm)
    end
  end

  defp format_recent_thinking(agent_id) do
    case Thinking.recent_thinking(agent_id, limit: 10) do
      [] ->
        "(No recent thinking entries)"

      entries ->
        Enum.map_join(entries, "\n", &format_thinking_entry/1)
    end
  end

  defp format_thinking_entry(entry) do
    sig = if entry.significant, do: " [SIGNIFICANT]", else: ""
    "- #{entry.text}#{sig}"
  end

  defp get_recent_activity_text(agent_id) do
    case Events.get_recent(agent_id, 50) do
      {:ok, []} ->
        "(No recent activity)"

      {:ok, events} ->
        Enum.map_join(events, "\n", &format_event_for_context/1)

      {:error, _} ->
        "(No recent activity)"
    end
  end

  defp format_event_for_context(event) do
    data_text =
      case event.data do
        data when is_map(data) and map_size(data) > 0 ->
          data
          |> Enum.take(4)
          |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{truncate(inspect(v), 100)}" end)

        _ ->
          ""
      end

    "- [#{event.type}] #{data_text}"
  end

  # ============================================================================
  # LLM Call
  # ============================================================================

  @doc false
  def call_llm(prompt, opts) do
    case Application.get_env(:arbor_memory, :reflection_llm_module) do
      nil -> call_arbor_ai(prompt, opts)
      mock_module -> call_mock_llm(mock_module, prompt, opts)
    end
  end

  defp call_mock_llm(mock_module, prompt, opts) do
    if function_exported?(mock_module, :generate_text, 2) do
      mock_module.generate_text(prompt, opts)
    else
      call_mock_reflect_fallback(mock_module, prompt)
    end
  end

  defp call_mock_reflect_fallback(mock_module, prompt) do
    case mock_module.reflect(prompt, %{}) do
      {:ok, %{analysis: text}} -> {:ok, text}
      {:error, _} = err -> err
    end
  end

  defp call_arbor_ai(prompt, opts) do
    if Code.ensure_loaded?(Arbor.AI) do
      start_time = System.monotonic_time(:millisecond)
      agent_id = opts[:agent_id] || "unknown"

      provider =
        opts[:provider] ||
          Application.get_env(:arbor_memory, :reflection_provider, :anthropic)

      model =
        opts[:model] ||
          Application.get_env(:arbor_memory, :reflection_model, "claude-3-5-haiku-latest")

      system_prompt = """
      You are a reflective AI examining your recent experiences to extract
      insights, learnings, and relationship understanding. Be thoughtful and specific.
      Respond only in valid JSON format.
      """

      llm_opts = [
        system_prompt: system_prompt,
        provider: provider,
        model: model
      ]

      {result, usage} =
        case Arbor.AI.generate_text(prompt, llm_opts) do
          {:ok, %{text: text, usage: usage}} ->
            {{:ok, text}, usage}

          {:ok, %{text: text}} ->
            {{:ok, text}, nil}

          {:ok, text} when is_binary(text) ->
            {{:ok, text}, nil}

          {:error, reason} ->
            {{:error, reason}, nil}
        end

      duration_ms = System.monotonic_time(:millisecond) - start_time

      success = match?({:ok, _}, result)

      Signals.emit_reflection_llm_call(agent_id, %{
        provider: provider,
        model: model,
        prompt_chars: String.length(prompt),
        duration_ms: duration_ms,
        success: success,
        usage: usage
      })

      result
    else
      {:error, :llm_not_available}
    end
  end

  # ============================================================================
  # Context Building (for reflect/3)
  # ============================================================================

  defp build_reflection_context(agent_id, include_sk, include_activity) do
    context = %{agent_id: agent_id}

    context =
      if include_sk do
        case IdentityConsolidator.get_self_knowledge(agent_id) do
          nil ->
            context

          sk ->
            Map.merge(context, %{
              capabilities:
                Enum.map(sk.capabilities, fn c ->
                  %{name: c.name, proficiency: c.proficiency}
                end),
              traits:
                Enum.map(sk.personality_traits, fn t ->
                  %{trait: t.trait, strength: t.strength}
                end),
              values:
                Enum.map(sk.values, fn v ->
                  %{value: v.value, importance: v.importance}
                end),
              recent_growth: Enum.take(sk.growth_log, 5)
            })
        end
      else
        context
      end

    if include_activity do
      Map.put(context, :activity_included, true)
    else
      context
    end
  end

  # ============================================================================
  # Storage
  # ============================================================================

  @doc false
  def store_reflection(agent_id, reflection) do
    ensure_ets_exists()

    existing =
      case :ets.lookup(@reflections_ets, agent_id) do
        [{^agent_id, stored}] -> stored
        [] -> []
      end

    updated =
      [reflection | existing]
      |> Enum.take(@max_reflections)

    :ets.insert(@reflections_ets, {agent_id, updated})
    :ok
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp time_since_last_reflection(agent_id) do
    ensure_ets_exists()

    case :ets.lookup(@reflections_ets, agent_id) do
      [{^agent_id, [latest | _]}] ->
        now = DateTime.utc_now()
        DateTime.diff(now, latest.timestamp, :millisecond)

      _ ->
        :infinity
    end
  end

  defp event_count_since_last_reflection(agent_id) do
    ensure_ets_exists()

    last_reflection_time =
      case :ets.lookup(@reflections_ets, agent_id) do
        [{^agent_id, [latest | _]}] -> latest.timestamp
        _ -> nil
      end

    case Events.get_recent(agent_id, 200) do
      {:ok, events} when last_reflection_time != nil ->
        Enum.count(events, fn event ->
          event.timestamp != nil and
            DateTime.compare(event.timestamp, last_reflection_time) == :gt
        end)

      {:ok, events} ->
        length(events)

      {:error, _} ->
        # On error, trigger reflection to be safe
        @default_signal_threshold + 1
    end
  end

  defp get_llm_module do
    Application.get_env(:arbor_memory, :reflection_llm_module, __MODULE__.MockLLM)
  end

  defp generate_id do
    "refl_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp maybe_filter_since(reflections, nil), do: reflections

  defp maybe_filter_since(reflections, since) do
    Enum.filter(reflections, fn r ->
      DateTime.compare(r.timestamp, since) == :gt
    end)
  end

  defp ensure_ets_exists do
    if :ets.whereis(@reflections_ets) == :undefined do
      try do
        :ets.new(@reflections_ets, [:named_table, :public, :set])
      rescue
        ArgumentError -> :ok
      end
    end
  end

  defp build_history_entry(agent_id, prompt, result) do
    %{
      id: generate_id(),
      agent_id: agent_id,
      prompt: prompt,
      analysis: "Deep reflection completed in #{result.duration_ms}ms",
      insights: Enum.map(result.insights, fn i -> i["content"] || inspect(i) end),
      self_assessment: %{
        goal_updates: length(result.goal_updates),
        new_goals: length(result.new_goals),
        knowledge_nodes_added: result.knowledge_nodes_added,
        knowledge_edges_added: result.knowledge_edges_added
      },
      timestamp: DateTime.utc_now(),
      goal_updates: result.goal_updates,
      new_goals: result.new_goals,
      knowledge_nodes: nil,
      knowledge_edges: nil,
      learnings: result.learnings,
      duration_ms: result.duration_ms
    }
  end

  defp get_knowledge_summary(agent_id) do
    case Arbor.Memory.knowledge_stats(agent_id) do
      {:ok, stats} ->
        text =
          "Nodes: #{stats.node_count}, Edges: #{stats.edge_count}, " <>
            "Types: #{inspect(stats.nodes_by_type)}, " <>
            "Avg Relevance: #{Float.round(stats.average_relevance || 0.0, 2)}"

        {:ok, text}

      {:error, _} ->
        {:error, :no_graph}
    end
  end

  # String truncation for signal data
  defp truncate(str, max_len) when is_binary(str) and byte_size(str) > max_len do
    String.slice(str, 0, max_len) <> "..."
  end

  defp truncate(str, _max_len) when is_binary(str), do: str
  defp truncate(_, _max_len), do: ""

  # ============================================================================
  # Mock LLM Module (Test-Only)
  # ============================================================================

  defmodule MockLLM do
    @moduledoc """
    Mock LLM module for testing and development.

    Returns structured test data without making actual LLM calls.
    Only used when explicitly configured via `:reflection_llm_module`.
    """

    @doc """
    Mock reflection call that returns structured test data.
    """
    @spec reflect(String.t(), map()) :: {:ok, map()} | {:error, term()}
    def reflect(prompt, context) do
      # Generate mock response based on prompt content
      analysis = generate_mock_analysis(prompt, context)
      insights = generate_mock_insights(prompt, context)
      self_assessment = generate_mock_self_assessment(context)

      {:ok,
       %{
         analysis: analysis,
         insights: insights,
         self_assessment: self_assessment
       }}
    end

    @doc """
    Mock generate_text for deep_reflect tests.
    Returns valid JSON that parse_reflection_response can handle.
    """
    @spec generate_text(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
    def generate_text(_prompt, _opts) do
      json = Jason.encode!(%{
        "thinking" => "Mock reflection thinking...",
        "goal_updates" => [],
        "new_goals" => [],
        "insights" => [
          %{"content" => "Mock insight from deep reflection", "importance" => 0.7}
        ],
        "learnings" => [
          %{"content" => "Mock technical learning", "confidence" => 0.8, "category" => "technical"}
        ],
        "knowledge_nodes" => [],
        "knowledge_edges" => [],
        "self_insight_suggestions" => []
      })

      {:ok, json}
    end

    defp generate_mock_analysis(prompt, context) do
      agent_id = Map.get(context, :agent_id, "unknown")

      cond do
        String.contains?(prompt, "pattern") ->
          "Analyzing patterns for agent #{agent_id}. " <>
            "The recent activity shows consistent engagement with structured tasks. " <>
            "There is a clear preference for methodical approaches."

        String.contains?(prompt, "improve") ->
          "Reflecting on improvement areas for agent #{agent_id}. " <>
            "Current strengths are being leveraged effectively. " <>
            "Some areas could benefit from increased attention to detail."

        true ->
          "General reflection for agent #{agent_id}. " <>
            "Current state is stable with ongoing growth in key areas."
      end
    end

    defp generate_mock_insights(prompt, _context) do
      base_insights = [
        "Consistent engagement with tasks shows dedication",
        "Pattern of thorough analysis before action"
      ]

      cond do
        String.contains?(prompt, "pattern") ->
          base_insights ++ ["Strong preference for structured approaches"]

        String.contains?(prompt, "improve") ->
          base_insights ++ ["Opportunity to expand capability range"]

        true ->
          base_insights
      end
    end

    defp generate_mock_self_assessment(context) do
      capabilities = Map.get(context, :capabilities, [])
      traits = Map.get(context, :traits, [])

      %{
        capability_confidence:
          if(capabilities != [],
            do: 0.7 + length(capabilities) * 0.02,
            else: 0.5
          ),
        trait_alignment:
          if(traits != [],
            do: 0.8,
            else: 0.6
          ),
        growth_trajectory: :stable,
        areas_for_focus: ["depth over breadth", "consistency"]
      }
    end
  end
end
