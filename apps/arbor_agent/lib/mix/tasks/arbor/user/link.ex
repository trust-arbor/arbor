defmodule Mix.Tasks.Arbor.User.Link do
  @moduledoc """
  Link or unlink OIDC identities via RPC to the running server.

  ## Usage

      mix arbor.user.link <new_login_id> --to <existing_id>  # link new login → existing account
      mix arbor.user.link --unlink <id>                       # remove a link
      mix arbor.user.link --list <id>                         # list linked identities

  ## Options

    * `--as <principal>` — the identity performing the link. Linking redirects
      a principal's future logins, so it is capability-gated on
      `arbor://identity/alias/manage`. Defaults to the local-operator
      principal, which is enough on a single-operator dev box; the capability
      check is the real control, so this default cannot grant anything.

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
    list: :string,
    as: :string
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
        unlink(opts[:unlink], caller_id(opts))

      length(args) == 1 and opts[:to] ->
        [new_login_id] = args
        link(new_login_id, opts[:to], caller_id(opts))

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

  defp link(secondary_id, primary_id, caller_id) do
    # Announce the INTENT only. This previously printed "Linking X → Y / All
    # logins producing X will resolve to Y" before the call, so a failure read
    # as though the link had happened.
    Mix.shell().info("Linking #{secondary_id} → #{primary_id} (as #{caller_id})")

    case rpc!(Arbor.Agent.IdentityAliases, :link, [caller_id, secondary_id, primary_id]) do
      :ok ->
        Mix.shell().info("Linked successfully.")
        Mix.shell().info("  All logins producing #{secondary_id} now resolve to #{primary_id}")

      {:error, {:unauthorized_alias_management, reason}} ->
        Mix.shell().error("""
        #{caller_id} may not manage identity aliases (#{inspect(reason)}).

        Linking redirects a principal's future logins, so it requires
        arbor://identity/alias/manage. Grant it to the caller, or re-run with
        --as <principal> for an identity that holds it.
        """)

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

  defp unlink(secondary_id, caller_id) do
    resolved = rpc!(Arbor.Agent.IdentityAliases, :resolve, [secondary_id])

    if resolved == secondary_id do
      Mix.shell().info("#{secondary_id} is not an alias — nothing to unlink.")
    else
      case rpc!(Arbor.Agent.IdentityAliases, :unlink, [caller_id, secondary_id]) do
        :ok ->
          Mix.shell().info("Unlinked #{secondary_id} (was → #{resolved})")

        {:error, {:unauthorized_alias_management, reason}} ->
          Mix.shell().error(
            "#{caller_id} may not manage identity aliases (#{inspect(reason)}). " <>
              "Re-run with --as <principal> for an identity holding " <>
              "arbor://identity/alias/manage."
          )

        {:error, reason} ->
          Mix.shell().error("Failed: #{inspect(reason)}")
      end
    end
  end

  # The principal performing the link. `IdentityAliases.link/3` authorizes it
  # against `arbor://identity/alias/manage` — without a caller the whole
  # surface is an account-takeover vector (M5), which is why the arity is 3.
  #
  # Defaults to the local-operator principal so a single-operator dev box needs
  # no flag; the capability check remains the real control, so defaulting here
  # cannot grant anything.
  defp caller_id(opts) do
    opts[:as] || Arbor.Contracts.Security.Identity.local_operator_id()
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
