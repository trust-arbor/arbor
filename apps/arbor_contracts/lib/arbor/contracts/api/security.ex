defmodule Arbor.Contracts.API.Security do
  @moduledoc """
  Public API contract for the Arbor.Security library.

  Defines the facade interface for capability-based security.

  ## Quick Start

      case Arbor.Security.authorize("agent_001", "arbor://fs/read/docs", :read) do
        {:ok, :authorized} -> proceed()
        {:error, reason} -> handle_denial(reason)
      end

  ## Trust Tiers

  | Tier | Score | Capabilities |
  |------|-------|--------------|
  | `:untrusted` | 0-19 | Read own code only |
  | `:probationary` | 20-49 | Limited access |
  | `:trusted` | 50-74 | Standard access |
  | `:veteran` | 75-89 | Extended access |
  | `:autonomous` | 90-100 | Self-modification |
  """

  alias Arbor.Types

  @type principal_id :: Types.agent_id()
  @type resource :: Types.resource_uri()
  @type action :: Types.operation()
  @type trust_tier :: :untrusted | :probationary | :trusted | :veteran | :autonomous

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
          | term()

  @type capability :: map()
  @type trust_profile :: map()

  @type authorize_opts :: [
          context: map(),
          skip_consensus: boolean(),
          trace_id: String.t()
        ]

  @type grant_opts :: [
          principal: principal_id(),
          resource: resource(),
          constraints: map(),
          expires_at: DateTime.t() | nil,
          delegation_depth: non_neg_integer(),
          metadata: map()
        ]

  # Core Authorization

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

  # Capability Management

  @doc """
  Grant a capability to a principal for a specific resource.
  """
  @callback grant_capability_to_principal_for_resource(grant_opts()) ::
              {:ok, capability()} | {:error, term()}

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

  # Trust Management

  @doc """
  Create a new trust profile for a principal.

  Initializes the principal with default untrusted tier.
  """
  @callback create_trust_profile_for_principal(principal_id()) ::
              {:ok, trust_profile()} | {:error, :already_exists | term()}

  @doc """
  Get the complete trust profile for a principal.
  """
  @callback get_trust_profile_for_principal(principal_id()) ::
              {:ok, trust_profile()} | {:error, :not_found}

  @doc """
  Get the current trust tier for a principal.
  """
  @callback get_current_trust_tier_for_principal(principal_id()) ::
              {:ok, trust_tier()} | {:error, :not_found}

  @doc """
  Record a trust-affecting event for a principal with metadata.

  Events modify the principal's trust score and may trigger tier changes.
  """
  @callback record_trust_event_for_principal_with_metadata(
              principal_id(),
              event_type :: atom(),
              metadata :: map()
            ) :: :ok

  @doc """
  Freeze trust progression for a principal with a stated reason.

  Frozen principals keep current capabilities but cannot earn more trust.
  """
  @callback freeze_trust_progression_for_principal_with_reason(
              principal_id(),
              reason :: atom()
            ) :: :ok | {:error, term()}

  @doc """
  Unfreeze trust progression for a principal.
  """
  @callback unfreeze_trust_progression_for_principal(principal_id()) ::
              :ok | {:error, term()}

  # Fast Authorization

  @doc """
  Check if a principal can perform an operation on a resource.

  Fast boolean check — capability only, does not verify trust status.
  """
  @callback check_if_principal_can_perform_operation_on_resource(
              principal_id(),
              resource_uri :: String.t(),
              operation :: atom()
            ) :: boolean()

  # Lifecycle

  @doc """
  Start the security system.
  """
  @callback start_link(opts :: keyword()) :: GenServer.on_start()

  @doc """
  Check if the security system is healthy.
  """
  @callback healthy?() :: boolean()

  @optional_callbacks [
    check_if_principal_can_perform_operation_on_resource: 3
  ]
end
