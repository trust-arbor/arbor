defmodule Arbor.Orchestrator.RunLifecycle.EffectRecoveryCore do
  @moduledoc """
  Pure CRC-style recovery decisions for canonical `Record.current_effect`.

  Classifies the validated effect envelope against durable record progress and
  an already-authenticated Engine checkpoint view. Returns data-only effects
  for the Engine shell to interpret — no IO, no journal calls, no process
  state, no wall clock.

  Recovery proof for a completed/settled effect is bound to the **current
  effect visit**, not `node_id` alone (DOT nodes can repeat). The checkpoint's
  per-node `execution_digests` marker is the visit identity: `execution_id`,
  `input_hash`, `outcome_status`, and timestamp. Settlement also requires the
  checkpoint `Outcome` result digest to match the journal receipt.

  Canonical effect safety is **not** bypassable by `force_replay` or DOT
  `on_resume="retry"` (those apply only to legacy checkpoint pending_intents).
  """

  alias Arbor.Orchestrator.Engine.EffectOwner
  alias Arbor.Orchestrator.Engine.Outcome
  alias Arbor.Orchestrator.RunLifecycle.EffectEnvelope
  alias Arbor.Orchestrator.RunLifecycle.Record

  @type execution_marker :: map()

  @type checkpoint_view :: %{
          optional(:completed_nodes) => [String.t()],
          optional(:outcomes) => %{optional(String.t()) => Outcome.t()},
          optional(:node_outcomes) => %{optional(String.t()) => Outcome.t()},
          optional(:execution_digests) => %{optional(String.t()) => execution_marker()}
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
  (`completed_nodes` + `outcomes` + `execution_digests`).
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

  # Pending is always indeterminate — never settle, never replay.
  defp classify(%{"status" => "pending"} = effect, _record_nodes, _checkpoint) do
    {:error, {:indeterminate_effect, effect["node_id"], effect["execution_id"]}}
  end

  defp classify(%{"status" => "completed"} = effect, record_nodes, checkpoint) do
    node_id = effect["node_id"]
    execution_id = effect["execution_id"]
    generation = effect["generation"]

    case match_current_execution_marker(effect, checkpoint) do
      {:error, :missing_or_stale_marker} ->
        # Absent marker or a different visit's marker — completed but checkpoint
        # never applied *this* execution. Halt without replay.
        {:error, {:completed_effect_unapplied, node_id, execution_id}}

      {:error, reason} when is_atom(reason) ->
        # Same execution_id present but fields disagree / are malformed.
        {:error, {:effect_recovery_inconsistent, reason}}

      {:ok, :marker_match} ->
        case exact_outcome_match(effect, checkpoint) do
          {:ok, :match} ->
            case completed_effect_progress_coherence(node_id, checkpoint.completed_nodes) do
              :ok ->
                case ordered_progress_relation(record_nodes, checkpoint.completed_nodes) do
                  :equal ->
                    {:ok, :reconcile, [{:settle, generation, execution_id}]}

                  :record_prefix ->
                    {:ok, :reconcile,
                     [
                       {:sync_progress, checkpoint.completed_nodes},
                       {:settle, generation, execution_id}
                     ]}

                  :inconsistent ->
                    {:error, {:effect_recovery_inconsistent, :ordered_progress_inconsistent}}
                end

              {:error, reason} ->
                {:error, {:effect_recovery_inconsistent, reason}}
            end

          {:error, :missing_outcome} ->
            {:error, {:effect_recovery_inconsistent, :outcome_missing}}

          {:error, :status_mismatch} ->
            {:error, {:effect_recovery_inconsistent, :outcome_status_mismatch}}

          {:error, :digest_mismatch} ->
            {:error, {:effect_recovery_inconsistent, :result_digest_mismatch}}

          {:error, reason} when is_atom(reason) ->
            {:error, {:effect_recovery_inconsistent, reason}}
        end
    end
  end

  defp classify(%{"status" => "settled"} = effect, record_nodes, checkpoint) do
    # Settled proves its own node was durably settled. Exact marker + outcome
    # evidence is required; ordered progress may be equal or a strict prefix
    # of an authenticated checkpoint that advanced past non-journaled nodes
    # while best-effort journal progress lagged. Never re-settle.
    case match_current_execution_marker(effect, checkpoint) do
      {:ok, :marker_match} ->
        case exact_outcome_match(effect, checkpoint) do
          {:ok, :match} ->
            case settled_effect_progress_coherence(
                   effect["node_id"],
                   checkpoint.completed_nodes
                 ) do
              :ok ->
                case ordered_progress_relation(record_nodes, checkpoint.completed_nodes) do
                  :equal ->
                    {:ok, :continue}

                  :record_prefix ->
                    # Checkpoint-ahead after settle is recoverable: sync journal
                    # progress from authenticated checkpoint and continue.
                    {:ok, :reconcile, [{:sync_progress, checkpoint.completed_nodes}]}

                  :inconsistent ->
                    {:error, {:effect_recovery_inconsistent, :ordered_progress_inconsistent}}
                end

              {:error, reason} ->
                {:error, {:effect_recovery_inconsistent, reason}}
            end

          {:error, :missing_outcome} ->
            {:error, {:effect_recovery_inconsistent, :settled_outcome_missing}}

          {:error, :status_mismatch} ->
            {:error, {:effect_recovery_inconsistent, :outcome_status_mismatch}}

          {:error, :digest_mismatch} ->
            {:error, {:effect_recovery_inconsistent, :result_digest_mismatch}}

          {:error, reason} when is_atom(reason) ->
            {:error, {:effect_recovery_inconsistent, reason}}
        end

      {:error, :missing_or_stale_marker} ->
        {:error, {:effect_recovery_inconsistent, :settled_marker_missing}}

      {:error, reason} when is_atom(reason) ->
        {:error, {:effect_recovery_inconsistent, reason}}
    end
  end

  defp classify(_effect, _record_nodes, _checkpoint),
    do: {:error, {:invalid_current_effect, :invalid_status}}

  # ---------------------------------------------------------------------------
  # Execution visit marker (Checkpoint.execution_digests)
  # ---------------------------------------------------------------------------

  # Returns:
  # - {:ok, :marker_match} — marker.execution_id == effect.execution_id and fields agree
  # - {:error, :missing_or_stale_marker} — absent or different execution_id
  # - {:error, atom} — same execution_id with malformed / mismatching fields
  defp match_current_execution_marker(effect, checkpoint) do
    node_id = effect["node_id"]
    execution_id = effect["execution_id"]
    digests = checkpoint.execution_digests || %{}

    case Map.fetch(digests, node_id) do
      :error ->
        {:error, :missing_or_stale_marker}

      {:ok, marker} when is_map(marker) ->
        marker_exec = marker_get(marker, :execution_id)

        cond do
          not is_binary(marker_exec) ->
            {:error, :missing_or_stale_marker}

          marker_exec != execution_id ->
            # Stale visit evidence for a different execution of the same node.
            {:error, :missing_or_stale_marker}

          true ->
            validate_marker_fields(effect, marker)
        end

      {:ok, _} ->
        {:error, :invalid_execution_marker}
    end
  end

  defp validate_marker_fields(effect, marker) do
    marker_hash = marker_get(marker, :input_hash)
    marker_status = marker_get(marker, :outcome_status)
    marker_completed_at = marker_get(marker, :completed_at)
    expected_hash = effect["input_hash"]
    expected_status = effect["outcome_status"]
    expected_completed_at = effect["completed_at"]

    cond do
      not is_binary(marker_hash) or marker_hash == "" ->
        {:error, :invalid_execution_marker}

      not is_binary(expected_hash) ->
        {:error, :invalid_effect_input_hash}

      marker_hash != expected_hash ->
        {:error, :input_hash_mismatch}

      not is_binary(expected_status) ->
        {:error, :invalid_effect_outcome_status}

      normalize_status_string(marker_status) != expected_status ->
        {:error, :outcome_status_mismatch}

      not is_binary(marker_completed_at) or marker_completed_at == "" ->
        {:error, :invalid_execution_marker}

      not is_binary(expected_completed_at) or expected_completed_at == "" ->
        {:error, :invalid_effect_completed_at}

      marker_completed_at != expected_completed_at ->
        {:error, :completed_at_mismatch}

      true ->
        {:ok, :marker_match}
    end
  end

  defp marker_get(marker, key) when is_atom(key) do
    Map.get(marker, key) || Map.get(marker, Atom.to_string(key))
  end

  # Completed effects cannot advance past settle: the effect node must be the
  # last chronological completed node (duplicates allowed earlier in the list).
  defp completed_effect_progress_coherence(node_id, completed_nodes)
       when is_binary(node_id) and is_list(completed_nodes) do
    case List.last(completed_nodes) do
      ^node_id -> :ok
      _ -> {:error, :effect_progress_incoherent}
    end
  end

  defp completed_effect_progress_coherence(_node_id, _completed_nodes),
    do: {:error, :effect_progress_incoherent}

  # Settled effects require the effect node somewhere in checkpoint progress
  # (may not be last — later non-journaled nodes can advance the checkpoint).
  defp settled_effect_progress_coherence(node_id, completed_nodes)
       when is_binary(node_id) and is_list(completed_nodes) do
    if node_id in completed_nodes do
      :ok
    else
      {:error, :effect_progress_incoherent}
    end
  end

  defp settled_effect_progress_coherence(_node_id, _completed_nodes),
    do: {:error, :effect_progress_incoherent}

  # Exact reconciliation requires an Outcome whose status + result digest match
  # the retained receipt for this node.
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

  # Ordered list comparison including duplicates.
  # :equal — consistent
  # :record_prefix — durable record is a strict prefix of checkpoint (may sync)
  # :inconsistent — checkpoint-behind or divergent (never overwrite durable progress)
  defp ordered_progress_relation(record_nodes, checkpoint_nodes)
       when is_list(record_nodes) and is_list(checkpoint_nodes) do
    cond do
      record_nodes == checkpoint_nodes ->
        :equal

      list_strict_prefix?(record_nodes, checkpoint_nodes) ->
        :record_prefix

      true ->
        :inconsistent
    end
  end

  defp ordered_progress_relation(_, _), do: :inconsistent

  defp list_strict_prefix?(prefix, list)
       when is_list(prefix) and is_list(list) and length(prefix) < length(list) do
    Enum.take(list, length(prefix)) == prefix
  end

  defp list_strict_prefix?(_, _), do: false

  defp outcome_status_string(status) when is_atom(status), do: Atom.to_string(status)
  defp outcome_status_string(status) when is_binary(status), do: status
  defp outcome_status_string(_), do: nil

  defp normalize_status_string(status) when is_atom(status), do: Atom.to_string(status)
  defp normalize_status_string(status) when is_binary(status), do: status
  defp normalize_status_string(_), do: nil

  defp checkpoint_view(nil),
    do: %{completed_nodes: [], outcomes: %{}, execution_digests: %{}}

  defp checkpoint_view(%{completed_nodes: nodes, outcomes: outcomes} = checkpoint)
       when is_list(nodes) and is_map(outcomes) do
    %{
      completed_nodes: nodes,
      outcomes: outcomes,
      execution_digests: normalize_digests(Map.get(checkpoint, :execution_digests, %{}))
    }
  end

  defp checkpoint_view(%{completed_nodes: nodes, node_outcomes: outcomes} = checkpoint)
       when is_list(nodes) and is_map(outcomes) do
    %{
      completed_nodes: nodes,
      outcomes: outcomes,
      execution_digests: normalize_digests(Map.get(checkpoint, :execution_digests, %{}))
    }
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

    digests =
      Map.get(checkpoint, :execution_digests) ||
        Map.get(checkpoint, "execution_digests") ||
        %{}

    %{
      completed_nodes: if(is_list(nodes), do: nodes, else: []),
      outcomes: if(is_map(outcomes), do: outcomes, else: %{}),
      execution_digests: normalize_digests(digests)
    }
  end

  defp checkpoint_view(_),
    do: %{completed_nodes: [], outcomes: %{}, execution_digests: %{}}

  defp normalize_digests(digests) when is_map(digests), do: digests
  defp normalize_digests(_), do: %{}
end
