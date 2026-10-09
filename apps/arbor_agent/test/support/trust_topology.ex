defmodule Arbor.Agent.Test.TrustTopology do
  @moduledoc false

  @supervisor Arbor.Trust.ApplicationSupervisor
  @children [
    {Arbor.Trust.Store, [persistence: :memory]},
    {Arbor.Trust.Manager,
     [circuit_breaker: false, decay: false, event_store: false, persistence: :memory]}
  ]

  def ensure_owned! do
    supervisor =
      Process.whereis(@supervisor) ||
        raise "Arbor.Trust.ApplicationSupervisor is not running"

    Enum.each(@children, &ensure_child!(supervisor, &1))
    supervisor
  end

  defp ensure_child!(supervisor, child) do
    spec = Supervisor.child_spec(child, [])

    case Supervisor.start_child(supervisor, spec) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, :already_present} -> restart_child!(supervisor, spec.id)
      {:error, reason} -> raise "failed to start trust test child: #{inspect(reason)}"
    end

    case List.keyfind(Supervisor.which_children(supervisor), spec.id, 0) do
      {id, pid, :worker, _modules} when id == spec.id and is_pid(pid) -> :ok
      _ -> raise "trust test child #{inspect(spec.id)} is not owned by #{@supervisor}"
    end
  end

  @doc """
  Make way for a test that starts its own `Arbor.Trust.Store` and
  `Arbor.Trust.Manager` (with options of its own) under `start_supervised!/1`.

  `ensure_owned!/0` leaves those children running under
  `Arbor.Trust.ApplicationSupervisor` for later modules, so a private start
  would collide with `{:already_started, pid}`. This stops only the ones that
  are running, Manager before Store, with `Supervisor.terminate_child/2` (a
  clean stop that never counts toward restart intensity), and restarts them in
  order when the test exits.
  """
  def release_owned! do
    released =
      case Process.whereis(@supervisor) do
        nil ->
          []

        supervisor ->
          for {module, _opts} <- Enum.reverse(@children),
              running_child?(supervisor, module) do
            :ok = Supervisor.terminate_child(supervisor, module)
            module
          end
      end

    ExUnit.Callbacks.on_exit(fn ->
      with supervisor when is_pid(supervisor) <- Process.whereis(@supervisor) do
        released |> Enum.reverse() |> Enum.each(&restart_child!(supervisor, &1))
      end
    end)

    :ok
  end

  defp running_child?(supervisor, child_id) do
    Enum.any?(Supervisor.which_children(supervisor), fn
      {^child_id, pid, _type, _modules} -> is_pid(pid)
      _other -> false
    end)
  end

  defp restart_child!(supervisor, child_id) do
    case Supervisor.restart_child(supervisor, child_id) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, :running} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> raise "failed to restart trust test child: #{inspect(reason)}"
    end
  end
end
