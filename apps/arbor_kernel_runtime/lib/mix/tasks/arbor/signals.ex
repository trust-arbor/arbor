defmodule Mix.Tasks.Arbor.Signals do
  @shortdoc "View recent signals from the running Arbor server"
  @moduledoc """
  Displays recent signals from the Arbor signals system.

      $ mix arbor.signals
      $ mix arbor.signals --limit 50
      $ mix arbor.signals --category shell
      $ mix arbor.signals --type command_started
      $ mix arbor.signals --category action --limit 10

  ## Options

    * `--limit` / `-n` - Number of signals to fetch (default: 20)
    * `--category` - Filter by signal category (e.g., "action", "shell", "comms")
    * `--type` - Filter by signal type (e.g., "command_started", "completed")
    * `--help` / `-h` - Show this help message

  ## Output Format

  Each signal is displayed as:

      [HH:MM:SS] category/type  — data_summary
  """
  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: Config

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        aliases: [n: :limit, h: :help],
        strict: [limit: :integer, category: :string, type: :string, help: :boolean]
      )

    if opts[:help] do
      print_usage()
      exit(:normal)
    end

    Config.ensure_distribution()

    unless Config.server_running?() do
      Mix.shell().error("Arbor is not running. Start it with: mix arbor.start")
      exit({:shutdown, 1})
    end

    limit = opts[:limit] || 20
    category_filter = opts[:category]
    type_filter = opts[:type]

    node = Config.full_node_name()

    case :rpc.call(node, Arbor.Signals, :recent, [[limit: limit]]) do
      {:badrpc, reason} ->
        Mix.shell().error("Failed to fetch signals: #{inspect(reason)}")
        exit({:shutdown, 1})

      {:ok, signals} when is_list(signals) ->
        signals
        |> filter_signals(category_filter, type_filter)
        |> display_signals()

      {:error, reason} ->
        Mix.shell().error("Error fetching signals: #{inspect(reason)}")
        exit({:shutdown, 1})

      other ->
        Mix.shell().error("Unexpected response: #{inspect(other)}")
        exit({:shutdown, 1})
    end
  end

  defp filter_signals(signals, nil, nil), do: signals

  defp filter_signals(signals, category_filter, type_filter) do
    Enum.filter(signals, fn signal ->
      matches_category?(signal, category_filter) and matches_type?(signal, type_filter)
    end)
  end

  defp matches_category?(_signal, nil), do: true

  defp matches_category?(signal, category) do
    to_string(signal.category) == category
  end

  defp matches_type?(_signal, nil), do: true

  defp matches_type?(signal, type) do
    to_string(signal.type) == type
  end

  defp display_signals([]) do
    Mix.shell().info("No signals found.")
  end

  defp display_signals(signals) do
    Mix.shell().info("")

    Enum.each(signals, fn signal ->
      time = format_time(signal.timestamp)
      category = signal.category
      type = signal.type
      summary = summarize_data(signal)

      Mix.shell().info("[#{time}] #{category}/#{type}  \u2014 #{summary}")
    end)

    Mix.shell().info("\n#{length(signals)} signal(s) displayed.")
  end

  defp format_time(%DateTime{} = dt) do
    dt
    |> Calendar.strftime("%H:%M:%S")
  end

  defp format_time(_), do: "??:??:??"

  defp summarize_data(%{category: :action, data: data}) do
    cond do
      Map.has_key?(data, :module) ->
        "module=#{inspect(data.module)}"

      Map.has_key?(data, :action) ->
        "action=#{data.action}"

      true ->
        summarize_map(data)
    end
  end

  defp summarize_data(%{category: :shell, data: data}) do
    cond do
      Map.has_key?(data, :command) ->
        truncate("cmd=#{data.command}", 60)

      Map.has_key?(data, :cmd) ->
        truncate("cmd=#{data.cmd}", 60)

      true ->
        summarize_map(data)
    end
  end

  defp summarize_data(%{data: data}) do
    summarize_map(data)
  end

  defp summarize_map(data) when data == %{}, do: "(no data)"

  defp summarize_map(data) when is_map(data) do
    data
    |> Enum.take(3)
    |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{format_value(v)}" end)
  end

  defp summarize_map(_), do: "(no data)"

  defp format_value(v) when is_binary(v), do: truncate(v, 40)
  defp format_value(v) when is_atom(v), do: to_string(v)
  defp format_value(v) when is_number(v), do: to_string(v)
  defp format_value(v), do: truncate(inspect(v), 40)

  defp truncate(str, max) when is_binary(str) do
    if String.length(str) > max do
      String.slice(str, 0, max - 3) <> "..."
    else
      str
    end
  end

  defp truncate(other, max), do: truncate(to_string(other), max)

  defp print_usage do
    Mix.shell().info("""
    Usage: mix arbor.signals [options]

    Options:
      -n, --limit N        Number of signals to fetch (default: 20)
          --category CAT   Filter by category (e.g., "action", "shell", "comms")
          --type TYPE      Filter by type (e.g., "command_started", "completed")
      -h, --help           Show this help message

    Examples:
      mix arbor.signals
      mix arbor.signals --limit 50
      mix arbor.signals --category shell
      mix arbor.signals --category action --type completed
    """)
  end
end
