defmodule Arbor.AI.AcpManaged.Supervisor do
  @moduledoc """
  DynamicSupervisor for non-pooled managed `AcpSession` children.

  Always available when `arbor_ai` starts its children. Managed sessions that
  are not checked out from `AcpPool` are started here with `restart: :temporary`
  so a normal close cannot restart an untracked worker.
  """

  use DynamicSupervisor

  @default_start_timeout_ms 120_000
  @cleanup_grace_ms 250

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start a temporary session child under the managed supervisor.

  Returns `{:ok, pid}` or `{:error, reason}`. Children use `restart: :temporary`
  so orderly closes do not auto-restart.
  """
  @spec start_session(module(), keyword(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_session(session_module, session_opts, opts \\ [])
      when is_atom(session_module) and is_list(session_opts) do
    supervisor = Keyword.get(opts, :supervisor, __MODULE__)
    deadline = Keyword.get(opts, :deadline_ms, default_deadline())

    case deadline do
      :infinity ->
        start_before_deadline(
          supervisor,
          session_module,
          session_opts,
          default_deadline()
        )

      value when is_integer(value) ->
        start_before_deadline(supervisor, session_module, session_opts, value)

      _invalid ->
        {:error, :invalid_deadline}
    end
  end

  @doc false
  def adopt_started_session(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      Process.link(pid)
      {:ok, pid}
    else
      {:error, :session_died_before_adoption}
    end
  end

  def adopt_started_session(_pid), do: {:error, :invalid_session_pid}

  defp adopt(supervisor, session_module, pid) do
    child_spec = %{
      id: {session_module, make_ref()},
      start: {__MODULE__, :adopt_started_session, [pid]},
      restart: :temporary,
      type: :worker,
      shutdown: 30_000
    }

    case DynamicSupervisor.start_child(supervisor, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _info} -> {:ok, pid}
      {:error, {:already_started, ^pid}} -> {:ok, pid}
      {:error, reason} -> {:error, Arbor.LLM.sanitize_external_reason(reason)}
    end
  end

  defp start_before_deadline(supervisor, session_module, session_opts, deadline) do
    if deadline <= System.monotonic_time(:millisecond) do
      {:error, :timeout}
    else
      start_owned(supervisor, session_module, session_opts, deadline)
    end
  end

  defp start_owned(supervisor, session_module, session_opts, deadline) do
    caller = self()
    reply = :erlang.alias()
    ref = make_ref()

    {starter, monitor} =
      spawn_monitor(fn ->
        result = safely_start(session_module, session_opts)
        completed_at = System.monotonic_time(:millisecond)
        send(reply, {ref, result, completed_at, self()})

        case result do
          {:ok, pid} -> await_start_ack(caller, ref, pid, deadline, completed_at)
          _error -> :ok
        end
      end)

    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    result =
      receive do
        {^ref, {:ok, pid}, completed_at, ^starter} when completed_at <= deadline ->
          case adopt(supervisor, session_module, pid) do
            {:ok, ^pid} = ok ->
              send(starter, {ref, :accepted, caller})
              ok

            {:error, reason} ->
              send(starter, {ref, :rejected, caller})
              terminate_started_process(pid)
              {:error, reason}
          end

        {^ref, {:ok, pid}, _completed_at, ^starter} ->
          send(starter, {ref, :rejected, caller})
          terminate_started_process(pid)
          {:error, :timeout}

        {^ref, result, completed_at, ^starter} ->
          if completed_at <= deadline, do: result, else: {:error, :timeout}

        {:DOWN, ^monitor, :process, ^starter, reason} ->
          {:error, {:start_worker_exit, Arbor.LLM.sanitize_external_reason(reason)}}
      after
        remaining ->
          terminate_start_worker(starter)
          {:error, :timeout}
      end

    :erlang.unalias(reply)
    await_or_demonitor(starter, monitor)
    result
  end

  defp safely_start(session_module, session_opts) do
    case apply(session_module, :start_link, [session_opts]) do
      {:ok, pid} when is_pid(pid) -> {:ok, pid}
      {:ok, pid, _info} when is_pid(pid) -> {:ok, pid}
      {:error, reason} -> {:error, Arbor.LLM.sanitize_external_reason(reason)}
      other -> {:error, {:invalid_session_start, Arbor.LLM.sanitize_external_reason(other)}}
    end
  rescue
    exception ->
      {:error, {:session_start_failed, Arbor.LLM.external_exception_message(exception)}}
  catch
    kind, reason ->
      {:error, {:session_start_failure, kind, Arbor.LLM.sanitize_external_reason(reason)}}
  end

  defp await_start_ack(caller, ref, pid, deadline, completed_at) do
    if completed_at <= deadline do
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {^ref, :accepted, ^caller} ->
          Process.unlink(pid)
          :ok

        {^ref, :rejected, ^caller} ->
          terminate_started_process(pid)
      after
        remaining -> terminate_started_process(pid)
      end
    else
      terminate_started_process(pid)
    end
  end

  defp await_or_demonitor(pid, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      @cleanup_grace_ms -> Process.demonitor(monitor, [:flush])
    end
  end

  defp terminate_started_process(pid) when is_pid(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    :ok
  end

  defp terminate_start_worker(starter) do
    linked_processes =
      case Process.info(starter, :links) do
        {:links, links} -> Enum.filter(links, &is_pid/1)
        nil -> []
      end

    Enum.each(linked_processes, &terminate_started_process/1)
    terminate_started_process(starter)
  end

  defp default_deadline,
    do: System.monotonic_time(:millisecond) + @default_start_timeout_ms

  @doc """
  Terminate a managed session child if it is still alive under the supervisor.
  """
  @spec terminate_session(pid(), keyword()) :: :ok | {:error, term()}
  def terminate_session(pid, _opts \\ []) when is_pid(pid) do
    # AcpSession traps exits to handle owner/client links. A supervisor shutdown
    # signal could therefore consume the full child shutdown timeout. Direct kill
    # is reserved for failed/cancelled startup cleanup; DynamicSupervisor removes
    # the child from its table when it observes the DOWN signal.
    terminate_started_process(pid)
  end
end
