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

  alias Arbor.Contracts.Memory.Goal
  alias Arbor.Memory.{Events, GoalStore, IdentityConsolidator, Signals, Thinking, WorkingMemory}

  require Logger

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
  @spec periodic_reflection(String.t()) :: {:ok, reflection()} | {:error, term()}
  def periodic_reflection(agent_id) do
    prompt = """
    Reflect on my recent activity and patterns. Consider:
    - What tasks have I been focused on?
    - What patterns do I notice in my approach?
    - What have I learned or improved?
    - Are there areas where I could do better?
    """

    reflect(agent_id, prompt)
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
         {:ok, prompt} <- {:ok, build_reflection_prompt(context)},
         {:ok, response_text} <- call_llm(prompt, opts),
         {:ok, parsed} <- parse_reflection_response(response_text) do
      # Integrate results into subsystems
      process_goal_updates(agent_id, parsed.goal_updates)
      process_new_goals(agent_id, parsed.new_goals)
      integrate_insights(agent_id, parsed.insights)
      integrate_learnings(agent_id, parsed.learnings)
      integrate_knowledge_graph(agent_id, parsed.knowledge_nodes, parsed.knowledge_edges)
      run_post_reflection_decay(agent_id)

      duration = System.monotonic_time(:millisecond) - start_time

      result = %{
        goal_updates: parsed.goal_updates,
        new_goals: parsed.new_goals,
        insights: parsed.insights,
        learnings: parsed.learnings,
        knowledge_nodes_added: length(parsed.knowledge_nodes),
        knowledge_edges_added: length(parsed.knowledge_edges),
        self_insight_suggestions: parsed.self_insight_suggestions,
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

  # ============================================================================
  # Deep Context Building
  # ============================================================================

  @doc false
  def build_deep_context(agent_id, _opts) do
    sk = IdentityConsolidator.get_self_knowledge(agent_id)
    goals = GoalStore.get_active_goals(agent_id)

    {:ok,
     %{
       agent_id: agent_id,
       self_knowledge: sk,
       self_knowledge_text: format_self_knowledge_or_default(sk),
       goals: goals,
       goals_text: format_goals_for_prompt(goals),
       knowledge_graph_text: get_knowledge_text(agent_id),
       working_memory_text: get_working_memory_text(agent_id),
       recent_thinking_text: format_recent_thinking(agent_id)
     }}
  end

  defp format_self_knowledge_or_default(nil), do: "(No self-knowledge established yet)"
  defp format_self_knowledge_or_default(sk), do: format_self_knowledge(sk)

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

  # ============================================================================
  # LLM Prompt Building (ported from arbor_seed)
  # ============================================================================

  @doc false
  def build_reflection_prompt(context) do
    """
    You are performing a deep reflection on recent experiences. Your PRIMARY PURPOSE is to:
    1. **EVALUATE PROGRESS ON ACTIVE GOALS** - This is your most important task
    2. Identify patterns and connections relevant to your goals
    3. Note relationship dynamics that affect your work
    4. Consolidate learnings
    5. Discover knowledge graph relationships

    ## Current Identity Context
    #{context.self_knowledge_text}

    ## ACTIVE GOALS - EVALUATE EACH ONE
    #{context.goals_text}

    ## Current Knowledge Graph
    #{context.knowledge_graph_text}

    ## Working Memory
    #{context.working_memory_text}

    ## Recent Thinking
    #{context.recent_thinking_text}

    ## Instructions

    **GOAL EVALUATION IS YOUR TOP PRIORITY.** For each active goal:
    - What progress was made? (estimate new percentage)
    - What blockers or challenges exist?
    - What's the next concrete step?
    - Should this goal be marked achieved, failed, or blocked?

    Also reflect on:
    - Patterns in the ACTUAL WORK being done (not system behavior)
    - Relationship dynamics (what matters to the human you're working with)
    - Technical learnings relevant to the project/codebase
    - New goals that emerged from the work
    - Entities (people, projects, concepts) and their relationships

    **DO NOT** create learnings or insights about:
    - How the system/framework works internally
    - Meta-observations about your own behavior or the heartbeat loop
    - Obvious facts about conversation flow or goal tracking
    - System implementation details

    Respond in JSON format:
    {
      "thinking": "Your reflection process, especially about goal progress...",
      "goal_updates": [
        {
          "goal_id": "the goal ID from above",
          "new_progress": 0.45,
          "status": "active|achieved|failed|blocked|abandoned",
          "note": "What happened with this goal",
          "next_step": "The next concrete action to take",
          "blockers": ["any blockers identified"]
        }
      ],
      "new_goals": [
        {
          "description": "A new goal that emerged",
          "priority": "critical|high|medium|low",
          "type": "achieve|maintain|explore|learn",
          "parent_goal_id": "optional - if this is a subgoal"
        }
      ],
      "insights": [
        {"content": "An insight about patterns or meaning", "importance": 0.7, "related_goal_id": "optional"}
      ],
      "learnings": [
        {"content": "Something meaningful learned", "confidence": 0.8, "category": "technical|relationship|self"}
      ],
      "knowledge_nodes": [
        {"name": "entity name", "type": "person|project|concept|tool|goal", "context": "brief context"}
      ],
      "knowledge_edges": [
        {"from": "entity name", "to": "other entity name", "relationship": "knows|worked_on|uses|advances_goal|blocks_goal|related_to"}
      ],
      "self_insight_suggestions": [
        {
          "content": "I tend to be curious and ask clarifying questions before acting",
          "category": "personality|capability|value|preference",
          "confidence": 0.4,
          "evidence": ["asked 3 questions before starting"]
        }
      ]
    }

    **Important:** Include goal_updates for EVERY active goal, even if just to note "no progress this cycle".
    Link insights and knowledge nodes to goals when relevant.
    """
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

      result =
        case Arbor.AI.generate_text(prompt, llm_opts) do
          {:ok, %{text: text}} ->
            {:ok, text}

          {:ok, text} when is_binary(text) ->
            {:ok, text}

          {:error, reason} ->
            {:error, reason}
        end

      duration_ms = System.monotonic_time(:millisecond) - start_time

      {success, _} =
        case result do
          {:ok, _} -> {true, %{}}
          {:error, _} -> {false, %{}}
        end

      Signals.emit_reflection_llm_call("unknown", %{
        provider: provider,
        model: model,
        prompt_chars: String.length(prompt),
        duration_ms: duration_ms,
        success: success
      })

      result
    else
      {:error, :llm_not_available}
    end
  end

  # ============================================================================
  # JSON Response Parsing
  # ============================================================================

  @doc false
  def parse_reflection_response(response) do
    json_text = extract_json_text(response)

    case Jason.decode(json_text) do
      {:ok, parsed} ->
        {:ok, normalize_parsed_response(parsed)}

      {:error, _} ->
        Logger.warning("Failed to parse reflection JSON response",
          response_preview: String.slice(response, 0, 200)
        )

        {:ok, empty_parsed_response()}
    end
  end

  defp extract_json_text(response) do
    case Regex.run(~r/```(?:json)?\s*(\{[\s\S]*?\})\s*```/, response) do
      [_, json] -> json
      nil -> String.trim(response)
    end
  end

  defp normalize_parsed_response(parsed) do
    %{
      goal_updates: parsed["goal_updates"] || [],
      new_goals: parsed["new_goals"] || [],
      insights: parsed["insights"] || [],
      learnings: parsed["learnings"] || [],
      knowledge_nodes: parsed["knowledge_nodes"] || [],
      knowledge_edges: parsed["knowledge_edges"] || [],
      self_insight_suggestions: parsed["self_insight_suggestions"] || [],
      thinking: parsed["thinking"]
    }
  end

  defp empty_parsed_response do
    %{
      goal_updates: [],
      new_goals: [],
      insights: [],
      learnings: [],
      knowledge_nodes: [],
      knowledge_edges: [],
      self_insight_suggestions: [],
      thinking: nil
    }
  end

  # ============================================================================
  # Goal Processing
  # ============================================================================

  @doc false
  def process_goal_updates(agent_id, goal_updates) do
    Enum.each(goal_updates, fn update ->
      goal_id = update["goal_id"]

      if goal_id do
        process_single_goal_update(agent_id, goal_id, update)
      end
    end)
  end

  defp process_single_goal_update(agent_id, goal_id, update) do
    # Update progress
    if update["new_progress"] do
      progress = min(1.0, max(0.0, update["new_progress"]))
      GoalStore.update_goal_progress(agent_id, goal_id, progress)
    end

    # Update status
    case update["status"] do
      "achieved" ->
        GoalStore.achieve_goal(agent_id, goal_id)

      "abandoned" ->
        GoalStore.abandon_goal(agent_id, goal_id, update["note"])

      _ ->
        :ok
    end

    Signals.emit_reflection_goal_update(agent_id, goal_id, update)

    Logger.debug("Goal updated via reflection",
      agent_id: agent_id,
      goal_id: goal_id,
      progress: update["new_progress"],
      status: update["status"]
    )
  rescue
    ArgumentError ->
      Logger.debug("Invalid goal update data",
        agent_id: agent_id,
        goal_id: goal_id
      )
  end

  @doc false
  def process_new_goals(agent_id, new_goals) do
    new_goals
    |> Enum.filter(&valid_goal_description?/1)
    |> Enum.each(&create_goal_from_data(agent_id, &1))
  end

  defp valid_goal_description?(goal_data) do
    desc = goal_data["description"]
    desc != nil and desc != ""
  end

  defp create_goal_from_data(agent_id, goal_data) do
    goal =
      Goal.new(goal_data["description"],
        type: atomize_type(goal_data["type"]),
        priority: atomize_priority_to_int(goal_data["priority"])
      )

    goal = maybe_set_parent(goal, goal_data["parent_goal_id"])

    case GoalStore.add_goal(agent_id, goal) do
      {:ok, saved_goal} ->
        Signals.emit_reflection_goal_created(agent_id, saved_goal.id, goal_data)

        Logger.info("New goal created via reflection",
          agent_id: agent_id,
          goal_id: saved_goal.id,
          description: goal_data["description"]
        )

      _ ->
        :ok
    end
  end

  defp maybe_set_parent(goal, nil), do: goal
  defp maybe_set_parent(goal, parent_id), do: %{goal | parent_id: parent_id}

  # ============================================================================
  # Insight Integration
  # ============================================================================

  @doc false
  def integrate_insights(agent_id, insights) do
    Enum.each(insights, &integrate_single_insight(agent_id, &1))
  end

  defp integrate_single_insight(agent_id, insight) do
    content = insight["content"]
    importance = insight["importance"] || 0.5

    Signals.emit_reflection_insight(agent_id, %{
      content: content,
      importance: importance,
      related_goal_id: insight["related_goal_id"]
    })

    if importance >= 0.5 do
      add_thought_to_working_memory(agent_id, "[Insight] #{content}")
    end
  end

  defp add_thought_to_working_memory(agent_id, text) do
    case Arbor.Memory.get_working_memory(agent_id) do
      nil -> :ok
      wm ->
        updated_wm = WorkingMemory.add_thought(wm, text)
        Arbor.Memory.save_working_memory(agent_id, updated_wm)
    end
  end

  # ============================================================================
  # Learning Integration
  # ============================================================================

  @doc false
  def integrate_learnings(agent_id, learnings) do
    Enum.each(learnings, &integrate_single_learning(agent_id, &1))
  end

  defp integrate_single_learning(agent_id, learning) do
    content = learning["content"]
    confidence = learning["confidence"] || 0.5
    category = learning["category"]

    Signals.emit_reflection_learning(agent_id, %{
      content: content,
      confidence: confidence,
      category: category
    })

    if confidence >= 0.5 do
      prefix = learning_category_prefix(category)
      add_thought_to_working_memory(agent_id, "#{prefix} #{content}")
    end
  end

  defp learning_category_prefix("technical"), do: "[Technical Learning]"
  defp learning_category_prefix("relationship"), do: "[Relationship Learning]"
  defp learning_category_prefix("self"), do: "[Self Learning]"
  defp learning_category_prefix(_), do: "[Learning]"

  # ============================================================================
  # Knowledge Graph Integration
  # ============================================================================

  @doc false
  def integrate_knowledge_graph(_agent_id, [], []), do: :ok

  def integrate_knowledge_graph(agent_id, nodes, edges) do
    node_map = add_knowledge_nodes(agent_id, nodes)
    edges_added = add_knowledge_edges(agent_id, edges, node_map)

    Signals.emit_reflection_knowledge_graph(agent_id, %{
      nodes_added: map_size(node_map),
      edges_added: edges_added
    })

    :ok
  end

  defp add_knowledge_nodes(agent_id, nodes) do
    nodes
    |> Enum.filter(&valid_node_name?/1)
    |> Enum.reduce(%{}, fn node_data, acc ->
      case add_single_knowledge_node(agent_id, node_data) do
        {:ok, node_id} -> Map.put(acc, node_data["name"], node_id)
        _ -> acc
      end
    end)
  end

  defp valid_node_name?(node_data) do
    name = node_data["name"]
    name != nil and name != ""
  end

  defp add_single_knowledge_node(agent_id, node_data) do
    Arbor.Memory.add_knowledge(agent_id, %{
      type: safe_node_type(node_data["type"]),
      content: node_data["name"],
      metadata: %{context: node_data["context"], source: :reflection}
    })
  end

  defp add_knowledge_edges(agent_id, edges, node_map) do
    Enum.count(edges, &add_single_knowledge_edge(agent_id, &1, node_map))
  end

  defp add_single_knowledge_edge(agent_id, edge_data, node_map) do
    from_id = Map.get(node_map, edge_data["from"])
    to_id = Map.get(node_map, edge_data["to"])

    if from_id && to_id do
      relationship = safe_atom(edge_data["relationship"], :related_to)
      Arbor.Memory.link_knowledge(agent_id, from_id, to_id, relationship) == :ok
    else
      false
    end
  end

  # ============================================================================
  # Post-Reflection Decay
  # ============================================================================

  defp run_post_reflection_decay(agent_id) do
    if Arbor.Memory.should_consolidate?(agent_id) do
      case Arbor.Memory.run_consolidation(agent_id) do
        {:ok, _graph, _metrics} -> :ok
        _ -> :ok
      end
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

  defp format_self_knowledge(sk) do
    parts = []

    parts =
      if sk.capabilities != [] do
        caps =
          Enum.map_join(sk.capabilities, "\n", fn c ->
            "  - #{c.name}: #{Float.round(c.proficiency * 100, 0)}%"
          end)

        parts ++ ["## Capabilities\n#{caps}"]
      else
        parts
      end

    parts =
      if sk.personality_traits != [] do
        traits =
          Enum.map_join(sk.personality_traits, "\n", fn t ->
            "  - #{t.trait}: #{Float.round(t.strength * 100, 0)}%"
          end)

        parts ++ ["## Personality Traits\n#{traits}"]
      else
        parts
      end

    parts =
      if sk.values != [] do
        vals =
          Enum.map_join(sk.values, "\n", fn v ->
            "  - #{v.value}: #{Float.round(v.importance * 100, 0)}%"
          end)

        parts ++ ["## Values\n#{vals}"]
      else
        parts
      end

    if parts == [] do
      "(Self-knowledge initialized but no entries yet)"
    else
      Enum.join(parts, "\n\n")
    end
  end

  defp format_goals_for_prompt([]) do
    "(No active goals)"
  end

  defp format_goals_for_prompt(goals) do
    Enum.map_join(goals, "\n", fn goal ->
      progress_pct = Float.round(goal.progress * 100, 0)
      bar_filled = round(goal.progress * 20)
      bar_empty = 20 - bar_filled
      bar = String.duplicate("█", bar_filled) <> String.duplicate("░", bar_empty)

      "- [#{goal.id}] #{goal.description}\n" <>
        "  Priority: #{goal.priority} | Type: #{goal.type} | " <>
        "Progress: #{bar} #{progress_pct}%"
    end)
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

  # Priority mapping: arbor_seed uses atoms, trust-arbor uses 0-100 integers
  defp atomize_priority_to_int(nil), do: 50
  defp atomize_priority_to_int("critical"), do: 90
  defp atomize_priority_to_int("high"), do: 70
  defp atomize_priority_to_int("medium"), do: 50
  defp atomize_priority_to_int("low"), do: 30
  defp atomize_priority_to_int(_), do: 50

  # Goal type mapping to trust-arbor atoms
  defp atomize_type(nil), do: :achieve
  defp atomize_type("achieve"), do: :achieve
  defp atomize_type("achievement"), do: :achieve
  defp atomize_type("maintain"), do: :maintain
  defp atomize_type("maintenance"), do: :maintain
  defp atomize_type("explore"), do: :explore
  defp atomize_type("exploration"), do: :explore
  defp atomize_type("learn"), do: :learn
  defp atomize_type(_), do: :achieve

  # Safe node type conversion
  defp safe_node_type(nil), do: :concept
  defp safe_node_type("person"), do: :relationship
  defp safe_node_type("project"), do: :experience
  defp safe_node_type("concept"), do: :fact
  defp safe_node_type("tool"), do: :skill
  defp safe_node_type("goal"), do: :insight
  defp safe_node_type(_), do: :fact

  # Safe atom conversion with fallback
  defp safe_atom(nil, default), do: default
  defp safe_atom(str, default) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> default
  end
  defp safe_atom(atom, _default) when is_atom(atom), do: atom

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
