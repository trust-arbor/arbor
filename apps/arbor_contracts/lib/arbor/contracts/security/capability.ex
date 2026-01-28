defmodule Arbor.Contracts.Security.Capability do
  @moduledoc """
  Represents a permission grant for resource access.

  This is the fundamental security primitive in the Arbor system. Capabilities
  are unforgeable tokens that grant specific permissions to access resources
  or perform operations.

  ## Capability Model

  - **Resource-oriented**: Each capability grants access to a specific resource
  - **Time-limited**: Capabilities can have expiration times
  - **Delegatable**: Capabilities can be delegated with reduced permissions
  - **Constrainable**: Additional constraints can limit capability scope

  ## Resource URIs

  Resources are identified by URIs following the pattern:
  `arbor://{type}/{operation}/{path}`

  Examples:
  - `arbor://fs/read/project/docs` - Read access to directory
  - `arbor://tool/execute/code_analyzer` - Execute specific tool
  - `arbor://api/call/external_service` - Call external API

  ## Usage

      {:ok, cap} = Capability.new(
        resource_uri: "arbor://fs/read/project/src",
        principal_id: "agent_abc123",
        expires_at: DateTime.utc_now() |> DateTime.add(3600, :second)
      )
  """

  use TypedStruct

  alias Arbor.Types

  @derive {Jason.Encoder, except: [:signature]}
  typedstruct enforce: true do
    @typedoc "A capability granting access to a specific resource"

    field(:id, Types.capability_id())
    field(:resource_uri, Types.resource_uri())
    field(:principal_id, Types.agent_id())
    field(:granted_at, DateTime.t())
    field(:expires_at, DateTime.t(), enforce: false)
    field(:parent_capability_id, Types.capability_id(), enforce: false)
    field(:delegation_depth, non_neg_integer(), default: 3)
    field(:constraints, map(), default: %{})
    field(:signature, binary(), enforce: false)
    field(:metadata, map(), default: %{})
  end

  @doc """
  Create a new capability with validation.

  ## Options

  - `:resource_uri` (required) - URI of the resource this capability grants access to
  - `:principal_id` (required) - ID of the agent receiving this capability
  - `:expires_at` - When this capability expires (optional)
  - `:parent_capability_id` - Parent capability if this is a delegation
  - `:delegation_depth` - How many times this capability can be delegated (default: 3)
  - `:constraints` - Additional constraints on capability usage
  - `:metadata` - Additional metadata

  ## Examples

      # Basic capability
      {:ok, cap} = Capability.new(
        resource_uri: "arbor://fs/read/project/docs",
        principal_id: "agent_worker001"
      )

      # Time-limited capability
      {:ok, cap} = Capability.new(
        resource_uri: "arbor://api/call/openai",
        principal_id: "agent_llm001",
        expires_at: DateTime.utc_now() |> DateTime.add(1, :hour),
        constraints: %{max_requests: 100}
      )
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    capability = %__MODULE__{
      id: attrs[:id] || generate_capability_id(),
      resource_uri: Keyword.fetch!(attrs, :resource_uri),
      principal_id: Keyword.fetch!(attrs, :principal_id),
      granted_at: attrs[:granted_at] || DateTime.utc_now(),
      expires_at: attrs[:expires_at],
      parent_capability_id: attrs[:parent_capability_id],
      delegation_depth: attrs[:delegation_depth] || 3,
      constraints: attrs[:constraints] || %{},
      metadata: attrs[:metadata] || %{}
    }

    case validate_capability(capability) do
      :ok -> {:ok, capability}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Check if a capability is currently valid.

  A capability is valid if:
  - It has not expired
  - It has delegation depth remaining (if delegated)
  """
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{} = cap) do
    not_expired?(cap) and has_delegation_depth?(cap)
  end

  @doc """
  Check if a capability grants access to a specific resource.

  Supports exact matching and pattern matching for hierarchical resources.
  """
  @spec grants_access?(t(), String.t()) :: boolean()
  def grants_access?(%__MODULE__{resource_uri: cap_uri}, resource_uri) do
    cap_uri == resource_uri or String.starts_with?(resource_uri, cap_uri <> "/")
  end

  @doc """
  Create a delegated capability with reduced permissions.

  The new capability will have:
  - Reduced delegation depth
  - Same or shorter expiration time
  - Additional constraints as specified
  """
  @spec delegate(t(), Types.agent_id(), keyword()) :: {:ok, t()} | {:error, term()}
  def delegate(%__MODULE__{} = parent, new_principal_id, opts \\ []) do
    if parent.delegation_depth <= 0 do
      {:error, :delegation_depth_exhausted}
    else
      new_constraints = Map.merge(parent.constraints, opts[:constraints] || %{})
      new_expires_at = min_datetime(parent.expires_at, opts[:expires_at])

      new(
        resource_uri: parent.resource_uri,
        principal_id: new_principal_id,
        expires_at: new_expires_at,
        parent_capability_id: parent.id,
        delegation_depth: parent.delegation_depth - 1,
        constraints: new_constraints,
        metadata: opts[:metadata] || %{}
      )
    end
  end

  # Private functions

  defp generate_capability_id do
    "cap_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  defp validate_capability(%__MODULE__{} = cap) do
    validators = [
      &validate_resource_uri/1,
      &validate_principal_id/1,
      &validate_expiration/1,
      &validate_delegation_depth/1
    ]

    Enum.reduce_while(validators, :ok, fn validator, :ok ->
      case validator.(cap) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_resource_uri(%{resource_uri: uri}) do
    if valid_resource_uri?(uri) do
      :ok
    else
      {:error, {:invalid_resource_uri, uri}}
    end
  end

  defp validate_principal_id(%{principal_id: id}) do
    if String.starts_with?(id, "agent_") do
      :ok
    else
      {:error, {:invalid_principal_id, id}}
    end
  end

  defp validate_expiration(%{granted_at: _granted, expires_at: nil}), do: :ok

  defp validate_expiration(%{granted_at: granted, expires_at: expires}) do
    if DateTime.compare(expires, granted) == :gt do
      :ok
    else
      {:error, {:expires_before_granted, expires, granted}}
    end
  end

  defp validate_delegation_depth(%{delegation_depth: depth}) when depth >= 0 and depth <= 10 do
    :ok
  end

  defp validate_delegation_depth(%{delegation_depth: depth}) do
    {:error, {:invalid_delegation_depth, depth}}
  end

  defp valid_resource_uri?(uri) when is_binary(uri) do
    String.match?(uri, ~r/^arbor:\/\/[a-z]+\/[a-z]+\/.+$/)
  end

  defp valid_resource_uri?(_), do: false

  defp not_expired?(%{expires_at: nil}), do: true

  defp not_expired?(%{expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :gt
  end

  defp has_delegation_depth?(%{delegation_depth: depth}), do: depth >= 0

  defp min_datetime(nil, nil), do: nil
  defp min_datetime(dt, nil), do: dt
  defp min_datetime(nil, dt), do: dt

  defp min_datetime(dt1, dt2) do
    case DateTime.compare(dt1, dt2) do
      :lt -> dt1
      _ -> dt2
    end
  end
end
