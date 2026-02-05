defmodule Arbor.Monitor.Skills.Memory do
  @moduledoc """
  Memory metrics: total, process, binary, ETS, atom memory breakdown.
  """

  @behaviour Arbor.Monitor.Skill

  alias Arbor.Monitor.Config

  @impl true
  def name, do: :memory

  @impl true
  def collect do
    mem = :erlang.memory()

    metrics = %{
      total: Keyword.get(mem, :total, 0),
      processes: Keyword.get(mem, :processes, 0),
      processes_used: Keyword.get(mem, :processes_used, 0),
      binary: Keyword.get(mem, :binary, 0),
      ets: Keyword.get(mem, :ets, 0),
      atom: Keyword.get(mem, :atom, 0),
      atom_used: Keyword.get(mem, :atom_used, 0),
      code: Keyword.get(mem, :code, 0),
      system: Keyword.get(mem, :system, 0)
    }

    {:ok, metrics}
  rescue
    error -> {:error, Exception.message(error)}
  end

  @impl true
  def check(metrics) do
    config = Config.anomaly_config()
    # Default threshold: 85% of system memory or absolute bytes
    mem_threshold = get_in(config, [:memory_total, :threshold]) || 0.85

    # Check if total memory exceeds threshold of system memory
    system_mem = get_system_memory_total()

    if system_mem > 0 do
      ratio = metrics[:total] / system_mem

      if ratio > mem_threshold do
        {:anomaly, :critical,
         %{
           metric: :memory_ratio,
           value: ratio,
           threshold: mem_threshold,
           total_bytes: metrics[:total],
           system_bytes: system_mem
         }}
      else
        :normal
      end
    else
      :normal
    end
  end

  defp get_system_memory_total do
    case :memsup.get_system_memory_data() do
      data when is_list(data) ->
        Keyword.get(data, :total_memory, 0)

      _ ->
        0
    end
  rescue
    _ -> 0
  end
end
