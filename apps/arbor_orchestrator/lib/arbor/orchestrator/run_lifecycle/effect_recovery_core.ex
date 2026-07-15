defmodule Arbor.Orchestrator.RunLifecycle.EffectRecoveryCore do
  @moduledoc """
  Pure CRC-style recovery decisions for canonical `Record.current_effect`.

  Classifies the validated effect envelope against durable record progress and
  an already-authenticated Engine checkpoint view. Returns data-only effects
  for the Engine shell to interpret — no IO, no journal calls, no process
  state, no wall clock.

  Canonical effect safety is **not** bypassable by `force_replay` or DOT
  `on_resume="retry"` (those apply only to legacy checkpoint pending_intents).
  """

  alias Arbor.Orchestrator.Engine.EffectOwner
  alias Arbor.Orchestrator.Engine.Outcome
  alias Arbor.Orchestrator.RunLifecycle.EffectEnvelope
  alias Arbor.Orchestrator.RunLifecycle.Record

  @type checkpoint_view :: %{
          optional(:completed_nodes) => [String.t()],
          optional(:outcomes) => %{optional(String.t()) => Outcome.t()},
          optional(:node_outcomes) => %{optional(String.t()) => Outcome.t()}
        }

  @type reconcile_action ::
          {:sync_progress, [String.t()]}
          | {:settle, pos_integer(), String.t()}

  @type decision ::
          {:ok, :continue}
          | {:ok, :reconcile, [reconcile_action()]}
          | {:error, error_reason()}

  @type error_reason ::
          {:indeterminate_effect, String.t(), String.t()}
          | {:completed_effect_unapplied, String.t(), String.t()}
          | {:effect_recovery_inconsistent, atom()}
          | {:invalid_current_effect, term()}

  @doc """
  Decide how to recover from `record.current_effect` given checkpoint progress.

  `checkpoint` must already be authenticated by the Engine. Accepts either a
  `%Checkpoint{}`-shaped map or the Engine resume state fields
  (`completed_nodes` + `outcomes`).
  """
  @spec decide(Record.t() | map() | nil, checkpoint_view() | map() | nil) :: decision()
  def decide(record, checkpoint)

  def decide(nil, _checkpoint), do: {:error, {:effect_recovery_inconsistent, :record_missing}}

  def decide(%Record{} = record, checkpoint) do
    decide_effect(
      record.current_effect,
      record.completed_nodes || [],
      checkpoint_view(checkpoint)
    )
  end

  def decide(%{current_effect: effect, completed_nodes: nodes}, checkpoint)
      when is_list(nodes) or is_nil(nodes) do
    decide_effect(effect, nodes || [], checkpoint_view(checkpoint))
  end

  def decide(%{"current_effect" => effect, "completed_nodes" => nodes}, checkpoint)
      when is_list(nodes) or is_nil(nodes) do
    decide_effect(effect, nodes || [], checkpoint_view(checkpoint))
  end

  def decide(_record, _checkpoint),
    do: {:error, {:effect_recovery_inconsistent, :invalid_record}}

  defp decide_effect(nil, _record_nodes, _checkpoint), do: {:ok, :continue}

  defp decide_effect(effect, record_nodes, checkpoint) when is_map(effect) do
    case EffectEnvelope.validate(effect) do
      {:ok, validated} ->
        classify(validated, record_nodes, checkpoint)

      {:error, reason} ->
        {:error, {:invalid_current_effect, reason}}
    end
  end

  defp decide_effect(_effect, _record_nodes, _checkpoint),
    do: {:error, {:invalid_current_effect, :invalid_type}}

  defp classify(%{"status" => "pending"} = effect, _record_nodes, _checkpoint) do
    {:error, {:indeterminate_effect, effect["node_id"], effect["execution_id"]}}
  end

  defp classify(%{"status" => "completed"} = effect, record_nodes, checkpoint) do
    node_id = effect["node_id"]
    execution_id = effect["execution_id"]
    generation = effect["generation"]
    in_record? = node_completed?(record_nodes, node_id)
    in_checkpoint? = node_completed?(checkpoint.completed_nodes, node_id)

    case exact_checkpoint_completion(effect, checkpoint, in_checkpoint?) do
      {:ok, :match} ->
        cond do
          # Matching receipt but durable progress disagrees with checkpoint identity.
          in_record? and not in_checkpoint? ->
            {:error, {:effect_recovery_inconsistent, :progress_disagree}}

          not in_record? ->
            # Checkpoint is ahead of durable journal progress — sync then settle.
            {:ok, :reconcile,
             [
               {:sync_progress, checkpoint.completed_nodes},
               {:settle, generation, execution_id}
             ]}

          true ->
            {:ok, :reconcile, [{:settle, generation, execution_id}]}
        end

      {:error, :missing_outcome} ->
        # Handler may have completed (receipt) but checkpoint never applied the node.
        if in_record? and not in_checkpoint? do
          {:error, {:effect_recovery_inconsistent, :progress_disagree}}
        else
          {:error, {:completed_effect_unapplied, node_id, execution_id}}
        end

      {:error, :status_mismatch} ->
        {:error, {:effect_recovery_inconsistent, :outcome_status_mismatch}}

      {:error, :digest_mismatch} ->
        {:error, {:effect_recovery_inconsistent, :result_digest_mismatch}}

      {:error, reason} when is_atom(reason) ->
        {:error, {:effect_recovery_inconsistent, reason}}
    end
  end

  defp classify(%{"status" => "settled"} = effect, record_nodes, checkpoint) do
    node_id = effect["node_id"]
    in_record? = node_completed?(record_nodes, node_id)
    in_checkpoint? = node_completed?(checkpoint.completed_nodes, node_id)

    cond do
      not in_record? or not in_checkpoint? ->
        {:error, {:effect_recovery_inconsistent, :settled_progress_missing}}

      true ->
        case exact_checkpoint_completion(effect, checkpoint, true) do
          {:ok, :match} ->
            {:ok, :continue}

          {:error, :missing_outcome} ->
            {:error, {:effect_recovery_inconsistent, :settled_outcome_missing}}

          {:error, :status_mismatch} ->
            {:error, {:effect_recovery_inconsistent, :outcome_status_mismatch}}

          {:error, :digest_mismatch} ->
            {:error, {:effect_recovery_inconsistent, :result_digest_mismatch}}

          {:error, reason} when is_atom(reason) ->
            {:error, {:effect_recovery_inconsistent, reason}}
        end
    end
  end

  defp classify(_effect, _record_nodes, _checkpoint),
    do: {:error, {:invalid_current_effect, :invalid_status}}

  # Exact reconciliation requires the effect node in checkpoint completed_nodes
  # and an Outcome whose status + result digest match the retained receipt.
  defp exact_checkpoint_completion(effect, checkpoint, in_checkpoint?) do
    if not in_checkpoint? do
      {:error, :missing_outcome}
    else
      exact_outcome_match(effect, checkpoint)
    end
  end

  defp exact_outcome_match(effect, checkpoint) do
    node_id = effect["node_id"]

    case Map.fetch(checkpoint.outcomes, node_id) do
      :error ->
        {:error, :missing_outcome}

      {:ok, %Outcome{} = outcome} ->
        expected_status = effect["outcome_status"]
        actual_status = outcome_status_string(outcome.status)

        cond do
          not is_binary(expected_status) ->
            {:error, :invalid_effect_outcome_status}

          actual_status != expected_status ->
            {:error, :status_mismatch}

          EffectOwner.outcome_result_digest(outcome) != effect["result_digest"] ->
            {:error, :digest_mismatch}

          true ->
            {:ok, :match}
        end

      {:ok, _} ->
        {:error, :invalid_checkpoint_outcome}
    end
  end

  defp outcome_status_string(status) when is_atom(status), do: Atom.to_string(status)
  defp outcome_status_string(status) when is_binary(status), do: status
  defp outcome_status_string(_), do: nil

  defp node_completed?(nodes, node_id) when is_list(nodes) and is_binary(node_id) do
    node_id in nodes
  end

  defp node_completed?(_, _), do: false

  defp checkpoint_view(nil), do: %{completed_nodes: [], outcomes: %{}}

  defp checkpoint_view(%{completed_nodes: nodes, outcomes: outcomes})
       when is_list(nodes) and is_map(outcomes) do
    %{completed_nodes: nodes, outcomes: outcomes}
  end

  defp checkpoint_view(%{completed_nodes: nodes, node_outcomes: outcomes})
       when is_list(nodes) and is_map(outcomes) do
    %{completed_nodes: nodes, outcomes: outcomes}
  end

  defp checkpoint_view(checkpoint) when is_map(checkpoint) do
    nodes =
      Map.get(checkpoint, :completed_nodes) ||
        Map.get(checkpoint, "completed_nodes") ||
        []

    outcomes =
      Map.get(checkpoint, :outcomes) ||
        Map.get(checkpoint, :node_outcomes) ||
        Map.get(checkpoint, "node_outcomes") ||
        %{}

    %{
      completed_nodes: if(is_list(nodes), do: nodes, else: []),
      outcomes: if(is_map(outcomes), do: outcomes, else: %{})
    }
  end

  defp checkpoint_view(_), do: %{completed_nodes: [], outcomes: %{}}
end
