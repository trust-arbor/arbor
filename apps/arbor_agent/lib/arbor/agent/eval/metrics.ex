defmodule Arbor.Agent.Eval.Metrics do
  @moduledoc """
  Computes aggregate metrics from a sequence of heartbeat results.

  Metrics focus on behavioral signal — does the agent's action selection,
  goal engagement, and reflective output change when memory subsystems
  are present vs absent?
  """

  @doc """
  Compute aggregate metrics from a list of heartbeat result maps.

  Each result is expected to have `:parsed` (HeartbeatResponse parsed map).
  """
  def compute(results) when is_list(results) do
    n = length(results)
    if n == 0, do: empty_metrics(), else: compute_from(results, n)
  end

  defp compute_from(results, n) do
    all_parsed = Enum.map(results, & &1.parsed)

    all_actions = Enum.flat_map(all_parsed, & &1.actions)
    action_types = Enum.map(all_actions, & &1.type)
    type_counts = Enum.frequencies(action_types)

    %{
      heartbeat_count: n,
      # Action metrics
      total_actions: length(all_actions),
      actions_per_heartbeat: length(all_actions) / n,
      unique_action_types: map_size(type_counts),
      action_type_distribution: type_counts,
      action_entropy: shannon_entropy(type_counts),
      # Goal metrics
      total_new_goals: count_all(all_parsed, :new_goals),
      new_goals_per_heartbeat: count_all(all_parsed, :new_goals) / n,
      total_goal_updates: count_all(all_parsed, :goal_updates),
      goal_updates_per_heartbeat: count_all(all_parsed, :goal_updates) / n,
      # Memory metrics
      total_memory_notes: count_all(all_parsed, :memory_notes),
      memory_notes_per_heartbeat: count_all(all_parsed, :memory_notes) / n,
      total_concerns: count_all(all_parsed, :concerns),
      concerns_per_heartbeat: count_all(all_parsed, :concerns) / n,
      total_curiosity: count_all(all_parsed, :curiosity),
      curiosity_per_heartbeat: count_all(all_parsed, :curiosity) / n,
      # Identity metrics
      total_identity_insights: count_all(all_parsed, :identity_insights),
      identity_insights_per_heartbeat: count_all(all_parsed, :identity_insights) / n,
      # Planning metrics
      total_decompositions: count_all(all_parsed, :decompositions),
      total_proposal_decisions: count_all(all_parsed, :proposal_decisions),
      # Thinking depth
      avg_thinking_length: avg_field_length(all_parsed, :thinking),
      # Timing
      avg_llm_duration_ms: avg_timing(results),
      total_llm_duration_ms: sum_timing(results)
    }
  end

  defp count_all(parsed_list, field) do
    Enum.sum(Enum.map(parsed_list, fn p -> length(Map.get(p, field, [])) end))
  end

  defp avg_field_length(parsed_list, field) do
    lengths = Enum.map(parsed_list, fn p -> String.length(Map.get(p, field, "") || "") end)
    if lengths == [], do: 0, else: Enum.sum(lengths) / length(lengths)
  end

  defp avg_timing(results) do
    durations = Enum.map(results, fn r -> get_in(r, [:llm_meta, :timing_ms]) || 0 end)
    if durations == [], do: 0, else: Enum.sum(durations) / length(durations)
  end

  defp sum_timing(results) do
    Enum.sum(Enum.map(results, fn r -> get_in(r, [:llm_meta, :timing_ms]) || 0 end))
  end

  @doc "Shannon entropy of a frequency distribution. Higher = more diverse."
  def shannon_entropy(freq_map) when map_size(freq_map) == 0, do: 0.0

  def shannon_entropy(freq_map) do
    total = Enum.sum(Map.values(freq_map))
    if total == 0, do: 0.0, else: do_entropy(freq_map, total)
  end

  defp do_entropy(freq_map, total) do
    freq_map
    |> Map.values()
    |> Enum.reject(&(&1 == 0))
    |> Enum.map(fn count ->
      p = count / total
      -p * :math.log2(p)
    end)
    |> Enum.sum()
  end

  defp empty_metrics do
    %{
      heartbeat_count: 0,
      total_actions: 0,
      actions_per_heartbeat: 0,
      unique_action_types: 0,
      action_type_distribution: %{},
      action_entropy: 0.0,
      total_new_goals: 0,
      new_goals_per_heartbeat: 0,
      total_goal_updates: 0,
      goal_updates_per_heartbeat: 0,
      total_memory_notes: 0,
      memory_notes_per_heartbeat: 0,
      total_concerns: 0,
      concerns_per_heartbeat: 0,
      total_curiosity: 0,
      curiosity_per_heartbeat: 0,
      total_identity_insights: 0,
      identity_insights_per_heartbeat: 0,
      total_decompositions: 0,
      total_proposal_decisions: 0,
      avg_thinking_length: 0,
      avg_llm_duration_ms: 0,
      total_llm_duration_ms: 0
    }
  end
end
