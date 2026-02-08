defmodule Arbor.Monitor.Diagnostics do
  @moduledoc """
  BEAM runtime diagnostics for investigating anomalies.

  Provides read-only inspection of processes, supervisors, and system state.
  Used by the DebugAgent to gather evidence for hypothesis generation.

  All functions are safe and read-only — they inspect but never modify state.
  """

  @doc """
  Inspect a process and return detailed information.

  Returns `nil` if the process doesn't exist.
  """
  @spec inspect_process(pid()) :: map() | nil
  def inspect_process(pid) when is_pid(pid) do
    case Process.info(pid) do
      nil ->
        nil

      info ->
        %{
          pid: pid,
          message_queue_len: Keyword.get(info, :message_queue_len, 0),
          memory: Keyword.get(info, :memory, 0),
          status: Keyword.get(info, :status),
          current_function: Keyword.get(info, :current_function),
          initial_call: Keyword.get(info, :initial_call),
          registered_name: Keyword.get(info, :registered_name),
          reductions: Keyword.get(info, :reductions, 0),
          links: Keyword.get(info, :links, []),
          monitors: Keyword.get(info, :monitors, []),
          monitored_by: Keyword.get(info, :monitored_by, []),
          dictionary: extract_arbor_metadata(Keyword.get(info, :dictionary, [])),
          heap_size: Keyword.get(info, :heap_size, 0),
          stack_size: Keyword.get(info, :stack_size, 0),
          total_heap_size: Keyword.get(info, :total_heap_size, 0)
        }
    end
  end

  def inspect_process(_), do: nil

  @doc """
  Inspect a supervisor and return information about its children.

  Returns `nil` if the pid is not a supervisor or doesn't exist.
  """
  @spec inspect_supervisor(pid()) :: map() | nil
  def inspect_supervisor(pid) when is_pid(pid) do
    case safe_supervisor_call(pid, :which_children) do
      {:ok, children} ->
        child_info =
          Enum.map(children, fn {id, child_pid, type, modules} ->
            %{
              id: id,
              pid: child_pid,
              type: type,
              modules: modules,
              alive: is_pid(child_pid) and Process.alive?(child_pid)
            }
          end)

        # Try to get supervisor counts (returns a map)
        counts =
          case safe_supervisor_call(pid, :count_children) do
            {:ok, c} -> c
            _ -> %{}
          end

        %{
          pid: pid,
          children: child_info,
          child_count: length(children),
          specs: Map.get(counts, :specs, 0),
          active: Map.get(counts, :active, 0),
          supervisors: Map.get(counts, :supervisors, 0),
          workers: Map.get(counts, :workers, 0),
          restart_intensity: get_restart_intensity(pid)
        }

      {:error, _} ->
        nil
    end
  end

  def inspect_supervisor(_), do: nil

  @doc """
  Get top processes by a specific metric.

  Supported metrics: `:memory`, `:message_queue`, `:reductions`
  """
  @spec top_processes_by(atom(), pos_integer()) :: [map()]
  def top_processes_by(metric, limit \\ 10) when is_atom(metric) and is_integer(limit) do
    recon_type = metric_to_recon_type(metric)

    :recon.proc_count(recon_type, limit)
    |> Enum.flat_map(fn
      {pid, value, info} when is_list(info) ->
        [
          %{
            pid: pid,
            value: value,
            metric: metric,
            registered_name: get_registered_name(info),
            current_function: Keyword.get(info, :current_function),
            initial_call: Keyword.get(info, :initial_call)
          }
        ]

      _ ->
        # Skip malformed entries
        []
    end)
  end

  @doc """
  Get the process tree starting from a root pid.

  Returns a nested structure showing parent-child relationships.
  """
  @spec process_tree(pid()) :: map() | nil
  def process_tree(root_pid) when is_pid(root_pid) do
    case Process.info(root_pid) do
      nil ->
        nil

      info ->
        links = Keyword.get(info, :links, [])
        children = Enum.filter(links, &is_pid/1)

        %{
          pid: root_pid,
          registered_name: Keyword.get(info, :registered_name),
          children:
            Enum.map(children, fn child ->
              # Only go one level deep to avoid infinite recursion
              case Process.info(child) do
                nil ->
                  %{pid: child, alive: false}

                child_info ->
                  %{
                    pid: child,
                    alive: true,
                    registered_name: Keyword.get(child_info, :registered_name),
                    message_queue_len: Keyword.get(child_info, :message_queue_len, 0)
                  }
              end
            end)
        }
    end
  end

  def process_tree(_), do: nil

  @doc """
  Get current scheduler utilization.

  Returns utilization as a float between 0.0 and 1.0.
  """
  @spec scheduler_utilization() :: float()
  def scheduler_utilization do
    case :recon.scheduler_usage(100) do
      result when is_list(result) ->
        total = Enum.reduce(result, 0.0, fn {_, usage}, acc -> acc + usage end)
        total / max(length(result), 1)

      _ ->
        0.0
    end
  end

  @doc """
  Get system-wide memory information.
  """
  @spec memory_info() :: map()
  def memory_info do
    # :recon_alloc.memory(:used) returns bytes used
    # :recon_alloc.memory(:allocated) returns bytes allocated
    used = :recon_alloc.memory(:used)
    allocated = :recon_alloc.memory(:allocated)

    %{
      total: allocated,
      allocated: used,
      usage_ratio: used / max(allocated, 1),
      process_memory: :erlang.memory(:processes),
      ets_memory: :erlang.memory(:ets),
      binary_memory: :erlang.memory(:binary),
      atom_memory: :erlang.memory(:atom)
    }
  end

  @doc """
  Find processes with message queues exceeding a threshold.
  """
  @spec find_bloated_queues(pos_integer()) :: [map()]
  def find_bloated_queues(threshold \\ 1000) do
    for pid <- Process.list(),
        {:message_queue_len, len} <- [Process.info(pid, :message_queue_len)],
        len > threshold do
      info = Process.info(pid) || []

      %{
        pid: pid,
        message_queue_len: len,
        registered_name: Keyword.get(info, :registered_name),
        current_function: Keyword.get(info, :current_function),
        memory: Keyword.get(info, :memory, 0),
        dictionary: extract_arbor_metadata(Keyword.get(info, :dictionary, []))
      }
    end
    |> Enum.sort_by(& &1.message_queue_len, :desc)
  end

  @doc """
  Find supervisors with high restart intensity.

  This helps identify supervisors experiencing repeated child crashes.
  """
  @spec find_troubled_supervisors() :: [map()]
  def find_troubled_supervisors do
    for {_, pid, :supervisor, _} <- Process.list() |> Enum.flat_map(&get_process_ancestors/1),
        info = inspect_supervisor(pid),
        info != nil,
        info.restart_intensity > 0 do
      info
    end
    |> Enum.uniq_by(& &1.pid)
    |> Enum.sort_by(& &1.restart_intensity, :desc)
  end

  @doc """
  Trace arbor correlation from process dictionary.

  Returns the correlation_id and fault_type if present.
  """
  @spec trace_arbor_metadata(pid()) :: map()
  def trace_arbor_metadata(pid) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} ->
        extract_arbor_metadata(dict)

      nil ->
        %{}
    end
  end

  def trace_arbor_metadata(_), do: %{}

  # Private helpers

  defp extract_arbor_metadata(dict) when is_list(dict) do
    correlation_id = Keyword.get(dict, :arbor_correlation_id)
    fault_type = Keyword.get(dict, :arbor_fault_type)
    leaked_by = Keyword.get(dict, :arbor_leaked_by)

    %{}
    |> maybe_put(:correlation_id, correlation_id)
    |> maybe_put(:fault_type, fault_type)
    |> maybe_put(:leaked_by, leaked_by)
  end

  defp extract_arbor_metadata(_), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp safe_supervisor_call(pid, action) do
    result =
      case action do
        :which_children -> Supervisor.which_children(pid)
        :count_children -> Supervisor.count_children(pid)
      end

    {:ok, result}
  catch
    :exit, _ -> {:error, :not_supervisor}
  end

  defp get_restart_intensity(pid) do
    # Try to get supervisor intensity from its state
    # This is a heuristic - not all supervisors expose this
    case :sys.get_state(pid) do
      {:state, _, _, _, _, intensity, _, _, _, _, _, _} -> intensity
      _ -> 0
    end
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  defp metric_to_recon_type(:memory), do: :memory
  defp metric_to_recon_type(:message_queue), do: :message_queue_len
  defp metric_to_recon_type(:reductions), do: :reductions
  defp metric_to_recon_type(_), do: :memory

  defp get_registered_name(info) when is_list(info) do
    case Keyword.get(info, :registered_name) do
      [] -> nil
      name -> name
    end
  end

  defp get_registered_name(_), do: nil

  defp get_process_ancestors(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} ->
        case Keyword.get(dict, :"$ancestors") do
          ancestors when is_list(ancestors) ->
            Enum.map(ancestors, fn
              name when is_atom(name) -> {name, Process.whereis(name), :supervisor, []}
              pid when is_pid(pid) -> {:undefined, pid, :supervisor, []}
              _ -> nil
            end)
            |> Enum.reject(&is_nil/1)

          _ ->
            []
        end

      nil ->
        []
    end
  end
end
