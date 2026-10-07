defmodule Arbor.Security.SupervisedOwner do
  @moduledoc false

  @spec authorized?(pid(), atom(), [term()]) :: boolean()
  def authorized?(caller, application, child_path)
      when is_pid(caller) and is_atom(application) and is_list(child_path) and child_path != [] do
    case application_root(application) do
      {:ok, root} -> child_at_path(root, child_path) == caller
      {:error, _reason} -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @spec child_pid(pid(), term()) :: pid() | nil
  def child_pid(supervisor, child_id) when is_pid(supervisor) do
    case Enum.find(Supervisor.which_children(supervisor), fn
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

  def child_pid(_supervisor, _child_id), do: nil

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

  @spec application_root(atom()) :: {:ok, pid()} | {:error, :application_unavailable}
  def application_root(application) when is_atom(application) do
    with master when is_pid(master) <- :application_controller.get_master(application),
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

  defp child_at_path(supervisor, [child_id]) do
    child_pid(supervisor, child_id)
  end

  defp child_at_path(supervisor, [child_id | rest]) do
    case child_pid(supervisor, child_id) do
      pid when is_pid(pid) -> child_at_path(pid, rest)
      _ -> nil
    end
  end
end
