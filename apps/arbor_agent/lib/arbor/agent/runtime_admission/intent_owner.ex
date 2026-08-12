defmodule Arbor.Agent.RuntimeAdmission.IntentOwner do
  @moduledoc """
  Supervised target-unique owner for one ordinary runtime-admission intent.

  Holds validated start opts, registers before external preparation, adopts
  through TaskStore by stable store_ref (never a captured store pid), and
  launches the fixed OrdinaryStartWorker only after adopt succeeds.

  Worker binding is owner-authenticated: the owner spawns a worker blocked on
  an unforgeable gate ref, binds that exact PID via TaskStore (caller must be
  this owner), then releases the gate. Survives worker death; removed only
  after authoritative settlement.
  """

  use GenServer

  alias Arbor.Agent.Orchestration.TaskStore
  alias Arbor.Agent.RuntimeAdmission.OrdinaryStartWorker

  @registry Arbor.Agent.RuntimeAdmissionRegistry
  @default_store TaskStore
  @default_task_supervisor Arbor.Agent.Orchestration.TaskSupervisor
  @adopt_retry_ms 50
  @max_adopt_retries 40
  @gate_release_timeout_ms 30_000

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

    case Registry.register(@registry, {:runtime_admission_owner, target}, %{
           intent_id: intent_id,
           fingerprint: fingerprint
         }) do
      {:ok, _} ->
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
          adopt_attempts: 0
        }

        send(self(), :try_adopt)
        {:ok, state}

      {:error, {:already_registered, _}} ->
        {:stop, :target_owner_taken}
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
  def handle_info(:try_adopt, state) do
    case adopt_with_store(state) do
      :ok ->
        state = %{state | adopted?: true, adopt_attempts: 0}
        state = maybe_launch_worker(state)
        {:noreply, state}

      {:error, :target_fenced} ->
        {:stop, :normal, state}

      {:error, :conflict} ->
        {:stop, :normal, state}

      {:error, :runtime_admission_not_ready} ->
        schedule_adopt_retry(state)

      {:error, :fence_not_ready} ->
        schedule_adopt_retry(state)

      {:error, :store_restart} ->
        schedule_adopt_retry(state)

      {:error, _other} ->
        schedule_adopt_retry(state)
    end
  end

  def handle_info({:DOWN, mon, :process, pid, _reason}, %{worker_mon: mon, worker_pid: pid} = state) do
    # Worker-down is source-authentic via TaskStore's monitor after bind.
    {:noreply, %{state | worker_pid: nil, worker_mon: nil, gate_ref: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = Registry.unregister(@registry, {:runtime_admission_owner, state.target_agent_id})
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
           worker_alive?: is_pid(Map.get(state, :worker_pid))
         }}
      ]
    ]
  end

  def format_status(_opts, status), do: status

  defp redact_fp(fp) when is_binary(fp) and byte_size(fp) > 12 do
    binary_part(fp, 0, 12) <> "…"
  end

  defp redact_fp(fp), do: fp

  defp schedule_adopt_retry(state) do
    attempts = Map.get(state, :adopt_attempts, 0) + 1

    if attempts > @max_adopt_retries do
      {:stop, :normal, state}
    else
      Process.send_after(self(), :try_adopt, @adopt_retry_ms)
      {:noreply, %{state | adopt_attempts: attempts}}
    end
  end

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

      _ ->
        schedule_launch_retry(state)
    end
  rescue
    _ ->
      schedule_launch_retry(state)
  catch
    :exit, _ ->
      schedule_launch_retry(state)
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

      {:error, _reason} ->
        if Process.alive?(worker_pid), do: Process.exit(worker_pid, :kill)
        schedule_launch_retry(state)
    end
  catch
    :exit, reason ->
      if Process.alive?(worker_pid), do: Process.exit(worker_pid, :kill)

      if store_restart_exit?(reason, state.store_ref) do
        schedule_launch_retry(state)
      else
        schedule_launch_retry(state)
      end
  end

  # Always schedule bounded retry so waiters never permanently stall after
  # launcher exceptions/exits/bind failures.
  defp schedule_launch_retry(state) do
    attempts = Map.get(state, :adopt_attempts, 0) + 1

    if attempts > @max_adopt_retries do
      state
    else
      Process.send_after(self(), :try_adopt, @adopt_retry_ms)
      %{state | adopt_attempts: attempts, worker_pid: nil, worker_mon: nil, gate_ref: nil}
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
