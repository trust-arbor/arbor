defmodule Arbor.Consensus.ConsultationFinalizer do
  @moduledoc """
  Supervised, temporary owner of ConsultationLog timeout terminalization.

  Started at run-creation time under the arbor_consensus supervision tree,
  unlinked from the consult caller, with a unique per-run child id and
  `restart: :temporary`. After the consultation's absolute deadline it
  performs idempotent `ConsultationLog.finalize_run/2` compare-and-set
  attempts from `running` to the timeout outcome (`failed`).

  Terminalization is bounded, supervised, best-effort CAS. Each
  CAS/persistence attempt runs in a bounded supervised task; the
  GenServer loop never makes a bare unbounded persist call. Retries
  follow the finalize_run taxonomy until the run's deadline plus grace:

  - `{:ok, :transitioned}` or `{:ok, {:already_terminal, status}}` — exit
    normally (the row is terminal either way)
  - `{:error, :not_found}` — the row may not be created yet; retry, and
    never conclude terminal from a missing row
  - `{:error, {:persistence, reason}}` — retry
  - attempts exhausted — log loudly (run id and last error) and exit

  The first attempt always runs with a full bounded budget even when
  `grace_ms` is zero, so every accepted grace value yields at least one
  terminalization attempt after the deadline.

  A stored row may remain `running` only if persistence is unavailable
  for that whole window. No stronger durability promise is made.

  Because the child is temporary it is never restarted after a normal
  completion, a timeout terminalization, or a give-up. The consult's
  normal completion path uses the same `finalize_run/2` to CAS `running`
  to `completed`. Exactly one side wins when both persist.
  """

  use GenServer

  require Logger

  alias Arbor.Consensus.ConsultationLog

  @default_grace_ms 5_000
  @default_persist_timeout_ms 5_000
  @max_persist_timeout_ms 5_000
  @min_backoff_ms 50
  @max_backoff_ms 500

  @doc "Default grace after the consult deadline before giving up persist retries."
  @spec default_grace_ms() :: pos_integer()
  def default_grace_ms, do: @default_grace_ms

  @doc "Default wall-clock budget for one supervised persist attempt."
  @spec default_persist_timeout_ms() :: pos_integer()
  def default_persist_timeout_ms, do: @default_persist_timeout_ms

  @doc "Conservative upper bound for one persist attempt (milliseconds)."
  @spec max_persist_timeout_ms() :: pos_integer()
  def max_persist_timeout_ms, do: @max_persist_timeout_ms

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    run_id = Keyword.fetch!(opts, :run_id)

    %{
      id: {__MODULE__, run_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) when is_list(opts) do
    # Trap exits so stopping the linked per-run Task.Supervisor during
    # terminate/2 cannot backwash a :shutdown exit signal that would
    # override our :normal stop, and so its abnormal death is observable.
    Process.flag(:trap_exit, true)
    run_id = Keyword.fetch!(opts, :run_id)
    deadline = Keyword.fetch!(opts, :deadline_unix_ms)
    log = Keyword.get(opts, :consultation_log, ConsultationLog)
    grace_ms = Keyword.get(opts, :grace_ms, configured_grace_ms())

    persist_timeout_ms =
      opts
      |> Keyword.get(:persist_timeout_ms, @default_persist_timeout_ms)
      |> cap_persist_timeout_ms()

    {:ok, task_sup} = Task.Supervisor.start_link()

    wait_ms = max(deadline - System.system_time(:millisecond), 0)
    Process.send_after(self(), :timeout_cas, wait_ms)

    {:ok,
     %{
       run_id: run_id,
       log: log,
       deadline_unix_ms: deadline,
       grace_ms: grace_ms,
       persist_timeout_ms: persist_timeout_ms,
       task_sup: task_sup,
       persist_task: nil,
       persist_timer: nil,
       attempt: 0,
       last_error: nil
     }}
  end

  @impl true
  def handle_info(:timeout_cas, state) do
    case start_persist_attempt(state) do
      {:stop, new_state} -> {:stop, :normal, new_state}
      {:noreply, new_state} -> {:noreply, new_state}
    end
  end

  def handle_info({:persist_timeout, ref}, %{persist_task: %Task{ref: ref}} = state) do
    _ = Task.shutdown(state.persist_task, :brutal_kill)

    retry_or_give_up(%{
      state
      | persist_task: nil,
        persist_timer: nil,
        last_error: {:persist_timeout, :budget_exceeded}
    })
  end

  def handle_info({:persist_timeout, _ref}, state), do: {:noreply, state}

  def handle_info({ref, result}, %{persist_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    cancel_timer(state.persist_timer)
    state = %{state | persist_task: nil, persist_timer: nil, last_error: result}

    case result do
      {:ok, :transitioned} -> {:stop, :normal, state}
      {:ok, {:already_terminal, _status}} -> {:stop, :normal, state}
      {:error, :not_found} -> retry_or_give_up(state)
      {:error, {:persistence, _reason}} -> retry_or_give_up(state)
      {:error, _reason} -> retry_or_give_up(state)
      _unknown -> retry_or_give_up(state)
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{persist_task: %Task{ref: ref}} = state) do
    cancel_timer(state.persist_timer)

    retry_or_give_up(%{
      state
      | persist_task: nil,
        persist_timer: nil,
        last_error: {:persist_task_exit, reason}
    })
  end

  def handle_info({:EXIT, pid, reason}, %{task_sup: pid} = state) when reason != :normal do
    # Our per-run Task.Supervisor died abnormally; no persist attempt can
    # run without it. Give up loudly rather than idle silently.
    give_up(%{state | last_error: {:task_supervisor_exit, reason}})
    {:stop, reason, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if match?(%Task{}, state[:persist_task]) do
      _ = Task.shutdown(state.persist_task, :brutal_kill)
    end

    if is_pid(state[:task_sup]) and Process.alive?(state.task_sup) do
      Supervisor.stop(state.task_sup, :shutdown, 1_000)
    end

    :ok
  end

  defp start_persist_attempt(state) do
    # The FIRST attempt always runs with a full bounded budget, even when
    # grace is zero and the remaining window is already exhausted — a zero
    # grace must never mean zero terminalization attempts. Retries after
    # the first attempt stay bounded by deadline + grace.
    budget =
      if state.attempt == 0 do
        max(persist_budget_ms(state), state.persist_timeout_ms)
      else
        persist_budget_ms(state)
      end

    if budget <= 0 do
      give_up(state)
      {:stop, state}
    else
      task =
        Task.Supervisor.async_nolink(state.task_sup, fn ->
          try do
            state.log.finalize_run(state.run_id, {:error, :timeout})
          rescue
            exception -> {:error, {:persist_failed, exception.__struct__}}
          catch
            kind, reason -> {:error, {:persist_failed, {kind, reason}}}
          end
        end)

      timer = Process.send_after(self(), {:persist_timeout, task.ref}, budget)
      {:noreply, %{state | persist_task: task, persist_timer: timer, attempt: state.attempt + 1}}
    end
  end

  defp retry_or_give_up(state) do
    remaining = remaining_until_give_up(state)

    if remaining <= 0 do
      give_up(state)
      {:stop, :normal, state}
    else
      Process.send_after(self(), :timeout_cas, backoff_ms(state.attempt, remaining))
      {:noreply, state}
    end
  end

  defp give_up(state) do
    Logger.error(
      "ConsultationFinalizer: giving up terminalizing run #{state.run_id} after #{state.attempt} bounded persist attempts last_error=#{inspect(state.last_error)}"
    )
  end

  defp persist_budget_ms(state) do
    remaining = remaining_until_give_up(state)
    max(min(state.persist_timeout_ms, remaining), 0)
  end

  defp remaining_until_give_up(state) do
    max(state.deadline_unix_ms + state.grace_ms - System.system_time(:millisecond), 0)
  end

  defp backoff_ms(attempt, remaining) do
    delay = min(@max_backoff_ms, @min_backoff_ms * Integer.pow(2, max(attempt - 1, 0)))
    min(delay, remaining)
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(ref) do
    Process.cancel_timer(ref)
    :ok
  end

  defp cap_persist_timeout_ms(timeout)
       when is_integer(timeout) and timeout > 0 do
    min(timeout, @max_persist_timeout_ms)
  end

  defp cap_persist_timeout_ms(_timeout), do: @default_persist_timeout_ms

  defp configured_grace_ms do
    case Application.get_env(:arbor_consensus, :finalizer_grace_ms, @default_grace_ms) do
      grace when is_integer(grace) and grace >= 0 -> grace
      _ -> @default_grace_ms
    end
  end
end

defmodule Arbor.Consensus.ConsultationFinalizer.Supervisor do
  @moduledoc """
  DynamicSupervisor for per-run ConsultationFinalizer processes.

  Children are started under the arbor_consensus tree, are never
  linked to the consult caller, and use the finalizer's temporary
  per-run child_spec.
  """

  use DynamicSupervisor

  alias Arbor.Consensus.ConsultationFinalizer

  @doc "Start the finalizer supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc """
  Start a timeout finalizer for a persisted consultation run.

  Not linked to the caller. Returns `{:error, :supervisor_unavailable}`
  when the arbor_consensus finalizer supervisor is not running.
  """
  @spec start_finalizer(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_finalizer(opts) when is_list(opts) do
    start_finalizer(__MODULE__, opts)
  end

  @spec start_finalizer(Supervisor.supervisor(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_finalizer(supervisor, opts) when is_list(opts) do
    spec = ConsultationFinalizer.child_spec(opts)

    case DynamicSupervisor.start_child(supervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _info} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  rescue
    ArgumentError -> {:error, :supervisor_unavailable}
  catch
    :exit, {:noproc, _info} -> {:error, :supervisor_unavailable}
    :exit, {:normal, _info} -> {:error, :supervisor_unavailable}
    :exit, _reason -> {:error, :supervisor_unavailable}
  end

  @doc "Stop a finalizer if it is still alive. Best-effort."
  @spec stop_finalizer(pid() | nil) :: :ok
  def stop_finalizer(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  def stop_finalizer(_pid), do: :ok
end
