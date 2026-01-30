defmodule Mix.Tasks.Arbor.Attach do
  @shortdoc "Attach an IEx session to the running Arbor server"
  @moduledoc """
  Prints the command to attach an IEx remote shell to the running Arbor server.

      $ mix arbor.attach

  Since interactive sessions require a TTY, this task prints the `iex --remsh`
  command for you to run directly in your terminal.
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

    hostname = Config.node_hostname()

    suffix = :rand.uniform(99_999)
    attach_name = "arbor_attach_#{suffix}"

    cmd =
      "iex --sname #{attach_name} --cookie #{Config.cookie()} --remsh #{Config.node_name()}@#{hostname}"

    Mix.shell().info("""

    Run this command to attach to the Arbor server:

        #{cmd}

    Detach with Ctrl+C, Ctrl+C (this won't stop the server).
    """)
  end
end
