defmodule Mix.Tasks.Arbor.Server.Start do
  @shortdoc "Start Arbor as a background daemon"
  @moduledoc """
  Starts Arbor as a detached Erlang node for development.

      $ mix arbor.server.start

  The server runs in the background with:
  - Node name: `arbor_dev@hostname`
  - Cookie: `arbor_dev`
  - Logs: `/tmp/arbor-dev.log`
  - PID file: `/tmp/arbor-dev.pid`

  Use `mix arbor.server.status` to check on it and
  `mix arbor.server.stop` to shut it down.
  """
  use Mix.Task

  alias Mix.Tasks.Arbor.Server, as: Config

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

    # -detached is an Erlang VM flag, passed via --erl.
    # System.cmd with explicit arg list avoids shell quoting issues.
    args = [
      "--erl", "-detached",
      "--sname", "#{Config.node_name()}@localhost",
      "--cookie", to_string(Config.cookie()),
      "-S", "mix", "run", "--no-halt"
    ]

    System.cmd("elixir", args,
      cd: project_dir,
      env: [{"MIX_ENV", to_string(Mix.env())}],
      stderr_to_stdout: true
    )

    # Write any startup errors we can capture to the log file
    File.touch(log_file)

    # Poll until the node responds or we time out
    case poll_until_ready(@startup_timeout_ms) do
      :ok ->
        pid = discover_pid()
        write_pid_file(pid)

        Mix.shell().info("""

        Arbor server started successfully.
          Node:  #{Config.full_node_name()}
          PID:   #{pid || "unknown"}
          Log:   #{log_file}

        Use `mix arbor.server.status` for details.
        Use `mix arbor.server.stop` to shut down.
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

  defp discover_pid do
    node_str = to_string(Config.node_name())

    case System.cmd("pgrep", ["-f", "sname #{node_str}"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> List.first()
        |> String.trim()
        |> String.to_integer()

      _ ->
        nil
    end
  end

  defp write_pid_file(nil), do: :ok

  defp write_pid_file(pid) do
    File.write!(Config.pid_file(), to_string(pid))
  end
end
