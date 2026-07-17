defmodule Mix.Tasks.Arbor.Status do
  @shortdoc "Show Arbor server status"
  @moduledoc """
  Displays the status of the running Arbor server.

      $ mix arbor.status

  When the node is reachable, shows uptime, memory, process count, and loaded
  Arbor apps. Distinguishes fully ready applications from a reachable-but-partial
  mid-boot node so distribution ping alone is not labeled as fully running.
  """
  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: Config
  alias Mix.Tasks.Arbor.Readiness

  @rpc_timeout_ms 5_000

  @impl Mix.Task
  def run(_args) do
    Config.ensure_distribution()

    if Config.server_running?() do
      print_reachable_status()
    else
      print_not_running()
    end
  end

  defp print_reachable_status do
    node = Config.full_node_name()
    expected = Readiness.expected_umbrella_apps(Mix.Project.apps_paths())
    observation = observe_started_apps(node)
    readiness = Readiness.classify_observation(expected, observation)
    status_label = Readiness.status_label(readiness)

    uptime = fetch_uptime(node)
    procs = Config.rpc(node, :erlang, :system_info, [:process_count])
    memory_bytes = Config.rpc(node, :erlang, :memory, [:total])
    apps = fetch_arbor_apps(observation)
    missing = missing_apps(readiness)
    pid = Config.read_pid()

    memory_mb =
      case memory_bytes do
        n when is_integer(n) -> Float.round(n / 1_048_576, 1)
        _ -> "?"
      end

    Mix.shell().info("""

    Arbor Server Status
    ═══════════════════════════════════════
      Status:     #{status_label}
      Node:       #{node}
      PID:        #{pid || "unknown"}
      Uptime:     #{uptime}
      Memory:     #{memory_mb} MB
      Processes:  #{procs}
      Arbor apps: #{format_apps(apps)}
      Expected:   #{length(expected)} umbrella apps
      Missing:    #{format_apps(missing)}
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

  defp observe_started_apps(node) do
    case :rpc.call(node, :application, :which_applications, [], @rpc_timeout_ms) do
      {:badrpc, reason} -> {:error, {:badrpc, reason}}
      apps when is_list(apps) -> {:ok, apps}
      other -> {:error, {:unexpected_rpc_result, other}}
    end
  end

  defp fetch_uptime(node) do
    case Config.rpc(node, :erlang, :statistics, [:wall_clock]) do
      {ms, _} when is_integer(ms) -> format_duration(ms)
      _ -> "unknown"
    end
  end

  defp fetch_arbor_apps({:ok, apps}) when is_list(apps) do
    apps
    |> Enum.map(fn {name, _, _} -> name end)
    |> Enum.filter(&(to_string(&1) |> String.starts_with?("arbor_")))
    |> Enum.sort()
  end

  defp fetch_arbor_apps(_), do: []

  defp missing_apps({:partial, missing, _present}), do: missing
  defp missing_apps(_), do: []

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
