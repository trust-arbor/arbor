defmodule Arbor.Memory.Introspection do
  @moduledoc """
  Live system introspection — read-only aggregation across memory stores.

  Provides `read_self/3` which pulls live data from KG, working memory,
  preferences, proposals, self-knowledge, goals, and thinking. This is
  the Seed-style introspection API.
  """

  alias Arbor.Memory.{
    GoalStore,
    GraphOps,
    IdentityConsolidator,
    KnowledgeGraph,
    Preferences,
    Proposal,
    Thinking,
    WorkingMemory
  }

  @working_memory_ets :arbor_working_memory

  @doc """
  Aggregate live stats from the memory system for a given aspect.

  ## Aspects

  - `:memory_system` — KG stats, working memory stats, proposal stats
  - `:identity` — self-knowledge traits/values/capabilities, active goal count by type
  - `:tools` — capability list with proficiency, optional trust_tier bounds
  - `:cognition` — preferences, working memory engagement/concerns/curiosity
  - `:all` — aggregates all four

  ## Options

  - `:trust_tier` — trust tier for preference bounds (default: `:trusted`)
  """
  @spec read_self(String.t(), atom(), keyword()) :: {:ok, map()}
  def read_self(agent_id, aspect \\ :all, opts \\ []) do
    result =
      case aspect do
        :memory_system ->
          read_self_memory_system(agent_id)

        :identity ->
          read_self_identity(agent_id, opts)

        :tools ->
          read_self_tools(agent_id, opts)

        :cognition ->
          read_self_cognition(agent_id)

        :all ->
          Map.merge(
            Map.merge(read_self_memory_system(agent_id), read_self_identity(agent_id, opts)),
            Map.merge(read_self_tools(agent_id, opts), read_self_cognition(agent_id))
          )

        _ ->
          %{error: "Unknown aspect: #{inspect(aspect)}"}
      end

    {:ok, result}
  end

  defp read_self_memory_system(agent_id) do
    kg = GraphOps.fetch_graph(agent_id)
    kg_stats = if kg, do: KnowledgeGraph.stats(kg), else: %{node_count: 0, edge_count: 0}

    wm = fetch_working_memory(agent_id)
    wm_stats = if wm, do: WorkingMemory.stats(wm), else: %{thought_count: 0}

    proposal_stats =
      try do
        Proposal.stats(agent_id)
      rescue
        _ -> %{pending: 0}
      end

    %{
      memory_system: %{
        knowledge_graph: kg_stats,
        working_memory: wm_stats,
        proposals: proposal_stats
      }
    }
  end

  defp read_self_identity(agent_id, _opts) do
    sk = IdentityConsolidator.get_self_knowledge(agent_id)
    goals = GoalStore.get_active_goals(agent_id)

    goals_by_type =
      goals
      |> Enum.group_by(& &1.type)
      |> Map.new(fn {type, gs} -> {type, length(gs)} end)

    sk_summary =
      if sk do
        %{
          traits:
            Enum.map(sk.personality_traits, fn {trait, strength, _, _} ->
              %{trait: trait, strength: strength}
            end),
          values:
            Enum.map(sk.values, fn {value, importance, _, _} ->
              %{value: value, importance: importance}
            end),
          capability_count: length(sk.capabilities),
          version: sk.version
        }
      else
        %{traits: [], values: [], capability_count: 0, version: 0}
      end

    %{
      identity: %{
        self_knowledge: sk_summary,
        active_goals: goals_by_type,
        total_active_goals: length(goals)
      }
    }
  end

  defp read_self_tools(agent_id, opts) do
    sk = IdentityConsolidator.get_self_knowledge(agent_id)
    trust_tier = Keyword.get(opts, :trust_tier, :trusted)

    capabilities =
      if sk do
        Enum.map(sk.capabilities, fn {name, proficiency, evidence, _added_at} ->
          %{name: name, proficiency: proficiency, evidence: evidence}
        end)
      else
        []
      end

    bounds =
      try do
        Preferences.bounds_for_tier(trust_tier)
      rescue
        _ -> %{}
      end

    %{
      tools: %{
        capabilities: capabilities,
        trust_tier: trust_tier,
        trust_bounds: bounds
      }
    }
  end

  defp read_self_cognition(agent_id) do
    prefs = get_preferences(agent_id)
    wm = fetch_working_memory(agent_id)

    prefs_summary =
      if prefs do
        try do
          Preferences.inspect_preferences(prefs)
        rescue
          _ -> %{}
        end
      else
        %{}
      end

    wm_summary =
      if wm do
        %{
          engagement: Map.get(wm, :engagement_level, 0.5),
          concerns: Map.get(wm, :concerns, []),
          curiosity: Map.get(wm, :curiosity, []),
          thought_count: length(Map.get(wm, :recent_thoughts, []))
        }
      else
        %{engagement: 0.5, concerns: [], curiosity: [], thought_count: 0}
      end

    thinking_count =
      try do
        length(Thinking.recent_thinking(agent_id, limit: 100))
      rescue
        _ -> 0
      end

    %{
      cognition: %{
        preferences: prefs_summary,
        working_memory: wm_summary,
        recent_thinking_count: thinking_count
      }
    }
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp fetch_working_memory(agent_id) do
    if :ets.whereis(@working_memory_ets) != :undefined do
      case :ets.lookup(@working_memory_ets, agent_id) do
        [{^agent_id, wm}] -> wm
        [] -> nil
      end
    end
  rescue
    _ -> nil
  end

  defp get_preferences(agent_id) do
    preferences_ets = :arbor_preferences

    if :ets.whereis(preferences_ets) != :undefined do
      case :ets.lookup(preferences_ets, agent_id) do
        [{^agent_id, prefs}] -> prefs
        [] -> nil
      end
    end
  rescue
    _ -> nil
  end
end
