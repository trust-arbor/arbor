defmodule Arbor.Dashboard.Live.LandingLive do
  @moduledoc """
  Navigation shell and system overview dashboard.

  Shows links to sub-dashboards and basic system health information.
  """

  use Phoenix.LiveView

  import Arbor.Web.Components

  @impl true
  def mount(_params, _session, socket) do
    stats = safe_signal_stats()
    app_count = length(Application.started_applications())

    socket =
      assign(socket,
        page_title: "Home",
        stats: stats,
        app_count: app_count
      )

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_header title="Arbor Dashboard" subtitle="Agent orchestration control plane" />

    <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 1rem; margin-top: 1rem;">
      <.stat_card value={@stats.total_stored} label="Signals" color={:blue} />
      <.stat_card value={@stats.active_subscriptions} label="Subscriptions" color={:purple} />
      <.stat_card
        value={if @stats.healthy, do: "Healthy", else: "Degraded"}
        label="System health"
        color={if @stats.healthy, do: :green, else: :error}
      />
      <.stat_card value={@app_count} label="OTP apps" color={:gray} />
    </div>

    <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 1.5rem; margin-top: 1.5rem;">
      <.card title="Signals">
        <p style="margin-bottom: 1rem; color: var(--aw-text-muted, #888);">
          Real-time signal stream monitoring.
          View published signals, subscription state, and bus health.
        </p>
        <a href="/signals" class="aw-nav-link">Open Signals Dashboard &rarr;</a>
      </.card>

      <.card title="Evaluation">
        <p style="margin-bottom: 1rem; color: var(--aw-text-muted, #888);">
          Evaluation results and safety scores.
          Review LLM output assessments and compliance metrics.
        </p>
        <a href="/eval" class="aw-nav-link">Open Eval Dashboard &rarr;</a>
      </.card>

      <.card title="Trust & Security">
        <p style="margin-bottom: 1rem; color: var(--aw-text-muted, #888);">
          Agent trust tiers, capability grants, and security events.
        </p>
        <.badge label="Coming Soon" color={:gray} />
      </.card>

      <.card title="Consensus">
        <p style="margin-bottom: 1rem; color: var(--aw-text-muted, #888);">
          Multi-perspective deliberation and proposal outcomes.
        </p>
        <.badge label="Coming Soon" color={:gray} />
      </.card>
    </div>

    <div style="margin-top: 2rem;">
      <.card title="System Info">
        <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 1rem;">
          <.stat_card value={node() |> to_string()} label="Node" />
          <.stat_card value={System.otp_release()} label="OTP Release" />
          <.stat_card value={System.version()} label="Elixir" />
        </div>
      </.card>
    </div>
    """
  end

  defp safe_signal_stats do
    stats = Arbor.Signals.stats()

    %{
      total_stored: get_in(stats, [:store, :total_stored]) || 0,
      active_subscriptions: get_in(stats, [:bus, :active_subscriptions]) || 0,
      healthy: stats[:healthy] || false
    }
  rescue
    _ -> %{total_stored: 0, active_subscriptions: 0, healthy: false}
  catch
    :exit, _ -> %{total_stored: 0, active_subscriptions: 0, healthy: false}
  end
end
