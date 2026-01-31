defmodule Mix.Tasks.Arbor.Start do
  @shortdoc "Start Arbor as a background daemon"
  @moduledoc """
  Starts Arbor as a detached background process for development.

      $ mix arbor.start

  The server runs in the background with:
  - Node name: `arbor_dev@localhost`
  - Cookie: `arbor_dev`
  - Logs: `~/.arbor/logs/arbor-dev.log`
  - PID file: `/tmp/arbor-dev.pid`

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

    Mix.shell().info("Starting Arbor server...")

    project_dir = File.cwd!()
    log_file = Config.log_file()

    # Background via shell so stdout/stderr flow to the log file for `mix arbor.logs`.
    # The shell returns the PID immediately via `echo $!`.
    elixir_cmd =
      "elixir --sname #{Config.node_name()}@localhost " <>
        "--cookie #{Config.cookie()} -S mix run --no-halt " <>
        "> #{log_file} 2>&1 & echo $!"

    {output, 0} =
      System.cmd("sh", ["-c", elixir_cmd],
        cd: project_dir,
        env: [{"MIX_ENV", to_string(Mix.env())}]
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
end
