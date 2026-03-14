defmodule Mix.Tasks.Arbor.User do
  @moduledoc """
  Manage Arbor users via RPC to the running server.

  Users are identified by their OIDC-derived agent IDs (`human_<hash>`).
  This task provides visibility into known users and their workspaces.

  ## Usage

      mix arbor.user              # list all known users
      mix arbor.user list         # same as above
      mix arbor.user show <id>    # show user details
      mix arbor.user setup <id>   # ensure workspace directory exists
  """

  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: Config

  @shortdoc "Manage Arbor users"

  @impl Mix.Task
  def run(args) do
    {_opts, args, _} = OptionParser.parse(args, strict: [])

    Config.ensure_distribution()

    unless Config.server_running?() do
      Mix.shell().error("Arbor server is not running. Start it with: mix arbor.start")
      exit({:shutdown, 1})
    end

    case args do
      [] -> list_users()
      ["list"] -> list_users()
      ["show", user_id] -> show_user(user_id)
      ["setup", user_id] -> setup_user(user_id)
      _ -> Mix.shell().error("Usage: mix arbor.user [list|show <id>|setup <id>]")
    end
  end

  defp list_users do
    users = discover_users()

    if users == [] do
      Mix.shell().info("No users found. Users are created via OIDC login.")
    else
      Mix.shell().info("Known users (#{length(users)}):\n")

      for user <- users do
        workspace = rpc!(Arbor.Contracts.TenantContext, :default_workspace_root, [user.id])
        workspace_exists = File.dir?(workspace)

        status =
          if workspace_exists, do: "workspace: #{workspace}", else: "no workspace"

        agent_count =
          case Config.rpc(
                 Config.full_node_name(),
                 Arbor.Agent.Manager,
                 :list_agents_for_principal,
                 [user.id]
               ) do
            agents when is_list(agents) -> length(agents)
            _ -> "?"
          end

        Mix.shell().info(
          "  #{user.id}  agents: #{agent_count}  #{status}" <>
            if(user.display_name, do: "  (#{user.display_name})", else: "")
        )
      end
    end
  end

  defp show_user(user_id) do
    workspace = rpc!(Arbor.Contracts.TenantContext, :default_workspace_root, [user_id])

    Mix.shell().info("User: #{user_id}")
    Mix.shell().info("  Workspace: #{workspace}")
    Mix.shell().info("  Workspace exists: #{File.dir?(workspace)}")

    case Config.rpc(Config.full_node_name(), Arbor.Agent.Manager, :list_agents_for_principal, [
           user_id
         ]) do
      agents when is_list(agents) ->
        Mix.shell().info("  Agents: #{length(agents)}")

        for agent <- agents do
          display = Map.get(agent.metadata || %{}, :display_name, agent.agent_id)
          Mix.shell().info("    - #{agent.agent_id} (#{display})")
        end

      _ ->
        Mix.shell().info("  Agents: ?")
    end

    case Config.rpc(Config.full_node_name(), Arbor.Agent.UserConfig, :get_all, [user_id]) do
      config when is_map(config) and map_size(config) > 0 ->
        Mix.shell().info("  Config:")

        Enum.each(config, fn {k, v} ->
          display = if k == :api_keys, do: "(#{map_size(v || %{})} keys)", else: inspect(v)
          Mix.shell().info("    #{k}: #{display}")
        end)

      _ ->
        :ok
    end
  end

  defp setup_user(user_id) do
    workspace = rpc!(Arbor.Contracts.TenantContext, :default_workspace_root, [user_id])

    case File.mkdir_p(workspace) do
      :ok ->
        Mix.shell().info("Workspace created: #{workspace}")

      {:error, reason} ->
        Mix.shell().error("Failed to create workspace: #{inspect(reason)}")
    end
  end

  # Discover users from profile metadata and identity registry via RPC
  defp discover_users do
    node = Config.full_node_name()
    profile_users = discover_from_profiles(node)
    identity_users = discover_from_identities(node)

    Enum.uniq_by(profile_users ++ identity_users, & &1.id)
    |> Enum.sort_by(& &1.id)
  end

  defp discover_from_profiles(node) do
    case Config.rpc(node, Arbor.Agent.ProfileStore, :list_profiles, []) do
      profiles when is_list(profiles) ->
        profiles
        |> Enum.map(fn p -> Map.get(p.metadata || %{}, :created_by) end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.map(&%{id: &1, display_name: nil, source: :profile})

      {:ok, profiles} when is_list(profiles) ->
        profiles
        |> Enum.map(fn p -> Map.get(p.metadata || %{}, :created_by) end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.map(&%{id: &1, display_name: nil, source: :profile})

      _ ->
        []
    end
  end

  defp discover_from_identities(node) do
    case Config.rpc(node, Arbor.Security, :list_identities, []) do
      {:ok, identities} when is_list(identities) ->
        identities
        |> Enum.filter(fn id -> String.starts_with?(id.agent_id, "human_") end)
        |> Enum.map(&%{id: &1.agent_id, display_name: &1.name, source: :identity})

      _ ->
        []
    end
  end

  defp rpc!(mod, fun, args) do
    Config.rpc!(Config.full_node_name(), mod, fun, args)
  end
end
