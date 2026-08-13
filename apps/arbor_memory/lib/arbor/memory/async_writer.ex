defmodule Arbor.Memory.AsyncWriter do
  @moduledoc false

  alias Arbor.Memory.AsyncWriter.Operation
  alias Arbor.Memory.AsyncWriter.Reservation
  alias Arbor.Memory.AsyncWriter.Supervisor, as: WriterSupervisor
  alias Arbor.Memory.AsyncWriter.Worker
  alias Arbor.Memory.MutationAdmission

  @activate_call_timeout_ms 1_000

  @type error ::
          {:error,
           {:memory_store, :async_writer,
            :draining
            | :destroyed
            | :unavailable
            | :capacity_exceeded
            | :invalid_operation
            | :start_failed
            | :invalid_reservation
            | :expired}}

  @spec start(Operation.t()) :: :ok | error()
  def start(operation) do
    with {:ok, reservation} <- reserve(operation) do
      activate(reservation)
    end
  end

  @spec reserve(Operation.t()) :: {:ok, Reservation.t()} | error()
  def reserve(operation) do
    owner = self()

    with :ok <- Operation.validate(operation),
         :ok <- ensure_supervisor(),
         :ok <- reject_if_closed(Operation.agent_id(operation)) do
      start_reserved_worker(operation, owner)
    end
  end

  @spec activate(term()) :: :ok | error()
  def activate(%Reservation{} = reservation) do
    if Reservation.owner(reservation) == self() and is_pid(Reservation.worker(reservation)) do
      deadline = System.monotonic_time(:millisecond) + @activate_call_timeout_ms
      Worker.activate(reservation, deadline, @activate_call_timeout_ms)
    else
      {:error, {:memory_store, :async_writer, :invalid_reservation}}
    end
  end

  def activate(_reservation), do: {:error, {:memory_store, :async_writer, :invalid_reservation}}

  @spec cancel(term()) :: :ok | error()
  def cancel(%Reservation{} = reservation) do
    if Reservation.owner(reservation) == self() and is_pid(Reservation.worker(reservation)) do
      Worker.cancel(reservation)
    else
      {:error, {:memory_store, :async_writer, :invalid_reservation}}
    end
  end

  def cancel(_reservation), do: {:error, {:memory_store, :async_writer, :invalid_reservation}}

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

  defp start_reserved_worker(operation, owner) do
    spec = Worker.child_spec({operation, owner})

    case DynamicSupervisor.start_child(WriterSupervisor.name(), spec) do
      {:ok, pid} ->
        checkout_or_stop(pid, owner)

      {:ok, pid, _info} ->
        checkout_or_stop(pid, owner)

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

  defp checkout_or_stop(pid, owner) do
    case Worker.checkout_reservation(pid, owner) do
      {:ok, %Reservation{} = reservation} ->
        {:ok, reservation}

      error ->
        _ = DynamicSupervisor.terminate_child(WriterSupervisor.name(), pid)
        error
    end
  end

  defp map_admission(:draining), do: :draining
  defp map_admission(:destroyed), do: :destroyed
  defp map_admission(:capacity_exceeded), do: :capacity_exceeded
  defp map_admission(_reason), do: :unavailable
end
