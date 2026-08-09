defmodule Arbor.Agent.Orchestration.TaskControlRecoveryPersistence do
  @moduledoc false

  alias Arbor.Agent.Orchestration.TaskControlLease
  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Persistence

  @invalid_record :invalid_task_control_recovery_record

  @spec buffered_store_acknowledged_put(atom(), String.t(), TaskControlLease.marker()) ::
          {:ok, TaskControlLease.marker()} | {:error, atom()}
  def buffered_store_acknowledged_put(store_name, key, marker) do
    with {:ok, normalized} <- normalize_marker_for_key(key, marker),
         record <- Record.new(key, normalized, id: "task_control_recovery:#{key}"),
         {:ok, _stored} <-
           Persistence.buffered_store_acknowledged_put(store_name, key, record) do
      {:ok, normalized}
    end
  end

  @spec buffered_store_acknowledged_delete(atom(), String.t()) :: :ok | {:error, atom()}
  def buffered_store_acknowledged_delete(store_name, key) do
    with :ok <- validate_key(key) do
      Persistence.buffered_store_acknowledged_delete(store_name, key)
    end
  end

  @spec buffered_store_authoritative_get(atom(), String.t()) ::
          {:ok, TaskControlLease.marker()} | {:error, atom()}
  def buffered_store_authoritative_get(store_name, key) do
    with :ok <- validate_key(key) do
      case Persistence.buffered_store_authoritative_get(store_name, key) do
        {:ok, persisted} -> decode_record(key, persisted)
        {:error, :invalid_backend_record} -> {:error, @invalid_record}
        {:error, _reason} = error -> error
      end
    end
  end

  @spec buffered_store_authoritative_list(atom()) :: {:ok, [String.t()]} | {:error, atom()}
  def buffered_store_authoritative_list(store_name) do
    with :ok <- attest_authority(store_name),
         {:ok, keys} <- Persistence.buffered_store_authoritative_list(store_name),
         :ok <- validate_keys(keys) do
      {:ok, keys}
    end
  end

  @spec attest_authority(atom()) :: :ok | {:error, atom()}
  def attest_authority(store_name) do
    case Persistence.buffered_store_authority_mode(store_name) do
      {:ok, {:backend, :node_restart}} ->
        :ok

      {:ok, _insufficient} ->
        {:error, :task_control_recovery_authority_not_durable}

      {:error, _reason} ->
        {:error, :task_control_recovery_authority_unavailable}

      _other ->
        {:error, :task_control_recovery_authority_unavailable}
    end
  end

  defp decode_record(key, %Record{key: key, data: marker}) do
    normalize_marker_for_key(key, marker)
  end

  defp decode_record(_key, _persisted), do: {:error, @invalid_record}

  defp normalize_marker_for_key(key, marker) do
    with :ok <- validate_key(key),
         {:ok, normalized} <- TaskControlLease.marker_normalize(marker),
         true <- TaskControlLease.marker_key(normalized["task_id"]) == key do
      {:ok, normalized}
    else
      _ -> {:error, @invalid_record}
    end
  end

  defp validate_keys(keys) when is_list(keys) do
    if Enum.all?(keys, &(validate_key(&1) == :ok)) do
      :ok
    else
      {:error, @invalid_record}
    end
  end

  defp validate_keys(_keys), do: {:error, @invalid_record}

  defp validate_key(key) do
    if TaskControlLease.valid_task_id?(key), do: :ok, else: {:error, @invalid_record}
  end
end
