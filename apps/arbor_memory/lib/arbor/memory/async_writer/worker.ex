defmodule Arbor.Memory.AsyncWriter.Worker do
  @moduledoc false

  use GenServer

  alias Arbor.Memory.AsyncWriter.Operation
  alias Arbor.Memory.AsyncWriter.Reservation
  alias Arbor.Memory.MemoryStore
  alias Arbor.Memory.MutationAdmission

  @reservation_ttl_ms 5_000
  @token_bytes 32
  @default_call_timeout 1_000

  @doc false
  def start_link({operation, owner}) when is_pid(owner) do
    GenServer.start_link(__MODULE__, {operation, owner})
  end

  @doc false
  def child_spec({operation, owner}) when is_pid(owner) do
    %{
      id: {:async_writer, System.unique_integer([:positive])},
      start: {__MODULE__, :start_link, [{operation, owner}]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }
  end

  @doc false
  def checkout_reservation(pid, owner) when is_pid(pid) and is_pid(owner) do
    call(pid, {:checkout, owner})
  end

  def checkout_reservation(_pid, _owner),
    do: {:error, {:memory_store, :async_writer, :invalid_reservation}}

  @doc false
  def activate(%Reservation{} = reservation, deadline_mono, timeout)
      when is_integer(deadline_mono) and is_integer(timeout) and timeout > 0 do
    call(
      Reservation.worker(reservation),
      {:activate, Reservation.token(reservation), Reservation.owner(reservation), deadline_mono},
      timeout
    )
  end

  def activate(_reservation, _deadline_mono, _timeout),
    do: {:error, {:memory_store, :async_writer, :invalid_reservation}}

  @doc false
  def cancel(%Reservation{} = reservation) do
    call(
      Reservation.worker(reservation),
      {:cancel, Reservation.token(reservation), Reservation.owner(reservation)}
    )
  end

  def cancel(_reservation), do: {:error, {:memory_store, :async_writer, :invalid_reservation}}

  defp call(pid, message, timeout \\ @default_call_timeout) do
    GenServer.call(pid, message, timeout)
  catch
    :exit, {:timeout, _} -> {:error, {:memory_store, :async_writer, :unavailable}}
    :exit, {:noproc, _} -> {:error, {:memory_store, :async_writer, :unavailable}}
    :exit, _ -> {:error, {:memory_store, :async_writer, :unavailable}}
  end

  @impl true
  def init({operation, owner}) do
    if is_pid(owner) and node(owner) == node() do
      case Operation.validate(operation) do
        :ok ->
          acquire_reserved(operation, owner)

        {:error, _reason} ->
          {:stop, {:admission, :invalid_request}}
      end
    else
      {:stop, {:admission, :invalid_request}}
    end
  end

  @impl true
  def handle_call({:checkout, owner}, {caller, _}, %{phase: :reserved} = state) do
    if owner == state.owner and caller == state.owner do
      {:reply, {:ok, reservation(state)}, state}
    else
      {:reply, invalid_reservation(), state}
    end
  end

  def handle_call({:checkout, _owner}, _from, state) do
    {:reply, invalid_reservation(), state}
  end

  def handle_call({:activate, token, owner, deadline_mono}, {caller, _}, state) do
    now = now_ms()

    cond do
      state.phase != :reserved ->
        {:reply, invalid_reservation(), state}

      token != state.token or owner != state.owner or caller != state.owner ->
        {:reply, invalid_reservation(), state}

      now >= state.deadline_mono ->
        stop_reserved(state, expired())

      not is_integer(deadline_mono) or now >= deadline_mono ->
        stop_reserved(state, expired())

      Operation.validate(state.operation) != :ok ->
        stop_reserved(state, {:error, {:memory_store, :async_writer, :invalid_operation}})

      MutationAdmission.assert_owner(state.lease) != :ok ->
        stop_reserved(state, {:error, {:memory_store, :async_writer, :unavailable}})

      true ->
        commit_activated(state)
    end
  end

  def handle_call({:cancel, token, owner}, {caller, _}, state) do
    cond do
      state.phase != :reserved ->
        {:reply, invalid_reservation(), state}

      token != state.token or owner != state.owner or caller != state.owner ->
        {:reply, invalid_reservation(), state}

      true ->
        stop_reserved(state, :ok)
    end
  end

  def handle_call(_message, _from, state) do
    {:reply, invalid_reservation(), state}
  end

  @impl true
  def handle_info(
        {:DOWN, mon, :process, _pid, _reason},
        %{phase: :reserved, owner_mon: mon} = state
      ) do
    _ = release_lease(state)
    {:stop, :normal, clear_lease(state)}
  end

  def handle_info({:DOWN, mon, :process, _pid, _reason}, %{owner_mon: mon} = state) do
    {:noreply, state}
  end

  def handle_info(
        {:reservation_deadline, msg_ref},
        %{phase: :reserved, msg_ref: msg_ref} = state
      ) do
    _ = release_lease(state)
    {:stop, :normal, clear_lease(state)}
  end

  def handle_info({:reservation_deadline, _msg_ref}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_continue(:run, %{phase: :activated} = state) do
    try do
      _ = perform(state.operation)
    after
      _ = release_lease(state)
    end

    {:stop, :normal, clear_lease(state)}
  end

  def handle_continue(_continue, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{lease: lease}) when not is_nil(lease) do
    _ = MutationAdmission.release(lease)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl true
  def format_status(status) when is_map(status) do
    status
    |> redact_status_state()
    |> redact_status_key(:message)
    |> redact_status_key(:log)
  end

  def format_status(status), do: status

  defp acquire_reserved(operation, owner) do
    case MutationAdmission.acquire(Operation.agent_id(operation)) do
      {:ok, lease} ->
        token = :crypto.strong_rand_bytes(@token_bytes)
        msg_ref = make_ref()

        {:ok,
         %{
           phase: :reserved,
           lease: lease,
           operation: operation,
           token: token,
           owner: owner,
           owner_mon: Process.monitor(owner),
           deadline_mono: now_ms() + @reservation_ttl_ms,
           timer_ref:
             Process.send_after(self(), {:reservation_deadline, msg_ref}, @reservation_ttl_ms),
           msg_ref: msg_ref
         }}

      {:error, reason} ->
        {:stop, {:admission, reason}}
    end
  end

  defp commit_activated(state) do
    cancel_timer(state)
    {:reply, :ok, %{state | phase: :activated}, {:continue, :run}}
  end

  defp stop_reserved(state, reply) do
    cancel_timer(state)
    _ = release_lease(state)
    {:stop, :normal, reply, clear_lease(state)}
  end

  defp reservation(state) do
    Reservation.new(
      state.token,
      self(),
      state.owner,
      Operation.agent_id(state.operation)
    )
  end

  defp redact_status_state(%{state: state} = status) when is_map(state) do
    Map.put(status, :state, redact(state))
  end

  defp redact_status_state(status), do: status

  defp redact_status_key(status, key) do
    if is_map_key(status, key) do
      Map.put(status, key, :redacted)
    else
      status
    end
  end

  defp perform({:persist, fields}) do
    MemoryStore.persist_confirmed(
      fields.namespace,
      fields.key,
      fields.data,
      fields.metadata
    )
  end

  defp perform({:embed, fields}) do
    MemoryStore.embed_confirmed(
      fields.agent_id,
      fields.namespace,
      fields.key,
      fields.content,
      fields.type,
      fields.taint
    )
  end

  defp release_lease(%{lease: nil}), do: :ok
  defp release_lease(%{lease: lease}), do: MutationAdmission.release(lease)

  defp clear_lease(state), do: %{state | lease: nil, phase: :stopped}

  defp cancel_timer(%{timer_ref: timer_ref}) when is_reference(timer_ref) do
    _ = Process.cancel_timer(timer_ref)
    :ok
  end

  defp cancel_timer(_state), do: :ok

  defp redact(state) do
    %{
      phase: Map.get(state, :phase),
      agent_id: safe_agent_id(state),
      operation_kind: safe_kind(state)
    }
  end

  defp safe_agent_id(%{operation: operation}) do
    Operation.agent_id(operation)
  rescue
    _ -> :redacted
  end

  defp safe_agent_id(_state), do: :redacted

  defp safe_kind(%{operation: {kind, _fields}}) when kind in [:persist, :embed], do: kind
  defp safe_kind(_state), do: :redacted

  defp invalid_reservation, do: {:error, {:memory_store, :async_writer, :invalid_reservation}}
  defp expired, do: {:error, {:memory_store, :async_writer, :expired}}
  defp now_ms, do: System.monotonic_time(:millisecond)
end
