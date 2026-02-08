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

  alias Arbor.Memory.{
    Events,
    GoalStore,
    IdentityConsolidator,
    InsightDetector,
    Relationship,
    SelfKnowledge,
    Signals,
    Thinking,
    WorkingMemory
  }

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
         {:ok, prompt} <- {:ok, build_reflection_prompt(context)},
         {:ok, response_text} <- call_llm(prompt, Keyword.put(opts, :agent_id, agent_id)),
         {:ok, parsed} <- parse_reflection_response(response_text) do
      # Integrate results into subsystems
      process_goal_updates(agent_id, parsed.goal_updates)
      process_new_goals(agent_id, parsed.new_goals)
      integrate_insights(agent_id, parsed.insights)
      integrate_learnings(agent_id, parsed.learnings)
      integrate_knowledge_graph(agent_id, parsed.knowledge_nodes, parsed.knowledge_edges)
      process_relationships(agent_id, parsed.relationships)
      trigger_insight_detection(agent_id)
      store_self_insight_suggestions(agent_id, parsed.self_insight_suggestions)
      add_goals_to_knowledge_graph(agent_id, Map.get(context, :goals, []))
      archived_count = run_post_reflection_decay(agent_id)

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
       goals_text: format_goals_for_prompt(goals),
       knowledge_graph_text: get_knowledge_text(agent_id),
       working_memory_text: get_working_memory_text(agent_id),
       recent_thinking_text: format_recent_thinking(agent_id),
       recent_activity_text: get_recent_activity_text(agent_id)
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

    ## Recent Activity
    #{context.recent_activity_text}

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
      relationships: parsed["relationships"] || [],
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
      relationships: [],
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

      "blocked" ->
        GoalStore.block_goal(agent_id, goal_id, update["blockers"])

      "failed" ->
        reason = "[Failed] #{update["note"] || "No reason given"}"
        GoalStore.abandon_goal(agent_id, goal_id, reason)

      _ ->
        :ok
    end

    # Store notes in goal metadata if present
    if update["note"] do
      accumulate_goal_note(agent_id, goal_id, update["note"])
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
    metadata =
      if goal_data["success_criteria"] do
        %{success_criteria: goal_data["success_criteria"]}
      else
        %{}
      end

    goal =
      Goal.new(goal_data["description"],
        type: atomize_type(goal_data["type"]),
        priority: atomize_priority_to_int(goal_data["priority"]),
        metadata: metadata
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

  defp accumulate_goal_note(agent_id, goal_id, note) do
    case GoalStore.get_goal(agent_id, goal_id) do
      {:ok, goal} ->
        existing_notes = Map.get(goal.metadata || %{}, :notes, [])
        timestamped_note = "#{DateTime.utc_now() |> DateTime.to_iso8601()}: #{note}"
        updated_metadata = Map.put(goal.metadata || %{}, :notes, existing_notes ++ [timestamped_note])
        updated_goal = %{goal | metadata: updated_metadata}
        :ets.insert(:arbor_memory_goals, {{agent_id, goal_id}, updated_goal})

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
      # Route by category to appropriate subsystem
      route_learning_by_category(agent_id, category, content)

      # Always add to working memory for immediate context
      prefix = learning_category_prefix(category)
      add_thought_to_working_memory(agent_id, "#{prefix} #{content}")
    end
  end

  defp route_learning_by_category(agent_id, "self", content) do
    case IdentityConsolidator.get_self_knowledge(agent_id) do
      nil -> :ok
      sk ->
        updated = SelfKnowledge.record_growth(sk, :self_learning, content)
        IdentityConsolidator.save_self_knowledge(agent_id, updated)
    end
  rescue
    _ -> :ok
  end

  defp route_learning_by_category(agent_id, "technical", content) do
    # Dedup: check if this learning already exists as a KG node
    case Arbor.Memory.find_knowledge_by_name(agent_id, content) do
      {:ok, _existing_id} -> :ok
      {:error, _} ->
        Arbor.Memory.add_knowledge(agent_id, %{
          type: :skill,
          content: content,
          metadata: %{source: :reflection_learning}
        })
    end
  rescue
    _ -> :ok
  end

  defp route_learning_by_category(_agent_id, _category, _content), do: :ok

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
    name = node_data["name"]

    # Dedup: check if a node with this name already exists
    case Arbor.Memory.find_knowledge_by_name(agent_id, name) do
      {:ok, existing_id} ->
        {:ok, existing_id}

      {:error, _} ->
        Arbor.Memory.add_knowledge(agent_id, %{
          type: safe_node_type(node_data["type"]),
          content: name,
          metadata: %{context: node_data["context"], source: :reflection}
        })
    end
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
  # Relationship Processing
  # ============================================================================

  @doc false
  def process_relationships(_agent_id, []), do: :ok

  def process_relationships(agent_id, relationships) do
    Enum.each(relationships, &process_single_relationship(agent_id, &1))
  end

  defp process_single_relationship(_agent_id, %{"name" => name})
       when is_nil(name) or name == "",
       do: :ok

  defp process_single_relationship(_agent_id, rel_data)
       when not is_map_key(rel_data, "name"),
       do: :ok

  defp process_single_relationship(agent_id, rel_data) do
    name = rel_data["name"]
    observation_default = "Observed during reflection"
    markers = parse_emotional_markers(rel_data["tone"])

    case Arbor.Memory.get_relationship_by_name(agent_id, name) do
      {:ok, existing} ->
        updated = maybe_update_dynamic(existing, rel_data["dynamic"])
        Arbor.Memory.save_relationship(agent_id, updated)
        observation = rel_data["observation"] || observation_default
        Arbor.Memory.add_moment(agent_id, updated.id, observation, emotional_markers: markers)

      {:error, :not_found} ->
        rel = Relationship.new(name, relationship_dynamic: rel_data["dynamic"])
        Arbor.Memory.save_relationship(agent_id, rel)
        observation = rel_data["observation"] || "First encountered during reflection"
        Arbor.Memory.add_moment(agent_id, rel.id, observation, emotional_markers: markers)
    end
  rescue
    e ->
      Logger.warning("Failed to process relationship: #{inspect(e)}",
        agent_id: agent_id,
        name: rel_data["name"]
      )
  end

  defp maybe_update_dynamic(rel, nil), do: rel
  defp maybe_update_dynamic(rel, dynamic), do: Relationship.update_dynamic(rel, dynamic)

  defp parse_emotional_markers(nil), do: []

  defp parse_emotional_markers(tone) when is_binary(tone) do
    tone
    |> String.split(~r/[,\s]+/, trim: true)
    |> Enum.map(&safe_atom(&1, :neutral))
  end

  defp parse_emotional_markers(_), do: []

  # ============================================================================
  # Insight Detection Integration
  # ============================================================================

  defp trigger_insight_detection(agent_id) do
    if Code.ensure_loaded?(Arbor.Memory.InsightDetector) do
      InsightDetector.detect_and_queue(agent_id)
    end
  rescue
    e ->
      Logger.debug("InsightDetector unavailable: #{inspect(e)}")
  end

  defp store_self_insight_suggestions(_agent_id, []), do: :ok

  defp store_self_insight_suggestions(agent_id, suggestions) do
    # Dedup against existing suggestions in working memory
    existing_suggestions = get_existing_suggestion_contents(agent_id)

    suggestions
    |> Enum.map(fn s -> if is_map(s), do: s["content"] || to_string(s), else: to_string(s) end)
    |> Enum.filter(&(&1 != "" and &1 != nil))
    |> Enum.reject(&MapSet.member?(existing_suggestions, &1))
    |> Enum.take(max(0, 10 - MapSet.size(existing_suggestions)))
    |> Enum.each(fn content ->
      add_thought_to_working_memory(agent_id, "[Insight Suggestion] #{content}")
    end)
  end

  defp get_existing_suggestion_contents(agent_id) do
    prefix = "[Insight Suggestion] "

    case Arbor.Memory.get_working_memory(agent_id) do
      nil ->
        MapSet.new()

      wm ->
        wm.recent_thoughts
        |> Enum.map(&thought_content/1)
        |> Enum.filter(&String.starts_with?(&1, prefix))
        |> Enum.map(&String.replace_leading(&1, prefix, ""))
        |> MapSet.new()
    end
  end

  defp thought_content(%{content: content}) when is_binary(content), do: content
  defp thought_content(content) when is_binary(content), do: content
  defp thought_content(_), do: ""

  # ============================================================================
  # Goals in Knowledge Graph
  # ============================================================================

  defp add_goals_to_knowledge_graph(_agent_id, []), do: :ok

  defp add_goals_to_knowledge_graph(agent_id, goals) do
    goals
    |> Enum.filter(&(&1.status == :active))
    |> Enum.each(&add_goal_to_kg(agent_id, &1))
  rescue
    _ -> :ok
  end

  defp add_goal_to_kg(agent_id, goal) do
    case Arbor.Memory.find_knowledge_by_name(agent_id, goal.description) do
      {:ok, _existing_id} ->
        :ok

      {:error, _} ->
        Arbor.Memory.add_knowledge(agent_id, %{
          type: :insight,
          content: goal.description,
          metadata: %{source: :goal, goal_id: goal.id}
        })
    end
  end

  # ============================================================================
  # Post-Reflection Decay
  # ============================================================================

  defp run_post_reflection_decay(agent_id) do
    if Arbor.Memory.should_consolidate?(agent_id) do
      case Arbor.Memory.run_consolidation(agent_id) do
        {:ok, graph, metrics} ->
          archived = Map.get(metrics, :pruned_count, 0)
          remaining = map_size(Map.get(graph, :nodes, %{}))

          Signals.emit_reflection_knowledge_decay(agent_id, %{
            archived_count: archived,
            remaining_nodes: remaining
          })

          archived

        _ ->
          0
      end
    else
      0
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
    {blocked, active} = Enum.split_with(goals, &(&1.status == :blocked))

    sorted_active =
      active
      |> Enum.sort_by(&goal_urgency/1, :desc)

    active_text =
      if sorted_active == [] do
        ""
      else
        Enum.map_join(sorted_active, "\n\n", &format_single_goal/1)
      end

    blocked_text =
      if blocked == [] do
        ""
      else
        header = "\n\n### Blocked Goals\n"
        items = Enum.map_join(blocked, "\n\n", &format_blocked_goal/1)
        header <> items
      end

    (active_text <> blocked_text)
    |> String.trim()
    |> case do
      "" -> "(No active goals)"
      text -> text
    end
  end

  defp format_single_goal(goal) do
    emoji = priority_emoji(goal.priority)
    progress_pct = Float.round(goal.progress * 100, 0)
    bar_filled = round(goal.progress * 20)
    bar_empty = 20 - bar_filled
    bar = String.duplicate("█", bar_filled) <> String.duplicate("░", bar_empty)
    deadline = deadline_text(goal)

    base =
      "- #{emoji} [#{goal.id}] #{goal.description}#{deadline}\n" <>
        "  Priority: #{goal.priority} | Type: #{goal.type} | " <>
        "Progress: #{bar} #{progress_pct}%"

    base
    |> maybe_append_criteria(goal)
    |> maybe_append_notes(goal)
  end

  defp format_blocked_goal(goal) do
    emoji = priority_emoji(goal.priority)
    blockers = get_in(goal.metadata || %{}, [:blockers]) || []

    blockers_text =
      if blockers == [] do
        ""
      else
        "\n  Blocked by: " <> Enum.join(blockers, ", ")
      end

    "- #{emoji} [BLOCKED] [#{goal.id}] #{goal.description}#{blockers_text}"
  end

  defp maybe_append_criteria(text, goal) do
    case get_in(goal.metadata || %{}, [:success_criteria]) do
      nil -> text
      "" -> text
      criteria -> text <> "\n  Success criteria: #{criteria}"
    end
  end

  defp maybe_append_notes(text, goal) do
    case get_in(goal.metadata || %{}, [:notes]) do
      nil -> text
      [] -> text
      notes ->
        recent = Enum.take(notes, -3)
        notes_text = Enum.map_join(recent, "\n", &("    - " <> &1))
        text <> "\n  Recent notes:\n#{notes_text}"
    end
  end

  defp goal_urgency(goal) do
    overdue_factor =
      case get_in(goal.metadata || %{}, [:deadline]) do
        nil -> 0.0
        deadline when is_binary(deadline) ->
          case DateTime.from_iso8601(deadline) do
            {:ok, dt, _} -> deadline_urgency_factor(dt)
            _ -> 0.0
          end
        %DateTime{} = dt -> deadline_urgency_factor(dt)
        _ -> 0.0
      end

    goal.priority * (1.0 + overdue_factor)
  end

  defp deadline_urgency_factor(deadline) do
    hours = DateTime.diff(deadline, DateTime.utc_now(), :hour)

    cond do
      hours < 0 -> 2.0
      hours < 24 -> 1.0
      hours < 168 -> 0.5
      true -> 0.0
    end
  end

  defp priority_emoji(priority) when is_integer(priority) do
    cond do
      priority >= 80 -> "🔴"
      priority >= 60 -> "🟠"
      priority >= 40 -> "🟡"
      true -> "🟢"
    end
  end

  defp priority_emoji(_), do: "🟡"

  defp deadline_text(goal) do
    case get_in(goal.metadata || %{}, [:deadline]) do
      nil -> ""
      deadline when is_binary(deadline) ->
        case DateTime.from_iso8601(deadline) do
          {:ok, dt, _} -> format_deadline(dt)
          _ -> ""
        end
      %DateTime{} = dt -> format_deadline(dt)
      _ -> ""
    end
  end

  defp format_deadline(deadline) do
    hours = DateTime.diff(deadline, DateTime.utc_now(), :hour)

    cond do
      hours < 0 -> " ⚠️ OVERDUE"
      hours < 24 -> " ⏰ Due in #{hours}h"
      hours < 168 -> " Due in #{div(hours, 24)}d"
      true -> ""
    end
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

  # String truncation for signal data
  defp truncate(str, max_len) when is_binary(str) and byte_size(str) > max_len do
    String.slice(str, 0, max_len) <> "..."
  end

  defp truncate(str, _max_len) when is_binary(str), do: str
  defp truncate(_, _max_len), do: ""

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
