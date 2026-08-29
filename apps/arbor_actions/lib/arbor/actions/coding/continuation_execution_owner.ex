defmodule Arbor.Actions.Coding.ContinuationExecutionOwner do
  @moduledoc false

  use GenServer

  @pending_ttl_ms 5_000
  @handle_bytes 32
  @call_timeout_ms 5_000
  @action Arbor.Actions.Coding.CrossApp.Validate

  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def bind(registered_name, opts \\ []),
    do: call(opts, {:bind, registered_name})

  def arm(scope, opts \\ []), do: call(opts, {:arm, scope})

  def abort(continuation_id, opts \\ []),
    do: call(opts, {:abort, continuation_id})

  def invalidate(continuation_id, generation, opts \\ []),
    do: call(opts, {:invalidate, continuation_id, generation})

  def attach(handle, opts \\ []), do: call(opts, {:attach, handle})

  def recheck_live(opts \\ []), do: call(opts, {:recheck, self()})

  def live_grant(opts \\ []), do: call(opts, {:live_grant, self()})

  def release(opts \\ []), do: call(opts, {:release, self()})

  def grant_count(opts \\ []), do: call(opts, :grant_count)

  defp call(opts, message) do
    server = Keyword.get(opts, :server, server_name())

    try do
      GenServer.call(server, message, @call_timeout_ms)
    catch
      :exit, {:noproc, _} -> {:error, :witness_unbound}
      :exit, {:timeout, _} -> {:error, :not_ready}
    end
  end

  defp server_name do
    Application.get_env(
      :arbor_actions,
      :continuation_execution_owner,
      __MODULE__
    )
  end

  @impl true
  def init(_opts) do
    {:ok,
     %{
       witness: nil,
       epoch: 0,
       grants: %{},
       handles: %{},
       by_executor: %{}
     }}
  end

  @impl true
  def handle_call({:bind, registered_name}, {from_pid, _tag}, state) do
    {reply, state} = do_bind(registered_name, from_pid, state)
    {:reply, reply, state}
  end

  def handle_call({:arm, scope}, {from_pid, _tag}, state) do
    if witness_pid?(state, from_pid) do
      {reply, state} = do_arm(scope, state)
      {:reply, reply, state}
    else
      {:reply, {:error, :foreign_caller}, state}
    end
  end

  def handle_call({:abort, continuation_id}, {from_pid, _tag}, state) do
    if witness_pid?(state, from_pid) do
      {:reply, :ok, abort_grant(state, continuation_id)}
    else
      {:reply, {:error, :foreign_caller}, state}
    end
  end

  def handle_call({:invalidate, continuation_id, generation}, {from_pid, _tag}, state) do
    if witness_pid?(state, from_pid) do
      {:reply, :ok, invalidate_generation(state, continuation_id, generation)}
    else
      {:reply, {:error, :foreign_caller}, state}
    end
  end

  def handle_call({:attach, handle}, {from_pid, _tag}, state) do
    {reply, state} = do_attach(handle, from_pid, state)
    {:reply, reply, state}
  end

  def handle_call({:recheck, executor_pid}, {from_pid, _tag}, state)
      when from_pid == executor_pid do
    {:reply, recheck_grant(state, executor_pid), state}
  end

  def handle_call({:live_grant, executor_pid}, {from_pid, _tag}, state)
      when from_pid == executor_pid do
    {:reply, inspect_grant(state, executor_pid), state}
  end

  def handle_call({:release, executor_pid}, {from_pid, _tag}, state)
      when from_pid == executor_pid do
    {:reply, :ok, drop_executor_grant(state, executor_pid)}
  end

  def handle_call(:grant_count, _from, state) do
    {:reply, map_size(state.grants), state}
  end

  def handle_call(_message, _from, state) do
    {:reply, {:error, :foreign_caller}, state}
  end

  @impl true
  def handle_info({:pending_ttl, continuation_id, handle}, state) do
    {:noreply, expire_pending(state, continuation_id, handle)}
  end

  def handle_info({:DOWN, monitor_ref, :process, pid, _reason}, state) do
    {:noreply, handle_down(state, monitor_ref, pid)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp do_bind(name, from_pid, state) when is_atom(name) do
    case Process.whereis(name) do
      ^from_pid when is_pid(from_pid) ->
        bind_witness(state, name, from_pid)

      _other ->
        {{:error, :foreign_caller}, state}
    end
  end

  defp do_bind(_name, _from_pid, state), do: {{:error, :invalid_witness}, state}

  defp bind_witness(%{witness: nil} = state, name, pid) do
    {:ok, put_witness(state, name, pid)}
  end

  defp bind_witness(%{witness: %{name: name, pid: pid}} = state, name, pid) do
    {:ok, state}
  end

  defp bind_witness(%{witness: %{name: name, pid: old_pid}} = state, name, pid)
       when old_pid != pid do
    if Process.alive?(old_pid) do
      {{:error, :witness_busy}, state}
    else
      state = increment_epoch(demonitor_witness(state))
      {:ok, put_witness(state, name, pid)}
    end
  end

  defp bind_witness(state, _name, _pid), do: {{:error, :witness_busy}, state}

  defp put_witness(state, name, pid) do
    monitor = Process.monitor(pid)
    epoch = state.epoch

    %{state | witness: %{name: name, pid: pid, monitor: monitor, epoch: epoch}}
  end

  defp do_arm(scope, state) when is_map(scope) do
    with {:ok, admitted} <- admit_scope(scope),
         :ok <- reject_busy(state, admitted.continuation_id),
         {:ok, grant} <- mint_grant(admitted, state) do
      state =
        state
        |> put_grant(grant)
        |> schedule_pending(grant)

      {{:ok, grant.handle}, state}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp do_arm(_scope, state), do: {{:error, :invalid_execution_grant_scope}, state}

  defp admit_scope(scope) when is_map(scope) do
    continuation_id = fetch_scope(scope, :continuation_id)
    workspace_id = fetch_scope(scope, :workspace_id)
    task_id = fetch_scope(scope, :task_id)
    principal_id = fetch_scope(scope, :principal_id)
    fence_generation = fetch_scope(scope, :fence_generation)
    expires_at = fetch_scope(scope, :expires_at)
    remaining_ttl_ms = fetch_scope(scope, :remaining_ttl_ms)
    window = fetch_scope(scope, :window)
    receipt = fetch_scope(scope, :receipt)
    action = fetch_scope(scope, :action)

    with true <- action in [nil, @action],
         true <- is_binary(continuation_id) and continuation_id != "",
         true <- is_binary(workspace_id) and workspace_id != "",
         true <- is_binary(task_id) and task_id != "",
         true <- is_binary(principal_id) and principal_id != "",
         true <- is_integer(fence_generation) and fence_generation > 0,
         true <- is_binary(expires_at) and expires_at != "",
         true <- is_integer(remaining_ttl_ms) and remaining_ttl_ms > 0,
         true <- is_map(window) and not is_struct(window),
         true <- is_map(receipt) and not is_struct(receipt) do
      {:ok,
       %{
         action: @action,
         continuation_id: continuation_id,
         workspace_id: workspace_id,
         task_id: task_id,
         principal_id: principal_id,
         fence_generation: fence_generation,
         expires_at: expires_at,
         remaining_ttl_ms: remaining_ttl_ms,
         window: window,
         receipt: receipt
       }}
    else
      _ -> {:error, :invalid_execution_grant_scope}
    end
  end

  defp fetch_scope(scope, key) when is_atom(key) do
    Map.get(scope, key) || Map.get(scope, Atom.to_string(key))
  end

  defp reject_busy(state, continuation_id) do
    case Map.get(state.grants, continuation_id) do
      nil -> :ok
      _grant -> {:error, :execution_grant_busy}
    end
  end

  defp mint_grant(scope, state) do
    handle = Base.encode16(:crypto.strong_rand_bytes(@handle_bytes), case: :lower)
    now = System.monotonic_time(:millisecond)

    {:ok,
     %{
       handle: handle,
       action: scope.action,
       continuation_id: scope.continuation_id,
       workspace_id: scope.workspace_id,
       task_id: scope.task_id,
       principal_id: scope.principal_id,
       fence_generation: scope.fence_generation,
       expires_at: scope.expires_at,
       deadline_mono: now + scope.remaining_ttl_ms,
       window: scope.window,
       receipt: scope.receipt,
       status: :pending_attach,
       executor_pid: nil,
       executor_monitor: nil,
       pending_timer: nil,
       witness_epoch: state.epoch
     }}
  end

  defp put_grant(state, grant) do
    %{
      state
      | grants: Map.put(state.grants, grant.continuation_id, grant),
        handles: Map.put(state.handles, grant.handle, grant.continuation_id)
    }
  end

  defp schedule_pending(state, grant) do
    timer =
      Process.send_after(
        self(),
        {:pending_ttl, grant.continuation_id, grant.handle},
        @pending_ttl_ms
      )

    grant = %{grant | pending_timer: timer}
    replace_grant(state, grant)
  end

  defp do_attach(handle, from_pid, state) when is_binary(handle) do
    case Map.get(state.handles, handle) do
      nil ->
        {{:error, :invalid_handoff}, state}

      continuation_id ->
        attach_grant(state, continuation_id, handle, from_pid)
    end
  end

  defp do_attach(_handle, _from_pid, state), do: {{:error, :invalid_handoff}, state}

  defp attach_grant(state, continuation_id, handle, from_pid) do
    grant = Map.fetch!(state.grants, continuation_id)

    cond do
      grant.handle != handle ->
        {{:error, :invalid_handoff}, state}

      grant.status != :pending_attach ->
        {{:error, :invalid_handoff}, state}

      not current_witness?(state) ->
        {{:error, :witness_unbound}, drop_grant(state, continuation_id)}

      grant.witness_epoch != state.epoch ->
        {{:error, :invalid_handoff}, drop_grant(state, continuation_id)}

      System.monotonic_time(:millisecond) >= grant.deadline_mono ->
        {{:error, :execution_grant_expired}, drop_grant(state, continuation_id)}

      Map.has_key?(state.by_executor, from_pid) ->
        {{:error, :invalid_handoff}, state}

      true ->
        if is_reference(grant.pending_timer), do: Process.cancel_timer(grant.pending_timer)
        monitor = Process.monitor(from_pid)

        grant = %{
          grant
          | status: :attached,
            executor_pid: from_pid,
            executor_monitor: monitor,
            pending_timer: nil
        }

        state =
          state
          |> replace_grant(grant)
          |> Map.update!(:by_executor, &Map.put(&1, from_pid, continuation_id))

        {{:ok, inspect_fields(grant)}, state}
    end
  end

  defp recheck_grant(state, executor_pid) do
    case inspect_grant(state, executor_pid) do
      {:ok, grant} ->
        stored = Map.fetch!(state.grants, grant.continuation_id)

        cond do
          stored.status != :attached ->
            {:error, :continuation_execution_unauthorized}

          not current_witness?(state) ->
            {:error, :witness_unbound}

          stored.witness_epoch != state.epoch ->
            {:error, :continuation_execution_unauthorized}

          System.monotonic_time(:millisecond) >= stored.deadline_mono ->
            {:error, :execution_grant_expired}

          true ->
            :ok
        end

      :none ->
        {:error, :continuation_execution_unauthorized}
    end
  end

  defp inspect_grant(state, executor_pid) do
    case Map.get(state.by_executor, executor_pid) do
      nil ->
        :none

      continuation_id ->
        case Map.get(state.grants, continuation_id) do
          %{executor_pid: ^executor_pid, status: status} = grant
          when status in [:attached, :attached_aborted] ->
            {:ok, inspect_fields(grant)}

          _other ->
            :none
        end
    end
  end

  defp inspect_fields(grant) do
    %{
      action: grant.action,
      continuation_id: grant.continuation_id,
      workspace_id: grant.workspace_id,
      task_id: grant.task_id,
      principal_id: grant.principal_id,
      fence_generation: grant.fence_generation,
      expires_at: grant.expires_at,
      window: grant.window,
      receipt: grant.receipt,
      status: grant.status
    }
  end

  defp expire_pending(state, continuation_id, handle) do
    case Map.get(state.grants, continuation_id) do
      %{handle: ^handle, status: :pending_attach} ->
        drop_grant(state, continuation_id)

      _other ->
        state
    end
  end

  defp abort_grant(state, continuation_id) do
    case Map.get(state.grants, continuation_id) do
      nil ->
        state

      %{status: :pending_attach} = _grant ->
        drop_grant(state, continuation_id)

      %{status: :attached} = grant ->
        replace_grant(state, %{grant | status: :attached_aborted})

      _other ->
        state
    end
  end

  defp invalidate_generation(state, continuation_id, generation) do
    case Map.get(state.grants, continuation_id) do
      %{fence_generation: ^generation} -> abort_grant(state, continuation_id)
      _other -> state
    end
  end

  defp drop_executor_grant(state, executor_pid) do
    case Map.get(state.by_executor, executor_pid) do
      nil -> state
      continuation_id -> drop_grant(state, continuation_id)
    end
  end

  defp drop_grant(state, continuation_id) do
    case Map.pop(state.grants, continuation_id) do
      {nil, _grants} ->
        state

      {grant, grants} ->
        if is_reference(grant.pending_timer), do: Process.cancel_timer(grant.pending_timer)

        if is_reference(grant.executor_monitor) do
          Process.demonitor(grant.executor_monitor, [:flush])
        end

        handles = Map.delete(state.handles, grant.handle)

        by_executor =
          if is_pid(grant.executor_pid),
            do: Map.delete(state.by_executor, grant.executor_pid),
            else: state.by_executor

        %{state | grants: grants, handles: handles, by_executor: by_executor}
    end
  end

  defp replace_grant(state, grant) do
    %{state | grants: Map.put(state.grants, grant.continuation_id, grant)}
  end

  defp handle_down(state, monitor_ref, pid) do
    cond do
      match?(%{monitor: ^monitor_ref}, state.witness) ->
        state
        |> abort_all()
        |> demonitor_witness()
        |> increment_epoch()

      Map.has_key?(state.by_executor, pid) ->
        drop_executor_grant(state, pid)

      true ->
        state
    end
  end

  defp abort_all(state) do
    Enum.reduce(Map.keys(state.grants), state, fn continuation_id, acc ->
      abort_grant(acc, continuation_id)
    end)
    |> drop_pending_grants()
  end

  defp drop_pending_grants(state) do
    Enum.reduce(state.grants, state, fn
      {continuation_id, %{status: :pending_attach}}, acc ->
        drop_grant(acc, continuation_id)

      _other, acc ->
        acc
    end)
  end

  defp demonitor_witness(%{witness: %{monitor: monitor}} = state) do
    Process.demonitor(monitor, [:flush])
    %{state | witness: nil}
  end

  defp demonitor_witness(state), do: %{state | witness: nil}

  defp increment_epoch(state), do: %{state | epoch: state.epoch + 1}

  defp witness_pid?(%{witness: %{pid: pid}}, from_pid), do: pid == from_pid
  defp witness_pid?(_state, _from_pid), do: false

  defp current_witness?(%{witness: %{pid: pid}}) when is_pid(pid), do: Process.alive?(pid)
  defp current_witness?(_state), do: false
end
