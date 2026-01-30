defmodule Arbor.Security.Kernel do
  @moduledoc """
  Security kernel providing core capability operations.

  This module serves as the programmatic API for granting and revoking
  capabilities. It delegates to the CapabilityStore for persistence
  and the Security facade for higher-level operations.
  """

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security.CapabilityStore

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
    principal_id = Keyword.fetch!(opts, :principal_id)
    resource_uri = Keyword.fetch!(opts, :resource_uri)
    constraints = Keyword.get(opts, :constraints, %{})
    metadata = Keyword.get(opts, :metadata, %{})
    expires_at = Keyword.get(opts, :expires_at)

    case Capability.new(
           resource_uri: resource_uri,
           principal_id: principal_id,
           constraints: constraints,
           expires_at: expires_at,
           metadata: metadata
         ) do
      {:ok, cap} ->
        {:ok, :stored} = CapabilityStore.put(cap)
        {:ok, cap}

      error ->
        error
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
    capability_id = Keyword.fetch!(opts, :capability_id)
    CapabilityStore.revoke(capability_id)
  end
end
