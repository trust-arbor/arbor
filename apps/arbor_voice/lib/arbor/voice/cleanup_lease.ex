defmodule Arbor.Voice.CleanupLease do
  @moduledoc false

  use GenServer

  alias Arbor.Voice.Redacted

  @supervisor Arbor.Voice.CleanupLeaseSupervisor
  @cleanup_supervisor Arbor.Voice.ResourceCleanupTaskSupervisor

  @default_cleanup_per_attempt_timeout_ms 2_000
  @default_retry_base_ms 50
  @default_retry_max_ms 2_000
  @default_max_cleanups 16

  @max_cleanup_per_attempt_timeout_ms 60_000
  @max_retry_ms 60_000
  @max_cleanups 64
  @call_timeout_ms 5_000
  @provisional_cleanup_tag :voice_provisional_cleanup

  @allowed_opts [
    :supervisor,
    :cleanup_supervisor,
    :cleanup_per_attempt_timeout_ms,
    :retry_base_ms,
    :retry_max_ms,
    :max_cleanups
  ]

  @type credential :: Redacted.t()

  @doc false
  @spec start(pid(), nil | {term(), (-> term())} | map(), keyword()) ::
          {:ok, pid(), credential()} | {:error, atom() | tuple()}
  def start(owner_pid, initial_cleanups \\ nil, opts \\ [])

  def start(owner_pid, initial_cleanups, opts)
      when is_pid(owner_pid) and is_list(opts) do
    if owner_pid != self() do
      {:error, :foreign_caller}
    else
      with :ok <- validate_opts_syntax(opts),
           {:ok, cleanups} <- normalize_initial_cleanups(initial_cleanups),
           {:ok, config} <- build_config(opts),
           true <- map_size(cleanups) <= config.max_cleanups,
           {:ok, supervisor} <-
             resolve_dynamic_supervisor(Keyword.get(opts, :supervisor, @supervisor)),
           :ok <-
             validate_cleanup_supervisor(
               Keyword.get(opts, :cleanup_supervisor, @cleanup_supervisor)
             ) do
        token = make_ref()

        spec = %{
          id: make_ref(),
          start:
            {__MODULE__, :start_link,
             [
               owner_pid,
               Redacted.new(token),
               Redacted.new(cleanups),
               config,
               Keyword.get(opts, :cleanup_supervisor, @cleanup_supervisor)
             ]},
          restart: :temporary,
          shutdown: 5_000,
          type: :worker
        }

        case DynamicSupervisor.start_child(supervisor, spec) do
          {:ok, pid} -> {:ok, pid, Redacted.new({pid, token})}
          {:ok, pid, _info} -> {:ok, pid, Redacted.new({pid, token})}
          {:error, reason} -> {:error, normalize_start_error(reason)}
        end
      else
        false -> {:error, :cleanup_capacity_exceeded}
        {:error, _reason} = error -> error
      end
    end
  end

  def start(_owner_pid, _initial_cleanups, _opts), do: {:error, :invalid_cleanup_config}

  @doc false
  def start_link(owner_pid, token, cleanups, config, cleanup_supervisor) do
    GenServer.start_link(
      __MODULE__,
      {owner_pid, token, cleanups, config, cleanup_supervisor}
    )
  end

  @doc false
  @spec bind_worker(credential(), pid()) :: :ok | {:error, atom()}
  def bind_worker(credential, worker) when is_pid(worker),
    do: credential_call(credential, {:bind_worker, worker})

  def bind_worker(_credential, _worker), do: {:error, :invalid_worker}

  @doc false
  @spec register_cleanup(credential(), term(), (-> term())) :: :ok | {:error, atom()}
  def register_cleanup(credential, key, fun) when is_function(fun, 0),
    do: credential_call(credential, {:register_cleanup, key, fun})

  def register_cleanup(_credential, _key, _fun), do: {:error, :invalid_cleanup}

  @doc false
  @spec adopt_provisional_cleanup(credential(), term(), (-> term())) ::
          :ok | {:error, atom()}
  def adopt_provisional_cleanup(credential, key, fun) when is_function(fun, 0),
    do: credential_call(credential, {:adopt_provisional_cleanup, key, fun})

  def adopt_provisional_cleanup(_credential, _key, _fun),
    do: {:error, :invalid_cleanup}

  @doc false
  @spec remove_cleanup(credential(), term()) :: :ok | {:error, atom()}
  def remove_cleanup(credential, key),
    do: credential_call(credential, {:remove_cleanup, key})

  @doc false
  @spec begin_cleanup(credential(), :fenced) :: :ok | {:error, atom()}
  def begin_cleanup(credential, :fenced),
    do: credential_call(credential, {:begin_cleanup, :fenced})

  def begin_cleanup(_credential, _proof), do: {:error, :cleanup_not_fenced}

  @doc false
  @spec await_empty(credential(), [term()], non_neg_integer()) ::
          :ok | {:error, :cleanup_pending | :lease_unavailable}
  def await_empty(credential, keys, timeout_ms)
      when is_list(keys) and is_integer(timeout_ms) and timeout_ms >= 0 do
    with {:ok, pid, token} <- unpack_credential(credential) do
      GenServer.call(pid, {:await_empty, token, keys, timeout_ms}, timeout_ms + @call_timeout_ms)
    else
      _ -> {:error, :lease_unavailable}
    end
  catch
    :exit, _ -> {:error, :lease_unavailable}
  end

  def await_empty(_credential, _keys, _timeout_ms), do: {:error, :lease_unavailable}

  @doc false
  @spec status(credential()) :: {:ok, map()} | {:error, :lease_unavailable}
  def status(credential), do: credential_call(credential, :status)

  @impl true
  def init({owner_pid, token, cleanups, config, cleanup_supervisor}) do
    Process.flag(:trap_exit, true)
    cleanups = Redacted.value(cleanups)

    state = %{
      token: token,
      owner_pid: owner_pid,
      owner_ref: Process.monitor(owner_pid),
      owner_down: false,
      worker_pid: nil,
      worker_ref: nil,
      retiring_worker: false,
      cleanups: Redacted.new(cleanups),
      order: Map.keys(cleanups),
      mode: :holding,
      config: config,
      cleanup_supervisor: cleanup_supervisor,
      current: nil,
      retry_ref: nil,
      retry_token: nil,
      retry_delay_ms: config.retry_base_ms,
      waiters: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call(request, from, state) do
    case request do
      {:bind_worker, token, worker} ->
        handle_authorized_call(token, {:bind_worker, worker}, from, state)

      {:register_cleanup, token, key, fun} ->
        handle_authorized_call(token, {:register_cleanup, key, fun}, from, state)

      {:adopt_provisional_cleanup, token, key, fun} ->
        handle_authorized_call(token, {:adopt_provisional_cleanup, key, fun}, from, state)

      {:remove_cleanup, token, key} ->
        handle_authorized_call(token, {:remove_cleanup, key}, from, state)

      {:begin_cleanup, token, proof} ->
        handle_authorized_call(token, {:begin_cleanup, proof}, from, state)

      {:await_empty, token, keys, timeout_ms} ->
        handle_authorized_call(token, {:await_empty, keys, timeout_ms}, from, state)

      {:status, token} ->
        handle_authorized_call(token, :status, from, state)

      _ ->
        {:reply, {:error, :lease_unavailable}, state}
    end
  end

  defp handle_authorized_call(token, request, from, state) do
    if token == Redacted.value(state.token) do
      handle_lease_call(request, from, state)
    else
      {:reply, {:error, :lease_unavailable}, state}
    end
  end

  defp handle_lease_call({:bind_worker, _worker}, _from, %{owner_down: true} = state),
    do: {:reply, {:error, :owner_unavailable}, state}

  defp handle_lease_call({:bind_worker, worker}, _from, state) when is_pid(worker) do
    cond do
      not Process.alive?(worker) ->
        {:reply, {:error, :invalid_worker}, state}

      is_pid(state.worker_pid) and Process.alive?(state.worker_pid) ->
        {:reply, {:error, :worker_already_bound}, state}

      true ->
        state = clear_worker_monitor(state)
        {:reply, :ok, %{state | worker_pid: worker, worker_ref: Process.monitor(worker)}}
    end
  end

  defp handle_lease_call({:register_cleanup, _key, _fun}, _from, %{mode: :draining} = state),
    do: {:reply, {:error, :lease_closing}, state}

  defp handle_lease_call({:register_cleanup, key, fun}, _from, state) do
    cleanups = Redacted.value(state.cleanups)

    cond do
      not is_function(fun, 0) ->
        {:reply, {:error, :invalid_cleanup}, state}

      Map.has_key?(cleanups, key) ->
        {:reply, {:error, :duplicate_cleanup_key}, state}

      map_size(cleanups) >= state.config.max_cleanups ->
        {:reply, {:error, :cleanup_capacity_exceeded}, state}

      true ->
        cleanups = Map.put(cleanups, key, fun)
        {:reply, :ok, %{state | cleanups: Redacted.new(cleanups), order: state.order ++ [key]}}
    end
  end

  defp handle_lease_call(
         {:adopt_provisional_cleanup, _key, _fun},
         _from,
         %{mode: :draining} = state
       ),
       do: {:reply, {:error, :lease_closing}, state}

  defp handle_lease_call({:adopt_provisional_cleanup, key, fun}, _from, state) do
    cleanups = Redacted.value(state.cleanups)
    provisional_key = {@provisional_cleanup_tag, key}

    case Map.fetch(cleanups, key) do
      {:ok, existing} when existing === fun ->
        {:reply, :ok, state}

      {:ok, _different} ->
        {:reply, {:error, :provisional_cleanup_conflict}, state}

      :error ->
        adopt_reserved_cleanup(state, cleanups, provisional_key, fun)
    end
  end

  defp handle_lease_call({:remove_cleanup, _key}, _from, %{mode: :draining} = state),
    do: {:reply, {:error, :lease_closing}, state}

  defp handle_lease_call({:remove_cleanup, key}, _from, state) do
    cleanups = Redacted.value(state.cleanups)

    if Map.has_key?(cleanups, key) do
      state = remove_cleanup_key(state, key)
      {:reply, :ok, notify_waiters(state)}
    else
      {:reply, {:error, :unknown_cleanup_key}, state}
    end
  end

  defp handle_lease_call({:begin_cleanup, :fenced}, _from, state) do
    state = state |> Map.put(:mode, :draining) |> schedule_work(0)
    {:reply, :ok, state}
  end

  defp handle_lease_call({:await_empty, keys, timeout_ms}, from, state) do
    with {:ok, key_set} <- normalize_wait_keys(keys) do
      if keys_absent?(state, key_set) do
        {:reply, :ok, state}
      else
        add_waiter(state, from, key_set, timeout_ms)
      end
    else
      _ -> {:reply, {:error, :lease_unavailable}, state}
    end
  end

  defp handle_lease_call(:status, _from, state) do
    status = %{
      cleanup_count: map_size(Redacted.value(state.cleanups)),
      mode: state.mode,
      owner_alive: not state.owner_down and Process.alive?(state.owner_pid),
      worker_alive: is_pid(state.worker_pid) and Process.alive?(state.worker_pid),
      cleanup_active: not is_nil(state.current),
      retry_scheduled: is_reference(state.retry_ref)
    }

    {:reply, {:ok, status}, state}
  end

  defp handle_lease_call(_request, _from, state),
    do: {:reply, {:error, :lease_unavailable}, state}

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, %{owner_ref: ref, owner_pid: pid} = state) do
    state = %{state | owner_ref: nil, owner_down: true, mode: :draining}

    state =
      case state.current do
        %{pid: cleanup_pid} = current ->
          if Process.alive?(cleanup_pid), do: Process.exit(cleanup_pid, :kill)
          %{state | current: %{current | timed_out: true, result: :error}}

        nil ->
          state
      end

    state =
      if is_pid(state.worker_pid) and Process.alive?(state.worker_pid) do
        Process.exit(state.worker_pid, :kill)
        %{state | retiring_worker: true}
      else
        clear_worker_monitor(state)
      end

    continue(state)
  end

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{worker_ref: ref, worker_pid: pid} = state
      ) do
    state = %{state | worker_pid: nil, worker_ref: nil, retiring_worker: false}
    continue(state)
  end

  def handle_info(
        {:cleanup_result, generation, pid, result, completed_at},
        %{current: %{generation: generation, pid: pid} = current} = state
      ) do
    valid_result =
      if result == :ok and is_integer(completed_at) and completed_at <= current.deadline_ms,
        do: :ok,
        else: :error

    current = %{current | result: valid_result}
    continue_current(%{state | current: current})
  end

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{current: %{monitor_ref: ref, pid: pid} = current} = state
      ) do
    current = %{current | down: true, result: current.result || :error}
    continue_current(%{state | current: current})
  end

  def handle_info(
        {:cleanup_timeout, generation, pid},
        %{current: %{generation: generation, pid: pid} = current} = state
      ) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    current = %{current | timed_out: true, timer_ref: nil, result: :error}
    {:noreply, %{state | current: current}}
  end

  def handle_info({:retry_cleanup, token}, %{retry_token: token} = state) do
    state = %{state | retry_ref: nil, retry_token: nil}
    continue(state)
  end

  def handle_info({:cleanup_wait_timeout, token}, state) do
    case Map.pop(state.waiters, token) do
      {nil, _waiters} ->
        {:noreply, state}

      {%{from: from}, waiters} ->
        GenServer.reply(from, {:error, :cleanup_pending})
        {:noreply, %{state | waiters: waiters}}
    end
  end

  def handle_info({:EXIT, pid, _reason}, %{current: %{pid: pid}} = state),
    do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.retry_ref)

    case state.current do
      %{pid: pid, timer_ref: timer_ref} ->
        cancel_timer(timer_ref)
        if Process.alive?(pid), do: Process.exit(pid, :kill)

      _ ->
        :ok
    end

    :ok
  end

  @impl true
  def format_status(%{state: state} = status) when is_map(state) do
    redacted = %{
      owner_pid: state.owner_pid,
      owner_down: state.owner_down,
      worker_pid: state.worker_pid,
      mode: state.mode,
      cleanup_count: map_size(Redacted.value(state.cleanups)),
      cleanup_active: not is_nil(state.current),
      retry_scheduled: is_reference(state.retry_ref)
    }

    %{status | state: redacted, message: :redacted, log: :redacted}
  end

  def format_status(status), do: status

  defp continue_current(%{current: %{down: true, result: result}} = state)
       when result in [:ok, :error] do
    current = state.current
    cancel_timer(current.timer_ref)

    state = %{state | current: nil}

    state =
      if result == :ok and not current.timed_out do
        state
        |> remove_cleanup_key(current.key)
        |> Map.put(:retry_delay_ms, state.config.retry_base_ms)
        |> notify_waiters()
      else
        state
        |> rotate_cleanup_key(current.key)
        |> schedule_retry()
      end

    continue(state)
  end

  defp continue_current(state), do: {:noreply, state}

  defp continue(state) do
    cond do
      should_stop?(state) ->
        {:stop, :normal, state}

      can_start_cleanup?(state) ->
        {:noreply, start_cleanup(state)}

      true ->
        {:noreply, maybe_schedule_retry(state)}
    end
  end

  defp can_start_cleanup?(state) do
    state.mode == :draining and is_nil(state.current) and is_nil(state.retry_ref) and
      map_size(Redacted.value(state.cleanups)) > 0 and
      not (state.owner_down and is_pid(state.worker_pid))
  end

  defp start_cleanup(state) do
    case next_cleanup(state) do
      {:ok, key, fun, state} ->
        case start_cleanup_task(state, key, fun) do
          {:ok, current} -> %{state | current: current}
          {:error, _reason} -> state |> rotate_cleanup_key(key) |> schedule_retry()
        end

      :none ->
        state
    end
  end

  defp start_cleanup_task(state, key, fun) do
    with {:ok, cleanup_supervisor} <- resolve_task_supervisor(state.cleanup_supervisor) do
      lease = self()
      generation = make_ref()
      timeout_ms = state.config.cleanup_per_attempt_timeout_ms
      deadline_ms = now_ms() + timeout_ms

      task = fn ->
        Process.link(lease)

        result =
          try do
            if fun.() == :ok, do: :ok, else: :error
          rescue
            _ -> :error
          catch
            _, _ -> :error
          end

        send(lease, {:cleanup_result, generation, self(), result, now_ms()})
      end

      case Task.Supervisor.start_child(cleanup_supervisor, task, restart: :temporary) do
        {:ok, pid} ->
          monitor_ref = Process.monitor(pid)
          timer_ref = Process.send_after(self(), {:cleanup_timeout, generation, pid}, timeout_ms)

          {:ok,
           %{
             key: key,
             generation: generation,
             pid: pid,
             monitor_ref: monitor_ref,
             timer_ref: timer_ref,
             deadline_ms: deadline_ms,
             result: nil,
             down: false,
             timed_out: false
           }}

        _ ->
          {:error, :cleanup_supervisor_unavailable}
      end
    end
  catch
    :exit, _ -> {:error, :cleanup_supervisor_unavailable}
  end

  defp next_cleanup(state) do
    cleanups = Redacted.value(state.cleanups)
    order = Enum.filter(state.order, &Map.has_key?(cleanups, &1))

    case order do
      [key | _] -> {:ok, key, Map.fetch!(cleanups, key), %{state | order: order}}
      [] -> :none
    end
  end

  defp remove_cleanup_key(state, key) do
    cleanups = Map.delete(Redacted.value(state.cleanups), key)
    %{state | cleanups: Redacted.new(cleanups), order: List.delete(state.order, key)}
  end

  defp rotate_cleanup_key(state, key) do
    order = state.order |> List.delete(key) |> Kernel.++([key])
    %{state | order: order}
  end

  defp maybe_schedule_retry(state) do
    if state.mode == :draining and is_nil(state.current) and is_nil(state.retry_ref) and
         map_size(Redacted.value(state.cleanups)) > 0 and
         not (state.owner_down and is_pid(state.worker_pid)) do
      schedule_retry(state)
    else
      state
    end
  end

  defp schedule_work(state, delay_ms) do
    if is_nil(state.current) and is_nil(state.retry_ref) do
      token = make_ref()
      ref = Process.send_after(self(), {:retry_cleanup, token}, delay_ms)
      %{state | retry_ref: ref, retry_token: token}
    else
      state
    end
  end

  defp schedule_retry(state) do
    delay = state.retry_delay_ms

    state
    |> schedule_work(delay)
    |> Map.put(:retry_delay_ms, min(delay * 2, state.config.retry_max_ms))
  end

  defp should_stop?(state) do
    state.owner_down and is_nil(state.worker_pid) and is_nil(state.current) and
      map_size(Redacted.value(state.cleanups)) == 0
  end

  defp adopt_reserved_cleanup(state, cleanups, provisional_key, fun) do
    cond do
      Map.get(cleanups, provisional_key) === fun ->
        {:reply, :ok, state}

      Map.has_key?(cleanups, provisional_key) ->
        {:reply, {:error, :provisional_cleanup_conflict}, state}

      Enum.any?(Map.keys(cleanups), &match?({@provisional_cleanup_tag, _}, &1)) ->
        {:reply, {:error, :provisional_cleanup_occupied}, state}

      true ->
        cleanups = Map.put(cleanups, provisional_key, fun)

        {:reply, :ok,
         %{state | cleanups: Redacted.new(cleanups), order: state.order ++ [provisional_key]}}
    end
  end

  defp add_waiter(state, _from, _keys, 0),
    do: {:reply, {:error, :cleanup_pending}, state}

  defp add_waiter(state, from, keys, timeout_ms) do
    token = make_ref()
    timer_ref = Process.send_after(self(), {:cleanup_wait_timeout, token}, timeout_ms)
    waiter = %{from: from, keys: keys, timer_ref: timer_ref}
    {:noreply, %{state | waiters: Map.put(state.waiters, token, waiter)}}
  end

  defp notify_waiters(state) do
    {remaining, _completed} =
      Enum.reduce(state.waiters, {%{}, []}, fn {token, waiter}, {pending, completed} ->
        if keys_absent?(state, waiter.keys) do
          cancel_timer(waiter.timer_ref)
          GenServer.reply(waiter.from, :ok)
          {pending, [token | completed]}
        else
          {Map.put(pending, token, waiter), completed}
        end
      end)

    %{state | waiters: remaining}
  end

  defp keys_absent?(state, key_set) do
    cleanups = Redacted.value(state.cleanups)
    Enum.all?(key_set, &(not Map.has_key?(cleanups, &1)))
  end

  defp normalize_wait_keys(keys) do
    if length(keys) == length(Enum.uniq(keys)),
      do: {:ok, MapSet.new(keys)},
      else: {:error, :duplicate_key}
  end

  defp clear_worker_monitor(%{worker_ref: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    %{state | worker_pid: nil, worker_ref: nil, retiring_worker: false}
  end

  defp clear_worker_monitor(state),
    do: %{state | worker_pid: nil, worker_ref: nil, retiring_worker: false}

  defp credential_call(credential, request) do
    with {:ok, pid, token} <- unpack_credential(credential) do
      message = insert_token(request, token)
      GenServer.call(pid, message, @call_timeout_ms)
    else
      _ -> {:error, :lease_unavailable}
    end
  catch
    :exit, _ -> {:error, :lease_unavailable}
  end

  defp unpack_credential(%Redacted{} = credential) do
    case Redacted.value(credential) do
      {pid, token} when is_pid(pid) and is_reference(token) -> {:ok, pid, token}
      _ -> {:error, :invalid_credential}
    end
  end

  defp unpack_credential(_credential), do: {:error, :invalid_credential}

  defp insert_token({:bind_worker, worker}, token), do: {:bind_worker, token, worker}

  defp insert_token({:register_cleanup, key, fun}, token),
    do: {:register_cleanup, token, key, fun}

  defp insert_token({:adopt_provisional_cleanup, key, fun}, token),
    do: {:adopt_provisional_cleanup, token, key, fun}

  defp insert_token({:remove_cleanup, key}, token), do: {:remove_cleanup, token, key}
  defp insert_token({:begin_cleanup, proof}, token), do: {:begin_cleanup, token, proof}
  defp insert_token(:status, token), do: {:status, token}

  defp normalize_initial_cleanups(nil), do: {:ok, %{}}

  defp normalize_initial_cleanups({key, fun}) when is_function(fun, 0),
    do: {:ok, %{key => fun}}

  defp normalize_initial_cleanups(cleanups) when is_map(cleanups) do
    if Enum.all?(cleanups, fn {_key, fun} -> is_function(fun, 0) end),
      do: {:ok, cleanups},
      else: {:error, :invalid_cleanup}
  end

  defp normalize_initial_cleanups(_), do: {:error, :invalid_cleanup}

  defp validate_opts_syntax(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)

      if length(keys) == length(Enum.uniq(keys)) and Enum.all?(keys, &(&1 in @allowed_opts)),
        do: :ok,
        else: {:error, :invalid_cleanup_config}
    else
      {:error, :invalid_cleanup_config}
    end
  end

  defp build_config(opts) do
    config = %{
      cleanup_per_attempt_timeout_ms:
        Keyword.get(
          opts,
          :cleanup_per_attempt_timeout_ms,
          @default_cleanup_per_attempt_timeout_ms
        ),
      retry_base_ms: Keyword.get(opts, :retry_base_ms, @default_retry_base_ms),
      retry_max_ms: Keyword.get(opts, :retry_max_ms, @default_retry_max_ms),
      max_cleanups: Keyword.get(opts, :max_cleanups, @default_max_cleanups)
    }

    with :ok <-
           bounded_positive(
             config.cleanup_per_attempt_timeout_ms,
             @max_cleanup_per_attempt_timeout_ms
           ),
         :ok <- bounded_positive(config.retry_base_ms, @max_retry_ms),
         :ok <- bounded_positive(config.retry_max_ms, @max_retry_ms),
         true <- config.retry_base_ms <= config.retry_max_ms,
         :ok <- bounded_positive(config.max_cleanups, @max_cleanups) do
      {:ok, config}
    else
      _ -> {:error, :invalid_cleanup_config}
    end
  end

  defp bounded_positive(value, max) when is_integer(value) and value > 0 and value <= max,
    do: :ok

  defp bounded_positive(_value, _max), do: {:error, :invalid_cleanup_config}

  defp resolve_dynamic_supervisor(name) when is_atom(name) and not is_nil(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> {:ok, pid}
      _ -> {:error, :supervisor_unavailable}
    end
  end

  defp resolve_dynamic_supervisor(pid) when is_pid(pid) do
    if Process.alive?(pid), do: {:ok, pid}, else: {:error, :supervisor_unavailable}
  end

  defp resolve_dynamic_supervisor(_), do: {:error, :supervisor_unavailable}

  defp validate_cleanup_supervisor(name) when is_atom(name) and not is_nil(name), do: :ok
  defp validate_cleanup_supervisor(pid) when is_pid(pid), do: :ok
  defp validate_cleanup_supervisor(_), do: {:error, :invalid_cleanup_config}

  defp resolve_task_supervisor(name) when is_atom(name) and not is_nil(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> {:ok, pid}
      _ -> {:error, :cleanup_supervisor_unavailable}
    end
  end

  defp resolve_task_supervisor(pid) when is_pid(pid) do
    if Process.alive?(pid), do: {:ok, pid}, else: {:error, :cleanup_supervisor_unavailable}
  end

  defp resolve_task_supervisor(_), do: {:error, :cleanup_supervisor_unavailable}

  defp normalize_start_error(:max_children), do: :cleanup_capacity_exceeded
  defp normalize_start_error(_), do: :supervisor_unavailable

  defp cancel_timer(ref) when is_reference(ref) do
    _ = Process.cancel_timer(ref)
    :ok
  end

  defp cancel_timer(_), do: :ok

  defp now_ms, do: System.monotonic_time(:millisecond)
end
