defmodule Mix.Tasks.Arbor.User.Link do
  @moduledoc """
  Link or unlink OIDC identities via RPC to the running server.

  ## Usage

      mix arbor.user.link <secondary_id> <primary_id>   # link secondary → primary
      mix arbor.user.link --unlink <secondary_id>        # remove a link
      mix arbor.user.link --list <primary_id>             # list linked identities

  ## Examples

      # Link a new Zitadel account to your existing identity
      mix arbor.user.link human_abc123 human_def456

      # See what's linked to an identity
      mix arbor.user.link --list human_def456

      # Remove a link
      mix arbor.user.link --unlink human_abc123
  """

  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: Config

  @shortdoc "Link OIDC identities to a primary Arbor identity"

  @switches [
    unlink: :string,
    list: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, args, _} = OptionParser.parse(args, strict: @switches)

    Config.ensure_distribution()

    unless Config.server_running?() do
      Mix.shell().error("Arbor server is not running. Start it with: mix arbor.start")
      exit({:shutdown, 1})
    end

    cond do
      opts[:list] ->
        list_aliases(opts[:list])

      opts[:unlink] ->
        unlink(opts[:unlink])

      length(args) == 2 ->
        [secondary_id, primary_id] = args
        link(secondary_id, primary_id)

      true ->
        Mix.shell().error("""
        Usage:
          mix arbor.user.link <secondary_id> <primary_id>
          mix arbor.user.link --unlink <secondary_id>
          mix arbor.user.link --list <primary_id>
        """)
    end
  end

  defp link(secondary_id, primary_id) do
    # Show what we're about to do
    Mix.shell().info("Linking #{secondary_id} → #{primary_id}")
    Mix.shell().info("  All logins producing #{secondary_id} will resolve to #{primary_id}")

    case rpc!(Arbor.Agent.IdentityAliases, :link, [secondary_id, primary_id]) do
      :ok ->
        Mix.shell().info("Linked successfully.")

      {:error, :cannot_alias_self} ->
        Mix.shell().error("Cannot link an identity to itself.")

      {:error, {:primary_is_alias, resolved}} ->
        Mix.shell().error(
          "#{primary_id} is itself an alias for #{resolved}. Link to #{resolved} instead."
        )

      {:error, reason} ->
        Mix.shell().error("Failed: #{inspect(reason)}")
    end
  end

  defp unlink(secondary_id) do
    resolved = rpc!(Arbor.Agent.IdentityAliases, :resolve, [secondary_id])

    if resolved == secondary_id do
      Mix.shell().info("#{secondary_id} is not an alias — nothing to unlink.")
    else
      rpc!(Arbor.Agent.IdentityAliases, :unlink, [secondary_id])
      Mix.shell().info("Unlinked #{secondary_id} (was → #{resolved})")
    end
  end

  defp list_aliases(primary_id) do
    aliases = rpc!(Arbor.Agent.IdentityAliases, :list_aliases, [primary_id])

    if aliases == [] do
      Mix.shell().info("No linked identities for #{primary_id}")
    else
      Mix.shell().info("Linked identities for #{primary_id}:\n")

      for alias_id <- aliases do
        Mix.shell().info("  #{alias_id} → #{primary_id}")
      end
    end
  end

  defp rpc!(mod, fun, args) do
    Config.rpc!(Config.full_node_name(), mod, fun, args)
  end
end
