defmodule Arbor.Memory.AsyncWriter do
  @moduledoc false

  alias Arbor.Memory.AsyncWriter.Operation
  alias Arbor.Memory.AsyncWriter.Supervisor, as: WriterSupervisor
  alias Arbor.Memory.AsyncWriter.Worker
  alias Arbor.Memory.MutationAdmission

  @type error ::
          {:error,
           {:memory_store, :async_writer,
            :draining
            | :destroyed
            | :unavailable
            | :capacity_exceeded
            | :invalid_operation
            | :start_failed}}

  @spec start(Operation.t()) :: :ok | error()
  def start(operation) do
    with :ok <- Operation.validate(operation),
         :ok <- ensure_supervisor(),
         :ok <- reject_if_closed(Operation.agent_id(operation)) do
      start_worker(operation)
    end
  end

  defp ensure_supervisor do
    if Process.whereis(WriterSupervisor.name()) do
      :ok
    else
      {:error, {:memory_store, :async_writer, :unavailable}}
    end
  end

  defp reject_if_closed(agent_id) do
    case MutationAdmission.status(agent_id) do
      {:ok, %{gate: gate}} when gate in [:draining, :destroyed] ->
        {:error, {:memory_store, :async_writer, gate}}

      {:ok, %{gate: _gate}} ->
        :ok

      {:error, :unavailable} ->
        {:error, {:memory_store, :async_writer, :unavailable}}

      {:error, :disabled} ->
        {:error, {:memory_store, :async_writer, :unavailable}}

      {:error, :busy} ->
        {:error, {:memory_store, :async_writer, :unavailable}}

      {:error, :indeterminate} ->
        {:error, {:memory_store, :async_writer, :unavailable}}

      {:error, :invalid_request} ->
        {:error, {:memory_store, :async_writer, :unavailable}}

      {:error, _reason} ->
        {:error, {:memory_store, :async_writer, :unavailable}}
    end
  end

  defp start_worker(operation) do
    spec = Worker.child_spec(operation)

    case DynamicSupervisor.start_child(WriterSupervisor.name(), spec) do
      {:ok, _pid} ->
        :ok

      {:ok, _pid, _info} ->
        :ok

      {:error, :max_children} ->
        {:error, {:memory_store, :async_writer, :capacity_exceeded}}

      {:error, {:admission, reason}} ->
        {:error, {:memory_store, :async_writer, map_admission(reason)}}

      {:error, {:shutdown, {:admission, reason}}} ->
        {:error, {:memory_store, :async_writer, map_admission(reason)}}

      {:error, {{:admission, reason}, _stack}} ->
        {:error, {:memory_store, :async_writer, map_admission(reason)}}

      {:error, _reason} ->
        {:error, {:memory_store, :async_writer, :start_failed}}
    end
  end

  defp map_admission(:draining), do: :draining
  defp map_admission(:destroyed), do: :destroyed
  defp map_admission(:capacity_exceeded), do: :capacity_exceeded
  defp map_admission(_reason), do: :unavailable
end
