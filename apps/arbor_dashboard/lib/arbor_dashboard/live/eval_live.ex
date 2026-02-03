defmodule Arbor.Dashboard.Live.EvalLive do
  @moduledoc """
  Evaluation results dashboard.

  Displays LLM output evaluations, safety scores, and compliance metrics.
  """

  use Phoenix.LiveView

  import Arbor.Web.Components

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Eval")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_header title="Evaluation" subtitle="Output assessment results" />
    <.empty_state
      icon="\u{1F4CA}"
      title="Evaluation dashboard coming soon"
      hint="This dashboard will display evaluation results, safety scores, and compliance metrics."
    />
    """
  end
end
