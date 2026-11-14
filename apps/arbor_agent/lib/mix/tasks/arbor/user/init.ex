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
  obtain that proof and cannot complete a first turn. This task registers a
  keypair-backed human identity from local claims instead, as an explicit,
  gated exception.

  **Production expects a working OIDC provider.** Do not use this there. Three
  independent gates enforce that, and only the third lives in this task:

    1. `config :arbor_capabilities, :allow_local_human_identity` must be `true`
       (default `false`, set only in `dev.exs`)
    2. no OIDC provider may be configured — once a real login exists, use it
    3. `Mix.env()` must be `:dev`

  ## What it creates

  An Ed25519 keypair **generated in this Mix process**. The private key is
  written to a local `.arbor.key` file the CLI holds, so later commands can
  prove possession. Only the public key reaches the server, with a signed
  proof that this process holds the private key
  (`Arbor.Security.register_local_human_identity/3`). The server never holds
  the operator's private key and never returns one (security review F-002).

  The id is derived on the server from `arbor://local` + `<user>@<host>`, so it
  is deterministic. Re-running with the same key file is idempotent: the
  server reports the identity as existing and nothing new is minted. If the
  identity already exists and the key file is missing, the task stops with
  instructions instead of generating a second key. A key file whose public key
  differs from the registered one is refused.

  Because the server holds no private key for this identity, server-side
  flows that sign with a human's server-held key (the gateway's signed HTTP
  agent create/start routes) are not available to it. CLI commands sign with
  the key file instead.

  The key file is plaintext with mode `0600` (the same convention as
  `~/.arbor/identity.key`). There is no passphrase wrapping in this
  command. It will not overwrite an existing file — remove it explicitly
  if you intend to replace it.

  Default path: `~/.arbor/operator.key`. Override with `--key-file PATH`.

  ## First-run genesis

  Every capability and identity mutation requires an actor that already holds
  a matching capability, so a fresh install cannot grant anything until it has
  a first administrator. After registering, this task signs a genesis request
  with the key file and submits only that proof to
  `Arbor.Security.complete_local_genesis/1`. The server re-checks the same
  gates, verifies the signature against the registered identity, and — only
  while no administrator exists yet — grants this identity `arbor://**`. That
  covers `arbor://identity/alias/manage`, so no separate grant is needed.

  The outcome is reported as one of:

    * **granted** — this identity is the install's first administrator;
    * **closed** — an administrator already exists (on a re-run, usually this
      identity from the first run). Nothing is granted; alias management then
      needs a grant from that administrator;
    * **failure** — the task exits non-zero; re-run it to retry.

  It is your PRIMARY account. Later OIDC logins derive their own id and are
  folded onto this one:

      mix arbor.user.link <new_oidc_id> --to <this_id> --as <this_id>
  """

  use Mix.Task

  alias Arbor.Agent.IdentityAliasProof
  alias Mix.Tasks.Arbor.Helpers, as: Config

  @shortdoc "Create the local operator's human identity (dev only)"

  @manage_resource "arbor://identity/alias/manage"
  @genesis_resource "arbor://**"

  @switches [key_file: :string]

  @typedoc "Performs one call on the Arbor server and returns its result."
  @type remote :: (module(), atom(), list() -> term())

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

    # Every failure branch used to exit 0 in places — `:store_unavailable`
    # while the server was mid-restart looked like success to a script.
    case init_operator(opts, &rpc/3) do
      :ok -> :ok
      :error -> exit({:shutdown, 1})
    end
  end

  @doc false
  # Everything after the process gates in `run/1`. `remote` performs one call
  # on the server: `rpc/3` in production, a peer-node call in tests. Only
  # public material is passed to it: the public key and signed proofs. Reports
  # as it goes; returns `:error` after reporting a failure.
  @spec init_operator(keyword(), remote()) :: :ok | :error
  def init_operator(opts, remote) when is_list(opts) and is_function(remote, 3) do
    key_path = IdentityAliasProof.key_file_path(opts)

    with {:ok, principal_id, registered_key} <- fetch_status(remote),
         :ok <- ensure_key_file(key_path, principal_id, registered_key),
         {:ok, identity, status} <- register(remote, key_path, principal_id, registered_key) do
      report(identity, status, key_path)
      genesis = complete_genesis(remote, identity.agent_id, key_path)
      if genesis != :granted, do: report_alias_grant_needs_admin(identity.agent_id)
      verify_usable(remote, identity.agent_id, key_path)
      next_steps(identity.agent_id, key_path)

      if genesis == :failed do
        Mix.shell().error("Genesis did not complete. Re-run mix arbor.user.init to retry.")
        :error
      else
        :ok
      end
    end
  end

  # -- 1. Where the operator stands ------------------------------------------

  defp fetch_status(remote) do
    case remote.(Arbor.Security, :local_human_identity_status, [[]]) do
      {:ok, %{principal_id: principal_id, public_key: public_key}}
      when is_binary(principal_id) and (is_nil(public_key) or is_binary(public_key)) ->
        {:ok, principal_id, public_key}

      {:error, reason} when reason in [:local_human_identity_disabled, :oidc_configured] ->
        report_refused(reason)

      other ->
        Mix.shell().error("Failed to read the local operator identity: #{inspect(other)}")
        :error
    end
  end

  # -- 2. The key file -------------------------------------------------------

  # An existing file is validated when it is read in step 3. A missing file is
  # generated only for an identity that is not registered yet: a registered
  # identity already has a key, and a second one would never match it.
  defp ensure_key_file(key_path, principal_id, registered_key) do
    case File.lstat(key_path) do
      {:ok, _stat} ->
        :ok

      {:error, :enoent} when is_binary(registered_key) ->
        report_missing_key_file(principal_id, key_path)

      {:error, :enoent} ->
        generate_key_file(key_path, principal_id)

      {:error, reason} ->
        Mix.shell().error("Cannot inspect operator key file #{key_path}: #{inspect(reason)}")
        :error
    end
  end

  # The keypair is generated here, in the CLI process, and the private key
  # goes only to the key file. The server receives the public key.
  defp generate_key_file(key_path, principal_id) do
    {_public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

    case Arbor.Security.write_key_file(key_path, %{
           agent_id: principal_id,
           private_key: private_key
         }) do
      {:ok, written} ->
        Mix.shell().info("Generated an Ed25519 keypair locally for #{principal_id}")
        Mix.shell().info("  Wrote operator key file: #{written} (mode 0600)")
        Mix.shell().info("  Plaintext Ed25519 key material; passphrase wrapping is not applied.")
        :ok

      {:error, :already_exists} ->
        # Created between the check and the write. It is validated when read.
        Mix.shell().info("  Key file already exists at #{key_path} (not overwritten)")
        :ok

      {:error, reason} ->
        Mix.shell().error("""
        Failed to write operator key file #{key_path}: #{format_key_file_error(reason)}

        Nothing was registered. Fix the path or its permissions and re-run.
        """)

        :error
    end
  end

  # -- 3. Registration -------------------------------------------------------

  # The proof is built HERE, from the key file; the server never opens a
  # caller-nominated path and never sees the private key.
  defp register(remote, key_path, principal_id, registered_key) do
    case prepare_registration(key_path) do
      {:ok, ^principal_id, public_key, _proof}
      when is_binary(registered_key) and registered_key != public_key ->
        report_key_mismatch(principal_id, key_path)

      {:ok, ^principal_id, public_key, proof} ->
        submit_registration(remote, key_path, principal_id, public_key, proof)

      {:ok, other_id, _public_key, _proof} ->
        report_principal_mismatch(principal_id, other_id, key_path)

      {:error, reason} ->
        Mix.shell().error(
          "Cannot use operator key file #{key_path}: #{format_key_file_error(reason)}"
        )

        :error
    end
  end

  defp prepare_registration(key_path) do
    with_key_file(key_path, &Arbor.Security.prepare_key_file_local_human_registration/1)
  end

  defp submit_registration(remote, key_path, principal_id, public_key, proof) do
    case remote.(Arbor.Security, :register_local_human_identity, [public_key, proof, []]) do
      {:ok, %{agent_id: ^principal_id} = identity, status} when status in [:created, :existing] ->
        {:ok, identity, status}

      {:error, :local_human_key_mismatch} ->
        report_key_mismatch(principal_id, key_path)

      {:error, reason} when reason in [:local_human_identity_disabled, :oidc_configured] ->
        report_refused(reason)

      {:error, :local_human_registration_unauthorized} ->
        Mix.shell().error("""
        The server refused the registration proof signed with #{key_path}.

        The proof is single-use and time-limited. Check that this machine's
        clock agrees with the server's, then re-run.
        """)

        :error

      other ->
        Mix.shell().error("Failed to register local identity: #{inspect(other)}")
        :error
    end
  end

  defp report(identity, :created, key_path) do
    Mix.shell().info("Registered local operator identity: #{identity.agent_id}")

    Mix.shell().info(
      "  The server holds only its public key; the private key stays in #{key_path}"
    )
  end

  defp report(identity, :existing, key_path) do
    Mix.shell().info("Local operator identity already exists: #{identity.agent_id}")
    Mix.shell().info("  Key file #{key_path} matches the registered public key")
  end

  defp report_refused(:local_human_identity_disabled) do
    Mix.shell().error("""
    Local human identities are disabled.

    This is the default. It is enabled only in dev.exs via
    `config :arbor_capabilities, allow_local_human_identity: true`.
    """)

    :error
  end

  defp report_refused(:oidc_configured) do
    Mix.shell().error("""
    An OIDC provider is configured, so a real login is available.

    Sign in through it rather than minting a local identity. If you want
    an existing local account to keep its grants, link the OIDC id to it:

        mix arbor.user.link <oidc_id> --to <existing_id>
    """)

    :error
  end

  defp report_missing_key_file(principal_id, key_path) do
    Mix.shell().error("""
    Local operator identity #{principal_id} already exists, but its key file
    is missing: #{key_path}

    Without its key file this identity cannot sign, and this task will not
    generate a second key for an existing identity. Restore the file, or pass
    --key-file PATH if it is stored somewhere else.

    If no key file was ever written for this identity, the key cannot be
    recovered. Arbor builds from 2026-10-07 to 2026-11-13 kept it inside the
    server and could not export it. On a development install whose security
    state you can discard, stop Arbor, move the security store aside as
    docs/QUICKSTART.md section 4 describes, start Arbor and re-run this task.
    """)

    :error
  end

  defp report_key_mismatch(principal_id, key_path) do
    Mix.shell().error("""
    The key file #{key_path} does not match the registered identity #{principal_id}.

    The server has a different public key registered for this identity.
    Nothing was changed: this task never re-keys an identity. Use the key
    file that belongs to #{principal_id} (--key-file PATH).
    """)

    :error
  end

  defp report_principal_mismatch(principal_id, other_id, key_path) do
    Mix.shell().error("""
    The key file #{key_path} belongs to #{other_id},
    but this user and host derive #{principal_id}.

    Nothing was sent. To create a key for #{principal_id}, keep this file and
    pass a new path with --key-file PATH. Then fold one id onto the other with
    mix arbor.user.link so grants and agents carry over.
    """)

    :error
  end

  # -- 4. First-run genesis --------------------------------------------------

  # The proof is built HERE, from the key file this task just wrote or found;
  # only the signed request crosses to the server. A key file that belongs to
  # another principal is refused before anything is submitted.
  defp complete_genesis(remote, agent_id, key_path) do
    case prepare_genesis_proof(key_path) do
      {:ok, ^agent_id, proof} ->
        submit_genesis(remote, agent_id, proof)

      {:ok, other_id, _proof} ->
        Mix.shell().error(
          "  Genesis not attempted: #{format_key_file_error({:principal_mismatch, agent_id, other_id})}"
        )

        :failed

      {:error, reason} ->
        Mix.shell().error(
          "  Genesis not attempted: could not sign from #{key_path}: #{format_key_file_error(reason)}"
        )

        :failed
    end
  end

  defp prepare_genesis_proof(key_path) do
    with_key_file(key_path, &Arbor.Security.prepare_key_file_local_genesis/1)
  end

  defp submit_genesis(remote, agent_id, proof) do
    case remote.(Arbor.Security, :complete_local_genesis, [proof]) do
      {:ok, capability_id} ->
        Mix.shell().info(
          "  Genesis: granted #{@genesis_resource} to #{agent_id} (#{capability_id})"
        )

        Mix.shell().info("  This identity is the install's first administrator.")
        :granted

      {:error, :genesis_closed} ->
        Mix.shell().info("""
          Genesis already closed: an administrator already exists, so nothing was granted.
          (On a re-run this is usually this identity, from the first run.)
        """)

        :closed

      {:error, reason} ->
        Mix.shell().error("  Genesis failed: #{inspect(reason)}")
        :failed
    end
  end

  # Granting needs an actor that already holds `arbor://security/grant/...`,
  # which this task does not have once genesis is closed. Say so instead of
  # calling a grant that cannot succeed.
  defp report_alias_grant_needs_admin(agent_id) do
    Mix.shell().info("""
      #{@manage_resource} was not granted by this task: granting requires an
      administrator. Unless #{agent_id} already is one, mix arbor.user.link
      will not work until an administrator grants it.
    """)
  end

  # Do not claim success we have not verified. Alias management requires both
  # a registered principal that holds the capability and a mutation-bound
  # SignedRequest produced from the key file this task just wrote. The
  # synthetic self-link is never applied; IdentityAliases would reject it.
  # It only proves the key can sign the canonical payload and the principal
  # can pass authorize with that exact reconstructed payload.
  defp verify_usable(remote, agent_id, key_path) do
    mutation = {:link, agent_id, agent_id}

    case IdentityAliasProof.prove(key_path, agent_id, mutation) do
      {:ok, signed_request} ->
        {:ok, expected_payload} = IdentityAliasProof.canonical_payload(mutation)

        case remote.(Arbor.Security, :authorize, [
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

  # -- Helpers ---------------------------------------------------------------

  defp with_key_file(key_path, callback) do
    case :file.open(String.to_charlist(key_path), [:read, :raw, :binary]) do
      {:ok, io_device} ->
        try do
          callback.(io_device)
        after
          :file.close(io_device)
        end

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  defp format_key_file_error(:already_exists), do: "file already exists"
  defp format_key_file_error({:read_failed, reason}), do: "read failed (#{inspect(reason)})"
  defp format_key_file_error({:write_failed, reason}), do: "write failed (#{inspect(reason)})"

  defp format_key_file_error({:mkdir_failed, reason}),
    do: "could not create directory (#{inspect(reason)})"

  defp format_key_file_error({:insecure_permissions, mode}),
    do: "insecure permissions #{Integer.to_string(mode, 8)}"

  defp format_key_file_error({:not_a_regular_file, type}), do: "not a regular file (#{type})"
  defp format_key_file_error(:invalid_key_file_size), do: "unexpected file size"
  defp format_key_file_error(:key_file_changed), do: "file changed while it was read"
  defp format_key_file_error({:invalid_agent_id, id}), do: "invalid principal id #{inspect(id)}"
  defp format_key_file_error({:missing_field, field}), do: "missing field #{field}"
  defp format_key_file_error({:empty_field, field}), do: "empty field #{field}"

  defp format_key_file_error(:invalid_private_key_base64),
    do: "private_key_b64 is not valid base64"

  defp format_key_file_error({:invalid_private_key_size, size}),
    do: "private key is #{size} bytes; expected 32 or 64"

  defp format_key_file_error(:invalid_key_file_signing_material),
    do: "private key is not valid Ed25519 signing material"

  defp format_key_file_error(:local_human_registration_unauthorized),
    do: "the key file is not for a local human (human_) principal"

  defp format_key_file_error({:principal_mismatch, claimed, actual}),
    do: "key file is for #{actual}, not claimed #{claimed}"

  defp format_key_file_error(other), do: inspect(other)

  defp rpc(mod, fun, args) do
    Config.rpc!(Config.full_node_name(), mod, fun, args)
  end
end
