defmodule Arbor.Voice.ResourceOwner do
  @moduledoc """
  Supervised temporary owner of a realtime backend session and session-scoped
  cleanup obligations.

  The owner owns the backend session handle and executes all backend callbacks
  in its own process. Session-bound cleanups execute under a dedicated
  `Task.Supervisor` and are bounded by an absolute close deadline.
  """

  use GenServer

  alias Arbor.Voice.Redacted

  @supervisor Arbor.Voice.ResourceSupervisor
  @cleanup_supervisor Arbor.Voice.ResourceCleanupTaskSupervisor

  @default_close_timeout_ms 5_000
  @default_cleanup_ready_timeout_ms 500
  @default_cleanup_attempts 3
  @default_cleanup_per_attempt_timeout_ms 2_000
  @default_max_recv_timeout_ms 1_000
  @default_max_cleanups 16

  @max_recv_timeout_ms 1_000
  @max_cleanups 16
  @max_close_timeout_ms 60_000
  @max_cleanup_attempts 10
  @max_cleanup_per_attempt_timeout_ms 60_000
  @shutdown_grace_ms 5_000
  @shutdown_timeout_ms @max_close_timeout_ms + @shutdown_grace_ms

  @defaults [
    close_timeout_ms: @default_close_timeout_ms,
    cleanup_ready_timeout_ms: @default_cleanup_ready_timeout_ms,
    cleanup_attempts: @default_cleanup_attempts,
    cleanup_per_attempt_timeout_ms: @default_cleanup_per_attempt_timeout_ms,
    max_recv_timeout_ms: @default_max_recv_timeout_ms,
    max_cleanups: @default_max_cleanups
  ]

  @allowed_owner_opts [
    :close_timeout_ms,
    :cleanup_ready_timeout_ms,
    :cleanup_attempts,
    :cleanup_per_attempt_timeout_ms,
    :max_recv_timeout_ms,
    :max_cleanups,
    :supervisor,
    :cleanup_supervisor
  ]

  @call_timeout_ms @shutdown_timeout_ms

  @doc false
  def start(owner_pid, backend_module, backend_opts \\ [], opts \\ [])

  def start(owner_pid, backend_module, backend_opts, opts)
      when is_pid(owner_pid) and is_atom(backend_module) do
    if owner_pid != self() do
      {:error, :foreign_caller}
    else
      with :ok <- validate_backend_opts(backend_opts),
           {:ok, config} <- validate_opts(opts),
           supervisor_opt <- Keyword.get(opts, :supervisor, @supervisor),
           cleanup_supervisor_opt <-
             Keyword.get(opts, :cleanup_supervisor, @cleanup_supervisor),
           {:ok, supervisor} <- resolve_supervisor(supervisor_opt),
           {:ok, cleanup_supervisor} <-
             resolve_cleanup_supervisor(cleanup_supervisor_opt),
           :ok <- validate_backend_module(backend_module) do
        spec = %{
          id: make_ref(),
          start:
            {__MODULE__, :start_link,
             [
               owner_pid,
               backend_module,
               Redacted.new(backend_opts),
               config,
               supervisor,
               cleanup_supervisor
             ]},
          restart: :temporary,
          shutdown: @shutdown_timeout_ms,
          type: :worker
        }

        case DynamicSupervisor.start_child(supervisor, spec) do
          {:ok, pid} ->
            {:ok, pid}

          {:ok, pid, _info} ->
            {:ok, pid}

          {:error, reason} ->
            {:error, normalize_supervisor_error(reason)}
        end
      end
    end
  end

  def start(_owner_pid, _backend_module, _backend_opts, _opts),
    do: {:error, :invalid_owner_config}

  @doc false
  def start_link(
        owner_pid,
        backend_module,
        backend_opts,
        config,
        supervisor,
        cleanup_supervisor
      )
      when is_pid(owner_pid) and is_atom(backend_module) and is_map(config) and is_pid(supervisor) and
             is_pid(cleanup_supervisor) do
    GenServer.start_link(
      __MODULE__,
      {owner_pid, backend_module, backend_opts, config, supervisor, cleanup_supervisor}
    )
  end

  @spec configure(GenServer.server(), map()) :: :ok | {:error, atom()}
  def configure(owner, config), do: call(owner, {:backend, :configure, [config]})

  @spec send_text(GenServer.server(), String.t()) :: :ok | {:error, atom()}
  def send_text(owner, text), do: call(owner, {:backend, :send_text, [text]})

  @spec send_audio(GenServer.server(), binary()) :: :ok | {:error, atom()}
  def send_audio(owner, chunk), do: call(owner, {:backend, :send_audio, [chunk]})

  @spec send_tool_result(GenServer.server(), String.t(), String.t()) :: :ok | {:error, atom()}
  def send_tool_result(owner, call_id, output),
    do: call(owner, {:backend, :send_tool_result, [call_id, output]})

  @doc """
  Nonblocking owner-authenticated tool-result request.

  Uses `:gen_server.send_request/2` so `caller_pid` remains `self()` (must be the
  Session owner_pid). Callers that need the result use
  `:gen_server.wait_response/2`; cancel/best-effort paths may fire-and-forget and
  rely on same-sender mailbox ordering so requests are enqueued before a
  subsequent `close/1` call.
  """
  @spec send_tool_result_request(GenServer.server(), String.t(), String.t()) ::
          {:ok, :gen_server.request_id()} | {:error, atom()}
  def send_tool_result_request(owner, call_id, output)
      when is_pid(owner) and is_binary(call_id) and is_binary(output) do
    req_id = :gen_server.send_request(owner, {:backend, :send_tool_result, [call_id, output]})
    {:ok, req_id}
  rescue
    _ -> {:error, :owner_unavailable}
  catch
    :exit, {:noproc, _} -> {:error, :owner_unavailable}
    :exit, _ -> {:error, :owner_unavailable}
    _kind, _reason -> {:error, :owner_unavailable}
  end

  def send_tool_result_request(_owner, _call_id, _output), do: {:error, :owner_unavailable}

  @spec recv(GenServer.server(), timeout()) ::
          {:ok, Arbor.Voice.RealtimeBackend.event()} | {:error, atom()}
  def recv(owner, timeout), do: call(owner, {:backend, :recv, [timeout]})

  @spec meta(GenServer.server()) :: {:ok, map()} | {:error, atom()}
  def meta(owner), do: call(owner, :meta)

  @spec register_cleanup(GenServer.server(), term(), fun()) :: :ok | {:error, atom()}
  def register_cleanup(owner, key, fun), do: call(owner, {:register_cleanup, key, fun})

  @spec remove_cleanup(GenServer.server(), term()) :: :ok | {:error, atom()}
  def remove_cleanup(owner, key), do: call(owner, {:remove_cleanup, key})

  @spec close(GenServer.server()) :: :ok | {:error, atom()}
  def close(owner) when is_pid(owner) do
    GenServer.call(owner, :close, @call_timeout_ms)
  catch
    :exit, {:timeout, _} -> {:error, :owner_timeout}
    :exit, {:killed, _} -> {:error, :owner_timeout}
    :exit, :killed -> {:error, :owner_timeout}
    :exit, {:noproc, _} -> :ok
    :exit, {:normal, _} -> :ok
    :exit, _ -> {:error, :owner_unavailable}
  end

  def close(_owner), do: {:error, :owner_unavailable}

  defp call(owner, message, timeout \\ @call_timeout_ms) do
    if is_pid(owner) do
      GenServer.call(owner, message, timeout)
    else
      {:error, :owner_unavailable}
    end
  catch
    :exit, {:timeout, _} -> {:error, :owner_timeout}
    :exit, {:noproc, _} -> {:error, :owner_unavailable}
    :exit, _ -> {:error, :owner_unavailable}
  end

  @impl true
  def init({owner_pid, backend_module, backend_opts, config, supervisor, cleanup_supervisor}) do
    if not is_pid(supervisor) or not is_pid(cleanup_supervisor) do
      {:stop, :invalid_supervisor}
    else
      if not Process.alive?(supervisor) do
        {:stop, :supervisor_unavailable}
      else
        if not Process.alive?(cleanup_supervisor) do
          {:stop, :cleanup_unavailable}
        else
          state = %{
            owner_pid: owner_pid,
            owner_ref: Process.monitor(owner_pid),
            backend_mod: backend_module,
            backend_opts: backend_opts,
            session: nil,
            config: config,
            supervisor: supervisor,
            supervisor_ref: Process.monitor(supervisor),
            cleanup_supervisor: cleanup_supervisor,
            cleanup_supervisor_ref: Process.monitor(cleanup_supervisor),
            close_state: :open,
            close_ref: nil,
            close_deadline_ms: nil,
            close_coordinator_pid: nil,
            close_coordinator_ref: nil,
            coordinator_ready: false,
            coordinator_ready_ref: nil,
            close_deadline_ref: nil,
            backend_closed: false,
            cleanups_done: false,
            cleanups: Redacted.new(%{}),
            close_waiters: []
          }

          case open_backend(state) do
            {:ok, session} ->
              {:ok, %{state | session: Redacted.new(session)}}

            {:error, reason} ->
              {:stop, reason}
          end
        end
      end
    end
  end

  @impl true
  def handle_call(request, {caller_pid, _tag} = from, state) do
    if caller_pid == state.owner_pid do
      handle_owner_call(request, from, state)
    else
      {:reply, {:error, :foreign_caller}, state}
    end
  end

  defp handle_owner_call(:close, _from, %{close_state: :closed} = state) do
    {:reply, :ok, state}
  end

  defp handle_owner_call(:close, from, %{close_state: :closing} = state) do
    {:noreply, add_close_waiter(state, from)}
  end

  defp handle_owner_call(:close, from, state) do
    case begin_close(state) do
      {:ok, next_state} ->
        {:noreply, add_close_waiter(next_state, from)}

      {:error, reason, next_state} ->
        next_state = stop_after_close(next_state, reason)

        {:stop, :normal, {:error, reason}, next_state}
    end
  end

  defp handle_owner_call({:backend, _operation, _args}, _from, %{close_state: :closed} = state) do
    {:reply, {:error, :owner_closed}, state}
  end

  defp handle_owner_call({:backend, _operation, _args}, _from, %{close_state: :closing} = state) do
    {:reply, {:error, :owner_closing}, state}
  end

  defp handle_owner_call({:backend, operation, args}, _from, state) do
    case execute_backend_callback(operation, args, state) do
      {:ok, next_state} ->
        {:reply, :ok, next_state}

      {:ok, next_state, event} ->
        {:reply, {:ok, event}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp handle_owner_call(:meta, _from, %{close_state: :closed} = state) do
    {:reply, {:error, :owner_closed}, state}
  end

  defp handle_owner_call(:meta, _from, %{close_state: :closing} = state) do
    {:reply, {:error, :owner_closing}, state}
  end

  defp handle_owner_call(:meta, _from, state) do
    case safe_meta(state.backend_mod, Redacted.value(state.session)) do
      {:ok, meta} ->
        {:reply, {:ok, meta}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp handle_owner_call(
         {:register_cleanup, _key, _fun},
         _from,
         %{close_state: :closed} = state
       ) do
    {:reply, {:error, :owner_closed}, state}
  end

  defp handle_owner_call(
         {:register_cleanup, _key, _fun},
         _from,
         %{close_state: :closing} = state
       ) do
    {:reply, {:error, :owner_closing}, state}
  end

  defp handle_owner_call({:register_cleanup, key, fun}, _from, state) do
    case do_register_cleanup(state, key, fun) do
      {:ok, cleanups} ->
        {:reply, :ok, %{state | cleanups: Redacted.new(cleanups)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp handle_owner_call({:remove_cleanup, _key}, _from, %{close_state: :closed} = state) do
    {:reply, {:error, :owner_closed}, state}
  end

  defp handle_owner_call({:remove_cleanup, _key}, _from, %{close_state: :closing} = state) do
    {:reply, {:error, :owner_closing}, state}
  end

  defp handle_owner_call({:remove_cleanup, key}, _from, state) do
    cleanups = Redacted.value(state.cleanups)

    if Map.has_key?(cleanups, key) do
      {:reply, :ok, %{state | cleanups: Redacted.new(Map.delete(cleanups, key))}}
    else
      {:reply, {:error, :unknown_cleanup_key}, state}
    end
  end

  defp handle_owner_call(_request, _from, state) do
    {:reply, {:error, :unsupported_request}, state}
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{owner_ref: ref, owner_pid: pid} = state
      ) do
    if state.close_state == :open do
      case begin_close(state) do
        {:ok, next_state} ->
          {:noreply, next_state}

        {:error, _reason, next_state} ->
          {:stop, :normal, next_state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{supervisor_ref: ref, supervisor: pid} = state
      ) do
    {:stop, :normal, %{state | supervisor_ref: nil, close_state: :closed}}
  end

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{cleanup_supervisor_ref: ref, cleanup_supervisor: pid} = state
      ) do
    case state.close_state do
      :open ->
        {:noreply, state}

      _ ->
        {:stop, :normal, stop_after_close(state, :cleanup_unavailable)}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{
          close_coordinator_ref: ref,
          close_coordinator_pid: pid,
          close_state: :closing
        } = state
      ) do
    {:stop, :normal, stop_after_close(state, :cleanup_unavailable)}
  end

  def handle_info(
        {:coordinator_ready, close_ref, coordinator_pid},
        %{
          close_state: :closing,
          close_ref: close_ref,
          close_coordinator_pid: coordinator_pid,
          coordinator_ready: false
        } = state
      ) do
    state =
      state
      |> cancel_timer(:coordinator_ready_ref)
      |> Map.put(:coordinator_ready, true)

    send(self(), :perform_close)

    {:noreply, state}
  end

  def handle_info({:coordinator_ready, _close_ref, _coordinator_pid}, state),
    do: {:noreply, state}

  def handle_info(
        {:coordinator_done, close_ref},
        %{close_state: :closing, close_ref: close_ref} = state
      ) do
    state
    |> Map.put(:cleanups_done, true)
    |> finish_close_if_ready()
  end

  def handle_info(
        {:coordinator_ready_timeout, close_ref},
        %{close_state: :closing, close_ref: close_ref, coordinator_ready: false} = state
      ) do
    {:stop, :normal, stop_after_close(state, :cleanup_unavailable)}
  end

  def handle_info({:coordinator_ready_timeout, _close_ref}, state), do: {:noreply, state}

  def handle_info(
        {:close_deadline_reached, close_ref},
        %{close_state: :closing, close_ref: close_ref} = state
      ) do
    {:stop, :normal, stop_after_close(state, :owner_timeout)}
  end

  def handle_info(:perform_close, %{close_state: :closing} = state) do
    state
    |> close_backend_once()
    |> finish_close_if_ready()
  end

  def handle_info({:coordinator_done, _close_ref, _results}, state), do: {:noreply, state}
  def handle_info({_msg, _}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.close_state != :closed do
      _ = close_backend_once(state)
    end

    :ok
  end

  @impl true
  def format_status(%{state: state} = status) when is_map(state) do
    cleanups = Redacted.value(state.cleanups)

    redacted_state = %{
      owner_pid: state.owner_pid,
      backend_mod: state.backend_mod,
      close_state: state.close_state,
      backend_closed: state.backend_closed,
      close_deadline_ms: state.close_deadline_ms,
      cleanup_count: map_size(cleanups),
      has_session: not is_nil(Redacted.value(state.session)),
      supervisor_alive: alive?(state.supervisor),
      cleanup_supervisor_alive: alive?(state.cleanup_supervisor)
    }

    %{status | state: redacted_state, message: :redacted, log: :redacted}
  end

  def format_status(status), do: status

  # ------------------------------------------------------------------
  # Close orchestration

  defp begin_close(state) do
    if state.close_state != :open do
      {:ok, state}
    else
      close_ref = make_ref()
      close_deadline_ms = now_ms() + state.config[:close_timeout_ms]

      state =
        state
        |> Map.put(:close_state, :closing)
        |> Map.put(:close_ref, close_ref)
        |> Map.put(:close_deadline_ms, close_deadline_ms)
        |> Map.put(:backend_closed, false)
        |> Map.put(:cleanups_done, false)
        |> Map.put(:close_coordinator_pid, nil)
        |> Map.put(:close_coordinator_ref, nil)
        |> Map.put(:coordinator_ready, false)

      if not alive?(state.cleanup_supervisor) do
        {:error, :cleanup_unavailable, close_after_fail(state)}
      else
        case start_cleanup_coordinator(state) do
          {:ok, next_state} ->
            {:ok, next_state}

          {:error, :cleanup_unavailable} ->
            {:error, :cleanup_unavailable, close_after_fail(state)}
        end
      end
    end
  end

  defp close_after_fail(state) do
    state
    |> Map.put(:close_state, :closed)
    |> cancel_timers()
  end

  defp start_cleanup_coordinator(state) do
    close_ref = state.close_ref
    deadline_ms = state.close_deadline_ms
    now = now_ms()
    ready_timeout_ms = max(0, min(state.config[:cleanup_ready_timeout_ms], deadline_ms - now))
    deadline_timeout_ms = max(0, deadline_ms - now)

    if ready_timeout_ms == 0 or deadline_timeout_ms == 0 do
      {:error, :cleanup_unavailable}
    else
      ready_ref =
        Process.send_after(self(), {:coordinator_ready_timeout, close_ref}, ready_timeout_ms)

      deadline_ref =
        Process.send_after(self(), {:close_deadline_reached, close_ref}, deadline_timeout_ms)

      state =
        state
        |> Map.put(:coordinator_ready_ref, ready_ref)
        |> Map.put(:close_deadline_ref, deadline_ref)

      cleanups =
        state.cleanups
        |> Redacted.value()
        |> Map.new(fn {key, fun} -> {key, {fun, state.config[:cleanup_attempts]}} end)

      owner = self()

      coordinator_task_fn = fn ->
        send(owner, {:coordinator_ready, close_ref, self()})

        run_cleanups_in_rounds(
          cleanups,
          state.cleanup_supervisor,
          state.config[:cleanup_per_attempt_timeout_ms],
          deadline_ms
        )

        send(owner, {:coordinator_done, close_ref})

        monitor_ref = Process.monitor(owner)
        remaining_ms = max(0, deadline_ms - now_ms())

        receive do
          {:DOWN, ^monitor_ref, :process, ^owner, _reason} ->
            :ok
        after
          remaining_ms ->
            if Process.alive?(owner), do: Process.exit(owner, :kill)
        end
      end

      case Task.Supervisor.start_child(state.cleanup_supervisor, coordinator_task_fn) do
        {:ok, pid} ->
          {:ok,
           state
           |> Map.put(:close_coordinator_pid, pid)
           |> Map.put(:close_coordinator_ref, Process.monitor(pid))}

        {:error, reason} ->
          log_redacted(:cleanup_unavailable)
          _ = reason
          {:error, :cleanup_unavailable}
      end
    end
  end

  defp stop_after_close(state, close_result) do
    reply = normalize_close_result(close_result)

    Enum.each(state.close_waiters, fn from ->
      safe_reply(from, reply)
    end)

    state
    |> Map.put(:close_waiters, [])
    |> Map.put(:close_state, :closed)
    |> Map.put(:backend_closed, true)
    |> cancel_timers()
  end

  defp finish_close_if_ready(%{backend_closed: true, cleanups_done: true} = state) do
    {:stop, :normal, stop_after_close(state, :ok)}
  end

  defp finish_close_if_ready(state), do: {:noreply, state}

  defp normalize_close_result(:ok), do: :ok
  defp normalize_close_result(result), do: {:error, result}

  defp safe_reply({pid, ref} = from, reply) do
    try do
      GenServer.reply(from, reply)
    catch
      :exit, _ ->
        _ = pid
        _ = ref
        :ok
    end
  end

  defp add_close_waiter(state, from) do
    %{state | close_waiters: [from | state.close_waiters]}
  end

  defp run_cleanups_in_rounds(cleanups, cleanup_supervisor, per_attempt_timeout_ms, deadline_ms) do
    if map_size(cleanups) == 0 do
      :ok
    else
      if now_ms() >= deadline_ms do
        :ok
      else
        next_round =
          run_cleanup_round(cleanups, cleanup_supervisor, per_attempt_timeout_ms, deadline_ms)

        if map_size(next_round) == 0 do
          :ok
        else
          run_cleanups_in_rounds(
            next_round,
            cleanup_supervisor,
            per_attempt_timeout_ms,
            deadline_ms
          )
        end
      end
    end
  end

  defp run_cleanup_round(cleanups, supervisor, per_attempt_timeout_ms, deadline_ms) do
    remaining_ms = max(0, deadline_ms - now_ms())

    if remaining_ms == 0 do
      cleanups
    else
      task_timeout_ms = min(per_attempt_timeout_ms, remaining_ms)

      tasks =
        for {key, {fun, attempts_left}} <- cleanups do
          task =
            Task.Supervisor.async_nolink(supervisor, fn ->
              try do
                # Soft failures must retry: `{:error, _}` is failure. Other
                # normal returns (including `:ok` and incidental values such as
                # `send/2` → pid) remain success for compatibility. raise /
                # throw / exit / timeout still fail via the catch clause.
                case fun.() do
                  {:error, _reason} -> :error
                  _other -> :ok
                end
              catch
                _kind, _reason ->
                  :error
              end
            end)

          {key, fun, attempts_left, task}
        end

      task_refs = Enum.map(tasks, fn {_key, _fun, _attempts_left, task} -> task end)
      yields = Task.yield_many(task_refs, task_timeout_ms)

      Enum.zip(tasks, yields)
      |> Enum.reduce(%{}, fn
        {{key, fun, attempts_left, task}, {_task, result}}, acc ->
          case result do
            {:ok, :ok} ->
              acc

            {:ok, :error} ->
              attempt_cleanup_retry(acc, key, fun, attempts_left)

            nil ->
              Task.shutdown(task, :brutal_kill)
              attempt_cleanup_retry(acc, key, fun, attempts_left)

            {:exit, _reason} ->
              attempt_cleanup_retry(acc, key, fun, attempts_left)

            {:ok, _other} ->
              attempt_cleanup_retry(acc, key, fun, attempts_left)

            _ ->
              attempt_cleanup_retry(acc, key, fun, attempts_left)
          end
      end)
    end
  end

  defp attempt_cleanup_retry(acc, _key, _fun, attempts_left) when attempts_left <= 1 do
    log_redacted(:cleanup_retry_exhausted)
    acc
  end

  defp attempt_cleanup_retry(acc, key, fun, attempts_left) do
    Map.put(acc, key, {fun, attempts_left - 1})
  end

  defp close_backend_once(state) do
    if state.backend_closed do
      state
    else
      session = Redacted.value(state.session)
      backend_mod = state.backend_mod

      try do
        backend_mod.close(session)
      catch
        _kind, _reason ->
          :ok
      end

      %{state | backend_closed: true}
    end
  end

  # ------------------------------------------------------------------
  # Backend callback validation and execution

  defp open_backend(state) do
    backend_mod = state.backend_mod
    backend_opts = Redacted.value(state.backend_opts)

    try do
      case backend_mod.open(backend_opts) do
        {:ok, session} ->
          {:ok, session}

        {:error, _reason} ->
          {:error, :backend_open_failed}

        _other ->
          {:error, :backend_open_failed}
      end
    catch
      _kind, _reason ->
        log_redacted(:open_error)
        {:error, :backend_open_failed}
    end
  end

  defp execute_backend_callback(operation, args, state) do
    with {:ok, validated_args} <-
           validate_backend_args(operation, args, state.config[:max_recv_timeout_ms]) do
      session = Redacted.value(state.session)

      try do
        state.backend_mod
        |> apply(operation, [session | validated_args])
        |> validate_backend_result(operation, state)
      catch
        _kind, _reason ->
          log_redacted(:backend_callback_error)
          {:error, :backend_callback_failed}
      end
    end
  end

  defp validate_backend_result({:ok, new_session}, operation, state)
       when operation in [:configure, :send_text, :send_audio, :send_tool_result] do
    {:ok, %{state | session: Redacted.new(new_session)}}
  end

  defp validate_backend_result({:ok, new_session, event}, :recv, state) do
    {:ok, %{state | session: Redacted.new(new_session)}, event}
  end

  # Preserve only a backend recv timeout so Session can continue finite
  # polling. Every other returned backend reason stays redacted.
  defp validate_backend_result({:error, :timeout}, :recv, _state),
    do: {:error, :timeout}

  defp validate_backend_result({:error, _reason}, _operation, _state),
    do: {:error, :backend_callback_failed}

  defp validate_backend_result(_result, _operation, _state),
    do: {:error, :backend_callback_failed}

  defp validate_backend_args(:recv, [timeout], max_recv_timeout_ms)
       when is_integer(timeout) and is_integer(max_recv_timeout_ms) and max_recv_timeout_ms > 0 do
    if timeout >= 0 and timeout <= max_recv_timeout_ms do
      {:ok, [timeout]}
    else
      {:error, :invalid_timeout}
    end
  end

  defp validate_backend_args(:recv, [_timeout], _max_recv_timeout_ms),
    do: {:error, :invalid_timeout}

  defp validate_backend_args(:configure, [config], _max_recv_timeout_ms) when is_map(config),
    do: {:ok, [config]}

  defp validate_backend_args(:send_text, [text], _max_recv_timeout_ms) when is_binary(text),
    do: {:ok, [text]}

  defp validate_backend_args(:send_audio, [chunk], _max_recv_timeout_ms) when is_binary(chunk),
    do: {:ok, [chunk]}

  defp validate_backend_args(:send_tool_result, [call_id, output], _max_recv_timeout_ms)
       when is_binary(call_id) and is_binary(output),
       do: {:ok, [call_id, output]}

  defp validate_backend_args(_operation, _args, _max_recv_timeout_ms),
    do: {:error, :backend_callback_failed}

  defp safe_meta(_backend_mod, nil), do: {:error, :owner_unavailable}

  defp safe_meta(backend_mod, session) do
    try do
      meta = backend_mod.meta(session)

      if is_map(meta) and valid_meta?(meta) do
        {:ok, meta}
      else
        {:error, :invalid_backend_meta}
      end
    catch
      _kind, _reason ->
        log_redacted(:meta_error)
        {:error, :backend_callback_failed}
    end
  end

  defp valid_meta?(
         %{
           backend: backend,
           mode: mode,
           input_rate: input_rate,
           output_rate: output_rate
         } = meta
       ) do
    keys = Map.keys(meta) |> MapSet.new()
    required = MapSet.new([:backend, :mode, :input_rate, :output_rate])

    is_atom(backend) and
      mode in [:cloud, :local] and
      (is_nil(input_rate) or (is_integer(input_rate) and input_rate > 0)) and
      (is_nil(output_rate) or (is_integer(output_rate) and output_rate > 0)) and
      MapSet.equal?(keys, required)
  end

  defp valid_meta?(_meta), do: false

  defp do_register_cleanup(state, key, fun) do
    if not is_function(fun, 0) do
      {:error, :invalid_cleanup}
    else
      cleanups = Redacted.value(state.cleanups)
      max_cleanups = state.config[:max_cleanups]

      cond do
        map_size(cleanups) >= max_cleanups ->
          {:error, :cleanup_capacity_exceeded}

        Map.has_key?(cleanups, key) ->
          {:error, :duplicate_cleanup_key}

        true ->
          {:ok, Map.put(cleanups, key, fun)}
      end
    end
  end

  # ------------------------------------------------------------------
  # Validation and helpers

  defp validate_opts(opts) when is_list(opts) do
    with :ok <- validate_owner_opts_syntax(opts) do
      owner_opts =
        opts
        |> Keyword.delete(:supervisor)
        |> Keyword.delete(:cleanup_supervisor)

      config =
        @defaults
        |> Keyword.merge(owner_opts)
        |> Map.new()

      with :ok <- validate_pos_int(config[:close_timeout_ms], :close_timeout_ms),
           :ok <- validate_pos_int(config[:cleanup_ready_timeout_ms], :cleanup_ready_timeout_ms),
           :ok <- validate_pos_int(config[:cleanup_attempts], :cleanup_attempts),
           :ok <-
             validate_pos_int(
               config[:cleanup_per_attempt_timeout_ms],
               :cleanup_per_attempt_timeout_ms
             ),
           :ok <- validate_pos_int(config[:max_recv_timeout_ms], :max_recv_timeout_ms),
           :ok <- validate_pos_int(config[:max_cleanups], :max_cleanups),
           true <- config[:max_recv_timeout_ms] <= @max_recv_timeout_ms,
           true <- config[:max_cleanups] <= @max_cleanups,
           true <- config[:close_timeout_ms] <= @max_close_timeout_ms,
           true <- config[:cleanup_attempts] <= @max_cleanup_attempts,
           true <- config[:cleanup_per_attempt_timeout_ms] <= @max_cleanup_per_attempt_timeout_ms do
        {:ok, config}
      else
        false ->
          {:error, :invalid_owner_config}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp validate_opts(_opts), do: {:error, :invalid_owner_config}

  defp validate_owner_opts_syntax(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)

      cond do
        Enum.any?(keys, &(&1 not in @allowed_owner_opts)) ->
          {:error, :invalid_owner_config}

        length(keys) != length(Enum.uniq(keys)) ->
          {:error, :invalid_owner_config}

        true ->
          :ok
      end
    else
      {:error, :invalid_owner_config}
    end
  end

  defp validate_backend_opts(backend_opts) when is_list(backend_opts) do
    if Keyword.keyword?(backend_opts) and
         length(Keyword.keys(backend_opts)) == length(Enum.uniq(Keyword.keys(backend_opts))) do
      :ok
    else
      {:error, {:invalid_owner_config, :backend_opts}}
    end
  end

  defp validate_backend_opts(_backend_opts), do: {:error, {:invalid_owner_config, :backend_opts}}

  defp validate_pos_int(value, _key) when is_integer(value) and value > 0, do: :ok
  defp validate_pos_int(_value, key), do: {:error, {:invalid_owner_config, key}}

  defp resolve_supervisor(name) when is_atom(name) do
    case Process.whereis(name) do
      nil -> {:error, :supervisor_unavailable}
      pid when is_pid(pid) -> {:ok, pid}
      _ -> {:error, :supervisor_unavailable}
    end
  end

  defp resolve_supervisor(pid) when is_pid(pid), do: {:ok, pid}
  defp resolve_supervisor(_), do: {:error, :supervisor_unavailable}

  defp resolve_cleanup_supervisor(name) when is_atom(name) do
    case Process.whereis(name) do
      nil -> {:error, :cleanup_unavailable}
      pid when is_pid(pid) -> {:ok, pid}
      _ -> {:error, :cleanup_unavailable}
    end
  end

  defp resolve_cleanup_supervisor(pid) when is_pid(pid), do: {:ok, pid}
  defp resolve_cleanup_supervisor(_), do: {:error, :cleanup_unavailable}

  defp validate_backend_module(module) do
    callbacks = Arbor.Voice.RealtimeBackend.behaviour_info(:callbacks)

    try do
      exports = module.module_info(:exports)

      if Enum.all?(callbacks, &(&1 in exports)) do
        :ok
      else
        {:error, :invalid_backend}
      end
    catch
      _kind, _reason -> {:error, :invalid_backend}
    end
  end

  defp normalize_supervisor_error({:already_started, _pid}), do: :owner_already_started
  defp normalize_supervisor_error(:max_children), do: :supervisor_capacity_exceeded
  defp normalize_supervisor_error(:backend_open_failed), do: :backend_open_failed
  defp normalize_supervisor_error(:cleanup_unavailable), do: :cleanup_unavailable
  defp normalize_supervisor_error(_), do: :supervisor_unavailable

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp alive?(_), do: false

  defp cancel_timer(state, key) do
    ref = Map.get(state, key)

    if is_reference(ref) do
      _ = Process.cancel_timer(ref)
    end

    Map.put(state, key, nil)
  end

  defp cancel_timers(state) do
    state
    |> cancel_timer(:coordinator_ready_ref)
    |> cancel_timer(:close_deadline_ref)
  end

  defp log_redacted(tag) do
    require Logger

    Logger.warning("Arbor.Voice.ResourceOwner: callback failure", tag: tag, reason: :redacted)
  end
end
