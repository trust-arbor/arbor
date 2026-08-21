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
  exactly like an OIDC-derived human, **and** a local `.arbor.key` file the
  CLI holds so later commands can prove possession. The id is derived from
  `arbor://local` + `<user>@<host>`, so it is deterministic and idempotent —
  re-running loads the existing identity rather than minting a second one.

  The key file is plaintext with mode `0600` (the same convention as
  `~/.arbor/identity.key`). There is no passphrase wrapping in this
  command. It will not overwrite an existing file — remove it explicitly
  if you intend to replace it.

  Default path: `~/.arbor/operator.key`. Override with `--key-file PATH`.

  It is your PRIMARY account. Later OIDC logins derive their own id and are
  folded onto this one:

      mix arbor.user.link <new_oidc_id> --to <this_id> --as <this_id>
  """

  use Mix.Task

  alias Arbor.Agent.IdentityAliasProof
  alias Mix.Tasks.Arbor.Helpers, as: Config

  @shortdoc "Create the local operator's human identity (dev only)"

  @manage_resource "arbor://identity/alias/manage"

  @switches [key_file: :string]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _invalid} = OptionParser.parse(args, strict: @switches)

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

    create_identity(opts)
  end

  defp create_identity(opts) do
    case rpc(Arbor.Security, :create_local_human_identity, [[]]) do
      {:ok, identity, status} ->
        report(identity, status)
        key_path = IdentityAliasProof.key_file_path(opts)

        case export_key_file(identity, key_path) do
          :ok ->
            grant_alias_management(identity.agent_id)
            verify_usable(identity.agent_id, key_path)
            next_steps(identity.agent_id, key_path)

          {:error, reason} ->
            Mix.shell().error("""
            Failed to write operator key file #{key_path}: #{format_key_file_error(reason)}

            mix arbor.user.link cannot prove possession until a key file is written.
            """)
        end

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

  defp export_key_file(%{agent_id: agent_id, private_key: private_key}, path)
       when is_binary(agent_id) and is_binary(private_key) do
    case Arbor.Security.write_key_file(path, %{agent_id: agent_id, private_key: private_key}) do
      {:ok, written} ->
        Mix.shell().info("  Wrote operator key file: #{written} (mode 0600)")
        Mix.shell().info("  Plaintext Ed25519 key material; passphrase wrapping is not applied.")
        :ok

      {:error, :already_exists} ->
        Mix.shell().info("  Key file already exists at #{path} (not overwritten)")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp export_key_file(_identity, _path), do: {:error, :missing_private_key}

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

  # Do not claim success we have not verified. Alias management requires both
  # a registered principal that holds the capability and a mutation-bound
  # SignedRequest produced from the key file this task just wrote. The
  # synthetic self-link is never applied; IdentityAliases would reject it.
  # It only proves the key can sign the canonical payload and the principal
  # can pass authorize with that exact reconstructed payload.
  defp verify_usable(agent_id, key_path) do
    mutation = {:link, agent_id, agent_id}

    case IdentityAliasProof.prove(key_path, agent_id, mutation) do
      {:ok, signed_request} ->
        {:ok, expected_payload} = IdentityAliasProof.canonical_payload(mutation)

        case rpc(Arbor.Security, :authorize, [
               agent_id,
               @manage_resource,
               :write,
               [
                 signed_request: signed_request,
                 expected_resource: expected_payload,
                 verify_identity: true
               ]
             ]) do
          {:ok, :authorized} ->
            Mix.shell().info("  Verified: #{agent_id} can manage identity aliases")

          {:error, {:unauthorized, :unknown_identity}} ->
            Mix.shell().error("""

              NOT REGISTERED: #{agent_id} is not in Identity.Registry, so
              authorization fails closed with :unknown_identity.
            """)

          other ->
            Mix.shell().error("  Could not verify authorization: #{inspect(other)}")
        end

      {:error, reason} ->
        Mix.shell().error(
          "  Could not prove possession from #{key_path}: #{format_key_file_error(reason)}"
        )
    end
  end

  defp next_steps(agent_id, key_path) do
    Mix.shell().info("")
    Mix.shell().info("This is your primary account. When you later add an OIDC login:")

    Mix.shell().info(
      "    mix arbor.user.link <new_oidc_id> --to #{agent_id} --as #{agent_id} --key-file #{key_path}"
    )
  end

  defp format_key_file_error(:already_exists), do: "file already exists"
  defp format_key_file_error(:missing_private_key), do: "identity did not include a private key"
  defp format_key_file_error({:read_failed, reason}), do: "read failed (#{inspect(reason)})"
  defp format_key_file_error({:write_failed, reason}), do: "write failed (#{inspect(reason)})"

  defp format_key_file_error({:mkdir_failed, reason}),
    do: "could not create directory (#{inspect(reason)})"

  defp format_key_file_error({:insecure_permissions, mode}),
    do: "insecure permissions #{Integer.to_string(mode, 8)}"

  defp format_key_file_error({:invalid_agent_id, id}), do: "invalid principal id #{inspect(id)}"
  defp format_key_file_error({:missing_field, field}), do: "missing field #{field}"
  defp format_key_file_error({:empty_field, field}), do: "empty field #{field}"

  defp format_key_file_error(:invalid_private_key_base64),
    do: "private_key_b64 is not valid base64"

  defp format_key_file_error({:invalid_private_key_size, size}),
    do: "private key is #{size} bytes; expected 32 or 64"

  defp format_key_file_error({:principal_mismatch, claimed, actual}),
    do: "key file is for #{actual}, not claimed #{claimed}"

  defp format_key_file_error(other), do: inspect(other)

  defp rpc(mod, fun, args) do
    Config.rpc!(Config.full_node_name(), mod, fun, args)
  end
end
