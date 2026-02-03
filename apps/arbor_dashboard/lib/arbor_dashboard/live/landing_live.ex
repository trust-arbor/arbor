defmodule Arbor.Dashboard.Live.LandingLive do
  @moduledoc """
  Navigation shell and system overview dashboard.

  Shows links to sub-dashboards and basic system health information.
  """

  use Phoenix.LiveView

  import Arbor.Web.Components

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Home")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_header title="Arbor Dashboard" subtitle="Agent orchestration control plane" />

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
end
