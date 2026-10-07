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

  defp find_registered_child(application, child_path, registered_name) do
    with true <- application_running?(application),
         master when is_pid(master) <- :application_controller.get_master(application),
         {root_pid, _application_module} when is_pid(root_pid) <-
           :application_master.get_child(master),
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
