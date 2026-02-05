defmodule Arbor.Monitor.Skills.Supervisor do
  @moduledoc """
  Supervisor tree health: child counts, restart tracking.
  """

  @behaviour Arbor.Monitor.Skill

  @impl true
  def name, do: :supervisor

  @impl true
  def collect do
    supervisors = find_supervisors()

    supervisor_details =
      Enum.map(supervisors, fn {name, pid} ->
        try do
          counts = :supervisor.count_children(pid)

          %{
            name: name,
            pid: inspect(pid),
            specs: Keyword.get(counts, :specs, 0),
            active: Keyword.get(counts, :active, 0),
            supervisors: Keyword.get(counts, :supervisors, 0),
            workers: Keyword.get(counts, :workers, 0)
          }
        rescue
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    total_specs = Enum.reduce(supervisor_details, 0, fn s, acc -> acc + s.specs end)
    total_active = Enum.reduce(supervisor_details, 0, fn s, acc -> acc + s.active end)

    metrics = %{
      supervisor_count: length(supervisor_details),
      total_specs: total_specs,
      total_active: total_active,
      supervisors: supervisor_details
    }

    {:ok, metrics}
  rescue
    error -> {:error, Exception.message(error)}
  end

  @impl true
  def check(metrics) do
    # Check if any supervisor has fewer active children than specs
    # (indicates crashed children that haven't been restarted)
    inactive =
      Enum.filter(metrics[:supervisors] || [], fn s ->
        s.active < s.specs
      end)

    if Enum.any?(inactive) do
      {:anomaly, :warning,
       %{
         metric: :supervisor_inactive_children,
         supervisors:
           Enum.map(inactive, fn s ->
             %{name: s.name, specs: s.specs, active: s.active}
           end)
       }}
    else
      :normal
    end
  end

  defp find_supervisors do
    # Walk registered processes looking for supervisors
    Process.registered()
    |> Enum.filter(fn name ->
      case Process.whereis(name) do
        nil ->
          false

        pid ->
          try do
            {:dictionary, dict} = Process.info(pid, :dictionary)

            Enum.any?(dict, fn
              {:"$initial_call", {mod, :init, 1}} ->
                function_exported?(mod, :init, 1) and
                  supervisor_module?(mod)

              _ ->
                false
            end)
          rescue
            _ -> false
          end
      end
    end)
    |> Enum.map(fn name -> {name, Process.whereis(name)} end)
    |> Enum.reject(fn {_, pid} -> is_nil(pid) end)
  end

  defp supervisor_module?(mod) do
    behaviours =
      if function_exported?(mod, :module_info, 1) do
        mod.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()
      else
        []
      end

    Supervisor in behaviours or :supervisor in behaviours
  rescue
    _ -> false
  end
end
