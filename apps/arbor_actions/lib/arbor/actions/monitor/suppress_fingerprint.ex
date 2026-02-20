defmodule Arbor.Actions.Monitor.SuppressFingerprint do
  @moduledoc """
  Suppress a known anomaly fingerprint to reduce noise.

  Useful for known-noisy metrics (EWMA noise < 4σ) where the anomaly
  is expected and doesn't require investigation.

  Uses runtime bridge pattern since arbor_monitor is standalone.

  ## Parameters

  | Name | Type | Required | Description |
  |------|------|----------|-------------|
  | `skill` | string | yes | Monitor skill name (e.g., "beam", "processes") |
  | `metric` | string | yes | Metric key to suppress |
  | `reason` | string | yes | Why this fingerprint is being suppressed |
  | `duration_minutes` | integer | no | Suppression duration in minutes (default: 30) |
  """

  use Jido.Action,
    name: "monitor_suppress_fingerprint",
    description: "Suppress a known anomaly fingerprint to reduce noise",
    category: "monitor",
    tags: ["monitor", "healing", "suppress"],
    schema: [
      skill: [
        type: :string,
        required: true,
        doc: "Monitor skill name (e.g., beam, processes)"
      ],
      metric: [
        type: :string,
        required: true,
        doc: "Metric key to suppress"
      ],
      reason: [
        type: :string,
        required: true,
        doc: "Why this fingerprint is being suppressed"
      ],
      duration_minutes: [
        type: :non_neg_integer,
        default: 30,
        doc: "Suppression duration in minutes"
      ]
    ]

  @queue_mod Arbor.Monitor.AnomalyQueue

  def taint_roles do
    %{skill: :data, metric: :data, reason: :data, duration_minutes: :data}
  end

  @impl true
  def run(%{skill: skill, metric: metric, reason: reason} = params, _context) do
    if queue_available?() do
      duration = params[:duration_minutes] || 30
      fingerprint = "#{skill}:#{metric}"

      case apply(@queue_mod, :suppress, [fingerprint, reason, duration]) do
        :ok ->
          {:ok, %{suppressed: true, fingerprint: fingerprint, duration_minutes: duration}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :anomaly_queue_unavailable}
    end
  end

  defp queue_available? do
    Code.ensure_loaded?(@queue_mod) and
      Process.whereis(@queue_mod) != nil
  end
end
