defmodule Mix.Tasks.Arbor.Status do
  @shortdoc "Show Arbor server status"
  @moduledoc """
  Displays the status of the running Arbor server.

      $ mix arbor.status

  Resolves the persisted managed node identity (metadata file, or the
  legacy PID file when no metadata exists) and verifies it via an exact,
  bounded process-identity check before displaying it — never a freshly
  re-detected host. When the node is reachable, shows uptime, memory,
  process count, and loaded Arbor apps. Distinguishes fully ready
  applications from a reachable-but-partial mid-boot node so distribution
  ping alone is not labeled as fully running.
  """
  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: Config
  alias Mix.Tasks.Arbor.LifecycleIdentity
  alias Mix.Tasks.Arbor.Readiness

  @rpc_timeout_ms 5_000

  @impl Mix.Task
  def run(_args) do
    Config.ensure_distribution()

    case resolve_managed_node() do
      {:ok, node_string, pid} ->
        if Config.node_alive?(node_string) do
          print_reachable_status(node_string, pid)
        else
          print_unreachable_status(node_string, pid)
        end

      :ambiguous ->
        print_ambiguous()

      :none ->
        print_not_running()
    end
  end

  @doc false
  # 3-way result (:ok/:ambiguous/:none) rather than a 2-way ok/fallback —
  # a malformed metadata or legacy-PID read means tracking state exists
  # but can't be trusted, which must be surfaced distinctly rather than
  # silently reported as "Arbor is not running."
  @spec resolve_managed_node(String.t()) :: {:ok, String.t(), pos_integer()} | :ambiguous | :none
  def resolve_managed_node(home \\ Config.arbor_home()) do
    metadata = Config.read_metadata(home)

    metadata_pid_check =
      case metadata do
        {:ok, meta} -> Config.verify_pid_as_arbor_node(meta.pid)
        _other -> nil
      end

    {legacy_pid_present?, legacy_pid, legacy_pid_check} =
      if metadata == :absent, do: legacy_pid_facts(home), else: {false, nil, nil}

    case LifecycleIdentity.decide_status(%{
           metadata: metadata,
           metadata_pid_check: metadata_pid_check,
           legacy_pid_present?: legacy_pid_present?,
           legacy_pid: legacy_pid,
           legacy_pid_check: legacy_pid_check
         }) do
      {:managed, node, pid} -> {:ok, node, pid}
      other -> other
    end
  end

  defp legacy_pid_facts(home) do
    case Config.read_pid(home) do
      {:ok, pid} ->
        {true, pid, Config.verify_pid_as_arbor_node(pid)}

      {:error, :malformed} ->
        {true, nil, :unverified}

      :absent ->
        {false, nil, nil}
    end
  end

  defp print_reachable_status(node_string, pid) do
    node = Config.node_atom(node_string)
    expected = Readiness.expected_umbrella_apps(Mix.Project.apps_paths())
    observation = observe_started_apps(node)
    readiness = Readiness.classify_observation(expected, observation)
    status_label = Readiness.status_label(readiness)

    uptime = fetch_uptime(node)
    procs = Config.rpc(node, :erlang, :system_info, [:process_count])
    memory_bytes = Config.rpc(node, :erlang, :memory, [:total])
    apps = fetch_arbor_apps(observation)
    missing_label = Readiness.status_missing_label(readiness)

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
      PID:        #{pid}
      Uptime:     #{uptime}
      Memory:     #{memory_mb} MB
      Processes:  #{procs}
      Arbor apps: #{format_apps(apps)}
      Expected:   #{length(expected)} umbrella apps
      Missing:    #{missing_label}
    ═══════════════════════════════════════
    """)
  end

  defp print_ambiguous do
    Mix.shell().error("""

    Tracking state exists under #{Config.arbor_home()} but could not be
    verified (malformed metadata, or its recorded PID's identity could not
    be confirmed either way). Inspect #{Config.metadata_file()} and
    #{Config.pid_file()} manually.
    """)
  end

  defp print_unreachable_status(node_string, pid) do
    Mix.shell().info("""

    Arbor Server Status
    ═══════════════════════════════════════
      Status:     process alive; distributed node unreachable
      Node:       #{node_string}
      PID:        #{pid}
      Tracking:   verified
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
