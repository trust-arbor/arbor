defmodule Arbor.Monitor.Skills.Ets do
  @moduledoc """
  ETS metrics: table count, per-table sizes, total ETS memory.
  """

  @behaviour Arbor.Monitor.Skill

  alias Arbor.Monitor.Config

  @impl true
  def name, do: :ets

  @impl true
  def collect do
    tables = :ets.all()
    table_count = length(tables)

    table_details =
      tables
      |> Enum.map(fn tab ->
        try do
          %{
            name: safe_table_name(tab),
            size: :ets.info(tab, :size) || 0,
            memory_words: :ets.info(tab, :memory) || 0,
            type: :ets.info(tab, :type)
          }
        rescue
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    total_memory_words =
      Enum.reduce(table_details, 0, fn t, acc -> acc + t.memory_words end)

    # Top 10 tables by memory
    top_tables =
      table_details
      |> Enum.sort_by(& &1.memory_words, :desc)
      |> Enum.take(10)

    metrics = %{
      table_count: table_count,
      total_memory_words: total_memory_words,
      total_memory_bytes: total_memory_words * :erlang.system_info(:wordsize),
      top_tables: top_tables
    }

    {:ok, metrics}
  rescue
    error -> {:error, Exception.message(error)}
  end

  @impl true
  def check(metrics) do
    config = Config.anomaly_config()
    table_threshold = get_in(config, [:ets_table_count, :threshold]) || 500

    if metrics[:table_count] > table_threshold do
      {:anomaly, :warning,
       %{
         metric: :ets_table_count,
         value: metrics[:table_count],
         threshold: table_threshold
       }}
    else
      :normal
    end
  end

  defp safe_table_name(tab) when is_atom(tab), do: tab
  defp safe_table_name(tab) when is_reference(tab), do: inspect(tab)
  defp safe_table_name(tab), do: inspect(tab)
end
