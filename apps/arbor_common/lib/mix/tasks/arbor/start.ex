defmodule Mix.Tasks.Arbor.Start do
  @shortdoc "Start Arbor as a background daemon"
  @moduledoc """
  Starts Arbor as a detached background process for development.

      $ mix arbor.start

  The server runs in the background with:
  - Node name: `arbor_dev@localhost` (or `arbor_dev@<ip>` with ARBOR_NODE_HOST)
  - Cookie: from ARBOR_COOKIE env var
  - Logs: `~/.arbor/logs/arbor-dev.log`
  - PID file: `~/.arbor/arbor-dev.pid`

  ## Environment Variables

  - `ARBOR_COOKIE` (required) — distribution cookie for cluster authentication
  - `ARBOR_NODE_HOST` (optional) — IP or FQDN for cross-machine clustering.
    When set, uses longnames (`--name`). Defaults to localhost with shortnames (`--sname`).

  ## Examples

      # Local development (shortnames)
      ARBOR_COOKIE=secret mix arbor.start

      # Cross-machine clustering (longnames)
      ARBOR_NODE_HOST=10.42.42.101 ARBOR_COOKIE=secret mix arbor.start

  Use `mix arbor.status` to check on it and
  `mix arbor.stop` to shut it down.
  """
  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: Config

  @startup_timeout_ms 15_000
  @poll_interval_ms 500

  @impl Mix.Task
  def run(_args) do
    Config.ensure_distribution()

    if Config.server_running?() do
      Mix.shell().error("Arbor is already running at #{Config.full_node_name()}")
      exit({:shutdown, 1})
    end

    host = Config.node_hostname()

    host_source =
      cond do
        System.get_env("ARBOR_NODE_HOST") -> "(from ARBOR_NODE_HOST)"
        Config.detect_wireguard_ip() -> "(WireGuard auto-detected)"
        true -> "(localhost — no VPN, local only)"
      end

    Mix.shell().info("Starting Arbor server...")
    Mix.shell().info("  Host: #{host} #{host_source}")

    project_dir = File.cwd!()
    log_file = Config.log_file()

    # Fresh nodes don't have ~/.arbor/logs yet — create it before the shell
    # redirect below writes to it (otherwise: "cannot create … Directory
    # nonexistent"). Covers `mix arbor.restart` too (it delegates to Start.run).
    Config.ensure_runtime_dirs()

    # Rotate the previous log before the `> log_file` truncate below wipes it. Keeps 3 generations
    # (arbor-dev.log.1/.2/.3) so a crash's evidence survives a restart — truncating on every start is
    # exactly what erased the 2026-07-04 node-crash logs and forced a Postgres-EventLog reconstruction.
    rotate_log(log_file)

    # Resolve the real elixir and mix paths from the running Elixir installation.
    # This avoids mise/asdf shim binaries which are Mach-O executables that
    # crash when loaded by `elixir -S mix` (Code.require_file tries to parse
    # the binary as Elixir source).
    {elixir_path, mix_path} = resolve_real_paths()

    # Background via shell so stdout/stderr flow to the log file for `mix arbor.logs`.
    # The shell returns the PID immediately via `echo $!`.
    name_flag = if Config.longnames?(), do: "--name", else: "--sname"

    # Pin Erlang distribution to a predictable port range for firewalls
    # Increase net_ticktime to 120s (disconnect after ~8 min of no response)
    # to tolerate brief network hiccups and idle periods
    erl_flags =
      "--erl '-kernel inet_dist_listen_min 9100 inet_dist_listen_max 9155 net_ticktime 120'"

    elixir_cmd =
      "#{elixir_path} #{name_flag} #{Config.full_node_name()} " <>
        "--cookie #{Config.cookie()} #{erl_flags} #{mix_path} run --no-halt " <>
        "> #{log_file} 2>&1 & echo $!"

    # Inherit the full environment so API keys, PATH, etc. are available.
    # Only override MIX_ENV explicitly.
    env =
      System.get_env()
      |> Map.put("MIX_ENV", to_string(Mix.env()))
      |> Enum.to_list()

    {output, 0} =
      System.cmd("sh", ["-c", elixir_cmd],
        cd: project_dir,
        env: env
      )

    pid =
      output
      |> String.trim()
      |> String.split("\n")
      |> List.last()
      |> String.to_integer()

    write_pid_file(pid)

    # Poll until the node responds or we time out
    case poll_until_ready(@startup_timeout_ms) do
      :ok ->
        Mix.shell().info("""

        Arbor server started successfully.
          Node:  #{Config.full_node_name()}
          PID:   #{pid}
          Log:   #{log_file}

        Use `mix arbor.status` for details.
        Use `mix arbor.stop` to shut down.
        """)

      :timeout ->
        Mix.shell().error("""

        Arbor server did not respond within #{div(@startup_timeout_ms, 1000)} seconds.
        Check the log file for errors: #{log_file}
        """)

        exit({:shutdown, 1})
    end
  end

  defp poll_until_ready(remaining) when remaining <= 0, do: :timeout

  defp poll_until_ready(remaining) do
    Process.sleep(@poll_interval_ms)

    if Config.server_running?() do
      :ok
    else
      poll_until_ready(remaining - @poll_interval_ms)
    end
  end

  defp write_pid_file(pid) do
    File.write!(Config.pid_file(), to_string(pid))
  end

  # Keep the last 3 log generations (.1 newest → .3 oldest) so the shell's `> log_file` truncate on
  # start doesn't erase the previous run's log. Shift .2→.3, .1→.2, log→.1; the truncate then makes a
  # fresh log. No-op for a missing/empty log. Best-effort — never block startup on a rename error.
  defp rotate_log(log_file) do
    if File.exists?(log_file) and File.stat!(log_file).size > 0 do
      for n <- 3..1//-1 do
        src = if n == 1, do: log_file, else: "#{log_file}.#{n - 1}"
        dst = "#{log_file}.#{n}"
        if File.exists?(src), do: File.rename(src, dst)
      end
    end
  rescue
    _ -> :ok
  end

  defp resolve_real_paths do
    # Derive the real elixir and mix scripts from the Elixir installation
    # powering this VM. :code.lib_dir(:elixir) returns e.g. ".../lib/elixir",
    # so we go up to the installation root and find bin/elixir and bin/mix —
    # guaranteed to be the real scripts, not version-manager shim binaries.
    elixir_lib = :code.lib_dir(:elixir) |> to_string() |> Path.expand()
    elixir_root = elixir_lib |> Path.dirname() |> Path.dirname()
    real_elixir = Path.join([elixir_root, "bin", "elixir"])
    real_mix = Path.join([elixir_root, "bin", "mix"])

    elixir_path = if File.exists?(real_elixir), do: real_elixir, else: "elixir"
    mix_path = if File.exists?(real_mix), do: real_mix, else: "-S mix"

    {elixir_path, mix_path}
  end
end
