defmodule Arbor.Common.AgentTelemetry do
  @moduledoc """
  Pure functional CRC module for agent telemetry metrics.

  Follows the Construct-Reduce-Convert pattern:

  - **Construct**: `new/1` creates a zeroed telemetry struct
  - **Reduce**: `record_turn/2`, `record_tool/4`, `record_routing/2`,
    `record_compaction/2`, `reset_session/1` — pure transformations
  - **Convert**: `show_dashboard/1`, `show_cost_report/1`, `show_tool_report/1`
    — formatted output for display

  This module has NO side effects. All state is passed in and returned.
  For persistent storage, see `Arbor.Common.AgentTelemetry.Store`.
  """

  alias Arbor.Contracts.Agent.Telemetry

  @max_latency_window 100

  # ===========================================================================
  # Construct
  # ===========================================================================

  @doc """
  Create a new telemetry struct with zeroed metrics for the given agent.
  """
  @spec new(String.t()) :: Telemetry.t()
  def new(agent_id) when is_binary(agent_id) do
    now = DateTime.utc_now()

    %Telemetry{
      agent_id: agent_id,
      created_at: now,
      updated_at: now
    }
  end

  # ===========================================================================
  # Reduce (pure transformations)
  # ===========================================================================

  @doc """
  Record a completed LLM turn.

  `usage` is a map with optional keys:
  - `:input_tokens` — tokens consumed from the prompt
  - `:output_tokens` — tokens generated in the response
  - `:cached_tokens` — tokens served from cache
  - `:cost` — monetary cost of this call (float)
  - `:duration_ms` — wall-clock time for the LLM call
  - `:provider` — provider name string (e.g., "anthropic", "openai")
  """
  @spec record_turn(Telemetry.t(), map()) :: Telemetry.t()
  def record_turn(%Telemetry{} = t, usage) when is_map(usage) do
    input = Map.get(usage, :input_tokens, 0)
    output = Map.get(usage, :output_tokens, 0)
    cached = Map.get(usage, :cached_tokens, 0)
    cost = Map.get(usage, :cost, 0.0)
    duration_ms = Map.get(usage, :duration_ms, nil)
    provider = Map.get(usage, :provider, nil)

    cost_by_provider =
      if provider do
        Map.update(t.cost_by_provider, to_string(provider), cost, &(&1 + cost))
      else
        t.cost_by_provider
      end

    llm_latencies =
      if duration_ms do
        append_to_window(t.llm_latencies, duration_ms)
      else
        t.llm_latencies
      end

    %Telemetry{
      t
      | session_input_tokens: t.session_input_tokens + input,
        session_output_tokens: t.session_output_tokens + output,
        session_cached_tokens: t.session_cached_tokens + cached,
        session_cost: t.session_cost + cost,
        lifetime_input_tokens: t.lifetime_input_tokens + input,
        lifetime_output_tokens: t.lifetime_output_tokens + output,
        lifetime_cached_tokens: t.lifetime_cached_tokens + cached,
        lifetime_cost: t.lifetime_cost + cost,
        cost_by_provider: cost_by_provider,
        turn_count: t.turn_count + 1,
        llm_latencies: llm_latencies,
        updated_at: DateTime.utc_now()
    }
  end

  @doc """
  Record a tool call.

  - `tool_name` — the tool identifier (e.g., "file.read")
  - `result` — `:ok`, `:error`, or `:gated`
  - `duration_ms` — wall-clock time for the tool execution
  """
  @spec record_tool(Telemetry.t(), String.t(), :ok | :error | :gated, non_neg_integer()) ::
          Telemetry.t()
  def record_tool(%Telemetry{} = t, tool_name, result, duration_ms)
      when is_binary(tool_name) and result in [:ok, :error, :gated] and is_integer(duration_ms) do
    default_stats = %{calls: 0, succeeded: 0, failed: 0, gated: 0, total_duration_ms: 0}
    stats = Map.get(t.tool_stats, tool_name, default_stats)

    stats =
      stats
      |> Map.update!(:calls, &(&1 + 1))
      |> Map.update!(:total_duration_ms, &(&1 + duration_ms))
      |> increment_result(result)

    tool_latencies = append_to_window(t.tool_latencies, duration_ms)

    %Telemetry{
      t
      | tool_stats: Map.put(t.tool_stats, tool_name, stats),
        tool_latencies: tool_latencies,
        updated_at: DateTime.utc_now()
    }
  end

  @doc """
  Record a sensitivity routing decision.

  `decision` is one of `:classified`, `:rerouted`, `:tokenized`, or `:blocked`.
  """
  @spec record_routing(Telemetry.t(), :classified | :rerouted | :tokenized | :blocked) ::
          Telemetry.t()
  def record_routing(%Telemetry{} = t, decision)
      when decision in [:classified, :rerouted, :tokenized, :blocked] do
    routing = Map.update!(t.routing_stats, decision, &(&1 + 1))

    %Telemetry{t | routing_stats: routing, updated_at: DateTime.utc_now()}
  end

  @doc """
  Record a context compaction event.

  `utilization_pct` is the context utilization percentage (0.0 to 1.0) at the
  time of compaction. The running average is updated incrementally.
  """
  @spec record_compaction(Telemetry.t(), float()) :: Telemetry.t()
  def record_compaction(%Telemetry{} = t, utilization_pct)
      when is_float(utilization_pct) do
    new_count = t.compaction_count + 1

    # Incremental running average: avg = avg + (new - avg) / count
    new_avg = t.avg_utilization + (utilization_pct - t.avg_utilization) / new_count

    %Telemetry{
      t
      | compaction_count: new_count,
        avg_utilization: new_avg,
        updated_at: DateTime.utc_now()
    }
  end

  @doc """
  Reset session-scoped metrics without touching lifetime metrics.

  Clears session token counts and session cost. Lifetime counters,
  tool stats, latency windows, and routing stats are preserved.
  """
  @spec reset_session(Telemetry.t()) :: Telemetry.t()
  def reset_session(%Telemetry{} = t) do
    %Telemetry{
      t
      | session_input_tokens: 0,
        session_output_tokens: 0,
        session_cached_tokens: 0,
        session_cost: 0.0,
        updated_at: DateTime.utc_now()
    }
  end

  # ===========================================================================
  # Convert (output/display)
  # ===========================================================================

  @doc """
  Format telemetry for dashboard display.

  Returns a map with human-readable values including formatted costs,
  latency percentiles, and tool success rates.
  """
  @spec show_dashboard(Telemetry.t()) :: map()
  def show_dashboard(%Telemetry{} = t) do
    %{
      agent_id: t.agent_id,
      turn_count: t.turn_count,
      session: %{
        input_tokens: t.session_input_tokens,
        output_tokens: t.session_output_tokens,
        cached_tokens: t.session_cached_tokens,
        cost: format_cost(t.session_cost)
      },
      lifetime: %{
        input_tokens: t.lifetime_input_tokens,
        output_tokens: t.lifetime_output_tokens,
        cached_tokens: t.lifetime_cached_tokens,
        cost: format_cost(t.lifetime_cost)
      },
      latency: %{
        llm_p50_ms: percentile(t.llm_latencies, 50),
        llm_p95_ms: percentile(t.llm_latencies, 95),
        tool_p50_ms: percentile(t.tool_latencies, 50),
        tool_p95_ms: percentile(t.tool_latencies, 95)
      },
      tool_success_rate: tool_success_rate(t.tool_stats),
      routing: t.routing_stats,
      compaction: %{
        count: t.compaction_count,
        avg_utilization: Float.round(t.avg_utilization * 100, 1)
      }
    }
  end

  @doc """
  Return a cost breakdown by provider.
  """
  @spec show_cost_report(Telemetry.t()) :: map()
  def show_cost_report(%Telemetry{} = t) do
    provider_breakdown =
      Map.new(t.cost_by_provider, fn {provider, cost} ->
        {provider, format_cost(cost)}
      end)

    %{
      session_cost: format_cost(t.session_cost),
      lifetime_cost: format_cost(t.lifetime_cost),
      by_provider: provider_breakdown
    }
  end

  @doc """
  Return per-tool success/failure/gated rates.
  """
  @spec show_tool_report(Telemetry.t()) :: map()
  def show_tool_report(%Telemetry{} = t) do
    Map.new(t.tool_stats, fn {name, stats} ->
      total = stats.calls

      rates =
        if total > 0 do
          %{
            calls: total,
            success_rate: Float.round(stats.succeeded / total * 100, 1),
            failure_rate: Float.round(stats.failed / total * 100, 1),
            gated_rate: Float.round(stats.gated / total * 100, 1),
            avg_duration_ms: div(stats.total_duration_ms, total)
          }
        else
          %{calls: 0, success_rate: 0.0, failure_rate: 0.0, gated_rate: 0.0, avg_duration_ms: 0}
        end

      {name, rates}
    end)
  end

  # ===========================================================================
  # Latency helpers
  # ===========================================================================

  @doc """
  Calculate the Pth percentile from a list of values.

  Returns `nil` if the list is empty.
  """
  @spec percentile([non_neg_integer()], number()) :: non_neg_integer() | nil
  def percentile([], _p), do: nil

  def percentile(values, p) when p >= 0 and p <= 100 do
    sorted = Enum.sort(values)
    count = length(sorted)
    # Use nearest-rank method
    rank = max(1, ceil(p / 100 * count))
    Enum.at(sorted, rank - 1)
  end

  # ===========================================================================
  # Private helpers
  # ===========================================================================

  defp append_to_window(list, value) do
    new_list = list ++ [value]

    if length(new_list) > @max_latency_window do
      Enum.drop(new_list, length(new_list) - @max_latency_window)
    else
      new_list
    end
  end

  defp increment_result(stats, :ok), do: Map.update!(stats, :succeeded, &(&1 + 1))
  defp increment_result(stats, :error), do: Map.update!(stats, :failed, &(&1 + 1))
  defp increment_result(stats, :gated), do: Map.update!(stats, :gated, &(&1 + 1))

  defp format_cost(cost) when is_float(cost) or is_integer(cost) do
    "$#{:erlang.float_to_binary(cost / 1, decimals: 4)}"
  end

  defp tool_success_rate(tool_stats) when map_size(tool_stats) == 0, do: %{}

  defp tool_success_rate(tool_stats) do
    Map.new(tool_stats, fn {name, stats} ->
      rate =
        if stats.calls > 0,
          do: Float.round(stats.succeeded / stats.calls * 100, 1),
          else: 0.0

      {name, rate}
    end)
  end
end
