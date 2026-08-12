defmodule Arbor.Agent.RuntimeAdmission.IntentOwner do
  @moduledoc """
  Supervised target-unique owner for one ordinary runtime-admission intent.

  Holds validated start opts, registers before external preparation, binds
  through TaskStore with an unforgeable launch_ref in `init/1` (so start_child
  cannot commit an unbound child), adopts via stable store_ref, and launches
  the fixed OrdinaryStartWorker only after adopt succeeds.

  Adoption retries use a per-attempt self-message reference. Worker binding is
  owner-authenticated: the owner spawns a worker blocked on an unforgeable gate
  ref, binds that exact PID via TaskStore, then releases the gate.
  """

  use GenServer

  alias Arbor.Agent.Orchestration.TaskStore
  alias Arbor.Agent.RuntimeAdmission.IntentCore
  alias Arbor.Agent.RuntimeAdmission.OrdinaryStartWorker

  @registry Arbor.Agent.RuntimeAdmissionRegistry
  @default_store TaskStore
  @default_task_supervisor Arbor.Agent.Orchestration.TaskSupervisor
  @adopt_retry_ms 50
  @max_adopt_retries 40
  @gate_release_timeout_ms 30_000
  @launch_bind_timeout_ms 2_000

  @doc false
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Snapshot for restart reconcile (bounded scalars + owner pid)."
  @spec snapshot(pid()) ::
          {:ok, map()} | {:error, term()}
  def snapshot(pid) when is_pid(pid) do
    GenServer.call(pid, :snapshot, 1_000)
  catch
    :exit, reason -> {:error, reason}
  end

  @doc "Validated keyword opts held by this owner."
  @spec validated_opts(pid()) :: {:ok, keyword()} | {:error, term()}
  def validated_opts(pid) when is_pid(pid) do
    GenServer.call(pid, :validated_opts, 1_000)
  catch
    :exit, reason -> {:error, reason}
  end

  @impl true
  def init(opts) do
    intent_id = Keyword.fetch!(opts, :intent_id)
    target = Keyword.fetch!(opts, :target_agent_id)
    fingerprint = Keyword.fetch!(opts, :fingerprint)
    validated_opts = Keyword.fetch!(opts, :validated_opts)
    store_ref = Keyword.get(opts, :store_ref, @default_store)
    task_supervisor = Keyword.get(opts, :task_supervisor, @default_task_supervisor)
    launch_ref = Keyword.get(opts, :launch_ref)

    case launch_ref do
      ref when is_reference(ref) ->
        register_and_bind_owner(
          intent_id,
          target,
          fingerprint,
          validated_opts,
          store_ref,
          task_supervisor,
          ref
        )

      _ ->
        {:stop, {:launch_bind_failed, :missing_launch_ref}}
    end
  end

  defp register_and_bind_owner(
         intent_id,
         target,
         fingerprint,
         validated_opts,
         store_ref,
         task_supervisor,
         launch_ref
       ) do
    case Registry.register(@registry, {:runtime_admission_owner, target}, %{
           intent_id: intent_id,
           fingerprint: fingerprint
         }) do
      {:ok, _} ->
        bind_registered_owner(
          intent_id,
          target,
          fingerprint,
          validated_opts,
          store_ref,
          task_supervisor,
          launch_ref
        )

      {:error, {:already_registered, _}} ->
        {:stop, :target_owner_taken}
    end
  end

  defp bind_registered_owner(
         intent_id,
         target,
         fingerprint,
         validated_opts,
         store_ref,
         task_supervisor,
         launch_ref
       ) do
    case bind_launch_with_store(store_ref, target, intent_id, fingerprint, launch_ref) do
      :ok ->
        adopt_msg_ref = make_ref()

        state = %{
          intent_id: intent_id,
          target_agent_id: target,
          fingerprint: fingerprint,
          validated_opts: validated_opts,
          store_ref: store_ref,
          task_supervisor: task_supervisor,
          adopted?: false,
          worker_pid: nil,
          worker_mon: nil,
          gate_ref: nil,
          adopt_attempts: 0,
          launch_attempts: 0,
          adopt_msg_ref: adopt_msg_ref,
          adopt_retry_timer: nil
        }

        send(self(), {:try_adopt, adopt_msg_ref})
        {:ok, state}

      {:error, reason} ->
        _ = Registry.unregister(@registry, {:runtime_admission_owner, target})
        {:stop, {:launch_bind_failed, IntentCore.redact_error_reason(reason)}}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply,
     {:ok,
      %{
        intent_id: state.intent_id,
        target_agent_id: state.target_agent_id,
        fingerprint: state.fingerprint,
        owner_pid: self()
      }}, state}
  end

  def handle_call(:validated_opts, _from, state) do
    {:reply, {:ok, state.validated_opts}, state}
  end

  @impl true
  def handle_info({:try_adopt, ref}, %{adopt_msg_ref: ref} = state) when is_reference(ref) do
    # Consume the current attempt ref so duplicates/stale copies are inert.
    state = %{state | adopt_msg_ref: nil, adopt_retry_timer: nil}

    case adopt_with_store(state) do
      :ok ->
        state = %{state | adopted?: true, adopt_attempts: 0}
        state = maybe_launch_worker(state)
        {:noreply, state}

      {:error, :target_fenced} ->
        {:stop, :target_fenced, state}

      {:error, :conflict} ->
        {:stop, :conflict, state}

      {:error, reason} ->
        if IntentCore.retryable_adopt_error?(reason) do
          schedule_adopt_retry(state)
        else
          {:stop, {:adopt_failed, reason}, state}
        end
    end
  end

  def handle_info({:try_adopt, _stale}, state) do
    # Plain/stale/foreign/duplicated retry messages cannot spend budget.
    {:noreply, state}
  end

  def handle_info(:try_adopt, state) do
    # Legacy bare atom is never authorized.
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, mon, :process, pid, _reason},
        %{worker_mon: mon, worker_pid: pid} = state
      ) do
    # Worker-down is source-authentic via TaskStore's monitor after bind.
    {:noreply, %{state | worker_pid: nil, worker_mon: nil, gate_ref: nil}}
  end

  def handle_info({:stop_typed, reason}, state) do
    {:stop, reason, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_map(state) do
      _ = Registry.unregister(@registry, {:runtime_admission_owner, state.target_agent_id})
    end

    :ok
  end

  @impl true
  def format_status(_opts, [_pdict, state]) when is_map(state) do
    [
      data: [
        {~c"State",
         %{
           intent_id: Map.get(state, :intent_id),
           target_agent_id: Map.get(state, :target_agent_id),
           fingerprint: redact_fp(Map.get(state, :fingerprint)),
           adopted?: Map.get(state, :adopted?),
           worker_alive?: is_pid(Map.get(state, :worker_pid)),
           adopt_attempts: Map.get(state, :adopt_attempts),
           launch_attempts: Map.get(state, :launch_attempts)
         }}
      ]
    ]
  end

  def format_status(_opts, status), do: status

  defp redact_fp(fp) when is_binary(fp) and byte_size(fp) > 12 do
    binary_part(fp, 0, 12) <> "…"
  end

  defp redact_fp(fp), do: fp

  defp bind_launch_with_store(store_ref, target, intent_id, fingerprint, launch_ref) do
    TaskStore.bind_runtime_admission_launch(
      target,
      intent_id,
      fingerprint,
      launch_ref,
      name: store_ref,
      timeout: @launch_bind_timeout_ms
    )
  catch
    :exit, reason ->
      if store_restart_exit?(reason, store_ref),
        do: {:error, :store_restart},
        else: {:error, :bind_exit}
  end

  defp schedule_adopt_retry(state) do
    attempts = Map.get(state, :adopt_attempts, 0) + 1

    if attempts > @max_adopt_retries do
      {:stop, :adopt_retry_exhausted, state}
    else
      cancel_adopt_retry_timer(state)
      ref = make_ref()
      timer = Process.send_after(self(), {:try_adopt, ref}, @adopt_retry_ms)

      {:noreply,
       %{state | adopt_attempts: attempts, adopt_msg_ref: ref, adopt_retry_timer: timer}}
    end
  end

  defp cancel_adopt_retry_timer(%{adopt_retry_timer: timer}) when is_reference(timer) do
    _ = Process.cancel_timer(timer)
    :ok
  end

  defp cancel_adopt_retry_timer(_), do: :ok

  defp adopt_with_store(state) do
    TaskStore.adopt_runtime_admission_owner(
      state.target_agent_id,
      state.intent_id,
      state.fingerprint,
      name: state.store_ref
    )
  catch
    :exit, reason ->
      if store_restart_exit?(reason, state.store_ref),
        do: {:error, :store_restart},
        else: exit(reason)
  end

  defp maybe_launch_worker(%{adopted?: true, worker_pid: nil} = state) do
    gate_ref = make_ref()

    worker_args = %{
      intent_id: state.intent_id,
      target_agent_id: state.target_agent_id,
      fingerprint: state.fingerprint,
      validated_opts: state.validated_opts,
      store_ref: state.store_ref,
      gate_ref: gate_ref,
      gate_timeout_ms: @gate_release_timeout_ms
    }

    case Task.Supervisor.start_child(
           state.task_supervisor,
           OrdinaryStartWorker,
           :run,
           [worker_args],
           []
         ) do
      {:ok, worker_pid} when is_pid(worker_pid) ->
        bind_and_release(state, worker_pid, gate_ref)

      {:ok, worker_pid, _} when is_pid(worker_pid) ->
        bind_and_release(state, worker_pid, gate_ref)

      {:error, reason} ->
        classified = IntentCore.classify_start_child_error(reason)

        if IntentCore.retryable_launch_failure?(classified) do
          schedule_launch_retry(state)
        else
          stop_typed(state, {:launch_failed, IntentCore.redact_error_reason(classified)})
        end

      other ->
        classified = IntentCore.classify_start_child_error(other)
        stop_typed(state, {:launch_failed, IntentCore.redact_error_reason(classified)})
    end
  rescue
    e ->
      # Bound/redacted — never leak full exception text unbounded.
      stop_typed(state, {:launch_exception, IntentCore.redact_error_reason(Exception.message(e))})
  catch
    :exit, reason ->
      if store_restart_exit?(reason, state.store_ref) do
        schedule_launch_retry(state)
      else
        # Unrelated exit — do not swallow with infinite retry.
        exit(reason)
      end
  end

  defp maybe_launch_worker(state), do: state

  defp bind_and_release(state, worker_pid, gate_ref) do
    case TaskStore.bind_runtime_admission_worker(
           state.target_agent_id,
           state.intent_id,
           state.fingerprint,
           worker_pid,
           name: state.store_ref
         ) do
      :ok ->
        send(worker_pid, {:runtime_admission_release, gate_ref})
        mon = Process.monitor(worker_pid)
        %{state | worker_pid: worker_pid, worker_mon: mon, gate_ref: gate_ref}

      {:error, reason} when reason in [:not_owner, :conflict, :not_found] ->
        if Process.alive?(worker_pid), do: Process.exit(worker_pid, :kill)
        # Auth/bind errors are not collision retries.
        send(self(), {:stop_typed, {:bind_failed, reason}})
        %{state | worker_pid: nil, worker_mon: nil, gate_ref: nil}

      {:error, reason} ->
        if Process.alive?(worker_pid), do: Process.exit(worker_pid, :kill)

        if IntentCore.retryable_launch_failure?(reason) do
          schedule_launch_retry(state)
        else
          send(self(), {:stop_typed, {:bind_failed, reason}})
          %{state | worker_pid: nil, worker_mon: nil, gate_ref: nil}
        end
    end
  catch
    :exit, reason ->
      if Process.alive?(worker_pid), do: Process.exit(worker_pid, :kill)

      if store_restart_exit?(reason, state.store_ref) do
        schedule_launch_retry(state)
      else
        # Unrelated exit — stop typed so TaskStore owner DOWN finalizes waiters.
        send(self(), {:stop_typed, {:bind_exit, :unrelated}})
        %{state | worker_pid: nil, worker_mon: nil, gate_ref: nil}
      end
  end

  defp stop_typed(state, reason) do
    send(self(), {:stop_typed, reason})
    %{state | worker_pid: nil, worker_mon: nil, gate_ref: nil}
  end

  defp schedule_launch_retry(state) do
    attempts = Map.get(state, :launch_attempts, 0) + 1

    if attempts > @max_adopt_retries do
      # Must stop so TaskStore observes owner DOWN and releases waiters.
      send(self(), {:stop_typed, :launch_retry_exhausted})
      %{state | launch_attempts: attempts, worker_pid: nil, worker_mon: nil, gate_ref: nil}
    else
      cancel_adopt_retry_timer(state)
      ref = make_ref()
      timer = Process.send_after(self(), {:try_adopt, ref}, @adopt_retry_ms)

      %{
        state
        | launch_attempts: attempts,
          worker_pid: nil,
          worker_mon: nil,
          gate_ref: nil,
          adopt_msg_ref: ref,
          adopt_retry_timer: timer
      }
    end
  end

  defp store_restart_exit?({{:nodedown, _}, {GenServer, :call, args}}, store_ref),
    do: call_targets_store?(args, store_ref)

  defp store_restart_exit?({:noproc, {GenServer, :call, args}}, store_ref),
    do: call_targets_store?(args, store_ref)

  defp store_restart_exit?({reason, {GenServer, :call, args}}, store_ref)
       when reason in [:normal, :shutdown, :killed, :noproc] do
    call_targets_store?(args, store_ref)
  end

  defp store_restart_exit?({{:shutdown, _}, {GenServer, :call, args}}, store_ref),
    do: call_targets_store?(args, store_ref)

  defp store_restart_exit?(_, _), do: false

  defp call_targets_store?([store_ref | _], store_ref), do: true
  defp call_targets_store?(_, _), do: false
end
