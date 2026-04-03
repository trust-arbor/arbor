defmodule Arbor.Dashboard.Cores.TelemetryCore do
  @moduledoc """
  Pure business logic for the telemetry dashboard.

  Follows the Construct-Reduce-Convert pattern. All functions are pure
  and side-effect free — no ETS reads, no GenServer calls.

  ## Pipeline

      telemetry_list
      |> TelemetryCore.new()
      |> TelemetryCore.sort_by(:cost)
      |> TelemetryCore.show_overview()
  """

  alias Arbor.Contracts.Agent.Telemetry

  # Local percentile to keep this module pure (no cross-library calls)
  defp percentile([], _p), do: nil

  defp percentile(values, p) when p >= 0 and p <= 100 do
    sorted = Enum.sort(values)
    count = length(sorted)
    rank = max(1, ceil(p / 100 * count))
    Enum.at(sorted, rank - 1)
  end

  @type state :: %{
          agents: [Telemetry.t()],
          selected_agent_id: String.t() | nil,
          sort_field: atom()
        }

  # ===========================================================================
  # Construct
  # ===========================================================================

  @doc """
  Create display-ready state from a list of `%Telemetry{}` structs.
  """
  @spec new([Telemetry.t()]) :: state()
  def new(telemetry_list) when is_list(telemetry_list) do
    %{
      agents: telemetry_list,
      selected_agent_id: nil,
      sort_field: :name
    }
  end

  # ===========================================================================
  # Reduce
  # ===========================================================================

  @doc """
  Select an agent for detail view. Passing `nil` deselects.
  """
  @spec select_agent(state(), String.t() | nil) :: state()
  def select_agent(state, agent_id) do
    # Toggle: clicking the same agent deselects
    if state.selected_agent_id == agent_id do
      %{state | selected_agent_id: nil}
    else
      %{state | selected_agent_id: agent_id}
    end
  end

  @doc """
  Sort the agent list by the given field.
  """
  @spec sort_by(state(), atom()) :: state()
  def sort_by(state, :name) do
    sorted = Enum.sort_by(state.agents, & &1.agent_id)
    %{state | agents: sorted, sort_field: :name}
  end

  def sort_by(state, :cost) do
    sorted = Enum.sort_by(state.agents, & &1.lifetime_cost, :desc)
    %{state | agents: sorted, sort_field: :cost}
  end

  def sort_by(state, :turns) do
    sorted = Enum.sort_by(state.agents, & &1.turn_count, :desc)
    %{state | agents: sorted, sort_field: :turns}
  end

  def sort_by(state, :latency) do
    sorted =
      Enum.sort_by(
        state.agents,
        fn t -> percentile(t.llm_latencies, 50) || 0 end,
        :desc
      )

    %{state | agents: sorted, sort_field: :latency}
  end

  def sort_by(state, _unknown), do: state

  # ===========================================================================
  # Convert
  # ===========================================================================

  @doc """
  Aggregate stats across all agents for overview cards.
  """
  @spec show_overview(state()) :: map()
  def show_overview(state) do
    agents = state.agents

    total_cost =
      Enum.reduce(agents, 0.0, fn t, acc -> acc + t.lifetime_cost end)

    total_turns =
      Enum.reduce(agents, 0, fn t, acc -> acc + t.turn_count end)

    all_latencies =
      Enum.flat_map(agents, & &1.llm_latencies)

    p50 = percentile(all_latencies, 50)

    %{
      total_agents: length(agents),
      total_cost: total_cost,
      total_cost_formatted: format_cost(total_cost),
      total_turns: total_turns,
      avg_latency_p50: p50,
      avg_latency_p50_formatted: format_latency(p50)
    }
  end

  @doc """
  Build the agent table data from current state.
  """
  @spec show_agent_table(state()) :: [map()]
  def show_agent_table(state) do
    Enum.map(state.agents, fn t ->
      p50 = percentile(t.llm_latencies, 50)
      tool_count = map_size(t.tool_stats)

      %{
        agent_id: t.agent_id,
        turn_count: t.turn_count,
        lifetime_cost: t.lifetime_cost,
        cost_formatted: format_cost(t.lifetime_cost),
        p50_latency: p50,
        p50_formatted: format_latency(p50),
        tool_count: tool_count,
        selected: t.agent_id == state.selected_agent_id
      }
    end)
  end

  @doc """
  Detailed view for the selected agent. Returns `nil` if none selected.
  """
  @spec show_agent_detail(state()) :: map() | nil
  def show_agent_detail(%{selected_agent_id: nil}), do: nil

  def show_agent_detail(state) do
    case Enum.find(state.agents, &(&1.agent_id == state.selected_agent_id)) do
      nil ->
        nil

      t ->
        p50 = percentile(t.llm_latencies, 50)
        p95 = percentile(t.llm_latencies, 95)

        tool_report =
          Enum.map(t.tool_stats, fn {name, stats} ->
            total = stats.calls

            success_rate =
              if total > 0, do: Float.round(stats.succeeded / total * 100, 1), else: 0.0

            %{
              name: name,
              calls: total,
              succeeded: stats.succeeded,
              failed: stats.failed,
              gated: stats.gated,
              success_rate: success_rate,
              avg_duration_ms: if(total > 0, do: div(stats.total_duration_ms, total), else: 0)
            }
          end)
          |> Enum.sort_by(& &1.calls, :desc)

        cost_by_provider =
          Enum.map(t.cost_by_provider, fn {provider, cost} ->
            %{provider: provider, cost: cost, cost_formatted: format_cost(cost)}
          end)
          |> Enum.sort_by(& &1.cost, :desc)

        %{
          agent_id: t.agent_id,
          turn_count: t.turn_count,
          tokens: %{
            session: %{
              input: t.session_input_tokens,
              output: t.session_output_tokens,
              cached: t.session_cached_tokens,
              input_formatted: format_tokens(t.session_input_tokens),
              output_formatted: format_tokens(t.session_output_tokens),
              cached_formatted: format_tokens(t.session_cached_tokens)
            },
            lifetime: %{
              input: t.lifetime_input_tokens,
              output: t.lifetime_output_tokens,
              cached: t.lifetime_cached_tokens,
              input_formatted: format_tokens(t.lifetime_input_tokens),
              output_formatted: format_tokens(t.lifetime_output_tokens),
              cached_formatted: format_tokens(t.lifetime_cached_tokens)
            }
          },
          cost: %{
            session: t.session_cost,
            session_formatted: format_cost(t.session_cost),
            lifetime: t.lifetime_cost,
            lifetime_formatted: format_cost(t.lifetime_cost),
            by_provider: cost_by_provider
          },
          latency: %{
            p50: p50,
            p95: p95,
            p50_formatted: format_latency(p50),
            p95_formatted: format_latency(p95)
          },
          tool_report: tool_report,
          routing: t.routing_stats,
          compaction: %{
            count: t.compaction_count,
            avg_utilization: Float.round(t.avg_utilization * 100, 1)
          }
        }
    end
  end

  # ===========================================================================
  # Historical Data (Convert)
  # ===========================================================================

  @doc """
  Format a list of telemetry events for timeline display.

  Returns a list of maps with human-readable event descriptions,
  sorted by timestamp descending (most recent first).
  """
  @spec show_event_timeline([map()]) :: [map()]
  def show_event_timeline(events) when is_list(events) do
    events
    |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
    |> Enum.map(&format_event/1)
  end

  @doc """
  Aggregate cost by hour for trend display.

  Returns a list of `%{period, cost, cost_formatted, turn_count}` maps
  sorted chronologically.
  """
  @spec show_cost_over_time([map()]) :: [map()]
  def show_cost_over_time(events) when is_list(events) do
    events
    |> Enum.filter(&(&1.event_type == "turn_completed"))
    |> Enum.group_by(fn event ->
      ts = event.timestamp
      # Truncate to hour
      %{ts | minute: 0, second: 0, microsecond: {0, 0}}
    end)
    |> Enum.map(fn {hour, hour_events} ->
      cost =
        Enum.reduce(hour_events, 0.0, fn e, acc ->
          acc + (get_data(e.data, "cost", 0.0) || 0.0)
        end)

      %{
        period: Calendar.strftime(hour, "%Y-%m-%d %H:%M"),
        cost: cost,
        cost_formatted: format_cost(cost),
        turn_count: length(hour_events)
      }
    end)
    |> Enum.sort_by(& &1.period)
  end

  @doc """
  List recent tool failures with timestamps.

  Returns events where the tool result was `:error` or `"error"`.
  """
  @spec show_tool_failures([map()]) :: [map()]
  def show_tool_failures(events) when is_list(events) do
    events
    |> Enum.filter(fn e ->
      e.event_type == "tool_call" and
        get_data(e.data, "result", nil) in ["error", :error]
    end)
    |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
    |> Enum.map(&format_event/1)
  end

  @doc """
  Format a single telemetry event for display.
  """
  @spec format_event(map()) :: map()
  def format_event(%{event_type: type, timestamp: ts, data: data} = event) do
    %{
      id: Map.get(event, :id, ""),
      agent_id: Map.get(event, :agent_id, ""),
      event_type: type,
      timestamp: format_timestamp(ts),
      description: describe_event(type, data),
      data: data
    }
  end

  defp describe_event("turn_completed", data) do
    cost = get_data(data, "cost", 0.0)
    input = get_data(data, "input_tokens", 0)
    output = get_data(data, "output_tokens", 0)
    provider = get_data(data, "provider", "unknown")
    "LLM turn (#{provider}): #{input}in/#{output}out, #{format_cost(cost)}"
  end

  defp describe_event("tool_call", data) do
    tool = get_data(data, "tool_name", "unknown")
    result = get_data(data, "result", "unknown")
    ms = get_data(data, "duration_ms", 0)
    "Tool #{tool}: #{result} (#{ms}ms)"
  end

  defp describe_event("routing_decision", data) do
    decision = get_data(data, "decision", "unknown")
    "Routing: #{decision}"
  end

  defp describe_event("compaction", data) do
    util = get_data(data, "utilization", 0.0)

    pct =
      if is_number(util) do
        Float.round(util * 100, 1)
      else
        0.0
      end

    "Compaction at #{pct}% utilization"
  end

  defp describe_event(type, _data), do: "#{type}"

  # Handle both string and atom keys in data maps
  defp get_data(data, key, default) when is_map(data) do
    case Map.get(data, key) do
      nil ->
        atom_key =
          try do
            String.to_existing_atom(key)
          rescue
            ArgumentError -> nil
          end

        if atom_key, do: Map.get(data, atom_key, default), else: default

      val ->
        val
    end
  end

  defp get_data(_data, _key, default), do: default

  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  defp format_timestamp(other), do: inspect(other)

  # ===========================================================================
  # Formatters (pure)
  # ===========================================================================

  @doc "Format a cost float as a dollar string."
  @spec format_cost(number()) :: String.t()
  def format_cost(cost) when is_number(cost) do
    "$#{:erlang.float_to_binary(cost / 1, decimals: 4)}"
  end

  def format_cost(_), do: "$0.0000"

  @doc "Format milliseconds as human-readable latency."
  @spec format_latency(non_neg_integer() | nil) :: String.t()
  def format_latency(nil), do: "-"
  def format_latency(ms) when ms >= 1000, do: "#{Float.round(ms / 1000, 1)}s"
  def format_latency(ms), do: "#{ms}ms"

  @doc "Format a token count with K suffix for thousands."
  @spec format_tokens(non_neg_integer()) :: String.t()
  def format_tokens(count) when count >= 1000 do
    "#{Float.round(count / 1000, 1)}K"
  end

  def format_tokens(count), do: "#{count}"
end
