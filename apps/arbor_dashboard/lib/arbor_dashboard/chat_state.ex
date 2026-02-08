defmodule Arbor.Dashboard.ChatState do
  @moduledoc """
  ETS-backed state storage for ChatLive.

  Stores per-agent state that survives page refreshes but not server restarts:
  - Token counts (input, output, cached, call count, last duration)
  - Signal stream (last 50 signals)
  - Identity evolution (insights, changes, consolidations)
  - Cognitive preferences (quotas, pins, adjustments)
  - Code modules (agent-created code)
  - Recent agents (last 10 agents interacted with)
  """

  @tokens_table :arbor_chat_tokens
  @signal_table :arbor_chat_signals
  @identity_table :arbor_chat_identity
  @cognitive_table :arbor_chat_cognitive
  @code_table :arbor_chat_code
  @recent_table :arbor_chat_recent

  @max_signals 50
  @max_insights 20
  @max_identity_changes 10
  @max_cognitive_adjustments 10
  @max_code_modules 20
  @max_recent_agents 10

  @tables [
    @tokens_table,
    @signal_table,
    @identity_table,
    @cognitive_table,
    @code_table,
    @recent_table
  ]

  def init do
    for table <- @tables do
      if :ets.whereis(table) == :undefined do
        :ets.new(table, [:named_table, :public, :set])
      end
    end

    :ok
  end

  # ── Token Counts ──────────────────────────────────────────────────

  def get_tokens(agent_id) do
    case :ets.lookup(@tokens_table, agent_id) do
      [{^agent_id, tokens}] -> tokens
      [] -> %{input: 0, output: 0, cached: 0, count: 0, last_duration: nil}
    end
  rescue
    ArgumentError -> %{input: 0, output: 0, cached: 0, count: 0, last_duration: nil}
  end

  def add_tokens(agent_id, input_tokens, output_tokens, duration_ms) do
    current = get_tokens(agent_id)

    updated = %{
      input: current.input + input_tokens,
      output: current.output + output_tokens,
      cached: current.cached,
      count: current.count + 1,
      last_duration: duration_ms
    }

    :ets.insert(@tokens_table, {agent_id, updated})
    updated
  rescue
    ArgumentError ->
      %{
        input: input_tokens,
        output: output_tokens,
        cached: 0,
        count: 1,
        last_duration: duration_ms
      }
  end

  def add_cached_tokens(agent_id, cached_tokens) do
    current = get_tokens(agent_id)

    updated = %{
      input: current.input,
      output: current.output,
      cached: current.cached + cached_tokens,
      count: current.count,
      last_duration: current.last_duration
    }

    :ets.insert(@tokens_table, {agent_id, updated})
    updated
  rescue
    ArgumentError ->
      %{input: 0, output: 0, cached: cached_tokens, count: 0, last_duration: nil}
  end

  # ── Signal Stream ─────────────────────────────────────────────────

  def get_signals(agent_id) do
    case :ets.lookup(@signal_table, agent_id) do
      [{^agent_id, signals}] -> signals
      [] -> []
    end
  rescue
    ArgumentError -> []
  end

  def add_signal(agent_id, signal) do
    signals = get_signals(agent_id)
    updated = [signal | signals] |> Enum.take(@max_signals)
    :ets.insert(@signal_table, {agent_id, updated})
    updated
  rescue
    ArgumentError -> [signal]
  end

  # ── Identity Evolution ────────────────────────────────────────────

  def get_identity_state(agent_id) do
    case :ets.lookup(@identity_table, agent_id) do
      [{^agent_id, state}] -> state
      [] -> %{insights: [], identity_changes: [], last_consolidation: nil}
    end
  rescue
    ArgumentError -> %{insights: [], identity_changes: [], last_consolidation: nil}
  end

  def add_insight(agent_id, insight) do
    state = get_identity_state(agent_id)
    insights = [insight | state.insights] |> Enum.take(@max_insights)
    updated = %{state | insights: insights}
    :ets.insert(@identity_table, {agent_id, updated})
    updated
  rescue
    ArgumentError -> %{insights: [insight], identity_changes: [], last_consolidation: nil}
  end

  def add_identity_change(agent_id, change) do
    state = get_identity_state(agent_id)
    changes = [change | state.identity_changes] |> Enum.take(@max_identity_changes)
    updated = %{state | identity_changes: changes}
    :ets.insert(@identity_table, {agent_id, updated})
    updated
  rescue
    ArgumentError -> %{insights: [], identity_changes: [change], last_consolidation: nil}
  end

  def set_consolidation(agent_id, consolidation_data) do
    state = get_identity_state(agent_id)
    updated = %{state | last_consolidation: consolidation_data}
    :ets.insert(@identity_table, {agent_id, updated})
    updated
  rescue
    ArgumentError -> %{insights: [], identity_changes: [], last_consolidation: consolidation_data}
  end

  # ── Cognitive Preferences ─────────────────────────────────────────

  def get_cognitive_state(agent_id) do
    case :ets.lookup(@cognitive_table, agent_id) do
      [{^agent_id, state}] -> state
      [] -> %{current_prefs: nil, adjustments: [], pinned_count: 0}
    end
  rescue
    ArgumentError -> %{current_prefs: nil, adjustments: [], pinned_count: 0}
  end

  def set_cognitive_prefs(agent_id, prefs) do
    state = get_cognitive_state(agent_id)
    updated = %{state | current_prefs: prefs}
    :ets.insert(@cognitive_table, {agent_id, updated})
    updated
  rescue
    ArgumentError -> %{current_prefs: prefs, adjustments: [], pinned_count: 0}
  end

  def add_cognitive_adjustment(agent_id, adjustment) do
    state = get_cognitive_state(agent_id)
    adjustments = [adjustment | state.adjustments] |> Enum.take(@max_cognitive_adjustments)
    updated = %{state | adjustments: adjustments}
    :ets.insert(@cognitive_table, {agent_id, updated})
    updated
  rescue
    ArgumentError -> %{current_prefs: nil, adjustments: [adjustment], pinned_count: 0}
  end

  def set_pinned_count(agent_id, count) do
    state = get_cognitive_state(agent_id)
    updated = %{state | pinned_count: count}
    :ets.insert(@cognitive_table, {agent_id, updated})
    updated
  rescue
    ArgumentError -> %{current_prefs: nil, adjustments: [], pinned_count: count}
  end

  # ── Code Modules ──────────────────────────────────────────────────

  def get_code_modules(agent_id) do
    case :ets.lookup(@code_table, agent_id) do
      [{^agent_id, modules}] -> modules
      [] -> []
    end
  rescue
    ArgumentError -> []
  end

  def add_code_module(agent_id, module_info) do
    modules = get_code_modules(agent_id)

    updated =
      if Enum.any?(modules, &(&1.name == module_info.name)) do
        Enum.map(modules, fn m ->
          if m.name == module_info.name, do: module_info, else: m
        end)
      else
        [module_info | modules] |> Enum.take(@max_code_modules)
      end

    :ets.insert(@code_table, {agent_id, updated})
    updated
  rescue
    ArgumentError -> [module_info]
  end

  def remove_code_module(agent_id, module_name) do
    modules = get_code_modules(agent_id)
    updated = Enum.reject(modules, &(&1.name == module_name))
    :ets.insert(@code_table, {agent_id, updated})
    updated
  rescue
    ArgumentError -> []
  end

  # ── Recent Agents ─────────────────────────────────────────────────

  def get_recent_agents do
    case :ets.lookup(@recent_table, :recent_list) do
      [{:recent_list, agents}] -> agents
      [] -> []
    end
  rescue
    ArgumentError -> []
  end

  def touch_agent(agent_id) do
    agents = get_recent_agents()
    {existing, others} = Enum.split_with(agents, fn a -> a.agent_id == agent_id end)

    updated_entry =
      case existing do
        [entry] ->
          %{entry | last_seen: DateTime.utc_now(), message_count: entry.message_count + 1}

        [] ->
          %{agent_id: agent_id, last_seen: DateTime.utc_now(), message_count: 1}
      end

    updated =
      [updated_entry | others]
      |> Enum.sort_by(& &1.last_seen, {:desc, DateTime})
      |> Enum.take(@max_recent_agents)

    :ets.insert(@recent_table, {:recent_list, updated})
    updated
  rescue
    ArgumentError ->
      [%{agent_id: agent_id, last_seen: DateTime.utc_now(), message_count: 1}]
  end

  def remove_recent_agent(agent_id) do
    agents = get_recent_agents()
    updated = Enum.reject(agents, fn a -> a.agent_id == agent_id end)
    :ets.insert(@recent_table, {:recent_list, updated})
    updated
  rescue
    ArgumentError -> []
  end

  # ── Cleanup ───────────────────────────────────────────────────────

  def clear(agent_id) do
    for table <- @tables -- [@recent_table] do
      :ets.delete(table, agent_id)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end
end
