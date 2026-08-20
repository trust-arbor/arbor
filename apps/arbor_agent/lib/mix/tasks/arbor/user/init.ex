defmodule Mix.Tasks.Arbor.User.Init do
  @moduledoc """
  Create the local operator's human identity — **development installs only**.

      mix arbor.user.init

  ## What this is for

  Arbor normally derives a human principal from an authenticated OIDC login
  (`human_<hash>` of `iss:sub`), and `Identity.Registry.register/2` refuses to
  register a `human_` identity any other way. That rule is correct, and this
  task does not change it.

  A single-operator development box has no identity provider, so it cannot
  obtain that proof and cannot complete a first turn. This task mints a
  keypair-backed human identity from local claims instead, as an explicit,
  gated exception.

  **Production expects a working OIDC provider.** Do not use this there. Three
  independent gates enforce that, and only the third lives in this task:

    1. `config :arbor_security, :allow_local_human_identity` must be `true`
       (default `false`, set only in `dev.exs`)
    2. no OIDC provider may be configured — once a real login exists, use it
    3. `Mix.env()` must be `:dev`

  ## What it creates

  A real Ed25519 + X25519 keypair stored encrypted via `SigningKeyStore`,
  exactly like an OIDC-derived human. The id is derived from
  `arbor://local` + `<user>@<host>`, so it is deterministic and idempotent —
  re-running loads the existing identity rather than minting a second one.

  It is your PRIMARY account. Later OIDC logins derive their own id and are
  folded onto this one:

      mix arbor.user.link <new_oidc_id> --to <this_id>
  """

  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: Config

  @shortdoc "Create the local operator's human identity (dev only)"

  @manage_resource "arbor://identity/alias/manage"

  @impl Mix.Task
  def run(_args) do
    Config.ensure_distribution()

    unless Config.server_running?() do
      Mix.shell().error("Arbor server is not running. Start it with: mix arbor.start")
      exit({:shutdown, 1})
    end

    # Gate 3. The other two are enforced inside the facade, which refuses on
    # its own rather than trusting this caller.
    unless Mix.env() == :dev do
      Mix.shell().error("""
      mix arbor.user.init is a development-only task (MIX_ENV=#{Mix.env()}).

      Production derives human principals from an authenticated OIDC login.
      Configure a provider instead of minting a local identity.
      """)

      exit({:shutdown, 1})
    end

    create_identity()
  end

  defp create_identity do
    case rpc(Arbor.Security, :create_local_human_identity, [[]]) do
      {:ok, identity, status} ->
        report(identity, status)
        grant_alias_management(identity.agent_id)
        verify_usable(identity.agent_id)
        next_steps(identity.agent_id)

      {:error, :local_human_identity_disabled} ->
        Mix.shell().error("""
        Local human identities are disabled.

        This is the default. It is enabled only in dev.exs via
        `config :arbor_security, allow_local_human_identity: true`.
        """)

      {:error, :oidc_configured} ->
        Mix.shell().error("""
        An OIDC provider is configured, so a real login is available.

        Sign in through it rather than minting a local identity. If you want
        an existing local account to keep its grants, link the OIDC id to it:

            mix arbor.user.link <oidc_id> --to <existing_id>
        """)

      {:error, reason} ->
        Mix.shell().error("Failed to create local identity: #{inspect(reason)}")
    end
  end

  defp report(identity, :created) do
    Mix.shell().info("Created local operator identity: #{identity.agent_id}")
    Mix.shell().info("  Ed25519 + X25519 keypair stored encrypted (SigningKeyStore)")
  end

  defp report(identity, :existing) do
    Mix.shell().info("Local operator identity already exists: #{identity.agent_id}")
  end

  # Without this the operator cannot run `mix arbor.user.link`, which is the
  # whole point of having a primary account. It is deliberately narrow: ONE
  # resource, granted to the identity this task just created, on a dev-only
  # path that has already passed all three gates.
  defp grant_alias_management(agent_id) do
    # `grant_capability_id/1`, not `grant/1`: the facade asks cross-library
    # consumers to use it so Capability structs stay private to arbor_security.
    case rpc(Arbor.Security, :grant_capability_id, [
           [principal: agent_id, resource: @manage_resource]
         ]) do
      {:ok, _capability_id} ->
        Mix.shell().info("  Granted #{@manage_resource} (needed by mix arbor.user.link)")

      {:error, reason} ->
        Mix.shell().error("""
          Could not grant #{@manage_resource}: #{inspect(reason)}
          mix arbor.user.link will not work until this is granted.
        """)
    end
  end

  # Do not claim success we have not verified. The keypair and the grant are
  # only half the story: `AuthDecision` also requires the principal to be
  # REGISTERED in `Identity.Registry`, and `register/2` refuses `human_` ids
  # with `:oidc_proof_required`. Until a local registration path exists, this
  # identity can hold a capability it cannot yet exercise — say so plainly
  # rather than letting the operator discover it at the next command.
  defp verify_usable(agent_id) do
    case rpc(Arbor.Security, :authorize, [agent_id, @manage_resource, :write]) do
      {:ok, :authorized} ->
        Mix.shell().info("  Verified: #{agent_id} can manage identity aliases")

      {:error, {:unauthorized, :unknown_identity}} ->
        Mix.shell().error("""

          NOT YET USABLE: #{agent_id} is not registered in Identity.Registry,
          so authorization fails with :unknown_identity and mix arbor.user.link
          will still refuse.

          Identity.Registry.register/2 rejects human_ ids with
          :oidc_proof_required, and the local registration path does not exist
          yet. The keypair and grant above are real and will work once it does.
        """)

      other ->
        Mix.shell().error("  Could not verify authorization: #{inspect(other)}")
    end
  end

  defp next_steps(agent_id) do
    Mix.shell().info("")
    Mix.shell().info("This is your primary account. When you later add an OIDC login:")
    Mix.shell().info("    mix arbor.user.link <new_oidc_id> --to #{agent_id}")
  end

  defp rpc(mod, fun, args) do
    Config.rpc!(Config.full_node_name(), mod, fun, args)
  end
end
