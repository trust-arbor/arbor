defmodule Mix.Tasks.Arbor.Recompile do
  @shortdoc "Hot-reload changed modules on the running Arbor server"
  @moduledoc """
  Recompiles and hot-reloads changed modules on the running Arbor server.

      $ mix arbor.recompile

  Uses `IEx.Helpers.recompile/0` on the remote node to detect and reload
  any modules whose source has changed since last compilation.
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

    node = Config.full_node_name()
    Mix.shell().info("Recompiling on #{node}...")

    case :rpc.call(node, IEx.Helpers, :recompile, []) do
      {:badrpc, reason} ->
        Mix.shell().error("RPC failed: #{inspect(reason)}")
        exit({:shutdown, 1})

      :noop ->
        Mix.shell().info("No modules changed.")

      {:recompiled, modules} when is_list(modules) ->
        Mix.shell().info("Recompiled #{length(modules)} module(s):")

        Enum.each(modules, fn mod ->
          Mix.shell().info("  #{inspect(mod)}")
        end)

      other ->
        Mix.shell().info("Result: #{inspect(other)}")
    end
  end
end
