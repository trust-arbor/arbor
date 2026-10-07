defmodule Arbor.Security.Kernel do
  @moduledoc """
  Security kernel providing core capability operations.

  This module serves as the programmatic API for granting and revoking
  capabilities. It delegates to the CapabilityStore for persistence
  and the Security facade for higher-level operations.
  """

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security

  @doc """
  Grant a capability using keyword options.

  ## Options

  - `:principal_id` - Agent ID (required)
  - `:resource_uri` - Resource URI (required)
  - `:constraints` - Constraints map (default: %{})
  - `:granter_id` - ID of the granting entity
  - `:metadata` - Additional metadata map
  - `:expires_at` - Expiration DateTime

  ## Returns

  - `{:ok, capability}` on success
  - `{:error, reason}` on failure
  """
  @spec grant_capability(keyword()) :: {:ok, Capability.t()} | {:error, term()}
  def grant_capability(opts) do
    with true <- Keyword.keyword?(opts),
         principal_id when is_binary(principal_id) <- Keyword.get(opts, :principal_id),
         resource_uri when is_binary(resource_uri) <- Keyword.get(opts, :resource_uri),
         actor_authority when not is_nil(actor_authority) <- Keyword.get(opts, :actor_authority) do
      Security.grant(
        principal: principal_id,
        resource: resource_uri,
        actor_authority: actor_authority,
        constraints: Keyword.get(opts, :constraints, %{}),
        metadata: Keyword.get(opts, :metadata, %{}),
        expires_at: Keyword.get(opts, :expires_at)
      )
    else
      _ -> {:error, :capability_mutation_unauthorized}
    end
  end

  @doc """
  Revoke a capability using keyword options.

  ## Options

  - `:capability_id` - ID of the capability to revoke (required)
  - `:reason` - Reason for revocation
  - `:revoker_id` - ID of the revoking entity
  - `:cascade` - Whether to cascade revocation (default: false)

  ## Returns

  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @spec revoke_capability(keyword()) :: :ok | {:error, term()}
  def revoke_capability(opts) do
    with true <- Keyword.keyword?(opts),
         capability_id when is_binary(capability_id) <- Keyword.get(opts, :capability_id),
         actor_authority when not is_nil(actor_authority) <- Keyword.get(opts, :actor_authority) do
      Security.revoke(capability_id, actor_authority: actor_authority)
    else
      _ -> {:error, :capability_mutation_unauthorized}
    end
  end
end
