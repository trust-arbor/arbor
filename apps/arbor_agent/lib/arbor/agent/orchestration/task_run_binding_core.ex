defmodule Arbor.Agent.Orchestration.TaskRunBindingCore do
  @moduledoc """
  Pure classification of task-control recovery markers.

  Distinguishes v1/invalid orphans from v2 candidates. Executor probing,
  code loading, and process decisions belong in the TaskStore shell.
  """

  alias Arbor.Agent.Orchestration.TaskControlLease

  @rehydrate_domain "arbor.agent.coding_run_recovery.rehydrate.v1"

  @probe_keys MapSet.new(~w(
    schema_version
    task_id
    run_id
    agent_id
    execution_principal
    control_principal_id
    executor_kind
    graph_hash
    artifact_identity
    binding_digest
  ))

  @type classification :: :orphan | :v2_candidate
  @type cas_decision ::
          {:spawn, String.t()}
          | :idempotent
          | {:error, :recovery_cas_conflict | :stale_or_duplicate_terminal | :not_admitted}

  @type admission_action :: :spawn | :keep | :orphan | :unavailable

  @spec classify(term()) :: classification()
  def classify(marker) do
    case TaskControlLease.marker_normalize(marker) do
      {:ok, %{"schema_version" => 2}} -> :v2_candidate
      {:ok, %{"schema_version" => 1}} -> :orphan
      {:error, _} -> :orphan
    end
  end

  @spec rehydrate_cas(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def rehydrate_cas(marker, binding_digest)
      when is_binary(binding_digest) and byte_size(binding_digest) == 64 do
    case TaskControlLease.marker_normalize(marker) do
      {:ok, %{"schema_version" => 2} = normalized} ->
        {:ok,
         framed_digest([
           @rehydrate_domain,
           normalized["task_id"],
           normalized["run_id"],
           normalized["control_principal_id"],
           normalized["agent_id"],
           normalized["executor_kind"],
           String.downcase(binding_digest)
         ])}

      {:ok, _} ->
        {:error, :not_recoverable}

      {:error, _} = error ->
        error
    end
  end

  def rehydrate_cas(_marker, _binding_digest), do: {:error, :invalid_binding_digest}

  @spec closed_probe_projection?(term()) :: :ok | {:error, :invalid_probe}
  def closed_probe_projection?(projection)
      when is_map(projection) and not is_struct(projection) do
    keys = MapSet.new(Map.keys(projection))

    cond do
      not MapSet.equal?(keys, @probe_keys) ->
        {:error, :invalid_probe}

      projection["schema_version"] != 1 ->
        {:error, :invalid_probe}

      not is_binary(projection["task_id"]) or projection["task_id"] == "" ->
        {:error, :invalid_probe}

      projection["run_id"] != projection["task_id"] ->
        {:error, :invalid_probe}

      not is_binary(projection["agent_id"]) or projection["agent_id"] == "" ->
        {:error, :invalid_probe}

      projection["execution_principal"] != projection["agent_id"] ->
        {:error, :invalid_probe}

      not is_binary(projection["control_principal_id"]) or
          projection["control_principal_id"] == "" ->
        {:error, :invalid_probe}

      not is_binary(projection["executor_kind"]) or projection["executor_kind"] == "" ->
        {:error, :invalid_probe}

      not sha256_hex?(projection["graph_hash"]) ->
        {:error, :invalid_probe}

      not sha256_hex?(projection["artifact_identity"]) ->
        {:error, :invalid_probe}

      not sha256_hex?(projection["binding_digest"]) ->
        {:error, :invalid_probe}

      true ->
        :ok
    end
  end

  def closed_probe_projection?(_), do: {:error, :invalid_probe}

  @spec join_probe(term(), term()) :: {:ok, String.t()} | {:error, :orphan}
  def join_probe(marker, projection) do
    with {:ok, %{"schema_version" => 2} = normalized} <- TaskControlLease.marker_normalize(marker),
         :ok <- closed_probe_projection?(projection),
         true <- projection["task_id"] == normalized["task_id"],
         true <- projection["run_id"] == normalized["run_id"],
         true <- projection["run_id"] == projection["task_id"],
         true <- projection["agent_id"] == normalized["agent_id"],
         true <- projection["execution_principal"] == projection["agent_id"],
         true <- projection["control_principal_id"] == normalized["control_principal_id"],
         true <- projection["executor_kind"] == normalized["executor_kind"],
         {:ok, cas} <- rehydrate_cas(normalized, projection["binding_digest"]) do
      {:ok, cas}
    else
      _ -> {:error, :orphan}
    end
  end

  @spec admit_cas(nil | map(), String.t()) :: cas_decision()
  def admit_cas(existing, cas)
      when is_binary(cas) and byte_size(cas) == 64 do
    case existing do
      nil ->
        {:spawn, cas}

      %{state: :running, recovery_cas: ^cas} ->
        :idempotent

      %{state: :running} ->
        {:error, :recovery_cas_conflict}

      %{state: terminal, recovery_cas: ^cas}
      when terminal in [:done, :failed, :cancelled] ->
        :idempotent

      %{state: terminal} when terminal in [:done, :failed, :cancelled] ->
        {:error, :stale_or_duplicate_terminal}

      %{state: _} ->
        {:error, :not_admitted}

      _ ->
        {:error, :not_admitted}
    end
  end

  def admit_cas(_existing, _cas), do: {:error, :not_admitted}

  @doc """
  TaskStore shell action for one admit_cas/2 decision.

  Cleanup (orphan/reconcile) is only `:not_admitted`. Conflict and stale keep
  the live/terminal task without spawning. Unknown errors stay unavailable so
  the marker is preserved.
  """
  @spec admission_action(term()) :: admission_action()
  def admission_action(:idempotent), do: :keep
  def admission_action({:spawn, cas}) when is_binary(cas), do: :spawn
  def admission_action({:error, :recovery_cas_conflict}), do: :keep
  def admission_action({:error, :stale_or_duplicate_terminal}), do: :keep
  def admission_action({:error, :not_admitted}), do: :orphan
  def admission_action({:error, _}), do: :unavailable
  def admission_action(_), do: :unavailable

  @spec cleanup_descriptor(map()) :: map() | nil
  def cleanup_descriptor(%{"cleanup" => cleanup}) when is_map(cleanup) do
    %{}
    |> maybe_put(:caller_id, Map.get(cleanup, "caller_id"))
    |> maybe_put(:principal_id, Map.get(cleanup, "principal_id"))
    |> maybe_put(:trace_id, Map.get(cleanup, "trace_id"))
    |> case do
      empty when map_size(empty) == 0 -> nil
      closed -> closed
    end
  end

  def cleanup_descriptor(_), do: nil

  defp maybe_put(map, _key, value) when not is_binary(value) or value == "", do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp sha256_hex?(value) when is_binary(value), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp sha256_hex?(_), do: false

  defp framed_digest(parts) when is_list(parts) do
    iodata =
      Enum.map(parts, fn part ->
        bin = if is_binary(part), do: part, else: ""
        [<<byte_size(bin)::unsigned-32>>, bin]
      end)

    iodata
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
