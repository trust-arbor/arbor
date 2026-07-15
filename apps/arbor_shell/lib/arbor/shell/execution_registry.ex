defmodule Arbor.Shell.ExecutionRegistry do
  @moduledoc """
  Read-only public execution inventory with process-derived mutation ownership.

  PID, Port, monitor, and cancellation authority never appear in `get/1` or
  `list/1`. Lifecycle mutations are accepted only from the process currently
  owned by the entry; async handoff is accepted only from the original
  controller.
  Callers cannot assert an owner PID or copy a mutation token.
  """

  use GenServer

  alias Arbor.Identifiers

  @terminal_statuses [:completed, :failed, :timed_out, :killed]

  @type status :: :pending | :running | :cancelling | :completed | :failed | :timed_out | :killed

  # Explicit terminal provenance set in the same transition as status/result.
  # nil while nonterminal; never inferred from result.error shape.
  @type terminal_source :: nil | :owner_published | :owner_down

  @type execution :: %{
          id: String.t(),
          command: String.t(),
          status: status(),
          started_at: DateTime.t(),
          completed_at: DateTime.t() | nil,
          result: map() | nil,
          sandbox: atom(),
          cwd: String.t() | nil,
          terminal_source: terminal_source()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc false
  @spec register(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def register(command, opts \\ []) do
    GenServer.call(__MODULE__, {:register, command, opts})
  end

  @doc false
  @spec adopt(String.t(), pid()) :: :ok | {:error, term()}
  def adopt(execution_id, owner_pid) when is_pid(owner_pid) do
    GenServer.call(__MODULE__, {:adopt, execution_id, owner_pid})
  end

  @doc false
  @spec mark_running(String.t()) :: :ok | {:error, term()}
  def mark_running(execution_id) do
    GenServer.call(__MODULE__, {:owner_running, execution_id})
  end

  @doc false
  @spec finish(String.t(), map()) :: :ok | {:error, term()}
  def finish(execution_id, result) when is_map(result) do
    GenServer.call(__MODULE__, {:owner_finish, execution_id, result})
  end

  @doc false
  @spec fail(String.t(), term()) :: :ok | {:error, term()}
  def fail(execution_id, reason) do
    GenServer.call(__MODULE__, {:owner_fail, execution_id, reason})
  end

  @doc false
  @spec request_cancel(String.t()) :: :ok | {:error, :not_found | :not_running | :not_owner}
  def request_cancel(execution_id) do
    GenServer.call(__MODULE__, {:request_cancel, execution_id})
  end

  @doc "Get a redacted execution projection by ID."
  @spec get(String.t()) :: {:ok, execution()} | {:error, :not_found}
  def get(execution_id) do
    GenServer.call(__MODULE__, {:get, execution_id})
  end

  @doc "List redacted execution projections with optional status/limit filters."
  @spec list(keyword()) :: {:ok, [execution()]}
  def list(opts \\ []) do
    GenServer.call(__MODULE__, {:list, opts})
  end

  @spec cleanup(non_neg_integer()) :: :ok
  def cleanup(ttl_seconds \\ 3600) do
    GenServer.cast(__MODULE__, {:cleanup, ttl_seconds})
  end

  @impl true
  def init(_opts) do
    schedule_cleanup()
    {:ok, %{executions: %{}}}
  end

  @impl true
  def handle_call({:register, command, opts}, {controller_pid, _tag}, state)
      when is_binary(command) and is_list(opts) do
    id_prefix = if Keyword.get(opts, :id_prefix) == "port_", do: "port_", else: "exec_"
    id = Identifiers.generate_id(id_prefix)
    controller_ref = Process.monitor(controller_pid)

    execution = %{
      id: id,
      command: command,
      status: :pending,
      started_at: DateTime.utc_now(),
      completed_at: nil,
      result: nil,
      sandbox: Keyword.get(opts, :sandbox, :basic),
      cwd: Keyword.get(opts, :cwd),
      terminal_source: nil,
      owner_pid: controller_pid,
      owner_ref: controller_ref,
      controller_pid: controller_pid,
      controller_ref: controller_ref
    }

    {:reply, {:ok, id}, put_in(state, [:executions, id], execution)}
  end

  def handle_call({:register, _command, _opts}, _from, state) do
    {:reply, {:error, :invalid_execution_registration}, state}
  end

  def handle_call({:adopt, id, new_owner}, {caller, _tag} = from, state) do
    with {:ok, execution} <- fetch(state, id),
         true <- legitimate_call?(from),
         true <- execution.owner_pid == caller and execution.controller_pid == caller,
         true <- execution.status == :pending,
         true <- Process.alive?(new_owner) do
      owner_ref = Process.monitor(new_owner)

      updated = %{execution | owner_pid: new_owner, owner_ref: owner_ref, status: :running}
      {:reply, :ok, put_in(state, [:executions, id], updated)}
    else
      {:error, :not_found} -> {:reply, {:error, :not_found}, state}
      false -> {:reply, {:error, :owner_mismatch}, state}
    end
  end

  def handle_call({:owner_running, id}, {caller, _tag} = from, state) do
    if legitimate_call?(from),
      do: owner_transition(state, id, caller, [:pending], :running, nil),
      else: {:reply, {:error, :invalid_caller}, state}
  end

  def handle_call({:owner_finish, id, result}, {caller, _tag} = from, state)
      when is_map(result) do
    if legitimate_call?(from) do
      status = terminal_status(result)
      owner_transition(state, id, caller, [:pending, :running, :cancelling], status, result)
    else
      {:reply, {:error, :invalid_caller}, state}
    end
  end

  def handle_call({:owner_fail, id, reason}, {caller, _tag} = from, state) do
    if legitimate_call?(from) do
      owner_transition(
        state,
        id,
        caller,
        [:pending, :running, :cancelling],
        :failed,
        %{error: reason}
      )
    else
      {:reply, {:error, :invalid_caller}, state}
    end
  end

  def handle_call({:request_cancel, id}, {caller, _tag} = from, state) do
    case Map.get(state.executions, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      execution ->
        cond do
          not legitimate_call?(from) ->
            {:reply, {:error, :invalid_caller}, state}

          execution.controller_pid != caller ->
            {:reply, {:error, :not_owner}, state}

          execution.status in @terminal_statuses ->
            {:reply, {:error, :not_running}, state}

          execution.status == :cancelling ->
            {:reply, :ok, state}

          true ->
            send(execution.owner_pid, {:cancel_shell_execution, id})
            updated = %{execution | status: :cancelling}
            {:reply, :ok, put_in(state, [:executions, id], updated)}
        end
    end
  end

  def handle_call({:get, id}, _from, state) do
    case Map.get(state.executions, id) do
      nil -> {:reply, {:error, :not_found}, state}
      execution -> {:reply, {:ok, project(execution)}, state}
    end
  end

  def handle_call({:list, opts}, _from, state) when is_list(opts) do
    status_filter = Keyword.get(opts, :status)
    limit = normalize_limit(Keyword.get(opts, :limit, 100))

    executions =
      state.executions
      |> Map.values()
      |> maybe_filter_status(status_filter)
      |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
      |> Enum.take(limit)
      |> Enum.map(&project/1)

    {:reply, {:ok, executions}, state}
  end

  def handle_call({:list, _opts}, _from, state) do
    {:reply, {:ok, []}, state}
  end

  # Old mutation tuple shapes and arbitrary raw calls are data, not authority.
  def handle_call(_request, _from, state) do
    {:reply, {:error, :unsupported_registry_request}, state}
  end

  @impl true
  def handle_cast({:cleanup, ttl_seconds}, state)
      when is_integer(ttl_seconds) and ttl_seconds >= 0 do
    {:noreply, cleanup_state(state, ttl_seconds)}
  end

  def handle_cast(_request, state), do: {:noreply, state}

  @impl true
  def handle_info({:DOWN, ref, :process, owner_pid, reason}, state) do
    executions =
      Map.new(state.executions, fn {id, execution} ->
        owner_down? = execution.owner_ref == ref and execution.owner_pid == owner_pid

        controller_down? =
          execution.controller_ref == ref and execution.controller_pid == owner_pid

        cond do
          execution.status in @terminal_statuses ->
            {id, execution}

          owner_down? ->
            status = if execution.status == :cancelling, do: :killed, else: :failed

            result =
              if status == :killed do
                cancellation_result(execution)
              else
                %{error: {:execution_owner_down, bounded_reason(reason)}}
              end

            {id, apply_terminal(execution, status, result, :owner_down)}

          controller_down? ->
            send(execution.owner_pid, {:cancel_shell_execution, id})

            # Cancellation request only — remains nonterminal with nil provenance.
            {id,
             %{
               execution
               | status: :cancelling,
                 controller_pid: nil,
                 controller_ref: nil
             }}

          true ->
            {id, execution}
        end
      end)

    {:noreply, %{state | executions: executions}}
  end

  def handle_info(:cleanup, state) do
    schedule_cleanup()
    {:noreply, cleanup_state(state, 3600)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.executions, fn {_id, execution} ->
      if execution.status not in @terminal_statuses do
        send(execution.owner_pid, {:cancel_shell_execution, execution.id})
      end
    end)

    :ok
  end

  defp owner_transition(state, id, caller, allowed, status, result) do
    case Map.get(state.executions, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{owner_pid: owner} when owner != caller ->
        {:reply, {:error, :owner_mismatch}, state}

      execution ->
        cond do
          execution.status not in allowed ->
            {:reply, {:error, {:invalid_status, execution.status}}, state}

          status in @terminal_statuses ->
            updated = apply_terminal(execution, status, result, :owner_published)
            {:reply, :ok, put_in(state, [:executions, id], updated)}

          true ->
            # Nonterminal transitions keep nil terminal_source.
            updated = %{execution | status: status}
            {:reply, :ok, put_in(state, [:executions, id], updated)}
        end
    end
  end

  defp apply_terminal(execution, status, result, terminal_source)
       when terminal_source in [:owner_published, :owner_down] do
    execution
    |> monitor_refs()
    |> Enum.each(&Process.demonitor(&1, [:flush]))

    execution
    |> Map.put(:status, status)
    |> Map.put(:result, result)
    |> Map.put(:completed_at, DateTime.utc_now())
    |> Map.put(:terminal_source, terminal_source)
  end

  defp monitor_refs(execution) do
    [execution.owner_ref, execution.controller_ref]
    |> Enum.filter(&is_reference/1)
    |> Enum.uniq()
  end

  defp terminal_status(result) do
    cond do
      Map.get(result, :timed_out) == true -> :timed_out
      Map.get(result, :killed) == true -> :killed
      true -> :completed
    end
  end

  defp cancellation_result(execution) do
    %{
      exit_code: 137,
      stdout: "",
      stderr: "",
      duration_ms: max(DateTime.diff(DateTime.utc_now(), execution.started_at, :millisecond), 0),
      timed_out: false,
      killed: true,
      output_truncated: false,
      output_limit_exceeded: false,
      cancelled: true
    }
  end

  defp project(execution) do
    execution
    |> Map.take([
      :id,
      :command,
      :status,
      :started_at,
      :completed_at,
      :result,
      :sandbox,
      :cwd,
      :terminal_source
    ])
    |> sanitize_public()
  end

  defp sanitize_public(value) when is_pid(value) or is_port(value) or is_reference(value),
    do: :redacted

  defp sanitize_public(value) when is_function(value), do: :redacted

  defp sanitize_public(%DateTime{} = value), do: value

  defp sanitize_public(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {sanitize_public(key), sanitize_public(nested)} end)
  end

  defp sanitize_public(value) when is_list(value), do: Enum.map(value, &sanitize_public/1)

  defp sanitize_public(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> sanitize_public()

  defp sanitize_public(value), do: value

  defp fetch(state, id) do
    case Map.fetch(state.executions, id) do
      {:ok, execution} -> {:ok, execution}
      :error -> {:error, :not_found}
    end
  end

  # A real GenServer.call establishes a monitor from its caller to this server
  # before sending an alias-tagged request. A copied/asserted owner PID cannot
  # create that monitor on the owner's behalf. Avoid sampling current_function:
  # the server can receive a valid call just before the caller enters do_call.
  defp legitimate_call?({pid, [:alias | _ref]}) when is_pid(pid) do
    case Process.info(pid, :monitors) do
      {:monitors, monitors} ->
        Enum.any?(monitors, fn
          {:process, target} -> target == self()
          _other -> false
        end)

      _ ->
        false
    end
  end

  defp legitimate_call?(_from), do: false

  defp maybe_filter_status(executions, nil), do: executions

  defp maybe_filter_status(executions, status),
    do: Enum.filter(executions, &(&1.status == status))

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, 1000)
  defp normalize_limit(_limit), do: 100

  defp cleanup_state(state, ttl_seconds) do
    cutoff = DateTime.add(DateTime.utc_now(), -ttl_seconds, :second)

    executions =
      state.executions
      |> Enum.reject(fn {_id, execution} ->
        execution.status in @terminal_statuses and execution.completed_at != nil and
          DateTime.compare(execution.completed_at, cutoff) != :gt
      end)
      |> Map.new()

    %{state | executions: executions}
  end

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, 5 * 60 * 1000)

  defp bounded_reason(reason) when is_atom(reason), do: reason

  defp bounded_reason(reason),
    do: reason |> inspect(limit: 10, printable_limit: 200) |> String.slice(0, 500)
end
