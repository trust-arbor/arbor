defmodule Arbor.Dashboard.Components.TelemetryComponent do
  @moduledoc """
  Socket-first delegate component for the telemetry dashboard.

  Manages telemetry state on the parent LiveView's socket. Provides mount,
  update, and function component functions that the LiveView delegates to.

  Events are namespaced as `"telemetry:<action>"`.
  """

  use Phoenix.Component

  alias Arbor.Dashboard.Cores.TelemetryCore

  # ===========================================================================
  # Mount / Update (socket delegation)
  # ===========================================================================

  @doc """
  Initialize telemetry assigns on the socket.
  """
  def mount(socket, _opts) do
    telemetry_list = fetch_all_telemetry()
    state = TelemetryCore.new(telemetry_list) |> TelemetryCore.sort_by(:cost)

    socket
    |> Phoenix.Component.assign(:telemetry_state, state)
    |> Phoenix.Component.assign(:telemetry_overview, TelemetryCore.show_overview(state))
    |> Phoenix.Component.assign(:telemetry_agents, TelemetryCore.show_agent_table(state))
    |> Phoenix.Component.assign(:selected_agent_telemetry, nil)
    |> Phoenix.Component.assign(:sort_field, :cost)
    |> Phoenix.Component.assign(:history_events, [])
    |> Phoenix.Component.assign(:history_cost_trend, [])
    |> Phoenix.Component.assign(:history_tool_failures, [])
    |> Phoenix.Component.assign(:history_loaded, false)
  end

  @doc """
  Handle telemetry events. Called from the LiveView's handle_event.
  """
  def update_telemetry(socket, "refresh") do
    telemetry_list = fetch_all_telemetry()

    state =
      TelemetryCore.new(telemetry_list)
      |> TelemetryCore.sort_by(socket.assigns.sort_field)
      |> maybe_reselect(socket.assigns.telemetry_state.selected_agent_id)

    rebuild_assigns(socket, state)
  end

  # Catch-all for unknown 2-arg events
  def update_telemetry(socket, _event), do: socket

  def update_telemetry(socket, "load_history", %{"agent_id" => agent_id}) do
    events = fetch_history_events(agent_id)
    timeline = TelemetryCore.show_event_timeline(events)
    cost_trend = TelemetryCore.show_cost_over_time(events)
    tool_failures = TelemetryCore.show_tool_failures(events)

    socket
    |> Phoenix.Component.assign(:history_events, timeline)
    |> Phoenix.Component.assign(:history_cost_trend, cost_trend)
    |> Phoenix.Component.assign(:history_tool_failures, tool_failures)
    |> Phoenix.Component.assign(:history_loaded, true)
  end

  def update_telemetry(socket, "select_agent", %{"id" => agent_id}) do
    state = TelemetryCore.select_agent(socket.assigns.telemetry_state, agent_id)
    rebuild_assigns(socket, state)
  end

  def update_telemetry(socket, "sort", %{"field" => field}) do
    sort_field = safe_sort_field(field)
    state = TelemetryCore.sort_by(socket.assigns.telemetry_state, sort_field)

    socket
    |> Phoenix.Component.assign(:telemetry_state, state)
    |> Phoenix.Component.assign(:telemetry_agents, TelemetryCore.show_agent_table(state))
    |> Phoenix.Component.assign(:sort_field, sort_field)
  end

  # Catch-all for unknown 3-arg events
  def update_telemetry(socket, _event, _params), do: socket

  # ===========================================================================
  # Function Components
  # ===========================================================================

  @doc """
  Overview cards showing aggregate stats.
  """
  attr :telemetry_overview, :map, required: true

  def overview_cards(assigns) do
    ~H"""
    <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 1rem;">
      <.stat_card label="Total Agents" value={@telemetry_overview.total_agents} />
      <.stat_card label="Total Cost" value={@telemetry_overview.total_cost_formatted} />
      <.stat_card label="Total Turns" value={@telemetry_overview.total_turns} />
      <.stat_card label="Avg Latency P50" value={@telemetry_overview.avg_latency_p50_formatted} />
    </div>
    """
  end

  @doc """
  Sortable table of agents with key metrics.
  """
  attr :telemetry_agents, :list, required: true
  attr :sort_field, :atom, default: :cost

  def agent_table(assigns) do
    ~H"""
    <div class="aw-card" style="margin-top: 1rem; overflow-x: auto;">
      <table style="width: 100%; border-collapse: collapse; font-size: 0.875rem;">
        <thead>
          <tr style="border-bottom: 1px solid var(--aw-border, #333); text-align: left;">
            <th style="padding: 0.5rem 0.75rem;">
              <button
                phx-click="telemetry:sort"
                phx-value-field="name"
                style={"font-weight: #{if @sort_field == :name, do: "700", else: "400"}; background: none; border: none; color: var(--aw-text-primary, #e4e4e7); cursor: pointer; padding: 0;"}
              >
                Agent {if @sort_field == :name, do: sort_indicator()}
              </button>
            </th>
            <th style="padding: 0.5rem 0.75rem; text-align: right;">
              <button
                phx-click="telemetry:sort"
                phx-value-field="turns"
                style={"font-weight: #{if @sort_field == :turns, do: "700", else: "400"}; background: none; border: none; color: var(--aw-text-primary, #e4e4e7); cursor: pointer; padding: 0;"}
              >
                Turns {if @sort_field == :turns, do: sort_indicator()}
              </button>
            </th>
            <th style="padding: 0.5rem 0.75rem; text-align: right;">
              <button
                phx-click="telemetry:sort"
                phx-value-field="cost"
                style={"font-weight: #{if @sort_field == :cost, do: "700", else: "400"}; background: none; border: none; color: var(--aw-text-primary, #e4e4e7); cursor: pointer; padding: 0;"}
              >
                Cost {if @sort_field == :cost, do: sort_indicator()}
              </button>
            </th>
            <th style="padding: 0.5rem 0.75rem; text-align: right;">
              <button
                phx-click="telemetry:sort"
                phx-value-field="latency"
                style={"font-weight: #{if @sort_field == :latency, do: "700", else: "400"}; background: none; border: none; color: var(--aw-text-primary, #e4e4e7); cursor: pointer; padding: 0;"}
              >
                P50 Latency {if @sort_field == :latency, do: sort_indicator()}
              </button>
            </th>
            <th style="padding: 0.5rem 0.75rem; text-align: right;">Tools</th>
          </tr>
        </thead>
        <tbody>
          <%= for agent <- @telemetry_agents do %>
            <tr
              phx-click="telemetry:select_agent"
              phx-value-id={agent.agent_id}
              style={"padding: 0.5rem; cursor: pointer; border-bottom: 1px solid var(--aw-border, #222); #{if agent.selected, do: "background: var(--aw-bg-active, rgba(99,102,241,0.15));"}"}
            >
              <td style="padding: 0.5rem 0.75rem; font-family: monospace; font-size: 0.8rem;">
                {truncate_id(agent.agent_id)}
              </td>
              <td style="padding: 0.5rem 0.75rem; text-align: right;">{agent.turn_count}</td>
              <td style="padding: 0.5rem 0.75rem; text-align: right;">{agent.cost_formatted}</td>
              <td style="padding: 0.5rem 0.75rem; text-align: right;">{agent.p50_formatted}</td>
              <td style="padding: 0.5rem 0.75rem; text-align: right;">{agent.tool_count}</td>
            </tr>
          <% end %>

          <%= if @telemetry_agents == [] do %>
            <tr>
              <td
                colspan="5"
                style="padding: 2rem; text-align: center; color: var(--aw-text-secondary, #71717a);"
              >
                No agent telemetry data available
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Detailed telemetry breakdown for the selected agent.
  """
  attr :selected_agent_telemetry, :map, required: true

  def agent_detail(assigns) do
    ~H"""
    <div class="aw-card" style="margin-top: 1rem; padding: 1.25rem;">
      <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 1rem;">
        <h2 style="font-size: 1.1rem; font-weight: 600; font-family: monospace;">
          {truncate_id(@selected_agent_telemetry.agent_id)}
        </h2>
        <div style="display: flex; gap: 0.75rem; align-items: center;">
          <span style="font-size: 0.8rem; color: var(--aw-text-secondary, #71717a);">
            {Integer.to_string(@selected_agent_telemetry.turn_count)} turns
          </span>
          <button
            phx-click="telemetry:load_history"
            phx-value-agent_id={@selected_agent_telemetry.agent_id}
            class="aw-btn"
            style="font-size: 0.75rem; padding: 0.25rem 0.5rem;"
          >
            Load History
          </button>
        </div>
      </div>

      <%!-- Token Breakdown --%>
      <div style="margin-bottom: 1.25rem;">
        <h3 style="font-size: 0.9rem; font-weight: 600; margin-bottom: 0.5rem;">Token Usage</h3>
        <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 1rem;">
          <div>
            <div style="font-size: 0.75rem; color: var(--aw-text-secondary, #71717a); margin-bottom: 0.25rem;">
              Session
            </div>
            <div style="font-size: 0.8rem;">
              In: {@selected_agent_telemetry.tokens.session.input_formatted} |
              Out: {@selected_agent_telemetry.tokens.session.output_formatted} |
              Cached: {@selected_agent_telemetry.tokens.session.cached_formatted}
            </div>
          </div>
          <div>
            <div style="font-size: 0.75rem; color: var(--aw-text-secondary, #71717a); margin-bottom: 0.25rem;">
              Lifetime
            </div>
            <div style="font-size: 0.8rem;">
              In: {@selected_agent_telemetry.tokens.lifetime.input_formatted} |
              Out: {@selected_agent_telemetry.tokens.lifetime.output_formatted} |
              Cached: {@selected_agent_telemetry.tokens.lifetime.cached_formatted}
            </div>
          </div>
        </div>
      </div>

      <%!-- Cost by Provider --%>
      <.cost_chart cost={@selected_agent_telemetry.cost} />

      <%!-- Latency --%>
      <div style="margin-bottom: 1.25rem;">
        <h3 style="font-size: 0.9rem; font-weight: 600; margin-bottom: 0.5rem;">Latency</h3>
        <div style="display: flex; gap: 2rem; font-size: 0.875rem;">
          <div>
            <span style="color: var(--aw-text-secondary, #71717a);">P50:</span>
            <strong>{@selected_agent_telemetry.latency.p50_formatted}</strong>
          </div>
          <div>
            <span style="color: var(--aw-text-secondary, #71717a);">P95:</span>
            <strong>{@selected_agent_telemetry.latency.p95_formatted}</strong>
          </div>
        </div>
      </div>

      <%!-- Routing Stats --%>
      <div style="margin-bottom: 1.25rem;">
        <h3 style="font-size: 0.9rem; font-weight: 600; margin-bottom: 0.5rem;">Routing</h3>
        <div style="display: flex; gap: 1.5rem; font-size: 0.8rem;">
          <div>Classified: <strong>{@selected_agent_telemetry.routing.classified}</strong></div>
          <div>Rerouted: <strong>{@selected_agent_telemetry.routing.rerouted}</strong></div>
          <div>Tokenized: <strong>{@selected_agent_telemetry.routing.tokenized}</strong></div>
          <div>Blocked: <strong>{@selected_agent_telemetry.routing.blocked}</strong></div>
        </div>
      </div>

      <%!-- Tool Report --%>
      <.tool_report tool_report={@selected_agent_telemetry.tool_report} />

      <%!-- Compaction --%>
      <div>
        <h3 style="font-size: 0.9rem; font-weight: 600; margin-bottom: 0.5rem;">Compaction</h3>
        <div style="font-size: 0.8rem;">
          Count: <strong>{@selected_agent_telemetry.compaction.count}</strong> |
          Avg Utilization: <strong>{@selected_agent_telemetry.compaction.avg_utilization}%</strong>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Per-tool success/failure/gated breakdown.
  """
  attr :tool_report, :list, required: true

  def tool_report(assigns) do
    ~H"""
    <div style="margin-bottom: 1.25rem;">
      <h3 style="font-size: 0.9rem; font-weight: 600; margin-bottom: 0.5rem;">Tool Report</h3>
      <%= if @tool_report == [] do %>
        <div style="font-size: 0.8rem; color: var(--aw-text-secondary, #71717a);">
          No tool calls recorded
        </div>
      <% else %>
        <table style="width: 100%; border-collapse: collapse; font-size: 0.8rem;">
          <thead>
            <tr style="border-bottom: 1px solid var(--aw-border, #333); text-align: left;">
              <th style="padding: 0.35rem 0.5rem;">Tool</th>
              <th style="padding: 0.35rem 0.5rem; text-align: right;">Calls</th>
              <th style="padding: 0.35rem 0.5rem; text-align: right;">OK</th>
              <th style="padding: 0.35rem 0.5rem; text-align: right;">Fail</th>
              <th style="padding: 0.35rem 0.5rem; text-align: right;">Gated</th>
              <th style="padding: 0.35rem 0.5rem; text-align: right;">Success%</th>
              <th style="padding: 0.35rem 0.5rem; text-align: right;">Avg ms</th>
            </tr>
          </thead>
          <tbody>
            <%= for tool <- @tool_report do %>
              <tr style="border-bottom: 1px solid var(--aw-border, #222);">
                <td style="padding: 0.35rem 0.5rem; font-family: monospace;">{tool.name}</td>
                <td style="padding: 0.35rem 0.5rem; text-align: right;">{tool.calls}</td>
                <td style="padding: 0.35rem 0.5rem; text-align: right; color: #4ade80;">
                  {tool.succeeded}
                </td>
                <td style="padding: 0.35rem 0.5rem; text-align: right; color: #f87171;">
                  {tool.failed}
                </td>
                <td style="padding: 0.35rem 0.5rem; text-align: right; color: #fbbf24;">
                  {tool.gated}
                </td>
                <td style="padding: 0.35rem 0.5rem; text-align: right;">{tool.success_rate}%</td>
                <td style="padding: 0.35rem 0.5rem; text-align: right;">{tool.avg_duration_ms}</td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>
    </div>
    """
  end

  @doc """
  Cost breakdown by provider.
  """
  attr :cost, :map, required: true

  def cost_chart(assigns) do
    ~H"""
    <div style="margin-bottom: 1.25rem;">
      <h3 style="font-size: 0.9rem; font-weight: 600; margin-bottom: 0.5rem;">Cost</h3>
      <div style="display: flex; gap: 2rem; font-size: 0.8rem; margin-bottom: 0.5rem;">
        <div>
          <span style="color: var(--aw-text-secondary, #71717a);">Session:</span>
          <strong>{@cost.session_formatted}</strong>
        </div>
        <div>
          <span style="color: var(--aw-text-secondary, #71717a);">Lifetime:</span>
          <strong>{@cost.lifetime_formatted}</strong>
        </div>
      </div>
      <%= if @cost.by_provider != [] do %>
        <div style="margin-top: 0.5rem;">
          <%= for provider_entry <- @cost.by_provider do %>
            <div style="display: flex; align-items: center; gap: 0.5rem; margin-bottom: 0.35rem;">
              <span style="font-size: 0.75rem; min-width: 80px; color: var(--aw-text-secondary, #71717a);">
                {provider_entry.provider}
              </span>
              <div style="flex: 1; height: 8px; background: var(--aw-bg-tertiary, #27272a); border-radius: 4px; overflow: hidden;">
                <div style={"height: 100%; background: #6366f1; border-radius: 4px; width: #{cost_bar_width(@cost, provider_entry.cost)}%;"}>
                </div>
              </div>
              <span style="font-size: 0.75rem; min-width: 60px; text-align: right;">
                {provider_entry.cost_formatted}
              </span>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Scrollable event timeline for historical telemetry events.
  """
  attr :history_events, :list, required: true

  def event_timeline(assigns) do
    ~H"""
    <div class="aw-card" style="margin-top: 1rem; padding: 1.25rem;">
      <h3 style="font-size: 0.9rem; font-weight: 600; margin-bottom: 0.75rem;">Event Timeline</h3>
      <%= if @history_events == [] do %>
        <div style="font-size: 0.8rem; color: var(--aw-text-secondary, #71717a);">
          No historical events found
        </div>
      <% else %>
        <div style="max-height: 300px; overflow-y: auto;">
          <table style="width: 100%; border-collapse: collapse; font-size: 0.8rem;">
            <thead>
              <tr style="border-bottom: 1px solid var(--aw-border, #333); text-align: left; position: sticky; top: 0; background: var(--aw-bg-secondary, #18181b);">
                <th style="padding: 0.35rem 0.5rem;">Time</th>
                <th style="padding: 0.35rem 0.5rem;">Type</th>
                <th style="padding: 0.35rem 0.5rem;">Description</th>
              </tr>
            </thead>
            <tbody>
              <%= for event <- @history_events do %>
                <tr style="border-bottom: 1px solid var(--aw-border, #222);">
                  <td style="padding: 0.35rem 0.5rem; white-space: nowrap; color: var(--aw-text-secondary, #71717a);">
                    {event.timestamp}
                  </td>
                  <td style="padding: 0.35rem 0.5rem;">
                    <span style={"padding: 0.1rem 0.4rem; border-radius: 3px; font-size: 0.7rem; #{event_type_style(event.event_type)}"}>
                      {event.event_type}
                    </span>
                  </td>
                  <td style="padding: 0.35rem 0.5rem;">{event.description}</td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Cost trend table showing cost per time period.
  """
  attr :history_cost_trend, :list, required: true

  def cost_over_time(assigns) do
    ~H"""
    <div class="aw-card" style="margin-top: 1rem; padding: 1.25rem;">
      <h3 style="font-size: 0.9rem; font-weight: 600; margin-bottom: 0.75rem;">Cost Trend</h3>
      <%= if @history_cost_trend == [] do %>
        <div style="font-size: 0.8rem; color: var(--aw-text-secondary, #71717a);">
          No cost data available
        </div>
      <% else %>
        <table style="width: 100%; border-collapse: collapse; font-size: 0.8rem;">
          <thead>
            <tr style="border-bottom: 1px solid var(--aw-border, #333); text-align: left;">
              <th style="padding: 0.35rem 0.5rem;">Period</th>
              <th style="padding: 0.35rem 0.5rem; text-align: right;">Turns</th>
              <th style="padding: 0.35rem 0.5rem; text-align: right;">Cost</th>
              <th style="padding: 0.35rem 0.5rem;">Bar</th>
            </tr>
          </thead>
          <tbody>
            <%= for entry <- @history_cost_trend do %>
              <tr style="border-bottom: 1px solid var(--aw-border, #222);">
                <td style="padding: 0.35rem 0.5rem; white-space: nowrap;">{entry.period}</td>
                <td style="padding: 0.35rem 0.5rem; text-align: right;">{entry.turn_count}</td>
                <td style="padding: 0.35rem 0.5rem; text-align: right;">{entry.cost_formatted}</td>
                <td style="padding: 0.35rem 0.5rem;">
                  <div style="height: 8px; background: var(--aw-bg-tertiary, #27272a); border-radius: 4px; overflow: hidden;">
                    <div style={"height: 100%; background: #6366f1; border-radius: 4px; width: #{cost_trend_bar_width(@history_cost_trend, entry.cost)}%;"}>
                    </div>
                  </div>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>
    </div>
    """
  end

  @doc """
  Tool failures list showing recent errors.
  """
  attr :history_tool_failures, :list, required: true

  def tool_failures(assigns) do
    ~H"""
    <div class="aw-card" style="margin-top: 1rem; padding: 1.25rem;">
      <h3 style="font-size: 0.9rem; font-weight: 600; margin-bottom: 0.75rem;">
        Recent Tool Failures
      </h3>
      <%= if @history_tool_failures == [] do %>
        <div style="font-size: 0.8rem; color: #4ade80;">No recent failures</div>
      <% else %>
        <div style="max-height: 200px; overflow-y: auto;">
          <%= for failure <- @history_tool_failures do %>
            <div style="padding: 0.35rem 0.5rem; border-bottom: 1px solid var(--aw-border, #222); font-size: 0.8rem;">
              <span style="color: var(--aw-text-secondary, #71717a);">{failure.timestamp}</span>
              <span style="color: #f87171; margin-left: 0.5rem;">{failure.description}</span>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp stat_card(assigns) do
    ~H"""
    <div class="aw-card" style="padding: 1rem; text-align: center;">
      <div style="font-size: 0.75rem; color: var(--aw-text-secondary, #71717a); margin-bottom: 0.25rem;">
        {@label}
      </div>
      <div style="font-size: 1.5rem; font-weight: 700;">
        {@value}
      </div>
    </div>
    """
  end

  defp rebuild_assigns(socket, state) do
    detail = TelemetryCore.show_agent_detail(state)

    socket
    |> Phoenix.Component.assign(:telemetry_state, state)
    |> Phoenix.Component.assign(:telemetry_overview, TelemetryCore.show_overview(state))
    |> Phoenix.Component.assign(:telemetry_agents, TelemetryCore.show_agent_table(state))
    |> Phoenix.Component.assign(:selected_agent_telemetry, detail)
    |> Phoenix.Component.assign(:sort_field, state.sort_field)
  end

  defp maybe_reselect(state, nil), do: state
  defp maybe_reselect(state, agent_id), do: TelemetryCore.select_agent(state, agent_id)

  defp fetch_all_telemetry do
    if Code.ensure_loaded?(Arbor.Common.AgentTelemetry.Store) do
      apply(Arbor.Common.AgentTelemetry.Store, :all, [])
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp fetch_history_events(agent_id) do
    store_mod = Arbor.Common.AgentTelemetry.Store

    if Code.ensure_loaded?(store_mod) and function_exported?(store_mod, :query_events, 2) do
      case apply(store_mod, :query_events, [agent_id, [limit: 200, order: :desc]]) do
        {:ok, events} -> events
        _ -> []
      end
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp truncate_id(id) when is_binary(id) do
    if String.length(id) > 24 do
      String.slice(id, 0, 21) <> "..."
    else
      id
    end
  end

  defp truncate_id(id), do: inspect(id)

  defp safe_sort_field("name"), do: :name
  defp safe_sort_field("cost"), do: :cost
  defp safe_sort_field("turns"), do: :turns
  defp safe_sort_field("latency"), do: :latency
  defp safe_sort_field(_), do: :cost

  defp sort_indicator, do: "v"

  defp cost_bar_width(%{lifetime: lifetime}, provider_cost) when lifetime > 0 do
    Float.round(provider_cost / lifetime * 100, 1)
  end

  defp cost_bar_width(_cost, _provider_cost), do: 0

  defp event_type_style("turn_completed"),
    do: "background: rgba(99,102,241,0.2); color: #818cf8;"

  defp event_type_style("tool_call"), do: "background: rgba(74,222,128,0.2); color: #4ade80;"

  defp event_type_style("routing_decision"),
    do: "background: rgba(251,191,36,0.2); color: #fbbf24;"

  defp event_type_style("compaction"), do: "background: rgba(248,113,113,0.2); color: #f87171;"
  defp event_type_style(_), do: "background: rgba(113,113,122,0.2); color: #71717a;"

  defp cost_trend_bar_width(trend, cost) do
    max_cost = Enum.reduce(trend, 0.0, fn e, acc -> max(acc, e.cost) end)

    if max_cost > 0 do
      Float.round(cost / max_cost * 100, 1)
    else
      0
    end
  end
end
