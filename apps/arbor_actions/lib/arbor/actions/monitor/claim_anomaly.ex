defmodule Arbor.Actions.Monitor.ClaimAnomaly do
  @moduledoc """
  Claim the next pending anomaly from the healing queue.

  Uses runtime bridge pattern since arbor_monitor is standalone.

  ## Parameters

  | Name | Type | Required | Description |
  |------|------|----------|-------------|
  | `agent_id` | string | yes | ID of the agent claiming the anomaly |

  ## Returns

  Map with `:lease` (lease token map) and `:anomaly` (anomaly details),
  or `{:error, :empty}` if no anomalies are pending.
  """

  use Jido.Action,
    name: "monitor_claim_anomaly",
    description: "Claim the next pending anomaly from the healing queue",
    category: "monitor",
    tags: ["monitor", "healing", "anomaly"],
    schema: [
      agent_id: [
        type: :string,
        required: true,
        doc: "ID of the agent claiming the anomaly"
      ]
    ]

  @queue_mod Arbor.Monitor.AnomalyQueue

  def taint_roles do
    %{agent_id: :control}
  end

  @impl true
  def run(%{agent_id: agent_id}, _context) do
    if queue_available?() do
      case apply(@queue_mod, :claim_next, [agent_id]) do
        {:ok, {lease, anomaly}} ->
          {:ok, %{lease: lease, anomaly: format_anomaly(anomaly)}}

        {:error, :empty} ->
          {:ok, %{status: :empty, message: "No pending anomalies"}}

        {:error, :settling} ->
          {:ok, %{status: :settling, message: "Queue is in settling period"}}

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

  defp format_anomaly(anomaly) when is_map(anomaly) do
    Map.take(anomaly, [
      :id,
      :skill,
      :severity,
      :details,
      :timestamp,
      :fingerprint,
      :attempt_count
    ])
  end

  defp format_anomaly(anomaly), do: anomaly
end
