defmodule Arbor.Contracts.Security.Enforcer do
  @moduledoc """
  Defines the contract for security enforcement in the Arbor system.

  This behaviour establishes how capability-based security is enforced
  throughout the system. All security implementations must conform to
  this contract to ensure consistent authorization decisions.

  ## Security Model

  Arbor uses capability-based security where:
  - Every operation requires an explicit capability
  - Capabilities are unforgeable tokens with specific permissions
  - Capabilities can be delegated with reduced permissions
  - All security decisions are auditable

  ## Example Implementation

      defmodule MySecurityEnforcer do
        @behaviour Arbor.Contracts.Security.Enforcer

        @impl true
        def authorize(cap, resource_uri, operation, context, state) do
          with :ok <- validate_capability(cap),
               :ok <- check_permissions(cap, resource_uri, operation),
               :ok <- verify_constraints(cap, context) do
            {:ok, :authorized}
          else
            {:error, reason} ->
              {:error, {:authorization_denied, reason}}
          end
        end
      end
  """

  alias Arbor.Contracts.Core.Capability
  alias Arbor.Contracts.Security.AuditEvent
  alias Arbor.Types

  @type state :: any()
  @type context :: map()

  @type authorization_error ::
          :capability_expired
          | :capability_revoked
          | :invalid_capability
          | :insufficient_permissions
          | :resource_not_found
          | :operation_not_allowed
          | :constraint_violation
          | {:custom_error, term()}

  @doc """
  Authorize an operation on a resource using a capability.
  """
  @callback authorize(
              capability :: Capability.t(),
              resource_uri :: Types.resource_uri(),
              operation :: Types.operation(),
              context :: context(),
              state :: state()
            ) :: {:ok, :authorized} | {:error, {:authorization_denied, authorization_error()}}

  @doc """
  Check if a capability is valid without performing authorization.
  """
  @callback validate_capability(
              capability :: Capability.t(),
              state :: state()
            ) :: {:ok, :valid} | {:error, authorization_error()}

  @doc """
  Grant a new capability.
  """
  @callback grant_capability(
              principal_id :: Types.agent_id(),
              resource_uri :: Types.resource_uri(),
              constraints :: map(),
              granter_id :: String.t(),
              state :: state()
            ) :: {:ok, Capability.t()} | {:error, term()}

  @doc """
  Revoke an existing capability.
  """
  @callback revoke_capability(
              capability_id :: Types.capability_id(),
              reason :: atom() | String.t(),
              revoker_id :: String.t(),
              cascade :: boolean(),
              state :: state()
            ) :: :ok | {:error, term()}

  @doc """
  Delegate a capability to another principal.
  """
  @callback delegate_capability(
              parent_capability :: Capability.t(),
              delegate_to :: Types.agent_id(),
              constraints :: map(),
              delegator_id :: String.t(),
              state :: state()
            ) :: {:ok, Capability.t()} | {:error, term()}

  @doc """
  List all capabilities for a principal.
  """
  @callback list_capabilities(
              principal_id :: Types.agent_id(),
              filters :: keyword(),
              state :: state()
            ) :: {:ok, [Capability.t()]} | {:error, term()}

  @doc """
  Get audit trail for security events.
  """
  @callback get_audit_trail(
              filters :: keyword(),
              state :: state()
            ) :: {:ok, [AuditEvent.t()]} | {:error, term()}

  @doc """
  Initialize the security enforcer.
  """
  @callback init(opts :: keyword()) :: {:ok, state()} | {:error, term()}

  @doc """
  Clean up resources when shutting down.
  """
  @callback terminate(reason :: term(), state :: state()) :: :ok
end
