defmodule Arbor.Actions.Monitor.CompleteAnomaly do
  @moduledoc """
  Complete processing of a claimed anomaly with an outcome.

  Uses runtime bridge pattern since arbor_monitor is standalone.

  ## Parameters

  | Name | Type | Required | Description |
  |------|------|----------|-------------|
  | `lease_token` | string | yes | Lease token from claim_anomaly |
  | `outcome` | string | yes | One of: "fixed", "escalated", "resolved", "failed" |
  | `reason` | string | no | Reason for the outcome (used with retry/ineffective) |

  ## Returns

  Map with `:completed` boolean and `:outcome`.
  """

  use Jido.Action,
    name: "monitor_complete_anomaly",
    description: "Complete processing of a claimed anomaly with an outcome",
    category: "monitor",
    tags: ["monitor", "healing", "anomaly"],
    schema: [
      lease_token: [
        type: :string,
        required: true,
        doc: "Lease token from claim_anomaly"
      ],
      outcome: [
        type: {:in, ["fixed", "escalated", "resolved", "failed", "ineffective"]},
        required: true,
        doc: "Outcome: fixed, escalated, resolved, failed, ineffective"
      ],
      reason: [
        type: :string,
        doc: "Reason for the outcome"
      ]
    ]

  @queue_mod Arbor.Monitor.AnomalyQueue

  @outcome_map %{
    "fixed" => :fixed,
    "escalated" => :escalated,
    "resolved" => :resolved,
    "failed" => :failed,
    "ineffective" => :ineffective
  }

  def taint_roles do
    %{lease_token: :control, outcome: :control, reason: :data}
  end

  @impl true
  def run(%{lease_token: lease_token, outcome: outcome} = params, _context) do
    if queue_available?() do
      outcome_atom = Map.fetch!(@outcome_map, outcome)

      outcome_value =
        case {outcome_atom, params[:reason]} do
          {:failed, reason} when is_binary(reason) -> {:retry, reason}
          {:ineffective, reason} when is_binary(reason) -> {:ineffective, reason}
          {atom, _} -> atom
        end

      case apply(@queue_mod, :complete, [lease_token, outcome_value]) do
        :ok ->
          {:ok, %{completed: true, outcome: outcome}}

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
