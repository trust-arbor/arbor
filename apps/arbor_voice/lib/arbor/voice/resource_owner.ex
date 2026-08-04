defmodule Arbor.Voice.ResourceOwner do
  @moduledoc """
  Supervised temporary owner of a realtime backend session and session-scoped
  cleanup obligations.

  The owner owns the backend session handle and executes all backend callbacks
  in its own process. Close callers have a bounded wait, while unresolved
  backend and authority cleanup remains owned and is retried in the background.
  """

  use GenServer

  alias Arbor.Identifiers
  alias Arbor.Voice.EgressAuthority
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
  @retry_base_ms 50
  @retry_max_ms 2_000
  @provisional_cleanup_tag :voice_provisional_cleanup

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
  @spec close_call_timeout_ms() :: pos_integer()
  def close_call_timeout_ms, do: @call_timeout_ms

  @doc false
  def start(owner_pid, backend_module, backend_opts \\ [], opts \\ [])

  def start(owner_pid, backend_module, backend_opts, opts)
      when is_pid(owner_pid) and is_atom(backend_module) do
    # Compatibility is deliberately local-only. External backends must use
    # start/5 with authenticated route authority; there is no allow default.
    handoff = %{
      authority: %{
        kind: :local,
        route: :none,
        session_id: Identifiers.generate_session_id()
      },
      initial_cleanup: nil
    }

    start(owner_pid, backend_module, backend_opts, handoff, opts)
  end

  def start(_owner_pid, _backend_module, _backend_opts, _opts),
    do: {:error, :invalid_owner_config}

  @doc false
  @spec start(pid(), module(), keyword(), map(), keyword()) ::
          {:ok, pid()} | {:error, atom() | tuple()}
  def start(owner_pid, backend_module, backend_opts, handoff, opts)
      when is_pid(owner_pid) and is_atom(backend_module) and is_map(handoff) do
    if owner_pid != self() do
      {:error, :foreign_caller}
    else
      with :ok <- validate_backend_opts(backend_opts),
           :ok <- validate_handoff(handoff),
           {:ok, config} <- validate_opts(opts),
           supervisor_opt <- Keyword.get(opts, :supervisor, @supervisor),
           cleanup_supervisor_opt <-
             Keyword.get(opts, :cleanup_supervisor, @cleanup_supervisor),
           {:ok, supervisor} <- resolve_supervisor(supervisor_opt),
           {:ok, cleanup_supervisor} <-
             resolve_cleanup_supervisor(cleanup_supervisor_opt),
           :ok <- validate_backend_module(backend_module),
           :ok <- validate_backend_handoff(backend_module, handoff) do
        spec = %{
          id: make_ref(),
          start:
            {__MODULE__, :start_link,
             [
               owner_pid,
               backend_module,
               Redacted.new(backend_opts),
               Redacted.new(handoff),
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

  def start(_owner_pid, _backend_module, _backend_opts, _handoff, _opts),
    do: {:error, :invalid_owner_config}

  @doc false
  def start_link(
        owner_pid,
        backend_module,
        backend_opts,
        handoff,
        config,
        supervisor,
        cleanup_supervisor
      )
      when is_pid(owner_pid) and is_atom(backend_module) and is_map(config) and is_pid(supervisor) and
             is_pid(cleanup_supervisor) do
    GenServer.start_link(
      __MODULE__,
      {owner_pid, backend_module, backend_opts, handoff, config, supervisor, cleanup_supervisor}
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

  @doc false
  @spec adopt_provisional_cleanup(GenServer.server(), term(), fun()) ::
          :ok | {:error, atom()}
  def adopt_provisional_cleanup(owner, key, fun),
    do: call(owner, {:adopt_provisional_cleanup, key, fun})

  @spec remove_cleanup(GenServer.server(), term()) :: :ok | {:error, atom()}
  def remove_cleanup(owner, key), do: call(owner, {:remove_cleanup, key})

  @spec activate_turn(GenServer.server(), map()) :: :ok | {:error, atom()}
  def activate_turn(owner, lease), do: call(owner, {:activate_turn, lease})

  @spec fence_and_drain(GenServer.server(), :session | String.t()) ::
          :ok | {:error, atom()}
  def fence_and_drain(owner, scope), do: call(owner, {:fence_and_drain, scope})

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
  def init(
        {owner_pid, backend_module, backend_opts, handoff, config, supervisor, cleanup_supervisor}
      ) do
    Process.flag(:trap_exit, true)

    if not is_pid(supervisor) or not is_pid(cleanup_supervisor) do
      {:stop, :invalid_supervisor}
    else
      if not Process.alive?(supervisor) do
        {:stop, :supervisor_unavailable}
      else
        if not Process.alive?(cleanup_supervisor) do
          {:stop, :cleanup_unavailable}
        else
          handoff = Redacted.value(handoff)

          case EgressAuthority.new_private_cell(handoff.authority) do
            {:ok, authority_cell} ->
              authorizer = EgressAuthority.effect_authorizer(authority_cell)

              backend_opts =
                backend_opts
                |> Redacted.value()
                |> Keyword.put(:effect_authorizer, authorizer)
                |> Redacted.new()

              state = %{
                owner_pid: owner_pid,
                owner_ref: Process.monitor(owner_pid),
                backend_mod: backend_module,
                backend_opts: backend_opts,
                session: Redacted.new(nil),
                authority_cell: Redacted.new(authority_cell),
                poisoned: false,
                config: config,
                supervisor: supervisor,
                supervisor_ref: Process.monitor(supervisor),
                cleanup_supervisor: cleanup_supervisor,
                cleanup_supervisor_ref: Process.monitor(cleanup_supervisor),
                close_state: :open,
                close_deadline_ms: nil,
                close_deadline_ref: nil,
                close_deadline_token: nil,
                close_deadline_expired: false,
                backend_closed: false,
                backend_close_attempt: nil,
                cleanup_attempt: nil,
                retry_ref: nil,
                retry_token: nil,
                retry_delay_ms: @retry_base_ms,
                cleanups: Redacted.new(initial_cleanups(handoff)),
                close_waiters: []
              }

              case open_backend(state) do
                {:ok, session} ->
                  {:ok, %{state | session: Redacted.new(session)}}

                {:error, reason} ->
                  # init/1 failure does not guarantee terminate/2. Execute the
                  # already-handed-off route cleanup before reporting failure;
                  # Session still retains idempotent fallback until start/5
                  # confirms success.
                  _ = run_open_failure_cleanups(state)
                  {:stop, reason}
              end

            {:error, _reason} ->
              {:stop, :invalid_authority}
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

  defp handle_owner_call(
         :close,
         _from,
         %{close_state: :closing, close_deadline_expired: true} = state
       ) do
    {:reply, {:error, :owner_timeout}, state}
  end

  defp handle_owner_call(:close, from, %{close_state: :closing} = state) do
    state = state |> add_close_waiter(from) |> ensure_caller_deadline()
    {:noreply, state}
  end

  defp handle_owner_call(:close, from, state) do
    state = state |> begin_close() |> add_close_waiter(from) |> ensure_caller_deadline()
    {:noreply, state}
  end

  defp handle_owner_call({:activate_turn, _lease}, _from, %{close_state: state} = owner)
       when state in [:closing, :closed] do
    {:reply, {:error, :owner_closing}, owner}
  end

  defp handle_owner_call({:activate_turn, _lease}, _from, %{poisoned: true} = state) do
    {:reply, {:error, :owner_poisoned}, state}
  end

  defp handle_owner_call({:activate_turn, lease}, _from, state) when is_map(lease) do
    cleanups = Redacted.value(state.cleanups)
    cleanup_registered? = Map.has_key?(cleanups, Map.get(lease, :cleanup_key))
    cell = Redacted.value(state.authority_cell)

    case EgressAuthority.activate_turn(cell, lease, cleanup_registered?) do
      :ok -> {:reply, :ok, state}
      {:error, _reason} -> {:reply, {:error, :turn_activation_denied}, state}
    end
  end

  defp handle_owner_call({:activate_turn, _lease}, _from, state) do
    {:reply, {:error, :turn_activation_denied}, state}
  end

  defp handle_owner_call({:fence_and_drain, scope}, _from, state) do
    cell = Redacted.value(state.authority_cell)

    case EgressAuthority.fence_and_drain(cell, scope) do
      :ok -> {:reply, :ok, state}
      {:error, :owner_poisoned} -> {:reply, {:error, :owner_poisoned}, %{state | poisoned: true}}
      {:error, _reason} -> {:reply, {:error, :fence_failed}, state}
    end
  end

  defp handle_owner_call({:backend, _operation, _args}, _from, %{close_state: :closed} = state) do
    {:reply, {:error, :owner_closed}, state}
  end

  defp handle_owner_call({:backend, _operation, _args}, _from, %{close_state: :closing} = state) do
    {:reply, {:error, :owner_closing}, state}
  end

  defp handle_owner_call({:backend, _operation, _args}, _from, %{poisoned: true} = state) do
    {:reply, {:error, :owner_poisoned}, state}
  end

  defp handle_owner_call({:backend, operation, args}, _from, state) do
    case execute_backend_callback(operation, args, state) do
      {:ok, next_state} ->
        {:reply, :ok, next_state}

      {:ok, next_state, event} ->
        {:reply, {:ok, event}, next_state}

      {:error, reason, next_state} ->
        {:reply, {:error, reason}, next_state}

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

  defp handle_owner_call(
         {:adopt_provisional_cleanup, _key, _fun},
         _from,
         %{close_state: state} = owner
       )
       when state in [:closing, :closed] do
    {:reply, {:error, :owner_closing}, owner}
  end

  defp handle_owner_call({:adopt_provisional_cleanup, key, fun}, _from, state) do
    case do_adopt_provisional_cleanup(state, key, fun) do
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
  def handle_info({:EXIT, supervisor, reason}, %{supervisor: supervisor} = state) do
    {:stop, reason, state}
  end

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{owner_ref: ref, owner_pid: pid} = state
      ) do
    state = %{state | owner_ref: nil}
    state = if state.close_state == :open, do: begin_close(state), else: state
    continue_close(state)
  end

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{supervisor_ref: ref, supervisor: pid} = state
      ) do
    state = %{state | supervisor_ref: nil}
    state = if state.close_state == :open, do: begin_close(state), else: state
    continue_close(state)
  end

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{cleanup_supervisor_ref: ref, cleanup_supervisor: pid} = state
      ) do
    state = %{state | cleanup_supervisor_ref: nil}

    state =
      if state.close_state == :closing and is_nil(state.cleanup_attempt),
        do: schedule_retry(state),
        else: state

    continue_close(state)
  end

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{cleanup_attempt: %{monitor_ref: ref, pid: pid}} = state
      ) do
    state =
      state
      |> cancel_attempt_timer(:cleanup_attempt, :ready_timer_ref)
      |> cancel_attempt_timer(:cleanup_attempt, :timeout_timer_ref)

    case state.cleanup_attempt.child do
      nil ->
        state
        |> Map.put(:cleanup_attempt, nil)
        |> maybe_schedule_pending_retry()
        |> continue_close()

      %{pid: child_pid} ->
        if Process.alive?(child_pid), do: Process.exit(child_pid, :kill)

        attempt = %{state.cleanup_attempt | status: :awaiting_child_down}
        {:noreply, %{state | cleanup_attempt: attempt}}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{
          cleanup_attempt: %{
            generation: generation,
            pid: coordinator,
            child: %{monitor_ref: ref, pid: pid}
          }
        } = state
      ) do
    if state.cleanup_attempt.status == :awaiting_child_down do
      state
      |> Map.put(:cleanup_attempt, nil)
      |> maybe_schedule_pending_retry()
      |> continue_close()
    else
      send(coordinator, {:cleanup_child_cleared, generation, pid})
      attempt = %{state.cleanup_attempt | child: nil}
      {:noreply, %{state | cleanup_attempt: attempt}}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{backend_close_attempt: %{monitor_ref: ref, pid: pid}} = state
      ) do
    state =
      state
      |> cancel_attempt_timer(:backend_close_attempt, :ready_timer_ref)
      |> cancel_attempt_timer(:backend_close_attempt, :timeout_timer_ref)
      |> Map.put(:backend_close_attempt, nil)
      |> maybe_schedule_pending_retry()

    continue_close(state)
  end

  def handle_info(
        {:cleanup_ready, generation, pid},
        %{
          cleanup_attempt: %{
            generation: generation,
            pid: pid,
            status: :starting
          }
        } = state
      ) do
    attempt =
      state.cleanup_attempt
      |> cancel_timer_in_map(:ready_timer_ref)
      |> Map.put(:status, :ready)

    {:noreply, %{state | cleanup_attempt: attempt}}
  end

  def handle_info(
        {:cleanup_child_started, generation, coordinator, child},
        %{
          cleanup_attempt: %{
            generation: generation,
            pid: coordinator,
            child: nil,
            status: status
          }
        } = state
      )
      when is_pid(child) and status in [:starting, :ready] do
    monitor_ref = Process.monitor(child)
    send(coordinator, {:cleanup_child_registered, generation, child})

    attempt = %{state.cleanup_attempt | child: %{pid: child, monitor_ref: monitor_ref}}
    {:noreply, %{state | cleanup_attempt: attempt}}
  end

  def handle_info(
        {:cleanup_result, generation, pid, successful_keys},
        %{
          cleanup_attempt: %{
            generation: generation,
            pid: pid,
            status: status,
            keys: attempted_keys
          }
        } = state
      ) do
    if status in [:ready, :starting] and valid_successful_keys?(successful_keys, attempted_keys) do
      cleanups = Redacted.value(state.cleanups)
      remaining = Map.drop(cleanups, successful_keys)
      progress? = map_size(remaining) < map_size(cleanups)

      attempt = %{state.cleanup_attempt | status: :result_received}

      attempt = cancel_timer_in_map(attempt, :timeout_timer_ref)

      state =
        state
        |> Map.put(:cleanups, Redacted.new(remaining))
        |> Map.put(:cleanup_attempt, attempt)
        |> maybe_reset_retry_delay(progress?)

      continue_close(state)
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:cleanup_ready_timeout, generation, pid},
        %{
          cleanup_attempt: %{
            generation: generation,
            pid: pid,
            status: :starting
          }
        } = state
      ) do
    Process.exit(pid, :kill)
    attempt = %{state.cleanup_attempt | status: :canceling, ready_timer_ref: nil}
    {:noreply, %{state | cleanup_attempt: attempt}}
  end

  def handle_info(
        {:cleanup_attempt_timeout, generation, pid},
        %{
          cleanup_attempt: %{
            generation: generation,
            pid: pid,
            status: status
          }
        } = state
      )
      when status in [:starting, :ready] do
    Process.exit(pid, :kill)

    attempt = %{
      state.cleanup_attempt
      | status: :canceling,
        ready_timer_ref: cancel_timer_ref(state.cleanup_attempt.ready_timer_ref),
        timeout_timer_ref: nil
    }

    {:noreply, %{state | cleanup_attempt: attempt}}
  end

  def handle_info(
        {:backend_close_ready, generation, pid},
        %{
          backend_close_attempt: %{
            generation: generation,
            pid: pid,
            status: :starting
          }
        } = state
      ) do
    attempt = %{state.backend_close_attempt | status: :ready}
    {:noreply, %{state | backend_close_attempt: attempt}}
  end

  def handle_info(
        {:backend_close_result, generation, pid, result},
        %{
          backend_close_attempt: %{
            generation: generation,
            pid: pid,
            status: status
          }
        } = state
      ) do
    if status in [:ready, :starting] and result in [:ok, :error] do
      attempt =
        state.backend_close_attempt
        |> cancel_timer_in_map(:timeout_timer_ref)
        |> Map.put(:status, :result_received)

      state = %{
        state
        | backend_close_attempt: attempt,
          backend_closed: result == :ok,
          retry_delay_ms: if(result == :ok, do: @retry_base_ms, else: state.retry_delay_ms)
      }

      continue_close(state)
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:backend_close_timeout, generation, pid},
        %{
          backend_close_attempt: %{
            generation: generation,
            pid: pid,
            status: status
          }
        } = state
      )
      when status in [:starting, :ready] do
    Process.exit(pid, :kill)
    attempt = %{state.backend_close_attempt | status: :canceling, timeout_timer_ref: nil}
    {:noreply, %{state | backend_close_attempt: attempt}}
  end

  def handle_info(
        {:close_deadline_reached, token},
        %{close_deadline_token: token, close_state: :closing} = state
      ) do
    Enum.each(state.close_waiters, &safe_reply(&1, {:error, :owner_timeout}))

    state = %{
      state
      | close_waiters: [],
        close_deadline_ms: nil,
        close_deadline_ref: nil,
        close_deadline_token: nil,
        close_deadline_expired: true
    }

    {:noreply, state}
  end

  def handle_info({:retry_close, token}, %{retry_token: token, close_state: :closing} = state) do
    state = %{state | retry_ref: nil, retry_token: nil}
    state = start_pending_attempts(state)
    continue_close(state)
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_attempt(state.cleanup_attempt)
    stop_attempt(state.backend_close_attempt)

    deadline_ms = now_ms() + @shutdown_grace_ms

    unless state.backend_closed do
      _ = invoke_backend_close_bounded(state, max(0, deadline_ms - now_ms()))
    end

    state.cleanups
    |> Redacted.value()
    |> Enum.each(fn {_key, cleanup} ->
      _ = invoke_cleanup_bounded(cleanup, max(0, deadline_ms - now_ms()))
    end)

    :ok
  end

  @impl true
  def format_status(%{state: state} = status) when is_map(state) do
    cleanups = Redacted.value(state.cleanups)

    redacted_state = %{
      owner_pid: state.owner_pid,
      backend_mod: state.backend_mod,
      close_state: state.close_state,
      poisoned: state.poisoned,
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
    _ =
      state.authority_cell
      |> Redacted.value()
      |> EgressAuthority.fence_and_drain(:session)

    state
    |> Map.put(:close_state, :closing)
    |> start_pending_attempts()
  end

  defp ensure_caller_deadline(%{close_deadline_ref: ref} = state) when is_reference(ref),
    do: state

  defp ensure_caller_deadline(%{close_deadline_expired: true} = state), do: state

  defp ensure_caller_deadline(state) do
    token = make_ref()
    timeout_ms = state.config[:close_timeout_ms]
    timer_ref = Process.send_after(self(), {:close_deadline_reached, token}, timeout_ms)

    %{
      state
      | close_deadline_ms: now_ms() + timeout_ms,
        close_deadline_ref: timer_ref,
        close_deadline_token: token
    }
  end

  defp start_pending_attempts(%{close_state: :closing} = state) do
    state
    |> maybe_start_backend_close_attempt()
    |> maybe_start_cleanup_attempt()
  end

  defp start_pending_attempts(state), do: state

  defp maybe_start_backend_close_attempt(
         %{backend_closed: false, backend_close_attempt: nil} = state
       ) do
    generation = make_ref()
    owner = self()
    backend = state.backend_mod
    session = Redacted.value(state.session)

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        send(owner, {:backend_close_ready, generation, self()})

        result =
          try do
            if backend.close(session) == :ok, do: :ok, else: :error
          catch
            _kind, _reason -> :error
          end

        send(owner, {:backend_close_result, generation, self(), result})
      end)

    timeout_timer_ref =
      Process.send_after(
        self(),
        {:backend_close_timeout, generation, pid},
        state.config[:close_timeout_ms]
      )

    attempt = %{
      generation: generation,
      pid: pid,
      monitor_ref: monitor_ref,
      status: :starting,
      timeout_timer_ref: timeout_timer_ref
    }

    %{state | backend_close_attempt: attempt}
  end

  defp maybe_start_backend_close_attempt(state), do: state

  defp maybe_start_cleanup_attempt(%{cleanup_attempt: nil} = state) do
    cleanups = Redacted.value(state.cleanups)

    if map_size(cleanups) == 0 do
      state
    else
      generation = make_ref()
      owner = self()
      keys = Map.keys(cleanups)
      attempts = state.config[:cleanup_attempts]
      per_attempt_timeout_ms = state.config[:cleanup_per_attempt_timeout_ms]
      attempt_deadline_ms = now_ms() + state.config[:close_timeout_ms]

      coordinator = fn ->
        send(owner, {:cleanup_ready, generation, self()})

        invoke = fn fun, timeout_ms ->
          invoke_cleanup_bounded(fun, timeout_ms, owner, generation)
        end

        unresolved =
          cleanups
          |> Map.new(fn {key, fun} -> {key, {fun, attempts}} end)
          |> run_cleanups_without_supervisor(per_attempt_timeout_ms, attempt_deadline_ms, invoke)

        successful_keys = keys -- Map.keys(unresolved)
        send(owner, {:cleanup_result, generation, self(), successful_keys})
      end

      {pid, kind} = start_cleanup_worker(state.cleanup_supervisor, coordinator)
      monitor_ref = Process.monitor(pid)

      ready_timer_ref =
        Process.send_after(
          self(),
          {:cleanup_ready_timeout, generation, pid},
          state.config[:cleanup_ready_timeout_ms]
        )

      timeout_timer_ref =
        Process.send_after(
          self(),
          {:cleanup_attempt_timeout, generation, pid},
          state.config[:close_timeout_ms]
        )

      attempt = %{
        generation: generation,
        pid: pid,
        monitor_ref: monitor_ref,
        kind: kind,
        keys: MapSet.new(keys),
        status: :starting,
        child: nil,
        ready_timer_ref: ready_timer_ref,
        timeout_timer_ref: timeout_timer_ref
      }

      %{state | cleanup_attempt: attempt}
    end
  end

  defp maybe_start_cleanup_attempt(state), do: state

  defp start_cleanup_worker(supervisor, coordinator) do
    if alive?(supervisor) do
      try do
        case Task.Supervisor.start_child(supervisor, coordinator) do
          {:ok, pid} -> {pid, :supervised}
          _ -> {spawn(coordinator), :fallback}
        end
      catch
        _kind, _reason -> {spawn(coordinator), :fallback}
      end
    else
      {spawn(coordinator), :fallback}
    end
  end

  defp continue_close(state) do
    if close_complete?(state) do
      Enum.each(state.close_waiters, &safe_reply(&1, :ok))

      state =
        state
        |> Map.put(:close_waiters, [])
        |> Map.put(:close_state, :closed)
        |> cancel_close_timers()

      {:stop, :normal, state}
    else
      {:noreply, maybe_schedule_pending_retry(state)}
    end
  end

  defp close_complete?(state) do
    state.backend_closed and
      map_size(Redacted.value(state.cleanups)) == 0 and
      is_nil(state.backend_close_attempt) and
      is_nil(state.cleanup_attempt)
  end

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

  defp valid_successful_keys?(successful_keys, attempted_keys)
       when is_list(successful_keys) and is_struct(attempted_keys, MapSet) do
    length(successful_keys) == length(Enum.uniq(successful_keys)) and
      Enum.all?(successful_keys, &MapSet.member?(attempted_keys, &1))
  end

  defp valid_successful_keys?(_successful_keys, _attempted_keys), do: false

  defp maybe_reset_retry_delay(state, true), do: %{state | retry_delay_ms: @retry_base_ms}
  defp maybe_reset_retry_delay(state, false), do: state

  defp maybe_schedule_pending_retry(%{close_state: :closing} = state) do
    pending_backend? = not state.backend_closed and is_nil(state.backend_close_attempt)

    pending_cleanups? =
      map_size(Redacted.value(state.cleanups)) > 0 and is_nil(state.cleanup_attempt)

    if (pending_backend? or pending_cleanups?) and is_nil(state.retry_ref) do
      schedule_retry(state)
    else
      state
    end
  end

  defp maybe_schedule_pending_retry(state), do: state

  defp schedule_retry(%{retry_ref: ref} = state) when is_reference(ref), do: state

  defp schedule_retry(state) do
    token = make_ref()
    delay_ms = state.retry_delay_ms
    timer_ref = Process.send_after(self(), {:retry_close, token}, delay_ms)

    %{
      state
      | retry_ref: timer_ref,
        retry_token: token,
        retry_delay_ms: min(delay_ms * 2, @retry_max_ms)
    }
  end

  defp cancel_attempt_timer(state, attempt_key, timer_key) do
    case Map.get(state, attempt_key) do
      nil -> state
      attempt -> Map.put(state, attempt_key, cancel_timer_in_map(attempt, timer_key))
    end
  end

  defp cancel_timer_in_map(map, key) do
    Map.put(map, key, cancel_timer_ref(Map.get(map, key)))
  end

  defp cancel_timer_ref(ref) when is_reference(ref) do
    _ = Process.cancel_timer(ref)
    nil
  end

  defp cancel_timer_ref(_ref), do: nil

  defp cancel_close_timers(state) do
    _ = cancel_timer_ref(state.close_deadline_ref)
    _ = cancel_timer_ref(state.retry_ref)

    %{
      state
      | close_deadline_ms: nil,
        close_deadline_ref: nil,
        close_deadline_token: nil,
        retry_ref: nil,
        retry_token: nil
    }
  end

  defp stop_attempt(nil), do: :ok

  defp stop_attempt(%{pid: pid, monitor_ref: monitor_ref} = attempt) do
    stop_cleanup_child(Map.get(attempt, :child))

    if Process.alive?(pid), do: Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    after
      100 ->
        Process.demonitor(monitor_ref, [:flush])
        :ok
    end
  end

  defp stop_cleanup_child(nil), do: :ok

  defp stop_cleanup_child(%{pid: pid, monitor_ref: monitor_ref}) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    after
      100 ->
        Process.demonitor(monitor_ref, [:flush])
        :ok
    end
  end

  defp attempt_cleanup_retry(acc, key, fun, attempts_left) when attempts_left <= 1 do
    log_redacted(:cleanup_retry_exhausted)
    Map.put(acc, key, {fun, 0})
  end

  defp attempt_cleanup_retry(acc, key, fun, attempts_left) do
    Map.put(acc, key, {fun, attempts_left - 1})
  end

  defp no_cleanup_attempts_left?(cleanups) do
    Enum.all?(cleanups, fn {_key, {_fun, attempts_left}} -> attempts_left <= 0 end)
  end

  defp run_cleanups_without_supervisor(cleanups, per_attempt_timeout_ms, deadline_ms) do
    run_cleanups_without_supervisor(
      cleanups,
      per_attempt_timeout_ms,
      deadline_ms,
      &invoke_cleanup_bounded/2
    )
  end

  defp run_cleanups_without_supervisor(
         cleanups,
         per_attempt_timeout_ms,
         deadline_ms,
         invoke
       ) do
    cond do
      map_size(cleanups) == 0 ->
        %{}

      now_ms() >= deadline_ms or no_cleanup_attempts_left?(cleanups) ->
        cleanups

      true ->
        next_round =
          Enum.reduce(cleanups, %{}, fn
            {key, {fun, attempts_left}}, acc when attempts_left > 0 ->
              timeout_ms = min(per_attempt_timeout_ms, max(0, deadline_ms - now_ms()))

              case invoke.(fun, timeout_ms) do
                :ok -> acc
                :error -> attempt_cleanup_retry(acc, key, fun, attempts_left)
              end

            {key, {fun, attempts_left}}, acc ->
              Map.put(acc, key, {fun, attempts_left})
          end)

        run_cleanups_without_supervisor(
          next_round,
          per_attempt_timeout_ms,
          deadline_ms,
          invoke
        )
    end
  end

  defp invoke_cleanup_bounded(_fun, timeout_ms) when timeout_ms <= 0, do: :error

  defp invoke_cleanup_bounded(fun, timeout_ms) when is_function(fun, 0) do
    coordinator = self()
    result_ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        result =
          try do
            case fun.() do
              {:error, _reason} -> :error
              _other -> :ok
            end
          catch
            _kind, _reason -> :error
          end

        send(coordinator, {result_ref, result})
      end)

    _guard = spawn(fn -> guard_cleanup_worker(coordinator, pid) end)

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        receive do
          {^result_ref, result} -> result
        after
          0 -> :error
        end
    after
      timeout_ms ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :error
        after
          100 -> :error
        end
    end
  end

  defp invoke_cleanup_bounded(fun, timeout_ms, owner, generation)
       when is_function(fun, 0) and is_pid(owner) and is_reference(generation) do
    coordinator = self()
    owner_ref = Process.monitor(owner)
    result_ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        coordinator_ref = Process.monitor(coordinator)

        receive do
          {:run_cleanup, ^result_ref} ->
            Process.demonitor(coordinator_ref, [:flush])

            result =
              try do
                case fun.() do
                  {:error, _reason} -> :error
                  _other -> :ok
                end
              catch
                _kind, _reason -> :error
              end

            send(coordinator, {result_ref, result})

          {:DOWN, ^coordinator_ref, :process, ^coordinator, _reason} ->
            :ok
        end
      end)

    _guard = spawn(fn -> guard_cleanup_worker(coordinator, pid) end)
    send(owner, {:cleanup_child_started, generation, coordinator, pid})

    registered? =
      receive do
        {:cleanup_child_registered, ^generation, ^pid} -> true
        {:DOWN, ^owner_ref, :process, ^owner, _reason} -> :owner_down
      after
        timeout_ms -> false
      end

    case registered? do
      true ->
        send(pid, {:run_cleanup, result_ref})

        {result, worker_down?} =
          receive do
            {^result_ref, result} ->
              {result, false}

            {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
              {:error, true}

            {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
              Process.exit(pid, :kill)
              await_worker_down(pid, monitor_ref)
              exit(:resource_owner_down)
          after
            timeout_ms ->
              Process.exit(pid, :kill)
              await_worker_down(pid, monitor_ref)
              {:error, true}
          end

        unless worker_down?, do: await_worker_down(pid, monitor_ref)

        receive do
          {:cleanup_child_cleared, ^generation, ^pid} ->
            Process.demonitor(owner_ref, [:flush])
            result

          {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
            exit(:resource_owner_down)
        after
          timeout_ms ->
            Process.demonitor(owner_ref, [:flush])
            exit(:cleanup_child_clear_timeout)
        end

      :owner_down ->
        Process.exit(pid, :kill)
        await_worker_down(pid, monitor_ref)
        exit(:resource_owner_down)

      false ->
        Process.demonitor(owner_ref, [:flush])
        Process.exit(pid, :kill)
        await_worker_down(pid, monitor_ref)
        exit(:cleanup_child_registration_timeout)
    end
  end

  defp await_worker_down(pid, monitor_ref) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    after
      100 ->
        Process.demonitor(monitor_ref, [:flush])
        :ok
    end
  end

  defp guard_cleanup_worker(coordinator, worker) do
    coordinator_ref = Process.monitor(coordinator)
    worker_ref = Process.monitor(worker)

    receive do
      {:DOWN, ^coordinator_ref, :process, ^coordinator, _reason} ->
        if Process.alive?(worker), do: Process.exit(worker, :kill)

        receive do
          {:DOWN, ^worker_ref, :process, ^worker, _reason} -> :ok
        after
          100 -> Process.demonitor(worker_ref, [:flush])
        end

      {:DOWN, ^worker_ref, :process, ^worker, _reason} ->
        Process.demonitor(coordinator_ref, [:flush])
        :ok
    end
  end

  defp invoke_backend_close_bounded(_state, timeout_ms) when timeout_ms <= 0, do: :error

  defp invoke_backend_close_bounded(state, timeout_ms) do
    parent = self()
    result_ref = make_ref()
    backend = state.backend_mod
    session = Redacted.value(state.session)

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        result =
          try do
            if backend.close(session) == :ok, do: :ok, else: :error
          catch
            _kind, _reason -> :error
          end

        send(parent, {result_ref, result})
      end)

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        receive do
          {^result_ref, result} -> result
        after
          0 -> :error
        end
    after
      timeout_ms ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :error
        after
          100 -> :error
        end
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
    case validate_backend_args(operation, args, state.config[:max_recv_timeout_ms]) do
      {:ok, validated_args} ->
        session = Redacted.value(state.session)

        try do
          state.backend_mod
          |> apply(operation, [session | validated_args])
          |> validate_backend_result(operation, state)
        catch
          _kind, _reason ->
            log_redacted(:backend_callback_error)

            if send_operation?(operation) do
              poisoned = poison_state(state)
              {:error, :backend_callback_failed, poisoned}
            else
              {:error, :backend_callback_failed}
            end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_backend_result({:ok, new_session}, operation, state)
       when operation in [:configure, :send_text, :send_audio, :send_tool_result] do
    {:ok, %{state | session: Redacted.new(new_session)}}
  end

  defp validate_backend_result({:error, _reason, latest_session}, operation, state)
       when operation in [:send_text, :send_audio, :send_tool_result] do
    next_state =
      state
      |> Map.put(:session, Redacted.new(latest_session))
      |> poison_state()

    {:error, :backend_callback_failed, next_state}
  end

  defp validate_backend_result({:error, _reason, latest_session}, :configure, state) do
    {:error, :backend_callback_failed, %{state | session: Redacted.new(latest_session)}}
  end

  defp validate_backend_result({:ok, new_session, event}, :recv, state) do
    {:ok, %{state | session: Redacted.new(new_session)}, event}
  end

  # Preserve only a backend recv timeout so Session can continue finite
  # polling. Every other returned backend reason stays redacted.
  defp validate_backend_result({:error, :timeout}, :recv, _state),
    do: {:error, :timeout}

  defp validate_backend_result({:error, _reason}, operation, state)
       when operation in [:send_text, :send_audio, :send_tool_result] do
    {:error, :backend_callback_failed, poison_state(state)}
  end

  defp validate_backend_result({:error, _reason}, _operation, _state),
    do: {:error, :backend_callback_failed}

  defp validate_backend_result(_result, operation, state)
       when operation in [:send_text, :send_audio, :send_tool_result] do
    {:error, :backend_callback_failed, poison_state(state)}
  end

  defp validate_backend_result(_result, _operation, _state),
    do: {:error, :backend_callback_failed}

  defp send_operation?(operation),
    do: operation in [:send_text, :send_audio, :send_tool_result]

  defp poison_state(state) do
    _ = state.authority_cell |> Redacted.value() |> EgressAuthority.poison()
    %{state | poisoned: true}
  end

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

  # A disclosure minted before ordinary cleanup registration succeeds must not
  # be stranded in Session if owner close remains pending. Reserve exactly one
  # owner-only slot outside the ordinary cleanup cap for that handoff. If the
  # configured facade already registered the exact closure, this is a pure
  # verification and does not add a duplicate obligation.
  defp do_adopt_provisional_cleanup(state, key, fun) when is_function(fun, 0) do
    cleanups = Redacted.value(state.cleanups)
    provisional_key = {@provisional_cleanup_tag, key}

    case Map.fetch(cleanups, key) do
      {:ok, existing} when existing === fun ->
        {:ok, cleanups}

      {:ok, _different_cleanup} ->
        {:error, :provisional_cleanup_conflict}

      :error ->
        adopt_reserved_provisional_cleanup(cleanups, provisional_key, fun)
    end
  end

  defp do_adopt_provisional_cleanup(_state, _key, _fun),
    do: {:error, :invalid_cleanup}

  defp adopt_reserved_provisional_cleanup(cleanups, provisional_key, fun) do
    cond do
      Map.get(cleanups, provisional_key) === fun ->
        {:ok, cleanups}

      Map.has_key?(cleanups, provisional_key) ->
        {:error, :provisional_cleanup_conflict}

      Enum.any?(Map.keys(cleanups), &match?({@provisional_cleanup_tag, _}, &1)) ->
        {:error, :provisional_cleanup_occupied}

      true ->
        {:ok, Map.put(cleanups, provisional_key, fun)}
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
         length(Keyword.keys(backend_opts)) == length(Enum.uniq(Keyword.keys(backend_opts))) and
         not Keyword.has_key?(backend_opts, :effect_authorizer) do
      :ok
    else
      {:error, {:invalid_owner_config, :backend_opts}}
    end
  end

  defp validate_backend_opts(_backend_opts), do: {:error, {:invalid_owner_config, :backend_opts}}

  defp validate_handoff(%{authority: authority, initial_cleanup: nil})
       when is_map(authority) do
    if Map.get(authority, :kind) == :local and Map.get(authority, :route) == :none do
      :ok
    else
      {:error, :invalid_authority}
    end
  end

  defp validate_handoff(%{
         authority: %{kind: :external} = authority,
         initial_cleanup: {key, cleanup}
       })
       when is_map(authority) and is_function(cleanup, 0) do
    if key == :voice_realtime_route_capability do
      :ok
    else
      {:error, :invalid_authority}
    end
  end

  defp validate_handoff(_handoff), do: {:error, :invalid_authority}

  defp initial_cleanups(%{initial_cleanup: nil}), do: %{}

  defp initial_cleanups(%{initial_cleanup: {key, cleanup}})
       when is_function(cleanup, 0),
       do: %{key => cleanup}

  defp run_open_failure_cleanups(state) do
    cleanups =
      state.cleanups
      |> Redacted.value()
      |> Map.new(fn {key, fun} -> {key, {fun, state.config[:cleanup_attempts]}} end)

    deadline_ms = now_ms() + state.config[:close_timeout_ms]

    run_cleanups_without_supervisor(
      cleanups,
      state.config[:cleanup_per_attempt_timeout_ms],
      deadline_ms
    )
  end

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

  defp validate_backend_handoff(backend_module, %{authority: %{route: expected_route}}) do
    try do
      if backend_module.egress_route() == expected_route do
        :ok
      else
        {:error, :invalid_authority}
      end
    catch
      _kind, _reason -> {:error, :invalid_authority}
    end
  end

  defp validate_backend_handoff(_backend_module, _handoff), do: {:error, :invalid_authority}

  defp normalize_supervisor_error({:already_started, _pid}), do: :owner_already_started
  defp normalize_supervisor_error(:max_children), do: :supervisor_capacity_exceeded
  defp normalize_supervisor_error(:backend_open_failed), do: :backend_open_failed
  defp normalize_supervisor_error(:invalid_authority), do: :invalid_authority
  defp normalize_supervisor_error(:cleanup_unavailable), do: :cleanup_unavailable
  defp normalize_supervisor_error(_), do: :supervisor_unavailable

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp alive?(_), do: false

  defp log_redacted(tag) do
    require Logger

    Logger.warning("Arbor.Voice.ResourceOwner: callback failure", tag: tag, reason: :redacted)
  end
end
