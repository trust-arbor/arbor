defmodule Arbor.Voice.ResourceOwner do
  @moduledoc """
  Supervised coordinator for one realtime backend worker and its cleanup lease.

  Backend callbacks execute only in `Arbor.Voice.BackendWorker`. Cleanup
  closures execute only through `Arbor.Voice.CleanupLease`. This process owns
  the authority cell and coordinates their authenticated protocols without
  retaining backend handles or running physical effects itself.
  """

  use GenServer

  alias Arbor.Identifiers
  alias Arbor.Voice.BackendWorker
  alias Arbor.Voice.BackendWorker.EffectRequest
  alias Arbor.Voice.BackendWorker.Result
  alias Arbor.Voice.BackendWorkerSupervisor
  alias Arbor.Voice.CleanupLease
  alias Arbor.Voice.EgressAuthority
  alias Arbor.Voice.RealtimeBackend
  alias Arbor.Voice.Redacted

  @resource_supervisor Arbor.Voice.ResourceSupervisor
  @cleanup_task_supervisor Arbor.Voice.ResourceCleanupTaskSupervisor
  @cleanup_lease_supervisor Arbor.Voice.CleanupLeaseSupervisor
  @backend_worker_supervisor Arbor.Voice.BackendWorkerSupervisor

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
  @max_backend_opts_count 32
  @max_backend_opts_bytes 65_536
  @max_cleanup_key_bytes 4_096
  @max_initial_cleanups_bytes 65_536
  @max_deferred_requests 32
  @shutdown_grace_ms 5_000
  @call_timeout_ms @max_close_timeout_ms + @shutdown_grace_ms
  @startup_grace_ms 2_000
  @route_cleanup_key :voice_realtime_route_capability
  @result_tag :voice_backend_operation_result

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
    :cleanup_supervisor,
    :cleanup_lease_supervisor,
    :backend_worker_supervisor
  ]

  @external_effects %{
    open: [:connect],
    configure: [:configure],
    send_text: [:text_item, :text_response],
    send_audio: [:audio_append, :audio_commit, :audio_response],
    send_tool_result: [:tool_result_item, :tool_result_response],
    recv: [],
    meta: [],
    close: []
  }

  @doc false
  @spec close_call_timeout_ms() :: pos_integer()
  def close_call_timeout_ms, do: @call_timeout_ms

  @doc false
  def start(owner_pid, backend_module, backend_opts \\ [], opts \\ [])

  def start(owner_pid, backend_module, backend_opts, opts)
      when is_pid(owner_pid) and is_atom(backend_module) do
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
           {:ok, config} <- validate_opts(opts),
           {:ok, authority, initial_cleanups} <- normalize_handoff(handoff, config.max_cleanups),
           :ok <- validate_authority(authority),
           :ok <- validate_backend_module(backend_module),
           :ok <- validate_backend_route(backend_module, authority),
           {:ok, resource_supervisor} <-
             resolve_supervisor(Keyword.get(opts, :supervisor, @resource_supervisor), :supervisor),
           {:ok, cleanup_supervisor} <-
             resolve_supervisor(
               Keyword.get(opts, :cleanup_supervisor, @cleanup_task_supervisor),
               :cleanup
             ),
           {:ok, cleanup_lease_supervisor} <-
             resolve_supervisor(
               Keyword.get(opts, :cleanup_lease_supervisor, @cleanup_lease_supervisor),
               :cleanup
             ),
           {:ok, backend_worker_supervisor} <-
             resolve_supervisor(
               Keyword.get(opts, :backend_worker_supervisor, @backend_worker_supervisor),
               :worker
             ) do
        token = make_ref()
        startup_ref = make_ref()

        bootstrap =
          Redacted.new(%{
            owner_pid: owner_pid,
            token: Redacted.new(token),
            starter_pid: self(),
            startup_ref: startup_ref,
            backend_module: backend_module,
            backend_opts: Redacted.new(backend_opts),
            authority: Redacted.new(authority),
            initial_cleanups: Redacted.new(initial_cleanups),
            config: config,
            cleanup_supervisor: cleanup_supervisor,
            cleanup_lease_supervisor: cleanup_lease_supervisor,
            backend_worker_supervisor: backend_worker_supervisor
          })

        spec = %{
          id: make_ref(),
          start: {__MODULE__, :start_link, [bootstrap]},
          restart: :temporary,
          shutdown: @call_timeout_ms,
          type: :worker
        }

        start_supervised_owner(resource_supervisor, spec, startup_ref, token, config)
      end
    end
  end

  def start(_owner_pid, _backend_module, _backend_opts, _handoff, _opts),
    do: {:error, :invalid_owner_config}

  @doc false
  def start_link(%Redacted{} = bootstrap), do: GenServer.start_link(__MODULE__, bootstrap)

  @spec configure(GenServer.server(), map()) :: :ok | {:error, atom()}
  def configure(owner, config), do: call(owner, {:backend, :configure, [config]})

  @spec send_text(GenServer.server(), String.t()) :: :ok | {:error, atom()}
  def send_text(owner, text), do: call(owner, {:backend, :send_text, [text]})

  @spec send_audio(GenServer.server(), binary()) :: :ok | {:error, atom()}
  def send_audio(owner, chunk), do: call(owner, {:backend, :send_audio, [chunk]})

  @spec send_tool_result(GenServer.server(), String.t(), String.t()) ::
          :ok | {:error, atom()}
  def send_tool_result(owner, call_id, output),
    do: call(owner, {:backend, :send_tool_result, [call_id, output]})

  @doc """
  Enqueues a tool-result operation without blocking the Session owner.

  A following `close/1` from the same owner is serialized after this admitted
  request by normal mailbox order and ResourceOwner's deferred fence queue.
  """
  @spec send_tool_result_request(GenServer.server(), String.t(), String.t()) ::
          {:ok, :gen_server.request_id()} | {:error, atom()}
  def send_tool_result_request(owner, call_id, output)
      when is_pid(owner) and is_binary(call_id) and is_binary(output) do
    with {:ok, request} <-
           authenticated_request(owner, {:backend, :send_tool_result, [call_id, output]}) do
      {:ok, :gen_server.send_request(owner, request)}
    end
  rescue
    _exception -> {:error, :owner_unavailable}
  catch
    _kind, _reason -> {:error, :owner_unavailable}
  end

  def send_tool_result_request(_owner, _call_id, _output),
    do: {:error, :owner_unavailable}

  @spec recv(GenServer.server(), timeout()) ::
          {:ok, Arbor.Voice.RealtimeBackend.event()} | {:error, atom()}
  def recv(owner, timeout), do: call(owner, {:backend, :recv, [timeout]})

  @spec meta(GenServer.server()) :: {:ok, map()} | {:error, atom()}
  def meta(owner), do: call(owner, {:backend, :meta, []})

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
    result = call(owner, :close)
    Process.delete(owner_token_key(owner))
    result
  end

  def close(_owner), do: {:error, :owner_unavailable}

  defp call(owner, request) when is_pid(owner) do
    with {:ok, authenticated} <- authenticated_request(owner, request) do
      GenServer.call(owner, authenticated, @call_timeout_ms)
    end
  catch
    :exit, {:timeout, _} -> {:error, :owner_timeout}
    :exit, {:noproc, _} -> {:error, :owner_unavailable}
    :exit, {:normal, _} -> {:error, :owner_unavailable}
    :exit, _ -> {:error, :owner_unavailable}
  end

  defp call(_owner, _request), do: {:error, :owner_unavailable}

  defp authenticated_request(owner, request) do
    cond do
      not Process.alive?(owner) ->
        {:error, :owner_unavailable}

      match?(%Redacted{}, Process.get(owner_token_key(owner))) ->
        token = Process.get(owner_token_key(owner))
        {:ok, {:owner_request, token, Redacted.new(request)}}

      true ->
        {:error, :foreign_caller}
    end
  end

  @impl true
  def init(%Redacted{} = redacted_bootstrap) do
    Process.flag(:trap_exit, true)
    bootstrap = Redacted.value(redacted_bootstrap)
    authority_value = Redacted.value(bootstrap.authority)
    initial_cleanups_value = Redacted.value(bootstrap.initial_cleanups)

    with {:ok, authority_cell} <- EgressAuthority.new_private_cell(authority_value),
         {:ok, lease, lease_credential} <-
           CleanupLease.start(self(), initial_cleanups_value,
             supervisor: bootstrap.cleanup_lease_supervisor,
             cleanup_supervisor: bootstrap.cleanup_supervisor,
             cleanup_per_attempt_timeout_ms: bootstrap.config.cleanup_per_attempt_timeout_ms,
             max_cleanups: bootstrap.config.max_cleanups
           ) do
      state = %{
        owner_pid: bootstrap.owner_pid,
        owner_ref: Process.monitor(bootstrap.owner_pid),
        owner_token: bootstrap.token,
        starter_pid: bootstrap.starter_pid,
        startup_ref: bootstrap.startup_ref,
        backend_module: bootstrap.backend_module,
        backend_opts: bootstrap.backend_opts,
        route: Redacted.new(authority_value.route),
        authority_cell: Redacted.new(authority_cell),
        config: bootstrap.config,
        backend_worker_supervisor: bootstrap.backend_worker_supervisor,
        worker: nil,
        worker_ref: nil,
        worker_credential: nil,
        lease: lease,
        lease_ref: Process.monitor(lease),
        lease_credential: Redacted.new(lease_credential),
        cleanup_keys: Redacted.new(MapSet.new(Map.keys(initial_cleanups_value))),
        phase: :starting,
        poisoned: false,
        current: nil,
        deferred: :queue.new(),
        lease_request: nil,
        close_waiters: [],
        close_deadline_ms: nil,
        close_timer_ref: nil,
        close_timer_token: nil,
        close_error: nil
      }

      {:ok, state, {:continue, :start_backend_worker}}
    else
      {:error, reason} -> {:stop, normalize_init_error(reason)}
    end
  end

  @impl true
  def handle_continue(:start_backend_worker, state) do
    generation = make_ref()
    route = Redacted.value(state.route)
    backend_opts = Redacted.value(state.backend_opts)

    worker_opts = [
      effect_timeout_ms: min(state.config.close_timeout_ms, 5_000),
      ack_timeout_ms: min(state.config.close_timeout_ms, 30_000),
      retire_timeout_ms: min(state.config.close_timeout_ms, 30_000)
    ]

    case BackendWorkerSupervisor.start_worker(
           state.backend_worker_supervisor,
           self(),
           generation,
           state.backend_module,
           backend_opts,
           route,
           worker_opts
         ) do
      {:ok, worker, credential} ->
        worker_ref = Process.monitor(worker)

        case CleanupLease.bind_worker(lease_credential(state), worker) do
          :ok ->
            state = %{
              state
              | worker: worker,
                worker_ref: worker_ref,
                worker_credential: Redacted.new(credential),
                backend_opts: Redacted.new([])
            }

            case submit_operation(:open, [], :startup, state) do
              {:ok, state} -> {:noreply, state}
              {:error, state} -> startup_failure(state)
            end

          {:error, _reason} ->
            Process.demonitor(worker_ref, [:flush])
            startup_failure(state)
        end

      {:error, _reason} ->
        startup_failure(state)
    end
  end

  @impl true
  def handle_call({:owner_request, token, request}, {caller_pid, _tag} = from, state) do
    if authenticated_owner?(caller_pid, token, state) do
      dispatch_owner_request(Redacted.value(request), from, state)
    else
      {:reply, {:error, :foreign_caller}, state}
    end
  end

  def handle_call(_request, _from, state),
    do: {:reply, {:error, :foreign_caller}, state}

  defp dispatch_owner_request(request, from, %{current: current} = state)
       when not is_nil(current) do
    cond do
      not deferrable_request?(request) ->
        {:reply, {:error, :owner_busy}, state}

      :queue.len(state.deferred) >= @max_deferred_requests ->
        {:reply, {:error, :owner_busy}, state}

      true ->
        {:noreply, enqueue_deferred(state, request, from)}
    end
  end

  defp dispatch_owner_request(:close, from, %{phase: :closing} = state) do
    {:noreply, add_close_waiter(state, from)}
  end

  defp dispatch_owner_request(:close, from, state) do
    state = state |> add_close_waiter(from) |> begin_close()
    continue_close(state)
  end

  defp dispatch_owner_request({:fence_and_drain, :session}, from, state) do
    state = state |> add_close_waiter(from) |> begin_close()
    continue_close(state)
  end

  defp dispatch_owner_request({:fence_and_drain, turn_id}, from, state)
       when is_binary(turn_id) do
    begin_turn_fence(turn_id, from, state)
  end

  defp dispatch_owner_request({:activate_turn, _lease}, _from, %{phase: phase} = state)
       when phase in [:closing, :closed, :terminal] do
    {:reply, {:error, :owner_closing}, state}
  end

  defp dispatch_owner_request({:activate_turn, _lease}, _from, %{poisoned: true} = state),
    do: {:reply, {:error, :owner_poisoned}, state}

  defp dispatch_owner_request({:activate_turn, lease}, _from, state) when is_map(lease) do
    cleanup_key = Map.get(lease, :cleanup_key)
    cleanup_registered? = MapSet.member?(cleanup_keys(state), cleanup_key)

    case safe_authority_call(fn ->
           EgressAuthority.activate_turn(authority_cell(state), lease, cleanup_registered?)
         end) do
      :ok -> {:reply, :ok, state}
      _error -> {:reply, {:error, :turn_activation_denied}, state}
    end
  end

  defp dispatch_owner_request({:register_cleanup, key, fun}, _from, state) do
    if valid_cleanup_key?(key) do
      case CleanupLease.register_cleanup(lease_credential(state), key, fun) do
        :ok -> {:reply, :ok, put_cleanup_key(state, key)}
        {:error, reason} -> {:reply, {:error, bounded_cleanup_error(reason)}, state}
      end
    else
      {:reply, {:error, :invalid_cleanup}, state}
    end
  end

  defp dispatch_owner_request({:adopt_provisional_cleanup, key, fun}, _from, state) do
    if valid_cleanup_key?(key) do
      case CleanupLease.adopt_provisional_cleanup(lease_credential(state), key, fun) do
        :ok -> {:reply, :ok, put_cleanup_key(state, key)}
        {:error, reason} -> {:reply, {:error, bounded_cleanup_error(reason)}, state}
      end
    else
      {:reply, {:error, :invalid_cleanup}, state}
    end
  end

  defp dispatch_owner_request({:remove_cleanup, key}, _from, state) do
    if valid_cleanup_key?(key) do
      case CleanupLease.remove_cleanup(lease_credential(state), key) do
        :ok -> {:reply, :ok, delete_cleanup_key(state, key)}
        {:error, reason} -> {:reply, {:error, bounded_cleanup_error(reason)}, state}
      end
    else
      {:reply, {:error, :invalid_cleanup}, state}
    end
  end

  defp dispatch_owner_request({:backend, _operation, _args}, _from, %{phase: :closing} = state),
    do: {:reply, {:error, :owner_closing}, state}

  defp dispatch_owner_request({:backend, _operation, _args}, _from, %{phase: :closed} = state),
    do: {:reply, {:error, :owner_closed}, state}

  defp dispatch_owner_request({:backend, _operation, _args}, _from, %{phase: :terminal} = state),
    do: {:reply, {:error, :owner_poisoned}, state}

  defp dispatch_owner_request({:backend, _operation, _args}, _from, %{poisoned: true} = state),
    do: {:reply, {:error, :owner_poisoned}, state}

  defp dispatch_owner_request({:backend, operation, args}, from, state) do
    with :ok <- validate_operation_args(operation, args, state.config),
         {:ok, state} <- submit_operation(operation, args, {:call, from}, state) do
      {:noreply, state}
    else
      {:error, :invalid_timeout} -> {:reply, {:error, :invalid_timeout}, state}
      {:error, _reason} -> {:reply, {:error, :backend_callback_failed}, state}
      {:error, _reason, next_state} -> {:reply, {:error, :backend_callback_failed}, next_state}
    end
  end

  defp dispatch_owner_request(_request, _from, state),
    do: {:reply, {:error, :unsupported_request}, state}

  @impl true
  def handle_info(%EffectRequest{} = request, state),
    do: handle_effect_request(request, state)

  def handle_info({@result_tag, %Result{} = result}, state),
    do: handle_worker_result(result, state)

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{owner_ref: ref, owner_pid: pid} = state
      ) do
    state = %{state | owner_ref: nil}

    cond do
      state.phase == :closing ->
        {:noreply, state}

      not is_nil(state.current) ->
        {:noreply, enqueue_internal_close(state)}

      true ->
        state = begin_close(state)
        continue_close(state)
    end
  end

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{worker_ref: ref, worker: pid} = state
      ) do
    state = %{state | worker: nil, worker_ref: nil, worker_credential: nil}
    handle_worker_down(state)
  end

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{lease_ref: ref, lease: pid} = state
      ) do
    state = %{state | lease_ref: nil, lease: nil, lease_credential: nil}

    if state.phase == :starting do
      startup_failure(state)
    else
      state = %{poison_state(state) | close_error: state.close_error || :cleanup_pending}

      cond do
        state.phase == :closing and is_nil(state.worker) ->
          finish_close({:error, :cleanup_pending}, state)

        state.phase == :closing ->
          {:noreply, state}

        not is_nil(state.current) ->
          {:noreply, enqueue_internal_close(state)}

        true ->
          state = begin_close(state)
          continue_close(state)
      end
    end
  end

  def handle_info({:EXIT, pid, _reason}, %{worker: pid} = state), do: {:noreply, state}

  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  def handle_info({:operation_deadline, token}, %{current: %{token: token} = current} = state) do
    if current.status == :running do
      state = poison_state(state)

      current = %{
        current
        | status: :awaiting_down,
          reply: current.reply || {:error, :owner_timeout}
      }

      {:noreply, %{state | current: current}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:close_deadline, token}, %{close_timer_token: token, phase: :closing} = state) do
    state = %{
      clear_close_timer(state)
      | close_error: state.close_error || :owner_timeout
    }

    cond do
      is_pid(state.worker) ->
        Process.exit(state.worker, :kill)
        {:noreply, state}

      MapSet.size(cleanup_keys(state)) > 0 ->
        finish_close({:error, :cleanup_pending}, state)

      true ->
        finish_close(close_success_reply(state), state)
    end
  end

  def handle_info(message, %{lease_request: %{request_id: request_id} = request} = state) do
    case CleanupLease.check_response(message, request_id) do
      {:reply, reply} ->
        handle_lease_response(reply, request, %{state | lease_request: nil})

      {:error, :lease_unavailable} ->
        handle_lease_response(
          {:error, :lease_unavailable},
          request,
          %{state | lease_request: nil}
        )

      :no_reply ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_timer(Map.get(state, :close_timer_ref))

    case Map.get(state, :current) do
      %{timer_ref: timer_ref} -> cancel_timer(timer_ref)
      _ -> :ok
    end

    :ok
  end

  @impl true
  def format_status(%{state: state} = status) when is_map(state) do
    public_state = %{
      owner_pid: state.owner_pid,
      backend_module: state.backend_module,
      phase: state.phase,
      poisoned: state.poisoned,
      worker_alive: is_pid(state.worker) and Process.alive?(state.worker),
      lease_alive: is_pid(state.lease) and Process.alive?(state.lease),
      operation: if(state.current, do: state.current.operation, else: nil),
      cleanup_count: MapSet.size(cleanup_keys(state)),
      deferred_count: :queue.len(state.deferred)
    }

    %{status | state: public_state, message: :redacted, log: :redacted}
  end

  def format_status(status), do: status

  # Backend protocol

  defp submit_operation(operation, args, origin, state) do
    token = BackendWorker.new_operation_token()
    deadline_ms = now_ms() + state.config.close_timeout_ms

    case BackendWorker.submit(
           state.worker,
           worker_credential(state),
           token,
           deadline_ms,
           operation,
           args
         ) do
      :ok ->
        timer_ref =
          Process.send_after(
            self(),
            {:operation_deadline, token},
            max(1, deadline_ms - now_ms())
          )

        current = %{
          operation: operation,
          token: token,
          deadline_ms: deadline_ms,
          timer_ref: timer_ref,
          expected_effects: expected_effects(operation, state),
          origin: origin,
          status: :running,
          reply: nil
        }

        {:ok, %{state | current: current}}

      {:error, _reason} ->
        {:error, :submit_failed}
    end
  end

  defp handle_effect_request(request, %{current: current} = state) when not is_nil(current) do
    credential = worker_credential(state)

    with {:ok, ^request} <- BackendWorker.verify_effect_request(request, credential),
         true <- request.worker == state.worker,
         true <- request.operation_token === current.token,
         true <- current.status == :running,
         true <- now_ms() <= current.deadline_ms,
         [expected | rest] <- current.expected_effects,
         true <- request.effect === expected,
         :allow <- authorize_effect(state, request),
         :ok <- BackendWorker.reply_effect(request, credential, :allow) do
      current = %{current | expected_effects: rest}
      {:noreply, %{state | current: current}}
    else
      _invalid ->
        maybe_deny_effect(request, credential)
        {:noreply, poison_current(state, :backend_effect_denied)}
    end
  end

  defp handle_effect_request(_request, state), do: {:noreply, state}

  defp handle_worker_result(result, %{current: current} = state) when not is_nil(current) do
    credential = worker_credential(state)
    received_at = now_ms()

    with {:ok, verified} <- BackendWorker.verify_result(result, credential),
         true <- verified.worker == state.worker,
         true <- verified.operation_token === current.token,
         true <- verified.operation === current.operation,
         true <- verified.completed_at <= current.deadline_ms,
         true <- received_at <= current.deadline_ms do
      cancel_timer(current.timer_ref)
      reply = current.reply || public_outcome(verified.outcome, current.operation)

      terminal? =
        terminal_outcome?(verified.outcome, current.operation) or not is_nil(current.reply)

      effects_complete? = current.expected_effects == []

      cond do
        successful_outcome?(verified.outcome) and not effects_complete? ->
          current = %{
            current
            | timer_ref: nil,
              status: :awaiting_down,
              reply: {:error, :backend_effect_denied}
          }

          {:noreply, %{poison_state(state) | current: current}}

        BackendWorker.ack(state.worker, credential, result) != :ok ->
          current = %{
            current
            | timer_ref: nil,
              status: :awaiting_down,
              reply: {:error, :backend_callback_failed}
          }

          {:noreply, %{poison_state(state) | current: current}}

        terminal? ->
          current = %{current | timer_ref: nil, status: :awaiting_down, reply: reply}

          state =
            if current.operation == :close,
              do: state,
              else: poison_state(state)

          {:noreply, %{state | current: current}}

        true ->
          state = %{state | current: nil, phase: :open}
          complete_origin(current.origin, reply, state)
      end
    else
      _invalid ->
        cancel_timer(current.timer_ref)

        current = %{
          current
          | timer_ref: nil,
            status: :awaiting_down,
            reply: {:error, :backend_callback_failed}
        }

        {:noreply, %{poison_state(state) | current: current}}
    end
  end

  defp handle_worker_result(_result, state), do: {:noreply, state}

  defp handle_worker_down(%{current: nil, phase: :closing} = state),
    do: begin_close_cleanup(state)

  defp handle_worker_down(%{current: nil, phase: :starting} = state),
    do: startup_failure(state)

  defp handle_worker_down(%{current: nil} = state),
    do: {:noreply, %{poison_state(state) | phase: :terminal}}

  defp handle_worker_down(%{current: current} = state) do
    cancel_timer(current.timer_ref)
    reply = current.reply || {:error, :backend_callback_failed}
    state = %{state | current: nil, phase: :terminal}

    case current.origin do
      :startup ->
        startup_failure(state)

      :close ->
        begin_close_cleanup(%{state | phase: :closing, close_error: close_error(reply)})

      {:call, from} ->
        GenServer.reply(from, reply)
        dispatch_deferred(state)
    end
  end

  defp complete_origin(:startup, :ok, state) do
    send(state.starter_pid, {:resource_owner_started, state.startup_ref, self(), :ok})
    {:noreply, %{state | phase: :open, starter_pid: nil, startup_ref: nil}}
  end

  defp complete_origin(:startup, _reply, state), do: startup_failure(state)

  defp complete_origin({:call, from}, reply, state) do
    GenServer.reply(from, reply)
    dispatch_deferred(state)
  end

  defp complete_origin(:close, reply, state) do
    # A close result is terminal by contract, so this clause is defensive.
    begin_close_cleanup(%{state | phase: :closing, close_error: close_error(reply)})
  end

  defp authorize_effect(state, request) do
    safe_authority_call(fn ->
      EgressAuthority.effect_authorizer(authority_cell(state)).(
        request.effect,
        request.frozen_route
      )
    end)
  end

  defp maybe_deny_effect(request, credential) do
    case BackendWorker.verify_effect_request(request, credential) do
      {:ok, ^request} -> BackendWorker.reply_effect(request, credential, :deny)
      _invalid -> :ok
    end
  end

  defp poison_current(%{current: nil} = state, _reason), do: poison_state(state)

  defp poison_current(%{current: current} = state, reason) do
    current = %{current | reply: {:error, reason}}
    %{poison_state(state) | current: current}
  end

  # Turn and session cleanup protocol

  defp begin_turn_fence(turn_id, from, state) do
    case safe_authority_call(fn ->
           EgressAuthority.fence_and_drain(authority_cell(state), turn_id)
         end) do
      :ok ->
        key = {:voice_turn, turn_id}

        if MapSet.member?(cleanup_keys(state), key) do
          case CleanupLease.settle_cleanup_request(
                 lease_credential(state),
                 key,
                 state.config.cleanup_per_attempt_timeout_ms
               ) do
            {:ok, request_id} ->
              lease_request = %{
                request_id: request_id,
                stage: :settle,
                action: {:turn, from, key}
              }

              {:noreply, %{state | lease_request: lease_request}}

            {:error, _reason} ->
              {:reply, {:error, :cleanup_pending}, state}
          end
        else
          {:reply, :ok, state}
        end

      {:error, :owner_poisoned} ->
        {:reply, {:error, :owner_poisoned}, poison_state(state)}

      _error ->
        {:reply, {:error, :fence_failed}, state}
    end
  end

  defp handle_lease_response(:ok, %{stage: :settle, action: {:turn, from, key}}, state) do
    case CleanupLease.await_empty_request(lease_credential(state), [key], 0) do
      {:ok, request_id} ->
        request = %{request_id: request_id, stage: :await, action: {:turn, from, key}}
        {:noreply, %{state | lease_request: request}}

      {:error, _reason} ->
        GenServer.reply(from, {:error, :cleanup_pending})
        dispatch_deferred(state)
    end
  end

  defp handle_lease_response(:ok, %{stage: :await, action: {:turn, from, key}}, state) do
    GenServer.reply(from, :ok)
    state = delete_cleanup_key(state, key)
    dispatch_deferred(state)
  end

  defp handle_lease_response(:ok, %{stage: :await, action: :close}, state),
    do: finish_close(close_success_reply(state), clear_close_timer(state))

  defp handle_lease_response(_reply, %{action: {:turn, from, _key}}, state) do
    GenServer.reply(from, {:error, :cleanup_pending})
    dispatch_deferred(state)
  end

  defp handle_lease_response(_reply, %{action: :close}, state),
    do: finish_close({:error, :cleanup_pending}, clear_close_timer(state))

  defp handle_lease_response(_reply, _request, state), do: {:noreply, state}

  defp begin_close(%{phase: :closing} = state), do: state

  defp begin_close(state) do
    _ =
      safe_authority_call(fn ->
        EgressAuthority.fence_and_drain(authority_cell(state), :session)
      end)

    token = make_ref()
    deadline_ms = now_ms() + state.config.close_timeout_ms

    timer_ref =
      Process.send_after(self(), {:close_deadline, token}, state.config.close_timeout_ms)

    %{
      state
      | phase: :closing,
        close_deadline_ms: deadline_ms,
        close_timer_ref: timer_ref,
        close_timer_token: token
    }
  end

  defp continue_close(%{worker: worker, current: nil} = state) when is_pid(worker) do
    case submit_operation(:close, [], :close, state) do
      {:ok, state} ->
        {:noreply, state}

      {:error, _reason} ->
        {:noreply, %{poison_state(state) | close_error: :backend_callback_failed}}
    end
  end

  defp continue_close(%{worker: nil} = state), do: begin_close_cleanup(state)
  defp continue_close(state), do: {:noreply, state}

  defp begin_close_cleanup(state) do
    _ = CleanupLease.begin_cleanup(lease_credential(state), :fenced)
    keys = MapSet.to_list(cleanup_keys(state))

    cond do
      keys == [] ->
        finish_close(close_success_reply(state), state)

      not is_integer(state.close_deadline_ms) ->
        finish_close({:error, :cleanup_pending}, state)

      true ->
        remaining = max(0, state.close_deadline_ms - now_ms())

        case CleanupLease.await_empty_request(lease_credential(state), keys, remaining) do
          {:ok, request_id} ->
            lease_request = %{request_id: request_id, stage: :await, action: :close}
            {:noreply, %{state | lease_request: lease_request}}

          {:error, _reason} ->
            finish_close({:error, :cleanup_pending}, state)
        end
    end
  end

  defp finish_close(reply, state) do
    Enum.each(state.close_waiters, &GenServer.reply(&1, reply))
    {:stop, :normal, %{state | close_waiters: [], phase: :closed}}
  end

  defp close_success_reply(%{close_error: nil}), do: :ok
  defp close_success_reply(%{close_error: error}), do: {:error, error}

  # Deferred owner calls

  defp enqueue_deferred(state, request, from) do
    deferred = :queue.in({Redacted.new(request), from}, state.deferred)
    %{state | deferred: deferred}
  end

  defp enqueue_internal_close(state) do
    deferred = :queue.in({Redacted.new(:internal_close), nil}, state.deferred)
    %{state | deferred: deferred}
  end

  defp dispatch_deferred(state) do
    case :queue.out(state.deferred) do
      {{:value, {request, from}}, deferred} ->
        state = %{state | deferred: deferred}

        case dispatch_deferred_request(Redacted.value(request), from, state) do
          {:reply, reply, state} ->
            GenServer.reply(from, reply)
            dispatch_deferred(state)

          {:noreply, state} ->
            {:noreply, state}

          {:stop, reason, state} ->
            {:stop, reason, state}
        end

      {:empty, _deferred} ->
        {:noreply, state}
    end
  end

  defp deferrable_request?(:close), do: true
  defp deferrable_request?({:fence_and_drain, _scope}), do: true
  defp deferrable_request?({:backend, _operation, _args}), do: true
  defp deferrable_request?(_request), do: false

  defp dispatch_deferred_request(:internal_close, nil, state) do
    state = begin_close(state)
    continue_close(state)
  end

  defp dispatch_deferred_request(request, from, state),
    do: dispatch_owner_request(request, from, state)

  # Startup

  defp start_supervised_owner(supervisor, spec, startup_ref, token, config) do
    case DynamicSupervisor.start_child(supervisor, spec) do
      {:ok, pid} -> await_startup(pid, supervisor, startup_ref, token, config)
      {:ok, pid, _info} -> await_startup(pid, supervisor, startup_ref, token, config)
      {:error, reason} -> {:error, normalize_supervisor_error(reason)}
    end
  end

  defp await_startup(pid, supervisor, startup_ref, token, config) do
    monitor_ref = Process.monitor(pid)
    timeout_ms = config.close_timeout_ms + @startup_grace_ms

    receive do
      {:resource_owner_started, ^startup_ref, ^pid, :ok} ->
        Process.demonitor(monitor_ref, [:flush])
        Process.put(owner_token_key(pid), Redacted.new(token))
        {:ok, pid}

      {:resource_owner_started, ^startup_ref, ^pid, {:error, :start_failed}} ->
        await_exact_down(pid, monitor_ref, 1_000)
        {:error, {:handoff_accepted, :start_failed}}

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        {:error, {:handoff_accepted, :start_failed}}
    after
      timeout_ms ->
        _ = DynamicSupervisor.terminate_child(supervisor, pid)
        await_exact_down(pid, monitor_ref, 1_000)
        {:error, {:handoff_accepted, :start_failed}}
    end
  end

  defp startup_failure(state) do
    if is_pid(state.starter_pid) and is_reference(state.startup_ref) do
      send(
        state.starter_pid,
        {:resource_owner_started, state.startup_ref, self(), {:error, :start_failed}}
      )
    end

    {:stop, :normal, %{state | starter_pid: nil, startup_ref: nil}}
  end

  # Validation and redacted helpers

  defp validate_opts(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         keys <- Keyword.keys(opts),
         true <- length(keys) == length(Enum.uniq(keys)),
         true <- Enum.all?(keys, &(&1 in @allowed_owner_opts)) do
      config =
        @defaults
        |> Keyword.merge(
          Keyword.drop(opts, [
            :supervisor,
            :cleanup_supervisor,
            :cleanup_lease_supervisor,
            :backend_worker_supervisor
          ])
        )
        |> Map.new()

      with :ok <-
             bounded_positive(config.close_timeout_ms, @max_close_timeout_ms, :close_timeout_ms),
           :ok <-
             bounded_positive(
               config.cleanup_ready_timeout_ms,
               @max_close_timeout_ms,
               :cleanup_ready_timeout_ms
             ),
           :ok <-
             bounded_positive(config.cleanup_attempts, @max_cleanup_attempts, :cleanup_attempts),
           :ok <-
             bounded_positive(
               config.cleanup_per_attempt_timeout_ms,
               @max_cleanup_per_attempt_timeout_ms,
               :cleanup_per_attempt_timeout_ms
             ),
           :ok <-
             bounded_positive(
               config.max_recv_timeout_ms,
               @max_recv_timeout_ms,
               :max_recv_timeout_ms
             ),
           :ok <- bounded_positive(config.max_cleanups, @max_cleanups, :max_cleanups) do
        {:ok, config}
      end
    else
      _invalid -> {:error, :invalid_owner_config}
    end
  end

  defp validate_opts(_opts), do: {:error, :invalid_owner_config}

  defp bounded_positive(value, maximum, _key)
       when is_integer(value) and value > 0 and value <= maximum,
       do: :ok

  defp bounded_positive(_value, _maximum, key),
    do: {:error, {:invalid_owner_config, key}}

  defp validate_backend_opts(backend_opts) when is_list(backend_opts) do
    keys = if Keyword.keyword?(backend_opts), do: Keyword.keys(backend_opts), else: []

    if Keyword.keyword?(backend_opts) and length(keys) == length(Enum.uniq(keys)) and
         length(keys) <= @max_backend_opts_count and
         not Keyword.has_key?(backend_opts, :effect_authorizer) and
         safe_external_size(backend_opts) <= @max_backend_opts_bytes do
      :ok
    else
      {:error, {:invalid_owner_config, :backend_opts}}
    end
  end

  defp validate_backend_opts(_backend_opts),
    do: {:error, {:invalid_owner_config, :backend_opts}}

  defp normalize_handoff(handoff, max_cleanups) do
    keys = Map.keys(handoff)

    cond do
      MapSet.new(keys)
      |> MapSet.subset?(MapSet.new([:authority, :initial_cleanup, :initial_cleanups])) == false ->
        {:error, :invalid_authority}

      Map.has_key?(handoff, :initial_cleanup) and Map.has_key?(handoff, :initial_cleanups) ->
        {:error, :invalid_authority}

      not Map.has_key?(handoff, :authority) ->
        {:error, :invalid_authority}

      true ->
        with {:ok, cleanups} <- normalize_initial_cleanups(handoff),
             true <- map_size(cleanups) <= max_cleanups,
             true <- safe_external_size(Map.keys(cleanups)) <= @max_initial_cleanups_bytes,
             true <-
               Enum.all?(Map.keys(cleanups), &(safe_external_size(&1) <= @max_cleanup_key_bytes)),
             false <- Enum.any?(Map.keys(cleanups), &reserved_cleanup_key?/1),
             :ok <- validate_handoff_cleanup_shape(handoff.authority, cleanups) do
          {:ok, handoff.authority, cleanups}
        else
          false -> {:error, :invalid_authority}
          true -> {:error, :invalid_authority}
          {:error, _reason} = error -> error
        end
    end
  end

  defp normalize_initial_cleanups(handoff) do
    value =
      cond do
        Map.has_key?(handoff, :initial_cleanup) -> Map.get(handoff, :initial_cleanup)
        Map.has_key?(handoff, :initial_cleanups) -> Map.get(handoff, :initial_cleanups)
        true -> nil
      end

    case value do
      nil ->
        {:ok, %{}}

      {key, fun} when is_function(fun, 0) ->
        {:ok, %{key => fun}}

      cleanups when is_map(cleanups) ->
        if Enum.all?(cleanups, fn {_key, fun} -> is_function(fun, 0) end),
          do: {:ok, cleanups},
          else: {:error, :invalid_authority}

      _invalid ->
        {:error, :invalid_authority}
    end
  end

  defp validate_handoff_cleanup_shape(%{kind: :local}, _cleanups), do: :ok

  defp validate_handoff_cleanup_shape(%{kind: :external}, cleanups) do
    if Map.has_key?(cleanups, @route_cleanup_key), do: :ok, else: {:error, :invalid_authority}
  end

  defp validate_handoff_cleanup_shape(_authority, _cleanups),
    do: {:error, :invalid_authority}

  defp validate_authority(authority) do
    case EgressAuthority.new_private_cell(authority) do
      {:ok, tid} ->
        :ets.delete(tid)
        :ok

      {:error, _reason} ->
        {:error, :invalid_authority}
    end
  end

  defp validate_backend_module(module) do
    callbacks = RealtimeBackend.behaviour_info(:callbacks)

    if Code.ensure_loaded?(module) and
         Enum.all?(callbacks, fn {name, arity} -> function_exported?(module, name, arity) end) do
      :ok
    else
      {:error, :invalid_backend}
    end
  rescue
    _exception -> {:error, :invalid_backend}
  catch
    _kind, _reason -> {:error, :invalid_backend}
  end

  defp validate_backend_route(backend_module, %{route: expected_route}) do
    if backend_module.egress_route() === expected_route,
      do: :ok,
      else: {:error, :invalid_authority}
  rescue
    _exception -> {:error, :invalid_authority}
  catch
    _kind, _reason -> {:error, :invalid_authority}
  end

  defp validate_backend_route(_backend_module, _authority),
    do: {:error, :invalid_authority}

  defp validate_operation_args(:recv, [timeout], config)
       when is_integer(timeout) and timeout >= 0 and timeout <= config.max_recv_timeout_ms,
       do: :ok

  defp validate_operation_args(:recv, [_timeout], _config), do: {:error, :invalid_timeout}
  defp validate_operation_args(:configure, [config], _owner_config) when is_map(config), do: :ok
  defp validate_operation_args(:send_text, [text], _config) when is_binary(text), do: :ok
  defp validate_operation_args(:send_audio, [audio], _config) when is_binary(audio), do: :ok

  defp validate_operation_args(:send_tool_result, [call_id, output], _config)
       when is_binary(call_id) and is_binary(output),
       do: :ok

  defp validate_operation_args(operation, [], _config) when operation in [:meta, :close], do: :ok
  defp validate_operation_args(_operation, _args, _config), do: {:error, :invalid_operation}

  defp resolve_supervisor(name, kind) when is_atom(name) and not is_nil(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        if Process.alive?(pid),
          do: {:ok, pid},
          else: {:error, unavailable_error(kind)}

      _missing ->
        {:error, unavailable_error(kind)}
    end
  end

  defp resolve_supervisor(pid, _kind) when is_pid(pid) do
    if Process.alive?(pid), do: {:ok, pid}, else: {:error, :supervisor_unavailable}
  end

  defp resolve_supervisor(_supervisor, kind), do: {:error, unavailable_error(kind)}

  defp unavailable_error(:cleanup), do: :cleanup_unavailable
  defp unavailable_error(:worker), do: :worker_unavailable
  defp unavailable_error(:supervisor), do: :supervisor_unavailable

  defp normalize_supervisor_error({:already_started, _pid}), do: :owner_already_started
  defp normalize_supervisor_error(:max_children), do: :supervisor_capacity_exceeded
  defp normalize_supervisor_error({:shutdown, reason}), do: normalize_supervisor_error(reason)

  defp normalize_supervisor_error({:failed_to_start_child, _id, reason}),
    do: normalize_supervisor_error(reason)

  defp normalize_supervisor_error(:cleanup_unavailable), do: :cleanup_unavailable
  defp normalize_supervisor_error(:invalid_authority), do: :invalid_authority
  defp normalize_supervisor_error(_reason), do: :supervisor_unavailable

  defp normalize_init_error(:cleanup_capacity_exceeded), do: :cleanup_unavailable
  defp normalize_init_error(:cleanup_supervisor_unavailable), do: :cleanup_unavailable
  defp normalize_init_error(:supervisor_unavailable), do: :cleanup_unavailable
  defp normalize_init_error(:invalid_authority), do: :invalid_authority
  defp normalize_init_error(_reason), do: :cleanup_unavailable

  defp authenticated_owner?(caller_pid, %Redacted{} = provided, state) do
    caller_pid == state.owner_pid and
      Redacted.value(provided) === Redacted.value(state.owner_token) and
      Process.alive?(state.owner_pid)
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  defp authenticated_owner?(_caller_pid, _provided, _state), do: false

  defp public_outcome(:ok, _operation), do: :ok
  defp public_outcome({:ok, value}, _operation), do: {:ok, value}
  defp public_outcome({:error, :timeout}, :recv), do: {:error, :timeout}
  defp public_outcome({:error, :operation_timeout}, _operation), do: {:error, :owner_timeout}
  defp public_outcome({:error, :invalid_backend_meta}, :meta), do: {:error, :invalid_backend_meta}
  defp public_outcome({:error, _reason}, _operation), do: {:error, :backend_callback_failed}
  defp public_outcome(_outcome, _operation), do: {:error, :backend_callback_failed}

  defp successful_outcome?(:ok), do: true
  defp successful_outcome?({:ok, _value}), do: true
  defp successful_outcome?({:error, :timeout}), do: true
  defp successful_outcome?(_outcome), do: false

  defp terminal_outcome?(_outcome, :close), do: true
  defp terminal_outcome?({:error, :timeout}, :recv), do: false
  defp terminal_outcome?({:error, _reason}, _operation), do: true
  defp terminal_outcome?(_outcome, _operation), do: false

  defp expected_effects(operation, state) do
    if Redacted.value(state.route) == :none,
      do: [],
      else: Map.fetch!(@external_effects, operation)
  end

  defp close_error(:ok), do: nil
  defp close_error({:error, reason}), do: reason
  defp close_error(_reply), do: :backend_callback_failed

  defp safe_authority_call(fun) when is_function(fun, 0) do
    fun.()
  rescue
    _exception -> {:error, :authorization_failed}
  catch
    _kind, _reason -> {:error, :authorization_failed}
  end

  defp poison_state(state) do
    _ = safe_authority_call(fn -> EgressAuthority.poison(authority_cell(state)) end)
    %{state | poisoned: true}
  end

  defp add_close_waiter(state, from), do: %{state | close_waiters: [from | state.close_waiters]}

  defp put_cleanup_key(state, key) do
    %{state | cleanup_keys: Redacted.new(MapSet.put(cleanup_keys(state), key))}
  end

  defp delete_cleanup_key(state, key) do
    %{state | cleanup_keys: Redacted.new(MapSet.delete(cleanup_keys(state), key))}
  end

  defp cleanup_keys(state), do: Redacted.value(state.cleanup_keys)
  defp authority_cell(state), do: Redacted.value(state.authority_cell)
  defp lease_credential(state), do: Redacted.value(state.lease_credential)
  defp worker_credential(state), do: Redacted.value(state.worker_credential)

  defp bounded_cleanup_error(reason)
       when reason in [
              :invalid_cleanup,
              :duplicate_cleanup_key,
              :cleanup_capacity_exceeded,
              :provisional_cleanup_conflict,
              :provisional_cleanup_occupied,
              :unknown_cleanup_key,
              :lease_closing
            ],
       do: reason

  defp bounded_cleanup_error(_reason), do: :cleanup_unavailable

  defp valid_cleanup_key?(key), do: safe_external_size(key) <= @max_cleanup_key_bytes

  defp reserved_cleanup_key?({:voice_provisional_cleanup, _logical_key}), do: true
  defp reserved_cleanup_key?(_key), do: false

  defp owner_token_key(owner), do: {__MODULE__, :owner_token, owner}

  defp clear_close_timer(state) do
    cancel_timer(state.close_timer_ref)
    %{state | close_timer_ref: nil, close_timer_token: nil, close_deadline_ms: nil}
  end

  defp cancel_timer(ref) when is_reference(ref) do
    _ = Process.cancel_timer(ref)
    :ok
  end

  defp cancel_timer(_ref), do: :ok

  defp await_exact_down(pid, monitor_ref, timeout_ms) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    after
      timeout_ms ->
        Process.demonitor(monitor_ref, [:flush])
        :timeout
    end
  end

  defp safe_external_size(term) do
    :erlang.external_size(term)
  rescue
    _exception -> @max_initial_cleanups_bytes + 1
  catch
    _kind, _reason -> @max_initial_cleanups_bytes + 1
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
