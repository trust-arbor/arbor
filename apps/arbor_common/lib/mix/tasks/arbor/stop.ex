defmodule Mix.Tasks.Arbor.Stop do
  @shortdoc "Stop the running Arbor server"
  @moduledoc """
  Gracefully stops the Arbor background server.

      $ mix arbor.stop

  Sends `:init.stop/1` to the server node for a clean OTP shutdown.
  Falls back to SIGTERM via the PID file if the node doesn't stop in time.
  """
  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: Config

  @shutdown_timeout_ms 10_000
  @poll_interval_ms 500

  @impl Mix.Task
  def run(_args) do
    Config.ensure_distribution()

    unless Config.server_running?() do
      Mix.shell().info("Arbor is not running.")
      cleanup_stale_pid()
      return_ok()
    end

    Mix.shell().info("Stopping Arbor server...")

    # Request graceful OTP shutdown
    :rpc.call(Config.full_node_name(), :init, :stop, [0])

    case poll_until_stopped(@shutdown_timeout_ms) do
      :ok ->
        cleanup_pid_file()
        Mix.shell().info("Arbor server stopped.")

      :timeout ->
        Mix.shell().info("Node still responding, sending SIGTERM...")
        force_stop()
        cleanup_pid_file()
        Mix.shell().info("Arbor server stopped (forced).")
    end
  end

  defp poll_until_stopped(remaining) when remaining <= 0, do: :timeout

  defp poll_until_stopped(remaining) do
    Process.sleep(@poll_interval_ms)

    if Config.server_running?() do
      poll_until_stopped(remaining - @poll_interval_ms)
    else
      :ok
    end
  end

  defp force_stop do
    case Config.read_pid() do
      nil ->
        Mix.shell().error("No PID file found. You may need to kill the process manually.")

      pid ->
        System.cmd("kill", [to_string(pid)], stderr_to_stdout: true)
        # Give it a moment to die
        Process.sleep(1_000)
    end
  end

  defp cleanup_pid_file do
    File.rm(Config.pid_file())
  end

  defp cleanup_stale_pid do
    if File.exists?(Config.pid_file()) do
      Mix.shell().info("Removing stale PID file.")
      File.rm(Config.pid_file())
    end
  end

  defp return_ok, do: :ok
end
