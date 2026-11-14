defmodule Mix.Tasks.Arbor.Agent.GrantDisclosure do
  @shortdoc "Let agents you created before 2026-11-14 chat with you on external routes"
  @moduledoc """
  Grant your existing agents the narrow right their Session needs to mint the
  one-turn disclosure capability for your own chat turns.

      mix arbor.agent.grant_disclosure <name|id>
      mix arbor.agent.grant_disclosure --all-owned
      mix arbor.agent.grant_disclosure <name|id> --key-file ~/.arbor/operator.key

  Agents created since 2026-11-14 get this right at creation. An agent created
  earlier lacks it, and every authenticated chat turn to an external provider
  is refused before the model is called: the CLI shows
  `Chat failed: :delivery_failed`, and the server log shows
  `[Session] turn refused for <agent> at route_and_disclosure:
  :capability_mutation_unauthorized`. Run this once per agent (or once with
  `--all-owned`). It takes effect on the next turn; no restart is needed.

  The right granted is `arbor://security/disclose/<agent_id>/<you>`. It lets
  the agent's Session mint a disclosure capability only for turns you
  authenticated, and nothing else. It is never the general
  `arbor://security/grant/<agent_id>`, which would let the agent grant itself
  anything.

  ## How the grant proves who you are

  The grant is signed in this process with your key file. The human it names
  is always the key file's own principal: there is no option to name another
  human. Only the capability and its signature go to the server, which admits
  it only if you created the agent and you may grant it capabilities. Your
  private key never leaves the key file. Running it again on an agent that
  already holds the right changes nothing.

  ## Options

    * `--all-owned` — every agent whose profile names you as its creator.
      Agents that record no creator (for example, created before 2026-03) are
      skipped and listed; recreate them with `mix arbor.agent start`.
    * `--key-file` — operator key (default `~/.arbor/operator.key`, created by
      `mix arbor.user.init`).
  """

  use Mix.Task

  # Same reason as `mix arbor.agent`: runtime config (including `.env`) is only
  # applied by `app.config`.
  @requirements ["app.config"]

  alias Arbor.Agent.IdentityAliasProof
  alias Arbor.Agent.OwnerDisclosureRight
  alias Mix.Tasks.Arbor.Helpers, as: Config

  @switches [key_file: :string, all_owned: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    target =
      case {positional, Keyword.get(opts, :all_owned, false), invalid} do
        {[ref], false, []} -> {:agent, ref}
        {[], true, []} -> :all_owned
        _ -> usage!()
      end

    Config.ensure_distribution()

    unless Config.server_running?() do
      Mix.shell().error("Arbor server is not running. Start with: mix arbor.start")
      exit({:shutdown, 1})
    end

    case grant_operator(target, opts, &remote/3) do
      :ok -> :ok
      :error -> exit({:shutdown, 1})
    end
  end

  @doc false
  # Everything after the server check, with the RPC seam injected so tests can
  # run each server call in its own process, as `:rpc` does.
  @spec grant_operator({:agent, String.t()} | :all_owned, keyword(), function()) :: :ok | :error
  def grant_operator(target, opts, remote) when is_function(remote, 3) do
    key_path = IdentityAliasProof.key_file_path(opts)

    with {:ok, principal} <- operator_principal(key_path),
         {:ok, profiles} <- targets(target, principal, remote) do
      profiles
      |> Enum.map(&grant_one(&1, principal, key_path, remote))
      |> Enum.all?(&(&1 == :ok))
      |> if(do: :ok, else: :error)
    end
  end

  defp usage! do
    Mix.raise("usage: mix arbor.agent.grant_disclosure <name|id> | --all-owned [--key-file PATH]")
  end

  defp operator_principal(key_path) do
    case Arbor.Security.key_file_principal(key_path) do
      {:ok, principal} ->
        {:ok, principal}

      {:error, _reason} ->
        Mix.shell().error(
          "Granting this requires your operator key (#{key_path}). " <>
            "Run mix arbor.user.init or supply --key-file <path>."
        )

        :error
    end
  end

  defp targets({:agent, ref}, principal, remote) do
    case Enum.find(remote.(Arbor.Agent, :list_agents, []), &named?(&1, ref)) do
      nil ->
        Mix.shell().error(
          "Agent '#{ref}' not found. Use `mix arbor.agent list --all` to see all agents."
        )

        :error

      profile ->
        case OwnerDisclosureRight.creator(profile) do
          ^principal ->
            {:ok, [profile]}

          creator ->
            Mix.shell().error(not_owner(profile, principal, creator))
            :error
        end
    end
  end

  defp targets(:all_owned, principal, remote) do
    profiles = remote.(Arbor.Agent, :list_agents, [])
    owned = Enum.filter(profiles, &(OwnerDisclosureRight.creator(&1) == principal))
    unowned = Enum.filter(profiles, &is_nil(OwnerDisclosureRight.creator(&1)))

    for profile <- unowned do
      Mix.shell().info("Skipped #{label(profile)}: its profile records no creator.")
    end

    if owned == [] do
      Mix.shell().info("No agents record #{principal} as their creator.")
    end

    {:ok, owned}
  end

  defp named?(profile, ref) do
    profile.agent_id == ref or profile.display_name == ref or
      (is_map(profile.character) and Map.get(profile.character, :name) == ref)
  end

  defp grant_one(profile, principal, key_path, remote) do
    with {:ok, capability, proof} <- prepare(key_path, profile.agent_id, principal) do
      case remote.(Arbor.Agent, :submit_signed_owner_disclosure_grant, [capability, proof]) do
        {:ok, :granted} ->
          Mix.shell().info(
            "Granted #{label(profile)} #{capability.resource_uri}: its Session may now " <>
              "mint the disclosure for your own chat turns."
          )

          :ok

        {:ok, :already_granted} ->
          Mix.shell().info("#{label(profile)} already holds #{capability.resource_uri}.")
          :ok

        {:error, reason} ->
          Mix.shell().error(refusal(profile, principal, reason))
          :error

        other ->
          Mix.shell().error("Unexpected reply from the server: #{inspect(other)}")
          :error
      end
    end
  end

  defp prepare(key_path, agent_id, principal) do
    result =
      case :file.open(String.to_charlist(key_path), [:read, :raw, :binary]) do
        {:ok, io_device} ->
          try do
            Arbor.Security.prepare_key_file_disclosure_right_grant(io_device, agent_id)
          after
            :file.close(io_device)
          end

        {:error, reason} ->
          {:error, {:read_failed, reason}}
      end

    case result do
      {:ok, ^principal, capability, proof} ->
        {:ok, capability, proof}

      {:ok, _other, _capability, _proof} ->
        Mix.shell().error("Operator key changed while signing (#{key_path}).")
        :error

      {:error, reason} ->
        Mix.shell().error("Could not sign the grant with #{key_path}: #{inspect(reason)}")
        :error
    end
  end

  defp label(profile), do: "'#{profile.display_name}' (#{profile.agent_id})"

  defp not_owner(profile, principal, nil),
    do: """
    #{label(profile)} records no creator, so #{principal} cannot grant it this right.
    Recreate the agent with `mix arbor.agent start`; new agents get it at creation.
    """

  defp not_owner(profile, principal, creator),
    do: """
    #{label(profile)} was created by #{creator}, not #{principal}.
    Only its creator can grant it the right to mint the disclosure for their own turns.
    """

  defp refusal(profile, principal, :not_agent_owner),
    do: "The server does not record #{principal} as the creator of #{label(profile)}."

  defp refusal(profile, principal, :capability_mutation_unauthorized),
    do: """
    #{principal} may not grant capabilities to #{label(profile)} (:capability_mutation_unauthorized).
    The administrator made by `mix arbor.user.init` (genesis) can.
    """

  defp refusal(profile, _principal, reason),
    do: "The server refused the grant for #{label(profile)}: #{inspect(reason)}"

  defp remote(mod, fun, args), do: Config.rpc!(Config.full_node_name(), mod, fun, args)
end
