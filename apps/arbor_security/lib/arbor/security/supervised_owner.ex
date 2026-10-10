defmodule Arbor.Security.SupervisedOwner do
  @moduledoc false

  # Supervisors on a starting application's path may still be inside init/1
  # (starting later siblings). Bound each lookup so a slow or wedged startup
  # refuses admission instead of blocking the authorizing owner forever.
  @startup_lookup_timeout_ms 5_000

  @spec authorized?(pid(), atom(), [term()]) :: boolean()
  def authorized?(caller, application, child_path)
      when is_pid(caller) and is_atom(application) and is_list(child_path) and child_path != [] do
    case application_root(application) do
      {:ok, root} -> child_at_path(root, child_path, :infinity) == caller
      {:error, _reason} -> starting_application_authorized?(caller, application, child_path)
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @spec child_pid(pid(), term()) :: pid() | nil
  def child_pid(supervisor, child_id) when is_pid(supervisor) do
    child_pid(supervisor, child_id, :infinity)
  end

  def child_pid(_supervisor, _child_id), do: nil

  defp child_pid(supervisor, child_id, timeout) do
    case Enum.find(GenServer.call(supervisor, :which_children, timeout), fn
           {^child_id, _pid, _type, _modules} -> true
           _child -> false
         end) do
      {^child_id, pid, _type, _modules} when is_pid(pid) -> pid
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  @doc false
  @spec protected_directory_owner(atom(), term(), atom(), [term()]) :: pid() | nil
  def protected_directory_owner(table, key, application, child_path)
      when is_atom(table) and is_atom(application) and is_list(child_path) and child_path != [] do
    case :ets.lookup(table, key) do
      [{^key, owner}] when is_pid(owner) ->
        if Process.alive?(owner) and :ets.info(table, :owner) == owner and
             authorized?(owner, application, child_path),
           do: owner,
           else: nil

      _ ->
        nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  def protected_directory_owner(_table, _key, _application, _child_path), do: nil

  @doc false
  @spec registered_child(atom(), atom(), [term()]) :: pid() | nil
  def registered_child(name, application, child_path)
      when is_atom(name) and is_atom(application) and is_list(child_path) and child_path != [] do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        if Process.alive?(pid) and authorized?(pid, application, child_path), do: pid, else: nil

      _ ->
        nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  def registered_child(_name, _application, _child_path), do: nil

  # Never ask an application master for its child before the application
  # controller has marked the application started. Until start/2 returns, the
  # master's child slot is :undefined and OTP 28's get_child path crashes the
  # master with badarg; the controller then never receives
  # `application_started`, so `Application.ensure_all_started/1` hangs with the
  # application stuck in `starting` (2026-10-09: Trust.CapabilityGrantOwner's
  # key-custody claim hung every dev boot at 15/26 apps). authorized?/3 uses
  # starting_application_authorized?/3 for that window instead.
  @spec application_root(atom()) :: {:ok, pid()} | {:error, :application_unavailable}
  def application_root(application) when is_atom(application) do
    with true <- application_started?(application),
         master when is_pid(master) <- :application_controller.get_master(application),
         {root, _module} when is_pid(root) <- :application_master.get_child(master),
         true <- Process.alive?(root) do
      {:ok, root}
    else
      _ -> {:error, :application_unavailable}
    end
  rescue
    _ -> {:error, :application_unavailable}
  catch
    :exit, _ -> {:error, :application_unavailable}
  end

  @spec application_started?(atom()) :: boolean()
  def application_started?(application) when is_atom(application) do
    Enum.any?(Application.started_applications(), fn {name, _description, _version} ->
      name == application
    end)
  rescue
    _ -> false
  end

  # Role owners (Trust.CapabilityGrantOwner, Scheduler.Identity, ...) claim key
  # custody from their own continuation, while their application's start/2 is
  # still running — Scheduler.Application.start/2 even waits for that claim.
  # The master cannot be asked for its child yet (see application_root/1), so
  # bind the root to the application from VM-maintained spawn parents instead,
  # which no process can forge: walking exactly length(child_path) parents up
  # from the caller must reach a root whose parent is the process the master
  # spawned to run start/2, and that master must be the controller's master
  # for `application`. The exact child ids are then still confirmed top-down.
  defp starting_application_authorized?(caller, application, child_path) do
    with master when is_pid(master) <- :application_controller.get_master(application),
         {:ok, controller} <- spawn_parent(master),
         ^controller <- Process.whereis(:application_controller),
         {:ok, root} <- spawn_ancestor(caller, length(child_path)),
         {:ok, starter} <- spawn_parent(root),
         {:ok, ^master} <- spawn_parent(starter) do
      child_at_path(root, child_path, @startup_lookup_timeout_ms) == caller
    else
      _ -> false
    end
  end

  defp spawn_ancestor(pid, 0), do: {:ok, pid}

  defp spawn_ancestor(pid, depth) do
    with {:ok, parent} <- spawn_parent(pid), do: spawn_ancestor(parent, depth - 1)
  end

  defp spawn_parent(pid) do
    case Process.info(pid, :parent) do
      {:parent, parent} when is_pid(parent) -> {:ok, parent}
      _ -> :error
    end
  end

  defp child_at_path(supervisor, [child_id], timeout) do
    child_pid(supervisor, child_id, timeout)
  end

  defp child_at_path(supervisor, [child_id | rest], timeout) do
    case child_pid(supervisor, child_id, timeout) do
      pid when is_pid(pid) -> child_at_path(pid, rest, timeout)
      _ -> nil
    end
  end
end
