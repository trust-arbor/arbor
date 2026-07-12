defmodule Arbor.AI.AcpManaged.Supervisor do
  @moduledoc """
  DynamicSupervisor for non-pooled managed `AcpSession` children.

  Always available when `arbor_ai` starts its children. Managed sessions that
  are not checked out from `AcpPool` are started here with `restart: :temporary`
  so a normal close cannot restart an untracked worker.
  """

  use DynamicSupervisor

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
    deadline = Keyword.get(opts, :deadline_ms, :infinity)

    case deadline do
      :infinity ->
        do_start_session(supervisor, session_module, session_opts)

      value when is_integer(value) ->
        start_before_deadline(supervisor, session_module, session_opts, value)

      _invalid ->
        {:error, :invalid_deadline}
    end
  end

  defp do_start_session(supervisor, session_module, session_opts) do
    child_spec = %{
      id: {session_module, make_ref()},
      start: {session_module, :start_link, [session_opts]},
      restart: :temporary,
      type: :worker,
      shutdown: 30_000
    }

    case DynamicSupervisor.start_child(supervisor, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _info} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_before_deadline(supervisor, session_module, session_opts, deadline) do
    caller = self()
    reply = :erlang.alias()
    ref = make_ref()

    {coordinator, monitor} =
      spawn_monitor(fn ->
        result = do_start_session(supervisor, session_module, session_opts)
        completed_at = System.monotonic_time(:millisecond)
        send(reply, {ref, result, completed_at, self()})

        case result do
          {:ok, pid} -> await_start_ack(caller, ref, pid, supervisor, deadline, completed_at)
          _error -> :ok
        end
      end)

    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    result =
      receive do
        {^ref, result, completed_at, ^coordinator} ->
          if completed_at <= deadline do
            send(coordinator, {ref, :accepted, caller})
            result
          else
            {:error, :timeout}
          end

        {:DOWN, ^monitor, :process, ^coordinator, reason} ->
          {:error, {:start_coordinator_exit, Arbor.LLM.sanitize_external_reason(reason)}}
      after
        remaining -> {:error, :timeout}
      end

    :erlang.unalias(reply)
    Process.demonitor(monitor, [:flush])
    result
  end

  defp await_start_ack(caller, ref, pid, supervisor, deadline, completed_at) do
    if completed_at <= deadline do
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {^ref, :accepted, ^caller} -> :ok
      after
        remaining -> terminate_started_child(supervisor, pid)
      end
    else
      terminate_started_child(supervisor, pid)
    end
  end

  defp terminate_started_child(supervisor, pid) do
    case DynamicSupervisor.terminate_child(supervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        :ok

      {:error, _reason} ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
        :ok
    end
  catch
    :exit, _reason ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      :ok
  end

  @doc """
  Terminate a managed session child if it is still alive under the supervisor.
  """
  @spec terminate_session(pid(), keyword()) :: :ok | {:error, term()}
  def terminate_session(pid, opts \\ []) when is_pid(pid) do
    supervisor = Keyword.get(opts, :supervisor, __MODULE__)

    if Process.alive?(pid) do
      case DynamicSupervisor.terminate_child(supervisor, pid) do
        :ok -> :ok
        {:error, :not_found} -> :ok
        {:error, _} = error -> error
      end
    else
      :ok
    end
  end
end
