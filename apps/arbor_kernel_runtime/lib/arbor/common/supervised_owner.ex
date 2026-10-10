defmodule Arbor.Common.SupervisedOwner do
  @moduledoc false

  @default_timeout 1_000

  @spec registered_child_pid(atom(), [term()], atom(), timeout()) ::
          {:ok, pid()} | {:error, :not_supervised_owner}
  def registered_child_pid(application, child_path, registered_name, timeout \\ @default_timeout)

  def registered_child_pid(
        application,
        child_path,
        registered_name,
        timeout
      )
      when is_atom(application) and is_list(child_path) and child_path != [] and
             is_atom(registered_name) and is_integer(timeout) and timeout > 0 do
    task =
      Task.async(fn ->
        find_registered_child(application, child_path, registered_name)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, pid} when is_pid(pid) -> {:ok, pid}
      _timeout_or_failure -> {:error, :not_supervised_owner}
    end
  end

  def registered_child_pid(_application, _child_path, _registered_name, _timeout),
    do: {:error, :not_supervised_owner}

  @doc """
  Binds `candidate` to the root supervisor of an application whose `start/2`
  is still running, without asking that application's master.

  Until `start/2` returns, the master's child slot is `:undefined` and OTP 28's
  `:application_master.get_child/1` crashes the master with `badarg`; the
  application controller then never hears `application_started` and the boot
  hangs with the application stuck in `starting` (2026-10-09). Instead, walk
  VM-maintained spawn parents, which no process can forge: exactly `depth`
  parents above `candidate` must be a root whose parent is the process the
  master spawned to run `start/2`, and that master must be the controller's
  master for `application`. Callers still confirm the exact child ids
  top-down from the returned root.
  """
  @spec starting_application_root(atom(), pid(), pos_integer()) :: {:ok, pid()} | :error
  def starting_application_root(application, candidate, depth)
      when is_atom(application) and is_pid(candidate) and is_integer(depth) and depth > 0 do
    with master when is_pid(master) <- :application_controller.get_master(application),
         {:ok, controller} <- spawn_parent(master),
         ^controller <- Process.whereis(:application_controller),
         {:ok, root} <- spawn_ancestor(candidate, depth),
         {:ok, starter} <- spawn_parent(root),
         {:ok, ^master} <- spawn_parent(starter) do
      {:ok, root}
    else
      _other -> :error
    end
  rescue
    # Process.info/2 raises for a pid on another node.
    ArgumentError -> :error
  end

  def starting_application_root(_application, _candidate, _depth), do: :error

  defp find_registered_child(application, child_path, registered_name) do
    with candidate when is_pid(candidate) <- Process.whereis(registered_name),
         {:ok, root_pid} <- application_root(application, candidate, length(child_path)),
         true <- Process.alive?(root_pid),
         child_pid when is_pid(child_pid) <- supervised_descendant_pid(root_pid, child_path),
         true <- Process.alive?(child_pid),
         ^child_pid <- Process.whereis(registered_name) do
      child_pid
    else
      _other -> nil
    end
  catch
    :exit, _reason -> nil
  end

  # Ask the master only once the application controller reports the
  # application started; during start/2 use the spawn-parent binding above.
  # Owners such as the scheduler's run-lease store are looked up from inside
  # their own application's start (Scheduler.Application.start/2 waits for
  # them), so failing closed there deadlocked the scheduler's boot.
  defp application_root(application, candidate, depth) do
    if application_running?(application) do
      with master when is_pid(master) <- :application_controller.get_master(application),
           {root_pid, _application_module} when is_pid(root_pid) <-
             :application_master.get_child(master) do
        {:ok, root_pid}
      else
        _other -> :error
      end
    else
      starting_application_root(application, candidate, depth)
    end
  end

  defp spawn_ancestor(pid, 0), do: {:ok, pid}

  defp spawn_ancestor(pid, depth) do
    with {:ok, parent} <- spawn_parent(pid), do: spawn_ancestor(parent, depth - 1)
  end

  defp spawn_parent(pid) do
    case Process.info(pid, :parent) do
      {:parent, parent} when is_pid(parent) -> {:ok, parent}
      _other -> :error
    end
  end

  defp supervised_descendant_pid(root_pid, child_path) do
    Enum.reduce_while(child_path, root_pid, fn child_id, supervisor_pid ->
      case supervised_child_pid(supervisor_pid, child_id) do
        child_pid when is_pid(child_pid) -> {:cont, child_pid}
        _other -> {:halt, nil}
      end
    end)
  end

  defp supervised_child_pid(supervisor_pid, child_id) do
    Enum.find_value(Supervisor.which_children(supervisor_pid), fn
      {^child_id, child_pid, _type, _modules} when is_pid(child_pid) -> child_pid
      _other -> nil
    end)
  end

  defp application_running?(application) do
    Enum.any?(Application.started_applications(), fn
      {^application, _description, _version} -> true
      _other -> false
    end)
  end
end
