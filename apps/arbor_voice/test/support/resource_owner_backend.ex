defmodule Arbor.Voice.Test.ResourceOwnerBackend do
  @moduledoc """
  Instrumented backend for `ResourceOwnerTest` that stores live state in ETS so
  multiple operations and test helpers share one mutable session record.
  """

  @behaviour Arbor.Voice.RealtimeBackend

  @session_table :arbor_voice_resource_owner_backend_sessions

  @default_secret "backend-secret-super-secret-value"

  @impl true
  def egress_route, do: :none

  defmodule Session do
    @enforce_keys [:id, :handle]
    defstruct [:id, :handle]
  end

  defstruct [
    :id,
    :parent,
    :handle,
    :generation,
    :configured,
    :sent_text,
    :sent_audio,
    :sent_tool_result,
    :recv_timeout,
    :close_count,
    :raise_on,
    :throw_on,
    :exit_on,
    :hang_close_for_ms,
    :secret
  ]

  @doc false
  def start_test_table! do
    case :ets.whereis(@session_table) do
      :undefined ->
        _tid = :ets.new(@session_table, [:named_table, :public, :set])

      tid ->
        if :ets.info(tid, :owner) == self() do
          :ets.delete_all_objects(tid)
        else
          raise "resource owner backend table is not owned by the test process"
        end
    end

    :ok
  end

  # The test process must own the table so ResourceOwner termination cannot erase
  # the close evidence that assertions inspect.
  defp ensure_table! do
    case :ets.whereis(@session_table) do
      :undefined -> raise "call start_test_table!/0 from test setup before opening a backend"
      tid -> tid
    end
  end

  defp session_entry_key(id), do: {:session, id}
  defp parent_entry_key(parent), do: {:parent, parent}

  @impl true
  def open(opts) do
    ensure_table!()

    case Keyword.get(opts, :open_mode) do
      :fail ->
        {:error, :open_failed}

      mode when mode in [:raise, :throw, :exit] ->
        failure_message = Keyword.get(opts, :secret, @default_secret)
        send_failure(mode, failure_message)

      _ ->
        id = make_ref()
        handle = make_ref()
        parent = Keyword.get(opts, :parent)

        state = %__MODULE__{
          id: id,
          parent: parent,
          handle: handle,
          generation: 0,
          configured: false,
          sent_text: false,
          sent_audio: false,
          sent_tool_result: false,
          recv_timeout: nil,
          close_count: 0,
          raise_on: MapSet.new(),
          throw_on: MapSet.new(),
          exit_on: MapSet.new(),
          hang_close_for_ms: Keyword.get(opts, :hang_close_for_ms, 0),
          secret: Keyword.get(opts, :secret, @default_secret)
        }

        persist_state(state)
        notify_parent(parent, {:resource_owner_backend_open, id})
        {:ok, %Session{id: id, handle: handle}}
    end
  end

  @impl true
  def configure(%Session{id: id} = session, _config) do
    with {:ok, state} <- get_state(id), :ok <- maybe_fail(state, :configure) do
      next_handle = next_handle(state)
      state = %{state | configured: true, handle: next_handle}
      persist_state(state)
      {:ok, %Session{session | handle: next_handle}}
    end
  end

  @impl true
  def send_text(%Session{id: id} = session, _text) do
    with {:ok, state} <- get_state(id), :ok <- maybe_fail(state, :send_text) do
      next_handle = next_handle(state)
      state = %{state | sent_text: true, handle: next_handle}
      persist_state(state)
      {:ok, %Session{session | handle: next_handle}}
    end
  end

  @impl true
  def send_audio(%Session{id: id} = session, _chunk) do
    with {:ok, state} <- get_state(id), :ok <- maybe_fail(state, :send_audio) do
      next_handle = next_handle(state)
      state = %{state | sent_audio: true, handle: next_handle}
      persist_state(state)
      {:ok, %Session{session | handle: next_handle}}
    end
  end

  @impl true
  def send_tool_result(%Session{id: id} = session, _call_id, _output) do
    with {:ok, state} <- get_state(id), :ok <- maybe_fail(state, :send_tool_result) do
      next_handle = next_handle(state)
      state = %{state | sent_tool_result: true, handle: next_handle}
      persist_state(state)
      {:ok, %Session{session | handle: next_handle}}
    end
  end

  @impl true
  def recv(%Session{id: id} = session, timeout) do
    with {:ok, state} <- get_state(id), :ok <- maybe_fail(state, :recv) do
      next_handle = next_handle(state)
      state = %{state | recv_timeout: timeout, handle: next_handle}
      persist_state(state)
      {:ok, %Session{session | handle: next_handle}, {:turn_done, %{text: ""}}}
    end
  end

  def session_handle(subject) do
    case to_subject_session(subject) do
      nil -> nil
      session_id -> session_handle_for_session(session_id)
    end
  end

  @impl true
  def close(%Session{id: id}) do
    with {:ok, state} <- get_state(id) do
      updated =
        state
        |> Map.put(:close_count, state.close_count + 1)

      notify_parent(updated.parent, {:resource_owner_backend_close, id, updated.close_count})
      persist_state(updated)

      if is_integer(updated.hang_close_for_ms) and updated.hang_close_for_ms > 0 do
        Process.sleep(updated.hang_close_for_ms)
      end
    end

    :ok
  end

  @impl true
  def meta(_session) do
    %{
      backend: :resource_owner_backend,
      mode: :cloud,
      input_rate: 16_000,
      output_rate: 24_000
    }
  end

  def set_failures(subject, failures) when is_list(failures),
    do: set_failures_for_subject(subject, failures)

  def set_failures(subject, failures), do: set_failures_for_subject(subject, failures)

  def set_failures(subject, mode, operations) when is_atom(mode) and is_list(operations) do
    set_failures(subject, [{mode, operations}])
  end

  def set_hang_close(subject, timeout_ms) when is_integer(timeout_ms) or timeout_ms == nil do
    case to_subject_session(subject) do
      nil -> :error
      session_id -> set_hang_close_for_session(session_id, timeout_ms)
    end
  end

  def close_count(subject) do
    case to_subject_session(subject) do
      nil -> 0
      session_id -> close_count_for_session(session_id)
    end
  end

  # Helpers

  defp set_failures_for_subject(subject, opts) do
    case to_subject_session(subject) do
      nil -> :error
      session_id -> set_failures_for_session(session_id, opts)
    end
  end

  defp to_subject_session(session_id) when is_reference(session_id), do: session_id

  defp to_subject_session(pid) when is_pid(pid) do
    ensure_table!()

    case :ets.lookup(@session_table, parent_entry_key(pid)) do
      [{_, session_id}] -> session_id
      [] -> nil
    end
  end

  defp to_subject_session(module) when is_atom(module),
    do: to_subject_session(self())

  defp to_subject_session(_), do: nil

  defp set_failures_for_session(session_id, opts) when is_reference(session_id) do
    with {:ok, %__MODULE__{} = state} <- get_state(session_id) do
      failures = normalize_failures(opts)

      state =
        %__MODULE__{
          state
          | raise_on: failures.raise_on,
            throw_on: failures.throw_on,
            exit_on: failures.exit_on
        }

      persist_state(state)
      :ok
    end
  end

  defp set_failures_for_session(_session_id, _opts), do: :error

  defp set_hang_close_for_session(session_id, timeout_ms) when is_reference(session_id) do
    with {:ok, %__MODULE__{} = state} <- get_state(session_id) do
      persist_state(%{state | hang_close_for_ms: timeout_ms})
      :ok
    end
  end

  defp set_hang_close_for_session(_session_id, _timeout_ms), do: :error

  defp close_count_for_session(session_id) when is_reference(session_id) do
    case get_state(session_id) do
      {:ok, state} -> state.close_count
      _ -> 0
    end
  end

  defp persist_state(%__MODULE__{} = state) do
    ensure_table!()
    :ets.insert(@session_table, {session_entry_key(state.id), state})

    if is_pid(state.parent) do
      :ets.insert(@session_table, {parent_entry_key(state.parent), state.id})
    end

    :ok
  end

  defp session_handle_for_session(session_id) when is_reference(session_id) do
    case get_state(session_id) do
      {:ok, state} -> state.handle
      _ -> nil
    end
  end

  defp get_state(session_id) when is_reference(session_id) do
    ensure_table!()

    case :ets.lookup(@session_table, session_entry_key(session_id)) do
      [{_, state}] -> {:ok, state}
      [] -> :error
    end
  end

  defp get_state(_), do: :error

  defp next_handle(_state) do
    make_ref()
  end

  defp normalize_failures(failures) when is_list(failures) do
    raise_on =
      failures
      |> Keyword.get(:raise, [])
      |> Enum.into(MapSet.new())

    throw_on =
      failures
      |> Keyword.get(:throw, [])
      |> Enum.into(MapSet.new())

    exit_on =
      failures
      |> Keyword.get(:exit, [])
      |> Enum.into(MapSet.new())

    %{raise_on: raise_on, throw_on: throw_on, exit_on: exit_on}
  end

  defp normalize_failures({mode, operations}) when mode in [:raise, :throw, :exit] do
    normalize_failures([{mode, operations}])
  end

  defp normalize_failures(_),
    do: %{raise_on: MapSet.new(), throw_on: MapSet.new(), exit_on: MapSet.new()}

  defp maybe_fail(state, operation) do
    cond do
      MapSet.member?(state.raise_on, operation) ->
        {:error, raise_failure(state)}

      MapSet.member?(state.throw_on, operation) ->
        {:error, throw_failure(state)}

      MapSet.member?(state.exit_on, operation) ->
        {:error, exit_failure(state)}

      true ->
        :ok
    end
  end

  defp raise_failure(state),
    do: raise("backend failed #{inspect(state.id)} with secret=#{state.secret}")

  defp throw_failure(state), do: throw({:throw, state.secret})

  defp exit_failure(state), do: exit({:exit, state.secret})

  defp notify_parent(parent, payload) when is_pid(parent), do: send(parent, payload)
  defp notify_parent(_parent, _payload), do: :ok

  defp send_failure(:raise, message), do: raise(message)
  defp send_failure(:throw, message), do: throw(message)
  defp send_failure(:exit, message), do: exit(message)
  defp send_failure(_mode, _message), do: :ok
end
