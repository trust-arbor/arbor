defmodule Mix.Tasks.Arbor.Restart do
  @shortdoc "Restart the Arbor server"
  @moduledoc """
  Stops and restarts the Arbor background server.

      $ mix arbor.restart

  Equivalent to running `mix arbor.stop` followed by `mix arbor.start`.
  If the server is not running, starts it directly.
  """
  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: Config
  alias Mix.Tasks.Arbor.Start
  alias Mix.Tasks.Arbor.Stop

  @impl Mix.Task
  def run(args) do
    Config.ensure_distribution()

    if Config.server_running?() do
      Mix.shell().info("Restarting Arbor server...")
      Stop.run(args)
      # Brief pause to ensure the port is fully released
      Process.sleep(500)
    end

    Start.run(args)
  end
end
