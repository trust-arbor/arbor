defmodule Arbor.Agent.OwnerDisclosureRight do
  @moduledoc false
  # Backfill of the narrow disclosure-issue right
  # (`arbor://security/disclose/<agent_id>/<human_id>`) for agents created
  # before `Lifecycle.create/2` began granting it (2026-11-14, 9d8275a7a).
  # Without it the agent's Session cannot mint the one-turn disclosure
  # capability, so every authenticated turn of its owner on an external route
  # is refused at route_and_disclosure (`:capability_mutation_unauthorized`).
  #
  # The operator signs the grant with its key file in the CLI process
  # (`Arbor.Security.prepare_key_file_disclosure_right_grant/2`); only the
  # capability and the signed request reach this server. Admitted only when:
  #
  #   * the right is bound to the human who signed it (never another human's
  #     turns), with no delegation, scope or task binding;
  #   * the signer created the agent (profile `created_by`), the same owner
  #     `Lifecycle.create/2` grants the right to;
  #   * the signer's own grant authority admits it
  #     (`Arbor.Security.submit_signed_capability_grant/2`): this path never
  #     grants what the signer could not grant directly.
  #
  # Idempotent: an agent that already holds the exact right is left alone and
  # the proof is not consumed.

  alias Arbor.Agent.ProfileStore
  alias Arbor.Contracts.Security.Capability
  alias Arbor.Contracts.Security.SignedRequest

  @type result :: {:ok, :granted | :already_granted} | {:error, term()}

  @spec submit(Capability.t(), SignedRequest.t()) :: result()
  def submit(
        %Capability{principal_id: agent_id} = cap,
        %SignedRequest{agent_id: signer} = proof
      )
      when is_binary(agent_id) and is_binary(signer) do
    with {:ok, resource} <- right_uri(agent_id, signer),
         :ok <- bound_to(cap, resource),
         :ok <- created_by(agent_id, signer) do
      if holds?(agent_id, resource) do
        {:ok, :already_granted}
      else
        case Arbor.Security.submit_signed_disclosure_right_grant(cap, proof) do
          {:ok, _capability} -> {:ok, :granted}
          {:error, _reason} = error -> error
        end
      end
    end
  rescue
    _ -> {:error, :disclosure_right_grant_failed}
  catch
    :exit, _ -> {:error, :disclosure_right_grant_failed}
  end

  def submit(_cap, _proof), do: {:error, :disclosure_right_not_bound_to_signer}

  @doc false
  # The human the profile names as the agent's creator, or nil. Some agents
  # record none (for example, those created before multi-user ownership in
  # 2026-03); nobody owns them here.
  @spec creator(map()) :: String.t() | nil
  def creator(%{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, :created_by) || Map.get(metadata, "created_by") do
      creator when is_binary(creator) and creator != "" -> creator
      _ -> nil
    end
  end

  def creator(_profile), do: nil

  defp right_uri(agent_id, signer) do
    case Arbor.Security.disclosure_issue_right_uri(agent_id, signer) do
      {:ok, resource} -> {:ok, resource}
      {:error, _} -> {:error, :disclosure_right_not_bound_to_signer}
    end
  end

  defp bound_to(%Capability{resource_uri: resource}, resource), do: :ok
  defp bound_to(_cap, _resource), do: {:error, :disclosure_right_not_bound_to_signer}

  defp created_by(agent_id, signer) do
    case ProfileStore.load_profile(agent_id) do
      {:ok, profile} ->
        if creator(profile) == signer, do: :ok, else: {:error, :not_agent_owner}

      {:error, _} ->
        {:error, :agent_not_found}
    end
  end

  defp holds?(agent_id, resource) do
    case Arbor.Security.list_capabilities(agent_id) do
      {:ok, caps} ->
        Enum.any?(caps, &(&1.resource_uri == resource and Capability.valid?(&1)))

      _ ->
        false
    end
  end
end
