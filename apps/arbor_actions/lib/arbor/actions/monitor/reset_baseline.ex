defmodule Arbor.Actions.Monitor.ResetBaseline do
  @moduledoc """
  Reset the EWMA baseline for a specific metric.

  Useful when a metric has drifted significantly (≥ 4σ) due to a
  legitimate workload change, not an anomaly.

  Uses runtime bridge pattern since arbor_monitor is standalone.

  ## Parameters

  | Name | Type | Required | Description |
  |------|------|----------|-------------|
  | `skill` | string | yes | Monitor skill name (e.g., "beam", "processes") |
  | `metric` | string | yes | Metric key to reset |
  """

  alias Arbor.Common.SafeAtom

  use Jido.Action,
    name: "monitor_reset_baseline",
    description: "Reset the EWMA baseline for a specific metric",
    category: "monitor",
    tags: ["monitor", "healing", "baseline"],
    schema: [
      skill: [
        type: :string,
        required: true,
        doc: "Monitor skill name (e.g., beam, processes)"
      ],
      metric: [
        type: :string,
        required: true,
        doc: "Metric key to reset"
      ]
    ]

  @detector_mod Arbor.Monitor.AnomalyDetector
  @known_skills [:beam, :memory, :ets, :processes, :supervisor, :system]

  def taint_roles do
    %{skill: :data, metric: :data}
  end

  @impl true
  def run(%{skill: skill, metric: metric}, _context) do
    if detector_available?() do
      case SafeAtom.to_allowed(skill, @known_skills) do
        {:ok, skill_atom} ->
          metric_atom = String.to_existing_atom(metric)
          apply(@detector_mod, :reset, [skill_atom, metric_atom])
          {:ok, %{reset: true, skill: skill, metric: metric}}

        {:error, _} ->
          {:error, {:unknown_skill, skill}}
      end
    else
      {:error, :anomaly_detector_unavailable}
    end
  rescue
    ArgumentError ->
      {:error, {:unknown_metric, metric}}
  end

  defp detector_available? do
    Code.ensure_loaded?(@detector_mod)
  end
end
