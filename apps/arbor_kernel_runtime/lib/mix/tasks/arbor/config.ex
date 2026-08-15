defmodule Mix.Tasks.Arbor.Config do
  @shortdoc "Show app config for an Arbor application"
  @moduledoc """
  Displays runtime configuration for an Arbor application from the running server.

      $ mix arbor.config                  # List all arbor_* apps
      $ mix arbor.config arbor_comms      # Show config for arbor_comms
      $ mix arbor.config arbor_security   # Show config for arbor_security

  Fetches configuration via RPC from the running server node, so you see
  the actual runtime config rather than compile-time config.
  """
  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: Config

  @impl Mix.Task
  def run(args) do
    Config.ensure_distribution()

    unless Config.server_running?() do
      Mix.shell().error("Arbor is not running. Start it with: mix arbor.start")
      exit({:shutdown, 1})
    end

    node = Config.full_node_name()

    case args do
      [] -> list_arbor_apps(node)
      [app_name | _] -> show_app_config(node, app_name)
    end
  end

  defp list_arbor_apps(node) do
    apps = Config.rpc(node, :application, :which_applications, []) || []

    arbor_apps =
      apps
      |> Enum.map(fn {name, _, _} -> name end)
      |> Enum.filter(&(to_string(&1) |> String.starts_with?("arbor_")))
      |> Enum.sort()

    Mix.shell().info("\nArbor applications with config:")

    if arbor_apps == [] do
      Mix.shell().info("  (none found)")
    else
      Enum.each(arbor_apps, fn app ->
        Mix.shell().info("  #{app}")
      end)

      Mix.shell().info("\nUse `mix arbor.config <app_name>` to view config.")
    end
  end

  defp show_app_config(node, app_name) do
    app_atom = String.to_existing_atom(app_name)

    case Config.rpc(node, Application, :get_all_env, [app_atom]) do
      nil ->
        Mix.shell().error("Failed to fetch config for #{app_name}.")
        exit({:shutdown, 1})

      [] ->
        Mix.shell().info("No configuration set for #{app_name}.")

      env when is_list(env) ->
        Mix.shell().info("\nConfig for #{app_name}:\n")

        env
        |> Enum.sort_by(fn {key, _} -> key end)
        |> Enum.each(fn {key, value} ->
          formatted = inspect(value, pretty: true, limit: 50, width: 60)
          Mix.shell().info("  #{key}: #{formatted}")
        end)
    end
  rescue
    ArgumentError ->
      Mix.shell().error("Unknown application: #{app_name}")
      exit({:shutdown, 1})
  end
end
