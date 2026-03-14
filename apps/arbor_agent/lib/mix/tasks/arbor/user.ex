defmodule Mix.Tasks.Arbor.User do
  @moduledoc """
  Manage Arbor users.

  Users are identified by their OIDC-derived agent IDs (`human_<hash>`).
  This task provides visibility into known users and their workspaces.

  ## Usage

      mix arbor.user              # list all known users
      mix arbor.user list         # same as above
      mix arbor.user show <id>    # show user details
      mix arbor.user setup <id>   # ensure workspace directory exists
  """

  use Mix.Task

  @shortdoc "Manage Arbor users"

  @impl Mix.Task
  def run(args) do
    {_opts, args, _} = OptionParser.parse(args, strict: [])

    # Start the app to access stores
    Mix.Task.run("app.start", [])

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
        workspace = Arbor.Contracts.TenantContext.default_workspace_root(user.id)
        workspace_exists = File.dir?(workspace)

        status =
          if workspace_exists, do: "workspace: #{workspace}", else: "no workspace"

        agent_count =
          if Code.ensure_loaded?(Arbor.Agent.Manager) do
            length(Arbor.Agent.Manager.list_agents_for_principal(user.id))
          else
            "?"
          end

        Mix.shell().info(
          "  #{user.id}  agents: #{agent_count}  #{status}" <>
            if(user.display_name, do: "  (#{user.display_name})", else: "")
        )
      end
    end
  end

  defp show_user(user_id) do
    workspace = Arbor.Contracts.TenantContext.default_workspace_root(user_id)

    Mix.shell().info("User: #{user_id}")
    Mix.shell().info("  Workspace: #{workspace}")
    Mix.shell().info("  Workspace exists: #{File.dir?(workspace)}")

    if Code.ensure_loaded?(Arbor.Agent.Manager) do
      agents = Arbor.Agent.Manager.list_agents_for_principal(user_id)
      Mix.shell().info("  Agents: #{length(agents)}")

      for agent <- agents do
        display = Map.get(agent.metadata, :display_name, agent.agent_id)
        Mix.shell().info("    - #{agent.agent_id} (#{display})")
      end
    end
  end

  defp setup_user(user_id) do
    workspace = Arbor.Contracts.TenantContext.default_workspace_root(user_id)

    case File.mkdir_p(workspace) do
      :ok ->
        Mix.shell().info("Workspace created: #{workspace}")

      {:error, reason} ->
        Mix.shell().error("Failed to create workspace: #{inspect(reason)}")
    end
  end

  # Discover users from profile metadata and identity registry
  defp discover_users do
    profile_users = discover_from_profiles()
    identity_users = discover_from_identities()

    # Merge and deduplicate
    all_ids = MapSet.new(Enum.map(profile_users ++ identity_users, & &1.id))

    Enum.uniq_by(profile_users ++ identity_users, & &1.id)
    |> Enum.filter(fn u -> MapSet.member?(all_ids, u.id) end)
    |> Enum.sort_by(& &1.id)
  end

  defp discover_from_profiles do
    if Code.ensure_loaded?(Arbor.Agent.ProfileStore) do
      try do
        case Arbor.Agent.ProfileStore.list_profiles() do
          {:ok, profiles} ->
            profiles
            |> Enum.map(fn p -> Map.get(p.metadata || %{}, :created_by) end)
            |> Enum.reject(&is_nil/1)
            |> Enum.uniq()
            |> Enum.map(&%{id: &1, display_name: nil, source: :profile})

          _ ->
            []
        end
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end
    else
      []
    end
  end

  defp discover_from_identities do
    # Look for human_* entries in the identity registry
    if Code.ensure_loaded?(Arbor.Security) and
         function_exported?(Arbor.Security, :list_identities, 0) do
      try do
        case apply(Arbor.Security, :list_identities, []) do
          {:ok, identities} ->
            identities
            |> Enum.filter(fn id -> String.starts_with?(id.agent_id, "human_") end)
            |> Enum.map(&%{id: &1.agent_id, display_name: &1.name, source: :identity})

          _ ->
            []
        end
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end
    else
      []
    end
  end
end
