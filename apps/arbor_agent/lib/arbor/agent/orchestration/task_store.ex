defmodule Arbor.Agent.Orchestration.TaskStore do
  @moduledoc """
  In-memory async task registry for the shared orchestration facade.

  The store owns task lifecycle state and result retention. It does not decide
  authorization; callers perform capability checks before dispatching or reading.
  """

  use GenServer

  @default_name __MODULE__
  @default_task_supervisor Arbor.Agent.Orchestration.TaskSupervisor
  @default_runner Arbor.Agent.Orchestration.TaskRunner
  @default_max_tasks 1_000

  alias Arbor.Agent.Orchestration.TaskArtifacts

  @type task_id :: String.t()
  @type state_name :: :running | :waiting_approval | :done | :failed | :cancelled

  @type task_status :: %{
          task_id: task_id(),
          agent_id: String.t(),
          state: state_name(),
          current_step: String.t() | nil,
          waiting_on: String.t() | nil,
          started_at: DateTime.t(),
          updated_at: DateTime.t(),
          completed_at: DateTime.t() | nil,
          metadata: map()
        }

  @type task_result ::
          {:ok, map()}
          | {:error,
             :not_found
             | :not_ready
             | :cancelled
             | {:waiting_approval, String.t()}
             | {:failed, term()}}

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Dispatch an async task.

  Options:

    * `:name` - task store process name, for tests
    * `:runner` - module implementing `run/3`
    * `:task_id` - explicit id, for deterministic tests
    * `:metadata` - caller metadata copied into the task record
    * `:approval_answer_cap_id` - private temporary approval-answer capability id
  """
  @spec dispatch(String.t(), term(), keyword() | map()) :: {:ok, task_id()} | {:error, term()}
  def dispatch(agent_id, task, opts \\ []) do
    GenServer.call(store_name(opts), {:dispatch, agent_id, task, normalize_opts(opts)})
  end

  @doc "Return current task status."
  @spec status(task_id(), keyword() | map()) :: {:ok, task_status()} | {:error, :not_found}
  def status(task_id, opts \\ []) do
    GenServer.call(store_name(opts), {:status, task_id})
  end

  @doc "Return the completed task result."
  @spec result(task_id(), keyword() | map()) :: task_result()
  def result(task_id, opts \\ []) do
    GenServer.call(store_name(opts), {:result, task_id})
  end

  @doc "Cancel a running task."
  @spec cancel(task_id(), keyword() | map()) :: {:ok, task_status()} | {:error, term()}
  def cancel(task_id, opts \\ []) do
    GenServer.call(store_name(opts), {:cancel, task_id})
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       task_supervisor: Keyword.get(opts, :task_supervisor, @default_task_supervisor),
       runner: Keyword.get(opts, :runner, @default_runner),
       max_tasks: Keyword.get(opts, :max_tasks, @default_max_tasks),
       tasks: %{},
       refs: %{}
     }}
  end

  @impl true
  def handle_call({:dispatch, agent_id, task, opts}, _from, state) do
    task_id = task_id(opts)
    now = DateTime.utc_now()
    runner = Keyword.get(opts, :runner, state.runner)
    runner_opts = Keyword.put(opts, :task_id, task_id)

    task_ref =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        runner.run(agent_id, task, runner_opts)
      end)

    record = %{
      task_id: task_id,
      agent_id: agent_id,
      task: task,
      state: :running,
      current_step: "running",
      waiting_on: nil,
      result: nil,
      error: nil,
      pid: task_ref.pid,
      ref: task_ref.ref,
      started_at: now,
      updated_at: now,
      completed_at: nil,
      metadata: metadata(opts),
      approval_answer_cap_id: Keyword.get(opts, :approval_answer_cap_id),
      approval_answer_security_module:
        Keyword.get(opts, :approval_answer_security_module, Arbor.Security),
      approval_answer_revoke: Keyword.get(opts, :approval_answer_revoke)
    }

    next_state =
      state
      |> put_in([:tasks, task_id], record)
      |> put_in([:refs, task_ref.ref], task_id)
      |> prune_tasks()

    {:reply, {:ok, task_id}, next_state}
  rescue
    e ->
      {:reply, {:error, {:dispatch_failed, Exception.message(e)}}, state}
  catch
    :exit, reason ->
      {:reply, {:error, {:dispatch_exit, reason}}, state}
  end

  def handle_call({:status, task_id}, _from, state) do
    case Map.fetch(state.tasks, task_id) do
      {:ok, record} -> {:reply, {:ok, status_view(record)}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:result, task_id}, _from, state) do
    reply =
      case Map.fetch(state.tasks, task_id) do
        {:ok, %{state: :done, result: result}} ->
          {:ok, result}

        {:ok, %{state: :failed, error: error}} ->
          {:error, {:failed, error}}

        {:ok, %{state: :cancelled}} ->
          {:error, :cancelled}

        {:ok, %{state: :waiting_approval, waiting_on: approval_id}} ->
          {:error, {:waiting_approval, approval_id}}

        {:ok, _record} ->
          {:error, :not_ready}

        :error ->
          {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:cancel, task_id}, _from, state) do
    case Map.fetch(state.tasks, task_id) do
      {:ok, %{state: :running} = record} ->
        now = DateTime.utc_now()

        if is_pid(record.pid) and Process.alive?(record.pid) do
          Process.exit(record.pid, :kill)
        end

        cancelled_record =
          record
          |> Map.merge(%{
            state: :cancelled,
            current_step: "cancelled",
            waiting_on: nil,
            error: nil,
            updated_at: now,
            completed_at: now
          })
          |> revoke_approval_answer_capability()

        next_state =
          state
          |> put_in([:tasks, task_id], cancelled_record)
          |> remove_ref(record.ref)

        {:reply, {:ok, status_view(cancelled_record)}, next_state}

      {:ok, record} ->
        {:reply, {:error, {:not_running, record.state}}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case Map.fetch(state.refs, ref) do
      {:ok, task_id} ->
        {:noreply, complete_task(state, task_id, ref, result)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, :normal}, state) when is_reference(ref) do
    {:noreply, remove_ref(state, ref)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    case Map.fetch(state.refs, ref) do
      {:ok, task_id} ->
        now = DateTime.utc_now()

        state =
          update_in(state.tasks[task_id], fn
            nil ->
              nil

            record ->
              if record.state in [:done, :failed, :waiting_approval, :cancelled] do
                record
              else
                record
                |> Map.merge(%{
                  state: :failed,
                  current_step: "failed",
                  error: reason,
                  updated_at: now,
                  completed_at: now
                })
                |> revoke_approval_answer_capability()
              end
          end)

        {:noreply, remove_ref(state, ref)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp complete_task(state, task_id, ref, result) do
    now = DateTime.utc_now()

    state =
      update_in(state.tasks[task_id], fn
        nil ->
          nil

        record ->
          if record.state == :cancelled do
            record
          else
            record
            |> Map.merge(completion_fields(result, now))
            |> Map.put(:updated_at, now)
            |> maybe_revoke_completed_approval_answer_capability()
          end
      end)

    remove_ref(state, ref)
  end

  defp completion_fields({:ok, :pending_approval, approval_id}, _now) do
    %{
      state: :waiting_approval,
      current_step: "waiting_approval",
      waiting_on: approval_id
    }
  end

  defp completion_fields({:error, {:pending_approval, approval_id}}, _now) do
    %{
      state: :waiting_approval,
      current_step: "waiting_approval",
      waiting_on: approval_id
    }
  end

  defp completion_fields({:ok, result}, now) do
    %{
      state: :done,
      current_step: "done",
      result: normalize_result(result),
      completed_at: now
    }
  end

  defp completion_fields({:error, reason}, now) do
    %{
      state: :failed,
      current_step: "failed",
      error: reason,
      completed_at: now
    }
  end

  defp completion_fields(result, now) do
    %{
      state: :done,
      current_step: "done",
      result: normalize_result(result),
      completed_at: now
    }
  end

  defp normalize_result(result), do: TaskArtifacts.normalize(result)

  defp maybe_revoke_completed_approval_answer_capability(%{state: state} = record)
       when state in [:done, :failed, :cancelled] do
    revoke_approval_answer_capability(record)
  end

  defp maybe_revoke_completed_approval_answer_capability(record), do: record

  defp revoke_approval_answer_capability(%{approval_answer_cap_id: cap_id} = record)
       when is_binary(cap_id) and cap_id != "" do
    record
    |> revoke_approval_answer_capability(cap_id)
    |> Map.put(:approval_answer_cap_id, nil)
  end

  defp revoke_approval_answer_capability(record), do: record

  defp revoke_approval_answer_capability(%{approval_answer_revoke: revoke_fun} = record, cap_id)
       when is_function(revoke_fun, 1) do
    revoke_fun.(cap_id)
    record
  rescue
    _ -> record
  catch
    :exit, _ -> record
  end

  defp revoke_approval_answer_capability(
         %{approval_answer_security_module: module} = record,
         cap_id
       ) do
    if is_atom(module) and Code.ensure_loaded?(module) and function_exported?(module, :revoke, 1) do
      apply(module, :revoke, [cap_id])
    else
      :ok
    end

    record
  rescue
    _ -> record
  catch
    :exit, _ -> record
  end

  defp status_view(record) do
    %{
      task_id: record.task_id,
      agent_id: record.agent_id,
      state: record.state,
      current_step: record.current_step,
      waiting_on: record.waiting_on,
      started_at: record.started_at,
      updated_at: record.updated_at,
      completed_at: record.completed_at,
      metadata: record.metadata
    }
  end

  defp remove_ref(state, ref) do
    update_in(state.refs, &Map.delete(&1, ref))
  end

  defp prune_tasks(%{max_tasks: max_tasks, tasks: tasks} = state)
       when map_size(tasks) <= max_tasks do
    state
  end

  defp prune_tasks(%{max_tasks: max_tasks, tasks: tasks} = state) do
    completed =
      tasks
      |> Enum.filter(fn {_id, record} -> record.state in [:done, :failed, :cancelled] end)
      |> Enum.sort_by(fn {_id, record} -> record.updated_at end, DateTime)

    excess = max(map_size(tasks) - max_tasks, 0)

    prune_ids =
      completed
      |> Enum.take(excess)
      |> Enum.map(fn {id, _record} -> id end)

    update_in(state.tasks, &Map.drop(&1, prune_ids))
  end

  defp task_id(opts) do
    Keyword.get(opts, :task_id) ||
      "task_" <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp metadata(opts) do
    opts
    |> Keyword.get(:metadata, %{})
    |> case do
      metadata when is_map(metadata) -> metadata
      _ -> %{}
    end
  end

  defp store_name(opts) do
    opts
    |> opt(:name, @default_name)
  end

  defp normalize_opts(opts) when is_list(opts), do: opts
  defp normalize_opts(opts) when is_map(opts), do: Map.to_list(opts)
  defp normalize_opts(_opts), do: []

  defp opt(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)

  defp opt(opts, key, default) when is_map(opts),
    do: Map.get(opts, key, Map.get(opts, to_string(key), default))

  defp opt(_opts, _key, default), do: default
end
