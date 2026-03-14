defmodule Mix.Tasks.Arbor.User.Link do
  @moduledoc """
  Link or unlink OIDC identities via RPC to the running server.

  ## Usage

      mix arbor.user.link <new_login_id> --to <existing_id>  # link new login → existing account
      mix arbor.user.link --unlink <id>                       # remove a link
      mix arbor.user.link --list <id>                         # list linked identities

  ## Examples

      # You have an existing account (human_def456) with agents and data.
      # You created a new OIDC login that generates human_abc123.
      # Link the new login to your existing account:
      mix arbor.user.link human_abc123 --to human_def456

      # See what's linked to an identity
      mix arbor.user.link --list human_def456

      # Remove a link
      mix arbor.user.link --unlink human_abc123
  """

  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: Config

  @shortdoc "Link OIDC identities to a primary Arbor identity"

  @switches [
    to: :string,
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

      length(args) == 1 and opts[:to] ->
        [new_login_id] = args
        link(new_login_id, opts[:to])

      true ->
        Mix.shell().error("""
        Usage:
          mix arbor.user.link <new_login_id> --to <existing_id>
          mix arbor.user.link --unlink <id>
          mix arbor.user.link --list <id>

        The <new_login_id> is the ID from your new OIDC login.
        The <existing_id> is your current account (with agents, data, etc).
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
