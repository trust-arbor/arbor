defmodule Arbor.Dashboard.Live.SignalsLive do
  @moduledoc """
  Real-time signal stream dashboard.

  Displays published signals, subscription state, and bus health.
  Subscribes to the signal bus for live updates.
  """

  use Phoenix.LiveView

  import Arbor.Web.Components

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Signals")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_header title="Signals" subtitle="Real-time signal stream" />
    <.empty_state
      icon="\u{1F4E1}"
      title="Signal monitoring coming soon"
      hint="This dashboard will display live signal traffic, subscriptions, and bus health."
    />
    """
  end
end
