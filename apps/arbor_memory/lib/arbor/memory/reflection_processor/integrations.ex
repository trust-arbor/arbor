defmodule Arbor.Memory.ReflectionProcessor.Integrations do
  @moduledoc """
  Handles integration of reflection results into memory subsystems.

  This module contains functions extracted from `ReflectionProcessor` that
  integrate parsed reflection outputs (insights, learnings, knowledge graph
  updates, relationship observations, etc.) into the appropriate memory
  stores and subsystems.
  """

  require Logger

  alias Arbor.Memory.{
    IdentityConsolidator,
    InsightDetector,
    Relationship,
    SelfKnowledge,
    Signals,
    WorkingMemory
  }

  alias Arbor.Memory.Reflection.PromptBuilder

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

  @doc false
  def add_thought_to_working_memory(agent_id, text) do
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
          type: PromptBuilder.safe_node_type(node_data["type"]),
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

  @doc false
  def trigger_insight_detection(agent_id) do
    if Code.ensure_loaded?(Arbor.Memory.InsightDetector) do
      InsightDetector.detect_and_queue(agent_id)
    end
  rescue
    e ->
      Logger.debug("InsightDetector unavailable: #{inspect(e)}")
  end

  @doc false
  def store_self_insight_suggestions(_agent_id, []), do: :ok

  def store_self_insight_suggestions(agent_id, suggestions) do
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

  @doc false
  def add_goals_to_knowledge_graph(_agent_id, []), do: :ok

  def add_goals_to_knowledge_graph(agent_id, goals) do
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

  @doc false
  def run_post_reflection_decay(agent_id) do
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
  # Shared Helpers
  # ============================================================================

  # Safe atom conversion with fallback
  defp safe_atom(nil, default), do: default
  defp safe_atom(str, default) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> default
  end
  defp safe_atom(atom, _default) when is_atom(atom), do: atom
end
