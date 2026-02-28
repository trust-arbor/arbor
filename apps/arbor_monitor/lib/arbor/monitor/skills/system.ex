defmodule Arbor.Monitor.Skills.System do
  @moduledoc """
  OS-level metrics: system memory, CPU info, port count.
  """

  @behaviour Arbor.Monitor.Skill

  @impl true
  def name, do: :system

  @impl true
  def collect do
    port_count = :erlang.system_info(:port_count)
    port_limit = :erlang.system_info(:port_limit)

    otp_release = :erlang.system_info(:otp_release) |> to_string()
    system_arch = :erlang.system_info(:system_architecture) |> to_string()
    logical_processors = :erlang.system_info(:logical_processors_available)
    schedulers = :erlang.system_info(:schedulers_online)

    {uptime_ms, _} = :erlang.statistics(:wall_clock)

    sys_mem = safe_system_memory()

    metrics = %{
      port_count: port_count,
      port_limit: port_limit,
      port_count_ratio: port_count / max(port_limit, 1),
      otp_release: otp_release,
      system_architecture: system_arch,
      logical_processors: logical_processors,
      schedulers_online: schedulers,
      uptime_ms: uptime_ms,
      system_total_memory: sys_mem[:total_memory],
      system_free_memory: sys_mem[:free_memory],
      system_available_memory: sys_mem[:available_memory]
    }

    {:ok, metrics}
  rescue
    error -> {:error, Exception.message(error)}
  end

  @impl true
  def check(metrics) do
    # Check for system memory pressure.
    # Prefer available_memory (includes reclaimable/cached pages) over free_memory.
    # On macOS, free_memory is only truly unused pages — always looks critically low
    # because the OS aggressively caches files. available_memory is what matters.
    total = metrics[:system_total_memory] || 0
    available = metrics[:system_available_memory] || metrics[:system_free_memory] || 0

    if total > 0 and available > 0 do
      used_ratio = 1.0 - available / total

      if used_ratio > 0.95 do
        {:anomaly, :emergency,
         %{
           metric: :system_memory_pressure,
           used_ratio: used_ratio,
           free_bytes: available,
           total_bytes: total
         }}
      else
        :normal
      end
    else
      :normal
    end
  end

  defp safe_system_memory do
    case :memsup.get_system_memory_data() do
      data when is_list(data) ->
        %{
          total_memory: Keyword.get(data, :total_memory, 0),
          free_memory: Keyword.get(data, :free_memory, 0),
          available_memory: Keyword.get(data, :available_memory, 0)
        }

      _ ->
        %{total_memory: 0, free_memory: 0, available_memory: 0}
    end
  rescue
    _ -> %{total_memory: 0, free_memory: 0, available_memory: 0}
  end
end
