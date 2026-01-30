defmodule Mix.Tasks.Arbor.Server.Status do
  @shortdoc "Show Arbor server status"
  @moduledoc """
  Displays the status of the running Arbor server.

      $ mix arbor.server.status

  When running, shows uptime, memory, process count, and loaded Arbor apps.
  """
  use Mix.Task

  alias Mix.Tasks.Arbor.Server, as: Config

  @impl Mix.Task
  def run(_args) do
    Config.ensure_distribution()

    if Config.server_running?() do
      print_running_status()
    else
      print_not_running()
    end
  end

  defp print_running_status do
    node = Config.full_node_name()

    uptime = fetch_uptime(node)
    procs = rpc(node, :erlang, :system_info, [:process_count])
    memory_bytes = rpc(node, :erlang, :memory, [:total])
    apps = fetch_arbor_apps(node)
    pid = Config.read_pid()

    memory_mb =
      case memory_bytes do
        n when is_integer(n) -> Float.round(n / 1_048_576, 1)
        _ -> "?"
      end

    Mix.shell().info("""

    Arbor Server Status
    ═══════════════════════════════════════
      Status:     running
      Node:       #{node}
      PID:        #{pid || "unknown"}
      Uptime:     #{uptime}
      Memory:     #{memory_mb} MB
      Processes:  #{procs}
      Arbor apps: #{format_apps(apps)}
    ═══════════════════════════════════════
    """)
  end

  defp print_not_running do
    msg = "Arbor is not running."

    msg =
      if File.exists?(Config.pid_file()) do
        msg <> " (stale PID file exists at #{Config.pid_file()})"
      else
        msg
      end

    Mix.shell().info(msg)
  end

  defp fetch_uptime(node) do
    case rpc(node, :erlang, :statistics, [:wall_clock]) do
      {ms, _} when is_integer(ms) -> format_duration(ms)
      _ -> "unknown"
    end
  end

  defp fetch_arbor_apps(node) do
    case rpc(node, :application, :which_applications, []) do
      apps when is_list(apps) ->
        apps
        |> Enum.map(fn {name, _, _} -> name end)
        |> Enum.filter(&(to_string(&1) |> String.starts_with?("arbor_")))
        |> Enum.sort()

      _ ->
        []
    end
  end

  defp rpc(node, mod, fun, args) do
    case :rpc.call(node, mod, fun, args) do
      {:badrpc, _reason} -> nil
      result -> result
    end
  end

  defp format_duration(ms) do
    total_seconds = div(ms, 1000)
    days = div(total_seconds, 86_400)
    hours = div(rem(total_seconds, 86_400), 3600)
    minutes = div(rem(total_seconds, 3600), 60)
    seconds = rem(total_seconds, 60)

    parts =
      [{days, "d"}, {hours, "h"}, {minutes, "m"}, {seconds, "s"}]
      |> Enum.reject(fn {val, _} -> val == 0 end)
      |> Enum.map(fn {val, unit} -> "#{val}#{unit}" end)

    case parts do
      [] -> "0s"
      _ -> Enum.join(parts, " ")
    end
  end

  defp format_apps([]), do: "none"
  defp format_apps(apps), do: Enum.join(apps, ", ")
end
