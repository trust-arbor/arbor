defmodule Mix.Tasks.Arbor.Apps do
  @shortdoc "List running Arbor applications with status"
  @moduledoc """
  Lists all Arbor applications and their status on the running server.

      $ mix arbor.apps

  Shows a table of arbor_* applications with their version and whether
  they are started, loaded, or not loaded.
  """
  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: Config

  @impl Mix.Task
  def run(_args) do
    Config.ensure_distribution()

    unless Config.server_running?() do
      Mix.shell().error("Arbor is not running. Start it with: mix arbor.start")
      exit({:shutdown, 1})
    end

    node = Config.full_node_name()

    started = Config.rpc(node, :application, :which_applications, []) || []
    loaded = Config.rpc(node, :application, :loaded_applications, []) || []

    started_map =
      started
      |> Enum.filter(fn {name, _, _} -> to_string(name) |> String.starts_with?("arbor_") end)
      |> Map.new(fn {name, _desc, vsn} -> {name, {:started, to_string(vsn)}} end)

    loaded_map =
      loaded
      |> Enum.filter(fn {name, _, _} -> to_string(name) |> String.starts_with?("arbor_") end)
      |> Map.new(fn {name, _desc, vsn} -> {name, {:loaded, to_string(vsn)}} end)

    # Merge: started takes precedence over loaded
    all_apps = Map.merge(loaded_map, started_map)

    if all_apps == %{} do
      Mix.shell().info("No arbor_* applications found.")
    else
      print_table(all_apps)
    end
  end

  defp print_table(apps) do
    rows =
      apps
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map(fn {name, {status, vsn}} ->
        status_str =
          case status do
            :started -> "started"
            :loaded -> "loaded"
          end

        {to_string(name), vsn, status_str}
      end)

    # Calculate column widths
    name_width = rows |> Enum.map(fn {n, _, _} -> String.length(n) end) |> Enum.max()
    vsn_width = rows |> Enum.map(fn {_, v, _} -> String.length(v) end) |> Enum.max()
    name_width = max(name_width, 11)
    vsn_width = max(vsn_width, 7)

    header =
      String.pad_trailing("Application", name_width) <>
        "  " <>
        String.pad_trailing("Version", vsn_width) <>
        "  " <>
        "Status"

    separator = String.duplicate("─", String.length(header) + 2)

    Mix.shell().info("\n#{header}")
    Mix.shell().info(separator)

    Enum.each(rows, fn {name, vsn, status} ->
      line =
        String.pad_trailing(name, name_width) <>
          "  " <>
          String.pad_trailing(vsn, vsn_width) <>
          "  " <>
          status

      Mix.shell().info(line)
    end)

    Mix.shell().info("")
  end
end
