defmodule Arbor.Agent.Orchestration.TaskStore do
  @moduledoc """
  In-memory async task registry for the shared orchestration facade.

  The store owns task lifecycle state and result retention. It does not decide
  authorization; callers perform capability checks before dispatching or reading.

  ## Executor selection

  Before spawning work, the store selects an executor:

  * plain strings and legacy maps (`input` / `prompt` / `message` / `task`) use
    `Arbor.Agent.Config.default_task_executor/0` (validated before spawn)
  * structured maps with an explicit `kind` resolve a configured executor via
    `Arbor.Agent.Config` (fail closed on blank/unknown/invalid mappings)
  * per-dispatch `:runner` and store-start `:runner` overrides remain a
    test/internal compatibility seam and skip cross-library progress/cancel
    callbacks

  When there is no explicit runner override, **both** the configured default
  path and the explicit-kind path use the JSON-clean boundary: plain string
  tasks remain strings, maps are string-keyed JSON, and only `task_id` /
  `timeout` / `caller_id` / `metadata` are forwarded. Private TaskStore
  options never cross that boundary. Trusted explicit runner overrides may
  still receive full keyword opts. Non-JSON values, structs, PIDs, functions,
  references, unsupported atoms, and conflicting kind declarations fail before
  any task process starts.

  Optional `task_status/2` and `cancel_task/2` callbacks are best-effort and
  time-bounded under the task supervisor (see Config
  `executor_callback_timeout_ms/0`); hung callbacks are killed and status falls
  back to the stored view while cancel continues with the turn bridge + hard kill.
  """

  use GenServer

  @default_name __MODULE__
  @default_task_supervisor Arbor.Agent.Orchestration.TaskSupervisor
  @default_runner Arbor.Agent.Orchestration.TaskRunner
  @default_max_tasks 1_000

  alias Arbor.Agent.Config
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
    * `:runner` - module implementing `run/3` (test/internal override)
    * `:task_id` - explicit id, for deterministic tests
    * `:metadata` - caller metadata copied into the task record
    * `:timeout` - optional timeout forwarded in JSON-clean executor context
    * `:caller_id` - optional caller id forwarded in JSON-clean executor context
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
       # When true, store-level `:runner` overrides kind-based Config selection.
       runner_override: Keyword.has_key?(opts, :runner),
       max_tasks: Keyword.get(opts, :max_tasks, @default_max_tasks),
       executor_callback_timeout_ms:
         Keyword.get(opts, :executor_callback_timeout_ms, Config.executor_callback_timeout_ms()),
       # Arity-2: (agent_id, task_id) — task-scoped Session cancel bridge.
       cancel_turn: Keyword.get(opts, :cancel_turn, &default_cancel_turn/2),
       tasks: %{},
       refs: %{}
     }}
  end

  @impl true
  def handle_call({:dispatch, agent_id, task, opts}, _from, state) do
    task_id = task_id(opts)

    case prepare_dispatch(task, opts, state, task_id) do
      {:ok, runner, context_mode, dispatch_task, runner_context} ->
        now = DateTime.utc_now()

        task_ref =
          Task.Supervisor.async_nolink(state.task_supervisor, fn ->
            runner.run(agent_id, dispatch_task, runner_context)
          end)

        record = %{
          task_id: task_id,
          agent_id: agent_id,
          task: dispatch_task,
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
          executor: runner,
          context_mode: context_mode,
          context: runner_context,
          approval_answer_cap_id: Keyword.get(opts, :approval_answer_cap_id),
          approval_answer_security_module:
            Keyword.get(opts, :approval_answer_security_module, Arbor.Security),
          approval_answer_revoke: Keyword.get(opts, :approval_answer_revoke),
          cancel_turn: Keyword.get(opts, :cancel_turn)
        }

        next_state =
          state
          |> put_in([:tasks, task_id], record)
          |> put_in([:refs, task_ref.ref], task_id)
          |> prune_tasks()

        {:reply, {:ok, task_id}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  rescue
    e ->
      {:reply, {:error, {:dispatch_failed, Exception.message(e)}}, state}
  catch
    :exit, reason ->
      {:reply, {:error, {:dispatch_exit, reason}}, state}
  end

  def handle_call({:status, task_id}, _from, state) do
    case Map.fetch(state.tasks, task_id) do
      {:ok, record} ->
        {:reply, {:ok, project_status(record, state)}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
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

        # Configured executors: cooperative cancel_task/2 first (bounded best-effort).
        maybe_cancel_executor(record, state)

        # Root cleanup: cancel the agent turn *before* killing the TaskRunner
        # wrapper. The real work lives in Orchestrator.Session (and ACP/worktree
        # owners under that turn). Process.exit(..., :kill) skips try/after, so
        # propagation must happen from this surviving store process.
        cancel_active_turn(record, state)

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

  defp cancel_active_turn(record, state) do
    cancel_fun =
      case Map.get(record, :cancel_turn) do
        fun when is_function(fun, 2) -> fun
        _ -> state.cancel_turn
      end

    if is_function(cancel_fun, 2) do
      cancel_fun.(record.agent_id, record.task_id)
    else
      :ok
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # Default: SessionManager facade → Session.cancel_task/2 (task-scoped bridge).
  defp default_cancel_turn(agent_id, task_id)
       when is_binary(agent_id) and agent_id != "" and is_binary(task_id) and task_id != "" do
    session_manager =
      Application.get_env(:arbor_agent, :session_manager, Arbor.Agent.SessionManager)

    if is_atom(session_manager) and Code.ensure_loaded?(session_manager) and
         function_exported?(session_manager, :cancel_task, 2) do
      apply(session_manager, :cancel_task, [agent_id, task_id])
    else
      :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp default_cancel_turn(_agent_id, _task_id), do: :ok

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

  defp project_status(%{state: :running, context_mode: :json_clean} = record, state) do
    status = status_view(record)
    merge_executor_progress(status, record, state)
  end

  defp project_status(record, _state), do: status_view(record)

  defp merge_executor_progress(status, record, state) do
    module = Map.get(record, :executor)
    context = Map.get(record, :context)
    agent_id = Map.get(record, :agent_id)

    if is_atom(module) and is_map(context) and is_binary(agent_id) and
         Code.ensure_loaded?(module) and function_exported?(module, :task_status, 2) do
      case call_executor_callback(state, fn -> module.task_status(agent_id, context) end) do
        {:ok, progress} ->
          case validate_progress(progress) do
            {:ok, clean_progress} ->
              status
              |> put_projected_field(:current_step, clean_progress)
              |> put_projected_field(:waiting_on, clean_progress)

            {:error, _} ->
              status
          end

        _ ->
          status
      end
    else
      status
    end
  end

  defp put_projected_field(status, field, progress) when is_map(progress) do
    value =
      Map.get(progress, Atom.to_string(field), Map.get(progress, field, :__missing__))

    case value do
      :__missing__ ->
        status

      projected when is_binary(projected) or is_nil(projected) ->
        Map.put(status, field, projected)

      _ ->
        status
    end
  end

  defp put_projected_field(status, _field, _progress), do: status

  defp validate_progress(progress) when is_map(progress) and not is_struct(progress) do
    case canonicalize_and_roundtrip(progress) do
      {:ok, clean} -> {:ok, clean}
      {:error, _reason} -> {:error, :non_json_progress}
    end
  end

  defp validate_progress(_progress), do: {:error, :invalid_progress}

  defp maybe_cancel_executor(%{context_mode: :json_clean} = record, state) do
    module = Map.get(record, :executor)
    context = Map.get(record, :context)
    agent_id = Map.get(record, :agent_id)

    if is_atom(module) and is_map(context) and is_binary(agent_id) and
         Code.ensure_loaded?(module) and function_exported?(module, :cancel_task, 2) do
      _ = call_executor_callback(state, fn -> module.cancel_task(agent_id, context) end)
    end

    :ok
  end

  defp maybe_cancel_executor(_record, _state), do: :ok

  # Bounded best-effort: run optional executor callbacks under the task
  # supervisor so a hung callback cannot freeze status or block cancellation.
  defp call_executor_callback(state, fun) when is_function(fun, 0) do
    timeout = Map.get(state, :executor_callback_timeout_ms, Config.executor_callback_timeout_ms())
    supervisor = Map.fetch!(state, :task_supervisor)

    # Rescue/catch inside the task so raises do not log as Task.Supervisor
    # crashes; timeouts still need brutal kill of a live process.
    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        try do
          fun.()
        rescue
          _ -> {:error, :executor_callback_exception}
        catch
          :exit, _ -> {:error, :executor_callback_exit}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, _reason} ->
        {:error, :executor_callback_exit}

      nil ->
        {:error, :executor_callback_timeout}
    end
  rescue
    _ -> {:error, :executor_callback_failed}
  catch
    :exit, _ -> {:error, :executor_callback_exit}
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

  # ---------------------------------------------------------------------------
  # Executor selection + JSON-clean boundary
  # ---------------------------------------------------------------------------

  defp prepare_dispatch(task, opts, state, task_id) do
    with {:ok, runner, context_mode} <- resolve_executor(task, opts, state) do
      case context_mode do
        :json_clean ->
          with {:ok, clean_task} <- canonicalize_and_validate_task(task),
               {:ok, clean_context} <- build_and_validate_json_context(opts, task_id) do
            {:ok, runner, :json_clean, clean_task, clean_context}
          end

        :full_opts ->
          {:ok, runner, :full_opts, task, Keyword.put(opts, :task_id, task_id)}
      end
    end
  end

  defp resolve_executor(task, opts, state) do
    cond do
      # Trusted explicit runner overrides may receive full keyword opts.
      Keyword.has_key?(opts, :runner) ->
        {:ok, Keyword.fetch!(opts, :runner), :full_opts}

      state.runner_override ->
        {:ok, state.runner, :full_opts}

      true ->
        # Configured default and explicit-kind paths both use JSON-clean.
        case explicit_task_kind(task) do
          :none ->
            case Config.validated_default_task_executor() do
              {:ok, module} -> {:ok, module, :json_clean}
              {:error, _reason} = error -> error
            end

          {:ok, kind} ->
            case Config.task_executor(kind) do
              {:ok, module} -> {:ok, module, :json_clean}
              {:error, _reason} = error -> error
            end

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp explicit_task_kind(task) when is_map(task) do
    atom_kind = Map.fetch(task, :kind)
    string_kind = Map.fetch(task, "kind")

    case {atom_kind, string_kind} do
      {{:ok, atom_raw}, {:ok, string_raw}} ->
        with {:ok, atom_normalized} <- Config.normalize_kind(atom_raw),
             {:ok, string_normalized} <- Config.normalize_kind(string_raw) do
          if atom_normalized == string_normalized do
            {:ok, atom_normalized}
          else
            {:error, :conflicting_task_kind}
          end
        end

      {{:ok, raw}, :error} ->
        Config.normalize_kind(raw)

      {:error, {:ok, raw}} ->
        Config.normalize_kind(raw)

      {:error, :error} ->
        :none
    end
  end

  defp explicit_task_kind(_task), do: :none

  defp build_and_validate_json_context(opts, task_id) do
    context =
      %{}
      |> put_present("task_id", task_id)
      |> put_present("timeout", Keyword.get(opts, :timeout))
      |> put_present("caller_id", caller_id_from_opts(opts))

    context =
      if Keyword.has_key?(opts, :metadata) do
        Map.put(context, "metadata", metadata(opts))
      else
        context
      end

    case canonicalize_and_roundtrip(context) do
      {:ok, clean} -> {:ok, clean}
      {:error, _reason} -> {:error, :non_json_execution_context}
    end
  end

  # Plain string tasks stay strings on the JSON-clean default path.
  defp canonicalize_and_validate_task(task) when is_binary(task), do: {:ok, task}

  defp canonicalize_and_validate_task(task) when is_map(task) do
    case canonicalize_and_roundtrip(task) do
      {:ok, clean} -> {:ok, clean}
      {:error, :conflicting_task_kind} = error -> error
      {:error, _reason} -> {:error, :non_json_task}
    end
  end

  defp canonicalize_and_validate_task(_task), do: {:error, :non_json_task}

  defp canonicalize_and_roundtrip(term) do
    case canonicalize_json(term) do
      {:ok, clean} ->
        case Jason.encode(clean) do
          {:ok, encoded} ->
            case Jason.decode(encoded) do
              {:ok, ^clean} -> {:ok, clean}
              {:ok, _other} -> {:error, :json_roundtrip_mismatch}
              {:error, _} -> {:error, :json_decode_failed}
            end

          {:error, _} ->
            {:error, :json_encode_failed}
        end

      {:error, _} = error ->
        error
    end
  end

  defp canonicalize_json(value) when is_binary(value), do: {:ok, value}
  defp canonicalize_json(value) when is_number(value), do: {:ok, value}
  defp canonicalize_json(value) when is_boolean(value), do: {:ok, value}
  defp canonicalize_json(nil), do: {:ok, nil}

  defp canonicalize_json(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case canonicalize_json(item) do
        {:ok, clean} -> {:cont, {:ok, [clean | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp canonicalize_json(map) when is_map(map) and not is_struct(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, string_key} <- canonicalize_map_key(key),
           {:ok, clean_value} <- canonicalize_map_value(string_key, value) do
        case Map.fetch(acc, string_key) do
          :error ->
            {:cont, {:ok, Map.put(acc, string_key, clean_value)}}

          {:ok, ^clean_value} ->
            {:cont, {:ok, acc}}

          {:ok, _other} when string_key == "kind" ->
            {:halt, {:error, :conflicting_task_kind}}

          {:ok, _other} ->
            {:halt, {:error, {:conflicting_map_keys, string_key}}}
        end
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp canonicalize_json(%_{}), do: {:error, :struct_not_json}
  defp canonicalize_json(value) when is_pid(value), do: {:error, :pid_not_json}
  defp canonicalize_json(value) when is_function(value), do: {:error, :function_not_json}
  defp canonicalize_json(value) when is_reference(value), do: {:error, :reference_not_json}
  defp canonicalize_json(value) when is_port(value), do: {:error, :port_not_json}
  defp canonicalize_json(value) when is_tuple(value), do: {:error, :tuple_not_json}

  defp canonicalize_json(value) when is_atom(value) do
    {:error, {:unsupported_atom_value, value}}
  end

  defp canonicalize_json(_value), do: {:error, :non_json_value}

  defp canonicalize_map_key(key) when is_binary(key), do: {:ok, key}

  defp canonicalize_map_key(key) when is_atom(key) and not is_nil(key),
    do: {:ok, Atom.to_string(key)}

  defp canonicalize_map_key(_key), do: {:error, :invalid_map_key}

  defp canonicalize_map_value("kind", value) do
    case Config.normalize_kind(value) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, :blank_task_kind} -> {:error, :blank_task_kind}
      {:error, :invalid_task_kind} -> {:error, :invalid_task_kind}
    end
  end

  defp canonicalize_map_value(_key, value), do: canonicalize_json(value)

  defp caller_id_from_opts(opts) do
    Keyword.get(opts, :caller_id) ||
      Keyword.get(opts, :actor_id) ||
      Keyword.get(opts, :authenticated_principal_id)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

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
