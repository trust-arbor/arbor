defmodule Mix.Tasks.Arbor.User.Link do
  @moduledoc """
  Link or unlink OIDC identities via RPC to the running server.

  ## Usage

      mix arbor.user.link <new_login_id> --to <existing_id> --as <existing_id>
      mix arbor.user.link --unlink <id> --as <existing_id>
      mix arbor.user.link --list <id>

  ## Options

    * `--as <principal>` — claim of *which* key file to use. Defaults to
      the local-operator principal. The claim is not authority: the CLI
      signs the exact mutation (link + secondary + primary, or unlink +
      secondary) with the matching key file, and the server reconstructs
      that payload from the arguments it will act on, then verifies the
      proof **and** that the principal holds
      `arbor://identity/alias/manage`. A proof for one link cannot
      authorize a different link or an unlink.
    * `--key-file <path>` — operator key file (default `~/.arbor/operator.key`,
      written by `mix arbor.user.init`). Must belong to the `--as` principal.

  ## Examples

      # You have an existing account (human_def456) with agents and data.
      # You created a new OIDC login that generates human_abc123.
      # Link the new login to your existing account:
      mix arbor.user.link human_abc123 --to human_def456 --as human_def456

      # See what's linked to an identity
      mix arbor.user.link --list human_def456

      # Remove a link
      mix arbor.user.link --unlink human_abc123 --as human_def456
  """

  use Mix.Task

  alias Arbor.Agent.IdentityAliasProof
  alias Mix.Tasks.Arbor.Helpers, as: Config

  @shortdoc "Link OIDC identities to a primary Arbor identity"

  @switches [
    to: :string,
    unlink: :string,
    list: :string,
    as: :string,
    key_file: :string
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
        unlink(opts[:unlink], caller_id(opts), opts)

      length(args) == 1 and opts[:to] ->
        [new_login_id] = args
        link(new_login_id, opts[:to], caller_id(opts), opts)

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

  defp link(secondary_id, primary_id, caller_id, opts) do
    # Announce the INTENT only. This previously printed "Linking X → Y / All
    # logins producing X will resolve to Y" before the call, so a failure read
    # as though the link had happened.
    Mix.shell().info("Linking #{secondary_id} → #{primary_id} (as #{caller_id})")

    with {:ok, signed_request} <-
           prove_caller(caller_id, {:link, secondary_id, primary_id}, opts) do
      case rpc!(Arbor.Agent.IdentityAliases, :link, [
             caller_id,
             secondary_id,
             primary_id,
             [signed_request: signed_request]
           ]) do
        :ok ->
          Mix.shell().info("Linked successfully.")
          Mix.shell().info("  All logins producing #{secondary_id} now resolve to #{primary_id}")

        {:error, {:unauthorized_alias_management, reason}} ->
          Mix.shell().error(unauthorized_message(caller_id, reason))

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
  end

  defp unlink(secondary_id, caller_id, opts) do
    resolved = rpc!(Arbor.Agent.IdentityAliases, :resolve, [secondary_id])

    if resolved == secondary_id do
      Mix.shell().info("#{secondary_id} is not an alias — nothing to unlink.")
    else
      with {:ok, signed_request} <- prove_caller(caller_id, {:unlink, secondary_id}, opts) do
        case rpc!(Arbor.Agent.IdentityAliases, :unlink, [
               caller_id,
               secondary_id,
               [signed_request: signed_request]
             ]) do
          :ok ->
            Mix.shell().info("Unlinked #{secondary_id} (was → #{resolved})")

          {:error, {:unauthorized_alias_management, reason}} ->
            Mix.shell().error(unauthorized_message(caller_id, reason))

          {:error, reason} ->
            Mix.shell().error("Failed: #{inspect(reason)}")
        end
      end
    end
  end

  # `--as` (or the local-operator default) is a claim of which key file to
  # use. Possession of that file's private key is the proof; the claim
  # itself never grants alias-management authority.
  defp caller_id(opts) do
    opts[:as] || Arbor.Contracts.Security.Identity.local_operator_id()
  end

  defp prove_caller(caller_id, mutation, opts) do
    key_path = IdentityAliasProof.key_file_path(opts)

    case IdentityAliasProof.prove(key_path, caller_id, mutation) do
      {:ok, signed_request} ->
        {:ok, signed_request}

      {:error, reason} ->
        Mix.shell().error(proof_error_message(caller_id, key_path, reason))
        {:error, reason}
    end
  end

  defp unauthorized_message(caller_id, reason) do
    cond do
      payload_mismatch?(reason) ->
        """
        Possession proof for #{caller_id} does not match this alias mutation (#{inspect(reason)}).

        The CLI signs the exact operation and identity arguments; a proof
        produced for a different link or unlink cannot be reused.
        """

      proof_failure?(reason) ->
        """
        Possession proof for #{caller_id} was rejected (#{inspect(reason)}).

        The CLI signs alias-management requests from a key file it holds; the
        server only verifies. A named principal is not proof.
        """

      true ->
        """
        #{caller_id} may not manage identity aliases (#{inspect(reason)}).

        Linking redirects a principal's future logins, so it requires
        arbor://identity/alias/manage. Grant it to the caller, or re-run with
        --as <principal> for an identity that holds it.
        """
    end
  end

  defp payload_mismatch?(:payload_mismatch), do: true
  defp payload_mismatch?({:payload_mismatch, _given, _expected}), do: true
  defp payload_mismatch?({:resource_mismatch, _payload, _expected}), do: true
  defp payload_mismatch?(_reason), do: false

  defp proof_failure?(reason)
       when reason in [
              :missing_signed_request,
              :invalid_signature,
              :unknown_agent,
              :expired_timestamp,
              :malformed_request,
              :cluster_replay_protection_unavailable,
              :invalid_private_key
            ],
       do: true

  defp proof_failure?({:identity_mismatch, _verified, _claimed}), do: true
  defp proof_failure?(_reason), do: false

  defp proof_error_message(caller_id, key_path, {:read_failed, :enoent}) do
    """
    Cannot prove possession of #{caller_id}: key file not found at #{key_path}.

    Create one with `mix arbor.user.init`, or pass --key-file <path>.
    """
  end

  defp proof_error_message(caller_id, key_path, {:read_failed, reason}) do
    """
    Cannot prove possession of #{caller_id}: key file #{key_path} is unreadable (#{inspect(reason)}).
    """
  end

  defp proof_error_message(caller_id, key_path, {:insecure_permissions, mode}) do
    """
    Cannot prove possession of #{caller_id}: key file #{key_path} has insecure permissions #{Integer.to_string(mode, 8)} (expected 0600).
    """
  end

  defp proof_error_message(caller_id, key_path, {:principal_mismatch, claimed, actual}) do
    """
    Cannot prove possession of #{caller_id}: key file #{key_path} belongs to #{actual}, not claimed #{claimed}.

    --as names which key file to use; it does not grant that principal's authority.
    """
  end

  defp proof_error_message(caller_id, key_path, {:missing_field, field}) do
    "Cannot prove possession of #{caller_id}: key file #{key_path} is missing #{field}."
  end

  defp proof_error_message(caller_id, key_path, {:empty_field, field}) do
    "Cannot prove possession of #{caller_id}: key file #{key_path} has an empty #{field}."
  end

  defp proof_error_message(caller_id, key_path, :invalid_private_key_base64) do
    "Cannot prove possession of #{caller_id}: key file #{key_path} has invalid private_key_b64."
  end

  defp proof_error_message(caller_id, key_path, {:invalid_private_key_size, size}) do
    "Cannot prove possession of #{caller_id}: key file #{key_path} private key is #{size} bytes; expected 32 or 64."
  end

  defp proof_error_message(caller_id, key_path, {:invalid_agent_id, id}) do
    "Cannot prove possession of #{caller_id}: key file #{key_path} has invalid principal id #{inspect(id)}."
  end

  defp proof_error_message(caller_id, key_path, reason) do
    "Cannot prove possession of #{caller_id} from #{key_path}: #{inspect(reason)}."
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
