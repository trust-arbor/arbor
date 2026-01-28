defmodule Arbor.Contracts.API.Security do
  @moduledoc """
  Public API contract for the Arbor.Security library.

  Defines the facade interface for capability-based security. Security handles
  authorization (checking capabilities) and capability lifecycle (grant/revoke/list).

  Trust management (profiles, scoring, tiers, freezing) is handled by the
  separate `Arbor.Contracts.API.Trust` behaviour.

  ## Quick Start

      case Arbor.Security.authorize("agent_001", "arbor://fs/read/docs", :read) do
        {:ok, :authorized} -> proceed()
        {:error, reason} -> handle_denial(reason)
      end
  """

  alias Arbor.Types

  @type principal_id :: Types.agent_id()
  @type resource :: Types.resource_uri()
  @type action :: Types.operation()

  @type authorization_result ::
          {:ok, :authorized}
          | {:ok, :pending_approval, proposal_id :: String.t()}
          | {:error, authorization_error()}

  @type authorization_error ::
          :unauthorized
          | :capability_not_found
          | :capability_expired
          | :insufficient_trust
          | :trust_frozen
          | :unknown_agent
          | :invalid_signature
          | :invalid_capability_signature
          | :broken_delegation_chain
          | :expired_timestamp
          | :replayed_nonce
          | {:constraint_violated, constraint_type :: atom(), context :: map()}
          | {:quota_exceeded, quota_type(), quota_context()}
          | term()

  @type quota_type :: :per_agent_capability_limit | :global_capability_limit | :delegation_depth_limit
  @type quota_context :: %{
          optional(:current) => non_neg_integer(),
          optional(:limit) => non_neg_integer(),
          optional(:agent_id) => String.t(),
          optional(:depth) => non_neg_integer()
        }

  @type constraint_type :: :time_window | :allowed_paths | :rate_limit | :requires_approval

  @type capability :: map()

  @type authorize_opts :: [
          context: map(),
          skip_consensus: boolean(),
          trace_id: String.t(),
          signed_request: map() | nil,
          verify_identity: boolean()
        ]

  @type grant_opts :: [
          principal: principal_id(),
          resource: resource(),
          constraints: map(),
          expires_at: DateTime.t() | nil,
          delegation_depth: non_neg_integer(),
          metadata: map(),
          issuer_id: String.t()
        ]

  # ===========================================================================
  # Core Authorization
  # ===========================================================================

  @doc """
  Check if a principal has a valid capability for a resource action.

  Verifies both capability existence and trust status.
  """
  @callback check_if_principal_has_capability_for_resource_action(
              principal_id(),
              resource(),
              action(),
              authorize_opts()
            ) :: authorization_result()

  # ===========================================================================
  # Capability Management
  # ===========================================================================

  @doc """
  Grant a capability to a principal for a specific resource.
  """
  @callback grant_capability_to_principal_for_resource(grant_opts()) ::
              {:ok, capability()} | {:error, term()}

  @doc """
  Delegate a capability from one principal to another.

  Creates a new capability derived from an existing one, with a signed delegation chain.
  """
  @callback delegate_capability_from_principal_to_principal(
              capability_id :: String.t(),
              new_principal_id :: String.t(),
              opts :: keyword()
            ) :: {:ok, capability()} | {:error, term()}

  @doc """
  Revoke a previously granted capability by its ID.
  """
  @callback revoke_capability_by_id(capability_id :: String.t(), opts :: keyword()) ::
              :ok | {:error, :not_found | term()}

  @doc """
  List all capabilities granted to a principal.
  """
  @callback list_capabilities_for_principal(principal_id(), opts :: keyword()) ::
              {:ok, [capability()]} | {:error, term()}

  # ===========================================================================
  # Fast Authorization
  # ===========================================================================

  @doc """
  Check if a principal can perform an operation on a resource.

  Fast boolean check — capability only, does not verify trust status.
  """
  @callback check_if_principal_can_perform_operation_on_resource(
              principal_id(),
              resource_uri :: String.t(),
              operation :: atom()
            ) :: boolean()

  # ===========================================================================
  # Lifecycle
  # ===========================================================================

  @doc """
  Start the security system.
  """
  @callback start_link(opts :: keyword()) :: GenServer.on_start()

  @doc """
  Check if the security system is healthy.
  """
  @callback healthy?() :: boolean()

  @optional_callbacks [
    check_if_principal_can_perform_operation_on_resource: 3,
    delegate_capability_from_principal_to_principal: 3
  ]
end
