defmodule Mix.Tasks.Arbor.Eval do
  @shortdoc "Evaluate an expression on the running Arbor server"
  @moduledoc """
  Evaluates an Elixir expression on the running Arbor server via RPC.

      $ mix arbor.eval ":erlang.memory(:total)"
      $ mix arbor.eval "Arbor.Security.list_capabilities()"
      $ mix arbor.eval "Application.started_applications()"

  The expression is evaluated in the context of the remote server node.
  The result is inspected and printed to stdout.
  """
  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: Config

  @impl Mix.Task
  def run([]) do
    Mix.shell().error("Usage: mix arbor.eval <expression>")
    exit({:shutdown, 1})
  end

  def run(args) do
    Config.ensure_distribution()

    unless Config.server_running?() do
      Mix.shell().error("Arbor is not running. Start it with: mix arbor.start")
      exit({:shutdown, 1})
    end

    expr = Enum.join(args, " ")
    node = Config.full_node_name()

    case :rpc.call(node, Code, :eval_string, [expr]) do
      {:badrpc, reason} ->
        Mix.shell().error("RPC failed: #{inspect(reason)}")
        exit({:shutdown, 1})

      {result, _bindings} ->
        Mix.shell().info(inspect(result, pretty: true, limit: :infinity))
    end
  end
end
