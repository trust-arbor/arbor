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
